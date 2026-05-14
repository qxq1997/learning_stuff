# 可观测性三件套：Metrics、Log、Trace 与排障落点

## 这一章想解决什么

§02–§05 讲的全是"故障发生时去机器上敲命令"——这是**事故响应**。但更上层的能力是**日常可观测性**：

- 故障还没发生时，监控大盘能告诉你"现在健康吗"
- 故障刚开始时，告警准确触发，且能直接指向问题区域
- 故障定位时，不用 SSH 进 100 台机器跑 jstack，而是从一个界面下钻到具体调用

可观测性靠 **Metrics（指标）/ Log（日志）/ Trace（链路）三件套**支撑。这一章解决三件事：

1. **三件套各自的本质和边界**——为什么必须三个都要、各自能回答什么、不能回答什么
2. **排障时的进入顺序**——Metrics 看面 → Trace 定位调用 → Log 看细节，这套顺序为什么是工业界共识
3. **怎么把这三件套真正用起来**——RED / USE / 黄金信号方法论、必须带的字段、告警分级、常见坑

不会讲具体产品的安装配置（那是 Prometheus / Grafana / SkyWalking 自己的文档的事）。**重点是方法论和落地姿势**。

## 一、三件套的本质：各自是什么、回答什么

### Metrics：聚合数字，定量趋势

Metrics 是**按时间聚合的数字**——QPS、错误率、P99 延迟、CPU 利用率、堆内存使用、GC 频率、连接数……每隔 N 秒采一次，存进时序数据库（Prometheus / InfluxDB / VictoriaMetrics）。

**本质**：

- 一个 metric 是 `(name, labels, value, timestamp)` 四元组
- 例：`http_request_duration_seconds{method="POST", route="/orders", status="200"} 0.025 @ 1715641200`
- 高度聚合 —— 一秒内 1000 个请求的耗时被压成 1 个直方图

**能回答的问题**：

- "现在 QPS 多少？"
- "P99 延迟过去一小时怎么变的？"
- "错误率突变发生在几点？"
- "CPU 用量是不是涨了？"

**不能回答的问题**：

- "为什么慢？"（只知道有慢的，不知道是哪个具体请求）
- "这个错是谁发起的？"（label 维度有限，不能存 userId 这种高基数字段）
- "请求链路里慢在哪一段？"

### Log：事件流，定性细节

Log 是**每一次发生的事件的文字记录**——每行一个事件，可以包含任意字段。

**本质**：

- 一条 log 是 `(timestamp, level, message, fields...)`
- 例：`2026-05-14T10:23:45.123Z ERROR [traceId=abc] failed to call payment: timeout after 3000ms userId=12345`
- 几乎不聚合，**每个事件都保留**

**能回答的问题**：

- "这个特定 traceId 的请求经过了哪些日志？"
- "9 点 23 分到 25 分之间发生了什么异常？"
- "userId=12345 的所有操作记录"

**不能回答的问题**：

- "总体趋势怎么样"（要看大盘还是得 Metrics）
- "P99 是多少"（log 不直接给统计）
- "调用链怎么走的"（一条日志只是一个事件，不能拼出链路）

### Trace：单次请求的因果链

Trace 是**一次请求在分布式系统里走过的所有节点和耗时**。

**本质**：

- 一个 Trace 是一棵 Span 树
- 每个 Span 是一次调用（HTTP / RPC / DB / Redis），有 `(traceId, spanId, parentSpanId, service, operation, start, duration, tags)`
- 整个 Trace 共享一个 `traceId`，子调用通过 `parentSpanId` 连成树

**能回答的问题**：

- "这个请求从入口到 DB 经过了哪几个服务？"
- "整条链路里哪一段最慢？"
- "失败是哪个下游引起的？"
- "DB 调用占了总耗时的多少？"

**不能回答的问题**：

- "整体 QPS / P99"（Trace 是单条，统计还是要 Metrics）
- "为什么这个 Span 慢"（要看 Log 或 Java 进程现场工具）

