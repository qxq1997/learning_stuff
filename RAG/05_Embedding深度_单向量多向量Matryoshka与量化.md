# RAG - 第 5 课：Embedding 深度：单向量、多向量、Matryoshka 与量化

## 学习目标（本节结束后你能做到什么）

1. 你能讲清 embedding 在 RAG 里到底承担什么角色，以及为什么“换个更强 embedding 模型”常常能直接改变检索上限。
2. 你能区分 single-vector bi-encoder、cross-encoder、late interaction / multi-vector 三条路线，并知道它们分别适合检索链路的哪一层。
3. 你能解释 Matryoshka Representation Learning（MRL）为什么在 2024 之后变得重要，以及它和量化根本不是一回事。
4. 你能从工程视角讲清 int8 / binary quantization、维度截断、检索延迟、显存 / 存储占用之间的取舍。
5. 你能基于文档类型、语言、上下文长度、部署方式，对 `bge`、`gte / mGTE`、`Qwen3-Embedding` 给出一个现实可用的选型框架。
6. 你能读懂 MTEB 这类 benchmark 的价值和局限，不会把排行榜当作“生产环境唯一真相”。

---

## 1. 先把问题摆正：embedding 不是“把文本变成向量”这么简单

很多人第一次做 RAG，会把 embedding 理解成：

- 输入一段文本
- 输出一个向量
- 用余弦相似度比一下

这当然没错，但远远不够。

在检索系统里，embedding 真正要解决的是：

`如何把自然语言问题和知识片段压缩进同一个可比较的表示空间。`

这里“压缩”两个字非常关键。

为什么？

因为原始文本里有大量信息：

- 主题
- 语气
- 结构
- 关键词
- 局部关系
- 长距离依赖
- 实体指代

而 embedding 最终交给向量库的，可能只是：

- 一个 768 维向量
- 一个 1024 维向量
- 或若干 token-level 向量

这意味着 embedding 本质上是在做取舍：

- 哪些信息保住
- 哪些信息被平均掉
- 哪些信息被量化损失掉

所以“embedding 模型选型”从来都不是换个 API 名字那么简单，  
它本质上是在决定：

`你愿意用多少表示能力，换取多少检索效率。`

---

## 2. embedding 在检索链路里到底放在哪

如果把整个 retrieval stack 抽象一下，大致是：

```mermaid
flowchart LR
    Q[用户问题] --> E[Embedding / Representation]
    D[文档 / chunk] --> E2[Embedding / Representation]
    E --> S[ANN / Similarity Search]
    E2 --> S
    S --> R[Rerank / Re-score]
    R --> C[Context Assembly]
```

embedding 这一层做的是：

- 把 query 映射到检索空间
- 把文档映射到检索空间
- 让相似性比较可计算、可索引、可压缩

它直接影响三件事：

1. `Recall 上限`
   - 如果表示空间本身没把相关内容拉近，后面的 rerank 根本看不到正确候选

2. `检索成本`
   - 向量维度、向量数量、量化方式都会影响索引大小和 ANN 成本

3. `跨语言 / 跨域泛化`
   - 同样的 retrieval pipeline，对中英混合、代码、表格描述、长文段落的稳健性差异很大

所以 embedding 是：

`RAG 检索层里最典型的“先决定上限，再决定成本”的模块。`

---

## 3. 先把三条路线分清：single-vector、cross-encoder、multi-vector

这三类模型在面试里经常被混说，但它们不是同一个东西。

### 3.1 Single-vector bi-encoder：最主流的第一阶段检索器

最常见的 dense retrieval 方式是：

- query 单独编码成一个向量
- 文档单独编码成一个向量
- 用向量相似度做 ANN 检索

这类方法的长处：

- 文档向量可预计算
- 查询延迟低
- 易于做大规模 ANN

也是为什么它成为生产 RAG 的默认主力。

但它的代价同样明显：

`一个向量必须概括整段文本。`

于是：

- 多主题段落会被平均化
- 局部词项和细粒度约束会被稀释
- query 中的某个关键 token 不一定被稳定保住

### 3.2 Cross-encoder：不是 embedding 模型，但必须拿来对照

cross-encoder 的输入是 query 和文档一起编码。  
它不产出可索引的独立文档向量，而是直接输出 pair-wise relevance score。

它的价值不在大规模第一阶段检索，而在：

