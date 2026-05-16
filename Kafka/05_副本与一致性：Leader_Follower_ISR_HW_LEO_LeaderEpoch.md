# 副本与一致性：Leader / Follower / ISR / HW / LEO / Leader Epoch

## 这一篇要回答什么

这一章是整个 Kafka 设计里**最有美感、也最容易被讲糊**的一章。讲清楚要回答 8 个递进的问题：

1. 为什么是 Leader / Follower 不对称——Follower 为什么不能服务读？
2. LEO、HW、Committed Offset 三者到底什么关系？
3. ISR 这个抽象在堵哪个洞？为什么不是“所有副本”？
4. `acks=all` + `min.insync.replicas` + `replication.factor` 必须三件配齐，少一件会发生什么？
5. HW 推进是“同步”的还是“延迟”的？这一点怎么影响 read-your-writes？
6. 光靠 HW 截断为什么会丢数据？**Leader Epoch 到底补了什么坑**？
7. `unclean.leader.election.enable` 关掉和开掉的工程后果分别是什么？
8. 生产上 ISR 频繁抖动，先查什么、怎么治？

学完应该能在面试里把 KAFKA-3514（HW 截断错位）那个经典 bug 用一支笔在纸上画给面试官。

## 起点：副本是为了挡 broker 单点

Kafka 整个副本设计的起点很朴素：**broker 会挂、磁盘会坏、机房会断电**。单 Partition 在一台机器上等于单点。

解法是为每个 Partition 维护 N 个副本（`replication.factor`，默认建议 3）。N 个副本分布在不同 broker 上（最好不同机架，配 `broker.rack` + `RackAwareReplicaAssignment`）。

> 副本是 **Partition 级别**的，不是 Topic 级别的。同一个 Topic 不同 Partition 的 Leader 分散在不同 broker，副本分布也独立——这是 Kafka 横向扩 Leader 写流量的根。

但“多副本”只是开始。多副本会立刻引出几个新问题：

- 谁负责读写？读写如果都走 Leader，Follower 干嘛？
- 副本之间怎么同步？强同步还是异步？
- 写要等几个副本 ack 才算成功？
- 副本之间数据可能短暂不一致，消费者会不会读到“将要丢失”的数据？
- Leader 挂了，新 Leader 怎么选才能不丢？

这一篇把这些问题挨个拆。

## Leader / Follower 不对称：为什么 Follower 不能服务读

**Leader 服务所有读写**，Follower 只做一件事：从 Leader 拉数据。

很多人第一反应是“Follower 闲着干嘛不让它分担读”。Kafka 的设计哲学很明确：

| 设计 | 优点 | 代价 |
|---|---|---|
| 读写都走 Leader（Kafka 选） | 强一致：客户端永远看到的是 Leader 的最新可见状态；Follower 实现极轻 | Leader 是热点 |
| Follower 可读 | 减少 Leader 压力 | Follower 落后于 Leader，可能读到“即将被回退”的数据；需要更复杂的一致性协议 |

Kafka 直到 2.4 才开了一个口子（KIP-392），允许 Consumer **从最近的 Follower 拉取**（典型用于跨 AZ 省带宽），且默认关闭。设计本质没变：

> Kafka 的横向扩，不是单 Partition 多读副本，而是**多 Partition × Leader 在 broker 间分散**。

每个 broker 都是“某些 Partition 的 Leader”、“另一些 Partition 的 Follower”。一台 broker 上 Leader 数据均匀分布时，读写压力天然摊平。

## 三个 offset：LEO、HW、Committed

讲一致性前要先把三个 offset 画清。它们经常被混在一起，混了之后所有讨论都糊。

### LEO（Log End Offset）

> **每一个副本（Leader 也算）都各自有自己的 LEO**。LEO = 该副本的日志末尾位置 = 下一条要写入的 offset。

- Leader 的 LEO：Leader 刚 append 完一条新消息，自己的 LEO 就推进
- Follower 的 LEO：Follower 把刚拉到的消息写到自己的日志后，自己的 LEO 也推进

