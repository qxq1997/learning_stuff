# 网络与线程模型：Reactor / Acceptor / Processor / Purgatory

## 这一篇要回答什么

前面我们一直沿着“消息语义”讲 Kafka：分区、副本、Producer、Consumer、事务、Rebalance、丢失、重复、顺序、积压。

这一篇钻进 broker 内部，回答一个更工程的问题：

> Producer / Consumer / Follower / Controller 的请求到了 broker 以后，是哪些线程接住的，怎么排队，谁真正执行读写，为什么有些请求要进 Purgatory，哪些线程或队列堵住会造成线上抖动？

要回答 8 个问题：

1. Kafka broker 为什么用 Reactor 模型？
2. Acceptor、Processor、RequestHandler 分别干什么？
3. 请求队列和响应队列为什么这么设计？
4. Produce 请求从 socket 到 append log 怎么走？
5. Fetch 请求为什么可能被“挂起”等一会儿？
6. Purgatory 到底是什么，为什么 acks=all 和 fetch.min.bytes 都会用到它？
7. 控制类请求为什么不能被普通 Produce / Fetch 淹没？
8. 线上怎么通过线程池空闲率、请求队列、请求延迟定位瓶颈？

先给结论：

> Kafka broker 的请求处理是一个分层异步模型：Acceptor 接连接，Processor 做网络读写，RequestHandler 执行业务逻辑，KafkaApis 分发到 Produce / Fetch / Metadata / Offset 等处理器，ReplicaManager / GroupCoordinator / TransactionCoordinator 等组件完成真正逻辑。Purgatory 用来保存“条件还没满足但未来可能完成”的延迟请求。这个模型快，是因为网络 I/O、业务处理、延迟等待被拆开了；它也容易抖，因为任何一层队列堆积都会向 Producer 延迟、Consumer lag、ISR 抖动传导。

## 总体图：从 socket 到 KafkaApis

Kafka broker 的请求主链路可以画成：

```text
Client / Follower / Controller
        │
        ▼
SocketServer
        │
        ▼
Acceptor
  接收新连接，把连接分给 Processor
        │
        ▼
Processor (network thread)
  读请求、解析协议头、放入 RequestChannel
        │
        ▼
RequestChannel.requestQueue
  网络线程和请求处理线程之间的共享队列
        │
        ▼
KafkaRequestHandler (I/O thread)
  从队列取请求
        │
        ▼
KafkaApis
  按 API 类型分发：
  Produce / Fetch / Metadata / OffsetCommit / JoinGroup / ...
        │
        ▼
ReplicaManager / Coordinator / LogManager / ...
        │
        ▼
RequestChannel.responseQueue
  每个 Processor 有自己的响应队列
        │
        ▼
Processor 写 Response 回 socket
```

注意这几个名字的层次：

- **SocketServer**：broker 网络入口总组件。
- **Acceptor**：监听端口，接受新 TCP 连接。
- **Processor**：网络线程，负责已建立连接的读写。
- **RequestChannel**：请求 / 响应在网络线程和处理线程之间交换的通道。
- **KafkaRequestHandler**：请求处理线程，也就是常说的 I/O 线程。
- **KafkaApis**：所有 Kafka API 请求的分发入口。

这不是“一个请求一个线程”，也不是“网络线程自己把所有逻辑做完”，而是典型 Reactor + 工作线程池。

## 为什么用 Reactor

如果每个连接一个线程：

```text
1 万个连接 = 1 万个线程
```

上下文切换、线程栈、调度开销会把 broker 拖垮。

Kafka 的连接数量通常很高：

- Producer 连接。
- Consumer 连接。
- Follower fetch 连接。
- AdminClient 连接。
- Controller / broker 间连接。
- 监控和运维工具连接。

Reactor 模型的核心是：

> 少量网络线程用 selector 管理大量连接，有事件再处理。

Acceptor 只管接新连接，Processor 用非阻塞 I/O 处理多个 socket 上的读写，真正慢的业务逻辑丢给 RequestHandler。这样网络层不会被磁盘读写、Purgatory 等待、Coordinator 逻辑卡住。

## Acceptor：只接连接，不做重活

Acceptor 的职责很轻：

1. 监听 broker 的 listener 端口。
2. `accept()` 新 TCP 连接。
3. 按轮询或负载方式把连接分给某个 Processor。

它不应该做：

- 日志 append。
- Fetch 读盘。
- group rebalance。
- 权限以外的复杂业务逻辑。

