//
//  WebRTCManager.swift
//  Ai幻境
//
//  Created by 陈源 on 10/3/25.
//

import Foundation
import WebRTC
import AVFoundation
import CoreMedia
import UIKit

// MARK: - 视频滤镜处理器（亮度/饱和度/对比度）
final class VideoFilterProcessor: NSObject, RTCVideoCapturerDelegate {
    weak var inner: RTCVideoCapturerDelegate?
    var brightness: Float = 0.0   // -1.0 ~ 1.0
    var saturation: Float = 1.0   // 0.0 ~ 2.0
    var contrast: Float = 1.0     // 0.0 ~ 4.0
    var enabled: Bool = false
    
    private let ciContext: CIContext
    private let colorControlsFilter = CIFilter(name: "CIColorControls")!
    
    override init() {
        // 使用 Metal 加速
        if let mtlDevice = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: mtlDevice)
        } else {
            ciContext = CIContext()
        }
        super.init()
    }
    
    private var filterAppliedCount = 0
    private var bypassedCount = 0
    
    func capturer(_ capturer: RTCVideoCapturer, didCapture videoFrame: RTCVideoFrame) {
        // 检查条件
        let hasParams = brightness != 0.0 || saturation != 1.0 || contrast != 1.0
        
        if !enabled {
            bypassedCount += 1
            if bypassedCount == 1 || bypassedCount % 60 == 0 {
                print("⚠️ 滤镜被绕过（enabled=false）: B=\(brightness) S=\(saturation) C=\(contrast) [计数:\(bypassedCount)]")
            }
        } else if !hasParams {
            bypassedCount += 1
            if bypassedCount == 1 || bypassedCount % 60 == 0 {
                print("ℹ️ 滤镜参数为默认值，跳过: B=\(brightness) S=\(saturation) C=\(contrast)")
            }
        }
        
        guard enabled, hasParams else {
            // 不需要滤镜，直接传递
            inner?.capturer(capturer, didCapture: videoFrame)
            return
        }
        
        // 应用滤镜
        if let filtered = applyFilter(to: videoFrame) {
            inner?.capturer(capturer, didCapture: filtered)
            filterAppliedCount += 1
            if filterAppliedCount == 1 || filterAppliedCount % 60 == 0 {
                print("🎨 滤镜已应用: B=\(brightness) S=\(saturation) C=\(contrast) [计数:\(filterAppliedCount)]")
            }
        } else {
            // 失败则传递原始帧
            inner?.capturer(capturer, didCapture: videoFrame)
            print("⚠️ 滤镜应用失败，使用原始帧")
        }
    }
    
    private func applyFilter(to frame: RTCVideoFrame) -> RTCVideoFrame? {
        guard let buffer = frame.buffer as? RTCCVPixelBuffer else { return nil }
        let pixelBuffer = buffer.pixelBuffer
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // 配置滤镜参数
        colorControlsFilter.setValue(ciImage, forKey: kCIInputImageKey)
        colorControlsFilter.setValue(brightness, forKey: kCIInputBrightnessKey)
        colorControlsFilter.setValue(saturation, forKey: kCIInputSaturationKey)
        colorControlsFilter.setValue(contrast, forKey: kCIInputContrastKey)
        
        guard let outputImage = colorControlsFilter.outputImage else { return nil }
        
        // 创建新的 PixelBuffer
        var newPixelBuffer: CVPixelBuffer?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            nil,
            &newPixelBuffer
        )
        
        guard status == kCVReturnSuccess, let outBuffer = newPixelBuffer else { return nil }
        
        // 渲染到新buffer
        ciContext.render(outputImage, to: outBuffer)
        
        // 创建新的RTCVideoFrame
        let newBuffer = RTCCVPixelBuffer(pixelBuffer: outBuffer)
        return RTCVideoFrame(
            buffer: newBuffer,
            rotation: frame.rotation,
            timeStampNs: frame.timeStampNs
        )
    }
}

final class FrameThrottler: NSObject, RTCVideoCapturerDelegate {
    weak var inner: RTCVideoCapturerDelegate?
    var targetSendFps: Int = 60
    private var lastSentTsSec: Double = 0

    private var intervalSec: Double {
        let clamped = max(1, min(targetSendFps, 60))
        return 1.0 / Double(clamped)
    }
    
    var fpsReportHandler: ((Int, Int) -> Void)?
    private var lastReportTsSec: Double = 0
    private var captureCounter: Int = 0
    private var sentCounter: Int = 0

    func capturer(_ capturer: RTCVideoCapturer, didCapture videoFrame: RTCVideoFrame) {
        // 以采集时间戳为基准做时间门控，保证平均输出
        let tsSec: Double = {
            let ns = videoFrame.timeStampNs
            return ns > 0 ? Double(ns) / 1_000_000_000.0 : CFAbsoluteTimeGetCurrent()
        }()
        // 采集计数
        captureCounter += 1
        if lastSentTsSec == 0 || (tsSec - lastSentTsSec) >= intervalSec {
            
            lastSentTsSec = tsSec
            inner?.capturer(capturer, didCapture: videoFrame)
            // 修复：真正发送时递增推送计数
            sentCounter += 1
        } else {
            // 丢弃以维持时间间隔
        }
        // 每秒上报一次采集/推送FPS
        if lastReportTsSec == 0 { lastReportTsSec = tsSec }
        if (tsSec - lastReportTsSec) >= 1.0 {
            let cap = captureCounter
            let snd = sentCounter
            
            DispatchQueue.main.async { [weak self] in
                self?.fpsReportHandler?(cap, snd)
            }
            print("📊 本地FPS 采集=\(cap) 推送=\(snd) 目标=\(targetSendFps)")
            captureCounter = 0
            sentCounter = 0
            lastReportTsSec = tsSec
        }
    }
}

// MARK: - 阶梯档位（动态根据摄像头能力）
enum LadderProfile: Int, CaseIterable {
    case standard  // 次高分辨率
    case high      // 最高分辨率
}

enum MountOrientation: Int, CaseIterable {
        case deg0, deg90, deg180, deg270
        var avOrientation: AVCaptureVideoOrientation {
            switch self {
            case .deg0:   return .portrait         // 0°
            case .deg90:  return .landscapeRight   // 90°（Home 键在左）
            case .deg180: return .portraitUpsideDown
            case .deg270: return .landscapeLeft    // 270°（Home 键在右）
            }
        }

        var label: String {
            switch self {
            case .deg0: return "0°"
            case .deg90: return "90°"
            case .deg180: return "180°"
            case .deg270: return "270°"
            }
        }
}


struct LadderPreset {
    let width: Int
    let height: Int
    let fps: Int
    let maxKbps: Int
}

final class WebRTCManager: NSObject, ObservableObject {
    
    // MARK: - 对外状态
    @Published var isPublishing = false
    @Published var currentKbps: Int = 0
    @Published var currentFps: Int = 0
    @Published var currentProfile: LadderProfile = .standard
    // 额外暴露采集/推送FPS，便于UI区分显示
   @Published var currentCaptureFps: Int = 0
   @Published var currentSendFps: Int = 0
   
   // 码率平滑（减少显示波动）
   private var kbpsHistory: [Int] = []
   private let kbpsHistorySize = 3  // 使用3秒移动平均
   
    // 动态档位配置（根据当前摄像头）
    var currentLadder: [LadderProfile: LadderPreset] = [:]
    
    // 新增：低档位降帧配置（逐步降低 30→24→20→15→10）
    private let LOWEST_PROFILE: LadderProfile = .standard
    private let LOW_FPS_STEPS: [Int] = [60, 50, 45, 40, 35, 30, 24, 20, 15, 12, 10]
    private var lowFpsIndex: Int = 0
    

    
    private var lastQualityPercent: Int? = nil
    private let QUALITY_PERCENT_STEPS: [Int] = [10, 15, 20, 25, 30, 40, 50, 60, 70, 80, 90, 100]

