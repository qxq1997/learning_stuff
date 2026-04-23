# 06 · Sidecar 服务:FastAPI on GKE

## 6.0 本章导读

前面几章里,Control Plane 都是每个 Team 自己部署的:

- DAG 文件在 Team 自己的 GCS bucket。
- Loader / Scheduler / Command Runner 跑在 Team 自己的 GKE namespace。
- 本地命令和 dbt 命令使用 Team 自己的 ServiceAccount。

但第 1 章已经讲过,EMF 架构里有一个刻意的非对称:

> 本地/数据命令去中心化,外部 API 命令中心化,统一走 Sidecar Service。

本章专门展开这个 Sidecar:

```text
Team A Control Plane
  sidecar command
        ↓ HTTP + Team SA ID Token
Central Sidecar Service (FastAPI on GKE)
        ↓ vendor credential / rate limit / retry / SDK
Salesforce / HubSpot / Jira / Slack / ...
```

Sidecar 要解决的不是"怎么发一个 HTTP 请求",而是四个组织级问题:

1. 第三方 SaaS 凭证通常是公司级共享资源,不适合散落到每个 Team 部署。
2. 第三方 rate limit 常常按公司账号计,必须集中治理。
3. SaaS SDK / API version / deprecation 需要平台团队统一维护。
4. 外部副作用需要统一的幂等、审计、错误语义和恢复策略。

---

## 6.1 Sidecar 的边界

Sidecar 只负责外部 API command,不负责 DAG。

它知道:

- 调用方是谁。
- 要调用哪个 vendor command。
- 参数是否合法。
- 应该使用哪份 vendor credential。
- 当前 vendor / team / command 是否还有配额。
- 怎么调用第三方 API。
- 怎么把第三方响应标准化成 command output。

它不知道:

- 整张 DAG 有哪些节点。
- 当前 Step 的 parents 是谁。
- Scheduler 什么时候调度下游。
- GCS DAG 文件长什么样。
- Run 最终是否成功。

这条边界非常重要。Sidecar 不是一个中心化 EMF 调度器,它只是外部 API command 的执行平面。

| 能力 | Control Plane | Sidecar |
|------|---------------|---------|
| DAG Loader | 是 | 否 |
| parents 拓扑调度 | 是 | 否 |
| StepRun 状态机 | 是 | 否 |
| command input/output schema | 拥有 registry snapshot | 必须兼容对应 command |
| vendor credential | 否 | 是 |
| vendor rate limit | 部分本地闸门 | 全局令牌桶 |
| vendor SDK / API version | 否 | 是 |
| 第三方副作用幂等 | 发 idempotency key | 落地执行和查询 |

---

## 6.2 为什么 Sidecar 必须中心化

如果每个 Team 都自己集成 Salesforce / HubSpot / Jira,会出现几个必然问题。

### 6.2.1 凭证散落

第三方 SaaS 的凭证常常不是 GCP IAM 能表达的:

- OAuth refresh token。
- API key。
- 公司级 app secret。
- vendor tenant id。

如果每个 Team 的 EMF 都存一份,会带来:

- 凭证复制扩散。
- rotate 困难。
- 审计困难。
- 某个 Team 配错影响 vendor 账号安全。

中心化 Sidecar 让凭证只在平台团队控制的 Secret Manager / KMS 边界里。

### 6.2.2 配额互相挤兑

很多 vendor 的限制是:

```text
整个公司账号每分钟 1000 次
整个 app 每天 100000 次
某个 OAuth token 每小时 5000 次
```

如果 Team A、Team B、Team C 各自部署外部 API client,它们彼此不知道对方用了多少配额。结果是:

```text
Team A 跑大批量同步
        ↓
公司级 Salesforce 配额耗尽
        ↓
Team B 的正常 DAG 也被 429
```

Sidecar 中心化后,可以按 vendor / operation / caller team 做统一令牌桶。

### 6.2.3 SDK 与 API version 维护

第三方 API 经常:

- deprecate 字段。
- 修改分页协议。
- 修改 rate limit header。
- OAuth 流程变化。
- SDK 版本升级带破坏性变化。

这些不应该让每个 Team 自己追。Sidecar 是平台团队维护外部 API 适配层的地方。

### 6.2.4 外部副作用需要统一审计

外部 API command 经常有副作用:

- 创建 ticket。
- 更新 CRM 字段。
- 发消息。
- 创建 campaign。
- 导出对象。

