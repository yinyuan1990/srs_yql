import Metal
import MetalKit
import CoreVideo

/// GPUImage LookupFilter 等价路径（512×512 LUT，玉麒麟 GPUImage.framework 同款资源）
/// 原生模式：相机 NV12 → LUT 查表 → 牌面调色 → NV12 → 编码
/// 亮度滑块只调 LUT 侧（intensity/exposure/temperature/redLift），曝光由快门负责
final class NV12LUTProcessor {

    /// 玉麒麟包里 5 张 LUT（与 PC 滤镜弹框 / STOMP ptype=lutName 一致）
    static let allowedLutNames = [
        "lookup",
        "lookup_soft_elegance_1",
        "lookup_soft_elegance_2",
        "lookup_amatorka",
        "lookup_miss_etikate"
    ]
    static let defaultLutName = "lookup_soft_elegance_1"

    /// LUT 混合强度 0~1
    var intensity: Float = 0.72
    /// 中低亮曝光偏移（高光有保护）
    var exposure: Float = 0.0
    /// 负=偏冷去黄，正=偏暖
    var temperature: Float = -0.010
    /// 暗红抬升（远处牌防发黑）
    var redLift: Float = 0.28
    /// 红色饱和（对手更红）
    var redSat: Float = 0.42

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

        print("✅ [NV12LUT] 玉麒麟 LUT=\(name).png intensity=\(intensity) redLift=\(redLift) redSat=\(redSat)")
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

    /// PC「原生亮度」0~100（50=默认）→ LUT 四参数，不调 ISO/EV（快门管曝光）
    func applyNativeBrightness(_ value: Int) {
        let v = Float(max(0, min(100, value)))
        let centered = (v - 50.0) / 50.0  // -1..1

        // LUT 强度
        intensity = 0.45 + (v / 100.0) * 0.45  // 0→0.45, 50→0.67, 100→0.90

        exposure = centered * 0.22

        temperature = -0.025 + centered * 0.015

        // 远处牌红色：默认强保护，滑块居中最大
        redLift = 0.32 - abs(centered) * 0.08   // 0.24~0.32
        redSat = 0.38 + (1.0 - abs(centered)) * 0.12  // 0.38~0.50

        print("🧪 [LUT亮度] slider=\(value) → intensity=\(String(format: "%.2f", intensity)) exp=\(String(format: "%.2f", exposure)) redLift=\(String(format: "%.2f", redLift)) redSat=\(String(format: "%.2f", redSat))")
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
            redSat: redSat
        )

        encode(cmdBuf, pipeline: pipelineY,
               yIn: yInTex, uvIn: uvInTex, yOut: yOutTex,
               params: &params, w: w, h: h)

        encodeUV(cmdBuf, pipeline: pipelineUV,
                 yIn: yInTex, uvIn: uvInTex, uvOut: uvOutTex,
                 params: &params, w: w / 2, h: h / 2)

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        return output
    }

    // MARK: - Private

    private struct LUTParamsMetal {
        var intensity: Float
        var exposure: Float
        var temperature: Float
        var redLift: Float
        var redSat: Float
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
