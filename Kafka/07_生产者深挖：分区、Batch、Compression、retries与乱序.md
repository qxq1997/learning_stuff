# 生产者深挖：分区、Batch、Compression、retries 与乱序

## 这一篇要回答什么

前面 03 已经沿着端到端链路讲过 Producer 的位置：`send()`、序列化、分区、Accumulator、Sender 线程、网络、ack。

这一篇把 Producer 单独拎出来，是因为线上很多 Kafka 问题都不是 broker 端先出事，而是 Producer 端的几个选择题没想清楚：

1. 分区策略怎么选，为什么 key 选错会导致乱序和热点？
2. `batch.size`、`linger.ms`、`buffer.memory` 到底在控制什么？
3. 压缩应该开吗，`gzip`、`snappy`、`lz4`、`zstd` 怎么权衡？
4. `acks`、`retries`、`delivery.timeout.ms`、`request.timeout.ms` 谁管谁？
5. 为什么 `retries > 0` + `max.in.flight > 1` 可能导致重复和乱序？
6. 一个生产级 Producer 应该怎么配置，怎么优雅关闭，怎么观测？

先给结论：

> Kafka Producer 的核心不是“调用 send 发消息”，而是一个 **异步批量发送器**。它的性能来自 batch、compression、pipelining；它的可靠性来自 acks、retries、幂等；它的顺序边界来自 partition key、in-flight 和业务状态机。

## Producer 全链路

Producer 内部链路可以画成这样：

```text
业务线程
  │
  ▼
producer.send(record)
  │
  ├─► Serializer
  │
  ├─► Partitioner
  │
  ├─► RecordAccumulator
  │       └─ 按 topic-partition 攒 batch
  │
  ▼
Sender 线程
  │
  ├─► Metadata 缓存：Partition Leader 在哪
  │
  ├─► NetworkClient：TCP 连接、in-flight requests
  │
  └─► Broker Leader
          └─ append log → 等 acks → 返回 response
```

这里最重要的事实：

- `send()` 默认是异步的。
- `send()` 返回不等于 broker 已经写入。
- 消息会先进入 Producer 进程内存的 Accumulator。
- 真正网络发送由 Sender 线程完成。
- callback / `Future.get()` 才代表这次发送最终成功或失败。

所以 Producer 是有状态的：它有元数据缓存、内存缓冲、未 ack 请求、重试状态。它不是一个“每次 send 都同步打一次 RPC”的薄客户端。

## 第一题：key 是顺序和并发的源头

Producer 发出的 `ProducerRecord` 里最关键的字段不是 value，而是 key。

```java
new ProducerRecord<>("order-events", orderId, event)
```

key 决定默认分区路由：

- 有 key：通常对 key 做 hash，然后映射到某个 Partition。
- 无 key：现代 Kafka Producer 会使用 sticky partitioner，把一段时间内的无 key 消息尽量塞进同一个 Partition，攒满 batch 后再切换。

### 有 key：保局部顺序

如果业务要求同一个订单有序，就用 `orderId` 作为 key：

```text
orderId=1001 → partition 3
orderId=1002 → partition 7
orderId=1001 → partition 3
```

只要同一个 key 进入同一个 Partition，Kafka 就能提供分区内 append 顺序。Consumer 同组内一个 Partition 只由一个 Consumer 消费，也就能按 offset 顺序读出来。

### 无 key：保 batch 效率

无 key 的日志、埋点、监控数据通常不要求同一实体顺序。此时 sticky partitioner 比简单 round-robin 更适合高吞吐：

```text
先集中写 partition 2，把 batch 攒大
batch 发出后，再切到 partition 5
```

这样能减少小 batch，提升压缩率，也减少网络请求数。

### key 选错的后果

常见翻车：

1. 用低基数字段当 key，比如 `eventType`、`status`、`region`。
   几个 key 把流量压到少数 Partition，形成热点。

2. 用会变化的字段当 key。
   同一个订单不同状态的 key 不同，就进了不同 Partition，顺序没了。

3. 自定义 Partitioner 做了复杂逻辑。
   它一旦不稳定，同一 key 的路由就不稳定，顺序和排障都会变难。

4. 对强顺序 Topic 随便增加 Partition。
   默认 hash 通常会对 Partition 数取模，Partition 数变了，同一个 key 后续可能映射到新 Partition。对“同 key 长期严格有序”的 Topic，扩 Partition 要谨慎，最好提前规划好。

