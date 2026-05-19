# 33 Worker 与 Scheduler 宕机恢复

## 先区分两种死亡

在工作流引擎里,worker 死和 scheduler 死不是一回事。

```text
Worker 死:
  影响的是某些正在执行的 task。
  风险是 RUNNING 卡住、外部副作用状态不明、旧 attempt 迟到回写。

Scheduler 死:
  影响的是状态推进和新任务派发。
  风险是 READY 不再派发、timeout/retry/cancel scanner 暂停、outbox backlog 堆积。
```

一句话:

```text
worker 死了,任务可能没人执行完;
scheduler 死了,系统可能没人继续调度。
```

它们的恢复机制也不同:

| 故障 | 发现方式 | 恢复者 | 核心机制 |
|---|---|---|---|
| 单个 worker 死 | worker heartbeat stale、task lease expired | zombie detector / recovery scanner | lease、fencing、external reconcile |
| 所有 worker 死 | worker pool heartbeat 全部 stale、queue 堆积 | scheduler / autoscaler / oncall | 停止派发、恢复 capacity、限速恢复 |
| scheduler 死 | scheduler heartbeat stale、leader lease expired | standby scheduler / 新 leader | leader election、CAS、outbox、state scan |
| scheduler 脑裂 | 多个 scheduler 同时推进 | DB CAS / fencing | version、epoch、唯一约束 |
| scheduler + worker 都死 | 所有控制面/执行面停止 | 重启后的 recovery mode | 重建 DAG、对账外部、限流恢复 |

## 关键原则

### 1. 进程死亡不能带走关键状态

关键状态必须落在 durable store:

```text
task_instance
workflow_instance
state_transition_log
outbox_event
inbox_event
external_call_ledger
resource_token
DAG definition / DAG instance
```

如果 EMF 的 DAG 文件统一放在 GCS,并且 owner、team、SLA、Jira board、command policy 等 metadata 在 GCS file metadata 或 DAG 文件 metadata 里,那么 scheduler 重启时应该能从这些来源重建:

```text
DAG definition
task graph
command policy
owner routing
retry / timeout policy
resource profile
```

如果 DAG 只存在某个 worker 内存里的 `DagManager`,进程一死就无法可靠恢复。

### 2. 死亡恢复要先对账,再调度

服务重启后最容易犯错:

```text
看到 RUNNING 很久没变 -> 全部重跑
```

正确顺序是:

```text
恢复服务进程
暂停或限速新调度
扫描非终态任务
对账 worker lease / external job / callback / output_ref
恢复状态
再逐步恢复 dispatch
```

也就是:

```text
先把旧世界解释清楚,再创建新执行。
```

### 3. 所有恢复写入都要 CAS

恢复逻辑也是并发写入者。

它不能绕过状态机直接 update。

```sql
UPDATE task_instance
SET status = 'RETRYING',
    recovery_reason = 'worker_lease_expired',
    version = version + 1
WHERE id = :task_id
  AND status = 'RECOVERING'
  AND version = :version;
```

这样即使 worker、scheduler、scanner、manual operator 同时动作,也不会互相覆盖。

## Worker 死了怎么办

Worker 死亡可以按时间点拆。

### 1. 还没领取任务就死

场景:

```text
task.status = READY
worker process crash
```

影响很小。

处理:

```text
任务仍然 READY
其他 worker 或重启后的 worker 可以继续 claim
```

只要 claim 是 CAS,不会重复执行。

### 2. 刚领取,还没真正开始执行就死

场景:

```text
READY -> RUNNING
worker_id = worker-1
lease_until = 10:05
worker-1 crash
external_job_id = null
```

处理:

```text
等 lease 过期
zombie detector 接管
确认没有 external side effect
RUNNING -> RECOVERING -> RETRYING -> READY
```

这里仍然不能只看 `external_job_id = null`,因为 worker 可能死在外部 submit 后、写 DB 前。

如果 command 没有任何外部副作用,可以安全 retry。

如果 command 可能有外部副作用,要查 idempotency ledger 或 external request id。

### 3. 本地执行中死

场景:

```text
worker 在本地处理文件、参数、转换逻辑时 crash
```

处理取决于 output:

