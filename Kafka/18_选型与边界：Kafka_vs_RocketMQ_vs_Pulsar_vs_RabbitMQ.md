# 选型与边界：Kafka vs RocketMQ vs Pulsar vs RabbitMQ

这是 Kafka 专题最后一篇。

前面我们已经把 Kafka 拆到很细：

- 它是分布式日志。
- 它擅长高吞吐、可回放、多下游。
- 它不擅长单条消息级别的复杂投递状态。
- 它的可靠性要靠 Producer、Broker、Consumer、业务幂等一起兜。
- 它作为基础设施时，还要治理 Schema、Topic、权限、配额、DLQ、回放。

最后要回答一个更现实的问题：

> 什么时候该选 Kafka，什么时候不该硬上 Kafka？

MQ 选型最怕两种极端：

1. “Kafka 性能最好，所以都用 Kafka。”
2. “业务消息就必须 RocketMQ，日志就必须 Kafka。”

真正的选型不是品牌投票，而是找主矛盾。

## 这一篇要回答什么

1. Kafka、RocketMQ、Pulsar、RabbitMQ 的核心心智模型分别是什么？
2. 它们不是都能发消息吗，差异到底在哪里？
3. 日志流、业务消息、多租户、复杂路由分别应该怎么选？
4. 为什么 Kafka 不适合所有业务消息？
5. 为什么 RabbitMQ 不适合当数据总线？
6. Pulsar 和 Kafka 的核心差别是什么？
7. RocketMQ 为什么在电商业务消息里常被选中？
8. 面试里怎么讲“MQ 选型和边界”才不像背表格？

先给结论：

> Kafka 是分布式提交日志，适合高吞吐事件流、日志中枢、CDC、流计算入口、可回放数据总线。RocketMQ 是偏业务消息的系统，适合事务消息、延迟消息、顺序消息、消费重试和 DLQ 更贴近业务的场景。Pulsar 是云原生多租户消息 / 流平台，Broker 与存储分离，适合强多租户、海量 Topic、分层存储、跨地域和弹性隔离诉求明显的场景。RabbitMQ 是 AMQP 消息路由器，适合任务队列、复杂路由、TTL、死信、单条 ack 和中小规模可靠投递。选型不是看谁“更强”，而是看你要的是日志回放、业务投递、多租户弹性，还是路由队列。

## 一句话定位

| 系统 | 更像什么 | 最擅长 |
| --- | --- | --- |
| Kafka | 分布式提交日志 | 高吞吐事件流、可回放、日志总线、CDC、Flink 入口 |
| RocketMQ | 业务消息中间件 | 事务消息、延迟消息、顺序消息、消费重试、DLQ |
| Pulsar | 云原生多租户消息 / 流平台 | Broker / 存储分离、多租户、海量 Topic、分层存储、地理复制 |
| RabbitMQ | AMQP 消息路由器 | Exchange 路由、任务队列、TTL、DLX、单条 ack、协议兼容 |

这张表背后是四套不同哲学：

```text
Kafka:
  先把消息当日志，消费进度由消费者维护。

RocketMQ:
  在日志存储上补强业务消息能力。

Pulsar:
  把消息服务做成多租户、存储计算分离的平台。

RabbitMQ:
  以 Queue / Exchange 为中心管理投递状态和路由。
```

## 选型第一问：这是事实流，还是任务投递？

先分清消息语义。

### 事实流

事实流表达的是：

> 某件事已经发生了。

例如：

- `order_created`
- `payment_succeeded`
- `inventory_changed`
- `user_clicked`
- `mysql.orders row updated`

事实流的特点：

- 多个下游都可能关心。
- 下游各自维护进度。
- 下游可能要重放历史。
- 消息通常按时间追加。
- 写入量可能很大。

更偏 Kafka / Pulsar。

### 任务投递

任务投递表达的是：

> 请某个消费者执行一件事。

例如：

