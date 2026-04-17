# DDIA - 第 4 课补充：Avro 与 Protobuf 怎么选

## 学习目标（本节结束后你能做到什么）

- 不再把 Avro 和 Protobuf 理解成"两个差不多的二进制序列化格式"。
- 能说清楚它们设计重点的差异：谁更偏服务通信，谁更偏数据管道与模式演化。
- 理解为什么很多团队在 `RPC` 场景偏向 Protobuf，而在 `Kafka/数仓/流处理` 场景更常选 Avro。
- 掌握两者的历史渊源、设计哲学、wire format 差异和 schema 演化规则。
- 遇到一个具体系统时，能从通信方式、数据生命周期、消费者数量、schema 演化频率四个维度做判断。
- 知道两者没有绝对高下，而是分别在不同"系统摩擦点"上做了优化。
- 了解 Thrift、FlatBuffers、Cap'n Proto 等替代方案的定位。

## 内容讲解（核心概念，用类比、例子、图示说清楚）

### 0. 先看历史：两者为什么长成今天这样

要理解 Avro 和 Protobuf 的差异，不能脱离它们的出生环境。

#### Protobuf 的出身：Google 内部 RPC（2001）

- 2001 年 Google 内部发明，2008 年开源。
- 最初动机：Google 有几千个内部服务需要高效通信，每个请求必须紧凑、快、跨语言。
- 设计假设：**客户端和服务端都由 Google 统一控制**——schema 的变更可以走统一的发布流程，代码生成可以作为 build 的一部分。
- 演化出的生态：gRPC（2015 年开源）、Envoy（xDS 协议基于 protobuf）、Google Cloud APIs。

#### Avro 的出身：Hadoop 生态（2009）

- 2009 年由 Doug Cutting（Hadoop 创始人）在 Apache Hadoop 项目中设计。
- 最初动机：Hadoop MapReduce 任务和 HDFS 文件需要跨时间、跨版本读取——一个数据集今天产生，可能三年后被新的查询引擎读。
- 设计假设：**数据是长期资产，schema 会演化，生产者和消费者不受同一批人控制**。
- 演化出的生态：Kafka + Schema Registry、Flink/Spark 的 Avro 数据源、Hadoop SequenceFile、Parquet（内部结构参考了 Avro）。

#### 还有第三位玩家：Thrift（Facebook 2007）

历史完整性要求：Thrift 比 Protobuf 和 Avro 都早，Facebook 2007 年开源。它的设计目标和 Protobuf 几乎一样（跨语言 RPC），但设计哲学稍保守（内置了完整的 RPC 框架，而不是让用户自己配）。今天 Thrift 的存在感主要在：

- Facebook/Meta 内部（仍在用）
- Apache Cassandra（服务端用 Thrift 做过 RPC，后改为 native protocol）
- Evernote、LinkedIn 早期用过
- Uber 2014 年到 2016 年从 Thrift 迁到 gRPC 的公开 blog 是研究两者差异的经典材料

**为什么 Protobuf 打败了 Thrift？** 主要不是技术——是 Google 的 gRPC 生态（负载均衡、服务发现、流式 RPC、拦截器、多语言支持）压倒了 Thrift 相对孤立的 RPC 框架。

#### 还有"零拷贝阵营"：Cap'n Proto 和 FlatBuffers

这两个是 **Protobuf 设计者本人** Kenton Varda 和 **Google 游戏团队** 后来反思 Protobuf 的产物：

- **Cap'n Proto**（2013）：Kenton Varda 离开 Google 后做的。核心卖点是 **zero-copy**——数据在内存里的布局就是 wire format，读取时不需要反序列化。适合游戏、高频交易。
- **FlatBuffers**（Google 2014）：Google 游戏团队专门为移动游戏做。类似零拷贝，但更轻。Protobuf 在手机游戏里反序列化成本太高，所以 Google 内部另起炉灶。

"为什么不用 Protobuf 做游戏？"——答案是：每帧 16ms 的预算里，反序列化几千个对象的 CPU 成本太大。这暴露了 Protobuf 的一个隐性成本：反序列化 **必须** 拷贝和重建对象。

这些替代方案的存在提醒我们：**没有银弹**，不同约束下最优解不同。

