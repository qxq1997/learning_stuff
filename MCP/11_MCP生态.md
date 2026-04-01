# MCP - 第 11 课：MCP 生态——官方 SDK、Registry 与社区 Server

## 学习目标（本节结束后你能做到什么）

1. 了解 MCP 官方提供的 SDK、工具和参考实现
2. 理解 MCP Registry（Server 注册中心）的作用和使用方式
3. 知道当前生态中最常用的社区 Server 及其适用场景
4. 掌握如何发现、评估、安装和配置 MCP Server
5. 了解 MCP 的行业采纳现状（哪些公司/产品支持 MCP）

---

## 一、MCP 官方资源全景

Anthropic 作为 MCP 的发起者，提供了一整套官方资源：

```
MCP 官方资源

├── 协议规范
│   └── spec.modelcontextprotocol.io          ← 协议的完整技术规范
│
├── 官方 SDK（帮你快速构建 Server / Client）
│   ├── Python SDK      → pip install mcp
│   ├── TypeScript SDK   → npm i @modelcontextprotocol/sdk
│   ├── Java SDK         → com.modelcontextprotocol:sdk
│   ├── Kotlin SDK       → com.modelcontextprotocol:sdk-kotlin
│   └── C# SDK           → ModelContextProtocol（NuGet）
│
├── 开发工具
│   ├── MCP Inspector    → npx @modelcontextprotocol/inspector
│   │   浏览器 UI 调试工具，可视化测试 Server 的所有能力
│   │
│   └── MCP CLI (mcptools) → pip install mcptools
│       命令行工具，快速测试 Server
│       $ mcp list tools --server "python server.py"
│       $ mcp call create_note --server "python server.py" \
│             --args '{"title":"test","content":"hello"}'
│
├── 官方参考 Server（示范如何写 Server）
│   ├── Filesystem Server    → 文件系统读写
│   ├── GitHub Server        → GitHub API 操作
│   ├── PostgreSQL Server    → 数据库查询
│   ├── Slack Server         → Slack 消息
│   ├── Google Maps Server   → 地图/地理信息
│   ├── Puppeteer Server     → 浏览器自动化
│   └── ... 更多见 github.com/modelcontextprotocol/servers
│
└── MCP Registry
    └── registry.modelcontextprotocol.io      ← Server 注册中心
```

### 各 SDK 的定位

```
你要做什么？                              用哪个 SDK？
──────────                               ──────────

写一个 MCP Server（暴露工具/数据）         Python SDK / TypeScript SDK
  ├── 后端工程师、要用 Python 生态         → Python SDK (FastMCP)
  └── 全栈/前端、要用 Node 生态            → TypeScript SDK

写一个 MCP Client（连接 Server）           Python SDK / TypeScript SDK
  ├── 构建自己的 AI 应用                   → 选择你熟悉的语言
  └── 集成到 Java/Kotlin 后端              → Java SDK / Kotlin SDK

写一个完整的 Host（Client + LLM 集成）     自行组合 SDK + LLM API
```

---

## 二、MCP Registry：Server 注册中心

### 2.1 Registry 是什么？

MCP Registry 是一个**集中化的 MCP Server 目录**——类似 npm registry 之于 Node 包、Docker Hub 之于容器镜像。

```
没有 Registry 的世界：

  "我想找一个能操作 GitHub 的 MCP Server"
  → Google 搜索
  → 翻 GitHub
  → 不知道哪个靠谱
  → 不知道怎么安装
  → 浪费大量时间

有了 Registry 的世界：

  $ 在 registry.modelcontextprotocol.io 搜索 "github"
  → 看到官方的 GitHub Server，有评分、文档、安装命令
  → 一键配置到 Claude Desktop
```

### 2.2 Registry 的使用方式

**方式 1：Web UI 浏览**

访问 `registry.modelcontextprotocol.io`，可以按分类浏览和搜索：