- `send_sms`
- `generate_report`
- `cancel_order_after_30min`
- `retry_payment_callback`
- `dispatch_job`

任务投递的特点：

- 更关注这条任务有没有被执行。
- 失败后要重试。
- 多次失败要进死信。
- 可能需要延迟。
- 单条 ack 语义很重要。

更偏 RocketMQ / RabbitMQ。

当然，Kafka 也能做任务投递，RocketMQ 也能做事件流。但你要知道自己是在顺着系统设计，还是逆着系统补洞。

## Kafka：分布式日志优先

Kafka 的核心是：

```text
Topic -> Partition -> Segment -> Offset
```

每个 Partition 是一条 append-only 日志。

Producer 追加消息，Consumer 按 offset 拉取。

Kafka 关心的是：

- 高吞吐写入。
- 按 Partition 顺序追加。
- 多副本可靠存储。
- 多 Consumer Group 独立读取。
- offset 可重置，可回放。

### Kafka 最适合什么

Kafka 很适合：

- 用户行为日志。
- 服务日志。
- 埋点。
- CDC。
- 数据总线。
- 实时计算入口。
- Flink / Spark Streaming / Kafka Streams。
- 机器学习特征流。
- 监控指标流。
- 多个下游各自消费同一份数据。
- 下游要重放历史。

典型链路：

```text
业务服务 / CDC / 埋点
  -> Kafka
  -> Flink
  -> 数据湖
  -> 搜索
  -> 推荐
  -> 监控
```

### Kafka 的优势

- 吞吐高。
- 生态强。
- 与 Flink / Spark / Kafka Streams / Connect 配合成熟。
- 可回放能力天然。
- Consumer Group 模型简单统一。
- PageCache、顺序写、Batch、Compression、零拷贝协同。
- 多副本和 ISR 可靠性边界清楚。
- KRaft 后元数据系统收敛到 Kafka 自身。

### Kafka 的短板

Kafka 不自然的地方：

- 单条消息 ack / reject / requeue 不像队列型 MQ 那么直接。
- 延迟消息不是原生主能力，通常要调度层。
- 失败重试和 DLQ 要消费者自己设计。
- Topic / Partition 太多会带来元数据、文件句柄、PageCache 和恢复成本。
- 复杂路由不如 RabbitMQ 的 Exchange 自然。
- 业务事务消息不如 RocketMQ 原生。
- 端到端 exactly-once 写外部系统仍然要靠幂等或事务 sink。

### 不要硬上 Kafka 的场景

这些场景要谨慎：

- 每条任务都要单独 ack / reject / nack。
- 大量不同 TTL / 延迟策略。
- 复杂 routing key、通配符、广播到不同 Queue。
- 只需要一个轻量任务队列。
- 海量小 Topic、小流量租户，且团队没有 Kafka 平台治理能力。
- 业务强依赖事务消息和延迟消息，不想自己补调度 / 回查 / DLQ。
- 需要在 MQ 里按任意条件查消息。
- 需要长期审计存储，多年保留。

Kafka 可以做其中一部分，但做出来往往是：

```text
Kafka + 调度服务 + DLQ Topic + 重放工具 + 幂等表 + 运维平台
```

如果你的团队其实只想要任务投递，这套东西可能太重。

## RocketMQ：业务消息优先

RocketMQ 的设计更贴近业务消息，尤其是 Java / 电商 / 交易场景。

它的核心存储模型是：

```text
CommitLog
  所有消息顺序写入

ConsumeQueue
  每个 Topic / Queue 的轻量消费索引
```

这和 Kafka 的每 Partition 独立日志不同。

RocketMQ 更强调：

- 事务消息。
- 延迟消息。
- 顺序消息。
- 消费失败重试。
- 死信队列。
- Tag 过滤。
- 大量业务 Topic。

### RocketMQ 最适合什么

适合：

- 订单。
- 支付。
- 库存。
- 优惠券。
- 营销触达。
- 超时取消。
- 交易状态通知。
- Java 业务系统之间可靠消息。

