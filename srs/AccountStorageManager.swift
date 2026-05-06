import Foundation
import Security

// 账号信息模型
struct SavedAccountInfo: Codable {
    let collectorAccount: String
    let controllerAccount: String
    let password: String
    let deviceId: String
    let savedDate: Date
}

// 本地账号存储管理器
class AccountStorageManager {
    static let shared = AccountStorageManager()
    
    private let service = "com.yourapp.account"
    private let accountKey = "saved_account_info"
    
    private init() {}
    
    // 保存账号信息到Keychain
    func saveAccountInfo(_ accountInfo: SavedAccountInfo) -> Bool {
        do {
            let data = try JSONEncoder().encode(accountInfo)
            return saveToKeychain(data: data, key: accountKey)
        } catch {
            print("保存账号信息失败: \(error)")
            return false
        }
    }
    
    // 从Keychain读取账号信息
    func loadAccountInfo() -> SavedAccountInfo? {
        guard let data = getFromKeychain(key: accountKey) else {
            return nil
        }
        
        do {
            let accountInfo = try JSONDecoder().decode(SavedAccountInfo.self, from: data)
            return accountInfo
        } catch {
            print("读取账号信息失败: \(error)")
            return nil
        }
    }
    
    // 删除保存的账号信息
    func clearAccountInfo() -> Bool {
        return deleteFromKeychain(key: accountKey)
    }
    
    // 检查是否有保存的账号信息
    func hasAccountInfo() -> Bool {
        return loadAccountInfo() != nil
    }
    
    // MARK: - Keychain操作
    
    private func saveToKeychain(data: Data, key: String) -> Bool {
        // 先删除已存在的项
        deleteFromKeychain(key: key)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    private func getFromKeychain(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess {
            return result as? Data
        }
        return nil
    }
    
    private func deleteFromKeychain(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}