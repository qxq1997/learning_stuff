# 04 · 内部 DAG 模型与调度执行引擎

## 4.0 本章导读

第 3 章结束时,Loader 已经完成了这些事情:

- 固定 GCS `generation` 读取 DAG 文件内容。
- 读取并快照 GCS object metadata。
- 把 JSON 节点 normalize 成 `NodeSpec`。
- 根据 `parents` 编译出 DAG graph。
- 校验 command 和 parameters。
- 创建 `RunRecord` 和一批 `StepRunRecord`。

从本章开始,EMF 进入真正的执行阶段:

```text
LOADED / RUNNING Run
        ↓
Scheduler 找 ready step
        ↓
解析 parameters template
        ↓
提交到 ThreadPoolExecutor
        ↓
Command Runner 执行 local / dbt / sidecar command
        ↓
StepRun 回写状态和 output
        ↓
Scheduler 推进下游节点
```

本章要回答五个问题:

1. 内部 DAG graph 和 Run / Step 状态应该怎么建模。
2. Scheduler 如何从 `parents` 判断哪些 Step ready。
3. 为什么执行模型是"全局线程池 + Run 级并发闸门",而不是每个 Run 一个线程池。
4. 失败、重试、超时、取消和恢复分别怎么处理。
5. 如果从单 Pod 扩到多 Pod,Run ownership 和 lease 应该怎么演进。

---

## 4.1 内部模型:不要把 JSON dict 一路传到底

Loader 读到的 JSON 只是外部协议。Scheduler 不应该拿着原始 dict 调度,而应该面对已经 normalize / validate 过的内部对象。

推荐内部对象分三层:

```text
DagSpec      静态图定义,来自 DAG content
RunRecord    一次运行实例,来自 GCS object generation
StepRun      某个节点在某次 Run 里的执行状态
```

### 4.1.1 `DagSpec`

`DagSpec` 是一份 DAG 文件的编译结果:

```python
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class NodeSpec:
    id: str
    command: str
    parents: tuple[str, ...]
    parameters_template: dict[str, Any]


@dataclass(frozen=True)
class DagGraph:
    nodes_by_id: dict[str, NodeSpec]
    parents_by_node: dict[str, set[str]]
    children_by_node: dict[str, set[str]]
    topological_order: tuple[str, ...]


@dataclass(frozen=True)
class CompiledDag:
    graph: DagGraph
    command_bindings: dict[str, "CommandBinding"]
```

这里有两个点:

- `parents_by_node` 用来判断当前节点是否 ready。
- `children_by_node` 用来在某个 Step 结束后快速推进下游。

不要每次调度都扫描所有节点再重新算依赖。小 DAG 可以扫,但一旦一个 DAG 里有几百个节点,扫描式调度会越来越吵。

### 4.1.2 `RunRecord`

`RunRecord` 是一次具体执行:

```json
{
  "run_id": "run_123",
  "status": "RUNNING",
  "pipeline_name": "daily_export",
  "owner": "growth-analytics",
  "environment": "prod",
  "source": {
    "bucket": "team-a-emf",
    "object": "dags/prod/daily_export.json",
    "generation": "1713840000000000",
    "metageneration": "3",
    "sha256": "..."
  },
  "object_metadata_snapshot": {
    "pipeline-name": "daily_export",
    "owner": "growth-analytics",
    "environment": "prod"
  },
  "runtime": {
    "emf_git_sha": "abc1234",
    "image_digest": "sha256:..."
  },
  "created_at": "2026-04-23T10:00:00Z",
  "started_at": "2026-04-23T10:00:02Z",
  "finished_at": null
}
```

Run 是用户、观测、审计看到的一等对象。Step 只是 Run 内部的节点状态。

### 4.1.3 `StepRunRecord`

`StepRunRecord` 是某个 Node 在某次 Run 里的运行实例:

```json
{
  "run_id": "run_123",
  "step_id": "export_orders",
  "command": "ExportToGcs",
  "parents": [],
  "status": "WAITING",
  "attempt": 0,
  "max_attempts": 3,
  "next_attempt_at": null,
  "started_at": null,
  "finished_at": null,
  "parameters_snapshot": null,
  "output": null,
  "error": null,
  "version": 1
}
```

`version` 是为了并发安全。多线程同时推进状态时,State Store 需要乐观并发控制:

```text
update step set status = RUNNING where step_id = ? and version = old_version
```

如果更新失败,说明别的线程已经抢先推进了这个 Step,当前 Scheduler 轮次应该放弃。

---

## 4.2 Run 状态机

Run 状态建议从装载期和执行期合在一起看:

```text
PENDING_LOAD
  ├── LOAD_RETRYING
  ├── LOAD_FAILED
  └── RUNNING
        ├── SUCCEEDED
        ├── FAILED
        ├── CANCELLED
        └── INTERRUPTED
```

状态含义:

| 状态 | 含义 |
|------|------|
| `PENDING_LOAD` | Ingestor 已接住 GCS 事件,Loader 还没完成 |
| `LOAD_RETRYING` | Loader 遇到临时错误,等待重试 |
| `LOAD_FAILED` | DAG 内容或 metadata 校验失败,不会执行 |
| `RUNNING` | StepRun 已创建,正在调度/执行 |
| `SUCCEEDED` | 所有必须执行的 Step 都成功 |
| `FAILED` | 至少一个 Step 最终失败,且失败不可恢复 |
| `CANCELLED` | 用户或平台主动取消 |
| `INTERRUPTED` | Pod 停机 / lease 丢失等导致运行中断,等待恢复策略处理 |

### 4.2.1 为什么 Run 不应该只有 success / failed

如果只有:

```text
RUNNING -> SUCCESS / FAILED
```

排障时会非常痛苦。比如:

- JSON 写错导致没跑,和 Step 执行失败,都叫 failed。
- 用户主动取消,和系统崩溃中断,都叫 failed。
- Loader 临时失败正在重试,也被误认为执行失败。

Run 状态越清楚,告警和恢复越简单。`LOAD_FAILED` 通知 DAG 作者;`FAILED` 通知流程 owner;`INTERRUPTED` 通知平台维护者,这三者不是同一种事故。

---

## 4.3 Step 状态机

Step 状态机比 Run 更细:

```text
WAITING
  ├── READY
  │     └── RUNNING
  │            ├── SUCCEEDED
  │            ├── RETRY_WAITING
  │            ├── FAILED
  │            ├── TIMED_OUT
  │            └── INTERRUPTED
  ├── CANCELLED_BY_PARENT
  └── CANCELLED
```

状态含义:

| 状态 | 含义 |
|------|------|
| `WAITING` | 等 parents 完成 |
| `READY` | parents 已满足,可被提交执行 |
| `RUNNING` | 已进入 worker 线程执行 |
| `RETRY_WAITING` | 本次 attempt 失败,等待下一次重试时间 |
| `SUCCEEDED` | 成功完成,output 已持久化 |
| `FAILED` | 重试耗尽或不可重试错误 |
| `TIMED_OUT` | 超时终止或被标记超时 |
| `INTERRUPTED` | Pod 停机/进程崩溃导致状态不确定 |
| `CANCELLED_BY_PARENT` | 上游失败导致本节点不再执行 |
| `CANCELLED` | 用户/平台主动取消 |

### 4.3.1 `READY` 要不要持久化

可以有两种做法:

1. `READY` 只在内存队列里出现,State Store 里仍然是 `WAITING`。
2. `READY` 持久化到 State Store。

推荐第一版可以不强制持久化 `READY`,因为它可以从状态推导:

```text
step.status == WAITING and all(parent.status == SUCCEEDED)
```

但如果要做多 Pod 调度,或者 UI 想展示"已就绪但还没拿到线程",那持久化 `READY` 会更清晰。

### 4.3.2 不要把没跑的下游标成 FAILED

如果:

```text
a -> b -> c
```

