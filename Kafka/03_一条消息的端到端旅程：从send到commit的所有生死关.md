# 一条消息的端到端旅程：从 send 到 commit 的所有生死关

## 这一篇要回答什么

前两篇我们立了心智模型，拆了 6 个抽象。但抽象孤立看会忘——一旦放回真实链路上，它们各自在守的位置就立刻清楚了。

这一篇做一件事：

> 沿着一条消息的端到端路径，**从 `producer.send()` 写下第一行代码，一直到 `consumer.commitSync()` 写下最后一行**，把中间会经过的所有“生死关”逐段拆开。

每一段我们都问两个问题：

1. 这一段如果**崩了**（机器挂、网络断、进程死），会发生什么？
2. Kafka 用**哪个机制 / 哪个抽象**在挡？

这一篇看完，后面 04~09 讲存储、副本、Controller、Producer、事务、Consumer 时，你会知道每一块在端到端链路里**待在哪个位置**。这才是后面深挖时不迷路的关键。

## 全链路地图

先把这条路画出来。每个红圈是“可能崩 / 可能出错”的位置：

```
                            Producer 进程
   ┌────────────────────────────────────────────────────────┐
   │  ① send() → ② Serializer → ③ Partitioner → ④ Accumulator (batch) │
   │                                            ↓                       │
   │                                       ⑤ Sender 线程                │
   └─────────────────────────────────│──────────────────────┘
                                     │ TCP
                                     ▼
                            Broker (Partition Leader)
   ┌────────────────────────────────────────────────────────┐
   │  ⑥ SocketServer (Acceptor / Processor)                 │
   │  ⑦ RequestHandler / KafkaApis                          │
   │  ⑧ ReplicaManager.appendRecords                        │
   │  ⑨ Log.append → PageCache → (异步) 磁盘                │
   │ 10 更新 LEO                                            │
   └─────────────────────────────────│──────────────────────┘
                                     │ Follower fetch
                                     ▼
                            Broker (Follower)
   ┌────────────────────────────────────────────────────────┐
   │ 11 Fetcher 拉取 → 写自己的 Log → 更新自己的 LEO        │
   │ 12 下次 fetch 时上报自己的 LEO → Leader 推进 HW        │
   └─────────────────────────────────│──────────────────────┘
                                     │ Leader ack 回 Producer
                                     ▼
   ┌────────────────────────────────────────────────────────┐
   │ 13 Producer 收到 ack（取决于 acks 配置）               │
   └────────────────────────────────────────────────────────┘

                            Consumer 进程
   ┌────────────────────────────────────────────────────────┐
   │ 14 Coordinator 分配 Partition                          │
   │ 15 Fetcher 从 Leader 拉取 (只能拉到 HW)               │
   │ 16 Deserializer → poll() 返回                          │
   │ 17 业务处理                                            │
   │ 18 commitSync() → 写 __consumer_offsets                │
   └────────────────────────────────────────────────────────┘
```

下面分四大段挖：**Producer 侧、Broker 侧 Leader、副本复制、Consumer 侧**。

## 第一段：Producer 侧的四道关

### 关 ①②③：send → Serializer → Partitioner

`producer.send(record)` 不是网络调用。它做三件事：

1. **Serializer**：把 key / value 序列化成 byte[]
2. **Partitioner**：决定这条消息进哪个 Partition
3. **塞进 Accumulator**（内存缓冲）后就返回（异步），返回值是一个 `Future`

这一段崩了会怎样？

- 序列化失败 → 抛异常，`send()` 调用方拿到错误，**消息根本没发出去**，不算丢
- Partitioner 出错（极少） → 同上
- 进程在这一步崩 → 业务代码自己丢，和 Kafka 无关

**关键设计点**：分区路由决定了顺序和并发。

- 传了 key → 按 `hash(key) % numPartitions` 路由 → 同 key 一定进同 Partition → 分区内有序的前提
- 没传 key → 默认是 sticky / round-robin → 同一个 batch 内倾向同 Partition（为了 batch 效率）
- 自定义 Partitioner → 可以按业务字段（订单 ID、用户 ID、商家 ID）路由

