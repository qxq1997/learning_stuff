# 26 与 Airflow、Temporal、Argo 的对比

## 为什么要做横向对比

面试里如果你讲自己参与或学习过一个工作流引擎,很容易被追问:

```text
那它和 Airflow 有什么区别?
为什么不用 Temporal?
和 Argo Workflows 比有什么取舍?
你们这个系统到底解决什么场景?
```

这类问题不是为了考你背工具功能,而是考:

```text
你是否理解工作流系统的不同范式。
```

EMF 可以理解为:

```text
消息驱动 + 动态 DAG + 命令插件化 + 外部系统编排
```

Airflow、Temporal、Argo 分别代表不同方向:

```text
Airflow: 数据批处理 DAG 调度
Temporal: durable workflow / 长事务状态机
Argo: Kubernetes 原生容器工作流
```

它们都能“编排任务”,但核心抽象不一样。

## 一张对比表

| 系统 | 核心抽象 | 适合场景 | 强项 | 典型代价 |
|---|---|---|---|---|
| EMF | Message + command + runtime DAG | 内部业务命令、数据/平台动作、动态任务生成 | 消息驱动、命令插件化、运行时扩展 DAG | 自研可靠性、可观测性、治理成本高 |
| Airflow | DAG + Operator + TaskInstance | 周期性数据 pipeline、批处理调度 | 成熟调度、UI、生态丰富 | 动态运行时扩展不是最核心范式 |
| Temporal | Workflow code + Activity + event history | 长事务、微服务编排、可靠业务流程 | durable execution、重试、恢复、事件历史 | 编程模型和确定性约束更强 |
| Argo | Workflow CRD + Pod/Container | Kubernetes 上的容器任务编排 | 容器隔离、K8s 原生、适合批量计算 | 强依赖 K8s,业务命令抽象要自己封 |

一句话:

```text
它们不是谁完全替代谁,而是用不同抽象解决不同编排问题。
```

## EMF 和 Airflow 的区别

Airflow 的经典模型是:

```text
DAG 文件定义工作流
Operator 定义任务类型
Scheduler 按时间和依赖调度 task instance
Executor/Worker 执行 task
```

它非常适合:

```text
每天跑一次数据同步
定时跑 SQL
批处理 pipeline
数据仓库 ETL/ELT
任务之间依赖清晰
```

EMF 的模型更像:

```text
外部事件或 OE-RUN 生成 Message
Message 通过 run_uuid/order_id/parents 形成 DAG
command 决定执行哪个 module
module 执行业务后还能继续 enqueue 新 Message
```

两者的关键差异:

| 维度 | Airflow | EMF |
|---|---|---|
| 任务表达 | Operator / task | Message / command |
| DAG 来源 | 通常来自定义文件或 DAG 解析 | 由 message 的 `order_id + parents` 推导 |
| 运行时扩展 | 支持动态任务映射等能力,但不是最原始心智模型 | command 可以继续生成 message,动态扩展是核心心智模型 |
| 命令执行 | operator 封装执行逻辑 | command -> module -> service |
| 业务集成 | 依赖 operator/provider 生态 | 更贴近内部 command/service/DI |
| 调度对象 | TaskInstance | Message / Vertex |
| 学习重点 | DAG、Operator、Scheduler、Executor | Message、DagContext、Consumer、CommandExecutor |

面试里不要说:

```text
EMF 比 Airflow 好。
```

更成熟的表达是:

```text
Airflow 更适合标准化、周期性的 data pipeline。EMF 更像内部业务平台的消息驱动工作流引擎,把每个任务抽象成 Message,再通过 command 映射到内部 module 和 service,并允许业务执行过程中继续生成新消息来扩展 DAG。
```

## Airflow 能给 EMF 的启发

Airflow 里有几个值得借鉴的概念:

```text
TaskInstance
DagRun
trigger rule
retry policy
sensor
backfill
UI run history
task log
```

