# iOS 应用分发平台指南

按**上架难度从易到难**排序，包含所需资料和流程。

---

## 📱 第一梯队：最简单（无需审核/即时分发）

### 1. 蒲公英（pgyer.com）
**难度：⭐ 极简**

| 项目 | 要求 |
|------|------|
| 账号 | 免费注册 |
| 证书 | Ad-Hoc 或企业证书 |
| IPA | 直接上传 |
| 审核 | 无 |
| 限制 | 免费版每天100次下载 |

**所需资料：**
- [x] IPA 安装包
- [x] 应用图标（可选）
- [x] 应用描述（可选）

**流程：**
1. 注册账号
2. 上传 IPA
3. 获取下载链接/二维码
4. 分享给测试用户

---

### 2. 雷神分发（diawi.com 国内替代）/ Diawi
**难度：⭐ 极简**

| 项目 | 要求 |
|------|------|
| 账号 | 可不注册 |
| 证书 | Ad-Hoc 或企业证书 |
| IPA | 直接上传 |
| 审核 | 无 |
| 有效期 | 免费版7天 |

**所需资料：**
- [x] IPA 安装包

**流程：**
1. 打开网站
2. 拖拽 IPA 上传
3. 获取链接

---

### 3. 牛蛙分发 / 分发猫 / 香蕉云
**难度：⭐ 极简**

类似蒲公英，国内第三方分发平台。

**所需资料：**
- [x] IPA 安装包
- [x] 应用名称
- [x] 应用图标

---

## 📱 第二梯队：简单（需 Apple 账号）

### 4. TestFlight（Apple 官方测试平台）
**难度：⭐⭐ 简单**

| 项目 | 要求 |
|------|------|
| 账号 | Apple Developer（$99/年） |
| 证书 | App Store 证书 |
| 审核 | 首次需要简单审核（1-2天） |
| 测试人数 | 内部测试100人，外部测试10000人 |
| 有效期 | 90天 |

**所需资料：**
- [x] Apple Developer 账号
- [x] App Store Connect 中创建 App
- [x] 应用图标 1024x1024
- [x] Bundle ID
- [x] 版本号
- [x] 构建号
- [x] 应用描述（外部测试需要）
- [x] 测试说明（外部测试需要）
- [x] 联系邮箱

**流程：**
1. Xcode → Archive → Distribute App → TestFlight
2. 等待处理（几分钟到几小时）
3. App Store Connect 中添加测试员
4. 测试员收到邮件，下载 TestFlight App 安装

---

## 📱 第三梯队：中等（需要审核）

### 5. App Store（苹果官方商店）
**难度：⭐⭐⭐⭐ 较难**

| 项目 | 要求 |
|------|------|
| 账号 | Apple Developer（$99/年） |
| 审核 | 严格审核（1-7天） |
| 拒审率 | 较高 |

**所需资料：**

#### 基础信息
- [x] Apple Developer 账号
- [x] Bundle ID（唯一标识）
- [x] SKU（库存单位，自定义）
- [x] 应用名称（30字符内）
- [x] 副标题（30字符内，可选）
- [x] 隐私政策 URL
- [x] 技术支持 URL
- [x] 营销 URL（可选）

#### 应用图标
- [x] 1024 x 1024 PNG（无透明）

#### 截图（每种设备尺寸）
| 设备 | 尺寸 |
|------|------|
| iPhone 6.7" | 1290 x 2796 |
| iPhone 6.5" | 1284 x 2778 |
| iPhone 5.5" | 1242 x 2208 |
| iPad Pro 12.9" | 2048 x 2732（如支持 iPad）|

- 每种尺寸 1-10 张截图
- 可选：预览视频（15-30秒）

#### 应用信息
- [x] 关键词（100字符内，逗号分隔）
- [x] 描述（4000字符内）
- [x] 新功能介绍（每个版本）
- [x] 分类（主分类 + 次分类）
- [x] 内容分级问卷
- [x] 版权信息

