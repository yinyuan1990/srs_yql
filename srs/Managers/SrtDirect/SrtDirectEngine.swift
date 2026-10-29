//
//  SrtDirectEngine.swift
//  srs
//
//  SRT直推媒体引擎（对应 Android SrtDirectEngine.kt）：
//  相机原始帧（FrameThrottler 推送节流后、滤镜前）→ VideoToolbox H.264 → SEI 打时间戳 → TS → SRT → MediaMTX。
//
//  - 采集/预览/镜头/曝光仍由 WebRTCManager + CustomAVCaptureVideoCapturer 负责，本引擎只管编码与传输；
//  - 编码尺寸 = 档位参数宽高（采集比它小时按采集尺寸等比缩，不放大）；尺寸/帧率/GOP/QP上限/峰值变化 →
//    下一帧换新编码器（SRT 不断）；只改码率 → 运行中 setBitrate；
//  - 延迟/限速变化 → 主动重连（流名不变）；
//  - tick() 每秒由 WebRTCManager 调用：统计行（进 SRT 日志）+ 峰值控制。
//

import Foundation
import CoreVideo

extension Notification.Name {
    /// WebSocketManager → WebRTCManager：srt_params / srt_exposure / srt_cam_query 原始 config 字典（userInfo）
    static let srtDirectCommand = Notification.Name("SrtDirectCommand")
}

protocol SrtDirectEngineHost: AnyObject {
    /// 连接线程调用：生成本次连接的地址/延迟/streamid（可阻塞取 token）；nil=本次不连
    func srtTarget(attempt: Int, plan: SrtDirectParams.Plan) -> SdSrtSender.Target?
    /// 某次连接的首个关键帧已发出（编码回调线程）
    func onSrtLive(attempt: Int)
    func onSrtLost(reason: String)
}

final class SrtDirectEngine {
    /// 期望的视频参数（WebRTCManager 按档位/清晰度/推送帧率算好给进来）
    struct VideoReq: Equatable {
        let plan: SrtDirectParams.Plan
        let fps: Int
        /// 目标码率（档位码率 × 清晰度%），峰值控制器在此基础上再乘系数
        let kbps: Int
    }

    /// 每秒快照（上报 CONFIG_STATE / UI 用）
    struct Snapshot {
        let connected: Bool
        let live: Bool
        let encKbps: Int
        let encFps: Int
        let capFps: Int
        let rttMs: Int
        let lossRate: Double
        let line: String
    }

    weak var host: SrtDirectEngineHost?

    private let lock = NSLock()
    private var req: VideoReq?
    private var encoder: SdH264Encoder?
    private var failedConfig: SdH264Encoder.Config?
    private var sender: SdSrtSender?
    private let muxLock = NSLock()
    private let muxer = SdTsMuxer()
    private let peak = SdPeakController()
    private var capFrames: Int64 = 0
    private(set) var encodeWidth = 0
    private(set) var encodeHeight = 0
    private(set) var inputWidth = 0
    private(set) var inputHeight = 0

    private final class EncoderBox { weak var encoder: SdH264Encoder? }

    // MARK: - 视频参数

    /// 档位/清晰度/帧率/srtParams 变化（结构性变化留到下一帧换编码器）
    func setVideo(_ r: VideoReq, reason: String) {
        lock.lock()
        let old = req
        req = r
        failedConfig = nil
        let enc = encoder
        let s = sender
        var bitrateMsg: String?
        if let enc, old != r, let size = targetSizeLocked(r), !Self.structuralChange(enc.config, config(for: r, size: size)) {
            if let old, old.plan != r.plan {
                if peak.curPMax != r.plan.qpPMax { enc.setQpMax(r.plan.qpPMax) }
                peak.reset(r.plan, qpRuntime: enc.qpConfigured)
            }
            let target = r.kbps * peak.ratePct / 100
            enc.setBitrate(target)
            bitrateMsg = "改码率 → \(target)kbps（\(reason)，档位码率×清晰度=\(r.kbps)，峰值控制\(peak.ratePct)%）"
        }
        lock.unlock()
        if let bitrateMsg { SdLog.i(bitrateMsg) }
        // 延迟/限速只在连接时生效 → 变了就主动重连（流名不变）
        if let s, let tgt = s.currentTarget, tgt.latencyMs != r.plan.latencyMs || tgt.maxBwKbps != r.plan.maxBwKbps {
            s.reconnect("延迟 \(tgt.latencyMs)→\(r.plan.latencyMs)ms / 限速 \(tgt.maxBwKbps)→\(r.plan.maxBwKbps)kbps")
        }
    }

