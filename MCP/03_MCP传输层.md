# MCP - 第 3 课：MCP 传输层——stdio 与 Streamable HTTP 的实现细节

## 学习目标（本节结束后你能做到什么）

1. 理解 stdio 传输的完整消息流转过程，能排查常见的 stdio 通信问题
2. 理解 Streamable HTTP 的请求/响应模型和 SSE 流式推送机制
3. 知道什么场景下该选哪种传输方式
4. 理解 MCP 的消息帧格式和错误处理机制

---

## 一、先搞清楚"传输层"在 MCP 中的位置

MCP 协议可以分成三层来理解：

```
┌─────────────────────────────────┐
│  应用层（Application Layer）     │  ← Tools/Resources/Prompts 的语义
│  "调用什么、传什么参数、返回什么"   │
├─────────────────────────────────┤
│  协议层（Protocol Layer）        │  ← JSON-RPC 2.0 消息格式
│  "消息长什么样、id 怎么对应"      │
├─────────────────────────────────┤
│  传输层（Transport Layer）       │  ← stdio / Streamable HTTP  ← 本课重点
│  "消息怎么发过去、怎么收回来"      │
└─────────────────────────────────┘
```

传输层解决的问题非常具体：**一段 JSON 文本，怎么从 A 进程传到 B 进程？**

这和你做后端时选 TCP 还是 UDP、用 HTTP/1.1 还是 HTTP/2 是同一层面的决策。

---

## 二、stdio 传输：深入细节

### 2.1 消息帧格式

stdio 传输的消息格式极其简单——**每条 JSON-RPC 消息占一行，以换行符 `\n` 结尾**。

```
→ stdin:  {"jsonrpc":"2.0","id":1,"method":"initialize","params":{...}}\n
← stdout: {"jsonrpc":"2.0","id":1,"result":{...}}\n
→ stdin:  {"jsonrpc":"2.0","id":2,"method":"tools/list"}\n
← stdout: {"jsonrpc":"2.0","id":2,"result":{"tools":[...]}}\n
```

没有长度前缀、没有分隔符协商、没有消息头——就是一行一条消息。这是你能想到的**最简单的帧格式**。

对比一下其他协议的帧格式，你就能体会 stdio 有多简单：

| 协议 | 帧格式 |
| --- | --- |
| HTTP/1.1 | 状态行 + 多行 Header + 空行 + Body（Content-Length 或 chunked） |
| HTTP/2 | 9 字节帧头（Length + Type + Flags + Stream ID）+ Payload |
| WebSocket | 2-14 字节帧头（Opcode + Mask + Length）+ Payload |
| gRPC | 5 字节前缀（Compressed Flag + 4 字节 Length）+ Protobuf |
| **MCP stdio** | **JSON + `\n`，没了** |

### 2.2 进程模型

当 Host 通过 stdio 连接一个 Server 时，实际发生的是：

```
Host 进程（比如 Claude Desktop）
│
│  fork + exec 启动子进程
│  同时建立两根管道（pipe）
│
├── pipe1: Host 写 → Server 的 stdin 读
├── pipe2: Server 的 stdout 写 → Host 读
│
▼
Server 子进程（比如 python mcp_server.py）
│
├── stdin  (fd=0) ← 从 pipe1 读取，接收 Host 的请求
├── stdout (fd=1) → 写入 pipe2，发送响应给 Host
└── stderr (fd=2) → 日志输出（Host 可以捕获用于调试）
```

用 Python 伪代码表示 Host 端的逻辑：

```python
import subprocess
import json

# Host 启动 Server 子进程
process = subprocess.Popen(
    ["python", "-m", "my_mcp_server"],
    stdin=subprocess.PIPE,    # Host 可以往这里写
    stdout=subprocess.PIPE,   # Host 可以从这里读
    stderr=subprocess.PIPE,   # 捕获日志
)

# 发送请求：往 Server 的 stdin 写
request = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {...}}
process.stdin.write(json.dumps(request).encode() + b"\n")
process.stdin.flush()  # 必须 flush，否则数据可能留在缓冲区！

# 接收响应：从 Server 的 stdout 读一行
response_line = process.stdout.readline()
response = json.loads(response_line)
```