谁调用的、用什么参数、vendor 返回什么 request id、是否重试过,都需要统一审计。分散在各 Team 的本地命令里很难治理。

---

## 6.3 Sidecar 的服务形态

推荐形态:

```text
GKE Deployment
  FastAPI app
  uvicorn / gunicorn workers
  Secret Manager client
  Redis / Memorystore for rate limit and idempotency
  OTel instrumentation
  Internal Load Balancer / Private Service Connect
```

### 6.3.1 为什么 FastAPI

FastAPI 适合 Sidecar 的原因:

- Python 生态和 EMF Control Plane 一致。
- Pydantic 适合 request / response schema。
- OpenAPI 可以自动暴露 command endpoint 文档。
- async HTTP client 适合外部 API I/O。
- 业务代码不重,主要是 API adapter、限流、凭证、错误标准化。

FastAPI 不是重点,重点是 Sidecar 作为一个清晰的 HTTP execution boundary。

### 6.3.2 网络路径

Sidecar 不应该公网暴露。

推荐:

```text
Team Control Plane GKE namespace
        ↓ private network
Internal Load Balancer / Private Service Connect
        ↓
Central Sidecar GKE Service
```

如果 Team 分散在多个 GCP project / VPC,需要明确:

- VPC peering。
- Private Service Connect。
- Internal HTTPS LB。
- mTLS / ID token 校验。

网络层允许访问只是第一道门,真正身份仍然要在应用层校验。

---

## 6.4 HTTP 协议:Sidecar 也是 command runner

Sidecar endpoint 不应该暴露 vendor 原生 API。它应该暴露 EMF command 协议。

推荐统一入口:

```text
POST /v1/commands/{command_name}:execute
```

例如:

```text
POST /v1/commands/SalesforceExport:execute
```

请求:

```json
{
  "run_id": "run_123",
  "step_id": "export_campaigns",
  "attempt": 1,
  "idempotency_key": "run_123:export_campaigns",
  "pipeline": {
    "name": "daily_marketing_export",
    "owner": "growth-analytics",
    "environment": "prod"
  },
  "parameters": {
    "object": "Campaign",
    "updated_since": "2026-04-23",
    "destination_uri": "gs://team-a-export/run_123/campaigns.jsonl"
  },
  "deadline": "2026-04-23T10:30:00Z",
  "trace": {
    "traceparent": "00-..."
  }
}
```

响应:

```json
{
  "status": "SUCCEEDED",
  "output": {
    "gcs_uri": "gs://team-a-export/run_123/campaigns.jsonl",
    "row_count": 1240,
    "vendor_request_id": "sf_req_abc"
  }
}
```

错误响应:

```json
{
  "status": "FAILED",
  "error": {
    "code": "RATE_LIMITED",
    "message": "Salesforce API rate limit exceeded",
    "retryable": true,
    "requires_manual_check": false,
    "vendor_request_id": "sf_req_abc"
  }
}
```

### 6.4.1 为什么不一条 vendor 一个裸 endpoint

不要这样设计:

```text
POST /salesforce/query
POST /hubspot/contacts/search
POST /jira/tickets/create
```

这会让 Control Plane 直接感知 vendor API 细节,Command Registry 也会变得很散。

更好的方式是:

```text
EMF command -> Sidecar command adapter -> vendor API
```

DAG 作者和 Control Plane 面对的仍然是 command:

```json
{
  "command": "SalesforceExport",
  "parameters": {...}
}
```

vendor endpoint 变化由 Sidecar adapter 消化。

---

## 6.5 调用身份:Team ServiceAccount ID Token

Sidecar 是中心服务,必须知道谁在调用。

推荐 Control Plane 调 Sidecar 时带上:

```text
Authorization: Bearer <GCP ServiceAccount ID Token>
```

token audience 绑定 Sidecar:

```text
aud = https://sidecar.internal.company/v1
```

Sidecar 校验:

- token 签名合法。
- audience 正确。
- issuer 是 Google。
- subject / email 是允许的 Team ServiceAccount。
- token 未过期。

校验后得到 caller identity:

```json
{
  "service_account": "emf-team-a@team-a-project.iam.gserviceaccount.com",
  "team": "team-a",
  "project": "team-a-project"
}
```

### 6.5.1 为什么不能只靠网络来源

Internal LB / VPC 只能说明"请求来自内网",不能说明:

- 哪个 Team。
- 哪个 ServiceAccount。
- 是否是被允许的 EMF Control Plane。
- 应该用哪份 vendor credential。
- 应该算到哪个 quota bucket。

