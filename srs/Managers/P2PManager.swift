//
//  P2PManager.swift
//  金凤凰
//
//  独立的 P2P/WebRTC 直连管理类。
//  - 与 SRS 模式互斥：connect_mode == "p2p" 时由 WebRTCManager 启动本类，SRS 推流不启用。
//  - 多观看端：每个观看 PC 一个独立 RTCPeerConnection。
//  - 链路顺序：P2P 直连(host/srflx) → TURN 中继(relay)；不回退 SRS（由全局开关决定走哪条）。
//  - 信令走 WebSocketManager 的 /app/webrtc/signal，本类只负责会话与 ICE 逻辑。
//

import Foundation
import WebRTC
import Network

// MARK: - P2P 信令通知名
extension Notification.Name {
    static let webrtcSignalingReceived = Notification.Name("webrtcSignalingReceived")
    static let webSocketDidReconnect = Notification.Name("webSocketDidReconnect")
}

// MARK: - 数据源：由 WebRTCManager 提供工厂、视频轨与当前编码参数
protocol P2PManagerDataSource: AnyObject {
    /// 共享同一个 RTCPeerConnectionFactory（视频轨与会话需同源）
    var p2pFactory: RTCPeerConnectionFactory { get }
    /// 当前本地视频轨（采集管线产出，P2P 复用不另起采集）
    var p2pLocalVideoTrack: RTCVideoTrack? { get }
    /// 当前码率区间（kbps）
    func p2pBitrateRangeKbps() -> (min: Int, max: Int)
    /// 当前目标推送 FPS
    func p2pTargetFps() -> Int
    /// 当前分辨率缩放比
    func p2pScaleDown() -> Double
}

final class P2PManager: NSObject {

    /// 当前 P2P 观看端数（供心跳上报）
    static var currentViewerCount: Int = 0

    weak var dataSource: P2PManagerDataSource?
    /// iOS 本机网络类型变化时回调（用于触发上层 P2P/SRS 重新评估）
    var onLocalNetworkChange: (() -> Void)?
    /// 某 PC 的 P2P 彻底失败（ICE 重试耗尽）→ 上层应回落 SRS
    var onViewerPermanentlyFailed: ((String) -> Void)?
    /// ⭐ 切网触发重连（拆会话+HANGUP，等 PC 重发 REQUEST）→ 上层置"重连中"给左上角 UI
    var onNetworkSwitchReconnect: (() -> Void)?

    private(set) var isActive = false
    /// 是否就绪接收观看请求（采集/视频轨已就绪）
    var isReadyForViewers = false

    // 每个观看 PC 一个独立会话
    private(set) var viewerSessions: [String: RTCPeerConnection] = [:] {
        didSet { P2PManager.currentViewerCount = viewerSessions.count }
    }

    /// 已连接（ICE connected/completed）的观看会话，供 WebRTCManager 采集码率/网络 stats。
    /// P2P 模式下 PeerConnection 不在 WebRTCManager.pc 上，码率统计需从这里取，否则上报 kbps 恒为 0。
    var connectedViewerPeerConnections: [RTCPeerConnection] {
        viewerSessions.values.filter {
            $0.iceConnectionState == .connected || $0.iceConnectionState == .completed
        }
    }

    /// ⭐ 2026-07-02 统计主源（稳定版）：按 pcId 排序取第一个已连接会话。
    /// 背景：Swift Dictionary 无序，`connectedViewerPeerConnections.first` 在多观看端时每次调用
    /// 可能取到不同会话 → statsTimer 的累计值基线(bytes/packetsLost/pliCount)在两路会话间来回跳 →
    /// 增量全部错乱（假 PLI 风暴/假丢包/kbps 乱跳），曾导致「网络极好也周期性 forceKeyframe → 攒帧卡顿」。
    var primaryStatsPeerConnection: RTCPeerConnection? {
        for pcId in viewerSessions.keys.sorted() {
            if let s = viewerSessions[pcId],
               s.iceConnectionState == .connected || s.iceConnectionState == .completed {
                return s
            }
        }
        return nil
    }
    private var viewerSenders: [String: RTCRtpSender] = [:]
    private var pendingRemoteIce: [String: [RTCIceCandidate]] = [:]
    private var pendingIceRestart: Set<String> = []
    private var iceRetryCount: [String: Int] = [:]
    private let maxICERetries = 2
    private var forceRelayPeerIds: Set<String> = []     // ICE 失败黑名单 → 重建时强制 relay
    /// ⭐ §25.7b：链路择优的 relay 钉住集合。与 forceRelayPeerIds 的区别：**跨会话拆建存活**
    ///（removeViewerSession 不清除，仅 closeAllViewerSessions/stop 清），因为硬切中继 =
    /// 拆会话让 PC 重新 REQUEST，重建时必须还记得「这个 PC 要走 relay」。
    private var qualityRelayPeerIds: Set<String> = []
    private var peerNetworkType: [String: String] = [:] // pcDeviceId → "cellular"/"wifi"/...