```
┌──────────────────────────────────────────────────────┐
│  MCP Registry                          [搜索: github]│
│                                                       │
│  分类：                                               │
│  ├── 开发工具（GitHub, Git, Docker, Kubernetes...）    │
│  ├── 数据库（PostgreSQL, MySQL, SQLite, MongoDB...）  │
│  ├── 通信（Slack, Discord, Email...）                 │
│  ├── 文件（Filesystem, Google Drive, S3...）          │
│  ├── 搜索（Brave Search, Google Search...）           │
│  ├── 监控（Sentry, Datadog, PagerDuty...）            │
│  └── AI/ML（Hugging Face, Replicate...）              │
│                                                       │
│  搜索结果：                                           │
│  ┌─────────────────────────────────────────────────┐ │
│  │ 🏷️ @modelcontextprotocol/server-github          │ │
│  │ ⭐ Official | 安装数: 50K+                       │ │
│  │ GitHub API 操作：PR、Issue、代码搜索、仓库管理    │ │
│  │ [查看详情] [安装指南]                             │ │
│  └─────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

**方式 2：通过 Host 应用直接搜索安装**

一些 Host 应用（如 Claude Desktop）开始集成 Registry，用户可以在应用内直接搜索和安装 Server，类似 VS Code 安装插件的体验。

**方式 3：API 接口**

Registry 提供 API，你的应用可以程序化地搜索和获取 Server 信息：

```bash
# 搜索 github 相关的 Server
curl "https://registry.modelcontextprotocol.io/api/servers?q=github"
```

### 2.3 如何发布自己的 Server 到 Registry

如果你写了一个有用的 MCP Server，可以发布到 Registry 让其他人使用：

```
发布流程：

1. 确保你的 Server 有完整的文档
   ├── README.md（功能描述、安装方法、配置说明）
   ├── 支持的 Tools / Resources / Prompts 列表
   └── 所需的环境变量和权限

2. 以 npm 包或 Python 包发布
   ├── npm: npm publish @yourname/mcp-server-xxx
   └── PyPI: pip install your-mcp-server

3. 在 Registry 注册
   └── 提交到 registry，填写元数据
```

---

## 三、社区热门 Server 分类介绍

### 3.1 开发工具类

```
┌───────────────────────────────────────────────────────────┐
│ 开发工具类 MCP Server                                      │
│                                                            │
│ GitHub Server (@modelcontextprotocol/server-github)        │
│ ├── Tools: 管理 PR、Issue、代码搜索、仓库操作               │
│ ├── Resources: 代码文件内容、PR diff                        │
│ └── 用途: AI 辅助代码审查、Issue 管理                       │
│                                                            │
│ Git Server (@modelcontextprotocol/server-git)              │
│ ├── Tools: status, diff, log, commit, branch               │
│ ├── Resources: 仓库历史、文件变更                           │
│ └── 用途: AI 辅助 Git 操作                                  │
│                                                            │
│ Filesystem Server (@modelcontextprotocol/server-filesystem)│
│ ├── Tools: 读写文件、创建目录、搜索文件                      │
│ ├── Resources: 文件内容、目录结构                           │
│ └── 用途: AI 助手需要操作本地文件时                          │
│                                                            │
│ Docker Server                                              │
│ ├── Tools: 管理容器、镜像、网络                              │
│ └── 用途: AI 辅助容器运维                                   │
└───────────────────────────────────────────────────────────┘
```

### 3.2 数据库类

```
┌───────────────────────────────────────────────────────────┐
│ 数据库类 MCP Server                                        │
│                                                            │
│ PostgreSQL Server (@modelcontextprotocol/server-postgres)   │
│ ├── Tools: 执行 SQL 查询（只读）                            │
│ ├── Resources: 表结构、索引信息                             │
│ └── 安全: 默认只允许 SELECT，防止误操作                      │
│                                                            │
│ SQLite Server (@modelcontextprotocol/server-sqlite)        │
│ ├── Tools: 查询、创建表、插入数据                           │
│ ├── Resources: 数据库 schema                               │
│ └── 适合: 本地开发、小型项目                                │
│                                                            │
│ MySQL Server                                               │
│ MongoDB Server                                             │
│ Redis Server                                               │
└───────────────────────────────────────────────────────────┘
```

### 3.3 通信与协作类

```
┌───────────────────────────────────────────────────────────┐
│ 通信与协作类 MCP Server                                     │
│                                                            │
│ Slack Server (@modelcontextprotocol/server-slack)          │
│ ├── Tools: 发消息、搜索消息、管理频道                        │
│ └── 用途: AI 助手在 Slack 中发通知、搜索历史消息             │
│                                                            │
│ Google Drive Server                                        │
│ ├── Tools: 搜索文件、读取文档                               │
│ ├── Resources: 文件列表、文档内容                           │
│ └── 用途: AI 助手访问 Google Drive 中的资料                  │
│                                                            │
│ Notion Server                                              │
│ Linear Server                                              │
│ Jira Server                                                │
└───────────────────────────────────────────────────────────┘
```

### 3.4 搜索与知识类

```
┌───────────────────────────────────────────────────────────┐
│ 搜索与知识类 MCP Server                                     │
│                                                            │
│ Brave Search Server                                        │
│ ├── Tools: 网页搜索、本地商户搜索                           │
│ └── 用途: 让 AI 助手能搜索互联网获取实时信息                 │
│                                                            │
│ Fetch Server (@modelcontextprotocol/server-fetch)          │
│ ├── Tools: 抓取网页内容、转换为 Markdown                    │
│ └── 用途: AI 助手读取网页文章、文档                          │
│                                                            │
│ Memory Server (@modelcontextprotocol/server-memory)        │
│ ├── Tools: 存储和检索知识图谱                               │
│ ├── Resources: 实体和关系                                   │
│ └── 用途: 给 AI 助手持久化记忆能力                          │
└───────────────────────────────────────────────────────────┘
```

### 3.5 监控与运维类

```
┌───────────────────────────────────────────────────────────┐
│ 监控与运维类 MCP Server                                     │
│                                                            │
│ Sentry Server                                              │
│ ├── Tools: 查询错误、分析 issue、管理 alert                 │
│ └── 用途: AI 辅助排查线上错误                               │
│                                                            │
│ Kubernetes Server                                          │
│ ├── Tools: 查看 Pod 状态、日志、重启服务                     │
│ └── 用途: AI 辅助 K8s 运维                                  │
│                                                            │
│ Cloudflare Server                                          │
│ Datadog Server                                             │
│ PagerDuty Server                                           │
└───────────────────────────────────────────────────────────┘
```

---

## 四、如何评估一个 MCP Server

在安装使用一个社区 Server 之前，你应该评估它的质量和安全性：

```
评估清单：

