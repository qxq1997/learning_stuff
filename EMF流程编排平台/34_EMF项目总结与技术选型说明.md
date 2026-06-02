# EMF 项目总结与技术选型说明

## 1. 项目简介与简历总结

EMF（Enterprise Metadata Framework）是基于 Azure 的企业级数据编排平台，支持元数据驱动的数据接入、依赖解析、Databricks 计算、结果发布与运维监控，广泛应用于金融/风险等批处理与分析场景。

**技术栈：**
- Python、Azure Databricks / Unity Catalog、Azure Blob Storage、Azure Service Bus、Azure Key Vault、Azure Monitor、Terraform、Docker、dbt、SQL、PyYAML、unittest、pylint

**主要内容：**
- 事件驱动的 Python Worker 架构，支持消息消费、任务调度、并发执行、重试、超时、取消和状态追踪
- 元数据驱动的数据流程，包括文件上传、目录登记、输入解析、SQL/dbt 转换、结果终态化和导出
- 集成 Azure Databricks、Storage、Service Bus、Key Vault、Monitor 等云服务，支持多项目、多环境和跨订阅数据访问
- 金融风险场景的数据处理能力，包括流动性 UDF、RWA CRM、授信层级等领域计算模块

**项目挑战：**
- 复杂批处理任务依赖、并发、失败重试
- 多环境配置、身份认证、跨订阅存储访问和 Databricks 运行上下文
- 长时间运行任务的可观测性、可恢复性和可审计性

**项目成果：**
- 将分散的数据处理脚本沉淀为可配置、可复用、可扩展的数据编排平台
- 提升数据接入、转换、发布和监控流程的标准化程度
- 支撑企业级 Azure + Databricks 数据平台在金融风险/监管分析场景中的稳定运行

---

## 2. 核心架构与元数据驱动

### 2.1 关键架构原理简述

- EMF 采用消息驱动、元数据驱动、DAG 任务调度、并发消费、失败重试、超时取消、异步日志和多环境配置管理。
- Worker 负责长期运行、消息消费、任务分发、并发执行和资源释放。
- 支持 Python 领域计算、UDF、Databricks Job、dbt 调度、Unity Catalog 表治理和 Lakehouse 数据管理。
- 适合金融风险等需要灵活编排、动态依赖、复杂计算和高可观测性的场景。

### 2.2 什么是元数据驱动？

不要把“元数据驱动”理解成一句抽象架构口号。放到 EMF 里，它的意思很具体：**Worker 的代码只负责通用动作，例如收消息、读文件、查配置、提交 Databricks Job、更新状态；至于这个文件是什么类型、用什么 schema、落到哪张表、触发哪个 workflow、依赖哪些输入、最终发布到哪里，尽量不写死在代码里，而是从 metadata、`LOAD_INFO`、`PROCESS_TASKS` 和 catalogue 中查出来。**

可以用一个文件上传场景来理解。

假设上游上传了一个业务文件到 Azure Storage，例如某类风险数据文件。文件本身只是一个 csv/json/avro 文件，但它旁边会带一些 metadata，例如：

- `file_type`：告诉 EMF 这是什么类型的数据。
- `reporting_date`：告诉 EMF 这批数据对应哪个业务日期。
- `source_system`：告诉 EMF 数据来自哪个上游系统。
- `run_uuid` 或其他业务参数：用于追踪一次批处理运行。

Worker 收到上传事件后，不会在代码里写死“如果是这个文件就跑某个脚本”。它会按下面的方式处理：

1. **先读文件 metadata**：Worker 读取 blob metadata 和 metadata token，拿到最关键的 `file_type`。
2. **用 `file_type` 查 `LOAD_INFO`**：系统到 `CONFIG_LOADER.LOAD_INFO` 中查这一类文件怎么处理，例如 schema 是什么、文件扩展名是什么、分隔符是什么、目标 dataset 是什么、表名前缀是什么、是否动态生成表名、写入方式是什么、上传后应该触发哪个 ingestion workflow。
3. **生成数据实体标识**：系统根据 `file_type` 和配置生成 `entity_uuid`、目标 table name 等运行时信息。这样一批数据就有了可以追踪的唯一标识。
4. **自动生成 `OE-RUN`**：Worker 根据 `LOAD_INFO.ingestion_workflow_name` 构造一个 workflow 运行消息，而不是手工指定每一步命令。
5. **用 workflow 查 `PROCESS_TASKS`**：`OE-RUN` 会找到对应的 `PROCESS_TASKS` 表，把里面的每一行任务展开成消息，例如建表、加载文件、执行 SQL/dbt、解析依赖、finalise、catalogue、export。
6. **按 DAG 执行任务**：每个 task 有自己的 `order_id`、`command`、`parents` 和 `parameters`。Worker 根据 `parents` 控制依赖顺序，父任务成功后才触发子任务。
7. **调用 Databricks 执行计算**：真正的数据处理交给 Databricks SQL、Notebook、Job、dbt 或 Python/UDF。
8. **写入 `DATAHUB` 并登记 catalogue**：finalise 后，结果表进入 `DATAHUB` 或 `LOAD_INFO.dataset_name` 指定的数据区；同时把 `entity_uuid`、`file_type`、dataset、table_name、run 信息和业务标签写入 `CATALOGUE.METADATA`。
9. **后续任务按条件解析数据**：下游任务不需要写死输入表名，可以用 `criteria` 从 catalogue 中查找满足条件的数据，例如“找最新一批 `file_type=A` 且 `reporting_date=2026-05-27` 的数据”。

也就是说，EMF 的处理逻辑不是：

- 代码里写死某个文件路径。
- 代码里写死某张目标表。
- 代码里写死每个 workflow 的步骤。
- 代码里写死每个输入依赖。

而是变成：

- `file_type` 决定这类文件应该查哪条 `LOAD_INFO`。
- `LOAD_INFO` 决定怎么建表、怎么加载、触发哪个 workflow。
- `PROCESS_TASKS` 决定 workflow 里有哪些任务、任务顺序是什么。
- `METADATA` / `CATALOGUE` 决定数据实体如何被登记、查找和复用。
- `criteria` 决定下游任务从 catalogue 中解析哪些输入数据。
- `DATAHUB` 承载最终被发布和消费的数据表。

一个更直观的对比是：

| 如果不用元数据驱动 | 使用 EMF 的元数据驱动 |
| --- | --- |
| 新增一种文件类型，需要写新脚本或改大量 `if/else` | 新增 `LOAD_INFO` 配置，并登记对应 workflow 和 metadata |
| schema 写在代码里，字段变化要改代码 | schema 放在 `LOAD_INFO`，变更以配置和表记录为主 |
| workflow 步骤写在程序里 | workflow 步骤放在 `PROCESS_TASKS` 表中 |
| 下游任务写死输入表名 | 下游任务用 `file_type` + `criteria` 从 catalogue 解析输入 |
| 很难知道一张表从哪里来 | `METADATA` 记录 `entity_uuid`、`file_type`、dataset、table、run 信息 |
| 不同项目容易复制多套脚本 | 同一套 Worker 和命令框架复用，不同项目主要换配置和元数据 |

所以，EMF 里的“元数据驱动”可以理解为：**代码提供通用能力，元数据决定业务行为。** Worker 像一个通用调度引擎，`LOAD_INFO`、`PROCESS_TASKS`、`METADATA`、`CATALOGUE`、`file_type` 和 `criteria` 共同告诉它每次运行应该怎么做。

这种设计的好处是非常实际的：新增数据类型时，不一定要重新开发一套 pipeline；调整 schema、目标表或 workflow 时，很多情况下可以通过修改配置表和 metadata 完成；生产问题排查时，也可以通过 `entity_uuid`、`run_uuid`、`file_type` 和 catalogue 追踪一批数据从上传、加载、计算、finalise 到导出的完整链路。

### 2.3 EMF 核心元数据对象与运行控制表

基于 EMF 代码和配置综合判断，`datahub`、`catalogue`、`metadata`、`loadinfo`、`filetype`、`dimqueue`、`processtasks` 不是同一层级的概念。它们共同构成 EMF 的元数据驱动基础，但有些是物理表，有些是 Unity Catalog schema/dataset，有些是运行时路由字段，有些是 workflow 控制表。

更准确的划分如下：

| 概念 | 更准确的物理形态 | 核心作用 |
| --- | --- | --- |
| `datahub` / `DATAHUB` | 数据区 / Unity Catalog schema / dataset，不是单张表 | 存放最终业务数据、解析结果、终态化表和可被下游消费的数据实体 |
| `catalogue` / `CATALOGUE` | 数据目录 schema + catalogue 服务域，不是单张表 | 管理数据资产索引，支持数据登记、查找、解析和审计 |
| `metadata` / `METADATA` | 明确的 metadata 表，以及 `VW_METADATA` 视图 | 保存每个数据实体的 key-value 元数据，用于 resolution、血缘和审计 |
| `loadinfo` / `LOAD_INFO` | 明确的配置表，位于 `CONFIG_LOADER.LOAD_INFO` | 定义每个 `file_type` 的 schema、落地区、表名前缀、写入方式和 ingestion workflow |
| `filetype` / `file_type` | 元数据字段 / 路由 key，不是表 | 决定文件、表、workflow 或消息应该走哪条处理路径 |
| `dimqueue` / `DIM_QUEUE` | `QUEUE.DIM_QUEUE` 队列表 + `file_type=dim_queue` 特殊分支 | 批量注入消息，驱动 workflow 或恢复/重放任务 |
| `processtasks` / `PROCESS_TASKS` | workflow task 表类 + `file_type=process_tasks` | 定义 workflow 中的命令节点、参数模板和 DAG 依赖关系 |

#### 1. `DATAHUB`：业务数据落地区

`DATAHUB` 在 EMF 中更像一个标准数据区，而不是一张表。项目参数中通常会把 `dataset-datahub` 配置为 `DATAHUB`，与 `CATALOGUE`、`QUEUE`、`CONFIG_LOADER` 等 schema/dataset 并列。

它的设计作用是承载 EMF 处理后的核心业务数据：

- **作为默认目标数据集**：如果 `LOAD_INFO` 中没有明确指定目标 dataset，finalise 或 resolution 场景中通常会回退到 `DATAHUB`。
- **作为 resolution 的默认来源**：catalogue resolution 解析 metadata 时，如果 metadata 中没有显式记录 `dataset`，系统会把实体默认定位到 `DATAHUB`。
- **作为终态化数据区**：业务文件经过加载、转换、校验和 finalise 后，会形成最终表，供后续流程或下游系统消费。
- **作为调整/快照/导出的基础区**：调整表、approved/unapproved view、snapshot、export 等能力都可能围绕 `DATAHUB` 中的实体展开。

可以把 `DATAHUB` 理解为 EMF Lakehouse 中的“主业务数据层”。`LOAD_INFO` 和 `METADATA` 决定数据应该如何进入 `DATAHUB`，而 `catalogue` 负责记录这些数据实体，使后续任务能够按条件解析和复用它们。

#### 2. `CATALOGUE`：数据资产目录域

`CATALOGUE` 也不应简单理解为一张表。它更准确地说是 EMF 的数据资产目录 schema 或目录服务域，底层主要依赖 `METADATA` 表和 `VW_METADATA` 视图。

`CATALOGUE` 的核心设计目标是回答几个问题：

- 系统中有哪些数据实体？
- 每个实体的 `entity_uuid` 是什么？
- 这个实体属于哪个 `file_type`？
- 这个实体对应哪个 dataset/table？
- 它有哪些业务标签，例如 `workflow`、`site`、`source_system`、`run_uuid`、`location`？
- 后续任务能否根据 `criteria` 找到它？

EMF 中的 catalogue 主要有两类操作：

1. **cataloguing / 登记**：把一个数据实体及其 metadata 写入 `CATALOGUE.METADATA`。例如 finalise 后会把最终表、`entity_uuid`、`file_type`、dataset、table name、run 信息等登记进去。
2. **resolution / 解析**：根据 `file_type` 和 metadata constraints 从 `CATALOGUE.VW_METADATA` 中查找满足条件的数据实体，再把这些实体解析成实际可查询的 dataset/table。

