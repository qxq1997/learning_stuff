# DDIA - 第 4 课补充：什么是 `.proto` 和代码生成

## 学习目标（本节结束后你能做到什么）

- 理解 `.proto` 文件不是"某种程序代码"，而是用来描述消息结构和服务接口的协议定义文件。
- 理解 `.proto` 是一种 **IDL（Interface Definition Language）**，知道 IDL 的历史渊源（CORBA、Thrift、gRPC）和它为什么存在。
- 理解"代码生成"不是 AI 自动写业务逻辑，而是工具根据 `.proto` 自动生成不同语言里的数据结构和通信骨架。
- 能看懂一个最简单的 `.proto` 例子，知道里面哪些部分在定义"数据"，哪些部分在定义"服务"。
- 能说清楚为什么 Protobuf 常和 `gRPC` 一起出现。
- 掌握 Proto3 的核心语法：字段编号、类型、`repeated`、`optional`、`oneof`、`map`、`enum`、`reserved`。
- 理解 wire format 的物理布局：tag + wiretype + value，以及它为什么能向前兼容。
- 了解 Proto2 vs Proto3 的关键差异，知道现代项目默认应该选哪个。
- 掌握代码生成的工具链：`protoc`、`buf`、各语言的生成器插件。

## 内容讲解（核心概念，用类比、例子、图示说清楚）

### 0. 什么是 IDL，以及它为什么存在

要理解 `.proto`，先要理解它所在的类别——**IDL（Interface Definition Language，接口定义语言）**。

IDL 的诞生背景：1990 年代的分布式计算革命。那时候的挑战是：

- C 程序要和 C++ 程序通信
- Unix 服务器要和 Windows 客户端通信
- Perl 脚本要和 Java 应用交换数据

如果每对语言都手写序列化代码，组合爆炸会让工程师发疯。所以需要一个 **语言无关的描述层**——先用一种中性语法定义"数据和接口长什么样"，再由工具生成各语言的绑定。

IDL 的历史主线：

| 年份 | IDL | 背景 |
|---|---|---|
| 1991 | CORBA IDL | OMG 组织的跨语言分布式对象标准，超级复杂 |
| 1997 | DCOM / Microsoft IDL | 微软版本 |
| 1998 | XML-RPC | 把 RPC 写成 XML，慢但普及 |
| 2000 | SOAP + WSDL | 企业级 Web Service 标准，同样复杂 |
| 2001 | Google Protobuf | Google 内部用，2008 年开源 |
| 2007 | Apache Thrift | Facebook 开源 |
| 2009 | Apache Avro | Hadoop 生态 |
| 2015 | OpenAPI / Swagger | REST API 的事实 IDL |
| 2016 | gRPC（基于 Protobuf） | Google 开源分布式 RPC 框架 |
| 2019 | Buf + CNCF Protobuf 治理 | 现代 Protobuf 生态整合 |

这张表里藏着一个规律：**每一代 IDL 都在解决上一代的痛点**。CORBA 太复杂 → SOAP 太啰嗦 → REST+JSON 缺类型 → Protobuf/Thrift 提供高效类型化 RPC。

所以 `.proto` 不是一个孤立发明，而是 30 年 IDL 演化的一个里程碑。

### 1. 什么是 `.proto`

`.proto` 是 **Protocol Buffers 的协议定义文件**。
你可以把它理解成一份"结构说明书"或者"合同"。

它主要用来描述两类东西：

1. 数据长什么样
   也就是消息结构，例如订单里有哪些字段。
2. 服务怎么调用
   也就是接口定义，例如"下单"这个 RPC 要传什么、返回什么。

所以 `.proto` 不是业务代码，它更像是：

- 前后端/服务之间先谈好的数据协议
- 一份给机器读的接口文档
- 一份可以进一步生成代码的结构化定义

### 2. 一个最小的 `.proto` 例子

