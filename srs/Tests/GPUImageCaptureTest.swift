import Foundation
import AVFoundation
import UIKit

/// GPUImage 采集测试类
/// 目标：测试能否用 AVCaptureSession 直接获取传感器原始 4:3 数据 + 120fps
/// 
/// 竞品用 GPUImage 的核心原理：
/// - GPUImage 绕过 RTCCameraVideoCapturer，直接配置 AVCaptureSession
/// - 可以选择特殊的 AVCaptureDevice.Format 获取传感器原始数据
/// - 传感器可能原生是 4:3，系统默认裁剪成 16:9
class GPUImageCaptureTest: NSObject {
    
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    private var frameCount: Int = 0
    private var lastFPSTime: Date = Date()
    private var currentFPS: Double = 0
    
    // 🧪 测试模式
    enum TestMode {
        case photo43            // Photo Preset (可能是 4:3)
        case high169_120fps     // 16:9 @120fps，模拟竞品方案
        case low43_640x480      // 🔥 640x480 (4:3) @60fps - 竞品可能用的
        case photoWithHighFps   // 🔥 照片预设 + 尝试高帧率（竞品可能用的）
        case photoForce120fps   // 🔥🔥 照片格式 + 强制120fps（测试你的理论）
    }
    var testMode: TestMode = .high169_120fps  // 🔥 默认测试 16:9 @120fps
    
    // 测试结果回调
    var onFPSUpdate: ((Double, String) -> Void)?
    var onFormatInfo: ((String) -> Void)?
    
    override init() {
        super.init()
        print("🧪 [GPUImageCaptureTest] 初始化")
    }
    
    /// 开始测试：尝试获取 4:3 + 高帧率
    func startTest(in containerView: UIView, useFrontCamera: Bool = true) {
        print("🧪 [GPUImageCaptureTest] 开始测试 - 前置=\(useFrontCamera)")
        
        // 1. 创建 Session
        captureSession = AVCaptureSession()
        guard let session = captureSession else { return }
        
        // 2. 获取摄像头
        let position: AVCaptureDevice.Position = useFrontCamera ? .front : .back
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            print("❌ 找不到摄像头")
            return
        }
        
        // 3. 🔥 分析所有可用格式，找 4:3 高帧率格式
        print("\n📐 ========== 传感器原始格式分析 ==========")
        analyzeFormats(camera: camera)
        
        // 4. 🔥 根据测试模式配置
        switch testMode {
        case .photo43:
            print("🧪 模式：Photo Preset (4:3)")
            // 🔥 分析 Photo 预设的实际格式
            analyzePhotoPreset(camera: camera)
        case .high169_120fps:
            print("🧪 模式：16:9 @120fps（模拟竞品方案）")
            // 🔥 手动设置 16:9 @120fps 格式
            if let format = find169HighFpsFormat(camera: camera) {
                configure120FpsFormat(camera: camera, format: format)
            }
        case .low43_640x480:
            print("🧪 模式：640x480 (4:3) @60fps（竞品可能用的）")
            // 🔥 手动设置 640x480 @60fps 格式
            if let format = find640x480Format(camera: camera) {
                configure60FpsFormat(camera: camera, format: format)
            }
        case .photoWithHighFps:
            print("🧪 模式：照片预设 + 尝试高帧率（竞品可能用的）")
            // 🔥 找最大 FOV 的格式并尝试设置高帧率
            if let format = findMaxFovFormat(camera: camera) {
                configureMaxFovHighFps(camera: camera, format: format)
            }
        case .photoForce120fps:
            print("🧪🔥 模式：照片格式 + 强制120fps（测试理论）")
            // 🔥🔥 找最大 FOV 的照片格式，然后强制设置 120fps
            if let format = findLargestFovFormat(camera: camera) {
                configurePhotoForce120fps(camera: camera, format: format)
            }
        }
        
