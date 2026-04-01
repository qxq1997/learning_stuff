# MCP - 第 4 课：MCP 核心能力之一——Tools（工具调用）

## 学习目标（本节结束后你能做到什么）

1. 完整理解 Tool 的定义、发现、调用、响应全流程
2. 知道如何设计一个好的 Tool（命名、参数、描述、粒度）
3. 理解 Tool 调用中的权限控制、错误处理和副作用管理
4. 能对比 MCP Tools 和你熟悉的 REST API / RPC 接口设计

---

## 一、Tool 在 MCP 中的定位

三种核心能力中，**Tools 是最重要的**。为什么？

- Resources 是"看数据"——被动的，应用/用户决定加载
- Prompts 是"按模板走"——辅助性的，优化交互质量
- **Tools 是"动手做事"——主动的，LLM 自主决定调用**

在实际的 MCP 生态中，绝大多数 Server 提供的主要能力都是 Tools。你可以把 Tool 理解为**暴露给 AI 的 API 接口**——区别是调用者不是人类开发者，而是 LLM。

这个区别非常关键，它影响了 Tool 的设计方式（后面会详细讲）。

---

## 二、Tool 的定义结构

一个 Tool 的完整定义长这样：

```json
{
  "name": "create_github_issue",
  "description": "在指定的 GitHub 仓库中创建一个新的 Issue。适用于需要跟踪 bug、feature request 或任务的场景。创建后会返回 Issue 的编号和 URL。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "owner": {
        "type": "string",
        "description": "仓库所有者（用户名或组织名），例如 'facebook'"
      },
      "repo": {
        "type": "string",
        "description": "仓库名称，例如 'react'"
      },
      "title": {
        "type": "string",
        "description": "Issue 标题，应简洁描述问题或需求"
      },
      "body": {
        "type": "string",
        "description": "Issue 正文，支持 Markdown 格式，可包含复现步骤、期望行为等"
      },
      "labels": {
        "type": "array",
        "items": { "type": "string" },
        "description": "标签列表，例如 ['bug', 'priority:high']。标签必须在仓库中已存在"
      },
      "assignees": {
        "type": "array",
        "items": { "type": "string" },
        "description": "指派人的用户名列表"
      }
    },
    "required": ["owner", "repo", "title"]
  }
}
```

逐个字段解析：

### name（工具名称）

```
"name": "create_github_issue"
```

- 这是 Tool 的唯一标识符，Client 调用时用这个名字
- 命名规范：`snake_case`，动词开头，描述动作
- 好的命名：`list_pull_requests`、`run_sql_query`、`send_slack_message`
- 差的命名：`pr`（太模糊）、`doStuff`（不知道干什么）、`github_api_v3_repos_issues_post`（太啰嗦）

### description（工具描述）

```
"description": "在指定的 GitHub 仓库中创建一个新的 Issue。适用于..."
```

**这是整个 Tool 定义中最重要的字段，没有之一。**

为什么？因为 LLM 决定"要不要调这个 Tool"和"怎么填参数"，主要靠的就是读 description。你写给人类的 API 文档可以简洁，但写给 LLM 的 description 需要更多上下文：

| 写给人类开发者的文档 | 写给 LLM 的 description |
| --- | --- |
| "创建 Issue" | "在指定的 GitHub 仓库中创建一个新的 Issue。适用于需要跟踪 bug、feature request 或任务的场景。创建后会返回 Issue 的编号和 URL。" |
| 人类会看参数列表和示例 | LLM 需要在 description 里就理解使用场景和预期效果 |

**description 的写作原则：**

1. **说清楚做什么**：不要只说"创建 Issue"，要说"在指定的 GitHub 仓库中创建一个新的 Issue"
2. **说清楚什么时候用**：比如"适用于需要跟踪 bug、feature request 或任务的场景"
3. **说清楚返回什么**：比如"创建后会返回 Issue 的编号和 URL"
4. **说清楚不做什么**（如果容易混淆）：比如"不会自动关联 PR"、"不支持跨仓库操作"