因此，`CATALOGUE` 是 EMF 元数据驱动的“索引层”。没有 catalogue，系统就很难做到“按条件找到最新的输入数据”“按 workflow 查找 process_tasks 表”“按业务标签解析依赖输入”。

#### 3. `METADATA`：数据实体的 key-value 描述表

`METADATA` 是 EMF 中明确存在的物理表，通常位于 `CATALOGUE.METADATA`；`VW_METADATA` 则是用于查询和 resolution 的视图。它保存的不是业务数据本身，而是业务数据实体的描述信息。

从代码模型看，一条 metadata 记录通常包含：

- `table_uuid` / `entity_uuid`：数据实体的唯一标识。
- `file_type`：该实体所属的数据类型或逻辑类型。
- `created`：metadata 被登记的时间。
- `attribute`：元数据属性名，例如 `dataset`、`table_name`、`workflow`、`location`、`run_uuid`。
- `value`：属性值。
- `data_type`：属性值的数据类型，用于 resolution 时做类型转换和比较。

`METADATA` 的关键作用包括：

- **支持数据发现**：系统可以通过 `file_type` 和 metadata constraints 查找数据实体。
- **支持依赖解析**：workflow 不一定写死输入表名，而是用 criteria 从 catalogue 中解析输入。
- **支持审计追踪**：可以追踪某个实体是什么时候生成的、属于什么类型、由哪个 run 产生、落在哪个 dataset/table。
- **支持 metadata injection**：`ADB-RESOLVE` 可以把解析到的 metadata 注入结果表的 `__metadata` 列，方便下游知道数据来源。
- **支持多项目/多环境查找**：resolution 可以在配置的 catalogue project 中查找满足条件的实体。

因此，`METADATA` 是 EMF 中“元数据驱动”的核心物理载体。它让数据实体从普通表变成可被查询、可被筛选、可被复用、可被审计的数据资产。

#### 4. `LOAD_INFO`：文件类型的加载配置表

`LOAD_INFO` 是 EMF 中另一个明确存在的物理表，通常位于 `CONFIG_LOADER.LOAD_INFO`。它是 `file_type` 到加载行为的配置映射表。

每一条 `LOAD_INFO` 记录可以理解为一份“某类数据如何进入 EMF”的合同，通常包含：

- `file_type`：配置适用的数据类型。
- `schema` / `schema_json`：目标表 schema 定义。
- `extension`：允许的文件扩展名，例如 csv、json、avro、orc。
- `delimiter`、`quote_character`、`skip_rows`：文件解析规则。
- `dataset_name`：默认目标 dataset；如果为空，可能回退到 `DATAHUB`。
- `prefix`：表名前缀。
- `dynamic_flag`：控制表名是否动态生成。为 true 时，表名通常跟 `entity_uuid` 相关；为 false 时，通常使用固定 prefix。
- `write_disposition`：写入方式，例如 append 或 replace。
- `ingestion_workflow_name`：上传该类型文件后自动触发的 ingestion workflow。
- `ingestion_parameters`：附加到 workflow 的默认参数。
- `is_adjustable`：是否支持调整表、调整视图等能力。

`LOAD_INFO` 在运行中的作用非常关键：

1. **校验文件类型是否受支持**：普通文件上传后，系统会用 `file_type` 查询 `LOAD_INFO`；如果没有匹配记录，说明该类型无法按标准 ingestion 处理。
2. **决定建表 schema**：`ADB-CREATE-TABLE-FROM-FILE-TYPE` 会根据 `file_type` 从 `LOAD_INFO` 取 schema 来创建表。
3. **决定数据加载方式**：`ADB-LOAD-TABLE-FROM-ASA-FILE` 会使用 `LOAD_INFO` 中的 extension、delimiter、schema 等信息加载文件。
4. **决定目标表命名**：`dynamic_flag` 和 `prefix` 会影响最终表名；动态表更适合每次 ingestion 形成独立实体，固定表更适合持续 append。
5. **决定自动触发哪个 workflow**：普通文件上传后，Worker 会读取 `ingestion_workflow_name`，自动生成一个 `OE-RUN`。
6. **支持运行时缓存**：EMF 可以在启动时缓存 `LOAD_INFO`，提高读取效率；配置变更后需要刷新缓存。

可以把 `LOAD_INFO` 理解为 EMF 的“接入配置中心”。它把“某类文件怎么加载”从代码中抽出来，变成可维护的表配置。

#### 5. `file_type`：EMF 的核心路由键

`file_type` 不是表，而是 EMF 中最重要的分类字段和路由 key。它出现在 blob metadata、`LOAD_INFO`、`METADATA`、resolution criteria、process_tasks、finalise 和 export 参数中。

在上传入口，Worker 会先从文件 metadata 中读取 `file_type`，然后按类型分支：

- `fact_message_attribute`：不走普通 ingestion，而是用于更新 DAG/message 状态。
- `dim_queue`：不加载业务数据，而是读取文件内容，将其中的消息批量加入队列。
- `load_info`：把上传内容作为 `LOAD_INFO` 配置处理。
- 其他业务 `file_type`：查询 `LOAD_INFO`，生成 entity uuid/table name，并自动触发 ingestion workflow。

在 catalogue resolution 中，`file_type` 是最核心的查询条件。系统会先限定 `file_type`，再叠加 metadata constraints，例如 `workflow=xxx`、`site=UK`、`source_system=ABC` 等。

所以，`file_type` 的概念设计类似于“业务数据类型主键”：

- 对 `LOAD_INFO` 来说，它决定读取哪条加载配置。
- 对 `METADATA` 来说，它决定实体属于哪类数据资产。
- 对 `CATALOGUE` 来说，它决定 resolution 的第一层过滤条件。
- 对 upload command 来说，它决定走哪条处理分支。
- 对 finalise/export 来说，它决定最终数据如何登记和发布。

#### 6. `DIM_QUEUE`：消息批量注入和运行队列

`DIM_QUEUE` 在 EMF 中同时有物理队列表和特殊文件类型两层含义。

作为物理表，它通常表示 `QUEUE.DIM_QUEUE`，用于保存待执行或可推断的 command message。作为特殊 `file_type`，`dim_queue` 表示“上传的文件不是业务数据，而是一批要注入队列的消息”。

典型流程如下：

1. 用户或上游系统上传一个文件，并在 blob metadata 中标记 `file_type=dim_queue`。
2. `ASA-UPLOAD-FILE` 读取 metadata 后发现是 `dim_queue`。
3. Worker 不读取 `LOAD_INFO`，也不创建业务表。
4. `GcsUploadDimQueueService` 读取文件内容。
5. 文件中每一行或每一段 JSON 被反序列化成 EMF message。
6. 系统为这些 message 统一设置 `batch_id`。
7. 系统检查 `run_uuid` 是否与已有 batch 冲突。
8. 通过 message appender 批量入队。

`DIM_QUEUE` 的作用是让 EMF 可以通过文件批量提交 workflow、重放任务、恢复任务或注入复杂消息集。它不是普通数据加载表，而是运行控制层的一部分。

#### 7. `PROCESS_TASKS`：workflow 的 DAG 定义表

`PROCESS_TASKS` 是 EMF workflow 编排的核心。它不是普通业务数据表，而是描述 workflow 中每个任务节点的控制表。它也可以作为 `file_type=process_tasks` 的数据资产被登记到 catalogue 中，再通过 metadata criteria 动态解析。

一张 `PROCESS_TASKS` 表通常包含：

- `workflow`：所属 workflow 名称。
- `order_id`：任务节点 ID。
- `command`：要执行的 EMF command，例如 `ADB-RESOLVE`、`ADB-SQL-EVAL`、`ADB-FINALISE`。
- `parents`：依赖的上游任务节点，用于形成 DAG。
- `parameters`：命令参数模板，支持用 run-level 参数替换。
- `topic`：目标消息 topic。

`OE-RUN` 执行时会根据 workflow 找到对应的 `PROCESS_TASKS` 表，然后把每一行 task 转成一条 EMF message。其逻辑可以分为两种：

1. **显式指定**：如果 `OE-RUN` 参数中直接给了 `process_tasks_dataset` 和 `process_tasks_table`，系统直接读取这张表。
2. **动态解析**：如果没有显式指定，系统会构造 `file_type=process_tasks` 的 resolution criteria，并叠加 `workflow`、`process_tasks_constraints`、`process_tasks_created_to` 等条件，从 catalogue 中解析出实际的 process_tasks 表位置。

读取到 `PROCESS_TASKS` 后，EMF 会做几件事：

- 校验任务依赖顺序是否合理。
- 用 run 参数替换 task 参数模板。
- 把 task 转成 message。
- 根据 `parents` 形成 DAG 依赖。
- 根据 `enabled` / `disabled` 标签过滤任务。
- 如果是 sub-workflow，会给子任务 `order_id` 加前缀并追加 completion token。

因此，`PROCESS_TASKS` 是 EMF 动态编排的核心控制表。它让 workflow 不必写死在 Python 代码中，而是通过表数据定义“执行哪些命令、按什么顺序执行、每个命令带什么参数”。

#### 8. 这些概念如何串起来？

从一次典型 ingestion 到后续 resolution，可以把它们串成一条完整链路：

1. 文件上传到 ASA，文件 metadata 中带有 `file_type`。
2. Worker 执行 `ASA-UPLOAD-FILE`，先读取 blob metadata 和 metadata token。
3. Worker 根据 `file_type` 判断处理分支。
4. 如果是 `dim_queue`，文件内容被解析成 message，写入队列，后续触发 workflow。
5. 如果是 `load_info`，文件内容被作为配置处理，用于更新或维护 `CONFIG_LOADER.LOAD_INFO`。
6. 如果是普通业务文件，Worker 根据 `file_type` 查询 `LOAD_INFO`。
7. `LOAD_INFO` 返回 schema、dataset、prefix、dynamic_flag、write_disposition、ingestion_workflow_name 等信息。
8. Worker 生成 `entity_uuid` 和目标 table name，并构造一个自动 `OE-RUN`。
9. `OE-RUN` 根据 workflow 查找 `PROCESS_TASKS`。
10. 如果 `PROCESS_TASKS` 没有显式指定表位置，系统通过 `CATALOGUE.METADATA` / `VW_METADATA` 动态解析 `file_type=process_tasks` 的表。
11. `PROCESS_TASKS` 被展开成一批带依赖关系的 command message。
12. 这些 command 可能执行建表、加载、SQL/dbt 转换、resolve、finalise、export 等动作。
13. finalise 后，结果数据进入 `DATAHUB` 或 `LOAD_INFO.dataset_name` 指定的数据区。
14. 结果实体的 metadata 被写入 `CATALOGUE.METADATA`。
15. 后续任务再通过 `file_type` + criteria 从 catalogue 中解析这些实体，实现依赖复用。

这个链路体现了 EMF 的核心思想：`file_type` 决定入口路由，`LOAD_INFO` 决定如何加载，`PROCESS_TASKS` 决定如何编排，`METADATA` 记录数据资产，`CATALOGUE` 提供查询和解析能力，`DATAHUB` 承载最终业务数据，`DIM_QUEUE` 承载消息化运行控制。

---

## 3. 技术挑战与生产问题

EMF 的难点不只是“把文件加载到 Databricks”，而是要把不同项目、不同环境、不同数据类型、不同依赖关系和不同执行引擎统一成一个可配置、可追踪、可恢复的数据编排平台。因此它的技术挑战主要集中在 **元数据一致性、动态 DAG 编排、分布式任务执行、长任务可观测性、数据治理和生产稳定性** 上。

### 3.1 技术上的主要挑战

**1. 元数据一致性与配置演进**

EMF 的核心逻辑依赖 `LOAD_INFO`、`METADATA`、`VW_METADATA`、`file_type`、`PROCESS_TASKS` 和各种环境配置。如果这些元数据不一致，系统不会简单地报一个代码错误，而是可能在运行时表现为“找不到输入”“解析到错误表”“schema 不匹配”“workflow 找不到任务表”等问题。

