import AVFoundation
import CoreMedia
import CoreVideo
import WebRTC

final class CustomAVCaptureVideoCapturer: RTCVideoCapturer {
    /// 冗余诊断日志（白平衡/亮度/对焦/帧率等运行期 print）统一走此 gate，
    /// 受 WebRTCManager.verboseLogEnabled 控制，默认关闭；错误 print（❌）不走此函数，始终输出。
    private func vlog(_ message: @autoclosure () -> String) {
        guard WebRTCManager.verboseLogEnabled else { return }
        print(message())
    }

    let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "custom.avcapture.session")
    private let videoQueue = DispatchQueue(label: "custom.avcapture.video", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private(set) var currentDevice: AVCaptureDevice?
    private var lockedWhiteBalanceGains: AVCaptureDevice.WhiteBalanceGains?
    private var baseISO: Float?
    private var baseBrightnessISO: Float?
    private var brightnessGeneration: Int = 0
    private var hardwareEV: Float = 0
    private var lockedDuration: CMTime?
    private var lockedISO: Float?
    private var videoHDREnabled = false
    private var autoHDREnabled = false
    private var autoWhiteBalanceEnabled = false
    private var lastAutoWhiteBalanceRefreshAt: TimeInterval = 0
    private var autoWhiteBalanceRefreshInFlight = false
    private let autoWhiteBalanceRefreshInterval: TimeInterval = 2.0
    private var outputPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    // 🚑 2026-07-02「切档概率卡死」修复：记录最近一次会话配置，供
    //    ① configureSession 失败自动重试 ② AVCaptureSessionRuntimeError 自动重建
    //    ③ WebRTCManager 采集看门狗兜底重建 使用。全部在 sessionQueue 上读写。
    private var lastConfigDevice: AVCaptureDevice?
    private var lastConfigFormat: AVCaptureDevice.Format?
    private var lastConfigFps: Int = 30
    private var configureRetryCount = 0
    private let maxConfigureRetries = 3
    // ⭐ 2026-08-16 修「切分辨率画面闪转」：重配会话时直接套用的期望方向/镜像，
    //   由 WebRTCManager.applyMountTransform 保持同步（App 强制横屏，默认 landscapeRight）。
    var desiredOrientation: AVCaptureVideoOrientation = .landscapeRight
    var desiredMirrored: Bool = false
    private var wbTemperature: Float = 0
    private var wbTint: Float = 0
    private var wbRed: Float = 0
    private var wbGreen: Float = 0
    private var wbBlue: Float = 0
    private var wbBlack: Float = 0
    private var wbWhite: Float = 0
    private var wbAmber: Float = 0
    private var wbAdjustmentBaseGains: AVCaptureDevice.WhiteBalanceGains?

    struct WhiteBalanceStatus {
        let isAuto: Bool
        let displayText: String
        let kelvin: Float
    }

    var currentVideoInput: AVCaptureDeviceInput? {
        captureSession.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first { $0.device.hasMediaType(.video) }
    }

    override init(delegate: RTCVideoCapturerDelegate) {
        super.init(delegate: delegate)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        applyVideoOutputPixelFormat()
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        // 🚑 会话级错误/中断恢复：切档重配置期间偶发 runtime error（-11819 媒体服务重置、
        //    相机被抢占等）会让 session 永久停止吐帧＝画面卡死；原代码完全没监听，无法自愈。
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionRuntimeError(_:)),
                                               name: .AVCaptureSessionRuntimeError,
                                               object: captureSession)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionInterruptionEnded(_:)),
                                               name: .AVCaptureSessionInterruptionEnded,
                                               object: captureSession)
        // ⭐ §53.14：**中断开始**此前完全没记。排「首次连接手机端不出画面、睡眠一次才好」
        //   必须知道相机是不是被系统中断了、以及中断原因（多前台App抢占/被其它客户端占用/
        //   音频设备冲突…）。原因码直接决定是我们的 bug 还是系统行为。
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionWasInterrupted(_:)),
                                               name: .AVCaptureSessionWasInterrupted,
                                               object: captureSession)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionDidStartRunning(_:)),
                                               name: .AVCaptureSessionDidStartRunning,
                                               object: captureSession)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionDidStopRunning(_:)),
                                               name: .AVCaptureSessionDidStopRunning,
                                               object: captureSession)
    }

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        let raw = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? -1
        let reason: String
        switch AVCaptureSession.InterruptionReason(rawValue: raw) {
        case .videoDeviceNotAvailableInBackground: reason = "后台不可用(正常)"
        case .audioDeviceInUseByAnotherClient:     reason = "音频被其它App占用"
        case .videoDeviceInUseByAnotherClient:     reason = "相机被其它App占用"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: reason = "多前台App(分屏/画中画)"
        case .videoDeviceNotAvailableDueToSystemPressure:        reason = "系统压力(过热/资源不足)"
        default: reason = "未知(\(raw))"
        }
        print("⚠️ [CustomCapture] 采集会话被中断: \(reason)")
    }

    @objc private func sessionDidStartRunning(_ notification: Notification) {
        print("▶️ [CustomCapture] 采集会话已启动(startRunning)")
    }

    @objc private func sessionDidStopRunning(_ notification: Notification) {
        print("⏹️ [CustomCapture] 采集会话已停止(stopRunning)")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 🚑 会话错误恢复（2026-07-02 切档概率卡死修复）

    @objc private func sessionRuntimeError(_ notification: Notification) {
        let err = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        print("❌ [CustomCapture] 会话运行时错误: \(err?.localizedDescription ?? "unknown") code=\(err.map { String($0.code) } ?? "?") → 0.3s 后自动重建")
        sessionQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.configureRetryCount = 0
            self.rebuildSessionFromLastConfig(reason: "runtimeError")
        }
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.captureSession.isRunning {
                print("🚑 [CustomCapture] 会话中断结束 → startRunning 恢复")
                self.captureSession.startRunning()
            }
        }
    }

    /// 🚑 用最近一次配置整体重建会话。必须在 sessionQueue 上调用。
    private func rebuildSessionFromLastConfig(reason: String) {
        guard let device = lastConfigDevice, let format = lastConfigFormat else {
            print("⚠️ [CustomCapture] 无历史配置可重建(\(reason))")
            return
        }
        print("🚑 [CustomCapture] 重建采集会话(\(reason)): \(device.localizedName) fps=\(lastConfigFps)")
        let ok = configureSession(device: device, format: format, fps: lastConfigFps)
        if !captureSession.isRunning { captureSession.startRunning() }
        if !ok { scheduleConfigureRetry(reason: reason) }
    }

    /// 🚑 配置失败重试（0.4s 间隔，最多 maxConfigureRetries 次）。
    ///    典型失败场景：切档瞬间相机被 HAL 短暂占用 → AVCaptureDeviceInput 创建抛错 /
    ///    canAddInput=false，原代码只 print 就 commit 了一个「没有输入」的会话 → 永久无帧。
    private func scheduleConfigureRetry(reason: String) {
        guard configureRetryCount < maxConfigureRetries else {
            print("❌ [CustomCapture] 配置重试 \(maxConfigureRetries) 次仍失败(\(reason))，等待采集看门狗兜底")
            return
        }
        configureRetryCount += 1
        let attempt = configureRetryCount
        print("🚑 [CustomCapture] 配置失败(\(reason)) → 0.4s 后重试 第\(attempt)/\(maxConfigureRetries)次")
        sessionQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let device = self.lastConfigDevice, let format = self.lastConfigFormat else { return }
            let ok = self.configureSession(device: device, format: format, fps: self.lastConfigFps)
            if !self.captureSession.isRunning { self.captureSession.startRunning() }
            if ok {
                self.configureRetryCount = 0
                print("✅ [CustomCapture] 配置重试成功(第\(attempt)次)")
            } else {
                self.scheduleConfigureRetry(reason: reason)
            }
        }
    }

    /// 🚑 采集看门狗兜底入口：推流中长时间无帧时由 WebRTCManager 调用，整体重建会话。
    func restartSessionFromLastConfig() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureRetryCount = 0
            self.rebuildSessionFromLastConfig(reason: "watchdog")
        }
    }

    static func captureDevices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera, .builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices
    }

    static func supportedFormats(for device: AVCaptureDevice) -> [AVCaptureDevice.Format] {
        device.formats
    }

    func setDelegate(_ delegate: RTCVideoCapturerDelegate) {
        self.delegate = delegate
    }

    func setOutputPixelFormat(_ pixelFormat: OSType) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.outputPixelFormat = pixelFormat
            self.applyVideoOutputPixelFormat()
            let name = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? "420v" : "420f"
            vlog("🧪 [CustomCapture] outputPixelFormat=\(name)")
        }
    }

    private func applyVideoOutputPixelFormat() {
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: outputPixelFormat
        ]
    }

    func queryWhiteBalanceStatus(completion: @escaping (WhiteBalanceStatus) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else {
                DispatchQueue.main.async {
                    completion(WhiteBalanceStatus(isAuto: false, displayText: "--", kelvin: 0))
                }
                return
            }
            let mode = device.whiteBalanceMode
            let gains = self.normalizedGains(device.deviceWhiteBalanceGains, for: device)
            let kelvin = device.temperatureAndTintValues(for: gains).temperature
            let isAuto = mode == .continuousAutoWhiteBalance || mode == .autoWhiteBalance
            let modeText = isAuto ? "自动" : "手动"
            let text = "\(modeText) \(Int(kelvin))K"
            DispatchQueue.main.async {
                completion(WhiteBalanceStatus(isAuto: isAuto, displayText: text, kelvin: kelvin))
            }
        }
    }

    func applyWhiteBalanceAdjustment(temperature: Float, tint: Float, red: Float, green: Float, blue: Float, black: Float, white: Float, amber: Float) {
        wbTemperature = max(-1, min(1, temperature))
        wbTint = max(-1, min(1, tint))
        wbRed = max(-1, min(1, red))
        wbGreen = max(-1, min(1, green))
        wbBlue = max(-1, min(1, blue))
        wbBlack = max(-1, min(1, black))
        wbWhite = max(-1, min(1, white))
        wbAmber = max(-1, min(1, amber))
        sessionQueue.async { [weak self] in
            self?.applyWhiteBalanceAdjustmentLocked()
        }
    }

    func resetWhiteBalanceAdjustment() {
        wbTemperature = 0
        wbTint = 0
        wbRed = 0
        wbGreen = 0
        wbBlue = 0
        wbBlack = 0
        wbWhite = 0
        wbAmber = 0
        sessionQueue.async { [weak self] in
            self?.restoreWhiteBalanceBaseLocked()
        }
    }

    private func restoreWhiteBalanceBaseLocked() {
        guard let device = currentDevice else { return }
        do {
            try device.lockForConfiguration()
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                enableContinuousWhiteBalanceLocked(device)
                vlog("🎨 [CustomCapture] WB reset → auto")
            }
            device.unlockForConfiguration()
        } catch {
            print("❌ [CustomCapture] 白平衡重置失败: \(error.localizedDescription)")
        }
    }

    private func applyWhiteBalanceAdjustmentLocked() {
        guard currentDevice != nil else { return }
        if wbTemperature == 0 && wbTint == 0 && wbRed == 0 && wbGreen == 0
            && wbBlue == 0 && wbBlack == 0 && wbWhite == 0 && wbAmber == 0 {
            return
        }
        applyContinuousWhiteBalance()
        vlog("🎨 [CustomCapture] WB adjustment ignored, keep continuous auto WB")
    }

    func applyShutter(_ shutterSpeed: Int, preserveCurrentISO: Bool) {
        guard let device = currentDevice else {
            print("⚠️ [CustomCapture] applyShutter skipped: device nil")
            return
        }
        let snapped = snapToAntiFlicker(shutterSpeed)
        let desired = CMTime(value: 1, timescale: CMTimeScale(snapped))

        do {
            try device.lockForConfiguration()
            // 🚑 2026-07-02：曝光时长上限再叠加当前帧间隔（activeVideoMaxFrameDuration），
            //    防止「慢快门 + 高帧率档位」组合超出帧间隔导致 HAL 概率性停摆（与 configureSession 同理）。
            var upperBound = device.activeFormat.maxExposureDuration
            let frameDur = device.activeVideoMaxFrameDuration
            if frameDur.isValid, frameDur.seconds > 0 {
                upperBound = min(upperBound, frameDur)
            }
            let safeDuration = clamp(desired, min: device.activeFormat.minExposureDuration, max: upperBound)
            let iso = lockedISO ?? AVCaptureDevice.currentISO
            lockedDuration = safeDuration
            if baseISO == nil { baseISO = iso / Float(pow(2.0, Double(hardwareEV))) }
            if baseBrightnessISO == nil { baseBrightnessISO = iso / Float(pow(2.0, Double(hardwareEV))) }
            if device.isExposureModeSupported(.custom) {
                device.exposureMode = .custom
                device.setExposureModeCustom(duration: safeDuration, iso: iso, completionHandler: nil)
            }
            applyHDRStateLocked(device)
            device.unlockForConfiguration()

            let seconds = CMTimeGetSeconds(safeDuration)
            let actualShutter: Int
            if seconds.isFinite && seconds > 0 {
                let reciprocal = 1.0 / seconds
                actualShutter = reciprocal.isFinite && reciprocal <= Double(Int.max) ? Int(round(reciprocal)) : snapped
            } else {
                actualShutter = snapped
            }
            let isoText = safeIntText(iso)
            vlog("📸 [CustomCapture] shutter=1/\(actualShutter)s snap=\(shutterSpeed)→\(snapped), keepISO=\(isoText)")
        } catch {
            print("❌ [CustomCapture] 快门设置失败: \(error.localizedDescription)")
        }
    }

    func applyHardwareBrightnessEV(_ ev: Float) {
        sessionQueue.async { [weak self] in
            self?.applyHardwareBrightnessEVLocked(ev)
        }
    }

    private func applyHardwareBrightnessEVLocked(_ ev: Float) {
        hardwareEV = ev
        brightnessGeneration += 1
        let generation = brightnessGeneration
        guard let device = currentDevice else { return }
        do {
            try device.lockForConfiguration()
            ensureBaseBrightnessISO(device)
            if device.isExposureModeSupported(.custom) {
                let iso = isoForCurrentEV(device)
                let duration = lockedDuration ?? device.exposureDuration
                lockedDuration = duration
                lockedISO = iso
                device.exposureMode = .custom
                device.setExposureModeCustom(duration: duration, iso: iso) { [weak self] _ in
                    self?.finishBrightnessApply(generation: generation, ev: ev)
                }
                refreshAutoWhiteBalanceAfterLightingChange(reason: "brightness ISO")
                vlog("📷 [CustomCapture] brightness request ISO=\(safeIntText(iso)) EV=\(String(format: "%.2f", ev)) mode=custom minISO=\(safeIntText(device.activeFormat.minISO)) maxISO=\(safeIntText(device.activeFormat.maxISO))")
            } else {
                let clamped = max(device.minExposureTargetBias, min(ev, device.maxExposureTargetBias))
                device.setExposureTargetBias(clamped, completionHandler: nil)
                vlog("📷 [CustomCapture] brightness AE EV=\(String(format: "%.2f", clamped)) mode=\(device.exposureMode.rawValue)")
            }
            device.unlockForConfiguration()
        } catch {
            print("❌ [CustomCapture] 亮度设置失败: \(error.localizedDescription)")
        }
    }

    /// 增益（硬件 ISO）：滑块 0-100 线性映射到设备实际 ISO [minISO, maxISO] 并直接设置。
    /// 增益本质就是传感器 ISO；0-100 是 UI 抽象，真正运用要落到设备的 ISO 上下限。
    /// 与 PC 亮度 EV 路径解耦：登录/切档下发的增益默认值走这里。
    func applyGainSlider(_ slider: Int) {
        sessionQueue.async { [weak self] in
            self?.applyGainSliderLocked(slider)
        }
    }

    private func applyGainSliderLocked(_ slider: Int) {
        guard let device = currentDevice else { return }
        let s = max(0, min(100, slider))
        do {
            try device.lockForConfiguration()
            guard device.isExposureModeSupported(.custom) else {
                device.unlockForConfiguration()
                vlog("⚠️ [CustomCapture] 增益: 设备不支持 custom 曝光，跳过")
                return
            }
            let minISO = device.activeFormat.minISO
            let maxISO = device.activeFormat.maxISO
            let iso = minISO + (Float(s) / 100.0) * (maxISO - minISO)
            let safeISO = max(minISO, min(maxISO, iso))
            let duration = lockedDuration ?? device.exposureDuration
            lockedDuration = duration
            lockedISO = safeISO
            device.exposureMode = .custom
            device.setExposureModeCustom(duration: duration, iso: safeISO, completionHandler: nil)
            refreshAutoWhiteBalanceAfterLightingChange(reason: "gain ISO")
            vlog("📷 [CustomCapture] 增益 slider=\(s)/100 → ISO=\(safeIntText(safeISO)) (min=\(safeIntText(minISO)) max=\(safeIntText(maxISO)))")
            device.unlockForConfiguration()
        } catch {
            print("❌ [CustomCapture] 增益设置失败: \(error.localizedDescription)")
        }
    }

    private func safeIntText(_ value: Float?) -> String {
        guard let value, value.isFinite, value >= Float(Int.min), value <= Float(Int.max) else { return "invalid" }
        return "\(Int(value))"
    }

    private func finishBrightnessApply(generation: Int, ev: Float) {
        sessionQueue.async { [weak self] in
            guard let self, generation == self.brightnessGeneration else { return }
            let actualEV = self.hardwareEV
            guard abs(actualEV - ev) < 0.001 else { return }
            guard let iso = self.lockedISO else { return }
            vlog("📷 [CustomCapture] brightness applied ISO=\(self.safeIntText(iso)) baseISO=\(self.safeIntText(self.baseBrightnessISO ?? iso)) EV=\(String(format: "%.2f", actualEV)) mode=custom")
        }
    }

    func applyFocus(_ distance: Float) {
        guard let device = currentDevice else { return }
        let clamped = max(0.0, min(1.0, distance))
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
                if device.isLockingFocusWithCustomLensPositionSupported {
                    device.setFocusModeLocked(lensPosition: clamped, completionHandler: nil)
                }
            }
            device.unlockForConfiguration()
            vlog("🔍 [CustomCapture] focus=\(String(format: "%.2f", clamped))")
        } catch {
            print("❌ [CustomCapture] 对焦设置失败: \(error.localizedDescription)")
        }
    }

    func adjustIsoTowardsTarget() {
        guard let device = currentDevice else { return }
        let offset = device.exposureTargetOffset
        if abs(offset) < 0.3 { return }

        let currentISO = device.iso
        let factor = pow(2.0, Double(offset) * 0.5)
        let minISO = device.activeFormat.minISO
        let maxISO = device.activeFormat.maxISO
        let clampedISO = max(minISO, min(maxISO, Float(Double(currentISO) * factor)))
        if abs(clampedISO - currentISO) < (maxISO - minISO) * 0.05 { return }

        do {
            try device.lockForConfiguration()
            ensureBaseISO(device)
            baseISO = clampedISO / Float(pow(2.0, Double(hardwareEV)))
            device.setExposureModeCustom(duration: device.exposureDuration, iso: clampedISO, completionHandler: nil)
            refreshAutoWhiteBalanceAfterLightingChange(reason: "auto ISO")
            device.unlockForConfiguration()
            vlog("🔄 [CustomCapture] AutoISO EV=\(String(format: "%+.2f", offset)), ISO \(Int(currentISO))→\(Int(clampedISO)), baseISO=\(Int(baseISO ?? clampedISO))")
        } catch {
            print("❌ [CustomCapture] AutoISO 失败: \(error.localizedDescription)")
        }
    }

    func applyWhiteBalanceLock() {
        applyContinuousWhiteBalance()
    }

    func applyContinuousWhiteBalance() {
        guard let device = currentDevice else { return }
        do {
            try device.lockForConfiguration()
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                enableContinuousWhiteBalanceLocked(device)
            }
            device.unlockForConfiguration()
        } catch {
            print("❌ [CustomCapture] 自动白平衡失败: \(error.localizedDescription)")
        }
    }

    func applyVideoHDR(_ enabled: Bool) {
        videoHDREnabled = enabled
        guard let device = currentDevice else { return }
        do {
            try device.lockForConfiguration()
            applyHDRStateLocked(device)
            device.unlockForConfiguration()
        } catch {
            print("❌ [CustomCapture] Video HDR 设置失败: \(error.localizedDescription)")
        }
    }

    func applyAutoHDR(_ enabled: Bool) {
        autoHDREnabled = enabled
        guard let device = currentDevice else { return }
        do {
            try device.lockForConfiguration()
            applyHDRStateLocked(device)
            device.unlockForConfiguration()
        } catch {
            print("❌ [CustomCapture] 自动 HDR 设置失败: \(error.localizedDescription)")
        }
    }

    func applyAutoWhiteBalance(_ enabled: Bool) {
        autoWhiteBalanceEnabled = enabled
        if enabled {
            applyContinuousWhiteBalance()
        } else {
            applyWhiteBalanceLock()
        }
        vlog("⚪️ [CustomCapture] autoWhiteBalance=\(enabled)")
    }

    /// 运用白平衡：开自动WB → 等收敛 → 读gains转色温 → 回调色温值；不锁定，保持连续自动
    func applyWhiteBalanceOnceAndLock(completion: @escaping (Float) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            do {
                try device.lockForConfiguration()
                guard device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else {
                    device.unlockForConfiguration()
                    return
                }
                self.enableContinuousWhiteBalanceLocked(device)
                device.unlockForConfiguration()
            } catch {
                print("❌ [CustomCapture] 运用白平衡失败: \(error.localizedDescription)")
                return
            }
            self.sessionQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let device = self.currentDevice else { return }
                do {
                    try device.lockForConfiguration()
                    self.enableContinuousWhiteBalanceLocked(device)
                    let gains = self.normalizedGains(device.deviceWhiteBalanceGains, for: device)
                    device.unlockForConfiguration()
                    let tempTint = device.temperatureAndTintValues(for: gains)
                    let kelvin = tempTint.temperature
                    vlog("⚪️ [CustomCapture] 运用白平衡完成: \(Int(kelvin))K gains=(\(String(format: "%.2f", gains.redGain)),\(String(format: "%.2f", gains.greenGain)),\(String(format: "%.2f", gains.blueGain))) mode=continuous")
                    DispatchQueue.main.async { completion(kelvin) }
                } catch {
                    print("❌ [CustomCapture] 运用白平衡读取失败: \(error.localizedDescription)")
                }
            }
        }
    }

    func applyColorTemperature(_ kelvin: Float) {
        applyContinuousWhiteBalance()
        vlog("⚪️ [CustomCapture] colorTemp request ignored, keep continuous auto WB")
    }

    private func applyColorTemperatureLocked(_ kelvin: Float) {
        applyContinuousWhiteBalance()
    }

    func lockFrameRate(_ fps: Int) {
        guard let device = currentDevice else { return }
        do {
            try device.lockForConfiguration()
            lockFrameRateLocked(device, fps: fps)
            device.unlockForConfiguration()
            vlog("📹 [CustomCapture] fps locked=\(fps)")
        } catch {
            print("❌ [CustomCapture] 帧率锁定失败: \(error.localizedDescription)")
        }
    }

    func applyBaseCameraTuning(focus: Float?, shutterSpeed: Int, captureFps: Int, preserveCurrentISO: Bool) {
        applyShutter(shutterSpeed, preserveCurrentISO: preserveCurrentISO)
        if let focus { applyFocus(focus) }
    }

    func startCapture(with device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int, completion: (() -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.lastConfigDevice = device
            self.lastConfigFormat = format
            self.lastConfigFps = fps
            self.configureRetryCount = 0
            let ok = self.configureSession(device: device, format: format, fps: fps)
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
            if !ok { self.scheduleConfigureRetry(reason: "startCapture") }
            DispatchQueue.main.async { completion?() }
        }
    }

    func switchCapture(to device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int, completion: (() -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.lastConfigDevice = device
            self.lastConfigFormat = format
            self.lastConfigFps = fps
            self.configureRetryCount = 0
            let ok = self.configureSession(device: device, format: format, fps: fps)
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
            if !ok { self.scheduleConfigureRetry(reason: "switchCapture") }
            DispatchQueue.main.async { completion?() }
        }
    }

    func stopCapture(completion: (() -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    @discardableResult
    private func configureSession(device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int) -> Bool {
        var success = false
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .inputPriority

        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }
        if captureSession.outputs.contains(videoOutput) {
            captureSession.removeOutput(videoOutput)
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            var inputAdded = false
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
                inputAdded = true
            } else {
                print("❌ [CustomCapture] canAddInput=false（相机被占用/会话状态异常）")
            }
            if captureSession.canAddOutput(videoOutput) {
                captureSession.addOutput(videoOutput)
            }
            let outputAdded = captureSession.outputs.contains(videoOutput)

            try device.lockForConfiguration()
            device.activeFormat = format
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            if let duration = lockedDuration, device.isExposureModeSupported(.custom) {
                // 🚑 2026-07-02：自定义曝光时长除按格式上下限 clamp 外，还必须 ≤ 帧间隔（1/fps）。
                //    否则「快门 1/50s(20ms) + 60fps 档位(16.7ms)」这类组合会让 HAL 帧间隔矛盾，
                //    部分机型概率性采集停摆/帧率异常 —— 切档卡死嫌疑之一。
                let maxSafe = min(device.activeFormat.maxExposureDuration, frameDuration)
                let safeDuration = clamp(duration, min: device.activeFormat.minExposureDuration, max: maxSafe)
                let iso = isoForCurrentEV(device)
                lockedDuration = safeDuration
                lockedISO = iso
                device.exposureMode = .custom
                device.setExposureModeCustom(duration: safeDuration, iso: iso, completionHandler: nil)
            }
            success = inputAdded && outputAdded
            applyHDRStateLocked(device)
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                enableContinuousWhiteBalanceLocked(device)
                device.isSubjectAreaChangeMonitoringEnabled = true
                vlog("⚪️ [CustomCapture] configureSession → 自动白平衡已开启, exposureMode=\(device.exposureMode.rawValue)")
            }
            device.unlockForConfiguration()

            // 延迟检查白平衡模式是否被系统覆盖
            let checkDevice = device
            sessionQueue.asyncAfter(deadline: .now() + 2.0) {
                if WebRTCManager.verboseLogEnabled {
                    let wbMode = checkDevice.whiteBalanceMode
                    let expMode = checkDevice.exposureMode
                    print("⚪️ [CustomCapture] 2秒后检查: whiteBalanceMode=\(wbMode.rawValue) (0=locked,1=auto,2=continuous), exposureMode=\(expMode.rawValue)")
                }
            }

            // ⭐ 2026-08-16 修「切分辨率画面先旋转一下再正」：原来这里把新连接方向写死
            //   .portrait，要等 WebRTCManager.applyMountTransform 在采集启动完成的异步
            //   回调里才改回横屏，中间几帧就是竖屏方向 → 每次切档画面闪转。
            //   现在重配会话时直接套用期望方向/镜像（由 applyMountTransform 保持同步）。
            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = desiredOrientation
                }
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = desiredMirrored
                }
            }

            currentDevice = device
            NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceSubjectAreaDidChange, object: nil)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(subjectAreaDidChange(_:)),
                name: .AVCaptureDeviceSubjectAreaDidChange,
                object: device
            )
            logFormat(device: device, format: format, fps: fps)
        } catch {
            print("❌ [CustomCapture] 配置失败: \(error.localizedDescription)")
            success = false
        }

        captureSession.commitConfiguration()
        return success
    }

    private func snapToAntiFlicker(_ shutterSpeed: Int) -> Int {
        let safe50Hz = stride(from: 50, through: 600, by: 50).map { $0 }
        let safe60Hz = stride(from: 60, through: 600, by: 60).map { $0 }
        let allSafe = Array(Set(safe50Hz + safe60Hz)).sorted()
        return allSafe.min(by: { abs($0 - shutterSpeed) < abs($1 - shutterSpeed) }) ?? shutterSpeed
    }

    private func clamp(_ value: CMTime, min minValue: CMTime, max maxValue: CMTime) -> CMTime {
        if value < minValue { return minValue }
        if value > maxValue { return maxValue }
        return value
    }

    private func ensureBaseISO(_ device: AVCaptureDevice) {
        guard baseISO == nil else { return }
        let minISO = device.activeFormat.minISO
        let maxISO = device.activeFormat.maxISO
        let cleanISO = minISO + (maxISO - minISO) * 0.34
        baseISO = max(minISO, min(maxISO, cleanISO))
    }

    private func ensureBaseBrightnessISO(_ device: AVCaptureDevice) {
        let minISO = device.activeFormat.minISO
        let maxISO = device.activeFormat.maxISO
        if let base = baseBrightnessISO, base.isFinite, base >= minISO, base <= maxISO { return }
        let neutral = sqrt(minISO * maxISO)
        baseBrightnessISO = max(minISO, min(maxISO, neutral))
    }

    private func isoForCurrentEV(_ device: AVCaptureDevice) -> Float {
        let minISO = device.activeFormat.minISO
        let maxISO = device.activeFormat.maxISO
        guard minISO > 0, maxISO > minISO else { return max(minISO, min(maxISO, minISO)) }
        let t = max(0.0, min(1.0, (hardwareEV - (-2.0)) / 10.0))
        let iso = minISO * Float(pow(Double(maxISO / minISO), Double(t)))
        return max(minISO, min(maxISO, iso))
    }

    private func lockFrameRateLocked(_ device: AVCaptureDevice, fps: Int) {
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        device.activeMaxExposureDuration = frameDuration
    }

    private func refreshAutoWhiteBalanceAfterLightingChange(reason: String) {
        guard autoWhiteBalanceEnabled, !autoWhiteBalanceRefreshInFlight else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAutoWhiteBalanceRefreshAt >= autoWhiteBalanceRefreshInterval else { return }
        lastAutoWhiteBalanceRefreshAt = now
        autoWhiteBalanceRefreshInFlight = true
        vlog("⚪️ [CustomCapture] \(reason)变化 → 重新触发自动白平衡")
        applyWhiteBalanceOnceAndLock { _ in
            self.sessionQueue.async { [weak self] in
                self?.autoWhiteBalanceRefreshInFlight = false
            }
        }
    }

    @objc private func subjectAreaDidChange(_ notification: Notification) {
        sessionQueue.async { [weak self] in
            self?.refreshAutoWhiteBalanceAfterLightingChange(reason: "画面亮度/主体")
        }
    }

    private func applyHDRStateLocked(_ device: AVCaptureDevice) {
        let supported = device.activeFormat.isVideoHDRSupported
        let autoEnabled = supported && autoHDREnabled
        let manualEnabled = supported && videoHDREnabled
        if device.automaticallyAdjustsVideoHDREnabled != autoEnabled {
            device.automaticallyAdjustsVideoHDREnabled = autoEnabled
        }
        if !autoEnabled && device.isVideoHDREnabled != manualEnabled {
            device.isVideoHDREnabled = manualEnabled
        }
        vlog("📷 [CustomCapture] videoHDR=\(device.isVideoHDREnabled) autoHDR=\(device.automaticallyAdjustsVideoHDREnabled) supported=\(supported)")
    }

    private func enableContinuousWhiteBalanceLocked(_ device: AVCaptureDevice) {
        guard device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else { return }
        device.whiteBalanceMode = .continuousAutoWhiteBalance
        autoWhiteBalanceEnabled = true
        lockedWhiteBalanceGains = nil
        wbAdjustmentBaseGains = nil
    }

    private func normalizedGains(_ gains: AVCaptureDevice.WhiteBalanceGains, for device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        let maxGain = device.maxWhiteBalanceGain
        return AVCaptureDevice.WhiteBalanceGains(
            redGain: max(1.0, min(gains.redGain, maxGain)),
            greenGain: max(1.0, min(gains.greenGain, maxGain)),
            blueGain: max(1.0, min(gains.blueGain, maxGain))
        )
    }

    private func logFormat(device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int) {
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let pixelFormatStr = String(format: "%c%c%c%c",
                                    (pixelFormat >> 24) & 0xFF,
                                    (pixelFormat >> 16) & 0xFF,
                                    (pixelFormat >> 8) & 0xFF,
                                    pixelFormat & 0xFF)
        let maxFps = Int(format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        vlog("✅ [CustomCapture] \(device.localizedName) \(dims.width)x\(dims.height) fmt=\(pixelFormatStr) max=\(maxFps)fps use=\(fps)fps output=NV12FullRange")
    }
}

extension CustomAVCaptureVideoCapturer: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timeStampNs = Int64(CMTimeGetSeconds(pts) * 1_000_000_000)
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: timeStampNs)
        delegate?.capturer(self, didCapture: frame)
    }
}