       // 手动 FPS 覆盖（作为上限，自动逻辑仍可往下压）
    private var manualFpsOverride: Int? = nil
    private let FPS_STEPS: [Int] = [60, 50, 45, 40, 35, 30, 24, 20, 15, 12, 10]
    
    

    
    // 预览/远端
    let localView = RTCMTLVideoView(frame: .zero)
    let remoteView = RTCMTLVideoView(frame: .zero)
    
    private var localVideoTrack: RTCVideoTrack?
    
    private var videoFilterProcessor: VideoFilterProcessor?
    private var frameThrottler: FrameThrottler?
    
    
    // MARK: - 动态档位计算
    /// 根据当前摄像头动态计算档位配置
    private func calculateLadderForDevice(_ device: AVCaptureDevice) {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        
        // 根据摄像头位置设置分辨率上限
        let maxPixels: Int
        if device.position == .back {
            // 后置摄像头：最高 1920x1080
            maxPixels = 1920 * 1080  // 2,073,600
        } else {
            // 前置摄像头：最高 1280x720
            maxPixels = 1280 * 720   // 921,600
        }
        
        // 提取所有分辨率并去重，按像素总数降序排序
        var resolutions: [(width: Int, height: Int, maxFps: Int, pixelCount: Int)] = []
        for fmt in formats {
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let w = Int(dims.width)
            let h = Int(dims.height)
            let maxFps = Int(fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 60)
            let pixels = w * h
            
            // ✅ 过滤：只保留不超过上限的分辨率
            if pixels > maxPixels { continue }
            
            // 去重：相同分辨率只保留一个
            if !resolutions.contains(where: { $0.width == w && $0.height == h }) {
                resolutions.append((w, h, maxFps, pixels))
            }
        }
        
        // 按像素数降序排序
        resolutions.sort { $0.pixelCount > $1.pixelCount }
        
        // 如果过滤后没有分辨率，使用默认值
        if resolutions.isEmpty {
            resolutions = device.position == .back 
                ? [(width: 1920, height: 1080, maxFps: 60, pixelCount: 1920*1080)]
                : [(width: 1280, height: 720, maxFps: 60, pixelCount: 1280*720)]
        }
        
        // 提取前两个作为 high 和 standard
        let highRes = resolutions.first ?? (width: 1920, height: 1080, maxFps: 60, pixelCount: 1920*1080)
        let standardRes = resolutions.count > 1 ? resolutions[1] : (width: 1280, height: 720, maxFps: 60, pixelCount: 1280*720)
        
        // 根据分辨率估算合适的码率（像素数越大码率越高）
        func estimateBitrate(pixels: Int) -> Int {
            // 基准：1920x1080 (2073600 pixels) → 4500 kbps
            let basePixels = 2073600.0  // 1080p
            let baseKbps = 4500.0
            let ratio = Double(pixels) / basePixels
            return max(1500, Int(baseKbps * ratio))
        }
        
        currentLadder = [
            .high: LadderPreset(
                width: highRes.width,
                height: highRes.height,
                fps: highRes.maxFps,
                maxKbps: estimateBitrate(pixels: highRes.pixelCount)
            ),
            .standard: LadderPreset(
                width: standardRes.width,
                height: standardRes.height,
                fps: standardRes.maxFps,
                maxKbps: estimateBitrate(pixels: standardRes.pixelCount)
            )
        ]
        
        print("📐 摄像头档位计算完成：")
        print("   高清 = \(highRes.width)x\(highRes.height) @\(highRes.maxFps)fps → \(currentLadder[.high]!.maxKbps)kbps")
        print("   标清 = \(standardRes.width)x\(standardRes.height) @\(standardRes.maxFps)fps → \(currentLadder[.standard]!.maxKbps)kbps")
    }
    
    private func effectiveMaxKbpsForCurrentProfile() -> Int {
            guard let preset = currentLadder[currentProfile] else { return 1500 }
            let fpsTarget = frameThrottler?.targetSendFps ?? preset.fps
            let base = kbpsForProfile(preset)
            let scaled = Int(Double(base) * Double(fpsTarget) / Double(preset.fps))
            return max(300, scaled)
    }
    
    /// 设置平均推送的目标 FPS（采集保持不变）
    func setAverageOutputFPS(_ fps: Int) {
         
        let clamped = max(1, min(fps, 60))
        frameThrottler?.targetSendFps = clamped
        if currentLadder[currentProfile] != nil {
            setMaxBitrateKbps(effectiveMaxKbpsForCurrentProfile())
        }
        print("🎛 平均推送FPS =", clamped)
        
    }
    
    /// 开/关平均节流（关时恢复直通）
    func enableAverageThrottling(_ enabled: Bool) {
        guard let capturer = self.capturer else { return }
        if enabled {
            if frameThrottler == nil {
                let throttler = FrameThrottler()
                throttler.inner = self.videoSource
                frameThrottler = throttler
            }
            // ✅ 保持滤镜链：capturer -> filter -> throttler -> source
            if let filter = videoFilterProcessor {
                capturer.delegate = filter
                print("✅ 平均节流开启（含滤镜）")
            } else {
                capturer.delegate = frameThrottler!
                print("✅ 平均节流开启（无滤镜）")
            }
        } else if let source = self.videoSource {
            capturer.delegate = source
            print("✅ 平均节流关闭")
        }
    }
    

    // MARK: - SRS 配置
    var srsIP = "8.162.11.163"
    var app   = "tenantA"

    // 动态流名（来自本地缓存 permanent_token）
    private(set) var streamKey: String = ""
    
    // 挂载方向 & 镜像开关（持久化可选）
    @Published var mountOrientation: MountOrientation = .deg0
    @Published var streamMirrored: Bool = false
    
    // WebRTCManager.applyThinRemoteConfig(_ cfg: ThinRemoteConfig)
    func applyThinRemoteConfig(_ cfg: ThinRemoteConfig) {
        
        print("---> "+cfg.ptype)
        // ... existing code ...
        switch cfg.ptype {
        case "type":
            // 档位：standard→次高分辨率；high→最高分辨率（仅在不同才应用）
            let desiredProfile: LadderProfile = (cfg.type.lowercased() == "high") ? .high : .standard
            if currentProfile != desiredProfile {
                if gentleAdaptMode { applyProfileBitrateOnly(desiredProfile) } else { applyProfile(desiredProfile) }
            }
            print("✅ 已按 ptype=type 应用档位: \(cfg.type)")

        case "direction":
            // 方向："-1"前置；"1"后置（若不一致则切换一次）
            if let input = capturer?.captureSession.inputs.first as? AVCaptureDeviceInput {
                let wantFront = (cfg.direction == "-1")
                let curFront = (input.device.position == .front)
                if wantFront != curFront { toggleCamera() }
                print("✅ 已按 ptype=direction 切换: wantFront=\(wantFront)")
            } else {
                print("⚠️ 无摄像头输入，略过方向更新")
            }

        case "zoom":
            // 变焦
            setZoom(cfg.zoom)
            print("✅ 已按 ptype=zoom 设置焦距: \(cfg.zoom)")

        case "exposureBias":
            // 曝光补偿 EV
            if let ev = cfg.exposureBias {
                setExposureBias(ev: ev)
                print("✅ 已按 ptype=exposureBias 设置EV: \(ev)")
            } else {
                print("⚠️ ptype=exposureBias 缺少值，忽略")
            }
            
        case "fps":
            // FPS（优先整数）
            if let f = cfg.fps {
                setAverageOutputFPS(f)
                enableAverageThrottling(true)
                print("✅ 已按 ptype=fps 设置平均推送FPS: \(f)")
            } else {
                print("⚠️ ptype=fps 缺少值，忽略")
            }

        case "bitrate":
            // 码率（百分比，保底 10%）
            if let pct = cfg.bitrate {
                setQualityPercentage(pct)
                print("✅ 已按 ptype=bitrate 设置质量百分比: \(pct)%")
            } else {
                print("⚠️ ptype=bitrate 缺少值，忽略")
            }

        case "angle":
            // 角度：支持 0/90/180/270
            if let angRaw = cfg.angle {
                let ang = ((angRaw % 360) + 360) % 360
                switch ang {
                case 0:   
                    mountOrientation = .deg0
                    print("✅ 应用 angle=0° → Portrait")
                case 90:  
                    mountOrientation = .deg90
                    print("✅ 应用 angle=90° → LandscapeRight")
                case 180: 
                    mountOrientation = .deg180
                    print("✅ 应用 angle=180° → PortraitUpsideDown")
                case 270: 
                    mountOrientation = .deg270
                    print("✅ 应用 angle=270° → LandscapeLeft")
                default:  
                    print("⚠️ ptype=angle 非法角度: \(angRaw)")
                }
                applyMountTransform()
            } else {
                print("⚠️ ptype=angle 缺少值，忽略")
            }
            
        case "focus":
            // 对焦距离 0.0~1.0
            if let f = cfg.focus {
                setFocus(f)
                print("✅ 已按 ptype=focus 设置对焦距离: \(f)")
            } else {
                print("⚠️ ptype=focus 缺少值，忽略")
            }
            
        case "brightness":
            // 亮度 -1.0~1.0
            if let b = cfg.brightness {
                setVideoBrightness(b)
                print("✅ 已按 ptype=brightness 设置亮度: \(b)")
            } else {
                print("⚠️ ptype=brightness 缺少值，忽略")
            }
            
        case "saturation":
            // 饱和度 0.0~2.0
            if let s = cfg.saturation {
                setVideoSaturation(s)
                print("✅ 已按 ptype=saturation 设置饱和度: \(s)")
            } else {
                print("⚠️ ptype=saturation 缺少值，忽略")
            }
            
        case "contrast":
            // 对比度 0.0~4.0
            if let c = cfg.contrast {
                setVideoContrast(c)
                print("✅ 已按 ptype=contrast 设置对比度: \(c)")
            } else {
                print("⚠️ ptype=contrast 缺少值，忽略")
            }
            
        default:
            print("⚠️ 未知 ptype=\(cfg.ptype)，忽略该项")
        }
        // ... existing code ...
    }
    