典型挑战包括：

- `LOAD_INFO` 中配置的 `file_type`、schema、dataset、prefix、dynamic_flag 与实际上传文件不一致。
- `METADATA` 中登记的 dataset/table 与真实 Databricks 表不一致。
- `file_type` 命名不统一，例如大小写、下划线、版本号或业务前缀不一致。
- `LOAD_INFO` 缓存未刷新，导致生产运行使用旧 schema 或旧 ingestion workflow。
- `PROCESS_TASKS` 被更新后，正在运行的 batch 和新配置之间出现版本不一致。

这类问题的本质是：EMF 把业务规则从代码移动到了元数据表和配置中，灵活性提高了，但也要求元数据本身必须被严格治理、校验和版本管理。

**2. 动态 DAG 编排复杂度高**

EMF 的 workflow 不是固定写死在代码中的流程，而是通过 `OE-RUN` 解析 `PROCESS_TASKS`，再把每一行 task 转成 message，并根据 `parents` 形成 DAG。这样可以支持复杂批处理，但也带来很高的编排复杂度。

主要挑战包括：

- `PROCESS_TASKS.parents` 配置错误会导致任务提前执行、永远等待或依赖链断裂。
- 子 workflow / workflow-of-workflows 会引入多层 order_id、parents 和 completion token，排查难度更高。
- `enabled` / `disabled` 标签过滤任务时，如果标签配置错误，可能跳过关键任务。
- 动态 resolution `process_tasks` 表时，如果 criteria 配置不准，可能解析到错误版本的 workflow 定义。
- 批处理重跑、补跑、取消和恢复时，需要保证 DAG 状态和 message 状态一致。

这要求 Worker 不只是简单消费消息，还要具备依赖管理、状态管理、失败传播和任务重连能力。

**3. 分布式执行与 Databricks Job 管理**

EMF 把实际计算交给 Databricks SQL、Notebook、Job、dbt 和 Python/UDF。挑战在于 Worker 和 Databricks 是两个不同层面的执行系统：Worker 负责调度和状态，Databricks 负责计算。两者之间必须通过 API、参数、状态轮询和错误处理保持一致。

生产中常见难点包括：

- Databricks cluster 冷启动慢，影响批处理 SLA。
- 高并发任务会争抢 cluster 资源，导致排队、超时或成本飙升。
- Spark shuffle、数据倾斜、大表 join、UDF 性能差会导致 job 长时间运行。
- Notebook / dbt / SQL / Python 包依赖版本不一致，导致同一逻辑在不同环境表现不同。
- Job 在 Databricks 侧失败、超时或被取消后，Worker 侧状态需要及时同步，否则可能出现“平台认为还在跑，但计算已经失败”的不一致。

因此，EMF 需要对 Databricks Job 做可靠的提交、轮询、超时、取消、失败映射和日志关联。

**4. 数据接入与 schema drift**

EMF 支持文件上传、metadata token、分片文件、不同扩展名和不同 file type 的加载规则。生产文件通常不是完全干净的，可能出现字段变化、格式变化、分隔符异常、空文件、重复文件、坏数据或 metadata 缺失。

典型挑战包括：

- 上游文件字段新增、删除、改名，导致 `LOAD_INFO.schema` 与实际文件不一致。
- CSV 引号、换行、delimiter、skip rows 配置不正确，导致解析失败或数据错列。
- chunked file 的 metadata token 上传顺序错误，导致系统过早触发加载。
- 文件 metadata 中缺少 `file_type`，Worker 无法判断处理路径。
- `extension_override` 使用不当，文件扩展名和真实内容格式不一致。
- 同一文件被重复上传或事件重复触发，引起重复 ingestion。

这类问题通常不是代码 bug，而是数据契约和上游交付质量问题，需要用数据校验、schema 管控和幂等设计来兜底。

**5. 幂等性、重复消息和重试一致性**

消息系统通常是 at-least-once 语义，生产中可能出现重复消息、重复事件、Worker 重启后重复消费、Databricks Job 提交成功但 Worker 未收到响应等情况。因此 EMF 必须考虑幂等性。

关键挑战包括：

- 同一个 `run_uuid` 或 `batch_id` 被重复使用，导致运行上下文冲突。
- 同一个 `entity_uuid` 被重复 finalise，可能覆盖或重复登记 metadata。
- 重试时前一次已经创建了 dataset/table，第二次再创建会失败。
- append 模式下重复加载会产生重复数据。
- export 或 catalogue 写入如果不是幂等的，可能生成重复文件或重复 metadata 条目。

因此，EMF 需要在 `run_uuid`、`batch_id`、`entity_uuid`、目标表、metadata 登记和 job 状态上设计幂等检查，避免“失败重试”变成“重复处理”。

**6. 长时间运行任务的可观测性和可恢复性**

金融/风险批处理任务经常运行数十分钟甚至数小时。如果只依赖普通日志，很难判断一个 batch 到底卡在哪里。

主要挑战包括：

- 一个 workflow 中可能有几十到上百个 task，失败点定位困难。
- Databricks 侧日志、Worker 日志、Service Bus 消息状态、metadata 记录分散在不同系统中。
- 任务失败后要判断是可重试错误、数据错误、权限错误还是代码错误。
- 长任务超时后，需要能取消 Databricks Job、释放资源、更新状态并通知下游。
- Worker 重启后，需要识别哪些任务已经完成、哪些任务需要恢复、哪些任务不能重复跑。

所以，EMF 必须把 run 级、batch 级、message 级、job 级和 data entity 级的信息串起来，形成可追踪的运行视图。

**7. 多环境、多项目和跨订阅治理**

EMF 要支持 dev/test/prod、多项目、多订阅和跨区域数据访问。每个环境都有不同的 storage、Service Bus、Databricks workspace、Unity Catalog、Key Vault、权限和配置。

技术挑战包括：

- 同一份代码在不同环境使用不同参数，容易出现配置漂移。
- Azure Managed Identity / Service Principal 权限不足会导致运行时失败。
- Key Vault secret 轮换后，Worker 或 Databricks 侧连接失败。
- 跨订阅访问 storage 或 catalogue 时，权限、网络和 catalog 映射更复杂。
- Unity Catalog 权限粒度较细，表存在但当前身份没有权限时，错误表现可能像“表不存在”。

这类问题往往在开发环境不明显，但在生产环境和跨项目访问中非常常见。

**8. 数据治理、安全和审计要求高**

金融/风险数据通常有较高的审计和合规要求。EMF 不仅要把数据算出来，还要回答数据从哪里来、按什么规则处理、谁触发、依赖哪些输入、输出到哪里、是否可重跑。

挑战包括：

- metadata 必须足够完整，否则后续无法解释数据血缘。
- 权限要最小化，但又要满足 Worker、Databricks、Storage、Service Bus 之间的调用。
- 生产数据可能包含敏感字段，日志中不能随意打印原始数据或 secret。
- 结果表、快照、导出文件和审计日志需要保留策略。
- 调整表、approved/unapproved view 等场景需要清楚区分原始数据、调整数据和已审批结果。

### 3.2 生产上可能遇到的问题

**1. 队列积压和任务延迟**

当上游集中上传文件或批量注入 `DIM_QUEUE` 消息时，Service Bus / Worker / Databricks 任何一层处理不过来都会造成积压。表现为消息延迟、batch 长时间不结束、SLA 超时。

常见原因包括：

- Worker 并发配置不足或线程被长任务占满。
- Databricks Job 排队或 cluster 资源不足。
- 某些失败消息不断重试，占用处理能力。
- 单个 workflow DAG 太大，父子依赖链过长。

**2. 消息重复、死信和状态不一致**

生产中可能出现消息重复投递、Worker 处理中断、lock 超时、dead-letter、取消后仍有子任务继续执行等问题。最终表现为任务状态和真实执行状态不一致。

例如：

- Worker 已提交 Databricks Job，但在记录状态前重启。
- Databricks Job 已失败，但 Worker 仍在等待轮询。
- 一个 parent 任务失败，但 children 已经被错误激活。
- 取消 batch 后，部分已提交的 Databricks Job 没有被同步取消。

**3. catalogue resolution 失败或解析错数据**

因为 EMF 很多输入依赖都靠 `file_type` + criteria 从 `CATALOGUE.VW_METADATA` 中解析，所以生产中经常会遇到 resolution 类问题。

典型表现：

- 找不到满足条件的 metadata，任务失败。
- metadata 有多条候选，latest_only 选到了非预期版本。
- `created_to` / `created_from` 时间窗口设置不对，漏掉正确数据。
- metadata 中 `dataset`、`table_name`、`workflow` 标签缺失或大小写不一致。
- 表已经被删除或重命名，但 catalogue 里还保留旧记录。

这类问题通常需要同时检查 `METADATA`、`VW_METADATA`、真实 Databricks 表和 workflow 参数。

**4. `LOAD_INFO` 配置变更引发运行问题**

生产中新增 file type 或修改 schema 时，如果没有完整验证，容易影响 ingestion。

常见问题包括：

- `schema_json` 格式错误。
- `dynamic_flag` 改变后，表名生成逻辑变化，导致旧流程找不到表。
- `dataset_name` 修改后，数据落到非预期位置。
- `ingestion_workflow_name` 指向不存在或错误的 workflow。
- 缓存未刷新，导致生产仍使用旧配置。
- 一个 file type 配置了多条 `LOAD_INFO`，Reader 期望单条结果时会失败。

**5. Databricks 资源、性能和成本问题**

Databricks 是 EMF 的主要计算引擎，生产上非常容易遇到性能和成本之间的平衡问题。

典型问题包括：

- cluster 冷启动影响首个任务延迟。
- 并发过高导致 job queue、driver 压力或 executor 不足。
- 数据倾斜导致少数 task 长时间运行。
- Python UDF 或复杂业务逻辑无法充分利用 Spark 优化。
- 大规模 shuffle、cache、checkpoint 使用不当导致成本升高。
- dbt/SQL/Notebook 混合执行时，定位性能瓶颈更困难。

**6. 数据质量和上游交付问题**

生产数据经常会出现上游未按契约交付的情况，EMF 需要能快速暴露并阻断错误数据。

常见问题包括：

- 必填字段为空。
- 字段类型与 schema 不一致。
- 分区数量或 record count 与 metadata token 不一致。
- 文件重复、缺失或晚到。
- 同一批次文件来自不同业务日期或不同版本。
- 下游依赖的数据还未 finalise，resolution 提前执行失败。

**7. 权限、网络和密钥问题**

生产环境中权限问题很常见，而且排查成本高。

例如：

- Worker 访问 Storage 失败。
- Databricks 访问 Unity Catalog 表失败。
- Key Vault secret 过期或权限被回收。
- 跨订阅 storage / catalogue 访问失败。
- Service Bus 连接字符串或 Managed Identity 配置错误。

这类问题通常不是业务逻辑问题，但会直接导致批处理失败。

**8. 发布变更和配置漂移问题**

EMF 同时依赖代码、Docker 镜像、Terraform、YAML/JSON 参数、Databricks Notebook/dbt、Unity Catalog 表和 metadata 配置。任何一层变更没有同步，都可能在生产上出问题。

常见场景：

- 代码已发布，但 `PROCESS_TASKS` 仍调用旧参数。
- `LOAD_INFO` 已更新，但 Databricks Notebook 还按旧 schema 处理。
- Terraform 已创建资源，但权限未同步。
- dev 环境测试通过，prod 因配置不同失败。
- 文档中命令参数与实际 command module 不一致。

### 3.3 逐项应对和解决方案

为了让 EMF 在生产中稳定运行，不能只在失败后靠人工查日志，而是要把“校验、隔离、幂等、可恢复、可观测、可治理”做成平台能力。下面按前面的技术挑战逐项展开。

**1. 元数据一致性：把配置当成代码治理**

