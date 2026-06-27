# 02 Protocol Buffers 深挖：IDL、Wire Format、varint/zigzag 与兼容性

> 这是整个专栏的第一块地基。gRPC 本身其实很“薄”，它真正的复杂度一半在 HTTP/2（下一篇），一半在 Protobuf。这一篇我们一路钻到字节：一条消息序列化后到底是哪几个 byte、为什么 `int32` 存 `-1` 会变成 10 个字节、为什么改个字段类型灰度就炸。把这一篇吃透，后面的 length-prefixed message、流控、契约演进才有根。

## 一、Protobuf 在 gRPC 里的双重身份

先定位。Protobuf 在 gRPC 里同时干两件事，很多人只记住其中一件：

1. **接口契约（IDL）**：`.proto` 文件用 `service` / `rpc` / `message` 定义“有哪些服务、每个服务有哪些方法、每个方法的请求和响应长什么样”。这是给 `protoc` 读的、机器可校验的契约。
2. **序列化格式（wire format）**：同一份 `message` 定义，决定了对象在网络上传输时的二进制布局。

```
       .proto 文件
           │
   ┌───────┴────────┐
   │                │
  作为 IDL        作为序列化规范
   │                │
   ▼                ▼
 protoc 生成      运行时把对象
 各语言 stub      编/解码成字节
 (服务/方法/类型)   (wire format)
```

这一篇的重点是第二块——**wire format**，因为它决定了三件你必须懂的事：**为什么 Protobuf 快**、**为什么兼容性那么强**、**哪些改动会在灰度时炸**。第一块（IDL 语法）够用就行，我们快速过。

## 二、`.proto` 语法：够用就走，重点在后面

一个典型的 `.proto`：

```protobuf
syntax = "proto3";                 // 声明用 proto3（不写默认 proto2）

package helloworld;                // 包名，影响生成代码的命名空间 + gRPC 的 :path

// 服务定义 —— 这部分是 gRPC 用的，纯 Protobuf 序列化用不到
service Greeter {
  rpc SayHello (HelloRequest) returns (HelloReply);
}

// 消息定义 —— 这部分既是契约，也是序列化规范
message HelloRequest {
  string name = 1;                 // 字段名 name，类型 string，字段号 1
  int32  age  = 2;
  repeated string tags = 3;        // repeated = 列表/数组
}

message HelloReply {
  string message = 1;
}
```

几个必须建立的概念：

- **字段号（field number）= `= 1` 那个数字**，不是字段在文件里的位置。它是这条字段在 wire format 里的“身份证”，**比字段名重要一万倍**（下面第五节专门讲）。
- **标量类型**：`int32 / int64 / uint32 / uint64 / sint32 / sint64 / fixed32 / fixed64 / sfixed32 / sfixed64 / float / double / bool / string / bytes`。注意这里有 6 种整数表示（`int* / uint* / sint* / fixed* / sfixed*`），它们的差别**全在 wire format**，第四节会讲为什么需要这么多种。
- **复合类型**：`repeated`（列表）、`map<k,v>`（底层是 repeated message）、`oneof`（互斥字段）、`enum`（枚举）、嵌套 `message`。
- **`reserved`**：保留字段号 / 字段名，禁止后人复用——这是契约演进的安全锁，第六节细讲。

语法手册不是这篇的重点，我们要钻的是“这些语法编码成字节后长什么样”。

## 三、proto2 vs proto3：为什么把 `required` 砍了

你会同时见到 proto2 和 proto3，先讲清差异，因为它直接关系到兼容性与一个经典大坑。

| 维度 | proto2 | proto3 |
|---|---|---|
| 字段标签 | `required` / `optional` / `repeated` | 默认隐式 optional；`repeated`；proto3.15+ 回归显式 `optional` |
| `required` | 有 | **被彻底删除** |
| 默认值 | 可自定义 `[default = ...]` | 固定（数值 0 / 字符串 "" / bool false），不可自定义 |
| 字段存在性（presence） | 标量字段有 `has_xxx()` | 标量字段默认**没有** presence（值 == 默认值就当“没设”）；用 `optional` 才找回 |
| 枚举 | 第一个值不必是 0 | 第一个值**必须是 0**（作默认值） |

**为什么 proto3 要砍掉 `required`？** 这是 Google 内部踩了多年坑后的决定，核心是：**`required` 是契约演进的“毒药”**。

