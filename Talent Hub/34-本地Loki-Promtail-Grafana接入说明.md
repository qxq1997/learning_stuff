# 本地 Loki、Promtail、Grafana 接入说明

## 目标

在本地 Docker 环境中，把 TalentHub backend 的结构化日志接到可查询、可过滤、可视化的日志平台里。

当前采用的方案是：

- backend 写 JSON 日志到标准输出
- backend 同时写 JSON 日志到本地文件
- Promtail 抓取本地日志文件
- Loki 存储日志
- Grafana 查询和展示日志

## 为什么不用直接抓 Docker stdout

在 Docker Desktop for Mac 环境下，直接让 Promtail 抓容器内部 stdout 对宿主机不够友好，配置也更绕。

当前方案更稳定：

- backend 把日志写到 `storage_data/logs/backend.log`
- 这个目录已经通过 volume 映射到宿主机
- Promtail 直接抓这个共享目录

这样更清晰，也更容易调试。

## 当前接入范围

当前接入的是：

- TalentHub backend 结构化日志

还没有单独接入：

- PostgreSQL 容器日志
- Redis 容器日志
- MinIO 容器日志

如果后续需要，这几类也可以继续纳入 Loki。

## Docker Compose 服务

当前 compose 新增了三个服务：

- `loki`
- `promtail`
- `grafana`

默认端口：

- Loki: `3100`
- Grafana: `3000`

## Grafana 访问方式

- 当前本地环境默认开启匿名访问
- 直接打开 `http://localhost:3000` 即可进入
- 登录表单默认关闭，避免本地使用时每次都要手动登录

说明：

- 这是本地开发态配置，目的是降低使用成本
- Grafana 内部仍保留管理员账号配置，后续如果你想切回登录模式，只需要把 compose 里的匿名访问开关关掉

## 启动方式

启动整套本地环境：

```bash
docker compose -f docker-compose.local.yml up -d --build
```

或：

```bash
make up
```

如果只想启动观测栈：

```bash
make observability-up
```

## 日志文件位置

当前 backend 默认会把日志写到：

- `storage_data/logs/backend.log`

同时保留滚动文件配置：

- 单文件大小默认 `10 MB`
- 默认保留 `5` 个备份文件

相关配置：

- `LOG_FILE_PATH`
- `LOG_FILE_MAX_BYTES`
- `LOG_FILE_BACKUP_COUNT`

说明：

- 本地直接运行 backend 时，`LOG_FILE_PATH` 推荐配置成 `../storage_data/logs/backend.log`
- Docker Compose 里的 backend 已经固定覆盖成 `/app/storage_data/logs/backend.log`

## Grafana 预置内容

当前已经预置：

- Loki 数据源 `TalentHub Loki`
- Dashboard：`TalentHub Logs`

Dashboard 里当前包含：

- Backend Structured Logs
- Log Volume
- Warnings Or Errors In Last 5m

## 适合怎么用

### 快速排查

先看：

```bash
docker compose -f docker-compose.local.yml logs -f backend
```

或者：

```bash
make logs-backend
```

### 精确查问题

再进 Grafana：

- 用 `request_id` 查一次完整请求
- 用 `actor_email` 查某个账号操作
- 用 `error_code` 查失败请求
- 用 `event` 查业务动作，比如 `question_preview_generated`

## 当前日志字段

当前统一结构化字段包括：

- `timestamp`
- `level`
- `logger`
- `event`
- `request_id`
- `actor_email`
- `method`
- `path`
- `status_code`
- `latency_ms`
- `error_code`

业务日志可能附带：

- `resource_id`
- `document_id`
- `question_id`
- `exam_paper_id`
- `assignment_id`
- `attempt_id`
- `provider`
- `model`
- `tokens_in`
- `tokens_out`
- `source_url`

## 验证方式

推荐这样验证接入是否正常：

1. 启动本地环境
2. 调一次 `GET /api/v1/healthz`
3. 导入一份知识库文档
4. 做一次题目生成或考试提交
5. 打开 Grafana 看 `TalentHub Logs`

如果能看到：

- `request_started`
- `request_finished`
- `knowledge_document_imported`
- `llm_question_generation_started`
- `llm_question_generation_succeeded`

说明整条链路已经通了。

## 后续可扩展方向

后面可以继续做：

1. 接入 PostgreSQL / Redis / MinIO 日志
2. 基于 `error_code` 做 Grafana 告警
3. 把 `llm_jobs` 指标和 Loki 日志联动
4. 增加部门、资源、模型维度的查询面板