元数据驱动的代价是：很多运行逻辑不在 Python 代码里，而在 `LOAD_INFO`、`PROCESS_TASKS`、`METADATA` 和 catalogue 中。所以第一类解决方案是把这些配置当成代码一样治理。

- 对 `LOAD_INFO` 做发布前校验：`file_type` 是否唯一，`schema_json` 是否可解析，`dataset_name` 是否存在，`ingestion_workflow_name` 是否能解析到有效 workflow。
- 对 `PROCESS_TASKS` 做 DAG 校验：`parents` 指向的节点是否存在，是否有环，是否有孤儿节点，是否有永远不会被触发的节点。
- 对 `METADATA` 做完整性校验：关键字段如 `entity_uuid`、`file_type`、`dataset`、`table_name`、`run_uuid`、`workflow` 必须齐全。
- 对 `file_type` 建命名规范：大小写、下划线、业务域前缀、版本号要统一，避免 `risk_file`、`RiskFile`、`risk-file-v2` 被系统当成三类数据。
- 对元数据变更做版本化：生产运行中的 batch 应该绑定当时解析到的 workflow 版本或 process_tasks 版本，避免运行到一半时新配置覆盖旧配置。
- 对缓存做明确刷新机制：`LOAD_INFO`、catalogue resolution 结果、workflow definition 如果有缓存，发布流程里必须有刷新动作和刷新后验证。

落地上可以把这些校验做成一个 `metadata validation` 或 `dry-run command`。它不真正跑 Databricks 计算，只检查“这个 file_type 能不能找到加载配置、能不能解析 workflow、依赖是否完整、目标表是否存在、权限是否满足”。这样很多生产错误可以在发布前暴露。

**2. 动态 DAG：从“能展开”升级为“可验证、可恢复、可解释”**

EMF 的 DAG 来自 `PROCESS_TASKS`，所以问题不只是拓扑排序，而是动态展开后仍然要可控。

- 展开前校验：检查 `parents`、`order_id`、`command`、`parameters`，确认没有循环依赖、重复节点、非法 command 和缺失参数。
- 展开时固化快照：一次 `OE-RUN` 应该记录本次使用的 workflow 名称、版本、task 列表和参数快照，后续排障时不能只看最新的 `PROCESS_TASKS`。
- 执行时状态机约束：task 状态应该从 `PENDING`、`READY`、`RUNNING`、`SUCCEEDED`、`FAILED`、`CANCELLED` 等状态按规则流转，不能随意跳转。
- parent 失败要阻断 children：如果父任务失败，子任务不能被错误激活，应该进入 `BLOCKED`、`SKIPPED` 或等待人工处理。
- 重跑要按范围控制：支持重跑单个 task、重跑某个子图、从失败点继续、整批重跑，并明确哪些下游结果需要作废。
- 子 workflow 要有 completion token：workflow-of-workflows 需要把子 workflow 的完成结果回传给父 workflow，否则父 workflow 无法判断依赖是否真正结束。

这部分的核心是把 DAG 从“配置表里的几行任务”变成“有版本、有状态、有血缘、有恢复语义的运行实例”。这样生产中修改配置、补跑、取消、恢复时，系统才知道应该影响哪些任务、不应该影响哪些任务。

**3. Databricks Job：Worker 只做控制面，Databricks 做计算面**

EMF 需要明确分层：Worker 是控制面，负责调度、状态、超时、取消、重试和审计；Databricks 是计算面，负责 SQL、Spark、dbt、Notebook、Python/UDF 的实际执行。

- 提交 job 前生成幂等 key：例如用 `run_uuid + order_id + command + entity_uuid` 标识一次外部计算，避免 Worker 重试时重复提交。
- 提交后保存 `databricks_run_id`：只要外部 job 创建成功，就必须把 run id 写入状态表，后续靠它轮询、取消和补偿。
- 定期轮询外部状态：Worker 不能只相信自己的 `RUNNING` 状态，要查询 Databricks run 当前是 running、success、failed、cancelled 还是 timed out。
- 做错误映射：把 Databricks 的 notebook error、cluster error、permission error、timeout、cancelled 映射成 EMF 内部错误类型，方便自动重试或人工处理。
- 超时要联动取消：EMF task 超时后，不仅要把内部状态置为 failed/cancelled，还要调用 Databricks API 尝试取消外部 run。
- 日志要可回跳：每个 task 记录 Databricks workspace、job id、run id、notebook path、cluster id 和日志链接，让运维能直接定位到计算侧。

这样做的好处是：Worker 重启、网络抖动、Databricks 慢启动都不会让任务状态失真。即使 Worker 死过一次，恢复后也能通过 `databricks_run_id` 把真实外部状态补回来。

**4. 数据接入和 schema drift：用数据契约兜底，而不是靠下游报错**

上游文件不稳定是生产常态。EMF 应该在入口处尽早发现问题，不要等到复杂计算跑了一半才失败。

- 上传阶段检查 metadata：必须有 `file_type`、业务日期、source system、batch id 或 run id 等关键字段。
- 加载前做 schema validation：检查字段名、字段类型、必填字段、分隔符、文件扩展名、编码、空文件和 record count。
- 对 schema 演进分级处理：新增可选字段可以自动兼容；删除字段、改字段类型、改主键这类变更必须走审批或配置发布。
- 对坏数据隔离：解析失败的文件不要直接污染目标表，可以进入 quarantine/error dataset，并记录失败原因。
- 对 chunked file 做完整性检查：所有分片和 metadata token 都到齐后才触发加载，避免半批数据被提前处理。
- 对重复上传做去重：同一个 `batch_id`、文件 checksum、source path 或 metadata token 重复时，要能识别并阻断重复 ingestion。

这类方案的目标是把“schema drift”变成可见、可分类、可阻断的问题，而不是让它随机表现为 Spark 报错、SQL 字段不存在或下游结果异常。

**5. 幂等、重试和补偿：每个外部副作用都要有防重复设计**

EMF 里很多动作都有副作用：建表、写 Delta 表、append 数据、finalise、catalogue 登记、export 文件、提交 Databricks Job。只要有重试，就必须考虑重复执行。

- 建表要幂等：可以用 create-if-not-exists，或者先查询目标表状态，再决定是否创建、替换或失败。
- append 要可去重：写入数据时带上 `run_uuid`、`batch_id`、`entity_uuid`，后续可以按批次删除、覆盖或去重。
- finalise 要有提交标记：同一个实体只能 finalise 一次，重复 finalise 要么返回已成功，要么进入人工确认。
- catalogue 写入要唯一：`entity_uuid + attribute` 或类似键要避免重复 metadata 条目。
- export 要有目标路径策略：同一次导出使用稳定路径或带版本路径，避免重试生成多个相同含义的文件。
- 重试策略要区分错误类型：网络抖动、Databricks 暂时不可用可以自动重试；schema 错、权限错、数据质量错通常要阻断并创建人工处理 ticket。

一个好用的判断标准是：任意 task 在成功、失败、Worker 重启、消息重复投递后再执行一次，系统都应该知道“这是新执行、重复执行、继续执行，还是需要补偿”。

**6. 可观测性和人工处理：让失败 ticket 自带上下文**

EMF 的失败排查不能只给一条 exception。生产上真正需要的是从一个失败 task 看完整上下文。

- 统一 trace id：所有日志、状态表、Databricks run、Service Bus message、metadata entity 都带 `run_uuid`、`batch_id`、`order_id`、`entity_uuid`。
- 建运行视图：能看到 workflow DAG、每个 task 状态、父子依赖、输入实体、输出表、外部 job、重试次数和耗时。
- 做错误分类：区分平台错误、权限错误、数据质量错误、配置错误、Databricks 资源错误、业务规则错误。
- 自动生成 Jira ticket：失败后汇总 workflow 信息、失败 task、错误堆栈、输入 metadata、Databricks run 链接、最近配置变更、SOP 建议和 owner team。
- 精准路由到 team：根据 `file_type`、workflow、dataset、source_system、command 类型或 catalog owner 找到对应 Jira board。
- ticket 要给处理建议：比如“刷新 LOAD_INFO 缓存”“检查 Key Vault secret”“修复 schema_json”“取消残留 Databricks run”“重跑 order_id=xxx 之后的子图”。

这里 AI 可以发挥作用：它不是替代 Worker 做调度，而是把分散在日志、metadata、SOP、Databricks、Service Bus 里的信息汇总成一份可执行的排障说明，减少一线同学从零查问题的时间。

**7. 权限、多环境和发布：把环境差异显式化**

很多生产问题来自 dev/test/prod 不一致，而不是业务逻辑本身。

- 环境参数集中管理：storage account、container、Service Bus、Databricks workspace、catalog、schema、Key Vault 都从环境配置读取。
- 发布前做权限探测：Worker 身份能否读写 Storage、发 Service Bus、读 Key Vault、调用 Databricks、访问 Unity Catalog 表。
- 最小权限但可运行：按 command 类型授予权限，例如 ingestion command 不应该拥有所有 export 权限。
- secret 轮换要有兼容窗口：Key Vault secret 更新后，Worker、Databricks cluster、job 参数和连接池都要能同步刷新。
- 跨订阅访问要做白名单：明确哪些项目可以访问哪些 storage/catalogue/dataset，避免运行时才发现网络或权限不通。
- 发布包要绑定配置版本：代码镜像、Terraform、Notebook/dbt、`LOAD_INFO`、`PROCESS_TASKS`、YAML 参数要能追踪到同一次 release。

对 EMF 这种平台来说，发布不是“部署一份代码”这么简单，而是“部署代码 + 计算脚本 + 云资源 + 元数据配置 + 权限模型”的组合。

**8. 性能和成本：不要只扩容，要做限流和分层优化**

Databricks 能横向扩展，但盲目扩容会把问题从“任务慢”变成“成本高、队列乱、资源抢占、问题更难定位”。对 EMF 来说，性能治理不是简单把 cluster 开大，而是要在 Worker、Queue、Databricks、Delta 表和数据生命周期几层一起做控制。

首先要明确一个原则：**不是所有任务都应该同等优先级、同等并发、同等资源配置。** 一个读取 metadata 的轻量 SQL、一个加载小文件的 ingestion task、一个大表 join、一个 Python/UDF 风险计算、一个 export 任务，对资源的消耗完全不同。如果它们都走同一套默认 cluster、同一套并发策略，最后一定会出现两类问题：

- 轻任务被重任务拖慢，SLA 不稳定。
- 重任务被无限并发放大，Databricks 成本快速上升。
- Worker 看起来很忙，但真正瓶颈在 Databricks queue、Spark shuffle、Delta 小文件或下游写入。
- 为了救一个慢任务把 cluster 开大，结果掩盖了 SQL 写法、数据倾斜、分区设计或重复扫描的问题。

所以 EMF 应该把任务做成“有成本感知的调度”，让平台知道这个 task 是轻量、普通、重计算、UDF 密集、IO 密集还是导出型任务。

可以在 `PROCESS_TASKS` 或 command metadata 中增加类似字段：

| 字段 | 含义 |
| --- | --- |
| `cost_class` | 任务成本等级，例如 `small`、`medium`、`large`、`xlarge` |
| `resource_pool` | 使用哪个资源池，例如 `sql_light`、`etl_standard`、`shuffle_heavy`、`python_udf`、`export` |
| `concurrency_key` | 并发控制维度，例如 project、workflow、dataset、command |
| `max_concurrency` | 同类任务最大并发数 |
| `priority` | 任务优先级，SLA 高的任务优先运行 |
| `timeout_policy` | 不同任务类型使用不同超时 |
| `retry_policy` | 不同错误类型采用不同重试策略 |
| `expected_input_size` | 预期输入规模，用于选择 cluster 或是否进入重任务队列 |

这样 Worker 不是拿到消息就立刻提交 Databricks，而是先判断：这个任务属于哪个资源池，现在还有没有额度，是否会超过项目配额，是否应该排队，是否应该降级或延后。

**Worker 层限流**

