# 核心抽象：Topic / Partition / Replica / Segment / Offset / Consumer Group

## 这一篇要回答什么

上一篇我们立了一个心智模型：**Kafka 是分布式日志，不是队列**。

这一篇要做的事，是把这个心智模型拆成 6 个具体的抽象——并且要回答比“它们是什么”更重要的三个问题：

1. 为什么 Kafka 选了**这 6 个**抽象，而不是更多或更少
2. 它们之间的**层级关系和约束**是什么
3. 每一个抽象具体在堵哪一个洞，去掉它会怎样

学这一篇的人最容易犯的错，是把它当成八股文背：“Topic 是主题，Partition 是分区，Replica 是副本……”。这种背法学完什么都没留下。正确的姿势是把它们当成**互相咬合的齿轮**：一个齿轮转，另一个跟着转，缺一个整个机器就停。

## 抽象的层级图

先把整张图立起来，后面所有细节都挂在这张图上：

```
                   ┌──────────────────────────────────────────────┐
   逻辑层          │                  Topic                       │
                   │      （用户视角的一份"数据流"）              │
                   └──────────────────────────────────────────────┘
                                       │
                                       ▼
                   ┌──────────────────────────────────────────────┐
   并发 / 顺序层   │    Partition 0 | Partition 1 | Partition 2   │
                   │   （并发单元 + 顺序单元 + 副本单元）         │
                   └──────────────────────────────────────────────┘
                                       │
                                       ▼
                   ┌──────────────────────────────────────────────┐
   可靠层          │     Replica (Leader) + Replica (Follower)    │
                   │       （副本组：高可用、不丢、可选主）       │
                   └──────────────────────────────────────────────┘
                                       │
                                       ▼
                   ┌──────────────────────────────────────────────┐
   存储层          │    Segment 0 | Segment 1 | Segment 2 ...     │
                   │   （append-only 日志切片 + 索引 + 时间索引） │
                   └──────────────────────────────────────────────┘
                                       │
                                       ▼
                   ┌──────────────────────────────────────────────┐
   定位层          │     Offset：日志中一条消息的"行号"           │
                   │   （Producer Offset / Consumer Offset 不同） │
                   └──────────────────────────────────────────────┘

   消费层（并行的另一面，挂在 Partition 上）
                   ┌──────────────────────────────────────────────┐
                   │             Consumer Group                   │
                   │  （消费状态的"逻辑读者"，决定并发与隔离）    │
                   └──────────────────────────────────────────────┘
```

读这张图的方式：**Topic 一路向下，每下一层都是"上一层为了解决某个问题而拆出来的物理化"**。

- Topic 是用户视角，**broker 上不存在 Topic 实体，存在的只是 Partition**
- Partition 把吞吐 / 顺序 / 副本三件事捆在了一起
- Replica 解决“单 Partition 节点挂了怎么办”
- Segment 解决“一个 Partition 的日志无限长，怎么落盘 / 删除 / 检索”
- Offset 解决“日志里怎么定位一条消息”
- Consumer Group 解决“多个消费者并发读，但又不能互相重复”

下面一个一个拆。

## Topic：逻辑层，最容易被高估

Topic 是用户视角的一份“数据流”。比如 `user.behavior.click`、`order.created`、`payment.txn` 这种。

但有几个事实和直觉相反：

**Broker 上不存在“Topic 这个东西”**。
broker 上的物理实体是一个个 Partition 目录，比如 `user.behavior.click-0`、`user.behavior.click-1`。Topic 只是这些 Partition 在元数据里的逻辑分组。

**Topic 不是 RabbitMQ 的 Queue，更不是数据库表**。
不要按“一个业务一个 Topic”的思路建表。Topic 是“数据流”的粒度，太细就把 Partition 总数推爆。常见踩坑：上线时一个集群有几万个 Topic、几十万个 Partition，Controller 切换一次卡 10 分钟。

**Topic 级别没几个有意义的语义参数**。
保留时间（`retention.ms`）、压缩策略（`cleanup.policy`）、Partition 数、副本数——大部分有效配置都落在 Partition / Replica 层。Topic 本身是个“配置容器”。

> Topic 唯一不可替代的作用：**给一组 Partition 一个语义名字**，让用户能按业务讲话。除此之外，它就是个目录名。

## Partition：整个 Kafka 最重要的抽象

如果让我只留一个抽象，我留 Partition。理由前面提过，但要重点强调——**Partition 同时承担三件事**，这是它的设计美感，也是它的代价。

### 身份一：并发单元

> 同一个 Consumer Group 内，**一个 Partition 在任意时刻只能被一个 Consumer 消费**。

