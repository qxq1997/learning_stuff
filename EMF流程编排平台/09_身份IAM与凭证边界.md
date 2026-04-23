# 09 · 身份、IAM 与凭证边界

## 9.0 本章导读

前面几章已经反复出现了几个很像、但含义完全不同的词:

- GCS object metadata 里的 `owner`。
- 真正把 DAG 文件上传到 GCS 的 principal。
- Team 自己部署的 Control Plane ServiceAccount。
- Control Plane 调 Sidecar 时使用的 ID Token 身份。
- Sidecar 挑选出来的 vendor credential。
- Sidecar 自己运行时的 ServiceAccount。

这些名字如果混在一起,EMF 很容易出现两类问题:

1. **安全问题**:把 `owner=growth-analytics` 当成授权依据,导致任何能上传 DAG 的人都能伪造业务身份。
2. **审计问题**:Run 页面只显示 owner,但查不出到底是谁上传、哪个 ServiceAccount 执行、Sidecar 用了哪份外部凭证。

本章的目标是把身份边界拆干净:

> `owner` 负责业务归属和告警路由;IAM principal 负责真实权限;Sidecar policy 负责跨团队外部凭证治理。三者必须关联,但不能互相替代。

---

## 9.1 EMF 里至少有六种身份

先给结论表。

| 身份 / 字段 | 来源 | 控制什么 | 不能拿来做什么 |
|-------------|------|----------|----------------|
| `dag_owner` | GCS object metadata 的 `owner` | 告警、聚合、业务归属、成本归属 | 不能作为安全授权依据 |
| `uploader_principal` | GCS Audit Logs / CI 发布记录 | 证明谁发布了这版 DAG | 不能代表运行时权限 |
| `control_plane_service_account` | Team EMF 部署的 GCP ServiceAccount | GCS / BigQuery / Secret Manager 等 GCP 资源访问 | 不能代表业务 owner |
| `sidecar_caller_service_account` | Control Plane 发给 Sidecar 的 ID Token subject/email | Sidecar 调用方认证、配额、命令授权 | 不能由 DAG 参数伪造 |
| `vendor_credential_scope` | Sidecar policy 决策结果 | 使用公司级或团队级第三方凭证 | 不能从 request body 直接信任 |
| `sidecar_runtime_service_account` | 中心 Sidecar GKE Workload Identity | 读取中心 Secret、写 Sidecar ledger | 不应拥有 Team 数据面大权限 |

### 9.1.1 一个具体例子

假设 Team A 部署了一套 EMF:

```text
Team A GCP project:
  GKE namespace: emf-prod
  KSA: emf-control-plane
  GSA: emf-control-plane@team-a-project.iam.gserviceaccount.com

GCS DAG object:
  gs://team-a-emf-dags/prod/daily_export.json
  metadata:
    pipeline-name: daily_export
    owner: growth-analytics
    environment: prod

Central Sidecar:
  GSA: emf-sidecar@platform-project.iam.gserviceaccount.com
```

一次 Run 里可能同时出现:

```json
{
  "dag_owner": "growth-analytics",
  "uploader_principal": "serviceAccount:ci-emf-publisher@team-a-project.iam.gserviceaccount.com",
  "control_plane_service_account": "emf-control-plane@team-a-project.iam.gserviceaccount.com",
  "sidecar_caller_service_account": "emf-control-plane@team-a-project.iam.gserviceaccount.com",
  "vendor_credential_scope": "team:growth-analytics/salesforce",
  "sidecar_runtime_service_account": "emf-sidecar@platform-project.iam.gserviceaccount.com"
}
```

这里 `growth-analytics` 是业务团队,但真正访问 BigQuery 的是 `emf-control-plane@team-a-project...`。真正调用 Salesforce 的 credential 也不是 DAG 里传进去的,而是 Sidecar 根据 caller ServiceAccount 和 policy 选择出来的。

---

## 9.2 DAG owner:业务归属,不是 actor

第 2 / 3 章已经确定:Pipeline 级 metadata 在 GCS object metadata 里,不放进 DAG JSON content。

推荐 metadata:

```text
pipeline-name: daily_export
owner: growth-analytics
environment: prod
notification-channel: slack://growth-data-alerts
```

这些字段的主要用途是:

- Run 页面展示。
- OTel attributes。
- Grafana 聚合维度。
- 告警路由。
- 成本和责任归属。
- Loader / command 的 guardrail,比如 `environment` 一致性校验。

但它们不是强身份。

### 9.2.1 为什么 owner 不能授权

GCS object metadata 是上传者写进去的。只要某个 principal 有写对象的权限,理论上它就能写:

```text
owner: finance-core
```

如果 Sidecar 或 Command Runner 直接根据这个字段放行:

```python
if metadata.owner == "finance-core":
    allow_finance_export()
```

