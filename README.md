# 自适应帧率控制模块 v10

## 功能特性

- **预测式降帧**：通过趋势分析，提前 1-2 秒预测网络恶化
- **快降慢升**：降帧大幅度（四档跳），升帧小幅度（10%/次）
- **WebSocket 信令**：通过现有 WebSocket 连接发送 `set_fps` 指令
- **档位感知**：根据【会员等级】+【当前档位】自动计算可用帧率范围
- **低帧率直通**：帧率 < 15fps 时跳过缓冲，直接渲染（v9.3）
- **自动关键帧请求**：低帧率模式下每秒请求关键帧，防止马赛克
- **PTS 漂移校准**：渲染端仅检测 PTS 漂移，避免阻塞渲染线程（v10）
- **智能丢帧策略**：优先丢最旧 P 帧，保护 I 帧（v10）

## 文件结构

```
adaptive_fps/
├── adaptive_fps_types.h       # 数据结构定义
├── network_metrics.h/.cpp     # 网络指标采集
├── network_trend_predictor.h/.cpp  # 趋势预测器（核心）
├── adaptive_fps_decider.h/.cpp     # 决策器（核心）
├── adaptive_fps_controller.h/.cpp  # 总控制器
├── example_usage.cpp          # 使用示例
├── CMakeLists.txt             # CMake 构建文件
└── README.md                  # 本文件
```

## 快速开始

### 1. 集成到你的项目

```cpp
#include "adaptive_fps_controller.h"

// 创建控制器
auto controller = std::make_unique<adaptive::AdaptiveFpsController>(
    60,  // 原始帧率
    [](const std::string& json) {
        return websocket->send(json);  // 你的 WebSocket 发送
    }
);

// 启动
controller->start();

// 每帧调用
controller->onFrameArrived(timestampMs);

// 定期调用
controller->updateQueueDepth(depth);
controller->updateRtcpStats(lost, received, rttMs);
```

### 2. 接入点

| 方法 | 调用位置 | 频率 |
|------|---------|------|
| `onFrameArrived(ts)` | 解码后/渲染前 | 每帧 |
| `updateQueueDepth(depth)` | 缓冲队列变化时 | 每帧或定期 |
| `updateRtcpStats(...)` | RTCP 回调 | 1-5秒 |

## 信令格式

```json
{
    "cmd": "set_fps",
    "fps": 30,
    "urgency": "high",
    "reason": "predict_warning",
    "bitrate": 5000000,
    "timestamp": 1706745600000
}
```

### urgency 紧急度

| 值 | 含义 | iOS 响应 |
|----|------|---------|
| `critical` | 紧急 | 立即执行，≤50ms |
| `high` | 高优先级 | 立即执行，≤200ms |
| `normal` | 正常 | 可短暂过渡 |
| `low` | 低优先级 | 平滑过渡（升帧） |

## 决策逻辑

### v9.3 低帧率直通模式（新增）

当 **帧率 EMA < 15fps** 时：
- 跳过所有缓冲逻辑
- 直接渲染收到的帧（最低延迟）
- 清空队列积压（只保留 1 帧）
- 每秒请求一次关键帧（防马赛克）

### 降帧（满足任一即降）

1. **队列 ≤ 1帧** → `critical`, 直接降到最低档
2. **预测风险分 > 0.7** → `high`, 降两档
3. **预测风险分 > 0.5** → `high`, 降一档
4. **水位 < 35%** → `normal`, 按比例降帧
5. **延迟 > 500ms** → `normal`, 按比例降帧

### 升帧（全部满足）

- 风险分 < 0.2
- 抖动趋势 < 1.0（稳定）
- 到达率斜率 > -2%/s（稳定）
- 延迟在 200-500ms（正常范围）
- 水位 ≥ 50%
- 持续 ≥ 1秒

每次升 10%，不超过档位上限。

### 四档阶梯（服务器格式）

| 档位 | 服务器fps | 实际fps |
|------|----------|---------|
| 最高 | 240 | 60 fps |
| 高 | 180 | 45 fps |
| 中 | 120 | 30 fps |
| 最低 | 60 | 15 fps |

### 档位限制

| 当前档位 | 会员等级 | 可用档位 |
|---------|---------|---------|
| 4K | 任意 | [120, 60] |
| 其他 | 等级1 | [120, 60] |
| 其他 | 等级2/3 | [180, 120, 60] |
| 其他 | 等级4/试用 | [240, 180, 120, 60] |

## 配置参数

