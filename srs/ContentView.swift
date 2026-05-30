import SwiftUI
import WebRTC
import MediaPlayer
import AVFoundation

// MARK: - 隐藏 Home Indicator 的 Modifier（iOS 16+）
struct HideHomeIndicatorModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .persistentSystemOverlays(.hidden)
        } else {
            content
        }
    }
}

// MARK: - 音量键监听管理器
class VolumeButtonManager: NSObject, ObservableObject {
    private var volumeView: MPVolumeView?
    private var volumeSlider: UISlider?
    private var volumeChangeHandler: (() -> Void)?
    private var isRestoringVolume: Bool = false
    private var lastTriggerTime: Date = Date.distantPast
    private var lastVolume: Float = 0.5
    
    private let targetVolume: Float = 0.5
    
    // 🔥 追踪 KVO 观察者是否已添加（防止 iOS 15 崩溃）
    private var isKVOObserverAdded: Bool = false
    
    func startMonitoring(onVolumeChange: @escaping () -> Void) {
        self.volumeChangeHandler = onVolumeChange
        
        // 1️⃣ 设置音频会话
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)
            lastVolume = audioSession.outputVolume
        } catch {
            print("❌ 音频会话设置失败: \(error)")
}

        // 2️⃣ 创建隐藏的 MPVolumeView
        volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        volumeView?.showsRouteButton = false
        volumeView?.showsVolumeSlider = true
        
        if let keyWindow = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.windows
            .first(where: { $0.isKeyWindow }),
           let vv = volumeView {
            keyWindow.addSubview(vv)
        }
        
        // 3️⃣ 延迟获取 slider 引用
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, let volumeView = self.volumeView else { return }
            self.volumeSlider = self.findSlider(in: volumeView)
            
            // 初始化到中间值
            let currentVolume = AVAudioSession.sharedInstance().outputVolume
            if currentVolume < 0.1 || currentVolume > 0.9 {
                self.setVolumeInternal(self.targetVolume)
            }
        }
        
        // 4️⃣ 使用 NotificationCenter 监听系统音量变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(volumeDidChange(_:)),
            name: NSNotification.Name("AVSystemController_SystemVolumeDidChangeNotification"),
            object: nil
        )
        
        // 5️⃣ 同时使用 KVO 作为备选方案
        if !isKVOObserverAdded {
        audioSession.addObserver(self, forKeyPath: "outputVolume", options: [.new, .old], context: nil)
            isKVOObserverAdded = true
        }
        
        print("✅ 音量键监听已启动")
                    }
    
    @objc private func volumeDidChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reason = userInfo["AVSystemController_AudioVolumeChangeReasonNotificationParameter"] as? String,
              reason == "ExplicitVolumeChange" else {
            // 忽略非用户主动调节的音量变化
            return
        }
        
        guard let newVolume = userInfo["AVSystemController_AudioVolumeNotificationParameter"] as? Float else {
            return
        }
        
        handleVolumeChange(oldVolume: lastVolume, newVolume: newVolume, source: "NotificationCenter")
    }
    
    private func handleVolumeChange(oldVolume: Float, newVolume: Float, source: String) {
        // 如果正在恢复音量，忽略
        if isRestoringVolume { return }
        
        // 防抖：距离上次触发不到 0.3 秒，忽略
        let now = Date()
        if now.timeIntervalSince(lastTriggerTime) < 0.3 { return }
        
        let diff = abs(newVolume - oldVolume)
        if diff > 0.01 {
            lastTriggerTime = now
            lastVolume = newVolume
            
            // 触发回调
            DispatchQueue.main.async {
                self.volumeChangeHandler?()
            }
            
            // 恢复到中间值
            isRestoringVolume = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self = self else { return }
                self.setVolumeInternal(self.targetVolume)
                self.lastVolume = self.targetVolume
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.isRestoringVolume = false
                }
            }
        }
    }
    
    private func findSlider(in view: UIView) -> UISlider? {
        for subview in view.subviews {
            if let slider = subview as? UISlider {
                return slider
            }
            if let slider = findSlider(in: subview) {
                return slider
            }
        }
        return nil
    }
    
    private func setVolumeInternal(_ volume: Float) {
        if let slider = volumeSlider {
            DispatchQueue.main.async {
                slider.value = volume
        }
        } else {
            MPVolumeView.setVolume(volume)
                            }
    }
    
    func stopMonitoring() {
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("AVSystemController_SystemVolumeDidChangeNotification"), object: nil)
        
        // 🔥 只有在 KVO 观察者已添加时才移除（防止 iOS 15 崩溃）
        if isKVOObserverAdded {
        AVAudioSession.sharedInstance().removeObserver(self, forKeyPath: "outputVolume")
            isKVOObserverAdded = false
        }
        
        volumeView?.removeFromSuperview()
        volumeView = nil
        volumeSlider = nil
    }
    
    // 🔥 确保对象销毁时清理 KVO 观察者（防止 iOS 15 崩溃）
    deinit {
        if isKVOObserverAdded {
            AVAudioSession.sharedInstance().removeObserver(self, forKeyPath: "outputVolume")
        }
        NotificationCenter.default.removeObserver(self)
        }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "outputVolume" {
            guard let newVolume = change?[NSKeyValueChangeKey.newKey] as? Float else { return }
            let oldVolume = change?[NSKeyValueChangeKey.oldKey] as? Float ?? lastVolume
            
            handleVolumeChange(oldVolume: oldVolume, newVolume: newVolume, source: "KVO")
        }
    }
}

