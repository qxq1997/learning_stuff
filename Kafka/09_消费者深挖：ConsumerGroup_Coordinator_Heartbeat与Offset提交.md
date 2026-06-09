# 消费者深挖：Consumer Group / Coordinator / Heartbeat 与 Offset 提交

## 这一篇要回答什么

前面 07、08 讲的是 Producer 端：怎么分区、怎么批量、怎么幂等、怎么事务。现在视角切到 Consumer。

Kafka 线上很多“消息丢了 / 重复了 / 积压了 / 一直 Rebalance”的问题，根因都在消费端的几个动作没想清楚：

1. Consumer Group 到底是什么，为什么一个 Partition 同组内只能给一个 Consumer？
2. Group Coordinator 是怎么选出来的，它负责什么？
3. Consumer 加入组时 `JoinGroup` / `SyncGroup` 到底发生了什么？
4. Heartbeat、`session.timeout.ms`、`max.poll.interval.ms` 分别在检测什么？
5. `poll()` 只是拉消息吗，为什么业务处理太慢会触发 Rebalance？
6. Offset commit 的语义是什么，为什么提交的是“下一条要读的 offset”？
7. 自动提交、`commitSync`、`commitAsync` 各有什么坑？
8. 批量消费、多线程处理、坏消息、Rebalance 回调里 offset 应该怎么处理？

先给一句结论：

> Kafka Consumer 的核心不是“拿到消息就处理”，而是一个 **消费进度管理器**。它既要和 Coordinator 保持组成员关系，又要从 Partition Leader 拉数据，还要把“业务处理成功的位置”提交到 `__consumer_offsets`。丢和重复，几乎都发生在“业务处理”和“offset 提交”的缝隙里。

## Consumer Group：一份日志的一个读者

Kafka 的 Topic 是一份可重放日志。Consumer Group 是这份日志的一个“逻辑读者”。

同一个 Topic 可以有多个 Group：

```text
topic: order-events

group: risk-service       offset=12000
group: warehouse-loader   offset=8000
group: search-indexer     offset=11800
```

它们读的是同一份物理日志，但各自维护各自的 offset。一个 Group 落后，不影响另一个 Group。

### 同组内：分摊消费

同一个 Consumer Group 内，规则是：

> **一个 Partition 在同一时刻只能分配给这个 Group 里的一个 Consumer。**

例如：

```text
topic A: 6 partitions
group G: 3 consumers

C1 -> p0, p1
C2 -> p2, p3
C3 -> p4, p5
```

这样做有两个好处：

- 同一个 Partition 的 offset 只有一个写者，提交进度不会乱。
- Partition 内有序可以成立，因为同一时间只有一个 Consumer 处理它。

代价也非常直接：

> **同一个 Group 的消费并发上限 = Partition 数。**

6 个 Partition，最多 6 个 Consumer 真正有活干。你启动 20 个 Consumer，多出来的 14 个只会空闲。

### 不同组：发布订阅

不同 Group 之间互不影响：

```text
group risk-service       读 p0..p5
group warehouse-loader   也读 p0..p5
group search-indexer     也读 p0..p5
```

这就是 Kafka 用一套 Consumer Group 机制同时实现“点对点”和“发布订阅”的原因：

- 想让多个实例分摊一份任务：用同一个 Group。
- 想让多个下游各自收到全量消息：每个下游用自己的 Group。

## Group Coordinator 是谁

Consumer Group 不是凭空自己协商的。每个 Group 都有一个 **Group Coordinator**，它是某个 broker 上的角色。

Coordinator 负责：

- 管理组成员加入和退出。
- 触发 Rebalance。
- 接收 Heartbeat，判断成员是否还活着。
- 接收 offset commit，写入 `__consumer_offsets`。
- 保存 Group 的稳定状态。

Coordinator 怎么选？

> 按 `group.id` hash 到 `__consumer_offsets` 的某个 Partition，这个 Partition 的 Leader broker 就是这个 Group 的 Coordinator。

大致是：