所以网络层是入口限制,ID Token 是调用身份。

### 6.5.2 是否需要 mTLS

mTLS 可以作为加强,但不要代替应用身份。

可选组合:

```text
Private network + ID Token
Private network + mTLS + ID Token
```

如果 Sidecar 只服务公司内部 GKE,`Private network + ID Token` 通常已经够用。对高敏 API 或跨 VPC 场景,可以加 mTLS。

---

## 6.6 授权:谁能调用哪个 Sidecar command

认证回答"你是谁",授权回答"你能做什么"。

Sidecar 需要一张 caller policy:

```json
{
  "team-a": {
    "service_accounts": [
      "emf-team-a@team-a-project.iam.gserviceaccount.com"
    ],
    "allowed_commands": [
      "SalesforceExport",
      "HubspotExport"
    ],
    "credential_scope": "team-a"
  },
  "team-b": {
    "service_accounts": [
      "emf-team-b@team-b-project.iam.gserviceaccount.com"
    ],
    "allowed_commands": [
      "SalesforceExport"
    ],
    "credential_scope": "company-default"
  }
}
```

授权失败返回:

```json
{
  "status": "FAILED",
  "error": {
    "code": "PERMISSION_DENIED",
    "message": "team-a is not allowed to execute command JiraCreateTicket",
    "retryable": false
  }
}
```

不要让 Sidecar 根据 DAG metadata 里的 `owner` 授权。`owner` 是业务归属,不是调用身份。真正授权基于 ServiceAccount / team policy。

---

## 6.7 凭证选择:公司级 vs Team 级

Sidecar 最难的设计之一是 vendor credential scope。

### 6.7.1 公司级凭证

所有 Team 共用同一份 vendor credential:

```text
Salesforce company OAuth app
HubSpot company API token
```

优点:

- 配置简单。
- credential rotate 集中。
- vendor 账号本来就是公司级时最自然。

缺点:

- Team 之间权限不可细分。
- 一个 Team 的误操作可能影响公司级数据。
- 审计要靠 Sidecar 自己记录 caller team。

### 6.7.2 Team 级凭证

同一个 vendor,不同 Team 用不同 credential:

```text
team-a/salesforce/oauth
team-b/salesforce/oauth
```

优点:

- 隔离更好。
- vendor 侧审计更清楚。
- Team 可以有不同权限范围。

缺点:

- 配置复杂。
- rotate 成本高。
- Sidecar 要做 credential routing。

### 6.7.3 推荐策略

先按 vendor 性质分类:

| vendor 类型 | 推荐 credential scope |
|-------------|-----------------------|
| 公司唯一账号,配额公司级 | company-default |
| vendor 支持多 workspace / 多 app | team-level |
| 高风险写操作 | team-level 或单独审批 |
| 纯读低风险导出 | company-default 可接受 |

Sidecar policy 要明确 credential selection:

```json
{
  "command": "SalesforceExport",
  "caller_team": "team-a",
  "credential_ref": "secretmanager://central/salesforce/company-default"
}
```

credential value 不进入 request、response、log、trace。

---

## 6.8 限流:全局令牌桶 + team 配额

Sidecar 必须集中做 rate limit。

至少三层:

```text
vendor global bucket
vendor operation bucket
caller team bucket
```

例如:

```json
{
  "salesforce": {
    "global": "1000/min",
    "operations": {
      "export": "200/min",
      "create": "50/min"
    },
    "teams": {
      "team-a": "100/min",
      "team-b": "50/min"
    }
  }
}
```

### 6.8.1 为什么 Control Plane 侧限流不够

第 4 章的 `resource_group` semaphore 只能保护单个 Team 的 Control Plane,它不知道其他 Team 正在调用 Sidecar。

Sidecar 的限流才是全局视角:

```text
Team A 80 QPS
Team B 50 QPS
Vendor total limit 100 QPS
```

如果不集中限流,vendor 返回 429 时已经晚了。

### 6.8.2 Rate limited 怎么返回

如果只是短暂等待,Sidecar 可以内部排队。但排队不能无限长,否则 Control Plane 的 Step 会卡死。

推荐:

- 能在 deadline 前拿到 token -> 等待后执行。
- 不能在 deadline 前拿到 token -> 返回 `RATE_LIMITED`。

错误:

```json
{
  "code": "RATE_LIMITED",
  "message": "Salesforce export quota exhausted for team-a",
  "retryable": true,
  "retry_after_seconds": 120
}
```

Control Plane 根据 `retry_after_seconds` 进入 `RETRY_WAITING`。

---

## 6.9 幂等:Sidecar 必须落地 request ledger

Control Plane 会传:

```text
Idempotency-Key: run_123:export_campaigns
```

Sidecar 不能只把它透传给 vendor。因为很多 vendor 不支持幂等键,或者支持方式不一致。

推荐 Sidecar 维护 request ledger:

```json
{
  "idempotency_key": "run_123:export_campaigns",
  "caller_team": "team-a",
  "command": "SalesforceExport",
  "request_hash": "sha256(parameters)",
  "status": "SUCCEEDED",
  "output": {
    "gcs_uri": "gs://...",
    "vendor_request_id": "sf_req_abc"
  },
  "created_at": "2026-04-23T10:00:00Z",
  "updated_at": "2026-04-23T10:01:00Z"
}
```

处理规则:

- 相同 key + 相同 request hash + 已成功 -> 返回相同 output。
- 相同 key + 不同 request hash -> 返回 `IDEMPOTENCY_CONFLICT`。
- 相同 key + 正在执行 -> 返回 in-progress 或等待。
- 相同 key + 上次 `SIDE_EFFECT_UNKNOWN` -> 进入恢复查询,不要盲目重放。

### 6.9.1 为什么 ledger 要在 Sidecar

因为副作用发生在 Sidecar 到 vendor 之间。Control Plane 只能知道"我发了请求",不知道 vendor 是否接受。

Sidecar ledger 能记录:

- vendor request id。
- vendor response body 摘要。
- retry attempts。
- rate limit header。
- credential scope。
- side effect status。

这些都是恢复和审计需要的信息。

---

## 6.10 错误语义:把 vendor 错误翻译成 EMF 错误

Vendor 错误千奇百怪:

```text
HTTP 400
HTTP 401
HTTP 403
HTTP 404
HTTP 409
HTTP 429
HTTP 500
SDK Timeout
OAuth refresh failed
pagination token invalid
```

Sidecar 要把它们标准化成第 5 章的 CommandError:

```json
{
  "code": "UPSTREAM_5XX",
  "message": "Salesforce returned 503",
  "retryable": true,
  "requires_manual_check": false,
  "vendor": "salesforce",
  "vendor_status": 503,
  "vendor_request_id": "sf_req_abc"
}
```

常见映射:

| vendor 情况 | EMF error code | retryable |
|-------------|----------------|-----------|
| 400 参数错误 | `INVALID_PARAMETERS` | false |
| 401/403 凭证或权限 | `AUTH_FAILED` / `PERMISSION_DENIED` | false |
| 404 资源不存在 | `NOT_FOUND` | 视 command 而定 |
| 409 幂等冲突 | `IDEMPOTENCY_CONFLICT` | false |
| 429 限流 | `RATE_LIMITED` | true |
| 5xx | `UPSTREAM_5XX` | true |
| 请求超时且状态未知 | `SIDE_EFFECT_UNKNOWN` | false/manual |

不要把 vendor 原始错误完整暴露给 DAG 作者,尤其不要带 credential、token、PII。原始细节可以进受控审计日志。

---

## 6.11 输出协议:Sidecar 返回也要符合 command output schema

Sidecar command 仍然是 EMF command,所以 output 必须符合 Command Registry。

例如 `SalesforceExport.output_schema`:

```json
{
  "type": "object",
  "required": ["gcs_uri", "row_count", "vendor_request_id"],
  "properties": {
    "gcs_uri": {"type": "string", "format": "gcs_uri"},
    "row_count": {"type": "integer"},
    "vendor_request_id": {"type": "string"}
  }
}
```

Sidecar 不应该直接返回 vendor 原始 JSON:

```json
{
  "records": [...],
  "nextRecordsUrl": "...",
  "attributes": {...}
}
```

外部 API 原始响应通常:

- 太大。
- 字段不稳定。
- 混杂 vendor 内部细节。
- 可能包含敏感信息。

Sidecar 应该把它转成稳定 output,大产物落到 GCS / BigQuery / vendor artifact,output 只返回 URI 和摘要。

---

## 6.12 FastAPI 内部模块

一个合理的 Sidecar 代码结构:

```text
sidecar/
  app.py
  auth/
    id_token.py
    policy.py
  commands/
    registry.py
    salesforce_export.py
    hubspot_export.py
    jira_create_ticket.py
  credentials/
    secret_manager.py
    credential_router.py
  rate_limit/
    limiter.py
    redis_bucket.py
  idempotency/
    ledger.py
  vendors/
    salesforce_client.py
    hubspot_client.py
  observability/
    tracing.py
    metrics.py
```

主请求流程:

```python
@app.post("/v1/commands/{command_name}:execute")
async def execute_command(command_name: str, request: ExecuteCommandRequest):
    caller = await authenticate_id_token(request)
    authorize(caller, command_name)

    command = registry.get(command_name)
    validate_input(command.input_schema, request.parameters)

    credential = credential_router.resolve(caller, command)
    await rate_limiter.acquire(caller, command, request.deadline)

    with idempotency_ledger.start_or_replay(request.idempotency_key, request):
        output = await command.execute(
            parameters=request.parameters,
            credential=credential,
            context=build_sidecar_context(caller, request),
        )

    validate_output(command.output_schema, output)
    return {"status": "SUCCEEDED", "output": output}
```

真实代码里细节会更多,但顺序不要乱:

```text
auth -> authorize -> validate -> credential -> rate limit -> idempotency -> execute -> validate output
```

尤其不要先拿 credential 再授权,也不要先调用 vendor 再写 idempotency ledger。

---

## 6.13 部署与扩缩容

Sidecar 是中心服务,要按线上服务对待。

### 6.13.1 Deployment

推荐:

```text
GKE Deployment
  min replicas: 2+
  HPA: CPU + request latency + queue depth
  PodDisruptionBudget
  readiness / liveness probes
  separate service account
```

Sidecar 的 ServiceAccount 应该只能读它需要的 Secret Manager 条目,不要给全项目 owner。

### 6.13.2 依赖存储

Sidecar 需要两类状态:

- rate limit token bucket。
- idempotency ledger。

可选:

| 存储 | 适合内容 |
|------|----------|
| Redis / Memorystore | 短期 token bucket、短期 in-flight lock |
| Postgres / Cloud SQL | idempotency ledger、审计状态 |
| Firestore | 简化运维的 ledger / policy |

不要只把 idempotency ledger 放内存。Pod 重启后会丢,重试就可能重复产生副作用。

### 6.13.3 灰度发布

Sidecar 升级比 framework 升级更敏感,因为它影响所有 Team。

推荐:

- command adapter 版本兼容。
- 新 vendor SDK 先 shadow / canary。
- 按 command 或 team 灰度。
- 保留旧 adapter 一段时间。
- 观测 4xx / 5xx / latency / vendor quota。

---

## 6.14 观测与审计

Sidecar 至少要记录:

- caller team。
- caller service account。
- command name。
- vendor。
- credential scope。
- idempotency key hash。
- vendor request id。
- retry attempts。
- rate limit wait time。
- normalized error code。

指标:

| 指标 | 含义 |
|------|------|
| `emf.sidecar.requests_total` | Sidecar command 请求数 |
| `emf.sidecar.errors_total` | 标准化错误数 |
| `emf.sidecar.rate_limited_total` | 限流次数 |
| `emf.sidecar.rate_limit_wait_ms` | 等 token 的时间 |
| `emf.sidecar.vendor_latency_ms` | vendor API 耗时 |
| `emf.sidecar.idempotency_replay_total` | 幂等命中重放次数 |
| `emf.sidecar.side_effect_unknown_total` | 副作用未知次数 |

低基数 labels:

- `command`
- `vendor`
- `caller_team`
- `environment`
- `error_code`

不要直接把下面内容打进 metric label:

- vendor request id。
- full idempotency key。
- full GCS URI。
- 原始 vendor error message。

审计日志可以保存更多,但要经过脱敏。

---

## 6.15 Sidecar 与 Control Plane 的契约

Control Plane 侧的 SidecarCommandAdapter 应该非常薄:

```python
class SidecarCommandAdapter:
    def run(self, parameters: dict[str, Any], context: CommandContext) -> dict[str, Any]:
        token = id_token_provider.get_token(audience=SIDECAR_AUDIENCE)
        response = http.post(
            f"{SIDECAR_URL}/v1/commands/{self.spec.name}:execute",
            headers={
                "Authorization": f"Bearer {token}",
                "Idempotency-Key": context.idempotency_key,
                "traceparent": context.traceparent,
            },
            json={
                "run_id": context.run_id,
                "step_id": context.step_id,
                "attempt": context.attempt,
                "idempotency_key": context.idempotency_key,
                "pipeline": {
                    "name": context.pipeline_name,
                    "owner": context.owner,
                    "environment": context.environment,
                },
                "parameters": parameters,
                "deadline": context.deadline.isoformat(),
            },
            timeout=context.remaining_seconds,
        )
        return normalize_sidecar_response(response)
```