| 情况 | 处理 |
|---|---|
| 没有写任何外部产物 | retry |
| 写了临时文件但没有 commit marker | 清理或覆盖后 retry |
| 写了正式 output_ref | 校验 output contract,可能补 SUCCESS |
| 写入状态未知 | NEEDS_MANUAL_CHECK 或专门 reconcile |

所以 output 最好有两阶段语义:

```text
write temp output
write manifest / marker
CAS mark SUCCESS
```

下游只认 marker 或 manifest,不认半成品文件。

### 4. 提交外部 job 后死

这是最常见也最危险的场景。

```text
worker submit Databricks job
external job 已经创建
worker 写 task.external_job_id 前 crash
```

平台可能看到:

```text
status = RUNNING
lease expired
external_job_id = null
```

但外部 job 真实存在。

处理:

```text
用 idempotency_key / external_request_id 查询 external_call_ledger
或查询外部系统 request history
能找到 job -> 绑定 external_job_id,进入 RUNNING_EXTERNAL / WAITING_EVENT
找不到且确认无副作用 -> retry
无法确认 -> LOST / NEEDS_MANUAL_CHECK
```

这里最重要的设计是:

```text
外部 submit 请求必须带稳定 idempotency_key。
```

否则 worker 死在 submit 边界时,平台无法判断是否可以重跑。

### 5. 外部 job 完成后,worker 回写前死

场景:

```text
external job = SUCCEEDED
output 已经写到 GCS
task.status 仍然 RUNNING / RUNNING_EXTERNAL
```

处理:

```text
zombie detector / reconciliation job 查询 external status
校验 output_ref / manifest / marker
CAS 更新 SUCCESS
写 transition reason = external_success_reconciled
```

如果 external job failed:

```text
retryable -> RETRYING
non-retryable -> FAILED
```

如果 external job succeeded 但 output 缺失:

```text
OUTPUT_VALIDATING / NEEDS_MANUAL_CHECK
```

### 6. Worker 死后又活了

旧 worker 可能并没有彻底死,只是卡顿、网络断开、GC pause,然后又恢复。

风险:

```text
旧 worker 的 lease 已经过期
新 attempt 已经开始
旧 worker 迟到写 SUCCESS
```

防护:

```text
worker 回写必须带 attempt + lease_token
task 更新必须 CAS
旧 lease_token 失效后只能写 attempt_result,不能写主状态
```

例如:

```sql
UPDATE task_instance
SET status = 'SUCCESS'
WHERE id = :task_id
  AND attempt = :attempt
  AND lease_token = :lease_token
  AND status = 'RUNNING';
```

更新不到就说明这个 worker 已经失去执行权。

## 所有 Worker 都死了怎么办

所有 worker 死亡时,系统会出现:

```text
READY / QUEUED 堆积
RUNNING lease 逐渐过期
外部 job 继续在外部系统运行
callback 可能继续到达
scheduler 可能还在产生更多 dispatch
```

正确处理不是无限派发。

### 1. Scheduler 要感知 worker pool 不健康

worker registry 应该维护:

```text
worker_id
worker_pool
capabilities
last_heartbeat_at
capacity
current_tasks
status
generation
```

当某个 worker pool 全部 stale:

```text
no healthy worker for capability = databricks
```

scheduler 应该:

```text
停止向对应 queue 派发新任务
把任务保留在 READY / BLOCKED
blocked_reason = no_healthy_worker
发出 worker_pool_unhealthy 告警
```

不要把几十万任务继续塞进队列。

### 2. 恢复 capacity 后限速接管

worker 恢复后,不要让所有过期任务同时 retry。

要按:

```text
tenant
workflow
command
external_system
priority
age
```

做恢复限速。

例如:

```text
每分钟最多恢复 100 个 expired task
每个 tenant 最多恢复 20 个
Databricks command 最多恢复 10 个
side_effect_unknown 不自动恢复
```

否则会出现 retry storm:

```text
worker 全挂 30 分钟
1 万个 lease 同时过期
worker 一恢复,1 万个任务同时重试
Databricks / DB / GCS 被打爆
```

### 3. 外部 job 优先 reconcile,不是优先 retry

全 worker 故障期间,外部 job 可能已经完成。

恢复顺序:

```text
先查询 external_job_id 已存在的任务
补 SUCCESS / FAILED / OUTPUT_VALIDATING
再处理没有 external_job_id 的任务
最后处理 side_effect_unknown
```

