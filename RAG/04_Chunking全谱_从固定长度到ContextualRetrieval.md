# RAG - 第 4 课：Chunking 全谱：从固定长度到 Contextual Retrieval

## 学习目标（本节结束后你能做到什么）

1. 你能解释为什么 chunking 不是“把文档切一下”，而是在设计`最小检索单元`与`可回答单元`的边界。
2. 你能系统讲清固定长度、递归切分、结构化切分、语义切分、Sentence Window、Parent-Child / Hierarchical、Late Chunking、Contextual Retrieval 各自在解决什么问题。
3. 你能根据文档类型、查询类型、检索策略、上下文预算，给出有依据的 chunk 方案，而不是背“500 tokens 最佳实践”。
4. 你能讲出 2024 → 2025 → 2026 的关键演化：从 naive chunking，走向`结构保真 + 上下文补偿 + 长上下文 embedding + contextualized chunks`。
5. 你能设计一套 chunking 评估方法，区分“是 chunk 坏了”，还是“其实是解析、检索、rerank 或生成坏了”。
6. 面试里如果被问“为什么检索不准”，你能把 chunk 层的问题说得比“调 chunk_size”更深入。

---

## 1. 先把问题摆正：chunking 不是文本切片，而是索引设计

很多人第一次做 RAG，会把 chunking 理解成：

1. 文档解析出来
2. 随便切成几段
3. 做 embedding
4. 检索

这是一种非常危险的简化。

因为在 RAG 系统里，chunk 不是普通字符串分段，  
它其实承担了三种角色：

1. `索引单元`
   - 向量库、BM25、稀疏索引最终检索的对象

2. `语义表示单元`
   - embedding 实际编码的是这个单元的语义平均值

3. `证据消费单元`
   - 生成模型最终看到并据以作答的上下文片段

这三个角色本来就天然冲突。

为什么？

- 对索引来说，chunk 越小越容易精确命中；
- 对 embedding 来说，chunk 太小会丢上下文，表示变脆；
- 对生成来说，chunk 太小又可能无法独立支撑回答；
- 但 chunk 太大时，多个主题被平均化，检索边界会变钝。

所以 chunking 的本质，不是“怎么切得整齐”，而是：

`如何找到一个边界，让检索足够细、表示足够稳、生成又足够有支撑。`

这就是为什么我更愿意把 chunking 称为：

`RAG 数据层里最重要的索引建模问题之一。`

---

## 2. 为什么到了 2026，chunking 仍然没有消失

很多人会问：

`模型上下文都这么大了，为什么还要切块？`

这是个好问题。

Anthropic 在 2024 年 Contextual Retrieval 官方博客里其实已经把边界说得很清楚：

- 如果知识库小于 200k tokens，很多场景可以直接全塞进 prompt
- 但当语料规模继续增长，就仍然需要 RAG

也就是说，长上下文确实改变了 chunking 的压力，但并没有消灭它。

原因有四个。

### 2.1 长上下文不是免费资源

即使能塞，也往往意味着：

- 输入成本上升
- 首字延迟变差
- query 无关上下文增多
- lost-in-the-middle 仍可能存在

### 2.2 检索仍然需要离散候选

无论你是：

- dense retrieval
- BM25
- hybrid retrieval
- rerank

都需要先定义“候选单元”是什么。  
chunk 正是这个候选单元。

### 2.3 多数业务问题不是“整本文档问答”

现实里用户问题经常只需要：

- 某条制度条款
- 某个错误码解释
- 某个 API 参数定义
- 某个财报指标及其脚注

整份文档直接送进模型，通常既贵又脏。

### 2.4 长上下文反而让 chunking 设计变得更精细

不是不切了，而是可以：

- 检索时更细
- 回答时回父块或拼更大窗口
- 在 late chunking 里先看长文再产出 chunk 表示

也就是说，长上下文带来的不是“chunking 消失”，而是：

`chunking 从粗暴切片，进化成更精细的 retrieval unit / synthesis unit 解耦。`

---

## 3. chunking 的核心悖论：检索单元和回答单元，经常不是同一个尺度

这句话非常重要，值得单独记住：