LEO 是“**这个副本知道的最新进度**”，是**副本本地**视角。

### HW（High Watermark）

> **每一个 Partition 有一个 HW，存在 Leader 那里**。HW = **ISR 内所有副本 LEO 的最小值**。

- Leader 通过 follower 来 fetch 时上报的 LEO，得知每个 follower 的进度
- 取 ISR 内所有副本 LEO 的最小值，就是 HW
- HW 是“**这条消息已经在 ISR 内全部副本都落地**”的承诺线

**消费者只能读到 HW 之前的消息**（在 `read_uncommitted` 默认下；事务消息还有 LSO 单独限制，08 讲）。HW 之后的消息可能还在某些副本上没落地，万一 Leader 挂被选主、新 Leader 没这些消息，原来读到的消息会“消失”——为了避免幻象，Kafka 干脆**不让消费者看到 HW 之后**。

### Committed Offset

> **每一个 Consumer Group 在每一个 Partition 上有一个 Committed Offset**，存在 `__consumer_offsets`。

这是消费侧的 offset，和副本一致性是两件事。注意不要把“**消息被提交（committed by replicas）**”和“**消费者提交 offset（committed by consumer）**”混为一谈——前者指 HW 推进过，后者指 Consumer 写了 `__consumer_offsets`。

### 三者关系

```
（Leader 视角）
  ┌─────────────────────────────────────┐
  │ Log:  [m0][m1][m2][m3][m4][m5][m6]  │
  └─────────────────────────────────────┘
                            ▲           ▲
                            │           │
                          HW=5        LEO=7
                  （ISR 都到了）   （Leader 自己的末尾）

  消费者最多能读到 offset=4（HW 之前）
  Consumer Group 自己 commit 到哪：另一回事
```

一句话总结：

- **LEO**：每个副本自己的“写到哪了”
- **HW**：Partition 维度的“安全到哪了”
- **Committed Offset**：Consumer 自己提交的“读到哪了”

## ISR 是什么、为什么不是“所有副本”

ISR（In-Sync Replicas）= **当前跟上了 Leader 进度的副本集合**，包含 Leader 自己。

为什么不直接等“所有副本”都 ack？

> 因为副本里**总会有慢的**。如果等所有副本，写延迟就被最慢的那个拖死。慢副本（GC 中、磁盘忙、网络抖）应该被**临时排除在外**，而不是拖累整个集群。

ISR 就是“**当前还跟得上的副本组**”：

- Follower 跟得上（在 `replica.lag.time.max.ms`，默认 30s 内追上 Leader 的 LEO）→ 留在 ISR
- Follower 跟不上（超过 30s 没追上）→ 被 Leader 踢出 ISR
- 被踢出后，恢复跟进度后还可以重新加回

`acks=all` 等的是“**ISR 内所有副本都 ack**”，**不是“所有 Replica 都 ack”**。

### 历史脚注：`replica.lag.max.messages` 为什么被废了

老版本 Kafka 还有个参数 `replica.lag.max.messages`：follower 落后 Leader 超过 N 条就踢出 ISR。这个参数在 0.9 被移除，只剩 `replica.lag.time.max.ms`。

为什么？因为它在**突发写**下会假阳性：

> Producer 突然来一波 burst，几秒钟写了 10 万条。Leader 写得飞快，所有 follower 临时落后 ≥ 4000 条。Leader 把所有 follower 全踢出 ISR，瞬间剩自己一个。

时间维度的判断更稳定：“30 秒内你能追上来就行，不在乎瞬时落后多少条”。这是 Kafka 副本设计里非常工程化的一个改动。

## `acks` + `min.insync.replicas` + `replication.factor` 三件套

这三个配置必须**配齐**才有意义。任一项错配，整套防线就形同虚设。

### `acks` 三档的精确语义

