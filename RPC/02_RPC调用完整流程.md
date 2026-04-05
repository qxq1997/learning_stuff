# RPC - 第 2 课：RPC 调用完整流程

## 学习目标（本节结束后你能做到什么）

- 画出 RPC 调用的完整流程图，说清每一步做了什么
- 理解四个核心组件（Proxy、Serialization、Transport、Dispatcher）各自的职责
- 解释动态代理的原理，区分 JDK 动态代理和 CGLIB
- 说清 TCP 粘包/拆包问题以及协议帧的设计
- 理解同步调用和异步调用的区别，能解释 CompletableFuture + requestId 机制

## 内容讲解

### 1. RPC 调用的整体流程

一个完整的 RPC 调用，从客户端发起到收到结果，一共经历 9 步：

```
客户端                                                    服务端
  │                                                         │
  │  1. 业务代码调用接口方法                                   │
  │  ──────────────────>                                    │
  │  2. Proxy 代理拦截调用，                                   │
  │     封装方法名、参数                                       │
  │  ──────────────────>                                    │
  │  3. 序列化：把请求对象                                     │
  │     变成二进制字节流                                       │
  │  ──────────────────>                                    │
  │  4. 网络传输：通过 TCP                                     │
  │     把字节流发到服务端                                     │
  │  ════════════════════════════════════════>               │
  │                                         5. 反序列化：     │
  │                                            字节流变回对象  │
  │                                         6. Dispatcher    │
  │                                            查找本地服务    │
  │                                         7. 反射调用目标   │
  │                                            方法，拿到结果  │
  │                                         8. 序列化结果，   │
  │  <════════════════════════════════════════  通过 TCP 返回  │
  │  9. 反序列化结果，                                        │
  │     返回给业务代码                                        │
  │  <──────────────────                                    │
```

对开发者来说，他只看到了第 1 步和第 9 步——调方法、拿结果。中间的 2 到 8 步全部由 RPC 框架自动完成。这就是上节课说的"远程调用看起来像本地调用"。

### 2. 四个核心组件

把上面的 9 步抽象一下，RPC 框架的核心就是四个组件：

```
┌───────────────────────────────────────────────────────────┐
│                     RPC 框架核心组件                        │
│                                                           │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
│  │  Proxy   │  │Serialize │  │Transport │  │Dispatcher│  │
│  │  代理     │  │  序列化   │  │ 网络传输  │  │ 服务调度  │  │
│  │          │  │          │  │          │  │          │  │
│  │ 拦截调用  │  │ 对象⇄字节 │  │ TCP通信   │  │ 查找+调用 │  │
│  │ 封装请求  │  │ 编码解码  │  │ 连接管理  │  │ 本地方法  │  │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘  │
│   客户端侧       两端都有       两端都有       服务端侧     │
└───────────────────────────────────────────────────────────┘
```

下面逐个深入讲解。

### 3. 代理（Proxy）：动态代理详细解释

代理是 RPC 框架在客户端侧最核心的技巧。它的作用是：**让你以为在调本地方法，实际上偷偷把调用信息打包发到了远程服务器。**

#### 用中介租房来理解代理

你要租房子，但你不想自己一个一个联系房东、看房、谈价。于是你找了一个中介（代理）。你跟中介说"我要一个朝南两居室"，中介帮你联系房东、筛选房源、安排看房。对你来说，你只是跟中介说了一句话，剩下的事中介全搞定了。

RPC 里的 Proxy 就是这个中介。你调用 `userService.getUserInfo(userId)`，Proxy 把这个调用拦截下来，帮你把方法名（`getUserInfo`）、参数（`userId`）、接口名（`UserService`）打包好，通过网络发到服务端。服务端返回结果后，Proxy 再把结果拆包，返回给你。

#### 静态代理 vs 动态代理

**静态代理**：你手动给每个接口写一个代理类。

```java
// 静态代理 —— 手动写
public class UserServiceProxy implements UserService {
    @Override
    public UserInfo getUserInfo(Long userId) {
        // 手动封装请求、发送网络调用、解析响应
        RpcRequest request = new RpcRequest();
        request.setServiceName("UserService");
        request.setMethodName("getUserInfo");
        request.setArgs(new Object[]{userId});
        RpcResponse response = rpcClient.send(request);
        return (UserInfo) response.getResult();
    }

    @Override
    public Address getAddress(Long userId) {
        // 又要写一遍，几乎一样的代码...
        RpcRequest request = new RpcRequest();
        request.setServiceName("UserService");
        request.setMethodName("getAddress");
        request.setArgs(new Object[]{userId});
        RpcResponse response = rpcClient.send(request);
        return (Address) response.getResult();
    }
}
```