```cpp
adaptive::AdaptiveConfig config;

// 降帧阈值
config.arrivalRateDropThreshold = 0.85;   // 到达率 < 85%
config.jitterRatioDropThreshold = 0.30;   // 抖动 > 30%
config.queueDepthDropThreshold = 3;       // 队列 < 3帧

// 趋势预测阈值
config.jitterTrendThreshold = 2.0;        // 抖动变化率 > 2ms/s
config.arrivalSlopeThreshold = -0.05;     // 到达率斜率 < -5%/s
config.queueDropSpeedThreshold = 3;       // 队列下降 >= 3帧/s
config.riskScoreThreshold = 0.5;          // 风险分 > 0.5

// 升帧配置
config.upgradeStep = 5;                   // 每次升 5fps
config.stableTimeMs = 1000;               // 稳定 1 秒后升帧
```

## 编译

```bash
mkdir build && cd build
cmake ..
cmake --build .
```

## 防马赛克措施

### GStreamer 层面（v10 超低延迟配置）

| 配置项 | v10 值 | 旧值 | 作用 |
|-------|--------|------|------|
| jitterbuffer latency | **100ms** | 350ms | 🔥 超低延迟核心 |
| drop-on-latency | **TRUE** | FALSE | 🔥 超过延迟立即丢帧 |
| do-retransmission | **FALSE** | TRUE | 🔥 禁用重传（避免延迟爆炸）|
| do-lost | FALSE | FALSE | 不发送丢包事件 |
| mode | 0 (none) | 0 | 纯透传，不做时钟同步 |
| wait-for-keyframe | TRUE | TRUE | 等待关键帧才开始解包 |
| request-keyframe | TRUE | TRUE | 启用关键帧请求 |
| request-keyframe-on-discont | TRUE | - | 🔥 发现不连续时立即请求关键帧 |

### 应用层队列（v10 微队列）

| 配置项 | v10 值 | 旧值 | 作用 |
|-------|--------|------|------|
| QUEUE_ABSOLUTE_MAX | **5** | 90 | 🔥 微队列（可调：2/5/10）|
| appsink max-buffers | **5** | 30 | 与应用层队列一致 |
| queueDepay max-size-buffers | **5** | 30 | 解码前队列 |
| queueDepay max-size-time | **200ms** | 600ms | 时间限制 |
| leaky | 2 | 2 | 丢弃老帧，保持最新帧 |

## 超低延迟端到端参数规范（SRS + iOS + GStreamer）

> 目标：**典型 150ms**，弱网 **0–500ms** 可容忍；网络波动时自动拉高延迟平滑播放。  
> 约束：**不丢 I 帧**，P 帧仅在队列溢出时丢 1 帧；播放端帧率手动可调 1–60fps。

### 1) iOS 推流端（WebRTC）

**帧率与码率（CBR）**

| 分辨率/帧率 | 建议码率 |
|-----------|----------|
| 1080p30 | 4.5 Mbps |
| 1080p60 | 7–9 Mbps |
| 720p30 | 2.5–3.5 Mbps |
| 720p60 | 4–5.5 Mbps |

**帧率档位**

- 固定档位：60 / 45 / 30 / 15 fps  
- 最低降帧：**5 fps**

**关键帧与反馈**

- GOP：**1–2 秒**
- PLI：收到立即插 I 帧
- 禁止编码器重写采集 PTS（透传 PTS）

### 2) SRS 服务器（WebRTC 中转）

**关键配置**

- ICE 必须包含公网 IP
- `rtc.twcc = on`
- `rtc.remb = on`
- `rtc.gop_cache = on`
- `rtc.jitterbuffer = 0`（不在服务端做抖动缓冲）
- `rtc.min_nack_interval = 0`（不启用重传）

### 3) PC 端 GStreamer（播放）

**GStreamer jitterbuffer**

- `latency = 100ms`（默认）
- 弱网自动升到 `200–350ms`
- `drop-on-latency = TRUE`
- `do-retransmission = FALSE`

**应用层队列（微队列）**

- 默认：`QUEUE_ABSOLUTE_MAX = 5`
- 弱网：`QUEUE_ABSOLUTE_MAX = 8–10`

**目标延迟参考**

| 网络状态 | jitterbuffer | 应用层队列 | 预期总延迟 |
|---------|--------------|-----------|-----------|
| 正常 | 100ms | 5 帧 | 200–300ms |
| 弱网 | 200–350ms | 8–10 帧 | 350–500ms |

**渲染策略（平滑）**

- 定时渲染 + PTS 漂移校准（不阻塞渲染线程）
- PTS 漂移 > 200ms → 重置基准

