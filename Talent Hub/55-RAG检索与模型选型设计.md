# TalentHub RAG 检索与模型选型设计

## 1. 目标

TalentHub 的 RAG 不是一个独立聊天能力，而是企业培训业务链路里的检索底座。它要同时支撑：

- 基于内部知识生成题目
- 用户作答后的出处引用与学习建议
- 知识库检索预演
- 跨知识库的培训内容召回

这意味着我们不能只追求“能检索到”，还要平衡：

- 中文英文混合文档效果
- 企业术语、编号、缩写、规则名的可命中性
- 长文档与结构化文档的可切片性
- 本地可部署与后续演进空间
- 图片、截图、课件页等非纯文本知识的纳入路径

补充说明：

- 本文描述的是 TalentHub 的主线检索演进目标
- 当前默认运行时是 `OpenAI text-embedding-3-large + Qdrant dense retrieval`
- `BGE-M3 + Qdrant hybrid retrieval` 仍保留为可切换和继续演进的高级路线

## 2. 选型原则

### 2.1 检索优先于对话

TalentHub 的核心不是通用问答，而是“把最相关的知识片段找出来，再把这些片段带入出题、判卷与学习建议”。因此模型和存储的优先级应围绕检索质量组织，而不是围绕聊天模型组织。

### 2.2 文本主通道先做强

现阶段图片确实存在，但在业务里，真正决定题目质量和反馈质量的仍然主要是制度、网页正文、培训材料文本。因此第一阶段先把文本检索通道做强，再为图片保留专门通道。

### 2.3 召回、精排、评测必须分层

RAG 质量不是由一个 embedding 模型单独决定，而是由四层共同决定：

- chunking
- retrieval
- reranking
- evaluation

如果这些层混在一起，后面就无法定位问题，也无法有纪律地优化。

### 2.4 尽量保留业务域和数据域稳定

知识文档、题库、考试、判卷这些业务对象应继续留在 PostgreSQL 中。检索引擎是为业务服务的基础设施，不应该反向侵入领域边界。

## 3. 候选方案对比

### 3.1 为什么不继续停留在当前本地轻量 embedding

当前实现的优势是：

- 完全本地
- 零外部 embedding 成本
- 结构简单，方便验证闭环

但它的问题也很明确：

- 本质上不是训练好的语义 embedding
- 更像哈希特征向量，不适合长期承担高质量检索
- 对中文英文混合语义、改写、术语变体的鲁棒性不足
- 无法支撑真正的 hybrid retrieval

因此，它适合原型验证，不适合作为 TalentHub 的长期检索底座。

### 3.2 为什么不把最终方案定成单一云 API embedding

Gemini、OpenAI、Voyage 都可以提供很强的 dense embedding，但如果 TalentHub 的长期目标明确包含：

- hybrid retrieval
- 企业术语和编号的精确匹配
- 更强的本地可控性
- 后续检索链路评测与调优

那么仅仅接入一个 dense embedding API 不够。dense 方案适合第一阶段快速升级，但不是第二阶段的终局。

### 3.3 为什么最终更偏向 BGE-M3 路线

`BGE-M3` 的优势不只是“一个开源 embedding 模型”，而是它天然覆盖三种检索表示：

- dense retrieval
- sparse retrieval
- multi-vector retrieval

这意味着它不是只补语义相似，而是更适合作为 hybrid 检索底座。对于 TalentHub 这种企业知识库，它特别适合处理：

- 中文英文混合
- 术语、缩写、规则编号
- 长制度文档
- 一段文本内包含多个知识点的局部匹配

它的代价是接入复杂度更高，但换来的是检索上限更高、后续演进空间更大。

## 4. 最终推荐选型

### 4.1 Chunking

采用 **父子 chunk** 设计。

推荐组合：

- 文档结构与层级保留：`Docling HybridChunker`
- 子块切分与句段边界控制：`LlamaIndex SentenceSplitter`

父块的职责：

