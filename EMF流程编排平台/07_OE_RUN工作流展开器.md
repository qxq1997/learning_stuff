# 07 OE-RUN 工作流展开器

## OE-RUN 的定位

`OE-RUN` 是理解 EMF 的关键命令。

它不是一个普通业务任务,而是“把 workflow 定义展开成一批消息”的命令。

所以 `OE-RUN` 在 EMF 里有点像 workflow compiler:

```text
workflow definition / process_tasks
  -> Run
  -> workflow messages
  -> enqueue
  -> runtime DAG
```

## 它为什么重要

如果只看 `Message` 和 `DagContext`,你会知道 EMF 如何调度一批已经存在的消息。

但还要回答一个问题:

```text
这些 workflow messages 最初是怎么来的?
```

`OE-RUN` 就是关键答案之一。

## OE-RUN 流程

### 1. 读取外部参数并创建 Run

它读取外部参数,准备创建一个新的 run。

### 2. 合并参数并创建 Run

`RunFactory` 会合并:

- message 参数。
- 外部参数。
- run 相关参数。

然后创建 `Run`。

### 3. 生成 workflow messages 并 enqueue

它会:

1. 创建目标 dataset。
2. 生成 workflow messages。
3. 添加 timeout message。
4. 把生成的消息 enqueue。

### 4. 读取 process_tasks 并转换成 Message

`RunService` 读取 `process_tasks`,把任务定义转换成 `Message`,并做 enabled/disabled label 过滤。

这一步还会处理 workflow task 的顺序和依赖关系。特别是当某些 task 被 disabled 或 label 过滤掉时,系统需要避免留下断掉的依赖链。

### 5. 支持子工作流递归展开

它支持子工作流递归展开,让一个 workflow 可以继续生成内部 workflow。

## 子 workflow 怎么触发

子 workflow 不是另起一套完全独立系统,而是由父 workflow 的某个 task 触发:

```text
父 workflow process_tasks 中的 OE-RUN task
  -> 找到子 workflow
  -> 按子 workflow 的方式生成 workflow messages
  -> 子任务通过 order_id / parents 接回父流程
  -> completion token 汇合
  -> 父 workflow 后续节点继续执行
```

这说明 `OE-RUN` 既可以作为顶层入口,也可以作为父流程内部的一个展开节点。

这点很容易和普通函数调用混淆。子 workflow 不是:

```text
父节点调用一个函数,函数内部同步跑完所有子任务,然后返回。
```

更准确的是:

```text
父 workflow 中有一个特殊的 OE-RUN 节点;
这个节点执行后生成一批子 workflow messages;
这些 messages 加入 DAG;
调度器继续按 Message / parents / ready 语义推进。
```

所以子 workflow 仍然没有绕过 EMF 的核心模型,它只是又生成了一批可调度的消息。

## 子 workflow 的依赖重接

当子 workflow 被展开时,最重要的是依赖不能断。

假设父流程里:

```text
PARENT_SUBFLOW_A
  -> A
  -> B
  -> C
```

子 workflow 内部有:

```text
A
B
C
```

系统需要把父流程节点、子 workflow 入口、子 workflow 出口重新接好。否则父流程会误以为子 workflow 节点已经完成,或者后续节点永远等不到 completion token。

## 子 workflow 的 order_id 命名空间

子 workflow 展开后,一个很现实的问题是:父 workflow 和子 workflow 里可能有同名节点。

例如父流程和子流程里都叫:

```text
LOAD_DATA
VALIDATE
EXPORT
```

如果直接放到同一张 DAG 里,`parents` 用 `order_id` 匹配父节点时就会混乱。

所以子 workflow 通常需要给子节点加命名空间前缀:

```text
child_order_id = parent_oe_run_order_id + ":" + child_order_id
```

例如:

```text
父节点: SUBFLOW_LOAD
子节点: LOAD_DATA
展开后: SUBFLOW_LOAD:LOAD_DATA
```

这个设计的目的不是让名字更复杂,而是保证同一张 DAG 里每个业务节点身份清晰,避免父子 workflow 的 `order_id` 冲突。

