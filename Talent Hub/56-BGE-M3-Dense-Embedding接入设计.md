# BGE-M3 Dense Embedding 接入设计

## 1. 目的

TalentHub 的最终目标检索栈包含：

- 父子 chunk
- `BGE-M3`
- `Qdrant`
- `bge-reranker-v2-m3`
- `Ragas + ranx`

但这条路线不适合一次性全部落地。当前这一阶段只解决一个明确问题：

- 把知识库索引与检索链路里的 embedding 能力，从“固定本地哈希实现”升级为“可切换 provider”
- 先让 `BGE-M3` 以 **dense embedding provider** 的身份进入代码结构

这一步的目标不是直接完成最终 hybrid 检索，而是先把后续替换成本降下来。

## 2. 为什么这一阶段只做 dense provider

如果直接同时接入：

- `BGE-M3`
- `Qdrant`
- sparse 检索
- multi-vector
- reranker

那就会把四类变化一次性耦合在一起：

- embedding 变化
- 向量存储变化
- 检索算法变化
- 精排变化

这样一来，出了问题就很难知道问题是在：

- 分片
- embedding
- hybrid 检索
- reranker

因此当前策略是：

1. 先把 `embedding provider` 抽象稳定下来
2. 让 `BGE-M3` 先进入 dense 通道
3. 后续再把向量存储和 hybrid 检索替换为 `Qdrant`

## 3. 当前设计

### 3.1 抽象边界

知识库索引链路现在通过 `KnowledgeEmbeddingProvider` 工作，而不是直接调用具体 embedding 实现。

这个抽象层提供两类能力：

- 批量文档 embedding
- 单条 query embedding

这样可以保证：

- 父子 chunk 索引时可以批量算向量
- 检索预演、跨知识库检索、出题检索都能统一走 query embedding

### 3.2 当前 provider 组合

当前存在两个 provider：

- `bge_m3`
  - 当前默认 provider
  - 作为正式文本 embedding 路径进入运行链路
- `local_hashed`
  - 保留为轻量实现
  - 用于开发调试或回退实验，不再作为默认路径

### 3.3 为什么当前改为默认启用 `bge_m3`

TalentHub 当前已经完成：

- `Qdrant` 检索主路径切换
- 父子 chunk 落地
- `BGE-M3` 本地与容器内验证

继续保留 `local_hashed` 作为默认值只会让代码路径和文档路径继续分裂。因此当前策略调整为：

- `BGE-M3` 成为默认 provider
- `local_hashed` 留作轻量调试实现
- 缺依赖和加载失败时继续明确报错

## 4. 配置约束

当前 `BGE-M3` dense provider 的配置约束是：

- `EMBEDDING_PROVIDER=bge_m3`
- `EMBEDDING_MODEL_NAME=BAAI/bge-m3`
- `VECTOR_DIMENSION=1024`

这里强约束 `1024` 维，是因为当前这一阶段只接入 `BGE-M3` 的 dense 向量通道。

运行时依赖约束：

- `FlagEmbedding`
- `transformers < 5.0`
- `sentencepiece`
- `datasets`
- `peft`

这是当前验证过程中明确发现的兼容要求，不满足时应直接报错，而不是继续尝试隐式修复。

依赖安装策略：

- 默认 backend 依赖已直接带上这组运行时
- provider 在首次加载模型前会先用 `huggingface_hub.snapshot_download(max_workers=1)` 做单线程预下载，避免 `FlagEmbedding` 内部并发下载在共享缓存目录里产生 `.incomplete` 文件竞争
- `backend/requirements-rag-bge.txt` 保留为本地重装入口
- Docker 镜像构建时也会安装这组依赖

如果维度不匹配，系统会直接 fail fast，而不是尝试做隐式裁剪或补丁式兼容。

## 5. 失败策略

这一阶段的失败策略刻意保持直接和明确：

- 没装 `FlagEmbedding`
  - 直接报：需要安装 `FlagEmbedding`
- 模型名无效或加载失败
  - 直接报：`BGE-M3` 模型加载失败
- 返回维度和数据库 schema 不一致
  - 直接报：向量维度不匹配
- 批量 embedding 返回条数不一致
  - 直接报：embedding count mismatch

不会做：

- 偷偷回退到 `local_hashed`
- 自动裁剪或补零
- 自动改数据库维度

## 6. 解决了什么问题

这一阶段已经解决了三个关键问题：

1. 父子 chunk 已经有稳定的批量 embedding 入口
2. 知识库检索和出题检索不再绑定具体 embedding 实现
3. 后续接 `Qdrant` 时，不需要再大改 Knowledge / Question Bank 的上层用例

## 7. 下一步

最自然的下一步是：

1. 在 `Qdrant` 路径上继续推进 sparse / multi-vector
2. 接入 `bge-reranker-v2-m3`
3. 建立 `Ragas + ranx` 评测基线

也就是说，这一阶段的定位是：

- 不是最终形态
- 但它为最终形态清理了结构障碍

补充说明：

- 上面的第 `1`、`2` 步已经在下一阶段完成
- 也就是 `Qdrant` dense retrieval 现已接入主链路
- 这一文档仍然保留，目的是说明为什么当时先做 provider 抽象，而不是一开始就把检索后端一起替换掉
