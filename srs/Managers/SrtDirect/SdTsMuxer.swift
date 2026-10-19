//
//  SdTsMuxer.swift
//  srs
//
//  只含一路 H.264 视频的 MPEG-TS 封装（ISO/IEC 13818-1），逐行照 Android SdTsMuxer.kt：
//  - PID：PAT=0x0000，PMT=0x1000，视频=0x0100（同时作 PCR PID），stream_type=0x1B，无音频
//  - 每一帧前都发 PAT/PMT；SPS/PPS 从码流里拆出保存，每个 IDR 前插入
//  - 每个访问单元前加 AUD；无 B 帧，PES 只带 PTS（DTS=PTS）
//  - PCR 放在每个 PES 的首包，比 PTS 早 pcrLead90k
//
//  SdLatencySei：端到端延迟测量 SEI（照 Android SdLatencySei.kt），UUID 必须与 PC gstplayer.cpp kSrtE2eUuid 一致。
//

import Foundation
import CoreMedia

final class SdTsMuxer {
    static let packetSize = 188
    private static let pidPat = 0x0000
    private static let pidPmt = 0x1000
    private static let pidVideo = 0x0100
    private static let streamTypeH264 = 0x1B
    /// 首帧 PTS 起点 1.4s，PCR 提前量 200ms 不会算出负值
    private static let ptsBase90k: Int64 = 126_000
    private static let pcrLead90k: Int64 = 18_000
    private static let aud: [UInt8] = [0, 0, 0, 1, 0x09, 0xF0]
    private static let startCode: [UInt8] = [0, 0, 0, 1]

    private var cc = [Int](repeating: 0, count: 0x2000)
    private var firstPtsUs: Int64 = -1
    private var sps: [UInt8]?
    private var pps: [UInt8]?

    /// 把一个编码帧（Annex-B）封装成若干个 188 字节 TS 包
    func mux(_ frame: [UInt8], ptsUs: Int64, isKey: Bool) -> [UInt8] {
        if firstPtsUs < 0 { firstPtsUs = ptsUs }
        let pts90k = Self.ptsBase90k + (ptsUs - firstPtsUs) * 9 / 100
        var out = [UInt8]()
        out.reserveCapacity(frame.count + frame.count / 180 * 4 + 1024)
        out.append(contentsOf: psiPacket(pid: Self.pidPat, section: patSection()))
        out.append(contentsOf: psiPacket(pid: Self.pidPmt, section: pmtSection()))
        let pes = pesPacket(buildAccessUnit(frame), pts90k: pts90k)
        writePes(&out, pes, pcr90k: pts90k - Self.pcrLead90k, randomAccess: isKey)
        return out
    }

    /// 拆出编码器输出里的 SPS/PPS/AUD 单独保存，每个 IDR 前插入保存的 SPS+PPS；访问单元开头加自己的 AUD
    private func buildAccessUnit(_ frame: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(frame.count + 64)
        out.append(contentsOf: Self.aud)
        for nal in Self.splitAnnexB(frame) {
            guard let head = nal.first else { continue }
            switch Int(head & 0x1F) {
            case 7: sps = nal
            case 8: pps = nal
            case 9: break
            default:
                if Int(head & 0x1F) == 5, let s = sps, let p = pps {
                    out.append(contentsOf: Self.startCode); out.append(contentsOf: s)
                    out.append(contentsOf: Self.startCode); out.append(contentsOf: p)
                }
                out.append(contentsOf: Self.startCode); out.append(contentsOf: nal)
            }
        }
        return out
    }

    /// Annex-B 码流切成 NAL（不含起始码）
    static func splitAnnexB(_ data: [UInt8]) -> [[UInt8]] {
        var nals = [[UInt8]]()
        var start = -1
        var i = 0
        let n = data.count
        while i + 2 < n {
            if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    while end > start && data[end - 1] == 0 { end -= 1 }
                    if end > start { nals.append(Array(data[start..<end])) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0 && start < n { nals.append(Array(data[start..<n])) }
        if nals.isEmpty && !data.isEmpty { nals.append(data) }
        return nals
    }

    // MARK: - PES

    private func pesPacket(_ es: [UInt8], pts90k: Int64) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 14)
        h[0] = 0; h[1] = 0; h[2] = 1
        h[3] = 0xE0                 // 视频流 stream_id
        h[4] = 0; h[5] = 0          // PES_packet_length=0：视频允许不定长
        h[6] = 0x84                 // '10' + data_alignment_indicator
        h[7] = 0x80                 // PTS_DTS_flags='10'（只有 PTS）
        h[8] = 5                    // PES_header_data_length
        Self.writeTimestamp(&h, 9, prefix: 0x2, ts: pts90k)
        return h + es
    }

