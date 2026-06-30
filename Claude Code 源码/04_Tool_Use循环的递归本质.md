# 04 · Tool Use 循环的递归本质

> **核心问题:tool_use → tool_result 如何收敛?**
>
> 上一课我们把 Agent Loop 看成一个 while 循环,出口只有两个。这一课我们把镜头拉进去,
> 专门盯住"工具执行"那半条路:它内部是怎么运转的,为什么有时会像套娃一样嵌套,
> 又为什么最终必须收敛而不会无限下去。

---

## 一、从一次完整的 tool_use 说起

上一课的伪代码里,这一步是"并发派发":

```
tool_results = dispatch_concurrently(tool_uses, permission_check=permission)
```

一行代码,背后发生了什么?我们一步一步拆。

### 1.1 一个 tool_use 块长什么样

模型生成的 `tool_use` 块是标准 JSON,结构非常固定:

```json
{
  "type": "tool_use",
  "id": "toolu_abc123",
  "name": "Bash",
  "input": {
    "command": "git log --oneline -10",
    "description": "查看最近 10 条提交"
  }
}
```

三个字段是核心:
- **`id`**:这次工具调用的唯一标识符。后面 `tool_result` 必须带上同一个 `id`,模型才能把结果和请求对应起来。
- **`name`**:工具名字,Agent 用它查注册表找到具体的 handler。
- **`input`**:参数,由模型按照该工具注册时声明的 JSON Schema 填写。

这个结构有一个隐藏含义:**模型是"下单方",它不关心工具怎么实现**。`id` 是订单号,`name` 是商品 SKU,`input` 是规格。实际由谁执行、怎么执行,模型不知道也不需要知道。

### 1.2 tool_result 长什么样

工具执行完成后,Agent 把结果包成 `tool_result` 块,放进下一条 `role: "user"` 消息里:

```json
{
  "type": "tool_result",
  "tool_use_id": "toolu_abc123",
  "content": "bd5d1d8 update\n3207fe6 update\nd9c2136 update\n..."
}
```

注意:`tool_use_id` 必须和请求里的 `id` 完全匹配。如果一条 assistant 消息发了 3 个 `tool_use`,对应的 user 消息里就要有 3 个 `tool_result`,**并且每个 `tool_use_id` 都要有对应项**——不能缺、不能错,模型会把这当成严重上下文异常。

把请求和响应画成时序:

```
assistant 消息:
  [text: "我来查一下 git 历史"]
  [tool_use id=A name=Bash input={command: "git log"}]

        ↓ 工具执行,结果喂回

user 消息:
  [tool_result tool_use_id=A content="bd5d1d8 update\n..."]
```

这就是一轮最简单的 tool_use/tool_result 往返。

---

## 二、工具执行的内部管道

`dispatch_concurrently` 并不是一个"调调就完事"的简单函数。它内部是一条有完整生命周期的管道:

```
tool_use 块
    │
    ▼
① 名字解析 → 从注册表找 handler
    │
    ▼
② 权限检查 → allow / ask / deny
    │ (deny 直接短路,返回 error tool_result)
    ▼
③ 参数校验 → 按 JSON Schema 验 input
    │
    ▼
④ 实际执行 → handler(input)  ← 这里才是"工作"
    │
    ▼
⑤ 超时 / 取消 → 如果超时,终止并产生 error
    │
    ▼
⑥ 结果格式化 → 转成 tool_result 块
```

每一步都是一道关卡。特别值得展开三个环节:

### 2.1 权限检查在哪里发生

权限检查发生在"名字解析"之后、"实际执行"之前,而且是**每次**发生——不是"用户第一次批准后就永久免检"。

这个设计的理由很朴素:每次工具调用的 `input` 都可能不同。用户对 `Read("/etc/hosts")` 和 `Read("/home/user/.ssh/id_rsa")` 的容忍度是不一样的。**权限不只是看工具名字,要看工具名字 + 这次的具体参数。**

实现上这对应一个 `PermissionChecker`:它拿到 `(tool_name, input)` 这个二元组,对照用户设置的规则列表(allow/ask/deny patterns),决定是直接放行、弹交互确认框、还是拒绝。拒绝时返回的不是抛异常——而是**产生一条内容为错误说明的 `tool_result`**,把"被拒绝"这件事显式地写进对话历史。

