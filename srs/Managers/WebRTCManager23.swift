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

// MARK: - Array安全下标扩展
extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 帧节流器（固定时间间隔算法：确保推送FPS稳定）
final class FrameThrottler: NSObject, RTCVideoCapturerDelegate {
    weak var inner: RTCVideoCapturerDelegate?           // 🔥 推送输出（受后端fps控制）
    weak var previewDelegate: RTCVideoCapturerDelegate? // 🔥 预览输出（固定60fps）
    
    // 🔥 推送FPS硬上限（58、59、60 都限制为 58）
    private let maxAllowedFps: Int = 58
    
    var targetSendFps: Int = 58 {
        didSet {
            // 🔥 硬上限58fps：58、59、60都变成58
            if targetSendFps > maxAllowedFps {
                targetSendFps = maxAllowedFps
            }
            print("🎯 [FrameThrottler] 推送目标FPS变更: \(oldValue) → \(targetSendFps) (硬上限\(maxAllowedFps))")
        }
    }
    
    // 🔥 预览固定60fps（从120/240fps采集中节流）
    private let previewFps: Int = 60
    private var previewSentCounter: Int = 0
    private var previewFrameAccumulator: Double = 0  // 🔥 预览帧累加器
    
    // 🔥 推送受后端fps控制
    private var sendFrameAccumulator: Double = 0     // 🔥 推送帧累加器
    private var pendingFrame: RTCVideoFrame?
    private weak var pendingCapturer: RTCVideoCapturer?
    
    // 🔥 采集帧率检测（用于计算等差跳帧比例）
    private var detectedCaptureFps: Int = 60
    private var captureFpsDetectCounter: Int = 0
    private var captureFpsDetectStartTime: Double = 0
    
    var fpsReportHandler: ((Int, Int) -> Void)?
    private var lastReportTsSec: Double = 0
    private var captureCounter: Int = 0
    private var sentCounter: Int = 0
    private var lastFrameWidth: Int32 = 0
    private var lastFrameHeight: Int32 = 0
    private var lastOriginalRotation: RTCVideoRotation = ._0
    
    // 🔥 前置摄像头镜像标志
    var isFrontCamera: Bool = false  // 是否是前置摄像头

    func capturer(_ capturer: RTCVideoCapturer, didCapture videoFrame: RTCVideoFrame) {
        let nowSec = CFAbsoluteTimeGetCurrent()
        
        // 采集计数
        captureCounter += 1
        
        // 记录帧尺寸和旋转（用于日志）
        lastFrameWidth = videoFrame.width
        lastFrameHeight = videoFrame.height
        lastOriginalRotation = videoFrame.rotation
        
        // 缓存最新帧
        pendingFrame = videoFrame
        pendingCapturer = capturer
        
        // 🔥 检测实际采集帧率（每秒更新一次）
        captureFpsDetectCounter += 1
        if captureFpsDetectStartTime == 0 {
            captureFpsDetectStartTime = nowSec
        } else if nowSec - captureFpsDetectStartTime >= 1.0 {
            detectedCaptureFps = max(1, captureFpsDetectCounter)
            captureFpsDetectCounter = 0
            captureFpsDetectStartTime = nowSec
        }
        
        // ========== 🔥 预览输出：等差节流到60fps ==========
        // 累加器算法：每帧累加 (目标fps / 采集fps)，累加 >= 1 时发送
        let previewRatio = Double(previewFps) / Double(max(1, detectedCaptureFps))
        previewFrameAccumulator += previewRatio
        if previewFrameAccumulator >= 1.0 {
            previewFrameAccumulator -= 1.0
            sendPreviewFrame(capturer, videoFrame: videoFrame)
        }
        
        // ========== 🔥 推送输出：等差节流到目标fps ==========
        let sendRatio = Double(targetSendFps) / Double(max(1, detectedCaptureFps))
        sendFrameAccumulator += sendRatio
        if sendFrameAccumulator >= 1.0 {
            sendFrameAccumulator -= 1.0
            sendFrame(capturer, videoFrame: videoFrame)
        }
        
        // 每秒上报一次采集/推送FPS
        if lastReportTsSec == 0 { lastReportTsSec = nowSec }
        if (nowSec - lastReportTsSec) >= 1.0 {
            let cap = captureCounter
            let snd = sentCounter
            let preview = previewSentCounter
            
            DispatchQueue.main.async { [weak self] in
                self?.fpsReportHandler?(cap, snd)
            }
            print("📊 本地FPS 采集=\(cap) 预览=\(preview) 推送=\(snd) 目标=\(targetSendFps) 帧尺寸=\(lastFrameWidth)x\(lastFrameHeight)")
            captureCounter = 0
            sentCounter = 0
            previewSentCounter = 0
            lastReportTsSec = nowSec
        }
    }
    
    // 🔥 发送到预览（固定60fps）
    private func sendPreviewFrame(_ capturer: RTCVideoCapturer, videoFrame: RTCVideoFrame) {
        previewSentCounter += 1
        
        // ✅ 保持固定横屏方向（不做动态补偿，避免画面尺寸变化）
        let fixedFrame = RTCVideoFrame(
            buffer: videoFrame.buffer,
            rotation: ._0,
            timeStampNs: videoFrame.timeStampNs
        )
        previewDelegate?.capturer(capturer, didCapture: fixedFrame)
    }
    
    // 🔥 发送到推送（受后端fps控制）
    private func sendFrame(_ capturer: RTCVideoCapturer, videoFrame: RTCVideoFrame) {
        sentCounter += 1
        
        // ✅ 推送保持固定横屏方向
        let fixedFrame = RTCVideoFrame(
            buffer: videoFrame.buffer,
            rotation: ._0,
            timeStampNs: videoFrame.timeStampNs
        )
        inner?.capturer(capturer, didCapture: fixedFrame)
    }
    
    /// 重置节流器状态（用于重新开始推流时）
    func reset() {
        previewFrameAccumulator = 0
        sendFrameAccumulator = 0
        lastReportTsSec = 0
        captureCounter = 0
        sentCounter = 0
        previewSentCounter = 0
        pendingFrame = nil
        pendingCapturer = nil
        captureFpsDetectCounter = 0
        captureFpsDetectStartTime = 0
    }
}

// MARK: - 阶梯档位（动态根据摄像头能力）
enum LadderProfile: Int, CaseIterable {
    case standard  // 标清
    case high      // 高清
    case ultra     // 超清
    case p4k       // 4K（仅后置）
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
    let fps: Int           // 采集FPS
    let maxKbps: Int
    let maxPushFps: Int    // 🔥 最高推送FPS（根据分辨率限制）
    
    // 兼容旧代码的初始化方法
    init(width: Int, height: Int, fps: Int, maxKbps: Int, maxPushFps: Int = 60) {
        self.width = width
        self.height = height
        self.fps = fps
        self.maxKbps = maxKbps
        self.maxPushFps = maxPushFps
    }
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
   
   // FPS平滑（减少显示波动）
   private var fpsHistory: [Int] = []
   private let fpsHistorySize = 3  // 使用3秒移动平均
   
    // 动态档位配置（根据当前摄像头）
    var currentLadder: [LadderProfile: LadderPreset] = [:]
    
    // 新增：低档位降帧配置（逐步降低 30→24→20→15→10）
    private let LOWEST_PROFILE: LadderProfile = .standard
    private let LOW_FPS_STEPS: [Int] = [60, 50, 45, 40, 35, 30, 24, 20, 15, 12, 10]
    private var lowFpsIndex: Int = 0
    

    
    private var lastQualityPercent: Int? = nil
    private let QUALITY_PERCENT_STEPS: [Int] = Array(1...100)

       // 手动 FPS 覆盖（作为上限，自动逻辑仍可往下压）
    private var manualFpsOverride: Int? = nil
    private let FPS_STEPS: [Int] = [60, 50, 45, 40, 35, 30, 24, 20, 15, 12, 10]
    
    

    
    // 预览/远端
    let localView = RTCMTLVideoView(frame: .zero)
    let remoteView = RTCMTLVideoView(frame: .zero)
    
    private var localVideoTrack: RTCVideoTrack?
    private var frameThrottler: FrameThrottler?
    
    
    // MARK: - 动态档位计算
    /// 根据当前摄像头动态计算档位配置
    // ✅ 固定4档配置（前后置摄像头分别设置）
   private func calculateLadderForDevice(_ device: AVCaptureDevice) {
        // 🔥🔥 全系 16:9 采集（1920x1080），通过 scaleResolutionDownBy 缩放输出
        // scale=1:   1920x1080 (4K档)
        // scale=1.5: 1280x720  (超清档)
        // scale=2:   960x540   (高清档)
        // scale=3:   640x360   (标清档)
        
        if device.position == .back {
            // 🎥 后置摄像头：4档固定（采集 1920x1080 @60fps，16:9 支持更高帧率）
            currentLadder = [
                .p4k:      LadderPreset(width: 1920, height: 1080, fps: 60, maxKbps: 4500, maxPushFps: 60),   // scale=1
                .ultra:    LadderPreset(width: 1280, height: 720,  fps: 60, maxKbps: 3000, maxPushFps: 60),   // scale=1.5
                .high:     LadderPreset(width: 960,  height: 540,  fps: 60, maxKbps: 2000, maxPushFps: 60),   // scale=2
                .standard: LadderPreset(width: 640,  height: 360,  fps: 60, maxKbps: 1500, maxPushFps: 60)    // scale=3
            ]
            print("📐 后置摄像头 - 全系16:9配置（1920x1080采集）：")
            print("   4K    = 1920x1080 (scale=1)   → 4500kbps")
            print("   超清  = 1280x720  (scale=1.5) → 3000kbps")
            print("   高清  = 960x540   (scale=2)   → 2000kbps")
            print("   标清  = 640x360   (scale=3)   → 1500kbps")
        } else {
            // 📱 前置摄像头：4档固定（采集 1920x1080 @60fps，16:9 支持更高帧率）
            currentLadder = [
                .p4k:      LadderPreset(width: 1920, height: 1080, fps: 60, maxKbps: 4500, maxPushFps: 60),   // scale=1
                .ultra:    LadderPreset(width: 1280, height: 720,  fps: 60, maxKbps: 3000, maxPushFps: 60),   // scale=1.5
                .high:     LadderPreset(width: 960,  height: 540,  fps: 60, maxKbps: 1500, maxPushFps: 60),   // scale=2
                .standard: LadderPreset(width: 640,  height: 360,  fps: 60, maxKbps: 1200, maxPushFps: 60)    // scale=3
            ]
            print("📐 前置摄像头 - 全系16:9配置（1920x1080采集）：")
            print("   4K    = 1920x1080 (scale=1)   → 4500kbps")
            print("   超清  = 1280x720  (scale=1.5) → 3000kbps")
            print("   高清  = 960x540   (scale=2)   → 1500kbps")
            print("   标清  = 640x360   (scale=3)   → 1200kbps")
        }
    }
    
    // ✅ 综合计算最终码率（加法分配模型）
    // 🔥 权重 bitrate : fps = 2 : 1（最高码率按比例分配给两个参数）
    // 例如：最高4500kbps → bitrate控制3000kbps + fps控制1500kbps
    private func effectiveMaxKbpsForCurrentProfile() -> Int {
            guard let preset = currentLadder[currentProfile] else { return 1500 }
            
            // 1️⃣ 档位最高码率
            let maxKbps = preset.maxKbps  // 如 4500kbps
            
            // 2️⃣ 按 2:1 分配码率额度
            let bitrateWeight = 2.0
            let fpsWeight = 1.0
            let totalWeight = bitrateWeight + fpsWeight  // 3.0
            
            let bitrateQuota = Double(maxKbps) * (bitrateWeight / totalWeight)  // 3000kbps
            let fpsQuota = Double(maxKbps) * (fpsWeight / totalWeight)          // 1500kbps
            
            // 3️⃣ 计算 bitrate 贡献（0-100% → 0-3000kbps）
            let qualityPercent = lastQualityPercent ?? 100
            let bitrateRatio = Double(qualityPercent) / 100.0
            let bitrateContribution = bitrateQuota * bitrateRatio
            
            // 4️⃣ 计算 fps 贡献（0-100% → 0-1500kbps）
            let baseFps = Double(getMaxPushFpsForCurrentProfile())  // 档位最大推送FPS（如 60）
            let actualFps = Double(targetOutputFPS)                  // 实际推送FPS
            let fpsRatio = min(1.0, actualFps / max(1.0, baseFps))   // FPS比例（0~1）
            let fpsContribution = fpsQuota * fpsRatio
            
            // 5️⃣ 最终码率 = bitrate贡献 + fps贡献
            let result = Int(bitrateContribution + fpsContribution)
            
            print("📊 码率计算(2:1分配): 最高=\(maxKbps)kbps, bitrate=\(qualityPercent)%→\(Int(bitrateContribution))kbps, fps=\(Int(fpsRatio*100))%→\(Int(fpsContribution))kbps → 最终=\(result)kbps")
            
            return max(100, result)  // 保底 100kbps
    }
    
    /// 设置平均推送的目标 FPS（采集保持不变，码率按比例调整）
    /// - Parameter fps: 后端下发的FPS值（0-120），实际推送为 fps/2（0-60）
    func setAverageOutputFPS(_ fps: Int) {
         
        // 🔥 后端下发 fps 范围 0-120，实际推送 = fps / 2，最大58fps
        let maxPushFps = getMaxPushFpsForCurrentProfile()  // 档位最大推送FPS（如60）
        let actualTargetFps = fps / 2  // 后端fps/2 = 实际推送目标
        // 🔥 先限制在档位上限，再限制在硬上限58fps（58、59、60都变成58）
        let profileClamped = max(1, min(actualTargetFps, maxPushFps))
        let clamped = min(profileClamped, maxAllowedPushFps)  // 硬上限58fps
        let oldFps = frameThrottler?.targetSendFps ?? targetOutputFPS
        
        // 🔥 先存储到持久化变量
        targetOutputFPS = clamped
        
        // 🔥 检查 frameThrottler 是否存在
        if frameThrottler == nil {
            print("⚠️ [setAverageOutputFPS] frameThrottler 是 nil！已存储目标FPS=\(clamped)，等待节流器创建")
        } else {
            frameThrottler?.targetSendFps = clamped
            print("✅ [setAverageOutputFPS] 后端fps=\(fps) → 实际推送目标: \(oldFps)fps → \(clamped)fps")
        }
        
        if actualTargetFps > maxPushFps {
            print("⚠️ 后端请求FPS(\(fps)/2=\(actualTargetFps)) 超过档位上限(\(maxPushFps)fps)，已限制为\(clamped)fps")
        }
        
        if currentLadder[currentProfile] != nil {
            let newKbps = effectiveMaxKbpsForCurrentProfile()
            setMaxBitrateKbps(newKbps)
            print("🎛 推送FPS: \(oldFps)fps → \(clamped)fps | 码率调整为: \(newKbps)kbps (±100kb)")
        } else {
            print("🎛 推送FPS = \(clamped)fps")
        }
        
    }
    
    /// 开/关平均节流（关时恢复直通）
    func enableAverageThrottling(_ enabled: Bool) {
        guard let capturer = self.capturer else { return }
        if enabled {
            if frameThrottler == nil {
                let throttler = FrameThrottler()
                throttler.inner = self.videoSource
                throttler.previewDelegate = self.previewVideoSource  // 🔥 预览输出（固定60fps）
                throttler.targetSendFps = targetOutputFPS            // 🔥 只影响推送
                frameThrottler = throttler
                print("🔄 [enableAverageThrottling] 创建新节流器，推送目标FPS: \(targetOutputFPS)fps，预览固定60fps")
            }
            capturer.delegate = frameThrottler!
        } else if let source = self.videoSource {
            capturer.delegate = source
        }
    }
    
    // MARK: - 🔥 快门速度控制（cjfps 0-100 → 1/90s ~ 1/240s）
    
    /// 设置快门速度百分比（后端下发 cjfps）
    /// - Parameter percentage: 0-100（0=1/90s, 100=1/240s）
    func setCaptureFrameRate(percentage: Int, forceApply: Bool = false) {
        let oldPercentage = cjfpsPercentage
        cjfpsPercentage = max(0, min(100, percentage))
        
        let oldShutter = 90 + Int(Double(oldPercentage) * 1.5)
        let newShutter = 90 + Int(Double(cjfpsPercentage) * 1.5)
        
        print("📸 [快门速度] cjfps: \(oldPercentage)% → \(cjfpsPercentage)%")
        print("   快门: 1/\(oldShutter)s → 1/\(newShutter)s")
        
        // 🔥 只有快门速度有变化时才调整
        if oldShutter != newShutter || forceApply {
            applyShutterSpeedChange()
        } else {
            print("   ✅ 快门速度已是目标值，无需调整")
        }
    }
    
    /// 应用快门速度变化
    private func applyShutterSpeedChange() {
        guard let device = getCurrentCaptureDevice() else {
            print("⚠️ [applyShutterSpeedChange] device 不存在")
            return
        }
        
        let targetShutterSpeed = 90 + Int(Double(cjfpsPercentage) * 1.5)  // 90~240
        
        do {
            try device.lockForConfiguration()
            
            if device.isExposureModeSupported(.custom) {
                let duration = CMTime(value: 1, timescale: CMTimeScale(targetShutterSpeed))
                
                let minDuration = device.activeFormat.minExposureDuration
                let maxDuration = device.activeFormat.maxExposureDuration
                
                let safeDuration: CMTime
                let actualShutterSpeed: Int
                if duration < minDuration {
                    safeDuration = minDuration
                    actualShutterSpeed = Int(1.0 / CMTimeGetSeconds(safeDuration))
                    print("📸 快门调整: cjfps=\(cjfpsPercentage)% → 1/\(actualShutterSpeed)s (硬件最快)")
                } else if duration > maxDuration {
                    safeDuration = maxDuration
                    actualShutterSpeed = Int(1.0 / CMTimeGetSeconds(safeDuration))
                    print("📸 快门调整: cjfps=\(cjfpsPercentage)% → 1/\(actualShutterSpeed)s (硬件最慢)")
                } else {
                    safeDuration = duration
                    actualShutterSpeed = targetShutterSpeed
                    print("📸 快门调整: cjfps=\(cjfpsPercentage)% → 1/\(actualShutterSpeed)s")
                }
                
                device.setExposureModeCustom(duration: safeDuration, iso: AVCaptureDevice.currentISO, completionHandler: nil)
                
                // 🔥🔥 关键：显式锁定帧率，防止手动曝光后帧率被自动降低
                // 直接使用 currentCaptureFPS（采集时已正确设置）
                let targetFps = currentCaptureFPS
                if targetFps > 0 {
                    let frameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
                    device.activeVideoMinFrameDuration = frameDuration
                    device.activeVideoMaxFrameDuration = frameDuration
                    print("📹 帧率锁定: \(targetFps)fps")
        }
            }
            
            device.unlockForConfiguration()
        } catch {
            print("❌ [快门调整] 失败: \(error.localizedDescription)")
        }
    }
    
    /// 获取当前采集设备
    private func getCurrentCaptureDevice() -> AVCaptureDevice? {
        guard let session = capturer?.captureSession else { return nil }
        for input in session.inputs {
            if let deviceInput = input as? AVCaptureDeviceInput,
               deviceInput.device.hasMediaType(.video) {
                return deviceInput.device
            }
        }
        return nil
    }
    

    // MARK: - SRS 配置
    // 🔥 从登录接口获取推流IP，不再写死
    var srsIP: String {
        return UserDefaults.standard.string(forKey: "stream_push_ip") ?? "8.162.11.163"
    }
    var app   = "tenantA"

    // 🔥 基础流名（来自 permanent_token，不带时间戳）
    var baseStreamKey: String = ""  // 改为 internal，供 ContentView 检查
    