```text
hash(group.id) % __consumer_offsets_partition_count = N
__consumer_offsets partition N 的 Leader broker = Group Coordinator
```

这带来两个工程结论：

1. `__consumer_offsets` 本身的健康非常重要。
   它不是普通内部 Topic，它承载了所有 Consumer Group 的位点和组元数据。

2. Coordinator 不是单点。
   broker 挂了，`__consumer_offsets` 对应 Partition 会选新 Leader，Group 会找到新的 Coordinator。

Consumer 启动时会先发 `FindCoordinator`，找到自己 Group 的 Coordinator，然后才加入组。

## 加入组：JoinGroup 和 SyncGroup

Consumer 用 `subscribe()` 订阅 Topic 后，会走 group management 流程。

典型流程：

```text
1. FindCoordinator
   找到 group.id 对应的 Coordinator

2. JoinGroup
   告诉 Coordinator：我要加入这个 Group，我订阅了哪些 Topic，我支持哪些分配策略

3. Coordinator 选 Group Leader
   注意：这是 Consumer 里的 leader，不是 broker leader

4. Group Leader 计算分区分配方案
   根据所有成员、所有订阅 Topic、partition.assignment.strategy 计算

5. SyncGroup
   Group Leader 把分配方案发给 Coordinator
   Coordinator 再下发给所有 Consumer

6. Consumer 收到自己的 assignment
   开始从对应 Partition 拉取消息
```

为什么分配方案是 Consumer 端算，而不是 Coordinator 自己算？

- Consumer 客户端可以支持多种分配策略。
- 协议可以演进，broker 不必理解每种客户端策略细节。
- Group Leader 拿到成员元数据后计算方案，再由 Coordinator 做广播。

常见分配策略包括：

| 策略 | 直觉 |
|---|---|
| RangeAssignor | 按 Topic 内 Partition 范围分给 Consumer，简单但多 Topic 时容易不均 |
| RoundRobinAssignor | 全部 Partition 打平轮询分配，更均匀 |
| StickyAssignor | 尽量保持上次分配，减少迁移 |
| CooperativeStickyAssignor | 增量协作式迁移，减少 Stop-The-World |

第 10 篇会专门讲 Rebalance，这里先记住：**分配策略决定一次成员变化时，多少 Partition 要被撤销和重新分配。**

## Heartbeat：Coordinator 怎么知道你还活着

Consumer 加入组后，会定期向 Coordinator 发 Heartbeat。

几个关键参数：

| 参数 | 作用 |
|---|---|
| `heartbeat.interval.ms` | 心跳发送间隔 |
| `session.timeout.ms` | Coordinator 多久没收到心跳，就认为 Consumer 死了 |
| `max.poll.interval.ms` | Consumer 两次 `poll()` 之间最多允许间隔多久 |

这三个参数经常被混淆。

### `session.timeout.ms`：检测进程 / 网络是否还活着

如果 Coordinator 在 `session.timeout.ms` 内没有收到某个 Consumer 的心跳，就认为它离组了，触发 Rebalance，把它的 Partition 分给别人。

常见原因：

- Consumer 进程挂了。
- JVM Full GC 太久，心跳发不出去。
- 网络断开。
- broker / Coordinator 短暂不可达。

`heartbeat.interval.ms` 一般设为 `session.timeout.ms` 的 1/3 左右，让 Coordinator 有几次容错机会。

### `max.poll.interval.ms`：检测业务线程是否卡住

现代 Java Consumer 有独立心跳线程，但这不代表业务可以永远不 `poll()`。

Kafka 还需要判断：

> 这个 Consumer 虽然心跳还活着，但它是不是已经卡在业务处理里，不再继续消费了？

这就是 `max.poll.interval.ms` 的作用。两次 `poll()` 间隔超过这个值，Consumer 会被认为“处理太慢 / 卡住”，Group 会触发 Rebalance。

典型场景：

```text
poll 拉到 500 条
业务逐条调用慢 RPC
处理 10 分钟还没回到下一次 poll
超过 max.poll.interval.ms
Coordinator 触发 Rebalance
```