**坑**：很多人想要“按订单顺序”，但 key 用了订单状态字段（如 `pending` / `paid`），结果同一个订单的不同状态消息散到不同 Partition——**乱序**。

### 关 ④：Accumulator（batch 缓冲）

这是 Producer 性能的灵魂。送进来的消息不会立刻发，而是按 `(topic, partition)` 分桶累积成 **Record Batch**，达到下面任一条件才触发发送：

- `batch.size`：默认 16KB，攒够就发
- `linger.ms`：默认 0，等满这个时间就发（**调到 5~20ms 通常能极大提升吞吐**，代价是几十 ms 延迟）

这一段崩了会怎样？

- **Producer 进程崩** → Accumulator 里所有还没发出的消息**全丢**
- 这就是为什么 `producer.send()` 返回 `Future` 时，**它的"成功"不是"已落 broker"，只是"已进缓冲"**
- 真正的“落 broker”信号是 callback 里的 `RecordMetadata`，或者 `Future.get()` 返回

**生产高频坑**：

> “我服务正常退出还会丢消息？”

会。如果你不显式 `producer.flush()` + `producer.close()`，JVM 直接退出时 Accumulator 里的消息没人发。微服务优雅退出钩子里要补 `flush()`。

### 关 ⑤：Sender 线程 + 网络

Sender 是 Producer 内部一个独立线程，把 batch 通过 TCP 发给对应 Partition 的 Leader。这里有两个关键参数：

- **`acks`**：要求 broker 在什么程度后才回 ack（下文展开）
- **`retries` + `retry.backoff.ms`**：网络错误 / Leader 切换时的重试次数
- **`max.in.flight.requests.per.connection`**：单连接上同时发多少个未 ack 的请求

这一段崩了会怎样？

- TCP 超时 / 连接断 / broker 临时不可用 → 触发 retries
- **没开幂等的情况下**：重试可能造成**重复**（broker 已写入但 ack 丢了）
- **没开幂等 + `max.in.flight > 1`**：重试可能造成**分区内乱序**（请求 A 失败重试，请求 B 先到）

> 这就是 02 提到的“retries × inflight 会破坏分区内有序”。Kafka 的解法是 `enable.idempotence=true`——broker 端按 Sequence Number 重排去重，让重试既不重复也不乱序。08 会专挖。

## 第二段：Broker 侧 Leader 的五道关

消息到了 broker 端 Leader。

### 关 ⑥⑦：SocketServer + RequestHandler

Kafka 的网络层是经典 Reactor 模型（14 会专挖）：

- **Acceptor**：单线程，监听端口，分发新连接给 Processor
- **Processor**：N 个线程，处理已建立连接上的 IO（默认 `num.network.threads=3`）
- **RequestHandler**：M 个线程（默认 `num.io.threads=8`），处理实际业务逻辑

请求从网络读出来后丢到 RequestChannel，RequestHandler 取出来分发到 `KafkaApis`，根据请求类型走不同分支（`Produce` / `Fetch` / `Metadata` / ...）。

这一段崩了会怎样？

- Broker 进程崩 → 走副本切换（后面讲）
- 网络饱和、Processor 线程不足 → 请求堆积、Producer 端超时
- I/O 线程不足 → 请求处理慢、ack 慢、Producer 重试增多

### 关 ⑧⑨：ReplicaManager.appendRecords → Log.append

进入 `KafkaApis.handleProduceRequest` 后，核心是 `ReplicaManager.appendRecords`：

1. 拿到对应 Partition 的 Leader Log 对象
2. 调 `Log.append`，把消息追加到当前活跃 Segment 的 `.log` 文件末尾
3. 更新 `.index` 和 `.timeindex` 的稀疏索引
4. 推进 LEO（Log End Offset）

**关键事实**：`Log.append` 写的是**PageCache**，**默认不强制刷盘**。

```
Producer ──► Leader broker (堆内)
                  │
                  ▼
            PageCache (OS 内存) ←── 默认就到这里就返回
                  │
                  ▼  (OS 后台异步)
              磁盘
```

刷盘策略由两个参数控制，**默认两个都设得极其保守**（基本等于关闭）：

