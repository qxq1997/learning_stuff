# 线上排障专题：ISR 抖动 / Controller 切换 / Rebalance 风暴 / 磁盘打满

前面 14 篇把 Kafka 的机制基本铺完了。

这一篇换一个视角：**线上真的报警了，你该怎么排？**

Kafka 线上问题最麻烦的地方，不是某个指标看不懂，而是它经常会串起来：

```text
磁盘抖
  -> Follower fetch 慢
  -> ISR shrink
  -> acks=all 等待变长
  -> Producer timeout / retry
  -> broker 请求队列更满
  -> Consumer fetch 也慢
  -> lag 暴涨
  -> Consumer 超过 max.poll.interval.ms
  -> Rebalance 风暴
```

如果只盯着最后一个现象，比如 “consumer lag 高”，很容易做错动作。

## 这一篇要回答什么

这篇要把前面的机制串成生产排障手册：

1. Kafka 报警后，前 10 分钟先看什么？
2. ISR 抖动怎么判断是 follower 慢，还是 leader 端处理不过来？
3. Controller 切换慢为什么会放大成全局抖动？
4. Rebalance 风暴怎么区分是 consumer 自己的问题，还是 coordinator / broker 的问题？
5. 磁盘打满以后为什么不是删文件那么简单？
6. Producer timeout、NotLeaderForPartition、NotEnoughReplicas、Consumer lag 分别指向哪条链路？
7. 哪些动作是止血，哪些动作是根治，哪些动作很危险？

先给结论：

> Kafka 排障不要从“调哪个参数”开始，而要从“哪条链路正在变慢”开始。Producer 写慢，先拆成客户端发送、broker 网络线程、请求队列、Log append、ISR 等待、response 写回；Consumer lag 高，先拆成生产流量、分区分布、Consumer 处理、Rebalance、Fetch 延迟、Broker 资源；ISR 抖动，先同时看 follower 本机和 leader 端处理 follower fetch 的能力；Controller 抖动，先看 metadata 传播和控制类请求是否被拖慢；磁盘打满，先保住 broker 活着和数据安全，再处理 retention、扩容、迁移。

## 第一原则：先止血，再定位，再治理

线上事故里最容易犯的错误是：一上来就做永久性变更。

比如：

- lag 高就疯狂扩 Consumer。
- Producer timeout 就把 `request.timeout.ms` 调很大。
- ISR 抖动就把 `replica.lag.time.max.ms` 调大。
- 写入失败就把 `min.insync.replicas` 调低。
- 分区不可用就打开 `unclean.leader.election.enable`。
- 磁盘满了就手动删除 Kafka log 文件。

这些动作有些能短期缓解，有些会直接制造更大的事故。

更稳的顺序是：

```text
1. 先确认影响面
   哪些 topic / partition / consumer group / broker 受影响？

2. 先止血
   限流、降级、暂停非核心任务、隔离 catch-up consumer、停止扩容/重分配。

3. 再定位
   按 Producer / Broker / Replica / Controller / Consumer / Storage 分层排查。

4. 再恢复
   追 lag、恢复 ISR、均衡 leader、处理磁盘、重启或迁移。

5. 最后治理
   容量规划、告警、压测、Topic 设计、发布策略、参数收敛。
```

## 前 10 分钟检查清单

Kafka 报警后，先不要钻进细节。先回答 10 个问题：

1. **影响对象**：是单个 Topic / Group，还是整个集群？
2. **影响方向**：是 Producer 写不进，Consumer 读不出，还是两边都慢？
3. **时间点**：是否刚发布、扩容、缩容、重分配、Broker 重启、Topic 扩分区？
4. **错误类型**：是 timeout、NotLeader、NotEnoughReplicas、Coordinator unavailable，还是磁盘错误？
5. **lag 形态**：所有 Partition 都涨，还是少数 Partition 涨？
6. **ISR 状态**：UnderReplicatedPartitions 是否上升，ISR shrink / expand 是否频繁？
7. **Controller 状态**：Active Controller 是否切换，OfflinePartitions 是否出现？
8. **Broker 资源**：磁盘、网络、CPU、GC、请求队列、线程空闲率是否异常？
9. **Consumer 状态**：是否 Rebalance 风暴、心跳超时、poll 超时、下游慢？
10. **存储空间**：磁盘使用率是否逼近 85%、90%、95% 或已经打满？

用一句话概括：

> 先确定是“单点业务慢”，还是“集群基础设施抖”。

## 先看四个视角

### 客户端视角

Producer 常见信号：