如果 Acceptor 卡住，新连接建不进来；但已建立连接通常还能由 Processor 继续处理。

生产上常见问题：

- 连接风暴，比如大量短连接。
- 客户端疯狂重连。
- TLS 握手过重。
- listener 配置错误导致连接集中到少数 broker。

治理：

- 客户端连接复用。
- 控制重试退避。
- 合理配置连接数和认证方式。
- 监控连接创建速率和失败认证日志。

## Processor：网络线程，负责读写 socket

Processor 是 Kafka 的网络线程，由参数控制：

```properties
num.network.threads=3
```

它负责：

- 监听已分配连接上的可读 / 可写事件。
- 读取请求字节。
- 做基础协议解析。
- 把完整请求放入 RequestChannel。
- 从自己的响应队列取 response。
- 写回客户端 socket。

Processor 不负责真正的 Kafka 业务逻辑。它不会自己 append log，也不会自己执行 offset commit。

为什么响应队列通常是每个 Processor 自己的？

因为连接归某个 Processor 管。response 要写回同一个 socket，最自然的方式就是把 response 放回这个 Processor 的队列，由它在下一轮 selector 事件里写出去。

如果 Processor 忙，会表现为：

- request 读不及时。
- response 写不及时。
- 客户端 request latency 上升。
- 网络线程空闲率下降。
- 连接上 in-flight 请求变多。

常看指标：

```text
NetworkProcessorAvgIdlePercent
```

长期很低，说明网络线程很忙。可能是网络吞吐太高、SSL 加密太重、response 太大、连接太多，或者 broker 负载过高。

## RequestChannel：网络层和业务层的缓冲

Processor 读到完整请求后，不直接执行，而是放进共享请求队列：

```text
RequestChannel.requestQueue
```

KafkaRequestHandler 从这个队列取请求处理。

这个队列的作用是解耦：

- 网络线程数量和请求处理线程数量。
- 网络读写速度和业务处理速度。
- 短时间突发请求和后端处理能力。

但是队列不是越大越好。

队列太小：

- 突发流量下容易满。
- 网络线程无法继续放请求。
- 客户端延迟升高。

队列太大：

- 请求排队时间变长。
- Producer / Consumer 看到的是高延迟。
- 故障恢复变慢，因为旧请求堆在队列里。

相关参数：

```properties
queued.max.requests
```

这个参数控制请求队列能排多少请求。它是保护 broker 的背压阀，不是吞吐银弹。

## RequestHandler：I/O 线程，执行真正逻辑

RequestHandler 线程池由参数控制：

```properties
num.io.threads=8
```

它负责从 requestQueue 里取请求，调用 KafkaApis：

```text
KafkaRequestHandler.run()
  -> requestChannel.receiveRequest()
  -> kafkaApis.handle(request)
```

KafkaApis 再按请求类型分发：

| 请求 | 典型处理组件 |
|---|---|
| Produce | ReplicaManager / Log |
| Fetch | ReplicaManager / Log |
| Metadata | MetadataCache |
| OffsetCommit / OffsetFetch | GroupCoordinator |
| JoinGroup / SyncGroup / Heartbeat | GroupCoordinator |
| InitProducerId / AddPartitionsToTxn | TransactionCoordinator |
| LeaderAndIsr / UpdateMetadata | Controller 相关处理 |

如果 RequestHandler 忙，会表现为：

- 请求队列堆积。
- Produce / Fetch / Commit 延迟上升。
- Producer retry rate 上升。
- Consumer lag 上升。
- Follower fetch 慢，ISR 抖动。

常看指标：

```text
RequestHandlerAvgIdlePercent
```

长期很低，说明 I/O 请求处理线程忙。原因可能是磁盘慢、PageCache miss、压缩格式转换、Coordinator 负载高、事务请求多、请求太多太小。

## Produce 请求怎么走

Producer 发送消息到 broker Leader 后：

```text
Processor 读到 ProduceRequest
  -> requestQueue
  -> RequestHandler
  -> KafkaApis.handleProduceRequest
  -> ReplicaManager.appendRecords
  -> Partition.appendRecordsToLeader
  -> Log.append
  -> PageCache
```

然后根据 `acks` 决定何时返回：

### acks=0

Producer 不等响应。broker 侧即使处理失败，Producer 也未必知道。

### acks=1

Leader append 完就可以返回。

```text
Log.append 成功
response 放入 Processor 响应队列
Processor 写回客户端
```

### acks=all

