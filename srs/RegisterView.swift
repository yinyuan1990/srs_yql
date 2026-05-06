import SwiftUI
import Photos
import CommonCrypto  // 🔥 用于 SHA256 哈希

// MARK: - 数据模型

// 设备端注册请求
struct DeviceRegisterRequest: Codable {
    let username: String
    let nickname: String  // 🔥 新增昵称字段（必填，1-50位）
    let deviceId: String
    let password: String
    let secondaryPassword: String
    let securityQuestion1: String
    let securityAnswer1: String
    let securityQuestion2: String
    let securityAnswer2: String
    let securityQuestion3: String
    let securityAnswer3: String
}

// 设备端注册响应
struct DeviceRegisterResponse: Codable {
    let username: String
    let nickname: String?  // 🔥 新增昵称字段
    let deviceId: String
    let message: String
}

// 注册数据（用于界面显示）
struct RegisterData {
    let username: String
    let nickname: String  // 🔥 新增昵称字段
    let deviceId: String
    let password: String
    let secondaryPassword: String
    let message: String
}

// 默认密保问题配置响应
struct SecurityQuestionConfig: Codable {
    let id: Int
    let configKey: String
    let configValue: String
    let description: String
}

// MARK: - 注册主界面

struct RegisterView: View {
    @Environment(\.dismiss) private var dismiss
    
    // 注册状态
    @State private var isRegistering = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var registerResult: RegisterData?
    @State private var showSuccessView = false
    
    // 用户输入
    @State private var username = ""
    @State private var nickname = ""  // 🔥 新增昵称字段
    @State private var password = ""
    @State private var secondaryPassword = ""
    @State private var isPasswordVisible = false  // 密码可见性
    
    // 密保问题和答案（默认答案为1、2、3）
    @State private var question1 = "您的出生年月日是？"
    @State private var answer1 = "1"
    @State private var question2 = "您的老家是哪里？"
    @State private var answer2 = "2"
    @State private var question3 = "您最喜欢干的事是？"
    @State private var answer3 = "3"
    
    // 默认问题
    @State private var defaultQuestions: [String] = []
    @State private var isLoadingQuestions = false
    
    // 协议
    @State private var showUserAgreement = false
    @State private var showPrivacyPolicy = false
    
    // 设备ID
    private let deviceId = DeviceIDManager.shared.getDeviceID()
    
    // 注册成功后的回调
    var onRegisterSuccess: ((String, String) -> Void)?
    