`最适合检索的单元，往往不是最适合直接回答的单元。`

举个很典型的例子：

用户问：

`员工离职后多久停用门禁权限？`

最适合检索命中的，可能是一句非常短的条款：

`离职审批完成后 24 小时内停用门禁权限。`

但最适合直接送给模型作答的，往往不止这一句，还需要：

- 这条制度属于哪份文档
- 适用对象是谁
- 有没有例外情况

也就是说：

- 检索单元希望更小、更尖锐
- 生成单元希望更完整、更自洽

这就催生出后面很多方法：

- Sentence Window
- Parent-Child
- Hierarchical
- Late Chunking
- Contextual Retrieval

它们其实都在试图解决同一个问题：

`能不能把“检索精度”和“回答完整性”同时保住。`

---

## 4. 一个更成熟的 chunking 视角：不要只问切多大，要先问切给谁用

chunk 设计至少要同时回答四个问题：

1. `给谁检索？`
   - dense、BM25、hybrid、rerank、LLM-as-judge

2. `给谁消费？`
   - 直接送生成模型，还是只作为索引锚点

3. `文档结构是什么？`
   - 论文、表格、代码、合同、知识库手册、wiki、扫描件

4. `问题类型是什么？`
   - exact lookup、解释型、比较型、多跳型、时间线型

只有把这四件事说清楚，chunking 才不是玄学。

否则你就会一直停留在：

- chunk_size=256 还是 512
- overlap=20 还是 50

这种局部调参上。

---

## 5. 先讲最原始的两类：固定长度与递归切分

### 5.1 固定长度切分：最容易上手，也最容易制造“语义断裂”

最常见的 naive 方案是：

```python
def chunk_text(text, size=500, overlap=50):
    chunks = []
    start = 0
    while start < len(text):
        end = min(start + size, len(text))
        chunks.append(text[start:end])
        start += size - overlap
    return chunks
```

它的好处很简单：

- 稳定
- 快
- 易于控制 token 预算
- 不依赖复杂解析

但它的问题同样直白：

- 不理解段落边界
- 不理解标题层级
- 不理解表格 / 列表 / 代码块
- 容易把一个语义单元切断

所以固定长度切分更像：

`一个很好的 baseline，不是一个长期最佳方案。`

### 5.2 递归切分：尽量尊重自然边界，但仍然是启发式

LangChain / LlamaIndex 一类工具里的 recursive splitter，常见逻辑是：

- 优先按标题 / 段落 / 换行切
- 不行再按句子切
- 再不行按 token / 字符切

它比固定长度成熟很多，因为至少承认：

`文档边界本身是有层级的。`

但它仍然有几个局限：

- 规则边界不一定等于语义边界
- 对坏格式文档无能为力
- 对表格、代码、公式仍经常不够强

所以递归切分是：

- 比 fixed chunking 更成熟的默认值
- 但还不是完整答案

---

## 6. 结构化切分：顺着文档本身的结构来切，而不是顺着 token 数来切

这是第 03 节文档解析和第 04 节 chunking 的自然衔接。

如果你前面已经有了：

- 标题
- 段落
- 表格
- 列表
- 代码块
- 图注

那么最自然的思路就是：

`先按文档结构单元切，再决定这些单元是否进一步拼合。`

### 6.1 为什么它通常比固定长度更合理

因为结构单元往往更接近人类写作时的语义单元。

例如：

- 一个二级标题下的 2 段正文
- 一个完整表格
- 一个“配置项 + 示例 + 注意事项”块

这些东西对检索和回答都更自然。

### 6.2 它的真正前提是什么

前提不是 chunking 算法本身，而是：

`你的文档解析层足够好。`

如果上游 PDF 解析已经把：

- 表格打平
- 阅读顺序打乱
- 标题树丢掉

那结构化切分根本无从谈起。

所以这也是为什么 03 节和 04 节本来就应该连着看。

### 6.3 结构化切分最容易踩的坑

- 结构单元太大，直接拿去 embedding 会平均化
- 结构单元太细，比如每个列表项都分开，又可能丢上下文
- 某些文档结构本身很差，不能盲信 heading hierarchy

