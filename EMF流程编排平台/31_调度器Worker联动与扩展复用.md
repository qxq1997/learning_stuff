# 31 调度器、Worker 联动与扩展复用

## 这块到底在设计什么

调度器和 worker 的关系,可以先用一句话抓住:

```text
Scheduler 决定“谁现在可以跑、能不能跑、交给谁跑”;
Worker 负责“真正把这个任务安全地跑完,并把结果回写成状态”。
```

也就是说:

```text
Scheduler 是控制面;
Worker 是执行面。
```

控制面关心的是:

```text
DAG 依赖是否满足
workflow 是否暂停/取消
资源 quota 是否允许
任务是否到达 scheduled_at
任务是否需要 retry
任务是否超时
如何避免重复领取
```

执行面关心的是:

```text
怎么建立任务执行上下文
怎么解析 command
怎么调用具体 module/service
怎么处理外部系统
怎么 heartbeat
怎么回写 SUCCESS/FAILED/RETRY/TIMEOUT
怎么保证幂等和可恢复
```

所以一个生产级工作流引擎,不要把 scheduler 和 worker 混成一个“while loop 跑函数”的东西。

更好的心智模型是:

```text
Workflow state + DAG state
        |
        v
Scheduler 做调度决策
        |
        v
Task queue / dispatch
        |
        v
Worker 执行任务
        |
        v
State machine 回写结果
        |
        v
Scheduler 根据新状态继续推进 DAG
```

## EMF 里的调度与执行模型

从 EMF 的代码结构看,它更像是一个:

```text
worker 进程内嵌 producer + appender + DAG manager + consumer + command executor
```

链路可以理解为:

```text
Service Bus / PubSub
  -> PubSubMessageProducer 拉取外部消息
  -> WorkerMessageAppender 把 Message 加入 Batch/Run/DAG
  -> DagManager / DagContext 维护 run_uuid 对应的图
  -> ParallelMessageConsumer 找 ready vertex
  -> MessageHandler 建立 message scope
  -> StratusCommandExecutor 找 command module
  -> module/service 执行业务
  -> 执行过程中可能继续 enqueue 新 Message
  -> DagContext 更新状态并继续推进
```

这和很多平台里的“独立 scheduler + worker pool”不完全一样。

EMF 的特点是:

```text
外部消息进入 worker 后,worker 内部就有一套 DAG 调度循环。
```

所以在 EMF 语境下:

```text
ParallelMessageConsumer 扮演了调度器的一部分角色。
DagManager/DagContext 扮演了 DAG 状态管理角色。
MessageHandler/StratusCommandExecutor 扮演了 worker 执行角色。
```

如果抽象成通用工作流引擎,可以拆成:

| 通用概念 | EMF 中的对应角色 |
|---|---|
| Producer | `PubSubMessageProducer` |
| DAG appender | `WorkerMessageAppender` |
| Scheduler graph state | `DagManager` / `DagContext` |
| Ready selector | `ParallelMessageConsumer` |
| Worker handler | `MessageHandler` |
| Command executor | `StratusCommandExecutor` |
| Plugin/module | `ParameterisedModuleBase` 的具体实现 |

## Scheduler 的核心职责

调度器不是简单找 `READY`。

它至少要回答四类问题。

### 1. 结构上能不能跑

也就是 DAG 依赖是否满足:

```text
父节点是否都到达允许的终态
trigger rule 是否满足
条件分支是否 skip 了不相关分支
动态 fan-out 是否已经生成完
join 节点是否等到了 completion token
```

例如:

```text
A -> B -> D
A -> C -> D
```

如果 D 的 trigger rule 是 `all_success`,那么 B/C 都成功后 D 才能 ready。

如果是 `all_done`,那么 B/C 只要都终态,D 就能 ready。

所以 ready 不是一个固定字段,而是:

```text
DAG 结构 + 父节点状态 + trigger rule + workflow 控制状态
```

共同推导出来的结果。

### 2. 控制上允不允许跑

即使任务结构上 ready,也不一定能执行。

还要检查:

```text
workflow 是否 PAUSED
workflow 是否 CANCELLING/STOPPING
task 是否在 retry delay 中
task 是否 scheduled_at 在未来
是否被人工 hold
是否需要审批或等待事件
```

这就是第 22 节说的调度门禁。

