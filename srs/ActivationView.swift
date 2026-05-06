import SwiftUI
import AVFoundation

// MARK: - 激活页面
struct ActivationView: View {
    @Environment(\.dismiss) private var dismiss
    
    // 页面状态
    @State private var isLoading: Bool = true
    @State private var isActivated: Bool = false
    
    // 激活详情（已激活时显示）
    @State private var activationLevel: Int = 0
    @State private var activationLevelName: String = ""
    @State private var activationExpireAt: String = ""
    @State private var qualityAccess: [String] = []
    
    // 激活码输入（未激活时显示）
    @State private var activationCode: String = ""
    @State private var isActivating: Bool = false
    @State private var showAlert: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""
    @State private var isSuccess: Bool = false
    
    // 🔥 扫码相关
    @State private var showScanner: Bool = false
    
    // 激活成功回调
    var onActivationSuccess: (() -> Void)?
    
    // 🔥 是否直接进入扫码模式
    var startWithScanner: Bool = false
    
    var body: some View {
        NavigationView {
            ZStack {
                if showScanner {
                    // 🔥 扫码界面（同一页面内）
                    activationScannerView
                } else {
                    // 原有内容
                    ZStack {
                        // 背景 - 白色
                        Color.white
                            .ignoresSafeArea()
                        
                        if isLoading {
                            // 加载中
                            VStack(spacing: 16) {
                                ProgressView()
                                    .scaleEffect(1.5)
                                Text("正在获取激活状态...")
                                    .font(.system(size: 14))
                                    .foregroundColor(Color(hex: "808080"))
                            }
                        } else if isActivated {
                            // 已激活 - 显示激活详情
                            activatedDetailView
                        } else {
                            // 未激活 - 显示激活码输入
                            activationInputView
                        }
                    }
                }
            }
            .navigationTitle(showScanner ? "扫码激活" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        if showScanner {
                            // 返回输入界面
                            showScanner = false
                        } else {
                            dismiss()
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(showScanner ? .white : Color(hex: "1A1A1A"))
                    }
                }
            })
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("确定") {
                if isSuccess {
                    dismiss()
                    onActivationSuccess?()
                }
            }
        } message: {
            Text(alertMessage)
        }
        // 🔥 设置竖屏
        .onAppear {
            // 允许所有方向，设置为竖屏
            AppDelegate.orientationLock = .portrait
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
            
            // 设置导航栏为白色背景
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = .white
            appearance.titleTextAttributes = [.foregroundColor: UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)]
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
            
            // 获取激活状态
            fetchActivationStatus()
            
            // 🔥 如果是扫码模式启动，直接显示扫码界面
            if startWithScanner {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showScanner = true
                }
            }
        }
        .onChange(of: showScanner, perform: { isScanning in
            // 根据界面切换导航栏样式
            let appearance = UINavigationBarAppearance()
            if isScanning {
                appearance.configureWithTransparentBackground()
                appearance.backgroundColor = UIColor.black.withAlphaComponent(0.6)
                appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
            } else {
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = .white
                appearance.titleTextAttributes = [.foregroundColor: UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)]
            }
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
        })
    }
    
    // MARK: - 扫码界面
    private var activationScannerView: some View {
        ActivationScannerContentView(
            onCodeScanned: { code in
                // 扫到激活码后，填入并自动激活
                activationCode = code
                showScanner = false
                
                // 延迟一点点再激活，让界面切换完成
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    activateMembership()
                }
            },
            onCancel: {
                showScanner = false
            }
        )
    }
    
    // MARK: - 已激活详情视图（灰白配风格）
    private var activatedDetailView: some View {
        VStack(spacing: 0) {
            // 顶部间距
            Color.clear.frame(height: 30)
            
            // 图标区域
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 40))
                    .foregroundColor(activationLevel == 2 ? .orange : .primary)
                
                Text("已激活")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Color(hex: "1A1A1A"))
                
                Text(activationLevelName)
                    .font(.system(size: 14))
                    .foregroundColor(activationLevel == 2 ? .orange : Color(hex: "808080"))
            }
            .padding(.bottom, 30)
            
            // 激活详情卡片
            VStack(spacing: 0) {
                // 等级
                HStack {
                    Image(systemName: "star")
                        .font(.system(size: 16))
                        .foregroundColor(.primary)
                        .frame(width: 24)
                    Text("会员等级")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "808080"))
                    Spacer()
                    Text(activationLevelName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(hex: "1A1A1A"))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                
                Divider().padding(.leading, 56)
                
                // 到期时间
                HStack {
                    Image(systemName: "calendar")
                        .font(.system(size: 16))
                        .foregroundColor(.primary)
                        .frame(width: 24)
                    Text("到期时间")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "808080"))
                    Spacer()
                    Text(formatExpireDate(activationExpireAt))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(hex: "1A1A1A"))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                
                Divider().padding(.leading, 56)
                
                // 可用画质 - 行显示
                HStack {
                    Image(systemName: "video")
                        .font(.system(size: 16))
                        .foregroundColor(.primary)
                        .frame(width: 24)
                    Text("可用画质")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "808080"))
                    Spacer()
                    // 行显示画质标签
                    HStack(spacing: 8) {
                        ForEach(qualityAccess, id: \.self) { quality in
                            Text(quality)
                                .font(.system(size: 12))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(hex: "F4F4F8"))
                                .foregroundColor(Color(hex: "1A1A1A"))
                                .cornerRadius(6)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color(hex: "F4F4F8"))
            .cornerRadius(12)
            .padding(.horizontal, 16)
            
            Spacer()
            
            // 提示
            Text("如需续费或升级，请联系代理商")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "808080"))
                .padding(.bottom, 30)
        }
    }
    
    // MARK: - 激活码输入视图（灰白配风格）
    private var activationInputView: some View {
        VStack(spacing: 0) {
            // 顶部间距
            Color.clear.frame(height: 30)
            
            // 图标区域
            VStack(spacing: 12) {
                Image(systemName: "key")
                    .font(.system(size: 40))
                    .foregroundColor(.primary)
                
                Text("会员激活")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Color(hex: "1A1A1A"))
                
                Text("输入激活码解锁全部功能")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "808080"))
            }
            .padding(.bottom, 30)
            
            // 激活码输入区域
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("激活码")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "808080"))
                    
                    Spacer()
                    
                    // 🔥 扫码按钮
                    Button(action: {
                        // 🔥 扫码前触发睡眠，完全释放摄像头资源
                        NotificationCenter.default.post(name: NSNotification.Name("ReleaseCameraForScanner"), object: nil)
                        showScanner = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 14))
                            Text("扫码")
                                .font(.system(size: 14))
                        }
                        .foregroundColor(.blue)
                    }
                }
                
                TextField("请输入激活码 (XXXX-XXXX-XXXX-XXXX)", text: $activationCode)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color(hex: "F4F4F8"))
                    .cornerRadius(10)
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "1A1A1A"))
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)
            }
            .padding(.horizontal, 16)
            
            Spacer().frame(height: 30)
            
            // 激活按钮
            Button(action: {
                activateMembership()
            }) {
                if isActivating {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: "FAFAFA")))
                        .frame(width: 160, height: 46)
                } else {
                    Text("立即激活")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Color(hex: "FAFAFA"))
                        .frame(width: 160, height: 46)
                }
            }
            .background(isActivating || activationCode.isEmpty ? Color(hex: "CCCCCC") : Color.blue)
            .cornerRadius(10)
            .disabled(isActivating || activationCode.isEmpty)
            
            Spacer().frame(height: 30)
            
            // 等级说明
            VStack(alignment: .leading, spacing: 12) {
                Text("会员等级说明")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "808080"))
                
                VStack(spacing: 0) {
                    LevelInfoRow(
                        level: "白银会员",
                        description: "标清、高清画质",
                        color: .gray
                    )
                    
                    Divider().padding(.leading, 24)
                    
                    LevelInfoRow(
                        level: "黄金会员",
                        description: "标清、高清、超高帧、超清画质",
                        color: .orange
                    )
                }
                .background(Color(hex: "F4F4F8"))
                .cornerRadius(12)
            }
            .padding(.horizontal, 16)
            
            Spacer()
            
            // 联系客服
            Text("如需获取激活码，请联系代理商")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "808080"))
                .padding(.bottom, 30)
        }
    }
    
    // MARK: - 获取激活状态
    private func fetchActivationStatus() {
        Task {
            do {
                let status = try await APIService.shared.getActivationStatus()
                
                await MainActor.run {
                    isActivated = status.activated
                    
                    if status.activated {
                        activationLevel = status.activationLevel ?? 0
                        activationLevelName = status.activationLevelName ?? "未知"
                        activationExpireAt = status.activationExpireAt ?? ""
                        qualityAccess = status.qualityAccess ?? []
                        
                        print("✅ 已激活: \(activationLevelName), 到期: \(activationExpireAt)")
                    } else {
                        print("📋 未激活，显示激活码输入界面")
                    }
                    
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    print("❌ 获取激活状态失败: \(error)")
                    // 获取失败时，默认显示激活码输入界面
                    isActivated = false
                    isLoading = false
                }
            }
        }
    }
    
    // MARK: - 激活会员
    private func activateMembership() {
        let code = activationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            showError("请输入激活码")
            return
        }
        
        isActivating = true
        
        Task {
            do {
                let response = try await APIService.shared.activateMembership(code: code)
                
                await MainActor.run {
                    isActivating = false
                    
                    // 更新本地激活状态
                    UserDefaults.standard.set(false, forKey: "trial_required")
                    UserDefaults.standard.set(true, forKey: "activated")
                    UserDefaults.standard.set(response.level, forKey: "activation_level")
                    UserDefaults.standard.set(response.levelName, forKey: "activation_level_name")
                    UserDefaults.standard.set(response.expireAt, forKey: "activation_expire_at")
                    
                    // 根据等级设置可用画质
                    if response.level == 1 {
                        UserDefaults.standard.set(["标清", "高清"], forKey: "quality_access")
                    } else if response.level == 2 {
                        UserDefaults.standard.set(["标清", "高清", "超高帧", "超清"], forKey: "quality_access")
                    }
                    
                    print("✅ 激活成功: level=\(response.level), levelName=\(response.levelName)")
                    
                    // 显示成功提示
                    isSuccess = true
                    alertTitle = "激活成功"
                    alertMessage = response.message
                    showAlert = true
                }
            } catch let error as APIError {
                await MainActor.run {
                    isActivating = false
                    switch error {
                    case .serverErrorWithMessage(let msg):
                        showError(msg)
                    default:
                        showError(error.localizedDescription)
                    }
                }
            } catch {
                await MainActor.run {
                    isActivating = false
                    showError("激活失败：\(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - 格式化到期时间
    private func formatExpireDate(_ dateString: String) -> String {
        // 尝试解析 ISO 8601 格式
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let date = formatter.date(from: dateString) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "yyyy年MM月dd日"
            return displayFormatter.string(from: date)
        }
        
        // 尝试解析不带毫秒的格式
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: dateString) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "yyyy年MM月dd日"
            return displayFormatter.string(from: date)
        }
        
        // 尝试解析简单格式 "2026-12-16T10:30:00"
        let simpleFormatter = DateFormatter()
        simpleFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let date = simpleFormatter.date(from: dateString) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "yyyy年MM月dd日"
            return displayFormatter.string(from: date)
        }
        
        // 如果都解析失败，直接返回原字符串
        return dateString
    }
    
    private func showError(_ message: String) {
        isSuccess = false
        alertTitle = "激活失败"
        alertMessage = message
        showAlert = true
    }
}