#### 构建信息
- [x] 版本号（如 1.0.0）
- [x] 构建号（如 1）

#### 审核信息
- [x] 联系人姓名
- [x] 联系电话
- [x] 联系邮箱
- [x] 演示账号（如需登录）
- [x] 审核备注（解释特殊功能）

#### 隐私相关
- [x] 隐私政策 URL
- [x] 数据收集声明
- [x] 第三方 SDK 声明
- [x] App 隐私标签（App Privacy）

#### 特殊权限说明（Info.plist）
| 权限 | 说明示例 |
|------|----------|
| NSCameraUsageDescription | "用于视频推流" |
| NSMicrophoneUsageDescription | "用于音频采集" |
| NSLocationWhenInUseUsageDescription | "用于..." |

---

### 6. AltStore（侧载商店）
**难度：⭐⭐⭐ 中等**

| 项目 | 要求 |
|------|------|
| 账号 | Apple ID（免费） |
| 限制 | 需要电脑配合，7天重签 |
| 审核 | 无 |

**所需资料：**
- [x] IPA 安装包
- [x] 电脑安装 AltServer
- [x] 手机安装 AltStore

---

## 📱 第四梯队：国外平台

### 7. Google Play（Android 对照）
不适用于 iOS。

### 8. 企业签名分发（Enterprise）
**难度：⭐⭐⭐⭐ 较难**

| 项目 | 要求 |
|------|------|
| 账号 | Apple Developer Enterprise（$299/年） |
| 申请条件 | 需要 D-U-N-S 编号，公司实体 |
| 审核 | Apple 审核企业资质 |
| 限制 | 仅限内部员工使用（违规会被封） |

**所需资料：**
- [x] 公司营业执照
- [x] D-U-N-S 编号
- [x] 公司官网
- [x] 法人信息
- [x] Apple 电话核实

---

### 9. 超级签名
**难度：⭐⭐⭐ 中等（但有风险）**

| 项目 | 要求 |
|------|------|
| 原理 | 使用多个个人开发者账号签名 |
| 费用 | 按设备收费 |
| 风险 | 证书可能被苹果吊销 |

**所需资料：**
- [x] IPA 安装包
- [x] 找第三方服务商

---

## 📋 快速对比表

| 平台 | 难度 | 费用 | 审核 | 适用场景 |
|------|------|------|------|----------|
| 蒲公英 | ⭐ | 免费/付费 | 无 | 内测分发 |
| Diawi | ⭐ | 免费 | 无 | 临时分发 |
| TestFlight | ⭐⭐ | $99/年 | 轻度 | 正式测试 |
| App Store | ⭐⭐⭐⭐ | $99/年 | 严格 | 正式上架 |
| 企业签名 | ⭐⭐⭐⭐ | $299/年 | 资质审核 | 企业内部 |
| 超级签名 | ⭐⭐⭐ | 按设备 | 无 | 灰色地带 |

---

## 🚀 推荐路径

1. **开发阶段**：蒲公英 / Diawi（快速分发给测试人员）
2. **正式测试**：TestFlight（稳定，官方支持）
3. **正式上架**：App Store（最终目标）

---

## 📝 App Store 审核常见拒绝原因

1. **崩溃/Bug** - 确保充分测试
2. **缺少隐私政策** - 必须有可访问的隐私政策 URL
3. **权限说明不清** - Info.plist 中的权限描述要具体
4. **测试账号无效** - 提供有效的演示账号
5. **功能不完整** - 不能有"即将推出"的占位功能
6. **元数据问题** - 截图、描述与实际功能不符
7. **第三方登录** - 必须支持 Apple 登录（如有其他第三方登录）
8. **内购问题** - 虚拟商品必须使用苹果内购
9. **敏感内容** - 成人内容、赌博等需要特殊处理

---

## 🔧 打包命令参考

