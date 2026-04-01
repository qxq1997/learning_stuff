# BGE Sparse、Multi-Vector Hybrid 接入设计

## 1. 目的

这份文档描述 TalentHub 当前这一轮 RAG 检索主线真正完成后的状态：

- `BGE-M3` 不再只作为 dense embedding provider
- `Qdrant` 正式承接 dense + sparse + multi-vector 三路召回
- `bge-reranker-v2-m3` 负责召回后的候选精排
- `Ragas + ranx` 基线开始以 hybrid 主路径为准

它回答的问题是：

1. 为什么 `BGE-M3` 要从 dense-only 继续推进到 hybrid 主路径
2. `Qdrant` 在 TalentHub 里如何承接三路召回
3. 这一轮落地后，系统真正解决了什么问题，边界还剩什么

## 2. 当前默认检索路线

TalentHub 当前默认检索路线是：

- 父子 chunk
- `BGE-M3`
- `Qdrant hybrid retrieval (dense + sparse + multi-vector)`
- `bge-reranker-v2-m3`
- `Ragas + ranx`

职责边界如下：

- PostgreSQL：业务真相来源，存文档、版本、父子 chunk、题目引用关系
- Qdrant：检索表示与候选召回
- BGE-M3：为 query 和 child chunk 生成 dense / sparse / multi-vector 表示
- bge-reranker-v2-m3：对召回候选重新排序
- Ragas + ranx：对召回质量做离线基线评测

## 3. 为什么要继续从 dense-only 走到 hybrid

前一阶段的 dense + reranker 已经能把检索链路跑通，但仍然存在两个结构性问题：

- 企业术语、编号、缩写、时间点等信号，不应该只靠 dense 语义近似去碰运气
- 一段长文档里有多个知识点时，只靠单一 dense 向量容易把局部重点平均掉

因此，TalentHub 继续推进 hybrid 的目的不是“把技术栈做复杂”，而是解决实际业务问题：

- 让知识库检索对制度名、规则编号、截止时间更稳
- 让出题前召回的 top-k 更聚焦
- 让判卷后的学习建议引用更贴近真正的知识点

## 4. 为什么选 BGE-M3

`BGE-M3` 在 TalentHub 里最有价值的不是单纯的 dense embedding，而是它同时覆盖了三种检索表示：

- dense：整体语义相似
- sparse：术语、编号、关键词信号
- multi-vector：局部语义细粒度匹配

这意味着 TalentHub 不需要同时拼接多个文本检索模型，就能先把 hybrid 的主骨架建立起来。

## 5. 当前主链路

### 5.1 文档索引

1. 知识文档进入 Knowledge 模块
2. 文本切成父块和子块
3. 子块构造 embedding 文本
4. `BGE-M3` 为每个子块生成：
   - dense embedding
   - sparse lexical weights
   - colbert-style multi-vectors
5. 写入 `Qdrant`
6. PostgreSQL 保留父子 chunk 正文、结构和引用关系

### 5.2 检索

1. 输入 query
2. `BGE-M3` 生成 query 的 dense / sparse / multi-vector 表示
3. `Qdrant` 对三路表示并行召回候选
4. `Qdrant` 使用 `RRF` 融合三路候选
5. PostgreSQL 补齐子块正文、父块上下文、文档来源
6. `bge-reranker-v2-m3` 对候选重新排序
7. 返回最终 top-k 片段

### 5.3 当前已经使用这条主链路的业务场景

- 知识库检索预演
- 跨知识库检索预演
- 基于知识文档出题
- 基于知识库问题出题
- 判卷后学习引用与回看建议

## 6. 解决了什么问题

这一轮落地后，TalentHub 解决了五个关键问题：

1. 默认实现和长期检索主线终于完全对齐
2. 检索不再只依赖 dense 语义近似
3. 企业术语、编号、关键词信号开始进入正式召回主路径
4. 长文档局部知识点可以通过 multi-vector 更稳定地被命中
5. 评测基线终于能约束真正的默认检索链路，而不是一个简化版 dense 路线

## 7. 当前边界

当前已经完成：

- `BGE-M3` hybrid embedding 主路径接入
- `Qdrant` hybrid retrieval 主路径接入
- `bge-reranker-v2-m3` 精排
- `Ragas + ranx` 基线更新到 hybrid 路线

当前仍未完成：

- 更大规模、更多业务样本的评测集
- hybrid 融合参数和候选规模的系统调优
- 图片、截图、课件页的独立多模态检索通道
- 历史旧知识文档的全量重建索引工具

## 8. 下一步

最自然的下一步是：

1. 扩大评测集覆盖面
2. 对召回候选数、RRF 融合和 reranker 截断做系统调优
3. 补全全量重建索引工具
4. 再进入图片与图文混合知识检索