典型链路：

```text
订单服务
  -> RocketMQ 事务消息 / 普通消息 / 延迟消息
  -> 库存服务
  -> 优惠券服务
  -> 通知服务
```

### RocketMQ 的优势

- 事务消息语义贴近业务。
- 延迟消息能力比 Kafka 原生更自然。
- 消费失败重试和 DLQ 更内建。
- 顺序消息支持更贴近业务队列。
- Java 生态和国内业务场景经验丰富。
- CommitLog + ConsumeQueue 对大量业务 Topic 更友好。

### RocketMQ 的短板

- 数据流生态通常不如 Kafka 厚。
- 与 Flink / Spark / Connect 生态的通用程度不如 Kafka。
- 全球社区和跨语言生态要具体评估。
- 极致日志总线、CDC、湖仓生态通常不是它最强项。
- 运维要理解 NameServer、Broker、CommitLog、ConsumeQueue、主从 / DLedger 等体系。

### RocketMQ 和 Kafka 怎么选

如果主矛盾是：

```text
业务消息可靠投递
事务消息
延迟消息
消费失败重试
```

RocketMQ 更自然。

如果主矛盾是：

```text
高吞吐数据流
可回放
Flink / CDC / 数据湖生态
多个下游独立消费
```

Kafka 更自然。

如果是核心业务事件平台，两者都可能成立。

分水岭是：

> 你更看重业务投递闭环，还是数据流生态和回放能力？

## Pulsar：云原生多租户优先

Pulsar 的定位和 Kafka 最接近，但架构哲学不同。

Pulsar 的核心特点是：

```text
Broker 层
  处理客户端连接、协议、路由

BookKeeper / Bookie 存储层
  持久化 segment / ledger

元数据层
  管理 tenant / namespace / topic / cursor 等
```

也就是：

> Broker 和存储分离。

Kafka 更像：

```text
Broker 同时负责服务请求 + 本地磁盘存储 Partition
```

Pulsar 更像：

```text
Broker 负责服务
BookKeeper 负责持久化
```

### Pulsar 最适合什么

适合：

- 强多租户消息平台。
- 海量 Topic / Namespace。
- 计算和存储希望独立扩缩容。
- 长 backlog。
- 分层存储。
- 跨地域复制。
- 云原生部署。
- 同时需要 queue / pub-sub / streaming 多种订阅模型。

### Pulsar 的优势

- 天生多租户模型：tenant / namespace / topic。
- Broker stateless-ish，扩缩容和迁移思路更云原生。
- 存储层 BookKeeper 支持 segment 化、ledger 化存储。
- 支持不同 subscription 模型，适配队列和发布订阅。
- 分层存储适合长时间 backlog 或低成本历史保存。
- 地理复制、多集群场景设计比较突出。
- 海量 Topic 和多租户隔离是它的强项之一。

### Pulsar 的短板

- 架构组件更多，理解和运维复杂度更高。
- Broker、BookKeeper、元数据组件都要监控和排障。
- 团队如果只需要普通日志流，Kafka 的生态和经验可能更直接。
- 社区、生态、人才储备要结合团队环境评估。
- 问题定位链路更长：客户端、Broker、Bookie、ledger、cursor、namespace 都可能相关。

### Pulsar 和 Kafka 怎么选

选 Kafka 更自然的情况：

- 公司已经有成熟 Kafka 生态。
- Flink / CDC / Connect / 数据湖链路围绕 Kafka 建好了。
- Topic 数和多租户复杂度可控。
- 团队熟悉 Kafka 运维。
- 追求简单直接的高吞吐日志系统。

选 Pulsar 更自然的情况：

- 一开始就要做云原生多租户消息平台。
- Topic 数量极多，租户隔离强。
- 希望存储和计算分离扩容。
- 长 backlog 和分层存储是核心需求。
- 跨地域复制、Namespace 管理、订阅模式多样性很重要。