用 Python 伪代码表示 Server 端的逻辑：

```python
import sys
import json

# Server 的主循环：不断从 stdin 读请求
for line in sys.stdin:
    request = json.loads(line)

    # 处理请求
    if request["method"] == "initialize":
        result = {"protocolVersion": "2025-03-26", "capabilities": {...}}
    elif request["method"] == "tools/list":
        result = {"tools": [...]}
    # ...

    # 往 stdout 写响应
    response = {"jsonrpc": "2.0", "id": request.get("id"), "result": result}
    sys.stdout.write(json.dumps(response) + "\n")
    sys.stdout.flush()  # 同样必须 flush！
```

### 2.3 stdio 的三个常见坑

作为一个写过不少后端代码的工程师，这几个坑你必须知道：

**坑 1：缓冲区问题（最常见！）**

很多编程语言的标准输出默认有缓冲区（line-buffered 或 full-buffered）。如果你不手动 `flush()`，消息会卡在缓冲区里，对面读不到，两边互相等——**死锁了**。

```python
# ❌ 错误：没有 flush
sys.stdout.write(json.dumps(response) + "\n")
# 消息可能还在缓冲区里，Host 读不到

# ✅ 正确：写完立即 flush
sys.stdout.write(json.dumps(response) + "\n")
sys.stdout.flush()

# ✅ 更好：启动时直接关闭缓冲
# Python: 环境变量 PYTHONUNBUFFERED=1
# Node.js: 默认 stdout 是 unbuffered，不用管
```

**坑 2：stderr 和 stdout 混淆**

Server 进程里如果有任何东西不小心写到了 stdout（比如 `print()` 调试信息、第三方库的 log），就会被 Host 当成 JSON-RPC 消息解析——然后**报错**。

```python
# ❌ 错误：print 默认写 stdout
print("debug: processing request")  # Host 会尝试把这行当 JSON 解析！

# ✅ 正确：调试信息写 stderr
import sys
print("debug: processing request", file=sys.stderr)

# ✅ 更好：用 logging 模块，配置输出到 stderr
import logging
logging.basicConfig(stream=sys.stderr)
logger = logging.getLogger(__name__)
logger.info("processing request")
```

这是 MCP Server 开发中**最常见的 bug 来源之一**——你引入了一个第三方库，它在某个地方偷偷 `print` 了一行，你的 Server 就莫名其妙坏了。

**坑 3：进程退出处理**

Host 关闭时，Server 子进程应该优雅退出。但如果 Host 崩溃了（被 kill -9），stdin 管道会断开，Server 需要检测到这个情况并退出，否则变成僵尸进程。

```python
# Server 应该处理 stdin 关闭的情况
for line in sys.stdin:
    # 正常处理...
    pass

# 循环结束 = stdin 被关闭 = Host 断了
# 到这里应该清理资源并退出
cleanup()
sys.exit(0)
```

### 2.4 stdio 的适用场景

| 适合 | 不适合 |
| --- | --- |
| Server 和 Host 在同一台机器上 | Server 在远程服务器上 |
| 单用户使用 | 多用户共享同一个 Server |
| 对安全性要求高（不开端口） | 需要跨网络访问 |
| 快速开发原型 | 需要水平扩展的生产部署 |

---

## 三、Streamable HTTP 传输：深入细节

### 3.1 整体设计

Streamable HTTP 是 MCP 协议在 2025 年 3 月（协议版本 `2025-03-26`）引入的远程传输方式，取代了之前的 HTTP+SSE 方案。

它的核心思路：**用标准 HTTP 做主通道，用 SSE（Server-Sent Events）做流式推送**。

Server 只需要暴露一个 HTTP 端点（比如 `https://my-server.com/mcp`），所有通信都通过这一个端点完成。

### 3.2 三种 HTTP 交互模式

**模式 1：POST 请求 → JSON 响应（最简单）**