        // 5. 配置 Session
        do {
            session.beginConfiguration()
            
            // 🧪 根据模式选择 preset
            let testPreset: AVCaptureSession.Preset
            switch testMode {
            case .photo43:
                testPreset = .photo
            case .high169_120fps:
                testPreset = .inputPriority  // 让 format 决定
            case .low43_640x480:
                testPreset = .inputPriority  // 让 format 决定
            case .photoWithHighFps:
                testPreset = .inputPriority  // 让 format 决定，不用 .photo
            case .photoForce120fps:
                testPreset = .inputPriority  // 🔥 必须用 inputPriority 才能手动设置格式
            }
            session.sessionPreset = testPreset
            print("🧪 使用 Preset: \(testPreset.rawValue)")
            
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) {
                session.addInput(input)
            }
            
            // 视频输出
            videoOutput = AVCaptureVideoDataOutput()
            videoOutput?.alwaysDiscardsLateVideoFrames = true
            videoOutput?.setSampleBufferDelegate(self, queue: DispatchQueue(label: "GPUImageTest.VideoQueue"))
            
            if let output = videoOutput, session.canAddOutput(output) {
                session.addOutput(output)
            }
            
            session.commitConfiguration()
            
            // 6. 预览层
            previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer?.videoGravity = .resizeAspect
            previewLayer?.frame = containerView.bounds
            if let layer = previewLayer {
                containerView.layer.addSublayer(layer)
            }
            
