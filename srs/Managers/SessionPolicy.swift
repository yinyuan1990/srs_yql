import Foundation

// ============================================================================
// SessionPolicy —— 「本次推流走什么链路、用什么编码」的唯一决策点（§53.4-定稿）
//
// 设计口径（用户 2026-07-28 拍板）：
//   1. **推流前定案**：iOS/Android 登录成功后与 PC 已经能互相通信（`/topic/device/{id}/config`
//      双方都订阅），所以在按下推流之前就能把「网络关系」和「观看端能力」交换清楚，
//      一次定下 mode + codec。**推流中不再切换**（旧方案"先起 P2P、发现跨网再回落/退登录页"作废）。
//   2. 登录页不再让用户选线路/编码 —— 用户选不出正确答案，这是系统该判的事。
//   3. 一方断线 / 切网 = 决策输入变了 → **重新协商**：停推流 → 重新决策 → 起推流。
//      带冷却与次数上限，绝不无限抖（见 renegotiateCooldownSec / maxRenegotiatePerSession）。
//
// 为什么单独一个文件：决策逻辑不该散进 6000 行的 WebRTCManager。本文件对外只暴露
//   · updatePresence / removeStalePresence  ← 喂输入
//   · decideForPublish()                    ← 出结果（startPublish 调）
//   · onRenegotiateNeeded                   ← 输入变化且结果会变时回调上层重启推流
// 删掉本文件 + 还原 WebRTCManager 里的 3 处调用即可回退到"登录页手选"的老行为。
// ============================================================================

/// 本次会话的链路
enum SessionMode: String {
    case p2p = "p2p"
    case srs = "srs"

    /// CONFIG_STATE.connectstype 上报值（PC 按此跟随：0=SRS / 1=P2P）
    var connectstype: Int { self == .p2p ? 1 : 0 }
}

/// 一次决策的完整结果
struct SessionDecision: Equatable {
    let mode: SessionMode
    let codec: VideoCodecOption
    /// 人话原因，随 CONFIG_STATE.connectReason 上报给 PC 顶栏显示（"互相监督"的一半）
    let reason: String

    /// 只比较"会不会改变链路行为"的两项——reason 变化不触发重新协商
    static func == (l: SessionDecision, r: SessionDecision) -> Bool {
        l.mode == r.mode && l.codec == r.codec
    }
}

/// 一个在线观看端（PC）的状态快照
private struct ViewerInfo {
    var lastSeen: Date
    var viewing: Bool
    var h265Recv: Bool
    var kernel: String
    var localIps: [String]
    /// ⭐ §53.20.2：PC 的公网出口 IP（登录时后端回给它、随 PC_PRESENCE 上报）。
    /// 空 = 老版 PC/老后端，跳过公网校验。
    var publicIp: String
}

final class SessionPolicy {

    static let shared = SessionPolicy()
    private init() {}

    // MARK: - 可调参数（集中在此，便于现场调）

    /// ⭐⭐ 2026-08-02 用户拍板：当前版本三端一律直接走 SRS，P2P 以后单独出专版、不再混用。
    /// true = compute() 协商直接返回 SRS（P2P 判定/重协商代码保留不删）；P2P 专版改回 false 即恢复。
    static let srsOnlyBuild = true

    /// 推流前等 PC_PRESENCE 的宽限期：两端登录有先后，刚开机时消息可能还没到。
    /// 等不到就按 SRS（对任何网络都成立的安全默认），避免"其实同 WiFi 却白走 SRS"。
    let presenceGraceSec: Double = 2.0
    /// 两次重新协商的最小间隔
    private let renegotiateCooldownSec: Double = 5.0
    /// 单次推流会话内最多重新协商几次；超了就钉在 SRS（对所有网络都成立）
    private let maxRenegotiatePerSession = 3
    /// 观看端心跳超时（与 PC 侧 1s 发送间隔匹配，容忍 3 次丢包）
    private let presenceTimeoutSec: Double = 4.0

    // MARK: - 输入

    private var viewers: [String: ViewerInfo] = [:]
    private let lock = NSLock()

    /// 服务器下发的默认编码（总后台可配，§53.4.4）。登录时写入 UserDefaults，P2P/SRS 各一个 key。
    /// 这里只读、不猜：读不到就按 h264（§56.27 产品默认，与后端部署无关），设备/观看端不支持时下面会如实降 H264。
    private func serverDefaultCodec(for mode: SessionMode) -> VideoCodecOption {
        let key = (mode == .p2p) ? VideoCodecOption.storageKey : VideoCodecOption.srsStorageKey
        return VideoCodecOption.lastSelected(key: key, defaultCodec: .h264)
    }

