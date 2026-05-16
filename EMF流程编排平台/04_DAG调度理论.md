# 04 DAG 调度理论

## DagManager 和 DagContext

EMF 的 DAG 调度围绕两个对象展开:

```text
DagManager 管多个 DagContext
每个 run_uuid 对应一张 DagContext
```

`DagManager` 的职责不是执行命令,而是管理运行时 DAG 集合。真正单张 DAG 里的节点、边、ready 判断,主要落在 `DagContext`。

关键区别:

```text
DagManager: 管很多 run_uuid -> DagContext
DagContext: 管一张 run_uuid 内部的 vertices / parents / children / state
```

## DagContext 负责什么

`DagContext` 主要做四件事:

1. 添加节点。
2. 建立 parent/child 边。
3. 判断节点是否 ready。
4. 计算 run 最终状态。

从系统设计角度看,`DagContext` 是一个运行时 graph state:

```text
vertices: 当前 run 里有哪些消息节点
parents: 每个节点依赖谁
children: 每个节点完成后影响谁
states: 每个节点当前执行状态
```

它的价值不是“保存 DAG 结构”,而是能不断回答一个问题:

```text
现在有哪些节点可以安全执行?
```

## 依赖边怎么建

EMF 的依赖不是通过 `msg_id` 连起来的,而是:

```text
child.parents -> parent.order_id
```

因此 `order_id` 是业务 DAG 节点的稳定标识。`msg_id` 更像消息实例标识。

这带来的好处是:即使一条业务任务因为 retry 或重新生成产生了不同消息实例,依赖语义仍然围绕业务节点 ID 表达。

把一组 messages 推导成图,就是:

```text
[
  {"order_id": "A", "parents": []},
  {"order_id": "B", "parents": ["A"]},
  {"order_id": "C", "parents": ["A"]},
  {"order_id": "D", "parents": ["B", "C"]}
]
```

生成 DAG:

```text
A -> B -> D
A -> C -> D
```

这也是为什么 EMF 的 DAG 是“Message 推导出来的”,不是先有一份中心化 DAG 对象再把任务塞进去。

换句话说,EMF 的 DAG 不是提前画好的一张静态图,而是由消息集合自然导出的:

```text
每条 Message 声明自己是谁: order_id
每条 Message 声明自己依赖谁: parents
同一个 run_uuid 的 Message 放在一起
DagContext 就能推导出这张 run 的 DAG
```

因此 workflow 的执行顺序不是文件里列表的顺序,而是 `parents` 关系决定的拓扑推进顺序。

## 调度依赖和数据依赖

面试里经常会被问到一个场景:

```text
A
B
C
 \ | /
   D
```

如果 `D.parents = ["A", "B", "C"]`,这只说明 D 必须等 A/B/C 都达到允许状态后才能执行。它不说明 A/B/C 之间有没有顺序。

所以要区分两类依赖:

| 依赖类型 | 解决什么问题 | EMF 怎么表达 |
|---|---|---|
| 调度依赖 | 谁必须先执行完成 | `parents -> order_id` |
| 数据依赖 | 谁的输出会被谁读取或影响 | 必须转成显式 DAG 边,或者通过数据治理保证隔离 |

如果真实业务是:

```text
A 产出数据
B 读取 A 的数据
C 读取 B 的结果
D 汇总最终结果
```

那 DAG 不能只写成 D 依赖 A/B/C,而应该写成:

```text
A -> B -> C -> D
```

如果 C 不依赖 B,但 B/C 都依赖 A,则应该是:

```text
A -> B -> D
A -> C -> D
```

关键原则是:

```text
凡是会影响数据正确性的依赖,都必须进入 parents。
```

否则这类依赖就是 hidden dependency。调度器看不见 hidden dependency,就会把 A/B/C 当成可并发节点,可能导致脏读、旧数据、读不到上游产物或结果不确定。

还有一种情况是 A/B/C 之间没有读取依赖,但会写同一张表、同一个 partition 或同一个外部资源。这更像资源冲突,不一定要全部串行化,但必须有额外治理:

- 拆分 partition,保证并发写互不影响。
- 先写 staging path,再由一个 commit / publish 节点统一发布。
- 把最终写入集中到 merge 节点。
- 用幂等 key 或锁避免重复写和并发覆盖。
- 对外部系统做 reconciliation,检查最终状态是否符合预期。

所以 DAG 正确性只能保证“执行顺序正确”,不能自动保证“数据语义正确”。数据依赖、写冲突和外部副作用需要 workflow 设计者显式建模。

## ready 判断是调度器的安全闸门

ready 判断是 EMF 调度正确性的核心。一个节点被交给线程池前,必须先通过 ready 判断。

这层安全闸门解决三个问题:

1. **依赖正确性**:父节点没完成,子节点不能跑。
2. **时间正确性**:retry 或延迟消息不到时间不能跑。
3. **状态正确性**:已经跑过、正在跑、失败终态的节点不能重复被调度。

