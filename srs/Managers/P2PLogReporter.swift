import Foundation

/// P2P 诊断日志上报器（第二十二章）
///
/// 总后台「P2P日志」开关打开时，把本进程 stdout（print 输出）tee 一份，
/// 按关键词过滤出 P2P 相关诊断行，批量上报到后端，按推流ID分流落盘，
/// 供总后台下载离线排查卡顿。
///
/// - 前缀固定 "ios-p2p"；streamId = 推流ID（streamKey）
/// - 开关：GET /api/p2plog/config（活跃期间每 60s 复查；关闭时零上报、stdout 不重定向）
/// - 上报：POST /api/p2plog/upload（每 10s 批量一次，单批上限 256KB）
/// - 采集方式 = dup2 管道 tee stdout：所有 print 原样写回原 stdout（Xcode 控制台不受影响），
///   同时按 captureKeywords 过滤缓冲。不改动任何既有 print 调用点。
/// - 推流开始（streamKey 生成后）start，停流 stop。
final class P2PLogReporter {

    static let shared = P2PLogReporter()
    private init() {}

    private let prefix = "ios-p2p"
    private let flushInterval: TimeInterval = 10
    private let configInterval: TimeInterval = 60
    private let maxBatchBytes = 256 * 1024
    private let maxBufferLines = 5000

    /// 只上报含这些关键词的行（P2P/自适应/推流诊断），防止把 UI 等无关 print 全灌上去
    private let captureKeywords = [
        "P2P", "p2p", "malvshezhing", "[自适应]", "ICE", "candidate",
        "Offer", "Answer", "offer", "answer", "关键帧", "PLI", "IDR",
        "推流", "码率", "fps", "FPS", "WEBRTC", "🔑", "🚑", "热点", "relay", "TURN",
        "H265", "h265", "HEVC",  // ⭐ H265 专属诊断行（H265Support.swift 的 h265Log）
        // ⭐ §53.14：SRS 与采集侧的诊断此前**不在白名单里**，导致「SRS 首连不出画面」
        //   「每几秒卡一次」这两类线索根本传不上来（除非那行恰好含"推流/fps/码率"）。
        "SRS", "srs", "采集", "预览", "首帧", "中断", "健康检查", "链路决策", "会话"
    ]

    private var timerQueue = DispatchQueue(label: "p2plog.reporter")
    private var flushTimer: DispatchSourceTimer?
    private var configTimer: DispatchSourceTimer?

    private var buffer = ""
    private var bufferLines = 0
    private let lock = NSLock()

    private var active = false
    private var enabled = false
    private var streamId = ""

    // stdout tee
    private var pipe: Pipe?
    private var originalStdoutFD: Int32 = -1
    private var lineRemainder = ""

    // MARK: - 生命周期（推流开始/结束时由 WebRTCManager 调）

    func start(streamId: String) {
        timerQueue.async { [weak self] in
            guard let self = self else { return }
            self.streamId = streamId
            guard !self.active else { return }
            self.active = true
            print("📤 [P2P日志上报] 启动 streamId=\(streamId)（等服务器开关）")

            self.checkConfig()

            let cfg = DispatchSource.makeTimerSource(queue: self.timerQueue)
            cfg.schedule(deadline: .now() + self.configInterval, repeating: self.configInterval)
            cfg.setEventHandler { [weak self] in self?.checkConfig() }
            cfg.resume()
            self.configTimer = cfg

            let fl = DispatchSource.makeTimerSource(queue: self.timerQueue)
            fl.schedule(deadline: .now() + self.flushInterval, repeating: self.flushInterval)
            fl.setEventHandler { [weak self] in self?.flush() }
            fl.resume()
            self.flushTimer = fl
        }
    }

    func stop() {
        timerQueue.async { [weak self] in
            guard let self = self, self.active else { return }
            self.flush()
            self.active = false
            self.stopTee()
            self.configTimer?.cancel(); self.configTimer = nil
            self.flushTimer?.cancel(); self.flushTimer = nil
        }
    }

