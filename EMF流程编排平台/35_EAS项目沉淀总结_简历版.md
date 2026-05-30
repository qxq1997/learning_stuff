# EAS 项目沉淀总结（简历版）

## 1. 项目定位

EAS（emf-api-service）是一个企业级 API 编排与数据落地中间层服务。它对外提供统一入口（核心为 `/v1/call`），用于调用外部 REST 服务（当前主干实现以 RADAR 和 MOCKUP 为主），并将处理后的结果写入 Azure Databricks Unity Catalog。

它的核心价值是：把“外部接口对接复杂度”从下游业务系统中抽离，统一处理鉴权、限流、重试、分页、数据转换、结果落地与异常治理。

## 2. 技术栈

- 语言与服务框架：Python 3.12、FastAPI、Uvicorn
- 网络与调用：requests、aiohttp
- 数据校验与模型：Pydantic
- 限流：slowapi（全局 + 服务粒度）
- 认证鉴权：Azure AD JWT（JWKS、issuer/audience 校验、object id 白名单）
- 云能力：Azure Blob Storage、Azure Key Vault、Azure Databricks Unity Catalog
- 可观测性：Azure Log Analytics
- 工程化：Docker 多阶段构建、Helm（AKS）、Terraform（Identity/权限/IaC）
- 测试：unittest、integration tests、httpx

## 3. 已实现核心能力

1. 统一 API 入口与服务路由

- 通过 `/v1/call` 收口外部服务调用，统一请求校验、日志上下文（`call_uuid`）、异常包装与响应模型。

2. 可扩展 RestService 执行框架

- 抽象通用执行骨架（构建器 + 执行态 + 服务映射），支持按 `service_name` 扩展具体服务实现。
- 内置分页拉取、认证刷新、错误处理、回退重试、行数校验等能力。

3. 企业级安全治理

- Azure JWT 校验 + `allowed_object_ids` 授权控制。
- TLS、安全响应头（CSP/HSTS/XFO 等）、异常详情脱敏。

4. 稳定性与运行保障

- 指数退避重试（429/5xx 等场景）。
- 健康检查 `/health`、heartbeat 定时触发。

5. 数据落地能力

- 结果通过 Azure Databricks 客户端写入 Unity Catalog。
- 支持结果路径导入与表写入策略控制。

## 4. 重点机制：对象存储缓冲 + 多线程处理

这部分是本项目中最值得在面试里展开的工程点。

### 4.1 背景问题

当外部 API 返回大量分页数据时，如果把所有 page 都积压在内存里再统一处理，容易导致内存峰值过高甚至 OOM。

### 4.2 解决方案（生产者-消费者并发模型）

- 主线程（生产者）：负责持续拉取分页数据。
- 工作线程（消费者）：负责把 page 做数据转换后，立即写入对象存储临时目录。
- 共享缓冲区：使用有界队列承接 page 数据，连接“拉取”与“处理”。

这使流程从“先全部拉完再处理”的串行模式，升级为“边拉边处理边落盘”的流水线模式。

### 4.3 为什么能降低内存压力

- 数据尽早落盘到对象存储，避免在进程内长期堆积。
- 队列可配置上限（`max_pending_page_in_queue`），形成背压：当消费速度暂时落后时，生产侧会受控等待，而不是无限涨内存。
- 工作线程数可配置（`data_processing_workers_num`），可根据资源调优吞吐。

### 4.4 精准表述（面试/简历推荐）

不是“完全无阻塞”，而是“并行解耦 + 有界背压”。

推荐表达：

“将分页拉取与数据处理拆分为生产者-消费者并发流水线：主线程持续抓取分页数据，工作线程并行完成转换并落盘对象存储；通过有界队列背压控制内存峰值，支撑大批量分页场景下的稳定处理。”

## 5. 技术挑战、生产问题与应对方案

这一部分适合面试时展开讲，重点体现后端工程能力、稳定性意识和生产问题处理经验。

### 5.1 外部 API 不稳定与协议差异