一个任务能被 worker 领取,至少要满足:

```text
task dependency ready
and workflow scheduling gate open
and task scheduled_at <= now
and task not cancelled
and task not waiting approval/event
```

### 3. 资源上能不能跑

生产调度器还要保护系统:

```text
global concurrency
tenant quota
workflow concurrency
batch concurrency
task type concurrency
external system concurrency
worker pool capacity
```

所以最好把 ready 拆成三层:

```text
dependency_ready   # 依赖满足
resource_ready     # 有资源额度
dispatchable       # 可以真正派发
```

如果只用一个 `READY`,排查时会很痛。

用户会问:

```text
为什么它 ready 了还不执行?
```

实际上可能是:

```text
Databricks pool 满了
tenant quota 满了
workflow 自己的 max concurrency 达到了
worker 没有对应 capability
```

所以建议记录:

```text
blocked_reason = tenant_quota_exceeded
blocked_reason = external_pool_full
blocked_reason = workflow_paused
blocked_reason = no_worker_capability
```

### 4. 交给谁跑

如果 worker 有不同类型,调度器还要做 worker 匹配:

```text
SQL task -> SQL worker pool
Databricks task -> Databricks worker pool
HTTP task -> HTTP worker pool
CPU heavy task -> heavy pool
metadata task -> light pool
tenant A task -> tenant A isolated pool
```

这里就需要 task capability 和 worker capability。

例如:

```text
task.required_capabilities = ["databricks", "catalogue-write"]
worker.capabilities = ["databricks", "storage", "catalogue-write"]
```

只有匹配成功,任务才能派给这个 worker。

## Worker 的核心职责

Worker 不应该决定 DAG 依赖。

Worker 的核心是:

```text
可靠执行一个已经被调度器授权执行的 task/message。
```

一次执行大致是:

```text
1. 领取或接收 task。
2. 建立 execution context。
3. 加载 task input 和 resolved parameters。
4. 根据 command 找到 module。
5. 调用 module/service 执行业务。
6. 记录日志、metrics、trace。
7. 写 output_ref / completion marker。
8. 回写状态 SUCCESS/FAILED/RETRYING/TIMEOUT。
9. 释放 lease 和资源 slot。
```

在 EMF 里,这条链路对应:

```text
ParallelMessageConsumer
  -> MessageHandler
  -> begin_scope
  -> StratusCommandExecutor
  -> ModuleProvider 找 module
  -> MessageParameterParser 解析参数
  -> module.execute_with_parameters()
```

Worker 的设计目标是:

```text
薄、可替换、可横向扩展、尽量无本地关键状态。
```

## Scheduler 和 Worker 怎么联动

可以按一次任务生命周期来看。

```text
Message/task 进入系统
  -> appender 加入 DAG
  -> scheduler 计算 ready
  -> scheduler 判断 quota/resource
  -> scheduler/worker CAS 领取 task
  -> task RUNNING,写 worker_id/attempt/lease
  -> worker 执行 command
  -> worker heartbeat/续租
  -> worker 写 output_ref
  -> worker 回写 SUCCESS/FAILED/RETRYING
  -> scheduler 根据状态更新 children
  -> 下游 task 变成 ready
```

如果是内嵌式 EMF 模型:

```text
ParallelMessageConsumer 在本进程里找 ready vertex 并提交线程池。
```

如果是分布式模型:

```text
Scheduler 把 dispatchable task 写入 task queue,worker 从 queue 消费。
```

两种模型的区别:

| 模型 | 优点 | 代价 |
|---|---|---|
| 内嵌 scheduler/worker | 简单、低延迟、适合单进程或小规模内部平台 | HA、跨节点扩展、状态恢复更难 |
| 独立 scheduler + worker pool | 可横向扩展、职责清晰、适合生产大规模 | 需要 DB/MQ/lease/heartbeat/幂等 |

EMF 当前主线更接近:

```text
消息进入 worker,worker 内部维护 DAG 并消费 ready 节点。
```

如果要往生产级平台演进,可以逐步拆成:

```text
Workflow Service
  -> Scheduler Service
  -> Task Queue
  -> Worker Pool
  -> State Store
```

## 为什么不能只用一个普通队列

普通队列只知道:

```text
下一条消息是谁。
```

DAG 调度器要知道:

```text
哪些消息现在满足依赖。
```

如果把 A/B/C/D 都直接丢 FIFO:

```text
A -> B -> D
A -> C -> D
```

队列并不知道 D 要等 B/C。

你可能会在 worker 里写:

```text
拿到 D 后检查父节点,不满足就塞回队列。
```

这会导致:

```text
大量无效 requeue
消息乱序难排查
延迟不可控
依赖判断散落在 worker
worker 需要理解 DAG
```

所以更好的分工是:

```text
Scheduler/DagContext 负责依赖判断;
Queue 只负责传输可执行任务;
Worker 只执行已经可执行的任务。
```

## Worker 怎么扩展

Worker 扩展有四个层面。

### 1. 横向扩展实例数

最直接是多开 worker:

```text
worker-1
worker-2
worker-3
```

但前提是:

```text
任务领取是原子的
任务执行是幂等的
RUNNING 有 lease
worker 有 heartbeat
```

否则多开 worker 只会把问题放大:

```text
重复执行
状态覆盖
任务丢失
旧 attempt 回写
```

### 2. 按任务类型拆 worker pool

不同任务的资源特征不同。

比如:

```text
SQL 查询
Databricks job
Storage 文件操作
Catalogue 元数据操作
HTTP API 调用
轻量参数计算
```

可以拆成:

```text
light-worker-pool
sql-worker-pool
databricks-worker-pool
storage-worker-pool
api-worker-pool
```

优点:

```text
不同资源隔离
不同并发上限
不同超时策略
不同依赖环境
故障半径更小
```

代价:

```text
部署复杂
任务路由复杂
worker capability 管理复杂
资源利用率可能不均衡
```

### 3. 按租户/环境隔离 worker

如果涉及多租户或敏感权限,可以按租户或环境隔离:

```text
tenant-a-worker-pool
tenant-b-worker-pool
prod-worker-pool
sandbox-worker-pool
```

适合:

```text
数据权限强隔离
secret 不同
外部系统账号不同
SLA 不同
高价值租户独占资源
```

这和第 30 节的隔离设计是同一套思路:

```text
默认隔离,显式协作。
```

### 4. 按执行模式扩展

Worker 不一定真的在本进程里执行所有任务。

可以有三种执行方式:

| 模式 | Worker 做什么 | 适用场景 |
|---|---|---|
| 内置执行 | 直接调用 module/service | 轻量命令、低延迟任务 |
| 外部触发 | 提交 Databricks/Spark/HTTP job,再监控 | 长任务、外部系统任务 |
| 容器化执行 | 创建 Kubernetes Job/Pod | 重计算、多语言、不可信依赖 |

这时 worker 更像:

```text
executor adapter
```

它不一定负责把任务算完,而是负责:

```text
提交任务
记录 external_job_id
监控终态
拉取结果
回写状态
```

## Worker 怎么复用

Worker 复用的关键是:

```text
Worker 不写业务 if/else,业务能力做成 command/module/plugin。
```

也就是说,worker 不应该写成:

```text
if command == "LOAD_DATA":
  ...
elif command == "VALIDATE":
  ...
elif command == "EXPORT":
  ...
```

而应该是:

```text
command name
  -> module provider
  -> parameter parser
  -> module.execute_with_parameters()
```

这样同一个 worker 可以复用在很多 workflow:

```text
LOAD_DATA
VALIDATE
EXPORT
RUN_SQL
CALL_API
CATALOGUE_UPDATE
SEND_NOTIFICATION
```

Worker 只提供稳定能力:

```text
消息消费
DAG ready 调度
状态管理
DI scope
参数解析
日志审计
重试超时
幂等上下文
```

业务扩展通过:

```text
新增 command module
注册 module provider
声明参数 schema
声明 required capabilities
声明 retry/timeout/idempotency policy
```

这就是 EMF 里 `StratusCommandExecutor + ModuleProvider + ParameterisedModuleBase` 这套设计的价值。

## Module 级扩展怎么设计

一个可复用的 module 最好声明这些元数据:

```text
registered_command_name
registered_az_command_name
parameter_schema
required_capabilities
retry_policy
timeout_policy
idempotency_key_policy
resource_profile
output_contract
```

例如:

```text
command = ADB-SQL-EVAL
required_capabilities = ["databricks"]
resource_profile = "heavy"
timeout_policy = "2h"
retry_policy = "system_failure_only"
output_contract = "sql_result_manifest"
```

调度器可以用这些信息决定:

```text
派到哪个 worker pool
占用哪个资源池
是否允许 retry
timeout 怎么判
下游怎么校验输出
```

worker 可以用这些信息决定:

```text
怎么解析参数
怎么构造执行上下文
怎么生成 idempotency key
怎么验证输出
```

## Worker 生命周期

生产级 worker 不是启动后一直干活这么简单。

它至少有这些生命周期:

```text
STARTING
REGISTERED
HEALTHY
DRAINING
STOPPING
STOPPED
UNHEALTHY
```

启动时:

```text
加载配置
注册 capabilities
注册 command modules
连接 DB/MQ/外部系统
上报 heartbeat
开始领取任务
```

运行中:

```text
周期性 heartbeat
续租 RUNNING task
上报 capacity
上报 running task count
处理 graceful shutdown signal
```

下线时:

```text
进入 DRAINING
停止领取新任务
等待当前任务完成或转移
释放 lease
写 worker stopped event
```

为什么要有 `DRAINING`?

因为如果部署升级时直接 kill worker,会产生大量:

```text
RUNNING but no heartbeat
```

然后 scanner 会把它们当成僵尸任务,触发重试或恢复,增加事故风险。

## Worker 注册与能力发现

如果 worker pool 变多,系统需要知道:

```text
当前有哪些 worker
每个 worker 能跑什么
当前负载是多少
是否健康
```

可以设计 worker registry:

```text
worker_id
worker_group
capabilities
max_concurrency
current_running
heartbeat_at
status
version
zone
```

调度器派发任务时看:

```text
task.required_capabilities subset of worker.capabilities
worker.status = HEALTHY
worker.current_running < worker.max_concurrency
worker.version compatible with task.protocol_version
```

如果没有匹配 worker,任务不要失败,而应该进入:

```text
READY but blocked_by = no_worker_capability
```

这样用户看到的是:

```text
不是任务失败,而是当前没有能执行它的 worker。
```

## 推模式和拉模式

Scheduler/Worker 联动有两种常见方式。

### 拉模式

Worker 主动从 DB/MQ 拉任务:

```text
worker poll/consume queue
  -> claim task
  -> execute
```

优点:

```text
worker 自然按自己能力消费
扩容简单
worker 挂了不会被继续派任务
```

代价:

```text
scheduler 对实时分配控制弱一些
需要 queue 分区或过滤
可能有空轮询
```

### 推模式

Scheduler 主动把任务派给指定 worker:

```text
scheduler choose worker
  -> dispatch task to worker
```

优点:

```text
全局调度更强
公平性和资源分配更可控
```

代价:

```text
需要 worker registry
worker 挂了要重新派发
scheduler 更复杂
```

很多生产系统会混合:

```text
scheduler 把 task 放到某个 queue/resource pool;
worker 从自己订阅的 queue 里拉。
```

这既保留了调度器的资源控制,又保留了 worker 横向扩展能力。

## Quota 和并发度应该放在哪一层

一个很关键的问题是:

```text
如果 Scheduler 把 ready task 塞进 queue 给 Worker 执行,
quota 和并发度只交给 Scheduler 控制可以吗?
```

答案是:

```text
只靠 Scheduler 通常不够。
```

原因是:

```text
入队不等于执行。
```

真正的压力发生在 worker 执行阶段:

```text
worker 什么时候消费 queue
worker 当前还有没有线程
worker 是否正在 draining
worker 能不能连上外部系统
Databricks / DB / API 真实并发是多少
任务是否已经 submit 到外部系统
```

这些都不是 task 被 scheduler 放进 queue 的那一刻能完全知道的。

更稳的设计是把并发控制拆成两层:

```text
Scheduler 做 admission control;
Worker 做 execution control。
```

也就是:

```text
Scheduler 控制哪些 task 可以排队、进入哪个队列、最多允许多少 in-flight;
Worker 在真正执行前,再获取真实执行资源 token。
```

## 为什么只靠 Scheduler 控制会有问题

### 1. Queue 会变成不可控缓冲区

假设 scheduler 看到 100 个任务依赖满足,就都塞进 queue。

但 worker 实际消费很慢:

```text
scheduler dispatch 100 tasks
worker 每分钟只能执行 5 个
queue depth 越积越高
用户看到任务已经排队,但迟迟不运行
```

这时 scheduler 以为自己已经“调度成功”,但从执行面看,任务还没有真正开始。

所以要区分:

```text
已调度入队
```

和:

```text
已开始执行
```

### 2. 入队时占 quota 会导致资源假占用

如果 Databricks 并发 quota 是 5。

Scheduler 把 5 个 Databricks task 放进 queue,并认为 quota 已占满。

但 worker 可能还没消费它们,更没 submit job。

这会导致:

```text
quota 被队列里的任务占住
实际外部系统没有运行任何 job
后续真正可以执行的任务反而被挡住
```

这种叫:

```text
资源假占用。
```

### 3. 执行时占 quota 又可能瞬间超发

反过来,如果 scheduler 入队时不占 quota,只让 worker 执行时占。

那多个 worker 可能同时从 queue 里拿到任务,一起 submit 外部 job:

```text
worker-1 submit Databricks job
worker-2 submit Databricks job
worker-3 submit Databricks job
...
```

如果没有中心 token 或 CAS,就会瞬间打爆外部并发限制。

所以 worker 执行前也必须通过一个中心化的资源许可:

```text
acquire execution token
```

### 4. Worker 的真实执行状态会变化

Scheduler 可能以为某个 worker pool 有能力执行任务,但实际 worker 可能:

```text
线程池满了
正在 graceful shutdown
心跳延迟
外部连接不可用
本地依赖初始化失败
某个 command module 暂时不可用
```

所以 worker 在执行前还要做最后一次 gate check。

这个检查不是替代 scheduler,而是防止远端调度决策过期。

## 推荐状态拆分

为了表达清楚,可以把 task 状态拆成:

```text
CREATED
READY
QUEUED
RUNNING
SUCCESS / FAILED / RETRYING / CANCELLED
```

含义是:

| 状态 | 含义 |
|---|---|
| `READY` | DAG 依赖满足,理论上可以调度 |
| `QUEUED` | Scheduler 已允许它进入某个执行队列 |
| `RUNNING` | Worker 已领取并拿到执行资源,真正开始执行 |

这样就不会把:

```text
依赖满足
```

和:

```text
已经执行
```

混在一起。

如果系统不想增加 `QUEUED` 状态,也至少要在字段上区分:

```text
dispatch_status
queue_name
queued_at
worker_claimed_at
started_at
blocked_reason
```

## 推荐联动流程

比较稳的流程是:

```text
1. Scheduler 计算 dependency_ready task。
2. Scheduler 检查 workflow gate、tenant quota、queue depth、粗粒度资源池。
3. Scheduler 将 task 从 READY -> QUEUED,写入 queue_name。
4. Worker 从自己订阅的 queue 消费 task。
5. Worker 执行前重新检查 workflow 是否 pause/cancel。
6. Worker 向中心 resource manager 申请 execution token。
7. token 申请成功后,task QUEUED -> RUNNING。
8. Worker 设置 worker_id、attempt、lease_until。
9. Worker 执行业务并 heartbeat/续租。
10. 任务终态后释放 execution token。
11. Scheduler 根据终态继续推进下游。
```

这里 quota 是分层的。

Scheduler 侧主要控制:

```text
admission quota
queue depth
tenant dispatch quota
workflow dispatch quota
fair scheduling
```

Worker / resource manager 侧控制:

```text
actual running quota
external system concurrency
worker pool capacity
task type concurrency
lease-held execution token
```

一句话:

```text
Scheduler 控制“不要把系统塞爆”;
Worker/resource manager 控制“真实执行不要超并发”。
```

## Execution Token 设计

如果要精确控制并发,可以引入 execution token。

token 可以按维度发放:

```text
tenant_id
workflow_instance_id
task_type
external_system
worker_pool
resource_profile
```

例如:

```text
databricks_tokens = 5
tenant_a_tokens = 20
workflow_run_tokens = 10
heavy_pool_tokens = 8
```

Worker 执行前做:

```text
acquire token for:
  tenant = A
  workflow = run_001
  task_type = databricks
  external_system = databricks-prod
```

只有所有 token 都拿到,才能进入 `RUNNING`。

执行结束后:

```text
release tokens
```

