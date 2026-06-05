# RAG - 第 2 课：Chunk分片：RAG里最容易被低估、却最影响效果的一层

## 学习目标（本节结束后你能做到什么）

1. 你能解释为什么 chunk 不是“预处理细节”，而是 RAG 效果的地基。
2. 你能说清固定长度切分、结构化切分、语义切分、Parent-Child、Late Chunking 分别在解决什么问题，又分别会踩什么坑。
3. 你能根据文档类型和查询类型，给出一个有依据的 chunk 策略，而不是背“500 tokens 最佳实践”。
4. 你能建立一套评估 chunk 好坏的方法，知道什么时候问题出在切分，什么时候其实出在检索、rerank 或生成。
5. 你能从后端工程视角设计文档解析、切分、索引、增量更新、监控和告警这条链路。

## 内容讲解（核心概念，用类比、例子、图示说清楚）

### 1. 先把这个问题摆正：chunk 不是“把文档切一下”这么简单

很多人第一次做 RAG，会把问题理解成：

1. 文档丢进去。
2. 切成小块。
3. 做 embedding。
4. 相似度检索。
5. 把结果塞给模型。

这条链路当然没有错，但真正的坑在于：  
**第 2 步看起来最普通，实际上它决定了后面 3、4、5 步的上限。**

因为 RAG 的知识访问方式不是“直接看原始文档”，而是“先在切出来的小块里找，再把找到的小块拼回去”。  
这意味着：

- chunk 切坏了，embedding 再强也只能学到坏切片的语义。
- chunk 切坏了，向量库再快也只能检索到坏切片。
- chunk 切坏了，Prompt 再优雅也只能基于错误或不完整的上下文作答。

所以 chunk 是什么？  
最直白的说法就是：

`chunk 是你给知识库建立的“最小检索单元”。`

你可以把它想成图书馆索引系统里的“卡片”：

- 如果卡片太粗，只写“这本书讲 Java”，那就查不准。
- 如果卡片太细，细到每一行代码都单独做一张卡片，那就丢掉上下文。
- 如果卡片刚好覆盖一个完整的小主题，检索和回答就都舒服。

RAG 系统里大多数“为什么检索不准”“为什么答案不完整”“为什么成本这么高”的问题，最后都能追溯到 chunk 切得不合适。

### 2. 为什么一定要切：这是大模型、检索和成本三方面共同逼出来的

先别谈技巧，先谈约束。  
文档之所以必须切，不是因为大家爱折腾，而是因为不切根本跑不起来，或者跑起来会非常贵、非常差。

#### 2.1 上下文窗口不是无限资源

哪怕今天很多模型的上下文已经很大，比如 100k、200k token，甚至更大，也不意味着我们应该把整篇文档直接塞进去。

原因有三个：

- **第一，成本问题。**  
  模型上下文越长，输入 token 成本越高。你每次问一个问题都带上整本手册，API 账单会非常难看。

- **第二，时延问题。**  
  长上下文意味着更慢的预填充和推理。很多工程系统不是做“学术演示”，而是做真实在线服务，响应时间要可控。

- **第三，位置偏差问题。**  
  长上下文里，模型并不是对每个位置都同样敏感。中间内容往往最容易被忽略，这就是著名的 “Lost in the Middle” 现象。

所以，“模型上下文很大”不等于“RAG 可以不切块”。  
它只意味着：**你在切块和上下文组装上可以更从容，但不会消灭切块问题。**

#### 2.2 检索的基本单位必须足够小

向量检索不是魔法，它要比较的是“问题向量”和“chunk 向量”之间的相似性。

如果一个 chunk 里同时塞了：

- Spring Boot 启动优化
- Spring Cloud 配置中心
- Feign 超时重试
- Docker 镜像构建

那这个 chunk 的 embedding 就会变成一个“主题平均值”。  
用户问 `Spring Boot 启动优化` 时，它可能检索到，也可能被别的语义稀释掉。

所以检索单元不能太大，否则语义表达会被“平均化”，召回边界变模糊。

#### 2.3 生成模型吃上下文也不是越多越好

很多人觉得，多给模型一点上下文总没坏处。  
实际上不对。

上下文太多会引出三个工程问题：

- 噪声增加：相关片段淹没在无关片段里。
- token 预算被浪费：真正关键的内容反而占比下降。
- 模型更容易“拼接式胡编”：把多个相邻但不该合并的片段混成一个答案。

因此，切块的目标不是“把文档切小”，而是：

`让每个块既足够小，能被准确召回；又足够完整，能支持后续回答。`

### 3. 切分悖论：所有 chunk 设计，本质上都在平衡两个相反目标

这也是为什么团队总会围绕 `chunk_size` 和 `overlap` 争论半天。

可以把 chunk 设计理解成一个经典悖论：

- **切太小**  
  召回更精确，但上下文丢失，答案不完整。
- **切太大**  
  上下文更完整，但召回变钝，成本更高，噪声更多。

这就是“切分悖论”。

它不是一个可以彻底消灭的问题，而是一个必须管理的权衡。

我们可以用一张图把它画出来：

```mermaid
flowchart LR
    A["Chunk 太小"] --> A1["语义单元被切碎"]
    A --> A2["配置示例、表格、代码上下文丢失"]
    A --> A3["召回准，但回答容易残缺"]

    B["Chunk 太大"] --> B1["多个主题被混在一起"]
    B --> B2["Embedding 表达被平均化"]
    B --> B3["召回不准，成本高，上下文污染"]

    C["理想目标"] --> C1["块内主题尽量单一"]
    C --> C2["块内逻辑尽量完整"]
    C --> C3["块间重复适度而非过度"]
```

所以不要问：

`“chunk_size 到底应该设多少？”`

更有价值的问题是：

`“对于这类文档、这类查询、这类成本约束，我希望检索单元多大才最合适？”`

### 4. Token 这件事，比很多人以为的要坑得多

这一节非常重要。很多团队调 chunk 时的第一个错误，就是把“字符数”和“token 数”混着用。

#### 4.1 字符、词、token 不是一回事

对于中文，最容易出错。  
比如：

`基于深度学习的自然语言处理技术`

这串文本看起来只有十几个字，但不同 tokenizer 下 token 数差别很大。  
同样一句中文：

- 在某些 OpenAI tokenizer 下可能是 11 个 token
- 在某些 Anthropic tokenizer 下可能是 9 个 token
- 在某些对中文不友好的 tokenizer 下可能是 20 多个 token

这意味着：

- 你用 A 模型的 tokenizer 去估 B 模型的上下文预算，结果经常会偏。
- 你在本地评估时觉得 600 token 很安全，换模型上线后可能直接超。

所以一个很朴素但经常被忽视的规则是：

`chunk 大小的预算，一定要基于目标模型的 tokenizer。`

#### 4.2 中文标点、代码块、表格都可能扭曲 token 估算

很多经验法则只适合英文纯文本，比如：

`1 token ≈ 0.75 个英文单词`

但中文里：

- 标点可能单独占 token
- 省略号、全角符号、特殊换行都可能让 token 急剧增加
- Markdown 标题、代码 fence、JSON、YAML 都会放大 token 数

尤其是代码文档和 API 文档，字符看起来不长，token 往往偏多。

#### 4.3 你最终管理的是“总 token 预算”，而不是单个 chunk 大小

chunk 不是孤立存在的。  
一次检索通常会返回多个 chunk，再加上：

- system prompt
- query
- instructions
- citations
- output reservation

真正需要管理的是一次请求的总预算：

```text
总输入预算 = 系统提示 + 查询改写 + 检索结果 + 额外指令 + 安全冗余
```

如果你给 chunk 切得很大，`topK=8` 的时候可能一下就爆掉。  
所以 chunk 设计一定要和后面的 `topK`、rerank、上下文组装一起考虑。

### 5. 固定长度切分：为什么它最常见，也最容易埋雷

