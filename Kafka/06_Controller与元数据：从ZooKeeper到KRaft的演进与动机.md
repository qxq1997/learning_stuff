# Controller 与元数据：从 ZooKeeper 到 KRaft 的演进与动机

## 这一篇要回答什么

前面我们一直在讲“**单个 Partition 内部**”怎么写、怎么复制、怎么选主。这一篇视角拉远——

> 集群里有几千个 Partition、几十个 broker，**“谁是谁的 Leader、谁在 ISR 里、Topic 是什么配置”这一堆元数据，是怎么在集群里管理、怎么变更、怎么传播的？**

具体要回答 6 个问题：

1. Kafka 的“元数据”到底包含什么？
2. **Controller** 是什么角色，它在做哪几件事？
3. ZK 时代的 Controller 是怎么干活的，**它的具体痛点是什么**——不要含糊地说“ZK 慢”
4. KRaft 是什么？它**用什么方式**解决了 ZK 时代的痛点？
5. KRaft 之后的 Controller 切换、元数据传播、Partition 上限发生了什么变化？
6. 演进时间线、迁移路径、生产部署上的选择

讲清楚这一章，你会理解为什么一个看似纯架构的“去 ZK”动作，在 Kafka 这个量级的系统里是必须的，而不是为了赶时髦。

## 起点：什么是“集群元数据”

“元数据”这个词太抽象。具体到 Kafka，它指**集群里所有 broker 必须达成一致**的那些信息：

- **集群拓扑**：有哪些 broker、各自的 host:port、机架信息、是不是 Controller
- **Topic 列表**：集群里有哪些 Topic、各自的 Partition 数、副本因子、配置（保留、压缩、cleanup.policy 等）
- **每个 Partition 的状态**：
  - **AR**（Assigned Replicas）：被分配到哪些 broker
  - **Leader**：当前 Leader 是哪个 broker
  - **ISR**：当前同步副本集合
  - **Leader Epoch**：当前任期号
- **ACL**：权限规则
- **配额**：Producer / Consumer 配额
- **Reassignment / Ongoing changes**：正在进行的副本重分布

这些元数据有个共同特征：**变更不频繁，但每次变更都要让所有 broker 立刻知道**——尤其是“Leader 切了”这种变更，相关 broker 必须在毫秒级感知，否则消息发到的不是新 Leader 就要错。

> 元数据管理本质上就是“分布式系统的注册中心 + 配置中心 + 选主协调器”三合一。

## Controller 这个角色

Controller 是**集群里一个被选出来的特殊 broker**——任意时刻只有一个 Active Controller，其它 broker 都是普通 broker（也是 Controller 的候选）。

Active Controller 干的事：

1. **管理 broker 上下线**：感知 broker 加入 / 退出 / 假死
2. **管理 Partition 状态机**：副本分配、Leader 选主、ISR 维护
3. **执行集群级变更**：建 / 删 Topic、改配置、副本重分布
4. **下发元数据变更通知**：让所有 broker 同步到一致视图
5. **处理副本切换**：发 LeaderAndIsr / StopReplica / UpdateMetadata 这些控制类 RPC

> **Controller 是集群的“大脑”**。它本身不处理 Produce / Fetch 这些数据流量，但它一旦抖动，数据流量就会跟着抖。

后面会看到，ZK 时代和 KRaft 时代的 Controller 在“**它怎么知道集群状态、怎么把状态告诉别人**”这两件事上完全不同。

## ZK 时代：Controller 怎么干活

Kafka 从一开始（2010）就用 ZooKeeper 当“真理之源”。架构是这样：

```
                ┌──────────────┐
                │ ZooKeeper    │ ←─ 元数据的真理之源（持久化）
                │  /controller │
                │  /brokers/.. │
                │  /topics/..  │
                │  /isr_change_notification │
                └──────┬───────┘
                       │ watch
              ┌────────┴────────┐
              │                 │
       ┌──────▼──────┐   ┌──────▼──────┐
       │ Broker 1    │   │ Broker 2    │ ...
       │ (Controller)│   │             │
       └──────┬──────┘   └──────▲──────┘
              │  LeaderAndIsr/  │
              │  UpdateMetadata │
              └─────────────────┘
                     RPC 下发
```

