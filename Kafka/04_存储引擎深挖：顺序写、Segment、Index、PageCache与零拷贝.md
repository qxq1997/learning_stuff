# 存储引擎深挖：顺序写、Segment、Index、PageCache 与零拷贝

## 这一篇要回答什么

“Kafka 为什么快？”——八股答案是 **“顺序写 + 零拷贝”**。这六个字在面试里只能拿基础分，真要讲清楚 Kafka 的性能模型，要回答四个更难的问题：

1. 顺序写真的快是**因为磁盘顺序**，还是因为别的？
2. PageCache 在 Kafka 里到底扮演什么角色，为什么 Kafka 几乎不做应用层 cache？
3. 零拷贝在什么场景下**失效**，失效时 Kafka 还快不快？
4. 顺序写 + 零拷贝 + Batch + Compression + Pipelining 这一组**协同**起来是怎么省的？哪一项被破坏会立刻退化？

这一篇要把这四件事讲到工程层。重点不是“是什么”，是 **每一项单独能省什么、合起来能省什么、生产上什么时候这个省法会失效**。

## 第一锤：磁盘真的慢吗？

这是所有讨论的起点。如果你把磁盘想成“慢得没救”，Kafka 整个设计逻辑都看不懂。

数量级（HDD 7200 转，2010 年代典型值，今天的 SSD 把这两端都拉高，但比例没变）：

| 访问模式 | 大致吞吐 |
|---|---|
| HDD 顺序读 / 写 | ~100 MB/s |
| HDD 随机读 / 写 | ~1 MB/s |
| 内存随机访问 | ~10 GB/s |

**HDD 顺序访问能甩开随机访问 100 倍**。SSD 上这个差距小一些但仍然是数量级——这就是为什么 Kafka 反复强调 “顺序”。Kafka 的整个存储模型只做一件事：**把所有写操作变成对单个文件末尾的 append**。

但是注意一个常被忽略的事实：

> 顺序写 + PageCache 的组合，能让磁盘**看起来像内存**。

Linux 的 PageCache 会把刚写的数据留在内存里，**读的时候大概率命中 PageCache 而不是真的去碰磁盘**。所以 Kafka 不只是“顺序写磁盘”，而是 **“顺序写 PageCache，PageCache 后台异步刷盘”**。这两点必须一起看。

## 第二锤：append-only + Segment 切分

### 为什么是 append-only

Kafka 的 Partition 在物理上就是一个 **append-only 文件序列**。永远只往末尾写、从不在中间改，意味着：

- 写位置永远是“当前 Segment 文件末尾”，磁盘磁头几乎不需要寻道
- 没有 in-place update → 没有并发写冲突，不需要锁页 / MVCC
- 没有“先读再写”→ 没有读放大
- 删除是按段整段 unlink，不是按记录扣除

对比一下 MySQL InnoDB 的 B+ 树：

| 维度 | Kafka (append-only) | InnoDB (B+ 树) |
|---|---|---|
| 写模式 | 单文件末尾 append | 按主键定位到页 → 修改 |
| 寻道 | 几乎无 | 每次都有 |
| 并发控制 | 无（单 Leader 串行 append） | 行锁 / 页锁 / MVCC |
| 读模式 | 顺序扫 + 稀疏索引 | 树查找 |
| 删除 | 整段 unlink | tombstone / purge |
| 适合 | 高吞吐写、按 offset 顺序读 | 任意键随机读写 |

这两条路是不同物种。Kafka 不擅长“按订单号查这条订单的最新状态”，但能扛 InnoDB 望尘莫及的写吞吐。

### Segment 是顺序写能成立的工程前提

Partition 是一个逻辑上无限的 append-only 日志，但磁盘文件不能无限大。Segment 是把它切成几百到几千个 1GB 文件。每个 Partition 在任一时刻只有**一个 active segment**，所有新写入都打在它末尾。

这就推出一个常被忽略的事实：

> 单 Partition 的写是顺序的；**但单 broker 上所有 Partition 的 active segment 加起来，对磁盘来说就是 N 路并发写**。

如果一个 broker 上有 100 个 Partition active，OS 看到的是 100 个文件被同时 append——这从单文件视角是顺序的，从磁盘 head 视角则是 100 路 “伪随机”。

这一点的工程后果：

