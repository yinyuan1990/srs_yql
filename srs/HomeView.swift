import SwiftUI

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        ZStack {
            // 底层背景色
            Color(hex: "F4F4F9")
                .ignoresSafeArea()
            
            // 顶部渐变背景
            VStack {
            LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color(hex: "B1E8FA"), location: 0),
                        .init(color: Color(hex: "C6E0FA"), location: 0.5288),
                        .init(color: Color(hex: "F4F4F9"), location: 1.0)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 249)
                
                Spacer()
            }
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // 顶部标题栏
                HStack {
                    Spacer()
                    
                Text("首页")
                        .font(.custom("PingFang SC", size: 18))
                        .fontWeight(.semibold)
                        .foregroundColor(Color(hex: "1A1A1A"))
                    
                    Spacer()
                }
                .frame(height: 44)
                .padding(.top, 44) // 状态栏高度
                
                // 主要内容区域
                VStack(alignment: .leading, spacing: 17) {
                    // 温馨提示部分
                    VStack(alignment: .leading, spacing: 11) {
                        Text("温馨提示")
                            .font(.custom("PingFang SC", size: 18))
                            .fontWeight(.semibold)
                            .foregroundColor(Color(hex: "1A1A1A"))
                    
                        Text("要使用我们的产品。您需要两台手机设备配合，\n一台架设在家里，作为监控，一台家长使用观看。")
                            .font(.custom("PingFang HK", size: 12))
                            .foregroundColor(Color(hex: "666666"))
                            .lineSpacing(5)
                    }
                    
                    // 卡片区域
                    VStack(spacing: 10) {
                        // 家长端卡片
                        Button(action: {
                            // 家长端暂无效果
                        }) {
                            HStack {
                                Text("家长端")
                                    .font(.custom("PingFang SC", size: 16))
                                    .fontWeight(.semibold)
                                    .foregroundColor(Color(hex: "1A1A1A"))
                                
                                Spacer()
                                
                                Image("jiachang")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 92, height: 94)
                            }
                            .padding(.leading, 36)
                            .padding(.trailing, 28)
                            .padding(.vertical, 2)
                            .frame(height: 98)
                .background(Color.white)
                            .cornerRadius(12)
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        // 监控端卡片
                    Button(action: {
                        appState.navigateToMonitorLogin()
                    }) {
                        HStack {
                            Text("监控端")
                                    .font(.custom("PingFang SC", size: 16))
                                    .fontWeight(.semibold)
                                    .foregroundColor(Color(hex: "1A1A1A"))
                            
                            Spacer()
                            
                                Image("kongzhiduan")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 118, height: 94)
                            }
                            .padding(.leading, 36)
                            .padding(.trailing, 28)
                            .padding(.vertical, 2)
                            .frame(height: 98)
                        .background(Color.white)
                            .cornerRadius(12)
                    }
                    .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 15)
                .padding(.top, 18)
                
                Spacer()
                
                // 底部指示器
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(hex: "1A1A1A"))
                    .frame(width: 134, height: 5)
                    .padding(.bottom, 8)
            }
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState())
}
