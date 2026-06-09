# Kafka 作为基础设施：数据总线 / CDC / 日志中枢 / 与 Flink 配合

前面我们一直在拆 Kafka 自己：

- Topic、Partition、Replica。
- Producer、Consumer。
- 幂等、事务、Rebalance。
- 丢失、重复、顺序、积压。
- 线程模型、排障、性能调优。

这一篇换个视角：**Kafka 在一家公司里到底放在哪一层？**

如果只把 Kafka 当成“发消息的工具”，你会把它用小。

Kafka 更常见的生产定位是：

> 公司级实时数据基础设施。

它把业务事件、数据库变更、日志、埋点、监控、实时计算输入、数仓入湖入口连接起来，让多个下游可以各自消费、各自回放、各自维护进度。

## 这一篇要回答什么

1. Kafka 为什么适合作为数据总线？
2. 数据总线和业务命令队列有什么区别？
3. CDC 链路怎么接 Kafka，binlog 到 Topic 之间有哪些坑？
4. 日志中枢 / 埋点中枢为什么天然适合 Kafka？
5. Kafka 和 Flink 怎么配合，offset、checkpoint、exactly-once 分别是谁负责？
6. Schema、事件版本、Topic 命名、权限、配额怎么治理？
7. Kafka 作为基础设施的边界是什么，哪些事情不该让它背？

先给结论：

> Kafka 适合做数据总线，是因为它是可持久、可回放、多消费者独立进度的分布式日志。业务服务、CDC、日志采集都可以把“事实事件”写入 Kafka，下游风控、推荐、搜索、Flink、数仓、数据湖各自用不同 Consumer Group 消费。Kafka 负责可靠存储和分发事件，但它不是业务真相源、不是数据库、不是 RPC、不是工作流引擎，也不会自动解决 Schema 演进、业务幂等和端到端 exactly-once。真正生产化要同时治理事件语义、Topic 设计、Schema 契约、权限配额、回放策略、DLQ 和下游幂等。

## Kafka 在公司里的位置

一个典型的数据基础设施图：

```text
业务服务
  ├─ 领域事件 Producer
  ├─ Outbox Relay
  └─ CDC Source

数据库
  └─ binlog / WAL

日志 / 埋点 / 监控
  └─ Agent / SDK

                │
                ▼
          Kafka Cluster
      持久化、分区、复制、回放
                │
      ┌─────────┼─────────┬─────────┬─────────┐
      ▼         ▼         ▼         ▼         ▼
    Flink     搜索索引   风控服务   数仓入湖   告警监控
  实时计算     ES/OpenSearch  Online    S3/HDFS   Metrics
```

Kafka 在中间，不是为了“所有系统都绕一圈更酷”，而是解决几个具体问题：

- 上游不需要知道有多少下游。
- 下游慢了不拖垮上游。
- 下游可以各自重放历史。
- 同一份数据可以给实时、离线、在线服务复用。
- 数据生产和数据消费的节奏解耦。

这就是第一篇里说的 N×M 数据集成问题：

```text
没有 Kafka:
  N 个上游 × M 个下游 = N*M 条专线

有 Kafka:
  N 个上游 -> Kafka -> M 个下游
```

当然，这不是免费午餐。

你把 Kafka 放进中间后，也引入了：

- Topic 治理。
- Schema 治理。
- 消费积压。
- 重复消费。
- 权限隔离。
- 回放冲击。
- 数据血缘。
- 多租户资源争抢。

所以 Kafka 作为基础设施，核心不是“部署一个集群”，而是“建立一套数据契约和运维治理”。

## 数据总线：发布事实，不是远程命令

Kafka 很适合承载**事实事件**。

事实事件的语义是：

> 某件事已经发生了。

比如：

- `order_created`
- `payment_succeeded`
- `inventory_reserved`
- `user_registered`
- `merchant_status_changed`
- `shipment_delivered`

它不是命令：

- `create_order`
- `charge_payment`
- `reserve_inventory`
- `send_email`

命令语义是：

> 请某个下游去做一件事。

两者非常容易混，但边界必须清楚。

### 事实事件适合 Kafka

```text
订单服务
  -> 发布 order_created

风控服务订阅
推荐服务订阅
数仓订阅
搜索订阅
客服系统订阅
```

订单服务只负责说：“订单已创建。”

它不关心：

