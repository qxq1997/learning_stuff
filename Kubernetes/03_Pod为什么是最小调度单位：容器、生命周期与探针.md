# Kubernetes - 第 3 课：Pod为什么是最小调度单位：容器、生命周期与探针

## 学习目标（本节结束后你能做到什么）

学完这一节，你不应该只会背“Pod 是 Kubernetes 最小调度单位”。这句话是结论，不是理解。

你应该能做到：

- 解释 Kubernetes 为什么调度 Pod，而不是直接调度单个容器。
- 说清 Pod 和容器的关系：Pod 是运行环境边界，容器是其中的进程隔离单元。
- 理解 pause container / Pod sandbox 的作用，以及为什么同一个 Pod 内容器可以共享 IP 和端口空间。
- 理解 Pod 内哪些东西共享，哪些东西不共享：network namespace、volume、IPC、PID、cgroup、root filesystem。
- 能区分普通业务容器、init container、sidecar container 的适用场景。
- 掌握 Pod 从创建到 Ready 的生命周期：Pending、ContainerCreating、Running、Ready、Terminating、Succeeded、Failed。
- 能深入理解 readinessProbe、livenessProbe、startupProbe 的区别，以及它们如何影响发布、流量摘挂和自动恢复。
- 理解 restartPolicy、CrashLoopBackOff、OOMKilled、优雅终止、preStop、terminationGracePeriodSeconds。
- 能从 Pod 角度排查常见问题：Pending、ContainerCreating、ImagePullBackOff、CrashLoopBackOff、Running 但 NotReady、Terminating 卡住。

## 内容讲解（核心概念，用类比、例子、图示说清楚。不要太提纲化，加强每一节深度，力求深度。）

### 1. 为什么要有 Pod：Kubernetes 调度的不是“一个进程”，而是“一个运行单元”

很多人第一次接触 Kubernetes 会有一个疑问：容器才是真正运行业务代码的东西，为什么 Kubernetes 不直接调度容器，而要引入 Pod？

这个问题问得非常好。因为它直接触到 Kubernetes 的一个核心设计：生产系统里，一个“应该被一起调度、一起部署、一起生命周期管理”的单元，有时不只是一个容器。

想象一个订单服务。最简单情况下，一个 Pod 里只有一个容器：

```text
Pod
└── order container
```

这个容器里跑着 Spring Boot 或 Go 服务。对大多数普通后端 API 来说，这是最常见模型。

但有些场景，一个业务服务旁边需要一个辅助进程：

```text
Pod
├── order container：业务服务
└── log-agent container：日志采集或转发
```

或者：

```text
Pod
├── app container：业务服务
└── envoy container：sidecar 代理，拦截出入流量
```

或者：

```text
Pod
├── init-db container：启动前检查数据库 schema
├── init-config container：启动前拉取配置
└── app container：真正业务容器
```

这些容器不是独立服务。它们应该被放在同一台节点上，应该共享某些资源，应该作为一个整体被调度和生命周期管理。

如果 Kubernetes 直接调度容器，就会遇到问题：业务容器和 sidecar 可能被调度到不同节点；日志代理可能比业务容器晚很多启动；共享文件和本地网络要额外设计；调度器也不知道哪些容器必须绑在一起。

Pod 解决的是这个问题：

```text
Pod 是 Kubernetes 里一组紧密协作容器的运行环境边界。
Scheduler 调度 Pod。
kubelet 在节点上创建 Pod 里的容器。
```

所以“Pod 是最小调度单位”的意思不是“Pod 比容器更小”，而是：

```text
在 Kubernetes 看来，应该被整体放到某个节点上的最小单位是 Pod。
容器是 Pod 内部的运行进程。
```

### 2. Pod 像一台“逻辑主机”，容器像主机里的进程

理解 Pod 最好用一个类比：Pod 像一台很轻量的逻辑主机，容器像这台主机里的进程。

这不是完全准确的类比，但对建立直觉非常有帮助。

普通虚拟机里，多个进程共享：

- 同一个 IP。
- 同一个端口空间。
- 同一个本地文件系统的一部分。
- 同一个主机名。
- 同一套进程间通信能力。

Pod 内多个容器也有类似味道：