    var currentReq: VideoReq? {
        lock.lock(); defer { lock.unlock() }
        return req
    }

    // MARK: - 帧输入（相机线程）

    func appendFrame(_ pixelBuffer: CVPixelBuffer, hostPtsNs: Int64) {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        lock.lock()
        capFrames += 1
        inputWidth = w
        inputHeight = h
        guard let r = req, let size = targetSizeLocked(r) else { lock.unlock(); return }
        let want = config(for: r, size: size)
        var enc = encoder
        var rebuildMsg: String?
        var retired: SdH264Encoder?
        if enc == nil || Self.structuralChange(enc!.config, want), want != failedConfig {
            let old = enc
            do {
                let created = try makeEncoder(want)
                encoder = created
                encodeWidth = want.width
                encodeHeight = want.height
                peak.reset(r.plan, qpRuntime: created.qpConfigured)
                enc = created
                let from = old.map { "\($0.config.width)x\($0.config.height)@\($0.config.fps)" } ?? "无"
                rebuildMsg = "换编码器 \(from) → \(want.width)x\(want.height)@\(want.fps) 目标\(want.bitrateKbps)kbps" +
                    " GOP\(want.gopSec)s 采集\(w)x\(h)（SRT 不断）"
                retired = old
            } catch {
                failedConfig = want
                rebuildMsg = "⚠️ 编码器创建失败 \(want.width)x\(want.height)@\(want.fps): \(error.localizedDescription)，保持原编码器"
            }
        }
        lock.unlock()
        // 旧会话在锁外失效：VideoToolbox 回调可能正等 lock（onEncoded），锁内 Invalidate 会互等
        retired?.stop()
        if let rebuildMsg { SdLog.i(rebuildMsg) }
        enc?.encode(pixelBuffer, hostPtsNs: hostPtsNs)
    }

    func requestKeyFrame() {
        lock.lock(); let enc = encoder; lock.unlock()
        enc?.requestKeyFrame()
    }

    /// 编码尺寸：档位宽高；采集比它小时按采集等比缩（不放大），偶数对齐
    private func targetSizeLocked(_ r: VideoReq) -> (width: Int, height: Int)? {
        let pw = r.plan.width, ph = r.plan.height
        guard inputWidth > 0, inputHeight > 0 else { return nil }
        if inputWidth >= pw && inputHeight >= ph { return (pw & ~1, ph & ~1) }
        let scale = min(Double(inputWidth) / Double(pw), Double(inputHeight) / Double(ph))
        let w = max(2, Int(Double(pw) * scale) & ~1)
        let h = max(2, Int(Double(ph) * scale) & ~1)
        return (w, h)
    }

    private func config(for r: VideoReq, size: (width: Int, height: Int)) -> SdH264Encoder.Config {
        SdH264Encoder.Config(width: size.width, height: size.height, fps: r.fps, bitrateKbps: r.kbps,
                             bitrateMode: r.plan.bitrateMode, qpPMax: r.plan.qpPMax,
                             gopSec: r.plan.gopSec, peakKbps: r.plan.peakKbps)
    }

    private static func structuralChange(_ a: SdH264Encoder.Config, _ b: SdH264Encoder.Config) -> Bool {
        a.width != b.width || a.height != b.height || a.fps != b.fps || a.gopSec != b.gopSec ||
        a.bitrateMode != b.bitrateMode || a.qpPMax != b.qpPMax || a.peakKbps != b.peakKbps
    }

    private func makeEncoder(_ cfg: SdH264Encoder.Config) throws -> SdH264Encoder {
        let box = EncoderBox()
        let enc = try SdH264Encoder(config: cfg) { [weak self] data, ptsUs, isKey, hostPtsNs in
            guard let self, let me = box.encoder else { return }
            self.onEncoded(from: me, data: data, ptsUs: ptsUs, isKey: isKey, hostPtsNs: hostPtsNs)
        }
        box.encoder = enc
        return enc
    }

