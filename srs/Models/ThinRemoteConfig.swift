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
    var shutterSpeed: Int?   // 防频闪快门，如 100 表示 1/100s
    var cjfps: Int?          // 🔥 采集FPS百分比 (0-100)，前置60-120fps，后置60-240fps
    var bitrate: Int?
    var angle: Int?
    var focus: Float?        // 对焦距离 0.0~1.0 (0.0=近处，1.0=无穷远)
    var brightness: Float?   // 亮度 (v3.1: 中调曲线, -1~1)
    var saturation: Float?   // 饱和度 0.0~2.0
    var contrast: Float?     // 对比度 0.0~4.0
    // ⭐ v3 滤镜新字段 — STOMP 直推路径用 (PC sendConfigUpdate)
    var sharpness: Float?       // 占位兼容, kernel 不读
    var redBoost: Float?        // 旧字段, 自动映射到 redGlow
    var blackPoint: Float?      // 黑场压死
    var redGlow: Float?         // 红色发光强度
    var highlightLift: Float?   // 高光提亮
    var gamma: Float?           // 伽马 0.5..2.0
    var exposure: Float?        // 曝光 -3..+3 stops
    var chroma: Float?          // 色度：黄色拉白 0.0~1.0（保留红色）
    var filterEnabled: Bool?    // 滤镜主开关
    var lutName: String?        // 玉麒麟 LUT 图名 (5 张之一)
    var videoHDR: Bool?         // Video HDR 开关
    var autoHDR: Bool?          // 自动 HDR 开关
    var autoWhiteBalance: Bool? // 自动白平衡开关
    var testBrightness: Int?    // debug 亮度 -2...8，直接映射硬件 ISO/EV
    var testWhiteBalance: Int?  // 白平衡 0-100，映射 2000K-8000K，默认50=5000K
    // ⭐ 采集端白平衡微调（PC L 键弹框 STOMP 直推）
    var wbTemperature: Float?   // 冷暖 -1~1
    var wbTint: Float?          // 绿紫 -1~1
    var wbRed: Float?           // 红 -1~1
    var wbGreen: Float?         // 绿 -1~1
    var wbBlue: Float?          // 蓝 -1~1
    var wbBlack: Float?         // 黑 -1~1
    var wbWhite: Float?         // 白 -1~1
    var wbAmber: Float?         // 黄/琥珀 -1~1

    // ⭐ 2026-07-14：低功率采集模式开关（PC「相机设定」面板新增，还原按钮旁）。
    //   仅影响「采集」帧率（钉死30fps）；PC 下发的推送(push)fps 逻辑完全不变，两者本就解耦。
    //   由 WebRTCManager.getCaptureResolutionForProfile 统一收口应用（详见该函数注释）。
    var lowPowerCapture: Bool?

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
        case shutterSpeed
        case cjfps       // 🔥 采集FPS百分比
        case bitrate
        case angle
        case focus
        case brightness
        case saturation
        case contrast
        case sharpness
        case redBoost
        case blackPoint
        case redGlow
        case highlightLift
        case gamma
        case exposure
        case chroma
        case filterEnabled
        case lutName
        case videoHDR
        case autoHDR
        case autoWhiteBalance
        case testBrightness = "value"
        case testWhiteBalance = "wb_value"
        case wbTemperature = "temperature"
        case wbTint = "tint"
        case wbRed = "red"
        case wbGreen = "green"
        case wbBlue = "blue"
        case wbBlack = "black"
        case wbWhite = "white"
        case wbAmber = "amber"
        case lowPowerCapture
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
        shutterSpeed = try container.decodeIfPresent(Int.self, forKey: .shutterSpeed)
        cjfps = try container.decodeIfPresent(Int.self, forKey: .cjfps)  // 🔥 采集FPS百分比
        bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate)
        angle = try container.decodeIfPresent(Int.self, forKey: .angle)
        focus = try container.decodeIfPresent(Float.self, forKey: .focus)
        brightness = try container.decodeIfPresent(Float.self, forKey: .brightness)
        saturation = try container.decodeIfPresent(Float.self, forKey: .saturation)
        contrast = try container.decodeIfPresent(Float.self, forKey: .contrast)
        sharpness = try container.decodeIfPresent(Float.self, forKey: .sharpness)
        redBoost = try container.decodeIfPresent(Float.self, forKey: .redBoost)
        blackPoint = try container.decodeIfPresent(Float.self, forKey: .blackPoint)
        redGlow = try container.decodeIfPresent(Float.self, forKey: .redGlow)
        highlightLift = try container.decodeIfPresent(Float.self, forKey: .highlightLift)
        gamma = try container.decodeIfPresent(Float.self, forKey: .gamma)
        exposure = try container.decodeIfPresent(Float.self, forKey: .exposure)
        chroma = try container.decodeIfPresent(Float.self, forKey: .chroma)
        filterEnabled = try container.decodeIfPresent(Bool.self, forKey: .filterEnabled)
        lutName = try container.decodeIfPresent(String.self, forKey: .lutName)
        videoHDR = try container.decodeIfPresent(Bool.self, forKey: .videoHDR)
        autoHDR = try container.decodeIfPresent(Bool.self, forKey: .autoHDR)
        autoWhiteBalance = try container.decodeIfPresent(Bool.self, forKey: .autoWhiteBalance)
        testBrightness = try container.decodeIfPresent(Int.self, forKey: .testBrightness)
        testWhiteBalance = try container.decodeIfPresent(Int.self, forKey: .testWhiteBalance)
        wbTemperature = try container.decodeIfPresent(Float.self, forKey: .wbTemperature)
        wbTint = try container.decodeIfPresent(Float.self, forKey: .wbTint)
        wbRed = try container.decodeIfPresent(Float.self, forKey: .wbRed)
        wbGreen = try container.decodeIfPresent(Float.self, forKey: .wbGreen)
        wbBlue = try container.decodeIfPresent(Float.self, forKey: .wbBlue)
        wbBlack = try container.decodeIfPresent(Float.self, forKey: .wbBlack)
        wbWhite = try container.decodeIfPresent(Float.self, forKey: .wbWhite)
        wbAmber = try container.decodeIfPresent(Float.self, forKey: .wbAmber)
        lowPowerCapture = try container.decodeIfPresent(Bool.self, forKey: .lowPowerCapture)
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
        self.shutterSpeed = nil
        self.cjfps = cjfps  // 🔥 采集FPS百分比
        self.bitrate = bitrate
        self.angle = angle
        self.focus = focus
        self.brightness = brightness
        self.saturation = saturation
        self.contrast = contrast
        self.sharpness = nil
        self.redBoost = nil
        self.blackPoint = nil
        self.redGlow = nil
        self.highlightLift = nil
        self.gamma = nil
        self.exposure = nil
        self.chroma = nil
        self.filterEnabled = nil
        self.lutName = nil
        self.videoHDR = nil
        self.autoHDR = nil
        self.autoWhiteBalance = nil
        self.testBrightness = nil
        self.testWhiteBalance = nil
        self.wbTemperature = nil
        self.wbTint = nil
        self.wbRed = nil
        self.wbGreen = nil
        self.wbBlue = nil
        self.wbBlack = nil
        self.wbWhite = nil
        self.wbAmber = nil
        self.lowPowerCapture = nil
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
            h264ProfileLevel: "H264_High_AutoLevel"
        ),
        .high: .init(
            width: 1920, height: 1080,
            videoBitrateKbps: 5000,
            fps: 60,
            audioBitrate: 128_000,
            sampleRate: 44100,
            keyframeIntervalSec: 1,
            h264ProfileLevel: "H264_High_AutoLevel"
        )
    ]
}