### inputSchema（输入参数 Schema）

```json
"inputSchema": {
  "type": "object",
  "properties": { ... },
  "required": ["owner", "repo", "title"]
}
```

这就是标准的 **JSON Schema**——和你在 Swagger/OpenAPI 里定义请求体参数是一模一样的东西。

注意几个要点：

1. **每个属性都要有 description**——LLM 不能靠猜来填参数
2. **用 `required` 明确必填项**——LLM 看到 required 会确保填上
3. **用 `enum` 限制取值范围**——避免 LLM 乱填

```json
// ✅ 好的 inputSchema
"status": {
  "type": "string",
  "enum": ["open", "closed", "merged"],
  "description": "PR 状态过滤：open（进行中）、closed（已关闭）、merged（已合并）"
}

// ❌ 差的 inputSchema
"status": {
  "type": "string"
  // 没有 description，没有 enum，LLM 会猜 "active"? "pending"? "done"?
}
```

---

## 三、Tool 的完整调用流程

从 LLM 决定调用到返回结果，完整链路是这样的：

```
步骤 1：LLM 看到 Tool 列表，决定调用
┌─────────────────────────────────────────────────┐
│ LLM 的推理过程（对你透明，你看不到）                │
│                                                   │
│ "用户想在 GitHub 上创建一个 bug 工单..."            │
│ "我看到有个 create_github_issue 工具可以做这件事"   │
│ "需要的参数有 owner、repo、title..."               │
│ "用户说了仓库是 facebook/react，标题是..."          │
│                                                   │
│ → 输出 tool_use 请求                               │
└─────────────────────────────────────────────────┘
               │
               ▼
步骤 2：Host 收到 LLM 的 tool_use 请求
┌─────────────────────────────────────────────────┐
│ Host 的处理：                                     │
│                                                   │
│ 1. 解析 LLM 返回的 tool_use：                      │
│    name = "create_github_issue"                    │
│    arguments = {"owner":"facebook","repo":"react", │
│                 "title":"Bug: ..."}                 │
│                                                   │
│ 2. 查路由表：这个 Tool 属于哪个 Server？             │
│    → GitHub MCP Server（通过 Client A 连接）        │
│                                                   │
│ 3. 权限检查：这个 Tool 需要用户确认吗？              │
│    → create 操作有副作用，弹窗让用户确认              │
└─────────────────────────────────────────────────┘
               │
               ▼
步骤 3：用户确认（可选）
┌─────────────────────────────────────────────────┐
│ 弹窗/提示：                                       │
│ "Claude 想要在 facebook/react 创建一个 Issue：     │
│  标题：Bug: Component unmount causes memory leak   │
│  确认执行？ [允许] [拒绝]"                          │
└─────────────────────────────────────────────────┘
               │ 用户点击 [允许]
               ▼
步骤 4：Client 通过 MCP 协议调用 Server
┌─────────────────────────────────────────────────┐
│ Client → Server (JSON-RPC):                       │
│                                                   │
│ {                                                  │
│   "jsonrpc": "2.0",                                │
│   "id": 42,                                        │
│   "method": "tools/call",                          │
│   "params": {                                      │
│     "name": "create_github_issue",                 │
│     "arguments": {                                 │
│       "owner": "facebook",                         │
│       "repo": "react",                             │
│       "title": "Bug: Component unmount causes...", │
│       "body": "## 复现步骤\n1. ...",                │
│       "labels": ["bug"]                            │
│     }                                              │
│   }                                                │
│ }                                                  │
└─────────────────────────────────────────────────┘
               │
               ▼
步骤 5：Server 执行实际操作
┌─────────────────────────────────────────────────┐
│ Server 的处理：                                    │
│                                                   │
│ 1. 校验参数（owner、repo、title 必填）              │
│ 2. 调用 GitHub REST API：                          │
│    POST https://api.github.com/repos/facebook/     │
│         react/issues                               │
│ 3. 处理 GitHub 的响应                               │
│ 4. 格式化返回结果                                   │
└─────────────────────────────────────────────────┘
               │
               ▼
步骤 6：Server 返回结果
┌─────────────────────────────────────────────────┐
│ Server → Client (JSON-RPC):                       │
│                                                   │
│ {                                                  │
│   "jsonrpc": "2.0",                                │
│   "id": 42,                                        │
│   "result": {                                      │
│     "content": [                                   │
│       {                                            │
│         "type": "text",                            │
│         "text": "已创建 Issue #12345\n             │
│                  URL: https://github.com/..."      │
│       }                                            │
│     ],                                             │
│     "isError": false                               │
│   }                                                │
│ }                                                  │
└─────────────────────────────────────────────────┘
               │
               ▼
步骤 7：Host 把结果传回 LLM
┌─────────────────────────────────────────────────┐
│ Host 把 Tool 的返回结果作为 tool_result 传回 LLM   │
│ LLM 基于结果生成最终回答给用户：                     │
│                                                   │
│ "已经帮你创建了 Issue #12345，标题是..."             │
└─────────────────────────────────────────────────┘
```

