//
//  AESUtils.swift
//  srs
//
//  AES加密工具 - 对应后端 NewAesUtils.java
//

import Foundation
import CommonCrypto

class AESUtils {
    
    // 🔑 AES密钥（与后端一致）
    private static let AES_KEY = "7793rfdf-3datt9d"
    
    /// 🧪 测试加密功能 - 启动时调用
    static func testEncryption() {
        print("====== AES加密测试 ======")
        
        // 测试1: 单独加密 "123456"
        let test1 = "123456"
        if let encrypted1 = encrypt(test1) {
            print("📝 明文: \(test1)")
            print("🔐 密文: \(encrypted1)")
        }
        
        // 测试2: 加密 "device001,123456" (登录格式)
        let test2 = "device001,123456"
        if let encrypted2 = encrypt(test2) {
            print("📝 明文: \(test2)")
            print("🔐 密文: \(encrypted2)")
        }
        
        // 测试3: 验证解密
        if let encrypted = encrypt(test1), let decrypted = decrypt(encrypted) {
            print("🔓 解密验证: \(decrypted) == \(test1) ? \(decrypted == test1 ? "✅" : "❌")")
        }
        
        print("========================")
    }
    
    /// AES加密 + Base64编码
    /// - Parameter data: 明文字符串
    /// - Returns: Base64编码的密文，失败返回nil
    static func encrypt(_ data: String) -> String? {
        guard let keyData = AES_KEY.data(using: .utf8),
              let inputData = data.data(using: .utf8) else {
            print("❌ [AES] 编码失败")
            return nil
        }
        
        // AES/ECB/PKCS7Padding (PKCS7 在iOS上等同于Java的PKCS5)
        let keyLength = kCCKeySizeAES128
        let bufferSize = inputData.count + kCCBlockSizeAES128
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var numBytesEncrypted: size_t = 0
        
        let cryptStatus = keyData.withUnsafeBytes { keyBytes in
            inputData.withUnsafeBytes { dataBytes in
                CCCrypt(
                    CCOperation(kCCEncrypt),           // 加密
                    CCAlgorithm(kCCAlgorithmAES),     // AES算法
                    CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),  // PKCS7 + ECB模式
                    keyBytes.baseAddress,             // 密钥
                    keyLength,                        // 密钥长度
                    nil,                              // IV (ECB模式不需要)
                    dataBytes.baseAddress,            // 输入数据
                    inputData.count,                  // 输入长度
                    &buffer,                          // 输出缓冲区
                    bufferSize,                       // 缓冲区大小
                    &numBytesEncrypted                // 实际加密字节数
                )
            }
        }
        
        guard cryptStatus == kCCSuccess else {
            print("❌ [AES] 加密失败: \(cryptStatus)")
            return nil
        }
        
        let encryptedData = Data(bytes: buffer, count: numBytesEncrypted)
        let base64String = encryptedData.base64EncodedString()
        
        print("🔐 [AES] 加密成功: \(data) -> \(base64String.prefix(20))...")
        return base64String
    }
    
    /// Base64解码 + AES解密
    /// - Parameter data: Base64编码的密文
    /// - Returns: 明文字符串，失败返回nil
    static func decrypt(_ data: String) -> String? {
        guard !data.isEmpty else {
            return ""
        }
        
        guard let keyData = AES_KEY.data(using: .utf8),
              let encryptedData = Data(base64Encoded: data) else {
            print("❌ [AES] Base64解码失败")
            return nil
        }
        
        let keyLength = kCCKeySizeAES128
        let bufferSize = encryptedData.count + kCCBlockSizeAES128
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var numBytesDecrypted: size_t = 0
        
        let cryptStatus = keyData.withUnsafeBytes { keyBytes in
            encryptedData.withUnsafeBytes { dataBytes in
                CCCrypt(
                    CCOperation(kCCDecrypt),           // 解密
                    CCAlgorithm(kCCAlgorithmAES),     // AES算法
                    CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),  // PKCS7 + ECB模式
                    keyBytes.baseAddress,             // 密钥
                    keyLength,                        // 密钥长度
                    nil,                              // IV (ECB模式不需要)
                    dataBytes.baseAddress,            // 输入数据
                    encryptedData.count,              // 输入长度
                    &buffer,                          // 输出缓冲区
                    bufferSize,                       // 缓冲区大小
                    &numBytesDecrypted                // 实际解密字节数
                )
            }
        }
        
        guard cryptStatus == kCCSuccess else {
            print("❌ [AES] 解密失败: \(cryptStatus)")
            return nil
        }
        
        let decryptedData = Data(bytes: buffer, count: numBytesDecrypted)
        guard let decryptedString = String(data: decryptedData, encoding: .utf8) else {
            print("❌ [AES] UTF8解码失败")
            return nil
        }
        
        print("🔓 [AES] 解密成功")
        return decryptedString
    }
    
    /// 加密登录数据
    /// - Parameters:
    ///   - username: 用户名
    ///   - password: 密码
    /// - Returns: 加密后的字符串
    static func encryptLoginData(username: String, password: String) -> String? {
        let plainText = "\(username),\(password)"
        return encrypt(plainText)
    }
}