一句话：

> Kafka 是生态和日志模型的王者；Pulsar 更像面向云原生多租户的平台化消息系统。

## RabbitMQ：路由和任务队列优先

RabbitMQ 的核心不是日志，而是：

```text
Exchange -> Binding -> Queue -> Consumer
```

Producer 把消息发给 Exchange。

Exchange 根据 Binding 和 Routing Key 把消息路由到 Queue。

Consumer 从 Queue 消费并 ack。

### RabbitMQ 最适合什么

适合：

- 任务队列。
- 复杂路由。
- 工作分发。
- RPC-like 异步调用。
- TTL。
- DLX / 死信。
- 单条 ack / nack。
- 消息优先级。
- 中小规模业务系统。
- AMQP 协议生态。

典型链路：

```text
订单服务
  -> exchange: business
  -> routing key: order.created.vip
  -> queue: vip-notification
  -> queue: analytics
  -> queue: crm-sync
```

### RabbitMQ 的优势

- Exchange 路由模型灵活。
- Direct / Fanout / Topic / Headers 路由自然。
- Queue 级 TTL、DLX、prefetch、ack 语义成熟。
- 管理控制台好用。
- 适合“任务有没有被处理”这类语义。
- 多语言 AMQP 生态成熟。

### RabbitMQ 的短板

- 不适合超高吞吐日志流。
- 历史回放不是天然能力。
- 多下游消费通常要复制到多个 Queue。
- 大量消息长期堆积会让队列压力变大。
- 作为数据总线不如 Kafka / Pulsar 自然。
- 流计算、CDC、湖仓生态不是主场。

### RabbitMQ 和 Kafka 怎么选

如果你需要：

```text
复杂 routing key
任务投递
每条消息 ack
TTL + DLX
小中规模可靠队列
```

RabbitMQ 更自然。

如果你需要：

```text
日志流
回放历史
多个 Consumer Group 独立读同一份数据
Flink / CDC / 数据湖
```

Kafka 更自然。

RabbitMQ 更像“派单系统”，Kafka 更像“事件日志”。

## 存储模型对比

| 系统 | 存储模型 | 影响 |
| --- | --- | --- |
| Kafka | Partition 独立 append-only Segment | 模型简单，吞吐高；Partition 多时元数据和文件成本高 |
| RocketMQ | CommitLog + ConsumeQueue | 写路径集中，海量 Topic 更友好；读路径和索引更复杂 |
| Pulsar | Broker / BookKeeper 分离，ledger / segment 存储 | 存储计算分离，多租户强；组件更多 |
| RabbitMQ | Queue 为中心，消息随投递状态变化 | 投递语义强；不适合长时间可回放日志 |

这个差异决定了它们的边界。

Kafka 的问题常出在：

- Partition 过多。
- Consumer lag。
- Rebalance。
- PageCache / 磁盘 / 网络。
- ISR 抖动。

RocketMQ 的问题常出在：

- 事务消息回查。
- 延迟消息堆积。
- ConsumeQueue / CommitLog 清理。
- 消费重试和 DLQ。
- NameServer / Broker 路由。

Pulsar 的问题常出在：

- Broker / Bookie / 元数据组件之间。
- ledger backlog。
- cursor。
- namespace / tenant 配额。
- 分层存储读写。

RabbitMQ 的问题常出在：

- Queue 堆积。
- unacked 消息。
- prefetch 设置。
- DLX / TTL 路由。
- 单队列热点。
- 镜像 / quorum 队列复制压力。

## 消费确认机制对比

### Kafka：进度条模式

Kafka Consumer 处理消息后提交 offset：

```text
committed offset = 下一条要读的位置
```

它提交的是“进度条”。

优点：

- 批量高效。
- 适合顺序日志。
- 回放简单。

代价：

- 单条失败不好独立 ack。
- 批量中间失败要业务自己处理。
- DLQ 要消费者写。

