# RAG - 第 6 课：向量索引底层：HNSW、IVF-PQ、DiskANN 与向量库对比

## 学习目标（本节结束后你能做到什么）

1. 你能讲清为什么 ANN（Approximate Nearest Neighbor）索引不是“向量库的实现细节”，而是 dense retrieval 的性能核心。
2. 你能区分`精确搜索`、`图索引`、`聚类索引`、`磁盘索引`、`量化索引`几条路线分别在解决什么问题。
3. 你能解释 HNSW 的 `M / efConstruction / efSearch`、IVF-PQ 的 `nlist / nprobe / m / nbits`、DiskANN / Vamana 的核心思想，以及它们在召回、延迟、内存、构建速度上的权衡。
4. 你能说清 2024-2026 的最新趋势：过滤感知 ANN、HNSW + quantization 组合索引、磁盘优先索引、对象存储 / serverless 架构。
5. 你能从工程视角比较 `pgvector`、`Milvus`、`Qdrant`、`Weaviate`、`LanceDB`、`Vespa`、`turbopuffer` 的定位，而不是只背“谁更快”。
6. 面试里如果被问“为什么你们不用 pgvector / 为什么要上专职向量库”，你能给出带规模、过滤、运维和产品能力边界的回答。

---

## 1. 先把问题摆正：向量检索真正难的，不是算距离，而是“别把所有距离都算一遍”

从数学上说，向量搜索最朴素的版本非常简单：

- 给定查询向量 `q`
- 对库里每个向量 `x_i` 计算距离或相似度
- 找 topK

如果直接这么做，这叫：

`精确 kNN / brute-force search`

它的优点几乎完美：

- 结果最准
- 没有 ANN 误差
- 没有复杂参数

但问题也一样直接：

`当向量数量很大时，所有距离都算一遍会非常贵。`

想象一下：

- 100 万条向量
- 每条 768 维
- 每次 query 都要做 100 万次相似度计算

哪怕单次计算不算重，总量也会很快变成瓶颈。

所以向量索引真正要解决的不是：

- “如何计算余弦相似度”

而是：

`如何在不遍历整个库的情况下，尽量找到真正的近邻。`

这就是 ANN 的本质。

---

## 2. 先分清层次：算法、索引、数据库不是同一个东西

很多人学习这一层时最容易混乱的地方是：

- HNSW
- IVF-PQ
- DiskANN
- Qdrant
- Milvus
- pgvector

这些词经常在同一个段落里出现，结果把层次混掉。

更清晰的区分是：

### 2.1 算法 / 数据结构层

例如：

- HNSW
- IVF
- PQ
- DiskANN / Vamana
- ScaNN

它们回答的是：

`索引怎么组织，查询怎么剪枝。`

### 2.2 系统 / 数据库层

例如：

- pgvector
- Milvus
- Qdrant
- Weaviate
- LanceDB
- Vespa
- turbopuffer

它们回答的是：

`把这些索引放进一个可写、可过滤、可扩容、可运维的系统之后，整体怎么工作。`

这两层都重要，但问题不同：

- 算法层决定 recall-latency-memory 基本边界
- 系统层决定过滤、多租户、更新、复制、容灾、部署、成本

所以如果面试官问：

`HNSW 和 Qdrant 的区别是什么？`

一个成熟回答必须先说：

> HNSW 是 ANN 索引算法，Qdrant 是使用 HNSW 作为 dense vector index 的向量数据库，两者不在同一层。

---

## 3. ANN 的大图景：三条经典路线

把近十几年的向量索引路线压缩一下，最核心的有三条：

### 3.1 图索引：HNSW 为代表

核心思想：

- 给向量建近邻图
- 查询时沿图贪心行走
- 逐步逼近最近邻

优势：

- 高 recall
- query latency 很好
- 对很多分布都比较稳

代价：

- 内存占用大
- 构建成本高
- 更新和删除相对麻烦

### 3.2 聚类 / 倒排 / 量化索引：IVF、PQ、IVF-PQ 为代表

核心思想：

- 先把向量分桶 / 分区
- 查询时只搜最可能的几个桶
- 再在桶内用原始向量或压缩向量比较

优势：

- 存储效率高
- 易于配合量化
- 更适合超大规模

代价：

- 参数调节很关键
- recall-latency 曲线对数据分布较敏感
- 对高精度 query 往往不如 HNSW 稳