如果 worker 挂了,不能靠 worker 主动释放,所以 token 也要有 lease:

```text
token_holder = task_instance_id
lease_until = now + 5 minutes
heartbeat renews lease
lease expired -> scanner recovers token
```

这样才能避免:

```text
worker 死了,token 永远不释放。
```

## Queue quota 和 Running quota 的区别

这两个不要混。

| 类型 | 控制什么 | 典型问题 |
|---|---|---|
| queue quota | queue 里最多积压多少待执行任务 | 防止消息堆积、延迟失控 |
| running quota | 同时真正执行多少任务 | 防止外部系统或 worker 被打爆 |

举个例子:

```text
queue quota = 1000
running quota = 20
```

意思是:

```text
最多允许 1000 个任务排队,
但同一时刻只有 20 个任务真正执行。
```

如果只有限制 queue:

```text
worker 可能瞬间并发执行太多。
```

如果只有限制 running:

```text
scheduler 可能把 queue 塞到几十万。
```

生产系统通常两个都要有。

## 什么时候只靠 Scheduler 也可以

不是所有系统都必须一开始做 execution token。

如果满足这些条件,可以先只做 scheduler-side quota:

```text
任务很轻量
worker 数量少
任务执行时间短
没有昂贵外部系统
queue 延迟可以接受
重复执行副作用低
```

例如:

```text
本地参数转换
轻量 metadata 校验
简单通知任务
```

但只要出现下面任一情况,就建议引入 worker-side token 或中心 resource manager:

```text
任务会调用 Databricks / DB / 第三方 API
任务耗时长
worker 会动态扩缩容
多租户共享资源
外部系统有严格限流
任务失败副作用大
```

## 面试表达

可以这样回答:

```text
quota 不能完全只放在 scheduler,因为 scheduler 把 task 放进 queue 不等于 worker 已经执行。实际并发取决于 worker 消费速度、worker 当前容量和外部系统可用资源。比较稳的设计是 scheduler 做 admission control,限制 dependency-ready task 的入队速度、队列深度和粗粒度配额;worker 在真正执行前再向中心资源池申请 execution token,拿到 token 后任务才从 QUEUED 进入 RUNNING。token 需要 lease 和 heartbeat,任务终态后释放,worker 挂了由 scanner 回收。这样既防止 scheduler 塞爆 queue,也防止 worker 实际执行时超过外部系统或租户 quota。
```

## 状态更新谁负责

一个容易争论的问题是:

```text
task SUCCESS/FAILED 到底由 worker 直接写,还是由 scheduler 写?
```

常见有两种设计。

### Worker 直接回写

```text
worker execute task
  -> update task status
```

优点:

```text
简单
低延迟
链路短
```

风险:

```text
worker 需要状态机权限
旧 worker 可能写错状态
多个组件状态规则不一致
```

所以必须通过:

```text
central state machine API
CAS/version
transition validation
```

而不是让 worker 随意 update SQL。

### Worker 上报事件,Scheduler/State Service 回写

```text
worker emits TaskSucceeded/TaskFailed
  -> state service validates transition
  -> update status
```

优点:

```text
状态机更集中
审计更一致
方便事件回放
```

代价:

```text
链路更长
需要 outbox/inbox
事件丢失要补偿
```

面试里可以说:

```text
小系统 worker 直接回写也可以,但必须经过状态机服务和 CAS;
大系统更适合事件上报 + 中心状态服务,用 outbox/inbox 保证可靠。
```

## 调度器和 Worker 的可靠性协议

Scheduler/Worker 之间至少要有这几个协议。

### 1. Claim 协议

```text
READY -> RUNNING
set worker_id
set attempt
set lease_until
CAS by expected status/version
```

保证:

```text
同一个 task 不会被多个 worker 同时领取。
```

### 2. Heartbeat / lease 协议

```text
worker 定期续租 RUNNING task
如果 lease 过期,scanner 接管判断
```

保证:

```text
worker 挂了以后任务不会永远 RUNNING。
```

### 3. Completion 协议

```text
worker 完成任务前先写 output_ref/completion marker
再把状态改成 SUCCESS
```

保证:

```text
下游看到 SUCCESS 时,依赖的输出已经存在。
```

### 4. Idempotency 协议

```text
idempotency_key = workflow_instance_id + task_key + attempt
或业务允许的稳定 request_id
```

