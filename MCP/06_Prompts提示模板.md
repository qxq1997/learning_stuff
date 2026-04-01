# MCP - 第 6 课：MCP 核心能力之三——Prompts（提示模板）

## 学习目标（本节结束后你能做到什么）

1. 理解 Prompts 在 MCP 三大能力中的定位和独特价值
2. 掌握 Prompt 的定义、参数化、多轮消息结构
3. 理解 Prompt 如何嵌入 Resource 内容
4. 知道什么场景下该用 Prompt，什么场景下该用 Tool 或 Resource
5. 能为自己的 MCP Server 设计实用的 Prompt 模板

---

## 一、Prompts 的定位：三大能力中最容易被忽视的

先看三大能力的全景图：

```
MCP Server 的三大能力

┌─────────────────────────────────────────────────────────┐
│                                                          │
│   Tools                Resources           Prompts       │
│   ┌──────────┐        ┌──────────┐       ┌──────────┐  │
│   │ LLM 调用  │        │ 应用加载  │       │ 用户触发  │  │
│   │ 执行操作  │        │ 提供数据  │       │ 标准化流程 │  │
│   │ 可有副作用 │        │ 只读     │       │ 无副作用   │  │
│   └──────────┘        └──────────┘       └──────────┘  │
│       ↓                    ↓                   ↓         │
│   "做事的手"           "看到的眼"          "思考的模板"    │
│                                                          │
│   谁决定用？            谁决定用？          谁决定用？     │
│   → LLM 自主            → 应用/用户        → 用户主动     │
│                                                          │
│   进入上下文的是？       进入上下文的是？    进入上下文的是？│
│   → Tool 定义列表        → Resource 内容    → 展开后的消息  │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

**Prompts 是用户主动触发的交互模板**——用户在 UI 上选择一个 Prompt（通常是斜杠命令 `/xxx`），填入参数，Prompt 展开成一组高质量的 messages 发给 LLM。

如果说 Tools 是"LLM 的双手"，Resources 是"LLM 的眼睛"，那 Prompts 就是**"预制的思维模式"**——告诉 LLM 按什么框架来思考和回答。

---

## 二、为什么需要 Prompts？

你可能会想："用户直接打字告诉 LLM 该怎么做不就行了吗？为什么要搞一个 Prompt 模板？"

看一个对比：

```
场景：让 LLM 审查一段 SQL 的性能

❌ 没有 Prompt 模板——每次用户要自己写：

  用户："帮我分析这段 SQL 的性能问题。要从索引使用、
  全表扫描、JOIN 顺序、子查询优化、数据量估算这几个
  维度来看。输出格式要按维度分段，每个维度给出评级
  （✅通过/⚠️警告/❌严重）。SQL 如下：SELECT ..."

  → 写了一大段，下次还要再写一遍
  → 不同人写的角度不一样，质量不一致
  → 容易忘记某个重要的审查维度


✅ 有 Prompt 模板——用户只需：

  用户选择 /analyze-sql，填入 SQL 语句

  → Prompt 模板自动展开成结构化的多轮消息
  → 每次审查的维度、格式、深度都一致
  → 还能自动嵌入数据库的表结构（Resource）作为上下文
```

**Prompts 解决的核心问题：**

1. **一致性**——同一个任务每次的处理质量一致，不依赖用户的 prompt 写作水平
2. **复用性**——写一次模板，团队所有人都能用
3. **上下文自动注入**——模板可以自动附带相关的 Resource 内容
4. **降低门槛**——用户不需要懂 prompt engineering，选一个模板就行

---

## 三、Prompt 的定义结构

### 3.1 Prompt 列表（prompts/list）

```json
// 请求
{ "jsonrpc": "2.0", "id": 1, "method": "prompts/list" }