    // MARK: - 输出

    /// 本次会话已定案的决策（nil = 还没推流）
    private(set) var current: SessionDecision?
    /// 输入变化且新结果与已定案不同 → 回调上层做「停推流 → 重新决策 → 起推流」
    var onRenegotiateNeeded: ((String) -> Void)?

    private var lastRenegotiateAt: Date = .distantPast
    private var renegotiateCount = 0
    /// 达到次数上限后钉死 SRS，不再响应任何输入变化
    private var pinnedToSrs = false
    /// ⭐ §53.20.1：标记「接下来这次 decideForPublish 是重新协商触发的重启」。
    /// 没有它，重协商 = 停推流→startPublish→decideForPublish 把 pinnedToSrs/renegotiateCount
    /// 全部重置 —— 「钉住 SRS」活不过一次重启，P2P↔SRS 每 5~10s 拆建一轮无限打架（实测=卡顿）。
    private var renegotiationInFlight = false

    // MARK: - 喂输入：PC_PRESENCE 心跳

    /// 收到一条 PC_PRESENCE。返回是否是新上线的 PC（供上层打日志）。
    @discardableResult
    func updatePresence(pcId: String, viewing: Bool, h265Recv: Bool,
                        kernel: String, localIps: [String], publicIp: String = "") -> Bool {
        lock.lock()
        let isNew = viewers[pcId] == nil
        let old = viewers[pcId]
        viewers[pcId] = ViewerInfo(lastSeen: Date(), viewing: viewing, h265Recv: h265Recv,
                                   kernel: kernel, localIps: localIps, publicIp: publicIp)
        lock.unlock()

        // 只在"可能改变决策"的字段变了时才去评估，避免每秒心跳都跑一遍决策。
        // ⭐ §53.12：本机切过网时也在这里补评估一次（那时不评估，见 onLocalNetworkChanged）。
        let inputChanged = isNew
            || old?.h265Recv != h265Recv
            || old?.localIps != localIps
            || old?.publicIp != publicIp
        let pending = pendingNetworkChange
        if pending { pendingNetworkChange = false }
        if inputChanged || pending {
            // ⭐ §53.20.3 单人模式先到先得：P2P 会话进行中，**其它观看端的任何 presence 变化都不触发
            //   重新协商**——不只是"新上线"。此前只挡 isNew，导致第二台 PC 的后续心跳字段一变
            //   （或它跨网）就把 compute() 拖去"非同网段→SRS"，把正在 P2P 的第一台踢下来切 SRS，
            //   第二台被拒绝走了又切回 P2P → P2P↔SRS 来回翻（用户实测"混乱"，PC 日志 connectstype 1↔0）。
            //   单人模式=只认先来的那台；其它 PC 由 P2P 层回 single_mode_occupied 提示占线。
            //   本机切网(pending)例外照常评估；真正的 P2P 对端变差由 ICE 失败 → forceSrsForSession 兜底。
            if !pending && current?.mode == .p2p {
                log("🚧 单人直连进行中，观看端(\(pcId))presence 变化不触发重协商（单人模式；其它 PC 由 P2P 层拒绝占线）")
                return isNew
            }
            let base = isNew ? "PC上线(\(pcId))" : "PC网络/能力变化(\(pcId))"
            let handled = evaluateForRenegotiate(trigger: pending ? base + " + 本机切过网" : base)
            // ⭐⭐ 2026-08-01 修「切网后卡死在 P2P、切不到 SRS」：切网标记是唯一的评估触发源
            //  （PC 没动，它心跳里的字段永远不变、inputChanged 永远 false）。评估若被 5s 冷却
            //   挡下（快速来回切网必撞），标记已在上面被消费——不还回去就**再也没有任何东西
            //   触发重评估**，跨网了还钉在 P2P 上黑屏。还回去后 PC 心跳 1s 一条，冷却一过自动重试。
            if pending && !handled {
                pendingNetworkChange = true
            }
        }
        return isNew
    }

    /// 清理超时未续期的观看端。返回是否有 PC 下线。
    @discardableResult
    func removeStalePresence() -> Bool {
        let cutoff = Date()
        lock.lock()
        let before = viewers.count
        viewers = viewers.filter { cutoff.timeIntervalSince($0.value.lastSeen) <= presenceTimeoutSec }
        let changed = viewers.count != before
        lock.unlock()
        // ⭐ PC 掉线**不**触发重新协商：它可能只是重启一下，为此重启推流是自伤。
        //   等它回来时若网段变了，updatePresence 那条路径会处理。
        return changed
    }

