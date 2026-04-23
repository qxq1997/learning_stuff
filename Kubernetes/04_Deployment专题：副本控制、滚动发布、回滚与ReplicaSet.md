# Kubernetes - 第 4 课：Deployment专题：副本控制、滚动发布、回滚与ReplicaSet

## 学习目标（本节结束后你能做到什么）

学完这一节，你应该能把 Deployment 当成一个“无状态服务发布控制系统”来理解，而不是只会写 `replicas` 和 `image`。

你应该能做到：

- 解释为什么生产环境很少直接创建裸 Pod，也很少直接操作 ReplicaSet，而是使用 Deployment。
- 说清 Deployment、ReplicaSet、Pod、Container 的层级关系。
- 理解 `selector`、`template.metadata.labels`、`PodTemplate`、`pod-template-hash` 的关系。
- 理解 Deployment 如何维持副本数：少了补、多了删、手工删 Pod 为什么会自动重建。
- 深入理解滚动发布：新 ReplicaSet 怎么创建，旧 ReplicaSet 怎么缩容，`maxSurge` 和 `maxUnavailable` 怎么影响可用性。
- 理解 readinessProbe 为什么会影响 Deployment 发布推进。
- 掌握 `rollout status`、`rollout history`、`rollout undo`、`pause`、`resume` 的使用语义。
- 理解 `revisionHistoryLimit`、`progressDeadlineSeconds`、`minReadySeconds`、`strategy` 等关键字段。
- 能排查 Deployment 常见问题：发布卡住、`ProgressDeadlineExceeded`、新 Pod 不 Ready、镜像拉取失败、selector 写错、旧 ReplicaSet 残留。
- 能解释 Deployment 不适合什么场景，为什么有状态服务要看 StatefulSet。

## 内容讲解（核心概念，用类比、例子、图示说清楚。不要太提纲化，加强每一节深度，力求深度。）

### 1. Deployment 解决的不是“启动 Pod”，而是“长期管理一组无状态 Pod”

第 3 章讲过，Pod 是 Kubernetes 的运行原子。但生产环境里，你通常不会直接创建裸 Pod。

为什么？

因为裸 Pod 太脆弱。

假设你直接创建一个订单服务 Pod：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: order-pod
spec:
  containers:
    - name: order
      image: order:v1
```

它确实可以跑起来。但问题马上出现：

- 这个 Pod 被误删了，谁补回来？
- 节点宕机了，这个 Pod 怎么迁移？
- 我要 6 个副本，难道手写 6 个 Pod？
- 我要扩容到 10 个，谁创建新 Pod？
- 我要发布 `order:v2`，怎么逐步替换？
- 新版本有问题，怎么回滚？
- 发布过程中至少保留多少可用副本？
- 历史版本怎么记录？

裸 Pod 表达的是“一次具体运行实例”。它不表达“长期保持多少个实例”，也不表达“怎么发布新版本”。

Deployment 解决的就是这个问题。

```text
Pod：
一次具体运行实例。

Deployment：
长期维持一组无状态 Pod，并管理它们的发布、扩缩容和回滚。
```

所以 Deployment 不是“Pod 的 YAML 外面套一层壳”。它是 Kubernetes 里最常用的无状态服务控制器。

对于后端工程师来说，Deployment 对应的就是你最熟悉的服务类型：

- Java Spring Boot API 服务。
- Go HTTP/RPC 服务。
- Python/FastAPI 服务。
- Node.js 后端服务。
- 网关服务。
- worker 服务，只要它本身不需要稳定身份和本地持久数据。

只要单个实例是可替换的，挂掉一个换一个不会丢业务数据，通常就适合 Deployment。

### 2. Deployment、ReplicaSet、Pod、Container 的层级关系

Deployment 并不直接运行容器。它通过 ReplicaSet 管理 Pod，Pod 里再运行 Container。

关系是：

```text
Deployment
  -> ReplicaSet
    -> Pod
      -> Container
```

更准确一点：

```text
Deployment：管理版本和发布策略。
ReplicaSet：管理某一个版本的 Pod 副本数量。
Pod：一次具体运行实例。
Container：真正的业务进程。
```

一次正常部署可能是：

```text
Deployment/order-service
└── ReplicaSet/order-service-7b9f8d6c9
    ├── Pod/order-service-7b9f8d6c9-a1
    ├── Pod/order-service-7b9f8d6c9-b2
    └── Pod/order-service-7b9f8d6c9-c3
```

当你发布新镜像 `order:v2` 时，Deployment 会创建新的 ReplicaSet：

```text
Deployment/order-service
├── ReplicaSet/order-service-7b9f8d6c9   # 旧版本 v1
│   ├── Pod ...
│   └── Pod ...
└── ReplicaSet/order-service-58cc77d4d   # 新版本 v2
    ├── Pod ...
    └── Pod ...