## 第二题：Partition 数怎么影响 Producer

Partition 数不只是 Consumer 并发上限，也是 Producer 吞吐和 batch 效率的取舍。

Partition 多的好处：

- 写入 Leader 分散到更多 broker。
- 单个 Partition 的吞吐压力下降。
- Consumer Group 后续可扩的并发更高。

Partition 多的代价：

- Producer 端 batch 被分散。
- 每个 `(topic, partition)` 都有自己的 batch，分区越多，单个 batch 越不容易攒大。
- broker 文件句柄、PageCache、元数据、Rebalance 成本上升。
- key 顺序 Topic 扩分区可能改变 key 到 Partition 的映射。

所以不要机械地说“Partition 越多越好”。对 Producer 来说，==太多 Partition 会让小 batch 变多，压缩率下降，请求数上升，吞吐反而变差。==

## 第三题：Batch 是 Producer 性能的第一块地基

Producer 会按 `(topic, partition)` 把消息攒成 Record Batch。触发发送的主要条件有两个：

- `batch.size`：单个 batch 的目标大小。
- `linger.ms`：batch 没攒满时，最多等多久再发。

### `batch.size`

`batch.size` 不是“每次一定发这么大”，而是“给每个 Partition batch 预留 / 允许的目标空间”。消息少时，batch 可能很小就被发走；消息多时，batch 满了马上发。

调大它的收益：

- 请求数减少。
- 压缩率提高。
- broker 处理效率提高。

代价：

- Producer 内存占用上升。
- 单条消息等待时间可能变长。
- 如果 Topic 分区很多，每个分区都分配 batch 空间，内存压力会放大。

### `linger.ms`

`linger.ms` 是“等一等，让 batch 变大”。默认偏低延迟，很多在线业务保持默认也没问题。但高吞吐日志场景，适当设成 5~20ms，通常能显著提高吞吐。

直觉是：

```text
linger.ms = 0
  来一条发一批，低延迟，但小 batch 多

linger.ms = 10
  最多等 10ms，多攒几条再发，吞吐高，延迟多一点
```

这就是 Kafka Producer 的一个基本 trade-off：

> **低延迟和高吞吐，不可能同时拉满。**

### `buffer.memory`

Accumulator 用的是 Producer 进程内存，受 `buffer.memory` 限制。Sender 线程如果发不出去，业务线程还在不断 `send()`，buffer 就会被填满。

填满后会发生什么？

- `send()` 可能阻塞，最多等 `max.block.ms`。
- 超过后抛 `TimeoutException`。
- 这说明 Producer 的生产速度已经超过“网络 + broker ack + 重试”的排水速度。

所以看到 Producer 端 `bufferpool-wait-time` 变高，不要只调大 `buffer.memory`。它可能是在告诉你：broker 慢了、网络慢了、acks 等太久、请求重试太多，或者 Producer 本身打得太猛。

## 第四题：Compression 是用 CPU 换网络和磁盘

Kafka 的压缩很优雅：

```text
Producer 压整个 batch
Broker 不解压，原样落盘
Consumer 拉到后自己解压
```

这意味着压缩能同时节省：

- Producer 到 broker 的网络。
- broker 磁盘空间。
- broker 到 Consumer 的网络。
- PageCache 占用。

而且 broker 不解压，所以不会明显增加 broker CPU。CPU 成本主要在 Producer 和 Consumer。

### 常见算法取舍

| 算法 | 特点 | 适合场景 |
|---|---|---|
| `none` | 无 CPU 成本，但网络和磁盘最大 | 小流量、极低延迟、内网资源富余 |
| `snappy` | 速度快，压缩率一般 | 通用低延迟场景 |
| `lz4` | 速度很快，压缩率不错 | 低延迟 + 高吞吐常用选择 |
| `gzip` | 压缩率高，CPU 重 | 离线日志、带宽昂贵、延迟不敏感 |
| `zstd` | 压缩率高，速度也较好 | 新集群常用，兼顾压缩率和性能 |

实际经验里，`lz4` 和 `zstd` 是很常见的生产选择。日志 / 埋点 / CDC 这类文本或 JSON 数据，压缩收益尤其大。

### 压缩和 batch 是一组