- `acks=0`：Producer 发完立刻当成功，**broker 收没收到都不管**。最快，但 broker 挂、网络丢都直接丢消息。
- `acks=1`：**Leader 写到 PageCache 就 ack**（不等任何 follower）。一种"看起来还行"但有隐患的语义——Leader 刚 ack 完就挂、follower 还没来得及同步，消息丢。
- `acks=all`（或 `-1`）：**等 ISR 内所有副本都同步过这条消息**才 ack。

### `min.insync.replicas` 限定 ISR 下限

`min.insync.replicas=2` 的意思：

> Partition 的 ISR 大小 ≥ 2 才允许写。否则 Leader 直接拒写，抛 `NotEnoughReplicasException`。

为什么需要这个？考虑场景：

- `replication.factor=3`、`acks=all`、**没配 min.insync**
- ISR 缩到只剩 Leader 一个（其他 follower 都被踢出）
- 此时 `acks=all` 等的就是“ISR 内全部都 ack”，但 ISR 只有 Leader → 等于退化成 `acks=1`
- Leader 一挂，没有任何 follower 持有最新数据 → 丢

`min.insync.replicas` 就是堵这个洞：**ISR 不够，宁可不收也不假装写成功**。

### 三件套的典型组合

```
replication.factor   = 3   ← 部署 3 副本
min.insync.replicas  = 2   ← ISR 至少 2 个才能写
acks                 = all ← Producer 等 ISR 全部 ack
```

这是“**不丢已 ack 消息**”的工程下限。少一件都不行：

| 错配 | 后果 |
|---|---|
| `RF=3, acks=1` | Leader ack 完挂 → 丢 |
| `RF=3, acks=all, min.insync=1` | ISR 缩到只剩 Leader 仍能写 → 退化成 acks=1 |
| `RF=3, acks=all, min.insync=3` | 一个 broker 挂就拒写（ISR 必须满员）→ 牺牲可用性 |
| `RF=2, acks=all, min.insync=2` | 滚动重启时必然短暂不可用（拿走一台 ISR 就只剩 1） |

> 经验法则：**RF=3, min.insync=2, acks=all**。RF=2 的搭配几乎都有坑，不推荐。

## HW 推进是延迟的：一个微妙的事实

讲到这里要点出 HW 模型一个**经常被忽略但很重要**的细节：

> **HW 的推进是延迟的**——延迟一个 Fetch 周期。

为什么？看 follower 怎么告诉 Leader 自己 LEO：

```
T0:  Leader 写一条新消息 → Leader LEO=101
T1:  Follower 发 fetch(from=100) → 拉到这条消息 → Follower LEO=101
     这次 fetch request 里 follower 上报的是它**之前**的 LEO=100
T2:  Follower 处理完，下次 fetch(from=101)
     这次 fetch request 里 follower 上报 LEO=101
T3:  Leader 收到 T2 的 fetch，发现 follower 已到 101 → 推进 HW=101
```

也就是说，**HW 推进总是慢一拍**——总是依赖**下一次** fetch 才能知道上次 fetch 真的把数据落了。

工程后果：

- 消费者读到的“最新可见”比 Leader 实际写入位置**永远落后一个 Fetch 周期**。一般几毫秒~几十毫秒。
- 在 Leader 切换的极端时序里，这个延迟正是 KAFKA-3514 的祸根。

## Leader Epoch：补 HW 截断的漏洞

到这里要直接讲 Kafka 0.11 引入的 Leader Epoch。这是 Kafka 副本设计里**最精彩的一处补丁**。

### 没有 Leader Epoch 时的经典 bug 场景

考虑 RF=2，副本 A、B：

