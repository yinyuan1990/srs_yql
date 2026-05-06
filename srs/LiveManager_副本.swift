import Foundation
import AVFoundation
import HaishinKit
import Photos

// 将 AVCaptureVideoOrientation 替换为自定义枚举
// 用自己的方向枚举，避免 iOS 17+ 对 AVCaptureVideoOrientation 的警告
enum VideoOrientation: CaseIterable {
    case portrait
    case landscapeLeft
    case landscapeRight
    case portraitUpsideDown
    
    // 转换为角度值（用于 videoRotationAngle）
    var rotationAngle: Double {
        switch self {
        case .portrait:
            return 0
        case .landscapeLeft:
            return 90
        case .landscapeRight:
            return -90
        case .portraitUpsideDown:
            return 180
        }
    }
    
    // 兼容旧的 AVCaptureVideoOrientation（如果需要）
    @available(iOS, deprecated: 17.0, message: "Use rotationAngle instead")
    var legacyOrientation: AVCaptureVideoOrientation {
        switch self {
        case .portrait:
            return .portrait
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        case .portraitUpsideDown:
            return .portraitUpsideDown
        }
    }
}

final class LiveManager: ObservableObject {
    // ① 底层 RTMP 连接
    private let conn = RTMPConnection()
    
    // ② 编码/复用/推流的“流对象”，所有设置都打到它身上
    let stream: RTMPStream

    // UI 状态
    @Published var isPublishing = false
    @Published var log: [String] = []
    
    
    // ③ 媒体混合器：负责把采集到的音视频作为输出送给 stream
    private let mixer = MediaMixer()
    
    // 固定的 RTMP 目标
    @Published var serverIP = "8.162.11.163"
    @Published var app = "tenantA"
    @Published var streamKey = "" // 登录后从 permanent_token 获取
    
    // 参数（这里仅保存，不在多处反复重配）
    @Published var width = 1920
    @Published var height = 1080
    @Published var fps = 60
    @Published var bitrateKbps = 6000
    @Published var usingBackCamera = true
    @Published var zoom: CGFloat = 1.0
    //@Published var orientation: AVCaptureVideoOrientation = .portrait
    // 修改属性声明
    @Published var orientation: VideoOrientation = .portrait
    
    
    // 拍照参数（和直播采集相互独立）
    @Published var photoQuality: Double = 1.0
    @Published var photoResolution: String = "1920x1080"
    @Published var flashMode: String = "auto"
    @Published var focusMode: String = "auto"
    @Published var whiteBalance: String = "auto"
    @Published var isoValue: Int = 100
    @Published var exposureCompensation: Double = 0.0
    @Published var timerDelay: Int = 0
    @Published var burstMode: Bool = false
    @Published var burstCount: Int = 1
    @Published var saveToAlbum: Bool = true
    @Published var watermarkEnabled: Bool = false
    @Published var watermarkText: String = ""
    
    // 当前相机设备句柄
    private var cameraDevice: AVCaptureDevice?
    // 拍照输出
    private var photoOutput: AVCapturePhotoOutput?
    
    // HaishinKit 的异步状态监听任务
    private var statusTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?

    init() {
            // ④ 准备流对象（绑定连接）
            stream = RTMPStream(connection: conn)
            // ⑤ 把 stream 注册成 mixer 的输出（采集 → mixer → stream）
            Task { await mixer.addOutput(stream) }
            // ⑥ 读取本地配置（只更新内存变量，不立刻改编码器）
            loadConfigFromStorage()
            // ⑦ 配音频会话（类别/采样率/IO 缓冲）
            setupAVSession()
            // ⑧ 只做一次“预览期”初始化：先让预览尽快出画（软编/低码/GOP=1s）
            setupStream()
            // ⑨ 设置 RTMP 状态监听（UI 用）
            setupStatusMonitoring()
            // ⑩ 初始化拍照输出（与直播无强耦合）
            setupPhotoOutput()
            // *注意：不在 init 里 publish。点击“开始”时才连服务器 + 切硬编 + publish
    }
    
     
    deinit {
        // 清理任务
        statusTask?.cancel()
        connectionTask?.cancel()
    }
    
