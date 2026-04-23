# RAG - 08c：Query Routing：让不同问题走不同知识源

## 学习目标（本节结束后你能做到什么）

1. 你能讲清 Query Routing 为什么不是“先分类再检索”这么简单，而是整个知识访问架构的分流层。
2. 你能区分`知识源路由`、`检索器路由`、`策略路由`、`成本路由`四种不同的 routing 维度。
3. 你能设计一个带 fallback、带置信度、支持多路并发的 router，而不是做一个脆弱的单点 if/else。
4. 你能结合 2024-2026 的最新进展，讲出 Adaptive-RAG、Self-Route、Semantic Router、RouterRetriever 这些思路各自在解决什么问题。
5. 面试里被问到“为什么不把所有知识都塞进一个大索引”，你能给出有工程现实感的答案。

---

## 1. 先把问题摆正：统一索引很方便，但“所有问题走同一条路”通常是错的

RAG 系统早期很喜欢一个简单架构：

```text
所有文档 -> 一个向量库 -> 一个检索器 -> 一个 prompt
```

这个结构之所以流行，是因为它非常省心。  
但一旦系统进入真实业务，问题很快就会出现：

- 规范制度和工单记录不该混着搜
- 结构化数据库和 PDF 文档不该走同一检索器
- 实时信息和静态知识的 freshness 要求不同
- 某些问题根本不需要检索，直接长上下文或工具查询更合适

所以 Query Routing 的核心问题不是：

`怎么给 query 打标签？`

而是：

`当前这个问题，最合适的知识访问路径是什么？`

这条路径可能决定：

- 去哪个知识源
- 用哪个检索器
- 是否需要拆分子问题
- 是否需要 web search / SQL / code search
- 是否甚至不该走 RAG

---

## 2. 四种 routing，其实在解决四种不同的系统不匹配

### 2.1 知识源路由（Source Routing）

这是最直观的一类：

- HR 制度去制度库
- 客诉问题去工单库
- API 问题去代码和技术文档
- 实时行情去实时数据源

它解决的是：

`不同知识本来就存放在不同仓里。`

### 2.2 检索器路由（Retriever Routing）

即使在同一知识源里，也不一定都用同一个检索器。

例如：

- 错误码类 query -> BM25 / exact match
- 解释型 query -> hybrid retrieval
- 长文精排 -> ColBERT / reranker

它解决的是：

`不同 query mismatch 需要不同召回器。`

### 2.3 策略路由（Strategy Routing）

这里路由的不是知识源，而是整个方法。

例如：

- 简单事实问题 -> 单跳 RAG
- 复杂多跳问题 -> decomposition + multi-retrieval
- 全局总结问题 -> GraphRAG / RAPTOR / long-context summarize

Adaptive-RAG 就属于这一脉。  
它的重点是按 query complexity 选择：

- no retrieval
- single-shot retrieval
- iterative retrieval

### 2.4 成本路由（Cost Routing）

到 2024-2026，一个越来越现实的问题是：

`不是每个问题都值得走最贵、最长、最复杂的链路。`

Self-Route 这类工作讨论的是：

- 某些问题更适合直接 long-context
- 某些问题更适合走 RAG
- 是否可以通过模型自反思来决定

这说明 routing 已经不只是“去哪个库”，而是：

`这个 query 值得消耗多大系统资源。`

---

## 3. Query Routing 的原理：它是一个带约束的决策层

可以把 router 抽象成：

```text
route = g(query, conversation_state, user_context, policy, budget)
```

输出可能是：

- 单一路径
- 多路径并发
- 主路径 + fallback

这里最重要的不是“分类准确率”本身，而是：

`错分之后系统还能不能活。`

为什么这么说？

因为 router 一旦错，不像 reranker 那样只是排序稍差，  
它可能直接把 query 送进错误世界：

- 问政策，送去工单库
- 问实时报价，送去静态 wiki
- 问 SQL 指标，送去 PDF 手册

所以一个成熟 router 必须具备：

- 置信度
- fallback
- 可并发多路
- 可审计日志

而不是一个一次性拍板的黑盒分类器。

---

