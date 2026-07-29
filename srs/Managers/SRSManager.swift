//
//  SRSManager.swift
//  金凤凰
//
//  独立的 SRS 推流连接管理类（与 P2PManager 对称）。
//  - 仅负责 SRS 连接建立（创建 PeerConnection、Offer→/rtc/v1/publish→Answer、Token、deleteStream）
//    与 ICE 重连。
//  - 采集管线（capturer/frameThrottler/localVideoTrack）、统计、码率强制、关键帧、自适应
//    仍由 WebRTCManager 管理，作用于本类回填的「活动连接」。
//  - 与 P2PManager 互斥：connect_mode == "srs" 时启用。
//

import Foundation
import WebRTC

// MARK: - 数据源：由 WebRTCManager 提供工厂/视频轨/SRS 参数 + 回调
protocol SRSManagerDataSource: AnyObject {
    var srsFactory: RTCPeerConnectionFactory { get }
    var srsLocalVideoTrack: RTCVideoTrack? { get }
    var srsIP: String { get }
    var srsApp: String { get }
    var srsStreamKey: String { get }
    var srsUsername: String { get }
    var srsIsPublishing: Bool { get }
    /// 连接成功：回填活动 pc/sender，由 WebRTCManager 启动统计/码率强制等共享逻辑
    func srsDidConnect(pc: RTCPeerConnection, sender: RTCRtpSender?)
    /// 连接失败
    func srsDidFail(reason: String)
}

final class SRSManager: NSObject {

    weak var dataSource: SRSManagerDataSource?

    private(set) var pc: RTCPeerConnection?
    private(set) var videoSender: RTCRtpSender?
    private(set) var isActive = false

    private var streamToken = ""
    private var iceReconnectTimer: Timer?
    private var iceRestartAttempts = 0
    private let maxIceRestartAttempts = 3

    // MARK: - 生命周期

    func start() {
        isActive = true
        establish(isRestart: false)
    }

    func stop() {
        isActive = false
        iceReconnectTimer?.invalidate(); iceReconnectTimer = nil
        iceRestartAttempts = 0
        let key = dataSource?.srsStreamKey ?? ""
        pc?.close()
        pc = nil
        videoSender = nil
        if !key.isEmpty { deleteStream(streamKey: key) }
    }

    // MARK: - 连接建立

    private func establish(isRestart: Bool) {
        guard let ds = dataSource else { return }
        guard let videoTrack = ds.srsLocalVideoTrack else {
            ds.srsDidFail(reason: "本地视频轨未就绪")
            return
        }

        // 清理旧连接
        pc?.close(); pc = nil

        let cfg = RTCConfiguration()
        cfg.sdpSemantics = .unifiedPlan
        cfg.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.miwifi.com:3478"]),
            RTCIceServer(urlStrings: ["stun:stun.qq.com:3478"]),
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
        ]
        cfg.continualGatheringPolicy = .gatherContinually
        cfg.iceBackupCandidatePairPingInterval = 2000
        cfg.iceCandidatePoolSize = 2
        cfg.iceTransportPolicy = .all
        cfg.bundlePolicy = .maxBundle
        cfg.rtcpMuxPolicy = .require

