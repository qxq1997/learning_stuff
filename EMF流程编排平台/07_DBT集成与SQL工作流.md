# 07 · DBT 集成与 SQL 工作流

## 7.0 本章导读

前面第 5 章把 command 分成三类:

```text
local command   -> 进程内 Python 调用
dbt command     -> subprocess 执行 dbt CLI
sidecar command -> HTTP 调中心化 Sidecar
```

第 6 章已经展开 Sidecar。本章专门展开 dbt。

DBT 在 EMF 里的定位不是"另一个调度器",而是:

> 一组被 EMF command 化的 SQL transformation / test 能力。

也就是说:

- EMF 负责 DAG、Run、StepRun、parents、重试、观测、恢复。
- dbt 负责 SQL model 编译、依赖选择、执行、test、artifact 生成。
- BigQuery / GCS 仍然使用当前 Team 的 GCP ServiceAccount 和 IAM 边界。

本章要回答:

1. 为什么 dbt 不应该替代 EMF 调度器。
2. `dbt run / test / build` 如何包装成 command。
3. `profiles.yml`、`target`、`vars`、selector 如何注入。
4. dbt artifact 怎么采集成 Step output。
5. dbt 失败、超时、重试和恢复应该怎么定义。

---

## 7.1 dbt 在 EMF 里的职责边界

先划清边界。

| 能力 | EMF | dbt |
|------|-----|-----|
| GCS 事件触发 | 是 | 否 |
| DAG JSON 节点解析 | 是 | 否 |
| `parents` 跨 command 调度 | 是 | 否 |
| StepRun 状态机 | 是 | 否 |
| SQL model 编译 | 否 | 是 |
| SQL model 依赖选择 | 只传 selector | 是 |
| BigQuery 执行 SQL | 通过 dbt 间接触发 | 是 |
| dbt artifacts 生成 | 否 | 是 |
| artifact 归档 / output 标准化 | 是 | 产出原始 artifact |

最重要的一句话:

> dbt 管 SQL 项目内部的 model graph,EMF 管跨 command 的业务 workflow graph。

例如:

```text
EMF DAG:
ExportToGcs -> LoadToBigQuery -> RunDbt -> ExportReport

dbt graph:
stg_orders -> fct_orders -> mart_daily_sales
```

这两张图不要混在一起。EMF 不应该理解每个 dbt model 的 SQL 依赖,dbt 也不应该知道 EMF 的 GCS 事件和 Sidecar command。

---

## 7.2 为什么不直接用 dbt Cloud / dbt scheduler

dbt 自己也能调度,为什么还要放进 EMF?

因为 EMF 面对的是更宽的工作流:

- 先从外部 SaaS 拉数据。
- 写到 GCS。
- load 到 BigQuery。
- 再跑 dbt。
- 再导出报表。
- 最后通知业务方。

dbt 很强,但它主要解决 SQL transformation。它不适合承担:

- GCS object finalize 触发。
- 外部 API credential / rate limit。
- 非 SQL command 依赖。
- 多 Team 去中心化 framework 部署。
- 统一 Run / StepRun 状态机。
- Sidecar 外部副作用审计。

所以 EMF 集成 dbt 的正确姿势不是"用 EMF 重新实现 dbt",也不是"让 dbt 接管整个流程",而是把 dbt 当作一类 command。

---

## 7.3 DAG 中怎么调用 dbt

一个典型节点:

```json
{
  "id": "run_marketing_marts",
  "command": "RunDbt",
  "parents": ["load_campaigns_to_bq"],
  "parameters": {
    "project": "marketing_analytics",
    "selector": "tag:marketing",
    "target": "prod",
    "vars": {
      "business_date": "${business_date}",
      "source_dataset": "team_a_raw"
    }
  }
}
```

也可以拆成 `DbtRun`、`DbtTest`:

```json
[
  {
    "id": "dbt_run",
    "command": "DbtRun",
    "parents": ["load_raw_tables"],
    "parameters": {
      "project": "marketing_analytics",
      "select": "tag:marketing",
      "target": "prod",
      "vars": {
        "business_date": "${business_date}"
      }
    }
  },
  {
    "id": "dbt_test",
    "command": "DbtTest",
    "parents": ["dbt_run"],
    "parameters": {
      "project": "marketing_analytics",
      "select": "tag:marketing",
      "target": "prod"
    }
  }
]
```