Control Plane 不应该:

- 读取 vendor secret。
- 自己实现 vendor pagination。
- 自己解释 vendor rate limit header。
- 在 DAG 层暴露 vendor 原始 API。

它只把 command 请求交给 Sidecar,并消费标准 output / error。

---

## 6.16 常见反模式

### 6.16.1 Sidecar 变成中心化调度器

如果 Sidecar 开始知道 DAG、parents、Run 状态,架构就会混乱。它应该只执行 command,不调度 workflow。

### 6.16.2 每个 Team 自己带 vendor credential

这会把 Sidecar 的价值打掉。除非是明确的 team-level credential 策略,否则 vendor credential 不应该从 Control Plane request 传入。

### 6.16.3 直接透传 vendor API

如果 Sidecar 只是代理:

```text
/proxy/salesforce/*
```

那它没有提供 command schema、错误标准化、幂等和审计,只是多了一跳网络。

### 6.16.4 无 idempotency ledger

没有 ledger,超时/重试/Pod 重启时就很难知道副作用是否发生。所有写类 Sidecar command 都应该接入 ledger。

### 6.16.5 原始 vendor response 直接进 output

这会污染 State Store,也会把 vendor schema 变化传染给 DAG 下游。Sidecar 必须做 output 标准化。

---

## 6.17 AI 赋能 Sidecar 的位置

Sidecar 是未来 AI command 化的一个抓手,但要谨慎。

适合 AI 介入:

- 根据 vendor 文档辅助生成 adapter 初稿。
- 把 vendor error 翻译成可读修复建议。
- 分析最近的 rate limit / auth failure 模式。
- 帮平台团队发现某个 command 的参数设计不清。

不适合第一版就交给 AI:

- 动态决定调用哪个 vendor endpoint。
- 动态生成生产请求字段。
- 绕过 registry schema 调 vendor。
- 自动处理高风险写操作。

Sidecar 的第一职责是稳定和治理。AI 可以辅助开发和排障,但不能替代 command spec。

---

## 6.18 本章关键结论

1. **Sidecar 是外部 API command 的中心执行平面,不是中心化 DAG 调度器**。
2. **Sidecar 中心化的原因是 vendor 凭证、公司级配额、SDK/API 维护和外部副作用审计**。
3. **Control Plane 调 Sidecar 要带 Team ServiceAccount ID Token**,网络内网访问不能替代身份认证。
4. **授权基于 caller ServiceAccount / team policy**,不要基于 DAG metadata 的 owner 字段做安全决策。
5. **凭证选择要明确 company-default 与 team-level 的边界**,credential value 不进入 request/response/log。
6. **Sidecar 要做全局 rate limit**,Control Plane 的 resource_group semaphore 只能保护单个 Team。
7. **Sidecar 必须维护 idempotency ledger**,尤其是写类外部 API command。
8. **Vendor 错误要翻译成 EMF 标准错误**,让 Scheduler 能判断 retry / manual check。
9. **Sidecar output 必须符合 command output schema**,不要把 vendor 原始响应直接塞回 State Store。
10. **Sidecar 是平台团队真正需要 on-call 的中心服务**,部署、灰度、观测和审计都要按线上服务标准做。

---

## 本章未定的问题(需要和真实代码校准)

- Sidecar 当前是否已经存在?如果存在,endpoint 是按 command 统一入口,还是按 vendor 拆 endpoint?
- Control Plane 现在用 ID Token、mTLS、API key,还是别的方式调用 Sidecar?
- caller team 与 ServiceAccount 的映射在哪里维护?
- vendor credential 是 company-default 还是 team-level?是否按 command 有差异?
- Sidecar 的 rate limit 状态存在哪里?Redis / DB / 内存?
- 是否已有 idempotency ledger?如果没有,写类 API command 如何避免重复副作用?
- Sidecar 错误是否已经标准化成 `code / retryable / requires_manual_check`?
- Sidecar 是否会把 vendor 原始 response 落 State Store?如果会,需要评估敏感信息和 schema 漂移风险。