### 1. 先给结论：两者都好用，但优化目标不一样

如果你只想先记一个非常实用的结论，可以先记这句：

- **Protobuf 更像"服务之间高效说话的语言"**
- **Avro 更像"跨时间、跨系统传递数据的协议"**

这句话不严格，但很有用。

为什么这么说？

因为在工程里，数据有两种很不一样的使用方式：

1. 现在发、现在收
   比如 A 服务马上调用 B 服务，几十毫秒内就要返回结果。
2. 现在写、以后再读
   比如把消息写进 Kafka，几个小时后被下游消费；或者把数据写入文件，明天给 Spark/Flink/Hive 处理。

这两种场景对格式的要求不一样。

- 第一种更看重：性能、紧凑、代码生成、接口约束、RPC 工具链
- 第二种更看重：schema 演化、跨版本兼容、跨团队消费、长期存储后的可解释性

而 Protobuf 和 Avro 正好分别把重心放在这两个方向上。

#### 1.1 本质差异：schema 在哪里

这是 DDIA 里最精辟的一句总结。两者最本质的差别是：

| 格式 | schema 存在哪 | 每条消息带什么 |
|---|---|---|
| Protobuf | 只存在生成的代码里 | 只带字段 **编号（tag）** + 值 |
| Avro | schema 本身是数据的一部分 | **文件模式**：schema 在文件头，后面是纯数据；**消息模式**：schema ID 在 Schema Registry |

这决定了所有后续差异：

- Protobuf：字段编号是硬契约，代码决定解析能力
- Avro：writer schema + reader schema 协商，运行时做 schema resolution

### 2. Protobuf 的核心思路：先定义接口，再生成代码，再高效通信

Protobuf 的世界观很像这样：

1. 先写一个 `.proto`
2. 明确消息字段和字段编号
3. 通过代码生成器生成各语言的数据结构
4. 服务之间按这个契约传输二进制数据

例如：

```proto
message Order {
  int64 order_id = 1;
  int64 user_id = 2;
  int64 amount = 3;
}
```

#### 2.1 Protobuf 的 wire format 细节

一条 `Order{order_id: 150, user_id: 42, amount: 999}` 在 wire 上大致是这样：

```
tag=1, wiretype=0(varint), value=150  → 0x08 0x96 0x01
tag=2, wiretype=0(varint), value=42   → 0x10 0x2A
tag=3, wiretype=0(varint), value=999  → 0x18 0xE7 0x07
```

总共 9 字节。没有字段名，没有 schema，只有 `(tag, wiretype, value)` 三元组。

wire type 只有 6 种（varint、fixed64、length-delim、group-start/end 已废弃、fixed32）——这就是 Protobuf 的 **所有数据类型** 在线上的实际形态。任何新类型都映射到这 5 种之一。

这个格式最妙的地方：**读取未知字段时，只要知道 wire type 就能跳过它**。所以旧版本解析新版本的消息时，看到不认识的 tag 依然能解析——这就是 Protobuf 向前兼容的物理机制。

它的感觉很像：

- 我们先把协议谈清楚
- 然后大家按这份协议生成代码
- 以后通信就按这个强约束接口走

这很适合服务间通信，因为：

- 类型很清晰
- 生成代码后开发体验好
- 和 `gRPC` 配合非常自然
- 二进制紧凑，网络传输效率高

所以很多团队在这些场景会优先想到 Protobuf：

- 微服务 RPC
- 内部高频接口通信
- 移动端和服务端之间追求体积与性能的场景
- 需要强类型 SDK 的系统

### 3. Avro 的核心思路：writer schema 和 reader schema 要能协商

Avro 的世界观和 Protobuf 不太一样。
它更关注的问题是：

**一份数据被写出去之后，未来由另一个版本、另一个程序、另一个团队来读时，还能不能解释得通。**

Avro 很强调两个角色：

- writer schema：写数据时使用的 schema
- reader schema：读数据时使用的 schema

然后由系统去做 schema resolution，也就是：

**写的时候的结构，和读的时候的结构不完全一样时，能不能合理对齐。**

#### 3.1 Avro 的 wire format 细节

