# 03 Message 数据模型

## Message 是任务单元

可以把它理解为“可被调度和执行的一条任务”。系统里的 DAG 节点不是一个独立的 `Task` 类,而是一条带依赖信息、命令信息和参数信息的 `Message`。

更强一点说:

```text
EMF 的 DAG 不是由一个单独的 DAG DSL 配出来的,
而是由每个 Message 携带的 order_id 和 parents 推导出来的.
```

也就是说,`Message` 既是任务,也是 DAG DSL 的最小语法单元。

这是一种很重要的抽象:EMF 没有把“任务定义”和“运行时事件”拆成两个完全不同的模型。它让同一个 `Message` 同时承担:

- workflow 定义里的一个 task。
- 运行时 DAG 里的一个 vertex。
- 命令执行系统的一次输入。
- retry / fan-out / 子 workflow 继续生成任务时的载体。

这样做让系统的扩展路径非常统一:只要能生成合法 `Message`,就能接入调度器。

## 关键字段

| 字段 | 含义 |
|---|---|
| `command` | 决定执行哪个命令模块 |
| `msg_id` | 消息实例 ID |
| `run_uuid` | 一个 workflow run 的 DAG 分组 |
| `batch_id` | 一批 run 的分组 |
| `order_id` | 业务层面的任务节点 ID |
| `parents` | 依赖的父节点 `order_id` 列表 |
| `run_date` | 延迟执行时间 |
| `batch_priority` | 跨 run 调度优先级 |
| `parameters` | 命令参数 |
| `parameter_object` | 结构化命令参数对象 |

可以把这些字段压成一句:

```text
Message 是异步节点,parents 是边,run_uuid 是图,batch_id 是图的容器。
```

对应到 EMF 的几个核心抽象:

| 抽象 | 在 Message 里的体现 | 面试讲法 |
|---|---|---|
| 一个被执行的业务节点 | `order_id` + `command` | 这个节点是谁,要做什么 |
| 节点之间的依赖关系 | `parents` | 当前节点要等哪些父节点 |
| 一次 workflow run | `run_uuid` | 哪些消息属于同一张 DAG |
| 一批 workflow run | `batch_id` | 哪些 run 属于同一批生命周期 |
| 命令输入 | `parameters` / `parameter_object` | command 执行需要的上下文 |
| 调度信号 | `run_date` / `batch_priority` | 什么时候可执行,谁先执行 |

一个最小 message 例子:

```json
{
  "order_id": "D",
  "parents": ["B", "C"],
  "command": "ADB-SQL-EVAL",
  "parameters": {
    "sql": "select ..."
  }
}
```

这条消息本身就说明:

```text
D 节点依赖 B 和 C;
D 执行 ADB-SQL-EVAL;
D 的命令参数在 parameters 里.
```

## 三个 ID 的边界

最容易混的是 `batch_id`、`run_uuid`、`msg_id`、`order_id`。

### `batch_id`

`batch_id` 管一组 run。它常用于 batch 级的执行控制和状态汇总。

例如:

```text
Batch
  |- Run A / run_uuid=A / DAG A
  |    |- message 1
  |    |- message 2
  |
  |- Run B / run_uuid=B / DAG B
       |- message 4
       |- message 5
```

同一个 batch 下可以有多个 `run_uuid`,每个 `run_uuid` 对应一张 DAG。

可以把 `batch_id` 想成一个文件夹,里面可以放多张图:

```text
batch_id: 一个批次文件夹
run_uuid: 文件夹里的一张 DAG 图
message: DAG 图里的一个任务节点
```

EMF 需要把 `batch_id` 和 `run_uuid` 分开,是因为平台上经常同时需要两种粒度:

| 粒度 | 典型问题 |
|---|---|
| run 级 | 这一次 workflow DAG 有没有结束?有没有 timeout/cancel? |
| batch 级 | 这一批 run 是否都结束?能不能做 batch cleanup / cache 清理 / 状态汇总? |

如果只用一个 ID,就很难表达“一个 batch 里有多个 workflow run,每个 run 又有自己的 DAG 状态”。

### `msg_id`

`msg_id` 是消息实例 ID。它标识“这一条消息本身”。

它适合用来追踪日志、审计、唯一消息实例,但它不是 DAG 依赖的主键。

### `run_uuid`

`run_uuid` 是一次 workflow run 的分组。`DagManager` 会按 `run_uuid` 管理多张 DAG。

