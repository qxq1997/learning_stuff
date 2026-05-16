# AI Agent - 第 32 课：Agentic Engineering：从 Vibe Coding 到工程化 AI 协作

## 学习目标

- 理解 `Vibe Coding` 和 `Agentic Engineering` 的本质区别。
- 从第一性原理理解：为什么 AI 编码不能只追求速度，而要放进完整软件工程约束里。
- 建立一套 Agentic Engineering 的实践框架：Context Engineering、Spec-First、Docs as Code、小任务推进、多层验证、Knowledge as Code、Self-Refinement。
- 理解基于 Skill 的模块化 Agentic Engineering 框架为什么适合作为落地载体。

## 先给结论

如果只记一句话：

**Vibe Coding 是把需求抛给 AI，快速得到“能跑”的结果；Agentic Engineering 是把 AI 放进工程纪律里，在保留理解、约束和验证的前提下提升研发效能。**

前者适合：

- 原型验证
- 个人小项目
- 低风险脚本
- 可快速丢弃的实验

后者适合：

- 生产系统
- 大型代码库
- 多人协作
- 有质量、安全、性能、可维护性要求的工程任务

Agentic Engineering 的关键不是“让 AI 替你写代码”，而是：

**让 AI 成为软件工程全链条中的协作者，同时让工程师保留最终判断权。**

### 一个更短的实践版结论

过去几年，AI 编程工具的粒度一直在变粗：

```text
2021：行级补全
  -> 2023：对话式改代码
  -> 2025：终端 Agent 执行任务
  -> 2026：spec-driven + 多 Agent 并行
```

工具形态一直在变，但真正沉淀下来的模式很简单：

**AI 跑实现，人保留 spec、context、review。**

这三件事分别对应三个控制点：

| 控制点 | 人要保留什么 | 为什么不能全交给 AI |
| --- | --- | --- |
| `spec` | 目标、边界、约束、验收标准 | 没有 spec，AI 只能按局部上下文猜意图 |
| `context` | 哪些文档、代码、规则、历史决策应该进入任务 | 上下文错了，模型越努力越容易偏 |
| `review` | diff 审查、测试验证、设计判断和最终取舍 | AI 能生成答案，但不能替团队承担质量责任 |

也就是说，成熟的 AI 开发不是“人完全放手”，而是“人把驾驶位前移”：

- 不再逐行手写所有实现
- 但要更早定义问题
- 更清楚组织上下文
- 更严格设计验证方式
- 更主动审查 AI 产物

这也是本课最重要的底线：

**AI 可以拥有执行权，但工程师必须保留解释权、验收权和责任边界。**

---

## 内容讲解

### 1. Vibe Coding 到底是什么

Vibe Coding 指的是一种很直觉的 AI 编码方式：

- 开发者把需求直接抛给 AI
- AI 生成代码
- 开发者不认真审查 diff
- 不深入理解生成逻辑
- 只要能跑，就先接受

它的优势很明显：

- 快
- 反馈周期短
- 很适合探索
- 很适合做原型

但代价也很明显：

- 理解被削弱
- 控制被削弱
- 设计约束容易丢失
- 隐藏 bug 很难发现
- 后续维护成本不可控

所以 Vibe Coding 的本质是：

**用速度换取理解和控制。**

这不是说它没有价值。  
而是说它不能作为生产级软件工程的主方法。

更准确地说，`vibe coding` 最初不是泛指“用 AI 辅助开发”。  
Karpathy 在 2025 年 2 月提出这个说法时，强调的是一种更放飞的状态：

- 接受 AI 生成结果
- 不认真读代码
- 不认真读 diff
- 错误信息原样回喂给 AI
- bug 修不掉就绕过去

Simon Willison 后来也做过一个很有用的区分：

- 如果你不读 diff 就 commit，那更接近 vibe coding。
- 如果你写测试、读 diff、能解释代码做了什么，那就是正常的软件开发，只是 AI 提高了速度。

这个区分很重要。  
很多人批评“vibe coding 不靠谱”，其实批评的是“不理解、不审查、不负责”的做法，而不是批评 AI 辅助开发本身。

可以这样记：

```text
不读 diff + 不理解代码 + 只看能不能跑 = Vibe Coding

写 spec + 管 context + 审 diff + 做验证 = Agentic Engineering
```

### 2. Agentic Engineering 是什么

Agentic Engineering 是一种工程师与 AI Agent 深度协作的研发范式。