- 它们共享同一个 Pod IP。
- 它们共享同一个网络命名空间。
- 它们可以通过 `localhost` 互相访问。
- 它们可以挂载同一个 Volume 共享文件。
- 它们作为一个整体被调度到同一个 Node。

但 Pod 又不是虚拟机。每个容器仍然有自己的 root filesystem、自己的镜像、自己的进程入口。容器之间不是完全混在一起，而是在某些 namespace 和 volume 上共享。

可以画成这样：

```text
Node
└── Pod: order-pod
    ├── 共享网络命名空间
    │   ├── Pod IP: 10.244.1.23
    │   └── 端口空间: 8080, 15001, ...
    ├── 共享 Volume
    │   └── /var/log/app
    ├── container: order
    │   └── rootfs 来自 order:v1
    └── container: envoy
        └── rootfs 来自 envoy:vX
```

这解释了一个非常重要的事实：同一个 Pod 里的两个容器不能同时监听同一个端口。

因为它们共享网络命名空间和端口空间。如果业务容器已经监听 `0.0.0.0:8080`，sidecar 再监听同一个地址和端口，就会端口冲突。它们更像同一台机器上的两个进程，而不是两台机器上的两个进程。

### 3. pause container / Pod sandbox：Pod 的网络命名空间谁来持有

很多人知道“Pod 内容器共享 IP”，但不知道这个共享 IP 是怎么存在的。

在容器运行时里，Pod 通常会先创建一个 Pod sandbox。很多实现中，这个 sandbox 会对应一个非常小的 pause container。它本身几乎不做业务逻辑，只是作为 Pod 共享 namespace 的“占位者”。

为什么需要它？

如果一个 Pod 里有两个业务容器：

```text
container A
container B
```

它们要共享同一个网络命名空间。那这个网络命名空间应该挂在谁身上？如果挂在 A 身上，A 重启时会不会影响 B？如果挂在 B 身上，B 重启时又怎么办？

pause container 的作用就是提供一个稳定的 Pod sandbox：

```text
Pod sandbox / pause container
  -> 持有 Pod 的网络命名空间
  -> CNI 给这个网络命名空间分配 Pod IP
  -> 业务容器加入这个网络命名空间
```

简化流程是：

```text
kubelet 发现 Pod 要在本节点运行
  -> 调用 runtime 创建 Pod sandbox
  -> CNI 给 sandbox 配网络，分配 Pod IP
  -> 启动业务容器，让它们加入 sandbox 的网络命名空间
```

所以从外部看，Pod 有一个 IP；从内部看，多个容器共享这套网络。

这个细节解释了很多现象：

- Pod IP 属于 Pod，不属于某个业务容器。
- 同 Pod 容器用 `localhost` 通信。
- 同 Pod 容器端口会冲突。
- 业务容器重启通常不改变 Pod IP。
- Pod 被重建后，新的 Pod IP 可能变化。

### 4. Pod 内到底共享什么，不共享什么

Pod 内共享和不共享的边界要讲清楚。否则很容易误以为“同一个 Pod 里的容器什么都共享”。

共享网络命名空间。这个最重要。所有容器看到同一个网络设备、同一个 IP、同一个端口空间。同 Pod 容器可以通过 `localhost` 访问彼此。

共享 Volume。只有当多个容器挂载同一个 Volume 时，才共享对应文件目录。不是说它们天然共享所有文件。每个容器自己的 root filesystem 来自自己的镜像，不会自动共享。

可能共享 IPC namespace。Kubernetes 支持相关配置，但日常业务里不一定经常使用。

PID namespace 默认不共享。也就是说，一个容器默认看不到另一个容器里的进程。Kubernetes 支持 `shareProcessNamespace: true`，开启后同 Pod 容器可以看到彼此进程。这在某些调试或 sidecar 场景有用，但也要注意隔离风险。

cgroup 资源限制通常是按容器设置的。Pod 是调度单位，但 CPU/memory requests/limits 通常写在容器级别。调度时 Pod 的资源请求会聚合所有容器的 requests。运行时限制则由容器自己的 cgroup 生效。

root filesystem 不共享。每个容器有自己的镜像文件系统。要共享文件，需要显式挂载 Volume。

可以总结成表：