Leader append 完还不够，要等 ISR 内 follower 都复制到。

这时请求不会占着 RequestHandler 线程傻等，而是进入 DelayedProduce Purgatory：

```text
append to leader
条件未满足：ISR follower 还没追上
放入 Purgatory
RequestHandler 线程释放，继续处理别的请求

Follower fetch 推进 HW
DelayedProduce 条件满足
生成 ProduceResponse
放入对应 Processor responseQueue
```

这就是 Purgatory 的价值：**等待条件时不占用 I/O 线程。**

## Fetch 请求怎么走

Fetch 请求有两类重要来源：

- Consumer 拉业务消息。
- Follower 拉副本数据。

路径类似：

```text
Processor 读 FetchRequest
  -> requestQueue
  -> RequestHandler
  -> KafkaApis.handleFetchRequest
  -> ReplicaManager.fetchMessages
  -> Log.read
  -> PageCache / Disk
```

Fetch 不一定立刻返回。为什么？

Consumer 可能配置：

```properties
fetch.min.bytes=1048576
fetch.max.wait.ms=500
```

意思是：

- 如果暂时没有攒够 1MB 数据，可以等一会儿。
- 最多等 500ms。

这时 Fetch 请求也会进入 DelayedFetch Purgatory：

```text
当前数据不足 fetch.min.bytes
放入 Purgatory
新消息写入 / 超时
条件满足
返回 FetchResponse
```

这能减少空轮询和小包，提高吞吐。

## Follower Fetch：复制链路也走这套模型

Follower 复制不是 Leader 主动推，而是 Follower 发 Fetch 请求来拉。

所以 Leader broker 上处理 follower fetch，也要经过：

```text
Processor -> requestQueue -> RequestHandler -> ReplicaManager.fetchMessages
```

这带来一个重要排障点：

> 如果 Leader broker 的网络线程 / I/O 线程 / 请求队列被普通客户端请求打满，Follower fetch 也会变慢。

后果：

```text
Follower 拉不到数据
Follower LEO 落后
超过 replica.lag.time.max.ms
被踢出 ISR
acks=all 变慢或失败
Producer 看到 NotEnoughReplicas / timeout
```

所以 ISR 抖动不一定是 follower 自己慢，也可能是 Leader 上处理 follower fetch 的线程或队列堵了。

排查 ISR 抖动时要同时看：

- follower broker 磁盘 / 网络 / GC。
- leader broker 请求队列。
- leader broker Fetch 请求延迟。
- network / request handler idle percent。
- 副本 fetcher 线程和带宽。

## Purgatory：延迟请求的“等待室”

Purgatory 这个名字很形象，意思是“炼狱”：

> 请求已经进来了，但暂时不能完成；它既不应该失败，也不应该占着线程干等，于是被挂起，等条件满足或超时。

常见延迟请求：

| 类型 | 等什么 |
|---|---|
| DelayedProduce | `acks=all` 等 ISR 副本复制完成 |
| DelayedFetch | Fetch 等新数据或 `fetch.min.bytes` 满足 |
| DelayedDeleteRecords | 删除到指定 offset 等待条件 |
| DelayedOperation | 一类带条件和超时的异步操作抽象 |

Purgatory 的关键字段通常是：

- 完成条件。
- 超时时间。
- 监听的 key，比如 TopicPartition。
- 条件满足时要执行的回调。

### Purgatory 不是失败队列

进入 Purgatory 不代表请求异常。它只是“现在还不能返回”。

例如：

- `acks=all` 等 follower 正常。
- Fetch 等数据攒够。

但如果 Purgatory 里请求堆积太多，就说明某些条件长期不满足：

- follower 复制慢。
- ISR 抖动。
- consumer fetch 太多但数据不足。
- broker 请求延迟高。
- 下游网络写 response 慢。

### Purgatory 和线程池的关系

最重要的一点：

> Purgatory 让等待不占用 RequestHandler 线程。

如果没有 Purgatory，`acks=all` 的 Produce 请求可能要在 I/O 线程里等 follower，Fetch 请求可能要在 I/O 线程里等新数据。很快所有 I/O 线程都被等待占满，broker 就没法处理新请求。

## 控制类请求为什么要有优先级

Kafka 里有些请求不是普通数据请求，而是控制类请求：

- LeaderAndIsr。
- UpdateMetadata。
- StopReplica。
- AlterPartition。
- Controller 到 broker 的状态变更请求。

这些请求决定：

