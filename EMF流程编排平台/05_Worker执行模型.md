# 05 Worker 执行模型

## Worker 本身很薄

`Worker` 本身不应该承担太多业务逻辑。可以把它看成一个协调壳:

```text
Worker
  -> start producer
  -> start consumer
```

更完整的启动后链路是:

```text
Worker
  -> producer 在主线程/后台循环中拉消息
  -> consumer 在线程池中不断调度 ready messages
```

真正复杂的逻辑分散在消息进入、DAG 入队、并发调度、单消息执行这几层。

## 消息进入

外部消息由 `PubSubMessageProducer` 拉入:

流程:

1. 从 Service Bus / PubSub 拉消息。
2. 把外部 payload 转换成内部 `Message`。
3. 交给 `WorkerMessageAppender.enqueue_all()`。

这一步完成的是“从外部消息系统到 EMF 内部消息模型”的转换。

## 入队逻辑

入队逻辑在:

主要步骤:

1. 按 `batch_id` 分组。
2. 创建 `BatchContext`。
3. 创建 `RunContext`。
4. 把消息加入 `DagManager`。
5. 写 audit log。

入队不是简单 append 到 list,而是把消息放到正确的 batch、run 和 DAG 上下文中。

## 执行调度

它负责:

- 按 `max_messages` 控制并发。
- 用 `Counter` 记录当前占用 slot。
- 用 `Semaphore` 控制并发。
- 查找 `available_slots` 个 ready vertices。
- 从 `DagManager` 获取 ready vertices。
- 按 `batch_priority` 降序调度。
- 设置状态 `ACTIVE`、`IN_PROGRESS`、`COMPLETE`。
- 异常时走 retry 或 failed。

这一层可以用一句话概括:

```text
Consumer 不负责判断业务是否应该执行,
它负责把 DagManager 给出的 ready 节点安全地并发派发出去。
```

调度时实际在平衡三件事:

| 控制点 | 作用 |
|---|---|
| ready 集合 | 只执行依赖已经满足的节点 |
| `batch_priority` | 多个 ready 节点竞争时排序 |
| `max_messages` / slot | 限制同时执行的消息数量 |

例如系统里同时有 100 个 ready 节点,但 `max_messages` 只有 10,那么这一轮只会有一部分节点进入执行。剩下的 ready 节点不是不合法,只是没有拿到当前轮的并发资源。

这带来三个效果:

1. 多个 workflow run 可以同时推进。
2. 单个 batch 或 run 不容易无限占满执行资源。
3. DAG 依赖优先于队列顺序,依赖没满足的节点即使“排在前面”也不会执行。

## 单条消息执行

`ParallelMessageConsumer` 选出 ready 节点后,不会自己解析 command。它会把消息交给 `MessageHandler`。

`MessageHandler` 的关键价值是建立单消息执行上下文,并进入 DI scope:

之后再交给:

```text
StratusCommandExecutor
```

也就是说,worker 执行链路可以拆成:

```text
拉消息: PubSubMessageProducer
入 DAG: WorkerMessageAppender
选 ready: ParallelMessageConsumer
建 scope: MessageHandler
跑命令: StratusCommandExecutor
```

## 为什么要分这么多层

这些层的边界很重要:

| 层 | 不应该做什么 |
|---|---|
| Producer | 不应该理解 DAG 依赖 |
| Appender | 不应该执行 command |
| Consumer | 不应该解析参数和 module |
| Handler | 不应该知道具体业务命令 |
| Executor | 不应该关心消息从哪里来 |

边界清楚后,EMF 才能同时支持外部消息、动态生成消息、DAG ready 判断、命令插件化和 per-message DI scope。

## 并发不会破坏 DAG 依赖

并发只发生在 ready message 之间。也就是说:

```text
ParallelMessageConsumer 不会绕过 DagContext 的 ready 判断.
```

它只是把多个已经 ready 的节点放进线程池。依赖没满足的节点不会因为线程池有空位就被执行。

所以 EMF 的并发模型可以理解为:

```text
DAG 控制能不能执行;
Semaphore/Counter 控制同时执行多少;
batch_priority 控制谁先占用 slot.
```

更细一点看,一次消息执行大致是:

```text
ready vertex 被选中
  -> set_state(ACTIVE)
  -> 提交到线程池
  -> set_state(IN_PROGRESS)
  -> MessageHandler.handle(message)
  -> set_state(COMPLETE / RETRY / FAILED / TIMEOUT / CANCELLED)
```

状态更新不是装饰性日志,而是 DAG 推进的信号。一个节点完成后,它的 children 才有机会在下一轮 ready 判断中被选出来。

## Worker 模型的设计取舍

### 为什么 producer 和 consumer 要拆开

producer 负责“把外部世界的消息引入系统”,consumer 负责“在系统内部按 DAG 规则执行消息”。这两个节奏不同:

- 外部消息到达可能突发。
- DAG ready 节点数量取决于依赖和状态。
- command 执行时间可能很长。

拆开后,外部拉取、入队、内部调度可以独立演进。

### 为什么入队时就放入 DAG

如果只把消息放到普通 FIFO 队列,consumer 每次都要重新判断所有依赖。EMF 把消息加入 `DagManager`,让系统维护 graph state,后续只需要从 graph state 中找 ready vertices。

这就是“队列系统”和“工作流引擎”的差别:

```text
队列系统关心下一条消息是谁;
工作流引擎关心哪些节点现在满足依赖.
```

### 为什么单条消息要有独立 scope

命令执行可能依赖运行上下文、参数上下文、日志上下文和业务 service。单条消息有独立 scope 可以避免:

- 并发消息共享可变状态。
- 上一条消息的上下文泄漏。
- audit / trace / logging 混在一起。

面试时可以总结:

```text
Worker 层把外部消息接入、DAG 入队、ready 调度、命令执行这几件事拆开,核心是为了把吞吐、正确性和可扩展性分开治理。
```
