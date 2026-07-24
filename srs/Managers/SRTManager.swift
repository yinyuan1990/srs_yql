//
//  SRTManager.swift
//  srs
//
//  ★ 第三条独立推流链路：SRT（Secure Reliable Transport）
//
//  解耦红线（务必遵守）：
//  - 本文件完全独立，绝不 import / 引用 SRSManager、P2PManager。
//  - 与 SRS / P2P 是「兄弟」关系，不是「改造」关系。
//  - 删除本文件 + WebRTCManager 里的 `// MARK: - SRT (independent)` 分区，即可完全回退到现状。
//
//  方案 A（当前阶段）：iOS 用 SRT 把「滤镜后帧」推到 SRS 的 srt_server，
//  SRS 内部 srt_to_rtmp + rtmp_to_rtc 桥接成 WebRTC，PC 仍走现有 webrtcbin 拉流（PC 零改动）。
//
//  依赖：HaishinKit.swift（含 SRTHaishinKit 模块，内置 libsrt + MPEG-TS 打包）
//  通过 SPM 引入：https://github.com/shogo4405/HaishinKit.swift
//
//  ⚠️ 若工程尚未添加 HaishinKit 包，本文件会编译失败（import 找不到）。
//     先在 Xcode → Package Dependencies 添加该包并 Build 通过后再用。
//

import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
import VideoToolbox
import HaishinKit
import SRTHaishinKit

/// SRT 推流管理器（独立链路）。
///
/// 用法（在 WebRTCManager 的 SRT 分区里调用，见 `startSRTPublish`）：
/// 1. `let srt = SRTManager()`
/// 2. `srt.start(ip: <stream_push_ip>, streamKey: <streamKey>)`
/// 3. 每一「滤镜后帧」调用 `srt.appendVideoFrame(pixelBuffer:timeStampNs:)`
/// 4. 结束时 `srt.stop()`
final class SRTManager {

    // MARK: - 对外状态

    /// 是否正在推流（已 connect 且 publish）。
    private(set) var isPublishing: Bool = false

    /// 失败回调（主线程）。reason 为人类可读原因。
    var onFailure: ((_ reason: String) -> Void)?

    /// 状态变化回调（主线程）。
    var onStateChange: ((_ isPublishing: Bool) -> Void)?

    /// 统计/网络采样回调（主线程，每秒一次）。
    /// 解耦：SRTManager 不直接引用 WebSocketManager / 自适应逻辑，
    /// 由 WebRTCManager 在回调里转写上报字段并驱动自适应（与 SRS/P2P 同一套策略）。
    /// - pushFps: 本秒实际喂入 SRT 的帧数（= 推送 fps）。
    /// - kbps: 真实发送码率（取自 libsrt mbpsSendRate；拿不到时回退目标码率）。
    /// - rttMs: SRT 链路 RTT（毫秒）。
    /// - lossRate: 本秒发送丢包率（0~1，按发送/丢包计数增量算）。
    /// - lossPerSec: 本秒发送丢包数。
    var onSample: ((_ pushFps: Int, _ kbps: Int, _ rttMs: Int, _ lossRate: Double, _ lossPerSec: Int) -> Void)?

    /// 目标码率（kbps），由 WebRTCManager 注入当前档位/清晰度对应的目标码率。
    /// SRT 链路无 WebRTC stats，故用目标码率作为上报近似（与发送字节统计择优）。
    var targetBitrateKbps: Int = 0

    // MARK: - 编码参数（分辨率/帧率，由 WebRTCManager 按档位注入）

    /// ⭐ 2026-06-24 修复「SRT 分辨率永远 854x480」：
    ///   HaishinKit 自带 H.264 编码器的默认 VideoCodecSettings 写死 videoSize=854x480、
    ///   bitRate=640k、scalingMode=.trim，且本链路从未调用 setVideoSettings，
    ///   所以无论喂入多大的帧，编码器都强制缩放裁剪到 854x480。
    ///   P2P/SRS 走 WebRTC 自己的编码器（按档位配置），故不受影响 → 三链路看似解耦，
    ///   实则 SRT 缺了「按档位配置编码器」这一步。
    ///   解法：WebRTCManager 按 getCaptureResolutionForProfile 注入分辨率/帧率/码率，
    ///   publish 前应用一次，运行中（档位/清晰度变化）再持续同步。
    private var encWidth: Int = 1280
    private var encHeight: Int = 720
    private var encFps: Int = 30