最原始的 chunk 思路就是按固定长度切。

比如：

```python
def naive_chunk(text, size=1000):
    return [text[i:i+size] for i in range(0, len(text), size)]
```

这类方案之所以大家都用过，是因为它有两个明显优点：

- 极其简单
- 很稳定，不依赖复杂解析器

如果你只是为了快速跑通 Demo，它确实是最容易上手的方案。

但它的问题也同样明显。

#### 5.1 它不理解任何语义边界

固定长度切分对文本一视同仁：

- 不知道哪里是段落边界
- 不知道哪里是代码块边界
- 不知道哪里是表格边界
- 不知道哪里是一句话刚讲完

结果就是：

- 一个完整配置示例上半段在 A，下半段在 B
- 标题和正文分开
- 表格行被切断
- 注释和代码分家

#### 5.2 它会制造“检索时命中不到、生成时拼不完整”的典型事故

举个真实场景：

文档里有一段：

```text
Spring Boot 启动优化建议如下：
1. 开启懒加载；
2. 减少自动配置扫描范围；
3. 使用 CDS；
4. 检查第三方 starter 初始化耗时。
```

如果固定 1000 字符硬切，刚好把第 1 行切到一个块，第 2~4 行切到另一个块：

- 用户搜“Spring Boot 启动优化”时，可能只召回标题块；
- 用户搜“CDS 怎么优化启动”时，可能只召回列表块；
- 任何一边单独进模型，都会丢掉完整语义。

#### 5.3 overlap 是固定长度切分的补救机制，不是万能药

很多人发现固定切分会断上下文，就会加 overlap。

这当然有用，但 overlap 只能缓解，不能根治。

因为 overlap 解决的是：

- 边界处的信息断裂

它解决不了的是：

- chunk 本身主题杂糅
- 切分点不自然
- 重复内容膨胀

所以 overlap 更像一个缓冲垫，而不是结构化切分的替代品。

### 6. overlap 到底该怎么理解：它不是越多越安全

overlap 最常见的误区就是：

`“怕丢内容，那我多重叠一点不就好了？”`

听起来合理，实际代价很大。

#### 6.1 overlap 的正面作用

它主要解决边界问题：

- 某个概念从 chunk A 结尾延续到 chunk B 开头
- 某个配置示例跨越边界
- 某句话上下句被拆开

这时适量重叠，确实能提升召回的连续性。

#### 6.2 overlap 的负面作用

但 overlap 一旦太大，会引出三个副作用：

- **存储膨胀**：重复文本做了多次 embedding，占空间、占索引。
- **召回去重难度上升**：同一段内容会以多个几乎相同的 chunk 形式反复出现。
- **上下文污染**：最终拼装 prompt 时，重复内容占用了宝贵 token。

#### 6.3 overlap 更像“边界保险”，不是“效果增强器”

经验上，overlap 通常可以先从相对保守的范围起步：

- 技术文档：10% 到 15%
- 新闻与短内容：15% 到 20%
- 强依赖上下文的法律或规范文档：20% 到 25%

但这只是起点，不是定律。

你应该始终结合两件事一起看：

- 你的 chunk 是否经常把完整信息切断
- 你的最终 prompt 里是否出现大量重复上下文

### 7. 结构化切分：真正工程可用的第一步

如果说固定长度切分是“先跑起来”的办法，  
那结构化切分通常是“第一次真正做出效果”的关键转折点。

它的核心思想不是按字符数硬切，而是优先尊重文档结构：

- 段落
- 标题
- 句号
- 列表项
- 代码块
- 表格
- Markdown 层级

这类方法的好处是：

`尽量让 chunk 边界和人类阅读边界一致。`

#### 7.1 一个常见的结构化切分思路

本质上是“优先级分隔符 + 大小约束”的组合。

比如：

1. 优先按标题或空段切
2. 如果块太大，再按句号切
3. 如果还太大，再按分号、逗号切
4. 最后才退化到硬切

这类策略虽然朴素，但在工程里非常鲁棒。

因为它不会假装自己“理解文档”，而是先最大化利用现成结构信号。

#### 7.2 为什么它比纯语义切分更容易落地

因为结构信号通常更稳定：

- 段落是作者自己划出来的
- 标题是文档天然的语义边界
- 代码块 fence 是硬边界
- 表格结构是格式边界

这些边界不需要额外算 embedding，就能直接利用。

这就是为什么很多成熟系统最终都会采用一种“看起来不够炫，但效果稳定”的方案：  
**先结构化，必要时再语义微调。**

### 8. 语义切分：很迷人，但不要神话它

语义切分的想法很自然：

既然 chunk 的目标是保持语义完整，那我为什么不直接用 embedding 相似度，在语义跳变处切呢？

思路通常是：

1. 先把文档切成句子或小单元
2. 为每个句子生成 embedding
3. 比较相邻句子的相似度
4. 当相似度低于阈值时，认为主题发生切换，于是切分

理论上非常优雅，问题也非常现实。

#### 8.1 语义切分的三个核心难点

**第一，成本高。**  
每一句都算 embedding，长文档处理时间很可观，尤其是离线索引构建规模一大就更明显。

**第二，阈值难定。**  
0.7、0.75、0.8 看起来只是几个数字，但对不同文档类型含义完全不同。

**第三，局部句子相似度并不等于主题连续性。**  
这是最容易被忽略的问题。

举个典型技术规范例子：

```text
系统采用微服务架构。API 网关负责请求路由。认证服务处理用户登录。
```

这三句话都在讲“系统架构”，但句子之间词汇表面差异很大。  
如果只看句子 embedding，相似度可能并不高，于是被切成三个块。

这就说明：

`语义切分并不天然等于“主题切分”。`

它只是用一个局部统计信号，去近似你真正想找的主题边界。

#### 8.2 语义切分适合什么场景

它更适合：

- 句子结构比较清晰的正文型文档
- 语义段落自然过渡明显的文本
- 离线可接受额外计算成本的系统

它不太适合：

- 强结构文档（Markdown、代码、表格）
- 公式密集文档
- 带大量模板化句式的规范文档

所以语义切分一般不应该是你的默认第一选择，而更像一个“精修工具”。

### 9. 一个更成熟的思路：混合切分而不是押宝单一策略

很多团队最后都会发现，最实用的不是“找到唯一正确的 chunk 算法”，而是：

`先分类，再选策略。`

也就是说，切分策略和文档类型应该耦合。

#### 9.1 文档分类为什么重要

同样 100 页内容：

- 技术规范
- FAQ
- Markdown 教程
- 接口文档
- Word 合同
- PDF 扫描件

它们的理想切分边界根本不是一回事。

#### 9.2 一个非常实用的工程套路：先判型，再切分

先做轻量采样分析，再决定走哪条处理链：

- 如果前 5000 字里出现大量 code fence，倾向代码文档。
- 如果标题层级明显，倾向 Markdown / 结构文档。
- 如果 OCR 噪声严重，先清洗再切分。
- 如果表格很多，走专门表格处理链。

这看起来“没那么学术”，但非常符合工程现实：

**不要试图用一个切分器吃掉所有文档。**

更准确地说，生产里的 chunking 不应该是：

```text
document -> splitter -> chunks
```

而应该是：

```text
document -> light profiling -> document-type routing -> specialized parsing/chunking -> chunks + metadata
```

这里的 `light profiling` 不需要很重。  
它不是要理解文档全部内容，而是快速判断：

`这份文档最怕被哪种方式切坏？`

不同文档怕的东西不一样：

- 代码文档怕切断 code block、函数签名、配置示例。
- Markdown / Wiki 怕标题路径丢失。
- OCR 文档怕噪声先被 embedding 学进去。
- 表格文档怕表头、单位、行列关系丢失。
- FAQ 文档怕问答对被拆开。
- 合同 / 政策文档怕条款编号、例外条件、有效期被拆散。

所以这一步不是“锦上添花”，而是在避免一开始就把知识形状打碎。