- 风控是否消费成功。
- 推荐是否更新特征。
- 数仓是否入湖。
- 搜索是否建索引。

下游失败由下游自己重试、补偿、告警。

这是事件驱动的解耦。

### 命令队列要谨慎放 Kafka

如果上游发：

```text
send_coupon_to_user
```

并且业务要求：

```text
优惠券系统必须立刻执行成功，否则上游业务失败
```

那这不是真正解耦。

你只是把同步 RPC 换成了异步消息，但业务依赖仍然是强耦合。

这种场景可能更适合：

- RPC。
- 任务队列。
- 工作流编排。
- 事务消息。
- Saga 编排。

Kafka 可以承载命令类消息，但要明确：

- 谁负责超时？
- 谁负责重试？
- 谁负责 DLQ？
- 谁负责业务补偿？
- 上游是否等待结果？

如果这些都没想清楚，就不要把 Kafka 当万能异步化工具。

## 事件设计：一条好事件长什么样

一个基础事件通常至少包含：

```json
{
  "event_id": "01J7Z...",
  "event_type": "payment_succeeded",
  "event_version": 3,
  "occurred_at": "2026-06-10T12:00:00Z",
  "published_at": "2026-06-10T12:00:01Z",
  "producer": "payment-service",
  "aggregate_type": "payment",
  "aggregate_id": "pay_123",
  "aggregate_version": 15,
  "trace_id": "trace_abc",
  "payload": {
    "payment_id": "pay_123",
    "order_id": "ord_456",
    "amount": 19900,
    "currency": "CNY",
    "status": "SUCCEEDED"
  }
}
```

这些字段各有作用：

| 字段 | 作用 |
| --- | --- |
| `event_id` | 幂等去重 |
| `event_type` | 下游路由和语义识别 |
| `event_version` | Schema 演进 |
| `occurred_at` | 业务发生时间，Flink event time 常用 |
| `published_at` | 事件发布时间，用于链路延迟 |
| `producer` | 数据血缘 |
| `aggregate_id` | 分区 key、幂等、顺序 |
| `aggregate_version` | 状态更新类事件的乱序防护 |
| `trace_id` | 跨服务追踪 |
| `payload` | 业务内容 |

这里最重要的是：**事件要有业务身份，不要只依赖 Kafka offset。**

Kafka offset 只能表示：

```text
这条消息在这个 Topic-Partition 的位置
```

它不能表示：

- 这是哪个业务动作。
- 是否和另一条消息重复。
- 是否是同一个实体的新版本。
- 是否能安全重放。

业务幂等必须靠业务字段。

## Topic 设计：按语义分，不按消费者分

Topic 设计常见错误：

```text
order_for_flink
order_for_es
order_for_dw
order_for_risk
```

这其实把 Kafka 又用回了“下游专线”。

更好的设计通常是按事实语义：

```text
order.events
payment.events
inventory.events
merchant.status.events
user.behavior.events
```

下游用不同 Consumer Group：

```text
topic: order.events
  group: flink-risk
  group: es-indexer
  group: data-lake-ingest
  group: customer-service-projection
```

Topic 应该回答：

> 这是一类什么事实？

Consumer Group 回答：

> 谁在用这份事实？

### Topic 粒度太粗的问题

如果把所有业务事件都塞进一个 Topic：

```text
business.events
```

问题会很多：

- 下游要过滤大量无关事件。
- Schema 混杂。
- 权限不好控。
- retention 不能按业务差异配置。
- 热点业务拖慢所有订阅者。
- 分区 key 很难统一。

### Topic 粒度太细的问题

如果每个小动作一个 Topic：

```text
order_created
order_paid
order_cancelled
order_confirmed
order_refunded
```

也会带来：

- Topic / Partition 数爆炸。
- Controller metadata 压力。
- 下游订阅复杂。
- 事件关联困难。
- 运维治理成本上升。

一个实用折中：

- 同一业务域、同一实体生命周期的事件放一个 Topic。
- 事件类型用 `event_type` 区分。
- 差异很大的吞吐、权限、retention、Schema，再拆 Topic。

比如：

```text
order.events
payment.events
user.behavior.events
```

而不是：

```text
all.events
```

也不是：

```text
order_created.events
order_paid.events
order_cancelled.events
```

## 分区 key：既影响顺序，也影响吞吐

事件流里最常见的 key 是实体 ID：