    // 🔥 实际推流使用的流名（基础流名 + 时间戳，每次推流生成新的）
    private(set) var streamKey: String = ""
    
    // 挂载方向 & 镜像开关（持久化可选）
    @Published var mountOrientation: MountOrientation = .deg0
    @Published var streamMirrored: Bool = false
    
    // WebRTCManager.applyThinRemoteConfig(_ cfg: ThinRemoteConfig)
    func applyThinRemoteConfig(_ cfg: ThinRemoteConfig) {
        let startTime = Date()
        print("⚡ [applyThinRemoteConfig] 开始执行: ptype=\(cfg.ptype), 线程=\(Thread.isMainThread ? "主线程" : "后台线程")")
        print("📋 [后端配置-实时更新] 完整配置:")
        print("   type=\(cfg.type), direction=\(cfg.direction), zoom=\(cfg.zoom)")
        print("   fps=\(cfg.fps ?? 0), cjfps=\(cfg.cjfps ?? 100), bitrate=\(cfg.bitrate ?? 0), focus=\(cfg.focus ?? 0)")
        print("   ptype=\(cfg.ptype), angle=\(cfg.angle ?? 0)")
        
        //print("---> "+cfg.ptype)
        // ... existing code ...
        switch cfg.ptype {
        case "type":
            // 档位：4档固定配置 - standard/high/ultra/p4k
            let desiredProfile: LadderProfile
            switch cfg.type.lowercased() {
            case "p4k", "4k":
                desiredProfile = .p4k
            case "ultra", "超清":
                desiredProfile = .ultra
            case "high", "高清":
                desiredProfile = .high
            default:  // standard, 标清, 或其他
                desiredProfile = .standard
            }
            if currentProfile != desiredProfile {
                if gentleAdaptMode { applyProfileBitrateOnly(desiredProfile) } else { applyProfile(desiredProfile) }
            }
            //print("✅ 已按 ptype=type 应用档位: \(cfg.type) → \(desiredProfile)")
            
            // ✅ 切换档位时，同时应用 fps（如果有）
            if let f = cfg.fps {
                let maxFps = getMaxPushFpsForCurrentProfile()
                let webrtcFps = min(maxFps, f / 2)
                print("🔄 [FPS设置] 后端: \(f)fps / 2 = \(f/2)fps, 上限: \(maxFps)fps → WebRTC: \(webrtcFps)fps")
                setAverageOutputFPS(f)
                enableAverageThrottling(true)
            }

        case "direction":
            // 方向："-1"后置；"1"前置（若不一致则切换一次）
            //print("🔍 收到 direction 切换请求: cfg.direction=\(cfg.direction)")
            if let input = capturer?.captureSession.inputs.first as? AVCaptureDeviceInput {
                let currentPos = input.device.position
                let wantFront = (cfg.direction == "1")  // ✅ 1=前置，-1=后置
                let curFront = (currentPos == .front)
                
                //print("🔍 当前摄像头: \(currentPos == .back ? "后置(back)" : currentPos == .front ? "前置(front)" : "未知") | 目标: \(wantFront ? //"前置" : "后置")")
                
                if wantFront != curFront {
                    //print("🔄 开始切换摄像头...")
                    toggleCamera()
                    //print("✅ 已按 ptype=direction 切换摄像头: 目标=\(wantFront ? "前置" : "后置")")
                } else {
                    //print("✅ ptype=direction 无需切换: 当前已是\(curFront ? "前置" : "后置")")
                }
            } else {
               // print("⚠️ 无摄像头输入，略过方向更新")
            }

        case "zoom":
            // 变焦
            setZoom(cfg.zoom)
            //print("✅ 已按 ptype=zoom 设置焦距: \(cfg.zoom)")

    
        case "fps":
            // FPS（优先整数）- 推送FPS
            if let f = cfg.fps {
                let maxFps = getMaxPushFpsForCurrentProfile()
                let webrtcFps = min(maxFps, f / 2)
                print("🔄 [推送FPS设置] 后端: \(f)fps / 2 = \(f/2)fps, 上限: \(maxFps)fps → WebRTC: \(webrtcFps)fps")
                setAverageOutputFPS(f)
                enableAverageThrottling(true)
            } else {
               // print("⚠️ ptype=fps 缺少值，忽略")
            }
            
        case "cjfps":
            // 🔥 快门速度（0-100 → 1/90s ~ 1/240s）
            if let cj = cfg.cjfps {
                let targetShutter = 90 + Int(Double(cj) * 1.5)
                print("📸 [快门速度设置] 后端: cjfps=\(cj)% → 1/\(targetShutter)s")
                setCaptureFrameRate(percentage: cj)
            } else {
                print("⚠️ ptype=cjfps 缺少值，忽略")
            }

        case "bitrate":
            // 码率（百分比，保底 10%）
            if let pct = cfg.bitrate {
                setQualityPercentage(pct)
               // print("✅ 已按 ptype=bitrate 设置质量百分比: \(pct)%")
            } else {
              //  print("⚠️ ptype=bitrate 缺少值，忽略")
            }

        case "focus":
            // 对焦距离 0.0~1.0
            if let f = cfg.focus {
                setFocus(f)
               // print("✅ 已按 ptype=focus 设置对焦距离: \(f)")
            } else {
                print("⚠️ ptype=focus 缺少值，忽略")
            }
        
        default:
            print("⚠️ 未知 ptype=\(cfg.ptype)，忽略该项")
        }
        
        // 🔥 记录执行时间
        let executionTime = Date().timeIntervalSince(startTime) * 1000 // 转换为毫秒
        print("⚡ [applyThinRemoteConfig] 执行完成: ptype=\(cfg.ptype), 耗时=\(String(format: "%.2f", executionTime))ms")
        // ... existing code ...
    }
    
    func applyThinRemoteConfigInit(_ cfg: ThinRemoteConfig) {
            // 1) 档位：4档固定配置 - standard/high/ultra/p4k
            let desiredProfile: LadderProfile
            switch cfg.type.lowercased() {
            case "p4k", "4k":
                desiredProfile = .p4k
            case "ultra", "超清":
                desiredProfile = .ultra
            case "high", "高清":
                desiredProfile = .high
            default:  // standard, 标清, 或其他
                desiredProfile = .standard
            }
            
            // ✅ 初始化时只设置档位，不尝试切换（因为capturer还不存在）
            currentProfile = desiredProfile
            //print("🎬 初始化档位: \(desiredProfile) (type=\(cfg.type))")
            
            // 如果已经有 capturer（重新加载配置的情况），则尝试切换
            if capturer != nil {
                if gentleAdaptMode { applyProfileBitrateOnly(desiredProfile) } else { applyProfile(desiredProfile) }
            }

            // 2) 方向："-1"后置；"1"前置（若不一致则切换一次）
            //print("🔍 初始化 direction 检查: cfg.direction=\(cfg.direction)")
            if let input = capturer?.captureSession.inputs.first as? AVCaptureDeviceInput {
                let currentPos = input.device.position
                let wantFront = (cfg.direction == "1")  // ✅ 1=前置，-1=后置
                let curFront = (currentPos == .front)
                
                //print("🔍 初始化摄像头状态: 当前=\(currentPos == .back ? "后置" : "前置") | 目标=\(wantFront ? "前置" : "后置")")
                
                if wantFront != curFront {
                    //print("🔄 初始化：开始切换摄像头...")
                    toggleCamera()
                    //print("🎬 初始化切换摄像头完成: 目标=\(wantFront ? "前置" : "后置")")
                } else {
                    print("✅ 初始化：无需切换，当前已是目标摄像头")
                }
            }

            // 3) 变焦
            setZoom(cfg.zoom)

            // 4) FPS（优先整数）- 推送FPS
            if let f = cfg.fps {
                    let maxFps = getMaxPushFpsForCurrentProfile()
                    let webrtcFps = min(maxFps, f / 2)
                    print("🔄 [推送FPS设置-初始化] 后端: \(f)fps / 2 = \(f/2)fps, 上限: \(maxFps)fps → WebRTC: \(webrtcFps)fps")
                    setAverageOutputFPS(f)
                    enableAverageThrottling(true)
                }
            
            // 4.5) 🔥 快门速度（0-100 → 1/90s ~ 1/240s）
            if let cj = cfg.cjfps {
                let targetShutter = 90 + Int(Double(cj) * 1.5)
                print("📸 [快门速度设置-初始化] 后端: cjfps=\(cj)% → 1/\(targetShutter)s")
                setCaptureFrameRate(percentage: cj)
                }

            // 5) 码率（kbps→百分比，按当前档位上限换算；保底 10%）
            if let pct = cfg.bitrate { setQualityPercentage(pct) }
            
            // 6) 对焦距离 0.0~1.0
            if let f = cfg.focus { setFocus(f) }
            
            print("✅ 已应用 ThinRemoteConfig: type=\(cfg.type) dir=\(cfg.direction) zoom=\(cfg.zoom) fps=\(String(describing: cfg.fps)) cjfps=\(String(describing: cfg.cjfps)) bitrate=\(String(describing: cfg.bitrate)) angle=\(String(describing: cfg.angle)) focus=\(String(describing: cfg.focus))")
    }
    
