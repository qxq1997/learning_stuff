# MCP - 第 10b 课：高级特性补充 Q&A

## Q1：MCP Server 做的事情可以分步骤吗？

**单个 Tool 调用是一次请求一次响应，但"分步骤"有三种实现方式：**

### 方式 1：LLM 自主编排多步调用（最常见）

```
用户："帮我分析 orders 表的性能问题并优化"

LLM 自主决定分步：
  第 1 步 → call_tool("describe_table", {table: "orders"})    ← 先看表结构
  第 2 步 → call_tool("run_select_query", {sql: "SELECT..."}) ← 再看数据分布
  第 3 步 → call_tool("explain_query", {sql: "SELECT..."})    ← 最后看执行计划

每一步都是独立的 Tool 调用，LLM 根据上一步的结果决定下一步做什么。
分步逻辑在 LLM 的推理中，不在 Server 中。
```

### 方式 2：Server 内部分步（对外是一次调用）

```python
@mcp.tool()
async def full_analysis(table: str, ctx: Context) -> str:
    """对表进行完整的性能分析"""
    await ctx.report_progress(1, 4)     # 报告进度
    schema = get_schema(table)

    await ctx.report_progress(2, 4)
    stats = get_statistics(table)

    await ctx.report_progress(3, 4)
    slow_queries = find_slow_queries(table)

    await ctx.report_progress(4, 4)
    return format_report(schema, stats, slow_queries)

# 对 Client 来说：一次 tools/call → 中间收到进度通知 → 一次最终响应
```

### 方式 3：Server 用 Sampling 在中间"思考"（最强大）

```python
@mcp.tool()
async def migrate_code(file_path: str, ctx: Context) -> str:
    """把 Java 8 代码迁移到 Java 17"""
    code = read_file(file_path)

    # 第 1 步：让 LLM 分析需要改什么（Sampling）
    analysis = await ctx.sample(
        messages=[{"role": "user", "content": f"分析需要哪些升级：\n{code}"}]
    )

    # 第 2 步：让 LLM 生成迁移后的代码（Sampling）
    migrated = await ctx.sample(
        messages=[{"role": "user", "content": f"改写代码：\n{analysis}"}]
    )

    write_file(file_path, migrated)
    return f"已迁移: {file_path}"
```

### 三种方式对比

| 方式 | 分步逻辑在哪 | Tool 调用次数 | 适用场景 |
| --- | --- | --- | --- |
| LLM 编排 | LLM 推理中 | 多次 | 每步需要 LLM 判断下一步做什么 |
| Server 内部 | Server 代码中 | 1 次 | 步骤固定，不需要 LLM 介入 |
| Sampling | Server + LLM 协作 | 1 次（但内部多次 Sampling） | 步骤中间需要 LLM 推理 |

---

## Q2：MCP 和 Skills 的本质区别是什么？

### 核心区别：代码运行在哪

```
┌─────────────────────────────────────────────────────────────┐
│                    Claude Code（Host）                       │
│                                                              │
│   ┌──────────────────────────┐  ┌─────────────────────────┐ │
│   │       Skills             │  │      MCP Clients        │ │
│   │                          │  │                         │ │
│   │  内置在 Host 中的能力     │  │  通过协议连接外部 Server │ │
│   │  Host 自己知道怎么做      │  │  Host 不知道细节        │ │
│   │                          │  │  Server 知道怎么做      │ │
│   │  /pdf → Host 内置逻辑    │  │                         │ │
│   │  /commit → Host 内置逻辑 │  │  Client A → GitHub Svr  │ │
│   │  /xlsx → Host 内置逻辑   │  │  Client B → DB Server   │ │
│   │                          │  │  Client C → 你的 Server │ │
│   └──────────────────────────┘  └─────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### 详细对比

| 维度 | Skills | MCP Server |
| --- | --- | --- |
| **本质** | Host 内置的功能模块 | 独立运行的外部服务 |
| **代码运行在哪** | Host 进程内部 | 独立进程（通过 stdio/HTTP 通信） |
| **谁开发** | Host 的开发者（如 Anthropic） | 任何人（你、社区、第三方） |
| **通信方式** | 函数调用（进程内） | JSON-RPC 协议（进程间） |
| **可扩展性** | ❌ 用户不能自己添加 Skill | ✅ 用户可以写自己的 Server |
| **标准化** | ❌ 每个 Host 的 Skill 系统不同 | ✅ 统一的 MCP 协议，跨 Host 通用 |
| **复用性** | ❌ 只能在特定 Host 中使用 | ✅ 一个 Server 可以接入任何 MCP Host |

### 类比

```
Skills ≈ 手机预装的 App
  ├── 出厂就有，你不能自己装新的
  ├── 深度集成，调用系统底层能力
  └── 只能在这款手机上用

MCP Server ≈ App Store 下载的 App
  ├── 任何人可以开发和发布
  ├── 通过标准 API 与系统交互
  └── 理论上可以在任何支持的手机上运行
```

### 未来趋势

```
现状：                              理想的未来：

Claude Code                        Claude Code
├── /pdf (内置 Skill)               ├── MCP Client → PDF Server
├── /xlsx (内置 Skill)              ├── MCP Client → XLSX Server
└── MCP Clients → 外部 Server      └── MCP Clients → 外部 Server

Cursor                             Cursor
├── 自己的 Skill 系统               ├── MCP Client → PDF Server（同一个！）
└── MCP Clients → 外部 Server      ├── MCP Client → XLSX Server（同一个！）
                                   └── MCP Clients → 外部 Server

现状：每个 Host 各搞各的 Skills     未来：通过 MCP 统一，一次开发到处运行
```

这正是 MCP 想解决的 M×N 问题的另一面——不仅是数据源/工具的标准化，也是 Host 内置能力本身的标准化。
