# Kafka 是什么、解决什么问题、心智模型与边界

## 这一篇要回答什么

学 Kafka 第一步，最容易犯的错就是把它当成“另一种 RabbitMQ”，然后照着 MQ 的思维去用——这是后续一切坑的源头：

- 把 Topic 当队列，期望消息一被消费就消失
- 期望 broker 帮你做“投递确认 / 重试 / 死信”这些 RabbitMQ 风格的事
- 期望同一条消息只有一个消费者消费，结果加了第二个 Consumer Group 才发现“怎么两边都收到了”
- 期望严格全局有序，结果 Topic 一拆分区就乱了
- 期望像 RabbitMQ 那样几千上万的 queue 满天飞，结果几万个 Partition 直接把 broker 干趴

这一篇不解释 Kafka 的命令、不画架构图细节，而是先回答一个更底层的问题：

> Kafka 在心智模型上到底是什么、它不是什么、它和别的消息中间件本质区别在哪。

把这一篇吃透，后面所有的概念——Partition、Replica、Offset、ISR、Rebalance、事务消息——会像挂在主干上的枝叶，而不是一堆散点。

## Kafka 出生时要解决的问题

Kafka 不是凭空发明的。2010 年前后，LinkedIn 内部碰到一个非常具体的工程问题——**数据集成的 N×M 噩梦**：

- N 个数据源：业务库、用户行为埋点、日志、监控、搜索索引、推荐系统的特征流……
- M 个下游：数据仓库、Hadoop 离线、搜索引擎、监控告警、A/B 实验、机器学习训练……

每多一个上游或下游，工程师就要再拉一根专线。当时已有的方案各有死穴：

| 方案 | 死穴 |
|---|---|
| 传统 MQ（ActiveMQ / RabbitMQ） | 设计上偏“消息中继”，消息消费完即删；不能给多个下游用同一份数据；吞吐撑不住日志级别的数据量 |
| 数据库 / 日志文件直接共享 | 紧耦合，下游一多上游就被压垮；故障恢复极痛 |
| 直接 RPC | 上下游必须同时在线；消费速度不一致时上游会被拖垮 |
| Scribe / Flume 这类日志收集 | 偏单向、批量、面向 HDFS；不能给在线系统用 |

LinkedIn 想要的东西其实非常具体：

1. **吞吐要够大**——日志级别的数据量，单机几十万 QPS 起步
2. **多消费者**——同一份数据要能同时喂给离线、搜索、推荐、监控
3. **解耦上下游进度**——下游消费速度差异巨大（实时秒级 vs 离线小时级），上游不应该被慢下游拖死
4. **可重放**——下游计算逻辑改了、出 bug 了，应该能从历史数据重跑
5. **可持久**——不能因为下游一时离线就把数据丢了

把这五条放在一起看，会发现传统的“消息队列”心智模型完全错配。**真正能同时满足这五条的，是一个东西：一个分布式、可持久、可重放的“日志”。**

Kafka 的原始论文（Jay Kreps 等，2011）和后来那篇神文《The Log: What every software engineer should know about real-time data's unifying abstraction》，反复强调的就是一句话：

> Kafka 不是消息队列，Kafka 是一个 **distributed commit log**（分布式提交日志）。

## 心智模型一：Kafka 是“分布式日志”，不是“队列”

这一节是整个 Kafka 学习里最关键的一次思维切换。

### 队列模型 vs 日志模型

传统 MQ 的心智模型是“队列”：

```
producer ──► [ msg1, msg2, msg3 ] ──► consumer
                  ▲
                  └── 消费完即删除
```

- 消息是“在途品”，状态由 broker 持有
- broker 要记录每条消息的投递状态（已投递 / 已确认 / 重试中 / 死信）
- broker 要主动 push，要管重试、超时、ack
- 消费完就没了，第二个消费者再想要这条消息？对不起，没了

Kafka 的心智模型是“日志”：

```
                       offset:  0    1    2    3    4    5  ...
Topic-Partition  ─►  [ m0 , m1 , m2 , m3 , m4 , m5 , ...  ]
                       ▲                        ▲
                       │                        │
                Consumer A 在 offset=2     Consumer B 在 offset=5
```

- 消息是“已落地的事实”，是一个 append-only 的字节序列
- broker 不记录“谁消费到哪了”，**Offset 是消费者自己的事**（提交到 `__consumer_offsets` 这个 topic 里）
- broker 不 push，是 consumer 来 **pull**
- 消息默认按时间 / 大小过期，**不会因为“被消费过”就删除**
- 想让 N 个下游各自独立消费这份数据？开 N 个 Consumer Group，各自维护各自的 offset 就行

这一个切换带来的所有连锁反应，是 Kafka 整套设计的根：

