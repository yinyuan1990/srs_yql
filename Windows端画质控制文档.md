# Windows 端画质控制对接文档

## 概述

iOS 采集端每秒向 WebSocket 频道 `/topic/device/{deviceId}/config` 发送 `CONFIG_STATE` 消息，包含设备状态和用户激活/试用信息。Windows 端需要根据这些信息控制画质选择功能。

---

## 消息格式

### CONFIG_STATE 消息结构

```json
{
    "type": "CONFIG_STATE",
    "deviceId": "设备ID",
    "timestamp": "2025-12-16T10:30:00Z",
    "state": {
        // ========== 推流状态 ==========
        "networkType": "WiFi",
        "publishStatus": 1,
        "streamKey": "xxx",
        "streamPushIp": "171.80.4.72",
        "kbps": 2500,
        "fps": 60,
        "sendFps": 60,
        "networkQuality": "excellent",
        "packetLoss": 0.0,
        "rtt": 50,
        "deviceType": {
            "os": "iOS 17.0",
            "model": "iPhone15,2"
        },
        "battery": 85,
        
        // ========== 激活/试用信息（Windows端关注）==========
        "trialRequired": true,           // 是否需要试用限制
        "activated": false,              // 是否已激活
        "activationLevel": 0,            // 激活等级 (0=未激活, 1=白银, 2=黄金)
        "activationLevelName": "",       // 等级名称
        "activationExpireAt": "",        // 激活到期时间
        "qualityAccess": [],             // 可用画质列表
        "trialEnded": false,             // 当天试用是否已结束
        "currentStage": 1,               // 当前试用阶段 (1-6)
        "totalStages": 6,                // 总阶段数
        "stageSeconds": 1800,            // 当前阶段总秒数
        "remainingSeconds": 1500,        // 当前阶段剩余秒数
        "usedSeconds": 300               // 当前阶段已用秒数
    }
}
```

---

## 会员等级与画质对应关系

| 等级 | activationLevel | activationLevelName | 可用画质 |
|------|-----------------|---------------------|----------|
| 未激活（试用） | 0 | "" | 标清、高清、超清、4K（全部） |
| 白银会员 | 1 | "白银" | 标清、高清 |
| 黄金会员 | 2 | "黄金" | 标清、高清、超清、4K（全部） |

---

## Windows 端画质控制逻辑

### 判断流程图

```
收到 CONFIG_STATE 消息
         │
         ▼
   activated == true ?
         │
    ┌────┴────┐
   Yes       No
    │         │
    ▼         ▼
【已激活用户】  trialRequired == true ?
根据等级限制         │
画质选择        ┌────┴────┐
               Yes       No
                │         │
                ▼         ▼
          【试用用户】   【无限制用户】
          全部画质可用    全部画质可用
```

### 伪代码实现

```csharp
// C# / Windows 示例
void HandleConfigState(ConfigStateMessage msg) {
    var state = msg.State;
    
    // 已激活用户
    if (state.Activated) {
        switch (state.ActivationLevel) {
            case 1: // 白银
                EnableQualities(new[] { "标清", "高清" });
                DisableQualities(new[] { "超清", "4K" });
                break;
            case 2: // 黄金
                EnableQualities(new[] { "标清", "高清", "超清", "4K" });
                break;
            default:
                EnableAllQualities();
                break;
        }
    }
    // 试用用户（未激活但需要试用限制）
    else if (state.TrialRequired) {
        // 试用期间：全部画质可用
        EnableAllQualities();
        
        // 可选：显示试用剩余时间
        ShowTrialInfo(state.CurrentStage, state.RemainingSeconds);
    }
    // 无限制用户
    else {
        EnableAllQualities();
    }
}
```

---

## 场景详解

### 场景1：试用用户（未激活）

```json
{
    "trialRequired": true,
    "activated": false,
    "activationLevel": 0,
    "activationLevelName": "",
    "qualityAccess": [],
    "trialEnded": false,
    "currentStage": 1,
    "remainingSeconds": 1500
}
```