- 精排
- 细粒度相关性判断
- 复杂条件和局部匹配

所以面试里如果有人问：

`embedding 和 reranker 区别是什么？`

一个很稳的回答是：

- bi-encoder embedding 负责大规模粗召回
- cross-encoder 负责第二阶段精排

### 3.3 Multi-vector / Late Interaction：在效果和效率之间重新找折中

ColBERTv2 的 NAACL 2022 论文把 late interaction 这条路线讲得很清楚：

- 查询和文档仍然分别编码
- 但不是压成单个向量
- 而是保留 token-level 或局部多向量表示
- 打分时做细粒度 interaction

论文摘要里明确强调：

- 它相比 single-vector 检索效果更强
- 但空间成本更大
- ColBERTv2 通过 residual compression 将 footprint 压缩了 6-10 倍

这条路线特别值得记住，因为它点破了一个事实：

`single-vector 检索的根本瓶颈，不是训练不够，而是信息压缩得太狠。`

所以 multi-vector 的本质，是在说：

`不要急着把整段文本压成一个点。`

---

## 4. single-vector 为什么能赢这么久：不是因为最好，而是因为“最值”

这点非常重要。  
很多人看完 ColBERT 或更复杂的多向量模型后，会自然觉得 single-vector 很落后。

但现实里 single-vector 仍然长期占主流，原因不是因为它一定效果最好，而是因为：

`它是大规模检索里性价比最高的默认点。`

它赢在：

- 预编码简单
- 索引成熟
- 存储成本低
- ANN 生态成熟
- 对大多数企业问答 already good enough

也就是说，single-vector 是工程均衡点。

所以真正成熟的理解不是：

- “single-vector 过时了”

而是：

- “single-vector 依然是默认基座，但越来越多场景会在第二阶段或高价值路径上叠加 multi-vector / reranker。”

---

## 5. 一个向量里到底压了什么：pooling、normalization、instruction，本身都不是小事

很多工程团队用 embedding 时容易忽略三个细节。

- **Pooling**：把一堆 token 向量“压缩”成一个文本向量。
- **Normalization**：把向量长度统一，方便做相似度比较。
- **Instruction**：告诉 embedding 模型“你现在是为了什么任务来编码这段文本”。

### 5.1 pooling 决定“整段文本如何被概括”

常见做法包括：

- CLS pooling
- mean pooling
- last-token pooling

它们不是完全等价的。  
同一个 encoder，不同 pooling 方式，检索效果会有明显差异。

因为 pooling 决定了：

- 你更强调整体主题
- 还是最后位置的表示
- 还是所有 token 的平均语义

### 5.2 normalization 决定相似度空间的几何性质

很多 embedding pipeline 会在向量输出后做 L2 normalize。  
这样做的效果是：

- 让 cosine similarity 更稳定
- 把模型输出的向量尺度变化抹平

如果不想清楚这一层，后面你在：

- cosine
- dot product
- ANN index distance

之间很容易出现不一致。

### 5.3 instruction / query prefix 很多时候是模型能力的一部分

很多现代 embedding 模型已经不再默认 query/document 完全同分布。  
而是会建议：

- query 走 instruction-style prefix
- document 走 plain text

这说明一件很重要的事：

`现代 embedding 模型越来越把“检索任务意图”显式编码进输入协议里。`

如果你忽略这些使用方式，  
线上效果可能会明显低于模型卡上的结果。

---

## 6. 2024 → 2026：embedding 这一层到底变了什么

### 6.1 2024：从“更强单向量”走向“多功能统一模型”

2024 年最有代表性的工作之一是 `BGE-M3`。

arXiv 论文标题就把野心写得很清楚：

`Multi-Linguality (100+ languages), Multi-Functionality (dense retrieval, sparse retrieval, multi-vector / ColBERT), Multi-Granularity (input up to 8192 tokens)`

这件事意义很大，因为它说明 2024 年 embedding 模型已经不再满足于：

- 只做 single-vector dense retrieval

而是开始尝试把：

- dense
- sparse
- multi-vector

统一进一个模型族里。

这实际上在逼近一个更成熟的工业需求：

`我们不想为每个 retrieval stage 维护完全不同的模型生态。`

### 6.2 2024：Matryoshka 开始从研究概念进入检索实践

Matryoshka Representation Learning（NeurIPS 2022）的思想在 2024 之后突然变得非常重要，原因很现实：