#### 9.3 轻量采样到底采什么

可以先只读：

- 前 `5000` 到 `10000` 字符
- 文档中间随机几段
- 最后一两页或最后一两节
- parser 输出的 element 类型统计
- 页码、标题、表格、代码块、图片说明等结构信息

不要只看开头。  
很多文档开头是目录、声明、封面，真正结构在后面。  
更稳的做法是：

```text
head sample + middle sample + tail sample + parser element statistics
```

采样时可以计算这些信号：

| 信号 | 说明 | 可能指向 |
| --- | --- | --- |
| `code_fence_count` | ``` 或 `~~~` 出现频率 | 代码 / 技术文档 |
| `heading_density` | `#`、`1.2.3`、`第 x 章` 等标题密度 | 结构化文档 |
| `table_line_ratio` | Markdown 表格、CSV 风格、制表符、对齐符比例 | 表格文档 |
| `ocr_noise_score` | 乱码、断行、异常空格、重复页眉页脚 | OCR / 扫描件 |
| `avg_line_length` | 行长是否异常短或异常碎 | OCR、代码、列表 |
| `list_density` | `-`、`1.`、`（一）` 等列表项比例 | SOP、政策、FAQ |
| `punctuation_ratio` | 标点和特殊符号占比 | 代码、表格、噪声 |
| `element_type_histogram` | parser 输出 title/table/paragraph/code 数量 | 专门处理链 |

一个重要判断是：

`文档类型不是单选题，而是多标签。`

比如一份技术文档可能同时是：

```text
Markdown + code-heavy + table-heavy
```

这时不要给整篇文档选一个 splitter，而应该对不同 element 走不同处理链。

#### 9.4 代码文档怎么处理

代码文档的典型信号：

- code fence 很多：```python、```json、```yaml
- 行首缩进多
- `{}`、`()`, `=>`, `::`, `import`, `class`, `def` 密集
- Markdown 里穿插大量配置、命令、API 示例
- 文件路径、函数名、错误码很多

代码文档最怕两件事：

1. 把代码块切断。
2. 把解释文字和对应代码分开。

比如：

````markdown
下面配置用于开启重试：

```yaml
retry:
  max_attempts: 3
  backoff: exponential
```

`max_attempts` 表示最大重试次数。
````

如果 splitter 把 yaml 和后面的解释分开，用户问 `max_attempts 是什么` 时，很容易只召回代码或只召回解释。

代码文档处理链建议：

```text
Markdown parser
-> 识别 heading / paragraph / code fence
-> code block 作为不可切断 element
-> 将“代码前说明 + code block + 代码后解释”合并成一个 parent
-> child 可以按函数、配置项、段落继续切
-> metadata 记录 language、symbol、file_path、heading_path
```

关键 metadata：

```json
{
  "element_type": "code",
  "code_language": "yaml",
  "section_path": ["配置", "重试策略"],
  "symbol_names": ["retry.max_attempts", "retry.backoff"],
  "file_path": "docs/retry.md"
}
```

如果是代码仓库，不要只靠 Markdown splitter。  
更稳的是 AST / tree-sitter-aware chunking：

- 函数作为基本单元
- 类作为 parent
- 文件路径和模块路径进入 metadata
- import / dependency 作为结构信息
- 注释和函数体尽量不要拆开

代码类 RAG 的经验是：

`按自然语言切文档，按 AST 切代码。`

#### 9.5 Markdown / Wiki / 结构化文档怎么处理

结构化文档的典型信号：

- 标题层级明显：`#`、`##`、`###`
- 条款编号明显：`1.`、`1.1`、`1.1.1`
- 中文制度标题：`第一章`、`第十二条`
- 列表和段落边界清楚
- parser 能输出 title / paragraph / list item

这类文档最重要的是保留 `section_path`。

例如：

```text
入职与离职
  离职流程
    权限回收
      门禁权限应在 24 小时内停用
```

如果只存正文：

```text
门禁权限应在 24 小时内停用
```

embedding 还能召回，但生成时容易丢掉约束。  
更好的 chunk text 是：

```text
标题路径：入职与离职 > 离职流程 > 权限回收
正文：门禁权限应在 24 小时内停用。
```

结构化文档处理链建议：

```text
解析标题树
-> 按 section 生成 parent chunk
-> section 内按段落 / 列表项生成 child chunk
-> child text 注入 heading path
-> metadata 保存 section_id / section_path / heading_level
-> 检索 child，回填 parent 或 section window
```

关键点：

- 标题不要单独成为孤立 chunk，除非标题本身有业务含义。
- 列表项短时，可以把相邻列表项和列表标题合并。
- 条款型文档要保留条款编号。
- parent-child 很适合结构化文档。

#### 9.6 OCR 噪声文档怎么处理

OCR 噪声文档的典型信号：

- 大量异常空格：`权 限 回 收`
- 断行严重：一句话被切成很多短行
- 页眉页脚重复出现
- 乱码或替代字符：`�`
- 标点缺失或错位
- 表格被 OCR 成乱序文本
- 置信度低，如果 OCR 引擎提供 confidence

OCR 文档最忌讳：

`把脏文本直接 embedding。`

因为 embedding 会把噪声也编码进去，后面很难救。  
OCR 文档应该先做清洗和结构恢复，再切分。

处理链建议：

```text
OCR / layout parser
-> 去页眉页脚
-> 修复断行和连字符
-> 归一化空格和全角半角
-> 基于 layout 恢复阅读顺序
-> 标记低置信区域
-> 噪声仍高时走 VLM / 人工复核 / 降权索引
-> 再做 section-aware 或 paragraph-aware chunking
```

清洗要克制。  
不要为了“看起来干净”把证据改坏。

建议同时保留：

- `raw_text`
- `clean_text`
- `ocr_confidence`
- `page_number`
- `bbox`
- `parser_version`

metadata 示例：

```json
{
  "element_type": "paragraph",
  "source_type": "scanned_pdf",
  "ocr_required": true,
  "ocr_confidence": 0.71,
  "cleaning_pipeline": "ocr_clean_v2",
  "page_number": 8,
  "bbox": [71.2, 210.0, 510.5, 244.6]
}
```

OCR 质量太低时，不要假装它和普通文本一样可靠。  
可以在 rerank 或 context assembly 时降权，也可以在回答中提示“证据来自 OCR，可能需要核对原文”。

#### 9.7 表格很多的文档怎么处理

表格文档的典型信号：

- Markdown 表格分隔符很多：`| --- |`
- CSV / TSV 风格明显
- parser 输出 table element 多
- PDF 页面里存在大量网格线或对齐列
- 数字、单位、百分比、日期密集
- 行列标题非常关键

表格最怕被当成普通文本切。

原因是表格的信息不是线性的。  
一个单元格的含义来自：

```text
表标题 + 表头 + 行标题 + 列标题 + 单位 + 脚注
```

例如单元格 `24` 本身毫无意义。  
它可能是：

```text
离职员工 / 门禁权限 / 回收时限 / 小时 = 24
```

表格处理链建议：

```text
table extraction
-> 识别 caption / header / units / footnotes
-> 简单表格转 Markdown
-> 复杂表格生成 table summary
-> 按行或逻辑区域生成 row-level chunks
-> 每个 row chunk 注入表头、单位、caption
-> 原始表格另存为 structured artifact
-> metadata 保存 table_id、row_id、column_ids、page、bbox
```

表格 chunk 示例：

```text
表格：权限回收 SLA
列：对象=离职员工；权限类型=门禁；回收时限=24；单位=小时
说明：离职员工的门禁权限应在 24 小时内完成回收。
```

metadata 示例：

```json
{
  "element_type": "table_row",
  "table_id": "tbl_access_sla",
  "row_id": "row_3",
  "column_ids": ["subject", "permission_type", "sla", "unit"],
  "caption": "权限回收 SLA",
  "page_number": 12
}
```