**Windows 端处理**：
- ✅ **全部4个档位都可用**（标清、高清、超清、4K）
- 可选择显示试用剩余时间
- 可选择显示"激活会员"提示

---

### 场景2：白银会员

```json
{
    "trialRequired": false,
    "activated": true,
    "activationLevel": 1,
    "activationLevelName": "白银",
    "qualityAccess": ["标清", "高清"],
    "activationExpireAt": "2026-12-16T10:30:00"
}
```

**Windows 端处理**：
- ✅ 启用：标清、高清
- ❌ 禁用/灰显：超清、4K
- 可选择显示"升级黄金"提示

---

### 场景3：黄金会员

```json
{
    "trialRequired": false,
    "activated": true,
    "activationLevel": 2,
    "activationLevelName": "黄金",
    "qualityAccess": ["标清", "高清", "超清", "4K"],
    "activationExpireAt": "2026-12-16T10:30:00"
}
```

**Windows 端处理**：
- ✅ 全部画质可用（标清、高清、超清、4K）

---

### 场景4：试用已结束（当天用完）

```json
{
    "trialRequired": true,
    "activated": false,
    "activationLevel": 0,
    "trialEnded": true,
    "currentStage": 6,
    "remainingSeconds": 0
}
```

**Windows 端处理**：
- ⚠️ iOS 端已停止推流并断开 WebSocket
- Windows 端应显示"试用已结束"提示
- 引导用户激活会员

---

## 画质档位定义

| 档位名称 | 代码标识 | 分辨率 | 说明 |
|----------|----------|--------|------|
| 标清 | standard | 640x360 | 基础画质 |
| 高清 | high | 1280x720 | 720P |
| 超清 | ultra | 1920x1080 | 1080P |
| 4K | p4k | 3840x2160 | 4K |

---

## 核心字段速查表

| 字段 | 类型 | 说明 | Windows端用途 |
|------|------|------|---------------|
| `activated` | Boolean | 是否已激活 | 判断是否限制画质 |
| `activationLevel` | Integer | 激活等级 (0/1/2) | 确定可用画质范围 |
| `activationLevelName` | String | 等级名称 | 界面显示 |
| `qualityAccess` | Array | 可用画质列表 | 直接使用此列表控制 |
| `trialRequired` | Boolean | 是否需要试用限制 | 判断用户类型 |
| `trialEnded` | Boolean | 试用是否已结束 | 显示相应提示 |
| `currentStage` | Integer | 当前试用阶段 | 显示试用进度 |
| `remainingSeconds` | Integer | 剩余秒数 | 显示倒计时 |

---

## 推荐实现方式

### 方式一：使用 qualityAccess 数组（推荐）

```csharp
// 如果 qualityAccess 有值，直接使用
if (state.QualityAccess != null && state.QualityAccess.Length > 0) {
    SetAvailableQualities(state.QualityAccess);
}
// 否则根据 activationLevel 判断
else {
    // ...
}
```

### 方式二：使用 activationLevel 判断

```csharp
var availableQualities = state.ActivationLevel switch {
    0 => new[] { "标清", "高清", "超清", "4K" },  // 试用：全部
    1 => new[] { "标清", "高清" },                 // 白银
    2 => new[] { "标清", "高清", "超清", "4K" },  // 黄金：全部
    _ => new[] { "标清", "高清", "超清", "4K" }   // 默认：全部
};
```

---

## 注意事项

1. **试用期全部可用**：未激活用户在试用期间可以体验全部画质
2. **白银限制超清/4K**：白银会员只能使用标清和高清
3. **黄金无限制**：黄金会员可以使用全部画质
4. **优先使用 qualityAccess**：如果后端返回了 `qualityAccess` 数组，直接使用它
5. **消息频率**：CONFIG_STATE 消息每秒发送一次

---

## 版本记录

| 版本 | 日期 | 说明 |
|------|------|------|
| 1.0 | 2025-12-16 | 初始版本 |