所以更成熟的做法常常是：

- 先用结构切
- 再在结构内部按 token 或语义做二次分层

---

## 7. 语义切分：不要按格式切，而是按语义跳变切

这是 chunking 里很容易让人误解的一类方法。

很多人第一次听到 semantic chunking，会以为它是在说：

- “让 LLM 判断哪里该切”

其实更常见也更实用的做法是：

- 先按句子分
- 对相邻句子或小窗口计算 embedding similarity
- 在语义变化明显的位置切开

LlamaIndex 官方的 `SemanticSplitterNodeParser` 就是这一路线：

- 把文档切成由语义相关句子组成的节点

它想解决的问题非常明确：

`自然段边界并不总等于语义边界。`

例如一个段落里可能前半段在讲定义，后半段已经开始讲限制条件；  
或者一个长段落其实糅合了两个主题。

### 7.1 语义切分的优点

- 对长段、杂糅段落更敏感
- 更有机会找到真正的 topic shift
- 在 wiki / 说明文 / 知识库文本中常常比固定段落更合理

### 7.2 它的局限

- 需要额外 embedding 成本
- 对噪声文本、OCR 错误、代码、表格不稳定
- 相似度阈值很难一劳永逸

换句话说，语义切分更像：

`在“格式边界”不太可靠时，用语义边界补救。`

它不是所有文档都必须开启的通用神技。

---

## 8. Sentence Window / Small-to-Big：检索更小，但回答时回看周边

这类方法的核心思想特别值得记住：

`把检索单元做小，把消费单元做大。`

LlamaIndex 官方的 `SentenceWindowNodeParser` 就是一个很典型的实现：

- 每个 node 是一句话
- 但 node metadata 里同时保留周围句子的窗口
- 检索时用精细单句
- 生成前再替换回 surrounding window

LlamaIndex 示例里甚至明确说：

- 这对 large documents / indexes 很有用
- 有助于检索更细粒度细节

### 8.1 为什么它有效

因为它正中前面那个核心悖论：

- 单句适合命中细节
- 单句不适合独立回答

于是：

- retrieval precision 上升
- 生成时又不至于只看到一行碎片

### 8.2 它的局限

- 需要额外元数据管理
- retrieval ranking 和最终消费内容不再一一对应
- 如果窗口过大，仍会把噪声带回来

但对很多知识库文档来说，它是非常实用的折中。

---

## 9. Parent-Child / Hierarchical Chunking：把“检索粒度”和“返回粒度”正式解耦

这是生产系统里非常重要的一条路线。

它的核心直觉和 Sentence Window 类似，但更系统：

- 用较小 child chunks 做检索
- 命中后回到较大的 parent chunk 或多层节点

LlamaIndex 的 `HierarchicalNodeParser` 官方文档就写得很清楚：

- 可以递归生成层级节点
- 例如 2048 / 512 / 128 三层
- 会保留 parent-child 关系

这类方法非常适合：

- 长文档
- 长手册
- 结构复杂文档
- 一边希望 recall 准，一边又希望 answer 有完整局部上下文

### 9.1 它解决的本质问题

`一个 chunk 不应该同时扮演所有尺度上的角色。`

这句话其实是现代 chunking 思想的核心。

### 9.2 它的真实代价

- 索引对象变多
- 去重更难
- parent merge 逻辑要小心
- rerank 需要想清是对 child 排还是对 parent 排

但这类复杂度通常是值得的，因为它比“一个固定 chunk_size 试图兼顾一切”成熟得多。

---

## 10. Late Chunking：不是先切再 embed，而是先看长文、后产出 chunk 表示

这一条是 2024 之后最重要的 chunking 进展之一。

### 10.1 它在解决什么问题

Jina / arXiv 2024 的 `Late Chunking` 论文指出：

- 传统做法是先切 chunk，再分别做 embedding
- 但这样得到的 chunk embeddings 会丢掉周边上下文

arXiv 摘要写得很清楚：

- naive chunking 产生的 chunk embeddings 会丢失 surrounding chunks 的上下文
- late chunking 则先对整段长文本做 token-level encoding
- 再在 transformer 之后、mean pooling 之前切 chunk