┌─ 可信度 ─────────────────────────────────────────────┐
│ □ 是否为官方（@modelcontextprotocol）发布？             │
│ □ 作者是否可信（知名公司/开发者）？                     │
│ □ 是否开源？代码是否可审查？                            │
│ □ 在 Registry 上的安装量和评分如何？                    │
│ □ 是否有活跃维护（最近的 commit、issue 响应速度）？      │
└──────────────────────────────────────────────────────┘

┌─ 安全性 ─────────────────────────────────────────────┐
│ □ 需要哪些权限/凭据（API Key、数据库密码）？            │
│ □ 暴露了哪些 Tools？有没有危险操作（delete、drop）？    │
│ □ 数据暴露范围是否合理（不应无限制暴露整个数据库）？     │
│ □ 是否有 annotations 标注（destructiveHint 等）？      │
│ □ 代码中有没有可疑的外部请求（偷传数据）？              │
└──────────────────────────────────────────────────────┘

┌─ 质量 ───────────────────────────────────────────────┐
│ □ Tool 的 description 写得是否清晰？                    │
│ □ inputSchema 是否完整（有 description、enum、required）?│
│ □ 错误处理是否完善（不会因异常挂掉）？                   │
│ □ 有没有文档和使用示例？                                │
│ □ 是否有测试覆盖？                                     │
└──────────────────────────────────────────────────────┘
```

---

## 五、安装和配置 Server 的完整流程

### 5.1 以 GitHub Server 为例

**第一步：安装**

```bash
# npm 全局安装
npm install -g @modelcontextprotocol/server-github

# 或者不安装，用 npx 直接运行
npx -y @modelcontextprotocol/server-github
```

**第二步：获取凭据**

```
GitHub Server 需要 Personal Access Token：
1. 访问 github.com → Settings → Developer Settings → Personal Access Tokens
2. 创建 Token，勾选需要的权限（repo、read:org 等）
3. 复制 Token
```

**第三步：配置 Host**

Claude Desktop 配置（`claude_desktop_config.json`）：

```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_xxxxxxxxxxxx"
      }
    }
  }
}
```

Claude Code 配置（`~/.claude.json` 或项目级 `.mcp.json`）：

```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_xxxxxxxxxxxx"
      }
    }
  }
}
```

**第四步：验证**

```bash
# 用 MCP Inspector 验证
npx @modelcontextprotocol/inspector npx -y @modelcontextprotocol/server-github

# 或用 mcptools CLI
mcp list tools --server "npx -y @modelcontextprotocol/server-github"
```

**第五步：使用**

重启 Host 应用后，就可以在对话中使用了：

```
用户："帮我看看 my-org/api-service 仓库最近有什么 PR"
Claude → 调用 github__list_pull_requests
Claude："你有 3 个待审查的 PR：..."
```

### 5.2 同时配置多个 Server

```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_xxx" }
    },
    "postgres": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-postgres", "postgresql://user:pass@localhost/mydb"]
    },
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/projects"]
    },
    "notes": {
      "command": "python",
      "args": ["/path/to/my-mcp-server/server.py"]
    }
  }
}
```

```
配置后的效果：

