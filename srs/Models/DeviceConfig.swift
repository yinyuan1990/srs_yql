//
//  DeviceConfig.swift
//  srs
//
//  Created by 陈源 on 8/27/25.
//

import Foundation

// 设备配置模型
struct DeviceConfig: Codable {
    let deviceId: String
    let streamConfig: StreamConfig
    let photoConfig: PhotoConfig
    let lastUpdated: String
    let updatedBy: String?  // 🔥 改为可选类型
    let version: Int
    
    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case streamConfig = "stream_config"
        case photoConfig = "photo_config"
        case lastUpdated = "last_updated"
        case updatedBy = "updated_by"
        case version
    }
}

// 推流配置
struct StreamConfig: Codable {
    let videoBitrate: Int
    let videoFps: Int
    let videoResolution: String
    let audioBitrate: Int
    let audioSampleRate: Int
    let keyframeInterval: Int
    let encodingPreset: String
    let rtmpUrl: String
    let streamKey: String
    
    enum CodingKeys: String, CodingKey {
        case videoBitrate = "video_bitrate"
        case videoFps = "video_fps"
        case videoResolution = "video_resolution"
        case audioBitrate = "audio_bitrate"
        case audioSampleRate = "audio_sample_rate"
        case keyframeInterval = "keyframe_interval"
        case encodingPreset = "encoding_preset"
        case rtmpUrl = "rtmp_url"
        case streamKey = "stream_key"
    }
}

// 拍照配置
struct PhotoConfig: Codable {
    let photoQuality: Double
    let photoResolution: String
    let flashMode: String
    let focusMode: String
    let whiteBalance: String
    let isoValue: Int
    let exposureCompensation: Double
    let timerDelay: Int
    let burstMode: Bool
    let burstCount: Int
    let saveToAlbum: Bool
    let watermarkEnabled: Bool
    let watermarkText: String
    
    enum CodingKeys: String, CodingKey {
        case photoQuality = "photo_quality"
        case photoResolution = "photo_resolution"
        case flashMode = "flash_mode"
        case focusMode = "focus_mode"
        case whiteBalance = "white_balance"
        case isoValue = "iso_value"
        case exposureCompensation = "exposure_compensation"
        case timerDelay = "timer_delay"
        case burstMode = "burst_mode"
        case burstCount = "burst_count"
        case saveToAlbum = "save_to_album"
        case watermarkEnabled = "watermark_enabled"
        case watermarkText = "watermark_text"
    }
}