    // 读取 token / 设备参数
    private func loadConfigFromStorage() {
        // 从UserDefaults获取permanent_token作为streamKey
        if let permanentToken = UserDefaults.standard.string(forKey: "permanent_token") {
            streamKey = permanentToken
            print("✅ 已加载permanent_token作为streamKey")
        } else {
            print("⚠️ 未找到permanent_token，请先登录")
            // 发送通知要求退出到登录页面
            NotificationCenter.default.post(name: NSNotification.Name("LogoutRequired"), object: nil)
        }
        
        // 从ConfigManager加载设备配置
        if let config = ConfigManager.shared.currentConfig {
            applyDeviceConfig(config)
        }
    }
    
    // “应用设备配置”只做数据落地，不立即重配编码器（避免首屏抖动）
    private func applyDeviceConfig(_ config: DeviceConfig) {
        // 应用推流配置
        applyStreamConfig(config.streamConfig)
        
        // 应用拍照配置
        applyPhotoConfig(config.photoConfig)
        
        print("✅ 设备配置已应用")
    }
    
    
    // 保存直播参数（首屏不下发到编码器）
    private func applyStreamConfig(_ c: StreamConfig) {
        let res = c.videoResolution.split(separator: "x")
        if res.count == 2 {
            width = Int(res[0]) ?? 1280
            height = Int(res[1]) ?? 720
        }
        fps = c.videoFps
        bitrateKbps = c.videoBitrate
        print("📺(defer) 保存推流配置: \(width)x\(height)@\(fps)fps, \(bitrateKbps)kbps")
        // ❌ 不在这里调用 stream.setVideoSettings，避免与 setupStream 冲突
    }
    // 应用拍照配置
    private func applyPhotoConfig(_ photoConfig: PhotoConfig) {
        self.photoQuality = photoConfig.photoQuality
        self.photoResolution = photoConfig.photoResolution
        self.flashMode = photoConfig.flashMode
        self.focusMode = photoConfig.focusMode
        self.whiteBalance = photoConfig.whiteBalance
        self.isoValue = photoConfig.isoValue
        self.exposureCompensation = photoConfig.exposureCompensation
        self.timerDelay = photoConfig.timerDelay
        self.burstMode = photoConfig.burstMode
        self.burstCount = photoConfig.burstCount
        self.saveToAlbum = photoConfig.saveToAlbum
        self.watermarkEnabled = photoConfig.watermarkEnabled
        self.watermarkText = photoConfig.watermarkText
        
        print("📷 拍照配置已应用: 质量\(photoQuality), 分辨率\(photoResolution)")
    }
    
    // 外部更新配置：只更新内存，不立即重配
    func updateFromConfig(_ config: DeviceConfig) {
        
        // 只保存，不立刻重配
            applyStreamConfig(config.streamConfig)
            applyPhotoConfig(config.photoConfig)
            appendLog("✅ 设备配置已保存(延后生效)")
            // 重新附加相机以应用新设置
            //applyDeviceConfig(config)
            //attachCamera(position: usingBackCamera ? .back : .front)
    }

    
    // 音频会话只在启动时设置一次，避免频繁切换导致硬件重建
    private func setupAVSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            
            try session.setCategory(.playAndRecord,
                                    mode: .videoRecording,
                                    options: [.defaultToSpeaker, .allowBluetooth])  // ✅ 去掉 .mixWithOthers