解决方向：

- 降低 `max.poll.records`，减少单次处理量。
- 优化业务处理耗时。
- 把重任务拆到 worker 线程，但要自己管理 offset 提交。
- 合理调大 `max.poll.interval.ms`，让它覆盖最坏处理时间。

但不要无脑调很大。调太大意味着 Consumer 真卡住时，故障恢复也会变慢。

## poll() 到底做了什么

`poll()` 不是一个简单的“拉消息 API”。它是 Consumer 客户端的主循环入口。

一次 `poll()` 可能做这些事：

- 发送 / 接收网络请求。
- 加入组或完成 Rebalance。
- 执行分区分配回调。
- 向 Partition Leader 拉取数据。
- 返回本地缓存中的 records。
- 触发自动提交检查。
- 处理 commit 回调。
- 更新 Consumer 的 position。

这就是为什么 Kafka Consumer API 要求你持续调用 `poll()`。它不是只影响“有没有新消息”，还影响组成员协议和客户端内部状态推进。

典型消费循环：

```java
while (running) {
    ConsumerRecords<K, V> records = consumer.poll(Duration.ofMillis(100));

    for (ConsumerRecord<K, V> record : records) {
        process(record);
    }

    consumer.commitSync();
}
```

这段代码的语义是：

1. 拉一批。
2. 全部处理成功。
3. 提交这批之后的位置。

这是最基础的 at-least-once 写法。

## Fetch：从哪里拉、一次拉多少

Consumer 分配到 Partition 后，会向对应 Partition 的 Leader broker 发送 Fetch 请求。

Fetch 请求里最关键的是：

- topic
- partition
- 从哪个 offset 开始拉
- 最大拉多少字节
- 是否等到一定字节数再返回

相关参数：

| 参数 | 作用 |
|---|---|
| `fetch.min.bytes` | broker 至少攒到多少字节再返回，提升吞吐 |
| `fetch.max.wait.ms` | 最多等多久，即使没攒够也返回 |
| `fetch.max.bytes` | 单次 fetch 响应总大小上限 |
| `max.partition.fetch.bytes` | 单个 Partition 一次最多返回多少字节 |
| `max.poll.records` | 一次 `poll()` 最多返回多少条给应用 |

注意一个细节：

> `max.poll.records` 限制的是一次 `poll()` 交给应用多少条，不一定限制底层 fetch 已经拉到本地缓存多少条。

所以如果消息处理慢，Consumer 本地可能已经预取了一些数据，但 offset 只有在 commit 后才算持久推进。

## position、committed offset、log end offset

消费端至少要分清三个位置：

| 名字 | 含义 |
|---|---|
| position | Consumer 内存里“下一条准备返回给应用的 offset” |
| committed offset | 写到 `__consumer_offsets` 的“下次重启从哪读” |
| log end offset | Partition Leader 当前日志末尾 |

举例：

```text
Partition log: offset 0..999

Consumer 已经 poll 到 200
position = 201

Consumer 只提交到 150
committed offset = 150

Leader 最新写到 1000
log end offset = 1000
```

如果此时 Consumer 崩溃，重启后从 committed offset=150 读，而不是从 position=201 读。150~200 会重放。

这就是 Kafka at-least-once 的根：

> **position 是内存进度，committed offset 是故障恢复进度。**

## Offset commit 的精确语义

Kafka commit 的 offset 是：

> **下一条要消费的 offset，不是最后一条已消费的 offset。**

如果你处理完 offset 100，应该提交 101。

```java
consumer.commitSync(Map.of(
    tp,
    new OffsetAndMetadata(lastProcessedOffset + 1)
));
```

为什么这样设计？

- 重启时从 committed offset 开始读。
- 提交 101 表示 0..100 都已经处理完成。
- 这和 log end offset 的“下一条要写的位置”保持一致。

批量处理时最常见的错误是：

```text
处理完 100..199
提交 199
```

这样重启会从 199 再读，重复一条。正确提交 200。

## __consumer_offsets 里存什么

`__consumer_offsets` 是一个内部 compact topic。

