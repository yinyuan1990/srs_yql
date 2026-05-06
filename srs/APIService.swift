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

// API服务类
class APIService {
    static let shared = APIService()
    
    private init() {}
    
    
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
        let deviceId = DeviceIDManager.shared.getDeviceID()
        let loginData: [String: String] = [
            "data": encryptedData,
            "deviceId": deviceId
        ]
        
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