```

旧 ReplicaSet 和新 ReplicaSet 会在滚动发布期间同时存在。发布完成后，新 ReplicaSet 承担全部副本，旧 ReplicaSet 通常保留一段历史，用于回滚。

这解释了一个常见现象：

```bash
kubectl get rs
```

你可能看到同一个 Deployment 下面有多个 ReplicaSet，有的副本数是 0。这不是异常，通常是历史版本。

### 3. 为什么通常不直接操作 ReplicaSet

ReplicaSet 的职责很单一：保证某一组 Pod 的副本数量。

它不关心复杂发布策略，也不提供完整版本管理体验。Deployment 在 ReplicaSet 上面增加了发布控制能力。

可以这样理解：

```text
ReplicaSet：
我负责让 label 匹配的一组 Pod 保持 N 个。

Deployment：
我负责决定当前应该有哪个版本的 ReplicaSet，
如何从旧 ReplicaSet 迁移到新 ReplicaSet，
如何记录历史、暂停、继续、回滚。
```

所以日常操作应该面向 Deployment，而不是直接面向 ReplicaSet。

比如扩容：

```bash
kubectl scale deployment order-service --replicas=6
```

而不是：

```bash
kubectl scale replicaset order-service-xxx --replicas=6
```

因为如果你直接改 ReplicaSet，Deployment Controller 下一轮调谐可能会把它改回期望状态。上层控制器才是长期期望的来源。

这也是 Kubernetes 学习里一个通用原则：

```text
谁拥有这个对象，就改谁。
```

Pod 归 ReplicaSet 管，ReplicaSet 归 Deployment 管。你要改变服务副本数、镜像版本、发布策略，就应该改 Deployment。

### 4. 一个 Deployment YAML 到底表达了什么

看一个相对完整的 Deployment：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
  labels:
    app: order
spec:
  replicas: 4
  revisionHistoryLimit: 5
  progressDeadlineSeconds: 600
  minReadySeconds: 10
  selector:
    matchLabels:
      app: order
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: order
        version: v1
    spec:
      terminationGracePeriodSeconds: 30
      containers:
        - name: order
          image: registry.example.com/order:v1
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              memory: "1Gi"
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: 8080
            initialDelaySeconds: 60
            periodSeconds: 10
```

这份 YAML 不是“创建 4 个容器”这么简单。它表达的是：

```text
我希望集群里长期存在一个名为 order-service 的 Deployment。
它管理 app=order 这组 Pod。
期望副本数是 4。
Pod 模板里使用 order:v1 镜像。
发布时使用 RollingUpdate。
最多额外创建 1 个 Pod。
发布过程中不允许可用副本少于期望副本数。
新 Pod Ready 后至少稳定 10 秒，才算可用。
如果 600 秒还没有推进成功，认为发布进展失败。
保留最多 5 个历史 ReplicaSet。
```

读 Deployment YAML 时，重点看这几块：

- `replicas`：期望副本数。
- `selector`：Deployment 管理哪些 Pod。
- `template`：新 Pod 长什么样。
- `strategy`：怎么从旧版本切到新版本。
- `revisionHistoryLimit`：保留多少历史版本。
- `progressDeadlineSeconds`：发布多久没进展算失败。
- `minReadySeconds`：Pod Ready 后稳定多久才算 available。

### 5. selector 和 template labels：Deployment 最容易踩的底层契约

Deployment 的 `selector` 和 `template.metadata.labels` 必须匹配。

比如：

```yaml
spec:
  selector:
    matchLabels:
      app: order
  template:
    metadata:
      labels:
        app: order
```

Deployment 通过 selector 找到自己应该管理的 Pod。ReplicaSet 也依赖 selector 管理 Pod。Service 也常用 selector 选择 Pod。

如果 Deployment selector 是：

```yaml
selector:
  matchLabels:
    app: order
```

但 template labels 写成：

```yaml
labels:
  app: orders
```

那 Deployment 创建出来的 Pod 不匹配自己的 selector，这在 `apps/v1` 里通常会被 API 校验拦住。

为什么 Kubernetes 对这个非常严格？

因为 selector 是控制器认领 Pod 的边界。如果 selector 写错，控制器可能：

- 找不到自己创建的 Pod。
- 错误认领别人创建的 Pod。
- 删除不该删除的 Pod。
- 副本数计算混乱。

所以 Deployment 的 `.spec.selector` 是不可变字段。创建后通常不能随便改。

这是一个关键原则：

```text
selector 是控制器和 Pod 之间的管理契约。
不要把它当成普通标签随意调整。
```

如果你只是想给 Pod 增加新标签，用于日志、监控、版本标识，可以加在 `template.metadata.labels` 里，但要小心不要破坏 selector 匹配关系。

### 6. PodTemplate：为什么改 template 会触发新版本

Deployment 里的 `spec.template` 是 PodTemplate，也就是新 Pod 的模板。

它包含：