- **Partition 数太多，顺序写优势退化**。在 HDD 上尤其明显。
- 这是 02 提到“Partition 数有上限”的物理根之一。
- 现代 SSD 没有寻道概念，但仍然有写放大 / GC（这里指 SSD 内部的垃圾回收）问题，Partition 数过多依然会拖性能。

### Segment 大小为什么是 1GB

默认 `log.segment.bytes=1GB`。这是一个工程取舍：

- **太小**（几十 MB）：文件数爆炸 → 句柄数多、目录扫描慢、index 加载多
- **太大**（10GB+）：删除 / compact 粒度变粗 → 即便保留时间到了也得等整段才能删；index 加载慢
- **1GB**：典型负载下，每个段几分钟到几十分钟切一次，删除粒度可接受，文件数可控

短保留 + 高吞吐的 Topic 可以调小（512MB 甚至 256MB），让删除更及时；长保留 + 低吞吐可以调大（4GB），减少元数据负担。

## 第三锤：稀疏索引

### 为什么不是稠密索引

如果每条消息都建索引：

- 内存占用线性于消息数（消息一多就装不下）
- 索引写本身成了性能瓶颈

Kafka 选稀疏索引：

> 大约**每 4KB 数据**写一条索引项，记录 `(offset → 文件物理位置)`。

参数 `index.interval.bytes` 控（默认 4KB）。所以一个 1GB 段大概有 25 万条索引项，每条几个字节——一段索引几 MB，全部 mmap 进 PageCache，访问就是内存随机读。

实际 `.index` 里记录的是**相对 offset**。比如 Segment 文件名是 `00000000000000123456.log`，它的 base offset 是 `123456`；索引里 relative offset `37`，对应的绝对 offset 就是 `123456 + 37 = 123493`。这样索引项可以更小，Segment 文件名负责提供基准点。

### 查找路径

要按 offset 找一条消息：

1. **定位 Segment**：Segment 文件名是它的起始 offset → 对所有 Segment 文件名做二分
2. **定位段内位置**：在该 Segment 的 `.index` 里二分找 ≤ 目标 offset 的最近一条
3. **顺序扫**：从那个文件位置开始往后扫，最多扫 ~4KB 命中目标 offset

每一步都很便宜。即便 Partition 上有几亿条消息，查任一 offset 也是几次内存二分 + 几 KB 顺序扫。

### .timeindex：按时间反查

类似的稀疏映射，`timestamp → offset`，让 “给我 14:00 之后的消息” 这种查询能两级跳转：先 timeindex 找到 offset，再 index 找到位置。Consumer 端通常是先用 `offsetsForTimes` 找 offset，再 `seek` 到对应位置。

### 为什么 index 用 mmap

Kafka 的 index 是 mmap 进进程地址空间的——好处：

- 启动时不用 read 一遍，PageCache 自己懒加载
- 进程崩重启，索引内容还在 PageCache 里
- 二分查找直接在内存上做，不过 syscall

### Segment、retention 和 compact 的关系

Segment 还决定了 Kafka 怎么清理数据。

对普通删除型 Topic，Kafka 不是消费一条删一条，而是按保留策略清理老 Segment：

```text
00000000000000000000.log      过期 -> 删除整个 Segment
00000000000000123456.log      未过期 -> 保留
00000000000000987654.log      active segment -> 继续写
```

所以 retention 的真实粒度是 Segment。即使某些消息已经过期，只要它们还在 active segment 里，也通常要等这个段滚动成老 Segment 后才能被清理。

对 `cleanup.policy=compact` 的 Topic，compact 不是 gzip / zstd 那种压缩体积，而是**按 key 去重保留较新的值**：

```text
k1 -> old value
k2 -> value
k1 -> new value

compact 后最终保留：
k2 -> value
k1 -> new value
```

Log Cleaner 会挑选一批老 Segment，读取其中的 key，合并出较新的记录，写成新的 Segment，再替换旧 Segment。几个边界要记住：

- compact 是后台异步发生的，不是写入后立刻清掉旧值。
- active segment 通常不会马上 compact。
- compact 后也不保证整个 Topic 里永远只有每个 key 一条，只能保证旧版本最终会被清理。
- 如果写入 tombstone，也就是 key 对应 value=null，Kafka 会保留一段删除标记，之后最终把这个 key 清掉。

## 第四锤：PageCache —— Kafka 性能的真正秘密武器

这一节是 Kafka 设计哲学和其他存储系统**最不一样**的地方，也是面试最容易被追问的地方。