这条规则是 Kafka 整个消费模型的根。它推出三件事：

1. **Consumer 数 ≤ Partition 数**：多出来的 Consumer 会空跑（拿不到分配）
2. **想加消费并发？先加 Partition**——这是 Kafka 几乎唯一的“横向扩消费”手段
3. **Partition 数是一个 Topic 的吞吐上限**——一旦分区数定了，单 Consumer Group 的消费天花板就锁定了

为什么要这么强？因为 Kafka 不像 RabbitMQ 那样在 broker 端维护“消息状态机”。如果允许多个 Consumer 共消费同一个 Partition，offset 提交就会变成多写者问题——Kafka 选择从源头避免这个问题。

### 身份二：顺序单元

> **Kafka 只保证分区内有序，不保证 Topic 全局有序**。

这是一道分水岭：从 RabbitMQ / RocketMQ 转过来的人最容易栽。

要保证“同一个订单的状态消息按序”，必须保证它们落在**同一个 Partition**。做法是 Producer 端按 `orderId` 哈希成 partition key。这件事 Kafka 不会自动帮你做——它的分区策略默认是按 key 哈希，如果你没传 key，就轮询。

更细的坑（后面 07、13 会专挖）：

- 即便走同一个 Partition，Producer 端 `retries > 0` 且 `max.in.flight.requests.per.connection > 1` 时，**重试也能把分区内顺序打乱**
- 要分区内严格有序，要么 `max.in.flight = 1`（代价是吞吐），要么开 `enable.idempotence=true`（broker 端按 Sequence Number 重排）

### 身份三：副本单元

> 副本是**Partition 级别**的，不是 Topic 级别的。

每一个 Partition 都有自己的 Leader 和 Follower 副本组。同一个 Topic 的不同 Partition，**Leader 可以分布在不同 broker 上**。这就是 Kafka 横向扩流量的根本机制——Topic 一拆 N 个 Partition，N 份 Leader 写流量就摊到 N 个 broker 上。

这条事实推出几个工程结论：

- 一个 broker 挂了，影响的是“以它为 Leader 的所有 Partition”，不是“以它为 Leader 的所有 Topic”——颗粒度比想象中细
- 副本 reassign（重分布）是 Partition 粒度的，运维代价比想象中高
- “3 副本”指的是**每个 Partition 3 个副本**，不是“整个 Topic 3 个副本”

### Partition 数的工程权衡

Partition 数选多少，是 Kafka 选型上最直接的工程权衡：

| Partition 多 | Partition 少 |
|---|---|
| 消费并发高 | 消费并发受限 |
| 单 Partition 流量小，Leader 压力分散 | 单 Partition 流量大 |
| 文件句柄数多、ZK/KRaft 元数据膨胀 | 元数据轻 |
| 副本同步代价线性增加 | 副本同步压力小 |
| Rebalance 时间线性变长 | Rebalance 快 |
| Controller 切换时间线性变长 | Controller 切换快 |

经验法则（不绝对）：

- 单 Topic Partition 数：**几十到几百**是甜区，过千要慎重
- 整个集群 Partition 总数：**几万**还好，**几十万就要小心了**（即便 KRaft 改善了很多）
- 一个 broker 上 Partition 数：**几千**已经偏多
- **Partition 数只能加不能减**——加是数据重分布，减没原生支持

## Replica：把 Partition 变成可靠的

Partition 解决了“横向扩”，但单 Partition 还是一个单点。Replica 就是用来把它做成高可用的。

### Leader / Follower 不对称

Kafka 的副本模型最常被问到的设计：

> 为什么 Follower 不能服务读？

Kafka 直到 2.4 才支持有限的 Follower 读（KIP-392），并且默认还是关的。设计哲学是：

- 读写都走 Leader → **强一致** + 实现简单
- Follower 只 fetch + apply → **逻辑极轻**，能用很高的副本因子

代价就是 Leader 是热点。但这恰好被 Partition 数解决了——Partition 多了，Leader 自然分散到各个 broker。所以 Kafka 的横向扩，是“多 Partition × 多 Leader 分布”这一对配合，不是单 Partition 多读副本。

### ISR：In-Sync Replicas

ISR 是 Kafka 一致性模型的灵魂，05 会专挖。这里先建立直觉：

- ISR = “**当前跟上了 Leader 进度的副本集合**”，包含 Leader 自己
- Follower 跟得上（在 `replica.lag.time.max.ms` 内追上来）→ 留在 ISR
- 跟不上 → 被踢出 ISR，但还是 Replica，只是不算“同步副本”
- `acks=all` 等的是“ISR 内所有副本都 ack”，不是“所有 Replica 都 ack”
- `min.insync.replicas` 限定的是“ISR 至少要有几个，否则拒写”