### 7.3.1 `dbt build` 还是 `run + test`

两种都可以:

- `dbt build` 一次完成 run/test/snapshot/seed 等组合。
- `dbt run` + `dbt test` 分成两个 Step,状态更清楚。

EMF 里更推荐生产 DAG 使用拆开的方式:

```text
DbtRun -> DbtTest -> Publish
```

好处:

- `run` 成功但 `test` 失败时,UI 更清楚。
- 下游可以选择只依赖 `DbtRun` 或必须依赖 `DbtTest`。
- 失败重试粒度更细。

如果团队本来就习惯 `dbt build`,也可以封装 `DbtBuild` command,但它的 output 和失败语义要写清楚。

---

## 7.4 DBT Command Registry

dbt command 也必须走第 5 章的 Command Registry。

示例:

```json
{
  "name": "DbtRun",
  "kind": "dbt",
  "resource_group": "dbt",
  "input_schema": {
    "type": "object",
    "required": ["project", "select", "target"],
    "additionalProperties": false,
    "properties": {
      "project": {
        "type": "string"
      },
      "select": {
        "type": "string"
      },
      "exclude": {
        "type": "string"
      },
      "target": {
        "type": "string",
        "enum": ["dev", "staging", "prod"]
      },
      "vars": {
        "type": "object"
      },
      "full_refresh": {
        "type": "boolean",
        "default": false
      }
    }
  },
  "output_schema": {
    "type": "object",
    "required": ["artifact_uri", "run_results_uri", "status"],
    "properties": {
      "artifact_uri": {"type": "string", "format": "gcs_uri"},
      "manifest_uri": {"type": "string", "format": "gcs_uri"},
      "run_results_uri": {"type": "string", "format": "gcs_uri"},
      "models_succeeded": {"type": "integer"},
      "models_failed": {"type": "integer"},
      "status": {"type": "string"}
    }
  },
  "timeout": {
    "default": "1h",
    "max": "6h"
  },
  "retry_policy": {
    "max_attempts": 1,
    "retryable_errors": ["DBT_INFRA_TRANSIENT"]
  },
  "idempotency": {
    "mode": "destination_overwrite",
    "key_scope": "run_step"
  }
}
```

注意几个选择:

- `resource_group` 是 `dbt`,这样 Scheduler 可以限制 dbt subprocess 并发。
- 默认 `max_attempts` 可以很保守,因为 dbt 重跑可能很贵。
- output 不返回完整 artifact 内容,只返回 artifact URI。

---

## 7.5 dbt project 放在哪里

这是集成 dbt 时最先要定的问题。

常见三种方式:

### 7.5.1 跟 EMF 镜像打在一起

```text
Control Plane image
  /app/emf
  /app/dbt_projects/marketing_analytics
```

优点:

- 部署简单。
- dbt project 和 EMF runtime 版本一起固化。
- 没有运行时拉代码风险。

缺点:

- 每次改 SQL 都要重建 EMF 镜像。
- 多 Team project 会让镜像膨胀。
- 不符合"业务改 DAG 不 redeploy"的初衷。

### 7.5.2 挂载 Git repo / init container 拉取

```text
init container:
  git clone dbt repo
main container:
  dbt run --project-dir /workspace/dbt
```

优点:

- dbt project 可以独立发布。
- SQL 团队习惯 Git workflow。

缺点:

- 需要处理 commit pin。
- 网络/凭证/拉取失败会影响 Run。
- 必须把 dbt repo sha 记录进 Run。

### 7.5.3 GCS artifact 分发

CI 把 dbt project 打包上传到 GCS:

```text
gs://team-a-emf-artifacts/dbt/marketing_analytics/sha256.zip
```

EMF 在执行前下载并解压。

优点:

- 适合 GCP 原生链路。
- artifact 可 immutable。
- Run 记录可以 pin 到 artifact URI + sha256。

缺点:

- 要维护打包发布流程。
- 本地开发和生产发布要对齐。

### 7.5.4 推荐

如果目标是生产可回放,最推荐:

```text
CI 构建 dbt project artifact -> GCS immutable URI -> DAG parameters 或 metadata 引用 artifact version
```