    var body: some View {
        NavigationView {
            ZStack {
                // 背景 - 白色
                Color.white
                    .ignoresSafeArea()
                
                if showSuccessView, let result = registerResult {
                    // 注册成功界面
                    RegisterSuccessView(
                        registerData: result,
                        onSaveToAlbum: { saveAccountInfoToAlbum(result) },
                        onBackToLogin: { backToLoginWithCredentials(result) }
                    )
                } else {
                    VStack(spacing: 0) {
                        // 顶部安全区域
                        Color.clear.frame(height: 25)
                        
                        // 顶部导航栏
                        HStack {
                            Button(action: {
                                dismiss()
                            }) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(Color(hex: "1A1A1A"))
                            }
                            
                            Spacer()
                            
                            Text("监控注册")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(Color(hex: "1A1A1A"))
                            
                            Spacer()
                            
                            // 占位，保持标题居中
                            Color.clear.frame(width: 18)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        
                        // 分隔线
                        Divider()
                            .background(Color(hex: "F0F0F0"))
                        
                        // 可滚动内容
                        ScrollView {
                            VStack(spacing: 30) {
                                // 输入表单
                                VStack(spacing: 0) {
                                    // 账号输入（用户手动输入9-12位，注册时自动添加 Y- 前缀）
                                    HStack(spacing: 6) {
                                        ZStack {
                                            Circle()
                                                .stroke(Color(hex: "B3B3B3"), lineWidth: 0.6)
                                                .frame(width: 20, height: 20)
                                            Image(systemName: "person")
                                                .font(.system(size: 10))
                                                .foregroundColor(Color(hex: "1A1A1A"))
                                        }
                                        .frame(width: 24, height: 24)
                                        
                                        TextField("请输入账号(9-12位)", text: $username)
                                            .font(.system(size: 16))
                                            .keyboardType(.asciiCapable)
                                            .autocapitalization(.none)
                                            .disableAutocorrection(true)
                                            .onChange(of: username, perform: { newValue in
                                                // 限制只能输入字母和数字，最多12位
                                                let filtered = newValue.filter { $0.isLetter || $0.isNumber }
                                                if filtered.count > 12 {
                                                    username = String(filtered.prefix(12))
                                                } else if filtered != newValue {
                                                    username = filtered
                                                }
                                            })
                                        
                                        Spacer()
                                        
                                        // 显示当前输入长度
                                        Text("\(username.count)/12")
                                                .font(.system(size: 12))
                                            .foregroundColor(username.count >= 9 ? Color(hex: "4CAF50") : Color(hex: "A3A3A3"))
                                    }
                                    .padding(.vertical, 16)
                                    
                                    Divider().background(Color(hex: "F0F0F0"))
                                    
                                    // 登录密码
                                    HStack(spacing: 6) {
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
                                            TextField("请输入登录密码", text: $password)
                                                .font(.system(size: 16))
                                        } else {
                                            SecureField("请输入登录密码", text: $password)
                                                .font(.system(size: 16))
                                        }
                                        
                                        Spacer()
                                        
                                        Button(action: { isPasswordVisible.toggle() }) {
                                            Image(systemName: isPasswordVisible ? "eye" : "eye.slash")
                                                .font(.system(size: 14))
                                                .foregroundColor(Color(hex: "A3A3A3"))
                                        }
                                    }
                                    .padding(.vertical, 16)
                                    
                                    Divider().background(Color(hex: "F0F0F0"))
                                    
                                    // 绑定码
                                    HStack(spacing: 6) {
                                        ZStack {
                                            Circle()
                                                .stroke(Color(hex: "B3B3B3"), lineWidth: 0.6)
                                                .frame(width: 20, height: 20)
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 10))
                                                .foregroundColor(Color(hex: "1A1A1A"))
                                        }
                                        .frame(width: 24, height: 24)
                                        
                                        SecureField("请输入绑定码", text: $secondaryPassword)
                                            .font(.system(size: 16))
                                    }
                                    .padding(.vertical, 16)
                                    
                                    Divider().background(Color(hex: "F0F0F0"))
                                }
                                .padding(.horizontal, 22)
                                
                                // 立即注册按钮（样式与登录按钮一致）
                                Button(action: {
                                    handleRegister()
                                }) {
                                    HStack {
                                        if isRegistering {
                                            ProgressView()
                                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                                .scaleEffect(0.8)
                                        }
                                        Text(isRegistering ? "注册中..." : "立即注册")
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundColor(.white)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .background(
                                        isRegistering ?
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
                                .disabled(isRegistering)
                                .padding(.horizontal, 20)
                                .padding(.top, 20)
                                
                                Spacer()
                            }
                        }
                    }
                }
            }
            .onTapGesture {
                hideKeyboard()
            }
        }
        .navigationBarHidden(true)
        .alert("提示", isPresented: $showAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .sheet(isPresented: $showUserAgreement) {
            LocalWebView(fileName: "user_agreement", title: "用户协议")
        }
        .sheet(isPresented: $showPrivacyPolicy) {
            LocalWebView(fileName: "privacy_policy", title: "隐私政策")
        }
        .onAppear {
            // 🔥 账号由用户手动输入，不再自动生成
            // 🔥 昵称自动生成为 Y- + 账号前8位（在注册时处理）
            // 加载默认密保问题
            loadDefaultSecurityQuestions()
        }
    }
    
    // MARK: - 计算属性
    
    // 验证是否可以注册
    private var canRegister: Bool {
        // 账号：9-12位
        guard username.count >= 9, username.count <= 12 else { return false }
        
        // 🔥 昵称自动生成，无需验证
        
        // 密码：6-20位
        guard password.count >= 6, password.count <= 20 else { return false }
        
        // 绑定码：6-20位
        guard secondaryPassword.count >= 6, secondaryPassword.count <= 20 else { return false }
        
        // 密保问题和答案不能为空
        guard !question1.isEmpty, !answer1.isEmpty else { return false }
        guard !question2.isEmpty, !answer2.isEmpty else { return false }
        guard !question3.isEmpty, !answer3.isEmpty else { return false }
        
        return true
    }
    
    // MARK: - 方法
    
    // 🔥 自动生成9位唯一账号（基于时间戳hash）
    private func generateUsername() -> String {
        // 获取当前时间戳（纳秒级精度确保唯一性）
        let timestamp = Int(Date().timeIntervalSince1970 * 1000000)
        
        // 使用时间戳的哈希值确保唯一性
        var hash = abs(timestamp.hashValue)
        
        // 转换为9位数字字符串
        // 取模确保在9位数范围内：100000000-999999999
        let nineDigitHash = 100000000 + (hash % 900000000)
        let username = String(nineDigitHash)
        
        print("🎲 自动生成9位账号: \(username)")
        return username
    }
    
    // 🔥 自动生成昵称（时间戳后3位 + 随机3位，确保唯一性）
    private func generateNickname() -> String {
        // 获取纳秒级时间戳后3位
        let nanoseconds = DispatchTime.now().uptimeNanoseconds
        let timePart = String("\(nanoseconds)".suffix(3))
        
        // 生成3位随机数 (000-999)
        let randomPart = String(format: "%03d", Int.random(in: 0...999))
        
        let nickname = timePart + randomPart
        print("🎲 自动生成昵称: \(nickname) (时间:\(timePart) + 随机:\(randomPart))")
        return nickname
    }
    
    // 🔥 自动生成 Y 开头的 8 位账号
    private func generateAutoUsername() -> String {
        // Y + 7位数字（时间戳后4位 + 随机3位）
        let nanoseconds = DispatchTime.now().uptimeNanoseconds
        let timePart = String("\(nanoseconds)".suffix(4))
        let randomPart = String(format: "%03d", Int.random(in: 0...999))
        let username = "Y" + timePart + randomPart
        print("🎲 自动生成账号: \(username)")
        return username
    }
    
    // 加载默认密保问题
    private func loadDefaultSecurityQuestions() {
        isLoadingQuestions = true
        print("🔄 开始加载默认密保问题...")
        
        Task {
            do {
                var questions: [String] = []
                
                // 加载3个默认密保问题
                for i in 1...3 {
                    if let question = try await loadSecurityQuestion(index: i) {
                        questions.append(question)
                        print("   ✅ 问题\(i): \(question)")
                    } else {
                        print("   ⚠️ 问题\(i) 加载失败，使用默认值")
                    }
                }
                
                // 🔥 在 MainActor.run 之前捕获 questions 为常量
                let loadedQuestions = questions
                
                await MainActor.run {
                    if !loadedQuestions.isEmpty {
                        defaultQuestions = loadedQuestions
                        if loadedQuestions.count > 0 { question1 = loadedQuestions[0] }
                        if loadedQuestions.count > 1 { question2 = loadedQuestions[1] }
                        if loadedQuestions.count > 2 { question3 = loadedQuestions[2] }
                        print("✅ 已加载 \(loadedQuestions.count) 个默认密保问题")
                    }
                    // 确保答案保持默认值 1、2、3
                    print("📝 默认答案: 1, 2, 3")
                    isLoadingQuestions = false
                }
            } catch {
                print("⚠️ 加载默认密保问题失败: \(error)")
                await MainActor.run {
                    isLoadingQuestions = false
                }
            }
        }
    }
    
    // 加载单个密保问题
    private func loadSecurityQuestion(index: Int) async throws -> String? {
        let endpoint: String
        switch index {
        case 1: endpoint = APIConfig.Auth.securityQuestion1
        case 2: endpoint = APIConfig.Auth.securityQuestion2
        case 3: endpoint = APIConfig.Auth.securityQuestion3
        default: return nil
        }
        
        guard let url = APIConfig.shared.url(for: endpoint) else {
            return nil
        }
        
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }
        
        let config = try JSONDecoder().decode(SecurityQuestionConfig.self, from: data)
        return config.configValue
    }
    
