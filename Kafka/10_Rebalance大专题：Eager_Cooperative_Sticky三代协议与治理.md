# Rebalance 大专题：Eager / Cooperative / Sticky 三代协议与治理

## 这一篇要回答什么

Rebalance 是 Kafka Consumer Group 最强也最疼的机制。

它强在：Consumer 挂了、扩容了、订阅变化了，Kafka 能自动把 Partition 重新分给活着的 Consumer，消费能继续。

它疼在：线上一次普通发布、一次 GC、一次网络抖动，都可能让整个 Consumer Group 反复 JoinGroup / SyncGroup，消费停顿、lag 暴涨、重复消费增加。

这一篇专门回答 8 个问题：

1. Rebalance 到底是什么，不要只说“重新分配分区”。
2. 哪些事件会触发 Rebalance？
3. 一次 Rebalance 的完整流程是什么？
4. Eager Rebalance 为什么是 Stop-The-World？
5. Sticky Assignor 解决了什么，没解决什么？
6. Cooperative Rebalance 为什么是增量迁移，为什么也不是银弹？
7. Static Membership 能减少哪类 Rebalance？
8. 线上 Rebalance 风暴怎么定位、怎么治理？

先给结论：

> Rebalance 的本质是 **Consumer Group 成员集合或订阅集合变化后，重新建立 Partition 所有权的协议**。Eager 方案简单但全量撤销，Sticky 减少迁移但仍会停顿，Cooperative 把全量撤销改成增量撤销。治理 Rebalance 风暴，要同时看发布方式、心跳、`max.poll.interval.ms`、GC、分配策略、静态成员、offset 提交和业务处理耗时。

## Rebalance 到底在平衡什么

Consumer Group 的核心约束是：

> 同一个 Group 内，一个 Partition 同一时刻只能被一个 Consumer 拥有。

当组成员变化时，原来的分配可能不再成立：

```text
原来：
C1 -> p0, p1
C2 -> p2, p3

现在 C3 加入：
C1 -> ?
C2 -> ?
C3 -> ?
```

Rebalance 要重新确定：

- 哪些 Consumer 是组成员。
- 每个 Consumer 订阅哪些 Topic。
- 这些 Topic 当前有哪些 Partition。
- 每个 Partition 最终归谁。
- 原持有者什么时候停止消费。
- 新持有者从哪个 offset 开始消费。

所以 Rebalance 不是一个单纯的“数学分配函数”，而是一整套所有权转移协议。

它必须保证：

- 一个 Partition 不会同时被两个 Consumer 消费。
- Consumer 离开后，它的 Partition 能被别人接手。
- 接手者能从已提交 offset 继续读。
- 分配方案在所有成员之间一致。

## 哪些事件会触发 Rebalance

常见触发源有 8 类。

### 1. Consumer 新加入

扩容、发布新实例、应用重启后重新加入 Group。

```text
C1, C2 稳定消费
C3 启动并 JoinGroup
触发 Rebalance
```

### 2. Consumer 离开

正常关闭时调用 `consumer.close()`，会主动 LeaveGroup，Coordinator 触发 Rebalance。

如果进程被 kill、机器宕机、网络断开，则 Coordinator 要等 `session.timeout.ms` 超时后才认为它离开。

### 3. Consumer 心跳超时

超过 `session.timeout.ms` 没收到 Heartbeat。

常见原因：

- JVM Full GC。
- 容器 CPU 被 throttling。
- 网络抖动。
- Coordinator broker 抖动。
- 应用线程被卡住，老版本客户端心跳也受影响。

### 4. 两次 poll 间隔太久

超过 `max.poll.interval.ms`。

这说明 Consumer 还活着，但业务处理太久没回到 `poll()`，Kafka 认为它不适合继续占有 Partition。

常见原因：

- 单批拉太多。
- 下游 RPC 慢。
- DB 慢查询。
- 线程池排队。
- 业务逻辑偶发卡死。