### 3.3 磁盘优先索引：DiskANN 为代表

核心思想：

- 不再假设索引必须驻留内存
- 用 SSD / NVMe 承载大索引
- 内存里只放更轻的辅助结构或压缩表示

优势：

- 可以在较小内存上服务超大规模数据
- 节点密度高

代价：

- 强依赖存储介质和 I/O 并行能力
- 系统实现复杂

这三条线并不是谁取代谁，而是在不同资源约束下占优。

---

## 4. 精确搜索：为什么它仍然值得保留

在讲 ANN 之前，一定要先讲 exact search，因为它是所有 ANN 的真值基准。

### 4.1 它什么时候其实就够用

如果你：

- 数据规模不大
- 查询量不高
- 过滤条件很强，先把候选缩得很小
- 或你极其重视 correctness

那么 exact search 完全可能是更优方案。

这也是为什么很多数据库，包括 `pgvector`，默认还是以 exact search 为起点。

`pgvector` 官方 README 就写得很清楚：

- 默认执行 exact nearest neighbor search
- exact search 提供 perfect recall
- 也可以额外加 approximate index

这句话的工程含义特别重要：

`ANN 不是天然更高级，而是用准确率去换速度。`

### 4.2 精确搜索为什么对评测尤其重要

你在线上调 ANN 参数时，最终总要回答一个问题：

`现在 recall 掉了多少？`

而这个 recall 的基准，就来自 exact search。

turbopuffer 官方甚至直接提供 recall 调试接口，做的就是：

- ANN search
- exact exhaustive search
- 比较 overlap@k

这说明一个成熟检索系统不会只看延迟，还必须保留 ground truth 通道。

---

## 5. HNSW：今天最常见、也最容易被问的图索引

### 5.1 核心思想：多层近邻图，像“向量世界里的跳表”

HNSW 的原始论文《Efficient and Robust Approximate Nearest Neighbor Search Using Hierarchical Navigable Small World Graphs》提出的关键思想是：

- 给数据点建多层图
- 上层更稀疏，用来快速跳到大致区域
- 下层更密，用来做精细搜索

论文摘要里明确提到：

- 它是 fully graph-based approach
- 不需要额外 coarse search structures
- 最大层按指数衰减随机分布
- 这样能带来对数级复杂度扩展

你可以把它直觉化地理解成：

- 上层负责“远距离大跳”
- 下层负责“近距离精修”

这就是为什么很多人会把 HNSW 类比成：

- skip list
- 多层高速路网

### 5.2 为什么 HNSW 这么流行

因为它几乎正中生产系统的痛点：

- 查询快
- recall 高
- 参数不算特别多
- 对不同数据分布通常比较稳

这也是为什么：

- `pgvector` 的近似索引先支持 HNSW
- `Qdrant` 当前 dense index 主要就是 HNSW
- `Weaviate` 的向量索引基座是 HNSW
- `Vespa` 也以修改版 HNSW 作为近似向量索引主力

### 5.3 HNSW 三个最该记住的参数

#### `M`

这是每个节点最多连接多少邻居。

直觉上：

- `M` 越大，图越稠
- recall 往往更高
- 但内存占用和构建成本都会上升

`pgvector` README、Vespa 文档、Weaviate 文档都把这个参数作为核心参数。

#### `efConstruction`

构建图时搜索多深。

直觉上：

- 值越高，建图时会更认真找邻居
- 图质量更好
- 构建时间更长

#### `efSearch`

查询时保留多大的候选列表。

直觉上：

- 越高 recall 越好
- 但 latency 也更高

这是 HNSW 最典型的“线上可调 recall knob”。

`pgvector` 文档就明确写了：

- `hnsw.ef_search` 默认 40
- 对更多结果和过滤场景，通常要把它调大

### 5.4 HNSW 的强项和弱项

强项：

- 高 recall 场景很强
- topK 小到中等时通常很优秀
- 参数语义相对清晰

弱项：

- 内存重
- 大规模构建慢
- 过滤场景容易退化
- 删除和高频更新比 flat / IVF 更麻烦

这也是为什么 2024-2026 很多工作在围绕：

- filtered HNSW
- HNSW + PQ
- HNSW + native filtering

继续做系统优化。

---

## 6. IVF-PQ：经典“分桶 + 压缩”路线，适合更大规模和更强存储约束

### 6.1 IVF：先缩小搜索范围

IVF（Inverted File Index）的基本思想是：