表格多的系统通常需要两条检索路：

- 文本化表格 chunk：适合语义问答。
- 结构化表格对象：适合精确筛选、聚合、计算。

比如用户问：

```text
哪类权限回收时限最长？
```

这可能需要对表格做排序或聚合，单纯 vector retrieval 不一定够。

#### 9.8 FAQ、政策、合同、SOP 这类半结构文档怎么处理

除了上面四类，企业知识库里还有几类高频文档。

FAQ：

```text
按 Q/A 对切，问题和答案不能分离。
同义问法可以作为 metadata 或扩展 query。
```

政策 / 合同：

```text
按条款、章节、定义、例外条件切。
保留条款编号、有效期、适用范围、例外说明。
不要把“规则”和“例外”切到两个互不相关的 chunk。
```

SOP / Runbook：

```text
按任务步骤切，但保留前置条件、风险提示、回滚步骤。
步骤太短时，按阶段合并成 parent，step 做 child。
```

API 文档：

```text
endpoint / method / request schema / response schema / error code 要绑定在一起。
不要把参数表、示例请求、错误码表分别孤立索引。
```

这类文档的共同特点是：

`结构比字面相似度更可靠。`

所以优先结构化，再考虑语义切分。

#### 9.9 一个轻量文档路由器示例

下面这个代码不是为了做一个完美分类器，而是展示工程套路：

```python
from __future__ import annotations

import re
from dataclasses import dataclass


@dataclass(frozen=True)
class DocumentProfile:
    kind: str
    confidence: float
    signals: dict[str, float]


def profile_document(text: str, *, sample_size: int = 8000) -> DocumentProfile:
    sample = text[:sample_size]
    lines = [line for line in sample.splitlines() if line.strip()]
    line_count = max(len(lines), 1)

    code_fence_count = sample.count("```") + sample.count("~~~")
    markdown_heading_count = len(re.findall(r"(?m)^#{1,6}\s+\S+", sample))
    numbered_heading_count = len(re.findall(r"(?m)^\s*(\d+\.){1,4}\s+\S+", sample))
    cn_policy_heading_count = len(re.findall(r"(?m)^第[一二三四五六七八九十百]+[章节条]\s*", sample))
    markdown_table_lines = len(re.findall(r"(?m)^\s*\|.+\|\s*$", sample))
    replacement_chars = sample.count("�")
    very_short_lines = sum(1 for line in lines if len(line.strip()) <= 6)
    avg_line_len = sum(len(line) for line in lines) / line_count
    whitespace_ratio = sum(ch.isspace() for ch in sample) / max(len(sample), 1)

    signals = {
        "code_fence_ratio": code_fence_count / line_count,
        "heading_ratio": (markdown_heading_count + numbered_heading_count + cn_policy_heading_count) / line_count,
        "table_line_ratio": markdown_table_lines / line_count,
        "replacement_char_ratio": replacement_chars / max(len(sample), 1),
        "short_line_ratio": very_short_lines / line_count,
        "avg_line_len": avg_line_len,
        "whitespace_ratio": whitespace_ratio,
    }

    if code_fence_count >= 3 or signals["code_fence_ratio"] > 0.02:
        return DocumentProfile("code_or_technical_doc", 0.85, signals)

    if signals["table_line_ratio"] > 0.15:
        return DocumentProfile("table_heavy_doc", 0.82, signals)

    if signals["replacement_char_ratio"] > 0.002 or (
        signals["short_line_ratio"] > 0.45 and avg_line_len < 24
    ):
        return DocumentProfile("ocr_noisy_doc", 0.78, signals)

    if signals["heading_ratio"] > 0.04:
        return DocumentProfile("structured_markdown_or_policy", 0.8, signals)

    return DocumentProfile("plain_text", 0.55, signals)
```

它背后的思想是：

- 先用便宜信号判型。
- 不追求一次判断绝对正确。
- 低置信度时走保守策略。
- 类型可以多标签，真实系统可以返回多个候选链路。
- 每次路由结果写入 metadata，方便后续评测。

比如 metadata 可以记录：

```json
{
  "profile_kind": "table_heavy_doc",
  "profile_confidence": 0.82,
  "chunking_pipeline": "table_aware_v2"
}
```

这样以后你发现“表格类问题效果差”，才能按 `chunking_pipeline` 做评测切片。

#### 9.10 一个实际的路由决策表

| 判型 | 推荐 parser | 推荐 parent | 推荐 child | 关键 metadata |
| --- | --- | --- | --- | --- |
| 代码 / 技术文档 | Markdown parser + code fence / AST | 标题小节 + code block 附近解释 | 函数、配置项、段落 | `code_language`、`symbol`、`file_path` |
| Markdown / Wiki | Markdown / HTML parser | section | 段落、列表项 | `section_path`、`heading_level` |
| OCR 扫描件 | OCR + layout parser | 页面 / 章节 | 清洗后段落 | `ocr_confidence`、`bbox`、`page` |
| 表格密集 | table extractor | table / logical table region | row chunk / table summary | `table_id`、`row_id`、`column_ids` |
| FAQ | Q/A parser | FAQ item | question variants + answer | `question_id`、`intent` |
| 政策 / 合同 | section / clause parser | 条款组 | 条款、例外、定义 | `clause_id`、`valid_from`、`valid_to` |
| SOP / Runbook | step parser | 阶段 / 任务 | step + 前置条件 | `step_id`、`phase`、`risk_level` |

这个表才是真正的工程入口。  
你不需要一上来把所有链路都做到极致，但至少要让系统承认：

`不同文档有不同的知识形状。`

### 10. Parent-Child 双层索引：为什么它经常是质量跃迁点

这部分非常值得吃透。

Parent-Child 的直觉其实很简单：

- 小块检索更准
- 大块上下文更全

那为什么不两者都要？

这就是 Parent-Child 的核心思路：

1. 先把文档切成较大的 parent chunk，尽量保持主题完整。
2. 再把每个 parent chunk 切成较小的 child chunk，用来做高精度检索。
3. 查询时，先在 child 上检索；命中后，再返回对应的 parent 给生成模型。

它解决的是一个长期存在的矛盾：

- 如果只存小块，召回准，但上下文容易碎。
- 如果只存大块，上下文全，但召回精度差。

Parent-Child 让你在“检索精度”和“回答完整性”之间建立桥梁。

```mermaid
flowchart TD
    A["原始文档"] --> B["Parent Chunk (1500 tokens)"]
    B --> C1["Child Chunk 1 (300 tokens)"]
    B --> C2["Child Chunk 2 (300 tokens)"]
    B --> C3["Child Chunk 3 (300 tokens)"]
    Q["用户问题"] --> D["先在 Child 上检索"]
    C1 --> D
    C2 --> D
    C3 --> D
    D --> E["命中 Child 所属的 Parent"]
    E --> F["把 Parent 作为完整上下文返回"]
