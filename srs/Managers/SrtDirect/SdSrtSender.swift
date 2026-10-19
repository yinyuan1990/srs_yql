//
//  SdSrtSender.swift
//  srs
//
//  SRT（live）发送 MPEG-TS 到 MediaMTX，照 Android SdSrtSender.kt：
//  - 编码回调线程里同步发送、不排队；网络跟不上时 SRT 按 latency 丢迟到包，峰值由峰值控制器压；
//  - 每 1316 字节（7 个 TS 包）一次 srt_send；
//  - 每次连接都调 targetProvider 取地址/延迟/限速/streamid（推流 token 一次性，重连必须重取）；
//  - 断线 2s 自动重连，流名不变（MediaMTX 同路径新推流顶掉旧会话，PC 不用跟流名）；
//  - 连上后丢到首个 IDR 为止；首个 IDR 发出回调 onLive。
//
//  libsrt 来自工程已引入的 HaishinKit（SRTHaishinKit 依赖的 libsrt.xcframework）。
//

import Foundation
import libsrt

final class SdSrtSender {
    struct Target: Equatable {
        let host: String
        let port: Int
        let streamId: String
        let latencyMs: Int
        /// >0 时设 SRTO_MAXBW（绝对上限）；0=libsrt 默认
        let maxBwKbps: Int
    }

    private static let chunk = SdTsMuxer.packetSize * 7
    private static let reconnectDelay: TimeInterval = 2
    private static let slowSendMs: Int64 = 300
    private static let noFrameWarnMs: Int64 = 2000
    private static var startedUp = false
    private static let startupLock = NSLock()

    /// 连接线程里调用（可阻塞取 token）；attempt=第几次连接（0=首次）
    private let targetProvider: (Int) -> Target?
    private let onNeedKeyFrame: () -> Void
    /// 某次连接成功后首个关键帧已发出；在编码回调线程调用
    private let onLive: (Int) -> Void
    /// 断线（含原因）
    private let onLost: (String) -> Void

    private let lock = NSLock()
    private let sendLock = NSLock()
    private var socket: SRTSOCKET = -1
    private var running = false
    private var waitKey = true
    private var thread: Thread?
    private var attempts = 0
    private var currentAttempt = 0
    private(set) var currentTarget: Target?

    // —— 状态/统计 ——
    private(set) var state = "未开始"
    private(set) var live = false
    private(set) var droppedFrames: Int64 = 0
    private(set) var reconnects = 0
    private(set) var sendMbps = 0.0
    private(set) var rttMs = 0.0
    private(set) var sentTotal: Int64 = 0
    private(set) var lossTotal: Int64 = 0
    private(set) var retransTotal: Int64 = 0
    private(set) var sndDropTotal: Int64 = 0
    /// SRT 发送缓冲里还没发出去的数据（毫秒）：持续变大 = 上行带宽不够
    private(set) var sndBufMs = 0
    private(set) var bandwidthMbps = 0.0
    private(set) var flightPkts = 0
    private(set) var lastError = ""

    private var connectedAtMs: Int64 = 0
    private var lastOfferMs: Int64 = 0
    private var noFrameWarned = false
    private var closeReason: String?
    private var waitKeySinceMs: Int64 = 0
    private var waitKeyDrops = 0

    var connected: Bool {
        lock.lock(); defer { lock.unlock() }
        return socket >= 0
    }