Jina 官方博客把这个差别概括得特别好：

- naive chunk embeddings 更像 i.i.d.
- late chunking 产出的 chunk embeddings 是 contextualized / conditional 的

### 10.2 它的核心原理

传统 chunking：

```text
切块 -> 每块分别过 embedding model -> 得到 chunk vectors
```

Late chunking：

```text
整段长文本先过 embedding transformer -> 得到 token representations ->
按 chunk 边界对 token reps 分段池化 -> 得到 chunk vectors
```

Jina 官方博客第一个很重要的例子是 Berlin：

- 原文里后文有 “the city”、“its”
- 如果先切块，这些 chunk 内没有 Berlin，就容易变成弱表示
- 如果先让整段文本进 transformer，再对 chunk 池化，这些代词所在 chunk 也能带上前文 Berlin 的上下文

### 10.3 为什么它重要

因为它第一次很系统地提出：

`chunk 边界可以用于 pooling，不一定非要用于 transformer 编码的输入边界。`

这等于把“切块”和“编码”这两件事解耦了。

### 10.4 它的局限

- 需要 long-context embedding model
- 对极长文档仍要分段处理
- 实现复杂度高于普通 chunking
- 通常不太适合 BM25 那条 lexical 路线

所以它不是所有系统的默认方案，  
但在长文 dense retrieval 里非常值得关注。

### 10.5 2026 的延伸：late chunking 正在向视觉文档检索扩展

2026 年的 `Visual Late Chunking`（arXiv:2604.10167）很能说明趋势：

- late chunking 的思想已经从文本检索扩展到 visual document retrieval
- 通过 multimodal late chunking 构造 contextualized multi-vectors
- 在 24 个视觉文档检索数据集上，同时降低存储并提升 nDCG@5

这件事的信号很明确：

`late chunking 不再只是文本 embedding 的小技巧，而是在演化成一种更通用的“先建全局上下文，再产出局部表示”的方法论。`

---

## 11. Contextual Retrieval：不是重新切块，而是给 chunk “补背景说明”

Anthropic 2024 年 9 月的官方博客，是这一年 chunking 思想里最值得记住的一次转向。

### 11.1 它在解决什么问题

Anthropic 直接指出：

- 传统 RAG 会 destroy context
- 很多 chunk 单独拿出来时，缺少足够背景

他们给的例子很典型：

原 chunk：

`The company's revenue grew by 3% over the previous quarter.`

问题在于，这句单独看时不知道：

- 哪家公司
- 哪个季度
- 前一个季度是多少

于是 Anthropic 的做法不是改边界，而是：

`给每个 chunk 生成 50-100 token 的简短上下文说明，再 prepend 到 chunk 前。`

官方博客里的做法是：

- 生成 chunk-specific explanatory context
- 既用于 embedding，也用于 BM25 index

### 11.2 这和普通 summary 有什么区别

这不是：

- 给整篇文档加个摘要

而是：

- 给`每一个 chunk`加一个只属于它自己的定位说明

也就是说，它强调的不是全局摘要，而是：

`chunk-level situating context`

### 11.3 Anthropic 公布的数据为什么重要

Anthropic 官方博客给出了非常明确的数字：

- 仅用 contextual embeddings，top-20 retrieval failure rate 从 5.7% 降到 3.7%，下降 35%
- 加上 contextual BM25，降到 2.9%，下降 49%
- 再加 reranking，降到 1.9%，下降 67%

这几个数字很重要，因为它们说明：

`chunking 的问题不只是边界问题，还有“chunk 单独表达时信息不足”的问题。`

### 11.4 它和 late chunking 的区别

这是很容易混淆的点。

`Late chunking`：

- 通过编码阶段保留上下文
- 让 chunk embedding 自带长上下文语义

`Contextual Retrieval`：

- 通过生成显式 contextual text
- 让 chunk 本体在 embedding 和 BM25 上都更可检索

可以简单记：

- late chunking 是`representation-side contextualization`
- contextual retrieval 是`text-side contextualization`

