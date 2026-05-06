//
//  ThinRemoteConfig.swift
//  srs
//
//  Created by 陈源 on 9/2/25.
//

import Foundation


// 服务器轻配置：只回档位 + 初始焦距
// 服务器轻配置：只回档位 + 初始焦距 + 相机方向
struct ThinRemoteConfig: Codable {
    let deviceId: String?
    var type: String       // "standard" or "high"
    var zoom: CGFloat
    var ptype: String
    var direction: String  // "-1"后置相机 or "1"前置相机  ✅ 修正
    var exposureBias: Float?   // ✅ 曝光补偿 EV [-2 ~ 2] - 控制画面亮度
    var fps: Int?            // 新增：后端/
    var cjfps: Int?          // 🔥 采集FPS百分比 (0-100)，前置60-120fps，后置60-240fps
    var bitrate: Int?
    var angle: Int?
    var focus: Float?        // 对焦距离 0.0~1.0 (0.0=近处，1.0=无穷远)
    var brightness: Float?   // 亮度 -0.02~0.02 ⚠️ 超出范围会被限制
    var saturation: Float?   // 饱和度 0.0~2.0
    var contrast: Float?     // 对比度 0.0~4.0
    
    let lastUpdated: String?
    let updatedBy: String?
    
    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case type
        case zoom
        case ptype
        case direction
        case exposureBias// ✅ 后端字段
        case fps
        case cjfps       // 🔥 采集FPS百分比
        case bitrate
        case angle
        case focus
        case brightness
        case saturation
        case contrast
        case lastUpdated = "last_updated"
        case updatedBy = "updated_by"
    }
    
    // 🔥 自定义解码：支持增量更新（ptype 指定更新类型，其他字段可选）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        
        // 🔥 type 可选：增量更新时可能不传，从当前配置获取或使用默认值
        if let t = try container.decodeIfPresent(String.self, forKey: .type) {
            type = t
        } else {
            type = ConfigManager.shared.currentThinConfig?.type ?? "standard"
        }
        
        // 🔥 zoom 可选：增量更新时可能不传，从当前配置获取或使用默认值
        if let z = try container.decodeIfPresent(CGFloat.self, forKey: .zoom) {
            zoom = z
        } else {
            zoom = ConfigManager.shared.currentThinConfig?.zoom ?? 1.0
        }
        
        ptype = try container.decode(String.self, forKey: .ptype)
        
        // 🔥 direction 兼容数字和字符串
        if let dirString = try? container.decode(String.self, forKey: .direction) {
            direction = dirString
        } else if let dirInt = try? container.decode(Int.self, forKey: .direction) {
            direction = String(dirInt)  // 数字 1 -> 字符串 "1"
            print("📱 [ThinRemoteConfig] direction 从数字 \(dirInt) 转换为字符串 \"\(direction)\"")
        } else {
            direction = ConfigManager.shared.currentThinConfig?.direction ?? "-1"  // 从当前配置获取或默认后置
        }
        
        exposureBias = try container.decodeIfPresent(Float.self, forKey: .exposureBias)
        fps = try container.decodeIfPresent(Int.self, forKey: .fps)
        cjfps = try container.decodeIfPresent(Int.self, forKey: .cjfps)  // 🔥 采集FPS百分比
        bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate)
        angle = try container.decodeIfPresent(Int.self, forKey: .angle)
        focus = try container.decodeIfPresent(Float.self, forKey: .focus)
        brightness = try container.decodeIfPresent(Float.self, forKey: .brightness)
        saturation = try container.decodeIfPresent(Float.self, forKey: .saturation)
        contrast = try container.decodeIfPresent(Float.self, forKey: .contrast)
        lastUpdated = try container.decodeIfPresent(String.self, forKey: .lastUpdated)
        updatedBy = try container.decodeIfPresent(String.self, forKey: .updatedBy)
    }
    
    // 初始化方法，用于创建更新请求
    init(type: String, zoom: CGFloat, ptype: String, direction: String = "-1", exposureBias: Float? = nil
         ,fps: Int? = nil, cjfps: Int? = nil, bitrate: Int? = nil, angle: Int? = nil, focus: Float? = nil, 
         brightness: Float? = nil, saturation: Float? = nil, contrast: Float? = nil) {
        self.deviceId = nil
        self.type = type
        self.zoom = zoom
        self.ptype = ptype
        self.direction = direction  // 默认为"-1"（后置相机）✅ 修正
        self.exposureBias = exposureBias
        self.fps = fps
        self.cjfps = cjfps  // 🔥 采集FPS百分比
        self.bitrate = bitrate
        self.angle = angle
        self.focus = focus
        self.brightness = brightness
        self.saturation = saturation
        self.contrast = contrast
        self.lastUpdated = nil
        self.updatedBy = nil
    }
}


// 档位（本地只维护这两个）
enum StreamProfile: String, Codable {
    case standard   // 标清
    case high       // 高清
}

struct StreamPreset {
    let width: Int
    let height: Int
    let videoBitrateKbps: Int
    let fps: Int
    let audioBitrate: Int
    let sampleRate: Int
    let keyframeIntervalSec: Int
    let h264ProfileLevel: String

    static let table: [StreamProfile: StreamPreset] = [
        
        
        .standard: .init(
            width: 1280, height: 720,
            videoBitrateKbps: 2500,
            fps: 60,
            audioBitrate: 128_000,
            sampleRate: 44100,
            keyframeIntervalSec: 1,
            h264ProfileLevel: "H264_Baseline_AutoLevel"
        ),
        .high: .init(
            width: 1920, height: 1080,
            videoBitrateKbps: 5000,
            fps: 60,
            audioBitrate: 128_000,
            sampleRate: 44100,
            keyframeIntervalSec: 1,
            h264ProfileLevel: "H264_Baseline_AutoLevel"
        )
    ]
}
