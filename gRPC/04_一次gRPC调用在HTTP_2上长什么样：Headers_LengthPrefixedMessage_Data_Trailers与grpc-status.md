# 04 一次 gRPC 调用在 HTTP/2 上长什么样：Headers / Length-Prefixed-Message / Data / Trailers 与 grpc-status

> 前两篇打了地基:02 讲 Protobuf 的字节,03 讲 HTTP/2 的帧。这一篇把它们合起来,逐字节拆解一次真实的 unary 调用。能不能讲清“`grpc-status` 为什么必须在 trailer”“那 5 个字节前缀里装了什么”,是“面过 gRPC”和“真懂 gRPC”的第一道分水岭。这一篇之后,你抓包看 gRPC 就不再是“一堆乱码”。

我们全程用同一个例子:

```protobuf
package helloworld;
service Greeter { rpc SayHello (HelloRequest) returns (HelloReply); }
message HelloRequest { string name = 1; }
message HelloReply   { string message = 1; }
```

客户端调用 `SayHello(HelloRequest{ name: "world" })`,服务端返回 `HelloReply{ message: "Hello world" }`。

## 一、鸟瞰:一次 unary 调用的完整帧序列

先看全景。一次最普通的一问一答,在一条 HTTP/2 连接的**一个 stream**(假设 Stream ID = 1)上,帧是这样流动的:

```
客户端                                                        服务端
  │                                                             │
  │  ① HEADERS (Stream 1)  ── 请求头 / initial metadata ──────► │
  │      :method=POST  :path=/helloworld.Greeter/SayHello       │
  │      content-type=application/grpc  te=trailers ...         │
  │                                                             │
  │  ② DATA    (Stream 1, END_STREAM) ── 请求消息 ────────────► │
  │      [5字节前缀][HelloRequest 序列化]                         │
  │      END_STREAM=客户端“我说完了”(半关闭)                      │
  │                                                             │
  │ ◄────── ③ HEADERS (Stream 1) ── 响应头 / initial metadata   │
  │              :status=200  content-type=application/grpc     │
  │                                                             │
  │ ◄────── ④ DATA    (Stream 1) ── 响应消息                    │
  │              [5字节前缀][HelloReply 序列化]                   │
  │                                                             │
  │ ◄────── ⑤ HEADERS (Stream 1, END_STREAM) ── Trailers!       │
  │              grpc-status=0  grpc-message=...                │
  │              END_STREAM=服务端“我也说完了”→ stream 关闭        │
```

**五个帧,三个 HEADERS 两个 DATA。** 记住这个骨架,下面逐个拆。注意三件事,它们是 gRPC 区别于普通 HTTP 的核心:

- 请求和响应**各有一个 HEADERS 在前**(请求头 / 响应头),叫 **initial metadata**。
- 真正的业务状态码 `grpc-status` **不在响应头里**,而在**最后那个 HEADERS 帧(Trailers)** 里。
- DATA 帧里不是裸 protobuf,前面套了 **5 字节前缀**(Length-Prefixed-Message)。

## 二、请求 HEADERS:伪头部 + gRPC 专用头 + metadata

第①帧 HEADERS,逻辑内容(HPACK 压缩前)长这样:

```
:method        = POST                              ← 永远 POST
:scheme        = https                             ← 或 http(h2c)
:path          = /helloworld.Greeter/SayHello      ← 方法定位,见第三节
:authority     = greeter.svc:50051                 ← 相当于 Host
content-type   = application/grpc                  ← 必须以 application/grpc 开头
te             = trailers                          ← 关键!声明“我能收 trailer”
grpc-timeout   = 1S                                ← deadline 的传输形式(可选)
grpc-encoding  = gzip                              ← 本条消息的压缩算法(可选)
grpc-accept-encoding = gzip,identity               ← 我能解的压缩(可选)
user-agent     = grpc-go/1.60.0                    ← 实现 + 版本
authorization  = Bearer xxx                        ← 你的自定义 metadata(可选)
trace-id       = abc123                             ← 你的自定义 metadata(可选)
```