| 维度 | 同 Pod 容器是否共享 | 说明 |
| --- | --- | --- |
| 网络命名空间 | 共享 | 同一个 Pod IP，可以 localhost 通信，端口会冲突 |
| Volume | 可共享 | 只有挂载同一个 Volume 的路径才共享 |
| root filesystem | 不共享 | 每个容器来自自己的镜像 |
| PID namespace | 默认不共享 | 可通过 `shareProcessNamespace` 开启 |
| CPU/内存限制 | 不共享 | 通常按容器配置，调度时按 Pod 汇总 |
| 调度位置 | 共享 | 同一个 Pod 内容器一定在同一个 Node |
| 生命周期 | 部分绑定 | Pod 是整体对象，但容器可单独重启 |

这个表比“Pod 共享网络和存储”更精确。

### 5. Pod YAML：不要只看 containers

一个 Pod 的 YAML 可以很简单：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: order-pod
  labels:
    app: order
spec:
  containers:
    - name: order
      image: order:v1
      ports:
        - containerPort: 8080
```

但生产中的 Pod 远不止 `containers`。

一个稍微完整的 Pod spec 可能包含：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: order-pod
  labels:
    app: order
spec:
  restartPolicy: Always
  terminationGracePeriodSeconds: 30
  initContainers:
    - name: wait-db
      image: busybox:1.36
      command: ["sh", "-c", "until nc -z mysql 3306; do sleep 2; done"]
  containers:
    - name: order
      image: order:v1
      ports:
        - containerPort: 8080
      env:
        - name: SPRING_PROFILES_ACTIVE
          value: prod
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
      lifecycle:
        preStop:
          exec:
            command: ["sh", "-c", "sleep 10"]
      volumeMounts:
        - name: app-logs
          mountPath: /var/log/app
    - name: log-agent
      image: log-agent:v1
      volumeMounts:
        - name: app-logs
          mountPath: /var/log/app
  volumes:
    - name: app-logs
      emptyDir: {}
```

这份 YAML 里有很多关键点：

- `labels` 让 Service、Deployment、监控、日志系统能识别 Pod。
- `restartPolicy` 决定容器失败后是否重启。
- `terminationGracePeriodSeconds` 决定优雅终止窗口。
- `initContainers` 在业务容器前执行。
- `resources` 影响调度、QoS、OOM 风险。
- `readinessProbe` 影响是否接 Service 流量。
- `livenessProbe` 影响容器是否被重启。
- `preStop` 影响下线前是否有时间摘流和排空连接。
- `volumes` 和 `volumeMounts` 让多个容器共享文件。

所以看 Pod 不应该只看镜像名，而要看它完整表达了什么运行约束。

### 6. init container：主容器启动前的前置任务

init container 是 Pod 里一种特殊容器。它在普通业务容器启动前运行，按顺序执行，必须成功完成，后面的容器才会启动。

常见用途：

- 等待依赖服务可达。
- 初始化配置文件。
- 拉取启动所需资源。
- 执行轻量迁移或检查。
- 为主容器准备共享 Volume 内容。

比如：

```yaml
initContainers:
  - name: wait-db
    image: busybox:1.36
    command: ["sh", "-c", "until nc -z mysql 3306; do echo waiting db; sleep 2; done"]
```

这个 init container 会等待 MySQL 端口可达。只有它退出码为 0，业务容器才会启动。

init container 和普通容器有几个区别：

- init container 按顺序执行。
- 每个 init container 必须成功退出。
- init container 不会和业务容器长期并行。
- 如果 init container 失败，Pod 会停在初始化阶段并按策略重试。
- init container 可以使用和业务容器不同的镜像。

但要谨慎使用 init container。它适合做“启动前必须完成”的准备工作，不适合塞复杂业务流程。比如数据库 schema 迁移如果放在每个 Pod 的 init container 里，多副本同时启动时可能并发执行，造成锁竞争或数据风险。真正复杂的迁移通常应该由独立 Job 或发布流程管理。

### 7. sidecar：和主容器一起长期运行的辅助容器

sidecar 是和主业务容器一起运行的辅助容器。它不是 Kubernetes 新对象，而是一种 Pod 内容器组合模式。

常见 sidecar 场景：

- 日志采集：业务容器写文件，sidecar 读取文件并发送到日志系统。
- 代理：Envoy、Istio sidecar 处理出入流量。
- 配置同步：sidecar 监听配置变化并写入共享 Volume。
- 文件同步：sidecar 从对象存储同步静态资源。

