# AI 辅助开发 - 第 2 章：SDD 规格驱动开发：从需求到代码的具体落地

## 这一章在补什么

第 1 章讲了 SDD 是什么、面试怎么说，但停在了"先写 spec 再让 AI 实现"这个概念层。问题是：

- spec 到底写成什么样？一段话，还是一份结构化文档？
- specify / plan / tasks 这几个阶段，产物分别长什么样、谁来写、写到多细？
- 用什么工具落地？是手搓 prompt，还是有现成框架？
- 一个真实需求，端到端走一遍 SDD 是什么体感？

这一章就把这些"虚"的地方全部落到"实"。读完你应该能**今天就在自己项目里跑一遍 SDD**，而不只是会在面试里说它。

如果只记一句话：

**SDD 的落地，本质是把"需求 → spec → plan → tasks → 代码"这条链上的每一环都变成一份可审查、可版本化、可被 AI 读取的文件，让人审"意图和方案"，让 AI 干"翻译成代码"。**

---

## 1. 先纠正一个最常见的误解

很多人以为 SDD 就是"写需求文档"。不是。区别在于 spec 的**身份**：

| | 传统需求文档 | SDD 的 spec |
| --- | --- | --- |
| 读者 | 人 | 人 + AI |
| 写完之后 | 归档，和代码逐渐脱节 | 是后续 plan/tasks/代码/测试的 **source of truth** |
| 更新 | 经常不更新 | 改需求先改 spec，再让 AI 重新生成下游 |
| 形态 | Word / Confluence | 仓库里的 markdown，进 git，走 review |
| 颗粒度 | 偏业务，常缺技术约束 | 显式写非目标、接口契约、验收标准、边界 |

一句话：**传统文档是"给人看的说明书"，SDD 的 spec 是"驱动后续一切的控制文件"。** 它和代码住在一起、一起进 git、一起被 review。这是 SDD 区别于"认真写文档"的根本点。

---

## 2. SDD 的完整生命周期：四份产物

目前最成型的 SDD 落地范式来自 GitHub 的 **Spec Kit**（开源工具包），它把流程固化成四份递进的产物。即使你不用 Spec Kit，这套分层也值得照搬：

```
constitution（宪法/项目原则）   ← 一次性，整个项目共享
        │
   ┌────┴──── 每个需求(feature)循环 ────────┐
   │                                          │
specify（spec）  →  plan（技术方案）  →  tasks（任务清单）  →  implement（实现）
  做什么/为什么      怎么做/用什么栈        拆成可执行小步        AI 逐条落代码
   人主导            人审 AI 起草          AI 拆 人审            AI 干 人审 diff
```

四份产物的分工，对应第 1 章那张表，但这里给出**每份的具体定位**：

1. **constitution（项目宪法）**：整个项目的不可违背原则。技术栈、架构边界、代码规范、测试要求、安全红线。写一次，所有 feature 共享。它是 AI 的"长期记忆约束"。
2. **spec（规格）**：单个需求**做什么、为什么**。只写意图和验收，**不写技术实现**。这是人投入最多、最该 review 的一份。
3. **plan（技术方案）**：这个需求**怎么做**。用什么模块、什么数据结构、什么接口、数据怎么流、有什么风险。AI 起草，人审。
4. **tasks（任务清单）**：把 plan 拆成一条条**可独立执行、可验证**的小任务。AI 拆，人确认顺序和边界。
5. **implement（实现）**：AI 按 tasks 逐条写代码、跑测试，人审每步 diff。

关键纪律：**这四份是有顺序、有依赖的，不能跳。** 跳过 spec 直接 plan，就退化回"凭感觉让 AI 改代码"；跳过 plan 直接 implement，AI 会自己脑补架构（第 1 章说的"架构漂移"）。

---

## 3. 每份产物到底长什么样（给可抄的模板 + 填好的例子）

光说结构没用，直接上模板和真实例子。下面用一个贯穿的需求：**给结算系统加一个"结算单自动生成"功能**（衔接你 DDD track 里的结算中心场景）。

### 3.1 constitution（项目宪法）

模板（放在 `/.specify/memory/constitution.md` 或项目根的 `CONSTITUTION.md`）：