    init(targetProvider: @escaping (Int) -> Target?,
         onNeedKeyFrame: @escaping () -> Void,
         onLive: @escaping (Int) -> Void,
         onLost: @escaping (String) -> Void) {
        self.targetProvider = targetProvider
        self.onNeedKeyFrame = onNeedKeyFrame
        self.onLive = onLive
        self.onLost = onLost
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    func start() {
        lock.lock()
        running = true
        lock.unlock()
        let t = Thread { [weak self] in self?.connectLoop() }
        t.name = "sd-srt-conn"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    func stop() {
        SdLog.i("停止发送（共重连 \(reconnects) 次，断线丢帧 \(droppedFrames)）")
        lock.lock()
        running = false
        closeSocketLocked()
        live = false
        state = "已停止"
        lock.unlock()
        thread?.cancel()
        thread = nil
    }

    /// 参数变了（延迟/限速/节点）：主动断开，2s 后按新参数重连（流名不变）
    func reconnect(_ reason: String) {
        lock.lock()
        let s = socket
        lock.unlock()
        guard s >= 0 else { return }
        SdLog.i("主动重连：\(reason)")
        closeReason = "主动重连(\(reason))"
        onDisconnected(s, reason: "主动重连(\(reason))", notify: false)
    }

    /// 编码回调线程调用：同步发送一帧 TS（断线中直接丢弃）
    func offer(_ ts: [UInt8], isKey: Bool) {
        let now = Self.nowMs()
        var liveAttempt = -1
        var failure: (SRTSOCKET, String)?
        lock.lock()
        guard running else { lock.unlock(); return }
        if noFrameWarned {
            SdLog.i("帧恢复送来（中断 \(now - lastOfferMs)ms）")
            noFrameWarned = false
        }
        lastOfferMs = now
        let s = socket
        if s < 0 {
            droppedFrames += 1
            lock.unlock()
            return
        }
        if waitKey && !isKey {
            droppedFrames += 1
            waitKeyDrops += 1
            lock.unlock()
            return
        }
        if waitKey {
            SdLog.i("连上后首个关键帧已发：等了 \(now - waitKeySinceMs)ms，期间丢 \(waitKeyDrops) 帧（IDR \(ts.count / 1024)KB）")
            waitKey = false
            live = true
            state = "推流中"
            liveAttempt = currentAttempt
        }
        lock.unlock()
        // 发送只串行在 sendLock 上，状态锁不跨阻塞发送（统计/心跳读状态不被慢发送卡住）
        sendLock.lock()
        let t0 = Self.nowMs()
        var off = 0
        var err: String?
        ts.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            base.withMemoryRebound(to: CChar.self, capacity: buf.count) { p in
                while off < buf.count {
                    let n = min(Self.chunk, buf.count - off)
                    let r = srt_send(s, p + off, Int32(n))
                    if r < 0 {
                        err = String(cString: srt_getlasterror_str())
                        return
                    }
                    off += n
                }
            }
        }
        let cost = Self.nowMs() - t0
        sendLock.unlock()
        if let err {
            let cause = closeReason.map { "\($0)；" } ?? ""
            failure = (s, "\(cause)发送失败: \(err)（帧 \(ts.count / 1024)KB）")
            liveAttempt = -1
        } else if cost > Self.slowSendMs {
            SdLog.w("发送阻塞 \(cost)ms（帧 \(ts.count / 1024)KB\(isKey ? " 关键帧" : "")）" +
                    " 发送缓冲 \(sndBufMs)ms 链路估计 \(String(format: "%.1f", bandwidthMbps))Mbps")
        }
        if let failure { onDisconnected(failure.0, reason: failure.1) }
        if liveAttempt >= 0 { onLive(liveAttempt) }
    }

    private func onDisconnected(_ s: SRTSOCKET, reason: String, notify: Bool = true) {
        lock.lock()
        guard socket == s else { lock.unlock(); return }
        let alive = Double(Self.nowMs() - connectedAtMs) / 1000.0
        readStatsLocked(s)
        SdLog.w("断线 \(reason)；本次连接存活 \(String(format: "%.1f", alive))s；断前 \(statsLineLocked())")
        lastError = reason
        state = "连接断开，重连中…"
        closeSocketLocked()
        live = false
        reconnects += 1
        lock.unlock()
        if notify { onLost(reason) }
    }

    func statsLine() -> String {
        lock.lock(); defer { lock.unlock() }
        return statsLineLocked()
    }

    private func statsLineLocked() -> String {
        "发送\(String(format: "%.2f", sendMbps))Mbps 估计带宽\(String(format: "%.1f", bandwidthMbps))Mbps RTT\(Int(rttMs))ms" +
        " 发送缓冲\(sndBufMs)ms 在途\(flightPkts)包 累计丢\(lossTotal) 重传\(retransTotal) 迟到丢弃\(sndDropTotal)"
    }

    private func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private func connectLoop() {
        Self.startupLock.lock()
        if !Self.startedUp {
            if srt_startup() < 0 {
                Self.startupLock.unlock()
                lock.lock()
                state = "SRT 库初始化失败"
                lastError = String(cString: srt_getlasterror_str())
                lock.unlock()
                SdLog.w("SRT 库初始化失败: \(lastError)")
                return
            }
            Self.startedUp = true
        }
        Self.startupLock.unlock()

        while isRunning() {
            lock.lock()
            let s = socket
            lock.unlock()
            if s < 0 {
                if !connect() { Thread.sleep(forTimeInterval: Self.reconnectDelay) }
                continue
            }
            lock.lock()
            readStatsLocked(s)
            lock.unlock()
            checkSocket(s)
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func checkSocket(_ s: SRTSOCKET) {
        let st = srt_getsockstate(s)
        if st == SRTS_BROKEN || st == SRTS_CLOSED || st == SRTS_NONEXIST {
            let reason = "检测到 socket 状态 \(st.rawValue)（服务器关闭连接 / 网络中断 / 被同名新推流顶掉）"
            closeReason = reason
            onDisconnected(s, reason: reason)
            return
        }
        lock.lock()
        let gap = Self.nowMs() - max(lastOfferMs, connectedAtMs)
        var warn = false
        if !noFrameWarned && gap > Self.noFrameWarnMs {
            noFrameWarned = true
            warn = true
        }
        lock.unlock()
        if warn { SdLog.w("已连接但 \(gap)ms 没有帧送来（摄像头/编码器没出帧，或编码线程卡在上一次发送里）") }
    }

    private func setInt(_ s: SRTSOCKET, _ opt: SRT_SOCKOPT, _ value: Int32) -> Bool {
        var v = value
        return srt_setsockflag(s, opt, &v, Int32(MemoryLayout<Int32>.size)) >= 0
    }

    private func connect() -> Bool {
        let attempt = attempts
        attempts += 1
        let t0 = Self.nowMs()
        guard let tgt = targetProvider(attempt) else { return false }
        guard isRunning() else { return false }
        lock.lock()
        currentTarget = tgt
        state = "连接 \(tgt.host):\(tgt.port) …"
        lock.unlock()

        let s = srt_create_socket()
        if s < 0 {
            SdLog.w("创建 SRT socket 失败: \(String(cString: srt_getlasterror_str()))")
            return false
        }
        // TRANSTYPE 最先设：它会把其它选项重置为 live 模式默认值
        _ = setInt(s, SRTO_TRANSTYPE, Int32(truncatingIfNeeded: SRTT_LIVE.rawValue))
        _ = tgt.streamId.withCString { p in
            srt_setsockflag(s, SRTO_STREAMID, p, Int32(strlen(p)))
        }
        _ = setInt(s, SRTO_SENDER, 1)
        _ = setInt(s, SRTO_TSBPDMODE, 1)
        _ = setInt(s, SRTO_LATENCY, Int32(tgt.latencyMs))
        _ = setInt(s, SRTO_PEERLATENCY, Int32(tgt.latencyMs))
        _ = setInt(s, SRTO_RCVLATENCY, Int32(tgt.latencyMs))
        _ = setInt(s, SRTO_PAYLOADSIZE, Int32(Self.chunk))
        _ = setInt(s, SRTO_CONNTIMEO, Int32(min(10_000, max(1000, tgt.latencyMs * 20))))
        if tgt.maxBwKbps > 0 {
            // 字节/秒；绝对上限 —— 尖峰在 latency 窗口内摊平
            var bw = Int64(tgt.maxBwKbps) * 125
            _ = srt_setsockflag(s, SRTO_MAXBW, &bw, Int32(MemoryLayout<Int64>.size))
        }

        var ok = false
        var errText = ""
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        let gai = getaddrinfo(tgt.host, String(tgt.port), &hints, &res)
        if gai == 0, let ai = res, let addr = ai.pointee.ai_addr {
            ok = srt_connect(s, addr, Int32(ai.pointee.ai_addrlen)) >= 0
            if !ok { errText = String(cString: srt_getlasterror_str()) }
        } else {
            errText = "域名解析失败(\(gai))"
        }
        if res != nil { freeaddrinfo(res) }

        if !ok {
            let reject = srt_getrejectreason(s)
            let rejectText = String(cString: srt_rejectreason_str(reject))
            lock.lock()
            lastError = "连接失败: \(errText) 拒绝原因=\(rejectText)"
            state = "连接失败：\(errText)"
            lock.unlock()
            SdLog.w("连接失败 \(tgt.host):\(tgt.port) streamid=\(SdLog.maskStreamId(tgt.streamId)): \(errText) 拒绝原因=\(rejectText)" +
                    "（耗时\(Self.nowMs() - t0)ms；常见：8890/udp 不通 / MediaMTX 鉴权拒绝(token 无效) / 流名非法）")
            srt_close(s)
            return false
        }

        lock.lock()
        if !running {
            lock.unlock()
            srt_close(s)
            return false
        }
        socket = s
        currentAttempt = attempt
        waitKey = true
        live = false
        waitKeySinceMs = Self.nowMs()
        waitKeyDrops = 0
        connectedAtMs = waitKeySinceMs
        noFrameWarned = false
        closeReason = nil
        state = "已连接，等关键帧"
        lock.unlock()
        onNeedKeyFrame()
        SdLog.i("已连接 \(tgt.host):\(tgt.port) streamid=\(SdLog.maskStreamId(tgt.streamId)) latency=\(tgt.latencyMs)ms" +
                " 限速=\(tgt.maxBwKbps > 0 ? "\(tgt.maxBwKbps)kbps" : "不限") 握手\(Self.nowMs() - t0)ms（第\(attempt + 1)次连接）")
        return true
    }

    private func readStatsLocked(_ s: SRTSOCKET) {
        var st = SRT_TRACEBSTATS()
        guard srt_bstats(s, &st, 0) >= 0 else { return }
        sendMbps = st.mbpsSendRate
        rttMs = st.msRTT
        sentTotal = st.pktSentTotal
        lossTotal = Int64(st.pktSndLossTotal)
        retransTotal = Int64(st.pktRetransTotal)
        sndDropTotal = Int64(st.pktSndDropTotal)
        sndBufMs = Int(st.msSndBuf)
        bandwidthMbps = st.mbpsBandwidth
        flightPkts = Int(st.pktFlightSize)
    }

    private func closeSocketLocked() {
        let s = socket
        socket = -1
        if s >= 0 { srt_close(s) }
    }
}