    // MARK: - 统计（fps 实测 + 码率近似）

    /// 本统计窗口内实际喂入 SRT 的帧数（用 statLock 保护）。
    private var statFrameCount: Int = 0
    private let statLock = NSLock()
    /// 每秒统计定时器（主队列）。
    private var statsTimer: DispatchSourceTimer?
    /// 上次采样的累计发送包数 / 累计发送丢包数（用于按增量算每秒丢包率）。
    private var lastPktSentTotal: Int64 = 0
    private var lastPktSndLossTotal: Int32 = 0

    // MARK: - 连接参数（方案 A：端口写死，IP 复用登录返回的 stream_push_ip）

    /// SRT 服务端口（与 SRS srt_server listen 对齐，默认 10080）。
    static let defaultSRTPort: Int = 10080
    /// SRT app（与 SRS default_app / streamid r=<app>/<stream> 对齐）。
    /// ⭐ 2026-06-24 修复「SRT 模式 PC/网页内核出不来画面」：
    ///   方案A 下 PC/网页内核走 WHEP 从 app=`tenantA` 拉流（与 SRS 模式同命名空间），
    ///   但 SRT 原来落在 app=`live` → app 对不上、SRS 找不到流 → 两个内核都出不来。
    ///   streamKey 本就与 SRS 一致，只差 app 名。改成 `tenantA` 即与 SRS/PC 完全同命名空间。
    ///   streamid 显式带 `r=tenantA/<key>`，SRS 按 streamid 的 app 落流（`srt_server default_app live`
    ///   仅为缺省值，streamid 显式指定时以其为准）→ 桥接成 WebRTC 后正好落在 tenantA/<key>。
    static let defaultApp: String = "tenantA"

    // MARK: - HaishinKit 组件（actor 隔离，统一在 srtTask 串行）

    private let mixer = MediaMixer(captureSessionMode: .manual)
    private let connection = SRTConnection()
    private lazy var stream = SRTStream(connection: connection)

    /// 串行执行 HaishinKit 的异步调用，避免 actor 竞争。
    private var startTask: Task<Void, Never>?

    /// 视频格式描述缓存（尺寸变化时重建）。
    private var formatDescription: CMVideoFormatDescription?
    private var cachedWidth: Int32 = 0
    private var cachedHeight: Int32 = 0

    // MARK: - 生命周期

