//
//  SdH264Encoder.swift
//  srs
//
//  SRT直推 H.264 硬编码（VideoToolbox），对应 Android SdH264Encoder.kt：
//  - RealTime、无 B 帧、High AutoLevel；GOP 秒数 / 码率模式由 Config 给（后台 srtParams 下发）；
//  - VideoToolbox 没有 I/P 分开的 QP 上下限：iOS 15+ 用 MaxAllowedFrameQP 当「QP 上限」（取 P 帧上限），
//    设不进去时 qpConfigured=false，峰值控制只走降码率；
//  - 峰值码率用 DataRateLimits 限制（peakKbps 字节/秒）；
//  - 输入尺寸与编码尺寸不同时由 VideoToolbox 内部缩放（PixelTransferProperties ScalingMode=Trim）；
//  - 输出 Annex-B，关键帧前带 SPS/PPS；每秒统计 I/P 帧大小。
//

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

final class SdH264Encoder {
    struct Config: Equatable {
        let width: Int
        let height: Int
        let fps: Int
        let bitrateKbps: Int
        /// 1=VBR 2=CBR
        let bitrateMode: Int
        let qpPMax: Int
        let gopSec: Int
        let peakKbps: Int
    }

    let config: Config
    /// 每个编码输出（Annex-B，含起始码）；isKey=IDR；hostPtsNs=相机主机时钟时间戳。在 VideoToolbox 回调线程调用。
    private let onFrame: (_ data: [UInt8], _ ptsUs: Int64, _ isKey: Bool, _ hostPtsNs: Int64) -> Void

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var forceKey = true
    private var invalidated = false

    /// MaxAllowedFrameQP 是否设进去了
    private(set) var qpConfigured = false
    private(set) var curQpMax = 0
    private(set) var curBitrateKbps = 0

    // —— 每秒统计（回调线程写，统计线程读）——
    private var secBytes = 0
    private var secFrames = 0
    private var secPBytes = 0
    private var secPCount = 0
    private var secPMax = 0
    private var secStartMs: Int64 = 0
    private(set) var statKbps = 0
    private(set) var statFps = 0
    private(set) var statPAvgBytes = 0
    private(set) var statPMaxBytes = 0
    private(set) var lastIBytes = 0
    private(set) var framesTotal: Int64 = 0
    private(set) var encodeErrors = 0