这样能减少重复提交。

## Scheduler 死了怎么办

Scheduler 死亡通常不会直接杀掉正在执行的 worker。

它影响的是:

```text
新的 READY 不再派发
retry 到期任务没人重新 ready
timeout/cancel/zombie scanner 可能暂停
workflow completion 可能不再计算
outbox publisher 如果跟 scheduler 绑在一起也会暂停
```

所以 scheduler 的设计目标是:

```text
可被替换,可被多实例接管,不保存唯一关键状态。
```

## 单 Scheduler 重启

如果只有一个 scheduler,它重启后应该做 recovery scan:

```text
1. 注册 scheduler identity 和 generation。
2. 读取 GCS DAG files / DAG metadata,恢复 DAG definition。
3. 从 DB 读取 workflow_instance 和 task_instance。
4. 扫描 READY / QUEUED / RUNNING / RETRYING / WAITING_EVENT / CANCELLING。
5. 对 RUNNING 做 lease/heartbeat 判断。
6. 对 external job 做 reconciliation。
7. 处理 due retry / due timeout / due cancel。
8. 重新开始 dispatch。
```

重启后不应该相信本地内存里的旧图。

可靠来源应该是:

```text
GCS DAG file
GCS file metadata
task_instance
workflow_instance
state_transition_log
outbox/inbox
external_call_ledger
```

如果某个动态 DAG 子节点只存在内存里、没有写 task_instance 或 lineage log,那 scheduler 重启后就无法知道它存在。

所以动态 DAG expansion 也要持久化:

```text
parent task generates child specs
insert child task_instance with unique(run_uuid, order_id)
insert lineage event
commit
```

### Scheduler 死亡时间点

| 死亡时间点 | 风险 | 恢复 |
|---|---|---|
| 算出 READY 前死 | 没影响,新 scheduler 重新计算 |
| 把 task 标 READY 后死 | 新 scheduler 继续领取 |
| 标 QUEUED 后、发 MQ 前死 | outbox publisher 补发 |
| 发 MQ 后、没记录成功就死 | worker 消费时查 DB 状态,消息幂等 |
| claim task 后、dispatch 前死 | task lease/queued lease 到期后重新派发 |
| 推进 workflow completion 前死 | 新 scheduler 重算 workflow completion |
| 扫描 timeout 一半死 | 新 scanner CAS 接着扫 |

这里的关键是 outbox:

```text
状态变化和待发布事件同事务落库。
```

否则 scheduler 可能死在:

```text
DB 状态更新成功
MQ 消息发送失败
```

导致下游永远不动。

## 多 Scheduler 高可用

多 scheduler 有两种常见模式。

### 1. Active-passive leader

只有 leader 负责调度。

```text
scheduler_leader:
  scheduler_id
  epoch
  lease_until
```

leader 定期续租。

如果 leader 死亡:

```text
lease_until 过期
standby scheduler CAS 抢 leader
epoch + 1
新 leader 开始调度
```

所有 scheduler 写状态时都带 epoch:

```sql
UPDATE task_instance
SET status = 'QUEUED',
    scheduler_epoch = :epoch
WHERE id = :task_id
  AND status = 'READY'
  AND version = :version;
```

旧 leader 如果恢复,发现自己 epoch 过期,必须停止写入。

### 2. Active-active 多实例

多个 scheduler 同时扫描和推进。

这要求所有关键动作都可并发:

```text
claim READY 用 CAS / SELECT FOR UPDATE SKIP LOCKED
生成 child task 用 unique(run_uuid, order_id)
发布事件用 outbox idempotency key
workflow completion 用聚合条件 + CAS
resource quota 用中心 token 或原子计数
```

active-active 不怕某个 scheduler 死,但更怕并发竞争。

所以它的核心不是 leader election,而是:

```text
每个状态推进都是幂等且可竞争失败的。
```

## Scheduler 脑裂怎么办

脑裂是:

```text
两个 scheduler 都以为自己是 leader。
```

风险:

```text
重复 dispatch
重复生成 dynamic child
重复发布下游事件
quota 被重复占用
workflow 被错误标终态
```

防护:

| 风险 | 防护 |
|---|---|
| 双 leader 写状态 | leader epoch / fencing token |
| 重复 claim | CAS by status/version |
| 重复 child | unique(run_uuid, order_id) |
| 重复事件 | outbox event idempotency key |
| 重复外部 submit | task idempotency_key |
| quota 超扣 | resource token CAS / lease |

结论:

```text
不要相信“只有一个 scheduler”这个运行时事实。
要让存储层和状态机允许竞争,并拒绝过期 writer。
```

## 内嵌式 EMF 进程死了怎么办

EMF 当前模型里,一个 worker 进程内部可能同时包含:

```text
PubSubMessageProducer
WorkerMessageAppender
DagManager / DagContext
ParallelMessageConsumer
MessageHandler
StratusCommandExecutor
```

所以一个进程死掉,可能同时意味着:

```text
本地 scheduler 死了
本地 worker 死了
本地内存 DAG 丢了
本地 in-flight command 丢了
```

这比“独立 scheduler + worker pool”更需要持久化边界。

### 必须能重建三类东西

#### 1. DAG definition

来源:

```text
GCS DAG file
GCS file metadata
DAG version
```

用来回答:

```text
这张图本来长什么样?
每个 order_id 的 parents 是谁?
command policy 是什么?
owner team 是谁?
```

#### 2. DAG instance state

来源:

```text
task_instance
workflow_instance
state_transition_log
message_lineage
```

用来回答:

```text
哪些节点已经成功?
哪些失败?
哪些正在运行?
哪些 dynamic child 已经生成?
```

#### 3. External reality

来源:

```text
external_call_ledger
external_job_id
GCS output manifest
callback inbox
```

用来回答:

```text
真实世界里副作用发生了吗?
产物存在吗?
外部 job 到底成功还是失败?
```

如果这三类信息都能重建,进程死了只是一次恢复事件。

如果其中任何一类只在内存中,进程死就是数据丢失。

## Scheduler 和 Worker 都死了怎么办

如果控制面和执行面都死了:

```text
没有新任务派发
没有 worker 续租
没有 scanner 运行
外部 job 可能继续执行
callback 可能堆积或失败
```

恢复时建议进入 recovery mode。

### Recovery mode

```text
1. 启动 DB / queue / object storage 连接检查。
2. 恢复 scheduler,但暂时不派发新任务。
3. 恢复 worker registry,等待 worker pool heartbeat 稳定。
4. 读取 GCS DAG metadata 和 DB 状态,重建 run 视图。
5. 处理 outbox/inbox backlog。
6. 对 RUNNING / RUNNING_EXTERNAL / CANCELLING 做 reconcile。
7. 处理 expired lease,但限速。
8. 逐步打开 dispatch。
9. 观察 retry storm、external API error、zombie count。
```

可以把 dispatch gate 设计成:

```text
global_dispatch_enabled = false
tenant_dispatch_enabled = false
command_dispatch_enabled = false
```

recovery 完成后逐步打开:

```text
先 light command
再 idempotent command
再 external async command
最后 side-effect write command
```

## 队列语义下的死亡处理

如果使用 MQ,还要考虑 worker 死在消息消费过程中。

### 1. Worker 收到消息前死

消息还在队列里,没有影响。

### 2. Worker 收到消息后、claim 前死

如果消息有 visibility timeout,超时后会重新投递。

worker 消费时仍要查 DB:

```text
只有 task.status 允许执行,才 claim。
```

### 3. Worker claim 后、ack 前死

消息可能重新投递。

但是 task 已经是 RUNNING。

新的 worker 消费到重复消息时应该:

```text
发现 status != READY
不执行
ack / drop duplicate
```

### 4. Worker 完成任务后、ack 前死

消息也可能重新投递。

因为 task 已经 SUCCESS,重复消息应该被 inbox 或状态机忽略。

所以队列层面一定要接受:

```text
at-least-once delivery
```

平台层面用:

```text
state CAS
inbox dedup
idempotency key
```

抵消重复投递。

## 资源 token 怎么恢复

如果有中心资源池:

```text
databricks_concurrency_token
tenant_running_slot
worker_execution_token
```

worker 死后 token 也可能不释放。

所以 resource token 也要有 lease:

```text
token_id
holder_task_id
holder_worker_id
lease_until
status
```

恢复扫描:

```sql
SELECT *
FROM resource_token
WHERE status = 'HELD'
  AND lease_until < now() - interval '60 seconds';
```

处理:

```text
如果 task 已终态 -> release token
如果 task 正在 RECOVERING -> 暂不释放或转 recovery_owner
如果 external job 仍 running -> token 是否继续占用取决于资源语义
如果 worker dead 且 no external running -> release token
```

不要只恢复 task,忘了恢复 token。

否则系统会出现:

```text
没有任务在跑,但 quota 一直满。
```

## 可观测性

需要能回答:

```text
谁死了?
什么时候死的?
死前在处理哪些 task?
哪些 task 已经被恢复?
哪些 task 仍然需要人工?
scheduler 是否完成 takeover?
是否发生重复 dispatch?
恢复速度是否被限流?
```

建议指标:

```text
emf.worker.heartbeat_stale_count{pool}
emf.worker.dead_total{pool}
emf.scheduler.leader_takeover_total
emf.scheduler.heartbeat_stale
emf.scheduler.epoch_conflict_total
emf.recovery.mode_active
emf.recovery.tasks_scanned_total
emf.recovery.tasks_reconciled_total
emf.recovery.tasks_retried_total
emf.recovery.throttled_total
emf.queue.duplicate_message_total
emf.resource_token.expired_total
```

关键告警:

```text
all workers in pool stale
scheduler leader lease expired and no takeover
recovery mode active too long
expired lease count spike
retry storm detected
external reconcile failures spike
resource token leaked
```

## Jira / LLM 自动诊断

当 worker 或 scheduler 死亡导致故障升级时,ticket 里应该包含:

```text
故障类型: worker_dead / worker_pool_down / scheduler_dead / scheduler_split_brain / full_control_plane_down
影响范围: tenant / workflow / command / worker_pool
开始时间和发现时间
stale heartbeat 列表
expired lease task 数量
RUNNING / QUEUED / READY backlog
external job 状态分布
recovery actions 已执行哪些
当前 dispatch gate 是否关闭
下一步建议
owner_team / jira_board / component
```

LLM 可以把这些结构化证据整理成:

```text
事故摘要
当前进度
疑似根因
受影响 workflow
推荐 SOP
应该发给哪个 team
```

但是否恢复 dispatch、是否 retry side-effect command,仍然应该由规则化 recovery executor 或人工确认决定。

## 测试用例

至少要做这些故障注入:

```text
worker claim 前 crash
worker claim 后 crash
worker submit external job 后、写 external_job_id 前 crash
worker 写 output 后、mark SUCCESS 前 crash
worker lease 过期后迟到写 SUCCESS
所有 worker pool 同时停止
scheduler 标 QUEUED 后、outbox publish 前 crash
scheduler publish 后 crash,消息重复投递
scheduler leader crash,standby takeover
两个 scheduler 同时认为自己是 leader
dynamic child 写一半时 scheduler crash
resource token held 后 worker crash
scheduler 和 worker 同时重启
GCS DAG metadata 可读但 DB 有部分状态缺失
```

每个测试要验证:

```text
任务不会永久卡住
不会重复产生外部副作用
旧 worker 不能覆盖新状态
新 scheduler 能接管
outbox/inbox 能补偿重复或丢失事件
资源 token 能释放
恢复过程有 audit 和 metrics
```

## 面试表达

```text
worker 死和 scheduler 死要分开处理。worker 死影响正在执行的任务,我会用 worker heartbeat、task lease、attempt 和 lease_token 发现并隔离旧 owner,再通过 external_job_id、idempotency_key、output_ref 做对账,决定补 success、retry、fail 或人工处理。scheduler 死影响调度推进,所以 scheduler 必须无本地关键状态,状态落 DB/GCS/outbox,多实例通过 leader lease 或 active-active CAS 接管。恢复时不能一启动就盲目重跑,要先进入 recovery mode,重建 DAG、处理 outbox/inbox、reconcile 外部状态,再限速恢复 dispatch。这样进程死亡只是可恢复事件,不会变成任务丢失或重复执行事故。
```

## 一句话总结

```text
Worker 死靠 lease 和 zombie recovery 收敛执行状态;
Scheduler 死靠 durable state、leader fencing 和重新扫描恢复调度状态。
```
