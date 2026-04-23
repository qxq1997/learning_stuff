# Kubernetes - 第 5 课：调度与资源：requests、limits、亲和性、污点与驱逐

## 学习目标（本节结束后你能做到什么）

- 理解 Kubernetes 调度不是随机找机器，而是基于资源和约束做决策。
- 掌握 requests、limits 对调度、运行时限制和稳定性的影响。
- 理解 QoS、节点压力、驱逐之间的关系。
- 能解释 nodeSelector、亲和性、污点和容忍的常见使用场景。

## 内容讲解（核心概念，用类比、例子、图示说清楚。不要太提纲化，加强每一节深度，力求深度。）

调度是 Kubernetes 的核心能力之一。一个 Pod 创建出来后，并不会天然知道自己该跑在哪台机器。Scheduler 要根据节点资源、Pod 资源请求、亲和性规则、污点容忍、卷绑定、端口冲突等条件，选择一个合适节点。这个过程有点像给任务分配工位：不仅要看有没有空座，还要看这个任务需要什么设备、能不能和某些任务坐一起、是否不能进某些区域。

最基础的调度信号是 requests。你可以在容器里声明需要多少 CPU 和内存，例如 `cpu: 500m`、`memory: 512Mi`。这里的 CPU `500m` 表示 0.5 个 CPU 核心。Scheduler 会用 requests 来判断节点是否还有足够可分配资源。如果一个节点剩余可分配内存只有 300Mi，那么请求 512Mi 的 Pod 就不会被调度上去。

limits 则更像运行时上限。CPU limit 会影响容器最多能用多少 CPU，超过后会被限制；memory limit 更硬，容器使用内存超过 limit，通常会被 OOMKilled。requests 主要影响“能不能调度”，limits 主要影响“运行时最多能用多少”。当然两者也共同影响 QoS 等级。

很多线上问题来自 requests 和 limits 配置不合理。比如一个服务实际启动就需要 800Mi 内存，但 request 写 128Mi，Scheduler 可能把很多类似 Pod 塞到同一节点，看起来调度成功，实际运行后节点内存压力很大，开始驱逐 Pod。反过来，如果 request 写得过高，节点明明有实际空闲资源，但 Kubernetes 认为可分配资源不足，Pod 长期 Pending，集群利用率很低。

QoS 是 Kubernetes 根据 requests 和 limits 给 Pod 的服务质量分类，常见有 Guaranteed、Burstable、BestEffort。简单理解：

- Guaranteed：每个容器 CPU 和内存都设置 request 与 limit，且二者相等，稳定性最高。
- Burstable：设置了部分 request/limit，允许一定弹性，是最常见类型。
- BestEffort：没有设置 request/limit，资源紧张时最容易被驱逐。

当节点出现内存、磁盘等资源压力时，kubelet 会根据策略驱逐 Pod。不是所有 Pod 一视同仁，低 QoS、超出 request 较多、优先级低的 Pod 更容易被驱逐。因此生产环境中不设置资源请求是很危险的，它等于告诉调度器：“我不需要预留资源”，但真实运行时应用还是会消耗资源。

除了资源，调度还要表达位置偏好。nodeSelector 是最简单的方式：给节点打标签，比如 `disk=ssd`、`zone=shanghai-a`，Pod 声明只调度到带某个标签的节点。它简单直接，但表达能力有限。

亲和性 affinity 更灵活。Node affinity 表示 Pod 对节点的偏好或硬性要求，比如必须跑在 GPU 节点，或者优先跑在某个可用区。Pod affinity 表示希望和某些 Pod 靠近，比如缓存代理和业务服务放在同一区域。Pod anti-affinity 表示希望和某些 Pod 分散，比如同一个服务的多个副本不要都跑在同一台节点上，避免单节点故障导致全部副本消失。

污点 taint 和容忍 toleration 是另一套很有用的机制。污点是节点说：“我不欢迎普通 Pod 来。”容忍是 Pod 说：“我能接受这个污点。”比如你有一批专门跑数据库的节点，可以给节点打污点 `dedicated=db:NoSchedule`，普通业务 Pod 没有对应 toleration 就不会被调度过去。这样可以保护特殊节点资源。

```text
nodeSelector / affinity：Pod 主动表达“我想去哪”
taint / toleration：Node 主动表达“谁可以来”
```

这两套机制经常配合使用。比如 GPU 节点既有标签 `accelerator=gpu`，又有污点防止普通服务误调度。AI 推理 Pod 通过 node affinity 选择 GPU 节点，并通过 toleration 表示可以容忍 GPU 节点污点。这样资源隔离更清晰。

调度和稳定性之间的关系也很深。假设订单服务有 6 个副本，如果它们都被调度到同一台节点，一旦节点挂掉，订单服务会整体不可用。你可以通过 Pod anti-affinity 或 topology spread constraints 让副本分散到不同节点、不同可用区。Kubernetes 不会自动理解你的业务容灾目标，你需要通过调度约束把目标表达出来。

从排障角度，Pod Pending 很多时候不是 Kubernetes 坏了，而是调度条件无法满足。常见原因包括：CPU/内存 requests 太高、节点有污点但 Pod 没有 toleration、nodeSelector 标签不存在、PVC 绑定不到合适存储、亲和性规则过于苛刻。看到 Pending，第一步应该 `kubectl describe pod` 看 Events，里面通常会写明调度失败原因。

对后端工程师来说，资源配置不是运维细节，而是服务稳定性契约。你写 requests 是告诉平台“请至少为我预留这些资源”；写 limits 是告诉平台“我最多不应超过这些资源”。写得太随意，就会在发布高峰、流量突增、节点压力时变成线上事故。

## 小结（3-5 条关键点）

- requests 主要影响调度和资源预留，limits 主要影响运行时上限和 OOM 风险。
- QoS 会影响节点资源压力下的驱逐优先级，BestEffort 最脆弱。
- nodeSelector 和 affinity 用于表达 Pod 对节点或其他 Pod 的位置要求。
- taint 是节点拒绝普通 Pod 的机制，toleration 是 Pod 接受特殊节点的声明。
- Pod Pending 常常是资源或调度约束无法满足，应该优先查看 describe 事件。

## 问题（检测你对当前章节内容是否了解）

1. requests 和 limits 分别影响什么？为什么只写 limits 不写 requests 可能有问题？
2. BestEffort、Burstable、Guaranteed 哪个在资源紧张时更容易被驱逐？
3. node affinity 和 taint/toleration 分别从谁的角度表达调度约束？
4. 一个 Pod 长期 Pending，你会从哪些方向排查？