| 信号 | 常见含义 |
| --- | --- |
| `TimeoutException` | 请求在客户端超时，可能是 broker 慢、ISR 等待、网络慢、请求排队 |
| `NotLeaderForPartition` | 客户端 metadata 旧了，或 Controller / broker 元数据传播慢 |
| `NotEnoughReplicas` | ISR 数量不足，且 `min.insync.replicas` 不满足 |
| `RecordTooLargeException` | 单条或 batch 超过 broker/topic/client 限制 |
| `BufferExhaustedException` | Producer 本地 buffer 被打满，broker ack 太慢或发送太快 |

Consumer 常见信号：

| 信号 | 常见含义 |
| --- | --- |
| lag 持续上涨 | 消费速度小于生产速度 |
| `CommitFailedException` | Rebalance 后旧成员再提交 offset |
| `max.poll.interval.ms exceeded` | 单批处理太慢，consumer 被踢出 group |
| `session timeout` | 心跳断了，常见于 GC、CPU 卡、网络抖 |
| `CoordinatorNotAvailable` | Group Coordinator 所在 broker 或 `__consumer_offsets` 异常 |

### Broker 视角

Broker 侧优先看：

- Produce / Fetch 请求延迟。
- RequestQueue 大小。
- RequestHandlerAvgIdlePercent。
- NetworkProcessorAvgIdlePercent。
- UnderReplicatedPartitions。
- IsrShrinksPerSec / IsrExpandsPerSec。
- OfflinePartitionsCount。
- ActiveControllerCount。
- LeaderCount / PartitionCount。
- BytesIn / BytesOut。
- 磁盘使用率、磁盘 await、磁盘吞吐。
- JVM GC pause、堆使用、直接内存。

这些指标要一起看。单看一个指标，很容易误判。

### 副本视角

副本相关问题要看：

- 哪些 Partition 变成 under-replicated。
- ISR 是缩到只剩 leader，还是少数 follower 掉队。
- 掉队 follower 是否集中在某一台 broker。
- leader 是否集中在某一台 broker。
- 是否正在做 partition reassignment。
- 是否有 broker 刚重启，PageCache 变冷。
- follower fetch 请求在 leader 端是否排队。

第 14 篇讲过一个关键点：

> Follower 复制也是 Fetch 请求。Leader 端请求队列或 I/O 线程忙，也会让 follower 看起来“跟不上”。

### 存储视角

存储相关问题看：

- 磁盘是否打满。
- log.dirs 是否有某块盘 offline。
- retention 是否设置过大。
- 是否有 compacted topic 清理跟不上。
- 是否有大量 catch-up consumer 读冷数据。
- 是否重启后 PageCache 变冷。
- 是否 Segment 数、Partition 数过多。
- 是否磁盘实际吞吐已经打满。

## 事故一：ISR 抖动

ISR 抖动指的是 Partition 的 ISR 集合频繁缩小、扩大：

```text
ISR = {1,2,3}
  -> {1,2}
  -> {1,2,3}
  -> {1,2}
```

线上表现通常是：

- UnderReplicatedPartitions 上升。
- IsrShrinksPerSec / IsrExpandsPerSec 上升。
- Producer `acks=all` 延迟变高。
- `NotEnoughReplicas` 或 `NotEnoughReplicasAfterAppend` 增多。
- Consumer lag 也可能跟着涨。
- broker 日志出现 follower 落后、ISR 变更。

### ISR 抖动为什么危险

Kafka 的可靠性很大程度依赖：

```text
replication.factor = 3
min.insync.replicas = 2
acks = all
```

如果 ISR 从 3 缩到 2，系统还能写。

如果 ISR 从 2 缩到 1，并且 `min.insync.replicas=2`，Producer 写入会失败。

如果你把 `min.insync.replicas` 调成 1，写入能恢复，但可靠性退化：

```text
ISR 只剩 leader
acks=all 等于只等 leader
leader 再挂
已 ack 数据可能丢
```

所以 ISR 抖动不是一个“看起来不太舒服”的指标，而是写入可靠性正在变薄。

### ISR 抖动的根因图

```text
Follower 跟不上 Leader
        │
        ├─ Follower 自己慢
        │    ├─ 磁盘写慢
        │    ├─ 网络慢
        │    ├─ GC / CPU 抖
        │    ├─ PageCache 冷
        │    └─ replica fetcher 不够
        │
        ├─ Leader 端处理 follower fetch 慢
        │    ├─ RequestQueue 堆积
        │    ├─ RequestHandler 忙
        │    ├─ NetworkProcessor 忙
        │    ├─ Leader 分布不均
        │    └─ 客户端普通请求把 broker 打满
        │
        └─ 集群正在变更
             ├─ broker 重启
             ├─ partition reassignment
             ├─ leader election
             └─ Controller 抖动
```

