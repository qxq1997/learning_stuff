# RAG 选型全景对比与选型理由

## 目标

这篇文档不是再讲一遍“TalentHub 选了什么”，而是把 RAG 链路上四个关键环节的**市面主流方案铺开**，逐一对比优缺点，最后给出 TalentHub 当前选什么、为什么选这个。

覆盖四块：

- Embedding
- Chunking
- LLM API
- BM25 / Sparse Retrieval

对每一块都遵循同一个结构：

- 市面主流方案有哪些
- 它们各自的优缺点
- TalentHub 当前选什么、为什么

同时配合 `docs/73-技术选型权衡与替代方案深度设计.md` 阅读，那篇是整体架构层面的 trade-off，这篇是 RAG 子系统层面的横向对比。

---

## 一、Embedding

### 1.1 市面主流方案

| 方案 | 形态 | 维度 | 中文 | 英文 | 多语言 | 特殊能力 | 主要风险 |
|---|---|---|---|---|---|---|---|
| OpenAI `text-embedding-3-large` | 云 API | 3072（可裁剪） | 强 | 强 | 强 | 通用主力，长上下文 8k token | 依赖外部服务、数据出境、按 token 计费 |
| OpenAI `text-embedding-3-small` | 云 API | 1536 | 较强 | 强 | 中 | 便宜（large 的 ~1/6） | 检索质量弱于 large |
| Voyage `voyage-3` / `voyage-3-large` | 云 API | 1024 / 2048 | 中 | 强 | 中 | 偏 RAG 场景调优 | 国内访问偶发限流 |
| Cohere `embed-v3` | 云 API | 1024 | 中 | 强 | 强 | 支持检索语义指令 | 在国内生态相对边缘 |
| Google `gemini-embedding-001` | 云 API | 3072 | 中 | 强 | 强 | 与 Gemini 模型生态打通 | API 区域限制、配额波动 |
| BGE-M3（BAAI） | 本地模型 | 1024 | 强（专门优化） | 强 | 强 | **同时输出 dense + sparse + multi-vector**，hybrid 一站式 | 模型 ~2GB，冷启动慢，依赖 torch/transformers |
| `bge-large-zh-v1.5` | 本地模型 | 1024 | 极强 | 弱 | 弱 | 中文专精 | 中英混合场景不行 |
| `multilingual-e5-large` | 本地模型 | 1024 | 强 | 强 | 强 | 通用多语言 baseline | 中文上略逊 BGE-M3 |
| Jina `jina-embeddings-v3` | 云 API + 本地 | 1024 | 中 | 强 | 强 | Late chunking 支持 | 国内可用性一般 |
| 本地 hash / TF-IDF | 纯代码 | 任意 | 极弱 | 极弱 | 弱 | 零依赖，毫秒级 | 只能做 demo，无语义能力 |

### 1.2 关键对比维度

- **质量**：当前公开 benchmark（MTEB、C-MTEB）里第一梯队是 OpenAI 3-large、BGE-M3、Voyage-3、Gemini embedding。差距已经不大，业务场景下取舍更多看“契合度”而非“天花板”。
- **部署形态**：云 API 启动快、零运维；本地模型隐私好、可控、长期免费，但要承担镜像体积、冷启动、GPU 选型的成本。
- **中英混合表现**：企业知识库经常是中英夹杂（API 文档英文 + 中文注释 + 中文制度），BGE-M3 和 OpenAI 3-large 在这类场景上表现最稳。
- **特殊能力**：BGE-M3 的“一次推理出三种向量”和 Jina 的 late chunking 是结构性差异，会直接影响 hybrid 路线怎么搭。

### 1.3 TalentHub 当前选择与理由

**默认**：`OpenAI text-embedding-3-large`
**备选**：`BGE-M3`（可通过 `EMBEDDING_PROVIDER=bge_m3` 切换）

理由：

- TalentHub 是培训与考试系统，**检索是辅助、不是主业**，链路必须轻量稳定。云 API 的零冷启动 + 零运维直接命中诉求。
- 3-large 的 3072 维在中英混合场景下的效果，足够覆盖当前知识库的多领域需求（详见 `docs/75-当前检索benchmark测试报告.md`，MRR@5/Recall@5 已达 1.0）。
- BGE-M3 不是不好，而是**作为"将来要认真做 hybrid 的能力储备"**更合适。它的 sparse + dense + multi-vector 一站式输出，是后续走 hybrid 路线的关键能力，因此通过 provider 抽象保留可切换。
- 没选 Voyage embedding 当默认：当前已经用 Voyage 做 reranker，embedding 再压一个 provider 会增加单点风险。
- 没选 Gemini embedding：国内可用性和配额稳定性当前不如 OpenAI。

