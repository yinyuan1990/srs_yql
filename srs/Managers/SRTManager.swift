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

    // MARK: - 连接参数（方案 A：端口写死，IP 复用登录返回的 stream_push_ip）

    /// SRT 服务端口（与 SRS srt_server listen 对齐，默认 10080）。
    static let defaultSRTPort: Int = 10080
    /// SRT app（与 SRS default_app / streamid r=<app>/<stream> 对齐）。
    static let defaultApp: String = "live"

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
    ///   - app: app 名（默认 "live"）。
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
        // ⚠️ 关键修复（2026-06-23）：streamid 必须以「原始明文」交给 libsrt。
        // 之前用 addingPercentEncoding(.alphanumerics) 把整串编码成 %23%21%3A%3A...，
        // 但 libsrt 不会反解码，SRS 收到后解析不出 #!:: 前缀 → connect 失败（error 1）。
        // 服务端已用 ffmpeg 明文 streamid 实测推通，证明问题在客户端编码。
        // 改用 URLComponents 拼接：它只对 query value 做标准 URL 转义，
        // libsrt/HaishinKit 按标准 URL 解析时会正确还原成原始 streamid。
        let streamId = "#!::r=\(app)/\(streamKey),m=publish"

        var components = URLComponents()
        components.scheme = "srt"
        components.host = ip
        components.port = port
        components.queryItems = [URLQueryItem(name: "streamid", value: streamId)]

        guard let url = components.url else {
            reportFailure("SRT URL 构造失败：ip=\(ip) port=\(port)")
            return
        }
        let urlString = url.absoluteString

        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                // mixer 输出接到 SRT 流；手动采集模式下我们只喂自定义帧。
                await self.mixer.addOutput(self.stream)

                try await self.connection.connect(url)
                await self.stream.publish(streamKey)

                await MainActor.run {
                    self.isPublishing = true
                    self.onStateChange?(true)
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
        startTask?.cancel()
        startTask = nil
        let stream = self.stream
        let connection = self.connection
        let mixer = self.mixer
        Task {
            await stream.close()
            try? await connection.close()
            await mixer.removeOutput(stream)
        }
        isPublishing = false
        formatDescription = nil
        cachedWidth = 0
        cachedHeight = 0
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(false)
        }
        print("🛑 [SRT] 已停止推流")
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