Worker 层限流的目标是防止 EMF 自己把 Databricks 打爆。Worker 消费 Service Bus 很快，但 Databricks 的 cluster、job queue、driver、executor 和 DBU budget 都是有限资源。如果 Worker 不限流，短时间内提交大量 job，系统表面上吞吐提高了，实际会变成 Databricks 排队、任务超时、成本上升。

可以按几个维度限流：

- **按 project 限流**：防止一个项目的大批量任务占满全平台资源。
- **按 workflow 限流**：防止一个超大 DAG 同时展开几百个 Databricks job。
- **按 command 限流**：例如 `ADB-SQL-EVAL`、`ADB-FINALISE`、`EXPORT` 使用不同并发上限。
- **按 dataset 限流**：防止多个任务同时写同一个 Delta 表或同一个 dataset，引发事务冲突。
- **按 cost_class 限流**：大任务并发少，小任务并发多。

一个比较实用的策略是给每类任务分配 token。Worker 领取任务前先申请 token，拿到 token 才能提交 Databricks；任务结束、失败或取消后释放 token。这样即使 Service Bus 里有很多消息，真正进入 Databricks 的任务也会被平台节流。

例如：

| 任务类型 | 并发策略 |
| --- | --- |
| metadata resolution | 高并发，通常是轻量查询 |
| 小文件 ingestion | 中等并发，避免大量小 job 冷启动 |
| 大表 SQL/dbt | 低并发，避免 shuffle 和 cluster 争抢 |
| Python/UDF 领域计算 | 低到中并发，看 CPU 和内存消耗 |
| finalise / merge | 对同一目标表串行或低并发 |
| export | 低并发，避免 IO 和下游系统被打爆 |

**Queue 层背压**

背压的意思是：当下游处理不过来时，上游要放慢速度。对 EMF 来说，下游不只是 Worker，也包括 Databricks job queue、cluster 可用性、Delta 写入冲突、成本预算和 SLA 状态。

可以监控这些指标来判断是否需要背压：

- Service Bus backlog 和 message age。
- Worker 当前 running task 数、线程池占用、失败率。
- Databricks job queue time、running jobs、failed jobs、cluster pending time。
- cluster CPU、内存、shuffle spill、executor lost、driver OOM。
- 每小时 DBU / 云资源成本是否超过预算。
- Delta 写冲突、merge 耗时、小文件数量。

背压不是简单“队列越长 worker 越多”。如果 backlog 增加是因为 Worker 不够，可以扩 Worker；但如果 backlog 增加是因为 Databricks 已经排队，再扩 Worker 只会提交更多 job，让 Databricks 更堵。这个时候应该降低消费速度、延迟低优先级任务、限制重任务提交，甚至只允许关键 SLA workflow 继续运行。

可以把背压策略做成几档：

| 状态 | 策略 |
| --- | --- |
| 正常 | 按默认并发消费 |
| Databricks queue 上升 | 降低重任务提交速度 |
| 成本接近预算 | 暂停低优先级 batch 或 export |
| 失败率异常升高 | 暂停自动重试，避免错误风暴 |
| SLA 临近 | 给关键 workflow 提高优先级 |
| 下游系统不可用 | 暂停对应 command，消息保留或延迟重试 |

**Cluster policy 分层**

不同任务应该使用不同 cluster policy，而不是所有任务都用一个万能 cluster。万能 cluster 往往既贵又不稳定：轻任务浪费资源，重任务又不够强。

可以按 workload 分层：

| 资源池 | 适合任务 | 特点 |
| --- | --- | --- |
| `sql_light` | metadata 查询、轻量 SQL、catalogue resolution | 小规格、启动快、成本低 |
| `etl_standard` | 普通文件加载、清洗、转换 | 中等规格、稳定吞吐 |
| `shuffle_heavy` | 大表 join、聚合、dbt 大模型 | 更强 executor、更多 shuffle 空间 |
| `python_udf` | 复杂 Python/UDF、领域计算 | 更关注 CPU、内存和依赖环境 |
| `export_io` | 导出文件、发布到下游 | 控制 IO 并发，避免打爆 storage |

Cluster policy 里可以限制 runtime version、instance type、autoscaling 范围、最大 DBU、是否允许 all-purpose cluster、是否必须使用 job cluster。这样既能控制成本，也能减少“某个任务临时开了一个超大 cluster”的人为风险。

但真正落地时，难点不是“列出几个资源池”，而是 **Worker/Scheduler 怎么知道某个 task 应该用哪个资源池**。这个判断不应该完全靠 Worker 临时猜，而应该分四层：

1. **显式配置优先**：如果 `PROCESS_TASKS.parameters` 或 command metadata 已经指定 `resource_pool` / `compute_profile`，系统直接使用。
2. **Command 默认规则**：如果 task 没有显式指定，就根据 command 类型给默认资源池。
3. **输入规模估算**：如果能从 metadata、catalogue、Delta table stats、文件大小或历史 run 中估算输入规模，再做上调或下调。
4. **历史指标反馈**：如果某类任务过去多次 OOM、shuffle spill、超时或成本过高，平台可以建议或自动调整它的资源池。

也就是说，资源选择不是一次性写死，而是“配置 + 规则 + 规模 + 反馈”的组合。

可以先在 workflow task 定义中允许显式声明：

```json
{
  "order_id": "transform_rwa",
  "command": "ADB-SQL-EVAL",
  "parents": ["load_input"],
  "parameters": {
    "sql_file": "rwa_transform.sql",
    "criteria": {
      "file_type": "rwa_input",
      "reporting_date": "${reporting_date}"
    },
    "resource_pool": "shuffle_heavy",
    "cost_class": "large",
    "max_concurrency": 2,
    "timeout_policy": "long_sql"
  }
}
```

如果没有显式配置，就用 command registry 做默认映射：

| command 类型 | 默认资源池 | 原因 |
| --- | --- | --- |
| `ADB-RESOLVE` / catalogue lookup | `sql_light` | 多为 metadata 查询，输入小，启动快比算力重要 |
| `ADB-CREATE-TABLE-FROM-FILE-TYPE` | `etl_standard` | 建表和 schema 解析通常中等成本 |
| `ADB-LOAD-TABLE-FROM-ASA-FILE` | `etl_standard` | 普通文件加载，关注稳定吞吐 |
| `ADB-SQL-EVAL` | `etl_standard`，可按规模上调 | SQL 可能轻也可能重，需要结合输入规模判断 |
| `ADB-DBT-RUN` | `etl_standard` 或 `shuffle_heavy` | dbt 模型可能包含大 join 和聚合 |
| `ADB-PYTHON-UDF` / 领域计算 | `python_udf` | Python 依赖、序列化和 CPU/内存特征不同 |
| `ADB-FINALISE` / `MERGE` | `shuffle_heavy` 或目标表专用池 | 容易涉及大表写入、merge、compaction |
| `EXPORT` | `export_io` | 主要瓶颈可能是 IO 和下游系统 |

代码层面可以把这个逻辑做成一个 `ComputeProfileResolver`，输入是 task、command、run context、metadata 和历史统计，输出是 compute profile：

```python
class ComputeProfileResolver:
    def resolve(self, task, run_context):
        explicit = task.parameters.get("resource_pool") or task.parameters.get("compute_profile")
        if explicit:
            return self.validate_profile(explicit, task)

        profile = self.command_defaults.get(task.command, "etl_standard")

        estimate = self.estimate_input_size(task, run_context)
        if estimate.bytes >= 500 * GB or estimate.rows >= 500_000_000:
            profile = self.upgrade(profile, "shuffle_heavy")

        if task.parameters.get("uses_python_udf") is True:
            profile = "python_udf"

        if task.command in {"EXPORT", "PUBLISH_TO_GCS", "EXPORT_TO_GCS"}:
            profile = "export_io"

        history = self.metrics_store.lookup(task.workflow, task.command, task.logical_name)
        if history.recent_oom_count > 0 or history.p95_runtime_minutes > task.timeout_minutes * 0.8:
            profile = self.recommend_upgrade(profile)

        return profile
```

这里的 `estimate_input_size` 可以来自几类数据：

- 上传文件 metadata：文件大小、文件数量、chunk 数、record count。
- `LOAD_INFO`：file type 的默认数据规模、是否动态表、写入方式。
- catalogue metadata：依赖输入的 `entity_uuid`、dataset、table、reporting_date。
- Delta table statistics：表大小、文件数、分区数、历史版本。
- 历史运行指标：同一个 workflow/command 在过去的平均输入规模和耗时。
- 业务参数：例如 `reporting_date`、region、scenario、portfolio 范围会影响数据量。

判断逻辑可以先做得保守，不需要一开始就很智能。一个可落地的版本是：

| 判断条件 | 选择 |
| --- | --- |
| task 显式写了 `resource_pool` | 使用显式配置 |
| command 是 metadata / resolve 类 | `sql_light` |
| command 是 export 类 | `export_io` |
| parameters 标记 `uses_python_udf=true` | `python_udf` |
| 输入文件小于 1GB，且无大 join | `etl_standard` |
| 输入超过 100GB 或文件数很多 | `shuffle_heavy` |
| SQL/dbt 标记 `join_level=heavy` 或 `requires_shuffle=true` | `shuffle_heavy` |
| 目标表正在被同 dataset 其他任务写入 | 降低并发或排队 |
| 历史 P95 接近 timeout | 提醒升级 profile 或拆分任务 |

这个判断最好还要有治理边界，避免所有人都把任务标成大资源池：

- `resource_pool` 必须在允许列表中，不能随便写一个超大 cluster。
- `xlarge` 或 `shuffle_heavy` 需要 project quota 或审批。
- 同一个 project 同时运行的重任务数量有限制。
- 如果 task 显式要求的资源池和 command 类型明显不匹配，dry-run 要提示。
- 如果历史数据显示任务长期只用很少资源，可以建议降级。

最终 Worker 提交 Databricks job 时，不直接写死 cluster，而是通过 profile 找到对应 Databricks job/cluster policy：

```python
profile = compute_profile_resolver.resolve(task, run_context)
policy = compute_policy_registry.get(profile)

databricks.submit_run(
    task_key=task.order_id,
    notebook_path=task.parameters["notebook_path"],
    job_cluster_key=policy.job_cluster_key,
    spark_conf=policy.spark_conf,
    parameters=rendered_parameters,
)
```

`compute_policy_registry` 可以来自 YAML、数据库配置或环境配置：

```yaml
compute_profiles:
  sql_light:
    job_cluster_key: sql-light
    max_concurrency: 20
    timeout_minutes: 20
  etl_standard:
    job_cluster_key: etl-standard
    max_concurrency: 8
    timeout_minutes: 90
  shuffle_heavy:
    job_cluster_key: shuffle-heavy
    max_concurrency: 2
    timeout_minutes: 240
  python_udf:
    job_cluster_key: python-udf
    max_concurrency: 4
    timeout_minutes: 180
  export_io:
    job_cluster_key: export-io
    max_concurrency: 3
    timeout_minutes: 120
```

这样设计后，资源分层就不是空想，而是形成了一条明确链路：

`PROCESS_TASKS / command metadata` -> `ComputeProfileResolver` -> `compute profile` -> `cluster policy / job cluster` -> `Databricks run` -> `运行指标回写` -> `下次调度优化`

这条链路也给运维留下了可解释性：一个任务为什么被分到 `shuffle_heavy`，可以从 task 参数、输入规模、历史运行和 resolver 决策日志里查出来；如果分错了，也可以通过配置覆盖，而不是改 Worker 代码。

**数据层优化**

很多 Databricks 性能问题不在 cluster，而在数据本身。数据布局差，再大的 cluster 也只是更贵地跑慢查询。

常见优化包括：

- **合理分区**：按业务日期、region、scenario 等常用过滤字段分区；不要用 `entity_uuid`、user_id 这类高基数字段分区，否则会产生海量小目录。
- **控制小文件**：大量小文件会让 Spark 花很多时间做文件 listing 和 task 调度。加载和 finalise 后要定期 compact，把小文件合并到合理大小。
- **避免全表扫描**：下游任务通过 `criteria` resolution 找到输入后，SQL 里也要带上业务日期、batch、scenario 等过滤条件。
- **大表 join 优化**：小表 broadcast，大表先过滤和预聚合；热点 key 可以 salting；必要时拆分大 join。
- **Delta merge 优化**：`MERGE` 前先按日期、batch 或实体范围缩小目标数据，不要每次 merge 扫全表。
- **中间结果落盘**：超长 lineage 或重复使用的数据可以落成中间 Delta 表，减少失败重算和重复计算。