- Pod labels。
- 容器镜像。
- 容器命令。
- 环境变量。
- 资源配置。
- 探针。
- Volume 挂载。
- 安全上下文。
- 调度约束。

Deployment Controller 会根据 PodTemplate 计算一个 hash，常见标签是：

```text
pod-template-hash=7b9f8d6c9
```

这个 hash 会出现在 ReplicaSet 和 Pod 的 label 里，用来区分不同版本。

只要 PodTemplate 发生变化，就会触发新的 ReplicaSet。

比如这些变化都会触发滚动发布：

- 镜像从 `order:v1` 改成 `order:v2`。
- 增加环境变量。
- 修改 readinessProbe。
- 修改 resources。
- 修改 volumeMount。
- 修改 template labels。

但只改 Deployment 自己的 metadata labels，不一定触发新 ReplicaSet。因为它不是 PodTemplate。

这个区别很重要：

```text
改 spec.template：
影响新 Pod 长什么样，触发新 ReplicaSet。

改 Deployment metadata：
只改 Deployment 对象自己的元数据，通常不触发 Pod 更新。
```

如果你想强制重启 Deployment，但镜像没有变化，可以用：

```bash
kubectl rollout restart deployment order-service
```

它本质上会修改 PodTemplate 上的 annotation，从而触发新 ReplicaSet。

### 7. Deployment 如何维持副本数

Deployment 不直接创建 Pod，它通过 ReplicaSet 维持副本数。

假设：

```yaml
replicas: 4
```

当前只有 3 个 Ready Pod。ReplicaSet Controller 会发现当前 Pod 数量不满足期望，然后创建新的 Pod。

如果你手工删除一个 Pod：

```bash
kubectl delete pod order-service-xxx
```

你很快会看到一个新 Pod 出现。

这不是 Pod “复活”，而是控制器重新创建了一个新 Pod：

```text
你删除 Pod
  -> ReplicaSet 发现当前副本数从 4 变 3
  -> ReplicaSet 创建一个新 Pod
  -> Scheduler 调度新 Pod
  -> kubelet 启动新 Pod
```

所以在 Deployment 管理的服务里，删除 Pod 是一种“让它重建”的操作，不是缩容。

真正缩容要改 Deployment：

```bash
kubectl scale deployment order-service --replicas=2
```

或者修改 YAML：

```yaml
spec:
  replicas: 2
```

再 apply。

这就是第 2 章讲过的控制器调谐：

```text
spec.replicas 是期望状态。
当前 Pod 数量是真实状态。
ReplicaSet Controller 持续让真实状态接近期望状态。
```

### 8. Deployment 的发布不是“替换 Pod”，而是“新旧 ReplicaSet 协同伸缩”

滚动发布是 Deployment 最核心的能力之一。

假设当前订单服务是：

```text
replicas = 4
image = order:v1
```

当前结构：

```text
Deployment/order-service
└── ReplicaSet v1
    ├── Pod v1-a
    ├── Pod v1-b
    ├── Pod v1-c
    └── Pod v1-d
```

现在你把镜像改成：

```yaml
image: order:v2
```

Deployment Controller 会创建新的 ReplicaSet：

```text
Deployment/order-service
├── ReplicaSet v1
│   ├── Pod v1-a
│   ├── Pod v1-b
│   ├── Pod v1-c
│   └── Pod v1-d
└── ReplicaSet v2
```

然后按照滚动策略逐步：

```text
扩大新 ReplicaSet
缩小旧 ReplicaSet
等待新 Pod Ready
继续下一轮
```

也就是说，滚动发布不是“原地修改旧 Pod 镜像”。Pod 的 spec 大部分字段不可变，Kubernetes 通常会创建新 Pod，删除旧 Pod。

发布过程可以简化成：

```text
开始：
v1 v1 v1 v1

创建 1 个新 Pod：
v1 v1 v1 v1 v2

v2 Ready 后删除 1 个旧 Pod：
v1 v1 v1 v2

继续：
v1 v1 v2 v2
v1 v2 v2 v2
v2 v2 v2 v2
```

这里的节奏由 `maxSurge` 和 `maxUnavailable` 控制。

### 9. maxSurge 和 maxUnavailable：发布速度与可用性的取舍

Deployment 的 RollingUpdate 有两个核心参数：

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1
    maxUnavailable: 0