### RocketMQ：消费状态模式

Consumer 返回消费状态。

失败后 Broker 会按策略重试，超过次数进入 DLQ。

优点：

- 业务开发体验更自然。
- 失败重试和死信内建。

代价：

- 重试语义、顺序消费、幂等仍要理解清楚。
- 大量失败重试可能拖垮业务。

### Pulsar：订阅游标模式

Pulsar 有多种 subscription 模式，比如 exclusive、shared、failover、key_shared。

消费进度以 cursor / subscription 维护。

优点：

- 同一个系统里能表达更多消费形态。
- 多租户和订阅模型灵活。

代价：

- 语义更多，团队要理解不同 subscription 对顺序和并发的影响。

### RabbitMQ：单据签收模式

RabbitMQ Consumer ack / nack / reject。

优点：

- 每条消息状态清楚。
- 任务队列语义自然。
- prefetch 控制消费者承载。

代价：

- Broker 维护投递状态更重。
- 大规模历史回放不自然。

## 高级能力对比

| 能力 | Kafka | RocketMQ | Pulsar | RabbitMQ |
| --- | --- | --- | --- | --- |
| 高吞吐日志流 | 强 | 中到强 | 强 | 弱到中 |
| 可回放 | 强 | 中 | 强 | 弱 |
| 多 Consumer Group / 订阅 | 强 | 强 | 强 | 通过多 Queue |
| 事务消息 | Kafka 内部事务强，业务双写仍要 Outbox | 原生业务事务消息强 | 有事务能力，需结合场景 | 不主打 |
| 延迟消息 | 原生不强，常用调度层 | 强 | 支持延迟 / 定时能力 | TTL + DLX / 插件 |
| 死信 | 业务自建 DLQ Topic | 内建 DLQ | 支持 DLQ | DLX 成熟 |
| 复杂路由 | 弱 | Tag / SQL 过滤 | 订阅和命名空间能力 | Exchange 最强 |
| 海量 Topic / 多租户 | 要谨慎治理 | 较友好 | 强 | 大量 Queue 要谨慎 |
| 流计算生态 | 最强 | 中 | 中到强 | 弱 |
| 运维复杂度 | 中 | 中 | 高 | 低到中 |

表格不是绝对真理，只是选型时的方向感。

## 场景选型

### 用户行为日志、埋点、服务日志

推荐倾向：Kafka。

理由：

- 高吞吐。
- Batch + Compression 收益大。
- 多个下游复用。
- Flink / 数据湖生态强。
- 可重放。

Pulsar 也可以，尤其是多租户、长 backlog、云原生隔离很强时。

RabbitMQ 不适合当日志中枢。

### CDC、数据湖、实时数仓

推荐倾向：Kafka。

理由：

- Debezium / Kafka Connect / Flink / 湖仓生态成熟。
- offset 回放能力天然。
- 多下游消费同一份变更流。

Pulsar 也可用于类似场景，但要看团队生态和连接器成熟度。

RocketMQ / RabbitMQ 通常不是 CDC 主战场。

### 订单、支付、库存业务事件

推荐倾向：RocketMQ / Kafka。

怎么选：

- 如果最看重事务消息、延迟消息、消费重试、DLQ，RocketMQ 更自然。
- 如果公司已经把业务事件平台、Flink、数据湖都建在 Kafka 上，Kafka 也可以胜任，但要配 Outbox、幂等、DLQ、重放治理。

不要只因为“业务消息”就排除 Kafka。

关键看平台能力和团队经验。

### 订单超时取消、延迟任务

推荐倾向：RocketMQ / RabbitMQ。

理由：

- RocketMQ 延迟消息更贴近业务。
- RabbitMQ TTL + DLX 或延迟插件也常见。
- Kafka 原生不是延迟队列，通常要额外调度层。

如果延迟任务非常复杂，比如百万级定时任务、取消、修改时间、查询状态，甚至应该考虑专门调度系统，而不是单纯 MQ。