两者不是互斥关系，甚至可以结合。

---

## 12. LLM-based / Proposition-level Chunking：2025-2026 的方向，但还不是统一标准

这一类方法现在很热，但必须讲得克制一点。

它们的共同直觉是：

- 与其按 token / 段落切
- 不如让模型直接产出更“原子”的知识单元

常见做法包括：

- 提取命题级 facts
- 把一段文字拆成若干 proposition / claim / QA pair
- 再按 proposition 建索引或作为更细粒度 retrieval unit

### 12.1 为什么它诱人

因为它试图直接对齐：

- “用户问一个事实”
- “索引里就有一个事实单元”

理论上这会让：

- recall 更高
- 证据更尖锐
- citation 更直接

### 12.2 为什么它还没有成为普适默认值

因为代价非常真实：

- 预处理成本高
- 容易引入抽取幻觉
- 元数据、父子关系、可追溯性更复杂
- 很难对所有文档类型都稳定

所以到 2026 年，更成熟的判断是：

`这是一条很有潜力的工程方向，但还不是所有团队该默认使用的通用 chunking 基座。`

把它当成：

- 针对高价值知识库
- 或高精度 FAQ / fact lookup

的增强路线，会更稳。

---

## 13. 2024 → 2026 的主线：chunking 的重心到底在怎么迁移

如果把过去两三年的演化压成一条主线，我会这么总结：

### 13.1 2024 之前：主要问题是“边界怎么切”

大家讨论最多的是：

- 256 还是 512
- overlap 多少
- 按段落还是按句子

这是 naive chunking 时代。

### 13.2 2024：开始意识到“边界之外，还有上下文丢失问题”

最重要的两个信号：

- `Late Chunking`：不是所有上下文都该在切块前丢掉
- `Contextual Retrieval`：chunk 单独表达时上下文不足，可以显式补背景

这说明行业已经从：

- “怎么切”

转向：

- “切完之后，chunk 还剩多少可检索信息”

### 13.3 2025：层级化和解耦越来越被接受

比如：

- sentence retrieval + window replacement
- parent-child retrieval
- hierarchical nodes

这些方法的共同特征是：

`接受 retrieval unit 和 synthesis unit 可以不是同一个对象。`

### 13.4 2026：chunking 正从“预处理参数”变成“表示学习与检索策略的一部分”

最新趋势包括：

- late chunking 向多模态扩展
- contextual chunking 与 hybrid retrieval、rerank 联合优化
- 更细粒度的 evidence unit 与更大粒度的 answer unit 解耦

到这一步，chunking 就已经不再只是：

- splitter 配什么参数

而变成：

`检索系统里一个跨解析、表示、索引、重排、上下文组装的系统设计问题。`

---

## 14. 一个实用的选型框架：不同文档、不同 query，该怎么选 chunk 策略

### 14.1 如果你是普通企业知识库 / wiki / 手册

默认推荐：

- 文档解析保结构
- 递归 / 结构化切分
- 适度 overlap
- hybrid retrieval + rerank

如果问题多是：

- exact lookup
- 制度问答
- API 文档问答

这通常已经足够好。

### 14.2 如果你是长文档、长报告、财报、法律文本

更推荐：

- 结构化切分
- Parent-Child / Hierarchical
- 有条件时叠加 contextual retrieval

因为这类文档的核心问题常常是：

- 单个局部条款信息不足
- 但直接用大块检索又太钝

### 14.3 如果你是论文、长技术文档、需要跨段指代

更值得考虑：

- sentence / small chunks 做 retrieval
- sentence-window / parent-child 做 synthesis
- 或 late chunking 做 dense retrieval

因为这类语料经常有：

- 代词指代
- 前文定义、后文引用
- 长距离依赖

### 14.4 如果你是高价值、追求极致精度的知识库

可以逐步尝试：

- contextual retrieval
- proposition-level extraction
- LLM-based chunk enrichment

但不建议跳过基础设施，直接从这里起步。

---

## 15. Python 示例：4 种最常见路线怎么落地

### 15.1 递归 / 结构化优先的基础切分