这个设计上一课提到过,这里再强调一遍:**拒绝是上下文里的一个事件,不是程序流的一个 exception。** 模型看到"你发起的工具调用被用户拒绝了",它可以自主决定下一步——是换种方法、还是问用户、还是放弃这个方向。这件事交给模型推理,比写代码枚举"被拒后应该做什么"要灵活得多。

### 2.2 超时是语义问题,不是实现问题

超时听起来是个实现细节("等多少秒"),但其实暗含一个语义决策:

> 超时之后,tool_result 的 content 写什么?

有几种选法:
- `"命令超时,未获得输出"` —— 最简单
- `"命令超时。已获得的部分输出:\n..."` —— 带截断内容
- `"命令被终止 (SIGTERM)"` —— 技术细节

Claude Code 倾向于**带上已获得的部分输出**,而不是只说"超时"。理由和中断那条一样:让模型看见发生了什么。如果 Bash 命令跑了 55 秒后被截断,前 55 秒里可能已经打印了很多有用信息——全丢掉会逼着模型盲猜。

这也是为什么流式工具执行(边跑边收输出)比"等完成再给结果"更有价值:它让超时语义从"全失败"变成"部分成功"。

### 2.3 结果可以是富文本

`tool_result` 的 `content` 不限于字符串——它可以是一个数组,包含 `text` 和 `image` 两种类型:

```json
{
  "type": "tool_result",
  "tool_use_id": "toolu_abc123",
  "content": [
    {"type": "text", "text": "截图已生成"},
    {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "..."}}
  ]
}
```

这在截图类工具(`mcp__Claude_Preview__preview_screenshot`)或者图像分析类任务里会用到。模型本身是多模态的,tool_result 传图进去它能直接分析。

---

## 三、"递归本质"到底在哪里

这是本课标题里最重要的词。我们现在来正面回答它。

### 3.1 最直接的递归:Subagent

先说最字面意义上的递归。在 Claude Code 里有一个工具叫 `Task`(就是用户界面里看到的 "Agent" 工具)。它的 handler 做的事情是:

```
def task_handler(input):
    # 起一个全新的 Agent Loop
    sub_messages = [{"role": "user", "content": input["prompt"]}]
    result = run_agent_loop(
        messages=sub_messages,
        tools=input.get("tools", default_tools),
        system=sub_system_prompt,
    )
    return result.final_text
```

也就是说:主 Agent Loop 调用了 `Task` 工具 → `Task` 工具内部又起了一个完整的 Agent Loop → 这个子 Loop 也可以继续调工具、也可以再调 `Task` → 套娃下去。

**这是字面意义上的函数自调用式递归。**

画成树:

```
主 Agent Loop (turn N)
  └─ tool_use: Task("把 src/auth 重构成独立模块")
        └─ 子 Agent Loop
              ├─ tool_use: Read(src/auth/...)
              ├─ tool_use: Edit(...)
              └─ tool_use: Task("为这个模块补单测")   ← 可以再递归
                    └─ 孙 Agent Loop
                          ├─ tool_use: Write(auth.test.ts)
                          └─ end_turn → 返回给父
              └─ end_turn → 返回给主
  └─ 主 Loop 继续...
```

这棵树的每一个节点都是一个完整的 Agent Loop,每一条边都是一次 tool_use/tool_result 往返。

### 3.2 为什么不用递归,用"嵌套"来理解更准确

严格说,"递归"这个词有点误导——它暗示"同一个函数调自己",但子 Agent Loop 和父 Agent Loop 在实现层面是**隔离的**:

- 它们有各自独立的 `messages` 数组(对话历史)
- 子 Agent 看不到父 Agent 的完整历史——它只能看到 `Task` 工具传给它的 `prompt`
- 子 Agent 的上下文窗口是独立的,不和父 Agent 共享 200k tokens

用"**树形嵌套**"比"递归"更准确。每个节点是一个 Agent Loop 实例,父子之间的数据边界是严格的:

```
父 → 子:只传 Task.input.prompt(一段自然语言指令)
子 → 父:只返回 task_result(子 Agent 最终输出的文本)
```