    // MARK: - 恢复配置（除对焦外）
    /// 在切换场景（切换档位、切换摄像头）后调用，恢复除对焦外的配置
    /// 需要保持一致的参数：变焦(zoom)、FPS、码率
    /// 不需要恢复：对焦(focus)让用户手动调整、角度(angle)由后端控制
    func reapplyConfigExceptFocus() {
        print("🔄 [reapplyConfigExceptFocus] 开始恢复配置（除对焦外）")
        
        // 1) 变焦 - 🔥 优先从 ConfigManager 读取后端配置的 zoom 值，确保切换摄像头后恢复正确
        let zoomValue: CGFloat
        if let cfg = ConfigManager.shared.getCurrentConfig() {
            zoomValue = cfg.zoom
            currentZoomFactor = zoomValue  // 同步更新本地变量
            print("   📋 从后端配置读取 zoom: \(zoomValue)")
        } else {
            zoomValue = currentZoomFactor
            print("   📋 使用本地保存的 zoom: \(zoomValue)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.setZoom(zoomValue)
            print("   ✅ 变焦恢复: \(zoomValue)")
        }
        
        // 2) FPS（目标推送FPS）- 使用本地保存的值（已经是 /2 后的值）
        let fpsValue = targetOutputFPS
        let maxPushFps = getMaxPushFpsForCurrentProfile()
        let webrtcFps = min(maxPushFps, fpsValue)
        frameThrottler?.targetSendFps = fpsValue
        print("   ✅ FPS恢复: 推送目标=\(fpsValue)fps, 上限=\(maxPushFps)fps → WebRTC=\(webrtcFps)fps")
        
        // 3) 码率 - 显式调用 setMaxBitrateKbps 确保配置被应用
        let kbpsValue = effectiveMaxKbpsForCurrentProfile()
        setMaxBitrateKbps(kbpsValue)
        if let pct = lastQualityPercent {
            print("   ✅ 码率恢复: \(pct)% → \(kbpsValue)kbps")
        } else {
            print("   ✅ 码率恢复: 默认 → \(kbpsValue)kbps")
        }
        
        // 注意：角度(angle)由后端控制，不在前端恢复
        // 注意：对焦(focus)单独恢复，见 reapplyFocusFromConfig()
        print("🔄 [reapplyConfigExceptFocus] 配置恢复完成")
    }
    
    // MARK: - 从后端配置恢复对焦
    /// 从 ConfigManager 读取后端配置的 focus 值并应用
    /// 切换摄像头后调用，确保对焦恢复到后端设置的值
    func reapplyFocusFromConfig() {
        print("🔍 [reapplyFocusFromConfig] 开始恢复对焦")
        
        // 🔥 用户手动调整的值优先于后端配置
        if userHasManuallyAdjustedFocus, let savedFocus = savedUserFocusDistance {
            // 用户手动调整过，优先使用用户设置的值
            print("   📋 使用用户手动调整的 focus: \(savedFocus)")
            setFocus(savedFocus)
            print("   ✅ 对焦恢复: \(savedFocus) (用户手动调整)")
        } else if let cfg = ConfigManager.shared.getCurrentConfig(), let focusValue = cfg.focus {
            // 用户没调整过，使用后端配置
            print("   📋 从后端配置读取 focus: \(focusValue)")
            setFocus(focusValue)
            print("   ✅ 对焦恢复: \(focusValue) (后端配置)")
        } else {
            print("   ⚠️ 无可用的对焦配置，保持当前状态")
        }
    }
    
    // MARK: - 唤醒后恢复所有配置（包括对焦）
    /// 休眠唤醒后调用，恢复所有参数（包括对焦）
    /// 唤醒后需要完整还原：变焦、FPS、码率、对焦（自动对焦）
    func reapplyConfigForWake() {
        print("☀️ [reapplyConfigForWake] 唤醒后恢复所有配置")
        
        // 1) 变焦 - 🔥 优先从 ConfigManager 读取后端配置的 zoom 值
        let zoomValue: CGFloat
        if let cfg = ConfigManager.shared.getCurrentConfig() {
            zoomValue = cfg.zoom
            currentZoomFactor = zoomValue  // 同步更新本地变量
            print("   📋 从后端配置读取 zoom: \(zoomValue)")
        } else {
            zoomValue = currentZoomFactor
            print("   📋 使用本地保存的 zoom: \(zoomValue)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.setZoom(zoomValue)
            print("   ✅ 变焦恢复: \(zoomValue)")
        }
        
        // 2) FPS（目标推送FPS）- 使用本地保存的值
        let fpsValue = targetOutputFPS
        let maxPushFps = getMaxPushFpsForCurrentProfile()
        let webrtcFps = min(maxPushFps, fpsValue)
        frameThrottler?.targetSendFps = fpsValue
        print("   ✅ FPS恢复: 推送目标=\(fpsValue)fps, 上限=\(maxPushFps)fps → WebRTC=\(webrtcFps)fps")
        
        // 3) 码率 - 显式调用 setMaxBitrateKbps 确保 FPS 缩放公式被应用
        let kbpsValue = effectiveMaxKbpsForCurrentProfile()
        setMaxBitrateKbps(kbpsValue)
        if let pct = lastQualityPercent {
            print("   ✅ 码率恢复: \(pct)% → \(kbpsValue)kbps")
        } else {
            print("   ✅ 码率恢复: 默认 → \(kbpsValue)kbps")
        }
        
        // 4) 对焦 - 唤醒后直接恢复保存的焦距（不执行自动对焦）
        if let savedFocus = savedUserFocusDistance {
            print("   ✅ 对焦恢复: \(savedFocus)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.setFocus(savedFocus)
            }
        } else {
            print("   ✅ 对焦：保持当前焦距（由后端配置控制）")
        }
        
        print("☀️ [reapplyConfigForWake] 配置恢复完成")
    }
    
    
    func setQualityPercentage(_ percent: Int) {
            let clamped = max(1, min(100, percent))
            // 吸附到统一阶梯，跨档位统一体验
            let snapped = QUALITY_PERCENT_STEPS.min(by: { abs($0 - clamped) < abs($1 - clamped) }) ?? clamped
            let oldPercent = lastQualityPercent ?? 100
            lastQualityPercent = snapped
            
            if currentLadder[currentProfile] != nil {
                let newKbps = effectiveMaxKbpsForCurrentProfile()
                setMaxBitrateKbps(newKbps)
                //print("🎨 质量百分比: \(oldPercent)% → \(snapped)% | 码率调整为: \(newKbps)kbps (±100kb)")
            } else {
                //print("✨ 质量百分比=", snapped, "%")
            }
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
        //print("🎯 手动 FPS(%) → ", snapped, "fps")
        // ... existing code ...
    }
    
    
    func setFPSValue(_ fps: Int) {
        let clamped = max(10, min(60, fps))
        manualFpsOverride = clamped
        // 关键：立刻重采集以应用手动 FPS 覆盖
        if let preset = currentLadder[currentProfile] {
            recapture(width: preset.width, height: preset.height, fps: preset.fps)
        }
        //print("🎯 手动 FPS =", clamped, "fps")
    }
    
    func clearManualFpsOverride() {
        manualFpsOverride = nil
        //print("🧹 清除手动 FPS 覆盖")
    }
    
    // ✅ 统一根据质量百分比计算当前档位应设的码率上限
    private func kbpsForProfile(_ preset: LadderPreset) -> Int {
        guard let pct = lastQualityPercent else { return preset.maxKbps }
        // 按百分比映射到当前档位的上限码率，避免过低设置
        let result = max(300, Int(Double(preset.maxKbps) * Double(pct) / 100.0))
        return result
    }
    
    @MainActor
    func startPreviewIfNeeded(initialProfile: LadderProfile? = nil) {
        // 已初始化则不重复
        guard capturer == nil else { return }
        
        // ✅ 使用配置的档位，如果没有指定则使用 currentProfile
        let useProfile = initialProfile ?? currentProfile
        
        // 🔥 初始化前先从服务器配置读取目标FPS
        if let cfg = ConfigManager.shared.getCurrentConfig() {
            print("📋 [后端配置-预览] 完整配置:")
            print("   type=\(cfg.type), direction=\(cfg.direction), zoom=\(cfg.zoom)")
            print("   fps=\(cfg.fps ?? 0), bitrate=\(cfg.bitrate ?? 0), focus=\(cfg.focus ?? 0)")
            print("   ptype=\(cfg.ptype), angle=\(cfg.angle ?? 0)")
            
            if let serverFps = cfg.fps {
                targetOutputFPS = serverFps
                print("🎯 [初始化-预览] 从服务器配置读取目标FPS: \(serverFps)fps")
            } else {
                print("⚠️ [初始化-预览] 服务器配置无FPS，使用默认值: \(targetOutputFPS)fps")
            }
        } else {
            print("⚠️ [初始化-预览] 无法获取服务器配置，使用默认FPS: \(targetOutputFPS)fps")
        }

        AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        guard granted else { print("❌ 相机权限未授权"); return }
                        
                        // 🔥 推送用 videoSource（受后端fps控制）
                        self.videoSource = self.factory.videoSource()
                        
                        // 🔥 预览用 videoSource（固定60fps）
                        self.previewVideoSource = self.factory.videoSource()
                      
                        // 建立管线链：capturer -> throttler -> (previewVideoSource + videoSource)
                        let throttler = FrameThrottler()
                        throttler.inner = self.videoSource              // 🔥 推送输出（受后端fps控制）
                        throttler.previewDelegate = self.previewVideoSource  // 🔥 预览输出（固定60fps）
                        throttler.targetSendFps = self.targetOutputFPS  // 🔥 使用服务器配置的目标FPS（只影响推送）
                        throttler.fpsReportHandler = { [weak self] cap, snd in
                                self?.currentCaptureFps = cap
                                self?.currentSendFps = snd
                        }

                        self.frameThrottler = throttler
                        self.capturer = RTCCameraVideoCapturer(delegate: throttler)
                        print("🔄 [初始化] 创建帧节流器，推送目标FPS: \(self.targetOutputFPS)fps，预览固定60fps")

                        // 🔥 预览轨道绑定到 previewVideoSource（固定60fps）
                        let previewTrack = self.factory.videoTrack(with: self.previewVideoSource, trackId: "local_preview")
                        self.previewVideoTrack = previewTrack
                        self.previewVideoTrack?.add(self.localView)
                        
                        // 🔥 推送轨道绑定到 videoSource（受后端fps控制）
                        let track = self.factory.videoTrack(with: self.videoSource, trackId: "video0")
                        self.localVideoTrack = track

                        self.currentProfile = useProfile
                        
                        // ✅ 打印前置和后置摄像头支持的所有格式（初始化诊断）
                        let devices = RTCCameraVideoCapturer.captureDevices()
                        
                        // 🔥 诊断：打印所有摄像头设备和最大 FOV 格式
                        print("📐 ========== 摄像头设备诊断 ==========")
                        print("📷 可用摄像头设备 (共\(devices.count)个):")
                        for (idx, dev) in devices.enumerated() {
                            let pos = dev.position == .front ? "前置" : (dev.position == .back ? "后置" : "未知")
                            let type = dev.deviceType.rawValue
                            print("   [\(idx)] \(pos) - \(dev.localizedName) (\(type))")
                        }
                        
                        print("\n📐 ========== 所有格式诊断（横屏 vs 竖屏）==========")
                        
                        if let frontCamera = devices.first(where: { $0.position == .front }) {
                            let frontFormats = RTCCameraVideoCapturer.supportedFormats(for: frontCamera)
                            
                            print("📱 前置摄像头 所有格式 (共\(frontFormats.count)个):")
                            var landscapeCount = 0
                            var portraitCount = 0
                            for (index, fmt) in frontFormats.enumerated() {
                                let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                                let maxFps = Int(fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                                let fov = fmt.videoFieldOfView
                                let isLandscape = dims.width > dims.height
                                let orientation = isLandscape ? "横" : "竖"
                                
                                if isLandscape {
                                    landscapeCount += 1
                                } else {
                                    portraitCount += 1
                                }
                                
                                print("   [\(index)] \(orientation) \(dims.width)x\(dims.height) @\(maxFps)fps FOV=\(String(format: "%.1f", fov))°")
                            }
                            print("   📊 统计: 横屏=\(landscapeCount)个, 竖屏=\(portraitCount)个")
                        }
                        
                        if let backCamera = devices.first(where: { $0.position == .back }) {
                            let backFormats = RTCCameraVideoCapturer.supportedFormats(for: backCamera)
                            
                            print("📱 后置摄像头 所有格式 (共\(backFormats.count)个):")
                            var landscapeCount = 0
                            var portraitCount = 0
                            for (index, fmt) in backFormats.enumerated() {
                                let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                                let maxFps = Int(fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                                let fov = fmt.videoFieldOfView
                                let isLandscape = dims.width > dims.height
                                let orientation = isLandscape ? "横" : "竖"
                                
                                if isLandscape {
                                    landscapeCount += 1
                                } else {
                                    portraitCount += 1
                                }
                                
                                print("   [\(index)] \(orientation) \(dims.width)x\(dims.height) @\(maxFps)fps FOV=\(String(format: "%.1f", fov))°")
                            }
                            print("   📊 统计: 横屏=\(landscapeCount)个, 竖屏=\(portraitCount)个")
                        }
                        
                        // 🔥🔥🔥 打印所有 4:3 画幅格式（横屏）
                        print("\n📐 ========== 4:3 画幅格式（更多垂直内容）==========")
                        
                        func print43Formats(camera: AVCaptureDevice, name: String) {
                            let formats = RTCCameraVideoCapturer.supportedFormats(for: camera)
                            // 筛选 4:3 横屏格式（允许一定误差）
                            let formats43 = formats.filter { fmt in
                                let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                                let ratio = Float(dims.width) / Float(dims.height)
                                let isLandscape = dims.width > dims.height
                                return isLandscape && abs(ratio - 4.0/3.0) < 0.05
                            }
                            
                            print("📱 \(name) 4:3 格式 (共\(formats43.count)个):")
                            
                            // 去重：按分辨率分组，显示每个分辨率的最高FPS
                            var seen: Set<String> = []
                            let sorted = formats43.sorted { a, b in
                                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                                if da.width != db.width { return da.width > db.width }
                                let fa = Int(a.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                                let fb = Int(b.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                                return fa > fb
                            }
                            
                            for fmt in sorted {
                                let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                                let maxFps = Int(fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                                let fov = fmt.videoFieldOfView
                                let key = "\(dims.width)x\(dims.height)"
                                
                                if !seen.contains(key) {
                                    seen.insert(key)
                                    print("   ✅ \(dims.width)x\(dims.height) @\(maxFps)fps FOV=\(String(format: "%.1f", fov))°")
                                }
                            }
                            
                            if formats43.isEmpty {
                                print("   ⚠️ 无 4:3 格式")
                            }
                        }
                        
                        if let frontCamera = devices.first(where: { $0.position == .front }) {
                            print43Formats(camera: frontCamera, name: "前置摄像头")
                        }
                        if let backCamera = devices.first(where: { $0.position == .back }) {
                            print43Formats(camera: backCamera, name: "后置摄像头")
                        }
                        
                        // 🔥🔥🔥 专门筛选 4:3 + 高帧率(120fps+) 的格式
                        print("\n📐 ========== 4:3 高帧率格式 (120fps+) ==========")
                        func print43HighFpsFormats(camera: AVCaptureDevice, name: String) {
                            let formats = RTCCameraVideoCapturer.supportedFormats(for: camera)
                            let highFps43 = formats.filter { fmt in
                                let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                                let ratio = Float(dims.width) / Float(dims.height)
                                let isLandscape = dims.width > dims.height
                                let maxFps = Int(fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                                return isLandscape && abs(ratio - 4.0/3.0) < 0.05 && maxFps >= 120
                            }
                            
                            if highFps43.isEmpty {
                                print("📱 \(name): ❌ 无 4:3 高帧率格式")
                            } else {
                                print("📱 \(name) 4:3 高帧率格式 (共\(highFps43.count)个):")
                                var seen: Set<String> = []
                                for fmt in highFps43.sorted(by: { a, b in
                                    let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                                    let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                                    return da.width > db.width
                                }) {
                                    let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                                    let maxFps = Int(fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                                    let fov = fmt.videoFieldOfView
                                    let key = "\(dims.width)x\(dims.height)@\(maxFps)"
                                    if !seen.contains(key) {
                                        seen.insert(key)
                                        print("   🚀 \(dims.width)x\(dims.height) @\(maxFps)fps FOV=\(String(format: "%.1f", fov))°")
                            }
                        }
                            }
                        }
                        
                        if let frontCamera = devices.first(where: { $0.position == .front }) {
                            print43HighFpsFormats(camera: frontCamera, name: "前置摄像头")
                        }
                        if let backCamera = devices.first(where: { $0.position == .back }) {
                            print43HighFpsFormats(camera: backCamera, name: "后置摄像头")
                        }
                        
                        // 🔥 打印 120fps 格式的详细信息（看重复格式的区别）
                        print("\n📐 ========== 120fps 格式详细信息 ==========")
                        if let frontCamera = devices.first(where: { $0.position == .front }) {
                            let formats = RTCCameraVideoCapturer.supportedFormats(for: frontCamera)
                            print("📱 前置 1920x1080 @120fps 详细:")
                            for (index, fmt) in formats.enumerated() {
                                let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                                let maxFps = Int(fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                                if dims.width == 1920 && dims.height == 1080 && maxFps >= 120 {
                                    let fov = fmt.videoFieldOfView
                                    let binned = fmt.isVideoBinned ? "Binned" : "NonBinned"
                                    // 获取像素格式类型
                                    let mediaSubType = CMFormatDescriptionGetMediaSubType(fmt.formatDescription)
                                    let subTypeStr = String(format: "%c%c%c%c",
                                        (mediaSubType >> 24) & 0xFF,
                                        (mediaSubType >> 16) & 0xFF,
                                        (mediaSubType >> 8) & 0xFF,
                                        mediaSubType & 0xFF)
                                    print("   [\(index)] 1920x1080 @\(maxFps)fps FOV=\(String(format: "%.1f", fov))° \(binned) 格式=\(subTypeStr)")
                                }
                            }
                        }
                        
                        // 🔥 检查是否有超广角摄像头
                        if let ultraWide = devices.first(where: { $0.deviceType == .builtInUltraWideCamera }) {
                            let formats = RTCCameraVideoCapturer.supportedFormats(for: ultraWide)
                            if let maxFovFormat = formats.max(by: { $0.videoFieldOfView < $1.videoFieldOfView }) {
                                let dims = CMVideoFormatDescriptionGetDimensions(maxFovFormat.formatDescription)
                                let maxFps = Int(maxFovFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                                print("🌐 超广角摄像头可用! 最大FOV: \(dims.width)x\(dims.height) @\(maxFps)fps FOV=\(String(format: "%.1f", maxFovFormat.videoFieldOfView))°")
                            }
                        } else {
                            print("⚠️ 无超广角摄像头")
                        }
                        
                        // 🔥 检查各摄像头的 zoom 范围
                        print("🔍 Zoom 范围诊断 (RTCCameraVideoCapturer):")
                        for dev in devices {
                            let pos = dev.position == .front ? "前置" : (dev.position == .back ? "后置" : "未知")
                            let minZoom = dev.minAvailableVideoZoomFactor
                            let maxZoom = dev.maxAvailableVideoZoomFactor
                            let deviceType = dev.deviceType.rawValue
                            print("   \(pos): \(deviceType) minZoom=\(String(format: "%.2f", minZoom)) maxZoom=\(String(format: "%.1f", maxZoom))")
                            if minZoom < 1.0 {
                                print("   ✅ \(pos)支持超广角 zoom (可设置 zoom=\(String(format: "%.2f", minZoom)) 获得更广视野)")
                            }
                        }
                        
                        // 🔥 检查系统中所有可用的摄像头（包括虚拟摄像头）
                        print("🔍 系统所有摄像头 (AVCaptureDevice.DiscoverySession):")
                        let discoverySession = AVCaptureDevice.DiscoverySession(
                            deviceTypes: [
                                .builtInWideAngleCamera,
                                .builtInUltraWideCamera,
                                .builtInTelephotoCamera,
                                .builtInDualCamera,
                                .builtInDualWideCamera,
                                .builtInTripleCamera
                            ],
                            mediaType: .video,
                            position: .unspecified
                        )
                        for dev in discoverySession.devices {
                            let pos = dev.position == .front ? "前置" : (dev.position == .back ? "后置" : "未知")
                            let minZoom = dev.minAvailableVideoZoomFactor
                            let maxZoom = dev.maxAvailableVideoZoomFactor
                            let deviceType = dev.deviceType.rawValue
                            print("   \(pos): \(deviceType) minZoom=\(String(format: "%.2f", minZoom)) maxZoom=\(String(format: "%.1f", maxZoom))")
                        }
                        
                        print("📐 ================================================")
                        
                        // ✅ 根据配置选择初始摄像头
                        let cfg = ConfigManager.shared.getCurrentConfig()
                        let directionValue = cfg?.direction ?? "nil"
                        let wantFront = (cfg?.direction == "1")  // 1=前置，-1=后置
                        print("🎬 [初始化摄像头] direction=\"\(directionValue)\", wantFront=\(wantFront)")
                        let initialCamera: AVCaptureDevice?
                        
                        if wantFront {
                            initialCamera = devices.first(where: { $0.position == .front }) ?? devices.first
                            print("🎬 配置要求前置摄像头(direction=1)，使用前置启动")
                        } else {
                            initialCamera = devices.first(where: { $0.position == .back }) ?? devices.first
                            print("🎬 配置要求后置摄像头(direction=-1)，使用后置启动")
                        }
                        
                        if let camera = initialCamera {
                            self.calculateLadderForDevice(camera)
                            
                            // 🔥 初始化时立即设置正确的采集FPS（根据前后置摄像头）
                            // 后置: 240fps, 前置: 120fps
                            if let preset = self.currentLadder[self.currentProfile] {
                                self.currentCaptureFPS = preset.fps
                                print("🎬 [初始化-预览] 摄像头: \(camera.position == .back ? "后置" : "前置"), 采集FPS: \(preset.fps)fps")
                            }
                        }
                        
                        // ✅ 使用综合码率计算（考虑质量百分比和推送FPS）
                        // 此时 currentCaptureFPS 已根据前后置摄像头正确设置
                        let kbps = self.effectiveMaxKbpsForCurrentProfile()
                        self.setMaxBitrateKbps(kbps)
                        
                        // ✅ 全系 16:9 采集（1920x1080）
                        if let camera = initialCamera {
                            print("🎬 [初始化-预览] 采集分辨率: \(self.fixedCaptureWidth)x\(self.fixedCaptureHeight) (16:9)")
                            self.startCaptureWithDevice(camera, width: self.fixedCaptureWidth, height: self.fixedCaptureHeight, fps: 60)
                        }
                        
                        //print("🎬 预览启动: 档位=\(useProfile), 码率=\(kbps)kbps, 摄像头=\(wantFront ? "前置" : "后置")")
                    }
        }
    }
    
    // ✅ 使用指定设备启动采集（固定 1920×1080，通过 scaleResolutionDownBy 缩放输出）
    private func startCaptureWithDevice(_ device: AVCaptureDevice, width: Int, height: Int, fps: Int) {
        let allFormats = RTCCameraVideoCapturer.supportedFormats(for: device)
        
        // 🔥 固定采集 1920×1080（或设备支持的最接近分辨率）
        // 通过 scaleResolutionDownBy 在编码时缩放到目标分辨率，实现热切换不断流
        let targetWidth = fixedCaptureWidth
        let targetHeight = fixedCaptureHeight
        
        print("🎬 [startCaptureWithDevice] 固定采集分辨率: \(targetWidth)x\(targetHeight)")
        
        // 打印所有匹配目标分辨率的格式（横竖都算）
        // 🔥 优先选择支持 60fps 的格式
        let matchingFormats = allFormats.filter { fmt in
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let w = Int(dims.width)
            let h = Int(dims.height)
            // 横向或竖向都匹配
            return (w == targetWidth && h == targetHeight) || (w == targetHeight && h == targetWidth)
        }
        
        // 🔥 在匹配的格式中，优先选择支持 60fps 的
        let highFpsFormats = matchingFormats.filter { fmt in
            let maxFps = Int(fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            return maxFps >= 60
        }
        
        if !matchingFormats.isEmpty {
            print("   找到\(matchingFormats.count)个匹配\(targetWidth)x\(targetHeight)的格式，其中\(highFpsFormats.count)个支持60fps+")
        }
        
        // 🔥 优先从高FPS格式中选择，如果没有再从所有格式中选择
        let candidateFormats = highFpsFormats.isEmpty ? allFormats : highFpsFormats
        
        // 分辨率优先：先选最接近目标的，分辨率相同时选最高FPS的
        guard let best = candidateFormats.sorted(by: { f0, f1 in
            let a = CMVideoFormatDescriptionGetDimensions(f0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions(f1.formatDescription)
            let d0 = abs(Int(a.width) - targetWidth) + abs(Int(a.height) - targetHeight)
            let d1 = abs(Int(b.width) - targetWidth) + abs(Int(b.height) - targetHeight)
            if d0 != d1 { return d0 < d1 }  // 分辨率更接近的优先
            
            // 分辨率相同时，选最高FPS的
            let max0 = Int(f0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            let max1 = Int(f1.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            return max0 > max1
        }).first else { return }
        
        let maxFps = Int(best.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
        let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
        
        // 🔍 打印该格式的所有帧率范围
        for (idx, range) in best.videoSupportedFrameRateRanges.enumerated() {
            print("   [\(idx)] \(Int(range.minFrameRate))-\(Int(range.maxFrameRate))fps")
        }
        
        print("   选中格式: \(dims.width)x\(dims.height) 最大FPS=\(maxFps)")
        
        // 🔥 直接使用设备最大 FPS（cjfps 只控制快门速度，不再控制采集 FPS）
        let useFps = maxFps
        currentCaptureFPS = useFps
        
        print("📹 [采集FPS] 使用设备最大: \(useFps)fps (cjfps=\(cjfpsPercentage)% 仅控制快门)")
        
        // 🔥 根据当前档位设置初始分辨率缩放比例
        let scale = getResolutionScaleForProfile(currentProfile)
        currentResolutionScale = scale
        let outputWidth = Int(Double(fixedCaptureWidth) / scale)
        let outputHeight = Int(Double(fixedCaptureHeight) / scale)
        print("   采集: \(dims.width)x\(dims.height)@\(useFps)fps → 输出: \(outputWidth)x\(outputHeight) (scale=\(scale))")
        
        // ✅ 确保推送FPS不超过采集FPS
        if let currentSendFps = frameThrottler?.targetSendFps, currentSendFps > useFps {
            frameThrottler?.targetSendFps = useFps
            targetOutputFPS = useFps
            print("⚠️ 推送FPS(\(currentSendFps)) 超过采集FPS(\(useFps))，已限制为\(useFps)fps")
        }
        
        // 🔥 最终采集FPS = min(目标, 格式支持的最大值)
        let actualMaxFps = Int(best.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
        let finalFps = min(useFps, actualMaxFps)
        
        if finalFps < useFps {
            print("⚠️ 目标FPS \(useFps) 超过格式最大支持FPS \(actualMaxFps)，降低到 \(finalFps)fps")
            currentCaptureFPS = finalFps  // 更新记录的采集FPS
        }
        
        // 🔥 先启动采集
        capturer.startCapture(with: device, format: best, fps: finalFps)
        print("🚀 采集启动: \(dims.width)x\(dims.height) @\(finalFps)fps (16:9)")
        
        // ✅ 延迟配置相机模式，确保 activeFormat 已更新
        // startCapture 是异步的，格式切换需要时间
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            self.configureCameraAutoModes(device)
        }
        
        // ✅ 立即应用方向，避免画面旋转（App已强制横屏）
        // 使用极短延迟（0.05秒）确保 session 已启动，但用户感知不到
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.applyMountTransform()
            
            // 🪞 更新预览镜像（前置摄像头需要镜像）
            self?.updatePreviewMirror(isFrontCamera: device.position == .front)
            
            // ✅ 发送预览成功通知（用于事件驱动自动推流）
            //print("\n📸📸📸 [WebRTCManager] 摄像头预览就绪，准备发送通知...")
            NotificationCenter.default.post(name: .cameraPreviewReady, object: nil)
            //print("📸 [WebRTCManager] cameraPreviewReady 通知已发送✅\n")
        }
        
        // 🔥 首次初始化摄像头后，应用后端配置的焦距
        // 延迟应用，确保摄像头已稳定
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            
            // 如果有待处理的对焦设置，优先应用
                if let focus = self.pendingFocus {
                    self.pendingFocus = nil
                    self.setFocus(focus)
                print("🔍 [startCaptureWithDevice] 应用待处理的焦距: \(focus)")
            } else {
                // 🔥 否则从后端配置恢复焦距（解决首次启动时焦距未应用导致模糊的问题）
                self.reapplyFocusFromConfig()
                }
            }
    }
    
    func applyMountTransform() {
        guard let session = capturer?.captureSession else {
            //print("⚠️ applyMountTransform: capturer.captureSession 为空")
            return
        }
        
        // ✅ App已强制横屏，这里只是确保 AVCaptureConnection 也设置为横屏
        let want: AVCaptureVideoOrientation = .landscapeRight
        
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
        
        // 📊 显示当前采集格式的详细信息
        if let device = (session.inputs.first as? AVCaptureDeviceInput)?.device {
            let format = device.activeFormat
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            //print("📊 当前采集格式: \(dims.width)x\(dims.height) (设备层面)")
            //print("🧭 App强制横屏 + 连接方向=LandscapeRight, 已应用连接数=\(applied)")
            //print("✅ 推送到后端的视频: 宽(\(dims.width)) x 高(\(dims.height)) - \(dims.width > dims.height ? "✅横向" : "⚠️竖向")")
        }
    }

    // 对外接口（UI 调用） - ⚠️ 已禁用，App已强制横屏
    func setMountOrientation(_ o: MountOrientation) {
        // ✅ 忽略用户/后端的方向设置，始终保持横屏
        //print("⚠️ 方向设置已禁用 - 强制横屏模式，忽略设置: \(o.label)")
        // mountOrientation = o  // 不再更新
        // applyMountTransform()  // 不再应用
    }

    func setStreamMirrored(_ on: Bool) {
        streamMirrored = on
        applyMountTransform()
    }
    
    // MARK: - 预览镜像（前置摄像头显示正向）
    
    /// 更新预览镜像状态（前置摄像头需要水平镜像，让用户看到"正常"的自己）
    func updatePreviewMirror(isFrontCamera: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if isFrontCamera {
                // 🔥 前置摄像头：水平镜像（像照镜子一样）
                self.localView.transform = CGAffineTransform(scaleX: -1, y: 1)
                print("🪞 [预览镜像] 前置摄像头 → 启用水平镜像")
            } else {
                // 🔥 后置摄像头：恢复正常
                self.localView.transform = .identity
                print("🪞 [预览镜像] 后置摄像头 → 关闭镜像")
            }
            
            // 🔥 同步更新 FrameThrottler 的前置摄像头标志
            self.frameThrottler?.isFrontCamera = isFrontCamera
        }
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
                // 🔥 优化：使用 High Profile 提升画质（牺牲一些兼容性）
                // profile-level-id 说明：
                // - 42e01f: Constrained Baseline (低延迟，低画质，最高兼容性) ← 当前使用
                // - 4d001f: Main Profile Level 3.1 (中等画质，较好兼容性)
                // - 42e01f: High Profile Level 3.1 (高画质，WebRTC/现代浏览器支持)
                let compatibleH264 = RTCVideoCodecInfo(
                                name: h264.name,
                                parameters: [
                                   "profile-level-id": "42e01f",  // 🔥 High Profile + Level 3.1 (更好的画质)
                                   "level-asymmetry-allowed": "1",
                                   "packetization-mode": "1"
                               ]
                )
                enc.preferredCodec = compatibleH264
                print("🎯 使用H.264 High Profile (42e01f) 提升画质")
            }
            
            return RTCPeerConnectionFactory(encoderFactory: enc, decoderFactory: dec)
    }()
    private var pc: RTCPeerConnection!
    private var videoSource: RTCVideoSource!           // 🔥 推送用（受后端fps控制）
    private var previewVideoSource: RTCVideoSource!    // 🔥 预览用（固定60fps）
    private var previewVideoTrack: RTCVideoTrack?      // 🔥 预览轨道
    var capturer: RTCCameraVideoCapturer!
    private var videoSender: RTCRtpSender?
    
    // 记录当前采集FPS
    private var currentCaptureFPS: Int = 60
    
    // 🔥 推送FPS硬上限（58、59、60 都限制为 58）
    private let maxAllowedPushFps: Int = 58
    
    // 🔥 存储目标推送FPS（即使 frameThrottler 被重新创建也能恢复）
    private var targetOutputFPS: Int = 58  // 默认值改为58
    
    // 🔥 快门速度百分比 (后端下发 0-100)
    // 0% = 1/90s, 100% = 1/240s
    // 公式: shutterSpeed = 90 + cjfps * 1.5
    private var cjfpsPercentage: Int = 100  // 默认100%，即 1/240s

    // 统计 & 自适应
    private var statsTimer: Timer?
    private var adaptTimer: Timer?
    private var lastBytesSent: UInt64 = 0
    private var lastTs: TimeInterval = 0
    private var badSeconds = 0
    private var goodSeconds = 0
    
    // 回退：帧数差分估算 fps
    private var lastFramesSent: UInt64 = 0
    
    // 🔥 包速率统计（用于对比UDP包速率 vs 视频帧率）
    private var lastPacketsSent: UInt64 = 0
    
    // 🔥 丢包统计（用于计算每秒丢包数）
    private var lastPacketsLost: UInt64 = 0
    private var lastNackCount: UInt64 = 0
    private var lastPliCount: UInt64 = 0
    
    // 🔥 关键帧定时器（减少卡顿恢复时间）
    private var keyframeTimer: Timer?
    private let keyframeIntervalSec: Double = 2.0  // 每2秒强制一个关键帧
    
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

    // 手动对焦距离
    @Published var focusDistance: Float = 0.5  // 0.0~1.0
    private var pendingFocus: Float?
    private var userHasManuallyAdjustedFocus = false  // ✅ 标记用户是否手动调整过对焦
    private var savedUserFocusDistance: Float?  // 🔥 保存用户设置的对焦距离（用于自动对焦后恢复）
    
    // 🔥 本地保存的变焦值（用于切换档位/摄像头时恢复）
    // 🔥 默认 0.5 超广角（iPhone 11+ 支持，老设备会自动限制到 1.0）
    private var currentZoomFactor: CGFloat = 0.5
    
    // 🔥 分辨率缩放比例（用于热切换分辨率，不断流）
    // 1.0 = 1920x1080, 1.5 = 1280x720
    private var currentResolutionScale: Double = 1.0
    
    // 🔥 固定采集分辨率（16:9 比例）
    // 全系使用 1920x1080 (16:9) 采集，配合智能快门减少拖影
    private let fixedCaptureWidth: Int = 1920
    private let fixedCaptureHeight: Int = 1080
    
    // 🔥 对焦任务管理（防止快速切换时对焦冲突）
    private var currentAutoFocusTask: DispatchWorkItem?
    
    // 🔥 每个档位的对焦距离缓存（避免重复自动对焦）
    // 键格式："前置_1024x768" 或 "后置_1920x1080"
    private var focusDistanceCache: [String: Float] = [:]

    override init() {
        super.init()
        // 🔥 测试：scaleAspectFit = 完整显示（可能有黑边），scaleAspectFill = 填满（可能裁剪）
        localView.videoContentMode = .scaleAspectFit
        
        // 🔥 确保初始化时重置休眠状态（防止残留状态导致不自动推流）
        isCameraSleeping = false
        sleepBeforePublishing = false
        print("🔧 [WebRTCManager.init] 初始化完成，休眠状态已重置")
        
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
                // 🔥 确保在主线程立即执行，不使用 async（避免延迟）
                if Thread.isMainThread {
                    print("📨 [WebRTCManager] 收到配置更新通知（主线程）: ptype=\(cfg.ptype)")
                    self.applyThinRemoteConfig(cfg)
                } else {
                    // 如果不在主线程，使用 sync 立即切换到主线程执行（不延迟）
                    DispatchQueue.main.sync {
                        print("📨 [WebRTCManager] 收到配置更新通知（切换到主线程）: ptype=\(cfg.ptype)")
                        self.applyThinRemoteConfig(cfg)
                    }
                }
                return
            }
            
    }

    deinit {
        statsTimer?.invalidate()
        adaptTimer?.invalidate()
        RTCCleanupSSL()
        NotificationCenter.default.removeObserver(self)
    }
    
   
    // ✅ 温和切换档位（热切换：只改码率和分辨率缩放，不断流）
    func applyProfileBitrateOnly(_ p: LadderProfile) {
            guard let preset = currentLadder[p] else { return }
            let oldProfile = currentProfile
            let oldMaxPushFps = getMaxPushFpsForProfile(oldProfile)
            let oldScale = currentResolutionScale
            currentProfile = p
            let newMaxPushFps = getMaxPushFpsForProfile(p)
            
            print("🎚️ 温和档位热切换: \(oldProfile)(上限\(oldMaxPushFps)fps) → \(p)(上限\(newMaxPushFps)fps)")
            print("   当前状态: 采集=\(currentCaptureFPS)fps, 后端目标=\(targetOutputFPS)fps")
            
            // 🔥 计算分辨率缩放比例（热切换分辨率，不断流）
            let scale = getResolutionScaleForProfile(p)
            let targetWidth = preset.width
            let targetHeight = preset.height
            
        // 🔥🔥 全系 16:9 采集（1920x1080）
        let outputWidth = Int(Double(fixedCaptureWidth) / scale)
        let outputHeight = Int(Double(fixedCaptureHeight) / scale)
        print("   📐 分辨率切换: scale \(oldScale) → \(scale)")
        print("      目标档位分辨率: \(targetWidth)x\(targetHeight)")
        print("      采集分辨率: \(fixedCaptureWidth)x\(fixedCaptureHeight)")
            print("      计算输出分辨率: \(outputWidth)x\(outputHeight)")
            setResolutionScale(scale)
            
            // 🔥 检查当前推送FPS是否超过新档位的限制
            // 注意：后端FPS需要除以2才是实际WebRTC推送FPS，所以后端最大可发送 maxPushFps * 2
            let maxPushFps = getMaxPushFpsForProfile(p)
            let maxBackendFps = maxPushFps * 2  // 后端最大可发送值（除以2后=档位上限）
            if targetOutputFPS > maxBackendFps {
                print("   ⚠️ 当前后端FPS(\(targetOutputFPS))超过限制(\(maxBackendFps)fps)，自动调低")
                targetOutputFPS = maxBackendFps
                frameThrottler?.targetSendFps = maxBackendFps
            }
            
            // ✅ 使用 effectiveMaxKbpsForCurrentProfile() 来考虑质量百分比和推送FPS
            let targetKbps = effectiveMaxKbpsForCurrentProfile()
            setMaxBitrateKbps(targetKbps)
            
            // 🔥 立即强制码率，确保切换时码率立即生效
            enforceBitrateImmediately()
            
            print("   🔥 热切换完成: 采集=\(fixedCaptureWidth)x\(fixedCaptureHeight) → 输出=\(outputWidth)x\(outputHeight), 最高\(maxPushFps)fps, 码率=\(targetKbps)kbps")
            
            // 🔥 恢复其他配置（变焦、FPS、码率等）
            // 全系 16:9 采集，不需要在档位切换时重新采集
            reapplyConfigExceptFocus()
    }

    // MARK: - 清理服务器端旧流状态
    /// 调用 SRS HTTP API 删除服务器端的旧流（进程被杀死后，服务器不知道客户端已断开）
    // MARK: - Token
    private func loadTokenIfNeeded() {
        if let permanentToken = UserDefaults.standard.string(forKey: "permanent_token") {
            baseStreamKey = permanentToken
            //print("✅ 已加载 permanent_token 作为基础流名：\(baseStreamKey)")
        } else {
            //print("⚠️ 未找到 permanent_token，请先登录")
            NotificationCenter.default.post(name: NSNotification.Name("LogoutRequired"), object: nil)
        }
    }

    @objc private func onLogoutRequired() {
        // 可在这里清理资源/跳转登录
    }

    // 如果登录后从服务器拿到新的流名，也可以直接调用它
    func updateStreamKey(_ newKey: String) {
        guard !newKey.isEmpty else { return }
        if newKey == baseStreamKey { return }
        //print("🔄 更新基础流名：\(baseStreamKey) → \(newKey)")
        baseStreamKey = newKey
        UserDefaults.standard.set(newKey, forKey: "permanent_token")
        if isPublishing {
            Task { @MainActor in
                stopPublish()
                try? await Task.sleep(nanoseconds: 150_000_000)
                startPublish() // 新流名立即生效
            }
        }
    }
    
    func startPublish(initialProfile: LadderProfile? = nil) {
        //print("\n========================================")
        //print("🎬🎬🎬 startPublish 被调用")
        //print("========================================")
        
        // 🔥 检查基础流名
        guard !baseStreamKey.isEmpty else {
            //print("❌ 无基础流名：请先登录或写入 permanent_token")
            //print("========================================\n")
            return
        }
        
        // 🔥 生成带时间戳的 streamKey（每次推流唯一，避免 SRS 缓存冲突）
        let timestamp = Int(Date().timeIntervalSince1970)
        streamKey = "\(baseStreamKey)_\(timestamp)"
        print("🔑 推流 streamKey: \(streamKey) (带时间戳)")
        
        WebSocketManager.publishingStreamKey = streamKey  // 🔥 更新到WebSocket，供设备状态推送使用
        
        //print("📊 前置条件检查：")
        //print("   - streamKey: \(streamKey)")
        //print("   - isPublishing: \(isPublishing ? "⚠️是（不应该）" : "✅否")")
        //print("   - capturer: \(capturer == nil ? "❌nil" : "✅已创建")")
        //print("   - localVideoTrack: \(localVideoTrack == nil ? "❌nil" : "✅已创建")")
        //print("   - videoSource: \(videoSource == nil ? "❌nil（预览模式）" : "✅已创建（无预览模式）")")
        //print("   - pc (PeerConnection): \(pc == nil ? "✅nil（即将创建）" : "⚠️已存在（可能有问题）")")
        
        guard !isPublishing else {
            //print("⚠️ 已在推流中，忽略重复调用")
            //print("========================================\n")
            return
        }
        
        // 🔥 检查摄像头预览是否准备好（只有在预览模式下才需要检查）
        // 如果 capturer 和 localVideoTrack 都不存在，后面会自动初始化（无预览模式）
        // 如果只有 localVideoTrack 存在但 capturer 不存在，说明状态异常（如从休眠恢复）
        if localVideoTrack != nil && capturer == nil {
            //print("⚠️ localVideoTrack 存在但 capturer 为 nil，可能从休眠恢复，将自动重新初始化")
            // 清空轨道，让后面重新初始化整个管线
            previewVideoTrack?.remove(localView)  // 🔥 移除预览轨道
            previewVideoTrack = nil
            previewVideoSource = nil
            localVideoTrack = nil
            videoSource = nil
            frameThrottler = nil
            print("🔄 已清理旧的视频轨道，准备重新初始化")
        }
        
        //print("✅ 所有前置条件满足，开始创建 PeerConnection...")
        
        // 🔥 关键修复：如果旧的 pc 存在，先清理
        if let oldPc = pc {
            //print("⚠️ 发现旧的 PeerConnection，先清理...")
            oldPc.close()
            pc = nil
            //print("✅ 旧 PeerConnection 已清理")
        }
        
        // ✅ 使用配置的档位，如果没有指定则使用 currentProfile
        let useProfile = initialProfile ?? currentProfile
        //print("🎯 推流档位: \(useProfile)")
        
        // 🔥 推流前先从服务器配置读取目标FPS（确保使用正确的FPS）
        if let serverCfg = ConfigManager.shared.getCurrentConfig() {
            print("📋 [后端配置] 完整配置:")
            print("   type=\(serverCfg.type), direction=\(serverCfg.direction), zoom=\(serverCfg.zoom)")
            print("   fps=\(serverCfg.fps ?? 0), bitrate=\(serverCfg.bitrate ?? 0), focus=\(serverCfg.focus ?? 0)")
            print("   ptype=\(serverCfg.ptype), angle=\(serverCfg.angle ?? 0)")
            
            if let serverFps = serverCfg.fps {
                targetOutputFPS = serverFps
                print("🎯 [初始化-推流] 从服务器配置读取目标FPS: \(serverFps)fps")
            } else {
                print("⚠️ [初始化-推流] 服务器配置无FPS，使用默认值: \(targetOutputFPS)fps")
            }
        } else {
            print("⚠️ [初始化-推流] 无法获取服务器配置，使用默认FPS: \(targetOutputFPS)fps")
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
        //print("✅ 新 PeerConnection 已创建")

        // 音频轨
        //let audioSrc = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        //let audioTrack = factory.audioTrack(with: audioSrc, trackId: "audio0")
        //_ = pc.add(audioTrack, streamIds: ["s0"])

        // 视频轨：优先复用预览管线
        if let pushTrack = localVideoTrack, capturer != nil {
            // 🔥 复用推送轨道（localVideoTrack 已经绑定到 videoSource）
            videoSender = pc.add(pushTrack, streamIds: ["s0"]) // 保存 sender，便于设码率
            print("🔄 推流复用预览管线（预览60fps，推送\(targetOutputFPS)fps）")
        } else {
            // 无预览时才初始化采集与轨道
            videoSource = factory.videoSource()
            previewVideoSource = factory.videoSource()  // 🔥 预览用
            
            // 建立管线链：capturer -> throttler -> (previewVideoSource + videoSource)
            let throttler = FrameThrottler()
            throttler.inner = videoSource                    // 🔥 推送输出
            throttler.previewDelegate = previewVideoSource   // 🔥 预览输出（固定60fps）
            throttler.targetSendFps = self.targetOutputFPS   // 🔥 只影响推送
            throttler.fpsReportHandler = { [weak self] cap, snd in
                    self?.currentCaptureFps = cap
                    self?.currentSendFps = snd
            }

            self.frameThrottler = throttler
            capturer = RTCCameraVideoCapturer(delegate: throttler)
            print("🔄 [startPublish] 创建帧节流器，推送目标FPS: \(self.targetOutputFPS)fps，预览固定60fps")

            // 🔥 预览轨道绑定到 previewVideoSource
            let previewTrack = factory.videoTrack(with: previewVideoSource, trackId: "local_preview")
            previewVideoTrack = previewTrack
            previewVideoTrack?.add(localView)
            
            // 🔥 推送轨道绑定到 videoSource
            let videoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
            localVideoTrack = videoTrack
            videoSender = pc.add(videoTrack, streamIds: ["s0"]) // 保存 sender
            
            // ✅ 根据配置选择初始摄像头
            let devices = RTCCameraVideoCapturer.captureDevices()
            let cfg = ConfigManager.shared.getCurrentConfig()
            let wantFront = (cfg?.direction == "1")  // 1=前置，-1=后置
            let initialCamera: AVCaptureDevice?
            
            if wantFront {
                initialCamera = devices.first(where: { $0.position == .front }) ?? devices.first
                //print("🎬 推流配置要求前置摄像头(direction=1)，使用前置启动")
            } else {
                initialCamera = devices.first(where: { $0.position == .back }) ?? devices.first
                //print("🎬 推流配置要求后置摄像头(direction=-1)，使用后置启动")
            }
            
            if let camera = initialCamera {
                calculateLadderForDevice(camera)
                
                // 🔥 初始化时立即设置正确的采集FPS（根据前后置摄像头）
                // 后置: 240fps, 前置: 120fps
                if let preset = currentLadder[currentProfile] {
                    currentCaptureFPS = preset.fps
                    print("🎬 [初始化] 摄像头: \(camera.position == .back ? "后置" : "前置"), 采集FPS: \(preset.fps)fps")
                }
            }
            
            // ✅ 全系 16:9 采集（1920x1080）
            if let camera = initialCamera {
                print("🎬 [初始化-推流] 采集分辨率: \(fixedCaptureWidth)x\(fixedCaptureHeight) (16:9)")
                startCaptureWithDevice(camera, width: fixedCaptureWidth, height: fixedCaptureHeight, fps: 60)
            }
        }

        // 🔥 设置分辨率缩放比例（根据当前档位）
        let scale = getResolutionScaleForProfile(currentProfile)
        currentResolutionScale = scale
        
        // 🔥 设置码率（此时 currentCaptureFPS 已根据前后置摄像头正确设置）
        let targetKbps = effectiveMaxKbpsForCurrentProfile()
        setMaxBitrateKbps(targetKbps)
        //print("📊 推流初始化：档位=\(useProfile), 码率=\(targetKbps)kbps")

        // Offer（发送端不接收远端）
        let sdpCons = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio":"false","OfferToReceiveVideo":"false"],
            optionalConstraints: nil
        )
        
        pc.offer(for: sdpCons) { [weak self] sdp, err in
            guard let self, let sdp else { print("offer err", err ?? "nil"); return }
            
            // 🔥 安全检查：pc 可能在异步期间被清空
            guard let pc = self.pc else {
                print("⚠️ pc 已被清空，跳过 setLocalDescription")
                return
            }
            
            pc.setLocalDescription(sdp) { _ in }
            Task {
                do {
                    let ans = try await self.postOfferToSRS(
                        apiPath: "/rtc/v1/publish/",
                        streamurl: "webrtc://\(self.srsIP)/\(self.app)/\(self.streamKey)",
                        offer: sdp.sdp
                    )
                    
                    // 🔥 安全检查：pc 可能在异步网络请求期间被清空
                    guard let pc = self.pc else {
                        print("⚠️ pc 已被清空，跳过 setRemoteDescription")
                        return
                    }
                    
                    //print("🔄 开始设置 Remote Description (SRS Answer)...")
                    pc.setRemoteDescription(.init(type: .answer, sdp: ans)) { err in
                        if let err {
                            //print("❌ setRemoteDescription 失败：\(err)")
                            // 发送失败通知
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(
                                    name: .publishFailed,
                                    object: nil,
                                    userInfo: ["reason": "设置 Answer 失败: \(err.localizedDescription)"]
                                )
                            }
                        } else {
                            //print("✅ setRemoteDescription 成功")
                            DispatchQueue.main.async {
                                self.isPublishing = true
                                WebSocketManager.isPublishingFlag = 1
                                //print("✅✅✅ 推流状态已设置：isPublishing = true")
                                
                                self.startStats()   // 启动统计 + 自适应
                            }
                            //print("✅ 发布成功：\(self.streamKey)")
                        }
                    }
                } catch {
                    //print("❌ 发布失败：\(error.localizedDescription)")
                    // 🔥 关键修复：发送推流失败通知，触发重试机制
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .publishFailed,
                            object: nil,
                            userInfo: ["reason": "SRS 服务器错误: \(error.localizedDescription)"]
                        )
                    }
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
                
                // 🔒 极限CBR：按FPS比例调整码率，min=max强制恒定
                let targetKbps = effectiveMaxKbpsForCurrentProfile()  // 按推送FPS比例计算
                let minKbps = targetKbps  // 100% - min=目标值
                let maxKbps = targetKbps  // 100% - max=目标值
                
                dict["x-google-start-bitrate"] = "\(targetKbps)"
                dict["x-google-min-bitrate"] = "\(minKbps)"
                dict["x-google-max-bitrate"] = "\(maxKbps)"
                
                //print("🔧 SDP极限CBR: start=min=max=\(targetKbps)kbps (强制恒定码率)")
                //print("💡 防止黑布等简单画面降低码率，避免后端模糊")
                
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
                
                // 🔥 安全检查：pc 可能在异步网络请求期间被清空
                guard let pc = self.pc else {
                    print("⚠️ pc 已被清空，跳过 setRemoteDescription (postAndSetAnswer)")
                    return
                }
                
                //print("🔄 开始设置 Remote Description (SRS Answer)...")
                pc.setRemoteDescription(.init(type: .answer, sdp: ans)) { err in
                    if let err {
                        //print("❌ setRemoteDescription 失败：\(err)")
                        // 发送失败通知
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: .publishFailed,
                                object: nil,
                                userInfo: ["reason": "设置 Answer 失败: \(err.localizedDescription)"]
                            )
                        }
                    } else {
                        //print("✅ setRemoteDescription 成功")
                        DispatchQueue.main.async {
                            self.isPublishing = true
                            WebSocketManager.isPublishingFlag = 1
                            //print("✅✅✅ 推流状态已设置：isPublishing = true")
                            
                            self.startStats()
                        }
                        //print("✅ 发布成功：\(self.streamKey)")
                    }
                }
            } catch {
                //print("❌ 发布失败：\(error.localizedDescription)")
                // 🔥 关键修复：发送推流失败通知，触发重试机制
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .publishFailed,
                        object: nil,
                        userInfo: ["reason": "SRS 服务器错误: \(error.localizedDescription)"]
                    )
                }
            }
        }
    }

    // 简单等待 ICE 完整（最多 timeoutSec 秒）
    private func waitForIceComplete(timeoutSec: TimeInterval,
                                    done: @escaping (RTCSessionDescription?) -> Void) {
        let deadline = Date().addingTimeInterval(timeoutSec)
        func poll() {
            // 🔥 安全检查：pc 可能在轮询期间被清空
            guard let pc = self.pc else {
                print("⚠️ pc 已被清空，停止 ICE 轮询")
                done(nil)
                return
            }
            
            if pc.iceGatheringState == .complete, let ld = pc.localDescription {
                done(ld); return
            }
            if Date() > deadline {
                done(pc.localDescription); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        poll()
    }


    @MainActor
    func stopPublish() {
        adaptTimer?.invalidate(); adaptTimer = nil
        statsTimer?.invalidate(); statsTimer = nil
        stopBitrateEnforcement()  // ✅ 停止码率强制定时器
        stopKeyframeTimer()       // ✅ 停止关键帧定时器
        badSeconds = 0; goodSeconds = 0
        kbpsHistory.removeAll()  // ✅ 清空码率历史
        fpsHistory.removeAll()    // ✅ 清空FPS历史
        WebSocketManager.isPublishingFlag = 0
        WebSocketManager.publishingKbps = 0
        WebSocketManager.publishingFps = 0
        WebSocketManager.publishingSendFps = 0
        WebSocketManager.publishingStreamKey = ""  // 清空流名
        WebSocketManager.networkQuality = "unknown"
        WebSocketManager.packetLoss = 0.0
        WebSocketManager.rtt = 0
        isPublishing = false
        pc?.close(); pc = nil
        //print("⏹️ 已停止发布")
    }
    
    // MARK: - 摄像头休眠/唤醒（节省电量）
    @Published var isCameraSleeping: Bool = false
    private var sleepBeforePublishing: Bool = false  // 休眠前是否在推流
    
    /// 摄像头休眠：停止采集但保持预览黑屏，节省电量
    @MainActor
    func sleepCamera() {
        print("💤 摄像头进入休眠模式...")
        
        // 🔥 先检查是否已经在休眠中
        if isCameraSleeping {
            print("   ⚠️ 已经在休眠中，忽略重复操作")
            return
        }
        
        // 记录休眠前的推流状态（在停止推流之前记录）
        sleepBeforePublishing = isPublishing
        print("   -> 记录休眠前推流状态: \(sleepBeforePublishing ? "正在推流" : "未推流")")
        
        // ✅ 摄像头状态已保存在 ConfigManager 中，无需单独记录
        
        // 如果正在推流，先停止推流
        if isPublishing {
            print("   -> 停止推流...")
            stopPublish()
        }
        
        // 停止摄像头采集并清空采集器
        if let capturer = self.capturer {
            capturer.stopCapture {
                print("   ✅ 摄像头采集已停止")
            }
        } else {
            print("   ⚠️ 采集器不存在，跳过停止采集")
        }
        
        // 🔥 清空所有视频管线对象，确保唤醒时会重新初始化
        self.capturer = nil
        self.frameThrottler = nil
        self.videoSource = nil
        // 不清空 localVideoTrack，保持预览视图绑定（显示黑屏）
        print("   -> 已清空采集器和视频源引用")
        
        // 🔥 休眠时保留对焦状态，唤醒后直接恢复
        // 不再重置 userHasManuallyAdjustedFocus 和 focusDistanceCache
        print("   -> 保留对焦状态（唤醒后将恢复当前焦距）")
        
        // 标记为休眠状态
        isCameraSleeping = true
        
        // 清空推流统计数据
        WebSocketManager.publishingKbps = 0
        WebSocketManager.publishingFps = 0
        WebSocketManager.publishingSendFps = 0
        currentKbps = 0
        currentFps = 0
        currentCaptureFps = 0
        currentSendFps = 0
        
        print("💤 摄像头休眠完成（休眠前推流状态: \(sleepBeforePublishing)）")
    }
    
    /// 摄像头唤醒：恢复采集，如果之前在推流则自动恢复推流
    @MainActor
    func wakeCamera() {
        print("☀️ 摄像头唤醒...")
        
        guard isCameraSleeping else {
            print("   ⚠️ 摄像头未休眠，无需唤醒")
            return
        }
        
        // 先标记为非休眠状态
        isCameraSleeping = false
        
        // 🔥 判断是否需要恢复推流
        let shouldRestorePublish = sleepBeforePublishing
        sleepBeforePublishing = false  // 立即重置，避免重复恢复
        
        if shouldRestorePublish {
            // 需要恢复推流：直接调用 startPublish（它会自动初始化摄像头）
            print("   -> 休眠前在推流，0.3秒后恢复推流（startPublish会自动初始化摄像头）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !self.isPublishing {
                    print("   -> 开始恢复推流...")
                    self.startPublish()
                    
                    // 🔥 唤醒后恢复所有配置（包括对焦）：需要等待摄像头初始化完成
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.reapplyConfigForWake()
                    }
                } else {
                    print("   ⚠️ 已经在推流中，跳过恢复推流")
                }
            }
        } else {
            // 不需要恢复推流：只恢复摄像头预览
            print("   -> 休眠前未推流，仅恢复预览")
            // 延迟一点启动预览，确保状态切换完成
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.startPreviewIfNeeded()
                
                // 🔥 唤醒后恢复所有配置（包括对焦）：需要等待摄像头初始化完成
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.reapplyConfigForWake()
                }
            }
        }
        
        print("☀️ 摄像头唤醒完成")
    }

    // MARK: - 相机控制
    private func configureCameraAutoModes(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            
            // 🔥 检查是否有后端配置的 focus 或者用户手动调整过
            let backendFocus = ConfigManager.shared.getCurrentConfig()?.focus
            let hasBackendFocus = backendFocus != nil
            let shouldUseLocked = userHasManuallyAdjustedFocus || hasBackendFocus
            
            if shouldUseLocked {
                // 用户已手动调整过 或 后端配置了 focus，使用手动对焦模式
                if device.isFocusModeSupported(.locked) {
                    // 🔥 关键修复：用户手动调整的值优先于后端配置
                    // 这样用户调好焦距后，切换摄像头回来仍然保持用户设置的值
                    let focusValue: Float
                    if userHasManuallyAdjustedFocus, let saved = savedUserFocusDistance {
                        // 🔥 用户手动调整过，优先使用用户设置的值
                        focusValue = saved
                        print("📸 对焦模式: 手动锁定, 焦距=\(focusValue) (用户手动调整)")
                    } else if let bf = backendFocus {
                        // 用户没调整过，使用后端配置
                        focusValue = bf
                        print("📸 对焦模式: 手动锁定, 焦距=\(focusValue) (后端配置)")
                    } else {
                        focusValue = 0.5  // 默认中间值
                        print("📸 对焦模式: 手动锁定, 焦距=\(focusValue) (默认值)")
                    }
                    
                    device.focusMode = .locked
                    if device.isLockingFocusWithCustomLensPositionSupported {
                        device.setFocusModeLocked(lensPosition: focusValue, completionHandler: nil)
                        focusDistance = focusValue
                    }
                }
            } else {
                // 首次启动且后端没有配置 focus，使用自动对焦
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                    print("📸 对焦模式: 连续自动对焦（首次启动）")
                }
            }
            
            // 🔥🔥 快门速度由 cjfps 控制（0-100 → 90-240）
            // cjfps=0 → 1/90s, cjfps=100 → 1/240s
            if device.isExposureModeSupported(.custom) {
                let targetShutterSpeed = 90 + Int(Double(cjfpsPercentage) * 1.5)  // 90~240
                let duration = CMTime(value: 1, timescale: CMTimeScale(targetShutterSpeed))
                
                let minDuration = device.activeFormat.minExposureDuration
                let maxDuration = device.activeFormat.maxExposureDuration
                
                let safeDuration: CMTime
                let actualShutterSpeed: Int
                if duration < minDuration {
                    safeDuration = minDuration
                    actualShutterSpeed = Int(1.0 / CMTimeGetSeconds(safeDuration))
                    print("📸 快门速度: cjfps=\(cjfpsPercentage)% → 1/\(actualShutterSpeed)s (硬件最快)")
                } else if duration > maxDuration {
                    safeDuration = maxDuration
                    actualShutterSpeed = Int(1.0 / CMTimeGetSeconds(safeDuration))
                    print("📸 快门速度: cjfps=\(cjfpsPercentage)% → 1/\(actualShutterSpeed)s (硬件最慢)")
                } else {
                    safeDuration = duration
                    actualShutterSpeed = targetShutterSpeed
                    print("📸 快门速度: cjfps=\(cjfpsPercentage)% → 1/\(actualShutterSpeed)s")
                }
                
                // 使用自动 ISO
                device.setExposureModeCustom(duration: safeDuration, iso: AVCaptureDevice.currentISO, completionHandler: nil)
                
                // 🔥🔥 关键：显式锁定帧率，防止手动曝光后帧率被自动降低
                // 直接使用 currentCaptureFPS（在 startCapture 前已正确设置）
                // 不从 activeFormat 读取，因为 startCapture 是异步的，格式可能还没更新
                let targetFps = currentCaptureFPS
                if targetFps > 0 {
                    let frameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
                    device.activeVideoMinFrameDuration = frameDuration
                    device.activeVideoMaxFrameDuration = frameDuration
                    print("📹 帧率锁定: \(targetFps)fps")
                }
            } else if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
                print("📸 快门速度: 自动（设备不支持手动快门）")
            }
            
