# TestFlight 上架详细指南

## 📋 目录

1. [准备工作](#一准备工作)
2. [账号注册](#二apple-developer-账号注册)
3. [Xcode 配置](#三xcode-项目配置)
4. [App Store Connect 配置](#四app-store-connect-配置)
5. [构建上传](#五构建上传)
6. [TestFlight 测试](#六testflight-测试配置)
7. [常见问题](#七常见问题)

---

## 一、准备工作

### 1.1 必备条件

| 项目 | 说明 |
|------|------|
| Mac 电脑 | 安装 macOS 12.0+ |
| Xcode | 版本 14.0+（建议最新版） |
| Apple ID | 用于注册开发者账号 |
| 信用卡/借记卡 | 支付 $99 年费 |
| 身份证 | 中国用户实名认证 |

### 1.2 你的 App 信息

| 项目 | 当前值 |
|------|--------|
| App 名称 | （填写你的 App 名称） |
| Bundle ID | （填写你的 Bundle ID，如 com.company.appname） |
| 版本号 | 1.0 |
| 构建号 | 1 |
| 最低 iOS 版本 | iOS 15.0+ |

---

## 二、Apple Developer 账号注册

### 2.1 注册步骤

1. 访问 https://developer.apple.com/programs/enroll/
2. 点击「Start Your Enrollment」
3. 使用 Apple ID 登录
4. 选择账号类型：
   - **个人**：适合个人开发者
   - **公司/组织**：需要 D-U-N-S 编号
5. 填写个人信息
6. 身份验证（上传身份证照片）
7. 支付费用 **¥688/年**（约 $99）
8. 等待审核（通常 24-48 小时）

### 2.2 账号类型对比

| 类型 | 费用 | 审核时间 | 适用 |
|------|------|----------|------|
| 个人账号 | ¥688/年 | 24-48 小时 | 个人开发者 |
| 公司账号 | ¥688/年 | 1-2 周 | 公司上架 |

---

## 三、Xcode 项目配置

### 3.1 签名配置

1. 打开 Xcode → 选择项目
2. 选择 Target → **Signing & Capabilities**
3. 配置如下：

```
☑️ Automatically manage signing
Team: [选择你的开发者团队]
Bundle Identifier: com.yourcompany.appname
```

### 3.2 版本号配置

位置：Target → **General**

| 字段 | 说明 | 示例 |
|------|------|------|
| Version | 对外显示版本号 | 1.0.0 |
| Build | 每次上传必须递增 | 1, 2, 3... |

### 3.3 部署目标

位置：Target → **General** → **Minimum Deployments**

```
iOS: 15.0
```

---

## 四、你的 App 使用的权限

### 4.1 当前 Info.plist 权限配置

你的 App 已配置以下权限：

| 权限 Key | 用途说明 | 审核要求 |
|----------|----------|----------|
| `NSCameraUsageDescription` | 此应用需要访问相机以进行直播推流功能 | ✅ 必须 |
| `NSMicrophoneUsageDescription` | 此应用需要访问麦克风以进行直播推流功能 | ✅ 必须 |
| `NSPhotoLibraryUsageDescription` | 此应用需要访问相册以读取和管理您的照片 | ✅ 必须 |
| `NSPhotoLibraryAddUsageDescription` | 此应用需要访问相册以保存注册账号信息 | ✅ 必须 |

### 4.2 Info.plist 完整权限内容

```xml
<!-- 相机权限 -->
<key>NSCameraUsageDescription</key>
<string>此应用需要访问相机以进行直播推流功能</string>

<!-- 麦克风权限 -->
<key>NSMicrophoneUsageDescription</key>
<string>此应用需要访问麦克风以进行直播推流功能</string>

<!-- 相册读取权限 -->
<key>NSPhotoLibraryUsageDescription</key>
<string>此应用需要访问相册以读取和管理您的照片</string>

<!-- 相册写入权限 -->
<key>NSPhotoLibraryAddUsageDescription</key>
<string>此应用需要访问相册以保存注册账号信息</string>
```

### 4.3 权限说明审核要点

⚠️ **审核员会检查的内容：**

1. **权限说明必须具体**：不能只写「需要访问相机」，要说明具体用途
2. **权限必须与功能匹配**：如果声明了权限但没用到，会被拒
3. **必须在使用前请求**：不能一进 App 就弹出所有权限请求

✅ **你的权限说明已经符合要求**

---

## 五、App Store Connect 配置

### 5.1 创建 App

1. 登录 https://appstoreconnect.apple.com
2. 点击「我的 App」→「+」→「新建 App」
3. 填写信息：

| 字段 | 说明 | 示例 |
|------|------|------|
| 平台 | 选择 iOS | iOS |
| App 名称 | 全球唯一，30 字符内 | 爱棋牌监控 |
| 主要语言 | 默认语言 | 简体中文 |
| Bundle ID | 与 Xcode 一致 | com.yourcompany.appname |
| SKU | 唯一标识（自定义） | aiqipai_001 |
| 用户访问权限 | 完全访问 | 完全访问权限 |

### 5.2 App 信息配置

创建后需要填写：

| 项目 | 是否必须 | 说明 |
|------|----------|------|
| 类别 | ✅ | 如：工具、效率 |
| 内容分级 | ✅ | 填写问卷 |
| 隐私政策 URL | ✅（外部测试） | 必须可访问 |
| 技术支持 URL | ❌ | 可选 |

---

## 六、构建上传

### 6.1 Archive 构建

1. 选择目标设备：**Any iOS Device (arm64)**
2. 菜单：**Product** → **Archive**
3. 等待构建完成（2-5 分钟）

### 6.2 上传到 App Store Connect

1. 构建完成后自动打开 **Organizer**
2. 选择刚才的 Archive
3. 点击 **Distribute App**
4. 选择 **App Store Connect**
5. 选择 **Upload**
6. 保持默认选项 → **Next**
7. 选择签名证书 → **Upload**
8. 等待上传完成

### 6.3 上传后处理

上传成功后需要等待 Apple 处理：

| 阶段 | 时间 | 状态 |
|------|------|------|
| 上传中 | 1-5 分钟 | Uploading |
| 处理中 | 5-30 分钟 | Processing |
| 准备就绪 | - | Ready to Submit |

---

## 七、TestFlight 测试配置

### 7.1 内部测试（推荐先用这个）

**特点：**
- ❌ 无需 Apple 审核
- 👥 最多 100 人
- ⏰ 有效期 90 天

**配置步骤：**

1. 登录 App Store Connect
2. 选择你的 App → **TestFlight**
3. 等待构建版本处理完成
4. 点击构建版本 → **加密合规信息**
5. 回答加密问题（见下方）
6. **用户和访问权限** → 添加内部测试员
7. 测试员收到邮件邀请

### 7.2 加密合规信息（首次必填）

**问题：您的 App 是否使用加密？**

**你的 App 情况：**
- 使用 HTTPS 网络请求 ✅
- 使用 WebRTC（DTLS/SRTP 加密）✅
- 没有自定义加密算法

**回答：**
```
是 → 仅使用 iOS、macOS 或第三方库的标准加密
```

### 7.3 外部测试（大规模测试）

**特点：**
- ✅ 需要 Apple 轻度审核（1-2 天）
- 👥 最多 10000 人
- ⏰ 有效期 90 天

**额外需要的资料：**

| 项目 | 是否必须 | 说明 |
|------|----------|------|
| App 图标 | ✅ | 1024×1024 PNG |
| 测试详情 | ✅ | 描述测试内容 |
| 反馈邮箱 | ✅ | 接收反馈 |
| 隐私政策 URL | ✅ | 必须可访问 |
| 演示账号 | ✅（如需登录） | 测试用账号密码 |

**测试详情示例：**

```
测试内容：
本次版本包含以下功能的测试：
1. 视频直播推流功能
2. 远程控制功能
3. 画质切换功能
4. 账号登录注册功能

测试说明：
- 请确保网络畅通
- 使用演示账号登录
- 测试完成后请提交反馈

已知问题：
- 暂无
```

### 7.4 邀请测试员

**内部测试员邀请：**
1. App Store Connect → 用户和访问权限
2. 添加用户（Apple ID 邮箱）
3. 选择角色：App 管理 或 开发者
4. 分配到对应 App
5. 用户接受邀请后，在 TestFlight 中添加

**外部测试员邀请：**
1. TestFlight → 外部测试 → 添加测试员
2. 输入邮箱（不需要 Apple ID）
3. 等待审核通过后自动发送邀请

### 7.5 测试员安装步骤

测试员收到邮件后：

1. 在 App Store 下载 **TestFlight** App
2. 打开邮件中的链接 或 输入兑换码
3. 在 TestFlight 中安装你的 App
4. 每次有新版本会收到通知

---

## 八、上传检查清单

### 8.1 上传前检查

- [ ] Apple Developer 账号已激活
- [ ] Xcode 签名配置正确（Team 已选择）
- [ ] Bundle ID 与 App Store Connect 一致
- [ ] Version 版本号正确
- [ ] Build 构建号已递增（每次上传必须不同）
- [ ] Info.plist 权限说明已添加
- [ ] 代码无崩溃 Bug
- [ ] 选择 Any iOS Device (arm64) 作为目标

### 8.2 上传后检查

- [ ] 等待处理完成（5-30 分钟）
- [ ] 填写加密合规信息
- [ ] 添加测试员
- [ ] 填写测试详情（外部测试）
- [ ] 等待审核（外部测试，1-2 天）
- [ ] 通知测试员下载 TestFlight

---

## 九、常见问题

### Q1: 上传后一直显示「正在处理」？

**原因：** 正常现象，Apple 在扫描和验证

**解决：** 等待 5-30 分钟，如超过 2 小时可联系 Apple

---

### Q2: 构建版本号必须递增？

**原因：** 每次上传的 Build 号必须比之前大

**解决：** 
- Version 可以不变（如 1.0.0）
- Build 必须递增（1 → 2 → 3）

---

### Q3: 出现 「Missing Compliance」？

**原因：** 未填写加密合规信息

**解决：** 在 App Store Connect 中填写加密问题答案

---

### Q4: 测试员收不到邀请？

**原因：** 邮件可能在垃圾箱

**解决：**
- 检查垃圾邮件
- 确认邮箱地址正确
- 让测试员主动在 TestFlight 中输入兑换码

---

### Q5: 外部测试审核被拒？

**常见原因：**
- App 崩溃
- 权限说明不清晰
- 功能不完整
- 缺少隐私政策 URL

**解决：** 根据拒绝邮件中的原因修复

---

## 十、时间线参考

| 步骤 | 预计时间 |
|------|----------|
| 申请开发者账号 | 24-48 小时 |
| Xcode 配置 | 30 分钟 |
| App Store Connect 创建 App | 10 分钟 |
| Archive + Upload | 10-20 分钟 |
| Apple 处理 | 5-30 分钟 |
| 内部测试（无审核） | 立即可用 |
| 外部测试审核 | 1-2 天 |
| **总计（内部测试）** | **1-2 天** |
| **总计（外部测试）** | **3-4 天** |

---

## 十一、联系支持

- **Apple Developer 支持**：https://developer.apple.com/contact/
- **App Store Connect 帮助**：https://developer.apple.com/app-store-connect/

---

*最后更新：2024年12月*

