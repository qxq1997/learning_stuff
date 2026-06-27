# 06 Channel / Stub / 连接管理与代码生成：从 .proto 到一次远程调用

> 前五篇把“一次调用在协议层怎么走完”讲透了。这一篇切到**客户端骨架**:`.proto` 经 `protoc` 变成了什么代码、你手里的 `stub` 和 `Channel` 各是什么、以及**一个 Channel 底下到底维护着几条 HTTP/2 连接**。最后那个问题是本篇的重心——它直接决定了第 11 篇“为什么 L4 负载均衡对 gRPC 失效”的另一半答案。

## 一、protoc 生成了什么

`.proto` 不能直接运行,要先用 `protoc`(Protobuf 编译器)+ 语言插件生成代码:

```
        greeter.proto
             │
   protoc + protoc-gen-go + protoc-gen-go-grpc   (Go)
   protoc + grpc-java 插件                        (Java)
             │
   ┌─────────┴──────────────────────────────────┐
   │                                             │
 ① 消息代码                                  ② 服务代码
 message → struct/class                    service → 客户端 stub + 服务端 skeleton
 + 序列化(marshal/unmarshal)                + 每个 rpc 方法的桩
```

生成物分两块:

1. **消息代码**:每个 `message` 变成一个 struct(Go)/ class(Java),带 getter/setter 和**序列化逻辑**(把对象编成 02 篇讲的 wire format,以及反过来)。
2. **服务代码**,又分两半:
   - **客户端 stub**:把“调用一个本地方法”翻译成“发一次 RPC”。`stub.SayHello(req)` 内部就是去拼 04 篇那套 HEADERS/DATA 帧。
   - **服务端 skeleton**(base class / interface):你**继承/实现**它,把业务逻辑填进去。gRPC runtime 收到请求后,解析 `:path` 路由到你的实现方法。

```
客户端侧                          服务端侧
  你的代码                          你的代码
    │ 调 stub.SayHello(req)           ▲ 实现 SayHello(req) 返回 resp
    ▼                                │
 [生成的 client stub]            [生成的 server skeleton]
    │ 拼帧、序列化、发送              ▲ 路由(:path)、反序列化、调你的实现
    ▼                                │
 ───────────── gRPC runtime + HTTP/2 + TCP ─────────────
```

**stub 是“远程调用长得像本地方法”这句话的兑现处**——它把网络细节藏在生成代码里。

## 二、三种 stub:blocking / future / async

同一个服务,客户端 stub 通常有几种风格。Java 分得最清楚,三种:

| stub 类型 | unary | server streaming | client / bidi streaming | 特点 |
|---|---|---|---|---|
| **BlockingStub** | 同步返回 `Resp` | 返回 `Iterator<Resp>` | ❌ 不支持 | 同步阻塞,代码最直观 |
| **FutureStub** | 返回 `ListenableFuture<Resp>` | ❌ | ❌ | unary 异步,拿 future |
| **(Async)Stub** | `StreamObserver` 回调 | `StreamObserver` 回调 | ✅ 支持 | 全异步,支持全部四种 |

为什么 **client/bidi streaming 只能用 async stub**?因为它们需要**同时收和发**(05 篇讲的全双工),阻塞式 API 表达不了“一边 Send 一边 Recv”,必须用回调/异步。

**Go 没有这种三分**:它统一用 `Send`/`Recv`,靠 **goroutine** 实现并发收发——你想异步就开个 goroutine,想阻塞就直接调。所以 Go 里看不到 blocking/async stub 的区分,但**底层的并发模型差异依然存在**(回扣 05 篇:Go 的 `Send` 阻塞自带背压,Java 的 `onNext` 不阻塞要手动背压)。

> 选用建议:能用 unary + blocking 就用它,代码最清晰;高并发、要并行发很多 unary 用 future/async;凡是 client/bidi streaming 别无选择,只能 async。

## 三、Channel:重量级、长寿、必须复用的核心抽象

stub 只是个“皮”,真正干活的是它包着的 **Channel**。

