# 幂等与事务 Producer：PID / Sequence / Transaction Coordinator 与 EOS

## 这一篇要回答什么

上一篇讲 Producer 时留下了一个核心问题：

> 为什么没开幂等时，`retries > 0` + `max.in.flight > 1` 会导致重复和乱序；开了 `enable.idempotence=true` 后，Kafka 又是怎么把这个洞堵上的？

这一篇继续往下挖两层：

1. **幂等 Producer**：用 PID + Sequence Number 解决 Producer 重试导致的重复和乱序。
2. **事务 Producer**：用 Transaction Coordinator + 事务状态日志 + 控制消息，解决多 Partition 写入和消费-生产闭环的原子可见性。

最重要的结论先说：

> Kafka 的 Exactly-Once 不是“整个分布式业务只执行一次”。它覆盖的是 Kafka 内部边界：Producer 到 Kafka 的幂等写入，以及 Kafka → process → Kafka 的事务闭环。一旦写 MySQL、Redis、HTTP、对象存储，就必须靠业务幂等、Outbox、外部事务或补偿机制兜底。

## 起点：没有幂等会发生什么

Producer 重试是可靠性的基本动作，但重试天然会制造两个问题。

### 问题一：ack 丢了导致重复

```text
T1: Producer 发 batch A
T2: Leader append 成功
T3: broker 返回 ack
T4: ack 在网络中丢失
T5: Producer 以为发送失败，重试 batch A
T6: broker 再 append 一次
```

站在 Producer 视角，它只是做了一次合理重试；站在 broker 视角，它看到两次 Produce 请求。没有额外标识时，broker 分不清第二次是“重复重试”，还是“业务真的又发了一条相同 value 的消息”。

### 问题二：in-flight 导致乱序

为了吞吐，Producer 会允许多个请求同时在路上：

```text
T1: 发 batch A
T2: 发 batch B
T3: A 请求超时，被标记失败
T4: B 写入成功
T5: A 重试后写入成功
```

最终 broker 日志里可能是：

```text
offset 100: batch B
offset 101: batch A
```

如果 A、B 是同一个订单的状态变更，顺序就错了。

所以 Producer 端真正难的不是“能不能重试”，而是：

> **重试时 broker 怎么知道这是一条已经见过的消息，并且还能保持同一 Partition 内的顺序？**

## 幂等 Producer 的核心三件套

Kafka 的解法是给每个 Producer 批次加上三个身份字段：

| 字段                | 含义                          |
| ----------------- | --------------------------- |
| PID / Producer ID | broker 分配给 Producer 实例的唯一编号 |
| Producer Epoch    | Producer 的任期号，用来隔离旧实例       |
| Sequence Number   | 每个 PID 在每个 Partition 上递增的序号 |

可以理解成：

```text
(PID, Partition, Sequence)
```

这三个字段合起来，让 broker 能判断：

- 这是下一批正常消息。
- 这是已经写过的重复请求。
- 这是跳号 / 乱序请求。
- 这是旧 Producer 实例发来的僵尸请求。

## PID：Producer 的写入身份

开启幂等后，Producer 启动时会先向 broker 申请一个 PID。之后它发送的每个 batch 都带着这个 PID。

```text
Producer 启动
  │
  ▼
InitProducerId
  │
  ▼
broker 返回 PID
```

PID 不是业务消息 ID，也不是应用自己生成的 trace ID。它是 Kafka 内部用来识别“这个 Producer 发送流”的编号。

没有事务时，Producer 重启通常会拿到新的 PID。因此幂等 Producer 能解决的是：

> **同一个 Producer 会话内，由网络超时、ack 丢失、Leader 切换等造成的重试重复。**

它不能解决：

```text
T1: Producer 发出订单事件，broker 已写入
T2: 应用还没记录“发送成功”，进程崩溃
T3: 应用重启，重新构造同一个订单事件再发
T4: 新 Producer 拿到新 PID
T5: broker 认为这是另一个 Producer 的新消息
```

这仍然会重复。要挡这种重复，需要业务幂等键、Outbox 或消费端幂等。

## Sequence Number：每个 Partition 一条递增线

Sequence Number 不是全局递增，而是：

> **同一个 PID，在每个 Partition 上独立递增。**

例如一个 Producer 同时写两个 Partition：

