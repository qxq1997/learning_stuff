# 15 生产级 DAG 引擎挑战总览

## 核心判断

从零开发一个 DAG 工作流引擎,技术上最大的挑战不是“把几个任务按依赖顺序跑起来”。

真正难的是:

```text
在失败、重试、并发、暂停、恢复、版本变更、人工介入、数据不一致的情况下,
仍然让流程可控、可追踪、可恢复。
```

一旦进入生产,它就不再只是图执行器,而会变成:

```text
分布式状态机
  + 调度系统
  + 可靠任务系统
  + 运维平台
```

所以面试里不要把 DAG 引擎讲成“拓扑排序 + worker 执行”。拓扑排序只是开始,生产可靠性才是主体。

## 一句话本质

可以把生产级 DAG 引擎记成:

```text
在分布式不可靠环境中,可靠地推进一组有依赖关系的状态机。
```

这句话拆开看:

| 关键词 | 含义 |
|---|---|
| 分布式 | scheduler、worker、DB、MQ、外部系统都可能独立失败 |
| 不可靠 | 网络超时、重复投递、worker 宕机、callback 丢失都会发生 |
| 依赖关系 | 一个节点的状态会影响下游节点是否 ready |
| 状态机 | 任务和 workflow 都有严格状态流转 |
| 可靠推进 | 不能重复执行、不能假完成、不能永远卡住、不能丢审计 |

## 挑战地图

生产级 DAG 引擎可以按 12 类问题来理解。

| 类别 | 核心问题 | 典型事故 |
|---|---|---|
| DAG 建模 | definition / instance / dependency 怎么表达 | 有环、依赖不存在、旧实例被新定义影响 |
| 状态机 | 状态能否严格流转 | `SUCCESS -> RUNNING`、人工改状态无审计 |
| 调度器 | 谁 ready、谁先跑、谁能拿资源 | 重复调度、饿死、资源打爆 |
| 可靠执行 | 任务执行和状态更新能否一致 | 外部成功但状态失败,导致重复副作用 |
| 重试 | 什么失败能重试、怎么重试 | 参数错误无限重试,重试风暴 |
| 失败传播 | 上游失败后下游语义是什么 | 清理任务没执行,汇总节点提前跑 |
| 动态 DAG | 运行时生成节点是否可控 | fan-out 爆炸、relink 错误、run completion 错 |
| 上下文 | 任务输入输出怎么传 | 大 JSON 塞 DB、敏感信息泄露 |
| 人工干预 | 暂停、恢复、重跑、跳过怎么做 | 人工标成功后下游不一致 |
| 可观测性 | 为什么没跑、为什么失败、谁操作过 | 线上排查没有证据链 |
| 一致性 | DB、MQ、worker、外部系统如何协同 | DB 更新成功但消息没发 |
| 规模和运营 | 大 DAG、多租户、升级怎么扛 | scheduler 扫描慢、租户互相抢资源 |

这些不是独立问题。比如“重复执行”同时涉及状态机、任务领取、幂等、重试、外部副作用和审计。

## 从 EMF 角度映射

EMF 当前的主线可以对应到更通用的 DAG 引擎概念:

| 通用概念 | EMF 里的对应物 | 关注点 |
|---|---|---|
| Workflow Definition | workflow / process_tasks / catalogue resolution | 流程模板和任务声明 |
| Workflow Instance | `run_uuid` 对应的一次运行 | 一张运行时 DAG |
| Batch / Run Group | `batch_id` | 一批 run 的生命周期 |
| Task Definition | workflow task | 节点模板 |
| Task Instance | `Message` | 可调度、可执行、可审计的节点实例 |
| Dependency Edge | `parents -> order_id` | 调度依赖 |
| Scheduler | `DagManager` / `DagContext` / `ParallelMessageConsumer` | ready 判断和并发调度 |
| Executor | `MessageHandler` / `StratusCommandExecutor` / module | 业务执行 |
| Execution Context | run context / message scope / parameters | 参数、日志、依赖和 service scope |

这张映射很重要。它能防止把 EMF 误解成“消息队列消费器”,也能防止把所有复杂度都塞进某一个类。

## 生产排查的基本方法

遇到 DAG 引擎问题,不要直接问“代码哪里错了”。先按状态和证据链排查。

第一步:确认 workflow instance 状态。

```text
这个 run 是 RUNNING / FAILED / PAUSED / TIMEOUT / CANCELLED?
状态最后一次变化是什么时候?
是谁或哪个组件改的?
```