### 复杂路由和任务队列

推荐倾向：RabbitMQ。

理由：

- Exchange / Binding / Routing Key 天然。
- Direct / Fanout / Topic 路由成熟。
- ack / reject / nack / prefetch / TTL / DLX 很贴近任务处理。

Kafka 做这类会比较别扭。

### 云原生多租户消息平台

推荐倾向：Pulsar / Kafka。

怎么选：

- 强多租户、海量 Topic、存储计算分离、长 backlog、跨地域，Pulsar 值得重点评估。
- 生态成熟、数据流工具链、团队经验、Flink/CDC，Kafka 更稳。

如果团队没有 Pulsar 运维经验，不要低估 Broker + BookKeeper + 元数据体系的复杂度。

### IoT / 海量设备接入

可能倾向：Pulsar / Kafka / 专用 IoT 平台。

看主矛盾：

- 设备消息进入数据湖和实时计算：Kafka / Pulsar。
- 强多租户和 Topic 隔离：Pulsar。
- MQTT 协议、设备管理、影子状态：专用 IoT 平台更合适。

不要把 Kafka 当设备接入协议网关。

### 低吞吐后台任务

推荐倾向：RabbitMQ / Redis Queue / 云队列。

如果只是：

```text
每天几万条任务
失败重试
死信
管理界面
```

Kafka 可能太重。

## Kafka 的边界：这些事别让它单独背

### 不要让 Kafka 负责业务事务一致性

业务数据库和 Kafka 双写：

```text
写 DB
send Kafka
```

中间一定有缝。

解决方案是：

- Outbox。
- CDC。
- RocketMQ 事务消息。
- 业务补偿和对账。

Kafka 事务 Producer 不能自动把 MySQL、Redis、HTTP 调用一起纳入原子事务。

### 不要让 Kafka 负责单条任务重试闭环

Kafka Consumer 提交的是 offset，不是单条 ack。

单条失败要你自己设计：

- 重试策略。
- DLQ Topic。
- 原始消息保存。
- 错误原因。
- 修复和重放工具。
- 幂等。

如果你不想做这些，RabbitMQ / RocketMQ 可能更省心。

### 不要让 Kafka 负责复杂路由

Kafka 没有 RabbitMQ 那种 Exchange / Binding 模型。

常见替代：

- 按业务语义拆 Topic。
- Consumer 自己过滤。
- Flink 做清洗分流。
- Kafka Streams 分流到新 Topic。

如果路由规则是主需求，RabbitMQ 更自然。

### 不要让 Kafka 负责长期审计存储

Kafka retention 适合短中期保留和回放。

多年审计要落：

- S3 / HDFS / 对象存储。
- 数据湖。
- 数仓。
- 审计数据库。

Kafka 不是长期归档系统。

### 不要让 Kafka 负责任意查询

Kafka 只能顺序读、按 offset / key 定位有限场景。

查询视图应该落：

- Elasticsearch / OpenSearch。
- ClickHouse / Druid。
- Redis。
- MySQL / PostgreSQL。
- 湖仓表。

Kafka 提供事件，不提供查询模型。

### 不要让 Kafka 替代工作流

多步骤业务：

```text
提交申请
校验
风控
人工审核
补材料
通过 / 拒绝
```

这需要状态机 / 工作流。

Kafka 可以记录事件，但不负责：

- 当前流程状态。
- 超时推进。
- 人工回调。
- 补偿路径。
- SLA 可视化。

## 反过来：什么时候 Kafka 仍然可以做业务消息

Kafka 不是不能做业务消息。

它适合这些业务消息：

- 事实事件流。
- 多下游订阅。
- 需要回放。
- 下游包括实时计算和数仓。
- 流量较大。
- 团队有 Kafka 平台治理能力。

例如：

```text
order.events
payment.events
inventory.events
```

如果配套齐全：