    /// ⭐ §53.3①：最近一次给某个 PC 发出 Offer 的时刻。
    /// 用来判定「重复的 WEBRTC_REQUEST」——**不再用 PeerConnection 的 new/connecting 状态判**。
    /// 旧实现把 state ∈ {new, connecting} 一律当"建立中，忽略重复请求"，但上一个 PC 进程消失后
    /// 那条会话会在 connecting 上挂几十秒（ICE 自己重试），而 VIEWER_DISCONNECTED 当时又不拆会话 →
    /// 新登录的 PC 用同一个 pcDeviceId 来请求，5 次重试全被吞掉 → PC 等 Offer 超时黑屏（两端却都"在线"）。
    private var lastOfferSentAt: [String: Date] = [:]
    /// 同一个 pcId 在这个窗口内的重复请求才算"竞态重试"而忽略；超过就一律拆旧建新。
    /// 取 2s：PC 侧重发间隔 1.5s（gstplayer.cpp P2P_VIEW_REQUEST_RETRY_INTERVAL_MS），
    /// 给上一个 Offer 留出到达时间，又不至于让幽灵会话长期吞请求。
    private let duplicateRequestWindowSec: Double = 2.0
    /// PC 带来的 requestId（每次 connectP2P/重发递增，旧版 PC 不带）。仅用于日志与"变了就必须重建"。
    private var lastRequestId: [String: Int64] = [:]

    private var signalingObserver: NSObjectProtocol?
    private var reconnectObserver: NSObjectProtocol?

    // 本机网络监听（蜂窝强制 relay + 切网重连）
    private var isOnCellular = false
    private let nwMonitor = NWPathMonitor()
    private let nwQueue = DispatchQueue(label: "p2p.nwpath", qos: .utility)
    private var nwStarted = false
    // 切网检测：记录上次 path 状态/接口指纹，用于捕获 WiFi↔WiFi（同类型）切换
    private var lastPathSatisfied = false
    private var lastInterfaceFingerprint = ""
    private var lastNetSwitchAt: TimeInterval = 0

    var maxViewers: Int { let v = UserDefaults.standard.integer(forKey: "maxP2PViewers"); return v > 0 ? v : 4 }
    var forceRelay: Bool { UserDefaults.standard.bool(forKey: "forceRelay") }

    var viewerCount: Int { viewerSessions.count }

    // MARK: - 生命周期

    func start() {
        guard !isActive else { return }
        isActive = true
        isReadyForViewers = true
        registerObservers()
        startNetworkMonitoring()
        print("✅ [P2P] P2PManager 启动，maxViewers=\(maxViewers), forceRelay=\(forceRelay)")
    }

    func stop() {
        isReadyForViewers = false
        closeAllViewerSessions(notifyPC: true)
        unregisterObservers()
        isActive = false
        print("🛑 [P2P] P2PManager 停止")
    }

    // MARK: - 观察者

    private func registerObservers() {
        unregisterObservers()
        signalingObserver = NotificationCenter.default.addObserver(
            forName: .webrtcSignalingReceived, object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self, let dict = note.userInfo as? [String: Any] else { return }
            self.handleSignaling(dict)
        }
        reconnectObserver = NotificationCenter.default.addObserver(
            forName: .webSocketDidReconnect, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, !self.viewerSessions.isEmpty else { return }
            print("🔌 [P2P] WebSocket 重连，重连所有 P2P 会话")
            self.restartAllIceForNetworkSwitch()
        }
        print("✅ [P2P] 已注册信令观察者")
    }

    private func unregisterObservers() {
        if let o = signalingObserver { NotificationCenter.default.removeObserver(o); signalingObserver = nil }
        if let o = reconnectObserver { NotificationCenter.default.removeObserver(o); reconnectObserver = nil }
    }

    // MARK: - 网络监听