详细决策见 `docs/58-OpenAI-Embedding默认化与可切换Provider设计.md`。

---

## 二、Chunking

### 2.1 市面主流方案

| 方案 | 代表实现 | 切分依据 | 优点 | 缺点 |
|---|---|---|---|---|
| Fixed-size character | 自己几行代码 | 固定字符数 | 极简 | 切碎语义，常切断句子 |
| Recursive character splitter | LangChain `RecursiveCharacterTextSplitter` | 按分隔符优先级递归切 | 流行、零配置 | 默认分隔符偏英文，中英混合要自配 |
| Sentence-aware | NLTK / spaCy | 句子边界 | 语义最干净 | 依赖 NLP 库，中文分句要额外模型 |
| Token-aware | tiktoken + 自切 | 按模型 token 数切 | 直接对齐 embedding 上限 | 跨模型 tokenizer 不一致 |
| Structural（Markdown/HTML） | LangChain `MarkdownHeaderTextSplitter` | 标题、列表、代码块 | 保留文档结构 | 只适合 Markdown/HTML，纯文本无效 |
| Semantic chunking | LlamaIndex `SemanticSplitter` | 相邻句子 embedding 相似度断点 | 语义连贯 | 切分时已经要跑 embedding，慢且贵 |
| Parent-Child / Hierarchical | LangChain `ParentDocumentRetriever`、LlamaIndex `AutoMergingRetriever` | 切两层：小块做检索、大块做上下文 | 检索精+召回上下文足 | 实现复杂，要管两层关系 |
| Late chunking | Jina | 先 embed 整篇，再在向量层切 | 跨 chunk 语义连贯 | 依赖支持 late chunking 的模型 |
| Contextual chunking | Anthropic Contextual Retrieval | 每个 chunk 前拼一段 LLM 生成的上下文摘要 | 检索质量显著提升 | 索引阶段要调一次 LLM，慢且贵 |

### 2.2 关键对比维度

- **召回 vs 精度**：chunk 越小检索越精，但上下文越少；越大上下文越足，但容易被无关内容稀释。父子 chunk 是这个权衡的经典解法。
- **依赖体积**：Fixed/Recursive 几乎零依赖；Sentence-aware 要 NLTK/spaCy；Semantic/Contextual 要 embedding 或 LLM 在索引时就介入。
- **中英混合的适配成本**：LangChain 默认 splitter 在 `\n\n / \n / . / space` 这套英文断点上跑，中文文档要手动加 `。！？；`。

### 2.3 TalentHub 当前选择与理由

**当前**：完全自研，无第三方 chunking 库依赖。
- `ParentChildKnowledgeDocumentIndexer`：父 chunk `2400`、子 chunk `800`，overlap 分别 `240` / `120`
- `_split_content_into_chunks`：在 `[60%, 100%] chunk_size` 窗口内回找最靠后的中英文断点（`\n\n / \n / 。！？； / ;.!?`），找不到才硬切
- `build_document_embedding_text`：embedding 前拼 `"{文档标题}\n[{parent|child}]\n{文本}"`，给向量空间烙上文档归属语义

理由：

- **没用 LangChain 的 splitter**：默认分隔符偏英文，中英混合要手配；父子 chunk 要拼 `ParentDocumentRetriever` 等多个组件，比自己写一个文件 40 行更重。
- **没用 LlamaIndex 的 AutoMergingRetriever**：同样过重，引入整个生态只为换一个父子逻辑不划算。
- **没用 Semantic / Contextual chunking**：索引阶段调 embedding/LLM 会让"上传一篇文档"的体验从秒级降到分钟级，对培训系统不可接受。这两条路保留为后续可选优化。
- **父子结构本身**的取舍详见 `docs/73-技术选型权衡与替代方案深度设计.md` 第九节。

一句话：**控制权大于便利性**——RAG 不是项目主业，chunking 链路要绝对可控，自己写 40 行远比引入一个会随版本变动的生态更稳定。

---

## 三、LLM API

### 3.1 市面主流方案