### Tool 的返回值格式

Tool 调用的返回值 `result` 包含两个关键字段：

```json
{
  "content": [
    { "type": "text", "text": "查询结果：找到 42 条记录" },
    { "type": "image", "data": "base64...", "mimeType": "image/png" }
  ],
  "isError": false
}
```

**content**：一个数组，可以包含多种类型的内容：

| 类型 | 用途 | 例子 |
| --- | --- | --- |
| `text` | 文本结果 | 查询结果、操作确认信息 |
| `image` | 图片（base64） | 截图、图表、可视化 |
| `resource` | 嵌入一个 Resource 引用 | 指向一个文件或数据源 |

**isError**：标记这个结果是否表示错误。注意，这不是协议层面的错误（那个用 JSON-RPC 的 `error` 字段），而是业务层面的错误——"Tool 执行了，但结果是失败的"。

```json
// 协议错误：Tool 不存在（JSON-RPC error）
{
  "jsonrpc": "2.0", "id": 42,
  "error": { "code": -32601, "message": "Tool not found: nonexistent_tool" }
}

// 业务错误：Tool 存在，执行了，但失败了（isError: true）
{
  "jsonrpc": "2.0", "id": 42,
  "result": {
    "content": [{ "type": "text", "text": "错误：仓库 facebook/react 不存在或无权访问" }],
    "isError": true
  }
}
```

这和 HTTP API 的区别类似：
- 协议错误 = HTTP 404/500
- 业务错误 = HTTP 200 + `{"success": false, "error": "..."}`

---

## 四、Tool 的发现与动态更新

### 发现：tools/list

Client 初始化完成后，通过 `tools/list` 获取 Server 的所有 Tool：

```json
// 请求
{ "jsonrpc": "2.0", "id": 5, "method": "tools/list" }

// 响应
{
  "jsonrpc": "2.0", "id": 5,
  "result": {
    "tools": [
      {
        "name": "list_pull_requests",
        "description": "列出仓库的 Pull Requests...",
        "inputSchema": { ... }
      },
      {
        "name": "create_github_issue",
        "description": "创建 Issue...",
        "inputSchema": { ... }
      }
    ]
  }
}
```

如果 Tool 很多，还支持**分页**（通过 `cursor` 参数）：

```json
// 第一页
{ "method": "tools/list" }
→ { "tools": [...前 50 个...], "nextCursor": "page2" }

// 第二页
{ "method": "tools/list", "params": { "cursor": "page2" } }
→ { "tools": [...后 30 个...] }
```

### 动态更新：notifications/tools/list_changed

如果 Server 在初始化时声明了 `"tools": { "listChanged": true }`，表示它的 Tool 列表可能会动态变化。变化时 Server 主动推送通知：

```json
// Server → Client（Notification，没有 id）
{ "jsonrpc": "2.0", "method": "notifications/tools/list_changed" }
```

Client 收到后重新调 `tools/list` 获取最新列表，然后通知 Host 更新全局能力视图。

**什么时候 Tool 列表会动态变化？**

