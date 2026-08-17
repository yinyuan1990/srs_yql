//
//  APIService.swift
//  srs
//
//  Created by 陈源 on 8/27/25.
//

// 在APIService类中添加获取配置的方法
import Foundation
import UIKit
// API错误类型
enum APIError: Error {
    case invalidURL
    case invalidResponse
    case serverError(Int)
    case serverErrorWithMessage(String)  // 重命名以避免重载冲突
    case decodingError
    case networkError(Error)
    case accountBanned(reason: String)   // 🔥 账号被封禁
    
    var localizedDescription: String {
        switch self {
        case .invalidURL:
            return "无效的URL"
        case .invalidResponse:
            return "无效的响应"
        case .serverError(let code):
            return "服务器错误: \(code)"
        case .serverErrorWithMessage(let error):
            return "错误: \(error)"
        case .decodingError:
            return "数据解析错误"
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        case .accountBanned(let reason):
            return "账号已被封禁: \(reason)"
        }
    }
}

// 修改密码请求结构（旧接口）
struct ChangePasswordRequest: Codable {
    let oldPassword: String
    let newPassword: String
    let secondaryPassword: String  // 🔥 新增绑定码字段
}

// 修改密码响应结构
struct ChangePasswordResponse: Codable {
    let message: String
}

// 🔥 同时修改登录密码和绑定码请求结构（新接口 PUT /api/user/password/all）
struct ChangeAllPasswordsRequest: Codable {
    let oldPassword: String           // 原登录密码
    let oldSecondaryPassword: String  // 原绑定码（绑定码）
    let newPassword: String           // 新登录密码（6-20位）
    let newSecondaryPassword: String  // 新绑定码（6-20位）
}

// 🔥 同时修改登录密码和绑定码响应结构
struct ChangeAllPasswordsResponse: Codable {
    let message: String
}

// API响应基础结构
struct APIResponse<T: Codable>: Codable {
    let success: Bool
    let data: T?
    let message: String
}

// 🔥 推流Token请求结构
struct StreamTokenRequest: Codable {
    let username: String
    let streamName: String
}

// 🔥 推流Token响应结构
struct StreamTokenResponse: Codable {
    let token: String
    let expireAt: String?
    let expireSeconds: Int?
    let username: String?
    let streamName: String?
}

// 🔥 试用信息结构
struct TrialInfo: Codable {
    let trialRequired: Bool           // 是否需要试用限制
    let activated: Bool?              // 是否已激活
    let activationLevel: Int?         // 激活等级 (1=标清, 2=高清, 3=超清, 4=4K)
    let activationLevelName: String?  // 等级名称
    let activationExpireAt: String?   // 激活到期时间
    let activationTime: String?       // ⭐ §53.9 开通时间（「我的」页显示"<等级>会员 + 开通时间"）
    let qualityAccess: [String]?      // 可用画质列表
    
    // 🔥 日试用相关（新增）
    let isDailyTrial: Bool?           // 是否日试用码激活
    let activationRemainingSeconds: Int?  // 剩余有效秒数
    
    // 未激活时的试用状态
    let trialEnded: Bool?             // 当天试用是否已全部结束
    let currentStage: Int?            // 当前试用阶段 (1-6)
    let totalStages: Int?             // 总阶段数
    let stageSeconds: Int?            // 当前阶段总秒数
    let remainingSeconds: Int?        // 当前阶段剩余秒数
    let usedSeconds: Int?             // 当前阶段已用秒数
    let message: String?              // 提示信息
}

// MARK: - P2P ICE 服务器配置模型（登录接口下发）
struct IceServer: Codable {
    let urls: [String]
    let username: String?
    let credential: String?
    let region: String?

    init(urls: [String], username: String? = nil, credential: String? = nil, region: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
        self.region = region
    }

    enum CodingKeys: String, CodingKey { case urls, username, credential, region }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let arr = try? c.decode([String].self, forKey: .urls) {
            urls = arr
        } else if let single = try? c.decode(String.self, forKey: .urls) {
            urls = [single]
        } else {
            urls = []
        }
        username = try? c.decode(String.self, forKey: .username)
        credential = try? c.decode(String.self, forKey: .credential)
        region = try? c.decode(String.self, forKey: .region)
    }
}

// 登录响应结构
struct LoginResponse: Codable {
    let token: String
    let username: String
    let nickname: String?         // 🔥 昵称字段
    let userType: String
    let deviceId: String
    let permanentToken: String
    let membershipType: String
    let status: String
    let streamPushIp: String?     // 🔥 推流地址字段
    let message: String
    let userId: Int?              // 🔥 用户ID（用于问题反馈等功能）
    let trialInfo: TrialInfo?     // 🔥 新增：试用/激活信息
    let boundControlCount: Int?   // 🔥 绑定的控制端数量，0时需要跳转扫码绑定页面
    let scan: Int?                // 🔥 是否需要扫码绑定：1=需要跳转扫码，0=不需要
    // ⭐ 连接方式与 P2P 配置（全局二选一，srs/p2p 不混用；缺省 p2p）
    let connectMode: String?      // "srs"=总后台强制多人线路 | 其它(auto)=推流前自动决策（§53.4）
    let iceServers: [IceServer]?  // P2P 模式 STUN/TURN 列表
    let forceRelay: Bool?         // 强制 TURN 中继
    let maxP2PViewers: Int?       // 最大 P2P 观看端数
    // ⭐ §53.4.4：编码默认值改由总后台配置（默认 h265，不支持时客户端自动回退 h264）
    let videoCodecP2p: String?    // "h264" | "h265"
    let videoCodecSrs: String?    // "h264" | "h265"
    // ⭐ §53.20.2：本机的公网出口 IP（后端按请求来源回填）。与 PC 上报的 publicIp 比对，
    //   防 /24 网段号撞车（两地都是 192.168.1.x）误判同 WiFi。老后端缺省 → 跳过该校验。
    let clientIp: String?
    // ⭐ 需求#13（2026-07-31）：三端最新版本号（总后台可配）。与本地版本比对，不一致提示更新（软提示）。
    let latestVersions: LatestVersions?
}

// ⭐ 需求#13：三端最新版本号
struct LatestVersions: Codable {
    let pc: String?
    let ios: String?
    let android: String?
}


// 用户资料响应结构
struct UserProfileResponse: Codable {
    let username: String        // 用户名
    let nickname: String?       // 昵称（可选）
    var avatar: String?         // 头像URL（可选）
    let userType: String        // 用户类型（"采集端" 或 "控制端"）
    let membershipType: String  // 会员类型（"试用"、"永久"、"月付"）
    let status: String          // 用户状态（"有效"、"已过期"、"已暂停"）
    let createdAt: String       // 创建时间
}