### 选 Controller 的方式

ZK 有个 `/controller` 临时节点（EPHEMERAL）。所有 broker 启动时抢着写它，**写成功的那个就是 Controller**。如果它挂了，ZK 自动删除这个临时节点，其它 broker 被 watch 通知到，再抢一次。

### 元数据怎么走

- **真理之源在 ZK**：`/topics/<t>/partitions/<p>/state` 这种节点存着每个 Partition 的 Leader/ISR
- **Controller 维护内存副本**：启动时把 ZK 上的元数据全部拉一遍进自己内存
- **变更走 Controller 写 ZK**：ISR 变化、Leader 切换、Topic 增删，统一由 Controller 写 ZK，**单写者**保证一致性
- **变更通知给 broker**：Controller 用 RPC（LeaderAndIsr / UpdateMetadata / StopReplica）告诉各 broker “你现在是这些 Partition 的 Leader / Follower”
- **broker 上的元数据缓存**：每个 broker 也维护一份自己关心的元数据缓存，用于响应 Producer / Consumer 的 Metadata 请求

### ISR 变更的链路

一个看似简单的“follower 跟不上、被踢出 ISR”动作，背后链路是：

```
Leader 发现 follower lag > replica.lag.time.max.ms
        │
        ▼
Leader 把新 ISR 写到 ZK (/topics/.../state)
        │
        ▼
Controller watch 到 ZK 节点变化
        │
        ▼
Controller 计算下游影响
        │
        ▼
Controller RPC 通知相关 broker（UpdateMetadata）
        │
        ▼
各 broker 更新自己的元数据缓存
```

这条链路在小集群没什么问题。但在大集群上每一段都是潜在瓶颈。

## ZK 时代的具体痛点

“ZK 慢”是模糊的说法。准确的痛点有这么几个，每一个都是 KRaft 要解决的：

### 痛点 1：Controller 启动慢

Controller 切换或新建时，要**从 ZK 把所有元数据拉一遍**到自己内存。在几万 Partition 的集群上：

- ZK 上 `/topics/<t>/partitions/<p>/state` 每个 Partition 一个节点
- Controller 启动要遍历几万节点 → ZK 读 RT × 几万 → **分钟级**

这就是“**集群越大 Controller 切换越慢**”的根。生产上看到“Controller 切换十几分钟集群整体抖动”，根因就在这里。

### 痛点 2：Watch 风暴

ZK 的 watch 是**一次性、不可靠**的：

- 一次性：触发一次就失效，要继续监听必须重新 watch
- 不可靠：在断连重连之间发生的变更会丢

Controller 切换 / 网络抖动后，要把所有 watch 重新注册一遍 → **几万 Partition 几万 watch** → ZK 压力暴涨。

而且 ZK 上 broker 临时节点抖一下，整个集群可能要重算 Controller、重读元数据、重发 LeaderAndIsr——一个抖动放大成集群级风暴。

### 痛点 3：元数据传播链路长且分裂

一个 ISR 变更：

```
Leader → ZK → Controller → RPC → 各 broker
```

四段。每一段都可能慢、可能丢、可能时序错位。最常见的现象是：

- broker A 已经知道 Partition X 的 Leader 是 broker C
- broker B 还在以为是 broker D
- Producer 拿到 broker B 的 Metadata 响应，把消息发到 D
- D 已经不是 Leader → 报 `NotLeaderForPartition` → Producer 重新 fetch metadata
- 整个过程产生几秒 ~ 几十秒的“消息发不进去”窗口

这就是为什么 Kafka 的 Producer / Consumer 客户端有 `metadata.max.age.ms`、有 NotLeaderForPartition 重试等等——本质都是在补元数据传播延迟和分裂。

