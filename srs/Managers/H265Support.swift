import Foundation
import SwiftUI
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
// ⚠️ 依赖：stasel/WebRTC SPM ≥ 146.0.0 才带 H265 编解码（M140 无）。
//   已在 project.pbxproj 把 minimumVersion 提到 146.0.0，Mac 上需 Resolve Packages。
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

    /// 本地记忆 key（与 connect_mode 同风格）
    static let storageKey = "p2p_video_codec"

    /// 读取上次选择（无则默认 H264，与现网行为一致）
    static var lastSelected: VideoCodecOption {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return VideoCodecOption(rawValue: raw) ?? .h264
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
        h265Info = codecs.first(where: {
            $0.name.caseInsensitiveCompare("H265") == .orderedSame ||
            $0.name.lowercased().contains("h265") ||
            $0.name.lowercased().contains("hevc")
        })
        sdkSupportsH265 = (h265Info != nil)
        h265Log("SDK能力探测: H265编码=\(sdkSupportsH265 ? "支持✅" : "不支持❌(需 stasel/WebRTC ≥146)") 全部codec=\(codecs.map { $0.name })")
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
                h265Log("⚠️ 选了 H265 但 SDK 不支持（WebRTC <146?），回落 H264")
            }
            return .h264
        }
    }

    // MARK: 钩子 3：SRS/SRT 分支调（非 P2P 永远 H264）

    /// 非 P2P 链路恢复 H264 preferred（SRS/SRT 不支持 H265，行为与现网完全一致）
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

    // MARK: 钩子 4：CONFIG_STATE 上报（PC 据此预建解码管线）

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

            Text("P2P编码")
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
            UserDefaults.standard.set(codec.rawValue, forKey: VideoCodecOption.storageKey)
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
