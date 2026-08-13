import SwiftUI
import WebKit

// 通用网页视图组件
struct WebView: View {
    let url: String
    let title: String
    @Environment(\.presentationMode) var presentationMode
    @State private var isLoading = true
    @State private var loadError: String? = nil
    @State private var hasLoadedOnce = false  // 新增：防止重复加载
    
    var body: some View {
        NavigationView {
            ZStack {
                // WebView内容
                WebViewRepresentable(
                    url: url,
                    isLoading: $isLoading,
                    loadError: $loadError,
                    hasLoadedOnce: $hasLoadedOnce
                )
                
                // 加载指示器
                if isLoading && loadError == nil {
                    VStack {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("加载中...")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
                }
                
                // 错误提示
                if let error = loadError, !isLoading {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 50))
                            .foregroundColor(.orange)
                        
                        Text("加载失败")
                            .font(.headline)
                        
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        Button("重新加载") {
                            reloadWebView()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar(content: {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("返回") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("刷新") {
                        reloadWebView()
                    }
                }
            })
        }
    }
    
    // 重新加载方法
    private func reloadWebView() {
        loadError = nil
        isLoading = true
        hasLoadedOnce = false
    }
}

// WebKit视图包装器
struct WebViewRepresentable: UIViewRepresentable {
    let url: String
    @Binding var isLoading: Bool
    @Binding var loadError: String?
    @Binding var hasLoadedOnce: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // 防止重复加载
        guard !hasLoadedOnce else { return }
        
        guard let url = URL(string: url) else {
            DispatchQueue.main.async {
                self.loadError = "无效的URL地址"
                self.isLoading = false
            }
            return
        }
        
        let request = URLRequest(url: url, timeoutInterval: 30.0)
        webView.load(request)
        hasLoadedOnce = true
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebViewRepresentable
        
        init(_ parent: WebViewRepresentable) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = true
                self.parent.loadError = nil
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.loadError = nil
            }
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.loadError = error.localizedDescription
            }
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.loadError = error.localizedDescription
            }
        }
        
        // 处理SSL证书错误
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// 预览
struct WebView_Previews: PreviewProvider {
    static var previews: some View {
        WebView(url: "https://www.apple.com", title: "Apple官网")
    }
}

// MARK: - §59 登录广告弹框（登录成功后 sheet 弹出；WKWebView 加载后端 /config/login-ad/page）
// 「已读，不再提醒」→ 调用方本地记 version，该版本不再弹；「关闭」/下滑关闭 = 不记，下次登录还弹。
// 内容里的链接点击 → 外部浏览器打开；长按选择复制是 WKWebView 默认能力。
struct LoginAdView: View {
    let title: String
    let onRead: () -> Void
    let onClose: () -> Void

