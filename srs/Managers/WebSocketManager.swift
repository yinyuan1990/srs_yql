import Foundation
import SwiftStomp
// ... existing code ...
import UIKit
import Network
import CoreTelephony


class WebSocketManager: ObservableObject {
    
    static var isPublishingFlag: Int = 0
    static var publishingKbps: Int = 0
    static var publishingFps: Int = 0
    static var publishingSendFps: Int = 0  // WebRTC实际推送FPS
    // ⭐ 2026-07-14：低功率采集回报（WebRTCManager 每次改动时同步写入）——
    //   之前 PC 点开关是纯下发、iOS 不回报，PC 端完全看不到有没有生效/当前实际采集多少fps。
    static var publishingCaptureFps: Int = 0        // 当前实际采集fps（已套用低功率钳制后的值）
    static var publishingLowPowerCapture: Bool = false  // 当前是否处于低功率采集模式
    static var publishingStreamKey: String = ""  // 当前推流使用的唯一streamKey
    static var networkQuality: String = "unknown"  // 网络质量: excellent/good/fair/poor/unknown
    /// ⭐ §53.4.5：本次会话链路/编码的决策原因（人话），随 CONFIG_STATE 上报给 PC 顶栏显示
    static var connectReason: String = ""
    static var packetLoss: Double = 0.0  // 丢包率 0.0~1.0
    static var rtt: Int = 0  // RTT往返时延(ms)
    // 设备状态推送
    private var statusTimer: Timer?
    private let statusInterval: TimeInterval = 1.0  // ✅ 改为1秒推送一次
    private var isPublishingCache: Int = 0
    private var networkMonitor: NWPathMonitor?
    private var currentNetworkType: String = "Unknown"
    /// iOS 本机当前是否 WiFi（供 P2P/SRS 自动协商判断）
    var isOnWiFi: Bool { currentNetworkType == "WiFi" }
    
    // 单例
    static let shared = WebSocketManager()
    @Published var isConnected = false
    @Published var connectionStatus = "未连接"
    
    private var swiftStomp: SwiftStomp?
    private var deviceId: String?
    
    // 心跳
    private var heartbeatTimer: Timer?
    private let heartbeatInterval: TimeInterval = 5.0
    
    // —— 新增：连接自检与一次性重连控制 —— //
    private var monitorTimer: Timer?
    private let monitorInterval: TimeInterval = 5.0
    private var isReconnectingOnce = false   // 防止同一轮多次尝试
    
    // 若有外部调用的“额外重连定时器”，保留
    private var reconnectTimer: Timer?
    
    private init() {}
    