    /// 启动 SRT 推流。
    /// - Parameters:
    ///   - ip: 服务器 IP（方案 A 复用登录返回的 `stream_push_ip`）。
    ///   - streamKey: 流名（沿用现有 SRS streamKey 语义）。
    ///   - port: SRT 端口（默认 10080）。
    ///   - app: app 名（默认 "tenantA"，与 SRS/PC WHEP 同命名空间）。
    func start(ip: String,
               streamKey: String,
               port: Int = SRTManager.defaultSRTPort,
               app: String = SRTManager.defaultApp) {
        guard !ip.isEmpty else {
            reportFailure("SRT 推流 IP 为空，请重新登录")
            return
        }
        guard !streamKey.isEmpty else {
            reportFailure("SRT 流名为空")
            return
        }

        // streamid 约定（与 PC/SRS 对齐）：
        // srt://IP:PORT?streamid=#!::r=<app>/<streamKey>,m=publish
        //
        // ⚠️ 关键修复（2026-06-23，第二版）：streamid 必须以「原始明文」交给 libsrt。
        //
        // 根因（已查 HaishinKit 源码 SRTSocketOption.getQueryItems）：
        //   HaishinKit 用 `uri.absoluteString` 取 query，按 '?' 和 '&' 切分后，
        //   **直接把 value 传给 libsrt SRTO_STREAMID，不做任何百分号解码**。
        //   所以无论 addingPercentEncoding 还是 URLComponents，只要 absoluteString 里
        //   streamid 被编码成 %23/%3D/%2C，SRS 就会收到编码串（实测 app=%23!::r%3Dlive）。
        //   → 必须让 url.absoluteString 里的 streamid 就是明文 #!::r=live/...,m=publish。
        //
        // 做法（已查 HaishinKit 源码 + Issue #1498 实证）：
        //   HaishinKit.getQueryItems 用 `uri.absoluteString.split("?")[1].split("&")` 取 streamid，
        //   **不做百分号解码**，原样传给 libsrt SRTO_STREAMID。
        //   因此 url.absoluteString 里必须是明文 `streamid=#!::r=live/<key>,m=publish`。
        //   Issue #1498 实测 `URL(string:"srt://ip:10080?streamid=#!::r=live/x,m=publish")` 可被 SRS 正确识别。
        //   坑：iOS 17+ 的 URL(string:) 默认会把 '#' 百分号编码成 %23 → 必须用
        //       encodingInvalidCharacters:false 保留明文；iOS 16 用经典 URL(string:)（# 进 fragment 但 absoluteString 保留全文）。
        let streamId = "#!::r=\(app)/\(streamKey),m=publish"
        let urlString = "srt://\(ip):\(port)?streamid=\(streamId)"

        let url: URL
        if #available(iOS 17.0, *) {
            guard let u = URL(string: urlString, encodingInvalidCharacters: false) else {
                reportFailure("SRT URL 非法：\(urlString)")
                return
            }
            url = u
        } else {
            guard let u = URL(string: urlString) else {
                reportFailure("SRT URL 非法：\(urlString)")
                return
            }
            url = u
        }

        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                // mixer 输出接到 SRT 流；手动采集模式下我们只喂自定义帧。
                await self.mixer.addOutput(self.stream)

                // ⚠️ 关键修复（2026-06-23）：必须启动 mixer，否则 append 进来的帧
                // 没有消费者（MediaMixer.startRunning 内部才建立 videoIO.output → 各 output
                // 的转发循环），帧到不了 SRTStream → SRS 收不到数据 → SrtTimeout(6002)。
                // .manual 采集模式下不开摄像头，startRunning 只负责建立帧转发管线。
                await self.mixer.startRunning()

                try await self.connection.connect(url)

                // ⚠️ 关键修复（2026-06-23）：HaishinKit 2.x 自定义喂帧时，publish 前必须显式声明
                // 期望的媒体轨道，否则报 "Please set expected media" 且不推视频。
                // 我们只推视频、不推音频（mixer 未 attachAudio），故只传 [.video]。
                // 2.2.5 的方法名为 setExpectedMedias(_:)（复数），入参为 Set<AVMediaType>。
                // 需在 connect 之后、publish 之前调用。
                await self.stream.setExpectedMedias([.video])

                // ⭐ 关键修复（2026-06-24）：publish 前按档位应用编码参数，
                // 否则编码器吃 HaishinKit 默认值 854x480@640k（见 encWidth 注释）。
                await self.applyVideoSettingsToStream()

                await self.stream.publish(streamKey)