### 生成 IPA（用于第三方分发）
```bash
# 1. Archive
xcodebuild archive -workspace YourApp.xcworkspace -scheme YourApp -archivePath build/YourApp.xcarchive

# 2. Export IPA (Ad-Hoc)
xcodebuild -exportArchive -archivePath build/YourApp.xcarchive -exportPath build/ -exportOptionsPlist ExportOptions.plist
```

### ExportOptions.plist 示例（Ad-Hoc）
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>ad-hoc</string>
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>
</dict>
</plist>
```

---

---

## 📜 资质要求详解

### 一、Apple Developer 账号类型对比

| 类型 | 费用 | 适用对象 | 上架 App Store | 企业内部分发 | 申请条件 |
|------|------|----------|----------------|--------------|----------|
| **个人账号** | $99/年 | 个人开发者 | ✅ | ❌ | 身份证/护照 |
| **公司账号** | $99/年 | 公司/组织 | ✅ | ❌ | D-U-N-S 编号 + 公司资质 |
| **企业账号** | $299/年 | 大型企业 | ❌ | ✅ | D-U-N-S 编号 + 严格审核 |

---

### 二、个人开发者账号所需资料

| 项目 | 说明 |
|------|------|
| Apple ID | 注册一个新的 Apple ID |
| 身份证明 | 身份证/护照（中国用户需身份证） |
| 信用卡/借记卡 | 支持 Visa/MasterCard/银联 |
| 手机号 | 用于验证 |
| 费用 | ¥688/年（约 $99） |

**申请流程：**
1. 访问 https://developer.apple.com/programs/enroll/
2. 登录 Apple ID
3. 填写个人信息
4. 身份验证（拍照上传证件）
5. 支付费用
6. 等待审核（通常 24-48 小时）

---

### 三、公司开发者账号所需资料

| 项目 | 说明 | 如何获取 |
|------|------|----------|
| **D-U-N-S 编号** | 邓白氏编号（9位数字） | 免费申请，约 14 天 |
| **公司法人信息** | 法人姓名、职位 | 营业执照 |
| **公司官网** | 必须可访问 | 域名需与公司相关 |
| **公司邮箱** | 企业邮箱（非 QQ/163） | 如 admin@yourcompany.com |
| **联系电话** | 公司座机或法人手机 | Apple 会电话核实 |
| **营业执照** | 三证合一 | 工商局 |

**D-U-N-S 编号申请：**
1. 访问 https://developer.apple.com/enroll/duns-lookup/
2. 填写公司信息
3. 邓白氏公司会联系核实
4. 约 14 个工作日获得编号

**Apple 电话核实内容：**
- 确认公司是否真实存在
- 确认法人身份
- 确认申请人是否有权代表公司
- 确认公司地址

---

### 四、企业开发者账号所需资料（Enterprise）

| 项目 | 说明 |
|------|------|
| D-U-N-S 编号 | 必须 |
| 公司规模 | 通常要求 100+ 员工 |
| 使用场景说明 | 必须说明仅内部使用 |
| 法人授权书 | 签字盖章 |
| 公司官网 | 必须有详细公司介绍 |

**注意事项：**
- ⚠️ 企业证书不能用于公开分发
- ⚠️ 违规使用会被苹果吊销证书
- ⚠️ 申请周期较长（1-2 个月）
- ⚠️ 审核非常严格，拒绝率高

---

### 五、直播/视频类 App 特殊资质（中国大陆）

如果 App 涉及**直播、视频、音视频通讯**，在中国大陆上架可能需要：

| 资质 | 说明 | 办理机构 |
|------|------|----------|
| **ICP 备案** | 网站/App 备案 | 工信部 |
| **网络视听许可证** | 视频直播类必须 | 广电总局 |
| **增值电信业务许可证** | 互联网信息服务 | 省通信管理局 |
| **网络文化经营许可证** | 含表演/游戏直播 | 文化和旅游部 |

**实际情况：**
- 📌 个人开发者：通常不需要这些资质（除非涉及敏感内容）
- 📌 公司开发者：看 App 具体功能
- 📌 纯工具类 App：一般不需要特殊资质
- 📌 监控/摄像头类 App：通常只需要常规审核

---

### 六、App Store 上架完整资料清单

#### 开发者信息
- [ ] Apple Developer 账号（$99/年）
- [ ] 团队 ID（Team ID）

#### App 基础信息
- [ ] Bundle ID（如 com.company.appname）
- [ ] App 名称（30 字符内，全球唯一）
- [ ] 副标题（30 字符内）
- [ ] 分类（主分类 + 次分类）
- [ ] 内容分级（填写问卷）

#### 图标和截图
- [ ] App 图标：1024×1024 PNG（无透明通道）
- [ ] iPhone 截图（至少 3 张）：
  - 6.7 英寸：1290×2796
  - 6.5 英寸：1284×2778
  - 5.5 英寸：1242×2208
- [ ] iPad 截图（如支持）：2048×2732
- [ ] 预览视频（可选）：15-30 秒

#### 文案描述
- [ ] 宣传文本（170 字符内）
- [ ] 描述（4000 字符内）
- [ ] 关键词（100 字符内，逗号分隔）
- [ ] 新功能说明（每个版本）
- [ ] 版权信息

#### URL 链接
- [ ] 隐私政策 URL（**必须**）
- [ ] 技术支持 URL（**必须**）
- [ ] 营销 URL（可选）

#### 审核信息
- [ ] 联系人姓名
- [ ] 联系电话
- [ ] 联系邮箱
- [ ] 演示账号/密码（如需登录）
- [ ] 审核备注（说明特殊功能）
- [ ] 附件（演示视频等）

#### 隐私信息
- [ ] App 隐私标签（在 App Store Connect 填写）
- [ ] 数据收集类型声明
- [ ] 第三方 SDK 隐私声明

#### 构建信息
- [ ] 版本号（如 1.0.0）
- [ ] 构建号（如 1）
- [ ] 最低 iOS 版本要求

---

### 七、TestFlight 详细准备资料

#### 1. 账号准备

| 项目 | 说明 | 获取方式 |
|------|------|----------|
| **Apple Developer 账号** | $99/年 | https://developer.apple.com/programs/enroll/ |
| **Apple ID** | 用于登录 | 已有或新注册 |
| **App Store Connect 账号** | 与开发者账号关联 | 自动关联 |

---

#### 2. Xcode 项目配置

| 项目 | 说明 | 位置 |
|------|------|------|
| **Bundle ID** | 唯一标识符 | Xcode → Target → General → Bundle Identifier |
| **Team** | 开发者团队 | Xcode → Target → Signing & Capabilities → Team |
| **Version** | 版本号（如 1.0.0） | Xcode → Target → General → Version |
| **Build** | 构建号（如 1） | Xcode → Target → General → Build |
| **Deployment Target** | 最低 iOS 版本 | Xcode → Target → General → Minimum Deployments |

**签名配置：**
```
Signing & Capabilities:
  ☑️ Automatically manage signing
  Team: Your Team Name
  Bundle Identifier: com.yourcompany.appname