```
T0:  Leader=A，ISR={A,B}
     A.LEO=10, B.LEO=10, HW=10
T1:  Producer 写一条消息 → A 写下 offset=10（注：从 0 起算这是第 11 条），A.LEO=11
     此时 HW=10（还没等 B fetch 上来）
T2:  B fetch(from=10) → 拉到 offset=10 这条 → B.LEO=11
     **但 B 还没下次 fetch，所以 Leader A 还没把 HW 推到 11**
     此时 A.HW=10, B 上的 HW 也还是 10（B 的 HW 是 Leader 在 fetch response 里告诉它的）
T3:  B 崩了
T4:  B 重启 → 作为 follower 启动 → **按 HW 截断自己的日志**
     B 上的 HW=10 → B 把 offset=10 那条**截掉**，B.LEO=10
T5:  A 也崩了
T6:  Controller 看到 A 挂、ISR 里只剩 B → 选 B 当 Leader
     B 当 Leader，LEO=10，HW=10
T7:  Producer 写新消息 → B 写 offset=10（覆盖了原本的内容）
T8:  A 恢复，作为 follower 来 fetch
     A 的 LEO=11，B 的 LEO 已经 11，但 offset=10 这一条**内容不一样**了
     这就出现了**两个副本日志在同一 offset 上内容不同**的不一致
```

更狠的版本：上面这条 offset=10 已经被 Producer ack（因为它在 A、B 上都落地过）→ **ack 过的消息丢了 / 错了**。

### Leader Epoch 怎么补

引入一个递增数字：**Leader Epoch**。每次 Leader 切换，Controller 把这个 Partition 的 Epoch +1，并把 `(epoch, start_offset)` 的映射持久化到副本本地的 `leader-epoch-checkpoint` 文件里。

Follower 重启 / 切换时，不再用 HW 截断，而是问 Leader：

> 我手上 Epoch=E 的最后一个 offset 是多少？

Leader 用 `leader-epoch-checkpoint` 查 E 这个 epoch 的有效范围，告诉 Follower 一个准确的截断点。这个截断点是“**当前 Leader 持有的、和 follower 这个 Epoch 兼容的日志末尾**”，而不是“**follower 自己的 HW**”。

回到刚才的 bug 场景：

- B 重启时不再无脑用 HW 截，而是发 OffsetsForLeaderEpoch 请求问 Leader
- B 会发现自己持有的 Epoch=0 的最后 offset 是 11，没必要截到 10
- 即便走到 T7（B 当 Leader），新写的消息会用 Epoch=1，**和 Epoch=0 的日志区分开**——后续 A 来同步时能基于 Epoch 边界精确对齐

> **一句话：HW 是“数据安全”的承诺，但它在 Leader 切换瞬间的延迟会让"截断"操作误伤已 ack 数据；Leader Epoch 是给"截断"操作加了一个版本号锚点。**

这是 Kafka 设计里非常少见的“事后补丁补得很优雅”的案例。0.11 之后默认开启，**不要关**。

## `unclean.leader.election.enable`：可用 vs 不丢的权衡

最后一个关键开关：

- **关掉（默认 false）**：只能从 ISR 里选新 Leader。如果 ISR 空了（所有 ISR 都挂了），**Partition 就不可用**，等到 ISR 副本回来。
- **开掉**：ISR 空了时允许从“**非 ISR 副本**”里选新 Leader——但那些副本本来就跟不上 Leader 的进度，会**丢已 ack 数据**。

工程取舍：

- 数据强敏感场景（金融、订单、计费）→ **关**。宁可短暂不可用。
- 日志 / 监控 / 行为埋点 → 可以**开**。可用性优先，丢点点也能接受。

老版本 Kafka 默认是开的，0.11+ 改成默认关。生产建议保持默认关。

## 生产高频问题与解法

**问：“ISR 抖动很厉害（follower 反复被踢和加回），怎么查？”**
先看四个方向，顺序：

1. **JVM GC**：broker 长 GC 期间 follower fetch 卡住或 leader 处理 fetch 慢 → 被踢。看 GC 日志。
2. **磁盘 IO**：磁盘忙（catch-up consumer、压缩、其他进程）→ follower 写日志慢 → 被踢。看 `iostat`、`%util`。
3. **网络**：网络抖动 / 限速 → follower 拉慢。看丢包、`ss -i`、网卡饱和。
4. **副本拉取线程数不够**：`num.replica.fetchers` 默认 1，**对 Partition 数多的集群明显偏少**。调到 4~8 是常见做法。