    // 处理注册
    private func handleRegister() {
        // 验证输入
        guard validateInput() else { return }
        
        isRegistering = true
        
        // 🔥 直接使用用户输入的账号（9-12位，不加前缀）
        let finalUsername = username.trimmingCharacters(in: .whitespaces)
        // 🔥 昵称自动生成为账号前8位
        let finalNickname = String(finalUsername.prefix(8))
        
        let requestBody = DeviceRegisterRequest(
            username: finalUsername,
            nickname: finalNickname,
            deviceId: deviceId,
            password: password,
            secondaryPassword: secondaryPassword,
            securityQuestion1: question1,
            securityAnswer1: answer1.trimmingCharacters(in: .whitespaces),
            securityQuestion2: question2,
            securityAnswer2: answer2.trimmingCharacters(in: .whitespaces),
            securityQuestion3: question3,
            securityAnswer3: answer3.trimmingCharacters(in: .whitespaces)
        )
        
        print("📝 开始注册设备端用户...")
        print("   - 账号: \(requestBody.username) (9-12位)")
        print("   - 昵称: \(requestBody.nickname)")
        print("   - 设备ID: \(requestBody.deviceId)")
        
        // 调用注册API
        registerDevice(request: requestBody) { result in
            DispatchQueue.main.async {
                isRegistering = false
                
                switch result {
                case .success(let response):
                    print("✅ 注册成功: \(response.message)")
                    
                    // 构建注册结果数据
                    let registerData = RegisterData(
                        username: response.username,
                        nickname: response.nickname ?? String(username.prefix(8)),
                        deviceId: response.deviceId,
                        password: password,
                        secondaryPassword: secondaryPassword,
                        message: response.message
                    )
                    
                    // 🔥 直接跳转登录界面（不再保存到相册）
                    backToLoginWithCredentials(registerData)
                    
                case .failure(let error):
                    print("❌ 注册失败: \(error.localizedDescription)")
                    showAlert(message: "注册失败：\(error.localizedDescription)")
                }
            }
        }
    }
    