- 先用 k-means 等方式把向量聚成若干簇
- 每个簇一个 centroid
- 查询时只看最靠近 query 的几个簇

也就是：

`先做粗路由，再做局部搜索。`

Milvus 的 IVF_PQ 文档就把这个流程写得非常直白：

1. clustering
2. assignment
3. inverted index
4. search selected clusters

这里两个参数最关键：

- `nlist`
  - 总簇数 / 倒排桶数

- `nprobe`
  - 查询时实际搜索多少个桶

直觉是：

- `nlist` 大，桶更细，build 复杂度更高
- `nprobe` 大，查得更广，recall 更高但更慢

### 6.2 PQ：把向量压缩成短码

PQ（Product Quantization）的核心思想来自 2011 的经典论文《Product Quantization for Nearest Neighbor Search》：

- 把高维向量切成若干子向量
- 每个子空间单独量化
- 用 codebook index 替代原始浮点值

也就是说，原本一个 128 维 float32 向量需要：

- 128 × 32 bits = 4096 bits

而 PQ 可以把它压成：

- `m × nbits`

Milvus 文档举了一个很典型的例子：

- `D = 128`
- `m = 64`
- `nbits = 8`

压缩后：

- 64 × 8 = 512 bits

也就是 8x 压缩。

### 6.3 IVF-PQ：为什么它在超大规模场景里长期有生命力

IVF 解决的是：

- 别全搜

PQ 解决的是：

- 别全存

IVF-PQ 合在一起，就变成：

`缩小搜索范围 + 压缩向量表示`

这使得它在：

- 数据很大
- 内存受限
- 可以接受一定 recall 损失

的场景里很有价值。

### 6.4 IVF-PQ 最关键的参数

#### `nlist`

簇数。越大越细，但训练和管理更复杂。

#### `nprobe`

查询搜索多少簇。越大 recall 越好，但 latency 越高。

#### `m`

把向量分成多少个子向量。

#### `nbits`

每个子向量的码本索引占多少位。

这四个参数共同决定：

- 存储压缩比
- 查询速度
- recall

### 6.5 IVF-PQ 的弱点

- 对参数很敏感
- 对数据分布更敏感
- 高 recall 区间常常不如 HNSW 稳
- 更新和训练要求更强

所以它不像 HNSW 那样常被拿来做“默认第一选择”，  
但在规模和成本压力上来之后，它会非常有价值。

---

## 7. DiskANN / Vamana：当内存放不下时，索引开始向 SSD 要空间

### 7.1 核心问题：为什么索引一定要驻留内存？

DiskANN 的 NeurIPS 2019 论文开篇就抓住了这个大矛盾：

- 现有 SOTA ANN 索引往往要求主索引驻留内存
- 这让高 recall 和大规模都变贵

论文摘要给出的结果很有代表性：

- 用 64GB RAM + 廉价 SSD
- 服务 10 亿点
- 平均延迟低于 3ms
- `1-recall@1` 超过 95%

这说明它挑战的是一个长期默认前提：

`大规模高 recall ANN 不一定非要靠超大内存。`

### 7.2 它的核心思路

DiskANN 不是简单“把 HNSW 放到硬盘上”。

它更像一整套系统设计：

- 图结构存在 SSD 上
- 内存里保留更轻的辅助表示
- 查询时依靠高并发 NVMe I/O 做图遍历

论文中还引入了 `Vamana` 图，用作更适合这类场景的 graph index。

Milvus 的 `DISKANN` 文档对这件事总结得很清楚：

- 核心包括 `Vamana graph`
- 再配合内存中的 PQ codes 做近似距离估计

这说明 DiskANN 的价值，不只是“磁盘版 ANN”，而是：

`图结构 + 磁盘访问模式 + 压缩表示` 的组合设计。

### 7.3 它什么时候特别有价值

尤其适合：

- 十亿级向量
- 内存预算受限
- 有快 SSD / NVMe
- 仍然想保高 recall

### 7.4 它的局限

- 对存储硬件要求高
- 系统实现复杂
- 对小规模数据未必有优势

所以 DiskANN 更像：

`规模把你逼出内存之后的路线`

而不是所有团队一开始就该上的方案。

---

## 8. ScaNN：Google 的“分区 + 量化 + 重排序”路线

ScaNN 这条线很适合理解另一种设计哲学。