```

`maxSurge` 表示发布过程中最多可以比期望副本数多出来多少 Pod。

`maxUnavailable` 表示发布过程中最多允许多少个 Pod 不可用。

假设 `replicas=4`。

如果：

```yaml
maxSurge: 1
maxUnavailable: 0
```

表示：

```text
总 Pod 数最多 5 个。
可用 Pod 数不能少于 4 个。
```

这种策略偏稳定。它会先多创建一个新 Pod，等新 Pod Ready 后，再删除旧 Pod。代价是需要额外资源。如果集群资源不足，新 Pod 可能 Pending，发布卡住。

如果：

```yaml
maxSurge: 0
maxUnavailable: 1
```

表示：

```text
总 Pod 数最多 4 个。
允许可用 Pod 暂时少 1 个。
```

这种策略不需要额外资源，但发布期间容量会下降。流量高峰时可能有风险。

如果比例写法：

```yaml
maxSurge: 25%
maxUnavailable: 25%
```

Kubernetes 会根据 replicas 计算数量，并处理取整。比例适合副本数较多的服务。

发布策略本质是在平衡：

```text
更稳定：需要更多额外资源，发布可能慢。
更省资源：可用容量下降，发布风险更高。
```

对于核心线上服务，常见偏稳配置是：

```yaml
maxSurge: 1
maxUnavailable: 0
```

但这不是银弹。如果每个 Pod 很重，额外创建一个 Pod 就需要很多资源；如果副本数很大，`1` 可能太慢。最终要结合服务容量、启动速度、资源池余量和发布系统设计。

### 10. readinessProbe 如何影响 Deployment 发布推进

Deployment 不是看到新 Pod Running 就认为它可用了。它会根据 Pod Ready 和 available 状态推进。

这就是第 3 章 Pod 探针和 Deployment 的连接点。

假设新 Pod 已经启动进程：

```text
order-v2-pod   0/1   Running
```

它 Running，但 readinessProbe 还没通过，所以不是 Ready。此时 Service 不应该把流量打给它，Deployment 也不会把它当成 available 副本。

只有变成：

```text
order-v2-pod   1/1   Running
```

并且满足 `minReadySeconds` 后，Deployment 才会把它计入 available。

如果 readinessProbe 一直失败，发布会卡住：

```text
新 ReplicaSet 创建了 Pod
Pod Running 但 NotReady
Deployment 不敢继续缩旧 Pod
rollout status 一直等待
最终可能 ProgressDeadlineExceeded
```

所以 readinessProbe 是滚动发布稳定性的核心。

没有 readinessProbe 会怎样？

Kubernetes 可能认为容器启动就是 Ready，过早把流量打给新 Pod。对于启动慢的 Java 服务，这很容易导致短暂 502、超时或业务错误。

readinessProbe 配太严格又会怎样？

新 Pod 长时间 NotReady，发布卡住。更糟的是，如果 readinessProbe 依赖某个不稳定下游，大量 Pod 可能同时摘流，造成服务可用容量下降。

所以 Deployment 发布是否稳定，不只是 Deployment 字段决定，也取决于 PodTemplate 里的 probe 设计。

### 11. minReadySeconds：Ready 后再等一会儿

`minReadySeconds` 表示新 Pod Ready 后，至少稳定多少秒，才认为它 available。

例如：

```yaml
minReadySeconds: 10
```

意思是：

```text
Pod Ready=True 后，还要持续 10 秒不掉 Ready，才算 available。
```

它可以防止一种情况：Pod 刚 Ready 一瞬间就被计入可用，Deployment 立刻删除旧 Pod，但新 Pod 很快又 NotReady。

对于启动后需要短暂预热、缓存加载、JIT 编译的服务，`minReadySeconds` 可以增加一点安全垫。

但设置过大也会拖慢发布。比如副本很多、每个 Pod 都要等 60 秒，发布会明显变慢。

### 12. progressDeadlineSeconds：发布多久没进展算失败

`progressDeadlineSeconds` 表示 Deployment 发布在多长时间内没有取得进展，就标记为失败。

例如：

```yaml
progressDeadlineSeconds: 600
```

如果 600 秒内新 ReplicaSet 没有成功推进，比如新 Pod 一直不 Ready，Deployment condition 可能出现：

```text
Progressing=False
Reason=ProgressDeadlineExceeded
```

这并不一定会自动回滚。它表示 Kubernetes 判断发布进展失败，告诉你要介入排查。

常见原因：

- 新镜像拉取失败。
- 新 Pod 启动崩溃。
- readinessProbe 配错。
- resources 太高导致 Pending。
- PVC/ConfigMap/Secret 挂载失败。
- 应用启动很慢，deadline 太短。
- 集群资源不足，maxSurge 创建不出新 Pod。

所以看到 `ProgressDeadlineExceeded`，不要只盯 Deployment。要沿着新 ReplicaSet 的 Pod 看状态和事件。

### 13. revisionHistoryLimit：保留多少历史 ReplicaSet

Deployment 会保留历史 ReplicaSet，用于回滚。

字段：

```yaml
revisionHistoryLimit: 5
```

表示最多保留 5 个历史 revision。旧 ReplicaSet 通常副本数为 0，但对象还在，记录着旧 PodTemplate。

查看历史：

```bash
kubectl rollout history deployment order-service
```

回滚到上一个版本：

```bash
kubectl rollout undo deployment order-service
```

回滚到指定版本：

```bash
kubectl rollout undo deployment order-service --to-revision=3
```

注意，Deployment 回滚只回滚 PodTemplate 层面的内容，比如镜像、环境变量、探针、资源配置等。

它不会自动回滚：

- 数据库 schema。
- 外部配置中心。
- MQ 消息格式。
- 下游接口兼容性。
- 手工改过的外部资源。

所以真正的生产回滚必须考虑数据和协议兼容。不要以为 `rollout undo` 可以解决所有发布事故。

### 14. rollout status、history、undo：Deployment 的发布操作语言

几个常用命令要理解语义。

查看发布状态：

```bash
kubectl rollout status deployment order-service
```

它会等待 Deployment 发布完成，或者报告卡住。

查看历史：

```bash
kubectl rollout history deployment order-service
```

查看某个 revision 详情：

```bash
kubectl rollout history deployment order-service --revision=3
```

回滚：

```bash
kubectl rollout undo deployment order-service
```

暂停发布：

```bash
kubectl rollout pause deployment order-service
```

继续发布：

```bash
kubectl rollout resume deployment order-service
```

重启：

```bash
kubectl rollout restart deployment order-service
```

`rollout restart` 很常用。比如 ConfigMap 内容变了，但你的应用不支持热加载，你想让 Pod 重建读取新配置。它会修改 PodTemplate annotation，触发新的 ReplicaSet。

但要小心：如果多个变更连在一起做，history 里看到的 revision 可能不够直观。生产发布最好通过 CI/CD 或 GitOps 管理变更来源，而不是大量手工命令。

### 15. pause/resume：为什么需要暂停发布

Deployment 支持 pause 和 resume。

暂停后，你可以对 Deployment 做多次修改，但不立即触发新的 rollout。等 resume 后，再一次性推进。

例如：

```bash
kubectl rollout pause deployment order-service
kubectl set image deployment/order-service order=order:v2
kubectl set resources deployment/order-service -c order --limits=memory=2Gi
kubectl rollout resume deployment order-service
```

这样可以把多个 PodTemplate 变更合并成一次发布。

不过生产里更常见的是通过 Git 提交一次完整变更，而不是手工 pause/resume。理解这个机制有助于你读懂 Deployment 的发布状态。

### 16. Recreate 策略：为什么默认不是它

Deployment strategy 有两种主要类型：

```yaml
strategy:
  type: RollingUpdate
