import Metal
import CoreVideo

/// GPU-native NV12 处理器 —— 与玉麒麟 GPUImage 链路等价
/// 相机(NV12) → Metal Shader(直接处理YUV纹理) → NV12 → VideoToolbox → H264
/// 全程无 BGRA 中间格式，无额外色彩空间转换
final class NV12MetalProcessor {

    // MARK: - 滤镜参数（与 VideoFilterPipeline 对齐）
    var exposure:    Float = 0.15
    var blackPoint:  Float = 0.10
    var brightness:  Float = 0.05
    var gamma:       Float = 1.0
    var contrast:    Float = 1.20
    var saturation:  Float = 1.30
    var sharpen:     Float = 0.6
    var redGlow:     Float = 0.25
    var pixelLevel:  Float = 0.0
    var enabled:     Bool  = true

    // MARK: - Metal 资源
    private let device:        MTLDevice
    private let commandQueue:  MTLCommandQueue
    private let pipelineY:     MTLComputePipelineState
    private let pipelineUV:    MTLComputePipelineState
    private var textureCache:  CVMetalTextureCache?
    private var outputPool:    CVPixelBufferPool?
    private var poolWidth  = 0
    private var poolHeight = 0

    // MARK: - 初始化
    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else { return nil }
        device = dev
        commandQueue = queue

        // 纹理缓存（零拷贝，IOSurface 直通 GPU）
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let c = cache else { return nil }
        textureCache = c

        // 加载 Metal 函数
        guard let lib = device.makeDefaultLibrary(),
              let fnY  = lib.makeFunction(name: "processY"),
              let fnUV = lib.makeFunction(name: "processUV") else {
            print("❌ [NV12Metal] 无法加载 Metal shader（NV12Filter.metal 是否已加入 target？）")
            return nil
        }
        guard let py  = try? dev.makeComputePipelineState(function: fnY),
              let puv = try? dev.makeComputePipelineState(function: fnUV) else { return nil }
        pipelineY  = py
        pipelineUV = puv

        print("✅ [NV12Metal] 初始化完成（GPU纹理直通，兼容iOS 15+）")
    }

    // MARK: - 每帧处理
    /// 输入：相机输出的 NV12 CVPixelBuffer
    /// 输出：处理后的 NV12 CVPixelBuffer（直接送 VideoToolbox 编码，无格式转换）
    func process(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        guard enabled else { return nil }

        let w = CVPixelBufferGetWidth(input)
        let h = CVPixelBufferGetHeight(input)

        // 按需创建输出 buffer 池
        if outputPool == nil || poolWidth != w || poolHeight != h {
            let poolAttrs: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 4]
            let bufAttrs:  [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey:           w,
                kCVPixelBufferHeightKey:          h,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey:  true
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, bufAttrs as CFDictionary, &pool)
            outputPool = pool
            poolWidth  = w
            poolHeight = h
        }
        guard let pool = outputPool else { return nil }

        var outBuf: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf) == kCVReturnSuccess,
              let output = outBuf else { return nil }

        // 获取 Metal 纹理（IOSurface 零拷贝）
        guard let cache = textureCache,
              let yInTex  = makeTexture(cache, input,  .r8Unorm,  w,   h,   plane: 0),
              let uvInTex = makeTexture(cache, input,  .rg8Unorm, w/2, h/2, plane: 1),
              let yOutTex = makeTexture(cache, output, .r8Unorm,  w,   h,   plane: 0),
              let uvOutTex = makeTexture(cache, output, .rg8Unorm, w/2, h/2, plane: 1)
        else { return nil }

        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return nil }

        var params = NV12Params(
            exposure: exposure, blackPoint: blackPoint, brightness: brightness,
            gamma: gamma, contrast: contrast, saturation: saturation,
            sharpen: sharpen, redGlow: redGlow, pixelLevel: pixelLevel
        )

        // Pass 1：Y 平面（全分辨率）
        encode(cmdBuf, pipeline: pipelineY,
               texIn: yInTex, texOut: yOutTex,
               params: &params, w: w, h: h)

        // Pass 2：UV 平面（半分辨率）
        encode(cmdBuf, pipeline: pipelineUV,
               texIn: uvInTex, texOut: uvOutTex,
               params: &params, w: w/2, h: h/2)

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return output
    }

    // MARK: - 同步参数（从 VideoFilterPipeline 拷贝）
    func sync(from fp: VideoFilterPipeline) {
        exposure   = fp.exposure
        blackPoint = fp.blackPoint
        brightness = fp.brightness
        gamma      = fp.gamma
        contrast   = fp.contrast
        saturation = fp.saturation
        sharpen    = fp.sharpenAmount
        redGlow    = fp.redGlow
        pixelLevel = fp.pixelLevel
        enabled    = fp.enabled
    }

    // MARK: - 私有工具
    private struct NV12Params {
        var exposure, blackPoint, brightness, gamma, contrast, saturation, sharpen, redGlow, pixelLevel: Float
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
                        texIn: MTLTexture, texOut: MTLTexture,
                        params: inout NV12Params,
                        w: Int, h: Int) {
        guard let enc = cmdBuf.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(texIn,  index: 0)
        enc.setTexture(texOut, index: 1)
        enc.setBytes(&params, length: MemoryLayout<NV12Params>.size, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grids = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(grids, threadsPerThreadgroup: tg)
        enc.endEncoding()
    }
}
