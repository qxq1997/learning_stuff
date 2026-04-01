# 数据库迁移与 ORM 说明

本文档说明 TalentHub 当前如何同时使用：

- PostgreSQL
- SQLAlchemy ORM
- Alembic migration

## 1. 当前策略

当前项目采用的是“接管现有数据库”的方式，而不是“删库重建”。

这意味着：

- 当前数据库结构以 [backend/sql/001_init_schema.sql](/Users/xinqi/WebstormProjects/TalentHub/backend/sql/001_init_schema.sql) 为基线
- 当前 ORM 模型以代码形式映射这套 schema
- 当前 Alembic 将这套 schema 记为 baseline revision
- 后续所有结构变化通过 migration 演进

## 2. 为什么不用每次重建数据库

因为数据库数据需要持久化。

正常开发流程应该是：

- 保留 `postgres_data`
- 启动 PostgreSQL 容器后复用旧数据
- 如果表结构变化，通过 Alembic 升级

而不是：

- 删除数据目录
- 重建数据库
- 重新导入所有数据

## 3. ORM 的作用

ORM 模型定义在各模块的 `infrastructure/models.py` 中。

例如：

- [backend/app/modules/identity/infrastructure/models.py](/Users/xinqi/WebstormProjects/TalentHub/backend/app/modules/identity/infrastructure/models.py)
- [backend/app/modules/knowledge/infrastructure/models.py](/Users/xinqi/WebstormProjects/TalentHub/backend/app/modules/knowledge/infrastructure/models.py)
- [backend/app/modules/question_bank/infrastructure/models.py](/Users/xinqi/WebstormProjects/TalentHub/backend/app/modules/question_bank/infrastructure/models.py)

这些模型是当前数据库结构的代码表达，用于：

- 持久化映射
- 未来仓储实现
- Alembic 自动比对

## 4. Alembic 的作用

Alembic 是数据库迁移工具。

在当前项目里，它负责：

- 记录数据库版本
- 在未来新增 revision
- 将 schema 变更以迁移形式显式执行

当前 Alembic 入口：

- [backend/alembic.ini](/Users/xinqi/WebstormProjects/TalentHub/backend/alembic.ini)
- [backend/alembic/env.py](/Users/xinqi/WebstormProjects/TalentHub/backend/alembic/env.py)
- [backend/alembic/versions/20260319_0001_baseline.py](/Users/xinqi/WebstormProjects/TalentHub/backend/alembic/versions/20260319_0001_baseline.py)
- [backend/alembic/versions/20260322_0002_add_question_generation_metadata.py](/Users/xinqi/WebstormProjects/TalentHub/backend/alembic/versions/20260322_0002_add_question_generation_metadata.py)
- [backend/alembic/versions/20260322_0003_add_question_tags.py](/Users/xinqi/WebstormProjects/TalentHub/backend/alembic/versions/20260322_0003_add_question_tags.py)

## 5. 当前 baseline 的含义

当前 baseline revision 是一个“接管点”，不是重新建表脚本。

原因是：

- 数据库已经存在
- schema 已经初始化完成
- 我们要做的是告诉 Alembic：“从这一刻开始，这套 schema 由你管理”

因此当前 baseline revision 不会重复执行 DDL，而是配合 `alembic stamp` 使用。

## 6. 命令说明

### 6.1 现有数据库接入 Alembic

```bash
make db-stamp
```

作用：

- 创建 `alembic_version`
- 把当前数据库标记为 baseline
- 不修改已有表结构

### 6.2 未来结构升级

```bash
make db-upgrade
```

作用：

- 将数据库升级到最新 migration

### 6.3 新空数据库首次初始化

当前项目仍保留显式 bootstrap 方式：

```bash
make db-up
make db-bootstrap
make db-stamp
```

这里故意不做“自动猜测数据库是否为空”的逻辑。空库初始化和已有库接管是两条明确路径。

## 7. 为什么这套方式符合 fail fast

- 已有库直接接管，不乱动旧数据
- 空库初始化需要显式执行 bootstrap
- schema 变更需要显式 migration
- 不依赖隐式 fallback 或启动时自动猜测

## 8. 索引和迁移必须一起演进

TalentHub 中，索引不是“数据库里手工点一下”就结束的东西。

只要索引进入正式设计，就必须同时处理三处：

1. ORM 模型
2. 空库初始化 SQL
3. Alembic migration

否则会出现：

- 旧数据库和新空库结构不一致
- 代码以为有索引，实际运行环境没有
- 文档、代码、数据库三者脱节

索引设计原则和当前推荐清单见：

- [数据库索引策略](./23-数据库索引策略.md)
