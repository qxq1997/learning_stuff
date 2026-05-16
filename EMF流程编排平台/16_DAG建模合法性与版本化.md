# 16 DAG 建模合法性与版本化

## 为什么建模是第一层难点

DAG 引擎最容易被低估的部分是“建模”。

小 demo 里,workflow 只是:

```text
A -> B -> D
A -> C -> D
```

但生产里,你需要回答:

```text
这个 DAG 合法吗?
节点代表定义还是实例?
这次运行绑定的是哪个版本?
条件分支怎么表达?
未选择的分支是什么状态?
子 workflow 是同一张图还是另一张图?
动态节点加入后还能保证无环吗?
```

建模一旦模糊,后面的状态机、调度器、重试、人工干预都会被拖下水。

## 定义和实例必须拆开

最重要的边界是:

```text
Definition 是模板;
Instance 是某次真实运行。
```

推荐模型:

| 概念 | 含义 | 例子 |
|---|---|---|
| Workflow Definition | 工作流逻辑定义 | 每日客户数据同步 |
| Workflow Definition Version | 某个不可变版本 | v12: A -> B -> C |
| Workflow Instance | 某一次运行 | 2026-05-13 这次同步 |
| Task Definition | 节点模板 | 同步客户表 |
| Task Instance | 某次运行中的节点实例 | 今天这次同步客户表 |
| Execution Context | 本次运行上下文 | 参数、变量、trace、tenant、secrets 引用 |

如果把 definition 和 instance 混在一起,会出现非常典型的生产问题:

| 问题 | 表现 |
|---|---|
| 旧实例被新定义影响 | 昨天启动的 run 今天按新 DAG 跑 |
| 重跑不可解释 | 失败节点重跑时节点集合变了 |
| 审计不可还原 | 查不到当时到底执行的是哪个 DAG |
| 参数被覆盖 | 新配置影响历史运行 |
| UI 展示混乱 | 同一个 run 前后看到的图不一致 |

原则:

```text
每次 workflow instance 必须绑定不可变 definition version。
```

也就是说,用户今天修改 DAG,只能影响新启动的 run,不能悄悄改变已经在跑或已经结束的 run。

## DAG 合法性校验

DAG 提交或运行前至少要校验:

| 校验项 | 为什么重要 |
|---|---|
| 是否有环 | 有环就没有拓扑顺序,调度会死锁 |
| 是否有重复节点 key | 依赖匹配会歧义 |
| 是否依赖不存在的节点 | 下游永远不会 ready |
| 是否有无法到达节点 | 定义里存在永远不会被触发的任务 |
| 是否有空 DAG | workflow 没有可执行内容 |
| 是否有非法节点类型 | scheduler / executor 无法处理 |
| 是否有非法 trigger rule | join 语义无法判断 |
| 是否有参数缺失 | 运行到执行阶段才失败 |

最基础的校验方式:

```text
build adjacency list
build indegree table
run topological sort
if topo result count != node count:
  has cycle
```

DFS 也可以检测环:

```text
WHITE: 未访问
GRAY: 当前递归栈中
BLACK: 已完成

DFS 遇到 GRAY 节点 => 有环
```

生产上错误信息不能只说:

```text
Invalid DAG.
```

最好能指出:

```text
Cycle detected: A -> B -> C -> A
Unknown parent: task D depends on missing task X
Duplicate task key: LOAD_DATA
```

## 孤立节点和不可达节点

孤立节点不一定总是错误。

比如一个 workflow 可以有多个入口:

```text
A -> B
C -> D
```

这可能是合法的两个并行入口。

但如果产品语义要求 workflow 必须有一个 `Start` 节点,那么 C 这种从 Start 不可达的节点就是异常。

所以校验要区分:

| 类型 | 是否一定错误 | 取决于 |
|---|---|---|
| 入度为 0 的节点 | 不一定 | 是否允许多入口 |
| 出度为 0 的节点 | 不一定 | 是否允许多终点 |
| 从 Start 不可达 | 通常可疑 | 是否有显式 Start 语义 |
| 到 End 不可达 | 通常可疑 | 是否有显式 End / completion 语义 |

建议文档化这些规则,否则用户会困惑:

```text
为什么我这个节点没跑?
为什么这个节点明明在 DAG 里,却从来没有 ready?
```

## 节点类型设计

生产工作流节点不是只有“执行一个函数”。

常见节点类型:

| 类型 | 特点 | 设计重点 |
|---|---|---|
| SQL 节点 | 调数据库或查询引擎 | 超时、SQL 参数、结果存储 |
| HTTP 节点 | 调 API | idempotency key、response code 分类 |
| Spark / Databricks 节点 | 外部长任务 | submit / monitor 分离、外部 job id |
| 人工审批节点 | 等人操作 | WAITING_APPROVAL、权限、审计 |
| 条件判断节点 | 选择分支 | 未选分支 SKIPPED、join trigger rule |
| 并行分支节点 | fan-out | 并发限制、下游汇合 |
| 子工作流节点 | 展开另一组任务 | namespace、completion token |
| 事件等待节点 | 等外部事件 | WAITING_EVENT、event correlation key |
| 补偿节点 | 失败后回滚 | 触发规则、幂等、人工介入 |
| 通知节点 | 发告警或消息 | 去重、失败策略 |

这些节点应该共享统一的 task 抽象:

```text
task_key
task_type
input
output_ref
status
retry_policy
timeout_policy
trigger_rule
resource_requirements
```