            // ✅ 白平衡自动
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            
            // 关闭 HDR，减少发热/延迟
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
    
    
    // ✅ 手动对焦距离（0.0=近处，1.0=无穷远）
    func setFocus(_ distance: Float) {
        guard let devInput = capturer?.captureSession.inputs.first as? AVCaptureDeviceInput else {
            pendingFocus = distance; return
        }
        let dev = devInput.device
        do {
            try dev.lockForConfiguration()
            
            // ✅ 标记用户已手动调整过对焦（第一次时）
            if !userHasManuallyAdjustedFocus {
                userHasManuallyAdjustedFocus = true
                //print("🎯 首次手动对焦，从自动对焦切换到手动对焦模式")
            }
            
            // 🔥 保存用户设置的对焦距离
            let clamped = max(0.0, min(1.0, distance))
            savedUserFocusDistance = clamped
            
            // 切换到手动对焦模式
            if dev.isFocusModeSupported(.locked) {
                dev.focusMode = .locked
                // ✅ iOS 13+需要检查是否支持自定义镜头位置
                if dev.isLockingFocusWithCustomLensPositionSupported {
                    dev.setFocusModeLocked(lensPosition: clamped, completionHandler: nil)
                    focusDistance = clamped
                    //print("🔍 对焦距离 = \(clamped) (0.0=近处 1.0=无穷远)")
                    
                } else {
                    //print("⚠️ 当前设备不支持自定义对焦距离")
                }
            }else{
                //print("⚠️ 对焦距离无用")
            }
            dev.unlockForConfiguration()
            
            
        } catch {
            //print("❌ 设置对焦失败：\(error.localizedDescription)")
        }
    }