Commit 的 key 大致是：

```text
(group.id, topic, partition)
```

value 是：

```text
committed offset
metadata
commit timestamp
expire timestamp
```

compact 的意思是：同一个 key 只需要保留最新值。一个 Group 对某个 Partition 提交了 100、200、300，最终保留 300 就够了。

这也解释了两个现象：

1. offset commit 本质也是写 Kafka。
   Coordinator 收到 commit 请求后，把它写到 `__consumer_offsets`。

2. commit 也可能失败。
   Coordinator 切换、网络抖动、Rebalance 进行中、权限问题，都可能导致 commit 异常。

## 自动提交：省事但危险

自动提交配置：

```properties
enable.auto.commit=true
auto.commit.interval.ms=5000
```

它的语义不是“业务处理成功后自动提交”，而是：

> Consumer 客户端按周期提交它认为已经消费到的位置。

在 Java Consumer 里，自动提交通常在 `poll()` 调用过程中检查是否到达提交周期，然后提交已经返回给应用的 offset。危险点在于：**这个提交和业务处理成功没有原子绑定。**

### 什么时候容易丢

如果你把消息交给异步线程池处理，然后主线程继续 `poll()`：

```text
poll 返回 100..199
把 100..199 扔进线程池
主线程继续 poll
自动提交 offset=200
线程池里 offset=150 还没处理完
进程崩溃
重启从 200 开始
150..199 里未完成的消息丢失
```

这种情况下自动提交非常危险。

### 什么时候看起来没那么危险

如果你是单线程严格：

```text
poll
同步处理完所有 records
下一次 poll
```

自动提交往往在下一次 `poll()` 时发生，实际风险小一些。但它仍然不能表达“某条消息业务处理失败、某条成功”的细粒度状态，也不好做异常兜底。

生产关键链路通常建议：

```properties
enable.auto.commit=false
```

然后处理成功后手动提交。

## commitSync：简单可靠，但会阻塞

`commitSync()` 会同步等待 commit 结果，失败会抛异常。

基础写法：

```java
while (running) {
    ConsumerRecords<K, V> records = consumer.poll(Duration.ofMillis(100));
    process(records);
    consumer.commitSync();
}
```

优点：

- 语义清楚。
- 失败可感知。
- 适合关键业务。

缺点：

- 每批都等 Coordinator 响应，吞吐较低。
- Coordinator 抖动时会拉高消费延迟。

一般关键链路宁可先用 `commitSync`，等确认瓶颈后再优化。

## commitAsync：吞吐好，但顺序和失败要小心

`commitAsync()` 不阻塞，提交结果通过 callback 返回。

```java
consumer.commitAsync((offsets, exception) -> {
    if (exception != null) {
        log.warn("commit failed: {}", offsets, exception);
    }
});
```

优点：

- 不阻塞消费主循环。
- 吞吐更好。

缺点：

1. 失败不会自动重试。
   如果盲目忽略，崩溃后会从旧 offset 重放更多数据。

2. 多个异步 commit 可能乱序完成。
   比如先提交 300，再提交 400；如果 400 成功、300 后成功，最终 committed offset 可能回退到 300，造成重复消费。

常见折中：

```text
正常循环中 commitAsync
关闭或 Rebalance 撤销分区时 commitSync
```

也就是吞吐和收尾可靠性兼顾。

## 处理失败时，offset 怎么办

批量消费最难的是：一批里部分成功、部分失败。

```text
poll 返回 100..199
100..149 成功
150 失败
151..199 未处理或已处理
```

你有几个选择。

### 选择一：不提交，整批重放

提交仍停在 100。重启或下一轮会从 100 开始。

优点：

- 不丢。
- 语义简单。

缺点：

- 100..149 会重复。
- 如果 150 是永久坏消息，会一直卡住。

前提：

- 业务必须幂等。
- 要有坏消息识别和 DLQ。

### 选择二：只提交到失败前

提交 150，表示 100..149 已完成，下次从 150 继续。

适合严格按 offset 顺序处理的场景。

