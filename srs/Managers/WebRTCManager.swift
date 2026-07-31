//
//  WebRTCManager.swift
//  金凤凰
//
//  Created by 陈源 on 10/3/25.
//

import Foundation
import WebRTC
import AVFoundation
import CoreMedia
import UIKit
import CoreImage
import Metal

// MARK: - iPhone型号检测（iPhone 15+ 48MP新架构需要 1080p 采集）
// iPhone15,4/5 = iPhone 15 / 15 Plus (majorVersion=15, minorVersion>=4)
// iPhone16,1/2 = iPhone 15 Pro / Pro Max (majorVersion=16)
// iPhone17,x   = iPhone 16 系列 (majorVersion=17)
// iPhone15,2/3 = iPhone 14 Pro / Pro Max (majorVersion=15, minorVersion<=3) → 不包含
fileprivate func isIPhone15OrNewer() -> Bool {
    var systemInfo = utsname()
    uname(&systemInfo)
    let machine = withUnsafePointer(to: &systemInfo.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) {
            String(validatingUTF8: $0)
        }
    }
    guard let identifier = machine else { return false }
    
    if identifier.hasPrefix("iPhone") {
        let numPart = identifier.dropFirst(6) // 去掉 "iPhone"
        if let commaIndex = numPart.firstIndex(of: ","),
           let majorVersion = Int(numPart[..<commaIndex]) {
            // iPhone 15 Pro+ = iPhone16,x → majorVersion >= 16
            if majorVersion >= 16 { return true }
            // iPhone 15 / 15 Plus = iPhone15,4 / iPhone15,5
            // iPhone 14 Pro = iPhone15,2 / iPhone15,3 → 不包含
            if majorVersion == 15 {
                let minorPart = numPart[numPart.index(after: commaIndex)...]
                if let minorVersion = Int(minorPart) {
                    return minorVersion >= 4  // iPhone15,4+ = iPhone 15 系列
                }
            }
        }
    }
    return false
}

// MARK: - Array安全下标扩展
extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// MARK: - ⭐ 视频滤镜管道 (单个 Metal CIColorKernel — GPU 统一处理)
//
// v3 重构 (解决发热 + 黑色变灰):
//   v2 用 3 个独立 CIFilter 串联 (CIColorControls + CIColorMatrix + CISharpenLuminance),
//   每帧 3 次 GPU dispatch + ISP 上下文切换, 是发热大头.
//   v3 把所有色彩运算合到 1 个 CIColorKernel, 单 pass 完成:
//
//     0. exposure    — 曝光乘法 (rgb × 2^EV, 把传感器伪黑乘出来变成可见暗部)
//     1. blackPoint  — 黑场压死 (减后归一化, 真正黑色归 0, 不会变灰)
//     2. brightness  — 中调亮度曲线 (保端点不会让黑变灰, 只弯中调)
//     3. gamma       — pow 曲线 (保端点, 对暗部敏感, ♠♣ 花纹更清晰)
//     4. saturation  — Rec.601 luma 加权混合
//     5. contrast    — 绕中点 0.5 拉
//     6. redGlow     — 选择性红色发光 (仅 R 高且 G/B 低的纯红区域非线性推向 1.0)
//     7. highlightLift — 高光提亮 (>0.7 区域非线性推向 1.0, 白色更白)
//
//   锐化已移除 — 卷积 9 采样开销最贵, ISP 自带 edge enhancement 已够用.
//   旧字段 sharpness 保留为 @Published 仅为兼容服务端推送, kernel 不读取.
//
// 兼容:
//   - UserDefaults key 不变, UI 滑块继续可绑定
//   - 服务端 filterSharpness 推下来不会报错, 只是不生效
//   - 服务端 filterRedBoost 推下来转作 redGlow 强度
final class VideoFilterPipeline: ObservableObject {

    // ===== 实际生效参数（kernel 读取）=====

    /// 黑场压死: 输入像素先减去 blackPoint 再归一化, 把暗部彻底推到 0
    /// 0 = 不动, 0.10 = 暗部下沉 10% (压死 H.264 limited-range 的 16/255≈6% 伪黑)
    /// 默认 0.10 是为了对抗 limited-range YUV 编码的"黑色 = 0.063 灰" 现象,
    /// 让 ♠♣ 黑牌真正黑下去, 不再灰蒙蒙. 对中调影响极小 (<0.5% 失真).
    @Published var blackPoint: Float = VideoFilterPipeline.loadDefault(.blackPoint, fallback: 0.0) {
        didSet { saveDefault(.blackPoint, blackPoint); if oldValue != blackPoint { logChange("blackPoint", blackPoint) } }
    }
    /// 中调亮度: 保端点曲线 rgb + b·rgb·(1-rgb), -1..+1
    /// 0 = 不变, 0.05 = 中调微提, 0.30 = 中调显著提亮
    /// 黑场 (rgb=0) 和高光 (rgb=1) 都不受影响, 拖动不会把黑变灰
    @Published var brightness: Float = VideoFilterPipeline.loadDefault(.brightness, fallback: 0.0) {
        didSet { saveDefault(.brightness, brightness); if oldValue != brightness { logChange("brightness", brightness) } }
    }
    /// 曝光: rgb × 2^EV, -3..+3 stops, 乘法增益. 默认 0.15 提亮中间调（对标看家宝双层亮度）
    @Published var exposure: Float = VideoFilterPipeline.loadDefault(.exposure, fallback: 0.0) {
        didSet { saveDefault(.exposure, exposure); if oldValue != exposure { logChange("exposure", exposure) } }
    }
    /// 伽马: pow 曲线 rgb' = rgb^(1/gamma), 0.5..2.0, 保端点
    @Published var gamma: Float = VideoFilterPipeline.loadDefault(.gamma, fallback: 1.0) {
        didSet { saveDefault(.gamma, gamma); if oldValue != gamma { logChange("gamma", gamma) } }
    }
    /// 对比度: 绕 0.5 中点拉
    @Published var contrast: Float = VideoFilterPipeline.loadDefault(.contrast, fallback: 1.0) {
        didSet { saveDefault(.contrast, contrast); if oldValue != contrast { logChange("contrast", contrast) } }
    }
    /// 饱和度: Rec.601 luma 混合
    @Published var saturation: Float = VideoFilterPipeline.loadDefault(.saturation, fallback: 1.0) {
        didSet { saveDefault(.saturation, saturation); if oldValue != saturation { logChange("saturation", saturation) } }
    }
    /// ⭐ 红色发光强度: 仅作用于"R 高且 G/B 低"的纯红像素 (♥♦)
    @Published var redGlow: Float = VideoFilterPipeline.loadDefault(.redGlow, fallback: 0.0) {
        didSet { saveDefault(.redGlow, redGlow); if oldValue != redGlow { logChange("redGlow", redGlow) } }
    }
    /// 玉麒麟 pixel_level: -2...8，采集后像素亮度等级（不是相机 ISO/EV）
    @Published var pixelLevel: Float = VideoFilterPipeline.loadDefault(.pixelLevel, fallback: 0.0) {
        didSet { saveDefault(.pixelLevel, pixelLevel); if oldValue != pixelLevel { logChange("pixelLevel", pixelLevel) } }
    }

    /// 高光提亮: > 0.7 的像素非线性推向 1.0
    @Published var highlightLift: Float = VideoFilterPipeline.loadDefault(.highlightLift, fallback: 0.0) {
        didSet { saveDefault(.highlightLift, highlightLift); if oldValue != highlightLift { logChange("highlightLift", highlightLift) } }
    }

    /// ⭐ 色度: 黄色拉白（保留红色）, 0.0~1.0
    /// 0 = 不动, 1 = 黄色色相完全中性化（拉成白/灰）。仅作用于黄色色相一段，红色不受影响。
    /// 与"饱和度"是不同维度：饱和度整体缩放 UV，色度只定向去掉黄色。
    @Published var chroma: Float = VideoFilterPipeline.loadDefault(.chroma, fallback: 0.0) {
        didSet { saveDefault(.chroma, chroma); if oldValue != chroma { logChange("chroma", chroma) } }
    }

    // ===== 编码前降噪 + 锐化（对标看家宝 TAA+hqdn3d+sharpen 链路）=====
    /// 降噪强度: 0=关闭, 0.02=轻度(推荐), 0.05=强力. 消除传感器噪点，节省码率
    @Published var noiseLevel: Float = VideoFilterPipeline.loadDefault(.noiseLevel, fallback: 0.0) {
        didSet { saveDefault(.noiseLevel, noiseLevel); if oldValue != noiseLevel { logChange("noiseLevel", noiseLevel) } }
    }
    /// 锐化强度: 0=关闭, 0.4=轻度(推荐), 1.0=强力. 2米远牌面必须锐化
    @Published var sharpenAmount: Float = VideoFilterPipeline.loadDefault(.sharpenAmount, fallback: 0.0) {
        didSet { saveDefault(.sharpenAmount, sharpenAmount); if oldValue != sharpenAmount { logChange("sharpenAmount", sharpenAmount) } }
    }

    // ===== 兼容旧服务端推送字段 (kernel 不读取, 留着不报错) =====
    @Published var sharpness: Float = VideoFilterPipeline.loadDefault(.sharpness, fallback: 0.0) {
        didSet { saveDefault(.sharpness, sharpness) }
    }

    // ⭐ 主开关（仅内存，不持久化）
    @Published var enabled: Bool = true {
        didSet { print("📷 [Filter] enabled=\(enabled)") }
    }

    private enum Key: String {
        case brightness    = "videoFilter.brightness"
        case contrast      = "videoFilter.contrast"
        case saturation    = "videoFilter.saturation"
        case sharpness     = "videoFilter.sharpness"
        case blackPoint    = "videoFilter.blackPoint"
        case redGlow       = "videoFilter.redGlow"
        case highlightLift = "videoFilter.highlightLift"
        case gamma         = "videoFilter.gamma"
        case exposure      = "videoFilter.exposure"
        case pixelLevel    = "videoFilter.pixelLevel"
        case noiseLevel    = "videoFilter.noiseLevel"
        case sharpenAmount = "videoFilter.sharpenAmount"
        case chroma        = "videoFilter.chroma"
    }

    // 滤镜/硬件/LUT 参数不持久化到本地：仅用内存默认值，运行期靠登录下发 + STOMP 覆盖
    private static func loadDefault(_ key: Key, fallback: Float) -> Float {
        return fallback
    }
    private func saveDefault(_ key: Key, _ value: Float) {
        // no-op: 不写 UserDefaults（参数只存内存）
    }
    private func logChange(_ name: String, _ v: Float) {
        print("📷 [Filter] \(name) = \(String(format: "%.3f", v))")
    }

    // ⭐ 一次性批量更新（避免多次 didSet 触发）
    func applyAll(brightness: Float?, contrast: Float?, saturation: Float?,
                  sharpness: Float?, redBoost: Float? = nil,
                  blackPoint: Float? = nil, redGlow: Float? = nil, highlightLift: Float? = nil,
                  gamma: Float? = nil, exposure: Float? = nil, pixelLevel: Float? = nil,
                  chroma: Float? = nil,
                  enabled: Bool? = nil, source: String = "remote") {
        if let v = brightness { self.brightness = v }
        if let v = contrast   { self.contrast   = v }
        if let v = saturation { self.saturation = v }
        if let v = sharpness  { self.sharpness = v; self.sharpenAmount = v }
        if let v = redBoost   { self.redGlow    = v }
        if let v = redGlow    { self.redGlow    = v }
        if let v = blackPoint { self.blackPoint = v }
        if let v = highlightLift { self.highlightLift = v }
        if let v = gamma      { self.gamma      = v }
        if let v = exposure   { self.exposure   = v }
        if let v = pixelLevel { self.pixelLevel = max(-2.0, min(8.0, v)) }
        if let v = chroma     { self.chroma     = max(0.0, min(1.0, v)) }
        if let v = enabled    { self.enabled    = v }
        print("📷 [Filter] 批量应用 (\(source)): enabled=\(self.enabled) passThrough=\(self.isPassThrough) | exposure=\(self.exposure) pixelLevel=\(self.pixelLevel) blackPoint=\(self.blackPoint) brightness=\(self.brightness) gamma=\(self.gamma) contrast=\(self.contrast) saturation=\(self.saturation) redGlow=\(self.redGlow) highlightLift=\(self.highlightLift) chroma=\(self.chroma) noiseLevel=\(self.noiseLevel) sharpenAmount=\(self.sharpenAmount) sharpness=\(self.sharpness)")
    }

    // ===== Metal CIColorKernel: 一次 dispatch 完成所有色彩运算 =====
    private static let kernelSource: String = """
    kernel vec4 cardEnhance(__sample s,
                            float exposure,
                            float pixelLevel,
                            float blackPoint,
                            float brightness,
                            float gamma,
                            float contrast,
                            float saturation,
                            float redGlow,
                            float highlightLift,
                            float chroma) {
        vec3 rgb = s.rgb;

        // 0. 曝光: rgb × 2^EV
        rgb = rgb * exp2(exposure);

        // 1. 玉麒麟 pixel_level: -2...8，主要动中高亮/白场，黑位基本不动
        float px = clamp(pixelLevel, -2.0, 8.0);
        vec3 hiMask = smoothstep(vec3(0.32), vec3(0.92), rgb);
        if (px >= 0.0) {
            float lift = px / 8.0;
            rgb = rgb + lift * 0.70 * hiMask * (1.0 - rgb);
            rgb = mix(rgb, min(rgb * (1.0 + lift * 0.12), vec3(1.0)), hiMask * vec3(0.25));
        } else {
            float down = (-px) / 2.0;
            rgb = rgb - down * 0.55 * hiMask * rgb;
        }
        rgb = clamp(rgb, 0.0, 1.0);

        // 2. 黑场压死
        float bpDenom = max(1.0 - blackPoint, 0.001);
        rgb = max(rgb - vec3(blackPoint), vec3(0.0)) / vec3(bpDenom);

        // 2. 中调亮度 (保端点)
        rgb = rgb + brightness * rgb * (1.0 - rgb);

        // 3. 伽马
        float invGamma = 1.0 / max(gamma, 0.01);
        rgb = pow(max(rgb, vec3(0.0)), vec3(invGamma));

        // 4. 饱和度
        float luma = dot(rgb, vec3(0.299, 0.587, 0.114));
        rgb = mix(vec3(luma), rgb, saturation);

        // 4.5 色度: 黄色拉白 (保留红色)
        //     黄色 = R,G 都高且 B 低 → yellowMask = clamp(min(R,G)-B); 红色 G 低 → mask 自动≈0.
        //     把 B 抬到 min(R,G) 高度即中性化为白/灰, 红色不受影响.
        float minRG = min(rgb.r, rgb.g);
        float yellowMask = clamp(minRG - rgb.b, 0.0, 1.0);
        rgb.b = rgb.b + chroma * yellowMask * (minRG - rgb.b);

        // 5. 对比度
        rgb = (rgb - 0.5) * contrast + 0.5;

        // 6. 红色发光 (仅纯红像素 ♥♦, 阈值降低以覆盖2米远暗红牌面)
        float gbMax = max(rgb.g, rgb.b);
        float redMask = smoothstep(0.15, 0.45, rgb.r) * max(0.0, 1.0 - gbMax);
        rgb.r = rgb.r + redGlow * redMask * (1.0 - rgb.r);

        // 7. 高光提亮
        vec3 highlightMask = smoothstep(vec3(0.7), vec3(1.0), rgb);
        rgb = rgb + highlightLift * highlightMask * (1.0 - rgb);

        rgb = clamp(rgb, 0.0, 1.0);
        return vec4(rgb, s.a);
    }
    """

    private let ciContext: CIContext
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0
    private let cardEnhanceKernel: CIColorKernel?

    init() {
        let device = MTLCreateSystemDefaultDevice()
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.itur_709) as Any,  // BT.709 视频色域，替代 sRGB 避免颜色偏淡
            .cacheIntermediates: false,
            .useSoftwareRenderer: false,
        ]
        if let device = device {
            ciContext = CIContext(mtlDevice: device, options: options)
        } else {
            ciContext = CIContext(options: options)
        }
        cardEnhanceKernel = CIColorKernel(source: VideoFilterPipeline.kernelSource)
        if cardEnhanceKernel == nil {
            print("❌ [Filter] CIColorKernel 编译失败, 滤镜将走直通")
        } else {
            print("✅ [Filter] Metal kernel 已加载 (单 pass GPU 处理)")
        }
    }

    /// 直通条件: 主开关关 / kernel 失败 / 所有参数都中性
    var isPassThrough: Bool {
        if !enabled { return true }
        if cardEnhanceKernel == nil { return true }
        return exposure == 0 && pixelLevel == 0 && blackPoint == 0 && brightness == 0 && gamma == 1.0
            && contrast == 1.0 && saturation == 1.0 && redGlow == 0 && highlightLift == 0
            && chroma == 0 && noiseLevel == 0 && sharpenAmount == 0
    }

    /// 处理一帧, 返回新的 CVPixelBuffer (BGRA) 或 nil (失败/直通时调用方使用原帧)
    func processFrame(_ inputPB: CVPixelBuffer) -> CVPixelBuffer? {
        if isPassThrough { return nil }
        guard let kernel = cardEnhanceKernel else { return nil }

        let width = CVPixelBufferGetWidth(inputPB)
        let height = CVPixelBufferGetHeight(inputPB)
        guard width > 0 && height > 0 else { return nil }

        if pixelBufferPool == nil || poolWidth != width || poolHeight != height {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            let poolAttrs: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 4]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                    poolAttrs as CFDictionary,
                                    attrs as CFDictionary, &pool)
            pixelBufferPool = pool
            poolWidth = width
            poolHeight = height
        }
        guard let pool = pixelBufferPool else { return nil }

        var ciImage = CIImage(cvPixelBuffer: inputPB)

        // Step 1: 编码前降噪（消除传感器噪点，节省码率给真实细节）
        if noiseLevel > 0 {
            let denoised = ciImage.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": noiseLevel,
                "inputSharpness": 0.5
            ])
            ciImage = denoised
        }

        // Step 2: 色彩增强 (CIColorKernel 单 pass)
        guard let colorResult = kernel.apply(
            extent: ciImage.extent,
            arguments: [ciImage, exposure, pixelLevel, blackPoint, brightness, gamma, contrast, saturation, redGlow, highlightLift, chroma]
        ) else { return nil }

        // Step 3: 锐化（2米远牌面天然偏软，必须锐化）
        var finalImage = colorResult
        if sharpenAmount > 0 {
            finalImage = colorResult.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: sharpenAmount
            ])
        }

        var outputPB: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputPB)
        guard let out = outputPB else { return nil }
        ciContext.render(finalImage, to: out)
        // ⭐ 补色彩元数据（BT.709 满范围），编码 BGRA→YUV 时矩阵一致，避免偏色
        CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return out
    }
}

// MARK: - 帧节流器（整除跳帧算法：确保帧时间戳等差分布）
final class FrameThrottler: NSObject, RTCVideoCapturerDelegate {
    weak var inner: RTCVideoCapturerDelegate?           // 🔥 推送输出（受后端fps控制）
    weak var previewDelegate: RTCVideoCapturerDelegate? // 🔥 预览输出（固定60fps）

    // MARK: - SRT (independent)
    // 滤镜后帧旁路给 SRT 推流（与 WebRTC 推送同节流、同时间戳）。
    // 为 nil 时完全无开销；设置后每「推送帧」回调一次。删除本闭包即可回退。
    var srtFrameSink: ((_ pixelBuffer: CVPixelBuffer, _ timeStampNs: Int64) -> Void)?
    var videoFilter: VideoFilterPipeline?               // ⭐ 参数管理（UserDefaults / 服务端推送）
    // ⭐ A：处理器跨线程安全 —— process() 在采集队列，替换/改 LUT 在主线程，统一用 processorLock 互斥
    private let processorLock = NSLock()
    private var _nv12Processor: NV12MetalProcessor?     // ⭐ GPU-native NV12 处理器（与玉麒麟链路一致）
    private var _nv12LutProcessor: NV12LUTProcessor?    // ⭐ LUT 阶段（玉麒麟 Lookup）

    /// 线程安全替换 Metal 处理器（主线程调用，采集线程若正在 process 会等其结束）
    func setNV12Processor(_ p: NV12MetalProcessor?) {
        processorLock.lock(); _nv12Processor = p; processorLock.unlock()
    }
    /// 线程安全替换 LUT 处理器
    func setLutProcessor(_ p: NV12LUTProcessor?) {
        processorLock.lock(); _nv12LutProcessor = p; processorLock.unlock()
    }
    /// 线程安全：LUT 处理器是否已存在
    var lutProcessorExists: Bool {
        processorLock.lock(); defer { processorLock.unlock() }; return _nv12LutProcessor != nil
    }
    /// 线程安全：当前 LUT 名
    var currentLutNameSafe: String? {
        processorLock.lock(); defer { processorLock.unlock() }; return _nv12LutProcessor?.currentLutName
    }
    /// 线程安全切换 LUT 名（原地换纹理）；处理器不存在或切换失败返回 false
    func switchLutName(_ name: String) -> Bool {
        processorLock.lock(); defer { processorLock.unlock() }
        guard let lut = _nv12LutProcessor else { return false }
        return lut.setLutName(name)
    }

    var lutModeEnabled: Bool = false                    // ⭐ LUT 开关（默认关，等登录 iosPipeline 下发）
    var filterModeEnabled: Bool = false                 // ⭐ Metal 滤镜栈（默认关，对标玉麒麟）
    private var pipelineFrameLogCounter: Int = 0