```
Java:  ManagedChannel channel = ManagedChannelBuilder
           .forTarget("dns:///greeter.default.svc:50051")
           .usePlaintext().build();
       var stub = GreeterGrpc.newBlockingStub(channel);   // stub 套在 channel 上

Go:    conn, _ := grpc.NewClient("dns:///greeter.default.svc:50051",
           grpc.WithTransportCredentials(insecure.NewCredentials()))
       stub := pb.NewGreeterClient(conn)                  // stub 套在 conn(Channel) 上
```

**Channel 是什么?** 它是“客户端到一个**逻辑服务**的虚拟连接”。注意三个词:

- **逻辑服务**:Channel 对应一个 **target**(如 `dns:///greeter...:50051`),不是一个具体 IP。后面那个 target 可能解析出一堆后端 IP(第四节)。
- **虚拟**:Channel **不是一条 TCP 连接**,它是个抽象,底下管理着一组真实连接。
- Channel 封装了一大堆能力:**名字解析、负载均衡、连接管理、重试、拦截器**——这些后面每一章讲的治理能力,都挂在 Channel 上。

**Channel 的三个铁律**(违反就是生产事故):

1. **重量级**:建一个 Channel 要做名字解析、建连、TLS 握手,开销大。
2. **线程安全 + 长寿**:一个 Channel 可以被多个线程、多个 stub 并发共享,应当**长期持有、全局复用**(单例 / 连接池)。
3. **必须显式关闭**:用完 `shutdown()`(Java)/ `conn.Close()`(Go),否则连接泄漏。

> **stub 轻、Channel 重**。多个 stub(不同服务、不同配置)可以共享同一个 Channel。**每次请求新建 Channel 是 gRPC 头号性能事故**(生产问题 Q1)——它把“少量长连接 + 多路复用”的全部优势直接清零。

## 四、Channel → Subchannel → Transport:三层结构(本篇重心)

现在拆开 Channel 内部。这是 gRPC 客户端**最重要的内部结构**,也是理解负载均衡的钥匙:

```
┌──────────────────────────────────────────────────────────────┐
│ Channel   target = "dns:///greeter.default.svc:50051"          │
│                                                                │
│  ① NameResolver(名字解析)                                      │
│     dns:/// 把域名解析成 → [10.0.0.1:50051,                     │
│                            10.0.0.2:50051,                      │
│                            10.0.0.3:50051]                      │
│                                                                │
│  ② LB Policy(负载均衡策略,在 subchannel 间选)                  │
│                                                                │
│  ③ Subchannel(每个后端地址一个)                                │
│     ┌───────────────┐ ┌───────────────┐ ┌───────────────┐     │
│     │ Subchannel A  │ │ Subchannel B  │ │ Subchannel C  │     │
│     │ 10.0.0.1:50051│ │ 10.0.0.2:50051│ │ 10.0.0.3:50051│     │
│     │   ▼ Transport │ │   ▼ Transport │ │   ▼ Transport │     │
│     │  HTTP/2 连接   │ │  HTTP/2 连接   │ │  HTTP/2 连接   │     │
│     └───────────────┘ └───────────────┘ └───────────────┘     │
└──────────────────────────────────────────────────────────────┘

  Channel(逻辑) ⊃ Subchannel(一个后端) ⊃ Transport(一条 HTTP/2 连接)
```

三层各司其职:

- **Channel**:对应一个 target(逻辑服务名)。一个。
- **Subchannel**:对应**一个具体后端地址**(一个 IP:port)。管理到这个后端的连接、它的健康状态、它的退避重连。
- **Transport**:**一条真实的 HTTP/2 连接**(03 篇讲的那条 TCP+多路复用)。一个 Subchannel 底下通常**就一条** Transport(多路复用让一条够用)。

**一次调用怎么落到具体连接上?**

```
stub.SayHello(req)
  → Channel 把请求交给 LB Policy
  → LB Policy 从“当前 READY 的 subchannel”里挑一个(round_robin 就轮着挑)
  → 用这个 subchannel 的 Transport(HTTP/2 连接)开一个新 stream
  → 发 HEADERS + DATA(04 篇的帧)
```