### 怎么判断是 follower 慢

如果 ISR 掉队副本集中在某一台 broker：

```text
p0 ISR: {1,2,3} -> {1,2}
p1 ISR: {1,2,3} -> {1,2}
p2 ISR: {1,2,3} -> {1,2}
```

broker 3 经常被踢出 ISR，就优先怀疑 broker 3：

- 磁盘 await 是否升高。
- 磁盘是否接近满。
- 网络入 / 出是否打满。
- JVM GC 是否长暂停。
- CPU 是否被打满或容器 throttling。
- 是否刚重启导致 PageCache 冷。
- 是否分配了过多 follower replica。
- 是否有坏盘、慢盘、log.dir offline。

处理动作：

- 暂停会增加复制压力的 reassignment。
- 降低非核心写入流量。
- 限速 catch-up consumer。
- 如果是单盘慢，迁移该盘上的 replica。
- 如果是 broker 资源不足，迁移 leader / replica 或扩 broker。
- 如果是 GC，调堆、减少对象压力、排查大请求。

### 怎么判断是 leader 端慢

如果掉队 follower 分散，但 leader 集中在某些 broker：

```text
很多 under-replicated partition 的 leader 都在 broker 1
```

就不要只查 follower。要看 broker 1：

- Produce / Fetch 请求延迟是否高。
- RequestQueue 是否堆积。
- RequestHandlerAvgIdlePercent 是否长期接近 0。
- NetworkProcessorAvgIdlePercent 是否低。
- BytesIn / BytesOut 是否打满。
- LeaderCount 是否明显高于其他 broker。
- 是否有热点 Topic 的 leader 都在它上面。

处理动作：

- 做 preferred leader election 或 leader rebalance。
- 对热点 Producer 限流。
- 增加 broker，迁移热点 partition。
- 调整 `num.network.threads` / `num.io.threads` 前先确认不是磁盘瓶颈。
- 隔离大流量 Topic。

### `replica.lag.time.max.ms` 要不要调

一般不要把它当成第一解。

这个参数表示 follower 多久没跟上 leader 就会被踢出 ISR。默认值通常已经不短。

调大能让 ISR “看起来稳定”，但代价是：

```text
一个实际已经很慢的 follower
更久留在 ISR
acks=all 要更久等它
写入延迟可能更高
故障时选主风险更复杂
```

调小则会让短暂抖动更容易触发 ISR shrink。

所以正确顺序是：

1. 先找 follower / leader / 磁盘 / 网络 / GC 根因。
2. 再评估这个参数是否和业务延迟、容错目标匹配。
3. 不要用它掩盖资源问题。

## 事故二：Controller 切换和元数据传播慢

Controller 是 Kafka 集群元数据的大脑。

它负责：

- broker 上下线感知。
- partition leader 选举。
- ISR 变化处理。
- Topic 创建、删除、扩分区。
- 下发 LeaderAndIsr / UpdateMetadata / StopReplica。

Controller 抖动时，数据流量不一定立刻全断，但元数据会变慢。

典型链路：

```text
broker A 挂了
  -> Controller 选新 leader
  -> 向 broker 下发 LeaderAndIsr / UpdateMetadata
  -> broker 更新本地 metadata cache
  -> client 刷新 metadata
  -> Producer / Consumer 找到新 leader
```

这条链路任何一段慢，客户端就会看到：

- `NotLeaderForPartition`。
- `LeaderNotAvailable`。
- `UnknownTopicOrPartition`。
- Metadata 请求变慢。
- Producer 重试增多。
- Consumer fetch 失败重试。
- Partition 短暂 unavailable。

### Controller 切换慢的两种时代

ZK 时代：

- Controller 挂了以后，新 Controller 要从 ZK 全量加载元数据。
- Partition 很多时，加载和 watch 重建会很慢。
- ISR 变化、Leader 切换都要写 ZK，ZK 单写者成为瓶颈。
- 大集群可能出现分钟级抖动。

KRaft 时代：

- Controller 是 Raft quorum。
- standby controller 已经有 metadata log。
- 切换通常快很多。
- 但如果 Controller 和 Broker 混部署，数据流量仍可能影响 Controller。
- Partition 太多仍会带来 broker 端应用 metadata、副本同步、PageCache 抢占等问题。

所以 KRaft 解决的是元数据瓶颈，不是所有数据面瓶颈。

### Controller 问题怎么排

先看：