举一个真实场景：一个数据库 MCP Server，当用户创建了一张新表 `orders`，Server 动态生成一个新的 Tool `query_orders`。或者一个插件化的 Server，管理员热加载了一个新插件，Server 把插件的功能暴露为新的 Tool。

---

## 五、Tool 设计最佳实践

这一节是本课的重点——设计 Tool 就像设计 API，但你的"调用者"是 LLM 而不是人类开发者，这带来了不同的考量。

### 5.1 粒度：一个 Tool 该做多大？

**原则：一个 Tool 做一件事，但要做完整。**

```
❌ 太细：
  - get_issue_title(issue_id)
  - get_issue_body(issue_id)
  - get_issue_labels(issue_id)
  - get_issue_assignees(issue_id)
  LLM 要调 4 次才能拿到一个 Issue 的完整信息

❌ 太粗：
  - manage_repository(action, ...)
  一个 Tool 包含 "创建Issue/关闭Issue/合并PR/删除分支/..." 十几种操作
  description 写不清楚，LLM 不知道怎么用

✅ 合适：
  - get_issue(owner, repo, issue_number)       → 返回完整 Issue 信息
  - create_issue(owner, repo, title, body, ...) → 创建 Issue
  - list_issues(owner, repo, state, labels, ...) → 搜索 Issue
  每个 Tool 完成一个完整的操作
```

类比你设计 REST API：
- 不会为一个实体的每个字段开一个 GET 端点（太细）
- 也不会把所有 CRUD 塞进一个 POST 端点（太粗）
- 而是每个操作一个端点（`GET /issues/{id}`、`POST /issues`、`GET /issues?state=open`）

### 5.2 命名：让 LLM 一看就懂

```
✅ 好的命名（动词_名词 格式）：
  - search_code          → "搜索代码"
  - create_pull_request  → "创建 PR"
  - restart_deployment   → "重启部署"
  - run_sql_query        → "执行 SQL 查询"

❌ 差的命名：
  - code                 → 是搜索代码？还是生成代码？
  - pr                   → 是列出 PR？创建 PR？合并 PR？
  - handle_request       → 处理什么请求？
  - do_action            → 做什么动作？
```

### 5.3 参数设计：给 LLM 足够的线索

**每个参数的 description 都要写清楚**——格式、示例、约束：

```json
// ✅ 好的参数描述
"date_from": {
  "type": "string",
  "description": "起始日期，ISO 8601 格式（YYYY-MM-DD），例如 '2024-01-15'。只返回此日期之后创建的记录。"
}

// ❌ 差的参数描述
"date_from": {
  "type": "string",
  "description": "开始日期"
  // LLM 会猜格式：2024/1/15? Jan 15? 1705276800?
}
```

**善用 `enum` 限制选项**：

```json
// ✅ 用 enum，LLM 只能从这几个值里选
"priority": {
  "type": "string",
  "enum": ["P0", "P1", "P2", "P3"],
  "description": "优先级：P0（致命）、P1（严重）、P2（一般）、P3（低优先）"
}

// ❌ 不用 enum，LLM 可能填 "high"、"urgent"、"1" 等乱七八糟的值
"priority": {
  "type": "string",
  "description": "优先级"
}
```

**善用 `default`，减少必填项**：

```json
"state": {
  "type": "string",
  "enum": ["open", "closed", "all"],
  "default": "open",
  "description": "过滤状态，默认只返回 open 状态"
}
```

### 5.4 副作用管理：读操作 vs 写操作

Tool 最重要的分类依据是**有没有副作用**：

| 类型 | 例子 | 风险 | Host 应该怎么处理 |
| --- | --- | --- | --- |
| 只读（无副作用） | `list_issues`、`search_code`、`get_metrics` | 低 | 可以自动执行 |
| 写入（有副作用） | `create_issue`、`merge_pr`、`delete_branch` | 中高 | 应该让用户确认 |
| 危险操作 | `drop_table`、`force_push`、`delete_repo` | 极高 | 必须让用户确认 + 二次确认 |