```proto
syntax = "proto3";

message Order {
  int64 order_id = 1;
  int64 user_id = 2;
  int64 amount = 3;
}
```

这里可以这样读：

- `syntax = "proto3";`
  表示使用 `proto3` 语法版本。
- `message Order`
  表示定义了一种消息，名字叫 `Order`。
- `int64 order_id = 1;`
  表示 `Order` 里有一个字段叫 `order_id`，类型是 `int64`，字段编号是 `1`。

这个编号非常重要，因为 Protobuf 在二进制传输时，靠的不是完整字段名，而主要靠字段编号来识别字段。

#### 2.1 字段编号的深层意义

为什么 Protobuf 要用编号，而不像 JSON 一样用字段名？

两个核心原因：

1. **紧凑**：编号是 varint 编码，通常只占 1 字节（tag 1-15）。字段名像 "user_profile_full_name" 每次都要传几十字节。
2. **解耦**：编号是 **契约**，字段名只是 **标签**。改名只影响代码可读性，改号会破坏所有在线流量。

编号的规则：

- 合法范围：1 到 2^29 - 1（536,870,911）
- 推荐：1 到 15 留给 **最常用字段**（单字节 tag）
- 禁用：19000 到 19999（Protobuf 内部保留）
- 删除的编号要 `reserved`：`reserved 5, 8 to 11;`

**经验教训**：字段编号是向前契约。一旦线上流量带着某个编号出现过，就永远不能改语义。这是 Protobuf 最严肃的工程约束。

### 3. 什么是"代码生成"

代码生成指的是：

**你写好 `.proto` 后，用 Protobuf 的工具自动生成各语言对应的数据结构和序列化/反序列化代码。**

比如你写了一个 `order.proto`，然后运行工具后，可以自动生成：

- Java 的 `Order.java`
- Go 的 `order.pb.go`
- Python 的 `order_pb2.py`
- TypeScript 的 `order_pb.ts`
- Rust 的 `order.rs`
- Swift 的 `Order.swift`
- Kotlin、Objective-C、C#、Ruby、PHP…

#### 3.1 生成出来的代码包含什么

这些生成出来的代码通常包含：

- `Order` 这个类或结构体
- 把 `Order` 编码成二进制的方法（`Serialize` / `Marshal` / `SerializeToString`）
- 把二进制还原成 `Order` 的方法（`Parse` / `Unmarshal` / `ParseFromString`）
- 字段的 getter / setter（某些语言）
- 反射和调试辅助（`String()`, `Equals`, `HashCode`）
- 默认值处理
- Builder 模式（Java）

以 Go 为例，生成的 `order.pb.go` 里会有：

```go
type Order struct {
    state         protoimpl.MessageState
    sizeCache     protoimpl.SizeCache
    unknownFields protoimpl.UnknownFields

    OrderId int64 `protobuf:"varint,1,opt,name=order_id,json=orderId,proto3" json:"order_id,omitempty"`
    UserId  int64 `protobuf:"varint,2,opt,name=user_id,json=userId,proto3" json:"user_id,omitempty"`
    Amount  int64 `protobuf:"varint,3,opt,name=amount,proto3" json:"amount,omitempty"`
}

func (x *Order) GetOrderId() int64 { ... }
func (x *Order) Reset() { ... }
func (x *Order) String() string { ... }
func (*Order) ProtoMessage() {}
// ... 更多方法
```

所以"代码生成"不是自动帮你实现业务逻辑，比如不会替你写"扣库存""创建订单"。
它做的是比较机械但很重要的工作：

- 按协议自动生成数据结构
- 保证不同语言对同一份协议的理解一致
- 减少手写序列化代码的出错概率

#### 3.2 `unknownFields` 的作用

注意上面 Go 代码里有个 `unknownFields` 字段。这是 Protobuf 向前兼容的核心物理机制：

