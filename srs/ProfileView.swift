//
//  ProfileView.swift
//  srs
//
//  Created by 陈源 on 9/4/25.
//

import SwiftUI



// 个人中心ViewModel
class ProfileViewModel: ObservableObject {
    @Published var userProfile: UserProfileResponse?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isUploadingAvatar = false
    
    private let apiService = APIService.shared
    
    // 获取用户信息
    func loadUserProfile() {
        
        // 安全获取token，提供默认值
        let token = UserDefaults.standard.string(forKey: "jwt_token") ?? ""
        
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let profile = try await apiService.getUserProfile(token: token)
                
                await MainActor.run {
                    self.userProfile = profile
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
    // 上传头像
    func uploadAvatar(_ image: UIImage) {
        let token = UserDefaults.standard.string(forKey: "jwt_token") ?? ""
        
        isUploadingAvatar = true
        errorMessage = nil
        
        Task {
            do {
                let avatarUrl = try await apiService.uploadAvatar(image: image, token: token)
                
                await MainActor.run {
                    // 更新本地用户资料
                    self.userProfile?.avatar = avatarUrl
                    self.isUploadingAvatar = false
                }
                
                // 重新加载用户资料
                loadUserProfile()
                
            } catch {
                await MainActor.run {
                    self.errorMessage = "头像上传失败: \(error.localizedDescription)"
                    self.isUploadingAvatar = false
                }
            }
        }
    }
}


struct ProfileView: View {
    
    
    @EnvironmentObject var appState: AppState  // 添加这行
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = ProfileViewModel()
    @State private var showingAlert = false
    
    @State private var showingImagePicker = false
    @State private var showingCamera = false
    @State private var showingActionSheet = false
    @State private var selectedImage: UIImage?
    
    // 修改密码页面
   @State private var showingChangePassword = false
    
   @State private var showingDeleteAccountAlert = false
   @State private var showingDeleteAccountConfirm = false
   @State private var isDeletingAccount = false
   @State private var deleteAccountError: String? = nil
   @State private var showDeleteAccountError = false
   @State private var deleteAccountPassword: String = ""  // 🔥 注销账号需要输入的绑定码
    
    // 添加关于我们WebView状态变量
   @State private var showingAboutUs = false
   
   // 问题反馈页面状态变量
   @State private var showingMessage = false
   
    
   // 添加设备绑定相关的状态变量
   @State private var showingQRScanner = false
   @State private var bindingSuccessMessage: String?
   @State private var showingBindingList = false  // 已绑定列表
    
   // 🔥 激活会员相关
   @State private var showingActivation = false
   @State private var startWithScanner = false  // 是否直接进入扫码模式
    
    var body: some View {
        NavigationView {
            mainContentView
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            viewModel.loadUserProfile()
        }
        .alert("错误", isPresented: $showingAlert) {
            Button("确定") { }
        } message: {
            Text(viewModel.errorMessage ?? "未知错误")
        }
        .onChange(of: viewModel.errorMessage, perform: { errorMessage in
            showingAlert = errorMessage != nil
        })
        .actionSheet(isPresented: $showingActionSheet) {
            avatarActionSheet
        }
        .sheet(isPresented: $showingImagePicker) {
            ImagePicker(selectedImage: $selectedImage, sourceType: .photoLibrary)
        }
        .sheet(isPresented: $showingCamera) {
            ImagePicker(selectedImage: $selectedImage, sourceType: .camera)
        }
        .onChange(of: selectedImage, perform: { image in
            if let image = image {
                viewModel.uploadAvatar(image)
                selectedImage = nil
            }
        })
        .fullScreenCover(isPresented: $showingChangePassword) {
            ChangePasswordView(onPasswordChangeSuccess: {
                // 🔥 修改密码成功后的完整退出流程
                handleLogoutAfterPasswordChange()
            })
            .environmentObject(appState)
        }
        .alert("注销账号", isPresented: $showingDeleteAccountConfirm) {
            // 🔥 绑定码输入框
            SecureField("请输入绑定码", text: $deleteAccountPassword)
            
            Button("取消", role: .cancel) {
                deleteAccountPassword = ""  // 清空密码
            }
            Button("确认注销", role: .destructive) {
                performDeleteAccount()
            }
        } message: {
            Text("注销后账号将无法恢复，所有数据将被删除。请输入绑定码确认注销。")
            }
        .alert("注销失败", isPresented: $showDeleteAccountError) {
            Button("确定") { }
        } message: {
            Text(deleteAccountError ?? "未知错误")
        }
        .fullScreenCover(isPresented: $showingAboutUs) {
            LocalWebView(fileName: "privacy_policy", title: "隐私政策")
        }
        .fullScreenCover(isPresented: $showingMessage) {
            MessageView()
        }
        // 添加二维码扫描（全屏显示）
        .fullScreenCover(isPresented: $showingQRScanner) {
            DeviceBindingQRScannerView(
                deviceUsername: viewModel.userProfile?.username ?? "",
                onBindingSuccess: { message in
                    bindingSuccessMessage = message
                }
            )
        }
        // 已绑定列表（全屏显示）
        .fullScreenCover(isPresented: $showingBindingList) {
            BindingListView()
        }
        // 绑定成功提示
        .alert("绑定结果", isPresented: Binding(
            get: { bindingSuccessMessage != nil },
            set: { if !$0 { bindingSuccessMessage = nil } }
        )) {
            Button("确定", role: .cancel) {
                bindingSuccessMessage = nil
            }
        } message: {
            Text(bindingSuccessMessage ?? "")
        }
        // 🔥 激活会员页面（全屏竖屏）
        .fullScreenCover(isPresented: $showingActivation, onDismiss: {
            // 重置扫码模式
            startWithScanner = false
        }) {
            ActivationView(
                onActivationSuccess: {
                    // 激活成功后：停止推流、断开WebSocket、返回登录界面
                    handleActivationSuccess()
                },
                startWithScanner: startWithScanner
            )
        }
    }
    
    // 格式化日期
    private func formatDate(_ dateString: String?) -> String {
        guard let dateString = dateString else { return "未知" }
        
        let formatter = DateFormatter()
        // 修改输入格式，支持毫秒和微秒
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        
        if let date = formatter.date(from: dateString) {
            // 输出格式：只显示年月日时分秒，不显示毫秒
            formatter.dateFormat = "yyyy年MM月dd日 HH:mm:ss"
            return formatter.string(from: date)
        }
        
        // 如果上面的格式不匹配，尝试不带毫秒的格式
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let date = formatter.date(from: dateString) {
            formatter.dateFormat = "yyyy年MM月dd日 HH:mm:ss"
            return formatter.string(from: date)
        }
        
        return dateString
    }
    
    private func handleChangePasswordAction() {
        showingChangePassword = true
       }
       
    // MARK: - 点击事件方法（暂时留空）
    
    private func handleRegistrationTimeAction() {
        print("注册时间点击事件")
        // TODO: 实现注册时间详情功能
    }
    
    // 处理设备绑定
    private func handleDeviceBindingAction() {
        print("📱 设备绑定点击事件")
        // 🔥 扫码前触发睡眠，完全释放摄像头资源
        NotificationCenter.default.post(name: NSNotification.Name("ReleaseCameraForScanner"), object: nil)
        showingQRScanner = true
    }
    
    
   
    private func handleDeleteAccountAction() {
        showingDeleteAccountConfirm = true
    }
    
    // 🔥 执行注销账号
    private func performDeleteAccount() {
        // 🔥 验证绑定码不能为空
        guard !deleteAccountPassword.isEmpty else {
            deleteAccountError = "请输入绑定码"
            showDeleteAccountError = true
            return
        }
        
        let password = deleteAccountPassword
        deleteAccountPassword = ""  // 清空密码
        isDeletingAccount = true
           
           Task {
               do {
                let response = try await APIService.shared.deleteAccount(secondaryPassword: password)
                   
                   await MainActor.run {
                    isDeletingAccount = false
                    print("✅ 注销账号成功: \(response.message)")
                    
                    // 🔥 发送停止推流通知
                    NotificationCenter.default.post(name: NSNotification.Name("StopPublishBeforeLogout"), object: nil)
                    
                    // 🔥 断开 WebSocket
                    WebSocketManager.shared.disconnect()
                    
                    // 🔥 清除本地账号信息
                    _ = AccountStorageManager.shared.clearAccountInfo()
                    
                    // 🔥 清除所有用户相关数据
                    UserDefaults.standard.set("", forKey: "jwt_token")
                    UserDefaults.standard.set("", forKey: "permanent_token")
                    UserDefaults.standard.set("", forKey: "username")
                    UserDefaults.standard.set("", forKey: "nickname")
                    UserDefaults.standard.set("", forKey: "device_id")
                    UserDefaults.standard.set("", forKey: "user_type")
                    UserDefaults.standard.set(false, forKey: "activated")
                    UserDefaults.standard.set(false, forKey: "trial_required")
                    
                    // 🔥 先关闭当前页面
                    dismiss()
                    
                    // 🔥 延迟返回登录页面（确保dismiss完成）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        appState.navigateToMonitorLogin()
                    }
                   }
                   
               } catch {
                   await MainActor.run {
                    isDeletingAccount = false
                    
                       if let apiError = error as? APIError {
                           switch apiError {
                           case .serverErrorWithMessage(let message):
                            deleteAccountError = message
                           case .serverError(let statusCode):
                            deleteAccountError = "服务器错误（状态码：\(statusCode)）"
                           default:
                            deleteAccountError = "注销失败，请重试"
                           }
                       } else {
                        deleteAccountError = "网络错误，请检查网络连接"
                       }
                    showDeleteAccountError = true
                }
            }
        }
    }
    
    private func handleVersionInfoAction() {
        print("版本号点击事件")
        // TODO: 实现版本信息功能
    }
    
    private func handleAboutUsAction() {
        showingAboutUs = true
    }
    
    
    // 返回按钮处理
    private func handleBackAction() {
        print("📱 从个人中心返回")
        dismiss()
    }
    
    private func handleLogoutAction() {
        print("退出点击事件")
        
        Task { @MainActor in
            // 1. 发送通知让ContentView停止推流
            print("📢 发送停止推流通知")
            NotificationCenter.default.post(name: NSNotification.Name("StopPublishBeforeLogout"), object: nil)
            
            // 2. 断开WebSocket
            print("🔌 断开WebSocket连接")
            WebSocketManager.shared.disconnect()
            
            // 3. 清理登录信息
            UserDefaults.standard.set("", forKey: "jwt_token")
            UserDefaults.standard.set("", forKey: "permanent_token")
            
            // 4. 延迟一下，等待推流停止
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
            
            // 5. 导航回登录页
            callBack()
        }
    }
    
    @MainActor
    private func callBack(){
        dismiss()
        appState.navigateToMonitorLogin()
    }
    
    // 🔥 修改密码成功后的完整退出流程
    private func handleLogoutAfterPasswordChange() {
        print("🔐 [ProfileView] 密码修改成功，执行完整退出流程")
        
        Task { @MainActor in
            // 1. 发送通知让ContentView停止推流
            print("📢 发送停止推流通知")
            NotificationCenter.default.post(name: NSNotification.Name("StopPublishBeforeLogout"), object: nil)
            
            // 2. 断开WebSocket
            print("🔌 断开WebSocket连接")
            WebSocketManager.shared.disconnect()
            
            // 3. 清理登录信息
            UserDefaults.standard.set("", forKey: "jwt_token")
            UserDefaults.standard.set("", forKey: "permanent_token")
            
            // 4. 延迟一下，等待推流停止
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
            
            // 5. 关闭ProfileView并导航回登录页
            callBack()
        }
    }
    
    // MARK: - 提取的子视图（减少编译器类型检查复杂度）
    
    private var mainContentView: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerView
                settingsListView
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("个人中心")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(content: {
            ToolbarItem(placement: .navigationBarLeading) {
                backButton
            }
        })
        .overlay(loadingOverlay)
    }
    