    // 验证输入
    private func validateInput() -> Bool {
        // 账号验证（9-12位字母或数字）
        if username.count < 9 || username.count > 12 {
            showAlert(message: "账号必须是9-12位字母或数字")
            return false
        }
        
        let usernamePattern = "^[a-zA-Z0-9]{9,12}$"
        if username.range(of: usernamePattern, options: .regularExpression) == nil {
            showAlert(message: "账号只能包含字母和数字")
            return false
        }
        
        // 🔥 昵称自动生成，无需验证
        
        // 密码验证
        if password.count < 6 || password.count > 20 {
            showAlert(message: "登录密码长度必须在6到20位之间")
            return false
        }
        
        // 绑定码验证
        if secondaryPassword.count < 6 || secondaryPassword.count > 20 {
            showAlert(message: "绑定码长度必须在6到20位之间")
            return false
        }
        
        // 密保问题验证
        if answer1.isEmpty || answer2.isEmpty || answer3.isEmpty {
            showAlert(message: "请填写所有密保问题的答案")
            return false
        }
        
        return true
    }
    
    // 注册API调用
    private func registerDevice(request: DeviceRegisterRequest, completion: @escaping (Result<DeviceRegisterResponse, Error>) -> Void) {
        guard let url = APIConfig.shared.registerDeviceURL else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }
        