同一个 `run_uuid` 下的消息属于同一张运行时 DAG。

反过来说,不同 `run_uuid` 默认就是不同 DAG。即使它们在同一个 `batch_id` 下,调度依赖也不会自然跨 DAG 生效。跨 run 协调需要额外的消息、状态或事件机制。

因此:

```text
batch_id 用来管一批 run;
run_uuid 用来定位一张 DAG;
order_id 用来定位 DAG 内的业务节点.
```

### `order_id`

`order_id` 是业务层面的任务节点 ID。父子依赖用的是它,不是 `msg_id`。

这点非常关键:

```text
DAG 依赖不是通过 msg_id 建立的,
而是通过 parents 引用父任务的 order_id.
```

父节点匹配逻辑的关键不是消息实例 ID,而是业务节点 ID。

## parents 的含义

`parents` 保存的是当前节点依赖的父任务 `order_id` 列表。

例如:

```text
order_id = "load_fact_orders"
parents = ["extract_orders", "extract_customers"]
```

含义是:

```text
只有 extract_orders 和 extract_customers 都完成到允许状态后,
load_fact_orders 才能成为 ready 节点.
```

所以 `parents` 本质上是一个 join barrier:

```text
A
|- B
|- C
   \ 
    D
```

如果 `D.parents = ["B", "C"]`,那么 D 必须等 B 和 C 都达到允许状态,而不是任意一个完成就能跑。

## batch_priority 的含义

`batch_priority` 用于跨 run 或跨 batch 调度时的优先级排序。多个节点都 ready 时,调度器会优先让高优先级 batch 占用执行资源。

## Message 为什么能承载 workflow

`Message` 同时包含这些信息:

```text
要执行什么: command
属于哪次运行: run_uuid
属于哪批运行: batch_id
自己是谁: order_id / msg_id
依赖谁: parents
什么时候能执行: run_date
优先级如何: batch_priority
执行参数是什么: parameters / parameter_object
```

因此,一批 `Message` 就足以组成一张运行时 DAG。

## Message 的不变量

为了让“用 Message 推导 DAG”成立,有几个不变量必须守住。

| 不变量 | 为什么重要 |
|---|---|
| 同一 `run_uuid` 下 `order_id` 应该能稳定代表业务节点 | 否则 `parents` 无法准确找到父节点 |
| `parents` 只能引用当前 DAG 中可解析的 `order_id` | 否则节点会永远等不到父节点 |
| 同一批动态生成消息要继承正确的 `run_uuid` 和 `batch_id` | 否则新节点会进入错误 DAG 或错误 batch |
| retry message 要保留原业务节点语义 | 否则 retry 会变成新节点,破坏依赖关系 |
| command 和 parameters 要能被命令层解析 | 否则调度成功但执行失败 |

面试时可以说:

```text
Message 是 EMF 的中心协议。它不只是队列消息,而是把调度身份、依赖关系、执行命令和参数都放在一起的任务描述。
```

## 为什么不用单独的 Task / Edge 表达

一种更传统的设计是:

```text
Workflow
  -> Task[]
  -> Edge[]
  -> RuntimeTask[]
  -> Message[]
```

EMF 没有这么拆,而是让 `Message` 直接携带节点和边的信息。好处是模型少、入口统一,坏处是每条消息都必须足够规范。

这个取舍适合 EMF 的原因是:

- 工作流可能来自外部事件、`OE-RUN`、query 结果、子 workflow 或 retry,入口很多。
- 如果每种入口都要先转成某种中心 workflow 对象,系统会越来越厚。
- 统一成 `Message` 后,所有入口都只需要回答一个问题:我要往 DAG 里追加哪些消息。

代价是调试时不能只看“workflow 配置”,而要看“最终生成的 Message 集合”。

## 不要把 Message 当普通队列消息

普通消息队列里的消息通常只表示“有一个事件要处理”。EMF 的 `Message` 额外携带:

- 它属于哪张 DAG: `run_uuid`。
- 它属于哪批运行: `batch_id`。
- 它在 DAG 里的节点名: `order_id`。
- 它依赖谁: `parents`。
- 它要执行哪个命令: `command`。
- 它怎么执行: `parameters`。

因此每来一条 `Message`,系统不只是“消费一条消息”,而是在不断补全和推进一张运行时 DAG。
