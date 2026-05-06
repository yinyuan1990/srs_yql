# iOS 一机一码 Keychain 属性对比

## 问题背景

两台 iPhone 通过"数据移机"（iCloud备份恢复/iTunes备份恢复/iPhone迁移助手）功能，会将 Keychain 数据一起复制到新手机，导致两台设备拥有**相同的设备ID**，"一机一码"失效。

---

## 两种方案对比

### 方案对比表

| 对比项 | ❌ 旧方案 (AfterFirstUnlock) | ✅ 新方案 (ThisDeviceOnly) |
|--------|---------------------------|--------------------------|
| **属性** | `kSecAttrAccessibleAfterFirstUnlock` | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |
| **卸载重装** | ✅ 保留 | ✅ 保留 |
| **iCloud 备份恢复** | ❌ **会被复制到新设备** | ✅ **不会被复制** |
| **iTunes 备份恢复** | ❌ **会被复制到新设备** | ✅ **不会被复制** |
| **iPhone 迁移助手** | ❌ **会被复制到新设备** | ✅ **不会被复制** |
| **恢复出厂设置** | ❌ 数据丢失 | ❌ 数据丢失 |
| **锁屏时可用** | ✅ 首次解锁后始终可用 | ✅ 首次解锁后始终可用 |
| **后台可用** | ✅ 可用 | ✅ 可用 |
| **老用户影响** | — | ✅ 自动升级，设备ID不变 |

---

## 详细说明

### ❌ 旧方案：kSecAttrAccessibleAfterFirstUnlock

```swift
kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
```

- 设备首次解锁后始终可访问
- Keychain 数据**包含在加密备份中**
- iCloud/iTunes 备份恢复到新设备时，**数据会被迁移**
- **后果**：两台手机拥有相同的设备ID，一机一码被绕过

### ✅ 新方案：kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

```swift
kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
```

- 设备首次解锁后始终可访问（与旧方案相同）
- Keychain 数据**绑定当前设备的硬件密钥**
- iCloud/iTunes 备份时，**ThisDeviceOnly 的数据被自动排除**
- **结果**：新手机恢复备份后没有设备ID，必须重新注册

---

## 升级策略（兼容老用户）

老用户已经有用旧属性保存的设备ID。直接改代码会导致老用户设备ID不变但仍然可被迁移。

### 解决：自动属性升级

```
App启动 → 读取 Keychain
    ↓
读到设备ID？
    ↓ 是
检查属性是否已是 ThisDeviceOnly
    ↓ 否
删除旧 Keychain 项 → 用 ThisDeviceOnly 重新保存（值不变）
    ↓
设备ID 不变，属性已升级
```

### 代码实现

```swift
// 属性升级函数
private func upgradeToThisDeviceOnly(_ value: String) {
    // 1. 读取当前属性
    // 2. 如果已经是 ThisDeviceOnly → 跳过
    // 3. 否则：删除旧的 → 用 ThisDeviceOnly 重新保存
    // 4. 设备ID 值完全不变
}
```

### 升级后各场景表现

| 用户类型 | 设备ID变化 | 说明 |
|---------|-----------|------|
| 老用户（正常使用） | ❌ **不变** | 自动升级属性，值不变 |
| 老用户（已移机） | ⚠️ 两台都有旧ID | 升级后各自变为不可迁移，阻止后续移机 |
| 新用户 | — | 直接用 ThisDeviceOnly 保存 |
| 新手机（移机后） | ✅ **没有ID** | 必须重新注册 |

---

## Android 对比

| 对比项 | iOS (Keychain) | Android (ANDROID_ID) |
|--------|---------------|---------------------|
| **存储方式** | Keychain + ThisDeviceOnly | 系统 Settings.Secure |
| **卸载重装** | ✅ 保留 | ✅ 保留 |
| **数据移机** | ✅ ThisDeviceOnly 阻止 | ✅ ANDROID_ID 绑定硬件，天然防移机 |
| **恢复出厂** | ❌ 丢失 | ❌ ANDROID_ID 重置 |
| **需要权限** | ❌ 不需要 | ❌ 不需要 |

**Android 天然防移机**：`ANDROID_ID` 是设备硬件级别标识符，克隆/移机到新设备后 `ANDROID_ID` 不同，生成的设备ID自然不同。

---

## Apple 官方文档参考

> **kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly**
> 
> The data in the keychain item cannot be accessed after a restart until the device has been unlocked once by the user.
> After the first unlock, the data remains accessible until the next restart. This is recommended for items that need to be accessed by background applications.
> **Items with this attribute do not migrate to a new device.** Thus, after restoring from a backup of a different device, these items will not be present.

来源: [Apple Keychain Services - kSecAttrAccessible](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)

---

## 变更记录

| 日期 | 变更 | 影响 |
|------|------|------|
| 2026-02-05 | `AfterFirstUnlock` → `AfterFirstUnlockThisDeviceOnly` | 阻止数据移机复制设备ID |
| 2026-02-05 | 新增自动属性升级逻辑 | 老用户无感知升级，设备ID不变 |