### 一个反直觉的事实：Kafka 几乎不维护应用层 cache

对比一下：

| 系统           | 数据缓存在哪                          |
| ------------ | ------------------------------- |
| MySQL InnoDB | Buffer Pool（应用层，自己管理）           |
| Redis        | 进程堆内（数据本身就在内存）                  |
| HBase        | BlockCache（应用层）                 |
| **Kafka**    | **PageCache（OS 内核，Kafka 完全不管）** |

Kafka 没有 Buffer Pool。它写的时候写到 PageCache、读的时候读 PageCache，**完全把缓存委托给 OS**。

### 为什么 Kafka 不自己做 cache

四个原因：

1. **JVM 堆是性能毒药**。Kafka 是 JVM 语言写的，如果数据进堆，几亿条消息直接把堆撑爆，GC 卡到天荒地老。
2. **PageCache 是免费的**。OS 本来就有，Kafka 不用，反而是浪费。
3. **PageCache 跨进程重启保留**。broker 重启 PageCache 里还有数据；自管 cache 重启就空了，要预热。
4. **OS 的 LRU / prefetch 已经很优**。Kafka 自己重写未必更好。

代价：**broker 的“可用内存”观感会很奇怪**。你看监控，broker JVM 堆只用 4GB、机器内存 64GB——“怎么内存没用完？” 用完了，剩下的全是 PageCache，**这就是 Kafka 设计要的**。

### 为什么 Kafka 不靠 fsync

`Log.append` 写完 PageCache 默认就返回。**默认不强制刷盘**：

- `log.flush.interval.messages`：LONG_MAX（不主动）
- `log.flush.interval.ms`：null（不主动）

这两条配置默认值看起来很激进。但 Kafka 的承诺方式是：

> **不靠每次写都 fsync，而是靠副本机制。**

只要 `acks=all` + `replication.factor≥3` + `min.insync.replicas≥2`，一条消息在 ack 返回前已经在至少 2 台机器的 PageCache 里。要丢这条消息得**同时**两台机器掉电——这个概率比 fsync 慢上 10 倍带来的吞吐损失更划算。

这就是 03 强调的：

> **Kafka 的"快"和"不丢"是两条不同的设计线：快靠顺序写 + PageCache + 零拷贝；不丢靠 Replica + ISR。**

### Producer 写 vs Consumer 读：天作之合

Kafka 的典型负载里，Consumer 通常**紧跟着** Producer 读最新消息。一条消息刚被 Producer 写到 Leader 的 PageCache，几十毫秒后 Consumer 来 fetch——大概率直接命中 PageCache，**根本不碰磁盘**。

这就是 Kafka 在大流量下还能保持低延迟的关键：**绝大多数读是热读，从内存直接出。**

只有 Consumer 大幅落后（“catch-up consumer”，比如重放历史、新下游从头开始）时，才会去碰磁盘。这种 cold read 也是 Kafka 性能突然下降的常见诱因。

## 第五锤：零拷贝（sendfile）

### 传统路径有多浪费

一个 broker 把消息从磁盘发给 Consumer，传统 `read + write` 路径：

```
1. read():  磁盘 → kernel buffer (DMA copy)
2. read():  kernel buffer → user buffer (CPU copy) ←── 浪费
3. write(): user buffer → socket buffer (CPU copy) ←── 浪费
4. write(): socket buffer → NIC (DMA copy)
```

**4 次拷贝 + 2 次上下文切换**（用户态 ↔ 内核态各一次往返）。其中第 2、3 次是纯浪费——broker 根本不需要看消息内容，只是搬运工。

### sendfile 砍掉浪费

Linux 的 `sendfile(out_fd, in_fd, ...)` 系统调用：

```
1. 磁盘 → kernel buffer (DMA copy)
2. kernel buffer → NIC (DMA copy，配合 scatter-gather DMA 还能避免实际拷贝，只传指针)
```

**2 次拷贝 + 1 次上下文切换**。Kafka 在 Consumer fetch 路径上用 `FileChannel.transferTo()`，底层就是 `sendfile`。这是 Kafka 单 broker 能扛几个 G/s 吞吐的硬件级原因。

### 零拷贝什么时候**失效**

这一点是面试和生产都最有价值的部分：

**失效 1：开 TLS / SSL**

零拷贝只能把字节原样从 PageCache 转到 NIC，**不能加密**。一旦启用 SSL，数据必须经过用户态加密，sendfile 走不通。