在这个范式里，AI 不只是：

- 代码补全工具
- 样板代码生成器
- 聊天助手

它还可以参与：

- 问题澄清
- 需求分析
- 方案设计
- 上下文检索
- 编码实现
- 测试生成
- Code Review
- 排障复盘
- 团队知识沉淀

但有一个边界必须守住：

**最终判断和决策权始终在工程师手中。**

这和“全自动 AI 工程师”不是一回事。

Agentic Engineering 追求的不是最大自治，而是：

- 人类定义问题
- AI 扩展执行和分析能力
- 系统保留约束和验证机制
- 团队知识不断沉淀
- 工程质量不因速度提升而下降

### 3. 为什么这里强调 Engineering

Engineering 的本质不是“写代码”，而是：

**在资源、时间、质量、安全、可维护性等约束下，找到最优可行解。**

所以 Agentic Engineering 不是问：

- AI 能不能把代码写出来？

而是问：

- 在复杂约束下，AI 怎么帮助团队更可靠地交付？
- 哪些环节应该交给 AI？
- 哪些判断必须由人做？
- 哪些知识必须结构化给 AI？
- 哪些输出必须验证后才能进入下一步？

这也是它和 Vibe Coding 的根本区别。

Vibe Coding 主要优化速度。  
Agentic Engineering 优化的是约束空间里的总价值。

### 4. 为什么要用第一性原理思考

第一性原理思维，就是把问题拆到不可再分的基本事实，再从这些事实重新推导方法。

它不是问：

- 别人都怎么用 AI 写代码？

而是问：

- 软件工程的本质约束是什么？
- LLM 的本质特征是什么？
- 人类工程师的稀缺资源是什么？
- 在这些事实下，最合理的人机协作方式是什么？

归纳法告诉我们别人怎么做。  
演绎法帮助我们判断为什么这样做，以及能不能做得更好。

Agentic Engineering 很适合用第一性原理分析，因为 AI 工具变化太快。  
如果只追某个工具的用法，很容易过时。  
但如果理解底层约束，就能跟着工具演进调整方法。

### 5. 软件工程的四个固有挑战

软件开发生命周期里，很多痛点不是某个团队特有，而是长期存在的结构性问题。

#### 5.1 信息损耗

人脑里的模糊意图，要经过：

```text
人类意图 -> 自然语言需求 -> 结构化设计 -> 形式化代码 -> 可执行程序
```

每一步都会损耗信息。

典型表现是：

- 需求被误解
- 设计有歧义
- 代码偏离原意
- 文档和实现脱节

#### 5.2 知识孤岛

很多关键知识不在代码里，而在人的脑子里：

- 模块历史决策
- 团队编码规范
- 架构隐含约束
- 排障经验
- 老系统的坑

如果这些知识没有结构化沉淀，AI 也无法利用它们。

#### 5.3 认知成本

理解复杂系统需要大量注意力。

AI 可以帮你读代码、写代码、生成测试，  
但当它一次生成大量 diff 时，工程师的审查压力也会上升。

AI 时代的瓶颈会从“写不出来”转向：

**看不完、想不清、判断不过来。**

#### 5.4 重复性劳动

大量工程活动是机械但不可省略的：

- 写样板代码
- 构造测试数据
- Mock 依赖
- 写脚本
- 做格式转换
- 补边界测试

AI 对这部分帮助最大，但也带来新问题：

**生成成本下降了，验证成本没有同步下降。**

### 6. AI 的双面效应

AI 对软件工程不是单向利好，而是同时带来改善和新问题。

| 维度 | AI 的改善 | AI 引入的新问题 |
| --- | --- | --- |
| 信息损耗 | 缩短从想法到代码的反馈周期 | 概率输出带来“似是而非”的新损耗 |
| 知识孤岛 | 通用知识即时可用 | 团队私有知识仍然缺失 |
| 认知成本 | 释放语法、API、样板代码层面的负担 | 审查信息量暴增 |
| 重复劳动 | 代码和测试生成成本骤降 | 验证成为新瓶颈 |

这就引出一个核心矛盾：

**AI 让生成能力爆炸，但验证能力仍然受人类认知限制。**

Agentic Engineering 就是在这个矛盾里寻找最优协作方式。

### 7. 三层价值模型：加速、增强、解锁

AI 对工程的价值可以分三层。