```text
order_id
payment_id
user_id
merchant_id
```

这样可以保证同一个实体的事件进入同一个 Partition：

```text
order_id = 1001
  -> order_created
  -> order_paid
  -> order_shipped
```

下游能按顺序处理这个订单。

但 key 也会造成热点：

```text
merchant_id = big_merchant
```

一个大商户产生 30% 流量，全部打到一个 Partition，吞吐就被单 Partition 锁死。

治理手段：

- 换更细粒度 key，比如 `order_id` 而不是 `merchant_id`。
- 对热点 key 加 bucket：`merchant_id + bucket_no`。
- 对需要聚合的下游再用 Flink keyed state 二次聚合。
- 对超热点租户单独 Topic 或单独集群。

代价是：

> 加 bucket 会牺牲这个大 key 的全局顺序。

所以 key 设计永远是顺序、并发、业务语义之间的权衡。

## CDC：数据库变更进入 Kafka

CDC 全称 Change Data Capture。

它的目标是：

> 捕获数据库里的增量变更，把它们变成事件流。

常见链路：

```text
MySQL binlog / PostgreSQL WAL
        │
        ▼
Debezium / Canal / Maxwell / 自研采集器
        │
        ▼
Kafka Topic
        │
        ├─ Flink 实时宽表 / 指标
        ├─ 搜索索引
        ├─ 缓存刷新
        ├─ 数据湖 / 数仓
        └─ 下游微服务投影
```

CDC 的价值：

- 不侵入业务代码。
- 不让下游直连业务库。
- 能按数据库提交顺序捕获变化。
- 能回放。
- 能同时喂多个下游。

但 CDC 不是魔法。

### CDC 事件不是领域事件

数据库 CDC 通常长这样：

```json
{
  "op": "u",
  "before": {
    "status": "PENDING"
  },
  "after": {
    "status": "PAID"
  },
  "source": {
    "db": "order_db",
    "table": "orders",
    "binlog_file": "mysql-bin.000123",
    "pos": 456789
  }
}
```

它表达的是：

> orders 表某行从 before 变成 after。

领域事件表达的是：

> 订单已支付。

这两个语义不同。

| 类型 | 优点 | 缺点 |
| --- | --- | --- |
| CDC 事件 | 自动、完整、贴近数据库事实 | 语义偏技术，暴露表结构 |
| 领域事件 | 业务语义清楚，下游更好理解 | 需要业务代码可靠发布 |

不要把 CDC 直接当作所有领域事件的替代品。

比如订单状态从 `PENDING` 变成 `PAID`，可能表示：

- 用户支付成功。
- 人工补单成功。
- 对账修复。
- 测试数据修正。

CDC 只看到字段变化，不一定知道业务原因。

### CDC 常见用途

CDC 很适合：

- 数据湖 / 数仓入湖。
- 搜索索引同步。
- 缓存刷新。
- 审计。
- 下游只需要最终状态投影。
- 老系统无代码侵入改造。

CDC 不太适合单独承载：

- 复杂业务意图。
- 强语义领域事件。
- 需要明确业务原因的事件。
- 跨聚合的一次业务动作。

一个稳的组合：

```text
核心业务语义:
  领域事件 / Outbox

数据同步和分析:
  CDC
```

### Outbox + CDC

关键事件发布里很常见的一种方案：

```text
业务事务
  ├─ 写 order 表
  └─ 写 outbox_event 表

CDC 订阅 outbox_event 表
  -> 发布到 Kafka
```

好处：

- 业务数据和待发布事件在同一个本地事务里。
- 应用不用在事务里直接依赖 Kafka。
- Kafka 不可用时，outbox 事件还在数据库里。
- CDC / Relay 可以稍后补发。

这比“业务库写成功后立即 send Kafka”稳得多。

注意：

- outbox 表要有唯一 `event_id`。
- Relay / CDC 下游要幂等。
- outbox 事件投递成功后要有清理策略。
- 如果使用 CDC 位点推进，也要监控位点滞后。

## Kafka Connect：连接器层

Kafka Connect 的定位是：

> 标准化 Source 和 Sink，把外部系统和 Kafka 接起来。

Source Connector：

```text
MySQL / PostgreSQL / MongoDB / 文件 / S3
  -> Kafka
```

Sink Connector：