### 5. 订阅 Topic 变化

Consumer 调整订阅集合，或者使用正则订阅时新 Topic 被创建。

```java
consumer.subscribe(Pattern.compile("order-.*"));
```

一旦匹配到新 Topic，Group 订阅的 Partition 集合变化，就需要 Rebalance。

### 6. Topic Partition 数变化

Topic 增加 Partition 后，Consumer Group 需要重新分配新增 Partition。

注意：Kafka Partition 只能增加不能减少。增加 Partition 会触发 Rebalance，也可能改变部分分配。

### 7. Coordinator 切换

Group Coordinator 所在 broker 挂了，`__consumer_offsets` 对应 Partition 选出新 Leader。Consumer 要重新 FindCoordinator、JoinGroup。

### 8. 订阅元数据变化

比如权限、Topic 删除、metadata 刷新发现分区集合变化，也可能间接触发。

## 一次 Rebalance 的完整流程

以经典 Group 协议为例：

```text
1. Coordinator 发现需要 Rebalance
   成员加入 / 离开 / 超时 / 订阅变化

2. Coordinator 标记 Group 为 PreparingRebalance
   新的 Heartbeat 会被告知需要重新加入

3. 所有成员发送 JoinGroup
   带上 member.id、订阅信息、支持的 assignor

4. Coordinator 选出 Group Leader
   这是 Consumer 里的 leader，不是 broker leader

5. Group Leader 计算 assignment
   根据成员列表、Topic Partition、assignor 算分配

6. Group Leader 发送 SyncGroup
   把分配结果交给 Coordinator

7. Coordinator 向所有成员返回各自 assignment

8. Consumer 执行 onPartitionsRevoked / onPartitionsAssigned 回调
   停止旧分区、提交 offset、初始化新分区状态

9. Group 进入 Stable
   Consumer 继续 Fetch
```

这套流程的关键点是：**所有成员必须参与**。只要有成员卡住、没及时 JoinGroup、网络慢，整个 Group 进入 Stable 的时间就会变长。

## Eager Rebalance：简单但全组停顿

早期 Kafka 的 Rebalance 是 Eager 模式。

Eager 的规则很粗暴：

> 一旦 Rebalance，所有 Consumer 先撤销自己当前持有的全部 Partition，然后等新方案下发，再重新领取 Partition。

图像是：

```text
稳定状态：
C1 -> p0, p1
C2 -> p2, p3

C3 加入，触发 Eager Rebalance：
C1 revoke p0, p1
C2 revoke p2, p3
全组停止消费

新方案：
C1 -> p0
C2 -> p1
C3 -> p2, p3
```

问题在于：即使某些 Partition 最终还归原 Consumer，它也要先撤销再重新分配。

比如新方案里 p0 仍然归 C1，Eager 仍然会让 C1 停止 p0 的消费。这就是 Stop-The-World。

### Eager 的优点

- 协议简单。
- 所有权清晰，不容易出现一个 Partition 两个 Consumer 同时处理。
- 各类 Assignor 都容易实现。

### Eager 的代价

- Rebalance 期间全组停顿。
- Partition 多时 revoke / assign 成本大。
- State 初始化重，比如本地缓存、状态存储、连接、预热都要重来。
- 发布和扩容会造成 lag 锯齿。
- 频繁 Rebalance 时，Group 可能长期不稳定。

这就是为什么 Rebalance 在生产上被称为 Kafka Consumer 的“大疼点”。

## Assignor：谁决定分配方案

分配策略由 Consumer 客户端配置：

```properties
partition.assignment.strategy=...
```

常见策略：

| 策略 | 特点 |
|---|---|
| RangeAssignor | 每个 Topic 内按 Partition 范围分配，简单，但多 Topic 时可能不均 |
| RoundRobinAssignor | 把所有 Partition 打平轮询，整体更均匀 |
| StickyAssignor | 尽量保持上次分配，减少 Partition 迁移 |
| CooperativeStickyAssignor | Sticky + 增量协作式撤销 |

