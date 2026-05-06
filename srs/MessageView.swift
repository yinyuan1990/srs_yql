//
//  MessageView.swift
//  srs
//
//  Created by AI Assistant on 1/25/26.
//

import SwiftUI

// MARK: - TextEditor 背景色兼容扩展
extension View {
    /// 兼容 iOS 15 和 iOS 16+ 的 TextEditor 背景色设置
    @ViewBuilder
    func textEditorBackground(_ color: Color) -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
                .background(color)
        } else {
            self.onAppear {
                UITextView.appearance().backgroundColor = .clear
            }
            .background(color)
        }
    }
}

// MARK: - 问题反馈状态枚举
enum MessageStatus: Int {
    case pending = 0    // 待回复
    case replied = 1    // 已回复
    case closed = 2     // 已关闭
    
    var color: Color {
        switch self {
        case .pending: return .orange
        case .replied: return .green
        case .closed: return .gray
        }
    }
    
    var name: String {
        switch self {
        case .pending: return "待回复"
        case .replied: return "已回复"
        case .closed: return "已关闭"
        }
    }
}

// MARK: - 问题反馈ViewModel
class MessageViewModel: ObservableObject {
    @Published var messages: [APIService.MessageItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var maxLength: Int = 200
    @Published var currentPage: Int = 0
    @Published var totalPages: Int = 0
    @Published var totalElements: Int = 0
    @Published var hasMoreData: Bool = true
    
    private let apiService = APIService.shared
    private let pageSize = 10
    
    // 获取用户ID（从UserDefaults读取）
    var userId: Int {
        // 🔥 优先从 user_id 获取（登录时保存）
        let savedUserId = UserDefaults.standard.integer(forKey: "user_id")
        if savedUserId > 0 {
            return savedUserId
        }
        
        // 兼容旧版本：尝试从device_id获取数字ID
        if let deviceId = UserDefaults.standard.string(forKey: "device_id"),
           let id = Int(deviceId) {
            return id
        }
        
        print("⚠️ [Message] userId获取失败: user_id=\(savedUserId), device_id=\(UserDefaults.standard.string(forKey: "device_id") ?? "nil")")
        return 0
    }
    
    // 加载问题反馈配置
    func loadConfig() {
        Task {
            do {
                let config = try await apiService.getMessageConfig()
                await MainActor.run {
                    self.maxLength = config.maxLength
                    print("✅ [Message] 配置加载成功, maxLength=\(config.maxLength)")
                }
            } catch {
                print("⚠️ [Message] 配置加载失败: \(error), 使用默认值200")
            }
        }
    }
    
    // 加载问题反馈列表（首次/刷新）
    func loadMessages() {
        guard userId > 0 else {
            errorMessage = "用户信息无效，请重新登录"
            return
        }
        
        isLoading = true
        errorMessage = nil
        currentPage = 0
        
        Task {
            do {
                let listData = try await apiService.getMessageList(userId: userId, page: 0, size: pageSize)
                await MainActor.run {
                    self.messages = listData.content
                    self.totalPages = listData.totalPages
                    self.totalElements = listData.totalElements
                    self.currentPage = listData.currentPage
                    self.hasMoreData = listData.currentPage < listData.totalPages - 1
                    self.isLoading = false
                    print("✅ [Message] 列表加载成功, count=\(listData.content.count), total=\(listData.totalElements)")
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    print("❌ [Message] 列表加载失败: \(error)")
                }
            }
        }
    }
    
    // 加载更多（分页）
    func loadMoreMessages() {
        guard !isLoading, hasMoreData, userId > 0 else { return }
        
        isLoading = true
        let nextPage = currentPage + 1
        
        Task {
            do {
                let listData = try await apiService.getMessageList(userId: userId, page: nextPage, size: pageSize)
                await MainActor.run {
                    self.messages.append(contentsOf: listData.content)
                    self.totalPages = listData.totalPages
                    self.totalElements = listData.totalElements
                    self.currentPage = listData.currentPage
                    self.hasMoreData = listData.currentPage < listData.totalPages - 1
                    self.isLoading = false
                    print("✅ [Message] 加载更多成功, page=\(nextPage), count=\(listData.content.count)")
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    print("❌ [Message] 加载更多失败: \(error)")
                }
            }
        }
    }
    
    // 提交问题反馈
    func submitMessage(content: String, completion: @escaping (Bool, String?) -> Void) {
        print("📝 [Message] 准备提交问题反馈, userId=\(userId)")
        
        guard userId > 0 else {
            print("❌ [Message] userId无效: \(userId)")
            completion(false, "用户信息无效，请重新登录")
            return
        }
        
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(false, "问题反馈内容不能为空")
            return
        }
        
        guard content.count <= maxLength else {
            completion(false, "问题反馈内容不能超过\(maxLength)字")
            return
        }
        
        Task {
            do {
                let response = try await apiService.submitMessage(userId: userId, content: content)
                await MainActor.run {
                    if response.success {
                        print("✅ [Message] 提交成功: \(response.message ?? "")")
                        completion(true, response.message)
                        // 刷新列表
                        self.loadMessages()
                    } else {
                        completion(false, response.message ?? "提交失败")
                    }
                }
            } catch {
                await MainActor.run {
                    let errorMsg = (error as? APIError)?.localizedDescription ?? error.localizedDescription
                    completion(false, errorMsg)
                    print("❌ [Message] 提交失败: \(error)")
                }
            }
        }
    }
}