// MARK: - 等级信息行（灰白配风格）
struct LevelInfoRow: View {
    let level: String
    let description: String
    let color: Color
    
    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            
            Text(level)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(hex: "1A1A1A"))
            
            Spacer()
            
            Text(description)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "808080"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white)
    }
}

// MARK: - 激活码扫描内容视图（全屏 + X关闭按钮）
struct ActivationScannerContentView: View {
    let onCodeScanned: (String) -> Void
    let onCancel: () -> Void
    
    @State private var isScanning = true
    @State private var scannedCode: String = ""
    @State private var showError = false
    @State private var errorMessage = ""
    
    private let scanBoxSize: CGFloat = 260
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 相机预览
                ActivationQRScannerViewController(
                    isScanning: $isScanning,
                    scannedCode: $scannedCode,
                    onError: { error in
                        errorMessage = error
                        showError = true
                    }
                )
                .ignoresSafeArea()
                
                // 扫描框覆盖层
                ActivationScannerOverlayView(
                    screenSize: geometry.size,
                    scanBoxSize: scanBoxSize
                )
                .ignoresSafeArea()
                
                // 顶部导航栏 - 标题和关闭按钮
                VStack {
                    HStack {
                        // X 关闭按钮
                        Button(action: {
                            onCancel()
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                        }
                        .padding(.leading, 8)
                        
                        Spacer()
                        
                        // 标题
                        Text("扫码激活")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                        
                        Spacer()
                        
                        // 占位，保持标题居中
                        Color.clear.frame(width: 44, height: 44)
                            .padding(.trailing, 8)
                    }
                    .frame(height: 44)
                    .padding(.top, geometry.safeAreaInsets.top)
                    .background(Color.black.opacity(0.6))
                    
                    Spacer()
                }
                .ignoresSafeArea(.all, edges: .top)
            }
        }
        .background(Color.black)
        .onChange(of: scannedCode, perform: { newValue in
            if !newValue.isEmpty {
                handleScanResult(newValue)
            }
        })
        .alert("扫描错误", isPresented: $showError) {
            Button("确定") {
                isScanning = true
            }
        } message: {
            Text(errorMessage)
        }
    }
    
    private func handleScanResult(_ code: String) {
        print("📷 [激活] 扫描到二维码: \(code)")
        
        // 停止扫描
        isScanning = false
        
        // 震动反馈
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        
        // 回调扫描结果
        onCodeScanned(code)
    }
}

