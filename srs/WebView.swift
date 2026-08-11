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