- `log.flush.interval.messages`（默认 LONG_MAX，等于不主动刷）
- `log.flush.interval.ms`（默认 NULL，等于不主动刷）

也就是说：**Kafka 设计上把刷盘委托给 OS PageCache，靠副本机制保证不丢**，而不是靠每次写都 fsync。这一点和 MySQL 默认 `sync_binlog=1` 是完全不同的哲学。

> 这是 04 要专挖的点。Kafka 的"快"和"不丢"是两条不同的设计线：快靠顺序写+PageCache+零拷贝；不丢靠 Replica + ISR。

这一段崩了会怎样？

- **机器掉电**：PageCache 里没刷盘的数据**会丢**。但只要 Replica 数 ≥ 2 且其他副本有，就不丢（下面讲）。
- **broker 进程崩，OS 没崩**：PageCache 还在，进程重启后能恢复。不丢。
- **磁盘满 / 文件系统错**：写失败，broker 直接报错，不会 ack 给 Producer。

### 关 ⑩：LEO 推进、等待副本

`Log.append` 完，Leader 的 LEO 推进了。但**还没 ack Producer**——`acks` 配置决定了什么时候 ack。

- `acks=0` → Producer 发完立刻当成功，**broker 收都不一定收到就 ack 了**
- `acks=1` → Leader 写到 PageCache 就 ack（**不等任何 follower**）
- `acks=all` → 等到 **ISR 内所有副本** 都已经把这条消息同步过去，才 ack

**`acks=all` 不等于"等所有 Replica"**，等的是 ISR。所以 `min.insync.replicas` 是关键的搭档：

- 配 `replication.factor=3`、`min.insync.replicas=2`、`acks=all` → 必须至少 Leader + 1 个 follower 同步成功才 ack
- 如果 ISR 缩到 < 2 个 → Leader **拒绝写**（抛 `NotEnoughReplicasException`），宁可不收也不丢

这就是 02 强调过的“Replica + ISR + acks 三件套必须联动”。三件配齐才有意义——任何一件没配对，整套都形同虚设。

## 第三段：副本复制的两道关

### 关 ⑪：Follower 拉

Follower 不是被 Leader 推消息，是**自己拉**。每个 Follower 上有 `ReplicaFetcherThread`，不停地向 Leader 发 `Fetch` 请求：

- 请求里带自己的 LEO
- Leader 返回从 follower LEO 开始的消息
- Follower 写到自己的 Log（同样落 PageCache）
- Follower 自己的 LEO 推进

为什么用拉不用推？

- **流控简单**：Follower 自己决定拉多少、什么节奏，慢就慢，不会被 Leader 压垮
- **Leader 状态简单**：Leader 不用维护 follower 进度，只需要在 Fetch 请求里看 follower 报上来的 LEO
- **新 Follower 上线方便**：直接以最早 offset 起步拉，不需要 Leader 主动追赶

这一段崩了会怎样？

- **Follower 拉得慢**（GC、磁盘忙、网络慢）：在 `replica.lag.time.max.ms`（默认 30s）内追不上 → **被 Leader 踢出 ISR**。Leader 仍能服务写（因为 ISR 还有自己 ± 其他副本），消费者也还能读，但**容错度降低**。
- **Follower 崩**：进程 / 机器恢复后从自己最后落盘的位置继续拉。Kafka 副本复制是幂等的——重复 fetch 同一段不会重复落盘。
- **Follower 网络分区**：被踢出 ISR；分区恢复后追上来再加回 ISR。

### 关 ⑫：Leader 推进 HW

HW（High Watermark）的定义很精确：

> HW = `min(ISR 内所有副本的 LEO)`

每次 follower 来 fetch 时报上来它自己的 LEO，Leader 看一遍 ISR 集合，取最小的那个，那就是新的 HW。

为什么 HW 这么重要？

- **消费者只能读到 HW 之前的消息**——HW 之后的消息可能还没在所有 ISR 副本上落地，万一 Leader 挂了被选主截断，消费者读过的消息可能"消失"
- HW 是 Kafka 给“**消息已经在分布式系统层面安全了**”的承诺线

