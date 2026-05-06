//
//  DeviceIdInfoView.swift
//  srs
//
//  显示设备ID信息（从登录页空白区域点击进入）
//

import SwiftUI

struct DeviceIdInfoView: View {
    @Environment(\.dismiss) private var dismiss
    
    private let deviceId = DeviceIDManager.shared.getDeviceID()
    private let bundleId = Bundle.main.bundleIdentifier ?? "未知"
    
    @State private var copied = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                Spacer()
                
                // 图标
                Image(systemName: "iphone.badge.checkmark")
                    .font(.system(size: 60))
                    .foregroundColor(Color(hex: "65AEF7"))
                
                Text("设备信息")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Color(hex: "1A1A1A"))
                
                // 设备ID卡片
                VStack(alignment: .leading, spacing: 16) {
                    // 设备ID
                    VStack(alignment: .leading, spacing: 8) {
                        Text("设备ID")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "808080"))
                        
                        Text(deviceId)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(hex: "1A1A1A"))
                            .textSelection(.enabled)
                    }
                    
                    Divider()
                    
                    // Bundle ID
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bundle ID")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "808080"))
                        
                        Text(bundleId)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(hex: "1A1A1A"))
                    }
                    
                    Divider()
                    
                    // 系统信息
                    VStack(alignment: .leading, spacing: 8) {
                        Text("系统")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "808080"))
                        
                        Text("iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.name)")
                            .font(.system(size: 15))
                            .foregroundColor(Color(hex: "1A1A1A"))
                    }
                }
                .padding(20)
                .background(Color(hex: "F4F4F8"))
                .cornerRadius(12)
                .padding(.horizontal, 24)
                
                // 复制按钮
                Button(action: {
                    UIPasteboard.general.string = deviceId
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copied = false
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14))
                        Text(copied ? "已复制" : "复制设备ID")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .frame(width: 180, height: 44)
                    .background(copied ? Color.green : Color(hex: "65AEF7"))
                    .cornerRadius(22)
                }
                
                Spacer()
                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Color(hex: "1A1A1A"))
                    }
                }
            }
        }
    }
}

#Preview {
    DeviceIdInfoView()
}