问题很明显：每个方法都要手写一个代理方法，十个接口一百个方法就要写一百遍。

**动态代理**：运行时自动生成代理类，不用手写任何代理代码。

#### JDK 动态代理 vs CGLIB vs Javassist

| 方案 | 原理 | 限制 | 性能 | 使用场景 |
| --- | --- | --- | --- | --- |
| JDK 动态代理 | 基于接口，运行时生成实现类 | 必须有接口 | 一般 | Spring AOP 默认（有接口时） |
| CGLIB | 基于继承，生成目标类的子类 | 不能代理 final 类和方法 | 较好 | Spring AOP（无接口时） |
| Javassist | 直接操作字节码生成类 | API 较底层 | 最好 | Dubbo 默认使用 |

RPC 框架通常用 JDK 动态代理（因为 RPC 调用一定有接口定义），下面是核心代码。

#### InvocationHandler 代码示例

```java
/**
 * RPC 调用的核心：InvocationHandler
 * 所有对接口方法的调用，都会被转发到这里的 invoke 方法
 */
public class RpcInvocationHandler implements InvocationHandler {

    private final String serviceName;     // 要调用的远程服务名
    private final RpcClient rpcClient;    // 网络通信客户端

    public RpcInvocationHandler(String serviceName, RpcClient rpcClient) {
        this.serviceName = serviceName;
        this.rpcClient = rpcClient;
    }

    /**
     * 每次调用接口的任何方法，都会走到这里
     * @param proxy  代理对象本身（一般不用）
     * @param method 被调用的方法（如 getUserInfo）
     * @param args   方法参数（如 userId = 12345）
     */
    @Override
    public Object invoke(Object proxy, Method method, Object[] args)
            throws Throwable {
        // 1. 封装 RPC 请求
        RpcRequest request = new RpcRequest();
        request.setRequestId(IdGenerator.nextId());  // 唯一请求ID
        request.setServiceName(serviceName);          // "UserService"
        request.setMethodName(method.getName());      // "getUserInfo"
        request.setParamTypes(method.getParameterTypes()); // 参数类型
        request.setArgs(args);                        // 实际参数值

        // 2. 通过网络发送请求，等待响应
        RpcResponse response = rpcClient.send(request);

        // 3. 检查是否有异常
        if (response.getException() != null) {
            throw response.getException();
        }

        // 4. 返回结果
        return response.getResult();
    }
}
```

#### Proxy.newProxyInstance 代码示例

```java
/**
 * 创建 RPC 代理对象
 * 调用后返回一个 UserService 的"假"实现，
 * 所有方法调用都会被 RpcInvocationHandler 拦截并转为网络调用
 */
@SuppressWarnings("unchecked")
public static <T> T createProxy(Class<T> interfaceClass, RpcClient rpcClient) {
    return (T) Proxy.newProxyInstance(
        interfaceClass.getClassLoader(),       // 类加载器
        new Class[]{interfaceClass},            // 要代理的接口
        new RpcInvocationHandler(               // 调用处理器
            interfaceClass.getName(),
            rpcClient
        )
    );
}

// 使用方式
UserService userService = createProxy(UserService.class, rpcClient);
// 这里的 userService 不是真正的实现类，而是动态生成的代理
// 调用任何方法都会走 RpcInvocationHandler.invoke()
UserInfo user = userService.getUserInfo(12345L);
```

### 4. 序列化（Serialization）

序列化的作用是把 Java 对象变成字节流（以便通过网络传输），反序列化则是把字节流变回对象。这是 RPC 框架里性能影响最大的环节之一。

详细内容在第 3 课专门讲，这里只需要知道：
- 序列化发生在客户端发送请求前、服务端返回结果前
- 反序列化发生在服务端收到请求后、客户端收到结果后
- 一次 RPC 调用涉及 4 次序列化/反序列化操作

### 5. 网络传输（Transport）：TCP 粘包/拆包问题