**MCP 协议本身不强制要求权限确认——这是 Host 的责任。** 但你作为 Server 开发者，可以在 Tool 的 description 中标注副作用级别，帮助 Host 做决策：

```json
{
  "name": "delete_branch",
  "description": "【危险操作】永久删除指定的 Git 分支。此操作不可撤销。如果分支上有未合并的 commit，这些 commit 将变得不可达（但在 Git GC 前仍可通过 commit hash 恢复）。",
  "inputSchema": { ... }
}
```

LLM 看到"【危险操作】"和"不可撤销"，也会更谨慎地使用这个 Tool。

### 5.5 幂等性

这个概念你作为后端工程师肯定熟——**同一个请求执行多次，效果和执行一次相同**。

为什么 MCP Tool 也要考虑幂等性？因为 LLM 有时会重试（比如第一次调用超时了，LLM 决定再调一次）：

```json
// ✅ 幂等的 Tool：重试安全
{
  "name": "set_issue_status",
  "description": "将 Issue 状态设置为指定值（幂等操作，重复调用不会产生副作用）"
  // set status = closed，调一次是 closed，调两次还是 closed
}

// ⚠️ 非幂等的 Tool：重试可能出问题
{
  "name": "add_comment",
  "description": "给 Issue 添加一条评论（注意：重复调用会创建多条相同评论）"
  // 如果 LLM 重试，就会出现两条一样的评论
}
```

对于非幂等的 Tool，可以在 Server 端做去重（比如基于请求的 hash 或者 JSON-RPC 的 `id` 字段去重）。

---

## 六、Tool Annotations（工具注解）

MCP 还定义了一个可选的 `annotations` 字段，用于给 Tool 添加元数据。这些注解帮助 Host 和 LLM 更好地理解 Tool 的特性：

```json
{
  "name": "delete_file",
  "description": "永久删除指定路径的文件",
  "inputSchema": { ... },
  "annotations": {
    "title": "删除文件",
    "readOnlyHint": false,
    "destructiveHint": true,
    "idempotentHint": true,
    "openWorldHint": false
  }
}
```

| 注解 | 含义 | 默认值 |
| --- | --- | --- |
| `title` | 人类可读的显示名称 | 无 |
| `readOnlyHint` | 是否只读（不修改任何状态） | false |
| `destructiveHint` | 是否有破坏性（删除、覆盖等） | true |
| `idempotentHint` | 是否幂等 | false |
| `openWorldHint` | 是否与外部实体交互（发邮件、发消息等） | true |

**注意这些都是 Hint（提示），不是强制的安全约束。** Host 可以参考这些提示来决定是否需要用户确认，但不能完全依赖它——恶意的 Server 可能会标注 `destructiveHint: false` 来绕过确认。

---

## 七、实际案例：设计一组 Database MCP Tools

让我们从头设计一个数据库 MCP Server 的 Tool 集合，把上面的原则全部用上：

