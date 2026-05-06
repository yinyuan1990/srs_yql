import Foundation
import AVFoundation
import CoreMedia


final class LiveManager: ObservableObject {
    // MARK: - RTMP
    //private let conn = RTMPConnection()
    
    private var isSwitchingProfile = false
    private let previewConn = RTMPConnection()   // 只给预览流用，永不 connect
    private var publishConn: RTMPConnection?     // 仅推流时存在
    let stream: RTMPStream                       // 预览流（绑定 previewConn）
    private var pubStream: RTMPStream?           // 推流流（绑定 publishConn）

    // MARK: - 采集/设备
    private let mixer = MediaMixer()
    private var cameraDevice: AVCaptureDevice?

    // MARK: - UI 状态
    @Published var isPublishing = false
    @Published var log: [String] = []

    // MARK: - 服务器/推流地址
    @Published var serverIP = ""  // 从登录接口获取
    @Published var app = "tenantA"
    @Published var streamKey = "" // 登录后从 permanent_token 获取

    private var isRTMPConnected = false
    private var rtmpURL: String { "rtmp://\(serverIP)/\(app)" }

    // MARK: - 档位
    @Published var currentProfile: StreamProfile = .standard
    @Published var pendingProfile: StreamProfile? = nil

    // MARK: - 记忆参数（UI 显示）
    @Published var width = 1280
    @Published var height = 720
    @Published var fps = 60
    @Published var bitrateKbps = 2500
    @Published var usingBackCamera = true
    @Published var zoom: CGFloat = 0.5  // 🔥 默认超广角

    private static var createdCount = 0

    // MARK: - 任务
    private var statusTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?

    // ✅ 是否已完成首挂相机
    private var hasAttachedCamera = false

    // MARK: - EV
    @Published var exposureBiasEV: Float = 0
    private var pendingExposureBias: Float?

    // MARK: - 音频（保留占位，不使用也不影响）
    private var hasAttachedMic = false