父 Agent 不能"读取子 Agent 的 messages 数组"。这个隔离是刻意的设计,有两个好处:
1. **防止上下文污染**。子 Agent 做了很多工具调用,产生了大量 tool_result 输出。如果全部暴露给父 Agent,父 Agent 的上下文会被撑爆。
2. **可并发**。多个子 Agent 的 Loop 在互相隔离的情况下可以真正并发运行——它们不共享状态,没有竞争条件。

### 3.3 更隐蔽的递归:多轮 tool_use 的收敛结构

除了 Subagent 这种字面递归,有一种更隐蔽的"递归本质"——**单个 Agent Loop 的多轮迭代本身就是在做深度优先搜索式探索**。

举一个具体任务:"找到项目里所有没有被 export 的工具函数,给它们补上 export"。

模型不知道项目结构,它只能探索。它的行为会像这样:

```
轮 1: tool_use: Bash("find . -name '*.ts' | head -20")
轮 2: tool_use: Read(src/utils/format.ts) + Read(src/utils/parse.ts)  ← 并发
轮 3: 发现 format.ts 里有 3 个未 export 函数
      tool_use: Edit(src/utils/format.ts)
轮 4: tool_use: Read(src/utils/validate.ts)   ← 继续探索
轮 5: 发现 validate.ts 里没有问题
      tool_use: Bash("grep -r 'function ' src/ | grep -v 'export'")  ← 换策略
...
```

这是一个**搜索过程**。每一轮的 tool_use 是"打开下一层节点",每一轮的 tool_result 是"拿到节点内容,决定继续展开还是回溯"。这和树的 DFS 遍历在结构上是同构的:

```
DFS:                         Agent Loop:
  visit(node)                  call_model()
    for child in children:       for tool in tool_uses:
      if should_expand:            result = execute(tool)
        visit(child)               messages.append(result)
      else:                      call_model_again()
        record(child)
```

**收敛的保证在哪里?** DFS 在有限图上总会终止,因为节点数有上限。Agent Loop 的"图"是什么?是上下文窗口——它是有限的。每一轮都会往 messages 里追加内容,迟早触到 200k token 上限。这是一个物理意义上的"图有限"保证,比任何外部计数器都更根本。

除此之外,模型在训练时被塑造成"在上下文积累的信息足够时应该 end_turn",这是另一个方向的收敛力——**从内部推向终止**,而不是从外部截断。

---

## 四、tool_use 失败的语义

工具执行失败是常态,不是异常——这一点值得专门说一段。

### 4.1 失败的两种形态

**形态 A:工具本身执行失败**

比如 `Read("/not/exist.ts")` 文件不存在,或者 `Bash("npm test")` 返回非零退出码。

这种情况下,`tool_result` 的 content 填错误信息,**另外加一个字段**:

```json
{
  "type": "tool_result",
  "tool_use_id": "toolu_abc123",
  "content": "Error: ENOENT: no such file or directory, open '/not/exist.ts'",
  "is_error": true
}
```

`is_error: true` 是一个显式信号,告诉模型"这次工具调用失败了"。模型看到这个信号会触发特定行为——通常是"换个策略、或者报告给用户"——而不是把错误当成普通输出继续往下走。

**形态 B:工具结果在语义上是"失败"的,但执行本身没有报错**

比如 `Bash("grep 'TODO' src/")` 返回空字符串——grep 没报错,只是没找到。这不是 `is_error`,但模型需要读返回值来判断"下一步怎么走"。

这两种形态的区别告诉你:工具的成功/失败语义不能只看"有没有异常",模型还需要读结果内容。这对工具的输出设计有隐含要求:**输出要让模型容易判断"是否达到目的"**。一个返回空字符串的工具,比返回 "Found 0 matches." 的工具更容易被模型误判。

### 4.2 失败 tool_result 和循环的关系

很关键:**失败的 tool_result 不会让循环终止**。它只是被追加进 messages,然后再调一次模型。

这是对的设计。模型看到 `is_error: true` 之后,有三种常见反应:
1. **换工具**:Read 失败了,试试 Bash ls 先看看有什么。
2. **调整参数**:路径写错了,用更宽松的 glob 再搜一次。
3. **告诉用户**:三次尝试都失败,现在放弃并说明原因。

哪条路最合适,由模型自己根据上下文推理决定——不是循环代码写死的。这是"把判断权还给模型"这个原则在错误处理上的体现。

### 4.3 错误的"层叠"问题