设想：服务 A 定义 `required string token = 1;`，全网都依赖。某天发现 `token` 该废弃了，但你**没法安全删它**——因为只要有一个老服务还按 required 解码，收到没有 `token` 的消息就会**解析失败、整条消息报废**。`required` 把“字段缺失”从“业务问题”升级成了“协议级硬错误”，而且这个错误会随着消息在系统里流转传染开。在一个有几千个服务、灰度滚动发布的体系里，任何一个 required 字段都是定时炸弹。

所以 proto3 的哲学是：**协议层永远不该因为“少了个字段”就解析失败；字段缺没缺、合不合法，是业务校验该管的事，不是序列化框架该管的事。** 这个取舍贯穿 Protobuf 的整个兼容性设计——记住它。

但砍掉 presence 带来了 proto3 自己的坑（“0 和未设置分不清”），后来又用 `optional` 补了回来。第七节专门讲这个坑。

## 四、Wire Format 逐字节深挖（核心）

现在进入这一篇的心脏。Protobuf 的 wire format 基于一个朴素思想：**TLV（Tag-Length-Value）**，但做了精巧的压缩。

### 4.1 一条消息 = 一串 (字段) 的拼接，字段名根本不传

最反直觉、也最关键的一点：**序列化后的字节里没有字段名。** 一条消息就是把它的每个字段，按 `[tag][value]`（或 `[tag][length][value]`）一个接一个拼起来。字段名（`name`、`age`）只存在于 `.proto` 和生成的代码里，**网络上一个字节都不传**。

这就是 Protobuf 比 JSON 小的根本原因：JSON 每个对象都要把 key（`"name"`、`"age"`）当字符串重复传；Protobuf 只传一个数字 tag。

### 4.2 Tag = 字段号 << 3 | wire type

每个字段以一个 **tag** 开头，tag 本身是个 varint，由两部分按位拼成：

```
   tag = (field_number << 3) | wire_type
          ┌──────────────┐    ┌────────┐
          高位：字段号      低 3 位：wire type
```

- 低 3 位是 **wire type**（线类型），告诉解码器“接下来的 value 怎么读、读几个字节”。3 位能表示 8 种，实际用了 6 种。
- 其余高位是 **字段号**。

**5 种（实际在用的）wire type：**

| wire type | 名字 | 含义 | 对应的 `.proto` 类型 |
|---|---|---|---|
| 0 | VARINT | 变长整数 | `int32/int64/uint32/uint64/sint32/sint64/bool/enum` |
| 1 | I64 | 固定 8 字节 | `fixed64/sfixed64/double` |
| 2 | LEN | 长度前缀 + 内容 | `string/bytes/嵌套message/packed repeated` |
| 5 | I32 | 固定 4 字节 | `fixed32/sfixed32/float` |
| 3 / 4 | SGROUP/EGROUP | 已废弃的 group | （别用） |

> **工程细节，面试爱问**：因为 tag 是 varint，字段号 **1~15** 的 tag 只占 **1 个字节**（`(15<<3)|7 = 127`，刚好 1 字节 varint 的上限）；字段号 **16~2047** 的 tag 要 **2 个字节**。所以官方建议：**把最高频、尤其是 `repeated` 里反复出现的字段，分配在 1~15 号**，能实打实省流量。字段号合法范围是 `1 ~ 2^29-1`，其中 `19000~19999` 被 protobuf 实现保留。

### 4.3 Varint：小数字省字节的代价是大数字膨胀

VARINT（wire type 0）是 Protobuf 省字节的主力。规则：

- 每个字节只用 **低 7 位存数据**，**最高位（MSB）是 continuation bit**：1 = “后面还有字节”，0 = “这是最后一个字节”。
- **小端**：低位组在前。

来看 Protobuf 官方的经典例子，`int32 a = 1;`，值 `a = 150`：

```
field_number = 1, wire_type = 0(VARINT)
tag = (1 << 3) | 0 = 0x08

value 150 编码成 varint：
  150 = 0b1001_0110
  按 7 位一组（从低位切）：
     低 7 位: 001_0110 = 22
     剩余:    1
  第 1 字节（低组）：补 continuation=1 → 1_0010110 = 0x96
  第 2 字节（高组）：补 continuation=0 → 0_0000001 = 0x01

所以 a=150 的完整编码：  08 96 01      （3 个字节）
                        ↑  ↑  ↑
                       tag 低组 高组
```