压缩是按 batch 做的。batch 太小，压缩率会很差。

这就是为什么 `linger.ms`、`batch.size` 和 `compression.type` 要一起看：

- `linger.ms` 太低 → 小 batch 多 → 压缩率差。
- `batch.size` 太小 → batch 装不下 → 压缩率差。
- message 本身已经是压缩格式，比如图片、gzip payload → 再压缩收益低。

## 第五题：acks 决定“等到什么程度算成功”

Producer 端 `acks` 决定 broker 什么时候回复成功：

| 配置 | 语义 | 风险 |
|---|---|---|
| `acks=0` | 发出去就算成功，不等 broker 响应 | broker 没收到也不知道，最快但最容易丢 |
| `acks=1` | Leader 写入后返回 | Leader 崩且 follower 没复制到时可能丢 |
| `acks=all` | ISR 内副本都同步后返回 | 最可靠，延迟更高，ISR 不足时会失败 |

生产上如果要可靠，常见组合是：

```text
replication.factor = 3
min.insync.replicas = 2
acks = all
```

这组配置的含义是：3 副本里至少 2 个同步副本可用，Producer 才能写成功。

但注意，`acks=all` 不是“所有副本都 fsync 到磁盘”，而是“ISR 内副本写入它们的 log，通常到 PageCache”。Kafka 的可靠性是靠多副本，而不是每条强刷盘。

## 第六题：retries 是可靠性和重复的分水岭

Producer 发送失败时会重试。常见失败包括：

- 网络断开。
- broker 正在切 Leader。
- 元数据过期，发到了旧 Leader。
- broker 繁忙，请求超时。
- ISR 不足，临时无法满足 `acks=all`。

有些错误是可重试的，有些不是。比如序列化错误、消息太大、认证失败，重试没有意义。

### 重试为什么会导致重复

最经典的场景：

```text
T1: Producer 发 batch A
T2: Leader 写入成功
T3: ack 在网络中丢了
T4: Producer 以为失败，重试 batch A
T5: broker 再写一次
```

站在 Producer 视角，这是一次失败后的重试；站在 broker 视角，这是两次写入。于是重复出现。

这就是为什么 Kafka 默认更接近 at-least-once：宁可重复，也不轻易丢。业务侧必须幂等。幂等 Producer 可以挡住一部分 Producer 重试重复，08 会专门讲。

### 三个 timeout 的关系

Producer 端容易把几个 timeout 搞混：

| 参数 | 管什么 |
|---|---|
| `request.timeout.ms` | 单个请求等待 broker 响应多久 |
| `retry.backoff.ms` | 一次失败后隔多久再重试 |
| `delivery.timeout.ms` | 一条消息从进入 Producer 到最终成功 / 失败的总时限 |
| `max.block.ms` | `send()` 等 metadata 或 buffer 空间最多阻塞多久 |

可以把它理解成：

```text
delivery.timeout.ms
  ├─ request.timeout.ms
  ├─ retry.backoff.ms
  ├─ request.timeout.ms
  ├─ retry.backoff.ms
  └─ ...
```

最终 `delivery.timeout.ms` 到了，即使还有重试机会，也会失败返回。

## 第七题：max.in.flight 为什么会导致乱序

`max.in.flight.requests.per.connection` 表示同一个 TCP 连接上，允许多少个请求“已经发出去但还没收到响应”。

它带来吞吐：

```text
in-flight = 1
  A 发出，等 A ack，再发 B
  网络 RTT 成为瓶颈

in-flight = 5
  A/B/C/D/E 连续发出
  broker 可以流水线处理，吞吐高
```

但没开幂等时，它也会带来乱序：

```text
T1: 发 batch A，offset 还没分配
T2: 发 batch B
T3: A 因网络错误被认为失败
T4: B 写入成功
T5: A 重试后写入成功

最终 broker 里的顺序：B 在前，A 在后
```

如果 A、B 里是同一个订单的状态消息，业务顺序就炸了。

### 怎么选

- 如果不开幂等，又要求严格分区内顺序：`max.in.flight=1`，代价是吞吐下降。
- 现代生产更推荐：开启 `enable.idempotence=true`，让 broker 用 PID + Sequence Number 处理重试去重和顺序，`max.in.flight` 可以保留较高值。
- 如果业务只要求最终可幂等、不要求同 key 严格顺序，可以接受较高 in-flight 换吞吐。