#### 技术挑战

- EAS 本质上是外部 API broker，中间层无法完全控制下游服务的稳定性。
- 外部服务可能返回 429、500、503、504 等临时错误，也可能出现认证 token 过期、响应体格式变化、分页协议异常等情况。
- RADAR 这类服务还存在比较特殊的场景：HTTP 200 但 result 为空，next token 仍不为 NA，需要判断是合法空结果还是需要继续重试。
- 不同外部服务的分页字段、认证方式、请求体模板、响应结果位置都可能不同，如果直接写在业务逻辑里，会导致代码难以扩展和维护。

#### 可能遇到的生产问题

- 外部服务短时间抖动导致请求失败率升高。
- 429 限流触发后，如果没有退避策略，会进一步放大对外部服务的压力。
- 某一页分页数据异常，可能导致整次调用失败或结果不完整。
- 外部接口返回结构发生变化，导致数据转换失败。
- 认证 token 过期或密钥轮换后，请求出现 401/403。

#### 应对方案

- 抽象 RestService 通用执行框架，把分页、认证刷新、异常处理、重试、行数校验封装为可复用能力。
- 对 429/5xx 等临时错误使用指数退避重试，避免瞬时失败直接影响用户调用。
- 针对 RADAR 实现服务级特殊逻辑，例如空 result + next token 的重试处理、SQL 一致性校验、行数一致性校验。
- 通过 `service_name` 到具体 RestService 的映射机制，将服务差异收敛到各自子类中，避免主流程被服务细节污染。

### 5.2 大批量分页数据带来的内存压力

#### 技术挑战

- 外部 API 可能一次调用返回大量分页数据，如果全部 page 都保存在内存中，再统一转换和写入，很容易导致内存峰值过高。
- 在容器或 VM 资源有限的生产环境中，内存暴涨可能导致 OOM Kill，进而造成请求中断、临时数据丢失或服务重启。
- 数据拉取速度和数据转换/导出速度不一定一致，如果生产速度远高于消费速度，内存队列会持续堆积。

#### 可能遇到的生产问题

- Pod 或进程因为内存超限被杀掉。
- 单个大请求占用过多内存，影响其他请求的响应。
- 数据转换线程异常退出，但主线程还在继续拉取数据，造成数据处理链路不完整。
- 对象存储临时文件写入失败或清理失败，造成脏数据残留。

#### 应对方案

- 使用“生产者-消费者”并发流水线：主线程负责分页拉取，工作线程负责转换和导出。
- 生产者把 page 放入 `pending_page_buffer`；在对象存储模式下，`pending_page_buffer` 是有界队列。
- 消费者线程从队列取 page，转换后写入对象存储临时目录，最终主流程再从对象存储路径批量写入 Databricks。
- 通过 `max_pending_page_in_queue` 控制队列上限，形成背压，防止无限制堆积。
- 通过 `data_processing_workers_num` 控制消费者线程数，根据生产环境 CPU、网络和对象存储吞吐进行调优。
- worker 如果提前异常退出，主线程会 fail fast，避免继续拉取但无人消费。
- 请求结束后清理对象存储临时目录，降低脏数据残留风险。

### 5.3 认证授权、密钥与证书管理

#### 技术挑战

- EAS 需要同时处理入口调用方认证和下游外部服务认证。
- 入口侧需要校验 Azure AD JWT，包括签名、issuer、audience、tenant、过期时间和 object id 白名单。
- 下游服务可能使用不同认证方式，如 Basic、JWT、LDAP、Keepie、Kestrel JWT 等。
- 云上运行还涉及 Managed Identity、Key Vault、证书挂载、TLS 配置等安全能力。

#### 可能遇到的生产问题

- 调用方 token audience 或 tenant 配置不一致，导致合法用户被拒绝。
- Azure JWKS key rotation 后，如果缓存没有刷新，可能出现验签失败。
- 容器时间漂移导致 JWT exp/nbf/iat 校验失败。
- Managed Identity 权限配置错误，导致访问 Key Vault、Blob Storage、Databricks 或 Log Analytics 失败。
- TLS 证书未挂载或过期，导致服务启动失败或探针失败。