**Leader 切换时的危险**：老 Leader 截断不一致问题。

考虑这个场景：

```
T0:  Leader=A，LEO=100，HW=100，ISR={A,B}
T1:  A 收到一条新消息，append，LEO=101，HW 还是 100（还没等到 B 复制）
T2:  A 挂了，Controller 选 B 当 Leader
T3:  B 的 LEO 是 100，HW 也是 100，新 Leader 工作
T4:  A 恢复，作为 Follower 加入，发现自己 LEO=101 比 Leader 的 100 还高
T5:  A 怎么办？
```

老办法是 A 把 101 那一条**截断**——但这里有微妙的不一致问题，靠单纯 HW 比较会在特殊场景下**丢已 ack 数据**（KAFKA-3514）。Kafka 在 0.11 加了 **Leader Epoch** 机制专门补这个洞——05 会专挖。

## 第四段：Consumer 侧的五道关

### 关 ⑭：Coordinator 分配 Partition

Consumer 启动时会找 Group Coordinator（一个特定 broker）：

1. 发 `JoinGroup`，加入 Group
2. Coordinator 选定一个 Consumer 当 **Group Leader**（不是 broker leader，是 group 内逻辑 leader）
3. Group Leader 算出分配方案（哪个 Consumer 拿哪些 Partition）
4. Coordinator 把方案下发给所有成员

这一段崩了会怎样？

- 任何 Consumer 上线 / 下线 / 改订阅 → 触发 **Rebalance**
- Eager 协议下 Rebalance 期间所有 Consumer 停止消费（**Stop-The-World**）
- Cooperative 协议下只有受影响的 Partition 暂停（10 会专挖）

### 关 ⑮：Fetcher 拉消息

分配完 Partition 后，Consumer 开始向**对应 Partition 的 Leader broker** 发 `Fetch` 请求：

- 请求里带 “从哪个 offset 起拉”
- broker 返回从该 offset 开始、到 **HW 为止** 的消息
- 注意：**消费者读不到 HW 之外的消息**

`fetch.min.bytes` / `fetch.max.wait.ms` 决定服务端是否要攒一会儿再返回（提升吞吐）。`max.poll.records` 决定每次 `poll()` 给业务多少条。

### 关 ⑯⑰：反序列化 + 业务处理

`poll()` 拿到一批消息后：

1. Deserializer 反序列化成业务对象
2. 业务代码处理

这一段是**整个端到端链路里 Kafka 完全管不到的地方**。绝大多数“消息丢”“消息重复”的真实原因都在这里：

- 业务处理抛异常 → 你怎么处理？继续？跳过？重试？
- 业务处理 OOM → 进程崩，offset 还没提交，下次重读
- 业务处理把消息写 DB 但 DB 失败 → offset 提没提决定了重读还是丢

### 关 ⑱：commit offset

Commit 有两种姿势：

- **自动提交**（`enable.auto.commit=true`，默认）：每隔 `auto.commit.interval.ms`（默认 5s）异步把当前最大 offset 提交回去
- **手动提交**：`commitSync()` / `commitAsync()` 业务自己控

自动提交的隐藏陷阱：**自动提交的是“已 poll 过的最大 offset”，不是“已成功处理的 offset”**。

```
poll 返回 100 条消息（offset 100~199）
↓
自动提交线程：5 秒后提交 offset=200（poll 完就算）
↓
业务还在处理第 50 条，进程崩了
↓
重启：从 200 开始读 → 100~199 中 50 条之后的消息全丢
```

这就是“**自动提交 = at-most-once 的常见误用**”。正确做法是**关掉自动提交，处理完一批再手动 commit**。

### 三种消费语义具体落在哪里

到这里可以把 Kafka 的三种语义画准：

| 语义 | 落地姿势 | 风险 |
|---|---|---|
| **At-most-once** | 先 commit offset，再处理业务 | 处理崩了 → 丢 |
| **At-least-once** | 先处理业务，再 commit offset（**默认推荐**） | commit 前崩 → 重复 → 业务幂等兜底 |
| **Exactly-once（Kafka 内）** | 用事务 Producer + `isolation.level=read_committed`，把“处理结果写 Kafka + commit offset”做成一个事务 | 仅在 consume → process → produce 全部在 Kafka 内时成立；sink 到外部系统不算 |

