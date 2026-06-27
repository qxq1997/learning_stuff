# 05 四种调用类型：Unary / Server Streaming / Client Streaming / BiDi 的语义与边界

> 上一篇把一次 unary 调用拆成了“5 帧骨架”。这一篇要让你看到:**unary 只是流的退化特例**。把骨架里“请求 1 条 DATA、响应 1 条 DATA”这两处各自放开成“N 条”,就长出了另外三种调用类型。这一篇的灵魂概念是**半关闭(half-close)**——它是理解所有流式行为、以及流式那些 hang 死 / 泄漏坑的钥匙。

## 一、四种类型总览

gRPC 的四种调用类型,本质是“请求方向几条消息 × 响应方向几条消息”的四种组合:

| 类型 | 请求 | 响应 | `.proto` 写法 | 一句话场景 |
|---|---|---|---|---|
| **Unary**(一元) | 1 | 1 | `rpc M(Req) returns (Resp)` | 绝大多数 CRUD / 查询 |
| **Server streaming**(服务端流) | 1 | N | `rpc M(Req) returns (stream Resp)` | 大结果集分批、订阅推送、LLM token 流 |
| **Client streaming**(客户端流) | N | 1 | `rpc M(stream Req) returns (Resp)` | 上传分片、批量上报、聚合 |
| **Bidirectional**(双向流) | N | N | `rpc M(stream Req) returns (stream Resp)` | 聊天、信令、实时双向交互 |

注意 `.proto` 里的差别只是 **`stream` 关键字加在请求侧、响应侧、还是两侧**:

```protobuf
service Demo {
  rpc Unary       (Req)        returns (Resp);         // 1 → 1
  rpc ServerStream(Req)        returns (stream Resp);  // 1 → N
  rpc ClientStream(stream Req) returns (Resp);         // N → 1
  rpc BiDi        (stream Req) returns (stream Resp);  // N → N
}
```

**底层全是同一套机制**:都跑在**一个 HTTP/2 stream** 上,都用 04 篇那套 HEADERS / DATA / TRAILERS 帧,都用 5 字节前缀切消息。区别只在“每个方向发几条 DATA、什么时候 END_STREAM”。

## 二、帧序列:把 5 帧骨架推广到四种

### Unary(1 → 1)——上一篇已拆,作为基准

```
C ─ HEADERS ──────────────────────────────► S   请求头
C ─ DATA(END_STREAM) ──────────────────────► S   1 条请求消息 + 客户端半关闭
C ◄────────────────────────────── HEADERS ─ S   响应头
C ◄────────────────────────────── DATA ──── S   1 条响应消息
C ◄────────────── HEADERS(END_STREAM) ───── S   trailers(grpc-status) + 服务端半关闭
```

### Server streaming(1 → N)——响应侧放开成多条 DATA

```
C ─ HEADERS ──────────────────────────────► S   请求头
C ─ DATA(END_STREAM) ──────────────────────► S   1 条请求 + 客户端立刻半关闭
C ◄────────────────────────────── HEADERS ─ S   响应头
C ◄────────────────────────────── DATA ──── S   响应消息 #1
C ◄────────────────────────────── DATA ──── S   响应消息 #2
C ◄────────────────────────────── DATA ──── S   ...... #N(边算边推)
C ◄────────────── HEADERS(END_STREAM) ───── S   trailers + 服务端半关闭
```

客户端只发一条请求,**立刻半关闭**(“我说完了,你慢慢推”);服务端连推 N 条 DATA,推完用 trailer 收尾。**注意 5 字节前缀此刻的价值**:N 条响应消息可能挤在同一个 DATA 帧、也可能一条跨多个 DATA 帧,接收方全靠每条消息前的 5 字节长度前缀切开(第四节展开)。

### Client streaming(N → 1)——请求侧放开成多条 DATA

```
C ─ HEADERS ──────────────────────────────► S   请求头
C ─ DATA ──────────────────────────────────► S   请求消息 #1
C ─ DATA ──────────────────────────────────► S   请求消息 #2
C ─ DATA(END_STREAM) ──────────────────────► S   请求 #N + 客户端半关闭(关键!)
C ◄────────────────────────────── HEADERS ─ S   响应头
C ◄────────────────────────────── DATA ──── S   1 条聚合响应
C ◄────────────── HEADERS(END_STREAM) ───── S   trailers + 服务端半关闭
```