#### 应对方案

- 入口统一使用 AccessTokenBearer 做 Azure JWT 校验，并通过 `allowed_object_ids` 控制调用方权限。
- 使用 Key Vault 管理敏感信息，避免密钥硬编码。
- 在 AKS 中通过 Workload Identity 绑定 Managed Identity，减少长期密钥暴露。
- 对外响应做异常脱敏，只返回必要错误信息，详细堆栈进入内部日志。
- 使用安全响应头、TLS 和服务级限流，降低安全风险。

### 5.4 多环境配置与服务参数管理

#### 技术挑战

- 项目存在 dev、ci、preprod、prod、liq、rwa 等多套环境配置。
- `app_config` 控制服务运行参数，`api_config` 控制外部服务请求参数、认证参数、body 模板、结果字段位置等。
- 不同环境的 endpoint、证书、Key Vault、Databricks、对象存储路径、限流参数都可能不同。

#### 可能遇到的生产问题

- 环境配置不一致导致本地/CI 正常，但生产失败。
- API body 模板或参数替换错误，导致外部服务返回业务错误。
- `api_config` 缓存未刷新，配置变更后服务仍使用旧配置。
- `result_project`、dataset、table 配置错误，导致写入错误表或无权限写入。
- 限流配置过高可能压垮下游服务，过低可能影响业务吞吐。

#### 应对方案

- 使用 AppConfig + ApiConfigReader 统一读取配置，减少散落配置。
- 支持参数替换和 `service_request_params` 覆写，避免大量硬编码。
- 使用 `config_template` 与 Helm ConfigMap 管理不同环境配置。
- 对关键配置进行启动时加载和日志记录，便于排查环境差异。
- 支持 `cache_api_config_file` 机制，在配置更新后刷新缓存。

### 5.5 数据落地一致性与 Databricks 写入

#### 技术挑战

- EAS 不只是调用 API，还要把结果转换成可入库格式，并写入 Azure Databricks Unity Catalog。
- 不同外部 API 的返回字段结构不同，需要做统一转换。
- 写入目标表时要考虑表名映射、schema、写入策略、空结果、重复写入和失败重试。
- 对象存储临时文件到 Databricks 表之间存在多阶段链路，任何一步失败都可能导致结果不完整。

#### 可能遇到的生产问题

- 返回数据 schema 变化，导致 Databricks 写入失败。
- `WRITE_EMPTY`/`WRITE_TRUNCATE` 使用不当，可能导致重复写入或覆盖已有数据。
- Databricks cluster 不可用、连接超时、token 获取失败。
- 临时对象存储文件已生成，但最终写入 Databricks 失败，需要清理和重试。
- API 返回 0 行时，是否写空表，是否做行数校验，需要明确业务语义。

#### 应对方案

- 通过 DataTransformationService 抽象数据转换逻辑，不同服务实现自己的转换方式。
- ResultWritingService 统一封装 Databricks 写入逻辑。
- 写入前做行数校验，确保外部 API 声称的记录数与实际转换后的记录数一致。
- 对 0 行结果做特殊处理，避免无意义写入。
- 对 Databricks 连接和 SQL 执行增加重试与连接保活逻辑。

### 5.6 可观测性、日志与问题定位

#### 技术挑战

- 作为中间层，问题可能发生在入口请求、鉴权、配置读取、外部 API、数据转换、对象存储、Databricks 写入、Kubernetes 部署等任一环节。
- 如果没有全链路日志，很难判断问题是 EAS 自身、外部服务、云资源权限还是配置导致的。

#### 可能遇到的生产问题

- 用户只看到 500/502，但不知道失败发生在哪个阶段。
- 多个并发请求日志混杂，难以追踪单次调用。
- Log Analytics ingestion 失败导致日志缺失。
- 日志中如果打印敏感响应体，可能存在安全风险。