- 当 **旧版本** client 收到 **新版本** 消息里它不认识的字段时
- 这些字段不会被丢弃，而是存到 `unknownFields` 里
- 如果旧版本 client 再把消息转发或重新序列化，这些未知字段会原样带出去

这就是为什么 Protobuf 能做到"经过一个不识别新字段的中间服务后，新字段不丢失"——比如 API Gateway 用旧 schema，但新字段能穿透它到达后端。

### 4. 为什么要代码生成

因为如果没有代码生成，你就得自己在每种语言里手写：

- 一个 `Order` 类
- 每个字段怎么编码
- 每个字段怎么解码
- 不同版本字段怎么兼容

这很麻烦，而且容易错。

代码生成的价值就是：

- 避免重复劳动
- 避免不同语言实现不一致
- 让协议定义和实际代码保持同步
- **强类型检查前置到编译期**（比 JSON 的运行时检查安全得多）

#### 4.1 代码生成 vs 反射：为什么选生成

其实有不少系统用"反射+动态解析"的方式处理序列化（比如 Go 的 `encoding/json`、Java 的 Jackson）。那为什么 Protobuf 要走"代码生成"这条路？

| 维度 | 代码生成 | 运行时反射 |
|---|---|---|
| 性能 | 直接字段访问，无反射开销 | 每次都要反射查表 |
| 启动时间 | 无需初始化 | 反射元数据构建耗时 |
| 二进制体积 | 大（每个 message 都有生成代码） | 小 |
| 编译期类型安全 | ✅ | ❌ |
| 动态消息处理 | 需要 `DynamicMessage` | 天然支持 |
| 调试 | 可以 step-through 生成代码 | 反射栈不直观 |

Protobuf 选代码生成，是因为它的主要使用场景是 **高频 RPC**——性能和类型安全权重远超动态性。

### 5. `.proto` 和普通类定义有什么不同

你可能会觉得，`.proto` 里定义字段，看起来和 Java / Go / Python 里的类定义很像。
但它们的定位不一样：

- 普通类定义：偏应用内部实现
- `.proto`：偏跨服务、跨语言、跨进程的数据协议

也就是说，普通类通常是"我自己程序内部怎么组织代码"，
而 `.proto` 更像是"多个程序之间约定怎么交换数据"。

### 6. `.proto` 不只定义数据，也可以定义服务

例如：

```proto
syntax = "proto3";

message CreateOrderRequest {
  int64 user_id = 1;
  int64 amount = 2;
}

message CreateOrderResponse {
  int64 order_id = 1;
  string status = 2;
}

service OrderService {
  rpc CreateOrder(CreateOrderRequest) returns (CreateOrderResponse);
}
```

这里就多了一层：

- `message` 定义请求和响应的数据结构
- `service` 定义接口
- `rpc CreateOrder(...) returns (...)`
  表示有一个远程调用方法叫 `CreateOrder`

这也是为什么 `gRPC` 经常和 Protobuf 一起出现。
因为你可以在 `.proto` 里同时定义：

- 传什么数据
- 暴露什么接口

然后工具自动生成客户端和服务端骨架代码。

#### 6.1 gRPC 的四种调用模式

gRPC 支持四种调用模式，都在 `.proto` 里声明：

```proto
service ChatService {
  // 1. Unary：一问一答
  rpc SendMessage(Message) returns (Ack);

  // 2. Server streaming：客户端一次问，服务端流式返回
  rpc Subscribe(SubscribeReq) returns (stream Message);

  // 3. Client streaming：客户端流式发，服务端一次返回
  rpc UploadFile(stream Chunk) returns (UploadResult);

  // 4. Bidirectional streaming：双向流
  rpc Chat(stream Message) returns (stream Message);
}
```

四种模式对应四种工程场景：

- Unary：普通的 RPC（90% 的用例）
- Server streaming：订阅、实时推送（股票行情、日志流）
- Client streaming：上传大文件、批量写入
- Bidirectional streaming：双向实时通信（聊天、游戏、协同编辑）