### 三件套的关系图

```
                   总览 / 趋势
                       ▲
                       │
                    Metrics
                       │ (告警触发后下钻)
                       ▼
                    Trace
                       │ (定位到具体调用)
                       ▼
                    Log
                       │
                       ▼
                   现场细节
```

**信息密度从上到下递增，聚合度从下到上递增**。Metrics 一秒可能聚合上万事件，Log 几乎是原始事件流，Trace 在中间——每条 Trace 是一个请求的完整故事。

## 二、三件套必须都要，缺一不可

经常有人问"我有 Log 全文检索（ELK）了，还要 Metrics 干嘛？" / "我有 Metrics 大盘了，还要 Trace 干嘛？"——**这三件套互相不能替代**：

| 缺哪个 | 缺什么能力 |
| --- | --- |
| 没 Metrics | **告警没基础**，没法做"P99 > X 触发告警"，故障靠用户反馈才知道；趋势看不见 |
| 没 Trace | 微服务里**没法定位慢在哪个服务**；只能挨个服务 grep 日志，一次排障要俩小时起步 |
| 没 Log | **细节全丢**；知道某个 Span 报错了，但报错原因、入参、异常栈都看不到 |

成本上：

- Metrics 最便宜——一个 metric 一天才几 MB
- Trace 中等——大流量场景 100% 采样存储压力大，**需要采样**（通常 1%–10%，或基于错误率的智能采样）
- Log 最贵——大流量服务一天上百 GB，**结构化 + 等级控制是关键**

## 三、排障的进入顺序：Metrics → Trace → Log

这是工业界的共识顺序，背后的逻辑：

```
1. Metrics 大盘（看面）
       ↓ 找到突变的指标、突变的时间窗口、突变的服务
2. Trace（找点）
       ↓ 在这个时间窗口里，拉一条 / 几条慢请求的 Trace，看链路里慢在哪
3. Log（看细节）
       ↓ 用 traceId 跨服务查日志，看具体异常、入参、栈
```

为什么这个顺序：

- **从聚合到细节**：先看大盘判断"是不是真有问题、范围多大、变化趋势"，再下钻看具体
- **从便宜到贵**：Metrics 查询毫秒级，Trace 几百 ms，Log 全文检索几秒~几十秒
- **避免无效工作**：直接 grep 日志的人会被日志噪音淹没；先 Metrics 圈出范围（具体服务 + 具体时间），再针对性查 Log，效率高十倍

**反模式**：

- 上来直接 SSH 到机器 grep 日志 —— 你都不知道是哪台机器、哪个时间窗口
- 看到告警立刻拉 jstack —— 不知道是哪个服务有问题、哪个接口慢

### 实战例子

告警："订单创建接口 P99 从 80ms 飙到 1200ms"

```
Step 1: Metrics 大盘
   - 看 order-service 的 P99 时序图，确认告警真实
   - 看 QPS / 错误率，QPS 没变 → 不是流量问题；错误率没涨 → 不是异常
   - 看下游依赖：payment-service / mysql / redis 的 P99
   - 发现 mysql 的 P99 也飙了 → 锁定 DB

Step 2: Trace
   - 在 Trace 系统过滤 service=order-service AND duration>500ms
   - 拉 3 条慢 Trace 看链路
   - 发现 80% 的耗时都在一个 mysql Span 上，Span 名 "SELECT ... FROM orders WHERE user_id=?"

Step 3: Log
   - 用某条慢 Trace 的 traceId 查日志：traceId="abc123"
   - 看到对应的 SQL log，慢查询 1100ms
   - DB 侧拉慢查询日志，EXPLAIN，定位到索引失效
```

不到 10 分钟从告警到根因，是因为**每一步都从上一步缩小了范围**，没有任何盲目搜索。

## 四、Metrics 深入：黄金信号、RED、USE 三大方法论