```

---

#### 3. Info.plist 权限说明（必须）

你的 App 使用了摄像头，必须添加以下权限说明：

```xml
<key>NSCameraUsageDescription</key>
<string>用于视频推流和远程监控</string>

<key>NSMicrophoneUsageDescription</key>
<string>用于音频采集（如需要）</string>
```

**⚠️ 权限说明必须具体说明用途，否则会被拒！**

---

#### 4. App Store Connect 创建 App

**步骤：**
1. 登录 https://appstoreconnect.apple.com
2. 点击「我的 App」→「+」→「新建 App」
3. 填写以下信息：

| 字段 | 说明 | 示例 |
|------|------|------|
| **平台** | 选择 iOS | iOS |
| **App 名称** | 30 字符内 | 爱棋牌监控 |
| **主要语言** | 默认语言 | 简体中文 |
| **Bundle ID** | 与 Xcode 一致 | com.yourcompany.appname |
| **SKU** | 唯一标识（自定义） | aiqipai_monitor_001 |
| **用户访问权限** | 完全访问 | 完全访问权限 |

---

#### 5. TestFlight 内部测试（无需审核）

**适用场景：** 内部团队快速测试

**测试人数：** 最多 100 人

**所需资料：**
- [x] App Store Connect 中创建的 App
- [x] Xcode 上传的构建版本
- [x] 测试员的 Apple ID 邮箱

**上传步骤：**
1. Xcode → Product → Archive
2. Archive 成功后 → Distribute App
3. 选择 **App Store Connect** → Upload
4. 等待处理（5-30 分钟）
5. App Store Connect → TestFlight → 内部测试 → 添加测试员

**邀请测试员：**
1. App Store Connect → 用户和访问权限 → 添加用户
2. 选择角色「App 管理」或「开发者」
3. 分配到对应 App
4. 用户收到邮件，接受邀请
5. TestFlight → 内部测试 → 添加测试员

---

#### 6. TestFlight 外部测试（需要轻度审核）

**适用场景：** 公开测试、大规模测试

**测试人数：** 最多 10000 人

**所需资料：**

| 项目 | 是否必须 | 说明 |
|------|----------|------|
| **App 图标** | ✅ | 1024×1024 PNG |
| **测试详情** | ✅ | 描述本次测试内容 |
| **反馈邮箱** | ✅ | 接收用户反馈 |
| **营销 URL** | ❌ | 可选 |
| **隐私政策 URL** | ✅ | 必须有效可访问 |
| **登录信息** | ✅（如需登录） | 演示账号密码 |

**测试详情示例：**
```
测试内容：
本次更新包含以下功能：
1. 视频推流功能测试
2. 远程控制功能测试
3. 画质切换测试

