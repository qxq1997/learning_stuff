# MCP - 第 9 课：动手实践——用 Python 构建 MCP Client 并连接 Server

## 学习目标（本节结束后你能做到什么）

1. 用 Python SDK 写一个 MCP Client，连接到上一课的 Server
2. 理解 Host 应用如何集成 MCP Client + LLM 组成完整的 AI 应用
3. 实现一个完整的 Host：用户输入 → LLM 推理 → MCP 工具调用 → 返回结果
4. 彻底理解 Host / Client / Server / LLM 四者在代码层面的协作关系

---

## 一、本课的全景定位

前面 8 课的学习中，你已经从协议到 Server 都搞清楚了。但还有一个关键角色没动手写过——**Client 和 Host**。

在实际应用中，Claude Desktop、Cursor 这些产品就是 Host，它们内部集成了 MCP Client。但如果你要**自己构建一个 AI 应用**（比如一个内部的 AI 运维助手），你就需要自己写 Host + Client 的代码。

本课的目标就是**从零构建一个完整的 Host 应用**：

```
本课要构建的完整应用：

┌─────────────────────────────────────────────────────┐
│                  你的 Host 应用                       │
│                                                      │
│  ┌──────────────┐     ┌──────────────┐              │
│  │ 用户交互层    │     │  LLM API     │              │
│  │ (终端输入输出) │     │  (Claude)    │              │
│  └──────┬───────┘     └──────┬───────┘              │
│         │                    │                       │
│         ▼                    ▼                       │
│  ┌─────────────────────────────────────────────┐    │
│  │              Host 核心逻辑                    │    │
│  │  1. 收集所有 Client 的 Tool 列表              │    │
│  │  2. 用户消息 + Tool 列表 → LLM                │    │
│  │  3. LLM 返回 tool_use → 路由到对应 Client     │    │
│  │  4. Tool 结果 → 回传 LLM → 生成最终回答       │    │
│  └──────────────────┬──────────────────────────┘    │
│                     │                                │
│         ┌───────────┼───────────┐                   │
│         ▼           ▼           ▼                   │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐            │
│  │ Client A │ │ Client B │ │ Client C │            │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘            │
│       │            │            │                    │
└───────│────────────│────────────│────────────────────┘
        │stdio       │stdio       │HTTP
        ▼            ▼            ▼
  ┌──────────┐ ┌──────────┐ ┌──────────┐
  │ Server A │ │ Server B │ │ Server C │
  └──────────┘ └──────────┘ └──────────┘
```

---

## 二、最小可运行的 Client：连接并调用

先从最简单的情况开始——一个 Client 连接一个 Server，调用一个 Tool：

```python
# simple_client.py
import asyncio
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

async def main():
    # ============================================================
    # 第一步：定义 Server 的启动参数
    # ============================================================
    server_params = StdioServerParameters(
        command="python",                    # 启动命令
        args=["server.py"],                  # 命令参数
        env=None,                            # 环境变量（可选）
    )

    # ============================================================
    # 第二步：建立连接（启动 Server 进程 + stdio 管道）
    # ============================================================
    async with stdio_client(server_params) as (read_stream, write_stream):

        # ============================================================
        # 第三步：创建 Client Session（处理协议层）
        # ============================================================
        async with ClientSession(read_stream, write_stream) as session:

            # ============================================================
            # 第四步：初始化握手
            # ============================================================
            await session.initialize()
            # initialize() 内部做了：
            #   1. 发送 initialize 请求（带 protocolVersion + capabilities）
            #   2. 接收 Server 的 initialize 响应
            #   3. 发送 initialized 通知
            #   → 三步握手完成，进入 Running 状态

            # ============================================================
            # 第五步：发现 Server 的能力
            # ============================================================
            tools_result = await session.list_tools()
            print("可用的 Tools：")
            for tool in tools_result.tools:
                print(f"  - {tool.name}: {tool.description}")

            resources_result = await session.list_resources()
            print("\n可用的 Resources：")
            for resource in resources_result.resources:
                print(f"  - {resource.uri}: {resource.name}")

            prompts_result = await session.list_prompts()
            print("\n可用的 Prompts：")
            for prompt in prompts_result.prompts:
                print(f"  - {prompt.name}: {prompt.description}")

            # ============================================================
            # 第六步：调用一个 Tool
            # ============================================================
            result = await session.call_tool(
                "create_note",
                arguments={
                    "title": "我的第一条笔记",
                    "content": "通过 MCP Client 创建的笔记！",
                    "tags": ["测试", "MCP"]
                }
            )
            print(f"\nTool 调用结果：{result.content[0].text}")

            # ============================================================
            # 第七步：读取一个 Resource
            # ============================================================
            resource = await session.read_resource("notes://list")
            print(f"\n笔记列表：{resource.contents[0].text}")


asyncio.run(main())
```