    // MARK: - 开关

    private func checkConfig() {
        guard active else { return }
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/p2plog/config") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let newEnabled = (obj["enabled"] as? Bool) ?? false
            self.timerQueue.async {
                guard self.active else { return }
                // ⭐ 幂等自愈（修「第一次能上报、重新推流后不上报」，与 Android 端同款 bug）：
                //   单例 stop() 停掉 stdout tee 后 enabled 仍是 true；第二次 start() 时开关值
                //   无变化，旧逻辑只在「值变化」时才 startTee → tee 永远没人重启。
                //   现改为：只要开关=开就确保 tee 在跑（startTee 自带 pipe==nil 幂等保护）。
                self.enabled = newEnabled
                if newEnabled {
                    self.startTee()
                } else {
                    self.stopTee()
                    self.lock.lock(); self.buffer = ""; self.bufferLines = 0; self.lock.unlock()
                }
            }
        }.resume()
    }

    // MARK: - stdout tee（所有 print 原样回写原 stdout，同时过滤缓冲）

    private func startTee() {
        guard pipe == nil else { return }
        let p = Pipe()
        originalStdoutFD = dup(STDOUT_FILENO)          // 保留原 stdout
        dup2(p.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        setvbuf(stdout, nil, _IOLBF, 0)                // 行缓冲，print 即时进管道
        pipe = p

        p.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // 1) 原样回写原 stdout（Xcode 控制台/设备日志不受影响）
            if self.originalStdoutFD >= 0 {
                data.withUnsafeBytes { raw in
                    _ = write(self.originalStdoutFD, raw.baseAddress, raw.count)
                }
            }
            // 2) 按行过滤缓冲
            guard let text = String(data: data, encoding: .utf8) else { return }
            self.consume(text: text)
        }
        print("📤 [P2P日志上报] stdout tee 已开启（服务器开关=开）")
    }

    private func stopTee() {
        guard let p = pipe else { return }
        p.fileHandleForReading.readabilityHandler = nil
        if originalStdoutFD >= 0 {
            dup2(originalStdoutFD, STDOUT_FILENO)      // 还原 stdout
            close(originalStdoutFD)
            originalStdoutFD = -1
        }
        try? p.fileHandleForWriting.close()
        try? p.fileHandleForReading.close()
        pipe = nil
        lineRemainder = ""
    }

    private func consume(text: String) {
        let combined = lineRemainder + text
        var lines = combined.components(separatedBy: "\n")
        lineRemainder = lines.removeLast()             // 最后一段可能是半行，留到下批
        guard !lines.isEmpty else { return }

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        let ts = fmt.string(from: Date())

        lock.lock()
        defer { lock.unlock() }
        for line in lines {
            guard !line.isEmpty, bufferLines < maxBufferLines else { continue }
            guard captureKeywords.contains(where: { line.contains($0) }) else { continue }
            buffer += "[\(ts)] \(line)\n"
            bufferLines += 1
        }
    }

    // MARK: - 上报

    private func flush() {
        guard enabled else { return }
        lock.lock()
        guard !buffer.isEmpty else { lock.unlock(); return }
        var content = buffer
        buffer = ""
        bufferLines = 0
        lock.unlock()

        if content.utf8.count > maxBatchBytes {
            content = String(content.suffix(maxBatchBytes / 2))   // 超限只留最新
        }

        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/p2plog/upload") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // ⭐ H265：H265 会话日志与 H264 分开（前缀 ios-p2p → ios-p2p-h265，总后台分文件下载）
        let effectivePrefix = H265Support.shared.logUploadPrefix(base: prefix)
        let body: [String: Any] = [
            "prefix": effectivePrefix,
            "streamId": streamId.isEmpty ? "unknown" : streamId,
            "content": content
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            // 服务端已关闭开关 → 本地同步关（等下轮 config 复查再开）
            if let en = obj["enabled"] as? Bool, en == false {
                self.timerQueue.async {
                    self.enabled = false
                    self.stopTee()
                }
            }
        }.resume()
    }
}