Run 记录保存:

```json
{
  "dbt_project": "marketing_analytics",
  "dbt_project_uri": "gs://team-a-emf-artifacts/dbt/marketing_analytics/sha256.zip",
  "dbt_project_sha256": "..."
}
```

否则半年后你只能知道"跑了 marketing_analytics",但不知道当时 SQL 到底是哪一版。

---

## 7.6 profiles.yml 与身份边界

dbt 访问 BigQuery 需要 profile。EMF 的原则是:

> dbt 使用当前 Team Control Plane 的 GCP ServiceAccount,不使用 DAG 文件里传入的凭证。

`profiles.yml` 应该由平台生成,而不是让 DAG 作者手写 secret。

示例:

```yaml
marketing_analytics:
  target: prod
  outputs:
    prod:
      type: bigquery
      method: oauth
      project: team-a-project
      dataset: analytics
      location: US
      threads: 4
      priority: interactive
```

如果在 GKE Workload Identity 下运行,dbt 的 BigQuery client 会使用 Pod 对应的 ServiceAccount。

### 7.6.1 不要在 parameters 里传 credential

坏例子:

```json
{
  "parameters": {
    "service_account_key_json": "{...}"
  }
}
```

这会把凭证带进 DAG、State Store、日志、trace。正确做法是:

- GCP 资源访问走 Workload Identity / IAM。
- 第三方凭证走 Secret Manager / Sidecar。
- dbt profile 由平台模板生成。

### 7.6.2 target 与 environment 的关系

GCS object metadata 里有:

```text
environment: prod
```

dbt parameters 里也可能有:

```json
{
  "target": "prod"
}
```

这两者应该一致。Loader 或 Command Runner 可以校验:

```text
if metadata.environment == "prod" and parameters.target != "prod":
    fail
```

否则会出现 prod DAG 跑到 dev target,或者 dev DAG 写 prod dataset。

---

## 7.7 vars 注入

dbt vars 是 EMF 和 SQL model 之间最常见的参数桥。

DAG:

```json
{
  "parameters": {
    "vars": {
      "business_date": "${business_date}",
      "source_dataset": "team_a_raw",
      "run_id": "${run_id}"
    }
  }
}
```

执行命令:

```text
dbt run --select tag:marketing --target prod --vars '{"business_date":"2026-04-23","source_dataset":"team_a_raw","run_id":"run_123"}'
```

### 7.7.1 vars 要进入 parameters_snapshot

最终解析后的 vars 必须保存:

```json
{
  "vars": {
    "business_date": "2026-04-23",
    "source_dataset": "team_a_raw",
    "run_id": "run_123"
  }
}
```

这样 SQL 结果有问题时,能回答:

> 当时 dbt model 是用什么 vars 编译的?

### 7.7.2 vars 不要承载无限业务逻辑

vars 可以传日期、dataset、run id、feature flag。不要把复杂流程塞进 vars,例如:

```json
{
  "vars": {
    "execute_branch_a_then_b_unless_x": true
  }
}
```

这会让 dbt SQL 里充满条件逻辑,EMF DAG 图反而看不出真实流程。

---

## 7.8 subprocess 执行模型

dbt command 不应该在当前 Python 进程里 import dbt internal API 执行。更稳的是 subprocess:

```python
cmd = [
    "dbt",
    "run",
    "--project-dir", project_dir,
    "--profiles-dir", profiles_dir,
    "--target", target,
    "--select", selector,
    "--vars", json.dumps(vars),
    "--target-path", target_path,
]
```

原因:

- dbt CLI 是稳定边界。
- dbt 内部 API 变动更频繁。
- subprocess 可以 terminate/kill。
- stdout/stderr 可以独立采集。
- dbt 依赖和 EMF 进程依赖可以隔离。

### 7.8.1 工作目录

每个 Step 应该有独立 workdir:

```text
/tmp/emf/runs/{run_id}/{step_id}/
  project/
  profiles/
  target/
  logs/
```

不要多个 Step 共用同一个 `target/` 目录,否则 artifacts 会互相覆盖。

### 7.8.2 环境变量

dbt subprocess 环境变量要白名单化:

```python
env = {
    "DBT_PROFILES_DIR": profiles_dir,
    "GOOGLE_CLOUD_PROJECT": team_project,
    "EMF_RUN_ID": context.run_id,
    "EMF_STEP_ID": context.step_id,
}
```

不要把整个 Control Plane 进程环境无脑传给 dbt,否则 secret / token / 内部配置可能泄露到 dbt logs。

---

## 7.9 artifacts 采集

dbt 执行后会产生 artifacts:

```text
target/manifest.json
target/run_results.json
target/catalog.json
target/compiled/
```

EMF 应该把关键 artifacts 上传到 GCS result path:

```text
gs://team-a-emf-results/{run_id}/{step_id}/dbt/
  manifest.json
  run_results.json
  compiled.zip
  dbt.log
```

Step output 返回 URI:

```json
{
  "status": "success",
  "manifest_uri": "gs://team-a-emf-results/run_123/dbt_run/dbt/manifest.json",
  "run_results_uri": "gs://team-a-emf-results/run_123/dbt_run/dbt/run_results.json",
  "artifact_uri": "gs://team-a-emf-results/run_123/dbt_run/dbt/",
  "models_succeeded": 12,
  "models_failed": 0
}
```

不要把 `run_results.json` 整个塞进 State Store。它可能不算特别大,但长期看会让 State Store 变成 artifact 存储。

---

## 7.10 dbt 失败语义

dbt subprocess 的退出码不够表达全部语义。EMF 要解析 `run_results.json`。

常见情况:

| 情况 | Step 状态 | 错误 code | retryable |
|------|-----------|-----------|-----------|
| SQL 编译失败 | FAILED | `DBT_COMPILE_ERROR` | false |
| model SQL 执行失败 | FAILED | `DBT_MODEL_FAILED` | 视 BigQuery 错误 |
| test 失败 | FAILED | `DBT_TEST_FAILED` | false |
| BigQuery transient | RETRY_WAITING/FAILED | `DBT_INFRA_TRANSIENT` | true |
| profiles 配错 | FAILED | `DBT_PROFILE_ERROR` | false |
| subprocess timeout | TIMED_OUT | `DBT_TIMEOUT` | 视恢复能力 |

### 7.10.1 dbt test 失败是不是系统失败

是 Step 失败,但不是平台故障。

`DbtTest` 失败通常代表数据质量不满足预期:

```text
not_null failed
unique failed
accepted_values failed
relationship failed
```

应该返回:

```json
{
  "code": "DBT_TEST_FAILED",
  "retryable": false,
  "requires_manual_check": true,
  "details": {
    "failed_tests": 3,
    "run_results_uri": "gs://..."
  }
}
```

这会让下游 Step `CANCELLED_BY_PARENT`,Run 最终 `FAILED`,但告警对象应该是数据 owner,不是平台 on-call。

### 7.10.2 model 失败要区分 SQL 错误和基础设施错误

同样是 dbt run failed:

- SQL 语法错 -> 不重试。
- BigQuery rate limit -> 可以重试。
- dataset not found -> 多半不重试。
- temporary internal error -> 可以重试。

所以 dbt adapter 要解析 dbt artifact 和 BigQuery error,尽量标准化成 EMF Error Schema。

---

## 7.11 超时与取消

dbt 是 subprocess,比 local Python command 更容易处理超时。

推荐:

```python
proc = subprocess.Popen(...)
try:
    proc.wait(timeout=remaining_seconds)
except TimeoutExpired:
    proc.terminate()
    try:
        proc.wait(timeout=30)
    except TimeoutExpired:
        proc.kill()
```

### 7.11.1 terminate 不等于 BigQuery job 取消

杀掉 dbt 进程,不一定取消已经提交给 BigQuery 的 job。

所以 dbt command 最好:

- 记录 BigQuery job ids。
- 超时后尝试 cancel job。
- 如果不能确认 job 状态,返回 `SIDE_EFFECT_UNKNOWN` 或 `DBT_TIMEOUT_UNKNOWN`。

否则可能出现:

```text
EMF 标记 dbt timeout
但 BigQuery job 继续跑完并写了表
EMF 重试
第二次又写一遍
```

这类问题必须靠 job id、幂等 destination、dbt model 写入策略一起控制。

---

## 7.12 幂等与增量模型

dbt 的幂等比普通 export command 更微妙。