### 运行效果

```bash
$ python simple_client.py

可用的 Tools：
  - create_note: 创建一条新的笔记...
  - search_notes: 搜索笔记...
  - delete_note: 【需要确认】删除指定标题的笔记...

可用的 Resources：
  - notes://list: 所有笔记的概览列表

可用的 Prompts：
  - summarize_notes: 对笔记进行总结分析
  - write_from_notes: 基于已有笔记撰写一篇文章

Tool 调用结果：笔记已创建：notes/我的第一条笔记.json
标题：我的第一条笔记
标签：测试, MCP
字数：18

笔记列表：[{"title": "我的第一条笔记", ...}]
```

### 代码与协议的对应关系

```
你写的 Client 代码                     底层的 JSON-RPC 消息
──────────────                         ────────────────

stdio_client(server_params)       →    fork 进程 python server.py
                                       建立 stdin/stdout 管道

session.initialize()              →    → {"method":"initialize","params":{...}}
                                       ← {"result":{"capabilities":{...}}}
                                       → {"method":"notifications/initialized"}

session.list_tools()              →    → {"method":"tools/list"}
                                       ← {"result":{"tools":[...]}}

session.call_tool("create_note",  →    → {"method":"tools/call",
  arguments={...})                        "params":{"name":"create_note",
                                                    "arguments":{...}}}
                                       ← {"result":{"content":[...]}}

session.read_resource(uri)        →    → {"method":"resources/read",
                                          "params":{"uri":"notes://list"}}
                                       ← {"result":{"contents":[...]}}
```

---

## 三、完整 Host 应用：集成 LLM + MCP

上面的 simple_client 只是直接调用 Tool，没有 LLM 参与。真正的 AI 应用需要 **LLM 来决定什么时候调什么 Tool**。

下面构建一个完整的 Host 应用——一个命令行 AI 助手：