| 层次 | 名称 | 含义 | 例子 |
| --- | --- | --- | --- |
| L1 | 加速 | 同样的事做得更快 | 生成脚本、样板代码、CRUD |
| L2 | 增强 | 同样的事做得更好 | 更完整测试、更严谨 review |
| L3 | 解锁 | 做以前做不到的事 | 系统性知识复用、跨模块架构分析、新人快速上手 |

Vibe Coding 在 L1 很有价值。

但真正需要 Agentic Engineering 的，是 L2 和 L3。

因为 L2 / L3 任务通常有这些特点：

- 约束空间复杂
- 上下文庞大
- 团队私有知识重要
- 正确性难验证
- 代码能跑不代表设计正确

所以 Agentic Engineering 的目标不是“让 AI 多写代码”，而是：

**在复杂约束下可靠地提升工程质量，并拓展工程师的能力边界。**

### 8. 三条第一性原理

Agentic Engineering 可以从三条基本事实推出。

#### 8.1 公理一：软件工程存在信息损耗

软件工程是意图转化链。

需求、设计、编码、测试、上线，每一步都可能损耗信息。

所以工程方法论的价值就在于：

- 显式化意图
- 增加校验点
- 保存关键决策
- 减少上下游误解

AI 时代这点更重要，因为 AI 会引入新的概率性偏差。

#### 8.2 公理二：LLM 是基于上下文的概率推理系统

LLM 有三个关键特征：

1. 输出由上下文决定
2. 输出是概率性的
3. 工作记忆有限且易失

这意味着：

- AI 不知道没给它的私有知识
- AI 输出不能天然保证正确
- 长任务里上下文会腐化、压缩、丢失
- 关键知识必须被结构化和持久化

#### 8.3 公理三：人类认知是稀缺资源

工程师的注意力、判断力和决策能力是有限的。

AI 可以增加产出速度，但不能无限增加人类审查能力。

所以最优策略不是最大化 AI 生成量，而是：

**优化工程师认知带宽的分配。**

让人少做机械劳动，多做判断、取舍、设计和验证。

### 9. 五个常见误区

#### 9.1 误区一：把代码喂给 AI，它就理解整个项目

代码只是项目知识的一部分。

AI 还需要：

- 架构决策
- 模块契约
- 历史原因
- 团队规范
- 业务约束

上下文的价值不取决于数量，而取决于信噪比和结构化程度。

#### 9.2 误区二：AI 不适合复杂系统

更准确地说：

**AI 在复杂系统中的可靠性，取决于关键上下文是否被有效传递。**

复杂系统不是不能用 AI，而是更需要：

- 结构化上下文
- 小任务拆分
- 中间校验
- 明确约束
- 可靠测试和审查

#### 9.3 误区三：AI 提效的核心是更快写代码

编码只是 SDLC 的一个环节。

如果需求和设计错了，AI 写得越快，返工越快。

AI 更大的价值是参与全链路：

- 需求澄清
- 设计权衡
- 编码实现
- 测试生成
- 审查排障
- 经验沉淀

#### 9.4 误区四：AI 生成的代码通过测试就可以提交

测试很重要，但不是充分条件。

完整验证应该覆盖：

| 层次 | 验证对象 | 验证方式 |
| --- | --- | --- |
| 意图层 | 需求是否完整 | Spec Review |
| 设计层 | 架构和约束是否合理 | Design Review |
| 实现层 | 代码质量和规范 | Code Review |
| 行为层 | 功能是否正确 | 自动化测试 |
| 系统层 | 性能、安全、集成行为 | 集成测试、性能测试、安全扫描 |

#### 9.5 误区五：AI 应该像人一样独立完成整个任务

长任务里，AI 的错误会累积，上下文会退化，人类最后一次性审查成本会很高。

更稳的模式是：

**小任务推进，频繁校验。**

AI 负责执行和辅助推理，工程师负责阶段性判断。

### 10. 最佳实践一：Context Engineering

AI 输出质量的上限由上下文决定。

但上下文窗口有限，超长上下文还会引发注意力稀释和信息丢失。

所以 Context Engineering 的核心是：

**在合适时机给模型最小但高信号的上下文。**

具体要做三件事。

#### 10.1 Spec-First

编码前先产出结构化 spec：

- 目标
- 背景
- 约束
- 非目标
- 验收标准
- 风险
- 待确认问题

Spec 的价值不是形式主义，而是把模糊意图变成持久上下文。

#### 10.2 Docs as Code

