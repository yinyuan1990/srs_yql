//
//  SrtDirectParams.swift
//  srs
//
//  SRT直推编码/传输参数（契约 `srtParams`，与 Android srtapp SrtDirectParams.kt 一致）。
//
//  生效值 = 内置默认 ⊕ 登录下发（整份覆盖）⊕ STOMP `ptype=srt_params`（只带改动项，增量合并）。
//  结构：
//  { presets: { low|standard|high|ultra|p4k|srt2k|srt4k: {width,height,fps,bitrateKbps, …可选覆盖任意全局键} },
//    bitrateMode:1(VBR)/2(CBR), qpIMin, qpIMax, qpPMin, qpPMax, gopSec, latencyMs, maxBwKbps(0=不限),
//    peakKbps, peakCtrl:{enable,qpStep,qpCeil,holdSec,recoverSec}, disableStabilization }
//  档位里可再带 peakKbps/latencyMs/gopSec/qp* 等，覆盖全局值。
//

import Foundation

enum SrtDirectParams {
    static let defaultHost = "118.178.33.144"
    static let defaultPort = 8890

    static let profiles = ["p1440", "low", "standard", "high", "ultra", "p4k", "srt2k", "srt4k"]

    private static let overrideKey = "srt_direct_override_json"
    private static let loginKey = "srt_direct_login_json"   // 登录下发的原样一份（PC「恢复默认」时回到它）
    private static let hostKey = "srt_direct_host"
    private static let portKey = "srt_direct_port"

    private static let defaultJSON = """
    {
      "presets": {
        "low":      {"width":640, "height":480, "fps":25,"bitrateKbps":1500},
        "standard": {"width":1024,"height":768, "fps":25,"bitrateKbps":2500},
        "high":     {"width":1440,"height":1080,"fps":25,"bitrateKbps":4500},
        "ultra":    {"width":1280,"height":720, "fps":50,"bitrateKbps":4000},
        "p4k":      {"width":1920,"height":1080,"fps":25,"bitrateKbps":5000},
        "p1440":    {"width":1920,"height":1440,"fps":25,"bitrateKbps":6000},
        "srt2k":    {"width":2560,"height":1440,"fps":25,"bitrateKbps":10000,"peakKbps":16000},
        "srt4k":    {"width":3840,"height":2160,"fps":25,"bitrateKbps":16000,
                     "peakKbps":24000,"latencyMs":1000,"gopSec":3,"qpPMin":25,"qpPMax":34}
      },
      "bitrateMode": 1,
      "qpIMin": 22, "qpIMax": 30, "qpPMin": 24, "qpPMax": 33,
      "gopSec": 2, "latencyMs": 800, "maxBwKbps": 0, "peakKbps": 14000,
      "peakCtrl": {"enable": true, "qpStep": 2, "qpCeil": 38, "holdSec": 2, "recoverSec": 5},
      "disableStabilization": true
    }
    """

    /// 解析后的一套参数（档位已与全局合并）
    struct Plan: Equatable {
        let profile: String
        let width: Int
        let height: Int
        let fps: Int
        let bitrateKbps: Int
        let bitrateMode: Int
        let qpIMin: Int
        let qpIMax: Int
        let qpPMin: Int
        let qpPMax: Int
        let gopSec: Int
        let latencyMs: Int
        let maxBwKbps: Int
        let peakKbps: Int
        let peakEnable: Bool
        let qpStep: Int
        let qpCeil: Int
        let holdSec: Int
        let recoverSec: Int
        let disableStabilization: Bool

        func describe() -> String {
            "\(profile) \(width)x\(height)@\(fps) \(bitrateKbps)kbps \(bitrateMode == 2 ? "CBR" : "VBR")" +
            " QP I\(qpIMin)~\(qpIMax) P\(qpPMin)~\(qpPMax) GOP\(gopSec)s 延迟\(latencyMs)ms" +
            " 限速\(maxBwKbps > 0 ? "\(maxBwKbps)kbps" : "不限") 峰值\(peakKbps)kbps" +
            " 峰值控制\(peakEnable ? "开(步长\(qpStep) 封顶\(qpCeil) 持续\(holdSec)s 回落\(recoverSec)s)" : "关")" +
            " 关防抖=\(disableStabilization)"
        }
    }

    private static let lock = NSLock()
    private static var overrideCache: [String: Any]?

