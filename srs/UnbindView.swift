//
//  UnbindView.swift
//  srs
//
//  解绑设备确认页面
//

import SwiftUI

struct UnbindView: View {
    @Environment(\.dismiss) private var dismiss
    
    let binding: APIService.BindingItem
    let onUnbindSuccess: () -> Void
    
    @State private var secondaryPassword: String = ""
    @State private var isUnbinding: Bool = false
    @State private var showResultAlert: Bool = false
    @State private var resultMessage: String = ""
    @State private var isSuccess: Bool = false
    
    var body: some View {
        NavigationView {
            ZStack {
                // 背景色（白色，与"我的"界面一致）
                Color.white
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // 设备信息区域
                    VStack(spacing: 16) {
                        // 图标
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 40))
                            .foregroundColor(.primary)
                            .padding(.top, 40)
                        
                        // 设备名称
                        Text(displayName)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(Color(hex: "1A1A1A"))
                        
                        // 绑定时间
                        if let time = binding.createdAt {
                            Text("绑定时间: \(formatTime(time))")
                                .font(.system(size: 14))
                                .foregroundColor(Color(hex: "808080"))
                        }
                    }
                    .padding(.bottom, 30)
                    
                    // 警告提示
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        
                        Text("解绑后该控制端将无法远程控制此设备")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(hex: "F4F4F8"))
                    .cornerRadius(10)
                    .padding(.horizontal, 20)
                    
                    // 绑定码输入
                    VStack(alignment: .leading, spacing: 8) {
                        Text("绑定码")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "808080"))
                        
                        SecureField("请输入绑定码", text: $secondaryPassword)
                            .textFieldStyle(.plain)
                            .padding()
                            .background(Color(hex: "F4F4F8"))
                            .cornerRadius(10)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    
                    Spacer()
                    
                    // 确认解绑按钮
                    Button(action: performUnbind) {
                        HStack {
                            if isUnbinding {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("确认解绑")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                        }
                        .frame(width: 160, height: 46)
                        .background(secondaryPassword.isEmpty ? Color(hex: "CCCCCC") : Color.red)
                        .foregroundColor(Color(hex: "FAFAFA"))
                        .cornerRadius(10)
                    }
                    .disabled(secondaryPassword.isEmpty || isUnbinding)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("解绑设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Color(hex: "1A1A1A"))
                    }
                }
            })
            .alert(isSuccess ? "解绑成功" : "解绑失败", isPresented: $showResultAlert) {
                Button("确定") {
                    if isSuccess {
                        onUnbindSuccess()
                        dismiss()
                    }
                }
            } message: {
                Text(resultMessage)
            }
        }
    }
    
    // MARK: - 显示名称
    
    private var displayName: String {
        if let nickname = binding.controlNickname, !nickname.isEmpty {
            return nickname
        }
        return maskUsername(binding.controlUsername)
    }
    
    // MARK: - 账号脱敏
    
    private func maskUsername(_ username: String) -> String {
        if username.count <= 4 {
            return username
        }
        let prefix = String(username.prefix(2))
        let suffix = String(username.suffix(2))
        return "\(prefix)**\(suffix)"
    }
    
    // MARK: - 格式化时间
    
    private func formatTime(_ isoTime: String) -> String {
        let inputFormatter = DateFormatter()
        
        inputFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        if let date = inputFormatter.date(from: isoTime) {
            let outputFormatter = DateFormatter()
            outputFormatter.dateFormat = "yyyy-MM-dd HH:mm"
            return outputFormatter.string(from: date)
        }
        
        inputFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let date = inputFormatter.date(from: isoTime) {
            let outputFormatter = DateFormatter()
            outputFormatter.dateFormat = "yyyy-MM-dd HH:mm"
            return outputFormatter.string(from: date)
        }
        
        return isoTime
    }
    
    // MARK: - 执行解绑
    
    private func performUnbind() {
        guard !secondaryPassword.isEmpty else { return }
        
        isUnbinding = true
        
        Task {
            do {
                let response = try await APIService.shared.unbindDevice(
                    bindingId: binding.bindingId,
                    secondaryPassword: secondaryPassword
                )
                
                await MainActor.run {
                    isUnbinding = false
                    isSuccess = true
                    resultMessage = response.message
                    showResultAlert = true
                }
                
                print("✅ 解绑成功: \(response.message)")
                
            } catch {
                await MainActor.run {
                    isUnbinding = false
                    isSuccess = false
                    
                    if let apiError = error as? APIError {
                        switch apiError {
                        case .serverErrorWithMessage(let msg):
                            resultMessage = msg
                        case .serverError(let code):
                            resultMessage = "服务器错误 (\(code))"
                        default:
                            resultMessage = error.localizedDescription
                        }
                    } else {
                        resultMessage = error.localizedDescription
                    }
                    
                    showResultAlert = true
                }
                
                print("❌ 解绑失败: \(error)")
            }
        }
    }
}

#Preview {
    UnbindView(
        binding: APIService.BindingItem(
            bindingId: 1,
            controlUsername: "testuser123",
            controlNickname: "测试用户",
            createdAt: "2025-12-19T10:30:00"
        ),
        onUnbindSuccess: {}
    )
}