这是 REST + JSON 天然不具备的能力。所以如果你要做实时推送、流式数据，gRPC 的流式调用比 HTTP + SSE 或 WebSocket + 自定义协议优雅得多。

### 7. Proto3 的核心语法全景

#### 7.1 基础类型

```proto
// 标量
int32, int64          // 变长编码，负数耗 10 字节
uint32, uint64        // 变长编码
sint32, sint64        // zigzag 编码，适合负数多的场景
fixed32, fixed64      // 定长 4/8 字节
sfixed32, sfixed64    // 定长有符号
float, double         // 浮点
bool
string                // UTF-8
bytes                 // 任意字节
```

#### 7.2 复合类型

```proto
message Nested {
  string name = 1;
}

message Outer {
  Nested nested = 1;               // 嵌套 message
  repeated string tags = 2;         // 列表（相当于数组）
  map<string, int32> counters = 3;  // map
}
```

**`repeated` 的 wire 优化**：Proto3 里数值类型的 `repeated` 默认 **packed**——多个值合并成一个 length-delimited 块，比每个值单独带 tag 省空间。

#### 7.3 `oneof`：类似 union

```proto
message Payment {
  int64 amount = 1;
  oneof method {
    CreditCard card = 10;
    BankTransfer transfer = 11;
    Crypto crypto = 12;
  }
}
```

同一时刻只能有 `card`、`transfer`、`crypto` 中的一个。wire 上只传被设置的那个。

#### 7.4 `enum`：枚举

```proto
enum OrderStatus {
  ORDER_STATUS_UNSPECIFIED = 0;  // 必须有 0 值（proto3 要求）
  ORDER_STATUS_CREATED = 1;
  ORDER_STATUS_PAID = 2;
  ORDER_STATUS_SHIPPED = 3;
}
```

**为什么 enum 必须有 0 值**：proto3 里 field 没有显式 default 的概念，未设置字段返回该类型的 zero value。`0` 成为 enum 的 fallback——这也是为什么约定第一个值必须是 `UNSPECIFIED`，避免"未设置"被误认为是某个有意义的状态。

#### 7.5 `optional`：proto3.15+ 的重要补丁

Proto3 早期移除了 `optional` 关键字（因为所有字段默认就是 optional）。但这引入一个难题：**你怎么区分"字段被显式设为 0"和"字段未设置"**？

例如 `int32 age = 1;`，收到 `age=0` 到底是"用户明确填了 0"还是"用户根本没填"？Proto3 早期无解。

所以 Proto3.15（2021）加回了 `optional`：

```proto
message Person {
  optional int32 age = 1;  // 现在可以区分 "设为 0" 和 "未设置"
}
```

生成的代码里会有 `HasAge()` / `has_age()` 方法。

#### 7.6 `reserved`：删除字段的正确姿势

```proto
message Order {
  reserved 5, 8 to 11, 42;
  reserved "old_field", "deprecated_name";

  int64 order_id = 1;
  // ...
}
```

这是防止"删字段后将来又复用旧编号"的唯一保险。必须写。

### 8. Proto2 vs Proto3：什么时候用哪个

绝大多数新项目应该用 Proto3。但你可能会遇到 Proto2 代码，所以要知道差异：

| 维度 | Proto2 | Proto3 |
|---|---|---|
| `required` 字段 | 有 | 没有（故意去掉） |
| `optional` | 显式 | 早期没有，3.15 加回 |
| 默认值 | 可自定义 | 固定为 zero value |
| `unknown fields` 行为 | 保留 | 3.0 早期丢弃，3.5+ 保留 |
| 扩展（`extend`） | 有 | 被 `Any` 替代 |
| Groups | 有（已废弃） | 没有 |
| JSON 映射 | 未标准化 | 标准化 |

**为什么 Proto3 去掉 `required`？**