有一个有意思的边界情况:如果连续多轮都是 `is_error: true`,会怎么样?

理论上循环本身不会因此停止。现实里这通常是信号——要么任务超出了工具能力范围,要么模型陷入了某种局部循环(每轮都尝试同样的方式,每轮都失败)。

Claude Code 在训练层面处理了这个问题:模型被训练成"看到多次相同错误应该报告用户并停止重试",而不是"不断循环"。但这不是代码里的 `if error_count > 3: break`,而是模型推理能力的一部分。

---

## 五、tool_use 和 text 共存的语义

一条 assistant 消息里,`tool_use` 块和 `text` 块可以同时存在:

```json
{
  "role": "assistant",
  "content": [
    {
      "type": "text",
      "text": "我先来看一下目录结构,然后再决定从哪里入手。"
    },
    {
      "type": "tool_use",
      "id": "toolu_abc",
      "name": "Bash",
      "input": {"command": "ls -la src/"}
    }
  ]
}
```

这里的 `text` 是模型在"边想边说"——它在 tool_use 之前的文字实际上是**推理痕迹**,类似思维链。

这对循环有一个实现细节的影响:**当 stop_reason 是 tool_use 时,循环只处理 `tool_use` 块,不需要对 `text` 块做任何额外操作**。文字已经作为流式输出实时渲染给用户了;工具还没执行,还等着。

对用户体验来说,这意味着用户能在工具跑之前就看到模型的"解释"。这不是意外,是有意的——用户能更早知道模型在打算做什么,如果方向不对可以按 Esc 打断。

从工程角度看,这意味着 **text 块的呈现和 tool_use 块的执行是天然串行的**——先流式输出 text,流完后再执行工具。即使同一条消息里的多个 tool_use 是并发执行的,它们依然在 text 输出完之后才启动。

---

## 六、工具结果的大小问题

一个经常被忽视的问题:如果 tool_result 的 content 非常大怎么办?

比如 `Read` 读了一个 5 万行的日志文件,或者 `Bash("docker logs")` 打出了几十 MB 的容器日志。

这些内容全部塞进 messages,会迅速吃掉上下文窗口。Claude Code 在这里有几个工程取舍:

**① 截断**:tool_result 的 content 有最大长度限制。超过限制的部分被截断,并在末尾加上 `"[输出已截断,共 X 行]"` 这样的说明。

**② 行数感知**:对 `Read` 工具,如果文件很大,只读前 N 行,然后告诉模型"文件共 M 行,当前只显示前 N 行"。模型可以再次调用 `Read` 并传 `offset` 参数来读后续部分。

**③ 摘要**:某些工具(尤其是 MCP 工具)的 handler 在返回结果之前会先对内容做摘要处理。

这些策略背后是一个统一原则:**tool_result 的内容要对模型有用,而不是完整**。把 5 万行日志全塞给模型,模型也看不过来——它的注意力在长文档上会退化。给它前 500 行 + "共 50000 行" + "如需更多请使用 offset" 的提示,比全文喂进去更有效。

---

## 七、tool_use 的不变式总结

把整个 tool_use 循环的不变式整理成一张表:

| 不变式 | 原因 |
|--------|------|
| 每个 `tool_use` 必须有对应的 `tool_result` | API 硬约定;模型依赖 id 配对 |
| `tool_result` 必须在 `role: user` 消息里 | "副作用在外部"原则;模型无法自给自足 |
| 失败的 tool_result 用 `is_error: true` 标记 | 让模型区分"执行失败"和"执行成功但结果为空" |
| 工具执行的 fork-join:并发执行,同步收齐 | 一轮 API 调用是原子的,不能半途喂结果 |
| tool_result 内容要"有用"不要"完整" | 上下文窗口有限;模型注意力有退化 |
| 失败不终止循环,失败是上下文里的事件 | 让模型自主决策失败后的下一步 |

---

## 八、与 EMF 的对照

上一课对照了两个 while 循环的整体结构。这课我们聚焦到一个节点:EMF 的单个 Operator 执行,和 Claude Code 的单次 tool_use 执行。