    // 启动设备状态定时推送
    private func startStatusPush() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: statusInterval, repeats: true) { [weak self] _ in
            self?.sendDeviceStatus()
        }
    }
    
    
    // 订阅推流状态变化（1/0）
    private func setupPublishingStatusObserver() {
       
    }
    
    // 网络监控：WiFi/Cellular + 5G/4G判定
    private func startNetworkMonitor() {
        networkMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            if path.usesInterfaceType(.wifi) {
                self.currentNetworkType = "WiFi"
            } else if path.usesInterfaceType(.cellular) {
                self.currentNetworkType = self.currentRadioType()
            } else {
                self.currentNetworkType = "Unknown"
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .background))
        networkMonitor = monitor
    }
    
    

    
    private func currentRadioType() -> String {
            let info = CTTelephonyNetworkInfo()
            let techs: [String]
            if let dict = info.serviceCurrentRadioAccessTechnology { // iOS 12+ 双卡
                techs = Array(dict.values)
            } else if let single = info.currentRadioAccessTechnology { // 旧设备/单卡
                techs = [single]
            } else {
                techs = []
            }
            if techs.contains(CTRadioAccessTechnologyNR) || techs.contains(CTRadioAccessTechnologyNRNSA) { return "5g" }
            if techs.contains(CTRadioAccessTechnologyLTE) { return "4g" }
            return "其它"
    }
    
    private func deviceModelIdentifier() -> String {
            var sysinfo = utsname()
            uname(&sysinfo)
            let mirror = Mirror(reflecting: sysinfo.machine)
            let identifier = mirror.children.reduce("") { id, elem in
                let v = elem.value as? Int8 ?? 0
                return v == 0 ? id : id + String(UnicodeScalar(UInt8(v)))
            }
            return identifier
    }
    
    private func batteryPercentage() -> Int {
           UIDevice.current.isBatteryMonitoringEnabled = true
           let level = UIDevice.current.batteryLevel
           if level < 0 { return -1 }
           return max(0, min(100, Int(level * 100)))
    }
    
    private func sendDeviceStatus() {
        
        guard let deviceId = deviceId else { return }
        let destination = "/topic/device/\(deviceId)/config"
        let osVer = UIDevice.current.systemVersion
        let model = deviceModelIdentifier()
        let battery = batteryPercentage()
        let network = currentNetworkType
        let publish = WebSocketManager.isPublishingFlag
        let kbps = WebSocketManager.publishingKbps
        let fps = WebSocketManager.publishingFps
        let sendFps = WebSocketManager.publishingSendFps
        let quality = WebSocketManager.networkQuality
        let loss = WebSocketManager.packetLoss
        let rtt = WebSocketManager.rtt
        let isoFormatter = ISO8601DateFormatter()
        let ts = isoFormatter.string(from: Date())
        let streamKey = WebSocketManager.publishingStreamKey
        let streamPushIp = UserDefaults.standard.string(forKey: "stream_push_ip") ?? ""  // 🔥 推流IP
        // ⭐ 连接方式由 WebRTCManager 实时决策（0=SRS,1=P2P,2=SRT），供 PC 跟随
        // 方案 A 下 SRT 经 SRS 桥接成 WebRTC，PC 仍按 WebRTC 拉，故 connectMode 仍上报 "srs"（不影响 PC 现有逻辑）。
        let connectstype = WebRTCManager.effectiveConnectstype
        let connectMode: String
        switch connectstype {
        case 1:  connectMode = "p2p"
        case 2:  connectMode = "srt"   // 方案 B：PC 直接拉 SRT（connectstype=2 → PC playSRT）
        default: connectMode = "srs"
        }
        let p2pViewerCount = P2PManager.currentViewerCount
        
        // 🔥 从 UserDefaults 读取试用/激活信息
        let trialRequired = UserDefaults.standard.bool(forKey: "trial_required")
        let activated = UserDefaults.standard.bool(forKey: "activated")
        let activationLevel = UserDefaults.standard.integer(forKey: "activation_level")
        let activationLevelName = UserDefaults.standard.string(forKey: "activation_level_name") ?? ""
        let activationExpireAt = UserDefaults.standard.string(forKey: "activation_expire_at") ?? ""
        let qualityAccess = UserDefaults.standard.stringArray(forKey: "quality_access") ?? []
        let trialEnded = UserDefaults.standard.bool(forKey: "trial_ended")
        let currentStage = UserDefaults.standard.integer(forKey: "current_stage")
        let totalStages = UserDefaults.standard.integer(forKey: "total_stages")
        let stageSeconds = UserDefaults.standard.integer(forKey: "stage_seconds")
        let remainingSeconds = UserDefaults.standard.integer(forKey: "remaining_seconds")
        let usedSeconds = UserDefaults.standard.integer(forKey: "used_seconds")
        // 🔥 日试用相关（新增）
        let isDailyTrial = UserDefaults.standard.bool(forKey: "is_daily_trial")
        let activationRemainingSeconds = UserDefaults.standard.integer(forKey: "activation_remaining_seconds")
        
        let state: [String: Any] = [
            "networkType": network,
            "publishStatus": publish,
            "streamKey": streamKey,
            "streamPushIp": streamPushIp,  // 🔥 推流IP地址
            // ⭐ 自动协商：连接方式 + P2P 状态，PC 跟随 connectstype 切换
            "connectstype": connectstype,
            "connectMode": connectMode,
            // ⭐ H265：P2P 实际生效编码（"h264"/"h265"），PC 据此选择 H264/H265 解码管线
            "videoCodec": H265Support.shared.effectiveCodecString,
            // ⭐ §53.4.5「互相监督」：本次链路/编码是**怎么定下来的**（人话），PC 顶栏直接显示。
            //   有了它，现场看到"走的多人线路"或"降了 H264"时不用再猜是谁决定的、为什么。
            "connectReason": WebSocketManager.connectReason,
            "p2pViewerCount": p2pViewerCount,
            "kbps": kbps,
            "fps": fps,
            "sendFps": sendFps,  // WebRTC实际推送FPS
            // ⭐ 低功率采集回报：PC 相机设定面板据此显示"是否已生效 + 当前实际采集fps"
            "captureFps": WebSocketManager.publishingCaptureFps,
            "lowPowerCapture": WebSocketManager.publishingLowPowerCapture,
            "networkQuality": quality,  // 网络质量等级
            "packetLoss": loss,  // 丢包率
            "rtt": rtt,  // RTT时延(ms)
            "deviceType": [
                "os": "iOS \(osVer)",
                "model": model
            ],
            "battery": battery,
            // 🔥 试用/激活信息
            "trialRequired": trialRequired,
            "activated": activated,
            "activationLevel": activationLevel,
            "activationLevelName": activationLevelName,
            "activationExpireAt": activationExpireAt,
            "qualityAccess": qualityAccess,
            "trialEnded": trialEnded,
            "currentStage": currentStage,
            "totalStages": totalStages,
            "stageSeconds": stageSeconds,
            "remainingSeconds": remainingSeconds,
            "usedSeconds": usedSeconds,
            // 🔥 日试用相关（新增）
            "isDailyTrial": isDailyTrial,
            "activationRemainingSeconds": activationRemainingSeconds
        ]
        let payloadDict: [String: Any] = [
            "type": "CONFIG_STATE",
            "deviceId": deviceId,
            "state": state,
            "timestamp": ts
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payloadDict, options: []),
           let payload = String(data: data, encoding: .utf8) {
            swiftStomp?.send(body: payload, to: destination)
            // print("📤 [心跳] publishStatus=\(publish)")
        } else {
            print("❌ [设备状态] 发送失败: JSON序列化错误")
        }
    }
    
    
    private func stopStatusPush() {
           statusTimer?.invalidate()
           statusTimer = nil
    }
    
    // MARK: - 🔥 自适应FPS发送（通知PC端当前推流FPS）
    /// 发送 FPS 变更消息到服务器，PC端会根据这个调整缓存策略
    /// - Parameter fps: 当前实际推流FPS (5-60)
    func sendFpsUpdate(fps: Int) {
        guard let deviceId = deviceId else {
            print("❌ [自适应FPS] 发送失败: deviceId为空")
            return
        }
        
        let destination = "/topic/device/\(deviceId)/config"
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        
        // 获取操作者用户名
        let operatorName = AccountStorageManager.shared.loadAccountInfo()?.collectorAccount ?? "unknown"
        
        // 🔥🔥 发送给后端的FPS需要×4（后端用采集FPS，我们用推送FPS）
        // 推送FPS 15 → 后端FPS 60
        // 推送FPS 30 → 后端FPS 120
        let backendFps = fps * 4
        
        let config: [String: Any] = [
            "fps": backendFps,
            "device_id": deviceId,
            "ptype": "fps"
        ]
        
        let payloadDict: [String: Any] = [
            "type": "CONFIG_UPDATE",
            "deviceId": deviceId,
            "config": config,
            "operator": operatorName,
            "timestamp": ts
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: payloadDict, options: []),
           let payload = String(data: data, encoding: .utf8) {
            swiftStomp?.send(body: payload, to: destination)
            print("📤 [iOS推送FPS] 推送\(fps)fps → 后端\(backendFps)fps, deviceId=\(deviceId)")
        } else {
            print("❌ [iOS推送FPS] 发送失败: JSON序列化错误")
        }
    }
    
    
    /// 运用白平衡结果回传：iOS 自动测得色温后通知 PC 同步滑块
    func sendWhiteBalanceResult(sliderValue: Int) {
        guard let deviceId = deviceId else { return }
        let destination = "/topic/device/\(deviceId)/config"
        let config: [String: Any] = [
            "ptype": "applyWhiteBalance",
            "wb_value": sliderValue,
            "device_id": deviceId
        ]
        let payloadDict: [String: Any] = [
            "type": "CONFIG_UPDATE",
            "deviceId": deviceId,
            "config": config,
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payloadDict, options: []),
           let payload = String(data: data, encoding: .utf8) {
            swiftStomp?.send(body: payload, to: destination)
            print("📤 [运用白平衡] 回传 slider=\(sliderValue)")
        }
    }

    // MARK: - 连接
    func connect(deviceId: String) {
        self.deviceId = deviceId
        
        guard let token = UserDefaults.standard.string(forKey: "jwt_token"), !token.isEmpty else {
            //print("❌ 未找到有效的认证token")
            updateConnectionState(.error)
            return
        }
        
        // 确保是 ws/wss 地址
        let urlString = "\(APIConfig.shared.baseStompWsURL)?token=\(token)&deviceId=\(deviceId)"
        guard let url = URL(string: urlString) else {
            print("[WebSocket] Invalid URL: \(urlString)")
            return
        }
        
        // 清理旧对象，避免多实例并发
        swiftStomp?.disconnect()
        swiftStomp = SwiftStomp(host: url)
        swiftStomp?.delegate = self
        swiftStomp?.autoReconnect = true
        
        swiftStomp?.connect()
        updateConnectionState(.connecting)
        //print("🔄 正在连接到STOMP服务器，设备ID: \(deviceId)")
        
        // —— 新增：启动连接监控（每5秒检查一次）——
        startConnectionMonitor()
    }
    
    // MARK: - 断开
    func disconnect() {
        // ⭐ §53.4：手动断开 = 退登录/切设备 → 清空观看端注册表与本次会话定案，
        //   避免上一台设备/上一个账号的观看端状态串到下一次推流决策里。
        SessionPolicy.shared.reset()
        WebSocketManager.connectReason = ""
        swiftStomp?.disconnect()
        stopHeartbeat()
        stopReconnectTimer()
        stopConnectionMonitor()
        isReconnectingOnce = false
        updateConnectionState(.disconnected)
        //print("🔌 STOMP连接已断开")
    }
    
    // MARK: - 状态
    private func updateConnectionState(_ state: ConnectionState) {
        DispatchQueue.main.async {
            self.isConnected = (state == .connected)
            self.connectionStatus = state.description
        }
        NotificationCenter.default.post(
            name: .webSocketConnectionStateChanged,
            object: nil,
            userInfo: ["connectionState": state.rawValue]
        )
    }
    
    // MARK: - 订阅
    private func subscribeToDeviceConfig() {
        guard let deviceId = deviceId else { return }
        let destination = "/topic/device/\(deviceId)/config"
        swiftStomp?.subscribe(to: destination)
        // ⭐ P2P：订阅 WebRTC 信令频道
        swiftStomp?.subscribe(to: "/topic/device/\(deviceId)/webrtc")
        print("✅ [P2P] 已订阅 WebRTC 信令频道")
        //print("✅ 已订阅频道: \(destination)")
    }
    
    // MARK: - 心跳
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            self?.sendHeartbeat()
        }
    }
    
    func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
    
    private func sendHeartbeat() {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let heartbeatJson = """
        {
            "type": "heartbeat",
            "timestamp": \(ts),
            "deviceId": "\(deviceId ?? "unknown")"
        }
        """
        swiftStomp?.send(body: heartbeatJson, to: "/app/heartbeat")
        //print("💓 [心跳] 发送: deviceId=\(deviceId ?? "unknown"), timestamp=\(ts)")
    }
    
    // MARK: - ⭐ P2P WebRTC 信令发送（统一发到 /app/webrtc/signal）
    // ⭐ §53.25：epoch = PC 发起本轮协商时生成的轮次标识（WEBRTC_REQUEST 带来，会话记住）。
    //   该会话所有出站信令回带它，PC 只收当前轮次——幽灵 Offer/迟到 ICE 从协议层根绝。
    //   nil = 老版 PC 没带（兼容），不写字段。
    func sendWebRTCSignalingSDP(sdpType: String, sdp: String, toDevice: String, epoch: Int64? = nil) {
        guard let deviceId = deviceId else { return }
        var payload: [String: Any] = [
            "type": "WEBRTC_SDP", "sdpType": sdpType, "sdp": sdp,
            "fromDevice": deviceId, "toDevice": toDevice
        ]
        if let e = epoch { payload["epoch"] = e }
        sendWebRTCSignalingPayload(payload)
    }

    func sendWebRTCSignalingICE(candidate: String, sdpMid: String, sdpMLineIndex: Int32, toDevice: String, epoch: Int64? = nil) {
        guard let deviceId = deviceId else { return }
        var payload: [String: Any] = [
            "type": "WEBRTC_ICE", "candidate": candidate, "sdpMid": sdpMid,
            "sdpMLineIndex": sdpMLineIndex, "fromDevice": deviceId, "toDevice": toDevice
        ]
        if let e = epoch { payload["epoch"] = e }
        sendWebRTCSignalingPayload(payload)
    }

    func sendWebRTCSignalingHangup(reason: String, toDevice: String, epoch: Int64? = nil) {
        guard let deviceId = deviceId else { return }
        var payload: [String: Any] = [
            "type": "WEBRTC_HANGUP", "reason": reason,
            "fromDevice": deviceId, "toDevice": toDevice
        ]
        if let e = epoch { payload["epoch"] = e }
        sendWebRTCSignalingPayload(payload)
    }

    func sendWebRTCSignaling(type: String, reason: String = "", toDevice: String, epoch: Int64? = nil) {
        guard let deviceId = deviceId else { return }
        var payload: [String: Any] = ["type": type, "fromDevice": deviceId, "toDevice": toDevice]
        if !reason.isEmpty { payload["reason"] = reason }
        if let e = epoch { payload["epoch"] = e }
        sendWebRTCSignalingPayload(payload)
    }

    private func sendWebRTCSignalingPayload(_ payload: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let body = String(data: data, encoding: .utf8) {
            swiftStomp?.send(body: body, to: "/app/webrtc/signal")
            print("📤 [P2P] 信令已发送: type=\(payload["type"] ?? ""), to=\(payload["toDevice"] ?? "")")
        }
    }

    // MARK: - （保留）一次性外部重连计时器
    private func stopReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }
    
    // MARK: - —— 新增：连接监控（核心逻辑）——
    private func startConnectionMonitor() {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: monitorInterval, repeats: true) { [weak self] _ in
            self?.checkAndReconnectOnceIfNeeded()
        }
    }
    
    private func stopConnectionMonitor() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }
    
    /// 每 5 秒触发：如果未连接，**只尝试一次**重连；能连上最好，连不上就等下一轮 5 秒再说
    private func checkAndReconnectOnceIfNeeded() {
        // 已连接：无需处理 & 清除“正在重连一次”的标记
        
        let jwtToken = UserDefaults.standard.string(forKey: "jwt_token")
        if jwtToken == nil || jwtToken == "" {
            print("Token 为空或不存在")
            // 处理空值的逻辑
            return
        } else {
            //print("Token 存在: \(jwtToken!)")
            // 使用 token 的逻辑
        }
        
        //print("🧭 连接监控：1")
        if isConnected {
            if isReconnectingOnce { isReconnectingOnce = false }
            return
        }
        //print("🧭 连接监控：2")
        // 已在“本轮尝试过一次”了：不再重复
        //if isReconnectingOnce { return }
        //print("🧭 连接监控：3")
        // 标记“本轮已尝试”
        //isReconnectingOnce = true
        //print("🧭 连接监控：检测到断开，尝试一次重连")
        
        // 尝试一次重连（不叠加、不循环）
        guard let did = deviceId else {
            print("⚠️ 无 deviceId，跳过重连")
            return
        }
        // 这里不等待回调结果，保持“尝试一次”的语义，连接成不成功交给下轮监控判断
        swiftStomp?.disconnect()   // 保守处理，释放旧连接
        swiftStomp = nil
        connect(deviceId: did)
        
        // 提醒：当 onConnect 成功时，会把 isReconnectingOnce 清零（见下方回调）
    }
}