RPC 框架通常直接用 TCP 长连接做通信（而不是 HTTP），因为性能更好、开销更小。但直接用 TCP 会遇到一个经典问题：**粘包和拆包**。

#### TCP 是字节流，没有消息边界

TCP 协议传输的是连续的字节流，它不知道你的"一条消息"从哪开始、到哪结束。

```
你发送了两条消息：
  消息1: [AAAA BBBB]    （8字节）
  消息2: [CCCC DDDD]    （8字节）

TCP 实际传输时可能变成这样：

情况1（粘包）：一次收到两条消息粘在一起
  [AAAA BBBB CCCC DDDD]

情况2（拆包）：一条消息被拆成两次收到
  第一次：[AAAA BB]
  第二次：[BB CCCC DDDD]

情况3（又粘又拆）：
  第一次：[AAAA BBBB CC]
  第二次：[CC DDDD]
```

如果不处理这个问题，服务端根本不知道从哪切分消息，解析就会出错。

#### 解决方案：协议帧（Protocol Frame）

RPC 框架会定义自己的协议帧格式，最常用的是**长度前缀法**：

```
┌────────┬────────┬──────────────┬─────────────────────┐
│ 魔数    │ 版本号  │  消息体长度    │     消息体            │
│ 2字节   │ 1字节   │  4字节        │   N字节（由长度决定）  │
├────────┼────────┼──────────────┼─────────────────────┤
│ 0xCAFE │ 0x01   │ 0x000000FF   │  序列化后的请求/响应   │
└────────┴────────┴──────────────┴─────────────────────┘
```

各个字段的作用：
- **魔数（Magic Number）**：固定值，用来快速识别这是不是我们的协议包。如果收到的字节流开头不是这个魔数，说明数据错乱了，直接丢弃。类似于文件格式里 PDF 以 `%PDF` 开头、Java class 文件以 `CAFEBABE` 开头。
- **版本号**：协议版本，方便后续升级时做兼容处理。
- **消息体长度**：关键字段！告诉接收方后面还有多少字节是属于这条消息的。
- **消息体**：序列化后的 RpcRequest 或 RpcResponse。

解码过程：
1. 先读 2 字节，检查魔数是否匹配
2. 再读 1 字节版本号
3. 再读 4 字节拿到消息体长度 N
4. 再读 N 字节得到完整消息体
5. 如果 N 字节还没收全，就等着继续收

这样无论 TCP 怎么粘包拆包，接收方都能正确切分出每一条完整消息。

#### 其他解决方案

| 方案 | 原理 | 优缺点 |
| --- | --- | --- |
| 长度前缀法 | 消息头带长度字段 | 最常用，RPC 框架首选 |
| 分隔符法 | 用特殊字符分割消息（如 `\n`） | 简单但消息体不能包含分隔符，HTTP 用的 `\r\n` |
| 固定长度法 | 每条消息固定长度 | 简单但浪费带宽，不灵活 |

### 6. 服务端调度（Dispatcher）

服务端收到请求后，需要找到对应的本地服务实现并调用。这就是 Dispatcher 做的事。

#### 本地服务注册表

服务端启动时，会把所有提供的服务实现注册到一个 Map 里：

```java
/**
 * 本地服务注册表
 * key: 服务接口名（如 "com.example.UserService"）
 * value: 服务实现对象（如 UserServiceImpl 的实例）
 */
private static final Map<String, Object> SERVICE_MAP = new ConcurrentHashMap<>();

// 服务端启动时注册
public void register(String serviceName, Object serviceImpl) {
    SERVICE_MAP.put(serviceName, serviceImpl);
}

// 注册示例
register("com.example.UserService", new UserServiceImpl());
register("com.example.OrderService", new OrderServiceImpl());
```

#### 反射调用

收到请求后，Dispatcher 做三件事：
1. 从 Map 里根据 serviceName 找到服务实现对象
2. 根据 methodName 和 paramTypes 找到具体方法
3. 用反射调用方法，拿到结果