```json
{
  "type": "record",
  "name": "Order",
  "fields": [
    {"name": "order_id", "type": "long"},
    {"name": "user_id", "type": "long"},
    {"name": "amount", "type": "long"}
  ]
}
```

一条相同的 `Order{150, 42, 999}` 在 wire 上是：

```
0x96 0x02  (zigzag-encoded varint for 150)
0x54       (zigzag-encoded varint for 42)
0xCE 0x0F  (zigzag-encoded varint for 999)
```

总共约 5 字节——比 Protobuf 更紧凑，因为 **没有字段编号**，只有值本身按 schema 顺序排列。

但这个紧凑是有代价的：**没有 schema 就完全无法解析**。拿到一串 0x96 0x02 0x54 ... 的字节流，如果没有配套的 schema，你甚至不知道这是 3 个字段还是 30 个字段。

所以 Avro 的两种部署模式：

1. **Avro Object Container File**：一个文件开头写 schema，后面跟数据。适合 HDFS/S3 上的批处理。
2. **Avro + Schema Registry**：消息前 5 字节是 magic byte (0x00) + 4 字节 schema ID，消费者用 ID 去 registry 查 schema。适合 Kafka。

#### 3.2 Schema Resolution 的威力

Avro 的真正卖点。

假设 writer schema 是：

```json
{"fields": [
  {"name": "order_id", "type": "long"},
  {"name": "amount", "type": "long"}
]}
```

reader schema 是（加了一个字段、删了一个字段、字段顺序变了）：

```json
{"fields": [
  {"name": "order_id", "type": "long"},
  {"name": "user_id", "type": "long", "default": 0},
  {"name": "currency", "type": "string", "default": "USD"}
]}
```

Avro 在读时会做：

1. 按 writer schema 解析出 `{order_id, amount}`
2. 与 reader schema 比对
3. `user_id` 在 writer 里没有 → 用 reader 的 default 0
4. `currency` 在 writer 里没有 → 用 reader 的 default "USD"
5. `amount` 在 reader 里没有 → 丢弃
6. 返回 `{order_id, user_id=0, currency="USD"}`

这个过程叫 **schema resolution**。它让"读者和写者用不同 schema 版本"这件事在协议层就被优雅处理。

这个思路对下面这些场景特别重要：

- Kafka 多个消费者长期订阅同一类事件
- 数据被写入对象存储、HDFS、湖仓，过几天再被批处理读取
- 一个 topic 会被很多团队接入，各自升级节奏不同
- schema 变化频率不低，但你不想每次都强依赖重新生成并统一发布代码

所以 Avro 常和这些生态一起出现：

- Kafka + Schema Registry
- Flink / Spark
- 数据仓库 / 数据湖 / 批处理任务

### 4. 两者最本质的区别，不在"谁更快"，而在"谁把复杂度放在哪里"

这句话很关键。

很多初学者比较 Avro 和 Protobuf，第一反应是：

- 谁更快？
- 谁更省空间？

这当然重要，但通常不是第一决策点。
更关键的是：

**它们把系统复杂度分配到了不同地方。**

#### 4.1 Protobuf 把复杂度更多放在"接口管理和代码生成"上

Protobuf 的风格是：

- 先把 schema 定得比较明确
- 靠字段编号保证兼容性
- 靠编译生成代码提升开发体验
- 让调用双方都尽量在编译期知道自己在处理什么

好处是：

- 开发体验强
- 类型安全感更好
- 服务接口很稳定
- 和 RPC 框架天然适配

代价是：

- schema 变更纪律要严格
- 字段编号不能乱动
- 很依赖代码生成和发布流程
- 如果一个数据事件被很多异步系统消费，管理起来未必最顺手

#### 4.2 Avro 把复杂度更多放在"schema 解析与演化规则"上

Avro 的风格是：

- 更关注不同版本 schema 之间如何互相读懂
- 倾向把 schema 管理放到数据管道层
- 允许读写双方不完全同步升级

好处是：

- 很适合长期演化的数据流
- 很适合一份数据被多个下游消费
- 和数据平台生态结合好
- schema registry 场景非常自然

代价是：