那就等于把安全决策交给了一个可由发布者填写的字符串。

正确关系应该是:

```text
metadata.owner -> 用于治理和通知
IAM principal   -> 用于安全授权
Sidecar policy  -> 用于外部 API 授权
```

### 9.2.2 owner 仍然需要校验

owner 不是授权身份,但 owner 也不能随便填。

推荐 Loader 做 metadata policy 校验:

```json
{
  "prefix": "prod/growth-analytics/",
  "allowed_owners": ["growth-analytics"],
  "allowed_environments": ["prod"],
  "allowed_publishers": [
    "serviceAccount:ci-growth-analytics@team-a-project.iam.gserviceaccount.com"
  ]
}
```

校验含义:

- `prod/growth-analytics/` 前缀下的 DAG,`owner` 只能是 `growth-analytics`。
- `environment` 必须是 `prod`。
- 发布者最好是 CI ServiceAccount,而不是个人账号。

如果违反,Loader 应该进入 `LOAD_FAILED`:

```text
METADATA_POLICY_VIOLATION:
object prefix prod/growth-analytics/ does not allow owner "finance-core".
```

这不是因为 owner 是安全身份,而是为了防止告警、成本、审计归属被污染。

---

## 9.3 上传者身份:Pub/Sub 事件里通常没有

GCS Object Finalize -> Pub/Sub 通知的核心字段是:

```text
bucket
object
generation
event_time
```

它能告诉 Loader "哪份对象有了新 generation",但通常不能直接告诉你"是谁上传的"。

所以不要在 Ingestor 里伪造:

```text
uploader_principal = metadata.owner
```

这会把 business owner 和 actor 混成一个东西。

### 9.3.1 uploader_principal 从哪里来

推荐来源有两个。

第一,Cloud Audit Logs:

```text
methodName: storage.objects.create
resourceName: projects/_/buckets/team-a-emf-dags/objects/prod/daily_export.json
authenticationInfo.principalEmail: ci-emf-publisher@team-a-project.iam.gserviceaccount.com
```

第二,CI 发布记录:

```json
{
  "release_id": "github-actions-run-123",
  "publisher": "serviceAccount:ci-emf-publisher@team-a-project.iam.gserviceaccount.com",
  "git_commit": "abc123",
  "gcs_object": "gs://team-a-emf-dags/prod/daily_export.json",
  "generation": "1710000000000000"
}
```

如果 Audit Log 关联是异步的,Run 不一定要阻塞等待它。可以先记录:

```json
{
  "uploader_principal": null,
  "uploader_principal_status": "PENDING_AUDIT_LOG_CORRELATION"
}
```

后续由 audit enricher 补齐。

### 9.3.2 content writer 和 metadata writer 可能不同

如果有人先上传 content,再 patch metadata,就会出现:

```text
content_generation: 1710000000000000
metageneration: 3
content_writer_principal: alice@example.com
metadata_writer_principal: bob@example.com
```

第 3 章已经建议 content + metadata 同次发布,避免 Loader 读到半成品。但审计上仍要承认:content writer 和 metadata writer 是两件事。

Run snapshot 至少应该保留:

```json
{
  "source": {
    "bucket": "team-a-emf-dags",
    "object": "prod/daily_export.json",
    "generation": "1710000000000000",
    "metageneration": "1",
    "sha256": "..."
  },
  "metadata_snapshot": {
    "pipeline-name": "daily_export",
    "owner": "growth-analytics",
    "environment": "prod"
  },
  "actor_snapshot": {
    "content_writer_principal": "serviceAccount:ci-emf-publisher@team-a-project.iam.gserviceaccount.com",
    "metadata_writer_principal": "serviceAccount:ci-emf-publisher@team-a-project.iam.gserviceaccount.com",
    "actor_source": "cloud_audit_logs"
  }
}
```

---

## 9.4 GCS DAG bucket 的 IAM 边界

EMF 的 DAG 文件都在 GCS。GCS bucket 是 DAG 发布入口,也是第一道治理边界。

### 9.4.1 推荐角色分工

以下是设计建议,具体角色名要按公司已有 IAM 模板调整。

| Actor | 需要的能力 | 说明 |
|-------|------------|------|
| DAG 发布 CI ServiceAccount | 写 DAG object + metadata | 生产环境最好只允许 CI 发布 |
| 人类开发者 | 提交代码 / PR 审核 | 尽量不要直接写 prod DAG bucket |
| GCS service agent | 向 Pub/Sub topic publish | 支撑 Object Finalize 通知 |
| EMF Control Plane ServiceAccount | 读 DAG object + metadata | Loader 固定 generation 读取 |
| EMF Control Plane ServiceAccount | 写 Run artifact / error report | 最好写到单独 result bucket/prefix |

GCS service agent 通常类似:

```text
service-<PROJECT_NUMBER>@gs-project-accounts.iam.gserviceaccount.com
```

它需要在 Pub/Sub topic 上有 publish 权限。

### 9.4.2 不要让运行时 ServiceAccount 随便改 DAG

Control Plane 需要读取 DAG 文件,但不应该默认能修改 DAG 文件。

推荐拆开:

```text
gs://team-a-emf-dags/
  prod/          # DAG source, Control Plane read-only
  staging/

gs://team-a-emf-artifacts/
  runs/          # Run artifacts, Control Plane write
  failures/
```

如果把 DAG source 和 artifacts 放在一个 bucket,也要用 prefix / IAM Conditions / 自定义角色隔离:

```text
Control Plane:
  read  gs://team-a-emf-dags/prod/**
  write gs://team-a-emf-dags/artifacts/**
  no write gs://team-a-emf-dags/prod/**
```

否则一个有 bug 的 command 可能覆盖 DAG source,触发新的 Run,甚至形成循环。

### 9.4.3 生产发布最好走 CI

手工上传的问题不是"人不可信",而是缺少一致的发布协议:

- 容易忘记写 metadata。
- 容易用错 environment。
- 很难记录 git commit。
- 很难稳定生成 sha256 / release_id。
- 很难做 owner/prefix policy 校验。

推荐生产路径:

```text
Git PR -> Review -> CI validate DAG -> CI upload content + metadata -> GCS Object Finalize -> EMF Loader
```

CI 在上传前至少检查:

```text
1. JSON schema / DAG graph valid.
2. owner / environment / pipeline-name metadata complete.
3. object prefix 与 owner/environment policy 匹配.
4. command 名称都在目标环境 Registry 中存在.
5. 不包含 credential / token / service account key.
```

---

## 9.5 Control Plane ServiceAccount:数据面的真实权限

EMF 是 framework,每个 Team 自己部署一套 Control Plane。这个部署的 GCP ServiceAccount 是数据面真实权限边界。

一句话:

> 当前 Team 的 EMF 能做什么,约等于当前 Team 的 Control Plane ServiceAccount 被 IAM 允许做什么。

### 9.5.1 Workload Identity

在 GKE 上推荐使用 Workload Identity:

```text
Kubernetes ServiceAccount:
  namespace: emf-prod
  name: emf-control-plane

Google ServiceAccount:
  emf-control-plane@team-a-project.iam.gserviceaccount.com
```

Pod 不挂载 service account key。Pod 通过 Workload Identity 获得 GCP 身份。

不推荐:

```text
parameters.service_account_key_json
mounted /secrets/sa-key.json
GOOGLE_APPLICATION_CREDENTIALS=/secrets/sa-key.json
```

原因:

- key 很容易被日志、artifact、异常 dump 泄露。
- key 轮换困难。
- key 跨环境复制后,环境边界会失效。
- 一旦 DAG 能传 key,EMF 的 IAM 边界就被绕开。

### 9.5.2 Control Plane 最小权限

一个 Team Control Plane 常见需要:

| 资源 | 能力 | 用途 |
|------|------|------|
| Pub/Sub subscription | consume / ack | 接收 GCS finalize 事件 |
| DAG bucket | read object + metadata | Loader 读取 DAG |
| Artifact bucket | create object | 上传 dbt artifacts、错误报告 |
| State Store | read/write | Run / Step 状态 |
| BigQuery project | create jobs | dbt / SQL / export 命令提交任务 |
| BigQuery datasets | dataViewer / dataEditor 等 | 由具体 command 决定 |
| Secret Manager | access selected team secrets | 只限本 Team 本地命令所需 secret |
| Sidecar endpoint | network access + ID token | 调外部 API command |

注意最后两项:

- Team Control Plane 可以读 Team 自己的 Secret。
- Team Control Plane 不应该读中心 Sidecar 持有的公司级 vendor Secret。

### 9.5.3 CommandContext 里的身份字段

第 5 章讲过 `CommandContext` 是平台注入的运行时上下文。身份字段也应该从平台注入,而不是从 DAG parameters 读取。

示例:

```python
@dataclass(frozen=True)
class CommandIdentity:
    dag_owner: str
    environment: str
    uploader_principal: str | None
    control_plane_service_account: str
    deployment_project: str
    deployment_namespace: str


@dataclass(frozen=True)
class CommandContext:
    run_id: str
    step_id: str
    command: str
    identity: CommandIdentity
    deadline: datetime
    idempotency_key: str
```

DAG parameters 里不应该出现:

```json
{
  "service_account": "finance-prod@company.iam.gserviceaccount.com",
  "impersonate": "admin@company.com"
}
```

如果确实需要特殊执行身份,应该由 Command Registry 或平台 policy 声明,而不是让 DAG 作者随便传。

---

