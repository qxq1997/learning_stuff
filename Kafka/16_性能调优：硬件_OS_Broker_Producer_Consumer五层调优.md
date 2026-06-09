# 性能调优：硬件 / OS / Broker / Producer / Consumer 五层调优

讲 Kafka 性能调优，最怕一句话：

> “把某个参数调大就好了。”

Kafka 的性能不是一个参数调出来的。前面已经拆过它的速度来源：

- 顺序写。
- PageCache。
- 零拷贝。
- Batch。
- Compression。
- Pipelining。
- 分区并行。
- Broker 网络线程 / I/O 线程。
- Consumer 批量拉取和批量处理。

这一篇把这些散点收成一套调优方法。

## 这一篇要回答什么

1. Kafka 调优前为什么必须先定义目标？
2. 吞吐、延迟、可靠性、成本为什么不能同时拉满？
3. 硬件怎么选：CPU、内存、磁盘、网络、Broker 数？
4. OS / JVM 怎么配：PageCache、堆、GC、文件系统、fd、swap？
5. Broker 参数怎么调：线程、队列、Partition、Retention、Replica、Compaction？
6. Producer 怎么调：`batch.size`、`linger.ms`、`compression.type`、`acks`、`buffer.memory`？
7. Consumer 怎么调：`fetch.min.bytes`、`fetch.max.wait.ms`、`max.poll.records`、提交和并发？
8. 怎么做压测和容量规划？

先给结论：

> Kafka 调优的第一步不是改参数，而是定义目标：要更高吞吐、更低延迟、更强可靠性，还是更低成本。吞吐优先通常要增大 batch、linger、fetch 批量和压缩；延迟优先要减少等待和排队；可靠性优先要坚持 `acks=all`、幂等、`min.insync.replicas`、合理副本；成本优先要控制 retention、压缩、Partition 数和副本数。真正的调优顺序是：先算容量和瓶颈，再压测基线，然后按硬件、OS/JVM、Broker、Producer、Consumer 五层逐层优化。

## 第一原则：先定目标，不要同时追四件事

Kafka 性能通常有四个目标：

| 目标 | 典型诉求 | 常见代价 |
| --- | --- | --- |
| 高吞吐 | 每秒更多 MB / records | 延迟变高、batch 等待变长 |
| 低延迟 | p99 尽量低 | batch 变小、吞吐下降、CPU/QPS 上升 |
| 高可靠 | 不丢、少重复、可恢复 | `acks=all`、副本等待、写延迟升高 |
| 低成本 | 少机器、少磁盘、少带宽 | 峰值余量变小、恢复变慢 |

它们不是完全冲突，但不能都极致。

比如：

```text
linger.ms = 20
batch.size = 64KB
compression.type = zstd
```

这组配置对日志链路很香：吞吐高、网络省。

但它对极低延迟交易事件不一定合适，因为 Producer 端会主动等 batch。

再比如：

```text
acks = 1
```

能降低写入等待，但 Leader 写完后如果还没复制就挂了，可能丢已 ack 消息。

所以每次调优前先写清楚：

1. 峰值写入吞吐是多少？
2. 峰值读取吞吐是多少？
3. p95 / p99 生产延迟目标是多少？
4. Consumer lag 最多允许多少？
5. 历史积压要求多久追平？
6. 是否允许丢消息？
7. 是否允许重复消息？
8. retention 要保留多久？
9. 峰值要撑几倍余量？
10. 成本上限是多少？

没有这些答案，所谓调优就是猜。

## 第二原则：先算放大系数

Kafka 的资源消耗不是“Producer 写多少，Broker 就消耗多少”。

假设：

- 入口写入：100 MB/s。
- 副本数：RF=3。
- Consumer Group：3 个，每个都完整消费这个 Topic。
- 数据已经是压缩后的大小。

大致资源是：

```text
Broker 外部入口:
  Producer -> Leader = 100 MB/s

Broker 内部复制:
  Leader -> 2 个 Follower = 200 MB/s

Broker 外部出口:
  Broker -> 3 个 Consumer Group = 300 MB/s

集群存储:
  100 MB/s * 3 副本 * retention 时间
```

也就是说，100 MB/s 的入口写入，可能对应：

- 300 MB/s 复制写入相关流量。
- 300 MB/s 消费出口。
- 远不止 100 MB/s 的磁盘和网络压力。

如果还有 catch-up consumer 读历史，磁盘读会额外放大。

容量规划时要看：

```text
总写入 = Producer 入口
总复制 = Producer 入口 * (RF - 1)
总读取 = 每个 Consumer Group 读取量求和
总存储 = Producer 入口 * RF * retention
```

再加上：

- 压缩率。
- 峰值 / 平均值比例。
- 数据倾斜。
- Broker 故障后剩余机器承压。
- Reassignment / 扩容时的临时双份流量。

## 第三原则：先压测基线，再动参数

