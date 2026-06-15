import Metal
import MetalKit
import CoreVideo

/// GPUImage LookupFilter 等价（512×512 LUT，玉麒麟同款 png）
/// 相机 NV12 → 纯 LUT 查表 mix → NV12，无额外抬红/饱和
final class NV12LUTProcessor {

    /// 玉麒麟包里 5 张 LUT（与 PC 滤镜弹框 / STOMP ptype=lutName 一致）
    static let allowedLutNames = [
        "lookup",
        "lookup_soft_elegance_1",
        "lookup_soft_elegance_2",
        "lookup_amatorka",
        "lookup_miss_etikate"
    ]
    static let defaultLutName = "lookup"

    /// LUT 混合强度 0~1（玉麒麟 GPUImage 默认满强度查表）
    var intensity: Float = 1.0
    var exposure: Float = 0.0
    var temperature: Float = 0.0
    var redLift: Float = 0.0
    var redSat: Float = 0.0
    /// LUT 前降对比（绕中点 0.5）：<1 降对比，1=不变。发牌场景柔化采集端硬过渡
    var preContrast: Float = 0.90
    /// LUT 前抬中间调（gamma，两端不动）：>1 提亮暗部/中间调，1=不变。发牌场景提亮主力
    var preGamma: Float = 1.20

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineY: MTLComputePipelineState
    private let pipelineUV: MTLComputePipelineState
    private(set) var currentLutName: String
    private var lookupTexture: MTLTexture
    private var textureCache: CVMetalTextureCache?
    private var outputPool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    init?(lutName: String = NV12LUTProcessor.defaultLutName) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else { return nil }
        device = dev
        commandQueue = queue

        let name = Self.normalizedLutName(lutName)
        guard let lutTex = NV12LUTProcessor.loadLookupTexture(device: dev, name: name) else {
            print("❌ [NV12LUT] 无法加载 \(name).png（玉麒麟 LUT）")
            return nil
        }
        currentLutName = name
        lookupTexture = lutTex

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let c = cache else { return nil }
        textureCache = c

        guard let lib = device.makeDefaultLibrary(),
              let fnY = lib.makeFunction(name: "lutProcessY"),
              let fnUV = lib.makeFunction(name: "lutProcessUV") else {
            print("❌ [NV12LUT] 无法加载 lutProcessY/UV（NV12LUTFilter.metal 是否已加入 target？）")
            return nil
        }
        guard let py = try? dev.makeComputePipelineState(function: fnY),
              let puv = try? dev.makeComputePipelineState(function: fnUV) else { return nil }
        pipelineY = py
        pipelineUV = puv

