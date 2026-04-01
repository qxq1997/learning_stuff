# Voyage Reranker 接入设计

## 目标

本文档说明 TalentHub 为什么在当前阶段引入线上 reranker，并最终选择：

- `Voyage rerank-2.5-lite`

本文重点回答：

- 为什么不继续默认使用本地 `bge-reranker-v2-m3`
- 为什么当前更适合引入线上 reranker
- Voyage 在 TalentHub 里的角色是什么

## 背景

在 TalentHub 的检索链路里，召回和精排已经明确分层：

1. embedding 与向量库负责召回候选
2. reranker 负责对候选重新排序

前一阶段已经接入过本地 `bge-reranker-v2-m3`，但在实际开发环境中暴露出一个明显问题：

- 首次加载成本高
- 本地推理更重
- 对 Docker 镜像、依赖和冷启动时间压力较大

因此，TalentHub 在当前默认路线里，优先选择：

- 让默认 dense 检索保持轻量
- 把 reranker 切到线上 provider

## 为什么是 Voyage `rerank-2.5-lite`

选择 Voyage 的主要原因有四个：

### 1. 更轻

相比本地 `BGE` reranker：

- 不需要本地模型下载
- 不需要本地推理运行时
- 不会显著增加 Docker 镜像体积

### 2. 成本相对友好

当前目标不是做重度搜索平台，而是让 TalentHub 的：

- 知识库出题
- 检索预演
- 判卷后学习建议

都能在一个可控成本下获得更稳定的 top few 结果。

### 3. 多语言和长文本友好

TalentHub 当前知识库是中英混合的企业内容，reranker 需要能处理：

- 中文
- 英文
- 中英混合 query
- 较长的候选片段

Voyage 当前在这类场景下比较贴合需求。

### 4. 接入形式简单

TalentHub 当前已经有：

- `KnowledgeReranker` 抽象

因此接 Voyage 时，不需要重写检索链路，只需要新增 provider 实现并切工厂装配。

## 当前设计

### Provider 抽象保持不变

当前仍然沿用：

- `KnowledgeReranker`

调用形态仍然是：

- 输入：`query_text + candidate items`
- 输出：重排后的 `item_id + relevance_score`

### 当前 provider 组合

当前支持：

- `disabled`
- `bge_reranker_v2_m3`
- `voyage`

其中：

- `voyage` 是当前推荐线上方案
- `bge_reranker_v2_m3` 仍保留为本地可切换方案

### 当前默认策略

当前默认仍然是：

- `RERANKER_PROVIDER=disabled`

原因不是 Voyage 不可用，而是：

- 没有配置 `VOYAGE_API_KEY_FILE` 时，不应该强行启用
- 默认运行链路要保持可本地启动

也就是说：

- Voyage 已接入
- 但是否启用，由环境配置决定

## 具体配置

相关配置项包括：

- `RERANKER_PROVIDER`
- `RERANKER_MODEL_NAME`
- `RERANKER_TIMEOUT_SECONDS`
- `VOYAGE_API_KEY_FILE`
- `VOYAGE_API_BASE_URL`

当前推荐值：

- `RERANKER_PROVIDER=voyage`
- `RERANKER_MODEL_NAME=rerank-2.5-lite`

## 和本地 BGE reranker 的关系

TalentHub 当前的策略不是“删掉 BGE”，而是：

- 默认推荐线上 Voyage
- 本地 BGE reranker 作为可切换高级路线保留

这意味着：

- 代码结构仍支持本地路线
- 文档和选型也承认 BGE 的长期价值
- 但当前开发默认不再把它作为主链路

## 当前阶段的取舍

### 这次获得的收益

- 默认运行更轻
- 启用 reranker 的成本更低
- 文本检索链路更容易投入日常使用
- 当 Voyage 配额不足、账号限流或外部网络异常时，系统会明确记录 `knowledge_retrieval_rerank_fallback` 业务日志，并回退到原始向量召回顺序

### 这次付出的代价

- 依赖外部服务
- 本地完全离线能力变弱
- 线上调用的可观测性和失败处理要更清晰

## 后续升级点

### 1. 给 Voyage reranker 加更细的指标

例如：

- 请求耗时
- rerank 输入候选数
- top-k 截断后的效果对比

### 2. 扩大评测集

接入线上 reranker 后，最关键的不是“能调通”，而是：

- 它是否真的提升了 `MRR / NDCG / Recall / Context Precision`

### 3. 继续保留本地 fallback

如果后续有：

- 完全离线部署
- 内网环境
- 数据出网限制

那么仍然可以切回：

- `bge-reranker-v2-m3`

## 总结

这次接入 Voyage reranker 的本质，不是换一个“更炫”的模型，而是做了一次更贴近工程现实的取舍：

- 检索质量继续要
- 但默认运行链路不能太重

因此当前 TalentHub 选择：

- `OpenAI text-embedding-3-large` 负责默认 dense 检索
- `Qdrant` 负责召回
- `Voyage rerank-2.5-lite` 作为当前推荐的线上 reranker
- `BGE` 路线保留为可切换方案
