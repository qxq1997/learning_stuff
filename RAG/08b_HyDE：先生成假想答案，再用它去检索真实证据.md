# RAG - 08b：HyDE：先生成假想答案，再用它去检索真实证据

## 学习目标（本节结束后你能做到什么）

1. 你能讲清 HyDE 的核心原理：为什么“先生成一篇假想文档”反而能改善检索。
2. 你能解释 HyDE 为什么尤其适合 zero-shot dense retrieval，以及它为什么不是“让模型先回答一遍再装作有证据”。
3. 你能判断 HyDE 适合哪些 query、不适合哪些 query，并设计 selective HyDE 策略。
4. 你能把 2024-2026 的演化讲出来：HyDE 不再是默认全局开关，而更像 query transform 工具箱里的`条件性武器`。
5. 面试里如果被质疑“这不就是先 hallucinate 再检索吗”，你能给出准确且有说服力的回应。

---

## 1. 先把误解打掉：HyDE 不是让模型先编一个答案，再把编的东西当证据

第一次听到 HyDE（Hypothetical Document Embeddings）时，很多人会本能觉得：

`这不就是先让模型胡编一个答案，然后拿胡编内容去搜吗？`

这个理解只对了一半，而且容易把 HyDE 说歪。

HyDE 真正的流程是：

1. 给定用户问题
2. 让 LLM 生成一段“可能长什么样的答案文档”
3. 对这段假想文档做 embedding
4. 用这个 embedding 去检索真实语料
5. 最终回答仍然只能基于检索到的真实证据

关键点在第 3 步和第 5 步：

- 假想文档只是`检索探针`
- 不是最终证据
- 也不是最终答案

所以 HyDE 的价值不在“先答一遍”，而在：

`把过短、过抽象的 query，变成更像目标文档分布的表达。`

---

## 2. 原理：为什么“假想文档”反而比原问题更适合做 dense retrieval

### 2.1 query 和 document 处在不同分布上

dense retrieval 有一个很容易被忽视的问题：

- 用户 query 通常很短
- 文档 chunk 通常更长、更完整、更像自然段

也就是说，query 和 document 本来就不长得像。  
哪怕 encoder 很强，这种`分布错位`也依然存在。

HyDE 的想法非常聪明：

- 不强迫模型直接把短 query 映射到文档空间
- 先让 LLM 生成一个“像文档的东西”
- 再去做 embedding

于是 query 不再是一个稀疏的、短的、信息量有限的探针，  
而变成一个更接近文档流形的向量。

### 2.2 HyDE 为什么不会被 hallucination 彻底带偏

HyDE 论文最关键的一句解释是：

`假想文档里的不准确细节会通过 dense bottleneck 被过滤掉，而整体相关模式会保留下来。`

换句话说：

- LLM 生成的伪文档确实可能有错
- 但 embedding 只保留较高层次的语义模式
- 检索时真正参与匹配的是这种语义轮廓，而不是逐字事实

所以 HyDE 的有效性，依赖的不是 LLM 先“答对”，而是：

`生成出的文档要足够像“如果这个答案存在，它会怎么被写在文档里”。`

### 2.3 HyDE 最适合补的是 dense retrieval 的 query-side 表达不足

它尤其擅长的场景包括：

- 查询很短
- 查询很抽象
- 查询是说明性问题，不是精确定位
- 没有标注数据，无法训练专门 query encoder

这也是为什么 HyDE 最初被称为`Precise Zero-Shot Dense Retrieval without Relevance Labels`。

---

## 3. 经典流程与一个必须坚持的边界

HyDE 的标准流程可以画成：

```mermaid
flowchart LR
    Q[用户问题] --> G[LLM 生成假想答案文档]
    G --> E[对假想文档做 embedding]
    E --> R[向量检索真实文档]
    R --> RR[重排 / 过滤]
    RR --> A[基于真实证据回答]
```

这里最重要的边界是：

`假想文档绝不能直接进入最终回答上下文。`

也就是说：

- 它只在 query transform 阶段存在
- 最终 prompt 里应该只放真实召回结果
- citation 也只能引用真实文档

一旦你把 HyDE 生成的伪文档当作证据一起塞给模型，系统就会失去可审计性。

