# 15 生产级 DAG 引擎挑战总览

## 本章定位

第 34 章是 EMF 的 source of truth。本章不重新定义 EMF，而是把第 34 章第 3 节里的“技术挑战与生产问题”整理成一张生产挑战地图。

EMF 的生产难点不是“会不会拓扑排序”，而是：

```text
元数据一致性
  + 动态 DAG 编排
  + 分布式任务执行
  + Databricks 外部计算
  + schema drift
  + 幂等重试
  + 可观测和恢复
  + 多环境权限治理
  + 性能成本控制
```

这些问题叠在一起，才构成生产级 DAG 引擎的真正复杂度。

## 核心判断

EMF 不是一个“内存里跑 DAG 的小工具”。它更像一个元数据驱动的数据编排平台：

```text
file_type -> LOAD_INFO -> OE-RUN -> PROCESS_TASKS -> command messages
  -> Databricks -> DATAHUB -> CATALOGUE.METADATA -> downstream resolution
```

所以生产上出问题时，不能只查某个 Python exception。真正要查的是：

- 本次 run 用的是哪份 metadata。
- `LOAD_INFO` 是否和上传文件匹配。
- `PROCESS_TASKS` 是否解析到正确版本。
- DAG 中哪些 task 已经生成、哪些已执行、哪些被阻塞。
- Databricks job 是否真实成功、失败、取消或仍在运行。
- 结果是否写入 Delta 表并登记到 catalogue。
- 下游是否按正确的 criteria 解析到了正确数据。

## 挑战地图

| 挑战 | 生产表现 | 需要的平台能力 | 详细章节 |
|---|---|---|---|
| 元数据一致性 | 找不到输入、解析错表、schema 不匹配 | metadata validation、版本化、dry-run | 16、20、34 |
| 动态 DAG 编排 | 任务提前跑、永远等待、fan-out 失控 | DAG 校验、fanout group、completion token | 08、19 |
| 状态机和领取 | 重复执行、任务卡死、状态错乱 | CAS、lease、attempt、合法状态流转 | 17 |
| 幂等和外部副作用 | 重试后重复写表、重复 export、重复 job | idempotency key、outbox/inbox、reconcile | 18、25 |
| Databricks 管理 | job 排队、cluster 慢、计算失败但平台未同步 | run id 绑定、轮询、取消、错误映射 | 23、34 |
| schema drift | 上游字段变更、文件格式异常、坏数据污染 | schema validation、quarantine、契约治理 | 21、34 |
| 可观测性 | 不知道卡在哪、日志分散、人工排障慢 | trace id、运行视图、audit、Jira/LLM 摘要 | 20、32、33 |
| 多环境权限 | dev 可跑 prod 失败、跨订阅访问失败 | 环境参数、权限探测、secret 轮换治理 | 23、30、34 |
| 性能成本 | backlog、DBU 飙升、小文件、shuffle 慢 | 限流、背压、cluster policy、数据层优化 | 23、34 |

## 1. 元数据一致性

EMF 把业务行为从代码移动到了 `LOAD_INFO`、`PROCESS_TASKS`、`METADATA`、catalogue 和环境配置中。好处是灵活，代价是配置本身必须被治理。

典型问题：

- `file_type` 在 blob metadata、`LOAD_INFO`、`METADATA` 中命名不一致。
- `LOAD_INFO.schema_json` 与真实文件字段不一致。
- `LOAD_INFO.ingestion_workflow_name` 指向不存在或错误的 workflow。
- `PROCESS_TASKS` 被更新后，正在运行的 batch 和新定义混用。
- catalogue 中登记的 dataset/table 已经不存在，或者权限不可见。

应对方式：

- 发布前做 metadata dry-run。
- 校验 `file_type` 唯一性、schema 可解析性、dataset/table 是否存在。
- 校验 `PROCESS_TASKS.parents` 是否存在、是否有环、是否有孤儿节点。
- 运行时固化 workflow definition snapshot，避免只依赖最新配置。
- 对 `LOAD_INFO`、`PROCESS_TASKS` 和 catalogue 变更做版本管理和审计。

## 2. 动态 DAG 编排

动态 DAG 的主线必须按第 34 章来理解：`OE-RUN` 读取 `PROCESS_TASKS`，把 task 定义展开成 command messages，再根据 `parents` 形成依赖。

运行时 generator fan-out 是扩展能力，不能和主线混在一起。

典型问题：

- `parents` 配错，任务提前执行或永远等待。
- `enabled/disabled` 标签跳过了关键任务。
- 子 workflow 的 `order_id` 前缀和 completion token 没处理好。
- generator command 重试时重复生成 child messages。
- fan-in 节点只等 generator 成功，没有等 child group 完成。