```
EMF Operator 执行:                Claude Code tool_use 执行:

① 从 DAG 拿到 Operator 类           ① 从 tool_name 查注册表
② 检查 input dependency 都就绪      ② 权限检查 (tool_name + input)
③ 调 operator.execute(context)      ③ 参数校验 (JSON Schema)
④ 捕获异常 → 写 task_instance 状态   ④ 执行 handler(input)
⑤ 成功 → 解锁下游节点               ⑤ 失败 → is_error tool_result
                                     ⑥ 成功 → 正常 tool_result
                                     ⑦ 两者都追加进 messages → 继续循环
```

最大的不同在收尾:

- EMF 的 Operator 执行成功后,会"解锁下游节点"——成功是 DAG 推进的触发器。
- Claude Code 的 tool_use 不管成功还是失败,结果都进 messages —— 结果是**给模型看的信息**,而不是触发后续行为的信号。

这个差异背后是两种"谁来调度"的哲学:

- EMF:调度逻辑在 Scheduler 代码里,它读取 Operator 的成功/失败状态然后决定走哪条路。
- Claude Code:调度逻辑在模型里,它读取 tool_result 的内容然后决定下一步调什么工具。

**EMF 是"代码调度 + 工具执行";Claude Code 是"模型调度 + 工具执行"。** 工具执行的 plumbing 几乎一样,差别全在"谁看执行结果、谁做决定"。

---

## 小结

1. **tool_use 块是模型的"订单":id、name、input 三件套,模型只管下单,不管执行。**
2. **工具执行是一条管道**:名字解析 → 权限检查 → 参数校验 → 实际执行 → 超时 → 结果格式化。权限检查发生在每次调用,不是一次性授权。
3. **Subagent 是字面意义上的嵌套 Agent Loop**,父子之间数据隔离严格——只传 prompt 和最终结果,不共享 messages。
4. **多轮 tool_use 是 DFS 式探索**,收敛保证来自"上下文窗口有限"这个物理约束 + 模型被训练成"在信息足够时主动 end_turn"。
5. **失败是上下文里的事件,不是循环的终止条件**——`is_error: true` 告诉模型"工具挂了",由模型推理下一步,而不是代码硬写"出错就停"。
6. **tool_result 的内容原则:有用而非完整**——截断、分页、摘要都是在保护上下文窗口。
7. **与 EMF 的本质区别:谁看结果、谁做决定。** EMF 是 Scheduler 代码看,Claude Code 是模型看。

---

## 问题(检测你是否掌握)

**问题 1**(id 配对机制):
一条 assistant 消息里发了 3 个 `tool_use` 块,id 分别是 A、B、C。工具 B 执行时报错,A 和 C 正常。
(a) user 消息里的 `tool_result` 数量应该是几个?
(b) 如果你只回了 A 和 C 的 result、把 B 的漏掉了,会发生什么?
(c) 如果 B 的 result 用 `is_error: true`,模型接下来最可能做什么?

**问题 2**(权限检查时机):
用户预先设置了一条规则:`allow Bash("git *")`(任何 git 命令自动放行)。
模型接下来发了一个 `tool_use: Bash("git push origin main --force")`。
(a) 权限检查会放行这条命令吗?
(b) 如果你是设计者,你会怎么改进这套规则机制,在不打扰用户的前提下阻止这条命令?

**问题 3**(递归收敛):
主 Agent 调用了 `Task` 工具,子 Agent 调用了另一个 `Task` 工具,孙 Agent 又调了一个 `Task`。
(a) 孙 Agent 的 200k 上下文窗口和主 Agent 共享还是独立?
(b) 如果孙 Agent 里有一个 Bash 命令无限输出内容(比如 `tail -f /dev/random`),这个无限输出会影响主 Agent 的上下文窗口吗?
(c) 这说明 Subagent 的隔离边界,除了"上下文隔离",还有什么工程上的价值?

**问题 4**(结果大小):
一个工具读取了一个 10 万行的日志文件,你需要决定 tool_result 的 content 怎么处理。列出至少 3 种策略,并说明各自的适用条件和缺点。

---

> **下一课预告:05 - 流式响应处理**
>
> 第 03 课里我们提到 `max_tokens` 截断到一半的 `tool_use` 块是个危险信号。
> 第 04 课里我们提到 text 块和 tool_use 块的流式呈现是串行的。
> 这两件事背后,是 Claude Code 对 SSE 流的解析逻辑。
> 下一课我们盯住流:一帧一帧看清楚从"bytes 进来"到"Markdown 渲染出去"之间发生了什么。