测试注意事项：
- 请确保网络畅通
- 测试完成后请在 TestFlight 中提交反馈

已知问题：
- 暂无
```

**审核时间：** 通常 24-48 小时

**审核重点：**
- App 是否崩溃
- 基本功能是否正常
- 权限使用是否合理

---

#### 7. 上传构建版本详细步骤

**方式一：Xcode 直接上传**

```bash
# 1. 选择 Any iOS Device (arm64) 作为目标设备
# 2. Product → Archive
# 3. 等待 Archive 完成
# 4. Window → Organizer → 选择最新 Archive
# 5. Distribute App → App Store Connect → Upload
# 6. 勾选选项（保持默认）→ Next → Upload
```

**方式二：命令行上传**

```bash
# 1. 创建 Archive
xcodebuild archive \
  -workspace YourApp.xcworkspace \
  -scheme YourApp \
  -archivePath build/YourApp.xcarchive

# 2. 导出 IPA
xcodebuild -exportArchive \
  -archivePath build/YourApp.xcarchive \
  -exportPath build/ \
  -exportOptionsPlist ExportOptions.plist

# 3. 上传到 App Store Connect
xcrun altool --upload-app \
  -f build/YourApp.ipa \
  -t ios \
  -u your@email.com \
  -p your-app-specific-password
```

**ExportOptions.plist（App Store）：**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
```

---

#### 8. TestFlight 常见问题

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| 上传后一直处理中 | 正常，需等待 | 5-30 分钟 |
| 构建版本不可用 | 缺少导出合规信息 | 在 App Store Connect 填写加密合规信息 |
| 测试员收不到邀请 | 邮箱错误/垃圾箱 | 检查邮箱，查看垃圾邮件 |
| 外部测试审核被拒 | 崩溃/权限问题 | 根据拒绝原因修复 |
| 构建版本号重复 | Build 号必须递增 | 增加 Build 号 |