| 方案 | 代表模型 | 中文能力 | 推理能力 | 单价（粗略） | 形态 | 风险点 |
|---|---|---|---|---|---|---|
| OpenAI | GPT-5 / GPT-5-mini / 4o / o1 / o3 | 强 | 极强（o 系列） | 中—高 | 云 API | 数据出境、限流、价格波动 |
| Anthropic Claude | Claude 4.5 Sonnet / Opus / Haiku | 强 | 强（长上下文、工具调用） | 中—高 | 云 API | 国内直连受限 |
| Google Gemini | Gemini 2.0 Flash / 1.5 Pro | 中—强 | 强 | 低—中 | 云 API | 区域限制、配额波动 |
| DeepSeek | V3 / R1 | 强 | 极强（R1） | 极低 | 云 API + 可本地 | 限流偶发，闭源细节有限 |
| 国产生态 | 通义、文心、Kimi、豆包、智谱 | 极强 | 中—强 | 低 | 云 API | 各家 SDK 风格不一，迁移成本高 |
| 本地推理 | Llama 3.x / Qwen 2.5 / GLM-4 via Ollama / vLLM | 看模型 | 看模型 | 自付硬件 | 本地 | GPU 成本、维护成本、能力天花板 |

### 3.2 关键对比维度

- **稳定性**：云 API 中 OpenAI 仍然是工程最稳的——SDK 成熟、错误码清晰、限流可预测。
- **中文能力**：国产模型在地道中文表达上有先天优势，但 SDK/工具生态差异大，多 provider 抽象成本高。
- **推理任务**：判主观题、出题这类需要推理，o 系列、Claude、DeepSeek R1 是第一梯队。
- **成本**：DeepSeek 价格在大厂里是数量级地便宜，但稳定性还在追赶。
- **本地推理**：能解决数据合规，但对一个个人/小团队项目，"为了一个 LLM 调 Ollama" 的运维成本远大于收益。

### 3.3 TalentHub 当前选择与理由

**当前默认**：`OpenAI gpt-5-mini`（`LLM_PROVIDER=openai`）
**可切换**：`LLM_PROVIDER=disabled`（关掉 AI，仅跑检索/题库基础流程）

实现位置：`backend/app/shared/ai/openai_question_generation.py`、`openai_attempt_grading.py`、`factories.py`。

理由：

- **gpt-5-mini 是当前性价比甜点**：能力够用（出题、判卷质量稳定），价格远低于旗舰，延迟可接受。
- **统一一家 provider**：项目当前没有"必须 A/B 多家模型"的诉求，单 provider 让 prompt 调优、token 计费、错误处理都简单。
- **保留 `disabled` 开关**：让没有 API key 的开发者也能跑通题库/考试基础流程。
- **没接 Claude / Gemini / 国产**：不是它们不行，而是 **provider 抽象层当前还没完整化**——按 doc 73 第三节的 trade-off 原则，多 provider 抽象要等到真有"切换需求"才补，不预先泛化。
- **没默认本地推理**：本地推理对培训系统的"出题秒级返回"诉求是个倒退。

未来升级方向：把 `LLMProvider` 抽象化（参考已有的 `EmbeddingProvider` / `Reranker` 模式），让 Claude / DeepSeek 可作为可切换选项。

---

## 四、BM25 / Sparse Retrieval

### 4.1 市面主流方案

| 方案 | 形态 | 特点 | 优点 | 缺点 |
|---|---|---|---|---|
| Elasticsearch / OpenSearch BM25 | 独立服务 | 工业级 BM25 + 倒排索引 | 成熟稳定、富查询语法 | 重资产，要单独运维 ES 集群 |
| Postgres full-text search | PG 内置 | `tsvector + GIN`，BM25 类似的 ranking | 不引入新组件 | 中文要装分词器（`pg_jieba` 等），ranking 算法弱于 BM25 |
| Tantivy / pyserini | Python lib | Lucene 系，Rust 实现 | 性能强 | 索引文件格式专有，要自管 |
| `rank_bm25` | 纯 Python lib | 内存中跑 BM25 | 零运维、零外部依赖 | 数据量上来后内存爆，无法持久化 |
| SPLADE | 学习型 sparse | 用 transformer 模型出 sparse 向量 | 比传统 BM25 检索质量更好 | 索引时要跑模型，慢且依赖 GPU |
| BGE-M3 sparse 输出 | 学习型 sparse | M3 一次推理同时出 dense + sparse | **dense/sparse 一个模型搞定**，统一管 | 仍然是模型推理路径，要承担 BGE 依赖 |
| Qdrant 原生 sparse vector | Qdrant 内 | 接受外部送进来的 sparse 向量 | 与 dense 在同一引擎，hybrid 融合天然 | 需要先有 sparse 来源（BM25 或 BGE-M3 sparse） |