- 纯应用开发体验往往不如 Protobuf 那么"顺手"
- 在很多后端业务团队里，心智模型不如 Protobuf 直观
- 如果你的场景只是简单 RPC，它可能有点"偏重"

#### 4.3 两者的哲学差异一句话

可以这样记：

- **Protobuf = 接口契约 first**（schema 是参与方之间的合同）
- **Avro = 数据自描述 first**（schema 是数据的一部分）

这是 DDIA 第 4 章的关键分类。

### 5. Schema 演化规则对比：它们允许什么、禁止什么

这是工程里最容易踩坑的地方。

#### 5.1 Protobuf 的演化规则

| 操作 | 是否允许 | 注意事项 |
|---|---|---|
| 添加新字段 | 允许 | 必须给新字段分配 **从未用过** 的 tag 编号 |
| 删除字段 | 允许 | 一定要把 tag 编号标记 `reserved`，避免将来复用 |
| 改字段名 | 允许 | 字段名不在 wire 上，只影响代码 |
| 改 tag 编号 | **绝对禁止** | 旧 client/server 会把它解析成别的字段 |
| 改字段类型 | **几乎都危险** | 个别"兼容"变化允许（int32 ↔ int64 ↔ bool），但要谨慎 |
| 改 `optional` ↔ `required` | Proto2 危险；Proto3 无 required | Proto3 废除 required 就是为了避免这个坑 |
| 改 `repeated` ↔ 单值 | 危险 | wire 布局不同 |

Protobuf 的所有兼容性 **依赖于字段 tag 编号的严格纪律**。一旦 tag 被污染，生产环境的向下兼容会立刻崩塌。

**真实事故**：某家公司删除了 tag=5 的字段，半年后又在同一个 proto 里添加新字段，复用了 tag=5——旧版本 client 发出的流量到新版本 server 上，tag=5 的数据被错误解析成新字段，出现了"用户余额被反序列化成用户头像 URL"的荒谬结果。

所以规范的 Protobuf 实践是：**删除字段必须 `reserved`**：

```proto
message Order {
  reserved 5, 8 to 11;
  reserved "old_field_name";
  int64 order_id = 1;
  // ...
}
```

#### 5.2 Avro 的演化规则

Avro 有 **BACKWARD / FORWARD / FULL** 三种兼容模式：

- **BACKWARD**：新 schema（reader）能读旧数据（writer）
- **FORWARD**：旧 schema（reader）能读新数据（writer）
- **FULL**：两个方向都兼容

Confluent Schema Registry 还有 **TRANSITIVE** 变体（不仅和上一版兼容，要和所有历史版本兼容）。

Avro 允许的演化：

| 操作 | BACKWARD | FORWARD | FULL |
|---|---|---|---|
| 添加有 default 的字段 | ✅ | ❌ | ❌ |
| 添加没有 default 的字段 | ❌ | ❌ | ❌ |
| 删除有 default 的字段 | ❌ | ✅ | ❌ |
| 改字段类型（promote，如 int→long） | ✅ | ❌ | ❌ |
| 改字段类型（demote，如 long→int） | ❌ | ✅ | ❌ |
| 改字段 alias | ✅ | ✅ | ✅ |
| 改字段顺序 | 无影响 | 无影响 | 无影响 |

**关键观察**：Avro 的"添加字段必须有 default"本质上是 BACKWARD 兼容的约束——这样旧数据没有这个字段时，reader 可以用 default 补齐。

#### 5.3 两种模式的演化复杂度比较

看起来 Avro 规则更复杂，但实际操作中：

- Protobuf：规则简单（不删 tag），但一旦破坏就是悄无声息的数据错误
- Avro：规则明确，Schema Registry 在提交新 schema 时会自动校验，违规被直接拒绝

所以 **Avro 的复杂度前置到了治理层**（Schema Registry 强制校验），而 **Protobuf 的复杂度后置到了规范执行**（依赖团队纪律）。

对大团队来说，前置的强制校验通常比人工纪律靠谱得多。这就是为什么 LinkedIn、Airbnb、Uber 的数据平台都选了 Avro + Schema Registry 的组合。

### 6. Schema Registry：Avro 真正的杀手锏

Schema Registry 是 Confluent 给 Kafka 生态写的一个独立服务，已经成为 Kafka + Avro 的事实标准。核心职责：

