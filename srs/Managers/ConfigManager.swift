//
//  ConfigManager.swift
//  srs
//
//  Created by 陈源 on 8/27/25.
//

import Foundation

class ConfigManager: ObservableObject {
    static let shared = ConfigManager()
    

    
    private let userDefaults = UserDefaults.standard
    private let configCacheKey = "cached_device_config"
    
    
    @Published var currentThinConfig: ThinRemoteConfig?
    private let thinConfigCacheKey = "cached_thin_config"
    
    
    private init() {
        loadCachedThinConfig()
    }
    
    
    
   
    // MARK: - 缓存配置到本地
    public func cacheConfig(_ config: DeviceConfig) {
        do {
            let data = try JSONEncoder().encode(config)
            userDefaults.set(data, forKey: configCacheKey)
            print("✅ 配置已缓存到本地")
        } catch {
            print("❌ 缓存配置失败: \(error.localizedDescription)")
        }
    }
    
  
    
    // 获取简化配置
    func getThinRemoteConfig(deviceId: String) async throws -> ThinRemoteConfig {
        let url = "\(APIConfig.shared.baseURL)/api/thin-config/\(deviceId)"
        
        print(url)
        guard let requestURL = URL(string: url) else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = APIConfig.shared.requestTimeout
        
        if let token = UserDefaults.standard.string(forKey: "jwt_token") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                throw APIError.serverError(httpResponse.statusCode)
            }
            
            struct ThinConfigResponse: Codable {
                let success: Bool
                let data: ThinRemoteConfig
                let message: String
            }
            
            let configResponse = try JSONDecoder().decode(ThinConfigResponse.self, from: data)
            
            guard configResponse.success else {
                throw APIError.serverError(0)
            }
            
            print(" 获取简化配置成功")
            return configResponse.data
            
        } catch {
            print("❌ 获取简化配置失败: \(error)")
            throw error
        }
    }
    
    
    
    // 更新简化配置
   func updateThinRemoteConfig(deviceId: String, config: ThinRemoteConfig, updatedBy: String = "iOS") async throws -> ThinRemoteConfig {
       let url = "\(APIConfig.shared.baseURL)/api/thin-config/\(deviceId)?updatedBy=\(updatedBy)"
       
       print("相机方向配置: "+url)
       guard let requestURL = URL(string: url) else {
           throw APIError.invalidURL
       }
       
       var request = URLRequest(url: requestURL)
       request.httpMethod = "PUT"
       request.setValue("application/json", forHTTPHeaderField: "Content-Type")
       request.timeoutInterval = APIConfig.shared.requestTimeout
       
       // 添加认证头
       if let token = UserDefaults.standard.string(forKey: "jwt_token") {
           request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
       }
       
       // 编码请求体
       do {
           let jsonData = try JSONEncoder().encode(config)
           request.httpBody = jsonData
       } catch {
           throw APIError.serverErrorWithMessage("error")
       }
       
       do {
           let (data, response) = try await URLSession.shared.data(for: request)
           
           guard let httpResponse = response as? HTTPURLResponse else {
               throw APIError.invalidResponse
           }
           
           guard httpResponse.statusCode == 200 else {
               throw APIError.serverError(httpResponse.statusCode)
           }
           
           struct ThinConfigResponse: Codable {
               let success: Bool
               let data: ThinRemoteConfig
               let message: String
           }
           
           let configResponse = try JSONDecoder().decode(ThinConfigResponse.self, from: data)
           
           guard configResponse.success else {
               throw APIError.serverError(0)
           }
           
           // 更新本地缓存
           self.currentThinConfig = configResponse.data
           cacheThinConfig(configResponse.data)
           
           print("✅ 更新简化配置成功")
           return configResponse.data
           
       } catch {
           print("❌ 更新简化配置失败: \(error)")
           throw error
       }
   }
    

    // 缓存ThinRemoteConfig
    func cacheThinConfig(_ config: ThinRemoteConfig) {
        do {
            let data = try JSONEncoder().encode(config)
            userDefaults.set(data, forKey: thinConfigCacheKey)
            print("✅ 简化配置已缓存到本地")
        } catch {
            print("❌ 缓存简化配置失败: \(error.localizedDescription)")
        }
    }

    // 从本地加载ThinRemoteConfig缓存
    public func loadCachedThinConfig() {
        guard let data = userDefaults.data(forKey: thinConfigCacheKey) else {
            print("📱 本地无简化配置缓存")
            return
        }
        
        do {
            let config = try JSONDecoder().decode(ThinRemoteConfig.self, from: data)
            self.currentThinConfig = config
            print("✅ 从本地加载简化配置成功")
        } catch {
            print("❌ 加载本地简化配置失败: \(error.localizedDescription)")
        }
    }
    
    
    /// 获取当前的简化配置
    /// - Returns: 当前缓存的ThinRemoteConfig，如果没有则返回nil
    public func getCurrentConfig() -> ThinRemoteConfig? {
        return currentThinConfig
    }
    
    /// 获取当前配置，如果没有则返回默认配置
    /// - Returns: 当前配置或默认的标准配置
    public func getCurrentConfigOrDefault() -> ThinRemoteConfig {
        return currentThinConfig ?? ThinRemoteConfig(
            type: StreamProfile.standard.rawValue,
            zoom: 1.0,  // 🔥 默认标准焦距
            ptype: "standard",
            focus: 0.6  // 🔥 默认对焦距离（与后端默认一致）
        )
    }
    
    /// 检查是否有有效的配置
    /// - Returns: 如果有当前配置返回true，否则返回false
    public func hasValidConfig() -> Bool {
        return currentThinConfig != nil
    }
    
}
