import Foundation
import SwiftUI
import VideoToolbox
import WebRTC

// ============================================================================
// H265 (HEVC) P2P 支持 —— 全部 H265 专属逻辑集中在本文件，与既有 H264 链路解耦。
//
// 设计原则（用户要求）：
//   1. 不散落在 WebRTCManager / P2PManager / MonitorLoginView 里，旧类只留一行钩子。
//   2. H265 日志与 H264 完全分开：上报前缀 ios-p2p → ios-p2p-h265（总后台可分开下载）。
//   3. 只对 P2P 生效：SRS / SRT 链路永远 H264，不受本文件影响。
//
// 生效链路：
//   登录页 P2P 芯片下方出现「P2P编码 H264/H265」二级选项（CodecOptionChips）
//   → UserDefaults(p2p_video_codec)
//   → WebRTCManager.factory 创建时 registerFactory() 记下 encoder factory + H264 preferred
//   → startPublish 走 P2P 分支时 applySelectionForP2P()：
//        选 H265 且 SDK 支持 → preferredCodec 切 H265（Offer 里 H265 排第一，H264 保留兜底，
//        PC 不支持 H265 时 SDP 协商自动回落 H264）
//        其它情况 → 恢复 H264 preferred
//   → CONFIG_STATE 上报 videoCodec 字段（PC 据此预建 H265 解码管线）
//
// ⚠️ 依赖：webrtc-sdk（LiveKit fork）144.7559.10 二进制，经 Packages/WebRTC 本地包引入（swift-tools-version:6.2）。
//   stasel/WebRTC 146 无 ObjC H265 编码器；本包与 github.com/webrtc-sdk/Specs 同 xcframework。
// ============================================================================

// MARK: - 编码选项（登录页二级选项）

enum VideoCodecOption: String, CaseIterable {
    case h264 = "h264"
    case h265 = "h265"

    var title: String {
        switch self {
        case .h264: return "H264"
        case .h265: return "H265"
        }
    }

    /// 本地记忆 key（P2P，与 connect_mode 同风格）
    static let storageKey = "p2p_video_codec"
    /// SRS 编码记忆 key（第四十九章新增，默认 h264；与 P2P 独立）
    static let srsStorageKey = "srs_video_codec"
    /// SRT 编码记忆 key（第四十九章新增，默认 h264；与 P2P 独立）
    static let srtStorageKey = "srt_video_codec"

    /// 读取上次选择（⭐ §56.27 默认改回 H264 = 产品默认，与后端部署无关；设备/协商不支持时 applySelectionForP2P 自动回退 H264）
    static var lastSelected: VideoCodecOption {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return VideoCodecOption(rawValue: raw) ?? .h264
    }

    /// 按 key 读取（SRS/SRT 用，默认由调用方给——SRS/SRT 默认 h264）
    static func lastSelected(key: String, defaultCodec: VideoCodecOption) -> VideoCodecOption {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        return VideoCodecOption(rawValue: raw) ?? defaultCodec
    }
}

// MARK: - H265-enabled 编码器工厂
//
// 关键：webrtc-sdk 的 RTCDefaultVideoEncoderFactory.supportedCodecs() 默认「不列出」H265
// （即使 RTCVideoEncoderH265 类存在、设备支持 HEVC 硬编）。而 preferredCodec 只能对
// 「已在 supportedCodecs 里的编码」排序——H265 不在列表里 → preferredCodec=H265 被忽略 →
// Offer 里永远没有 H265。
//
// 解决：子类重写 supportedCodecs()，在设备支持 HEVC 硬编时把 H265 追加进列表。
// 这样 libwebrtc 建 Offer 时会真正列出 H265，并用 createEncoder(H265) → RTCVideoEncoderH265 编码。
// SRS/非 P2P 会话由 preferredCodec=H264 保证 H264 优先，H265 仅作为额外可选项，不影响现网。
final class H265DefaultVideoEncoderFactory: RTCDefaultVideoEncoderFactory {
    override func supportedCodecs() -> [RTCVideoCodecInfo] {
        var codecs = super.supportedCodecs()
        let hasH265 = codecs.contains {
            $0.name.caseInsensitiveCompare("H265") == .orderedSame ||
            $0.name.caseInsensitiveCompare("HEVC") == .orderedSame
        }
        if !hasH265 && H265Support.deviceCanEncodeHEVC() {
            codecs.append(RTCVideoCodecInfo(name: kRTCVideoCodecH265Name))
        }
        return codecs
    }
}

