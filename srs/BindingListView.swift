//
//  BindingListView.swift
//  srs
//
//  已绑定控制端列表视图
//

import SwiftUI

struct BindingListView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var bindings: [APIService.BindingItem] = []
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?
    
    // 解绑相关状态（使用 item 绑定确保数据同步）
    @State private var selectedBinding: APIService.BindingItem?
    
    // 标题（包含绑定数量）
    private var titleText: String {
        if bindings.isEmpty {
            return "已绑定列表"
        } else {
            return "已绑定列表（\(bindings.count)）"
        }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                // 背景色（白色，和我的界面一致）
                Color.white
                    .ignoresSafeArea()
                
                if isLoading {
                    // 加载中
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("加载中...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else if let error = errorMessage {
                    // 错误状态
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 50))
                            .foregroundColor(.orange)
                        
                        Text("加载失败")
                            .font(.headline)
                        
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button("重试") {
                            Task {
                                await loadBindings()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else if bindings.isEmpty {
                    // 空状态
                    VStack(spacing: 16) {
                        Image(systemName: "link.circle")
                            .font(.system(size: 60))
                            .foregroundColor(.gray.opacity(0.5))
                        
                        Text("暂无绑定")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        Text("请先扫描控制端二维码进行绑定")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    // 绑定列表
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(bindings) { binding in
                                VStack(spacing: 0) {
                                    BindingRowView(binding: binding) {
                                        selectedBinding = binding
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 16)
                                    
                                    Divider()
                                        .padding(.leading, 76)
                                }
                            }
                        }
                        .background(Color.white)
                    }
                    .refreshable {
                        await loadBindings()
                    }
                }
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Color(hex: "1A1A1A"))
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !isLoading {
                        Button(action: {
                            Task {
                                await loadBindings()
                            }
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(Color(hex: "1A1A1A"))
                        }
                    }
                }
            })
            // 🔥 解绑页面（全屏显示）
            .fullScreenCover(item: $selectedBinding) { binding in
                UnbindView(binding: binding) {
                    // 解绑成功后从列表中移除
                    bindings.removeAll { $0.bindingId == binding.bindingId }
                    selectedBinding = nil
                }
            }
        }
        .task {
            await loadBindings()
        }
    }
    
    // MARK: - 加载绑定列表
    
    private func loadBindings() async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }
        
        do {
            let response = try await APIService.shared.getBindingList()
            
            await MainActor.run {
                bindings = response.bindings
                isLoading = false
            }
            
            print("✅ 成功加载 \(response.count) 个绑定")
            
        } catch {
            await MainActor.run {
                isLoading = false
                
                if let apiError = error as? APIError {
                    switch apiError {
                    case .serverErrorWithMessage(let msg):
                        errorMessage = msg
                    case .serverError(let code):
                        errorMessage = "服务器错误 (\(code))"
                    default:
                        errorMessage = error.localizedDescription
                    }
                } else {
                    errorMessage = error.localizedDescription
                }
            }
            
            print("❌ 加载绑定列表失败: \(error)")
        }
    }
    
}

// MARK: - 绑定行视图

struct BindingRowView: View {
    let binding: APIService.BindingItem
    let onUnbind: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            // 图标（与 ProfileRowView 风格一致）
            Image(systemName: "desktopcomputer")
                .font(.system(size: 20))
                .foregroundColor(.primary)
                .frame(width: 24, height: 24)
            
            // 信息
            VStack(alignment: .leading, spacing: 2) {
                // 🔥 优先显示昵称，没有昵称则显示脱敏账号
                if let nickname = binding.controlNickname, !nickname.isEmpty {
                    Text(nickname)
                        .font(.system(size: 16))
                        .foregroundColor(.primary)
                } else {
                    Text(maskUsername(binding.controlUsername))
                        .font(.system(size: 16))
                        .foregroundColor(.primary)
                }
                
                if let time = binding.createdAt {
                    Text("绑定时间: \(formatTime(time))")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // 解绑按钮
            Button(action: onUnbind) {
                Text("解绑")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "808080"))
            }
            .buttonStyle(.plain)
            
            // 箭头
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
        }
    }
    
    // 🔥 账号脱敏：前2位 + ** + 后2位，小于等于4位直接显示
    private func maskUsername(_ username: String) -> String {
        if username.count <= 4 {
            return username
        }
        let prefix = String(username.prefix(2))
        let suffix = String(username.suffix(2))
        return "\(prefix)**\(suffix)"
    }
    
    // 格式化时间
    private func formatTime(_ isoTime: String) -> String {
        // ISO格式可能带微秒: 2025-11-25T20:38:17.197671
        let inputFormatter = DateFormatter()
        
        // 尝试带微秒的格式
        inputFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        if let date = inputFormatter.date(from: isoTime) {
            let outputFormatter = DateFormatter()
            outputFormatter.dateFormat = "yyyy-MM-dd HH:mm"
            return outputFormatter.string(from: date)
        }
        
        // 尝试不带微秒的格式
        inputFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let date = inputFormatter.date(from: isoTime) {
            let outputFormatter = DateFormatter()
            outputFormatter.dateFormat = "yyyy-MM-dd HH:mm"
            return outputFormatter.string(from: date)
        }
        
        return isoTime
    }
}

// MARK: - Preview

#Preview {
    BindingListView()
}