```python
# host_app.py
import asyncio
import json
from anthropic import Anthropic
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

class MCPHost:
    """一个完整的 MCP Host 应用：终端 AI 助手"""

    def __init__(self):
        self.anthropic = Anthropic()       # Claude API 客户端
        self.sessions: dict[str, ClientSession] = {}   # server名 → session
        self.tools: list[dict] = []        # 汇总的全局 Tool 列表
        self.tool_to_session: dict[str, str] = {}  # tool名 → server名（路由表）
        self.conversation: list[dict] = [] # 对话历史

    # ================================================================
    # 第一阶段：连接所有 MCP Server
    # ================================================================

    async def connect_server(self, name: str, command: str, args: list[str]):
        """连接一个 MCP Server 并发现其能力"""
        server_params = StdioServerParameters(
            command=command,
            args=args,
        )

        # 建立 stdio 连接
        read_stream, write_stream = await self._start_server(server_params)
        session = ClientSession(read_stream, write_stream)
        await session.__aenter__()

        # 初始化握手
        await session.initialize()
        self.sessions[name] = session

        # 发现 Tools 并注册到路由表
        tools_result = await session.list_tools()
        for tool in tools_result.tools:
            # 加前缀避免命名冲突
            prefixed_name = f"{name}__{tool.name}"
            self.tools.append({
                "name": prefixed_name,
                "description": f"[{name}] {tool.description}",
                "input_schema": tool.inputSchema,
            })
            self.tool_to_session[prefixed_name] = name

        print(f"✅ 已连接 Server '{name}'，发现 {len(tools_result.tools)} 个 Tools")

    async def _start_server(self, params):
        """启动 Server 进程，返回读写流"""
        transport = stdio_client(params)
        read_stream, write_stream = await transport.__aenter__()
        return read_stream, write_stream

    # ================================================================
    # 第二阶段：对话循环（核心逻辑）
    # ================================================================

    async def chat(self, user_message: str) -> str:
        """处理一轮对话：用户消息 → LLM → (可能的 Tool 调用) → 最终回答"""

        # 1. 用户消息加入对话历史
        self.conversation.append({
            "role": "user",
            "content": user_message,
        })

        # 2. 调用 LLM（带 Tool 列表）
        response = self.anthropic.messages.create(
            model="claude-sonnet-4-20250514",
            max_tokens=4096,
            messages=self.conversation,
            tools=self.tools,      # ← 把汇总的 Tool 列表传给 LLM
        )

        # 3. 处理 LLM 的响应（可能需要多轮 Tool 调用）
        return await self._process_response(response)

    async def _process_response(self, response) -> str:
        """
        处理 LLM 响应。

        LLM 可能返回：
        - 纯文本 → 直接作为最终回答
        - tool_use → 执行 Tool，把结果传回 LLM，继续推理
        - 混合（文本 + tool_use）→ 先执行 Tool，再继续
        """

        # 收集 assistant 消息的所有 content blocks
        assistant_content = []
        final_text = ""

        for block in response.content:
            if block.type == "text":
                final_text += block.text
                assistant_content.append({
                    "type": "text",
                    "text": block.text,
                })

            elif block.type == "tool_use":
                assistant_content.append({
                    "type": "tool_use",
                    "id": block.id,
                    "name": block.name,
                    "input": block.input,
                })

        # 把 assistant 消息加入对话历史
        self.conversation.append({
            "role": "assistant",
            "content": assistant_content,
        })

        # 如果 LLM 要求调用 Tool
        if response.stop_reason == "tool_use":
            tool_results = []

            for block in response.content:
                if block.type != "tool_use":
                    continue

                tool_name = block.name          # 如 "notes__create_note"
                tool_input = block.input        # 如 {"title": "...", ...}

                print(f"  🔧 调用工具: {tool_name}")

                # 从路由表找到对应的 Server
                server_name = self.tool_to_session[tool_name]
                session = self.sessions[server_name]

                # 去掉前缀，还原原始 Tool 名
                original_name = tool_name.split("__", 1)[1]

                # 通过 MCP 协议调用 Tool
                result = await session.call_tool(original_name, arguments=tool_input)

                # 收集 Tool 结果
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": block.id,
                    "content": result.content[0].text if result.content else "无返回",
                })

            # 把 Tool 结果加入对话历史
            self.conversation.append({
                "role": "user",
                "content": tool_results,
            })

            # 继续调 LLM（带上 Tool 结果，让 LLM 生成最终回答）
            next_response = self.anthropic.messages.create(
                model="claude-sonnet-4-20250514",
                max_tokens=4096,
                messages=self.conversation,
                tools=self.tools,
            )

            # 递归处理（LLM 可能还要继续调 Tool）
            return await self._process_response(next_response)

        # LLM 不需要调 Tool，直接返回文本
        return final_text


# ================================================================
# 主程序：终端交互循环
# ================================================================

async def main():
    host = MCPHost()

    # 连接 MCP Server（可以连接多个）
    await host.connect_server(
        name="notes",
        command="python",
        args=["server.py"],
    )
    # 如果有更多 Server：
    # await host.connect_server("github", "npx", ["-y", "@modelcontextprotocol/server-github"])
    # await host.connect_server("db", "python", ["db_server.py"])

    print("\n🤖 AI 助手已就绪（输入 'quit' 退出）\n")

    # 对话循环
    while True:
        user_input = input("你: ").strip()
        if user_input.lower() in ("quit", "exit", "q"):
            break
        if not user_input:
            continue

        response = await host.chat(user_input)
        print(f"\n助手: {response}\n")


asyncio.run(main())
```