extension MPVolumeView {
    static func setVolume(_ volume: Float) {
        let volumeView = MPVolumeView(frame: .zero)
        
        // 方法1：直接查找 slider
        if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
            DispatchQueue.main.async {
                slider.value = volume
                            }
            return
        }
        
        // 方法2：使用私有API（备选方案）
        let selector = NSSelectorFromString("setVolume:")
        if volumeView.responds(to: selector) {
            volumeView.perform(selector, with: volume)
        }
    }
}

// MARK: - 自定义滑块组件（黄色圆形拖块）
struct CustomSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let displayText: String
    let onChanged: ((Double) -> Void)?
    
    init(label: String, value: Binding<Double>, range: ClosedRange<Double>, displayText: String? = nil, onChanged: ((Double) -> Void)? = nil) {
        self.label = label
        self._value = value
        self.range = range
        self.displayText = displayText ?? String(format: "%.2f", value.wrappedValue)
        self.onChanged = onChanged
    }
    
    var body: some View {
        HStack(spacing: 20) {
            // 标签
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "1A1A1A"))
                .frame(width: 42, alignment: .leading)
            
            // 滑块
            GeometryReader { geometry in
                let sliderWidth = geometry.size.width
                let progress = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                let thumbX = sliderWidth * CGFloat(progress)
                
                ZStack(alignment: .leading) {
                    // 背景轨道
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color(hex: "DBDBE0"))
                        .frame(height: 4)
                    
                    // 进度填充
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color(hex: "008BFF"))
                        .frame(width: max(0, thumbX), height: 4)
                    
                    // 黄色圆形拖块
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "FFD65B"), Color(hex: "FBAC00")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 16, height: 16)
                        .shadow(color: Color(hex: "FBAC00").opacity(0.5), radius: 1, x: 0, y: 2)
                        .offset(x: max(0, min(thumbX - 8, sliderWidth - 16)))
                        .gesture(
                            DragGesture()
                                .onChanged { gesture in
                                    let newProgress = min(max(0, gesture.location.x / sliderWidth), 1)
                                    let newValue = range.lowerBound + (range.upperBound - range.lowerBound) * Double(newProgress)
                                    value = newValue
                                    onChanged?(newValue)
                                }
                        )
                }
            }
            .frame(height: 16)
            
            // 值显示
            Text(displayText)
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "1A1A1A"))
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: 20)
    }
}

// MARK: - 清晰度单选按钮
struct QualityRadioButton: View {
    let profile: LadderProfile
    let isSelected: Bool
    let action: () -> Void
    
    private var profileName: String {
        switch profile {
        case .p4k: return "超高清"
        case .ultra: return "超高帧"
        case .high: return "超清"
        case .standard: return "高清"
        case .low: return "超低网"
        }
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                ZStack {
                    Circle()
                        .stroke(isSelected ? Color(hex: "1197D6") : Color(hex: "999999"), lineWidth: 1)
                        .frame(width: 15, height: 15)
                    
                    if isSelected {
                        Circle()
                            .fill(Color(hex: "1197D6"))
                            .frame(width: 6, height: 6)
                    }
                }
                .frame(width: 16, height: 16)
                
                Text(profileName)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "1A1A1A"))
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 右侧操作面板（滑块控件）
struct SettingsPanelView: View {
    @ObservedObject var rtc: WebRTCManager
    
    // 本地 UI 状态（仅显示用）
    @State private var exposureValue: Double = 240  // 曝光：60-600（与后端 cjfps 同步）
    @State private var focusValue: Double = 0.5    // 焦距：0.00-1.00
    @State private var fluencyValue: Double = 100  // 流畅：0-100
    @State private var brightnessValue: Double = 0 // 亮度：-2.00 到 8.00
    @State private var selectedProfile: LadderProfile = .standard  // 清晰度（仅 UI）
    