1. **集中存储所有 schema 版本**（每个 subject 有版本历史）
2. **校验新 schema 的兼容性**（BACKWARD/FORWARD/FULL 配置在 subject 级别）
3. **给每个 schema 分配全局唯一 ID**（4 字节 int）
4. **提供 REST API 给生产者和消费者查询**

#### 6.1 消息的物理格式

Kafka 上一条 Avro 消息看起来是：

```
┌──────────┬─────────────┬─────────────────┐
│ 0x00     │ schema ID   │ Avro payload    │
│ 1 byte   │ 4 bytes     │ variable        │
└──────────┴─────────────┴─────────────────┘
```

- 第 1 字节是 magic byte（固定 0x00）
- 后 4 字节是 schema ID
- 后面是纯 Avro 编码的数据

消费者收到消息后：
1. 解析出 schema ID
2. 从本地缓存或 Schema Registry 查对应 schema
3. 用这个 writer schema + 自己的 reader schema 做 resolution
4. 得到对象

#### 6.2 Subject Naming Strategy

Schema Registry 里同一个 Kafka topic 可以绑定多个 schema 版本，通过 **subject** 管理。Confluent 提供三种策略：

1. **TopicNameStrategy**（默认）：subject 名 = topic 名 + `-value` / `-key`。一个 topic 只允许一种消息类型。
2. **RecordNameStrategy**：subject 名 = 记录的 full name。允许不同类型的消息进入同一 topic（需要 multi-tenant 场景）。
3. **TopicRecordNameStrategy**：组合方案。

选错 naming strategy 是工程里常见的坑——一旦选定很难改回去。

#### 6.3 真实案例：LinkedIn 的 Kafka + Avro 故事

LinkedIn 是 Kafka 的原始作者团队（Jay Kreps、Neha Narkhede、Jun Rao 等后来创办了 Confluent），也是 Avro 最早的大规模用户之一。他们 2015 年的 blog *Stream Data Platform* 讲了为什么选 Avro：

> "LinkedIn 数据管道每天处理上千亿条消息，涉及几千个 schema、几百个应用团队。我们必须让每个团队独立演化 schema，同时保证全局兼容性——Avro + Schema Registry 是目前我们找到的唯一可行方案。"

LinkedIn 内部的 schema 校验规则甚至比 FULL 更严格，自动拒绝破坏性变更。这套治理能力成为后来 Confluent 开源的 Schema Registry 的原型。

### 7. 从四个最实用的维度来选

下面这个判断框架是最值得带走的。

#### 7.1 维度一：你的数据是在"调用"里用，还是在"管道"里用

如果是下面这种：

- 服务 A 调服务 B
- 追求低延迟
- 接口相对稳定
- 请求来了马上处理，处理完马上返回

通常更偏向 Protobuf。

如果是下面这种：

- 事件写进 Kafka
- 后面会被多个系统消费
- 数据会保存较长时间
- 下游升级节奏不一致

通常更偏向 Avro。

一句话：

- **同步接口，看 Protobuf**
- **异步事件流，看 Avro**

这不是铁律，但命中率很高。

#### 7.2 维度二：你是更在意"代码开发体验"，还是更在意"长期 schema 演化"

Protobuf 往往让业务开发更舒服，因为：

- `.proto` 很清晰
- 生成的类直接可用
- IDE、代码补全、RPC 框架配套成熟

Avro 往往让数据流治理更舒服，因为：

- 它天然更强调 reader schema / writer schema
- 和 Schema Registry 结合更顺
- 更适合"今天的生产者 + 明天的消费者 + 后天的新 schema"这种组合

如果你的团队主要是应用开发团队，且问题集中在接口定义、调用效率、SDK 管理，通常 Protobuf 更顺手。
如果你的团队主要在做数据平台、事件总线、数仓建模、跨团队数据消费，Avro 往往更自然。

#### 7.3 维度三：下游消费者有多少，升级是否同步

这是一个非常实际的决策点。

如果一个消息只有一个调用方和一个被调用方，而且双方由同一个团队维护、版本升级也容易同步，那 Protobuf 完全可以用得很舒服。

但如果一个 topic 后面挂着：