把 spec、设计文档、ADR、模块说明放进仓库，和代码一起版本化。

这样它们就能成为 AI 可检索、可引用、可演进的上下文。

#### 10.3 Progressive Disclosure

不要一开始把所有知识都塞给 AI。

应该按需展开：

- 先加载元信息
- 触发时加载对应 Skill
- 需要时再加载 references / scripts / assets

这和前面上下文工程讲过的原则一致：

**少而准，比多而乱更重要。**

### 11. 最佳实践二：基于知识不对称做人机分工

人和 AI 的知识边界不同。

可以用一个 2×2 模型判断协作方式：

|  | AI 知道 | AI 不知道 |
| --- | --- | --- |
| 人知道 | 开放区：可自动化 | 盲区：人要注入上下文 |
| 人不知道 | 潜能区：借助 AI 通用知识 | 未知区：共同探索 |

对应策略：

- 开放区：让 AI 快速执行
- 盲区：补 spec、rules、skills、docs
- 潜能区：让 AI 扩展人的知识边界
- 未知区：人类提出假设，AI 辅助验证

这比简单说“AI 能不能做”更有判断力。

关键问题不是 AI 强不强，而是：

**这个任务所需的知识，AI 是否看得见？**

### 12. 最佳实践三：AI 全链条参与

AI 不应该只在编码阶段出现。

更合理的 SDLC 协作方式是：

| 阶段 | AI 的角色 | 人的角色 |
| --- | --- | --- |
| 需求澄清 | 引导者，提出问题和边界 | 明确目标和取舍 |
| 方案设计 | 协作者，生成方案和权衡 | 做最终决策 |
| 编码测试 | 执行者，完成实现和测试 | 审查、校验、调整 |
| Review | 辅助审查者，找风险和遗漏 | 判断是否接受 |
| 排障复盘 | 线索整理者，提炼经验 | 确认根因和沉淀规则 |

AI 越早参与，越能保留意图上下文。

需求阶段产出的 spec，会成为设计上下文。  
设计阶段产出的文档，会成为编码上下文。  
编码阶段的错误和修正，会成为后续团队知识。

这就是上下文的正向循环。

### 13. 最佳实践四：小任务推进、多层验证

复杂任务不应该交给 AI 一口气做完。

更稳的是：

```text
拆分子任务
  ↓
构建聚焦上下文
  ↓
AI 执行
  ↓
人类 / 自动化校验
  ↓
通过后进入下一步
```

任务粒度取决于风险：

- 低风险样板代码：步子可以大一点
- 涉及并发、数据一致性、安全、生产配置：步子必须小

多层验证也很重要：

- spec 验证意图
- design review 验证方案
- code review 验证实现
- test 验证行为
- integration / performance / security 验证系统属性

Agentic Engineering 的一个核心原则是：

**AI 可以加速执行，但不能跳过验证。**

### 14. 最佳实践五：Knowledge as Code

团队共有知识应该像代码一样管理。

包括：

- 编码规范
- 架构约束
- 模块边界
- 测试规范
- 排障经验
- 常见错误
- 最佳实践

这些知识如果只存在于资深工程师脑中，AI 就无法稳定利用。

把它们沉淀成：

- Rules
- Skills
- Docs
- Checklists
- Playbooks

并放进仓库版本化管理，才能让 AI 在每次协作中都吃到团队经验。

这不是简单写文档，而是知识治理。

### 15. 最佳实践六：Error-Driven Context Refinement

AI 犯错后，不要只在当前对话里纠正它。

因为 LLM 的工作记忆是易失的。  
这次纠正不沉淀，下次仍然会犯。

更好的做法是建立反馈闭环：

```text
AI 犯错
  ↓
工程师纠正
  ↓
分析错误根因
  ↓
检查现有 Rules / Skills / Docs 是否缺失
  ↓
新增或更新知识
  ↓
下次自动加载，避免复发
```

这就是 Self-Refinement。

它可以有两种触发方式：

- 自动触发：AI 识别到自己被纠正，建议更新 Skill / Rule
- 手动触发：工程师在任务结束后让 AI 总结本轮错误并沉淀经验

核心思想是：

**把错误变成系统生长的养料。**

### 16. 基于 Skill 的 Agentic Engineering 框架

把上面的方法落地，一个自然载体就是 Skill。

Skill 通常是一个目录，包含：

