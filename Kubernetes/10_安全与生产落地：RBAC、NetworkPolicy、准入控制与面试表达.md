# Kubernetes - 第 10 课：安全与生产落地：RBAC、NetworkPolicy、准入控制与面试表达

## 学习目标（本节结束后你能做到什么）

- 理解 Kubernetes 安全不是单一开关，而是身份、权限、网络、镜像、运行时和准入策略的组合。
- 掌握 RBAC、ServiceAccount、Role、ClusterRole、RoleBinding 的基本关系。
- 理解 NetworkPolicy、Pod Security、准入控制在生产中的作用。
- 能从生产落地和面试角度总结 Kubernetes 的核心取舍。

## 内容讲解（核心概念，用类比、例子、图示说清楚。不要太提纲化，加强每一节深度，力求深度。）

Kubernetes 的强大来自统一 API，也意味着安全边界非常重要。谁能创建 Pod，谁能读取 Secret，哪个服务能访问数据库，容器能不能以 root 运行，镜像来自哪里，变更是否经过校验，这些都会影响生产风险。安全不是最后补一个工具，而是贯穿集群使用方式的基本设计。

先看身份与权限。Kubernetes 中访问 API Server 的主体可以是用户，也可以是 ServiceAccount。用户通常代表人或外部系统，ServiceAccount 通常代表运行在集群里的 Pod。比如某个 CI 系统需要发布应用，它访问 API Server 时需要身份；某个控制器运行在集群中，需要 watch Deployment 和创建 Pod，也需要 ServiceAccount。

RBAC 是 Kubernetes 常见授权模型。Role 定义某个 namespace 内的权限，比如可以 get/list/watch Pods，可以 create Deployments。ClusterRole 定义集群级权限，或者可复用于多个 namespace 的权限集合。RoleBinding 把 Role 绑定给某个用户、组或 ServiceAccount；ClusterRoleBinding 则做集群级绑定。

```text
主体：User / Group / ServiceAccount
  -> 绑定：RoleBinding / ClusterRoleBinding
  -> 权限集合：Role / ClusterRole
  -> 资源动作：get/list/watch/create/update/delete pods/secrets/deployments
```

RBAC 的核心原则是最小权限。一个业务 Pod 如果只需要读取自己 namespace 下某个 ConfigMap，就不应该拥有读取所有 Secret 的权限。一个开发人员如果只负责测试环境，就不应该能删除生产 namespace 的资源。生产事故里，“权限过大”经常是扩大影响面的重要原因。

Secret 权限尤其敏感。能读取 Secret，往往就能拿到数据库密码、云服务 token、第三方凭证。很多团队对 Pod 创建权限管得很严，也是因为能创建 Pod 的人可能通过挂载 ServiceAccount token、读取卷、运行调试镜像等方式间接扩大权限。因此 Kubernetes 权限不能只看表面动作，要考虑组合后的能力。

网络安全由 NetworkPolicy 提供基础能力。默认情况下，很多 Kubernetes 集群里的 Pod 网络是互通的。也就是说，只要知道地址和端口，一个 namespace 的 Pod 可能能访问另一个 namespace 的 Pod。NetworkPolicy 可以声明哪些 Pod 可以入站访问、哪些目的地可以出站访问。比如只允许订单服务访问库存服务，只允许业务服务访问数据库端口，不允许任意 Pod 横向扫描。

需要注意，NetworkPolicy 是否生效取决于 CNI 插件是否支持。你写了策略但网络插件不支持，可能没有实际隔离效果。生产环境要验证策略，而不是只提交 YAML。网络策略也要渐进落地，直接默认拒绝所有流量可能造成大面积不可用。

Pod Security 关注容器运行时安全。比如是否允许特权容器，是否允许宿主机网络，是否允许挂载宿主机路径，是否必须非 root 运行，是否只读根文件系统，是否限制 Linux capabilities。一个容器如果以特权模式运行并挂载宿主机关键路径，逃逸或误操作风险会显著增加。生产中应尽量使用受限的安全上下文。

准入控制 Admission Controller 是 API 请求进入集群前的检查和修改机制。比如你创建 Pod，API Server 在真正保存前可以执行准入逻辑：镜像必须来自可信仓库，必须设置 resources，不能使用 latest tag，必须带 owner 标签，不能创建特权容器。准入控制是平台治理的重要抓手，因为它能把规范变成强约束，而不是只写在文档里。

镜像安全也是一环。生产镜像应尽量小，减少无关工具和漏洞面；应该固定 tag 或 digest，避免 `latest` 带来不可追溯变更；应该做漏洞扫描；基础镜像应定期更新；私有仓库访问凭证要妥善管理。Kubernetes 能运行镜像，但不能自动保证镜像内容安全。

生产落地还要考虑多环境和多租户。namespace 是常见隔离单位，但它不是强安全边界本身。你还需要 RBAC、ResourceQuota、LimitRange、NetworkPolicy、准入策略、审计日志一起配合。ResourceQuota 可以限制 namespace 总资源，LimitRange 可以给默认 requests/limits，避免某个团队无意中吃光集群资源。

从稳定性角度，生产 Kubernetes 至少要关注：控制面高可用、etcd 备份、节点池容量、镜像仓库可用性、DNS 稳定性、监控告警、日志采集、升级策略、证书轮换、权限审计。应用侧则要关注健康检查、优雅停机、资源配置、发布策略、配置变更、下游保护。Kubernetes 不是让复杂度消失，而是把复杂度平台化、标准化。

面试表达时，可以用一条主线总结 Kubernetes：它通过声明式 API 表达期望状态，通过控制器调谐真实状态，通过 Scheduler 和 kubelet 把 Pod 放到节点并运行，通过 Service 和 Ingress 解决动态实例访问，通过 ConfigMap/Secret/PVC 解耦配置、密钥和存储，通过 RBAC、NetworkPolicy、Pod Security 等机制建立生产边界。

也要能讲取舍。Kubernetes 的优点是标准化部署模型、自动恢复、弹性扩缩容、生态丰富、多云一致性。代价是学习成本、运维复杂度、网络和存储排障难度、资源配置不当带来的浪费或不稳定、小团队可能过度工程。成熟回答不是盲目说“上 K8s 就好”，而是能判断什么场景值得上：服务数量多、发布频繁、多环境一致性要求高、需要平台化治理时价值更大；单体小系统、团队运维能力不足、部署频率低时未必划算。

## 小结（3-5 条关键点）

- Kubernetes 安全由身份、权限、网络、运行时、镜像和准入控制共同组成。
- RBAC 通过 Role/ClusterRole 和 Binding 把资源动作授权给用户或 ServiceAccount。
- NetworkPolicy 用于限制 Pod 间流量，但依赖 CNI 支持并需要实际验证。
- Pod Security 和准入控制能把运行时安全与平台规范变成强约束。
- 生产落地 Kubernetes 要同时考虑稳定性、安全、成本、复杂度和团队能力。

## 问题（检测你对当前章节内容是否了解）

1. ServiceAccount 和普通用户身份有什么区别？它通常给谁使用？
2. Role、ClusterRole、RoleBinding、ClusterRoleBinding 分别解决什么问题？
3. 为什么 NetworkPolicy 写了不一定生效？生产中如何验证？
4. 面试中如果被问“为什么你们要上 Kubernetes”，你会从哪些收益和代价回答？
