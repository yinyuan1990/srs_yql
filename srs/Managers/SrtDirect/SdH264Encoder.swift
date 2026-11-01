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
        /// QP 下限（MinAllowedFrameQP，iOS 16+）；0 = 不设
        let qpMin: Int
        let gopSec: Int
        let peakKbps: Int
        /// VBR 在低延迟码控下的平均码率 = 峰值 × 清晰度%（0 = 不放开，按目标码率）
        var vbrCeilingKbps: Int = 0
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
    /// MinAllowedFrameQP 实际设进去的值；0 = 没设 / 系统不支持
    private(set) var curQpMin = 0
    private(set) var curBitrateKbps = 0
    /// 实际设给编码器的平均码率（VBR + 低延迟码控时是放开到峰值的那个值）
    private(set) var curAvgKbps = 0

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
    /// 送进编码器的帧 / 低延迟码控为守码率主动丢的帧（累计；引擎每秒取差值）
    private(set) var framesIn: Int64 = 0
    private(set) var framesDropped: Int64 = 0
    /// 低延迟码控（EnableLowLatencyRateControl）建成功：守码率优先，QP 到上限还超预算就丢帧
    private(set) var lowLatency = false
    private(set) var encodeErrors = 0
    /// 连续编码失败帧数（成功一帧清零）。VideoToolbox 会话被系统作废后（App 退后台 / 被来电等打断）每帧都失败、不会自己好
    private(set) var consecutiveErrors = 0
    private(set) var lastErrorStatus: OSStatus = noErr
    /// 引擎看到 true 就用同样参数重建（shiji80888 10-31：作废后编码错误 3500+、0 帧，推流一直空连）
    var broken: Bool { lastErrorStatus == kVTInvalidSessionErr || consecutiveErrors >= 15 }

    init(config: Config, onFrame: @escaping (_ data: [UInt8], _ ptsUs: Int64, _ isKey: Bool, _ hostPtsNs: Int64) -> Void) throws {
        self.config = config
        self.onFrame = onFrame
        func create(_ spec: CFDictionary?) -> (OSStatus, VTCompressionSession?) {
            var s: VTCompressionSession?
            let st = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(config.width),
                height: Int32(config.height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: spec,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &s)
            return (st, s)
        }
        // 普通码控下 MaxAllowedFrameQP 优先于码率（shiji80888 11-01：QP≤30 时 1080p 冲到 55Mbps）；
        // 低延迟码控守码率优先，QP 到上限还超预算就丢帧（WWDC21「Explore low-latency video encoding」）
        var rcText = "普通"
        var created: (OSStatus, VTCompressionSession?) = (noErr, nil)
        if #available(iOS 14.5, *) {
            let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true] as CFDictionary
            created = create(spec)
            if created.0 == noErr, created.1 != nil {
                lowLatency = true
                rcText = "低延迟"
            } else {
                rcText = "普通(低延迟建不起来 \(created.0))"
            }
        } else {
            rcText = "普通(低延迟需 iOS 14.5)"
        }
        if !lowLatency { created = create(nil) }
        guard created.0 == noErr, let session = created.1 else {
            throw NSError(domain: "SdH264Encoder", code: Int(created.0),
                          userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate 失败 \(created.0)"])
        }
        self.session = session
        func set(_ key: CFString, _ value: CFTypeRef) -> OSStatus {
            VTSessionSetProperty(session, key: key, value: value)
        }
        _ = set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        _ = set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        var profileText = "High"
        if lowLatency, #available(iOS 15.0, *),
           set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel) == noErr {
            profileText = "ConstrainedHigh"
        } else {
            _ = set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        }
        _ = set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        _ = set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: config.fps))
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: max(1, config.fps * config.gopSec)))
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: config.gopSec))
        _ = set(kVTCompressionPropertyKey_PixelTransferProperties,
                [kVTPixelTransferPropertyKey_ScalingMode as String: kVTScalingMode_Trim as String] as CFDictionary)
        self.applyBitrateLocked(session, config.bitrateKbps)
        if #available(iOS 15.0, *) {
            let qs = set(kVTCompressionPropertyKey_MaxAllowedFrameQP, NSNumber(value: config.qpPMax))
            qpConfigured = qs == noErr
            curQpMax = qpConfigured ? config.qpPMax : 0
        }
        // 下限不能高过上限，否则 VideoToolbox 拒绝
        let qpMin = qpConfigured ? min(config.qpMin, config.qpPMax) : config.qpMin
        var qpMinText = "不设"
        if qpMin > 0 {
            if #available(iOS 16.0, *) {
                let st = set(kVTCompressionPropertyKey_MinAllowedFrameQP, NSNumber(value: qpMin))
                if st == noErr {
                    curQpMin = qpMin
                    qpMinText = "\(qpMin)（MinAllowedFrameQP）"
                } else {
                    qpMinText = "未设(编码器不支持 \(st))"
                }
            } else {
                qpMinText = "未设(需 iOS 16)"
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        SdLog.i("编码器就绪 VideoToolbox H.264 \(profileText) 码控=\(rcText) \(config.width)x\(config.height)@\(config.fps) 目标\(config.bitrateKbps)kbps" +
                " \(config.bitrateMode == 2 ? "CBR" : "VBR")\(curAvgKbps != config.bitrateKbps ? "（均值放开到 \(curAvgKbps)kbps）" : "") 峰值\(config.peakKbps)kbps GOP\(config.gopSec)s" +
                " QP上限 \(qpConfigured ? "\(config.qpPMax)（MaxAllowedFrameQP）" : "未设(系统不支持)") QP下限 \(qpMinText)")
    }

    deinit {
        stop()
    }

    /// 目标码率 + 峰值上限（DataRateLimits：字节/秒）
    /// 低延迟码控把 AverageBitRate 当硬目标（shiji8199 11-01 4K：CBR / VBR 都钉在目标 10M，峰值 14M 从没用上，
    ///   还为守码率把 QP 抬到 42、丢帧 11%）→ VBR 的平均给到峰值×清晰度：简单画面 QP 到下限用不满、码率自然往下走，
    ///   复杂画面才用到封顶；CBR 照旧钉在目标。peak 控制按比例降 kbps 时均值跟着同比例降。
    private func applyBitrateLocked(_ s: VTCompressionSession, _ kbps: Int) {
        curBitrateKbps = kbps
        let vbrOpen = lowLatency && config.bitrateMode != 2 && config.vbrCeilingKbps > config.bitrateKbps
        let avg = vbrOpen ? config.vbrCeilingKbps * kbps / max(1, config.bitrateKbps) : kbps
        curAvgKbps = avg
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: avg * 1000))
        let capKbps: Int
        if config.bitrateMode == 2 {
            capKbps = kbps * 11 / 10
        } else if vbrOpen {
            capKbps = max(config.peakKbps, avg) * 11 / 10
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
        framesIn += 1
        let st = VTCompressionSessionEncodeFrame(
            s, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, infoFlags, sampleBuffer in
            guard let self else { return }
            // 低延迟码控守码率主动丢帧：不是错误，不能算进「连续失败」（否则 15 帧就被当成失效重建）
            if status == noErr, sampleBuffer == nil || infoFlags.contains(.frameDropped) {
                self.framesDropped += 1
                if key { self.lock.lock(); self.forceKey = true; self.lock.unlock() }
                return
            }
            guard status == noErr, let sb = sampleBuffer else {
                self.encodeErrors += 1
                self.consecutiveErrors += 1
                if status != noErr { self.lastErrorStatus = status }
                return
            }
            self.consecutiveErrors = 0
            self.handleOutput(sb, hostPtsNs: hostPtsNs)
        }
        if st != noErr {
            encodeErrors += 1
            consecutiveErrors += 1
            lastErrorStatus = st
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