- embedding 越来越长
- 检索和存储成本越来越高
- 大家开始强烈需要“同一个向量能不能按预算伸缩”

MRL 的核心直觉非常漂亮：

`让 embedding 的前缀子向量本身也有用。`

也就是说，一个 1024 维向量，不是只能完整使用；  
它的前 512 维、前 256 维也应该保留尽量好的语义表示能力。

这就带来非常强的工程价值：

- 同一模型可适配不同延迟 / 成本预算
- 同一索引可尝试不同维度截断
- coarse retrieval 和 fine retrieval 可以共享同一表示体系

### 6.3 2025：长上下文 embedding 变成硬需求，而不是可选特性

随着 chunking 进入 late chunking、contextual retrieval 和长文档 retrieval 阶段，  
embedding 模型开始被明确要求支持：

- 更长输入
- 更稳的长上下文表征
- 跨语言和跨任务泛化

`mGTE` / `gte` 这条线很能体现这个趋势。  
arXiv 论文标题就直说：

`Generalized Long-Context Text Representation and Reranking Models for Multilingual Text Retrieval`

这里两个关键词非常关键：

- `Long-Context`
- `Generalized`

也就是：

`不是只在英文短句上强，而是要在长文、多语言、多个检索相关任务上都能用。`

### 6.4 2025-2026：embedding 和 reranker 越来越成对发布

一个值得注意的产业趋势是：

- 模型发布不再只给 embedding
- 而是 embedding + reranker 一起给

Qwen3 这条线特别典型。  
官方 Hugging Face 模型卡直接把 `Qwen3-Embedding` 和 `Qwen3-Reranker` 成对发布，并明确强调：

- 支持多语言、多语种代码、文本检索
- 支持自定义 embedding dimensions
- 支持 Matryoshka Representation Learning（MRL）
- 支持 binary quantization

这说明到 2026 年，产业侧已经越来越把检索看成：

`表示模型 + 精排模型 + 可伸缩表示预算`

的组合问题，而不是单个 embedding 名字。

---

## 7. Matryoshka Representation Learning：为什么它不是“向量裁剪技巧”，而是训练目标变化

这是本节最值得讲透的部分之一。

### 7.1 先讲直觉

正常 embedding 训练里，一个 1024 维向量通常只在“完整 1024 维”时被优化。  
如果你上线后为了省钱，直接截成前 256 维：

- 有时还能用
- 但效果常明显下降

因为模型根本没被训练成“前 256 维也必须自洽”。

Matryoshka 的想法就是：

`训练时就让多个前缀维度都参与目标。`

这样模型会学到：

- 前面维度先表达最粗、最重要的信息
- 后面维度逐步补充更细的信息

它像套娃，所以叫 Matryoshka。

### 7.2 它的工程价值为什么这么大

因为它直接解决了一个现实问题：

`不同产品、不同机器、不同索引阶段，预算不一样。`

有了 MRL 之后，你可以：

- 离线先存 1024 维
- 在线 ANN 先用 256 维做粗召回
- 再用 512 / 1024 维做精细重排

或者：

- 同一模型服务不同租户
- 高预算租户用高维
- 低预算租户用低维

这让 embedding 模型第一次具备了：

`表示预算的弹性。`

### 7.3 它和量化不是一回事

这一点必须讲清：

`MRL` 解决的是“信息如何分层排布在维度中”  
`Quantization` 解决的是“每个维度的数值如何更便宜地存储”

一个是训练表示方式，  
一个是存储 / 计算压缩方式。

两者可以结合，但绝不能混为一谈。

### 7.4 为什么 2025-2026 模型越来越强调 MRL support

因为这和实际产品需求太贴了。  
Qwen3 模型卡明确提到：

- 支持 custom dimensions
- 支持 Matryoshka Representation Learning

这意味着 MRL 已经不只是论文概念，而是：

`模型发布时的产品特性。`

---

## 8. 量化：不要只把它理解成“省一点存储”

### 8.1 为什么 embedding 特别适合量化

因为 retrieval 系统里文档向量往往数量非常大：

- 10 万
- 100 万
- 1000 万

每条向量如果是：

- 1024 维
- float32

存储和内存占用会很快上去。

所以 embedding 量化的收益往往非常直接：

- 降低索引体积
- 降低内存占用
- 有时还能提升 ANN 速度