---

## 四、Host 核心逻辑图解

上面的代码最核心的是 `chat()` 方法和 `_process_response()` 方法。用流程图来理解：

```
用户输入: "帮我创建一条关于 Python 装饰器的笔记"
│
▼
┌──────────────────────────────────────────────────────┐
│ chat()                                                │
│                                                       │
│  1. conversation.append(user_message)                 │
│                                                       │
│  2. anthropic.messages.create(                        │
│       messages = conversation,                        │
│       tools = [notes__create_note,                    │
│                notes__search_notes,                   │
│                notes__delete_note]                    │
│     )                                                 │
└──────────────────┬───────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────┐
│ LLM 返回:                                            │
│                                                       │
│ {                                                     │
│   "stop_reason": "tool_use",        ← LLM 要调 Tool  │
│   "content": [                                        │
│     { "type": "text",                                 │
│       "text": "好的，我来帮你创建..." },               │
│     { "type": "tool_use",                             │
│       "id": "call_001",                               │
│       "name": "notes__create_note",                   │
│       "input": {                                      │
│         "title": "Python装饰器详解",                   │
│         "content": "装饰器是Python中...",              │
│         "tags": ["Python", "学习"]                    │
│       }                                               │
│     }                                                 │
│   ]                                                   │
│ }                                                     │
└──────────────────┬───────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────┐
│ _process_response()                                   │
│                                                       │
│  stop_reason == "tool_use"  → 需要执行 Tool           │
│                                                       │
│  1. 查路由表: notes__create_note → server "notes"     │
│  2. 去前缀: notes__create_note → create_note          │
│  3. session.call_tool("create_note", arguments={...}) │
│     │                                                 │
│     │  ┌──────────── MCP 协议 ────────────┐          │
│     └──→ JSON-RPC: tools/call              │          │
│         │                      notes-server│          │
│         ← 返回: "笔记已创建..."             │          │
│         └─────────────────────────────────┘          │
│                                                       │
│  4. 把 Tool 结果加入 conversation                      │
│  5. 再次调用 LLM（带上 Tool 结果）                      │
└──────────────────┬───────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────┐
│ LLM 第二次返回:                                       │
│                                                       │
│ {                                                     │
│   "stop_reason": "end_turn",    ← 不需要再调 Tool     │
│   "content": [                                        │
│     { "type": "text",                                 │
│       "text": "已经帮你创建了笔记《Python装饰器详解》，  │
│                标签是 Python 和 学习..."                │
│     }                                                 │
│   ]                                                   │
│ }                                                     │
└──────────────────┬───────────────────────────────────┘
                   │
                   ▼
            返回给用户显示
```

### 对话历史（conversation）的变化过程

理解 conversation 数组的变化非常关键——它就是 LLM 的"记忆"：