第二步:确认 task 分布。

```text
有多少 READY?
有多少 RUNNING?
有多少 FAILED / RETRYING / WAITING?
有没有 INACTIVE 但父节点已满足的任务?
有没有 RUNNING 太久的任务?
```

第三步:确认 DAG 依赖。

```text
卡住节点的 parents 是谁?
parents 是否存在?
parents 状态是否满足 trigger rule?
有没有 cycle / dangling parent / hidden dependency?
```

第四步:确认调度和资源。

```text
ready 任务为什么没被领取?
全局并发是否满了?
tenant / command / external system 配额是否满了?
priority 是否导致某些任务长期饥饿?
```

第五步:确认执行证据。

```text
worker 是否领取过任务?
是否有 lease / heartbeat?
外部 job 是否提交成功?
外部系统 trace_id 是什么?
状态更新是否成功?
是否发生过 retry / timeout / manual override?
```

第六步:确认副作用和幂等。

```text
任务是否重复执行?
外部系统是否已经产生副作用?
idempotency key 是什么?
重复调用是否被外部系统识别?
是否需要 compensation / reconciliation?
```

## 设计原则

### 1. definition 和 instance 必须分开

模板是模板,运行是运行。

```text
Workflow Definition: 工作流定义
Workflow Definition Version: 不可变版本
Workflow Instance: 某次运行
Task Definition: 任务模板
Task Instance: 某次运行里的任务实例
```

如果 definition 和 instance 混在一起,后面会出现:

- 旧 run 被新 DAG 定义影响。
- 重跑时不知道该用哪个版本。
- 审计时无法还原当时执行过什么。
- 任务参数和结果覆盖历史。

### 2. 状态流转必须受控

状态不是普通字段,而是调度信号。

```text
READY -> RUNNING -> SUCCESS
READY -> RUNNING -> FAILED -> RETRYING -> READY
RUNNING -> TIMEOUT
RUNNING -> CANCELLED
WAITING_APPROVAL -> READY
```

不能让任意组件随便改状态。所有状态变化都应该:

- 校验 from/to 是否允许。
- 使用 CAS 或 version 防止并发覆盖。
- 记录 transition log。
- 写明 reason、operator、source component。

### 3. 执行必须默认会重复

生产里重复执行不是异常,而是必然会发生的场景。

原因包括:

- worker 执行成功但状态更新失败。
- MQ 重复投递。
- callback 重复回来。
- scheduler 重启后重新扫描。
- lease 过期后任务被重新领取。

所以有副作用的任务必须设计幂等 key。

### 4. 调度器不能只看 READY

生产调度不是:

```text
有 READY 就跑。
```

而是:

```text
这个任务 ready 吗?
资源池有额度吗?
租户还有配额吗?
外部系统还能承受吗?
这个 workflow run 是否被 pause / cancel?
这个任务类型是否被限流?
```

### 5. 可观测性不是附属功能

DAG 引擎生产可用的关键是用户能回答:

```text
为什么没跑?
为什么跑慢?
为什么失败?
谁改过状态?
用了什么参数?
外部系统返回了什么?
下一步该怎么办?
```

如果只能看到 `Task failed`,这个系统很难进入生产。

## 最容易踩的坑

| 坑 | 后果 | 设计修复 |
|---|---|---|
| 只设计成功路径 | 一失败就需要人工查库 | 先设计失败、超时、取消、重试 |
| 没有幂等 | 重复发券、重复扣款、重复写入 | 业务幂等 key + 唯一约束 |
| 只存当前状态 | 排查没有证据链 | 状态变更历史表 |
| DAG 没版本化 | 旧实例被新定义污染 | 每次运行绑定不可变 definition version |
| 调度器单点 | scheduler 挂了全停 | 多实例 + CAS / lease 领取 |
| 没有 zombie 检测 | 任务永远 RUNNING | heartbeat + lease timeout + scanner |
| 日志不可用 | 用户无法自助排查 | task log、trace id、错误分类 |
| 大结果塞 DB | DB 膨胀拖垮 | 元数据进 DB,大对象进对象存储 |
| 没有资源隔离 | 大 DAG 打爆平台 | 队列、优先级、配额、资源池 |
| 人工操作无审计 | 事故无法追责 | operation audit log |

## 推荐演进路线

不要一开始就做成 Airflow。可以分阶段演进。

