# RPC - 第 1 课：什么是 RPC

## 学习目标（本节结束后你能做到什么）

- 用业务场景解释 RPC 解决的核心问题
- 说清 RPC 和 HTTP 的本质区别，以及各自的适用场景
- 理解 RPC 的全称和核心设计思想
- 能在面试中回答"RPC vs REST"这类高频对比题

## 内容讲解

### 1. 从一个真实问题出发

假设你在做电商系统，有两个服务：**订单服务**和**用户服务**。订单服务在创建订单时，需要查一下用户的收货地址和信用等级。

问题来了：这两个服务跑在不同的机器上，不同的进程里，甚至可能在不同的机房。订单服务怎么去调用户服务的 `getUserInfo(userId)` 方法？

```
┌─────────────────┐          网络          ┌─────────────────┐
│   订单服务        │  ───────────────────>  │   用户服务        │
│                   │                        │                   │
│  需要调用：        │     跨进程、跨网络      │  getUserInfo()    │
│  getUserInfo()    │                        │  getAddress()     │
└─────────────────┘                         └─────────────────┘
```

这就是所有 RPC 框架要解决的根本问题：**跨进程、跨网络的方法调用**。

### 2. 最朴素的方案：直接用 HTTP 调

最直接的想法是：用户服务暴露一个 HTTP 接口，订单服务用 HttpClient 去调。

```java
// 订单服务中调用用户服务 —— 用 HTTP 方式
public UserInfo getUserInfo(Long userId) {
    // 1. 手动拼 URL
    String url = "http://user-service:8080/api/user/" + userId;

    // 2. 创建 HTTP 客户端
    HttpClient client = HttpClient.newHttpClient();

    // 3. 构建请求
    HttpRequest request = HttpRequest.newBuilder()
        .uri(URI.create(url))
        .header("Content-Type", "application/json")
        .GET()
        .build();

    // 4. 发送请求，拿到响应
    HttpResponse<String> response = client.send(request,
        HttpResponse.BodyHandlers.ofString());

    // 5. 手动解析 JSON
    return JSON.parseObject(response.body(), UserInfo.class);
}
```

这段代码能跑，但问题很明显：

- **啰嗦**：你本来只想调一个方法拿个对象，结果要写一堆 HTTP 相关的模板代码。
- **手动拼装**：URL、Header、参数序列化、响应反序列化，全得自己搞。
- **没有契约**：调用方和提供方之间没有强类型约束，改个字段名可能调用方完全不知道。
- **缺少治理**：超时、重试、负载均衡、服务发现，全得自己一个一个搭。

每调一个远程服务就写这么一坨代码，三个服务还好，三十个服务你就疯了。

### 3. RPC 的理想：远程调用看起来像本地方法调用

RPC 的核心理想非常朴素：**你调远程服务的方法，写起来应该跟调本地方法一样简单**。

```java
// RPC 方式调用 —— 开发者视角
@RpcReference
private UserService userService;

public Order createOrder(Long userId, Long productId) {
    // 看起来就像调本地方法，实际上底层走了网络
    UserInfo user = userService.getUserInfo(userId);
    Address addr = userService.getAddress(userId);

    // 拿到结果后继续本地逻辑
    return buildOrder(user, addr, productId);
}
```

你看这段代码，`userService.getUserInfo(userId)` 这一行，写起来跟调本地方法完全一样。你不需要关心 URL 怎么拼、JSON 怎么序列化、网络连接怎么管理、超时了怎么重试。所有这些脏活累活，RPC 框架帮你干了。

这就是 RPC 的核心思想：**屏蔽远程调用的复杂性，让开发者专注于业务逻辑**。

### 4. RPC 的全称和核心思想

RPC 全称 **Remote Procedure Call**，远程过程调用。

这个名字从 1984 年就有了（Birrell 和 Nelson 的论文），核心思想几十年没变过：

> 让程序能够像调用本地函数一样，调用运行在另一台机器上的函数。

注意几个关键词：
- **Remote**：跨网络、跨进程，不是同一个 JVM 里的方法调用。
- **Procedure**：过程/函数/方法，强调的是"调用一个动作"。
- **Call**：调用，对开发者而言就是一次普通的方法调用。

RPC 不是一个具体的协议（不像 HTTP 那样有 RFC 标准），它是一种**理念和架构模式**。gRPC、Dubbo、Thrift 都是这种理念的具体实现。

### 5. RPC vs HTTP（面试必考）

这是面试高频题，很多人答不好是因为把 RPC 和 HTTP 放在同一层比较，但它们根本不在同一个维度。

**本质区别：HTTP 是一个具体的应用层协议，RPC 是一种调用理念/框架。**

RPC 框架底层完全可以用 HTTP 做传输（比如 gRPC 就用的 HTTP/2），所以"RPC 和 HTTP 谁好"这个问题本身就不太准确。更准确的比较是：**直接用 HTTP REST 接口** vs **用 RPC 框架**。