```

或者：

```yaml
strategy:
  type: Recreate
```

RollingUpdate 是默认策略。它逐步创建新 Pod、删除旧 Pod。

Recreate 则是先删除所有旧 Pod，再创建新 Pod。

```text
Recreate：
v1 v1 v1 v1
全部删除
空窗
v2 v2 v2 v2
```

这会带来服务中断，所以无状态在线服务一般不使用 Recreate。

什么时候可能用？

- 应用不允许新旧版本同时存在。
- 本地独占资源不允许两个版本并行。
- 非在线服务，短暂停机可以接受。

但如果你的服务不能新旧版本共存，更应该反思接口、数据库和协议兼容设计。现代在线系统通常追求滚动发布能力。

### 17. Deployment 和 Service 的关系：Deployment 管 Pod，Service 管访问

Deployment 不负责流量入口。

它只负责：

```text
创建和管理一组 Pod。
```

Service 负责：

```text
给这组 Ready Pod 提供稳定访问入口。
```

两者通过 label/selector 间接连接。

Deployment PodTemplate：

```yaml
template:
  metadata:
    labels:
      app: order
```

Service：

```yaml
spec:
  selector:
    app: order
```

这表示 Service 会选择 Deployment 创建的 Pod。

但 Deployment 本身不知道 Service，Service 也不归 Deployment 拥有。它们只是通过 label 对上。

这带来灵活性，也带来风险：

- label 写对，Service 自动找到新旧 Pod。
- label 写错，Service 没后端。
- 发布时新 Pod NotReady，Service 不转发到它。
- 删除 Deployment，Service 可能还在，但后端变空。

所以第 5 章 Service 专题会继续深挖这条链路。这里先记住：

```text
Deployment 控制副本和发布。
Service 控制稳定访问和流量转发。
readinessProbe 决定 Pod 是否进入 Service 后端。
```

### 18. Deployment 不适合有状态服务的核心原因

Deployment 适合无状态服务。

所谓无状态，不是说服务不访问数据库，而是说单个 Pod 本身没有不可替代的身份和本地持久数据。

订单 API 服务访问 MySQL，但订单数据存在 MySQL 里。任意一个订单 Pod 挂了，换一个 Pod 继续连 MySQL 就行。这个服务适合 Deployment。

但数据库实例不同。比如 MySQL、Kafka、ZooKeeper 这类服务，实例身份和数据目录很重要：

- `mysql-0` 和 `mysql-1` 可能角色不同。
- 每个实例绑定自己的数据盘。
- 启停顺序可能有要求。
- 网络名需要稳定。
- 扩缩容不能随便替换。

Deployment 创建的 Pod 更像一组可互换副本。它不提供稳定序号、稳定网络身份、稳定 PVC 绑定。这个场景应该看 StatefulSet。

所以不要简单说：

```text
用了数据库就是有状态服务。
```

正确说法是：

```text
服务 Pod 本身是否保存不可替代状态？
实例身份是否重要？
本地持久数据是否和实例绑定？
```

如果答案是否，通常可以用 Deployment。如果答案是，就要考虑 StatefulSet 或 Operator。

### 18.1 和其他工作负载的边界：为什么旧版“工作负载总览”要拆开

旧版第四章把 Deployment、StatefulSet、DaemonSet、Job 放在同一章里讲，这样能快速建立全景，但问题是每个对象都讲不深。现在把它们拆成独立专题，不是因为它们没关系，而是因为它们表达的是完全不同的生命周期语义。

可以用一个问题判断：

```text
这个 Pod 为什么存在？
```

如果答案是：

```text
为了长期提供一个可水平扩展的无状态服务。
实例之间基本可替换。
发布时希望新旧版本滚动切换。
```

那就是 Deployment 的主场。

如果答案是：

```text
每个实例都有稳定身份。
实例名、网络名、数据盘和顺序都重要。
例如 mysql-0、mysql-1、kafka-0、zk-2。
```

那更接近 StatefulSet。

如果答案是：

```text
每台符合条件的节点上都要跑一个副本。
新增节点时自动补一个，删除节点时自然消失。
```

那是 DaemonSet，比如日志采集 Agent、节点监控 Agent、CNI 插件、安全 Agent。

如果答案是：

```text
这个 Pod 不是长期服务，而是运行完就结束。
成功完成比长期存活更重要。
```

那是 Job。按时间周期运行的 Job，则是 CronJob。

所以工作负载不是按“YAML 长得像不像”分类，而是按“生命周期和身份语义”分类：

| 工作负载 | 核心语义 | 典型场景 |
| --- | --- | --- |
| Deployment | 管理一组可替换的无状态副本 | API 服务、RPC 服务、网关、worker |
| StatefulSet | 管理有稳定身份和存储关系的实例 | 数据库、Kafka、ZooKeeper、部分中间件 |
| DaemonSet | 每个节点一个 Pod | 日志、监控、网络、安全节点代理 |
| Job | 一次性任务，成功完成即可 | 数据迁移、批处理、离线任务 |
| CronJob | 定时创建 Job | 定时报表、周期同步、清理任务 |

这里还有一个非常常见的误区：依赖数据库的服务不等于有状态服务。

订单 API 服务会访问 MySQL，但订单数据保存在 MySQL，不保存在订单 Pod 本地。订单 Pod 是可替换的，所以它仍然适合 Deployment。

真正有状态的是 MySQL 实例本身，因为它的数据目录、实例身份、复制关系、恢复流程都不能随意替换。

这一章聚焦 Deployment，因为它是后端无状态服务的日常主力。StatefulSet、DaemonSet、Job/CronJob 后续会单独成章，否则很容易把“稳定身份”“每节点一个”“运行完成”这些关键语义讲浅。

### 19. 常见 Deployment 故障一：发布卡在 ProgressDeadlineExceeded

现象：

```bash
kubectl rollout status deployment order-service
```

长时间等待，最后看到类似：

```text
error: deployment "order-service" exceeded its progress deadline
```

或 describe 里看到：

```text
Progressing  False  ProgressDeadlineExceeded
```

排查路线：

```bash
kubectl describe deployment order-service
kubectl get rs -l app=order
kubectl get pod -l app=order
kubectl describe pod <new-pod>
```

重点看新 ReplicaSet 的 Pod：

- 是 Pending 吗？看调度、资源、污点、PVC。
- 是 ImagePullBackOff 吗？看镜像名、tag、仓库权限。
- 是 CrashLoopBackOff 吗？看应用日志、OOM、启动参数。
- 是 Running 但 NotReady 吗？看 readinessProbe。
- 是 ContainerCreating 吗？看 CNI、CSI、ConfigMap、Secret。

Deployment 的错误通常只是“发布没推进”。根因大多在新 Pod。

### 20. 常见 Deployment 故障二：新版本已启动但流量仍有问题

发布完成不等于业务一定没问题。

可能出现：

- readinessProbe 太宽松，Pod 过早接流量。
- 应用健康接口返回成功，但核心业务接口失败。
- 新旧版本同时存在时，协议不兼容。
- 数据库 schema 和旧版本不兼容。
- 缓存 key 格式变化导致旧实例读不了。
- 消息格式变化导致消费者异常。

Deployment 只能管理 PodTemplate 和副本切换。它无法理解你的业务兼容性。

所以生产发布要遵守：

```text
先兼容，再发布，再清理。
```

比如数据库变更通常要分阶段：

```text
1. 先加新字段，保持旧代码可用。
2. 发布新代码，开始写新字段。
3. 验证稳定后，再删除旧字段或旧逻辑。
```

不要指望 Deployment 回滚能解决不兼容 schema 带来的数据问题。

### 21. 常见 Deployment 故障三：手工改 Pod 不生效或很快丢失

有时有人进入 Pod 手工改文件：

```bash
kubectl exec -it order-pod -- sh
vi /app/config.yaml
```

这类修改通常不可靠。

原因：

- Pod 重启后本地修改可能丢失。
- 新 Pod 会按 Deployment template 重新创建，不包含手工改动。
- 多副本时你只改了一个 Pod，其他 Pod 没改。
- 修改不可审计，无法回滚。

正确方式是修改源头：

- 镜像内容错了，重新构建镜像并更新 Deployment。
- 配置错了，修改 ConfigMap/Secret 并触发重启或热加载。
- 资源配置错了，修改 Deployment resources。
- 启动参数错了，修改 Deployment PodTemplate。

Deployment 的核心就是让 Pod 从 template 生成。你绕过 template 改 Pod，就和控制器模型冲突。

### 22. 常见 Deployment 故障四：selector 或 labels 设计混乱

Deployment、ReplicaSet、Service 都依赖 labels/selectors。

如果设计混乱，会出现非常隐蔽的问题。

比如多个 Deployment 使用了同样的 selector：

```yaml
selector:
  matchLabels:
    app: order
