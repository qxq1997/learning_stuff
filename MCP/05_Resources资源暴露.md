# MCP - 第 5 课：MCP 核心能力之二——Resources（资源暴露）

## 学习目标（本节结束后你能做到什么）

1. 理解 Resources 的精确语义——它和 Tools 的本质区别
2. 掌握 Resource 的 URI 设计、MIME 类型和内容格式
3. 理解静态 Resource vs 动态 Resource（Resource Templates）
4. 掌握 Resource 的订阅机制（subscribe / unsubscribe）
5. 知道 Resources 和 Tools 如何配合使用

---

## 一、Resources 的精确定位

上一课学了 Tools——LLM 自主决定调用，执行操作，可能有副作用。Resources 和 Tools 是完全不同的设计哲学：

| | Tools | Resources |
| --- | --- | --- |
| **核心语义** | "做事" | "看数据" |
| **谁决定使用** | LLM 自主决策 | 应用/用户主动选择 |
| **副作用** | 可能有（写入、修改、删除） | 没有（只读） |
| **类比** | POST /api/issues（创建工单） | GET /api/issues/123（查看工单） |
| **交互方式** | LLM 在对话中自动调用 | 用户在 UI 上选择"附加这个资源"，或应用自动注入 |

**关键区别在于"谁决定使用"。**

Tool 是 LLM 自己决定调的——用户说"帮我创建一个 Issue"，LLM 判断需要调 `create_issue` 这个 Tool。

Resource 是**应用层面**决定加载的——用户在 UI 上点击"附加文件"选了一个文件，或者应用根据当前上下文自动把某些数据塞进 LLM 的 prompt。LLM 本身不会主动说"我要读取 resource://xxx"。

用一个实际场景来理解：

```
场景：用户在 Claude Desktop 里说"帮我审查这段代码"

方式 A（Resource）：
  用户在对话框旁边点击 📎 按钮
  → 弹出 MCP Server 暴露的 Resource 列表
  → 用户选择 "github://repos/my-project/src/main.py"
  → 应用把文件内容作为上下文附加到对话中
  → LLM 看到代码内容，进行审查

方式 B（Tool）：
  用户直接说"帮我审查 my-project 的 main.py"
  → LLM 决定调用 get_file_content Tool
  → Tool 返回文件内容
  → LLM 基于内容进行审查
```

两种方式都能达到目的，但 Resource 是"用户主动选择要给 LLM 看什么"，Tool 是"LLM 自己决定要去拿什么"。

**为什么要有这个区分？安全和控制。**

如果所有数据获取都由 LLM 自主决定，用户会失去对"LLM 能看到什么"的控制。Resource 让应用可以精确控制哪些数据进入 LLM 的上下文，这对于处理敏感数据的场景非常重要。

---

## 二、Resource 的定义结构

### 2.1 Resource 列表（resources/list）

Client 通过 `resources/list` 获取 Server 暴露的所有 Resource：

```json
// 请求
{ "jsonrpc": "2.0", "id": 1, "method": "resources/list" }

// 响应
{
  "jsonrpc": "2.0", "id": 1,
  "result": {
    "resources": [
      {
        "uri": "file:///project/README.md",
        "name": "项目说明文档",
        "description": "项目的 README 文件，包含项目介绍、安装步骤和使用方法",
        "mimeType": "text/markdown"
      },
      {
        "uri": "postgres://localhost/mydb/tables/users/schema",
        "name": "users 表结构",
        "description": "users 表的完整 DDL，包含列定义、约束和索引",
        "mimeType": "application/json"
      },
      {
        "uri": "github://repos/my-org/api-service/pulls/142",
        "name": "PR #142: Fix auth middleware",
        "description": "Alice 提交的认证中间件修复，包含 3 个文件的改动",
        "mimeType": "text/markdown"
      }
    ]
  }
}
```

每个 Resource 的字段：

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `uri` | ✅ | 资源的唯一标识符，格式是 URI |
| `name` | ✅ | 人类可读的名称，显示在 UI 上 |
| `description` | ❌ | 资源的描述，帮助用户决定要不要加载 |
| `mimeType` | ❌ | 内容的 MIME 类型（text/plain、application/json、image/png 等） |
| `annotations` | ❌ | 元数据注解（如受众提示、优先级提示等） |

### 2.2 读取 Resource（resources/read）

当用户（或应用）选择加载某个 Resource 时，Client 调用 `resources/read`：