应对方式：

- `PROCESS_TASKS` 发布前做 DAG validation。
- 展开后写 task instance / expansion snapshot。
- 动态 fan-out 必须有 `fanout_group`、`max_children`、stable child key。
- 下游 fan-in ready 条件要包含 fanout group completion。
- 对动态生成的 child message 做 dedupe 和审计。

## 3. 状态机、任务领取和 lease

生产级 DAG 不能只靠“消息被消费了”判断任务状态。Worker 可能重启、消息可能重复、外部 job 可能还在跑。

典型问题：

- 多个 Worker 同时领取同一任务。
- Worker 已提交 Databricks job，但写状态前崩溃。
- Worker lease 过期后旧进程又恢复，迟到写 SUCCESS。
- parent 失败后 children 已被错误激活。
- cancel 后仍有子任务继续执行。

应对方式：

- 任务领取必须是 CAS 或带锁的原子动作。
- `RUNNING` 任务必须有 `worker_id`、`attempt`、`lease_token`、`lease_until`。
- Worker 更新状态时带 attempt 和 lease token，防止旧 owner 覆盖新状态。
- 状态流转必须受控，不能随意从 `FAILED` 改 `SUCCESS`。
- scanner 定期处理 lease expired、timeout、stuck task。

## 4. 幂等、重试和外部副作用

EMF 是 at-least-once 风格的系统，重复消息和重复执行必须被当作默认情况。

典型问题：

- 同一个 `run_uuid` 或 `batch_id` 被重复使用。
- 同一个 `entity_uuid` 被重复 finalise。
- 重试时重复建表、重复 append、重复 export。
- Worker 提交 Databricks job 成功，但 API 响应丢失，下一次又提交。
- catalogue 写入重复 metadata 条目。

应对方式：

- 每个外部副作用都要有 idempotency key。
- Databricks submit 前生成稳定 request key，submit 后保存 `databricks_run_id`。
- Delta 写入带 `run_uuid`、`batch_id`、`entity_uuid`，方便去重和补偿。
- finalise、catalogue、export 需要唯一约束或已成功直接返回。
- 对 unknown side effect 的任务先 reconcile，不能盲目重跑。

## 5. Databricks Job 管理

第 34 章已经明确：Worker 是控制面，Databricks 是计算面。生产问题往往发生在两个系统状态不同步的时候。

典型问题：

- cluster 冷启动慢导致 SLA 延迟。
- job queue 堆积，Worker 还在继续提交更多 job。
- Databricks job 已失败，EMF 仍显示 running。
- Spark shuffle、数据倾斜、Python UDF 导致任务长时间运行。
- 权限或 secret 变化导致 job 运行身份访问失败。

应对方式：

- 每个 task 记录 workspace、job id、run id、cluster id、notebook path。
- Worker 定期轮询 Databricks run 状态并做错误映射。
- 超时或取消时联动 Databricks cancel。
- 按 workload 使用不同 compute profile / cluster policy。
- 对 Databricks queue、cluster pending time、失败率和 DBU 成本做背压。

## 6. 数据接入和 schema drift

生产文件经常不是完全干净的。EMF 必须在入口处尽早发现问题，而不是等到下游计算跑一半才失败。

典型问题：

- 上传文件缺少 `file_type` 或 metadata token。
- CSV delimiter、quote、skip rows 配错，导致错列。
- 字段新增、删除、改名，和 `LOAD_INFO.schema` 不一致。
- chunked file 未到齐就触发加载。
- 同一文件重复上传或事件重复触发。

应对方式：

- 上传阶段校验必要 metadata。
- 加载前做 schema、字段、record count、文件格式检查。
- 对坏数据写 quarantine/error dataset。
- 对 chunked file 做完整性检查。
- 用 checksum、source path、batch id 或 metadata token 去重。

## 7. 可观测性、审计和人工处理

生产排障最怕的是“知道失败了，但不知道失败在哪里”。EMF 要把 run、batch、message、Databricks job 和 data entity 串起来。

典型问题：

- Worker 日志、Databricks 日志、Service Bus 状态和 metadata 分散。
- 一个 workflow 有几十个 task，不知道哪个是根因失败。
- 失败后不知道该找数据 team、平台 team 还是业务 owner。
- 人工重跑没有记录，后续审计说不清。

应对方式：