08 会展开为什么幂等 Producer 能把“高吞吐”和“分区内有序重试”重新放到一起。

## 第八题：消息太大是 Producer 和 Broker 的共同问题

大消息会放大所有成本：

- Producer 序列化慢。
- 压缩和拷贝慢。
- batch 容易被单条消息撑爆。
- broker 网络和 PageCache 压力大。
- Consumer 拉取和反序列化慢。
- 失败重试的代价更大。

相关参数包括：

- Producer：`max.request.size`
- broker：`message.max.bytes`
- Topic：`max.message.bytes`
- Consumer：`fetch.max.bytes`、`max.partition.fetch.bytes`

这些参数必须配套。Producer 允许 10MB，broker 只收 1MB，最后就是发送失败。

工程建议：

- 大对象不要直接塞 Kafka，优先把对象放对象存储，Kafka 里传引用。
- 单条消息尽量保持小而稳定。
- 如果必须传大消息，单独 Topic、单独限流、单独监控。

## 第九题：Callback 不是装饰品

很多代码这样写：

```java
producer.send(record);
```

这在可靠性上是不够的。`send()` 可能只代表消息进了本地缓冲。如果最终发送失败而业务没看 callback，就等于静默丢。

更安全的姿势：

```java
producer.send(record, (metadata, exception) -> {
    if (exception != null) {
        // 记录 topic、key、业务幂等键、异常类型，进入补偿或告警
        return;
    }
    // metadata.topic(), metadata.partition(), metadata.offset()
});
```

生产上 callback 至少要记录：

- topic
- key
- partition / offset
- 业务幂等键
- exception 类型
- 是否已经进入补偿通道

如果是关键业务消息，不要把发送失败藏在日志里就结束。要么同步等待结果，要么写 Outbox / 本地事件表，靠后台任务可靠投递。

## 第十题：flush 和 close 决定退出时丢不丢

Producer 进程内有 Accumulator。服务关闭时，如果直接杀进程，未发送或未 ack 的消息可能丢。

优雅退出要做两件事：

```java
producer.flush();
producer.close();
```

- `flush()`：等待当前已提交到 Producer 的消息发送完成。
- `close()`：关闭 Sender 线程和网络连接，也会尝试 flush。

微服务发布、容器滚动重启、JVM shutdown hook，都要注意这一点。Producer 端最隐蔽的丢消息，常常不是 broker 丢，而是服务退出时本地 buffer 里的消息没来得及发。

## 生产配置怎么组织

不要背一组“万能配置”。要按目标选。

### 可靠优先

适合订单、支付、库存变更、重要业务事件：

```properties
acks=all
enable.idempotence=true
retries=Integer.MAX_VALUE
delivery.timeout.ms=120000
request.timeout.ms=30000
max.in.flight.requests.per.connection=5
compression.type=lz4
linger.ms=5
batch.size=32768
```

同时 broker / topic 配：

```properties
replication.factor=3
min.insync.replicas=2
unclean.leader.election.enable=false
```

重点是业务侧仍要幂等。Producer 幂等只能解决“Producer 重试造成的重复”，解决不了“消费者处理成功但 offset 没提交造成的重复”。

### 吞吐优先

适合日志、埋点、指标：

```properties
acks=1
compression.type=zstd
linger.ms=10
batch.size=65536
buffer.memory=67108864
```

如果业务允许少量丢失，`acks=1` 可以换更低延迟和更高可用性。但这要有明确业务确认，不要偷偷把关键业务也放进这个配置。

### 延迟优先

适合对端到端延迟更敏感、吞吐不大的在线事件：

```properties
linger.ms=0
batch.size=16384
compression.type=lz4
acks=all
enable.idempotence=true
```

低延迟不是把所有 batch 都关掉，而是在可靠性和少量 batch 效率之间取平衡。

## Producer 端怎么观测

线上 Producer 至少要看这些指标：

| 指标 | 说明 |
|---|---|
| `record-send-rate` | 发送速率 |
| `record-error-rate` | 发送失败率 |
| `record-retry-rate` | 重试速率 |
| `request-latency-avg/max` | broker 请求延迟 |
| `batch-size-avg` | batch 平均大小 |
| `compression-rate-avg` | 压缩效果 |
| `buffer-available-bytes` | Accumulator 剩余空间 |
| `bufferpool-wait-time` | 等 buffer 的时间 |
| `record-queue-time-avg` | 消息在 Producer 内部排队多久 |
| `metadata-age` | 元数据多久没刷新 |