```text
PID=42

partition 0:
  batch A: seq=0
  batch B: seq=1
  batch C: seq=2

partition 1:
  batch D: seq=0
  batch E: seq=1
```

broker 对每个 Partition 维护这个 PID 的最近 sequence 状态。收到 batch 时做判断：

| 收到的 sequence | broker 判断 | 处理 |
|---|---|---|
| 等于期望值 | 正常下一批 | append |
| 小于期望值 | 重复请求 | 不重复 append，返回成功 |
| 大于期望值 | 中间缺了一段 | 报 out-of-order 类错误 |

这就把 ack 丢失问题堵住了：

```text
T1: Producer 发 batch A(seq=10)
T2: broker append，期望下一个 seq=11
T3: ack 丢了
T4: Producer 重试 batch A(seq=10)
T5: broker 发现 seq=10 已经处理过
T6: 不再 append，只返回成功
```

重复请求被识别出来了。

## 为什么幂等能挡住 in-flight 乱序

再看上一篇的乱序场景。

没有幂等：

```text
A 失败重试，B 先成功
broker 不知道 A/B 原始顺序
结果 B 可能先进日志，A 后进日志
```

有幂等：

```text
A: seq=10
B: seq=11
```

如果 B 先到 broker，而 A 还没成功：

```text
broker 当前期望 seq=10
收到 B(seq=11)
发现跳号
不能直接 append
```

broker 不会让 seq=11 越过 seq=10 写进去。Producer 后续重试 A，A 成功后，B 再按顺序成功。这样就保住了单 PID、单 Partition 上的顺序。

这就是幂等 Producer 的设计美感：**不是简单去重，而是“去重 + 保序”一起做。**

## 为什么 max.in.flight 仍然有限制

幂等 Producer 并不是允许无限 in-flight。Kafka 要求 `max.in.flight.requests.per.connection` 不能太大，常见安全配置是不超过 5。

原因是 broker 端为了处理重试、乱序和去重，需要保留每个 Producer 在每个 Partition 上最近若干个 batch 的 sequence 状态。窗口太大，broker 状态和恢复复杂度都会上升。

所以现代常见配置是：

```properties
enable.idempotence=true
acks=all
retries=Integer.MAX_VALUE
max.in.flight.requests.per.connection=5
```

这组配置的意思是：

- 用 `acks=all` 确保写入要等 ISR。
- 用 `retries` 抗网络抖动和 Leader 切换。
- 用 PID + Sequence 防止重试重复和乱序。
- 用有限 in-flight 保留流水线吞吐。

## Producer Epoch：挡住旧实例

PID 解决“同一发送流”的身份问题，但还需要一个任期号，也就是 Producer Epoch。

为什么需要 epoch？因为分布式系统里常有“旧实例复活”的问题：

```text
T1: Producer A 卡住，网络分区
T2: 系统认为 A 死了，启动 Producer B
T3: B 接管同一个 transactional.id
T4: A 网络恢复，又继续发消息
```

如果没有 epoch，broker 可能同时接受 A 和 B 的写入，顺序和事务都会乱。

Epoch 的作用是：

> **同一个 PID 下，新 epoch 可以 fence 掉旧 epoch。**

broker 看到旧 epoch 的请求，会拒绝。客户端通常会收到 `ProducerFencedException` 一类错误，说明自己已经不是合法写入者，必须退出。

这个机制在事务 Producer 里尤其关键，因为事务 Producer 通常会配置稳定的 `transactional.id`。

## 幂等 Producer 的边界

幂等 Producer 很强，但边界必须讲清楚。

### 1. 它不解决业务重复

同一个订单事件，因为应用重启、Outbox 重扫、人工补偿、上游重试，被重新构造并发送，这在 Kafka 看来是新的消息。只要 PID / Sequence 不同，Kafka 不会根据 value 内容帮你去重。

业务仍然要用：

- 订单 ID + 事件类型。
- payment_id。
- request_id。
- 去重表。
- 唯一约束。
- 状态机版本号。

### 2. 它不解决消费端重复

消费者处理成功后，还没提交 offset 就崩了，重启后会再次消费。这和 Producer 幂等没有关系。

```text
Consumer 写 DB 成功
Consumer commit offset 前崩溃
重启后从旧 offset 重读
```

这类重复只能靠消费端业务幂等。