- ActiveControllerCount 是否始终只有一个。
- Controller 是否频繁切换。
- OfflinePartitionsCount 是否大于 0。
- Leader election 是否密集。
- Controller 日志是否有超时、连接断开、事件队列堆积。
- Broker 日志是否大量 `NotLeaderForPartition` / metadata 更新。
- Metadata 请求延迟是否升高。
- 是否刚做 Topic 扩分区、删除、重分配、Broker 滚动重启。

再看影响面：

| 现象 | 更可能的方向 |
| --- | --- |
| 单 Topic leader 切换慢 | 该 Topic 副本、broker、partition 分布问题 |
| 大量 Topic 同时 NotLeader | Controller / metadata 传播问题 |
| OfflinePartitions 出现 | 可能没有可用 ISR 选 leader |
| Producer 重试增多但最终成功 | metadata 刷新窗口或短暂 leader 切换 |
| 长时间不可写 | ISR 不足、Controller 卡住、broker 大面积异常 |

### Controller 抖动怎么止血

短期动作：

- 暂停 Topic 创建、扩分区、删除等元数据变更。
- 暂停 partition reassignment。
- 暂停非必要 broker 滚动重启。
- 对非核心 Producer 限流。
- 先恢复 OfflinePartitions。
- 如果是 ZK 集群，检查 ZK 健康和网络。
- 如果是 KRaft 集群，检查 Controller quorum 健康。

长期治理：

- 控制 Topic / Partition 总量。
- 大集群使用专职 Controller 节点。
- 避免 Controller 和大流量 Broker 抢资源。
- 规划 ZK 到 KRaft 的迁移。
- 对大规模元数据变更做节流。

## 事故三：Rebalance 风暴

Rebalance 风暴指 Consumer Group 反复进入 Rebalance，消费无法稳定推进：

```text
PreparingRebalance
  -> JoinGroup
  -> SyncGroup
  -> Stable
  -> 又 PreparingRebalance
```

线上表现：

- lag 锯齿状上升。
- Consumer 日志反复出现 JoinGroup / SyncGroup / revoke / assign。
- `CommitFailedException` 增多。
- `max.poll.interval.ms exceeded`。
- `session timeout`。
- `Coordinator unavailable`。
- 某些实例频繁重启或被踢出 group。

### 先区分两类 Rebalance

第一类：**业务 Consumer 自己不稳定**。

常见原因：

- 单批处理太久，超过 `max.poll.interval.ms`。
- GC pause 太长，心跳断。
- CPU 被打满或容器限流。
- 下游 DB / RPC 慢，处理线程阻塞。
- 实例频繁发布、扩缩容、重启。
- `max.poll.records` 太大。
- revoke 回调里做了重操作。

第二类：**Coordinator 或 Broker 不稳定**。

常见原因：

- `__consumer_offsets` 所在 broker 慢。
- Group Coordinator 切换。
- `__consumer_offsets` ISR 抖动。
- broker 请求队列堆积。
- Controller / metadata 抖动导致 FindCoordinator 失败。
- 网络抖动导致心跳请求延迟。

区别很关键：

> 如果是 Consumer 自己处理慢，扩容可能有用；如果是 Coordinator 慢，盲目扩容会让 JoinGroup / SyncGroup 更多，风暴更大。

### 怎么定位 Rebalance 风暴

按这个顺序：

1. 找到哪个 `group.id` 在 Rebalance。
2. 看影响哪些 Topic / Partition。
3. 看 Consumer 日志里的原因：session timeout、max poll exceeded、coordinator unavailable。
4. 看是否刚发布、扩容、缩容、Topic 扩分区。
5. 看单批处理耗时和 `poll()` 间隔。
6. 看 GC、CPU、容器重启、OOM。
7. 看下游 DB / RPC 延迟。
8. 看 `__consumer_offsets` 的 leader 在哪台 broker。
9. 看该 broker 请求延迟、磁盘、网络、ISR。
10. 看分配策略是否还是 Eager。

### Rebalance 风暴怎么止血

如果是处理太慢：

- 降低 `max.poll.records`。
- 增大 `max.poll.interval.ms`，但要匹配真实处理上限。
- 把耗时处理移到异步线程池，但要控制 offset 提交。
- 优化下游调用，增加超时、熔断、批量写。
- 对坏消息进入 DLQ，不要无限重试卡住 poll。

如果是心跳超时：

- 查 GC pause。
- 查 CPU throttling。
- 查网络抖动。
- 合理设置 `session.timeout.ms` 和 `heartbeat.interval.ms`。
- 避免业务线程阻塞心跳线程。

如果是发布造成：

- 降低滚动发布并发。
- 使用优雅关闭，先 commit offset，再 leave group。
- 使用 Static Membership：`group.instance.id`。
- 使用 CooperativeSticky 分配策略。