// MARK: - 激活扫描覆盖层
struct ActivationScannerOverlayView: View {
    let screenSize: CGSize
    let scanBoxSize: CGFloat
    
    private let cornerLength: CGFloat = 22
    private let cornerWidth: CGFloat = 4
    private let cornerColor = Color.blue
    
    @State private var scanLineOffset: CGFloat = 0
    
    var body: some View {
        let boxOriginX = (screenSize.width - scanBoxSize) / 2
        let boxOriginY = (screenSize.height - scanBoxSize) / 2
        
        Canvas { context, size in
            let maskColor = Color.black.opacity(0.5)
            
            // 顶部遮罩
            context.fill(
                Path(CGRect(x: 0, y: 0, width: screenSize.width, height: boxOriginY)),
                with: .color(maskColor)
            )
            // 底部遮罩
            context.fill(
                Path(CGRect(x: 0, y: boxOriginY + scanBoxSize, width: screenSize.width, height: screenSize.height - boxOriginY - scanBoxSize)),
                with: .color(maskColor)
            )
            // 左侧遮罩
            context.fill(
                Path(CGRect(x: 0, y: boxOriginY, width: boxOriginX, height: scanBoxSize)),
                with: .color(maskColor)
            )
            // 右侧遮罩
            context.fill(
                Path(CGRect(x: boxOriginX + scanBoxSize, y: boxOriginY, width: screenSize.width - boxOriginX - scanBoxSize, height: scanBoxSize)),
                with: .color(maskColor)
            )
            
            // 四个角标
            // 左上角
            context.fill(Path(CGRect(x: boxOriginX, y: boxOriginY, width: cornerLength, height: cornerWidth)), with: .color(cornerColor))
            context.fill(Path(CGRect(x: boxOriginX, y: boxOriginY, width: cornerWidth, height: cornerLength)), with: .color(cornerColor))
            // 右上角
            context.fill(Path(CGRect(x: boxOriginX + scanBoxSize - cornerLength, y: boxOriginY, width: cornerLength, height: cornerWidth)), with: .color(cornerColor))
            context.fill(Path(CGRect(x: boxOriginX + scanBoxSize - cornerWidth, y: boxOriginY, width: cornerWidth, height: cornerLength)), with: .color(cornerColor))
            // 左下角
            context.fill(Path(CGRect(x: boxOriginX, y: boxOriginY + scanBoxSize - cornerWidth, width: cornerLength, height: cornerWidth)), with: .color(cornerColor))
            context.fill(Path(CGRect(x: boxOriginX, y: boxOriginY + scanBoxSize - cornerLength, width: cornerWidth, height: cornerLength)), with: .color(cornerColor))
            // 右下角
            context.fill(Path(CGRect(x: boxOriginX + scanBoxSize - cornerLength, y: boxOriginY + scanBoxSize - cornerWidth, width: cornerLength, height: cornerWidth)), with: .color(cornerColor))
            context.fill(Path(CGRect(x: boxOriginX + scanBoxSize - cornerWidth, y: boxOriginY + scanBoxSize - cornerLength, width: cornerWidth, height: cornerLength)), with: .color(cornerColor))
        }
        .overlay(
            // 扫描线
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [cornerColor.opacity(0), cornerColor.opacity(0.8), cornerColor.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: scanBoxSize - 40, height: 2)
                .shadow(color: cornerColor.opacity(0.6), radius: 8)
                .offset(y: scanLineOffset)
                .position(x: screenSize.width / 2, y: boxOriginY + scanBoxSize / 2)
                .onAppear {
                    scanLineOffset = -scanBoxSize / 2 + 20
                    withAnimation(Animation.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                        scanLineOffset = scanBoxSize / 2 - 20
                    }
                }
        )
        .overlay(
            // 提示文字
            Text("将激活码二维码放入框内")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.8))
                .position(x: screenSize.width / 2, y: boxOriginY + scanBoxSize + 40)
        )
    }
}