## 9.6 BigQuery / dbt 的 IAM 模型

dbt 集成最容易把身份搞乱,因为 dbt 传统上有 `profiles.yml`,很多人习惯在 profile 里放 credential。

EMF 里推荐:

```text
dbt command -> generated profiles.yml -> BigQuery client -> Team Control Plane ServiceAccount
```

不要:

```text
dbt command -> parameters.credentials_json -> BigQuery client
```

### 9.6.1 BigQuery 权限由 Team SA 决定

典型 BigQuery 权限拆分:

| 权限 | 绑定位置 | 用途 |
|------|----------|------|
| create jobs | project | 允许提交 query / load / extract job |
| read source data | dataset / table | 读取上游表 |
| write target data | dataset | 写入模型结果 |
| read/write temp dataset | dataset | dbt 临时表 / intermediate |

这样做的好处是审计天然清楚:

```text
BigQuery job principal:
  emf-control-plane@team-a-project.iam.gserviceaccount.com

Job labels:
  emf_run_id=run_123
  emf_step_id=dbt_run
  emf_owner=growth-analytics
  emf_pipeline=daily_export
```

BigQuery Audit Logs 里看到的是执行身份;EMF labels 里看到的是业务归属。两者合起来才是完整事实。

### 9.6.2 environment 必须多重一致

第 7 章提过,dbt target 要和 GCS metadata 的 `environment` 对齐。

推荐校验:

```python
if deployment_env != metadata.environment:
    raise LoadFailed("ENVIRONMENT_MISMATCH")

if command == "DbtRun" and parameters["target"] != metadata.environment:
    raise CommandFailed("DBT_TARGET_MISMATCH")
```

更完整的边界是:

```text
deployment_env == GCS metadata.environment == dbt target == Sidecar policy environment
```

不要只靠 metadata:

```text
dev Control Plane + metadata.environment=prod
```

这种情况下 Loader 应该失败,但真正的安全边界仍然是 IAM:dev ServiceAccount 本来就不应该能写 prod BigQuery dataset。

### 9.6.3 什么时候需要 per-command 身份

大多数情况下,一个 Team Control Plane ServiceAccount 足够。

如果某些 command 需要更窄权限,可以考虑 per-command ServiceAccount,但建议满足两个条件:

1. 身份选择由 Command Registry / deployment config 决定。
2. impersonation 权限由平台管理员配置,不是 DAG 参数决定。

示意:

```json
{
  "command": "FinanceExport",
  "execution_identity": {
    "mode": "impersonate_service_account",
    "service_account": "emf-finance-export@team-a-project.iam.gserviceaccount.com"
  }
}
```

这个配置属于 Registry / platform config,不属于 DAG file content。

---

## 9.7 Secret Manager:本地 Secret 和中心 Secret 要分开

EMF 里至少有两类 Secret。

| Secret 类型 | 放在哪里 | 谁能读 | 示例 |
|-------------|----------|--------|------|
| Team local secret | Team project Secret Manager | Team Control Plane SA | 内部数据库密码、team-owned API token |
| Central vendor secret | Platform project Secret Manager | Sidecar runtime SA | 公司 Salesforce OAuth、HubSpot API key |

### 9.7.1 DAG 不传 secret value

禁止:

```json
{
  "id": "export_salesforce",
  "command": "SalesforceExport",
  "parents": [],
  "parameters": {
    "access_token": "ya29..."
  }
}
```

也不要把 secret 放进 GCS object metadata:

```text
x-goog-meta-salesforce-token: ya29...
```

metadata 会出现在对象元信息、Run snapshot、日志和审计里,不适合放敏感值。

### 9.7.2 可以传 secret reference,但要受 schema 控制

某些本地 command 可能确实需要 Team secret。可以允许参数传引用:

```json
{
  "id": "load_from_internal_api",
  "command": "InternalApiExtract",
  "parents": [],
  "parameters": {
    "endpoint": "https://internal.example/api/orders",
    "credential": {
      "secret_ref": "projects/team-a-project/secrets/internal-api-token/versions/latest"
    }
  }
}
```

但必须满足:

- Command schema 明确允许 `secret_ref`。
- Secret 必须在允许的 project / prefix 下。
- Command Runner 在最后一刻解析 secret value。
- State Store 只保存 `secret_ref` 和 resolved version,不保存 value。
- 日志只允许记录 secret resource name 的脱敏形式或 hash。

推荐 Run snapshot:

```json
{
  "resolved_secrets": [
    {
      "parameter_path": "credential.secret_ref",
      "secret": "projects/team-a-project/secrets/internal-api-token",
      "version": "5",
      "value_logged": false
    }
  ]
}
```

### 9.7.3 中心 vendor secret 不给 Control Plane

外部 SaaS 凭证如果是公司级共享资源,应该只给 Sidecar runtime SA。