```json
// 请求
{
  "jsonrpc": "2.0", "id": 2,
  "method": "resources/read",
  "params": {
    "uri": "postgres://localhost/mydb/tables/users/schema"
  }
}

// 响应
{
  "jsonrpc": "2.0", "id": 2,
  "result": {
    "contents": [
      {
        "uri": "postgres://localhost/mydb/tables/users/schema",
        "mimeType": "application/json",
        "text": "{\n  \"table\": \"users\",\n  \"columns\": [\n    {\"name\": \"id\", \"type\": \"bigint\", \"primary_key\": true},\n    {\"name\": \"email\", \"type\": \"varchar(255)\", \"nullable\": false},\n    {\"name\": \"created_at\", \"type\": \"timestamp\", \"default\": \"now()\"}\n  ],\n  \"indexes\": [\n    {\"name\": \"idx_users_email\", \"columns\": [\"email\"], \"unique\": true}\n  ]\n}"
      }
    ]
  }
}
```

**注意 `contents` 是数组**——一个 URI 可以返回多个内容块。比如读取一个目录的 URI，可以返回目录下所有文件的内容。

内容有两种格式：

```json
// 文本内容（代码、JSON、Markdown 等）
{
  "uri": "file:///project/main.py",
  "mimeType": "text/x-python",
  "text": "def hello():\n    print('hello world')\n"
}

// 二进制内容（图片、PDF 等）
{
  "uri": "file:///project/diagram.png",
  "mimeType": "image/png",
  "blob": "iVBORw0KGgoAAAANSUhEUgAA..."   // base64 编码
}
```

---

## 三、URI 设计

URI（Uniform Resource Identifier）是 Resource 的唯一标识。MCP 没有强制规定 URI 的 scheme，Server 可以自定义，但有一些惯例：

### 3.1 常见的 URI scheme

| Scheme | 用途 | 示例 |
| --- | --- | --- |
| `file://` | 本地文件 | `file:///Users/me/project/src/main.py` |
| `http://` / `https://` | Web 资源 | `https://api.example.com/docs` |
| `postgres://` | 数据库资源 | `postgres://localhost/mydb/tables/users` |
| `github://` | GitHub 资源 | `github://repos/facebook/react/pulls/142` |
| `jira://` | Jira 资源 | `jira://PROJECT/issues/PROJ-123` |
| `slack://` | Slack 资源 | `slack://channels/C01234/messages` |
| 自定义 scheme | 任何自定义资源 | `myapp://dashboards/revenue-q4` |

### 3.2 URI 设计原则

```
✅ 好的 URI 设计：

  file:///project/src/main.py
  ├── scheme: file（一看就知道是文件）
  └── path: /project/src/main.py（真实文件路径）

  postgres://prod-db/analytics/tables/orders/schema
  ├── scheme: postgres
  ├── host: prod-db
  ├── database: analytics
  └── path: tables/orders/schema（层级清晰）

❌ 差的 URI 设计：

  resource://abc123
  └── 完全看不出是什么资源

  data://1
  └── 没有层级，没有语义
```

设计原则和你设计 REST API 的 URL 一样——**让人（和 LLM）一看 URI 就知道这是什么资源**。

---

## 四、Resource Templates（动态资源模板）

到目前为止，`resources/list` 返回的都是**静态的、固定的** Resource 列表。但很多场景下，Resource 是动态的——比如数据库里有多少张表，就有多少个 Resource，不可能预先列出来。

这就是 **Resource Templates** 的用途——定义一个 URI 模板，让客户端按需填参数来读取。

### 4.1 模板定义

```json
// 请求
{ "jsonrpc": "2.0", "id": 1, "method": "resources/templates/list" }

// 响应
{
  "jsonrpc": "2.0", "id": 1,
  "result": {
    "resourceTemplates": [
      {
        "uriTemplate": "postgres://localhost/mydb/tables/{table_name}/schema",
        "name": "表结构",
        "description": "获取指定表的结构信息（列、类型、约束、索引）",
        "mimeType": "application/json"
      },
      {
        "uriTemplate": "github://repos/{owner}/{repo}/files/{path}",
        "name": "GitHub 文件内容",
        "description": "获取 GitHub 仓库中指定路径文件的内容",
        "mimeType": "text/plain"
      },
      {
        "uriTemplate": "logs://services/{service_name}?from={start_time}&to={end_time}",
        "name": "服务日志",
        "description": "获取指定服务在指定时间范围内的日志",
        "mimeType": "text/plain"
      }
    ]
  }
}
```