```text
Kafka
  -> Elasticsearch / S3 / HDFS / JDBC / ClickHouse / Redshift
```

它解决的是工程重复劳动：

- 任务分布式运行。
- offset / source position 管理。
- 配置化连接。
- 失败重试。
- 基本转换。
- connector 生态复用。

但不要误解：

> Kafka Connect 不是业务 ETL 引擎，也不是复杂规则系统。

适合 Connect 的：

- 数据搬运。
- 标准化 CDC。
- S3 / HDFS 落地。
- 搜索索引同步。
- JDBC sink 这类通用同步。

不适合 Connect 的：

- 复杂事件关联。
- 大状态计算。
- 乱序窗口聚合。
- 复杂业务补偿。

这些更适合 Flink、Spark、应用服务或专门 ETL 作业。

## 日志中枢 / 埋点中枢

日志、埋点、监控事件是 Kafka 的经典场景。

特点：

- 写入量大。
- 单条价值相对低。
- 可批量。
- 可压缩。
- 多下游。
- 需要回放。
- 容忍最终一致。

典型链路：

```text
App / Web / Server
  -> SDK / Agent
  -> Kafka
  -> Flink 实时指标
  -> S3 / HDFS 原始日志
  -> ClickHouse / Druid / Elasticsearch 查询
  -> 告警系统
```

为什么适合 Kafka：

- 高吞吐。
- Batch + Compression 效果好。
- 多 Consumer Group 复用同一份日志。
- 下游出 bug 可重放。
- retention 可控。

但日志中枢也有治理点：

- 埋点 Schema 要版本化。
- 不能让客户端随便发任意字段。
- 要有采样和限流。
- 要区分原始日志、清洗后日志、聚合指标。
- 要处理脏数据和 DLQ。
- 要防止某个业务爆量拖垮共享集群。

### 原始层、清洗层、聚合层

日志数据常见三层：

```text
raw topic
  原始事件，尽量少改，保留可回放能力

clean topic
  清洗、补字段、过滤脏数据、统一 schema

aggregate topic
  窗口聚合、指标、画像、特征
```

例如：

```text
app.click.raw
  -> Flink 清洗
app.click.clean
  -> Flink 聚合
app.click.metrics.1m
```

这样做的好处：

- 原始事件可重放。
- 清洗逻辑出错可以重跑。
- 下游不用每个人都重复清洗。
- 聚合结果和原始明细分层管理。

## Kafka + Flink：实时计算入口

Kafka 和 Flink 是很常见的一对。

Kafka 负责：

- 事件持久化。
- 分区。
- 回放。
- 多消费者。
- 削峰。

Flink 负责：

- 有状态计算。
- 窗口。
- 乱序处理。
- Join。
- Exactly-once 状态快照。
- 实时结果输出。

典型链路：

```text
Kafka source
  -> Flink job
      -> map / filter / keyBy / window / join
      -> checkpoint
  -> Kafka sink / OLAP / 数据湖 / DB
```

### Offset 谁管理

普通 Kafka Consumer：

```text
处理成功
  -> commit offset 到 __consumer_offsets
```

Flink 读 Kafka 时，offset 通常和 checkpoint 绑定：

```text
Flink 从 Kafka 读到 offset 1000
  -> 状态计算
  -> checkpoint 成功
  -> 这个 checkpoint 记录 Kafka offset + Flink state
```

故障恢复时：

```text
从最近成功 checkpoint 恢复 state
从 checkpoint 里的 Kafka offset 继续读
```

这保证了：

- Flink 状态和 Kafka 消费位点一致恢复。
- 不会出现状态是新的、offset 是旧的这种错位。

所以 Flink 里不要用普通 Consumer 的思维去手动 commit offset。

### Event time 和 watermark

Kafka 只保存消息顺序和时间戳，不理解业务时间。

Flink 需要自己定义：

- event time：业务发生时间。
- processing time：Flink 处理时间。
- watermark：认为“某个时间之前的数据大概率都到了”的进度线。

例子：

```text
用户 12:00:00 点击
网络延迟
12:00:10 才到 Kafka
12:00:12 被 Flink 消费
```

如果做“12:00 这一分钟点击数”，应该按 event time 算，而不是按 Kafka 到达时间。

事件里就需要有：

```json
{
  "occurred_at": "2026-06-10T12:00:00Z"
}
```

并且 Flink 要设置 watermark 容忍乱序：