## 把整条链路并起来：每段在守什么

| 链路段 | 主要风险 | Kafka 用什么挡 | 业务侧要做什么 |
|---|---|---|---|
| ① Producer.send | 序列化错、业务异常 | 抛错由业务处理 | 业务自己处理失败 |
| ④ Accumulator | 进程崩丢内存消息 | 无 | `flush()` + 优雅退出 |
| ⑤ Sender + 网络 | 网络抖、重试导致重复 / 乱序 | `enable.idempotence` | 业务幂等兜底 |
| ⑥⑦ Broker 接入 | 线程不足 / 慢请求 | 调整线程数、监控 RequestQueue | 监控、扩容 |
| ⑧⑨ Log.append | 掉电丢 PageCache | **Replica + ISR** | 配 `acks=all` + `min.insync.replicas≥2` |
| ⑩ ack | Leader 挂 / 副本不够 | `acks=all` + ISR + `min.insync.replicas` | 配齐三件套 |
| ⑪ Follower 拉 | 拉慢被踢 ISR | `replica.lag.time.max.ms` 容差 | 监控 ISR 抖动 |
| ⑫ HW 推进 | 老 Leader 苏醒截断错位 | **Leader Epoch** | 升到 0.11+ |
| ⑭ Coordinator 分配 | Rebalance 停顿 | Cooperative / Sticky | 控好 `session.timeout` / `max.poll.interval` |
| ⑮ Fetch | 只能拉到 HW | HW 设计 | 无 |
| ⑰ 业务处理 | 业务崩 → 重读 | 无（Kafka 管不到） | **业务幂等** |
| ⑱ commit offset | 自动提交丢消息 | 提供手动提交 API | **关自动提交，手动 commit** |

这一张表是 Kafka 整个生产可靠性的浓缩版。每一行展开都是一个独立章节。

## 反复出现的几个核心机制

把上面 18 道关排一下，你会发现 Kafka 来回就用这几样东西在挡：

1. **Replica + ISR**：挡 broker 单点 / 落盘丢失（⑨⑩⑪⑫）
2. **acks + min.insync.replicas**：挡 ack 提前 / 副本不足（⑩）
3. **Idempotent Producer (PID + Sequence)**：挡重试带来的重复和乱序（⑤）
4. **Leader Epoch**：挡老 Leader 苏醒后的日志截断错位（⑫）
5. **HW**：挡消费者读到“可能丢失”的数据（⑮）
6. **`__consumer_offsets` + 手动 commit**：挡消费侧重复 / 丢失（⑱）
7. **Cooperative Rebalance**：挡 Group 抖动导致全局停顿（⑭）

后面 04~10 几乎就是把这 7 个机制各自挖到底。

## 这一篇要带走的结论

- 一条消息从 `send()` 到 `commit()` 大约要过 **18 道关**，每一道都有“崩了会怎样”
- Producer 端最容易丢的不是“发出去”，是**没 flush 就退出**；最容易出问题的是**重试 × inflight**
- Broker 端 `Log.append` 默认只到 PageCache，**不靠 fsync，靠副本保命**
- `acks=all` 单独配没用，**必须配齐 `replication.factor` + `min.insync.replicas` + `acks=all` 三件套**
- HW 不是“写到哪了”，HW 是“**已经安全到消费者可见的位置**”
- 消费侧 “丢 / 重复” 99% 出在业务处理和 offset 提交的相对顺序上
- Kafka 默认是 at-least-once，**业务幂等不是可选项**

---

下一篇 `04_存储引擎深挖：顺序写、Segment、Index、PageCache与零拷贝.md`，正式进入“Kafka 为什么快”——但不是背“顺序写零拷贝”六个字，而是把顺序写、Segment 切片、稀疏索引、PageCache、`sendfile`、Batch、Compression 这一组协同拆开，挖到每一项**单独能省什么、加在一起能省什么**。