    // 🔥 生成对焦缓存键（摄像头位置 + 分辨率）
    private func getFocusCacheKey(device: AVCaptureDevice, width: Int, height: Int) -> String {
        let position = device.position == .back ? "后置" : "前置"
        return "\(position)_\(width)x\(height)"
    }
    
    // 🔥 获取缓存的对焦距离
    private func getCachedFocusDistance(device: AVCaptureDevice, width: Int, height: Int) -> Float? {
        let key = getFocusCacheKey(device: device, width: width, height: height)
        return focusDistanceCache[key]
    }
    
    // 🔥 保存对焦距离到缓存
    private func saveFocusDistanceToCache(device: AVCaptureDevice, width: Int, height: Int, distance: Float) {
        let key = getFocusCacheKey(device: device, width: width, height: height)
        focusDistanceCache[key] = distance
        print("💾 [对焦缓存] 保存: \(key) → \(distance)")
    }

    // 🔥 自动对焦然后锁定（用于分辨率切换时）
    // width/height: 用于生成缓存键
    private func autoFocusThenLock(device: AVCaptureDevice, width: Int, height: Int, completion: @escaping () -> Void) {
        // 🔥 检查是否支持自动对焦（前置和后置都检查）
        let supportsAutoFocus = device.isFocusModeSupported(.autoFocus)
        let supportsContinuousAutoFocus = device.isFocusModeSupported(.continuousAutoFocus)
        
        guard supportsAutoFocus || supportsContinuousAutoFocus else {
            // 不支持自动对焦，直接完成
            print("⚠️ 设备不支持自动对焦模式")
            completion()
            return
        }
        
        print("🔍 开始自动对焦: 设备=\(device.position == .back ? "后置" : "前置"), 支持autoFocus=\(supportsAutoFocus), 支持continuousAutoFocus=\(supportsContinuousAutoFocus)")
        
        do {
            try device.lockForConfiguration()
            
            // 🔥 对于后置摄像头，先设置为连续自动对焦，然后再切换到一次性自动对焦
            // 这样可以确保对焦系统被激活
            if supportsContinuousAutoFocus {
                // 先设置为连续自动对焦，激活对焦系统
                device.focusMode = .continuousAutoFocus
                
                // 设置对焦点（如果支持）
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                }
                
                device.unlockForConfiguration()
                
                // 🔥 增加等待时间，确保连续自动对焦系统完全启动（前后置都用0.5秒）
                let waitTime: Double = 0.5
                print("🔍 [\(device.position == .back ? "后置" : "前置")] 等待\(waitTime)秒让连续自动对焦启动...")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                    do {
                        try device.lockForConfiguration()
                        
                        // 检查当前对焦模式
                        print("🔍 [\(device.position == .back ? "后置" : "前置")] 当前对焦模式: \(device.focusMode.rawValue)")
                        
                        // 2. 再次设置对焦点（确保对焦点设置生效）
                        if device.isFocusPointOfInterestSupported {
                            device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                            print("🔍 [\(device.position == .back ? "后置" : "前置")] 设置对焦点到中心: (0.5, 0.5)")
                        }
                        
                        // 3. 切换到一次性自动对焦模式（这会触发一次对焦）
                        if supportsAutoFocus {
                            device.focusMode = .autoFocus
                            print("🔍 [\(device.position == .back ? "后置" : "前置")] 切换到一次性自动对焦模式")
                        }
                        
                        device.unlockForConfiguration()
                        
                        // 再等待一小段时间，确保对焦开始
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            // 继续执行对焦检测逻辑
                            self.startFocusMonitoring(device: device, width: width, height: height, completion: completion)
                        }
                    } catch {
                        device.unlockForConfiguration()
                        print("⚠️ [\(device.position == .back ? "后置" : "前置")] 设置自动对焦失败：\(error.localizedDescription)")
                        completion()
                    }
                }
            } else if supportsAutoFocus {
                // 只支持一次性自动对焦
                device.focusMode = .autoFocus
                
                // 2. 触发一次自动对焦（如果支持对焦点）
                if device.isFocusPointOfInterestSupported {
                    // 使用画面中心点对焦
                    device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                }
                
                device.unlockForConfiguration()
                
                // 继续执行对焦检测逻辑
                startFocusMonitoring(device: device, width: width, height: height, completion: completion)
            } else {
                device.unlockForConfiguration()
                completion()
            }
            
        } catch {
            device.unlockForConfiguration()
            print("⚠️ 设置自动对焦失败：\(error.localizedDescription)")
            completion()
        }
    }
    
    // 🔥 对焦状态监控（从 autoFocusThenLock 中分离出来）
    private func startFocusMonitoring(device: AVCaptureDevice, width: Int, height: Int, completion: @escaping () -> Void) {
        let deviceType = device.position == .back ? "后置" : "前置"
        let isBackCamera = device.position == .back
        print("🔍 [\(deviceType)] 开始监控对焦状态...")
        
        // 等待一小段时间，确保对焦开始
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // 检查对焦是否已经开始
            if device.isAdjustingFocus {
                print("🔍 [\(deviceType)] 对焦正在进行中...")
            } else {
                print("⚠️ [\(deviceType)] 对焦可能未启动，isAdjustingFocus=\(device.isAdjustingFocus)")
            }
        }
        
        // 使用定时器轮询对焦状态
        var checkCount = 0
        let maxChecks = 50  // 最多等待5秒（50次 × 0.1秒）
        
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            checkCount += 1
            
            // 对焦完成（不再调整）
            if !device.isAdjustingFocus {
                timer.invalidate()
                print("✅ [\(deviceType)] 对焦完成（检查次数: \(checkCount)）")
                
                // 🔥 后置摄像头：对焦完成后保持连续自动对焦，不锁定
                if isBackCamera {
                    do {
                        try device.lockForConfiguration()
                        
                        // 获取当前对焦位置（用于记录）
                        let currentLensPosition = device.lensPosition
                        self?.focusDistance = currentLensPosition
                        
                        // 🔥 后置摄像头保持连续自动对焦模式
                        if device.isFocusModeSupported(.continuousAutoFocus) {
                            device.focusMode = .continuousAutoFocus
                            print("✅ [\(deviceType)] 自动对焦完成，保持连续自动对焦模式，当前对焦距离=\(currentLensPosition)")
                        } else {
                            print("⚠️ [\(deviceType)] 不支持连续自动对焦模式")
                        }
                        
                        device.unlockForConfiguration()
                        completion()
                    } catch {
                        print("⚠️ [\(deviceType)] 设置对焦模式失败：\(error.localizedDescription)")
                        completion()
                    }
                } else {
                    // 前置摄像头：锁定到当前对焦位置
                do {
                    try device.lockForConfiguration()
                    
                    if device.isFocusModeSupported(.locked) {
                        // 如果支持自定义镜头位置，获取当前对焦位置并锁定
                        if device.isLockingFocusWithCustomLensPositionSupported {
                            // 获取当前镜头位置（对焦完成后的位置）
                            let currentLensPosition = device.lensPosition
                            
                            print("🔍 [\(deviceType)] 当前镜头位置: \(currentLensPosition)")
                            
                            // 锁定到当前对焦位置（自动对焦的结果）
                            device.focusMode = .locked
                            device.setFocusModeLocked(lensPosition: currentLensPosition, completionHandler: { _ in
                                device.unlockForConfiguration()
                                
                                // 保存自动对焦的位置
                                self?.focusDistance = currentLensPosition
                                
                                // 🔥 保存到缓存（下次直接使用）
                                self?.saveFocusDistanceToCache(device: device, width: width, height: height, distance: currentLensPosition)
                                
                                print("✅ [\(deviceType)] 自动对焦完成并锁定，对焦距离=\(currentLensPosition)")
                                completion()
                            })
                        } else {
                            // 不支持自定义位置，直接锁定
                            device.focusMode = .locked
                            device.unlockForConfiguration()
                            print("✅ [\(deviceType)] 自动对焦完成并锁定（不支持自定义位置）")
                            completion()
                        }
                    } else {
                        device.unlockForConfiguration()
                        print("⚠️ [\(deviceType)] 不支持锁定对焦模式")
                        completion()
                    }
                } catch {
                    device.unlockForConfiguration()
                    print("⚠️ [\(deviceType)] 锁定对焦失败：\(error.localizedDescription)")
                    completion()
                    }
                }
            } else if checkCount >= maxChecks {
                // 超时，强制完成
                timer.invalidate()
                print("⚠️ [\(deviceType)] 自动对焦超时（5秒），强制完成，isAdjustingFocus=\(device.isAdjustingFocus)")
                
                // 🔥 后置摄像头超时也保持连续自动对焦
                if isBackCamera {
                    do {
                        try device.lockForConfiguration()
                        if device.isFocusModeSupported(.continuousAutoFocus) {
                            device.focusMode = .continuousAutoFocus
                            print("⚠️ [\(deviceType)] 超时后保持连续自动对焦模式")
                        }
                        device.unlockForConfiguration()
                    } catch {
                        print("⚠️ [\(deviceType)] 超时后设置对焦模式失败：\(error.localizedDescription)")
                    }
                } else {
                    // 前置摄像头超时尝试锁定
                do {
                    try device.lockForConfiguration()
                    if device.isFocusModeSupported(.locked) {
                        // 如果支持自定义位置，尝试获取当前位置
                        if device.isLockingFocusWithCustomLensPositionSupported {
                            let currentLensPosition = device.lensPosition
                            device.focusMode = .locked
                            device.setFocusModeLocked(lensPosition: currentLensPosition, completionHandler: nil)
                            print("⚠️ [\(deviceType)] 超时后强制锁定，对焦距离=\(currentLensPosition)")
                        } else {
                            device.focusMode = .locked
                            print("⚠️ [\(deviceType)] 超时后强制锁定（不支持自定义位置）")
                        }
                    }
                    device.unlockForConfiguration()
                } catch {
                    print("⚠️ [\(deviceType)] 超时后锁定对焦失败：\(error.localizedDescription)")
                    }
                }
                
                completion()
            } else if checkCount % 10 == 0 {
                // 每1秒打印一次状态
                print("🔍 [\(deviceType)] 对焦中... (\(checkCount)/\(maxChecks)), isAdjustingFocus=\(device.isAdjustingFocus)")
            }
        }
        
        // 将定时器添加到 RunLoop
        RunLoop.current.add(timer, forMode: .common)
    }
    
    // 数码变焦（可选）
    // 🔥 支持超广角：zoom < 1.0 表示使用更广的视野
    // - iPhone 11+ 后置摄像头支持 minAvailableVideoZoomFactor ≈ 0.5（超广角）
    // - zoom = 0.5 表示使用超广角镜头的全视野
    // - zoom = 1.0 表示标准广角（主摄）
    // - zoom > 1.0 表示数码变焦（裁剪放大）
    func setZoom(_ factor: CGFloat) {
        print("🔍 [setZoom] 收到请求: factor=\(factor)")
        
        // 🔥 先保存到本地变量（即使 capturer 不存在也保存，用于后续恢复）
        currentZoomFactor = factor
        
        guard let devInput = capturer?.captureSession.inputs.first as? AVCaptureDeviceInput else {
            print("⚠️ [setZoom] capturer 未准备好，zoom=\(factor) 已保存，等待后续应用")
            return
        }
        let dev = devInput.device
        let deviceType = dev.deviceType.rawValue
        let position = dev.position == .front ? "前置" : "后置"
        
        print("🔍 [setZoom] 设备: \(position) (\(deviceType))")
        
        do {
            try dev.lockForConfiguration()
            
            // 🔥 使用设备实际支持的最小/最大 zoom 值，支持超广角
            let minZoom = dev.minAvailableVideoZoomFactor  // iPhone 11+ 后置约 0.5
            let maxZoom = dev.activeFormat.videoMaxZoomFactor
            let currentZoom = dev.videoZoomFactor
            let safe = max(minZoom, min(factor, maxZoom))
            
            print("🔍 [setZoom] 当前zoom=\(currentZoom), 请求=\(factor), 范围=\(minZoom)~\(maxZoom), 最终=\(safe)")
            
            dev.videoZoomFactor = safe
            dev.unlockForConfiguration()
            
            // 验证是否设置成功
            let verifyZoom = dev.videoZoomFactor
            print("🔍 [setZoom] 设置后验证: zoom=\(verifyZoom)")
            
            if abs(verifyZoom - safe) > 0.01 {
                print("⚠️ [setZoom] 警告: zoom设置可能未生效! 期望=\(safe), 实际=\(verifyZoom)")
            }
        } catch {
            print("❌ [setZoom] 变焦失败：\(error.localizedDescription)")
        }
    }
    
    func toggleCamera() {
        // ... existing code ...
        guard let curInput = capturer?.captureSession.inputs.first as? AVCaptureDeviceInput else {
            //print("❌ toggleCamera: 无法获取当前输入设备")
            return
        }
        
        let currentPos = curInput.device.position
        let newPos: AVCaptureDevice.Position = (currentPos == .back) ? .front : .back
        
        //print("🔄 toggleCamera: 从 \(currentPos == .back ? "后置" : "前置") 切换到 \(newPos == .back ? "后置" : "前置")")
        
        guard let dev = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == newPos }) else {
            //print("❌ toggleCamera: 找不到目标摄像头设备")
            return
        }

        let allFormats = RTCCameraVideoCapturer.supportedFormats(for: dev)
        
        // ✅ 不过滤横竖向：高FPS格式可能是竖向的，通过FrameThrottler旋转处理即可
        let deviceMaxOverallFPS = Int(
            allFormats.compactMap { fmt in fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() }.max() ?? 0
        )
        
        // 🔥 打印摄像头支持的所有分辨率（去重，保留每个分辨率的最高FPS）
        print("📱 [\(newPos == .back ? "后置" : "前置")摄像头] 支持的分辨率 (共\(allFormats.count)个格式):")
        // 去重：同分辨率保留最高FPS
        var resolutionDict: [String: (width: Int32, height: Int32, maxFps: Int)] = [:]
        for fmt in allFormats {
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let maxFps = Int(fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            let key = "\(dims.width)x\(dims.height)"
            if let existing = resolutionDict[key] {
                // 保留最高FPS
                if maxFps > existing.maxFps {
                    resolutionDict[key] = (dims.width, dims.height, maxFps)
                }
            } else {
                resolutionDict[key] = (dims.width, dims.height, maxFps)
            }
        }
        // 按分辨率从高到低排序
        let resolutionList = resolutionDict.values.sorted { ($0.width * $0.height) > ($1.width * $1.height) }
        for (idx, res) in resolutionList.enumerated() {
            let isLandscape = res.width > res.height
            print("   [\(idx)] \(res.width)x\(res.height) @\(res.maxFps)fps \(isLandscape ? "横向" : "竖向")")
        }
        print("   📊 设备整体最大FPS: \(deviceMaxOverallFPS)fps")

        // 🔥 全系 16:9 采集（1920x1080）
        let targetWidth = fixedCaptureWidth
        let targetHeight = fixedCaptureHeight
        
        print("🔄 [toggleCamera] 采集分辨率: \(targetWidth)x\(targetHeight) (16:9)")
        
        // 🔥 优先选择支持 60fps 的格式
        let matchingFormats = allFormats.filter { fmt in
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let w = Int(dims.width)
            let h = Int(dims.height)
            return (w == targetWidth && h == targetHeight) || (w == targetHeight && h == targetWidth)
        }
        
        let highFpsFormats = matchingFormats.filter { fmt in
            let maxFps = Int(fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            return maxFps >= 60
        }
        
        print("   找到\(matchingFormats.count)个匹配格式，其中\(highFpsFormats.count)个支持60fps+")
        
        let candidateFormats = highFpsFormats.isEmpty ? allFormats : highFpsFormats
        
        // 分辨率优先：先选最接近目标的，分辨率相同时选最高FPS的
        guard let best = candidateFormats.sorted(by: { f0, f1 in
            let a = CMVideoFormatDescriptionGetDimensions(f0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions(f1.formatDescription)
            let d0 = abs(Int(a.width) - targetWidth) + abs(Int(a.height) - targetHeight)
            let d1 = abs(Int(b.width) - targetWidth) + abs(Int(b.height) - targetHeight)
            if d0 != d1 { return d0 < d1 }  // 分辨率更接近的优先
            
            // 分辨率相同时，选最高FPS的
            let max0 = Int(f0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            let max1 = Int(f1.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            return max0 > max1
        }).first else { return }

        let maxFps = Int(best.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
           let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
           //print("✅ 选中格式 \(dims.width)x\(dims.height) 最大FPS=\(maxFps)")
           
           // 🔍 打印该格式的所有帧率范围
           //print("📊 该格式的帧率范围:")
           for (idx, range) in best.videoSupportedFrameRateRanges.enumerated() {
               print("   [\(idx)] \(Int(range.minFrameRate))-\(Int(range.maxFrameRate))fps")
           }

        // 🔥 直接使用设备最大 FPS（cjfps 只控制快门速度，不再控制采集 FPS）
       let useFps = maxFps
        currentCaptureFPS = useFps
        
        print("📹 [toggleCamera] 使用设备最大: \(useFps)fps (cjfps=\(cjfpsPercentage)% 仅控制快门)")
       
       // ✅ 确保推送FPS不超过采集FPS
       if let currentSendFps = self.frameThrottler?.targetSendFps, currentSendFps > useFps {
           self.frameThrottler?.targetSendFps = useFps
           targetOutputFPS = useFps
           print("⚠️ 推送FPS(\(currentSendFps)) 超过采集FPS(\(useFps))，已限制为\(useFps)fps")
       }

        capturer.stopCapture { [weak self] in
               guard let self = self else { return }
               
               // ✅ 关键：切换摄像头后重新计算档位配置
               if let preset = self.currentLadder[self.currentProfile] {
                   print("📋 切换前档位配置: \(preset.width)x\(preset.height)@\(preset.fps)fps → \(preset.maxKbps)kbps")
               }
               self.calculateLadderForDevice(dev)
               if let preset = self.currentLadder[self.currentProfile] {
                   print("📋 切换后档位配置: \(preset.width)x\(preset.height)@\(preset.fps)fps → \(preset.maxKbps)kbps")
                   
                   // 🔥 切换摄像头后更新采集FPS（用于FPS缩放计算）
                   // 后置: 240fps, 前置: 120fps
                   self.currentCaptureFPS = preset.fps
                   print("🎬 [切换摄像头] 更新采集FPS: \(preset.fps)fps (\(dev.position == .back ? "后置" : "前置"))")
               }
               
               // ✅ 重新设置码率（切换摄像头后档位配置变了，码率也要更新）
               // 此时 currentCaptureFPS 已更新为新摄像头的采集FPS
               let newKbps = self.effectiveMaxKbpsForCurrentProfile()
               self.setMaxBitrateKbps(newKbps)
               //print("🔄 切换摄像头后重新设置码率: \(newKbps)kbps (±100kb)")
               
               // 🔥 立即强制码率，确保切换时码率立即生效
               self.enforceBitrateImmediately()
               
               // 🔥 关键：让 WebRTC SDK 自己设置帧率
               let actualMaxFps = Int(best.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
               let finalFps = min(useFps, actualMaxFps)
               
               if finalFps < useFps {
                   //print("⚠️ 目标FPS \(useFps) 超过格式最大支持FPS \(actualMaxFps)，降低到 \(finalFps)fps")
                   self.currentCaptureFPS = finalFps
               }
               
               // 🔥 先启动采集
               self.capturer.startCapture(with: dev, format: best, fps: finalFps)
               print("🚀 采集启动(切换): \(dims.width)x\(dims.height) @\(finalFps)fps (16:9)")
               
               // ✅ 延迟配置相机模式，确保 activeFormat 已更新
               DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                   guard let self = self else { return }
                   self.configureCameraAutoModes(dev)
               }
               
               // ✅ 更新 ConfigManager 中的 direction，记录当前使用的摄像头（保留其他所有字段）
               let newDirection = (newPos == .front) ? "1" : "-1"
               if var currentConfig = ConfigManager.shared.getCurrentConfig() {
                   // 🔥 只修改 direction，其他字段（type, zoom, ptype, fps, bitrate, angle, focus, brightness, saturation, contrast, exposureBias）全部保留
                   currentConfig.direction = newDirection
                   ConfigManager.shared.currentThinConfig = currentConfig  // 更新内存中的配置
                   ConfigManager.shared.cacheThinConfig(currentConfig)     // 持久化到本地
                   print("📝 已更新配置: direction=\(newDirection) (保留: type=\(currentConfig.type), zoom=\(currentConfig.zoom), ptype=\(currentConfig.ptype), fps=\(currentConfig.fps ?? 0), bitrate=\(currentConfig.bitrate ?? 0))")
               }
               
               // ✅ 立即应用方向，避免画面旋转（App已强制横屏）
               // 使用极短延迟确保 session 已启动
               DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                   self?.applyMountTransform()
                   
                   // 🪞 更新预览镜像（前置摄像头需要镜像）
                   self?.updatePreviewMirror(isFrontCamera: newPos == .front)
                   
                   // 🔥 切换摄像头后立即强制码率，确保码率立即提升到最大值附近
                   self?.enforceBitrateImmediately()
                   
                   // 🔥 切换摄像头后恢复配置（除对焦外）：变焦、FPS、码率等
                   self?.reapplyConfigExceptFocus()
                   
                   // 🔥 切换摄像头后恢复对焦（延迟应用，确保摄像头已稳定）
                   DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                       self?.reapplyFocusFromConfig()
                   }
               }
               
               // ✅ 获取实际使用的分辨率（用于对焦缓存）
               let actualDims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
               let actualWidth = Int(actualDims.width)
               let actualHeight = Int(actualDims.height)
               
               // 🔥 禁用自动对焦 - 切换摄像头后保持当前焦距或使用后端配置
               print("🔍 [toggleCamera] 不执行自动对焦，保持当前焦距设置")
               
               // 如果有待处理的对焦设置，延迟应用
                       if let focus = self.pendingFocus {
                   DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                       self?.pendingFocus = nil
                       self?.setFocus(focus)
                       print("🔍 [toggleCamera] 应用待处理的焦距: \(focus)")
                   }
               }
               
               // ✅ 重新连接节流器
               if self.frameThrottler == nil {
                   let t = FrameThrottler()
                   t.inner = self.videoSource
                   t.previewDelegate = self.previewVideoSource  // 🔥 预览输出（固定60fps）
                   t.targetSendFps = self.targetOutputFPS       // 🔥 只影响推送
                   self.frameThrottler = t
                   print("🔄 [toggleCamera] 重新创建帧节流器，推送目标FPS: \(self.targetOutputFPS)fps，预览固定60fps")
               }
               
               self.capturer.delegate = self.frameThrottler!
               
               print("🎯 推送FPS = \(self.frameThrottler?.targetSendFps ?? 60)fps，预览FPS = 60fps (切换摄像头后保持)")
           }
    }

    // MARK: - 档位应用（热切换，不断流）
    // ✅ 切换档位（热切换：通过 scaleResolutionDownBy 缩放输出分辨率，不断流）
    func applyProfile(_ p: LadderProfile) {
        guard let preset = currentLadder[p] else { return }
        let oldProfile = currentProfile
        let oldMaxPushFps = getMaxPushFpsForProfile(oldProfile)
        let oldScale = currentResolutionScale
        currentProfile = p
        let newMaxPushFps = getMaxPushFpsForProfile(p)
        
        print("♻️ 档位热切换: \(oldProfile)(上限\(oldMaxPushFps)fps) → \(p)(上限\(newMaxPushFps)fps)")
        print("   当前状态: 采集=\(currentCaptureFPS)fps, 后端目标=\(targetOutputFPS)fps")
        print("   目标配置: \(preset.width)x\(preset.height)@\(preset.fps)fps → \(preset.maxKbps)kbps")
        
        // 🔥 计算分辨率缩放比例（热切换分辨率，不断流）
        let scale = getResolutionScaleForProfile(p)
        
        // 🔥🔥 全系 16:9 采集（1920x1080）
        let outputWidth = Int(Double(fixedCaptureWidth) / scale)
        let outputHeight = Int(Double(fixedCaptureHeight) / scale)
        print("   📐 分辨率切换: scale \(oldScale) → \(scale)")
        print("      目标档位分辨率: \(preset.width)x\(preset.height)")
        print("      采集分辨率: \(fixedCaptureWidth)x\(fixedCaptureHeight)")
        print("      计算输出分辨率: \(outputWidth)x\(outputHeight)")
        setResolutionScale(scale)
        
        // 🔥 检查当前推送FPS是否超过新档位的限制
        // 注意：后端FPS需要除以2才是实际WebRTC推送FPS，所以后端最大可发送 maxPushFps * 2
        let maxPushFps = getMaxPushFpsForProfile(p)
        let maxBackendFps = maxPushFps * 2  // 后端最大可发送值（除以2后=档位上限）
        if targetOutputFPS > maxBackendFps {
            print("   ⚠️ 当前后端FPS(\(targetOutputFPS))超过限制(\(maxBackendFps)fps)，自动调低")
            targetOutputFPS = maxBackendFps
            frameThrottler?.targetSendFps = maxBackendFps
        }
        print("   最高推送FPS限制: \(maxPushFps)fps, 后端最大: \(maxBackendFps)fps")
        
        // ✅ 使用 effectiveMaxKbpsForCurrentProfile() 来考虑质量百分比和推送FPS
        let targetKbps = effectiveMaxKbpsForCurrentProfile()
        setMaxBitrateKbps(targetKbps)
        
        // 🔥 立即强制码率，确保切换时码率立即生效
        enforceBitrateImmediately()
        
        print("   🔥 热切换完成: 采集=\(fixedCaptureWidth)x\(fixedCaptureHeight) → 输出=\(outputWidth)x\(outputHeight)")
        print("   实际码率: \(targetKbps)kbps (±100kb)")
        
        // 🔥 恢复其他配置（变焦、FPS、码率等）
        // 全系 16:9 采集，不需要在档位切换时重新采集
        reapplyConfigExceptFocus()
    }
    
    /// 检查当前是否是前置摄像头
    private func isFrontCameraActive() -> Bool {
        guard let input = capturer?.captureSession.inputs.first as? AVCaptureDeviceInput else {
            return false
        }
        return input.device.position == .front
    }

    // 保存当前目标码率，用于周期性强制重置
    private var targetBitrateKbps: Int = 2000
    private var bitrateEnforceTimer: Timer?
    
    func setMaxBitrateKbps(_ kbps: Int) {
        // 记录目标码率
        targetBitrateKbps = kbps
        
        // 记录 sender
        if videoSender == nil {
            videoSender = pc?.senders.first(where: { $0.track?.kind == kRTCMediaStreamTrackKindVideo })
        }
        guard let sender = videoSender else {
            print("⚠️ videoSender 为空，无法设置码率")
            return
        }
        
        var params = sender.parameters
        if params.encodings.isEmpty {
            params.encodings = [RTCRtpEncodingParameters()]
        }
        
        // 🔥 优化VBR策略：码率可下浮，但不能超过最大值
        let maxBps = kbps * 1000  // 最大码率 = maxKbps（硬上限，绝不超过）
        
        // 🔥 允许码率动态向下调整：静态画面可降低到70%，但绝不超过maxKbps
        let minBps = Int(Double(maxBps) * 0.7)  // 70% - 静态场景可降低
        
        params.encodings[0].maxBitrateBps = NSNumber(value: maxBps)
        params.encodings[0].minBitrateBps = NSNumber(value: minBps)
        
        // 🔥 WebRTC推送FPS = targetOutputFPS（已经是 fps/2 后的值）
        // targetOutputFPS 在 setAverageOutputFPS 中已经做了 /2 处理
        // 例如：后端发120fps → targetOutputFPS=60fps
        // 例如：后端发60fps → targetOutputFPS=30fps
        let targetFps = frameThrottler?.targetSendFps ?? targetOutputFPS
        let maxPushFps = getMaxPushFpsForCurrentProfile()
        let webrtcFps = min(maxPushFps, targetFps)  // 直接使用，不再 /2
        params.encodings[0].maxFramerate = NSNumber(value: webrtcFps)
        
        // 🔍 详细FPS计算日志
        print("📊 [FPS计算] 档位=\(currentProfile), 推送目标=\(targetFps)fps, 上限=\(maxPushFps)fps → WebRTC=\(webrtcFps)fps")
        
        // 🔥 设置网络优先级为最高
        params.encodings[0].networkPriority = .high
        
        // 🔥 使用当前分辨率缩放比例（热切换分辨率）
        params.encodings[0].scaleResolutionDownBy = NSNumber(value: currentResolutionScale)
        
        // 🔥 关键：强制激活编码
        params.encodings[0].isActive = true
        
        // 🔥 设置关键帧间隔（GOP）：减小间隔可减少卡顿恢复时间
        // 1秒一个关键帧，Windows端丢包后最多等1秒就能恢复
        // 注意：关键帧间隔越小，码率开销越大（约5-10%）
        // 可选值：1=最低延迟，2=平衡，3=节省码率
        // params.encodings[0].maxFramerate 已设置，这里通过H264参数控制
        
        // ✅ 应用参数
        sender.parameters = params
        
        // 🔍 验证参数是否设置成功
        let verifyParams = sender.parameters
        if let encoding = verifyParams.encodings.first {
            let verifyMin = encoding.minBitrateBps?.intValue ?? 0
            let verifyMax = encoding.maxBitrateBps?.intValue ?? 0
            let verifyFps = encoding.maxFramerate?.intValue ?? 0
            let verifyScale = encoding.scaleResolutionDownBy?.doubleValue ?? 1.0
            let targetFps = frameThrottler?.targetSendFps ?? targetOutputFPS
            let outputWidth = Int(Double(fixedCaptureWidth) / currentResolutionScale)
            let outputHeight = Int(Double(fixedCaptureHeight) / currentResolutionScale)
            let actualOutputWidth = Int(Double(fixedCaptureWidth) / verifyScale)
            let actualOutputHeight = Int(Double(fixedCaptureHeight) / verifyScale)
            let maxPushFpsLimit = getMaxPushFpsForCurrentProfile()
            print("🔒 VBR码率设置: 最大=\(kbps)kbps, 范围=\(minBps/1000)-\(maxBps/1000)kbps (下浮30%)")
            print("   FPS设置: 推送目标=\(targetFps)fps, 上限=\(maxPushFpsLimit)fps → WebRTC=\(verifyFps)fps")
            print("   分辨率: 期望=\(outputWidth)x\(outputHeight)(scale=\(currentResolutionScale)), 实际=\(actualOutputWidth)x\(actualOutputHeight)(scale=\(verifyScale))")
            if abs(verifyScale - currentResolutionScale) > 0.01 {
                print("   ⚠️ 警告: scaleResolutionDownBy 未生效! 期望=\(currentResolutionScale), 实际=\(verifyScale)")
            }
        }
        
        // 🔄 启动周期性强制码率（每3秒重新设置一次，对抗WebRTC内部调整）
        startBitrateEnforcement()
    }
    
    // MARK: - 分辨率缩放（热切换，不断流）
    /// 设置输出分辨率缩放比例
    /// - Parameter scale: 缩放比例，1.0=原始分辨率，1.5=缩小到2/3
    /// - 1920/1280 = 1.5，所以 scale=1.5 时输出 1280x720
    func setResolutionScale(_ scale: Double) {
        let oldScale = currentResolutionScale
        currentResolutionScale = max(1.0, scale)  // 最小为 1.0（不放大）
        
        guard let sender = videoSender else {
            print("⚠️ [setResolutionScale] videoSender 为空，scale=\(scale) 已保存")
            return
        }
        
        var params = sender.parameters
        if params.encodings.isEmpty {
            params.encodings = [RTCRtpEncodingParameters()]
        }
        
        params.encodings[0].scaleResolutionDownBy = NSNumber(value: currentResolutionScale)
        sender.parameters = params
        
        // 🔍 验证设置是否成功
        let verifyParams = sender.parameters
        let verifyScale = verifyParams.encodings.first?.scaleResolutionDownBy?.doubleValue ?? 0
        
        // 🔥🔥 全系 16:9 采集（1920x1080）
        let outputWidth = Int(Double(fixedCaptureWidth) / currentResolutionScale)
        let outputHeight = Int(Double(fixedCaptureHeight) / currentResolutionScale)
        print("📐 [分辨率热切换] scale: \(oldScale) → \(currentResolutionScale)")
        print("   采集: \(fixedCaptureWidth)x\(fixedCaptureHeight) → 期望输出: \(outputWidth)x\(outputHeight)")
        print("   验证: scaleResolutionDownBy 设置=\(currentResolutionScale), 实际=\(verifyScale)")
        if abs(verifyScale - currentResolutionScale) > 0.01 {
            print("   ⚠️ 警告: scaleResolutionDownBy 设置可能未生效!")
        }
    }
    
    /// 根据档位计算分辨率缩放比例
    func getResolutionScaleForProfile(_ profile: LadderProfile) -> Double {
        guard let preset = currentLadder[profile] else { return 1.0 }
        
        // 🔥🔥 全系 16:9 采集（1920x1080），缩放到目标分辨率
        // 4K: scale=1 (1920x1080)
        // 超清: scale=1.5 (1280x720)
        // 高清: scale=2 (960x540)
        // 标清: scale=3 (640x360)
        let scale = Double(fixedCaptureWidth) / Double(preset.width)
        return max(1.0, scale)
    }
    
    /// 🔥 根据当前档位获取最高推送FPS（直接使用 LadderPreset.maxPushFps）
    /// - 4K (scale=1): 最高 60fps
    /// - 超清 (scale=1.5): 最高 60fps  
    /// - 高清 (scale=2): 最高 80fps
    /// - 标清 (scale=4): 最高 120fps
    func getMaxPushFpsForCurrentProfile() -> Int {
        guard let preset = currentLadder[currentProfile] else { return 60 }
        return preset.maxPushFps
    }
    
    /// 根据指定档位获取最高推送FPS
    func getMaxPushFpsForProfile(_ profile: LadderProfile) -> Int {
        guard let preset = currentLadder[profile] else { return 60 }
        return preset.maxPushFps
    }
    
    // 🔥 立即强制码率（用于分辨率切换时立即生效）
    private func enforceBitrateImmediately() {
        guard let sender = videoSender else { return }
        
        var params = sender.parameters
        if params.encodings.isEmpty { return }
        
        // 🔥 VBR策略：码率可下浮，但不能超过最大值
        let maxBps = targetBitrateKbps * 1000  // 最大码率（硬上限）
        let minBps = Int(Double(maxBps) * 0.7)  // 允许下浮30%
        
        // 立即强制设置码率
        params.encodings[0].minBitrateBps = NSNumber(value: minBps)
        params.encodings[0].maxBitrateBps = NSNumber(value: maxBps)
        params.encodings[0].isActive = true
        
        // 🔥 WebRTC推送FPS = targetOutputFPS（已经是 fps/2 后的值）
        let targetFps = frameThrottler?.targetSendFps ?? targetOutputFPS
        let maxPushFps = getMaxPushFpsForCurrentProfile()
        let webrtcFps = min(maxPushFps, targetFps)  // 直接使用，不再 /2
        params.encodings[0].maxFramerate = NSNumber(value: webrtcFps)
        
        // 🔥 设置网络优先级为最高
        params.encodings[0].networkPriority = .high
        
        // 🔥 使用当前分辨率缩放比例
        params.encodings[0].scaleResolutionDownBy = NSNumber(value: currentResolutionScale)
        
        sender.parameters = params
        
        // 🔥 连续设置两次，确保立即生效（WebRTC有时需要多次设置才能立即响应）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, let sender = self.videoSender else { return }
            var params2 = sender.parameters
            if params2.encodings.isEmpty { return }
            
            // 🔥 VBR策略：码率可下浮，但不能超过最大值
            let maxBps2 = self.targetBitrateKbps * 1000  // 最大码率（硬上限）
            let minBps2 = Int(Double(maxBps2) * 0.7)  // 允许下浮30%
            
            params2.encodings[0].minBitrateBps = NSNumber(value: minBps2)
            params2.encodings[0].maxBitrateBps = NSNumber(value: maxBps2)
            params2.encodings[0].isActive = true
            
            // 🔥 WebRTC推送FPS = targetOutputFPS（已经是 fps/2 后的值）
            let targetFps2 = self.frameThrottler?.targetSendFps ?? self.targetOutputFPS
            let maxPushFps2 = self.getMaxPushFpsForCurrentProfile()
            let webrtcFps2 = min(maxPushFps2, targetFps2)  // 直接使用，不再 /2
            params2.encodings[0].maxFramerate = NSNumber(value: webrtcFps2)
            
            params2.encodings[0].networkPriority = .high
            params2.encodings[0].scaleResolutionDownBy = NSNumber(value: self.currentResolutionScale)
            sender.parameters = params2
            
            let outputWidth = Int(Double(self.fixedCaptureWidth) / self.currentResolutionScale)
            let outputHeight = Int(Double(self.fixedCaptureHeight) / self.currentResolutionScale)
            print("✅ VBR码率已设置: \(minBps2/1000)-\(maxBps2/1000)kbps (最大不超maxKbps), WebRTC=\(webrtcFps2)fps, 输出=\(outputWidth)x\(outputHeight)")
        }
    }
    
    // 🔄 周期性强制码率，对抗WebRTC自动调整
    private func startBitrateEnforcement() {
        bitrateEnforceTimer?.invalidate()
        bitrateEnforceTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self, let sender = self.videoSender else { return }
            
            var params = sender.parameters
            if params.encodings.isEmpty { return }
            
            // 🔥 VBR策略：码率可下浮，但不能超过最大值
            let maxBps = self.targetBitrateKbps * 1000  // 最大码率（硬上限）
            let minBps = Int(Double(maxBps) * 0.7)  // 允许下浮30%
            
            let currentMin = params.encodings[0].minBitrateBps?.intValue ?? 0
            let currentMax = params.encodings[0].maxBitrateBps?.intValue ?? 0
            
            // 如果参数被改变，重新强制设置VBR范围（确保不超过maxKbps）
            if currentMin != minBps || currentMax != maxBps {
                //print("🔄 检测到码率参数被修改，重新强制设置VBR：")
                //print("   当前: min=\(currentMin/1000)kbps, max=\(currentMax/1000)kbps")
                //print("   强制: min=\(minBps/1000)kbps, max=\(maxBps/1000)kbps")
                
                params.encodings[0].minBitrateBps = NSNumber(value: minBps)
                params.encodings[0].maxBitrateBps = NSNumber(value: maxBps)
                params.encodings[0].isActive = true
                sender.parameters = params
            }
        }
    }
    
    // 停止强制码率
    private func stopBitrateEnforcement() {
        bitrateEnforceTimer?.invalidate()
        bitrateEnforceTimer = nil
    }
    
    // MARK: - 关键帧控制（减少卡顿恢复时间）
    
    /// 启动关键帧定时器：每隔 keyframeIntervalSec 秒强制发送一个关键帧
    private func startKeyframeTimer() {
        stopKeyframeTimer()
        keyframeTimer = Timer.scheduledTimer(withTimeInterval: keyframeIntervalSec, repeats: true) { [weak self] _ in
            // 🔥 使用两种方式触发关键帧，提高成功率
            self?.forceKeyframe()
            self?.requestKeyframeFromSource()
        }
       // print("🔑 [关键帧] 定时器已启动，每 \(keyframeIntervalSec) 秒发送一个关键帧")
    }
    
    /// 停止关键帧定时器
    private func stopKeyframeTimer() {
        keyframeTimer?.invalidate()
        keyframeTimer = nil
    }
    
    /// 强制发送关键帧（通过临时改变码率触发编码器重置）
    func forceKeyframe() {
        guard let sender = videoSender else {
            //print("⚠️ [关键帧] videoSender 为空，无法发送关键帧")
            return
        }
        
        var params = sender.parameters
        if params.encodings.isEmpty {
            //print("⚠️ [关键帧] encodings 为空，无法发送关键帧")
            return
        }
        
        // 🔥 方法：临时将 scaleResolutionDownBy 改变，触发编码器重新配置
        // 编码器重新配置时会自动发送关键帧（IDR帧）
        let originalScale = params.encodings[0].scaleResolutionDownBy?.doubleValue ?? 1.0
        let tempScale = originalScale + 0.001  // 微小改变
        
        // 第一步：改变 scale
        params.encodings[0].scaleResolutionDownBy = NSNumber(value: tempScale)
        sender.parameters = params
        
        // 第二步：立即恢复原值（触发两次编码器配置变化）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self, let sender = self.videoSender else { return }
            var params2 = sender.parameters
            if !params2.encodings.isEmpty {
                params2.encodings[0].scaleResolutionDownBy = NSNumber(value: originalScale)
                sender.parameters = params2
            }
        }
        
       // print("🔑 [关键帧] 已触发发送关键帧（scale: \(originalScale) → \(tempScale) → \(originalScale)）✅")
    }
    
    /// 通过 videoSource 请求关键帧（更直接的方式）
    func requestKeyframeFromSource() {
        // 🔥 通过触发 adaptOutputFormat 来请求关键帧
        guard let source = videoSource else {
            //print("⚠️ [关键帧] videoSource 为空")
            return
        }
        
        // 获取当前输出尺寸
        let outputWidth = Int(Double(fixedCaptureWidth) / currentResolutionScale)
        let outputHeight = Int(Double(fixedCaptureHeight) / currentResolutionScale)
        let fps = frameThrottler?.targetSendFps ?? 60
        
        // 调用 adaptOutputFormat 会触发编码器重新配置
        source.adaptOutputFormat(toWidth: Int32(outputWidth), height: Int32(outputHeight), fps: Int32(fps))
        
       // print("🔑 [关键帧] 通过 adaptOutputFormat 请求关键帧 (\(outputWidth)x\(outputHeight)@\(fps)fps) ✅")
    }

    func recapture(width: Int, height: Int, fps: Int) {
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
        
        // 🔥 固定采集 1920×1080（通过 scaleResolutionDownBy 缩放输出）
        let targetWidth = fixedCaptureWidth
        let targetHeight = fixedCaptureHeight
        
        // 🔥 打印当前档位和摄像头信息
        print("🔄 [recapture] 固定采集=\(targetWidth)x\(targetHeight), 摄像头=\(dev.position == .back ? "后置" : "前置")")
        print("   ⚠️ 注意：只重启摄像头采集，不停止WebRTC推流连接 (isPublishing=\(isPublishing))")

        let allFormats = RTCCameraVideoCapturer.supportedFormats(for: dev)
        
        // 🔥 优先选择支持 60fps 的格式
        let matchingFormats = allFormats.filter { fmt in
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let w = Int(dims.width)
            let h = Int(dims.height)
            return (w == targetWidth && h == targetHeight) || (w == targetHeight && h == targetWidth)
        }
        
        let highFpsFormats = matchingFormats.filter { fmt in
            let maxFps = Int(fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            return maxFps >= 60
        }
        
        print("   找到\(matchingFormats.count)个匹配格式，其中\(highFpsFormats.count)个支持60fps+")
        
        let candidateFormats = highFpsFormats.isEmpty ? allFormats : highFpsFormats
        
        // 分辨率优先：先选最接近目标的，分辨率相同时选最高FPS的
        guard let best = candidateFormats.sorted(by: { f0, f1 in
            let a = CMVideoFormatDescriptionGetDimensions(f0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions(f1.formatDescription)
            let d0 = abs(Int(a.width) - targetWidth) + abs(Int(a.height) - targetHeight)
            let d1 = abs(Int(b.width) - targetWidth) + abs(Int(b.height) - targetHeight)
            if d0 != d1 { return d0 < d1 }  // 分辨率更接近的优先
            
            // 分辨率相同时，选最高FPS的
            let max0 = Int(f0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            let max1 = Int(f1.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            return max0 > max1
        }).first else { return }
          
        let maxFps = Int(best.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
        let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
        print("   选中格式: \(dims.width)x\(dims.height) 最大FPS=\(maxFps)")
        
        // 🔍 打印该格式的所有帧率范围
        for (idx, range) in best.videoSupportedFrameRateRanges.enumerated() {
            print("   [\(idx)] \(Int(range.minFrameRate))-\(Int(range.maxFrameRate))fps")
        }

        // ✅ 采集FPS使用设备支持的最大值
           let useFps = maxFps
           currentCaptureFPS = useFps  // 记录采集FPS
           print("🎯 重采集采集FPS=\(useFps) (设备最大FPS, \(dev.position == .back ? "后置" : "前置"))")
           
           // ✅ 确保推送FPS不超过采集FPS
           if let currentSendFps = self.frameThrottler?.targetSendFps, currentSendFps > useFps {
               self.frameThrottler?.targetSendFps = useFps
               //print("⚠️ 推送FPS(\(currentSendFps)) 超过采集FPS(\(useFps))，已限制为\(useFps)fps")
           }

            capturer.stopCapture { [weak self] in
               guard let self else { return }
               
               // 🔥 关键：让 WebRTC SDK 自己设置帧率
               let actualMaxFps = Int(best.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
               let finalFps = min(useFps, actualMaxFps)
               
               if finalFps < useFps {
                   //print("⚠️ 目标FPS \(useFps) 超过格式最大支持FPS \(actualMaxFps)，降低到 \(finalFps)fps")
                   self.currentCaptureFPS = finalFps
               }
               
               // 🔥 先启动采集
               capturer.startCapture(with: dev, format: best, fps: finalFps)
               print("🚀 采集启动(重采): \(dims.width)x\(dims.height) @\(finalFps)fps (16:9)")
               
               // ✅ 延迟配置相机模式，确保 activeFormat 已更新
               DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                   guard let self = self else { return }
                   self.configureCameraAutoModes(dev)
               }
               
               // ✅ 立即应用方向，避免画面旋转（App已强制横屏）
               // 使用延迟确保 session 已启动
               DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                   self?.applyMountTransform()
                   
                   // 🪞 更新预览镜像（前置摄像头需要镜像）
                   self?.updatePreviewMirror(isFrontCamera: dev.position == .front)
                   
                   // ✅ 发送预览成功通知（用于事件驱动自动推流）
                   //print("\n📸📸📸 [WebRTCManager.recapture] 摄像头重采集就绪，准备发送通知...")
                   NotificationCenter.default.post(name: .cameraPreviewReady, object: nil)
                   //print("📸 [WebRTCManager.recapture] cameraPreviewReady 通知已发送✅\n")
                   
                   // 🔥 分辨率切换后立即强制码率，确保码率立即提升到最大值附近
                   self?.enforceBitrateImmediately()
                   
                   // 🔥 切换档位后恢复配置（除对焦外）：变焦、FPS、码率等
                   self?.reapplyConfigExceptFocus()
               }
               
               // 🔥 禁用自动对焦 - 切换档位后保持当前焦距
               print("🔍 [recapture] 不执行自动对焦，保持当前焦距设置")
               
               // 如果有待处理的对焦设置，延迟应用
                       if let focus = self.pendingFocus {
                   DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                       self?.pendingFocus = nil
                       self?.setFocus(focus)
                       print("🔍 [recapture] 应用待处理的焦距: \(focus)")
                   }
               }
           }
        
    }

    // MARK: - 实时统计 + 自适应
    private func startStats() {
        statsTimer?.invalidate()
        adaptTimer?.invalidate()
        lastBytesSent = 0; lastTs = 0
        lastFramesSent = 0; lastPacketsSent = 0
        lastPacketsLost = 0; lastNackCount = 0; lastPliCount = 0
        
        // 🔥 禁用关键帧定时器（通过 scaleResolutionDownBy 触发会导致画面抖动）
        // 依赖 WebRTC 内置的 PLI/FIR 机制自动请求关键帧
        // startKeyframeTimer()
        badSeconds = 0; goodSeconds = 0
        kbpsHistory.removeAll()  // ✅ 重置码率历史
        fpsHistory.removeAll()    // ✅ 重置FPS历史

        // 每秒抓一次 stats
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self, let pc = self.pc else { return }
                pc.statistics { report in
                    var bytesTotal: UInt64 = 0
                    var fpsNow: Int = 0
                    var framesSentTotal: UInt64 = 0
                    var qlr: String? = nil
                    
                    // ✅ 网络质量指标
                    var packetsSent: UInt64 = 0
                    var packetsLost: UInt64 = 0
                    var roundTripTime: Double = 0.0  // RTT (秒)
                    var jitter: Double = 0.0
                    
                    // 🔥 重传机制统计（NACK 和 PLI）
                    var nackCount: UInt64 = 0      // NACK 请求次数（接收端请求重传）
                    var pliCount: UInt64 = 0       // PLI 请求次数（请求关键帧）
                    var retransmittedPacketsSent: UInt64 = 0  // 重传包数量

                    for s in report.statistics.values {

                           #if DEBUG
                            if s.type.contains("rtp") || s.type == "track" {
                               // print("📊 统计类型: \(s.type) | 字段: \(s.values.keys.sorted())")
                            }
                           #endif
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
                            // ✅ 提取包统计（用于网络质量评估）
                            if let v = s.values["packetsSent"] {
                                if let num = v as? NSNumber { packetsSent = num.uint64Value }
                                else if let d = v as? Double { packetsSent = UInt64(d) }
                                else if let i = v as? Int { packetsSent = UInt64(i) }
                            }
                            // 🔥 提取 NACK 统计（重传机制）
                            if let v = s.values["nackCount"] {
                                if let num = v as? NSNumber { nackCount = num.uint64Value }
                                else if let d = v as? Double { nackCount = UInt64(d) }
                                else if let i = v as? Int { nackCount = UInt64(i) }
                            }
                            // 🔥 提取 PLI 统计（关键帧请求）
                            if let v = s.values["pliCount"] {
                                if let num = v as? NSNumber { pliCount = num.uint64Value }
                                else if let d = v as? Double { pliCount = UInt64(d) }
                                else if let i = v as? Int { pliCount = UInt64(i) }
                            }
                            // 🔥 提取重传包统计
                            if let v = s.values["retransmittedPacketsSent"] {
                                if let num = v as? NSNumber { retransmittedPacketsSent = num.uint64Value }
                                else if let d = v as? Double { retransmittedPacketsSent = UInt64(d) }
                                else if let i = v as? Int { retransmittedPacketsSent = UInt64(i) }
                            }
                            if let r = s.values["qualityLimitationReason"] as? String { qlr = r }
                        } else if type == "remote-inbound-rtp" && isVideo {
                            // ✅ 远端入站统计：包含丢包、RTT、抖动
                            if let v = s.values["packetsLost"] {
                                if let num = v as? NSNumber { packetsLost = num.uint64Value }
                                else if let d = v as? Double { packetsLost = UInt64(d) }
                                else if let i = v as? Int { packetsLost = UInt64(i) }
                            }
                            if let v = s.values["roundTripTime"] {
                                if let num = v as? NSNumber { roundTripTime = num.doubleValue }
                                else if let d = v as? Double { roundTripTime = d }
                            }
                            if let v = s.values["jitter"] {
                                if let num = v as? NSNumber { jitter = num.doubleValue }
                                else if let d = v as? Double { jitter = d }
                            }
                        } else if type == "track" && isVideo {
                            if let r = s.values["qualityLimitationReason"] as? String { qlr = r }
                        }
                    }
                    DispatchQueue.main.async {
                        let now = CFAbsoluteTimeGetCurrent()
                        defer {
                            self.lastBytesSent = bytesTotal
                            self.lastFramesSent = framesSentTotal
                            self.lastPacketsSent = packetsSent
                            self.lastPacketsLost = packetsLost
                            self.lastNackCount = nackCount
                            self.lastPliCount = pliCount
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
                        // ✅ FPS平滑处理：使用移动平均，减少瞬时波动（0-60跳动）
                        var instantFps: Int = fpsNow
                        if fpsNow == 0, self.lastTs > 0, framesSentTotal >= self.lastFramesSent {
                            // WebRTC没有报告framesPerSecond时，使用framesSent差值计算
                            let dt = now - self.lastTs
                            let dFrames = framesSentTotal &- self.lastFramesSent
                            instantFps = Int(Double(dFrames) / max(dt, 0.001))
                        }
                        
                        // 只有在有效值时才加入历史（过滤掉异常的0值）
                        if instantFps > 0 {
                            self.fpsHistory.append(instantFps)
                            if self.fpsHistory.count > self.fpsHistorySize {
                                self.fpsHistory.removeFirst()
                            }
                        }
                        
                        // 使用移动平均值
                        if !self.fpsHistory.isEmpty {
                            self.currentFps = self.fpsHistory.reduce(0, +) / self.fpsHistory.count
                        } else {
                            self.currentFps = instantFps
                        }
                        
                        // ✅ 推送给后端的FPS统计
                        WebSocketManager.publishingFps = self.currentCaptureFps  // 采集FPS
                        WebSocketManager.publishingSendFps = self.currentFps     // WebRTC实际推送FPS（从stats获取）
                        
                        // 🔥 对比本地统计和WebRTC实际发送帧率
                        let localSendFps = self.currentSendFps  // 本地节流器统计
                        let webrtcSendFps = self.currentFps     // WebRTC实际推送
                        let targetFps = self.frameThrottler?.targetSendFps ?? self.targetOutputFPS
                        let captureFps = self.currentCaptureFps // 采集FPS
                        
                        // 🔥 计算UDP包速率（包/秒）
                        var packetsPerSecond = 0
                        if self.lastTs > 0, packetsSent >= self.lastPacketsSent {
                            let dt = now - self.lastTs
                            let dPackets = packetsSent &- self.lastPacketsSent
                            packetsPerSecond = Int(Double(dPackets) / max(dt, 0.001))
                        }
                        
                        // 🔥 每秒打印 FPS 链路详情（诊断不稳定问题）
                        let shutter = 90 + Int(Double(self.cjfpsPercentage) * 1.5)
                        print("🔍 [FPS链路] 快门=1/\(shutter)s 采集=\(captureFps) → 节流目标=\(targetFps) → 本地推送=\(localSendFps) → WebRTC实际=\(webrtcSendFps)")
                        
                        // 🔥 检测编码器质量限制（可能导致卡顿的原因）
                        if let qlrReason = qlr, qlrReason != "none" {
                            print("⚠️ [编码器限制] 原因=\(qlrReason) - 可能导致卡顿")
                            // qualityLimitationReason 可能的值：
                            // - "none": 无限制
                            // - "cpu": CPU 负载过高
                            // - "bandwidth": 带宽不足
                            // - "other": 其他原因
                        }
                        
                        // 🔥 计算每秒丢包数和重传统计
                        var packetsLostPerSec = 0
                        var nackPerSec = 0
                        var pliPerSec = 0
                        if self.lastTs > 0 {
                            packetsLostPerSec = Int(packetsLost &- self.lastPacketsLost)
                            nackPerSec = Int(nackCount &- self.lastNackCount)
                            pliPerSec = Int(pliCount &- self.lastPliCount)
                        }
                        
                        // 🔥 如果有丢包或重传，打印警告
                        if packetsLostPerSec > 0 || nackPerSec > 0 || pliPerSec > 0 {
                            print("⚠️ [丢包/重传] 丢包=\(packetsLostPerSec)个/秒, NACK请求=\(nackPerSec)次, PLI请求=\(pliPerSec)次, 累计重传=\(retransmittedPacketsSent)包")
                        }
                        
                        // 🔥 每5秒打印一次详细统计
                        if Int(now) % 5 == 0 {
                            let packetsPerFrame = webrtcSendFps > 0 ? Double(packetsPerSecond) / Double(webrtcSendFps) : 0
                            print("📊 [WebRTC统计] 视频帧率=\(webrtcSendFps)fps, UDP包速率=\(packetsPerSecond)包/秒, 平均每帧=\(String(format: "%.1f", packetsPerFrame))个UDP包")
                            print("📊 [重传机制] NACK累计=\(nackCount)次, PLI累计=\(pliCount)次, 重传包=\(retransmittedPacketsSent)个, 累计丢包=\(packetsLost)个")
                        }
                        
                        // 🔥 WebRTC 实际帧率应该接近本地节流推送帧率
                        let expectedWebrtcFps = localSendFps
                        if abs(webrtcSendFps - expectedWebrtcFps) > 10 {
                            print("⚠️ 帧率异常: WebRTC实际=\(webrtcSendFps)fps, 期望≈\(expectedWebrtcFps)fps（节流目标\(targetFps)）")
                        }
                        
                        // ✅ 计算网络质量
                        let packetLossRate = packetsSent > 0 ? Double(packetsLost) / Double(packetsSent + packetsLost) : 0.0
                        let rttMs = Int(roundTripTime * 1000.0)  // 转换为毫秒
                        
                        // 综合评估网络质量等级
                        let quality: String
                        if packetLossRate <= 0.01 && rttMs <= 100 {
                            quality = "excellent"  // 优秀: 丢包≤1%, RTT≤100ms
                        } else if packetLossRate <= 0.03 && rttMs <= 200 {
                            quality = "good"  // 良好: 丢包≤3%, RTT≤200ms
                        } else if packetLossRate <= 0.05 && rttMs <= 400 {
                            quality = "fair"  // 一般: 丢包≤5%, RTT≤400ms
                        } else if packetLossRate > 0.05 || rttMs > 400 {
                            quality = "poor"  // 差: 丢包>5% 或 RTT>400ms
                        } else {
                            quality = "unknown"  // 未知: 无法获取指标
                        }
                        
                        // 更新到WebSocketManager
                        WebSocketManager.networkQuality = quality
                        WebSocketManager.packetLoss = packetLossRate
                        WebSocketManager.rtt = rttMs
                        
                        // 🔍 详细的码率监控日志（包括编码器参数验证）
                        if let preset = self.currentLadder[self.currentProfile] {
                            let targetKbps = preset.maxKbps
                            let actualKbps = self.currentKbps
                            let percentage = Int((Double(actualKbps) / Double(targetKbps)) * 100)
                            let qlrStr = qlr ?? "none"
                            
                            // ✅ 验证编码器参数是否被修改
                            var encoderInfo = ""
                            if let sender = self.videoSender,
                               let encoding = sender.parameters.encodings.first {
                                let encMin = encoding.minBitrateBps?.intValue ?? 0
                                let encMax = encoding.maxBitrateBps?.intValue ?? 0
                                encoderInfo = " | 编码器: min=\(encMin/1000)k max=\(encMax/1000)k"
                                
                                // ⚠️ 警告：如果编码器参数不是目标值，说明被WebRTC内部修改了
                                if encMin != self.targetBitrateKbps * 1000 || encMax != self.targetBitrateKbps * 1000 {
                                    encoderInfo += " ⚠️被修改"
                                }
                            }
                            
                            /*
                            print("📊 码率监控: \(actualKbps)/\(targetKbps) kbps (\(percentage)%) | FPS: \(self.currentFps) | QLR: \(qlrStr)\(encoderInfo)")
                            print("🌐 网络质量: \(quality) | 丢包率: \(String(format: "%.2f%%", packetLossRate * 100)) | RTT: \(rttMs)ms | 抖动: \(String(format: "%.2f", jitter * 1000))ms")*/
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
                //print("⬇️ 降档：\(currentProfile) → \(down)  (badSeconds=\(badSeconds))")
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
                    //print("📉 低档降帧：\(preset.width)x\(preset.height) @\(targetFps)fps")
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
        
        // 🔥 打印请求详情
        //print("\n========================================")
        //print("📤 向 SRS 发送 Offer:")
        //print("   URL: \(url)")
        //print("   streamurl: \(streamurl)")
        //print("   SDP 长度: \(offer.count) 字符")
        //print("========================================")
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        
        // 🔥 打印 HTTP 响应状态
        if let httpResponse = response as? HTTPURLResponse {
            //print("📥 SRS 响应：HTTP \(httpResponse.statusCode)")
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        
        // 🔥 打印完整的 SRS 响应
        //print("📥 SRS 响应内容：")
        if let jsonData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
        }
        
        if let code = json["code"] as? Int, code != 0 {
            // 🔥 获取详细错误信息
            let msg = json["msg"] as? String ?? "未知错误"
            let server = json["server"] as? String ?? "未知"
            
            //print("❌ SRS 返回错误：")
            //print("   code: \(code)")
            //print("   msg: \(msg)")
            //print("   server: \(server)")
            //print("========================================\n")
            
            throw NSError(domain: "srs", code: code, userInfo: [
                NSLocalizedDescriptionKey: "SRS code=\(code), msg: \(msg)"
            ])
        }
        
        guard let sdp = json["sdp"] as? String else {
            //print("❌ SRS 响应中没有 sdp 字段")
            //print("========================================\n")
            throw NSError(domain: "srs", code: -1, userInfo: [NSLocalizedDescriptionKey: "no sdp in response"])
        }
        
        //print("✅ 成功获取 SRS Answer SDP")
        //print("========================================\n")
        return sdp
    }
    
    // MARK: - 删除 SRS 流（重试前调用，清理旧流，失败也忽略）
    func deleteStream(streamKey: String) {
        let streamUrl = "webrtc://\(srsIP)/\(app)/\(streamKey)"
        guard let url = URL(string: "http://\(srsIP):1985/rtc/v1/unpublish/") else {
            print("❌ [deleteStream] URL 无效")
            return
        }
        
        print("🗑️ [deleteStream] 删除旧流: \(streamKey)")
        
        let body: [String: Any] = [
            "api": "http://\(srsIP):1985/rtc/v1/unpublish/",
            "streamurl": streamUrl
        ]
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        // 异步调用，不等待结果
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                print("🗑️ [deleteStream] 请求失败（忽略）: \(error.localizedDescription)")
            } else if let httpResponse = response as? HTTPURLResponse {
                print("🗑️ [deleteStream] 响应: HTTP \(httpResponse.statusCode)（忽略成功与否）")
            }
        }.resume()
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

    // 🔥 ICE 连接状态变化（重要！这里监听断线等）
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCIceConnectionState) {
        DispatchQueue.main.async {
            switch newState {
            case .new:
                print("🔵 ICE Connection: New")
            case .checking:
                print("🔵 ICE Connection: Checking...")
            case .connected:
                print("✅ ICE Connection: Connected")
            case .completed:
                print("✅ ICE Connection: Completed")
            case .failed:
                print("❌ ICE Connection: Failed")
                // ICE 连接失败，停止推流
                if self.isPublishing {
                    print("⚠️ ICE 连接失败，停止推流")
                    self.stopPublish()
                }
            case .disconnected:
                print("⚠️ ICE Connection: Disconnected")
                // 断开连接，停止推流
                if self.isPublishing {
                    print("⚠️ ICE 断开，停止推流")
                    self.stopPublish()
                }
            case .closed:
                print("🔴 ICE Connection: Closed")
            case .count:
                break
            @unknown default:
                print("⚠️ ICE Connection: Unknown state")
            }
        }
    }

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

    // 🔥 整体连接状态变化（综合状态）
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange state: RTCPeerConnectionState) {
        DispatchQueue.main.async {
            switch state {
            case .new:
                print("🔵 PeerConnection State: New")
            case .connecting:
                print("🔵 PeerConnection State: Connecting...")
            case .connected:
                print("✅ PeerConnection State: Connected")
            case .disconnected:
                print("⚠️ PeerConnection State: Disconnected")
                // 连接断开，停止推流
                if self.isPublishing {
                    print("⚠️ PeerConnection 断开，停止推流")
                    self.stopPublish()
                }
            case .failed:
                //print("❌ PeerConnection State: Failed")
                // 连接失败，停止推流
                if self.isPublishing {
                    //print("❌ PeerConnection 失败，停止推流")
                    self.stopPublish()
                }
            case .closed:
                print("🔴 PeerConnection State: Closed")
            @unknown default:
                print("⚠️ PeerConnection State: Unknown")
            }
        }
    }
}

// MARK: - 通知扩展
extension Notification.Name {
    static let cameraPreviewReady = Notification.Name("cameraPreviewReady")
    static let publishFailed = Notification.Name("publishFailed")
}