// 用户资料更新请求结构
struct UserProfileRequest: Codable {
    let nickname: String?       // 昵称（可选）
    let avatar: String?         // 头像URL（可选）
}

// MARK: - 设备绑定相关数据结构

// 创建绑定请求
struct CreateBindingRequest: Codable {
    let deviceUsername: String   // 设备端用户名
    let controlUsername: String  // 控制端用户名
}

// 创建绑定响应
struct CreateBindingResponse: Codable {
    let success: Bool
    let bindingId: Int
    let deviceUsername: String
    let controlUsername: String
    let status: String
    let deviceVerified: Bool
    let controlVerified: Bool
    let message: String
}

// 设备端验证绑定码请求
struct VerifyDeviceRequest: Codable {
    let bindingId: Int
    let secondaryPassword: String
}

// 设备端验证绑定码响应
struct VerifyDeviceResponse: Codable {
    let success: Bool
    let bindingId: Int
    let deviceVerified: Bool
    let controlVerified: Bool
    let status: String
    let message: String
}

/// iOS 三链路（LUT/滤镜/硬件）配置 —— 登录接口 iosPipeline 块的内存静态持有者。
/// 不持久化到 UserDefaults，仅在当前进程生命周期内有效。
final class IOSPipelineConfig {
    static let shared = IOSPipelineConfig()
    private init() {}

    // 三链路总开关（打开才在第一次/切档时运用对应默认值）
    var switchLut: Bool      = false
    var switchFilter: Bool   = true
    var switchHardware: Bool = true

    // 滤镜默认值
    var brightness:     Float = 1.10
    var gamma:          Float = 1.10
    var contrast:       Float = 1.10
    var saturation:     Float = 1.10
    /// 服务端线性曝光倍率（如 1.10）；运用前需 log2() 换算成 EV
    var exposureLinear: Float = 1.10
    var sharpness:      Float = 0.20
    var highlightLift:  Float = 0.0
    var blackPoint:     Float = 0.10   // 锁死值
    var redBoost:       Float = 0.02   // 锁死值 → iOS redGlow

    // 硬件默认值
    /// 增益滑块 0-100（运用时映射到设备实际 ISO min..max）；白平衡始终自动，不在此存值
    var gainDefault: Int = 20

    // LUT
    var lutName: String = "lookup"