客户端连发 N 条,**最后一条带 END_STREAM 表示半关闭**。**服务端必须等到这个半关闭信号,才知道“客户端发完了”,然后才计算并返回那一条响应**。这就是半关闭的核心作用——它是“我这个方向说完了”的明确信号。忘了半关闭 → 服务端一直等 → hang(生产问题 Q3)。

### Bidirectional(N → N)——两个方向都放开,全双工

```
C ─ HEADERS ──────────────────────────────► S
C ─ DATA ──────────────────────────────────► S   请求 #1
C ◄────────────────────────────── HEADERS ─ S   响应头
C ◄────────────────────────────── DATA ──── S   响应 #1
C ─ DATA ──────────────────────────────────► S   请求 #2      ← 收发同时进行
C ◄────────────────────────────── DATA ──── S   响应 #2
C ─ DATA(END_STREAM) ──────────────────────► S   请求 #N + 客户端半关闭
C ◄────────────────────────────── DATA ──── S   响应 #M(客户端半关闭后服务端仍可继续发)
C ◄────────────── HEADERS(END_STREAM) ───── S   trailers + 服务端半关闭
```

两个方向**各自独立地发 DATA、各自独立地 END_STREAM**。客户端可以一边发一边收,收发节奏完全解耦。这也是 bidi 最灵活、也最容易写出死锁的地方(第八节)。

## 三、半关闭(half-close):流式的灵魂

把上面四张图的共性提炼出来,就是这章最该记住的概念:

> **一个 HTTP/2 stream 是双向的,两个方向(C→S 和 S→C)各自独立结束。某一方向发出 `END_STREAM` 标志,叫这个方向“半关闭”;两个方向都半关闭了,整个 stream 才“全关闭”。**

对照四种类型,半关闭发生的时机不同:

```
              客户端→服务端 半关闭时机          服务端→客户端 半关闭时机
Unary         发完唯一请求(随 DATA)            发完响应,随 trailer
ServerStream  发完唯一请求(随 DATA)            推完 N 条,随 trailer
ClientStream  发完 N 条后(单独 END_STREAM)     发完聚合响应,随 trailer
BiDi          客户端自己决定何时               服务端自己决定何时
```

几个由此推出的关键事实:

- **`grpc-status` 一定在“服务端方向的半关闭”那一刻随 trailer 发出**——这就是 04 篇“status 为什么在 trailer”的本质:trailer 就是服务端方向的 END_STREAM 信号。
- **client streaming / bidi 里,客户端不主动半关闭(`CloseSend`),服务端就永远在等**。这是流式 hang 的头号原因。
- 半关闭只是“我不再发了”,**不代表我不再收**。客户端在 bidi 里 `CloseSend()` 之后,仍然可以继续 `Recv()` 服务端的剩余响应。

## 四、5 字节前缀在流式里大放异彩(回扣 04)

04 篇说“unary 看不出 Length-Prefixed-Message 的必要性,流式才显威力”,现在兑现:

流式下,**HTTP/2 的 DATA 帧边界和 gRPC 的消息边界彻底脱钩**:

```
服务端要推 3 条小响应消息 msg1/msg2/msg3,它们怎么落到 DATA 帧上?可能是:

情形A(挤一帧):  DATA[ <5前缀>msg1 <5前缀>msg2 <5前缀>msg3 ]
情形B(各一帧):  DATA[<5前缀>msg1]  DATA[<5前缀>msg2]  DATA[<5前缀>msg3]
情形C(大消息跨帧): DATA[<5前缀>msg1的前半]  DATA[msg1的后半 <5前缀>msg2...]

接收方完全不关心 DATA 帧怎么切的,它只做一件事:
  读 5 字节前缀 → 知道这条消息有 N 字节 → 攒够 N 字节交给应用 → 读下一个 5 字节前缀 ...
```

**正是这个 5 字节前缀,让 gRPC 能在一个字节流上精确切出一条条消息,与 HTTP/2 怎么分帧无关。** 这是流式能成立的底层保证。没有它,接收方面对一串 DATA 帧根本不知道消息从哪到哪。

## 五、编程模型:四种类型的 API 形态

帧是底层,上层 API 把它们包装成不同的编程形态。理解 API 形态能帮你避开一堆坑。以 Go 和 Java 为例(其他语言形态类似)。

**Go**(用 channel 式的 Send/Recv):

