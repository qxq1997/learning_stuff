# Claude Code 源码学习 · 第 03 课:Agent 主循环

## 学习目标(本节结束后你能做到什么)

- 能徒手写出 Agent Loop 的**伪代码骨架**(20 行以内),并解释每一行存在的理由。
- 能回答"对话循环和工具循环是不是同一个循环"——并指出问错这个问题的人,在心智模型上漏掉了什么。
- 理解 Anthropic Messages API 的几个 `stop_reason`(`end_turn` / `tool_use` / `max_tokens` / `stop_sequence`)分别意味着什么,以及循环要为它们各自做什么。
- 知道**一条 assistant 消息里出现多个 `tool_use` 块**这个常被忽略的事实,以及由此产生的并发模型。
- 能把 Claude Code 的 Agent Loop 与 LangGraph 状态机、Plan-Execute 等其他架构做对比,说出取舍。
- 能在你的 EMF DAG Scheduler 旁边画出一个**并行**的 Agent Loop,作为异常分支的执行器。

这一节是整门课的"心脏"。后面所有讲工具、权限、Hooks、Subagent 的内容,都是在装饰这个循环。

---

## 内容讲解

### 一、把"循环"放到正中间

回顾第 02 课的全景图,九层架构里只有第 ④ 层 Agent Loop 拥有"循环"概念。这一课我们就钻进这个盒子,把它撕开来看。

先回答课首的核心问题:

> **"对话循环"和"工具循环"是同一件事吗?**

很多人脑中默认有两个循环:
- 一个是"对话循环"——用户问、模型答、用户再问。
- 另一个是"工具循环"——模型调工具、看结果、再调工具。

这种心智模型**是错的**。Claude Code 内部**只有一个循环**,它的循环体长这样:

```
while 还需要继续:
    调一次模型,拿到一条 assistant 消息
    if 这条消息没要求调工具:
        退出循环                        ← 把控制权还给用户(看似"对话循环"在动)
    else:
        派发工具、拿到 tool_result
        把结果作为下一轮的输入            ← 看似"工具循环"在动
```

也就是说,**所谓"对话循环"只是这个循环的"出口"出现在了 user 输入这里;所谓"工具循环"只是出口暂时还不出现而已。** 它们是同一个 while 的两种相位,不是两个独立的循环。

这个视角调对了之后,后面所有事情都清晰了:

- "用户的下一条输入"和"工具的 tool_result"在循环看来是**同一种东西**——都是"喂给下一次 API 调用的下一条消息"。区别只在于一个来自人,一个来自工具执行器。
- 系统不需要维护"我现在处于对话模式还是工具模式"这种状态——**根本没有这种状态**。
- "中断"也是一个统一概念:不管模型在打字、还是在调工具,中断的语义都一样——把当前未完成的 assistant 消息回滚或截断,把控制权还给用户。

记住这一句话足以撑起整堂课:

> **Agent Loop 不区分"对话"和"工具调用",它只区分"还要不要继续"。**

### 二、伪代码骨架:20 行写完一个 Agent

把 Claude Code 的核心循环抽象到最干净,大概是这样(为了清晰我把异常处理、流式、Hooks 全部省略):

```python
def agent_loop(messages, system_prompt, tools, permission, persist):
    while True:
        # ① 调一次模型
        assistant_msg = api.create_message(
            system=system_prompt,
            messages=messages,
            tools=tools,            # 工具的 JSON Schema 清单
            stream=True,
        )
        messages.append(assistant_msg)
        persist(assistant_msg)

        # ② 根据 stop_reason 决定下一步
        if assistant_msg.stop_reason == "end_turn":
            return                                    # 模型表示自己说完了
        if assistant_msg.stop_reason == "max_tokens":
            handle_truncation(assistant_msg)          # 极少触发,见下文
            return
        if assistant_msg.stop_reason == "stop_sequence":
            return                                    # 命中停止序列(很罕见)
        # 走到这里只剩 stop_reason == "tool_use"

        # ③ 取出所有 tool_use 块(注意:可能不止一个)
        tool_uses = [b for b in assistant_msg.content if b.type == "tool_use"]

        # ④ 并发派发,但同步收齐结果
        tool_results = dispatch_concurrently(
            tool_uses,
            permission_check=permission,
        )

        # ⑤ 把结果作为一条 user 消息追加(API 约定,见下文)
        messages.append({"role": "user", "content": tool_results})
        persist(messages[-1])
        # ⑥ 回到 while 头,再调一次模型
```

