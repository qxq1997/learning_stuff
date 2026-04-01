# MCP - 第 4b 课：Tools 补充 Q&A

## Q1：Host 怎么感知当前有多少 Tool？所有 Client 都把 Tool 列表发给 Host 吗？

**是的，所有 Client 都把各自的 Tool 列表上报给 Host。** 流程如下：

```
Host 启动
│
├── 创建 Client A → 连接 GitHub Server → 初始化 → tools/list → 拿到 [list_pr, create_issue, merge_pr]
├── 创建 Client B → 连接 Jira Server   → 初始化 → tools/list → 拿到 [search_issues, update_status]
└── 创建 Client C → 连接 DB Server     → 初始化 → tools/list → 拿到 [run_query, explain_query]

Host 内部维护一张路由表（全局能力视图）：

┌─────────────────────────┬────────────────┐
│ Tool 名称                │ 归属 Client     │
├─────────────────────────┼────────────────┤
│ github__list_pr          │ Client A       │
│ github__create_issue     │ Client A       │
│ github__merge_pr         │ Client A       │
│ jira__search_issues      │ Client B       │
│ jira__update_status      │ Client B       │
│ db__run_query            │ Client C       │
│ db__explain_query        │ Client C       │
└─────────────────────────┴────────────────┘
```

当某个 Server 推送 `notifications/tools/list_changed` 时，对应的 Client 重新调 `tools/list`，Host 更新路由表。

---

## Q2：Tool 列表会进到 LLM 的对话上下文吗？

**会，而且这是整个机制能 work 的前提。**

Host 每次调用 LLM API 时，会把汇总的 Tool 列表作为 `tools` 参数传入。以调 Claude API 为例：

```json
{
  "model": "claude-sonnet-4-20250514",
  "messages": [
    { "role": "user", "content": "帮我看看 GitHub 上有什么 PR 要审查" }
  ],
  "tools": [
    {
      "name": "github__list_pr",
      "description": "列出仓库的 Pull Requests...",
      "input_schema": { ... }
    },
    {
      "name": "jira__search_issues",
      "description": "搜索 Jira 工单...",
      "input_schema": { ... }
    },
    {
      "name": "db__run_query",
      "description": "执行 SQL 查询...",
      "input_schema": { ... }
    }
  ]
}
```

LLM 看到这个 `tools` 列表后，才知道自己"有哪些工具可用"，才能做出"我要调 `github__list_pr`"的决策。

### Tool 太多怎么办？

每个 Tool 的定义（name + description + inputSchema）都占 token。如果你连了 20 个 Server，每个暴露 10 个 Tool，那就是 200 个 Tool 的定义要塞进上下文。这会：

1. **吃掉大量上下文窗口** — 留给用户对话的空间就少了
2. **影响 LLM 决策质量** — Tool 太多，LLM 选错 Tool 的概率增大
3. **增加 API 成本** — 输入 token 变多，每次调用都更贵

**Host 通常会做的优化：**

| 策略 | 做法 |
| --- | --- |
| **过滤** | 根据用户的当前对话主题，只传相关的 Tool（比如用户在聊代码，就不传 Jira 的 Tool） |
| **分组** | 先给 LLM 一个 Tool 摘要列表，LLM 说"我需要数据库相关的工具"，再把 DB 的完整 Tool 定义传过去 |
| **精简 description** | 把冗长的 description 压缩，只保留关键信息 |
| **限制数量** | 设定上限，比如最多传 40 个 Tool |

这也是为什么第四课强调 **Tool 的 description 要精练但足够**——太长浪费 token，太短 LLM 选不对。

### 总结

**MCP 的 Tool 信息从 Server → Client → Host → LLM 上下文，逐层汇聚，最终 LLM 是通过 API 调用中的 `tools` 参数"看到"所有可用工具的。**