### 第一版:核心 DAG 执行

- DAG 定义。
- 拓扑排序。
- 任务实例生成。
- `READY / RUNNING / SUCCESS / FAILED` 状态机。
- 简单 scheduler。
- 简单 worker。
- 失败停止。
- 基础日志。

### 第二版:生产可靠性

- 重试机制。
- 幂等键。
- 任务锁 / lease。
- 超时处理。
- worker heartbeat。
- 状态变更历史。
- DAG 版本化。
- 失败告警。

### 第三版:生产可运营

- 暂停 / 恢复 / 取消。
- 从失败节点重跑。
- 人工跳过。
- 权限控制。
- 审计日志。
- 运行面板。
- 并发限制。
- 资源池。

### 第四版:高级能力

- 条件分支。
- 动态任务。
- 子工作流。
- 事件等待。
- 补偿机制。
- 多租户隔离。
- 复杂 trigger rule。
- 大规模调度优化。

## 面试总结

可以这样讲:

```text
从零做 DAG 工作流引擎,难点不只是拓扑排序和依赖调度,
而是生产环境下的可靠状态管理。
核心挑战包括 DAG 定义版本化、任务状态机、调度器高可用、任务幂等、
失败重试、超时恢复、人工干预、日志审计和资源隔离。
生产上最容易出问题的是任务重复执行、worker 宕机导致任务卡死、
DB 和 MQ 状态不一致、DAG 修改影响历史实例、以及缺少审计导致问题无法追溯。
因此设计时需要把 workflow definition 和 instance 分离,
引入不可变版本、任务租约、CAS 状态更新、幂等 key、重试策略、heartbeat、
状态变更日志和操作审计。
这样系统才不是一个简单 DAG runner,而是一个可恢复、可审计、可运营的工作流平台。
```




从零开发一个 **DAG 工作流引擎**，技术上最大的挑战不是“把几个任务按依赖顺序跑起来”，而是：

**如何在失败、重试、并发、暂停、恢复、版本变更、人工介入、数据不一致的情况下，仍然让流程可控、可追踪、可恢复。**

这东西一旦进生产，就会从“图执行器”变成“分布式状态机 + 调度系统 + 可靠任务系统 + 运维平台”。

---

## **1. 第一层挑战：DAG 建模本身**

最基础的是定义工作流：

```text
A -> B -> D
A -> C -> D
```

看起来很简单，但生产里会马上遇到这些问题：

### **1.1 DAG 合法性校验**

你要检查：

```text
是否有环？
是否有孤立节点？
是否有重复节点？
是否有不存在的依赖？
是否存在无法到达的任务？
```

比如：

```text
A -> B -> C -> A
```

这就不是 DAG，而是有环图。必须在提交工作流定义时拦截。

常见做法是：

```text
拓扑排序
DFS 检测环
入度表检测可执行节点
```

但这只是最基础的。

---

### **1.2 节点类型设计**

一个工作流节点可能不是简单的“执行一个函数”。

它可能是：

```text
SQL 节点
HTTP 调用节点
Spark / Databricks Job 节点
人工审批节点
条件判断节点
并行分支节点
子工作流节点
事件等待节点
补偿节点
通知节点
```

所以你需要设计一个统一抽象：

```text
Task Definition：任务定义
Task Instance：任务实例
Workflow Definition：流程定义
Workflow Instance：流程实例
Execution Context：执行上下文
```

这里很容易混乱。

**定义**是模板，**实例**是某次真实运行。

例如：

```text
工作流定义：每日数据同步 DAG
工作流实例：2026-05-13 这一次运行
任务定义：同步客户表
任务实例：今天这次同步客户表的执行记录
```

很多自研系统一开始会把 definition 和 instance 混在一起，后面会很痛。

---

## **2. 第二层挑战：任务状态机设计**

DAG 引擎的核心其实是状态机。

一个任务不能只有：

```text
成功 / 失败
```

至少要有：

```text
CREATED
READY
RUNNING
SUCCESS
FAILED
SKIPPED
RETRYING
CANCELLED
TIMEOUT
WAITING_APPROVAL
WAITING_EVENT
```

工作流实例也需要状态：

```text
CREATED
RUNNING
SUCCESS
FAILED
PARTIAL_SUCCESS
CANCELLED
PAUSED
SUSPENDED
```

技术难点在于：**状态流转必须严格受控**。

比如：