如果是 Coordinator 慢：

- 先处理 `__consumer_offsets` 所在 broker 的资源问题。
- 检查 `__consumer_offsets` ISR。
- 避免大量 group 同时重启。
- 分批恢复 Consumer。
- 必要时迁移 `__consumer_offsets` partition leader。

## 事故四：磁盘打满

磁盘打满是 Kafka 很危险的一类事故。

Kafka 的数据最终都落在 `log.dirs` 下。磁盘满后，可能出现：

- Producer 写入失败。
- Log append 变慢或报错。
- Broker 标记 log.dir offline。
- Partition leader 迁移或不可用。
- ISR 大面积 shrink。
- Controller 处理 leader 变化。
- Consumer lag 暴涨。
- Broker 进程异常退出。

### 为什么不能手动删 log 文件

不要直接去 `log.dirs` 下删除 `.log` / `.index` / `.timeindex` 文件。

原因是：

- Kafka 的 LogManager 还持有这些 Segment 的元数据。
- offset、index、segment 边界会被破坏。
- 副本同步可能出现不可预期截断。
- broker 重启恢复时可能读到不一致状态。
- 删除错 active segment 可能直接造成数据损坏。

磁盘满了，优先用 Kafka 自己的 retention / delete / reassignment 机制处理。

### 磁盘为什么会满

常见原因：

| 原因 | 说明 |
| --- | --- |
| retention 配太长 | `retention.ms` / `retention.bytes` 太大 |
| 生产流量超预期 | 写入量超过容量规划 |
| compacted topic 清理慢 | log cleaner 跟不上 |
| 副本迁移造成双写 | reassignment 期间新旧副本同时占空间 |
| Topic 数 / Partition 数过多 | 每个 partition 都有 segment 和索引 |
| 消息过大 | 单条大消息拉高磁盘和网络压力 |
| 删除策略误解 | 以为消费后 Kafka 会自动删除，实际上按 retention 删除 |
| broker leader / replica 分布不均 | 某些 broker 扛了太多数据 |

### 磁盘打满怎么止血

先分情况。

#### 还没满，已经超过 85% / 90%

这是最舒服的窗口：

- 立刻停止非必要大流量 Producer。
- 暂停 partition reassignment。
- 检查哪些 Topic 占空间最大。
- 对低价值 Topic 临时调小 `retention.ms` 或 `retention.bytes`。
- 增加 broker 或磁盘。
- 迁移热点 / 大 Topic 的 replica。
- 检查 compacted topic 的 log cleaner 是否落后。

#### 已经接近 100%，broker 还活着

动作要更保守：

- 先限制写入，避免继续打满。
- 优先调小低价值 Topic retention，让 Kafka 自己删除旧 Segment。
- 如果能扩容，尽快加盘或加 broker。
- 暂停会复制大量数据的任务，避免雪上加霜。
- 关注 broker 是否能完成 delete cleanup。
- 不要反复重启 broker，重启会丢 PageCache，也可能让恢复更慢。

#### broker 已经因磁盘满异常

先保数据安全：

- 确认该 broker 上 partition 是否还有其他 ISR 副本。
- 确认 OfflinePartitions。
- 确认 `min.insync.replicas` 下写入是否还能继续。
- 清理空间时优先用可确认无价值的数据和 Kafka 管理动作。
- 恢复 broker 后观察副本 catch-up，不要马上放开全部流量。

### Retention 调小为什么不会立刻生效

Kafka 删除日志是按 Segment 处理的，不是按单条消息处理。

如果 active segment 还没滚动，或者旧 segment 还没满足删除条件，空间不会马上释放。

常见误解：

```text
把 retention.ms 从 7 天改成 1 小时
  -> 期待磁盘立刻下降
  -> 发现没立刻释放
```

原因可能是：

- Segment 还没滚动。
- delete cleanup 还没执行。
- 文件被进程持有，空间释放延迟。
- compacted topic 受 compaction 策略影响。
- 副本迁移仍在复制数据。

所以磁盘水位已经 99% 时，靠调 retention 可能来不及。

## 事故五：Producer timeout

Producer timeout 不等于 broker 一定挂了。

它可能发生在很多位置：

```text
Producer 本地 buffer
  -> sender 线程发送
  -> broker network thread
  -> request queue
  -> request handler
  -> log append
  -> acks=all 等 ISR
  -> response queue
  -> 网络返回
```

常见根因：