Google 2020 的论文《Accelerating Large-Scale Inference with Anisotropic Vector Quantization》强调的是：

- 对于 MIPS / inner product 检索
- 传统量化最小化 reconstruction error 不一定最优
- 更重要的是让对查询相关的误差更小

这就是 anisotropic vector quantization 的由来。

ScaNN 官方 README 也把系统思路讲得很清楚：

- search space pruning
- quantization
- reordering

也就是：

1. 先分区筛掉大部分向量
2. 再用压缩表示近似比较
3. 最后对少量候选做更精细重排

这条路线和 IVF-PQ 很像，但更强调：

- 量化目标如何更贴近检索任务
- 最后的小规模 reorder

Milvus 在 2026 文档里也已经把 `SCANN` 暴露成一种可选 index type，并明确给了：

- `with_raw_data`
- `reorder_k`

这说明 ScaNN 的思想已经从 Google 论文进入通用工程系统。

---

## 9. 2024-2026 的一个关键主题：过滤让 ANN 变难得多

很多 ANN benchmark 只测：

- 无过滤
- 纯向量 topK

但真实系统里，大量 query 都是：

- 带 tenant filter
- 带时间 filter
- 带权限 filter
- 带来源 filter

这会把 ANN 难度直接提高一个层级。

为什么？

因为 ANN 索引通常只知道“向量邻近”，  
却不知道：

`这些近邻里有多少 actually eligible。`

于是就会出现：

- 图走到了很相似的区域
- 但那里的点大半都被 filter 干掉
- 最后结果不够、recall 降、延迟升

这也是为什么 2024-2026 向量库的一个重要演化方向就是：

`filter-aware ANN`

### 9.1 Weaviate：ACORN

Weaviate 文档明确介绍了 `ACORN`：

- 忽略不满足过滤条件的对象距离计算
- 通过 multi-hop 更快抵达 filtered zone
- 随机播种额外符合过滤条件的 entrypoints

并且特别强调：

- 当 filter 与 query vector 相关性低时，ACORN 特别有用

这背后的含义很深：

`过滤不是 WHERE 子句问题，而是图遍历路径问题。`

### 9.2 pgvector：iterative index scans

`pgvector` 在 0.8.0 之后增加 iterative index scans，也是在解决这个问题：

- 过滤是在 approximate index scan 之后应用
- 可能导致结果变少
- iterative scan 会自动继续扫描，直到结果够或者触达上限

这是一种非常数据库化、非常工程现实的解法。

### 9.3 Vespa：近似 / 精确搜索自动切换阈值

Vespa 在 schema reference 里甚至直接提供：

- `approximate-threshold`
- `filter-first-threshold`

用来决定：

- 过滤条件太苛刻时，是不是直接退回 exact pre-filter
- 在近似图遍历时，先查 filter 还是先算距离

这说明成熟系统已经不再把“approximate vs exact”当静态配置，  
而是把它做成：

`随 query/filter 条件变化的执行策略。`

### 9.4 turbopuffer：native filtering

turbopuffer 2025 官方博客《Native filtering for high-recall vector search》更是直接把问题说透了：

- 大部分 production search queries 都带 WHERE 条件
- pre-filter 和 post-filter 都有明显问题
- 他们用 native filtering 来做高 recall filtered vector search

这再次说明：

`过滤不是一个边缘特性，而是生产 ANN 的主战场之一。`

---

## 10. 2026 的向量库产品，开始怎么分化

这部分非常适合系统设计面。

### 10.1 pgvector：如果你已经在 Postgres 里，而且规模还没把你逼疯

`pgvector` 的价值特别明确：

- 把向量放进 Postgres
- 可以 JOIN、事务、PITR、ACID
- exact search 起步
- 近似索引支持 HNSW 和 IVFFlat

它非常适合：

- 中小规模
- 强关系数据联动
- 过滤和业务表强耦合
- 团队不想额外维护一套专职向量库

何时它很够用：

- 10 万到几百万量级
- QPS 不夸张
- 强过滤比纯向量更重要

何时你会被它逼到边界：

- 数据继续增大
- 高并发 ANN 压力大
- 需要更多索引类型
- 需要更强的分布式弹性

### 10.2 Milvus：专职向量数据库，索引菜单最全

Milvus 的特点很鲜明：

- 索引类型多
- 文档里明确把索引拆成 data structure / quantization / refiner 三层
- 支持 HNSW、IVF、IVF_PQ、SCANN、DISKANN、HNSW_PQ 等多路线
- 分布式能力强

