# 02 Worker 生命周期与启动模型

## 启动入口解决什么问题

Worker 启动阶段的核心问题不是“执行业务”,而是把一个普通进程组装成可以运行工作流的执行节点。

它要完成:

```text
配置加载
  -> 日志初始化
  -> DI 容器注册
  -> 核心组件解析
  -> 生命周期事件订阅
  -> 缓存预热
  -> producer / consumer 启动
```

这一步更像 composition root,不是业务入口。

## 启动阶段做了什么

主流程可以拆成八步:

1. 解析启动参数。
2. 加载参数和配置。
3. 创建 bootstrap logger。
4. 注册生产容器。
5. 解析 `IWorker`。
6. 订阅 DAG 和 run/batch 生命周期事件。
7. 预加载 `LoadInfo` cache。
8. 启动 worker。

## 启动不是业务逻辑

启动入口不应该被理解为业务入口。它更像 composition root:

```text
配置 -> 日志 -> 容器 -> 组件解析 -> 事件订阅 -> worker.start()
```

真正的业务执行不在这里。它只是把这些核心对象组装起来:

```text
IWorker
IMessageHandler
ICommandExecutor
IModuleProvider
IParallelMessageConsumer
IMessageParameterParser
IDagManager
IMessageAppender
```

## 为什么启动模型值得单独学

启动模型决定了系统边界:

1. 哪些组件是 worker 级单例。
2. 哪些组件是 message 执行时才创建。
3. producer 和 consumer 如何被组装起来。
4. run / batch 生命周期事件如何进入系统。
5. 配置和缓存什么时候准备好。

面试时可以说:

```text
Worker 启动入口本质上是 composition root,它不处理业务任务,而是把配置、日志、DI、生命周期事件和 producer/consumer 执行循环接起来。
```

## 启动后进入哪里

启动入口最终启动的是 `Worker`。`Worker` 本身很薄,主要职责是启动 producer 和 consumer。

也就是说:

```text
启动入口
  -> 解析和注册
  -> resolve IWorker
  -> worker.start()
  -> producer 拉消息
  -> consumer 调度执行
```

从这里往下,就进入真正的消息驱动模型。

## 设计取舍

### 为什么不在启动入口直接写业务逻辑

如果启动入口直接写业务逻辑,系统会很快变成:

```text
启动参数 + 配置 + 容器 + 拉消息 + 调度 + 业务执行 混在一起
```

这样会让测试、替换实现、隔离作用域都变困难。

EMF 把启动入口限制在“组装系统”,让后续组件各司其职:

| 组件 | 职责 |
|---|---|
| Producer | 接入外部消息 |
| Appender | 把消息加入运行时 DAG |
| Consumer | 找 ready 节点并并发调度 |
| Handler | 建立 message scope |
| Executor | 执行 command |

### 为什么启动时要订阅生命周期事件

EMF 不只是执行一条条消息,还要维护 run / batch 的生命周期。启动时订阅这些事件,意味着 worker 在运行过程中可以响应:

- DAG 状态变化。
- run 结束。
- batch 结束。
- timeout。
- cancel。

这让系统具备 workflow engine 的治理能力,而不是普通 consumer。