    private static func writeTimestamp(_ b: inout [UInt8], _ off: Int, prefix: Int64, ts: Int64) {
        b[off] = UInt8(truncatingIfNeeded: (prefix << 4) | (((ts >> 30) & 0x07) << 1) | 1)
        b[off + 1] = UInt8(truncatingIfNeeded: (ts >> 22) & 0xFF)
        b[off + 2] = UInt8(truncatingIfNeeded: (((ts >> 15) & 0x7F) << 1) | 1)
        b[off + 3] = UInt8(truncatingIfNeeded: (ts >> 7) & 0xFF)
        b[off + 4] = UInt8(truncatingIfNeeded: ((ts & 0x7F) << 1) | 1)
    }

    /// PES 切成 TS 包：首包带 PCR（+随机接入标志），末包用自适应字段填充补齐 188
    private func writePes(_ out: inout [UInt8], _ pes: [UInt8], pcr90k: Int64, randomAccess: Bool) {
        let size = Self.packetSize
        let pid = Self.pidVideo
        var pos = 0
        var first = true
        while pos < pes.count {
            var pkt = [UInt8](repeating: 0xFF, count: size)
            let remaining = pes.count - pos

            var afBody = 0
            if first { afBody = 1 + 6 }             // flags + PCR
            var afTotal = afBody > 0 ? afBody + 1 : 0
            var payload = size - 4 - afTotal
            if remaining < payload {
                afTotal += payload - remaining      // 末包：扩大自适应字段把空余填满
                payload = remaining
            }

            pkt[0] = 0x47
            pkt[1] = UInt8(((first ? 0x40 : 0) | ((pid >> 8) & 0x1F)) & 0xFF)
            pkt[2] = UInt8(pid & 0xFF)
            let afc = afTotal > 0 ? 0x30 : 0x10
            pkt[3] = UInt8((afc | nextCc(pid)) & 0xFF)

            var p = 4
            if afTotal > 0 {
                pkt[p] = UInt8(afTotal - 1); p += 1  // adaptation_field_length
                if afTotal > 1 {
                    var flags = 0
                    if first {
                        flags = 0x10                 // PCR_flag
                        if randomAccess { flags |= 0x40 }
                    }
                    pkt[p] = UInt8(flags); p += 1
                    if first {
                        Self.writePcr(&pkt, p, pcrBase: max(0, pcr90k))
                        p += 6
                    }
                    p = 4 + afTotal                  // 其余为 0xFF 填充
                }
            }
            pkt.replaceSubrange(p..<(p + payload), with: pes[pos..<(pos + payload)])
            pos += payload
            first = false
            out.append(contentsOf: pkt)
        }
    }

    private static func writePcr(_ b: inout [UInt8], _ off: Int, pcrBase: Int64) {
        // program_clock_reference_base(33) + reserved(6) + extension(9)=0
        b[off] = UInt8(truncatingIfNeeded: (pcrBase >> 25) & 0xFF)
        b[off + 1] = UInt8(truncatingIfNeeded: (pcrBase >> 17) & 0xFF)
        b[off + 2] = UInt8(truncatingIfNeeded: (pcrBase >> 9) & 0xFF)
        b[off + 3] = UInt8(truncatingIfNeeded: (pcrBase >> 1) & 0xFF)
        b[off + 4] = UInt8(truncatingIfNeeded: ((pcrBase & 1) << 7) | 0x7E)
        b[off + 5] = 0
    }

    // MARK: - PSI

    private func patSection() -> [UInt8] {
        let body: [UInt8] = [
            0x00, 0x01,                                         // transport_stream_id
            0xC1,                                               // version 0, current_next 1
            0x00, 0x00,                                         // section_number / last_section_number
            0x00, 0x01,                                         // program_number 1
            UInt8(0xE0 | (Self.pidPmt >> 8)), UInt8(Self.pidPmt & 0xFF),
        ]
        return Self.section(tableId: 0x00, body: body)
    }

    private func pmtSection() -> [UInt8] {
        let v = Self.pidVideo
        let body: [UInt8] = [
            0x00, 0x01,                                         // program_number
            0xC1,
            0x00, 0x00,
            UInt8(0xE0 | (v >> 8)), UInt8(v & 0xFF),            // PCR_PID
            0xF0, 0x00,                                         // program_info_length=0
            UInt8(Self.streamTypeH264),
            UInt8(0xE0 | (v >> 8)), UInt8(v & 0xFF),
            0xF0, 0x00,                                         // ES_info_length=0
        ]
        return Self.section(tableId: 0x02, body: body)
    }