    private var headerView: some View {
        HStack(alignment: .center, spacing: 12) {
            // 头像（可点击，打开相册选择）
            Button(action: { showingActionSheet = true }) {
                avatarContent
            }
            .disabled(viewModel.isUploadingAvatar)
            
            // 昵称
            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.userProfile?.nickname ?? viewModel.userProfile?.username ?? "--")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Color(hex: "1A1A1A"))
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 25)
        .padding(.bottom, 20)
    }
    
    private var avatarContent: some View {
        ZStack {
            AsyncImage(url: URL(string: viewModel.userProfile?.avatar ?? "")) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.gray)
            }
            .frame(width: 60, height: 60)
            .clipShape(Circle())
            
            if viewModel.isUploadingAvatar {
                Circle().fill(Color.black.opacity(0.5)).frame(width: 60, height: 60)
                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white)).scaleEffect(1.0)
            }
        }
    }
    
    // 🔥 等级显示文本
    // 1=高清, 2=超清, 3=超高清, 4=超高帧
    private var levelDisplayText: String {
        let activated = UserDefaults.standard.bool(forKey: "activated")
        let level = UserDefaults.standard.integer(forKey: "activation_level")

        print("🏷️ [等级调试] activated=\(activated), level=\(level)")

        if !activated {
            return "试用用户"
        }

        switch level {
        case 4: return "超高帧"
        case 3: return "超高清"
        case 2: return "超清"
        case 1: return "高清"
        default: return "试用用户"
        }
    }
    
    // 🔥 等级图标
    // 1=高清, 2=超清, 3=超高清, 4=超高帧
    private var levelIcon: String {
        let level = UserDefaults.standard.integer(forKey: "activation_level")
        switch level {
        case 4: return "bolt.fill"       // 超高帧
        case 3: return "crown.fill"      // 超高清
        case 2: return "star.fill"       // 超清
        case 1: return "play.fill"       // 高清
        default: return "person.fill"    // 试用
        }
    }
    
    // 🔥 等级颜色
    // 1=高清, 2=超清, 3=超高清, 4=超高帧
    private var levelColor: Color {
        let level = UserDefaults.standard.integer(forKey: "activation_level")
        let activated = UserDefaults.standard.bool(forKey: "activated")

        if !activated {
            return Color(hex: "808080")  // 试用：灰色
        }

        switch level {
        case 4: return Color(hex: "FF6B00")  // 超高帧：橙色
        case 3: return Color(hex: "FFD700")  // 超高清：金色
        case 2: return Color(hex: "007AFF")  // 超清：蓝色
        case 1: return Color(hex: "34C759")  // 高清：绿色
        default: return Color(hex: "808080") // 默认：灰色
        }
    }
    
    private var settingsListView: some View {
        VStack(spacing: 0) {
            settingsSection1
            settingsSection2
            logoutButton
        }
        .background(Color.white)
    }
    
    private var settingsSection1: some View {
        VStack(spacing: 0) {
            ProfileRowView(icon: "clock", title: "注册时间", subtitle: formatDate(viewModel.userProfile?.createdAt), showArrow: true) {
                handleRegistrationTimeAction()
            }
            Divider().padding(.leading, 60)
            
            // 🔥 到期时间（已隐藏）
            // if isActivated {
            //     ProfileRowView(icon: "calendar.badge.clock", title: "到期时间", subtitle: formatExpireDate(), showArrow: false) {
            //         // 无操作
            //     }
            //     Divider().padding(.leading, 60)
            // }
            
            // 🔥 扫一扫（扫码绑定设备）
            ProfileRowView(icon: "qrcode.viewfinder", title: "扫一扫", subtitle: "扫描控制端二维码进行绑定", showArrow: true) {
                handleDeviceBindingAction()
            }
            Divider().padding(.leading, 60)
            
            ProfileRowView(icon: "lock", title: "修改密码", showArrow: true) {
                handleChangePasswordAction()
            }
            Divider().padding(.leading, 60)
            
            ProfileRowView(icon: "person.badge.minus", title: "注销账号", showArrow: true) {
                handleDeleteAccountAction()
            }
            Divider().padding(.leading, 60)
        }
    }
    
    // 🔥 是否已激活会员
    private var isActivated: Bool {
        return UserDefaults.standard.bool(forKey: "activated")
    }
    
    // 🔥 格式化到期时间
    private func formatExpireDate() -> String {
        guard let expireAt = UserDefaults.standard.string(forKey: "activation_expire_at"),
              !expireAt.isEmpty else {
            return "未知"
        }
        
        let formatter = DateFormatter()
        // 尝试解析 ISO8601 格式
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        
        if let date = formatter.date(from: expireAt) {
            formatter.dateFormat = "yyyy年MM月dd日"
            return formatter.string(from: date)
        }
        
        // 尝试不带毫秒的格式
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let date = formatter.date(from: expireAt) {
            formatter.dateFormat = "yyyy年MM月dd日"
            return formatter.string(from: date)
        }
        
        // 尝试只有日期的格式
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: expireAt) {
            formatter.dateFormat = "yyyy年MM月dd日"
            return formatter.string(from: date)
        }
        
        return expireAt
    }
    
    private var settingsSeparator: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.2))
            .frame(height: 8)
            .padding(.vertical, 20)
    }
    
    private var settingsSection2: some View {
        VStack(spacing: 0) {
            ProfileRowView(icon: "info.circle", title: "版本号", subtitle: "1.0.0", showArrow: true) {
                handleVersionInfoAction()
            }
            Divider().padding(.leading, 60)
            
            ProfileRowView(icon: "questionmark.circle", title: "关于我们", showArrow: true) {
                handleAboutUsAction()
            }
            Divider().padding(.leading, 60)
            
            Button(action: { showingMessage = true }) {
                HStack(spacing: 16) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 20))
                        .foregroundColor(.primary)
                        .frame(width: 24, height: 24)

                    Text("问题反馈")
                        .font(.system(size: 16))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.red)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Color.white)
            }
        }
    }
    
    private var logoutButton: some View {
        Button(action: handleLogoutAction) {
            Text("退出")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Color(hex: "FAFAFA"))
                .frame(width: 160, height: 46)
                .background(Color(hex: "CCCCCC"))
                .cornerRadius(10)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
        .padding(.bottom, 40)
    }
    
    private var backButton: some View {
        Button(action: { handleBackAction() }) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Color(hex: "1A1A1A"))
        }
    }
    
    private var loadingOverlay: some View {
        Group {
            if viewModel.isLoading {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.3))
            }
        }
    }
    
    private var avatarActionSheet: ActionSheet {
        ActionSheet(
            title: Text("选择头像"),
            message: Text("请选择图片来源"),
            buttons: [
                .default(Text("相机")) { showingCamera = true },
                .default(Text("相册")) { showingImagePicker = true },
                .cancel(Text("取消"))
            ]
        )
    }
    
    // 🔥 激活会员行视图
    private var activationRowView: some View {
        HStack(spacing: 16) {
            // 图标
            Image(systemName: "key.fill")
                .font(.system(size: 20))
                .foregroundColor(.primary)
                .frame(width: 24, height: 24)
            
            // 标题和副标题
            VStack(alignment: .leading, spacing: 2) {
                Text("激活会员")
                    .font(.system(size: 16))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                Text(getActivationStatusText())
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            // 扫码按钮
            Button(action: {
                // 🔥 扫码前触发睡眠，完全释放摄像头资源
                NotificationCenter.default.post(name: NSNotification.Name("ReleaseCameraForScanner"), object: nil)
                startWithScanner = true
                showingActivation = true
            }) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 20))
                    .foregroundColor(.primary)
                    .padding(8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
            }
            
            // 箭头
            Image(systemName: "chevron.right")
                .font(.system(size: 14))
                .foregroundColor(.gray)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            startWithScanner = false
            handleActivationAction()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
    }
    
    // 🔥 获取激活状态文本
    private func getActivationStatusText() -> String {
        let activated = UserDefaults.standard.bool(forKey: "activated")
        let levelName = UserDefaults.standard.string(forKey: "activation_level_name") ?? ""
        
        if activated && !levelName.isEmpty {
            return "\(levelName)"
        } else {
            return "未激活"
        }
    }
    
    // 🔥 处理激活按钮点击
    private func handleActivationAction() {
        showingActivation = true
    }
    
    // 🔥 激活成功后的处理
    private func handleActivationSuccess() {
        print("✅ [ProfileView] 激活成功，准备返回登录界面")
        
        Task { @MainActor in
            // 1. 发送通知让ContentView停止推流
            print("📢 发送停止推流通知")
            NotificationCenter.default.post(name: NSNotification.Name("StopPublishBeforeLogout"), object: nil)
            
            // 2. 断开WebSocket
            print("🔌 断开WebSocket连接")
            WebSocketManager.shared.disconnect()
            
            // 3. 清理登录信息（保留账号密码，只清token）
            UserDefaults.standard.set("", forKey: "jwt_token")
            UserDefaults.standard.set("", forKey: "permanent_token")
            
            // 4. 延迟一下，等待推流停止
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
            
            // 5. 导航回登录页
            callBack()
        }
    }
    
}