    /// 宽松解析布尔：支持 Bool / 0|1 / "true"|"false"
    private static func parseBool(_ any: Any?) -> Bool? {
        switch any {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// 传入登录原始 JSON 里 "iosPipeline" 对应的 [String: Any]
    func update(fromLoginJSON dict: [String: Any]) {
        let before = "filter=\(switchFilter) hw=\(switchHardware) lut=\(switchLut)"
        if let s = dict["switches"] as? [String: Any] {
            print("[IOSPipelineConfig] 原始 switches=\(s)")
            if let v = Self.parseBool(s["lut"])      { switchLut      = v }
            if let v = Self.parseBool(s["filter"])   { switchFilter   = v }
            if let v = Self.parseBool(s["hardware"]) { switchHardware = v }
        } else {
            print("[IOSPipelineConfig] ⚠️ iosPipeline 无 switches 字段，保留内置兜底")
        }
        if let f = dict["filter"] as? [String: Any] {
            func def(_ k: String) -> Float? { ((f[k] as? [String: Any])?["default"] as? NSNumber)?.floatValue }
            func locked(_ k: String) -> Float? { ((f[k] as? [String: Any])?["locked"] as? NSNumber)?.floatValue }
            if let v = def("brightness")    { brightness     = v }
            if let v = def("gamma")         { gamma          = v }
            if let v = def("contrast")      { contrast       = v }
            if let v = def("saturation")    { saturation     = v }
            if let v = def("exposure")      { exposureLinear = v }
            if let v = def("sharpness")     { sharpness      = v }
            if let v = def("highlightLift") { highlightLift  = v }
            if let v = locked("blackPoint") { blackPoint     = v }
            if let v = locked("redBoost")   { redBoost       = v }
        }
        if let hw = dict["hardware"] as? [String: Any] {
            if let v = ((hw["gain"] as? [String: Any])?["default"] as? NSNumber)?.intValue { gainDefault = v }
        }
        lutName = "lookup"
        print("[IOSPipelineConfig] 解析完成 \(before) → filter=\(switchFilter) hw=\(switchHardware) lut=\(switchLut) gain=\(gainDefault) lutName=\(lutName)")
        print("✅ [IOSPipelineConfig] filter=\(switchFilter) hw=\(switchHardware) lut=\(switchLut) gain=\(gainDefault) lutName=\(lutName)")
    }
}

// API服务类
class APIService {
    static let shared = APIService()
    
    private init() {}
    
    
    // MARK: - §76 领取一次性安全挑战值（登录前调用，无需 token）
    /// GET /auth/hw-challenge?deviceId=xxx → {challenge, expiresIn}
    /// 任何失败都返回 nil：调用方退回不带挑战值的旧签名格式（灰度期后端放行），不阻断登录。
    private func fetchHwChallenge(deviceId: String) async -> String? {
        let urlStr = APIConfig.shared.fullURL(for: APIConfig.Auth.hwChallenge)
            + "?deviceId=" + (deviceId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceId)
        guard let url = URL(string: urlStr) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("iPhone/iOS", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("⚠️ [§76挑战值] 领取失败，降级为旧签名格式")
                return nil
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let chal = obj["challenge"] as? String, !chal.isEmpty else { return nil }
            return chal
        } catch {
            print("⚠️ [§76挑战值] 领取异常: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 用户登录
    func login(username: String, password: String) async throws -> LoginResponse {
        
        
        guard let requestURL = APIConfig.shared.loginURL else {
                throw APIError.invalidURL
        }
            
        // 🔐 AES加密登录数据: "用户名,密码" -> 加密 -> Base64
        guard let encryptedData = AESUtils.encryptLoginData(username: username, password: password) else {
            print("❌ [登录] AES加密失败")
            throw APIError.invalidResponse
        }
        
        // 🔥 一机一码：请求体加上deviceId（后端验证是否是注册时的设备）
        // ⭐ §71 加 installId（安装实例ID）：后端按 deviceId 记录活跃安装，克隆机单活互踢
        let deviceId = DeviceIDManager.shared.getDeviceID()
        let installId = DeviceIDManager.shared.getInstallID()
        var loginData: [String: String] = [
            "data": encryptedData,
            "deviceId": deviceId,
            "installId": installId
        ]
        // ⭐ §72/§76 硬件密钥签名（Secure Enclave）：先领一次性挑战值，
        //   payload=deviceId|installId|时间戳|挑战值（挑战值验签后被服务端焚毁，抓包重放无效）。
        //   领取失败则退回不带挑战值的旧格式，由后端开关决定放不放行，不因一次网络抖动登不上。
        //   签名失败（极端情况）则整组字段都不带。
        let hwChal = await fetchHwChallenge(deviceId: deviceId)
        let hwTs = String(Int64(Date().timeIntervalSince1970 * 1000))
        var hwPayload = "\(deviceId)|\(installId)|\(hwTs)"
        if let chal = hwChal, !chal.isEmpty { hwPayload += "|\(chal)" }
        if let hwPub = HwKeyManager.shared.publicKeyB64(),
           let hwSign = HwKeyManager.shared.sign(hwPayload) {
            loginData["hwPub"] = hwPub
            loginData["hwSign"] = hwSign
            loginData["hwTs"] = hwTs
            if let chal = hwChal, !chal.isEmpty { loginData["hwChal"] = chal }
            // ⭐ §75 自报私钥存放位置（se/software），总后台「芯片密钥」列据此区分真芯片与静默降级
            if let hwLevel = HwKeyManager.shared.securityLevel() {
                loginData["hwLevel"] = hwLevel
            }
        }
        
        print("🔐 [登录] 接口: /auth/login/device")
        print("🔐 [登录] username: \(username)")
        print("🔐 [登录] deviceId: \(deviceId)")
        print("🔐 [登录] URL: \(requestURL)")
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("iPhone/iOS", forHTTPHeaderField: "User-Agent")  // 🔥 后端要求的 User-Agent
        // 🔥 关键修改：设置超时时间
        request.timeoutInterval = APIConfig.shared.requestTimeout
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: loginData)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            // 🔥 处理非200状态码的错误响应
            guard httpResponse.statusCode == 200 else {
                // 🔥 打印完整错误信息
                print("❌ [登录] HTTP \(httpResponse.statusCode)")
                print("❌ [登录] URL: \(requestURL)")
                if let responseString = String(data: data, encoding: .utf8) {
                    print("❌ [登录] 响应内容: \(responseString)")
                }
                
                // 尝试解析错误信息
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    print("❌ [登录] 解析JSON: \(errorJson)")
                    
                    // 🔥 处理403账号封禁
                    if httpResponse.statusCode == 403,
                       let banned = errorJson["banned"] as? Bool, banned == true {
                        let banReason = errorJson["banReason"] as? String ?? "违规操作"
                        print("❌ [登录] 账号被封禁: \(banReason)")
                        throw APIError.accountBanned(reason: banReason)
                    }
                    
                    // 其他错误
                    if let errorMsg = errorJson["error"] as? String {
                        print("❌ [登录] 错误: \(errorMsg)")
                        throw APIError.serverErrorWithMessage(errorMsg)
                    }
                }
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            // 🔥 打印原始响应（调试用）
            if let responseString = String(data: data, encoding: .utf8) {
                print("🔵 [登录] 原始响应: \(responseString)")
            }
            
            // 🔥 关键修改：直接解析LoginResponse，不是APIResponse包装
            let loginResponse = try JSONDecoder().decode(LoginResponse.self, from: data)
            print("✅ [登录] 成功, userId=\(loginResponse.userId ?? -1)")
            let rawLoginJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            // 🎨 解析 iosPipeline（三链路开关 + 滤镜/硬件/LUT 默认值）→ 内存静态变量（宽松解析，缺失保留兜底）
            if let pipeline = rawLoginJson?["iosPipeline"] as? [String: Any] {
                print("[登录] 收到 iosPipeline keys=\(pipeline.keys.sorted())")
                IOSPipelineConfig.shared.update(fromLoginJSON: pipeline)
            } else {
                let cfg = IOSPipelineConfig.shared
                print("[登录] ⚠️ 未返回 iosPipeline，使用内置兜底 filter=\(cfg.switchFilter) hw=\(cfg.switchHardware) lut=\(cfg.switchLut)")
                print("ℹ️ [登录] 未返回 iosPipeline，使用内置默认值")
            }
            // ⭐ §77 解析 videoLadder（5 档分辨率/帧率/码率）→ 落盘 UserDefaults，下次算档位生效。
            //   字段缺省（后端没配/老后端）传 nil，Store 会清掉本地覆盖回内置默认值。
            LadderConfigStore.shared.update(fromLoginJSON: rawLoginJson?["videoLadder"] as? [String: Any])
            return loginResponse
            
        } catch {
            print("❌ [登录] 异常: \(error)")
            if error is APIError {
                throw error
            } else {
                throw APIError.networkError(error)
            }
        }
    }
    
    // MARK: - 获取推流Token
    func getStreamToken(username: String, streamName: String) async throws -> StreamTokenResponse {
        guard let requestURL = APIConfig.shared.url(for: APIConfig.Auth.streamToken) else {
            throw APIError.invalidURL
        }
        
        let token = UserDefaults.standard.string(forKey: "jwt_token") ?? ""
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10.0
        
        let body = StreamTokenRequest(username: username, streamName: streamName)
        request.httpBody = try JSONEncoder().encode(body)
        
        print("📤 [推流Token] 请求: username=\(username), streamName=\(streamName)")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        if let responseString = String(data: data, encoding: .utf8) {
            print("📥 [推流Token] HTTP \(httpResponse.statusCode): \(responseString)")
        }
        
        guard httpResponse.statusCode == 200 else {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMsg = errorJson["error"] as? String {
                throw APIError.serverErrorWithMessage(errorMsg)
            }
            throw APIError.serverError(httpResponse.statusCode)
        }
        
        let tokenResponse = try JSONDecoder().decode(StreamTokenResponse.self, from: data)
        print("✅ [推流Token] 获取成功, token=\(tokenResponse.token.prefix(10))...")
        return tokenResponse
    }
    
    // MARK: - 用户个人信息
    func getUserProfile(token: String) async throws -> UserProfileResponse {
        
        guard let requestURL =   APIConfig.shared.url(for: APIConfig.User.profile) else {
            throw APIError.invalidURL
        }
        print("token: "+token)
        //print("userinfo: "+requestURL.path())
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("*/*", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            // 直接解析UserProfileResponse
            let userProfile = try JSONDecoder().decode(UserProfileResponse.self, from: data)
            print("获取用户资料成功")
            return userProfile
            
        } catch {
            print("获取用户资料失败: \(error)")
            if error is APIError {
                throw error
            } else {
                throw APIError.networkError(error)
            }
        }
    }
    
    // MARK: - 头像上传
    // MARK: - 头像上传
    func uploadAvatar(image: UIImage, token: String) async throws -> String {
        guard let requestURL = APIConfig.shared.url(for: APIConfig.User.updateProfile) else {
            throw APIError.invalidURL
        }
        // 压缩图片
        guard let imageData = image.jpegData(compressionQuality: 0.7) else {
            throw APIError.invalidResponse
        }
        // 创建multipart/form-data请求
        let boundary = UUID().uuidString
        var request = URLRequest(url: requestURL)
        request.httpMethod = "PUT"  // 使用PUT方法
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        
        var body = Data()
        
        // 添加图片数据
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"avatar\"; filename=\"avatar.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            // 修改响应解析结构
            struct AvatarUploadResponse: Codable {
                let message: String
                let avatarUrl: String?
            }
            
            let uploadResponse = try JSONDecoder().decode(AvatarUploadResponse.self, from: data)
            
            guard let avatarUrl = uploadResponse.avatarUrl else {
                throw APIError.decodingError
            }
            
            return avatarUrl
            
        } catch {
            if error is APIError {
                throw error
            } else {
                throw APIError.networkError(error)
            }
        }
    }
    
    // MARK: - 修改密码（旧接口）
    func changePassword(oldPassword: String, newPassword: String, secondaryPassword: String) async throws -> ChangePasswordResponse {
        guard let requestURL = APIConfig.shared.url(for: APIConfig.User.changePassword) else {
            throw APIError.invalidURL
        }
        
        let changePasswordData = ChangePasswordRequest(
            oldPassword: oldPassword,
            newPassword: newPassword,
            secondaryPassword: secondaryPassword  // 🔥 新增绑定码
        )
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        
        // 添加JWT token
        if let token = UserDefaults.standard.string(forKey: "jwt_token") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            request.httpBody = try JSONEncoder().encode(changePasswordData)
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                // 解析错误信息
                if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                   let errorMessage = errorData["error"] {
                    throw APIError.serverErrorWithMessage(errorMessage)
                }
                throw APIError.serverErrorWithMessage("修改密码失败")
            }
            
            let changePasswordResponse = try JSONDecoder().decode(ChangePasswordResponse.self, from: data)
            return changePasswordResponse
            
        } catch {
            if error is APIError {
                throw error
            } else {
                throw APIError.networkError(error)
            }
        }
    }
    