逐类说明:

- **伪头部(pseudo-headers,带 `:` 的)**:`:method`/`:scheme`/`:path`/`:authority`,这是 HTTP/2 规定的,必须排在普通头前面。gRPC 里 `:method` 恒为 `POST`,语义全靠 `:path`。
- **`content-type`**:必须以 `application/grpc` 开头。可带后缀表示编码:`application/grpc+proto`(默认)、`application/grpc+json` 等。代理常靠这个头识别“这是 gRPC 流量”。
- **`te: trailers`**:**必须有**。它声明客户端支持 HTTP trailer。HTTP/2 规范要求带 trailer 的响应必须先有这个声明。**这个头要是被中间代理吃掉,服务端可能就不发 trailer,`grpc-status` 丢失,客户端直接报错**(生产问题 Q4)。
- **`grpc-timeout`**:deadline 的线上形式,格式是 `数字 + 单位`,单位 `H/M/S/m/u/n`(时/分/秒/毫秒/微秒/纳秒)。`1S`=1 秒,`100m`=100 毫秒。它是“相对剩余时间”,每经过一跳服务都会扣减后再往下传(传播机制第 07 篇详讲)。
- **自定义 metadata**:就是普通 HTTP/2 头,经 HPACK 压缩。规则见第八节。

这些头大多在同一条连接上高度重复,**靠 03 篇讲的 HPACK 动态表压到几乎不占带宽**——这就是“gRPC metadata 便宜”的字节级原因。

## 三、`:path` 的构造:方法定位全靠它

gRPC 不用 HTTP method/REST 路径表达语义,而是把“调哪个服务的哪个方法”编码进 `:path`:

```
:path = "/" {package}.{Service} "/" {Method}

例:  package helloworld;  service Greeter { rpc SayHello(...) }
     →  /helloworld.Greeter/SayHello
          └──── 服务全名 ────┘ └ 方法名 ┘
```

要点:

- **前导 `/` 必须有**,服务全名是 `包名.服务名`,然后 `/方法名`。
- **大小写敏感**,且必须和 `.proto` 里的声明完全一致(服务名、方法名通常 PascalCase)。
- 服务端就是靠这个字符串路由到具体的方法处理器。`:path` 拼错 → 服务端找不到方法 → 返回 `UNIMPLEMENTED`(生产问题 Q2)。

## 四、DATA 帧里的 Length-Prefixed-Message:那 5 个字节

这是本篇最该记牢的细节。HTTP/2 的 DATA 帧 payload **不是裸 protobuf**,gRPC 在里面又套了一层自己的分帧,叫 **Length-Prefixed-Message**:

```
 ┌────────────┬──────────────────────┬─────────────────────────┐
 │ Compressed │   Message-Length     │      Message            │
 │  -Flag     │   (uint32, 大端!)    │   (protobuf 序列化字节)   │
 │  1 字节     │      4 字节          │      N 字节              │
 └────────────┴──────────────────────┴─────────────────────────┘
       │              │
       │              └─ 后面这条消息有多少字节(不含这 5 字节头)
       └─ 0 = 未压缩;1 = 已压缩(用 grpc-encoding 指定的算法,如 gzip)
```

- **第 1 字节 = 压缩标志**:`0x00` 未压缩,`0x01` 压缩。压缩时,`Message` 是被 `grpc-encoding`(如 `gzip`)压过的字节,解压后才是 protobuf。
- **第 2~5 字节 = 消息长度,uint32 大端序(network byte order)**。⚠️ 注意:**这里是大端**,而 02 篇讲的 protobuf 内部 varint 是**小端**——同一个 DATA 帧里两种字节序并存,这是个经典细节考点。
- **后面 N 字节 = 消息本体**(protobuf 序列化结果)。