### 3. 它不提供多 Partition 原子性

幂等 Producer 可以保证每个 Partition 上的重复重试不重复写，但它不保证“写 partition 0 和 partition 1 要么都可见，要么都不可见”。

如果你要多 Partition 原子可见性，就进入事务 Producer。

### 4. 它不覆盖外部系统

Producer 幂等只在 Kafka broker 内部生效。写 Kafka 成功后再写 MySQL，或先写 MySQL 再写 Kafka，都不在它的保护范围内。

这就是为什么 Kafka EOS 不能替代 Outbox。

## 事务 Producer 要解决什么

幂等 Producer 解决的是：

> 单 Producer 到单个或多个 Partition 的重试去重和单 Partition 顺序。

事务 Producer 要解决更高一层：

> 一组写入，可能跨多个 Topic / Partition，并且可能包含 consumer offset 提交，要么一起提交可见，要么一起中止不可见。

典型场景是流处理：

```text
input topic
  │
  ▼
Consumer 读消息
  │
  ▼
处理 / 聚合 / 转换
  │
  ▼
Producer 写 output topic
  │
  ▼
同时提交 input offset
```

没有事务时，崩在中间会有两个经典问题：

### 问题一：结果写了，但 offset 没提交

```text
T1: 消费 input offset=100
T2: 写 output 成功
T3: 提交 input offset 前崩溃
T4: 重启后又消费 offset=100
T5: output 被重复写
```

### 问题二：offset 提交了，但结果没写完

```text
T1: 消费 input offset=100
T2: 先提交 offset=101
T3: 写 output 前崩溃
T4: 重启从 101 开始
T5: offset=100 的处理结果丢了
```

事务 Producer 的目标是把这两件事绑成一个原子动作：

```text
写 output records + 提交 input offsets
要么一起 commit
要么一起 abort
```

这就是 Kafka 内部 EOS 的核心。

## 事务 Producer 的几个角色

事务机制里多了几个关键对象。

| 对象                      | 作用                                            |
| ----------------------- | --------------------------------------------- |
| `transactional.id`      | 应用配置的稳定事务身份                                   |
| PID / Producer Epoch    | Kafka 分配的内部写入身份和任期                            |
| Transaction Coordinator | 管理事务状态的 broker                                |
| `__transaction_state`   | 内部 topic，持久化事务元数据                             |
| transaction marker      | 写到业务 Partition 的 commit / abort 控制消息          |
| LSO                     | Last Stable Offset，read_committed 消费者最多能读到的位置 |

注意 `transactional.id` 和 PID 的关系：

- `transactional.id` 是应用可配置、跨重启稳定的身份。
- PID 是 broker 分配的内部编号。
- Transaction Coordinator 维护 `transactional.id -> PID / epoch / transaction state` 的映射。

同一个 `transactional.id` 只能有一个活跃 Producer。新实例启动并初始化事务时，会提升 epoch，把旧实例 fence 掉。

## 事务状态机

事务大致有这些状态：

```text
Empty
  │ beginTransaction
  ▼
Ongoing
  │ send records / sendOffsetsToTransaction
  ├───────────────► PrepareCommit ─► CompleteCommit
  │
  └───────────────► PrepareAbort  ─► CompleteAbort
```

这些状态不是只放内存里。Transaction Coordinator 会把它们写到内部 topic：

```text
__transaction_state
```

这点非常关键：Coordinator 挂了可以恢复。新 Coordinator 接管后，从 `__transaction_state` 读出事务元数据，继续完成 commit / abort。

## 事务写入完整流程

一个典型事务 Producer 代码大概是：

```java
producer.initTransactions();

while (true) {
    ConsumerRecords<K, V> records = consumer.poll(Duration.ofMillis(100));

    producer.beginTransaction();
    try {
        for (ConsumerRecord<K, V> record : records) {
            ProducerRecord<K2, V2> output = transform(record);
            producer.send(output);
        }

        producer.sendOffsetsToTransaction(offsets, consumer.groupMetadata());
        producer.commitTransaction();
    } catch (Exception e) {
        producer.abortTransaction();
    }
}
```

底层大致链路：