```python
from langchain_text_splitters import RecursiveCharacterTextSplitter

splitter = RecursiveCharacterTextSplitter(
    chunk_size=512,
    chunk_overlap=64,
    separators=["\n\n", "\n", "。", ".", " ", ""],
)

chunks = splitter.split_text(text)
```

适合：

- 默认 baseline
- 结构大致清晰的文档

### 15.2 语义切分

```python
from llama_index.core.node_parser import SemanticSplitterNodeParser

splitter = SemanticSplitterNodeParser(
    embed_model=embed_model,
    buffer_size=1,
)
nodes = splitter.get_nodes_from_documents(documents)
```

适合：

- 长段说明文
- 主题转折比较多

### 15.3 Sentence Window

```python
from llama_index.core.node_parser import SentenceWindowNodeParser

parser = SentenceWindowNodeParser.from_defaults(
    window_size=3,
)
nodes = parser.get_nodes_from_documents(documents)
```

适合：

- 需要高精度细粒度命中
- 但最终回答又需要邻近上下文

### 15.4 Hierarchical / Parent-Child

```python
from llama_index.core.node_parser import HierarchicalNodeParser

parser = HierarchicalNodeParser.from_defaults(
    chunk_sizes=[2048, 512, 128],
)
nodes = parser.get_nodes_from_documents(documents)
```

适合：

- 长文档
- 想把 retrieval unit 和 answer unit 解耦

### 15.5 Contextual Retrieval 的最小预处理骨架

```python
def contextualize_chunk(full_doc: str, chunk: str, llm) -> str:
    prompt = f"""
<document>
{full_doc}
</document>
<chunk>
{chunk}
</chunk>
请给一段简短上下文说明，用来帮助检索时理解这个 chunk 属于什么文档、
在讲什么主题、和前后文是什么关系。只输出说明文本。
"""
    return llm.complete(prompt).text.strip()


contextualized_chunks = []
for chunk in chunks:
    ctx = contextualize_chunk(full_doc, chunk, llm)
    contextualized_chunks.append(f"{ctx}\n{chunk}")
```

适合：

- 长文档
- chunk 单独拿出来信息不充分

---

## 16. 如何评估 chunking，而不是靠感觉

很多团队评估 chunking 的方法太随意了：

- 抽几段看看顺不顺
- 问几个问题感觉还行

这远远不够。

更靠谱的评估至少要分三层。

### 16.1 检索层

看：

- Recall@K
- MRR
- nDCG
- top-K 里是否出现正确父文档
- top-K 里是否出现正确细粒度证据

### 16.2 证据层

看：

- 返回 chunk 是否自洽
- 是否需要额外邻近上下文才能理解
- 是否存在大量重复 sibling chunks
- 表格 / 列表 / 代码是否被切坏

### 16.3 生成层

看：

- Answer faithfulness
- citation 是否指向真正支撑答案的 chunk
- 是否因为上下文碎片化导致答非所问

最重要的是要做对照实验：

- same parser
- same embedding
- same retriever
- same reranker
- only change chunking

否则你永远分不清效果变化来自哪一层。

---

## 17. 最容易踩的 12 个坑

### 17.1 把 chunk_size 当唯一超参

真正决定效果的往往是：

- 边界类型
- 父子关系
- 上下文补偿
- retrieval unit / synthesis unit 是否解耦

### 17.2 只按字符数切，不按 tokenizer 预算切

中文、代码、表格里尤其容易翻车。

### 17.3 overlap 设很大，当成万能补丁

这会带来：

- 重复索引
- rerank 冗余
- 上下文污染

但不一定真正解决结构断裂。

### 17.4 不区分 dense 和 BM25 对 chunk 的偏好

BM25 有时能接受稍大块；  
dense 对主题平均化更敏感。

### 17.5 把解析坏掉的文本拿来调 chunking

这会把上游问题误诊成 chunking 问题。

### 17.6 只看 answer，不看检索中间层

你会不知道是：

- chunk 没召回
- 还是召回了但没被用上

### 17.7 Parent-Child 做了，但 parent 返回过大

最后 prompt 还是塞回一大坨噪声。

### 17.8 Sentence Window 做了，但窗口过大