    private func startNetworkMonitoring() {
        if nwStarted { return }
        nwStarted = true
        nwMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let cellular = path.usesInterfaceType(.cellular)
            let wifi = path.usesInterfaceType(.wifi)
            let wired = path.usesInterfaceType(.wiredEthernet)
            let newCellular = cellular && !wifi && !wired

            // 接口指纹：可用接口名集合（换路由器/换热点时通常变化）
            let fingerprint = path.availableInterfaces.map { $0.name }.sorted().joined(separator: ",")
            let satisfied = (path.status == .satisfied)

            // 三类“切网”信号（任一命中即触发重连）：
            //   1) 蜂窝↔WiFi 类型变化（原有逻辑）
            //   2) 网络从断开恢复（unsatisfied → satisfied，换 WiFi 多经历此过渡）
            //   3) 可用接口指纹变化（WiFi A → WiFi B 同类型切换的关键补充）
            let typeChanged = (newCellular != self.isOnCellular)
            let recovered = (satisfied && !self.lastPathSatisfied)
            let ifaceChanged = (satisfied && !self.lastInterfaceFingerprint.isEmpty && fingerprint != self.lastInterfaceFingerprint)

            self.isOnCellular = newCellular
            self.lastPathSatisfied = satisfied
            self.lastInterfaceFingerprint = fingerprint

            guard satisfied, (typeChanged || recovered || ifaceChanged) else { return }

            // 节流：5s 内多次抖动只触发一次，避免狂刷重连
            let now = Date().timeIntervalSince1970
            if now - self.lastNetSwitchAt < 5.0 { return }
            self.lastNetSwitchAt = now

            print("📶 [P2P] 网络切换检测: 蜂窝=\(newCellular) 类型变=\(typeChanged) 恢复=\(recovered) 接口变=\(ifaceChanged) [\(fingerprint)]")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // 先让上层重新评估（蜂窝→可能整体切 SRS）
                self.onLocalNetworkChange?()
                // 仍在 P2P 的会话做 ICE Restart / 重连
                self.restartAllIceForNetworkSwitch()
            }
        }
        nwMonitor.start(queue: nwQueue)
    }

    /// 网络切换：重新评估每个会话的传输策略（蜂窝→relay）并重连
    ///
    /// ⭐ 2026-07-09 修「切网后必须手动重登 PC 才出画面」根因：
    ///   观看端恒为 PC GStreamer，其 webrtcbin **不支持在旧实例上 ICE Restart**（收新 ufrag 的
    ///   re-offer 不会重启 libnice/重新收集候选 → 新 ICE 永远配不通、卡死 25s）。
    ///   因此切网【不再尝试 ICE Restart】，一律拆会话 + HANGUP(network_switch_reconnect)，
    ///   由 PC 整体重建 pipeline + 重发 WEBRTC_REQUEST，手机再回全新 Offer（干净重连，与手动重登等效但全自动）。
    private func restartAllIceForNetworkSwitch() {
        let sessions = viewerSessions
        if sessions.isEmpty { return }
        print("📶 [P2P] 网络切换，拆除并让 PC 重连 \(sessions.count) 个会话（PC 恒 GStreamer，不做 ICE Restart）")
        for (pcId, _) in sessions {
            iceRetryCount[pcId] = 0
            // 切到蜂窝：拉黑该 peer，PC 重建后手机回的新 Offer 走 TURN relay
            if isOnCellular { forceRelayPeerIds.insert(pcId) }
            removeViewerSession(pcId, notifyPC: false)
            WebSocketManager.shared.sendWebRTCSignaling(type: "WEBRTC_HANGUP",
                                                        reason: "network_switch_reconnect",
                                                        toDevice: pcId)
        }
        onNetworkSwitchReconnect?()   // 通知上层置"重连中"（左上角显示，PC 重连成功后清除）
    }

    /// ⭐ §53.13：回前台 / WS 重连后的会话自检。
    ///
    /// App 被挂到后台期间 socket 会死、ICE 也会断；醒来时**观看端那边早就放弃重试了**
    ///（PC 的 WEBRTC_REQUEST 只重发 5 次共 ~7.5s），于是没有任何人再发起重连，
    /// PC 上就永远停在最后一帧。这里把已经死掉的会话拆掉并发
    /// HANGUP(network_switch_reconnect)——PC 已有处理：不拆 pipeline、自动重发 REQUEST，
    /// 手机再回一个全新 Offer（与切网恢复同一套动作，复用已验证的路径）。
    ///
    /// 没有会话时什么都不做（那是正常的"等 PC 来看"状态）。
    @discardableResult
    func recoverSessionsIfBroken(reason: String) -> Int {
        guard isActive, !viewerSessions.isEmpty else { return 0 }
        var broken: [String] = []
        for (pcId, pc) in viewerSessions {
            switch pc.iceConnectionState {
            case .connected, .completed:
                continue          // 活着，别碰
            default:
                broken.append(pcId)
            }
        }
        guard !broken.isEmpty else {
            print("✅ [P2P] \(reason)：\(viewerSessions.count) 个会话 ICE 均正常，无需重连")
            return 0
        }
        print("🚑 [P2P] \(reason)：\(broken.count)/\(viewerSessions.count) 个会话 ICE 已死 → 拆除并让 PC 重连")
        for pcId in broken {
            iceRetryCount[pcId] = 0
            if isOnCellular { forceRelayPeerIds.insert(pcId) }
            removeViewerSession(pcId, notifyPC: false)
            WebSocketManager.shared.sendWebRTCSignaling(type: "WEBRTC_HANGUP",
                                                        reason: "network_switch_reconnect",
                                                        toDevice: pcId)
        }
        onNetworkSwitchReconnect?()   // 上层置"重连中"，PC 重连成功后由心跳清除
        return broken.count
    }

    // MARK: - 传输策略

    private func effectiveForceRelay(for pcId: String) -> Bool {
        if forceRelay { return true }
        return isOnCellular || peerNetworkType[pcId] == "cellular" || forceRelayPeerIds.contains(pcId)
            || qualityRelayPeerIds.contains(pcId)
    }

    // MARK: - §25.7e 线路预判定（建会话前经 WebSocket 信令定直连/中继）

    /// 本机全部 IPv4（WiFi en0 / 热点 bridge100 / 有线等，排除回环与链路本地 169.254.*）
    private func localIPv4Addresses() -> [String] {
        var results: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return results }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                let flags = Int32(ifa.ifa_flags)
                if (flags & IFF_UP) != 0 && (flags & IFF_LOOPBACK) == 0 {
                    var addr = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                        let ip = String(cString: buf)
                        if !ip.hasPrefix("169.254.") { results.append(ip) }
                    }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return results
    }

    /// 同网段判定（/24）：双方任意一对 IPv4 前三段相同 = 同一局域网（同 WiFi）
    private func sharesSubnet(with peerIps: [String]) -> Bool {
        func prefix24(_ ip: String) -> String? {
            let parts = ip.split(separator: ".")
            guard parts.count == 4 else { return nil }
            return parts[0...2].joined(separator: ".")
        }
        let myPrefixes = Set(localIPv4Addresses().compactMap(prefix24))
        return peerIps.contains { ip in prefix24(ip).map(myPrefixes.contains) ?? false }
    }

    /// ⭐ §25.7e：建会话前预判线路。PC 的 WEBRTC_REQUEST 带 localIps（逗号分隔的局域网 IPv4），
    ///   与本机比网段：非同网段 = 非同 WiFi → pcId 钉进 qualityRelayPeerIds → 会话从创建起
    ///   relay-only，一次 ICE 定终身，不再有「直连先通→ICE 换车→软切/硬切」的中途折腾。
    ///   同网段/字段缺失（旧版 PC）→ 保持直连优先，host↔host stats 判定兜底。
    ///   只进不出：不因后续 REQUEST 判同网段而摘除钉住（防两个不同网络恰好同网段号 → 死循环回直连）。
    private func applyLanPrecheck(for pcId: String, message: [String: Any]) {
        guard let ipsStr = message["localIps"] as? String, !ipsStr.isEmpty else {
            print("🛣 [P2P线路预判] \(pcId) REQUEST 未带 localIps（旧版PC）→ 直连优先+stats兜底")
            return
        }
        let peerIps = ipsStr.split(separator: ",").map(String.init)
        if sharesSubnet(with: peerIps) {
            print("🛣 [P2P线路预判] \(pcId) 同网段(同WiFi) → 直连优先 peer=\(peerIps)")
        } else {
            qualityRelayPeerIds.insert(pcId)
            print("🛣 [P2P线路预判] \(pcId) 非同网段(非同WiFi) → 建会话即中继 peer=\(peerIps) 本机=\(localIPv4Addresses())")
        }
    }

    private func loadIceServers() -> [IceServer] {
        guard let data = UserDefaults.standard.data(forKey: "iceServers"),
              let servers = try? JSONDecoder().decode([IceServer].self, from: data) else { return [] }
        return servers
    }

    // MARK: - 信令处理

    func handleSignaling(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        let fromDevice = message["fromDevice"] as? String ?? ""

        switch type {
        case "VIEWER_CONNECTED":
            print("✅ [P2P] PC \(fromDevice) 已收到画面")
        case "VIEWER_DISCONNECTED":
            // ⭐ §53.3①：必须真的拆会话。以前这里只打日志，PC 退出时发的这条通知等于白发，
            //   会话留在 connecting 上变成"幽灵会话"，把 PC 下次登录的请求全吞掉 → 重登黑屏。
            if viewerSessions[fromDevice] != nil {
                print("🔌 [P2P] PC \(fromDevice) 断开 → 拆会话（防幽灵会话吞掉下次 WEBRTC_REQUEST）")
                removeViewerSession(fromDevice, notifyPC: false)
            } else {
                print("🔌 [P2P] PC \(fromDevice) 断开（无活动会话）")
            }
        case "WEBRTC_REQUEST":
            peerNetworkType[fromDevice] = (message["networkType"] as? String) ?? "unknown"
            applyLanPrecheck(for: fromDevice, message: message)   // §25.7e：建会话前定直连/中继
            guard isReadyForViewers else {
                WebSocketManager.shared.sendWebRTCSignaling(type: "WEBRTC_REJECT", reason: "not_ready", toDevice: fromDevice)
                return
            }
            let reqId = (message["requestId"] as? NSNumber)?.int64Value
            createViewerSession(for: fromDevice, requestId: reqId)
        case "WEBRTC_SDP":
            let sdpType = message["sdpType"] as? String ?? ""
            let sdp = message["sdp"] as? String ?? ""
            if sdpType == "answer" { handleRemoteAnswer(sdp, from: fromDevice) }
        case "WEBRTC_ICE":
            handleRemoteIce(message, from: fromDevice)
        case "WEBRTC_HANGUP":
            removeViewerSession(fromDevice, notifyPC: false)
        default:
            break
        }
    }

    private func handleRemoteAnswer(_ sdp: String, from pcId: String) {
        guard let pc = viewerSessions[pcId] else { return }
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        pc.setRemoteDescription(answer) { [weak self] error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let error = error {
                    print("❌ [P2P] setRemoteDescription 失败(\(pcId)): \(error.localizedDescription)")
                    return
                }
                self.pendingIceRestart.remove(pcId)
                // flush 缓冲的远端 ICE
                if let cands = self.pendingRemoteIce[pcId] {
                    for c in cands { pc.add(c) { _ in } }
                    self.pendingRemoteIce[pcId] = nil
                }
                print("✅ [P2P] 收到 PC \(pcId) Answer，会话建立中")
            }
        }
    }

    private func handleRemoteIce(_ message: [String: Any], from pcId: String) {
        guard let pc = viewerSessions[pcId] else { return }
        let candidate = message["candidate"] as? String ?? ""
        guard !candidate.isEmpty else { return }   // 忽略 end-of-candidates
        let mid = message["sdpMid"] as? String ?? "0"
        let mline = (message["sdpMLineIndex"] as? NSNumber)?.int32Value ?? 0
        let ice = RTCIceCandidate(sdp: candidate, sdpMLineIndex: mline, sdpMid: mid)
        if pc.remoteDescription == nil || pendingIceRestart.contains(pcId) {
            pendingRemoteIce[pcId, default: []].append(ice)
        } else {
            pc.add(ice) { _ in }
        }
    }

    // MARK: - 会话管理

    func createViewerSession(for pcId: String, requestId: Int64? = nil) {
        guard let ds = dataSource else { print("❌ [P2P] dataSource 为空"); return }

        // ⭐ §53.3① 幂等化：判据从「PeerConnection 状态」换成「距上次给这个 PC 发 Offer 多久」。
        //   窗口内 = PC 的重发与我们的 Offer 在路上交错（真竞态）→ 忽略；
        //   窗口外 = PC 确实没拿到 Offer（或是新登录的 PC 撞上幽灵会话）→ 一律拆旧建新、重发 Offer。
        //   requestId 变化视同"新请求"，直接跳过忽略分支（旧版 PC 不带该字段时只靠时间窗）。
        if let existing = viewerSessions[pcId] {
            let sinceOffer = Date().timeIntervalSince(lastOfferSentAt[pcId] ?? .distantPast)
            let sameRequest = (requestId == nil) || (requestId == lastRequestId[pcId])
            if sameRequest && sinceOffer < duplicateRequestWindowSec {
                print("⚠️ [P2P] PC \(pcId) 重复请求（距上次Offer \(String(format: "%.1f", sinceOffer))s，reqId=\(requestId.map(String.init) ?? "无")）→ 忽略")
                return
            }
            print("♻️ [P2P] PC \(pcId) 重新请求（state=\(existing.connectionState.rawValue) 距上次Offer=\(String(format: "%.1f", sinceOffer))s reqId=\(requestId.map(String.init) ?? "无")）→ 拆旧建新")
            removeViewerSession(pcId, notifyPC: false)
        }
        if let rid = requestId { lastRequestId[pcId] = rid }

        guard viewerSessions.count < maxViewers else {
            print("❌ [P2P] 已达最大观看人数(\(maxViewers))，拒绝 \(pcId)")
            WebSocketManager.shared.sendWebRTCSignaling(type: "WEBRTC_REJECT", reason: "max_viewers_reached", toDevice: pcId)
            return
        }

        guard let videoTrack = ds.p2pLocalVideoTrack else {
            print("❌ [P2P] 视频轨未就绪，无法创建会话")
            return
        }

        let cfg = RTCConfiguration()
        cfg.sdpSemantics = .unifiedPlan
        let servers = loadIceServers()
        if !servers.isEmpty {
            cfg.iceServers = servers.map { s in
                if let u = s.username, let c = s.credential {
                    return RTCIceServer(urlStrings: s.urls, username: u, credential: c)
                }
                return RTCIceServer(urlStrings: s.urls)
            }
            let turn = servers.filter { $0.urls.contains(where: { $0.hasPrefix("turn:") }) }.count
            print("🔔 [P2P] ICE 服务器 \(servers.count) 个 (TURN=\(turn))")
        } else {
            cfg.iceServers = [
                RTCIceServer(urlStrings: ["stun:stun.miwifi.com:3478"]),
                RTCIceServer(urlStrings: ["stun:stun.qq.com:3478"]),
                RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
            ]
        }
        cfg.continualGatheringPolicy = .gatherContinually
        cfg.iceBackupCandidatePairPingInterval = 2000
        cfg.iceCandidatePoolSize = 2
        // P0-2：补齐 ICE 稳定性参数
        cfg.iceConnectionReceivingTimeout = 8000          // 8s 无收包才判 disconnected，弱网更耐抖
        cfg.shouldPresumeWritableWhenFullyRelayed = true  // 全 relay 时预判可写，加快建连
        let useRelay = effectiveForceRelay(for: pcId)
        cfg.iceTransportPolicy = useRelay ? .relay : .all
        cfg.bundlePolicy = .maxBundle
        cfg.rtcpMuxPolicy = .require
        print("🔔 [P2P] 创建会话 \(pcId)，传输策略=\(useRelay ? "relay(TURN)" : "all(直连优先)")")

        let cons = RTCMediaConstraints(mandatoryConstraints: nil,
                                       optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
        guard let newPC = ds.p2pFactory.peerConnection(with: cfg, constraints: cons, delegate: self) else {
            print("❌ [P2P] 创建 PeerConnection 失败 \(pcId)")
            return
        }

        let sender = newPC.add(videoTrack, streamIds: ["s0"])
        viewerSessions[pcId] = newPC
        viewerSenders[pcId] = sender
        applyEncoding(to: sender)

        print("✅ [P2P] 会话创建成功 \(pcId)，当前观看 \(viewerSessions.count)/\(maxViewers)")

        let sdpCons = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "false", "OfferToReceiveVideo": "false"],
            optionalConstraints: nil)
        newPC.offer(for: sdpCons) { [weak self, weak newPC] sdp, err in
            guard let self = self, let newPC = newPC, let sdp = sdp else {
                print("❌ [P2P] 创建 Offer 失败 \(pcId): \(err?.localizedDescription ?? "")")
                return
            }
            newPC.setLocalDescription(sdp) { _ in }
            // ⭐ H265：用实际 Offer SDP 校准生效编码——若声称 H265 但 SDP 无 H265（本机不能编码 H265），
            //   如实降级 h264，CONFIG_STATE 随之报 h264，PC 建 H264 管线，画面退化为 H264 而非黑屏。
            if H265Support.shared.isH265Session() {
                let s = sdp.sdp
                let hasH265 = s.range(of: "H265", options: .caseInsensitive) != nil || s.range(of: "HEVC", options: .caseInsensitive) != nil
                let hasH264 = s.range(of: "H264", options: .caseInsensitive) != nil
                let hasBundle = s.range(of: "a=group:BUNDLE", options: .caseInsensitive) != nil
                H265Support.shared.h265Log("[Offer] 发给 \(pcId): 含H265=\(hasH265) 含H264兜底=\(hasH264) 含BUNDLE=\(hasBundle)")
                H265Support.shared.reconcileFromOfferSdp(s)
            }
            WebSocketManager.shared.sendWebRTCSignalingSDP(sdpType: "offer", sdp: sdp.sdp, toDevice: pcId)
            self.lastOfferSentAt[pcId] = Date()   // §53.3①：重复请求判据
            print("📤 [P2P] 已发送 Offer 给 \(pcId)")
        }
    }

    func removeViewerSession(_ pcId: String, notifyPC: Bool) {
        if notifyPC {
            WebSocketManager.shared.sendWebRTCSignalingHangup(reason: "ios_close", toDevice: pcId)
        }
        if let s = viewerSessions[pcId] { s.close() }
        viewerSessions.removeValue(forKey: pcId)
        viewerSenders.removeValue(forKey: pcId)
        pendingRemoteIce.removeValue(forKey: pcId)
        pendingIceRestart.remove(pcId)
        iceRetryCount.removeValue(forKey: pcId)
        forceRelayPeerIds.remove(pcId)
        peerNetworkType.removeValue(forKey: pcId)
        lastOfferSentAt.removeValue(forKey: pcId)   // §53.3①：拆了就别再拿旧时刻当"竞态窗口"
        lastRequestId.removeValue(forKey: pcId)
        print("🔌 [P2P] 移除会话 \(pcId)，剩余 \(viewerSessions.count)")
    }

    func closeAllViewerSessions(notifyPC: Bool) {
        for (pcId, s) in viewerSessions {
            if notifyPC {
                WebSocketManager.shared.sendWebRTCSignaling(type: "WEBRTC_HANGUP", reason: "ios_stop_publish", toDevice: pcId)
            }
            s.close()
        }
        viewerSessions.removeAll()
        viewerSenders.removeAll()
        pendingRemoteIce.removeAll()
        pendingIceRestart.removeAll()
        iceRetryCount.removeAll()
        forceRelayPeerIds.removeAll()
        qualityRelayPeerIds.removeAll()   // §25.7b：整体停止才清 relay 钉住（单会话拆建不清）
        peerNetworkType.removeAll()
        lastOfferSentAt.removeAll()
        lastRequestId.removeAll()
    }

    private func findPcId(for pc: RTCPeerConnection) -> String? {
        for (id, s) in viewerSessions where s === pc { return id }
        return nil
    }

    // MARK: - ICE 重连（P2P/TURN 内部，不回退 SRS）

    private func retryICEConnection(for pcId: String, peerConnection pc: RTCPeerConnection) {
        let cur = iceRetryCount[pcId] ?? 0
        if cur < maxICERetries {
            iceRetryCount[pcId] = cur + 1
            forceRelayPeerIds.insert(pcId)   // 失败后下次重建走 relay
            let cons = RTCMediaConstraints(
                mandatoryConstraints: ["IceRestart": "true",
                                       "OfferToReceiveAudio": "false",
                                       "OfferToReceiveVideo": "false"],
                optionalConstraints: nil)
            pendingIceRestart.insert(pcId)
            pc.offer(for: cons) { [weak self, weak pc] sdp, _ in
                guard let self = self, let pc = pc, let sdp = sdp else { return }
                pc.setLocalDescription(sdp) { _ in }
                WebSocketManager.shared.sendWebRTCSignalingSDP(sdpType: "offer", sdp: sdp.sdp, toDevice: pcId)
                print("🔄 [P2P] ICE Restart Offer 已发送 \(pcId) (\(cur + 1)/\(self.maxICERetries))")
            }
        } else {
            print("❌ [P2P] \(pcId) ICE 重试耗尽，断开 → 回落 SRS")
            iceRetryCount.removeValue(forKey: pcId)
            removeViewerSession(pcId, notifyPC: false)
            WebSocketManager.shared.sendWebRTCSignaling(type: "WEBRTC_HANGUP", reason: "ice_failed", toDevice: pcId)
            onViewerPermanentlyFailed?(pcId)
        }
    }

    // MARK: - 链路择优（§25.7：直连质量差 → 主动切中继）

    /// 直连路径质量持续差（由 WebRTCManager stats 判定）时，把所有会话切到 TURN 中继。
    /// 两级策略（§25.7b，2026-07-03 实测日志定型）：
    /// - **第一次触发 = 软切**：setConfiguration(.relay) + ICE Restart（不整拆会话，旧路径出画面
    ///   直到新路径 nominated）。Chromium 内核（网页内核）走这条即可完成切换。
    /// - **第二次触发（10s 后路径仍是直连）= 硬切**：实测 GStreamer webrtcbin 收到新 ufrag 的
    ///   Offer 不重启 libnice、不重新收集候选（回了 Answer 但零新增 [本地候选]），软切必然失效。
    ///   升级为：pcId 钉进 qualityRelayPeerIds（跨会话存活）→ 拆会话 → 发
    ///   WEBRTC_HANGUP(network_switch_reconnect)（PC 已有处理：不拆 pipeline，自动重发
    ///   WEBRTC_REQUEST）→ 重建的会话 effectiveForceRelay=true，从建会话起就只走 TURN。
    ///   网页内核第一次软切就生效、到不了第二次，不受硬切 HANGUP（网页内核收 HANGUP 停播不重连）影响。
    func switchAllSessionsToRelay(reason: String) {
        // 无 TURN 服务器时强制 relay = 零候选必死，直接放弃
        let hasTurn = loadIceServers().contains { s in
            s.urls.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
        }
        guard hasTurn else {
            print("⚠️ [P2P] 切中继请求被忽略（无 TURN 服务器配置）reason=\(reason)")
            return
        }
        for (pcId, pc) in viewerSessions {
            if forceRelayPeerIds.contains(pcId) {
                // 已软切过仍被再次触发 = 路径还是直连，对端不支持 ICE Restart（GStreamer）→ 硬切
                guard !qualityRelayPeerIds.contains(pcId) else { continue }   // 硬切也做过 = 等重建，别重复拆
                qualityRelayPeerIds.insert(pcId)
                print("🔨 [P2P] 软切中继未生效(路径仍直连，对端不支持 ICE Restart) → 硬切重建 \(pcId) reason=\(reason)")
                removeViewerSession(pcId, notifyPC: false)
                WebSocketManager.shared.sendWebRTCSignaling(type: "WEBRTC_HANGUP",
                                                            reason: "network_switch_reconnect",
                                                            toDevice: pcId)
                continue
            }
            forceRelayPeerIds.insert(pcId)
            let cfg = pc.configuration
            cfg.iceTransportPolicy = .relay
            pc.setConfiguration(cfg)
            let cons = RTCMediaConstraints(
                mandatoryConstraints: ["IceRestart": "true",
                                       "OfferToReceiveAudio": "false",
                                       "OfferToReceiveVideo": "false"],
                optionalConstraints: nil)
            pendingIceRestart.insert(pcId)
            pc.offer(for: cons) { [weak pc] sdp, err in
                guard let pc = pc, let sdp = sdp else {
                    print("❌ [P2P] 切中继 Offer 创建失败 \(pcId): \(err?.localizedDescription ?? "")")
                    return
                }
                pc.setLocalDescription(sdp) { _ in }
                WebSocketManager.shared.sendWebRTCSignalingSDP(sdpType: "offer", sdp: sdp.sdp, toDevice: pcId)
                print("🔀 [P2P] 已切中继并发送 ICE Restart Offer → \(pcId) reason=\(reason)")
            }
        }
    }

    // MARK: - 编码参数（PC 调参时由 WebRTCManager 调用，统一作用到所有会话）
    //
    // ⭐ 2026-06-25 改法A：码率与帧率解耦（对齐 SRS「码率和 FPS 完全解耦」设计）。
    //   旧实现 applyEncoding 把码率+帧率+分辨率一次性全写，导致「调码率会顺带重写 maxFramerate」，
    //   而上层自适应降帧（applyAdaptiveFps）在 P2P 模式下又没把 fps 落到会话编码器 →
    //   一拉码率百分比，节流器当前 fps 才被刷进编码器，观感就是「调码率把 fps 也改了」。
    //   现拆为两路：
    //     · applyBitrateToAllSessions  —— 只写 min/max 码率（含分辨率锁定与优先级），不碰 maxFramerate
    //     · applyFramerateToAllSessions —— 只写 maxFramerate
    //   会话创建时两者都调一次（保证初值），之后码率/帧率各自独立同步，互不牵连。

    /// 仅同步「码率」到所有直连会话（不改 maxFramerate）。
    func applyBitrateToAllSessions() {
        for (_, sender) in viewerSenders { applyBitrate(to: sender) }
    }

    /// 仅同步「帧率」到所有直连会话（不改码率）。
    func applyFramerateToAllSessions() {
        for (_, sender) in viewerSenders { applyFramerate(to: sender) }
    }

    /// 兼容旧调用点：同时同步码率 + 帧率（仅用于会话创建初始化）。
    func applyEncodingToAllSessions() {
        for (_, sender) in viewerSenders { applyEncoding(to: sender) }
    }

    /// 🔥 2026-07-02: P2P 本地强制关键帧（作用于所有直连会话）。
    /// 背景：WebRTCManager.forceKeyframe 只写 videoSender（SRS 专用），P2P 模式恒为 nil →
    ///   PLI 响应 / PC request_keyframe / 切档 IDR 在 P2P 路径全部空操作，弱网花屏只能干等。
    /// 实现：与 forceKeyframeViaBitrate 相同的码率微调 trick（iOS SDK 未暴露 GenerateKeyFrame），
    ///   +1kbps 触发编码器重配出 IDR，20ms 后原样恢复（含 nil，不篡改码率配置）。
    func forceKeyframeAllSessions() {
        guard !viewerSenders.isEmpty else { return }
        for (pcId, sender) in viewerSenders {
            var params = sender.parameters
            guard !params.encodings.isEmpty else { continue }
            let originalMax = params.encodings[0].maxBitrateBps
            let base = originalMax?.intValue ?? 3_000_000
            params.encodings[0].maxBitrateBps = NSNumber(value: base + 1000)
            sender.parameters = params
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self = self, let s = self.viewerSenders[pcId] else { return }
                var p2 = s.parameters
                if !p2.encodings.isEmpty {
                    p2.encodings[0].maxBitrateBps = originalMax
                    s.parameters = p2
                }
            }
        }
        print("🔑 [P2P] forceKeyframe → \(viewerSenders.count) 个直连会话")
    }

    /// 🔥 2026-07-02: P2P 周期码率纠偏（对标 SRS 的 startBitrateEnforcement）。
    /// 仅当编码器内的码率区间被 WebRTC 内部改动（drift）时才回写，避免每 3s 无谓 reconfigure。
    func enforceBitrateIfDrifted() {
        guard let ds = dataSource, !viewerSenders.isEmpty else { return }
        let range = ds.p2pBitrateRangeKbps()
        for (pcId, sender) in viewerSenders {
            let params = sender.parameters
            guard !params.encodings.isEmpty else { continue }
            let curMin = params.encodings[0].minBitrateBps?.intValue ?? 0
            let curMax = params.encodings[0].maxBitrateBps?.intValue ?? 0
            if curMin != range.min * 1000 || curMax != range.max * 1000 {
                applyBitrate(to: sender)
                print("🔒 [P2P] 周期纠偏 \(pcId): \(curMin/1000)-\(curMax/1000) → \(range.min)-\(range.max) kbps")
            }
        }
    }

    private func applyBitrate(to sender: RTCRtpSender?) {
        guard let sender = sender, let ds = dataSource else { return }
        var params = sender.parameters
        if params.encodings.isEmpty { params.encodings = [RTCRtpEncodingParameters()] }
        let range = ds.p2pBitrateRangeKbps()
        params.encodings[0].minBitrateBps = NSNumber(value: range.min * 1000)
        params.encodings[0].maxBitrateBps = NSNumber(value: range.max * 1000)
        params.encodings[0].scaleResolutionDownBy = NSNumber(value: ds.p2pScaleDown())
        params.encodings[0].networkPriority = .high
        params.encodings[0].isActive = true
        // ⭐ 2026-06-24 修复「P2P 弱网分辨率乱串」根因：
        //   原值 1=maintainFramerate → WebRTC 拥塞时为保帧率自动缩分辨率（与产品设计相反）。
        //   产品设计是弱网「先降 fps → 再降码率，分辨率不动」，由上层 processAdaptiveFps 控制。
        //   SRS 路径全程用 2=maintainResolution（所以 SRS 不乱串），P2P 这里漏成了 1 → 唯独 P2P 乱串。
        //   改为 2=maintainResolution，把分辨率锁死，弱网时只降帧/降码率，分辨率始终=档位预设。
        // RTCDegradationPreference: 0=disabled, 1=maintainFramerate, 2=maintainResolution, 3=balanced
        params.degradationPreference = NSNumber(value: 2)   // maintainResolution（与 SRS 路径一致）
        sender.parameters = params
    }

    private func applyFramerate(to sender: RTCRtpSender?) {
        guard let sender = sender, let ds = dataSource else { return }
        var params = sender.parameters
        if params.encodings.isEmpty { params.encodings = [RTCRtpEncodingParameters()] }
        params.encodings[0].maxFramerate = NSNumber(value: ds.p2pTargetFps())
        sender.parameters = params
    }

    /// 会话创建时初始化整组参数（码率 + 帧率），后续走拆分后的独立方法。
    private func applyEncoding(to sender: RTCRtpSender?) {
        applyBitrate(to: sender)
        applyFramerate(to: sender)
    }
}

// MARK: - RTCPeerConnectionDelegate（多会话）
extension P2PManager: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard let pcId = findPcId(for: peerConnection) else { return }
        WebSocketManager.shared.sendWebRTCSignalingICE(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid ?? "0",
            sdpMLineIndex: candidate.sdpMLineIndex,
            toDevice: pcId)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let pcId = self.findPcId(for: peerConnection) else { return }
            switch newState {
            case .connected, .completed:
                self.iceRetryCount.removeValue(forKey: pcId)
                print("✅ [P2P] \(pcId) ICE 已连接")
            case .failed:
                print("❌ [P2P] \(pcId) ICE 失败，重连")
                self.retryICEConnection(for: pcId, peerConnection: peerConnection)
            case .disconnected:
                print("⚠️ [P2P] \(pcId) ICE 断开，15s 后检查")
                DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
                    guard let self = self, let s = self.viewerSessions[pcId] else { return }
                    if s.iceConnectionState == .disconnected || s.iceConnectionState == .failed {
                        self.retryICEConnection(for: pcId, peerConnection: s)
                    }
                }
            default:
                break
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {}
}
