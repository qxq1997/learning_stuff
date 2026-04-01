# MCP - 第 8 课：动手实践——用 Python 从零构建一个 MCP Server

## 学习目标（本节结束后你能做到什么）

1. 用 Python 官方 SDK 从零写出一个可运行的 MCP Server
2. 为 Server 实现 Tools、Resources、Prompts 三种能力
3. 把 Server 接入 Claude Desktop / Claude Code 并实际使用
4. 理解 SDK 底层帮你做了什么（对照前面学的协议知识）

---

## 一、开发环境准备

### 1.1 技术选型

MCP 官方提供了两个 SDK：

| SDK | 语言 | 包名 | 适合场景 |
| --- | --- | --- | --- |
| TypeScript SDK | Node.js | `@modelcontextprotocol/sdk` | 前端/全栈工程师，或需要和 Node 生态集成 |
| Python SDK | Python 3.10+ | `mcp` | 后端工程师，或需要调用 Python 生态库（pandas、SQLAlchemy 等） |

你是后端工程师，我们用 **Python SDK**。

### 1.2 安装

```bash
# 推荐用 uv（Anthropic 官方推荐的 Python 包管理工具，比 pip 快很多）
# 安装 uv
curl -LsSf https://astral.sh/uv/install.sh | sh

# 创建项目
mkdir my-mcp-server && cd my-mcp-server
uv init
uv add mcp

# 如果你习惯用 pip，也可以：
pip install mcp
```

### 1.3 项目结构

我们要构建一个**笔记管理 MCP Server**——让 LLM 能够创建、搜索、读取笔记。这个例子足够简单，但覆盖了三种核心能力。

```
my-mcp-server/
├── server.py          ← 主文件，MCP Server 实现
├── pyproject.toml     ← 项目配置
└── notes/             ← 笔记存储目录（运行时自动创建）
```

---

## 二、最小可运行的 MCP Server

先从最简单的版本开始——一个只有一个 Tool 的 Server：

```python
# server.py
from mcp.server.fastmcp import FastMCP

# 创建 Server 实例
# name 会出现在初始化握手的 serverInfo 中
mcp = FastMCP("notes-server")

# 用装饰器定义一个 Tool
@mcp.tool()
def hello(name: str) -> str:
    """向指定的人打招呼。这是一个示例 Tool，用于验证 Server 是否正常工作。"""
    return f"你好，{name}！MCP Server 运行正常。"

# 启动 Server（默认使用 stdio 传输）
if __name__ == "__main__":
    mcp.run()
```

**就这么几行代码，一个可运行的 MCP Server 就写好了。**

让我们对照之前学的协议知识，看看 SDK 帮你做了什么：

```
你写的代码                          SDK 在底层帮你做的
──────────                          ────────────────

FastMCP("notes-server")        →    注册 serverInfo: {name: "notes-server"}

@mcp.tool()                    →    1. 解析函数签名，生成 inputSchema
def hello(name: str) -> str:        2. 把函数的 docstring 作为 description
    """向指定的人打招呼..."""         3. 注册到 tools/list 的返回列表中
                                    4. 当 tools/call 请求到来时，调用这个函数

mcp.run()                      →    1. 监听 stdin，读取 JSON-RPC 消息
                                    2. 处理 initialize 握手（版本协商、能力声明）
                                    3. 发送 initialized 通知
                                    4. 进入主循环，分发请求到对应的 handler
                                    5. 把返回值包装成 JSON-RPC 响应写入 stdout
```

### 测试运行

```bash
# 直接运行，看看是否报错
python server.py

# 此时 Server 在等待 stdin 输入
# 你可以手动输入 JSON-RPC 消息测试（不过通常我们直接接入 Host 测试）
```

---

## 三、完整实现：笔记管理 Server

现在来构建完整版本，实现三种核心能力：