## 同一个 run 还是新 run

子 workflow 展开时有一个关键设计选择:子 workflow 要不要沿用父 workflow 的 `run_uuid`。

| 选择 | 含义 | 优点 | 代价 |
|---|---|---|---|
| 沿用同一个 `run_uuid` | 父子 workflow 属于同一张 DAG | 依赖可以直接用 `parents` 连接,completion token 可以自然汇合 | DAG 更大,必须处理 `order_id` 命名空间 |
| 新开一个 `run_uuid` | 子 workflow 是另一张 DAG | 子 run 独立追踪和管理 | 父 workflow 不能天然等待另一张 DAG,需要外部状态、事件或消息回调 |

如果父流程后续节点要直接等待子 workflow 完成,沿用同一个 `run_uuid` 更符合 EMF 的 DAG 语义。因为父子节点仍在同一个 `DagContext` 里,`parents` 才能自然表达等待关系。

如果子 workflow 开成独立 run,它更像“启动另一个 workflow”,而不是“嵌入当前 workflow 的子流程”。这时父流程要等待它,就必须引入额外的协调机制。

## completion token 的作用

子 workflow 的另一个难点是:子流程可能有多个终点。

例如父 workflow 是:

```text
A -> OE-RUN(SUB) -> D
```

子 workflow 内部是:

```text
X -> Y
X -> Z
```

父流程的 `D` 到底应该等谁?等 Y?等 Z?还是等所有子流程终点?

直接让 D 依赖所有子流程终点会让父流程知道太多子流程内部结构。更好的方式是引入一个逻辑汇合点:

```text
A
  -> SUB:X
      -> SUB:Y -> SUB:COMPLETION_TOKEN
      -> SUB:Z -> SUB:COMPLETION_TOKEN
SUB:COMPLETION_TOKEN
  -> D
```

`COMPLETION_TOKEN` 不是一个普通业务任务,而是一个协调节点。它表示:

```text
子 workflow 的所有终点都已经达到允许状态,
父 workflow 可以继续往下走。
```

这样父 workflow 后续节点只需要等待一个 completion token,不用理解子 workflow 里到底有多少分支和终点。

## 关键结论

EMF 的 workflow 不是写死在 Python 代码里。

更准确地说:

```text
workflow 定义来自 process_tasks 表或 catalogue resolution,
然后被 OE-RUN 转换成一批 Message,
再进入 DagManager 形成运行时 DAG.
```

这解释了为什么 EMF 的最核心对象是 `Message`,而不是某种静态 `Workflow` 类。workflow 最终会被降解成一批可调度、可依赖、可执行的消息。

## 和普通 command 的差异

普通 command 的输出通常是业务副作用:

```text
写表 / 跑 SQL / 调服务 / 写文件
```

`OE-RUN` 的输出是新的调度结构:

```text
workflow definition -> messages -> runtime DAG
```

所以它是“工作流展开器”,不是单纯业务节点。

判断一个 `OE-RUN` 是顶层 workflow 还是子 workflow,关键看它出现在什么上下文:

```text
外部触发的 OE-RUN: 生成第一批 workflow messages
workflow 内部的 OE-RUN task: 展开子 workflow,并接回当前 DAG
```

## OE-RUN 的设计价值

`OE-RUN` 把 workflow 定义和 workflow 执行解耦。

如果没有 `OE-RUN`,系统可能会变成:

```text
每种 workflow 都写一段专门代码来生成任务.
```

有了 `OE-RUN`,统一变成:

```text
读取 workflow 定义
  -> 参数化
  -> 生成 Message
  -> 交给同一个 DAG 调度器
```

这让 workflow 的“编译阶段”和“执行阶段”分开:

| 阶段 | 关注点 |
|---|---|
| 编译阶段 | 读取任务定义、展开子流程、生成 messages、处理 labels |
| 执行阶段 | ready 判断、并发调度、命令执行、状态推进 |

面试时可以说:

```text
OE-RUN 相当于 workflow compiler,它把 process_tasks 这种业务定义编译成 EMF 调度器能理解的 Message DAG。
```