一个典型例子是：如果某个 finalise 每次都扫描全量历史数据，再用最新 batch 覆盖结果，那么扩 cluster 只能暂时缓解。更好的做法是按 `reporting_date`、`run_uuid` 或 `entity_uuid` 做增量处理，让每次只处理本批次相关数据。

**UDF 优化**

Python/UDF 很适合表达复杂业务规则，但它也是 Spark 性能里最容易踩坑的地方。原因是 Spark SQL 内置函数可以被 Catalyst optimizer 优化，而普通 Python UDF 往往需要在 JVM 和 Python 进程之间序列化数据，优化空间小。

优化原则是：

- 能用 Spark SQL 内置函数就不用 Python UDF。
- 能用 DataFrame 表达式就不用逐行 Python loop。
- 必须用 Python 时，优先考虑 pandas UDF 或批量处理，让数据按 batch 传输。
- UDF 输入列尽量少，不要把整行大对象传进去。
- 对可复用的领域逻辑做包版本管理，避免 notebook 里复制多份 UDF。
- 对 UDF 任务单独分配 cluster policy，避免和普通 SQL 任务互相影响。

在金融/风险场景里，UDF 常常不可避免，因为有很多规则和层级关系很难纯 SQL 化。重点不是禁止 UDF，而是让平台知道“这是昂贵任务”，给它单独资源池、较低并发、更长 timeout 和更细日志。

**生命周期管理**

EMF 会产生很多中间数据：staging 表、临时表、checkpoint、debug 输出、失败样本、历史快照、导出文件。如果没有生命周期管理，成本会悄悄增长，而且 catalogue resolution 也可能解析到过期数据。

需要明确几类保留策略：

- Raw 文件保留多久，是否需要归档。
- Staging/Bronze 表保留多久，失败数据是否单独保存。
- 中间 Silver 表是否只保留最近 N 个 run。
- Gold/finalise 表和审计快照保留多久。
- checkpoint、debug、临时输出在任务成功后是否清理。
- Delta `VACUUM` 保留时间如何设置，不能破坏 time travel 和审计要求。
- catalogue metadata 是否标记 active/expired，而不是直接物理删除。

生命周期管理的关键是把“能删什么、什么时候删、谁来删、删了是否影响审计”变成规则，而不是靠人工定期清理。

**指标和治理闭环**

最后，性能和成本优化要有闭环，不能只靠经验。

EMF 可以定期统计：

- 每个 project/workflow/command 的平均耗时、P95/P99 耗时。
- 每个 Databricks job 的 queue time、run time、失败率、重试次数。
- 每类 command 的 DBU 成本和单位数据成本。
- 每张 Delta 表的小文件数量、平均文件大小、分区数量。
- shuffle read/write、spill、skew task、driver OOM、executor lost。
- Service Bus backlog、message age、dead-letter 数。

这些指标可以反过来驱动平台策略：

- 哪些 workflow 需要拆分。
- 哪些 command 要降低并发。
- 哪些表需要 compact 或重新分区。
- 哪些 UDF 需要改写。
- 哪些 project 超过预算。
- 哪些低优先级任务可以延迟到低峰期运行。

这部分的核心不是“让所有任务都跑得更快”，而是让平台知道哪些任务能并发、哪些任务要排队、哪些任务贵、哪些任务可以降级。性能优化解决的是 SLA，成本治理解决的是可持续运行；两者必须一起设计，否则很容易变成“今天靠扩容救火，明天被账单反噬”。

### 3.4 Lakehouse 和 Delta Lake 是什么，为什么 EMF 要这么做

如果不熟 Lakehouse 和 Delta，可以先用一个简单对比理解。

传统数据平台通常有两类东西：

- **Data Lake**：把原始文件放到便宜的对象存储里，例如 Azure Blob Storage / ADLS。优点是便宜、灵活、能存 CSV/JSON/Parquet/日志/半结构化数据；缺点是文件很多时不好管理，缺少强事务，schema 容易漂移，更新和删除麻烦，数据质量容易失控。
- **Data Warehouse**：把数据整理成结构化表，提供稳定 SQL 查询、权限、事务和 BI 能力。优点是规范、查询体验好、适合报表；缺点是成本较高，对原始/半结构化/复杂 Python 处理不够灵活，动态数据工程场景会比较笨重。

**Lakehouse** 可以理解为把两者结合起来：底层仍然用对象存储保存开放格式的数据文件，但在文件之上加一层“表管理、事务、schema、版本、权限和目录”。它希望同时获得 Data Lake 的低成本和灵活性，以及 Data Warehouse 的可靠表语义。

**Delta Lake** 就是 Databricks 生态里最核心的 Lakehouse 表格式。它不是一个单独数据库，而是一套在对象存储之上的表协议。Delta 表底层通常仍然是 Parquet 文件，但旁边会有一个 `_delta_log` 事务日志目录，记录每次写入、删除、合并、schema 变化和版本信息。

可以把普通文件和 Delta 表的区别理解成：

| 对比项 | 普通 Parquet/CSV 文件 | Delta Lake 表 |
| --- | --- | --- |
| 写入一致性 | 多任务同时写容易产生脏数据或半成品 | 有事务日志，支持 ACID 语义 |
| 表版本 | 通常只能看到当前文件集合 | 每次提交形成版本，可追踪历史 |
| schema 管理 | 容易字段漂移，读的时候才发现问题 | 可以做 schema enforcement 和 schema evolution |
| 更新删除 | 通常要重写文件或整表覆盖 | 支持 update、delete、merge |
| 增量处理 | 需要自己判断哪些文件是新增的 | 可以基于版本和变更做增量处理 |
| 回滚排查 | 文件被覆盖后很难还原 | 可以 Time Travel 到旧版本 |
| 并发写入 | 容易互相覆盖 | 通过事务日志协调提交 |

**Delta 的几个关键能力：**

1. **ACID 事务**：即使底层是对象存储，也能保证一次写入要么完整成功，要么不生效，避免下游读到半批数据。
2. **Schema Enforcement**：写入时检查字段和类型，不符合表定义的数据不能悄悄混进去。
3. **Schema Evolution**：在允许的情况下支持字段演进，例如新增字段，而不是每次都手工重建表。
4. **Merge / Upsert**：可以按主键或业务键把新数据合并进旧表，适合修正、补录、增量加载和维表更新。
5. **Time Travel**：可以按版本或时间查询历史状态，用于审计、回滚、复盘和对账。
6. **统一批流处理基础**：同一张 Delta 表既可以被批处理写入，也可以支持增量读取和流式消费。
7. **数据治理集成**：结合 Unity Catalog 后，可以统一管理 catalog、schema、table、权限、血缘和审计。

放到 EMF 里，这么做的好处非常直接：

- **上传文件不会直接等于最终表**：原始文件可以先进 staging 或中间层，经过 schema 校验、转换、finalise 后再成为可消费的 Delta 表。
- **finalise 更可靠**：EMF 可以把“最终结果发布”做成一次 Delta 提交，避免下游读到一半成功、一半失败的数据。
- **重试和补跑更安全**：如果某个 batch 失败，可以按 `run_uuid`、`batch_id`、Delta version 找到对应写入，决定回滚、覆盖、删除或重跑。
- **catalogue 更有意义**：`CATALOGUE.METADATA` 记录的不只是一个文件路径，而是一个可查询、可审计、有版本的 Delta 数据实体。
- **schema drift 更可控**：上游字段变化可以在写入 Delta 时被发现，符合规则的演进可以进入新版本，不符合规则的变更可以阻断。
- **审计和回溯更强**：金融/风险场景经常要解释“这张结果表当时是怎么来的”，Delta version + metadata + run_uuid 可以把输入、计算和输出串起来。
- **跨项目复用更自然**：不同 workflow 不必传一堆文件路径，可以通过 catalogue 找到某个 `entity_uuid` 对应的 Delta 表或版本。
- **性能优化空间更大**：Delta 表可以配合分区、compaction、Z-Order、统计信息和 Spark 优化，比直接扫零散文件稳定很多。

从 EMF 的角度看，Lakehouse/Delta 不是一个“炫技选型”，而是在解决几个很现实的问题：批处理不能读到半成品，重试不能造成重复数据，schema 变化不能悄悄污染结果，历史结果要能审计，数据资产要能被 catalogue 解析和复用。

可以把 EMF 的 Lakehouse 分层理解成：

| 层次 | 作用 | EMF 中的含义 |
| --- | --- | --- |
| Raw / Landing | 保存原始上传文件 | Azure Storage 中的 csv/json/avro/parquet 文件和 blob metadata |
| Staging / Bronze | 初步解析和落表 | 根据 `LOAD_INFO` 加载后的原始结构化表 |
| Refined / Silver | 清洗、标准化、关联和业务规则处理 | SQL/dbt/Python/UDF 处理后的中间数据 |
| Curated / Gold | 可被下游消费的最终结果 | finalise 后进入 `DATAHUB` 或目标 dataset 的 Delta 表 |
| Catalogue / Metadata | 记录数据资产和血缘 | `CATALOGUE.METADATA`、`VW_METADATA`、`entity_uuid`、`criteria` |

这样分层后，EMF 的数据不再只是“文件上传后跑一段脚本”，而是有一个可治理生命周期：上传、识别、加载、校验、转换、终态化、登记、解析、复用、导出。

**简述：**

> EMF 的技术挑战集中在“动态”和“生产化”两个方面：动态体现在 `file_type`、`LOAD_INFO`、`METADATA`、`PROCESS_TASKS` 会在运行时决定执行路径；生产化体现在 Worker、Service Bus、Databricks、Unity Catalog、Storage、Key Vault 等多个系统必须保持状态一致、权限一致和配置一致。生产问题通常不是单点代码错误，而是元数据、消息、计算资源、权限、schema、重试和状态之间的不一致。因此，EMF 必须重点建设元数据校验、幂等重试、DAG 状态管理、运行可观测性、权限治理和成本控制能力。Lakehouse 和 Delta Lake 的价值，是让 EMF 处理后的数据从“散落在对象存储里的文件”升级成“有事务、有版本、有 schema、有权限、有血缘的表资产”，这正好支撑 EMF 的动态编排、结果终态化、审计追踪和跨 workflow 复用。

## 4. 为什么选 Databricks 而不是 Synapse？

EMF 选择 Databricks，而不是优先选择 Synapse，核心原因不是“Synapse 不能做数据处理”，而是 EMF 的底层设计更接近一个 **元数据驱动的 Lakehouse 数据编排平台**，需要强 Spark 计算、Python 扩展、Delta Lake 表治理、动态任务 API、Notebook/Job/dbt/UDF 混合执行和跨数据集依赖解析。Databricks 在这些能力上更集中、更成熟，也更符合 EMF 的运行方式。

### 4.1 从 EMF 的底层设计看

EMF 的底层不是一个固定 SQL 数仓项目，而是一个长期运行的 Python Worker + 消息队列 + 元数据目录 + Databricks 执行层的组合：

1. **消息驱动**：Azure Service Bus 中的消息触发 Worker 执行不同命令，例如加载文件、创建表、解析输入、执行 SQL/dbt、终态化结果、导出数据等。
2. **元数据驱动**：Worker 根据 `file_type`、`entity_uuid`、`LOAD_INFO`、`METADATA catalogue`、`criteria` 等元数据，动态决定执行路径，而不是调用一套固定脚本。
3. **动态编排**：不同消息可能生成不同任务链路，任务之间存在依赖、重试、取消、超时、状态更新和结果追踪。
4. **混合计算**：同一个数据流程中可能同时包含 SQL、Spark、Notebook、dbt、Python UDF 和领域计算逻辑。
5. **Lakehouse 管理**：数据不是只进入传统数仓表，而是需要围绕 Delta 表、Unity Catalog、schema 演进、快照、分区、终态表和导出结果做统一管理。