```text
READY -> RUNNING -> SUCCESS
READY -> RUNNING -> FAILED -> RETRYING -> READY
RUNNING -> TIMEOUT
RUNNING -> CANCELLED
WAITING_APPROVAL -> READY
```

但不应该允许：

```text
SUCCESS -> RUNNING
FAILED -> SUCCESS  // 除非是人工修复后的特殊动作
CANCELLED -> RUNNING
```

生产中非常容易出现“状态乱跳”。

尤其是多线程调度器、多个 worker、人工操作、异步 callback 同时修改状态时，状态机会变成事故高发区。

---

## **3. 第三层挑战：调度器设计**

DAG 引擎的调度器需要不断判断：

```text
哪些任务可以执行？
哪些任务正在运行？
哪些任务失败了要重试？
哪些任务超时了？
哪些工作流已经完成？
```

简单逻辑是：

```text
当一个任务成功后，检查它的下游任务
如果下游任务所有上游都成功，则置为 READY
然后交给 worker 执行
```

但是生产里会复杂很多。

---

### **3.1 并发控制**

你通常需要限制：

```text
全局最大并发
单个工作流最大并发
单个租户最大并发
单个任务类型最大并发
单个外部系统最大并发
```

比如 Databricks、数据库、第三方 API 都有容量限制。

否则一个大 DAG 可能瞬间把数据库打爆。

所以调度器不能只是：

```text
有任务就跑
```

而是要判断：

```text
当前资源池是否还有额度？
这个任务类型是否还能运行？
这个用户是否超过并发限制？
这个 workflow run 是否超过并发限制？
```

---

### **3.2 调度公平性**

假设有两个用户：

```text
用户 A 提交了 10000 个任务
用户 B 提交了 10 个任务
```

如果简单按时间顺序调度，B 可能长期被 A 堵住。

所以你可能需要：

```text
优先级队列
租户隔离
公平调度
资源配额
队列分组
```

这就是从“任务执行器”升级成“资源调度系统”。

---

### **3.3 调度器高可用**

如果调度器挂了怎么办？

你不能让所有 RUNNING 任务和 READY 任务都卡死。

所以需要考虑：

```text
调度器是否可以多实例部署？
多个调度器会不会重复调度同一个任务？
调度器重启后如何恢复现场？
正在运行的任务如何重新确认状态？
```

这会引出非常关键的问题：**任务领取机制**。

例如用数据库实现时，不能这样：

```sql
SELECT * FROM task_instance WHERE status = 'READY';
```

然后多个 scheduler 都拿到同一个任务。

你需要类似：

```sql
SELECT ...
FOR UPDATE SKIP LOCKED
```

或者 CAS 更新：

```sql
UPDATE task_instance
SET status = 'RUNNING', worker_id = ?
WHERE id = ?
AND status = 'READY';
```

只有更新成功的 worker 才真正拿到任务。

---

## **4. 第四层挑战：可靠执行与幂等**

这是生产里最核心的问题。

任务可能出现这些情况：

```text
任务执行成功了，但状态更新失败
状态更新成功了，但外部 API 调用失败
worker 执行中宕机
网络超时，但对方其实执行成功了
用户重复点击运行
消息队列重复投递
callback 重复回来
```

这时你必须靠 **幂等设计**。

---

## **5. 最经典的生产事故：任务重复执行**

比如一个任务是：

```text
给用户发优惠券
```

worker 执行时：

```text
1. 调用发券系统成功
2. 更新 task_instance 状态为 SUCCESS
```

如果第 1 步成功，第 2 步失败，worker 重启后任务可能被重新执行。

结果就是：

```text
用户收到两张券
```

所以任务执行必须支持幂等。

常见方式：

```text
业务幂等键
request_id
workflow_instance_id + task_instance_id
唯一索引
外部系统幂等接口
执行记录表
```

比如：

```text
coupon_request_id = workflow_instance_id + task_instance_id
```

发券系统收到同一个 request_id，应该只发一次。

---

## **6. 第五层挑战：重试机制**

重试不是简单地：

```text
失败了再跑一次
```

你要区分：

```text
可重试失败
不可重试失败
业务失败
系统失败
超时失败
依赖失败
人工取消
```

比如：

```text
网络抖动：可以重试
数据库死锁：可以重试
参数错误：不应该重试
余额不足：不应该重试
权限不足：不应该重试
外部系统 500：可以重试
外部系统 400：一般不重试
```

重试策略也要设计：