- 全链路使用 `run_uuid`、`batch_id`、`order_id`、`entity_uuid`。
- 建立 DAG 运行视图，展示 parent/child、状态、attempt、耗时和外部 run。
- 错误分类为配置、权限、数据质量、Databricks、平台、业务规则。
- 自动创建 Jira ticket，包含错误摘要、Databricks 链接、metadata、SOP 和 owner team。
- 人工操作必须有 audit log、操作者、原因和前后状态。

## 8. 多环境、多项目和权限治理

EMF 不是单环境脚本。它要运行在 dev/test/prod、多项目、多订阅和跨区域访问中。

典型问题：

- dev 配置能跑，prod 因 storage、catalog 或 secret 不同失败。
- Worker 身份能提交 job，但 Databricks job 身份不能读表。
- Key Vault secret 轮换后，Worker 或 cluster 没刷新。
- Unity Catalog 表存在，但当前身份无权限，错误看起来像 table not found。
- 跨订阅 storage 或 external location 访问失败。

应对方式：

- 环境参数集中管理，不在代码里写死资源名。
- 发布前做权限探测。
- 按 command、project、dataset 最小授权。
- secret 轮换要有兼容窗口和刷新机制。
- 对跨订阅、跨 project 访问做白名单和审计。

## 9. 性能、规模和成本

性能问题不能只靠扩 cluster。扩容可能只是把慢任务变成贵任务。

典型问题：

- Service Bus backlog 增长。
- Worker 并发很高，但 Databricks job queue 更堵。
- 小文件过多导致 Spark 调度开销大。
- 大表 join、shuffle、UDF 导致长尾任务。
- 所有 task 共用万能 cluster，轻任务浪费、重任务不够。
- 中间表、checkpoint、debug 输出长期不清理。

应对方式：

- Worker 层按 project、workflow、command、dataset、cost class 限流。
- Queue 层基于 backlog、Databricks queue、失败率、成本预算做背压。
- Cluster policy 分层：`sql_light`、`etl_standard`、`shuffle_heavy`、`python_udf`、`export_io`。
- Delta 表做合理分区、compaction、统计信息、merge 范围控制。
- Python/UDF 尽量向 Spark SQL 内置函数、DataFrame API 或 pandas UDF 收敛。
- 中间数据、快照、checkpoint 和 debug 输出要有生命周期策略。

## 10. 最容易踩的坑

| 坑 | 后果 | 正确做法 |
|---|---|---|
| 只设计成功路径 | 一失败就需要人工猜状态 | 状态机、错误分类、恢复流程前置 |
| DAG 定义不版本化 | 重跑时用到新定义，结果不可解释 | run 绑定 definition snapshot |
| 没有幂等 | 重试变成重复处理 | 每个副作用有 idempotency key |
| 只看内部状态 | 外部 job 已成功/失败但平台不知道 | 外部状态 reconcile |
| 没有 lease | Worker 死后任务永久 RUNNING | lease + heartbeat + zombie scanner |
| 动态 fan-out 不持久化 | 重启后子任务丢失或重复 | expansion snapshot |
| 日志没有 trace id | 失败排查靠人工翻日志 | run/batch/order/entity/job 全链路关联 |
| 不做资源隔离 | 一个大 workflow 拖垮全平台 | quota、pool、priority、backpressure |
| 人工修复无审计 | 无法解释谁改了什么 | manual operation audit |

## 11. 推荐演进路线

**第一阶段：核心 DAG 执行**

- Message 模型。
- `OE-RUN + PROCESS_TASKS` 展开。
- `order_id + parents` 依赖判断。
- Command executor。
- 基础状态更新。

**第二阶段：生产可靠性**

- 状态机约束。
- CAS 领取。
- lease / heartbeat。
- retry / timeout。
- 幂等 key。
- Databricks run id 绑定。

**第三阶段：生产可运营**

- DAG 运行视图。
- audit log。
- Jira/SOP/LLM 故障摘要。
- metadata validation。
- 权限探测。
- 资源限流和背压。

**第四阶段：高级能力**

- runtime fan-out。
- 子 workflow。
- fan-in completion token。
- 多 Scheduler HA。
- zombie recovery。
- 多租户资源治理。

## 面试总结

生产级 DAG 引擎的难点不是把节点按拓扑顺序跑完，而是要在消息重复、Worker 重启、外部 Job 不确定、metadata 变更、schema drift、权限差异和资源受限的情况下，仍然保证任务可追踪、可恢复、可审计、可重跑。EMF 的核心思路是用 `file_type`、`LOAD_INFO`、`PROCESS_TASKS` 和 `METADATA` 把业务行为配置化，用 Worker 做控制面，用 Databricks 做计算面，再通过状态机、幂等、lease、reconcile、observability 和 governance 把它变成生产可运行的平台。