        var urlRequest = URLRequest(url: url, timeoutInterval: 15)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
        } catch {
            return completion(.failure(error))
        }

        let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            if let error = error {
                return completion(.failure(error))
            }

            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? -1
            let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<nil>"
            print("🔵 [Register] URL=\(url.absoluteString)")
            print("🔵 [Register] Status=\(status)")
            print("🔵 [Register] Body=\(bodyStr)")

            guard (200...299).contains(status), let data = data else {
                // 解析错误信息
                if let data = data,
                   let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMsg = errorJson["error"] as? String {
                    return completion(.failure(NSError(domain: errorMsg, code: status)))
                }
                return completion(.failure(NSError(domain: "HTTP \(status)", code: status)))
            }

            do {
                let response = try JSONDecoder().decode(DeviceRegisterResponse.self, from: data)
                completion(.success(response))
            } catch {
                print("❌ 解析响应失败: \(error)")
                completion(.failure(error))
            }
        }
        task.resume()
    }
    
    // 保存账号信息到相册
    private func saveAccountInfoToAlbum(_ data: RegisterData) {
        let accountInfo = """
        设备端注册成功！
        
        账号：\(data.username)
        昵称：\(data.nickname)
        设备ID：\(data.deviceId)
        登录密码：\(data.password)
        绑定码：\(data.secondaryPassword)
        
        密保问题1：\(question1)
        答案1：\(answer1)
        
        密保问题2：\(question2)
        答案2：\(answer2)
        
        密保问题3：\(question3)
        答案3：\(answer3)
        
        请妥善保管您的账号信息
        """
    
        // 创建图片
        let image = createAccountInfoImage(text: accountInfo)
        
        // 保存到相册（静默保存，不显示提示）
        PHPhotoLibrary.requestAuthorization { status in
            if status == .authorized {
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }) { success, error in
                        if success {
                        print("✅ 账号信息已自动保存到相册")
                        } else {
                        print("⚠️ 保存到相册失败: \(error?.localizedDescription ?? "未知错误")")
                    }
                }
            } else {
                print("⚠️ 无相册权限，跳过保存")
            }
        }
    }
    
    // 创建账号信息图片
    private func createAccountInfoImage(text: String) -> UIImage {
        let size = CGSize(width: 600, height: 900)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        return renderer.image { context in
            // 背景
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            
            // 文字
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .left
            paragraphStyle.lineSpacing = 8
            
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 16),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraphStyle
            ]
            
            let rect = CGRect(x: 30, y: 50, width: size.width - 60, height: size.height - 100)
            text.draw(in: rect, withAttributes: attributes)
        }
    }
    
    // 返回登录界面并自动填充
    private func backToLoginWithCredentials(_ data: RegisterData) {
        // 保存账号信息到本地
        let savedAccountInfo = SavedAccountInfo(
            collectorAccount: data.username,  // 设备端只有一个用户名
            controllerAccount: data.username,
            password: data.password,
            deviceId: data.deviceId,
            savedDate: Date()
        )
        
        if AccountStorageManager.shared.saveAccountInfo(savedAccountInfo) {
            print("✅ 账号信息已保存到本地")
        } else {
            print("❌ 保存账号信息失败")
        }
        
        // 回调登录界面，自动填充用户名和密码
        onRegisterSuccess?(data.username, data.password)
        dismiss()
    }
    
    // 显示提示信息
    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }
    
    // Toast提示（简单实现）
    private func showToast(message: String) {
        alertMessage = message
        showAlert = true
}

    // 隐藏键盘
    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}


// MARK: - 注册成功界面

struct RegisterSuccessView: View {
    let registerData: RegisterData
    let onSaveToAlbum: () -> Void
    let onBackToLogin: () -> Void
    
