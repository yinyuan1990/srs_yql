import AVFoundation
import CoreMedia
import CoreVideo
import WebRTC

final class CustomAVCaptureVideoCapturer: RTCVideoCapturer {
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
    private var outputPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    private var wbTemperature: Float = 0
    private var wbTint: Float = 0
    private var wbRed: Float = 0
    private var wbGreen: Float = 0
    private var wbBlue: Float = 0
    private var wbBlack: Float = 0
    private var wbWhite: Float = 0
    private var wbAmber: Float = 0
    private var wbAdjustmentBaseGains: AVCaptureDevice.WhiteBalanceGains?

    var currentVideoInput: AVCaptureDeviceInput? {
        captureSession.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first { $0.device.hasMediaType(.video) }
    }

    override init(delegate: RTCVideoCapturerDelegate) {
        super.init(delegate: delegate)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        applyVideoOutputPixelFormat()
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
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
            print("🧪 [CustomCapture] outputPixelFormat=\(name)")
        }
    }

    private func applyVideoOutputPixelFormat() {
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: outputPixelFormat
        ]
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
                device.whiteBalanceMode = .continuousAutoWhiteBalance
                autoWhiteBalanceEnabled = true
                lockedWhiteBalanceGains = nil
                wbAdjustmentBaseGains = nil
                print("🎨 [CustomCapture] WB reset → auto")
            }
            device.unlockForConfiguration()
        } catch {
            print("❌ [CustomCapture] 白平衡重置失败: \(error.localizedDescription)")
        }
    }

    private func applyWhiteBalanceAdjustmentLocked() {
        guard let device = currentDevice else { return }
        // 所有微调值都是 0 时不覆盖自动白平衡
        if wbTemperature == 0 && wbTint == 0 && wbRed == 0 && wbGreen == 0
            && wbBlue == 0 && wbBlack == 0 && wbWhite == 0 && wbAmber == 0 {
            return
        }
        do {
            try device.lockForConfiguration()
            guard device.isWhiteBalanceModeSupported(.locked) else {
                device.unlockForConfiguration()
                return
            }
            let base = wbAdjustmentBaseGains ?? lockedWhiteBalanceGains ?? normalizedGains(device.deviceWhiteBalanceGains, for: device)
            if wbAdjustmentBaseGains == nil {
                wbAdjustmentBaseGains = base
            }
            let maxGain = device.maxWhiteBalanceGain
            let temp = wbTemperature
            let tint = wbTint
            let amber = wbAmber
            // 白：三通道同步提亮；黑：三通道同步压暗；黄/琥珀：R+G 抬、B 降（去冷光、白底更暖）
            let lumScale = (1 + wbWhite * 0.25) * (1 - wbBlack * 0.25)
            let rFactor = (1 + temp * 0.25 + tint * 0.08 + wbRed * 0.20) * (1 + amber * 0.18)
            let gFactor = (1 - tint * 0.15 + wbGreen * 0.20) * (1 + amber * 0.14)
            let bFactor = (1 - temp * 0.25 + tint * 0.08 + wbBlue * 0.20) * (1 - amber * 0.22)
            var gains = AVCaptureDevice.WhiteBalanceGains(
                redGain: base.redGain * rFactor * lumScale,
                greenGain: base.greenGain * gFactor * lumScale,
                blueGain: base.blueGain * bFactor * lumScale
            )
            gains = AVCaptureDevice.WhiteBalanceGains(
                redGain: max(1.0, min(gains.redGain, maxGain)),
                greenGain: max(1.0, min(gains.greenGain, maxGain)),
                blueGain: max(1.0, min(gains.blueGain, maxGain))
            )
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            lockedWhiteBalanceGains = gains
            device.unlockForConfiguration()
            print("🎨 [CustomCapture] WB temp=\(String(format: "%.2f", temp)) tint=\(String(format: "%.2f", tint)) amber=\(String(format: "%.2f", amber)) rgb=(\(String(format: "%.2f", wbRed)),\(String(format: "%.2f", wbGreen)),\(String(format: "%.2f", wbBlue))) bw=(\(String(format: "%.2f", wbBlack)),\(String(format: "%.2f", wbWhite))) lum=\(String(format: "%.2f", lumScale)) gains=(\(String(format: "%.2f", gains.redGain)),\(String(format: "%.2f", gains.greenGain)),\(String(format: "%.2f", gains.blueGain)))")
        } catch {
            print("❌ [CustomCapture] 白平衡微调失败: \(error.localizedDescription)")
        }
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
            let safeDuration = clamp(desired, min: device.activeFormat.minExposureDuration, max: device.activeFormat.maxExposureDuration)
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
            print("📸 [CustomCapture] shutter=1/\(actualShutter)s snap=\(shutterSpeed)→\(snapped), keepISO=\(isoText)")
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
                print("📷 [CustomCapture] brightness request ISO=\(safeIntText(iso)) EV=\(String(format: "%.2f", ev)) mode=custom minISO=\(safeIntText(device.activeFormat.minISO)) maxISO=\(safeIntText(device.activeFormat.maxISO))")
            } else {
                let clamped = max(device.minExposureTargetBias, min(ev, device.maxExposureTargetBias))
                device.setExposureTargetBias(clamped, completionHandler: nil)
                print("📷 [CustomCapture] brightness AE EV=\(String(format: "%.2f", clamped)) mode=\(device.exposureMode.rawValue)")
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
                print("⚠️ [CustomCapture] 增益: 设备不支持 custom 曝光，跳过")
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
            print("📷 [CustomCapture] 增益 slider=\(s)/100 → ISO=\(safeIntText(safeISO)) (min=\(safeIntText(minISO)) max=\(safeIntText(maxISO)))")
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
            print("📷 [CustomCapture] brightness applied ISO=\(self.safeIntText(iso)) baseISO=\(self.safeIntText(self.baseBrightnessISO ?? iso)) EV=\(String(format: "%.2f", actualEV)) mode=custom")
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
            print("🔍 [CustomCapture] focus=\(String(format: "%.2f", clamped))")
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
            device.unlockForConfiguration()
            print("🔄 [CustomCapture] AutoISO EV=\(String(format: "%+.2f", offset)), ISO \(Int(currentISO))→\(Int(clampedISO)), baseISO=\(Int(baseISO ?? clampedISO))")
        } catch {
            print("❌ [CustomCapture] AutoISO 失败: \(error.localizedDescription)")
        }
    }

    func applyWhiteBalanceLock() {
        guard let device = currentDevice else { return }
        do {
            try device.lockForConfiguration()
            if device.isWhiteBalanceModeSupported(.locked) {
                let gains = normalizedGains(device.deviceWhiteBalanceGains, for: device)
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                lockedWhiteBalanceGains = gains
                wbAdjustmentBaseGains = gains
                print("⚪️ [CustomCapture] WB locked r=\(String(format: "%.2f", gains.redGain)) g=\(String(format: "%.2f", gains.greenGain)) b=\(String(format: "%.2f", gains.blueGain))")
            }
            device.unlockForConfiguration()
        } catch {
            print("❌ [CustomCapture] 白平衡锁定失败: \(error.localizedDescription)")
        }
    }

    func applyContinuousWhiteBalance() {
        guard let device = currentDevice else { return }
        do {
            try device.lockForConfiguration()
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
                lockedWhiteBalanceGains = nil
                wbAdjustmentBaseGains = nil
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
        print("⚪️ [CustomCapture] autoWhiteBalance=\(enabled)")
    }

    /// 运用白平衡：开自动WB → 等收敛 → 读gains转色温 → 锁定 → 回调色温值
    func applyWhiteBalanceOnceAndLock(completion: @escaping (Float) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            do {
                try device.lockForConfiguration()
                guard device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else {
                    device.unlockForConfiguration()
                    return
                }
                device.whiteBalanceMode = .continuousAutoWhiteBalance
                device.unlockForConfiguration()
            } catch {
                print("❌ [CustomCapture] 运用白平衡失败: \(error.localizedDescription)")
                return
            }
            // 等自动WB收敛（0.5秒足够）
            self.sessionQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let device = self.currentDevice else { return }
                do {
                    try device.lockForConfiguration()
                    let gains = self.normalizedGains(device.deviceWhiteBalanceGains, for: device)
                    if device.isWhiteBalanceModeSupported(.locked) {
                        device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                    }
                    self.lockedWhiteBalanceGains = gains
                    self.wbAdjustmentBaseGains = gains
                    self.autoWhiteBalanceEnabled = false
                    device.unlockForConfiguration()
                    let tempTint = device.temperatureAndTintValues(for: gains)
                    let kelvin = tempTint.temperature
                    print("⚪️ [CustomCapture] 运用白平衡完成: \(Int(kelvin))K gains=(\(String(format: "%.2f", gains.redGain)),\(String(format: "%.2f", gains.greenGain)),\(String(format: "%.2f", gains.blueGain)))")
                    DispatchQueue.main.async { completion(kelvin) }
                } catch {
                    print("❌ [CustomCapture] 运用白平衡锁定失败: \(error.localizedDescription)")
                }
            }
        }
    }

    func applyColorTemperature(_ kelvin: Float) {
        sessionQueue.async { [weak self] in
            self?.applyColorTemperatureLocked(kelvin)
        }
    }

    private func applyColorTemperatureLocked(_ kelvin: Float) {
        guard let device = currentDevice else { return }
        do {
            try device.lockForConfiguration()
            guard device.isWhiteBalanceModeSupported(.locked) else {
                device.unlockForConfiguration()
                return
            }
            autoWhiteBalanceEnabled = false
            let maxGain = device.maxWhiteBalanceGain
            let tempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: kelvin, tint: 0
            )
            var gains = device.deviceWhiteBalanceGains(for: tempAndTint)
            let rawR = gains.redGain, rawG = gains.greenGain, rawB = gains.blueGain
            gains = normalizedGains(gains, for: device)
            let peak = max(gains.redGain, gains.greenGain, gains.blueGain)
            if peak > maxGain {
                let scale = maxGain / peak
                gains.redGain   = max(1.0, gains.redGain   * scale)
                gains.greenGain = max(1.0, gains.greenGain * scale)
                gains.blueGain  = max(1.0, gains.blueGain  * scale)
            }
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            lockedWhiteBalanceGains = gains
            wbAdjustmentBaseGains = gains
            device.unlockForConfiguration()
            let clamped = (rawR != gains.redGain || rawG != gains.greenGain || rawB != gains.blueGain) ? " (clamped)" : ""
            print("⚪️ [CustomCapture] colorTemp=\(Int(kelvin))K gains=(\(String(format: "%.2f", gains.redGain)),\(String(format: "%.2f", gains.greenGain)),\(String(format: "%.2f", gains.blueGain))) maxGain=\(String(format: "%.1f", maxGain))\(clamped)")
        } catch {
            print("❌ [CustomCapture] 色温设置失败: \(error.localizedDescription)")
        }
    }

    func lockFrameRate(_ fps: Int) {
        guard let device = currentDevice else { return }
        do {
            try device.lockForConfiguration()
            lockFrameRateLocked(device, fps: fps)
            device.unlockForConfiguration()
            print("📹 [CustomCapture] fps locked=\(fps)")
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
            self.configureSession(device: device, format: format, fps: fps)
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    func switchCapture(to device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int, completion: (() -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSession(device: device, format: format, fps: fps)
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
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

    private func configureSession(device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int) {
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
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }
            if captureSession.canAddOutput(videoOutput) {
                captureSession.addOutput(videoOutput)
            }

            try device.lockForConfiguration()
            device.activeFormat = format
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            if let duration = lockedDuration, device.isExposureModeSupported(.custom) {
                let safeDuration = clamp(duration, min: device.activeFormat.minExposureDuration, max: device.activeFormat.maxExposureDuration)
                let iso = isoForCurrentEV(device)
                lockedDuration = safeDuration
                lockedISO = iso
                device.exposureMode = .custom
                device.setExposureModeCustom(duration: safeDuration, iso: iso, completionHandler: nil)
            }
            applyHDRStateLocked(device)
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
                autoWhiteBalanceEnabled = true
                lockedWhiteBalanceGains = nil
                wbAdjustmentBaseGains = nil
                print("⚪️ [CustomCapture] configureSession → 自动白平衡已开启, exposureMode=\(device.exposureMode.rawValue)")
            }
            device.unlockForConfiguration()

            // 延迟检查白平衡模式是否被系统覆盖
            let checkDevice = device
            sessionQueue.asyncAfter(deadline: .now() + 2.0) {
                let wbMode = checkDevice.whiteBalanceMode
                let expMode = checkDevice.exposureMode
                print("⚪️ [CustomCapture] 2秒后检查: whiteBalanceMode=\(wbMode.rawValue) (0=locked,1=auto,2=continuous), exposureMode=\(expMode.rawValue)")
            }

            if let connection = videoOutput.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }

            currentDevice = device
            logFormat(device: device, format: format, fps: fps)
        } catch {
            print("❌ [CustomCapture] 配置失败: \(error.localizedDescription)")
        }

        captureSession.commitConfiguration()
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
        print("📷 [CustomCapture] videoHDR=\(device.isVideoHDREnabled) autoHDR=\(device.automaticallyAdjustsVideoHDREnabled) supported=\(supported)")
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
        print("✅ [CustomCapture] \(device.localizedName) \(dims.width)x\(dims.height) fmt=\(pixelFormatStr) max=\(maxFps)fps use=\(fps)fps output=NV12FullRange")
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