这一组规则让 Kafka 同时拿到两件事：

1. 一般情况下，写延迟靠最快的 N 个副本，不会被慢副本拖死（“跟不上就踢出去”）
2. 故障时，从 ISR 里选新 Leader——**ISR 里的副本一定持有最新数据**

后面会看到，这套机制还要配合 HW / LEO / Leader Epoch 才能真正闭环。

## Segment：让无限日志可落地

Partition 是一个逻辑上无限的 append-only 日志。但磁盘文件不能无限大。

> Segment 就是 Partition 的物理切片。

每个 Partition 在磁盘上的目录里大概长这样：

```
user.behavior.click-0/
├── 00000000000000000000.log      ← 数据文件
├── 00000000000000000000.index    ← 位置索引（offset → 文件位置）
├── 00000000000000000000.timeindex← 时间索引（timestamp → offset）
├── 00000000000000123456.log
├── 00000000000000123456.index
├── 00000000000000123456.timeindex
└── ...
```

文件名是这个 Segment 的**起始 offset**。

### Segment 解决的四个工程问题

**问题 1：怎么删除老数据**
不可能从一个大文件中间“抠掉”。Kafka 的做法是按 Segment 整段删——`retention.ms` / `retention.bytes` 命中了，就把整个老 Segment `unlink` 掉。简单粗暴、O(1)。

**问题 2：怎么按 offset 定位一条消息**
log 文件里消息是变长的（每条带 header + payload），不能直接 seek。Segment 配套一个 `.index` 文件，**稀疏索引**：每隔 ~4KB 一条记录，记录“offset → 文件物理位置”。查找时：

1. 用 Segment 文件名做二分定位到哪个 Segment
2. 在 Segment 的 `.index` 里二分找到 ≤ 目标 offset 的最近一条
3. 从那个物理位置开始顺序扫，扫到目标 offset

稀疏索引的好处：内存占用小（不是每条都索引），定位代价稳定（最多扫 4KB）。

**问题 3：怎么按时间定位**
比如“给我从昨天 14:00 开始的消息”。`.timeindex` 文件提供 “timestamp → offset” 的映射，配合 `.index` 完成两级跳转。

**问题 4：怎么做日志压缩（compact）**
对 `cleanup.policy=compact` 的 topic（典型如 `__consumer_offsets`），Kafka 会**保留每个 key 的最新值**。Segment 是 compact 的工作单元——后台进程整段读、合并、写出新 Segment、删旧 Segment。

### 为什么是 1GB 默认

默认 `log.segment.bytes=1GB`。这个数字的取舍：

- 太小（几十 MB）：文件数爆炸，OS 句柄、目录扫描、index 元数据全变重
- 太大（10GB+）：单段删除粒度大、压缩工作量大、index 加载慢
- 1GB 是经验上的甜区

但这个值是 Topic 级可调的，对**保留时间长、流量大**的 Topic 可以调大；对**短保留、压缩型**的 Topic 可以调小让删除更及时。

## Offset：双重身份的“行号”

Offset 表面是个 long 型整数，但它在 Kafka 里有两层完全不同的角色：

### Producer 视角：Broker 写入时给的“分配号”

Producer 发出的消息没有 offset。它落到 Leader 上，Leader **append 到 Segment 末尾**时，分配下一个 offset。所以：

- Offset 是 broker 单调递增产出的，不会回退
- 同一个 Partition 内 offset 严格连续（除非 compact）
- 跨 Partition 没有 offset 可比性

### Consumer 视角：自己维护的“读到哪了”

Consumer 读消息时，broker 不记录“你读到哪”。Consumer 自己读完一批后，把当前位置 commit 回去——commit 的目的地是一个特殊的内部 Topic：

```
__consumer_offsets   （内部 Topic，默认 50 个 Partition，compact 策略）
```

Commit 的 key 是 `(group.id, topic, partition)`，value 是 `committed_offset`。所以只要 Consumer 选定 Group，下次启动它知道该从哪开始读。

这是 Kafka **状态外置** 的关键设计：broker 没有“谁消费到哪”的状态，它只是另一个 Topic 的写者。后果：

- broker 极轻、几乎无状态
- 多 Group 完全独立，互不影响
- offset 重置（reset to earliest / latest / specific offset）是普通操作，不是“维护性操作”

### HW / LEO：另一组 offset

Partition 上还有两个特殊的 offset，副本一致性的核心（05 会专挖）：