```java
public RpcResponse dispatch(RpcRequest request) {
    RpcResponse response = new RpcResponse();
    response.setRequestId(request.getRequestId());

    try {
        // 1. 查找服务实现
        Object serviceImpl = SERVICE_MAP.get(request.getServiceName());
        if (serviceImpl == null) {
            throw new RuntimeException("服务不存在: " + request.getServiceName());
        }

        // 2. 查找方法
        Method method = serviceImpl.getClass().getMethod(
            request.getMethodName(),
            request.getParamTypes()
        );

        // 3. 反射调用
        Object result = method.invoke(serviceImpl, request.getArgs());
        response.setResult(result);

    } catch (Exception e) {
        response.setException(e);
    }

    return response;
}
```

#### 反射性能优化

Java 反射调用（`method.invoke()`）性能不太好，每次调用都要做安全检查、参数类型匹配等。RPC 框架通常用以下方式优化：

| 优化方式 | 原理 | 效果 |
| --- | --- | --- |
| `method.setAccessible(true)` | 跳过访问权限检查 | 提升 2-4 倍 |
| MethodHandle（Java 7+） | JVM 层面的方法引用，可被 JIT 优化 | 接近直接调用 |
| Javassist 生成调用代码 | 编译期生成直接调用代码，避免反射 | 等同直接调用 |
| 缓存 Method 对象 | 避免每次都 getMethod 查找 | 减少查找开销 |

Dubbo 默认用 Javassist 生成调用代码，避免了反射开销。

### 7. 同步调用 vs 异步调用

#### 同步调用的问题

默认情况下 RPC 是同步的——调用方发出请求后阻塞等待，直到服务端返回结果：

```java
// 同步调用：串行执行，总耗时 = 100 + 100 + 100 = 300ms
UserInfo user = userService.getUserInfo(userId);      // 100ms
Address addr = addressService.getAddress(userId);      // 100ms
CreditScore score = creditService.getScore(userId);    // 100ms
```

三个调用之间没有依赖关系，但串行执行浪费了时间。

#### Future 概念：还没装东西的盒子

要理解异步调用，先理解 Future。

Future 就像快递单号。你在网上下单后，快递还没到，但你拿到了一个快递单号。你可以先去做别的事，等需要的时候用快递单号查一下快递到了没有。

```java
// Future 就是一个"还没装结果的盒子"
// 你可以先拿着盒子去做别的事
// 等需要结果时再打开盒子看
CompletableFuture<UserInfo> future = new CompletableFuture<>();

// 此时盒子是空的，result 还没有
// ...

// 等网络响应回来后，往盒子里放结果
future.complete(userInfo);   // 塞结果进盒子

// 调用方通过 get() 打开盒子拿结果
// 如果结果还没到，get() 会阻塞等待
UserInfo user = future.get();
```

#### CompletableFuture 代码示例

```java
// 异步调用：并行执行，总耗时 = max(100, 100, 100) = 100ms
CompletableFuture<UserInfo> userFuture =
    CompletableFuture.supplyAsync(() -> userService.getUserInfo(userId));

CompletableFuture<Address> addrFuture =
    CompletableFuture.supplyAsync(() -> addressService.getAddress(userId));

CompletableFuture<CreditScore> scoreFuture =
    CompletableFuture.supplyAsync(() -> creditService.getScore(userId));

// 三个请求同时发出，并行等待
UserInfo user = userFuture.get();        // 如果已经回来就直接拿，否则等
Address addr = addrFuture.get();
CreditScore score = scoreFuture.get();

// 总耗时从 300ms 降到约 100ms
```

#### 为什么要把请求和响应对应起来？

在性能优化中，RPC 框架通常在一个 TCP 连接上同时发多个请求（多路复用）。这些请求的响应可能乱序返回：

```
客户端                              服务端
  │── 请求A（查用户）──────────────>│
  │── 请求B（查地址）──────────────>│   A 要查数据库，慢
  │── 请求C（查积分）──────────────>│   B 命中缓存，快
  │                                  │   C 中等
  │<─────────────── 响应B ──────────│   B 先回来
  │<─────────────── 响应C ──────────│   C 第二个回来
  │<─────────────── 响应A ──────────│   A 最后回来
```

客户端怎么知道收到的响应是给哪个请求的？答案是 **requestId**。

#### requestId + ConcurrentHashMap 机制

这是 RPC 异步调用的核心机制，面试经常考。逐行解释：