- 保留标题、章节、列表、表格等结构归属
- 作为展示和出处引用的稳定语义单元

子块的职责：

- 作为召回时的细粒度检索单元
- 让 query 能命中父块中的局部知识点

为什么父子而不是只做平铺切片：

- 题目生成和学习建议需要较完整的上下文
- 检索时又不能只靠大块文本
- 父子结构可以同时兼顾“命中精度”和“业务可解释性”

### 4.2 Embedding

采用 **`BGE-M3`** 作为文本检索主 embedding。

推荐原因：

- 开源，可本地部署
- 支持多语言
- 支持 dense / sparse / multi-vector
- 长文本能力强
- 与 hybrid 路线天然一致

它在 TalentHub 里的职责是：

- 生成子块检索表示
- 支撑跨知识库召回
- 为后续 hybrid 和精排打底

### 4.3 Hybrid Retrieval

采用 **`Qdrant`** 作为检索引擎。

推荐原因：

- 对 hybrid 查询支持更自然
- 对 named vectors、payload filter、多阶段 query 组织更友好
- 比只靠 PostgreSQL `pgvector` 更适合后续演进 dense + sparse + multi-vector

PostgreSQL 仍然保留：

- 业务表
- 知识文档元数据
- chunk 元数据
- 题库、考试、判卷、日志等业务信息

Qdrant 的职责只是：

- 存储检索表示
- 承担召回

### 4.3.1 为什么不是其他向量数据库

TalentHub 需要的不是“能存向量”这么简单，而是后续要认真做：

- dense
- sparse
- multi-vector
- reranker 前的候选召回
- 本地开发和本地部署

在这个前提下，几类常见方案的取舍是：

- `pgvector`
  - 优点：最省事，和 PostgreSQL 同库
  - 问题：当检索要从 simple dense 走向 hybrid、多阶段召回、multi-vector 时，结构会越来越拧巴
  - 结论：适合原型，不适合作为 TalentHub 的长期检索底座

- `Qdrant`
  - 优点：对 dense / sparse / hybrid / payload filter 的支持都很自然，本地部署轻，Python 接入顺
  - 问题：要多维护一套检索基础设施
  - 结论：最符合 TalentHub 当前“本地优先 + hybrid 演进”的方向

- `Milvus`
  - 优点：大规模向量检索能力强，生态成熟
  - 问题：本地单机开发体验和整体运维复杂度高于 Qdrant
  - 结论：更适合从一开始就明确追求更大规模和更重检索基础设施的团队

- `Weaviate`
  - 优点：一体化能力强，概念层清晰
  - 问题：TalentHub 当前并不需要它那套更重的一体化抽象，本地维护成本也偏高
  - 结论：不是当前最简洁的选择

- `Pinecone`
  - 优点：托管省心
  - 问题：和 TalentHub 的本地优先、开源优先方向不一致
  - 结论：不作为当前主选项

因此，Qdrant 的价值不是“绝对最强”，而是：

- 对 TalentHub 当前阶段最均衡
- 对后续 hybrid 演进最顺
- 对本地部署最友好

### 4.4 Reranker

采用 **`bge-reranker-v2-m3`**。

推荐原因：

- 与 `BGE-M3` 路线一致
- 多语言能力强
- 本地可控
- 用于把召回得到的候选片段再精排

需要明确的一点是：

- sparse 不是 reranker
- reranker 也不是 dense 的替代品

它们分工如下：

- dense / sparse / multi-vector：负责召回
- reranker：负责对候选结果做更贵但更准的排序

### 4.5 Evaluation

采用：

- `Ragas`
- `ranx`

推荐原因：

- `Ragas` 更适合组织 RAG 评测集与 LLM-based 评估
- `ranx` 更适合算检索指标，如 `NDCG@k`、`MRR`、`Recall@k`

TalentHub 后续要维护两类评测集：

- 检索评测集
- 生成/反馈评测集

其中本方案优先先把检索评测集做起来。