这种设计更像“数据平台 + 编排引擎 + Lakehouse 计算层”，而不是单纯的“SQL 数仓 + 报表模型”。因此，计算平台需要具备灵活的任务 API、强 Python/Spark 扩展能力、表治理能力和对动态数据流程的支持。

### 4.2 为什么 Databricks 更匹配这种设计？

**1. Spark 和分布式 ETL/ELT 能力更强**

EMF 需要处理文件接入、表创建、SQL 转换、分区处理、快照、终态化和导出等复杂 ETL/ELT 场景。Databricks 原生围绕 Spark 构建，适合大规模数据清洗、转换、Join、聚合、UDF 和批处理任务。

Synapse 也有 Spark Pool，但它的核心优势更多体现在 Dedicated SQL Pool、Serverless SQL 和结构化数仓分析上。如果主要是固定表模型、固定 SQL 转换和 BI 查询，Synapse 很合适；但 EMF 的处理逻辑更动态、更偏平台化，Databricks 的 Spark-first 架构更适合承载这类任务。

**2. Python 领域计算和 UDF 扩展更自然**

EMF 中存在金融风险相关的领域计算，例如流动性 UDF、RWA CRM、授信层级等。这类逻辑通常不只是 SQL 聚合，而是包含 Python 函数、复杂规则、数据结构处理和可复用计算模块。

Databricks 对 Python、PySpark、Notebook、UDF、包依赖和交互式调试支持更完整。开发人员可以用 Python 编写复杂业务逻辑，再通过 Spark 分布式执行。Synapse 虽然也支持 Spark 和 Notebook，但在以 Python/Spark 为核心的工程化开发、调试、任务化执行和生态成熟度上，Databricks 更贴合 EMF 的用法。

**3. Databricks Job API 更适合动态任务调度**

EMF 的 Worker 会根据消息和元数据动态生成任务，不同命令可能调用不同 Notebook、SQL、dbt 或参数化 Job。这个场景要求计算平台能被外部系统稳定调用、传参、监控状态、处理失败和重试。

Databricks Jobs/Workflows 和 REST API 更适合这种模式：

- Worker 可以根据消息动态选择 Job 或 Notebook。
- 可以传入 `file_type`、`entity_uuid`、`criteria`、目标表、项目环境等参数。
- 可以跟踪运行状态、失败原因和执行结果。
- 可以和 EMF 自己的超时、取消、重试、状态表结合。

Synapse Pipeline 也能做编排，但如果编排逻辑高度动态、由外部 Worker 和元数据决定，往往需要在 Pipeline、Spark Pool、SQL Pool、Notebook、Trigger 之间组合，整体会更分散。EMF 的调度中心已经在 Python Worker 中，因此更需要一个可 API 化调用的强计算引擎，而 Databricks 更符合这个角色。

**4. Delta Lake 和 Lakehouse 表管理更成熟**

EMF 需要的不只是查询数据，还包括数据生命周期管理：加载、建表、schema 解析、分区、快照、终态化、导出、审计和多版本结果追踪。Databricks 与 Delta Lake 结合紧密，适合做 Lakehouse 场景下的 ACID 表管理、Merge、Schema Evolution、Time Travel 和大规模表操作。

Synapse 更偏传统数仓和 SQL 分析。如果把 EMF 迁移成 Blob + Synapse，也可以实现一部分能力，但需要额外设计很多 Lakehouse 能力，例如：

- Delta 表治理如何替代或重构。
- schema 演进如何处理。
- 数据快照和终态化如何实现。
- 复杂 Merge、增量处理和版本追踪如何统一。
- 数据目录和权限治理如何与现有 EMF 元数据体系对接。

Databricks 在这些方面是原生优势，因此迁移成本和设计复杂度更低。

**5. Unity Catalog 更符合多项目、多环境治理**

EMF 需要支持多项目、多环境和跨订阅数据访问。数据平台不仅要能计算，还要能管理表、schema、权限、目录和数据资产。Unity Catalog 可以把数据目录、权限控制、表治理、数据血缘和 Lakehouse 资产管理统一起来。

对于 EMF 来说，这与 `METADATA catalogue`、数据集、实体、依赖关系、终态表和导出结果的管理方式更一致。Synapse 也可以结合 Azure 权限、SQL 权限和 Purview 等组件做治理，但整体上需要更多组件拼接；Databricks + Unity Catalog 对 Lakehouse 表治理的集成度更高。

**6. 更适合 Notebook、SQL、dbt、Python 混合工作负载**

EMF 不是只执行一种类型的任务。有些流程适合 SQL，有些适合 dbt，有些适合 Notebook，有些必须用 Python/UDF。Databricks 可以在一个平台中比较自然地承载这些混合任务，并通过 Jobs/Workflows 统一执行。

Synapse 更适合 SQL Pool、Serverless SQL、Pipeline 和 BI 结合的分析场景。如果 EMF 的目标是搭建标准化数据仓库、固定维度模型和 Power BI 报表，Synapse 的优势会更明显；但 EMF 当前更像一个动态数据处理平台，Databricks 的混合计算能力更匹配。

### 4.3 Databricks 生产中会出现的问题

Databricks 不是“用了就没有问题”。它解决了很多底层计算和 Lakehouse 表管理问题，但也会带来自己的生产风险。EMF 如果把 Databricks 作为主要计算层，就必须把这些风险纳入调度、监控和运维设计里。

**1. Cluster 启动慢、排队和资源争抢**

- Job cluster 冷启动可能需要几分钟，首个 task 的延迟会比较明显。
- 高峰期多个 workflow 同时触发，Databricks job queue 可能排队。
- Driver 或 executor 配置太小，会 OOM；配置太大，会成本浪费。
- Autoscaling 扩容不是瞬时完成的，短任务可能还没扩起来就结束了，长任务又可能在扩容前已经积压。
- 多项目共用 workspace 或 cluster policy 时，某个大任务可能挤占其他任务资源。

**2. Spark 执行性能问题**

- 大表 join、group by、distinct、window function 可能触发大量 shuffle。
- 数据倾斜会导致少数 executor 长时间跑不完，整体 job 被几个慢 task 拖住。
- 小文件过多会导致 task 数量爆炸，调度开销和元数据读取成本很高。
- 分区设计不合理会让查询扫太多数据，或者产生过多分区目录。
- Python UDF、普通 pandas 操作、逐行处理会绕开很多 Spark 优化，导致性能明显下降。
- cache/persist 使用不当会挤爆内存，反而引起 spill、GC 或 executor 重启。

**3. Delta 表和 Lakehouse 管理问题**

- 多个 job 同时写同一张 Delta 表时，可能出现事务冲突，需要重试或串行化。
- `MERGE` 很方便，但如果匹配条件不准，可能误更新大量数据。
- schema evolution 如果放得太开，可能把上游错误字段也接受进表里。
- `VACUUM` 保留时间设置不合理，可能影响历史版本回溯或下游还在读取的文件。
- 小文件没有定期 compact，长期会拖慢查询和 metadata 操作。
- 表分区、聚簇、统计信息维护不到位，会导致查询越来越慢。

**4. 代码、依赖和运行环境问题**

- Notebook 容易隐藏状态，例如前一个 cell 的变量、临时视图、手工调试代码没有清理干净。
- Python package、dbt version、Databricks Runtime version 不一致，会导致 dev/test/prod 行为不同。
- 任务参数通过 widget、job parameter 或环境变量传递时，如果参数缺失，错误可能在运行中后段才暴露。
- Notebook、SQL、dbt、Python 脚本混合后，错误栈分散，定位问题比单一代码仓库更复杂。

**5. 权限、网络和 Unity Catalog 问题**

- Worker 能提交 job，不代表 Databricks job 的运行身份能访问目标 storage、catalog、schema 或 table。
- Unity Catalog 权限粒度细，错误表现可能是 permission denied，也可能像 table not found。
- 跨订阅、跨 workspace、跨 storage account 访问时，network、managed identity、storage credential、external location 任一层出错都会失败。
- Secret 轮换后，如果 cluster、job 或 notebook 没有同步刷新，生产任务可能突然失败。

**6. Job API、状态同步和可观测性问题**

- Worker 提交 job 成功但记录 `databricks_run_id` 前重启，会造成内部状态和外部状态断裂。
- Databricks job 已失败或已取消，但 Worker 轮询延迟，平台状态仍显示 running。
- API 调用超时、限流或临时失败时，需要区分“提交失败”和“提交成功但响应丢失”。
- 一个 workflow 里有很多 Databricks runs 时，如果没有统一 trace id，排查会在 Worker 日志、Service Bus、Databricks job 页面和 metadata 表之间来回跳。

**7. 成本不可控**

- 高并发同时拉起 cluster，会让成本瞬间升高。
- 大 shuffle、重复全量刷新、频繁 `MERGE`、小文件扫描都会持续消耗 DBU 和云资源。
- All-purpose cluster 如果长期不关，成本会比 job cluster 更难控制。
- 为了赶 SLA 盲目加大 cluster，可能掩盖了数据布局、SQL 写法或 workflow 并发设计的问题。

### 4.4 Databricks 常见优化手段

Databricks 优化不能只看一条 SQL 或一个 Notebook，而要从 EMF 的任务调度、Spark 计算、Delta 表布局、集群策略和发布治理一起做。

**1. 计算资源优化**

- 对生产任务优先使用 job cluster 或受控 cluster policy，避免长期占用 all-purpose cluster。
- 对冷启动敏感的任务使用 cluster pool，减少首个 task 延迟。
- 按任务类型拆 compute：轻量 SQL、普通 ETL、大 shuffle、Python/UDF、导出任务不要都挤在同一种 cluster 配置上。
- 设置合理的 autoscaling min/max，避免 min 太小导致扩容慢，也避免 max 太大导致成本失控。
- 对高并发 workflow 做资源池和并发上限，避免 Worker 一次性提交过多 Databricks jobs。

**2. Spark SQL 和 PySpark 优化**

- 尽量使用 Spark SQL 内置函数、DataFrame API 和向量化逻辑，少用逐行 Python UDF。
- 大表 join 前检查数据量、分区和 join key 分布；小表可以 broadcast，大表倾斜可以做 salting 或拆分热点 key。
- 开启或利用 Adaptive Query Execution，让 Spark 在运行时优化 join strategy、shuffle partition 和 skew。
- 避免不必要的 `collect()`、`toPandas()` 和 driver 端大对象操作。
- 对重复使用的中间结果可以 cache，但必须明确 unpersist，避免内存长期被占。
- 对超大 DAG 或很长 lineage，可以在关键阶段 checkpoint 或写中间 Delta 表，降低失败重算成本。

**3. Delta 表和数据布局优化**

- 控制小文件：加载或 finalise 后定期 compact，避免成千上万个小文件拖慢查询。
- 合理分区：按业务日期、region、scenario 等低到中等基数字段分区，不要用 `entity_uuid` 这类高基数字段做分区。
- 对常用过滤字段做聚簇、Z-Order 或平台支持的数据跳过优化，让查询少扫文件。
- 对大表维护统计信息，帮助优化器做更好的执行计划。
- `MERGE` 前尽量缩小源数据和目标数据范围，例如按业务日期或 batch 范围过滤，避免全表 merge。
- 对历史快照、中间表和临时表设置保留策略，配合 `VACUUM` 清理无用文件，但保留时间不能破坏审计和回滚需求。

**4. EMF 调度层优化**

- Worker 提交 Databricks job 前先做限流，按 project、workflow、command、dataset 分配并发额度。
- 对不同命令设置不同 timeout，例如加载、SQL 转换、finalise、export 的超时策略不应完全相同。
- 每个 Databricks task 记录 `run_uuid`、`order_id`、`entity_uuid`、job id、run id、cluster id，方便失败后自动汇总。
- 对可重试错误使用指数退避；对权限、schema、数据质量错误直接失败并进入人工处理。
- 对 job 提交和状态轮询做幂等保护，避免 API 超时后重复提交同一个计算。
- 对批量小任务考虑合并执行，减少 Databricks job 启动和调度开销。