    /// table_id + section_syntax/length + body + CRC32
    private static func section(tableId: Int, body: [UInt8]) -> [UInt8] {
        let len = body.count + 4
        let head: [UInt8] = [UInt8(tableId), UInt8(0xB0 | ((len >> 8) & 0x0F)), UInt8(len & 0xFF)]
        let noCrc = head + body
        let crc = crc32Mpeg(noCrc)
        return noCrc + [UInt8(truncatingIfNeeded: crc >> 24), UInt8(truncatingIfNeeded: crc >> 16),
                        UInt8(truncatingIfNeeded: crc >> 8), UInt8(truncatingIfNeeded: crc)]
    }

    private func psiPacket(pid: Int, section: [UInt8]) -> [UInt8] {
        var pkt = [UInt8](repeating: 0xFF, count: Self.packetSize)
        pkt[0] = 0x47
        pkt[1] = UInt8(0x40 | ((pid >> 8) & 0x1F))
        pkt[2] = UInt8(pid & 0xFF)
        pkt[3] = UInt8(0x10 | nextCc(pid))
        pkt[4] = 0                                              // pointer_field
        pkt.replaceSubrange(5..<(5 + section.count), with: section)
        return pkt
    }

    private func nextCc(_ pid: Int) -> Int {
        let v = cc[pid]
        cc[pid] = (v + 1) & 0x0F
        return v
    }

    private static func crc32Mpeg(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data {
            crc ^= UInt32(b) << 24
            for _ in 0..<8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        return crc
    }
}

/// 端到端延迟测量：每帧第一个 slice 前插 SEI（user_data_unregistered），带手机墙钟的采集时刻与编码完成时刻
enum SdLatencySei {
    /// 与 PC gstplayer.cpp kSrtE2eUuid 必须一致："YQL-SRT-E2E-v1" 0x00 0x01
    static let uuid: [UInt8] = [
        0x59, 0x51, 0x4C, 0x2D, 0x53, 0x52, 0x54, 0x2D,
        0x45, 0x32, 0x45, 0x2D, 0x76, 0x31, 0x00, 0x01,
    ]

    /// 相机时间戳（主机时钟，ns）→ 手机墙钟 ms；不在 0~5s 内返回 -1
    static func captureWallMs(hostPtsNs: Int64, nowWallMs: Int64) -> Int64 {
        guard hostPtsNs > 0 else { return -1 }
        let nowHost = CMClockGetTime(CMClockGetHostTimeClock())
        let nowNs = Int64(CMTimeGetSeconds(nowHost) * 1_000_000_000)
        let ageMs = (nowNs - hostPtsNs) / 1_000_000
        return (0...5000).contains(ageMs) ? nowWallMs - ageMs : -1
    }

    /// 在第一个 slice NAL（type 1/5）前插入 SEI；找不到 slice 就原样返回
    static func insert(_ frame: [UInt8], captureMs: Int64, encodedMs: Int64) -> [UInt8] {
        guard let pos = firstVclStart(frame) else { return frame }
        var out = [UInt8]()
        out.reserveCapacity(frame.count + 64)
        out.append(contentsOf: frame[0..<pos])
        out.append(contentsOf: buildSei(captureMs: captureMs, encodedMs: encodedMs))
        out.append(contentsOf: frame[pos...])
        return out
    }

    /// 第一个 slice 的起始码位置（含 4 字节起始码的前导 0）
    private static func firstVclStart(_ b: [UInt8]) -> Int? {
        var i = 0
        while i + 3 < b.count {
            if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
                let type = b[i + 3] & 0x1F
                if type == 1 || type == 5 { return (i > 0 && b[i - 1] == 0) ? i - 1 : i }
                i += 3
            } else {
                i += 1
            }
        }
        return nil
    }

    private static func buildSei(captureMs: Int64, encodedMs: Int64) -> [UInt8] {
        // RBSP：payloadType=5, payloadSize=32, UUID(16) + 采集(8) + 编码完成(8), rbsp_trailing_bits
        var rbsp: [UInt8] = [0x05, 32]
        rbsp.append(contentsOf: uuid)
        appendInt64(&rbsp, captureMs)
        appendInt64(&rbsp, encodedMs)
        rbsp.append(0x80)
        var out: [UInt8] = [0, 0, 0, 1, 0x06]
        // 防竞争字节：连续两个 0x00 后若是 0x00~0x03，先插 0x03
        var zeros = 0
        for v in rbsp {
            if zeros >= 2 && v <= 3 {
                out.append(0x03)
                zeros = 0
            }
            out.append(v)
            zeros = v == 0 ? zeros + 1 : 0
        }
        return out
    }

    private static func appendInt64(_ o: inout [UInt8], _ v: Int64) {
        for s in stride(from: 56, through: 0, by: -8) {
            o.append(UInt8(truncatingIfNeeded: v >> Int64(s)))
        }
    }
}