    private func onEncoded(from enc: SdH264Encoder, data: [UInt8], ptsUs: Int64, isKey: Bool, hostPtsNs: Int64) {
        lock.lock()
        let current = encoder === enc
        let s = sender
        lock.unlock()
        // 换编码器时新旧短暂并存：只收当前编码器的输出（muxer 非线程安全）
        guard current, let s, s.connected else { return }
        // 每帧打上 采集/编码完成 墙钟时间（SEI），PC 据此算端到端延迟
        let nowWall = Int64(Date().timeIntervalSince1970 * 1000)
        let cap = SdLatencySei.captureWallMs(hostPtsNs: hostPtsNs, nowWallMs: nowWall)
        let stamped = SdLatencySei.insert(data, captureMs: cap > 0 ? cap : nowWall, encodedMs: nowWall)
        muxLock.lock()
        let ts = muxer.mux(stamped, ptsUs: ptsUs, isKey: isKey)
        muxLock.unlock()
        s.offer(ts, isKey: isKey)
    }

    // MARK: - SRT

    func startSender() {
        lock.lock()
        guard sender == nil else { lock.unlock(); return }
        let s = SdSrtSender(
            targetProvider: { [weak self] attempt in
                guard let self, let r = self.currentReq else { return nil }
                return self.host?.srtTarget(attempt: attempt, plan: r.plan)
            },
            onNeedKeyFrame: { [weak self] in self?.requestKeyFrame() },
            onLive: { [weak self] attempt in self?.host?.onSrtLive(attempt: attempt) },
            onLost: { [weak self] reason in self?.host?.onSrtLost(reason: reason) })
        sender = s
        resetStatBaselinesLocked()
        lock.unlock()
        s.start()
    }

    func stopSender() {
        lock.lock()
        let s = sender
        sender = nil
        lock.unlock()
        s?.stop()
    }

    var senderConnected: Bool {
        lock.lock(); let s = sender; lock.unlock()
        return s?.connected ?? false
    }

    var senderLive: Bool {
        lock.lock(); let s = sender; lock.unlock()
        return s?.live ?? false
    }

    /// 停推流 + 释放编码器（采集由 WebRTCManager 管）
    func stop() {
        stopSender()
        lock.lock()
        let enc = encoder
        encoder = nil
        encodeWidth = 0
        encodeHeight = 0
        lock.unlock()
        enc?.stop()
    }

    // MARK: - PC「SRT设置」回读（编码/链路部分；相机部分由 WebRTCManager 补）

    func encoderState() -> [String: Any] {
        lock.lock()
        let r = req
        let enc = encoder
        let s = sender
        var m: [String: Any] = [
            "width": encodeWidth,
            "height": encodeHeight,
            "fps": r?.fps ?? 0,
            "kbps": r?.kbps ?? 0,
        ]
        if let r {
            m["profile"] = r.plan.profile
            m["qpIMin"] = r.plan.qpIMin
            m["qpIMax"] = r.plan.qpIMax
            m["qpPMin"] = r.plan.qpPMin
            m["qpPMax"] = r.plan.qpPMax
            m["qpOk"] = enc?.qpConfigured ?? false
            m["qpAvg"] = -1
            m["qpPMaxNow"] = peak.curPMax
        }
        lock.unlock()
        m["latencyMs"] = s?.currentTarget?.latencyMs ?? (r?.plan.latencyMs ?? 0)
        if let s {
            m["rttMs"] = Int(s.rttMs)
            m["sndBufMs"] = s.sndBufMs
            m["srtState"] = s.state
        }
        return m
    }

    // MARK: - 每秒统计

    private var lastTickMs: Int64 = 0
    private var lastCapFrames: Int64 = 0
    private var lastEncFrames: Int64 = 0
    private var lastSent: Int64 = 0
    private var lastLoss: Int64 = 0
    private var lastRetrans: Int64 = 0
    private var lastDrop: Int64 = 0

    private func resetStatBaselinesLocked() {
        lastSent = 0; lastLoss = 0; lastRetrans = 0; lastDrop = 0
    }