    /// 退登录 / 切设备：清空，避免上一台设备的观看端状态串到下一次
    func reset() {
        lock.lock()
        viewers.removeAll()
        lock.unlock()
        current = nil
        renegotiateCount = 0
        pinnedToSrs = false
        renegotiationInFlight = false
        lastRenegotiateAt = .distantPast
        graceConsumed = false
        pendingNetworkChange = false
    }

    /// ⭐ §53.20.1：上层收到重协商回调但当前未推流（忽略执行）时清标记，
    /// 否则残留标记会让下一次**用户手动**推流误当成"重协商重启"而保留过期的钉住状态。
    func abortRenegotiation() {
        renegotiationInFlight = false
    }

    /// 停止推流：只清"本次会话"的定案，**保留观看端注册表**
    ///（PC 还在线、心跳还在来，下次推流要用它决策）
    func onPublishStopped() {
        current = nil
        graceConsumed = false
    }

    /// 一次性宽限：推流那一刻还没收到任何 PC_PRESENCE 时返回 true，
    /// 调用方等 `presenceGraceSec` 再重试一次决策（两端登录有先后，消息可能刚好没到）。
    /// 只放行一次，等不到就按 SRS 走，绝不无限等。
    private var graceConsumed = false
    func shouldWaitForPresence() -> Bool {
        if graceConsumed { return false }
        graceConsumed = true
        return onlineViewerCount == 0
    }

    // MARK: - 对外查询（UI 灯 + 编码仲裁复用同一份数据）

    var onlineViewerCount: Int {
        lock.lock(); defer { lock.unlock() }
        return viewers.count
    }
    /// 在线观看端里是否存在收不了 H265 的（网页内核=Chromium 134，收 H265 必黑屏，§49.6-10）
    var anyViewerCannotRecvH265: Bool {
        lock.lock(); defer { lock.unlock() }
        return viewers.values.contains { !$0.h265Recv }
    }
    var anyViewerActuallyViewing: Bool {
        lock.lock(); defer { lock.unlock() }
        return viewers.values.contains { $0.viewing }
    }

    // MARK: - 决策（唯一入口，startPublish 调）

    /// 按当前输入定案本次会话的 mode + codec。
    /// - Parameter deviceCanEncodeH265: 本机能否 H265 硬编（由 H265Support 探测）
    func decideForPublish(deviceCanEncodeH265: Bool) -> SessionDecision {
        // ⭐ §53.20.1：重协商触发的重启必须**继承**钉住状态与协商计数——否则
        //   forceSrsForSession 钉住 SRS → 停推流重启 → 这里清零 → 又算回 P2P → 又失败，
        //   P2P↔SRS 无限拆建（客户实测=画面周期性卡顿）。只有全新会话才清零。
        if renegotiationInFlight {
            renegotiationInFlight = false
        } else {
            renegotiateCount = 0
            pinnedToSrs = false
        }
        let d = compute(deviceCanEncodeH265: deviceCanEncodeH265)
        current = d
        // ⭐ §53.11：把**决策输入**一起打出来。上一版只打结果与原因，结果 iOS 因为
        //   `localIps` 在通知转发时漏传（空网段）而永远走 SRS，日志里看不出是输入缺了。
        lock.lock()
        let inputs = viewers.map { "\($0.key)[\($0.value.localIps.joined(separator: "/"))\($0.value.h265Recv ? "" : " 不收H265")]" }
        lock.unlock()
        log("决策输入：本机网段=\(Self.localIPv4Addresses().joined(separator: "/")) 观看端=\(inputs.isEmpty ? "无" : inputs.joined(separator: " "))")
        log("✅ 推流前定案：\(d.mode.rawValue.uppercased()) + \(d.codec.title) —— \(d.reason)")
        return d
    }