这就是标准的 HTTP 请求-响应，和你写 REST API 没区别：

```
POST /mcp HTTP/1.1
Content-Type: application/json
Accept: application/json, text/event-stream

{"jsonrpc":"2.0","id":1,"method":"tools/list"}
```

```
HTTP/1.1 200 OK
Content-Type: application/json

{"jsonrpc":"2.0","id":1,"result":{"tools":[...]}}
```

适用于：简单的请求-响应，比如列出 Tools、调用一个快速返回的 Tool。

**模式 2：POST 请求 → SSE 流式响应**

当 Tool 的执行需要较长时间，或者需要流式返回结果时，Server 可以返回 SSE 流：

```
POST /mcp HTTP/1.1
Content-Type: application/json
Accept: application/json, text/event-stream

{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run_query","arguments":{"sql":"SELECT ..."}}}
```

```
HTTP/1.1 200 OK
Content-Type: text/event-stream

data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"abc","progress":30,"total":100}}

data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"abc","progress":80,"total":100}}

data: {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"查询结果: ..."}]}}

```

注意看：
- 前两条是**进度通知**（没有 `id`，是 Notification），告诉 Client "我处理到 30% 了""80% 了"
- 最后一条是**最终响应**（有 `id`，匹配请求的 `id:2`），SSE 流到这里结束

这和你在后端做大文件上传时返回进度是一样的思路，只是用 SSE 格式。

**模式 3：GET 请求 → SSE 长连接（Server 主动推送通道）**

这是实现"Server → Client 主动推送"的关键：

```
GET /mcp HTTP/1.1
Accept: text/event-stream

（建立 SSE 长连接，保持不断开）
```

```
HTTP/1.1 200 OK
Content-Type: text/event-stream

（连接建立后，Server 随时可以推送消息）

data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}

（过了一会儿，又推一条）

data: {"jsonrpc":"2.0","method":"notifications/resources/list_changed"}
```

Client 在初始化成功后会发一个 GET 请求建立这个长连接，然后一直保持。Server 有事就往里面推消息，没事就空着。

### 3.3 SSE 格式详解

SSE（Server-Sent Events）是 HTML5 标准的一部分，你可能在前端用过 `EventSource` API。它的消息格式非常简单：

```
data: 一行数据内容\n
\n
```

每条消息以 `data: ` 开头，以两个换行符结尾（一个结束 data 行，一个作为消息分隔符）。

SSE 还支持可选的 `event` 和 `id` 字段（这是 SSE 自己的字段，和 JSON-RPC 的 id 不同）：

```
event: message
id: evt-001
data: {"jsonrpc":"2.0","id":1,"result":{...}}

event: message
id: evt-002
data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}

```

MCP 中 `id` 字段的作用是**断线重连**——如果 SSE 连接断了，Client 重连时带上 `Last-Event-ID` 头，Server 就知道从哪里继续推送。

### 3.4 会话管理

Streamable HTTP 还引入了**会话**（Session）的概念，这是 stdio 不需要的（stdio 天然就是一个会话——进程在就是会话在）。

```
1. Client 发送 initialize 请求
2. Server 返回 initialize 响应，并在 HTTP 头里带上：
   Mcp-Session-Id: session-abc123
3. Client 后续所有请求都带上这个 Session ID：
   Mcp-Session-Id: session-abc123
4. Server 通过 Session ID 关联这些请求到同一个会话
```

为什么需要 Session？因为 HTTP 是无状态的。不同的 POST 请求可能落到不同的 Server 实例上（如果有负载均衡），Session ID 让 Server 知道"这些请求来自同一个 Client 会话"。

```
没有 Session：                        有 Session：

Client                               Client
  │                                     │
  ├── POST (tools/list) → Server A      ├── POST (tools/list)
  ├── POST (tools/call) → Server B      │   Mcp-Session-Id: abc123
  └── POST (tools/call) → Server A      │   → 路由到 Server A
  （三次请求可能落到不同实例，             │
   Server 不知道它们有关联）              ├── POST (tools/call)
                                        │   Mcp-Session-Id: abc123
                                        │   → 路由到 Server A（同一会话）
                                        │
                                        └── （LB 可按 Session ID 做亲和性路由）
```