    var body: some View {
        ZStack {
            // 白色背景
            Color.white.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // 顶部安全区域
                Color.clear.frame(height: 60)
                
                // 成功图标
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(Color(hex: "4CAF50"))
                    .padding(.bottom, 16)
                
                Text("注册成功")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Color(hex: "1A1A1A"))
                    .padding(.bottom, 24)
                
                // 账号信息卡片
                VStack(alignment: .leading, spacing: 0) {
                    // 标题
                    Text("账号信息")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color(hex: "1A1A1A"))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    
                    Divider().background(Color(hex: "EEEEEE"))
                    
                    // 账号
                    AccountInfoRow(title: "账号", value: registerData.username)
                    Divider().background(Color(hex: "EEEEEE")).padding(.leading, 16)
                    
                    // 昵称
                    AccountInfoRow(title: "昵称", value: registerData.nickname)
                    Divider().background(Color(hex: "EEEEEE")).padding(.leading, 16)
                    
                    // 设备ID（可完整显示）
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("设备ID")
                                .font(.system(size: 14))
                                .foregroundColor(Color(hex: "666666"))
                            Spacer()
                            Button(action: {
                                UIPasteboard.general.string = registerData.deviceId
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 12))
                                    Text("复制")
                                        .font(.system(size: 12))
                                }
                                .foregroundColor(Color(hex: "65AEF7"))
                            }
                        }
                        Text(registerData.deviceId)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(hex: "1A1A1A"))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    
                    Divider().background(Color(hex: "EEEEEE")).padding(.leading, 16)
                    
                    // 登录密码
                    AccountInfoRow(title: "登录密码", value: registerData.password)
                }
                .background(Color(hex: "F4F4F8"))
                .cornerRadius(12)
                .padding(.horizontal, 16)
                
                // 提示信息
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "FF9800"))
                        Text("绑定码已设置，请妥善保管")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "666666"))
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "65AEF7"))
                        Text("密保问题可用于找回绑定码")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "666666"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                
                Spacer()
                
                // 操作按钮
                VStack(spacing: 12) {
                    Button(action: onSaveToAlbum) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 14))
                            Text("保存完整信息到相册")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundColor(Color(hex: "65AEF7"))
                        .frame(width: 200, height: 40)
                        .background(Color(hex: "65AEF7").opacity(0.1))
                        .cornerRadius(10)
                    }
                    
                    Button(action: onBackToLogin) {
                        Text("返回登录")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 160, height: 46)
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
                            .cornerRadius(10)
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }
}

// MARK: - 账号信息行组件