它适合：

- 向量检索就是系统核心能力
- 数据规模大
- 想尝试不同索引路线
- 可以接受更重的运维 / 系统复杂度

一句话：

`Milvus 更像 ANN 算法实验室 + 生产系统。`

### 10.3 Qdrant：HNSW-centric，但过滤、多租户、payload 做得很强

Qdrant 的特色不是“索引种类最多”，而是：

- dense index 以 HNSW 为主
- payload / filtering / hybrid query 做得很强
- tenant-aware optimization 明确
- quantization 和 named vectors 体系成熟

文档里非常值得记住的点有两个：

- dense vector index 主要使用 HNSW
- payload field 可以设 `is_tenant=true`，把 tenant 数据组织得更适合本地化搜索

如果你的系统特别重视：

- metadata filter
- hybrid retrieval
- 多租户
- 实时更新

Qdrant 很值得优先考虑。

### 10.4 Weaviate：HNSW + 模块生态 + 过滤优化

Weaviate 的鲜明特点是：

- HNSW 基础非常稳
- 动态 ef、vectorizer / generative 模块生态完整
- 在 filtered ANN 上投入很深，典型就是 ACORN

适合：

- 想快速把向量检索和上层 AI 模块连起来
- 又很在意过滤性能

### 10.5 LanceDB：更像“检索型 lakehouse / embedded engine”

LanceDB 的官方定位是：

- multimodal lakehouse for AI

它的工程气质和传统向量库不太一样：

- 更贴近文件 / 数据湖 / 本地嵌入式
- 明确强调 disk-based indexing philosophy
- 支持 IVF、IVF_PQ、IVF_HNSW、FTS、scalar index 等
- 适合和数据处理 / 离线分析 / 本地应用结合

如果你：

- 不想立刻上重分布式系统
- 想把向量、全文、结构化列放到同一张表里
- 希望检索层更接近数据处理层

LanceDB 非常值得看。

### 10.6 Vespa：如果你想把“搜索”和“向量检索”做成一个统一排序系统

Vespa 和典型向量库最不一样的一点在于：

`它首先是搜索引擎，其次才是向量数据库。`

它的强项非常鲜明：

- HNSW 支持单向量和多向量 field
- hybrid retrieval 强
- 过滤与 ranking system 极其成熟
- first-phase / second-phase ranking 很强

如果你要的是：

- 搜索 + 推荐 + 向量 + feature ranking 一体化

Vespa 会很有吸引力。

### 10.7 turbopuffer：serverless、对象存储、first-stage retrieval

turbopuffer 官方文档和主页定位非常一致：

- serverless vector and full-text search
- built on object storage
- 搜索层 focused on first-stage retrieval
- 支持 SPFresh vector index、native filtering、hybrid search

这条路线特别适合：

- 超大规模 namespace / tenant
- 想减少运维
- first-stage retrieval 为主
- 希望 warm cache 快、冷数据成本低

它不完全像传统“数据库”，更像：

`面向 AI 应用的 serverless search engine。`

---

## 11. 一个更成熟的比较框架：不要问“谁最好”，要问“你最缺哪种能力”

可以按这六个维度比较：

1. `数据规模`
   - 10 万 / 100 万 / 10 亿

2. `过滤复杂度`
   - 几乎无过滤 / 强权限 / 多租户 / 时间窗口

3. `写入模式`
   - 批量导入 / 高频更新 / 实时 upsert

4. `部署与运维`
   - 已有 Postgres / 想上专职 DB / 想 serverless

5. `索引多样性`
   - HNSW 足够 / 需要 IVF-PQ / 需要 DiskANN / 需要 GPU

6. `系统角色`
   - 只是 RAG retrieval layer / 还是完整搜索平台

用这个框架看，很多选择就很清楚了：

- `pgvector`
  - 关系型系统优先，规模适中

- `Qdrant / Weaviate`
  - 强过滤、强 payload、多租户、实时搜索

- `Milvus`
  - 大规模、索引路线丰富、专职向量基础设施

- `Vespa`
  - 搜索平台化、复杂排序和 hybrid 检索

- `LanceDB`
  - 本地 / lakehouse / 嵌入式 / 分析友好

- `turbopuffer`
  - serverless first-stage retrieval、超大规模低运维

---

## 12. Python / SQL 示例：三个最典型索引怎么落地