// MARK: - H265 支持核心

final class H265Support: ObservableObject {

    static let shared = H265Support()
    private init() {}

    /// SDK 是否带 H265 编码（registerFactory 时探测一次）
    private(set) var sdkSupportsH265 = false
    /// 当前会话实际生效的编码（推流时定案，供 CONFIG_STATE 上报 + 日志前缀 + 推流页左上角显示）
    @Published private(set) var effectiveCodec: VideoCodecOption = .h264

    /// WebRTCManager.factory 里创建的 encoder factory（弱引用，preferredCodec 可随时改写）
    private weak var encoderFactory: RTCDefaultVideoEncoderFactory?
    /// H264 的 preferred 配置（恢复默认用，由 WebRTCManager 创建时传入）
    private var h264Preferred: RTCVideoCodecInfo?
    /// SDK 里的 H265 codec info（探测缓存）
    private var h265Info: RTCVideoCodecInfo?

    // MARK: 钩子 1：WebRTCManager.factory 创建时调（唯一注册点）

    /// 记录 encoder factory 引用并探测 H265 能力。
    /// 不改变任何默认行为——factory 创建后仍是 H264 preferred。
    func registerFactory(encoder: RTCDefaultVideoEncoderFactory, h264Preferred: RTCVideoCodecInfo?) {
        self.encoderFactory = encoder
        self.h264Preferred = h264Preferred

        let codecs = RTCDefaultVideoEncoderFactory.supportedCodecs()
        let listedH265 = codecs.first(where: Self.isH265CodecName)
        let sdkHasClass = Self.sdkHasH265EncoderClass()
        let hwEnc = Self.deviceSupportsHEVCEncode()

        // webrtc-sdk 144+ 有 RTCVideoEncoderH265，但 supportedCodecs() 仅在硬件可用时才列入 H265。
        // 不能只靠列表探测——需结合 SDK 类 + VideoToolbox 硬编能力，再手动构造 preferredCodec。
        if let listed = listedH265 {
            h265Info = listed
        } else if sdkHasClass, hwEnc {
            h265Info = Self.buildH265CodecInfo()
        } else {
            h265Info = nil
        }
        sdkSupportsH265 = (h265Info != nil)

        let status = sdkSupportsH265 ? "支持✅" : "不支持❌"
        let reason: String
        if sdkSupportsH265 {
            reason = listedH265 != nil ? "listed" : "manual(\(kRTCVideoCodecH265Name))"
        } else if !sdkHasClass {
            reason = "无 RTCVideoEncoderH265（需 Packages/WebRTC webrtc-sdk 144+，非 stasel）"
        } else if !hwEnc {
            reason = "设备 VideoToolbox 无 HEVC 硬编"
        } else {
            reason = "未知"
        }
        h265Log("SDK能力探测: H265编码=\(status) 来源=\(reason) sdkClass=\(sdkHasClass) hwEnc=\(hwEnc) 全部codec=\(codecs.map { $0.name })")
    }

    // MARK: H265 能力探测（webrtc-sdk supportedCodecs 不一定含 H265）

    private static func isH265CodecName(_ info: RTCVideoCodecInfo) -> Bool {
        info.name.caseInsensitiveCompare("H265") == .orderedSame ||
        info.name.caseInsensitiveCompare("HEVC") == .orderedSame ||
        info.name.lowercased().contains("h265") ||
        info.name.lowercased().contains("hevc")
    }

