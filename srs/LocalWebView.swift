import SwiftUI
import WebKit

/// 本地 HTML 文件 WebView 组件
struct LocalWebView: View {
    let fileName: String  // 不带扩展名的文件名，如 "privacy_policy"
    let title: String
    @Environment(\.presentationMode) var presentationMode
    @State private var isLoading = true
    @State private var loadError: String? = nil
    
    var body: some View {
        ZStack {
            // 背景
            Color.white.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // 自定义导航栏
                HStack {
                    Button(action: {
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .medium))
                            Text("返回")
                                .font(.system(size: 16))
                        }
                        .foregroundColor(Color(hex: "1A1A1A"))
                    }
                    
                    Spacer()
                    
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Color(hex: "1A1A1A"))
                    
                    Spacer()
                    
                    // 占位，保持标题居中
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .medium))
                        Text("返回")
                            .font(.system(size: 16))
                    }
                    .opacity(0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.white)
                
                Divider()
                
                // WebView 内容
                ZStack {
                    LocalWebViewRepresentable(
                        fileName: fileName,
                        isLoading: $isLoading,
                        loadError: $loadError
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
                        .background(Color.white)
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
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white)
                    }
                }
            }
        }
        .navigationBarHidden(true)
    }
}

/// 本地 HTML WebKit 视图包装器
struct LocalWebViewRepresentable: UIViewRepresentable {
    let fileName: String
    @Binding var isLoading: Bool
    @Binding var loadError: String?
    
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.backgroundColor = .white
        webView.isOpaque = false
        
        // 加载本地 HTML 文件
        if let filePath = Bundle.main.path(forResource: fileName, ofType: "html") {
            let fileURL = URL(fileURLWithPath: filePath)
            webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        } else {
            DispatchQueue.main.async {
                self.loadError = "找不到文件: \(fileName).html"
                self.isLoading = false
            }
        }
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // 不需要更新
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: LocalWebViewRepresentable
        
        init(_ parent: LocalWebViewRepresentable) {
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
    }
}

// 预览
struct LocalWebView_Previews: PreviewProvider {
    static var previews: some View {
        LocalWebView(fileName: "privacy_policy", title: "隐私政策")
    }
}