// MARK: - 激活二维码扫描控制器
struct ActivationQRScannerViewController: UIViewControllerRepresentable {
    @Binding var isScanning: Bool
    @Binding var scannedCode: String
    let onError: (String) -> Void
    
    func makeUIViewController(context: Context) -> ActivationQRScannerUIViewController {
        let controller = ActivationQRScannerUIViewController()
        controller.delegate = context.coordinator
        return controller
    }
    
    func updateUIViewController(_ uiViewController: ActivationQRScannerUIViewController, context: Context) {
        if isScanning {
            uiViewController.startScanning()
        } else {
            uiViewController.stopScanning()
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, ActivationQRScannerDelegate {
        let parent: ActivationQRScannerViewController
        
        init(_ parent: ActivationQRScannerViewController) {
            self.parent = parent
        }
        
        func didScanQRCode(_ code: String) {
            parent.scannedCode = code
        }
        
        func didFailWithError(_ error: String) {
            parent.onError(error)
        }
    }
}

// MARK: - 激活扫描代理协议
protocol ActivationQRScannerDelegate: AnyObject {
    func didScanQRCode(_ code: String)
    func didFailWithError(_ error: String)
}

// MARK: - 激活扫描 UIViewController
class ActivationQRScannerUIViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: ActivationQRScannerDelegate?
    
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasFoundCode = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startScanning()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanning()
    }
    