    var body: some View {
        VStack(spacing: 0) {
            // 内部灰色卡片
            VStack(spacing: 12) {
                // 曝光滑块（与后端 cjfps 同步，范围 60-600）
                CustomSlider(
                    label: "曝光",
                    value: $exposureValue,
                    range: 60...600,
                    displayText: String(format: "%.0f", exposureValue)
                )
                
                // 分隔线
                Rectangle()
                    .fill(Color.white)
                    .frame(height: 1)
                
                // 焦距滑块（仅 UI 显示，与后端同步，不实际应用）
                CustomSlider(
                    label: "焦距",
                    value: $focusValue,
                    range: 0...1,
                    displayText: String(format: "%.2f", focusValue)
                )
                
                // 分隔线
                Rectangle()
                    .fill(Color.white)
                    .frame(height: 1)
                
                // 流畅滑块（右边始终显示"清晰"）
                CustomSlider(
                    label: "流畅",
                    value: $fluencyValue,
                    range: 0...100,
                    displayText: "清晰"
                )
                
                // 分隔线
                Rectangle()
                    .fill(Color.white)
                    .frame(height: 1)
                
                // 亮度滑块
                CustomSlider(
                    label: "亮度",
                    value: $brightnessValue,
                    range: -2...8,
                    displayText: String(format: "%.2f", brightnessValue)
                )
                
                // 分隔线
                Rectangle()
                    .fill(Color.white)
                    .frame(height: 1)
                
                // 档位选择（仅 UI 效果，不实际调用，与后端同步）
                HStack(spacing: 12) {
                        QualityRadioButton(
                            profile: .standard,
                            isSelected: selectedProfile == .standard,
                            action: { selectedProfile = .standard }  // 仅 UI 效果
                        )
                        
                        QualityRadioButton(
                            profile: .high,
                            isSelected: selectedProfile == .high,
                            action: { selectedProfile = .high }  // 仅 UI 效果
                        )
                        
                        QualityRadioButton(
                            profile: .p4k,
                            isSelected: selectedProfile == .p4k,
                            action: { selectedProfile = .p4k }  // 仅 UI 效果
                        )
                        
                        QualityRadioButton(
                            profile: .ultra,
                            isSelected: selectedProfile == .ultra,
                            action: { selectedProfile = .ultra }  // 仅 UI 效果
                        )

                        QualityRadioButton(
                            profile: .low,
                            isSelected: selectedProfile == .low,
                            action: { selectedProfile = .low }  // 仅 UI 效果
                        )

                    Spacer()
                }
                .padding(.horizontal, 18)
                .frame(height: 20)
                .onChange(of: rtc.currentProfile, perform: { newProfile in
                    // 后端 STOMP 下发时同步 UI
                    selectedProfile = newProfile
                })
            }
            .padding(.vertical, 20)
            .background(Color(hex: "F4F4F8"))
            .cornerRadius(12)
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(16, corners: [.topLeft, .topRight])
        .onAppear {
            // 同步后端数据
            exposureValue = Double(rtc.cjfpsValue)  // 🔥 曝光与后端 cjfps 同步
            focusValue = Double(rtc.focusDistance)
            selectedProfile = rtc.currentProfile
        }
        .onChange(of: rtc.cjfpsValue, perform: { newCjfps in
            // 🔥 后端下发 cjfps 时同步 UI
            exposureValue = Double(newCjfps)
        })
        .onChange(of: rtc.focusDistance, perform: { newFocus in
            // 后端下发时同步 UI
            focusValue = Double(newFocus)
        })
    }
}

// MARK: - 小组件：底部控制面板（只保留清晰度）
struct ControlPanelView: View {
    @ObservedObject var rtc: WebRTCManager
    
    // 档位名称（简短）
    private func profileName(_ p: LadderProfile) -> String {
        switch p {
        case .p4k: return "超高清"
        case .ultra: return "超高帧"
        case .high: return "超清"
        case .standard: return "高清"
        case .low: return "超低网"
        }
    }

    var body: some View {
        // ✅ 横屏模式：水平排列
        HStack(spacing: 16) {
            // 档位切换（清晰度）
            HStack(spacing: 6) {
                ForEach([LadderProfile.standard, .high, .p4k, .ultra, .low], id: \.self) { profile in
                    Button(action: {
                        rtc.applyProfile(profile)
                    }) {
                        Text(profileName(profile))
                            .font(.system(size: 10, weight: rtc.currentProfile == profile ? .bold : .regular))
                            .foregroundColor(rtc.currentProfile == profile ? .yellow : .white)
                            .frame(width: 40, height: 30)
                            .background(rtc.currentProfile == profile ? Color.blue.opacity(0.8) : Color.black.opacity(0.6))
                            .cornerRadius(6)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .background(Color.clear)  // 🔥 确保没有默认白色背景
    }
}

// MARK: - 亮度调节滑块（用DragGesture实现，和CustomSlider一样不卡）
struct BrightnessSliderView: View {
    @State private var brightness: Double = 0.5

    var body: some View {
        HStack(spacing: 8) {
            Text("亮度")
                .font(.system(size: 10))
                .foregroundColor(.white)
                .frame(width: 28)

            GeometryReader { geometry in
                let sliderWidth = geometry.size.width
                let progress = brightness
                let thumbX = sliderWidth * CGFloat(progress)

                ZStack(alignment: .leading) {
                    // 背景轨道
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color.white.opacity(0.3))
                        .frame(height: 4)

                    // 进度填充
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color.white)
                        .frame(width: max(0, thumbX), height: 4)

                    // 圆形拖块
                    Circle()
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: Color.black.opacity(0.3), radius: 2, x: 0, y: 1)
                        .offset(x: max(0, min(thumbX - 8, sliderWidth - 16)))
                }
                // 整个轨道区域都可拖动（不只是小圆点）
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let newProgress = min(max(0, gesture.location.x / sliderWidth), 1)
                            brightness = newProgress
                            UIScreen.main.brightness = CGFloat(newProgress)
                        }
                )
            }
            .frame(height: 30)  // 加大触摸区域

            Text("\(Int(brightness * 100))%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 32)
        }
        .onAppear {
            brightness = Double(UIScreen.main.brightness)
        }
    }
}

// MARK: - 主视图
struct ContentView: View {
    @StateObject var rtc = WebRTCManager()
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase  // ✅ App 生命周期

    // UI
    @State private var showControls: Bool = true
    @State private var isBlackout: Bool = false
    @State private var savedBrightness: CGFloat? = nil
    
    // 🔥 滑动黑屏：同一方向滑动5次触发
    @State private var swipeCount: Int = 0
    @State private var lastSwipeTime: Date = Date()
    @State private var lastSwipeDirection: String = ""  // "up"/"down"/"left"/"right"
    
    // 导航到个人中心
    @State private var showingProfile: Bool = false