    func tick(extra: String? = nil) -> Snapshot {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        lock.lock()
        let dt = lastTickMs == 0 ? 1.0 : Double(max(1, now - lastTickMs)) / 1000.0
        lastTickMs = now
        let enc = encoder
        let s = sender
        let r = req
        let capNow = capFrames
        let capFps = capNow >= lastCapFrames ? Int(Double(capNow - lastCapFrames) / dt) : 0
        lastCapFrames = capNow
        let encFrames = enc?.framesTotal ?? 0
        let encAlive = enc != nil && encFrames != lastEncFrames
        lastEncFrames = encFrames
        let encKbps = encAlive ? (enc?.statKbps ?? 0) : 0
        let encFps = encAlive ? (enc?.statFps ?? 0) : 0

        // SRT 累计值在新 socket 上会归零 → 回退时重置基线
        func delta(_ cur: Int64, _ last: Int64) -> Int64 { cur >= last ? cur - last : cur }
        let sent = s?.sentTotal ?? 0
        let loss = s?.lossTotal ?? 0
        let retrans = s?.retransTotal ?? 0
        let drop = s?.sndDropTotal ?? 0
        let dSent = delta(sent, lastSent)
        let dLoss = delta(loss, lastLoss)
        let dRetrans = delta(retrans, lastRetrans)
        let dDrop = delta(drop, lastDrop)
        lastSent = sent; lastLoss = loss; lastRetrans = retrans; lastDrop = drop
        let lossRate = dSent > 0 ? min(1.0, max(0.0, Double(dLoss) / Double(dSent))) : 0.0

        // 峰值控制器
        var peakMsg: String?
        if let enc, let r, let s {
            let connected = s.connected
            if let res = peak.tick(encKbps: encKbps, sndBufMs: s.sndBufMs, connected: connected) {
                switch res.step {
                case .qp(let from, let to)?:
                    enc.setQpMax(to)
                    peakMsg = "\(res.raised ? "压峰值" : "回落") QP上限 \(from)→\(to)（\(res.reason)）"
                case .rate(let fromPct, let toPct)?:
                    let target = r.kbps * toPct / 100
                    enc.setBitrate(target)
                    peakMsg = "\(res.raised ? "压峰值" : "回落") 目标码率 \(fromPct)%→\(toPct)%=\(target)kbps（\(res.reason)）"
                case nil:
                    peakMsg = "峰值超标但无可再降：\(res.reason)"
                }
            }
        }
        let peakDesc = peak.levelDesc
        let targetKbps = (r?.kbps ?? 0) * peak.ratePct / 100
        let ew = encodeWidth, eh = encodeHeight, iw = inputWidth, ih = inputHeight
        lock.unlock()
        if let peakMsg { SdLog.i("峰值控制 \(peakMsg)") }

        var line = "统计 \(s?.state ?? "未推流")"
        line += " | 采集\(capFps)fps(\(iw)x\(ih))"
        line += " | 编码 \(ew)x\(eh) \(encKbps)kbps/目标\(targetKbps) \(encFps)fps QP上限\(enc?.curQpMax ?? 0)"
        line += " I\((enc?.lastIBytes ?? 0) / 1024)KB P均\((enc?.statPAvgBytes ?? 0) / 1024)KB P峰\((enc?.statPMaxBytes ?? 0) / 1024)KB"
        if let enc, enc.encodeErrors > 0 { line += " 编码错误\(enc.encodeErrors)" }
        if let s {
            line += " | SRT 发送\(String(format: "%.2f", s.sendMbps))Mbps 估计\(String(format: "%.1f", s.bandwidthMbps))Mbps RTT\(Int(s.rttMs))ms"
            line += " 发送缓冲\(s.sndBufMs)ms 在途\(s.flightPkts) 本秒丢\(dLoss) 重传\(dRetrans) 迟到丢\(dDrop) 断线丢帧\(s.droppedFrames) 重连\(s.reconnects)"
        }
        line += " | 峰值控制 \(peakDesc)"
        if let extra, !extra.isEmpty { line += " | \(extra)" }
        SdLog.i(line)
        return Snapshot(
            connected: s?.connected ?? false,
            live: s?.live ?? false,
            encKbps: encKbps,
            encFps: encFps,
            capFps: capFps,
            rttMs: Int(s?.rttMs ?? 0),
            lossRate: lossRate,
            line: line)
    }
}

/// 峰值控制器（照 Android SdPeakController.kt）：每秒看编码实际 kbps 与 SRT 发送缓冲。
/// - 超标：实际码率 > peakKbps，或发送缓冲 > 45% latency，连续 holdSec 秒 →
///   先 QP 上限 += qpStep（≤ qpCeil，iOS 15+ MaxAllowedFrameQP）；QP 到顶或不支持 → 目标码率降 10%/档（最多到 50%）。
/// - 拥塞保护：上面两样到底后发送缓冲仍持续超标（上行真不够）→ QP 上限一步放到 jamQp，码率再降到最低 jamRateMin%。
///   上行被视频挤满时 WebSocket 心跳/指令也过不去（PC 显示码率 0、调不了参数），拥塞久了 SRT 也会断。
/// - 平稳：实际码率 ≤ 80% 峰值且发送缓冲 < 15% latency，连续 recoverSec 秒 → 撤销最近一步。
final class SdPeakController {
    static let jamQp = 45
    static let jamRateMin = 20