### 黄金信号（Google SRE）

四个维度，覆盖一个**服务**的所有关键状态：

| 信号 | 含义 | 例 |
| --- | --- | --- |
| **Latency**（延迟） | 请求耗时分布，重点 P99 | `http_request_duration_seconds_bucket` |
| **Traffic**（流量） | QPS / RPS | `http_requests_total[1m]` |
| **Errors**（错误） | 错误率 | `rate(http_requests_total{status=~"5.."}[1m]) / rate(http_requests_total[1m])` |
| **Saturation**（饱和度） | 资源利用率 + 排队 | CPU%、内存%、线程池排队数、DB 连接池使用率 |

**线上服务最低限度的监控就是这四个**。没有四金的服务等于裸奔。

### RED 方法（适合 request-driven 服务）

`Rate / Errors / Duration`——黄金信号的简化版，去掉饱和度：

- Rate = QPS
- Errors = 错误数（或错误率）
- Duration = 耗时分布

**RED 适合应用层服务**（Spring Boot 接口、Dubbo / gRPC 服务）。

### USE 方法（适合资源 / 容器）

`Utilization / Saturation / Errors`——给资源（CPU、内存、磁盘、网络）建模：

- Utilization：使用率（CPU% / 内存%）
- Saturation：饱和度（CPU 队列长度、内存换页、磁盘 await）
- Errors：错误（磁盘 IO 错、网卡丢包）

**USE 适合基础设施监控**（机器、数据库、Redis、中间件）。

### 工程上怎么落地

每个微服务都应该暴露：

```
# RED（应用层）
http_requests_total                       # counter，可算 QPS 和错误率
http_request_duration_seconds_bucket      # histogram，可算 P50/P99
http_request_duration_seconds_count
http_request_duration_seconds_sum

# 饱和度（应用层）
jvm_threads_states_threads                # 线程池状态
jvm_memory_used_bytes                     # JVM 各内存区
jvm_gc_pause_seconds                      # GC 停顿
hikaricp_connections_active               # DB 连接池
http_server_threads_busy                  # Tomcat 工作线程占用

# 业务指标
order_created_total                       # 订单创建数（业务"流量"）
payment_failed_total{reason="balance_insufficient"}  # 业务错误分桶
```

Spring Boot 用 Micrometer 接入 Prometheus 一行代码搞定，**没有任何理由不暴露**。

### Histogram vs Summary

Prometheus 的两种延迟指标类型，**搞清楚区别**：

| 类型 | 优势 | 劣势 |
| --- | --- | --- |
| **Histogram** | 服务端可聚合（跨实例算总 P99）；客户端计算开销极小 | 桶要预先定义，定义不好不准 |
| **Summary** | 客户端预算分位数，准 | **不能跨实例聚合**——10 个 Pod 各算自己的 P99，没法合并 |

**绝大多数场景用 Histogram**，因为微服务多实例必须能聚合。桶的定义经验：

```
[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]   秒
```

覆盖从 5ms 到 10s，对于一般业务接口够了。

### PromQL 速通

```promql
# QPS（最近 1 分钟均值）
sum(rate(http_requests_total[1m])) by (service)

# 错误率
sum(rate(http_requests_total{status=~"5.."}[1m])) by (service)
/
sum(rate(http_requests_total[1m])) by (service)

# P99
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket[1m])) by (le, service)
)

# JVM 堆使用率
jvm_memory_used_bytes{area="heap"} / jvm_memory_max_bytes{area="heap"}

# 横向对比：service A 比昨天同时刻慢了多少
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{service="A"}[5m])) by (le))
  -
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{service="A"}[5m] offset 1d)) by (le))
```

`rate()` 算每秒变化率（counter 类指标必经处理），`histogram_quantile()` 算分位数，`by (label)` 按 label 分组。这三个搞懂能解决 80% 的 PromQL 需求。

### 业务指标 vs 系统指标的重要分工