```
初始状态：conversation = []

─── 用户输入后 ───
conversation = [
  { role: "user", content: "帮我创建一条关于 Python 装饰器的笔记" }
]

─── LLM 第一次返回后（要调 Tool）───
conversation = [
  { role: "user", content: "帮我创建..." },
  { role: "assistant", content: [
      { type: "text", text: "好的，我来帮你创建..." },
      { type: "tool_use", id: "call_001", name: "notes__create_note", input: {...} }
  ]}
]

─── Tool 执行完后 ───
conversation = [
  { role: "user", content: "帮我创建..." },
  { role: "assistant", content: [ text + tool_use ] },
  { role: "user", content: [
      { type: "tool_result", tool_use_id: "call_001", content: "笔记已创建..." }
  ]}
]

─── LLM 第二次返回后（最终回答）───
conversation = [
  { role: "user", content: "帮我创建..." },
  { role: "assistant", content: [ text + tool_use ] },
  { role: "user", content: [ tool_result ] },
  { role: "assistant", content: [
      { type: "text", text: "已经帮你创建了笔记..." }
  ]}
]
```

**注意**：tool_result 的 role 是 `"user"` 而不是一个独立的 role。这是 Claude API 的设计——Tool 的返回结果被视为"用户提供的额外信息"传回给 LLM。

---

## 五、多 Server 路由机制

当 Host 连接了多个 Server 时，路由是怎么工作的？

```
连接阶段：

connect_server("notes", "python", ["server.py"])
  → 发现 Tools: [create_note, search_notes, delete_note]
  → 注册路由:
     notes__create_note  → session["notes"]
     notes__search_notes → session["notes"]
     notes__delete_note  → session["notes"]

connect_server("github", "npx", ["@mcp/server-github"])
  → 发现 Tools: [list_pr, create_issue, merge_pr]
  → 注册路由:
     github__list_pr      → session["github"]
     github__create_issue  → session["github"]
     github__merge_pr      → session["github"]

最终路由表：
┌──────────────────────┬─────────────────┐
│ Tool 名称（带前缀）   │ 归属 Session     │
├──────────────────────┼─────────────────┤
│ notes__create_note    │ sessions["notes"]│
│ notes__search_notes   │ sessions["notes"]│
│ notes__delete_note    │ sessions["notes"]│
│ github__list_pr       │ sessions["github"]│
│ github__create_issue  │ sessions["github"]│
│ github__merge_pr      │ sessions["github"]│
└──────────────────────┴─────────────────┘

传给 LLM 的 tools 列表：
[
  {name: "notes__create_note", description: "[notes] 创建一条新的笔记...", ...},
  {name: "notes__search_notes", description: "[notes] 搜索笔记...", ...},
  ...
  {name: "github__list_pr", description: "[github] 列出仓库的PR...", ...},
  ...
]
```

调用阶段：

```
LLM 返回: tool_use name="github__list_pr"
│
▼
Host 查路由表:
  github__list_pr → sessions["github"]

去掉前缀:
  github__list_pr → list_pr

调用:
  sessions["github"].call_tool("list_pr", arguments={...})
│
▼
通过 MCP 协议到达 GitHub Server
```

**LLM 看到的是带前缀的 Tool 名（`github__list_pr`），Server 看到的是原始 Tool 名（`list_pr`），Host 在中间做翻译。**

---

## 六、整体架构对照：代码 vs 协议 vs 角色

```
代码中的类/对象              MCP 协议角色           做的事情
────────────                ──────────            ──────────

MCPHost 类                  Host                  管理多个 Client
├── self.anthropic          (LLM API)             调用 Claude 做推理
├── self.sessions           多个 Client            每个对应一个 Server
├── self.tools              全局 Tool 列表         汇总所有 Server 的 Tools
├── self.tool_to_session    路由表                 Tool名 → 对应的 Session
│
├── connect_server()        初始化阶段             建连接 + 握手 + 发现能力
├── chat()                  运行阶段               用户消息 → LLM → 工具调用
└── _process_response()     运行阶段               处理 LLM 响应，执行 Tool

ClientSession               Client                与单个 Server 的 1:1 连接
├── initialize()            三步握手               版本协商 + 能力声明
├── list_tools()            能力发现               tools/list
├── call_tool()             工具调用               tools/call
├── list_resources()        能力发现               resources/list
├── read_resource()         资源读取               resources/read
├── list_prompts()          能力发现               prompts/list
└── get_prompt()            获取 Prompt            prompts/get

stdio_client()              传输层                 启动 Server 进程 + stdio 管道
```