sidecar 的价值在于，它能把横切能力从业务容器中拆出来。

比如服务网格里，业务容器不需要自己实现 mTLS、重试、熔断、流量镜像，sidecar 代理可以拦截流量并执行这些能力。

但 sidecar 也有代价：

- 资源开销增加。
- Pod 启动和终止更复杂。
- sidecar 异常可能影响主业务容器。
- 日志和排障多一个容器维度。
- 多容器共享 Volume 时要注意文件权限和写入竞争。

所以 sidecar 不是“越多越好”。只有当辅助能力和主容器确实需要共享生命周期、网络或本地文件时，才适合放进同一个 Pod。

一个常见判断：

```text
如果两个容器必须在同一个节点、通过 localhost 或本地文件紧密协作，
可以考虑放在同一个 Pod。

如果它们只是普通远程调用关系，
更应该拆成两个 Service。
```

### 8. Pod 的 phase：Pending、Running、Succeeded、Failed 只是粗粒度状态

`kubectl get pod` 里经常看到 Pod 状态：

```text
Pending
Running
Succeeded
Failed
Unknown
```

这些是 Pod phase，属于粗粒度状态。

Pending 表示 Pod 已经被 API Server 接受，但一个或多个容器还没有运行起来。原因可能很多：

- 还没被 Scheduler 绑定节点。
- 镜像还在拉。
- CNI 网络还没配好。
- Volume 还没挂载。
- init container 还没完成。

Running 表示 Pod 已经绑定到节点，并且至少一个容器正在运行或正在启动/重启。Running 不等于 Ready。

Succeeded 表示 Pod 里的所有容器都成功退出，且不会再重启。常见于 Job。

Failed 表示所有容器都终止，且至少一个失败退出。

Unknown 表示控制面无法获取 Pod 状态，常见于节点失联。

对长期运行的 Deployment 来说，最常看到的是 Pending、Running、Terminating 以及一些 container waiting reason，比如 ImagePullBackOff、CrashLoopBackOff。严格说 ImagePullBackOff 不是 Pod phase，而是容器状态里的 waiting reason，但 `kubectl get pod` 会把它展示出来。

所以排障时不能只看 `STATUS` 一列。要看：

```bash
kubectl describe pod <pod-name>
kubectl get pod <pod-name> -o yaml
```

尤其要看：

- `status.phase`
- `status.conditions`
- `containerStatuses`
- `initContainerStatuses`
- Events

### 9. Running 不等于 Ready：生产流量看的是 Ready

Pod Running 只是说明容器进程层面已经起来。它不代表业务已经可以接流量。

一个 Java 服务可能已经启动进程，但还在：

- 加载 Spring Context。
- 初始化连接池。
- 拉取远程配置。
- 预热缓存。
- 建立 MQ consumer。
- 检查下游依赖。

这时容器可能 Running，但业务还不能服务。

Kubernetes 用 Pod conditions 表达更细的状态。常见条件包括：

- `PodScheduled`
- `Initialized`
- `ContainersReady`
- `Ready`

其中 `Ready=True` 对生产流量很关键。普通 Service 会把 Ready Pod 作为后端；NotReady Pod 通常不会进入 EndpointSlice 的可用后端。

```text
Running：容器进程运行了。
Ready：这个 Pod 已经准备好接 Service 流量。
```

这两个状态不能混为一谈。

比如：

```text
order-pod   0/1   Running   0   30s
```

这说明 Pod phase 是 Running，但 0/1 表示 1 个容器中 0 个 Ready。它还不应该接流量。

再比如：

```text
order-pod   1/1   Running   0   45s
```

这才表示容器 Ready。

很多线上发布抖动，根因就是把 Running 当 Ready。新 Pod 进程刚起来就被打流量，结果初始化没完成，请求失败。

### 10. readinessProbe：决定 Pod 是否进入 Service 后端

readinessProbe 用来判断容器是否准备好接流量。它失败时，kubelet 不会因为这个探针失败而重启容器，而是把容器标记为 NotReady。Pod 也可能变成 NotReady，然后从 Service 后端摘除。

常见 readinessProbe：

```yaml
readinessProbe:
  httpGet:
    path: /actuator/health/readiness
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 5
  timeoutSeconds: 2
  failureThreshold: 3
```