注意两个概念不要混：

- **Assignor**：决定“最终怎么分”。
- **Rebalance 协议**：决定“从旧分配迁移到新分配时怎么撤销 / 接管”。

Sticky 主要优化分配结果，Cooperative 主要优化迁移过程。

## Sticky Assignor：少搬一点，但还是 Eager

Sticky Assignor 的目标有两个：

1. 分配尽量均衡。
2. 在均衡的前提下，尽量保持上一次的分配。

例子：

```text
原来：
C1 -> p0, p1
C2 -> p2, p3

C3 加入

非 Sticky 可能：
C1 -> p0, p3
C2 -> p1
C3 -> p2

Sticky 倾向：
C1 -> p0
C2 -> p2
C3 -> p1, p3
```

Sticky 的价值是减少迁移：

- 本地状态更少丢。
- 缓存更少失效。
- offset 提交和恢复更少。
- 分配更稳定。

但如果底层还是 Eager 协议，它仍然有 Stop-The-World 问题：

> Sticky 能减少“最终哪些 Partition 换主人”，但 Eager 仍然要求所有 Consumer 先 revoke 全部分区。

所以 Sticky 是一半优化，不是终局。

## Cooperative Rebalance：增量协作式迁移

Cooperative 的核心变化是：

> 不再要求所有 Consumer 一次性撤销全部 Partition，而是只撤销那些确实要转移给别人的 Partition。

还是看例子：

```text
原来：
C1 -> p0, p1
C2 -> p2, p3

C3 加入后目标：
C1 -> p0
C2 -> p2
C3 -> p1, p3
```

Eager 做法：

```text
C1 revoke p0, p1
C2 revoke p2, p3
全停
再 assign
```

Cooperative 做法：

```text
第一轮：
C1 继续持有 p0，只 revoke p1
C2 继续持有 p2，只 revoke p3
C3 暂时拿不到 p1/p3，等待旧 owner 释放

第二轮：
C3 获得 p1, p3
C1/C2 持续消费未撤销的 p0/p2
```

也就是说，Cooperative 会把一次全量迁移拆成可能多轮的增量迁移。没有变化的 Partition 不停。

这带来一个非常重要的回调差异：

- Eager：`onPartitionsRevoked` 往往表示“我所有分区都要没了”。
- Cooperative：`onPartitionsRevoked` 只表示“这次列出的分区要撤销”，没列出的分区仍然归你。

写回调时不能粗暴清掉所有本地状态。

## Cooperative 为什么也不是银弹

Cooperative 很强，但它不是“不会 Rebalance”。

### 1. 仍然要 JoinGroup / SyncGroup

成员变化时，Group 协议仍要运行。只是迁移影响面变小，不代表没有协议开销。

### 2. 可能需要多轮

因为不能让新 owner 在旧 owner revoke 前就接管，所以一次变化可能需要两轮同步。小组没问题，大组上仍有成本。

### 3. 所有 Consumer 必须兼容

同一个 Group 内要使用兼容的 cooperative assignor。滚动升级时要按官方推荐从旧 assignor 迁移到双列表，再切到 cooperative，避免协议不一致。

### 4. 撤销分区仍要正确提交 offset

只撤销部分 Partition，不代表可以忽略 offset。`onPartitionsRevoked` 里仍然要对被撤销的 Partition 提交连续成功 offset。

### 5. 对“成员频繁死亡”无能为力

如果 Consumer 因 GC、OOM、网络、慢处理反复离组，Cooperative 只能降低影响面，不能消除根因。

## Static Membership：减少“短暂重启”的 Rebalance

默认情况下，Consumer 每次加入 Group 都会拿到一个动态 member id。实例重启时，Coordinator 可能认为：

```text
旧成员离开 + 新成员加入
```

这会触发 Rebalance。

Static Membership 引入 `group.instance.id`：