// 响应
{
  "jsonrpc": "2.0", "id": 1,
  "result": {
    "prompts": [
      {
        "name": "analyze-sql",
        "description": "从索引、扫描方式、JOIN 策略等维度全面分析 SQL 性能",
        "arguments": [
          {
            "name": "sql",
            "description": "要分析的 SQL 语句",
            "required": true
          },
          {
            "name": "dialect",
            "description": "数据库类型：postgresql / mysql / sqlite",
            "required": false
          }
        ]
      },
      {
        "name": "review-code",
        "description": "按安全性、性能、可读性、测试覆盖四个维度审查代码",
        "arguments": [
          {
            "name": "file_path",
            "description": "要审查的文件路径",
            "required": true
          },
          {
            "name": "focus",
            "description": "重点审查维度：security / performance / all",
            "required": false
          }
        ]
      },
      {
        "name": "explain-error",
        "description": "分析错误日志，定位根因，给出修复建议",
        "arguments": [
          {
            "name": "error_log",
            "description": "错误日志内容（粘贴完整的 stack trace）",
            "required": true
          }
        ]
      }
    ]
  }
}
```

每个 Prompt 的字段：

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `name` | ✅ | 模板名称，通常在 UI 上显示为 `/name` 斜杠命令 |
| `description` | ❌ | 模板描述，帮助用户理解什么时候该用 |
| `arguments` | ❌ | 参数列表，用户需要填入的变量 |

### 3.2 获取 Prompt 内容（prompts/get）

当用户选择一个 Prompt 并填入参数后，Client 调用 `prompts/get` 获取展开后的消息：

```json
// 请求
{
  "jsonrpc": "2.0", "id": 2,
  "method": "prompts/get",
  "params": {
    "name": "analyze-sql",
    "arguments": {
      "sql": "SELECT u.name, COUNT(o.id) FROM users u LEFT JOIN orders o ON u.id = o.user_id WHERE o.created_at > '2024-01-01' GROUP BY u.name HAVING COUNT(o.id) > 5 ORDER BY COUNT(o.id) DESC",
      "dialect": "postgresql"
    }
  }
}
```

Server 返回展开后的消息列表：

```json
{
  "jsonrpc": "2.0", "id": 2,
  "result": {
    "description": "PostgreSQL SQL 性能分析",
    "messages": [
      {
        "role": "user",
        "content": {
          "type": "text",
          "text": "请对以下 PostgreSQL SQL 语句进行全面的性能分析：\n\n```sql\nSELECT u.name, COUNT(o.id)\nFROM users u\nLEFT JOIN orders o ON u.id = o.user_id\nWHERE o.created_at > '2024-01-01'\nGROUP BY u.name\nHAVING COUNT(o.id) > 5\nORDER BY COUNT(o.id) DESC\n```\n\n请从以下维度逐一分析，每个维度给出评级（✅ 无问题 / ⚠️ 可优化 / ❌ 严重问题）：\n\n1. **索引使用**：WHERE、JOIN、ORDER BY 涉及的列是否有合适的索引\n2. **扫描方式**：是否可能触发全表扫描，预估扫描行数\n3. **JOIN 策略**：JOIN 类型是否合理，驱动表选择是否最优\n4. **聚合与排序**：GROUP BY、HAVING、ORDER BY 的开销分析\n5. **数据量评估**：基于典型数据量（users 50万行，orders 500万行）的性能预估\n\n最后给出优化建议，按优先级排序。"
        }
      },
      {
        "role": "user",
        "content": {
          "type": "resource",
          "resource": {
            "uri": "postgres://localhost/mydb/tables/users/schema",
            "mimeType": "application/json",
            "text": "{\"table\":\"users\",\"columns\":[{\"name\":\"id\",\"type\":\"bigint\",\"primary_key\":true},{\"name\":\"name\",\"type\":\"varchar(100)\"},{\"name\":\"email\",\"type\":\"varchar(255)\"}],\"indexes\":[{\"name\":\"users_pkey\",\"columns\":[\"id\"],\"unique\":true}]}"
          }
        }
      },
      {
        "role": "user",
        "content": {
          "type": "resource",
          "resource": {
            "uri": "postgres://localhost/mydb/tables/orders/schema",
            "mimeType": "application/json",
            "text": "{\"table\":\"orders\",\"columns\":[{\"name\":\"id\",\"type\":\"bigint\",\"primary_key\":true},{\"name\":\"user_id\",\"type\":\"bigint\"},{\"name\":\"created_at\",\"type\":\"timestamp\"},{\"name\":\"amount\",\"type\":\"decimal(10,2)\"}],\"indexes\":[{\"name\":\"orders_pkey\",\"columns\":[\"id\"],\"unique\":true},{\"name\":\"idx_orders_user_id\",\"columns\":[\"user_id\"]}]}"
          }
        }
      }
    ]
  }
}
```

### 3.3 图解 Prompt 的展开过程

```
用户在 UI 上的操作                 Prompt 展开后进入 LLM 上下文的内容
─────────────────                 ────────────────────────────────