## 4. 2024-2026 的关键变化：routing 正从“workflow glue”变成“系统级调度层”

### 4.1 2024：Adaptive-RAG 把“问题复杂度”引入路由决策

Adaptive-RAG 的核心贡献不是又加了一个 fancy workflow，而是指出：

`不是所有 query 都需要同样深的检索过程。`

它把 query 分成不同复杂度，再选择：

- 不检索
- 单步检索
- 多步检索

这说明 routing 的对象可以是`检索深度`本身。

### 4.2 2024：Self-Route 把“RAG vs Long Context”也纳入决策空间

Self-Route 的关键点是：

- 长上下文和 RAG 各有优劣
- 可以让模型通过 self-reflection 选择更合适的路径

这件事很有时代感。  
因为在更早时期，大家默认“有知识问题就上 RAG”。  
但到 2024 以后，更现实的判断已经变成：

`有些问题，直接喂长上下文更便宜或更准；另一些问题，RAG 仍然更稳。`

所以 routing 的决策空间扩大了。

### 4.3 2025-2026：框架和基础设施开始把 routing 做成一等公民

到 2026 年，框架层已经明显把 router 抽成独立组件：

- LlamaIndex 提供 `RouterRetriever`
- Haystack 提供 `ConditionalRouter`
- semantic-router 提供基于语义向量的 route layer，并支持 hybrid routes

这说明 routing 不再只是 agent 里随手写几个 if/else，  
而是开始有：

- 独立 schema
- 独立观测
- 独立评测

换句话说，它在系统里的地位正在接近：

- API gateway 的路由层
- 搜索系统里的 federated search broker

---

## 5. 为什么“所有知识都放一个大索引”通常不是最终答案

### 5.1 因为不同知识源的更新节奏不同

例如：

- 产品手册：更新慢、版本化强
- 工单：实时变化、噪声高
- 数据仓库：结构化、可聚合
- 代码仓：分支多、符号检索重要

如果强行揉成一个统一索引，你会发现：

- freshness 语义混乱
- metadata schema 越来越复杂
- 检索器很难统一优化

### 5.2 因为不同知识源的“真理标准”不同

制度文档通常是 authoritative。  
工单和聊天记录通常只是经验。  
网页搜索可能是最新，但不一定权威。

如果没有 routing，这些来源会在同一个候选池里相互污染。

### 5.3 因为不同知识源需要不同检索方法

例如：

- 文本手册适合 hybrid retrieval
- SQL 适合 schema retrieval + text-to-SQL
- 代码适合 lexical-heavy or AST-aware search
- 图片/PDF 扫描件可能要走多模态检索

一个统一 retriever 很难同时把这些都做好。

---

## 6. 生产里怎么设计一个不脆弱的 router

### 6.1 先问三件事：路由维度、路由代价、错路后果

设计 router 前，先把这三件事说清楚：

1. `你在路由什么？`
   - source、retriever、strategy 还是 budget

2. `路由错了会怎样？`
   - 是轻微降质，还是权限/事实灾难

3. `是否允许多路并发？`
   - 某些问题其实更适合 top-2 routes 并发，再由 rerank 汇总

### 6.2 Router 不应该总是 single-label

很多 query 本来就跨域。  
比如：

`上周支付失败主要是哪个服务的哪个版本引起的？`

这可能同时需要：

- 工单 / 日志
- 版本发布记录
- 事故复盘文档

如果 router 只能单选，它就天然会丢上下文。  
所以更成熟的设计通常支持：

- top-1 with fallback
- top-2 parallel routes
- hierarchical route

### 6.3 置信度阈值和 fallback 比“分类器更准”更重要

一个好 router 不是永远自信，而是知道什么时候不该自信。

典型 fallback 包括：

- 回退到全局 hybrid retrieval
- 回退到多路并发
- 回退到人工定义的高可信知识源

这跟 API gateway 的设计很像。  
你不能指望主路永远正确，但你必须保证坏情况下系统还能工作。

---

## 7. 一个可落地的路由骨架