**PTS 漂移校准实现（v10）**

```cpp
// 1. 首帧记录基准
if (m_startPts < 0) {
    m_startPts = ptsMs;           // 首帧 PTS
    m_startSystemTime = nowMs;    // 首帧系统时间
}

// 2. 计算漂移量
qint64 expectedPts = (nowMs - m_startSystemTime) + m_startPts - PTS_OFFSET_MS;
qint64 drift = ptsMs - expectedPts;

// 3. 大漂移重置基准（网络恢复或严重延迟）
if (qAbs(drift) > 200) {
    m_startPts = ptsMs;
    m_startSystemTime = nowMs;
}
// 小漂移由播放速度调整机制自动吸收
```

**核心常量**

```cpp
static constexpr int GST_JITTER_LATENCY = 100;   // jitterbuffer 延迟
static constexpr int PTS_OFFSET_MS = 80;         // 目标偏移量
static constexpr int QUEUE_ABSOLUTE_MAX = 5;     // 应用层队列上限
```

**智能丢帧策略（v10）**

1. 优先丢弃**最旧 P 帧**  
2. **绝不丢 I 帧**  
3. 队列满且新帧为 I 帧 → 丢 I 帧前最近 1 个 P 帧  
4. 每次只丢 1 帧，避免画面跳变

**帧类型检测（GStreamer）**

```cpp
// I帧/P帧判断：GST_BUFFER_FLAG_DELTA_UNIT
// 设置了 DELTA_UNIT = P帧（非关键帧）
// 未设置 DELTA_UNIT = I帧（关键帧）
GstBuffer *buffer = gst_sample_get_buffer(sample);
bool isKeyframe = !GST_BUFFER_FLAG_IS_SET(buffer, GST_BUFFER_FLAG_DELTA_UNIT);
```

**首帧即播策略（v10）**

- 有 1 帧即开始播放（不等待缓冲）
- 延迟主要由 jitterbuffer(100ms) 控制
- 目标延迟：150–300ms  

### 4) 帧率与降帧阈值（推流端自动）

**降帧触发（任一满足）**

- 丢包率 > 8% 持续 3 秒  
- RTT > 200ms 持续 3 秒  
- 播放队列 > 8 帧  

**升帧触发（全部满足）**

- 丢包率 < 2% 持续 10 秒  
- RTT < 120ms 持续 10 秒  
- 播放队列 < 5 帧  

**最低帧率**：**5 fps**

### 5) 关键帧/PLI 触发（底层必须清楚）

播放端检测到以下情况必须发送 PLI：

- `GST_BUFFER_FLAG_CORRUPTED`
- `GST_BUFFER_FLAG_DISCONT`
- 队列 = 0（断帧）
- 降帧后 300/500/1000/1500ms 触发一次

### v10 智能丢帧实现（GStreamer）

在 `onNewSample` 回调中入队前：

```cpp
// 检测新帧是否是关键帧（I帧）
bool isNewFrameKeyframe = false;
GstBuffer *newBuffer = gst_sample_get_buffer(sample);
if (newBuffer) {
    isNewFrameKeyframe = !GST_BUFFER_FLAG_IS_SET(newBuffer, GST_BUFFER_FLAG_DELTA_UNIT);
}

// 队列满时智能丢帧
if (m_frameQueue.size() >= QUEUE_ABSOLUTE_MAX) {
    bool dropped = false;
    
    // 策略1：从队列头部找最旧的P帧丢弃
    for (int i = 0; i < m_frameQueue.size(); i++) {
        GstSample *oldSample = m_frameQueue.at(i);
        GstBuffer *oldBuffer = gst_sample_get_buffer(oldSample);
        bool isOldKeyframe = !GST_BUFFER_FLAG_IS_SET(oldBuffer, GST_BUFFER_FLAG_DELTA_UNIT);
        if (!isOldKeyframe) {
            // 找到P帧，丢弃它
            m_frameQueue.removeAt(i);
            gst_sample_unref(oldSample);
            dropped = true;
            break;  // 每次只丢1帧
        }
    }
    
    // 策略2：全是I帧的极端情况
    if (!dropped) {
        if (isNewFrameKeyframe) {
            // 新帧是I帧，丢弃最旧I帧
            GstSample *oldest = m_frameQueue.takeFirst();
            gst_sample_unref(oldest);
        } else {
            // 新帧是P帧，队列全是I帧，丢弃这个P帧
            gst_sample_unref(sample);
            return GST_FLOW_OK;
        }
    }
}

// 入队
m_frameQueue.append(sample);
```

### v9.3 帧损坏检测