```

#### 10.1 Parent-Child 带来的真实好处

- 用户搜一个很具体的小点时，小块更容易命中
- 生成答案时，不必只拿到一句孤零零的话
- 对于配置、示例、解释型文档特别有效

#### 10.2 它也有成本

当然，它不是免费的：

- 需要维护 parent-child 关联关系
- 索引更复杂
- 去重、回源、聚合逻辑更复杂

但如果你的系统主要是“知识解释”“配置说明”“技术问答”，Parent-Child 往往比单层 chunk 更稳。

### 11. Chunk 不只是文本：metadata 设计往往和切分同样重要

很多人谈 chunk，只谈正文文本。  
但真实系统里，`metadata` 常常和 chunk 本文一样重要。

至少应该问自己：

- 这个 chunk 来自哪篇文档？
- 来自哪一页、哪一章、哪个标题？
- 是否属于某个租户、某个权限域？
- 是否是代码块、表格、标题、正文？
- 创建时间、版本号、更新时间是什么？

这些信息的价值体现在四个地方：

1. **过滤**
   - 只搜某个产品线
   - 只搜最新版制度
   - 只搜自己有权限的知识

2. **排序**
   - 同分情况下优先新版本
   - 同分情况下优先标题命中

3. **解释**
   - 让答案附带来源页码、章节、文档名

4. **运维**
   - 文档更新时知道该重建哪些 chunk
   - 某篇文档解析异常时可以回溯

所以你可以记住一句话：

`chunk 设计 = 文本切分 + metadata 建模`

### 12. 特殊内容处理：代码、表格、PDF 才是真正的坑王

如果你的知识库只处理纯正文，那已经很幸福了。  
真实业务里最难搞的往往是这三类：

- 代码文档
- 表格文档
- 复杂 PDF

#### 12.1 代码块：不能把语法结构随便切断

代码文档有几个特殊性：

- 一个函数、一个类、一个 YAML 配置片段通常必须整体理解
- 注释和代码语义是配套的
- 缩进本身就是语义（Python、YAML）

所以对代码内容，常见策略是：

- 先识别 fence code block
- 尽量把整个代码块作为一个单元保护起来
- 如果代码块超大，再按函数、类、配置段做二次切分

这件事本质上不是“文本切分”，而是“语法边界切分”。

#### 12.2 表格：文本检索对它天然不友好

表格难点在于它的信息不是线性叙述，而是二维结构。

常见处理方式各有缺点：

- 转 Markdown：简单，但复杂格式会丢
- 转 JSON：结构清晰，但 token 占用大
- 保留 HTML：结构在，但 embedding 和检索效果不稳定

一个实用折中方案通常是：

- 简单表格：转成 Markdown
- 复杂表格：提取表头 + 摘要描述 + 原始引用链接
- 关键数据表：单独存储为结构化数据源，不完全依赖 RAG

#### 12.3 PDF：真正难的是“你看到的结构”和“解析出来的结构”不是一回事

复杂 PDF 里最常见的问题：

- 页眉页脚重复
- 双栏布局打乱阅读顺序
- 标题层级丢失
- 表格被拆成碎文本
- OCR 结果噪声极大

这就是为什么很多团队会在“切分策略”上纠结半天，其实问题根源在更上游：**解析就已经错了。**

所以 chunk 之前一定要建立一个意识：

`切分质量依赖于解析质量。`

如果解析结果乱序、噪声重、标题结构丢失，再高级的切分策略也救不回来。

### 13. Late Chunking：为什么它看起来像下一代思路

Late Chunking 这几年很火，因为它试图倒过来做一件事：

- 传统流程：先切，再给每个 chunk 做 embedding
- Late Chunking：先得到更完整上下文下的 token-level 表示，再决定边界，再生成 chunk embedding

它的吸引力在于：

`chunk 的向量表示不再只看自己这小块，而是在更大上下文中形成。`

这对以下场景很有帮助：

- 学术论文
- 法律条文
- 强上下文依赖的长说明文档

因为这些内容常常需要“周围上下文”才能正确理解当前片段的语义。

#### 13.1 先用一个例子把问题讲透

假设原文是这样：

```text
柏林是德国的首都，也是该国最大的城市。
它拥有约 370 万人口，是欧洲重要的政治与文化中心。
这座城市的公共交通系统由地铁、轻轨、公交和区域铁路组成。
```

如果你先切 chunk：

```text
chunk A：柏林是德国的首都，也是该国最大的城市。
chunk B：它拥有约 370 万人口，是欧洲重要的政治与文化中心。
chunk C：这座城市的公共交通系统由地铁、轻轨、公交和区域铁路组成。
```

然后分别 embedding：

```text
embed(chunk A)
embed(chunk B)
embed(chunk C)
```

问题来了：  
`chunk B` 里只有“它”，`chunk C` 里只有“这座城市”。  
人能从上文知道它们指柏林，但 embedding model 单独看 `chunk B` / `chunk C` 时，不一定能知道。

于是用户问：

```text
柏林人口是多少？
```

`chunk B` 本来应该很相关，但它的 embedding 可能没有强烈的“柏林”语义。  
这就是传统 chunking 的上下文丢失问题。

Late Chunking 想解决的正是这个：

`不要让 chunk 在完全失去上文的情况下单独形成向量。`

#### 13.2 它到底“late”在哪里

很多人第一次听 Late Chunking，会误以为：

```text
先不切文档，最后再切文本。
```

这个理解不够准确。

Late Chunking 不是不要边界。  
它仍然需要边界，比如句子、段落、标题、token offset。  
只是这个边界使用得更晚。

传统做法：

```text
1. 先按边界把文本切成 chunk
2. 每个 chunk 独立进入 embedding transformer
3. 每个 chunk 内部 token 做 pooling
4. 得到每个 chunk embedding
```

Late Chunking：

```text
1. 先记录 chunk 边界，例如每个 chunk 对应哪些 token offset
2. 把更长的一段文本整体送进 long-context embedding transformer
3. transformer 输出每个 token 的 contextual representation
4. 再按刚才记录的 chunk 边界，对 token representations 做 pooling
5. 得到每个 chunk embedding
```

也就是说：

`chunk 边界不再决定 transformer 能看到多少上下文，而是决定最后对哪些 token 向量做 pooling。`

这句话是 Late Chunking 的核心。

#### 13.3 普通 chunk embedding 和 late chunk embedding 的本质区别

普通 chunking 得到的是相对独立的表示：

```text
vector_B = embedding_model("它拥有约 370 万人口...")
```

Late Chunking 得到的是上下文化表示：

```text
token_reps = embedding_transformer("柏林是德国首都... 它拥有约 370 万人口...")
vector_B = mean_pool(token_reps[token_start_B : token_end_B])
```

两者的 `vector_B` 不一样。

普通 `vector_B` 只知道 chunk B 自己写了什么。  
Late `vector_B` 是在整段文本上下文里形成的，所以“它”对应柏林这个信息有机会被 transformer attention 带进 token representation。

这也是 Jina 文章里说的区别：

- naive chunk embeddings 更接近独立同分布
- late chunk embeddings 是 contextualized / conditional 的

你可以把它想成：

```text
普通 chunking：每个孩子单独考试。
Late chunking：大家先一起读完整篇文章，再分别写自己的摘要。
```

这个比喻不严谨，但直觉很准。

#### 13.4 它和 overlap、parent-child 有什么区别

这三个方法都在补上下文，但补的位置不同。

| 方法 | 在哪里补上下文 | 本质 |
| --- | --- | --- |
| Overlap | 文本切分阶段 | 把相邻文本重复放进 chunk |
| Parent-Child | 检索返回阶段 | child 负责召回，parent 负责给模型读 |
| Late Chunking | embedding 表示阶段 | chunk embedding 在更长上下文里形成 |

Overlap 的问题是重复存储、重复召回。  
Parent-Child 的问题是检索准了，但返回 parent 后可能带来更多噪声。  
Late Chunking 的特点是：它不一定改变返回文本大小，而是改变 child chunk 的向量质量。

举个例子：

```text
用户问：柏林人口是多少？
```

- overlap：希望 chunk B 附近刚好重复到了“柏林”。
- parent-child：先命中 chunk B，再返回包含 A+B+C 的 parent。
- late chunking：chunk B 自己的向量已经带有“柏林”上下文，更容易被召回。

所以 Late Chunking 解决的是：

`召回前的表示问题。`

Parent-Child 解决的是：

`召回后的上下文消费问题。`

两者可以组合。

#### 13.5 它和 Contextual Retrieval 又有什么区别

第 4 节还会讲 Contextual Retrieval，这里先给你一个清晰区分。

Contextual Retrieval 的做法是给 chunk 前面显式加一段背景说明：

```text
背景：本文档介绍柏林的城市概况。
原文：它拥有约 370 万人口，是欧洲重要的政治与文化中心。
```

然后用这段增强文本去做 embedding / BM25。

Late Chunking 不改 chunk 文本，而是改 embedding 生成方式：

```text
原文还是：它拥有约 370 万人口...
但它的 token representation 是在整段文本上下文中算出来的。
```

简单记：

```text
Late Chunking = representation-side contextualization
Contextual Retrieval = text-side contextualization
```

前者对 dense embedding 更直接。  
后者对 dense embedding 和 BM25 都有效，因为它真的把背景文字加进了索引文本。

#### 13.6 一个简化伪代码

普通 chunking 像这样：

```python
chunks = split_text(document)
vectors = [embedding_model.encode(chunk) for chunk in chunks]
```

Late Chunking 的思想像这样：

```python
chunks = split_text_with_offsets(document)

