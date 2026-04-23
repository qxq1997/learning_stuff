# Kubernetes - 第 8 课：发布、回滚与扩缩容：滚动更新、HPA与稳定性保护

## 学习目标（本节结束后你能做到什么）

- 理解 Deployment 滚动更新的基本过程。
- 掌握 maxUnavailable、maxSurge、readinessProbe 对发布稳定性的影响。
- 理解回滚、HPA、PDB 的作用和边界。
- 能从生产视角分析一次发布为什么会导致短暂不可用。

## 内容讲解（核心概念，用类比、例子、图示说清楚。不要太提纲化，加强每一节深度，力求深度。）

发布是 Kubernetes 最贴近日常研发流程的能力之一。传统发布常常是脚本停止旧进程、替换包、启动新进程。这个过程如果没有负载均衡摘流、健康检查、批次控制，很容易出现短暂不可用。Kubernetes 的 Deployment 通过滚动更新，把发布变成一个可声明、可观察、可回滚的过程。

假设订单服务有 4 个旧版本 Pod，现在要从 `v1` 发布到 `v2`。Deployment 不会直接杀掉全部旧 Pod。它会创建新的 ReplicaSet，逐步拉起新 Pod；当新 Pod Ready 后，再逐步减少旧 Pod。这个过程中，新旧版本会短暂共存。Service 只把流量转给 Ready 的 Pod，所以 readinessProbe 是发布稳定性的关键。

```text
发布前：v1 v1 v1 v1
发布中：v1 v1 v1 v1 v2
继续：  v1 v1 v2 v2
完成：  v2 v2 v2 v2
```

`maxSurge` 和 `maxUnavailable` 控制滚动节奏。maxSurge 表示发布过程中最多可以额外创建多少 Pod；maxUnavailable 表示发布过程中最多允许多少 Pod 不可用。比如副本数 4，maxSurge=1，maxUnavailable=0，就表示最多临时有 5 个 Pod，并且发布过程中不能少于 4 个可用 Pod。这种策略更稳，但需要额外资源。相反，如果 maxUnavailable 较高，发布更快，但可用容量下降风险更大。

readinessProbe 会决定新 Pod 什么时候进入 Service 后端。如果新版本容器启动了，但数据库连接失败，readinessProbe 不通过，那么它不会接流量，Deployment 也可能卡住发布。这是好事，因为它阻止了坏版本快速扩散。反过来，如果没有 readinessProbe 或检查过于宽松，新 Pod 刚 Running 就接流量，可能造成用户请求失败。

回滚依赖 Deployment 的历史 ReplicaSet。发布新版本时，旧 ReplicaSet 通常会保留一定历史。发现新版本有问题，可以回滚到上一个版本。注意，回滚主要回滚 Pod 模板，比如镜像和环境配置，不一定回滚数据库 schema、外部依赖、消息格式。因此真正的生产发布要考虑向前兼容和向后兼容，不能只依赖 Kubernetes 回滚。

HPA 是 Horizontal Pod Autoscaler，负责根据指标自动调整副本数。最常见的是根据 CPU 使用率扩缩容，也可以基于自定义指标，比如 QPS、队列长度、延迟。HPA 的基本逻辑是：观察当前指标和目标指标的差距，计算期望副本数，然后修改 Deployment 的 replicas。

HPA 不是万能的。第一，它有反应时间，流量突然暴涨时，新 Pod 从调度、拉镜像、启动到 Ready 需要时间。第二，如果应用启动慢，扩容效果会滞后。第三，如果瓶颈在数据库、下游服务或锁竞争，盲目扩 Pod 可能会把下游压垮。第四，如果 requests 配置不合理，基于 CPU 使用率的 HPA 会失真。比如 request 很小，CPU 百分比很容易飙高；request 很大，扩容可能迟钝。

PDB 是 PodDisruptionBudget，用来限制自愿中断时的不可用数量。比如节点维护、集群升级、驱逐 Pod 时，PDB 可以声明“这个服务至少要保持 3 个可用副本”。它不能阻止机器突然宕机这种非自愿故障，但可以降低维护操作把服务一次性驱散的风险。

发布稳定性还需要和资源、调度、网络一起看。你设置 maxSurge=2，但集群没有额外资源，新 Pod 可能 Pending，发布卡住。你设置 readinessProbe，但探针路径依赖某个慢下游，发布时新 Pod 长时间不 Ready。你设置 HPA，但镜像很大，扩容时拉镜像耗时几分钟。Kubernetes 提供机制，但机制需要结合应用特性调参。

一次线上发布失败通常不是单点原因。比如一个 Java 服务发布后短暂 502，可能链路是：没有 startupProbe，livenessProbe 过早杀进程；readinessProbe 配置过宽，应用还没预热就接流量；maxUnavailable 允许过多旧 Pod 下线；新 Pod requests 过高导致调度慢；Ingress 超时时间又偏短。排查发布问题，要把发布过程当成时间线来看，而不是只看最后的错误码。

灰度和金丝雀也是发布体系的一部分。原生 Deployment 滚动更新适合按副本比例逐步替换，但更复杂的流量灰度通常需要 Ingress、Service Mesh 或专门发布系统支持，比如按 header、用户、地域、百分比切流。学习 Kubernetes 基础阶段，先理解滚动更新和 Ready 语义，再扩展到更高级灰度。

从工程角度，一个稳健发布至少要具备：健康检查准确、资源容量足够、发布批次可控、失败可停止、版本可回滚、监控能发现异常、数据库变更兼容。Kubernetes 能提供底座，但发布质量最终取决于应用、平台和流程共同设计。

## 小结（3-5 条关键点）

- Deployment 滚动更新通过新旧 ReplicaSet 逐步替换 Pod，避免一次性中断。
- maxSurge 控制额外副本，maxUnavailable 控制可用容量下降，两者影响发布速度和稳定性。
- readinessProbe 是新 Pod 是否接流量的关键，配置错误会直接影响发布质量。
- HPA 能自动扩缩副本，但受指标、启动时间、资源配置和下游瓶颈限制。
- PDB 能降低自愿中断带来的可用性风险，但不能阻止突发硬故障。

## 问题（检测你对当前章节内容是否了解）

1. 滚动更新期间为什么会同时存在新旧版本 Pod？
2. maxSurge=1、maxUnavailable=0 更偏稳定还是速度？代价是什么？
3. HPA 根据 CPU 扩容时，为什么 requests 配置会影响扩容判断？
4. Kubernetes 回滚为什么不能替代数据库变更的兼容性设计？