### 12.1 FAISS：精确 Flat 和 HNSW

```python
import faiss
import numpy as np

d = 768
xb = np.random.random((100000, d)).astype("float32")
xq = np.random.random((10, d)).astype("float32")

# exact baseline
flat = faiss.IndexFlatIP(d)
faiss.normalize_L2(xb)
faiss.normalize_L2(xq)
flat.add(xb)
D, I = flat.search(xq, 10)

# HNSW
hnsw = faiss.IndexHNSWFlat(d, 32)  # M = 32
hnsw.hnsw.efConstruction = 200
hnsw.hnsw.efSearch = 64
hnsw.add(xb)
D2, I2 = hnsw.search(xq, 10)
```

这段代码最想表达的是：

- Flat 是真值基线
- HNSW 是最常见的 ANN 默认点

### 12.2 FAISS：IVF-PQ

```python
import faiss

d = 768
nlist = 4096
m = 64
nbits = 8

quantizer = faiss.IndexFlatIP(d)
ivfpq = faiss.IndexIVFPQ(quantizer, d, nlist, m, nbits)

ivfpq.train(xb)
ivfpq.add(xb)
ivfpq.nprobe = 16

D, I = ivfpq.search(xq, 10)
```

这里几个关键参数就是：

- `nlist`: 分区数
- `nprobe`: 搜多少区
- `m`: PQ 子空间数
- `nbits`: 每个子空间码本位数

### 12.3 pgvector：在 Postgres 里开 HNSW

```sql
CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 64);

SET hnsw.ef_search = 100;

SELECT id, embedding <=> '[...]' AS distance
FROM items
WHERE tenant_id = 42
ORDER BY distance
LIMIT 10;
```

这个例子表达的是：

- 你可以在已有 Postgres 体系里直接获得 HNSW
- 同时保留 SQL 过滤和事务系统

---

## 13. 工程上最容易踩的 12 个坑

### 13.1 只看 ANN latency，不看 recall

快但 recall 掉太多，最后 answer 质量会被悄悄拖垮。

### 13.2 只测无过滤 benchmark

一上 metadata filter，索引表现可能完全变样。

### 13.3 把 HNSW 参数当成黑盒

至少要知道：

- `M` 管图稠密度
- `efConstruction` 管建图质量
- `efSearch` 管查询深度

### 13.4 IVF-PQ 没有足够训练数据就硬建

聚类和量化质量差，recall 会很糟。

### 13.5 只看索引体积，不看写入与重建成本

某些索引很省空间，但重建或更新很贵。

### 13.6 规模没到就过早上 DiskANN

这通常只会增加系统复杂度。

### 13.7 在 pgvector 里硬扛所有规模问题

它很强，但也有边界。

### 13.8 忽略 exact baseline

没有真值比较，你根本不知道 ANN 调优是否真的有意义。

### 13.9 只看单索引效果，不看混合链路

现代系统里：

- ANN + filter
- ANN + rerank
- ANN + hybrid retrieval

才是现实。

### 13.10 不记录 query 分桶

不同 query 类型对 ANN 参数的敏感性差异很大。

### 13.11 不做 recall 监控

很多系统线上只监控 QPS / p99，却不监控近似检索质量漂移。

### 13.12 把“向量库选型”当“索引算法选型”

这会把系统问题和算法问题混在一起。

---

## 14. 面试里怎么讲，才像真的理解过 ANN 和向量库

如果面试官问：

`为什么 HNSW 这么常用？`

你可以这样答：

> 因为它在高 recall、低延迟和参数可理解性之间取得了很好的工程均衡。它通过多层近邻图实现远跳和近修，通常在中高 recall 区间表现很稳，所以成为很多向量数据库的默认 dense index。但代价是内存重、构建慢、过滤场景可能退化。

如果面试官再问：

`IVF-PQ 和 HNSW 怎么选？`

你可以答：

> 如果我更追求高 recall 和更稳的查询表现，尤其规模还没大到内存撑不住，通常先看 HNSW；如果规模更大、存储更紧、能接受更复杂的参数调优和一定 recall 损失，IVF-PQ 会更有吸引力。前者主要是图索引，后者是分桶加压缩路线，本质上优化目标不一样。

如果面试官继续追问：

`什么时候 pgvector 够用，什么时候该上专职向量库？`

你可以答：