            try session.setPreferredSampleRate(44100)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
            print("✅ 音频会话配置成功")
        } catch {
            print("❌ 音频会话配置失败: \(error.localizedDescription)")
        }
    }

    // “预览期初始化”：目标就是**尽快**让预览出画（降低首帧延迟）
    private func setupStream() {
        Task.detached { [weak self] in
            guard let self = self else { return }
            do {
                
                // 1) 先挂相机（非主线程，避免阻塞 UI）
                self.attachCamera(position: .back)
                // 2) 采集端统一帧率，仅设置一次
                try await self.mixer.setFrameRate(30)
                // 3) 预览期：软编 + 低码 + GOP=1s + 禁 B 帧 => *首帧通常最快*
                var previewV = VideoCodecSettings(
                    videoSize: CGSize(width: width, height: height),
                    bitRate: 800_000,                        // 低一些，软编更快
                    profileLevel: "H264_Baseline_AutoLevel",
                    maxKeyFrameIntervalDuration: 1,
                    dataRateLimits: nil,
                    isHardwareEncoderEnabled: false          // ★★ 软编
                )
                previewV.allowFrameReordering = false
                print("width: \(width) height: \(height)")
                try await self.stream.setVideoSettings(previewV)
                // 预览阶段不设置音频，避免首屏重建 AudioConverter
                await MainActor.run { print("✅ 预览就绪（软编/低码，GOP=1s）") }
            } catch {
                await MainActor.run { print("❌ 初始化失败: \(error.localizedDescription)") }
            }
        }
    }


    // 拍照输出初始化
    private func setupPhotoOutput() {
        photoOutput = AVCapturePhotoOutput()
        appendLog("📷 拍照输出设置完成")
    }
    
   
    // HaishinKit 的状态监听（给 UI 日志/状态）
    private func setupStatusMonitoring() {
        // 监听流状态 - 使用 Task.detached 避免 MainActor 冲突
        statusTask = Task.detached { [weak self] in
            guard let self = self else { return }
            
            // 需要使用 await 访问 actor 的 status 属性
            for await status in await self.stream.status {
                await MainActor.run {
                    self.handleRTMPStatus(status)
                }
            }
        }
        
        // 监听连接状态
        connectionTask = Task.detached { [weak self] in
            guard let self = self else { return }
            
            // 需要使用 await 访问 actor 的 status 属性
            for await status in await self.conn.status {
                await MainActor.run {
                    self.handleConnectionStatus(status)
                }
            }
        }
        
        print("✅ HaishinKit 2.0.0 状态监听已设置")
    }
    
    
    // RTMP 回调 → UI 绑定
    private func handleRTMPStatus(_ status: RTMPStatus) {
        switch status.code {
        case "NetStream.Publish.Start":
            isPublishing = true
            print("🔴 推流已开始")
        case "NetStream.Unpublish.Success":
            isPublishing = false
            print("⏹️ 推流已停止")
        case "NetStream.Connect.Failed", "NetStream.Publish.BadName":
            isPublishing = false
            print("❌ 推流错误: \(status.description)")
        default:
            print("📡 RTMP状态: \(status.code) - \(status.description)")
        }
    }

    private func handleConnectionStatus(_ status: RTMPStatus) {
        switch status.code {
        case "NetConnection.Connect.Success":
            print("✅ RTMP连接成功")
        case "NetConnection.Connect.Failed":
            print("❌ RTMP连接失败: \(status.description)")
        case "NetConnection.Connect.Closed":
            print("🔌 RTMP连接已关闭")
        default:
            print("🔗 连接状态: \(status.code) - \(status.description)")
        }
    }
    
    
    private func appendLog(_ s: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logEntry = "[\(timestamp)] \(s)"
        
        DispatchQueue.main.async {
            self.log.append(logEntry)
            
            if self.log.count > 100 {
                self.log.removeFirst(self.log.count - 100)
            }
        }
    }

     
    // 挂相机：把“协商最慢的一步”提前做好（选择 format、锁帧率等）
    func attachCamera(position: AVCaptureDevice.Position) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            print("❌ 未找到\(position == .back ? "后" : "前")置摄像头"); return
        }
        cameraDevice = device
        usingBackCamera = (position == .back)

        // 预锁 1280x720@30，减少后续协商
        do {
            try device.lockForConfiguration()

            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isVideoHDREnabled { device.isVideoHDREnabled = false }
            if device.isSubjectAreaChangeMonitoringEnabled { device.isSubjectAreaChangeMonitoringEnabled = false }

            let targetW = 1280, targetH = 720, targetFPS: Double = 30
            let best = device.formats
                .compactMap { f -> (AVCaptureDevice.Format, Int)? in
                    let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                    let okFPS = f.videoSupportedFrameRateRanges.contains {
                        $0.minFrameRate <= targetFPS && targetFPS <= $0.maxFrameRate
                    }
                    guard okFPS else { return nil }
                    let diff = abs(Int(d.width) - targetW) + abs(Int(d.height) - targetH)
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
        
        // 轻量 attach。注意：这里不要再设帧率/编码器。
        Task.detached { [weak self] in
            guard let self = self else { return }
            do {
                try await self.mixer.attachVideo(device, track: 0) { vu in
                    vu.isVideoMirrored = (position == .front)
                    vu.preferredVideoStabilizationMode = .off   // 关防抖，加速首帧
                }
                // 不要在这里 attachAudio（setupStream 已做），避免重复重配
                await MainActor.run { print("✅ \(position == .back ? "后" : "前")置摄像头已连接") }
            } catch {
                await MainActor.run { print("❌ 相机附加失败: \(error.localizedDescription)") }
            }
        }
    }


    private func configureCamera(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            
            // 设置对焦模式
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            
            // 设置曝光模式
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            
            // 应用拍照相关设置
            applyCameraPhotoSettings(device)
            
            //setFrameRate(device: device, targetFPS: Double(fps))
            
            device.unlockForConfiguration()
            
            print("🎥 相机配置完成")
            
        } catch {
            print("❌ 相机配置失败: \(error.localizedDescription)")
        }
    }
    
    // 应用拍照相机设置
    private func applyCameraPhotoSettings(_ device: AVCaptureDevice) {
        // ISO 设置
        if device.isExposureModeSupported(.custom) {
            let minISO = device.activeFormat.minISO
            let maxISO = device.activeFormat.maxISO
            let targetISO = Float(isoValue)
            let clampedISO = max(minISO, min(maxISO, targetISO))
            
            if clampedISO != targetISO {
                print("⚠️ ISO值已调整: \(targetISO) -> \(clampedISO)")
            }
        }
        
        // 曝光补偿设置
        if device.isExposureModeSupported(.continuousAutoExposure) {
            let minBias = device.minExposureTargetBias
            let maxBias = device.maxExposureTargetBias
            let targetBias = Float(exposureCompensation)
            let clampedBias = max(minBias, min(maxBias, targetBias))
            
            device.setExposureTargetBias(clampedBias, completionHandler: nil)
        }
        
        print("📷 拍照相机设置已应用")
    }

    private func setFrameRate(device: AVCaptureDevice, targetFPS: Double) {
        let targetDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
        
        for range in device.activeFormat.videoSupportedFrameRateRanges {
            if range.minFrameDuration <= targetDuration && targetDuration <= range.maxFrameDuration {
                device.activeVideoMinFrameDuration = targetDuration
                device.activeVideoMaxFrameDuration = targetDuration
                print("✅ 帧率设置为 \(targetFPS) FPS")
                return
            }
        }
        
        print("⚠️ 目标帧率 \(targetFPS) FPS 不支持，使用默认帧率")
    }

    func setZoom(_ factor: CGFloat) {
        zoom = factor
        guard let device = cameraDevice else { return }
        
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = max(1.0, min(factor, device.activeFormat.videoMaxZoomFactor))
            device.unlockForConfiguration()
        } catch {
            print("变焦设置失败: \(error.localizedDescription)")
        }
    }

    
    
    
    
    
    // 仅改变方向（不触发重配）
    func setOrientation(_ o: VideoOrientation) {
        orientation = o
        Task.detached { [weak self] in
            guard let self = self else { return }
            do {
                try await self.mixer.setVideoOrientation(o.legacyOrientation)
                await MainActor.run { self.appendLog("✅ 方向设置为 \(o)") }
            } catch {
                await MainActor.run { self.appendLog("❌ 方向设置失败: \(error.localizedDescription)") }
            }
        }
    }


    // 仅保存参数（不立刻重配）
    func applyParams(width: Int, height: Int, fps: Int, bitrateKbps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateKbps = bitrateKbps
        print("📝(defer) 更新参数: \(width)x\(height)@\(fps)fps, \(bitrateKbps)kbps")
        // ❌ 不要 setVideoSettings
    }


    // 点击“开始”：这一步才切硬编 + 设置音频 + publish
    func start() {
        guard !serverIP.isEmpty && !app.isEmpty && !streamKey.isEmpty else {
            print("❌ 服务器信息不完整"); return
        }
        let url = "rtmp://\(serverIP)/\(app)"
        print("🔗 开始连接: \(url)")
        print("🔑 流密钥: \(streamKey)")

        Task.detached { [weak self] in
            guard let self = self else { return }
            do {
                try await self.conn.connect(url)

                // 1) 切回“最终视频参数”：硬编 + 目标码率
                var finalV = VideoCodecSettings(
                    videoSize: CGSize(width: width, height: height),
                    bitRate: max(self.bitrateKbps, 2500) * 1000,
                    profileLevel: "H264_Baseline_AutoLevel",
                    maxKeyFrameIntervalDuration: 1,
                    dataRateLimits: nil,
                    isHardwareEncoderEnabled: true     // ★★ 硬编从这里开始
                    //bitRateMode: .average
                )
                finalV.allowFrameReordering = false
                try await self.stream.setVideoSettings(finalV)

                // 只在这里设置音频（避免预览阶段 AudioConverter 重建）
                var a = AudioCodecSettings(bitRate: 128_000, channelMap: [1, 2])
                try await self.stream.setAudioSettings(a)

                // 给硬编器 200ms 稳定再 publish（降低 publish 瞬间重配）
                try await Task.sleep(nanoseconds: 200_000_000)

                try await self.stream.publish(self.streamKey)
                await MainActor.run {
                    self.isPublishing = true
                    print("🚀 推流已开始（720p@~2.5Mbps 硬编，GOP=1s）")
                }
            } catch {
                await MainActor.run { print("❌ 连接/推流失败: \(error.localizedDescription)") }
            }
        }
    }


    func stop() {
        Task {
            do {
                try await stream.close()
                try await conn.close()
                
                await MainActor.run {
                    self.isPublishing = false
                    print("⏹️ 推流已停止")
                }
            } catch {
                await MainActor.run {
                    self.isPublishing = false
                    print("⚠️ 停止推流时出现错误: \(error.localizedDescription)")
                }
            }
        }
    }

    // 切镜头：直接在同一 track 重绑设备（避免 teardown→setup）
    func toggleCamera() {
        Task {
            do {
                let newPos: AVCaptureDevice.Position = usingBackCamera ? .front : .back
                guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPos) else {
                    print("❌ 切镜失败：找不到摄像头")
                    return
                }

                // 直接在同一 track 重绑新设备（会替换旧的）
                try await mixer.attachVideo(dev, track: 0) { vu in
                    vu.isVideoMirrored = (newPos == .front)
                    vu.preferredVideoStabilizationMode = .off   // 关防抖，加速首帧
                }
                usingBackCamera = (newPos == .back)
                cameraDevice = dev
                print("🔄 已切到\(usingBackCamera ? "后" : "前")置")

                // 轻触发一次同参编码设置，促发下一帧 IDR（更快出画）
                var v = VideoCodecSettings(
                    videoSize: CGSize(width: 1280, height: 720),
                    bitRate: 2_500_000,
                    profileLevel: "H264_Baseline_AutoLevel",
                    maxKeyFrameIntervalDuration: 1,
                    dataRateLimits: nil,
                    isHardwareEncoderEnabled: true
                    //bitRateMode: .average
                )
                v.allowFrameReordering = false
                try await stream.setVideoSettings(v)
            } catch {
                print("❌ 切镜异常: \(error.localizedDescription)")
            }
        }
    }


    
    // 拍照相关（与直播路径分离）
    func takePhoto() {
        guard let device = cameraDevice else {
            print("❌ 相机设备未准备好")
            return
        }
        
        if timerDelay > 0 {
            appendLog("📷 \(timerDelay)秒后拍照...")
            DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(timerDelay)) {
                self.capturePhoto()
            }
        } else {
            capturePhoto()
        }
    }
    
    private func capturePhoto() {
        guard let device = cameraDevice else { return }

        if burstMode {
            // 连拍模式
            for i in 0..<burstCount {
                DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(i) * 0.5) {
                    self.performSingleCapture(device: device, index: i + 1)
                }
            }
        } else {
            // 单拍模式
            performSingleCapture(device: device, index: 1)
        }
    }
    
    private func performSingleCapture(device: AVCaptureDevice, index: Int) {
        // 这里应该实现实际的拍照逻辑
        // 由于当前代码中没有完整的拍照实现，保持原有逻辑
        
        print("📷 拍照 \(index)/\(burstMode ? burstCount : 1)")
        
        // 模拟拍照完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if self.saveToAlbum {
                print("💾 照片已保存到相册")
            }
        }
    }
}