```go
// Unary —— 就是个普通函数调用
resp, err := client.Unary(ctx, req)

// Server streaming —— 拿到 stream,循环 Recv 到 io.EOF
stream, _ := client.ServerStream(ctx, req)
for {
    resp, err := stream.Recv()
    if err == io.EOF { break }   // io.EOF = 服务端 trailer / 半关闭
    if err != nil { /* 真错误 */ }
}

// Client streaming —— 循环 Send,最后 CloseAndRecv
stream, _ := client.ClientStream(ctx)
for _, r := range reqs { stream.Send(r) }
resp, err := stream.CloseAndRecv()   // CloseAndRecv = 半关闭 + 等聚合响应

// Bidi —— 收发分两个 goroutine,避免死锁(见第八节)
stream, _ := client.BiDi(ctx)
go func() {
    for _, r := range reqs { stream.Send(r) }
    stream.CloseSend()               // 客户端方向半关闭
}()
for {
    resp, err := stream.Recv()
    if err == io.EOF { break }
}
```

**Java**(用 `StreamObserver` 回调):

```java
// Unary —— blocking stub,直接返回
Resp resp = blockingStub.unary(req);

// Server streaming —— blocking stub 返回 Iterator
Iterator<Resp> it = blockingStub.serverStream(req);
while (it.hasNext()) { Resp r = it.next(); }

// Client streaming —— 只能 async;拿到 requestObserver 往里 onNext
StreamObserver<Resp> respObs = new StreamObserver<>() {
    public void onNext(Resp r) { ... }
    public void onCompleted() { ... }     // 对应服务端 trailer
    public void onError(Throwable t) { ... }
};
StreamObserver<Req> reqObs = asyncStub.clientStream(respObs);
for (Req r : reqs) reqObs.onNext(r);
reqObs.onCompleted();                      // 半关闭

// Bidi —— 两个 StreamObserver,全双工
StreamObserver<Req> reqObs2 = asyncStub.biDi(respObs);
```

几个映射要记牢:

- **`io.EOF`(Go) / `onCompleted()`(Java) = 收到服务端 trailer = 服务端方向半关闭**,这是正常结束,不是错误。
- **`CloseSend()`(Go) / `onCompleted()` on requestObserver(Java) = 客户端方向半关闭**,client streaming / bidi 必须显式调用。
- **真正的错误走 `err != io.EOF`(Go) / `onError()`(Java)**,里面带 `grpc-status`(第 09 篇)。

⚠️ **Java 的一个大坑提前预警**:`StreamObserver.onNext()` **默认不阻塞、不背压**——你疯狂 `onNext` 而对端消费慢时,数据会在本地缓冲堆积,可能 OOM。Java 要做流式背压得用 `CallStreamObserver.isReady()` + `setOnReadyHandler()` 手动控制。这和 Go 的 `Send()` 在窗口满时会阻塞(自带背压)是**完全不同的行为**,跨语言团队尤其要注意(第 06、15 篇细讲实现差异)。

## 六、背压:流式不 OOM 的保障(回扣 03,引向 12)

流式最现实的问题:**生产者快、消费者慢,数据堆哪?会不会 OOM?**

答案落在 03 篇讲的**两级 HTTP/2 流控窗口**上:

```
server streaming,客户端读得慢:
  客户端应用层不调 Recv → gRPC 不消费接收缓冲 → 不发 WINDOW_UPDATE
     → 服务端的流控窗口逐渐耗尽 → 服务端再想 Send 就被阻塞(Go)
     → 压力沿 HTTP/2 流控反向传导到服务端应用层
  这就是“背压自动传播”:消费端慢,生产端自动被按住,不会无限堆积。
```

**但这个保障有两个前提**,破了就会 OOM:

1. **发送端必须尊重背压**(窗口满了就停)。Go 的 `Send()` 会阻塞,天然尊重;Java 的 `onNext()` 不阻塞,**得自己查 `isReady()`**,否则数据堆在本地发送缓冲。
2. **接收端别用无界缓冲把数据先全收下来**。如果你 `Recv` 出来立刻丢进一个无界 queue,等于绕过了背压,照样堆爆内存。

背压是流式的深水区,第 12 篇会专门拆“消费端慢,数据到底堆在发送端缓冲、接收端缓冲、还是内核缓冲”。这里先建立认知:**HTTP/2 流控让背压能自动传播,但前提是你的代码尊重它。**

## 七、怎么选:适用场景与反模式