**这就是“客户端负载均衡”发生的地方**——选哪个后端,是 Channel 内部的 LB Policy 在 subchannel 间做的决策,不依赖外部 LB。第 11 篇整篇讲这个,这里先把结构立住。

### ⚠️ 默认 LB 是 pick_first,它只用一条连接

这里埋一个**第 11 篇会引爆的关键点**:gRPC 客户端的**默认 LB 策略是 `pick_first`**,不是 round_robin。`pick_first` 的行为是:

> 把解析出的地址当一个列表,**依次尝试,连上第一个能连的就只用那一个**,其余地址不建连。

也就是说,**默认情况下,一个 Channel 其实只维持一条活跃的 HTTP/2 连接、只打到一个后端!**

```
pick_first(默认):  Channel ──► 只连 10.0.0.1 这一个,2/3 闲置
round_robin:        Channel ──► 三个都连,请求轮流分发
```

把这个和 03 篇的“HTTP/2 多路复用 + 长连接”叠起来,你就拿到了**“K8s ClusterIP 下 gRPC 流量全压一个 Pod”的完整根因**:

1. K8s ClusterIP 是个 VIP,DNS 解析出来就一个 VIP 地址 → Channel 只看到一个地址;
2. 默认 pick_first → 只建一条连接到这个 VIP;
3. 这条长连接被 L4 转发钉死在某一个后端 Pod 上 → 多路复用让所有 RPC 都走它 → 倾斜。

解法(headless service 暴露真实 Pod IP + round_robin、或客户端 LB、或 mesh)留到第 11、16 篇。这里你要记住:**默认 pick_first“一个 Channel 一条连接”,是倾斜的内因之一。**

## 五、Channel 状态机与 WaitForReady

Channel 有个状态机,理解它能解释一大半“偶发 UNAVAILABLE”:

```
        首次 RPC / 显式连接
 IDLE ───────────────────► CONNECTING ──成功──► READY
  ▲                            │                  │
  │ 空闲超时                    │失败               │ 连接断
  │ (省资源,断连)               ▼                  │
  └──────────────────── TRANSIENT_FAILURE ◄───────┘
                          (指数退避后重试)
                                                   SHUTDOWN(关闭)
```

- **IDLE**:没有活动,不持有连接(省资源)。第一个 RPC 来了才开始连。
- **CONNECTING**:正在建连(TCP + TLS + HTTP/2 preface)。
- **READY**:连接就绪,能正常发 RPC。
- **TRANSIENT_FAILURE**:连接失败,正在**指数退避**重连。
- **SHUTDOWN**:已关闭。

**WaitForReady** 决定了“Channel 不在 READY 时发 RPC 会怎样”:

- **默认 `wait_for_ready = false`(fail-fast)**:Channel 处于 TRANSIENT_FAILURE 时发 RPC,**立即返回 `UNAVAILABLE`**,不等。
- **`wait_for_ready = true`**:RPC 会**排队等到 Channel READY**(或撞到 deadline)再发。

这俩的取舍很实际:fail-fast 让调用方快速失败、好做降级,但抖动期会报一片 UNAVAILABLE;wait_for_ready 让调用更“有耐心”,适合“宁可等一会也别失败”的场景,但要配好 deadline 否则会傻等。生产里怎么选,关系到第 17 篇的排障。

## 六、一次调用的完整内部链路(把 01–05 串起来)

到这里可以把前五篇缝成一条完整链路了。`stub.SayHello(req)` 从你的代码到对端,内部走这些步骤:

