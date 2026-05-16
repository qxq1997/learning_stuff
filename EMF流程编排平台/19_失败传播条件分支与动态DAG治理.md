# 19 失败传播、条件分支与动态 DAG 治理

## 为什么这块容易出事故

DAG 引擎最容易被误解的一点是:

```text
上游成功就跑下游,上游失败就停。
```

这只适合最简单的线性流程。生产工作流会有:

- 条件分支。
- 多分支汇合。
- 清理任务。
- 补偿任务。
- 允许部分成功。
- 动态 fan-out / fan-in。
- 人工审批。
- 子工作流。

这时问题会变成:

```text
上游 failed / skipped / cancelled / timeout 时,下游到底该不该跑?
```

如果不明确这套语义,用户会遇到:

- 上游失败了,下游居然跑了。
- 只有一个分支成功,join 却没跑。
- 清理任务没有执行。
- 条件分支没选中的节点导致 workflow 卡住。
- 动态生成的任务没跑完,汇总节点提前执行。

## 失败传播不是固定规则

看这个 DAG:

```text
A -> B -> D
A -> C -> D
```

如果 B 失败,C 成功,D 是否执行?

答案不是固定的,取决于 D 的 trigger rule。

常见规则:

| Trigger Rule | 含义 | 典型场景 |
|---|---|---|
| `all_success` | 所有上游成功才执行 | 普通业务节点 |
| `all_done` | 所有上游都到终态就执行,不管成功失败 | 清理、通知、审计 |
| `one_success` | 任一上游成功就执行 | 多路备选、fallback |
| `none_failed` | 没有 failed 即可执行,skipped 可接受 | 条件分支 join |
| `always` | 总是执行 | 最终兜底、错误收集 |
| `all_failed` | 所有上游失败才执行 | 补偿或失败处理 |

所以 ready 判断不能只写:

```text
all parents SUCCESS
```

而应该是:

```text
all parents terminal
and trigger_rule(parent_states) == true
and scheduled_time reached
and resource available
```

## 状态终态和非终态

trigger rule 依赖一个前提:哪些状态算终态?

常见划分:

| 类型 | 状态 |
|---|---|
| 成功终态 | `SUCCESS` |
| 中性终态 | `SKIPPED` |
| 失败终态 | `FAILED`, `TIMEOUT`, `CANCELLED` |
| 非终态 | `CREATED`, `READY`, `RUNNING`, `RETRYING`, `WAITING_APPROVAL`, `WAITING_EVENT` |

多数 join 节点至少要等所有 parent 到终态,否则会提前判断。

例如:

```text
B = SUCCESS
C = RUNNING
D trigger_rule = one_success
```

D 是否可以立刻跑?

这取决于产品语义。通常为了避免提前汇总,会要求:

```text
所有 parent terminal 后再应用 trigger rule。
```

但某些“抢先成功”场景可以允许 one_success 立即触发,同时取消其他分支。这必须显式设计,不能含糊。

## 条件分支怎么建模

条件分支示例:

```text
Start
  -> Branch
      -> Manual Approval
      -> Auto Approval
  -> Join
```

假设条件是:

```text
amount > 10000 => Manual Approval
otherwise => Auto Approval
```

当选择 `Auto Approval` 时,`Manual Approval` 不能一直保持 `CREATED` 或 `READY`,否则 Join 会永远等它。

正确做法是:

```text
Manual Approval -> SKIPPED
Auto Approval -> SUCCESS
Join trigger_rule = none_failed
```

这样 Join 可以继续。

核心原则:

```text
未被选中的分支也必须进入一个明确状态,通常是 SKIPPED。
```

## SKIPPED 的传播

`SKIPPED` 很麻烦,因为它既不是成功,也不是失败。

如果一个节点被 skip,它的下游怎么办?

取决于下游 trigger rule:

| 下游 rule | 上游 skipped 时 |
|---|---|
| `all_success` | 不执行,下游可能也 skipped |
| `none_failed` | 可以执行 |
| `all_done` | 可以执行 |
| `always` | 可以执行 |

条件分支里常见模式:

```text
Branch
  -> Path A -> Join
  -> Path B -> Join
```

未选路径标记 skipped,Join 用 `none_failed`。

但如果 Join 是业务汇总节点,必须确认 skipped 分支是真的“无需执行”,而不是因为错误跳过。

## 失败传播策略

上游失败后,下游通常有几种处理:

| 策略 | 含义 |
|---|---|
| 阻断 | 下游保持 blocked 或 skipped |
| 继续 | 下游按 `all_done` / `always` 执行 |
| 补偿 | 触发 compensation 节点 |
| 部分成功 | workflow 标记 `PARTIAL_SUCCESS` |
| 人工介入 | 进入 `WAITING_MANUAL_RESOLUTION` |
| 取消其他分支 | 某分支失败后取消并行分支 |

例如数据发布流程:

```text
Extract -> Transform -> Publish
                    -> Cleanup
```

如果 Transform 失败,Publish 不应该执行,但 Cleanup 应该执行:

```text
Publish trigger_rule = all_success
Cleanup trigger_rule = all_done
```

## 动态 fan-out / fan-in

动态任务生成最典型的是 map-reduce:

```text
List Files
  -> Process file 1
  -> Process file 2
  -> Process file 3
  -> ...
  -> Merge Results
```

挑战在于:

```text
Process file N 的数量运行时才知道。
```

系统需要持久化这批动态任务:

```text
fanout_group_id
generated_by_task
child_task_keys
expected_child_count
generated_at
```

Merge 节点不能只看 `List Files` 成功,而要等 fan-out group 达到汇合条件:

```text
all generated children terminal
and trigger_rule satisfied
```

## fan-out group

建议把一次动态生成看成一个 fan-out group。

字段:

```text
fanout_group_id
workflow_instance_id
parent_task_instance_id
status
expected_count
created_count
success_count
failed_count
skipped_count
created_at
completed_at
```

这个 group 可以帮助回答:

```text
这批动态任务是谁生成的?
预期有多少个?
实际创建了多少个?
成功多少,失败多少?
汇总节点为什么还没 ready?
retry 后有没有重复生成?
```

## completion token

如果下游不想直接依赖几千个动态节点,可以引入 completion token:

```text
List Files
  -> Process file 1
  -> Process file 2
  -> ...
  -> Fanout Completion Token
  -> Merge Results
```

completion token 的职责是:

```text
观察 fan-out group 是否完成;
完成后作为一个普通节点让下游继续。
```

这样 Merge 只需要依赖 token,不用依赖所有动态子任务。

## 动态生成和 retry

动态 DAG 里最危险的问题之一是重复生成。

场景:

```text
List Files 生成 100 个 ProcessFile 任务
List Files 后续因为状态更新失败被 retry
retry 又生成 100 个 ProcessFile 任务
```

如果没有幂等,就会重复处理文件。

治理方式:

- 动态 child task key 稳定。
- `workflow_instance_id + task_key` 唯一约束。
- fan-out group 幂等。
- 生成前检查是否已有 group。
- attempt 和 generation 分离。

关键原则:

```text
retry parent task 不应该无脑重复创建同一批 child task。
```

## 动态 DAG 和 run completion

静态 DAG 中,run completion 比较简单:

```text
所有已知任务终态 => workflow 结束
```

动态 DAG 中,任务集合会增长。run 不能在初始节点完成后就结束。

需要判断:

```text
没有 running task
没有 ready task
没有 retrying future task
没有 waiting event / approval
没有 open fan-out group
没有 pending dynamic generation
所有 required terminal 节点满足 workflow trigger rule
```

如果有 completion token,run completion 可以更清晰:

```text
所有 exit token terminal => run 可结束
```

## 动态 DAG 的版本和快照

动态 DAG 不是修改 definition version。

更准确地说:

```text
definition version 不变;
runtime graph 随 task execution 增长。
```

因此要保留运行时快照:

```text
runtime_task_instance
runtime_dependency
generated_by
fanout_group
generation_attempt
```

这样审计时可以还原:

```text
最初定义是什么?
运行时生成了哪些节点?
哪个节点生成的?
为什么下游被重接?
```

## 排查清单

### Join 节点为什么没跑

排查:

1. parent 是否都 terminal。
2. parent 状态分布是什么。
3. join 的 trigger rule 是什么。
4. 是否有 skipped 分支。
5. 是否有 failed / timeout parent。
6. 是否有动态 fan-out group 未完成。
7. completion token 是否生成并成功。

设计修复:

- trigger rule 显式化。
- branch 未选分支标记 `SKIPPED`。
- fan-out group 状态表。
- blocked reason。

### 下游为什么提前跑了

排查:

1. 下游 parents 是否只依赖原 parent。
2. 动态生成后是否 relink。
3. 是否用了 completion token。
4. fan-out group 是否还 open。
5. trigger rule 是否允许提前触发。

设计修复:

- 动态生成和 relink 放在同一事务或同一原子流程。
- 下游依赖 completion token。
- ready 判断检查 open fan-out group。

### 条件分支后 workflow 卡住

排查:

1. 未选分支是否变成 `SKIPPED`。
2. Join 是否使用 `all_success`。
3. skipped 是否被 trigger rule 接受。
4. branch 条件是否写错。

设计修复:

- Branch 节点统一负责 skip 未选路径。
- Join 默认使用适合分支的 rule,如 `none_failed`。
- UI 展示 branch decision。

### 动态任务数量太大

排查:

1. fan-out source 返回多少结果。
2. 是否分页。
3. 是否有最大 fan-out 限制。
4. 是否按 partition 分批。
5. worker / DB / external system 哪个先饱和。

设计修复:

- fan-out limit。
- pagination。
- chunk task。
- backpressure。
- resource pool。

## 面试总结

可以这样讲:

```text
失败传播和动态 DAG 的核心是把依赖语义说清楚。
一个节点是否执行不能只看 parent 是否 success,还要看 trigger rule。
条件分支中未选路径应该标记 SKIPPED,join 节点要能理解 skipped。
动态 fan-out 要持久化 fan-out group,避免下游提前执行,并通过 completion token 或 relink 完成 fan-in。
retry 时要保证动态生成幂等,防止重复创建子任务。
所以动态 DAG 的难点不是生成节点,而是失败传播、分支汇合、幂等生成、运行时图快照和 run completion。
```