字段含义：

- `initialDelaySeconds`：容器启动后多久开始探测。
- `periodSeconds`：探测周期。
- `timeoutSeconds`：单次探测超时。
- `failureThreshold`：连续失败多少次认为失败。
- `successThreshold`：连续成功多少次认为成功，readiness 可以使用。

readinessProbe 的典型用途：

- 应用启动完成前不接流量。
- 下游关键依赖不可用时临时摘流。
- 发布新版本时，只有新 Pod Ready 后才逐步替换旧 Pod。
- 终止前配合优雅下线，减少请求打到正在关闭的实例。

但 readinessProbe 也不能乱写。

如果 readinessProbe 过于严格，比如检查所有下游依赖，只要某个非核心依赖抖动就 NotReady，可能导致大量 Pod 同时从 Service 后端摘除，引发更大故障。

如果 readinessProbe 过于宽松，比如只检查进程是否活着，不检查应用是否真正可服务，新 Pod 可能过早接流量。

一个常见建议是：readinessProbe 应该判断“这个实例是否适合接入口流量”，而不是把所有业务依赖都做成一票否决。哪些依赖必须检查，取决于服务职责和降级能力。

### 11. livenessProbe：判断容器是否需要重启

livenessProbe 用来判断容器是否还活着。如果连续失败达到阈值，kubelet 会重启容器。

典型配置：

```yaml
livenessProbe:
  httpGet:
    path: /actuator/health/liveness
    port: 8080
  initialDelaySeconds: 60
  periodSeconds: 10
  timeoutSeconds: 2
  failureThreshold: 3
```

livenessProbe 适合发现“进程还在，但已经无法自我恢复”的情况，比如：

- 死锁。
- 主线程卡死。
- HTTP server 不响应。
- 内部状态损坏，只能靠重启恢复。

但 livenessProbe 是一把很锋利的刀。配错会造成灾难。

比如一个 Java 服务启动要 90 秒，你把 livenessProbe 配成启动后 20 秒开始检查。如果检查失败就重启，那么服务可能永远起不来：

```text
启动 20 秒 -> liveness 失败 -> kubelet 重启
再启动 20 秒 -> liveness 失败 -> 再重启
循环往复 -> CrashLoopBackOff
```

再比如 livenessProbe 检查数据库连接。如果数据库短暂抖动，所有业务 Pod 的 livenessProbe 都失败，kubelet 会把它们全部重启。数据库已经抖了，再叠加大量服务重启，故障会扩大。

所以 livenessProbe 应该尽量检查“本进程是否活着且可自我恢复”，不要轻易把外部依赖写进 liveness。

一句话：

```text
readiness 失败：摘流，不重启。
liveness 失败：重启容器。
```

### 12. startupProbe：保护慢启动应用

startupProbe 用来判断应用是否已经完成启动。在 startupProbe 成功之前，livenessProbe 和 readinessProbe 的常规失败不会按同样方式影响容器。

它特别适合启动慢的应用，比如：

- Spring Boot 大服务。
- 需要加载大量规则、模型、缓存的服务。
- 第一次启动要做本地初始化的服务。

示例：

```yaml
startupProbe:
  httpGet:
    path: /actuator/health/startup
    port: 8080
  periodSeconds: 5
  failureThreshold: 30
```

这个配置允许应用最多有：

```text
5 秒 * 30 = 150 秒
```

的启动窗口。

startupProbe 的价值是把“启动慢”和“运行中卡死”区分开。启动阶段可以给长一点时间；启动完成后，再用 livenessProbe 判断运行期是否健康。

没有 startupProbe 时，人们经常把 livenessProbe 的 initialDelaySeconds 配得很大来保护启动。但这会导致运行期故障发现也变慢。startupProbe 更清晰。

### 13. 三种 probe 的判断边界

可以用一张表总结：

| 探针 | 问题 | 失败后结果 | 典型用途 |
| --- | --- | --- | --- |
| startupProbe | 应用启动完成了吗？ | 启动窗口内持续等待，超过阈值后重启 | 慢启动保护 |
| readinessProbe | 现在适合接流量吗？ | 标记 NotReady，从 Service 后端摘除 | 发布、摘流、临时不可服务 |
| livenessProbe | 进程是否已经坏到需要重启？ | kubelet 重启容器 | 死锁、卡死、自愈失败 |

