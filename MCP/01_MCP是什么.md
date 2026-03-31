# MCP - 第 1 课：MCP 是什么——背景、动机与核心思想

## 学习目标（本节结束后你能做到什么）

1. 清楚解释 MCP 要解决什么问题，以及为什么现有方案不够好
2. 用自己的话描述 MCP 的核心设计思想
3. 理解 MCP 在 AI 应用技术栈中的位置
4. 能与同事讨论"为什么需要 MCP"而不只是说"Anthropic 搞的一个协议"

---

## 一、从一个真实痛点说起

假设你是一个后端工程师，你的团队在用 Claude（或 GPT）做一个智能助手，这个助手需要：

- 查询公司内部的 Jira 工单
- 读取 GitHub 仓库的代码
- 调用内部的监控 API 拿到服务健康状态
- 访问 Confluence 上的文档

**传统做法是什么？**

你会为每一个数据源写一段"胶水代码"：

```
用户提问
  → LLM 判断需要什么信息
    → 你的后端代码调 Jira API
    → 你的后端代码调 GitHub API
    → 你的后端代码调监控 API
    → 把结果拼好塞进 prompt
      → LLM 生成回答
```

这看起来没问题，但想想这个场景放大之后会怎样——

**问题 1：M×N 集成地狱**

市场上有 M 个 AI 应用（Claude Desktop、Cursor、Windsurf、你自己的产品……），有 N 个数据源/工具（GitHub、Jira、Slack、数据库、内部 API……）。如果每个应用都要自己写与每个数据源的集成代码，那就是 **M × N** 个集成。

这和当年 USB 出现之前的情况一模一样：每种外设都有自己的专用接口，每台电脑都得为每种外设装不同的驱动。USB 出现后变成了 **M + N**——每台电脑实现 USB 接口，每种外设实现 USB 接口，然后它们就能互相连接。

```
集成地狱（M×N）:                    MCP 之后（M+N）:

┌──────┐     ┌──────┐              ┌──────┐
│App A │────→│Jira  │              │App A │──┐
│      │────→│GitHub│              └──────┘  │
│      │────→│Slack │              ┌──────┐  │   ┌─────────┐   ┌──────┐
└──────┘     └──────┘              │App B │──┼──→│   MCP   │←──│Jira  │
┌──────┐     ┌──────┐              └──────┘  │   │ Protocol│←──│GitHub│
│App B │────→│Jira  │              ┌──────┐  │   │         │←──│Slack │
│      │────→│GitHub│              │App C │──┘   └─────────┘   └──────┘
│      │────→│Slack │              └──────┘
└──────┘     └──────┘
```

**MCP 就是 AI 应用领域的"USB 协议"。**

**问题 2：每个集成都要重复造轮子**

你写了一套调 GitHub API 的代码给你的产品用，隔壁组也做了一个 AI 助手，他们又写了一套几乎一样的代码。不同公司之间更是如此。这些集成代码包括认证、分页、错误处理、数据格式化……全是重复劳动。

**问题 3：AI 应用的上下文获取太碎片化**

LLM 的能力很强，但它被"困"在一个信息孤岛里——它只能看到你喂给它的 prompt。如何让 LLM 在需要时动态获取外部信息，而不是把所有可能的信息预先塞进 prompt？这需要一个标准化的、双向的通信协议。

---

## 二、MCP 的正式定义

**MCP（Model Context Protocol，模型上下文协议）** 是 Anthropic 于 2024 年 11 月开源发布的一个**开放协议**，它定义了 AI 应用与外部数据源/工具之间的标准化通信方式。

用一句话概括：

> **MCP 让 AI 模型能够以统一的方式发现、访问和使用外部工具与数据，就像 USB 让电脑以统一的方式连接外设一样。**

### MCP 的协议本质

作为一个有五年后端经验的工程师，你一定熟悉各种协议——HTTP、gRPC、WebSocket。MCP 本质上也是一个协议，它定义了：

| 维度       | MCP 的定义                                  |
| -------- | ---------------------------------------- |
| **消息格式** | 基于 JSON-RPC 2.0（你肯定见过，以太坊的 API 也用这个）     |
| **传输方式** | 支持 stdio（本地进程间通信）和 Streamable HTTP（远程通信） |
| **通信模式** | 双向通信，不是简单的请求-响应，Server 也可以主动通知 Client    |
| **能力模型** | 启动时双方"握手"协商各自支持的能力（类似 TLS 的能力协商）         |