// MARK: - SwiftStompDelegate
extension WebSocketManager: SwiftStompDelegate {
    func onConnect(swiftStomp: SwiftStomp, connectType: StompConnectType) {
        //print("✅ STOMP连接成功")
        updateConnectionState(.connected)
        stopReconnectTimer()
        
        // 订阅
        subscribeToDeviceConfig()
        isConnected = true
        
        // 订阅用户心跳回执（用户目的地固定写 /user/queue/heartbeat）
        swiftStomp.subscribe(to: "/user/queue/heartbeat")
        
        // 开始心跳
        startHeartbeat()
        
        //推流状态
        //信号状态
        startNetworkMonitor()
        //开始发送
        startStatusPush()
        
        
        
        // —— 新增：本轮重连成功，清除重连标记 —— //
        isReconnectingOnce = false

        // ⭐ P2P：WebSocket 重连成功后通知 P2PManager 做 ICE Restart
        NotificationCenter.default.post(name: .webSocketDidReconnect, object: nil)
    }
    
    func onDisconnect(swiftStomp: SwiftStomp, disconnectType: StompDisconnectType) {
        //print("🔌 STOMP连接断开: \(disconnectType)")
        updateConnectionState(.disconnected)
        isConnected = false
        stopHeartbeat()
        //
        stopStatusPush()
        // 不在这里直接重连；交给监控定时器每5秒检查一次
    }
    
    
    func onMessageReceived(swiftStomp: SwiftStomp, message: Any?, messageId: String, destination: String, headers: [String : String]) {
        // ⭐ P2P：WebRTC 信令频道，解析后整包转给 P2PManager
        if destination.contains("/topic/device/") && destination.contains("/webrtc") {
            var dict: [String: Any]?
            if let text = message as? String, let data = text.data(using: .utf8) {
                dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            } else if let d = message as? [String: Any] {
                dict = d
            } else if let data = message as? Data {
                dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            }
            if let dict = dict {
                print("📥 [P2P] 收到信令: type=\(dict["type"] as? String ?? ""), from=\(dict["fromDevice"] as? String ?? "")")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .webrtcSignalingReceived, object: nil, userInfo: dict)
                }
            }
            return
        }
        if destination.contains("/topic/device/") && destination.contains("/config") {
            let receiveTime = Date()
            let threadInfo = Thread.isMainThread ? "主线程" : "后台线程"
            //print("📨 收到STOMP消息: \(destination) \(message)")
            
            var msgType: String?
            var msgDict: [String: Any]?
            
            if let text = message as? String, let data = text.data(using: .utf8) {
                if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    msgType = json["type"] as? String
                    msgDict = json
                }
            } else if let dict = message as? [String: Any] {
                msgType = dict["type"] as? String
                msgDict = dict
            }
            
            // 处理 CONFIG_UPDATE 消息
            if msgType == "CONFIG_UPDATE" {
                print("📨 [WebSocket] 收到CONFIG_UPDATE消息（\(threadInfo)）: 时间戳=\(receiveTime.timeIntervalSince1970)")
                handleConfigUpdateMessage(message: message)
            }
            
            // 🔥 处理 RESET_PUBLISH 消息
            if msgType == "RESET_PUBLISH" {
                handleResetPublishMessage(messageDict: msgDict)
            }

            // 🔥 处理睡眠消息（停止采集）
            if msgType == "shuimian" {
                handleSleepMessage(messageDict: msgDict)
            }
            
            // 🔥 处理工作消息（重新推流）
            if msgType == "gongzuo" {
                handleWakeMessage(messageDict: msgDict)
            }
            
            // 🔥 处理试用断开消息
            if msgType == "TryDisconnect" {
                //print("📨 收到STOMP消息: TryDisconnect======>")
                handleTryDisconnectMessage(messageDict: msgDict)
            }
            
            // 🔥 v2.0: 处理 PC 端 set_fps 指令
            if let cmd = msgDict?["cmd"] as? String, cmd == "set_fps" {
                handleSetFpsCommand(messageDict: msgDict)
            }

            // PC 拉流心跳：收到就标记 PC 已连接（带 fromDevice + networkType 供观看者注册表）
            if msgType == "VIEWER_HEARTBEAT" {
                let fromDevice = (msgDict?["fromDevice"] as? String) ?? (msgDict?["pcDeviceId"] as? String) ?? ""
                let viewerNet = (msgDict?["networkType"] as? String) ?? "unknown"
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ViewerHeartbeat"),
                        object: nil,
                        userInfo: [
                            "fps": msgDict?["fps"] as? Int ?? 0,
                            "fromDevice": fromDevice,
                            "networkType": viewerNet
                        ]
                    )
                }
            }

            // ⭐ §53.2 PC 在线心跳（与拉流心跳分开）：PC 每秒发一条，**不管有没有画面**。
            //   有它才能把「PC 在线」和「PC 在看」分成两个状态——以前只有拉流心跳，
            //   PC 登录着但没画面时设备端显示「PC未连接」，把故障现象说成了对方没上线。
            //   同时带回 PC 内核的 H265 接收能力（§53.5 编码仲裁用）。
            if msgType == "PC_PRESENCE" {
                let fromDevice = (msgDict?["fromDevice"] as? String) ?? ""
                let viewing = (msgDict?["viewing"] as? Bool) ?? false
                let h265Recv = (msgDict?["h265Recv"] as? Bool) ?? true   // 缺省宽松：旧版 PC 视为能收
                let kernel = (msgDict?["kernel"] as? String) ?? "unknown"
                let pcUsername = (msgDict?["pcUsername"] as? String) ?? ""
                // ⭐⭐ §53.11 必须转发 localIps！这是"推流前判同不同 WiFi"的唯一依据（§53.4）。
                //   漏了它 → SessionPolicy 拿到空网段 → 判成"观看端未上报网段(旧版PC)" →
                //   **同 WiFi 也永远走 SRS，P2P 彻底不生效**（2026-07-28 实测：iOS 废了、Android 正常，
                //   因为 Android 是在自己的 WebSocketManager 里直接解析 JSON，没经过这层通知转发）。
                let localIps = (msgDict?["localIps"] as? String) ?? ""
                // ⭐ §53.20.2：PC 的公网出口 IP（防 /24 网段号撞车误判同 WiFi）。老 PC 缺省=空。
                let publicIp = (msgDict?["publicIp"] as? String) ?? ""
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("PCPresence"),
                        object: nil,
                        userInfo: [
                            "fromDevice": fromDevice,
                            "viewing": viewing,
                            "h265Recv": h265Recv,
                            "kernel": kernel,
                            "pcUsername": pcUsername,
                            "localIps": localIps,
                            "publicIp": publicIp
                        ]
                    )
                }
            }

            // 测试模式：切换硬件EV/ISO调亮度（从 config 对象里提取）
            if let config = msgDict?["config"] as? [String: Any],
               let cmd = config["cmd"] as? String, cmd == "test_mode" {
                let enabled = config["enabled"] as? Bool ?? false
                print("🧪 [test_mode] 收到PC指令: enabled=\(enabled)")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("TestModeCommand"),
                        object: nil,
                        userInfo: ["enabled": enabled]
                    )
                }
            }

            // 测试亮度滑块（仅测试模式生效，独立于综合亮度）
            if let config = msgDict?["config"] as? [String: Any],
               let cmd = config["cmd"] as? String, cmd == "test_brightness" {
                let value = config["value"] as? Int ?? 50
                print("🧪 [test_brightness] 收到PC指令: value=\(value)")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("TestBrightnessCommand"),
                        object: nil,
                        userInfo: ["value": value]
                    )
                }
            }

            // 白平衡滑块（PC 端下发 0-100，映射色温 2000K-8000K）
            if let config = msgDict?["config"] as? [String: Any],
               let cmd = config["cmd"] as? String, cmd == "white_balance" {
                let value = config["value"] as? Int ?? 50
                print("⚪️ [white_balance] 收到PC指令: value=\(value)")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("WhiteBalanceCommand"),
                        object: nil,
                        userInfo: ["value": value]
                    )
                }
            }

            // 抗频闪指令：PC 端开关 + 帧率档位（从 config 对象里提取）
            if let config = msgDict?["config"] as? [String: Any],
               let cmd = config["cmd"] as? String, cmd == "anti_flicker" {
                let enabled = config["enabled"] as? Bool ?? false
                let fps = config["fps"] as? Int ?? 80
                print("🔦 [anti_flicker] 收到PC指令: enabled=\(enabled), fps=\(fps)")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("AntiFlickerCommand"),
                        object: nil,
                        userInfo: ["enabled": enabled, "fps": fps]
                    )
                }
            }

            // 🔑 P0-1 关键帧请求：PC 的 RTCP PLI 兜底通道（SRS 不回传 RTCP 时走此路）
            //    收到后用 adaptOutputFormat 触发 IDR（不再用码率微调 hack）
            if let config = msgDict?["config"] as? [String: Any],
               let cmd = config["cmd"] as? String, cmd == "request_keyframe" {
                print("🔑 [request_keyframe] 收到PC关键帧请求")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("RequestKeyframeCommand"),
                        object: nil,
                        userInfo: [:]
                    )
                }
            }
            
        }
        if destination.contains("/queue/heartbeat") {
            // 心跳ACK响应
           // print("💓 [心跳ACK] 收到后端响应: \(message ?? "nil")")
        }
    }
    
    func onReceipt(swiftStomp: SwiftStomp, receiptId: String) {
        print("📋 收到STOMP回执: \(receiptId)")
    }
    
    func onError(swiftStomp: SwiftStomp, briefDescription: String, fullDescription: String?, receiptId: String?, type: StompErrorType) {
        print("❌ STOMP错误: \(briefDescription)")
        updateConnectionState(.error)
        // 不在这里直接重连；交给监控定时器
    }
    
    // 解析配置
    private func handleConfigUpdateMessage(message: Any?) {
        guard let messageString = message as? String else {
            print("相机方向配置: ❌ 消息格式错误"); return
        }
        guard let messageData = messageString.data(using: .utf8) else {
            print("相机方向配置: ❌ 消息转换为Data失败"); return
        }
        do {
            if let json = try JSONSerialization.jsonObject(with: messageData, options: []) as? [String: Any] {
                print("📦 [CONFIG_UPDATE] 收到完整消息: \(json)")  // 🔥 调试：打印完整消息
                print("📦 [CONFIG_UPDATE] config字段内容: \(json["config"] ?? "nil")")  // 🔥 单独打印config
                
                // 🔥 检查 operator 是否是自己发送的（自适应FPS消息会通过服务器反回来）
                if let msgOperator = json["operator"] as? String {
                    let myUsername = AccountStorageManager.shared.loadAccountInfo()?.collectorAccount ?? ""
                    if msgOperator == myUsername && !myUsername.isEmpty {
                        print("📦 [CONFIG_UPDATE] ⏭️ 跳过自己发送的消息 (operator=\(msgOperator))")
                        return
                    }
                }
                
                let webSocketMessage = WebSocketMessage(
                    type: json["type"] as? String ?? "CONFIG_UPDATE",
                    deviceId: json["deviceId"] as? String,
                    config: json["config"] as? [String: Any]
                )
                handleConfigUpdate(webSocketMessage)
            }
        } catch {
            print("相机方向配置: ❌ JSON解析失败: \(error)")
        }
    }
    
    // 🔥 处理重置推流消息
    private func handleResetPublishMessage(messageDict: [String: Any]?) {
        guard let msgDict = messageDict else {
            print("🔄 RESET_PUBLISH: ❌ 消息格式错误")
            return
        }
        
        // 解析消息
        let messageDeviceId = msgDict["deviceId"] as? String ?? ""
        let timestamp = msgDict["timestamp"] as? Int64 ?? 0
        let reason = msgDict["reason"] as? String ?? "未知原因"
        
        print("🔄🔄🔄 收到 RESET_PUBLISH 消息 🔄🔄🔄")
        print("   - 消息deviceId: \(messageDeviceId)")
        print("   - 本地deviceId: \(self.deviceId ?? "nil")")
        print("   - 时间戳: \(timestamp)")
        print("   - 触发原因: \(reason)")
        print("   - 完整消息: \(msgDict)")
        
        // 验证 deviceId 是否匹配
        guard let currentDeviceId = self.deviceId, messageDeviceId == currentDeviceId else {
            print("🔄 RESET_PUBLISH: ⚠️ deviceId不匹配，忽略该消息")
            return
        }
        
        print("🔄 RESET_PUBLISH: ✅ deviceId匹配，发送通知准备重置推流")
        
        // 发送通知给主线程处理重新推流
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .resetPublishRequested,
                object: nil,
                userInfo: [
                    "deviceId": messageDeviceId,
                    "timestamp": timestamp,
                    "reason": reason
                ]
            )
            print("🔄 RESET_PUBLISH: ✅ 通知已发送")
        }
    }
    
    // 🔥 处理睡眠消息（停止采集）
    private func handleSleepMessage(messageDict: [String: Any]?) {
        guard let msgDict = messageDict else {
            print("💤 shuimian: ❌ 消息格式错误")
            return
        }
        
        // 解析消息
        let messageDeviceId = msgDict["deviceId"] as? String ?? ""
        let timestamp = msgDict["timestamp"] as? Int64 ?? 0
        let reason = msgDict["reason"] as? String ?? "睡眠"
        
        print("💤 收到 shuimian 消息（停止采集）:")
        print("   - 消息deviceId: \(messageDeviceId)")
        print("   - 本地deviceId: \(self.deviceId ?? "nil")")
        print("   - 时间戳: \(timestamp)")
        print("   - 触发原因: \(reason)")
        
        // 验证 deviceId 是否匹配
        guard let currentDeviceId = self.deviceId, messageDeviceId == currentDeviceId else {
            print("💤 shuimian: ⚠️ deviceId不匹配，忽略该消息")
            return
        }
        
        print("💤 shuimian: ✅ deviceId匹配，准备停止采集")
        
        // 发送睡眠通知
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .cameraSleepRequested,
                object: nil,
                userInfo: [
                    "deviceId": messageDeviceId,
                    "timestamp": timestamp,
                    "reason": reason,
                    "action": "sleep"  // 🔥 明确指定是睡眠
                ]
            )
        }
    }
    
    // 🔥 处理工作消息（重新推流）
    private func handleWakeMessage(messageDict: [String: Any]?) {
        guard let msgDict = messageDict else {
            print("☀️ gongzuo: ❌ 消息格式错误")
            return
        }
        
        // 解析消息
        let messageDeviceId = msgDict["deviceId"] as? String ?? ""
        let timestamp = msgDict["timestamp"] as? Int64 ?? 0
        let reason = msgDict["reason"] as? String ?? "工作"
        
        print("☀️ 收到 gongzuo 消息（重新推流）:")
        print("   - 消息deviceId: \(messageDeviceId)")
        print("   - 本地deviceId: \(self.deviceId ?? "nil")")
        print("   - 时间戳: \(timestamp)")
        print("   - 触发原因: \(reason)")
        
        // 验证 deviceId 是否匹配
        guard let currentDeviceId = self.deviceId, messageDeviceId == currentDeviceId else {
            print("☀️ gongzuo: ⚠️ deviceId不匹配，忽略该消息")
            return
        }
        
        print("☀️ gongzuo: ✅ deviceId匹配，准备重新推流")
        
        // 发送唤醒通知
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .cameraSleepRequested,
                object: nil,
                userInfo: [
                    "deviceId": messageDeviceId,
                    "timestamp": timestamp,
                    "reason": reason,
                    "action": "wake"  // 🔥 明确指定是唤醒
                ]
            )
        }
    }
    
    // MARK: - 🔥 v2.0 自适应FPS：PC端 set_fps 指令处理
    
    /// 处理 PC 端发来的 set_fps 指令
    /// 协议格式：{ "cmd": "set_fps", "fps": 30, "urgency": "high", "reason": "jitter_high", "bitrate": 5000000, "timestamp": ... }
    private func handleSetFpsCommand(messageDict: [String: Any]?) {
        guard let msgDict = messageDict else {
            print("🎯 [set_fps] ❌ 消息格式错误")
            return
        }
        
        // 解析必填字段
        guard let fps = msgDict["fps"] as? Int else {
            print("🎯 [set_fps] ❌ fps字段缺失")
            return
        }
        
        // 解析可选字段
        let urgency = msgDict["urgency"] as? String ?? "normal"  // 默认 normal
        let reason = msgDict["reason"] as? String
        let bitrate = msgDict["bitrate"] as? Int
        let timestamp = msgDict["timestamp"] as? Int64 ?? Int64(Date().timeIntervalSince1970 * 1000)
        
        print("🎯 [set_fps] 收到PC端指令: fps=\(fps), urgency=\(urgency), reason=\(reason ?? "无"), bitrate=\(bitrate ?? 0)")
        
        // 使用高优先级队列处理 critical/high 级别指令
        let queue: DispatchQueue
        if urgency == "critical" || urgency == "high" {
            queue = DispatchQueue.global(qos: .userInteractive)
        } else {
            queue = DispatchQueue.main
        }
        
        queue.async {
            // 发送通知给 WebRTCManager
            NotificationCenter.default.post(
                name: .setFpsRequested,
                object: nil,
                userInfo: [
                    "fps": fps,
                    "urgency": urgency,
                    "reason": reason ?? "",
                    "bitrate": bitrate ?? 0,
                    "timestamp": timestamp
                ]
            )
        }
    }
    
    /// 发送 set_fps_ack 确认消息（可选）
    /// - Parameters:
    ///   - fps: 实际应用的帧率
    ///   - status: "applied" 或 "rejected"
    func sendSetFpsAck(fps: Int, status: String = "applied") {
        guard let deviceId = deviceId else {
            print("🎯 [set_fps_ack] ❌ deviceId为空")
            return
        }
        
        let destination = "/topic/device/\(deviceId)/config"
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        
        let payloadDict: [String: Any] = [
            "cmd": "set_fps_ack",
            "fps": fps,
            "status": status,
            "timestamp": ts
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: payloadDict, options: []),
           let payload = String(data: data, encoding: .utf8) {
            swiftStomp?.send(body: payload, to: destination)
            print("🎯 [set_fps_ack] 已发送确认: fps=\(fps), status=\(status)")
        } else {
            print("🎯 [set_fps_ack] ❌ JSON序列化错误")
        }
    }
    
    // 🔥 处理试用断开消息 (TryDisconnect)
    private func handleTryDisconnectMessage(messageDict: [String: Any]?) {
        guard let msgDict = messageDict else {
            print("⏱️ TryDisconnect: ❌ 消息格式错误")
            return
        }
        
        // 🔥 打印完整原始消息
        if let jsonData = try? JSONSerialization.data(withJSONObject: msgDict, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            //print("\n📨📨📨 收到 TryDisconnect 原始消息 📨📨📨")
            //print(jsonString)
            //print("📨📨📨 TryDisconnect 原始消息结束 📨📨📨\n")
        }
        
        // 解析消息
        let messageDeviceId = msgDict["deviceId"] as? String ?? ""
        let shouldDisconnect = msgDict["shouldDisconnect"] as? Bool ?? false
        let trialRequired = msgDict["trialRequired"] as? Bool ?? false
        let activated = msgDict["activated"] as? Bool ?? false
        let activationLevel = msgDict["activationLevel"] as? Int
        let activationLevelName = msgDict["activationLevelName"] as? String
        let activationExpireAt = msgDict["activationExpireAt"] as? String
        let qualityAccess = msgDict["qualityAccess"] as? [String]
        let trialEnded = msgDict["trialEnded"] as? Bool ?? false
        let currentStage = msgDict["currentStage"] as? Int
        let totalStages = msgDict["totalStages"] as? Int
        let stageSeconds = msgDict["stageSeconds"] as? Int
        let remainingSeconds = msgDict["remainingSeconds"] as? Int
        let usedSeconds = msgDict["usedSeconds"] as? Int
        let stageJustEnded = msgDict["stageJustEnded"] as? Int
        let message = msgDict["message"] as? String
        
        // 🔥 日试用相关（新增）
        let isDailyTrial = msgDict["isDailyTrial"] as? Bool ?? false
        let activationRemainingSeconds = msgDict["activationRemainingSeconds"] as? Int
        
        /*
        print("⏱️ [TryDisconnect] 解析结果:")
        print("   - deviceId: \(messageDeviceId)")
        print("   - shouldDisconnect: \(shouldDisconnect)")
        print("   - trialRequired: \(trialRequired)")
        print("   - activated: \(activated)")
        print("   - activationLevel: \(activationLevel ?? 0) (\(activationLevelName ?? "无"))")
        print("   - activationExpireAt: \(activationExpireAt ?? "无")")
        print("   - qualityAccess: \(qualityAccess ?? [])")
        print("   - trialEnded: \(trialEnded)")
        print("   - currentStage: \(currentStage ?? 0)/\(totalStages ?? 6)")
        print("   - stageSeconds: \(stageSeconds ?? 0)")
        print("   - remainingSeconds: \(remainingSeconds ?? 0)")
        print("   - usedSeconds: \(usedSeconds ?? 0)")
        print("   - stageJustEnded: \(stageJustEnded ?? 0)")
        print("   - message: \(message ?? "")")
        */
        // 🔥 更新本地保存的试用/激活信息（用于 CONFIG_STATE 推送）
        UserDefaults.standard.set(trialRequired, forKey: "trial_required")
        UserDefaults.standard.set(activated, forKey: "activated")
        if let level = activationLevel {
            UserDefaults.standard.set(level, forKey: "activation_level")
        }
        if let levelName = activationLevelName {
            UserDefaults.standard.set(levelName, forKey: "activation_level_name")
        }
        if let expireAt = activationExpireAt {
            UserDefaults.standard.set(expireAt, forKey: "activation_expire_at")
        }
        // ⭐ §53.9：服务器推送的激活状态变化里也带开通时间（后台改等级/续期后无需重登即刷新「我的」页）
        if let activationTime = msgDict["activationTime"] as? String {
            UserDefaults.standard.set(activationTime, forKey: "activation_time")
        }
        if let quality = qualityAccess {
            UserDefaults.standard.set(quality, forKey: "quality_access")
        }
        UserDefaults.standard.set(trialEnded, forKey: "trial_ended")
        if let stage = currentStage {
            UserDefaults.standard.set(stage, forKey: "current_stage")
        }
        if let total = totalStages {
            UserDefaults.standard.set(total, forKey: "total_stages")
        }
        if let stageSec = stageSeconds {
            UserDefaults.standard.set(stageSec, forKey: "stage_seconds")
        }
        if let remaining = remainingSeconds {
            UserDefaults.standard.set(remaining, forKey: "remaining_seconds")
        }
        if let used = usedSeconds {
            UserDefaults.standard.set(used, forKey: "used_seconds")
        }
        
        // 🔥 日试用相关（新增）
        UserDefaults.standard.set(isDailyTrial, forKey: "is_daily_trial")
        if let activationRemaining = activationRemainingSeconds {
            UserDefaults.standard.set(activationRemaining, forKey: "activation_remaining_seconds")
        }
        
        // 🔥 核心判断：是否需要强制退出
        // 1. shouldDisconnect = true 时必须断开
        // 2. 日试用用户 activationRemainingSeconds ≤ 0 时断开
        // 3. 未激活用户 trialEnded = true 或 remainingSeconds = 0 时断开
        
        var needDisconnect = shouldDisconnect
        var disconnectMessage = message ?? "试用时间已到"
        
        if activated && isDailyTrial {
            // 日试用用户
            if let remaining = activationRemainingSeconds, remaining <= 0 {
                needDisconnect = true
                disconnectMessage = "日试用已到期，请续费或扫码绑定"
                print("⏱️ TryDisconnect: ⚠️ 日试用已到期！")
            } else if let remaining = activationRemainingSeconds, remaining < 300 {
                // 提示即将到期（剩余5分钟内）
                print("⏱️ TryDisconnect: ⚠️ 日试用即将到期，剩余 \(remaining) 秒")
            }
        } else if !activated && trialRequired {
            // 未激活用户（走试用流程）
            if trialEnded {
                needDisconnect = true
                disconnectMessage = "今日试用已用完，请明天再来或扫码绑定"
                print("⏱️ TryDisconnect: ⚠️ 今日试用已全部用完！")
            } else if let remaining = remainingSeconds, remaining <= 0 {
                needDisconnect = true
                disconnectMessage = "当前阶段试用完成，请重启进入下一阶段"
                print("⏱️ TryDisconnect: ⚠️ 当前阶段试用完成！")
            }
        }
        
        if needDisconnect {
            print("⏱️ TryDisconnect: ⚠️ 需要强制退出！")
            
            // 发送通知给主线程处理
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .tryDisconnectRequested,
                    object: nil,
                    userInfo: [
                        "shouldDisconnect": needDisconnect,
                        "trialEnded": trialEnded,
                        "stageJustEnded": stageJustEnded as Any,
                        "currentStage": currentStage as Any,
                        "totalStages": totalStages as Any,
                        "remainingSeconds": remainingSeconds as Any,
                        "message": disconnectMessage,
                        "isDailyTrial": isDailyTrial,
                        "activationRemainingSeconds": activationRemainingSeconds as Any
                    ]
                )
            }
        } else {
           // print("⏱️ TryDisconnect: ✅ 正常使用，不需要断开")
        }
    }
    
    private func handleConfigUpdate(_ message: WebSocketMessage) {
        guard let configDict = message.config,
              let deviceId = message.deviceId else {
            print("相机方向配置: ❌ 配置更新消息格式错误"); return
        }
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: configDict)
            let config = try JSONDecoder().decode(ThinRemoteConfig.self, from: jsonData)
            
            // 🔥 关键修复：同时更新内存中的配置和本地缓存
            ConfigManager.shared.currentThinConfig = config  // 更新内存
            ConfigManager.shared.cacheThinConfig(config)     // 持久化到本地
            
            // 🔥 确保在主线程发送通知，立即执行（不延迟）
            if Thread.isMainThread {
                NotificationCenter.default.post(name: .thinConfigUpdated, object: nil, userInfo: ["cfg": config])
                print("相机方向配置 ✅ 配置更新成功（主线程）: deviceId=\(deviceId), ptype=\(config.ptype)")
            } else {
                // ⭐ D：改 async —— 网络回调线程不再同步等主线程，避免卡住 WebSocket 接收循环 / 潜在死锁
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .thinConfigUpdated, object: nil, userInfo: ["cfg": config])
                    print("相机方向配置 ✅ 配置更新成功（切换到主线程）: deviceId=\(deviceId), ptype=\(config.ptype)")
                }
            }
        } catch {
            print("相机方向配置❌ 解析配置更新失败: \(error)")
        }
    }
}

// MARK: - 辅助类型
enum ConnectionState: String {
    case disconnected = "disconnected"
    case connecting = "connecting"
    case connected = "connected"
    case error = "error"
    
    var description: String {
        switch self {
        case .disconnected: return "未连接"
        case .connecting:   return "连接中"
        case .connected:    return "已连接"
        case .error:        return "连接错误"
        }
    }
}

struct WebSocketMessage {
    let type: String
    let deviceId: String?
    let config: [String: Any]?
}

extension Notification.Name {
    static let webSocketConnectionStateChanged = Notification.Name("webSocketConnectionStateChanged")
    static let thinConfigUpdated = Notification.Name("thinConfigUpdated")
    static let resetPublishRequested = Notification.Name("resetPublishRequested")  // 🔥 重置推流请求
    static let cameraSleepRequested = Notification.Name("cameraSleepRequested")  // 🔥 摄像头休眠/唤醒请求
    static let tryDisconnectRequested = Notification.Name("tryDisconnectRequested")  // 🔥 试用断开请求
    static let setFpsRequested = Notification.Name("setFpsRequested")  // 🔥 PC端自适应FPS指令
    //static let publishingStateChanged = Notification.Name("publishingStateChanged")
}