对 EMF 学习最有价值的是:

```text
trigger rule 的显式化
运行历史和 task instance 的分离
重试、跳过、失败传播的 UI 表达
backfill / rerun 语义
```

尤其是 trigger rule。

EMF 里如果只是说:

```text
父节点都 complete 才 ready
```

那是基础版本。

生产上要能表达:

```text
all_success
all_done
none_failed
one_success
always
```

这正是 Airflow 类系统给 DAG 引擎的启发。

## EMF 和 Temporal 的区别

Temporal 的核心不是 DAG。

它的核心是:

```text
durable execution
```

也就是把一段业务流程代码变成可靠的长生命周期状态机。

典型模型:

```text
Workflow code
Activity
Event history
Deterministic replay
Timer
Signal
Query
Retry policy
```

它很适合:

```text
订单长事务
支付/退款流程
审批流
微服务可靠编排
需要等待人或外部事件
需要强恢复能力的业务流程
```

Temporal 的关键能力是:

```text
workflow 的每一步事件都会进入 history。
worker 挂了之后可以通过 replay 恢复 workflow 状态。
activity 有重试、timeout、heartbeat。
signal 可以把外部事件送进 workflow。
```

EMF 更像:

```text
消息和 DAG 节点驱动的调度平台。
```

Temporal 更像:

```text
代码驱动的可靠流程运行时。
```

对比:

| 维度 | Temporal | EMF |
|---|---|---|
| 核心抽象 | Workflow code + Activity | Message + command + DAG |
| 状态来源 | event history + replay | message/task state + DagContext |
| 执行语义 | durable execution | message-driven execution |
| 流程定义 | 代码表达流程 | workflow config / message graph / command expansion |
| 动态性 | 代码里自然分支和循环 | command 运行时生成 message 扩展 DAG |
| 恢复方式 | replay event history | 状态表、lease、reconcile、retry |
| 难点 | 确定性、版本兼容、activity 幂等 | 图治理、动态 fan-out、状态一致性 |

## Temporal 能给 EMF 的启发

Temporal 对 EMF 最大启发是:

```text
所有关键事件都要可恢复。
```

比如:

```text
task claimed
activity started
external request sent
callback received
retry scheduled
timer fired
manual signal received
```

如果 EMF 把这些也沉淀成:

```text
task_execution_attempt
task_state_transition
external_call_log
workflow_operation_audit
message_lineage
```

就能获得类似 durable history 的排障和恢复能力。

但 EMF 不一定要照搬 Temporal 的 workflow-as-code。

因为 EMF 的优势是:

```text
业务命令插件化
配置/消息驱动
与内部 Azure/Databricks/Storage/Catalogue 等 service 集成
运行时通过 Message 扩展 DAG
```

## EMF 和 Argo Workflows 的区别

Argo Workflows 是 Kubernetes 原生工作流。

它通常把任务表达成:

```text
container / pod
```

工作流用 YAML / CRD 表达:

```text
steps
DAG
templates
artifacts
parameters
retryStrategy
```

它适合:

```text
每个任务都是容器
机器学习训练
批量计算
CI/CD 类 workflow
Kubernetes 集群内任务编排
需要强隔离的任务执行
```

EMF 的任务通常不是直接一个容器。

它更像:

```text
command 调用内部 module/service。
```

例如:

```text
Databricks
Storage
Catalogue
SQL
API
文件处理
LoadInfo
UDF
```

对比:

| 维度 | Argo Workflows | EMF |
|---|---|---|
| 执行单元 | Pod / container | Message command / module |
| 平台依赖 | Kubernetes 强相关 | 依赖内部服务和消息系统 |
| 隔离性 | 容器隔离强 | 取决于 worker/module 设计 |
| 参数/产物 | parameters + artifacts | message parameters + output_ref |
| 适合任务 | 容器化批处理 | 内部业务命令和数据平台动作 |
| 动态扩展 | 可通过模板/递归/生成新 workflow | command 直接 enqueue 新 message |