解码时反着来：`0x96` 最高位是 1（还有后续），取低 7 位 = `0010110`；`0x01` 最高位是 0（结束），取低 7 位 = `0000001`；按小端拼：`0000001_0010110` = 150。✓

**varint 的代价**：数字越大，字节越多。`< 128` 用 1 字节，`< 16384` 用 2 字节……一个满 32 位的大数要 5 字节，满 64 位要 **10 字节**。所以：

- 字段值通常很小（ID、计数、状态码）→ varint 大赚。
- 字段值通常很大且分布均匀（哈希值、随机 ID）→ varint 不如定长，这时该用 `fixed32/fixed64`（永远 4/8 字节，且解码更快，不用逐位拼）。

### 4.4 Zigzag：负数的专门解法，以及 `int32` 存 `-1` 的 10 字节惨案

这是**面试最爱、生产最容易踩**的一个点。

普通 varint 是给非负数设计的。那负数怎么办？Protobuf 规定：`int32/int64` 的负数用**补码**编码，而且为了让 `int32` 和 `int64` 在 wire 上兼容，**负的 `int32` 会先符号扩展到 64 位**再编码。

后果很惨：`int32 x = -1;`，`-1` 的 64 位补码是 `0xFFFFFFFF_FFFFFFFF`（64 个 1），varint 编码需要 `⌈64/7⌉ = 10` 个字节！

```
int32 字段存 -1：
  FF FF FF FF FF FF FF FF FF 01   ← 整整 10 个字节，存一个 -1
```

只要你的 `int32/int64` 字段**经常出现负数**（增量、温度、坐标偏移、有符号差值……），用 `int32` 就是流量灾难。

解法就是 **`sint32/sint64`**，它们用 **ZigZag 编码**：把有符号数映射成无符号数，让**绝对值小的数（不管正负）都编码成小的 varint**。

```
ZigZag 映射： 0→0, -1→1, 1→2, -2→3, 2→4, -3→5 ...
编码公式（32 位）： zigzag(n) = (n << 1) ^ (n >> 31)   // >> 是算术右移
解码公式：         n = (z >> 1) ^ -(z & 1)
```

于是 `sint32 x = -1;`：`zigzag(-1) = 1`，varint(1) = `0x01`，**1 个字节**。

```
        存 -1          存 -1000000
int32:  10 字节        10 字节        ← 负数一律惨
sint32: 1 字节         3 字节         ← 绝对值小就小
```

**口诀：字段可能为负 → 用 `sint32/sint64`；字段几乎总是非负 → `int32/int64` 即可；字段是大随机数 → `fixed32/fixed64`。** 这三句要背下来，是真能省钱的工程决策。

### 4.5 Length-delimited（wire type 2）：string / bytes / 嵌套消息 / packed

wire type 2 的结构是 `[tag][length(varint)][length 个字节的内容]`。`string`、`bytes`、嵌套 `message`、packed 的 `repeated` 全走这条。

官方例子，`string b = 2;`，值 `b = "testing"`：

```
tag = (2 << 3) | 2 = 0x12
length = 7
"testing" 的 UTF-8 = 74 65 73 74 69 6e 67

完整编码：  12 07 74 65 73 74 69 6e 67
            ↑  ↑  └──── "testing" ────┘
           tag len
```

**关键洞察：嵌套 message 的编码 == 它自己序列化后的字节，外面套一个 length。** 也就是说，一个 `message` 字段在 wire 上和一个 `bytes` 字段长得**一模一样**。这直接导致两个重要结论（第六节兼容性会用到）：

1. `message` 字段和 `bytes` 字段在 wire 上兼容——你可以把一个嵌套 message 当 bytes 接收（拿到它的原始序列化字节）。
2. 解码一条消息时，遇到不认识的字段号 + wire type 2，解码器知道“跳过 length 个字节”就行，不用懂内容——这是**未知字段能被安全跳过 / 保留**的底层原因。

### 4.6 Packed repeated：列表的紧凑编码

`repeated int32 nums = 4;` 存 `[3, 270, 86942]`，proto3 默认对标量 repeated 用 **packed**：不是给每个元素都来一遍 tag，而是“一个 tag + 一个 length + 所有元素的 value 连续摆放”。