```properties
group.instance.id=order-consumer-3
```

它给 Consumer 一个稳定身份。只要同一个实例在 `session.timeout.ms` 内回来，Coordinator 可以把它视为同一个成员，而不是全新的成员。

适合：

- Kubernetes StatefulSet。
- 固定编号的消费实例。
- 滚动重启时希望减少分配抖动。

注意：

- `group.instance.id` 必须在同一个 Group 内唯一。
- 两个活跃实例不能用同一个 ID，否则会 fencing。
- 它减少短暂重启带来的 Rebalance，但不能解决处理太慢、心跳超时、订阅变化这些问题。

## Rebalance 和 offset commit 的关系

Rebalance 期间最大的风险不是“丢消息”，而是“重复消费增加”和“状态清理错”。

旧 owner 撤销 Partition 前，应该提交当前进度：

```java
public void onPartitionsRevoked(Collection<TopicPartition> partitions) {
    commitSyncFor(partitions);
    cleanupStateFor(partitions);
}
```

否则：

```text
C1 已处理 p0 到 offset=1000，但只提交到 900
Rebalance 后 p0 给 C2
C2 从 committed offset=900 开始
900..1000 重放
```

这通常不会丢，但会重复。业务幂等必须兜底。

Cooperative 下更要注意：

```java
onPartitionsRevoked(partitions)
```

只清理参数里列出的 partitions，不要把未撤销的分区状态也清掉。

## Rebalance 风暴是什么

一次 Rebalance 不可怕。可怕的是：

```text
JoinGroup -> SyncGroup -> Stable
刚稳定几秒
又有成员超时
再次 JoinGroup -> SyncGroup
...
```

表现：

- Consumer 日志反复出现 `PreparingRebalance`、`Revoking previously assigned partitions`、`JoinGroup`、`SyncGroup`。
- lag 呈锯齿状上升。
- 消费速率周期性掉到 0。
- commit 失败或 `CommitFailedException` 增多。
- 业务重复消费明显增加。
- 扩容越扩越慢。

本质是 Group 长期进不了稳定态，或者稳定态太短。

## 风暴原因一：处理时间超过 max.poll.interval.ms

这是最常见的一类。

```text
poll 拉 1000 条
业务处理要 8 分钟
max.poll.interval.ms = 5 分钟
Consumer 被踢出 Group
触发 Rebalance
```

解决：

- 降低 `max.poll.records`。
- 批量处理但控制总耗时。
- 优化慢 RPC / 慢 SQL。
- 把重任务交给 worker，但由 poll 线程持续 poll，并正确管理 pause/resume 和 offset。
- 合理调大 `max.poll.interval.ms`，但不要掩盖卡死。

## 风暴原因二：心跳超时

超过 `session.timeout.ms` 没有心跳。

常见原因：

- Full GC。
- CPU 饥饿，容器被限流。
- 网络抖动。
- Coordinator broker 卡顿。
- 客户端版本较老，心跳和 poll 耦合更重。

解决：

- 优化 GC，避免长停顿。
- 给容器足够 CPU request / limit。
- `heartbeat.interval.ms` 设为 `session.timeout.ms` 的 1/3 左右。
- 合理增大 `session.timeout.ms`，提升短抖动容忍度。
- 查 broker 端 Coordinator 负载和 `__consumer_offsets` 延迟。

权衡：

- timeout 太小：抖一下就 Rebalance。
- timeout 太大：真挂了恢复慢。

## 风暴原因三：发布方式太猛

如果一次滚动发布同时杀很多实例：

```text
10 个 Consumer 同时停止
10 个新 Consumer 同时加入
```

Group 会连续发生多次成员变化。

解决：

- 严格滚动发布，一次只动少量实例。
- 先启动新实例稳定，再停止旧实例，或反过来根据业务选择。
- 配 static membership，减少短暂重启影响。
- 优雅关闭，调用 `consumer.wakeup()` / `close()`，让实例主动 LeaveGroup。
- 配合 CooperativeStickyAssignor，降低每次变化影响面。