- 风控服务
- 营销服务
- 数仓同步
- 实时报表
- 离线补数任务

这些系统升级节奏都不一样，那你会更希望格式本身更强调 schema 演化与兼容管理。
这时候 Avro 的优势会更明显。

#### 7.4 维度四：你有没有围绕它的工具链

格式本身很重要，但生态经常比格式更重要。

例如：

- 你已经全面用 gRPC 了
  那 Protobuf 的工程收益会很大。
- 你已经有 Kafka + Schema Registry + Flink + Spark
  那 Avro 会非常顺手。

很多时候不是格式孤立决策，而是整条链路已经决定了哪种格式更省事。

### 8. 为什么很多 RPC 团队选 Protobuf，而很多 Kafka 团队选 Avro

这背后不是"社区流行"这么简单，而是因为问题类型不一样。

#### 8.1 RPC 场景为什么偏 Protobuf

RPC 的特点通常是：

- 请求和响应结构相对明确
- 延迟敏感
- 代码生成价值高
- 接口契约希望很清晰
- 业务开发团队直接使用生成代码

Protobuf 在这里非常契合，因为它就像一个强约束接口描述语言。

再加上 gRPC，本质上变成：

- 用 `.proto` 同时定义消息和服务
- 自动生成客户端、服务端代码
- 开发和治理一体化

这就是它在 RPC 领域很强的原因。

**扩展：为什么"RPC + Avro"不是主流**

理论上 Avro 也能做 RPC（Avro 本身有 RPC 协议）。但实际很少用，因为：

- Avro 每条消息都要查 writer schema → 延迟敏感场景增加了一步查询
- RPC 场景下客户端和服务端一般由同一团队控制，不太需要 Avro 的跨版本能力
- gRPC 的工具链（负载均衡、拦截器、流式调用）已经定义了事实标准

#### 8.2 Kafka / 数据平台为什么偏 Avro

Kafka 场景的问题更像是：

- 一个事件会被很多系统消费
- 消息可能会在 topic 中保留一段时间
- schema 会演化
- 同一个事件要给在线、离线、风控、报表多类系统用

这时候问题重点已经不是"我怎么生成一份最舒服的调用代码"，而是：

- 这条事件几年后还读不读得懂？
- 新增字段后旧消费者会不会炸？
- 我能不能通过 schema registry 管住格式变更？

Avro 在这种场景下的匹配度就很高。

**扩展：为什么"Kafka + Protobuf"也有拥趸**

这个组合其实也不少——尤其在 Google 体系里（Pub/Sub + Protobuf）。Kafka + Protobuf 的工具链也在补齐：

- Confluent Schema Registry 从 5.5 开始原生支持 Protobuf 和 JSON Schema
- Kafka Streams 和 Flink 都有 Protobuf 支持

但 Protobuf 在 Kafka 生态里仍然是"次主流"，核心原因是 **兼容性校验规则** 没有 Avro 那么系统——Protobuf 的 tag 纪律需要人守，不像 Avro 能被 registry 强制拒绝破坏性变更。

### 9. 兼容性上它们各自容易踩什么坑

#### 9.1 Protobuf 常见坑

- **改字段编号**：灾难，数据错位
- **删除字段后又复用旧编号**：同上，数据错位
- **把字段语义偷偷改掉**：tag 不变但语义变，比 tag 冲突更阴（编译不报错，运行时全错）
- **Proto2 里把 `required` 去掉**：旧客户端读到没有 required 字段会反序列化失败——这是 Proto3 直接废除 required 的原因
- **`repeated` 字段反序改成单值**：wire type 可能变化
- **`int32` 改成 `uint32`**：某些负数场景会变成大正数
- **跨语言默认值不统一**：Java 的 `int` 默认 0、Go 的 `int32` 默认 0，但对于 `optional string` 不同语言空值表达不一样

规范的 Protobuf 工程实践：

- 所有字段标 `optional`（Proto3.15+）
- 删除字段必须 `reserved`
- 代码 review 时强制检查 tag 变更
- CI 加 `buf breaking` 之类的工具做破坏性变更检测

#### 9.2 Avro 常见坑