### 3.5 认证与安全

Streamable HTTP 走的是标准 HTTP，所以认证方式和你平时写的 REST API 一样：

```
POST /mcp HTTP/1.1
Authorization: Bearer eyJhbGciOiJSUzI1NiJ9...
Content-Type: application/json

{"jsonrpc":"2.0","id":1,"method":"tools/list"}
```

支持的认证方式包括：
- **Bearer Token**：最常用，API Key 或 OAuth2 Token
- **OAuth 2.0**：MCP 规范中推荐的标准认证流程
- **自定义 Header**：比如 `X-API-Key`

**生产环境必须用 HTTPS**，这和任何 HTTP API 一样，不多说。

### 3.6 Streamable HTTP 的适用场景

| 适合 | 不适合 |
| --- | --- |
| Server 部署在远程/云端 | 简单的本地开发 |
| 需要多用户共享 | 对延迟极其敏感 |
| 需要水平扩展和负载均衡 | 不允许开 HTTP 端口 |
| 需要标准的认证和鉴权 | 离线环境 |

---

## 四、两种传输方式的完整对比

| 维度 | stdio | Streamable HTTP |
| --- | --- | --- |
| **通信范围** | 仅限本机 | 本机 + 远程 |
| **启动方式** | Host 启动 Server 子进程 | Server 独立运行，Client 连接 |
| **消息帧格式** | JSON + `\n` | HTTP Request/Response + SSE |
| **连接数** | 两根管道（stdin/stdout） | 按需建立 HTTP 连接 |
| **会话管理** | 进程 = 会话，天然绑定 | 需要 Session ID |
| **认证** | 不需要（进程隔离） | 需要（Bearer Token / OAuth） |
| **加密** | 不需要（数据不出本机） | 必须 HTTPS |
| **负载均衡** | 不适用 | 支持（按 Session 亲和） |
| **断线重连** | 进程挂了就重启 | SSE 支持 Last-Event-ID 续传 |
| **性能** | 极低延迟（管道直传） | 有 HTTP 开销，但可接受 |
| **调试** | 看 stderr 日志 | 标准 HTTP 工具（curl、Postman） |
| **部署复杂度** | 极低 | 中等（需要 Web 服务器） |

### 如何选择？

用一个决策树来判断：

```
你的 Server 需要被远程访问吗？
│
├── 是 → Streamable HTTP
│       │
│       ├── 需要多用户共享 → 加 Session + 认证
│       └── 单用户远程 → 简单 Bearer Token 即可
│
└── 否（Server 和 Host 在同一台机器上）
        │
        ├── Server 是轻量级的、用完即走 → stdio
        └── Server 需要长期运行、被多个 Host 共享 → Streamable HTTP（localhost）
```

**实际经验**：目前绝大多数 MCP Server 都用 stdio，因为主流使用场景是本地开发（Claude Desktop、Claude Code、Cursor 都是本地应用）。Streamable HTTP 更多用在企业级部署场景。

---

## 五、消息的错误处理

不管哪种传输方式，JSON-RPC 2.0 本身定义了标准的错误格式：

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32601,
    "message": "Method not found",
    "data": { "method": "tools/nonexistent" }
  }
}
```

MCP 使用的错误码：

| 错误码 | 含义 | 场景 |
| --- | --- | --- |
| -32700 | Parse error | JSON 格式错误 |
| -32600 | Invalid Request | 请求结构不符合 JSON-RPC 规范 |
| -32601 | Method not found | 调了一个不存在的方法 |
| -32602 | Invalid params | 参数类型或值不对 |
| -32603 | Internal error | Server 内部异常 |

这和 HTTP 状态码（400、404、500）是同一个思路——标准化的错误分类，让 Client 能程序化地处理不同错误。

**传输层面的错误**则取决于传输方式：

- stdio：管道断开（Server 进程退出、Host 崩溃）→ 读到 EOF
- HTTP：标准 HTTP 状态码（401 未认证、403 禁止、404 端点不存在、429 限流、503 不可用）

---

## 六、一个完整的 Streamable HTTP 交互实录

把所有概念串起来，完整走一遍远程 MCP 通信：

```
═══ 阶段 1：初始化 ═══