    // ✅ 自动推流状态
    @State private var isCameraReady = false
    @State private var isWebSocketConnected = false
    @State private var hasAutoPublished = false  // 防止重复推流
    @State private var autoPublishRetryCount = 0  // 自动推流重试次数
    
    // ✅ 音量键监听
    @StateObject private var volumeButtonManager = VolumeButtonManager()
    
    // ✅ 休眠/唤醒防抖
    @State private var isSleepWakeInProgress: Bool = false
    
    // ✅ 自动推流防抖（防止多次调用startPublish导致SRS返回400错误）
    @State private var isAutoPublishInProgress: Bool = false

    // 🔥 试用结束弹框
    @State private var showTrialEndAlert: Bool = false
    @State private var trialEndMessage: String = ""
    @State private var isTrialEnded: Bool = false
    
    // 🔥 激活页面
    @State private var showingActivation: Bool = false
    
    // 🔥 防止重复弹框（TryDisconnect 每秒都会收到）
    // 记录已弹框的阶段号，只有新阶段结束时才弹框
    @State private var lastShownStageEnded: Int = 0


    // 档位名称
    private func profileDisplayName(_ p: LadderProfile) -> String {
        switch p {
        case .p4k: return "超高清"
        case .ultra: return "超高帧"
        case .high: return "超清"
        case .standard: return "高清"
        case .low: return "超低网"
        }
    }

    private func captureExperimentPanel() -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("Range", selection: $rtc.captureRangeMode) {
                    ForEach(CaptureRangeMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Binning", selection: $rtc.captureBinningMode) {
                    ForEach(CaptureBinningMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Button("应用采集格式") {
                rtc.applyCaptureExperimentFormat()
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(Color.yellow)
            .cornerRadius(6)

            CaptureColorSliderView(
                title: "冷暖",
                value: $rtc.wbTemperature,
                remoteSyncToken: rtc.captureColorRemoteTick,
                onLocalCommit: { rtc.applyCaptureColorAdjustment() }
            )
            CaptureColorSliderView(
                title: "黄/琥珀",
                value: $rtc.wbAmber,
                remoteSyncToken: rtc.captureColorRemoteTick,
                onLocalCommit: { rtc.applyCaptureColorAdjustment() }
            )
            CaptureColorSliderView(
                title: "绿紫",
                value: $rtc.wbTint,
                remoteSyncToken: rtc.captureColorRemoteTick,
                onLocalCommit: { rtc.applyCaptureColorAdjustment() }
            )
            CaptureColorSliderView(
                title: "红",
                value: $rtc.wbRed,
                remoteSyncToken: rtc.captureColorRemoteTick,
                onLocalCommit: { rtc.applyCaptureColorAdjustment() }
            )
            CaptureColorSliderView(
                title: "绿",
                value: $rtc.wbGreen,
                remoteSyncToken: rtc.captureColorRemoteTick,
                onLocalCommit: { rtc.applyCaptureColorAdjustment() }
            )
            CaptureColorSliderView(
                title: "蓝",
                value: $rtc.wbBlue,
                remoteSyncToken: rtc.captureColorRemoteTick,
                onLocalCommit: { rtc.applyCaptureColorAdjustment() }
            )
            CaptureColorSliderView(
                title: "黑",
                value: $rtc.wbBlack,
                remoteSyncToken: rtc.captureColorRemoteTick,
                onLocalCommit: { rtc.applyCaptureColorAdjustment() }
            )
            CaptureColorSliderView(
                title: "白",
                value: $rtc.wbWhite,
                remoteSyncToken: rtc.captureColorRemoteTick,
                onLocalCommit: { rtc.applyCaptureColorAdjustment() }
            )

            HStack(spacing: 8) {
                Button("应用颜色") {
                    rtc.applyCaptureColorAdjustment()
                }
                .frame(maxWidth: .infinity, minHeight: 26)
                .background(Color.white.opacity(0.85))
                .foregroundColor(.black)
                .cornerRadius(6)

                Button("重置颜色") {
                    rtc.resetCaptureColorAdjustment()
                }
                .frame(maxWidth: .infinity, minHeight: 26)
                .background(Color.white.opacity(0.35))
                .foregroundColor(.white)
                .cornerRadius(6)
            }
            .font(.system(size: 11, weight: .medium))
        }
        .padding(8)
        .background(Color.black.opacity(0.55))
        .cornerRadius(8)
    }

    var body: some View {
        ZStack {
            // 🔥 底层黑色背景，确保没有白边
            Color.black
                .ignoresSafeArea(.all)
            
            // 预览（旋转90度，将横屏画面竖屏显示）
            GeometryReader { geo in
                WebRTCPreview(view: rtc.localView)
                    .frame(width: geo.size.height, height: geo.size.width)
                    .rotationEffect(.degrees(90))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .ignoresSafeArea()
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.25)) { showControls.toggle() }
            }

            // PC 连接状态指示器（左上角，始终显示）
            VStack {
                HStack {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(rtc.viewerConnected ? Color.green : Color.red)
                            .frame(width: 7, height: 7)
                        Text(rtc.viewerConnected ? "PC已连接" : "PC未连接")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(rtc.viewerConnected ? .green : .red)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.45))
                    .cornerRadius(8)
                    .padding(.top, 52)
                    .padding(.leading, 10)
                    Spacer()
                }
                Spacer()
            }