| 根因 | 伴随信号 |
| --- | --- |
| broker 请求队列堆积 | RequestQueue 增大，RequestHandler idle 低 |
| 网络线程忙 | NetworkProcessor idle 低，连接多，SSL CPU 高 |
| 磁盘慢 | Log append 延迟高，磁盘 await 高 |
| ISR 等待慢 | UnderReplicatedPartitions、IsrShrink、acks=all 延迟 |
| Producer 流量太大 | bufferpool wait、batch 堆积、retry 上升 |
| metadata 旧 | NotLeaderForPartition、metadata refresh 增多 |

短期止血：

- 对非核心 Producer 限流。
- 增大 `delivery.timeout.ms` 只能减少误报，不能解决 broker 慢。
- 检查 `retries`、`retry.backoff.ms` 是否合理。
- 不要为了恢复写入轻易降低 `acks` 或 `min.insync.replicas`。
- 如果是热点 Topic，考虑拆流量、扩 Partition、迁移 leader。

## 事故六：Consumer lag 暴涨

第 13 篇已经单独讲过积压，这里把它放进线上排障路径里。

lag 暴涨时先看形态：

```text
所有 partition lag 都涨
  -> 整体消费能力不足 / broker fetch 慢 / 下游慢 / 生产突增

少数 partition lag 涨
  -> key 倾斜 / 热点 partition / 坏消息 / 单分区处理慢

lag 锯齿状涨
  -> Rebalance / 发布 / GC / 批处理周期性卡顿

lag 高但消费速率也高
  -> 历史积压在追，重点看预计追平时间
```

不要只看 lag 数字，要看：

- 生产速率。
- 消费速率。
- records-lag-max。
- 单批处理耗时。
- 下游延迟。
- Rebalance 次数。
- Fetch 请求延迟。
- Broker 磁盘 / 网络。
- 是否有 catch-up consumer 读冷数据。

止血动作：

- 对上游限流或削峰。
- 扩 Consumer 到 Partition 数上限。
- 降低单条处理耗时，使用批量写。
- 对坏消息进入 DLQ。
- 暂停非核心 Group。
- 隔离 catch-up consumer。
- 必要时用临时高分区 Topic 重分发历史积压。

## 事故七：大量 NotLeaderForPartition

`NotLeaderForPartition` 的意思是：客户端把请求发到了它以为的 leader，但 broker 说自己不是 leader。

这通常不是业务代码 bug，而是 metadata 变化后的短暂窗口。

常见根因：

- broker 挂了，Partition leader 切换。
- Controller 切换或处理慢。
- broker metadata 更新慢。
- client metadata 缓存旧。
- partition reassignment。
- preferred leader election。
- 网络抖动导致客户端连到旧 broker。

排查顺序：

1. 看是否同一时间有 leader election。
2. 看 Controller 日志。
3. 看 OfflinePartitions。
4. 看 Metadata 请求延迟。
5. 看客户端 metadata refresh。
6. 看是否刚做运维变更。

如果只是短暂出现并被重试覆盖，通常是正常恢复窗口。

如果持续出现，就要查 Controller / broker metadata 传播是否卡住。

## 一张总排障图

```text
Kafka 报警
  │
  ├─ Producer 写失败 / timeout
  │    ├─ metadata 错？ -> NotLeader / Controller / Leader 切换
  │    ├─ ISR 不足？ -> UnderReplicated / min.insync
  │    ├─ broker 慢？ -> RequestQueue / I/O / Network / 磁盘
  │    └─ client 堵？ -> buffer / batch / retry / 流量
  │
  ├─ Consumer lag 暴涨
  │    ├─ 所有分区？ -> 总消费能力 / broker fetch / 下游慢
  │    ├─ 少数分区？ -> key 倾斜 / 坏消息 / 热点
  │    ├─ 锯齿状？ -> Rebalance / GC / 发布
  │    └─ 冷读？ -> PageCache miss / 磁盘读满
  │
  ├─ ISR 抖动
  │    ├─ 掉队集中某 broker？ -> follower 慢
  │    ├─ leader 集中某 broker？ -> leader 端处理慢
  │    └─ 变更期？ -> reassignment / 重启 / Controller
  │
  ├─ Controller 抖动
  │    ├─ ZK 时代？ -> ZK / watch / 全量元数据
  │    ├─ KRaft？ -> quorum / controller 资源
  │    └─ metadata 大？ -> Topic / Partition 总量
  │
  └─ 磁盘打满
       ├─ retention 太长？
       ├─ 流量超规划？
       ├─ compact 清理慢？
       ├─ reassignment 占双份？
       └─ leader/replica 分布不均？
```

## 关键指标分组

### 集群健康