    /// webrtc-sdk 二进制带 ObjC H265 编码器；stasel/Google 预编译包无此类。
    private static func sdkHasH265EncoderClass() -> Bool {
        NSClassFromString("RTCVideoEncoderH265") != nil
    }

    /// 供 H265DefaultVideoEncoderFactory 判断是否追加 H265：SDK 有 H265 编码器类 且 设备能 HEVC 硬编。
    static func deviceCanEncodeHEVC() -> Bool {
        sdkHasH265EncoderClass() && deviceSupportsHEVCEncode()
    }

    /// 创建编码器工厂（H265-enabled 子类）。WebRTCManager 建 factory 时用它替代 RTCDefaultVideoEncoderFactory()。
    static func makeEncoderFactory() -> RTCDefaultVideoEncoderFactory {
        H265DefaultVideoEncoderFactory()
    }

    /// VideoToolbox 是否支持 HEVC 硬件编码（与 WebRTC 内部探测一致）。
    private static func deviceSupportsHEVCEncode() -> Bool {
        var props: CFDictionary?
        let status = VTCopySupportedPropertyDictionaryForEncoder(
            width: 1920,
            height: 1080,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            encoderIDOut: nil,
            supportedPropertiesOut: &props
        )
        return status == noErr
    }

    /// 手动构造 H265 codec info（supportedCodecs 未列出时仍可通过 factory.createEncoder 走 H265）。
    private static func buildH265CodecInfo() -> RTCVideoCodecInfo {
        RTCVideoCodecInfo(name: kRTCVideoCodecH265Name)
    }

    // MARK: 钩子 2'：§53.4-定稿 —— 按 SessionPolicy 定案的编码切换（登录页不再让用户选）

    /// 推流前由 `SessionPolicy` 定案 codec 后调用（P2P / SRS 共用同一套 WebRTC 工厂）。
    ///
    /// 与旧的 `applySelectionForP2P/Srs` 的区别：**不再自己读 UserDefaults 里的用户选择**——
    /// 编码由 SessionPolicy 综合「服务器默认(总后台可配) + 观看端内核能否收 H265 + 本机能否硬编」
    /// 一次算好，这里只负责落到编码器工厂。这样"谁决定编码"只有一个地方，不会两处打架。
    @discardableResult
    func applyDecidedCodec(_ codec: VideoCodecOption, mode: String) -> VideoCodecOption {
        guard let enc = encoderFactory else {
            setEffective(.h264)
            h265Log("⚠️ applyDecidedCodec(\(mode)): encoderFactory 未注册，维持 H264")
            return .h264
        }
        if codec == .h265, sdkSupportsH265, let h265 = h265Info {
            enc.preferredCodec = h265
            setEffective(.h265)
            h265Log("✅ \(mode) preferredCodec → H265(\(h265.name))（定案编码；对端不支持时 SDP 协商自动回落 H264）")
            return .h265
        }
        if let h264 = h264Preferred { enc.preferredCodec = h264 }
        setEffective(.h264)
        if codec == .h265 {
            h265Log("⚠️ \(mode) 定案 H265 但本机不可用（需 webrtc-sdk 144+ 且设备支持 HEVC 硬编），回落 H264")
        } else {
            h265Log("ℹ️ \(mode) 定案 H264")
        }
        return .h264
    }

    // MARK: 钩子 2：startPublish P2P 分支调（每次推流定案）