> 如果数据规模适中、关系过滤和 JOIN 很重要、团队已经以 Postgres 为中心，pgvector 往往很够用；但如果要更大的规模、更复杂的过滤优化、更丰富的索引类型、分布式扩展或更专业的 ANN 调优能力，就该考虑 Milvus、Qdrant、Weaviate、Vespa 这类专职系统。关键不是“谁更先进”，而是系统瓶颈在哪一层。

---

## 小结

1. 向量索引的核心任务，是在不全量扫描的前提下尽量保住近邻。
2. HNSW 是最常见的高 recall 图索引默认点；IVF-PQ 是经典的大规模分桶压缩路线；DiskANN 是内存不够时的磁盘优先路线；ScaNN 则是分区、量化和重排序的组合设计。
3. 2024-2026 的重要趋势，不只是更快 ANN，而是更重视过滤感知 ANN、量化与图索引组合、磁盘和对象存储友好的架构。
4. 向量库的比较不能只看单个索引算法，还要看过滤、多租户、更新、部署和系统角色。
5. 真正成熟的工程思路是：先有 exact baseline，再调 ANN 参数；先看系统瓶颈，再选数据库产品。

---

## 检查站

1. 为什么说 ANN 的核心问题不是“怎么计算距离”，而是“怎么少算大部分距离”？
2. HNSW 的 `M / efConstruction / efSearch` 分别在影响什么？
3. IVF-PQ 为什么特别适合规模更大、存储更紧的场景？
4. 过滤为什么会让 ANN 变得显著更难？
5. `pgvector`、`Qdrant`、`Milvus` 在系统定位上最核心的区别分别是什么？

---

## 参考与延伸阅读

- Malkov & Yashunin, *Efficient and Robust Approximate Nearest Neighbor Search Using Hierarchical Navigable Small World Graphs* (TPAMI 2020 / arXiv 2016)  
  https://pubmed.ncbi.nlm.nih.gov/30602420/
- Jégou et al., *Product Quantization for Nearest Neighbor Search* (TPAMI 2011)  
  https://cir.nii.ac.jp/crid/1360292619798828672
- Johnson et al., *Billion-scale similarity search with GPUs* (IEEE TBD 2019 / arXiv 2017)  
  https://huggingface.co/papers/1702.08734
- Subramanya et al., *DiskANN: Fast Accurate Billion-point Nearest Neighbor Search on a Single Node* (NeurIPS 2019)  
  https://papers.nips.cc/paper/9527-diskann-fast-accurate-billion-point-nearest-neighbor-search-on-a-single-node
- Guo et al., *Accelerating Large-Scale Inference with Anisotropic Vector Quantization* (ICML 2020)  
  https://proceedings.mlr.press/v119/guo20h.html
- pgvector README  
  https://github.com/pgvector/pgvector
- Milvus Docs, *Index Explained*  
  https://blog.milvus.io/docs/index-explained.md
- Milvus Docs, *HNSW*  
  https://blog.milvus.io/docs/hnsw.md
- Milvus Docs, *IVF_PQ*  
  https://milvus.io/docs/ivf-pq.md
- Milvus Docs, *DISKANN*  
  https://blog.milvus.io/docs/diskann.md
- Milvus Docs, *SCANN*  
  https://milvus.io/docs/ar/scann.md
- Qdrant Docs, *Indexing*  
  https://qdrant.tech/documentation/manage-data/indexing/
- Qdrant Docs, *Quantization*  
  https://qdrant.tech/documentation/guides/quantization/
- Qdrant Docs, *Multitenancy*  
  https://qdrant.tech/documentation/guides/multitenancy/
- Weaviate Docs, *Filtering / ACORN*  
  https://docs.weaviate.io/weaviate/concepts/prefiltering
- Weaviate Docs, *Vector Index*  
  https://docs.weaviate.io/weaviate/concepts/vector-index
- Vespa Docs, *Approximate nearest neighbor search using HNSW index*  
  https://docs.vespa.ai/en/querying/approximate-nn-hnsw.html
- Vespa Schema Reference  
  https://docs.vespa.ai/en/reference/schemas/schemas.html
- LanceDB Docs, *Indexing Data*  
  https://docs.lancedb.com/indexing
- turbopuffer Docs, *Vector Search Guide*  
  https://turbopuffer.com/docs/vector
- turbopuffer Blog, *Native filtering for high-recall vector search*  
  https://turbopuffer.com/blog/native-filtering