```text
1. initTransactions
   找 Transaction Coordinator
   获取 / 恢复 PID 和 epoch
   fence 旧 producer

2. beginTransaction
   本地标记事务开始

3. send records
   如果第一次写某个 Partition
   向 Coordinator 注册这个 Partition 属于当前事务
   然后按普通 Produce 写入，但记录带 transaction 标记

4. sendOffsetsToTransaction
   把消费位点作为事务的一部分写入 __consumer_offsets

5. commitTransaction
   Coordinator 写 PrepareCommit
   向所有参与 Partition 写 COMMIT marker
   写 CompleteCommit

6. abortTransaction
   Coordinator 写 PrepareAbort
   向所有参与 Partition 写 ABORT marker
   写 CompleteAbort
```

这里的核心不是“消息没写入”。事务消息在事务进行中其实已经写到日志里了，只是对 `read_committed` 消费者不可见，直到 commit marker 到来。

## Control Batch：commit / abort 是写进日志的

Kafka 不是把事务结果存在某个外部表里，而是把控制消息写进每个参与的 Partition。

业务日志里会混着两类记录：

```text
offset 100: transactional data record
offset 101: transactional data record
offset 102: COMMIT marker
```

或者：

```text
offset 100: transactional data record
offset 101: transactional data record
offset 102: ABORT marker
```

这些 marker 是控制 batch，不会作为普通业务消息返回给消费者，但 broker 和 consumer 客户端会用它判断事务结果。

所以事务的可见性不是“写没写”，而是：

- commit marker 出现 → 这批事务消息对 `read_committed` 可见。
- abort marker 出现 → 这批事务消息被跳过。

## read_committed 和 LSO

普通消费者默认是 `read_uncommitted`，它可以读到已经写入日志的消息，即使这些消息属于未提交事务。

事务消费要设置：

```properties
isolation.level=read_committed
```

这时消费者最多只能读到 LSO（Last Stable Offset）。

可以粗略理解为：

> LSO = 当前最早未完成事务开始的位置。消费者不能越过这个位置，因为后面的消息里可能有未提交事务。

如果没有未完成事务：

```text
LSO = HW
```

如果有一个长事务卡住：

```text
offset 100: open transaction starts
offset 101: normal record
offset 102: normal record
offset 103: another transaction record
HW=200
LSO=100
```

`read_committed` 消费者只能读到 100 之前。即使 101、102 是非事务普通消息，也可能被这个未完成事务挡住。

这就是长事务的代价：

- 下游消费看起来 lag 变大。
- `read_committed` 可见进度被 LSO 卡住。
- commit / abort marker 迟迟不到，消费者不能安全越过。

所以 Kafka 事务不能当成长时间业务事务用。它适合短事务、流处理微批，不适合把 HTTP 调用、人工审批、外部数据库慢事务塞进去。

## 事务怎么实现 Kafka 内 EOS

Kafka 内 EOS 具体指这个闭环：

```text
read from Kafka input
process
write to Kafka output
commit input offset
```

事务 Producer 把两件事合在一个事务里：

1. 输出结果写到 output topic。
2. 输入 offset 写到 `__consumer_offsets`。

提交成功后：

- output records 对 `read_committed` 消费者可见。
- input offset 也随事务提交生效。

中止后：

- output records 被 `read_committed` 跳过。
- input offset 不会推进。
- 下次还会从旧 offset 重新处理。

于是崩溃恢复时不会出现“输出写了但 offset 没提交”或“offset 提了但输出没写”的中间状态。

## EOS 的边界：三段分开看

面试里最容易糊的是 Exactly-Once。必须按边界拆：

### 1. Producer -> Kafka

幂等 Producer 能做到：

- 同一 Producer 会话内重试不重复 append。
- 单 Partition 内顺序不被重试打乱。

但它不保证业务事件全局不重复。

### 2. Kafka -> process -> Kafka

事务 Producer 能做到：

- 多 Partition 输出原子可见。
- output records 和 input offsets 原子提交。
- `read_committed` 消费者不会看到 aborted 结果。

这是 Kafka EOS 最核心的范围。

### 3. Kafka -> 外部系统

比如写 MySQL、Redis、ES、HTTP API：

```text
consume Kafka
write MySQL
commit Kafka offset
```

Kafka 事务管不到 MySQL。你仍然会遇到：

- MySQL 写成功，offset 没提交 → 重复消费。
- offset 提交了，MySQL 没写 → 丢业务结果。

解决要靠：

