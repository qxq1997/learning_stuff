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

### 3.3 生产治理和应对思路

为了让 EMF 在生产中稳定运行，需要从平台能力、流程规范和运维监控三方面治理。

**1. 强化元数据校验**

- 发布前校验 `LOAD_INFO` 是否唯一、schema 是否可解析、`ingestion_workflow_name` 是否存在。
- 校验 `PROCESS_TASKS` 的 `parents` 是否形成合法 DAG，是否存在孤儿节点或循环依赖。
- 校验 catalogue 中 metadata 是否包含必要字段，例如 `dataset`、`table_name`、`workflow`、`run_uuid`。
- 对 `file_type` 命名、大小写、版本号建立规范。

**2. 建立幂等和重跑机制**

- 使用 `run_uuid`、`batch_id`、`entity_uuid` 区分一次运行、一个批次和一个数据实体。
- 对建表、finalise、catalogue、export 设计重复执行保护。
- 对 append 类加载增加去重或重复批次检查。
- 明确哪些步骤可以安全重试，哪些步骤失败后必须人工确认。

**3. 完善监控和告警**

- 监控 Service Bus 队列积压、dead-letter、消息处理延迟。
- 监控 Worker 存活、线程池、错误率、重试次数。
- 监控 Databricks Job 成功率、运行时长、排队时间和成本。
- 监控 catalogue resolution 失败率、`LOAD_INFO` 缺失、metadata 缺失。
- 对 SLA 超时、长时间运行、异常重试和取消失败建立告警。

**4. 统一日志和运行视图**

- 把 message id、run_uuid、batch_id、order_id、entity_uuid、Databricks run id 串起来。
- 支持从一个失败 task 反查它的输入 metadata、process_tasks 定义、Databricks job 和输出表。
- 对业务错误、数据错误、权限错误、平台错误做错误分类，方便一线运维判断处理路径。

**5. 控制 Databricks 成本和性能**

- 按任务类型选择合适 cluster policy、worker size 和 auto-scaling 策略。
- 对大表 join、UDF、shuffle-heavy 任务做专项性能优化。
- 对高并发批处理设置限流，避免同时拉起过多 job。
- 对临时表、快照、日志和中间数据设置生命周期清理策略。

**6. 规范发布和配置管理**

- 把代码、Terraform、参数文件、`LOAD_INFO`、`PROCESS_TASKS`、Notebook/dbt 版本一起纳入发布检查。
- 重要元数据变更先在非生产环境 dry-run。
- 生产发布后执行 smoke test，验证 upload、resolve、finalise、export 主链路。
- 对 `LOAD_INFO` 缓存刷新建立明确流程，避免旧配置继续生效。

**简述：**

> EMF 的技术挑战集中在“动态”和“生产化”两个方面：动态体现在 `file_type`、`LOAD_INFO`、`METADATA`、`PROCESS_TASKS` 会在运行时决定执行路径；生产化体现在 Worker、Service Bus、Databricks、Unity Catalog、Storage、Key Vault 等多个系统必须保持状态一致、权限一致和配置一致。生产问题通常不是单点代码错误，而是元数据、消息、计算资源、权限、schema、重试和状态之间的不一致。因此，EMF 必须重点建设元数据校验、幂等重试、DAG 状态管理、运行可观测性、权限治理和成本控制能力。

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

### 4.3 从具体用例判断

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

### 4.4 Synapse 更适合什么场景？

Synapse 并不是不好，而是更适合另一类目标：

- 以结构化数仓为核心，表模型相对稳定。
- 主要使用 T-SQL、存储过程和固定 ELT 流程。
- 面向 BI、报表、即席 SQL 查询和聚合分析。
- 数据处理链路较固定，动态依赖和 Python 领域计算较少。
- 需要与 Power BI、SQL Pool、Serverless SQL 做紧密集成。

如果 EMF 的目标变成“把数据整理进标准数仓，再提供 BI 报表分析”，Synapse 会是合理选择。但当前 EMF 的核心是“元数据驱动的数据编排和 Lakehouse 处理平台”，不仅要查数据，还要动态生成任务、处理依赖、运行 Python/Spark/dbt/UDF、管理 Delta 表和发布结果，因此 Databricks 更适合。

### 4.5 总结判断

| 判断维度 | EMF 的需求 | Databricks 适配度 | Synapse 适配度 |
| --- | --- | --- | --- |
| 计算模型 | Spark、SQL、Python、dbt、UDF 混合计算 | 高，原生支持混合工作负载 | 中，能力分散在 SQL Pool、Spark Pool、Pipeline 中 |
| 编排方式 | Worker 根据消息和元数据动态触发任务 | 高，Job API 和参数化任务更适合 | 中，Pipeline 更适合相对固定流程 |
| 数据管理 | Delta 表、schema 演进、快照、终态化 | 高，Delta Lake/Lakehouse 原生优势 | 中，需要额外设计和组件组合 |
| Python 扩展 | 领域计算、UDF、复杂规则 | 高，Python/PySpark 生态成熟 | 中，Spark 可支持，但与数仓能力衔接更复杂 |
| 治理方式 | 多项目、多环境、目录、权限、数据资产 | 高，Unity Catalog 集成度高 | 中，可通过多组件实现，但集成度较分散 |
| 典型场景 | 元数据驱动数据平台、复杂 ETL/ELT、动态 DAG | 更适合 | 可实现部分能力，但改造成本更高 |
| 最佳使用方向 | Lakehouse + 数据工程 + 动态编排 | 强项 | 更偏数仓、SQL 分析和 BI |

**简述：**

> EMF 的核心不是固定 SQL 报表系统，而是一个元数据驱动的数据编排平台。它需要根据消息和元数据动态生成任务，处理依赖、并发、重试、取消和超时，并调用 SQL、Notebook、dbt、UDF 和 Python 领域计算完成复杂 ETL/ELT。Databricks 在 Spark、Delta Lake、Unity Catalog、Python 扩展和 Job API 化执行方面更符合 EMF 的底层设计；Synapse 更适合固定 SQL 数仓、BI 查询和结构化报表场景。如果用 Synapse 实现 EMF，需要把很多动态编排、Python 计算、Lakehouse 表治理和元数据解析能力重新拆分到 Pipeline、SQL Pool、Spark Pool 和外部服务中，整体复杂度和迁移成本都会更高。

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