```markdown
# 项目宪法

## 技术栈
- 语言/框架：Java 17 + Spring Boot 3
- 持久化：MySQL 8 + MyBatis，禁止在领域层出现 SQL
- 消息：RocketMQ

## 架构原则
- 严格分层：interface / application / domain / infrastructure
- 领域层不依赖任何外部框架（依赖倒置）
- 跨上下文调用必须经防腐层，不得直接引用对方领域对象

## 编码规范
- 禁止贫血模型：业务规则进聚合，应用服务只编排
- 仓储以聚合为单位，禁止字段级 update

## 测试要求
- 领域层核心规则必须有单测，覆盖失败路径
- 测试 oracle 必须来自 spec 验收标准或既有行为，不得反推实现

## 安全红线
- 禁止在代码/日志中出现 secret、token
- 涉及资金的写操作必须幂等
```

要点：**constitution 写的是"不管做什么 feature 都要遵守的约束"**。它把你 DDD track 里的那些原则（不贫血、依赖倒置、防腐层）固化成 AI 每次都会读到的硬规则。这是防"架构漂移"最有效的一招。

### 3.2 spec（规格）—— 只写"做什么"，不写"怎么做"

模板（放在 `specs/001-auto-settlement/spec.md`）：

```markdown
# Spec：结算单自动生成

## 背景
当前结算单靠运营手工触发生成，月底高峰易遗漏、易出错。

## 目标
- 订单履约完成后，系统自动为该笔订单生成对应结算单
- 结算单生成后进入"待确认"状态，等待运营确认

## 非目标（这次明确不做）
- 不做结算单的确认/出款流程（已有，不动）
- 不做跨币种结算
- 不改动订单上下文的任何对外接口

## 用户故事
- 作为财务，订单完成后我希望结算单被自动创建，这样我不用手工触发

## 验收标准（可测）
- AC1：订单状态变为"已完成"后，1 分钟内生成一张结算单
- AC2：结算单金额 = 订单实付金额 - 平台佣金，佣金按商家费率计算
- AC3：同一订单重复触发，只生成一张结算单（幂等）
- AC4：商家费率缺失时，不生成结算单，记录告警，不抛异常中断主流程

## 约束
- 兼容性：不得修改订单上下文已有对外接口
- 一致性：结算单生成失败不能影响订单状态
- 性能：月底峰值约 50万单/天

## 风险点（需人工确认）
- 佣金计算规则是否已有权威来源？
- "订单完成"事件是否已存在，还是要新增？
```

要点：

- **spec 里没有一行说"用什么类、什么表、什么设计模式"** —— 那是 plan 的事。spec 越是克制不谈实现，越能逼出真正的需求共识。
- **非目标和验收标准是 spec 的灵魂**。第 1 章说过"把最容易误解的约束提前显式化"，落地就体现在这两节。AC1-AC4 每条都能写成一个测试。
- **风险点那一节**直接对应第 1 章说的"让 AI 在不确定时提问，而不是自行决定"——把不确定显式列出来，强制人来拍板。

### 3.3 plan（技术方案）—— AI 起草，人审

模板（`specs/001-auto-settlement/plan.md`）：

```markdown
# Plan：结算单自动生成

## 方案概述
监听订单上下文的 OrderCompleted 领域事件，在结算上下文里消费，
调用结算领域服务计算金额，生成 SettlementBill 聚合并落库。

## 涉及模块/上下文
- 订单上下文：已有 OrderCompleted 事件（确认无需改动其对外接口）
- 结算上下文（本次主要改动）

## 关键设计
- 聚合：SettlementBill（聚合根），含 Money（值对象）、BillingCycle（值对象）
- 领域服务：CommissionCalculator（佣金计算，跨"订单金额+商家费率"）
- 应用服务：SettlementAppService.onOrderCompleted(event)
- 仓储：SettlementBillRepository（以聚合为单位）
- 幂等：以 orderId 做唯一约束 + 消费前查重（对应 AC3）

## 数据流
OrderCompleted(MQ) → 结算 MQ 消费者（幂等校验）
  → SettlementAppService → CommissionCalculator 算金额
  → SettlementBill.create(...) → repository.save() → 状态"待确认"

## 数据结构
- 新增表 settlement_bill：id, order_id(唯一), merchant_id, amount, commission, status, version, created_at
- version 字段用于乐观锁

## 失败与边界处理
- 费率缺失：不生成，发告警事件，ack 消息（对应 AC4）
- 重复消息：唯一约束兜底 + 消费前查重（对应 AC3）
- 生成失败：不回查订单、不影响订单状态（对应约束"一致性"）

## 风险与回滚
- 灰度：先对 1% 商家开启自动生成
- 回滚：关开关即可退回手工触发
```