```text
最大重试次数
固定间隔
指数退避
随机抖动 jitter
失败后告警
失败后进入人工处理
```

例如：

```text
第 1 次失败：10 秒后重试
第 2 次失败：1 分钟后重试
第 3 次失败：5 分钟后重试
第 4 次失败：进入 FAILED
```

否则生产上容易出现两个问题：

第一，瞬间重试把下游系统打爆。

第二，本来就是参数错误，却一直无意义重试。

---

## **7. 第六层挑战：失败传播与分支语义**

DAG 中一个节点失败后，下游怎么办？

假设：

```text
A -> B -> D
A -> C -> D
```

如果 B 失败，C 成功，D 该不该执行？

这取决于你的依赖策略。

常见策略：

```text
all_success：所有上游成功才执行
all_done：所有上游结束就执行，不管成功失败
one_success：任一上游成功就执行
none_failed：没有失败即可执行
always：总是执行
```

Airflow 里类似叫 trigger rule。

如果你自研，一定要把这个语义设计清楚。

否则用户会问：

```text
为什么上游失败了，下游还跑了？
为什么有一个分支成功，下游却没跑？
为什么清理任务没有执行？
```

---

## **8. 第七层挑战：条件分支和动态 DAG**

生产流程往往不是固定的。

例如：

```text
如果金额 > 10000，走人工审批
否则自动通过
```

或者：

```text
根据输入文件数量，动态生成 N 个处理任务
```

这会带来两个难点。

---

### **8.1 条件分支**

你需要表达：

```text
if / else
switch / case
branch
join
```

例如：

```text
        -> Manual Approval ->
Start                         End
        -> Auto Approval   ->
```

问题是：未被选中的分支应该是什么状态？

通常是：

```text
SKIPPED
```

然后下游 join 节点要知道：

```text
SKIPPED 是否算完成？
```

这就和前面的 trigger rule 绑定在一起了。

---

### **8.2 动态任务生成**

比如：

```text
读取 100 个文件
为每个文件生成一个处理任务
全部处理完后合并
```

这就变成：

```text
Map -> Reduce
```

挑战是：

```text
动态生成的任务如何持久化？
生成后 DAG 版本如何记录？
动态任务数量过大怎么办？
失败后如何局部重跑？
UI 如何展示？
```

动态 DAG 是很多自研系统后期最难补的能力之一。

---

## **9. 第八层挑战：数据传递与上下文管理**

任务之间经常要传递数据。

例如：

```text
A 查询出 customer_id
B 用 customer_id 调 API
C 根据 B 的结果生成报告
```

你需要设计：

```text
任务输入参数
任务输出结果
全局上下文
运行时变量
敏感信息处理
大对象存储
```

不能把所有输出都塞进数据库。

比如一个任务输出 500MB 的 JSON，就不能直接放进 `task_instance.output` 字段。

更合理的方式是：

```text
小结果：存 DB
大结果：存对象存储，例如 S3 / OSS / ADLS / GCS
敏感信息：引用 Secret，不直接明文存储
```

生产问题包括：

```text
上下文过大
上下文版本不一致
任务读取了错误的变量
敏感信息泄露到日志
重跑时使用了旧输出还是新输出
```

---

## **10. 第九层挑战：暂停、恢复、取消、重跑**

生产系统一定会有人工操作。

用户会要求：

```text
暂停工作流
恢复工作流
取消工作流
重跑失败节点
从某个节点开始重跑
跳过某个节点
手动标记成功
手动修复参数后继续
```

这些功能非常难，因为它们会破坏原本的自动状态流转。

例如：

```text
A -> B -> C -> D
```

如果 C 失败了，用户修改参数后想只重跑 C 和 D，怎么办？

你需要回答：

```text
B 的输出是否复用？
C 的旧输出是否清理？
D 的旧状态是否重置？
这次重跑是新的 workflow instance，还是原 instance 的 attempt？
审计日志如何记录？
```

比较好的设计是引入：

```text
attempt number
retry history
rerun policy
manual operation audit log
```

---

## **11. 第十层挑战：版本管理**

这是很多人一开始会忽略，但生产里必炸的问题。

假设你今天定义了 DAG：

```text
A -> B -> C
```

明天用户修改成：

```text
A -> B -> D -> C
```

问题来了：

```text
昨天还在运行的 workflow instance 应该按旧 DAG 继续，还是按新 DAG？
失败后重跑用旧版本还是新版本？
审计时如何知道当时到底跑了哪个定义？
```