    /// 纯计算，不改状态（评估是否需要重新协商时也用它）
    private func compute(deviceCanEncodeH265: Bool) -> SessionDecision {
        lock.lock()
        let snapshot = viewers
        lock.unlock()

        let myIps = Self.localIPv4Addresses()
        var reasons: [String] = []

        // ① 链路：所有在线观看端都与本机同网段才走 P2P。
        //    依据 §52.5：跨网时 P2P 只能走 TURN 中继，物理路径与 SRS 完全相同，却拿不到
        //    服务端重传/GOP cache/一对多分发，是最差的一档组合 —— 所以跨网直接走 SRS。
        let mode: SessionMode
        // ⭐ 后端一键强制多人线路（总后台 `connect.mode=srs`）优先于一切网络判定，
        //   保留这条运维开关：出问题时可以让全网设备立刻统一走 SRS。
        let backendForcesSrs = (UserDefaults.standard.string(forKey: "connect_mode") ?? "auto")
                                    .lowercased() == "srs"
        if Self.srsOnlyBuild {
            // ⭐⭐ 2026-08-02 用户拍板：当前版本三端一律直接走 SRS，P2P 以后单独出专版、不再混用。
            //   协商直接定 SRS；下方 P2P 同网段判定/重协商代码全部保留（P2P 专版把 srsOnlyBuild 改回 false 即恢复）。
            mode = .srs
            reasons.append("当前版本固定多人线路（P2P另出专版）")
        } else if pinnedToSrs {
            // ⭐ §53.20.1：本次会话已被实测否掉 P2P（ICE 失败/协商次数达上限），
            //   重协商重启后必须还记得——不能拿网段预判再算回 P2P。
            mode = .srs
            reasons.append("本次会话已钉住多人线路")
        } else if backendForcesSrs {
            mode = .srs
            reasons.append("后端强制多人线路")
        } else if snapshot.isEmpty {
            mode = .srs
            reasons.append("暂无观看端在线，默认多人线路")
        } else {
            let allSameSubnet = snapshot.values.allSatisfy { Self.sharesSubnet(myIps: myIps, peerIps: $0.localIps) }
            let anyMissingIps = snapshot.values.contains { $0.localIps.isEmpty }
            // ⭐ §53.20.2：/24 网段判定有假阳性——192.168.1.x 是全世界路由器的默认网段，
            //   iOS 在 A 地、PC 在 B 地完全可能撞车 → 误判同 WiFi → P2P 白失败几十秒才回落。
            //   公网出口 IP 双重校验：同一 WiFi 下两端出口必然相同（同一路由器出网）。
            //   任一侧为空（老 PC/老后端没下发 clientIp）→ 跳过该校验，退回纯网段判定。
            let myPublicIp = UserDefaults.standard.string(forKey: "public_ip") ?? ""
            let publicIpMismatch = !myPublicIp.isEmpty && snapshot.values.contains {
                !$0.publicIp.isEmpty && $0.publicIp != myPublicIp
            }
            if allSameSubnet && !anyMissingIps && !publicIpMismatch {
                mode = .p2p
                reasons.append("与观看端同 WiFi，走单人直连")
            } else {
                mode = .srs
                if publicIpMismatch {
                    reasons.append("公网出口不同(非同一WiFi，网段号撞车)，走多人线路")
                } else {
                    reasons.append(anyMissingIps ? "观看端未上报网段(旧版PC)，走多人线路"
                                                 : "与观看端不在同一 WiFi，走多人线路")
                }
            }
        }

        // ② 编码：服务器默认（总后台可配，默认 H265），但要服从"最弱观看端"和本机硬编能力。
        var codec = serverDefaultCodec(for: mode)
        if codec == .h265 {
            if snapshot.values.contains(where: { !$0.h265Recv }) {
                codec = .h264
                reasons.append("有观看端内核收不了 H265，已降 H264")
            } else if !deviceCanEncodeH265 {
                codec = .h264
                reasons.append("本机无 H265 硬编，已降 H264")
            }
        }

        return SessionDecision(mode: mode, codec: codec, reason: reasons.joined(separator: "；"))
    }

    // MARK: - 重新协商