        let cons = RTCMediaConstraints(mandatoryConstraints: nil,
                                       optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
        guard let newPC = ds.srsFactory.peerConnection(with: cfg, constraints: cons, delegate: self) else {
            ds.srsDidFail(reason: "创建 PeerConnection 失败")
            return
        }
        pc = newPC
        videoSender = newPC.add(videoTrack, streamIds: ["s0"])

        let sdpCons = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "false", "OfferToReceiveVideo": "false"],
            optionalConstraints: nil)

        newPC.offer(for: sdpCons) { [weak self] sdp, err in
            guard let self = self, let sdp = sdp else {
                self?.dataSource?.srsDidFail(reason: "生成 Offer 失败: \(err?.localizedDescription ?? "")")
                return
            }
            guard let pc = self.pc else { return }
            pc.setLocalDescription(sdp) { _ in }
            Task {
                do {
                    let ans = try await self.postOfferToSRS(
                        apiPath: "/rtc/v1/publish/",
                        streamurl: "webrtc://\(ds.srsIP)/\(ds.srsApp)/\(ds.srsStreamKey)",
                        offer: sdp.sdp)
                    guard let pc = self.pc else { return }
                    pc.setRemoteDescription(.init(type: .answer, sdp: ans)) { [weak self] err in
                        guard let self = self else { return }
                        DispatchQueue.main.async {
                            if let err = err {
                                self.dataSource?.srsDidFail(reason: "设置 Answer 失败: \(err.localizedDescription)")
                            } else {
                                self.iceRestartAttempts = 0
                                print("🟢 [SRS] 推流连接成功")
                                self.dataSource?.srsDidConnect(pc: pc, sender: self.videoSender)
                            }
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.dataSource?.srsDidFail(reason: "SRS 服务器错误: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - ICE 重连（分级：ICE Restart → 全重建）

    private func scheduleIceReconnect(delay: TimeInterval, reason: String) {
        iceReconnectTimer?.invalidate()
        print("⏳ [SRS] \(reason)，\(delay)秒后检查重连")
        iceReconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self, self.dataSource?.srsIsPublishing == true else { return }
            let state = self.pc?.iceConnectionState
            if state == .disconnected || state == .failed || state == .closed {
                if self.iceRestartAttempts < self.maxIceRestartAttempts {
                    self.iceRestartAttempts += 1
                    print("🔄 [SRS] ICE Restart (\(self.iceRestartAttempts)/\(self.maxIceRestartAttempts))")
                    self.triggerICERestart()
                    self.scheduleIceReconnect(delay: 5.0, reason: "ICE Restart 后等待恢复")
                } else {
                    print("🔄 [SRS] ICE Restart 耗尽，全重建")
                    self.iceRestartAttempts = 0
                    self.establish(isRestart: true)
                }
            } else {
                self.iceRestartAttempts = 0
            }
        }
    }

    private func triggerICERestart() {
        guard let ds = dataSource, let pc = self.pc else { return }
        let cons = RTCMediaConstraints(
            mandatoryConstraints: ["IceRestart": kRTCMediaConstraintsValueTrue],
            optionalConstraints: nil)
        pc.offer(for: cons) { [weak self] sdp, _ in
            guard let self = self, let sdp = sdp, let pc = self.pc else { return }
            pc.setLocalDescription(sdp) { _ in }
            Task {
                do {
                    let ans = try await self.postOfferToSRS(
                        apiPath: "/rtc/v1/publish/",
                        streamurl: "webrtc://\(ds.srsIP)/\(ds.srsApp)/\(ds.srsStreamKey)",
                        offer: sdp.sdp)
                    guard let pc = self.pc else { return }
                    pc.setRemoteDescription(.init(type: .answer, sdp: ans)) { _ in }
                } catch {
                    print("❌ [SRS] ICE Restart 失败: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - SRS HTTP

    private func postOfferToSRS(apiPath: String, streamurl: String, offer: String) async throws -> String {
        guard let ds = dataSource else {
            throw NSError(domain: "srs", code: -1, userInfo: [NSLocalizedDescriptionKey: "dataSource 为空"])
        }
        let srsIP = ds.srsIP
        guard !srsIP.isEmpty else {
            throw NSError(domain: "srs", code: -1, userInfo: [NSLocalizedDescriptionKey: "推流IP为空，请重新登录"])
        }
        let username = ds.srsUsername
        var finalStreamUrl = streamurl
        do {
            let tokenResponse = try await APIService.shared.getStreamToken(username: username, streamName: ds.srsStreamKey)
            streamToken = tokenResponse.token
            finalStreamUrl = "\(streamurl)?token=\(tokenResponse.token)&username=\(username)"
        } catch {
            print("⚠️ [SRS] 获取推流Token失败: \(error.localizedDescription)，使用无Token推流")
        }
        // ⭐ H265（第四十九章）：SRS 6.0 的 RTC H265 协商由 API 请求参数 codec=hevc 开启
        //   （srs_app_rtc_api.cpp: r->query_get("codec")；不带则走 H264 分支，H265 Offer 会被 400 拒）
        let path = H265Support.shared.isH265Session() ? "\(apiPath)?codec=hevc" : apiPath
        let url = URL(string: "http://\(srsIP):1985\(path)")!
        let body: [String: Any] = [
            "api": "http://\(srsIP):1985\(path)",
            "streamurl": finalStreamUrl,
            "sdp": offer
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if let code = json["code"] as? Int, code != 0 {
            let msg = json["msg"] as? String ?? "未知错误"
            throw NSError(domain: "srs", code: code, userInfo: [NSLocalizedDescriptionKey: "SRS code=\(code), msg: \(msg)"])
        }
        guard let sdp = json["sdp"] as? String else {
            throw NSError(domain: "srs", code: -1, userInfo: [NSLocalizedDescriptionKey: "no sdp in response"])
        }
        return sdp
    }

    func deleteStream(streamKey: String) {
        guard let ds = dataSource else { return }
        guard let url = URL(string: "http://\(ds.srsIP):1985/rtc/v1/unpublish/") else { return }
        let body: [String: Any] = [
            "api": "http://\(ds.srsIP):1985/rtc/v1/unpublish/",
            "streamurl": "webrtc://\(ds.srsIP)/\(ds.srsApp)/\(streamKey)"
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { _, response, error in
            if let error = error {
                print("🗑️ [SRS] deleteStream 失败(忽略): \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse {
                print("🗑️ [SRS] deleteStream: HTTP \(http.statusCode)")
            }
        }.resume()
    }
}

// MARK: - RTCPeerConnectionDelegate
extension SRSManager: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, peerConnection === self.pc else { return }
            // ⭐ §53.14：**每次状态迁移都记一行**。原先只在 connected 打一行，
            //   「首连不出画面」时日志里什么都没有，看不出是卡在 checking 还是压根没起来。
            let name: String
            switch newState {
            case .new: name = "new"
            case .checking: name = "checking"
            case .connected: name = "connected"
            case .completed: name = "completed"
            case .failed: name = "failed"
            case .disconnected: name = "disconnected"
            case .closed: name = "closed"
            case .count: name = "count"
            @unknown default: name = "unknown"
            }
            print("🧊 [SRS] ICE 状态 → \(name)")
            switch newState {
            case .connected, .completed:
                print("✅ [SRS] ICE 已连接")
            case .failed:
                if self.dataSource?.srsIsPublishing == true {
                    self.scheduleIceReconnect(delay: 2.0, reason: "ICE failed")
                }
            case .disconnected:
                if self.dataSource?.srsIsPublishing == true {
                    self.scheduleIceReconnect(delay: 8.0, reason: "ICE disconnected")
                }
            default:
                break
            }
        }
    }
}