            // 顶部导航栏
            if showControls {
                VStack(spacing: 0) {
                    // 顶部导航栏背景
                    HStack {
                        // 左边 - 关闭按钮
                        Button(action: {
                            // 退出推流页前清理资源
                            // BackgroundAudioManager.shared.stopBackgroundKeepAlive()  // 🔊 审核隐藏
                            if rtc.isPublishing { print("⚠️ [原因] 点击返回按钮"); rtc.stopPublish() }
                            WebSocketManager.shared.disconnect()
                            if !rtc.isCameraSleeping { rtc.sleepCamera() }
                            appState.navigateBack()
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(Color(hex: "1A1A1A"))
                                .frame(width: 28, height: 28)
                                .background(Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        
                        Spacer()
                        
                        // 中间 - 标题
                        Text("主页")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Color(hex: "1A1A1A"))
                        
                        Spacer()
                        
                        // 右边 - 设置 + 我的
                        HStack(spacing: 12) {
                            // 设置图标
                            Button(action: {
                                showingProfile = true
                            }) {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 18))
                                    .foregroundColor(Color(hex: "1A1A1A"))
                                    .frame(width: 28, height: 28)
                            }
                            
                            // 我的
                            Button(action: {
                                showingProfile = true
                            }) {
                                Text("我的")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(Color(hex: "1A1A1A"))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(height: 44)
                    .background(Color(hex: "FAFAFA"))
                    
                    Spacer()
                }
                .padding(.top, 44) // 状态栏高度
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            
            // 底部操作面板（镜头变倍 + 清晰度 + 摄像头切换）
            if showControls {
                VStack(spacing: 0) {
                    Spacer()
                    
                    VStack(spacing: 10) {
                        // 🔍 屏幕亮度调节
                        BrightnessSliderView()
                            .padding(.horizontal, 16)

                        captureExperimentPanel()
                            .padding(.horizontal, 16)

                        // 档位（可点击切换UI高亮，不发后端）+ 摄像头切换
                        HStack(spacing: 6) {
                            // 档位按钮（仅UI切换，不发送后端）
                            ForEach([LadderProfile.low, .standard, .high, .p4k, .ultra], id: \.self) { profile in
                                Button(action: {
                                    // 仅切换UI显示，不实际切换档位
                                    rtc.currentProfile = profile
                                }) {
                                    Text(profileDisplayName(profile))
                                        .font(.system(size: 10, weight: rtc.currentProfile == profile ? .bold : .regular))
                                        .foregroundColor(rtc.currentProfile == profile ? .yellow : .white)
                                        .frame(width: 40, height: 30)
                                        .background(rtc.currentProfile == profile ? Color.blue.opacity(0.8) : Color.black.opacity(0.6))
                                        .cornerRadius(6)
                                }
                            }
                            
                            // 分隔线
                            Rectangle()
                                .fill(Color.white.opacity(0.3))
                                .frame(width: 1, height: 20)
                            
                            // 摄像头切换
                            Button(action: {
                                rtc.toggleCamera()
                            }) {
                                Text("切换")
                                    .font(.system(size: 10, weight: .regular))
                                    .foregroundColor(.white)
                                    .frame(width: 40, height: 30)
                                    .background(Color.black.opacity(0.6))
                                    .cornerRadius(6)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 40)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // 黑幕层
            if isBlackout {
                Color.black.ignoresSafeArea().allowsHitTesting(false)
            }
            
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)  // 🔥 确保填满整个屏幕
        .background(Color.black.ignoresSafeArea(.all))     // 🔥 黑色背景忽略所有安全区域
        .ignoresSafeArea(.all)                             // 🔥 ZStack 本身也忽略安全区域
        .statusBar(hidden: isBlackout)                     // 🔥 黑屏时隐藏状态栏
        .modifier(HideHomeIndicatorModifier())             // 🔥 隐藏 Home Indicator（iOS 16+）
        .onAppear {
            print("🚀 ContentView.onAppear")
            rtc.localView.backgroundColor = .black
            rtc.localView.isOpaque = true
            rtc.localView.contentMode = .scaleAspectFill
            if isBlackout {
                isBlackout = false
            }
            if let b = savedBrightness {
                UIScreen.main.brightness = b
                savedBrightness = nil
            }

            // 🔊 审核隐藏 - 后台保活
            // BackgroundAudioManager.shared.startBackgroundKeepAlive()
            
            // 清理旧状态
            if rtc.isCameraSleeping { rtc.wakeCamera() }
            if rtc.isPublishing { print("⚠️ [原因] 重新进入推流页清理旧状态"); rtc.stopPublish() }
            
            // 重置状态
            hasAutoPublished = false
            isCameraReady = false
            autoPublishRetryCount = 0
            lastShownStageEnded = 0
            
            // 检查试用状态
            let trialRequired = UserDefaults.standard.bool(forKey: "trial_required")
            let trialEnded = UserDefaults.standard.bool(forKey: "trial_ended")
            let activated = UserDefaults.standard.bool(forKey: "activated")
            let isTrialExpired = trialRequired && !activated && trialEnded
            
            if isTrialExpired {
                WebSocketManager.shared.disconnect()
            }
            
            // 加载 streamKey
            if let permanentToken = UserDefaults.standard.string(forKey: "permanent_token"), !permanentToken.isEmpty {
                rtc.updateStreamKey(permanentToken)
            }
            
            // 竖屏锁定
            AppDelegate.orientationLock = .portrait
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
            UIApplication.shared.isIdleTimerDisabled = true
            
            // 🔥 试用已结束 - 不进入推流，直接弹框提示
            if isTrialExpired {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.lastShownStageEnded = 6
                    self.trialEndMessage = "试用已结束，请扫码绑定设备后继续使用"
                    self.isTrialEnded = true
                    self.showTrialEndAlert = true
                }
                // 🔥 不启动摄像头和推流
                return
            }
            
            // 延迟启动摄像头
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                rtc.startPreviewIfNeeded()
            }
            
            // 注册自动推流监听
            setupAutoPublishing()
            
            // 检查 WebSocket 连接
            if WebSocketManager.shared.isConnected {
                isWebSocketConnected = true
            } else {
                isWebSocketConnected = false
                if let deviceId = UserDefaults.standard.string(forKey: "device_id"), !deviceId.isEmpty {
                    WebSocketManager.shared.connect(deviceId: deviceId)
                }
            }
            
            // 兜底检查
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                if !self.rtc.isPublishing && !self.hasAutoPublished {
                    self.tryAutoPublish()
                }
            }
            
            // 监听退出登录通知
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name("StopPublishBeforeLogout"),
                object: nil,
                queue: .main
            ) { _ in
                // BackgroundAudioManager.shared.stopBackgroundKeepAlive()  // 🔊 审核隐藏
                if rtc.isPublishing { print("⚠️ [原因] 退出登录停止推流"); rtc.stopPublish() }
            }
            
            // 监听扫码前释放摄像头通知
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name("ReleaseCameraForScanner"),
                object: nil,
                queue: .main
            ) { _ in
                if !rtc.isCameraSleeping { rtc.sleepCamera() }
            }
            
            // 启动音量键监听
            volumeButtonManager.startMonitoring { [weak rtc] in
                guard let rtc = rtc else { return }
                DispatchQueue.main.async {
                    if self.isSleepWakeInProgress { return }
                    self.isSleepWakeInProgress = true
                    
                    if rtc.isCameraSleeping {
                        rtc.wakeCamera()
                    } else {
                        rtc.sleepCamera()
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.isSleepWakeInProgress = false
                    }
                }
            }
        }
        .onDisappear {
            print("🚪 ContentView.onDisappear: 清理资源")
            
            // 兜底资源清理
            if rtc.isPublishing { print("⚠️ [原因] onDisappear兜底清理"); rtc.stopPublish() }
            if WebSocketManager.shared.isConnected { WebSocketManager.shared.disconnect() }
            if !rtc.isCameraSleeping { rtc.sleepCamera() }
            
            // 恢复方向
            AppDelegate.orientationLock = .all
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
            UIApplication.shared.isIdleTimerDisabled = false

            // 移除通知观察者
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name("StopPublishBeforeLogout"), object: nil)
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name("ReleaseCameraForScanner"), object: nil)
            NotificationCenter.default.removeObserver(self, name: .cameraPreviewReady, object: nil)
            NotificationCenter.default.removeObserver(self, name: .publishFailed, object: nil)
            NotificationCenter.default.removeObserver(self, name: .webSocketConnectionStateChanged, object: nil)
            NotificationCenter.default.removeObserver(self, name: .resetPublishRequested, object: nil)
            NotificationCenter.default.removeObserver(self, name: .cameraSleepRequested, object: nil)
            NotificationCenter.default.removeObserver(self, name: .tryDisconnectRequested, object: nil)
            
            volumeButtonManager.stopMonitoring()
        }
        .simultaneousGesture(
            // 🔥 同一方向滑动5次切换黑屏/亮屏
            DragGesture(minimumDistance: 50)
                .onEnded { value in
                    let now = Date()
                    
                    // 判断滑动方向
                    let horizontal = value.translation.width
                    let vertical = value.translation.height
                    let direction: String
                    if abs(horizontal) > abs(vertical) {
                        direction = horizontal > 0 ? "right" : "left"
                    } else {
                        direction = vertical > 0 ? "down" : "up"
                    }
                    
                    // 超过2秒 或 方向不同 → 重置计数
                    if now.timeIntervalSince(lastSwipeTime) > 2.0 || direction != lastSwipeDirection {
                        swipeCount = 0
                    }
                    
                    lastSwipeTime = now
                    lastSwipeDirection = direction
                    swipeCount += 1
                    
                    // 🔥 熄屏5次，亮屏20次（防止误触亮屏）
                    let threshold = isBlackout ? 20 : 5
                    if swipeCount >= threshold {
                        swipeCount = 0
                        lastSwipeDirection = ""
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isBlackout.toggle()
                            if isBlackout { showControls = false }
                        }
                        if isBlackout {
                            savedBrightness = UIScreen.main.brightness
                            UIScreen.main.brightness = 0.05
                        } else if let b = savedBrightness {
                            UIScreen.main.brightness = b
                            savedBrightness = nil
                        }
                    }
                }
        )
        .fullScreenCover(isPresented: $showingProfile, onDismiss: {
            // 从个人中心返回推流页，恢复竖屏锁定
            AppDelegate.orientationLock = .portrait
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }) {
            ProfileView()
                .environmentObject(appState)
                .onAppear {
                    // ✅ 打开个人中心时，允许竖屏
                    AppDelegate.orientationLock = .all
                    UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
                    UIViewController.attemptRotationToDeviceOrientation()
                }
        }
        // 🔥 试用结束 - 停止推流，弹框提示（不退出应用）
        .onChange(of: showTrialEndAlert, perform: { newValue in
            if newValue {
                // 停止推流和断开WebSocket
                if rtc.isPublishing { print("⚠️ [原因] 绑定成功弹窗显示"); rtc.stopPublish() }
                WebSocketManager.shared.disconnect()

                // 🔥 不再退出应用，只是弹框提示
                // 用户可以选择激活或返回
            }
        })
        // 🔥 试用结束弹框
        .alert("试用已结束", isPresented: $showTrialEndAlert) {
            Button("去扫码绑定") {
                showTrialEndAlert = false
                // 跳转到扫码绑定页面
                appState.navigateToQRScanner()
            }
            Button("取消", role: .cancel) {
                showTrialEndAlert = false
                // ⭐ 跳到登录页让用户重新登录 (清 token 防止旧账号 auto-skip)
                UserDefaults.standard.set("", forKey: "jwt_token")
                UserDefaults.standard.set("", forKey: "permanent_token")
                appState.navigateToMonitorLogin()
            }
        } message: {
            Text(trialEndMessage.isEmpty ? "试用已结束，请扫码绑定设备后继续使用" : trialEndMessage)
        }
        // 激活页面
        .sheet(isPresented: $showingActivation, onDismiss: {
            AppDelegate.orientationLock = .portrait
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }) {
            ActivationView(onActivationSuccess: {
                print("✅ 激活成功，返回登录界面")
                lastShownStageEnded = 0
                hasAutoPublished = false
                
                // 推流已经停止了，WebSocket也已经断开了
                // 清理token，导航回登录页
                UserDefaults.standard.set("", forKey: "jwt_token")
                UserDefaults.standard.set("", forKey: "permanent_token")
                
                // 🔥 恢复竖屏（登录页面是竖屏）
                AppDelegate.orientationLock = .portrait
                UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
                UIViewController.attemptRotationToDeviceOrientation()
                
                // 导航回登录页
                appState.navigateToMonitorLogin()
            })
        }
        // ✅ 监听 App 生命周期（iOS 15+ 兼容写法）
        .onChange(of: scenePhase, perform: { newPhase in
            handleScenePhaseChange(to: newPhase)
        })
    }
    
    // MARK: - 事件驱动自动推流
    private func setupAutoPublishing() {
        // 监听摄像头预览就绪
        NotificationCenter.default.addObserver(
            forName: .cameraPreviewReady,
            object: nil,
            queue: .main
        ) { _ in
            self.isCameraReady = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.tryAutoPublish()
            }
        }
        
        // 监听推流失败通知
        NotificationCenter.default.addObserver(
            forName: .publishFailed,
            object: nil,
            queue: .main
        ) { notification in
            self.isAutoPublishInProgress = false
            
            if let reason = notification.userInfo?["reason"] as? String {
                print("❌ 推流失败: \(reason)")
                
                if self.autoPublishRetryCount < 1 {
                    self.autoPublishRetryCount += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        if self.rtc.isPublishing {
                            print("⚠️ [原因] 自动推流失败重试")
                            self.rtc.stopPublish()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                self.hasAutoPublished = false
                                self.rtc.startPublish()
                            }
                        } else {
                            self.hasAutoPublished = false
                            self.rtc.startPublish()
                        }
                    }
                }
            }
        }
        
        // 监听WebSocket连接状态
        NotificationCenter.default.addObserver(
            forName: .webSocketConnectionStateChanged,
            object: nil,
            queue: .main
        ) { notification in
            if let userInfo = notification.userInfo,
               let stateRaw = userInfo["connectionState"] as? String,
               stateRaw == "connected" {
                self.isWebSocketConnected = true
                self.tryAutoPublish()
            } else {
                self.isWebSocketConnected = false
            }
        }
        
        // 监听重置推流请求
        NotificationCenter.default.addObserver(
            forName: .resetPublishRequested,
            object: nil,
            queue: .main
        ) { _ in
            print("🔄 收到重置推流请求")
            if self.rtc.isPublishing {
                print("⚠️ [原因] 服务器下发重置推流")
                self.rtc.stopPublish()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.rtc.startPublish()
                }
            } else {
                self.rtc.startPublish()
            }
        }
        
        // 监听睡眠/唤醒请求
        NotificationCenter.default.addObserver(
            forName: .cameraSleepRequested,
            object: nil,
            queue: .main
        ) { notification in
            let action = notification.userInfo?["action"] as? String ?? ""
            
            if action == "sleep" {
                if !self.rtc.isCameraSleeping {
                    print("💤 收到休眠指令")
                    self.rtc.sleepCamera()
                }
            } else if action == "wake" {
                let trialRequired = UserDefaults.standard.bool(forKey: "trial_required")
                let trialEnded = UserDefaults.standard.bool(forKey: "trial_ended")
                let activated = UserDefaults.standard.bool(forKey: "activated")
                
                if trialRequired && !activated && trialEnded {
                    WebSocketManager.shared.disconnect()
                    if self.lastShownStageEnded < 6 {
                        self.lastShownStageEnded = 6
                        self.trialEndMessage = "试用已结束，请扫码绑定设备后继续使用"
                        self.isTrialEnded = true
                        self.showTrialEndAlert = true
                    }
                    return
                }
                
                if self.rtc.isCameraSleeping {
                    print("☀️ 收到唤醒指令")
                self.rtc.wakeCamera()
            }
        }
        }
        
        // 监听试用断开请求
        NotificationCenter.default.addObserver(
            forName: .tryDisconnectRequested,
            object: nil,
            queue: .main
        ) { notification in
            let shouldDisconnect = notification.userInfo?["shouldDisconnect"] as? Bool ?? false
            let trialEnded = notification.userInfo?["trialEnded"] as? Bool ?? false
            let stageJustEnded = notification.userInfo?["stageJustEnded"] as? Int ?? 0
            let message = notification.userInfo?["message"] as? String ?? "试用时间已到"
            
            if shouldDisconnect {
                if self.rtc.isPublishing { print("⚠️ [原因] 网络类型切换断开"); self.rtc.stopPublish() }
                WebSocketManager.shared.disconnect()
                
                let shouldShowAlert = (stageJustEnded > 0 && stageJustEnded > self.lastShownStageEnded) || 
                                      (trialEnded && self.lastShownStageEnded < 6)
                
                if shouldShowAlert {
                    self.lastShownStageEnded = stageJustEnded > 0 ? stageJustEnded : 6
                    self.trialEndMessage = message.isEmpty ? "试用已结束，请扫码绑定设备后继续使用" : message
                    self.isTrialEnded = trialEnded
                    self.showTrialEndAlert = true
                    print("⏱️ 试用结束，弹框引导扫码绑定")
                }
            }
        }
    }
    
    private func tryAutoPublish() {
        // 检查试用状态
        let trialRequired = UserDefaults.standard.bool(forKey: "trial_required")
        let trialEnded = UserDefaults.standard.bool(forKey: "trial_ended")
        let activated = UserDefaults.standard.bool(forKey: "activated")
        
        if trialRequired && !activated && trialEnded {
            WebSocketManager.shared.disconnect()
            if lastShownStageEnded < 6 {
                lastShownStageEnded = 6
                trialEndMessage = "试用已结束，请扫码绑定设备后继续使用"
                isTrialEnded = true
                showTrialEndAlert = true
            }
            return
        }
        
        // 如果摄像头处于休眠状态，跳过
        if rtc.isCameraSleeping { return }
        
        // 防抖
        if isAutoPublishInProgress { return }
        
        // ✅ 检查 baseStreamKey 是否准备好（streamKey 会在 startPublish 时动态生成）
        guard !rtc.baseStreamKey.isEmpty else {
            print("⏳ baseStreamKey 未加载，0.5秒后重试...")
            // 延迟重试
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.tryAutoPublish()
            }
            return
        }
        
        // ✅ 所有条件都满足 + 未推流 + 未自动推流过，则自动开始推流
        guard isCameraReady,
              isWebSocketConnected,
              !rtc.isPublishing,
              !hasAutoPublished else {
            return
        }
        
        isAutoPublishInProgress = true
        print("✅ 开始自动推流")
        rtc.startPublish()
        
        // 延迟检查推流状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if self.rtc.isPublishing {
                self.hasAutoPublished = true
                self.isAutoPublishInProgress = false
                print("✅ 推流成功")
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.isAutoPublishInProgress = false
                    if self.rtc.isPublishing {
                        self.hasAutoPublished = true
                    }
                }
            }
        }
    }
    
    // MARK: - App 生命周期处理
    private func handleScenePhaseChange(to newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            handleAppEnterBackground()
        case .inactive:
            break
        case .active:
            handleAppBecomeActive()
        @unknown default:
            break
        }
    }
    
    private func handleAppEnterBackground() {
        if rtc.isCameraSleeping { return }
        print("🔊 [保活] App进入后台，保持推流 (isPublishing=\(rtc.isPublishing))")
    }
    
    private func handleAppBecomeActive() {
        if rtc.isCameraSleeping { return }
        rtc.localView.backgroundColor = .black
        rtc.localView.isOpaque = true
        rtc.localView.contentMode = .scaleAspectFill

        hasAutoPublished = false
        autoPublishRetryCount = 0
        
        if let permanentToken = UserDefaults.standard.string(forKey: "permanent_token"), !permanentToken.isEmpty {
            rtc.updateStreamKey(permanentToken)
        }
        
        if !WebSocketManager.shared.isConnected {
            if let deviceId = UserDefaults.standard.string(forKey: "device_id") {
                WebSocketManager.shared.connect(deviceId: deviceId)
                isWebSocketConnected = false
            }
        } else {
            isWebSocketConnected = true
        }
        
        if rtc.capturer != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                rtc.reapplyConfigForWake()
            }
        } else {
            isCameraReady = false
        }
    }
}

// MARK: - 采集颜色滑块（PC 下发同步显示；本地拖动不回传 PC）
struct CaptureColorSliderView: View {
    let title: String
    @Binding var value: Float
    let remoteSyncToken: UInt
    let onLocalCommit: () -> Void

    @State private var localValue: Float = 0
    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 40, alignment: .leading)
            Slider(
                value: $localValue,
                in: -1...1,
                step: 0.05,
                onEditingChanged: { editing in
                    isDragging = editing
                    if !editing {
                        value = localValue
                        onLocalCommit()
                    }
                }
            )
            .accentColor(.white)
            Text(String(format: "%.2f", localValue))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 38)
        }
        .onAppear {
            localValue = value
        }
        .onChange(of: value) { newValue in
            if !isDragging {
                localValue = newValue
            }
        }
        .onChange(of: remoteSyncToken) { _ in
            if !isDragging {
                localValue = value
            }
        }
    }
}

// SwiftUI预览
#Preview {
    ContentView()
}