token_ids = tokenizer(document)
token_reps = embedding_model.encode_tokens(token_ids)

vectors = []
for chunk in chunks:
    start, end = chunk.token_start, chunk.token_end
    chunk_token_reps = token_reps[start:end]
    vectors.append(mean_pool(chunk_token_reps))
```

真实实现比这个复杂，因为要处理：

- tokenizer offset mapping
- 长文超过 embedding model context window
- special tokens
- attention mask
- pooling 策略
- batch
- 多文档边界

但核心思想就是这几行：

`先算 token-level contextual representation，再按 chunk offset pooling。`

#### 13.7 它适合什么

Late Chunking 更适合：

- 长上下文 embedding model 可用的系统
- 学术论文、报告、法律、政策、技术说明这类上下文依赖强的长文
- 需要 dense retrieval 质量更高的离线索引
- chunk 中有大量代词、省略、跨段引用的文档
- 预算允许更复杂 embedding pipeline 的系统

尤其适合这种情况：

```text
chunk 本身短，但它的正确语义依赖前后文。
```

比如：

- “该方案在第二阶段启用。”
- “这项限制仅适用于企业版。”
- “上述服务默认关闭。”
- “它会在 24 小时内失效。”

这些句子单独 embedding 都弱，但在上下文中非常明确。

#### 13.8 它不适合什么

Late Chunking 不太适合：

- 没有 long-context embedding model 的系统
- 文档极长且无法合理分段的场景
- 主要靠 BM25 / keyword retrieval 的系统
- 表格、代码、结构化数据为主的文档
- 实时 ingestion、低成本、低延迟要求特别强的系统
- 解析质量很差的 OCR 文档

注意最后一点：Late Chunking 不会修复坏解析。  
如果 PDF 阅读顺序已经乱了，表格已经碎了，Late Chunking 只是在乱文本上做更复杂的表示。

#### 13.9 它为什么还没成为默认工程方案

主要有四个原因：

1. 成本更高  
   它依赖 long-context embedding，一次编码更长文本，离线索引成本更高。

2. 工程链路更复杂  
   你需要保存 chunk token offsets，并在 transformer 输出后做 pooling。

3. 模型支持有限  
   不是所有 embedding API 都暴露 token-level representations。很多托管 embedding API 只返回整段向量。

4. 对某些文档类型收益有限  
   代码、表格、FAQ、结构化字段，很多时候结构处理比 late chunking 更重要。

所以你可以把它理解成：

**效果上很有前景，但目前更偏高质量离线索引构建手段，而不是低成本普适方案。**

#### 13.10 工程上怎么选

如果你现在做企业知识库，我会这样排序：

1. 先做好解析和结构化切分。
2. 加 parent-child 或 sentence window，解决“召回小块、回答要上下文”的问题。
3. 加 metadata filter、hybrid retrieval、rerank、citation。
4. 如果长文 dense retrieval 仍然弱，再考虑 Late Chunking。

换句话说：

`Late Chunking 是增强 chunk embedding 的高级手段，不是替代文档解析和结构切分的捷径。`

### 14. 从信息论和优化视角看 chunk：为什么这不是纯拍脑袋

如果从理论上抽象，chunk 切分本质上是一个文本分割优化问题。

你希望达到的理想状态大概是：

- chunk 内部尽量语义连贯
- chunk 之间尽量边界清晰
- 尽量不要在语义强关联的位置切断
- 同时还要兼顾成本、索引规模和上下文预算

如果借用一个更抽象的目标函数，切分质量可以被理解成三种力量的平衡：

```text
Q = α * Coherence + β * Coverage - γ * Redundancy
```

其中：

- `Coherence`：块内语义是否连贯
- `Coverage`：相关信息是否能在合理块内被完整保留
- `Redundancy`：块间重复是否过高

这不是说你真的要在线上去求解这个公式，而是提醒你：

`chunk 优化从来不是单指标优化。`

你不可能只优化召回率、不看成本；  
也不可能只压缩 token、不看回答完整性。

### 15. 如何评估 chunk 切得好不好：不要只凭体感

这是最容易被忽略、但最该制度化的一部分。

很多团队优化 chunk 的方式是：

- 改个参数
- 问几个人“感觉好像变准了”
- 然后上线

这很危险。  
因为 chunk 的变化影响面非常广，靠体感容易误判。

#### 15.1 检索层评估

至少要看：

- Precision@k
- Recall@k
- MRR
- nDCG

其中 MRR 很重要，因为它能反映：  
**第一个真正相关结果是否足够靠前。**

这是 RAG 体验的关键指标之一。

#### 15.2 生成层评估

检索好了，不代表答案就一定好。  
所以还要看：

- faithfulness
- answer relevancy
- context precision
- context recall

像 RAGAS 这样的框架可以帮你快速建立这类评估。

#### 15.3 端到端评估

最终最重要的还是：

- 用户真实问题
- 对应标准答案或参考答案
- 端到端打分

很多时候一个 chunk 策略在离线检索指标上更好，但在真实问答里并没有明显收益。  
这通常意味着：

- 检索优化没有传导到生成
- 或者生成策略本身把召回优势抵消了

#### 15.4 在线指标

生产环境里至少建议长期监控：

- chunk 大小分布
- 文档解析失败率
- embedding 处理时延
- 检索空结果率
- topK 结果去重率
- 用户点击引用率
- 用户反馈分数
- 回答拒答率

如果你的平均 chunk size 突然从 500 token 掉到 200 token，往往说明上游解析结构变了，而不是“系统突然更聪明了”。

### 16. 生产环境怎么落地：chunk 不是一个函数，而是一条处理流水线

更贴近后端系统的视角，一条完整的 chunk 流水线通常长这样：

```mermaid
flowchart TD
    A["原始文档入库"] --> B["文档解析"]
    B --> C["清洗与结构提取"]
    C --> D["文档分类"]
    D --> E["选择切分策略"]
    E --> F["Chunk 生成"]
    F --> G["Metadata 补全"]
    G --> H["Embedding 计算"]
    H --> I["索引写入"]
    I --> J["质量校验与抽样评估"]