不要让 Team Control Plane 直接读:

```text
projects/platform-project/secrets/salesforce-company-oauth
```

否则 Sidecar 的中心化意义会被削弱:

- Team 可以绕过 Sidecar rate limit。
- Team 可以绕过 Sidecar idempotency ledger。
- Team 可以打出未审计的 vendor 请求。
- vendor credential 泄露面变成每个 Team 的 namespace。

---

## 9.8 Sidecar 跨边界身份

Sidecar 是 EMF 架构里唯一明显的中心服务。它面对的核心问题是:

> 一个去中心化的 Team Control Plane 调中心化 Sidecar 时,Sidecar 怎么知道是谁在调用?

推荐答案是 Team ServiceAccount ID Token。

### 9.8.1 调用流程

```text
Team Control Plane
  1. 使用 Workload Identity 获得 GCP 身份
  2. 获取 audience=sidecar 的 ID Token
  3. POST /v1/commands/{command}:execute
     Authorization: Bearer <ID Token>

Central Sidecar
  4. 校验 token issuer / audience / expiry / signature
  5. 读取 token subject/email
  6. 映射 caller ServiceAccount -> team policy
  7. 校验 command/environment/credential scope
  8. 执行 vendor API
  9. 写 Sidecar ledger 和 audit log
```

Sidecar request 里可以带 owner,但 owner 只是上下文:

```json
{
  "run_id": "run_123",
  "step_id": "salesforce_export",
  "owner": "growth-analytics",
  "environment": "prod",
  "parameters": {
    "object": "Account",
    "destination": "gs://team-a-exports/salesforce/account/"
  }
}
```

真正授权看 token:

```text
caller_service_account = emf-control-plane@team-a-project.iam.gserviceaccount.com
```

### 9.8.2 Sidecar policy 示例

```json
{
  "caller_service_account": "emf-control-plane@team-a-project.iam.gserviceaccount.com",
  "team": "team-a",
  "allowed_environments": ["prod"],
  "allowed_commands": [
    "SalesforceExport",
    "CreateZendeskTicket"
  ],
  "credential_policy": {
    "SalesforceExport": {
      "scope": "team",
      "credential_ref": "projects/platform-project/secrets/salesforce-team-a"
    },
    "CreateZendeskTicket": {
      "scope": "company-default",
      "credential_ref": "projects/platform-project/secrets/zendesk-company-default"
    }
  },
  "rate_limits": {
    "SalesforceExport": "1000/hour",
    "CreateZendeskTicket": "120/minute"
  }
}
```

几个重点:

- `caller_service_account` 是安全身份。
- `team` 是 Sidecar policy 里的映射结果。
- `credential_ref` 是 Sidecar 内部配置,不从 DAG 参数传入。
- `owner` 可以用于日志和告警,但不能覆盖 policy。

### 9.8.3 内网不等于认证

Sidecar 不应该公网暴露,但"只在内网"也不能替代身份认证。

内网能解决:

- 暴露面。
- 网络路径。
- 基础访问范围。

内网不能解决:

- 哪个 Team 在调。
- 这个 Team 能不能调这个 command。
- 这个 Team 应该用哪份 vendor credential。
- 调用失败后该算谁的配额。

所以 Sidecar 至少要有:

```text
network boundary + authenticated caller + authorization policy + audit log
```

---

## 9.9 vendor credential scope

第三方 SaaS 凭证通常不像 GCP IAM 那样天然按项目隔离,所以 Sidecar 必须自己定义 credential scope。

常见三种模式。

### 9.9.1 company-default

全公司共用一份 vendor credential。

适合:

- vendor 本身只给一个公司级账号。
- API 操作是共享资源。
- 分团队凭证成本太高。

风险:

- 一个 Team 的错误请求可能影响全公司配额。
- vendor 侧审计看到的是同一个账号。
- 需要 Sidecar 强制记录 caller team 和 owner。

必须配套:

- Sidecar rate limit 按 team / command 细分。
- Sidecar ledger 保存 caller identity。
- command 参数 schema 限制可操作范围。

### 9.9.2 team-level

同一个 vendor,每个 Team 一份 credential。

适合:

- vendor 支持多个 app / OAuth connection。
- 团队之间的数据边界强。
- 需要分团队撤销访问。

好处:

- 隔离更清楚。
- 某个 Team 凭证失效不影响全公司。
- vendor 审计更容易对应团队。

代价:

- credential onboarding 和 rotation 复杂。
- Sidecar policy 要维护更多映射。

### 9.9.3 user-delegated

以具体用户的 OAuth 身份调用 vendor。

这类模式最复杂,不建议作为 EMF 批处理默认模型。除非业务确实要求"代表某个用户执行",否则批处理系统更适合使用 service-level credential。

如果未来支持 user-delegated,要额外处理:

- 用户授权和撤销。
- refresh token 保护。
- 用户离职。
- Run 重放时原用户是否仍有权限。
- 审计里区分 user actor 和 system actor。

---

## 9.10 环境边界:dev / staging / prod 不能靠字符串隔离

`environment: prod` 是 metadata,不是墙。

真正的环境隔离应该由这些东西共同完成:

| 层 | 推荐做法 |
|----|----------|
| GCP project | dev / staging / prod 分项目或至少分 ServiceAccount |
| GCS bucket | 环境分 bucket 或强 prefix policy |
| Pub/Sub topic/subscription | 环境分离 |
| Control Plane deployment | 每环境独立 namespace / ServiceAccount |
| BigQuery dataset | prod dataset 只授予 prod SA |
| Secret Manager | prod secret 只授予 prod SA / Sidecar prod identity |
| Sidecar policy | caller SA -> allowed environments |
| Loader | metadata.environment 必须等于 deployment env |

### 9.10.1 一个错误示例

```text
dev Control Plane:
  serviceAccount: emf-control-plane-dev@team-a-project

DAG metadata:
  environment: prod

parameters:
  target_dataset: analytics_prod.orders
```

如果 IAM 没挡住,dev EMF 就可能写 prod dataset。

正确做法:

- dev SA 不具备 prod dataset 写权限。
- dev Loader 拒绝 `metadata.environment=prod`。
- Sidecar policy 不允许 dev caller 调 prod credential。
- CI 不允许 dev branch 发布到 prod GCS prefix。

### 9.10.2 metadata environment 的定位

`environment` 字段仍然重要。它提供:

- Loader guardrail。
- 告警路由。
- Run 页面过滤。
- dbt target 一致性检查。
- Sidecar request 上下文。

但它只是多层防线中的一层,不是唯一防线。

---

## 9.11 Run identity snapshot

为了审计和 replay,RunRecord 应该保存身份快照。

推荐结构:

```json
{
  "run_id": "run_123",
  "pipeline_name": "daily_export",
  "source": {
    "bucket": "team-a-emf-dags",
    "object": "prod/growth-analytics/daily_export.json",
    "generation": "1710000000000000",
    "metageneration": "1",
    "sha256": "..."
  },
  "metadata_snapshot": {
    "pipeline-name": "daily_export",
    "owner": "growth-analytics",
    "environment": "prod",
    "notification-channel": "slack://growth-data-alerts"
  },
  "identity_snapshot": {
    "uploader_principal": "serviceAccount:ci-growth-analytics@team-a-project.iam.gserviceaccount.com",
    "control_plane_service_account": "emf-control-plane@team-a-project.iam.gserviceaccount.com",
    "kubernetes_service_account": "emf-prod/emf-control-plane",
    "deployment_project": "team-a-project",
    "deployment_environment": "prod"
  },
  "runtime_snapshot": {
    "emf_version": "2026.04.23",
    "command_registry_version": "abc123",
    "dbt_artifact_sha256": "..."
  }
}
```

StepRunRecord 对 Sidecar command 还要补:

```json
{
  "step_id": "salesforce_export",
  "command": "SalesforceExport",
  "sidecar_identity_snapshot": {
    "caller_service_account": "emf-control-plane@team-a-project.iam.gserviceaccount.com",
    "sidecar_policy_team": "team-a",
    "credential_scope": "team:growth-analytics/salesforce",
    "credential_ref_hash": "sha256:...",
    "sidecar_service_account": "emf-sidecar@platform-project.iam.gserviceaccount.com"
  }
}
```

注意:

- 可以记录 `credential_ref_hash` 或 secret resource name,但不要记录 credential value。
- 如果 secret resource name 本身敏感,也可以只记录 stable credential id。
- 记录的是运行时快照,不是查询当前 policy 的结果。

---

## 9.12 Audit:几条日志要能串起来

一次 Run 的审计链至少涉及四类系统。

| 系统 | 记录什么 | 关键字段 |
|------|----------|----------|
| GCS Audit Logs | 谁上传 / 修改 DAG object | bucket/object/generation/principal |
| EMF State Store | 哪次 Run 执行哪版 DAG | run_id/source/metadata_snapshot |
| BigQuery Audit Logs | 哪个 GCP principal 执行 SQL/job | job_id/principal/labels |
| Sidecar ledger | 哪个 caller 调了哪个 vendor command | request_id/caller_sa/credential_scope |

推荐统一 correlation 字段:

```text
run_id
step_id
pipeline_name
owner
environment
gcs_bucket
gcs_object
gcs_generation
trace_id
idempotency_key_hash
```

### 9.12.1 BigQuery job labels

BigQuery job label 里不要塞太长或高敏字段。可以用:

```text
emf_run=run123short
emf_step=dbtrun
emf_owner=growth
emf_env=prod
emf_cmd=dbt
```