| 队列模型推论 | 日志模型推论 |
|---|---|
| broker 要管消息状态机（很重） | broker 只 append、只读取，几乎是哑存储（很轻） |
| 多消费者意味着复制消息 | 多消费者意味着多个 offset，物理只有一份 |
| 重放历史很难（消息已删） | 重放历史是天然能力，改 offset 就行 |
| broker push，慢消费者会被压 | consumer pull，慢消费者只是 offset 落后 |
| 单 broker 状态机难水平扩展 | broker 几乎无状态，扩 broker = 扩日志，天然水平 |
| 投递语义由 broker 担保 | 投递语义由 producer + consumer 协作担保 |

**Kafka 看起来像 MQ，但底层是一个被设计成日志的存储系统。** 后面所有的副本、ISR、Leader Epoch、事务，本质都是“怎么把这份分布式日志做得可靠、可重复、可串行”。

### 一个反直觉的事实：Offset 不在 broker

很多人没意识到这一点：

- 在 RabbitMQ 里，broker 知道“这条消息被谁消费了”
- 在 Kafka 里，broker **不知道**

broker 只知道这个 Partition 当前有多少条消息（HW / LEO）。至于 Consumer Group A 读到了 offset=200、Group B 读到了 offset=500，这个状态保存在另一个 topic 里，叫 `__consumer_offsets`，由 Consumer 自己提交。

这种“**状态外置**”的设计就是 broker 能做到几乎无状态、能水平扩展、能跑 PB 级日志的原因。

## 心智模型二：Partition 是“最小并发单元”，不是“分库分表”

第二个常见误解：把 Partition 类比成“分库分表里的分片”。

形式上像，但用途完全不同。

**Partition 在 Kafka 里同时承担三件事**：

1. **并发单元**：一个 Partition 只能被一个 Consumer Group 里的一个 Consumer 同时消费。想加并发？加 Partition。
2. **顺序单元**：Kafka 只保证 **分区内有序**，不保证 Topic 全局有序。需要顺序的消息要走同一个 Partition（同 key 路由）。
3. **副本单元**：副本机制是 Partition 级别的，不是 Topic 级别的。每个 Partition 有自己的 Leader 和 Follower 副本组。

这就推出了 Kafka 一个非常重要的工程权衡：

> Partition 数 = 并发上限。但 Partition 太多 → 元数据膨胀、副本同步压力大、Controller 切换变慢、Rebalance 变长。

RabbitMQ 用户喜欢“每个业务一个 queue”的习惯搬到 Kafka 上，就会出现“一个集群上万个 Topic、几十万个 Partition”，最后 Controller 切换一次 10 分钟、Rebalance 卡住整个业务线——这是 Kafka 选型上最常见的翻车点之一。

## 心智模型三：Consumer Group 是“一份日志的不同读者”

第三个关键认知：

> 在 Kafka 里，**消费者本身不重要，重要的是 Consumer Group**。

一个 Consumer Group 是逻辑上的“一份消费状态”。规则非常对称：

- 同一个 Group 内：一个 Partition 只会分给一个 Consumer（保证不重复消费）
- 不同 Group 之间：**互相完全独立**，各自从同一份日志里读，各自记各自的 offset

这就把“点对点队列”和“发布订阅 Topic”这两种 MQ 经典模型，用同一套机制统一了：

- 想要“点对点”？所有 Consumer 用同一个 Group ID
- 想要“发布订阅”？每个下游用自己的 Group ID

不需要两套抽象。RabbitMQ 那一堆 Exchange / Queue / Binding / Routing Key 的概念，在 Kafka 里被压缩成了 **Topic + Partition + Group**。

## Kafka 不是什么

知道它不是什么，比知道它是什么更能避免踩坑。

**Kafka 不是低延迟 RPC**。
端到端延迟在毫秒到几十毫秒，靠的是批量 + 顺序写 + PageCache。要 P99 < 1ms 的同步请求/响应，不要找 Kafka。

**Kafka 不是任务队列**。
它没有“任务被哪个 worker 拿到、执行失败要不要回到队头、要不要 N 次后扔死信”的概念。这些是 RabbitMQ / SQS / RocketMQ 的强项。Kafka 能做，但要业务自己实现，且很容易做错。

**Kafka 的 Topic 不是数据库表**。
不要拿“一个业务一个 Topic”的思路去建几万个 Topic。Topic 是数据流，不是数据实体。粒度应该按“数据流的语义”划分，而不是按“业务模块”。

**Kafka 的 Exactly-Once 不是“分布式系统里的精确一次”**。
它指的是非常具体的一段——“Producer 写到 broker”这一段、以及“consume → process → produce”这种 Kafka 内闭环。一旦你 sink 到外部系统（MySQL、Redis、HTTP API），EOS 就需要在业务层用幂等键自己补——这一篇 08 / 11 / 12 会反复讲。

**Kafka 不是延迟队列**。
原生没有“5 分钟后投递”的语义。要实现要么自己分级 Topic + 定时调度，要么用 RocketMQ 的延迟级别，要么走外部调度系统。

**Kafka 不擅长“几万个小 Topic”**。
它擅长“几十几百个大流量 Topic”。这是它的存储模型和元数据模型决定的，不是“调一调参数能解决”。