Kleppmann 也反复强调这点。`required` 看似是强约束，实际是 schema 演化的毒瘤：

- 你把字段标 `required`
- 十年后发现这个字段在新场景里没意义，想废弃
- 但不能删——因为删了，旧版本 client 就收到"缺少 required 字段"错误
- 只能永远保留它

Google 内部积累了数百万个 `.proto`，发现 `required` 造成了大量无法演化的僵化 schema。所以 Proto3 直接废除它——"宁可让你手动校验业务必填，也不要把这个约束锁进协议层"。

### 9. wire format 深入：为什么能向前兼容

一条消息在 wire 上是一串 `(tag_wire_byte, value_bytes)` 对。

#### 9.1 tag + wire type 的组合编码

Tag byte = `(field_number << 3) | wire_type`

Wire type 只有 6 种（其中 3、4 已废弃）：

| 类型编号 | 名称 | 用途 |
|---|---|---|
| 0 | VARINT | int32, int64, uint32, uint64, sint32, sint64, bool, enum |
| 1 | I64 | fixed64, sfixed64, double |
| 2 | LEN | string, bytes, embedded message, packed repeated |
| 3 | SGROUP | (deprecated) |
| 4 | EGROUP | (deprecated) |
| 5 | I32 | fixed32, sfixed32, float |

字段 15 以内的 tag 在 `(field_number << 3) | wire_type` 后仍然 ≤ 127，所以只占 1 个 varint 字节。字段 16+ 需要 2 字节。

#### 9.2 varint 编码

正整数用最低 7 位编码，最高位是"还有后续字节"标志。

例如 300：
- 二进制：100101100
- 分 7 位组：0000010 0101100
- 低位在前：0101100 0000010
- 加高位标志：10101100 00000010
- 十六进制：0xAC 0x02

所以数字越小，占用越少。Protobuf 之所以对"小数值"如此紧凑，就是靠这个。

#### 9.3 zigzag：处理负数

普通 varint 对负数很差（-1 用两字节补码是 0xFFFFFFFFFFFFFFFF，占满 10 字节）。zigzag 把有符号数映射成无符号：

- 0 → 0
- -1 → 1
- 1 → 2
- -2 → 3
- 2 → 4
- ...

这样 -1 占 1 字节而不是 10 字节。`sint32` / `sint64` 用的就是 zigzag。

#### 9.4 为什么这个布局能向前兼容

假设旧 client 的 proto 只定义了字段 1、2、3，新 server 发来的消息包含字段 1、2、3、4（4 是新加的）。

旧 client 读取流程：

1. 读 tag 字节，解析出 `field_number=1, wire_type=0`
2. 按 VARINT 读值，存入 Order.order_id
3. 读下一个 tag，拿到 field 2... field 3...
4. 读到 field 4 的 tag，字段不在本地 schema 中
5. 但 wire_type 告诉我"这是 VARINT"，知道怎么跳过它
6. 继续读

这就是 Protobuf 向前兼容的物理本质：**即使不认识字段，也能根据 wire type 知道怎么跳过**。

### 10. 代码生成的工具链

#### 10.1 `protoc`：官方编译器

最基础的工具，由 Google 维护。典型用法：

```bash
# 生成 Go 代码
protoc --go_out=. --go-grpc_out=. order.proto

# 生成 Python
protoc --python_out=. order.proto

# 生成 Java
protoc --java_out=. order.proto

# 生成 TypeScript（需要装插件）
protoc --ts_out=. order.proto
```

`protoc` 本身不生成任何代码——它只是解析 `.proto` 成 AST，然后调用语言相关的插件（`protoc-gen-go`、`protoc-gen-java` 等）生成代码。

#### 10.2 `buf`：现代化工具链

Buf（buf.build）是 Protobuf 生态的新一代工具，已经成为很多公司的默认选择：