| 指标 | 关注点 |
| --- | --- |
| OfflinePartitionsCount | 大于 0 就要优先处理 |
| UnderReplicatedPartitions | 副本同步是否跟不上 |
| ActiveControllerCount | 正常应只有一个 active controller |
| LeaderElectionRateAndTimeMs | leader 是否频繁切换 |
| IsrShrinksPerSec / IsrExpandsPerSec | ISR 是否抖动 |

### 请求链路

| 指标 | 关注点 |
| --- | --- |
| TotalTimeMs | 端到端请求耗时 |
| RequestQueueTimeMs | 请求在队列里等多久 |
| LocalTimeMs | broker 本地处理多久 |
| RemoteTimeMs | 等 follower / remote 条件多久 |
| ResponseQueueTimeMs | response 排队多久 |
| ResponseSendTimeMs | response 写回多久 |

### 线程和队列

| 指标 | 关注点 |
| --- | --- |
| RequestHandlerAvgIdlePercent | I/O 处理线程是否空闲 |
| NetworkProcessorAvgIdlePercent | 网络线程是否空闲 |
| RequestQueueSize | 请求是否堆积 |
| ResponseQueueSize | 响应是否堆积 |

### Consumer

| 指标 | 关注点 |
| --- | --- |
| records-lag-max | 单分区最大 lag |
| records-consumed-rate | 消费速率 |
| fetch-latency-avg/max | fetch 是否慢 |
| rebalance-rate-per-hour | Rebalance 是否频繁 |
| poll 间隔 / 处理耗时 | 是否会超过 max.poll |

### 机器资源

| 指标 | 关注点 |
| --- | --- |
| disk used | 磁盘是否接近打满 |
| disk await / util | 磁盘是否已经慢 |
| network in/out | 网卡是否打满 |
| CPU / load | CPU 是否成为瓶颈 |
| GC pause | 是否造成心跳、复制抖动 |
| PageCache / cached | 热读是否还能命中内存 |

## 常见危险动作

### 危险动作一：打开 unclean leader election

`unclean.leader.election.enable=true` 可以在 ISR 全挂时从非 ISR 副本选 leader。

这可能恢复可用性，但代价是：

> 允许丢已 ack 数据。

除非业务明确接受数据回滚，否则不要把它当成常规止血动作。

### 危险动作二：降低 min.insync.replicas

把 `min.insync.replicas` 从 2 改成 1，写入可能马上恢复。

但这意味着：

```text
ISR 只剩 leader 时也能写成功
acks=all 退化成只等 leader
```

这属于牺牲可靠性换可用性。必须有业务确认。

### 危险动作三：手动删除 log 文件

不要这么做。

磁盘满时优先：

- 限流。
- 调 retention。
- 扩容。
- 迁移。
- 停止非核心写入。

直接删 Kafka 数据目录里的文件，是把“容量事故”升级成“数据一致性事故”。

### 危险动作四：盲目扩 Consumer

扩 Consumer 只在这些情况下有效：

- Partition 数足够。
- 根因是消费处理能力不足。
- 下游也扛得住。
- Rebalance 能稳定完成。

如果根因是下游慢、Coordinator 慢、Broker fetch 慢，扩容可能更糟。

### 危险动作五：频繁重启 broker

Broker 重启会带来：

- Partition leader 切换。
- PageCache 变冷。
- Follower 追数据。
- ISR 抖动。
- Controller 元数据变更。

如果集群已经不稳，连续重启可能把局部问题放大全局。

## 一个完整排障例子：lag 暴涨 + ISR 抖动

现象：

```text
Consumer lag 从 100 万涨到 5000 万
Producer timeout 增多
UnderReplicatedPartitions 上升
```

不要直接扩 Consumer。先看：

1. lag 是所有 Partition 涨，还是少数 Partition 涨。
2. Producer 流量是否突增。
3. UnderReplicated 是否集中在某个 broker。
4. 该 broker 磁盘 / 网络 / GC 是否异常。
5. leader 是否集中在某个 broker。
6. RequestQueueTimeMs 是否升高。
7. RemoteTimeMs 是否升高。

可能链路一：

```text
broker 3 磁盘慢
  -> broker 3 作为 follower 跟不上
  -> ISR shrink
  -> acks=all 等待变长
  -> Producer retry 增多
  -> broker 压力更大
  -> Consumer fetch 变慢
  -> lag 暴涨
```

处理：

- 限制 Producer 峰值。
- 暂停 reassignment。
- 迁移 broker 3 上的 replica。
- 修复磁盘或下线 broker。
- 恢复后观察 ISR expand。
- 再考虑追 lag。

可能链路二：