几个判断：

- retry rate 上升：网络、Leader 切换、broker 慢、ISR 不足。
- queue time 上升：Sender 发不出去或 broker ack 慢。
- batch size 很小：流量太散、Partition 太多、`linger.ms` 太低。
- buffer wait 上升：Producer 内部积压，继续打只会让延迟和失败扩大。
- error rate 上升：要按异常类型区分是可重试还是不可重试。

## 常见事故拆解

### 事故一：明明 send 了，消息却没到

常见原因：

- 没看 callback，发送失败被吞了。
- 服务退出没 flush，Accumulator 里的消息丢了。
- `acks=0`，broker 没收到 Producer 也不知道。
- message 太大，被 broker 拒绝。
- metadata 过期或权限失败，重试耗尽。

解决：

- 关键消息必须看 callback 或使用 Outbox。
- 关闭时 flush + close。
- 可靠链路使用 `acks=all` + 幂等。
- 配套检查 Producer / broker / topic 的消息大小限制。

### 事故二：同一个订单状态乱序

常见原因：

- key 没用 `orderId`。
- 增加 Partition 后 key 映射变化。
- 没开幂等，`retries > 0` + `max.in.flight > 1`。
- Consumer 后面又用线程池无序处理。

解决：

- 用稳定业务 key。
- 强顺序 Topic 谨慎扩分区。
- 开启幂等 Producer，或把 `max.in.flight` 降到 1。
- Consumer 端按 key 串行，业务更新加状态机。

### 事故三：Producer 延迟突然升高

常见原因：

- broker 请求延迟升高。
- ISR 缩小，`acks=all` 等待变慢或失败。
- 网络抖动导致重试。
- buffer 被打满，业务线程阻塞。
- batch 太小，请求数过多。

解决：

- 看 Producer 的 request latency、retry rate、queue time。
- 看 broker 的 Produce 请求延迟、请求队列、磁盘和网络。
- 必要时限流 Producer。
- 调整 `linger.ms` / `batch.size` 提高批量效率。

## 面试怎么回答

面试里问“Kafka Producer 怎么保证消息不丢、怎么提升吞吐、为什么会乱序”，可以这样答：

> Producer 是异步批量发送模型。业务线程调用 `send()` 后，消息先序列化、按 key 分区，再进入 RecordAccumulator 按 topic-partition 攒 batch，由 Sender 线程异步发送。吞吐主要靠 `batch.size`、`linger.ms`、压缩和 in-flight pipeline；可靠性靠 `acks=all`、`retries`、`enable.idempotence=true`，并且 broker 端要配 `replication.factor=3`、`min.insync.replicas=2`。乱序主要来自 key 选错、扩 Partition 改变 key 映射、没开幂等时 `retries > 0` 加 `max.in.flight > 1`，以及 Consumer 端无序并发。关键业务还要看 callback、优雅 flush，并用业务幂等兜底。

这个回答把 Producer、broker、consumer 和业务幂等都连起来了，比只背几个参数更像真的用过。

## 这一篇要带走的结论

- Producer 是异步批量发送器，`send()` 返回不等于 broker 已写入。
- key 决定分区，分区决定顺序、热点和后续消费并发。
- batch、linger、compression 是吞吐三件套，要一起看。
- `acks=all` 必须配合 `replication.factor` 和 `min.insync.replicas` 才有意义。
- retries 提升可靠性，但没开幂等时可能带来重复和乱序。
- `max.in.flight` 提升吞吐，也会在重试场景下破坏顺序。
- callback、flush、close 是 Producer 可靠投递里很容易被忽略的工程细节。
- 关键业务不要只信 Kafka Producer，最终仍要靠业务幂等和 Outbox 兜底。

---

下一篇 `08_幂等与事务Producer：PID_Sequence_TransactionCoordinator与EOS.md`，会继续往下挖：幂等 Producer 到底怎么用 PID + Sequence Number 去重，事务 Producer 又是怎么用 Transaction Coordinator 把“写多分区 + 提交 offset”做成 Kafka 内部的 exactly-once。
