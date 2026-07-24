import SwiftUI

// 连接方式（登录页三选一，互斥，静态不自动切换）
enum ConnectModeOption: String, CaseIterable {
    case srs = "srs"
    case srt = "srt"
    case p2p = "p2p"

    var title: String {
        switch self {
        // ⭐ 2026-07-11：SRS=多人线路、P2P=单人线路（仅改显示名，rawValue 仍是 srs/p2p）
        case .srs: return "多人线路"
        case .srt: return "SRT"
        case .p2p: return "单人线路"
        }
    }

    /// 三条链路均可选（SRT 已接入独立链路，方案 A）。
    var isEnabled: Bool { true }

    /// 本地记忆 key
    static let storageKey = "selected_connect_mode"

    /// 读取上次选择（无则默认 SRS，与后端默认一致）
    static var lastSelected: ConnectModeOption {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return ConnectModeOption(rawValue: raw) ?? .srs
    }
}

// 监控端登录视图
struct MonitorLoginView: View {
    @EnvironmentObject var appState: AppState
    
    @State private var username: String = ""           // 显示用（有本地账号时显示前8位）
    @State private var fullUsername: String = ""       // 完整账号（用于登录）
    @State private var password: String = ""
    @State private var isPasswordVisible: Bool = false
    @State private var rememberPassword: Bool = false
    @State private var selectedConnectMode: ConnectModeOption = ConnectModeOption.lastSelected  // 连接方式（默认上次选择）
    @State private var selectedCodec: VideoCodecOption = VideoCodecOption.lastSelected  // ⭐ P2P编码二级选项（H264/H265，实现在 H265Support.swift）
    // ⭐ 第四十九章：SRS/SRT 也可选编码，与 P2P 独立记忆、默认 h264
    @State private var selectedCodecSrs: VideoCodecOption = VideoCodecOption.lastSelected(key: VideoCodecOption.srsStorageKey, defaultCodec: .h264)
    @State private var selectedCodecSrt: VideoCodecOption = VideoCodecOption.lastSelected(key: VideoCodecOption.srtStorageKey, defaultCodec: .h264)
    @State private var showAlert: Bool = false
    @State private var alertMessage: String = ""
    @State private var showRegisterView: Bool = false
    @State private var hasLocalAccount: Bool = false
    
    @State private var isLoading: Bool = false
    @State private var isLoggedIn: Bool = false
    @State private var loginStep: LoginStep = .idle
    @State private var boundControlCount: Int = 1  // 🔥 绑定的控制端数量
    
    @State private var showUserAgreement = false
    @State private var showPrivacyPolicy = false
    @State private var showAlreadyBoundAlert = false  // 已绑定账号提示
    @State private var showDeviceIdPage = false       // 🔥 设备ID查看页面
    // ⭐ 强制更新（总后台「App更新配置」下发最低版本+下载地址，本地版本低则弹不可绕过弹窗）
    @State private var showForceUpdate = false
    @State private var forceUpdateMessage = ""
    @State private var forceUpdateUrl = ""
        
    enum LoginStep {
        case idle
        case authenticating
        case connecting
        case success
        case failed
    }
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ZStack {
                // 渐变背景
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color(hex: "B1E8FA"), location: 0),
                        .init(color: Color(hex: "C6E0FA"), location: 0.5),
                        .init(color: Color(hex: "F4F4F9"), location: 1.0)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // 顶部安全区域占位（适配刘海/灵动岛）
                    Color.clear
                        .frame(height: 25)
                    