    private var pageURL: String {
        APIConfig.shared.fullURL(for: APIConfig.Ad.loginAdPage)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("关闭") { onClose() }
                    .font(.system(size: 15))
                    .foregroundColor(.gray)
                Spacer()
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button("浏览器打开") {
                    if let url = URL(string: pageURL) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.system(size: 14))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            LoginAdWebView(urlString: pageURL)

            Divider()

            Button(action: onRead) {
                Text("已读，不再提醒")
                    .font(.system(size: 16, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
        }
    }
}

// §59 广告专用 WKWebView：JS 关闭，链接点击拦截 → 外部浏览器
struct LoginAdWebView: UIViewRepresentable {
    let urlString: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url, timeoutInterval: 30.0))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, WKNavigationDelegate {
        // 初始加载是 .other；只有用户点内容里的链接（.linkActivated）才拦到外部浏览器
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - §60 邀请活动弹层（2026-08-13，登录后按用户状态三态展示）
// 试用未绑定 = 邀请人输入框（终身一次警示）/ 试用已绑定 = 已用过邀请+活动预览 / 会员 = 打卡信息+档位领取
struct ReferralView: View {
    @State var status: APIService.ReferralStatus
    let onClose: () -> Void

    @State private var inviterInput: String = ""
    @State private var busy: Bool = false
    @State private var errorText: String?
    @State private var noticeText: String?

    private var isMember: Bool { status.state == "MEMBER" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("关闭") { onClose() }
                    .font(.system(size: 15))
                    .foregroundColor(.gray)
                Spacer()
                Text(isMember ? "🎁 邀请打卡" : "🎁 邀请有礼")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                // 占位对称
                Text("关闭").font(.system(size: 15)).opacity(0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let content = status.popupContent, !content.isEmpty {
                        Text(content)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }

                    switch status.state {
                    case "TRIAL_CAN_BIND":
                        Text("填写邀请人（会员的昵称或完整账号），即可解锁全部功能体验 \(status.trialHours ?? 24) 小时")
                            .font(.system(size: 14))
                        TextField("邀请人昵称 / 完整账号", text: $inviterInput)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .disabled(busy)
                        Text("⚠️ 邀请号终身只能选择一次，提交后不可更改")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.red)
                        if let err = errorText {
                            Text(err).font(.system(size: 13)).foregroundColor(.red)
                        }
                        Button(action: bind) {
                            Text(busy ? "提交中..." : "确认绑定")
                                .font(.system(size: 16, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .disabled(busy)
                    case "TRIAL_BOUND":
                        Text("✅ 您已使用过邀请（终身一次）")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.green)
                        Text("解锁等级后即可作为邀请人参加活动，邀请好友赢会员时长")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    default:  // MEMBER
                        HStack {
                            VStack {
                                Text("\(status.boundCount ?? 0)")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundColor(.blue)
                                Text("已邀请（人）").font(.system(size: 12)).foregroundColor(.secondary)
                            }.frame(maxWidth: .infinity)
                            VStack {
                                Text("\(status.successCount ?? 0)")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundColor(.orange)
                                Text("成功解锁（人）").font(.system(size: 12)).foregroundColor(.secondary)
                            }.frame(maxWidth: .infinity)
                        }
                        Text("好友通过邀请绑定并付费解锁等级后计一次成功，达档可领取会员时长")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }

                    if let notice = noticeText {
                        Text(notice).font(.system(size: 13, weight: .medium)).foregroundColor(.green)
                    }

                    // 奖励档位列表（三态都展示；试用标注"解锁等级后可领"）
                    if let tiers = status.tiers, !tiers.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("奖励档位")
                                .font(.system(size: 15, weight: .semibold))
                                .padding(.top, 6)
                            if !isMember {
                                Text("（解锁等级后才可参加领取）")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            ForEach(tiers) { tier in
                                HStack {
                                    Text("邀请成功 \(tier.count ?? 0) 人")
                                        .font(.system(size: 14))
                                    Spacer()
                                    Text((tier.months ?? 0) > 0 ? "+\(tier.months ?? 0) 个月" : "已封顶")
                                        .font(.system(size: 13))
                                        .foregroundColor((tier.months ?? 0) > 0 ? .orange : .secondary)
                                    switch tier.status ?? "LOCKED" {
                                    case "CLAIMED":
                                        Text("已领取").font(.system(size: 13)).foregroundColor(.green)
                                    case "CLAIMABLE":
                                        Button("领取") { claim(tier.count ?? 0) }
                                            .font(.system(size: 13, weight: .semibold))
                                            .disabled(busy)
                                    case "ACHIEVED":
                                        Text("已达成").font(.system(size: 13)).foregroundColor(.blue)
                                    default:
                                        Text("未达成").font(.system(size: 13)).foregroundColor(Color(.systemGray3))
                                    }
                                }
                                .padding(.vertical, 8)
                                Divider()
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func refresh() {
        Task {
            let token = UserDefaults.standard.string(forKey: "jwt_token") ?? ""
            if let st = try? await APIService.shared.getReferralStatus(token: token) {
                await MainActor.run { self.status = st }
            }
        }
    }

    private func bind() {
        let input = inviterInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { errorText = "请输入邀请人的昵称或完整账号"; return }
        busy = true
        errorText = nil
        Task {
            do {
                let token = UserDefaults.standard.string(forKey: "jwt_token") ?? ""
                let deviceId = UserDefaults.standard.string(forKey: "device_id") ?? ""
                let r = try await APIService.shared.referralBind(inviter: input, deviceId: deviceId, token: token)
                await MainActor.run {
                    busy = false
                    noticeText = r.message ?? "绑定成功！"
                }
                refresh()
            } catch {
                await MainActor.run {
                    busy = false
                    errorText = (error as? APIError)?.localizedDescription ?? "绑定失败，请重试"
                }
            }
        }
    }

    private func claim(_ milestone: Int) {
        busy = true
        Task {
            do {
                let token = UserDefaults.standard.string(forKey: "jwt_token") ?? ""
                let r = try await APIService.shared.referralClaim(milestone: milestone, token: token)
                await MainActor.run {
                    busy = false
                    noticeText = r.message ?? "领取成功！"
                }
                refresh()
            } catch {
                await MainActor.run {
                    busy = false
                    noticeText = nil
                    errorText = (error as? APIError)?.localizedDescription
                }
            }
        }
    }
}