```bash
buf lint                   # 风格检查
buf breaking               # 检测破坏性变更（和 Avro Schema Registry 校验等价）
buf generate               # 替代 protoc
buf push                   # 推到 Buf Schema Registry
```

Buf 的核心价值：

- **统一配置**（`buf.yaml` 替代零散的 `protoc` 命令）
- **现代化 linter**（覆盖风格、命名、注释、弃用检测）
- **破坏性变更检测**（这是 Avro 一直有但 Protobuf 生态缺的——Buf 补上了）
- **依赖管理**（类似 Go modules，可以 import 其他团队的 `.proto`）

如果你现在开始一个 Protobuf 项目，强烈建议从 buf 入手，而不是裸 protoc。

#### 10.3 语言生态的坑

不同语言的代码生成器质量不一：

- **Go**：官方 `google.golang.org/protobuf` 成熟稳定。历史上 `gogoproto`（性能更好但有兼容问题）已在 2022 年被废弃。
- **Python**：官方库叫 `protobuf`，还有 `protoc-gen-python-betterproto`（现代 async/await 支持、数据类）。
- **Java**：官方 `protobuf-java` 庞大，手机端用 `protobuf-javalite` 精简版。
- **TypeScript / JavaScript**：有多个并存选择：`ts-proto`、`protobuf-ts`、`google-protobuf`、Connect 系列。
- **Rust**：`prost`（主流）、`rust-protobuf`（老）。
- **C++**：Google 官方，但和 Abseil、Bazel 绑得紧。

生态选择直接决定开发体验。选型时要看：

- 官方 vs 社区（官方通常稳但保守）
- 生成代码的可读性
- 对 async / 零拷贝的支持
- JSON 互转支持
- IDE 集成

### 11. 用餐厅点单来类比

你可以这样类比：

- `.proto`：餐厅菜单和点单格式说明
- 代码生成：根据这份菜单，自动给收银员、后厨、外卖系统各发一份统一模板
- gRPC：餐厅里上菜、传单的标准流程
- Schema Registry：菜单变更的审批系统，防止新菜单破坏老顾客的点单习惯

这样大家都按同一份标准工作，就不会出现：

- 收银员写"套餐 A"
- 后厨理解成"套餐 B"
- 外卖系统又把金额字段写成另一个格式

也就是说，`.proto` 负责统一协议，代码生成负责把协议落成各语言可直接使用的代码。

### 12. 真实项目里的目录结构

一个规范的 Protobuf 项目通常长这样：

```
proto/
├── buf.yaml                       # Buf 配置
├── buf.gen.yaml                   # 代码生成配置
├── buf.lock                       # 依赖锁
├── company/
│   └── order/
│       └── v1/                    # 版本化目录（关键！）
│           ├── order.proto
│           ├── order_service.proto
│           └── types.proto
│   └── user/
│       └── v1/
│           └── user.proto
└── google/                        # 官方依赖（well-known types）
    └── protobuf/
        ├── timestamp.proto
        └── empty.proto
```

#### 12.1 为什么要 `v1` 目录

这是 gRPC 生态的黄金实践：**每个包都放在 `vN` 下**。

```proto
// company/order/v1/order.proto
syntax = "proto3";
package company.order.v1;

message Order { ... }
```

当需要破坏性变更时，不是改 `v1`（会破坏所有存量 client），而是：

1. 新增 `company/order/v2/`
2. `v2` 里定义新 schema
3. 新老 client 可以并存，服务端同时挂两个版本
4. 逐步迁移客户端，最后下线 `v1`

这个模式和 REST API 的 `/v1/` URL 版本化是一样的思路。Google API 指南（aip.dev）详细记录了这套规范。

#### 12.2 Well-known types

Google 官方提供了一批基础类型：

