# Qdrant Dense Retrieval 接入设计

## 1. 目的

TalentHub 的最终检索路线不是单纯把 embedding 模型换掉，而是把“业务数据”和“检索底座”真正分层：

- PostgreSQL 继续负责业务事实
- Qdrant 负责知识片段召回

这一阶段的目标不是直接完成最终 hybrid retrieval，而是先把 **dense retrieval** 从 PostgreSQL `pgvector` 路径抽出来，迁到一个更适合后续 dense / sparse / multi-vector 演进的检索引擎上。

## 2. 这一阶段解决的核心问题

在上一阶段，TalentHub 已经完成了：

- 父子 chunk 落地
- `KnowledgeEmbeddingProvider` 抽象
- `BGE-M3` dense provider 接入代码结构

但检索层仍存在一个明显问题：

- 业务库和检索库仍然耦合在 PostgreSQL 一条路径里

这会导致后续如果继续接：

- sparse retrieval
- multi-vector retrieval
- reranker

上层业务用例仍然会被迫跟着改动。

因此这一阶段把问题重新切开：

- Knowledge / Question Bank 用例继续面向统一仓储接口
- 向量召回下沉为可切换的 `KnowledgeVectorStore`

## 3. 当前设计边界

### 3.1 PostgreSQL 继续负责什么

PostgreSQL 仍然保留：

- `knowledge_documents`
- `knowledge_document_versions`
- `knowledge_chunks`
- 题目、考试、判卷、日志、权限等全部业务表

也就是说，PostgreSQL 仍然是 **业务真相来源**。

### 3.2 Qdrant 负责什么

Qdrant 当前只负责：

- 存储知识子块的 dense 向量
- 承担相似度召回

它不是业务主库，也不承载题库、考试和文档管理逻辑。

### 3.3 为什么当前只写子块

父子 chunk 的职责在这一阶段是明确分工的：

- 父块：上下文归属、出处展示、业务可解释性
- 子块：细粒度召回

因此当前写入 Qdrant 的只有子块。召回命中子块后，再回 PostgreSQL 补齐：

- 子块正文
- 父块上下文
- 文档标题和来源元数据

## 4. 抽象与实现

### 4.1 新增的抽象

这一阶段新增了 `KnowledgeVectorStore` 抽象，它提供三类能力：

- `replace_document_chunks`
- `delete_document_chunks`
- `search`

这样上层仓储就不需要知道检索底层到底是：

- PostgreSQL `pgvector`
- 还是 Qdrant

### 4.2 当前实现方式

当前实现已经收敛为单一路径：

- 向量写入和召回交给 `QdrantKnowledgeVectorStore`
- 命中结果再回 PostgreSQL hydrate chunk 元数据

也就是说，TalentHub 当前不再保留 PostgreSQL `pgvector` 检索回退路径。

## 5. 写入路径

### 5.1 新建/更新知识文档

当前写入路径是：

1. 文档切成父子 chunk
2. 计算 embedding
3. 先写 PostgreSQL chunk 记录
4. 构造 `KnowledgeChunkVectorRecord`
5. 将子块写入 Qdrant
6. 成功后再提交数据库事务

这里刻意保持 fail fast：

- Qdrant 写入失败，整个文档索引流程直接失败
- 不会偷偷只写数据库、不写向量索引

### 5.2 删除知识文档

知识文档被归档后，会同时尝试删除 Qdrant 中对应的子块向量。

当前做法是：

- PostgreSQL 归档提交后
- 再清理 Qdrant

这是一个明确的工程权衡：

- 业务状态先稳定
- 检索索引随后同步清理

如果 Qdrant 清理失败，系统会明确打日志，不会静默忽略。

## 6. 检索路径

### 6.1 文档内检索

知识库预演、知识文档出题时，backend 当前直接走 Qdrant：

1. query 先做 embedding
2. 调用 Qdrant `query_points`
3. 返回命中的 chunk id 和 score
4. 再到 PostgreSQL 加载最新非归档子块记录
5. 同时补足父块上下文

### 6.2 跨知识库检索

跨知识库检索与文档内检索走同样模式，只是：

- 不再附带单文档 filter
- 命中范围扩大到整个知识库的最新非归档文档子块

## 7. 日志与错误表达

这一阶段继续遵守 TalentHub 的业务日志原则：

- 不只记录“接口调了”
- 要明确记录“索引、召回、清理”的业务动作

当前新增和使用的关键日志包括：

- `knowledge_vector_store_document_replaced`
- `knowledge_vector_store_document_deleted`
- `knowledge_vector_store_search_completed`

错误表达也保持直接：

- Qdrant collection 建不起来：直接报 collection preparation failed
- 向量 upsert 失败：直接报 document vector upsert failed
- 搜索失败：直接报 Qdrant knowledge search failed

不会做：

- 静默降级回 PostgreSQL
- 自动跳过写入失败的文档
- 自动屏蔽检索 backend 故障

## 8. 这一阶段已经验证了什么

这一阶段已经真实验证过：

- Docker 中的 Qdrant 服务可启动
- 新导入知识文档会把子块向量写入 Qdrant
- 基于知识文档的出题链路已经走 Qdrant dense retrieval
- 旧知识文档可通过回填脚本补入 Qdrant
- RAG 闭环烟雾测试通过

这说明 Qdrant 不再只是目标选型，而是已经进入运行链路。

## 9. 当前边界

这一阶段仍然刻意保留了几个边界：

- 当前只实现 dense retrieval，尚未把 sparse / multi-vector 接进召回主路径
- 当前只把子块写入 Qdrant，父块仍作为 PostgreSQL 侧展示上下文
- Docker 默认镜像已经包含 `BGE-M3` 运行时依赖
- `BGE-M3 + Qdrant` 已经是当前正式默认检索路径
- `bge-reranker-v2-m3` 已正式接入主链路
- `Ragas + ranx` 已建立第一版检索评测基线

这些不是遗漏，而是为了控制每一阶段的复杂度和可验证性。

## 10. 下一步

最自然的后续演进是：

1. 在 Qdrant 路径上继续推进 `BGE-M3` 的 sparse / multi-vector
2. 扩大 `Ragas + ranx` 的评测集覆盖范围
3. 为检索结果增加更直观的质量观察与调试面板

也就是说，这一阶段的定位是：

- **检索后端解耦完成**
- **Qdrant dense retrieval 落地完成**
- **rerank、evaluation 已进入主链路**
- **真正的 hybrid retrieval 进入下一阶段**