```text
允许最多乱序 30 秒
```

否则迟到数据会被漏算或算到错误窗口。

### Exactly-once 到底是谁的 exactly-once

Kafka + Flink 里“exactly-once”很容易被误解。

Flink checkpoint 可以保证：

> Flink 内部状态和 Kafka source offset 一致恢复。

Kafka transaction sink 可以进一步保证：

> Flink 写 Kafka 下游 Topic 时，checkpoint 成功才提交事务，失败则中止。

但端到端 exactly-once 还取决于 sink。

| Sink | 端到端语义 |
| --- | --- |
| Kafka Sink + 事务 | 可以做到较强 exactly-once |
| 数据湖表格式支持事务提交 | 可以做到 checkpoint 对齐提交 |
| 普通 JDBC 写入 | 通常要靠幂等键或 upsert |
| Redis / 外部 RPC | 通常是 at-least-once + 幂等 |
| Elasticsearch | 常用文档 ID 幂等覆盖 |

所以不要笼统说：

> “Flink + Kafka 就是 exactly-once。”

更准确的说法是：

> Flink 可以通过 checkpoint 管理 Kafka offset 和内部状态；如果下游 sink 支持事务或幂等提交，才能实现业务可观察的 effectively-once / exactly-once。

### Flink 反压会传回 Kafka 吗

Flink 处理慢时：

```text
Flink operator 反压
  -> source 读取变慢
  -> Kafka consumer lag 上升
```

Kafka 不会因为 Flink 慢就丢数据，只要 retention 够。

但如果 Flink 长时间追不上：

- consumer lag 持续上涨。
- 可能超过 retention，旧数据被删。
- checkpoint 变慢。
- state 变大。
- 下游延迟升高。

治理：

- 看 Flink backpressure。
- 看哪个 operator 慢。
- 增加 parallelism。
- 调整 Kafka Partition 数。
- 优化 state backend。
- 优化窗口和 join。
- 下游 sink 批量写。
- 保证 Kafka retention 能覆盖最大恢复时间。

### Kafka Partition 和 Flink parallelism

Flink Kafka Source 的并行度受 Kafka Partition 影响。

如果 Topic 只有 4 个 Partition：

```text
Flink source parallelism = 16
```

也只有 4 个 subtask 真正有数据。

所以流计算 Topic 的 Partition 数要按：

- 峰值吞吐。
- Flink source parallelism。
- 未来扩容。
- keyBy 后的数据倾斜。

一起设计。

但也不能无限加 Partition，因为第 16 篇讲过，Partition 是并发单位，也是成本单位。

### Flink 读取多个 Topic

常见场景：

```text
订单事件 Topic
支付事件 Topic
退款事件 Topic
```

Flink 做关联：

```text
order_id keyBy
  -> join / interval join / stateful process
```

要注意：

- 不同 Topic 的事件时间可能乱序。
- 每个 Topic 的水位推进不同。
- 某个 Topic 长时间没数据会影响 watermark。
- Join state 需要 TTL。
- 缺失事件要有补偿或旁路。

这已经不是 Kafka 问题，而是流计算设计问题。

## 数据湖 / 数仓：Kafka 不是终点

Kafka 可以保留历史，但它不是长期数仓。

原因：

- Kafka retention 通常按天或周，不适合多年审计。
- Kafka 查询能力弱，只能按 offset 顺序读。
- 数据分析需要列式存储、分区裁剪、统计信息、SQL 优化。
- Schema 演进和历史回算需要更稳定的存储层。

常见做法：

```text
Kafka raw topic
  -> S3 / HDFS / 对象存储 raw zone
  -> 清洗表 / 明细表
  -> 数仓 / 湖仓 / OLAP
  -> BI / 报表 / 训练集
```

Kafka 在这里的价值：

- 吸收实时数据。
- 解耦上游和入湖任务。
- 保留短期可回放窗口。
- 支持实时和离线共用同一份事件。

数据湖 / 数仓负责：

- 长期保存。
- 分层建模。
- SQL 分析。
- 历史回算。
- 合规审计。
- 数据质量检查。

### Raw Zone 很重要

不要只保留清洗后的结果。

原始事件层有几个价值：

- 清洗逻辑错了可以重跑。
- 新增字段可以回填。
- 下游口径变了可以重算。
- 审计时能看到原始输入。
- Kafka retention 过期后仍能恢复。