// MARK: - 问题反馈主页面
struct MessageView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = MessageViewModel()
    @State private var showingCompose = false
    @State private var selectedMessage: APIService.MessageItem?
    @State private var showAlert = false
    @State private var alertMessage = ""
    
    var body: some View {
        NavigationView {
            ZStack {
                // 背景色
                Color(UIColor.systemGroupedBackground)
                    .ignoresSafeArea()
                
                if viewModel.isLoading && viewModel.messages.isEmpty {
                    // 首次加载
                    ProgressView("加载中...")
                } else if viewModel.messages.isEmpty {
                    // 空状态
                    emptyStateView
                } else {
                    // 问题反馈列表
                    messageListView
                }
            }
            .navigationTitle("我的问题反馈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Color(hex: "1A1A1A"))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingCompose = true }) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.blue)
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            viewModel.loadConfig()
            viewModel.loadMessages()
        }
        .sheet(isPresented: $showingCompose) {
            MessageComposeView(viewModel: viewModel) { success, message in
                if success {
                    alertMessage = message ?? "问题反馈提交成功"
                    showAlert = true
                }
            }
        }
        .sheet(item: $selectedMessage) { message in
            MessageDetailView(message: message)
        }
        .alert("提示", isPresented: $showAlert) {
            Button("确定") { }
        } message: {
            Text(alertMessage)
        }
    }
    
    // 空状态视图
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 60))
                .foregroundColor(.gray.opacity(0.5))
            
            Text("暂无问题反馈")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("点击右上角按钮发起问题反馈")
                .font(.subheadline)
                .foregroundColor(.gray)
            
            Button(action: { showingCompose = true }) {
                Text("发起问题反馈")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .cornerRadius(22)
            }
            .padding(.top, 8)
        }
    }
    
    // 问题反馈列表视图
    private var messageListView: some View {
        List {
            ForEach(viewModel.messages) { message in
                MessageRowView(message: message)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedMessage = message
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.white)
            }
            
            // 加载更多
            if viewModel.hasMoreData {
                HStack {
                    Spacer()
                    if viewModel.isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Button("加载更多") {
                            viewModel.loadMoreMessages()
                        }
                        .font(.subheadline)
                        .foregroundColor(.blue)
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .onAppear {
                    viewModel.loadMoreMessages()
                }
            }
        }
        .listStyle(PlainListStyle())
        .refreshable {
            viewModel.loadMessages()
        }
    }
}

// MARK: - 问题反馈行视图
struct MessageRowView: View {
    let message: APIService.MessageItem
    