| 类型 | 适合 | 不适合 / 反模式 |
|---|---|---|
| **Unary** | 99% 的请求-响应:CRUD、查询、命令 | 无 —— 默认就用它,别过度设计成流 |
| **Server streaming** | 大结果集分批吐(避免一个 4MB 大响应)、订阅/推送(行情、日志 tail、进度条)、**LLM token 流式输出**、服务端生成式场景 | 结果集很小却硬上流(徒增复杂度);需要中途让客户端回话(那要 bidi) |
| **Client streaming** | 大文件分片上传、批量埋点/指标上报、客户端持续喂数据让服务端聚合 | 需要每条都拿到即时响应(那要 bidi);其实能一次性发完的小批量 |
| **Bidi** | 实时双向:聊天、协同编辑、信令、语音转写、复杂握手协议 | 只是想“一问一答多次”——多次 unary 往往更简单、更好治理(可重试、可独立负载均衡) |

**核心原则:能 unary 就 unary。** 流式很香,但它带来一串治理难题:不好自动重试、占用长连接资源、负载均衡粒度变粗(一条流锁死在一个后端)、半关闭/背压心智负担。**只有当“分批、推送、实时双向、大流量传输”这些需求真实存在时,才上对应的流式类型。** 把一个本可以 unary 的接口做成 bidi,是常见的过度设计。

> 给做 AI 的同学一个具体落点:**LLM 的流式 token 输出,天然是 server streaming**(一个 prompt 请求 → 一串 token 响应)。而一个**多轮对话 + 工具调用来回**的 Agent 协议,如果需要服务端边生成边等客户端反馈,可能用 bidi;但很多 Agent 实现其实是“每轮一次 unary 或 server-streaming”,而不是一条长 bidi——因为前者更好重试、好观测、好做负载均衡。

## 八、流式的坑(顺序、重试、资源、死锁)

把流式特有的几个坑集中讲清,这些都是生产高发:

1. **顺序保证只在“单条 stream 内”**。一个 stream(一次流式 RPC)内的消息严格有序(HTTP/2 stream 内 DATA 帧有序)。**跨 stream(跨 RPC)、跨连接没有任何顺序保证**。想全局有序,得靠业务序号,别指望 gRPC。

2. **流式基本不能自动重试**。gRPC 的自动重试(第 10 篇)只在“还没往 stream 上发过任何消息”时安全。流式一旦开始收发,中途断了要重试,意味着“已经发出/收到的消息怎么算”,语义极复杂。所以**流式调用默认不自动重试,得靠应用层自己设计断点续传 / 重连**。

3. **长流是资源黑洞**。每个活跃 stream 在服务端占一个处理 goroutine/线程 + 缓冲;在客户端也占资源。大量长寿流(尤其 bidi 长连接信令)会吃满。要配 deadline / idle 超时 / 上限。

4. **server streaming 客户端不读不取消 → 服务端泄漏**。客户端拿到 stream 却不 `Recv`、也不 `cancel`,服务端会一直阻塞在 `Send`(被流控按住),对应的 goroutine/线程**泄漏**。务必“要么读完、要么 cancel”(生产问题 Q1)。

5. **bidi 死锁**。经典场景:客户端在**单线程**里“先把所有请求 Send 完,再开始 Recv”,而服务端是“收一条回一条”且响应缓冲被流控顶满——客户端在 Send 上阻塞(等服务端读),服务端在 Send 上阻塞(等客户端读),**互等死锁**。解法:**收和发放在不同 goroutine/线程**(第五节 Go 示例就是这么写的),或用全异步回调(生产问题 Q4)。

6. **长流被 idle timeout 掐断**。中间隔一段没有数据的 bidi 流,会被 LB / 代理的 idle timeout 当成“死连接”掐掉。要靠 **gRPC keepalive ping**(03 篇的 PING 帧)或应用层心跳保活(第 12 篇)。

## 九、本章小结

- 四种类型 = “请求侧 / 响应侧各发几条消息”的组合;**unary 是流的退化特例**,底层全是同一套 HEADERS/DATA/TRAILERS + 5 字节前缀。
- **半关闭(END_STREAM)** 是灵魂:stream 两个方向各自独立结束;`grpc-status` 随服务端方向半关闭(trailer)发出;client streaming/bidi 客户端必须显式 `CloseSend`,否则服务端死等。
- **5 字节前缀**让消息边界独立于 HTTP/2 帧边界,这是流式能成立的底层保证。
- 编程模型:`io.EOF`/`onCompleted` = 正常结束(trailer),`CloseSend`/requestObserver.onCompleted = 客户端半关闭;**Java `onNext` 不背压是大坑**。
- **背压**靠 HTTP/2 两级流控自动传播,但前提是代码尊重它(发送端会停、接收端不无界缓冲)。
- 选型:**能 unary 就 unary**;流式只在分批/推送/实时双向/大传输的真实需求下用。
- 流式坑:只单流内有序、基本不能自动重试、长流吃资源、不读不取消会泄漏、bidi 收发同线程会死锁、长流要 keepalive。