要点：

- plan 里**每个设计决策尽量回指 spec 的某条 AC 或约束**（你看上面频繁出现"对应 AC3""对应约束"）。这让 review plan 的人能逐条核对"方案是否覆盖了 spec"。
- 这一份是 AI 最该帮你起草、但你最该认真审的。**plan 错了，AI 会非常稳定地朝错误方向实现**（第 1 章说的 SDD 边界）。

### 3.4 tasks（任务清单）—— 拆成可独立验证的小步

模板（`specs/001-auto-settlement/tasks.md`）：

```markdown
# Tasks：结算单自动生成

- [ ] T1 建表 settlement_bill + flyway 迁移脚本（order_id 唯一索引）
- [ ] T2 领域层：SettlementBill 聚合根 + Money/BillingCycle 值对象 + create 工厂方法
      验收：单测覆盖"金额=实付-佣金""非法金额拒绝"
- [ ] T3 领域层：CommissionCalculator 领域服务
      验收：单测覆盖正常费率、费率缺失抛领域异常
- [ ] T4 基础设施：SettlementBillRepository 实现（MyBatis）
- [ ] T5 应用层：SettlementAppService.onOrderCompleted（编排+事务+幂等查重）
      验收：单测覆盖 AC3 幂等、AC4 费率缺失不中断
- [ ] T6 接入层：OrderCompleted MQ 消费者（幂等、异常 ack 策略）
- [ ] T7 灰度开关 + 告警事件接入
- [ ] T8 集成测试：模拟 OrderCompleted → 验证生成结算单（覆盖 AC1/AC2）
```

要点：

- **每条 task 尽量"一个 PR 能完成、有明确验收"**。注意每条带了验收，且回指 AC。
- 顺序有讲究：**先领域层（T2/T3）再基础设施（T4）再应用/接入（T5/T6）**，符合你 DDD track 的依赖方向——核心在内、技术在外。
- 这份是 AI 拆、人确认。AI 经常会把 task 拆得太粗或顺序乱，人要校正。

---

## 4. 用什么工具落地：三条路线

模板有了，怎么真正驱动 AI 走这套流程？三条路线，从重到轻：

### 4.1 路线 A：GitHub Spec Kit（最成型）

Spec Kit 是开源 CLI（`specify` 命令），它做两件事：

1. **初始化目录骨架**：`specify init` 生成 `.specify/`（放 constitution、模板）和 `specs/` 目录。
2. **注入一组 slash command** 到你的 AI 工具（Claude Code / Cursor / Copilot 等）：

```
/constitution   → 生成/更新项目宪法
/specify        → 把一句需求扩写成结构化 spec（AI 起草，会反问澄清）
/plan           → 基于 spec + constitution 生成技术方案
/tasks          → 把 plan 拆成任务清单
/implement      → 按 tasks 逐条实现
```

体感是：你在 Claude Code 里敲 `/specify 给结算系统加结算单自动生成`，它会产出 3.2 那样的 spec 文件并反问你风险点；你审完改完，再 `/plan`，再 `/tasks`，再 `/implement`。**每一步都落成 git 里的文件，每一步你都能 review。**

适合：想要规范、团队协作、希望流程可复制的场景。

### 4.2 路线 B：Kiro / 内置 spec 模式的 IDE

Amazon 的 Kiro（以及越来越多 IDE）把 SDD 内置成"spec 模式"：你描述需求，它自动生成 `requirements.md`（含 EARS 格式的验收）、`design.md`、`tasks.md` 三件套，并能勾选 task 逐个执行。本质和 Spec Kit 一样，只是包装成了 IDE 原生体验。

适合：想开箱即用、不想自己搭骨架。

### 4.3 路线 C：手搓（任何 AI 工具都能做）

不装任何框架也能做 SDD，核心就是**纪律**。在 Claude Code 里：