所以常见设计：

```text
Kafka Topic
  -> S3 raw / HDFS raw
  -> Flink/Spark 清洗
  -> curated table
  -> warehouse / mart
```

## Schema 治理：数据总线的生死线

Kafka 本身只存 bytes。

它不知道 value 里是：

- JSON。
- Avro。
- Protobuf。
- String。
- 乱七八糟的半截日志。

所以数据总线必须治理 Schema。

### 为什么 Schema 重要

没有 Schema 治理时：

```text
上游把 amount 从 number 改成 string
  -> Flink 解析失败
  -> ES 写入失败
  -> 数仓入湖失败
  -> lag 暴涨
```

或者：

```text
上游删除字段 user_id
  -> 推荐特征缺失
  -> 模型效果下降
  -> 没人第一时间发现
```

Kafka 的解耦只解耦部署和消费进度，不自动解耦数据契约。

### Schema 演进规则

常见规则：

- 新增字段要给默认值或允许为空。
- 不要随意删除字段。
- 不要改变字段类型。
- 不要改变字段含义。
- 枚举新增值要通知下游。
- 语义变了就升 event version。
- 破坏性变更新建 Topic 或新版本事件。

例如：

```json
{
  "event_type": "payment_succeeded",
  "event_version": 2
}
```

下游可以按版本解析。

### JSON、Avro、Protobuf 怎么选

| 格式 | 优点 | 缺点 |
| --- | --- | --- |
| JSON | 可读性好，接入简单 | 体积大，类型弱，兼容性靠约定 |
| Avro | Schema 演进成熟，生态强 | 可读性差，需要 Schema Registry |
| Protobuf | 体积小，跨语言强 | JSON 调试不直观，字段编号要治理 |

小团队早期用 JSON 可以，但要有：

- 明确字段文档。
- 兼容规则。
- 示例事件。
- CI 校验。

中大型数据总线更推荐：

- Avro / Protobuf。
- Schema Registry。
- 兼容性检查。
- Schema owner。
- 版本治理。

## 权限、配额和多租户治理

Kafka 一旦成为基础设施，就会变成多租户系统。

多租户问题包括：

- 谁能写哪个 Topic？
- 谁能读哪个 Topic？
- 谁能创建 Topic？
- 谁能扩 Partition？
- 谁能改 retention？
- 谁能大规模回放？
- 谁占用了多少流量？

基础治理：

- ACL 控制读写权限。
- Topic 命名规范。
- Producer / Consumer quota。
- 默认 retention 策略。
- 大 Topic 审批。
- Partition 数审批。
- 回放任务限速。
- 核心 Topic 隔离。

一个共享 Kafka 集群如果没有 quota，很容易出现：

```text
某个团队从 earliest 启动历史回放
  -> Broker 磁盘冷读打满
  -> PageCache 被污染
  -> 其他业务 Fetch 延迟升高
  -> 全公司 lag 报警
```

所以 quota 是基础设施的安全带。

## DLQ、重放和数据修复

基础设施必须回答：

> 下游消费失败怎么办？

常见做法：

```text
主 Topic
  -> Consumer 处理
      -> 成功：commit offset
      -> 失败可重试：本地重试 / 延迟重试
      -> 失败不可处理：写 DLQ
```

DLQ 事件至少带：

- 原 Topic。
- 原 Partition。
- 原 Offset。
- 原 key。
- 原 value。
- 失败原因。
- 失败时间。
- Consumer Group。
- 重试次数。
- trace_id。

注意：

> DLQ 不是垃圾桶，是待处理队列。

要有：

- 告警。
- 查看工具。
- 修复流程。
- 重放工具。
- 重放限速。
- 幂等保障。

重放时特别小心：

- 不要冲垮下游。
- 不要破坏顺序。
- 不要重复造成副作用。
- 不要用旧 Schema 写新系统。
- 不要在业务高峰全量回放。

## 可观测性：数据链路也要有 SLO

Kafka 基础设施的指标不止 broker 指标。

要按链路看：

```text
Producer
  -> Kafka
  -> Flink / Consumer
  -> Sink
```

关键指标：