    // MARK: - 🔥 同时修改登录密码和绑定码（iOS设备端专用）
    /// PUT /api/user/password/all
    func changeAllPasswords(
        oldPassword: String,
        oldSecondaryPassword: String,
        newPassword: String,
        newSecondaryPassword: String
    ) async throws -> ChangeAllPasswordsResponse {
        guard let requestURL = APIConfig.shared.url(for: APIConfig.User.changeAllPasswords) else {
            throw APIError.invalidURL
        }
        
        let requestBody = ChangeAllPasswordsRequest(
            oldPassword: oldPassword,
            oldSecondaryPassword: oldSecondaryPassword,
            newPassword: newPassword,
            newSecondaryPassword: newSecondaryPassword
        )
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        
        // 添加JWT token
        if let token = UserDefaults.standard.string(forKey: "jwt_token") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            // 打印响应日志
            if let responseString = String(data: data, encoding: .utf8) {
                print("🔵 [ChangeAllPasswords] Status: \(httpResponse.statusCode)")
                print("🔵 [ChangeAllPasswords] Response: \(responseString)")
            }
            
            guard httpResponse.statusCode == 200 else {
                // 解析错误信息
                if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMessage = errorData["error"] as? String {
                    throw APIError.serverErrorWithMessage(errorMessage)
                }
                throw APIError.serverErrorWithMessage("修改密码失败")
            }
            
            let changePasswordResponse = try JSONDecoder().decode(ChangeAllPasswordsResponse.self, from: data)
            return changePasswordResponse
            
        } catch {
            if error is APIError {
                throw error
            } else {
                throw APIError.networkError(error)
            }
        }
    }
    
    // MARK: - 注销账号
    struct DeleteAccountResponse: Codable {
        let message: String
    }
    
    // 🔥 注销账号请求体（需要绑定码验证）
    struct DeleteAccountRequest: Codable {
        let secondaryPassword: String
    }
    
    func deleteAccount(secondaryPassword: String) async throws -> DeleteAccountResponse {
        guard let requestURL = APIConfig.shared.url(for: APIConfig.User.deleteAccount) else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"  // 🔥 改为POST（DELETE的body会被nginx/CDN丢弃导致超时）
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        
        // 添加JWT token
        if let token = UserDefaults.standard.string(forKey: "jwt_token") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        // 🔥 添加请求体（绑定码）
        let requestBody = DeleteAccountRequest(secondaryPassword: secondaryPassword)
        request.httpBody = try JSONEncoder().encode(requestBody)
        
        let jwtToken = UserDefaults.standard.string(forKey: "jwt_token") ?? ""
        print("🗑️ [注销] URL: \(requestURL)")
        print("🗑️ [注销] 方法: POST")
        print("🗑️ [注销] 绑定码: \(secondaryPassword.prefix(2))***")
        print("🗑️ [注销] JWT: \(jwtToken.isEmpty ? "❌空" : "✅\(jwtToken.prefix(20))...")")
        print("🗑️ [注销] ⏳ 发送请求中...")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            print("🗑️ [注销] ✅ 收到响应")
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            // 打印响应日志
            if let responseString = String(data: data, encoding: .utf8) {
                print("🗑️ [注销] Status: \(httpResponse.statusCode)")
                print("🗑️ [注销] 完整响应: \(responseString)")
            }
            
            guard httpResponse.statusCode == 200 else {
                // 尝试解析错误信息
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMsg = errorJson["error"] as? String {
                    throw APIError.serverErrorWithMessage(errorMsg)
                }
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            let deleteResponse = try JSONDecoder().decode(DeleteAccountResponse.self, from: data)
            print("🗑️ [注销] ✅ 注销成功: \(deleteResponse.message)")
            return deleteResponse
            
        } catch {
            print("🗑️ [注销] ❌ 异常: \(error)")
            if error is APIError {
                throw error
            } else {
                throw APIError.networkError(error)
            }
        }
    }
    
    // MARK: - 创建绑定记录
    func createBinding(deviceUsername: String, controlUsername: String) async throws -> CreateBindingResponse {
        guard let requestURL = APIConfig.shared.url(for: APIConfig.Binding.create) else {
            throw APIError.invalidURL
        }
        
        let requestBody = CreateBindingRequest(
            deviceUsername: deviceUsername,
            controlUsername: controlUsername
        )
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        
        // 添加JWT token认证
        if let token = UserDefaults.standard.string(forKey: "jwt_token") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        // 编码请求体
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(requestBody)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            // 打印响应日志
            if let responseString = String(data: data, encoding: .utf8) {
                print("🔵 [CreateBinding] Status: \(httpResponse.statusCode)")
                print("🔵 [CreateBinding] Response: \(responseString)")
            }
            
            guard httpResponse.statusCode == 200 else {
                // 尝试解析错误信息
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMsg = errorJson["error"] as? String {
                    throw APIError.serverErrorWithMessage(errorMsg)
                }
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            // 解析响应
            let decoder = JSONDecoder()
            let bindingResponse = try decoder.decode(CreateBindingResponse.self, from: data)
            
            return bindingResponse
            
        } catch {
            if error is APIError {
                throw error
            } else {
                throw APIError.networkError(error)
            }
        }
    }
    
    // MARK: - 设备端验证绑定码
    func verifyDeviceBinding(bindingId: Int, secondaryPassword: String) async throws -> VerifyDeviceResponse {
        guard let requestURL = APIConfig.shared.url(for: APIConfig.Binding.verifyDevice) else {
            throw APIError.invalidURL
        }
        
        let requestBody = VerifyDeviceRequest(
            bindingId: bindingId,
            secondaryPassword: secondaryPassword
        )
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        
        // 添加JWT token认证
        if let token = UserDefaults.standard.string(forKey: "jwt_token") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        // 编码请求体
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(requestBody)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            // 打印响应日志
            if let responseString = String(data: data, encoding: .utf8) {
                print("🔵 [VerifyDevice] Status: \(httpResponse.statusCode)")
                print("🔵 [VerifyDevice] Response: \(responseString)")
            }
            
            guard httpResponse.statusCode == 200 else {
                // 尝试解析错误信息
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMsg = errorJson["error"] as? String {
                    throw APIError.serverErrorWithMessage(errorMsg)
                }
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            // 解析响应
            let decoder = JSONDecoder()
            let verifyResponse = try decoder.decode(VerifyDeviceResponse.self, from: data)
            
            return verifyResponse
            
        } catch {
            if error is APIError {
                throw error
            } else {
                throw APIError.networkError(error)
            }
        }
    }
    
    // MARK: - 获取已绑定列表
    
    struct BindingItem: Codable, Identifiable {
        let bindingId: Int
        let controlUsername: String
        let controlNickname: String?
        let createdAt: String?
        
        var id: Int { bindingId }
    }
    
    struct BindingListResponse: Codable {
        let bindings: [BindingItem]
        let count: Int
    }
    
    func getBindingList() async throws -> BindingListResponse {
        guard let requestURL = APIConfig.shared.url(for: APIConfig.Binding.list) else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        
        // 添加JWT token认证
        if let token = UserDefaults.standard.string(forKey: "jwt_token") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            // 打印响应日志
            if let responseString = String(data: data, encoding: .utf8) {
                print("🔵 [BindingList] Status: \(httpResponse.statusCode)")
                print("🔵 [BindingList] Response: \(responseString)")
            }
            
            guard httpResponse.statusCode == 200 else {
                // 尝试解析错误信息
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMsg = errorJson["error"] as? String {
                    throw APIError.serverErrorWithMessage(errorMsg)
                }
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            // 解析响应
            let decoder = JSONDecoder()
            let listResponse = try decoder.decode(BindingListResponse.self, from: data)
            
            return listResponse
            
        } catch {
            if error is APIError {
                throw error
            } else {
                throw APIError.networkError(error)
            }
        }
    }
    
    // MARK: - 解绑
    
    struct UnbindResponse: Codable {
        let message: String
    }
    
    // 🔥 解绑请求体
    struct UnbindRequest: Codable {
        let secondaryPassword: String
    }
    
    func unbindDevice(bindingId: Int, secondaryPassword: String) async throws -> UnbindResponse {
        // DELETE /api/binding/unbind/{bindingId}
        let endpoint = "\(APIConfig.Binding.unbind)/\(bindingId)"
        guard let requestURL = APIConfig.shared.url(for: endpoint) else {
            throw APIError.invalidURL
        }
        
        print("🔵 [Unbind] URL: \(requestURL.absoluteString)")
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        
        // 添加JWT token认证
        if let token = UserDefaults.standard.string(forKey: "jwt_token") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            print("🔵 [Unbind] Token: \(String(token.prefix(20)))...")
        } else {
            print("⚠️ [Unbind] 警告：没有JWT token！")
        }
        
        // 🔥 添加请求体（绑定码）
        let unbindRequest = UnbindRequest(secondaryPassword: secondaryPassword)
        request.httpBody = try JSONEncoder().encode(unbindRequest)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            // 打印响应日志
            let responseString = String(data: data, encoding: .utf8) ?? "(空响应)"
            print("🔵 [Unbind] Status: \(httpResponse.statusCode)")
            print("🔵 [Unbind] Response: \(responseString)")
            
            guard httpResponse.statusCode == 200 else {
                // 尝试解析错误信息
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMsg = errorJson["error"] as? String {
                    throw APIError.serverErrorWithMessage(errorMsg)
                }
                // 403 特殊处理
                if httpResponse.statusCode == 403 {
                    throw APIError.serverErrorWithMessage("权限不足，请重新登录后再试")
                }
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            // 解析响应
            let decoder = JSONDecoder()
            let unbindResponse = try decoder.decode(UnbindResponse.self, from: data)
            
            return unbindResponse
            
        } catch {
            if error is APIError {
                throw error
            } else {
                throw APIError.networkError(error)
            }
        }
    }
    
}