```
非 packed（proto2 默认）：tag val tag val tag val   ← 每个元素都带 tag，浪费
packed   （proto3 默认）：tag len val val val        ← 共用一个 tag

[3, 270, 86942] packed，字段号 4：
  tag = (4<<3)|2 = 0x22       （注意 wire type 变成 2/LEN！）
  len = 6
  3      = 03
  270    = 8E 02
  86942  = 9E A7 05
  完整：  22 06 03 8E 02 9E A7 05
```

注意 packed 让 repeated 标量的 wire type 变成 **2（LEN）**，而不是元素本身的类型。packed 只适用于**标量数值**（varint/I32/I64 类），`string/bytes/message` 的 repeated 不能 packed（它们本来就是 LEN，各带各的 tag）。

> 兼容性彩蛋：packed 和非 packed 在解码端是**互相兼容**的——解码器两种都能读。所以从 proto2（非 packed）升 proto3（packed）不会因为这个炸。

### 4.7 把一条完整消息拼起来

```protobuf
message Person { string name = 1; int32 id = 2; repeated int32 scores = 3; }
```

`name="ab", id=150, scores=[1,2]`：

```
name:   tag=(1<<3)|2=0x0A  len=2  "ab"=61 62        →  0A 02 61 62
id:     tag=(2<<3)|0=0x10  150=96 01                →  10 96 01
scores: tag=(3<<3)|2=0x1A  len=2  1=01 2=02         →  1A 02 01 02

整条消息： 0A 02 61 62 10 96 01 1A 02 01 02   （11 字节）
```

同样的数据，JSON 是 `{"name":"ab","id":150,"scores":[1,2]}`（37 字节）。3 倍多的差距，主要来自 JSON 重复传 key 和数字转字符串。**这就是“Protobuf 快/小”的字节级真相——不是魔法，是不传字段名 + varint。**

## 五、字段号是契约的“主键”，字段名只是给人看的

把第四节的洞察提炼成一句必须刻进脑子的话：

> **在 wire format 里,唯一标识一个字段的是字段号（field number），不是字段名。**

由此推出一串“反直觉但正确”的结论，全是工程实践的依据：

- **字段改名是安全的**（对二进制而言）。`string name` 改成 `string username`，只要字段号不变，老服务和新服务的二进制完全互通。（但 JSON 映射、生成代码的 API 会变，见生产问题。）
- **字段在文件里的顺序无所谓**。决定编码的是字段号，不是它写在第几行。
- **改字段号 = 换了个字段**。把 `name` 的字段号从 1 改成 5，等于“删了字段 1、加了字段 5”，老数据里的字段 1 会变成新代码眼里的未知字段，新代码读不到 name 了。**改字段号是最危险的改动之一。**
- **删字段后必须 `reserved` 那个字段号**，否则将来有人新增字段复用了这个号，老数据里残留的旧字段会被新代码错误地当成新字段解读——静默数据错乱，没有任何报错。

```protobuf
message User {
  reserved 2, 5 to 8;            // 这些字段号永久封存，禁止复用
  reserved "old_email", "tmp";   // 这些字段名也封存
  string name = 1;
  string email = 9;              // 新字段用新号，不碰封存区
}
```

## 六、兼容性规则：能改什么、不能改什么（灰度发布的生死线）

Protobuf 的兼容性分两个方向，微服务里两个都要：

- **后向兼容（backward）**：新代码能读老数据 / 老消息。
- **前向兼容（forward）**：老代码能读新数据 / 新消息（读不懂的新字段不报错、最好还能保留）。

灰度发布时，新老版本**同时在线、互相调用**，所以必须**双向兼容**。下面是可以 / 不可以的清单，这张表建议背下来。

### ✅ 可以安全做的

| 操作 | 为什么安全 |
|---|---|
| **新增字段**（用从没用过的字段号） | 老代码遇到不认识的字段号，按 wire type 跳过；proto3.5+ 还会**保留**为未知字段，透传不丢 |
| **删除字段** | 前提是 `reserved` 字段号和名字；老数据里的该字段变成未知字段被忽略 |
| **字段改名** | wire 只认字段号（但会影响 JSON 和代码 API） |
| `int32 ↔ int64 ↔ uint32 ↔ uint64 ↔ bool` 互转 | 都是 wire type 0(varint)，编码方式相同。**注意截断**：64 位的值塞进 32 位字段会截断高位 |
| `sint32 ↔ sint64` 互转 | 都是 zigzag varint |
| `fixed32 ↔ sfixed32`、`fixed64 ↔ sfixed64` | 同 wire type（5 / 1），只是有无符号解读不同 |
| `string ↔ bytes` | 都是 LEN；前提是 bytes 内容是合法 UTF-8 |
| `嵌套 message ↔ bytes` | message 编码就是“带 length 的 bytes” |
| 把**非 repeated** 字段升成 **repeated**（同类型） | 单个值会被当成只有一个元素的列表（packed 情况下） |