```python
def route_query(query, user_ctx):
    decision = router.predict(
        query=query,
        user_ctx=user_ctx,
        return_confidence=True,
    )

    if decision.confidence < 0.65:
        routes = ["global_hybrid", "official_policy"]
    else:
        routes = decision.routes

    candidates = []
    for route in routes:
        candidates.extend(execute_route(route, query, user_ctx))

    return reranker.rerank(query, dedupe(candidates), top_k=12)
```

这个骨架里，真正重要的不是 `predict()` 用什么模型，  
而是：

- 低置信度怎么办
- 多路结果怎么合并
- 每条 route 的 SLA 和权限边界怎么定义

---

## 8. Query Routing 最容易踩的 8 个坑

### 8.1 把 router 做成一堆写死的 if/else

刚开始很快，半年后必炸。  
因为知识源和 query 类型只会越来越多。

### 8.2 路由标签太细

标签一多，训练和维护都困难，线上误分也更频繁。  
通常应从较粗的 route taxonomy 起步。

### 8.3 路由后没有 fallback

这是最危险的问题。  
错路一次，系统就彻底答偏。

### 8.4 混淆“权限过滤”和“路由”

权限是硬约束，不该交给 router 猜。  
router 决定去哪；ACL 决定哪些内容可看。

### 8.5 没把 conversation state 纳入决策

多轮对话里，当前 query 很短，主语和上下文都在历史里。  
只看当前句，经常路由错。

### 8.6 不评测 route-level confusion matrix

你需要知道：

- 哪些 query 经常被错送
- 哪些 route 互相混淆
- 错分后损失有多大

### 8.7 把 router 当成最终答案生成器

router 的任务是调度，不是总结。

### 8.8 只做 source routing，不做 strategy routing

很多系统路由到正确知识源后，仍然失败。  
原因不是源错了，而是方法错了：

- 应该多跳，却走了单跳
- 应该长上下文，却走了狭窄 RAG

---

## 9. 面试里怎么答，才像理解过“系统级调度”

如果面试官问：

`为什么不把所有知识都放一个大向量库里？`

你可以答：

> 因为不同知识源的更新频率、权威性、结构、权限和最优检索方法都不同。统一索引虽然实现简单，但会牺牲 freshness、authoritativeness 和 retrieval specialization。更成熟的做法是在路由层先决定知识访问路径，再在对应源内选择合适的检索策略，并保留低置信度 fallback。

如果面试官再问：

`router 错了怎么办？`

你可以答：

> 不能把 router 设计成一次性拍板。线上应该有置信度阈值、多路并发或 fallback route，并且按 route 记录命中率和错分代价。对于高风险领域，还要把 authoritative source 设成兜底路径。

---

## 小结

1. Query Routing 的本质，是决定当前问题最合适的知识访问路径，而不是简单给 query 打标签。
2. 它至少有四类：知识源路由、检索器路由、策略路由、成本路由。
3. 2024-2026 的重要变化，是 routing 开始覆盖“RAG vs long context”“single-hop vs multi-hop”这类更高层决策。
4. 成熟 router 的关键不是分类器多聪明，而是有置信度、fallback、多路并发和可观测性。
5. 一个大统一索引很适合起步，但往往不是复杂企业知识系统的最终形态。

---

## 检查站

1. Source routing 和 strategy routing 的区别是什么？
2. 为什么一个没有 fallback 的 router 比一个排序差一点的 retriever 更危险？
3. 如果你发现某类 query 同时需要 wiki、工单和数据库，router 该如何演进？

---

## 参考与延伸阅读

- Jeong et al., *Adaptive-RAG: Learning to Adapt Retrieval-Augmented Large Language Models through Question Complexity* (NAACL 2024)  
  https://aclanthology.org/2024.naacl-long.389/
- Li et al., *Self-Route: LLMs as Routers for Long Context vs. RAG* (EMNLP 2024)  
  https://aclanthology.org/2024.emnlp-industry.66/
- LlamaIndex Docs, *Router Retriever*  
  https://docs.llamaindex.ai/en/stable/examples/retrievers/router_retriever/
- Haystack Docs, *ConditionalRouter*  
  https://docs.haystack.deepset.ai/docs/conditionalrouter
- semantic-router  
  https://github.com/aurelio-labs/semantic-router