- `SKILL.md`：结构化指令
- YAML metadata：名称、描述、触发条件
- `references/`：参考资料
- `scripts/`：可执行脚本
- `assets/`：静态资源或模板

它适合 Agentic Engineering，因为它满足几个要求：

- 按需加载，不拖垮上下文
- 可版本化，可 review
- 可组合，可复用
- 可持续更新
- 不绑定某个具体 Agent 平台

### 17. Skill 的三层加载机制

一个成熟 Skill 不是一次性全加载，而是渐进式披露。

| 层级 | 内容 | 加载时机 | Token 成本 |
| --- | --- | --- | --- |
| L1 Metadata | name、description、触发信息 | Agent 启动时 | 很低 |
| L2 Instructions | `SKILL.md` 主体指令 | Skill 被触发时 | 中等 |
| L3 Resources | references / scripts / assets | 被显式引用时 | 按需 |

这个结构很适合解决上下文窗口有限的问题。

项目可以安装很多 Skills，但只有当前任务触发的 Skill 才真正消耗上下文。

### 18. 一套模块化框架应该包含什么

一个 Agentic Engineering 框架可以分成六类模块。

| 模块 | 职责 |
| --- | --- |
| Workflow | SDLC 全链条流程：需求、设计、编码、测试、评审 |
| Best Practices | 通用工程知识：架构、编码、性能、分布式等 |
| Standards | 项目 / 团队私有规范：语言、模块、测试约定 |
| Docs | spec、设计文档、ADR、架构说明 |
| Troubleshooting | 编译错误、运行异常、线上告警排查 |
| Self-Refinement | 从错误中抽取经验，更新 Rules / Skills |

模块之间的关系是：

- Workflow 是主线
- Best Practices 和 Standards 是按需上下文
- Docs 是持久化意图和设计依据
- Troubleshooting 是问题排查入口
- Self-Refinement 是持续进化机制

### 19. Workflow 如何兼顾纪律和灵活性

工程纪律不等于所有任务都走重流程。

更合理的 Workflow 应该先判断任务复杂度。

```text
任务进入
  ↓
评估复杂度
  ├─ 简单任务：单文件、意图明确、风险低
  │   -> 轻量流程：加载 standards，直接修改，快速验证
  │
  └─ 复杂任务：多文件、跨模块、涉及设计决策
      -> 完整流程：spec -> design -> implementation -> tests -> review
```

这样既不会让小改动被流程拖死，也不会让复杂变更跳过关键设计。

流程严格程度应该和任务风险成正比。

### 20. Agentic Engineering 和 Harness Engineering 的关系

这两者很接近，但关注层不同。

| 维度 | Agentic Engineering | Harness Engineering |
| --- | --- | --- |
| 关注对象 | 软件工程流程中的人机协作 | Agent 系统运行时怎么可靠交付 |
| 核心问题 | AI 如何参与 SDLC 并保持工程质量 | 模型如何通过工具、状态、护栏完成任务 |
| 典型产物 | Skills、Workflow、Specs、Docs、Rules | Orchestrator、Tool Runtime、State Store、Guardrails |
| 目标 | 提升研发效能和质量 | 提升任务完成率和可控性 |

可以这么理解：

- Agentic Engineering 是“怎么和 AI 一起做软件工程”
- Harness Engineering 是“怎么把 AI Agent 做成可交付系统”

一个成熟团队最终两者都需要。

### 21. 三套站得住的 AI 开发模式

到 2026 年，比较能站住的 AI 开发模式大致有三套。  
它们不是互相替代关系，而是分别解决三个不同的问题。

| 模式 | 解决什么问题 | 人保留什么 | AI 负责什么 |
| --- | --- | --- | --- |
| Plan-then-Implement | 防止 AI 一上来就乱改 | 计划审批、关键取舍、最终 review | 探索代码、写计划、执行修改、跑验证 |
| Spec-driven | 防止多个 Agent 或多轮对话对“真相”理解不一致 | spec 的定义、版本化、验收标准 | 基于同一份 spec 设计、实现、测试 |
| Subagent fan-out | 防止单 Agent 长上下文退化、任务互相污染 | 任务拆分、review 合并、冲突裁决 | 多个独立 context 并行完成子任务 |

#### 21.1 Plan-then-Implement

这套模式可以理解成：

```text
Explore -> Plan -> Implement -> Verify -> Commit
```

核心动作是先让 AI 只读不写：

- 先探索现有代码
- 找到相关文件和约束
- 写出计划
- 人审计划
- 再让 AI 实现
- 最后跑测试或其他验证

