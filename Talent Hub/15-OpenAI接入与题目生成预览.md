# OpenAI 接入与题目生成预览

## 目标

这一阶段的目标不是把所有 AI 能力一次接完，而是先把一条最小、可验证、可替换的 AI 调用链路落下来：

- 配置 OpenAI Provider
- 从知识库文档、临时文本或网页来源生成题目预览
- 使用结构化输出返回题目草稿
- 前端直接展示生成结果

## 为什么先做“题目生成预览”

题目生成是 TalentHub 最核心的 AI 能力之一，而且它非常适合作为第一条 AI 集成链路，因为它天然满足这些条件：

- 输入明确
- 输出结构化
- 容易人工验证
- 还不需要立即写入正式题库

最开始当前接口只做“预览”。现在系统已经继续向前推进，支持“预览确认后入草稿题库”，但预览仍然是第一道人工确认闸门。

## ChatGPT Plus 和 API 的关系

需要明确一点：

- `ChatGPT Plus` 不能直接当后端 API 用
- OpenAI API 需要单独的 API Key 和单独计费

当前项目不会尝试复用 ChatGPT 网页订阅做后端调用。

## 当前后端实现

本次新增的核心文件：

- [shared/ai/openai_question_generation.py](/Users/xinqi/WebstormProjects/TalentHub/backend/app/shared/ai/openai_question_generation.py)
- [question_bank/application/ports.py](/Users/xinqi/WebstormProjects/TalentHub/backend/app/modules/question_bank/application/ports.py)
- [question_bank/application/use_cases.py](/Users/xinqi/WebstormProjects/TalentHub/backend/app/modules/question_bank/application/use_cases.py)
- [question_bank/infrastructure/repositories.py](/Users/xinqi/WebstormProjects/TalentHub/backend/app/modules/question_bank/infrastructure/repositories.py)
- [question_bank/interfaces/router.py](/Users/xinqi/WebstormProjects/TalentHub/backend/app/modules/question_bank/interfaces/router.py)

当前相关接口包括：

- `POST /api/v1/question-bank/generation-previews`
- `POST /api/v1/question-bank/generation-previews/from-inline-text`
- `POST /api/v1/question-bank/generation-previews/from-web-page`

## 当前配置项

后端新增了这些配置：

- `LLM_PROVIDER`
- `OPENAI_API_KEY_FILE`
- `OPENAI_MODEL_NAME`
- `QUESTION_GENERATION_SOURCE_MAX_CHARS`

当前约定：

- `LLM_PROVIDER=disabled`
  - 默认关闭 AI 预览
- `LLM_PROVIDER=openai`
  - 启用 OpenAI 题目生成
- `LLM_PROVIDER=deepseek`
  - 启用 DeepSeek 题目生成
- `OPENAI_MODEL_NAME`
  - 默认使用 `gpt-5-mini`
- `OPENAI_API_KEY_FILE`
  - 指向一个只包含原始 key 的本地文件
- `QUESTION_GENERATION_SOURCE_MAX_CHARS`
  - 当前默认值 `20000`
  - 用于限制单次题目生成输入段落的最大字符数
- `DEEPSEEK_MODEL_NAME`
  - 默认使用 `deepseek-chat`
- `DEEPSEEK_API_KEY_FILE`
  - 指向 DeepSeek 的本地 key 文件

这套设计不是把密钥写死在某个 `.env` 里，而是按 provider 分文件读取。后面如果接入 DeepSeek、Gemini 或其他平台，可以继续新增各自的 `*_API_KEY_FILE`，复用同一套密钥加载逻辑。

## 为什么默认用 gpt-5-mini

当前这条链路是：

- 结构化输出
- 明确约束
- 中等复杂度文本生成

所以先用成本更适中的模型更合理。等后面你对题目质量要求更高，或者需要更复杂的企业语义理解时，再切更强模型也很自然。

## fail fast 规则

这条 AI 链路严格遵循项目原则，不做“差不多就算了”的容错：

- 没配 `LLM_PROVIDER=openai` 直接失败
- 没配 `OPENAI_API_KEY` 直接失败
- 文档不存在直接失败
- 文档不是 `parsed/indexed` 直接失败
- 文档正文超过当前预览上限直接失败
- 模型返回的题目数量不对直接失败
- 模型返回的题型不对直接失败
- 模型返回的难度不对直接失败
- 模型返回空答案或空来源摘录直接失败

也就是说，当前阶段我们优先暴露问题，而不是偷偷“修一修继续跑”。

当前对超长来源的处理也保持清晰：

- 不把整篇超长正文整体丢给模型
- 先做确定性分段
- 再按段生成题目
- 每道题会带上“来自第几段/共几段”的元信息

## 前端实现

前端首页现在新增“题目生成预览工作台”：

- 选择一份知识文档
- 选择题型
- 选择难度
- 选择题目数量
- 发起题目生成
- 显示结构化题目草稿

当前前端不会把结果直接写进题库，这个决定是有意为之：

- 先把 Prompt 和结构化输出调稳
- 再做“人工确认后入库”
- 最后再做批量生成和正式题库持久化

## 已验证结果

当前已经验证：

- 新接口可正常加载到 FastAPI
- 当 `LLM_PROVIDER` 未启用时，接口会明确返回错误
- 前端已接入这条接口并通过构建验证

当前还没有验证“真实 OpenAI 成功返回题目”的唯一前提是本地还没有把可用 API Key 接入 backend。

## 启用方式

如果你要真正调用 OpenAI，请把这些配置写到 [backend/.env](/Users/xinqi/WebstormProjects/TalentHub/backend/.env)：

```bash
LLM_PROVIDER=openai
OPENAI_API_KEY_FILE=/你的本地密钥文件路径
OPENAI_MODEL_NAME=gpt-5-mini
```

当前约定：

- 本地运行 `make backend-run` 时，FastAPI 会直接读取 `backend/.env`
- Docker Compose 运行 backend 时，也会通过 `env_file` 读取 `backend/.env`

因此你不需要再额外手工导出同样的 OpenAI 环境变量。

## 下一步

在这条 AI 预览链路稳定后，最自然的下一步是：

1. 让预览结果支持人工确认后入库
2. 记录题目来源文档和来源摘录
3. 基于 chunk 检索结果做更精确的 RAG 出题
4. 再继续接主观题判卷