// MARK: - 配置相关扩展
extension APIService {
    // 获取设备配置
    func getDeviceConfig(deviceId: String) async throws -> DeviceConfig {
        let url = APIConfig.shared.getDeviceConfigURL(deviceId: deviceId)
        
        guard let requestURL = URL(string: url) else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            // 解析响应
            struct ConfigResponse: Codable {
                let success: Bool
                let data: DeviceConfig
                let message: String
            }
            
            let configResponse = try JSONDecoder().decode(ConfigResponse.self, from: data)
            
            guard configResponse.success else {
                throw APIError.serverError(0)
            }
            
            return configResponse.data
            
        } catch {
            if error is APIError {
                throw error
            } else {
                throw APIError.networkError(error)
            }
        }
    }
}

// MARK: - 🔥 激活相关扩展
extension APIService {
    
    // 激活请求结构
    struct ActivationRequest: Codable {
        let code: String
    }
    
    // 激活响应结构
    struct ActivationResponse: Codable {
        let success: Bool
        let level: Int
        let levelName: String
        let expireAt: String
        let message: String
    }
    
    // 激活状态响应结构
    struct ActivationStatusResponse: Codable {
        let trialRequired: Bool
        let activated: Bool
        let activationLevel: Int?
        let activationLevelName: String?
        let activationExpireAt: String?
        let qualityAccess: [String]?
        let trialEnded: Bool?
        let currentStage: Int?
        let totalStages: Int?
        let stageSeconds: Int?
        let remainingSeconds: Int?
        let usedSeconds: Int?
        let expired: Bool?
        let expiredAt: String?
    }
    