```python
# server.py
import os
import json
from datetime import datetime
from pathlib import Path
from mcp.server.fastmcp import FastMCP

# ============================================================
# 初始化
# ============================================================

# 笔记存储目录
NOTES_DIR = Path("./notes")
NOTES_DIR.mkdir(exist_ok=True)

# 创建 Server
mcp = FastMCP("notes-server")


# ============================================================
# Tools：让 LLM "动手做事"
# ============================================================

@mcp.tool()
def create_note(title: str, content: str, tags: list[str] | None = None) -> str:
    """创建一条新的笔记。

    将笔记保存为 JSON 文件。标题会被用作文件名（自动处理特殊字符）。
    创建成功后返回笔记的文件路径和摘要信息。

    Args:
        title: 笔记标题，例如 "会议记录-2024年Q4规划"
        content: 笔记正文内容，支持 Markdown 格式
        tags: 可选的标签列表，例如 ["工作", "重要"]。用于后续搜索和分类。
    """
    # 生成安全的文件名
    safe_title = "".join(c if c.isalnum() or c in "-_ " else "_" for c in title)
    filename = f"{safe_title}.json"
    filepath = NOTES_DIR / filename

    note = {
        "title": title,
        "content": content,
        "tags": tags or [],
        "created_at": datetime.now().isoformat(),
        "updated_at": datetime.now().isoformat(),
    }

    with open(filepath, "w", encoding="utf-8") as f:
        json.dump(note, f, ensure_ascii=False, indent=2)

    return f"笔记已创建：{filepath}\n标题：{title}\n标签：{', '.join(tags or [])}\n字数：{len(content)}"


@mcp.tool()
def search_notes(keyword: str, tag: str | None = None) -> str:
    """搜索笔记。

    在所有笔记的标题和内容中搜索关键词。可选按标签过滤。
    返回匹配的笔记列表（标题、标签、创建时间、内容摘要）。

    Args:
        keyword: 搜索关键词，在标题和内容中进行模糊匹配（不区分大小写）
        tag: 可选的标签过滤，只返回包含此标签的笔记
    """
    results = []

    for filepath in NOTES_DIR.glob("*.json"):
        try:
            with open(filepath, "r", encoding="utf-8") as f:
                note = json.load(f)

            # 关键词匹配
            keyword_lower = keyword.lower()
            if (keyword_lower not in note["title"].lower()
                    and keyword_lower not in note["content"].lower()):
                continue

            # 标签过滤
            if tag and tag not in note.get("tags", []):
                continue

            # 生成摘要（前 100 字）
            summary = note["content"][:100]
            if len(note["content"]) > 100:
                summary += "..."

            results.append(
                f"📝 {note['title']}\n"
                f"   标签: {', '.join(note.get('tags', []))}\n"
                f"   创建: {note['created_at']}\n"
                f"   摘要: {summary}\n"
            )
        except (json.JSONDecodeError, KeyError):
            continue

    if not results:
        return f"未找到包含 '{keyword}' 的笔记。"

    return f"找到 {len(results)} 条匹配的笔记：\n\n" + "\n".join(results)


@mcp.tool()
def delete_note(title: str) -> str:
    """【需要确认】删除指定标题的笔记。

    此操作不可撤销。删除后笔记文件将被永久移除。

    Args:
        title: 要删除的笔记标题（必须精确匹配）
    """
    safe_title = "".join(c if c.isalnum() or c in "-_ " else "_" for c in title)
    filename = f"{safe_title}.json"
    filepath = NOTES_DIR / filename

    if not filepath.exists():
        return f"错误：未找到标题为 '{title}' 的笔记。"

    os.remove(filepath)
    return f"笔记 '{title}' 已被删除。"


# ============================================================
# Resources：让 LLM "看到数据"
# ============================================================

@mcp.resource("notes://list")
def list_all_notes() -> str:
    """所有笔记的概览列表，包含标题、标签和创建时间。"""
    notes = []

    for filepath in sorted(NOTES_DIR.glob("*.json")):
        try:
            with open(filepath, "r", encoding="utf-8") as f:
                note = json.load(f)
            notes.append({
                "title": note["title"],
                "tags": note.get("tags", []),
                "created_at": note["created_at"],
                "word_count": len(note["content"]),
            })
        except (json.JSONDecodeError, KeyError):
            continue

    if not notes:
        return "暂无笔记。"

    return json.dumps(notes, ensure_ascii=False, indent=2)


@mcp.resource("notes://{title}")
def get_note_content(title: str) -> str:
    """获取指定标题的笔记完整内容。"""
    safe_title = "".join(c if c.isalnum() or c in "-_ " else "_" for c in title)
    filename = f"{safe_title}.json"
    filepath = NOTES_DIR / filename

    if not filepath.exists():
        return f"错误：未找到标题为 '{title}' 的笔记。"

    with open(filepath, "r", encoding="utf-8") as f:
        note = json.load(f)

    return json.dumps(note, ensure_ascii=False, indent=2)


# ============================================================
# Prompts：让 LLM "按套路出牌"
# ============================================================

@mcp.prompt()
def summarize_notes(tag: str | None = None) -> str:
    """对笔记进行总结分析。

    汇总所有笔记（或指定标签的笔记），生成一份结构化的总结报告。

    Args:
        tag: 可选，只总结包含此标签的笔记
    """
    # 收集笔记内容
    notes_text = []
    for filepath in sorted(NOTES_DIR.glob("*.json")):
        try:
            with open(filepath, "r", encoding="utf-8") as f:
                note = json.load(f)

            if tag and tag not in note.get("tags", []):
                continue

            notes_text.append(f"## {note['title']}\n标签: {', '.join(note.get('tags', []))}\n\n{note['content']}")
        except (json.JSONDecodeError, KeyError):
            continue

    if not notes_text:
        filter_msg = f"（标签: {tag}）" if tag else ""
        return f"没有找到{filter_msg}笔记可供总结。"

    all_notes = "\n\n---\n\n".join(notes_text)

    return (
        f"请对以下{len(notes_text)}条笔记进行总结分析：\n\n"
        f"要求：\n"
        f"1. **主题归纳**：这些笔记涵盖了哪些主题\n"
        f"2. **关键要点**：提取每条笔记的核心观点（每条 1-2 句话）\n"
        f"3. **关联发现**：不同笔记之间有哪些关联或矛盾\n"
        f"4. **知识空白**：基于这些笔记，还有哪些方面值得进一步探索\n\n"
        f"以下是笔记内容：\n\n{all_notes}"
    )


@mcp.prompt()
def write_from_notes(topic: str) -> str:
    """基于已有笔记撰写一篇文章。

    从笔记中提取相关素材，围绕指定主题撰写结构化文章。

    Args:
        topic: 文章主题，例如 "MCP 协议的设计哲学"
    """
    # 收集所有笔记作为素材
    notes_text = []
    for filepath in sorted(NOTES_DIR.glob("*.json")):
        try:
            with open(filepath, "r", encoding="utf-8") as f:
                note = json.load(f)
            notes_text.append(f"[{note['title']}]: {note['content'][:200]}")
        except (json.JSONDecodeError, KeyError):
            continue

    notes_context = "\n".join(notes_text) if notes_text else "（暂无笔记素材）"

    return (
        f"请基于以下笔记素材，围绕主题「{topic}」撰写一篇文章。\n\n"
        f"要求：\n"
        f"1. 从笔记中提取相关内容作为论据和素材\n"
        f"2. 文章结构清晰：引言 → 正文（分 3-5 个小节）→ 结论\n"
        f"3. 如果笔记素材不足以覆盖主题，标注哪些部分需要补充\n"
        f"4. 保持专业但易懂的语气\n\n"
        f"可用的笔记素材：\n{notes_context}"
    )


# ============================================================
# 启动 Server
# ============================================================

if __name__ == "__main__":
    mcp.run()
```