## 和其他 MQ 的本质边界

放在一起对比，能看清 Kafka 的定位：

### Kafka vs RabbitMQ

不是同一个物种。

- RabbitMQ 是“**消息路由器**”：核心能力在 Exchange / Routing Key / Binding 这套灵活的路由模型，以及完善的投递确认、TTL、死信、优先级、延迟队列。适合**业务系统间复杂的消息路由**。
- Kafka 是“**分布式日志**”：核心能力在大吞吐、可重放、多消费者并行。适合**数据流 / 事件流 / 日志总线**。

如果你的需求是“订单系统通知 10 种下游做 10 件不同的事，每件事失败要重试要兜底”，RabbitMQ 更顺手。
如果你的需求是“用户行为数据要同时喂给实时风控、离线数仓、个性化推荐、监控告警”，Kafka 更顺手。

### Kafka vs RocketMQ

像，但侧重点不同。RocketMQ 借鉴了 Kafka 的存储模型，但补上了 Kafka 偏弱的“业务消息能力”：

- 原生支持**延迟消息**（18 个等级）
- 原生支持**事务消息**（半消息 + 回查）
- 原生支持**消息过滤**（按 tag、SQL92）
- 顺序消息的语义更明确（顺序消费组）

代价是：

- 单分区吞吐通常不如 Kafka
- 生态偏 Java、阿里系，国外用得少
- 存储模型是 CommitLog + ConsumeQueue，和 Kafka 的 Segment 模型不一样，运维心智不同

经验法则：**纯业务消息选 RocketMQ 顺手，纯数据流选 Kafka，混合场景看团队栈**。

### Kafka vs Pulsar

Pulsar 是后来者，最大的设计差异是**计算与存储分离**：

- Kafka：broker 既负责接收消息，又负责存储消息（log segment 在自己磁盘上）
- Pulsar：broker 只负责服务，存储下沉给 BookKeeper

这带来 Pulsar 的几个优势：

- broker 扩容不需要搬数据（broker 是无状态的）
- 多租户、命名空间隔离做得更细
- 原生支持 Topic 数量极多（几十万）的场景
- 队列模式（Shared / Key_Shared / Failover）比 Kafka 灵活

代价是：

- 两层架构运维更复杂（broker + bookie + ZK/Etcd）
- 生态没 Kafka 厚（连接器、流计算、监控、培训资源）
- 同等硬件下吞吐和延迟优势没那么悬殊

**Pulsar 的优势在“几万到几十万 Topic”、“多租户大型平台”、“需要队列语义又要日志语义”的场景**。如果团队已经在 Kafka 上跑得稳，没必要为了 Pulsar 的架构美感迁过去。

### Kafka vs Redis Stream / NSQ / NATS

这些是“轻量消息系统”。能用、但都不在 Kafka 这一档：

- Redis Stream：单机内存，几十 GB 就是天花板，副本能力弱
- NSQ：无持久化保证，定位是轻量任务分发
- NATS（不带 JetStream）：发完即忘的实时通信总线；NATS JetStream 有持久化但生态比 Kafka 薄

选型上，**只要你认真做日志总线 / 数据流 / 跨系统数据集成，几乎没有 Kafka 之外的选项**——这正是 Kafka 在数据基础设施层成为事实标准的原因。

## 一个统一的判断法

每次有人问“XX 场景该不该用 Kafka”，可以用三个问题判断：

1. **数据量是不是日志级的**（每秒万级以上、或者总量 TB / PB 级）？
2. **是不是有多个下游各自独立消费同一份数据**？
3. **是不是需要可重放**（出问题能回放历史、新下游能从头消费）？

三个都“是”——Kafka。
只有第一个“是”——可能 RocketMQ 也行。
三个都“不是”——很可能你不需要 MQ，需要的是 RPC、定时任务、或者 RabbitMQ。

## 这一篇要带走的结论

- Kafka 出生是为了解决 LinkedIn 的“数据集成 N×M 噩梦”，不是为了做更好的 RabbitMQ
- 心智模型必须从“队列”切换成“分布式日志”——broker 几乎无状态，offset 由消费者持有，消息按时间过期而不是按消费过期
- Partition 同时承担并发、顺序、副本三件事，不是“分库分表”
- Consumer Group 用同一套机制统一了点对点和发布订阅
- Kafka 不是任务队列、不是低延迟 RPC、不是延迟队列、不是“几万小 Topic”系统
- 选型上：业务消息复杂路由 → RabbitMQ；业务消息 + 事务/延迟 → RocketMQ；超大规模多租户 → Pulsar；数据流 / 日志总线 / 流计算入口 → Kafka

---

下一篇 `02_核心抽象：Topic_Partition_Replica_Segment_Offset_ConsumerGroup.md`，会从这张心智模型出发，把 Kafka 的 6 个核心抽象一个一个拆开，重点回答“为什么必须是这 6 个、少一个会怎样、它们之间是怎么互相约束的”。