### 8.2 常见路线：float16 / int8 / binary

可以粗略理解为：

- `float16`
  - 损失小，省一半空间

- `int8 / scalar quantization`
  - 更省，通常是比较稳的工程折中

- `binary / ubinary`
  - 极致压缩，但召回损失会更明显

Hugging Face 官方博客《Binary and Scalar Embedding Quantization for Significantly Faster & Cheaper Retrieval》把这件事讲得很明确：

- 对嵌入做 scalar / binary quantization
- 可以显著降低存储成本
- 并结合 rescore 缓解精度损失

这和前面 MRL 其实非常互补：

- MRL：先决定维度前缀如何保留信息
- quantization：再决定每维怎么更便宜地存

### 8.3 量化最常见的正确打开方式：粗召回量化 + 小候选重打分

一个很成熟的工业套路是：

1. 文档向量用 int8 / binary 存
2. 粗召回 topN
3. 再用全精度向量或 reranker 重打分

这比“全链路只用低精度向量”稳得多。

---

## 9. Multi-vector 为什么值得学，但通常不是第一步就上

这部分要讲得非常实事求是。

### 9.1 它为什么强

ColBERTv2 已经把价值说得很清楚：

- token-level late interaction
- 比 single-vector 更细粒度
- 更能保留局部匹配和复杂条件

它特别适合：

- 长文精细检索
- 高价值问答
- 需要更强 recall / precision 的专业场景

### 9.2 它为什么还没全面取代 single-vector

因为它的代价不是小补丁，而是：

- 索引对象更多
- 存储更大
- 查询更复杂
- 系统工程更难

即使 ColBERTv2 已经做了 residual compression，  
它依然不是“默认最省心”的路线。

所以成熟判断通常是：

- `single-vector` 做基础 dense retrieval
- `multi-vector` 用于高价值路径或更强第二阶段表示

---

## 10. 中文 / 多语言 embedding 选型：不要只看英文榜单

这是很多团队在国内语境里最容易掉进去的坑。

### 10.1 BGE：工程生态成熟，功能覆盖面大

`BGE-M3` 的优势非常明显：

- 100+ languages
- dense / sparse / multi-vector 三合一
- 最长输入 8192 tokens
- `FlagEmbedding` 生态完善

如果你是：

- 中英混合
- 想先落一个强而通用的检索基座
- 希望 dense / sparse / ColBERT 风格能在一个体系内衔接

那 BGE 这条线非常值得优先看。

### 10.2 GTE / mGTE：长上下文与 multilingual retrieval 很值得关注

`mGTE` 的定位更像：

- generalized
- multilingual
- long-context text representation

如果你的文档：

- 很长
- 多语言
- retrieval 和 reranking 都想在同一家族里统一

GTE 这条线很值得重点考虑。

### 10.3 Qwen3-Embedding：2025-2026 很值得关注的中文 / 多语种新一代路线

Qwen3 官方模型卡里几个点非常关键：

- 多语言、代码、文本都覆盖
- 支持自定义维度
- 支持 MRL
- 支持 binary quantization

这意味着它对工程团队非常友好，因为它把很多“上线后才发现重要”的特性前置成了模型能力。

如果你现在要在中文场景里选一个：

- 新
- 强
- 又明确考虑了尺寸弹性和量化落地

Qwen3-Embedding 是很值得重点跟踪的一条线。

### 10.4 选型不要只看榜单第一

真正该看的维度是：

- 语言覆盖
- 文档长度
- 是否需要 query instruction
- 是否支持 MRL
- 是否易于量化
- 是否有配套 reranker
- 是否已有团队生态和示例

---

## 11. MTEB 怎么看，才不至于被排行榜带偏

MTEB 的价值非常大，但它不是万能真相机。

### 11.1 它为什么重要

MTEB 官方站点把自己定义成：

- massive text embedding benchmark
- 覆盖 retrieval、clustering、pair classification、reranking、STS、summarization 等多个任务

它的重要性在于：

- 给 embedding 模型一个更统一的横向比较基准
- 不再只看单个 retrieval benchmark

### 11.2 为什么不能把它当唯一真相

因为生产环境和 benchmark 有天然差异：

- 你的 query 更短还是更口语？
- 你的语料是 PDF 残骸、wiki、代码、政策、工单，还是清洗好的 benchmark？
- 你的检索链路有 BM25、filter、rerank 吗？
- 你的文档长度和语言分布是什么？