    func applyThinRemoteConfigInit(_ cfg: ThinRemoteConfig) {
            // 1) 档位：standard→次高分辨率；high→最高分辨率（其他值默认 standard）
            let desiredProfile: LadderProfile = (cfg.type.lowercased() == "high") ? .high : .standard
            if currentProfile != desiredProfile {
                if gentleAdaptMode { applyProfileBitrateOnly(desiredProfile) } else { applyProfile(desiredProfile) }
            }

            // 2) 方向："-1"前置；"1"后置（若不一致则切换一次）
            if let input = capturer?.captureSession.inputs.first as? AVCaptureDeviceInput {
                let wantFront = (cfg.direction == "-1")
                let curFront = (input.device.position == .front)
                if wantFront != curFront { toggleCamera() }
            }

            // 3) 变焦
            setZoom(cfg.zoom)

            // 4) 曝光补偿 EV
            if let ev = cfg.exposureBias { setExposureBias(ev: ev) }

            // 5) FPS（优先整数）
            if let f = cfg.fps {
                    setAverageOutputFPS(f)
                    enableAverageThrottling(true)
                }

            // 6) 码率（kbps→百分比，按当前档位上限换算；保底 10%）
            if let pct = cfg.bitrate { setQualityPercentage(pct) }
            
            // 7) 角度：0/90/180/270（其他值忽略）
            if let angRaw = cfg.angle {
                let ang = ((angRaw % 360) + 360) % 360
                switch ang {
                  case 0:   
                    mountOrientation = .deg0
                    print("✅ 初始化 angle=0° → Portrait")
                  case 90:  
                    mountOrientation = .deg90
                    print("✅ 初始化 angle=90° → LandscapeRight")
                  case 180: 
                    mountOrientation = .deg180
                    print("✅ 初始化 angle=180° → PortraitUpsideDown")
                  case 270: 
                    mountOrientation = .deg270
                    print("✅ 初始化 angle=270° → LandscapeLeft")
                  default:  
                    print("⚠️ 初始化：非法角度 angle=\(ang)")
                }
                applyMountTransform()
            }
            
            // 8) 对焦距离 0.0~1.0
            if let f = cfg.focus { setFocus(f) }
            
            // 9) 亮度 -1.0~1.0
            if let b = cfg.brightness { setVideoBrightness(b) }
            
            // 10) 饱和度 0.0~2.0
            if let s = cfg.saturation { setVideoSaturation(s) }
            
            // 11) 对比度 0.0~4.0
            if let c = cfg.contrast { setVideoContrast(c) }
            
            print("✅ 已应用 ThinRemoteConfig: type=\(cfg.type) dir=\(cfg.direction) zoom=\(cfg.zoom) fps=\(String(describing: cfg.fps)) bitrate=\(String(describing: cfg.bitrate)) angle=\(String(describing: cfg.angle)) focus=\(String(describing: cfg.focus)) brightness=\(String(describing: cfg.brightness)) saturation=\(String(describing: cfg.saturation)) contrast=\(String(describing: cfg.contrast))")
    }
    
    
    func setQualityPercentage(_ percent: Int) {
            let clamped = max(10, min(100, percent))
            // 吸附到统一阶梯，跨档位统一体验
            let snapped = QUALITY_PERCENT_STEPS.min(by: { abs($0 - clamped) < abs($1 - clamped) }) ?? clamped
            lastQualityPercent = snapped
            if currentLadder[currentProfile] != nil {
                setMaxBitrateKbps(effectiveMaxKbpsForCurrentProfile())
            }
            print("✨ 质量百分比=", snapped, "%")
     }

    func setFPSPercent(_ percent: Int) {
        // ... existing code ...
        let clamped = max(1, min(100, percent))
        let base = 60
        let suggested = max(10, min(base, Int(round(Double(base) * Double(clamped) / 100.0))))
        let snapped = FPS_STEPS.min(by: { abs($0 - suggested) < abs($1 - suggested) }) ?? suggested
        manualFpsOverride = snapped
        // 关键：立刻重采集以应用手动 FPS 覆盖
        if let preset = currentLadder[currentProfile] {
            recapture(width: preset.width, height: preset.height, fps: preset.fps)
        }
        print("🎯 手动 FPS(%) → ", snapped, "fps")
        // ... existing code ...
    }
    
    
    func setFPSValue(_ fps: Int) {
        let clamped = max(10, min(60, fps))
        manualFpsOverride = clamped
        // 关键：立刻重采集以应用手动 FPS 覆盖
        if let preset = currentLadder[currentProfile] {
            recapture(width: preset.width, height: preset.height, fps: preset.fps)
        }
        print("🎯 手动 FPS =", clamped, "fps")
    }
    
    func clearManualFpsOverride() {
        manualFpsOverride = nil
        print("🧹 清除手动 FPS 覆盖")
    }
    
    // 统一根据百分比计算当前档位应设的码率上限
    private func kbpsForProfile(_ preset: LadderPreset) -> Int {
        guard let pct = lastQualityPercent else { return preset.maxKbps }
        // 按百分比映射到当前档位的上限码率，避免过低设置
        return max(300, Int(Double(preset.maxKbps) * Double(pct) / 100.0))
    }
    