1. 让 AI 把需求写成 `specs/xxx/spec.md`（把 3.2 的模板贴给它当格式）。
2. 你审 spec，改非目标和 AC。
3. 让 AI 读 spec + 你的 `CLAUDE.md`（充当 constitution）生成 `plan.md`。
4. 审 plan，让 AI 拆 `tasks.md`。
5. 让 AI 按 tasks 逐条做，每条做完跑测试、你审 diff。

**`CLAUDE.md` 就是你的轻量 constitution**——你 DDD track 里那些原则（不贫血、依赖倒置）写进去，AI 每次都会读。

适合：先体验 SDD 思想、不想引入新工具。**建议你从这条路线起步**，跑顺了再考虑 A/B。

---

## 5. 端到端走一遍（真实体感）

把上面串起来，模拟一次完整的 SDD 开发，让你感受每一步人和 AI 的分工：

```
① 你：/specify 订单完成后自动生成结算单
   AI：产出 spec.md 草稿，并反问——
       "佣金规则有权威来源吗？OrderCompleted 事件已存在吗？"
② 你：回答这两个问题，把 AC4（费率缺失不中断）补进 spec，确认非目标
   —— 这一步是人投入最大的，也是 SDD 价值最高的：需求在写代码前就对齐了

③ 你：/plan
   AI：读 spec + constitution，产出 plan.md
④ 你：审 plan，发现 AI 漏了"灰度回滚"，让它补上；确认幂等用 orderId 唯一约束

⑤ 你：/tasks
   AI：拆出 T1-T8
⑥ 你：调整顺序（确保领域层先于接入层），确认每条 task 边界

⑦ 你：/implement T2（先做领域层聚合）
   AI：写 SettlementBill + 单测，跑测试通过
⑧ 你：审 diff——重点看"金额规则是否真在聚合里、有没有贫血"
   ... 逐条 T3、T4... 直到 T8 集成测试

⑨ 合并前：走和人工代码一样的 review + CI + 安全扫描
```

注意几个关键分工：

- **② 是人的主场**（定义问题），**⑦ 是 AI 的主场**（翻译成代码），中间的 ④⑥⑧ 是人的质量闸门。
- 你不是在"写代码"，而是在**定义、审查、把关**——这正是第 1 章说的"工程师工作重心前移"的具体样子。
- 需求变了怎么办？**回到 spec 改，再让下游 plan/tasks 重新生成**。spec 是 source of truth，不是改完代码再补文档。

---

## 6. SDD 怎么和 DDD、TDD 咬合（你已经会的东西能复用）

SDD 不是孤立的，它和你已经学的方法天然互补：

- **SDD × DDD**：spec 的"用户故事/验收"对应 DDD 的需求层；plan 里的"聚合/领域服务/上下文"直接套你 DDD track 的战术设计；constitution 把 DDD 原则固化成 AI 硬约束。**SDD 提供流程，DDD 提供建模内容**——上面例子里 plan 全程在用聚合、值对象、领域服务、防腐层。
- **SDD × TDD**：spec 的每条 AC 就是一个待写的测试。落地时可以让 AI 在 implement 阶段**先把 AC 翻译成失败测试，再写实现**（task 里的"验收"那行就是测试目标）。这样测试的 oracle 来自 spec，而不是反推实现——正好解决第 1 章说的"测试虚高"。

一句话：**SDD 是骨架，DDD 填建模血肉，TDD 守验证纪律。** 三者叠起来，AI 才是在"受控工程"里干活。

---

## 7. 落地时真正会踩的坑（以及对策）

第 1 章列了 SDD 的"边界"，这里给**具体落地阶段**的坑和对策：

| 坑 | 现象 | 对策 |
| --- | --- | --- |
| spec 写成实现 | spec 里出现"用 Redis 缓存""加个 Service 类" | 强制 spec 只写做什么/为什么，技术决策留给 plan |
| AC 不可测 | "性能要好""体验流畅" | 每条 AC 必须能写成一个测试，写不出来就是没想清 |
| 一把梭跳步 | 嫌麻烦直接 /implement | 至少 spec + tasks 不能省；plan 在简单需求里可压缩但别跳 spec |
| spec 和代码脱节 | 改了代码没回改 spec | 把 spec 纳入 PR review，改需求先改 spec（CI 可加检查） |
| plan 太泛 | "实现一个结算模块" | plan 要细到"哪个聚合、哪张表、哪条数据流回指哪条 AC" |
| 大 feature 不拆 | 一个 spec 包揽整个子系统 | 一个 spec 对应一个可独立验收的 feature，大的拆多个 spec |
| constitution 缺失 | 每个 feature AI 风格都不一样 | 先写 constitution / CLAUDE.md，把架构和规范固化 |