不要让每种节点都偷偷发明自己的状态语义。节点类型可以不同,但状态机和调度协议要尽量统一。

## trigger rule 是 DAG 语义的一部分

一个节点是否 ready,不一定只是“所有上游都成功”。

常见 trigger rule:

| Rule | 含义 | 典型场景 |
|---|---|---|
| `all_success` | 所有上游成功才执行 | 默认业务节点 |
| `all_done` | 所有上游结束就执行 | 清理、通知、收尾 |
| `one_success` | 任一上游成功就执行 | 多路备选 |
| `none_failed` | 没有失败即可执行 | 允许 skipped 分支 |
| `always` | 不看上游结果也执行 | 最终审计、兜底 |

如果没有 trigger rule,用户会不停问:

```text
为什么上游失败了,下游还跑?
为什么有个分支 skipped,join 就不跑?
为什么清理任务没执行?
```

所以 trigger rule 应该写进 task definition,并在 ready 判断里统一处理。

## 条件分支的建模

条件分支看起来像代码里的 if/else:

```text
if amount > 10000:
  manual_approval
else:
  auto_approval
```

但在 DAG 引擎里要变成状态语义:

```text
Start
  -> Branch
      -> Manual Approval
      -> Auto Approval
  -> Join
```

关键问题是:未被选中的分支是什么状态?

通常应该标记为:

```text
SKIPPED
```

然后 join 节点要配合 trigger rule:

```text
none_failed: 上游成功或 skipped 都可以,只要没有 failed
```

否则会出现:

```text
Auto Approval 被选中成功;
Manual Approval 被 skipped;
Join 等 Manual Approval SUCCESS,于是永远不 ready。
```

## 动态 DAG 的版本问题

动态 DAG 会在运行中生成新节点。这里有一个重要问题:

```text
动态生成后的 DAG 版本如何记录?
```

建议把它分成两层:

| 层 | 是否不可变 | 含义 |
|---|---|---|
| Definition Version | 不可变 | 用户提交的 workflow 模板版本 |
| Runtime Graph Snapshot / Task Instance Set | 随运行扩展 | 本次运行实际生成过哪些节点 |

也就是说,workflow instance 绑定的定义版本不变,但运行时 task instance 集合可以增长。

排查时要能回答:

```text
这个动态节点是谁生成的?
它基于哪个 definition version?
它由哪次 task execution 生成?
它的 parents 为什么是这些?
它有没有替换或重接下游节点?
```

这就需要 lineage 字段:

```text
generated_by_task_instance_id
generated_by_command
fanout_group_id
runtime_generation
```

## 子工作流的建模选择

子 workflow 有两种常见建模方式。

### 方式一:嵌入同一个 workflow instance

父子任务属于同一个运行时 DAG:

```text
Parent A
  -> Subflow:Task1
  -> Subflow:Task2
  -> Completion Token
  -> Parent D
```

优点:

- 父流程可以自然等待子流程。
- 同一个 ready 判断和状态汇总。
- completion token 可以作为 join barrier。

代价:

- DAG 变大。
- 子节点要 namespace。
- UI 展示要折叠子流程。

### 方式二:子工作流新开 workflow instance

父节点启动另一个 run:

```text
Parent Task
  -> starts Child Workflow Instance
  -> waits event/callback/status
```

优点:

- 子流程独立追踪。
- 可以单独重跑、取消、授权。

代价:

- 父流程不能天然通过 DAG 边等待子流程。
- 需要事件、callback 或状态轮询来接回父流程。
- 跨 workflow 的一致性更复杂。

## 排查清单

### 节点永远不 ready

排查:

1. `parents` 是否存在。
2. parent 状态是否满足 trigger rule。
3. 分支节点是否把未选分支标记为 `SKIPPED`。
4. 是否有 dangling parent。
5. 是否有 cycle。
6. 是否有 future scheduled time。
7. workflow 是否 paused / cancelled。

设计修复:

- 入队前做 parent 校验。
- workflow 提交时做 cycle detection。
- ready 判断支持 trigger rule。
- 状态表里记录 blocked reason。

### 工作流运行到一半后定义变了

排查:

1. workflow instance 绑定的 definition version 是多少。
2. UI 展示的是运行时版本还是最新版本。
3. task instance 是否从旧版本生成。
4. 重跑策略是否允许使用新版本。

设计修复:

- workflow instance 绑定不可变 version。
- UI 明确展示 version。
- 重跑默认使用原 version。
- 使用新 version 重跑必须创建新 workflow instance 或明确记录 migration。

### 动态节点重复或接错

排查:

1. 动态节点的 `order_id` 是否稳定唯一。
2. 是否有 `generated_by`。
3. retry 前是否已经生成过同一 fan-out group。
4. 下游是否 relink 到动态节点或 completion token。

设计修复:

- `run_id + order_id` 唯一约束。
- fan-out group id。
- dynamic generation audit。
- relink / completion token 统一封装。

## 面试总结

可以这样讲:

```text
DAG 建模的难点不是画出 A->B->C,而是把模板和运行实例、节点定义和节点实例、静态定义和动态生成区分清楚。
生产系统必须在 workflow 提交时校验 DAG 合法性,包括 cycle、重复节点、dangling parent 和不可达节点。
每次运行要绑定不可变 definition version,否则历史实例、重跑和审计都会混乱。
条件分支要用 SKIPPED 和 trigger rule 表达,子工作流要明确是嵌入同一张 DAG 还是新开 instance。
这些建模选择决定了后面的调度、重试、人工干预和可观测性是否能成立。
```
