# DDD 领域模型设计

本文档定义 TalentHub 的限界上下文、核心聚合、领域服务和推荐使用的设计模式。

## 1. 架构风格

项目采用 DDD + 模块化单体。

每个模块都遵循统一分层：

- `domain`：实体、值对象、聚合、领域服务、领域事件
- `application`：用例、命令、查询、DTO、事务边界
- `infrastructure`：数据库、仓储实现、外部模型调用、向量检索接入
- `interfaces`：HTTP API、请求响应模型、鉴权接入

## 2. 限界上下文

### 2.1 Identity & Organization

职责：

- 用户
- 角色
- 部门
- 岗位
- 权限边界

核心聚合：

- `User`
- `Department`

### 2.2 Knowledge Base

职责：

- 文档上传
- 文档版本管理
- 文档切片
- 向量检索
- 文档标签管理

核心聚合：

- `KnowledgeDocument`

### 2.3 Question Bank

职责：

- 题目生成
- 题目版本管理
- 知识点绑定
- 题目审核与发布
- 来源追踪

核心聚合：

- `Question`

### 2.4 Exam

职责：

- 试卷管理
- 试卷题目快照
- 考试分配
- 作答过程
- 提交状态管理

核心聚合：

- `ExamPaper`
- `ExamAttempt`

### 2.5 Evaluation

职责：

- 评分规则定义
- 客观题判分
- 主观题 AI 评分
- 逐题反馈
- 能力分析结果

核心聚合：

- `GradingResult`

### 2.6 Learning

职责：

- 学习路径
- 路径节点
- 用户路径进度
- 个性化建议

核心聚合：

- `LearningPath`
- `UserLearningProgress`

### 2.7 Analytics

职责：

- 行为事件记录
- 指标聚合
- 报表快照

核心聚合：

- `ActivityEvent`
- `MetricSnapshot`

## 3. 聚合设计原则

### 3.1 Question 聚合

`Question` 只负责题目自身的业务一致性，例如：

- 题目必须属于合法题型
- 已发布题目不能被直接覆盖
- 修改题干时必须生成新版本

题目引用的文档来源、知识点映射可以作为聚合内关联对象，但不能把考试行为直接揉进题目聚合。

### 3.2 ExamPaper 聚合

`ExamPaper` 负责维护一套可投放试卷的完整性，例如：

- 试卷必须有题目
- 题目顺序必须稳定
- 发布后不能无痕修改

试卷中的题目必须引用明确的 `question_version`，避免题目后续修改影响历史考试。

### 3.3 ExamAttempt 聚合

`ExamAttempt` 负责一次考试作答过程，例如：

- 开始时间
- 提交时间
- 当前状态
- 每题作答
- 最终得分

非法状态迁移必须直接失败，不允许模糊补偿。

## 4. 领域服务

以下逻辑不适合塞进单个实体，应作为领域服务或应用服务实现：

- 基于知识库检索内容并生成题目
- 将题库题目按规则编排成试卷
- 对主观题执行评分和反馈生成
- 根据考试结果更新学习路径和能力画像

示例：

- `QuestionGenerationService`
- `PaperAssemblyService`
- `AnswerEvaluationService`
- `LearningProgressService`

## 5. 领域事件

建议在第一版就引入领域事件，但保持实现简单。

推荐事件：

- `KnowledgeDocumentImported`
- `QuestionGenerated`
- `QuestionPublished`
- `ExamAssigned`
- `ExamSubmitted`
- `ExamGraded`
- `LearningPathCompleted`

这些事件可以被后续模块用于：

- 生成指标
- 触发通知
- 更新统计报表
- 触发学习建议

## 6. 推荐设计模式

### 6.1 Repository Pattern

用于隔离领域模型和持久化实现。

示例：

- `QuestionRepository`
- `ExamPaperRepository`
- `ExamAttemptRepository`

### 6.2 Factory Pattern

用于创建结构复杂、校验要求高的领域对象。

示例：

- `QuestionFactory`
- `ExamPaperFactory`

### 6.3 Strategy Pattern

用于根据题型或评分方式切换实现。

示例：

- 选择题判分策略
- 简答题评分策略
- 题目生成策略

### 6.4 Specification Pattern

用于表达筛题、组卷和学习路径解锁等规则。

### 6.5 State Pattern 或显式状态机

用于管理如下状态：

- 文档处理状态
- 题目审核状态
- 考试状态
- 学习任务状态

## 7. 与 AI 能力的边界

AI 模型不是领域对象。

模型调用属于基础设施能力，真正的业务规则应由应用服务和领域模型控制。也就是说：

- 由应用服务决定何时调用模型
- 由领域规则决定生成结果是否可落库
- 模型输出必须经过结构化校验
- 校验失败直接报错，不做含糊修补

## 8. 推荐模块目录

```text
backend/
  app/
    modules/
      identity/
      knowledge/
      question_bank/
      exam/
      evaluation/
      learning/
      analytics/
    shared/
      domain/
      infrastructure/
      config/
```

每个模块内部统一采用：

```text
domain/
application/
infrastructure/
interfaces/
```