    private var status: MessageStatus {
        MessageStatus(rawValue: message.status) ?? .pending
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 顶部：状态标签 + 时间
            HStack {
                // 状态标签
                Text(message.statusName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(status.color)
                    .cornerRadius(4)
                
                Spacer()
                
                // 时间
                Text(formatDate(message.createdAt))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            // 问题反馈内容（最多显示2行）
            Text(message.content)
                .font(.system(size: 15))
                .foregroundColor(.primary)
                .lineLimit(2)
            
            // 如果已回复，显示回复摘要
            if let replyContent = message.replyContent, !replyContent.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                    
                    Text(replyContent)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
    }
    
    private func formatDate(_ dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        
        if let date = formatter.date(from: dateString) {
            let calendar = Calendar.current
            if calendar.isDateInToday(date) {
                formatter.dateFormat = "HH:mm"
                return "今天 \(formatter.string(from: date))"
            } else if calendar.isDateInYesterday(date) {
                formatter.dateFormat = "HH:mm"
                return "昨天 \(formatter.string(from: date))"
            } else {
                formatter.dateFormat = "MM-dd HH:mm"
                return formatter.string(from: date)
            }
        }
        return dateString
    }
}

// MARK: - 发起问题反馈页面
struct MessageComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: MessageViewModel
    let onSubmit: (Bool, String?) -> Void
    
    @State private var content: String = ""
    @State private var isSubmitting = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    private var remainingChars: Int {
        viewModel.maxLength - content.count
    }
    
    private var isValid: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && content.count <= viewModel.maxLength
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 输入区域
                VStack(alignment: .leading, spacing: 8) {
                    Text("问题反馈内容")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                    
                    ZStack(alignment: .topLeading) {
                        // 占位符
                        if content.isEmpty {
                            Text("请输入您的问题反馈内容，我们会尽快回复...")
                                .foregroundColor(.gray.opacity(0.6))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                        }
                        
                        TextEditor(text: $content)
                            .frame(minHeight: 150)
                            .textEditorBackground(Color.clear)
                    }
                    .padding(12)
                    .background(Color.white)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
                    .padding(.horizontal, 20)
                    
                    // 字数统计
                    HStack {
                        Spacer()
                        Text("\(content.count)/\(viewModel.maxLength)")
                            .font(.caption)
                            .foregroundColor(remainingChars < 0 ? .red : .secondary)
                    }
                    .padding(.horizontal, 20)
                }
                
                Spacer()
                
                // 提交按钮
                Button(action: submitMessage) {
                    HStack {
                        if isSubmitting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        }
                        Text(isSubmitting ? "提交中..." : "提交问题反馈")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(isValid && !isSubmitting ? Color.blue : Color.blue.opacity(0.4))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(!isValid || isSubmitting)
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("发起问题反馈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }
            }
        }
        .alert("提交失败", isPresented: $showError) {
            Button("确定") { }
        } message: {
            Text(errorMessage)
        }
    }
    
    private func submitMessage() {
        isSubmitting = true
        
        viewModel.submitMessage(content: content) { success, message in
            isSubmitting = false
            
            if success {
                dismiss()
                onSubmit(true, message)
            } else {
                errorMessage = message ?? "提交失败，请重试"
                showError = true
            }
        }
    }
}

// MARK: - 问题反馈详情页面
struct MessageDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let message: APIService.MessageItem
    
    private var status: MessageStatus {
        MessageStatus(rawValue: message.status) ?? .pending
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 我的问题反馈
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.blue)
                            
                            Text("我的问题反馈")
                                .font(.headline)
                            
                            Spacer()
                            
                            // 状态标签
                            Text(message.statusName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(status.color)
                                .cornerRadius(4)
                        }
                        
                        Text(message.content)
                            .font(.body)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        Text(formatFullDate(message.createdAt))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                    .background(Color.white)
                    .cornerRadius(12)
                    
                    // 系统回复（如果有）
                    if let replyContent = message.replyContent, !replyContent.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "info.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(.blue)
                                
                                Text("系统回复")
                                    .font(.headline)
                                
                                Spacer()
                            }
                            
                            Text(replyContent)
                                .font(.body)
                                .foregroundColor(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            
                            if let replyAt = message.replyAt {
                                Text(formatFullDate(replyAt))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(16)
                        .background(Color.green.opacity(0.08))
                        .cornerRadius(12)
                    } else {
                        // 未回复提示
                        HStack {
                            Image(systemName: "clock.fill")
                                .foregroundColor(.orange)
                            Text("客服正在处理中，请耐心等待...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(16)
                        .background(Color.orange.opacity(0.08))
                        .cornerRadius(12)
                    }
                }
                .padding(20)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("问题反馈详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Color(hex: "1A1A1A"))
                    }
                }
            }
        }
    }
    
    private func formatFullDate(_ dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        
        if let date = formatter.date(from: dateString) {
            formatter.dateFormat = "yyyy年MM月dd日 HH:mm"
            return formatter.string(from: date)
        }
        return dateString
    }
}

// MARK: - 预览
#Preview("MessageView") {
    MessageView()
}

#Preview("MessageComposeView") {
    MessageComposeView(viewModel: MessageViewModel()) { _, _ in }
}