- Outbox / CDC。
- `acks=all`。
- 幂等 Producer。
- Consumer 幂等。
- DLQ。
- Schema Registry。
- lag 告警。
- 回放工具。
- raw 归档。

Kafka 做核心业务事件平台是完全可以的。

关键是不要把 Kafka 当 RabbitMQ 用，也不要把数据流治理省掉。

## 选型决策树

可以按这个顺序问：

### 1. 消息需要回放吗？

需要：

- Kafka / Pulsar 优先。

不需要，消费完就可以删：

- RabbitMQ / RocketMQ 也许更自然。

### 2. 是否有多个下游独立消费同一份数据？

是：

- Kafka / Pulsar 优先。

否，只是任务分发：

- RabbitMQ / RocketMQ。

### 3. 是否强依赖事务消息 / 延迟消息 / 内建重试 DLQ？

是：

- RocketMQ 优先。
- RabbitMQ 适合 TTL / DLX / 任务队列。

否：

- Kafka / Pulsar 可继续评估。

### 4. 是否复杂路由是核心？

是：

- RabbitMQ。

否：

- Kafka / RocketMQ / Pulsar 继续看其他维度。

### 5. 是否强多租户、海量 Topic、存储计算分离？

是：

- Pulsar 值得重点评估。

否：

- Kafka / RocketMQ / RabbitMQ 按语义选。

### 6. 是否主要服务数据湖、Flink、CDC、实时分析？

是：

- Kafka 优先。

否：

- 看业务消息、路由、延迟、多租户等主矛盾。

### 7. 团队会运维谁？

最后一定要问：

- 团队熟悉哪个？
- 公司已有哪个平台？
- 监控和排障工具是否成熟？
- 线上事故谁能兜？
- 是否有 Schema、DLQ、重放、权限、配额治理？

很多选型不是技术本身输赢，而是团队能力决定边界。

## 对比总结表

| 维度 | Kafka | RocketMQ | Pulsar | RabbitMQ |
| --- | --- | --- | --- | --- |
| 核心模型 | 分布式日志 | 业务消息 + CommitLog | 多租户消息 / 流平台 | Exchange + Queue |
| 主场 | 数据流、日志、CDC、Flink | 交易业务消息 | 云原生多租户、长 backlog | 任务队列、复杂路由 |
| 消费状态 | Offset | 消费状态 / 重试 | Subscription cursor | Ack / nack |
| 回放 | 强 | 中 | 强 | 弱 |
| 延迟消息 | 需额外设计 | 强 | 支持，需看场景 | TTL/DLX/插件 |
| 事务消息 | Kafka 内部强，外部需配合 | 业务事务消息强 | 有事务能力 | 不主打 |
| 复杂路由 | 弱 | 中 | 中 | 强 |
| 流计算生态 | 很强 | 中 | 中到强 | 弱 |
| 多租户 | 需要治理 | 中 | 强 | vHost/Queue 隔离，中等 |
| 运维复杂度 | 中 | 中 | 高 | 低到中 |
| 最怕误用 | 当单条任务队列 | 当数据湖日志总线 | 小团队低估复杂度 | 当高吞吐可回放日志 |

## 常见误区

### 误区一：Kafka 性能最好，所以都用 Kafka

性能不是唯一指标。

如果你的核心需求是：

- 延迟 30 分钟投递。
- 失败自动重试 16 次。
- 超过次数进 DLQ。
- 每条消息手动 ack。

RocketMQ / RabbitMQ 可能更贴合。

Kafka 也能做，但要补很多平台能力。

### 误区二：RabbitMQ 简单，所以不需要治理

RabbitMQ 上线快，但也要治理：

- Queue 堆积。
- unacked 消息。
- prefetch。
- DLX。
- TTL。
- 消费者重试风暴。
- 单队列热点。

中小规模简单，不代表没边界。

### 误区三：Pulsar 云原生，所以一定比 Kafka 新

Pulsar 的架构很有吸引力，但组件更多。