```
1. 你调 stub.SayHello(req)
2. 客户端拦截器链(第 08 篇):加 trace、加 auth metadata、埋点
3. Channel 检查状态:IDLE → 触发名字解析 + 建连(懒,第一次才连,所以首调慢)
4. NameResolver:target → 后端地址列表(第 11 篇)
5. LB Policy:从 READY 的 subchannel 里挑一个(pick_first/round_robin,第 11 篇)
6. 选中 subchannel 的 Transport(HTTP/2 连接)上:
     - 分配一个新 Stream ID
     - 序列化 req(02 篇 wire format)
     - 发 HEADERS 帧(:path、grpc-timeout=deadline、metadata;04 篇)
     - 发 DATA 帧(5 字节前缀 + protobuf;04 篇)+ END_STREAM(半关闭)
7. 等服务端:HEADERS(响应头)→ DATA(响应)→ HEADERS(trailer: grpc-status)
8. 读 grpc-status:0 → 反序列化 resp 返回;非 0 → 抛对应错误(第 09 篇)
   期间 deadline 到 → 发 RST_STREAM 取消(第 07 篇)
9. 拦截器链回程、返回给你的代码
```

**这条链路就是整个专栏的脊柱。** 后面每一篇,本质都是在放大其中某一步:07 放大第 6 步的 deadline、08 放大第 2 步的拦截器、09 放大第 8 步的 status、10 放大失败重试、11 放大第 4-5 步的解析与 LB、12 放大第 3、6 步的连接生命周期。

## 七、连接管理:懒建连、IDLE、何时多连接

把连接相关的几个实际行为讲清,这些直接对应生产现象:

- **懒建连(lazy)**:创建 Channel **不会立刻建连**。`grpc.NewClient`(Go)、`ManagedChannelBuilder.build()`(Java)返回时连接还没建,**第一个 RPC 才触发**名字解析 + TCP + TLS。**后果**:① 首次调用明显慢(生产问题 Q3);② Channel 建好时连不上也**不报错**,要到第一次 RPC 才暴露(Go 老 `Dial` 想立刻报错得 `WithBlock`,新 `NewClient` 一律懒)。
- **IDLE 回收**:一段时间没有任何 RPC,Channel 进入 IDLE,**主动断开连接省资源**;下次 RPC 再重新建连。所以“放置一晚后第一个请求慢”是正常的(生产问题 Q3)。
- **一个后端默认一条连接**:靠多路复用,一条 HTTP/2 连接能扛很多并发 RPC,所以默认每个 subchannel 就一条 Transport。**grpc-go / grpc-java 默认不会对同一个后端自动开第二条连接**——这意味着一旦这条连接的 `MAX_CONCURRENT_STREAMS` 顶满(03 篇),新 RPC 就在客户端排队(生产问题 Q4)。想要单后端多连接,得靠多 Channel 或特殊 LB 配置(第 11、15 篇)。

## 八、本章小结

- `protoc` 生成**消息代码 + 客户端 stub + 服务端 skeleton**;stub 是“远程调用像本地方法”的兑现处。
- 三种 stub:**blocking**(同步,不支持 client/bidi)、**future**(unary 异步)、**async**(全异步,支持四种);Go 用 goroutine 统一,无此三分。
- **Channel 是重量级、长寿、线程安全、必须复用**的核心抽象,封装名字解析/LB/连接/重试/拦截器;**每次新建 Channel 是头号性能事故**。
- **三层结构 Channel ⊃ Subchannel ⊃ Transport**:一个 target → N 个后端地址 → N 个 subchannel → 各一条 HTTP/2 连接;LB 在 subchannel 间选。
- **默认 LB 是 pick_first**,只用一条连接打一个后端——这是 L4 LB 下 gRPC 倾斜的内因之一。
- Channel 状态机(IDLE/CONNECTING/READY/TRANSIENT_FAILURE/SHUTDOWN)+ **WaitForReady**(fail-fast vs 等待)解释了大半“偶发 UNAVAILABLE”。
- 连接是**懒建**的(首调慢、建好不报错)、**IDLE 会回收**、**单后端默认一条连接**(顶满 MAX_CONCURRENT_STREAMS 会排队)。

---

## 生产常见问题

**Q1:gRPC 客户端 QPS 上不去、延迟高,服务端连接数暴涨甚至 fd 耗尽,排查发现每个请求都在新建 Channel。**