    /// P2P 推流前按登录页选择切换 preferredCodec。
    /// 返回实际生效编码（选了 H265 但 SDK 不支持时回落 H264 并打日志）。
    @discardableResult
    func applySelectionForP2P() -> VideoCodecOption {
        let selected = VideoCodecOption.lastSelected
        guard let enc = encoderFactory else {
            effectiveCodec = .h264
            h265Log("⚠️ applySelectionForP2P: encoderFactory 未注册，维持 H264")
            return .h264
        }
        if selected == .h265, sdkSupportsH265, let h265 = h265Info {
            enc.preferredCodec = h265
            setEffective(.h265)
            h265Log("✅ P2P preferredCodec → H265(\(h265.name))。Offer 将 H265 优先、H264 兜底（PC 不支持时协商自动回落）")
            return .h265
        } else {
            if let h264 = h264Preferred {
                enc.preferredCodec = h264
            }
            setEffective(.h264)
            if selected == .h265 {
                h265Log("⚠️ 选了 H265 但不可用（需 webrtc-sdk 144+ 且设备支持 HEVC 硬编），回落 H264")
            }
            return .h264
        }
    }

    // MARK: 钩子 3：SRS 分支调（第四十九章：SRS 也可选 H265，默认 h264）

    /// SRS 推流前按登录页「多人编码」选择切 preferredCodec（SRS 与 P2P 同一套 WebRTC 工厂）。
    /// 选 H265 但 SDK/设备不支持时回落 H264。SRS 服务器 6.0.184 已 --h265=on。
    @discardableResult
    func applySelectionForSrs() -> VideoCodecOption {
        let selected = VideoCodecOption.lastSelected(key: VideoCodecOption.srsStorageKey, defaultCodec: .h264)
        guard let enc = encoderFactory else {
            setEffective(.h264)
            h265Log("⚠️ applySelectionForSrs: encoderFactory 未注册，维持 H264")
            return .h264
        }
        if selected == .h265, sdkSupportsH265, let h265 = h265Info {
            enc.preferredCodec = h265
            setEffective(.h265)
            h265Log("✅ SRS preferredCodec → H265(\(h265.name))。WHIP Offer H265 优先，SRS 6.0.184 回 H265")
            return .h265
        } else {
            if let h264 = h264Preferred { enc.preferredCodec = h264 }
            setEffective(.h264)
            if selected == .h265 { h265Log("⚠️ SRS 选 H265 但不可用，回落 H264") }
            return .h264
        }
    }

    // MARK: 钩子 3b：SRT 分支调（HaishinKit/VideoToolbox，不走 WebRTC 工厂）

    /// SRT 只定 effectiveCodec 供上报；实际编码由 SRTManager 读 srtWantsH265() 设 profileLevel（HEVC/H264）。
    /// ⭐ 2026-07-24 SRT 强制 H264：服务器 SRS 6.0.184 的 RTMP→RTC 桥接源码写死丢弃 HEVC
    ///（srs_app_rtc_source.cpp:1074 "WebRTC does NOT support HEVC"），SRT+H265 必黑屏。
    ///   登录页 SRT 编码选项已同步隐藏；这里兜底忽略历史存储的 h265 偏好。
    ///   服务器升 SRS 7.0.33+（rtmp2rtc 支持 HEVC）后，恢复读 srtStorageKey 即可。
    @discardableResult
    func applySelectionForSrt() -> VideoCodecOption {
        setEffective(.h264)
        return effectiveCodec
    }

    /// SRTManager 读取：SRT 本次会话是否用 HEVC 编码（服务器桥不支持 HEVC，恒 false，见上）
    func srtWantsH265() -> Bool {
        return false
    }

    // MARK: 兼容保留

    /// 非 P2P 链路恢复 H264 preferred（历史接口，个别路径仍可能调用）
    func forceH264ForNonP2P() {
        if let enc = encoderFactory, let h264 = h264Preferred {
            enc.preferredCodec = h264
        }
        setEffective(.h264)
    }

    /// @Published 必须在主线程改（SwiftUI 刷新左上角编码显示）
    private func setEffective(_ codec: VideoCodecOption) {
        if Thread.isMainThread {
            effectiveCodec = codec
        } else {
            DispatchQueue.main.async { [weak self] in self?.effectiveCodec = codec }
        }
    }