- **LEO（Log End Offset）**：当前 Partition 写到哪了，下一条要写的位置
- **HW（High Watermark）**：所有 ISR 副本都已经同步过的位置；**消费者最多只能看到 HW 之前的消息**

为什么消费者不能读到 LEO 之间的数据？因为那一段在某些副本上还没落地，万一 Leader 挂了被截断，消费者就看到“幻象数据”了。HW 是 Kafka 提供 read-your-writes 一致性的边界。

## Consumer Group：消费状态的“逻辑读者”

最后一个抽象，挂在 Partition 上的另一侧。

### 一个 Group 的核心规则

1. **Group 内一个 Partition 只能被一个 Consumer 消费**（决定不重复、决定 offset 提交无冲突）
2. **Group 间互不感知**（决定多下游可以共享一份数据）
3. Group 由一个 **Coordinator**（一个 broker）管理，负责成员管理、分配方案、Heartbeat、Rebalance

### 这个抽象同时解决了三件事

**事一：统一了点对点和发布订阅**

需要哪种模式，只看 Group ID 怎么用：

- 点对点 → 所有 Consumer 用同一个 group.id
- 发布订阅 → 每个下游一个独立 group.id

**事二：把消费并发和消费独立解耦**

“我要 8 路并发消费” 和 “另一个下游也要消费这份数据，但他想要 2 路并发”——两件事各自调各自 Group 的 Consumer 数，互不干扰。

**事三：把故障恢复变成局部问题**

某个 Consumer 挂了，Coordinator 触发 Rebalance，**把它的 Partition 重新分配给同 Group 内的其他 Consumer**。其他 Group 完全不知道发生了什么。

### Group 也有代价：Rebalance

但 Group 抽象的“成员动态加入 / 退出 → 触发重新分配”——这就是 Rebalance。在生产上它是 Kafka 最大的疼点之一：分配方案是“整组重分配”（Eager 协议下）还是“增量调整”（Cooperative），决定了一次扩容 / 上线是“消费暂停几秒”还是“消费暂停几十秒”。

10 会专挖这个题。

## 这 6 个抽象互相约束的几个例子

要看出它们是齿轮，看几个交叉点：

**例 1：想加消费并发，必须先加 Partition**
Consumer Group 内一 Partition 一 Consumer 的规则 → 消费并发上限被 Partition 数锁死。

**例 2：想要顺序，必须按 key 进同一个 Partition**
Kafka 只保证分区内有序 → 顺序需求要在 Producer 端把同一逻辑实体路由到同一 Partition。

**例 3：想要不丢，必须 Replica + ISR + acks=all 联动**
单 Replica = 单点，多 Replica 不限定 ISR = 可能选到落后副本，限定了不调 `acks` = Producer 不等就 ack。三个不联动等于没用。

**例 4：想删老数据，必须靠 Segment 切片**
Partition 是逻辑上无限日志，物理删除靠 Segment 整段回收。所以保留策略其实是“多少时间 / 多少字节会触发 Segment 删除”。

**例 5：Offset 状态外置，让 broker 可以水平扩，但代价是 Consumer 端要做幂等**
Consumer 提交 offset 和处理消息不是原子的——崩在中间会重复消费。这就是为什么 Kafka 默认是 at-least-once，业务幂等永远是必修课。

## 这一篇要带走的结论

- **Topic 是逻辑分组**：broker 上不存在 Topic 实体，只有 Partition 目录
- **Partition 是 Kafka 最重要的抽象**：同时是并发单元、顺序单元、副本单元
- **Replica 把 Partition 做成可靠的**：Leader 服务读写，Follower 只复制；ISR 是“跟上进度的副本集合”
- **Segment 让 Partition 可落地**：按段切，配套 `.index` / `.timeindex`，删除 / 压缩 / 检索都按段
- **Offset 有双重身份**：broker 写入时分配的“行号” + Consumer 自己维护的“读到哪了”；状态外置在 `__consumer_offsets`
- **Consumer Group 是消费状态的逻辑读者**：用一套机制统一了点对点和发布订阅；代价是 Rebalance
- 这 6 个抽象互相咬合：去掉任何一个，Kafka 的吞吐 / 顺序 / 可靠 / 可重放至少要塌掉一块

---

下一篇 `03_一条消息的端到端旅程：从send到commit的所有生死关.md`，会沿着这 6 个抽象，把“一条消息从 Producer.send() 到 Consumer.commit()”全程展开——每一段会出现什么问题、Kafka 用哪个抽象在挡。看完这一篇，后面 04 / 05 讲存储和副本时会非常顺。