```

这条链里每一层都可能出问题：

- 解析错
- 清洗过度
- 分类误判
- chunk 过碎
- metadata 缺失
- embedding 模型切换不兼容
- 索引写入不完整

这也是为什么成熟系统里，chunk 不应该只是某个“工具函数”，而应该是一个可观察、可回放、可重建的 pipeline。

### 17. 工程里最常见的问题，以及怎么定位

这一节很重要，尽量把“出事后怎么看”提前建立起来。

#### 17.1 检索命中但答案残缺

典型原因：

- chunk 太小
- 标题与正文分离
- 配置或示例跨块被切开

优先排查：

- 是否需要增大 chunk
- 是否应该启用 Parent-Child
- 是否需要改成按结构边界切

#### 17.2 检索总是偏题

典型原因：

- chunk 太大，主题混杂
- metadata filter 没有限制范围
- embedding 模型对领域术语表达不佳
- rerank 缺失

优先排查：

- 缩小 chunk
- 补 metadata
- 增加混合检索和 rerank

#### 17.3 成本高得离谱

典型原因：

- overlap 太大
- chunk 太多太碎
- topK 太高
- prompt 去重和合并做得差

优先排查：

- 减少重复
- 调低 topK 并引入 rerank
- 合并相邻 chunk

#### 17.4 文档更新后效果漂移

典型原因：

- 只更新原文，没有增量更新 chunk 与 embedding
- 文档结构变化导致切分分布突变

优先排查：

- 建立版本号
- 文档更新触发重切分
- 增量索引重建

### 18. 如何按文档类型和查询类型做策略选择

到这里，你应该已经能接受一个事实：

`没有全场景通吃的最佳 chunk size。`

真正实用的是建立一个策略矩阵。

#### 18.1 按文档类型

**技术文档**

- 推荐：500 到 800 token
- overlap：10% 到 15%
- 优先按标题、段落、代码块切

**新闻文章**

- 推荐：300 到 500 token
- overlap：15% 到 20%
- 优先按自然段和句号切

**法律文书 / 规范制度**

- 推荐：600 到 1000 token
- overlap：20% 到 25%
- 强调条款连续性和引用关系

**代码文档**

- 不要只看 token 大小
- 优先按函数、类、配置块边界切

#### 18.2 按查询类型

**事实型查询**

例如：

`某版本号是多少？`

这类问题更偏精确定位，小 chunk 更占优。

**概念型查询**

例如：

`解释一下微服务架构`

这类问题需要连续上下文，大 chunk 或 Parent-Child 更有优势。

**操作型查询**

例如：

`如何配置 XX`

这类问题通常最怕把步骤或代码示例切断，所以中等大小 chunk + 保持示例完整性最重要。

### 19. 工具体验：不要把框架默认参数当行业标准

这部分值得单独说，因为很多坑不是算法本身的问题，而是你“相信了框架默认值”。

更准确地说，chunk 工具选择不是在问：

`“LangChain、LlamaIndex、Unstructured 哪个更高级？”`

而是在问：

`“我现在缺的是解析能力、切分能力、节点组织能力，还是整条 ingestion pipeline 的治理能力？”`

这几个能力不是一回事。

#### 19.1 先分清：工具到底解决哪一层问题

很多团队选型会混乱，是因为把下面几层全叫成“chunk 工具”：

| 层次 | 解决的问题 | 常见工具方向 | 不能指望它解决什么 |
| --- | --- | --- | --- |
| Parser | 把 PDF、Word、HTML、Markdown、代码等转成结构化文本和元素 | Unstructured、专用 PDF/Office parser、Markdown parser、tree-sitter | 不自动保证最终 chunk 策略合理 |
| Splitter | 把已经解析好的文本按规则切成块 | LangChain text splitters、自研 splitter | 不负责复杂版面恢复和权限建模 |
| Node / Index Framework | 组织 document、node、metadata、关系和索引流程 | LlamaIndex、LangChain retriever 生态 | 不替你判断文档语义边界 |
| Domain Chunker | 按业务结构定制切分 | 自研规则、AST、表格抽取、合同条款解析 | 研发成本更高，需要测试和维护 |

所以第一步不是选品牌，而是判断：

- 如果输入已经是干净 Markdown 或纯文本，重点是 `splitter`。
- 如果输入是 PDF、扫描件、PPT、Word，重点先是 `parser`。
- 如果你需要 parent-child、sentence window、node metadata、ingestion pipeline，重点是 `node/index framework`。
- 如果是代码、表格、合同、配置手册，通用 splitter 往往只能打底，最终还是需要 `domain chunker`。

#### 19.2 LangChain：适合快速建立 baseline，但要显式控制规则

LangChain 的 text splitter 很适合做第一版 baseline。

适合用它的场景：

- 文档已经被清洗成纯文本或 Markdown。
- 你想快速比较 `chunk_size`、`overlap`、separator 的效果。
- 项目本来就用了 LangChain 的 loader、retriever、chain 生态。
- 你需要快速把 Demo 变成一个可测的最小闭环。

不适合完全依赖它的场景：

- 原始 PDF 阅读顺序混乱。
- 表格、图片、代码块很多。
- 中文标点和标题层级很重要，但你没有自定义 separator。
- 需要精确保存 page、section、source offset、权限字段。

使用方式上，不要只写：

```python
splitter = RecursiveCharacterTextSplitter()
chunks = splitter.split_text(text)
```

这等于把切分策略交给默认值了。

更稳的做法是显式声明几个东西：

```python
splitter = RecursiveCharacterTextSplitter(
    chunk_size=600,
    chunk_overlap=80,
    separators=[
        "\n## ",
        "\n### ",
        "\n\n",
        "。", "！", "？", "；",
        "\n",
        " ",
        "",
    ],
    length_function=count_tokens,
)

documents = splitter.create_documents(
    texts=[clean_text],
    metadatas=[{
        "doc_id": doc_id,
        "doc_version": doc_version,
        "source": source,
        "chunking_pipeline": "langchain_recursive_cjk_v1",
    }],
)
```

这里有几个关键点：

1. `separators` 要按你的语料调整，中文文档不能只靠英文空格和换行。
2. `length_function` 尽量接目标 embedding / LLM 的 tokenizer，而不是粗暴按字符数。
3. chunk 生成后要补齐 metadata，不然后面引用、回放、权限过滤都会很痛苦。
4. `chunking_pipeline` 要写版本号，方便以后对比和回滚。

LangChain 更像一把好用的刀。
刀本身没问题，但你要知道自己在切肉、切菜，还是切骨头。

#### 19.3 LlamaIndex：适合把 chunk 当成 Node 来管理

LlamaIndex 的优势不只是“也能切文本”，而是它更强调：

- `Document`
- `Node`
- `metadata`
- node relationship
- ingestion pipeline
- index / retriever

如果你的 RAG 系统开始需要 parent-child、sentence window、prev/next 关系，LlamaIndex 的抽象会比单独调用一个 splitter 更自然。

适合用它的场景：

- 你希望 chunk 不只是字符串，而是带关系的 `Node`。
- 你需要保留 section、document、prev/next、parent 等关系。
- 你想快速实验 sentence-level retrieval、window replacement、hierarchical retrieval。
- 你的系统本来就使用 LlamaIndex 做索引和检索编排。

基本用法可以理解成：

```python
documents = [
    Document(
        text=clean_text,
        metadata={
            "doc_id": doc_id,
            "doc_version": doc_version,
            "source": source,
        },
    )
]

node_parser = SentenceSplitter(
    chunk_size=700,
    chunk_overlap=100,
)