**系统指标**：CPU、内存、GC、连接池——告诉你"系统健康吗"
**业务指标**：订单数、支付成功率、转化率——告诉你"业务健康吗"

线上有这么一种事故：**系统指标全绿但业务全挂**。比如代码 bug 导致所有订单都失败但 HTTP 还是 200。这种事故只能靠**业务指标**告警发现。

**最关键的业务指标必须做告警**（订单创建成功率、支付成功率、登录成功率）——和系统告警同等优先级。

## 五、Log 深入：结构化、关联、控制

### 结构化日志（必须）

**绝对不要**：

```
2026-05-14 10:23:45 INFO 用户 12345 下单成功，订单号 ABC-001，金额 99.50
```

**必须**：

```json
{
  "timestamp": "2026-05-14T10:23:45.123Z",
  "level": "INFO",
  "service": "order-service",
  "host": "order-pod-7d8f-xyz",
  "traceId": "abc123def456",
  "spanId": "span001",
  "msg": "order created",
  "userId": 12345,
  "orderId": "ABC-001",
  "amount": 99.50
}
```

**为什么必须 JSON**：

- ELK / Loki / Datadog 全部能直接索引字段，不用正则解析
- 字段类型保留（数字就是数字，能算 SUM / AVG）
- 多语言互操作（不用为每种语言写解析器）

Spring Boot 用 logback + `logstash-logback-encoder` 一键产出 JSON。

### 必须带的字段

每条业务日志必须有：

- `traceId` + `spanId` —— 关联 Trace（**这是三件套联动的关键**）
- `service` + `host`（或 `instance`） —— 谁产生的
- `level` —— 等级
- `timestamp` —— 时间（ISO 8601，带毫秒和时区）
- 业务上下文：`userId` / `requestId` / `orderId` 等

### traceId 是三件套的胶水

**这是最重要的工程细节之一**。三件套各自孤立没用，必须用 `traceId` 串起来：

- Metrics 大盘看到错误率涨 → 找到一个具体 traceId（从 Trace 系统）
- 用 traceId 在 Log 系统全文搜，**跨服务**看到所有相关日志
- 在 Trace 系统看链路图

如果日志里没埋 traceId，"在生产环境定位某次特定请求的所有日志"几乎不可能（grep 大海捞针）。

**实现层面**：

- 接入 Trace SDK（SkyWalking / OpenTelemetry）后，自动把当前 Span 的 traceId 注入 MDC（Mapped Diagnostic Context）
- Logback 模板里 `%X{traceId}` 自动打印
- 跨服务调用通过 HTTP header（`traceparent` / `sw8`）传递

### 日志等级的正确用法

| 等级 | 用法 |
| --- | --- |
| `ERROR` | **有人需要立刻处理的异常**（系统失败、数据错误、外部依赖挂） |
| `WARN` | 异常但已处理（重试成功、降级生效），值得复盘但不需要醒人 |
| `INFO` | 关键业务事件（订单创建、支付完成）+ 启动 / 关闭流程 |
| `DEBUG` | 开发调试用，**线上默认关** |
| `TRACE` | 极详细调试，几乎只在本地开 |

**反模式**：

- 所有日志都 INFO —— Trace 信息量稀释成噪音，重要事件被淹没
- 业务异常打 ERROR —— ERROR 应该触发告警，业务"正常的失败"打成 ERROR 让告警系统假阳泛滥
- 把堆栈打到 INFO —— 一个异常上千字符日志，浪费存储

### 日志的成本

```
QPS 5000 × 每请求 10 行日志 × 平均 200 字节 = 10 MB/s = 864 GB/天
```

一个服务一天接近 1TB 日志，存储成本几百块；几十个服务全开 DEBUG 直接破产。所以：

- 默认 INFO，DEBUG 用动态调级（Spring Boot Actuator / Arthas `logger --level DEBUG`）按需开
- 业务热点路径**不要打日志**或只打错误分支
- 把高频低价值日志（"接收到请求"）改成 Metrics counter，便宜十倍
- 关键日志才保留 7 天 / 30 天，其他 1–3 天就好