### ❌ 不能做的（做了就静默错乱或解析失败）

| 操作 | 为什么炸 |
|---|---|
| **改字段号** | 等于删旧加新，引用关系断裂 |
| **复用已删除的字段号**（没 reserved） | 老数据残留字段被新字段错误解读 |
| `int32 ↔ sint32`、`int64 ↔ sint64` | **wire type 都是 0，但一个是补码、一个是 zigzag！** 编码规则不同，会读出完全错误的数值（且不报错！） |
| `int32 ↔ fixed32`、`int64 ↔ fixed64` | wire type 不同（0 vs 5/1），解码器按错误长度读，结构错乱 |
| `string ↔ int32` 等跨 wire type 改 | 同上，wire type 对不上 |
| 把单个字段移进 / 移出 `oneof` | oneof 的内存布局和编码语义特殊，移动不安全 |

> **最阴险的一条**：`int32 → sint32`。两者 wire type 都是 0，protoc **编译不会报错**、字段号也没变，看起来“只是换了个整数类型”，但因为补码 vs zigzag 的编码差异，**新老版本互发数据会读出垃圾值，且全程静默**。这正是开头第 01 篇生产问题 Q5 说的那类灰度事故的典型。

## 七、proto3 默认值的坑，与 `optional` 的回归

第三节埋了个伏笔：proto3 砍掉标量字段的 presence，带来一个经典坑。

proto3 里，标量字段的值**等于默认值时（0 / "" / false），序列化时根本不编码**（省字节）。解码端拿到的就是默认值。问题来了：

> **你无法区分「用户显式设了 0」和「用户根本没设这个字段」。**

这在很多场景是致命的：

- **PATCH / 部分更新**：`UpdateUser{ balance = 0 }`，你想把余额改成 0，但服务端收到的 `balance=0` 和“没传 balance”一模一样，没法判断用户到底是不是想清零。
- **开关类字段**：`bool enabled`，`false` 和“没设置”分不清，没法实现“默认 true、显式 false”。
- **三态语义**：是 / 否 / 未知，proto3 标量天生表达不了。

早期大家用各种丑陋的 workaround：包一层 `google.protobuf.Int32Value`（wrapper message，message 有 presence），或者额外加个 `bool has_balance` 字段。

**proto3.15+（2021 起）正式让 `optional` 关键字回归**：

```protobuf
message UpdateUser {
  optional int64 balance = 1;   // 现在能区分“设了 0”和“没设”了
}
```

加了 `optional`，就给这个标量字段**找回了 explicit presence**，生成代码里 `has_balance()` 回来了。底层实现是把它**编译成一个单字段的 `oneof`**（所以会多占一点点），但用起来透明。

**实践建议**：凡是“需要区分 0 和未设置”的标量字段（金额、开关、可空数值），一律加 `optional`。这是 proto3 现在的推荐做法，别再手动包 wrapper 了。

## 八、本章小结

- Protobuf 在 gRPC 里是**契约（IDL）+ 序列化格式**双重身份；这一篇重点是后者。
- wire format 的灵魂：**不传字段名，只传 `tag = 字段号<<3 | wire type`**，这是它比 JSON 小/快的根本。
- **varint** 让小数字省字节、大数字膨胀；负数千万别用 `int32`（`-1` 要 10 字节），用 **`sint32`（zigzag）**；大随机数用 **`fixed`**。
- length-delimited 让 string/bytes/嵌套 message **同构**，这是“未知字段能安全跳过/保留”的底层原因。
- **字段号是契约主键**：改名安全、改号致命、删字段要 `reserved`。
- 兼容性双向都要：记牢“能改 / 不能改”两张表，最阴险的是 `int32↔sint32`（静默读出垃圾）。
- proto3 砍 `required` 是为契约演进；砍标量 presence 带来“0 vs 未设置”坑，用 **`optional`** 找回。

---

## 生产常见问题

**Q1：监控发现某 gRPC 接口流量异常大、带宽打满，排查发现是一个 `int32` 字段。怎么回事？**