保证:

```text
重复投递、worker 重启、callback 重复都不会造成重复副作用。
```

### 5. Cancellation 协议

```text
workflow CANCELLING
  -> worker 停止领取新任务
  -> RUNNING task 接收 cancel signal
  -> 外部 job 调 cancel API
  -> 记录 cancel result
```

保证:

```text
取消不是只改控制面状态,还会尽力处理执行面副作用。
```

## 外部长任务怎么联动

对于 Databricks/Spark/SQL 这类长任务,不要把“submit 成功”当成 task 成功。

更稳的模型是:

```text
SubmitTask
  -> 保存 external_job_id
  -> task WAITING_EVENT / RUNNING
MonitorTask or callback
  -> 查询 external terminal status
  -> 校验输出
  -> SUCCESS / FAILED
```

或者在一个 command 内部做:

```text
submit
poll terminal state
validate output
return success
```

两种方式取舍:

| 方式 | 优点 | 代价 |
|---|---|---|
| worker 内等待 | 简单,状态少 | 长时间占 worker slot |
| submit/monitor 拆分 | 释放 worker,适合长任务 | 状态和恢复逻辑更复杂 |

生产上长任务更推荐:

```text
提交和监控解耦。
```

这样 worker 不需要为了一个 2 小时外部 job 一直占着线程。

## Worker 复用的边界

Worker 可以复用,但不是无限复用。

不适合塞进同一个 worker 的情况:

```text
依赖环境冲突
安全等级不同
资源模型差异巨大
任务耗时差异巨大
外部系统限流策略不同
租户隔离要求不同
```

例如:

```text
轻量 metadata command
```

和:

```text
大规模 Spark 提交/监控
```

可以共享 command 框架,但最好不要共享同一个执行池。

更好的做法是:

```text
复用 worker 框架;
隔离 worker pool;
用 capability 和 resource profile 路由任务。
```

## 常见生产问题

### 1. ready 任务很多,worker 很闲

可能原因:

```text
任务被 blocked_by no_worker_capability
queue 路由错了
scheduler 没有把 task dispatch 出去
worker registry 认为 worker 不健康
tenant/resource quota 阻塞
```

排查:

```text
ready count
dispatchable count
blocked_reason 分布
queue depth
worker heartbeat
worker capability
claim success/failure count
```

### 2. worker 很忙,但 workflow 不往前推进

可能原因:

```text
worker 卡在外部长任务
SUCCESS 前没有写 output_ref
completion event 丢了
状态回写失败
下游 trigger rule 不满足
```

排查:

```text
running task duration
external job status
output contract validation
state transition history
scheduler decision log
```

### 3. 扩 worker 后重复执行变多

可能原因:

```text
claim 不是原子操作
lease 太短
heartbeat 续租失败
MQ 重复投递无幂等
旧 attempt 回写覆盖新 attempt
```

设计修复:

```text
CAS claim
合理 lease
attempt/version 校验
幂等 key
outbox/inbox
```

### 4. 某类任务拖垮所有 worker

可能原因:

```text
heavy task 和 light task 共用池
外部系统慢导致线程耗尽
没有 task type concurrency
没有 timeout
```

设计修复:

```text
worker pool 隔离
resource profile
task type quota
timeout + circuit breaker
长任务 submit/monitor 拆分
```

## 面试讲法

可以这样总结:

```text
调度器和 worker 要做控制面与执行面的拆分。调度器根据 DAG 依赖、workflow 状态、trigger rule、资源 quota 和 worker capability 判断哪些任务可以执行,并通过 CAS/lease 把任务安全地交给 worker。Worker 本身应该尽量薄,只负责建立执行上下文、解析 command、调用 module/service、维护 heartbeat、写 output_ref 并通过状态机回写结果。Worker 的扩展不是在代码里堆 if/else,而是通过 command/module/plugin、capability、resource profile 和 worker pool 来扩展。轻任务可以内置执行,长任务更适合 submit/monitor 解耦,高隔离任务可以容器化。这样系统既能复用统一的 worker 框架,又能按任务类型、租户、资源池做隔离和扩容。
```

最关键的一句话:

```text
Scheduler 不执行任务,Worker 不决定依赖;二者通过状态机、任务领取、lease 和事件回写协议联动。
```