一个比较稳的后端服务探针设计可能是：

```text
startupProbe：
只判断应用启动流程是否完成，给足启动窗口。

readinessProbe：
判断服务是否能接入口流量，可包含必要依赖，但不要过度严格。

livenessProbe：
只判断本进程是否活着，不要因外部依赖抖动轻易重启。
```

从发布稳定性角度看，readinessProbe 最关键；从自愈角度看，livenessProbe 最危险；从慢启动角度看，startupProbe 最容易被忽略。

### 14. restartPolicy：Pod 重启还是容器重启

Pod 的 `restartPolicy` 决定容器退出后是否重启。常见值：

- `Always`
- `OnFailure`
- `Never`

Deployment 管理的长期服务通常只能使用 `Always`。Job 常用 `OnFailure` 或 `Never`。

要注意一个细节：容器重启不等于 Pod 重建。

如果一个容器崩溃，kubelet 可以在同一个 Pod 内重启这个容器。此时：

```text
Pod 名字不变
Pod IP 通常不变
container restartCount 增加
```

而 Pod 重建通常意味着旧 Pod 对象被删除，新 Pod 对象被创建。此时：

```text
Pod 名字变化
Pod UID 变化
Pod IP 可能变化
```

所以看到 `RESTARTS=5`，说明同一个 Pod 内容器已经重启过 5 次，不一定创建了 5 个 Pod。

`CrashLoopBackOff` 也要理解。它表示容器反复崩溃，kubelet 按退避策略延迟重启。BackOff 是为了避免疯狂重启耗尽资源。

常见原因：

- 应用启动即退出。
- 配置缺失。
- 环境变量错误。
- 数据库连接失败且应用选择退出。
- 端口冲突。
- livenessProbe 误杀。
- 内存 OOM。

排查时优先看：

```bash
kubectl logs <pod> -c <container> --previous
kubectl describe pod <pod>
kubectl get pod <pod> -o yaml
```

`--previous` 很关键，因为当前容器可能已经重启，上一轮崩溃日志才有根因。

### 15. OOMKilled：不是 Kubernetes 随机杀你

OOMKilled 表示容器因为内存超限被杀。它通常和 container memory limit 有关。

比如：

```yaml
resources:
  requests:
    memory: "512Mi"
  limits:
    memory: "1Gi"
```

如果容器内存使用超过 1Gi，可能被内核 OOM kill。kubelet 会观察到容器终止原因是 OOMKilled，并按 restartPolicy 重启。

这会表现为：

```text
STATUS: CrashLoopBackOff 或 Running
RESTARTS: 不断增加
Last State: Terminated
Reason: OOMKilled
Exit Code: 137
```

OOMKilled 不是“应用主动退出”，而是资源限制触发的强制终止。排查时要看：

- 应用是否内存泄漏。
- JVM heap 是否和容器 limit 匹配。
- off-heap、Metaspace、线程栈、DirectBuffer 是否考虑。
- requests/limits 是否过小。
- 是否流量突增导致内存上涨。
- 是否有大对象、大查询、大缓存。

这部分后面资源章节会深讲，但 Pod 章节里要先建立直觉：Pod 状态里的 containerStatuses 会告诉你容器上一次为什么死。

### 16. 优雅终止：Pod 下线不是立刻 kill

Pod 终止非常重要，因为它直接影响发布和缩容时是否丢请求。

当你删除一个 Pod，或者 Deployment 滚动发布要替换旧 Pod 时，Kubernetes 会让 Pod 进入 Terminating。

大致流程：

```text
1. Pod 被标记为 deletionTimestamp。
2. EndpointSlice 更新，Pod 从 Service 后端摘除。
3. kubelet 执行 preStop hook。
4. kubelet 给容器主进程发送 SIGTERM。
5. 等待 terminationGracePeriodSeconds。
6. 如果容器还没退出，发送 SIGKILL 强杀。
```

默认 `terminationGracePeriodSeconds` 通常是 30 秒。

一个常见配置：

```yaml
terminationGracePeriodSeconds: 60
containers:
  - name: order
    lifecycle:
      preStop:
        exec:
          command: ["sh", "-c", "sleep 10"]
```