- **默认值没设计好**：添加字段时用 `null` default 而不是真正合理的 default
- **schema registry 规则没管住**：默认是 BACKWARD，但团队以为是 FULL
- **改动虽然语法合法，但业务语义不兼容**：比如把"金额（美分）"改成"金额（美元）"——schema 看起来都是 long，但语义完全变了
- **太依赖"自动兼容"，忽略了消费者真实逻辑**：consumer 的代码可能硬编码了某字段名，schema 层面兼容不代表 consumer 不会 NPE
- **union 类型嵌套过深**：Avro 的 union 语法允许 `["null", "string", "int"]`，深嵌套时 schema resolution 非常复杂、调试痛苦
- **logicalType 丢失**：Avro 的 `logicalType: "timestamp-millis"` 在跨语言传输时可能被下游当 long 处理

Avro 很强调演化，但这不代表"随便改都没事"。
它只是给了你更系统化的兼容管理机制，不是替你做业务判断。

### 10. 不要神化"谁更快"

工程上当然会有人比较性能，但在大多数业务系统里，真正决定选型的往往不是那几个百分点的序列化速度，而是：

- 你的团队怎么协作
- 数据怎么流动
- 版本怎么发布
- 下游怎么消费
- 哪套生态你已经在用了

**粗略性能数字**（不同场景会翻倍）：

| 格式 | 序列化速度 | 反序列化速度 | 字节大小 |
|---|---|---|---|
| JSON | 基线 1× | 基线 1× | 基线 1× |
| Protobuf | ~3-5× 更快 | ~3-5× 更快 | ~20-30% |
| Avro | ~2-4× 更快 | ~2-4× 更快 | ~15-25%（可能更小） |
| Thrift | ~3-5× 更快 | ~3-5× 更快 | ~25-35% |
| FlatBuffers | 近零（zero-copy） | 近零 | ~40-50% |
| MessagePack | ~2× 更快 | ~2× 更快 | ~40-60% |

所以 Protobuf 和 Avro 在性能上其实很接近，差异经常被工作负载、语言实现、版本细节淹没。**性能差异 10-30% 通常不是选型决定因素**。

如果你为了"理论上更快"选了一个和团队工作流完全不匹配的格式，最后的总成本通常会更高。

所以更成熟的思路不是：

- "哪个最好？"

而是：

- "哪个让我们这条链路的总摩擦最小？"

### 11. 一个最实用的落地判断表

你可以先用下面这个粗粒度判断：

| 场景 | 更常优先考虑 |
| --- | --- |
| 微服务 RPC / gRPC | Protobuf |
| 内部高频接口，重视类型与生成代码 | Protobuf |
| Kafka 事件流，多消费者长期消费 | Avro |
| 数据仓库、批处理、流处理 | Avro |
| 团队已经有成熟 gRPC 工具链 | Protobuf |
| 团队已经有 Schema Registry 与数据平台生态 | Avro |
| 对外 API（浏览器、第三方） | JSON（不是本文重点但实际主流） |
| 游戏、实时仿真（要 zero-copy） | FlatBuffers / Cap'n Proto |
| 超大规模批处理（列式存储） | Parquet / ORC（不是消息格式但值得了解） |

### 12. 最后给你一个一句话判断法

如果你面对的是：

- "这是一个接口"
- "我希望双方按契约高效通信"
- "我很在意代码生成和调用体验"

优先想 Protobuf。

如果你面对的是：

- "这是一条要长期流转的数据"
- "会被多个下游、多个版本读取"
- "我很在意 schema 演化治理"

优先想 Avro。

### 13. 现代系统里的新趋势

#### 13.1 Protobuf + Confluent Schema Registry 的组合

Kafka 生态 2019 年之后开始广泛支持 Protobuf。很多原本全用 Avro 的公司开始把部分 topic 迁到 Protobuf（尤其是 RPC 和事件共用一个 schema 的场景）。

好处：RPC 和事件用同一个 `.proto`，避免维护两套定义。

代价：需要团队建立 Protobuf 的治理规范（Buf schema registry、CI 自动检查）。

#### 13.2 `buf` 工具链的崛起

Buf（buf.build）是 Protobuf 生态的新一代治理工具：