这套模式的关键不是“计划写得多漂亮”，而是把 AI 的写代码冲动压住。  
先让它理解现场，再让它动手。

其中最高杠杆的一步是：

**给 AI 一种自己验证结果的方式。**

验证可以是：

- 单元测试
- 集成测试
- 一个 bash 命令检查输出
- lint / typecheck / build
- 截图比对
- API smoke test

没有验证时，你就是 AI 唯一的反馈通道。  
每个错误都要靠你肉眼发现，协作效率会迅速掉下来。

#### 21.2 Spec-driven

Spec-driven 的核心不是“多写文档”，而是：

**把 spec 当成代码来管。**

这意味着 spec 应该：

- 放在仓库里
- 跟代码一起版本化
- 能被 review
- 能被多个 Agent 读取
- 能作为实现和测试的共同入口

GitHub 的 `spec-kit` 就是这类实践的代表。  
它把开发流程拆成类似下面的阶段：

```text
Constitution -> Specify -> Plan -> Implement
```

这条路对中等以上规模的功能特别有效。  
因为功能一复杂，对话里的临时说明很容易丢；一份清晰的 `SPEC.md` 反而能成为所有 Agent 的共同真相来源。

Spec-driven 的重点不是“文档越长越好”，而是：

- 目标明确
- 非目标明确
- 约束明确
- 验收标准明确
- 关键上下文可追溯

#### 21.3 Subagent fan-out

Subagent fan-out 解决的是另一个问题：

**单个 Agent 的 context 会变脏、变长、变糊。**

长任务跑到后半段，经常会出现：

- 早期约束被挤出上下文
- 日志和错误信息污染推理
- 多个子任务互相干扰
- Agent 开始忘记最初的 plan

一种解法是把任务拆开：

```text
主 Agent：拆任务、分配、汇总、review
子 Agent A：只处理任务 A 的独立 context
子 Agent B：只处理任务 B 的独立 context
子 Agent C：只处理任务 C 的独立 context
```

这样做的好处是：

- 每个子 Agent 上下文更干净
- 子任务之间污染更少
- 可以并行推进
- 主 Agent 可以把精力放在合并和审查上

但它也有明显代价：

- 协调成本更高
- 合并冲突更多
- 责任归属更复杂
- review 不能省，反而更重要

所以多 Agent 并行不是默认选项。  
它适合边界清晰、可拆分、可独立验证的任务。

#### 21.4 三套模式放在一起怎么看

三套模式本质上都在做同一件事：

**把人类驾驶位从“盯着 AI 写每一行代码”，前移到“定义任务、组织上下文、设计验证、审查结果”。**

对应关系可以这样看：

| 问题 | 对应模式 |
| --- | --- |
| AI 没搞清现状就开写 | Plan-then-Implement |
| 多轮、多 Agent 对目标理解不一致 | Spec-driven |
| 单 Agent 长任务 context 退化 | Subagent fan-out |

这也解释了为什么真正稳的 AI 开发玩家，通常会死死攥住三件事：

```text
spec    -> 防止目标漂移
context -> 防止信息污染或缺失
review  -> 防止错误进入主线
```

### 22. 从今天开始怎么练

不用一上来搭完整框架。

可以先跑一个很小的真实闭环：

1. 找一个边界清晰的小需求
2. 先写一页 spec
3. 让 AI 基于 spec 修改代码
4. 人审 diff，不满意就让 AI 修
5. 补测试或运行验证
6. 总结这轮 AI 犯了什么错
7. 把可复用经验写成 Rule / Skill / Doc

练习重点不是“让 AI 一次写对”，而是：

- 你能不能定义好问题
- 你能不能给出足够上下文
- 你能不能拆成可审查的小步
- 你能不能把错误沉淀成系统知识

还有三个日常动作杠杆最高：

1. 给 AI 一种自己验证的方式。测试、截图比对、bash 命令检查输出都可以；能自验的任务，你主要看结果，不能自验的任务，你就会被迫逐行盯。
2. 把 context 当成第一资源管理。频繁清理长对话，把研究类任务卸载给独立 context 的 subagent，`CLAUDE.md` 或规则文件只放跨任务都需要的内容，越短越好。
3. 把 spec 文件化。一份清晰的 `SPEC.md`，加一份精简的项目规则文件，通常胜过每次对话里反复口头补充规则。