- 谁是 Leader。
- 哪些副本在 ISR。
- broker 是否应该停止某些 replica。
- metadata 如何更新。

如果普通 Produce / Fetch 把请求队列塞满，控制类请求进不来，会发生什么？

```text
Controller 已经决定 p0 Leader 从 broker A 切到 broker B
broker A 请求队列被 Produce 塞满
LeaderAndIsr / metadata 更新处理很慢
Producer 还在向 A 发送旧请求
大量请求超时或进入 Purgatory
故障恢复变慢
```

这就是为什么 Kafka 后续引入控制平面和数据平面的隔离思路。生产上可以通过 control plane listener 等机制，让控制类通信不和普通数据流量完全挤在一起。

核心思想是：

> **控制请求慢，会放大数据请求的错误窗口。**

所以排障时看到 Leader 切换慢、NotLeaderForPartition 大量出现，不要只看 Producer，也要看 broker 请求队列和控制类请求处理是否被饿死。

## 请求延迟怎么拆

Kafka 请求延迟不是一个数字，它可以拆成几段：

```text
客户端等待时间
  = 网络传输
  + Processor 读请求
  + requestQueue 排队
  + RequestHandler 处理
  + Purgatory 等待
  + responseQueue 排队
  + Processor 写响应
```

不同瓶颈对应不同现象。

### 网络线程忙

表现：

- `NetworkProcessorAvgIdlePercent` 低。
- 吞吐高但 CPU / SSL CPU 高。
- response 写不出去。
- 多个请求 API 延迟同时上升。

可能原因：

- 网络带宽接近上限。
- SSL / SASL 开销大。
- 连接太多。
- response 太大，fetch.max.bytes 太高。

### I/O 线程忙

表现：

- `RequestHandlerAvgIdlePercent` 低。
- requestQueue 增长。
- Produce / Fetch 处理时间升高。
- commit / heartbeat 也可能受影响。

可能原因：

- 磁盘慢。
- PageCache miss，catch-up consumer 大量读冷数据。
- 请求太多太小。
- Coordinator 请求过多。
- 事务请求或 group rebalance 过多。

### Purgatory 等待多

表现：

- Produce 请求延迟高，但 Log.append 未必慢。
- `acks=all` 请求等待 ISR。
- Fetch 请求延迟高但数据量小。

可能原因：

- follower fetch 慢。
- ISR 缩小。
- fetch.min.bytes 太大。
- 客户端等待策略刻意增大吞吐。

### 响应写慢

表现：

- RequestHandler 处理完了，但客户端迟迟收到 response。
- 大 Fetch 响应多。
- 网络线程忙或客户端读慢。

可能原因：

- Consumer 拉大包但处理慢。
- 客户端网络差。
- broker 出口带宽打满。

## 线程参数怎么调

### `num.network.threads`

控制网络 Processor 数量。

适合调大：

- 网络线程 idle 长期很低。
- 连接数多。
- SSL 加密导致网络线程 CPU 重。
- response 写回压力大。

但调大不是万能：

- 如果瓶颈是磁盘或 I/O 线程，调网络线程没用。
- 线程太多会增加上下文切换。
- 还要看 CPU 核数。

### `num.io.threads`

控制请求处理线程数量。

适合调大：

- RequestHandler idle 长期很低。
- requestQueue 堆积。
- broker CPU 还有余量。
- 请求处理不是单纯被磁盘卡死。

如果磁盘已经打满，调大 I/O 线程可能让磁盘更抖。

### `queued.max.requests`

控制请求队列长度。

调大可以吸收突发，但会增加排队延迟。调小可以更早背压客户端，但突发下更容易失败。

### 相关但不同的线程

还有一些线程和请求路径相关，但不是同一层：

| 参数 / 线程 | 作用 |
|---|---|
| `num.replica.fetchers` | Follower 从 Leader 拉副本的线程数 |
| `background.threads` | 后台任务线程，如日志清理相关 |
| log cleaner threads | compact topic 的清理 |
| recovery threads | broker 启动 / 故障恢复时日志恢复 |

不要把所有“慢”都归到 `num.io.threads`。Kafka 慢经常是磁盘、网络、PageCache、GC、请求形态一起造成的。

## 常见事故拆解

### 事故一：Producer 端大量 timeout

可能链路：

```text
Producer send
  -> broker Processor 读慢
  -> requestQueue 排队
  -> RequestHandler 处理慢
  -> acks=all 进入 Purgatory 等 ISR
  -> 超过 delivery.timeout.ms
```