我们的 `HelloRequest{ name: "world" }`:

```
protobuf 序列化(回顾 02 篇):
  name 字段号1, string(LEN): tag=(1<<3)|2=0x0A, len=5, "world"=77 6F 72 6C 64
  → 0A 05 77 6F 72 6C 64        （7 字节）

加 5 字节前缀:
  压缩标志 = 00
  长度 = 7 → 大端 uint32 = 00 00 00 07
  → 00 | 00 00 00 07 | 0A 05 77 6F 72 6C 64

DATA 帧 payload(共 12 字节):
  00 00 00 00 07 0A 05 77 6F 72 6C 64
  └┘ └────────┘ └──────────────────┘
 flag  len=7         "world" 消息
```

**为什么 HTTP/2 已经分帧了,gRPC 还要再套一层?** 因为 **HTTP/2 的 DATA 帧边界和 gRPC 的消息边界不是一回事**:

- 一条**大消息**(比如 1MB)会被 HTTP/2 拆到**多个 DATA 帧**里传(受 `MAX_FRAME_SIZE` 限制,默认每帧最大 16KB)。接收方怎么知道“这条消息到哪结束”?靠这个长度前缀。
- **流式调用**时,一个 DATA 帧里可能**连续装多条小消息**。接收方怎么切开?靠每条消息前面的 5 字节前缀。

所以这层 Length-Prefixed-Message 是 gRPC **自己的消息定界符**,独立于 HTTP/2 的帧定界。**unary 看不出它的必要性,一到流式就立刻体现价值**(第 05 篇)。

> 顺带:`Message-Length` 是个 uint32,理论上限 4GB,但 gRPC 默认有 **`max receive message size = 4MB`** 的保护。单条消息超过它,直接 `RESOURCE_EXHAUSTED`(生产问题 Q5)。

## 五、响应:两个 HEADERS,与 `grpc-status` 为什么非在 trailer 不可

响应方向有**两个 HEADERS 帧**,这是 gRPC 最容易被忽略、也最该理解的设计。

### ③ 响应 HEADERS(initial metadata / Response-Headers)

```
:status      = 200                       ← HTTP 状态!只要这条 HTTP 流正常,恒为 200
content-type = application/grpc
（可带服务端的自定义 initial metadata）
```

**`:status: 200` 只表示“HTTP 这条流本身没问题”,和业务成功与否毫无关系。** 业务是成功还是失败、失败原因是什么,全看后面的 trailer。

### ④ 响应 DATA

`HelloReply{ message: "Hello world" }`,同样加 5 字节前缀:

```
protobuf: tag=0x0A, len=11, "Hello world" = 48 65 6C 6C 6F 20 77 6F 72 6C 64
  → 0A 0B 48 65 6C 6C 6F 20 77 6F 72 6C 64   （13 字节）
前缀: 00 | 00 00 00 0D（长度13大端）
DATA payload: 00 00 00 00 0D 0A 0B 48 65 6C 6C 6F 20 77 6F 72 6C 64
```

### ⑤ Trailers(Trailing-Metadata):真正的状态码在这

最后一个 HEADERS 帧,**带 `END_STREAM` 标志**,装的是 trailer:

```
grpc-status   = 0          ← 真正的 RPC 状态码!0 = OK,非 0 见第 09 篇
grpc-message  = OK         ← 错误描述(percent-encoded),成功时常省略
grpc-status-details-bin    ← 富错误模型(google.rpc.Status),可选,第 09 篇
（服务端的自定义 trailing metadata）
```

**核心问题:为什么 `grpc-status` 不能像 `:status` 一样放在响应头(initial metadata),非要放在流末尾的 trailer?**

答案是 **流式**。考虑 server streaming:服务端要先连续推 1000 条 DATA 帧,**全部推完了,它才知道这次到底是成功结束、还是中途出错**。如果状态码要放在最前面的响应头里,服务端在还没开始推数据时就得先知道最终结果——这对“边算边推”的流式是不可能的。