struct AccountInfoRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "666666"))
                .frame(width: 70, alignment: .leading)
            
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(hex: "1A1A1A"))
                .lineLimit(1)
            
            Spacer()
            
            Button(action: {
                UIPasteboard.general.string = value
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                    Text("复制")
                        .font(.system(size: 12))
                }
                .foregroundColor(Color(hex: "65AEF7"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - 设备ID管理器（持久化，卸载重装不变，防移机复制）

class DeviceIDManager {
    // 🔥 使用应用的 Bundle ID 作为 service，确保唯一性
    private let service = Bundle.main.bundleIdentifier ?? "com.aiqipai.deviceid"
    private let account = "persistent_device_identifier"
    
    // 单例模式，避免重复创建
    static let shared = DeviceIDManager()
    
    // 缓存设备ID，避免重复读取 Keychain
    private var cachedDeviceID: String?
    
    private init() {}
    
    /// 获取持久化设备ID
    /// 优先从 Keychain 读取（卸载重装后仍然存在）
    /// 如果 Keychain 没有，则生成新的并保存
    /// 🔥 使用 ThisDeviceOnly 属性，防止数据移机复制
    func getDeviceID() -> String {
        // 如果有缓存，直接返回
        if let cached = cachedDeviceID {
            return cached
        }
        
        // 🔥 Step 1: 尝试读取已有数据（兼容旧版本）
        if let existingID = getFromKeychain() {
            print("📱 [DeviceID] 从 Keychain 读取已有设备ID: \(existingID.prefix(8))...")
            
            // 🔥 Step 2: 属性升级 —— 将旧的 AfterFirstUnlock 升级为 ThisDeviceOnly
            // 这样老用户的设备ID不变，但属性变为不可迁移
            upgradeToThisDeviceOnly(existingID)
            
            cachedDeviceID = existingID
            return existingID
        }
        
        // 🔥 Step 3: Keychain 没有，生成新的UUID并保存（直接用 ThisDeviceOnly）
        let newID = generateUniqueID()
        if saveToKeychain(newID) {
            print("📱 [DeviceID] 生成新设备ID并保存到 Keychain (ThisDeviceOnly): \(newID.prefix(8))...")
            cachedDeviceID = newID
            return newID
        }
        
        // 保存失败时的降级方案：使用 IDFV
        print("⚠️ [DeviceID] Keychain 保存失败，降级使用 IDFV")
        let fallbackID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        cachedDeviceID = fallbackID
        return fallbackID
    }
    
    /// 生成唯一ID
    /// 使用 UUID + 时间戳 + 随机数，确保全球唯一
    private func generateUniqueID() -> String {
        let uuid = UUID().uuidString
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let random = Int.random(in: 1000...9999)
        // 格式: UUID-TIMESTAMP-RANDOM 的哈希
        let combined = "\(uuid)-\(timestamp)-\(random)"
        // 使用 SHA256 哈希，取前32位作为设备ID
        return combined.sha256Hash().prefix(32).uppercased()
    }
    
    // MARK: - Keychain 操作
    
    /// 🔥 属性升级：将旧的 AfterFirstUnlock 数据升级为 ThisDeviceOnly
    /// 老用户设备ID不变，只是更新 Keychain 存储属性为不可迁移
    private func upgradeToThisDeviceOnly(_ value: String) {
        // 读取当前项的属性
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let attrs = result as? [String: Any],
              let accessible = attrs[kSecAttrAccessible as String] as? String else {
            return
        }
        
        // 🔥 检查是否已经是 ThisDeviceOnly
        let thisDeviceOnlyValue = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        if accessible == thisDeviceOnlyValue {
            // 已经是 ThisDeviceOnly，无需升级
            return
        }
        
        // 🔥 需要升级：删除旧的 → 用 ThisDeviceOnly 重新保存
        print("🔄 [DeviceID] 属性升级: AfterFirstUnlock → ThisDeviceOnly (防移机)")
        
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        // 用 ThisDeviceOnly 重新保存（设备ID值不变）
        if saveToKeychain(value) {
            print("✅ [DeviceID] 属性升级成功，设备ID不变: \(value.prefix(8))...")
        } else {
            print("❌ [DeviceID] 属性升级失败，下次启动会重试")
        }
    }
    
    /// 保存到 Keychain（使用 ThisDeviceOnly 属性，防止移机复制）
    @discardableResult
    private func saveToKeychain(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        
        // 先尝试删除旧的（如果存在）
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        // 添加新的
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // 🔥🔥 关键改动：使用 ThisDeviceOnly 属性
            // ❌ 旧: kSecAttrAccessibleAfterFirstUnlock（会被 iCloud/iTunes 备份迁移）
            // ✅ 新: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly（绑定当前设备硬件，不可迁移）
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        
        if status == errSecSuccess {
            print("✅ [DeviceID] Keychain 保存成功 (ThisDeviceOnly, 防移机)")
            return true
        } else {
            print("❌ [DeviceID] Keychain 保存失败: \(status)")
            return false
        }
    }
    
    /// 从 Keychain 读取
    private func getFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess,
           let data = result as? Data,
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        
        if status != errSecItemNotFound {
            print("⚠️ [DeviceID] Keychain 读取错误: \(status)")
        }
        
        return nil
    }
    
    /// 清除设备ID（仅用于测试/调试）
    func clearDeviceID() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        cachedDeviceID = nil
        print("🗑️ [DeviceID] 已清除 Keychain 中的设备ID")
    }
}

// MARK: - String SHA256 扩展
extension String {
    func sha256Hash() -> String {
        guard let data = self.data(using: .utf8) else { return self }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// SwiftUI预览
#Preview {
    RegisterView()
}