### 23. 一个可参考的开源框架

原文提到的方法论已经落地为一个开源项目：

[agentic-engineering-framework](https://github.com/davidYichengWei/agentic-engineering-framework)

它的定位是：

- 基于 Skill 的模块化 Agentic Engineering 框架
- 包含完整 SDLC Workflow
- 包含 Best Practices
- 包含 Self-Refinement 机制
- 支持项目定制指南

你可以把它当成一个参考实现来看：

- Skill 目录怎么组织
- Workflow 怎么拆阶段
- Best Practices 和 Standards 怎么分层
- Self-Refinement 怎么形成闭环

不一定要照搬，但它提供了一个很好的工程化样板。

除此之外，也可以参考两个更偏工具流的开源项目：

- [github/spec-kit](https://github.com/github/spec-kit)：偏 `spec-driven`，把规格文件做成跨 Agent 的执行入口。
- [obra/superpowers](https://github.com/obra/superpowers)：偏 `subagent-driven-development`，强调用多个独立 context 的 subagent 分摊任务。

注意：仓库 star 数、平台收录状态这些信息变化很快，学习笔记里不建议写死。  
真正值得学习的是它们背后的工程模式，而不是某一刻的热度数字。

### 24. 最后：工程师未来的位置

AI 会持续变强。

会变的是：

- 模型能力边界
- 工具形态
- 上下文窗口
- 自动化程度
- 代码生成质量

不变的是：

- 软件工程最终要解决真实问题
- 方向判断仍然重要
- 需求取舍仍然重要
- 系统理解仍然重要
- 人类认知仍然稀缺

软件工程师未来的重要能力会越来越偏向：

- 定义问题
- 拆解系统
- 编排 AI
- 设计验证
- 沉淀知识
- 判断价值

不要和 AI 拼写代码速度。  
更值得练的是：

**怎么让 AI 在工程约束里稳定产生价值。**

## 小结

Agentic Engineering 不是“更高级的 prompt 技巧”，也不是“让 AI 全自动接管开发”。

它是一套工程化协作范式：

- 用 spec 锚定意图
- 用 docs 和 skills 沉淀上下文
- 用小任务和多层验证控制风险
- 用 knowledge as code 打破知识孤岛
- 用 self-refinement 让错误转化为团队知识

Vibe Coding 的价值在于速度。  
Agentic Engineering 的价值在于：

**在速度提升的同时，保留理解、控制和质量。**

## 你现在应该能回答的问题

1. Vibe Coding 和 Agentic Engineering 的本质区别是什么？
2. 为什么 AI 的核心瓶颈会从“生成”转向“验证”？
3. Agentic Engineering 的三条第一性原理是什么？
4. 为什么复杂系统更需要 Context Engineering？
5. 为什么 AI 不应该只参与编码阶段？
6. 小任务推进和多层验证分别解决什么问题？
7. Knowledge as Code 和 Docs as Code 有什么区别？
8. Skill 为什么适合作为 Agentic Engineering 的落地载体？
9. Agentic Engineering 和 Harness Engineering 的区别是什么？
10. 为什么 spec-driven 和 subagent fan-out 解决的是不同问题？

## 参考

- Andrej Karpathy: [vibe coding 原推](https://x.com/karpathy/status/1886192184808149383)
- Simon Willison: [Not all AI-assisted programming is vibe coding](https://simonwillison.net/2025/Mar/19/vibe-coding/)
- Anthropic: [Claude Code Best Practices](https://www.anthropic.com/engineering/claude-code-best-practices)
- GitHub: [spec-kit](https://github.com/github/spec-kit)
- obra: [superpowers](https://github.com/obra/superpowers)
- Addy Osmani: [Agentic Engineering](https://addyosmani.com/blog/agentic-engineering/)
- GitHub: [Quantifying GitHub Copilot's impact on developer productivity and happiness](https://github.blog/news-insights/research/research-quantifying-github-copilots-impact-on-developer-productivity-and-happiness/)
- Anthropic: [How AI is transforming work at Anthropic](https://www.anthropic.com/research/how-ai-is-transforming-work-at-anthropic)
- Nelson F. Liu, Kevin Lin, John Hewitt, et al.: [Lost in the Middle: How Language Models Use Long Contexts](https://arxiv.org/abs/2307.03172)
- Anthropic: [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- David Yicheng Wei: [agentic-engineering-framework](https://github.com/davidYichengWei/agentic-engineering-framework)