    private func setupCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCaptureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async {
                        self?.setupCaptureSession()
                    }
                } else {
                    self?.delegate?.didFailWithError("需要摄像头权限才能扫描二维码")
                }
            }
        default:
            delegate?.didFailWithError("没有摄像头权限")
        }
    }
    
    private func setupCaptureSession() {
        captureSession = AVCaptureSession()
        
        guard let captureSession = captureSession else { return }
        
        if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
        }
        
        guard let device = AVCaptureDevice.default(for: .video) else {
            delegate?.didFailWithError("无法访问摄像头")
            return
        }
        
        let videoInput: AVCaptureDeviceInput
        do {
            videoInput = try AVCaptureDeviceInput(device: device)
        } catch {
            delegate?.didFailWithError("无法创建视频输入")
            return
        }
        
        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        } else {
            delegate?.didFailWithError("无法添加视频输入")
            return
        }
        
        let metadataOutput = AVCaptureMetadataOutput()
        
        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        } else {
            delegate?.didFailWithError("无法添加元数据输出")
            return
        }
        
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer?.frame = view.layer.bounds
        previewLayer?.videoGravity = .resizeAspectFill
        
        if let previewLayer = previewLayer {
            view.layer.addSublayer(previewLayer)
        }
        
        // 配置对焦
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {}
        
        startScanning()
    }
    
    func startScanning() {
        hasFoundCode = false
        if captureSession?.isRunning == false {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.captureSession?.startRunning()
                print("📷 [激活扫码] 相机开始运行")
            }
        }
    }
    
    func stopScanning() {
        if captureSession?.isRunning == true {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.captureSession?.stopRunning()
                print("📷 [激活扫码] 相机停止运行")
            }
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }
    
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasFoundCode else { return }
        
        if let metadataObject = metadataObjects.first {
            guard let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject else { return }
            guard let stringValue = readableObject.stringValue, !stringValue.isEmpty else { return }
            
            hasFoundCode = true
            
            print("📷 [激活扫码] 扫码成功: \(stringValue)")
            
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            
            stopScanning()
            delegate?.didScanQRCode(stringValue)
        }
    }
}

// MARK: - 预览
#Preview {
    ActivationView()
}
