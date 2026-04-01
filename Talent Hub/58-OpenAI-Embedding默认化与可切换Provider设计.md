# OpenAI Embedding 默认化与可切换 Provider 设计

## 1. 目的

TalentHub 当前已经验证过：

- 父子 chunk
- Qdrant dense retrieval
- `BGE-M3`

但 `BGE-M3` 的运行时依赖较重，默认放进 backend 镜像会带来两个明显问题：

- Docker 镜像体积和构建复杂度上升
- 本地开发与容器运行都需要承担 `FlagEmbedding` 及其依赖链

在 TalentHub 仍以业务学习和架构演练为主的阶段，默认运行时应该优先追求：

- 更轻
- 更稳
- 更容易重建
- 更容易切模型

因此当前策略调整为：

- 默认文本 embedding provider 改为 `OpenAI text-embedding-3-large`
- `BGE-M3` 保留为可切换 provider
- 检索主路径继续保留 `Qdrant`

## 2. 当前默认路线

TalentHub 当前默认的文本检索路线是：

- Chunking：父子 chunk
- Embedding：`OpenAI text-embedding-3-large`
- Vector Store：`Qdrant`

其中：

- PostgreSQL 继续保存文档、chunk、题目、考试等业务真相
- Qdrant 继续承担召回
- OpenAI embedding 只负责生成 dense vector

## 3. 为什么默认改成 OpenAI

### 3.1 运行时更轻

OpenAI embedding provider 只依赖：

- `openai`

而不需要额外安装：

- `FlagEmbedding`
- `transformers`
- `sentencepiece`
- `datasets`
- `peft`

这让默认 backend 镜像明显更轻，也让容器重建更稳定。

### 3.2 更适合作为默认 dense provider

当前 TalentHub 的检索主链已经独立到了 Qdrant，因此 embedding provider 的第一职责是：

- 稳定地产出 dense vector

在这一阶段，`text-embedding-3-large` 比本地大模型 provider 更适合作为默认路径，因为它：

- 接入简单
- 维度明确
- 不依赖本地推理框架
- 更利于后续快速切换到其他云端 embedding 模型

### 3.3 保留 BGE-M3 的原因

默认改成 OpenAI，不代表放弃 `BGE-M3` 路线。

`BGE-M3` 仍然保留为重要的可选 provider，因为它更适合后续演进：

- dense / sparse / multi-vector
- 本地可控检索底座
- 更深的 hybrid retrieval

当前只是把它从“默认运行时”降级为“可选高级 provider”。

## 4. 可切换设计

### 4.1 配置入口

当前只需要通过配置切换：

- `EMBEDDING_PROVIDER`
- `EMBEDDING_MODEL_NAME`
- `VECTOR_DIMENSION`

默认配置为：

- `EMBEDDING_PROVIDER=openai`
- `EMBEDDING_MODEL_NAME=text-embedding-3-large`
- `VECTOR_DIMENSION=3072`

如果切到 `BGE-M3`：

- `EMBEDDING_PROVIDER=bge_m3`
- `EMBEDDING_MODEL_NAME=BAAI/bge-m3`
- `VECTOR_DIMENSION=1024`

### 4.2 Provider 抽象边界

TalentHub 上层只依赖统一抽象：

- `KnowledgeEmbeddingProvider`

因此上层不会直接关心具体是：

- `OpenAI`
- `BGE-M3`
- `local_hashed`

这让切换 provider 时，不需要重写知识库、出题、判卷等业务用例。

## 5. Qdrant 与维度切换

向量维度切换不是纯配置问题，因为 Qdrant collection 的维度是固定的。

因此当前规则是：

- 如果配置里的 `VECTOR_DIMENSION` 与现有 collection 不一致
- backend 会直接重建该 collection

这不是业务数据丢失，因为：

- PostgreSQL 仍保存 chunk 主数据
- 向量索引可以从 PostgreSQL 重新回填

因此切换 provider 后，正确流程是：

1. 重启 backend
2. 让 Qdrant collection 按新维度重建
3. 运行知识向量回填脚本

## 6. 依赖策略

当前依赖策略分成两层：

- 默认依赖
  - 只包含 OpenAI embedding 所需的轻量运行时
- BGE 可选依赖
  - 放在 `backend/requirements-rag-bge.txt`

对于 Docker backend，还额外通过：

- `INSTALL_BGE_RUNTIME`

这个 build arg 显式控制是否把 `BGE-M3` 运行时装进镜像。

这保证了：

- 默认环境更轻
- 仍可按需切到 `BGE-M3`

## 7. 解决了什么问题

这一轮主要解决了三个问题：

1. 默认 backend 运行时不再被本地 embedding 依赖链拖重
2. embedding provider 已正式具备可切换能力
3. `Qdrant` 与 embedding 维度切换之间的边界变得明确

## 8. 下一步

后续最自然的演进顺序是：

1. 保持 OpenAI dense 路线稳定
2. 接入 `bge-reranker-v2-m3`
3. 建立 `Ragas + ranx` 评测基线
4. 如果后续确定要认真做 hybrid，再切回 `BGE-M3` 作为正式主 embedding