Client → Server:
POST /mcp HTTP/1.1
Content-Type: application/json
Accept: application/json, text/event-stream

{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{"roots":{}},"clientInfo":{"name":"my-app","version":"1.0"}}}

Server → Client:
HTTP/1.1 200 OK
Content-Type: application/json
Mcp-Session-Id: sess-a1b2c3

{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"my-server","version":"0.1.0"}}}

Client → Server:
POST /mcp HTTP/1.1
Mcp-Session-Id: sess-a1b2c3
Content-Type: application/json

{"jsonrpc":"2.0","method":"notifications/initialized"}

（注意：这是一个 Notification，没有 id，Server 不需要返回响应）

Server → Client:
HTTP/1.1 202 Accepted


═══ 阶段 2：建立 SSE 监听通道 ═══

Client → Server:
GET /mcp HTTP/1.1
Mcp-Session-Id: sess-a1b2c3
Accept: text/event-stream

Server → Client:
HTTP/1.1 200 OK
Content-Type: text/event-stream

（连接保持打开，等待 Server 推送...）


═══ 阶段 3：发现能力 ═══

Client → Server:
POST /mcp HTTP/1.1
Mcp-Session-Id: sess-a1b2c3
Content-Type: application/json

{"jsonrpc":"2.0","id":2,"method":"tools/list"}

Server → Client:
HTTP/1.1 200 OK
Content-Type: application/json

{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"run_query","description":"执行SQL查询","inputSchema":{"type":"object","properties":{"sql":{"type":"string"}},"required":["sql"]}}]}}


═══ 阶段 4：调用 Tool（流式响应） ═══

Client → Server:
POST /mcp HTTP/1.1
Mcp-Session-Id: sess-a1b2c3
Content-Type: application/json

{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"run_query","arguments":{"sql":"SELECT count(*) FROM orders WHERE status='pending'"}}}

Server → Client:
HTTP/1.1 200 OK
Content-Type: text/event-stream

data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"q1","progress":50,"total":100}}

data: {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"查询结果: 1,234 条待处理订单"}]}}


═══ 阶段 5：Server 主动推送（通过之前的 GET SSE 通道） ═══

（Server 发现 Tool 列表变了，通过 SSE 长连接推送通知）

data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}

（Client 收到后重新 POST tools/list 获取最新列表）


═══ 阶段 6：关闭会话 ═══

Client → Server:
DELETE /mcp HTTP/1.1
Mcp-Session-Id: sess-a1b2c3

Server → Client:
HTTP/1.1 200 OK

（Server 清理 sess-a1b2c3 的所有状态，关闭 SSE 连接）
```

---

## 小结

1. **stdio 传输**：每条消息就是一行 JSON + `\n`，通过 stdin/stdout 管道传递。极简但只能本地用。注意三个坑：缓冲区要 flush、日志别写 stdout、处理好进程退出
2. **Streamable HTTP 传输**：POST 发请求（普通 JSON 或 SSE 流式响应）+ GET 建立 SSE 长连接接收推送。支持远程、认证、负载均衡
3. **SSE**：HTTP 标准的流式推送机制，`data: {...}\n\n` 格式，支持断线重连
4. **会话管理**：HTTP 模式通过 `Mcp-Session-Id` 头关联请求，类似你熟悉的 Session Cookie
5. **选择原则**：本地用 stdio，远程用 Streamable HTTP。目前主流场景以 stdio 为主

---

> **下一课预告**：深入 MCP 核心能力之一——Tools。我们将学习 Tool 的定义方式、调用流程、参数校验、错误处理，以及如何设计一个好的 Tool。

请告诉我你对这课内容的理解，或者有什么疑问？