```java
consumer.commitSync(Map.of(tp, new OffsetAndMetadata(150)));
```

### 选择三：跳过坏消息

把 offset=150 的原始消息、异常原因写入 DLQ，然后提交 151 或继续后续处理。

适合：

- 反序列化失败。
- schema 不兼容。
- 明确不可恢复的脏数据。
- 业务确认允许跳过。

但必须有：

- DLQ。
- 审计。
- 人工或自动补偿入口。

不要在没有记录的情况下直接跳 offset。

### 选择四：暂停该分区

如果某个 Partition 暂时依赖下游恢复，可以：

```java
consumer.pause(Set.of(tp));
```

继续消费其他 Partition，等下游恢复后：

```java
consumer.resume(Set.of(tp));
```

这能避免一个坏 Partition 拖住整个 Consumer，但 offset 提交仍要谨慎。

## 多线程消费的坑

KafkaConsumer 不是线程安全的。

最安全的模型是：

> 一个 Consumer 实例由一个线程调用 `poll()`。

如果业务处理很重，常见做法是：

```text
poll 线程只负责拉消息
按 partition 或 key 分发给 worker
worker 处理完成后上报 offset
poll 线程统一提交已连续完成的 offset
```

这里有两个大坑。

### 坑一：同一 Partition 并发处理会破坏顺序

如果 offset 100、101、102 同时丢给线程池：

```text
102 先写库成功
100 后失败
101 再成功
```

你既没法提交 103，也可能已经造成业务乱序。

如果需要 Partition 内顺序，就必须同 Partition 串行，或者按 key 串行。

### 坑二：不能提交“最大完成 offset”

假设：

```text
100 成功
101 处理中
102 成功
103 成功
```

你不能因为最大完成 offset 是 103，就提交 104。因为 101 还没成功。正确提交只能到 101。

提交规则是：

> **只能提交从上次 committed offset 开始，连续成功处理的下一位。**

多线程消费的 offset 管理，难点就在这里。

## Rebalance 时为什么要提交 offset

Consumer 失去 Partition 前，会触发回调：

```java
onPartitionsRevoked(Collection<TopicPartition> partitions)
```

这是你最后一次机会，在 Partition 被分给别人之前提交当前处理进度。

典型做法：

```java
consumer.subscribe(topics, new ConsumerRebalanceListener() {
    public void onPartitionsRevoked(Collection<TopicPartition> partitions) {
        commitCurrentOffsetsSync(partitions);
    }

    public void onPartitionsAssigned(Collection<TopicPartition> partitions) {
        initPartitionState(partitions);
    }
});
```

如果撤销前不提交：

- 新 Consumer 会从旧 committed offset 开始读。
- 已处理但未提交的消息会重放。

这通常不会丢，但会重复。业务幂等必须兜住。

第 10 篇会细讲 Eager / Cooperative 下 revoked / assigned 行为差异。这里先记住：

> **Rebalance 和 offset commit 是绑在一起考虑的。**

## seek 和 offset reset

Consumer 可以主动移动 position：

```java
consumer.seek(tp, 12345L);
consumer.seekToBeginning(partitions);
consumer.seekToEnd(partitions);
```

这常用于：

- 重放历史。
- 跳过坏消息。
- 按时间回放。
- 灾难恢复。
- 手工修复消费进度。

还有一个配置：

```properties
auto.offset.reset=earliest|latest|none
```

它只在两种情况下生效：

1. 这个 Group 对这个 Partition 没有 committed offset。
2. committed offset 已经无效，比如日志保留策略把它删掉了。

它不是“每次启动都从 earliest / latest 开始”。只要有 committed offset，就从 committed offset 继续。

## read_committed 对 Consumer 的影响

上一章讲事务 Producer 时说过，Consumer 可以配置：

```properties
isolation.level=read_committed
```

这样它只会读已提交事务消息，并跳过 aborted records。

代价是：

- 它最多只能读到 LSO，而不是 HW。
- 如果有长事务未完成，LSO 会卡住。
- 看起来像 consumer lag 增大，但其实是事务可见性卡住。