调优前至少要有一份基线：

| 维度 | 要记录什么 |
| --- | --- |
| Producer | records/s、MB/s、p99 latency、batch-size-avg、compression-rate、bufferpool-wait |
| Broker | Produce/Fetch latency、RequestQueue、NetworkProcessor idle、RequestHandler idle |
| Replica | UnderReplicatedPartitions、ISR shrink/expand、replica fetch 延迟 |
| Consumer | records/s、MB/s、records-lag-max、fetch latency、poll 处理耗时 |
| 机器 | CPU、网络、磁盘 util/await、PageCache、GC |

压测要尽量贴近真实业务：

- 消息大小分布要真实。
- key 分布要真实。
- Topic / Partition 数要真实。
- Consumer Group 数要真实。
- 是否开 SSL / SASL 要真实。
- 是否跨机房要真实。
- 下游处理耗时要真实。

不要只压 Kafka 空转链路：

```text
Producer -> Kafka -> Consumer 拉完丢弃
```

这只能测 Kafka 的裸能力，测不出实际系统瓶颈。

更有价值的是：

```text
Producer -> Kafka -> Consumer -> 下游 DB/RPC/计算
```

因为很多线上 lag，不是 Kafka 慢，是下游慢。

## 第一层：硬件调优

### CPU：给 SSL、压缩、请求处理留余量

Kafka broker 本身不是重 CPU 系统，但下面几件事会吃 CPU：

- SSL / TLS 加密。
- Broker 端消息格式转换。
- 请求数太多，小 batch 太多。
- 压缩格式不匹配导致 broker 转换。
- 大量 Group Coordinator / Transaction Coordinator 请求。
- Controller 和 Broker 混部署。
- GC。

经验上：

- 开 SSL 后，CPU 压力会明显升高，零拷贝路径也会失效。
- 小消息 + 小 batch 会让 broker QPS 暴涨，CPU 被协议处理吃掉。
- 大量 Consumer Group 会让 Fetch response 和 offset commit 变多。

调优方向：

- 优先让 Producer 做 batch，降低 broker 请求 QPS。
- Producer 压缩，Broker 不解压。
- 避免 broker 端 message format conversion。
- 大集群使用专职 Controller。
- 给 SSL 预留 CPU，必要时评估硬件加速或更轻认证方案。

### 内存：不是给堆，是给 PageCache

Kafka 的内存观念和很多 JVM 服务相反：

> JVM 堆不要太大，机器内存主要留给 PageCache。

原因前面讲过：

- Kafka 写到 PageCache。
- Consumer 热读也从 PageCache 出。
- PageCache 命中，Consumer fetch 基本不碰磁盘。
- 堆太大反而增加 GC 风险。

常见方向：

- Broker 堆通常保持在几 GB 到十几 GB，不要把机器内存都给 JVM。
- 机器内存越多，PageCache 越能扛热数据。
- 频繁 OS 重启会清 PageCache，比只重启 broker 更伤。
- catch-up consumer 大量读冷数据，会把 PageCache 搅乱。

如果你看到：

```text
JVM heap 使用率不高
Linux cached 很高
```

这通常是 Kafka 期待的状态，不是“内存浪费”。

### 磁盘：顺序写很强，但别破坏它

Kafka 对磁盘友好，是因为 append-only 顺序写。

但顺序写会被这些因素破坏：

- 单 broker 上 Partition 太多。
- active segment 太多。
- catch-up consumer 大量读历史。
- compaction 和 delete 清理与正常读写抢 I/O。
- partition reassignment 同时复制大量数据。
- 磁盘接近打满。
- SSD 自身 GC 或坏盘。

硬件建议：

- 生产优先 SSD / NVMe，尤其是有冷读、重放、分区很多的场景。
- HDD 可以扛顺序写，但冷读和多 Partition 并发会痛。
- 文件系统优先 XFS。
- 不要把 Kafka 数据放在网络盘、共享盘、慢云盘上。
- 磁盘水位要有 80%、85%、90% 分级告警。
- 给 reassignment 和 broker 故障恢复留空间余量。

关于 RAID / JBOD：

- Kafka 自己有副本机制，很多生产会用 JBOD 多盘。
- 单盘坏了可以让该盘上的 replica 重建。
- RAID 可以降低单盘故障暴露，但也可能引入控制器瓶颈和恢复放大。

没有绝对答案，关键是运维能力和故障恢复流程要匹配。

### 网络：经常比磁盘先打满

Kafka 很多瓶颈实际在网络。

原因是：

```text
入口写入
  + 副本复制
  + 多 Consumer Group 读取
  + 跨机房复制
  + reassignment 迁移
```

都会吃网络。

优化方向：

- 生产集群尽量使用 10GbE 起步，大流量用 25GbE / 更高。
- 使用压缩降低网络字节数。
- 控制 Consumer Group 数量和冷读任务。
- 给跨机房 Mirror / Replicator 单独规划带宽。
- 使用 rack awareness 降低机架故障风险，但不要误以为能减少流量。
- 用 quota 保护核心链路。