nodes = node_parser.get_nodes_from_documents(documents)
```

这类代码的重点不是 API 本身，而是思想：

- 原始文档先进 `Document`
- 切出来的是 `Node`
- `Node` 继承或携带 metadata
- 后续检索、rerank、引用都围绕 node 做

如果要做 Parent-Child，落地时通常会变成两层：

```text
原始文档
-> parent node：按标题 / section 切，保持语义完整
-> child node：在 parent 内继续切，用来做高精度召回
```

检索时：

1. 用 child node 做 embedding 检索。
2. 命中 child 后，通过 `parent_id` 找到 parent。
3. 最终给模型的上下文可以是 child 附近窗口，也可以是 parent section。

这种方式比单层 chunk 更适合：

- 技术文档解释
- 操作手册
- 制度条款
- 长 Wiki 页面

但也要注意一个问题：
如果你的业务系统已经有成熟的数据模型和索引 pipeline，只为了切 chunk 引入完整 LlamaIndex，可能会让工程栈变重。

#### 19.4 Unstructured：适合解决复杂文档解析，不等于最终 chunk 策略

Unstructured 的价值主要在 parser 侧。

它适合处理：

- PDF
- Word
- PPT
- HTML
- 带标题、列表、表格、页码、版面元素的复杂文档

它的强项不是“神奇地给你最佳 chunk size”，而是先把文档拆成更接近人类阅读结构的元素，例如：

- Title
- NarrativeText
- ListItem
- Table
- Header / Footer
- PageBreak

这对 chunk 非常重要。
因为如果 parser 已经把标题、正文、表格、页码都混成一坨，再高级的 splitter 也只是在坏输入上努力。

更稳的使用方式通常是两段式：

```text
原始文件
-> Unstructured partition，得到 element 列表
-> 自己根据 element type、title hierarchy、page metadata 做 chunk
```

而不是：

```text
原始文件
-> Unstructured 一键 chunk
-> 直接入库
```

如果使用它自己的 chunking strategy，也要先明确策略含义：

- `basic` 更像把相邻元素合并到目标大小以内。
- `by_title` 更强调标题边界，适合标题结构可靠的文档。
- `by_similarity` 会引入语义相似度判断，适合主题跳变明显的长文，但成本和可解释性都要评估。

使用时建议至少保留这些 metadata：

```json
{
  "doc_id": "policy_123",
  "doc_version": "v7",
  "page_number": 12,
  "element_id": "el_891",
  "element_type": "Table",
  "section_path": ["报销制度", "差旅标准", "住宿上限"],
  "chunking_pipeline": "unstructured_partition_custom_chunk_v2"
}
```

这样后面才能做：

- page 级引用
- 表格行定位
- 文档版本回放
- 按 element type 分析效果
- 针对 PDF 解析异常做排查

Unstructured 的典型坑也很明确：

- 高精度解析慢，成本高。
- 扫描 PDF 依赖 OCR，错误会被后续链路放大。
- 表格抽取不稳定时，chunk 看起来完整，实际语义已经错了。
- 页眉页脚如果没清理，会污染大量 chunk。

所以它更适合作为复杂文档入口，不应该被当作“最终 chunk 策略的唯一裁判”。

#### 19.5 一个实际选型矩阵

可以按下面这个方式快速判断：

| 场景 | 推荐起点 | 原因 |
| --- | --- | --- |
| 纯文本、Markdown、简单 Wiki | LangChain splitter 或自研递归 splitter | 成本低，容易调参，容易做 baseline |
| 标题层级清楚的内部文档 | Markdown / HTML parser + section-aware chunker | 标题结构比固定 token 更重要 |
| PDF、Word、PPT | Unstructured / 专用 parser + 自研 chunker | 先恢复结构，再谈切分 |
| 代码仓库 | tree-sitter / AST-aware chunker | 函数、类、配置块边界比 token 数重要 |
| 表格密集文档 | 表格抽取 + row chunk + table summary | 普通文本 splitter 很容易切坏表头和单位 |
| 需要 parent-child、sentence window、node 关系 | LlamaIndex 或自研 Node 模型 | 重点是节点关系和上下文回填 |
| 已有成熟后端 pipeline | 自研 chunker + 少量工具库 | 避免为了框架重写数据链路 |

这里最容易犯的错是：
因为某个框架 Demo 很顺手，就把所有文档都塞进同一套默认 splitter。

生产里更常见的做法应该是：

```text
document profile
-> 判断文档类型
-> 路由到不同 parser
-> 路由到不同 chunk strategy
-> 输出统一 Chunk schema
```

也就是说，工具可以不同，但最后进入索引的 chunk schema 要统一。

#### 19.6 工具落地时怎么用：先验收输出，再接向量库

不管选哪个工具，都不要一上来就接 embedding 和向量库。
正确顺序应该是：

1. 抽 50 到 100 篇代表性文档。
2. 跑 parser 和 chunker。
3. 把 chunk 输出成人能看的 Markdown / JSONL。
4. 人工检查切分结果。
5. 再跑检索评测。
6. 最后才批量入库。

人工检查时重点看这些东西：

- 标题有没有和正文分离。
- 表格有没有丢表头、单位、caption。
- 代码块有没有被切断。
- 步骤说明有没有被拆散。
- chunk 有没有大量页眉页脚、目录、版权信息。
- 中文句子有没有在奇怪位置被切开。
- overlap 有没有制造大量重复 chunk。

工程上还要为每个工具版本留下可观测指标：

```text
chunk_count_per_doc
avg_chunk_tokens
p50/p95_chunk_tokens
empty_chunk_ratio
duplicate_chunk_ratio
table_chunk_ratio
code_chunk_ratio
orphan_title_ratio
oversized_chunk_ratio
```

如果升级框架后这些指标突然变化，就要先怀疑 chunk pipeline，而不是马上怀疑 embedding 模型。

最后给一个很实用的使用原则：

`工具负责提高起点，评测负责决定能不能上线，自研规则负责补齐业务边界。`

换句话说：

- V1 可以用 LangChain / LlamaIndex 快速建立 baseline。
- 复杂 PDF、Office 文档可以用 Unstructured 做解析入口。
- 代码、表格、合同、制度类文档要逐步沉淀专门策略。
- 上线后必须冻结工具版本、记录 pipeline version、保留重建能力。

### 20. 一个更务实的三阶段成长路线

如果你是第一次做 RAG，我更推荐这样的节奏：

#### 第一阶段：先跑通，不做过度优化

- 用结构化递归切分器
- chunk_size 从 500 token 左右起步
- overlap 从 50~80 token 起步
- 跑通索引、检索、回答闭环

目标不是“最好”，而是“先有一个可以测的系统”。

#### 第二阶段：进入优化期

- 分析文档类型
- 建立测试集
- 比较 2~3 种 chunk 方案
- 引入 Parent-Child 或混合策略

目标是把优化从“拍脑袋”变成“有指标支撑”。

#### 第三阶段：进入生产治理期

- 建监控
- 做增量更新
- 做版本回滚
- 做质量抽检
- 做成本治理

目标不是继续卷算法，而是让系统稳定、可持续。

### 21. 这一课真正要建立的底层意识

这一课最重要的不是记住某个参数，而是建立四个意识：

#### 21.1 chunk 是检索单元，不是格式化步骤

它直接定义了系统“看待知识”的颗粒度。

#### 21.2 chunk 优化本质上是一个多目标权衡

你同时在平衡：

- 召回精度
- 上下文完整性
- 成本
- 时延
- 冗余

#### 21.3 chunk 不是独立模块

它和以下东西强耦合：

- tokenizer
- embedding 模型
- topK
- rerank
- prompt 预算
- 文档解析质量

#### 21.4 chunk 的答案永远依赖场景

真正成熟的工程判断，不是背出一句：

`“最佳 chunk size 是 512 token。”`

而是能说出：

`“对这类文档、这类问题、这类成本目标，我为什么选这个策略。”`

## 小结（5 条关键点）

- chunk 是 RAG 的最小检索单元，它的设计会直接影响 embedding、检索、生成三层效果。
- 所有切分策略都在平衡一个悖论：块太小会丢上下文，块太大会稀释语义并增加成本。
- 固定长度切分适合快速验证，但真正工程可用的方案通常要尊重结构边界，并按文档类型分类处理。
- Parent-Child、Late Chunking、表格和代码专门处理，都是在试图缓解“检索精度”和“上下文完整性”的矛盾。
- chunk 优化必须结合离线指标、端到端测试和在线监控，不能只靠体感调参。

## 检查站：请回答以下问题

1. 为什么说 chunk 不是一个“预处理小细节”，而是会决定整条 RAG 链路的上限？
2. 固定长度切分为什么最容易上手，但又最容易埋坑？overlap 为什么不能无限加？
3. Parent-Child 为什么经常能显著改善效果？它真正缓解的是哪一个矛盾？
4. 如果你的系统检索准确率下降了，你会怎么判断问题到底出在 chunk、embedding、检索还是生成？
5. 面对技术文档、法律文书、新闻文章这三类数据，你会怎么设计不同的 chunk 策略？
6. 如果你的知识源同时包含 Markdown、PDF、代码仓库和表格，你会怎么选择 LangChain、LlamaIndex、Unstructured 或自研 chunker？上线前你会检查哪些 chunk 输出指标？