---

## 4. 2024-2026 的演化：HyDE 还重要，但它的定位变了

### 4.1 2023：HyDE 解决的是“没有标注、query 太短、dense retrieval 不稳”

ACL 2023 的 HyDE 论文把价值讲得很清楚：

- zero-shot
- 无 relevance label
- 通过 hypothetical document 改善 dense retrieval

在那个阶段，HyDE 很像一个非常巧妙的“query 变形器”。

### 4.2 2024：更多工作开始意识到“扩写不能脱离语料分布”

到 2024 年，像 CSQE 这类工作开始强调：

- LLM 自由生成的扩写有漂移风险
- query transform 不能只靠模型脑补
- 最好让扩写受 corpus steering

这会反过来影响你对 HyDE 的使用方式：

- 不要无条件全局开启
- 最好和原 query 并行，而不是完全替代原 query
- 最好结合 rerank 和 metadata 约束

### 4.3 2024-2025：更强 embedding、Contextual Retrieval、长上下文让 HyDE 从“默认技巧”变成“条件性技巧”

随着：

- embedding 模型变强
- hybrid retrieval 普及
- rerank 普及
- Anthropic 这类 contextual retrieval 出现

HyDE 的角色发生了一个很明显的迁移：

`它不再是所有 query 的默认前置步骤，而更像针对特定 query 类型的增强器。`

也就是说，今天一个成熟系统更可能这样做：

- exact lookup：不用 HyDE
- dense semantic query：可能开 HyDE
- 多跳复杂问答：与多路召回结合

### 4.4 到 2026：HyDE 更常以“一个分支”而不是“唯一 query”存在

这点非常关键。

现在更成熟的做法通常不是：

- 先把原 query 替换成 HyDE 文档

而是：

- 原 query 作为一个分支
- HyDE 生成文档作为另一个 dense 分支
- 两路 union 后再 rerank

这样做的好处是：

- 原 query 保留用户原始约束
- HyDE 分支补语义展开
- 两者互相纠偏

---

## 5. HyDE 为什么有效，什么时候会失效

### 5.1 最适合的场景

HyDE 通常更适合：

- 解释型问题
- 概念型问题
- 开放式问答
- 零样本领域迁移
- 用户不知道专业术语，只会口语描述

比如：

- `为什么数据库会出现幻读？`
- `门禁停用流程一般会包含什么步骤？`
- `这个错误通常是哪里配置有问题？`

### 5.2 不太适合的场景

HyDE 常见失效场景包括：

- 精确 ID / 错误码 / 配置名查询
- 文档要求强词面匹配
- query 本身已经很明确
- LLM 对该领域完全没概念

比如：

- `ERR_CONN_RESET 1127`
- `invoice_status=17`
- `函数 FooBarConfig 的默认参数`

这类问题，HyDE 反而可能把 query 从精确查找带偏到抽象语义相似。

### 5.3 中文企业语料里的一个额外风险：术语漂移

企业内部术语经常很奇怪：

- 不是公开标准词
- 系统 A、系统 B、制度文档里叫法不同

如果 LLM 生成的假想文档更像“通用互联网表达”，而你的语料更像“内部黑话”，HyDE 的收益就会下降。  
这也是为什么它最好和：

- 原 query
- 术语扩展
- metadata filter

一起使用。

---

## 6. 生产里怎么把 HyDE 用对：关键不是“开不开”，而是“何时开、怎么并联”

### 6.1 最稳的方式：把 HyDE 当成 dense branch augmentation

不要把 HyDE 当作替代 query 的唯一输入。  
更稳的生产方式通常是：

- 原 query 跑 hybrid retrieval
- HyDE 文档只跑 dense retrieval
- 两路结果做 union + rerank

原因很简单：

- BM25 不适合吃假想长文
- 词法约束仍然应该保留给原 query

### 6.2 Selective HyDE 比全局 HyDE 更现实

一个很实用的启发式是：

- query 太短且无明显精确 token：开 HyDE
- query 含错误码、SKU、版本号、函数名：关 HyDE
- query 是解释型或 why/how：更适合开

这件事完全可以通过一个轻量 classifier 或规则系统来做。

### 6.3 一次不够，可以做多假设，但要克制