### Broker 数：不要只按平均吞吐算

Broker 数量要按峰值和故障余量算。

假设 6 台 broker 正常能扛 6 GB/s，不代表你就能长期跑 6 GB/s。

因为至少要考虑：

- 挂 1 台后，剩余 broker 要接住 leader 和 replica 压力。
- 滚动重启期间，ISR 和 PageCache 会抖。
- 扩容 / reassignment 会产生额外复制流量。
- 日常流量有峰值。

一个更稳的容量思路是：

```text
目标利用率不要长期超过 50%~60%
留出 broker 故障、峰值、迁移和冷读空间
```

## 第二层：OS / JVM 调优

### 文件系统：优先 XFS

Kafka 是大文件 append、多 segment、顺序读写场景。

常见选择：

| 文件系统 | 适配性 |
| --- | --- |
| XFS | 大文件、append、多盘场景稳定，生产常用 |
| ext4 | 也可用，但大规模场景通常更偏向 XFS |
| ZFS | 不推荐作为普通 Kafka 数据盘，ARC 会和 PageCache 抢内存，复杂度高 |

不要把文件系统选型当成唯一性能开关。大多数情况下，更重要的是：

- 磁盘本身能力。
- Partition 数。
- PageCache。
- 冷读比例。
- 网络和压缩。

### PageCache：让 OS 做它擅长的事

Kafka 不做应用层 cache，靠 OS PageCache。

因此：

- 不要把 JVM 堆调得太大。
- 不要让其他进程抢内存。
- 避免同机混部吃内存的服务。
- 控制 catch-up consumer 对热数据 PageCache 的污染。
- 滚动重启时避免同时重启太多 broker。

观察指标：

- Linux `cached` / `available`。
- 磁盘读 IOPS 是否突然升高。
- Consumer fetch latency 是否升高。
- broker 重启后是否出现 ISR 抖动。

### JVM 堆和 GC

Kafka 是 JVM 服务，但消息数据不应该大规模进堆。

调优方向：

- 堆保持适中，常见是 6GB 到 12GB 级别，按集群规模和版本压测确认。
- 使用现代 GC，如 G1；新版本和合适 JDK 下也可评估 ZGC。
- 关注 Full GC、长 pause、allocation rate。
- 避免超大请求、超大消息导致对象压力。
- 监控 direct memory 和 network buffer。

GC 对 Kafka 的伤害很直接：

```text
broker GC pause
  -> 不能处理 Produce / Fetch / Follower fetch
  -> Producer 延迟升高
  -> Follower 落后
  -> ISR shrink
  -> acks=all 更慢
```

### Swap、文件句柄和网络参数

生产 Broker 要关注：

- 关闭或极低使用 swap，避免 JVM 被换出。
- 提高 `ulimit -n`，Kafka 会打开大量 segment、index、socket。
- 确认 ephemeral port、TCP backlog、socket buffer 与连接规模匹配。
- 监控连接数和 fd 使用率。

这里不要迷信某一套万能 sysctl。

OS 参数最好跟着压测和监控调：

- 如果网络丢包 / 重传多，看 TCP 和网卡。
- 如果 fd 接近上限，提高 fd。
- 如果磁盘 flush 抖，看 dirty page 和磁盘能力。
- 如果 swap 出现，先查内存规划和混部。

## 第三层：Broker 调优

### Partition 数：并发单位，也是成本单位

Partition 是 Kafka 的并行单位：

- Producer 按 Partition 分 batch。
- Broker 按 Partition 存 log。
- Consumer Group 一个 Partition 同时只能给一个 Consumer 消费。
- Follower 按 Partition 复制。

Partition 太少：

- Producer 并发不够。
- Consumer 扩不起来。
- 单 Partition 热点明显。

Partition 太多：

- active segment 多，顺序写退化。
- 文件句柄和内存元数据增多。
- Controller metadata 变大。
- Leader election 和恢复变慢。
- Producer batch 被打散，压缩率下降。

估算 Partition 时至少看：

```text
Partition 数 >= 目标 Consumer 并发
Partition 数 >= 目标写入吞吐 / 单 Partition 可承载吞吐
Partition 数不能超过 broker、controller、fd、PageCache 能承受的范围
```

不要把 “以后不够再加 Partition” 当成无成本方案。

增加 Partition 会：

- 触发 Rebalance。
- 改变 key 到 Partition 的映射。
- 影响顺序边界。
- 只能提升后续消息并发，不能自动重分布历史积压。

### 副本与可靠性参数

关键业务建议基线：

```properties
replication.factor=3
min.insync.replicas=2
unclean.leader.election.enable=false
```

Producer 侧配：

```properties
acks=all
enable.idempotence=true
```