### 代码与协议概念的对应关系图

```
你写的 Python 代码                      对应的 MCP 协议概念
────────────────                        ────────────────

FastMCP("notes-server")            →    serverInfo.name

@mcp.tool()                        →    tools/list 返回的 Tool 定义
def create_note(title, content):        ├── name: "create_note"
    """创建一条新的笔记..."""              ├── description: docstring 内容
                                        └── inputSchema: 从函数签名自动生成
                                            {
                                              "properties": {
                                                "title": {"type": "string"},
                                                "content": {"type": "string"},
                                                "tags": {"type": "array", ...}
                                              },
                                              "required": ["title", "content"]
                                            }

@mcp.resource("notes://list")      →    resources/list 返回的 Resource
def list_all_notes():                   ├── uri: "notes://list"
    """所有笔记的概览列表..."""            └── description: docstring 内容

@mcp.resource("notes://{title}")   →    resources/templates/list 返回的模板
def get_note_content(title):            └── uriTemplate: "notes://{title}"
    """获取指定标题的笔记..."""

@mcp.prompt()                      →    prompts/list 返回的 Prompt
def summarize_notes(tag=None):          ├── name: "summarize_notes"
    """对笔记进行总结分析..."""            ├── description: docstring 内容
                                        └── arguments: 从函数参数自动生成
                                            [{"name": "tag", "required": false}]

mcp.run()                          →    启动 stdio 传输层
                                        ├── 监听 stdin
                                        ├── 处理 initialize 握手
                                        ├── 分发请求到 handler
                                        └── 写响应到 stdout
```