### 痛点 4：ZK 单写者瓶颈

ZK 本身写吞吐有限（典型几千 QPS）。Controller 是唯一往 ZK 写的角色，所有 ISR 变更、Leader 切换都要排队。

集群一大、Partition 一多、ISR 抖一抖，**Controller 写 ZK 排队几秒钟很正常**。期间 ISR 状态在 ZK 上落后于实际，对 acks=all 的一致性承诺就有微妙影响。

### 痛点 5：运维双系统

Kafka 集群 + ZK 集群 = 两套分布式系统要维护：

- 两套版本要兼容
- 两套监控告警
- ZK 调参（特别是 JVM、session 超时）是个独立技能点
- ZK 故障会让整个 Kafka 不可写——但 ZK 自己也是分布式系统，也会挂

很多公司 Kafka 出故障，根因在 ZK——但定位往往要绕一大圈。

### 痛点 6：Partition 上限

把上面 5 个痛点叠加，**ZK 时代 Kafka 集群的 Partition 数上限大致是几万**。社区内部测试和大厂经验是：

- 几万 Partition：正常工作但 Controller 切换变慢
- **十几万 Partition**：Controller 切换分钟级，元数据传播延迟暴涨
- 几十万 Partition：基本不能玩

这个上限不是单一参数能调出来的，是 ZK + Controller + 元数据传播这一整套机制的天花板。

## KRaft：用 Raft 替掉 ZK

KRaft 全称 **Kafka Raft Metadata mode**。核心思想很直接：

> **元数据不再放 ZK，而是放在 Kafka 自己里——一个特殊的 Kafka topic：`__cluster_metadata`，用 Raft 协议复制。**

### 架构图

```
            ┌──────────────────────────────────────┐
            │   Controller Quorum (3 or 5 nodes)   │
            │  ┌─────────┐ ┌─────────┐ ┌─────────┐ │
            │  │ Active  │ │Follower │ │Follower │ │ ← Raft 复制
            │  │Controller│ │ (standby)│ │ (standby)│ │
            │  └─────────┘ └─────────┘ └─────────┘ │
            │      │                                │
            │   维护一份 __cluster_metadata topic   │
            └──────┼───────────────────────────────┘
                   │ Brokers pull metadata
                   ▼
            ┌──────────────┐  ┌──────────────┐
            │  Broker 1    │  │  Broker 2    │  ...
            │ (普通 broker)│  │              │
            └──────────────┘  └──────────────┘
```

要点：

1. **Controller 变成 Quorum**：通常 3 个节点跑 Raft（生产 5 个也行），其中一个是 Active Controller，另两个是热备 Follower
2. **元数据是一个 Kafka topic**：所有变更（建 Topic、ISR 变化、Leader 切换、ACL 修改）作为消息**写到 `__cluster_metadata`**
3. **broker 通过订阅这个 topic** 来获取元数据更新——不再依赖 watch
4. **真理之源就是这个 topic 的 log**，Raft 协议保证它在 Quorum 内强一致

### 这套设计怎么挨个解决前面的痛点

| ZK 时代痛点 | KRaft 怎么解 |
|---|---|
| Controller 启动慢（要拉全量元数据） | Follower Controller **已经是热备**，元数据已经在它本地 log 里，切换是秒级 |
| Watch 风暴 | 不再用 watch，broker pull metadata topic 的 offset，本质就是消费 |
| 元数据传播链路长 | Leader 变更直接 append 到 `__cluster_metadata` → 所有 broker 在下次 pull 时拿到 |
| ZK 单写者瓶颈 | Active Controller 直接 append 到 Raft log，无外部依赖；Raft Quorum 内部高效 |
| 运维双系统 | 只剩 Kafka 一套 |
| Partition 上限 | 4.0 官方目标支持**百万级 Partition** |

### 几个关键设计细节