这套配置不是最高吞吐，但可靠性边界清楚。

如果为了吞吐把 `acks` 改成 1，或者把 `min.insync.replicas` 改成 1，要明确业务接受数据丢失风险。

### 网络线程：`num.network.threads`

这个参数控制 Broker 网络 Processor 数。

适合调大：

- `NetworkProcessorAvgIdlePercent` 长期很低。
- 连接数很多。
- SSL 加密导致网络线程 CPU 重。
- response 写回压力大。

不适合调大的情况：

- 磁盘已经打满。
- RequestHandler idle 已经很低。
- CPU 已经没有余量。
- 问题根因是 Consumer 下游慢。

### I/O 处理线程：`num.io.threads`

这个参数控制 KafkaRequestHandler 数量。

适合调大：

- `RequestHandlerAvgIdlePercent` 长期很低。
- RequestQueue 堆积。
- CPU 还有余量。
- LocalTimeMs 高但不是磁盘硬瓶颈。

不适合调大的情况：

- 磁盘 await 已经很高。
- PageCache miss 导致大量冷读。
- 下游 Consumer 不读，response 堵。
- 请求太小太多，应该先调 Producer batch。

线程数不是越大越好。线程太多会增加上下文切换，也可能把磁盘压得更抖。

### 请求队列：`queued.max.requests`

这个参数控制 broker 请求队列能排多少请求。

调大：

- 可以吸收突发。
- 短时减少客户端失败。
- 但会增加排队延迟。

调小：

- 更早背压客户端。
- 延迟更可控。
- 突发下更容易失败。

它是背压阀，不是吞吐银弹。

如果 RequestQueue 长期堆积，要找下游处理慢的原因，而不是只把队列调大。

### Replica fetch 相关参数

副本复制慢会导致 ISR 抖动。

关注：

- `num.replica.fetchers`。
- `replica.fetch.max.bytes`。
- `replica.fetch.wait.max.ms`。
- follower broker 磁盘和网络。
- leader broker Fetch 请求延迟。

适合调优的场景：

- 单 broker 上 follower replica 很多。
- 副本追赶慢。
- 大消息导致 fetch 上限不够。
- reassignment 期间复制压力大。

但如果网络或磁盘已经满，调大 fetcher 可能只会抢更多资源。

### Log segment、retention 和 compaction

`log.segment.bytes` 影响 segment 滚动。

较小 segment：

- 删除更及时。
- retention 生效更快。
- 文件数量更多，元数据更多。

较大 segment：

- 文件数量少。
- 顺序读写更规整。
- 删除不够及时，磁盘回收慢。

Retention：

- `retention.ms` 控时间。
- `retention.bytes` 控大小。
- 删除按 segment，不是按单条消息。

Compaction：

- 适合 changelog / 最新状态类 Topic。
- log cleaner 线程和磁盘 I/O 要规划。
- compaction 落后会让磁盘持续上涨。

调优重点：

- 高吞吐短保留 Topic 可以适当减小 segment，让删除更及时。
- 长保留低吞吐 Topic 可以适当增大 segment，减少文件数。
- compacted Topic 要监控 cleaner backlog。

### Message size：大消息是性能敌人

Kafka 能支持较大消息，但不代表应该这么用。

大消息会影响：

- Producer batch。
- Broker 内存和网络 buffer。
- PageCache。
- Fetch response。
- Consumer 处理耗时。
- `max.partition.fetch.bytes`。
- 复制延迟。

如果业务要传大文件、大 JSON、大图片，优先考虑：

```text
对象存储放大对象
Kafka 只传引用 / 元数据
```

Kafka 更适合事件流，不适合当大对象传输系统。

### Leader 均衡和热点治理

性能问题经常不是集群整体不够，而是热点集中：

- 某个 broker leader 太多。
- 某个 Topic 流量集中。
- 某几个 key 打到同一 Partition。
- 某个 Consumer Group 读冷数据。

治理手段：

- preferred leader election。
- partition reassignment。
- 优化 partition key。
- 热点 key 加 bucket。
- 对大流量 Topic 隔离集群或隔离 broker。
- 用 quota 限制非核心租户。

### Quota：保护核心链路

Quota 不是提升吞吐，而是保护系统。

可以限制：

- Producer 流量。
- Consumer 流量。
- Request 百分比。

适用场景：

- 多租户集群。
- 防止某个业务打爆 broker。
- 限速 catch-up consumer。
- 保护核心 Topic。

没有 quota 的共享 Kafka 集群，很容易被一个历史回放任务拖慢所有业务。

## 第四层：Producer 调优

Producer 的性能来自四件事：

```text
Batch + Compression + Pipelining + Partition 并行
```

### `batch.size`

`batch.size` 是单个 `(topic, partition)` batch 的目标大小。

调大适合：

- 流量高。
- 消息较小。
- 吞吐优先。
- batch-size-avg 长期很小但流量足够。