选择 /analyze-sql               ┌────────────────────────────────┐
                                │ message 1 (role: user)          │
填入参数：                       │                                 │
  sql = "SELECT ..."    ──→     │ "请对以下 SQL 进行全面性能分析：  │
  dialect = "postgresql"        │  ```sql                         │
                                │  SELECT u.name, COUNT(o.id) ... │
                                │  ```                            │
                                │  请从以下维度分析：               │
                                │  1. 索引使用                     │
                                │  2. 扫描方式                     │
                                │  3. JOIN 策略                    │
                                │  ..."                           │
                                ├────────────────────────────────┤
                                │ message 2 (role: user)          │
                                │ [嵌入 Resource]                  │
Server 自动读取     ──→         │ users 表结构：                   │
相关的表结构 Resource            │ id(bigint,PK), name(varchar),   │
                                │ email(varchar)                   │
                                │ 索引: users_pkey                 │
                                ├────────────────────────────────┤
                                │ message 3 (role: user)          │
                                │ [嵌入 Resource]                  │
                                │ orders 表结构：                  │
                                │ id(bigint,PK), user_id(bigint), │
                                │ created_at(timestamp), ...       │
                                │ 索引: orders_pkey, idx_user_id  │
                                └────────────────────────────────┘

                                    ↓ 这三条 messages 一起发给 LLM
                                    ↓ LLM 基于完整上下文进行分析
```

**看到关键点了吗？** Prompt 不仅展开了用户的简单输入成结构化的分析要求，还**自动嵌入了相关的 Resource（表结构）**。用户完全不需要自己去找表结构信息——Prompt 模板知道分析 SQL 需要表结构，所以自动从 Server 拉取并嵌入。

---

## 四、Prompt 消息中的内容类型

Prompt 展开后的 messages 中，每条消息的 content 可以是以下类型：

### 4.1 纯文本（最常见）

```json
{
  "role": "user",
  "content": {
    "type": "text",
    "text": "请分析以下代码的安全性..."
  }
}
```

### 4.2 嵌入 Resource

```json
{
  "role": "user",
  "content": {
    "type": "resource",
    "resource": {
      "uri": "file:///project/src/auth.py",
      "mimeType": "text/x-python",
      "text": "def authenticate(token):\n    ..."
    }
  }
}
```

Prompt 可以在生成消息时主动调用 `resources/read` 拉取内容并嵌入。这是 Prompt 的独特能力——**把"用什么数据"的决策封装在模板里，用户不需要手动选择 Resource**。

### 4.3 图片（用于视觉分析）

```json
{
  "role": "user",
  "content": {
    "type": "image",
    "data": "iVBORw0KGgo...",
    "mimeType": "image/png"
  }
}
```

比如一个 UI 审查的 Prompt 模板，可以自动截图并嵌入。

### 4.4 多轮消息

Prompt 不限于单条 user 消息，可以是**多轮对话**——包含 `user` 和 `assistant` 角色的消息交替：

```json
{
  "messages": [
    {
      "role": "user",
      "content": { "type": "text", "text": "你是一个资深的数据库专家。以下是需要分析的 SQL：..." }
    },
    {
      "role": "assistant",
      "content": { "type": "text", "text": "我会从以下 5 个维度来分析这个查询。让我先看一下涉及的表结构。" }
    },
    {
      "role": "user",
      "content": { "type": "resource", "resource": { "uri": "postgres://…/schema", "text": "..." } }
    }
  ]
}
```

为什么要有多轮？**因为你可以通过 assistant 消息来"引导" LLM 的思考方向。** 这是一种叫 **few-shot prompting** 的技巧——在对话历史中放入 assistant 的"示范回答"，引导 LLM 按照相似的模式来回答后续问题。

```
多轮 Prompt 的引导效果：