大概率这个字段**经常是负数**。`int32/int64` 存负数时会符号扩展到 64 位再 varint，**任何负数都固定占 10 字节**。如果这是个高频字段（比如每条消息都带、或者在大 `repeated` 里），10 字节 × 海量条数就是可观的带宽。改成 `sint32/sint64`（zigzag），负数的绝对值小就编码小，`-1` 从 10 字节降到 1 字节。**排查口诀：负数字段看类型,是不是误用了 `int*` 而非 `sint*`。**

**Q2：灰度发了个新版本，只是把一个字段从 `int32` 改成了 `sint32`（“反正都是整数”），结果新老实例互调时这个字段的值全乱了，还不报错，为什么？**

因为 `int32` 用**补码** varint、`sint32` 用 **zigzag** varint，**wire type 同为 0 但编码规则完全不同**。protoc 不会拦你（字段号没变、类型“看起来兼容”），但运行时新实例发的 zigzag 字节被老实例当补码读、反之亦然，读出的是**语义错误但格式合法**的垃圾值——所以**静默、无异常**，最难查。整数类型族里，只有 `int↔uint↔bool`、`sint32↔sint64`、`fixed↔sfixed` 这几组内部能互转，**`int* 和 sint* 之间是雷区**。

**Q3：删了一个废弃字段，过几个迭代后新增字段时随手复用了那个字段号，线上开始出现莫名其妙的数据错乱，没有任何报错。**

经典“字段号复用”事故。系统里还在流转的**老消息**带着旧字段（用的是那个号），新代码把这个号解读成新字段——wire type 凑巧兼容时就**静默错乱**，凑巧不兼容时报解析错。**铁律：删字段必须 `reserved` 字段号（和字段名）**，永久封存，禁止任何人复用。这条没有例外。

**Q4：proto3 里 `bool enabled` / `int64 amount`，业务要支持“不传则用默认、传 0/false 表示显式关闭/清零”，但服务端死活区分不出来。**

proto3 标量没有 presence，值 == 默认值时根本不上线（不编码），服务端收到的“0”和“没传”无法区分。解法：给字段加 **`optional`**（proto3.15+），找回 `has_xxx()`；老版本环境则用 `google.protobuf.Int64Value` / `BoolValue` 这类 wrapper message（message 有 presence）。**凡是需要区分“0 和未设置”的标量,默认加 `optional`。**

**Q5：API 网关（grpc-gateway）做 gRPC↔JSON 转换，前端反馈某字段在 JSON 里突然消失/改名，但后端说“我二进制兼容啊没动字段号”。**

二进制兼容 ≠ JSON 兼容。Protobuf 的 **JSON 映射用的是字段名**（默认 camelCase），不是字段号。所以**字段改名**虽然对 gRPC 二进制完全无害，却会**改变 JSON 字段名**，把对接 JSON 的前端 / 第三方搞挂。结论：纯内部 gRPC，改名随意；一旦这个 proto 还经 grpc-gateway / gRPC-Web 暴露成 JSON，**字段名就也成了对外契约的一部分**，不能随便改。（互操作详见第 14 篇。）

**Q6：中间有个透传服务（router/网关），只认识消息的部分字段、转发给下游。升级下游加了新字段后，发现新字段在透传节点“被吃掉”了，下游收不到。**

这是**未知字段保留**的问题。proto3 在 **3.5 之前**会**丢弃**未知字段，透传节点用老 proto 反序列化再重新序列化时，不认识的新字段就没了。3.5+ 改回**保留**未知字段（和 proto2 一致）。排查：升级透传节点的 protobuf 运行时到 3.5+；或者透传层别做“反序列化→再序列化”，直接转发原始字节。**透传/网关类服务尤其要确认 protobuf 版本支持未知字段保留。**

---

> 下一篇 `03_HTTP/2 深挖`：gRPC 的另一块地基。我们会讲清楚 gRPC 为什么**必须**是 HTTP/2 而不是 HTTP/1.1——Stream / Frame 的二进制分帧、一条连接如何多路复用几百个请求、HPACK 怎么压头、流控（flow control）是什么、以及多路复用把“应用层队头阻塞”消掉之后，又怎么把队头阻塞**推到了 TCP 层**（这正是 HTTP/3 要换 QUIC 的原因）。把 02、03 两块地基打牢，第 04 篇就能把“一次 gRPC 调用”逐字节拆给你看。