**gRPC 头号误用**。Channel 是重量级长寿对象,每次请求新建 = 每次都做 DNS 解析 + TCP 握手 + TLS 握手 + 新 HTTP/2 连接,既慢又把服务端连接数打爆,还彻底丢掉“长连接 + 多路复用”的意义。修法:**Channel 全局复用**——做成单例 / 注入容器管理 / 连接池,整个进程对一个目标服务**共享一个(或少数几个)Channel**,stub 可以随便建(轻)。这条没有例外。

**Q2:服务重启 / 短时不可用期间,客户端瞬间报一大片 `UNAVAILABLE`,而不是稍等就恢复。**

Channel 处于 **TRANSIENT_FAILURE** 且 **wait_for_ready=false(默认 fail-fast)**:这期间发的 RPC 立即失败返回 UNAVAILABLE。要不要改:① 对“宁可等也别失败”的关键调用,设 `wait_for_ready=true` 让它等到 READY(务必配 deadline 兜底);② 或者保留 fail-fast,但在调用方做重试(第 10 篇)/ 降级。两种都行,关键是**显式选择**,而不是默认 fail-fast 又没重试。

**Q3:服务的第一个请求、或闲置一段时间后的第一个请求明显比后续慢几十到几百毫秒。**

**懒建连 + IDLE 回收**的正常表现:Channel 懒建连,首个 RPC 要现做名字解析 + TCP + TLS 握手 + HTTP/2 preface;闲置后 Channel 进 IDLE 断连,再来请求又得重连。缓解:① 启动时**预热**(主动发个 RPC 或用 health check 把连接建起来);② 调整/关闭 IDLE 超时(谨慎,占资源);③ 接受首调慢,在压测里 warmup 后再测。

**Q4:单个客户端实例并发一高,P99 就尖刺,服务端却很闲(回扣 03 篇 Q3,这里补客户端结构视角)。**

因为**一个 Channel 对一个后端默认只有一条连接**,这条连接的并发 stream 受 `MAX_CONCURRENT_STREAMS` 限制,顶满后新 RPC 在客户端排队。结构性根因就在本篇第七节。修法:① 调大服务端 `MaxConcurrentStreams`;② 客户端**用多个 Channel**分摊(或配置支持单后端多连接的方案);③ 上 round_robin + 多后端把负载摊开(第 11 篇)。先用 channelz(第 15 篇)确认“是不是单连接 stream 打满了”。

**Q5:换了个 LB 配置 / 上了 K8s 后,明明有多个后端副本,流量却只打到一个。**

很可能还在用**默认的 `pick_first`**——它只连一个地址。若你的 target 解析出多个真实后端地址(headless service / 直连 Pod IP),要**显式配 `round_robin`** 才会都连上、轮询分发。若 target 是 ClusterIP(只解析出一个 VIP),那 pick_first/round_robin 都只看到一个地址,得先改用 headless service 暴露真实 Pod IP。完整解法见第 11、16 篇,本篇先确认:**默认 pick_first 是“只打一个”的直接原因。**

**Q6:Channel 用完没关,长跑服务里连接 / goroutine 缓慢泄漏。**

Channel 持有连接、后台还有名字解析 / keepalive / 状态管理的协程,**必须显式关闭**:Java `channel.shutdown()`(或 `shutdownNow()` + `awaitTermination`),Go `conn.Close()`。临时用途的 Channel(很少见,通常应复用)尤其记得关。长寿单例 Channel 则在进程退出时优雅关闭。

---

> 下一篇 `07_Deadline / 超时传播与 Cancellation`:开始进入“调用治理”四件套的第一件。我们会讲清为什么 gRPC 的超时是 **deadline(绝对时间点)** 而不是 timeout(相对时长)、它如何随 `grpc-timeout` 头**跨服务一跳跳传播并扣减**、服务端不检查 deadline 会酿成什么“算了半天结果没人要”的浪费,以及 cancellation 如何通过 RST_STREAM 一路传导。这是分布式调用链生命周期的总开关。