调太大的代价：

- Producer 内存占用上升。
- 低流量 Partition 可能攒不满。
- 延迟可能受 `linger.ms` 控制。

常见方向：

```properties
batch.size=32768
# 或高吞吐场景 65536、131072，需压测
```

### `linger.ms`

`linger.ms` 是“等一等，让 batch 变大”。

调大适合：

- 日志、埋点、监控、CDC。
- 吞吐优先。
- 网络或 broker QPS 压力大。

代价：

- Producer 端主动增加等待。
- p99 延迟可能上升。

典型方向：

```properties
linger.ms=5
# 高吞吐可试 10~20ms
# 低延迟可保持 0~1ms
```

不要把 `linger.ms=0` 理解成没有 batch。流量足够高时，batch 仍然可能自然攒满。

### `compression.type`

压缩能同时降低：

- 网络流量。
- 磁盘占用。
- Broker I/O。
- Consumer 读出的字节量。

但它会增加 Producer 和 Consumer CPU。

常见选择：

| 算法 | 特点 | 适合场景 |
| --- | --- | --- |
| `none` | 无 CPU 成本，字节最多 | 极低延迟、小流量、带宽富余 |
| `snappy` | 快，压缩率一般 | 通用场景 |
| `lz4` | 很快，压缩率不错 | 低延迟 + 高吞吐 |
| `zstd` | 压缩率高，速度也不错 | 大多数现代高吞吐场景 |
| `gzip` | 压缩率高，CPU 重 | 离线、延迟不敏感 |

压缩要和 batch 一起看：

```text
小 batch -> 压缩率差
大 batch -> 压缩率好
```

所以 `linger.ms`、`batch.size`、`compression.type` 是一组三件套。

### `buffer.memory`

`buffer.memory` 是 Producer 端 RecordAccumulator 总内存。

调大适合：

- 短时间突发流量。
- Broker 偶发抖动。
- Producer 进程内存充足。

但如果 `bufferpool-wait-time` 持续升高，不要只调大 buffer。

它可能说明：

- Broker ack 慢。
- 网络慢。
- ISR 等待慢。
- Producer 打得太猛。
- batch / linger / compression 不合理。

调大 buffer 只能让排队更久，不能让 broker 变快。

### `acks`、幂等和 in-flight

可靠链路：

```properties
acks=all
enable.idempotence=true
retries=Integer.MAX_VALUE
max.in.flight.requests.per.connection=5
```

这能兼顾：

- `acks=all` 等 ISR。
- 幂等 Producer 处理重试去重。
- `max.in.flight` 保留 pipeline 吞吐。

吞吐优先但允许风险的链路，可能用：

```properties
acks=1
```

但这必须有业务确认。

不要为了性能偷偷把关键消息从 `acks=all` 改成 `acks=1`。

### `delivery.timeout.ms` 和 `request.timeout.ms`

这两个参数不是性能加速器。

| 参数 | 作用 |
| --- | --- |
| `request.timeout.ms` | 单次请求等 broker response 多久 |
| `delivery.timeout.ms` | 一条消息从进入 Producer 到最终成功 / 失败的总时间 |

调大可以减少短抖动下的失败，但也会：

- 让失败暴露更晚。
- 增加 Producer 内部堆积时间。
- 让上游以为系统还在正常接收。

如果 broker 真慢，调 timeout 只是把问题藏起来。

### Partition key

Producer 分区策略影响吞吐和顺序。

有 key：

- 同 key 有序。
- 但 key 倾斜会热点。

无 key：

- sticky partitioner 能攒更大 batch。
- 吞吐更好。
- 不保证业务实体顺序。

热点 key 处理：

```text
merchantId
  -> merchantId + bucketNo
```

这是牺牲大 key 的全局顺序，换并发和吞吐。

### Producer 配置模板

#### 可靠优先

```properties
acks=all
enable.idempotence=true
retries=Integer.MAX_VALUE
max.in.flight.requests.per.connection=5
compression.type=lz4
linger.ms=5
batch.size=32768
delivery.timeout.ms=120000
request.timeout.ms=30000
```

适合订单、支付、核心业务事件。

#### 吞吐优先

```properties
acks=1
compression.type=zstd
linger.ms=10
batch.size=65536
buffer.memory=67108864
```

适合日志、埋点、监控等可接受少量风险或可重放场景。

#### 延迟优先

```properties
acks=all
enable.idempotence=true
compression.type=lz4
linger.ms=0
batch.size=16384
```

适合在线低延迟事件。注意低延迟不等于完全关掉 batch，而是在小等待和可靠性之间取平衡。

## 第五层：Consumer 调优

Consumer 的吞吐来自三件事：

```text
Fetch 批量 + 应用批处理 + 分区并行
```

### `fetch.min.bytes`

表示 broker 至少攒到多少字节再返回 Fetch。

调大适合：