`a` 失败,`b` 和 `c` 应该是:

```text
a FAILED
b CANCELLED_BY_PARENT
c CANCELLED_BY_PARENT
```

不要把 b/c 标成 `FAILED`。它们不是自己失败,只是依赖条件不满足。这个区别对用户很重要:真正要修的是 `a`,不是整条链上的每个节点。

---

## 4.4 Ready 判断:从 parents 到可执行节点

最朴素的 ready 判断:

```python
def is_ready(step_id: str, state: RunState, graph: DagGraph) -> bool:
    step = state.steps[step_id]
    if step.status != "WAITING":
        return False

    parents = graph.parents_by_node[step_id]
    return all(state.steps[parent].status == "SUCCEEDED" for parent in parents)
```

Scheduler 一轮可以这样做:

```python
def find_ready_steps(run: RunState, graph: DagGraph) -> list[str]:
    ready = []
    for step_id in graph.topological_order:
        if is_ready(step_id, run, graph):
            ready.append(step_id)
    return ready
```

这对几十个节点的 DAG 足够。要优化时,可以维护 `remaining_parent_count`:

```python
remaining_parent_count = {
    step_id: len(parents)
    for step_id, parents in graph.parents_by_node.items()
}
```

每当一个 Step 成功,只更新它的 children:

```python
for child in graph.children_by_node[finished_step_id]:
    remaining_parent_count[child] -= 1
    if remaining_parent_count[child] == 0:
        mark_ready(child)
```

### 4.4.1 为什么不靠参数引用自动补边

第 2 章已经定了:`parents` 是调度图的权威来源。即使 `parameters` 里引用了 `${abc.output.gcs_uri}`,也不建议 Scheduler 自动加边。

正确策略:

- Loader 发现参数引用了 parent output,但 `parents` 没包含对应节点 -> `LOAD_FAILED` 或至少强 warning。
- Scheduler 只看 `parents`。

这样运行时图和用户写出来的图一致,排障更容易。

---

## 4.5 Scheduler 主循环

在单 Pod 模型里,Scheduler 可以是一个循环:

```python
def scheduler_loop():
    while not shutting_down:
        runs = state_store.list_active_runs(limit=100)
        for run in runs:
            schedule_one_run(run)
        sleep(SCHEDULER_TICK_SECONDS)
```

`schedule_one_run` 做三件事:

```python
def schedule_one_run(run: RunRecord):
    if run.status != "RUNNING":
        return

    ready_steps = state_store.find_ready_steps(run.id)

    for step in ready_steps:
        if not run_limiter.try_acquire(run.id):
            break
        if not global_limiter.try_acquire():
            run_limiter.release(run.id)
            break

        claimed = state_store.claim_step(
            run_id=run.id,
            step_id=step.id,
            from_status="WAITING",
            to_status="RUNNING",
        )
        if not claimed:
            run_limiter.release(run.id)
            global_limiter.release()
            continue

        executor.submit(run_step_with_guards, run.id, step.id)
```

注意顺序:

1. 先确认并发闸门还有容量。
2. 再用 State Store 原子 claim Step。
3. claim 成功后才提交线程池。
4. worker 结束后释放闸门。

如果先 submit 再 claim,重复调度时可能出现两个线程跑同一个 Step。

---

## 4.6 并发模型:全局线程池 + Run 级 semaphore

第 1 章已经提到 EMF 是"多 DAG 也用多线程执行"。推荐的实现不是"每个 Run 一个线程池",而是:

```text
一个全局 ThreadPoolExecutor
        +
每个 Run 一个并发 semaphore
        +
可选的 command-kind semaphore
```

### 4.6.1 为什么不用每 Run 一个线程池

每 Run 一个池看起来隔离好,但问题很多:

- Run 数一多,线程数膨胀。
- 大量空闲线程浪费内存。
- 总体并发很难控制。
- 线程池生命周期要跟 Run 生命周期绑定,复杂度高。

全局线程池更适合团队级部署:

```python
executor = ThreadPoolExecutor(max_workers=32)
```

再用每 Run semaphore 控制单条 DAG 的并行度:

```python
run_semaphore[run_id] = Semaphore(max_parallel_steps_per_run)
```

这样既共享资源,又避免一个大 DAG 吃光所有线程。

### 4.6.2 command-kind semaphore

除了全局和 Run 级并发,还建议对下游资源加闸门:

```text
BigQuery command max concurrency: 8
Sidecar command max concurrency: 16
DBT subprocess max concurrency: 2
```

原因是线程池容量不是唯一瓶颈。真正会被打爆的往往是:

- BigQuery slots / jobs。
- Sidecar QPS。
- 第三方 API 配额。
- 本地 Pod CPU / memory。
- dbt subprocess 数量。

Command Registry 可以声明 command kind:

```json
{
  "name": "ExportToGcs",
  "kind": "local",
  "resource_group": "bigquery"
}
```

Scheduler 或 Command Runner 根据 `resource_group` 获取对应 semaphore。

---

## 4.7 Worker 执行边界

worker 线程的顶层必须兜住所有异常:

```python
def run_step_with_guards(run_id: str, step_id: str) -> None:
    try:
        run_step(run_id, step_id)
    except Exception as exc:
        state_store.mark_step_failed(
            run_id=run_id,
            step_id=step_id,
            error=to_error_record(exc),
        )
    finally:
        release_limiters(run_id, step_id)
        wake_scheduler(run_id)
```

`run_step` 的核心流程:

```python
def run_step(run_id: str, step_id: str) -> None:
    run = state_store.get_run(run_id)
    step = state_store.get_step(run_id, step_id)
    node = compiled_dag.get_node(step_id)

    parameters = param_resolver.resolve(
        template=node.parameters_template,
        run=run,
        parent_outputs=state_store.get_parent_outputs(run_id, step_id),
    )

    state_store.save_parameters_snapshot(run_id, step_id, parameters)

    command = command_registry.get(node.command)
    output = command_runner.run(
        command=command,
        parameters=parameters,
        context=build_command_context(run, step),
    )

    validate_output(command.output_schema, output)
    state_store.mark_step_succeeded(run_id, step_id, output)
```

这里有几个硬边界:

- 参数解析失败 -> Step `FAILED`,不是进程崩溃。
- command 抛异常 -> Step `FAILED` 或 `RETRY_WAITING`,不是 Run 直接崩。
- output schema 不合法 -> Step `FAILED`,因为下游不能安全消费。
- worker 顶层不能让异常冒出线程池。

---

## 4.8 参数解析与 Context

虽然 DAG DSL 很轻,但 command 执行时需要上下文:

```python
@dataclass(frozen=True)
class CommandContext:
    run_id: str
    step_id: str
    pipeline_name: str
    owner: str
    environment: str
    source_bucket: str
    source_object: str
    source_generation: str
    attempt: int
    idempotency_key: str
```

`parameters` 是用户传的入参,`context` 是平台注入的运行时信息。两者不要混在一起。

### 4.8.1 为什么需要 idempotency key

任何 command 都要假设自己可能被重复执行:

- worker 执行成功,但写 State Store 超时。
- Pod 崩溃后恢复,不确定外部副作用是否完成。
- 超时后重试。
- Pub/Sub / Scheduler 重复触发边界 bug。

推荐 idempotency key:

```text
run_id + ":" + step_id + ":" + attempt
```

但对有副作用的 create/write command,更稳的是:

```text
run_id + ":" + step_id
```

这样重试同一个 Step 不会创建多份外部资源。具体使用哪个,应该由 command schema 声明。

---

## 4.9 重试策略

当前 DAG DSL 没有 `retry` 字段,所以重试策略应该来自:

1. Command Registry 默认策略。
2. 部署级默认策略。
3. 少数未来可选的 Step 字段。

推荐判断顺序:

```python
if not error.retryable:
    mark_failed()
elif step.attempt >= max_attempts:
    mark_failed()
else:
    mark_retry_waiting(next_attempt_at=compute_backoff())
```

`RETRY_WAITING` 状态:

```json
{
  "status": "RETRY_WAITING",
  "attempt": 1,
  "next_attempt_at": "2026-04-23T10:05:00Z",
  "last_error": {
    "code": "RATE_LIMITED",
    "retryable": true
  }
}
```

Scheduler 扫描时,把到期的 retry step 重新变成可执行:

```python
if step.status == "RETRY_WAITING" and step.next_attempt_at <= now:
    claim_step_for_retry(step)
```

### 4.9.1 不要重试参数错误

这些错误不应该重试:

- parameters 缺字段。
- GCS URI 格式错。
- command 不存在。
- output schema 不匹配。

它们属于确定性错误,重试只会浪费资源。

适合重试的是:

- GCS 读写超时。
- BigQuery transient error。
- HTTP 429 / 503。
- Sidecar 临时不可用。

### 4.9.2 `SIDE_EFFECT_UNKNOWN`

最危险的错误是:

```text
请求发给外部系统了,但我们不知道对方是否成功。
```

比如 Sidecar 调第三方 API 超时。此时不能简单重试,除非 command 提供:

- 幂等 key。
- 外部查询接口。
- 去重表。
- 可补偿动作。

这类错误建议标为:

```json
{
  "code": "SIDE_EFFECT_UNKNOWN",
  "retryable": false,
  "requires_manual_check": true
}
```

第 5 / 6 / 8 章会继续展开命令幂等和 Sidecar 语义。

---

## 4.10 超时不是杀线程这么简单

Python 线程不能被安全强杀。这个事实会直接影响 EMF 的超时设计。

不同 command kind 的超时处理不同:

| command kind | 超时处理 |
|--------------|----------|
| local Python | 只能依赖 SDK timeout / 协作式检查 |
| dbt subprocess | 可以 terminate / kill 子进程 |
| sidecar HTTP | HTTP client timeout + Sidecar 自身 timeout |

所以 Scheduler 层的 timeout 不能幻想成:

```python
future.cancel()
```

`future.cancel()` 对已经运行的线程通常无效。

### 4.10.1 推荐做法

- 所有 I/O SDK 调用必须设置 timeout。
- CommandContext 提供 `deadline`。
- 长循环 command 必须定期检查 `context.is_cancelled()`。
- dbt subprocess 必须记录 pid,超时后 terminate。
- Sidecar endpoint 必须接受 request timeout / deadline。

Step 超时后的状态要谨慎:

```text
TIMED_OUT_RETRYABLE
TIMED_OUT_UNKNOWN
```

如果 command 能证明没有产生副作用,可以重试;否则进入人工检查或失败。

---

## 4.11 失败传播与 Run 收尾

当一个 Step 终态后,Scheduler 要推进两件事:

1. 如果成功,检查 children 是否 ready。
2. 如果失败,取消依赖它的下游。

### 4.11.1 成功推进

```python
def on_step_succeeded(run_id: str, step_id: str):
    for child in graph.children_by_node[step_id]:
        if all_parents_succeeded(run_id, child):
            mark_waiting_child_ready(child)
```

### 4.11.2 失败传播

```python
def cancel_descendants(run_id: str, failed_step_id: str):
    queue = list(graph.children_by_node[failed_step_id])
    while queue:
        child = queue.pop()
        if step_status(child) in TERMINAL_STATES:
            continue
        mark_cancelled_by_parent(child, failed_parent=failed_step_id)
        queue.extend(graph.children_by_node[child])
```

注意只取消依赖失败分支的下游。无关分支继续跑。

### 4.11.3 Run 终态判断

每次 Step 进入终态后,检查 Run 是否结束:

```python
terminal = {"SUCCEEDED", "FAILED", "TIMED_OUT", "CANCELLED_BY_PARENT", "CANCELLED", "SKIPPED"}

if all(step.status in terminal for step in steps):
    if any(step.status in {"FAILED", "TIMED_OUT"} for step in steps):
        run.status = "FAILED"
    elif any(step.status == "CANCELLED" for step in steps):
        run.status = "CANCELLED"
    elif any(step.status == "CANCELLED_BY_PARENT" for step in steps):
        run.status = "FAILED"
    else:
        run.status = "SUCCEEDED"
```

`CANCELLED_BY_PARENT` 通常意味着上游失败,所以 Run 应该是 `FAILED`。但 UI 可以显示"真正失败节点只有 1 个,其余是被上游取消"。

---

## 4.12 恢复:进程挂了之后怎么办

长任务系统真正的分水岭是恢复。Scheduler 不能假设进程永远活着。

### 4.12.1 单 Pod 重启

如果只有一个 Scheduler Pod,重启后可以这样恢复:

1. 扫描 `RUNNING` Run。
2. 找出 `RUNNING` Step。
3. 根据 command kind 判断是否可查询外部状态。
4. 无法确认的 Step 标记 `INTERRUPTED` 或 `FAILED_NEEDS_REVIEW`。
5. `WAITING` / `RETRY_WAITING` Step 重新纳入调度。

为什么不能把旧的 `RUNNING` Step 直接重新跑?

因为旧线程可能已经在崩溃前完成了外部副作用,只是没来得及写 State Store。盲目重跑会重复导出、重复写第三方系统、重复通知。

### 4.12.2 Step 恢复依赖 command 幂等语义

Command Registry 应该声明:

```json
{
  "recovery": {
    "external_status_query": true,
    "idempotent_by": "run_step_id"
  }
}
```

如果 command 能查询外部 job:

- BigQuery job id 已知 -> 查 job 是否完成。
- GCS destination 已知 -> 查 object 是否存在并校验 checksum。
- Sidecar request id 已知 -> 查 vendor 操作状态。

如果查不到,就不能假装恢复成功。

### 4.12.3 interrupted 的用户表达

`INTERRUPTED` 不应该被悄悄藏起来。它表达的是:

> 平台在执行过程中失去了对这个 Step 的确定性。

这类状态应该进入告警或人工检查,而不是简单标成 failed。失败是业务/命令错误;中断是平台可恢复性问题。

---

## 4.13 多 Pod 扩展:Run ownership 与 lease

单 Pod 多线程是合理起点,但未来一定会遇到上限。扩到多 Pod 时,最大的问题是:

> 两个 Scheduler Pod 不能同时调度同一个 Run 的同一个 Step。

推荐引入 Run lease:

```json
{
  "run_id": "run_123",
  "owner_pod": "emf-scheduler-7f8c9",
  "lease_until": "2026-04-23T10:05:00Z"
}
```

Scheduler Pod 工作前先抢 lease:

```python
def acquire_run_lease(run_id, pod_id):
    return state_store.compare_and_set(
        condition="lease_until < now or owner_pod == pod_id",
        update={
            "owner_pod": pod_id,
            "lease_until": now + LEASE_TTL,
        },
    )
```

只有 lease holder 可以调度该 Run。

### 4.13.1 lease 心跳

长 Run 需要定期续约:

```text
every 10s: extend lease_until by 30s
```

如果 Pod 挂了,lease 过期,另一个 Pod 才能接管。

### 4.13.2 接管时处理 RUNNING Step

新 Pod 接管时,旧 Pod 的线程已经不存在或不可控。所有旧 owner 下的 `RUNNING` Step 都需要进入恢复流程:

```text
RUNNING -> INTERRUPTED / RECOVERING
```

不能直接假设它们失败,也不能直接重跑。

---

## 4.14 Backfill 不是特殊调度器

如果未来要支持回填,不要为 backfill 写另一套执行引擎。

Backfill 本质是创建多条 Run:

```text
daily_export business_date=2026-04-20
daily_export business_date=2026-04-21
daily_export business_date=2026-04-22
```

每条 Run 仍然使用同一套:

- Loader / compiled graph。
- StepRun 状态机。
- Scheduler ready 判断。
- ThreadPoolExecutor。
- 重试 / 失败传播。

Backfill 额外需要的是:

- 生成多组运行参数。
- 控制 backfill Run 总并发。
- 避免覆盖同一 destination。
- UI 上按 batch 分组展示。

它不应该绕过 Scheduler,否则执行语义会分裂。

---

## 4.15 观测:Scheduler 要能回答"为什么没跑"

调度系统最常见的排障问题不是"为什么失败",而是:

> 为什么这个 Step 还没开始?

Scheduler 必须能回答:

- 它还在等哪些 parents?
- 它 ready 了但没有线程吗?
- 它被 Run 级并发限制卡住了吗?
- 它被 command-kind semaphore 卡住了吗?
- 它在 `RETRY_WAITING` 等下一次重试吗?
- 它因为上游失败被取消了吗?

推荐指标:

| 指标 | 含义 |
|------|------|
| `emf.scheduler.active_runs` | 当前 RUNNING Run 数 |
| `emf.scheduler.ready_steps` | ready 但未执行 Step 数 |
| `emf.scheduler.running_steps` | 正在执行 Step 数 |
| `emf.scheduler.queue_wait_ms` | Step 从 ready 到 running 的等待时间 |
| `emf.step.duration_ms` | Step 执行耗时 |
| `emf.step.retry_total` | Step 重试次数 |
| `emf.step.cancelled_by_parent_total` | 因上游失败取消的 Step 数 |

低基数 attributes:

- `pipeline_name`
- `environment`
- `command`
- `command_kind`
- `status`
- `error_code`

高基数字段如 `run_id`、`step_id`、GCS path 进 trace/log,不要直接进 metric label。

---

## 4.16 本章关键结论

1. **Scheduler 面对的是内部 `CompiledDag + RunRecord + StepRunRecord`,不是原始 JSON dict**。
2. **Run 和 Step 要有明确状态机**。`LOAD_FAILED`、`FAILED`、`CANCELLED_BY_PARENT`、`INTERRUPTED` 代表不同失败域,不能混成一个 failed。
3. **ready 判断只看 `parents`**。参数引用可以校验,但不应该在运行时偷偷补边。
4. **推荐执行模型是全局线程池 + Run 级 semaphore + 可选 command-kind semaphore**。这样既共享资源,又避免单个 Run 或单类命令吃光容量。
5. **State Store 必须支持原子 claim / 乐观并发**,否则多线程下会重复执行同一个 Step。
6. **worker 顶层必须兜住异常**,任何 command 错误都应该变成 Step 状态,不能冒泡打挂 Scheduler。
7. **重试要基于错误语义和 command 幂等声明**,不能所有失败都重试。
8. **超时不能靠杀 Python 线程解决**。local/dbt/sidecar 三类 command 要有各自的 timeout 机制。
9. **恢复能力取决于 command 的幂等和外部状态查询能力**。没有这两者,进程崩溃后的 RUNNING Step 只能进入 `INTERRUPTED` 或人工检查。
10. **多 Pod 扩展的核心是 Run ownership / lease**,不是简单把 Deployment replicas 调大。

---

## 本章未定的问题(需要和真实代码校准)

- 当前 Scheduler 是单循环扫描 active runs,还是事件驱动地由 Step 完成回调唤醒?
- State Store 是 Firestore、Postgres、Redis,还是本地文件/内存?是否支持 CAS / transaction?
- 线程池当前是全局共享、每 Run 独立,还是已经有 Run 级并发限制?
- command 是否有 registry schema 来声明 retryable error、resource_group、idempotency 和 recovery?
- 当前如何处理 Python local command 超时?是否所有 SDK 调用都设置 timeout?
- Pod 重启后,旧 `RUNNING` Step 当前如何恢复或标记?
- 是否已经需要多 Pod Scheduler?如果需要,Run lease 的 owner 和 TTL 存在哪里?