最核心的一条：**SDD 的失败几乎都来自"嫌写 spec 麻烦而跳步"**。但跳步省下的时间，会在返工时加倍还回来——这正是 SDD 想解决的问题本身。

---

## 8. 团队级落地：让 spec 真正成为 source of truth

个人用 SDD 是纪律问题，团队用 SDD 是机制问题。要让 spec 不沦为摆设：

1. **spec 进 git，和代码同仓**：`specs/` 目录跟随 feature 分支，PR 里同时包含 spec 变更和代码变更。
2. **spec 先 review**：在写代码前，spec 单独走一轮 review（相当于把需求评审显式化、前置）。这能挡住第 1 章说的"需求评审问题后移到代码阶段"。
3. **改需求先改 spec**：建立规矩——任何需求变更，先改 spec，再让 AI 重新生成 plan/tasks/代码。可以用 CI 检查"代码大改但 spec 没动"作为提醒。
4. **constitution 团队共建**：架构原则、安全红线由团队维护，所有人的 AI 都读同一份，保证产出一致。
5. **spec 复用为 skill**：常见 feature 类型（如"新增一个 XX 事件消费者"）可以把 spec/plan 模板沉淀成 skill（衔接第 1 章的 Skills），下次直接套。

这一步做到位，SDD 才从"个人提效技巧"升级成第 1 章说的"团队工程方法论"——也是面试里最有含金量的那一层。

---

## 9. 可直接抄走的落地清单

今天就想试，照这个最小路径走：

```
1. 在项目根写一份 CLAUDE.md（或 constitution.md），
   把架构原则、技术栈、测试要求、安全红线列清楚。
2. 拿一个边界清晰的小需求，让 AI 按第 3.2 模板写 spec.md。
3. 自己审 spec：重点改"非目标"和"验收标准"，把模糊点写成可测 AC。
4. 让 AI 读 spec + CLAUDE.md 生成 plan.md，审"方案是否覆盖每条 AC"。
5. 让 AI 拆 tasks.md，确认每条可独立验收、顺序符合依赖方向。
6. 逐条 implement：每条先写测试（oracle 来自 AC）、再写实现、审 diff。
7. 合并前走正常 review + CI + 安全扫描。
8. 跑顺后，把这套目录和模板固化下来，下个需求复用。
```

背后还是那句话：

**SDD 落地的全部努力，就是把"意图"和"实现"分开——人对意图负责（spec/plan 的 review），AI 对翻译负责（implement），中间用可审查的文件衔接。** 把这条做扎实，AI 才是在工程里帮你，而不是在帮你制造更快的返工。

---

## 10. 本章总结

```
constitution  固化不变的项目原则（写一次，AI 每次都读）
   → spec      只写做什么/为什么，非目标 + 可测 AC 是灵魂（人主导）
   → plan      怎么做，每个决策回指 AC（AI 起草，人审）
   → tasks     拆成可独立验收的小步（AI 拆，人确认）
   → implement 逐条落代码，先测试后实现，审每步 diff（AI 干，人把关）
```

工具上：**从手搓（CLAUDE.md + 模板）起步，跑顺再上 Spec Kit / Kiro**。
方法上：**SDD 给流程，DDD 给建模，TDD 给验证**，三者叠加。
团队上：**spec 进 git、先 review、改需求先改 spec、constitution 共建**。

一句话收束：

**SDD 不是多写文档，而是把开发的控制权从"AI 自由发挥"夺回到"人定义的、可审查的规格"手里——这才是它在 AI 时代真正的落地价值。**

---

## 参考资料

- GitHub Spec Kit（开源工具与方法）: <https://github.com/github/spec-kit>
- Spec-Driven Development with AI（GitHub 博客）: <https://github.blog/ai-and-ml/generative-ai/spec-driven-development-with-ai-get-started-with-a-new-open-source-toolkit/>
- AWS Kiro（spec 模式 IDE）: <https://kiro.dev/>
- 上一章：`01_AI如何帮助开发：SDD、Skills与生产落地问题.md`
