# BGE Hybrid、Reranker 与评测基线设计

## 1. 目的

这份文档描述 TalentHub 当前这一轮检索主线收敛后的状态：

- 默认 embedding 切回 `BGE-M3`
- 默认 reranker 接入 `bge-reranker-v2-m3`
- 检索主路径继续使用 `Qdrant`
- 检索质量不再只靠“体感”，而是建立 `Ragas + ranx` 基线

它回答三个问题：

1. 为什么默认路线又从 `OpenAI embedding` 切回 `BGE`
2. reranker 进入主链路后，召回和精排怎么分工
3. 如何用一套可重复执行的评测基线约束后续优化

## 2. 当前默认检索路线

TalentHub 当前默认检索路线是：

- `父子 chunk`
- `BGE-M3`
- `Qdrant hybrid retrieval (dense + sparse + multi-vector)`
- `bge-reranker-v2-m3`
- `Ragas + ranx` 评测基线

其中职责划分是：

- PostgreSQL：业务真相来源
- Qdrant：hybrid 候选召回
- BGE-M3：子块 dense / sparse / multi-vector embedding
- bge-reranker-v2-m3：候选片段精排
- Ragas + ranx：离线检索质量评测

## 3. 为什么默认路线切回 BGE

前一阶段把默认 embedding 临时切到 `OpenAI text-embedding-3-large`，解决的是：

- 默认镜像更轻
- 容器重建更快
- dense 检索主路径可以先稳定下来

这个阶段的任务已经完成：

- 父子 chunk 已落地
- Qdrant 已成为唯一检索 backend
- embedding provider 已完成抽象

在这些结构稳定后，再继续维持 `OpenAI` 为默认值会带来新的问题：

- 文档主线和默认实现继续分裂
- hybrid 设计无法真正推进
- reranker 与评测基线会变成“挂在旁边的高级功能”，而不是主链路的一部分

因此当前策略是：

- `BGE-M3` 回到默认 embedding 路线
- `OpenAI text-embedding-3-large` 保留为可切换 dense provider

## 4. 为什么 reranker 要进入主链路

TalentHub 的检索结果不是只给用户“看一堆命中片段”，而是会继续进入：

- 基于知识库出题
- 跨知识库出题
- 判卷后学习建议
- 出处引用

这类场景对 `top-k` 的排序质量非常敏感。只做 dense 召回会遇到两个典型问题：

- 召回到的结果“都相关”，但前几条不够聚焦
- 术语、时间点、规则编号命中后，最值得送给大模型的片段不一定排在最前

所以当前把检索分成两层：

1. `Qdrant` 做候选召回
2. `bge-reranker-v2-m3` 对候选做精排

这两层的边界必须清楚：

- 召回负责“找全、找准候选”
- 精排负责“把最该进入业务链路的结果排前面”

## 5. 当前检索主链路

### 5.1 文档索引

1. 知识文档进入 Knowledge 模块
2. 文本切成父块和子块
3. 子块构造 embedding 文本
4. `BGE-M3` 生成：
   - `1024` 维 dense 向量
   - sparse lexical weights
   - multi-vector colbert 表示
5. 子块向量写入 `Qdrant`
6. 父块与子块结构留在 PostgreSQL

### 5.2 检索

1. 输入 query
2. `BGE-M3` 生成 query 的 dense / sparse / multi-vector 表示
3. `Qdrant` 通过 `RRF` 融合三路召回结果
4. PostgreSQL 补齐子块正文、父块上下文、文档标题和来源信息
5. `bge-reranker-v2-m3` 对候选重新排序
6. 返回最终 top-k 结果

### 5.3 业务使用

当前已经走这条链路的场景：

- 知识库检索预演
- 跨知识库检索预演
- 基于知识文档出题
- 基于知识库问题出题
- 判卷后学习引用

## 6. 评测基线的定位

当前评测基线不是“大而全”的统一评测平台，而是一个明确的第一版约束：

- 先验证检索链路是否按预期命中
- 先验证变更后性能是否退化
- 先给后续 chunking / sparse / multi-vector 优化提供对照组

### 6.1 `ranx` 负责什么

`ranx` 负责传统检索指标：

- `MRR@5`
- `NDCG@5`
- `Recall@5`

它回答的是：

- 正确片段有没有被召回
- 正确片段排得靠不靠前

### 6.2 `Ragas` 负责什么

当前评测里，`Ragas` 先用于 **ID-based context evaluation**：

- `IDBasedContextPrecision`
- `IDBasedContextRecall`

也就是说，当前先不把评测绑定到大模型判断，而是先验证：

- 检索返回的 chunk id 是否正确
- 参考 chunk id 是否被命中

这样可以保证第一版评测：

- 稳定
- 可重复
- 不依赖额外 LLM 成本

## 7. 当前实现边界

当前已经完成：

- `BGE-M3` 默认化
- `Qdrant hybrid retrieval` 主链路接入
- `bge-reranker-v2-m3` 主链路接入
- `Ragas + ranx` 第一版检索评测基线

### 7.1 当前基线结果

当前第一版离线评测报告落在：

- `storage_data/evaluations/retrieval_baseline_latest.json`

基于当前样本集的结果是：

- `MRR@5 = 1.0`
- `NDCG@5 = 1.0`
- `Recall@5 = 1.0`
- `IDBasedContextRecall = 1.0`
- `IDBasedContextPrecision = 0.2`

这组结果说明了两件事：

1. 正确 chunk 已经稳定进入前 5，召回和首条排序在当前样本上是达标的
2. 返回结果里仍然带有较多“相关但不是目标 chunk”的片段，当前 top-k 纯度还不够高

也就是说，当前主链路已经具备：

- “能命中”
- “能排在前面”

但还没有完全做到：

- “返回结果足够干净”
- “前几条候选都尽量只围绕目标知识点”

这正是下一步继续扩大评测集、调优 hybrid 融合和 reranker 策略的原因。

当前还没有完成：

- 更大规模、更接近真实业务的评测集
- 基于 Grafana 或独立页面的检索评测观察界面
- 图片、截图、课件页的原生多模态检索

## 8. 解决了什么问题

这一轮解决了四个关键问题：

1. 默认实现终于和长期主线设计重新对齐
2. 检索质量不再只依赖 dense 召回
3. reranker 不再是概念选型，而是进入真实业务链路
4. 检索优化开始有可重复的评测基线，而不是只靠手感调参

## 9. 下一步

最自然的下一步是：

1. 扩展评测集，覆盖更多中英混合、术语、编号、长文档场景
2. 对 hybrid 融合策略、候选规模和 reranker 截断做更系统的调优
3. 给检索质量提供更直观的观察和回归入口
4. 再考虑图片和图文混合知识的正式检索通道
