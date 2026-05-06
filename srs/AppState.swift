//
//  AppState.swift
//  srs
//
//  Created by 陈源 on 8/30/25.
//

import SwiftUI
import Combine

// 定义应用的导航状态
enum AppView {
    case splash            // SplashView - 启动页（显示 Ai Logo）
    case home              // HomeView - 首页（暂不使用）
    case monitorLogin      // MonitorLoginView - 监控端登录
    case content           // ContentView - 推流页面
    case gpuImageTest      // 🧪 GPUImage 测试页面
    case qrScanner         // 🔥 扫码绑定页面（boundControlCount为0时跳转）
}

class AppState: ObservableObject {
    @Published var currentView: AppView = .splash  // 🔥 启动时显示 Splash 页面
    @Published var isLoggedIn: Bool = false
    @Published var permanentToken: String = ""
    
    init() {
        checkLoginStatus()
    }
    
    // 从 Splash 跳转到登录页
    func navigateToLogin() {
        currentView = .monitorLogin
    }
    
    // 🔥 跳转到首页（选择家长端/监控端）
    func navigateToHome() {
        currentView = .home
    }
    
    private func checkLoginStatus() {
        if let token = UserDefaults.standard.string(forKey: "permanent_token"), !token.isEmpty {
            self.permanentToken = token
            self.isLoggedIn = true
            // 注意：不自动跳转，保持现有导航逻辑
        }
    }
    
    // 导航方法
    func navigateToMonitorLogin() {
        currentView = .monitorLogin
    }
    
    func navigateToContent() {
        currentView = .content
    }
    
    // 🔥 跳转到扫码绑定页面
    func navigateToQRScanner() {
        currentView = .qrScanner
    }
    
    func navigateBack() {
        switch currentView {
        case .splash:
            break // Splash 页面不需要返回
        case .monitorLogin:
            break  // 登录页不需要返回（已是入口）
        case .content:
            currentView = .monitorLogin
        case .home:
            break // 已经在首页
        case .gpuImageTest:
            currentView = .splash  // 🧪 测试页面返回到 Splash
        case .qrScanner:
            currentView = .monitorLogin  // 🔥 扫码页面返回到登录页
        }
    }
    
    // 登录成功处理
    func loginSuccess(token: String, boundControlCount: Int = 1, scan: Int = 0) {
        self.permanentToken = token
        self.isLoggedIn = true
        UserDefaults.standard.set(token, forKey: "permanent_token")
        
        // 🔥 根据 boundControlCount + scan 决定跳转目标
        // 只有未绑定(boundControlCount<=0) 且 需要扫码(scan==1) 时才跳扫码页
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if boundControlCount <= 0 && scan == 1 {
                // 没有绑定控制端 且 后端要求扫码 → 跳转到扫码绑定页面
                self.navigateToQRScanner()
            } else {
                // 已绑定 或 不需要扫码 → 直接跳转到推流页面
                self.navigateToContent()
            }
        }
    }
    
    // 登出处理
    func logout() {
        self.isLoggedIn = false
        self.permanentToken = ""
        UserDefaults.standard.removeObject(forKey: "permanent_token")
        // 登出后返回首页
        currentView = .home
    }
}

// MARK: - Color 扩展 - 支持 hex 颜色值
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
