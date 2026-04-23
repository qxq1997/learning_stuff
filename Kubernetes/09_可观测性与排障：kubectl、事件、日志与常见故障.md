# Kubernetes - 第 9 课：可观测性与排障：kubectl、事件、日志与常见故障

## 学习目标（本节结束后你能做到什么）

- 建立 Kubernetes 排障的分层思路，而不是只会重复重启 Pod。
- 掌握 get、describe、logs、events、exec 等常用 kubectl 观察手段。
- 能分析 Pending、CrashLoopBackOff、ImagePullBackOff、服务 502 等常见问题。
- 理解指标、日志、事件、链路追踪分别提供什么信息。

## 内容讲解（核心概念，用类比、例子、图示说清楚。不要太提纲化，加强每一节深度，力求深度。）

Kubernetes 排障最怕“盲修”。看到服务异常，第一反应就是删除 Pod、重启 Deployment，这有时能暂时恢复，但不会告诉你根因。正确方式是先确定问题发生在哪一层：对象是否存在，调度是否成功，容器是否启动，探针是否通过，Service 是否有后端，网络是否通，下游是否异常，资源是否不足。

`kubectl get` 用来快速看资源概览。比如 `kubectl get pods` 可以看到 Pod 状态、Ready 数量、重启次数和运行时间。`kubectl get deploy` 可以看到期望副本、可用副本。`kubectl get svc` 看 Service，`kubectl get endpoints` 看后端地址。get 像体检报告的摘要，能告诉你哪里不正常，但通常不够解释原因。

`kubectl describe` 是排障时最重要的命令之一。它会展示对象详细状态和事件。比如 Pod Pending 时，describe 的 Events 里可能写着 `Insufficient cpu`、`node(s) had untolerated taint`、`didn't match node selector`。CrashLoopBackOff 时，describe 可能看到容器退出码、重启次数、探针失败信息。很多初学者忽略 Events，结果靠猜排障。

`kubectl logs` 用来看容器标准输出。对于 CrashLoopBackOff，当前容器可能一直重启，你可能需要看上一次崩溃日志。日志解决的是“应用自己说了什么”。如果应用启动报数据库连接失败、配置文件缺失、端口占用、权限不足，日志通常最直接。但如果容器根本没启动起来，比如镜像拉取失败，日志可能没有，此时要看 describe 事件。

`kubectl exec` 可以进入容器执行命令，适合验证运行时环境，比如配置文件是否挂载、DNS 是否解析、端口是否监听、能否访问下游。但生产环境要谨慎使用 exec，不要把它当成常规变更手段。它更适合观察，不适合手工修状态。手工在容器里改文件，Pod 一重建就丢，而且不可审计。

事件 events 是 Kubernetes 控制面和节点组件留下的行为记录。它不是完整日志系统，但对资源状态变化非常有用。比如调度失败、拉镜像失败、探针失败、卷挂载失败，都会出现在事件里。排障时可以按时间顺序看事件，建立故障时间线。

常见故障之一是 Pending。Pending 说明 Pod 还没完全运行起来，可能是未调度，也可能是资源准备失败。排查顺序：看 describe 事件；看是否资源不足；看 nodeSelector/affinity 是否过严；看节点污点是否缺少 toleration；看 PVC 是否绑定；看镜像是否在拉取中。Pending 不应该先看业务日志，因为容器可能还没启动。

CrashLoopBackOff 表示容器反复崩溃后进入退避重启。常见原因包括应用启动失败、配置错误、依赖不可达、启动命令错误、内存 OOM、livenessProbe 误杀。排查时看 `logs --previous`、describe 里的退出码和事件、资源限制、探针配置。退出码 137 往往和 OOMKilled 有关，退出码 1 常常是应用自身错误，但仍要结合日志。

ImagePullBackOff 表示镜像拉取失败。原因可能是镜像名或 tag 错误、镜像仓库不可达、私有仓库认证 Secret 配错、节点网络访问失败、镜像不存在。这个问题通常和业务代码无关，优先看 describe 事件里的具体错误，比如 unauthorized、not found、i/o timeout。

服务 502 或请求失败要沿网络链路排查。首先看 Ingress Controller 是否有错误日志，Ingress 规则是否匹配；然后看 Service 是否存在、selector 是否匹配；再看 endpoints 是否有 Ready Pod；接着看 Pod readiness 是否通过、容器端口和 targetPort 是否一致；最后看应用日志和下游依赖。很多 502 的根因其实是 Service 没有可用 Endpoint。

资源问题也很常见。CPU 被 limit 限制会导致延迟升高，但不一定重启；内存超过 limit 可能 OOMKilled；磁盘压力可能触发驱逐；节点资源不足会导致 Pending。生产环境应配合 metrics-server、Prometheus、Grafana 等看 CPU、内存、网络、磁盘和 Pod 重启趋势。单次命令只能看到现场，指标系统能看到历史曲线。

日志、指标、事件、Trace 各自回答不同问题。日志回答“某个实例当时说了什么”；指标回答“系统整体趋势如何”；事件回答“Kubernetes 对对象做过什么”；Trace 回答“一次请求经过了哪些服务，慢在哪里”。成熟排障需要把这几类信号拼起来，而不是只依赖一种。

一个实用排障框架是：

```text
1. 看范围：单个 Pod、单个节点、整个服务、整个 namespace？
2. 看状态：get 看 Ready、Restart、Age、Available。
3. 看事件：describe 看调度、拉镜像、探针、挂载。
4. 看日志：logs 看应用启动和运行错误。
5. 看链路：Service/Endpoint/Ingress/DNS/NetworkPolicy。
6. 看资源：CPU、内存、磁盘、节点压力、HPA 变化。
7. 看变更：最近是否发布、改配置、改 Secret、改网络策略。
```

排障能力的本质是建立状态机思维。Pod 从创建到服务可用要经过 API 创建、调度、镜像拉取、卷挂载、容器启动、探针通过、Endpoint 更新、流量进入。哪一步失败，就去看负责那一步的对象和日志。这样你就不会被 Kubernetes 的对象数量吓住。

## 小结（3-5 条关键点）

- Kubernetes 排障要分层：对象、调度、容器、探针、Service、网络、资源、变更。
- get 看概览，describe 看状态和事件，logs 看应用输出，exec 做运行时验证。
- Pending 多从调度、资源、污点、亲和性、PVC 等方向排查。
- CrashLoopBackOff 要看 previous 日志、退出码、OOM、探针和启动配置。
- 事件、日志、指标、Trace 各自提供不同视角，成熟排障需要组合使用。

## 问题（检测你对当前章节内容是否了解）

1. Pod Pending 时，为什么第一步通常不是看业务日志？
2. CrashLoopBackOff 和 ImagePullBackOff 分别代表什么阶段的问题？
3. Service 存在但请求 502，你会如何沿链路排查？
4. 日志、事件、指标、Trace 分别适合回答什么问题？
