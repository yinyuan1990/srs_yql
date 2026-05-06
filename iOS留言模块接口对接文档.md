# iOS留言模块接口对接文档

## 概述

本文档描述iOS端留言功能的接口对接规范。用户可以提交留言，查看留言列表和回复详情。

**基础URL**: `http://your-server:port/api/message`

---

## 1. 获取留言配置

获取留言字数限制等配置信息。

### 请求

```
GET /api/message/config
```

### 请求参数

无

### 响应

```json
{
  "success": true,
  "data": {
    "maxLength": 200
  }
}
```

### 响应字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| success | Boolean | 请求是否成功 |
| data.maxLength | Integer | 留言最大字数限制 |

### 示例

```swift
// Swift 示例
func getMessageConfig() {
    let url = "\(baseURL)/api/message/config"
    // GET 请求
}
```

---

## 2. 提交留言

用户提交新的留言。

### 请求

```
POST /api/message/submit
Content-Type: application/json
```

### 请求参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| userId | Long | 是 | 用户ID |
| content | String | 是 | 留言内容（不超过配置的最大字数） |

### 请求示例

```json
{
  "userId": 12345,
  "content": "您好，我想咨询一下会员升级的问题..."
}
```

### 响应

**成功响应:**
```json
{
  "success": true,
  "message": "留言提交成功",
  "data": {
    "id": 1,
    "status": 0,
    "statusName": "待回复",
    "createdAt": "2026-01-25T10:30:00"
  }
}
```

**失败响应:**
```json
{
  "success": false,
  "message": "留言内容不能超过200字"
}
```

### 响应字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| success | Boolean | 提交是否成功 |
| message | String | 提示信息 |
| data.id | Long | 留言ID |
| data.status | Integer | 状态码（0=待回复, 1=已回复, 2=已关闭） |
| data.statusName | String | 状态名称 |
| data.createdAt | String | 创建时间（ISO 8601格式） |

### 示例

```swift
// Swift 示例
func submitMessage(userId: Int, content: String) {
    let url = "\(baseURL)/api/message/submit"
    let params: [String: Any] = [
        "userId": userId,
        "content": content
    ]
    // POST 请求
}
```

---

## 3. 获取用户留言列表

获取当前用户的留言列表（分页）。

### 请求

```
GET /api/message/list?userId={userId}&page={page}&size={size}
```

### 请求参数

| 参数 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| userId | Long | 是 | - | 用户ID |
| page | Integer | 否 | 0 | 页码（从0开始） |
| size | Integer | 否 | 10 | 每页条数 |

### 响应

```json
{
  "success": true,
  "data": {
    "content": [
      {
        "id": 1,
        "content": "您好，我想咨询一下会员升级的问题...",
        "status": 1,
        "statusName": "已回复",
        "replyContent": "您好，会员升级可以通过...",
        "replyAdminName": "客服小王",
        "replyAt": "2026-01-25T11:00:00",
        "createdAt": "2026-01-25T10:30:00"
      },
      {
        "id": 2,
        "content": "请问如何修改密码？",
        "status": 0,
        "statusName": "待回复",
        "replyContent": null,
        "replyAdminName": null,
        "replyAt": null,
        "createdAt": "2026-01-25T09:00:00"
      }
    ],
    "totalElements": 15,
    "totalPages": 2,
    "currentPage": 0
  }
}
```

### 响应字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| content | Array | 留言列表 |
| content[].id | Long | 留言ID |
| content[].content | String | 留言内容 |
| content[].status | Integer | 状态码 |
| content[].statusName | String | 状态名称 |
| content[].replyContent | String | 回复内容（无回复时为null） |
| content[].replyAdminName | String | 回复人名称（无回复时为null） |
| content[].replyAt | String | 回复时间（无回复时为null） |
| content[].createdAt | String | 留言时间 |
| totalElements | Integer | 总条数 |
| totalPages | Integer | 总页数 |
| currentPage | Integer | 当前页码 |

### 示例

```swift
// Swift 示例
func getMessageList(userId: Int, page: Int = 0, size: Int = 10) {
    let url = "\(baseURL)/api/message/list?userId=\(userId)&page=\(page)&size=\(size)"
    // GET 请求
}
```

---

## 4. 获取留言详情

获取单条留言的详细信息。

### 请求

```
GET /api/message/detail?id={messageId}
```