### MCP 不是什么

在深入之前，先澄清几个常见误解：

- **MCP 不是一个 API**：它不是某个特定服务的接口，而是定义了一类接口的通用标准
- **MCP 不是 Function Calling 的替代品**：Function Calling 是 LLM 层面的能力（"模型决定调用什么函数"），MCP 是应用层面的协议（"应用如何连接到外部工具"）。它们是互补关系——LLM 通过 Function Calling 决定要调什么工具，MCP 负责实际连接到那个工具
- **MCP 不是 Anthropic 的专有技术**：它是开放协议，任何 LLM 提供商、任何应用都可以实现
- **MCP 不是 RAG 的替代品**：RAG 侧重于检索增强生成，MCP 侧重于工具调用和动态上下文获取，两者可以结合使用

---

## 三、MCP 的核心架构速览

虽然架构的细节在下一课展开，但这里先建立一个直觉。MCP 的世界里有三个核心角色：

```
┌─────────────────────────────────────────────────┐
│                   MCP Host                       │
│  （AI 应用，比如 Claude Desktop、Cursor、你的产品）│
│                                                   │
│   ┌───────────┐  ┌───────────┐  ┌───────────┐   │
│   │MCP Client │  │MCP Client │  │MCP Client │   │
│   │     1     │  │     2     │  │     3     │   │
│   └─────┬─────┘  └─────┬─────┘  └─────┬─────┘   │
│         │              │              │           │
└─────────│──────────────│──────────────│───────────┘
          │              │              │
          ▼              ▼              ▼
   ┌──────────┐   ┌──────────┐   ┌──────────┐
   │MCP Server│   │MCP Server│   │MCP Server│
   │ (GitHub) │   │ (Jira)   │   │ (数据库) │
   └──────────┘   └──────────┘   └──────────┘
```

- **Host（宿主）**：就是你的 AI 应用本身。它负责管理多个 Client 实例，协调 LLM 与 Server 之间的交互
- **Client（客户端）**：Host 内部为每个 Server 创建的一对一连接器。一个 Client 只对接一个 Server，保持 1:1 的关系
- **Server（服务端）**：暴露具体能力（工具、资源、提示模板）的服务。每个 Server 通常封装一个特定的数据源或服务

**用后端工程师的语言来类比：**

- Host 就像一个**网关/API Gateway**，统一管理多个下游服务的连接
- Client 就像网关里为每个下游服务创建的**gRPC Channel / HTTP Client 实例**
- Server 就像一个个**微服务**，各自暴露自己的接口

---

## 四、MCP Server 提供的三种核心能力

MCP Server 可以向 Client 暴露三种类型的能力，这是理解整个协议的关键：

### 1. Tools（工具）——让 LLM "动手做事"

Tools 是 **模型可调用的函数**。LLM 判断需要执行某个操作时（比如"创建一个 Jira 工单"），就会通过 MCP 调用对应的 Tool。

```json
{
  "name": "create_jira_issue",
  "description": "在 Jira 中创建一个新工单",
  "inputSchema": {
    "type": "object",
    "properties": {
      "project": { "type": "string", "description": "项目 key" },
      "summary": { "type": "string", "description": "工单标题" },
      "type": { "type": "string", "enum": ["Bug", "Task", "Story"] }
    },
    "required": ["project", "summary"]
  }
}
```

对后端工程师来说，Tool 就像一个 **RPC 接口定义**——有名字、有描述、有入参 Schema。

### 2. Resources（资源）——让 LLM "看到数据"

Resources 是 **可供应用读取的数据**，通过 URI 标识。比如一个文件的内容、一条数据库记录、一个 API 的返回结果。

```
file:///Users/me/project/README.md
postgres://localhost/mydb/users/123
jira://PROJECT-123
```

类比：Resources 就像 REST API 里的 **GET 端点**——它暴露的是数据，是只读的。

### 3. Prompts（提示模板）——让 LLM "按套路出牌"

Prompts 是 **预定义的交互模板**，帮助 LLM 按照特定工作流来处理任务。比如一个"代码审查"模板，会引导 LLM 按照安全性、性能、可读性等维度依次检查代码。

类比：Prompts 就像后端的 **请求模板/工作流模板**——预先定义好参数和流程。

---

## 五、MCP 与你熟悉的技术的对比