            // 7. 启动
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
                print("🧪 [GPUImageCaptureTest] Session 已启动")
            }
            
        } catch {
            print("❌ 配置失败: \(error)")
        }
    }
    
    /// 🔥 分析 Photo 预设的实际格式
    private func analyzePhotoPreset(camera: AVCaptureDevice) {
        print("\n📷 ========== Photo 预设分析 ==========")
        
        // 找最高分辨率的格式（Photo 预设通常会选这个）
        var bestPhotoFormat: AVCaptureDevice.Format?
        var bestPixels: Int = 0
        var bestFov: Float = 0
        
        for format in camera.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let pixels = Int(dims.width) * Int(dims.height)
            let fov = format.videoFieldOfView
            
            if pixels > bestPixels {
                bestPixels = pixels
                bestPhotoFormat = format
                bestFov = fov
            }
        }
        
        if let photoFormat = bestPhotoFormat {
            let dims = CMVideoFormatDescriptionGetDimensions(photoFormat.formatDescription)
            var maxFps: Double = 0
            for range in photoFormat.videoSupportedFrameRateRanges {
                maxFps = max(maxFps, range.maxFrameRate)
            }
            let isBinned = photoFormat.isVideoBinned
            
            print("   📷 Photo 格式: \(dims.width)x\(dims.height)")
            print("   📐 FOV: \(String(format: "%.1f", bestFov))°")
            print("   🎬 最大帧率: \(Int(maxFps))fps")
            print("   📦 Binned: \(isBinned ? "是" : "否")")
            
            // 🔥 与 120fps 格式对比
            var best120FpsFov: Float = 0
            for format in camera.formats {
                var maxFps: Double = 0
                for range in format.videoSupportedFrameRateRanges {
                    maxFps = max(maxFps, range.maxFrameRate)
                }
                if maxFps >= 120 {
                    best120FpsFov = max(best120FpsFov, format.videoFieldOfView)
                }
            }
            
            let fovDiff = bestFov - best120FpsFov
            if fovDiff > 0.1 {
                print("\n   ✅ Photo 格式 FOV 比 120fps 格式大 \(String(format: "%.1f", fovDiff))°")
                print("   💡 竞品可能用 Photo 格式采集，然后帧插值到高帧率")
            } else {
                print("\n   ⚠️ Photo 格式 FOV 与 120fps 格式相同")
                print("   💡 前置摄像头 FOV 固定，无法通过格式选择扩大")
            }
        }
    }
    
    /// 分析摄像头所有格式
    private func analyzeFormats(camera: AVCaptureDevice) {
        var formats43: [(format: AVCaptureDevice.Format, width: Int, height: Int, maxFps: Double)] = []
        var formats169: [(format: AVCaptureDevice.Format, width: Int, height: Int, maxFps: Double)] = []
        
        for format in camera.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let width = Int(dims.width)
            let height = Int(dims.height)
            
            // 计算最大帧率
            var maxFps: Double = 0
            for range in format.videoSupportedFrameRateRanges {
                maxFps = max(maxFps, range.maxFrameRate)
            }
            
            // 计算比例
            let ratio = Double(width) / Double(height)
            let is43 = abs(ratio - 4.0/3.0) < 0.05  // 4:3 ≈ 1.333
            let is169 = abs(ratio - 16.0/9.0) < 0.05  // 16:9 ≈ 1.778
            
            if is43 {
                formats43.append((format, width, height, maxFps))
            } else if is169 {
                formats169.append((format, width, height, maxFps))
            }
        }
        
        // 按帧率排序
        formats43.sort { $0.maxFps > $1.maxFps }
        formats169.sort { $0.maxFps > $1.maxFps }
        
        print("\n📱 4:3 格式 (共\(formats43.count)个):")
        for (i, f) in formats43.prefix(10).enumerated() {
            let fpsStr = f.maxFps >= 120 ? "✅ \(Int(f.maxFps))fps" : "\(Int(f.maxFps))fps"
            print("   [\(i)] \(f.width)x\(f.height) @ \(fpsStr)")
        }
        
        print("\n📱 16:9 格式 (共\(formats169.count)个):")
        for (i, f) in formats169.prefix(10).enumerated() {
            let fpsStr = f.maxFps >= 120 ? "✅ \(Int(f.maxFps))fps" : "\(Int(f.maxFps))fps"
            print("   [\(i)] \(f.width)x\(f.height) @ \(fpsStr)")
        }
        
        // 🔥 关键：找 4:3 + 120fps+ 的格式
        let high43 = formats43.filter { $0.maxFps >= 120 }
        if high43.isEmpty {
            print("\n⚠️ 没有找到 4:3 + 120fps 格式！")
            print("   → 竞品可能用了其他技术（帧插值？ReplayKit？）")
        } else {
            print("\n✅ 找到 4:3 + 120fps 格式:")
            for f in high43 {
                print("   🎯 \(f.width)x\(f.height) @ \(Int(f.maxFps))fps")
            }
        }
        
        // 回调格式信息
        let info = """
        4:3 格式: \(formats43.count)个, 最高帧率: \(Int(formats43.first?.maxFps ?? 0))fps
        16:9 格式: \(formats169.count)个, 最高帧率: \(Int(formats169.first?.maxFps ?? 0))fps
        4:3 + 120fps: \(high43.count)个
        """
        onFormatInfo?(info)
    }
    
    /// 找最佳 4:3 高帧率格式
    private func findBest43HighFpsFormat(camera: AVCaptureDevice) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestScore: Double = 0
        
        for format in camera.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let width = Double(dims.width)
            let height = Double(dims.height)
            
            let ratio = width / height
            let is43 = abs(ratio - 4.0/3.0) < 0.05
            
            if !is43 { continue }
            
            var maxFps: Double = 0
            for range in format.videoSupportedFrameRateRanges {
                maxFps = max(maxFps, range.maxFrameRate)
            }
            
            // 评分：帧率权重高，分辨率权重低
            let score = maxFps * 10 + width * 0.001
            if score > bestScore {
                bestScore = score
                best = format
            }
        }
        
        if let b = best {
            let dims = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            var maxFps: Double = 0
            for range in b.videoSupportedFrameRateRanges {
                maxFps = max(maxFps, range.maxFrameRate)
            }
            print("\n🎯 选择最佳 4:3 格式: \(dims.width)x\(dims.height) @ \(Int(maxFps))fps")
        }
        
        return best
    }
    
    /// 🔥 找 16:9 高帧率格式（120fps+）
    private func find169HighFpsFormat(camera: AVCaptureDevice) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestScore: Double = 0
        
        for format in camera.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let width = Double(dims.width)
            let height = Double(dims.height)
            
            let ratio = width / height
            let is169 = abs(ratio - 16.0/9.0) < 0.05
            
            if !is169 { continue }
            
            var maxFps: Double = 0
            for range in format.videoSupportedFrameRateRanges {
                maxFps = max(maxFps, range.maxFrameRate)
            }
            
            // 只要 120fps+ 的格式
            if maxFps < 120 { continue }
            
            // 评分：帧率权重高，分辨率也重要
            let score = maxFps * 10 + width * 0.01
            if score > bestScore {
                bestScore = score
                best = format
            }
        }
        
        if let b = best {
            let dims = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            var maxFps: Double = 0
            for range in b.videoSupportedFrameRateRanges {
                maxFps = max(maxFps, range.maxFrameRate)
            }
            print("\n🎯 选择 16:9 高帧率格式: \(dims.width)x\(dims.height) @ \(Int(maxFps))fps")
        }
        
        return best
    }
    
    /// 🔥 配置 120fps 格式
    private func configure120FpsFormat(camera: AVCaptureDevice, format: AVCaptureDevice.Format) {
        do {
            try camera.lockForConfiguration()
            
            camera.activeFormat = format
            
            // 设置 120fps
            let targetFps: Double = 120
            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate >= targetFps {
                    camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
                    camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
                    print("🎯 设置帧率: \(Int(targetFps))fps")
                    break
                }
            }
            
            camera.unlockForConfiguration()
            
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            print("✅ 摄像头已配置: \(dims.width)x\(dims.height) @ 120fps (16:9)")
            
        } catch {
            print("❌ 配置摄像头失败: \(error)")
        }
    }
    
    /// 🔥 找 640x480 格式
    private func find640x480Format(camera: AVCaptureDevice) -> AVCaptureDevice.Format? {
        for format in camera.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            
            if dims.width == 640 && dims.height == 480 {
                var maxFps: Double = 0
                for range in format.videoSupportedFrameRateRanges {
                    maxFps = max(maxFps, range.maxFrameRate)
                }
                print("🎯 找到 640x480 格式，最高帧率: \(Int(maxFps))fps")
                return format
            }
        }
        print("❌ 未找到 640x480 格式")
        return nil
    }
    
    /// 🔥 配置 60fps 格式
    private func configure60FpsFormat(camera: AVCaptureDevice, format: AVCaptureDevice.Format) {
        do {
            try camera.lockForConfiguration()
            
            camera.activeFormat = format
            
            // 设置最高帧率（60fps）
            var targetFps: Double = 0
            for range in format.videoSupportedFrameRateRanges {
                targetFps = max(targetFps, range.maxFrameRate)  // 🔥 修复：用 max 而不是 min
            }
            targetFps = min(targetFps, 60)  // 限制最高 60fps
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
            print("🎯 设置帧率: \(Int(targetFps))fps")
            
            camera.unlockForConfiguration()
            
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            print("✅ 摄像头已配置: \(dims.width)x\(dims.height) @ \(Int(targetFps))fps (4:3)")
            
        } catch {
            print("❌ 配置摄像头失败: \(error)")
        }
    }
    
    /// 🔥 找最大 FOV 的格式（包括支持高帧率的）
    private func findMaxFovFormat(camera: AVCaptureDevice) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestFov: Float = 0
        var bestFps: Double = 0
        
        print("\n📐 ========== FOV + Binning 分析 ==========")
        print("💡 Binning = 像素合并，提高帧率但可能减小FOV")
        
        // 🔥 分析所有格式的 FOV + Binning + FPS
        struct FormatInfo {
            let format: AVCaptureDevice.Format
            let dims: CMVideoDimensions
            let maxFps: Double
            let fov: Float
            let isBinned: Bool
        }
        
        var allFormats: [FormatInfo] = []
        
        for format in camera.formats {
            let fov = format.videoFieldOfView
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            var maxFps: Double = 0
            for range in format.videoSupportedFrameRateRanges {
                maxFps = max(maxFps, range.maxFrameRate)
            }
            let isBinned = format.isVideoBinned
            
            allFormats.append(FormatInfo(format: format, dims: dims, maxFps: maxFps, fov: fov, isBinned: isBinned))
            
            // 找最大 FOV + 最高帧率
            if fov > bestFov || (fov == bestFov && maxFps > bestFps) {
                bestFov = fov
                bestFps = maxFps
                best = format
            }
        }
        
        // 按 FOV 降序排序
        allFormats.sort { $0.fov > $1.fov }
        
        // 打印最大 FOV 的格式
        print("\n📊 FOV 排名（最大在前）:")
        var seenFovs: Set<Float> = []
        for info in allFormats {
            let roundedFov = (info.fov * 10).rounded() / 10
            if seenFovs.contains(roundedFov) { continue }
            seenFovs.insert(roundedFov)
            if seenFovs.count > 6 { break }
            
            let fpsIcon = info.maxFps >= 120 ? "✅" : (info.maxFps >= 60 ? "🟡" : "⚠️")
            let binIcon = info.isBinned ? "📦Binned" : "📷Full"
            print("   FOV=\(String(format: "%.1f", info.fov))° | \(fpsIcon)\(Int(info.maxFps))fps | \(info.dims.width)x\(info.dims.height) | \(binIcon)")
        }
        
        // 🔥 关键分析：比较 Binned vs 非Binned 的 FOV
        let binnedFormats = allFormats.filter { $0.isBinned }
        let fullFormats = allFormats.filter { !$0.isBinned }
        
        let maxBinnedFov = binnedFormats.max(by: { $0.fov < $1.fov })?.fov ?? 0
        let maxFullFov = fullFormats.max(by: { $0.fov < $1.fov })?.fov ?? 0
        let maxBinnedFps = binnedFormats.max(by: { $0.maxFps < $1.maxFps })?.maxFps ?? 0
        let maxFullFps = fullFormats.max(by: { $0.maxFps < $1.maxFps })?.maxFps ?? 0
        
        print("\n🔍 Binned vs Full 对比:")
        print("   📦 Binned: 最大FOV=\(String(format: "%.1f", maxBinnedFov))°, 最高FPS=\(Int(maxBinnedFps))")
        print("   📷 Full:   最大FOV=\(String(format: "%.1f", maxFullFov))°, 最高FPS=\(Int(maxFullFps))")
        
        if maxBinnedFov >= maxFullFov && maxBinnedFps >= 120 {
            print("   ✅ 存在 Binned + 大FOV + 高FPS 的格式！")
        } else if maxBinnedFov < maxFullFov {
            print("   ⚠️ Binned 格式 FOV 比 Full 小 \(String(format: "%.1f", maxFullFov - maxBinnedFov))°")
        }
        
        // 🔥 找最大 FOV + 支持 120fps 的格式
        var bestHighFpsFov: AVCaptureDevice.Format?
        var bestHighFpsFovValue: Float = 0
        var bestHighFpsFovBinned: Bool = false
        
        for info in allFormats {
            if info.maxFps >= 120 && info.fov > bestHighFpsFovValue {
                bestHighFpsFovValue = info.fov
                bestHighFpsFov = info.format
                bestHighFpsFovBinned = info.isBinned
            }
        }
        
        if let highFpsFormat = bestHighFpsFov {
            let dims = CMVideoFormatDescriptionGetDimensions(highFpsFormat.formatDescription)
            var maxFps: Double = 0
            for range in highFpsFormat.videoSupportedFrameRateRanges {
                maxFps = max(maxFps, range.maxFrameRate)
            }
            let binStr = bestHighFpsFovBinned ? "Binned" : "Full"
            print("\n🎯 最佳选择: \(dims.width)x\(dims.height) @ \(Int(maxFps))fps, FOV=\(String(format: "%.1f", bestHighFpsFovValue))° (\(binStr))")
            
            // 🔥 计算 FOV 差距
            if maxFullFov > bestHighFpsFovValue {
                let fovDiff = maxFullFov - bestHighFpsFovValue
                print("   📏 与最大 FOV 差距: \(String(format: "%.1f", fovDiff))°")
                print("   💡 竞品可能用软件方式弥补这 \(String(format: "%.1f", fovDiff))° 的差距")
            }
            
            return highFpsFormat
        }
        
        // 如果没有 120fps 的，返回最大 FOV 的格式
        if let b = best {
            let dims = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            print("\n⚠️ 没有 120fps 格式，使用最大 FOV 格式: \(dims.width)x\(dims.height) @ \(Int(bestFps))fps, FOV=\(String(format: "%.1f", bestFov))°")
        }
        
        return best
    }
    
    /// 🔥🔥 找最大 FOV + 最高分辨率的格式（不管帧率）
    private func findLargestFovFormat(camera: AVCaptureDevice) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestFov: Float = 0
        var bestPixels: Int = 0
        
        for format in camera.formats {
            let fov = format.videoFieldOfView
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let pixels = Int(dims.width) * Int(dims.height)
            
            // FOV 优先，相同 FOV 时选分辨率更高的
            if fov > bestFov || (fov == bestFov && pixels > bestPixels) {
                bestFov = fov
                bestPixels = pixels
                best = format
            }
        }
        
        if let b = best {
            let dims = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            var maxFps: Double = 0
            for range in b.videoSupportedFrameRateRanges {
                maxFps = max(maxFps, range.maxFrameRate)
            }
            print("🎯 最大 FOV 格式: \(dims.width)x\(dims.height), FOV=\(String(format: "%.1f", bestFov))°, 原生最大帧率=\(Int(maxFps))fps")
        }
        
        return best
    }
    
    /// 🔥🔥 照片格式 + 尝试高帧率（安全版本，不崩溃）
    private func configurePhotoForce120fps(camera: AVCaptureDevice, format: AVCaptureDevice.Format) {
        do {
            try camera.lockForConfiguration()
            
            camera.activeFormat = format
            
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let fov = format.videoFieldOfView
            
            // 查看格式原生支持的帧率范围
            var nativeMaxFps: Double = 0
            var nativeMinFps: Double = 999
            for range in format.videoSupportedFrameRateRanges {
                nativeMaxFps = max(nativeMaxFps, range.maxFrameRate)
                nativeMinFps = min(nativeMinFps, range.minFrameRate)
            }
            print("📊 格式原生帧率范围: \(Int(nativeMinFps))~\(Int(nativeMaxFps))fps")
            
            // 🔥 安全设置帧率：使用格式支持的最大帧率
            let targetFps = nativeMaxFps
            print("🔥 设置帧率: \(Int(targetFps))fps (格式支持的最大值)")
            
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
            
            // 设置 zoom 到最小值
            let minZoom = camera.minAvailableVideoZoomFactor
            camera.videoZoomFactor = minZoom
            
            camera.unlockForConfiguration()
            
            print("✅ 配置完成:")
            print("   分辨率: \(dims.width)x\(dims.height)")
            print("   FOV: \(String(format: "%.1f", fov))°")
            print("   zoom: \(String(format: "%.2f", minZoom))")
            print("   帧率: \(Int(targetFps))fps")
            
            // 🔥 结论
            if nativeMaxFps >= 120 {
                print("\n   ✅✅ 这个大 FOV 格式支持 120fps！")
            } else {
                print("\n   ⚠️ 结论：大 FOV 格式最高只支持 \(Int(nativeMaxFps))fps")
                print("   💡 竞品如果有大 FOV + 高帧率，可能用了：")
                print("      1. 帧插值（30fps → 120fps 补帧）")
                print("      2. 双采集（大FOV低帧率 + 小FOV高帧率融合）")
                print("      3. 你看错了（其实帧率没那么高）")
            }
            
        } catch {
            print("❌ 配置失败: \(error)")
        }
    }
    
    /// 🔥 配置最大 FOV + 尝试高帧率
    private func configureMaxFovHighFps(camera: AVCaptureDevice, format: AVCaptureDevice.Format) {
        do {
            try camera.lockForConfiguration()
            
            camera.activeFormat = format
            
            // 尝试设置最高帧率
            var targetFps: Double = 0
            for range in format.videoSupportedFrameRateRanges {
                targetFps = max(targetFps, range.maxFrameRate)
            }
            
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
            
            // 🔥 尝试设置 zoom 到最小值（获取更大 FOV）
            let minZoom = camera.minAvailableVideoZoomFactor
            camera.videoZoomFactor = minZoom
            
            camera.unlockForConfiguration()
            
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let fov = format.videoFieldOfView
            print("✅ 摄像头已配置: \(dims.width)x\(dims.height) @ \(Int(targetFps))fps, FOV=\(String(format: "%.1f", fov))°, zoom=\(String(format: "%.2f", minZoom))")
            
        } catch {
            print("❌ 配置摄像头失败: \(error)")
        }
    }
    
    /// 配置摄像头使用指定格式
    private func configureCamera(camera: AVCaptureDevice, format: AVCaptureDevice.Format) {
        do {
            try camera.lockForConfiguration()
            
            camera.activeFormat = format
            
            // 设置最高帧率
            var targetFps: Double = 120
            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate >= targetFps {
                    camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
                    camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
                    print("🎯 设置帧率: \(Int(targetFps))fps")
                    break
                } else if range.maxFrameRate > 60 {
                    targetFps = range.maxFrameRate
                    camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
                    camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
                    print("🎯 设置帧率: \(Int(targetFps))fps (最高可用)")
                }
            }
            
            camera.unlockForConfiguration()
            
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            print("✅ 摄像头已配置: \(dims.width)x\(dims.height) @ \(Int(targetFps))fps")
            
        } catch {
            print("❌ 配置摄像头失败: \(error)")
        }
    }
    
    /// 停止测试
    func stopTest() {
        captureSession?.stopRunning()
        previewLayer?.removeFromSuperlayer()
        captureSession = nil
        videoOutput = nil
        previewLayer = nil
        print("🧪 [GPUImageCaptureTest] 已停止")
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension GPUImageCaptureTest: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCount += 1
        
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFPSTime)
        
        if elapsed >= 1.0 {
            currentFPS = Double(frameCount) / elapsed
            frameCount = 0
            lastFPSTime = now
            
            // 获取当前帧信息
            if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let width = CVPixelBufferGetWidth(imageBuffer)
                let height = CVPixelBufferGetHeight(imageBuffer)
                let ratio = Double(width) / Double(height)
                let ratioStr = abs(ratio - 4.0/3.0) < 0.1 ? "4:3" : (abs(ratio - 16.0/9.0) < 0.1 ? "16:9" : String(format: "%.2f", ratio))
                
                let info = "\(width)x\(height) (\(ratioStr))"
                
                DispatchQueue.main.async { [weak self] in
                    self?.onFPSUpdate?(self?.currentFPS ?? 0, info)
                }
                
                print("📊 实时帧率: \(String(format: "%.1f", currentFPS))fps @ \(info)")
            }
        }
    }
}