Host 启动 → 依次连接 4 个 Server → 汇总所有 Tools

LLM 看到的 Tool 列表：
├── github__list_pull_requests
├── github__create_issue
├── github__search_code
├── postgres__query
├── filesystem__read_file
├── filesystem__write_file
├── filesystem__search_files
├── notes__create_note
├── notes__search_notes
└── notes__delete_note

用户可以在一次对话中跨 Server 操作：
"帮我看看 GitHub 上最近的 PR，然后查一下数据库里对应的
 部署记录，最后把分析结果保存成一条笔记"

→ LLM 依次调用 github、postgres、notes 三个 Server 的 Tools
```

---

## 六、行业采纳现状

MCP 从 2024 年 11 月发布以来，生态发展迅速：

### 6.1 Host 端采纳

```
已支持 MCP 的 AI 应用（Host）：

┌─ Anthropic 产品 ──────────────────────────┐
│ Claude Desktop    ← 最早支持，参考实现       │
│ Claude Code       ← 你正在用的 CLI 工具      │
│ Claude.ai         ← Web 版也支持远程 MCP     │
└───────────────────────────────────────────┘

┌─ AI 编程工具 ─────────────────────────────┐
│ Cursor           ← AI 编程编辑器            │
│ Windsurf         ← Codeium 的编辑器         │
│ Zed              ← 高性能编辑器              │
│ Cline            ← VS Code 插件             │
│ Continue         ← 开源 AI 编程助手          │
└───────────────────────────────────────────┘

┌─ 其他 AI 平台 ────────────────────────────┐
│ OpenAI           ← 2025年3月宣布支持 MCP    │
│ Sourcegraph Cody ← 代码搜索和理解           │
│ Replit           ← 在线开发环境              │
└───────────────────────────────────────────┘
```

**OpenAI 在 2025 年 3 月宣布支持 MCP 是一个里程碑事件**——这意味着 MCP 不再是 Anthropic 的"自嗨"，而是成为了行业共识。当 GPT 和 Claude 都支持 MCP 时，Server 开发者写一次就能同时服务两家的用户。

### 6.2 Server 端生态

```
Server 生态规模（截至 2026 年初）：

官方 Server:        ~30+
社区 Server:        数千+
Registry 收录:      持续增长中

覆盖的领域：
├── 开发工具（Git、GitHub、GitLab、Bitbucket...）
├── 数据库（PostgreSQL、MySQL、MongoDB、Redis...）
├── 云服务（AWS、GCP、Azure、Cloudflare...）
├── 通信（Slack、Discord、Email、Teams...）
├── 项目管理（Jira、Linear、Notion、Asana...）
├── 搜索（Brave、Google、Tavily...）
├── 监控（Sentry、Datadog、PagerDuty...）
├── 文件存储（S3、Google Drive、Dropbox...）
└── 更多垂直领域持续扩展中
```

---

## 七、自己写 vs 用现成的：决策框架

```
你需要的能力已经有现成的 MCP Server 吗？
│
├── 有
│   └── 它满足你的需求吗？
│       ├── 完全满足 → 直接安装使用 ✅
│       ├── 基本满足，缺少部分功能
│       │   └── Fork 修改 or 提 PR 给原作者 ✅
│       └── 不满足（安全性、性能、功能差距大）
│           └── 参考它的设计，自己写一个 ✅
│
└── 没有
    └── 这个需求够通用吗？
        ├── 通用（别人也可能需要）
        │   └── 自己写 + 发布到 Registry，贡献社区 ✅
        └── 特定于你的业务
            └── 自己写，内部使用 ✅
```

---

## 小结

1. **官方资源**：5 种语言的 SDK + MCP Inspector 调试工具 + MCP CLI + 30+ 官方参考 Server
2. **Registry**：MCP Server 的集中注册中心，类似 npm registry，支持搜索、评级、一键安装
3. **社区生态**：覆盖开发工具、数据库、通信、云服务、监控等主要领域，数千个 Server 可用
4. **安装流程**：安装包 → 配置凭据 → 写入 Host 配置文件 → 重启 Host → 使用
5. **行业采纳**：不仅 Anthropic 产品支持，OpenAI、Cursor、Windsurf 等也已支持，MCP 正在成为行业标准
6. **评估 Server**：从可信度、安全性、质量三个维度评估，不要盲目安装不可信来源的 Server

---

> **下一课预告**：实战项目——综合运用所学知识，设计并实现一个完整的 MCP 应用，从需求分析到 Server 开发到接入 Host 的全流程。

请告诉我你对这课内容的理解，或者有什么疑问？