### 4.2 关键对比维度

- **传统 BM25 vs 学习型 sparse**：传统 BM25 基于词频，对术语精确匹配强；学习型 sparse（SPLADE / BGE-M3 sparse）会做语义扩展，对同义词更鲁棒。两者其实可以叠加。
- **是否引入新组件**：BM25 路线选 ES 等于新增一整套基础设施；选 PG 全文搜索成本最低；选 BGE-M3 sparse + Qdrant sparse vector 等于"只在已有组件上加能力"。
- **中文分词**：传统 BM25 在中文场景必须配分词器（jieba、ik 等），是一个长期维护成本。BGE-M3 sparse 直接基于 subword，规避了这个问题。

### 4.3 TalentHub 当前选择与理由

**当前实际状态（必须诚实交代）**：
- **默认链路未启用 sparse / BM25**，纯 dense 检索（OpenAI embedding + Qdrant dense）
- **代码已就位但默认关闭**：`vector_store.py` 中已经实现 `enable_sparse_vectors`，`bge.py` 中 BGE-M3 已经能输出 sparse embedding，但 `EMBEDDING_PROVIDER=openai` 默认路径不会产出 sparse 向量

**未来的 hybrid 路线**：`BGE-M3 sparse + Qdrant sparse vector`，详见 `docs/60-BGE-Sparse-Multi-Vector-Hybrid接入设计.md`。

理由：

- **没引入 Elasticsearch**：为了一个 BM25 通道部署整套 ES，对 TalentHub 这种规模过重，运维成本远大于收益。
- **没用 PG 全文搜索**：要装中文分词扩展（`pg_jieba` 等），引入 PG 端的运维负担；ranking 质量也弱于 BM25。
- **没用 `rank_bm25`**：内存方案，数据量稍大就爆。只适合 demo。
- **走 BGE-M3 sparse 的原因**：dense 和 sparse 在同一个模型里出，索引链路统一；不引入新组件（Qdrant 本来就要用）；中文 subword 天然规避了分词器维护问题。
- **当前为什么不开**：默认链路要轻量，BGE-M3 一开就要装 `FlagEmbedding + torch + transformers`，与"默认轻、可切重"的整体原则冲突。等真有"dense 检索不够用"的明确证据，再切到 BGE-M3 把 sparse 同时开起来。

一句话：**BM25/sparse 的位置在 TalentHub 当前是"留好的口子"，不是"已经在跑的功能"**。决策原则是不为了"完整"而引入复杂度，等检索 benchmark 暴露出 dense 单通道的瓶颈再升级。

---

## 五、横向总结

| 子系统 | TalentHub 选择 | 一句话理由 |
|---|---|---|
| Embedding | OpenAI `text-embedding-3-large`（默认）+ BGE-M3（可切） | 默认链路要轻，效果第一梯队；BGE-M3 作为 hybrid 能力储备 |
| Chunking | 自研父子 chunk + 边界感知切分（零库依赖） | 中英混合 + 父子结构，自写 40 行 < 引入 LangChain 生态 |
| LLM API | OpenAI `gpt-5-mini`（默认）+ `disabled`（开关） | 性价比甜点；当前没有多 provider 诉求不预先泛化 |
| BM25 / Sparse | 默认未启用；BGE-M3 sparse + Qdrant sparse vector 作为下一步 | 不引入 ES；等 dense 瓶颈出现再切 BGE-M3 同时开 dense + sparse |

## 六、TalentHub 当前 RAG 路线的统一陈述

> TalentHub 的 RAG 当前是 **OpenAI text-embedding-3-large + Qdrant dense retrieval + 可选 Voyage rerank-2.5-lite + 自研父子 chunk + OpenAI gpt-5-mini 出题/判卷**。
>
> 这套路线的核心原则是 **默认轻量、可控、可演进**：默认链路不依赖本地大模型，零冷启动；chunking 不依赖外部生态，完全可控；BGE-M3 / sparse / hybrid 的能力以代码形式已就位，但默认关闭，等检索 benchmark 暴露出真问题再切。
>
> 这套路线**没有追求"用上所有 SOTA"，而是追求"每一层都讲得清楚为什么是它"**——这才是面对真实工程演进时最重要的能力。