可以让模型生成 2-3 个不同角度的假想答案，再分别检索。  
但和多路召回一样，边际收益很快递减。

过多假设的问题在于：

- latency 叠加
- drift 风险增加
- rerank 压力增大

所以多数系统里，`1-2 个 HyDE 分支`已经够用了。

---

## 7. 一个可落地的实现骨架

```python
def hyde_retrieve(query: str):
    pseudo_doc = llm.generate(
        f"写一段可能回答这个问题的说明性文字，但不要编造具体来源：{query}"
    )

    dense_from_query = vector_index.search(embed(query), top_k=40)
    dense_from_hyde = vector_index.search(embed(pseudo_doc), top_k=40)

    candidates = union_and_dedupe([dense_from_query, dense_from_hyde])
    return reranker.rerank(query, candidates, top_k=10)
```

这里有两个注意点：

1. 最终 rerank 仍然基于原 query  
2. 最终回答只用真实候选，不使用 `pseudo_doc`

---

## 8. HyDE 最容易踩的 8 个坑

### 8.1 把假想文档直接当证据

这是原则性错误。

### 8.2 用 HyDE 替代原始 query

这样会丢掉用户原始词面约束。

### 8.3 对 exact lookup 类问题也默认开 HyDE

这类问题常常越变形越差。

### 8.4 温度太高，导致 pseudo_doc 漂移

HyDE 追求的不是创意，而是稳定的语义轮廓。  
一般应使用较低温度。

### 8.5 LLM 对领域一无所知，却期待它生成有用假设

如果模型连问题大概属于什么领域都摸不着，生成出来的文档只会误导检索。

### 8.6 不做 rerank

HyDE 会扩大 dense branch 的语义覆盖，但不会替你做最终精排。

### 8.7 忽略 metadata filter

HyDE 只改造 query 表达，不解决权限、时间、来源这些约束。

### 8.8 没有缓存

很多企业查询其实重复度不低。  
HyDE 生成本身有 LLM 成本，适合按归一化 query 做缓存。

---

## 9. 面试里怎么讲，才不会把 HyDE 说成“高级 hallucination”

如果面试官问：

`HyDE 不就是先 hallucinate 再检索吗？`

你可以这样答：

> 不是。HyDE 生成的伪文档只用于构造更好的 dense retrieval 查询表示，不会作为最终证据进入回答。它利用的是“文档式表达比短 query 更接近文档分布”这一点，而不是利用 hallucination 本身。真正进入 prompt 的仍然必须是检索到的真实文档。

如果面试官再问：

`现在 embedding 都更强了，HyDE 还有意义吗？`

你可以答：

> 还有，但定位变了。今天它更像 selective query transform，适合短、抽象、说明性 query；对精确查询和强词法约束 query，不应该默认启用。更成熟的用法是把它作为一个 dense branch augmentation，与原 query 并联而不是替代。

---

## 小结

1. HyDE 的本质，是把短 query 转成更像文档分布的表达，再用于 dense retrieval。
2. 它不是让模型先编答案当证据，而只是生成检索探针。
3. HyDE 尤其适合短、抽象、解释型 query，不适合 exact lookup。
4. 到 2026 年，它更常作为条件性分支存在，而不是所有 query 的全局默认前置步骤。
5. 最稳的工程做法是：`原 query + HyDE 分支 -> union -> rerank -> 只用真实证据回答`。

---

## 检查站

1. 为什么 HyDE 更像“query transform”，而不是“先回答再检索”？
2. HyDE 为什么通常只适合 dense branch，而不适合直接替换 BM25 分支？
3. 如果线上监控发现 HyDE 在错误码类 query 上让效果变差，你会怎样改 gating 规则？

---

## 参考与延伸阅读

- Gao et al., *Precise Zero-Shot Dense Retrieval without Relevance Labels* (ACL 2023)  
  https://aclanthology.org/2023.acl-long.99/
- Mo et al., *Corpus-Steered Query Expansion with LLMs* (Findings of EMNLP 2024)  
  https://aclanthology.org/2024.findings-emnlp.103/
- Anthropic, *Introducing Contextual Retrieval*  
  https://www.anthropic.com/engineering/contextual-retrieval