---

## 生产常见问题

**Q1:server streaming 上线后,服务端 goroutine / 线程数缓慢上涨直到耗尽,像是泄漏。**

典型“**客户端不读完也不取消**”。客户端拿到流,读了几条就不读了(提前 break 但没 cancel)、或者 panic 了没清理,服务端就一直阻塞在 `Send`(被 HTTP/2 流控按住),对应的处理 goroutine 永不退出。修法:① 客户端**用完流必须 `cancel`**(Go 里 `defer cancel()`,Java 里取消 Call);② 服务端 `Send` 前检查 `ctx.Err()` / `context cancelled`,客户端断了就尽快退出;③ 给流式 RPC 配 deadline,兜底回收。

**Q2:bidi / client streaming 长连接流,运行一段时间后偶发被断开,报 `UNAVAILABLE` 或连接 reset。**

长流中间“静默期”被 **idle timeout** 掐了。LB(ELB/Nginx/Envoy)、甚至 NAT 网关都有空闲连接回收。修法:① 开 **gRPC keepalive**(客户端 `keepalive.ClientParameters`,服务端 `keepalive.ServerParameters`),让它周期发 HTTP/2 PING 保活;② keepalive 间隔要**小于**链路上最短的那个 idle timeout;③ 注意服务端的 `MinTime`/`PermitWithoutStream` 配置别把客户端的 keepalive 判成“太频繁”而 GOAWAY(第 12 篇详解这对参数的相互制约)。

**Q3:client streaming 调用,客户端 Send 完所有数据后就一直卡着拿不到响应。**

九成是**忘了半关闭**:client streaming / bidi 必须显式 `CloseSend()`(Go)/ `requestObserver.onCompleted()`(Java),服务端收到这个 END_STREAM 才知道“客户端发完了”,才会计算并返回。少了这一步,服务端永远在等更多请求,客户端永远在等响应——双等。检查代码里发完数据后有没有调半关闭。

**Q4:bidi 流偶发死锁,两端都卡住不动,CPU 也不高。**

经典 **bidi 收发同线程**死锁:在一个线程里“先 Send 完再 Recv”,当响应被流控憋住时,Send 阻塞(等对端读)、对端也阻塞(等你读),互等。修法:**收和发拆到不同 goroutine/线程**(参考第五节 Go 写法),或全异步回调(Java `StreamObserver`)。这是写 bidi 必须遵守的纪律。

**Q5:把一个普通查询接口做成了 server streaming,结果负载均衡变差、还更难排查,为什么?**

**过度设计成流的代价**。一条流式 RPC 会**锁死在一个后端**整个生命周期(连接级 LB,第 11 篇),粒度比“多次独立 unary”粗,负载更难均衡;流式还不好自动重试、观测埋点也更复杂。如果结果集不大、不需要边出边推,**退回 unary**。记住原则:能 unary 就 unary,流式是为“分批/推送/实时/大传输”准备的,不是默认选项。

**Q6:流式传输中,客户端收到的消息顺序和服务端发送顺序不一致 / 期望全局有序却乱了。**

先分清:**单条 stream 内 gRPC 保证顺序**(HTTP/2 stream 内有序)。如果你“乱了”,通常是:① 跨了多条 stream / 多次 RPC(无跨流顺序保证);② 客户端用多线程并发处理 Recv 出来的消息,处理顺序乱了(不是传输乱);③ 经过某些会重排的中间层。需要全局有序就**在消息里带业务序号**自己排,不要依赖 gRPC 跨流有序。

---

> 下一篇 `06_Channel / Stub / 连接管理与代码生成`:到这里你已经理解“一次调用(含流式)在协议层怎么走完”。06 篇切到客户端骨架——`.proto` 经 `protoc` 生成了什么、blocking/async/future 三种 stub 的差异、**Channel 和 Subchannel 是什么、一个 Channel 底下到底维护了几条 HTTP/2 连接**(这直接关系到第 11 篇的负载均衡)。我们会把“从 `.proto` 到一次远程调用”这条链路在代码层面补完整。