- 数据库唯一约束。
- 幂等表。
- 状态机。
- Outbox / Inbox。
- CDC。
- 外部事务或补偿。

不要把 Kafka EOS 讲成“我写数据库也 exactly-once”。那是面试里非常危险的答案。

## Transaction Coordinator 挂了怎么办

Coordinator 是 broker 上的一个角色，不是单点。

`transactional.id` 会按照 hash 映射到 `__transaction_state` 的某个 Partition；这个 Partition 的 Leader broker 就是对应事务的 Coordinator。

如果 Coordinator 挂了：

1. `__transaction_state` 对应 Partition 选出新 Leader。
2. 新 Leader 读取事务状态日志。
3. 恢复每个 `transactional.id` 的 PID、epoch、事务状态。
4. 对 PrepareCommit / PrepareAbort 但没完成的事务继续写 marker。

这就是为什么事务状态必须写内部 topic。否则 Coordinator 一挂，事务处于 commit 一半还是 abort 一半就没人知道了。

## Zombie Producer：为什么 transactional.id 不能乱用

事务 Producer 必须配置 `transactional.id`：

```properties
transactional.id=order-stream-worker-3
```

这个 ID 要稳定，但不能被两个活跃实例同时使用。

正确姿势：

- 每个任务 / 分片 / 实例有自己唯一的 `transactional.id`。
- 实例重启后复用同一个 ID，便于恢复和 fence 旧实例。
- 不要多个活跃实例共享一个 ID。
- 不要每次启动都随机生成 ID，否则失去 fencing 和事务恢复意义。

如果两个实例同时用同一个 `transactional.id`：

```text
新实例 initTransactions
Coordinator 提升 epoch
旧实例继续发送
broker 发现旧 epoch
抛 ProducerFencedException
```

旧实例应该立刻退出，不要捕获后继续重试。

## 事务的代价

事务不是免费午餐。

### 1. 延迟更高

普通发送只要 Produce 请求成功。事务还要：

- 注册参与 Partition。
- 写事务状态。
- commit / abort 时写 marker。
- 等待 Coordinator 协调。

### 2. 吞吐下降

事务会增加控制请求和状态写入，batch 太小或事务太频繁时，开销很明显。

### 3. 长事务阻塞 LSO

未完成事务会让 `read_committed` 消费者停在 LSO 前，造成看起来像 lag 的可见性延迟。

### 4. 运维复杂度更高

你要监控：

- transaction abort rate。
- transaction commit latency。
- producer fenced 异常。
- `__transaction_state` 的健康。
- read_committed consumer 的 lag 和 LSO 卡顿。

### 5. 只适合 Kafka 内部闭环

如果你的主要动作是写数据库，事务 Producer 帮不上核心问题。那时应该优先考虑 Outbox / CDC / 消费幂等，而不是强行上 Kafka 事务。

## 常见失败场景

### 场景一：事务中途 Producer 崩溃

```text
beginTransaction
send output records
Producer 崩溃，没 commit
```

结果：

- 事务超时后 Coordinator abort。
- 已写入日志的数据仍在日志里。
- `read_committed` 消费者跳过这些 aborted records。
- input offset 没提交，下次会重读。

### 场景二：commit 请求发出后超时

```text
Producer 调 commitTransaction
请求超时，Producer 不知道成功没成功
```

结果可能是：

- Coordinator 最终 commit 成功。
- Coordinator 最终 abort。
- Producer 需要按异常类型决定是继续查 / 重试，还是关闭实例。

这也是为什么事务 API 比普通 send 更重，错误处理不能粗暴吞掉。

### 场景三：旧 Producer 被 fence

```text
实例 A 卡住
实例 B 用同一个 transactional.id 启动
B initTransactions 成功，epoch 提升
A 恢复继续写
```

结果：

- A 收到 `ProducerFencedException`。
- A 必须退出。
- B 才是新的合法写入者。

这挡住了“僵尸实例”继续污染事务。

### 场景四：外部数据库写成功，但 Kafka 事务 abort

```text
beginTransaction
write MySQL 成功
send Kafka output
abortTransaction
```

结果：

- Kafka output 不可见。
- MySQL 写入已经发生。

Kafka 没法回滚 MySQL。这再次说明：不要把外部副作用塞进 Kafka EOS 的承诺里。

