//
//  SrtLogReporter.swift
//  srs
//
//  SRT直推诊断日志上报（总后台「SRT管理 → SRT日志」开关；与 P2P 日志开关互相独立），照 Android SrtLogReporter.kt：
//  - 内容：SdLog 的全部行（引擎每秒统计：采集/编码/SRT 发送/RTT/丢包/峰值控制、曝光、重连…）；
//  - 前缀 "iOS-srt"；streamId = 推流ID（与 PC 拉流端 pc-srt 同目录）；
//  - 开关：GET /api/srtlog/config（推流期间每 60s 复查）；关 → 不缓冲、不上传；
//  - 上报：POST /api/srtlog/upload（每 10s 一批，单批上限 256KB）。
//

import Foundation
import UIKit

/// SRT直推日志：控制台 + SrtLogReporter 缓冲
enum SdLog {
    static func i(_ msg: String) {
        print("[SRT直推] \(msg)")
        SrtLogReporter.shared.line(msg)
    }

    static func w(_ msg: String) {
        print("[SRT直推] ⚠️ \(msg)")
        SrtLogReporter.shared.line("⚠️ \(msg)")
    }

    /// streamid 里的 token 不落日志
    static func maskStreamId(_ sid: String) -> String {
        let parts = sid.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return sid }
        return parts.prefix(3).joined(separator: ":") + ":***"
    }
}

final class SrtLogReporter {
    static let shared = SrtLogReporter()
    private init() {}

    private let prefix = "iOS-srt"
    private let flushInterval: TimeInterval = 10
    private let configInterval: TimeInterval = 60
    private let maxBatchBytes = 256 * 1024
    private let maxBufferChars = 1_000_000

    private let queue = DispatchQueue(label: "srtlog.reporter")
    private var flushTimer: DispatchSourceTimer?
    private var configTimer: DispatchSourceTimer?

    private let lock = NSLock()
    private var buffer = ""
    private var active = false
    private var enabled = false
    private var configKnown = false
    private var streamId = ""
    private var username = ""

    private let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// 开始推流（SRT直推）时调用
    func start(streamId newStreamId: String, account: String) {
        lock.lock()
        streamId = newStreamId
        username = account
        let wasActive = active
        active = true
        if !wasActive { configKnown = false }
        lock.unlock()
        if wasActive { return }
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        line("==== 推流开始 流=\(newStreamId) 账号=\(account) 机型=\(Self.machineModel()) iOS\(UIDevice.current.systemVersion) App=\(ver) ====")
        queue.async { [weak self] in
            guard let self else { return }
            self.checkConfig()
            let cfg = DispatchSource.makeTimerSource(queue: self.queue)
            cfg.schedule(deadline: .now() + self.configInterval, repeating: self.configInterval)
            cfg.setEventHandler { [weak self] in self?.checkConfig() }
            cfg.resume()
            self.configTimer = cfg
            let fl = DispatchSource.makeTimerSource(queue: self.queue)
            fl.schedule(deadline: .now() + self.flushInterval, repeating: self.flushInterval)
            fl.setEventHandler { [weak self] in self?.flush(force: false) }
            fl.resume()
            self.flushTimer = fl
        }
    }

    /// 停止推流时调用：最后一批冲刷后停
    func stop() {
        lock.lock()
        let wasActive = active
        lock.unlock()
        guard wasActive else { return }
        line("==== 推流结束 ====")
        lock.lock(); active = false; lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.configTimer?.cancel(); self.configTimer = nil
            self.flushTimer?.cancel(); self.flushTimer = nil
            self.flush(force: true)
        }
    }

    /// 线程安全：缓冲一行（未激活 / 已确认开关关 → 直接丢）
    func line(_ msg: String) {
        lock.lock()
        defer { lock.unlock() }
        guard active, !(configKnown && !enabled), buffer.utf16.count <= maxBufferChars else { return }
        buffer += "[\(tsFormatter.string(from: Date()))] \(msg)\n"
    }

    private func checkConfig() {
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/srtlog/config") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self, let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let newEnabled = (obj["enabled"] as? Bool) ?? false
            self.lock.lock()
            self.enabled = newEnabled
            self.configKnown = true
            if !newEnabled { self.buffer = "" }
            self.lock.unlock()
        }.resume()
    }

    private func flush(force: Bool) {
        lock.lock()
        guard enabled, active || force, !buffer.isEmpty else { lock.unlock(); return }
        var content = buffer
        buffer = ""
        let sid = streamId
        let user = username
        lock.unlock()

        if content.utf8.count > maxBatchBytes {
            content = String(content.suffix(maxBatchBytes / 3))   // 超限只留最新
        }
        guard let url = URL(string: "\(APIConfig.shared.baseURL)/api/srtlog/upload") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "prefix": prefix,
            "streamId": sid.isEmpty ? "unknown" : sid,
            "username": user,
            "content": content
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let en = obj["enabled"] as? Bool, en == false {
                self.lock.lock(); self.enabled = false; self.lock.unlock()
            }
        }.resume()
    }

    private static func machineModel() -> String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        return mirror.children.reduce("") { acc, el in
            guard let v = el.value as? Int8, v != 0 else { return acc }
            return acc + String(UnicodeScalar(UInt8(v)))
        }
    }
}