```proto
import "google/protobuf/timestamp.proto";
import "google/protobuf/duration.proto";
import "google/protobuf/empty.proto";
import "google/protobuf/any.proto";
import "google/protobuf/wrappers.proto";

message Order {
  google.protobuf.Timestamp created_at = 1;
  google.protobuf.Duration timeout = 2;
  google.protobuf.Int32Value optional_count = 3;  // 可空的 int32
}
```

- `Timestamp`：跨语言统一的时间戳（秒 + 纳秒）
- `Duration`：时间段
- `Empty`：空消息（RPC 没有返回时用）
- `Any`：动态类型，内含 type_url + 值（类似 Java Object）
- `wrappers`：原生类型的可空包装（`Int32Value`、`StringValue` 等，用于"可以为 null 的值"）

使用这些而不是重新发明，可以让代码跨团队/跨项目互通。

### 13. 实战工程建议

#### 13.1 命名约定

- 文件名：`snake_case.proto`（如 `order_service.proto`）
- Package：`lowercase.with.dots`（如 `company.order.v1`）
- Message：`PascalCase`（如 `CreateOrderRequest`）
- 字段：`snake_case`（如 `order_id`，生成到 Go 会变 `OrderId`，Java 会变 `orderId`）
- RPC：`PascalCase`（如 `CreateOrder`）
- Enum 值：`SCREAMING_SNAKE_CASE` 并带 enum 前缀（如 `ORDER_STATUS_CREATED`）

#### 13.2 每个 Request/Response 都用独立 message

**❌ 反例**：
```proto
rpc CreateOrder(Order) returns (Order);
```

**✅ 正例**：
```proto
rpc CreateOrder(CreateOrderRequest) returns (CreateOrderResponse);

message CreateOrderRequest {
  int64 user_id = 1;
  int64 amount = 2;
}

message CreateOrderResponse {
  Order order = 1;
}
```

**理由**：今天你的 `CreateOrder` 只需要 `user_id` 和 `amount`。明天需要加一个 `promo_code`、后天需要 `client_version` —— 如果直接用 `Order` 当请求，Order 类型就被污染了无关字段。独立 request/response 给 API 演化留下了完整自由。

#### 13.3 每个字段都加注释

```proto
message Order {
  // Unique order identifier, generated server-side.
  // Monotonically increasing within a shard.
  int64 order_id = 1;

  // The user who placed the order. Must exist in users service.
  int64 user_id = 2;

  // Amount in cents (USD). Must be positive.
  int64 amount = 3;
}
```

生成的代码里会带这些注释（Go 生成 `// ... comments` 在字段上，Python 生成 docstring），对调用方非常友好。

#### 13.4 CI 集成

```yaml
# .github/workflows/proto.yml
- run: buf lint
- run: buf breaking --against "https://github.com/company/proto.git#branch=main"
- run: buf generate
- run: git diff --exit-code  # 确保生成代码已提交
```

这个流程能阻止：

- 风格不一致
- 破坏性变更悄悄合入
- 生成代码和 `.proto` 不同步

### 14. 常见问题与坑

#### 14.1 "为什么生成的 Go struct 字段都是指针？"

Proto3 早期把所有字段"非指针化"来简化访问。但 message 嵌套和 `optional` 字段仍然是指针——这是为了区分"未设置"和"零值"。生成的代码风格可能让 Go 开发者不太适应，但这是 protocol 语义的必然结果。

#### 14.2 "Python 生成的代码有个 `_pb2.py` 后缀，什么意思？"

`pb2` 是 "Protocol Buffers version 2" 的缩写——**但和 Proto2/Proto3 语法版本无关**。它指的是 Python 生成器的 API 版本 2（相对于 Google 早期的 proto1 API）。即使你用 Proto3 syntax，文件名仍然是 `xxx_pb2.py`。这是历史包袱。

#### 14.3 "为什么我的字段名是 `camelCase` 但 JSON 里变成了 `snake_case`？"