## 六、Trace 深入：分布式系统的命门

### Trace / Span 数据模型

```
TraceId = abc123 (全链路唯一)

[order-service: POST /orders] ───────── 850ms ───────────
  ├─ [validator: validate] ─ 20ms
  ├─ [user-service: GET /users/12345] ─── 80ms
  │    └─ [redis: GET user:12345] ─ 2ms
  ├─ [inventory-service: deduct] ── 120ms
  │    └─ [mysql: UPDATE inventory] ─ 90ms
  └─ [payment-service: charge] ──────── 600ms     ← 慢的元凶
       └─ [external bank API] ────── 580ms
```

每个矩形是一个 Span，所有 Span 共享 traceId。父子关系通过 parentSpanId 表达。

每个 Span 有：

- 服务名 + 操作名
- 开始时间、持续时间
- tags（自定义键值，如 `http.status=200`、`db.statement="SELECT..."`）
- logs（Span 期间的事件）
- 关联的 traceId / spanId / parentSpanId

### 主流产品

| 产品 | 协议 | 特点 |
| --- | --- | --- |
| **SkyWalking** | 自有 | 国产，Java 字节码增强，自动埋点强，中文社区大 |
| **Jaeger** | OpenTracing | CNCF 项目，UI 简单清晰 |
| **Zipkin** | Zipkin | Twitter 出品，老牌，简单 |
| **OpenTelemetry**（OTel） | 协议标准 | **未来共识**，Metrics + Log + Trace 统一标准，所有后端都在适配 |
| **商业**（Datadog / NewRelic / 阿里 ARMS） | — | 一体化、贵 |

新项目首选 **OpenTelemetry SDK + 后端选 Jaeger / Tempo / 商业**。OTel 是未来 5 年的标准，绑死单一产品（如 SkyWalking 私有协议）以后迁移成本高。

### 自动埋点 vs 手动埋点

- **自动埋点**：HTTP server / client、JDBC、Redis、Kafka 等常见组件 SDK 自动注入，零代码
- **手动埋点**：业务关键节点（"开始计算积分"、"调用第三方接口"）

线上一般 80% 自动 + 20% 手动。**手动埋点的关键节点要选耗时大、有业务价值的**，不要给每个内部方法都加。

### 采样率

100% 采样在大流量服务下成本爆炸（一天几 TB 数据）。常见策略：

1. **固定采样率**：1% / 10%——简单但慢请求和错误请求可能漏采
2. **基于错误的采样**：默认 1%，但凡是失败 / 慢请求 100% 采——**强烈推荐**
3. **基于业务的采样**：核心链路（下单 / 支付）100%，非核心 1%

OTel / SkyWalking 都支持上述策略，重点是**保证慢请求和错误请求一定被采到**，这是排障最有价值的样本。

### 跨服务传递

```
客户端                                      下游
   │ traceId=abc, parentSpan=001            │
   │ ────── HTTP header: traceparent ────► │
   │                                         │ 收到后继承 traceId，创建 spanId=002，parentSpanId=001
   │                                         │
```

W3C `traceparent` 是标准格式：`00-<traceId>-<parentSpanId>-<flags>`。

异步场景（Kafka / MQ）也要把 traceparent 序列化到消息 header，否则 Trace 链断了。

## 七、三件套协同的几个典型姿势

### 姿势 1：告警→定位（标准下钻）

```
1. Metrics 告警：order-service P99 > 1s
2. Grafana 看大盘，定位时间窗口和服务
3. 跳到 Trace 系统，过滤 service=order-service AND duration>500ms 取最近 N 条
4. 打开一条 Trace，看链路图，找最慢的 Span
5. 复制这条 Trace 的 traceId
6. 跳到 Log 系统搜 traceId=xxx，看跨服务的日志细节
7. 定位根因
```