- 吞吐优先。
- 消费流量稳定。
- 想减少 Fetch 请求次数。

代价：

- 数据不足时会等待。
- 低流量 Topic 延迟上升。

示例：

```properties
fetch.min.bytes=1048576
```

### `fetch.max.wait.ms`

表示即使没攒够 `fetch.min.bytes`，最多等多久也要返回。

它和 `fetch.min.bytes` 是一对：

```text
fetch.min.bytes 控“攒多少”
fetch.max.wait.ms 控“最多等多久”
```

吞吐优先可以：

```properties
fetch.min.bytes=1048576
fetch.max.wait.ms=500
```

低延迟可以：

```properties
fetch.min.bytes=1
fetch.max.wait.ms=50
```

具体值必须按业务延迟目标压测。

### `fetch.max.bytes` 和 `max.partition.fetch.bytes`

这两个控制单次拉取大小：

| 参数 | 含义 |
| --- | --- |
| `fetch.max.bytes` | 单次 Fetch response 总大小 |
| `max.partition.fetch.bytes` | 单个 Partition 单次最多返回多少 |

需要调大的场景：

- 消息较大。
- 单 Partition 吞吐很高。
- Consumer fetch 次数太多。

风险：

- Consumer 内存压力上升。
- 单次处理时间变长。
- 可能接近 `max.poll.interval.ms`。

### `max.poll.records`

它控制一次 `poll()` 交给应用的记录数。

调大：

- 单批处理更高效。
- commit 次数可能减少。
- 下游批量写更好。

调太大：

- 单批处理时间变长。
- 可能超过 `max.poll.interval.ms`。
- Rebalance 风险增加。
- 失败重试范围变大。

关键判断：

```text
max.poll.records * 单条平均处理耗时
  < max.poll.interval.ms 的安全边界
```

如果单条处理耗时波动很大，要按 p99 而不是平均值估算。

### `max.poll.interval.ms`

它不是吞吐参数，而是“业务处理最长允许多久不 poll”的稳定性参数。

调大适合：

- 单批处理确实较慢。
- 下游批量写不可避免。
- 已经控制好单批上限。

不要用它掩盖卡死。

如果 Consumer 偶尔处理 20 分钟才 poll，一味调大 interval 会让故障发现更慢。

### Consumer 并发模型

最简单模型：

```text
一个 Consumer 线程
  -> poll
  -> process
  -> commit
```

优点：

- offset 简单。
- 分区内顺序自然。
- Rebalance 处理简单。

缺点：

- 处理慢时吞吐低。

多线程模型：

```text
poll 线程
  -> 按 Partition 分发到 worker
  -> worker 处理
  -> 只提交连续成功 offset
```

关键难点：

- 同 Partition 顺序。
- 部分成功、部分失败。
- offset 只能提交连续完成的下一位。
- Rebalance revoke 前要收尾。

如果这些处理不好，多线程会把重复、乱序、丢失都放大。

### Commit 策略

吞吐和可靠性取舍：

| 策略 | 吞吐 | 风险 |
| --- | --- | --- |
| 每条 `commitSync` | 低 | 简单可靠但慢 |
| 每批 `commitSync` | 中 | 常见关键业务选择 |
| `commitAsync` | 高 | 失败和乱序要处理 |
| async + close/revoke sync | 高 | 常见折中 |
| auto commit | 高 | 异步处理时容易丢 |

关键链路通常：

```text
处理成功
  -> 提交 offset
```

也就是 at-least-once。重复用业务幂等解决。

### 下游批处理

很多 Consumer 慢，不是 Kafka 慢，是下游慢。

优化方向：

- DB 批量写。
- RPC 批量调用或并发调用。
- 设置合理超时。
- 熔断和降级。
- DLQ 处理坏消息。
- 控制每批最大耗时。
- 避免无限重试阻塞 poll。

Kafka Consumer 调优必须和下游一起看。

### Consumer 配置模板

#### 可靠处理

```properties
enable.auto.commit=false
max.poll.records=100
max.poll.interval.ms=300000
fetch.min.bytes=1
fetch.max.wait.ms=100
isolation.level=read_committed
```

适合核心业务。处理成功后手动提交，重复由幂等兜底。

#### 吞吐处理

```properties
enable.auto.commit=false
fetch.min.bytes=1048576
fetch.max.wait.ms=500
max.poll.records=1000
fetch.max.bytes=52428800
```

适合日志、离线、批处理链路。注意监控单批耗时，避免 Rebalance。

#### 低延迟处理

```properties
enable.auto.commit=false
fetch.min.bytes=1
fetch.max.wait.ms=50
max.poll.records=50
```

适合低流量低延迟事件，但 broker 和 consumer 请求频率会更高。

## 常见场景怎么调

### 场景一：日志 / 埋点高吞吐

目标：

- 吞吐高。
- 成本低。
- 延迟允许几十毫秒到几百毫秒。
- 可接受重复，部分场景可接受少量丢失或可重放。