`uriTemplate` 遵循 [RFC 6570 URI Template](https://datatracker.ietf.org/doc/html/rfc6570) 标准——`{variable}` 表示需要填入的参数。

### 4.2 使用模板

应用拿到模板后，填入具体的参数值，生成完整的 URI，然后正常调用 `resources/read`：

```
模板：postgres://localhost/mydb/tables/{table_name}/schema
填入：table_name = "orders"
生成：postgres://localhost/mydb/tables/orders/schema

→ resources/read({ "uri": "postgres://localhost/mydb/tables/orders/schema" })
→ 返回 orders 表的结构
```

### 4.3 静态 Resource vs Resource Template 的使用场景

| | 静态 Resource | Resource Template |
| --- | --- | --- |
| **列表方式** | `resources/list` | `resources/templates/list` |
| **数量** | 有限的、可枚举的 | 无限的、参数化的 |
| **例子** | 项目的 README、配置文件列表 | 任意表的 Schema、任意文件的内容 |
| **UI 展示** | 可以在下拉菜单中列出 | 需要用户填写参数（如表名、路径） |

实际中两者经常配合使用：

```
Server 同时暴露：

静态 Resources:
  - postgres://localhost/mydb/tables  （所有表的列表概览）
  - postgres://localhost/mydb/config  （数据库配置）

Resource Templates:
  - postgres://localhost/mydb/tables/{table}/schema  （任意表的结构）
  - postgres://localhost/mydb/tables/{table}/sample   （任意表的样例数据）
```

---

## 五、订阅机制（subscribe / unsubscribe）

如果 Server 在初始化时声明了 `"resources": { "subscribe": true }`，Client 就可以订阅特定 Resource 的变更通知。

### 5.1 订阅流程

```
Client                                       Server
  │                                              │
  │  ── resources/subscribe ──────────────→      │
  │  { "uri": "file:///project/config.yaml" }    │
  │                                              │
  │       ←── 200 OK ──────────────────────      │
  │                                              │
  │  （config.yaml 被修改了）                      │
  │                                              │
  │       ←── notification ────────────────      │
  │  {                                           │
  │    "method": "notifications/resources/updated",
  │    "params": {                               │
  │      "uri": "file:///project/config.yaml"    │
  │    }                                         │
  │  }                                           │
  │                                              │
  │  Client 收到通知，重新调 resources/read       │
  │  ── resources/read ──────────────────→       │
  │  { "uri": "file:///project/config.yaml" }    │
  │       ←── 返回最新内容 ────────────────      │
  │                                              │
  │  ...                                         │
  │                                              │
  │  不再需要时取消订阅                            │
  │  ── resources/unsubscribe ────────────→      │
  │  { "uri": "file:///project/config.yaml" }    │
```

### 5.2 两种通知的区别

MCP 有两种 Resource 相关的通知，容易混淆：

| 通知 | 含义 | 粒度 |
| --- | --- | --- |
| `notifications/resources/list_changed` | **Resource 列表**变了（有新增或删除） | 整个列表 |
| `notifications/resources/updated` | **某个 Resource 的内容**变了 | 单个 Resource |

```
场景 1：数据库新增了一张 orders 表
→ Server 推送 notifications/resources/list_changed
→ Client 重新调 resources/list，发现多了 orders 表相关的 Resource

场景 2：orders 表的结构被 ALTER 了（加了一列）
→ Server 推送 notifications/resources/updated，uri = "postgres://…/orders/schema"
→ Client 重新读取这个 Resource 的内容
```

### 5.3 实际应用场景

订阅机制最典型的场景是**配置文件监控**和**实时数据流**：

**配置文件监控：**
```
应用启动时加载 config.yaml 的内容到 LLM 上下文
  → 订阅 file:///project/config.yaml
  → 有人改了配置文件
  → Server 通知 Client
  → 应用自动更新 LLM 上下文中的配置信息
```

**实时监控面板：**
```
应用把服务器监控指标展示给 LLM 分析
  → 订阅 metrics://order-service/health
  → 每次指标更新，Server 通知 Client
  → 应用把最新指标传给 LLM，LLM 持续分析是否有异常
```

---

## 六、Resources 和 Tools 的配合使用

在实际的 MCP Server 中，Resources 和 Tools 经常配合使用。来看一个完整的数据库 Server 的设计：

```
Database MCP Server
│
├── Resources（看数据）
│   ├── 静态：
│   │   └── postgres://mydb/tables          → 所有表的概览列表
│   ├── 模板：
│   │   ├── postgres://mydb/tables/{t}/schema  → 任意表的结构
│   │   └── postgres://mydb/tables/{t}/sample  → 任意表的样例数据（前 10 行）
│   └── 订阅：
│       └── 支持订阅 schema 变更通知
│
├── Tools（做操作）
│   ├── run_select_query(sql)               → 执行 SELECT（只读）
│   ├── run_mutation_query(sql)             → 执行 INSERT/UPDATE/DELETE（写入）
│   └── explain_query(sql)                  → 分析执行计划
│
└── Prompts（交互模板）
    └── optimize-query(sql)                 → 性能优化模板
```

**典型的配合流程：**

```
1. 用户在 UI 上选择加载 Resource "postgres://mydb/tables"
   → LLM 看到数据库里有 users、orders、products 三张表

2. 用户选择加载 Resource "postgres://mydb/tables/orders/schema"
   → LLM 看到 orders 表的完整结构（列、类型、索引）

3. 用户说："帮我查一下最近 7 天的订单总金额"
   → LLM 基于已经看到的表结构，知道 orders 表有 amount 和 created_at 列
   → LLM 决定调用 Tool run_select_query：
     SELECT SUM(amount) FROM orders WHERE created_at > now() - interval '7 days'
   → 返回结果

4. 用户说："这个查询好像有点慢，帮我分析一下"
   → LLM 决定调用 Tool explain_query，传入刚才的 SQL
   → 返回执行计划，发现 created_at 没有索引
   → LLM 建议："created_at 列缺少索引，建议添加"
```

**看到了吗？Resource 提供了"上下文"（表结构），Tool 执行了"操作"（查询、分析），两者配合让 LLM 能做出更精准的决策。**

如果没有 Resource，LLM 要么猜表结构（可能猜错），要么先调一个 Tool 去查表结构（多一步调用）。Resource 让这些背景信息预先就在 LLM 的视野中。

---

## 七、Resources vs 其他数据获取方式的对比

| 方式 | 语义 | 控制权 | 实时性 | 适用场景 |
| --- | --- | --- | --- | --- |
| **Resource** | 结构化的只读数据 | 应用/用户控制 | 支持订阅 | 表结构、配置文件、文档 |
| **Tool 返回值** | 操作的执行结果 | LLM 自主决策 | 调用时获取 | 查询结果、API 响应 |
| **System Prompt** | 固定的背景知识 | 开发者预设 | 不实时 | 角色设定、行为规则 |
| **RAG** | 检索到的文档片段 | 检索算法决定 | 依赖索引更新 | 大规模知识库搜索 |

**一个常见的误区**：把所有数据获取都做成 Tool。

```
❌ 不好的设计：
  Tool: get_table_schema(table_name)
  Tool: get_config_value(key)
  Tool: get_readme_content()
  → 这些都是只读的背景数据，每次都要 LLM 决定去调，浪费调用轮次

✅ 更好的设计：
  Resource: postgres://mydb/tables/{t}/schema  → 用户选择性加载
  Resource: config://app/settings              → 应用自动注入
  Resource: file:///project/README.md          → 用户手动附加
  → 减少 Tool 调用轮次，LLM 上下文更丰富
```

但也不是说所有数据获取都该用 Resource——**如果数据获取依赖用户的动态输入（比如 SQL 查询内容），那就应该用 Tool，因为只有 LLM 才知道用户具体想查什么。**

---

## 八、Resource Annotations（资源注解）

和 Tool 类似，Resource 也支持 annotations，提供额外的元数据提示：

```json
{
  "uri": "postgres://prod-db/analytics/tables/users/data",
  "name": "用户表完整数据",
  "description": "包含所有用户的个人信息（姓名、邮箱、手机号、地址）",
  "mimeType": "application/json",
  "annotations": {
    "audience": ["internal-admin"],
    "priority": 0.3
  }
}
```

| 注解 | 含义 |
| --- | --- |
| `audience` | 这个资源适合谁看。`["user"]` 表示最终用户可见，`["assistant"]` 表示只给 LLM 看，自定义值如 `["internal-admin"]` 表示仅内部管理员 |
| `priority` | 优先级提示（0-1），帮助应用决定在上下文空间有限时优先加载哪些资源 |

---

## 小结

1. **Resources 的核心语义是"只读数据暴露"**，由应用/用户决定加载，而非 LLM 自主决策——这是和 Tools 的本质区别
2. **URI 是 Resource 的唯一标识**，遵循 `scheme://path` 格式，设计原则是让人一看就知道是什么
3. **Resource Templates 解决动态 Resource 的问题**，用 `{variable}` 模板参数化 URI，支持无限多的资源
4. **订阅机制**让 Client 能感知 Resource 内容的变化，适用于配置监控、实时数据等场景
5. **Resources 和 Tools 配合使用**：Resource 提供背景上下文（表结构、配置），Tool 执行具体操作（查询、写入），减少不必要的 Tool 调用轮次

---

> **下一课预告**：深入 MCP 核心能力之三——Prompts（提示模板）。我们将学习 Prompt 的定义、参数化、嵌入 Resource，以及如何设计高质量的 Prompt 模板。

请告诉我你对这课内容的理解，或者有什么疑问？