| 层 | 指标 |
| --- | --- |
| Producer | 发送速率、失败率、p99 latency、batch size、buffer wait |
| Kafka | Produce/Fetch latency、ISR、RequestQueue、磁盘、网络 |
| Consumer | lag、消费速率、处理耗时、commit latency、Rebalance |
| Flink | checkpoint duration、backpressure、watermark lag、state size |
| Sink | 写入延迟、失败率、批量大小、限流 |
| 数据质量 | 解析失败率、空字段率、重复率、延迟分布 |

数据链路 SLO 示例：

- 核心事件 99.9% 在 5 秒内进入 Kafka。
- 风控特征 99% 在 30 秒内更新。
- 数仓 raw 层 T+5 分钟可见。
- Flink checkpoint 连续失败不超过 3 次。
- Consumer lag 不超过 10 分钟生产量。
- DLQ 5 分钟内告警。

没有 SLO，Kafka 会变成“有问题但不知道严重不严重”的黑盒。

## Kafka 不是什么

### Kafka 不是业务真相源

业务真相通常在：

- 交易数据库。
- 领域服务状态。
- 审计存储。
- 数据湖 raw 层。

Kafka 是事件流和短中期日志，不应该成为唯一业务状态。

如果 Kafka retention 到期，消息会被删。

所以长期审计要落对象存储或数仓。

### Kafka 不是数据库

Kafka 不适合：

- 按任意字段查询。
- 复杂条件检索。
- 更新单条记录。
- 多表事务。
- 用户在线查询接口。

要做查询视图，应该由 Consumer 构建 read model：

```text
Kafka
  -> Consumer / Flink
  -> Redis / Elasticsearch / OLAP / DB
```

### Kafka 不是 RPC

Kafka 不适合把所有同步调用改成异步。

如果业务要求：

```text
用户提交请求后必须立即知道结果
```

同步 API 仍然要保留。

异步事件更适合：

- 通知。
- 分析。
- 搜索同步。
- 状态投影。
- 后置处理。
- 弱依赖下游。

### Kafka 不是工作流引擎

Kafka 可以承载事件，但不负责：

- 多步骤编排。
- 超时等待。
- 人工审批。
- Saga 状态机。
- 补偿决策。

这些更适合：

- 工作流引擎。
- 状态机。
- Saga orchestrator。
- 业务服务自己维护状态。

Kafka 只记录和传递事件。

### Kafka 不是大对象存储

大图片、大文件、大报告不要直接塞 Kafka。

更合理：

```text
对象存储保存大对象
Kafka 事件里放 object_key / url / checksum / metadata
```

这样能保护：

- Broker 网络。
- PageCache。
- Producer batch。
- Consumer 内存。
- 复制延迟。

## 一套生产化 Kafka 数据平台清单

如果一家公司说“我们要把 Kafka 做成数据总线”，至少要有这些东西：

### Topic 治理

- 命名规范。
- owner。
- 业务域。
- 数据等级。
- retention。
- 分区数。
- 副本数。
- key 规则。
- Schema。
- 下游列表。

### Schema 治理

- Schema Registry 或等价机制。
- 兼容性检查。
- 字段文档。
- 版本策略。
- 破坏性变更流程。
- 示例事件。
- CI 校验。

### 权限治理

- ACL。
- 服务账号。
- 读写分离。
- 生产 / 测试隔离。
- 敏感字段脱敏。
- 审计日志。

### 可靠性治理

- Producer callback。
- `acks=all`。
- 幂等 Producer。
- Outbox / CDC。
- Consumer 幂等。
- DLQ。
- 重放工具。
- 端到端校验。

### 运维治理

- Broker 指标。
- Consumer lag。
- Flink checkpoint。
- 数据质量指标。
- 磁盘水位。
- 配额。
- 回放审批。
- 容量规划。

### 数据资产治理

- 原始层归档。
- 数据血缘。
- 数据字典。
- 数据质量报告。
- 下游影响分析。
- 口径管理。

## 一个完整例子：订单事件平台

假设要设计订单事件平台。

### 上游

订单服务写数据库：

```text
orders 表
order_items 表
outbox_event 表
```

同一个本地事务：

```text
创建订单
  -> 写 orders
  -> 写 order_items
  -> 写 outbox_event(order_created)
```

CDC 订阅 outbox_event：

```text
outbox_event binlog
  -> Kafka order.events
```

### Topic

```text
order.events
key = order_id
value = OrderEvent
```

事件类型：

- `order_created`
- `order_paid`
- `order_cancelled`
- `order_shipped`
- `order_refunded`