完整 run_id / step_id 放 State Store 和 logs,labels 里可以用短 ID 或受控编码。

### 9.12.2 Sidecar audit log

Sidecar 每个 request 至少记录:

```json
{
  "timestamp": "2026-04-23T10:00:00Z",
  "request_id": "sidecar_req_123",
  "run_id": "run_123",
  "step_id": "salesforce_export",
  "command": "SalesforceExport",
  "caller_service_account": "emf-control-plane@team-a-project.iam.gserviceaccount.com",
  "policy_team": "team-a",
  "owner": "growth-analytics",
  "environment": "prod",
  "credential_scope": "team:growth-analytics/salesforce",
  "idempotency_key_hash": "sha256:...",
  "vendor_operation": "query",
  "status": "SUCCEEDED",
  "error_code": null
}
```

不要记录:

- OAuth access token。
- refresh token。
- API key。
- vendor raw response。
- PII payload。

---

## 9.13 常见权限故障和归因

权限错误一定要标准化,否则用户只会看到一长串云厂商异常。

| 场景 | 建议错误码 | 归因对象 | 处理方式 |
|------|------------|----------|----------|
| Loader 读不到 DAG object | `DAG_SOURCE_ACCESS_DENIED` | 平台/Team IAM 配置 | 给 Control Plane SA 加只读权限 |
| metadata 缺 owner/env | `METADATA_MISSING` | DAG 发布 CI / 作者 | 修上传协议 |
| owner 与 prefix 不匹配 | `METADATA_POLICY_VIOLATION` | DAG 发布 CI / 作者 | 改 metadata 或发布路径 |
| Pub/Sub 无法消费 | `EVENT_SUBSCRIPTION_ACCESS_DENIED` | 平台/Team IAM 配置 | 修 subscription IAM |
| dbt 提交 BigQuery job 被拒 | `BQ_JOB_ACCESS_DENIED` | Team IAM 配置 | 给 Team SA jobUser |
| dbt 读源表被拒 | `BQ_DATA_ACCESS_DENIED` | 数据 owner / Team IAM | 授 dataset/table read |
| dbt 写目标表被拒 | `BQ_WRITE_ACCESS_DENIED` | 数据 owner / Team IAM | 授 target dataset write |
| 本地 command 读 Secret 失败 | `SECRET_ACCESS_DENIED` | Team IAM / secret owner | 授指定 secret access |
| Sidecar token audience 不对 | `SIDECAR_AUTH_FAILED` | Control Plane config | 修 audience / token 获取 |
| Sidecar policy 不允许 command | `SIDECAR_COMMAND_FORBIDDEN` | Sidecar policy owner | 更新 policy 或换 command |
| Sidecar 读 vendor secret 失败 | `SIDECAR_CREDENTIAL_ACCESS_DENIED` | 平台 IAM / credential owner | 修 Sidecar SA secret access |
| vendor 返回认证失败 | `VENDOR_AUTH_FAILED` | credential owner / 平台 | 轮换或重新授权 credential |

错误里应该带上安全可展示的上下文:

```json
{
  "code": "BQ_DATA_ACCESS_DENIED",
  "retryable": false,
  "message": "Control Plane ServiceAccount cannot read source dataset.",
  "details": {
    "control_plane_service_account": "emf-control-plane@team-a-project.iam.gserviceaccount.com",
    "dataset": "analytics_raw.orders",
    "owner": "growth-analytics",
    "environment": "prod"
  }
}
```

不要把完整 credential、token、vendor raw error body 放进去。

---

## 9.14 反模式

### 9.14.1 用 owner 做授权

```python
if metadata.owner in allowed_teams:
    execute_sensitive_command()
```

问题:owner 是 metadata 字符串,不是 authenticated principal。

正确做法:使用 IAM principal / Sidecar caller identity / policy。

### 9.14.2 DAG parameters 传 ServiceAccount key

```json
{
  "parameters": {
    "service_account_key": "{...}"
  }
}
```

这会绕过 Workload Identity 和 IAM 审计,也会让 State Store / logs / artifacts 变成泄露面。

### 9.14.3 一个超级 ServiceAccount 跑所有 Team

集中式平台最容易这么做:

```text
emf-prod@platform-project has access to every team's BigQuery datasets
```

这会带来:

- 最小权限失效。
- 审计归因困难。
- 一个 command bug 影响全公司数据。
- Team 环境隔离形同虚设。

EMF 的去中心化部署就是为了避免这个模式。

### 9.14.4 把中心 vendor secret 下发到每个 Team

这样每个 Team 都能绕过 Sidecar 直接调 vendor:

```text
Team Control Plane -> vendor API
```

结果:

- Sidecar rate limit 失效。
- Sidecar ledger 失效。
- vendor SDK 兼容逻辑分散。
- 凭证泄露面扩大。