---

## 七、生产环境的注意事项

上面的代码是教学版本，生产环境还需要考虑：

### 7.1 错误处理

```python
# 教学版本（忽略了错误处理）
result = await session.call_tool(name, arguments=args)

# 生产版本
try:
    result = await session.call_tool(name, arguments=args)
    if result.isError:
        # 业务错误（Tool 执行了但失败了）
        return f"工具执行失败: {result.content[0].text}"
except McpError as e:
    # 协议错误（Tool 不存在、参数格式错）
    return f"MCP 协议错误: {e}"
except ConnectionError:
    # 连接断开
    await self.reconnect(server_name)
    return "连接中断，正在重连..."
```

### 7.2 超时控制

```python
import asyncio

# 给 Tool 调用设置超时
try:
    result = await asyncio.wait_for(
        session.call_tool(name, arguments=args),
        timeout=30.0  # 30 秒超时
    )
except asyncio.TimeoutError:
    # 发送取消通知
    await session.send_notification(
        "notifications/cancelled",
        {"requestId": request_id}
    )
    return "工具调用超时，已取消"
```

### 7.3 权限确认

```python
# 在调用有副作用的 Tool 前，询问用户
DANGEROUS_TOOLS = {"delete_note", "drop_table", "merge_pr"}

async def call_tool_with_confirmation(self, tool_name, arguments):
    original_name = tool_name.split("__", 1)[1]

    if original_name in DANGEROUS_TOOLS:
        print(f"\n⚠️  即将执行危险操作: {tool_name}")
        print(f"   参数: {json.dumps(arguments, ensure_ascii=False)}")
        confirm = input("   确认执行？(y/n): ")
        if confirm.lower() != "y":
            return "用户取消了操作"

    return await session.call_tool(original_name, arguments=arguments)
```

---

## 八、运行完整 Demo

确保上一课的 `server.py`（笔记管理 Server）和本课的 `host_app.py` 在同一目录下：

```bash
$ python host_app.py

✅ 已连接 Server 'notes'，发现 3 个 Tools

🤖 AI 助手已就绪（输入 'quit' 退出）

你: 帮我创建一条关于 Python 装饰器的笔记
  🔧 调用工具: notes__create_note

助手: 已经帮你创建了笔记《Python装饰器详解》，标签是 Python 和 学习。

你: 搜索一下有哪些笔记
  🔧 调用工具: notes__search_notes

助手: 找到了 2 条笔记：
1. 《Python装饰器详解》- 标签: Python, 学习
2. 《我的第一条笔记》- 标签: 测试, MCP

你: quit
```

---

## 小结

1. **Client 的核心 API**：`stdio_client()` 建连接 → `ClientSession` 管协议 → `initialize()` 握手 → `list_tools()` 发现 → `call_tool()` 调用
2. **Host 的核心职责**：汇总多个 Client 的 Tool 列表 → 传给 LLM → 根据 LLM 的 tool_use 响应路由到对应 Client → 把 Tool 结果传回 LLM
3. **对话历史是关键**：conversation 数组记录了完整的对话过程（user → assistant(tool_use) → user(tool_result) → assistant(最终回答)），LLM 通过这个历史理解上下文
4. **多 Server 路由**：Tool 名加前缀避免冲突，Host 维护路由表做分发
5. **生产环境额外考虑**：错误处理、超时控制、权限确认、断线重连

---

> **下一课预告**：MCP 高级特性——Sampling（Server 请求 Client 帮忙调 LLM）、Roots（工作目录共享）和安全模型深入。

请告诉我你对这课内容的理解，或者有什么疑问？