    /// 激活会员
    func activateMembership(code: String) async throws -> ActivationResponse {
        guard let requestURL = APIConfig.shared.url(for: APIConfig.Activation.activate) else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        
        // 添加JWT token
        if let token = UserDefaults.standard.string(forKey: "jwt_token") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        // 编码请求体
        let activationRequest = ActivationRequest(code: code)
        request.httpBody = try JSONEncoder().encode(activationRequest)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            // 打印响应日志
            if let responseString = String(data: data, encoding: .utf8) {
                print("🔵 [Activation] Status: \(httpResponse.statusCode)")
                print("🔵 [Activation] Response: \(responseString)")
            }
            
            guard httpResponse.statusCode == 200 else {
                // 尝试解析错误信息
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMsg = errorJson["error"] as? String {
                    throw APIError.serverErrorWithMessage(errorMsg)
                }
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            // 解析响应
            let activationResponse = try JSONDecoder().decode(ActivationResponse.self, from: data)
            return activationResponse
            
        } catch {
            if error is APIError {
                throw error
            } else {
                throw APIError.networkError(error)
            }
        }
    }
    
    /// 获取激活状态
    func getActivationStatus() async throws -> ActivationStatusResponse {
        guard let requestURL = APIConfig.shared.url(for: APIConfig.Activation.status) else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        
        // 添加JWT token
        if let token = UserDefaults.standard.string(forKey: "jwt_token") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            // 打印响应日志
            if let responseString = String(data: data, encoding: .utf8) {
                print("🔵 [ActivationStatus] Status: \(httpResponse.statusCode)")
                print("🔵 [ActivationStatus] Response: \(responseString)")
            }
            
            guard httpResponse.statusCode == 200 else {
                // 尝试解析错误信息
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMsg = errorJson["error"] as? String {
                    throw APIError.serverErrorWithMessage(errorMsg)
                }
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            // 解析响应
            let statusResponse = try JSONDecoder().decode(ActivationStatusResponse.self, from: data)
            return statusResponse
            
        } catch {
            if error is APIError {
                throw error
            } else {
                throw APIError.networkError(error)
            }
        }
    }
}

// MARK: - 🔥 问题反馈相关扩展
extension APIService {
    
    // MARK: - 问题反馈数据模型
    
    /// 问题反馈配置
    struct MessageConfig: Codable {
        let maxLength: Int
    }
    
    /// 问题反馈配置响应
    struct MessageConfigResponse: Codable {
        let success: Bool
        let data: MessageConfig?
        let message: String?
    }
    
    /// 单条问题反馈
    struct MessageItem: Codable, Identifiable {
        let id: Int
        let content: String
        let status: Int
        let statusName: String
        let replyContent: String?
        let replyAdminName: String?
        let replyAt: String?
        let createdAt: String
    }
    
    /// 问题反馈列表数据
    struct MessageListData: Codable {
        let content: [MessageItem]
        let totalElements: Int
        let totalPages: Int
        let currentPage: Int
    }
    
    /// 问题反馈列表响应
    struct MessageListResponse: Codable {
        let success: Bool
        let data: MessageListData?
        let message: String?
    }
    
    /// 提交问题反馈请求
    struct SubmitMessageRequest: Codable {
        let userId: Int
        let content: String
    }
    
    /// 提交问题反馈响应数据
    struct SubmitMessageData: Codable {
        let id: Int
        let status: Int
        let statusName: String
        let createdAt: String
    }
    
    /// 提交问题反馈响应
    struct SubmitMessageResponse: Codable {
        let success: Bool
        let message: String?
        let data: SubmitMessageData?
    }
    
    /// 问题反馈详情响应
    struct MessageDetailResponse: Codable {
        let success: Bool
        let data: MessageItem?
        let message: String?
    }
    
    // MARK: - 问题反馈API方法
    
    /// 获取问题反馈配置
    func getMessageConfig() async throws -> MessageConfig {
        guard let requestURL = APIConfig.shared.url(for: APIConfig.Message.config) else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        
        // 添加JWT token
        if let token = UserDefaults.standard.string(forKey: "jwt_token") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            // 打印响应日志
            if let responseString = String(data: data, encoding: .utf8) {
                print("🔵 [MessageConfig] Status: \(httpResponse.statusCode)")
                print("🔵 [MessageConfig] Response: \(responseString)")
            }
            
            guard httpResponse.statusCode == 200 else {
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMsg = errorJson["message"] as? String {
                    throw APIError.serverErrorWithMessage(errorMsg)
                }
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            let configResponse = try JSONDecoder().decode(MessageConfigResponse.self, from: data)
            
            guard configResponse.success, let config = configResponse.data else {
                throw APIError.serverErrorWithMessage(configResponse.message ?? "获取配置失败")
            }
            
            return config
            
        } catch {
            if error is APIError {
                throw error
            } else {
                throw APIError.networkError(error)
            }
        }
    }
    