方向：

- Producer 使用较大 batch。
- `linger.ms=10~20` 压测。
- `compression.type=zstd` 或 `lz4`。
- Consumer 增大 `fetch.min.bytes`。
- 下游批量写。
- Topic retention 明确，不要无限保留。
- 使用 quota 防止打爆共享集群。

### 场景二：核心交易事件

目标：

- 不丢。
- 顺序边界清楚。
- 允许重复但业务幂等。
- 延迟要稳。

方向：

- `replication.factor=3`。
- `min.insync.replicas=2`。
- `acks=all`。
- `enable.idempotence=true`。
- `unclean.leader.election.enable=false`。
- 业务使用稳定 partition key。
- Consumer 手动提交。
- Rebalance revoke 前同步提交。
- 严格监控 ISR、Producer error、Consumer lag。

### 场景三：低延迟在线链路

目标：

- p99 延迟低。
- 吞吐不是极限。

方向：

- `linger.ms=0~1`。
- batch 不要过大。
- `fetch.min.bytes=1`。
- `fetch.max.wait.ms` 较小。
- 避免 broker 请求队列排队。
- Topic / Broker 隔离，减少共享租户干扰。
- 控制消息大小。
- 网络和 GC 要稳。

### 场景四：历史回放 / 追积压

目标：

- 尽快追平。
- 不影响在线链路。

方向：

- 给 catch-up consumer 限速。
- 非高峰期执行。
- 增大 fetch 批量。
- 下游批量处理。
- 如果旧 Partition 锁住吞吐，用临时高分区 Topic 重分发。
- 避免把 PageCache 全部打冷。
- 必要时用独立集群或隔离 broker。

### 场景五：多租户共享 Kafka

目标：

- 多业务共用。
- 防止单租户拖垮集群。

方向：

- 使用 Producer / Consumer quota。
- 核心 Topic 独立集群或独立 broker。
- 对大流量 Topic 做容量审批。
- 限制 Topic / Partition 滥用。
- 对 retention 做默认上限。
- 对历史回放任务做审批和限速。

## 调优决策树

### Producer 吞吐上不去

先看：

```text
batch-size-avg 是否太小？
compression-rate 是否差？
bufferpool-wait 是否高？
request-latency 是否高？
record-error-rate 是否升高？
```

如果 batch 小：

- 增大 `linger.ms`。
- 增大 `batch.size`。
- 检查 Partition 是否太多导致流量分散。

如果 buffer wait 高：

- Broker ack 慢，查 broker。
- Producer 发送太猛，限流。
- 增大 `buffer.memory` 只作为缓冲。

如果 request latency 高：

- 查 broker Produce latency。
- 查 ISR。
- 查网络和磁盘。

### Producer 延迟高

先拆：

```text
Producer batch 等待
  -> 网络发送
  -> broker request queue
  -> log append
  -> acks=all 等 ISR
  -> response 返回
```

调优方向：

- 降低 `linger.ms`。
- 检查 batch 是否过大。
- 检查 broker request queue。
- 检查 ISR 抖动。
- 检查 SSL CPU。
- 检查网络。

不要直接把 timeout 调大当成解决方案。

### Consumer lag 高

先看形态：

```text
所有 Partition 都高？
少数 Partition 高？
锯齿状高？
高但下降很快？
```

如果所有都高：

- 扩 Consumer 到 Partition 上限。
- 增大 fetch 批量。
- 优化下游处理。
- 查 broker fetch latency。

如果少数高：

- key 倾斜。
- 热点 Partition。
- 坏消息。
- 单分区顺序瓶颈。

如果锯齿状：

- Rebalance。
- GC。
- 发布。
- 下游周期性慢。

### Broker CPU 高

常见原因：

- SSL。
- 小 batch 请求太多。
- 压缩 / 解压发生在 broker。
- message format conversion。
- Coordinator 请求多。
- Controller / Broker 混部。
- GC。

优化：

- Producer 增大 batch。
- 使用合适压缩。
- 避免老客户端触发格式转换。
- 分离 Controller。
- 增加 broker。
- 优化 GC。

### Broker 磁盘高

常见原因：

- 写入超预期。
- retention 太长。
- compaction 落后。
- catch-up consumer 冷读。
- reassignment。
- Partition 太多。

优化：

- 压缩。
- 控制 retention。
- 增加磁盘 / broker。
- 限速冷读。
- 调整 segment。
- 治理大消息。

### Broker 网络高

常见原因：

- 多 Consumer Group。
- 副本复制。
- 跨机房复制。
- reassignment。
- 未压缩。
- 大消息。

优化：

- 压缩。
- 限速非核心 Consumer。
- 扩网络带宽。
- 隔离跨机房复制。
- 控制 Consumer Group 数。
- 扩 broker 分摊 leader。

## 压测时要避免的坑

### 只测平均延迟