Protobuf 的 JSON 映射规则：`.proto` 里 `snake_case` 字段 → JSON 里 `camelCase`。这是 proto3 JSON 规范的一部分。如果你想在 JSON 里也用 `snake_case`，要设置 `use_proto_names` 选项。

#### 14.4 "我想在 REST Gateway 里暴露 gRPC 服务，怎么做？"

`grpc-gateway` 是 CNCF 生态里的方案：在 `.proto` 里用 `google.api.http` 注解，工具自动生成一个 HTTP+JSON 的反向代理，把 REST 请求翻译到 gRPC。

```proto
service OrderService {
  rpc CreateOrder(CreateOrderRequest) returns (Order) {
    option (google.api.http) = {
      post: "/v1/orders"
      body: "*"
    };
  }
}
```

这就实现了 **一份 .proto，同时暴露 gRPC 和 REST**。

## 小结（10 条关键点）

- **`.proto` 是一种 IDL（接口定义语言）**，继承自 30 年 IDL 演化（CORBA → SOAP → Thrift/Protobuf/Avro → OpenAPI），解决的是"跨语言、跨服务的数据和接口契约"。
- **`.proto` 不是业务代码，是机器可读的协议合同**。它定义"数据长什么样"和"接口怎么调用"。
- **字段编号是契约，字段名只是标签**。编号一旦用过，永远不能改语义，删除后必须 `reserved`。这是 Protobuf 最严肃的工程约束。
- **代码生成做的是机械但关键的工作**：按协议生成各语言数据结构、序列化/反序列化代码，保证跨语言一致性，让类型检查前置到编译期。
- **`unknownFields` 是 Protobuf 向前兼容的物理机制**：旧版本遇到不认识的字段不会丢弃，会原样保留穿透。
- **Proto3 废除 `required` 不是简化，是纠错**：Google 积累了无数"永远删不掉的 required 字段"后才做出这个决定。现代项目默认用 Proto3。
- **wire format 的精妙在于 tag + wire type**：读到不认识的字段时，wire type 告诉你怎么跳过，这是协议层面的向前兼容保障。varint + zigzag 让常见数值紧凑编码。
- **gRPC 的四种调用模式（unary、server stream、client stream、bidirectional stream）**都在 `.proto` 里直接声明——这是 REST 难以匹敌的能力。
- **工具链正在进化**：`protoc` 仍是基础，但 `buf` 提供了现代化的 lint、破坏性变更检测、依赖管理，已成为生产实践的首选。
- **规范的 Protobuf 项目要求几件事**：`vN` 版本化目录、独立的 Request/Response、完整注释、CI 中自动检查破坏性变更。缺了这些，Protobuf 的工程优势会被慢慢蚕食。

---

## 检查站：请回答以下问题

1. 用你自己的话解释：`.proto` 文件到底是什么？它和普通业务代码有什么区别？它和 OpenAPI、JSON Schema、Thrift IDL 是同一类东西吗？
2. "代码生成"到底自动帮我们做了什么，没帮我们做什么？为什么 Protobuf 选代码生成，而不是像 JSON 那样用运行时反射？
3. 为什么 `.proto` 里的字段编号比字段名更重要？如果团队不小心改了一个字段的编号，会发生什么？
4. Proto3 为什么故意废除了 `required` 关键字？你能想象一个真实场景，`required` 在长期维护里会变成毒瘤吗？
5. 为什么 `.proto` 可以既定义数据（message）又定义接口（service）？如果只用 JSON，你会怎么补上"接口定义"这一环？
6. 解释一下 Protobuf 的 wire format 为什么能"向前兼容"——旧 client 遇到新字段时为什么不会崩？
7. gRPC 的四种调用模式（unary、server streaming、client streaming、bidirectional）分别适合什么场景？你能想到一个具体业务吗？
8. 如果你现在要启动一个新的 `.proto` 项目，你会做哪几件事来确保它不会在两年后变成"改不动的协议"？

请把你的答案直接告诉我，我会根据你的回答决定下一步。