## 风暴原因四：Partition 或订阅频繁变化

比如：

- 正则订阅不断匹配到新 Topic。
- 运维频繁给 Topic 增 Partition。
- 应用动态改变订阅集合。

解决：

- 关键业务少用宽泛正则订阅。
- 增 Partition 做变更窗口，避免频繁小步变。
- Topic 创建和消费者上线要有发布节奏。

## 风暴原因五：Coordinator 或 __consumer_offsets 瓶颈

所有 Group 协调和 offset commit 都依赖 Coordinator 和 `__consumer_offsets`。

如果它慢了：

- Heartbeat 响应慢。
- JoinGroup / SyncGroup 慢。
- commit latency 高。
- Consumer 误判 Coordinator 不可用。

排查：

- 哪些 broker 是热点 Coordinator。
- `__consumer_offsets` Partition Leader 是否集中。
- commit latency 是否升高。
- broker 请求队列、网络、磁盘、GC 是否异常。
- 是否有大量 Group 同时 Rebalance。

解决：

- 分散 Group。
- 确保 `__consumer_offsets` 副本健康。
- 减少过高频率 commit。
- 修复 broker 资源瓶颈。

## 协议选择建议

现代新应用建议：

```properties
partition.assignment.strategy=org.apache.kafka.clients.consumer.CooperativeStickyAssignor
```

如果从老版本或老策略迁移，要注意兼容过程。常见思路是先让所有 Consumer 支持新策略，再把新策略提到首位，避免 Group 内策略不一致。

概念上可以这样选：

| 场景 | 建议 |
|---|---|
| 简单小 Group，消费无状态 | Range / RoundRobin 也能工作 |
| Partition 多、发布频繁 | Sticky 或 CooperativeSticky |
| 有本地状态 / cache / state store | CooperativeSticky 更合适 |
| Kafka Streams | 遵循 Streams 默认和版本建议 |
| 老客户端混跑 | 谨慎迁移，先确认协议兼容 |

## 参数治理清单

常用起点：

```properties
enable.auto.commit=false
max.poll.records=100
max.poll.interval.ms=300000
session.timeout.ms=45000
heartbeat.interval.ms=15000
partition.assignment.strategy=org.apache.kafka.clients.consumer.CooperativeStickyAssignor
```

如果实例身份稳定：

```properties
group.instance.id=order-consumer-3
```

怎么调要看指标：

- 处理经常超过 `max.poll.interval.ms`：先优化处理和降低 `max.poll.records`，再考虑调大。
- 心跳偶发超时：查 GC / CPU / 网络，再适度调大 `session.timeout.ms`。
- 发布触发抖动：上 Cooperative + static membership + 限速发布。
- commit latency 高：查 Coordinator 和 `__consumer_offsets`。

## 应用代码治理

### 1. 优雅关闭

收到关闭信号时：

```java
consumer.wakeup();
```

主循环捕获 `WakeupException` 后：

```java
try {
    commitCurrentOffsetsSync();
} finally {
    consumer.close();
}
```

这样能主动离组、提交进度、减少超时等待。

### 2. Rebalance 回调里只处理相关 Partition

```java
public void onPartitionsRevoked(Collection<TopicPartition> partitions) {
    commitSyncFor(partitions);
    cleanupOnly(partitions);
}
```

Cooperative 下尤其不要清空所有状态。

### 3. 慢分区 pause，不要拖死整个 Consumer

```java
consumer.pause(Set.of(tp));
```

其他 Partition 继续消费。恢复后：

```java
consumer.resume(Set.of(tp));
```

但 pause 后仍要继续 `poll()`，否则还是会触发 `max.poll.interval.ms`。

### 4. 多线程处理要提交连续 offset

不能提交最大完成 offset，只能提交连续成功区间。否则中间失败的消息会被跳过。