Kafka 调优看 p99 / p999。

平均延迟漂亮，不代表线上稳。

尤其要看：

- GC pause 时的尾延迟。
- ISR 抖动时的 `acks=all` 延迟。
- Controller 切换时的 metadata 延迟。
- catch-up consumer 读冷数据时的 fetch 延迟。

### 只测单 Topic

真实集群通常多 Topic、多 Group、多租户。

单 Topic 压测看不出：

- Controller metadata 压力。
- Partition 总数成本。
- 多 Consumer Group 出口带宽。
- compaction 和 retention 后台压力。

### 只测热读

热读很好看，因为命中 PageCache。

但线上有：

- 新 Consumer 从头读。
- 历史回放。
- 宕机恢复后追数据。
- OS 重启 PageCache 冷。

这些都要单独压。

### 忽略下游

Consumer 压测如果只 `poll()` 后丢弃，吞吐会很好。

但真实链路可能是：

```text
poll
  -> JSON 解析
  -> 业务校验
  -> RPC
  -> DB 写入
  -> commit offset
```

下游慢，Kafka 再快也没用。

## 一套调优流程

可以按这个顺序做：

1. 定义目标：吞吐、延迟、可靠性、成本。
2. 计算容量：入口、复制、出口、存储、峰值、故障余量。
3. 建基线：不改参数，先压测和记录指标。
4. 判断瓶颈：CPU、网络、磁盘、PageCache、请求队列、Consumer 下游。
5. 先调客户端 batch / fetch，减少小请求。
6. 再调 Broker 线程和队列，确认 CPU / 磁盘有余量。
7. 再调硬件和集群规模。
8. 最后固化配置、告警、限流和容量水位。

调优动作要一次只改一类：

```text
只改 Producer batch
  -> 压测
  -> 记录变化

再改 compression
  -> 压测
  -> 记录变化

再改 broker 线程
  -> 压测
  -> 记录变化
```

同时改十个参数，最后你不知道是谁起作用。

## 面试怎么回答

如果被问“Kafka 怎么做性能调优，从哪些层面入手”，可以这样答：

> 我会先明确目标，因为 Kafka 的吞吐、延迟、可靠性和成本不能同时极致。吞吐优先会增大 batch、linger、fetch 批量和压缩；低延迟会减少等待和排队；可靠性要坚持 `acks=all`、幂等、`replication.factor=3`、`min.insync.replicas=2`；成本要控制 retention、压缩、Partition 数和副本数。调优前还要算放大系数：入口写入、RF 带来的复制流量、多 Consumer Group 的出口流量和 retention 存储。
>
> 分层上，硬件层看 CPU、内存、磁盘、网络。CPU 主要被 SSL、小请求、格式转换、GC 吃掉；内存主要留给 PageCache，不是给 JVM 堆；磁盘要关注 cold read、Partition 太多、compaction、reassignment；网络要算 Producer 入口、Replica 复制和 Consumer 出口。OS/JVM 层看 XFS、PageCache、fd、swap、GC。Broker 层看 Partition 数、leader 分布、`num.network.threads`、`num.io.threads`、RequestQueue、replica fetcher、retention、compaction、quota。
>
> Producer 层主要调 `batch.size`、`linger.ms`、`compression.type`、`buffer.memory`、`acks`、幂等和 `max.in.flight`；Consumer 层主要调 `fetch.min.bytes`、`fetch.max.wait.ms`、`fetch.max.bytes`、`max.poll.records`、处理并发和 offset commit。最后一定要压测真实消息大小、key 分布、Consumer Group 数、SSL、下游处理，观察 p99、请求队列、线程 idle、ISR、lag、磁盘网络，而不是凭经验改参数。

这个回答的关键是：**先目标，再容量，再压测，再分层调。**

## 这一篇要带走的结论

- Kafka 性能不是单参数问题，而是硬件、OS、Broker、Producer、Consumer 的协同。
- 调优前先定义吞吐、延迟、可靠性、成本目标。
- 容量规划要算 RF 复制、多 Consumer Group 读取、retention 存储和故障余量。
- 内存主要留给 PageCache，Broker 堆不宜盲目调大。
- Producer 的吞吐三件套是 `batch.size`、`linger.ms`、`compression.type`。
- Consumer 的吞吐三件套是 fetch 批量、应用批处理、分区并行。
- Broker 线程和队列要结合 idle、request queue、CPU、磁盘看，不能盲调。
- Partition 数既是并发单位，也是元数据、文件、PageCache 和恢复成本。
- 压测必须贴近真实业务，尤其要测尾延迟、冷读、Rebalance、下游处理和故障恢复。

---

下一篇 `17_Kafka作为基础设施：数据总线_CDC_日志中枢_与Flink配合.md`，会把 Kafka 从“单个消息系统”放回公司级数据基础设施里，看它怎么承接 CDC、日志中枢、实时计算入口和数据总线。