```text
catch-up consumer 从很旧 offset 读
  -> 冷数据读磁盘
  -> 磁盘读打满
  -> 正常 Consumer fetch 变慢
  -> follower fetch 也慢
  -> ISR 抖动
```

处理：

- 给 catch-up consumer 限速。
- 暂停非核心历史回放。
- 使用独立集群或 follower read。
- 业务高峰不要做大规模重放。

## 一个完整排障例子：发布后 Rebalance 风暴

现象：

```text
服务滚动发布
  -> Consumer lag 锯齿上升
  -> 日志反复 JoinGroup / SyncGroup
  -> CommitFailedException 增多
```

排查：

1. 发布并发是否过高。
2. 是否优雅关闭。
3. 是否使用 static membership。
4. 分配策略是否 CooperativeSticky。
5. 单批处理是否超过 `max.poll.interval.ms`。
6. revoke 回调是否执行太慢。
7. `__consumer_offsets` 所在 broker 是否异常。

处理：

- 降低发布并发。
- 先 stop 拉取、处理完当前批、提交 offset、再 close。
- 配置 `group.instance.id`。
- 使用 CooperativeSticky。
- 减小 `max.poll.records`。
- 把重操作移出 rebalance 回调。

## 一个完整排障例子：磁盘快满

现象：

```text
broker 5 disk used = 92%
其他 broker 只有 60%
```

排查：

1. broker 5 是否 leader / replica 过多。
2. 哪些 Topic 占空间最大。
3. retention 是否异常。
4. 是否有 reassignment 中间态。
5. 是否 compacted topic 清理慢。
6. 是否有大消息 Topic。

处理：

- 对低价值 Topic 缩短 retention。
- 迁移 broker 5 上的大 replica。
- 做 leader / replica 均衡。
- 增加磁盘或 broker。
- 对大消息业务做治理。
- 加磁盘水位分级告警。

## 面试怎么回答

如果被问“Kafka 线上 ISR 抖动、Controller 切换、Rebalance 风暴、磁盘打满怎么排”，可以这样答：

> 我会先判断影响面：是单 Topic / Group，还是整个集群；是 Producer 写慢、Consumer lag，还是 broker 基础设施异常。Kafka 问题经常是链式传导，所以不会一上来调参数。Producer timeout 会拆成客户端 buffer、broker 网络线程、请求队列、Log append、ISR 等待、response 写回；Consumer lag 会拆成生产流量、分区分布、Consumer 处理、下游依赖、Rebalance、Broker fetch 和磁盘网络。
>
> ISR 抖动时，我会先看 UnderReplicatedPartitions、ISR shrink / expand，再判断掉队副本是否集中在某台 broker。如果集中，优先查 follower broker 的磁盘、网络、GC、PageCache、replica fetcher；如果 leader 集中在某台 broker，就查 leader 端请求队列、RequestHandler、NetworkProcessor、Leader 分布和热点流量。不要简单把 `replica.lag.time.max.ms` 调大，也不要轻易降低 `min.insync.replicas`。
>
> Controller 抖动要看 ActiveController、OfflinePartitions、Leader election、metadata 请求延迟和 Controller 日志。ZK 时代还要看 ZK 和 watch / 全量元数据加载，KRaft 时代看 Controller quorum 和是否专职部署。Rebalance 风暴要区分 Consumer 自己处理慢、GC、发布造成，还是 `__consumer_offsets` / Coordinator broker 异常。磁盘打满要先限流和调 retention / 扩容 / 迁移，不能手动删 Kafka log 文件。

这个回答的关键是：**你不是背几个指标，而是在还原故障传播链路。**

## 这一篇要带走的结论

- Kafka 线上排障要先看影响面，再分 Producer、Broker、Replica、Controller、Consumer、Storage 层定位。
- ISR 抖动要同时看 follower 本机和 leader 端 follower fetch 处理能力。
- Controller 抖动会放大 metadata 传播延迟，表现为 NotLeader、leader 切换慢、partition 不可用。
- Rebalance 风暴要区分 Consumer 自身不稳定和 Coordinator / broker 不稳定。
- 磁盘打满优先限流、retention、扩容、迁移，不能手动删除 Kafka log 文件。
- Producer timeout、Consumer lag、ISR shrink 经常是同一条资源瓶颈链路的不同表现。
- 高危动作包括打开 unclean leader election、降低 min.insync、盲目扩 Consumer、频繁重启 broker。

---

下一篇 `16_性能调优：硬件_OS_Broker_Producer_Consumer五层调优.md`，会从事故处理进入主动优化：硬件怎么选、OS 怎么配、Broker 参数怎么调、Producer / Consumer 怎么把吞吐和延迟调到目标区间。