**Controller 怎么选**？标准 Raft：Quorum 内多数派投票，term 单调递增，Leader 持久化最新 log。这是工业界已经验证十几年的协议（etcd、CockroachDB、TiKV 都在用），比基于 ZK 临时节点的"抢锁式选主" 稳定得多。

**元数据怎么传给 broker**？每个 broker 启动时连 Active Controller，订阅 `__cluster_metadata`，从某个 offset 开始消费。变更来了就推进 offset、应用变更到本地缓存。这本质就是 Kafka 自己的消费模型——非常对称。

**Active Controller 怎么处理变更**？变更（比如 ISR 从 {1,2,3} 缩到 {1,2}）封装成一条 `MetadataRecord`，append 到 `__cluster_metadata`。Raft 复制到 Quorum 多数后视为 committed，再让 broker 拉到。整个流程**和普通 Kafka 写消息几乎一样**。

**Snapshot**：`__cluster_metadata` 不能无限长。Controller 定期生成 metadata snapshot（类似 Raft snapshot），broker 启动可以先加载 snapshot 再追 tail。

## 部署模式：Combined vs Dedicated

KRaft 集群有两种部署形态：

### Combined 模式

```
┌──────────────────────┐
│ Node 1               │
│  - Controller (Raft) │  ← 同一进程
│  - Broker            │
└──────────────────────┘
```

每个节点既是 Controller 又是 Broker。优点：节点数少、部署简单。缺点：Controller 和数据流量抢资源，**生产不推荐**。

### Dedicated 模式（生产推荐）

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│ Controller 1│  │ Controller 2│  │ Controller 3│  ← 专职 Controller Quorum
└─────────────┘  └─────────────┘  └─────────────┘

┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ...
│ Broker A    │  │ Broker B    │  │ Broker C    │  ← 专职 Broker
└─────────────┘  └─────────────┘  └─────────────┘
```

Controller 单独 3 节点，Broker 单独一组。Controller 节点资源需求很低（小 CPU、几 GB 内存），但要稳定。这是大集群标配。

## 演进时间线

简化的历史脚注（记不清完整年份没关系，记关键拐点）：

| 版本 | 年份 | 事件 |
|---|---|---|
| 0.x – 2.x | 2011–2019 | ZK 时代 |
| 2.8 | 2021 | KRaft 预览（不稳定）|
| 3.3 | 2022 | KRaft 在生产 GA |
| 3.5 | 2023 | 推荐新集群直接用 KRaft；ZK 进入弃用倒计时 |
| 3.7 | 2024 | ZK → KRaft 迁移工具成熟 |
| 4.0 | 2025 | **ZK 模式被移除**，KRaft 成为唯一形态 |

> 也就是说，**今天（2026 年视角）建新 Kafka 集群应该直接 KRaft，不要再上 ZK**。已有 ZK 集群也应该在 3.7+ 上规划迁移。

## 元数据传播是大集群的命脉

讲完 KRaft，回过头看 03 链路里我们略过的一个问题：

> Producer 怎么知道 Partition X 的 Leader 在哪个 broker？

答案是 **Metadata 请求**。Producer 启动时会向 `bootstrap.servers` 里任一 broker 发 Metadata 请求，broker 返回完整的 “这个集群有哪些 Topic、每个 Partition 的 Leader 在谁”。Producer 缓存这份元数据，在 `metadata.max.age.ms`（默认 5 分钟）后或者收到 `NotLeaderForPartition` 错误时刷新。

这也意味着：

- 大集群里元数据响应本身就很大（几万 Partition 的元数据可能几 MB）
- 元数据刷新太频繁会拖累 broker
- 元数据传播 + Producer/Consumer 元数据缓存的协同，才是“Leader 切了之后多久客户端能感知”这件事的真实链路

**KRaft 大幅缩短了这条链路里 Controller → broker 的那段**，但客户端 → broker 这一段仍然受 `metadata.max.age.ms` 和 Producer 重试策略影响——不是开了 KRaft 客户端就自动“立刻知道”。

## 生产高频问题与解法

**问：“Controller 切换很慢（几分钟），怎么治？”**
ZK 时代根因是元数据全量重拉。短期治标：减小 Partition 总数、限制 Topic 数。长期治本：迁移到 KRaft。

**问：“ZK 抖动会怎样？”**
ZK 写不进去 → Controller 不能记录 ISR 变更、不能选主、不能改配置。**数据流量短时还能继续**（broker 内存里的元数据还在），但任何故障切换都做不了。这是为什么 ZK 集群要单独保护（独立机器、独立监控、专业 SRE）。

**问：“KRaft 迁移路径怎么走？”**
3.5+ 提供了 ZK → KRaft 的 dual-write 迁移工具：

1. 启动一组 KRaft Controller 与 ZK 并存
2. 元数据从 ZK 同步到 KRaft
3. 切换 broker 的元数据源到 KRaft
4. 下线 ZK

实际操作里**第 1 步和第 3 步都要灰度**，并且要在低峰期做。社区有完整文档，大集群迁移建议先在测试环境跑一遍。

**问：“KRaft 模式下 Topic 数能开多少？”**
社区目标百万级 Partition、十万级 Topic。生产实践目前到几十万 Partition、万级 Topic 是稳定的。但要注意：**Partition 多带来的副本同步、磁盘 IO、PageCache 抢占问题仍然存在**——KRaft 解的是元数据瓶颈，不是数据瓶颈。

**问：“Combined 模式能不能用？”**
开发测试可以。生产环境**不要**——Controller 一旦因为业务流量被卡，整个集群元数据停滞，是把鸡蛋全放一个篮子。

**问：“KRaft 下还有 Controller 切换吗？”**
有，但**秒级**。Active Controller 挂了，Raft Follower 立刻发起新一轮投票，几百毫秒内选出新 Leader，元数据 log 在它本地已经是最新的，不需要重新拉。

**问：“Controller Quorum 为什么是 3 个不是 1 个？”**
1 个是单点。3 个是 Raft 的最小高可用 Quorum（容忍 1 个挂）。5 个容忍 2 个挂、写延迟略增。生产标配 3，超大集群可以 5。

**问：“现在还要不要学 ZK 时代的知识？”**
要。理由：①公司里仍有大量 ZK 集群没迁；②**“为什么去 ZK”** 这件事本身就是面试和系统设计的高频题；③KRaft 的设计动机不理解 ZK 痛点就讲不清。

## 这一篇要带走的结论

- **Controller 是集群大脑**：选主、ISR 维护、Topic 增删、元数据下发都靠它
- ZK 时代的痛点不是“ZK 慢”一句话，是 **Controller 启动慢 + Watch 风暴 + 元数据传播链长 + ZK 单写者 + 运维双系统 + Partition 上限** 六个具体痛点叠加
- **KRaft 把元数据搬进 Kafka 自己**，作为一个 Raft 复制的 internal topic（`__cluster_metadata`）；broker 像消费 topic 一样获取元数据
- KRaft 让 Controller 切换从分钟级到秒级、Partition 上限从几万到百万级
- 部署上 **Dedicated 模式是生产标配**，Combined 仅适合开发测试
- 4.0 开始 ZK 模式被移除，今天建新集群直接 KRaft；老集群在 3.5+ 后规划迁移
- 元数据传播是大集群的命脉，KRaft 缩短了 Controller→Broker 段，但 Broker→Client 段仍受 `metadata.max.age.ms` 制约

---

下一篇 `07_生产者深挖：分区、Batch、Compression、retries与乱序.md`，进入 03 链路里 ①~⑤ 那一段——把 Producer 端的所有“选择题”讲清楚：分区策略怎么选、Batch 怎么调、Compression 怎么权衡、retries 配多少才不丢、`max.in.flight` 为什么是把双刃剑。然后接着 08 专挖幂等和事务 Producer。