### 姿势 2：从 Log 异常反查全局

```
1. 客服反馈：某用户报错"系统繁忙"，提供 requestId
2. Log 系统搜 requestId=xxx，找到对应日志，拿到 traceId
3. Trace 系统看 traceId 的完整链路，找失败的 Span
4. Metrics 系统看那个 Span 对应服务的当前健康度，确认是个别问题还是面问题
```

### 姿势 3：业务异常（成功率掉）

```
1. 业务监控告警：订单创建成功率从 99.8% 掉到 95%
2. Metrics 看错误码分布（按 reason label 分组）：发现 reason="stock_not_enough" 占比飙升
3. Trace 过滤错误样本，看链路是不是都死在 inventory-service
4. Log 看 inventory-service 错误日志，看是不是缓存不一致 / DB 同步延迟
```

### 姿势 4：性能基线对比

```
1. 上线后接口慢，但没到告警阈值
2. Metrics: 对比"今天 P99"和"昨天同时刻 P99"
3. Trace: 拉 100 条今天的 Trace 和 100 条昨天的，对比 Span 耗时分布
4. 火焰图（async-profiler）确认 CPU 热点变化
```

## 八、告警设计

### 告警的目的不是"我看到了"，是"我要立刻行动"

每条告警都要回答三个问题：

1. **是真问题吗？**（不是噪音）
2. **影响多大？**（决定 P0/P1/P2）
3. **要做什么？**（runbook 链接）

如果一条告警满足不了这三条，那它就是噪音，**会让真告警被淹没**。

### 告警分级

| 级别 | 触发条件 | 响应时间 | 响应方式 |
| --- | --- | --- | --- |
| **P0** | 主流程不可用（下单不能下） | 5 分钟 | 电话 + 短信 + 拉群 |
| **P1** | 主流程降级 / 部分用户受影响 | 15 分钟 | 短信 + IM |
| **P2** | 边缘功能 / 非业务影响 | 1 小时 | IM |
| **P3** | 资源水位 / 趋势预警 | 工作时间内处理 | 邮件 / 看板 |

### 黄金告警清单（每个服务都该有）

**应用层**：

- P99 > 阈值（按业务定，比如下单 500ms）
- 错误率 > 1%
- QPS 突变（±50% 同比）—— 流量异常
- 业务核心指标突变（订单成功率 < 99%）

**JVM 层**：

- FullGC 1 分钟内 ≥ 1 次
- 堆使用 > 90%
- 线程数 > 阈值（按业务定，500 / 1000）

**资源层**：

- CPU > 80% 持续 5 分钟
- 内存 available < 15%
- 磁盘 > 85%
- 网络丢包

**依赖层**：

- DB 连接池使用率 > 80%
- DB 慢查询数 / 分钟 > 阈值
- Redis P99 > 50ms
- MQ 消费 lag > 阈值

### 避免告警疲劳

- **抖动型告警必须有持续时间**：`P99 > 500ms FOR 5m`，不要 `FOR 0s`
- **聚合相关告警**：一台机器挂了不要触发 30 条告警（CPU / 内存 / 接口超时全报）
- **不可恢复的告警自动关闭**：告警平台支持自动 resolve
- **静默期 / 抑制规则**：发布期间允许短暂抖动
- **定期审查**：每月统计哪些告警最多人忽略，**忽略多就是噪音**，立刻删或调阈值

## 九、几个常见反模式