所以 gRPC 的设计是:**响应头(initial metadata)先发,表示“我开始回了”;数据流随后;最终状态码放在所有数据之后的 trailer 里,表示“流到此结束,结果是这个”。** unary 只是流的特例(只有一条响应消息),但沿用同一套机制,所以 unary 的 `grpc-status` 也在 trailer。

这一个设计决策,连带解释了好几件事:

- **为什么请求里必须有 `te: trailers`**:不声明支持 trailer,这套机制就玩不转。
- **为什么浏览器不能直连原生 gRPC**:浏览器的 `fetch`/XHR **拿不到 HTTP/2 trailer**,也就读不到 `grpc-status`,所以必须用 gRPC-Web 把状态搬到别处(第 14 篇)。
- **为什么抓包要看“流的最后”**:只看响应头会以为“200 成功了”,真正的成败要翻到末尾的 trailer 帧(生产问题 Q3)。

## 六、Trailers-Only:错误的快速路径

有一种特例:服务端**还没产出任何响应消息就要失败**(方法不存在、鉴权没过、参数非法被立即拒绝)。这时没有 DATA 要发,gRPC 允许把 initial metadata 和 trailer **合并成一个 HEADERS 帧**(带 END_STREAM)发回,叫 **Trailers-Only** 响应:

```
单个 HEADERS 帧(END_STREAM):
  :status      = 200
  content-type = application/grpc
  grpc-status  = 5            ← 比如 NOT_FOUND
  grpc-message = method not found
```

省掉了“先发响应头、再发 trailer”的两次,错误返回更快。**但有些老旧代理 / 老客户端对 Trailers-Only(尤其是把 `:status` 和 `grpc-status` 塞一个帧)处理有 bug**,会解析失败——这是个真实的兼容性坑(生产问题 Q6)。

另外补一句 HTTP↔gRPC 状态映射:正常情况 `:status` 恒 200,业务错误走 `grpc-status`。但如果 `:status` **不是** 200(比如经过代理时被改成 502/503/404),gRPC 客户端会按规范把 HTTP status **映射成对应的 grpc-status**(如 404→UNIMPLEMENTED、401→UNAUTHENTICATED、429/502/503/504→UNAVAILABLE)。所以你有时看到的 `UNAVAILABLE` 其实是代理返回的 HTTP 503 被翻译过来的(第 09、17 篇细讲)。

## 七、把一次完整调用的字节拼出来

合到一起,`SayHello("world") → "Hello world"` 在线上就是这串帧(HEADERS 用逻辑视图,DATA 用真实字节):

```
─── 客户端发出 ────────────────────────────────────────────────
① HEADERS  (Stream 1)
     :method=POST  :scheme=https
     :path=/helloworld.Greeter/SayHello  :authority=greeter:50051
     content-type=application/grpc  te=trailers  grpc-timeout=1S
② DATA     (Stream 1, END_STREAM)
     00 00 00 00 07 0A 05 77 6F 72 6C 64
     └flag┘└─len=7─┘└── "world" ──┘

─── 服务端返回 ────────────────────────────────────────────────
③ HEADERS  (Stream 1)                ← initial metadata
     :status=200  content-type=application/grpc
④ DATA     (Stream 1)
     00 00 00 00 0D 0A 0B 48 65 6C 6C 6F 20 77 6F 72 6C 64
     └flag┘└len=13─┘└──── "Hello world" ────┘
⑤ HEADERS  (Stream 1, END_STREAM)    ← trailers
     grpc-status=0
```

这就是“一次 gRPC 调用”的真身。回头看第 01 篇生产问题 Q3(“抓包全是乱码、看不出成败”),现在你能完全解释:POST 是 `:method`、乱码是“5 字节前缀 + protobuf”、200 是 HTTP 层的、真正成败是末尾那个 `grpc-status=0`。