## 5. 当前阶段落地状态

当前主链路已经完成：

- 父子 chunk
- `BGE-M3` dense / sparse / multi-vector hybrid embedding
- `Qdrant` hybrid retrieval
- `bge-reranker-v2-m3`
- `Ragas + ranx` 第一版检索评测基线

当前还没有完成的部分：

- 图片、截图、课件页的原生多模态检索
- 更完整的离线评测集与线上可视化评测看板
- hybrid 融合参数、候选规模和 reranker 截断策略的系统调优

## 6. 图片怎么处理

当前推荐方案明确是 **文本主通道优先**，因此图片不是直接进入 `BGE-M3`。

第一阶段建议：

- OCR
- caption
- 页面结构提取
- 把图片内容转成可检索文本，再进入文本检索链路

这适合：

- 网页中的截图
- 培训课件中的流程图和表格截图
- 平台页面操作说明图

第二阶段如果确认图片在知识库里是高价值主来源，再考虑新增独立多模态 embedding 通道。也就是说，图片不被忽略，但暂时不强行混入主检索底座。

## 7. 在 TalentHub 里的目标链路

### 6.1 文档入库

- 文档进入 Knowledge 模块
- 保留原始文本与结构化元数据
- 形成父块和子块

### 6.2 索引构建

- `BGE-M3` 生成检索表示
- 子块写入 Qdrant
- PostgreSQL 保留 chunk 与文档关系

### 6.3 检索

- query 进入召回层
- Qdrant 执行 dense + sparse + multi-vector 召回
- 候选结果送入 `bge-reranker-v2-m3`
- 返回 top-k 最相关片段

### 6.4 业务使用

这些检索结果会被用于：

- 基于知识库出题
- 跨知识库出题
- 判卷后学习建议
- 知识库检索预演

## 8. 这套方案解决了什么问题

- 不再依赖简单本地哈希向量承担长期检索
- 不再把 dense embedding 当成全部检索能力
- 能更自然地支撑 hybrid retrieval
- 给企业术语、编号、局部语义命中留下空间
- 给后续检索评测、回归和优化提供稳定底座

## 9. 这套方案的代价

- 接入复杂度高于单纯云 API embedding
- 需要引入新的检索基础设施 `Qdrant`
- 需要维护本地模型推理与索引同步
- 需要更严格的评测纪律

因此，它不是“最快上线”的路线，而是“长期更正确”的路线。

## 10. 分阶段实施建议

### 阶段一：结构先行

- 建立父子 chunk 体系
- 形成标准化 chunk 元数据
- 建好检索评测集骨架

### 阶段二：召回替换

- 引入 `BGE-M3`
- 建立 Qdrant collection
- 打通 dense 召回

当前实际状态：

- `BGE-M3` dense embedding provider 已接入代码层，并已成为当前默认文本 embedding provider
- `Qdrant` 已作为唯一 dense retrieval backend 接入，并完成了新文档写入和历史文档回填
- 当前仍未接入 sparse / multi-vector，因此这一阶段完成的是 dense 召回迁移，不是最终 hybrid 召回

### 阶段三：hybrid 与精排

- 接入 sparse / multi-vector
- 接入 `bge-reranker-v2-m3`
- 对召回结果做精排

### 阶段四：评测闭环

- 接入 `Ragas + ranx`
- 把检索指标正式纳入回归
- 决定不同知识源的策略差异

## 10. 结论

TalentHub 的最终推荐 RAG 检索栈是：

- Chunking：父子 chunk
- Embedding：`BGE-M3`
- Hybrid Retrieval：`Qdrant`
- Reranker：`bge-reranker-v2-m3`
- Evaluation：`Ragas + ranx`

这套方案最适合 TalentHub 的原因不是“它最省事”，而是：

- 它更贴近企业知识库的真实检索问题
- 它给中英混合和企业术语提供更强支撑
- 它能和出题、判卷、学习建议形成长期可维护的检索底座