`preStop` 里的 `sleep 10` 看起来土，但有时有实际用途：给 Service 后端摘除、负载均衡规则传播、连接排空留一点时间。

不过不要机械迷信 `sleep`。更好的方式是应用本身支持优雅停机：

- 收到 SIGTERM 后停止接新请求。
- 等待正在处理的请求完成。
- 关闭 HTTP server。
- 提交消费位点。
- 关闭数据库连接池。
- 释放锁。

Spring Boot、Go HTTP server、Netty 等都要确认是否正确处理 SIGTERM。

如果应用不处理 SIGTERM，Kubernetes 给了 30 秒也没用，最后还是 SIGKILL。SIGKILL 下，应用没有机会清理资源。

### 17. Pod 为什么不应该被当成稳定机器

Pod 是临时的、可替换的。

这句话要反复强调，因为它影响架构设计。

不要依赖固定 Pod IP。Pod 重建后 IP 可能变。服务之间应该通过 Service 调用。

不要依赖固定 Pod 名字。Deployment 创建的 Pod 名字带随机后缀，重建后会变。需要稳定身份的场景应该看 StatefulSet。

不要把关键业务数据只写在 Pod 本地文件系统。Pod 删除后，本地数据可能丢失。持久化数据要用 PVC 或外部存储。

不要手工进入 Pod 修改配置来“修复生产”。Pod 重建后改动消失，而且不可审计。配置应该来自 ConfigMap、Secret、镜像或发布系统。

不要把 Pod 当成 VM 运维。Kubernetes 的思路是“实例可替换”，不是“每台机器精心维护”。

这也是为什么 Pod 要配合更高层对象使用：

- Deployment 负责长期维持无状态 Pod 副本。
- Service 负责给动态 Pod 提供稳定访问入口。
- PVC 负责让数据生命周期独立于 Pod。
- ConfigMap/Secret 负责让配置独立于镜像和容器本地修改。

Pod 自己只是一个运行实例，不是稳定服务的全部。

### 18. 多容器 Pod 什么时候合理，什么时候不合理

多容器 Pod 很强，但不能滥用。

适合放进同一个 Pod 的条件：

- 必须一起调度到同一节点。
- 必须共享 localhost。
- 必须共享本地 Volume。
- 生命周期强绑定。
- 一个容器是另一个容器的辅助能力，不应该独立扩缩容。

典型例子：

- 业务容器 + Envoy sidecar。
- 业务容器 + 日志采集 sidecar。
- 业务容器 + 配置同步 sidecar。
- 主容器启动前的 init container。

不适合放进同一个 Pod 的情况：

- 两个都是独立业务服务。
- 它们需要独立扩缩容。
- 它们的发布节奏不同。
- 它们之间只是普通网络调用。
- 一个异常不应该影响另一个生命周期。

比如订单服务和支付服务不应该放在同一个 Pod。它们应该是两个 Deployment、两个 Service。否则订单服务扩容会强行带着支付服务扩容，发布也绑在一起，故障边界混乱。

判断标准很简单：

```text
共享 Pod 是为了表达“紧密耦合的运行单元”。
不是为了省 YAML，也不是为了把多个服务打包在一起。
```

### 19. Pod 排障：从状态机出发

Pod 排障要按生命周期看。

第一步，Pod 有没有被创建？

```bash
kubectl get pod
```

如果 Pod 根本没有，问题可能在 Deployment/ReplicaSet/Job 控制器、selector、配额、权限。这个属于上层控制器问题。

第二步，Pod 是否 Pending？

```bash
kubectl describe pod <pod>
```

Pending 常见原因：

- Scheduler 没找到合适节点。
- CPU/内存 requests 太高。
- nodeSelector/affinity 不满足。
- 节点有 taint 但 Pod 没 toleration。
- PVC 未绑定。
- 镜像还在拉取。
- CNI/CSI 准备失败。

第三步，是否 ContainerCreating？

ContainerCreating 常见原因：

- 镜像拉取中。
- CNI 分配网络失败。
- Volume 挂载失败。
- ConfigMap/Secret 不存在。
- 节点 runtime 异常。

第四步，是否 ImagePullBackOff？

看：

- 镜像地址是否正确。
- tag 是否存在。
- 私有仓库 imagePullSecret 是否配置。
- 节点是否能访问镜像仓库。