**5. 发布和运行环境优化**

- 固定 Databricks Runtime、Python package、dbt version 和 notebook/script 版本，避免环境漂移。
- Notebook 生产化时要减少隐藏状态：参数入口明确、临时表命名带 run id、调试代码和手工变量不要留在生产路径。
- 重要 SQL/dbt/Python 逻辑进入代码仓库和 CI，而不是只存在 workspace notebook 里。
- 发布前用小数据 dry-run 验证参数、权限、schema 和目标表。
- 对核心作业保留 Spark UI、event log、query profile 和 driver/executor log，作为性能复盘依据。

### 4.5 Databricks 的真正收益：不是功能唯一，而是降低平台复杂度

如果把功能拆开看，很多事情不用 Databricks 也能做：

- 分布式计算可以用开源 Spark、自建 Kubernetes Spark、Synapse Spark Pool 或其他计算平台。
- SQL 查询可以用 Synapse、SQL Server、Snowflake、BigQuery 或其他数仓。
- 文件可以直接放 Azure Blob / ADLS。
- 编排可以用 Airflow、ADF、Synapse Pipeline 或 EMF 自己的 Worker。
- 权限和目录可以用 Azure RBAC、Purview、外部 catalog 或自研 metadata 表。

所以，Databricks 的价值不是“没有它就绝对做不了”，而是它把 **Spark 计算、Delta 表事务、Job API、Notebook/dbt/Python/SQL 混合执行、Unity Catalog 治理和运行观测** 放在一个相对统一的边界里。对 EMF 来说，这很关键，因为 EMF 本身已经要负责 workflow、metadata、message、retry、状态机和人工排障。如果再自己拼计算层、表事务层和治理层，平台复杂度会明显上升。

更直白地说，EMF 用 Databricks 的好处是：

1. **少造计算引擎的轮子**：EMF 不需要自己管理 Spark 集群、executor、shuffle、job run、driver log 和大规模数据计算细节。
2. **少造表事务的轮子**：Delta Lake 已经提供 ACID、schema 管控、merge、time travel、版本追踪，EMF 可以把精力放在“什么时候加载、怎么编排、怎么登记 metadata”。
3. **少造治理和权限拼接层**：Unity Catalog 可以统一 catalog、schema、table、权限、血缘和审计，比 EMF 自己把 Storage ACL、SQL 权限、metadata 表和外部目录硬拼起来更自然。
4. **混合 workload 更顺**：SQL、Spark、dbt、Notebook、Python/UDF 可以在同一平台里被 Job API 调用，不需要在多个执行系统之间搬数据、同步权限和对齐状态。
5. **动态任务更好接入**：EMF Worker 可以把 Databricks 当成一个强计算后端，动态传参、提交、轮询、取消和收集错误，而不是把动态逻辑拆散到多个 pipeline 组件里。
6. **生产排障边界更清楚**：EMF 查控制面状态，Databricks 查计算面状态；两边通过 `databricks_run_id` 和 trace id 关联，问题边界比“Pipeline + SQL Pool + Spark Pool + 外部服务 + 自研 metadata”更清晰。
7. **对金融/风险复杂计算更友好**：RWA、流动性、层级关系、复杂规则和 UDF 不一定适合完全写成 T-SQL，Python/PySpark 的表达能力更强。

什么时候其实不一定要 Databricks？

- 数据量很小，单机 Python 或普通数据库就能稳定处理。
- 流程固定，主要是 T-SQL、存储过程和 BI 报表。
- 没有复杂 Python/UDF，没有动态 schema，没有跨项目 metadata resolution。
- 不需要 Delta 版本、time travel、merge、schema evolution 和 Lakehouse 表治理。
- 团队已经有成熟数仓平台，并且 EMF 只是很薄的一层调度。

但 EMF 当前的特点是：数据类型多、schema 动态、workflow 动态、依赖靠 catalogue resolution、计算里有 SQL/dbt/Notebook/Python/UDF、结果需要 finalise/catalogue/export、还要跨环境和跨项目治理。这个组合下，Databricks 的价值不只是“能跑 Spark”，而是能把大部分数据计算和 Lakehouse 管理能力收敛在一个平台里，让 EMF 专注做元数据编排和可靠调度。

一句话概括：**Databricks 不是让 EMF 少写所有代码，而是让 EMF 不必自己实现一个分布式计算平台、Delta 表事务层、Notebook/SQL/Python 混合执行层和统一数据治理层。**

### 4.6 从具体用例判断

**用例 1：根据 `file_type` 动态建表和加载数据**

EMF 可以根据 `file_type` 查询 `LOAD_INFO`，解析 schema，决定目标表和加载方式。不同文件类型可能有不同字段、分区、清洗规则和落表路径。Databricks 适合用 Spark/PySpark 和 Delta 表完成这种动态加载和表操作。

如果用 Synapse，也可以通过 SQL 外表、COPY、Pipeline 或 Spark Pool 实现，但动态 schema、动态任务参数、Delta/Lakehouse 表管理和 Python 逻辑会更分散，工程复杂度更高。

**用例 2：根据 `criteria` 从 metadata catalogue 解析依赖输入**

EMF 的某些任务不是固定读取某张表，而是根据业务条件从目录中解析满足条件的数据资产。这要求系统能动态查询元数据、组装输入、生成执行计划，再触发后续计算。

Databricks 更适合把这类“元数据查询 + Spark 计算 + Delta 表输出”放在一个执行环境中完成。Synapse 更适合已知输入、固定 SQL 模型和结构化查询；对于高度动态的依赖解析，需要额外编排和更多自定义逻辑。

**用例 3：执行 Python 领域计算和 UDF**

金融风险、流动性、RWA、层级关系等计算经常包含复杂规则，不一定能优雅地写成 T-SQL。Databricks 允许使用 Python/PySpark 编写领域逻辑，并与 SQL、Delta 表和 Notebook 串联。

如果用 Synapse Dedicated SQL Pool，很多 Python 逻辑需要改写成 T-SQL、存储过程或外部服务；如果用 Synapse Spark Pool，又需要额外处理 Spark 与 SQL Pool 之间的数据、权限和任务衔接。对 EMF 来说，Databricks 的一体化体验更自然。

**用例 4：长时间运行任务的状态追踪、重试、取消和超时**

EMF 的 Worker 需要管理长时间运行任务，包括并发执行、失败重试、取消、超时和状态追踪。Databricks Job API 可以作为后端执行层，Worker 负责平台级状态和控制，Databricks 负责实际分布式计算。

Synapse Pipeline 也能做任务编排和监控，但如果 EMF 已经有自己的 Worker 调度模型，再把大量动态逻辑放进 Synapse Pipeline，容易形成“双编排中心”：一部分逻辑在 Worker，一部分逻辑在 Pipeline，系统复杂度会增加。

**用例 5：结果终态化、快照和导出**

EMF 需要把中间处理结果转换成最终可消费的数据集，并可能生成快照、按实体导出或发布到下游系统。Databricks + Delta Lake 对这种表级操作、版本管理和大规模导出更友好。

Synapse 更适合最终结构化模型的查询和服务。如果把所有终态化逻辑放到 Synapse，需要更多 SQL 存储过程、外部表、Pipeline 活动和权限配置配合，整体灵活性不如 Databricks。

### 4.7 Synapse 更适合什么场景？

Synapse 并不是不好，而是更适合另一类目标：

- 以结构化数仓为核心，表模型相对稳定。
- 主要使用 T-SQL、存储过程和固定 ELT 流程。
- 面向 BI、报表、即席 SQL 查询和聚合分析。
- 数据处理链路较固定，动态依赖和 Python 领域计算较少。
- 需要与 Power BI、SQL Pool、Serverless SQL 做紧密集成。

如果 EMF 的目标变成“把数据整理进标准数仓，再提供 BI 报表分析”，Synapse 会是合理选择。但当前 EMF 的核心是“元数据驱动的数据编排和 Lakehouse 处理平台”，不仅要查数据，还要动态生成任务、处理依赖、运行 Python/Spark/dbt/UDF、管理 Delta 表和发布结果，因此 Databricks 更适合。

### 4.8 总结判断

| 判断维度 | EMF 的需求 | Databricks 适配度 | Synapse 适配度 |
| --- | --- | --- | --- |
| 计算模型 | Spark、SQL、Python、dbt、UDF 混合计算 | 高，原生支持混合工作负载 | 中，能力分散在 SQL Pool、Spark Pool、Pipeline 中 |
| 编排方式 | Worker 根据消息和元数据动态触发任务 | 高，Job API 和参数化任务更适合 | 中，Pipeline 更适合相对固定流程 |
| 数据管理 | Delta 表、schema 演进、快照、终态化 | 高，Delta Lake/Lakehouse 原生优势 | 中，需要额外设计和组件组合 |
| Python 扩展 | 领域计算、UDF、复杂规则 | 高，Python/PySpark 生态成熟 | 中，Spark 可支持，但与数仓能力衔接更复杂 |
| 治理方式 | 多项目、多环境、目录、权限、数据资产 | 高，Unity Catalog 集成度高 | 中，可通过多组件实现，但集成度较分散 |
| 运维边界 | Worker 做控制面，计算平台做执行面 | 高，Job run、Spark UI、Delta、权限和日志较集中 | 中，状态分散在 Pipeline、SQL Pool、Spark Pool 和外部服务中 |
| 平台复杂度 | 不希望 EMF 自建计算层和表事务层 | 高，减少自研和组件拼接 | 中，可实现，但需要更多胶水逻辑 |
| 典型场景 | 元数据驱动数据平台、复杂 ETL/ELT、动态 DAG | 更适合 | 可实现部分能力，但改造成本更高 |
| 最佳使用方向 | Lakehouse + 数据工程 + 动态编排 | 强项 | 更偏数仓、SQL 分析和 BI |

**简述：**

> EMF 的核心不是固定 SQL 报表系统，而是一个元数据驱动的数据编排平台。它需要根据消息和元数据动态生成任务，处理依赖、并发、重试、取消和超时，并调用 SQL、Notebook、dbt、UDF 和 Python 领域计算完成复杂 ETL/ELT。Databricks 的价值不是每个单点功能都不可替代，而是把 Spark 计算、Delta Lake 表事务、Unity Catalog 治理、Python 扩展和 Job API 化执行收敛在一个平台边界里。这样 EMF 可以专注做控制面和元数据编排，而不需要自己拼出一套分布式计算平台、表事务层、权限治理层和运维观测层。Synapse 更适合固定 SQL 数仓、BI 查询和结构化报表场景；如果用 Synapse 实现 EMF，需要把很多动态编排、Python 计算、Lakehouse 表治理和元数据解析能力重新拆分到 Pipeline、SQL Pool、Spark Pool 和外部服务中，整体复杂度和迁移成本都会更高。

---

## 5. 如果用 Blob + Synapse 可以吗？

- 理论上可以，但属于架构重构，迁移成本高。
- Python/UDF/领域计算需重写为 T-SQL、存储过程或外部服务。
- Delta Lake/Unity Catalog 能力需替代，表治理、ACID、Merge、Schema Evolution 等需额外设计。
- 动态任务编排、依赖调度、重试取消等复杂度更高。
- Synapse 适合结构化数仓和报表分析，EMF 这种动态数据处理平台更适合 Databricks。

---

## 6. 面试/答辩表达建议

- EMF 是一个元数据驱动的数据编排平台，支持动态任务调度、Python 领域计算、UDF、Databricks Job、Lakehouse 数据治理。
- Databricks 在 Spark、Delta Lake、Python 扩展和 API 化执行方面更适合这种复杂 ETL/ELT 和平台化场景。
- Synapse 适合结构化数仓和 BI 分析，若业务目标变为标准数仓和报表分析，Blob + Synapse 也可行，但对当前 EMF 平台迁移成本和能力损失较大。