检索精度赚来的收益，又被窗口噪声吃掉。

### 17.9 Semantic Splitter 当成默认万能方案

对代码、OCR 噪声、表格、结构差文本未必适合。

### 17.10 对每个域用同一套 chunk 策略

制度、论文、日志、代码、财报根本不是同一种文档。

### 17.11 只做 chunking，不做 rerank / filtering / source control

chunking 再好，也不能替代后面几层。

### 17.12 看到长上下文就放弃 chunking 设计

2026 反而更该做的是更细粒度的解耦。

---

## 18. 面试里怎么讲，才像真正理解过 chunking

如果面试官问：

`chunking 为什么这么重要？`

你可以这样答：

> 因为 chunk 是 RAG 里的最小检索单元，也是 embedding 的最小语义表示单元，还经常是生成模型消费的证据单元。它切得不好，后面的 dense retrieval、BM25、rerank 和 generation 都会在错误边界上工作。所以 chunking 不是简单的预处理，而是索引建模问题。

如果面试官再问：

`Parent-Child 和 Late Chunking 的区别是什么？`

你可以答：

> Parent-Child 是在索引和返回层面解耦 retrieval unit 与 answer unit，小块检索、大块消费；Late Chunking 是在表示学习层面解耦 chunk boundary 与 encoding boundary，先让长文本进入 embedding transformer，再对 token representations 做分块池化。前者主要改 retrieval / serving 结构，后者主要改 chunk embedding 的构造方式。

如果面试官继续追问：

`2024 到 2026 这一层最大的变化是什么？`

你可以答：

> 最大变化是行业开始接受“切块问题不只是边界问题”。2024 的 Late Chunking 和 Anthropic 的 Contextual Retrieval 都在说明：即使边界没问题，chunk 单独表示时仍会丢失跨段上下文。所以 chunking 的重心已经从“切多大”转向“如何保留和补偿上下文”，再到如何把 retrieval unit 和 synthesis unit 正式解耦。

---

## 小结

1. chunking 不是文本切片，而是在设计检索单元、表示单元和回答单元之间的关系。
2. 固定长度和递归切分是 baseline；结构化切分和语义切分是在提升边界质量。
3. Sentence Window、Parent-Child、Hierarchical 的共同思想，是把检索粒度和回答粒度解耦。
4. Late Chunking 和 Contextual Retrieval 标志着 2024 之后 chunking 进入“上下文补偿 / 表示解耦”阶段。
5. 到 2026 年，chunking 已经不再只是 splitter 配置，而是跨解析、表示、检索、重排和上下文工程的系统设计问题。

---

## 检查站

1. 为什么说“最适合检索的单元”和“最适合回答的单元”经常不是同一个尺度？
2. `Late Chunking` 和 `Contextual Retrieval` 分别是在表示层和文本层解决什么问题？
3. 如果你的文档主要是长手册和制度条款，为什么 Parent-Child 往往比单一固定 chunk_size 更合理？
4. 当检索不准时，你如何判断问题在 chunking，而不是在解析、embedding 或 rerank？

---

## 参考与延伸阅读

- Anthropic, *Introducing Contextual Retrieval* (2024-09-19)  
  https://www.anthropic.com/engineering/contextual-retrieval
- Günther et al., *Late Chunking: Contextual Chunk Embeddings Using Long-Context Embedding Models* (2024)  
  https://arxiv.org/abs/2409.04701
- Yan et al., *Visual Late Chunking: An Empirical Study of Contextual Chunking for Efficient Visual Document Retrieval* (2026)  
  https://arxiv.org/abs/2604.10167
- LlamaIndex Docs, *SemanticSplitterNodeParser*  
  https://docs.llamaindex.ai/en/stable/api_reference/node_parsers/semantic_splitter/
- LlamaIndex Docs, *SentenceWindowNodeParser*  
  https://docs.llamaindex.ai/en/stable/api_reference/node_parsers/sentence_window/
- LlamaIndex Docs, *HierarchicalNodeParser*  
  https://docs.llamaindex.ai/en/stable/api_reference/node_parsers/hierarchical/