| 对比维度 | 直接用 HTTP REST | RPC 框架 |
| --- | --- | --- |
| **本质** | 应用层协议，有 RFC 标准 | 调用理念 + 框架实现 |
| **传输格式** | 通常是 JSON 文本，可读性好 | 通常是二进制（Protobuf 等），体积小解析快 |
| **开发体验** | 手动拼 URL、手动序列化/反序列化 | 自动生成代码，像调本地方法 |
| **服务治理** | 没有内置，超时/重试/负载均衡自己搞 | 内置服务发现、负载均衡、熔断降级 |
| **接口约束** | 松散，靠文档约定 | IDL 强契约，改接口编译就报错 |
| **性能** | JSON 解析慢，HTTP 头部冗余大 | 二进制协议，头部紧凑，性能高很多 |
| **跨语言** | 天然跨语言，谁都能发 HTTP | 取决于框架，gRPC 跨语言，Dubbo 偏 Java |
| **调试** | 浏览器/curl 直接调，非常方便 | 需要专门工具，调试不如 HTTP 直观 |
| **生态通用性** | 所有语言、所有平台都支持 | 需要引入对应框架的依赖 |

#### 性能差距到底有多大？

举个直观的例子。传输同一个用户对象：

```
// JSON 格式（HTTP REST 常用）—— 约 120 字节
{"userId":12345,"name":"张三","age":28,"email":"zhangsan@example.com","level":"VIP"}

// Protobuf 二进制格式 —— 约 45 字节
// 不传字段名，用编号；数字用变长编码
0x08 0xB9 0x60 0x12 0x06 E5 BC A0 E4 B8 89 ...
```

体积差 2-3 倍，序列化/反序列化速度差 5-10 倍。一个请求感觉不大，但如果你的系统每秒处理 10 万次服务间调用，这个差距就非常可观了。

#### 开发体验差距

用 HTTP REST，接口改了怎么办？你得去改文档，然后通知所有调用方改代码。如果漏通知了一个调用方，线上直接报错。

用 RPC（以 gRPC 为例），接口定义在 `.proto` 文件里：

```protobuf
// user.proto —— 接口定义文件
service UserService {
    rpc GetUserInfo(UserRequest) returns (UserResponse);
}

message UserRequest {
    int64 user_id = 1;
}

message UserResponse {
    int64 user_id = 1;
    string name = 2;
    int32 age = 3;
    string email = 4;
}
```

改了 `.proto` 文件，所有调用方重新生成代码，编译阶段就能发现不兼容。这就是 **IDL 强契约** 的好处。

### 6. 一句话总结

> HTTP 通用但不精，RPC 为服务间调用专门优化。

HTTP REST 就像普通话，谁都能听懂，但表达效率一般。RPC 框架就像对讲机暗语，只有内部人听得懂，但传输快、不容易出错。

### 7. 适用场景：对内 RPC，对外 HTTP

这是工程实践中最常见的选择：

```
                    ┌──────────────────────────────────────┐
                    │            微服务集群内部              │
   用户/浏览器       │                                      │
   App/小程序    ──HTTP REST──>  API 网关                   │
                    │              │                        │
                    │         RPC  │  RPC                   │
                    │              ▼                        │
                    │         订单服务 ──RPC──> 库存服务     │
                    │              │                        │
                    │         RPC  │                        │
                    │              ▼                        │
                    │         用户服务 ──RPC──> 风控服务     │
                    └──────────────────────────────────────┘
```

- **对外**（面向浏览器、App、第三方）：用 HTTP REST。因为通用、简单、防火墙友好、前端能直接调。
- **对内**（服务和服务之间）：用 RPC。因为性能好、有类型安全、内置服务治理。

面试回答模板：

> "我们系统对外暴露 RESTful API 给前端和第三方，对内服务间通信用 RPC（比如 gRPC/Dubbo）。选择 RPC 主要考虑三点：一是二进制协议性能好，服务间调用量大时差距明显；二是 IDL 定义接口有强契约，避免接口变更导致线上事故；三是 RPC 框架内置了服务发现、负载均衡、熔断降级这些治理能力，不需要自己从零搭建。"

## 小结（3-5 条关键点）

- RPC 全称 Remote Procedure Call，核心思想是让远程调用看起来像本地方法调用，屏蔽网络通信的复杂性。
- HTTP 是协议，RPC 是理念/框架，两者不在同一层次；RPC 框架底层可以用 HTTP 做传输。
- RPC 相对于直接用 HTTP REST 的优势在于：二进制协议性能高、IDL 强契约防出错、内置服务治理能力。
- 工程实践中最常见的模式是"对外 HTTP REST，对内 RPC"。
- 面试时不要说"RPC 比 HTTP 好"，要说清各自适用场景和选择依据。