## Argo 能给 EMF 的启发

Argo 对 EMF 的启发主要是:

```text
任务隔离
artifact 管理
资源声明
Kubernetes 原生伸缩
模板化 workflow
```

如果 EMF 中有重计算任务或用户自定义代码任务,可以借鉴 Argo:

```text
把重任务下沉到容器/K8s job
worker 只负责 submit + monitor
output 用 artifact / manifest 表达
资源用 CPU/memory/GPU 声明
```

这和前面讲的:

```text
worker 不一定自己执行重任务,也可以触发外部 executor。
```

是一致的。

## 什么时候更像 Airflow

如果你的场景是:

```text
每天定时跑
大多是 SQL / Spark / 数据同步
依赖固定
重跑和 backfill 很重要
需要成熟 UI 和数据平台生态
```

那它更像 Airflow 适合的问题。

面试表达:

```text
如果目标是标准 data pipeline,Airflow 是非常自然的选择,因为它在 DAG 调度、定时、backfill、operator 生态和 UI 上很成熟。
```

## 什么时候更像 Temporal

如果你的场景是:

```text
订单流程
支付流程
长时间等待人工/外部事件
微服务之间需要可靠调用
每一步都要 durable history
业务流程更适合用代码表达
```

那它更像 Temporal。

面试表达:

```text
如果核心问题是长事务和 durable execution,Temporal 更合适。它通过 event history 和 replay 解决 worker 宕机恢复,把业务流程代码变成可靠状态机。
```

## 什么时候更像 Argo

如果你的场景是:

```text
每个任务都是容器
运行在 Kubernetes
任务需要强资源隔离
需要 CPU/GPU/memory 声明
产物通过 artifact 管理
```

那它更像 Argo。

面试表达:

```text
如果任务天然是容器化 batch job,Argo Workflows 会很合适,它利用 Kubernetes 的调度、隔离和资源管理能力。
```

## 什么时候 EMF 这种设计有意义

EMF 这种消息驱动动态 DAG 设计适合:

```text
内部平台已经有一批 command/module/service
任务来自 Service Bus / PubSub 或 OE-RUN
workflow 可以由配置、表、catalogue resolution 推导
运行中还会根据结果继续生成任务
任务需要和 Databricks/Storage/Catalogue/API 等深度集成
任务粒度是业务命令,不一定是容器或 Python operator
```

它的价值是:

```text
用统一的 Message 抽象承载任务、依赖、命令和参数。
用 DagContext 管理 run 内依赖。
用 CommandExecutor 解耦调度和业务执行。
用 module/service 复用内部能力。
用 enqueue 新 Message 支持动态 DAG。
```

它的代价是:

```text
需要自己补齐可靠性、幂等、状态机、观测、资源治理、版本化和运维能力。
```

## 选型判断框架

可以按这几个问题判断:

| 问题 | 更偏向 |
|---|---|
| 是否主要是周期性数据 pipeline | Airflow |
| 是否主要是长事务和可靠业务流程 | Temporal |
| 是否任务天然容器化并运行在 K8s | Argo |
| 是否主要是内部 command/service 编排 | EMF 类平台 |
| 是否需要运行时动态生成大量任务 | EMF / Airflow dynamic mapping / Argo,看场景 |
| 是否需要 durable replay | Temporal |
| 是否需要强任务隔离 | Argo / K8s executor |
| 是否需要和内部消息系统深度集成 | EMF 类平台 |

面试里可以这么组织:

```text
我会先看工作流定义方式、任务执行单元、状态恢复模型、动态扩展需求、外部系统集成深度和运维要求,而不是只问“哪个工具更流行”。
```

## 高频面试问答

### Q1: 为什么不用 Airflow?

可以答:

```text
如果只是标准数据 pipeline,Airflow 很合适。但 EMF 这类系统更强调消息驱动和内部 command/service 编排。它的任务天然来自 Message,通过 run_uuid/order_id/parents 推导 DAG,并且 command 执行过程中可以继续 enqueue 新 Message 来扩展 workflow。这个模型更贴近内部平台事件和业务命令体系。
```

### Q2: 为什么不用 Temporal?

可以答:

```text
Temporal 强在 durable execution 和长事务,适合用代码表达业务流程并通过 event history replay 恢复状态。EMF 更偏 DAG/message-driven 调度,任务是可观测的 message vertex,适合批量任务、数据平台动作和内部 command 编排。如果要做订单/支付这种长事务,Temporal 会更自然;如果要从配置或消息动态展开 DAG,EMF 的模型更直接。
```

### Q3: 为什么不用 Argo?

可以答:

```text
Argo 适合 Kubernetes 原生的容器工作流,每个任务基本是 pod/container。EMF 的任务粒度是内部 command/module,很多任务是调用 Databricks、Storage、Catalogue 或 API,不一定需要每个任务容器化。Argo 的资源隔离和 artifact 管理值得借鉴,但 EMF 的优势在于和内部服务、消息系统、命令体系集成更深。
```

### Q4: EMF 最大的短板是什么?

可以答:

```text
自研工作流引擎最大的短板不是功能能不能做出来,而是生产可靠性和运维治理要自己补齐。比如幂等、状态机、lease、scheduler HA、outbox/inbox、动态 DAG 治理、审计、UI 排障、资源隔离、版本兼容,这些成熟系统已经沉淀很多经验,自研时必须有意识地设计。
```

### Q5: EMF 最大的优势是什么?

可以答:

```text
它把任务抽象成 Message,用 command 解耦调度和业务执行,并允许业务执行过程中继续生成 Message 扩展 DAG。这样 workflow 不一定在运行前完全静态确定,而是可以由外部事件、catalogue resolution、query 结果或子 workflow 动态展开,比较适合内部平台型、命令型、数据动作型编排。
```

## 迁移或融合思路

这些系统也不是互斥的。

一种可能架构:

```text
EMF 负责业务 command 和 DAG 控制平面
Airflow 负责标准周期性数据 pipeline
Temporal 负责强一致长事务流程
Argo/K8s 负责重计算容器任务执行
```

也可以这样融合:

```text
EMF task -> submit Argo Workflow
EMF task -> trigger Airflow DAG
EMF command -> call Temporal workflow
Temporal activity -> submit EMF command
```

关键是边界清楚:

```text
谁是控制平面?
谁是执行平面?
谁负责状态真相?
谁负责重试和补偿?
谁负责审计?
```

如果边界不清,会出现:

```text
两个系统都以为自己负责 retry
两个系统状态不一致
取消一个 workflow 但另一个还在跑
日志和审计分散
```

## 面试总结

可以这样说:

```text
EMF、Airflow、Temporal、Argo 都是工作流系统,但范式不同。Airflow 的核心是数据 pipeline DAG 调度,Temporal 的核心是 durable workflow execution,Argo 的核心是 Kubernetes 原生容器工作流,EMF 更像消息驱动的动态 DAG 和内部命令编排平台。EMF 通过 Message 表达任务,用 run_uuid/order_id/parents 推导 DAG,再用 command 找 module 执行业务,并允许 command 运行时继续 enqueue 新 Message 扩展图。它的优势是贴近内部服务和动态业务编排,代价是可靠性、状态治理、幂等、观测和资源隔离要自己建设。选型时不能只比较功能列表,而要看任务抽象、状态恢复模型、动态扩展需求、执行隔离和运维治理边界。
```

最关键的一句话:

```text
Airflow 偏 DAG 批调度,Temporal 偏可靠长事务,Argo 偏 K8s 容器工作流,EMF 偏消息驱动的内部命令 DAG 编排。
```