### 请求参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| id | Long | 是 | 留言ID |

### 响应

**成功响应:**
```json
{
  "success": true,
  "data": {
    "id": 1,
    "content": "您好，我想咨询一下会员升级的问题...",
    "status": 1,
    "statusName": "已回复",
    "replyContent": "您好，会员升级可以通过购买对应等级的升级码来完成...",
    "replyAdminName": "客服小王",
    "replyAt": "2026-01-25T11:00:00",
    "createdAt": "2026-01-25T10:30:00"
  }
}
```

**失败响应:**
```json
{
  "success": false,
  "message": "留言不存在"
}
```

### 示例

```swift
// Swift 示例
func getMessageDetail(messageId: Int) {
    let url = "\(baseURL)/api/message/detail?id=\(messageId)"
    // GET 请求
}
```

---

## 状态码说明

| status | statusName | 说明 |
|--------|------------|------|
| 0 | 待回复 | 用户已提交，等待管理员回复 |
| 1 | 已回复 | 管理员已回复 |
| 2 | 已关闭 | 留言已关闭，不再处理 |

---

## 错误处理

所有接口在发生错误时返回以下格式：

```json
{
  "success": false,
  "message": "错误描述信息"
}
```

### 常见错误

| 错误信息 | 说明 |
|---------|------|
| 用户不存在 | userId 无效 |
| 留言内容不能为空 | content 为空或只有空格 |
| 留言内容不能超过XXX字 | 超出字数限制 |
| 留言不存在 | 查询的留言ID不存在 |

---

## iOS代码示例

### 数据模型

```swift
// 留言配置
struct MessageConfig: Codable {
    let maxLength: Int
}

// 留言
struct Message: Codable {
    let id: Int
    let content: String
    let status: Int
    let statusName: String
    let replyContent: String?
    let replyAdminName: String?
    let replyAt: String?
    let createdAt: String
}

// 留言列表响应
struct MessageListResponse: Codable {
    let content: [Message]
    let totalElements: Int
    let totalPages: Int
    let currentPage: Int
}

// 通用响应
struct APIResponse<T: Codable>: Codable {
    let success: Bool
    let message: String?
    let data: T?
}
```

### 网络请求封装

```swift
class MessageService {
    static let shared = MessageService()
    private let baseURL = "http://your-server:port"
    
    // 获取配置
    func getConfig(completion: @escaping (Result<MessageConfig, Error>) -> Void) {
        let url = URL(string: "\(baseURL)/api/message/config")!
        URLSession.shared.dataTask(with: url) { data, response, error in
            // 处理响应...
        }.resume()
    }
    
    // 提交留言
    func submitMessage(userId: Int, content: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        let url = URL(string: "\(baseURL)/api/message/submit")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let params: [String: Any] = [
            "userId": userId,
            "content": content
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: params)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            // 处理响应...
        }.resume()
    }
    
    // 获取留言列表
    func getList(userId: Int, page: Int = 0, size: Int = 10, completion: @escaping (Result<MessageListResponse, Error>) -> Void) {
        let url = URL(string: "\(baseURL)/api/message/list?userId=\(userId)&page=\(page)&size=\(size)")!
        URLSession.shared.dataTask(with: url) { data, response, error in
            // 处理响应...
        }.resume()
    }
    
    // 获取留言详情
    func getDetail(messageId: Int, completion: @escaping (Result<Message, Error>) -> Void) {
        let url = URL(string: "\(baseURL)/api/message/detail?id=\(messageId)")!
        URLSession.shared.dataTask(with: url) { data, response, error in
            // 处理响应...
        }.resume()
    }
}
```

---

## UI交互建议

1. **留言入口**: 在设置页或个人中心添加"我的留言"或"联系客服"入口

2. **提交留言页面**:
   - 显示字数限制提示（如"最多200字"）
   - 实时显示已输入字数
   - 提交后显示成功提示并返回列表

3. **留言列表页面**:
   - 用不同颜色/标签区分状态（待回复用橙色，已回复用绿色）
   - 下拉刷新、上拉加载更多
   - 点击进入详情页

4. **留言详情页面**:
   - 清晰展示用户留言和管理员回复
   - 已回复的留言显示回复内容和回复时间

---

## 版本记录

| 版本 | 日期 | 说明 |
|------|------|------|
| 1.0 | 2026-01-25 | 初始版本 |
