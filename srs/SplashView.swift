import SwiftUI

// MARK: - Splash 启动页（全屏背景图，1秒后跳转登录）
struct SplashView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        ZStack {
            // 全屏背景图
            Image("splash")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
        }
        .onAppear {
            // 1秒后直接跳转到登录页（跳过首页）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    appState.navigateToMonitorLogin()
                }
            }
        }
    }
}

#Preview {
    SplashView()
        .environmentObject(AppState())
}