## 八、metadata 的规则:key / value / -bin / 保留前缀

metadata 就是 gRPC 的“自定义 HTTP 头”,用来透传 trace id、token、租户信息等(用法第 08 篇)。但它有**硬性格式规则**,违反就报错:

- **key**:大小写**不敏感**,传输时一律转**小写**;合法字符限 `a-z 0-9 - _ .`。大写、空格、中文、冒号开头都非法。
- **普通 value**:必须是**可打印 ASCII**(以及空格)。想放二进制 / 非 ASCII(如中文、protobuf 字节)会报错。
- **`-bin` 后缀 = 二进制 metadata**:key 以 `-bin` 结尾(如 `trace-context-bin`),value 就可以是任意二进制,gRPC 库会自动 **base64 编解码**。**要放二进制或非 ASCII,必须用 `-bin` 后缀**(生产问题 Q7)。
- **保留前缀**:`grpc-` 开头的 key 是 gRPC 内部保留(`grpc-timeout`、`grpc-encoding`、`grpc-status`…),业务别用;`:` 开头的伪头部更不能碰;`content-type`、`te`、`user-agent` 也是协议占用。
- 这些 metadata 都经 **HPACK** 压缩;高频固定的 key/value 会进动态表,几乎不占增量带宽。

## 九、content-type 与编码协商

- **`content-type`** 决定 gRPC 消息体的编码:`application/grpc` / `application/grpc+proto`(默认 protobuf)、`application/grpc+json`(用 JSON 编码消息体,少见但 gRPC 支持可插拔编码)。gRPC-Web 用 `application/grpc-web` / `application/grpc-web+proto`(第 14 篇)。
- **压缩**走 `grpc-encoding`(本条消息用什么压)和 `grpc-accept-encoding`(我能解哪些)。注意 gRPC 的压缩是**逐消息**的(那个 5 字节前缀里的压缩标志),不是 HTTP 层的 `Content-Encoding`。压缩对大消息省带宽,但耗 CPU,小消息可能得不偿失(调优第 15 篇)。

## 十、本章小结

- 一次 unary 调用 = **5 个帧**:请求 `HEADERS → DATA(END_STREAM)`,响应 `HEADERS → DATA → HEADERS(END_STREAM, trailers)`。
- 请求头里 `:method=POST`、`:path=/包.服务/方法`、`content-type=application/grpc`、**`te: trailers` 必须有**、`grpc-timeout` 是 deadline。
- DATA 里是 **Length-Prefixed-Message**:`1 字节压缩标志 + 4 字节大端长度 + protobuf`。它是 gRPC 自己的消息定界,unary 看不出必要性,**流式才显威力**。
- **`grpc-status` 在 trailer,不在响应头**——因为流式要“先推数据、最后才知道结果”。这一个决策连带解释了 `te: trailers` 必需、浏览器不能直连、抓包要看流末尾。
- **HTTP `:status` 恒 200**(代理异常时例外,会被映射成 grpc-status);真正的成败看 `grpc-status`。
- metadata 规则:key 小写、value ASCII、二进制要 `-bin`、`grpc-` 前缀保留。

---

## 生产常见问题

**Q1:Wireshark 抓 gRPC,怎么才能看懂、而不是一堆 TCP/TLS 乱码?**

① 明文 h2c 才能直接解;② Wireshark 要启用 **HTTP2 + GRPC dissector**(并配上 `.proto` 让它解 protobuf body);③ TLS(h2)流量必须先用 `SSLKEYLOGFILE` 导出会话密钥喂给 Wireshark 才能解密;④ 看懂后,注意把**响应的最后一个 HEADERS 帧(trailers)**翻出来看 `grpc-status`,别只看前面那个 `:status: 200`。嫌麻烦就直接用 `grpcurl`(配合 server reflection)发请求看结构化结果。

**Q2:客户端报 `UNIMPLEMENTED: unknown method` / `unknown service`,但方法明明实现了。**