---

#### 9. 加密合规信息（首次上传必填）

上传后需要在 App Store Connect 回答加密问题：

**问题：** 您的 App 是否使用加密？

**回答指南：**
- 如果只使用 HTTPS（标准网络请求）→ 选择「是，但仅使用 iOS 标准加密」
- 如果使用自定义加密算法 → 需要额外申报

**你的 App 情况：**
- WebRTC 使用 DTLS/SRTP 加密（属于标准加密）
- 选择「是，但仅使用 iOS 标准加密或第三方库的加密」

---

#### 10. TestFlight 测试完整流程图

```
1. Apple Developer 账号 ($99/年)
         ↓
2. Xcode 配置签名 (Bundle ID + Team)
         ↓
3. App Store Connect 创建 App
         ↓
4. Xcode Archive → Upload
         ↓
5. 等待处理 (5-30分钟)
         ↓
6. 填写加密合规信息
         ↓
┌────────────────────────────────────┐
│                                    │
│  内部测试          外部测试        │
│  (无需审核)        (需要审核)       │
│      ↓                ↓            │
│  添加测试员      填写测试详情       │
│  (100人)         (10000人)         │
│      ↓                ↓            │
│  发送邀请        等待审核(1-2天)    │
│      ↓                ↓            │
│  测试员下载      审核通过后邀请     │
│  TestFlight         测试员         │
│                                    │
└────────────────────────────────────┘
```

---

#### 11. TestFlight 清单（Checklist）

**上传前：**
- [ ] Apple Developer 账号已激活
- [ ] Xcode 签名配置正确
- [ ] Bundle ID 与 App Store Connect 一致
- [ ] Version 和 Build 号正确
- [ ] Info.plist 权限说明已添加
- [ ] 代码无崩溃 Bug

**上传后：**
- [ ] 等待处理完成
- [ ] 填写加密合规信息
- [ ] 添加测试员（内部测试）
- [ ] 填写测试详情（外部测试）
- [ ] 等待审核（外部测试）
- [ ] 通知测试员下载

---

### 八、第三方分发平台（蒲公英等）所需资料

| 项目 | 说明 |
|------|------|
| IPA 安装包 | 用 Ad-Hoc 或企业证书签名 |
| UDID | Ad-Hoc 需要测试设备的 UDID |
| 应用名称 | 自定义 |
| 应用图标 | 可选 |
| 应用描述 | 可选 |

**Ad-Hoc 分发限制：**
- 最多 100 台设备
- 需要每台设备的 UDID 加入开发者账号
- 证书有效期 1 年

---

### 九、隐私政策模板要点

隐私政策 URL 必须包含以下内容：

1. **收集的信息类型**
   - 设备信息（型号、系统版本）
   - 摄像头/麦克风数据
   - 网络信息

2. **信息使用方式**
   - 用于视频推流
   - 用于远程控制

3. **信息存储和保护**
   - 本地存储
   - 加密传输

4. **第三方服务**
   - 列出使用的第三方 SDK

5. **用户权利**
   - 删除账号
   - 数据导出

6. **联系方式**
   - 客服邮箱

---

### 十、不同场景推荐方案

| 场景 | 推荐方案 | 资质要求 |
|------|----------|----------|
| 内部测试（<10人） | 蒲公英 + Ad-Hoc | 个人开发者账号 |
| 公开测试（<100人） | TestFlight 内部测试 | 个人/公司开发者账号 |
| 大规模测试（<10000人） | TestFlight 外部测试 | 个人/公司开发者账号 |
| 正式上架 | App Store | 个人/公司开发者账号 |
| 企业内部使用 | 企业签名 | 企业开发者账号 |
| 灰色分发 | 超级签名/企业签 | 找第三方（有风险） |

---

*最后更新：2024年12月*

