# MCP - 第 6b 课：Prompts 补充 Q&A

## Q1：Prompt 展开后的多条 messages 是多次 LLM 调用吗？还是一次？如果是一次，多轮有什么意义？

### 答：是一次调用，不是多次

Prompt 展开后的所有 messages **一次性塞进 LLM API 的 `messages` 数组**，只发起一次 API 调用：

```json
// 一次 API 调用，messages 数组里有多条消息
{
  "model": "claude-sonnet-4-20250514",
  "messages": [
    { "role": "user", "content": "你是数据库专家，分析以下SQL..." },
    { "role": "assistant", "content": "我会从5个维度分析..." },
    { "role": "user", "content": "[users 表结构 Resource]" },
    { "role": "user", "content": "[orders 表结构 Resource]" }
  ]
}
// → 一次请求，一次响应，不是四次对话
```

### 多轮和压缩成一段的区别

技术上可以压缩成一条 user 消息，但效果不一样。原因在于 **LLM 对 role 标签的理解不同**：

```
方式 A：全压成一条 user 消息

messages: [
  { "role": "user", "content": "你是数据库专家。分析以下SQL。
    从索引、扫描、JOIN这几个维度分析。表结构如下：...
    SQL如下：SELECT ..." }
]

→ LLM 看到一大坨文本，所有信息混在一起
→ LLM 自己决定怎么组织回答


方式 B：多轮消息

messages: [
  { "role": "user",      "content": "分析以下SQL的性能..." },
  { "role": "assistant", "content": "我会从5个维度逐一分析：1.索引 2.扫描..." },
  { "role": "user",      "content": "[表结构数据]" }
]

→ LLM 看到 assistant 消息，认为"我之前已经说过要从5个维度分析"
→ LLM 会自然地延续这个框架，按5个维度逐一输出
→ 输出结构更稳定、更可控
```

### 图解核心区别

```
一条长消息：                          多轮消息：

┌──────────────────┐               ┌──────────────────┐
│ user:             │               │ user:             │
│ 一大段指令+数据    │               │ 明确的任务指令     │
│ 全混在一起        │               ├──────────────────┤
│ LLM 自由发挥     │               │ assistant:        │
│                   │               │ "我会按X框架分析"  │  ← 锚定输出格式
└──────────────────┘               ├──────────────────┤
       ↓                           │ user:             │
  LLM 可能按自己的                  │ [上下文数据]       │  ← 数据和指令分离
  方式组织输出                      └──────────────────┘
  格式不稳定                               ↓
                                    LLM 延续 assistant
                                    消息的框架输出
                                    格式稳定可控
```

### 三个具体好处

| 好处 | 说明 |
| --- | --- |
| **引导输出格式** | assistant 消息起"锚定"作用——LLM 倾向于延续自己之前说过的话。放一条 assistant 消息说"我会从5个维度分析"，LLM 就真的会按5个维度来 |
| **信息分层** | 指令和数据分开放在不同 message 中，比塞在一段里更清晰。LLM 对 message 边界有明确的感知 |
| **Resource 嵌入语义更准确** | Resource 作为独立的 user message，LLM 知道这是"附件/上下文数据"而不是"用户指令的一部分" |

### 结论

简单 Prompt 用单条 user 消息完全够了。多轮主要用在需要**精确控制 LLM 输出结构**的复杂场景——通过 assistant 消息"锚定"输出框架，通过 message 分离实现指令与数据的分层。

---

## Q2：Prompt 可以同时用到 Resource 和 Tool 吗？是三者的叠加吗？

### 答：Prompt 可以主动嵌入 Resource，但不能直接调用 Tool——不过间接会触发 Tool

**三者的叠加发生在不同阶段：**

```
用户选择 /analyze-sql，填入 SQL
         │
         ▼
    ┌─────────┐
    │ Prompt  │  Server 端展开：
    │ 展开    │  1. 生成分析指令（text）
    │         │  2. 读取表结构（Resource）并嵌入     ← Prompt + Resource
    └────┬────┘
         │ 返回 messages 数组
         ▼
    ┌─────────┐
    │  Host   │  把 messages + Tool列表 一起发给 LLM
    └────┬────┘
         │
         ▼
    ┌─────────┐
    │  LLM    │  看到：
    │  推理   │  - Prompt 展开的消息（含SQL + 表结构）
    │         │  - 可用的 Tool 列表
    │         │
    │         │  LLM 判断："我需要调 explain_query"   ← 间接触发 Tool
    └────┬────┘
         │ tool_use: explain_query
         ▼
    ┌─────────┐
    │  Tool   │  执行 EXPLAIN ANALYZE
    │  调用   │  返回执行计划
    └────┬────┘
         │ 结果回传
         ▼
    ┌─────────┐
    │  LLM    │  结合 Prompt 框架 + Resource 表结构
    │  生成   │  + Tool 执行计划 → 完整分析报告
    └─────────┘
```

### 叠加关系总结

| 阶段 | 谁在工作 | 做什么 |
| --- | --- | --- |
| 用户触发 Prompt | **Prompt** | 展开成 messages，**主动拉取 Resource** 嵌入 |
| 发给 LLM | **Host** | 把 Prompt 的 messages + Tool 列表一起发 |
| LLM 推理 | **LLM** | 基于 Prompt 上下文，**自主决定调用 Tool** |
| Tool 执行 | **Tool** | 返回结果，LLM 继续推理 |

```
三者的叠加关系：

Prompt ──────┐
             │  Prompt 主动嵌入 Resource（Server 端，展开阶段）
Resource ────┤
             │  LLM 基于上下文自主决定调 Tool（LLM 端，推理阶段）
Tool ────────┘

时间线：
  Prompt展开(嵌入Resource) → 发给LLM → LLM决定调Tool → Tool执行 → LLM生成最终回答
  ─────────────────────────────────────────────────────────────────────────────────→
  Server 端                   Host 端    LLM 端         Server 端    LLM 端
```

### 关键区分

- **Prompt + Resource**：在 Server 端展开时就完成了（Prompt 主动读取 Resource）
- **Prompt + Tool**：在 LLM 推理时才发生（LLM 看到 Prompt 上下文后自主决定调 Tool）

所以"三者叠加"本质上是对的，只是叠加的时机和主导者不同。