如果你没有消费事务 Producer 写出的 Topic，默认 `read_uncommitted` 就够了。

如果你在做 Kafka Streams / consume-process-produce EOS 闭环，下游 Consumer 要用 `read_committed`，否则可能读到事务中止的数据。

## 常见消费语义

### At-most-once：先提交，再处理

```text
poll records
commit offset
process records
```

崩在 commit 之后、process 之前，消息就丢了。

适合：

- 非关键日志。
- 允许丢的监控事件。
- 明确追求低延迟且可接受丢失。

### At-least-once：先处理，再提交

```text
poll records
process records
commit offset
```

崩在 process 之后、commit 之前，消息会重复。

这是最常见、最推荐的默认语义。前提是业务幂等。

### Exactly-once：Kafka 内部闭环

```text
poll input
process
send output with transaction
sendOffsetsToTransaction
commitTransaction
```

只覆盖 Kafka input 到 Kafka output。写外部系统仍然不算。

## 消费端可靠性配置

关键业务常见起点：

```properties
enable.auto.commit=false
isolation.level=read_committed
max.poll.records=100
max.poll.interval.ms=300000
session.timeout.ms=45000
heartbeat.interval.ms=15000
auto.offset.reset=none
```

说明：

- `enable.auto.commit=false`：处理成功后手动提交。
- `isolation.level=read_committed`：如果上游有事务 Producer，只读已提交。
- `max.poll.records`：控制单批处理时长。
- `max.poll.interval.ms`：覆盖最坏处理时长。
- `session.timeout.ms` / `heartbeat.interval.ms`：心跳故障检测。
- `auto.offset.reset=none`：关键业务不允许悄悄从 earliest / latest 开始，没 offset 就报错人工处理。

日志 / 埋点类链路可以更偏吞吐：

```properties
enable.auto.commit=true
auto.offset.reset=latest
fetch.min.bytes=1048576
fetch.max.wait.ms=500
max.poll.records=1000
```

但这个配置不适合关键业务。

## 消费端要监控什么

至少看这些：

| 指标 | 说明 |
|---|---|
| `records-consumed-rate` | 消费速率 |
| `records-lag-max` | 最大分区 lag |
| `fetch-latency-avg/max` | Fetch 延迟 |
| `fetch-rate` | Fetch 请求频率 |
| `bytes-consumed-rate` | 消费字节速率 |
| `commit-latency-avg/max` | offset commit 延迟 |
| `commit-rate` | commit 频率 |
| Rebalance 次数 | 组是否频繁重分配 |
| poll 间隔 | 是否接近 `max.poll.interval.ms` |
| 处理耗时 | 业务是否拖慢消费 |
| 错误率 / DLQ 速率 | 是否有坏消息 |

判断思路：

- lag 上升但消费速率正常：可能生产流量暴涨。
- lag 上升且消费速率下降：消费者或下游变慢。
- 少数 Partition lag 高：热点 key、坏消息、单分区慢。
- commit latency 高：Coordinator 或 `__consumer_offsets` 慢。
- Rebalance 次数高：心跳、GC、发布、`max.poll.interval.ms`、网络问题。

## 常见事故拆解

### 事故一：自动提交导致丢消息

现象：

- 日志显示 poll 到消息。
- 下游没有处理结果。
- 重启后 Kafka 不再投递这批消息。

常见原因：

- 开了自动提交。
- 主线程继续 poll，业务在线程池里还没处理完。
- offset 已经提交到未处理消息之后。

解决：

- 关闭自动提交。
- 处理成功后提交。
- 异步处理时只提交连续完成 offset。

### 事故二：处理成功但重复消费

现象：

- DB 已经写成功。
- Consumer 重启后同一消息又来一遍。

常见原因：

- 业务处理成功后，commit offset 前进程崩溃。
- Rebalance 撤销分区前没提交。
- `commitAsync` 失败被忽略。

解决：

- 消费端幂等。
- revoke 回调里同步提交。
- 关键链路使用 `commitSync` 或 async + close sync。