    @MainActor
    private func ensureMicPermission() async -> Bool {
        let perm = AVAudioSession.sharedInstance().recordPermission
        if perm == .undetermined {
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    cont.resume(returning: ok)
                }
            }
        }
        return perm == .granted
    }

    private func attachMicToMixerIfNeeded() async {
        guard !hasAttachedMic else { return }
        guard await ensureMicPermission() else {
            print("❌ 麦克风权限未授权"); return
        }
        guard let mic = AVCaptureDevice.default(for: .audio) else {
            print("⚠️ 未找到可用麦克风设备"); return
        }
        do {
            try await mixer.attachAudio(mic, track: 0)
            hasAttachedMic = true
            print("✅ 麦克风已连接（挂到 MediaMixer）")
        } catch {
            print("❌ 麦克风挂载失败: \(error.localizedDescription)")
        }
    }
    
    

    // MARK: - 方向
    private func position(from direction: String) -> AVCaptureDevice.Position {
        // "1" 后置，"-1" 前置；其他值都按后置处理
        return direction == "-1" ? .front : .back
    }

    // MARK: - 初始化
    init() {
        Self.createdCount += 1
        
        stream = RTMPStream(connection: previewConn)
        
        print("📥 init: join #\(Self.createdCount)")

        // 采集 → mixer → 预览流
        Task { await mixer.addOutput(stream) }

        loadTokenIfNeeded()

        if let cached = ConfigManager.shared.getCurrentConfig() {
            print("📥 远端配置: join")
            applyRemoteConfig(cached)
        } else {
            print("📥 远端配置: no join")
        }

        NotificationCenter.default.addObserver(
            forName: .thinConfigUpdated,
            object: nil,
            queue: .main
        ) { [weak self] noti in
            guard
                let self,
                let cfg = noti.userInfo?["cfg"] as? ThinRemoteConfig
            else { return }
            print("=======>")
            self.applyRemoteConfig(cfg)
        }

        // 预览期：软编/低码/GOP=1s/禁B，快出预览
        setupPreviewPipeline()

        // 状态监听（默认监听预览流；开始推流后会切到 pubStream）
        setupStatusMonitoring()
    }

    deinit {
        statusTask?.cancel()
        connectionTask?.cancel()
    }

    // MARK: - 能力日志
    private func logExposureCapabilities(_ dev: AVCaptureDevice) {
        let minEV = dev.minExposureTargetBias
        let maxEV = dev.maxExposureTargetBias
        let fmt = dev.activeFormat
        let dmin = fmt.minExposureDuration.seconds
        let dmax = fmt.maxExposureDuration.seconds
        print("""
        📊 Exposure Caps:
        - EV range: \(minEV) ~ \(maxEV)
        - Duration: \(String(format: "%.6f", dmin))s ~ \(String(format: "%.6f", dmax))s
        - ISO: \(fmt.minISO) ~ \(fmt.maxISO)
        - Supports ROI: \(dev.isExposurePointOfInterestSupported)
        - AE mode: \(dev.exposureMode.rawValue)
        """)
    }

    // MARK: - EV
    func setExposureBias(ev: Float) {
        print("🔆 EV热更:--->1")
        guard let dev = cameraDevice else {
            print("🔆 EV热更:--->2"); return
        }
        print("🔆 EV热更:--->3")
        do {
            try dev.lockForConfiguration()

            if dev.isExposureModeSupported(.continuousAutoExposure) {
                dev.exposureMode = .continuousAutoExposure
            }
            if dev.isExposurePointOfInterestSupported {
                dev.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }

            let bizMin: Float = -2.0
            let bizMax: Float =  2.0
            let want = max(bizMin, min(ev, bizMax))
            let clamped = max(dev.minExposureTargetBias, min(want, dev.maxExposureTargetBias))

            dev.setExposureTargetBias(clamped)
            dev.unlockForConfiguration()
            exposureBiasEV = clamped
            print("🔆 EV热更: \(clamped)  (device range \(dev.minExposureTargetBias) ~ \(dev.maxExposureTargetBias))")
        } catch {
            print("❌ EV热更失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 服务器轻配置入口（type+zoom+direction+EV）
    func applyRemoteConfig(_ cfg: ThinRemoteConfig) {
        print("📥 远端配置: type=\(cfg.type), zoom=\(cfg.zoom), direction=\(cfg.direction), hasAttachedCamera=\(hasAttachedCamera), isPublishing=\(isPublishing), exposureBias=\(cfg.exposureBias)")

        // 1) 档位
        if let p = StreamProfile(rawValue: cfg.type) {
            if isPublishing {
                hotApplyProfile(p)
            } else {
                pendingProfile = p
                currentProfile = p
            }
        }
        // 2) 焦距
        setZoom(max(1.0, min(cfg.zoom, 3.0)))

        // 3) 方向
        let wantPos = position(from: cfg.direction)
        let nowPos: AVCaptureDevice.Position = usingBackCamera ? .back : .front

        // 4) EV
        if let ev = cfg.exposureBias {
            if hasAttachedCamera {
                if cameraDevice?.exposureMode != .continuousAutoExposure,
                   cameraDevice?.isExposureModeSupported(.continuousAutoExposure) == true {
                    do {
                        try cameraDevice?.lockForConfiguration()
                        cameraDevice?.exposureMode = .continuousAutoExposure
                        cameraDevice?.unlockForConfiguration()
                    } catch {
                        print("⚠️ 切 AE 模式失败: \(error.localizedDescription)")
                    }
                }
                setExposureBias(ev: ev)
            } else {
                pendingExposureBias = ev
                print("⏳ 暂存EV待首挂: \(ev)")
            }
        }

        if !hasAttachedCamera {
            usingBackCamera = (wantPos == .back)
            print("ℹ️ 尚未完成首次 attach，仅记录方向：\(usingBackCamera ? "后" : "前")置")
            return
        }

        if wantPos != nowPos {
            Task {
                do {
                    guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: wantPos) else {
                        print("❌ 切镜失败：找不到摄像头 wantPos=\(wantPos)"); return
                    }
                    try await mixer.attachVideo(dev, track: 0) { vu in
                        vu.isVideoMirrored = (wantPos == .front)
                        vu.preferredVideoStabilizationMode = .off
                    }
                    cameraDevice = dev
                    usingBackCamera = (wantPos == .back)
                    print("🔄 已切到\(usingBackCamera ? "后" : "前")置（by remote config）")
                } catch {
                    print("❌ 切镜异常: \(error.localizedDescription)")
                }
            }
        } else {
            usingBackCamera = (wantPos == .back)
        }
        
        // 后端/用户指定 fps（可选）
        if let wantFPS = cfg.fps {                 // 新增：10–60
            Task { await self.applyFPSOverride(wantFPS) }
        }
    }

    // MARK: - Token
    private func loadTokenIfNeeded() {
        if let permanentToken = UserDefaults.standard.string(forKey: "permanent_token") {
            streamKey = permanentToken
            print("✅ 已加载 permanent_token 作为 streamKey")
        } else {
            print("⚠️ 未找到 permanent_token，请先登录")
            NotificationCenter.default.post(name: NSNotification.Name("LogoutRequired"), object: nil)
        }
    }

    // MARK: - 预览期（软编/低码/GOP=1s）
    private func setupPreviewPipeline() {
        Task.detached { [weak self] in
            guard let self = self else { return }
            do {
                self.attachCamera(position: self.usingBackCamera ? .back : .front)
                
                try await self.mixer.setFrameRate(Float64(self.fps))  // 用当前 fps，而不是固定 60

                var previewV = VideoCodecSettings(
                    videoSize: CGSize(width: 1280, height: 720),
                    bitRate: 800_000,
                    profileLevel: "H264_Baseline_AutoLevel",
                    maxKeyFrameIntervalDuration: 1,
                    dataRateLimits: nil,
                    isHardwareEncoderEnabled: false
                )
                previewV.allowFrameReordering = false
                try await self.stream.setVideoSettings(previewV)
                await MainActor.run { print("✅ 预览就绪（软编/低码/GOP=1s）") }
            } catch {
                await MainActor.run { print("❌ 预览初始化失败: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - 状态监听（默认监听预览流；推流后切到 pubStream）
    /*private func setupStatusMonitoring() {
        // 重置旧任务
        statusTask?.cancel(); statusTask = nil
        connectionTask?.cancel(); connectionTask = nil

        let activeStream = self.pubStream ?? self.stream

        statusTask = Task.detached { [weak self, activeStream] in
            guard let self = self else { return }
            for await status in await activeStream.status {
                await MainActor.run { self.handleRTMPStatus(status) }
            }
        }
        connectionTask = Task.detached { [weak self] in
            guard let self = self else { return }
            for await status in await self.previewConn.status {
                await MainActor.run { self.handleConnectionStatus(status) }
            }
        }
        print("✅ HaishinKit 状态监听已设置（\(pubStream == nil ? "预览流" : "推流流")）")
    }*/
    private func setupStatusMonitoring() {
        statusTask?.cancel(); statusTask = nil
        connectionTask?.cancel(); connectionTask = nil

        let activeStream = self.pubStream ?? self.stream
        statusTask = Task.detached { [weak self, activeStream] in
            guard let self = self else { return }
            for await st in await activeStream.status {
                await MainActor.run { self.handleRTMPStatus(st) }
            }
        }
        if let c = self.publishConn {
            connectionTask = Task.detached { [weak self] in
                guard let self = self else { return }
                for await st in await c.status {
                    await MainActor.run { self.handleConnectionStatus(st) }
                }
            }
        }
        print("✅ 状态监听：\(pubStream == nil ? "预览流" : "推流流")")
    }


    @MainActor
    private func handleRTMPStatus(_ status: RTMPStatus) {
        switch status.code {
        case "NetStream.Publish.Start":
            isPublishing = true
            WebSocketManager.isPublishingFlag = 1
            print("🟢 [publishStatus] 1 ← RTMP推流开始")
        case "NetStream.Unpublish.Success":
            isPublishing = false
            WebSocketManager.isPublishingFlag = 0
            print("🔴 [publishStatus] 0 ← RTMP推流停止")
        case "NetStream.Connect.Failed", "NetStream.Publish.BadName":
            isPublishing = false
            WebSocketManager.isPublishingFlag = 0
            print("🔴 [publishStatus] 0 ← RTMP推流错误: \(status.description)")
        default:
            print("📡 RTMP状态: \(status.code) - \(status.description)")
        }
    }

    @MainActor
    private func handleConnectionStatus(_ status: RTMPStatus) {
        switch status.code {
        case "NetConnection.Connect.Success":
            isRTMPConnected = true
            print("✅ RTMP连接成功")
        case "NetConnection.Connect.Failed":
            isRTMPConnected = false
            print("❌ RTMP连接失败: \(status.description)")
        case "NetConnection.Connect.Closed":
            isRTMPConnected = false
            print("🔌 RTMP连接已关闭")
        default:
            print("🔗 连接状态: \(status.code) - \(status.description)")
        }
    }

    // MARK: - 相机 attach（预锁 720p@30）
    func attachCamera(position: AVCaptureDevice.Position) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            print("❌ 未找到\(position == .back ? "后" : "前")置摄像头"); return
        }
        cameraDevice = device
        usingBackCamera = (position == .back)

        do {
            try device.lockForConfiguration()
            
            // ✅ 先关自动 HDR 再改 HDR，顺序非常关键
           if #available(iOS 17.0, *) {
               if device.automaticallyAdjustsVideoHDREnabled {
                   device.automaticallyAdjustsVideoHDREnabled = false
               }
           }
            
            
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isVideoHDREnabled { device.isVideoHDREnabled = false }
            if device.isSubjectAreaChangeMonitoringEnabled { device.isSubjectAreaChangeMonitoringEnabled = false }

            let targetFPS: Double = Double(self.fps)
            let best = device.formats
                .compactMap { f -> (AVCaptureDevice.Format, Int)? in
                    let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                    let okFPS = f.videoSupportedFrameRateRanges.contains {
                        $0.minFrameRate <= targetFPS && targetFPS <= $0.maxFrameRate
                    }
                    guard okFPS else { return nil }
                    let diff = abs(Int(d.width) - 1280) + abs(Int(d.height) - 720)
                    return (f, diff)
                }
                .sorted { $0.1 < $1.1 }
                .first?.0

            if let best = best {
                device.activeFormat = best
                let dur = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
                device.activeVideoMinFrameDuration = dur
                device.activeVideoMaxFrameDuration = dur
            }
            device.unlockForConfiguration()
        } catch {
            print("⚠️ 相机预配置失败: \(error.localizedDescription)")
        }

        Task.detached { [weak self] in
            guard let self = self else { return }
            do {
                try await self.mixer.attachVideo(device, track: 0) { vu in
                    vu.isVideoMirrored = (position == .front)
                    vu.preferredVideoStabilizationMode = .off
                }
                await MainActor.run {
                    self.hasAttachedCamera = true
                    print("✅ \(position == .back ? "后" : "前")置摄像头已连接 (hasAttachedCamera=\(self.hasAttachedCamera))")
                }

                // 首挂后应用暂存 EV
                if let ev = self.pendingExposureBias {
                    self.pendingExposureBias = nil
                    self.setExposureBias(ev: ev)
                    await MainActor.run { print("🔁 首挂后应用EV: \(ev)") }
                }
            } catch {
                await MainActor.run { print("❌ 相机附加失败: \(error.localizedDescription)") }
            }
        }

        self.logExposureCapabilities(device)
    }

    // MARK: - 焦距（热更）
    func setZoom(_ factor: CGFloat) {
        zoom = factor
        guard let device = cameraDevice else {
            print("ℹ️ 相机未挂，先记住 zoom=\(factor)")
            return
        }
        do {
            try device.lockForConfiguration()
            let safe = max(1.0, min(factor, device.activeFormat.videoMaxZoomFactor))
            device.videoZoomFactor = safe
            device.unlockForConfiguration()
            print("变焦设置成功: \(safe)x")
        } catch {
            print("变焦设置失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 开始推流（每次新建 pubStream；预览流不参与 publish）
    
    
    func start() {
        guard !serverIP.isEmpty && !app.isEmpty && !streamKey.isEmpty else { print("❌ 服务器信息不完整"); return }
        guard !isPublishing else { print("ℹ️ 已在推流中"); return }

        let url = "rtmp://\(serverIP)/\(app)"
        let profile = pendingProfile ?? currentProfile
        guard let preset = StreamPreset.table[profile] else { return }

        width = preset.width; height = preset.height; fps = preset.fps; bitrateKbps = preset.videoBitrateKbps

        Task.detached { [weak self] in
            guard let self = self else { return }
            do {
                // 1) 新建“推流连接”
                let conn = RTMPConnection()
                self.publishConn = conn

                // 2) 监听切到“推流侧”
                //await MainActor.run { self.setupStatusMonitoring() }

                // 3) 连接并等待成功（带超时）
                try await conn.connect(url)
                try await Task.sleep(nanoseconds: 100_000_000) // 给握手留一点点时间

                // 4) 新建“推流流”，绑定 mixer 输出
                let s = RTMPStream(connection: conn)
                self.pubStream = s
                await self.mixer.addOutput(s)
                
                await MainActor.run { self.setupStatusMonitoring() }

                var v = VideoCodecSettings(
                    videoSize: CGSize(width: preset.width, height: preset.height),
                    bitRate: preset.videoBitrateKbps * 1000,
                    profileLevel: preset.h264ProfileLevel,
                    maxKeyFrameIntervalDuration: Int32(preset.keyframeIntervalSec),
                    dataRateLimits: nil,
                    isHardwareEncoderEnabled: true
                )
                v.allowFrameReordering = false
                try await s.setVideoSettings(v)

                try await Task.sleep(nanoseconds: 120_000_000)
                try await s.publish(self.streamKey)

                await MainActor.run {
                    self.isPublishing = true
                    self.currentProfile = profile
                    self.pendingProfile = nil
                    print("🚀 推流开始")
                }
            } catch {
                await MainActor.run { print("❌ 连接/推流失败: \(error.localizedDescription)") }
                await self._cleanupPublishSide()  // 失败兜底清理
            }
        }
    }

    @MainActor
    private func _cleanupPublishSide() async {
        statusTask?.cancel(); statusTask = nil
        connectionTask?.cancel(); connectionTask = nil
        WebSocketManager.isPublishingFlag = 0
        print("🔴 [publishStatus] 0 ← RTMP清理资源")
        if let s = pubStream {
            await mixer.removeOutput(s)
            do { try await s.close() } catch { print("ℹ️ close pubStream: \(error.localizedDescription)") }
        }
        if let c = publishConn {
            do { try await c.close() } catch { print("ℹ️ close publishConn: \(error.localizedDescription)") }
        }
        pubStream = nil
        publishConn = nil
        isPublishing = false
        print("✅ 推流侧已清理干净")
    }

    func stop() { Task { @MainActor in await _cleanupPublishSide(); setupStatusMonitoring() } }

    
    // MARK: - 停止推流（仅关闭 pubStream，不影响预览流/连接）
    

    // MARK: - 切镜（热更）
    func toggleCamera() {
        Task {
            do {
                let newPos: AVCaptureDevice.Position = usingBackCamera ? .front : .back
                guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPos) else {
                    print("❌ 切镜失败：找不到摄像头"); return
                }
                try await mixer.attachVideo(dev, track: 0) { vu in
                    vu.isVideoMirrored = (newPos == .front)
                    vu.preferredVideoStabilizationMode = .off
                }
                usingBackCamera = (newPos == .back)
                cameraDevice = dev
                print("🔄 已切到\(usingBackCamera ? "后" : "前")置")
            } catch {
                print("❌ 切镜异常: \(error.localizedDescription)")
            }
        }
    }
    
    
    private func formatSupportsFPS(_ format: AVCaptureDevice.Format, fps: Double) -> Bool {
            for r in format.videoSupportedFrameRateRanges {
                if r.minFrameRate <= fps && fps <= r.maxFrameRate { return true }
            }
            return false
    }
   
    // 方法：applyFPSOverride(_:)（仅调整当前 activeFormat 的帧间隔，不更换 format）
    func applyFPSOverride(_ newFPS: Int) async {
        // ... existing code ...
        let clamped = max(10, min(newFPS, 60))
        await MainActor.run { self.fps = clamped }

        guard let device = cameraDevice else {
            print("ℹ️ 相机未挂，记录 fps 覆盖: \(clamped)")
            return
        }

        do {
            try device.lockForConfiguration()
            let targetFPS = Double(clamped)

            // 仅在当前 activeFormat 内设置帧率，避免切换 format 造成停帧
            if let range = device.activeFormat.videoSupportedFrameRateRanges.first {
                let safeFPS = max(Double(range.minFrameRate), min(targetFPS, Double(range.maxFrameRate)))
                let dur = CMTime(value: 1, timescale: CMTimeScale(safeFPS))
                device.activeVideoMinFrameDuration = dur
                device.activeVideoMaxFrameDuration = dur
                device.unlockForConfiguration()
                await MainActor.run { self.fps = Int(safeFPS) }
                if Int(safeFPS) != clamped {
                    print("⚠️ 目标 \(clamped)fps 不支持，回退为 \(Int(safeFPS))fps（保持当前 format）")
                } else {
                    print("✅ 采集端帧率覆盖为 \(clamped)fps（保持当前 format）")
                }
            } else {
                device.unlockForConfiguration()
                print("⚠️ 未找到可用的帧率范围，保持当前设置")
            }
        } catch {
            print("❌ 采集端帧率覆盖失败: \(error.localizedDescription)")
        }

        // 输出端尽量同步（若你本地是 internal，可移除此调用）
        do { try await mixer.setFrameRate(Float64(clamped)) } catch {
            print("⚠️ 混合器帧率设置失败或不可用，将跟随采集端: \(error.localizedDescription)")
        }
        // ... existing code ...
    }
    
    /*
    // 方法：applyFPSOverride(_:)（行号约 641）
    func applyFPSOverride(_ newFPS: Int) async {
        // ... existing code ...
        let clamped = max(10, min(newFPS, 60))
        await MainActor.run { self.fps = clamped }

        guard let device = cameraDevice else {
            print("ℹ️ 相机未挂，记录 fps 覆盖: \(clamped)")
            return
        }

        do {
            try device.lockForConfiguration()
            let targetFPS = Double(clamped)

            let desiredW = self.width
            let desiredH = self.height
            // 选择最接近目标分辨率且支持目标 fps 的 format
            let best = device.formats
                .filter { formatSupportsFPS($0, fps: targetFPS) }
                .sorted { f1, f2 in
                    let d1 = CMVideoFormatDescriptionGetDimensions(f1.formatDescription)
                    let d2 = CMVideoFormatDescriptionGetDimensions(f2.formatDescription)
                    let diff1 = abs(Int(d1.width) - desiredW) + abs(Int(d1.height) - desiredH)
                    let diff2 = abs(Int(d2.width) - desiredW) + abs(Int(d2.height) - desiredH)
                    return diff1 < diff2
                }
                .first

            if let best = best {
                device.activeFormat = best
                let dur = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
                device.activeVideoMinFrameDuration = dur
                device.activeVideoMaxFrameDuration = dur
                device.unlockForConfiguration()
                print("✅ 采集端帧率覆盖为 \(clamped)fps")
            } else {
                // 无任一 format 支持目标 fps → 回退到当前 activeFormat 支持范围
                if let range = device.activeFormat.videoSupportedFrameRateRanges.first {
                    let fallbackFPS = max(Double(range.minFrameRate), min(targetFPS, Double(range.maxFrameRate)))
                    let dur = CMTime(value: 1, timescale: CMTimeScale(fallbackFPS))
                    device.activeVideoMinFrameDuration = dur
                    device.activeVideoMaxFrameDuration = dur
                    device.unlockForConfiguration()
                    await MainActor.run { self.fps = Int(fallbackFPS) }
                    print("⚠️ 目标 \(clamped)fps 不支持，回退为 \(Int(fallbackFPS))fps")
                    do { try await mixer.setFrameRate(fallbackFPS) } catch {
                        print("ℹ️ 混合器回退帧率失败/不可用: \(error.localizedDescription)")
                    }
                    return
                }
                device.unlockForConfiguration()
                print("⚠️ 未找到可用的帧率范围，保持当前设置")
            }
        } catch {
            print("❌ 采集端帧率覆盖失败: \(error.localizedDescription)")
        }

        // 输出端尽量同步（若你本地是 internal，可移除此调用）
        do { try await mixer.setFrameRate(Float64(clamped)) } catch {
            print("⚠️ 混合器帧率设置失败或不可用，将跟随采集端: \(error.localizedDescription)")
        }
        // ... existing code ...
    }*/
    
    
    
    
    

    // MARK: - 档位热切（同时更新预览流和推流流）
    /*
    func hotApplyProfile(_ profile: StreamProfile) {
        guard let preset = StreamPreset.table[profile] else { return }
        Task.detached { [weak self] in
            guard let self = self else { return }
            do {
                
                // 先同步采集端 fps，降低编码/采集不一致造成的停帧风险
                // try? await self.applyFPSOverride(preset.fps)
                
                var v = VideoCodecSettings(
                    videoSize: CGSize(width: preset.width, height: preset.height),
                    bitRate: preset.videoBitrateKbps * 1000,
                    profileLevel: preset.h264ProfileLevel,
                    maxKeyFrameIntervalDuration: Int32(preset.keyframeIntervalSec),
                    dataRateLimits: nil,
                    isHardwareEncoderEnabled: true
                )
                v.allowFrameReordering = false

                // 推流中的 pubStream（如有）
                if let s = self.pubStream {
                    try await s.setVideoSettings(v)
                }
                // 预览流
                try await self.stream.setVideoSettings(v)

                await MainActor.run {
                    self.currentProfile = profile
                    self.width = preset.width
                    self.height = preset.height
                    self.fps = preset.fps
                    self.bitrateKbps = preset.videoBitrateKbps
                    print("♻️ 热切档位：\(profile.rawValue) \(preset.width)x\(preset.height) @\(preset.videoBitrateKbps)kbps")
                }
                // 统一同步当前 fps（默认 60 或后端覆盖）
                try? await self.applyFPSOverride(self.fps)
            } catch {
                await MainActor.run { print("❌ 热切档位失败: \(error.localizedDescription)") }
            }
        }
    }*/
    
    /*
    // 方法：hotApplyProfile(_:)（顺序化重配：采集→预览→推流，避免推流死锁）
    func hotApplyProfile(_ profile: StreamProfile) {
        // ... existing code ...
        guard let preset = StreamPreset.table[profile] else { return }
        Task.detached { [weak self] in
            guard let self = self else { return }
            do {
                await MainActor.run { self.isSwitchingProfile = true }

                var v = VideoCodecSettings(
                    videoSize: CGSize(width: preset.width, height: preset.height),
                    bitRate: preset.videoBitrateKbps * 1000,
                    profileLevel: preset.h264ProfileLevel,
                    maxKeyFrameIntervalDuration: Int32(preset.keyframeIntervalSec),
                    dataRateLimits: nil,
                    isHardwareEncoderEnabled: true
                )
                v.allowFrameReordering = false

                // 先更新本地状态（供 applyFPSOverride 选 format）
                await MainActor.run {
                    self.currentProfile = profile
                    self.width = preset.width
                    self.height = preset.height
                    self.fps = preset.fps
                    self.bitrateKbps = preset.videoBitrateKbps
                    print("♻️ 热切档位：\(profile.rawValue) \(preset.width)x\(preset.height) @\(preset.videoBitrateKbps)kbps")
                }

                // 1) 采集端：一次性对齐新 fps + 分辨率
                try? await self.applyFPSOverride(self.fps)

                // 2) 预览流：先重配（更宽松，避免与推流侧并发）
                try await self.stream.setVideoSettings(v)

                // 3) 给硬编器留一点缓冲时间，再重配推流侧
                try await Task.sleep(nanoseconds: 120_000_000)
                if let s = self.pubStream {
                    try await s.setVideoSettings(v)
                }

                await MainActor.run { self.isSwitchingProfile = false }
            } catch {
                await MainActor.run {
                    self.isSwitchingProfile = false
                    print("❌ 热切档位失败: \(error.localizedDescription)")
                }
            }
        }
        // ... existing code ...
    }*/
    
    
    // 方法：hotApplyProfile(_:)（顺序化：更新状态→采集端 fps→预览流→推流流）
    func hotApplyProfile(_ profile: StreamProfile) {
        // ... existing code ...
        guard let preset = StreamPreset.table[profile] else { return }
        Task.detached { [weak self] in
            guard let self = self else { return }
            do {
                await MainActor.run { self.isSwitchingProfile = true }

                var v = VideoCodecSettings(
                    videoSize: CGSize(width: preset.width, height: preset.height),
                    bitRate: preset.videoBitrateKbps * 1000,
                    profileLevel: preset.h264ProfileLevel,
                    maxKeyFrameIntervalDuration: Int32(preset.keyframeIntervalSec),
                    dataRateLimits: nil,
                    isHardwareEncoderEnabled: true
                )
                v.allowFrameReordering = false

                // 先更新本地状态（供 applyFPSOverride 参考）
                await MainActor.run {
                    self.currentProfile = profile
                    self.width = preset.width
                    self.height = preset.height
                    self.fps = preset.fps
                    self.bitrateKbps = preset.videoBitrateKbps
                    print("♻️ 热切档位：\(profile.rawValue) \(preset.width)x\(preset.height) @\(preset.videoBitrateKbps)kbps")
                }

                // ① 采集端对齐新 fps（保持当前 format，避免停帧）
                try? await self.applyFPSOverride(self.fps)

                // ② 预览流重配（先做，风险更低）
                try await self.stream.setVideoSettings(v)

                // ③ 若在推流，再稍作缓冲后重配推流流
                try await Task.sleep(nanoseconds: 120_000_000)
                if let s = self.pubStream { try await s.setVideoSettings(v) }

                await MainActor.run { self.isSwitchingProfile = false }
            } catch {
                await MainActor.run {
                    self.isSwitchingProfile = false
                    print("❌ 热切档位失败: \(error.localizedDescription)")
                }
            }
        }
        // ... existing code ...
    }
    
    
    
    
    // MARK: - 停止推流（await 版本，主线程安全）
        @MainActor
        func stopAndReset() async {
            // 切监听回预览流
            statusTask?.cancel(); statusTask = nil
            connectionTask?.cancel(); connectionTask = nil
            setupStatusMonitoring() // 这时监听会绑定到预览流

            // 快照一下 pubStream 引用，随后置空
            let s = self.pubStream
            self.pubStream = nil
            self.isPublishing = false

            // 解绑 mixer → pubStream，避免残留占用
            if let s {
                await mixer.removeOutput(s)
                do {
                    // 有些版本有 unpublish()，没有就 close()
                    //if (try? await s.unpublish()) == nil {
                        try await s.close()
                    //}
                    print("⏹️ 推流已停止（pubStream 断开）")
                } catch {
                    print("ℹ️ stop 提示（可忽略）: \(error.localizedDescription)")
                }
            } else {
                print("ℹ️ 无活动的 pubStream，跳过 close")
            }
        }

        // 兼容老调用：非 await 的 stop()
        

        // MARK: - 彻底释放（await 版本）
       
        
    
        @MainActor
        func destroyAll() async {
            await _cleanupPublishSide()
            do { try await stream.close() } catch { print("ℹ️ close preview stream: \(error.localizedDescription)") }
            statusTask?.cancel(); statusTask = nil
            connectionTask?.cancel(); connectionTask = nil
            NotificationCenter.default.removeObserver(self)
            hasAttachedCamera = false
            print("✅ LiveManager 已彻底释放")
        }
        func destroy() { Task { @MainActor in await destroyAll() } }


}