#### 应对方案

- 每次调用生成 `call_uuid`，并把 `call_uuid` 写入日志上下文。
- 支持 `X-HSBC-Request-Correlation-Id`，方便与上游系统串联排查。
- 将错误分层包装为 BadGatewayException、EasInternalException 等，区分外部服务错误和系统内部错误。
- 对异常响应进行脱敏，避免将敏感数据暴露给调用方。
- 接入 Azure Log Analytics，集中采集生产日志。

### 5.7 Kubernetes 生产部署与运行稳定性

#### 技术挑战

- EAS 运行在容器和 AKS 中，需要同时考虑镜像安全、证书挂载、探针、资源限制、只读文件系统、Workload Identity 等生产约束。
- 应用内部有多进程 Uvicorn worker、heartbeat 线程、数据处理线程池，部署时需要合理配置 CPU/内存。

#### 可能遇到的生产问题

- readiness/liveness probe 配置不正确，导致 Pod 频繁重启或无法接流量。
- TLS secret 未挂载完成时服务启动失败。
- 只读根文件系统下，如果临时目录未正确挂载，会导致写文件失败。
- 资源 request/limit 配置不合理，大请求导致 OOM 或 CPU throttling。
- Helm/ConfigMap 更新后未滚动重启，导致旧配置继续生效。

#### 应对方案

- 使用 `/health` 做健康检查，并在 Helm 中配置 readiness/liveness probe。
- 通过 emptyDir 挂载临时目录，配合 readonlyRootFilesystem 提升安全性。
- 使用 Secret/ConfigMap 挂载证书和配置文件。
- 通过 Terraform 管理 Managed Identity、Federated Identity、Key Vault 权限和云资源权限。
- 根据大请求场景评估资源配置，并结合限流、队列上限和 worker 数做容量控制。

### 5.8 面试可用总结

如果面试官问“这个项目最大的技术挑战是什么”，可以这样回答：

“最大的挑战是它不是一个简单 CRUD 服务，而是一个外部 API 编排与数据落地中间层。生产上要同时面对外部服务不稳定、大批量分页数据、认证授权复杂、多环境配置差异、Databricks 写入一致性和 Kubernetes 运行稳定性。我的核心设计思路是把不确定性收敛在统一框架里：通过 RestService 抽象分页、重试、认证刷新和行数校验；通过生产者-消费者队列和对象存储缓冲控制内存峰值；通过 Azure AD JWT、Key Vault、Workload Identity、TLS 和异常脱敏保障安全；再通过 `call_uuid`、集中日志和健康探针提升生产可观测性。”

## 6. 可直接放进简历的版本

### 一句话项目描述

基于 FastAPI 构建企业级外部 API 编排与数据落地服务，统一完成鉴权、限流、分页重试、数据转换及 Azure Databricks 入库，并通过对象存储缓冲与并发处理优化大批量数据场景稳定性。

### 4-5 条简历 Bullet

- 设计并实现统一 `/v1/call` 接口，打通外部 REST 调用、参数化配置、日志追踪与统一异常处理链路。
- 抽象可扩展 RestService 执行框架，复用分页拉取、认证刷新、指数退避重试与行数校验能力。
- 实现对象存储缓冲 + 多线程处理流水线，在大批量分页场景下通过有界队列背压控制内存峰值。
- 落地企业级安全方案：Azure AD JWT 鉴权、TLS、安全响应头、服务级限流与异常脱敏。
- 推进云原生交付：Docker 多阶段构建、Helm on AKS、Terraform 管理 Identity 与权限。

## 7. 使用边界说明（写简历时注意）

- 当前代码中已明确注册并可直接证据化的服务以 RADAR / MOCKUP 为主。
- SAGE 等更多服务名和模板存在于枚举/配置体系中，除非你确实参与并上线了对应服务，否则简历里建议写“具备扩展能力”而不是“已全面接入”。