### 事故三：一直卡在同一个 offset

现象：

- lag 不下降。
- 日志反复报同一条消息错误。

常见原因：

- 反序列化失败。
- schema 不兼容。
- 脏数据导致业务异常。
- 失败后不提交 offset，下一轮继续读同一条。

解决：

- 不可恢复错误写 DLQ。
- 记录原 topic / partition / offset / key / exception。
- 业务确认后跳过该 offset。
- 修复后可从 DLQ 回放。

### 事故四：频繁 Rebalance

现象：

- Consumer 日志里大量 JoinGroup / SyncGroup。
- lag 锯齿状上升。
- 每次发布或 GC 后消费暂停。

常见原因：

- 单批处理时间超过 `max.poll.interval.ms`。
- GC 超过 `session.timeout.ms`。
- 网络抖动。
- 实例频繁上下线。
- 分配策略导致 Eager 全量撤销。

解决：

- 降低 `max.poll.records`。
- 优化处理耗时和 GC。
- 调整心跳参数。
- 使用 Sticky / Cooperative 策略。
- 发布时滚动并限速。

## 面试怎么回答

如果被问“Kafka Consumer Group、Coordinator、Heartbeat 和 offset commit 是怎么工作的”，可以这样答：

> Kafka 用 Consumer Group 表示一份消费进度。同一个 Group 内，一个 Partition 同一时刻只分给一个 Consumer，所以消费并发上限受 Partition 数限制；不同 Group 之间各自维护 offset，互不影响。每个 Group 有一个 Group Coordinator，它由 `group.id` hash 到 `__consumer_offsets` 的某个 Partition，这个 Partition 的 Leader broker 就是 Coordinator。Consumer 启动后先 FindCoordinator，再 JoinGroup，Coordinator 选出 Group Leader，由 Group Leader 按分配策略计算 Partition 分配，最后 SyncGroup 下发。
>
> Consumer 靠 heartbeat 维持成员身份，`session.timeout.ms` 检测心跳是否断掉，`max.poll.interval.ms` 检测业务是否太久没调用 poll。`poll()` 不只是拉消息，还推进网络 IO、Rebalance、Fetch、自动提交等客户端状态。Offset commit 写到 `__consumer_offsets`，提交的是下一条要读的 offset。关键业务通常关闭自动提交，处理成功后手动提交；先处理再提交是 at-least-once，会重复但不丢，所以业务必须幂等。自动提交和异步处理容易丢，`commitAsync` 要注意失败和乱序，Rebalance 撤销分区前要同步提交当前进度。

这个回答的关键不是背 API，而是把 **组成员管理、心跳存活、poll 主循环、offset 持久化、业务处理缝隙** 连成一条链。

## 这一篇要带走的结论

- Consumer Group 是一份逻辑消费进度，同组分摊，不同组独立。
- Group Coordinator 由 `group.id` 映射到 `__consumer_offsets` Partition Leader。
- `JoinGroup` / `SyncGroup` 完成成员加入和分区分配，分配策略影响 Rebalance 成本。
- Heartbeat 判断进程 / 网络是否活着，`max.poll.interval.ms` 判断业务处理是否卡住。
- `poll()` 是 Consumer 主循环入口，不只是拉消息。
- Offset commit 提交的是“下一条要读的 offset”，写入 `__consumer_offsets`。
- 自动提交不等于处理成功提交，关键链路应关闭自动提交。
- `commitSync` 可靠但阻塞，`commitAsync` 高吞吐但要处理失败和乱序。
- 多线程消费只能提交连续成功的 offset，不能提交最大完成 offset。
- Kafka 默认消费语义应按 at-least-once 理解，业务幂等是必修课。

---

下一篇 `10_Rebalance大专题：Eager_Cooperative_Sticky三代协议与治理.md`，会专门拆 Rebalance：为什么成员变化会让整个组停顿，Eager 为什么 Stop-The-World，Sticky 和 Cooperative 到底解决了哪一半问题，以及生产上怎么减少 Rebalance 风暴。