| 反模式 | 正确做法 |
| --- | --- |
| 排障只看日志 | 先 Metrics 看面，定位时间 / 服务，再 Trace 找点，最后 Log 看细节 |
| 监控只有 CPU 内存，没有业务指标 | 必须加业务指标告警（订单成功率、支付成功率） |
| 日志非结构化 / 没 traceId | JSON + traceId 是底线 |
| Trace 全采样 | 错误和慢请求 100%，其他 1%–10% |
| 告警没有持续时间限制 | `FOR 5m` 至少，避免抖动告警风暴 |
| 告警没分级 | P0/P1/P2 必须分开，电话 / 短信 / IM 通道隔离 |
| 业务异常用 ERROR 级日志 | 业务正常失败用 WARN 或单独指标，ERROR 留给系统级异常 |
| Histogram 桶定义不合理 | 覆盖 5ms~10s，业务接口的 P99 通常落在 50ms~500ms |
| 没有 SLO，只有阈值 | 建立基于错误预算的 SLO（"99.9% 请求 P99 < 500ms"），用 burn rate 告警代替静态阈值 |
| 跨服务调用没传 traceparent | Trace 链路断了，三件套联动失效 |
| Trace 全自动埋点，业务节点不埋 | 关键业务环节手动加 Span，否则只能看到框架级耗时 |
| Metrics 标签放 userId / orderId | 高基数标签会撑爆 TSDB（cardinality 爆炸），永远不要这么干 |

## 十、可观测性栈选型建议

**起步阶段**（团队没有完整方案）：

- Metrics: Prometheus + Grafana
- Log: Loki（轻量）或 ELK（重型）
- Trace: SkyWalking（Java 友好、自动埋点强）或 Jaeger
- 告警：Alertmanager / Grafana 告警

**进阶阶段**（团队已经熟悉，希望统一）：

- 全栈 OpenTelemetry SDK 接入
- 后端用 Grafana 全家桶：Prometheus + Loki + Tempo + Pyroscope（火焰图）
- OnCall: Grafana OnCall 或 PagerDuty

**云上托管**（不想自己运维）：

- 阿里 ARMS、腾讯 APM、AWS X-Ray、Datadog、NewRelic
- 优点：开箱即用
- 缺点：贵，且锁定（OTel 是反锁定的关键）

## 十一、本章小结与下一步

### 小结

- 三件套各自不可替代：Metrics 看趋势、Log 看事件、Trace 看链路
- 排障顺序：**Metrics 看面 → Trace 找点 → Log 看细节**——从聚合到细节，从便宜到贵
- Metrics 用 RED / USE / 黄金信号建模，必须有业务指标
- Log 必须结构化（JSON）+ 必须带 traceId，**traceId 是三件套的胶水**
- Trace 用 OpenTelemetry 这个未来标准，**错误和慢请求 100% 采样**，关键业务节点手动埋点
- 告警必须分级、有持续时间、有 runbook
- 高基数标签不要乱加（userId、orderId 进 Metrics 是灾难）

### 与后面章节的衔接

- **§07–§18 各专题**都会假设你有三件套——具体说"看 Metrics 大盘看 X 指标"、"在 Trace 里过滤 duration > Y"、"用 traceId 查 Log 关键字 Z"
- §09 接口 RT 抖动 —— Trace 是核心工具
- §11 FullGC 频繁 —— Metrics + GC 日志 + alloc 火焰图
- §19 应急预案 —— 告警分级和分级响应

### 留给下一章的问题

- §07 进入"专题"阶段。第一个具体问题：CPU 飙高。这一章给的工具（top -H / jstack / Arthas thread -n / profiler cpu）会和 §02 的 mpstat / pidstat 配合，形成完整 SOP——什么场景该用哪个？

---

## 未定问题清单

- 是否单独写一章 **SLO / SLI / 错误预算 / Burn Rate 告警**？对于成熟团队这是核心方法论，但偏向 SRE 实践不是排障本身。倾向作为本章附录或单独写一节，不单独成章。
- **eBPF 可观测性**（Pixie、Parca、Hubble）是否要在本章提一句？这是下一代可观测性范式，但目前生产采用率不高。倾向放在末尾作为前沿展望。

---

写完了。请确认这一章的组织和深度，以及上面两个未定问题如何选择。确认后进入 §07 CPU 飙高专题——正式进入"具体问题"阶段。
