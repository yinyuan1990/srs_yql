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