**问：“`min.insync.replicas` 配成几比较好？”**
RF=3 的话，配 2。配 3 就等于 “一台 broker 挂就拒写”，可用性太差。RF=5 可以配 3。

**问：“`replica.lag.time.max.ms` 该不该调大？”**
默认 30s 已经偏宽。短了会假阳性踢，**长了 ISR 抖动“看起来稳了”但实际容错变弱**——一个早已死掉的副本被当成"还在 ISR" 30 秒，期间 `acks=all` 还在等它 ack。一般保持默认。

**问：“Controller 切换时 ISR 大面积抖，正常吗？”**
正常。新 Controller 上来要重建所有 Partition 的状态，期间 LeaderAndIsr 请求洪水般下发，broker 处理过程中短暂卡顿是常见的。这是 ZK 时代 Controller 模型的痛点之一，KRaft 改善了很多（06 会讲）。

**问：“能不能把 follower 也用上分担读？”**
有限度可以——KIP-392 让 Consumer 按 rack 就近读 Follower，省跨 AZ 流量。但**默认是关的**，开启需要配 `client.rack` + broker 端 `replica.selector.class`，且只缓解读流量、不缓解 Leader 写压力。

**问：“RF=2 行不行？”**
强烈不建议。RF=2 + min.insync=2 → 一台 broker 重启就拒写；RF=2 + min.insync=1 → 退化到 acks=1。RF=2 在 Kafka 的副本模型下没有甜区。

**问：“跨机房副本怎么部署？”**
两种思路：

1. **同集群跨机房**（RF=3 三机房放一个）：要配 `broker.rack` + rack-aware assignment，让每个 Partition 的 3 副本散在 3 机房。代价：写延迟受跨机房 RTT 影响，跨机房带宽吃得多。
2. **跨集群复制（MirrorMaker2）**：每个机房独立 Kafka 集群，靠 MM2 异步复制。代价：异步会丢，offset 不能直接迁移。

绝大多数公司选 2。1 只在“同城两机房、RTT < 2ms”才比较舒服。

**问：“怎么知道一条已 ack 的消息真的安全了？”**
真正的"已提交"定义：**HW 推进过它**。Producer 收到 ack 时，broker 已经把这条消息计入 ISR 同步，但 ack 后**不代表所有副本都磁盘 fsync**。极端场景（整机房断电）仍可能丢——这是 Kafka 副本模型的承诺边界。要更强保证需要 `flush.messages=1`，代价是吞吐崩。

## 这一篇要带走的结论

- **LEO 是副本本地的“写到哪了”、HW 是 Partition 维度的“安全到哪了”、Committed Offset 是 Consumer 的“读到哪了”**，三者不要混
- **ISR 是 Kafka 写一致性的灵魂**——它让“慢副本不拖死写”和“不丢已 ack 消息”同时成立
- `acks=all` + `min.insync.replicas=2` + `replication.factor=3` **必须配齐**，任一错配整套防线就垮
- **HW 推进延迟一个 Fetch 周期**——这是 Leader 切换时数据不一致的根源
- **Leader Epoch 用版本号给“截断”加了锚点**，0.11 后默认开，不要关
- `unclean.leader.election` 是“可用 vs 不丢”的开关，金融类场景必须关
- ISR 抖动先查 GC / 磁盘 / 网络 / `num.replica.fetchers`
- RF=2 在 Kafka 副本模型里没有甜区

---

下一篇 `06_Controller与元数据：从ZooKeeper到KRaft的演进与动机.md`，把视角从“一个 Partition 的副本”拉到“整个集群的元数据管理”——Leader 是谁、ISR 是谁、Topic 配置是什么，这些信息怎么在集群里传播？为什么 Kafka 当初用 ZK、后来又非要去掉它？KRaft 解决了什么具体痛点？