**FastMCP 的设计哲学**是：让你写普通的 Python 函数，SDK 自动帮你处理所有协议细节。你不需要手动写 JSON-RPC 消息、不需要手动实现握手、不需要手动生成 inputSchema——**SDK 通过 Python 的类型注解和 docstring 自动推导**。

---

## 四、接入 Host 实际使用

### 4.1 接入 Claude Desktop

编辑 Claude Desktop 的配置文件：

```
macOS: ~/Library/Application Support/Claude/claude_desktop_config.json
Windows: %APPDATA%\Claude\claude_desktop_config.json
```

```json
{
  "mcpServers": {
    "notes": {
      "command": "python",
      "args": ["/absolute/path/to/my-mcp-server/server.py"],
      "env": {}
    }
  }
}
```

重启 Claude Desktop，你就能在对话中使用笔记管理的功能了。

```
用户在 Claude Desktop 中：

"帮我创建一条笔记，标题是 MCP学习心得，
 内容是今天学了 MCP 的三大核心能力...标签设为 学习"

→ Claude 自动调用 create_note Tool
→ 笔记被保存到 notes/ 目录
→ Claude 回复："已经帮你创建了笔记 MCP学习心得..."
```

### 4.2 接入 Claude Code

Claude Code 的 MCP 配置在 `~/.claude/config.json` 或项目级的 `.mcp.json`：

```json
{
  "mcpServers": {
    "notes": {
      "command": "python",
      "args": ["/absolute/path/to/my-mcp-server/server.py"]
    }
  }
}
```

### 4.3 使用 MCP Inspector 调试

MCP 官方提供了一个调试工具 **MCP Inspector**，可以在浏览器里直接测试你的 Server：

```bash
# 安装并启动 Inspector
npx @modelcontextprotocol/inspector python server.py
```

Inspector 会在浏览器中打开一个 UI：

```
┌─────────────────────────────────────────────────┐
│  MCP Inspector                                    │
│                                                   │
│  Server: notes-server (connected ✅)              │
│                                                   │
│  ┌─── Tools ──────────────────────────────────┐  │
│  │ ▶ create_note                               │  │
│  │ ▶ search_notes                              │  │
│  │ ▶ delete_note                               │  │
│  └─────────────────────────────────────────────┘  │
│                                                   │
│  ┌─── Resources ──────────────────────────────┐  │
│  │ ▶ notes://list                              │  │
│  │ ▶ notes://{title}  (template)               │  │
│  └─────────────────────────────────────────────┘  │
│                                                   │
│  ┌─── Prompts ────────────────────────────────┐  │
│  │ ▶ summarize_notes                           │  │
│  │ ▶ write_from_notes                          │  │
│  └─────────────────────────────────────────────┘  │
│                                                   │
│  点击任意项可以填参数并测试调用                      │
└─────────────────────────────────────────────────┘
```

Inspector 是开发 MCP Server 时**最有用的调试工具**——你可以直接看到 Server 暴露了哪些能力、手动填参数测试调用、查看请求和响应的原始 JSON-RPC 消息。

---

## 五、SDK 底层做了什么？（拆解魔法）

FastMCP 的装饰器看起来很"魔法"，但底层做的事情其实就是我们前面学的协议流程。拆解一下：

### 5.1 @mcp.tool() 的底层

```python
@mcp.tool()
def create_note(title: str, content: str, tags: list[str] | None = None) -> str:
    """创建一条新的笔记..."""
```

SDK 内部做了这些事：

