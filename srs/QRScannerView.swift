import SwiftUI
import AVFoundation

// MARK: - 设备绑定二维码扫描视图（微信风格）
// 🔥 扫码成功后直接在同一页面显示确认界面

struct DeviceBindingQRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let deviceUsername: String  // 当前设备用户名
    let onBindingSuccess: (String) -> Void  // 绑定成功回调
    
    @State private var isScanning = true
    @State private var scannedCode: String = ""
    @State private var showError = false
    @State private var errorMessage = ""
    
    // 🔥 扫码成功后显示确认界面
    @State private var showConfirm = false
    @State private var isBinding = false
    @State private var bindingError: String?
    
    // 🔥 绑定码输入
    @State private var secondaryPassword: String = ""
    
    // 扫描框尺寸
    private let scanBoxSize: CGFloat = 260
    
    var body: some View {
        NavigationView {
            ZStack {
                if showConfirm {
                    // 🔥 扫码成功后显示确认界面（同一个页面内）
                    confirmView
                } else {
                    // 扫码界面
                    scannerView
                }
            }
            .navigationTitle(showConfirm ? "确认绑定" : "扫一扫")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        if showConfirm {
                            // 返回扫码界面
                            showConfirm = false
                            scannedCode = ""
                            secondaryPassword = ""  // 🔥 重置绑定码
                            isScanning = true
                        } else {
                            dismiss()
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(showConfirm ? Color(hex: "1A1A1A") : .white)
                    }
                }
            })
            .onAppear {
                // 设置导航栏样式
                updateNavigationBarAppearance(isConfirmView: false)
            }
            .onChange(of: showConfirm, perform: { isConfirm in
                updateNavigationBarAppearance(isConfirmView: isConfirm)
            })
        }
        .onChange(of: scannedCode, perform: { newValue in
            if !newValue.isEmpty && !showConfirm {
                handleScanResult(newValue)
            }
        })
        .alert("扫描错误", isPresented: $showError) {
            Button("确定") {
                // 重新开始扫描
                isScanning = true
            }
        } message: {
            Text(errorMessage)
        }
        .alert("绑定失败", isPresented: Binding(
            get: { bindingError != nil },
            set: { if !$0 { bindingError = nil } }
        )) {
            Button("确定") {
                bindingError = nil
            }
        } message: {
            Text(bindingError ?? "")
        }
    }
    
    // MARK: - 扫码界面
    private var scannerView: some View {
        GeometryReader { geometry in
            ZStack {
                // 相机预览
                DeviceBindingQRCodeScannerViewController(
                    isScanning: $isScanning,
                    scannedCode: $scannedCode,
                    onError: { error in
                        errorMessage = error
                        showError = true
                    }
                )
                .ignoresSafeArea()
                
                // 半透明遮罩 + 角标 + 扫描线（统一定位）
                ScannerOverlayView(
                    screenSize: geometry.size,
                    scanBoxSize: scanBoxSize
                )
                .ignoresSafeArea()
            }
        }
    }
    
    // MARK: - 确认绑定界面（灰白配风格）
    private var confirmView: some View {
        VStack(spacing: 0) {
            // 顶部间距
            Color.clear.frame(height: 40)
            
            // 设备信息区域
            VStack(spacing: 0) {
                // 图标
                Image(systemName: "link.circle")
                    .font(.system(size: 40))
                    .foregroundColor(.primary)
                    .padding(.bottom, 16)
                
                // 设备名称
                Text(deviceUsername)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Color(hex: "1A1A1A"))
                
                // 绑定到
                Text("绑定到 \(scannedCode)")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "808080"))
                    .padding(.top, 8)
            }
            .padding(.vertical, 24)
            
            // 分隔线
            Divider()
                .padding(.leading, 20)
            
            // 警告提示
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 16))
                    .foregroundColor(.orange)
                
                Text("绑定后，控制端可远程管理此设备")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "808080"))
                
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(hex: "F4F4F8"))
            
            // 绑定码输入区域
            VStack(alignment: .leading, spacing: 12) {
                Text("请输入绑定码")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "808080"))
                
                SecureField("绑定码", text: $secondaryPassword)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color(hex: "F4F4F8"))
                    .cornerRadius(10)
                    .foregroundColor(Color(hex: "1A1A1A"))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            
            Spacer()
            
            // 按钮区域
            VStack(spacing: 16) {
                // 确认绑定按钮
                Button(action: {
                    performBinding()
                }) {
                    if isBinding {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: "FAFAFA")))
                            .frame(width: 160, height: 46)
                    } else {
                        Text("确认绑定")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Color(hex: "FAFAFA"))
                            .frame(width: 160, height: 46)
                    }
                }
                .background(
                    secondaryPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBinding
                    ? Color(hex: "CCCCCC")
                    : Color.blue
                )
                .cornerRadius(10)
                .disabled(isBinding)
                
                // 重新扫码按钮
                Button(action: {
                    // 返回扫码界面
                    showConfirm = false
                    scannedCode = ""
                    secondaryPassword = ""  // 🔥 重置绑定码
                    isScanning = true
                }) {
                    Text("重新扫码")
                        .font(.system(size: 16))
                        .foregroundColor(Color(hex: "808080"))
                }
            }
            .padding(.bottom, 50)
        }
        .background(Color.white)
    }
    
    // MARK: - 更新导航栏外观
    private func updateNavigationBarAppearance(isConfirmView: Bool) {
        let appearance = UINavigationBarAppearance()
        if isConfirmView {
            // 确认界面：白色背景
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = .white
            appearance.titleTextAttributes = [.foregroundColor: UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)]
        } else {
            // 扫码界面：深色背景
            appearance.configureWithTransparentBackground()
            appearance.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        }
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
    
    // MARK: - 处理扫描结果
    private func handleScanResult(_ code: String) {
        print("📷 扫描到二维码: \(code)")
        
        // 停止扫描
        isScanning = false
        
        // 震动反馈
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        
        // 🔥 直接在同一页面显示确认界面
        withAnimation {
            showConfirm = true
        }
    }
    
    // MARK: - 执行绑定
    private func performBinding() {
        // 🔥 验证绑定码不为空
        guard !secondaryPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            bindingError = "请输入绑定码"
            return
        }
        
        isBinding = true
        
        Task {
            do {
                // 第一步：创建绑定记录
                let createResponse = try await APIService.shared.createBinding(
                    deviceUsername: deviceUsername,
                    controlUsername: scannedCode
                )
                
                print("✅ 创建绑定记录成功: bindingId=\(createResponse.bindingId)")
                
                // 第二步：验证设备端绑定码
                let verifyResponse = try await APIService.shared.verifyDeviceBinding(
                    bindingId: createResponse.bindingId,
                    secondaryPassword: secondaryPassword.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                
                print("✅ 设备端验证成功: deviceVerified=\(verifyResponse.deviceVerified)")
                
                await MainActor.run {
                    isBinding = false
                    // 绑定成功，关闭整个页面并回调
                    dismiss()
                    onBindingSuccess("绑定成功！已绑定到 \(createResponse.controlUsername)")
                }
            } catch let error as APIError {
                await MainActor.run {
                    isBinding = false
                    switch error {
                    case .serverErrorWithMessage(let msg):
                        bindingError = msg
                    default:
                        bindingError = error.localizedDescription
                    }
                }
            } catch {
                await MainActor.run {
                    isBinding = false
                    bindingError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - 扫描覆盖层（遮罩 + 角标 + 扫描线 + 提示文字）
struct ScannerOverlayView: View {
    let screenSize: CGSize
    let scanBoxSize: CGFloat
    
    // 角标参数
    private let cornerLength: CGFloat = 22
    private let cornerWidth: CGFloat = 4
    private let cornerColor = Color(red: 0.18, green: 0.8, blue: 0.44) // 微信绿
    
    // 扫描线动画状态
    @State private var scanLineOffset: CGFloat = 0
    
    var body: some View {
        // 计算扫描框的位置（居中）
        let boxOriginX = (screenSize.width - scanBoxSize) / 2
        let boxOriginY = (screenSize.height - scanBoxSize) / 2
        
        Canvas { context, size in
            let maskColor = Color.black.opacity(0.5)
            
            // 绘制四周遮罩（中间留空）
            // 顶部
            context.fill(
                Path(CGRect(x: 0, y: 0, width: screenSize.width, height: boxOriginY)),
                with: .color(maskColor)
            )
            // 底部
            context.fill(
                Path(CGRect(x: 0, y: boxOriginY + scanBoxSize, width: screenSize.width, height: screenSize.height - boxOriginY - scanBoxSize)),
                with: .color(maskColor)
            )
            // 左侧
            context.fill(
                Path(CGRect(x: 0, y: boxOriginY, width: boxOriginX, height: scanBoxSize)),
                with: .color(maskColor)
            )
            // 右侧
            context.fill(
                Path(CGRect(x: boxOriginX + scanBoxSize, y: boxOriginY, width: screenSize.width - boxOriginX - scanBoxSize, height: scanBoxSize)),
                with: .color(maskColor)
            )
            
            // 绘制四个角标
            let green = cornerColor
            
            // 左上角 L
            context.fill(Path(CGRect(x: boxOriginX, y: boxOriginY, width: cornerLength, height: cornerWidth)), with: .color(green))
            context.fill(Path(CGRect(x: boxOriginX, y: boxOriginY, width: cornerWidth, height: cornerLength)), with: .color(green))
            
            // 右上角 L
            context.fill(Path(CGRect(x: boxOriginX + scanBoxSize - cornerLength, y: boxOriginY, width: cornerLength, height: cornerWidth)), with: .color(green))
            context.fill(Path(CGRect(x: boxOriginX + scanBoxSize - cornerWidth, y: boxOriginY, width: cornerWidth, height: cornerLength)), with: .color(green))
            
            // 左下角 L
            context.fill(Path(CGRect(x: boxOriginX, y: boxOriginY + scanBoxSize - cornerWidth, width: cornerLength, height: cornerWidth)), with: .color(green))
            context.fill(Path(CGRect(x: boxOriginX, y: boxOriginY + scanBoxSize - cornerLength, width: cornerWidth, height: cornerLength)), with: .color(green))
            
            // 右下角 L
            context.fill(Path(CGRect(x: boxOriginX + scanBoxSize - cornerLength, y: boxOriginY + scanBoxSize - cornerWidth, width: cornerLength, height: cornerWidth)), with: .color(green))
            context.fill(Path(CGRect(x: boxOriginX + scanBoxSize - cornerWidth, y: boxOriginY + scanBoxSize - cornerLength, width: cornerWidth, height: cornerLength)), with: .color(green))
        }
        .overlay(
            // 扫描线（使用SwiftUI动画）
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            cornerColor.opacity(0),
                            cornerColor.opacity(0.8),
                            cornerColor.opacity(0)
                        ],
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
            Text("将二维码放入框内，即可自动扫描")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.8))
                .position(x: screenSize.width / 2, y: boxOriginY + scanBoxSize + 40)
        )
    }
}


// MARK: - 二维码扫描控制器（UIKit）

struct DeviceBindingQRCodeScannerViewController: UIViewControllerRepresentable {
    @Binding var isScanning: Bool
    @Binding var scannedCode: String
    let onError: (String) -> Void
    
    func makeUIViewController(context: Context) -> DeviceBindingQRScannerUIViewController {
        let controller = DeviceBindingQRScannerUIViewController()
        controller.delegate = context.coordinator
        return controller
    }
    
    func updateUIViewController(_ uiViewController: DeviceBindingQRScannerUIViewController, context: Context) {
        if isScanning {
            uiViewController.startScanning()
        } else {
            uiViewController.stopScanning()
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, DeviceBindingQRScannerDelegate {
        let parent: DeviceBindingQRCodeScannerViewController
        
        init(_ parent: DeviceBindingQRCodeScannerViewController) {
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

// MARK: - 二维码扫描 UIViewController

protocol DeviceBindingQRScannerDelegate: AnyObject {
    func didScanQRCode(_ code: String)
    func didFailWithError(_ error: String)
}

class DeviceBindingQRScannerUIViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: DeviceBindingQRScannerDelegate?
    
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var videoCaptureDevice: AVCaptureDevice?
    
    // 🔥 重试机制
    private var retryTimer: Timer?
    private var retryCount = 0
    private let maxRetries = 3
    private let retryInterval: TimeInterval = 2.0  // 每2秒检查一次是否需要重试
    
    // 🔥 防止重复回调
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
        stopRetryTimer()
    }
    
    deinit {
        stopRetryTimer()
    }
    
    private func setupCamera() {
        // 检查摄像头权限
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
        
        // 🔥 优化：使用高分辨率以提高扫描成功率
        if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
        }
        
        guard let device = AVCaptureDevice.default(for: .video) else {
            delegate?.didFailWithError("无法访问摄像头")
            return
        }
        
        videoCaptureDevice = device
        
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
        
        // 🔥 优化对焦设置
        configureFocus()
        
        // 🔥 修复：设置完成后立即开始扫描（解决权限回调后不自动扫描的问题）
        startScanning()
        
        // 🔥 启动重试定时器
        startRetryTimer()
    }
    
    // 🔥 优化对焦配置，提高扫描成功率
    private func configureFocus() {
        guard let device = videoCaptureDevice else { return }
        
        do {
            try device.lockForConfiguration()
            
            // 自动对焦
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
                print("📷 扫码相机：启用连续自动对焦")
            }
            
            // 自动曝光
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            
            // 对焦兴趣点设为中心
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            
            device.unlockForConfiguration()
        } catch {
            print("⚠️ 配置对焦失败: \(error)")
        }
    }
    
    // 🔥 手动触发对焦（用于重试时重新对焦）
    private func refocus() {
        guard let device = videoCaptureDevice else { return }
        
        do {
            try device.lockForConfiguration()
            
            // 先切换到自动对焦，触发一次对焦
            if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
                print("📷 扫码重试：触发自动对焦")
            }
            
            // 延迟后恢复连续对焦
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let device = self?.videoCaptureDevice else { return }
                do {
                    try device.lockForConfiguration()
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    device.unlockForConfiguration()
                } catch {}
            }
            
            device.unlockForConfiguration()
        } catch {
            print("⚠️ 重新对焦失败: \(error)")
        }
    }
    
    // 🔥 启动重试定时器
    private func startRetryTimer() {
        stopRetryTimer()
        retryCount = 0
        hasFoundCode = false
        
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: true) { [weak self] _ in
            self?.checkAndRetry()
        }
        print("📷 扫码：启动重试定时器")
    }
    
    // 🔥 停止重试定时器
    private func stopRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
    }
    
    // 🔥 检查并重试扫描
    private func checkAndRetry() {
        guard !hasFoundCode else {
            stopRetryTimer()
            return
        }
        
        retryCount += 1
        print("📷 扫码重试 #\(retryCount): 尝试重新对焦...")
        
        // 重新对焦
        refocus()
        
        // 确保扫描正在运行
        if captureSession?.isRunning == false {
            print("📷 扫码重试 #\(retryCount): 重新启动扫描...")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.captureSession?.startRunning()
            }
        }
        
        // 超过最大重试次数后停止定时器（但继续扫描）
        if retryCount >= maxRetries {
            print("📷 扫码：已达最大重试次数 \(maxRetries)，停止自动重试")
            stopRetryTimer()
        }
    }
    
    func startScanning() {
        hasFoundCode = false
        if captureSession?.isRunning == false {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.captureSession?.startRunning()
                print("📷 扫码：相机开始运行")
            }
        }
    }
    
    func stopScanning() {
        if captureSession?.isRunning == true {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.captureSession?.stopRunning()
                print("📷 扫码：相机停止运行")
            }
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }
    
    // AVCaptureMetadataOutputObjectsDelegate
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        // 🔥 防止重复回调
        guard !hasFoundCode else { return }
        
        if let metadataObject = metadataObjects.first {
            guard let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject else { return }
            guard let stringValue = readableObject.stringValue, !stringValue.isEmpty else { return }
            
            // 🔥 标记已找到二维码
            hasFoundCode = true
            
            print("📷 扫码成功: \(stringValue)")
            
            // 震动反馈
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            
            // 停止扫描和重试
            stopScanning()
            stopRetryTimer()
            
            // 通知代理
            delegate?.didScanQRCode(stringValue)
        }
    }
}

// SwiftUI预览
#Preview {
    DeviceBindingQRScannerView(
        deviceUsername: "test_device",
        onBindingSuccess: { message in
            print("绑定成功: \(message)")
        }
    )
}

