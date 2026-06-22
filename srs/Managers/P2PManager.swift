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
    private var viewerSenders: [String: RTCRtpSender] = [:]
    private var pendingRemoteIce: [String: [RTCIceCandidate]] = [:]
    private var pendingIceRestart: Set<String> = []
    private var iceRetryCount: [String: Int] = [:]
    private let maxICERetries = 2
    private var forceRelayPeerIds: Set<String> = []     // ICE 失败黑名单 → 重建时强制 relay
    private var peerNetworkType: [String: String] = [:] // pcDeviceId → "cellular"/"wifi"/...

    private var signalingObserver: NSObjectProtocol?
    private var reconnectObserver: NSObjectProtocol?

    // 本机网络监听（蜂窝强制 relay + 切网重连）
    private var isOnCellular = false
    private let nwMonitor = NWPathMonitor()
    private let nwQueue = DispatchQueue(label: "p2p.nwpath", qos: .utility)
    private var nwStarted = false

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
            if newCellular != self.isOnCellular {
                self.isOnCellular = newCellular
                print("📶 [P2P] 网络类型变化: \(newCellular ? "蜂窝" : "WiFi/有线")")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // 先让上层重新评估（蜂窝→可能整体切 SRS）
                    self.onLocalNetworkChange?()
                    // 仍在 P2P 的会话做 ICE Restart
                    self.restartAllIceForNetworkSwitch()
                }
            }
        }
        nwMonitor.start(queue: nwQueue)
    }

    /// 网络切换：重新评估每个会话的传输策略（蜂窝→relay）并重连
    private func restartAllIceForNetworkSwitch() {
        let sessions = viewerSessions
        if sessions.isEmpty { return }
        print("📶 [P2P] 网络切换，处理 \(sessions.count) 个会话")
        for (pcId, pc) in sessions {
            let state = pc.connectionState
            if state == .closed || state == .failed {
                // 无法 ICE Restart：拆掉并让 PC 重新发起（重建时按新网络选 relay/all）
                removeViewerSession(pcId, notifyPC: false)
                WebSocketManager.shared.sendWebRTCSignaling(type: "WEBRTC_HANGUP",
                                                            reason: "network_switch_reconnect",
                                                            toDevice: pcId)
            } else {
                // 切到蜂窝且当前不是 relay 黑名单 → 加入黑名单，下次重建走 relay；本次先 ICE Restart
                if isOnCellular { forceRelayPeerIds.insert(pcId) }
                retryICEConnection(for: pcId, peerConnection: pc)
            }
        }
    }

    // MARK: - 传输策略

    private func effectiveForceRelay(for pcId: String) -> Bool {
        if forceRelay { return true }
        return isOnCellular || peerNetworkType[pcId] == "cellular" || forceRelayPeerIds.contains(pcId)
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
            print("🔌 [P2P] PC \(fromDevice) 断开")
        case "WEBRTC_REQUEST":
            peerNetworkType[fromDevice] = (message["networkType"] as? String) ?? "unknown"
            guard isReadyForViewers else {
                WebSocketManager.shared.sendWebRTCSignaling(type: "WEBRTC_REJECT", reason: "not_ready", toDevice: fromDevice)
                return
            }
            createViewerSession(for: fromDevice)
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

    func createViewerSession(for pcId: String) {
        guard let ds = dataSource else { print("❌ [P2P] dataSource 为空"); return }

        if let existing = viewerSessions[pcId] {
            let s = existing.connectionState
            if s == .new || s == .connecting {
                print("⚠️ [P2P] PC \(pcId) 会话建立中，忽略重复请求")
                return
            }
            removeViewerSession(pcId, notifyPC: false)
        }

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
            WebSocketManager.shared.sendWebRTCSignalingSDP(sdpType: "offer", sdp: sdp.sdp, toDevice: pcId)
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
        peerNetworkType.removeAll()
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

    // MARK: - 编码参数（PC 调参时由 WebRTCManager 调用，统一作用到所有会话）

    func applyEncodingToAllSessions() {
        for (_, sender) in viewerSenders { applyEncoding(to: sender) }
    }

    private func applyEncoding(to sender: RTCRtpSender?) {
        guard let sender = sender, let ds = dataSource else { return }
        var params = sender.parameters
        if params.encodings.isEmpty { params.encodings = [RTCRtpEncodingParameters()] }
        let range = ds.p2pBitrateRangeKbps()
        params.encodings[0].minBitrateBps = NSNumber(value: range.min * 1000)
        params.encodings[0].maxBitrateBps = NSNumber(value: range.max * 1000)
        params.encodings[0].maxFramerate = NSNumber(value: ds.p2pTargetFps())
        params.encodings[0].scaleResolutionDownBy = NSNumber(value: ds.p2pScaleDown())
        params.encodings[0].networkPriority = .high
        params.encodings[0].isActive = true
        params.degradationPreference = NSNumber(value: 1)   // maintainFramerate
        sender.parameters = params
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