```
1. 解析函数签名（通过 Python 的 inspect 模块 + typing）：
   ├── 参数 title: str → {"type": "string"}, required
   ├── 参数 content: str → {"type": "string"}, required
   └── 参数 tags: list[str] | None = None → {"type": "array", ...}, optional

2. 生成 Tool 定义：
   {
     "name": "create_note",
     "description": "创建一条新的笔记...",  ← 来自 docstring
     "inputSchema": {
       "type": "object",
       "properties": {
         "title": {"type": "string", "description": "..."},
         "content": {"type": "string", "description": "..."},
         "tags": {"type": "array", "items": {"type": "string"}, ...}
       },
       "required": ["title", "content"]
     }
   }

3. 注册 handler：
   当收到 tools/call name="create_note" 时 → 调用这个函数

4. 包装返回值：
   函数返回 str → 包装成 {"content": [{"type": "text", "text": "..."}]}
```

### 5.2 @mcp.resource() 的底层

```python
@mcp.resource("notes://{title}")
def get_note_content(title: str) -> str:
```

```
1. 解析 URI 模板 "notes://{title}"：
   ├── 有 {variable} → 注册为 Resource Template
   └── 没有 {variable} → 注册为静态 Resource

2. 注册 handler：
   当收到 resources/read uri="notes://MCP学习心得" 时
   → 从 URI 中提取 title="MCP学习心得"
   → 调用 get_note_content("MCP学习心得")
```

### 5.3 @mcp.prompt() 的底层

```python
@mcp.prompt()
def summarize_notes(tag: str | None = None) -> str:
```

```
1. 解析函数签名，生成 arguments 列表：
   [{"name": "tag", "description": "...", "required": false}]

2. 注册 handler：
   当收到 prompts/get name="summarize_notes" 时
   → 调用函数，拿到返回的字符串
   → 包装成 messages：
     [{"role": "user", "content": {"type": "text", "text": "返回的字符串"}}]
```

### 5.4 mcp.run() 的底层

```
mcp.run() 做的事情：

1. 启动 stdio 传输层
   ├── 创建 stdin reader（逐行读 JSON）
   └── 创建 stdout writer（逐行写 JSON）

2. 等待 initialize 请求
   ├── 读取 Client 的 protocolVersion 和 capabilities
   ├── 进行版本协商
   ├── 收集所有注册的 tools/resources/prompts，生成 Server capabilities
   └── 返回 initialize 响应

3. 等待 initialized 通知 → 进入 Running 状态

4. 主循环：
   while True:
     line = stdin.readline()        # 读一行 JSON
     message = json.loads(line)      # 解析 JSON-RPC

     if message["method"] == "tools/list":
       → 返回所有注册的 Tool 定义
     elif message["method"] == "tools/call":
       → 找到对应的函数，调用，包装结果返回
     elif message["method"] == "resources/list":
       → 返回所有注册的 Resource 定义
     elif message["method"] == "resources/read":
       → 找到对应的函数，调用，包装结果返回
     elif message["method"] == "prompts/list":
       → 返回所有注册的 Prompt 定义
     elif message["method"] == "prompts/get":
       → 找到对应的函数，调用，包装成 messages 返回
     elif message["method"] == "ping":
       → 返回空 result（pong）
     ...
```

---

## 六、进阶：给 Tool 添加上下文和异步支持

### 6.1 访问 MCP Context

有时候 Tool 需要访问 MCP 的底层能力（比如发送日志、报告进度）：

```python
from mcp.server.fastmcp import FastMCP, Context

mcp = FastMCP("notes-server")

@mcp.tool()
async def import_notes(directory: str, ctx: Context) -> str:
    """从指定目录批量导入笔记文件。

    Args:
        directory: 包含 .md 或 .txt 文件的目录路径
    """
    files = list(Path(directory).glob("*.md")) + list(Path(directory).glob("*.txt"))
    total = len(files)

    for i, filepath in enumerate(files):
        # 报告进度（对应 notifications/progress）
        await ctx.report_progress(i, total)

        # 发送日志（对应 notifications/message）
        await ctx.info(f"正在导入: {filepath.name}")

        content = filepath.read_text(encoding="utf-8")
        # ... 保存笔记 ...

    return f"成功导入 {total} 条笔记。"
```

**ctx 对象提供的方法和协议的对应关系：**

```
ctx.report_progress(current, total)  →  notifications/progress
ctx.info("消息")                     →  notifications/message (level=info)
ctx.debug("消息")                    →  notifications/message (level=debug)
ctx.warning("消息")                  →  notifications/message (level=warning)
ctx.error("消息")                    →  notifications/message (level=error)
ctx.read_resource("notes://list")    →  内部调用 resources/read
```