> 生产观察：开 SSL 后单 broker 吞吐通常掉 30%~60%，CPU 也涨。
>
> 解法：要么用专门的 SSL 卸载（kTLS）、要么把传输加密放到下层（VPN）、要么接受这个代价。

**失效 2：开消息压缩但 broker 端要解压**

Kafka 的压缩是“**Producer 压、Consumer 解、broker 不动**”——broker 拿到压缩字节就落盘，发给 Consumer 时也是压缩字节，零拷贝仍然成立。

但**如果配了 broker 端 message format 转换**（Producer 用新版本格式、Consumer 是老版本 client，broker 要做格式转换），broker 就要解压、重新组装、重压——零拷贝失效。这是为什么 Kafka 大版本升级时建议 Producer / Broker / Consumer 一起推进。

**失效 3：跨段读 / 不对齐**

`sendfile` 一次只能传一个文件。跨 Segment 边界的请求 broker 要拆成多个 sendfile。这是损耗但不算“失效”。

### `mmap` vs `sendfile` 的分工

Kafka 在两个地方分别用：

- **`mmap`**：index 文件（小、随机访问、要 binary search）
- **`sendfile`**：log 文件（大、顺序传给 Consumer）

不混用。index 不会 sendfile（不需要发给客户端），log 不会 mmap（一是大、二是顺序读用不上 mmap，三是 mmap 写会让 OS 不太好控刷盘时机）。

## 第六锤：Batch + Compression + Pipelining 协同

到这里讲完了存储侧的“硬”优化。还剩三个**协议侧**的优化，是同等重要的速度来源。

### Batch

Producer 端把消息按 `(topic, partition)` 分桶累积，到 `batch.size` 或 `linger.ms` 才发。

效果：

- **网络层**：N 条消息合成 1 个请求 → broker 端只处理一次握手、一次响应、一次 ack
- **存储层**：N 条消息合成 1 次 append → 一次 PageCache 写
- **副本层**：Follower 一次 fetch 拉一批 → 副本同步效率拉满

**没 batch 的 Kafka 大概比 batch 满了的慢 5~10 倍**。这是为什么 `linger.ms=0`（默认）的高 QPS 场景可以微调到 5~20ms 换来巨幅吞吐。

### Compression

Producer 端把整个 batch 一起压缩，broker 不解压、直接落盘和转发，Consumer 端解压。

几个事实：

- **压缩在 batch 上做**，单条消息压不出多少；batch 越大压缩比越高 → batch + compression 是一对
- **broker 端 CPU 几乎不增加**，因为不解压
- 算法选择：

| 算法 | 压缩比 | CPU | 备注 |
|---|---|---|---|
| `none` | 1× | 0 | 网络带宽充裕时可用 |
| `gzip` | 高 | 重 | 压缩比好但 CPU 贵 |
| `snappy` | 中 | 轻 | 老牌默认，速度好 |
| `lz4` | 中 | 轻 | 速度极快 |
| `zstd` | 高 | 中 | **2.1+ 后的甜区**，压缩比接近 gzip、速度接近 lz4 |

> 经验法则：现代集群直接 zstd。除非有 CPU 紧张或者带宽过剩。

### Pipelining

`max.in.flight.requests.per.connection` 默认 5，意思是一个 TCP 连接上**允许 5 个 batch 同时在飞**（已发未 ack）。

效果：

- 网络 RTT 被掩盖。第 1 个 batch 还在等 ack，第 2~5 个已经在发。
- 单连接吞吐接近网卡上限。

代价（前面讲过）：**没开幂等的情况下，`max.in.flight > 1` 会让重试乱序**。所以现代用法是 `enable.idempotence=true` + `max.in.flight ≤ 5` 一起开（**幂等 Producer 强制要求 max.in.flight ≤ 5**）。

## 协同效应：一项失效会有多大影响

Kafka 的快不是某一项的功劳，是一组协同。我们做个思维实验，看每一项单独失效会怎样：