```

但它们其实代表不同服务或不同环境。这样控制器可能互相干扰。

推荐做法是给 label 设计清晰维度：

```yaml
labels:
  app.kubernetes.io/name: order-service
  app.kubernetes.io/instance: order-prod
  app.kubernetes.io/version: v1
  app.kubernetes.io/component: api
  app.kubernetes.io/part-of: ecommerce
```

selector 应该选择稳定身份标签，比如服务名和实例名；版本标签通常不应该作为 Service selector 的唯一条件，否则滚动发布时 Service 可能只选到某一版。

比如 Service selector：

```yaml
selector:
  app.kubernetes.io/name: order-service
  app.kubernetes.io/component: api
```

Pod 版本标签：

```yaml
app.kubernetes.io/version: v2
```

这样 Service 可以在滚动发布期间同时选择 v1 和 v2 的 Ready Pod。

### 23. 常见 Deployment 故障五：资源不足导致发布卡住

如果你配置：

```yaml
replicas: 4
strategy:
  rollingUpdate:
    maxSurge: 1
    maxUnavailable: 0
```

发布时需要额外创建 1 个 Pod。

如果集群资源不足，这个新 Pod 可能 Pending：

```text
0/5 nodes are available: 5 Insufficient memory
```

由于 `maxUnavailable=0`，Deployment 又不能先删旧 Pod 释放资源，于是发布卡住。

解决思路：

- 增加节点资源。
- 降低 Pod requests。
- 临时调整 `maxUnavailable`，允许先下一个旧 Pod。
- 分批发布或低峰发布。
- 检查是否有资源配额限制。

这里体现了发布策略和资源调度的耦合。稳定策略需要资源余量，没有余量就会卡住。

### 24. 常见 Deployment 故障六：旧 ReplicaSet 为什么还在

发布完成后，你看到：

```bash
kubectl get rs
```

有多个 ReplicaSet：

```text
order-service-7b9f8d6c9   0   0   0
order-service-58cc77d4d   4   4   4
```

旧 ReplicaSet 副本数是 0，但对象还在。这通常是正常的。它用于保存历史 revision，支持回滚。

保留数量由：

```yaml
revisionHistoryLimit: 5
```

控制。

如果设置太小，回滚历史有限；设置太大，对象变多但通常影响不大。生产中保留几个历史版本即可，真正的版本来源应该在镜像仓库和 Git 里。

### 25. Deployment 的扩缩容和 HPA 的关系

手工扩缩容可以直接改：

```yaml
spec:
  replicas: 6