    @MainActor
    func startPreviewIfNeeded(initialProfile: LadderProfile = .standard) {
        // 已初始化则不重复
        guard capturer == nil else { return }

        AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        guard granted else { print("❌ 相机权限未授权"); return }
                        self.videoSource = self.factory.videoSource()
                        
                        // 建立管线链：capturer -> filter -> throttler -> videoSource
                        let filterProcessor = VideoFilterProcessor()
                        let throttler = FrameThrottler()
                        filterProcessor.inner = throttler
                        throttler.inner = self.videoSource
                        throttler.fpsReportHandler = { [weak self] cap, snd in
                                self?.currentCaptureFps = cap
                                self?.currentSendFps = snd
                        }
                        
                        self.videoFilterProcessor = filterProcessor
                        self.frameThrottler = throttler
                        self.capturer = RTCCameraVideoCapturer(delegate: filterProcessor)
                        
                        print("🎬 视频管线已建立: capturer -> VideoFilterProcessor -> FrameThrottler -> videoSource")
                        
                        let track = self.factory.videoTrack(with: self.videoSource, trackId: "local_preview")
                        // 强引用本地轨道并绑定渲染器
                        self.localVideoTrack = track
                        self.localVideoTrack?.add(self.localView)

                        self.currentProfile = initialProfile
                        
                        // 动态计算档位（先获取默认后置摄像头）
                        let devices = RTCCameraVideoCapturer.captureDevices()
                        if let backCamera = devices.first(where: { $0.position == .back }) ?? devices.first {
                            self.calculateLadderForDevice(backCamera)
                        }
                        
                        let preset = self.currentLadder[initialProfile] ?? LadderPreset(width: 1280, height: 720, fps: 60, maxKbps: 3200)
                        // 复用质量百分比
                        self.setMaxBitrateKbps(self.kbpsForProfile(preset))
                        self.recapture(width: preset.width, height: preset.height, fps: preset.fps)
                    }
        }
    }
    
    func applyMountTransform() {
        guard let session = capturer?.captureSession else { 
            print("⚠️ applyMountTransform: capturer.captureSession 为空")
            return 
        }
        
        let want = mountOrientation.avOrientation
        
        let orientationName: String = {
            switch want {
            case .portrait: return "Portrait(竖屏)"
            case .landscapeRight: return "LandscapeRight(横屏右)"
            case .portraitUpsideDown: return "PortraitUpsideDown(倒竖屏)"
            case .landscapeLeft: return "LandscapeLeft(横屏左)"
            @unknown default: return "Unknown"
            }
        }()
        
        var applied = 0
        for conn in session.connections {
            // 只改视频连接
            for port in conn.inputPorts where port.mediaType == .video {
                if conn.isVideoOrientationSupported {
                    conn.videoOrientation = want
                    applied += 1
                }
                if conn.isVideoMirroringSupported {
                    conn.isVideoMirrored = streamMirrored
                }
            }
        }
        print("🧭 编码方向=\(mountOrientation.label) → \(orientationName), 镜像=\(streamMirrored ? "开" : "关"), 已应用连接数=\(applied)")
    }

    // 对外接口（UI 调用）
    func setMountOrientation(_ o: MountOrientation) {
        mountOrientation = o
        applyMountTransform()
        print("🔄 设置方向为 \(o.label)")
    }

    func setStreamMirrored(_ on: Bool) {
        streamMirrored = on
        applyMountTransform()
    }

    // MARK: - WebRTC 内部

   
    
    
    private let factory: RTCPeerConnectionFactory = {
            RTCInitializeSSL()
            
            let enc = RTCDefaultVideoEncoderFactory()
            let dec = RTCDefaultVideoDecoderFactory()
            
            // 强制使用兼容的H.264 Constrained Baseline Profile (42e01f)
            // 解决SRS服务器"not ideal H.264"警告和profile-level-id不匹配问题
            let codecs = RTCDefaultVideoEncoderFactory.supportedCodecs()
            if let h264 = codecs.first(where: {
                        $0.name.caseInsensitiveCompare(kRTCH264CodecName) == .orderedSame ||
                        $0.name.lowercased().contains("h264")
            }) {
                // 创建兼容的H.264编解码器参数
                let compatibleH264 = RTCVideoCodecInfo(
                                name: h264.name,
                                parameters: [
                                   "profile-level-id": "42e01f",  // Constrained Baseline Profile + Level 3.1 (最佳兼容性)
                                   "level-asymmetry-allowed": "1",
                                   "packetization-mode": "1"
                               ]
                )
                enc.preferredCodec = compatibleH264
                print("🎯 强制H.264 profile-level-id=42e01f (Constrained Baseline)")
            }
            
            return RTCPeerConnectionFactory(encoderFactory: enc, decoderFactory: dec)
    }()
    private var pc: RTCPeerConnection!
    private var videoSource: RTCVideoSource!
    private var capturer: RTCCameraVideoCapturer!
    private var videoSender: RTCRtpSender?

    // 统计 & 自适应
    private var statsTimer: Timer?
    private var adaptTimer: Timer?
    private var lastBytesSent: UInt64 = 0
    private var lastTs: TimeInterval = 0
    private var badSeconds = 0
    private var goodSeconds = 0
    
    // 回退：帧数差分估算 fps
    private var lastFramesSent: UInt64 = 0
    
    // ❌ 自动档位调整已完全禁用 - 档位控制方式：
    // 1. 后端推送：ptype="type", type="high"/"standard"
    // 2. UI手动：ContentView 的 ↑升档/↓降档 按钮
    // 3. 初始化：startPreviewIfNeeded/startPublish 的 initialProfile 参数
    private var autoAdaptEnabled = false  // 固定为false，不可修改
    
    // 温和自适应：只改码率不上下采集档位，避免重启采集闪烁
   var gentleAdaptMode = true
   private var lastAdaptAt: TimeInterval = 0
   private let ADAPT_MIN_INTERVAL_SEC: TimeInterval = 8

    // 阈值（这些阈值已无效，因为自动调整已禁用）
    private let BAD_KBPS_FACTOR: Double = 0.60
    private let BAD_FPS_FACTOR:  Double = 0.80
    private let BAD_HOLD_SEC = 4
    private let GOOD_HOLD_SEC = 15

    // 曝光补偿（可选）
    @Published var exposureBiasEV: Float = 0
    private var pendingEV: Float?
    
    // 手动对焦距离
    @Published var focusDistance: Float = 0.5  // 0.0~1.0
    private var pendingFocus: Float?
    
    // 视频滤镜参数
    @Published var videoBrightness: Float = 0.0   // -1.0~1.0
    @Published var videoSaturation: Float = 1.0   // 0.0~2.0
    @Published var videoContrast: Float = 1.0     // 0.0~4.0
    private var ciContext: CIContext?
    private var needsVideoFilter: Bool = false

    override init() {
        super.init()
        // 启用相机自动控制的默认偏好（自动曝光/白平衡/对焦）
        localView.videoContentMode = .scaleAspectFill
        loadTokenIfNeeded() // 动态流名：使用你的读取逻辑
        NotificationCenter.default.addObserver(self, selector: #selector(onLogoutRequired),
                                               name: NSNotification.Name("LogoutRequired"), object: nil)
        if let cached = ConfigManager.shared.getCurrentConfig() {
            applyThinRemoteConfigInit(cached)
        }
        
        NotificationCenter.default.addObserver(
                self,
                selector: #selector(onThinConfigUpdated(_:)),
                name: .thinConfigUpdated,
                object: nil
        )
        
    }
    
    @objc private func onThinConfigUpdated(_ note: Notification) {
            // 优先使用消息里携带的 cfg
            if let cfg = note.userInfo?["cfg"] as? ThinRemoteConfig {
                DispatchQueue.main.async { self.applyThinRemoteConfig(cfg) }
                return
            }
            
    }

    deinit {
        statsTimer?.invalidate()
        adaptTimer?.invalidate()
        RTCCleanupSSL()
        NotificationCenter.default.removeObserver(self)
    }
    
   
    func applyProfileBitrateOnly(_ p: LadderProfile) {
            guard let preset = currentLadder[p] else { return }
            currentProfile = p
            // 码率按百分比作为上限
            //setMaxBitrateKbps(effectiveMaxKbpsForCurrentProfile())
            setMaxBitrateKbps(effectiveMaxKbpsForCurrentProfile())
            // 采集用手动 FPS 作为上限（自动仍可往下压）
            //recapture(width: preset.width, height: preset.height, fps: preset.fps)
            recapture(width: preset.width, height: preset.height, fps: preset.fps)
            print("🎚️ 软切档位=\(p) 上限=\(preset.maxKbps)kbps")
    }

    // MARK: - Token（你的原方法，保持不变）
    private func loadTokenIfNeeded() {
        if let permanentToken = UserDefaults.standard.string(forKey: "permanent_token") {
            streamKey = permanentToken
            print("✅ 已加载 permanent_token 作为 streamKey")
        } else {
            print("⚠️ 未找到 permanent_token，请先登录")
            NotificationCenter.default.post(name: NSNotification.Name("LogoutRequired"), object: nil)
        }
    }

    @objc private func onLogoutRequired() {
        // 可在这里清理资源/跳转登录
    }

    // 如果登录后从服务器拿到新的流名，也可以直接调用它
    func updateStreamKey(_ newKey: String) {
        guard !newKey.isEmpty else { return }
        if newKey == streamKey { return }
        print("🔄 更新流名：\(streamKey) → \(newKey)")
        streamKey = newKey
        UserDefaults.standard.set(newKey, forKey: "permanent_token")
        if isPublishing {
            Task { @MainActor in
                stopPublish()
                try? await Task.sleep(nanoseconds: 150_000_000)
                startPublish() // 新流名立即生效
            }
        }
    }
    
    
    func startPublish(initialProfile: LadderProfile = .standard) {
        guard !streamKey.isEmpty else {
            print("❌ 无流名：请先登录或写入 permanent_token")
            return
        }
        // 建立 PeerConnection
        let cfg = RTCConfiguration()
        cfg.sdpSemantics = .unifiedPlan
        cfg.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        cfg.continualGatheringPolicy = .gatherContinually
        //cfg.iceConnectionReceiveTimeout = 30000  // 30秒ICE连接超时
        cfg.iceBackupCandidatePairPingInterval = 5000  // 5秒备用候选对ping间隔
       
           // 优化DTLS配置以提高连接稳定性
           cfg.iceTransportPolicy = .all  // 允许所有类型的ICE传输
           cfg.bundlePolicy = .maxBundle  // 强制使用BUNDLE策略
           cfg.rtcpMuxPolicy = .require   // 要求RTCP复用
        
        
        
        let cons = RTCMediaConstraints(mandatoryConstraints: nil,
                                       optionalConstraints: ["DtlsSrtpKeyAgreement":"true"])
        pc = factory.peerConnection(with: cfg, constraints: cons, delegate: self)

        // 音频轨
        //let audioSrc = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        //let audioTrack = factory.audioTrack(with: audioSrc, trackId: "audio0")
        //_ = pc.add(audioTrack, streamIds: ["s0"])

        // 视频轨：优先复用预览管线
        if let previewTrack = localVideoTrack, capturer != nil {
            // 复用预览的采集与轨道
            videoSender = pc.add(previewTrack, streamIds: ["s0"]) // 保存 sender，便于设码率
            print("🔄 推流复用预览管线（滤镜已就绪: \(videoFilterProcessor != nil)）")
        } else {
            // 无预览时才初始化采集与轨道
            videoSource = factory.videoSource()
            
            // 建立管线链：capturer -> filter -> throttler -> videoSource
            let filterProcessor = VideoFilterProcessor()
            let throttler = FrameThrottler()
            filterProcessor.inner = throttler
            throttler.inner = videoSource
            throttler.fpsReportHandler = { [weak self] cap, snd in
                    self?.currentCaptureFps = cap
                    self?.currentSendFps = snd
            }
            
            self.videoFilterProcessor = filterProcessor
            self.frameThrottler = throttler
            capturer = RTCCameraVideoCapturer(delegate: filterProcessor)
            
            print("🎬 推流视频管线已建立: capturer -> VideoFilterProcessor -> FrameThrottler -> videoSource")
            
            let videoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
            localVideoTrack = videoTrack                    // 强引用本地轨
            localVideoTrack?.add(localView)                 // 绑定渲染器
            videoSender = pc.add(videoTrack, streamIds: ["s0"]) // 保存 sender
            
            // 动态计算档位（先获取默认后置摄像头）
            let devices = RTCCameraVideoCapturer.captureDevices()
            if let backCamera = devices.first(where: { $0.position == .back }) ?? devices.first {
                calculateLadderForDevice(backCamera)
            }
            
            // 直接按初始档位启动采集
            let preset = currentLadder[initialProfile] ?? LadderPreset(width: 1280, height: 720, fps: 60, maxKbps: 3200)
            recapture(width: preset.width, height: preset.height, fps: preset.fps)
        }

        // 初始档位（设上限 + 采集）
        applyProfile(initialProfile)

        // Offer（发送端不接收远端）
        let sdpCons = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio":"false","OfferToReceiveVideo":"false"],
            optionalConstraints: nil
        )
        
        pc.offer(for: sdpCons) { [weak self] sdp, err in
            guard let self, let sdp else { print("offer err", err ?? "nil"); return }
            self.pc.setLocalDescription(sdp) { _ in }
            Task {
                do {
                    let ans = try await self.postOfferToSRS(
                        apiPath: "/rtc/v1/publish/",
                        streamurl: "webrtc://\(self.srsIP)/\(self.app)/\(self.streamKey)",
                        offer: sdp.sdp
                    )
                    self.pc.setRemoteDescription(.init(type: .answer, sdp: ans)) { err in
                        if let err { print("setRemoteDescription:", err) }
                        else {
                            DispatchQueue.main.async {
                                self.isPublishing = true
                                WebSocketManager.isPublishingFlag = 1
                                self.startStats()   // 启动统计 + 自适应
                            }
                            print("✅ 发布成功：\(self.streamKey)")
                        }
                    }
                } catch {
                    print("❌ 发布失败：\(error.localizedDescription)")
                }
            }
        }
    }
    
    // 类内新增：SDP 改写（确保 H.264 fmtp 关键参数）
    private func mungeH264ForSRS(_ sdp: String) -> String {
        // ... existing code ...
        var lines = sdp.components(separatedBy: "\r\n")
        var h264PT: String?
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("a=rtpmap:") && lower.contains("h264/90000") {
                if let colon = line.firstIndex(of: ":"), let space = line.firstIndex(of: " ") {
                    h264PT = String(line[line.index(after: colon)..<space])
                    break
                }
            }
        }
        guard let pt = h264PT else { return sdp }
        var modified = false
        for i in 0..<lines.count {
            let l = lines[i]
            if l.lowercased().hasPrefix("a=fmtp:\(pt)") {
                modified = true
                let parts = l.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                var kvStr = parts.count > 1 ? String(parts[1]) : ""
                var dict: [String: String] = [:]
                for pair in kvStr.split(separator: ";") {
                    let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    if kv.count == 2 { dict[String(kv[0])] = String(kv[1]) }
                }
                dict["packetization-mode"] = "1"
                dict["profile-level-id"] = dict["profile-level-id"] ?? "42e01f"
                dict["level-asymmetry-allowed"] = "1"
                
                // ✅ 超严格CBR：起始/最小/最大码率几乎相同，波动±3%
                let targetKbps = currentLadder[currentProfile]?.maxKbps ?? 3200
                let minKbps = Int(Double(targetKbps) * 0.97)
                let maxKbps = Int(Double(targetKbps) * 1.03)
                
                dict["x-google-start-bitrate"] = "\(targetKbps)"
                dict["x-google-min-bitrate"] = "\(minKbps)"
                dict["x-google-max-bitrate"] = "\(maxKbps)"
                
                let merged = dict.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
                lines[i] = "a=fmtp:\(pt) \(merged)"
                break
            }
        }
        if !modified {
            let appended = "a=fmtp:\(pt) level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f"
            if let idx = lines.firstIndex(where: { $0.lowercased().hasPrefix("a=rtpmap:\(pt)") }) {
                lines.insert(appended, at: idx + 1)
            } else {
                lines.append(appended)
            }
        }
        return lines.joined(separator: "\r\n")
        // ... existing code ...
    }
    
    

    // 发给 SRS 并设置 Answer
    private func postAndSetAnswer(local: RTCSessionDescription) {
        Task {
            do {
                let ans = try await self.postOfferToSRS(
                    apiPath: "/rtc/v1/publish/",
                    streamurl: "webrtc://\(self.srsIP)/\(self.app)/\(self.streamKey)",
                    offer: local.sdp
                )
                self.pc.setRemoteDescription(.init(type: .answer, sdp: ans)) { err in
                    if let err { print("setRemoteDescription:", err) }
                    else {
                        DispatchQueue.main.async {
                            self.isPublishing = true
                            WebSocketManager.isPublishingFlag = 1
                            self.startStats()
                        }
                        print("✅ 发布成功：\(self.streamKey)")
                    }
                }
            } catch {
                print("❌ 发布失败：\(error.localizedDescription)")
            }
        }
    }

    // 简单等待 ICE 完整（最多 timeoutSec 秒）
    private func waitForIceComplete(timeoutSec: TimeInterval,
                                    done: @escaping (RTCSessionDescription?) -> Void) {
        let deadline = Date().addingTimeInterval(timeoutSec)
        func poll() {
            if self.pc.iceGatheringState == .complete, let ld = self.pc.localDescription {
                done(ld); return
            }
            if Date() > deadline {
                done(self.pc.localDescription); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        poll()
    }


    @MainActor
    func stopPublish() {
        adaptTimer?.invalidate(); adaptTimer = nil
        statsTimer?.invalidate(); statsTimer = nil
        badSeconds = 0; goodSeconds = 0
        kbpsHistory.removeAll()  // ✅ 清空码率历史
        WebSocketManager.isPublishingFlag = 0
        WebSocketManager.publishingKbps = 0
        WebSocketManager.publishingFps = 0
        isPublishing = false
        pc?.close(); pc = nil
        print("⏹️ 已停止发布")
    }

    // MARK: - 相机控制（手动对焦 + 自动 AE/AWB + EV）
    private func configureCameraAutoModes(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            // ✅ 改为手动对焦模式（客户需求）
            if device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            // 可选：设置中心曝光点
            if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            
            
            // 关闭 HDR，减少发热/延迟（若需要）
            if #available(iOS 17.0, *) {
                   if device.automaticallyAdjustsVideoHDREnabled {
                       device.automaticallyAdjustsVideoHDREnabled = false
                   }
            }
            
            
            
            if device.isVideoHDREnabled { device.isVideoHDREnabled = false }
            device.unlockForConfiguration()
        } catch {
            print("⚠️ 相机配置失败：\(error.localizedDescription)")
        }
    }

    func setExposureBias(ev: Float) {
        guard let devInput = capturer?.captureSession.inputs.first as? AVCaptureDeviceInput else {
            pendingEV = ev; return
        }
        let dev = devInput.device
        do {
            try dev.lockForConfiguration()
            if dev.isExposureModeSupported(.continuousAutoExposure) {
                dev.exposureMode = .continuousAutoExposure
            }
            let want = max(dev.minExposureTargetBias, min(ev, dev.maxExposureTargetBias))
            dev.setExposureTargetBias(want)
            dev.unlockForConfiguration()
            exposureBiasEV = want
            print("🔆 EV = \(want)  (range \(dev.minExposureTargetBias) ~ \(dev.maxExposureTargetBias))")
        } catch {
            print("❌ 设置 EV 失败：\(error.localizedDescription)")
        }
    }
    
    // ✅ 手动对焦距离（0.0=近处，1.0=无穷远）
    func setFocus(_ distance: Float) {
        guard let devInput = capturer?.captureSession.inputs.first as? AVCaptureDeviceInput else {
            pendingFocus = distance; return
        }
        let dev = devInput.device
        do {
            try dev.lockForConfiguration()
            // 先切换到手动对焦模式
            if dev.isFocusModeSupported(.locked) {
                dev.focusMode = .locked
            }
            // 设置对焦距离（0.0=近，1.0=远）
            let clamped = max(0.0, min(1.0, distance))
            dev.setFocusModeLocked(lensPosition: clamped)
            dev.unlockForConfiguration()
            focusDistance = clamped
            print("🔍 对焦距离 = \(clamped) (0.0=近处 1.0=无穷远)")
        } catch {
            print("❌ 设置对焦失败：\(error.localizedDescription)")
        }
    }

    // 数码变焦（可选）
    func setZoom(_ factor: CGFloat) {
        guard let devInput = capturer?.captureSession.inputs.first as? AVCaptureDeviceInput else { return }
        let dev = devInput.device
        do {
            try dev.lockForConfiguration()
            let safe = max(1.0, min(factor, dev.activeFormat.videoMaxZoomFactor))
            dev.videoZoomFactor = safe
            dev.unlockForConfiguration()
            print("🔍 变焦=\(safe)x")
        } catch {
            print("❌ 变焦失败：\(error.localizedDescription)")
        }
    }
    
    // MARK: - 视频滤镜控制（亮度/饱和度/对比度）
    func setVideoBrightness(_ value: Float) {
        let clamped = max(-1.0, min(1.0, value))
        videoBrightness = clamped
        
        if videoFilterProcessor == nil {
            print("⚠️ videoFilterProcessor 为 nil！滤镜未初始化")
        } else {
            videoFilterProcessor?.brightness = clamped
            print("✅ videoFilterProcessor.brightness 已设置为 \(clamped)")
        }
        
        updateFilterEnabled()
        print("🌞 亮度 = \(clamped)")
    }
    
    func setVideoSaturation(_ value: Float) {
        let clamped = max(0.0, min(2.0, value))
        videoSaturation = clamped
        
        if videoFilterProcessor == nil {
            print("⚠️ videoFilterProcessor 为 nil！滤镜未初始化")
        } else {
            videoFilterProcessor?.saturation = clamped
            print("✅ videoFilterProcessor.saturation 已设置为 \(clamped)")
        }
        
        updateFilterEnabled()
        print("🎨 饱和度 = \(clamped)")
    }
    
    func setVideoContrast(_ value: Float) {
        let clamped = max(0.0, min(4.0, value))
        videoContrast = clamped
        
        if videoFilterProcessor == nil {
            print("⚠️ videoFilterProcessor 为 nil！滤镜未初始化")
        } else {
            videoFilterProcessor?.contrast = clamped
            print("✅ videoFilterProcessor.contrast 已设置为 \(clamped)")
        }
        
        updateFilterEnabled()
        print("📊 对比度 = \(clamped)")
    }
    
    private func updateFilterEnabled() {
        // 只有当任一参数偏离默认值时才启用滤镜
        let needsFilter = videoBrightness != 0.0 || videoSaturation != 1.0 || videoContrast != 1.0
        videoFilterProcessor?.enabled = needsFilter
        print("🔧 滤镜状态更新: enabled=\(needsFilter) | B=\(videoBrightness) S=\(videoSaturation) C=\(videoContrast)")
    }

    
    func toggleCamera() {
        // ... existing code ...
        guard let curInput = capturer?.captureSession.inputs.first as? AVCaptureDeviceInput else { return }
        let newPos: AVCaptureDevice.Position = (curInput.device.position == .back) ? .front : .back
        guard let dev = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == newPos }) else { return }

        let formats = RTCCameraVideoCapturer.supportedFormats(for: dev)
        //let formats = RTCCameraVideoCapturer.supportedFormats(for: dev)
        // 设备整体最大采集FPS（用于诊断）
        let deviceMaxOverallFPS = Int(
            formats.compactMap { fmt in fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() }.max() ?? 0
        )
        print("🔎 设备=\(dev.localizedName) 位置=\(newPos == .back ? "后置" : "前置") 支持格式=\(formats.count) 设备整体最大FPS=\(deviceMaxOverallFPS)")

        let preset = currentLadder[currentProfile] ?? LadderPreset(width: 1280, height: 720, fps: 60, maxKbps: 3200)
        let targetWidth = preset.width
        let targetHeight = preset.height
        let baseFps = preset.fps
        
        // HFR优先：先按最高maxFrameRate降序，其次分辨率贴近目标
           guard let best = formats.sorted(by: { f0, f1 in
               let max0 = Int(f0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
               let max1 = Int(f1.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
               if max0 != max1 { return max0 > max1 }
               let a = CMVideoFormatDescriptionGetDimensions(f0.formatDescription)
               let b = CMVideoFormatDescriptionGetDimensions(f1.formatDescription)
               let d0 = abs(Int(a.width) - targetWidth) + abs(Int(a.height) - targetHeight)
               let d1 = abs(Int(b.width) - targetWidth) + abs(Int(b.height) - targetHeight)
               return d0 < d1
           }).first else { return }

        let maxFps = Int(best.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
           let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
           print("✅ 选中格式 \(dims.width)x\(dims.height) 最大FPS=\(maxFps)")

        // 采集FPS：优先手动覆盖，否则使用设备最大值
       let useFps = manualFpsOverride.map { min(maxFps, $0) } ?? maxFps
       print("🎯 最终采集FPS=\(useFps) (设备最大=\(maxFps))")

        capturer.stopCapture { [weak self] in
               guard let self = self else { return }
               
               // ✅ 关键：切换摄像头后重新计算档位配置
               self.calculateLadderForDevice(dev)
               
               self.configureCameraAutoModes(dev)
               self.capturer.startCapture(with: dev, format: best, fps: useFps)
               self.applyMountTransform()
               if let ev = self.pendingEV { self.pendingEV = nil; self.setExposureBias(ev: ev) }
               if let focus = self.pendingFocus { self.pendingFocus = nil; self.setFocus(focus) }
               print("🔄 切到\(newPos == .back ? "后" : "前")置摄像头，\(targetWidth)x\(targetHeight) @\(useFps)fps")
               
               // ✅ 保持完整的视频处理链：capturer -> filter -> throttler -> source
               if self.frameThrottler == nil { 
                   let t = FrameThrottler()
                   t.inner = self.videoSource
                   self.frameThrottler = t 
               }
               
               // 重新连接滤镜链
               if let filter = self.videoFilterProcessor {
                   self.capturer.delegate = filter
                   print("✅ 切换摄像头后重连滤镜链: capturer -> filter -> throttler -> source")
               } else {
                   self.capturer.delegate = self.frameThrottler!
                   print("⚠️ 切换摄像头：无滤镜，直接连接节流器")
               }
               
               let currentTarget = self.frameThrottler?.targetSendFps ?? 60
               self.frameThrottler?.targetSendFps = min(currentTarget, 60)
               print("🎯 推送FPS（平均）上限= \(self.frameThrottler?.targetSendFps ?? 60)")
           }
        // ... existing code ...
    }

    // MARK: - 档位应用（改码率上限 + 采集）
    func applyProfile(_ p: LadderProfile) {
        guard let preset = currentLadder[p] else { return }
        currentProfile = p
        setMaxBitrateKbps(preset.maxKbps)
        recapture(width: preset.width, height: preset.height, fps: preset.fps)
        print("♻️ 档位=\(p) → \(preset.width)x\(preset.height) @\(preset.fps)fps, 上限 \(preset.maxKbps)kbps")
    }

    func setMaxBitrateKbps(_ kbps: Int) {
        // 记录 sender
        if videoSender == nil {
            videoSender = pc?.senders.first(where: { $0.track?.kind == kRTCMediaStreamTrackKindVideo })
        }
        guard let sender = videoSender else { return }
        var params = sender.parameters
        if params.encodings.isEmpty { params.encodings = [RTCRtpEncodingParameters()] }
        
        // ✅ 超严格CBR策略：min/max非常接近，波动控制在±3%以内
        let targetBps = kbps * 1000
        let minBps = Int(Double(targetBps) * 0.97)  // 最小97%
        let maxBps = Int(Double(targetBps) * 1.03)  // 最大103%
        
        params.encodings[0].maxBitrateBps = NSNumber(value: maxBps)
        params.encodings[0].minBitrateBps = NSNumber(value: minBps)
        
        // 设置网络优先级为最高
        params.encodings[0].networkPriority = .high
        
        // 禁用自适应降级（保持码率稳定，即使掉帧）
        //params.degradationPreference = .maintainResolution
        
        // ✅ 这个版本用属性 setter，而不是 setParameters(...)
        sender.parameters = params
        print("🎛️ 超稳定码率: \(minBps/1000)-\(maxBps/1000) kbps (±3%)")
    }

    private func recapture(width: Int, height: Int, fps: Int) {
        // 选择摄像头（沿用当前，若无则取后置）
        
        let devOpt: AVCaptureDevice? = {
                if let inDev = capturer?.captureSession.inputs.first as? AVCaptureDeviceInput {
                    return inDev.device
                }
                let devices = RTCCameraVideoCapturer.captureDevices()
                return devices.first(where: { $0.position == .back }) ?? devices.first
            }()
          guard let dev = devOpt else {
               print("❌ 无可用摄像头设备，跳过重采集")
               return
           }
           guard let capturer = self.capturer else {
               print("❌ capturer 尚未初始化或已释放，跳过重采集")
               return
           }

        let formats = RTCCameraVideoCapturer.supportedFormats(for: dev)
           let deviceMaxOverallFPS = Int(
               formats.compactMap { fmt in fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() }.max() ?? 0
           )
           print("🔎 重采集 设备=\(dev.localizedName) 位置=\(dev.position == .back ? "后置" : "前置") 支持格式=\(formats.count) 设备整体最大FPS=\(deviceMaxOverallFPS)")

        // HFR优先：先按最高maxFrameRate降序，其次分辨率贴近目标
            guard let best = formats.sorted(by: { f0, f1 in
                let max0 = Int(f0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                let max1 = Int(f1.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                if max0 != max1 { return max0 > max1 }
                let a = CMVideoFormatDescriptionGetDimensions(f0.formatDescription)
                let b = CMVideoFormatDescriptionGetDimensions(f1.formatDescription)
                let d0 = abs(Int(a.width) - width) + abs(Int(a.height) - height)
                let d1 = abs(Int(b.width) - width) + abs(Int(b.height) - height)
                return d0 < d1
            }).first else { return }

          
        let maxFps = Int(best.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
        let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
        print("✅ 重采集选中格式 \(dims.width)x\(dims.height) 最大FPS=\(maxFps)")

        // 采集FPS：优先手动覆盖，否则使用设备最大值
           let useFps = manualFpsOverride.map { min(maxFps, $0) } ?? maxFps
           print("🎯 重采集最终采集FPS=\(useFps) (设备最大=\(maxFps))")

            capturer.stopCapture { [weak self] in
               guard let self else { return }
               self.configureCameraAutoModes(dev)
               capturer.startCapture(with: dev, format: best, fps: useFps)
               self.applyMountTransform()
               if let ev = self.pendingEV { self.pendingEV = nil; self.setExposureBias(ev: ev) }
               if let focus = self.pendingFocus { self.pendingFocus = nil; self.setFocus(focus) }
           }
        
    }

    // MARK: - 实时统计 + 自适应
    private func startStats() {
        statsTimer?.invalidate()
        adaptTimer?.invalidate()
        lastBytesSent = 0; lastTs = 0
        badSeconds = 0; goodSeconds = 0

        // 每秒抓一次 stats
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self, let pc = self.pc else { return }
                pc.statistics { report in
                    var bytesTotal: UInt64 = 0
                    var fpsNow: Int = 0
                    var framesSentTotal: UInt64 = 0
                    var qlr: String? = nil

                    for s in report.statistics.values {
                        let type = s.type
                        let isVideo = ((s.values["mediaType"] as? String)?.lowercased() == "video") ||
                                      ((s.values["kind"] as? String)?.lowercased() == "video")
                        if type == "outbound-rtp" && isVideo {
                            if let v = s.values["bytesSent"] {
                                if let num = v as? NSNumber { bytesTotal &+= num.uint64Value }
                                else if let d = v as? Double { bytesTotal &+= UInt64(d) }
                                else if let i = v as? Int { bytesTotal &+= UInt64(i) }
                                else if let str = v as? String, let val = UInt64(str) { bytesTotal &+= val }
                            }
                            if let v = s.values["framesPerSecond"] {
                                if let num = v as? NSNumber { fpsNow = max(fpsNow, Int(num.doubleValue.rounded())) }
                                else if let d = v as? Double { fpsNow = max(fpsNow, Int(d.rounded())) }
                                else if let str = v as? String, let d = Double(str) { fpsNow = max(fpsNow, Int(d.rounded())) }
                            }
                            if let v = s.values["framesSent"] {
                                if let num = v as? NSNumber { framesSentTotal &+= num.uint64Value }
                                else if let d = v as? Double { framesSentTotal &+= UInt64(d) }
                                else if let i = v as? Int { framesSentTotal &+= UInt64(i) }
                                else if let str = v as? String, let val = UInt64(str) { framesSentTotal &+= val }
                            }
                            if let r = s.values["qualityLimitationReason"] as? String { qlr = r }
                        } else if type == "track" && isVideo {
                            if let r = s.values["qualityLimitationReason"] as? String { qlr = r }
                        }
                    }
                    DispatchQueue.main.async {
                        let now = CFAbsoluteTimeGetCurrent()
                        defer {
                            self.lastBytesSent = bytesTotal
                            self.lastFramesSent = framesSentTotal
                            self.lastTs = now
                        }
                        if self.lastTs > 0, bytesTotal >= self.lastBytesSent {
                            let dt = now - self.lastTs
                            let dBytes = bytesTotal &- self.lastBytesSent
                            let instantKbps = Int((Double(dBytes) * 8.0 / max(dt, 0.001)) / 1000.0)
                            
                            // ✅ 码率平滑：使用移动平均，减少瞬时波动
                            self.kbpsHistory.append(instantKbps)
                            if self.kbpsHistory.count > self.kbpsHistorySize {
                                self.kbpsHistory.removeFirst()
                            }
                            let smoothedKbps = self.kbpsHistory.reduce(0, +) / max(self.kbpsHistory.count, 1)
                            
                            self.currentKbps = smoothedKbps
                            WebSocketManager.publishingKbps = smoothedKbps
                        }
                        if fpsNow == 0, self.lastTs > 0, framesSentTotal >= self.lastFramesSent {
                            let dt = now - self.lastTs
                            let dFrames = framesSentTotal &- self.lastFramesSent
                            self.currentFps = Int(Double(dFrames) / max(dt, 0.001))
                        } else {
                            self.currentFps = fpsNow
                        }
                        WebSocketManager.publishingFps = self.currentCaptureFps
                        
                        // 🔍 详细的码率监控日志
                        if let preset = self.currentLadder[self.currentProfile] {
                            let targetKbps = preset.maxKbps
                            let actualKbps = self.currentKbps
                            let percentage = Int((Double(actualKbps) / Double(targetKbps)) * 100)
                            let qlrStr = qlr ?? "none"
                            print("📊 码率监控: \(actualKbps)/\(targetKbps) kbps (\(percentage)%) | FPS: \(self.currentFps) | QLR: \(qlrStr)")
                        }
                        
                        self.evaluate(qlr: qlr)
                    }
                }
        }

        // 自适应节拍器
        adaptTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tickAdapt()
        }
    }
    
    private func evaluate(qlr: String?) {
        // ❌ 自动档位调整已禁用 - 用户通过后端手动控制档位
        // 这个方法保留但不会触发档位切换
        guard autoAdaptEnabled, let preset = currentLadder[currentProfile] else { return }
        let cap = effectiveMaxKbpsForCurrentProfile()
        let fpsTarget = frameThrottler?.targetSendFps ?? preset.fps
        let badByKbps = currentKbps < Int(Double(cap) * BAD_KBPS_FACTOR)
        let badByFps  = currentFps < Int(Double(fpsTarget) * BAD_FPS_FACTOR)
        let badByQLR  = (qlr == "bandwidth" || qlr == "cpu")

        let isBad = badByKbps || badByFps || badByQLR

        if isBad {
            badSeconds += 1
            goodSeconds = max(0, goodSeconds - 1)
        } else {
            goodSeconds += 1
            badSeconds = max(0, badSeconds - 1)
        }
    }

    private func tickAdapt() {
        // ❌ 自动档位调整已禁用 - 用户通过后端手动控制档位
        guard autoAdaptEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if badSeconds >= BAD_HOLD_SEC {
            if let down = stepDown(from: currentProfile), now - lastAdaptAt >= ADAPT_MIN_INTERVAL_SEC {
                print("⬇️ 降档：\(currentProfile) → \(down)  (badSeconds=\(badSeconds))")
                if gentleAdaptMode { applyProfileBitrateOnly(down) } else { applyProfile(down) }
                lastAdaptAt = now
                badSeconds = 0; goodSeconds = 0
                if down == LOWEST_PROFILE { lowFpsIndex = 0 }
            } else {
                // 已是最低档位：按帧率继续降，保持实时性
                if currentProfile == LOWEST_PROFILE,
                   lowFpsIndex < LOW_FPS_STEPS.count - 1,
                   now - lastAdaptAt >= ADAPT_MIN_INTERVAL_SEC,
                   let preset = currentLadder[currentProfile] {
                    lowFpsIndex += 1
                    let targetFps = LOW_FPS_STEPS[lowFpsIndex]
                    recapture(width: preset.width, height: preset.height, fps: targetFps)
                    print("📉 低档降帧：\(preset.width)x\(preset.height) @\(targetFps)fps")
                    lastAdaptAt = now
                    badSeconds = 0; goodSeconds = 0
                } else {
                    badSeconds = 0
                }
            }
            return
        }
        if goodSeconds >= GOOD_HOLD_SEC {
            goodSeconds = 0
                /*
                if let up = stepUp(from: currentProfile), now - lastAdaptAt >= ADAPT_MIN_INTERVAL_SEC {
                    print("⬆️ 升档：\(currentProfile) → \(up)  (goodSeconds=\(goodSeconds))")
                    // 升档：使用完整档位应用，切换到目标分辨率与 fps
                    applyProfile(up)
                    lastAdaptAt = now
                    badSeconds = 0; goodSeconds = 0
                } else {
                    goodSeconds = 0
                }*/
        }
    }

    
    
    private func stepUp(from p: LadderProfile) -> LadderProfile? {
        let n = p.rawValue + 1
        return (n < LadderProfile.allCases.count) ? LadderProfile(rawValue: n) : nil
    }
    private func stepDown(from p: LadderProfile) -> LadderProfile? {
        let n = p.rawValue - 1
        return (n >= 0) ? LadderProfile(rawValue: n) : nil
    }

    // MARK: - SRS HTTP
    private func postOfferToSRS(apiPath: String, streamurl: String, offer: String) async throws -> String {
        let url = URL(string: "http://\(srsIP):1985\(apiPath)")!
        let body: [String: Any] = [
            "api": "http://\(srsIP):1985\(apiPath)",
            "streamurl": streamurl,
            "sdp": offer
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if let code = json["code"] as? Int, code != 0 {
            throw NSError(domain: "srs", code: code, userInfo: [NSLocalizedDescriptionKey: "SRS code=\(code)"])
        }
        guard let sdp = json["sdp"] as? String else {
            throw NSError(domain: "srs", code: -1, userInfo: [NSLocalizedDescriptionKey: "no sdp in response"])
        }
        return sdp
    }
}

// MARK: - PC Delegate（推流场景回调很少）
// MARK: - PC Delegate
extension WebRTCManager: RTCPeerConnectionDelegate {
    // 信令状态变化
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange stateChanged: RTCSignalingState) {}

    // 旧版（Plan B）：添加/移除媒体流
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didRemove stream: RTCMediaStream) {}

    // 需要重新协商
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    // ICE 连接状态变化
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCIceConnectionState) {}

    // ICE 收集状态变化
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCIceGatheringState) {}

    // 生成候选
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didGenerate candidate: RTCIceCandidate) {}

    // ✅ 必须补的：移除候选
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didRemove candidates: [RTCIceCandidate]) {}

    // DataChannel 打开
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didOpen dataChannel: RTCDataChannel) {}

    // Unified Plan：收到远端轨（拉流时用得到）
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd rtpReceiver: RTCRtpReceiver,
                        streams: [RTCMediaStream]) {
        if let track = rtpReceiver.track as? RTCVideoTrack {
            track.add(remoteView)
        }
    }

    // （部分版本会有）整体连接状态变化
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange state: RTCPeerConnectionState) {}
}


