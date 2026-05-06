import SwiftUI
import AVFoundation

/// GPUImage 测试视图
/// 用于测试能否用 AVCaptureSession 直接获取 4:3 + 120fps
struct GPUImageTestView: View {
    @State private var currentFPS: Double = 0
    @State private var frameInfo: String = "等待中..."
    @State private var formatInfo: String = "分析中..."
    @State private var isRunning: Bool = false
    @State private var useFrontCamera: Bool = true
    @State private var testMode: Int = 4  // 0 = Photo 4:3, 1 = 16:9 @120fps, 2 = 640x480, 3 = MaxFOV+HighFps, 4 = Photo+Force120
    
    private let captureTest = GPUImageCaptureTest()
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 20) {
                // 标题
                Text("🧪 GPUImage 采集测试")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                
                // 预览区域
                CapturePreviewView(captureTest: captureTest, isRunning: $isRunning, useFrontCamera: $useFrontCamera)
                    .frame(height: 300)
                    .background(Color.gray.opacity(0.3))
                    .cornerRadius(12)
                
                // FPS 显示
                VStack(spacing: 8) {
                    HStack {
                        Text("实时帧率:")
                            .foregroundColor(.gray)
                        Text(String(format: "%.1f fps", currentFPS))
                            .font(.title.bold())
                            .foregroundColor(currentFPS >= 100 ? .green : (currentFPS >= 60 ? .yellow : .red))
                    }
                    
                    Text(frameInfo)
                        .font(.caption)
                        .foregroundColor(.white)
                    
                    Text(formatInfo)
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(Color.white.opacity(0.1))
                .cornerRadius(12)
                
                // 🧪 测试模式切换
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Button(action: { testMode = 0 }) {
                            Text("Photo")
                                .font(.caption2.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(testMode == 0 ? Color.orange : Color.gray.opacity(0.5))
                                .cornerRadius(8)
                        }
                        
                        Button(action: { testMode = 1 }) {
                            Text("16:9@120")
                                .font(.caption2.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(testMode == 1 ? Color.green : Color.gray.opacity(0.5))
                                .cornerRadius(8)
                        }
                        
                        Button(action: { testMode = 2 }) {
                            Text("640x480")
                                .font(.caption2.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(testMode == 2 ? Color.purple : Color.gray.opacity(0.5))
                                .cornerRadius(8)
                        }
                    }
                    
                    // 🔥 新增：最大FOV + 高帧率测试
                    Button(action: { testMode = 3 }) {
                        Text("最大FOV")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(testMode == 3 ? Color.cyan : Color.gray.opacity(0.5))
                            .cornerRadius(8)
                    }
                    
                    // 🔥🔥 核心测试：照片格式 + 强制120fps
                    Button(action: { testMode = 4 }) {
                        Text("🔥Photo+120")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(testMode == 4 ? Color.red : Color.gray.opacity(0.5))
                            .cornerRadius(8)
                    }
                }
                
                // 控制按钮
                HStack(spacing: 20) {
                    // 前后置切换
                    Button(action: {
                        useFrontCamera.toggle()
                        if isRunning {
                            captureTest.stopTest()
                            isRunning = false
                            // 延迟重新启动
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                captureTest.testMode = getTestMode()
                                isRunning = true
                            }
                        }
                    }) {
                        VStack {
                            Image(systemName: useFrontCamera ? "camera.rotate" : "camera.rotate.fill")
                                .font(.title2)
                            Text(useFrontCamera ? "前置" : "后置")
                                .font(.caption)
                        }
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.blue.opacity(0.6))
                        .cornerRadius(12)
                    }
                    
                    // 开始/停止
                    Button(action: {
                        captureTest.testMode = getTestMode()
                        isRunning.toggle()
                    }) {
                        VStack {
                            Image(systemName: isRunning ? "stop.fill" : "play.fill")
                                .font(.title2)
                            Text(isRunning ? "停止" : "开始")
                                .font(.caption)
                        }
                        .foregroundColor(.white)
                        .padding()
                        .frame(width: 100)
                        .background(isRunning ? Color.red.opacity(0.6) : Color.green.opacity(0.6))
                        .cornerRadius(12)
                    }
                }
                
                // 说明
                Text("测试目标：4:3 画幅 + 120fps\n如果能达到，说明可以用这个方案")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                
                Spacer()
            }
            .padding()
        }
        .onAppear {
            setupCallbacks()
        }
        .onDisappear {
            captureTest.stopTest()
        }
    }
    
    private func setupCallbacks() {
        captureTest.onFPSUpdate = { fps, info in
            self.currentFPS = fps
            self.frameInfo = info
        }
        captureTest.onFormatInfo = { info in
            self.formatInfo = info
        }
    }
    
    private func getTestMode() -> GPUImageCaptureTest.TestMode {
        switch testMode {
        case 0: return .photo43
        case 1: return .high169_120fps
        case 2: return .low43_640x480
        case 3: return .photoWithHighFps
        case 4: return .photoForce120fps  // 🔥🔥 照片格式 + 强制120fps
        default: return .photoForce120fps
        }
    }
}

// MARK: - 预览视图包装器
struct CapturePreviewView: UIViewRepresentable {
    let captureTest: GPUImageCaptureTest
    @Binding var isRunning: Bool
    @Binding var useFrontCamera: Bool
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        if isRunning {
            // 清除旧的子层
            uiView.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            captureTest.startTest(in: uiView, useFrontCamera: useFrontCamera)
        } else {
            captureTest.stopTest()
        }
    }
}

// MARK: - 预览
#Preview {
    GPUImageTestView()
}