### 7.12.1 view / table 全量重建

如果 model 是 view 或全量 table:

```text
create or replace table ...
create or replace view ...
```

重复执行通常是幂等的,只要输入数据不变。

### 7.12.2 incremental model

incremental model 可能不是天然幂等:

```text
insert into target select ...
```

如果没有唯一键/merge 策略,重跑会重复写。

所以 dbt command 的幂等策略需要依赖 dbt project 规范:

- incremental model 必须配置 `unique_key`。
- 尽量使用 merge / insert_overwrite。
- 按 `business_date` 分区覆盖。
- 避免裸 append。

### 7.12.3 full_refresh 风险

`full_refresh: true` 是高风险参数。

建议:

- prod 默认禁止,除非 command policy 允许。
- 需要 GCS metadata / environment 校验。
- 或要求独立 command `DbtFullRefresh`。

不要让用户随手在 `parameters` 里打开:

```json
{
  "full_refresh": true
}
```

然后重建几十张生产表。

---

## 7.13 dbt 与 EMF parents 的关系

dbt 内部有自己的 model 依赖。EMF DAG 也有 parents。两者不要互相替代。

### 7.13.1 EMF parents 管跨 command 顺序

```json
{
  "id": "dbt_run",
  "command": "DbtRun",
  "parents": ["load_raw_tables"],
  "parameters": {
    "select": "tag:marketing"
  }
}
```

这里的 parent 表示:

> raw tables load 完之后,才能跑 dbt。

### 7.13.2 dbt selector 管 SQL model 范围

```text
dbt run --select tag:marketing+
```

这里的 selector 表示:

> 在 dbt project 内部选择哪些 model。

EMF 不应该展开 dbt manifest 并把每个 model 变成 EMF Step,除非有非常强的理由。否则:

- Step 数暴涨。
- EMF 和 dbt graph 双重调度。
- dbt artifact 语义被打碎。
- 失败恢复更复杂。

推荐 EMF Step 粒度是:

```text
一个 dbt selector / tag / model group
```

而不是每个 dbt model 一个 Step。

---

## 7.14 dbt logs 与 OTel

dbt stdout/stderr 很重要,但不能只靠日志文本。

EMF 应该:

- 保存完整 dbt log 到 GCS artifact。
- 从 `run_results.json` 提取结构化指标。
- 给 Step trace 加 dbt summary event。
- 不把每一行 dbt log 都打成 metric。

可提取指标:

| 指标 | 含义 |
|------|------|
| `emf.dbt.models_total` | 本次选中的 model 数 |
| `emf.dbt.models_succeeded` | 成功 model 数 |
| `emf.dbt.models_failed` | 失败 model 数 |
| `emf.dbt.tests_failed` | 失败 test 数 |
| `emf.dbt.duration_ms` | dbt CLI 总耗时 |

低基数 attributes:

- `pipeline_name`
- `environment`
- `dbt_project`
- `dbt_command`
- `target`

不要把 model name 全部作为 metric label。model name 可以进 artifact 或 trace event,否则 cardinality 会爆。

---

## 7.15 DBT Command Runner 伪代码

```python
def run_dbt_command(parameters: dict[str, Any], context: CommandContext) -> dict[str, Any]:
    spec = validate_and_resolve_dbt_parameters(parameters, context)

    workdir = prepare_workdir(context.run_id, context.step_id)
    project_dir = materialize_dbt_project(spec.project, spec.project_version, workdir)
    profiles_dir = render_profiles(spec.target, context, workdir)
    target_dir = workdir / "target"

    cmd = build_dbt_cli_args(
        action=spec.action,
        project_dir=project_dir,
        profiles_dir=profiles_dir,
        target=spec.target,
        select=spec.select,
        exclude=spec.exclude,
        vars=spec.vars,
        target_path=target_dir,
        full_refresh=spec.full_refresh,
    )

    result = run_subprocess_with_timeout(
        cmd=cmd,
        env=build_safe_env(context),
        cwd=project_dir,
        deadline=context.deadline,
    )

    artifacts = collect_dbt_artifacts(target_dir, workdir)
    artifact_uri = upload_artifacts_to_gcs(artifacts, context)

    parsed = parse_run_results(artifacts.run_results_json)
    if result.timed_out:
        raise CommandError(code="DBT_TIMEOUT", retryable=False)
    if result.exit_code != 0 or parsed.has_failures:
        raise to_dbt_command_error(result, parsed, artifact_uri)

    return {
        "status": "success",
        "artifact_uri": artifact_uri,
        "manifest_uri": artifact_uri + "/manifest.json",
        "run_results_uri": artifact_uri + "/run_results.json",
        "models_succeeded": parsed.models_succeeded,
        "models_failed": parsed.models_failed,
    }
```