```

或：

```bash
kubectl scale deployment order-service --replicas=6
```

但如果启用了 HPA，HPA 会根据指标修改 Deployment 的 replicas。

这时你手工改 replicas 可能很快被 HPA 改回来。

关系是：

```text
Deployment：
根据 replicas 维持 Pod 数量。

HPA：
根据指标计算期望副本数，并更新 Deployment replicas。
```

所以启用 HPA 后，副本数的长期来源变成 HPA。Deployment 仍然执行副本维持，但期望值由 HPA 动态调整。

这也是 Kubernetes 控制器叠加的典型例子：一个控制器管理另一个对象的 spec，另一个控制器再根据 spec 管理下级对象。

### 26. Deployment 的面试表达

如果面试问：“Deployment 是什么？它和 ReplicaSet、Pod 什么关系？”

可以这样回答：

```text
Deployment 是 Kubernetes 用来管理无状态服务的工作负载控制器。
它不直接运行容器，而是通过 ReplicaSet 管理 Pod。

Deployment 负责声明期望副本数、PodTemplate 和发布策略。
当 PodTemplate 变化时，Deployment 会创建新的 ReplicaSet，并按照 rollingUpdate 策略逐步扩新 ReplicaSet、缩旧 ReplicaSet。
ReplicaSet 负责保证某个版本的 Pod 副本数，Pod 才是真正被调度到节点上运行容器的实例。