message 1 (user):    "你是数据库专家，分析以下 SQL..."
message 2 (assistant): "我会从 5 个维度分析..."     ← 引导 LLM 按这个框架走
message 3 (user):    [表结构 Resource]              ← 自动注入上下文

→ LLM 接收到这个对话历史后，会自然地延续 message 2 的分析框架
→ 比单条 user 消息效果更好更稳定
```

---

## 五、Prompts 在 UI 上的呈现

不同的 Host 应用对 Prompt 的 UI 呈现不同，但通常是**斜杠命令**的形式：

```
┌─────────────────────────────────────────────────┐
│  Claude Desktop 对话框                            │
│                                                   │
│  ┌─────────────────────────────────────────────┐ │
│  │ /                                            │ │
│  │                                              │ │
│  │  📋 /analyze-sql  分析 SQL 性能               │ │
│  │  📋 /review-code  审查代码质量                │ │
│  │  📋 /explain-error 分析错误日志               │ │
│  │  📋 /sprint-review 生成冲刺回顾报告           │ │
│  │                                              │ │
│  └─────────────────────────────────────────────┘ │
│                                                   │
│  用户选择 /analyze-sql 后弹出参数填写：             │
│  ┌─────────────────────────────────────────────┐ │
│  │ SQL 语句（必填）: [________________]          │ │
│  │ 数据库类型:       [postgresql ▾]              │ │
│  │                           [执行]              │ │
│  └─────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

**你现在用的 Claude Code 也支持 MCP Prompts——在终端里输入 `/` 就能看到可用的 Prompt 列表。**

---

## 六、实战案例：为不同场景设计 Prompt

### 案例 1：数据库巡检 Prompt

```json
{
  "name": "db-health-check",
  "description": "对数据库进行全面健康检查：慢查询、表膨胀、索引使用率、连接池状态",
  "arguments": [
    {
      "name": "database",
      "description": "数据库名称",
      "required": true
    },
    {
      "name": "time_range",
      "description": "分析时间范围：1h / 6h / 24h / 7d",
      "required": false
    }
  ]
}
```

展开后的 messages（Server 自动拉取多个 Resource）：

```
message 1 (user):
  "请对数据库 analytics 进行全面健康检查，时间范围：最近 24 小时。
   按以下维度逐一分析，每个维度给出健康状态（🟢正常/🟡注意/🔴告警）：
   1. 慢查询 TOP 10（执行时间 > 1s）
   2. 表膨胀（dead tuple 比例 > 10%）
   3. 索引使用率（未使用的索引）
   4. 连接池状态（活跃/空闲/等待连接数）
   5. 磁盘空间趋势
   最后给出总体评估和需要立即处理的事项。"

message 2 (user): [嵌入 Resource: 慢查询统计]
message 3 (user): [嵌入 Resource: 表膨胀数据]
message 4 (user): [嵌入 Resource: 索引使用统计]
message 5 (user): [嵌入 Resource: 连接池状态]
```

### 案例 2：事故复盘 Prompt

```json
{
  "name": "incident-postmortem",
  "description": "基于告警信息和时间线，生成结构化的事故复盘报告",
  "arguments": [
    {
      "name": "incident_id",
      "description": "事故编号（来自 PagerDuty 或告警系统）",
      "required": true
    }
  ]
}
```

展开后：

```
message 1 (user):
  "请根据以下告警信息和时间线，生成一份事故复盘报告。

   报告结构：
   ## 1. 事故概要（一句话总结）
   ## 2. 时间线（按时间排列关键事件）
   ## 3. 影响范围（受影响的服务、用户数、持续时间）
   ## 4. 根因分析（5 Whys 方法深挖根因）
   ## 5. 修复措施（已采取的止血和修复动作）
   ## 6. 后续行动项（防止复发的改进措施，附负责人和截止日期）

   基调要求：无指责文化，聚焦系统改进而非个人失误。"

message 2 (user): [嵌入 Resource: PagerDuty 告警详情]
message 3 (user): [嵌入 Resource: 相关服务最近 2 小时的日志]
message 4 (user): [嵌入 Resource: 相关 Grafana 监控面板截图]
```