所以你需要：

```text
workflow_definition
workflow_definition_version
workflow_instance.definition_version_id
```

每次运行绑定一个不可变版本。

这点在金融、合规、审计场景尤其重要。

---

## **12. 第十一层挑战：日志、审计、可观测性**

生产上用户最常问的不是“你用了什么算法”，而是：

```text
为什么没跑？
为什么跑慢了？
为什么失败？
谁点了重跑？
这个任务用了什么参数？
上游输出是什么？
什么时候开始卡住的？
```

所以 DAG 引擎必须有完整的可观测性：

```text
任务日志
状态变更日志
执行耗时
排队耗时
重试次数
错误堆栈
输入输出快照
人工操作审计
外部调用 trace_id
指标 dashboard
告警
```

最低限度要有：

```text
workflow_instance 表
task_instance 表
task_execution_log 表
task_state_transition 表
operation_audit_log 表
```

状态变更最好不要只覆盖当前状态，还要保留历史。

例如：

```text
task_id | from_status | to_status | reason | operator | created_at
```

这样线上排查才有证据链。

---

## **13. 第十二层挑战：分布式锁和一致性**

DAG 引擎通常涉及：

```text
API Server
Scheduler
Worker
Database
Message Queue
External Systems
```

典型架构：

```text
User/API
   |
Workflow Service
   |
Database  <-> Scheduler
   |
Message Queue
   |
Worker
   |
External Systems
```

问题是：这些组件之间不会天然一致。

你会遇到：

```text
DB 状态和 MQ 消息不一致
任务已入队但 DB 更新失败
DB 更新成功但消息发送失败
worker 执行成功但 callback 丢失
多个 worker 抢同一个任务
scheduler 重复扫描同一个任务
```

经典解决思路：

```text
Outbox Pattern
幂等消费
CAS 状态更新
乐观锁 version 字段
唯一约束
定期补偿扫描
心跳机制
租约 lease
```

比如任务领取可以设计成：

```text
status = READY
lease_until < now
```

worker 领取任务时：

```sql
UPDATE task_instance
SET status = 'RUNNING',
    worker_id = ?,
    lease_until = now() + interval '5 minutes',
    attempt = attempt + 1
WHERE id = ?
  AND status = 'READY';
```

如果 worker 挂了，lease 过期后任务可以被重新捞起来。

---

## **14. 第十三层挑战：Worker 执行模型**

worker 怎么执行任务也很关键。

有几种模式：

### **模式一：内置执行**

worker 直接执行代码。

优点：

```text
简单
低延迟
容易调试
```

缺点：

```text
隔离性差
用户代码可能拖垮 worker
依赖冲突
安全风险高
```

---

### **模式二：外部任务触发**

worker 只是触发外部系统，例如：

```text
Databricks Job
Spark Job
Kubernetes Job
HTTP API
SQL Engine
```

优点：

```text
隔离性好
适合重任务
容易扩容
```

缺点：

```text
状态回传复杂
callback / polling 都要处理
外部系统失败语义不统一
```

---

### **模式三：容器化执行**

每个任务用容器或 Pod 执行。

优点：

```text
隔离最好
资源可控
适合多语言、多依赖
```

缺点：

```text
复杂度高
启动慢
成本高
调度和日志采集复杂
```

---

## **15. 第十四层挑战：超时、心跳与僵尸任务**

生产里一定会出现：

```text
任务一直 RUNNING
worker 已经死了
外部 job 已经失败但没回调
网络中断导致状态没更新
```

这类任务叫 zombie task。

你需要：

```text
worker heartbeat
task heartbeat
lease timeout
external job polling
timeout scanner
zombie detector
```

例如：

```text
如果 task_instance.status = RUNNING
并且 updated_at 超过 30 分钟没变化
并且 worker heartbeat 已过期
则标记为 LOST / RETRYING / FAILED
```

不做这个，系统会积累大量永远 RUNNING 的任务。

---

## **16. 第十五层挑战：权限与多租户**

如果这是公司内部平台，还要考虑：

```text
谁能创建工作流？
谁能运行？
谁能看日志？
谁能重跑失败节点？
谁能手动标记成功？
谁能审批？
谁能查看敏感参数？
```

在金融场景下尤其重要。

你可能需要：

```text
RBAC
项目空间
租户隔离
操作审计
审批流
Secret 权限控制
数据脱敏
```

比如某些任务参数里有：