    // MARK: 钩子 6：用「实际生成的 Offer SDP」校准生效编码（防止 claim H265 但 SDP 里根本没有）

    /// P2P 创建 Offer 后调用：核对 Offer 里是否真含 H265。
    ///   - 若声称 H265 但 SDP 无 H265（本机 SDK/设备实际不能编码 H265）→ 如实降级 h264，
    ///     使 CONFIG_STATE 上报 h264、PC 建 H264 管线，画面退化为 H264 而不是黑屏死循环。
    ///   - 返回 Offer 里是否真的含 H265。
    @discardableResult
    func reconcileFromOfferSdp(_ sdp: String) -> Bool {
        let hasH265 = sdp.range(of: "H265", options: .caseInsensitive) != nil
                   || sdp.range(of: "HEVC", options: .caseInsensitive) != nil
        if effectiveCodec == .h265 && !hasH265 {
            h265Log("⚠️ 声称 H265 但 Offer SDP 里无 H265 → 本机实际不能编码 H265，如实降级为 H264（PC 将建 H264 管线，画面正常）")
            setEffective(.h264)
        }
        return hasH265
    }

    // MARK: 钩子 4：CONFIG_STATE 上报（PC 据此预建解码管线）

    /// 当前会话是否 H265（P2PManager 判断用）
    func isH265Session() -> Bool { effectiveCodec == .h265 }

    /// CONFIG_STATE.state.videoCodec 字段值（"h264" / "h265"）
    var effectiveCodecString: String { effectiveCodec.rawValue }

    // MARK: 钩子 5：日志前缀（H265 日志与 H264 完全分开，总后台分文件落盘）

    /// P2PLogReporter 上报前缀：H265 会话 → base-h265（如 ios-p2p-h265），H264 原样
    func logUploadPrefix(base: String) -> String {
        effectiveCodec == .h265 ? base + "-h265" : base
    }

    // MARK: H265 专属打印（带 [H265] 标记，P2PLogReporter 关键词可捕获）

    func h265Log(_ msg: String) {
        print("🎞️ [H265] \(msg)")
    }
}

// MARK: - 登录页二级选项 UI（P2P 选中时才显示）

/// 「P2P编码」H264/H265 二选一芯片行。样式对齐登录页连接方式芯片。
/// 放本文件而非 MonitorLoginView，保持 H265 相关 UI 与旧登录页解耦。
struct CodecOptionChips: View {
    @Binding var selected: VideoCodecOption
    /// 存储 key（P2P=p2p_video_codec / SRS=srs_video_codec / SRT=srt_video_codec）
    var storageKey: String = VideoCodecOption.storageKey
    /// 标题文案（P2P编码/多人编码/SRT编码）
    var title: String = "P2P编码"

    var body: some View {
        HStack(spacing: 6) {
            // 图标（与连接方式行同风格）
            ZStack {
                Circle()
                    .stroke(Color(hex: "B3B3B3"), lineWidth: 0.6)
                    .frame(width: 20, height: 20)
                Image(systemName: "film")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "1A1A1A"))
            }
            .frame(width: 24, height: 24)

            Text(title)
                .font(.system(size: 16))
                .foregroundColor(Color(hex: "1A1A1A"))

            Spacer()

            HStack(spacing: 8) {
                ForEach(VideoCodecOption.allCases, id: \.self) { codec in
                    chip(codec)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func chip(_ codec: VideoCodecOption) -> some View {
        let isSelected = (selected == codec)
        Button(action: {
            selected = codec
            UserDefaults.standard.set(codec.rawValue, forKey: storageKey)
        }) {
            Text(codec.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : Color(hex: "65AEF7"))
                .frame(minWidth: 44)
                .padding(.vertical, 6)
                .background(isSelected ? Color(hex: "65AEF7") : Color(hex: "EAF4FE"))
                .cornerRadius(6)
        }
    }
}