### 9.14.5 metadata 里放 secret

GCS object metadata 不是 secret store。它适合放:

```text
owner
environment
pipeline-name
labels
notification-channel
```

不适合放:

```text
token
password
private-key
oauth-refresh-token
```

### 9.14.6 只靠 environment 字符串隔离

```text
metadata.environment=prod
```

不能替代:

- prod ServiceAccount。
- prod BigQuery IAM。
- prod Secret Manager IAM。
- prod Sidecar policy。
- prod GCS bucket/prefix 权限。

### 9.14.7 Sidecar 只做网络内网,不做身份认证

内网服务如果不校验 caller identity,就无法回答:

- 谁调用了 SalesforceExport?
- 该不该允许这个 Team 调?
- 用哪份 credential?
- 配额算谁的?
- 出问题通知谁?

---

## 9.15 AI 在身份/IAM上的位置

AI 可以帮很多忙,但不能成为权限系统。

适合 AI 做:

- 解释 `PERMISSION_DENIED` 是缺 project-level job permission,还是 dataset-level data permission。
- 根据错误信息生成最小权限建议。
- 检查 DAG parameters / metadata 是否疑似包含 secret。
- 检查 owner/prefix/environment 是否不一致。
- 生成 Sidecar policy 变更草案。
- 汇总某个 owner 最近的 IAM 失败模式。

不适合 AI 直接做:

- 自动授予 IAM 权限。
- 根据自然语言绕过 Sidecar policy。
- 从日志里恢复或推测 secret。
- 根据 metadata.owner 判定用户身份。
- 自动把 dev Run 升级成 prod Run。

AI 输出 IAM 建议时,应该带上依据:

```text
Observed:
  principal: emf-control-plane@team-a-project.iam.gserviceaccount.com
  operation: bigquery.jobs.create
  resource: project team-a-prod
  error: accessDenied

Suggested:
  grant job creation permission on project team-a-prod to the Control Plane ServiceAccount.
  verify dataset-level read/write permissions separately.
```

但最终授权仍然走公司 IAM review / IaC / admin workflow。

---

## 9.16 本章小结

1. **EMF 至少有六种身份**:`dag_owner`、`uploader_principal`、`control_plane_service_account`、`sidecar_caller_service_account`、`vendor_credential_scope`、`sidecar_runtime_service_account`。
2. **GCS metadata 的 owner 是治理字段,不是安全身份**。它用于告警、聚合、成本和责任归属,不能直接用于授权。
3. **上传者身份要从 GCS Audit Logs 或 CI 发布记录获取**,Pub/Sub Object Finalize 事件通常只告诉你对象和 generation。
4. **Team Control Plane ServiceAccount 是数据面的真实权限边界**。local / dbt / GCS / BigQuery 命令默认都在这个 IAM 边界里运行。
5. **生产环境应该用 Workload Identity,不要在 DAG、metadata、parameters、profiles.yml 里传 ServiceAccount key**。
6. **Sidecar 授权基于 caller ServiceAccount ID Token 和 Sidecar policy**,而不是 request body 里的 owner。
7. **vendor credential scope 必须由 Sidecar policy 选择**,区分 company-default、team-level、user-delegated 等模式。
8. **dev / staging / prod 不能靠字符串隔离**,必须由项目、ServiceAccount、bucket、dataset、secret、Sidecar policy 多层共同隔离。
9. **Run / Step 必须保存身份快照**,否则历史 replay 和审计会被后续 IAM / metadata / policy 变更污染。
10. **AI 可以辅助解释和生成建议,但不能替代 IAM / Sidecar policy / human review**。

---

## 9.17 需要结合真实代码确认的问题

- 当前 Control Plane 在 GKE 上是否已经使用 Workload Identity?KSA 与 GSA 的映射在哪里定义?
- DAG 上传是否已经统一走 CI?还是允许个人直接写 GCS bucket?
- GCS Object Finalize 事件里是否带有可用的 actor 信息?如果没有,是否已有 Audit Log correlation?
- GCS object metadata 的 owner/environment 是否有 prefix policy 校验?
- Control Plane ServiceAccount 是否拥有写 DAG source bucket 的权限?如果有,是否必要?
- dbt profiles.yml 当前如何生成?是否存在 service account key 或 credential file?
- Sidecar 当前用什么认证方式:ID Token、mTLS、API key,还是内部网络裸奔?
- Sidecar caller ServiceAccount 到 team / credential scope 的映射在哪里维护?
- vendor credential 是 company-default 还是 team-level?是否按 command 有差异?
- RunRecord / StepRunRecord 是否保存 identity snapshot,还是只保存 owner?
- IAM 错误是否已经标准化成 EMF error code,还是直接暴露云 SDK 异常?