因此,并发调度本身不是最危险的地方。真正危险的是 ready 判断错了:一旦 ready 判断放宽,后面线程池会很快把错误放大。

这一点面试时可以讲得更明确:

```text
EMF 不是 FIFO 调度。
它先从 DAG 中找 ready set,
再在 ready set 里做优先级和并发控制。
```

## 节点 ready 条件

一个节点可以被执行,需要同时满足:

1. 当前状态必须是 `INACTIVE`。
2. `run_date` 不能在未来。
3. 所有父节点必须是 `COMPLETE` 或 `RETRY`。

可以写成:

```text
is_ready(message):
  message.state == INACTIVE
  and message.run_date <= now
  and all(parent.state in {COMPLETE, RETRY} for parent in parents)
```

这里最值得注意的是 `RETRY`。在这套状态语义里,父节点处于某些 retry 语义时也可能允许下游推进,具体要结合业务对 retry 的定义继续看实现。

如果一个节点不是 ready,通常要从这三个方向排查:

| 排查点 | 常见原因 |
|---|---|
| 状态不是 `INACTIVE` | 已经被调度、正在执行、已完成或进入异常态 |
| `run_date` 在未来 | retry 或 delayed message 被设置了未来执行时间 |
| 父节点没到允许状态 | `parents` 对应的 `order_id` 还没 `COMPLETE` 或 `RETRY` |

## 状态机

整体状态流可以记成:

```text
INACTIVE -> ACTIVE -> IN_PROGRESS -> COMPLETE
                                 |-> RETRY
                                 |-> FAILED
                                 |-> TIMEOUT
                                 |-> CANCELLED
```

含义:

| 状态 | 含义 |
|---|---|
| `INACTIVE` | 节点已在 DAG 中,但还没有被调度执行 |
| `ACTIVE` | 节点已被选中,准备进入执行 |
| `IN_PROGRESS` | 命令正在执行 |
| `COMPLETE` | 命令成功完成 |
| `RETRY` | 执行失败但进入重试路径 |
| `FAILED` | 最终失败 |
| `TIMEOUT` | 超时 |
| `CANCELLED` | 被取消 |

其中 retry 不是“立刻重跑同一条消息”这么简单。通常会生成一条新的 retry message,保留原始 message 的核心字段,并把 `run_date` 设到未来,等时间到了再进入 ready 判断。

## DAG 调度的核心循环

从调度角度看,EMF 不断重复下面的动作:

```text
while worker running:
  从 DagManager 拿 ready vertices
  按 batch_priority 排序
  取当前 available_slots 个节点
  标记 ACTIVE / IN_PROGRESS
  调用 MessageHandler 执行
  回写 COMPLETE / RETRY / FAILED / TIMEOUT / CANCELLED
  下游节点可能变 ready
```

这就是“消息驱动 + DAG 调度”的结合点。

它的核心公式可以记成:

```text
ready_set + priority + concurrency limit
```

| 部分 | 解决什么问题 |
|---|---|
| `ready_set` | 保证依赖正确,没满足父节点的任务不能执行 |
| `priority` | 多个 batch/run 抢资源时谁先执行 |
| `concurrency limit` | 控制同一时间最多有多少任务进入执行 |

所以“ready”决定能不能跑,“priority”决定谁先跑,“concurrency”决定同时跑几个。

## 调度器要解决的四个矛盾

### 1. 正确性 vs 并发

系统想并发执行多个节点,但不能破坏依赖。EMF 的做法是:

```text
先由 DagContext 过滤出 ready vertices,
再由 Consumer 并发执行这些 ready vertices.
```

也就是说,并发层不直接决定节点能不能跑,它只决定 ready 节点中谁先占用资源。

### 2. 静态图 vs 动态图

EMF 的 DAG 可能运行时增长。调度器不能假设图在启动时已经完整。

所以它更像一个持续推进的 graph:

```text
已有节点完成 -> 下游 ready
新消息加入 -> graph 更新 -> 新节点可能 ready
```

这也是为什么 `DagManager` 需要长期存在,而不是一次性拓扑排序后就结束。

### 3. 单 run 正确性 vs batch 级公平性

每个 `run_uuid` 内部要保证 DAG 依赖正确;多个 run 或 batch 之间又要考虑优先级。`batch_priority` 就是跨 run 竞争资源时的调度信号。

### 4. 失败隔离 vs 下游推进

失败节点可能进入 `RETRY`、`FAILED`、`TIMEOUT` 等状态。哪些状态允许下游继续,哪些状态阻断下游,是 workflow 语义的一部分。这个选择会影响数据一致性和恢复策略。

## batch 和 run 的状态边界

`run_uuid` 决定单张 DAG 的调度状态。`batch_id` 决定一组 run 的聚合状态。

可以这么记:

```text
run_uuid: 当前这张 DAG 有没有跑完
batch_id: 这一批 run 整体有没有跑完
```

所以同一个 batch 下面可以同时存在多张不同状态的 DAG。`DagManager` 需要区分 run context 和 batch context,否则容易把“批次完成”和“单个 DAG 完成”混在一起。
