//
//  ChangePasswordView.swift
//  srs
//
//  修改密码独立页面
//

import SwiftUI

struct ChangePasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState  // 🔥 用于导航到登录页
    
    // 🔥 修改成功后的回调（由 ProfileView 传入，用于完整退出流程）
    var onPasswordChangeSuccess: (() -> Void)?
    
    // 🔥 3个输入框（原登录密码自动获取）
    @State private var oldPassword: String = ""           // 原登录密码（自动获取，不显示）
    @State private var oldSecondaryPassword: String = ""  // 原绑定码
    @State private var newPassword: String = ""           // 新登录密码
    @State private var newSecondaryPassword: String = ""  // 新绑定码
    
    @State private var isChanging: Bool = false
    @State private var showAlert: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""
    @State private var isSuccess: Bool = false
    
    var body: some View {
        NavigationView {
            ZStack {
                // 背景 - 白色
                Color.white
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 0) {
                        // 顶部间距
                        Color.clear.frame(height: 30)
                        
                        // 图标区域
                        VStack(spacing: 12) {
                            Image(systemName: "lock.rotation")
                                .font(.system(size: 40))
                                .foregroundColor(.primary)
                            
                            // 提示文字
                            Text("修改登录密码和绑定码")
                                .font(.system(size: 14))
                                .foregroundColor(Color(hex: "808080"))
                        }
                        .padding(.bottom, 30)
                        
                        // 🔥 3个输入框（原登录密码自动获取）
                        VStack(spacing: 0) {
                            // 原绑定码
                            PasswordInputRow(
                                title: "原绑定码",
                                placeholder: "请输入原绑定码",
                                text: $oldSecondaryPassword
                            )
                            
                            Divider()
                                .padding(.leading, 96)
                            
                            // 新登录密码
                            PasswordInputRow(
                                title: "新登录密码",
                                placeholder: "请输入新登录密码（6-20位）",
                                text: $newPassword
                            )
                            
                            Divider()
                                .padding(.leading, 96)
                            
                            // 新绑定码
                            PasswordInputRow(
                                title: "新绑定码",
                                placeholder: "请输入新绑定码（6-20位）",
                                text: $newSecondaryPassword
                            )
                        }
                        .background(Color(hex: "F4F4F8"))
                        .cornerRadius(12)
                        .padding(.horizontal, 16)
                        
                        Spacer().frame(height: 40)
                        
                        // 提交按钮
                        Button(action: {
                            handleChangePassword()
                        }) {
                            if isChanging {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: "FAFAFA")))
                                    .frame(width: 160, height: 46)
                            } else {
                                Text("确认修改")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(Color(hex: "FAFAFA"))
                                    .frame(width: 160, height: 46)
                            }
                        }
                        .background(isChanging ? Color(hex: "CCCCCC") : Color.blue)
                        .cornerRadius(10)
                        .disabled(isChanging)
                        
                        Spacer()
                    }
                }
            }
            .navigationTitle("修改密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(Color(hex: "1A1A1A"))
                    }
                }
            })
            .onAppear {
                // 设置导航栏为白色背景
                let appearance = UINavigationBarAppearance()
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = .white
                appearance.titleTextAttributes = [.foregroundColor: UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)]
                UINavigationBar.appearance().standardAppearance = appearance
                UINavigationBar.appearance().scrollEdgeAppearance = appearance
                
                // 🔥 自动获取原登录密码
                if let accountInfo = AccountStorageManager.shared.loadAccountInfo() {
                    oldPassword = accountInfo.password
                    print("✅ 已自动获取原登录密码")
                }
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("确定") {
                if isSuccess {
                    // 🔥 修改成功后退出到登录界面
                    handleLogoutAfterPasswordChange()
                }
            }
        } message: {
            Text(alertMessage)
        }
    }
    
    // MARK: - 修改密码逻辑（使用新接口 PUT /api/user/password/all）
    private func handleChangePassword() {
        // 🔥 验证原登录密码（自动获取）
        guard !oldPassword.isEmpty else {
            showError("无法获取原登录密码，请重新登录后再试")
            return
        }
        
        // 🔥 验证原绑定码
        guard !oldSecondaryPassword.isEmpty else {
            showError("请输入原绑定码")
            return
        }
        
        // 🔥 验证新登录密码
        guard !newPassword.isEmpty else {
            showError("请输入新登录密码")
            return
        }
        
        guard newPassword.count >= 6 && newPassword.count <= 20 else {
            showError("新登录密码长度必须在6-20位之间")
            return
        }
        
        guard oldPassword != newPassword else {
            showError("新登录密码不能与原登录密码相同")
            return
        }
        
        // 🔥 验证新绑定码
        guard !newSecondaryPassword.isEmpty else {
            showError("请输入新绑定码")
            return
        }
        
        guard newSecondaryPassword.count >= 6 && newSecondaryPassword.count <= 20 else {
            showError("新绑定码长度必须在6-20位之间")
            return
        }
        
        guard oldSecondaryPassword != newSecondaryPassword else {
            showError("新绑定码不能与原绑定码相同")
            return
        }
        
        // 开始修改
        isChanging = true
        
        Task {
            do {
                // 🔥 调用新接口：同时修改登录密码和绑定码
                let response = try await APIService.shared.changeAllPasswords(
                    oldPassword: oldPassword,
                    oldSecondaryPassword: oldSecondaryPassword,
                    newPassword: newPassword,
                    newSecondaryPassword: newSecondaryPassword
                )
                
                await MainActor.run {
                    isChanging = false
                    isSuccess = true
                    alertTitle = "修改成功"
                    alertMessage = response.message
                    showAlert = true
                }
                
            } catch {
                await MainActor.run {
                    isChanging = false
                    
                    if let apiError = error as? APIError {
                        switch apiError {
                        case .serverErrorWithMessage(let message):
                            showError(message)
                        case .serverError(let statusCode):
                            showError("服务器错误（状态码：\(statusCode)）")
                        default:
                            showError("修改密码失败，请重试")
                        }
                    } else {
                        showError("网络错误，请检查网络连接")
                    }
                }
            }
        }
    }
    
    private func showError(_ message: String) {
        isSuccess = false
        alertTitle = "修改失败"
        alertMessage = message
        showAlert = true
    }
    
    // 🔥 修改密码成功后退出到登录界面
    private func handleLogoutAfterPasswordChange() {
        print("🔐 密码修改成功，准备退出到登录界面")
        
        // 1. 关闭当前页面
        dismiss()
        
        // 2. 延迟调用回调（确保dismiss完成后由ProfileView处理完整退出流程）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let callback = onPasswordChangeSuccess {
                callback()
            } else {
                // 🔥 兜底逻辑：如果没有回调，直接执行退出流程
                print("📢 发送停止推流通知")
                NotificationCenter.default.post(name: NSNotification.Name("StopPublishBeforeLogout"), object: nil)
                
                print("🔌 断开WebSocket连接")
                WebSocketManager.shared.disconnect()
                
                UserDefaults.standard.set("", forKey: "jwt_token")
                UserDefaults.standard.set("", forKey: "permanent_token")
                
                appState.navigateToMonitorLogin()
            }
        }
    }
}

// MARK: - 密码输入行组件
struct PasswordInputRow: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "808080"))
                .frame(width: 80, alignment: .leading)
            
            SecureField(placeholder, text: $text)
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "1A1A1A"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white)
    }
}

// MARK: - 预览
#Preview {
    ChangePasswordView()
}