```text
客户 ID
账户信息
访问 token
数据库连接信息
```

这些不能直接暴露在 UI 和日志里。

---

## **17. 第十六层挑战：UI 和排障体验**

DAG 引擎非常依赖 UI。

用户需要看到：

```text
DAG 图
节点状态
运行历史
失败原因
日志
耗时
重试记录
输入输出
上下游依赖
手动操作按钮
```

难点在于：

```text
大 DAG 如何渲染？
几千个动态节点如何展示？
如何快速定位失败节点？
如何展示 skipped / retrying / waiting？
如何展示历史版本？
```

如果 UI 做得差，用户会觉得系统“不可控”。

---

## **18. 第十七层挑战：性能与规模**

小规模时，一切都好说。

但生产上会遇到：

```text
每天几万个 workflow instance
每天几十万 task instance
单个 DAG 几千个节点
大量状态扫描
大量日志写入
大量任务轮询
```

数据库会很快成为瓶颈。

需要考虑：

```text
表分区
索引设计
冷热数据归档
批量调度
减少全表扫描
事件驱动替代轮询
日志单独存储
```

例如 `task_instance` 表至少要考虑这些索引：

```text
status
workflow_instance_id
scheduled_time
lease_until
worker_id
created_at
```

否则 scheduler 每次扫描 READY 任务都会越来越慢。

---

## **19. 第十八层挑战：部署和升级**

DAG 引擎自身升级也很麻烦。

因为它升级时，可能还有大量工作流正在运行。

你要考虑：

```text
老版本 worker 和新版本 scheduler 是否兼容？
状态枚举变更如何迁移？
任务定义 schema 变更如何兼容？
数据库 migration 会不会锁表？
运行中的任务如何平滑处理？
```

特别是你新增状态，比如：

```text
SUSPENDED
WAITING_EVENT
```

旧 worker 不认识这个状态怎么办？

所以状态机、schema、worker 协议都要做版本兼容。

---

# **生产上最容易踩的坑**

我按严重程度排一下。

---

## **坑 1：只设计成功路径，没有设计失败路径**

很多系统一开始只考虑：

```text
A 成功后跑 B
B 成功后跑 C
```

但生产里 80% 的复杂度来自：

```text
失败
超时
取消
重试
部分成功
人工修复
外部系统不确定状态
```

所以 DAG 引擎设计时，应该先问：

```text
失败后怎么办？
重复执行怎么办？
状态不一致怎么办？
用户想恢复怎么办？
```

---

## **坑 2：没有幂等，导致重复执行事故**

这是最危险的。

只要你的任务有副作用，比如：

```text
发券
扣款
发邮件
改库存
写数据库
触发审批
创建工单
```

就必须设计幂等。

否则迟早出现重复发、重复扣、重复写。

---

## **坑 3：状态只存当前值，不存变更历史**

只存：

```text
status = FAILED
```

是不够的。

你还要知道：

```text
什么时候从 RUNNING 变成 FAILED？
谁触发的？
失败原因是什么？
之前重试过几次？
是否被人工改过？
```

否则线上排查基本靠猜。

---

## **坑 4：DAG 定义没有版本化**

没有版本化会导致：

```text
旧实例按新定义执行
审计无法还原
重跑结果不一致
用户修改流程后影响历史运行
```

生产系统一定要让每次运行绑定不可变 DAG 版本。

---

## **坑 5：调度器单点**

如果只有一个 scheduler，而且没有恢复机制：

```text
scheduler 挂了，所有流程停摆
```

但如果简单部署多个 scheduler，又会出现：

```text
同一个任务被多个 scheduler 调度
```

所以要有可靠的任务领取和锁机制。

---

## **坑 6：没有处理僵尸任务**

任务一直 RUNNING，没人知道。

一周后用户问：

```text
为什么这个流程还没结束？
```

你一查发现 worker 三天前就挂了。

必须有：

```text
heartbeat
lease timeout
zombie scanner
```

---

## **坑 7：日志不可用**

只告诉用户：

```text
Task failed
```

没有任何堆栈、参数、trace_id、外部返回码。

这会让系统很难被生产团队接受。

好的错误信息应该包括：

```text
错误类型
错误消息
外部系统 response code
trace_id
重试次数
下一步建议
```

---

## **坑 8：把大结果塞进数据库**

一开始方便，后面数据库膨胀严重。

尤其是：