                    // 顶部导航栏
                    HStack {
                        // 关闭按钮
                        Button(action: {
                            appState.navigateBack()
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(Color(hex: "1A1A1A"))
                                .frame(width: 28, height: 28)
                        }
                        
                        Spacer()
                        
                        // 标题
                        Text("登录")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Color(hex: "1A1A1A"))
                        
                        Spacer()
                        
                        // 占位，保持标题居中
                        Color.clear.frame(width: 28, height: 28)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    
                    Spacer()
                        .frame(height: 50)
                    
                    // Logo 图标
                    Image("yqlicon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 94, height: 94)
                        .cornerRadius(9)
                    
                    Spacer()
                        .frame(height: 50)
                    
                    // 登录表单卡片
                    VStack(spacing: 0) {
                        // 账号输入行
                        HStack(spacing: 6) {
                            // 账号图标
                            ZStack {
                                Circle()
                                    .stroke(Color(hex: "B3B3B3"), lineWidth: 0.6)
                                    .frame(width: 20, height: 20)
                                
                                Image(systemName: "person.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(hex: "1A1A1A"))
                            }
                            .frame(width: 24, height: 24)
                            
                            TextField("请输入账号", text: $username)
                                .font(.system(size: 16))
                                .foregroundColor(Color(hex: "1A1A1A"))
                            
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        
                        // 分隔线
                        Divider()
                            .background(Color(hex: "F0F0F0"))
                            .padding(.leading, 50)
                        
                        // 密码输入行
                        HStack(spacing: 6) {
                            // 密码图标
                            ZStack {
                                Circle()
                                    .stroke(Color(hex: "B3B3B3"), lineWidth: 0.6)
                                    .frame(width: 20, height: 20)
                                
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(hex: "1A1A1A"))
                            }
                            .frame(width: 24, height: 24)
                            
                            if isPasswordVisible {
                                TextField("密码", text: $password)
                                    .font(.system(size: 16))
                                    .foregroundColor(password.isEmpty ? Color(hex: "A3A3A3") : Color(hex: "1A1A1A"))
                            } else {
                                SecureField("密码", text: $password)
                                    .font(.system(size: 16))
                                    .foregroundColor(password.isEmpty ? Color(hex: "A3A3A3") : Color(hex: "1A1A1A"))
                            }
                            
                            Spacer()
                            
                            // 眼睛图标
                            Button(action: {
                                isPasswordVisible.toggle()
                            }) {
                                Image(systemName: isPasswordVisible ? "eye" : "eye.slash")
                                    .font(.system(size: 14))
                                    .foregroundColor(Color(hex: "A3A3A3"))
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        
                        // 分隔线
                        Divider()
                            .background(Color(hex: "F0F0F0"))
                            .padding(.leading, 50)
                        
                        // 记住密码
                        HStack(spacing: 4) {
                            Button(action: {
                                rememberPassword.toggle()
                            }) {
                                ZStack {
                                    Circle()
                                        .stroke(Color(hex: "999999"), lineWidth: 1)
                                        .frame(width: 15, height: 15)
                                    
                                    if rememberPassword {
                                        Circle()
                                            .fill(Color(hex: "65AEF7"))
                                            .frame(width: 10, height: 10)
                                    }
                                }
                            }
                            
                            Text("记住密码")
                                .font(.system(size: 16))
                                .foregroundColor(Color(hex: "1A1A1A"))
                            
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)

                        // 分隔线
                        Divider()
                            .background(Color(hex: "F0F0F0"))
                            .padding(.leading, 50)

                        // 连接方式三选一（SRS / SRT / P2P，互斥，静态不自动切换）
                        HStack(spacing: 6) {
                            // 连接方式图标
                            ZStack {
                                Circle()
                                    .stroke(Color(hex: "B3B3B3"), lineWidth: 0.6)
                                    .frame(width: 20, height: 20)

                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(hex: "1A1A1A"))
                            }
                            .frame(width: 24, height: 24)

                            Text("连接方式")
                                .font(.system(size: 16))
                                .foregroundColor(Color(hex: "1A1A1A"))

                            Spacer()

                            HStack(spacing: 8) {
                                ForEach(ConnectModeOption.allCases, id: \.self) { mode in
                                    connectModeChip(mode)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)

                        // ⭐ 编码二级选项 H264/H265（第四十九章：P2P/SRS/SRT 都显示，各自独立记忆；UI 组件在 H265Support.swift）
                        if selectedConnectMode == .p2p {
                            Divider().background(Color(hex: "F0F0F0")).padding(.leading, 50)
                            CodecOptionChips(selected: $selectedCodec,
                                             storageKey: VideoCodecOption.storageKey, title: "单人编码")
                        } else if selectedConnectMode == .srs {
                            Divider().background(Color(hex: "F0F0F0")).padding(.leading, 50)
                            CodecOptionChips(selected: $selectedCodecSrs,
                                             storageKey: VideoCodecOption.srsStorageKey, title: "多人编码")
                        } else if selectedConnectMode == .srt {
                            Divider().background(Color(hex: "F0F0F0")).padding(.leading, 50)
                            CodecOptionChips(selected: $selectedCodecSrt,
                                             storageKey: VideoCodecOption.srtStorageKey, title: "SRT编码")
                        }
                    }
                    .background(Color.white)
                    .cornerRadius(16, corners: [.topLeft, .topRight])
                    .padding(.horizontal, 22)
                    
                    Spacer()
                        .frame(height: 88)  // 固定间距，让按钮更靠近表单
                    
                    // 登录按钮和协议
                    VStack(spacing: 12) {
                        // 登录按钮
                        Button(action: {
                            handleLogin()
                        }) {
                            HStack {
                                if isLoading {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                }
                                Text(getLoginButtonText())
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(
                                isLoading ? 
                                AnyView(Color.gray) :
                                AnyView(LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color(hex: "B7F4FC"),
                                        Color(hex: "93D6F9"),
                                        Color(hex: "65AEF7")
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                            )
                            .cornerRadius(8)
                        }
                        .disabled(isLoading)
                        .padding(.horizontal, 20)
                        
                        // 注册按钮（样式与登录按钮一致）
                        Button(action: {
                            // 不依赖本地缓存判断，直接进注册页
                            // RegisterView 内部会调 check-device 做真正的设备检查
                            showRegisterView = true
                        }) {
                            Text("注册")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            Color(hex: "B7F4FC"),
                                            Color(hex: "93D6F9"),
                                            Color(hex: "65AEF7")
                                        ]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .cornerRadius(8)
                        }
                        .padding(.horizontal, 20)
                        
                        // 协议文字（可点击）
                        HStack(spacing: 0) {
                            Text("登入即代表您已阅读")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "808080"))
                            
                            Button(action: {
                                showUserAgreement = true
                            }) {
                                Text("《用户协议》")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(hex: "65AEF7"))
                            }
                            
                            Text("与")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "808080"))
                            
                            Button(action: {
                                showPrivacyPolicy = true
                            }) {
                                Text("《隐私政策》")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(hex: "65AEF7"))
                            }
                        }
                    }
                    
                    Spacer()
                    
                    // 🔥 隐藏入口：点击底部区域跳转设备ID页面
                    Button(action: { showDeviceIdPage = true }) {
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 60)
                    }
                }
            }
            .onTapGesture {
                hideKeyboard()
            }
        }
        .navigationBarHidden(true)
        .fullScreenCover(isPresented: $showDeviceIdPage) {
            DeviceIdInfoView()
        }
        .onAppear {
            loadLocalAccountInfo()
            selectedConnectMode = ConnectModeOption.lastSelected  // 同步上次选择
            setupWebSocketNotificationListener()
            checkForceUpdate()   // ⭐ 强制更新检查（总后台「App更新配置」，公共接口）
        }
        .onDisappear {
            NotificationCenter.default.removeObserver(self, name: .webSocketConnectionStateChanged, object: nil)
        }
        .fullScreenCover(isPresented: $showRegisterView, onDismiss: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                loadLocalAccountInfo()
                print("📱 注册页面关闭，重新加载本地账号: hasLocalAccount=\(hasLocalAccount)")
            }
        }) {
            RegisterView(onRegisterSuccess: { registeredUsername, registeredPassword in
                print("✅ 注册成功回调: username=\(registeredUsername)")
                self.username = registeredUsername
                self.password = registeredPassword
                self.hasLocalAccount = true
            })
        }
        .alert("提示", isPresented: $showAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        // ⭐ 强制更新：只有「立即更新」一个按钮，点完 0.5s 后重新弹出——不可绕过
        .alert("发现新版本", isPresented: $showForceUpdate) {
            Button("立即更新") {
                if let url = URL(string: forceUpdateUrl) {
                    UIApplication.shared.open(url)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showForceUpdate = true }
            }
        } message: {
            Text(forceUpdateMessage)
        }
        .alert("提示", isPresented: $showAlreadyBoundAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text("您的设备已经绑定了账号（\(username)）\n如需解绑请联系管理员")
        }
        .fullScreenCover(isPresented: $showUserAgreement) {
            LocalWebView(fileName: "user_agreement", title: "用户协议")
        }
        .fullScreenCover(isPresented: $showPrivacyPolicy) {
            LocalWebView(fileName: "privacy_policy", title: "隐私政策")
        }
    }
    
    // MARK: - ⭐ App 强制更新（与 Android AppUpdateManager 同一接口同一语义）
    // 公共接口 GET /api/config/app-update（无需登录），返回 {config:"{\"ios\":{enabled,minVersion,downloadUrl},...}"}。
    // 本地 CFBundleShortVersionString < minVersion 且 enabled → 弹不可绕过的强更弹窗跳 downloadUrl。
    // 网络/解析失败一律放行（不能因接口抖动把用户锁在门外）。
    private func checkForceUpdate() {
        guard let url = URL(string: APIConfig.shared.baseURL + "/api/config/app-update") else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cfgStr = outer["config"] as? String,
                  let cfgData = cfgStr.data(using: .utf8),
                  let cfg = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any],
                  let iosCfg = cfg["ios"] as? [String: Any] else {
                print("📦 [强更] 检查失败(放行)")
                return
            }
            let enabled = (iosCfg["enabled"] as? Bool) ?? false
            let minVersion = (iosCfg["minVersion"] as? String) ?? ""
            let downloadUrl = (iosCfg["downloadUrl"] as? String) ?? ""
            guard enabled, !minVersion.isEmpty, !downloadUrl.isEmpty else {
                print("📦 [强更] 未开启或未配置 → 放行")
                return
            }
            let local = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            if MonitorLoginView.compareVersion(local, minVersion) < 0 {
                print("📦 [强更] 本地=\(local) < 最低=\(minVersion) → 强制更新 \(downloadUrl)")
                DispatchQueue.main.async {
                    forceUpdateUrl = downloadUrl
                    forceUpdateMessage = "当前版本 \(local) 已停止支持，请更新到 \(minVersion) 及以上版本后继续使用。"
                    showForceUpdate = true
                }
            } else {
                print("📦 [强更] 本地=\(local) ≥ 最低=\(minVersion) → 放行")
            }
        }.resume()
    }

    /// 语义化版本比较（"2.4" vs "2.4.1" 逐段数字比），返回 <0 / 0 / >0
    private static func compareVersion(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0.filter { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.filter { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    // 设置WebSocket通知监听
    private func setupWebSocketNotificationListener() {
        NotificationCenter.default.addObserver(
            forName: .webSocketConnectionStateChanged,
            object: nil,
            queue: .main
        ) { notification in
            print("🔔 收到STOMP连接状态变化通知")
            
            if let connectionStateRaw = notification.userInfo?["connectionState"] as? String,
               let connectionState = ConnectionState(rawValue: connectionStateRaw) {
                
                switch connectionState {
                case .connected:
                    print("✅ STOMP连接成功")
                    
                    if loginStep == .connecting {
                        print("✅ STOMP连接成功，更新登录状态")
                        loginStep = .success
                        isLoading = false
                        
                        if let permanentToken = UserDefaults.standard.string(forKey: "permanent_token") {
                            let scanValue = UserDefaults.standard.integer(forKey: "login_scan")
                            // 🔥 传递 boundControlCount + scan 决定跳转目标
                            appState.loginSuccess(token: permanentToken, boundControlCount: boundControlCount, scan: scanValue)
                        }
                    }
                    
                case .disconnected, .error:
                    print("❌ STOMP连接断开或出错")
                    
                    if loginStep == .connecting {
                        print("❌ STOMP连接失败")
                        loginStep = .failed
                        isLoading = false
                        showAlert(message: "连接失败，请检查网络")
                    }
                    
                case .connecting:
                    print("🔄 STOMP连接中...")
                }
            }
        }
    }

    // 连接方式单个选项芯片
    @ViewBuilder
    private func connectModeChip(_ mode: ConnectModeOption) -> some View {
        let isSelected = (selectedConnectMode == mode)
        let enabled = mode.isEnabled

        Button(action: {
            guard enabled else {
                showAlert(message: "\(mode.title) 即将上线，敬请期待")
                return
            }
            selectedConnectMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: ConnectModeOption.storageKey)
        }) {
            Text(mode.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(
                    !enabled ? Color(hex: "C4C4C4")
                    : (isSelected ? .white : Color(hex: "65AEF7"))
                )
                .frame(minWidth: 44)
                .padding(.vertical, 6)
                .background(
                    Group {
                        if !enabled {
                            Color(hex: "F0F0F0")
                        } else if isSelected {
                            Color(hex: "65AEF7")
                        } else {
                            Color(hex: "EAF4FE")
                        }
                    }
                )
                .cornerRadius(6)
        }
        .disabled(false)  // SRT 仍可点击以弹出提示
    }

    private func getLoginButtonText() -> String {
        switch loginStep {
        case .idle:
            return "立即登入"
        case .authenticating:
            return "验证中..."
        case .connecting:
            return "连接中..."
        case .success:
            return "登录成功"
        case .failed:
            return "立即登入"
        }
    }
    
    private func loadLocalAccountInfo() {
        if let savedAccount = AccountStorageManager.shared.loadAccountInfo() {
            // 🔥 保存完整账号用于登录
            fullUsername = savedAccount.collectorAccount
            // 🔥 显示前8位（昵称风格）
            username = String(fullUsername.prefix(8))
            password = savedAccount.password
            hasLocalAccount = true
            rememberPassword = true
            print("已加载本地账号: 显示=\(username), 完整=\(fullUsername)")
        } else {
            hasLocalAccount = false
            print("没有本地保存的账号信息")
        }
    }
    
    private func clearLocalAccount() {
        if AccountStorageManager.shared.clearAccountInfo() {
            username = ""
            fullUsername = ""
            password = ""
            hasLocalAccount = false
            showAlert(message: "已清除本地保存的账号信息")
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    
    private func handleLogin() {
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showAlert(message: "请输入用户名")
            return
        }
        
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showAlert(message: "请输入密码")
            return
        }
        
        isLoading = true
        loginStep = .authenticating
        
        Task {
            do {
                // 🔥 如果输入框的值跟本地前8位一致，用完整账号；否则用输入框的值（用户手动改过）
                let loginUsername: String
                if hasLocalAccount && username == String(fullUsername.prefix(8)) {
                    loginUsername = fullUsername  // 本地账号未被修改，传完整账号
                } else {
                    loginUsername = username      // 用户手动输入的，传什么就是什么
                }
                let loginResponse = try await APIService.shared.login(
                    username: loginUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                
                await MainActor.run {
                    UserDefaults.standard.set(loginResponse.token, forKey: "jwt_token")
                    UserDefaults.standard.set(loginResponse.permanentToken, forKey: "permanent_token")
                    UserDefaults.standard.set(loginResponse.username, forKey: "username")
                    UserDefaults.standard.set(loginResponse.deviceId, forKey: "device_id")
                    UserDefaults.standard.set(loginResponse.userType, forKey: "user_type")
                    
                    // 🔥 保存用户ID（用于问题反馈等功能）
                    if let userId = loginResponse.userId {
                        UserDefaults.standard.set(userId, forKey: "user_id")
                        print("✅ 保存用户ID: \(userId)")
                    }
                    
                    if let nickname = loginResponse.nickname {
                        UserDefaults.standard.set(nickname, forKey: "nickname")
                        print("✅ 保存昵称: \(nickname)")
                    }
                    
                    if let streamPushIp = loginResponse.streamPushIp {
                        UserDefaults.standard.set(streamPushIp, forKey: "stream_push_ip")
                        print("✅ 保存推流IP: \(streamPushIp)")
                    }

                    // ⭐ 连接方式：以用户在登录页的手动选择为准（静态、互斥、不自动切换），覆盖后端下发
                    let connectMode = selectedConnectMode.rawValue
                    UserDefaults.standard.set(connectMode, forKey: "connect_mode")
                    UserDefaults.standard.set(connectMode, forKey: ConnectModeOption.storageKey)  // 记住本次选择
                    UserDefaults.standard.set(loginResponse.forceRelay ?? false, forKey: "forceRelay")
                    UserDefaults.standard.set(loginResponse.maxP2PViewers ?? 4, forKey: "maxP2PViewers")
                    if let iceServers = loginResponse.iceServers,
                       let iceData = try? JSONEncoder().encode(iceServers) {
                        UserDefaults.standard.set(iceData, forKey: "iceServers")
                    }
                    print("✅ 连接方式(用户选): \(connectMode), 后端下发: \(loginResponse.connectMode ?? "nil"), forceRelay: \(loginResponse.forceRelay ?? false), maxP2PViewers: \(loginResponse.maxP2PViewers ?? 4), iceServers: \(loginResponse.iceServers?.count ?? 0)个")
                    
                    if let trialInfo = loginResponse.trialInfo {
                        saveTrialInfo(trialInfo)
                    }
                    
                    // 🔥 保存绑定控制端数量和scan字段
                    boundControlCount = loginResponse.boundControlCount ?? 1
                    let scanValue = loginResponse.scan ?? 0
                    UserDefaults.standard.set(scanValue, forKey: "login_scan")
                    print("✅ 绑定控制端数量: \(boundControlCount), scan: \(scanValue)")
                    
                    loginStep = .connecting
                }
                
                let thinConfig = try await ConfigManager.shared.getThinRemoteConfig(deviceId: loginResponse.deviceId)
                ConfigManager.shared.cacheThinConfig(thinConfig)
                
                await MainActor.run {
                    WebSocketManager.shared.connect(deviceId: loginResponse.deviceId)
                    
                    // 根据"记住密码"选项保存账号
                    if rememberPassword {
                        let savedAccountInfo = SavedAccountInfo(
                            collectorAccount: loginResponse.username,
                            controllerAccount: "",
                            password: password,
                            deviceId: loginResponse.deviceId,
                            savedDate: Date()
                        )
                        
                        if AccountStorageManager.shared.saveAccountInfo(savedAccountInfo) {
                            print("账号信息已保存到本地")
                        }
                    }
                }
                
            } catch let error as APIError {
                await MainActor.run {
                    loginStep = .failed
                    isLoading = false
                    
                    let errorMessage: String
                    switch error {
                    case .accountBanned(let reason):
                        errorMessage = "账号已被封禁\n原因：\(reason)"
                        print("❌ 账号被封禁: \(reason)")
                        
                    case .serverErrorWithMessage(let msg):
                        errorMessage = msg
                    default:
                        errorMessage = error.localizedDescription
                    }
                    
                    showAlert(message: errorMessage)
                }
            } catch {
                await MainActor.run {
                    loginStep = .failed
                    isLoading = false
                    showAlert(message: "登录失败：\(error.localizedDescription)")
                }
            }
        }
    }
    
    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }
    
    private func saveTrialInfo(_ trialInfo: TrialInfo) {
        UserDefaults.standard.set(trialInfo.trialRequired, forKey: "trial_required")
        UserDefaults.standard.set(trialInfo.activated ?? false, forKey: "activated")
        
        if let level = trialInfo.activationLevel {
            UserDefaults.standard.set(level, forKey: "activation_level")
        }
        if let levelName = trialInfo.activationLevelName {
            UserDefaults.standard.set(levelName, forKey: "activation_level_name")
        }
        if let expireAt = trialInfo.activationExpireAt {
            UserDefaults.standard.set(expireAt, forKey: "activation_expire_at")
        }
        if let qualityAccess = trialInfo.qualityAccess {
            UserDefaults.standard.set(qualityAccess, forKey: "quality_access")
        }
        
        // 🔥 日试用相关（新增）
        UserDefaults.standard.set(trialInfo.isDailyTrial ?? false, forKey: "is_daily_trial")
        if let activationRemaining = trialInfo.activationRemainingSeconds {
            UserDefaults.standard.set(activationRemaining, forKey: "activation_remaining_seconds")
        }
        
        UserDefaults.standard.set(trialInfo.trialEnded ?? false, forKey: "trial_ended")
        
        if let currentStage = trialInfo.currentStage {
            UserDefaults.standard.set(currentStage, forKey: "current_stage")
        }
        if let totalStages = trialInfo.totalStages {
            UserDefaults.standard.set(totalStages, forKey: "total_stages")
        }
        if let stageSeconds = trialInfo.stageSeconds {
            UserDefaults.standard.set(stageSeconds, forKey: "stage_seconds")
        }
        if let remainingSeconds = trialInfo.remainingSeconds {
            UserDefaults.standard.set(remainingSeconds, forKey: "remaining_seconds")
        }
        if let usedSeconds = trialInfo.usedSeconds {
            UserDefaults.standard.set(usedSeconds, forKey: "used_seconds")
        }
        
        let isDailyTrialStr = (trialInfo.isDailyTrial ?? false) ? ", 日试用" : ""
        print("✅ 保存试用信息: trialRequired=\(trialInfo.trialRequired), activated=\(trialInfo.activated ?? false), level=\(trialInfo.activationLevelName ?? "无")\(isDailyTrialStr)")
    }
}

// 圆角扩展 - 支持指定角
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

#Preview {
    MonitorLoginView()
}