### 6.2 异步 Tool

如果你的 Tool 需要做 IO 密集操作（调 API、查数据库），用 `async` 可以避免阻塞：

```python
import httpx

@mcp.tool()
async def fetch_web_content(url: str) -> str:
    """获取指定 URL 的网页内容摘要。

    Args:
        url: 要抓取的网页 URL，例如 "https://example.com"
    """
    async with httpx.AsyncClient() as client:
        response = await client.get(url, follow_redirects=True)
        response.raise_for_status()
        # 只取前 5000 字符
        return response.text[:5000]
```

SDK 同时支持同步和异步函数——你写 `def` 就是同步，写 `async def` 就是异步。

---

## 七、完整的运行流程图

把所有东西串起来，从启动到使用的完整流程：

```
你执行: python server.py
         │
         ▼
  ┌──────────────────────┐
  │ mcp.run() 启动       │
  │ 监听 stdin            │
  │ 等待 initialize...    │
  └──────────┬───────────┘
             │
             │  Claude Desktop 启动，读取配置，
             │  fork 进程运行 python server.py，
             │  通过 stdin/stdout 连接
             │
  ┌──────────▼───────────┐
  │ 收到 initialize 请求  │
  │                       │
  │ SDK 自动处理：          │
  │ 1. 版本协商 ✓          │
  │ 2. 收集已注册的        │
  │    3 个 Tools          │
  │    2 个 Resources      │
  │    2 个 Prompts        │
  │ 3. 生成 capabilities   │
  │ 4. 返回响应            │
  │ 5. 收到 initialized    │
  └──────────┬───────────┘
             │
  ┌──────────▼───────────┐
  │ Running 状态          │
  │                       │
  │ 等待请求...            │
  │                       │
  │ → tools/list          │──→ 返回 [create_note, search_notes, delete_note]
  │ → resources/list      │──→ 返回 [notes://list]
  │ → prompts/list        │──→ 返回 [summarize_notes, write_from_notes]
  │                       │
  │ → tools/call          │──→ 调用对应的 Python 函数
  │   name=create_note    │    返回函数的返回值
  │                       │
  │ → resources/read      │──→ 调用对应的 Python 函数
  │   uri=notes://list    │    返回函数的返回值
  │                       │
  │ → prompts/get         │──→ 调用对应的 Python 函数
  │   name=summarize_notes│    包装成 messages 返回
  │                       │
  └───────────────────────┘
```

---

## 八、常见踩坑点

| 问题 | 原因 | 解决方案 |
| --- | --- | --- |
| Claude Desktop 看不到你的 Server | 配置文件路径写错 / 没重启 | 用绝对路径，重启 Claude Desktop |
| Server 启动后立刻退出 | Python 报错（import 失败、语法错误） | 先在终端手动 `python server.py` 看报错 |
| Tool 调用报错 "Tool not found" | 函数名拼写不一致 | 检查 @mcp.tool() 注册的名字 |
| 中文乱码 | 文件读写没指定 encoding | 所有 open() 都加 `encoding="utf-8"` |
| Server 卡住不响应 | 同步函数里做了耗时操作阻塞了事件循环 | 用 `async def` + 异步 IO |
| print 导致协议错误 | print 输出到了 stdout | 用 `logging` 输出到 stderr，或用 ctx.info() |

---

## 小结

1. **FastMCP 让构建 Server 极其简单**——用装饰器注册 Tool/Resource/Prompt，SDK 自动处理协议细节（签名解析、Schema 生成、JSON-RPC 分发）
2. **三个装饰器对应三种能力**：`@mcp.tool()` → Tools，`@mcp.resource()` → Resources，`@mcp.prompt()` → Prompts
3. **docstring 就是 description**——SDK 从 docstring 提取描述，从类型注解生成 inputSchema。写好 docstring = 写好 Tool 定义
4. **接入 Host 只需改配置文件**——Claude Desktop / Claude Code 都通过 JSON 配置指定 Server 的启动命令
5. **MCP Inspector 是最好的调试工具**——浏览器 UI 直接测试你的 Server

---

> **下一课预告**：从 Client 端出发——用代码构建一个 MCP Client，连接到 Server，理解 Host 应用如何集成 MCP。

请告诉我你对这课内容的理解，或者有什么疑问？
