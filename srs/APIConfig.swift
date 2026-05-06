import Foundation

// API配置管理类
class APIConfig {
    // 单例模式
    static let shared = APIConfig()
    
    private init() {}
    
    // MARK: - 服务器配置
    
    // 基础URL - 可以根据环境切换
    public var baseURL: String {
        #if DEBUG
        return "https://api.147258yql.cn" // 开发环境
        #else
        return "https://api.147258yql.cn" // 生产环境
        #endif
    }
    
    
    private var baseWsURL: String {
        #if DEBUG
        return "wss://ws.147258yql.cn/native-ws"
        #else
        return "wss://ws.147258yql.cn/native-ws"
        #endif
    }
    
    public var baseStompWsURL: String {
        #if DEBUG
        return "wss://ws.147258yql.cn/ws"
        #else
        return "wss://ws.147258yql.cn/ws"
        #endif
    }
    
    // API版本
    private let apiVersion = "/api"
    
    // 静态页面已改为本地加载（LocalWebView）
    
    // MARK: - API端点
    
    // 认证相关
    struct Auth {
        static let registerDevice = "/auth/register/device"  // 设备端注册
        static let login = "/auth/login/device"  // 🔥 一机一码登录（带deviceId验证）
        static let verifyToken = "/auth/verify-token"
        static let refreshToken = "/auth/refresh-token"
        static let streamToken = "/auth/stream/token/simple"  // 获取推流Token
        static let securityQuestion1 = "/config/security_question_1"  // 默认密保问题1
        static let securityQuestion2 = "/config/security_question_2"  // 默认密保问题2
        static let securityQuestion3 = "/config/security_question_3"  // 默认密保问题3
    }
    
    // 设备绑定相关
    struct Binding {
        static let create = "/binding/create"           // 创建绑定记录
        static let verifyDevice = "/binding/verify-device"  // 设备端验证绑定码
        static let list = "/binding/list"               // 获取已绑定列表
        static let unbind = "/binding/unbind"           // 解绑 (DELETE /binding/unbind/{bindingId})
    }
    
    // 用户相关
    struct User {
        static let profile = "/user/profile"                    // 获取用户资料
        static let updateProfile = "/user/profile"              // 更新用户资料（昵称和头像）
        static let changePassword = "/user/password"            // 修改密码（旧接口）
        static let changeAllPasswords = "/user/password/all"    // 🔥 同时修改登录密码和绑定码（iOS设备端专用）
        static let deleteAccount = "/user/account/delete"        // 注销账号（POST，解决DELETE body被丢弃问题）
    }
    
    // 会员相关
    struct Membership {
        static let upgrade = "/membership/upgrade"
        static let status = "/membership/status"
        static let history = "/membership/history"
    }
    
    // 设备相关
    struct Device {
        static let list = "/device/list"
        static let bind = "/device/bind"
        static let unbind = "/device/unbind"
        static let status = "/device/status"
    }
    
    // 🔥 激活相关
    struct Activation {
        static let activate = "/activation/activate"     // 激活会员
        static let status = "/activation/status"         // 获取激活状态
    }
    
    // 🔥 问题反馈相关
    struct Message {
        static let config = "/message/config"            // 获取问题反馈配置
        static let submit = "/message/submit"            // 提交问题反馈
        static let list = "/message/list"                // 获取问题反馈列表
        static let detail = "/message/detail"            // 获取问题反馈详情
    }
    
    // MARK: - 完整URL生成方法
    
    /// 生成完整的API URL
    /// - Parameter endpoint: API端点路径
    /// - Returns: 完整的URL字符串
    func fullURL(for endpoint: String) -> String {
        return baseURL + apiVersion + endpoint
    }
    
    /// 生成完整的API URL（URL对象）
    /// - Parameter endpoint: API端点路径
    /// - Returns: URL对象，如果无效则返回nil
    func url(for endpoint: String) -> URL? {
        return URL(string: fullURL(for: endpoint))
    }
    
    // MARK: - 常用API URL
    
    /// 设备注册URL
    var registerDeviceURL: URL? {
        return url(for: Auth.registerDevice)
    }
    
    /// 用户登录URL
    var loginURL: URL? {
        return url(for: Auth.login)
    }
    
    /// 令牌验证URL
    var verifyTokenURL: URL? {
        return url(for: Auth.verifyToken)
    }
    
    /// 会员升级URL
    var membershipUpgradeURL: URL? {
        return url(for: Membership.upgrade)
    }
    
    // MARK: - 请求配置
    
    /// 默认请求头
    var defaultHeaders: [String: String] {
        return [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "iOS-App/1.0"
        ]
    }
    
    
    
    /// 请求超时时间（秒）
    let requestTimeout: TimeInterval = 30.0
    
    // MARK: - 环境切换
    
    /// 设置自定义基础URL（用于测试）
    func setCustomBaseURL(_ url: String) {
        // 注意：这里可以添加URL验证逻辑
        // 在生产环境中，可能需要更严格的验证
    }
    
    /// 获取当前基础URL
    func getCurrentBaseURL() -> String {
        return baseURL
    }
    
    func getCurrentBaseWsURL() -> String {
        return baseWsURL
    }
    // 配置相关端点
    var getDeviceConfigURL: String {
        return "\(baseURL)\(apiVersion)/config"
    }
    //
    func getDeviceConfigURL(deviceId: String) -> String {
        return "\(getDeviceConfigURL)/\(deviceId)"
    }
}

// MARK: - 扩展：便捷方法

extension APIConfig {
    /// 打印所有API端点（调试用）
    func printAllEndpoints() {
        print("=== API配置 ===")
        print("基础URL: \(baseURL)")
        print("认证相关:")
        print("  注册设备: \(fullURL(for: Auth.registerDevice))")
        print("  用户登录: \(fullURL(for: Auth.login))")
        print("  验证令牌: \(fullURL(for: Auth.verifyToken))")
        print("会员相关:")
        print("  会员升级: \(fullURL(for: Membership.upgrade))")
        print("  会员状态: \(fullURL(for: Membership.status))")
        print("===============")
    }
}