        print("✅ [NV12LUT] 玉麒麟 LUT=\(name).png intensity=\(intensity) exposure=\(exposure) temperature=\(temperature) redLift=\(redLift) redSat=\(redSat) preContrast=\(preContrast) preGamma=\(preGamma)")
    }

    /// PC STOMP / 本地切换 LUT 图（无需重建 Processor）
    @discardableResult
    func setLutName(_ name: String) -> Bool {
        let normalized = Self.normalizedLutName(name)
        guard normalized != currentLutName else { return true }
        guard let tex = Self.loadLookupTexture(device: device, name: normalized) else {
            print("❌ [NV12LUT] 切换失败，无 \(normalized).png")
            return false
        }
        lookupTexture = tex
        currentLutName = normalized
        print("✅ [NV12LUT] 已切换 LUT → \(normalized).png")
        return true
    }

    static func normalizedLutName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if allowedLutNames.contains(trimmed) { return trimmed }
        return defaultLutName
    }

    /// 硬件亮度滑块联动（仅微调 LUT 强度，不调红/色温）
    func applyNativeBrightness(_ value: Int) {
        let v = Float(max(0, min(100, value)))
        intensity = 0.85 + (v / 100.0) * 0.15   // 0→0.85, 50→0.925, 100→1.0
        exposure = 0
        temperature = 0
        redLift = 0.0
        redSat = 0.0
        print("[NV12LUT] applyNativeBrightness value=\(value) → intensity=\(intensity) exposure=\(exposure) temperature=\(temperature) redLift=\(redLift) redSat=\(redSat) preContrast=\(preContrast) preGamma=\(preGamma)")
    }

    func process(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(input)
        let h = CVPixelBufferGetHeight(input)

        if outputPool == nil || poolWidth != w || poolHeight != h {
            let poolAttrs: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 4]
            let bufAttrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey: w,
                kCVPixelBufferHeightKey: h,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, bufAttrs as CFDictionary, &pool)
            outputPool = pool
            poolWidth = w
            poolHeight = h
        }
        guard let pool = outputPool else { return nil }

        var outBuf: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf) == kCVReturnSuccess,
              let output = outBuf else { return nil }

        // ⭐ 关键：补回色彩元数据（BT.709 + 满范围），否则编码后 H264 不带 colour_description，
        //    PC 解码端按有限范围还原 → 红色发暗、整体偏色。设这三项后 VideoToolbox 会写 video_full_range_flag=1。
        setColorAttachments(output)

        guard let cache = textureCache,
              let yInTex = makeTexture(cache, input, .r8Unorm, w, h, plane: 0),
              let uvInTex = makeTexture(cache, input, .rg8Unorm, w / 2, h / 2, plane: 1),
              let yOutTex = makeTexture(cache, output, .r8Unorm, w, h, plane: 0),
              let uvOutTex = makeTexture(cache, output, .rg8Unorm, w / 2, h / 2, plane: 1)
        else { return nil }

        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return nil }

        var params = LUTParamsMetal(
            intensity: intensity,
            exposure: exposure,
            temperature: temperature,
            redLift: redLift,
            redSat: redSat,
            preContrast: preContrast,
            preGamma: preGamma
        )

        encode(cmdBuf, pipeline: pipelineY,
               yIn: yInTex, uvIn: uvInTex, yOut: yOutTex,
               params: &params, w: w, h: h)

        encodeUV(cmdBuf, pipeline: pipelineUV,
                 yIn: yInTex, uvIn: uvInTex, uvOut: uvOutTex,
                 params: &params, w: w / 2, h: h / 2)

        // ⭐ B：有界等待 + 错误检查 —— 避免 GPU 卡顿/出错时裸 waitUntilCompleted() 永久阻塞采集队列
        let sem = DispatchSemaphore(value: 0)
        cmdBuf.addCompletedHandler { _ in sem.signal() }
        cmdBuf.commit()
        if sem.wait(timeout: .now() + 0.1) == .timedOut {
            print("⚠️ [NV12LUT] GPU 超时(>100ms)，丢弃该帧（避免卡死采集队列）")
            return nil
        }
        if cmdBuf.status == .error {
            print("⚠️ [NV12LUT] GPU 命令出错，丢弃该帧: \(String(describing: cmdBuf.error))")
            return nil
        }
        return output
    }

    // MARK: - Private

    /// 给输出 NV12 buffer 打上 BT.709 满范围色彩标签（与相机 420f FullRange 一致）
    private func setColorAttachments(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    }

    private struct LUTParamsMetal {
        var intensity: Float
        var exposure: Float
        var temperature: Float
        var redLift: Float
        var redSat: Float
        var preContrast: Float
        var preGamma: Float
    }

    private static func loadLookupTexture(device: MTLDevice, name: String) -> MTLTexture? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
            print("❌ [NV12LUT] Bundle 中无 \(name).png")
            return nil
        }
        let loader = MTKTextureLoader(device: device)
        do {
            return try loader.newTexture(URL: url, options: [
                .SRGB: false,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
            ])
        } catch {
            print("❌ [NV12LUT] LUT 纹理加载失败: \(error.localizedDescription)")
            return nil
        }
    }

    private func makeTexture(_ cache: CVMetalTextureCache,
                             _ buf: CVPixelBuffer,
                             _ fmt: MTLPixelFormat,
                             _ w: Int, _ h: Int, plane: Int) -> MTLTexture? {
        var ref: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buf, nil, fmt, w, h, plane, &ref)
        guard status == kCVReturnSuccess, let r = ref else { return nil }
        return CVMetalTextureGetTexture(r)
    }

    private func encode(_ cmdBuf: MTLCommandBuffer,
                        pipeline: MTLComputePipelineState,
                        yIn: MTLTexture, uvIn: MTLTexture, yOut: MTLTexture,
                        params: inout LUTParamsMetal,
                        w: Int, h: Int) {
        guard let enc = cmdBuf.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(yIn, index: 0)
        enc.setTexture(uvIn, index: 1)
        enc.setTexture(yOut, index: 2)
        enc.setTexture(lookupTexture, index: 3)
        enc.setBytes(&params, length: MemoryLayout<LUTParamsMetal>.size, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grids = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(grids, threadsPerThreadgroup: tg)
        enc.endEncoding()
    }

    private func encodeUV(_ cmdBuf: MTLCommandBuffer,
                          pipeline: MTLComputePipelineState,
                          yIn: MTLTexture, uvIn: MTLTexture, uvOut: MTLTexture,
                          params: inout LUTParamsMetal,
                          w: Int, h: Int) {
        guard let enc = cmdBuf.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(yIn, index: 0)
        enc.setTexture(uvIn, index: 1)
        enc.setTexture(uvOut, index: 2)
        enc.setTexture(lookupTexture, index: 3)
        enc.setBytes(&params, length: MemoryLayout<LUTParamsMetal>.size, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grids = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(grids, threadsPerThreadgroup: tg)
        enc.endEncoding()
    }
}