- `buf lint`：风格检查
- `buf breaking`：破坏性变更检测（等价于 Avro Schema Registry 的 compatibility check）
- `buf generate`：替代传统 `protoc`

它把 Protobuf 的治理体验推向了 Avro 级别。如果你用 Protobuf，强烈建议集成 buf。

#### 13.3 JSON Schema 也在被认真对待

这听起来反潮流——二进制都被研究透了，怎么又回到 JSON？

因为：

- 对外 API 仍然以 JSON 为主（浏览器、第三方集成）
- OpenAPI 3.1 + JSON Schema 已经成为 REST API 的标准
- Confluent Schema Registry 从 5.5 开始支持 JSON Schema

所以未来的混合栈可能是：

- 内部高频 RPC：Protobuf + gRPC
- 事件流：Avro 或 Protobuf
- 对外 API：OpenAPI + JSON Schema

### 14. 最终心智模型

一句话总结：

> **格式本身是"数据的语法"，演化纪律是"语义协议"，工具链是"治理能力"。三者缺一不可。**

Protobuf 和 Avro 的真正差距，不是谁更快、谁更小，而是 **它们假设的治理模型不一样**：

- Protobuf 假设你有统一的 build 流程和代码纪律
- Avro 假设你有中心化的 schema registry 和自动校验

选错等于选错了治理模型，会在未来一两年里慢慢付出代价。

## 小结（8 条关键点）

- **历史决定性格**：Protobuf 出身 Google 内部 RPC（2001），Avro 出身 Hadoop 长期数据（2009）——它们解决的原始问题不一样。
- **本质差别在"schema 存在哪"**：Protobuf 的 schema 藏在代码里，每条消息只带 tag+value；Avro 的 schema 是数据的一部分，要么在文件头，要么用 registry 里的 ID 引用。
- **wire format 差异反映哲学**：Protobuf 有 tag 编号支持演化但多 1-2 字节开销；Avro 更紧凑但离了 schema 完全没法解析。
- **演化规则的复杂度分布不同**：Protobuf 规则简单但全靠人守纪律；Avro 规则复杂但 Schema Registry 自动强制。
- **Schema Registry 是 Avro 的杀手锏**：它把"schema 的治理"从应用代码拉到平台层，大团队协作时收益巨大。LinkedIn、Airbnb、Uber 都是这个模式的重度用户。
- **两者性能差距通常只有 10-30%，远不是选型决定因素**：真正决定因素是团队协作、数据流动、工具链。
- **不是孤立选型**：gRPC → Protobuf 基本默认，Kafka + Schema Registry → Avro 基本默认。跟着已有的生态走摩擦最小。
- **记住一句话**：Protobuf 更像"服务之间高效说话的语言"，Avro 更像"跨时间、跨系统传递数据的协议"。遇到具体问题时，先问这是哪一类。

---

## 检查站：请回答以下问题

1. 用你自己的话解释：为什么说 Protobuf 更像"服务之间高效说话的语言"，而 Avro 更像"跨时间传递数据的协议"？请结合它们在 wire format 和 schema 存储位置的差异说。
2. 如果一个系统主要是微服务之间的同步 RPC，你为什么会更倾向 Protobuf？如果让你配 gRPC + Avro，可行吗？有什么顾虑？
3. 如果一个订单事件会进 Kafka，然后被营销、风控、报表、离线任务一起消费，你为什么会更倾向 Avro？Schema Registry 在这里起到什么核心作用？
4. Protobuf 的演化纪律里最容易踩的坑是什么？为什么 `reserved` 关键字在生产里必须用？
5. Avro 的 BACKWARD / FORWARD / FULL 兼容模式分别在保护什么？如果你的系统是"消费者先升级，生产者后升级"，你该选哪种？
6. 什么情况下你会考虑 FlatBuffers / Cap'n Proto 而不是 Protobuf？这些格式做了什么取舍？
7. 你现在自己的粗粒度判断标准是什么？请用 2 到 4 句话总结"什么时候优先想 Protobuf，什么时候优先想 Avro"。
8. 你能说出一个"选错了格式导致长期付出代价"的场景吗（真实或虚构都行）？根本原因是什么？

请把你的答案直接告诉我，我会根据你的回答决定下一步。