在 `onNewSample` 回调中检测 buffer flags：

```cpp
GstBufferFlags flags = GST_BUFFER_FLAGS(buffer);

// GST_BUFFER_FLAG_CORRUPTED (512) - 数据损坏
// GST_BUFFER_FLAG_DISCONT (4) - 不连续（可能丢帧）
bool isCorrupted = (flags & GST_BUFFER_FLAG_CORRUPTED) != 0;
bool isDiscont = (flags & GST_BUFFER_FLAG_DISCONT) != 0;

if (isCorrupted) {
    // 丢弃损坏帧，请求关键帧
    gst_sample_unref(sample);
    requestKeyFrame();
    return GST_FLOW_OK;
}

if (isDiscont) {
    // 不连续帧，请求关键帧（但继续播放）
    requestKeyFrame();
}
```

日志：
```
🔴 检测到损坏帧! flags=512 丢弃并请求关键帧
⚠️ 检测到不连续帧 flags=4 请求关键帧
⚠️ 累计检测到 10 个损坏帧
```

### 应用层面

1. **帧损坏检测**：检测 buffer flags，丢弃损坏帧（v9.3 新增）
2. **低帧率自动请求关键帧**：帧率 < 15fps 时每秒请求一次
3. **队列见底请求关键帧**：队列 = 0 时立即请求
4. **档位切换请求关键帧**：切换后 300ms/500ms/1000ms/1500ms 各请求一次

## v10 可调方案（gstplayer.h）

根据实际测试选择：

```cpp
// 方案A（极致低延迟）：总延迟 ~150ms，可能不平滑
static constexpr int QUEUE_ABSOLUTE_MAX = 2;

// 方案B（平衡方案）：总延迟 ~250ms，较平滑 ⭐推荐
static constexpr int QUEUE_ABSOLUTE_MAX = 5;

// 方案C（平滑优先）：总延迟 ~400ms，很平滑
static constexpr int QUEUE_ABSOLUTE_MAX = 10;
```

## 完整参数总表（精准数值）

| 环节 | 参数 | v10 值 | 说明 |
|------|------|--------|------|
| **iOS 推流** | FPS 档位 | 60/45/30/15 | 四档阶梯 |
| | 最低 FPS | 5 | 极端弱网 |
| | GOP | 1–2s | 关键帧间隔 |
| | 码率（1080p30） | 4.5 Mbps | CBR |
| **SRS 服务器** | nack | OFF | 禁用重传 |
| | FEC | ON | 前向纠错 |
| | gop_cache | ON | 关键帧缓存 |
| **PC GStreamer** | jitterbuffer | **100ms** | 🔥超低延迟 |
| | drop-on-latency | **TRUE** | 超时丢帧 |
| | do-retransmission | **FALSE** | 禁用重传 |
| | QUEUE_ABSOLUTE_MAX | **5** | 应用层队列 |
| | appsink max-buffers | **5** | 内部缓冲 |
| | PTS 重校准阈值 | 200ms | 漂移检测 |
| **降帧阈值** | 丢包率 | >8% 持续 3s | 触发降帧 |
| | RTT | >200ms 持续 3s | 触发降帧 |
| | 队列深度 | >8 帧 | 立即降帧 |
| **升帧阈值** | 丢包率 | <2% 持续 10s | 可以升帧 |
| | RTT | <120ms 持续 10s | 可以升帧 |
| **PLI 触发** | CORRUPTED | 立即 | 损坏帧 |
| | DISCONT | 立即 | 不连续帧 |
| | 队列空 | 立即 | 断帧 |

## 日志格式

```
📉 v9.3降帧[critical] | 🚨紧急:队列=1帧 | 60fps→15fps | 队列=1/6帧 延迟=33ms
📉 v9.3降帧[high] | ⚡预测:风险=65% 抖动趋势=3.5ms/s | 60fps→30fps
📈 v9.3升帧 | 延迟=300ms 水位=65% 风险=12% | 30fps→33fps(+3,10%)
🔴 v9.3低帧率直通 | 收=10fps EMA=12fps | 跳过缓冲直接渲染
🟢 帧率恢复 16fps >= 15fps | 恢复缓冲模式
📊 v9.1[✅正常] | 收=30fps 到达=30fps | 队列=6帧(最佳6,范围4-14) | 速度=100% | 延迟=545ms
```

## 日志

```cpp
controller->setLogCallback([](int level, const std::string& msg) {
    // level: 0=debug, 1=info, 2=warn, 3=error
    std::cout << "[" << level << "] " << msg << std::endl;
});
```