                await MainActor.run {
                    self.isPublishing = true
                    self.onStateChange?(true)
                    self.startStatsTimer()
                    print("✅ [SRT] 已连接并 publish：\(urlString)")
                }
            } catch {
                await MainActor.run {
                    self.isPublishing = false
                    self.onStateChange?(false)
                    self.reportFailure("SRT 连接/推流失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 停止 SRT 推流并释放资源。
    func stop() {
        stopStatsTimer()
        startTask?.cancel()
        startTask = nil
        let stream = self.stream
        let connection = self.connection
        let mixer = self.mixer
        Task {
            await stream.close()
            try? await connection.close()
            await mixer.removeOutput(stream)
            await mixer.stopRunning()
        }
        isPublishing = false
        formatDescription = nil
        cachedWidth = 0
        cachedHeight = 0
        statLock.lock()
        statFrameCount = 0
        statLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(false)
            self?.onSample?(0, 0, 0, 0, 0)   // 通知清零（PC 端码率/帧率回到 0）
        }
        print("🛑 [SRT] 已停止推流")
    }

    // MARK: - 编码参数注入

    /// 设置/更新 SRT 编码参数（分辨率/帧率/码率）。
    ///
    /// 可在 publish 前调用（仅记录，随后 publish 时统一应用），也可运行中调用
    /// （档位/清晰度变化时实时下发到编码器）。参数无变化时不重复下发。
    ///
    /// - Parameters:
    ///   - width/height: 目标编码分辨率（应与喂入帧尺寸一致，避免被 .trim 缩放）。
    ///   - fps: 期望帧率（仅作编码器功耗优化提示）。
    ///   - bitrateKbps: 目标码率（kbps）。
    func setEncodeParams(width: Int, height: Int, fps: Int, bitrateKbps: Int) {
        let changed = width != encWidth || height != encHeight
            || fps != encFps || bitrateKbps != targetBitrateKbps
        encWidth = max(2, width)
        encHeight = max(2, height)
        encFps = max(1, fps)
        targetBitrateKbps = max(1, bitrateKbps)
        guard changed, isPublishing else { return }
        Task { [weak self] in
            await self?.applyVideoSettingsToStream()
        }
    }

    /// 把当前 enc* 参数下发到 SRTStream 的编码器。
    ///
    /// ⚠️ 分辨率红线（与 P2P/SRS 一致，勿犯 P2P 历史错误 commit be84f5c）：
    ///   弱网自适应「只降 fps / 降码率，分辨率绝不变」。本方法的 videoSize 只来自
    ///   档位（WebRTCManager.getCaptureResolutionForProfile），档位切换时才变；
    ///   自适应过程只改 bitRate / expectedFrameRate（HaishinKit 走 live setOption，
    ///   不重建编码会话、不改分辨率）。HaishinKit 也无 WebRTC 那种拥塞自动缩分辨率机制，
    ///   故 SRT 天然不会在弱网时乱缩分辨率。切勿把 emergencyBitrateScale 等自适应量
    ///   接到 videoSize 上。
    private func applyVideoSettingsToStream() async {
        var settings = await stream.videoSettings
        settings.videoSize = CGSize(width: encWidth, height: encHeight)
        settings.bitRate = targetBitrateKbps * 1000
        // ⭐ H265（第四十九章）：SRT 按登录页「SRT编码」选择切 HEVC/H264。
        //   H264：Baseline + AutoLevel（对老 PC 硬解最友好，无 CABAC，level 随分辨率自动抬升）。
        //   H265：HEVC Main + AutoLevel（HaishinKit → VideoToolbox HEVC；PC 走 SRT→SRS→WHEP 拉 H265）。
        if H265Support.shared.srtWantsH265() {
            settings.profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel as String
            if WebRTCManager.verboseLogEnabled { print("🎬 [SRT] 编码=HEVC(Main)") }
        } else {
            settings.profileLevel = kVTProfileLevel_H264_Baseline_AutoLevel as String
        }
        settings.scalingMode = .trim
        settings.expectedFrameRate = Double(encFps)
        settings.maxKeyFrameIntervalDuration = 2
        do {
            try await stream.setVideoSettings(settings)
            if WebRTCManager.verboseLogEnabled {
                print("🎚️ [SRT] 编码参数 \(encWidth)x\(encHeight)@\(encFps) \(targetBitrateKbps)kbps")
            }
        } catch {
            print("⚠️ [SRT] 应用编码参数失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 统计定时器

    /// 启动每秒统计：实测推送 fps + 真实发送码率/RTT/丢包（取自 libsrt 性能数据），
    /// 通过 onSample 回调上报并驱动自适应。
    private func startStatsTimer() {
        stopStatsTimer()
        lastPktSentTotal = 0
        lastPktSndLossTotal = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.isPublishing else { return }
            self.statLock.lock()
            let fps = self.statFrameCount
            self.statFrameCount = 0
            self.statLock.unlock()
            // libsrt 性能数据是 actor 隔离的异步属性，取回后在主线程回调。
            Task { [weak self] in
                guard let self else { return }
                let pd = await self.connection.performanceData
                await MainActor.run {
                    guard self.isPublishing else { return }
                    var kbps = self.targetBitrateKbps
                    var rttMs = 0
                    var lossRate = 0.0
                    var lossPerSec = 0
                    if let pd {
                        // mbpsSendRate：真实发送速率（Mbps）→ kbps；0 时回退目标码率近似。
                        let realKbps = Int((pd.mbpsSendRate * 1000.0).rounded())
                        if realKbps > 0 { kbps = realKbps }
                        rttMs = Int(pd.msRTT.rounded())
                        // 按累计计数增量算每秒发送丢包率（不依赖 libsrt 的清零行为）。
                        let sentDelta = max(0, pd.pktSentTotal - self.lastPktSentTotal)
                        let lossDelta = max(0, Int(pd.pktSndLossTotal - self.lastPktSndLossTotal))
                        self.lastPktSentTotal = pd.pktSentTotal
                        self.lastPktSndLossTotal = pd.pktSndLossTotal
                        lossPerSec = lossDelta
                        let denom = Double(sentDelta) + Double(lossDelta)
                        if denom > 0 { lossRate = min(1.0, Double(lossDelta) / denom) }
                    }
                    self.onSample?(fps, kbps, rttMs, lossRate, lossPerSec)
                }
            }
        }
        timer.resume()
        statsTimer = timer
    }

    private func stopStatsTimer() {
        statsTimer?.cancel()
        statsTimer = nil
    }

    // MARK: - 帧注入（喂「滤镜后」的 NV12 帧）

    /// 把一帧「滤镜后」的 CVPixelBuffer 送入 SRT 编码推流。
    ///
    /// 这是解耦关键点：复用 WebRTCManager 现有采集 + Metal 滤镜链的产物（NV12），
    /// 不让 HaishinKit 自己采集（否则会绕过我们的滤镜）。
    ///
    /// - Parameters:
    ///   - pixelBuffer: 滤镜后的像素缓冲（NV12 / 420f / 420v 均可）。
    ///   - timeStampNs: 帧时间戳（纳秒，与推流链路一致）。
    func appendVideoFrame(pixelBuffer: CVPixelBuffer, timeStampNs: Int64) {
        guard isPublishing else { return }
        guard let sampleBuffer = makeSampleBuffer(from: pixelBuffer, timeStampNs: timeStampNs) else {
            return
        }
        // 统计：累计实际喂入帧数（用于每秒计算推送 fps）。
        statLock.lock()
        statFrameCount += 1
        statLock.unlock()
        // MediaMixer.append 为 nonisolated-safe 的 actor 方法；用 Task 转交。
        Task { [mixer] in
            await mixer.append(sampleBuffer, track: 0)
        }
    }

    // MARK: - CVPixelBuffer → CMSampleBuffer

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, timeStampNs: Int64) -> CMSampleBuffer? {
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))

        // 尺寸变化时重建 format description。
        if formatDescription == nil || width != cachedWidth || height != cachedHeight {
            var fmt: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &fmt
            )
            guard status == noErr, let fmt else {
                print("⚠️ [SRT] 创建 FormatDescription 失败：\(status)")
                return nil
            }
            formatDescription = fmt
            cachedWidth = width
            cachedHeight = height
        }

        guard let formatDescription else { return nil }

        // 90kHz 视频时钟下的 PTS（与 RTP 时钟一致，保证平滑）。
        let pts = CMTime(value: timeStampNs, timescale: 1_000_000_000)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else {
            print("⚠️ [SRT] 创建 SampleBuffer 失败：\(status)")
            return nil
        }
        return sampleBuffer
    }

    // MARK: - 私有

    private func reportFailure(_ reason: String) {
        print("❌ [SRT] \(reason)")
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(reason)
        }
    }
}