```json
[
  {
    "name": "list_tables",
    "description": "列出数据库中所有的表名及其行数估计值。返回格式为表名列表，每项包含表名、预估行数、表注释。",
    "inputSchema": {
      "type": "object",
      "properties": {
        "schema": {
          "type": "string",
          "default": "public",
          "description": "数据库 schema 名称，默认 'public'"
        }
      }
    },
    "annotations": {
      "readOnlyHint": true,
      "destructiveHint": false
    }
  },
  {
    "name": "describe_table",
    "description": "获取指定表的详细结构：列名、数据类型、是否可空、默认值、主键、外键、索引。用于在写 SQL 前了解表结构。",
    "inputSchema": {
      "type": "object",
      "properties": {
        "table_name": {
          "type": "string",
          "description": "表名，例如 'orders'、'users'"
        },
        "schema": {
          "type": "string",
          "default": "public",
          "description": "schema 名称"
        }
      },
      "required": ["table_name"]
    },
    "annotations": {
      "readOnlyHint": true,
      "destructiveHint": false
    }
  },
  {
    "name": "run_select_query",
    "description": "执行只读的 SELECT 查询并返回结果。仅支持 SELECT 语句，不允许 INSERT/UPDATE/DELETE/DROP 等修改操作。结果最多返回 1000 行。超出部分会被截断并提示总行数。",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sql": {
          "type": "string",
          "description": "要执行的 SELECT SQL 语句。不支持多条语句（不能用分号分隔多条 SQL）。"
        },
        "max_rows": {
          "type": "integer",
          "default": 100,
          "description": "最大返回行数（1-1000），默认 100"
        }
      },
      "required": ["sql"]
    },
    "annotations": {
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true
    }
  },
  {
    "name": "run_mutation_query",
    "description": "【需要确认】执行修改数据的 SQL（INSERT/UPDATE/DELETE）。执行前会在事务中运行并返回预估影响行数，需要用户确认后才真正提交。不支持 DDL（CREATE/ALTER/DROP）。",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sql": {
          "type": "string",
          "description": "要执行的 INSERT/UPDATE/DELETE SQL 语句"
        }
      },
      "required": ["sql"]
    },
    "annotations": {
      "readOnlyHint": false,
      "destructiveHint": true,
      "idempotentHint": false
    }
  },
  {
    "name": "explain_query",
    "description": "对 SQL 语句执行 EXPLAIN ANALYZE，返回查询执行计划。用于分析查询性能、发现全表扫描、缺失索引等问题。不会修改数据。",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sql": {
          "type": "string",
          "description": "要分析的 SQL 语句（通常是 SELECT）"
        },
        "format": {
          "type": "string",
          "enum": ["text", "json", "yaml"],
          "default": "text",
          "description": "执行计划的输出格式"
        }
      },
      "required": ["sql"]
    },
    "annotations": {
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true
    }
  }
]
```

**设计要点回顾：**

1. **粒度合理**：`list_tables` 和 `describe_table` 分开，而不是合成一个"查数据库信息"的万能 Tool
2. **读写分离**：`run_select_query`（只读）和 `run_mutation_query`（写入）分成两个 Tool，权限模型清晰
3. **安全边界**：`run_select_query` 明确说"不允许 INSERT/UPDATE/DELETE"，Server 端会做校验
4. **description 详细**：每个 Tool 说清楚做什么、限制是什么、返回什么
5. **annotations 准确**：标注了只读/破坏性/幂等性，帮助 Host 做权限决策

---

## 八、与 REST API 设计的对比

| 维度 | REST API | MCP Tool |
| --- | --- | --- |
| 调用者 | 人类开发者（读文档、写代码） | LLM（读 description、生成参数） |
| 发现方式 | Swagger/OpenAPI 文档 | tools/list 动态发现 |
| 参数传递 | path/query/body 分开 | 统一的 inputSchema |
| 版本管理 | URL 路径 `/v1/` `/v2/` | 协议版本 + 能力协商 |
| 错误返回 | HTTP 状态码 + JSON body | JSON-RPC error + isError |
| 认证 | API Key、OAuth、JWT | Server 侧管理，对 Tool 调用透明 |
| 文档质量要求 | 高（给人看） | 更高（给 LLM 看，description 是核心） |

---

## 小结

1. **Tool = 暴露给 LLM 的 API 接口**，但调用者是 AI 而非人类，description 的质量直接决定 Tool 是否好用
2. **完整流程**：LLM 决策 → Host 路由 → 权限确认 → Client 转发 → Server 执行 → 结果回传 → LLM 生成回答
3. **返回值**：content 数组（支持 text/image/resource）+ isError 标记业务错误
4. **设计原则**：一个 Tool 做一件完整的事、命名用动词_名词、参数 description 写清格式和示例、用 enum 限制取值、读写分离
5. **Annotations**：可选的元数据标注（只读/破坏性/幂等），帮助 Host 做权限决策

---

> **下一课预告**：深入 MCP 核心能力之二——Resources。我们将学习 Resource 的 URI 设计、静态 vs 动态 Resource、订阅机制，以及 Resources 和 Tools 的配合使用。

请告诉我你对这课内容的理解，或者有什么疑问？