读这段伪代码,有四件事值得在脑子里画下划线:

**1. `messages` 这个数组就是整个 Agent 的"全部记忆"。** 它从一开始就是 ground truth——只要你重新喂同一份 messages 给同样的模型和工具,你就会得到几乎一样的行为。这是 Agent 设计上一个非常划算的不变量。

**2. 出口只有两个:`end_turn` 走退、`tool_use` 走继续。** 其他 `stop_reason` 都是边角异常。这意味着循环的复杂度被压在最低——一个二选一分支,而不是状态机。

**3. tool_result 是放在 `user` 消息里的,不是 `assistant` 消息里。** 这是 Anthropic Messages API 的硬约定:工具调用请求出现在 assistant 消息(`tool_use` 块),工具执行结果出现在 user 消息(`tool_result` 块)。第一次写 Claude 客户端的人有 9 个会在这里栽。**模型是不被允许给自己打 tool_result 的**——它只能"提需求",结果必须从外部"喂回来",哪怕外部就是你的本地 Node 进程。这条约定其实是对"模型无副作用"原则在 API 层的强制执行。

**4. 一条 assistant 消息里可以同时出现多个 `tool_use` 块。** 这就是后面要讲的并发派发——很多人脑子里以为 LLM 一次只调一个工具,这是 ChatGPT 早期 function call 形态留下的误解。

### 三、状态机视角:其实只有一张图

把循环画成状态图,你会发现它真的很小:

```
                        ┌──────────────────────┐
                        │   等待 user 输入       │  ← 起点 / 终点
                        └──────────┬───────────┘
                                   │ user 敲回车
                                   ▼
                        ┌──────────────────────┐
                        │   调 API (流式)       │
                        └──────────┬───────────┘
                                   │ 流结束
                                   ▼
                        ┌──────────────────────┐
                        │  检查 stop_reason     │
                        └─┬─────────┬───────┬──┘
                          │         │       │
                  end_turn│ tool_use│       │max_tokens
                          │         │       │
                          ▼         ▼       ▼
                       (回到等   ┌────────┐ (截断/告警/
                        user)    │派工具   │  退出)
                                 └───┬────┘
                                     │ 全部 tool_result 收齐
                                     ▼
                              (回到"调 API")
```

这就是全部。**没有"plan 状态"、"reflect 状态"、"act 状态"。** 这是 Claude Code 与 LangGraph 这类框架在哲学上的根本不同——后者鼓励你显式地把每个阶段建模成一个图节点,前者反过来,把"阶段"全部塞进模型自身的注意力里,外部循环只做最简化的派发。

后面 Subagent (第 11 课)会让你看到:**Subagent 不过是这张图被嵌套了一层**——主 Agent 在某次 `tool_use` 里调用了 `Task` 工具,而 `Task` 工具的 handler 就是再起一份这张图。

### 四、`stop_reason` 的细节:每一种意味着什么

Anthropic Messages API 的 `stop_reason` 有 4 种,Agent Loop 要为每种设计行为:

| stop_reason | 意味着 | 循环该做什么 |
| --- | --- | --- |
| `end_turn` | 模型主动收尾,认为本轮任务/对话已完整 | 退出循环,把控制权还给用户 |
| `tool_use` | 模型在 content 里产生了至少一个 `tool_use` 块,等外部喂结果 | 派发工具 → 收集 tool_result → 继续循环 |
| `max_tokens` | 模型生成达到上限被强制截断 | 棘手,见下文 |
| `stop_sequence` | 命中调用方传入的 stop_sequences | 一般等同 end_turn,但要把命中的序列记下来 |

最棘手的是 `max_tokens`。它意味着模型被"中途斩断"。如果它正在写文本回答,问题不大,告诉用户输出被截断即可。**但如果它正写到一半的 `tool_use` 块**——参数 JSON 还没闭合——这是危险信号:你既不能把这条工具调用真的派发(参数不完整),又不能轻易丢弃(等于模型白干了一轮)。Claude Code 的处理通常是检测到不完整 tool_use 后**给一个明确的错误信号回模型**,让模型自己重发。这个细节会在第 05 课流式响应里再细看,因为它本质上是流式协议的边界条件。

### 五、并发派发:同一条消息里的多个 tool_use

实际跑过一些 Claude Code 任务你会发现,经常出现这种 assistant 消息:

```
"我打算并行做三件事:读 a.ts、读 b.ts、跑一下 git status。"
[tool_use: Read(a.ts)]
[tool_use: Read(b.ts)]
[tool_use: Bash("git status")]
```

这三个 `tool_use` 块在**同一条** assistant 消息里。它们逻辑上是并列的——模型期望循环把这三个一起执行,然后**一次性把三个 `tool_result` 喂回来**。

这就引出 Agent Loop 中一个经常被误读的并发模型:

```
派发阶段:               并发(可以三个一起跑)
回到 API 之前:           同步(必须三个结果都收齐)
```

也就是**fork-join 模式**:循环每次进入"派工具"分支时,会 fork 出 N 个工具执行任务,等它们全部 join 完才能继续。这对应 ToolDispatcher 的实现:它收集所有 `tool_use`,然后用 `Promise.all` 等价物等齐。

这个设计有几个有意思的副作用:

- **慢工具会卡住整轮**。如果三个工具里有一个是 60 秒的 Bash,整个循环要等 60 秒才能继续。这是工具超时设计的根本起点。
- **工具之间没有内部依赖**。模型既然把三个并列在一条消息里,就意味着它认为这三个互不依赖。如果模型需要"先 A 再用 A 的结果调 B",它会分两轮:第一轮只发 A,等结果回来,第二轮再发 B。
- **可以有界并发**。Claude Code 可以给"同时执行的工具数"设上限(避免一次开 50 个 Bash 子进程),这个上限设在 Tool Dispatcher 层。

后端工程师对这个并发模型不会陌生——它和 Java 里 `CompletableFuture.allOf(...)` 或 Go 里 `sync.WaitGroup` 是同一个范式。区别只在于"任务是谁产生的"——这里是模型在每一轮 inference 里现场决定的。

### 六、中断:流被打断时,循环怎么办

终端里你按下 Esc 或 Ctrl-C,会发生什么?这是 Agent Loop 一个常被忽视的健壮性维度。

要分两种情况:

**情况 A:中断发生在"调 API"阶段(SSE 流还在传)**
- 取消正在进行的 fetch / SSE 解析。
- 把已经收到一半的 assistant 消息**丢弃**(不写进 messages,不写进 transcript)。
- 控制权回到 ① Input 层。
- 用户可以接着发新输入,系统状态干净。

**情况 B:中断发生在"派工具"阶段(某个工具正在跑)**
- 给所有进行中的工具一个取消信号(对 Bash 子进程来说就是 SIGTERM/SIGKILL)。
- 已经返回的 tool_result 可以保留也可以丢弃,Claude Code 这里的工程选择是**写一条"工具被用户中断"的 tool_result 进 messages**,这样后续 resume 时模型知道前面发生了什么。
- 然后退出循环,等用户下一句。