    /// 提交问题反馈
    func submitMessage(userId: Int, content: String) async throws -> SubmitMessageResponse {
        guard let requestURL = APIConfig.shared.url(for: APIConfig.Message.submit) else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        
        // 添加JWT token
        if let token = UserDefaults.standard.string(forKey: "jwt_token") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        // 编码请求体
        let submitRequest = SubmitMessageRequest(userId: userId, content: content)
        let requestBody = try JSONEncoder().encode(submitRequest)
        request.httpBody = requestBody
        
        // 打印请求信息
        print("🟢 [SubmitMessage] ========== 发布问题反馈请求 ==========")
        print("🟢 [SubmitMessage] URL: \(requestURL)")
        print("🟢 [SubmitMessage] userId: \(userId)")
        print("🟢 [SubmitMessage] content: \(content)")
        if let requestBodyString = String(data: requestBody, encoding: .utf8) {
            print("🟢 [SubmitMessage] Body: \(requestBodyString)")
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            // 打印响应日志
            print("🔵 [SubmitMessage] ========== 服务器响应 ==========")
            print("🔵 [SubmitMessage] Status: \(httpResponse.statusCode)")
            if let responseString = String(data: data, encoding: .utf8) {
                print("🔵 [SubmitMessage] Response: \(responseString)")
            }
            
            guard httpResponse.statusCode == 200 else {
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMsg = errorJson["message"] as? String {
                    throw APIError.serverErrorWithMessage(errorMsg)
                }
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            let submitResponse = try JSONDecoder().decode(SubmitMessageResponse.self, from: data)
            return submitResponse
            
        } catch {
            if error is APIError {
                throw error
            } else {
                throw APIError.networkError(error)
            }
        }
    }
    
    /// 获取问题反馈列表
    func getMessageList(userId: Int, page: Int = 0, size: Int = 10) async throws -> MessageListData {
        let endpoint = "\(APIConfig.Message.list)?userId=\(userId)&page=\(page)&size=\(size)"
        guard let requestURL = APIConfig.shared.url(for: endpoint) else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        
        // 添加JWT token
        if let token = UserDefaults.standard.string(forKey: "jwt_token") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            // 打印响应日志
            if let responseString = String(data: data, encoding: .utf8) {
                print("🔵 [MessageList] Status: \(httpResponse.statusCode)")
                print("🔵 [MessageList] Response: \(responseString)")
            }
            
            guard httpResponse.statusCode == 200 else {
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMsg = errorJson["message"] as? String {
                    throw APIError.serverErrorWithMessage(errorMsg)
                }
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            let listResponse = try JSONDecoder().decode(MessageListResponse.self, from: data)
            
            guard listResponse.success, let listData = listResponse.data else {
                throw APIError.serverErrorWithMessage(listResponse.message ?? "获取问题反馈列表失败")
            }
            
            return listData
            
        } catch {
            if error is APIError {
                throw error
            } else {
                throw APIError.networkError(error)
            }
        }
    }
    
    /// 获取问题反馈详情
    func getMessageDetail(messageId: Int) async throws -> MessageItem {
        let endpoint = "\(APIConfig.Message.detail)?id=\(messageId)"
        guard let requestURL = APIConfig.shared.url(for: endpoint) else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        
        // 添加JWT token
        if let token = UserDefaults.standard.string(forKey: "jwt_token") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            // 打印响应日志
            if let responseString = String(data: data, encoding: .utf8) {
                print("🔵 [MessageDetail] Status: \(httpResponse.statusCode)")
                print("🔵 [MessageDetail] Response: \(responseString)")
            }
            
            guard httpResponse.statusCode == 200 else {
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMsg = errorJson["message"] as? String {
                    throw APIError.serverErrorWithMessage(errorMsg)
                }
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            let detailResponse = try JSONDecoder().decode(MessageDetailResponse.self, from: data)
            
            guard detailResponse.success, let message = detailResponse.data else {
                throw APIError.serverErrorWithMessage(detailResponse.message ?? "问题反馈不存在")
            }
            
            return message
            
        } catch {
            if error is APIError {
                throw error
            } else {
                throw APIError.networkError(error)
            }
        }
    }
    
    // MARK: - §56.11 留言未读回复（登录后弹框）
    
    /// 单条未读回复
    struct UnreadReplyItem: Codable, Identifiable {
        let replyId: Int
        let messageId: Int
        let messageContent: String?   // 我的留言原文
        let content: String?          // 管理员回复内容
        let adminName: String?
        let createdAt: String?
        var id: Int { replyId }
    }
    
    /// 未读回复响应
    struct UnreadRepliesResponse: Codable {
        let success: Bool
        let total: Int?
        let data: [UnreadReplyItem]?
    }
    
    /// 获取未读回复（登录成功后调用，有未读则弹框）
    func getUnreadReplies(userId: Int) async throws -> [UnreadReplyItem] {
        let endpoint = "\(APIConfig.Message.unreadReplies)?userId=\(userId)"
        guard let requestURL = APIConfig.shared.url(for: endpoint) else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        if let token = UserDefaults.standard.string(forKey: "jwt_token") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.invalidResponse
        }
        if let responseString = String(data: data, encoding: .utf8) {
            print("🔵 [UnreadReplies] Response: \(responseString)")
        }
        let resp = try JSONDecoder().decode(UnreadRepliesResponse.self, from: data)
        return resp.data ?? []
    }
    