|           | 传统 API 集成   | Function Calling | MCP                     |
| --------- | ----------- | ---------------- | ----------------------- |
| **标准化程度** | 每个 API 各自为政 | LLM 厂商各自定义       | 统一开放协议                  |
| **连接方向**  | 应用主动调 API   | LLM 决定调函数，应用执行   | 双向通信，Server 也可主动推送      |
| **发现机制**  | 人工阅读文档      | 开发者硬编码函数列表       | Client 自动发现 Server 的能力  |
| **复用性**   | 每个应用各写各的    | 每个应用各写各的         | 写一次 Server，所有 MCP 应用都能用 |
| **生态效应**  | 无           | 限于单一 LLM 厂商      | 跨应用、跨模型的开放生态            |

---

## 六、一个完整的交互流程示例

让我们走一遍真实的 MCP 交互流程，把上面的概念串起来：

**场景**：用户在 Claude Desktop 中问："帮我看看 GitHub 上 my-project 仓库最近有什么 PR 需要我审查？"

```
1. [用户] → [Claude Desktop(Host)]
   "帮我看看 GitHub 上 my-project 仓库最近有什么 PR 需要我审查？"

2. [Host] → [Claude LLM]
   把用户消息 + 可用工具列表（从 MCP Server 发现的）发给 LLM

3. [Claude LLM] 思考后决定：
   "我需要调用 list_pull_requests 工具"
   返回一个 tool_use 响应

4. [Host] → [MCP Client for GitHub] → [MCP Server (GitHub)]
   发送 JSON-RPC 请求：
   {
     "method": "tools/call",
     "params": {
       "name": "list_pull_requests",
       "arguments": {
         "repo": "my-project",
         "state": "open",
         "reviewer": "me"
       }
     }
   }

5. [MCP Server (GitHub)] → 调用 GitHub API → 返回结果

6. [MCP Server] → [MCP Client] → [Host] → [Claude LLM]
   把 PR 列表作为上下文传回 LLM

7. [Claude LLM] 基于 PR 数据生成自然语言回答

8. [Host] → [用户]
   "你有 3 个待审查的 PR：
    - #142 'Fix auth middleware' by Alice（2小时前）
    - #139 'Add caching layer' by Bob（1天前）
    - #135 'Update dependencies' by Charlie（3天前）"
```

注意这个流程中，**MCP 协议管的是步骤 4-6**——即 Host/Client 如何与 Server 通信。LLM 的推理（步骤 3）和最终的回答生成（步骤 7）不在 MCP 的范畴内。

---

## 七、为什么是现在？为什么 MCP 会成功？

你可能会想："标准化协议多了去了，凭什么 MCP 能推起来？"

**时机对了**：2024-2025 年，AI Agent 从概念进入工程落地阶段。当大量团队都在写类似的"LLM + 外部工具"集成代码时，标准化的需求自然浮现。

**Anthropic 的推动力**：作为 Claude 的开发商，Anthropic 自己的产品（Claude Desktop、Claude Code）率先支持 MCP，形成了第一批用户基础。

**开放生态策略**：MCP 是 MIT 协议开源的，不绑定特定 LLM。这意味着 OpenAI、Google 的模型理论上都可以用 MCP，降低了采纳门槛。事实上，OpenAI 在 2025 年 3 月也宣布在其产品中支持 MCP。

**开发者体验好**：官方提供了 TypeScript 和 Python 的 SDK，加上 JSON-RPC 本身就很简单，一个有经验的后端工程师可以在一两个小时内写出一个可用的 MCP Server。

---

## 小结

1. **MCP 解决的核心问题**：AI 应用与外部工具/数据源之间的 M×N 集成问题，通过标准化协议降为 M+N
2. **MCP 的本质**：基于 JSON-RPC 2.0 的开放双向通信协议，定义了 Host-Client-Server 三层架构
3. **MCP Server 的三种能力**：Tools（让 LLM 执行操作）、Resources（让 LLM 获取数据）、Prompts（预定义交互模板）
4. **MCP 与 Function Calling 是互补关系**：Function Calling 是 LLM 的决策能力，MCP 是应用的连接协议
5. **MCP 的成功条件已经具备**：AI Agent 落地的时机、Anthropic 的推动、开放生态策略、良好的开发者体验

---

> **下一课预告**：我们会深入拆解 MCP 的三层架构——Host、Client、Server 各自的职责边界、它们之间的通信流程，以及能力协商（Capability Negotiation）机制。

请告诉我你对这课内容的理解，或者有什么疑问？你也可以直接说"继续"进入下一课。