    init(config: Config, onFrame: @escaping (_ data: [UInt8], _ ptsUs: Int64, _ isKey: Bool, _ hostPtsNs: Int64) -> Void) throws {
        self.config = config
        self.onFrame = onFrame
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(config.width),
            height: Int32(config.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &s)
        guard st == noErr, let session = s else {
            throw NSError(domain: "SdH264Encoder", code: Int(st),
                          userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate 失败 \(st)"])
        }
        self.session = session
        func set(_ key: CFString, _ value: CFTypeRef) -> OSStatus {
            VTSessionSetProperty(session, key: key, value: value)
        }
        _ = set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        _ = set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        _ = set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        _ = set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        _ = set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: config.fps))
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: max(1, config.fps * config.gopSec)))
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: config.gopSec))
        _ = set(kVTCompressionPropertyKey_PixelTransferProperties,
                [kVTPixelTransferPropertyKey_ScalingMode as String: kVTScalingMode_Trim as String] as CFDictionary)
        self.applyBitrateLocked(session, config.bitrateKbps)
        // qpPMax <= 0 = 不设 QP 上限（码率失控保护触发后，见 SrtDirectEngine.tick）
        if #available(iOS 15.0, *), config.qpPMax > 0 {
            let qs = set(kVTCompressionPropertyKey_MaxAllowedFrameQP, NSNumber(value: config.qpPMax))
            qpConfigured = qs == noErr
            curQpMax = qpConfigured ? config.qpPMax : 0
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        let qpDesc = config.qpPMax <= 0 ? "不设（码率失控保护）"
            : (qpConfigured ? "\(config.qpPMax)（MaxAllowedFrameQP）" : "未设(系统不支持)")
        SdLog.i("编码器就绪 VideoToolbox H.264 High \(config.width)x\(config.height)@\(config.fps) 目标\(config.bitrateKbps)kbps" +
                " \(config.bitrateMode == 2 ? "CBR" : "VBR") 峰值\(config.peakKbps)kbps GOP\(config.gopSec)s QP上限 \(qpDesc)")
    }

    deinit {
        stop()
    }

    /// 目标码率 + 峰值上限（DataRateLimits：字节/秒）
    private func applyBitrateLocked(_ s: VTCompressionSession, _ kbps: Int) {
        curBitrateKbps = kbps
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: kbps * 1000))
        let capKbps: Int
        if config.bitrateMode == 2 {
            capKbps = kbps * 11 / 10
        } else if config.peakKbps > kbps {
            capKbps = config.peakKbps
        } else {
            capKbps = kbps * 3 / 2
        }
        let limits = [NSNumber(value: capKbps * 125), NSNumber(value: 1.0)] as CFArray
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    /// 送一帧（相机线程）；hostPtsNs = 相机主机时钟时间戳（纳秒），同时作为 PTS
    func encode(_ pixelBuffer: CVPixelBuffer, hostPtsNs: Int64) {
        lock.lock()
        guard let s = session, !invalidated else { lock.unlock(); return }
        let key = forceKey
        forceKey = false
        lock.unlock()
        let pts = CMTime(value: hostPtsNs, timescale: 1_000_000_000)
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
        let st = VTCompressionSessionEncodeFrame(
            s, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            guard status == noErr, let sb = sampleBuffer else {
                self.encodeErrors += 1
                return
            }
            self.handleOutput(sb, hostPtsNs: hostPtsNs)
        }
        if st != noErr {
            encodeErrors += 1
            if key { lock.lock(); forceKey = true; lock.unlock() }
        }
    }

    func requestKeyFrame() {
        lock.lock(); forceKey = true; lock.unlock()
    }

    /// 运行中改目标码率，不重建编码器
    func setBitrate(_ kbps: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let s = session, !invalidated else { return }
        applyBitrateLocked(s, kbps)
    }

    /// 运行中改 QP 上限（峰值控制用）；false = 系统不支持
    @discardableResult
    func setQpMax(_ qp: Int) -> Bool {
        guard qpConfigured else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let s = session, !invalidated else { return false }
        if #available(iOS 15.0, *) {
            let st = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxAllowedFrameQP, value: NSNumber(value: qp))
            if st == noErr { curQpMax = qp }
            return st == noErr
        }
        return false
    }

    func stop() {
        lock.lock()
        let s = session
        session = nil
        invalidated = true
        lock.unlock()
        if let s { VTCompressionSessionInvalidate(s) }
    }

    // MARK: - 输出

    private func handleOutput(_ sb: CMSampleBuffer, hostPtsNs: Int64) {
        lock.lock()
        let alive = !invalidated
        lock.unlock()
        guard alive, CMSampleBufferDataIsReady(sb) else { return }

        var isKey = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[String: Any]],
           let first = arr.first, let notSync = first[kCMSampleAttachmentKey_NotSync as String] as? Bool {
            isKey = !notSync
        }

        var out = [UInt8]()
        var nalLenSize: Int32 = 4
        if let fmt = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLenSize)
            if isKey {
                for i in 0..<count {
                    var ptr: UnsafePointer<UInt8>?
                    var size = 0
                    let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    if st == noErr, let ptr {
                        out.append(contentsOf: [0, 0, 0, 1])
                        out.append(contentsOf: UnsafeBufferPointer(start: ptr, count: size))
                    }
                }
            }
        }

        guard let block = CMSampleBufferGetDataBuffer(sb) else { return }
        let total = CMBlockBufferGetDataLength(block)
        guard total > 0 else { return }
        var avcc = [UInt8](repeating: 0, count: total)
        let cst = avcc.withUnsafeMutableBytes { raw -> OSStatus in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: raw.baseAddress!)
        }
        guard cst == noErr else { return }

        // AVCC（长度前缀）→ Annex-B
        let lenSize = Int(nalLenSize > 0 ? nalLenSize : 4)
        var off = 0
        while off + lenSize <= total {
            var nalLen = 0
            for k in 0..<lenSize { nalLen = (nalLen << 8) | Int(avcc[off + k]) }
            off += lenSize
            guard nalLen > 0, off + nalLen <= total else { break }
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(contentsOf: avcc[off..<(off + nalLen)])
            off += nalLen
        }
        guard !out.isEmpty else { return }

        framesTotal += 1
        accountStats(out.count, isKey: isKey)
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let ptsUs = pts.isValid ? Int64(CMTimeGetSeconds(pts) * 1_000_000) : hostPtsNs / 1000
        onFrame(out, ptsUs, isKey, hostPtsNs)
    }

    private func accountStats(_ bytes: Int, isKey: Bool) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if secStartMs == 0 { secStartMs = now }
        secBytes += bytes
        secFrames += 1
        if isKey {
            lastIBytes = bytes
        } else {
            secPBytes += bytes
            secPCount += 1
            if bytes > secPMax { secPMax = bytes }
        }
        let elapsed = now - secStartMs
        if elapsed >= 1000 {
            statKbps = Int(Int64(secBytes) * 8 / elapsed)
            statFps = Int(Int64(secFrames) * 1000 / elapsed)
            statPAvgBytes = secPCount > 0 ? secPBytes / secPCount : 0
            statPMaxBytes = secPMax
            secBytes = 0; secFrames = 0
            secPBytes = 0; secPCount = 0; secPMax = 0
            secStartMs = now
        }
    }
}