## 怎么排查一次 Rebalance 风暴

可以按这个顺序：

1. 确认哪个 `group.id` 在 Rebalance，影响哪些 Topic。
2. 看 Consumer 日志：是 `session timeout`、`max poll interval exceeded`、`CommitFailedException`，还是 Coordinator unavailable。
3. 看发布记录：是否刚滚动、扩容、缩容。
4. 看单批处理耗时和 `poll()` 间隔。
5. 看 GC pause、容器 CPU throttling、OOM 重启。
6. 看网络和 Coordinator broker 指标。
7. 看 `__consumer_offsets` 是否有 ISR 缩小、Leader 切换、请求延迟高。
8. 看分配策略是否还是 Range / RoundRobin / Eager。
9. 看是否使用正则订阅或频繁增 Partition。
10. 看 revoke 回调是否过慢，是否在里面做了重操作。

不要一上来只扩 Consumer。扩容本身也会触发 Rebalance，如果根因是处理慢或 Coordinator 慢，扩容可能让风暴更严重。

## 面试怎么回答

如果被问“Kafka Rebalance 为什么会导致消费停顿，Eager / Sticky / Cooperative 有什么区别，怎么治理”，可以这样答：

> Rebalance 是 Consumer Group 成员或订阅变化后，重新建立 Partition 所有权的协议。触发源包括 Consumer 加入 / 离开、心跳超过 `session.timeout.ms`、处理太久超过 `max.poll.interval.ms`、Topic 分区变化、订阅变化和 Coordinator 切换。经典流程是 Coordinator 进入 PreparingRebalance，成员 JoinGroup，Coordinator 选 Group Leader，Group Leader 计算 assignment，再 SyncGroup 下发。
>
> Eager Rebalance 一旦触发，会让所有成员撤销全部 Partition，再重新分配，所以是 Stop-The-World。Sticky Assignor 尽量保持原分配，减少最终迁移量，但如果底层还是 Eager，仍然会全量 revoke。CooperativeSticky 把迁移改成增量协作式，只 revoke 确实要转移的 Partition，没变的 Partition 可以继续消费，但它仍然要跑 JoinGroup / SyncGroup，也可能需要多轮，不解决成员频繁死亡这类根因。
>
> 治理上要看 Rebalance 原因：慢处理就降低 `max.poll.records`、优化下游或调 `max.poll.interval.ms`；心跳超时就查 GC、CPU、网络并调整 `session.timeout.ms` / `heartbeat.interval.ms`；发布抖动就滚动限速、优雅关闭、用 static membership；协议上优先用 CooperativeSticky；Rebalance 回调里要提交被撤销分区的 offset，Cooperative 下不要清掉未撤销分区状态。

这段回答的关键是版本和边界清楚：**Sticky 优化分配结果，Cooperative 优化迁移过程，Static Membership 优化短暂重启身份稳定性。**

## 这一篇要带走的结论

- Rebalance 是重新建立 Partition 所有权的协议，不只是“重新分配”。
- 触发源包括成员变化、心跳超时、poll 超时、订阅变化、Partition 变化、Coordinator 切换。
- Eager Rebalance 简单但全量撤销，是 Stop-The-World。
- Sticky Assignor 减少最终迁移量，但不必然消除全组停顿。
- CooperativeSticky 只撤销需要迁移的 Partition，显著降低影响面，但仍可能多轮同步。
- Static Membership 用 `group.instance.id` 减少短暂重启造成的成员抖动。
- Rebalance 前后 offset commit 必须谨慎，否则重复消费会放大。
- 风暴治理要从处理耗时、心跳、GC、发布方式、Coordinator、`__consumer_offsets`、分配策略一起看。

---

下一篇 `11_消息丢失专题：链路逐段拆解与解法.md`，会回到生产事故四大件的第一件：沿 Producer、Broker、副本、Consumer、业务处理五段逐段拆“哪里会丢、怎么配、怎么验证”。