## 幂等、事务、业务幂等怎么选

| 目标 | 方案 |
|---|---|
| Producer 重试不重复写 Kafka | 幂等 Producer |
| Producer 重试不破坏单 Partition 顺序 | 幂等 Producer |
| 多个 Kafka Partition 输出要么都可见要么都不可见 | 事务 Producer |
| Kafka 输入 offset 和 Kafka 输出结果原子提交 | 事务 Producer |
| 消费成功但 offset 没提交导致重复 | 消费端业务幂等 |
| 写 MySQL / Redis / HTTP 的 exactly-once | 外部幂等、Outbox、事务表、补偿 |
| 上游本地事务和消息发送一致 | Outbox / CDC，或特定 MQ 的事务消息 |

可以用一句话记：

> 幂等 Producer 管“重试写 Kafka”，事务 Producer 管“Kafka 内部多写入原子可见”，业务幂等管“外部副作用重复”。

## 生产配置建议

### 幂等 Producer

关键业务 Producer 建议显式配置：

```properties
enable.idempotence=true
acks=all
retries=Integer.MAX_VALUE
max.in.flight.requests.per.connection=5
delivery.timeout.ms=120000
```

并配合 broker / topic：

```properties
replication.factor=3
min.insync.replicas=2
unclean.leader.election.enable=false
```

### 事务 Producer

事务 Producer 必须配置稳定的 `transactional.id`：

```properties
transactional.id=stream-job-A-task-0
enable.idempotence=true
acks=all
transaction.timeout.ms=60000
```

Consumer 侧如果要只读已提交事务：

```properties
isolation.level=read_committed
enable.auto.commit=false
```

注意：

- 事务要短，不要把慢外部调用放进事务窗口。
- 不要多个活跃实例共享同一个 `transactional.id`。
- `transaction.timeout.ms` 不要随便调很大，长事务会卡 LSO。
- 下游如果不是 Kafka，仍然做业务幂等。

## 面试怎么回答

如果被问“Kafka 的幂等和事务是怎么实现的，EOS 到底是什么”，可以这样答：

> 幂等 Producer 主要解决 Producer 重试导致的重复和乱序。Producer 启动后拿到 PID，每个 PID 在每个 Partition 上维护递增 Sequence Number，broker 记录最近写入的 sequence：正常递增就 append，重复 sequence 就直接返回成功，跳号就报错。Producer Epoch 用来 fence 旧实例。它的边界是只解决 Producer 写 Kafka 的重试重复，解决不了业务重复和消费端重复。
>
> 事务 Producer 在幂等基础上加了 `transactional.id`、Transaction Coordinator 和 `__transaction_state`。事务里的数据先写入各业务 Partition，commit 或 abort 时 Coordinator 向参与 Partition 写控制 marker。`read_committed` 消费者通过 LSO 和事务 marker 只读取已提交事务，并跳过 aborted records。它可以把 Kafka output records 和 input offsets 一起提交，实现 Kafka → process → Kafka 的 exactly-once。它不覆盖 MySQL、Redis、HTTP 这些外部系统，外部副作用仍然要靠业务幂等或 Outbox。

这段回答最关键的是边界清楚：**Kafka EOS 是 Kafka 内部 EOS，不是分布式世界通用 EOS。**

## 这一篇要带走的结论

- 幂等 Producer 用 PID + Sequence Number 识别重复重试，并保持单 Partition 顺序。
- Producer Epoch 用来 fence 旧实例，事务场景尤其重要。
- 幂等 Producer 不解决业务重复、不解决消费端重复、不解决外部系统副作用。
- 事务 Producer 通过 Transaction Coordinator、`__transaction_state` 和 commit / abort marker 实现多 Partition 原子可见。
- `read_committed` 消费者受 LSO 限制，长事务会阻塞可见进度。
- Kafka EOS 覆盖 Kafka → process → Kafka，不覆盖 Kafka → MySQL / Redis / HTTP。
- 关键业务的最终防线仍然是业务幂等、Outbox、状态机和补偿。

---

下一篇 `09_消费者深挖：ConsumerGroup_Coordinator_Heartbeat与Offset提交.md`，会切到消费端，把 Consumer Group、Group Coordinator、心跳、poll 循环、offset commit、自动提交和手动提交这些真正决定“丢还是重复”的地方拆开。