| 失效项 | 影响 |
|---|---|
| 没顺序写（随机写） | 磁盘吞吐掉 10~100× |
| 没 PageCache（直接 O_DIRECT） | Consumer 读全走磁盘，cold read 暴增 |
| 没零拷贝（开 SSL） | 吞吐掉 30%~60%，CPU 暴涨 |
| 没 Batch（`batch.size=1`） | Producer 吞吐掉 5~10×、broker QPS 暴涨 |
| 没 Compression（带宽不富裕时） | 网络打满，吞吐被网卡锁死 |
| 没 Pipelining（`max.in.flight=1`） | 网络 RTT 直接成为吞吐瓶颈 |
| Partition 太多（顺序写退化） | 单机吞吐随 Partition 数下降 |

**这就是为什么 Kafka 的性能是“一组协同”，而不是“一个银弹”。** 任何一项被破坏，对应的那部分优化就垮了。

## 生产高频问题与解法

**问：“broker 内存只用了 30%，是不是该缩容？”**
不是。Kafka 故意让 JVM 堆小（典型 6~12GB），剩下全留给 PageCache。监控里堆使用率不高是设计目标，看 PageCache 命中率才是关键。一般要看 OS 层面 `cached` 字段或 `vmstat`。

**问：“我升级到 SSD 没变快。”**
大概率瓶颈不在磁盘。Kafka 顺序写在 HDD 上就能跑很快。SSD 主要救的是 **catch-up consumer**（cold read 大量走磁盘的场景）和 **高 Partition 数下的多路并发写**。如果你只是热读热写，SSD 提升有限——瓶颈通常是网络 / CPU（特别是开了 SSL/压缩转换）。

**问：“开了 SSL 后吞吐掉一半。”**
正常。零拷贝失效 + 加密 CPU 开销。能接受就接受；想救：升级到 kTLS、或者用更轻的认证（SASL_PLAINTEXT + VPN）。

**问：“某些消费者很慢，整个 broker 都被拖慢。”**
catch-up consumer 在读老段，**不命中 PageCache**，触发磁盘随机 IO，把磁盘带宽吃光。解法：限速这种消费者（`fetch.max.bytes`）、或者用 quota 配额、或者把它们放到副本机器（KIP-392 follower read）。

**问：“Partition 加到几千以后吞吐反而下降。”**
顺序写退化。每个 Partition 一个 active segment，broker 看到的是几千路并发 append。HDD 上几百就开始痛，SSD 上能撑到几千但不是无限。**Partition 数是要管理的资源，不是越多越好**。

**问：“broker 启动后头几分钟很慢。”**
PageCache 是冷的，读老数据都走磁盘。等热数据慢慢被回填。这就是“PageCache 跨进程重启保留”的反面——**OS 重启**（不是进程重启）会真清掉 PageCache。所以滚动重启时要看 ISR 抖动控住节奏。

**问：“GC 一卡，ISR 就抖。”**
JVM Full GC 期间，broker 既不能服务 Producer 也不能服务 Follower fetch。Follower 拉不到数据 → 落后超 `replica.lag.time.max.ms` → 被踢 ISR。解法：堆调小（6~12GB）、用 G1 / ZGC、监控 GC pause、必要时换 JVM 参数。

**问：“为什么 Kafka 推荐 XFS / ext4 而不是 ext3？”**
ext3 的 metadata journal 比较吃磁盘。XFS 在大文件、append 多的场景表现最稳定。ZFS 不建议（它的 ARC 会和 PageCache 抢内存，复杂度高）。

## 这一篇要带走的结论

- **顺序写**真正的功劳是“让磁盘头几乎不动”——但 Partition 太多会破坏这点
- **PageCache** 是 Kafka 性能的真正秘密武器，Kafka 故意不做应用层 cache，把内存让给 OS
- Kafka **不靠 fsync 不丢**，靠副本不丢——这是和 MySQL 完全不同的哲学
- **零拷贝（sendfile）** 在 SSL 和消息格式转换下会失效，是开 SSL 后吞吐掉一半的根因
- **Batch + Compression + Pipelining** 是协议层的快，没有它们存储层再快也撑不起整体性能
- Kafka 的快是一组**协同**——任意一项失效都会让整体退化一个量级
- 生产上**瓶颈通常不在磁盘**，而在网络、SSL CPU、catch-up consumer、Partition 数、GC

---

下一篇 `05_副本与一致性：Leader_Follower_ISR_HW_LEO_LeaderEpoch.md`，把 03 链路里 ⑩⑪⑫ 三道关放大，专挖 Kafka 的副本一致性模型——ISR 怎么动、HW 怎么推、LEO 是谁的、Leader Epoch 到底补的是什么坑。这一篇是 Kafka 设计美感最集中的一章。
