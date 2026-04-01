# MCP - 第 5b 课：Resources 补充 Q&A

## Q1：Resource 的 URI 也会一直在 LLM 上下文中吗？

**不是。Resource 的 URI 列表本身不会进入 LLM 上下文。**

### URI 列表和 LLM 上下文的关系

```
Resource URI 列表                    LLM 上下文
（存在 Host/应用层面）                （发给 LLM 的 messages）

┌─────────────────────────┐
│ resources/list 返回：     │
│                          │
│ • file:///README.md      │         ┌──────────────────────┐
│ • postgres://…/schema    │──选择──→│ 被选中的 Resource 的   │
│ • github://…/PR#142      │  加载   │ **内容** 进入上下文     │
│ • config://app/settings  │         └──────────────────────┘
└─────────────────────────┘
     ↑                                       ↑
  Host/UI 层面持有                         LLM 能看到的
  LLM 看不到这些 URI                      是内容，不是 URI 列表
```

### 完整的数据流

```
步骤 1：Client 调 resources/list → 拿到 URI 列表 → 存在 Host 内存中
        （LLM 完全不知道有这些 Resource）

步骤 2：用户在 UI 上选择"附加 README.md"
        或者应用自动决定加载某个 Resource

步骤 3：Client 调 resources/read("file:///README.md") → 拿到文件内容

步骤 4：Host 把文件内容塞进 LLM 的 messages 中：
        {
          "role": "user",
          "content": "以下是项目的 README 文件内容：\n\n# My Project\n..."
        }

        LLM 看到的是文本内容，不是 URI
```

### 和 Tools 的对比

| | Tools | Resources |
|---|---|---|
| **列表存在哪** | `tools` 参数 → **在 LLM 上下文中** | Host 内存 → **不在 LLM 上下文中** |
| **为什么** | LLM 需要看到 Tool 列表才能决定调哪个 | LLM 不需要决定加载哪个 Resource，这是应用/用户的事 |
| **进入上下文的是什么** | Tool 的定义（name + description + schema） | 被选中的 Resource 的**内容** |

### 关键结论

**Resource 不会像 Tool 那样有"太多占 token"的问题——URI 列表不进上下文，只有被选中加载的 Resource 内容才进入 LLM 上下文。**