### 下游

```text
group: risk-flink
  -> 实时风控特征

group: search-indexer
  -> 订单搜索索引

group: data-lake-ingest
  -> S3 raw zone

group: customer-service-view
  -> 客服查询 read model

group: notification-service
  -> 短信 / 邮件提醒
```

每个下游自己维护 offset、幂等和失败处理。

### Flink

Flink 读：

```text
order.events
payment.events
refund.events
```

按 `order_id` keyBy，构建订单实时状态：

```text
order_created + payment_succeeded + shipment_delivered
  -> order_lifecycle_view
```

输出：

- `order.lifecycle.metrics.1m`
- OLAP 明细表。
- 风控特征 Topic。

### 治理点

- `order.events` 的 Schema 由订单团队 owner。
- 破坏性字段变更要走 review。
- 关键下游有 lag 告警。
- DLQ 进入修复平台。
- raw event 落 S3 长期保存。
- 回放需要审批和限速。

这才是 Kafka 作为基础设施的完整形态。

## 面试怎么回答

如果被问“Kafka 在公司里怎么作为数据总线、CDC、日志中枢和 Flink 入口使用”，可以这样答：

> 我会先把 Kafka 定位成分布式日志，而不是普通队列。它适合做数据总线，因为消息持久化、可回放、多 Consumer Group 独立维护 offset。业务服务可以发布领域事件，CDC 可以把数据库 binlog / WAL 转成变更流，日志和埋点也可以进入 Kafka。下游风控、搜索、推荐、Flink、数仓入湖、监控告警用不同 Consumer Group 消费同一份数据，各自失败不拖上游。
>
> 设计上我会区分事实事件和命令消息。Kafka 更适合传播 `order_created`、`payment_succeeded` 这种已经发生的事实，而不是要求某个下游必须立即执行成功的远程命令。事件里要有 `event_id`、`event_type`、`event_version`、`occurred_at`、`aggregate_id`、`aggregate_version`、`trace_id` 等字段，Topic 按业务语义分，而不是按下游分。CDC 很适合数据同步、入湖、搜索索引，但它表达的是表变更，不一定等于领域事件；关键业务事件可以用 Outbox + CDC 保证本地事务和事件发布一致。
>
> Kafka 和 Flink 配合时，Kafka 负责持久化和回放，Flink 负责状态计算、窗口、乱序和 checkpoint。Flink 的 Kafka offset 会和 checkpoint 绑定，恢复时从 checkpoint 里的 offset 和 state 一起恢复。所谓 exactly-once 不能泛泛而谈，Flink 内部状态和 Kafka source offset 可以一致恢复，但端到端还取决于 sink 是否支持事务或幂等。作为基础设施还要治理 Schema、Topic owner、ACL、quota、retention、DLQ、重放工具、数据质量和 raw zone 归档。

这个回答的关键是：**Kafka 不是只会收发消息，而是公司实时数据链路的中间层；但它不替代业务真相源、数据库、RPC 和工作流引擎。**

## 这一篇要带走的结论

- Kafka 适合作为数据总线，因为它是持久、可回放、多消费者独立进度的分布式日志。
- 数据总线应该发布事实事件，不要把所有远程命令都塞进 Kafka。
- 好事件要有 `event_id`、事件类型、版本、业务时间、聚合 ID、聚合版本和 trace。
- Topic 应按业务语义分，不要按消费者分，也不要粗暴塞进一个万能 Topic。
- CDC 适合数据同步和入湖，但表变更不等于领域事件。
- Outbox + CDC 是关键业务事件发布里很稳的最终一致方案。
- Kafka Connect 适合标准数据搬运，复杂状态计算交给 Flink 等流处理引擎。
- Kafka + Flink 里，offset 和 checkpoint 绑定；端到端 exactly-once 取决于 sink。
- Kafka 不是业务真相源、不是数据库、不是 RPC、不是工作流引擎、不是大对象存储。
- 真正生产化的数据总线必须治理 Schema、权限、配额、DLQ、回放、数据质量和 raw 归档。

---

下一篇 `18_选型与边界：Kafka_vs_RocketMQ_vs_Pulsar_vs_RabbitMQ.md`，会做最后的横向收口：Kafka、RocketMQ、Pulsar、RabbitMQ 各自适合什么场景，哪些需求不要硬上 Kafka。