    private static func loadOverrideLocked() -> [String: Any] {
        if let c = overrideCache { return c }
        var o: [String: Any] = [:]
        if let s = UserDefaults.standard.string(forKey: overrideKey), let d = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            o = obj
        }
        overrideCache = o
        return o
    }

    private static func persistLocked(_ o: [String: Any]) {
        overrideCache = o
        if JSONSerialization.isValidJSONObject(o),
           let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: overrideKey)
        }
    }

    /// 登录下发：整份替换覆盖项（nil/非对象 = 回内置默认）
    static func saveFromLogin(_ raw: Any?) {
        let o = (raw as? [String: Any]) ?? [:]
        lock.lock(); persistLocked(o); lock.unlock()
        if JSONSerialization.isValidJSONObject(o),
           let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: loginKey)
        }
        SdLog.i("登录下发 srtParams \(o.isEmpty ? "无（用内置默认）" : "已保存 \(String(describing: o).prefix(300))")")
    }

    /// PC「恢复默认」：丢掉 PC 临时改的（QP / 延迟等），回到登录下发的总后台值。没存过登录值返回 false
    @discardableResult
    static func resetToLogin() -> Bool {
        guard let s = UserDefaults.standard.string(forKey: loginKey), let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        lock.lock(); persistLocked(o); lock.unlock()
        return true
    }

    /// 总后台「保存并下发」（srt_params 带 replace=true）：整份替换，后台清空的键（降噪 / 档位单独值）才能回默认；
    /// 同时作为 PC「恢复默认」的基准（原来只有登录时才更新基准）
    static func replaceFromAdmin(_ params: [String: Any]) {
        lock.lock(); persistLocked(params); lock.unlock()
        if JSONSerialization.isValidJSONObject(params),
           let d = try? JSONSerialization.data(withJSONObject: params), let s = String(data: d, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: loginKey)
        }
    }

    /// STOMP `ptype=srt_params`：增量合并（只带改动项）
    static func mergeRemote(_ patch: [String: Any]) {
        lock.lock()
        let merged = deepMerge(loadOverrideLocked(), patch)
        persistLocked(merged)
        lock.unlock()
    }

    /// 登录下发的 srtServer {host, port}；缺省则清掉，回默认节点
    static func saveServer(_ raw: Any?) {
        let d = UserDefaults.standard
        let s = raw as? [String: Any]
        let host = (s?["host"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let port = (s?["port"] as? NSNumber)?.intValue ?? Int((s?["port"] as? String) ?? "") ?? 0
        if host.isEmpty { d.removeObject(forKey: hostKey) } else { d.set(host, forKey: hostKey) }
        if port <= 0 || port > 65535 { d.removeObject(forKey: portKey) } else { d.set(port, forKey: portKey) }
    }

    /// 单帧降噪 0~1（总后台「参数设置」/ PC「SRT设置」，没配 = nil 不降噪）；iOS 用 CoreImage CINoiseReduction（只处理单帧）
    static var noiseReduction: Float? {
        lock.lock()
        let v = loadOverrideLocked()["noiseReduction"]
        lock.unlock()
        // PC「默认」发 -1
        if let n = v as? NSNumber { return n.floatValue < 0 ? nil : min(1, n.floatValue) }
        if let s = v as? String, let d = Float(s) { return d < 0 ? nil : min(1, d) }
        return nil
    }

    static var serverHost: String {
        let h = UserDefaults.standard.string(forKey: hostKey) ?? ""
        return h.isEmpty ? defaultHost : h
    }

    static var serverPort: Int {
        let p = UserDefaults.standard.integer(forKey: portKey)
        return (1...65535).contains(p) ? p : defaultPort
    }

    /// 某档位的生效参数
    static func plan(_ profile: String) -> Plan {
        lock.lock()
        let override = loadOverrideLocked()
        lock.unlock()
        var def: [String: Any] = [:]
        if let d = defaultJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            def = obj
        }
        let eff = deepMerge(def, override)
        let presets = (eff["presets"] as? [String: Any]) ?? [:]
        let key = presets[profile] is [String: Any] ? profile : "standard"
        let pre = (presets[key] as? [String: Any]) ?? [:]

        func num(_ dict: [String: Any], _ name: String) -> Int? {
            if let n = dict[name] as? NSNumber { return n.intValue }
            if let s = dict[name] as? String { return Int(s) }
            return nil
        }
        func boolVal(_ dict: [String: Any], _ name: String) -> Bool? {
            if let b = dict[name] as? Bool { return b }
            if let n = dict[name] as? NSNumber { return n.intValue != 0 }
            if let s = dict[name] as? String { return s.lowercased() == "true" || s == "1" }
            return nil
        }
        // 档位里的同名键覆盖全局
        func int(_ name: String, _ def: Int) -> Int { num(pre, name) ?? num(eff, name) ?? def }
        func bool(_ name: String, _ def: Bool) -> Bool { boolVal(pre, name) ?? boolVal(eff, name) ?? def }
        func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), max(lo, hi)) }

        var pc = (eff["peakCtrl"] as? [String: Any]) ?? [:]
        if let prePc = pre["peakCtrl"] as? [String: Any] { pc = deepMerge(pc, prePc) }

        let qpIMin = clamp(int("qpIMin", 22), 0, 51)
        let qpPMin = clamp(int("qpPMin", 24), 0, 51)
        return Plan(
            profile: key,
            width: clamp(num(pre, "width") ?? 1920, 160, 7680),
            height: clamp(num(pre, "height") ?? 1080, 120, 4320),
            fps: clamp(num(pre, "fps") ?? 25, 5, 60),
            bitrateKbps: clamp(num(pre, "bitrateKbps") ?? 8000, 300, 80000),
            bitrateMode: int("bitrateMode", 1) == 2 ? 2 : 1,
            qpIMin: qpIMin,
            qpIMax: clamp(int("qpIMax", 30), qpIMin, 51),
            qpPMin: qpPMin,
            qpPMax: clamp(int("qpPMax", 33), qpPMin, 51),
            gopSec: clamp(int("gopSec", 2), 1, 10),
            latencyMs: clamp(int("latencyMs", 800), 80, 5000),
            maxBwKbps: clamp(int("maxBwKbps", 0), 0, 200000),
            peakKbps: clamp(int("peakKbps", 14000), 0, 200000),
            peakEnable: boolVal(pc, "enable") ?? true,
            qpStep: clamp(num(pc, "qpStep") ?? 2, 1, 10),
            qpCeil: clamp(num(pc, "qpCeil") ?? 38, 0, 51),
            holdSec: clamp(num(pc, "holdSec") ?? 2, 1, 30),
            recoverSec: clamp(num(pc, "recoverSec") ?? 5, 1, 120),
            disableStabilization: bool("disableStabilization", true)
        )
    }

    /// 对象逐键递归合并；非对象值直接覆盖
    private static func deepMerge(_ base: [String: Any], _ patch: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in patch {
            if let pv = v as? [String: Any], let bv = out[k] as? [String: Any] {
                out[k] = deepMerge(bv, pv)
            } else {
                out[k] = v
            }
        }
        return out
    }
}