```text
大 JSON
SQL 查询结果
文件内容
模型输出
日志全文
```

应该分层：

```text
元数据进 DB
大对象进对象存储
日志进日志系统
```

---

## **坑 9：没有资源隔离**

某个用户提交一个超大 DAG，把整个系统资源吃光。

所以要有：

```text
队列
优先级
并发限制
租户配额
任务类型限流
```

---

## **坑 10：人工操作没有审计**

生产里用户会：

```text
手动重跑
手动跳过
手动标记成功
手动取消
```

如果没有审计，后面出问题说不清楚。

至少记录：

```text
operator
operation
target
old_status
new_status
reason
timestamp
```

---

# **一个比较合理的技术架构**

可以这样分层：

```text
                UI / API
                  |
        Workflow Management Service
                  |
       ----------------------------
       |                          |
 Definition Store          Instance Store
       |                          |
       -------- Scheduler --------
                  |
             Task Queue
                  |
              Workers
                  |
      External Systems / Executors
```

核心模块：

```text
Workflow Definition Service：管理 DAG 定义和版本
Workflow Instance Service：管理每次运行
Scheduler：发现可执行任务
Executor / Worker：执行任务
State Machine：控制状态流转
Retry Manager：处理重试
Timeout Scanner：处理超时和僵尸任务
Audit Service：记录操作审计
Log Service：采集任务日志
Notification Service：失败和超时告警
```

---

# **最小可用版本应该包含什么？**

不要一开始就做成 Airflow。

MVP 可以这样：

## **第一版：核心 DAG 执行**

```text
DAG 定义
拓扑排序
任务实例生成
READY / RUNNING / SUCCESS / FAILED 状态机
简单 scheduler
简单 worker
失败停止
基础日志
```

---

## **第二版：生产可靠性**

```text
重试机制
幂等键
任务锁 / lease
超时处理
worker heartbeat
状态变更历史
DAG 版本化
失败告警
```

---

## **第三版：生产可运营**

```text
暂停 / 恢复 / 取消
从失败节点重跑
人工跳过
权限控制
审计日志
运行面板
并发限制
资源池
```

---

## **第四版：高级能力**

```text
条件分支
动态任务
子工作流
事件等待
补偿机制
多租户隔离
复杂 trigger rule
大规模调度优化
```

---

# **数据库表可以怎么设计？**

一个简化版本：

```sql
workflow_definition
- id
- name
- owner
- created_at
- updated_at

workflow_definition_version
- id
- workflow_definition_id
- version
- dag_json
- status
- created_at

workflow_instance
- id
- workflow_definition_version_id
- status
- input_json
- started_at
- ended_at
- created_by
- created_at

task_instance
- id
- workflow_instance_id
- task_key
- task_type
- status
- attempt
- max_retries
- scheduled_at
- started_at
- ended_at
- worker_id
- lease_until
- input_ref
- output_ref
- error_message
- created_at
- updated_at

task_dependency
- workflow_instance_id
- upstream_task_key
- downstream_task_key

task_state_transition
- id
- task_instance_id
- from_status
- to_status
- reason
- operator
- created_at

workflow_operation_audit
- id
- workflow_instance_id
- operation
- operator
- reason
- created_at
```

如果是生产系统，我会强烈建议保留：

```text
task_state_transition
workflow_operation_audit
```

这两个表非常有价值。

---

# **你可以在面试里怎么总结？**

可以这样说：

从零做 DAG 工作流引擎，难点不只是拓扑排序和依赖调度，而是生产环境下的可靠状态管理。核心挑战包括 DAG 定义版本化、任务状态机、调度器高可用、任务幂等、失败重试、超时恢复、人工干预、日志审计和资源隔离。生产上最容易出问题的是任务重复执行、worker 宕机导致任务卡死、DB 和 MQ 状态不一致、DAG 修改影响历史实例、以及缺少审计导致问题无法追溯。因此设计时需要把 workflow definition 和 instance 分离，引入不可变版本、任务租约、CAS 状态更新、幂等 key、重试策略、heartbeat、状态变更日志和操作审计。这样这个系统才不是一个简单的 DAG runner，而是一个可恢复、可审计、可运营的工作流平台。

这段很适合后端面试。

---

# **最关键的一句话**

**DAG 工作流引擎的本质不是“按顺序执行任务”，而是“在分布式不可靠环境中，可靠地推进一组有依赖关系的状态机”。**

你只要抓住这句话，后面所有设计都会顺很多。