### 案例 3：API 设计审查 Prompt

```json
{
  "name": "review-api-design",
  "description": "审查 REST API 设计是否符合最佳实践（命名、版本、错误码、分页、幂等）",
  "arguments": [
    {
      "name": "openapi_spec",
      "description": "OpenAPI/Swagger 规范文件路径",
      "required": true
    }
  ]
}
```

展开后：

```
message 1 (user):
  "请审查以下 OpenAPI 规范的 API 设计质量。

   审查维度：
   1. URL 设计：是否符合 RESTful 命名规范，资源名词复数，层级合理
   2. HTTP 方法：GET/POST/PUT/PATCH/DELETE 使用是否正确
   3. 版本策略：是否有版本控制，向后兼容性
   4. 错误响应：是否有统一的错误码体系，错误信息是否有助于调试
   5. 分页与过滤：列表接口是否支持分页、排序、过滤
   6. 幂等性：POST/PUT/DELETE 是否考虑了幂等
   7. 安全：认证方式、敏感数据是否在 URL 中暴露

   每个维度给出评级和具体的改进建议。"

message 2 (user): [嵌入 Resource: OpenAPI 规范文件内容]
```

---

## 七、Prompts vs Tools vs Resources 的选择决策树

到这里三大能力都学完了，给一个决策树帮你判断什么场景用什么：

```
你需要 LLM 做什么？
│
├─── "执行一个操作"（调 API、写数据、创建文件……）
│    → 用 Tool
│    │
│    └─── 这个操作有副作用吗？
│         ├── 有 → Tool + Host 层权限确认
│         └── 没有（只是查询）→ 考虑是否该用 Resource 替代
│              ├── 数据是相对固定的背景信息 → Resource
│              └── 数据依赖用户的动态输入 → Tool
│
├─── "给 LLM 提供数据"（文件内容、表结构、配置……）
│    → 用 Resource
│    │
│    └─── 数据需要实时更新吗？
│         ├── 需要 → Resource + subscribe 订阅
│         └── 不需要 → 静态 Resource 就够了
│
└─── "让 LLM 按特定方式思考"（审查框架、分析模板、报告格式……）
     → 用 Prompt
     │
     └─── 需要自动附带上下文数据吗？
          ├── 需要 → Prompt 内嵌入 Resource
          └── 不需要 → 纯文本 Prompt
```

---

## 八、Prompts 的动态更新

和 Tools、Resources 一样，Prompts 也支持动态更新。如果 Server 初始化时声明了 `"prompts": { "listChanged": true }`：

```
Server 添加了一个新的 Prompt 模板
  │
  ▼
Server → Client: notifications/prompts/list_changed
  │
  ▼
Client 重新调 prompts/list 获取最新列表
  │
  ▼
Host 更新 UI 中的 Prompt 选择菜单
```

---

## 小结

1. **Prompts 是用户主动触发的交互模板**，把简单输入展开成结构化的高质量 prompt，保证一致性和复用性
2. **Prompt 展开后是一组 messages**，可包含 text、resource（自动嵌入数据）、image，支持多轮对话引导
3. **Prompt 的独特价值**是自动注入上下文——模板知道完成某个任务需要什么数据，自动从 Server 读取 Resource 并嵌入
4. **三大能力各有定位**：Tool 做操作（LLM 决定），Resource 提供数据（应用/用户决定），Prompt 标准化流程（用户触发）
5. **在 UI 上通常表现为斜杠命令**（`/analyze-sql`），用户选择后填入参数即可

---

> **下一课预告**：MCP 协议生命周期——初始化、能力协商与会话管理的完整细节，把前面零散学到的 initialize、notification、session 等概念串成一个完整的体系。

请告诉我你对这课内容的理解，或者有什么疑问？