    enum Step {
        case qp(from: Int, to: Int)
        case rate(fromPct: Int, toPct: Int)
    }

    struct Result {
        let step: Step?
        let raised: Bool
        let reason: String
    }

    private var plan: SrtDirectParams.Plan?
    private var qpRuntime = false
    private var steps: [Step] = []
    private var overSec = 0
    private var calmSec = 0

    /// 当前 QP 上限（含控制器抬高量）
    private(set) var curPMax = 0
    /// 当前码率系数（百分比）
    private(set) var ratePct = 100

    var levelDesc: String {
        steps.isEmpty ? "平稳" : "已介入\(steps.count)步(QP≤\(curPMax) 码率\(ratePct)%)"
    }

    /// 新编码器/新参数：清零
    func reset(_ p: SrtDirectParams.Plan, qpRuntime: Bool) {
        plan = p
        self.qpRuntime = qpRuntime
        steps.removeAll()
        overSec = 0
        calmSec = 0
        curPMax = p.qpPMax
        ratePct = 100
    }

    func tick(encKbps: Int, sndBufMs: Int, connected: Bool) -> Result? {
        guard let p = plan else { return nil }
        if !p.peakEnable || !connected {
            overSec = 0; calmSec = 0
            return nil
        }
        let peakOver = p.peakKbps > 0 && encKbps > p.peakKbps
        let bufOver = sndBufMs > p.latencyMs * 45 / 100
        let calm = (p.peakKbps <= 0 || encKbps <= p.peakKbps * 8 / 10) && sndBufMs < p.latencyMs * 15 / 100
        if peakOver || bufOver {
            overSec += 1; calmSec = 0
        } else if calm {
            calmSec += 1; overSec = 0
        } else {
            overSec = 0; calmSec = 0
        }
        var why = ""
        if peakOver { why += "实际\(encKbps)kbps>峰值\(p.peakKbps)" }
        if bufOver { why += (why.isEmpty ? "" : " ") + "发送缓冲\(sndBufMs)ms>45%延迟" }
        if overSec >= p.holdSec {
            overSec = 0
            let jamQp = max(Self.jamQp, p.qpCeil)
            let s: Step?
            var jam = false
            if qpRuntime && curPMax < p.qpCeil {
                s = .qp(from: curPMax, to: min(p.qpCeil, curPMax + p.qpStep))
            } else if ratePct > 50 {
                s = .rate(fromPct: ratePct, toPct: ratePct - 10)
            } else if bufOver && qpRuntime && curPMax < jamQp {
                s = .qp(from: curPMax, to: jamQp); jam = true
            } else if bufOver && ratePct > Self.jamRateMin {
                s = .rate(fromPct: ratePct, toPct: ratePct - 10); jam = true
            } else {
                s = nil
            }
            guard let step = s else {
                let floor = bufOver ? "QP 上限 \(jamQp) 且码率 \(Self.jamRateMin)%" : "QP 上限 \(p.qpCeil) 且码率 50%"
                return Result(step: nil, raised: true, reason: "\(why)（已到 \(floor)，无可再降）")
            }
            apply(step)
            steps.append(step)
            return Result(step: step, raised: true, reason: "\(why) 连续\(p.holdSec)s" + (jam ? "，上行不够 → 拥塞保护" : ""))
        }
        if calmSec >= p.recoverSec, let last = steps.popLast() {
            calmSec = 0
            let back: Step
            switch last {
            case .qp(let from, let to): back = .qp(from: to, to: from)
            case .rate(let fromPct, let toPct): back = .rate(fromPct: toPct, toPct: fromPct)
            }
            apply(back)
            return Result(step: back, raised: false, reason: "平稳\(p.recoverSec)s（实际\(encKbps)kbps 发送缓冲\(sndBufMs)ms）")
        }
        return nil
    }

    private func apply(_ s: Step) {
        switch s {
        case .qp(_, let to): curPMax = to
        case .rate(_, let toPct): ratePct = toPct
        }
    }
}