第五步，是否 CrashLoopBackOff？

看：

```bash
kubectl logs <pod> --previous
kubectl describe pod <pod>
```

重点看应用启动日志、退出码、OOMKilled、probe 失败。

第六步，是否 Running 但 NotReady？

看 readinessProbe：

- 路径是否正确。
- 端口是否正确。
- initialDelay 是否太短。
- 应用健康接口是否依赖下游。
- 下游是否异常。

第七步，是否 Terminating 卡住？

常见原因：

- finalizer 阻塞。
- Volume 卸载卡住。
- 节点失联。
- 应用不响应 SIGTERM。
- preStop 卡住。

可以压缩成一张表：

| 现象 | 优先方向 | 常用命令 |
| --- | --- | --- |
| Pending | 调度、资源、PVC、污点、亲和性 | `kubectl describe pod` |
| ContainerCreating | 镜像、CNI、CSI、ConfigMap/Secret | `kubectl describe pod` |
| ImagePullBackOff | 镜像名、tag、仓库认证、网络 | `kubectl describe pod` |
| CrashLoopBackOff | 应用崩溃、OOM、探针误杀 | `kubectl logs --previous` |
| Running 但 0/1 Ready | readinessProbe、应用初始化、依赖 | `describe`、应用日志 |
| OOMKilled | memory limit、泄漏、JVM 参数 | `describe`、metrics |
| Terminating 卡住 | finalizer、preStop、节点、Volume | `describe`、node 状态 |

### 20. Pod 和后续章节的关系

Pod 是 Kubernetes 的运行原子，但不是你在生产里最常直接操作的对象。

生产里你通常不会手工创建裸 Pod，而是通过 Deployment、StatefulSet、DaemonSet、Job 等控制器创建 Pod。

但理解 Pod 是后面所有章节的基础：

- 学 Deployment，要理解它最终管理的是一组 Pod。
- 学 Service，要理解它选择的是 Ready Pod。
- 学 Ingress，要理解流量最终还是进 Pod。
- 学 ConfigMap/Secret，要理解它们如何注入 Pod。
- 学 PVC，要理解数据如何挂进 Pod。
- 学调度，要理解 Scheduler 调度的是 Pod。
- 学发布，要理解 probe 和 termination 如何影响 Pod 摘挂流量。

如果 Pod 没吃透，Deployment 和 Service 就会变成 YAML 记忆题。吃透 Pod 之后，后面对象之间的关系会自然很多。

## 小结（3-5 条关键点）

- Pod 是 Kubernetes 的最小调度单位，因为它表达的是一组紧密协作容器的运行环境边界，而不是单个进程。
- Pod 内容器共享网络命名空间和可挂载的 Volume，但 root filesystem、默认 PID namespace、容器级资源限制并不完全共享。
- pause container / Pod sandbox 通常用于持有 Pod 的共享网络命名空间，业务容器加入这个命名空间后共享 Pod IP。
- Running 不等于 Ready；readinessProbe 决定是否接 Service 流量，livenessProbe 决定是否重启容器，startupProbe 用于慢启动保护。
- Pod 是临时、可替换的运行实例，不应该依赖固定 Pod IP、本地临时数据或手工进 Pod 修改状态。

## 问题（检测你对当前章节内容是否了解）

1. Kubernetes 为什么调度 Pod，而不是直接调度容器？请用 sidecar 或 init container 场景解释。
2. Pod 内多个容器共享哪些东西？哪些东西默认不共享？
3. pause container / Pod sandbox 的作用是什么？为什么业务容器重启通常不会改变 Pod IP？
4. Running 和 Ready 的区别是什么？为什么 Service 更关心 Ready？
5. readinessProbe、livenessProbe、startupProbe 分别回答什么问题？配错会造成什么生产事故？
6. 容器重启和 Pod 重建有什么区别？`RESTARTS` 增加通常说明什么？
7. Pod 被删除或滚动发布下线时，优雅终止大致经历哪些步骤？
8. 一个 Pod 显示 CrashLoopBackOff，你会优先看哪些信息？一个 Pod Running 但 0/1 Ready，你又会看什么？
9. 为什么不建议把订单服务和支付服务放进同一个 Pod？
10. 为什么说 Pod 是后续 Deployment、Service、PVC、调度和发布章节的基础？