如果团队没有 BookKeeper、ledger、cursor、namespace、tiered storage 的运维经验，复杂度会真实落到事故里。

技术先进不等于落地成本低。

### 误区四：RocketMQ 有事务消息，所以端到端强一致

RocketMQ 事务消息解决的是：

```text
本地事务结果
和
消息是否对消费者可见
```

它不保证消费者处理一定成功。

下游仍然要：

- 重试。
- 幂等。
- DLQ。
- 对账。
- 补偿。

### 误区五：Kafka exactly-once 覆盖所有外部系统

Kafka EOS 主要覆盖 Kafka 内部：

- 幂等写。
- 事务写多个 Kafka Partition。
- consume-process-produce 场景下 offset 和输出绑定。

写 MySQL、Redis、HTTP、第三方接口，仍然要靠：

- 幂等键。
- 本地事务。
- Outbox / Inbox。
- 事务 sink。
- 对账补偿。

## 面试怎么回答

如果被问“Kafka、RocketMQ、Pulsar、RabbitMQ 怎么选”，可以这样答：

> 我不会按“谁性能最好”来选，而是先看消息语义。Kafka 是分布式提交日志，核心价值是高吞吐、可回放、多 Consumer Group 独立消费，所以适合日志、埋点、CDC、数据总线、Flink / Spark 流计算入口。它不擅长单条消息级别的 ack、复杂路由、原生延迟消息和业务重试 DLQ，这些要业务或平台补。
>
> RocketMQ 更偏业务消息，CommitLog + ConsumeQueue 的存储模型对大量业务 Topic 友好，而且事务消息、延迟消息、顺序消息、消费失败重试和 DLQ 更贴近电商交易场景。RabbitMQ 是 AMQP 路由系统，Exchange / Queue / Binding / RoutingKey 很适合复杂路由、任务队列、TTL、DLX、manual ack，但不适合当超高吞吐、可回放的日志总线。Pulsar 和 Kafka 最像，但它是 Broker 和 BookKeeper 存储分离的云原生多租户平台，适合强多租户、海量 Topic、长 backlog、分层存储、跨地域复制，但运维复杂度也更高。
>
> 所以我的判断路径是：如果要可回放数据流和流计算生态，优先 Kafka；如果要业务事务消息、延迟、重试和 DLQ，优先 RocketMQ；如果要复杂路由和任务投递，优先 RabbitMQ；如果要云原生多租户、存储计算分离和海量 Topic，重点评估 Pulsar。最后还要看团队已有生态、运维能力、监控、Schema、权限、配额、DLQ 和重放工具是否成熟。

这个回答的关键是：**四个系统不是同一把尺上的性能排名，而是四套消息哲学。**

## 这一篇要带走的结论

- Kafka、RocketMQ、Pulsar、RabbitMQ 都能收发消息，但核心模型完全不同。
- Kafka 是日志系统，适合高吞吐、可回放、多下游、CDC、Flink、数据总线。
- RocketMQ 是业务消息系统，适合事务消息、延迟消息、顺序消息、消费重试和 DLQ。
- Pulsar 是云原生多租户消息 / 流平台，适合存储计算分离、海量 Topic、长 backlog、分层存储、跨地域。
- RabbitMQ 是 AMQP 路由队列系统，适合复杂路由、任务队列、TTL、DLX、单条 ack。
- Kafka 不应该单独承担业务双写一致性、单条任务重试闭环、复杂路由、长期审计存储和任意查询。
- Kafka 可以做核心业务事件平台，但必须配 Outbox / CDC、业务幂等、DLQ、Schema、回放和审计。
- 选型要先看主矛盾，再看团队生态、运维能力和治理体系。

---

到这里，Kafka 专题 18 篇主线完成。真正学完 Kafka，不是记住一堆参数，而是能把它放回系统里判断：它什么时候是最好的分布式日志，什么时候只是被硬拽来做一件并不适合它的事。