```java
public class RpcClient {

    /**
     * 核心数据结构：requestId -> Future 的映射表
     * 每发一个请求，就在这个 Map 里放一个空 Future
     * 响应回来时，根据 requestId 找到对应的 Future，把结果塞进去
     *
     * 为什么用 ConcurrentHashMap？因为发送线程和接收线程不是同一个线程，
     * 需要线程安全的容器
     */
    private final Map<Long, CompletableFuture<RpcResponse>> pendingRequests
        = new ConcurrentHashMap<>();

    /**
     * 发送 RPC 请求（异步版本）
     */
    public CompletableFuture<RpcResponse> sendAsync(RpcRequest request) {
        // 1. 生成唯一的请求 ID
        long requestId = IdGenerator.nextId();
        request.setRequestId(requestId);

        // 2. 创建一个空的 Future（盒子），放进 Map
        //    key = requestId，value = 空盒子
        CompletableFuture<RpcResponse> future = new CompletableFuture<>();
        pendingRequests.put(requestId, future);

        // 3. 序列化 + 发送请求到服务端
        //    注意：发完就返回了，不等结果
        byte[] data = serializer.serialize(request);
        channel.writeAndFlush(data);

        // 4. 返回 Future 给调用方
        //    调用方可以选择立即 get()（阻塞），也可以先做别的事
        return future;
    }

    /**
     * 接收线程：当 TCP 连接收到服务端返回的数据时调用
     * 这个方法运行在 Netty 的 IO 线程里，和 sendAsync 不是同一个线程
     */
    public void onResponseReceived(RpcResponse response) {
        // 1. 从响应里拿到 requestId
        long requestId = response.getRequestId();

        // 2. 根据 requestId 从 Map 里找到对应的 Future
        CompletableFuture<RpcResponse> future = pendingRequests.remove(requestId);

        if (future != null) {
            // 3. 往 Future 里塞结果 —— 此时调用方的 get() 会被唤醒
            future.complete(response);
        }
        // 如果 future == null，说明请求已超时被清理掉了
    }

    /**
     * 超时清理：定时扫描 pendingRequests，清理超时的请求
     */
    public void cleanTimeoutRequests() {
        pendingRequests.forEach((requestId, future) -> {
            if (isTimeout(requestId)) {
                pendingRequests.remove(requestId);
                future.completeExceptionally(
                    new TimeoutException("RPC 调用超时, requestId=" + requestId)
                );
            }
        });
    }
}
```

整个流程串起来：

```
1. 调用方调 sendAsync()
2. 生成 requestId=101，创建空 Future，放进 Map{101 -> Future}
3. 发送请求（带着 requestId=101）到服务端
4. 返回 Future 给调用方（调用方可以继续发其他请求）
5. ... 同时发了 requestId=102、103 ...
6. 服务端返回了 102 的结果
7. onResponseReceived() 拿到 requestId=102
8. 从 Map 找到 102 对应的 Future，塞结果进去
9. 调 future102.get() 的线程被唤醒，拿到结果
```

### 8. 面试万能回答模板

> "一个完整的 RPC 调用分为客户端和服务端两侧。客户端通过动态代理拦截接口方法调用，把方法名、参数封装成请求对象，经过序列化变成二进制，通过 TCP 发到服务端。服务端反序列化后，通过服务注册表找到对应的实现类，用反射调用目标方法，再把结果序列化返回。
>
> 为了提高性能，通常在一个 TCP 连接上做多路复用，用 requestId 把请求和响应对应起来，配合 CompletableFuture 实现异步调用。
>
> 解决 TCP 粘包问题靠的是自定义协议帧，消息头里带魔数校验和长度字段，接收方按长度切分消息。"

## 小结（3-5 条关键点）

- RPC 调用经历 9 步：业务调用 → 代理拦截 → 序列化 → 网络传输 → 反序列化 → 服务查找 → 反射调用 → 序列化结果 → 返回结果。
- 动态代理是 RPC 客户端的核心，JDK 动态代理基于接口，通过 InvocationHandler 拦截所有方法调用并转为网络请求。
- TCP 是字节流无消息边界，RPC 框架通过协议帧（魔数 + 版本 + 长度 + 消息体）解决粘包/拆包问题。
- 异步调用的核心是 requestId + ConcurrentHashMap + CompletableFuture：发请求时存空 Future，收响应时根据 requestId 找到 Future 并塞结果。
- 服务端调度靠本地服务注册表（Map）+ 反射调用，生产环境用 Javassist 或 MethodHandle 优化反射性能。