注意 B 的精妙:它**没有把消息丢弃**。中断不是"清空状态",是"把异常显式地编码进对话历史"。这个选择源于一个朴素的原则——**让模型看见发生了什么,而不是替它隐藏**。如果你把工具中断悄悄抹掉,模型重新看到的世界就是"我说要调工具,但什么都没发生",它会困惑。

### 七、循环的边界:有没有"最大轮数"?

理论上,Agent Loop 是无限的——只要模型一直产 `tool_use`,它就一直转。这显然不安全。Claude Code 的实际边界来自几个地方,**没有一个是显式的 max_iterations 计数器**:

1. **上下文窗口压力**——每多转一轮,messages 就更长,迟早顶到 200k 上限。这个由第 07 课的 auto-compact 处理。
2. **预算/成本**——每一轮都是一次 API 调用 + tokens 消耗,用户在 TUI 上一直能看到累计代价,可以随时中断。
3. **模型自身收敛性**——这是最微妙的一条:Anthropic 在训练时就把"什么时候该结束"塑造进了模型行为,大多数任务模型会主动 end_turn。
4. **Hooks 干预**——用户可以挂一个 `Stop` hook 在循环出口,某些条件下强制阻止退出或继续(第 12 课)。

**最值得记的是第 3 条**:Claude Code 没有外部"最多 N 轮"硬限制,它信任模型的自我收敛。这是和 AutoGPT 早期版本一个根本不同——AutoGPT 必须设最大轮数,因为它的"agent"是 prompt 拼出来的,模型本身没被训练成"会停"。Claude 系列模型则**专门为 Agent 形态训过收敛性**,所以可以省掉这个外部硬约束。

这件事反过来也告诉你:**Agent 系统的收敛性不是循环代码写出来的,是训练出来的。** 你抄 cli.js 的循环结构很容易,但如果你后面接的是一个没被训练成"会停"的模型,你立刻就会需要那个 max_iterations。

### 八、与其他架构的对比

| 架构 | 决策机制 | 显式状态 | 适用场景 |
| --- | --- | --- | --- |
| **Single-turn Function Call**(老式 GPT plugin) | 模型一次性返回工具调用,框架执行后再返回一段文本 | 无循环,单跳 | 一锤子买卖式工具(如查天气)|
| **Plan-then-Execute** | 先让 LLM 写 plan,再按 plan 顺序执行 | 显式两阶段 | 流程相对稳定的批处理 |
| **LangGraph 状态机** | 把每种"状态"建模成 graph 节点,边由代码决定 | 显式有限状态机 | 想要"白盒可视化"的复杂业务流 |
| **Claude Code 主循环** | 每轮模型自己决定:`end_turn` 或 `tool_use` | 几乎没有显式状态 | 长尾、未知、需要灵活探索的开发任务 |

后端思维里很容易倾向于 LangGraph 风格——"画图、定节点、定边、可观测"——这套思路在 EMF 那种业务场景里完全正确。但在编程助手这种**任务空间无穷且高度任务相关**的场景里,你提前画不出有意义的图。Claude Code 选择"几乎不画图,一切交给模型"——这是对场景特性的精准回应,不是设计偷懒。

### 九、与 EMF 的对照(第二轮)

第 02 课我们说过,EMF 的 DAG Scheduler 也有一个 while 循环。我们这次把两个 while 循环并排放到一起对比:

```
EMF DAG Scheduler:                Claude Code Agent Loop:

while 还有未完成节点:              while True:
    任务 = 拓扑.下一批可执行()       msg = 调一次模型()
    并发执行(任务)                  if msg.无 tool_use:
    收集结果                            return
    更新拓扑状态                      并发派工具(msg.tool_uses)
    if 全部完成 or 失败终止:          把结果追加到 messages
        break
```

形式几乎一模一样。差别只在两个地方:

1. **"下一步是什么"由谁回答?** EMF 由拓扑(预先写好的图)回答;Claude Code 由模型(实时推理)回答。
2. **退出条件是什么?** EMF 的退出条件是"所有节点完成";Claude Code 是"模型说不再调工具"。

这个对比也直接告诉你 EMF 升级 AI 能力的最自然路径:

> 在 EMF 里给某些节点附加一个 `agent_handler`。当这个节点的常规 Operator 失败时,Scheduler **不直接走失败分支**,而是临时启动一个 Agent Loop,以"诊断并尝试修复这个节点"为目标。Loop 退出后再回 EMF 主调度。

这其实就是把"探索能力"作为**异常分支的兜底**塞进确定性 DAG 里。第 11 课和第 20 课会继续推进这条思路。

---

## 小结

1. **整个 Agent 是一个 while 循环,只有两个分支:`end_turn` 退、`tool_use` 续。**
2. **"对话循环"和"工具循环"是同一个循环的两种相位**——区别只是出口在哪。
3. **tool_result 必须放在 user 消息里**,这是 API 硬约定;模型只能"提需求",副作用永远在外部。
4. **一条 assistant 消息可以含多个 tool_use 块**,触发 fork-join 式并发。
5. **没有 max_iterations 这种硬约束**;收敛性靠模型训练,而不是循环代码。
6. **中断的语义是"显式记录,而不是隐藏"**——把异常写进对话历史,让模型知道发生了什么。
7. **EMF 的 DAG Scheduler 与 Agent Loop 形式同构**,差异在"下一步谁说了算"。AI 赋能 EMF 最自然的位置是异常分支。

---

## 问题(检测你是否掌握)

**问题 1**(API 协议):
为什么 `tool_result` 必须放在 `role: "user"` 的消息里,而不是放进 assistant 消息里?如果 API 允许 assistant 自己写 tool_result,会带来什么后果?(提示:从"模型应当无副作用"反推。)

**问题 2**(并发模型):
模型在一条 assistant 消息里同时发了 10 个 `tool_use` 块,其中第 3 个是一个会跑 60 秒的 Bash 命令。
(a) 在 fork-join 模型下,整轮循环最少要等多久才能进下一次 API?
(b) 如果你想优化这个延迟,是改 Agent Loop、还是改 Tool Dispatcher、还是改模型的 system prompt?各自的取舍是什么?

**问题 3**(`max_tokens` 边界):
模型在生成一个 `tool_use` 块时被 `max_tokens` 截断,JSON 参数还没闭合。
你作为 Agent Loop 的设计者,有三种处理思路:
(A) 直接退出循环,告诉用户被截断了。
(B) 丢弃这条不完整的 assistant 消息,重发一次同样的 API 请求。
(C) 保留不完整消息,追加一条 user 消息说"上一条工具调用因长度限制不完整,请重新发起",再让模型重试。
请说明三者的取舍,并指出 Claude Code **不会**选哪个、为什么。

**问题 4**(EMF 集成):
你打算在 EMF 里给特定 Operator 加 "失败时启动 mini Agent Loop 自动诊断" 的能力。
(a) 这个 mini Agent 的"工具集"应该包含什么?(尽量具体)
(b) 它的退出条件设成"模型 end_turn"够不够安全?如果不够,你会加哪些**外部**约束?
(c) 这个 Agent Loop 和 EMF 主 Scheduler 之间,谁是谁的子,数据怎么传?

---

> 答任意几题就发过来。基于回答,后面会:
> - 全过 → 推进第 04 课《Tool Use 循环的递归本质》,把 fork-join 这一段单独再放大。
> - 问题 3(`max_tokens` 边界)栽掉 → 生成 `03b_流式中断的边界条件.md`,提前把第 05 课的部分内容借过来打补丁。
> - 问题 4 答得不顺 → 留着,在第 11 课 Subagent 时一起做一次 EMF 集成专题练习。