排查：

- Produce 请求延迟。
- RequestQueueSize。
- RequestHandlerAvgIdlePercent。
- NetworkProcessorAvgIdlePercent。
- UnderReplicatedPartitions / ISR shrink。
- broker 磁盘和网络。

### 事故二：Consumer lag 暴涨，但消费者没报错

可能链路：

```text
Fetch 请求处理慢
Fetch response 写回慢
catch-up consumer 读冷数据拖慢磁盘
Coordinator / heartbeat 请求也排队
```

排查：

- Fetch 请求延迟。
- bytes out。
- 磁盘读 I/O。
- PageCache 是否被冷读污染。
- network idle。
- Consumer 端 fetch latency。

### 事故三：ISR 抖动

可能链路：

```text
Follower fetch 请求在 Leader 端排队
Leader RequestHandler 忙
Follower 复制延迟增大
ISR shrink
```

不要只查 follower。Leader 端请求处理慢也会让 follower 看起来“跟不上”。

### 事故四：Leader 切换后恢复很慢

可能链路：

```text
控制类请求排队
broker metadata 更新慢
客户端继续向旧 Leader 发请求
NotLeaderForPartition 增多
Producer 重试增多
```

排查：

- Controller 相关日志。
- broker 请求队列。
- 控制平面 listener 配置。
- Metadata 请求延迟。
- NotLeaderForPartition 错误率。

## 面试怎么回答

如果被问“Kafka broker 请求是怎么处理的，Purgatory 是什么，线程池怎么调”，可以这样答：

> Kafka broker 网络层是 Reactor 模型。SocketServer 里 Acceptor 负责接收新连接，并把连接分配给 Processor 网络线程；Processor 用非阻塞 I/O 读写 socket，读到完整请求后放入 RequestChannel 的共享请求队列。KafkaRequestHandler，也就是 I/O 线程池，从请求队列取请求，交给 KafkaApis 按 Produce、Fetch、Metadata、OffsetCommit、JoinGroup 等类型分发，真正逻辑由 ReplicaManager、GroupCoordinator、TransactionCoordinator 等组件执行。处理完成后的 response 会放回对应 Processor 的响应队列，由它写回客户端。
>
> Purgatory 是延迟请求等待室。比如 `acks=all` 的 Produce 请求要等 ISR 副本复制完成，`fetch.min.bytes` 的 Fetch 请求要等数据攒够；这些请求不能立刻返回，但也不能占着 I/O 线程干等，所以会进入 Purgatory，等条件满足或超时后再生成 response。排障时要把请求延迟拆成网络线程、请求队列、I/O 线程、Purgatory 等待、响应写回几段看。
>
> 调参上，`num.network.threads` 看网络线程空闲率和连接 / SSL / response 压力，`num.io.threads` 看 RequestHandler 空闲率和请求队列，但如果瓶颈是磁盘或 PageCache miss，单纯加线程没用。Produce timeout、Consumer lag、ISR 抖动都可能是 broker 请求路径堵塞传导出来的，所以要同时看 RequestQueue、RequestHandlerAvgIdlePercent、NetworkProcessorAvgIdlePercent、Produce/Fetch latency、ISR 和磁盘网络。

这个回答的关键是：**不要把 Kafka broker 看成一个黑盒，要能说清请求在哪个队列、哪个线程、哪个等待条件上卡住。**

## 这一篇要带走的结论

- Kafka broker 用 Reactor 模型接大量连接，避免一个连接一个线程。
- Acceptor 接连接，Processor 做网络读写，RequestHandler 执行业务逻辑。
- 请求队列解耦网络线程和 I/O 线程，但队列堆积会直接变成客户端延迟。
- Produce 请求在 `acks=all` 时可能进 DelayedProduce Purgatory 等 ISR。
- Fetch 请求在数据不足或 `fetch.min.bytes` 未满足时可能进 DelayedFetch Purgatory。
- Follower 复制也走 Fetch 请求，Leader 端请求处理慢会导致 ISR 抖动。
- 控制类请求处理慢会放大 Leader 切换和 metadata 传播窗口。
- 调线程要看 idle percent、请求队列、请求延迟、磁盘、网络和 GC，不能靠一个参数包治百病。

---

下一篇 `15_线上排障专题：ISR抖动_Controller切换_Rebalance风暴_磁盘打满.md`，会把前面这些机制串成生产排障手册：看到 lag、ISR、Controller、磁盘、请求延迟这些信号时，怎么一步步定位。