一个在 MTEB retrieval 上领先的模型，  
不一定就是你公司知识库里最稳的选择。

### 11.3 正确用法：把 MTEB 当初筛，不当最终裁决

更成熟的流程是：

1. 用 MTEB 先缩小候选集
2. 在自己语料和 query 分布上做离线评测
3. 再看线上延迟、成本、存储、配套 reranker

这才是面向工程的选型方式。

---

## 12. Python 示例：从 baseline 到进阶

### 12.1 baseline：single-vector bi-encoder

```python
from sentence_transformers import SentenceTransformer

model = SentenceTransformer("BAAI/bge-m3")

queries = ["员工离职后多久停用门禁权限？"]
docs = [
    "离职审批完成后24小时内停用门禁权限。",
    "试用期员工报销标准见附录。",
]

q_emb = model.encode(queries, normalize_embeddings=True)
d_emb = model.encode(docs, normalize_embeddings=True)
```

这是最典型的 dense retrieval 起点。

### 12.2 量化编码

Hugging Face / Sentence Transformers 生态现在已经支持在编码阶段直接输出低精度表示：

```python
from sentence_transformers import SentenceTransformer

model = SentenceTransformer("mixedbread-ai/mxbai-embed-large-v1")

emb_int8 = model.encode(
    docs,
    precision="int8",
    normalize_embeddings=True,
)
```

适合：

- 语料量大
- 先做便宜粗召回

### 12.3 MRL / 自定义维度思路

如果模型本身支持 MRL / custom dimensions，那么可以按预算裁剪：

```python
full_emb = model.encode(docs, normalize_embeddings=True)

# 只有在模型明确支持 MRL / dimension truncation 时才建议这么做
emb_256 = full_emb[:, :256]
emb_512 = full_emb[:, :512]
```

要点不是代码，而是：

- 不是所有 embedding 都该随便截维
- 只有 MRL-aware 模型才更适合这样用

### 12.4 multi-vector / late interaction

这类一般不会像 bi-encoder 那样“几行代码搞定全链路”。  
更典型的实践是：

- 第一阶段先用 bi-encoder 召回
- 第二阶段用 ColBERT 或 reranker 重打分

这也是为什么很多系统先把 07 和 05 分开讲，但工程上它们是连起来的。

---

## 13. 怎么做领域适配：不是所有任务都该从头训练 embedding

这个问题在生产里很现实。

如果你自己的语料是：

- 很强行业术语
- 很强格式特征
- 很多内部缩写
- 查询分布和公开 benchmark 差异很大

那领域适配会很有价值。

但成熟路线通常不是直接从头训练，而是：

1. 先选一个强的基础 embedding 家族
2. 再做小规模指令适配 / 对比学习微调 / LoRA 微调
3. 保持 query / positive / hard negative 数据构造质量

这里最容易犯的错是：

- 一开始就迷信“自己训一定更好”

现实常常是：

- 数据不够好
- hard negatives 不够难
- 训练完反而过拟合某类 query

所以除非你的域差异真的很大，  
否则更建议先用：

- 强基座模型
- 好的 chunking
- hybrid retrieval
- reranker

把基础链路打稳。

---

## 14. 最容易踩的 12 个坑

### 14.1 把 cross-encoder 当成 embedding 模型

它解决的是 pairwise scoring，不是大规模 first-stage indexing。

### 14.2 只看单个 retrieval 分数，不看系统总成本

更强模型如果把存储、延迟、吞吐全打爆，也未必真更好。

### 14.3 忽略 query instruction

很多模型的线上效果，就是在这里白白损失掉的。

### 14.4 不做向量归一化，却直接比较 cosine / inner product

这样很容易让离线实验和线上 ANN 不一致。

### 14.5 看到长向量就以为一定更强

维度更高常常意味着：

- 存储更大
- ANN 更慢
- 不代表在你的任务上就稳定更好

### 14.6 把 MRL 和量化混为一谈

一个是训练表示方式，一个是数值压缩方式。

### 14.7 多向量一上来就全量替换 single-vector

这通常会让系统复杂度先爆炸。

### 14.8 只看英文 benchmark 选中文模型

这是国内团队最常见的误判之一。

### 14.9 只看 embedding 榜单，不看配套 reranker