九成是 **`:path` 对不上**。检查:① 客户端用的 package + service + method 名是否和服务端 `.proto` 完全一致(大小写敏感);② 服务端是否真的注册了这个 service 实现;③ 中间是否有代理改写了路径。`:path` 的格式是 `/{package}.{Service}/{Method}`,任何一处大小写或包名不符都会 `UNIMPLEMENTED`。

**Q3:接口“调用成功了”(HTTP 200、有响应体),但业务说其实是失败的 / 客户端却抛了异常,矛盾。**

因为 **HTTP `:status: 200` ≠ 业务成功**。gRPC 的成败在 **trailer 的 `grpc-status`**:`0` 才是 OK,非 0 是各种错误(第 09 篇)。你看到的“200 + 有响应体 + 客户端抛异常”,通常是服务端先发了部分数据、最后 trailer 里给了非 0 的 `grpc-status`。排查一律以 `grpc-status` 为准,不要看 HTTP status。

**Q4:经过 Nginx / 某些代理后,客户端偶发 `Internal: server closed the stream without sending trailers` / 丢 `grpc-status`。**

trailer 被中间代理**吞掉或不转发**了。HTTP trailer 是相对小众的特性,部分代理默认不转发,或在 `te: trailers` 被它剥掉后服务端就不发 trailer。排查:① 用**对 gRPC 友好的代理**(Envoy、或 Nginx 用 `grpc_pass` 且版本支持);② 确认 `te: trailers` 全链路透传;③ 别在 gRPC 链路里塞只懂 HTTP/1.1 的老代理。这是“`grpc-status` 在 trailer”这个设计在工程上最常见的副作用。

**Q5:大请求 / 大响应报 `RESOURCE_EXHAUSTED: received message larger than max (xxx vs 4194304)`。**

撞上了 gRPC 默认的 **max message size = 4MB**(那 4 字节长度前缀指示的消息体超限)。解法:① 评估是否真该传这么大(大 payload 考虑分页、流式、或走对象存储传引用);② 确需则两端都调大 `maxInboundMessageSize`/`MaxRecvMsgSize`(**发送端和接收端、以及中间代理都要调**,任一处没调都会拦);③ 注意调太大有 OOM 风险。详见第 15 篇调优。

**Q6:服务端返回错误时,某些老客户端 / 老代理解析失败、连错误信息都拿不到。**

可能是 **Trailers-Only 响应**(把 `:status` 和 `grpc-status` 合并在一个 HEADERS 帧)触发了对端的兼容性 bug,老实现可能期望“先 initial headers 再 trailers”的两段式。排查:升级两端 gRPC 库 / 代理版本;或在服务端配置上避免某些极端的 Trailers-Only 路径。这是协议合法、但实现参差导致的边角坑。

**Q7:往 metadata 里塞 trace 上下文 / protobuf 字节 / 中文,报错 “Header value xxx contains non-ASCII” 或值乱码。**

metadata 普通 value 只能是 **ASCII**。要放二进制或非 ASCII(protobuf 序列化的 trace context、中文),**key 必须用 `-bin` 后缀**(如 `grpc-trace-bin`、`tenant-info-bin`),gRPC 会自动 base64 编解码。另外 key 不能有大写 / 空格 / 非法字符。用法见第 08 篇。

---

> 下一篇 `05_四种调用类型`:把这一篇的“5 帧骨架”推广到流式。Unary 只是“请求 1 条 + 响应 1 条”的特例;server streaming 是“请求 1 条 + 响应 N 条 DATA”、client streaming 是“请求 N 条 + END_STREAM 半关闭 + 响应 1 条”、双向流是“两个方向的 DATA 同时来回飞”。我们会把每种的帧序列、半关闭语义、以及各自的适用场景和坑讲清楚——你会看到第四节那 5 字节前缀在流式里才真正大放异彩。