几个关键点:

- `parameters` 先解析并 snapshot。
- profiles 由平台渲染。
- subprocess 有 deadline。
- artifacts 无论成功失败都尽量上传。
- output 只返回 artifact URI 和摘要。

---

## 7.16 常见反模式

### 7.16.1 把 dbt model 全部展开成 EMF Step

这会制造双重调度。除非你要跨 model 插入非 SQL command,否则不要这么做。

### 7.16.2 DAG parameters 直接传 service account key

这是严重安全问题。dbt 访问 BigQuery 应该走 Workload Identity / IAM。

### 7.16.3 不保存 artifact

dbt 失败后只留一段 stdout,很难排查。`manifest.json`、`run_results.json`、`dbt.log` 至少要保存。

### 7.16.4 无限制允许 full_refresh

生产环境随意 full refresh 可能导致成本、锁表、长时间运行和数据覆盖事故。

### 7.16.5 重试所有 dbt 失败

SQL 编译错误、test failed、profile 配错都不应该重试。只有明确 infra/transient 错误才重试。

---

## 7.17 AI 赋能 dbt 集成的位置

适合 AI:

- 解释 dbt test failure。
- 根据 `run_results.json` 总结失败 model。
- 从 compiled SQL 和 BigQuery error 推断根因。
- 建议 selector / tag 拆分。
- 检查 DAG 的 `DbtRun -> DbtTest` parents 是否合理。

不适合第一版就交给 AI:

- 自动修改生产 SQL 并执行。
- 自动打开 full_refresh。
- 自动忽略 failing tests。
- 根据自然语言绕过 dbt selector 直接拼 SQL。

AI 可以辅助解释和建议,但 dbt command 的执行仍然必须受 schema、IAM、artifact 和状态机约束。

---

## 7.18 本章关键结论

1. **dbt 在 EMF 里是 command adapter,不是调度器替代品**。EMF 管 workflow graph,dbt 管 SQL model graph。
2. **推荐生产 DAG 拆成 `DbtRun -> DbtTest`**,比一把 `dbt build` 更容易表达失败语义。
3. **dbt project 版本必须可追溯**,最好用 GCS immutable artifact + sha256。
4. **profiles.yml 应由平台生成**,BigQuery 访问走 Team ServiceAccount / IAM,不要在 parameters 里传凭证。
5. **vars 是 EMF 向 dbt SQL 注入运行参数的主通道**,解析后的 vars 必须进 parameters snapshot。
6. **dbt subprocess 要有独立 workdir、target path、safe env 和 deadline**。
7. **dbt artifacts 必须上传到 GCS**,Step output 只保存 URI 和摘要。
8. **dbt 失败要结构化区分 compile/model/test/profile/infra/timeout**,不能只看退出码。
9. **incremental model 的幂等依赖 dbt 项目规范**,尤其是 unique_key、merge、分区覆盖策略。
10. **不要把 dbt model 全部展开成 EMF Step**,除非确实需要跨 model 编排非 SQL command。

---

## 本章未定的问题(需要和真实代码校准)

- 当前 dbt project 是打进 EMF 镜像、Git 拉取,还是 GCS artifact 分发?
- 现在是否 pin dbt project commit / artifact sha256 到 Run 记录?
- profiles.yml 是用户提供、平台生成,还是镜像内置?
- dbt target 是否和 GCS object metadata 的 environment 做一致性校验?
- 当前使用 `dbt run/test/build` 哪些 command?是否拆分 run 与 test?
- dbt artifacts 现在保存到哪里?State Store、GCS result path,还是只在 Pod 本地?
- dbt subprocess 超时后是否会 cancel BigQuery job?
- incremental model 是否有统一规范来保证重跑幂等?