// MARK: - 设置行组件
struct ProfileRowView: View {
    let icon: String
    let title: String
    let subtitle: String?
    let showArrow: Bool
    let action: () -> Void
    
    init(icon: String, title: String, subtitle: String? = nil, showArrow: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.showArrow = showArrow
        self.action = action
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // 图标
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(.primary)
                    .frame(width: 24, height: 24)
                
                // 标题和副标题
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                
                // 箭头
                if showArrow {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color.white)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 绑定确认视图
struct BindingConfirmView: View {
    let deviceUsername: String
    let controlUsername: String
    let onSuccess: (String) -> Void  // 成功回调，传递消息
    let onCancel: () -> Void
    
    // 状态变量
    @State private var secondaryPassword: String = ""
    @State private var isLoading: Bool = false
    @State private var currentStep: BindingStep = .ready
    @State private var statusMessage: String = ""
    @State private var errorMessage: String?
    
    // 绑定步骤枚举
    enum BindingStep {
        case ready           // 准备就绪
        case creatingBinding // 正在创建绑定记录
        case verifyingDevice // 正在验证设备端
        case success         // 绑定成功
        case failed          // 绑定失败
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    // 顶部图标
                    VStack(spacing: 16) {
                        Image(systemName: stepIcon)
                            .font(.system(size: 60))
                            .foregroundColor(stepIconColor)
                        
                        Text("确认设备绑定")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("请确认绑定信息并输入绑定码")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 30)
                    .padding(.bottom, 24)
                    
                    // 绑定信息表单
                    VStack(spacing: 0) {
                        // 设备端用户名
                        BindingInfoRow(
                            icon: "iphone",
                            title: "设备端用户名",
                            value: deviceUsername,
                            iconColor: .green
                        )
                        
                        Divider()
                            .padding(.leading, 56)
                        
                        // 控制端用户名
                        BindingInfoRow(
                            icon: "desktopcomputer",
                            title: "控制端用户名",
                            value: controlUsername,
                            iconColor: .orange
                        )
                    }
                    .background(Color.white)
                    .cornerRadius(12)
                    .padding(.horizontal, 20)
                    
                    // 绑定码输入区域
                    VStack(alignment: .leading, spacing: 12) {
                        Text("绑定码")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        SecureField("请输入您的绑定码", text: $secondaryPassword)
                            .textFieldStyle(PlainTextFieldStyle())
                            .padding()
                            .background(Color.white)
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                            .disabled(isLoading)
                        
                        Text("绑定码用于验证绑定操作的安全性")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    
                    // 状态显示区域
                    if !statusMessage.isEmpty || errorMessage != nil {
                        VStack(spacing: 12) {
                            // 进度状态
                            if isLoading {
                                HStack(spacing: 12) {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text(statusMessage)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } else if currentStep == .success {
                                HStack(spacing: 12) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text(statusMessage)
                                        .font(.subheadline)
                                        .foregroundColor(.green)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            
                            // 错误信息
                            if let error = errorMessage {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.red)
                                    Text(error)
                                        .font(.subheadline)
                                        .foregroundColor(.red)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding()
                        .background(Color.white)
                        .cornerRadius(12)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                    }
                    
                    // 提示信息
                    VStack(alignment: .leading, spacing: 8) {
                        Label {
                            Text("绑定后，控制端需要同时验证才能生效")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } icon: {
                            Image(systemName: "info.circle")
                                .foregroundColor(.primary)
                        }
                        
                        Label {
                            Text("验证通过后，控制端将可以远程查看此设备")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } icon: {
                            Image(systemName: "eye")
                                .foregroundColor(.primary)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    
                    Spacer(minLength: 30)
                    
                    // 底部按钮
                    VStack(spacing: 12) {
                        // 确认绑定按钮
                        Button(action: startBinding) {
                            HStack {
                                if isLoading {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                }
                                Text(buttonText)
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(buttonEnabled ? Color.blue : Color.blue.opacity(0.4))
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(!buttonEnabled)
                        
                        // 取消按钮
                        Button(action: onCancel) {
                            Text("取消")
                                .fontWeight(.medium)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.gray.opacity(0.1))
                                .foregroundColor(.primary)
                                .cornerRadius(12)
                        }
                        .disabled(isLoading)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        onCancel()
                    }
                    .disabled(isLoading)
                }
            })
        }
    }
    
    // MARK: - 计算属性
    
    private var stepIcon: String {
        switch currentStep {
        case .ready, .creatingBinding, .verifyingDevice:
            return "link.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        }
    }
    
    private var stepIconColor: Color {
        switch currentStep {
        case .ready, .creatingBinding, .verifyingDevice:
            return .blue
        case .success:
            return .green
        case .failed:
            return .red
        }
    }
    
    private var buttonText: String {
        switch currentStep {
        case .ready:
            return "确认绑定"
        case .creatingBinding:
            return "创建绑定中..."
        case .verifyingDevice:
            return "验证中..."
        case .success:
            return "完成"
        case .failed:
            return "重试"
        }
    }
    
    private var buttonEnabled: Bool {
        if isLoading { return false }
        if currentStep == .success { return true }
        return !secondaryPassword.isEmpty
    }
    
    // MARK: - 绑定流程
    
    private func startBinding() {
        // 如果已成功，关闭界面
        if currentStep == .success {
            onSuccess(statusMessage)
            return
        }
        
        // 验证绑定码
        guard !secondaryPassword.isEmpty else {
            errorMessage = "请输入绑定码"
            return
        }
        
        errorMessage = nil
        isLoading = true
        
        Task {
            await performBinding()
        }
    }
    
    private func performBinding() async {
        do {
            // 步骤1: 创建绑定记录
            await MainActor.run {
                currentStep = .creatingBinding
                statusMessage = "正在创建绑定记录..."
            }
            
            print("📝 步骤1: 创建绑定记录...")
            let createResponse = try await APIService.shared.createBinding(
                deviceUsername: deviceUsername,
                controlUsername: controlUsername
            )
            
            print("✅ 绑定记录创建成功, bindingId: \(createResponse.bindingId)")
            
            await MainActor.run {
                statusMessage = "绑定记录已创建 (ID: \(createResponse.bindingId))"
            }
            
            // 短暂延迟，让用户看到状态
            try await Task.sleep(nanoseconds: 500_000_000)
            
            // 步骤2: 验证设备端绑定码
            await MainActor.run {
                currentStep = .verifyingDevice
                statusMessage = "正在验证绑定码..."
            }
            
            print("📝 步骤2: 验证设备端绑定码...")
            let verifyResponse = try await APIService.shared.verifyDeviceBinding(
                bindingId: createResponse.bindingId,
                secondaryPassword: secondaryPassword
            )
            
            print("✅ 设备端验证成功")
            print("   - deviceVerified: \(verifyResponse.deviceVerified)")
            print("   - controlVerified: \(verifyResponse.controlVerified)")
            print("   - status: \(verifyResponse.status)")
            print("   - message: \(verifyResponse.message)")
            
            // 成功
            await MainActor.run {
                currentStep = .success
                statusMessage = verifyResponse.message
                isLoading = false
            }
            
        } catch {
            print("❌ 绑定失败: \(error.localizedDescription)")
            
            await MainActor.run {
                currentStep = .failed
                isLoading = false
                
                // 解析错误信息
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
        }
    }
}

// MARK: - 绑定信息行
struct BindingInfoRow: View {
    let icon: String
    let title: String
    let value: String
    let iconColor: Color
    
    var body: some View {
        HStack(spacing: 16) {
            // 图标
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(iconColor)
                .frame(width: 36, height: 36)
                .background(iconColor.opacity(0.1))
                .cornerRadius(8)
            
            // 标题和值
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(value)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

#Preview {
    ProfileView()
}

#Preview("BindingConfirmView") {
    BindingConfirmView(
        deviceUsername: "1md3it",
        controlUsername: "c71234",
        onSuccess: { _ in },
        onCancel: {}
    )
}