    /// 输入变了 → 看结果会不会变；会变才回调上层重启推流（带冷却与次数上限）。
    /// ⭐ 2026-08-01 返回值：true=已处理完毕（协商已发起/结果不变/无需处理），
    ///   false=**被冷却挡下、需要稍后重试**——调用方（updatePresence 的切网标记路径）据此把
    ///   pendingNetworkChange 还回去，否则切网评估机会被冷却吞掉后永远不会再触发（卡死在旧链路）。
    @discardableResult
    private func evaluateForRenegotiate(trigger: String) -> Bool {
        guard let decided = current else { return true }      // 还没推流，decideForPublish 会用最新输入重算
        guard !pinnedToSrs else { return true }               // 本次会话已钉死，无需再评估

        let fresh = compute(deviceCanEncodeH265: H265Support.deviceCanEncodeHEVC())
        guard fresh != decided else {
            log("输入变化(\(trigger))但决策结果不变（\(decided.mode.rawValue)+\(decided.codec.title)），不重启推流")
            return true
        }

        let since = Date().timeIntervalSince(lastRenegotiateAt)
        guard since >= renegotiateCooldownSec else {
            log("⏳ 需要重新协商(\(trigger))但距上次仅 \(String(format: "%.1f", since))s，等冷却后重试")
            return false   // ⭐ 冷却挡下 ≠ 处理完，调用方须保留切网标记重试
        }
        renegotiateCount += 1
        if renegotiateCount > maxRenegotiatePerSession {
            pinnedToSrs = true
            log("⚠️ 本次会话已重新协商 \(maxRenegotiatePerSession) 次，钉死多人线路(SRS)不再切换（防抖）")
            current = SessionDecision(mode: .srs, codec: decided.codec, reason: "协商次数达上限，固定多人线路")
            lastRenegotiateAt = Date()
            renegotiationInFlight = true   // §53.20.1：重启后的 decideForPublish 保留钉住/计数
            onRenegotiateNeeded?("协商次数达上限→固定SRS")
            return true
        }
        lastRenegotiateAt = Date()
        log("🔄 重新协商(\(trigger))：\(decided.mode.rawValue)+\(decided.codec.title) → \(fresh.mode.rawValue)+\(fresh.codec.title)（停推流→重决策→起推流）")
        renegotiationInFlight = true       // §53.20.1
        onRenegotiateNeeded?(trigger)
        return true
    }

    /// 设备自己切网（WiFi↔蜂窝/换 WiFi）由 WebRTCManager 的网络监听调用。
    ///
    /// ⚠️ §53.12：**只打标记，不在这里评估**。切网瞬间 WS 多半已断、PC 的 presence 也停了，
    /// 此刻算出来的"网段关系"是拿旧的/空的观看端网段去比，最不可靠；更要紧的是切网同时会触发
    /// 各端原有的切网自愈（iOS 是 P2PManager 拆会话 + HANGUP 让 PC 重新 REQUEST），
    /// 两条恢复路径在同一事件里抢着重建，顺序不确定 —— Android 上实测就是「切网后不出画面」。
    /// 等观看端心跳重新到达（网络已稳、网段是新的）时，由 updatePresence 一并评估。
    func onLocalNetworkChanged() {
        pendingNetworkChange = true
        log("📶 本机切网 → 标记待重新决策（等观看端心跳恢复后再评估，避免与切网自愈打架）")
    }

    private var pendingNetworkChange = false

    /// 兜底：推流前预判为同 WiFi，但实测 ICE 路径不是局域网（AP 隔离/多网卡/NAT 掩盖网段）。
    /// 直接把本次会话钉在 SRS 并重新协商——比让用户自己去登录页改线路正确（§52.6 已废弃）。
    func forceSrsForSession(reason: String) {
        guard let decided = current, decided.mode == .p2p else { return }
        let since = Date().timeIntervalSince(lastRenegotiateAt)
        guard since >= renegotiateCooldownSec else {
            log("⏳ 实测非局域网(\(reason))，但距上次协商仅 \(String(format: "%.1f", since))s，等冷却")
            return
        }
        lastRenegotiateAt = Date()
        pinnedToSrs = true      // 本次会话不再回 P2P（预判已被实测否掉，别来回试）
        current = SessionDecision(mode: .srs, codec: decided.codec, reason: "实测非局域网，改走多人线路")
        log("🔧 \(reason) → 本次会话钉住多人线路(SRS)，执行重新协商")
        renegotiationInFlight = true   // §53.20.1：重启后的 decideForPublish 保留钉住状态
        onRenegotiateNeeded?(reason)
    }

    // MARK: - 网段工具（与 P2PManager.§25.7e 同一套算法，避免两份判定打架）

    /// 本机全部 IPv4（WiFi en0 / 热点 bridge100 / 有线等，排除回环与链路本地 169.254.*）
    static func localIPv4Addresses() -> [String] {
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
    static func sharesSubnet(myIps: [String], peerIps: [String]) -> Bool {
        func prefix24(_ ip: String) -> String? {
            let parts = ip.split(separator: ".")
            guard parts.count == 4 else { return nil }
            return parts[0...2].joined(separator: ".")
        }
        let mine = Set(myIps.compactMap(prefix24))
        return peerIps.contains { prefix24($0).map(mine.contains) ?? false }
    }

    private func log(_ msg: String) {
        print("🧭 [链路决策] \(msg)")
    }
}