    /// 全部未读回复标记已读（弹框点"已读"后调用，之后登录不再弹）
    func markRepliesRead(userId: Int) async throws {
        guard let requestURL = APIConfig.shared.url(for: APIConfig.Message.read) else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        if let token = UserDefaults.standard.string(forKey: "jwt_token") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["userId": userId])
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.invalidResponse
        }
        print("🔵 [MarkRepliesRead] ✅ 已全部标记已读")
    }

    // MARK: - §59 登录广告

    /// 登录广告配置（外层 {config:"<json string>"}，内层 {enabled,title,content,version}）
    struct LoginAdEnvelope: Codable {
        let config: String?
    }

    struct LoginAdConfig: Codable {
        let enabled: Bool?
        let title: String?
        let version: Int64?
    }

    /// §59 获取登录广告配置（公开接口，登录成功后调用；内容由 WKWebView 直接加载 /config/login-ad/page）
    func getLoginAd() async throws -> LoginAdConfig {
        guard let requestURL = APIConfig.shared.url(for: APIConfig.Ad.loginAd) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = APIConfig.shared.requestTimeout

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.invalidResponse
        }
        if let responseString = String(data: data, encoding: .utf8) {
            print("🔵 [LoginAd] Response: \(responseString)")
        }
        let envelope = try JSONDecoder().decode(LoginAdEnvelope.self, from: data)
        guard let inner = envelope.config?.data(using: .utf8) else {
            throw APIError.invalidResponse
        }
        return try JSONDecoder().decode(LoginAdConfig.self, from: inner)
    }

    // MARK: - §60 邀请活动 + PC 下载入口（2026-08-13）

    struct ReferralTier: Codable, Identifiable {
        let count: Int?
        let months: Int?
        let cumulativeMonths: Int?
        let status: String?           // LOCKED / ACHIEVED / CLAIMABLE / CLAIMED
        var id: Int { count ?? 0 }
    }

    struct ReferralStatus: Codable {
        let enabled: Bool?
        let state: String?            // MEMBER / TRIAL_CAN_BIND / TRIAL_BOUND
        let popupContent: String?
        let trialHours: Int?
        let trialCardPending: Bool?   // §62 日卡已领未用（「我的」页显示「日卡」行）
        let remainingDays: Int64?     // 当前等级剩余天数（个人中心显示）
        let level: Int?
        let expireAt: String?
        let referralTrialActive: Bool?
        let boundCount: Int?
        let successCount: Int?
        let tiers: [ReferralTier]?
    }

    struct ReferralActionResult: Codable {
        let success: Bool?
        let message: String?
        let trialLevel: Int?
        let trialExpireAt: String?
        let months: Int?
        let expireAt: String?
        let remainingDays: Int64?
    }

    struct PcdlConfig: Codable {
        let enabled: Bool?
        let url: String?
        let content: String?
    }

    /// §60 从错误响应体提取 {"error": "..."} 消息
    private func referralErrorMessage(from data: Data) -> String? {
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (dict["error"] as? String) ?? (dict["message"] as? String)
        }
        return nil
    }

    /// §60 邀请活动状态（登录成功后调用，需 JWT）
    /// state = TRIAL_CAN_BIND（试用未绑定→邀请人输入框）/ TRIAL_BOUND（已用过邀请）/ MEMBER（打卡+领取）
    func getReferralStatus(token: String) async throws -> ReferralStatus {
        guard let requestURL = APIConfig.shared.url(for: APIConfig.Referral.status + "?variant=" + APIConfig.Referral.variant) else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = APIConfig.shared.requestTimeout

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.invalidResponse
        }
        if let s = String(data: data, encoding: .utf8) { print("🔵 [ReferralStatus] \(s)") }
        return try JSONDecoder().decode(ReferralStatus.self, from: data)
    }

    /// §60 试用用户填写邀请人（终身一次，绑定成功解锁体验）
    func referralBind(inviter: String, deviceId: String, token: String) async throws -> ReferralActionResult {
        guard let requestURL = APIConfig.shared.url(for: APIConfig.Referral.bind) else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "inviter": inviter,
            "deviceId": deviceId,
            "variant": APIConfig.Referral.variant
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let s = String(data: data, encoding: .utf8) { print("🔵 [ReferralBind] \(s)") }
        guard let httpResponse = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard httpResponse.statusCode == 200 else {
            throw APIError.serverErrorWithMessage(referralErrorMessage(from: data) ?? "绑定失败")
        }
        return try JSONDecoder().decode(ReferralActionResult.self, from: data)
    }

    /// §60 会员领取档位奖励（延长当前等级到期时间）
    func referralClaim(milestone: Int, token: String) async throws -> ReferralActionResult {
        guard let requestURL = APIConfig.shared.url(for: APIConfig.Referral.claim) else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "milestone": milestone,
            "variant": APIConfig.Referral.variant
        ] as [String: Any])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let s = String(data: data, encoding: .utf8) { print("🔵 [ReferralClaim] \(s)") }
        guard let httpResponse = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard httpResponse.statusCode == 200 else {
            throw APIError.serverErrorWithMessage(referralErrorMessage(from: data) ?? "领取失败")
        }
        return try JSONDecoder().decode(ReferralActionResult.self, from: data)
    }

    /// §62 使用日卡（「我的」页二级确认后调用，从确定那一刻起生效 trialHours 小时）
    func referralTrialUse(token: String) async throws -> ReferralActionResult {
        guard let requestURL = APIConfig.shared.url(for: APIConfig.Referral.trialUse) else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "variant": APIConfig.Referral.variant
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let s = String(data: data, encoding: .utf8) { print("🔵 [ReferralTrialUse] \(s)") }
        guard let httpResponse = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard httpResponse.statusCode == 200 else {
            throw APIError.serverErrorWithMessage(referralErrorMessage(from: data) ?? "使用日卡失败")
        }
        return try JSONDecoder().decode(ReferralActionResult.self, from: data)
    }

    /// §60 PC 端下载入口配置（公开接口，「我的」页入口用）
    func getPcDownload() async throws -> PcdlConfig {
        guard let requestURL = APIConfig.shared.url(for: APIConfig.Referral.pcdl + "?variant=" + APIConfig.Referral.variant) else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = APIConfig.shared.requestTimeout

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.invalidResponse
        }
        if let s = String(data: data, encoding: .utf8) { print("🔵 [Pcdl] \(s)") }
        return try JSONDecoder().decode(PcdlConfig.self, from: data)
    }
    
    // MARK: - 🔥 图片上传相关
    
    /// 图片上传响应
    struct ImageUploadResponse: Codable {
        let success: Bool
        let message: String
        let data: ImageUploadData?
    }
    
    struct ImageUploadData: Codable {
        let url: String
        let deviceId: String
    }
    
    /// 上传单张图片
    /// - Parameters:
    ///   - imageData: 图片数据
    ///   - fileName: 文件名
    ///   - deviceId: 设备ID
    /// - Returns: 上传响应
    func uploadImage(imageData: Data, fileName: String, deviceId: String) async throws -> ImageUploadResponse {
        guard let requestURL = APIConfig.shared.url(for: "/chain/upload") else {
            throw APIError.invalidURL
        }
        
        // 创建 multipart/form-data 请求
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60  // 上传可能需要更长时间
        
        // 🔥 此接口不需要token验证
        
        // 构建 multipart body
        var body = Data()
        
        // 添加 deviceId 字段
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"deviceId\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(deviceId)\r\n".data(using: .utf8)!)
        
        // 添加 file 字段
        let mimeType = getMimeType(for: fileName)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        
        // 结束边界
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            // 🔥 精简日志（避免IO阻塞）
            // if let responseString = String(data: data, encoding: .utf8) {
            //     print("🔵 [ImageUpload] Status: \(httpResponse.statusCode)")
            //     print("🔵 [ImageUpload] Response: \(responseString)")
            // }
            
            guard httpResponse.statusCode == 200 else {
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMsg = errorJson["message"] as? String {
                    throw APIError.serverErrorWithMessage(errorMsg)
                }
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            let uploadResponse = try JSONDecoder().decode(ImageUploadResponse.self, from: data)
            return uploadResponse
            
        } catch {
            if error is APIError {
                throw error
            } else {
                throw APIError.networkError(error)
            }
        }
    }
    
    /// 根据文件名获取 MIME 类型
    private func getMimeType(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        default:
            return "image/jpeg"
        }
    }
}