Deployment 支持滚动更新、回滚、暂停、继续、历史版本保留等能力。
发布是否能推进，取决于新 Pod 是否能成功创建并 Ready，readinessProbe 会影响新 Pod 是否计入 available。
```

如果继续问：“为什么不直接用 ReplicaSet？”

可以回答：

```text
ReplicaSet 只负责副本数量，不负责完整发布语义。
Deployment 在 ReplicaSet 之上提供版本管理、滚动更新、回滚和 rollout 状态。
日常应该操作 Deployment，让它控制 ReplicaSet 和 Pod。
```

如果问：“Deployment 回滚能解决所有发布问题吗？”

可以回答：

```text
不能。Deployment 回滚主要回滚 PodTemplate，比如镜像、环境变量、探针和资源配置。
它不能自动回滚数据库 schema、外部配置、消息格式、下游接口兼容性和已经写入的数据。
所以生产发布仍然需要兼容性设计和分阶段变更。
```

### 27. 本章心智模型

Deployment 可以压缩成一句话：

```text
Deployment 是无状态服务的期望状态控制器，
它通过管理多个版本的 ReplicaSet，
实现副本维持、滚动发布和回滚。
```

更完整的链路是：

```text
你修改 Deployment spec
  -> Deployment Controller 观察到 PodTemplate 变化
  -> 创建新的 ReplicaSet
  -> 新 ReplicaSet 创建新 Pod
  -> Scheduler 调度新 Pod
  -> kubelet 启动新 Pod
  -> readinessProbe 通过
  -> 新 Pod 计入 available
  -> Deployment 缩小旧 ReplicaSet
  -> 重复直到新 ReplicaSet 承担全部副本
```

排障时反向看：

```text
Deployment 没发布完
  -> 看 Deployment conditions
  -> 看新旧 ReplicaSet
  -> 看新 Pod 状态
  -> 看 Pod events
  -> 看应用日志和 probe
  -> 看资源、镜像、配置、网络、存储
```

只要记住 Deployment 的核心是“管理 ReplicaSet 的发布控制器”，它就不会再是一堆 YAML 字段。

## 小结（3-5 条关键点）

- Deployment 适合管理无状态长期服务，它通过 ReplicaSet 管理 Pod，提供副本维持、滚动更新、回滚和历史版本能力。
- ReplicaSet 负责某个版本的 Pod 副本数，Deployment 负责多个 ReplicaSet 之间的版本切换和发布策略。
- Deployment 的 `selector` 是管理契约，必须匹配 PodTemplate labels，创建后不能随意修改。
- 修改 `spec.template` 会触发新的 ReplicaSet；滚动发布通过扩新 ReplicaSet、缩旧 ReplicaSet 完成。
- Deployment 发布是否顺利，最终取决于新 Pod 是否能创建、调度、启动并 Ready；readinessProbe、资源、镜像、配置都会影响发布推进。
- Deployment 的边界是无状态、可替换副本；需要稳定身份用 StatefulSet，每节点一个用 DaemonSet，一次性任务用 Job/CronJob。

## 问题（检测你对当前章节内容是否了解）

1. 为什么生产环境一般不直接创建裸 Pod？Deployment 比裸 Pod 多解决了哪些问题？
2. Deployment、ReplicaSet、Pod、Container 的关系是什么？为什么通常不直接操作 ReplicaSet？
3. `spec.selector` 和 `spec.template.metadata.labels` 为什么必须匹配？selector 为什么不能随便改？
4. 修改 Deployment 的哪些字段会触发新的 ReplicaSet？为什么改 PodTemplate 会触发发布？
5. `maxSurge` 和 `maxUnavailable` 分别控制什么？`maxSurge=1`、`maxUnavailable=0` 的收益和代价是什么？
6. readinessProbe 为什么会影响 Deployment 滚动发布？新 Pod Running 但 NotReady 时，Deployment 会怎样？
7. `ProgressDeadlineExceeded` 通常说明什么？你会按什么顺序排查？
8. Deployment 回滚能回滚哪些内容？为什么它不能替代数据库 schema 兼容性设计？
9. Service 和 Deployment 是什么关系？Deployment 是否负责流量入口？
10. 为什么 Deployment 不适合管理需要稳定身份和独立持久数据的数据库实例？
11. Deployment、StatefulSet、DaemonSet、Job 的核心生命周期语义分别是什么？