现代检索常常是 embedding + reranker 联合作战。

### 14.10 只看 Recall，不看 retrieval 后上下文质量

召回到了，但如果候选太脏，最终 answer 也不一定好。

### 14.11 对截维模型随便裁切

不是所有向量都适合直接裁前缀。

### 14.12 在坏 chunk、坏解析上调 embedding

这会把上游问题误诊成表示问题。

---

## 15. 面试里怎么讲，才像真正理解过 embedding

如果面试官问：

`embedding 模型选型你看什么？`

你可以这样答：

> 我会先分三层看。第一层是表示路线：single-vector、multi-vector 还是 pairwise rerank；第二层是工程约束：维度、长上下文、是否支持量化和 MRL、是否有配套 reranker；第三层是域匹配：语言、文档长度、术语分布、query 风格。排行榜只能帮我缩小候选集，不能替代在线下和真实语料上的评测。

如果面试官再问：

`Matryoshka 为什么重要？`

你可以答：

> 因为它让同一个 embedding 在不同维度预算下都尽量可用，相当于把表示预算弹性训练进模型里。这样我们可以做更灵活的索引策略，比如低维粗召回、高维精排，或者同一模型适配不同成本档位。它解决的是表示分层问题，不是存储压缩问题，所以不能和量化混为一谈。

如果面试官继续追问：

`为什么 ColBERT 这种多向量方法没全面取代 bi-encoder？`

你可以答：

> 因为 single-vector 的价值不只是效果，而是索引、存储和 ANN 生态的性价比。多向量能显著提升细粒度匹配能力，但也带来更大的存储和系统复杂度。所以现实里更常见的不是完全替换，而是 single-vector 做第一阶段，大候选再交给多向量或 reranker 做第二阶段。

---

## 小结

1. embedding 的本质，是把 query 和文档压进同一个可比较表示空间，而压缩本身就是取舍。
2. single-vector bi-encoder 仍是生产默认基座；cross-encoder 负责精排；multi-vector / late interaction 负责在效果和效率之间做更强折中。
3. 2024 之后 embedding 的关键变化，是统一多功能模型、长上下文表示、MRL 弹性维度和与 reranker 成对发布。
4. Matryoshka 解决的是“表示如何分层”，量化解决的是“表示如何便宜存储”；两者可以结合，但不是一回事。
5. MTEB 很重要，但只能做候选筛选，最终选型仍要回到你的语料、query 分布、延迟预算和全链路评测。

---

## 检查站

1. 为什么说 embedding 模型选型本质上是在做“表示能力 vs 检索成本”的取舍？
2. `single-vector`、`cross-encoder`、`multi-vector` 各自在检索链路里最适合放在哪？
3. Matryoshka 为什么会让“低维粗召回 + 高维精排”这种策略变得更自然？
4. 为什么一个 MTEB 上更强的模型，不一定就是你内部知识库的最优选择？

---

## 参考与延伸阅读

- Santhanam et al., *ColBERTv2: Effective and Efficient Retrieval via Lightweight Late Interaction* (NAACL 2022)  
  https://aclanthology.org/2022.naacl-main.272/
- Kusupati et al., *Matryoshka Representation Learning* (NeurIPS 2022)  
  https://openreview.net/forum?id=9njZa1fm35
- Chen et al., *BGE M3-Embedding: Multi-Lingual, Multi-Functionality, Multi-Granularity Text Embeddings Through Self-Knowledge Distillation* (2024)  
  https://arxiv.org/abs/2402.03216
- Zhang et al., *mGTE: Generalized Long-Context Text Representation and Reranking Models for Multilingual Text Retrieval* (2024)  
  https://arxiv.org/abs/2407.19669
- Qwen Team, *Qwen3 Embedding: Advancing Text Embedding and Reranking Through Foundation Models* (2025)  
  https://arxiv.org/abs/2506.05176
- BAAI `bge-m3` Model Card  
  https://huggingface.co/BAAI/bge-m3
- `Qwen3-Embedding-4B` Model Card  
  https://huggingface.co/Qwen/Qwen3-Embedding-4B
- MTEB Official Site  
  https://mteb.dev/
- Hugging Face Blog, *Binary and Scalar Embedding Quantization for Significantly Faster & Cheaper Retrieval*  
  https://huggingface.co/blog/embedding-quantization