    /// 相机 NV12 → [Metal 滤镜(开关)] → [LUT(开关，高光在此)] → 编码
    private func applyFilter(_ frame: RTCVideoFrame) -> RTCVideoFrame {
        guard let cvBuffer = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else { return frame }

        // ⭐ A：整段处理与处理器替换互斥 —— 持锁期间主线程的 setNV12Processor/setLutProcessor/switchLutName 会等待，
        //        保证 process() 永远看不到换了一半的处理器或被原地替换的 LUT 纹理。
        processorLock.lock()
        defer { processorLock.unlock() }

        var currentBuffer = cvBuffer
        var didProcess = false
        var ranMetalFilter = false
        var ranLut = false

        if filterModeEnabled, let filter = videoFilter, filter.enabled, !filter.isPassThrough {
            if let proc = _nv12Processor {
                proc.sync(from: filter)
                if let processed = proc.process(currentBuffer) {
                    currentBuffer = processed
                    didProcess = true
                    ranMetalFilter = true
                }
            } else if let processed = filter.processFrame(currentBuffer) {
                currentBuffer = processed
                didProcess = true
                ranMetalFilter = true
            }
        }

        if lutModeEnabled, let lut = _nv12LutProcessor {
            if let processed = lut.process(currentBuffer) {
                currentBuffer = processed
                didProcess = true
                ranLut = true
            }
        }

        pipelineFrameLogCounter &+= 1
        if didProcess && (pipelineFrameLogCounter <= 5 || pipelineFrameLogCounter % 300 == 0) {
            let pass = videoFilter.map { "enabled=\($0.enabled) passThrough=\($0.isPassThrough) exposure=\($0.exposure) pixelLevel=\($0.pixelLevel) blackPoint=\($0.blackPoint) brightness=\($0.brightness) gamma=\($0.gamma) contrast=\($0.contrast) saturation=\($0.saturation) redGlow=\($0.redGlow) highlightLift=\($0.highlightLift) noiseLevel=\($0.noiseLevel) sharpenAmount=\($0.sharpenAmount)" } ?? "noFilter"
            let nv12 = _nv12Processor.map { "nv12(exp=\($0.exposure), pixel=\($0.pixelLevel), bp=\($0.blackPoint), bright=\($0.brightness), gamma=\($0.gamma), contrast=\($0.contrast), sat=\($0.saturation), redGlow=\($0.redGlow), sharpen=\($0.sharpen), enabled=\($0.enabled))" } ?? "nv12=nil"
            let lut = _nv12LutProcessor.map { "lut(name=\($0.currentLutName), intensity=\($0.intensity), exposure=\($0.exposure), temperature=\($0.temperature), redLift=\($0.redLift), redSat=\($0.redSat), preContrast=\($0.preContrast), preGamma=\($0.preGamma))" } ?? "lut=nil"
            print("[FrameThrottler] 帧#\(pipelineFrameLogCounter) 处理 metal=\(ranMetalFilter) lut=\(ranLut) | filterMode=\(filterModeEnabled) lutMode=\(lutModeEnabled) | \(pass) | \(nv12) | \(lut)")
        }

        guard didProcess else { return frame }
        return RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: currentBuffer),
                             rotation: frame.rotation,
                             timeStampNs: frame.timeStampNs)
    }

    // 🔥 推送FPS硬上限
    private let maxAllowedFps: Int = 60
    
    // 🔥 采集FPS（外部设置，用于计算跳帧比例）
    var captureFps: Int = 60 {
        didSet {
            updateAccumulatorParams()
        }
    }
    
    var targetSendFps: Int = 30 {
        didSet {
            // 🔥 最高60fps（无下限限制）
            if targetSendFps > maxAllowedFps {
                targetSendFps = maxAllowedFps
            }
            if targetSendFps < 1 {
                targetSendFps = 1  // 至少1fps，避免除零
            }
            updateAccumulatorParams()
            print("🎯 [FrameThrottler] 推送目标FPS变更: \(oldValue) → \(targetSendFps)")
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // 🔥 累加器算法（支持任意FPS，均匀分布帧）
    // ═══════════════════════════════════════════════════════════════════════════
    private var sendAccumulator: Int = 0      // 推送累加器
    private var previewAccumulator: Int = 0   // 预览累加器
    
    // ═══════════════════════════════════════════════════════════════════════════
    // 🔥 方案B：90k RTP时钟（行业标准，无累积误差）
    // ═══════════════════════════════════════════════════════════════════════════
    // RTP 标准用 90kHz 时钟，常见FPS都能整除：
    // 60fps: 90000/60 = 1500 ticks/帧
    // 30fps: 90000/30 = 3000 ticks/帧
    // 25fps: 90000/25 = 3600 ticks/帧
    // 20fps: 90000/20 = 4500 ticks/帧
    // 15fps: 90000/15 = 6000 ticks/帧
    private let rtpClockRate: Int64 = 90_000        // RTP 90kHz 时钟
    private var rtp90kTimestamp: Int64 = 0          // 当前 90k 时间戳
    private var rtp90kStep: Int64 = 1500            // 每帧步进（90000/fps）
    private var isFirstFrame: Bool = true           // 是否第一帧
    
    // 🔥 预览固定60fps
    private let previewFps: Int = 60
    private var previewSentCounter: Int = 0
    
    // 🔥 采集帧率检测（用于自动调整跳帧比例）
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
    var isFrontCamera: Bool = false
    
    // 🔥 当前档位信息（用于日志）
    var currentProfileName: String = "unknown"
    var expectedCaptureWidth: Int = 0
    var expectedCaptureHeight: Int = 0
    var expectedOutputWidth: Int = 0
    var expectedOutputHeight: Int = 0
    var currentScaleDown: Double = 1.0
    
    // 🔥 首帧标记（用于唤醒检测）
    var hasReceivedFrame: Bool = false

    // 🚑 2026-07-02 切档卡死修复：最近一次采集帧到达时刻（CFAbsoluteTime），
    //    供 WebRTCManager 采集看门狗判断「推流中相机是否已停止吐帧」。
    //    采集线程每帧写、看门狗定时器读；Double 在 arm64 上对齐读写，无需加锁。
    private(set) var lastCaptureFrameAt: CFAbsoluteTime = 0
    
    // ═══════════════════════════════════════════════════════════════════════════
    // 🔥 诊断计数器（原子操作，不阻塞采集线程）
    // ═══════════════════════════════════════════════════════════════════════════
    private var diagCapCount: Int = 0   // 摄像头回调计数
    private var diagPushCount: Int = 0  // 实际喂给 WebRTC 的帧数
    private var diagTimer: Timer?       // 独立诊断定时器（不在采集队列）
    private let diagQueue = DispatchQueue(label: "fps.diag", qos: .utility)
    
    override init() {
        super.init()
        updateAccumulatorParams()
        startDiagTimer()
    }
    
    deinit {
        stopDiagTimer()
    }
    
    // 🔥 启动诊断定时器（独立线程，每秒输出一次）
    private func startDiagTimer() {
        stopDiagTimer()
        diagTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // 🔥 在独立队列打印，不影响任何关键线程
            self.diagQueue.async {
                let cap = self.diagCapCount
                let push = self.diagPushCount
                let target = self.targetSendFps

                // 重置计数
                self.diagCapCount = 0
                self.diagPushCount = 0

                // ⭐ §53.14 重新启用（原先注释掉了）：排「首次连接手机端不出画面」与「每几秒卡一次」
                //   必须看到最底层这两个数——cap=相机回调帧数、push=真正喂给编码器的帧数。
                //   · cap=0 → 相机根本没吐帧（首连黑屏就是这种）；
                //   · cap 正常但 push=0 → 卡在节流/编码入口；
                //   · cap 周期性掉坑（如 30→8→30）→ 采集端卡顿，不是网络问题。
                //   带「采集」关键词，P2PLogReporter 才会收进上报（见其 captureKeywords）。
                let gapMs = self.lastCaptureFrameAt > 0
                    ? Int((CFAbsoluteTimeGetCurrent() - self.lastCaptureFrameAt) * 1000) : -1
                print("🔬 [采集诊断] cap=\(cap) push=\(push)/\(target) 距上帧=\(gapMs)ms 尺寸=\(self.lastFrameWidth)x\(self.lastFrameHeight) 首帧=\(self.hasReceivedFrame ? "已到" : "未到")")
            }
        }
    }
    
    private func stopDiagTimer() {
        diagTimer?.invalidate()
        diagTimer = nil
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - 🔥 累加器算法（核心：支持任意FPS + 等差时间戳）
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// 更新累加器参数
    private func updateAccumulatorParams() {
        let captureRate = max(1, captureFps)
        let targetRate = max(1, min(targetSendFps, maxAllowedFps))
        
        // 🔥 方案B：计算 90k RTP 时钟步进
        // 90000/fps = 每帧步进的 ticks
        rtp90kStep = rtpClockRate / Int64(targetRate)
        
        // 转换为毫秒用于日志显示
        let intervalMs = Double(rtp90kStep) * 1000.0 / Double(rtpClockRate)
        
        print("📊 [FrameThrottler] 90k RTP时钟参数更新:")
        print("   采集=\(captureRate)fps")
        print("   推送=\(targetRate)fps")
        print("   90k步进=\(rtp90kStep) ticks/帧 (间隔\(String(format: "%.3f", intervalMs))ms)")
        print("   预览=\(previewFps)fps")
        
        // 检查是否能整除
        if rtpClockRate % Int64(targetRate) != 0 {
            print("⚠️ [FrameThrottler] 警告: \(targetRate)fps 不能整除90000，可能有微小误差")
        }
        
        // 重置累加器
        sendAccumulator = 0
        previewAccumulator = 0
    }
    
    /// 🔥 累加器判断：是否应该发送这一帧
    /// 原理：每采集一帧，累加 targetFps，当累加值 >= captureFps 时发送并减去 captureFps
    /// 这样可以将 targetFps 帧均匀分布在 captureFps 帧中
    private func shouldSendPushFrame() -> Bool {
        sendAccumulator += targetSendFps
        if sendAccumulator >= captureFps {
            sendAccumulator -= captureFps
            return true
        }
        return false
    }
    
    /// 预览累加器判断
    private func shouldSendPreviewFrame() -> Bool {
        previewAccumulator += previewFps
        if previewAccumulator >= captureFps {
            previewAccumulator -= captureFps
            return true
        }
        return false
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - RTCVideoCapturerDelegate（采集回调）
    // ═══════════════════════════════════════════════════════════════════════════

    func capturer(_ capturer: RTCVideoCapturer, didCapture videoFrame: RTCVideoFrame) {
        let nowSec = CFAbsoluteTimeGetCurrent()
        lastCaptureFrameAt = nowSec  // 🚑 采集看门狗心跳
        
        // 采集计数
        captureCounter += 1
        diagCapCount += 1  // 🔥 诊断：摄像头回调计数
        
        // 记录帧尺寸和旋转（用于日志）
        lastFrameWidth = videoFrame.width
        lastFrameHeight = videoFrame.height
        lastOriginalRotation = videoFrame.rotation
        
        // 🔥 第一帧标记（90k时钟从0开始，不需要基准）
        if isFirstFrame {
            isFirstFrame = false
            hasReceivedFrame = true  // 🔥 标记已收到帧（用于唤醒检测）
            let step = rtp90kStep
            DispatchQueue.global(qos: .utility).async {
                print("🎬 [FrameThrottler] 首帧，90k RTP时钟从0开始，步进=\(step)")
            }
        }
        
        // 🔥 检测实际采集帧率（每秒更新一次）
        captureFpsDetectCounter += 1
        if captureFpsDetectStartTime == 0 {
            captureFpsDetectStartTime = nowSec
        } else if nowSec - captureFpsDetectStartTime >= 1.0 {
            let newDetectedFps = captureFpsDetectCounter
            
            // 🔥 如果检测到的FPS与设置的不同，异步打印警告
            if abs(newDetectedFps - captureFps) > 5 {
                let detected = newDetectedFps
                let expected = captureFps
                DispatchQueue.global(qos: .utility).async {
                    print("⚠️ [FrameThrottler] 检测FPS(\(detected))与设置FPS(\(expected))差距较大")
                }
            }
            
            detectedCaptureFps = max(1, newDetectedFps)
            captureFpsDetectCounter = 0
            captureFpsDetectStartTime = nowSec
        }
        
        // ⭐ C：每帧只跑一次 applyFilter（GPU 处理），预览与推送复用同一处理结果，GPU 负载减半
        let needPreview = shouldSendPreviewFrame()
        let needPush = shouldSendPushFrame()
        if needPreview || needPush {
            let filtered = applyFilter(videoFrame)

            // ========== 🔥 预览输出：累加器算法 ==========
            if needPreview {
                previewSentCounter += 1
                let previewFrame = RTCVideoFrame(
                    buffer: filtered.buffer,
                    rotation: ._0,
                    timeStampNs: videoFrame.timeStampNs
                )
                previewDelegate?.capturer(capturer, didCapture: previewFrame)
            }

            // ========== 🔥 推送输出：累加器算法 + 90k RTP 等差时间戳 ==========
            if needPush {
                sentCounter += 1
                diagPushCount += 1
                let timestampNs = rtp90kTimestamp * 1_000_000_000 / rtpClockRate
                rtp90kTimestamp += rtp90kStep
                let pushFrame = RTCVideoFrame(
                    buffer: filtered.buffer,
                    rotation: ._0,
                    timeStampNs: timestampNs
                )
                inner?.capturer(capturer, didCapture: pushFrame)

                // MARK: - SRT (independent)
                // 同一滤镜后帧、同一时间戳旁路给 SRT；sink 为 nil 时零开销。
                if let sink = srtFrameSink,
                   let cvBuffer = (filtered.buffer as? RTCCVPixelBuffer)?.pixelBuffer {
                    sink(cvBuffer, timestampNs)
                }
            }
        }
        
        // 每秒上报一次采集/推送FPS（异步，不阻塞采集线程）
        if lastReportTsSec == 0 { lastReportTsSec = nowSec }
        if (nowSec - lastReportTsSec) >= 1.0 {
            let cap = captureCounter
            let snd = sentCounter
            let width = lastFrameWidth
            let height = lastFrameHeight
            let expCaptureW = expectedCaptureWidth
            let expCaptureH = expectedCaptureHeight
            let expOutputW = expectedOutputWidth
            let expOutputH = expectedOutputHeight
            let scale = currentScaleDown
            let targetFps = targetSendFps
            let step = rtp90kStep
            let clock = rtpClockRate
            
            // 🔥 FPS回调移到主线程
            DispatchQueue.main.async { [weak self] in
                self?.fpsReportHandler?(cap, snd)
            }
            
            // 🔥 日志已禁用（避免任何潜在影响）
            // DispatchQueue.global(qos: .utility).async {
            //     let captureMatch = (Int(width) == expCaptureW && Int(height) == expCaptureH) ? "✅" : "❌"
            //     let intervalMs = Double(step) * 1000.0 / Double(clock)
            //     print("📡 推流: 采集=\(width)x\(height) \(captureMatch) → 输出=\(expOutputW)x\(expOutputH) (scale=\(scale)) | FPS: \(cap)→\(snd)/\(targetFps) (90k步进=\(step), \(String(format: "%.2f", intervalMs))ms)")
            // }
            
            captureCounter = 0
            sentCounter = 0
            previewSentCounter = 0
            lastReportTsSec = nowSec
        }
    }
    
    // ⭐ C：预览/推送的发送逻辑已内联进 capturer(_:didCapture:)，每帧只跑一次 applyFilter，
    //        旧的 sendPreviewFrame / sendFrameWithArithmeticTimestamp / sendFrame 已移除以防重复处理。

    /// 重置节流器状态
    func reset() {
        // 重置累加器
        sendAccumulator = 0
        previewAccumulator = 0
        
        // 重置 90k RTP 时钟
        rtp90kTimestamp = 0
        isFirstFrame = true
        
        // 重置统计
        lastReportTsSec = 0
        captureCounter = 0
        sentCounter = 0
        previewSentCounter = 0
        captureFpsDetectCounter = 0
        captureFpsDetectStartTime = 0
    }
    
    /// 停止（兼容旧接口）
    func stop() {
        reset()
    }
}

// MARK: - 阶梯档位（动态根据摄像头能力）
enum LadderProfile: Int, CaseIterable {
    case low       // 低清
    case standard  // 标清
    case high      // 高清
    case ultra     // 超高帧
    case p4k       // 超清（仅后置）
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

enum CaptureRangeMode: String, CaseIterable {
    case any = "Any"
    case fullRange420f = "420f"
    case videoRange420v = "420v"
}

enum CaptureBinningMode: String, CaseIterable {
    case any = "Any"
    case binned = "Binned"
    case nonBinned = "NonBinned"
}


struct LadderPreset {
    let width: Int         // 输出宽度（缩放后）
    let height: Int        // 输出高度（缩放后）
    let fps: Int           // 采集FPS
    let minKbps: Int       // WebRTC 最低码率
    let maxKbps: Int       // WebRTC 最高码率
    let maxPushFps: Int    // 🔥 最高推送FPS（根据分辨率限制）
    let scaleDown: Double  // 🔥 缩放比例（1.0=不缩放，2.0=缩小一半，3.0=缩小到1/3）
    
    init(width: Int, height: Int, fps: Int, maxKbps: Int, minKbps: Int? = nil, maxPushFps: Int = 60, scaleDown: Double = 1.0) {
        self.width = width
        self.height = height
        self.fps = fps
        self.maxKbps = maxKbps
        self.minKbps = minKbps ?? maxKbps
        self.maxPushFps = maxPushFps
        self.scaleDown = scaleDown
    }
}

final class WebRTCManager: NSObject, ObservableObject {
    
    /// 全局冗余日志开关（自适应/SRT/采集等模块的高频诊断 print 受此 gate）。
    /// 默认关闭：每秒刷的自适应/采集诊断 print 在发布/性能场景下会拖慢主路，仅排查时临时改 true。
    /// ⚠️ 2026-07-02 临时开启：定性「P2P 弱网 fps 不自动升降」——跑一次 P2P 弱网→好网，
    ///   控制台过滤 malvshezhing 看 [自适应] 行的 RTT/丢包是否恒 0。拿到日志后改回 false。
    static let verboseLogEnabled = true

    /// 码率限制 / 自适应 FPS 调试日志统一前缀（控制台过滤: malvshezhing）
    private static let malvshezhingLogPrefix = "malvshezhing"
    private func malvshezhingLog(_ message: String) {
        guard WebRTCManager.verboseLogEnabled else { return }
        print("\(Self.malvshezhingLogPrefix) \(message)")
    }
    
    // MARK: - 快门速度上限（静态变量，程序启动时计算）
    /// 综合 16:9 和 4:3 格式的最快快门，取最小值，再和 900 比较取最小
    static var maxShutterSpeed: Int = 240  // 默认值，初始化时会重新计算
    
    // MARK: - 对外状态
    @Published var isPublishing = false
    @Published var viewerConnected: Bool = false
    /// ⭐ 切网重连中（P2P）：拆会话+HANGUP 后等 PC 重连，左上角显示"网络切换重连中…"；PC 心跳恢复即清除
    @Published var p2pReconnecting: Bool = false

    // MARK: - §53.2 PC 在线（与"在看"分开的两个状态）
    /// 有没有 PC **登录在线**（收到 PC_PRESENCE 心跳，不管它有没有画面）。
    /// 与 `viewerConnected`（=有画面在看）严格区分：两者组合起来才能说清现场状态——
    /// 「PC在线 + 未在看」正是"两端都在线却没画面"这类故障的特征，以前只有一个灯，看不出来。
    @Published var pcOnline: Bool = false
    /// 在线 PC 台数
    @Published var pcOnlineCount: Int = 0
    /// 在线 PC 里是否**存在收不了 H265 的**（网页内核=Chromium 134，收 H265 必黑屏，见 §49.6-10）。
    /// SRS 模式据此把编码降到 H264（§53.5，编码要服从最弱的观看端）。
    @Published var anyViewerCannotRecvH265: Bool = false
    /// 本次会话定案的链路/编码原因（随 CONFIG_STATE.connectReason 上报，PC 顶栏显示——"互相监督"的一半）
    @Published var connectReason: String = ""

    private var lastViewerHeartbeatTime: Date = Date.distantPast
    private var viewerHeartbeatChecker: Timer?
    var currentKbps: Int = 0       // 🔥 去掉@Published，纯统计不触发UI刷新
    var currentFps: Int = 0         // 🔥 去掉@Published，纯统计不触发UI刷新
    @Published var currentProfile: LadderProfile = .standard
    @Published var captureRangeMode: CaptureRangeMode = .any
    @Published var captureBinningMode: CaptureBinningMode = .any
    @Published var wbTemperature: Float = 0
    @Published var wbTint: Float = 0
    @Published var wbRed: Float = 0
    @Published var wbGreen: Float = 0
    @Published var wbBlue: Float = 0
    @Published var wbBlack: Float = 0
    @Published var wbWhite: Float = 0
    @Published var wbAmber: Float = 0
    /// PC 下发采集颜色时递增，驱动 iOS 面板滑块同步（iOS 本地调节不回传 PC）
    @Published private(set) var captureColorRemoteTick: UInt = 0
    @Published var whiteBalanceIsAuto: Bool = false
    @Published var whiteBalanceStatusText: String = "--"
    private var whiteBalanceStatusTimer: Timer?
    // 额外暴露采集/推送FPS，便于UI区分显示
   var currentCaptureFps: Int = 0   // 🔥 去掉@Published，纯统计不触发UI刷新
   var currentSendFps: Int = 0      // 🔥 去掉@Published，纯统计不触发UI刷新
   
   // 码率平滑（减少显示波动）- 🔥 200ms周期，15次=3秒
   private var kbpsHistory: [Int] = []
   private let kbpsHistorySize = 15  // 使用3秒移动平均（200ms x 15 = 3秒）
   
   // FPS平滑（减少显示波动）- 🔥 200ms周期，15次=3秒
   private var fpsHistory: [Int] = []
   private let fpsHistorySize = 15  // 使用3秒移动平均（200ms x 15 = 3秒）
   
    // 动态档位配置（根据当前摄像头）
    var currentLadder: [LadderProfile: LadderPreset] = [:]
    
    // 新增：低档位降帧配置（逐步降低 30→24→20→15→10）
    private let LOWEST_PROFILE: LadderProfile = .standard  // 自适应底线（low 只能手动/后端选择）
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

    // ⭐ 视频后处理滤镜 (单 Metal CIColorKernel)
    let videoFilter = VideoFilterPipeline()
    
    
    // MARK: - 动态档位计算
    /// 根据当前摄像头动态计算档位配置
    // ✅ 固定5档配置（前后置摄像头分别设置）
   private func calculateLadderForDevice(_ device: AVCaptureDevice) {
        // 🔥🔥 非ultra/非p4k(15+)档位统一采集 1920x1440 (4:3)
        // ultra (16:9) 需要单独采集 1280x720
        // 🔥 iPhone 15+ 超高清(p4k) 直接采集 1920x1080 (16:9)，scaleDown=1.0
        //    因为 scaleResolutionDownBy 是等比缩放，无法从 1920x1440 → 1920x1080

        let needP4kSeparateCapture = isIPhone15OrNewer()

        // 🔥 超高清档位：iPhone 15+ 直接采集1920x1080 (16:9)，scaleDown=1.0
        //              iPhone 13/14 采集1920x1440 (4:3) → 原始输出1920x1440，scaleDown=1.0
        // ⭐ 2026-07-09 用户要求：全档位码率上限统一下调 500（min 不动）
        let p4kPreset: LadderPreset
        if needP4kSeparateCapture {
            p4kPreset = LadderPreset(width: 1920, height: 1080, fps: 60, maxKbps: 7000, minKbps: 4500, maxPushFps: 60, scaleDown: 1.0)
        } else {
            p4kPreset = LadderPreset(width: 1920, height: 1440, fps: 60, maxKbps: 7000, minKbps: 4500, maxPushFps: 60, scaleDown: 1.0)
        }

        // 其它档位所有设备统一，不区分机型（采集1920x1440，通过scaleDown缩放输出）
        // ⭐ 除 640x480(low) 外，其他档位最大码率再 +1000kbps
        // ⭐ minKbps 约为 max 的 60%，码率可向下波动
        // 🔥 2026-07-02: high 档码率上调 5500→7000（min 60%）。原与 ultra(1280x720) 同区间 3300-5500，
        //   但 high 像素多 68%（1440x1080≈1.55M vs 0.92M px），同码率必然先糊先卡（编码器 underbitrate）。
        let highPreset     = LadderPreset(width: 1440, height: 1080, fps: 60, maxKbps: 6500, minKbps: 4200, maxPushFps: 60, scaleDown: 1.0)
        let standardPreset = LadderPreset(width: 1024, height: 768,  fps: 60, maxKbps: 4000, minKbps: 2700, maxPushFps: 60, scaleDown: 1.0)
        let lowPreset      = LadderPreset(width: 640,  height: 480,  fps: 60, maxKbps: 2000, minKbps: 1500, maxPushFps: 60, scaleDown: 1.0)  // 低清 1500~2000

        let p4kInfo = needP4kSeparateCapture ? "1920x1080(16:9直接采集)" : "1920x1440(4:3原始)"
        
        if device.position == .back {
            currentLadder = [
                .p4k:      p4kPreset,
                .ultra:    LadderPreset(width: 1280, height: 720, fps: 240, maxKbps: 5000, minKbps: 3300, maxPushFps: 60, scaleDown: 1.0),
                .high:     highPreset,
                .standard: standardPreset,
                .low:      lowPreset
            ]
            print("📐 后置摄像头 - 档位配置：")
            print("   超高清(p4k)   = \(p4kPreset.width)x\(p4kPreset.height) @60fps → 4500-7000kbps [\(p4kInfo)]")
            print("   超高帧(ultra) = 1280x720  @240fps → 3300-5000kbps (16:9单独采集)")
            print("   超清(high)    = 1440x1080 @60fps  → 4200-6500kbps (采集1920x1440缩放)")
            print("   高清(standard)= 1024x768  @60fps  → 2700-4000kbps (采集1920x1440缩放)")
            print("   低清(low)     = 640x480   @60fps  → 1500-2000kbps (采集1920x1440缩放)")
        } else {
            currentLadder = [
                .p4k:      p4kPreset,
                .ultra:    LadderPreset(width: 1280, height: 720, fps: 120, maxKbps: 5000, minKbps: 3300, maxPushFps: 60, scaleDown: 1.0),
                .high:     highPreset,
                .standard: standardPreset,
                .low:      lowPreset
            ]
            print("📐 前置摄像头 - 档位配置：")
            print("   超高清(p4k)   = \(p4kPreset.width)x\(p4kPreset.height) @60fps → 4500-7000kbps [\(p4kInfo)]")
            print("   超高帧(ultra) = 1280x720  @120fps → 3300-5000kbps (16:9单独采集)")
            print("   超清(high)    = 1440x1080 @60fps  → 4200-6500kbps (采集1920x1440缩放)")
            print("   高清(standard)= 1024x768  @60fps  → 2700-4000kbps (采集1920x1440缩放)")
            print("   低清(low)     = 640x480   @60fps  → 1500-2000kbps (采集1920x1440缩放)")
        }
    }
    
    private func effectiveMinKbpsForCurrentProfile() -> Int {
        guard let preset = currentLadder[currentProfile] else { return 1500 }
        let qualityPercent = lastQualityPercent ?? 100
        let result = Int(Double(preset.minKbps) * Double(qualityPercent) / 100.0)
        return max(100, result)
    }

    // ✅ 计算目标码率（仅由质量百分比决定，与 FPS 完全解耦）
    // 🔥 码率和 FPS 独立控制：手动设置码率不受 FPS 变动影响，无运动时码率也不降
    private func effectiveMaxKbpsForCurrentProfile() -> Int {
        guard let preset = currentLadder[currentProfile] else { return 1500 }

        // 档位最高码率 × 质量百分比 = 目标码率
        let qualityPercent = lastQualityPercent ?? 100
        let result = Int(Double(preset.maxKbps) * Double(qualityPercent) / 100.0)

        print("📊 码率计算: 档位 min=\(preset.minKbps) max=\(preset.maxKbps)kbps × 质量=\(qualityPercent)% → \(effectiveMinKbpsForCurrentProfile())-\(max(100, result))kbps")

        return max(100, result)  // 保底 100kbps
    }

    private func applyEffectiveBitrateToWebRTC() {
        let baseMin = effectiveMinKbpsForCurrentProfile()
        let baseMax = max(baseMin, effectiveMaxKbpsForCurrentProfile())
        // 🚨 叠加弱网紧急降码率系数
        let minK = max(100, Int(Double(baseMin) * emergencyBitrateScale))
        let maxK = max(minK, Int(Double(baseMax) * emergencyBitrateScale))
        setBitrateRangeKbps(min: minK, max: maxK)
        let pct = lastQualityPercent ?? 100
        if emergencyBitrateScale < 0.999 {
            malvshezhingLog("[码率] 应用 档位=\(currentProfile) 清晰度=\(pct)% 紧急系数=\(String(format: "%.2f", emergencyBitrateScale)) → \(minK)-\(maxK) kbps (基准\(baseMin)-\(baseMax))")
        } else {
            malvshezhingLog("[码率] 应用 档位=\(currentProfile) 清晰度=\(pct)% → \(minK)-\(maxK) kbps")
        }
        // ⭐ P2P：仅同步「码率」到所有直连会话（改法A：与帧率解耦，不再重写 maxFramerate）
        if currentConnMode == .p2p { p2pManager.applyBitrateToAllSessions() }
        // ⭐ SRT：把最新目标码率（连同当前推送帧率/分辨率）即时同步给 HaishinKit 编码器，
        //   与 P2P/SRS 的即时性对齐（修复「SRT 后端下发码率不起作用」）。
        if currentConnMode == .srt { syncSRTEncodeParamsFromCurrentState() }
    }

    /// ⭐ SRT 编码参数同步（修复「SRT 后端下发码率/fps 不起作用」）。
    ///
    /// 把「当前档位分辨率 + 当前推送帧率 + 当前目标码率」下发给 SRTManager 的编码器：
    ///   - fps 取「实际推送目标」frameThrottler.targetSendFps（后端下发 fps 的落地值），
    ///     而不是档位采集 fps，否则编码器 expectedFrameRate 永远停在采集帧率、后端调 fps 无感。
    ///   - 码率直接交给 setEncodeParams 比对：调用前【绝不能】预写 srtManager.targetBitrateKbps，
    ///     否则 setEncodeParams 的「变更检测」会把新码率误判为「无变化」而跳过下发——
    ///     这正是本次「后端下发码率不起作用」的根因（commit 949acc2 引入）。
    /// 仅 SRT 模式且正在推流时生效；其它模式为零开销空操作。
    private func syncSRTEncodeParamsFromCurrentState() {
        guard currentConnMode == .srt, srtManager.isPublishing else { return }
        let res = getCaptureResolutionForProfile(currentProfile)
        let pushFps = frameThrottler?.targetSendFps ?? res.fps
        srtManager.setEncodeParams(width: res.width, height: res.height,
                                   fps: pushFps, bitrateKbps: targetBitrateKbps)
    }
    
    /// 设置平均推送的目标 FPS（采集保持不变，码率按比例调整）
    /// - Parameter fps: 后端下发的FPS值（0-240），实际推送为 fps/4（0-60）
    func setAverageOutputFPS(_ fps: Int) {
         
        // 🔥 后端下发 fps 范围 0-240，实际推送 = fps / 4，最大60fps
        let maxPushFps = getMaxPushFpsForCurrentProfile()  // 档位最大推送FPS（如60）
        let actualTargetFps = fps / 4  // 后端fps/4 = 实际推送目标
        // 🔥 先限制在档位上限，再限制在硬上限60fps，最低1fps（避免除零）
        let minPushFps = 1  // 🔥 最低推送FPS（无下限限制）
        let profileClamped = max(minPushFps, min(actualTargetFps, maxPushFps))
        let clamped = min(profileClamped, maxAllowedPushFps)  // 硬上限60fps
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
        
        // 🔥 修复：同步更新 WebRTC 编码器的 maxFramerate
        // 否则初始化时设置的 maxFramerate 会变成永久上限，后续 FPS 提升无效
        // ⭐ 2026-06-25 改法A配套：P2P 模式 videoSender 恒为 nil，需落到各直连会话（仅改帧率，不碰码率）。
        if currentConnMode == .p2p {
            p2pManager.applyFramerateToAllSessions()
            malvshezhingLog("[setAverageOutputFPS] P2P 各会话 maxFramerate 同步为 \(clamped)fps")
        } else if let sender = videoSender {
            let params = sender.parameters
            if !params.encodings.isEmpty {
                let oldMaxFr = params.encodings[0].maxFramerate
                params.encodings[0].maxFramerate = NSNumber(value: clamped)
                sender.parameters = params
                print("✅ [setAverageOutputFPS] WebRTC编码器 maxFramerate: \(oldMaxFr ?? 0) → \(clamped)")
            }
        } else {
            print("⚠️ [setAverageOutputFPS] videoSender 是 nil，无法更新编码器 maxFramerate")
        }
        
        if actualTargetFps > maxPushFps {
            print("⚠️ 后端请求FPS(\(fps)/4=\(actualTargetFps)) 超过档位上限(\(maxPushFps)fps)，已限制为\(clamped)fps")
        }
        
        // 🔥 FPS 与码率完全解耦：FPS 变动不触发码率重算
        // 码率只由 setQualityPercentage / setMaxBitrateKbps 显式控制
        let actualSendFps = frameThrottler?.targetSendFps ?? clamped
        print("mm: 档位=\(currentProfile), 后端fps=\(fps), 推送目标=\(oldFps)→\(clamped)fps, 实际节流=\(actualSendFps)fps, 码率=\(targetMinBitrateKbps)-\(targetBitrateKbps)kbps")
        
        // 🔥 同步更新自适应FPS基准值
        if adaptiveFpsEnabled {
            adaptiveFps = clamped
        }
        
        // 同步相机采集帧率（服务器下发fps时）
        // ⭐ 2026-07-14：套 effectiveCaptureFps —— 低功率开关开着时，这里也不能让推送fps把采集fps顶回60。
        if let input = capturer?.currentVideoInput {
            let dev = input.device
            let captureFps = effectiveCaptureFps(max(clamped, minCaptureFps))
            if currentCaptureFPS != captureFps {
                capturer?.lockFrameRate(captureFps)
                currentCaptureFPS = captureFps
                print("🎯 [FPS同步] 推流:\(clamped)fps → 采集:\(captureFps)fps ✅已调整 (后端下发\(fps)/4=\(actualTargetFps))")
            } else {
                print("🎯 [FPS同步] 推流:\(clamped)fps → 采集:\(captureFps)fps（无变化）")
            }
        } else {
            print("🎯 [FPS同步] 推流:\(clamped)fps → 采集:未知（capturer未就绪，将在启动后同步）")
        }
        // ⭐ SRT：把后端下发的推送 fps（连同当前码率/分辨率）即时同步给 HaishinKit 编码器，
        //   与 P2P/SRS 即时性对齐（修复「SRT 后端下发 fps 不起作用」）。实际喂帧由 frameThrottler
        //   节流，这里同步编码器 expectedFrameRate 使其与推送帧率一致。
        syncSRTEncodeParamsFromCurrentState()
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - 🔥 自适应FPS算法（核心逻辑）
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// 启用/禁用自适应FPS
    /// - Parameter enabled: true=启用自适应FPS，false=使用固定FPS
    func enableAdaptiveFps(_ enabled: Bool) {
        adaptiveFpsEnabled = enabled
        if enabled {
            // 初始化自适应FPS为当前目标FPS
            adaptiveFps = frameThrottler?.targetSendFps ?? targetOutputFPS
            highLossCounter = 0
            lowLossCounter = 0
            lastNotifiedFps = 0
            print("✅ [自适应FPS] 已启用，初始FPS=\(adaptiveFps)")
        } else {
            // 禁用时恢复到后端下发的目标FPS
            let targetFps = targetOutputFPS
            if frameThrottler?.targetSendFps != targetFps {
                frameThrottler?.targetSendFps = targetFps
                print("✅ [自适应FPS] 已禁用，恢复FPS=\(targetFps)")
            }
        }
    }
    
    /// 🔥🔥 v2.1 自适应FPS逻辑（重构：修复时间单位、移除码率判断、加冷却期）
    /// 由200ms的statsTimer调用，但内部保证每秒只执行一次核心逻辑
    /// - Parameters:
    ///   - instantLossRate: 本次200ms窗口的瞬时丢包率 (0.0~1.0)
    ///   - packetsLostPerSec: 本次200ms窗口的丢包数
    ///   - rttMs: 往返延迟（毫秒）
    ///   - bitrateRatio: 码率达成率（v2.1不再使用，仅日志记录）
    private func processAdaptiveFps(instantLossRate: Double, packetsLostPerSec: Int, rttMs: Int, bitrateRatio: Double) {
        let now = Date()

        // 🔥 v2.1: 每秒只执行一次核心逻辑（statsTimer是200ms，但自适应以1秒为单位）
        let timeSinceLastProcess = now.timeIntervalSince(lastAdaptiveProcessTime)
        if timeSinceLastProcess < 0.9 {
            // 不到1秒，只收集丢包数据，不执行判断
            return
        }
        lastAdaptiveProcessTime = now

        // 抗频闪模式下不触发自适应升降帧
        if antiFlickerEnabled {
            malvshezhingLog("[自适应] ⏸️ 抗频闪开启，升降帧停摆 档位=\(currentProfile) fps=\(adaptiveFps)")
            return
        }
        
        // 🔥 后端消息设置FPS后1秒内，自适应逻辑不介入（避免冲突）
        let timeSinceRemoteFps = now.timeIntervalSince(lastRemoteFpsTime)
        if timeSinceRemoteFps < 1.0 {
            //print("📊 [自适应] fps=\(adaptiveFps) 🔒后端指令生效中(\(String(format: "%.1f", 1.0 - timeSinceRemoteFps))s后介入)")
            return
        }
        
        // 冷却期时长（降帧后1秒，升帧后2秒）；判定在算出网络状态后进行
        let timeSinceLastChange = now.timeIntervalSince(lastFpsChangeTime)
        let cooldown = lastFpsDirection == .down ? cooldownAfterDown : cooldownAfterUp
        let inFpsCooldown = timeSinceLastChange < cooldown
        
        // 🔥 v2.1: 丢包率3秒移动平均（防止突发抖动误触发）
        lossRateHistory.append(instantLossRate)
        if lossRateHistory.count > lossRateHistorySize {
            lossRateHistory.removeFirst()
        }
        let avgLossRate = lossRateHistory.reduce(0, +) / Double(max(1, lossRateHistory.count))
        
        // 使用后端下发的 targetOutputFPS 作为升帧上限
        let maxFps = targetOutputFPS  // 升帧上限=PC下发值÷4
        
        // 🔥 v2.1: 网络状态判断（只用RTT + 平均丢包率，不用bitrateRatio）
        // RTT=0 当"中等"处理（可能是没获取到数据）
        let isRttBad = rttMs > rttDownThreshold && rttMs > 0
        let isRttGood = rttMs > 0 && rttMs < rttUpThreshold
        let isLossBad = avgLossRate > lossRateDownThreshold
        let isLossGood = avgLossRate < lossRateUpThreshold
        
        // 网络差 = RTT差 或 丢包差（不再包含码率判断）
        let isNetworkBad = isRttBad || isLossBad
        // 网络好 = RTT好(且有数据) 且 丢包好
        let isNetworkGood = isRttGood && isLossGood
        
        let status = isNetworkBad ? "🔴差" : (isNetworkGood ? "🟢好" : "🟡中")
        let bitratePct = targetBitrateKbps > 0 ? Int(bitrateRatio * 100) : 0
        malvshezhingLog("[自适应] 档位=\(currentProfile) fps=\(adaptiveFps)/\(maxFps) RTT=\(rttMs)ms 丢包=\(String(format: "%.1f", avgLossRate * 100))%(3s均) 码率达成=\(bitratePct)% \(status) ↓\(highLossCounter)/\(downgradeHoldSec) ↑\(lowLossCounter)/\(upgradeHoldSec)")
        
        if inFpsCooldown {
            if isNetworkBad {
                malvshezhingLog("[自适应] 冷却中 剩\(String(format: "%.1f", cooldown - timeSinceLastChange))s 上次=\(lastFpsDirection == .down ? "降帧" : "升帧") fps=\(adaptiveFps)")
            }
            return
        }
        
        var fpsChanged = false
        let oldFps = adaptiveFps

        // ⭐ §25.5-2：RTT 判差但丢包持续干净（<0.5%）= RTT 读数可疑（GStreamer RR 污染实测签名）
        let rttOnlySuspect = isRttBad && avgLossRate < 0.005
        if rttOnlySuspect { rttOnlyBadSeconds += 1 } else { rttOnlyBadSeconds = 0; rttOnlyEpisodeDropped = false }

        if isNetworkBad {
            // 🔴 网络差：累积计数，达到阈值降帧（档位切换：直接减半）
            highLossCounter += 1
            lowLossCounter = 0

            if rttOnlySuspect && rttOnlyBadSeconds >= rttOnlyProbeSec {
                // 🧪 试探回升：RTT 恒高但丢包干净已持续 15s+ → 反向逐级恢复。
                //   真拥塞会立刻出丢包 → rttOnlySuspect 变 false → 下一秒回到正常压制分支。
                rttOnlyBadSeconds = max(0, rttOnlyProbeSec - rttOnlyProbeIntervalSec)
                if emergencyBitrateScale < 0.999 {
                    let oldScale = emergencyBitrateScale
                    emergencyBitrateScale = min(1.0, emergencyBitrateScale + emergencyBitrateStepUp)
                    lastFpsChangeTime = now
                    lastFpsDirection = .up
                    applyEffectiveBitrateToWebRTC()
                    enforceBitrateImmediately()
                    malvshezhingLog("[自适应] 🧪试探回升(RTT=\(rttMs)ms高但丢包=0) 码率系数\(String(format: "%.2f", oldScale))→\(String(format: "%.2f", emergencyBitrateScale))")
                } else {
                    let newFps = min(maxFps, fpsLadder.last(where: { $0 > adaptiveFps }) ?? adaptiveFps)
                    if newFps != adaptiveFps {
                        adaptiveFps = newFps
                        fpsChanged = true
                        lastFpsChangeTime = now
                        lastFpsDirection = .up
                        malvshezhingLog("[自适应] 🧪试探升帧(RTT=\(rttMs)ms高但丢包=0) \(oldFps)→\(adaptiveFps)fps")
                    }
                }
                highLossCounter = 0
            } else if highLossCounter >= downgradeHoldSec {
                let newFps = fpsLadder.first(where: { $0 < adaptiveFps }) ?? fpsLadder.last ?? minAdaptiveFps
                if newFps != adaptiveFps && !(rttOnlySuspect && rttOnlyEpisodeDropped) {
                    // 还能降帧 → 先降帧（RTT-only 可疑期最多降一档，防止被脏读数拖到底）
                    adaptiveFps = newFps
                    fpsChanged = true
                    lastFpsChangeTime = now
                    lastFpsDirection = .down
                    if rttOnlySuspect { rttOnlyEpisodeDropped = true }
                    malvshezhingLog("[自适应] ⬇️降帧 \(oldFps)→\(adaptiveFps)fps 网络差 RTT=\(rttMs)ms 丢包=\(String(format: "%.1f", avgLossRate * 100))%")
                } else if rttOnlySuspect {
                    // RTT-only 且已降过一档 → 码率最多压到 0.7（一步），等待试探回升介入
                    if emergencyBitrateScale > rttOnlyEmergencyFloor {
                        let oldScale = emergencyBitrateScale
                        emergencyBitrateScale = max(rttOnlyEmergencyFloor, emergencyBitrateScale * emergencyBitrateStepDown)
                        lastFpsChangeTime = now
                        lastFpsDirection = .down
                        applyEffectiveBitrateToWebRTC()
                        enforceBitrateImmediately()
                        malvshezhingLog("[码率] ⚠️RTT可疑限压 系数\(String(format: "%.2f", oldScale))→\(String(format: "%.2f", emergencyBitrateScale))(下限\(rttOnlyEmergencyFloor)) RTT=\(rttMs)ms 丢包=0")
                    } else {
                        malvshezhingLog("[码率] ⏸️RTT可疑保持 系数=\(String(format: "%.2f", emergencyBitrateScale)) fps=\(adaptiveFps) RTT=\(rttMs)ms 丢包=0 等待试探回升(\(rttOnlyBadSeconds)/\(rttOnlyProbeSec)s)")
                    }
                } else if emergencyBitrateScale > emergencyBitrateMinScale {
                    // 🚨 fps 已到最低档仍网络差 → 紧急逐级降码率，缓解队列堆积
                    let oldScale = emergencyBitrateScale
                    emergencyBitrateScale = max(emergencyBitrateMinScale, emergencyBitrateScale * emergencyBitrateStepDown)
                    lastFpsChangeTime = now
                    lastFpsDirection = .down
                    applyEffectiveBitrateToWebRTC()
                    enforceBitrateImmediately()
                    malvshezhingLog("[码率] 🚨紧急降码率 系数\(String(format: "%.2f", oldScale))→\(String(format: "%.2f", emergencyBitrateScale)) 目标=\(targetMinBitrateKbps)-\(targetBitrateKbps)kbps (fps=\(adaptiveFps)已到底) RTT=\(rttMs)ms")
                } else {
                    malvshezhingLog("[码率] ⚠️已压到最低 系数=\(String(format: "%.2f", emergencyBitrateScale)) 目标=\(targetMinBitrateKbps)-\(targetBitrateKbps)kbps fps=\(adaptiveFps) RTT=\(rttMs)ms 仍差")
                }
                highLossCounter = 0
            }
        } else if isNetworkGood {
            // 🟢 网络好：累积计数，达到阈值升帧（档位切换：直接翻倍）
            lowLossCounter += 1
            highLossCounter = 0

            if lowLossCounter >= upgradeHoldSec {
                if emergencyBitrateScale < 0.999 {
                    // 🚨 先把紧急压低的码率逐级恢复，再考虑升帧
                    let oldScale = emergencyBitrateScale
                    emergencyBitrateScale = min(1.0, emergencyBitrateScale + emergencyBitrateStepUp)
                    lastFpsChangeTime = now
                    lastFpsDirection = .up
                    applyEffectiveBitrateToWebRTC()
                    enforceBitrateImmediately()
                    malvshezhingLog("[码率] ✅恢复码率 系数\(String(format: "%.2f", oldScale))→\(String(format: "%.2f", emergencyBitrateScale)) 目标=\(targetMinBitrateKbps)-\(targetBitrateKbps)kbps RTT=\(rttMs)ms")
                } else {
                    let newFps = min(maxFps, fpsLadder.last(where: { $0 > adaptiveFps }) ?? fpsLadder.first ?? 60)
                    if newFps != adaptiveFps {
                        adaptiveFps = newFps
                        fpsChanged = true
                        lastFpsChangeTime = now
                        lastFpsDirection = .up
                        malvshezhingLog("[自适应] ⬆️升帧 \(oldFps)→\(adaptiveFps)fps 网络好 上限=\(maxFps) RTT=\(rttMs)ms")
                    }
                }
                lowLossCounter = 0
            }
        } else {
            // 🟡 网络中等：每秒衰减1
            highLossCounter = max(0, highLossCounter - 1)
            lowLossCounter = max(0, lowLossCounter - 1)
        }

        if fpsChanged {
            applyAdaptiveFps(adaptiveFps)
        }
    }
    
    /// 应用自适应FPS并通知PC端
    /// - Parameter fps: 新的FPS值
    private func applyAdaptiveFps(_ fps: Int) {
        // 1. 更新节流器
        frameThrottler?.targetSendFps = fps
        
        // 2. 同步相机采集帧率（避免 ISP 全速空跑）
        // ⭐ 2026-07-14：套 effectiveCaptureFps，低功率开关下自适应也不能把采集fps顶回30以上。
        if let input = capturer?.currentVideoInput {
            let dev = input.device
            let captureFps = effectiveCaptureFps(max(fps, minCaptureFps))
            if currentCaptureFPS != captureFps {
                capturer?.lockFrameRate(captureFps)
                currentCaptureFPS = captureFps
                malvshezhingLog("[自适应] 已应用 fps=\(fps) 采集=\(captureFps)fps（已调相机）")
            } else {
                malvshezhingLog("[自适应] 已应用 fps=\(fps) 采集=\(captureFps)fps（相机无变化）")
            }
        } else {
            malvshezhingLog("[自适应] 已应用 fps=\(fps) 采集未就绪")
        }
        
        // 3. 更新WebRTC编码参数
        // ⭐ 2026-06-25 改法A配套：P2P 模式下 self.videoSender 恒为 nil，
        //   自适应 fps 必须落到 P2P 各会话编码器（applyFramerateToAllSessions 只改 maxFramerate，不碰码率），
        //   否则自适应降帧在编码器层不生效，且会留到「调码率」时才被 applyEncoding 补刷 → 表现为「调码率改了 fps」。
        if currentConnMode == .p2p {
            p2pManager.applyFramerateToAllSessions()
        } else if let sender = videoSender {
            let params = sender.parameters
            if !params.encodings.isEmpty {
                params.encodings[0].maxFramerate = NSNumber(value: fps)
                sender.parameters = params
            }
        }
        
        // 4. 通知PC端（避免重复发送）
        if fps != lastNotifiedFps {
            lastNotifiedFps = fps
            WebSocketManager.shared.sendFpsUpdate(fps: fps)
        }
    }
    
    // MARK: - §53.2 PC 在线心跳（与拉流心跳分开，不看有没有画面）

    @objc private func onPCPresence(_ notification: Notification) {
        guard let pcId = notification.userInfo?["fromDevice"] as? String, !pcId.isEmpty else { return }
        let viewing = (notification.userInfo?["viewing"] as? Bool) ?? false
        let h265Recv = (notification.userInfo?["h265Recv"] as? Bool) ?? true
        let kernel = (notification.userInfo?["kernel"] as? String) ?? "unknown"
        let ipsStr = (notification.userInfo?["localIps"] as? String) ?? ""
        let localIps = ipsStr.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        let publicIp = (notification.userInfo?["publicIp"] as? String) ?? ""

        // ⭐ §53.4：观看端状态的唯一存放处是 SessionPolicy（决策要用同一份输入），
        //   这里只把结果镜像成 @Published 给左上角状态条用。
        let isNew = SessionPolicy.shared.updatePresence(pcId: pcId, viewing: viewing,
                                                        h265Recv: h265Recv, kernel: kernel,
                                                        localIps: localIps, publicIp: publicIp)
        if isNew {
            print("🖥 [PC在线] \(pcId) 上线（内核=\(kernel) 能收H265=\(h265Recv) 在看=\(viewing) 网段=\(localIps) 公网=\(publicIp.isEmpty ? "未报" : publicIp)）")
        }
        refreshPCPresenceState()
    }

    /// 汇总在线 PC 状态到 @Published（主线程调用）
    private func refreshPCPresenceState() {
        let count = SessionPolicy.shared.onlineViewerCount
        let noH265 = SessionPolicy.shared.anyViewerCannotRecvH265
        if pcOnlineCount != count { pcOnlineCount = count }
        if pcOnline != (count > 0) { pcOnline = (count > 0) }
        if anyViewerCannotRecvH265 != noH265 {
            anyViewerCannotRecvH265 = noH265
            print("🎞️ [编码仲裁] 在线观看端\(noH265 ? "存在" : "不存在")收不了 H265 的内核 → 编码\(noH265 ? "需降 H264" : "可用 H265")")
        }
    }

    // MARK: - 🔥 v2.0 PC端自适应FPS指令处理

    @objc private func onViewerHeartbeat(_ notification: Notification) {
        lastViewerHeartbeatTime = Date()
        if !viewerConnected {
            viewerConnected = true
            let fps = (notification.userInfo?["fps"] as? Int) ?? 0
            print("📺 [VIEWER] PC 已连接，接收 \(fps)fps")
        }
        if p2pReconnecting { p2pReconnecting = false }   // ⭐ PC 心跳恢复 = 切网重连完成，清除"重连中"
        // ⭐ 维护观看者注册表（用于 P2P/SRS 自动协商计数）
        if let pcId = notification.userInfo?["fromDevice"] as? String, !pcId.isEmpty {
            let net = (notification.userInfo?["networkType"] as? String) ?? "unknown"
            viewerRegistry[pcId] = (Date(), net)
        }
    }

    @objc private func onAntiFlickerCommand(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        let enabled = userInfo["enabled"] as? Bool ?? false
        let serverFps = userInfo["fps"] as? Int ?? 80
        let actualFps = serverFps / 4

        antiFlickerEnabled = enabled
        antiFlickerFps = actualFps

        if enabled {
            applyAdaptiveFps(actualFps)
            print("🔦 [抗频闪] 开启，锁定 \(actualFps)fps（服务器值=\(serverFps)）")
        } else {
            // 关闭时不还原参数，保持当前状态
            print("🔦 [抗频闪] 关闭，保持当前帧率不变")
        }
    }

    @objc private func onTestModeCommand(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        let enabled = userInfo["enabled"] as? Bool ?? false
        lutModeEnabled = enabled
        pipelineDefaultsApplied = true
        applyLutMode(enabled)
    }

    private var pipelineDefaultsApplied = false

    private var shouldUsePipelineDefaults: Bool {
        !pipelineDefaultsApplied
    }

    /// LUT 开关（与滤镜独立，可滤镜→LUT 串联）
    private func applyLutMode(_ enabled: Bool) {
        lutModeEnabled = enabled
        frameThrottler?.lutModeEnabled = enabled
        if enabled {
            ensureLutProcessor()
            let lut = frameThrottler?.currentLutNameSafe ?? pendingLutName ?? NV12LUTProcessor.defaultLutName
            print("[LUT] 开启 — \(lut)")
            print("✅ [LUT] 开启 — \(lut)")
        } else {
            print("[LUT] 关闭")
            print("✅ [LUT] 关闭")
        }
    }

    /// Metal 滤镜栈开关（与 LUT 独立）
    private func applyFilterMode(_ enabled: Bool) {
        let before = "filterMode=\(filterModeEnabled) videoFilter.enabled=\(videoFilter.enabled)"
        filterModeEnabled = enabled
        videoFilter.enabled = enabled
        frameThrottler?.filterModeEnabled = enabled
        print("[滤镜] \(enabled ? "开启" : "关闭") | \(before) → filterMode=\(filterModeEnabled) enabled=\(videoFilter.enabled)")
        print("✅ [滤镜] \(enabled ? "开启" : "关闭")")
    }

    /// 登录后 / 预览初始化前：只同步三链路开关，不运用默认值（默认值等相机就绪后 applyPipelineDefaults）
    func syncPipelineSwitchesFromConfig(source: String) {
        let cfg = IOSPipelineConfig.shared
        print("[syncPipelineSwitches] source=\(source) iosPipeline filter=\(cfg.switchFilter) lut=\(cfg.switchLut) hw=\(cfg.switchHardware) | 当前 filterMode=\(filterModeEnabled) lutMode=\(lutModeEnabled)")
        applyFilterMode(cfg.switchFilter)
        applyLutMode(cfg.switchLut)
    }

    /// STOMP ptype=lutName：切换 5 张玉麒麟 LUT 之一
    func applyLutName(_ name: String) {
        let normalized = NV12LUTProcessor.normalizedLutName(name)
        pendingLutName = normalized
        if frameThrottler?.switchLutName(normalized) != true {
            frameThrottler?.setLutProcessor(NV12LUTProcessor(lutName: normalized))
        }
        print("🎨 [LUT] STOMP 切换 → \(normalized)")
    }

    private func ensureLutProcessor() {
        if frameThrottler?.lutProcessorExists == false {
            let name = pendingLutName ?? NV12LUTProcessor.defaultLutName
            frameThrottler?.setLutProcessor(NV12LUTProcessor(lutName: name))
        }
    }

    /// 推流启动时同步滤镜/LUT 开关到 FrameThrottler
    private func applyPipelineModes() {
        applyFilterMode(filterModeEnabled)
        applyLutMode(lutModeEnabled)
    }

    // MARK: - 登录/档位切换后运用三链路默认值
    /// 读取 IOSPipelineConfig.shared，按三个开关把登录下发的默认值运用到 滤镜/硬件/LUT 链路。
    /// 仅在「第一次（相机就绪）」和「切换档位（ptype="type"）」时调用。
    /// 运行期 PC 的 STOMP 推送（其它 ptype）会在此之后覆盖这些值 —— 两者不冲突。
    func applyPipelineDefaults(source: String = "manual") {
        let cfg = IOSPipelineConfig.shared
        print("[applyPipelineDefaults] source=\(source) 开始 iosPipeline filter=\(cfg.switchFilter) lut=\(cfg.switchLut) hw=\(cfg.switchHardware) shouldUseDefaults=\(shouldUsePipelineDefaults) | 当前 filterMode=\(filterModeEnabled) lutMode=\(lutModeEnabled)")

        if !shouldUsePipelineDefaults {
            applyFilterMode(filterModeEnabled)
            applyLutMode(lutModeEnabled)
            if cfg.switchHardware {
                capturer?.applyContinuousWhiteBalance()
            }
            print("[applyPipelineDefaults] source=\(source) 保持运行期链路状态 filterMode=\(filterModeEnabled) lutMode=\(lutModeEnabled) passThrough=\(videoFilter.isPassThrough)")
            return
        }

        pipelineDefaultsApplied = true

        // ① 滤镜链路：开关打开才运用，否则直通
        if cfg.switchFilter {
            applyFilterMode(true)
            // 后端 exposure.default 是线性倍率(如1.10)，shader 走 2^EV，故换算 EV=log2(linear)（与 PC 端 Math.log2 一致）
            let evStops = log2(max(cfg.exposureLinear, 1e-6))
            videoFilter.applyAll(
                brightness: cfg.brightness, contrast: cfg.contrast, saturation: cfg.saturation,
                sharpness: cfg.sharpness, redBoost: cfg.redBoost,
                blackPoint: cfg.blackPoint, highlightLift: cfg.highlightLift,
                gamma: cfg.gamma, exposure: evStops,
                enabled: true, source: "pipelineDefaults")
            print("[applyPipelineDefaults] 滤镜已运用 brightness=\(cfg.brightness) exposureLinear=\(cfg.exposureLinear) ev=\(evStops)")
        } else {
            applyFilterMode(false)
            print("[applyPipelineDefaults] 滤镜开关=关 → 直通")
        }

        // ② 硬件链路：开关打开才运用。增益(0-100)映射到设备实际 ISO min..max；白平衡始终自动（不下发具体值）
        if cfg.switchHardware {
            applyHardwareBrightness(cfg.gainDefault)   // 0-100 → ISO，并记录 slider 值供相机就绪后重应用
            capturer?.applyContinuousWhiteBalance()
            print("✅ [applyPipelineDefaults] 硬件: gain(0-100)=\(cfg.gainDefault)→ISO, 白平衡=自动")
        }

        // ③ LUT 链路：开关打开才套用默认 LUT，否则关闭
        if cfg.switchLut {
            applyLutMode(true)
            applyLutName(cfg.lutName)
        } else {
            applyLutMode(false)
            print("[applyPipelineDefaults] LUT开关=关 → 直通")
        }
        print("[applyPipelineDefaults] 完成 filterMode=\(filterModeEnabled) lutMode=\(lutModeEnabled) passThrough=\(videoFilter.isPassThrough)")
        print("✅ [applyPipelineDefaults] filter=\(cfg.switchFilter) hardware=\(cfg.switchHardware) lut=\(cfg.switchLut)")
    }

    /// PC「增益」滑块（后台 test_brightness）：值是 0-100，只走硬件 ISO，不进滤镜链路。
    /// 注意：0-100 是 UI 抽象，真正运用要映射到设备实际 ISO 的 min..max。
    @objc private func onTestBrightnessCommand(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        let value = userInfo["value"] as? Int ?? 0
        applyHardwareBrightness(value)
    }

    static let defaultHardwareBrightnessSlider: Int = 20

    /// 硬件增益：滑块 0-100 → 设备实际 ISO[min,max]（由 capturer 计算），不走 shader 高光增强
    func applyHardwareBrightness(_ sliderValue: Int) {
        hardwareBrightnessSliderValue = max(0, min(100, sliderValue))
        print("📷 [硬件增益] value=\(hardwareBrightnessSliderValue)/100 → ISO")
        applyHardwareBrightnessEVIfReady()
    }

    private func applyHardwareBrightnessEVIfReady() {
        guard let capturer else { return }
        capturer.applyGainSlider(hardwareBrightnessSliderValue)
    }

    // MARK: - 白平衡（PC 滤镜弹框下发，0-100 → 2000K-8000K）

    @objc private func onWhiteBalanceCommand(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        let value = userInfo["value"] as? Int ?? 50
        applyHardwareWhiteBalance(value)
    }

    static let wbMinKelvin: Float = 2000
    static let wbMaxKelvin: Float = 8000
    static let defaultWBSlider: Int = 50

    static func colorTemperature(fromSlider value: Int) -> Float {
        let slider = max(0, min(100, value))
        return wbMinKelvin + Float(slider) / 100.0 * (wbMaxKelvin - wbMinKelvin)
    }

    func applyHardwareWhiteBalance(_ sliderValue: Int) {
        let kelvin = Self.colorTemperature(fromSlider: sliderValue)
        hardwareWBSliderValue = max(0, min(100, sliderValue))
        print("⚪️ [白平衡] value=\(sliderValue) kelvin=\(Int(kelvin))K")
        guard let capturer else { return }
        capturer.applyColorTemperature(kelvin)
    }

    /// 运用白平衡：开自动WB → 等收敛 → 读色温 → 锁定 → 回传滑块值给 PC
    func applyWhiteBalanceOnce() {
        guard let capturer else { return }
        capturer.applyWhiteBalanceOnceAndLock { [weak self] kelvin in
            guard let self else { return }
            let slider = Self.sliderFromTemperature(kelvin)
            self.hardwareWBSliderValue = slider
            print("⚪️ [运用白平衡] 自动测得 \(Int(kelvin))K → slider=\(slider)")
            WebSocketManager.shared.sendWhiteBalanceResult(sliderValue: slider)
        }
    }

    static func sliderFromTemperature(_ kelvin: Float) -> Int {
        let slider = (kelvin - wbMinKelvin) / (wbMaxKelvin - wbMinKelvin) * 100
        return max(0, min(100, Int(round(slider))))
    }

    /// 处理 PC 端发来的 set_fps 通知
    /// 🔑 P0-1：收到 PC 端 WebSocket 关键帧请求（RTCP PLI 的兜底通道）
    /// 此路用于「RTCP 没回传」的场景，必须可靠本地强制 IDR → 走 forceKeyframe()（码率微调）。
    /// 注意：adaptOutputFormat 传相同分辨率是 no-op，不能用于此处。
    @objc private func onRequestKeyframeCommand(_ notification: Notification) {
        // ⭐ 2026-06-25 发热优化：PLI/REQUEST_KEYFRAME 走节流，窗口内只补一帧，防观看端狂刷 PLI 打爆编码器
        let now = Date()
        let elapsed = now.timeIntervalSince(lastForceKeyframeTime)
        if elapsed < forceKeyframeMinIntervalSec {
            print("🔑 [request_keyframe] 节流跳过（距上次仅 \(String(format: "%.2f", elapsed))s < \(forceKeyframeMinIntervalSec)s）")
            return
        }
        lastForceKeyframeTime = now
        print("🔑 [request_keyframe] 处理PC关键帧请求 → forceKeyframe")
        forceKeyframe()
    }

    @objc private func onSetFpsRequested(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let fps = userInfo["fps"] as? Int else {
            print("🎯 [set_fps] ❌ 通知参数错误")
            return
        }
        
        let urgency = userInfo["urgency"] as? String ?? "normal"
        let reason = userInfo["reason"] as? String ?? ""
        let bitrate = userInfo["bitrate"] as? Int ?? 0
        let timestamp = userInfo["timestamp"] as? Int64 ?? 0
        
        print("🎯 [set_fps] 处理指令: fps=\(fps), urgency=\(urgency), reason=\(reason)")
        
        // 根据 urgency 决定执行方式
        applyRemoteFps(fps: fps, urgency: urgency, bitrate: bitrate, reason: reason)
    }
    
    /// 应用 PC 端下发的 FPS（v2.0 核心方法）
    /// - Parameters:
    ///   - fps: 目标帧率（可以是任意值，如 15/20/25/30/35/40/45/50/55/60）
    ///   - urgency: 紧急度（"critical"/"high"/"normal"/"low"）
    ///   - bitrate: 建议码率（bps），0 表示不调整
    ///   - reason: 触发原因（调试用）
    private func applyRemoteFps(fps: Int, urgency: String, bitrate: Int, reason: String) {
        let startTime = Date()
        let oldFps = adaptiveFps
        
        // 🔥🔥 记录后端消息设置FPS的时间（自适应逻辑暂停1秒）
        lastRemoteFpsTime = Date()
        
        // 🔥 直接应用目标FPS，不受上限限制（后端消息优先）
        let targetFps = max(minAdaptiveFps, fps)
        
        // 更新自适应FPS值
        adaptiveFps = targetFps
        
        // 🔥 v10.1 防花屏：根据 urgency 决定执行方式 + 降码率 + 插I帧
        // ⭐ 2026-06-25 发热优化：弱网（critical/high）才【临时】开短 GOP 快恢复，
        //   用完由 scheduleKeyframeTimerAutoStop 在数秒后自动 stopKeyframeTimer 归位到常态；
        //   normal/low（网络已恢复/升帧）直接关定时器，回到「默认长 GOP + 按需 PLI」，不再常驻短 GOP。
        switch urgency {
        case "critical":
            // 🚨 紧急：50ms内执行，保码率不降（降FPS已足够，降码率会双重恶化画质）
            applyFpsImmediately(targetFps, bitrate: bitrate)
            forceKeyframe()
            setKeyframeInterval(gopExtreme)        // 临时短 GOP（启动定时器）
            scheduleKeyframeTimerAutoStop()        // ⭐ 数秒后自动关回常态
            malvshezhingLog("[set_fps] critical \(oldFps)→\(targetFps)fps 临时GOP=\(gopExtreme)s(用完自动归位) 码率=\(bitrate)")

        case "high":
            // ⚡ 高优先级：保码率不降，只降FPS + 插I帧
            applyFpsImmediately(targetFps, bitrate: bitrate)
            forceKeyframe()
            setKeyframeInterval(gopWeak)           // 临时短 GOP（启动定时器）
            scheduleKeyframeTimerAutoStop()        // ⭐ 数秒后自动关回常态
            malvshezhingLog("[set_fps] high \(oldFps)→\(targetFps)fps 临时GOP=\(gopWeak)s(用完自动归位) 码率=\(bitrate)")
            
        case "normal":
            // 正常：网络已稳，回到常态长 GOP（关定时器，不再常驻强制 IDR）
            applyFpsImmediately(targetFps, bitrate: bitrate)
            stopKeyframeTimer()
            malvshezhingLog("[set_fps] normal \(oldFps)→\(targetFps)fps 关闭定时强制(回常态长GOP) 码率=\(bitrate)")
            
        case "low":
            // 低优先级：平滑过渡（升帧时用），网络宽裕→回常态长 GOP
            applyFpsWithTransition(targetFps, bitrate: bitrate, duration: 0.3)
            stopKeyframeTimer()
            malvshezhingLog("[set_fps] low \(oldFps)→\(targetFps)fps 关闭定时强制(回常态长GOP) 码率=\(bitrate)")
            
        default:
            applyFpsImmediately(targetFps, bitrate: bitrate)
        }
        
        // 重置本地自适应计数器（PC端已经接管控制）
        highLossCounter = 0
        lowLossCounter = 0
        
        // 计算执行时间
        let execTime = Date().timeIntervalSince(startTime) * 1000
        malvshezhingLog("[set_fps] 已应用 \(oldFps)→\(targetFps)fps urgency=\(urgency) 耗时=\(String(format: "%.1f", execTime))ms")
        
        // 发送确认（可选）
        WebSocketManager.shared.sendSetFpsAck(fps: targetFps, status: "applied")
    }
    
    /// 立即应用 FPS（无过渡）
    private func applyFpsImmediately(_ fps: Int, bitrate: Int) {
        // 1. 更新节流器
        frameThrottler?.targetSendFps = fps
        
        // 2. 同步相机采集帧率（避免相机 ISP 全速采集浪费功耗）
        // ⭐ 2026-07-14：套 effectiveCaptureFps，低功率开关下 PC 的 set_fps 指令也不能把采集fps顶回30以上。
        if let input = capturer?.currentVideoInput {
            let dev = input.device
            let captureFps = effectiveCaptureFps(max(fps, minCaptureFps))
            if currentCaptureFPS != captureFps {
                capturer?.lockFrameRate(captureFps)
                currentCaptureFPS = captureFps
                malvshezhingLog("[set_fps] 采集 \(fps)→\(captureFps)fps 已调相机")
            }
        } else {
            malvshezhingLog("[set_fps] 采集未就绪 推流=\(fps)fps")
        }
        
        // 3. 更新 WebRTC 编码参数
        // ⭐ 2026-06-25 改法A配套：P2P 模式 videoSender 恒为 nil，需落到各直连会话（fps/码率仍各自独立）。
        if currentConnMode == .p2p {
            p2pManager.applyFramerateToAllSessions()
            if bitrate > 0 {
                p2pManager.applyBitrateToAllSessions()
                malvshezhingLog("[码率] set_fps(P2P) 附带 max=\(bitrate/1000) kbps fps=\(fps)")
            }
        } else if let sender = videoSender {
            let params = sender.parameters
            if !params.encodings.isEmpty {
                params.encodings[0].maxFramerate = NSNumber(value: fps)
                
                if bitrate > 0 {
                    params.encodings[0].maxBitrateBps = NSNumber(value: bitrate)
                    malvshezhingLog("[码率] set_fps 附带 max=\(bitrate/1000) kbps fps=\(fps)")
                }
                
                sender.parameters = params
            }
        }
        
        // 4. 更新 lastNotifiedFps 避免本地自适应再次发送
        lastNotifiedFps = fps
    }
    
    /// 带过渡的 FPS 切换（用于升帧）
    private func applyFpsWithTransition(_ targetFps: Int, bitrate: Int, duration: TimeInterval) {
        // 简单实现：直接应用（iOS 端的帧率切换本身就很平滑）
        // 如果需要更复杂的过渡，可以在这里实现渐变
        applyFpsImmediately(targetFps, bitrate: bitrate)
    }
    
    /// 获取当前自适应FPS值
    func getCurrentAdaptiveFps() -> Int {
        return adaptiveFpsEnabled ? adaptiveFps : targetOutputFPS
    }
    
    /// 开/关平均节流（关时恢复直通）
    func enableAverageThrottling(_ enabled: Bool) {
        guard let capturer = self.capturer else { return }
        if enabled {
            if frameThrottler == nil {
                let throttler = FrameThrottler()
                throttler.inner = self.videoSource
                throttler.previewDelegate = self.previewVideoSource  // 🔥 预览输出（固定60fps）
                throttler.captureFps = currentCaptureFPS             // 🔥 设置采集FPS
                throttler.targetSendFps = targetOutputFPS            // 🔥 设置推送FPS
                throttler.videoFilter = self.videoFilter             // ⭐ 参数管理
                throttler.setNV12Processor(NV12MetalProcessor())     // ⭐ GPU-native NV12
                frameThrottler = throttler
                applyPipelineModes()
                print("🔄 [enableAverageThrottling] 创建新节流器，采集=\(currentCaptureFPS)fps，推送=\(targetOutputFPS)fps，预览=60fps")
            }
            capturer.setDelegate(frameThrottler!)
        } else if let source = self.videoSource {
            capturer.setDelegate(source)
        }
    }
    
    // MARK: - 🔥 快门速度控制（cjfps 60-600 直接应用）
    
    /// 设置快门速度（后端下发 cjfps 60-600，直接作为快门速度值）
    /// - Parameter shutterSpeed: 60-600（60=1/60s, 600=1/600s）
    func setCaptureFrameRate(shutterSpeed: Int, forceApply: Bool = false) {
        let oldShutter = cjfpsValue
        // 🔥 限制范围 60-600（后端下发的实际值）
        // ⭐ 需求#10（2026-07-31）：快门上限 600→1000（后台曝光FPS配置已放宽到 1000，
        //   这里的硬钳制曾把下发的 1000 压回 600，是"后端设了 1000 拉不上去"的设备端一环）
        cjfpsValue = max(60, min(1000, shutterSpeed))
        
        print("📸 [快门速度] cjfps: 1/\(oldShutter)s → 1/\(cjfpsValue)s")
        
        // 🔥 只有快门速度有变化时才调整
        if oldShutter != cjfpsValue || forceApply {
            applyShutterSpeedChange()
        } else {
            print("   ✅ 快门速度已是目标值，无需调整")
        }
    }
    
    /// 将快门速度对齐到防频闪安全值（50Hz/60Hz 整数倍）
    private func snapToAntiFlicker(_ shutterSpeed: Int) -> Int {
        let safe50Hz = stride(from: 50, through: 600, by: 50).map { $0 }
        let safe60Hz = stride(from: 60, through: 600, by: 60).map { $0 }
        let allSafe = Array(Set(safe50Hz + safe60Hz)).sorted()
        let nearest = allSafe.min(by: { abs($0 - shutterSpeed) < abs($1 - shutterSpeed) }) ?? shutterSpeed
        return nearest
    }

    /// 应用快门速度变化 — 快门优先模式（精确锁定快门 + 自动 ISO 闭环）
    private func applyShutterSpeedChange() {
        let snappedShutter = snapToAntiFlicker(cjfpsValue)
        capturer?.applyShutter(snappedShutter,
                               preserveCurrentISO: autoIsoEnabled)
        if autoIsoEnabled { startAutoIsoLoop() }
    }

    // MARK: - 自动 ISO 闭环 (S 档: 快门固定, ISO 跟随光线)

    private func startAutoIsoLoop() {
        stopAutoIsoLoop()
        print("🔄 [AutoISO] 启动闭环 ISO 调整 (1Hz, 快门固定 ISO 跟随)")
        DispatchQueue.main.async { [weak self] in
            self?.autoIsoTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.adjustIsoTowardsTarget()
            }
        }
    }

    private func stopAutoIsoLoop() {
        DispatchQueue.main.async { [weak self] in
            self?.autoIsoTimer?.invalidate()
            self?.autoIsoTimer = nil
        }
    }

    private func adjustIsoTowardsTarget() {
        guard autoIsoEnabled else { return }
        capturer?.adjustIsoTowardsTarget()
    }

    /// 获取当前采集设备
    private func getCurrentCaptureDevice() -> AVCaptureDevice? {
        return capturer?.currentDevice
    }
    

    // MARK: - SRS 配置
    // 🔥 从登录接口获取推流IP，不再写死
    var srsIP: String {
        return UserDefaults.standard.string(forKey: "stream_push_ip") ?? ""
    }
    var app   = "tenantA"

    // 🔥 基础流名（来自 permanent_token，不带时间戳）
    var baseStreamKey: String = ""  // 改为 internal，供 ContentView 检查
    
    // 🔥 实际推流使用的流名（基础流名 + 时间戳，每次推流生成新的）
    private(set) var streamKey: String = ""
    
    // 🔥 推流Token（每次推流前从服务器获取）
    private var streamToken: String = ""
    
    // 挂载方向 & 镜像开关（持久化可选）
    @Published var mountOrientation: MountOrientation = .deg0
    @Published var streamMirrored: Bool = false
    
    // WebRTCManager.applyThinRemoteConfig(_ cfg: ThinRemoteConfig)
    func applyThinRemoteConfig(_ cfg: ThinRemoteConfig) {
        let startTime = Date()
        // print("⚡ [applyThinRemoteConfig] ptype=\(cfg.ptype)")
        
        //print("---> "+cfg.ptype)
        // ... existing code ...
        switch cfg.ptype {
        case "type":
            // 档位：5档固定配置 - low/standard/high/ultra/p4k
            // print("🔍 [档位] cfg.type = '\(cfg.type)'")
            let desiredProfile: LadderProfile
            switch cfg.type.lowercased() {
            case "p4k":
                desiredProfile = .p4k
                // print("   → .p4k")
            case "ultra":
                desiredProfile = .ultra
                // print("   → .ultra")
            case "high":
                desiredProfile = .high
                // print("   → .high")
            case "standard":
                desiredProfile = .standard
                // print("   → .standard")
            case "low":
                desiredProfile = .low
                // print("   → .low")
            default:
                desiredProfile = .low
                print("   ⚠️ 未知档位 '\(cfg.type)'，使用默认 .low")
            }
            // print("   当前档位: \(currentProfile), 目标档位: \(desiredProfile)")
            if currentProfile != desiredProfile {
                print("🔔 [触发源:applyThinRemoteConfig-ptype=type] 档位变更: \(currentProfile) → \(desiredProfile)")
                if gentleAdaptMode { applyProfileBitrateOnly(desiredProfile) } else { applyProfile(desiredProfile) }
            } else {
                // print("⏭️ 档位无变化")
            }
            //print("✅ 已按 ptype=type 应用档位: \(cfg.type) → \(desiredProfile)")
            
            // ✅ 切换档位时，同时应用 fps（如果有）
            if let f = cfg.fps {
                let maxFps = getMaxPushFpsForCurrentProfile()
                let webrtcFps = min(maxFps, f / 4)
                print("mm: 档位=\(cfg.type)(\(desiredProfile)), fps=后端\(f)/4=\(f/4) → 实际\(webrtcFps)fps (上限\(maxFps))")
                setAverageOutputFPS(f)
                enableAverageThrottling(true)
            }
            // 🎨 切换档位会重建采集/管线，需按开关重新运用三链路默认值（之后 STOMP 推送仍可覆盖）
            applyPipelineDefaults(source: "stomp:type")

        case "direction":
            // 方向："-1"后置；"1"前置（若不一致则切换一次）
            //print("🔍 收到 direction 切换请求: cfg.direction=\(cfg.direction)")
            if let input = capturer?.currentVideoInput {
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
                let webrtcFps = min(maxFps, f / 4)
                print("mm: 档位=\(currentProfile), fps=后端\(f)/4=\(f/4) → 实际\(webrtcFps)fps (上限\(maxFps))")
                setAverageOutputFPS(f)
                enableAverageThrottling(true)
            } else {
                print("mm: 档位=\(currentProfile), fps=⚠️缺少值")
            }
            
        case "cjfps":
            let cj = cfg.cjfps ?? Int(cfg.brightness ?? 0)
            if cj > 0 {
                print("📸 [快门] cjfps=\(cj) → 1/\(cj)s")
                setCaptureFrameRate(shutterSpeed: cj, forceApply: true)
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

        case "lutName":
            applyLutName("lookup")

        case "filterEnabled":
            if let enabled = cfg.filterEnabled {
                print("[STOMP filterEnabled] PC 下发 enabled=\(enabled)")
                pipelineDefaultsApplied = true
                applyFilterMode(enabled)
            }

        case "lowPowerCapture":
            // ⭐ 2026-07-14：PC「相机设定」面板低功率/高功率开关。只调采集fps（lockFrameRate 轻量
            //   重锁帧间隔，不触发完整会话重配置/不换格式），推送fps不受影响。
            if let enabled = cfg.lowPowerCapture {
                lowPowerCaptureEnabled = enabled
                let newFps = getCaptureResolutionForProfile(currentProfile).fps
                capturer?.lockFrameRate(newFps)
                currentCaptureFPS = newFps
                malvshezhingLog("[低功率] PC下发 enabled=\(enabled) → 采集fps钉\(newFps) (档位=\(currentProfile))")
                print("🔋 [低功率采集] enabled=\(enabled) → 采集fps=\(newFps)")
            }

        case "videoHDR":
            if let enabled = cfg.videoHDR {
                capturer?.applyVideoHDR(enabled)
            }

        case "autoHDR":
            if let enabled = cfg.autoHDR {
                capturer?.applyAutoHDR(enabled)
            }

        case "applyWhiteBalance":
            if let wbResult = cfg.testWhiteBalance {
                hardwareWBSliderValue = wbResult
            } else {
                applyWhiteBalanceOnce()
            }

        case "test_brightness":
            let value = cfg.testBrightness ?? Int(cfg.exposure ?? cfg.brightness ?? Float(Self.defaultHardwareBrightnessSlider))
            applyHardwareBrightness(value)

        case "white_balance":
            let value = cfg.testWhiteBalance ?? Self.defaultWBSlider
            applyHardwareWhiteBalance(value)

        case "captureColor":
            applyRemoteCaptureColor(cfg)

        case "captureColorReset":
            resetCaptureColorAdjustment()
            captureColorRemoteTick &+= 1
            print("🎨 [CaptureColor] PC 重置采集颜色")

        case "pixelLevel", "pixel_level", "last_pixel_level":
            let level = cfg.exposure ?? cfg.brightness
            if cfg.filterEnabled != nil {
                pipelineDefaultsApplied = true
            }
            videoFilter.applyAll(
                brightness: nil,
                contrast: nil,
                saturation: nil,
                sharpness: nil,
                pixelLevel: level,
                enabled: cfg.filterEnabled,
                source: "stomp:\(cfg.ptype)"
            )

        // ⭐ v3 滤镜直推 — STOMP 一跳到位, PC sendConfigUpdate("brightness", {"brightness": v}) 直接到这里
        case "brightness", "contrast", "saturation", "sharpness", "redBoost",
             "blackPoint", "redGlow", "highlightLift", "gamma", "exposure", "chroma":
            if cfg.filterEnabled != nil {
                pipelineDefaultsApplied = true
            }
            videoFilter.applyAll(
                brightness:    cfg.brightness,
                contrast:      cfg.contrast,
                saturation:    cfg.saturation,
                sharpness:     cfg.sharpness,
                redBoost:      cfg.redBoost,
                blackPoint:    cfg.blackPoint,
                redGlow:       cfg.redGlow,
                highlightLift: cfg.highlightLift,
                gamma:         cfg.gamma,
                exposure:      cfg.exposure,
                chroma:        cfg.chroma,
                enabled:       cfg.filterEnabled,
                source:        "stomp:\(cfg.ptype)"
            )

        default:
            print("⚠️ 未知 ptype=\(cfg.ptype)，忽略该项")
        }
        
        // 🔥 记录执行时间
        let executionTime = Date().timeIntervalSince(startTime) * 1000 // 转换为毫秒
        // print("⚡ [applyThinRemoteConfig] 完成: ptype=\(cfg.ptype)")
        // ... existing code ...
    }
    
    func applyThinRemoteConfigInit(_ cfg: ThinRemoteConfig) {
            // 0) 🔥 2026-07-14 低功率采集模式：必须在「1) 档位」之前设置，
            //    这样下面 applyProfileBitrateOnly 触发的首次采集就直接按正确fps启动，不用再等一次 lockFrameRate。
            lowPowerCaptureEnabled = cfg.lowPowerCapture ?? false

            // 1) 档位：5档固定配置 - low/standard/high/ultra/p4k
            let desiredProfile: LadderProfile
            switch cfg.type.lowercased() {
            case "p4k":
                desiredProfile = .p4k
            case "ultra":
                desiredProfile = .ultra
            case "high":
                desiredProfile = .high
            case "standard":
                desiredProfile = .standard
            case "low":
                desiredProfile = .low
            default:
                desiredProfile = .standard
                print("⚠️ [Init] 未知档位 '\(cfg.type)'，使用默认 .standard")
            }
            
            // ✅ 初始化时只设置档位，不尝试切换（因为capturer还不存在）
            currentProfile = desiredProfile
            //print("🎬 初始化档位: \(desiredProfile) (type=\(cfg.type))")
            
            // 如果已经有 capturer（重新加载配置的情况），则尝试切换
            if capturer != nil {
                print("🔔 [触发源:applyThinRemoteConfigInit] 初始化档位: \(desiredProfile)")
                if gentleAdaptMode { applyProfileBitrateOnly(desiredProfile) } else { applyProfile(desiredProfile) }
            }

            // 2) 方向："-1"后置；"1"前置（若不一致则切换一次）
            //print("🔍 初始化 direction 检查: cfg.direction=\(cfg.direction)")
            if let input = capturer?.currentVideoInput {
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
                    let webrtcFps = min(maxFps, f / 4)
                    print("🔄 [推送FPS设置-初始化] 后端: \(f)fps / 4 = \(f/4)fps, 上限: \(maxFps)fps → WebRTC: \(webrtcFps)fps")
                    setAverageOutputFPS(f)
                    enableAverageThrottling(true)
                }
            
            // 4.5) 🔥 快门速度（后端直接下发 60-600）
            if let cj = cfg.cjfps {
                print("📸 [快门速度设置-初始化] 后端: cjfps=\(cj) → 1/\(cj)s")
                setCaptureFrameRate(shutterSpeed: cj)
                }

            // 5) 码率（kbps→百分比，按当前档位上限换算；保底 10%）
            if let pct = cfg.bitrate { setQualityPercentage(pct) }
            
            // 6) 对焦距离 0.0~1.0
            if let f = cfg.focus {
                print("📸 [applyThinRemoteConfigInit] 后端焦距: \(f)，准备应用")
                setFocus(f)
            } else {
                print("📸 [applyThinRemoteConfigInit] 后端未配置焦距")
            }
            
            // print("✅ 已应用 ThinRemoteConfig")
    }
    
    // MARK: - 恢复配置（除对焦外）
    /// 在切换场景（切换档位、切换摄像头）后调用，恢复除对焦外的配置
    /// 需要保持一致的参数：变焦(zoom)、FPS、码率
    /// 不需要恢复：对焦(focus)让用户手动调整、角度(angle)由后端控制
    func reapplyConfigExceptFocus() {
        // print("🔄 [reapplyConfigExceptFocus] 开始")
        
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
        setZoom(zoomValue)
        print("   ✅ 变焦恢复: \(zoomValue)")
        
        // 2) FPS（目标推送FPS）- 使用本地保存的值（已经是 /4 后的值）
        let fpsValue = targetOutputFPS
        let maxPushFps = getMaxPushFpsForCurrentProfile()
        let webrtcFps = min(maxPushFps, fpsValue)
        frameThrottler?.targetSendFps = fpsValue
        print("   ✅ FPS恢复: 推送目标=\(fpsValue)fps, 上限=\(maxPushFps)fps → WebRTC=\(webrtcFps)fps")
        
        // 3) 码率 - min/max 均按档位 + 清晰度百分比
        applyEffectiveBitrateToWebRTC()
        if let pct = lastQualityPercent {
            print("   ✅ 码率恢复: \(pct)% → \(targetMinBitrateKbps)-\(targetBitrateKbps)kbps")
        } else {
            print("   ✅ 码率恢复: 默认 → \(targetMinBitrateKbps)-\(targetBitrateKbps)kbps")
        }
        
        // 注意：角度(angle)由后端控制，不在前端恢复
        // 注意：对焦(focus)单独恢复，见 reapplyFocusFromConfig()
        // print("🔄 [reapplyConfigExceptFocus] 完成")
    }
    
    // MARK: - 从后端配置恢复对焦
    /// 从 ConfigManager 读取后端配置的 focus 值并应用
    /// 切换摄像头后调用，确保对焦恢复到后端设置的值
    func reapplyFocusFromConfig() {
        // print("🔍 [reapplyFocusFromConfig] 开始")
        
        // 🔥 用户手动调整的值优先于后端配置
        if userHasManuallyAdjustedFocus, let savedFocus = savedUserFocusDistance {
            // 用户手动调整过，优先使用用户设置的值
            print("📸 [reapplyFocusFromConfig] 使用用户设置的焦距: \(savedFocus)")
            setFocus(savedFocus)
        } else if let cfg = ConfigManager.shared.getCurrentConfig(), let focusValue = cfg.focus {
            // 用户没调整过，使用后端配置
            print("📸 [reapplyFocusFromConfig] 使用后端配置的焦距: \(focusValue)")
            setFocus(focusValue)
        } else {
            // 🔥 无配置时使用默认值0.6
            print("📸 [reapplyFocusFromConfig] 无焦距配置，使用默认值: 0.6")
            setFocus(0.6)
        }
    }
    
    // MARK: - 唤醒后恢复所有配置（包括对焦）
    /// 休眠唤醒后调用，恢复所有参数（包括对焦）
    /// 唤醒后需要完整还原：变焦、FPS、码率、对焦（自动对焦）
    func reapplyConfigForWake() {
        // print("☀️ [reapplyConfigForWake] 唤醒")
        
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
        setZoom(zoomValue)
        print("   ✅ 变焦恢复: \(zoomValue)")
        
        // 2) FPS（目标推送FPS）- 使用本地保存的值
        let fpsValue = targetOutputFPS
        let maxPushFps = getMaxPushFpsForCurrentProfile()
        let webrtcFps = min(maxPushFps, fpsValue)
        frameThrottler?.targetSendFps = fpsValue
        print("   ✅ FPS恢复: 推送目标=\(fpsValue)fps, 上限=\(maxPushFps)fps → WebRTC=\(webrtcFps)fps")
        
        // 3) 码率 - min/max 均按档位 + 清晰度百分比
        applyEffectiveBitrateToWebRTC()
        if let pct = lastQualityPercent {
            print("   ✅ 码率恢复: \(pct)% → \(targetMinBitrateKbps)-\(targetBitrateKbps)kbps")
        } else {
            print("   ✅ 码率恢复: 默认 → \(targetMinBitrateKbps)-\(targetBitrateKbps)kbps")
        }
        
        // 4) 对焦 - 唤醒后直接恢复保存的焦距（不执行自动对焦）
        if let savedFocus = savedUserFocusDistance {
            print("   ✅ 对焦恢复: \(savedFocus)")
            setFocus(savedFocus)
        } else {
            print("   ✅ 对焦：保持当前焦距（由后端配置控制）")
        }
        
        // print("☀️ [reapplyConfigForWake] 完成")
    }
    
    
    func setQualityPercentage(_ percent: Int) {
            let clamped = max(1, min(100, percent))
            // 吸附到统一阶梯，跨档位统一体验
            let snapped = QUALITY_PERCENT_STEPS.min(by: { abs($0 - clamped) < abs($1 - clamped) }) ?? clamped
            let oldPercent = lastQualityPercent ?? 100
            lastQualityPercent = snapped
            
            if currentLadder[currentProfile] != nil {
                emergencyBitrateScale = 1.0  // 🚨 显式调清晰度，重置弱网紧急降码率系数
                applyEffectiveBitrateToWebRTC()
                enforceBitrateImmediately()
                malvshezhingLog("[码率] 清晰度 \(oldPercent)% → \(snapped)% 目标=\(targetMinBitrateKbps)-\(targetBitrateKbps) kbps")
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
        // 关键：立刻重采集以应用手动 FPS 覆盖（使用采集分辨率，不是输出分辨率）
        let captureRes = getCaptureResolutionForProfile(currentProfile)
        recapture(width: captureRes.width, height: captureRes.height, fps: captureRes.fps)
        //print("🎯 手动 FPS(%) → ", snapped, "fps")
        // ... existing code ...
    }
    
    
    func setFPSValue(_ fps: Int) {
        let clamped = max(10, min(60, fps))
        manualFpsOverride = clamped
        // 关键：立刻重采集以应用手动 FPS 覆盖（使用采集分辨率，不是输出分辨率）
        let captureRes = getCaptureResolutionForProfile(currentProfile)
        recapture(width: captureRes.width, height: captureRes.height, fps: captureRes.fps)
        //print("🎯 手动 FPS =", clamped, "fps")
    }
    
    func clearManualFpsOverride() {
        manualFpsOverride = nil
        //print("🧹 清除手动 FPS 覆盖")
    }
    
    // ✅ 统一根据质量百分比计算当前档位应设的码率（min / max）
    private func kbpsMinForProfile(_ preset: LadderPreset) -> Int {
        guard let pct = lastQualityPercent else { return preset.minKbps }
        return max(100, Int(Double(preset.minKbps) * Double(pct) / 100.0))
    }

    private func kbpsForProfile(_ preset: LadderPreset) -> Int {
        guard let pct = lastQualityPercent else { return preset.maxKbps }
        // 按百分比映射到当前档位的上限码率，避免过低设置
        let result = max(100, Int(Double(preset.maxKbps) * Double(pct) / 100.0))
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
            // print("📋 [后端配置-预览]")
            
            if let serverFps = cfg.fps {
                // 🔥 后端下发的是采集fps，推送fps = 采集fps / 4
                let pushFps = serverFps / 4
                targetOutputFPS = pushFps
                // print("🎯 [初始化-预览] FPS=\(pushFps)")
            } else {
                // print("⚠️ [初始化-预览] 默认FPS")
            }
        } else {
            // print("⚠️ [初始化-预览] 无服务器配置")
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
                        throttler.captureFps = self.currentCaptureFPS   // 🔥 设置采集FPS（整除跳帧）
                        throttler.targetSendFps = self.targetOutputFPS  // 🔥 设置推送FPS
                        throttler.videoFilter = self.videoFilter        // ⭐ 参数管理
                        throttler.setNV12Processor(NV12MetalProcessor())  // ⭐ GPU-native NV12（玉麒麟同链路）
                        throttler.fpsReportHandler = { [weak self] cap, snd in
                                self?.currentCaptureFps = cap
                                self?.currentSendFps = snd
                        }

                        self.frameThrottler = throttler
                        // 🎨 预览初始化前先同步登录下发的三链路开关（避免 LUT/滤镜默认开跑一段）
                        self.syncPipelineSwitchesFromConfig(source: "startPreviewIfNeeded")
                        self.applyPipelineModes()
                        self.capturer = CustomAVCaptureVideoCapturer(delegate: throttler)
                        // print("🔄 [初始化] 创建帧节流器")

                        // 🔥 预览轨道绑定到 previewVideoSource（固定60fps）
                        let previewTrack = self.factory.videoTrack(with: self.previewVideoSource, trackId: "local_preview")
                        self.previewVideoTrack = previewTrack
                        self.previewVideoTrack?.add(self.localView)
                        
                        // 🔥 推送轨道绑定到 videoSource（受后端fps控制）
                        let track = self.factory.videoTrack(with: self.videoSource, trackId: "video0")
                        self.localVideoTrack = track

                        self.currentProfile = useProfile
                        
                        // ✅ 打印前置和后置摄像头支持的所有格式（初始化诊断）
                        let devices = CustomAVCaptureVideoCapturer.captureDevices()
                        
                        // 🔥 诊断：打印所有摄像头设备和最大 FOV 格式
                        // print("📐 ========== 摄像头设备诊断 ==========")
                        // print("📷 可用摄像头设备 (共\(devices.count)个):")
                        for (idx, dev) in devices.enumerated() {
                            let pos = dev.position == .front ? "前置" : (dev.position == .back ? "后置" : "未知")
                            let type = dev.deviceType.rawValue
                            // print("   [\(idx)] \(pos) - \(dev.localizedName)")
                        }
                        
                        // print("\n📐 ========== 所有格式诊断 ==========")
                        
                        if let frontCamera = devices.first(where: { $0.position == .front }) {
                            let frontFormats = CustomAVCaptureVideoCapturer.supportedFormats(for: frontCamera)
                            
                            // print("📱 前置摄像头格式: \(frontFormats.count)个")
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
                            let backFormats = CustomAVCaptureVideoCapturer.supportedFormats(for: backCamera)
                            
                            // print("📱 后置摄像头格式: \(backFormats.count)个")
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
                        // print("\n📐 ========== 4:3 画幅格式 ==========")
                        
                        func print43Formats(camera: AVCaptureDevice, name: String) {
                            let formats = CustomAVCaptureVideoCapturer.supportedFormats(for: camera)
                            // 筛选 4:3 横屏格式（允许一定误差）
                            let formats43 = formats.filter { fmt in
                                let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                                let ratio = Float(dims.width) / Float(dims.height)
                                let isLandscape = dims.width > dims.height
                                return isLandscape && abs(ratio - 4.0/3.0) < 0.05
                            }
                            
                            // print("📱 \(name) 4:3 格式: \(formats43.count)个")
                            
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
                            let formats = CustomAVCaptureVideoCapturer.supportedFormats(for: camera)
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
                            let formats = CustomAVCaptureVideoCapturer.supportedFormats(for: frontCamera)
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
                            let formats = CustomAVCaptureVideoCapturer.supportedFormats(for: ultraWide)
                            if let maxFovFormat = formats.max(by: { $0.videoFieldOfView < $1.videoFieldOfView }) {
                                let dims = CMVideoFormatDescriptionGetDimensions(maxFovFormat.formatDescription)
                                let maxFps = Int(maxFovFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                                print("🌐 超广角摄像头可用! 最大FOV: \(dims.width)x\(dims.height) @\(maxFps)fps FOV=\(String(format: "%.1f", maxFovFormat.videoFieldOfView))°")
                            }
                        } else {
                            print("⚠️ 无超广角摄像头")
                        }
                        
                        // 🔥 检查各摄像头的 zoom 范围
                        print("🔍 Zoom 范围诊断 (CustomAVCaptureVideoCapturer):")
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
                            
                            // 🔥 获取实际采集分辨率（ultra=1280x720, p4k(15+)=1920x1080, 其他=1920x1440）
                            let captureRes = self.getCaptureResolutionForProfile(self.currentProfile)
                            let preset = self.currentLadder[self.currentProfile]
                            
                            print("🎬 [初始化-预览] 当前档位 currentProfile=\(self.currentProfile)")
                                print("🎬 [初始化-预览] 摄像头: \(camera.position == .back ? "后置" : "前置"), 档位: \(self.currentProfile)")
                            print("   采集: \(captureRes.width)x\(captureRes.height)@\(captureRes.fps)fps")
                            print("   输出: \(preset?.width ?? 0)x\(preset?.height ?? 0) (scale=\(preset?.scaleDown ?? 1.0))")
                            
                            self.currentCaptureFPS = captureRes.fps
                            self.currentCaptureWidth = captureRes.width
                            self.currentCaptureHeight = captureRes.height
                        }
                        
                        // ✅ 使用综合码率计算（考虑质量百分比和推送FPS）
                        self.applyEffectiveBitrateToWebRTC()
                        
                        // ✅ 使用实际采集分辨率（不是输出分辨率）
                        if let camera = initialCamera {
                            let captureRes = self.getCaptureResolutionForProfile(self.currentProfile)
                            let preset = self.currentLadder[self.currentProfile]
                            
                            print("═══════════════════════════════════════════════════")
                            print("🎬 [初始化-预览] 开始采集")
                            print("   档位: \(self.currentProfile)")
                            print("   采集分辨率: \(captureRes.width)x\(captureRes.height)@\(captureRes.fps)fps")
                            print("   输出分辨率: \(preset?.width ?? 0)x\(preset?.height ?? 0)")
                            print("   缩放因子: \(preset?.scaleDown ?? 1.0)")
                            print("═══════════════════════════════════════════════════")
                            
                            self.startCaptureWithDevice(camera, width: captureRes.width, height: captureRes.height, fps: captureRes.fps)
                            
                            // 🔥 FrameThrottler 使用采集和输出分辨率
                            self.frameThrottler?.currentProfileName = "\(self.currentProfile)"
                            self.frameThrottler?.expectedCaptureWidth = captureRes.width
                            self.frameThrottler?.expectedCaptureHeight = captureRes.height
                            self.frameThrottler?.expectedOutputWidth = preset?.width ?? captureRes.width
                            self.frameThrottler?.expectedOutputHeight = preset?.height ?? captureRes.height
                            self.frameThrottler?.currentScaleDown = preset?.scaleDown ?? 1.0
                            
                            // 🔥 初始化时设置 WebRTC 缩放
                            self.setResolutionScale(preset?.scaleDown ?? 1.0)
                        }
                        
                        //print("🎬 预览启动: 档位=\(useProfile), 码率=\(kbps)kbps, 摄像头=\(wantFront ? "前置" : "后置")")
                    }
        }
    }
    
    // ✅ 使用指定设备启动采集（根据当前档位采集真实分辨率）
    private func startCaptureWithDevice(_ device: AVCaptureDevice, width: Int, height: Int, fps: Int) {
        print("🔍🔍🔍 [startCaptureWithDevice] 被调用！目标: \(width)x\(height)@\(fps)fps")

        // 更新当前采集分辨率
        currentCaptureWidth = width
        currentCaptureHeight = height
        currentResolutionScale = 1.0  // 不缩放

        print("🎬 [startCaptureWithDevice] 真实采集分辨率: \(width)x\(height)")

        // 🔥🔥 统一使用 findBestFormat 选择格式（与 recaptureWithResolution 完全一致）
        // 修复：初始启动和档位切换使用不同格式选择算法导致非超高帧档位只有30fps
        guard let best = findBestFormat(for: device, targetWidth: width, targetHeight: height, targetFps: fps) else {
            print("❌ [startCaptureWithDevice] 未找到合适的格式")
            return
        }

        let maxFps = Int(best.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
        let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
        applyOutputPixelFormatForCurrentRange()

        // 🔍 打印详细格式信息（用于诊断）
        let pixelFormat = CMFormatDescriptionGetMediaSubType(best.formatDescription)
        let pixelFormatStr = String(format: "%c%c%c%c",
            (pixelFormat >> 24) & 0xFF,
            (pixelFormat >> 16) & 0xFF,
            (pixelFormat >> 8) & 0xFF,
            pixelFormat & 0xFF)
        print("📱 [格式详情] 设备=\(device.localizedName), 分辨率=\(dims.width)x\(dims.height), maxFPS=\(maxFps), 像素格式=\(pixelFormatStr)")

        // 🔥 使用目标fps和格式支持的最大fps中较小的那个
        let useFps = min(fps, maxFps)
        currentCaptureFPS = useFps

        print("🎯档位🎯 选中格式: \(dims.width)x\(dims.height) maxFPS=\(maxFps) → 采集FPS=\(useFps)fps")

        // 🔥 不缩放，真实采集分辨率
        currentResolutionScale = 1.0
        print("   采集: \(dims.width)x\(dims.height)@\(useFps)fps (不缩放)")

        // ✅ 确保推送FPS不超过采集FPS
        if let currentSendFps = frameThrottler?.targetSendFps, currentSendFps > useFps {
            frameThrottler?.targetSendFps = useFps
            targetOutputFPS = useFps
            print("⚠️ 推送FPS(\(currentSendFps)) 超过采集FPS(\(useFps))，已限制为\(useFps)fps")
        }

        capturer.startCapture(with: device, format: best, fps: useFps) { [weak self] in
            guard let self else { return }
            self.configureCameraAutoModes(device)
            self.applyMountTransform()
            self.updatePreviewMirror(isFrontCamera: device.position == .front)
            if let focus = self.pendingFocus {
                self.pendingFocus = nil
                self.setFocus(focus)
                print("🔍 [startCaptureWithDevice] 应用待处理的焦距: \(focus)")
            } else {
                self.reapplyFocusFromConfig()
            }
            // 🎨 首次相机就绪后，按开关运用登录下发的三链路默认值（推流+预览同一处理点）
            self.applyPipelineDefaults(source: "startCaptureWithDevice")
            NotificationCenter.default.post(name: .cameraPreviewReady, object: nil)
        }
    }

    func applyMountTransform() {
        guard let session = capturer?.captureSession else {
            return
        }

        let want: AVCaptureVideoOrientation = .landscapeRight
        var applied = 0
        for conn in session.connections {
            if conn.isVideoOrientationSupported {
                conn.videoOrientation = want
                applied += 1
            }
            if conn.isVideoMirroringSupported {
                conn.isVideoMirrored = streamMirrored
            }
        }

        if let device = capturer?.currentDevice {
            let format = device.activeFormat
            _ = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
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

   
    
    
    // 🔥 2026-07-02: 恢复 High Profile（640c34）。42e01f 是给老 PC（Sandy Bridge 核显）验证用的
    //   临时降档，一直没改回——Baseline 无 8x8 变换/CABAC，同码率画质/压缩效率明显差，弱网下更容易
    //   underbitrate 出块效应。竞品（webrtc-preview）明确开 WebRtcUseH264HighProfile。
    //   若个别老 PC High 硬解失败（GStreamer "Internal data stream error"），临时改回 "42e01f" 或按机型协商。
    private static let forcedH264ProfileLevelId = "640c34"

    private let factory: RTCPeerConnectionFactory = {
            RTCInitializeSSL()
            
            // ⭐ H265：用 H265-enabled 工厂（重写 supportedCodecs 追加 H265，否则 preferredCodec 塞不进 Offer）
            let enc = H265Support.makeEncoderFactory()
            let dec = RTCDefaultVideoDecoderFactory()
            
            // 🔥🔥 画质优化：改用 High Profile（提升远处细节/红牌清晰度）
            // profile-level-id 说明：
            // - 42e01f: Constrained Baseline Level 3.1（最弱，无 8x8 变换/CABAC，细节糊）
            // - 640c34: High Profile Level 5.2（8x8变换+CABAC，同码率细节明显更好；无 B 帧仍低延迟）
            // High Profile 不强制 B 帧（VideoToolbox 推流默认不插 B 帧），延迟基本不变，画质显著提升。
            let codecs = RTCDefaultVideoEncoderFactory.supportedCodecs()
            if let h264 = codecs.first(where: {
                        $0.name.caseInsensitiveCompare(kRTCH264CodecName) == .orderedSame ||
                        $0.name.lowercased().contains("h264")
            }) {
                let compatibleH264 = RTCVideoCodecInfo(
                                name: h264.name,
                                parameters: [
                                   "profile-level-id": WebRTCManager.forcedH264ProfileLevelId,  // High 5.2（含义见常量定义处注释）
                                   "level-asymmetry-allowed": "1",
                                   "packetization-mode": "1"
                               ]
                )
                enc.preferredCodec = compatibleH264
                print("🎯 H.264 preferredCodec profile-level-id=\(WebRTCManager.forcedH264ProfileLevelId)（High 5.2；老 PC 不兼容时改 42e01f）")
                // ⭐ H265 支持（全部逻辑在 H265Support.swift，此处仅注册钩子）：
                //   记下 factory + H264 preferred，P2P 推流时按登录页「P2P编码」选项切换。
                H265Support.shared.registerFactory(encoder: enc, h264Preferred: compatibleH264)
            }
            
            return RTCPeerConnectionFactory(encoderFactory: enc, decoderFactory: dec)
    }()
    private var pc: RTCPeerConnection!
    private var videoSource: RTCVideoSource!           // 🔥 推送用（受后端fps控制）
    private var previewVideoSource: RTCVideoSource!    // 🔥 预览用（固定60fps）
    private var previewVideoTrack: RTCVideoTrack?      // 🔥 预览轨道
    var capturer: CustomAVCaptureVideoCapturer!
    private var videoSender: RTCRtpSender?

    // ⭐ 两种连接方式各自独立管理类，自动协商：能 P2P 就 P2P（省流量），否则 SRS（互斥不混用）
    let p2pManager = P2PManager()
    let srsManager = SRSManager()

    // MARK: - SRT (independent)
    /// SRT 推流管理器（第三条独立链路，方案 A）。删除此属性 + 相关分区即可回退。
    let srtManager = SRTManager()

    /// 后端开关："srs"=强制 SRS；其它(p2p/auto)=自动协商
    private var backendConnectMode: String { (UserDefaults.standard.string(forKey: "connect_mode") ?? "auto").lowercased() }
    private var backendForceSRS: Bool { backendConnectMode == "srs" }

    /// 当前生效连接方式（0=SRS,1=P2P），供 WebSocketManager 心跳上报；PC 跟随此值
    static var effectiveConnectstype: Int = 0
    /// 当前会话实际模式
    enum ConnMode { case none, p2p, srs, srt }
    private var currentConnMode: ConnMode = .none

    /// 观看者注册表：pcDeviceId → 最近心跳时间/网络类型（PC 每 ~1.5s 发 VIEWER_HEARTBEAT）
    private var viewerRegistry: [String: (lastSeen: Date, net: String)] = [:]
    /// ⛔ 自动协商已废弃，仅保留定时器引用以兼容历史调用点（不再实际调度）
    private var modeEvalTimer: Timer?

    /// 当前观看者数（注册表 + P2P 活动会话取大）
    private var currentViewerCount: Int {
        let regCount = viewerRegistry.count
        return max(regCount, p2pManager.viewerCount)
    }
    
    // 记录当前采集FPS
    private var currentCaptureFPS: Int = 60 {
        didSet {
            // 🔥 同步更新 FrameThrottler 的采集FPS（确保整除跳帧正确）
            if oldValue != currentCaptureFPS {
                frameThrottler?.captureFps = currentCaptureFPS
                print("📊 [采集FPS变化] \(oldValue) → \(currentCaptureFPS)fps")
            }
            // ⭐ 2026-07-14：同步回报给 PC（走 CONFIG_STATE 心跳）——之前 PC 完全看不到实际采集fps，
            //   现在不管是低功率开关、切档、自适应、set_fps 哪条路径改的，这里唯一收口都会同步。
            WebSocketManager.publishingCaptureFps = currentCaptureFPS
        }
    }
    
    // 🔥 推送FPS硬上限
    private let maxAllowedPushFps: Int = 60
    
    // 🔥 存储目标推送FPS（即使 frameThrottler 被重新创建也能恢复）
    private var targetOutputFPS: Int = 60  // 默认值60
    
    // 🔥 快门速度值（后端下发 60-600，直接应用）
    // 60 = 1/60s, 600 = 1/600s
    @Published var cjfpsValue: Int = 240  // 默认 1/240s

    // 自动 ISO 闭环 (S 档: 快门固定, ISO 跟随光线)
    @Published var autoIsoEnabled: Bool = false {
        didSet {
            if oldValue == autoIsoEnabled { return }
            if autoIsoEnabled {
                startAutoIsoLoop()
            } else {
                stopAutoIsoLoop()
                setCaptureFrameRate(shutterSpeed: cjfpsValue, forceApply: true)
            }
        }
    }
    private var autoIsoTimer: Timer?

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
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - 🔥 自适应FPS算法（基于丢包率动态调整推流FPS）
    // ═══════════════════════════════════════════════════════════════════════════
    // 算法原理：
    // 1. 检测丢包率 > 阈值，连续N秒 → 降低FPS
    // 2. 检测丢包率 < 阈值，连续M秒 → 恢复FPS
    // 3. FPS变化时通知PC端，PC端调整缓存策略
    
    /// 自适应FPS开关（默认开启，基于丢包率动态调整推流FPS）
    var adaptiveFpsEnabled: Bool = true

    /// 抗频闪模式（PC端控制，开启后锁定FPS，自适应不触发）
    var antiFlickerEnabled: Bool = false
    var antiFlickerFps: Int = 20  // 实际帧率（80/4=20, 100/4=25, 200/4=50）
    var lutModeEnabled: Bool = false       // LUT 开关（默认关，等登录 iosPipeline 下发）
    var filterModeEnabled: Bool = false   // Metal 滤镜栈（默认关，PC 可开）
    var hardwareBrightnessSliderValue: Int = 20  // 后台 test_brightness value 0...100，20=0EV
    var hardwareWBSliderValue: Int = 50          // 后台 white_balance value 0...100，50=5000K
    private var pendingLutName: String?
    
    /// 当前自适应FPS值（独立于后端下发的targetOutputFPS）
    private var adaptiveFps: Int = 30
    
    /// 🔥🔥 v2.1 自适应FPS重构（修复200ms/1s时间单位错配问题）
    /// 核心改进：
    /// 1. 丢包率用3秒移动平均（防突发抖动误触发）
    /// 2. 移除bitrateRatio判断（避免连锁降帧）
    /// 3. RTT=0当"中等"（不是好也不是差）
    /// 4. 升降帧后3秒冷却期（防止抖动）
    /// 5. 计数器以"秒"为单位，每秒只更新一次
    
    private let minAdaptiveFps: Int = 15     // 最低15fps（弱网最低档）
    private let minCaptureFps: Int = 15      // 최저 camera capture fps (발열/화면 끊김 균형)

    /// 🚨 弱网紧急降码率系数（1.0=不降）。当 fps 已到最低档仍持续网络差时，逐级把
    /// min/max 码率往下压，缓解发送队列堆积（bufferbloat/RTT 飙升导致的断流）；
    /// 网络恢复后逐级升回 1.0。档位切换/清晰度变更等显式指令会重置为 1.0。
    private var emergencyBitrateScale: Double = 1.0
    private let emergencyBitrateMinScale: Double = 0.2   // 最低压到基准的 20%（如 low 档 1500→300kbps）
    private let emergencyBitrateStepDown: Double = 0.7   // 每次下压 ×0.7
    private let emergencyBitrateStepUp: Double = 0.15    // 恢复每次 +0.15

    // ⭐ §53.21：原「中继码率钳制(p2pPathIsRelay/relayMaxKbps) + 链路择优限频(lastRelaySwitchAt/
    //   relaySwitchGapSec)」已随 TURN 中继物理删除——P2P 只有局域网直连，无中继路径可钳可切。
    /// ⭐ §52.6：本次推流会话内「非同 WiFi」只处理一次，防止 stats 每秒重复发通知
    var notSameWifiHandled = false
    // maxAdaptiveFps 动态取值：使用 targetOutputFPS（后端下发的推送FPS）作为上限

    /// 帧率档位表（直接切档，不逐步微调）
    /// 🔥 2026-07-02 加密阶梯：原 [60,30,20,15] 一步从 60 跳 30（掉一半），弱网抖动时反复大跳
    ///   观感就是「一顿一顿」。加密为逐级降，每步降幅 ≤1/3，弱网过渡平滑。
    private let fpsLadder: [Int] = [60, 45, 30, 24, 20, 15]

    /// 丢包率阈值（基于3秒移动平均）
    private let lossRateDownThreshold: Double = 0.025   // 3秒均值>2.5%，降级
    private let lossRateUpThreshold: Double = 0.01      // 3秒均值<1%，恢复

    /// RTT阈值（SRS 多一跳，比 P2P 宽松）
    private let rttDownThreshold: Int = 200    // RTT>200ms 网络差
    private let rttUpThreshold: Int = 100      // RTT<100ms 且 >0 网络好

    /// 档位切换核心参数
    private let downgradeHoldSec: Int = 1     // 连续1秒网络差 → 降级（快速响应）
    private let upgradeHoldSec: Int = 3       // 连续3秒网络好 → 升级
    private let cooldownAfterDown: Double = 1.0  // 降帧后冷却1秒
    private let cooldownAfterUp: Double = 2.0    // 升帧后冷却2秒

    /// 步长设计：档位切换（直接减半/翻倍）
    // fpsDownStep/fpsUpStep 已废弃，改用 fpsLadder 档位切换
    
    /// 🔥 v2.1 丢包率移动平均（3秒窗口）
    private var lossRateHistory: [Double] = []
    private let lossRateHistorySize: Int = 3  // 保留最近3秒
    
    /// 连续计数器（每秒更新一次）
    private var highLossCounter: Int = 0
    private var lowLossCounter: Int = 0

    /// 上次FPS变化时间和方向（冷却期保护）
    private enum FpsDirection { case up, down }
    private var lastFpsChangeTime: Date = Date.distantPast
    private var lastFpsDirection: FpsDirection = .down
    
    /// 🔥 v2.1 上次自适应逻辑执行时间（确保每秒只执行一次）
    private var lastAdaptiveProcessTime: Date = Date.distantPast

    /// ⭐ 2026-07-03 §25.5-2：「RTT 单因素判差但丢包干净」防锁死保护。
    ///   实测（GStreamer 拉流端）：RR 反馈被污染成恒定 450ms → 旧逻辑降帧到底 + 码率压到 0.2 后
    ///   永远等不到「网络好」，15fps/300kbps 锁死直到断开。真拥塞必然伴随丢包（UDP 路径），
    ///   丢包持续干净时 RTT 读数按「可疑」处理：压制减半深度 + 周期试探回升，真拥塞出丢包会立即回压。
    private var rttOnlyBadSeconds: Int = 0            // RTT差但丢包干净的连续秒数
    private var rttOnlyEpisodeDropped: Bool = false   // 本轮 RTT-only 期间已降过一档 fps
    private let rttOnlyProbeSec: Int = 15             // 丢包干净持续 N 秒后开始试探回升
    private let rttOnlyProbeIntervalSec: Int = 10     // 之后每 N 秒试探一次
    private let rttOnlyEmergencyFloor: Double = 0.7   // RTT-only 时紧急码率系数最低只压一步（vs 常规 0.2）
    
    /// 上次通知PC端的FPS（避免重复发送）
    private var lastNotifiedFps: Int = 0
    
    /// 🔥 后端消息设置FPS后，暂停自适应1秒（避免冲突）
    private var lastRemoteFpsTime: Date = Date.distantPast
    
    // 🚑 2026-07-02 切档卡死修复：采集看门狗。
    //   切档 = 相机会话整拆重建，偶发失败（AVCaptureDeviceInput 抛错 / canAddInput=false /
    //   runtime error）后原代码无任何恢复路径 → 推流中画面永久卡死。
    //   看门狗每 2s 检查一次：推流中（非休眠）连续 ≥3s 无采集帧 → 让 capturer 用最近一次
    //   配置整体重建会话，恢复后补一拍 IDR。恢复动作 10s 节流，防重建风暴。
    private var captureWatchdogTimer: Timer?
    private var lastCaptureRecoveryTime: CFAbsoluteTime = 0
    private let captureWatchdogGapSec: Double = 3.0
    private let captureRecoveryMinIntervalSec: Double = 10.0

    // 🔥🔥 关键帧定时器（v10.1防花屏：极端弱网GOP=0.5秒）
    // 方案要求：GOP越短，花屏恢复越快。极端弱网必须0.5秒
    private var keyframeTimer: Timer?
    private var keyframeIntervalSec: Double = 0.5  // 🔥 v10.1: 极端弱网推荐0.5秒（可动态调整）

    // ⭐ 2026-06-25 发热优化：短 GOP 定时器的自动归位
    //   弱网（critical/high）临时启用短 GOP 后，由该 work 在 keyframeTimerAutoStopSec 秒后
    //   自动 stopKeyframeTimer 回到常态（长 GOP + 按需 PLI），避免短 GOP 常驻持续发热。
    private var keyframeAutoStopWork: DispatchWorkItem?
    private let keyframeTimerAutoStopSec: Double = 5.0  // 弱网短 GOP 持续时间，超时自动归位

    // ⭐ 2026-06-25 发热优化：观看端 PLI / REQUEST_KEYFRAME 节流
    //   P2P 直连时观看端一卡就连发 PLI，每个 PLI → forceKeyframe 重编 IDR，会把编码器打爆。
    //   这里限制最小间隔，窗口内只响应一次，避免「短时间多个 PLI → 多个 IDR」的发热风暴。
    private var lastForceKeyframeTime: Date = .distantPast
    private let forceKeyframeMinIntervalSec: Double = 1.0
    
    // 🔥 v10.1: GOP动态调整（根据网络状况）
    private let gopNormal: Double = 1.0      // 正常网络：1秒
    private let gopWeak: Double = 0.5        // 弱网：0.5秒
    private let gopExtreme: Double = 0.5     // 极端弱网：0.5秒
    
    // ❌ 自动档位调整已完全禁用 - 档位控制方式：
    // 1. 后端推送：ptype="type", type="high"/"standard"
    // 2. UI手动：ContentView 的 ↑升档/↓降档 按钮
    // 3. 初始化：startPreviewIfNeeded/startPublish 的 initialProfile 参数
    private var autoAdaptEnabled = false  // 固定为false，不可修改
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - 🔥 2026-07-14 低功率采集模式（PC「相机设定」面板新增，还原按钮旁的开关）
    // ═══════════════════════════════════════════════════════════════════════════
    // 背景：目前所有档位（low/standard/high/p4k）採集恒定 60fps（ultra 更高达120/240fps），
    //   耗电/发热主要来源之一就是采集侧。PC 新增「低功率/高功率」开关，iOS 收到后自行判断：
    //   低功率 = 采集帧率钉死 30fps（不管当前档位）；高功率 = 按档位原有 fps 不变（现网行为）。
    //   ⚠️ 只影响「采集」fps，PC 下发的「推送(push)」fps 逻辑完全不动——两者本就解耦
    //   （LadderPreset.fps=采集、maxPushFps/推送侧走 targetOutputFPS，互不牵连）。
    //
    // 🔥 采集 fps 决策口径统一收口：全项目所有实际调用 capturer.startCapture/switchCapture/
    //   lockFrameRate 的地方，理论上都必须经过 getCaptureResolutionForProfile(_:).fps 或
    //   effectiveCaptureFps(_:) 换算，不允许再直接读 preset.fps——否则低功率开关会在那个分支失效。
    //   （审计发现 applyProfileBitrateOnly 里有一处历史遗留直接用 preset.fps，已改用换算后的值。）
    @Published var lowPowerCaptureEnabled: Bool = false {
        didSet {
            // ⭐ 2026-07-14：状态变化即回报给 PC（走 CONFIG_STATE 心跳，几秒内到达；
            //   之前只下发不回报，PC 端完全看不到有没有生效）
            WebSocketManager.publishingLowPowerCapture = lowPowerCaptureEnabled
        }
    }
    private let lowPowerCaptureFpsCap: Int = 30

    /// 采集 fps 唯一换算口径：低功率开启时钉 30（或更低的原始值，取小），否则原样返回。
    func effectiveCaptureFps(_ rawFps: Int) -> Int {
        return lowPowerCaptureEnabled ? min(rawFps, lowPowerCaptureFpsCap) : rawFps
    }

    // 温和自适应：只改码率不上下采集档位，避免重启采集闪烁
   var gentleAdaptMode = true
   private var lastAdaptAt: TimeInterval = 0
   private let ADAPT_MIN_INTERVAL_SEC: TimeInterval = 8

    // 阈值（这些阈值已无效，因为自动调整已禁用）
    private let BAD_KBPS_FACTOR: Double = 0.60
    private let BAD_FPS_FACTOR:  Double = 0.80
    private let BAD_HOLD_SEC = 4
    private let GOOD_HOLD_SEC = 15

    // 手动对焦距离（默认0.6，与后端默认值一致）
    @Published var focusDistance: Float = 0.0  // 0.0~1.0，默认超焦距（远近都清楚）
    private var pendingFocus: Float?
    private var userHasManuallyAdjustedFocus = false  // ✅ 标记用户是否手动调整过对焦
    private var savedUserFocusDistance: Float?  // 🔥 保存用户设置的对焦距离（用于自动对焦后恢复）
    
    // 🔥 本地保存的变焦值（用于切换档位/摄像头时恢复）
    // 🔥 默认 1.0 标准焦距（范围 1.0-3.0）
    private var currentZoomFactor: CGFloat = 1.0
    
    // 🔥 对外暴露的当前 zoom 值（用于 UI 显示，范围 1.0-3.0）
    @Published var currentZoom: CGFloat = 1.0
    
    // 🔥 分辨率缩放比例（用于热切换分辨率，不断流）
    // 1.0 = 1920x1080, 1.5 = 1280x720
    private var currentResolutionScale: Double = 1.0
    
    // 🔥 基础采集高度：所有设备统一 1920x1440 (4:3)
    // iPhone 15+ 超高清档位通过 scaleDown 缩放，不改变采集分辨率
    private let baseCaptureHeight: Int = 1440
    
    // 🔥 当前采集分辨率（根据档位动态变化）
    // iPhone 15+: 1920x1080 (16:9), iPhone 14-: 1920x1440 (4:3)
    private var currentCaptureWidth: Int = 1920
    private var currentCaptureHeight: Int = 1440
    
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
        
        // 🔥 计算快门速度上限（取 16:9 和 4:3 的最小值，再和 900 比较）
        WebRTCManager.calculateMaxShutterSpeed()
        
        loadTokenIfNeeded() // 动态流名：使用你的读取逻辑
        NotificationCenter.default.addObserver(self, selector: #selector(onLogoutRequired),
                                               name: NSNotification.Name("LogoutRequired"), object: nil)
        
        // 🔥 强制重新加载本地缓存的配置（确保获取最新的）
        ConfigManager.shared.loadCachedThinConfig()
        
        if let cached = ConfigManager.shared.getCurrentConfig() {
            print("🎬 [WebRTCManager.init] 发现缓存配置，档位=\(cached.type)")
            applyThinRemoteConfigInit(cached)
            print("🎬 [WebRTCManager.init] 初始化后 currentProfile=\(currentProfile)")
        } else {
            print("🎬 [WebRTCManager.init] 无缓存配置，使用默认档位 currentProfile=\(currentProfile)")
        }
        
        NotificationCenter.default.addObserver(
                self,
                selector: #selector(onThinConfigUpdated(_:)),
                name: .thinConfigUpdated,
                object: nil
        )
        
        // 🔥 v2.0: 监听 PC 端 set_fps 指令
        NotificationCenter.default.addObserver(
                self,
                selector: #selector(onSetFpsRequested(_:)),
                name: .setFpsRequested,
                object: nil
        )

        // ⭐ 监听视频滤镜热更新 (登录下发 / STOMP 推送 / UI 滑块)
        NotificationCenter.default.addObserver(
                self,
                selector: #selector(onVideoFilterUpdated(_:)),
                name: NSNotification.Name("videoFilterUpdated"),
                object: nil
        )

        // 抗频闪指令监听（PC端控制）
        NotificationCenter.default.addObserver(
                self,
                selector: #selector(onAntiFlickerCommand(_:)),
                name: NSNotification.Name("AntiFlickerCommand"),
                object: nil
        )

        // 🔑 P0-1 关键帧请求监听（PC RTCP PLI 的 WebSocket 兜底）
        NotificationCenter.default.addObserver(
                self,
                selector: #selector(onRequestKeyframeCommand(_:)),
                name: NSNotification.Name("RequestKeyframeCommand"),
                object: nil
        )

        // PC 拉流心跳监听
        NotificationCenter.default.addObserver(
                self,
                selector: #selector(onViewerHeartbeat(_:)),
                name: NSNotification.Name("ViewerHeartbeat"),
                object: nil
        )
        // ⭐ §53.2 PC 在线心跳监听（PC_PRESENCE，1s 一条、与画面无关）
        NotificationCenter.default.addObserver(
                self,
                selector: #selector(onPCPresence(_:)),
                name: NSNotification.Name("PCPresence"),
                object: nil
        )
        viewerHeartbeatChecker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let elapsed = Date().timeIntervalSince(self.lastViewerHeartbeatTime)
            if elapsed > 3.0 && self.viewerConnected {
                self.viewerConnected = false
                print("📺 [VIEWER] 心跳超时，PC 未连接")
            }
            // ⭐ §53.2 清理离线 PC（>4s 无 PC_PRESENCE）。
            //   注意：PC 掉线**不**触发重新协商（它可能只是重启一下，为此重启推流是自伤）——
            //   等它回来时若网段变了，updatePresence 那条路径才会重新协商（§53.4.3）。
            if SessionPolicy.shared.removeStalePresence() {
                print("🖥 [PC在线] 有 PC 心跳超时下线，剩余 \(SessionPolicy.shared.onlineViewerCount) 台")
            }
            self.refreshPCPresenceState()
            // ⭐ 清理过期观看者（>4s 无心跳）
            let now = Date()
            let before = self.viewerRegistry.count
            self.viewerRegistry = self.viewerRegistry.filter { now.timeIntervalSince($0.value.lastSeen) <= 4.0 }
            if self.viewerRegistry.count != before { self.evaluateConnectMode(reason: "viewer-change") }
        }

        // 测试模式监听（PC端 LUT 开关）
        NotificationCenter.default.addObserver(
                self,
                selector: #selector(onTestModeCommand(_:)),
                name: NSNotification.Name("TestModeCommand"),
                object: nil
        )

        // 硬件亮度滑块（ISO/EV，不受滤镜/LUT 开关影响）
        NotificationCenter.default.addObserver(
                self,
                selector: #selector(onTestBrightnessCommand(_:)),
                name: NSNotification.Name("TestBrightnessCommand"),
                object: nil
        )

        // 白平衡滑块（色温 2000K-8000K）
        NotificationCenter.default.addObserver(
                self,
                selector: #selector(onWhiteBalanceCommand(_:)),
                name: NSNotification.Name("WhiteBalanceCommand"),
                object: nil
        )

        // ⭐ 两种连接管理类（P2P / SRS）的数据源
        p2pManager.dataSource = self
        srsManager.dataSource = self

        // ⭐ §53.4.3：决策输入变化 → 停推流 → 重新决策 → 起推流（冷却/次数上限在 SessionPolicy）
        SessionPolicy.shared.onRenegotiateNeeded = { [weak self] reason in
            Task { @MainActor [weak self] in
                self?.renegotiateSession(reason: reason)
            }
        }

        // ⭐ §53.4.3 / §53.12：本机切网（WiFi↔蜂窝/换 WiFi）。
        //   ① 只给 SessionPolicy 打"待重新决策"标记，不在此刻评估（切网瞬间输入最不可靠，
        //      且会与切网自愈抢着重启推流 —— Android 上实测就是切网后不出画面）。
        //   ② 延迟做一次推流健康检查：**P2P 有专门的切网恢复**（P2PManager 拆会话+HANGUP 让 PC 重连），
        //      但 **SRS 模式此前在 iOS 上切网后完全没有恢复路径**——PeerConnection 早死了也没人重推，
        //      观看端就一直黑。3s 延迟是等 WS 重连与 ICE 状态稳定，避免在半就绪状态上误判。
        p2pManager.onLocalNetworkChange = { [weak self] in
            SessionPolicy.shared.onLocalNetworkChanged()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                Task { @MainActor in self?.publishHealthCheck("切网") }
            }
        }
        // ⭐ §53.19：P2P 已改为**纯局域网直连**（无 TURN/STUN，见 P2PManager.createViewerSession）。
        //   非同 WiFi 的会话没有任何可用候选、ICE 必然失败 —— 失败重试耗尽就是"确认不在局域网"，
        //   必须回落 SRS（原来这里 no-op 是"连接方式静态"时代的口径，现在会造成永远黑屏）。
        //   forceSrsForSession 自带冷却/钉住，本次会话不会再回 P2P。
        p2pManager.onViewerPermanentlyFailed = { pcId in
            SessionPolicy.shared.forceSrsForSession(reason: "P2P ICE 失败重试耗尽(\(pcId))，无中继=确认非局域网")
        }
        // ⭐ 切网重连：置"重连中"（左上角显示），PC 重连成功后由 viewerConnected 心跳清除
        p2pManager.onNetworkSwitchReconnect = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.p2pReconnecting = true
                self.viewerConnected = false
            }
        }
    }

    /// ⭐ 视频滤镜热更新 — 服务端旧字段 brightness/sharpness/redBoost 与新字段 blackPoint/redGlow/highlightLift/gamma/exposure 都接受
    @objc private func onVideoFilterUpdated(_ notification: Notification) {
        guard let info = notification.userInfo else { return }
        videoFilter.applyAll(
            brightness:    (info["brightness"]    as? NSNumber)?.floatValue,
            contrast:      (info["contrast"]      as? NSNumber)?.floatValue,
            saturation:    (info["saturation"]    as? NSNumber)?.floatValue,
            sharpness:     (info["sharpness"]     as? NSNumber)?.floatValue,
            redBoost:      (info["redBoost"]      as? NSNumber)?.floatValue,
            blackPoint:    (info["blackPoint"]    as? NSNumber)?.floatValue,
            redGlow:       (info["redGlow"]       as? NSNumber)?.floatValue,
            highlightLift: (info["highlightLift"] as? NSNumber)?.floatValue,
            gamma:         (info["gamma"]         as? NSNumber)?.floatValue,
            exposure:      (info["exposure"]      as? NSNumber)?.floatValue,
            enabled:       info["enabled"] as? Bool,
            source:        (info["source"] as? String) ?? "notification"
        )
    }
    
    // MARK: - 计算快门速度上限
    /// 遍历前后置摄像头的 16:9 和 4:3 格式，取最快快门的最小值，再和 900 比较
    static func calculateMaxShutterSpeed() {
        var minShutter16x9 = Int.max
        var minShutter4x3 = Int.max
        
        let devices = CustomAVCaptureVideoCapturer.captureDevices()
        
        for device in devices {
            let formats = CustomAVCaptureVideoCapturer.supportedFormats(for: device)
            
            for format in formats {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let w = Int(dims.width)
                let h = Int(dims.height)
                
                // 计算宽高比
                let ratio = Double(w) / Double(h)
                let is16x9 = abs(ratio - 16.0/9.0) < 0.1
                let is4x3 = abs(ratio - 4.0/3.0) < 0.1
                
                // 获取最快快门（minExposureDuration）
                let minExposure = format.minExposureDuration
                let shutterSpeed = Int(1.0 / CMTimeGetSeconds(minExposure))
                
                if is16x9 {
                    minShutter16x9 = min(minShutter16x9, shutterSpeed)
                } else if is4x3 {
                    minShutter4x3 = min(minShutter4x3, shutterSpeed)
                }
            }
        }
        
        // 取 16:9 和 4:3 的最小值
        var result = min(minShutter16x9, minShutter4x3)
        
        // 再和 900 比较取最小
        result = min(result, 900)
        
        // 确保至少有个合理值
        if result == Int.max || result < 90 {
            result = 240  // 默认值
        }
        
        maxShutterSpeed = result
        
        print("📸 [快门上限计算] 16:9最快=1/\(minShutter16x9)s, 4:3最快=1/\(minShutter4x3)s → 取最小再和900比较 → 上限=1/\(result)s")
    }
    
    @objc private func onThinConfigUpdated(_ note: Notification) {
            // 优先使用消息里携带的 cfg
            if let cfg = note.userInfo?["cfg"] as? ThinRemoteConfig {
                // 🔥 确保在主线程立即执行，不使用 async（避免延迟）
                if Thread.isMainThread {
                    print("📨 [WebRTCManager] 收到配置更新通知（主线程）: ptype=\(cfg.ptype)")
                    self.applyThinRemoteConfig(cfg)
                } else {
                    // 🔥 使用 async 避免阻塞（sync 可能导致卡顿）
                    DispatchQueue.main.async {
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
    
   
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - 🔥 简化版档位切换（重写）
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// 🔥 切换档位（4:3档位只改缩放，16:9档位需重采集）
    /// - Parameter p: 目标档位
    func applyProfileBitrateOnly(_ p: LadderProfile) {
        print("═══════════════════════════════════════════════════")
        print("🎯 [档位切换] 请求: \(p)")
        
        // 1️⃣ 获取档位预设
            guard let preset = currentLadder[p] else {
            print("   ❌ 未找到档位 \(p) 的预设")
                return
            }
            
            let oldProfile = currentProfile
        let oldPreset = currentLadder[oldProfile]
        print("   当前: \(oldProfile) → 目标: \(p)")
        print("   输出分辨率: \(preset.width)x\(preset.height)@\(preset.fps)fps, scaleDown=\(preset.scaleDown)")
        
        // 2️⃣ 检查是否需要切换
        if oldProfile == p {
            print("   ⏭️ 档位无变化，跳过")
                return
            }
            
        // 3️⃣ 更新档位
            currentProfile = p
        
        // 4️⃣ 设置码率（min/max 均按档位 + 清晰度百分比）
        emergencyBitrateScale = 1.0  // 🚨 显式切档，重置弱网紧急降码率系数
        applyEffectiveBitrateToWebRTC()
        enforceBitrateImmediately()
        malvshezhingLog("[码率] 档位切换 \(oldProfile)→\(p) 目标=\(targetMinBitrateKbps)-\(targetBitrateKbps) kbps")
            
        // 5️⃣ 更新 FrameThrottler（采集和输出分辨率）
        let captureRes = getCaptureResolutionForProfile(p)
            frameThrottler?.currentProfileName = "\(p)"
        frameThrottler?.expectedCaptureWidth = captureRes.width
        frameThrottler?.expectedCaptureHeight = captureRes.height
        frameThrottler?.expectedOutputWidth = preset.width
        frameThrottler?.expectedOutputHeight = preset.height
        frameThrottler?.currentScaleDown = preset.scaleDown
        
        // 6️⃣ 🔥 判断是否需要重采集
        // 不同档位的采集分辨率不同时需要重采集：
        // - ultra: 1280x720 (16:9)
        // - p4k iPhone 15+: 1920x1080 (16:9)
        // - 其他: 1920x1440 (4:3)
        let oldCaptureRes = getCaptureResolutionForProfile(oldProfile)
        let newCaptureRes = getCaptureResolutionForProfile(p)
        let needRecapture = (oldCaptureRes.width != newCaptureRes.width || oldCaptureRes.height != newCaptureRes.height)

        if needRecapture {
            // 🔥 需要重采集（采集分辨率发生变化）
            // ⭐ 2026-07-14 修复：这里原来直接用 preset.fps（绕开 getCaptureResolutionForProfile
            //   的低功率换算），改用 newCaptureRes.fps（= effectiveCaptureFps(preset.fps)），
            //   否则低功率开关在「切档触发重采集」这条路径上会失效，只有初始启动/切摄像头生效。
            print("   🔄 需要重采集: \(oldCaptureRes.width)x\(oldCaptureRes.height) → \(newCaptureRes.width)x\(newCaptureRes.height)")
            recaptureWithResolution(width: newCaptureRes.width, height: newCaptureRes.height, fps: newCaptureRes.fps)
        } else {
            // 🔥 同采集分辨率，只需改 scaleResolutionDownBy
            print("   ✅ 同采集分辨率切换，只改缩放比例: \(oldPreset?.scaleDown ?? 1.0) → \(preset.scaleDown)")
            setResolutionScale(preset.scaleDown)

            // 更新采集分辨率记录（实际采集不变）
            currentCaptureWidth = newCaptureRes.width
            currentCaptureHeight = newCaptureRes.height
        }
        
        // 7️⃣ 恢复变焦等配置
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.reapplyConfigExceptFocus()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + (needRecapture ? 0.7 : 0.05)) { [weak self] in
            self?.applyPipelineDefaults(source: "profileSwitch-final")
        }

        // 8️⃣ 🔥 切换后发送关键帧（解决绿幕问题）
        //   ⚠️ 仅「同采集分辨率」分支用主线程固定延时发 IDR —— 该分支 setResolutionScale 是同步生效、
        //   帧不断流，100/200ms 后必有新帧，发 IDR 安全。
        //   「需要重采集」分支(needRecapture)的 IDR 已改由 recaptureWithResolution 的
        //   startCapture completion 回调发送（= 后台重配置真正完成、新格式开始产帧之后），
        //   这里不能再用固定延时发 —— 否则又会在换格式空窗期把 IDR 浪费掉，导致 P2P 切挡位冻住/超高清条纹。
        if !needRecapture {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.forceKeyframe()
                print("🔑 [档位切换] 100ms 后发送第一次关键帧（同采集分辨率分支）")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.forceKeyframe()
                print("🔑 [档位切换] 200ms 后发送第二次关键帧（同采集分辨率分支）")
            }
        } else {
            print("🔑 [档位切换] 重采集分支：IDR 交由 recaptureWithResolution 重配置完成回调发送（避免空窗期浪费 IDR）")
        }
        
        print("🎯 [档位切换] 完成: \(oldProfile) → \(p)")
        print("═══════════════════════════════════════════════════")
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
        
        // ⭐ P2P诊断日志上报（总后台开关控制）：按推流ID分流，tee stdout 过滤 P2P 相关 print 行
        P2PLogReporter.shared.start(streamId: streamKey)
        
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

        // ⭐ §53.4.1 宽限期：推流那一刻若还没收到任何 PC_PRESENCE（两端登录有先后，
        //   刚开机时消息可能还在路上），等 2s 再决策一次——否则"其实同 WiFi"却因消息未到白走 SRS。
        //   只等一次，等不到就按 SRS（对任何网络都成立的安全默认）。
        if SessionPolicy.shared.shouldWaitForPresence() {
            let grace = SessionPolicy.shared.presenceGraceSec
            print("🧭 [链路决策] 暂未收到观看端在线心跳，等 \(grace)s 再定案（避免同 WiFi 被误判成跨网）")
            DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak self] in
                self?.startPublish(initialProfile: initialProfile)
            }
            return
        }

        // ⭐ §53.4-定稿：**推流前一次定案** mode + codec（决策逻辑全在 SessionPolicy.swift）。
        //   输入 = PC_PRESENCE 心跳带来的「观看端网段 + 能否收 H265」+ 服务器默认编码 + 本机硬编能力。
        //   登录页不再让用户选线路/编码；推流中也不再切换（切网/换观看端 → 走重新协商，见 onRenegotiateNeeded）。
        let decision = SessionPolicy.shared.decideForPublish(
            deviceCanEncodeH265: H265Support.deviceCanEncodeHEVC())
        connectReason = decision.reason
        WebSocketManager.connectReason = decision.reason   // 随 CONFIG_STATE 上报给 PC 顶栏显示

        if decision.mode == .p2p {
            currentConnMode = .p2p
            WebRTCManager.effectiveConnectstype = 1
            // ⭐ H265：按定案编码切 preferredCodec（H265Support.swift 内聚全部逻辑）
            H265Support.shared.applyDecidedCodec(decision.codec, mode: "P2P")
            startP2PPublish(initialProfile: initialProfile)
            return
        }
        // MARK: - SRT (independent)
        // ⭐ §53.4-定稿：SRT 已退役（登录页去掉选项、决策也不再产出 SRT）。
        //   SRTManager / startSRTPublish 全部保留为死代码，便于回滚——
        //   退役理由：SRS 6.0.184 的 RTMP→RTC 桥写死丢弃 HEVC（§49.6-9），SRT+H265 必黑屏，
        //   而默认编码已改 H265，这条链路没有可用组合。
        currentConnMode = .srs
        WebRTCManager.effectiveConnectstype = 0
        // ⭐ 按定案编码切 preferredCodec（SRS 与 P2P 同一套 WebRTC 工厂）
        H265Support.shared.applyDecidedCodec(decision.codec, mode: "SRS")
        
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
                // 🔥 后端下发的是采集fps，推送fps = 采集fps / 4
                // 使用 setAverageOutputFPS 确保 frameThrottler 也被更新
                setAverageOutputFPS(serverFps)
                enableAverageThrottling(true)
                print("mm: 档位=\(currentProfile), 初始化FPS: 后端=\(serverFps)/4=\(serverFps/4) → targetOutputFPS=\(targetOutputFPS)fps")
            } else {
                print("⚠️ [初始化-推流] 缓存无FPS，使用默认值: \(targetOutputFPS)fps")
            }
            
            // 🔥 同时应用档位（确保初始化时档位正确）
            let serverType = serverCfg.type.lowercased()
            let initProfile: LadderProfile
            switch serverType {
            case "p4k": initProfile = .p4k
            case "ultra": initProfile = .ultra
            case "high": initProfile = .high
            case "low": initProfile = .low
            default: initProfile = .standard
            }
            if currentProfile != initProfile {
                print("mm: 档位初始化: \(currentProfile) → \(initProfile)")
                if gentleAdaptMode { applyProfileBitrateOnly(initProfile) } else { applyProfile(initProfile) }
            }
        } else {
            print("⚠️ [初始化-推流] 无法获取服务器配置，使用默认FPS: \(targetOutputFPS)fps")
        }
        
        // ⭐ SRS 连接由 SRSManager 负责创建（pc/offer/answer/ICE重连）
        //    这里只准备采集管线与本地视频轨；连接在 srsManager.start() 中建立。

        // 视频轨：优先复用预览管线
        if let _ = localVideoTrack, capturer != nil {
            // 🔥 复用推送轨道（localVideoTrack 已绑定到 videoSource，由 SRSManager add 到 pc）
            
            // 🔥🔥 关键修复：复用预览管线时，必须同步更新 frameThrottler 的推送FPS
            // 否则 frameThrottler 还是预览时的默认值（30fps），后端下发的FPS不生效
            if let throttler = frameThrottler {
                throttler.targetSendFps = targetOutputFPS
                print("mm: [复用] frameThrottler.targetSendFps 更新为 \(targetOutputFPS)fps")
            }
            print("🔄 推流复用预览管线（预览60fps，推送\(targetOutputFPS)fps）")
        } else {
            // 无预览时才初始化采集与轨道
            videoSource = factory.videoSource()
            previewVideoSource = factory.videoSource()  // 🔥 预览用
            
            // 建立管线链：capturer -> throttler -> (previewVideoSource + videoSource)
            let throttler = FrameThrottler()
            throttler.inner = videoSource                    // 🔥 推送输出
            throttler.previewDelegate = previewVideoSource   // 🔥 预览输出（固定60fps）
            throttler.captureFps = currentCaptureFPS         // 🔥 设置采集FPS（整除跳帧）
            throttler.targetSendFps = self.targetOutputFPS   // 🔥 设置推送FPS
            throttler.videoFilter = self.videoFilter         // ⭐ 参数管理
            throttler.setNV12Processor(NV12MetalProcessor())   // ⭐ GPU-native NV12
            throttler.fpsReportHandler = { [weak self] cap, snd in
                    self?.currentCaptureFps = cap
                    self?.currentSendFps = snd
            }

            self.frameThrottler = throttler
            self.applyPipelineModes()
            capturer = CustomAVCaptureVideoCapturer(delegate: throttler)
            print("🔄 [startPublish] 创建帧节流器，采集=\(currentCaptureFPS)fps，推送=\(self.targetOutputFPS)fps，预览=60fps")

            // 🔥 预览轨道绑定到 previewVideoSource
            let previewTrack = factory.videoTrack(with: previewVideoSource, trackId: "local_preview")
            previewVideoTrack = previewTrack
            previewVideoTrack?.add(localView)
            
            // 🔥 推送轨道绑定到 videoSource（由 SRSManager add 到 pc）
            let videoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
            localVideoTrack = videoTrack
            
            // ✅ 根据配置选择初始摄像头
            let devices = CustomAVCaptureVideoCapturer.captureDevices()
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
                
                // 🔥 获取实际采集分辨率（ultra=1280x720, p4k(15+)=1920x1080, 其他=1920x1440）
                let captureRes = getCaptureResolutionForProfile(currentProfile)
                let preset = currentLadder[currentProfile]
                
                currentCaptureFPS = captureRes.fps
                currentCaptureWidth = captureRes.width
                currentCaptureHeight = captureRes.height
                
                    print("🎬 [初始化-推流] 摄像头: \(camera.position == .back ? "后置" : "前置"), 档位: \(currentProfile)")
                print("   采集: \(captureRes.width)x\(captureRes.height)@\(captureRes.fps)fps")
                print("   输出: \(preset?.width ?? 0)x\(preset?.height ?? 0) (scale=\(preset?.scaleDown ?? 1.0))")
            }
            
            // ✅ 使用实际采集分辨率（不是输出分辨率）
            if let camera = initialCamera {
                let captureRes = getCaptureResolutionForProfile(currentProfile)
                let preset = currentLadder[currentProfile]
                
                let throttlerFps = frameThrottler?.targetSendFps ?? targetOutputFPS
                print("═══════════════════════════════════════════════════")
                print("mm: [初始化] 开始采集")
                print("mm:   档位=\(currentProfile)")
                print("mm:   采集=\(captureRes.width)x\(captureRes.height)@\(captureRes.fps)fps")
                print("mm:   输出=\(preset?.width ?? 0)x\(preset?.height ?? 0) (scale=\(preset?.scaleDown ?? 1.0))")
                print("mm:   推送目标=\(targetOutputFPS)fps, 节流器=\(throttlerFps)fps")
                print("mm:   码率=\(targetBitrateKbps)kbps")
                print("═══════════════════════════════════════════════════")
                
                startCaptureWithDevice(camera, width: captureRes.width, height: captureRes.height, fps: captureRes.fps)
                
                // 🔥 FrameThrottler 使用采集和输出分辨率
                frameThrottler?.currentProfileName = "\(currentProfile)"
                frameThrottler?.expectedCaptureWidth = captureRes.width
                frameThrottler?.expectedCaptureHeight = captureRes.height
                frameThrottler?.expectedOutputWidth = preset?.width ?? captureRes.width
                frameThrottler?.expectedOutputHeight = preset?.height ?? captureRes.height
                frameThrottler?.currentScaleDown = preset?.scaleDown ?? 1.0
                
                // 🔥 初始化时设置 WebRTC 缩放
                setResolutionScale(preset?.scaleDown ?? 1.0)
            }
        }

        // 🔥 设置分辨率缩放比例（根据当前档位）
        let scaleDown = currentLadder[currentProfile]?.scaleDown ?? 1.0
        currentResolutionScale = scaleDown
        setResolutionScale(scaleDown)  // 确保 WebRTC 也使用正确的缩放
        
        // 🔥 设置码率（此时 currentCaptureFPS 已根据前后置摄像头正确设置）
        applyEffectiveBitrateToWebRTC()

        // ⭐ 交给 SRSManager 建立连接（Offer→/rtc/v1/publish→Answer + ICE重连）
        srsManager.dataSource = self
        srsManager.start()
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
                dict["profile-level-id"] = WebRTCManager.forcedH264ProfileLevelId   // 🔧 临时降档测试（原 "640028" High 4.0）
                dict["level-asymmetry-allowed"] = "1"
                
                let targetMinKbps = effectiveMinKbpsForCurrentProfile()
                let targetMaxKbps = effectiveMaxKbpsForCurrentProfile()
                let minKbps = targetMinKbps
                let maxKbps = targetMaxKbps
                
                dict["x-google-start-bitrate"] = "\(maxKbps)"
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
            let appended = "a=fmtp:\(pt) level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=\(WebRTCManager.forcedH264ProfileLevelId)"  // 🔧 临时降档测试（原 640028 High 4.0）
            if let idx = lines.firstIndex(where: { $0.lowercased().hasPrefix("a=rtpmap:\(pt)") }) {
                lines.insert(appended, at: idx + 1)
            } else {
                lines.append(appended)
            }
        }
        return lines.joined(separator: "\r\n")
        // ... existing code ...
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
        // 🔥 取消唤醒轮询（如果有）
        if wakeWaitingForPublish {
            wakeWaitingForPublish = false
        }
        
        adaptTimer?.invalidate(); adaptTimer = nil
        statsTimer?.invalidate(); statsTimer = nil
        stopBitrateEnforcement()  // ✅ 停止码率强制定时器
        stopKeyframeTimer()       // ✅ 停止关键帧定时器
        stopCaptureWatchdog()     // 🚑 停止采集看门狗
        frameThrottler?.stop()    // ✅ 停止帧定时器
        badSeconds = 0; goodSeconds = 0
        kbpsHistory.removeAll()  // ✅ 清空码率历史
        fpsHistory.removeAll()    // ✅ 清空FPS历史
        WebSocketManager.isPublishingFlag = 0
        print("🔴 [publishStatus] 0 ← stopPublish()调用")
        WebSocketManager.publishingKbps = 0
        WebSocketManager.publishingFps = 0
        WebSocketManager.publishingSendFps = 0
        WebSocketManager.publishingStreamKey = ""  // 清空流名
        P2PLogReporter.shared.stop()  // ⭐ P2P诊断日志上报：停流即冲刷剩余并停止
        WebSocketManager.networkQuality = "unknown"
        WebSocketManager.packetLoss = 0.0
        WebSocketManager.rtt = 0
        isPublishing = false
        pc?.close(); pc = nil
        // ⭐ 停止对应连接管理类
        modeEvalTimer?.invalidate(); modeEvalTimer = nil
        currentConnMode = .none
        // ⭐ §53.4：清掉"本次会话定案"，但**保留观看端在线注册表**——PC 还在线、心跳还在来，
        //   下次推流要用它决策（清空会导致重新协商后必然误判成"无观看端"→ 白走 SRS）。
        SessionPolicy.shared.onPublishStopped()
        viewerRegistry.removeAll()
        if p2pManager.isActive { p2pManager.stop() }
        if srsManager.isActive { srsManager.stop() }
        // MARK: - SRT (independent)
        frameThrottler?.srtFrameSink = nil
        if srtManager.isPublishing { srtManager.stop() }
    }

    // MARK: - ⭐ P2P 直连推流（connect_mode == "p2p"）
    func startP2PPublish(initialProfile: LadderProfile? = nil) {
        print("🎬 [P2P] 启动 P2P 直连推流")
        notSameWifiHandled = false   // ⭐ §52.6：新一轮推流重新判定同 WiFi
        // 预览采集管线应已就绪（进主页/唤醒时已 startPreviewIfNeeded）；未就绪则回主线程补起后重试
        if localVideoTrack == nil || capturer == nil {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.startPreviewIfNeeded(initialProfile: initialProfile)
                try? await Task.sleep(nanoseconds: 300_000_000)
                self.startP2PPublish(initialProfile: initialProfile)
            }
            return
        }
        // 从服务器配置应用 FPS / 档位（与 SRS 路径一致，仅不建立 SRS 连接）
        if let serverCfg = ConfigManager.shared.getCurrentConfig(), let serverFps = serverCfg.fps {
            setAverageOutputFPS(serverFps)
            enableAverageThrottling(true)
        }
        isPublishing = true
        WebSocketManager.isPublishingFlag = 1
        p2pManager.dataSource = self
        p2pManager.start()
        startStats()
        startCaptureWatchdog()  // 🚑 切档卡死兜底
        print("✅ [P2P] 就绪，等待 PC 发起 WEBRTC_REQUEST")
    }

    // MARK: - SRT (independent)
    /// SRT 推流（connect_mode == "srt"）。完全独立链路、与 SRS/P2P 互斥（一次只走一条）：
    /// 复用现有采集 + 滤镜（capturer / frameThrottler），把「滤镜后帧」旁路给 SRTManager，
    /// 不建立 WebRTC PeerConnection、不调用 SRS/P2P。仅推视频，不接音频。
    /// 删除本方法 + decideMode 的 .srt 分支 + SRTManager.swift 即可完全回退。
    func startSRTPublish(initialProfile: LadderProfile? = nil) {
        print("🎬 [SRT] 启动 SRT 推流（独立链路，与 SRS/P2P 互斥）")
        // 预览采集管线应已就绪；未就绪则补起后重试（与 P2P 一致）。
        if localVideoTrack == nil || capturer == nil || frameThrottler == nil {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.startPreviewIfNeeded(initialProfile: initialProfile)
                try? await Task.sleep(nanoseconds: 300_000_000)
                self.startSRTPublish(initialProfile: initialProfile)
            }
            return
        }
        // 从服务器配置应用 FPS / 档位（与 SRS/P2P 路径一致，仅不建立 SRS/PC 连接）。
        if let serverCfg = ConfigManager.shared.getCurrentConfig(), let serverFps = serverCfg.fps {
            setAverageOutputFPS(serverFps)
            enableAverageThrottling(true)
        }

        // 方案 A：IP 复用登录返回的 stream_push_ip，端口写死 10080。
        let ip = UserDefaults.standard.string(forKey: "stream_push_ip") ?? ""

        srtManager.onFailure = { reason in
            print("❌ [SRT] 失败：\(reason)")
        }
        srtManager.onStateChange = { publishing in
            print("ℹ️ [SRT] publishing=\(publishing)")
        }
        // ⭐ 先按当前档位/清晰度算出目标码率（与 SRS/P2P 同一套 effectiveMaxKbps 逻辑），
        //   否则 targetBitrateKbps 停在默认值 2000，SRT 上报码率会失真。
        //   SRT 模式 pc/videoSender 为 nil，setBitrateRangeKbps 只会更新 targetBitrateKbps（打印一条
        //   "videoSender 为空" 警告，无副作用），currentConnMode=.srt 也不会触发 P2P 分支。
        applyEffectiveBitrateToWebRTC()
        // ⭐ 初始注入编码参数（分辨率/推送帧率/目标码率）。publish 前 isPublishing=false，
        //   setEncodeParams 仅记录、随后在 SRTManager.publish 内统一 applyVideoSettingsToStream 应用。
        //   ⚠️ 不要在此预写 srtManager.targetBitrateKbps：那会让运行中 setEncodeParams 的变更检测
        //      恒判「无变化」而跳过下发，导致后端下发码率不生效（本次 bug 根因）。
        //   fps 用「实际推送目标」而非档位采集 fps，使编码器 expectedFrameRate 跟随后端下发。
        let initRes = getCaptureResolutionForProfile(currentProfile)
        let initPushFps = frameThrottler?.targetSendFps ?? initRes.fps
        srtManager.setEncodeParams(width: initRes.width, height: initRes.height,
                                   fps: initPushFps, bitrateKbps: targetBitrateKbps)
        // ⭐ SRT 统计回调：实测 fps + 真实码率/RTT/丢包 → 写入状态上报字段（与 SRS/P2P 完全对齐，PC 顶栏显示）。
        //   回调签名为 onSample(pushFps, kbps, rttMs, lossRate, lossPerSec)。
        srtManager.onSample = { [weak self] fps, kbps, rttMs, lossRate, _ in
            guard let self else { return }
            WebSocketManager.publishingFps = fps
            WebSocketManager.publishingSendFps = fps
            WebSocketManager.publishingKbps = kbps
            // ⭐ 与 SRS/P2P 同口径上报网络质量/丢包/RTT（阈值与 startStats 完全一致）。
            WebSocketManager.packetLoss = lossRate
            WebSocketManager.rtt = rttMs
            let quality: String
            if lossRate <= 0.01 && rttMs <= 100 {
                quality = "excellent"
            } else if lossRate <= 0.03 && rttMs <= 200 {
                quality = "good"
            } else if lossRate <= 0.05 && rttMs <= 400 {
                quality = "fair"
            } else {
                quality = "poor"
            }
            WebSocketManager.networkQuality = quality
            // 周期性安全网：把当前「码率 + 推送帧率 + 分辨率」同步给 SRT 编码器
            //（即时同步已在 setAverageOutputFPS / applyEffectiveBitrateToWebRTC 内完成；
            //  此处兜底切档/漏发。setEncodeParams 内部仅在参数变化时才下发，无变化为空操作）。
            self.syncSRTEncodeParamsFromCurrentState()
        }
        srtManager.start(ip: ip, streamKey: streamKey)

        // 把滤镜后帧旁路给 SRT（与原 WebRTC 推送同节流、同时间戳）。
        frameThrottler?.srtFrameSink = { [weak self] pixelBuffer, ts in
            self?.srtManager.appendVideoFrame(pixelBuffer: pixelBuffer, timeStampNs: ts)
        }

        isPublishing = true
        WebSocketManager.isPublishingFlag = 1
        startCaptureWatchdog()  // 🚑 切档卡死兜底
        // 注意：不调用 startStats()（那是 WebRTC PeerConnection 统计，SRT 模式 pc 为 nil 空转）。
        // SRT 码率/帧率由 srtManager.onSample 上报。
        print("✅ [SRT] 就绪：srt://\(ip):10080 streamKey=\(streamKey)")
    }

    // MARK: - ⭐ §53.4-定稿：链路/编码决策与重新协商

    /// ⛔ 已废弃（§53.4-定稿）：链路不再由登录页手选，改为推流前按网络关系自动决策
    ///（`SessionPolicy.decideForPublish`）。保留本方法仅供回滚参考。
    /// 后端 `connect.mode == "srs"` 仍可一键强制多人线路——该判定已移入 SessionPolicy 之前的调用处。
    private func decideMode() -> ConnMode {
        switch backendConnectMode {
        case "p2p": return .p2p
        case "srt": return .srt   // MARK: - SRT (independent)（已退役）
        default:    return .srs
        }
    }

    /// ⛔ 已废弃：去掉周期评估定时器（重新协商改为事件驱动，见 SessionPolicy.onRenegotiateNeeded）。
    private func startModeEvalTimer() {
        modeEvalTimer?.invalidate(); modeEvalTimer = nil
    }

    /// ⭐ §53.4.3 重新协商：决策输入变了（观看端换网段 / 新增收不了 H265 的观看端 / 本机切网）
    /// 且新结果与已定案不同时，由 SessionPolicy 回调到这里。
    ///
    /// **标准动作：停推流 → 重新决策 → 起推流**，不做任何"边推边改"的 in-place 切换——
    /// mode/codec 都要在推流前定好（编码器工厂、SDP、PC 的解码管线全都依赖它）。
    /// 冷却与次数上限在 SessionPolicy 里，这里只负责执行。
    @MainActor
    func renegotiateSession(reason: String) {
        guard isPublishing else {
            print("🧭 [链路决策] 收到重新协商(\(reason))但当前未推流，忽略")
            SessionPolicy.shared.abortRenegotiation()   // §53.20.1：清标记，防污染下次手动推流
            return
        }
        print("🧭 [链路决策] 执行重新协商：\(reason) —— 停推流 → 重新决策 → 起推流")
        let profile = currentProfile
        stopPublish()
        // 留一拍给 PeerConnection/采集管线收尾，避免拆建重叠（与切档重建同款间隔）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.startPublish(initialProfile: profile)
        }
    }

    /// ⛔ 已废弃：连接方式静态，由用户登录页选择决定，不再做运行时自动协商切换。
    /// 保留方法签名以兼容历史调用点，但内部不执行任何切换。
    func evaluateConnectMode(reason: String) {
        // no-op：静态连接方式，不自动切换
    }

    // MARK: - 摄像头休眠/唤醒（节省电量）
    @Published var isCameraSleeping: Bool = false
    private var sleepBeforePublishing: Bool = false  // 休眠前是否在推流
    private var wakeWaitingForPublish: Bool = false  // 唤醒后等待首帧再推流
    
    /// 摄像头休眠：停止采集但保持预览黑屏，节省电量
    @MainActor
    func sleepCamera() {
        print("💤 摄像头进入休眠模式...")
        
        // 🔥 取消唤醒轮询（如果有）
        if wakeWaitingForPublish {
            print("   -> 取消唤醒推流轮询")
            wakeWaitingForPublish = false
        }
        
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
            // 🔥 需要恢复推流：先启动预览，等首帧到达后再推流
            print("   -> 休眠前在推流，先启动预览等待首帧...")
            
            self.wakeWaitingForPublish = true  // 标记：等待首帧后推流
            
            // 立即启动预览（摄像头采集）
            self.startPreviewIfNeeded()
            
            // 🔥 轮询等待首帧到达后再推流（最多等待3秒）
            var waitCount = 0
            let maxWait = 30  // 最多等待3秒（100ms x 30）
            
            func checkAndPublish() {
                // 🔥 检查是否被取消（休眠/手动停止等）
                guard self.wakeWaitingForPublish else {
                    print("   ⏹️ 唤醒推流轮询已取消")
                    return
                }
                
                waitCount += 1
                
                // 检查首帧是否已到达（通过 frameThrottler 的标记）
                let hasFrame = self.frameThrottler?.hasReceivedFrame ?? false
                if hasFrame {
                    print("   ✅ 首帧已到达，开始推流...")
                    self.wakeWaitingForPublish = false
                if !self.isPublishing {
                    self.startPublish()
                    
                        // 恢复配置
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.reapplyConfigForWake()
                        }
                    }
                } else if waitCount >= maxWait {
                    // 超时，强制推流
                    print("   ⚠️ 等待首帧超时(3秒)，强制推流...")
                    self.wakeWaitingForPublish = false
                    if !self.isPublishing {
                        self.startPublish()
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.reapplyConfigForWake()
                        }
                    }
                } else {
                    // 继续等待
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        checkAndPublish()
                }
            }
            }
            
            // 0.2秒后开始检查（给预览一点启动时间）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                checkAndPublish()
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
        
        print("☀️ 摄像头唤醒流程已启动")
    }

    // MARK: - 相机控制
    private func configureCameraAutoModes(_ device: AVCaptureDevice) {
        let backendFocus = ConfigManager.shared.getCurrentConfig()?.focus
        let focusValue: Float
        if userHasManuallyAdjustedFocus, let saved = savedUserFocusDistance {
            focusValue = saved
            print("📸 对焦模式: 手动锁定, 焦距=\(focusValue) (用户手动调整)")
        } else if let backendFocus {
            focusValue = backendFocus
            print("📸 对焦模式: 手动锁定, 焦距=\(focusValue) (后端配置)")
        } else {
            focusValue = 0.0
            print("📸 对焦模式: 手动锁定, 焦距=\(focusValue) (默认超焦距)")
        }
        focusDistance = focusValue
        capturer?.applyBaseCameraTuning(focus: focusValue,
                                        shutterSpeed: cjfpsValue,
                                        captureFps: max(currentCaptureFPS, 15),
                                        preserveCurrentISO: autoIsoEnabled)
        applyHardwareBrightnessEVIfReady()
    }
    
    
    // ✅ 手动对焦距离（0.0=近处，1.0=无穷远）
    func setFocus(_ distance: Float) {
        guard capturer?.currentDevice != nil else {
            pendingFocus = distance
            print("📸 [setFocus] capturer未就绪，保存到pendingFocus: \(distance)")
            return
        }

        if !userHasManuallyAdjustedFocus {
            userHasManuallyAdjustedFocus = true
        }
        let clamped = max(0.0, min(1.0, distance))
        savedUserFocusDistance = clamped
        focusDistance = clamped
        capturer?.applyFocus(clamped)
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
        // print("💾 [对焦缓存] \(key) → \(distance)")
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
        
        // print("🔍 开始自动对焦: \(device.position == .back ? "后置" : "前置")")
        
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
                // print("🔍 等待自动对焦启动...")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                    do {
                        try device.lockForConfiguration()
                        
                        // 检查当前对焦模式
                        // print("🔍 当前对焦模式: \(device.focusMode.rawValue)")
                        
                        // 2. 再次设置对焦点（确保对焦点设置生效）
                        if device.isFocusPointOfInterestSupported {
                            device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                            // print("🔍 设置对焦点到中心")
                        }
                        
                        // 3. 切换到一次性自动对焦模式（这会触发一次对焦）
                        if supportsAutoFocus {
                            device.focusMode = .autoFocus
                            // print("🔍 切换到一次性自动对焦模式")
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
        // print("🔍 [\(deviceType)] 监控对焦状态...")
        
        // 等待一小段时间，确保对焦开始
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // 检查对焦是否已经开始
            // if device.isAdjustingFocus {
            //     print("🔍 对焦进行中...")
            // }
        }
        
        // 使用定时器轮询对焦状态
        var checkCount = 0
        let maxChecks = 50  // 最多等待5秒（50次 × 0.1秒）
        
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            checkCount += 1
            
            // 对焦完成（不再调整）
            if !device.isAdjustingFocus {
                timer.invalidate()
                // print("✅ 对焦完成")
                
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
                            // print("✅ 对焦完成，距离=\(currentLensPosition)")
                        } else {
                            // print("⚠️ 不支持连续自动对焦")
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
                            
                            // print("🔍 镜头位置: \(currentLensPosition)")
                            
                            // 锁定到当前对焦位置（自动对焦的结果）
                            device.focusMode = .locked
                            device.setFocusModeLocked(lensPosition: currentLensPosition, completionHandler: { _ in
                                device.unlockForConfiguration()
                                
                                // 保存自动对焦的位置
                                self?.focusDistance = currentLensPosition
                                
                                // 🔥 保存到缓存（下次直接使用）
                                self?.saveFocusDistanceToCache(device: device, width: width, height: height, distance: currentLensPosition)
                                
                                // print("✅ 对焦锁定，距离=\(currentLensPosition)")
                                completion()
                            })
                        } else {
                            // 不支持自定义位置，直接锁定
                            device.focusMode = .locked
                            device.unlockForConfiguration()
                            // print("✅ 对焦锁定")
                            completion()
                        }
                    } else {
                        device.unlockForConfiguration()
                        // print("⚠️ 不支持锁定对焦")
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
        
        // 🔥 同步更新 UI 显示的 zoom 值
        DispatchQueue.main.async {
            self.currentZoom = factor
        }
        
        guard let dev = capturer?.currentDevice else {
            print("⚠️ [setZoom] capturer 未准备好，zoom=\(factor) 已保存，等待后续应用")
            return
        }
        let deviceType = dev.deviceType.rawValue
        let position = dev.position == .front ? "前置" : "后置"
        
        print("🔍 [setZoom] 设备: \(position) (\(deviceType))")
        
        // 🔥 使用设备实际支持的最小/最大 zoom 值，支持超广角
        let minZoom = dev.minAvailableVideoZoomFactor  // iPhone 11+ 后置约 0.5
        let maxZoom = dev.activeFormat.videoMaxZoomFactor
        let currentZoom = dev.videoZoomFactor
        let safe = max(minZoom, min(factor, maxZoom))

        print("🔍 [setZoom] 当前zoom=\(currentZoom), 请求=\(factor), 范围=\(minZoom)~\(maxZoom), 最终=\(safe)")

        // 🔥 直接设置zoom（UI 已保证每次只变0.1步进，不会卡死）
        do {
            try dev.lockForConfiguration()
            dev.videoZoomFactor = safe
            dev.unlockForConfiguration()
        } catch {
            print("❌ [setZoom] 变焦失败：\(error.localizedDescription)")
        }
    }
    
    func toggleCamera() {
        // ... existing code ...
        guard let curInput = capturer?.currentVideoInput else {
            //print("❌ toggleCamera: 无法获取当前输入设备")
            return
        }
        
        let currentPos = curInput.device.position
        let newPos: AVCaptureDevice.Position = (currentPos == .back) ? .front : .back
        
        //print("🔄 toggleCamera: 从 \(currentPos == .back ? "后置" : "前置") 切换到 \(newPos == .back ? "后置" : "前置")")
        
        guard let dev = CustomAVCaptureVideoCapturer.captureDevices().first(where: { $0.position == newPos }) else {
            //print("❌ toggleCamera: 找不到目标摄像头设备")
            return
        }

        let allFormats = CustomAVCaptureVideoCapturer.supportedFormats(for: dev)
        
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

        // 🔥 使用采集分辨率（4:3统一1920x1440，16:9用1280x720）
        let captureRes = getCaptureResolutionForProfile(currentProfile)
        let targetWidth = captureRes.width
        let targetHeight = captureRes.height
        let targetFps = captureRes.fps
        currentCaptureWidth = targetWidth
        currentCaptureHeight = targetHeight
        
        print("🎯档位🎯 [toggleCamera] 采集: \(targetWidth)x\(targetHeight)@\(targetFps)fps, 档位: \(currentProfile)")
        
        // 🔥 查找匹配目标分辨率的格式
        let matchingFormats = allFormats.filter { fmt in
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let w = Int(dims.width)
            let h = Int(dims.height)
            return (w == targetWidth && h == targetHeight) || (w == targetHeight && h == targetWidth)
        }
        
        // 🔥 根据目标帧率选择不同的策略
        let isHighFpsMode = targetFps > 60
        
        let candidateFormats: [AVCaptureDevice.Format]
        
        if isHighFpsMode {
            // 🔥 高帧率模式：选择支持目标帧率的格式
            let highFpsFormats = matchingFormats.filter { fmt in
                let maxFps = Int(fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                return maxFps >= targetFps
            }
            print("🎯档位🎯 高帧率模式: 目标\(targetFps)fps, 找到\(matchingFormats.count)个匹配格式, 其中\(highFpsFormats.count)个支持\(targetFps)fps+")
            
            if !highFpsFormats.isEmpty {
                candidateFormats = highFpsFormats
                print("🎯档位🎯 ✅ 使用支持\(targetFps)fps的格式")
            } else {
                candidateFormats = matchingFormats.isEmpty ? allFormats : matchingFormats
                print("🎯档位🎯 ⚠️ 无支持\(targetFps)fps的格式，使用最接近的格式")
            }
        } else {
            // 🔥 普通模式：优先精确60fps格式
            let exact60FpsFormats = matchingFormats.filter { fmt in
                let maxFps = Int(fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                return maxFps >= 59 && maxFps <= 61
            }
            let highFpsFormats = matchingFormats.filter { fmt in
                let maxFps = Int(fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                return maxFps >= targetFps
            }
            
            print("🎯档位🎯 普通模式: 目标\(targetFps)fps, 找到\(matchingFormats.count)个匹配格式 (精确60fps=\(exact60FpsFormats.count)个)")
            
            if !exact60FpsFormats.isEmpty {
                candidateFormats = exact60FpsFormats
                print("🎯档位🎯 ✅ 使用精确60fps格式")
            } else if !highFpsFormats.isEmpty {
                candidateFormats = highFpsFormats
                print("🎯档位🎯 ⚠️ 无精确60fps格式，使用支持\(targetFps)fps+的格式")
            } else {
                candidateFormats = matchingFormats.isEmpty ? allFormats : matchingFormats
                print("🎯档位🎯 ⚠️ 无\(targetFps)fps格式，从所有格式中选择")
            }
        }
        
        // 分辨率优先：先选最接近目标的，分辨率相同时选更接近目标fps的
        guard let best = candidateFormats.sorted(by: { f0, f1 in
            let a = CMVideoFormatDescriptionGetDimensions(f0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions(f1.formatDescription)
            let d0 = abs(Int(a.width) - targetWidth) + abs(Int(a.height) - targetHeight)
            let d1 = abs(Int(b.width) - targetWidth) + abs(Int(b.height) - targetHeight)
            if d0 != d1 { return d0 < d1 }
            
            // 分辨率相同时，选择最大fps更接近目标fps的
            let max0 = Int(f0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            let max1 = Int(f1.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            let diff0 = abs(max0 - targetFps)
            let diff1 = abs(max1 - targetFps)
            return diff0 < diff1
        }).first else { return }

        let maxFps = Int(best.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
        let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
        print("🎯档位🎯 选中格式: \(dims.width)x\(dims.height) 最大FPS=\(maxFps)")

        // 🔥 使用目标fps和格式支持的最大fps中较小的那个
        let useFps = min(targetFps, maxFps)
        currentCaptureFPS = useFps
        
        print("🎯档位🎯 采集FPS: \(useFps)fps (目标=\(targetFps), 格式最大=\(maxFps))")
       
       // ✅ 确保推送FPS不超过采集FPS
       if let currentSendFps = self.frameThrottler?.targetSendFps, currentSendFps > useFps {
           self.frameThrottler?.targetSendFps = useFps
           targetOutputFPS = useFps
           print("⚠️ 推送FPS(\(currentSendFps)) 超过采集FPS(\(useFps))，已限制为\(useFps)fps")
       }

        capturer.stopCapture { [weak self] in
               guard let self = self else { return }

               if let preset = self.currentLadder[self.currentProfile] {
                   print("📋 切换前档位配置: \(preset.width)x\(preset.height)@\(preset.fps)fps → \(preset.minKbps)-\(preset.maxKbps)kbps")
               }
               self.calculateLadderForDevice(dev)
               if let preset = self.currentLadder[self.currentProfile] {
                   print("📋 切换后档位配置: \(preset.width)x\(preset.height)@\(preset.fps)fps → \(preset.minKbps)-\(preset.maxKbps)kbps")
               }

               let newCaptureRes = self.getCaptureResolutionForProfile(self.currentProfile)
               self.currentCaptureWidth = newCaptureRes.width
               self.currentCaptureHeight = newCaptureRes.height
               guard let newBest = self.findBestFormat(for: dev,
                                                        targetWidth: newCaptureRes.width,
                                                        targetHeight: newCaptureRes.height,
                                                        targetFps: newCaptureRes.fps) else {
                   print("❌ [toggleCamera] 新摄像头未找到合适格式: \(newCaptureRes.width)x\(newCaptureRes.height)@\(newCaptureRes.fps)")
                   return
               }
               let newMaxFps = Int(newBest.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
               let finalFps = min(newCaptureRes.fps, newMaxFps)
               self.currentCaptureFPS = finalFps
               let newDims = CMVideoFormatDescriptionGetDimensions(newBest.formatDescription)
               print("🎬 [切换摄像头] 新格式 \(newDims.width)x\(newDims.height) max=\(newMaxFps)fps final=\(finalFps)fps")

               if let currentSendFps = self.frameThrottler?.targetSendFps, currentSendFps > finalFps {
                   self.frameThrottler?.targetSendFps = finalFps
                   self.targetOutputFPS = finalFps
                   print("⚠️ 推送FPS(\(currentSendFps)) 超过采集FPS(\(finalFps))，已限制为\(finalFps)fps")
               }

               self.capturer.setDelegate(self.frameThrottler!)
               self.capturer.switchCapture(to: dev, format: newBest, fps: finalFps) { [weak self] in
                   guard let self else { return }
                   self.applyEffectiveBitrateToWebRTC()
                   self.enforceBitrateImmediately()
                   self.configureCameraAutoModes(dev)
                   self.applyMountTransform()
                   self.updatePreviewMirror(isFrontCamera: newPos == .front)
                   self.reapplyConfigExceptFocus()
                   self.reapplyFocusFromConfig()
                   self.videoSource?.adaptOutputFormat(
                       toWidth: Int32(newCaptureRes.width),
                       height: Int32(newCaptureRes.height),
                       fps: Int32(finalFps)
                   )
                   self.forceKeyframe()
               }
               //print("🚀 切换摄像头开始采集 (由SDK设置帧率为\(finalFps)fps)")
               
               // ✅ 更新 ConfigManager 中的 direction，记录当前使用的摄像头（保留其他所有字段）
               let newDirection = (newPos == .front) ? "1" : "-1"
               if var currentConfig = ConfigManager.shared.getCurrentConfig() {
                   // 🔥 只修改 direction，其他字段（type, zoom, ptype, fps, bitrate, angle, focus, brightness, saturation, contrast, exposureBias）全部保留
                   currentConfig.direction = newDirection
                   ConfigManager.shared.currentThinConfig = currentConfig  // 更新内存中的配置
                   ConfigManager.shared.cacheThinConfig(currentConfig)     // 持久化到本地
                   print("📝 已更新配置: direction=\(newDirection) (保留: type=\(currentConfig.type), zoom=\(currentConfig.zoom), ptype=\(currentConfig.ptype), fps=\(currentConfig.fps ?? 0), bitrate=\(currentConfig.bitrate ?? 0))")
               }
               
               // ✅ 获取实际使用的分辨率（用于对焦缓存）
               let actualDims = CMVideoFormatDescriptionGetDimensions(newBest.formatDescription)
               let actualWidth = Int(actualDims.width)
               let actualHeight = Int(actualDims.height)
               
               // 🔥 禁用自动对焦 - 切换摄像头后保持当前焦距或使用后端配置
               print("🔍 [toggleCamera] 不执行自动对焦，保持当前焦距设置")

               // 如果有待处理的对焦设置，立即应用
               if let focus = self.pendingFocus {
                   self.pendingFocus = nil
                   self.setFocus(focus)
                   print("🔍 [toggleCamera] 应用待处理的焦距: \(focus)")
               }
               
               // ✅ 重新连接节流器
               if self.frameThrottler == nil {
                   let t = FrameThrottler()
                   t.inner = self.videoSource
                   t.previewDelegate = self.previewVideoSource  // 🔥 预览输出（固定60fps）
                   t.videoFilter = self.videoFilter
                   t.setNV12Processor(NV12MetalProcessor())
                   t.targetSendFps = self.targetOutputFPS       // 🔥 只影响推送
                   self.frameThrottler = t
                   self.applyPipelineModes()
                   print("🔄 [toggleCamera] 重新创建帧节流器，推送目标FPS: \(self.targetOutputFPS)fps，预览固定60fps")
               }

               print("🎯 推送FPS = \(self.frameThrottler?.targetSendFps ?? 60)fps，预览FPS = 60fps (切换摄像头后保持)")
           }
    }

    // MARK: - 档位应用（直接调用 applyProfileBitrateOnly）
    /// 🔥 与 applyProfileBitrateOnly 功能相同，为兼容性保留
    func applyProfile(_ p: LadderProfile) {
        applyProfileBitrateOnly(p)
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - 🔥 简化版分辨率切换（重写）
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// 🔥 核心分辨率切换函数 - 通过停止/启动 capturer 来真正切换分辨率
    /// - Parameters:
    ///   - width: 目标宽度
    ///   - height: 目标高度
    ///   - fps: 目标帧率
    private func recaptureWithResolution(width: Int, height: Int, fps: Int) {
        print("═══════════════════════════════════════════════════")
        print("📐 [分辨率切换] 开始")
        print("   目标: \(width)x\(height)@\(fps)fps")
        
        // 1️⃣ 检查 capturer 是否存在
        guard let capturer = self.capturer else {
            print("   ❌ capturer 未初始化，跳过")
            return
        }
        
        // 2️⃣ 获取当前摄像头设备
        let isFront = isFrontCameraActive()
        let devices = CustomAVCaptureVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == (isFront ? .front : .back) }) else {
            print("   ❌ 无可用摄像头设备")
            return
        }
        
        print("   摄像头: \(isFront ? "前置" : "后置")")
        
        // 3️⃣ 查找最佳匹配格式
        guard let bestFormat = findBestFormat(for: device, targetWidth: width, targetHeight: height, targetFps: fps) else {
            print("   ❌ 未找到合适的格式")
            return
        }
        
        let dims = CMVideoFormatDescriptionGetDimensions(bestFormat.formatDescription)
        let maxFps = Int(bestFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
        let useFps = min(fps, maxFps)
        applyOutputPixelFormatForCurrentRange()
        
        print("   选中格式: \(dims.width)x\(dims.height), maxFps=\(maxFps), 使用=\(useFps)fps")
        
        // 6️⃣ 预先算好新档位的输出参数（completion 与下方都要用）
        let preset      = currentLadder[currentProfile]
        let scaleDown   = preset?.scaleDown ?? 1.0
        let outputWidth  = preset?.width  ?? Int(dims.width)
        let outputHeight = preset?.height ?? Int(dims.height)

        // 4️⃣ 热切换格式（不 stopCapture，保持相机会话连续，避免绿幕）
        // CustomAVCaptureVideoCapturer.startCapture 内部走 beginConfiguration/commitConfiguration
        // 与玉麒麟 GPUImage 热切换原理一致：帧不断流，编码器不重启
        //
        // ⭐⭐ 修复「P2P 切挡位画面冻住 / 切超高清条纹」（2026-06-24）：
        //   startCapture 内部是 sessionQueue.async（beginConfiguration/removeInput/addInput/
        //   commitConfiguration/startRunning 全在后台串行执行，完成时刻不确定，16:9 大格式常 >200ms）。
        //   旧实现把 adaptOutputFormat + forceKeyframe 挂在主线程固定延时(+0.05/+0.15s)，
        //   极易在「重配置还没完成、新格式还没产帧」的空窗期就把 IDR 发完 → 新格式首帧没有参考 IDR
        //   → PC webrtcbin 收到无参考的 P 帧 → 画面冻住/超高清条纹，要等下一个周期 IDR 才恢复。
        //   正解：把 adaptOutputFormat + forceKeyframe 移到 startCapture 的 completion 里
        //   （= 重配置真正完成、新格式开始产帧之后再发 IDR），无论后台耗时多久都不会再丢首个 IDR。
        print("   🔄 热切换格式（不停流）: \(dims.width)x\(dims.height)@\(useFps)fps")
        capturer.startCapture(with: device, format: bestFormat, fps: useFps) { [weak self] in
            guard let self = self else { return }
            // completion 已由 CustomAVCaptureVideoCapturer 切回主线程执行。
            // 通知 WebRTC 新分辨率 → 编码器立即输出 IDR（比码率微调更直接可靠）。
            self.videoSource?.adaptOutputFormat(
                toWidth: Int32(outputWidth),
                height: Int32(outputHeight),
                fps: Int32(useFps)
            )
            self.forceKeyframe()
            // 兜底：再补两拍关键帧，覆盖「completion 时新格式首帧尚未真正吐出」的极短窗口。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.forceKeyframe()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.forceKeyframe()
            }
            print("🔑 [分辨率切换] 重配置完成回调 → adaptOutputFormat + forceKeyframe（IDR 发在新格式产帧之后）")
        }

        // 5️⃣ 更新状态变量
        currentCaptureWidth  = Int(dims.width)
        currentCaptureHeight = Int(dims.height)
        currentCaptureFPS    = useFps

        // 6️⃣ 更新 FrameThrottler
        frameThrottler?.expectedCaptureWidth  = Int(dims.width)
        frameThrottler?.expectedCaptureHeight = Int(dims.height)
        frameThrottler?.expectedOutputWidth   = outputWidth
        frameThrottler?.expectedOutputHeight  = outputHeight
        frameThrottler?.currentScaleDown      = scaleDown

        print("   ✅ 格式热切换请求已发出: \(dims.width)x\(dims.height)@\(useFps)fps → 输出: \(outputWidth)x\(outputHeight)（IDR 待重配置完成回调发送）")
        print("═══════════════════════════════════════════════════")

        // 7️⃣ 延迟应用相机配置（推迟到格式稳定后，避免 ISO 越界 + 减少二次抖动）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.configureCameraAutoModes(device)
            self.applyMountTransform()
            self.applyPipelineDefaults(source: "recapture-stabilized")
        }
    }
    
    func applyCaptureExperimentFormat() {
        applyOutputPixelFormatForCurrentRange()
        recaptureWithResolution(width: currentCaptureWidth, height: currentCaptureHeight, fps: max(30, currentCaptureFPS))
    }

    /// 读取相机白平衡状态（UI 1Hz 轮询）
    func refreshWhiteBalanceStatus() {
        capturer?.queryWhiteBalanceStatus { [weak self] status in
            guard let self else { return }
            self.whiteBalanceIsAuto = status.isAuto
            self.whiteBalanceStatusText = status.displayText
            let slider = Self.sliderFromTemperature(status.kelvin)
            if self.hardwareWBSliderValue != slider {
                self.hardwareWBSliderValue = slider
                WebSocketManager.shared.sendWhiteBalanceResult(sliderValue: slider)
            }
        }
    }

    func startWhiteBalanceStatusPolling() {
        stopWhiteBalanceStatusPolling()
        refreshWhiteBalanceStatus()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.whiteBalanceStatusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.refreshWhiteBalanceStatus()
            }
        }
    }

    func stopWhiteBalanceStatusPolling() {
        DispatchQueue.main.async { [weak self] in
            self?.whiteBalanceStatusTimer?.invalidate()
            self?.whiteBalanceStatusTimer = nil
        }
    }

    func applyCaptureColorAdjustment() {
        capturer?.applyWhiteBalanceAdjustment(
            temperature: wbTemperature,
            tint: wbTint,
            red: wbRed,
            green: wbGreen,
            blue: wbBlue,
            black: wbBlack,
            white: wbWhite,
            amber: wbAmber
        )
    }

    /// PC STOMP 下发 → 更新面板 + 应用硬件 WB（iOS 本地滑块不回传 PC）
    private func applyRemoteCaptureColor(_ cfg: ThinRemoteConfig) {
        let apply = { [self] in
            if let v = cfg.wbTemperature { self.wbTemperature = max(-1, min(1, v)) }
            if let v = cfg.wbTint { self.wbTint = max(-1, min(1, v)) }
            if let v = cfg.wbRed { self.wbRed = max(-1, min(1, v)) }
            if let v = cfg.wbGreen { self.wbGreen = max(-1, min(1, v)) }
            if let v = cfg.wbBlue { self.wbBlue = max(-1, min(1, v)) }
            if let v = cfg.wbBlack { self.wbBlack = max(-1, min(1, v)) }
            if let v = cfg.wbWhite { self.wbWhite = max(-1, min(1, v)) }
            if let v = cfg.wbAmber { self.wbAmber = max(-1, min(1, v)) }
            self.applyCaptureColorAdjustment()
            self.captureColorRemoteTick &+= 1
            print("🎨 [CaptureColor] PC→iOS temp=\(String(format: "%.2f", self.wbTemperature)) tint=\(String(format: "%.2f", self.wbTint)) amber=\(String(format: "%.2f", self.wbAmber)) rgb=(\(String(format: "%.2f", self.wbRed)),\(String(format: "%.2f", self.wbGreen)),\(String(format: "%.2f", self.wbBlue))) bw=(\(String(format: "%.2f", self.wbBlack)),\(String(format: "%.2f", self.wbWhite))) tick=\(self.captureColorRemoteTick)")
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func resetCaptureColorAdjustment() {
        wbTemperature = 0
        wbTint = 0
        wbRed = 0
        wbGreen = 0
        wbBlue = 0
        wbBlack = 0
        wbWhite = 0
        wbAmber = 0
        capturer?.resetWhiteBalanceAdjustment()
    }

    private func applyOutputPixelFormatForCurrentRange() {
        let pixelFormat: OSType = captureRangeMode == .videoRange420v
            ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        capturer?.setOutputPixelFormat(pixelFormat)
    }

    /// 🔥 查找最佳匹配格式
    private func findBestFormat(for device: AVCaptureDevice, targetWidth: Int, targetHeight: Int, targetFps: Int) -> AVCaptureDevice.Format? {
        let allFormats = CustomAVCaptureVideoCapturer.supportedFormats(for: device)
        let requiredFps = max(30, targetFps)

        func pixelFormatString(_ fmt: AVCaptureDevice.Format) -> String {
            let pixelFmt = CMFormatDescriptionGetMediaSubType(fmt.formatDescription)
            return String(format: "%c%c%c%c",
                          (pixelFmt >> 24) & 0xFF,
                          (pixelFmt >> 16) & 0xFF,
                          (pixelFmt >> 8) & 0xFF,
                          pixelFmt & 0xFF)
        }

        func matchesResolution(_ fmt: AVCaptureDevice.Format) -> Bool {
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let w = Int(dims.width)
            let h = Int(dims.height)
            return (w == targetWidth && h == targetHeight) || (w == targetHeight && h == targetWidth)
        }

        func maxFps(_ fmt: AVCaptureDevice.Format) -> Int {
            Int(fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }

        func matchesRange(_ fmt: AVCaptureDevice.Format) -> Bool {
            switch captureRangeMode {
            case .any: return true
            case .fullRange420f: return pixelFormatString(fmt) == "420f"
            case .videoRange420v: return pixelFormatString(fmt) == "420v"
            }
        }

        func matchesBinning(_ fmt: AVCaptureDevice.Format) -> Bool {
            switch captureBinningMode {
            case .any: return true
            case .binned: return fmt.isVideoBinned
            case .nonBinned: return !fmt.isVideoBinned
            }
        }

        func choose(_ formats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
            formats.sorted { lhs, rhs in
                let lFps = maxFps(lhs)
                let rFps = maxFps(rhs)
                if lFps != rFps { return lFps < rFps }
                let lDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let rDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                return Int(lDims.width * lDims.height) < Int(rDims.width * rDims.height)
            }.first
        }

        let sameResolution = allFormats.filter(matchesResolution)
        let base = sameResolution.isEmpty ? allFormats : sameResolution
        print("   格式切换: 分辨率=\(targetWidth)x\(targetHeight), range=\(captureRangeMode.rawValue), binned=\(captureBinningMode.rawValue), 最低FPS=\(requiredFps)")
        for (idx, fmt) in base.enumerated() {
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let binned = fmt.isVideoBinned ? "Binned" : "NonBinned"
            print("      [\(idx)] \(dims.width)x\(dims.height) @\(maxFps(fmt))fps \(pixelFormatString(fmt)) \(binned)")
        }

        let strict = base.filter { matchesRange($0) && matchesBinning($0) && maxFps($0) >= requiredFps }
        let rangeBinning = base.filter { matchesRange($0) && matchesBinning($0) }
        let rangeOnly = base.filter { matchesRange($0) && maxFps($0) >= requiredFps }
        let binnedOnly = base.filter { matchesBinning($0) && maxFps($0) >= requiredFps }
        let fpsOnly = base.filter { maxFps($0) >= requiredFps }

        let selected: AVCaptureDevice.Format?
        let reason: String
        if let fmt = choose(strict) {
            selected = fmt
            reason = "strict"
        } else if let fmt = choose(rangeBinning) {
            selected = fmt
            reason = "range+binned fps fallback"
        } else if let fmt = choose(rangeOnly) {
            selected = fmt
            reason = "range only"
        } else if let fmt = choose(binnedOnly) {
            selected = fmt
            reason = "binned only"
        } else if let fmt = choose(fpsOnly) {
            selected = fmt
            reason = "fps only"
        } else {
            selected = choose(base)
            reason = "best available below 30fps"
        }

        if let selected {
            let dims = CMVideoFormatDescriptionGetDimensions(selected.formatDescription)
            let binned = selected.isVideoBinned ? "Binned" : "NonBinned"
            print("   ✅ 格式选中(\(reason)): \(dims.width)x\(dims.height) @\(maxFps(selected))fps \(pixelFormatString(selected)) \(binned)")
        }
        return selected
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // 以下是旧的复杂逻辑（已废弃，保留注释供参考）
    // ═══════════════════════════════════════════════════════════════════════════
    
    /*
    // 旧的 session.beginConfiguration() 方式不可靠，已删除
    */
    
    
    /// 检查当前是否是前置摄像头
    private func isFrontCameraActive() -> Bool {
        return capturer?.currentDevice?.position == .front
    }

    // 保存当前目标码率，用于周期性强制重置
    private var targetMinBitrateKbps: Int = 2000
    private var targetBitrateKbps: Int = 2000
    private var bitrateEnforceTimer: Timer?
    
    func setMaxBitrateKbps(_ kbps: Int) {
        setBitrateRangeKbps(min: kbps, max: kbps)
    }

    func setBitrateRangeKbps(min minKbps: Int, max maxKbps: Int) {
        let minK = max(100, min(minKbps, maxKbps))
        let maxK = max(minK, maxKbps)
        targetMinBitrateKbps = minK
        targetBitrateKbps = maxK
        
        // 记录 sender
        if videoSender == nil {
            videoSender = pc?.senders.first(where: { $0.track?.kind == kRTCMediaStreamTrackKindVideo })
        }
        guard let sender = videoSender else {
            if currentConnMode == .p2p {
                // 🔥 2026-07-02: P2P 无 videoSender 属正常（sender 在 P2PManager.viewerSenders，
                //   码率由 applyEffectiveBitrateToWebRTC → applyBitrateToAllSessions 落地）。
                //   这里补启动周期纠偏定时器——原来因提前 return，P2P 的 3s 纠偏从未运行。
                startBitrateEnforcement()
            } else {
                print("⚠️ videoSender 为空，无法设置码率")
            }
            return
        }
        
        var params = sender.parameters
        if params.encodings.isEmpty {
            params.encodings = [RTCRtpEncodingParameters()]
        }
        
        // 🔥 WebRTC min/max 码率（按档位最低/最高 × 清晰度百分比）
        let minBps = minK * 1000
        let maxBps = maxK * 1000
        
        params.encodings[0].maxBitrateBps = NSNumber(value: maxBps)
        params.encodings[0].minBitrateBps = NSNumber(value: minBps)
        
        // 🔥 WebRTC推送FPS = targetOutputFPS（已经是 fps/4 后的值）
        // targetOutputFPS 在 setAverageOutputFPS 中已经做了 /4 处理
        // 例如：后端发120fps → targetOutputFPS=30fps
        // 例如：后端发60fps → targetOutputFPS=30fps
        let targetFps = frameThrottler?.targetSendFps ?? targetOutputFPS
        let maxPushFps = getMaxPushFpsForCurrentProfile()
        let webrtcFps = min(maxPushFps, targetFps)  // 直接使用，不再 /2
        params.encodings[0].maxFramerate = NSNumber(value: webrtcFps)
        
        // 🔍 详细FPS计算日志
        print("📊 [FPS计算] 档位=\(currentProfile), 推送目标=\(targetFps)fps, 上限=\(maxPushFps)fps → WebRTC=\(webrtcFps)fps")
        
        // 🔥 设置网络优先级为最高
        params.encodings[0].networkPriority = .high
        
        // 🔥 应用当前档位的缩放比例
        let scaleDown = currentLadder[currentProfile]?.scaleDown ?? 1.0
        params.encodings[0].scaleResolutionDownBy = NSNumber(value: scaleDown)
        currentResolutionScale = scaleDown
        
        // 🔥🔥 关键：禁用 WebRTC 自动分辨率调整
        // .maintainResolution = 保持分辨率，网络差时降低帧率而不是分辨率
        // 这样可以防止 WebRTC 自动把 1920x1440 降到 960x720
        // RTCDegradationPreference: 0=disabled, 1=maintainFramerate, 2=maintainResolution, 3=balanced
        params.degradationPreference = NSNumber(value: 2)  // maintainResolution
        
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
            let verifyFps = encoding.maxFramerate?.intValue ?? 0
            let verifyScale = encoding.scaleResolutionDownBy?.doubleValue ?? 1.0
            let targetFps = frameThrottler?.targetSendFps ?? targetOutputFPS
            let maxPushFpsLimit = getMaxPushFpsForCurrentProfile()
            print("🔒 WebRTC码率: min=\(minK)kbps max=\(maxK)kbps")
            print("   FPS设置: 推送目标=\(targetFps)fps, 上限=\(maxPushFpsLimit)fps → WebRTC=\(verifyFps)fps")
            let expectedScale = currentLadder[currentProfile]?.scaleDown ?? 1.0
            print("   分辨率: \(currentCaptureWidth)x\(currentCaptureHeight) (scale=\(verifyScale), 应为\(expectedScale))")
            if abs(verifyScale - expectedScale) > 0.01 {
                print("   ⚠️ 警告: scaleResolutionDownBy 不匹配! 实际=\(verifyScale), 期望=\(expectedScale)")
            }
        }
        
        // 🔄 启动周期性强制码率（每3秒重新设置一次，对抗WebRTC内部调整）
        startBitrateEnforcement()
    }
    
    // MARK: - 分辨率缩放（热切换，不断流）
    /// 设置输出分辨率缩放比例
    /// - Parameter scale: 缩放比例，1.0=不缩放，1.33=缩小到3/4，3.0=缩小到1/3
    /// - 例如：采集1920x1440，scale=1.33 → 输出1440x1080
    /// - 例如：采集1920x1440，scale=3.0 → 输出640x480
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
        
        // 🔥 应用缩放比例
        params.encodings[0].scaleResolutionDownBy = NSNumber(value: currentResolutionScale)
        // 🔥🔥 禁用 WebRTC 自动分辨率调整
        // RTCDegradationPreference: 0=disabled, 1=maintainFramerate, 2=maintainResolution, 3=balanced
        params.degradationPreference = NSNumber(value: 2)  // maintainResolution
        sender.parameters = params
        
        // 计算输出分辨率
        let outputWidth = Int(Double(currentCaptureWidth) / currentResolutionScale)
        let outputHeight = Int(Double(currentCaptureHeight) / currentResolutionScale)
        print("📐 [分辨率] 缩放: \(oldScale) → \(currentResolutionScale)")
        print("   采集: \(currentCaptureWidth)x\(currentCaptureHeight) → 输出: \(outputWidth)x\(outputHeight)")
    }
    
    /// 根据档位获取分辨率缩放比例
    func getResolutionScaleForProfile(_ profile: LadderProfile) -> Double {
        return currentLadder[profile]?.scaleDown ?? 1.0
    }
    
    /// 🔥 获取档位的实际采集分辨率 + 采集fps（⭐ 全项目采集fps的唯一收口点）
    /// - ultra: 采集 1280x720 (16:9)
    /// - p4k iPhone 15+: 直接采集 1920x1080 (16:9)
    /// - 其他: 采集 1920x1440 (4:3)，通过 scaleDown 缩放输出
    /// - 返回的 fps 已经过 effectiveCaptureFps 换算（低功率开关钉30fps，与档位原始fps无关）——
    ///   所有需要「档位对应的采集fps」的调用方都应该走这个函数（或至少走 effectiveCaptureFps），
    ///   不要再直接读 currentLadder[profile]?.fps，否则低功率开关在那个分支会失效。
    /// - Returns: (width, height, fps)
    func getCaptureResolutionForProfile(_ profile: LadderProfile) -> (width: Int, height: Int, fps: Int) {
        guard let preset = currentLadder[profile] else {
            return (1920, 1440, effectiveCaptureFps(60))  // 默认 4:3
        }
        let fps = effectiveCaptureFps(preset.fps)

        switch profile {
        case .ultra:
            return (1280, 720, fps)
        case .p4k:
            return isIPhone15OrNewer() ? (1920, 1080, fps) : (1920, 1440, fps)
        case .high:
            return (1440, 1080, fps)   // 直接采集 1440×1080，无缩放
        case .low:
            return (640, 480, fps)     // 直接采集 640×480，无缩放
        case .standard:
            return (1024, 768, fps)    // 直接采集 1024×768，无缩放
        default:
            return (1920, 1440, fps)
        }
    }
    
    /// 🔥 根据当前档位获取最高推送FPS（直接使用 LadderPreset.maxPushFps）
    /// - 超清 (1920x1440): 最高 60fps
    /// - 超高帧 (1440x1080): 最高 60fps  
    /// - 高清 (1440x1080): 最高 60fps（与超高帧相同配置）
    /// - 标清 (640x480): 最高 60fps
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
        // 🔥 2026-07-02 P2P 断链修复：P2P 模式 videoSender 恒 nil → 原实现直接 return，
        //   紧急降码率(emergencyBitrateScale)/切档码率落不到 P2P 编码器。
        //   走 P2PManager 落到各直连会话（applyBitrate 内部按 p2pBitrateRangeKbps 已含紧急系数）。
        if currentConnMode == .p2p {
            p2pManager.applyBitrateToAllSessions()
            p2pManager.applyFramerateToAllSessions()
            malvshezhingLog("[码率] 立即强制(P2P) → 已同步全部直连会话 目标=\(targetMinBitrateKbps)-\(targetBitrateKbps)kbps")
            return
        }
        guard let sender = videoSender else { return }
        
        var params = sender.parameters
        if params.encodings.isEmpty { return }
        
        // 🔥 WebRTC min/max 码率
        let minBps = targetMinBitrateKbps * 1000
        let maxBps = targetBitrateKbps * 1000
        
        // 立即强制设置码率
        params.encodings[0].minBitrateBps = NSNumber(value: minBps)
        params.encodings[0].maxBitrateBps = NSNumber(value: maxBps)
        params.encodings[0].isActive = true
        
        // 🔥 WebRTC推送FPS = targetOutputFPS（已经是 fps/4 后的值）
        let targetFps = frameThrottler?.targetSendFps ?? targetOutputFPS
        let maxPushFps = getMaxPushFpsForCurrentProfile()
        let webrtcFps = min(maxPushFps, targetFps)  // 直接使用，不再 /2
        params.encodings[0].maxFramerate = NSNumber(value: webrtcFps)
        
        // 🔥 设置网络优先级为最高
        params.encodings[0].networkPriority = .high
        
        // 🔥 应用当前档位的缩放比例
        let scaleDown2 = currentLadder[currentProfile]?.scaleDown ?? 1.0
        params.encodings[0].scaleResolutionDownBy = NSNumber(value: scaleDown2)
        currentResolutionScale = scaleDown2
        
        // 🔥🔥 禁用 WebRTC 自动分辨率调整
        // RTCDegradationPreference: 0=disabled, 1=maintainFramerate, 2=maintainResolution, 3=balanced
        params.degradationPreference = NSNumber(value: 2)  // maintainResolution
        
        sender.parameters = params
        malvshezhingLog("[码率] 立即强制 min=\(minBps/1000) max=\(maxBps/1000) kbps WebRTCfps=\(webrtcFps) 档位=\(currentProfile)")
        
        // 🔥 连续设置两次，确保立即生效（WebRTC有时需要多次设置才能立即响应）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, let sender = self.videoSender else { return }
            var params2 = sender.parameters
            if params2.encodings.isEmpty { return }
            
            let minBps2 = self.targetMinBitrateKbps * 1000
            let maxBps2 = self.targetBitrateKbps * 1000
            
            params2.encodings[0].minBitrateBps = NSNumber(value: minBps2)
            params2.encodings[0].maxBitrateBps = NSNumber(value: maxBps2)
            params2.encodings[0].isActive = true
            
            // 🔥 WebRTC推送FPS = targetOutputFPS（已经是 fps/4 后的值）
            let targetFps2 = self.frameThrottler?.targetSendFps ?? self.targetOutputFPS
            let maxPushFps2 = self.getMaxPushFpsForCurrentProfile()
            let webrtcFps2 = min(maxPushFps2, targetFps2)  // 直接使用，不再 /2
            params2.encodings[0].maxFramerate = NSNumber(value: webrtcFps2)
            
            params2.encodings[0].networkPriority = .high
            // 🔥 应用当前档位的缩放比例
            let scaleDown3 = self.currentLadder[self.currentProfile]?.scaleDown ?? 1.0
            params2.encodings[0].scaleResolutionDownBy = NSNumber(value: scaleDown3)
            // 🔥🔥 禁用 WebRTC 自动分辨率调整
            params2.degradationPreference = NSNumber(value: 2)  // maintainResolution
            sender.parameters = params2
            
            // 计算输出分辨率
            let outputW = Int(Double(self.currentCaptureWidth) / scaleDown3)
            let outputH = Int(Double(self.currentCaptureHeight) / scaleDown3)
            self.malvshezhingLog("[码率] 二次确认 min=\(minBps2/1000) max=\(maxBps2/1000) kbps WebRTCfps=\(webrtcFps2) 输出=\(outputW)x\(outputH) scale=\(scaleDown3)")
        }
    }
    
    // 🔄 周期性强制码率，对抗WebRTC自动调整
    private func startBitrateEnforcement() {
        bitrateEnforceTimer?.invalidate()
        bitrateEnforceTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // 🔥 2026-07-02 P2P 断链修复：P2P 无 videoSender，周期纠偏落到直连会话
            //   （enforceBitrateIfDrifted 仅在被 WebRTC 内部改动时回写，无谓 reconfigure 为零）。
            if self.currentConnMode == .p2p {
                self.p2pManager.enforceBitrateIfDrifted()
                return
            }
            guard let sender = self.videoSender else { return }
            
            var params = sender.parameters
            if params.encodings.isEmpty { return }
            
            let minBps = self.targetMinBitrateKbps * 1000
            let maxBps = self.targetBitrateKbps * 1000
            
            let currentMin = params.encodings[0].minBitrateBps?.intValue ?? 0
            let currentMax = params.encodings[0].maxBitrateBps?.intValue ?? 0
            
            if currentMin != minBps || currentMax != maxBps {
                params.encodings[0].minBitrateBps = NSNumber(value: minBps)
                params.encodings[0].maxBitrateBps = NSNumber(value: maxBps)
                params.encodings[0].isActive = true
                // 🔥🔥 禁用 WebRTC 自动分辨率调整
                // RTCDegradationPreference: 0=disabled, 1=maintainFramerate, 2=maintainResolution, 3=balanced
        params.degradationPreference = NSNumber(value: 2)  // maintainResolution
                sender.parameters = params
                self.malvshezhingLog("[码率] 周期纠正 WebRTC被改 min=\(currentMin/1000)→\(minBps/1000) max=\(currentMax/1000)→\(maxBps/1000) kbps 实际=\(self.currentKbps) 目标=\(self.targetBitrateKbps)")
            }
        }
    }
    
    // 停止强制码率
    private func stopBitrateEnforcement() {
        bitrateEnforceTimer?.invalidate()
        bitrateEnforceTimer = nil
    }
    
    // MARK: - ⭐ §53.13 推流健康检查（回前台 / 唤醒后的统一恢复出口，对标 Android publishHealthCheck）

    /// App 从后台回到前台（或其它"可能已经断了很久"的时机）后，自检整条推流链路并恢复。
    ///
    /// **为什么必须有这个**：iOS 被挂到后台时相机会被系统收走、socket 会死、ICE 会断，而
    /// `isPublishing` 还停在 true —— 于是 `tryAutoPublish` 的 `!isPublishing` 前置条件不成立、
    /// 不会重推；观看端那边 PC 的 `WEBRTC_REQUEST` 也只重发 5 次（~7.5s）早就放弃了。
    /// 结果就是**谁都不再发起恢复，PC 上永远停在最后一帧**（实测："从后台切到前台画面静止"）。
    /// Android 早有 `publishHealthCheck` 兜住同样的场景，iOS 一直缺这一环。
    ///
    /// 恢复动作按"从轻到重"排：先救采集 → 没在推流就重推 → 在推流则按模式修媒体链路。
    @MainActor
    func publishHealthCheck(_ source: String) {
        guard !isCameraSleeping else { return }
        print("🔄 [健康检查] \(source): publishing=\(isPublishing) mode=\(currentConnMode)")

        // ① 采集：长时间没有新帧 = 相机在后台被收走了没回来 → 用最近一次配置整体重建会话。
        //    这里比看门狗的 3s 窗口更早介入（回前台就该立刻救），恢复后补一拍 IDR。
        if let t = frameThrottler, t.hasReceivedFrame, t.lastCaptureFrameAt > 0 {
            let gap = CFAbsoluteTimeGetCurrent() - t.lastCaptureFrameAt
            if gap >= 1.5 {
                print("🚑 [健康检查] \(source): 已 \(String(format: "%.1f", gap))s 无采集帧 → 重建相机会话")
                capturer?.restartSessionFromLastConfig()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.forceKeyframe()
                }
            }
        }

        // ② 压根没在推流（后台被系统停掉）→ 重新推一次
        guard isPublishing else {
            if !baseStreamKey.isEmpty {
                print("🔄 [健康检查] \(source): 未在推流 → 重新推流")
                startPublish(initialProfile: currentProfile)
            }
            return
        }

        // ③ 在推流：按模式检查媒体链路死没死
        switch currentConnMode {
        case .p2p:
            // 死掉的会话拆掉 + HANGUP，让 PC 重发 REQUEST（复用切网恢复那套已验证动作）
            p2pManager.recoverSessionsIfBroken(reason: source)
        case .srs:
            let st = pc?.iceConnectionState
            let dead = (pc == nil || st == .failed || st == .disconnected || st == .closed)
            if dead {
                print("🚑 [健康检查] \(source): SRS 媒体连接已死(\(String(describing: st))) → 停流后重推")
                let profile = currentProfile
                stopPublish()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.startPublish(initialProfile: profile)
                }
            } else {
                print("▶️ [健康检查] \(source): SRS 媒体连接正常(\(String(describing: st)))")
            }
        default:
            break
        }
    }

    // MARK: - 🚑 采集看门狗（2026-07-02 切档概率卡死修复）

    private func startCaptureWatchdog() {
        stopCaptureWatchdog()
        captureWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.captureWatchdogTick()
        }
        print("🚑 [采集看门狗] 已启动（推流中连续\(Int(captureWatchdogGapSec))s无采集帧→自动重建相机会话）")
    }

    private func stopCaptureWatchdog() {
        captureWatchdogTimer?.invalidate()
        captureWatchdogTimer = nil
    }

    private func captureWatchdogTick() {
        guard isPublishing, !isCameraSleeping else { return }

        // ⭐ §53.14 推流侧 2s 心跳诊断行（排「首连不出画面」「每几秒卡一次」）：
        //   把"设备这边到底在不在发"一次说清——链路/编码/推送fps/码率/首帧/距上帧。
        //   与上面的 [采集诊断]（相机侧）配成一对：一眼分清是采集断了还是发送断了。
        let hbLast = frameThrottler?.lastCaptureFrameAt ?? 0
        let hbGapMs = hbLast > 0 ? Int((CFAbsoluteTimeGetCurrent() - hbLast) * 1000) : -1
        // ⭐ §53.16：必须带 **P2P 会话数/已连接数** —— 上一版只有"观看端N台"（那是 PC 在线心跳，
        //   跟会话通没通是两回事），实测遇到「采集正常、推送=0fps、PC 没画面」时，光看这行
        //   根本判断不出是"PC 没来请求"还是"会话建了没连上"，只能回头翻 [P2P] 行。
        let p2pInfo: String
        if currentConnMode == .p2p {
            let total = p2pManager.viewerCount
            let live = p2pManager.connectedViewerPeerConnections.count
            p2pInfo = " P2P会话=\(total)(已连\(live))"
        } else {
            p2pInfo = ""
        }
        print("💓 [推流诊断] 链路=\(currentConnMode) 编码=\(H265Support.shared.effectiveCodecString) 推送=\(WebSocketManager.publishingSendFps)fps 码率=\(WebSocketManager.publishingKbps)kbps 网络=\(WebSocketManager.networkQuality) 首帧=\(frameThrottler?.hasReceivedFrame == true ? "已到" : "未到") 距上帧=\(hbGapMs)ms 观看端=\(SessionPolicy.shared.onlineViewerCount)台\(p2pInfo)")

        guard let throttler = frameThrottler, throttler.hasReceivedFrame else { return }  // 从未出过帧=还在启动，不误判
        let last = throttler.lastCaptureFrameAt
        guard last > 0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let gap = now - last
        guard gap >= captureWatchdogGapSec else { return }
        guard now - lastCaptureRecoveryTime >= captureRecoveryMinIntervalSec else { return }
        lastCaptureRecoveryTime = now
        print("🚑 [采集看门狗] 推流中已 \(String(format: "%.1f", gap))s 无采集帧（档位=\(currentProfile)）→ 重建相机会话恢复")
        capturer?.restartSessionFromLastConfig()
        // 会话恢复出帧后补 IDR，观看端立即出画面（forceKeyframe 已按 SRS/P2P 模式路由）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.forceKeyframe()
        }
    }

    // MARK: - 关键帧控制（减少卡顿恢复时间）
    
    /// 启动关键帧定时器：每隔 keyframeIntervalSec 秒强制发送一个关键帧
    private func startKeyframeTimer() {
        stopKeyframeTimer()
        keyframeTimer = Timer.scheduledTimer(withTimeInterval: keyframeIntervalSec, repeats: true) { [weak self] _ in
            self?.forceKeyframe()
        }
        DispatchQueue.global(qos: .utility).async {
            print("🔑 [关键帧] 定时器已启动，每 \(self.keyframeIntervalSec) 秒强制一个 IDR")
        }
    }
    
    /// 停止关键帧定时器
    private func stopKeyframeTimer() {
        keyframeTimer?.invalidate()
        keyframeTimer = nil
        keyframeAutoStopWork?.cancel()
        keyframeAutoStopWork = nil
    }
    
    /// ⭐ 点2 修复：设置关键帧间隔；若定时器正在运行则立即重启，使新间隔生效。
    /// ⭐ 2026-06-25 发热优化：常态不再常驻定时器，故此处改为「无论当前是否在跑都启动」，
    ///   即调用本方法即代表「进入弱网临时短 GOP 模式」（仅 critical/high 分支调用）。
    private func setKeyframeInterval(_ sec: Double) {
        keyframeIntervalSec = sec
        startKeyframeTimer()   // 启动/重启短 GOP 定时器（常态由 stopKeyframeTimer 关闭）
    }

    /// ⭐ 2026-06-25 发热优化：弱网临时短 GOP 的「安全阀」。
    ///   critical/high 触发短 GOP 快恢复后，若 keyframeTimerAutoStopSec 秒内没有新的弱网指令，
    ///   自动 stopKeyframeTimer 归位到常态长 GOP，避免短 GOP 常驻持续发热。
    ///   每次调用都会重置倒计时（弱网持续期间不断续期，恢复后才真正停）。
    private func scheduleKeyframeTimerAutoStop() {
        keyframeAutoStopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.keyframeTimer != nil else { return }
            self.stopKeyframeTimer()
            self.malvshezhingLog("[关键帧] 弱网短 GOP 用完，自动归位常态（关闭定时强制）")
        }
        keyframeAutoStopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + keyframeTimerAutoStopSec, execute: work)
    }
    
    /// 🔑 强制关键帧（本地强制路径）。
    ///
    /// 【官方做法说明（2026-06 调研）】iOS 上「主动强制 IDR」的官方标准做法并不存在于 Objective-C/Swift SDK：
    ///  1. 标准官方机制 = 接收侧驱动的 RTCP PLI/FIR：观看端编码器需要关键帧时发 PLI，
    ///     发送侧 WebRTC 引擎自动产生 IDR。这是设计上的「正道」，无需我们手动干预。
    ///  2. libwebrtc C++ 层确有主动接口 `RtpSenderInterface::GenerateKeyFrame(rids)`，
    ///     但官方 iOS SDK 的 `RTCRtpSender`（含 stasel/WebRTC 预编译包）从未把它暴露到 ObjC/Swift——
    ///     头文件里仅有 senderId / parameters / track，没有 generateKeyFrame。故 iOS 上无法直接调用。
    ///  3. W3C 的 `RTCRtpSender.generateKeyFrame()` 是 Web/JS（encoded-transform）的 API，原生 iOS 不可用。
    ///  4. `adaptOutputFormat` 仅在「输出格式真正变化」时才触发编码器重配出 IDR；传相同分辨率/帧率是 no-op。
    ///
    /// 结论：iOS 原生 + 标准 RTCDefaultVideoEncoderFactory 下，没有可调用的官方本地强制 IDR API。
    /// 因此「主动本地强制」沿用社区通行的码率微调（setParameters 触发编码器重配）作为兜底；
    /// 而干净的「按需」恢复主路仍是 RTCP PLI（PC 发，编码器自动响应）。
    func forceKeyframe() {
        // 🔥 2026-07-02 P2P 断链修复：P2P 模式 sender 在 P2PManager.viewerSenders（videoSender 恒 nil），
        //   原实现直接空操作 → PLI 响应 / PC request_keyframe / 切档 IDR 在 P2P 全部失效，
        //   弱网花屏恢复只能赌 libwebrtc 内部机制。现按连接模式路由。
        if currentConnMode == .p2p {
            p2pManager.forceKeyframeAllSessions()
            return
        }
        forceKeyframeViaBitrate()
    }
    
    /// 码率微调强制 IDR：临时 +1kbps 再恢复 → 触发编码器重配发 IDR。
    /// iOS WebRTC 下唯一可靠的本地强制关键帧方式（无自定义编码器、SDK 未暴露 GenerateKeyFrame 时）。
    /// ⭐ 2026-06-25 健壮性修复：原实现把「未限制码率」(maxBitrateBps==nil) 误恢复成 3Mbps，
    ///    等于给码流凭空加了 3M 上限。改为原样保存并恢复 nil，避免篡改码率配置。
    private func forceKeyframeViaBitrate() {
        guard let sender = videoSender else { return }
        
        var params = sender.parameters
        if params.encodings.isEmpty { return }
        
        // 原样保存（可能为 nil = 不限制码率，官方语义不可篡改）
        let originalMaxBitrate = params.encodings[0].maxBitrateBps
        let baseBitrate = originalMaxBitrate?.intValue ?? 3_000_000
        let tempBitrate = baseBitrate + 1000  // 微调 +1kbps，仅用于触发编码器重配
        
        // 第一步：微调码率
        params.encodings[0].maxBitrateBps = NSNumber(value: tempBitrate)
        sender.parameters = params
        
        // 第二步：立即恢复原码率（在后台队列延迟执行，避免阻塞）。恢复为原始值（含 nil）
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self = self, let sender = self.videoSender else { return }
            var params2 = sender.parameters
            if !params2.encodings.isEmpty {
                params2.encodings[0].maxBitrateBps = originalMaxBitrate
                sender.parameters = params2
            }
        }
    }
    
    /// 通过 videoSource.adaptOutputFormat 请求关键帧。
    /// ⚠️ 仅在「输出格式真正变化」时才会触发 IDR；传相同分辨率/帧率为 no-op。
    /// 本地强制关键帧请用 forceKeyframe()。
    func requestKeyframeFromSource() {
        guard let source = videoSource else { return }
        
        let fps = frameThrottler?.targetSendFps ?? 30
        source.adaptOutputFormat(
            toWidth: Int32(currentCaptureWidth), 
            height: Int32(currentCaptureHeight), 
            fps: Int32(fps)
        )
    }

    func recapture(width: Int, height: Int, fps: Int) {
        // 🔍 调试：打印调用
        print("🔍🔍🔍 [recapture] 被调用！目标: \(width)x\(height)@\(fps)fps")
        
        // 选择摄像头（沿用当前，若无则取后置）
        
        let devOpt: AVCaptureDevice? = {
                if let inDev = capturer?.currentDevice {
                    return inDev
                }
                let devices = CustomAVCaptureVideoCapturer.captureDevices()
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
        
        // 🔥 使用当前档位的真实分辨率和帧率采集
        // 🔥 使用采集分辨率（4:3统一1920x1440，16:9用1280x720）
        let captureRes = getCaptureResolutionForProfile(currentProfile)
        let targetWidth = captureRes.width
        let targetHeight = captureRes.height
        let targetFps = captureRes.fps
        currentCaptureWidth = targetWidth
        currentCaptureHeight = targetHeight
        
        // 🔥 打印当前档位和摄像头信息
        print("🎯档位🎯 [recapture] 采集=\(targetWidth)x\(targetHeight)@\(targetFps)fps, 档位=\(currentProfile), 摄像头=\(dev.position == .back ? "后置" : "前置")")

        let allFormats = CustomAVCaptureVideoCapturer.supportedFormats(for: dev)
        
        // 🔥 查找匹配目标分辨率的格式
        let matchingFormats = allFormats.filter { fmt in
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let w = Int(dims.width)
            let h = Int(dims.height)
            return (w == targetWidth && h == targetHeight) || (w == targetHeight && h == targetWidth)
        }
        
        // 🔥 根据目标帧率选择不同的策略
        let isHighFpsMode = targetFps > 60
        
        let candidateFormats: [AVCaptureDevice.Format]
        
        if isHighFpsMode {
            // 🔥 高帧率模式：选择支持目标帧率的格式
            let highFpsFormats = matchingFormats.filter { fmt in
                let maxFps = Int(fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                return maxFps >= targetFps
            }
            print("🎯档位🎯 高帧率模式: 目标\(targetFps)fps, 找到\(matchingFormats.count)个匹配格式, 其中\(highFpsFormats.count)个支持\(targetFps)fps+")
            
            if !highFpsFormats.isEmpty {
                candidateFormats = highFpsFormats
                print("🎯档位🎯 ✅ 使用支持\(targetFps)fps的格式")
            } else {
                candidateFormats = matchingFormats.isEmpty ? allFormats : matchingFormats
                print("🎯档位🎯 ⚠️ 无支持\(targetFps)fps的格式，使用最接近的格式")
            }
        } else {
            // 🔥 普通模式：优先精确60fps格式
            let exact60FpsFormats = matchingFormats.filter { fmt in
                let maxFps = Int(fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                return maxFps >= 59 && maxFps <= 61
            }
            let highFpsFormats = matchingFormats.filter { fmt in
                let maxFps = Int(fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                return maxFps >= targetFps
            }
            
            print("🎯档位🎯 普通模式: 目标\(targetFps)fps, 找到\(matchingFormats.count)个匹配格式 (精确60fps=\(exact60FpsFormats.count)个)")
            
            if !exact60FpsFormats.isEmpty {
                candidateFormats = exact60FpsFormats
                print("🎯档位🎯 ✅ 使用精确60fps格式")
            } else if !highFpsFormats.isEmpty {
                candidateFormats = highFpsFormats
                print("🎯档位🎯 ⚠️ 无精确60fps格式，使用支持\(targetFps)fps+的格式")
            } else {
                candidateFormats = matchingFormats.isEmpty ? allFormats : matchingFormats
                print("🎯档位🎯 ⚠️ 无\(targetFps)fps格式，从所有格式中选择")
            }
        }
        
        // 分辨率优先：先选最接近目标的，分辨率相同时选更接近目标fps的
        guard let best = candidateFormats.sorted(by: { f0, f1 in
            let a = CMVideoFormatDescriptionGetDimensions(f0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions(f1.formatDescription)
            let d0 = abs(Int(a.width) - targetWidth) + abs(Int(a.height) - targetHeight)
            let d1 = abs(Int(b.width) - targetWidth) + abs(Int(b.height) - targetHeight)
            if d0 != d1 { return d0 < d1 }
            
            // 分辨率相同时，选择最大fps更接近目标fps的
            let max0 = Int(f0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            let max1 = Int(f1.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            let diff0 = abs(max0 - targetFps)
            let diff1 = abs(max1 - targetFps)
            return diff0 < diff1
        }).first else { return }
          
        let maxFps = Int(best.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
        let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
        print("🎯档位🎯 选中格式: \(dims.width)x\(dims.height) 最大FPS=\(maxFps)")

        // 🔥 使用目标fps和格式支持的最大fps中较小的那个
        let useFps = min(targetFps, maxFps)
        currentCaptureFPS = useFps
        print("🎯档位🎯 采集FPS: \(useFps)fps (目标=\(targetFps), 格式最大=\(maxFps))")
           
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
               //print("🚀 重采集startCapture: format=\(dims.width)x\(dims.height) fps=\(finalFps) (由SDK设置帧率)")
               capturer.startCapture(with: dev, format: best, fps: finalFps)
               
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
        
        // ⭐ 2026-06-25 发热优化：常态【不】启动定时强制关键帧。
        //   旧实现 startKeyframeTimer() 常驻每 0.5~1s 强制一个 IDR（forceKeyframeViaBitrate 码率抖动），
        //   每个 I 帧编码算力是 P 帧数倍 → 编码器持续高负载，是 P2P/SRS 发热的主因。
        //   对齐同类 App 与 SRT 链路：常态信任「WebRTC 默认长 GOP + 按需 PLI」，不主动砸 I 帧。
        //   弱网快恢复改为「临时短 GOP、用完自动归位」（见 applyRemoteFps 的 critical/high 分支）。
        // startKeyframeTimer()   // ← 常态不再常驻；仅弱网临时启用
        stopKeyframeTimer()       // 确保任何残留定时器被关闭，回到常态
        badSeconds = 0; goodSeconds = 0
        kbpsHistory.removeAll()  // ✅ 重置码率历史
        fpsHistory.removeAll()    // ✅ 重置FPS历史

        // 🔥 每200ms抓一次stats（更敏感的自适应FPS检测）
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let self else { return }
                // 🔥 关键修复：P2P 模式下 PeerConnection 在 P2PManager.viewerSessions，self.pc 恒为 nil，
                //   旧代码 `guard let pc = self.pc` 直接 return，导致 stats 空转、上报 kbps/sendFps/networkQuality 恒为 0。
                //   按模式选取统计用的 PeerConnection：SRS 用 self.pc，P2P 用已连接的观看会话（取一路，代表本机发送码率）。
                // ⭐ 2026-07-02：改用 primaryStatsPeerConnection（按 pcId 排序取首个）。
                //   原 `.first` 在 Swift Dictionary 无序性下多观看端会来回换会话 → 累计值基线错乱 →
                //   假 PLI/假丢包/kbps 乱跳（曾引发网络极好也周期性强制 IDR → 攒帧卡顿）。
                let statsPC: RTCPeerConnection?
                if self.currentConnMode == .p2p {
                    statsPC = self.p2pManager.primaryStatsPeerConnection
                } else {
                    statsPC = self.pc
                }
                guard let pc = statsPC else { return }
                // 🔥 统计处理移到后台队列
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let self else { return }
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

                    // ⭐ 2026-07-03 §25.5：ICE 层 RTT + 选中路径 relay 检测
                    //   RTT 主源改 candidate-pair.currentRoundTripTime（STUN 探测自带，不依赖对端 RTCP RR）。
                    //   背景：GStreamer 拉流端 RR 时序脏会把 remote-inbound 的 roundTripTime 污染成恒定 450ms，
                    //   自适应据此把码率压到 0.2 并永久锁死（实测 15fps/300kbps 直到断开）。
                    var selectedPairId: String? = nil               // transport.selectedCandidatePairId
                    var pairRttSec: [String: Double] = [:]          // pairId → currentRoundTripTime(秒)
                    var pairLocalCandId: [String: String] = [:]     // pairId → localCandidateId
                    var pairRemoteCandId: [String: String] = [:]    // pairId → remoteCandidateId
                    var remoteCandType: [String: String] = [:]      // candidateId → host/srflx/prflx/relay
                    var nominatedPairIds: [String] = []             // 兜底：nominated+succeeded 的 pair
                    var localCandType: [String: String] = [:]       // candidateId → host/srflx/prflx/relay

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
                            // ⚠️ packetsLost 规范上是有符号(long)，可能为负（重传补回时倒退）。
                            //    必须按有符号读取后 clamp 到非负，否则负值经 uint64Value 会变成巨值，
                            //    后续差值 Int(...) 转换会崩溃（Not enough bits to represent...）。
                            if let v = s.values["packetsLost"] {
                                if let num = v as? NSNumber { packetsLost = UInt64(max(0, num.int64Value)) }
                                else if let d = v as? Double { packetsLost = UInt64(max(0, d)) }
                                else if let i = v as? Int { packetsLost = UInt64(max(0, i)) }
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
                        } else if type == "transport" {
                            if let v = s.values["selectedCandidatePairId"] as? String { selectedPairId = v }
                        } else if type == "candidate-pair" {
                            let pairId = s.id
                            if let v = s.values["currentRoundTripTime"] {
                                if let num = v as? NSNumber { pairRttSec[pairId] = num.doubleValue }
                                else if let d = v as? Double { pairRttSec[pairId] = d }
                            }
                            if let lc = s.values["localCandidateId"] as? String { pairLocalCandId[pairId] = lc }
                            if let rc = s.values["remoteCandidateId"] as? String { pairRemoteCandId[pairId] = rc }
                            let nominated = (s.values["nominated"] as? NSNumber)?.boolValue ?? false
                            let succeeded = (s.values["state"] as? String) == "succeeded"
                            if nominated && succeeded { nominatedPairIds.append(pairId) }
                        } else if type == "local-candidate" {
                            if let ct = s.values["candidateType"] as? String { localCandType[s.id] = ct }
                        } else if type == "remote-candidate" {
                            if let ct = s.values["candidateType"] as? String { remoteCandType[s.id] = ct }
                        }
                    }

                    // ⭐ 选中候选对：优先 transport.selectedCandidatePairId，否则取 nominated+succeeded 的第一个
                    let activePairId = selectedPairId ?? nominatedPairIds.first
                    // ICE 层 RTT（秒）：仅在选中候选对上有读数时采用
                    var iceRttSec: Double = 0.0
                    if let pid = activePairId, let r = pairRttSec[pid], r > 0 { iceRttSec = r }
                    // 选中路径的本端/远端候选类型（host/srflx/prflx/relay）
                    var localPathType: String? = nil
                    var remotePathType: String? = nil
                    if let pid = activePairId {
                        if let lcId = pairLocalCandId[pid] { localPathType = localCandType[lcId] }
                        if let rcId = pairRemoteCandId[pid] { remotePathType = remoteCandType[rcId] }
                    }
                    // ⭐ §25.7：同 WiFi 判定 = 选中候选对 host↔host（两侧类型都拿到才判定，防 stats 未就绪误判）
                    //   §53.21：无 TURN/STUN 后本端候选只有 host，pathIsRelay 判定已随中继代码删除。
                    let pathIsLan = (localPathType == "host" && remotePathType == "host")
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

                            // 🔥 显示稳定性：静止画面编码器产出少，但显示不能偏离目标超过 100kbps
                            // 只对显示值做下限保护，实际发送字节不变
                            let displayFloor = max(0, self.targetBitrateKbps - 100)
                            let displayKbps = max(displayFloor, smoothedKbps)

                            self.currentKbps = displayKbps
                            WebSocketManager.publishingKbps = displayKbps
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
                        // let shutter = self.cjfpsValue
                        // print("🔍 [FPS链路] 快门=1/\(shutter)s 采集=\(captureFps) → 节流目标=\(targetFps) → 本地推送=\(localSendFps) → WebRTC实际=\(webrtcSendFps)")
                        
                        // 🔥 检测编码器质量限制（可能导致卡顿的原因）
                        // if let qlrReason = qlr, qlrReason != "none" {
                        //     print("⚠️ [编码器限制] 原因=\(qlrReason)")
                        // }
                        
                        // 🔥 计算每秒丢包数和重传统计
                        // ⚠️ 崩溃修复：packetsLost 在 WebRTC remote-inbound-rtp 里语义上是有符号的
                        //    （可能为负，重传补回时甚至倒退），上面用 uint64Value 读取会把负值变成接近
                        //    UInt64.max 的巨值；再 `Int(a &- b)` 转换就会触发
                        //    "Not enough bits to represent the passed value" 致命错误并卡死。
                        //    这里改成安全差值：累计值倒退或差值越界一律归 0，绝不溢出崩溃。
                        func safeDeltaPerSec(_ current: UInt64, _ last: UInt64) -> Int {
                            guard current >= last else { return 0 }          // 统计重置/倒退 → 本秒按 0 计
                            let delta = current &- last
                            guard delta <= UInt64(Int.max) else { return 0 } // 异常巨值（负数被误转）→ 丢弃
                            return Int(delta)
                        }
                        var packetsLostPerSec = 0
                        var nackPerSec = 0
                        var pliPerSec = 0
                        if self.lastTs > 0 {
                            packetsLostPerSec = safeDeltaPerSec(packetsLost, self.lastPacketsLost)
                            nackPerSec = safeDeltaPerSec(nackCount, self.lastNackCount)
                            pliPerSec = safeDeltaPerSec(pliCount, self.lastPliCount)
                        }
                        
                        // ⭐ 2026-07-02 P2P 攒帧卡顿修复：删除「收到 PLI 再手动 forceKeyframe」。
                        //   libwebrtc 收到 RTCP PLI 会【自动】让编码器出 IDR（标准路径，无需干预）；
                        //   这里再手动码率抖动强制一发 = 每个 PLI 双倍 IDR + 2 次 sender.parameters 写入（编码器重配）。
                        //   与 Android 40bf7ef 摘除的周期 IDR 同机理：大 IDR 突发打满上行 → 后续帧攒批 →
                        //   PC 端「堆一坨帧」卡顿 → 观看端又发 PLI/request_keyframe → 自激振荡，网络再好也周期性卡。
                        //   兜底通道保留：PC WS request_keyframe（onRequestKeyframeCommand，1s 节流）。
                        if pliPerSec > 0 {
                            print("🔑 [PLI] 收到\(pliPerSec)个PLI（libwebrtc 自动响应出 IDR，不再手动强制）")
                        }
                        
                        // 🔥 如果有丢包或重传，打印警告（减少打印频率）
                        // if packetsLostPerSec > 5 || nackPerSec > 5 || pliPerSec > 2 {
                        //     print("⚠️ [丢包/重传] 丢包=\(packetsLostPerSec)/秒, NACK=\(nackPerSec), PLI=\(pliPerSec)")
                        // }
                        
                        // 🔥 每5秒打印一次详细统计（已精简）
                        // if Int(now) % 5 == 0 {
                        //     print("📊 [WebRTC] fps=\(webrtcSendFps), 丢包=\(packetsLost)")
                        // }
                        
                        // 🔥 WebRTC 实际帧率应该接近本地节流推送帧率（已精简）
                        // let expectedWebrtcFps = localSendFps
                        // if abs(webrtcSendFps - expectedWebrtcFps) > 15 {
                        //     print("⚠️ 帧率异常: \(webrtcSendFps)fps vs \(expectedWebrtcFps)fps")
                        // }
                        
                        // ✅ 计算网络质量
                        let packetLossRate = packetsSent > 0 ? Double(packetsLost) / Double(packetsSent + packetsLost) : 0.0
                        // ⭐ 2026-07-03 §25.5：RTT 主源 = ICE candidate-pair.currentRoundTripTime，
                        //   remote-inbound-rtp.roundTripTime 仅在 ICE 层无读数时兜底。
                        //   两源差异过大时打日志（GStreamer RR 污染的现场证据）。
                        let rrRttMs = Int(roundTripTime * 1000.0)
                        let iceRttMs = Int(iceRttSec * 1000.0)
                        let rttMs = iceRttMs > 0 ? iceRttMs : rrRttMs
                        if iceRttMs > 0 && rrRttMs > 0 && abs(iceRttMs - rrRttMs) > 200 {
                            self.malvshezhingLog("[RTT] ⚠️两源偏差 ice=\(iceRttMs)ms rr=\(rrRttMs)ms → 采用 ice（RR 疑被拉流端污染）")
                        }
                        // ⭐ §53.4-定稿：这里**只做兜底核对，不再退登录页**。
                        //   正常情况下"同不同 WiFi"已在推流前用 PC_PRESENCE 的 localIps 比过网段
                        //   （SessionPolicy），跨网压根不会走 P2P。真跑到这儿说明预判与实际不符
                        //   （例：同网段但 AP 隔离、多网卡、PC 网段判断被 NAT 掩盖）→ 交给
                        //   SessionPolicy 重新协商（停推流→重决策→起推流），它自带冷却与次数上限。
                        //   §52.6 的"退回登录页让用户自己改线路"已废弃：用户不该为网络拓扑负责。
                        if self.currentConnMode == .p2p, activePairId != nil, !self.notSameWifiHandled,
                           let lt = localPathType, let rt = remotePathType, !pathIsLan {
                            self.notSameWifiHandled = true
                            self.malvshezhingLog("[线路] ⚠️实测路径非同WiFi(本端=\(lt) 远端=\(rt))，与推流前预判不符 → 重新协商走多人线路")
                            SessionPolicy.shared.forceSrsForSession(reason: "实测ICE路径非局域网(\(lt)/\(rt))")
                        }
                        
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
                        
                        // ═══════════════════════════════════════════════════════════════
                        // 🔥 自适应FPS处理（基于RTT+码率+丢包综合判断）
                        // ═══════════════════════════════════════════════════════════════
                        if self.adaptiveFpsEnabled {
                            // 🔥 计算本秒丢包率（更敏感的瞬时指标）
                            var instantLossRate: Double = 0.0
                            if self.lastTs > 0 {
                                // 复用上面的安全差值，避免 Int(UInt64) 溢出崩溃（统计重置/翻转时）
                                let sentThisSec = safeDeltaPerSec(packetsSent, self.lastPacketsSent)
                                let lostThisSec = packetsLostPerSec
                                if sentThisSec > 0 {
                                    instantLossRate = Double(lostThisSec) / Double(sentThisSec + lostThisSec)
                                }
                            }
                            
                            // 🔥 计算码率达成率（实际/目标）
                            let bitrateRatio = self.targetBitrateKbps > 0 ? Double(self.currentKbps) / Double(self.targetBitrateKbps) : 1.0
                            
                            self.processAdaptiveFps(
                                instantLossRate: instantLossRate,
                                packetsLostPerSec: packetsLostPerSec,
                                rttMs: rttMs,
                                bitrateRatio: bitrateRatio
                            )
                        }
                        
                        // 🔍 详细的码率监控日志（包括编码器参数验证）
                        if let preset = self.currentLadder[self.currentProfile] {
                            let targetMinKbps = self.kbpsMinForProfile(preset)
                            let targetMaxKbps = self.kbpsForProfile(preset)
                            let actualKbps = self.currentKbps
                            let percentage = targetMaxKbps > 0 ? Int((Double(actualKbps) / Double(targetMaxKbps)) * 100) : 0
                            let qlrStr = qlr ?? "none"
                            
                            if let sender = self.videoSender,
                               let encoding = sender.parameters.encodings.first {
                                let encMin = encoding.minBitrateBps?.intValue ?? 0
                                let encMax = encoding.maxBitrateBps?.intValue ?? 0
                                let targetMin = self.targetMinBitrateKbps * 1000
                                let targetMax = self.targetBitrateKbps * 1000
                                let encoderDrift = encMin != targetMin || encMax != targetMax
                                let overCap = self.targetBitrateKbps > 0 && actualKbps > self.targetBitrateKbps + 500
                                let networkStress = rttMs > self.rttDownThreshold || packetLossRate > self.lossRateDownThreshold
                                if encoderDrift || (overCap && networkStress) {
                                    self.malvshezhingLog("[码率] 监控 实际=\(actualKbps) 目标=\(self.targetMinBitrateKbps)-\(self.targetBitrateKbps) (\(percentage)%) 编码器=\(encMin/1000)-\(encMax/1000)kbps\(encoderDrift ? " ⚠️漂移" : "") RTT=\(rttMs)ms 丢包=\(String(format: "%.1f", packetLossRate * 100))% QLR=\(qlrStr)")
                                }
                            }
                        }
                        
                        self.evaluate(qlr: qlr)
                    }
                }
                } // 🔥 DispatchQueue.global 结束
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
                print("🔔 [触发源:tickAdapt-降档] \(currentProfile) → \(down) (badSeconds=\(badSeconds))")
                if gentleAdaptMode { applyProfileBitrateOnly(down) } else { applyProfile(down) }
                lastAdaptAt = now
                badSeconds = 0; goodSeconds = 0
                if down.rawValue <= LOWEST_PROFILE.rawValue { lowFpsIndex = 0 }
            } else {
                // 已是最低档位（low 或 standard）：按帧率继续降，保持实时性
                if currentProfile.rawValue <= LOWEST_PROFILE.rawValue,
                   lowFpsIndex < LOW_FPS_STEPS.count - 1,
                   now - lastAdaptAt >= ADAPT_MIN_INTERVAL_SEC {
                    lowFpsIndex += 1
                    let targetFps = LOW_FPS_STEPS[lowFpsIndex]
                    let captureRes = getCaptureResolutionForProfile(currentProfile)
                    recapture(width: captureRes.width, height: captureRes.height, fps: targetFps)
                    //print("📉 低档降帧：\(captureRes.width)x\(captureRes.height) @\(targetFps)fps")
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
        // 不自动降到 LOWEST_PROFILE 以下（low 只能手动/后端选择）
        return (n >= LOWEST_PROFILE.rawValue) ? LadderProfile(rawValue: n) : nil
    }

    // SRS HTTP（postOfferToSRS / deleteStream）已抽取到 SRSManager
}

// MARK: - ⭐ SRSManagerDataSource（向独立 SRS 类提供工厂/视频轨/参数 + 回调）
extension WebRTCManager: SRSManagerDataSource {
    var srsFactory: RTCPeerConnectionFactory { factory }
    var srsLocalVideoTrack: RTCVideoTrack? { localVideoTrack }
    // srsIP / app 已是 WebRTCManager 现有属性
    var srsApp: String { app }
    var srsStreamKey: String { streamKey }
    var srsUsername: String { UserDefaults.standard.string(forKey: "username") ?? "" }
    var srsIsPublishing: Bool { isPublishing }

    func srsDidConnect(pc: RTCPeerConnection, sender: RTCRtpSender?) {
        // 回填活动连接，供统计/码率强制/关键帧等共享逻辑使用
        self.pc = pc
        self.videoSender = sender
        self.isPublishing = true
        WebSocketManager.isPublishingFlag = 1
        print("🟢 [publishStatus] 1 ← SRS 推流连接成功")
        startStats()
        startCaptureWatchdog()  // 🚑 切档卡死兜底
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            let correctScale = self.currentLadder[self.currentProfile]?.scaleDown ?? 1.0
            self.setResolutionScale(correctScale)
            self.enforceBitrateImmediately()
        }
    }

    func srsDidFail(reason: String) {
        NotificationCenter.default.post(name: .publishFailed, object: nil, userInfo: ["reason": reason])
    }
}

// MARK: - 通知扩展
extension Notification.Name {
    static let cameraPreviewReady = Notification.Name("cameraPreviewReady")
    static let publishFailed = Notification.Name("publishFailed")
}

// MARK: - ⭐ P2PManagerDataSource（向独立 P2P 类提供工厂/视频轨/编码参数）
extension WebRTCManager: P2PManagerDataSource {
    var p2pFactory: RTCPeerConnectionFactory { factory }
    var p2pLocalVideoTrack: RTCVideoTrack? { localVideoTrack }
    func p2pBitrateRangeKbps() -> (min: Int, max: Int) {
        // ⭐ §53.21：原「中继时钳到 relayMaxKbps」已随 TURN 中继物理删除（P2P 只有局域网直连）。
        let baseMin = effectiveMinKbpsForCurrentProfile()
        let baseMax = max(baseMin, effectiveMaxKbpsForCurrentProfile())
        let minK = max(100, Int(Double(baseMin) * emergencyBitrateScale))
        let maxK = max(minK, Int(Double(baseMax) * emergencyBitrateScale))
        return (minK, maxK)
    }
    func p2pTargetFps() -> Int {
        let target = frameThrottler?.targetSendFps ?? targetOutputFPS
        return min(getMaxPushFpsForCurrentProfile(), target)
    }
    func p2pScaleDown() -> Double {
        return currentLadder[currentProfile]?.scaleDown ?? 1.0
    }
}


