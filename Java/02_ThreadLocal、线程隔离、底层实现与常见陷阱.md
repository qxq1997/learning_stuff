# Java - 第 2 课：ThreadLocal、线程隔离、底层实现与常见陷阱

## 学习目标（本节结束后你能做到什么）

- 用一句话说清 `ThreadLocal` 解决的是什么问题。
- 理解它不是“线程共享”，而是“线程隔离”。
- 知道 `set()`、`get()`、`remove()` 大致在底层做了什么。
- 理解 `Thread -> ThreadLocalMap` 这条关系，而不是误以为是全局大 Map。
- 知道 `ThreadLocal` 在线程池环境中的两个经典风险：脏数据串请求和内存滞留。

## 内容讲解（核心概念，用类比、例子、图示说清楚）

### 1. 先一句话理解 `ThreadLocal`

`ThreadLocal` 的核心目标很朴素：

**我想让每个线程都有自己独立的一份变量副本，互不干扰。**

它不是用来在线程之间共享数据的，恰恰相反，它是用来避免共享的。

你可以把它理解成：

**给每个线程发一个私有小抽屉。**

虽然大家拿着的是同一个 `ThreadLocal` 对象，但：

- 线程 A 存进去的值，只有线程 A 自己看到
- 线程 B 存进去的值，只有线程 B 自己看到

### 2. 它到底在解决什么问题

先看一个特别真实的后端场景。

一次请求进来后，整个调用链里你都想拿到“当前用户 ID”或者“当前 traceId”。最笨的方式是层层传参：

```java
serviceA(userId);
serviceB(userId);
serviceC(userId);
```

如果调用链很深，就会出现几个问题：

- 很多方法本身不关心 `userId`，却为了往下传不得不带着它
- 参数一层层透传，代码会越来越脏
- 某些上下文信息本来应该是“请求级别”的，不该到处显式传递

于是就有人想：能不能把“当前线程正在处理的上下文”放在线程自己的地方里？

这就是 `ThreadLocal` 常见的价值来源。

典型场景包括：

- 当前登录用户
- `traceId`
- 请求上下文
- 数据库连接上下文
- 事务上下文
- 某些线程不安全对象的线程内复用

### 3. 它和普通成员变量有什么不同

假设你写了一个单例对象：

```java
class UserContext {
    private String userId;
}
```

如果多个线程都共用这个对象，就会发生覆盖：

- 线程 A 刚写进去 `userA`
- 线程 B 又写成 `userB`
- 线程 A 再读时，可能拿到的已经不是自己的值了

而 `ThreadLocal<String>` 的意思是：

虽然变量名看起来是同一个，但每个线程实际拿到的是自己的那份值。

它的本质不是“大家共用一个变量”，而是“同一个变量名在每个线程各自记一份账”。

### 4. 最基本的使用方式

```java
private static final ThreadLocal<String> currentUser = new ThreadLocal<>();
```

设置值：

```java
currentUser.set("userA");
```

获取值：

```java
String user = currentUser.get();
```

删除值：

```java
currentUser.remove();
```

### 5. 一个简单例子

```java
public class ThreadLocalDemo {
    private static final ThreadLocal<String> local = new ThreadLocal<>();

    public static void main(String[] args) {
        Thread t1 = new Thread(() -> {
            local.set("线程1的数据");
            System.out.println(Thread.currentThread().getName() + ": " + local.get());
        });

        Thread t2 = new Thread(() -> {
            local.set("线程2的数据");
            System.out.println(Thread.currentThread().getName() + ": " + local.get());
        });

        t1.start();
        t2.start();
    }
}
```

虽然用的是同一个 `local`，但不同线程看到的是自己的值。这就是 `ThreadLocal` 的最直观效果。

### 6. 底层到底是怎么做到的

这是最关键的理解点之一。

很多人的第一直觉是：

```text
ThreadLocal -> Map<Thread, Value>
```

也就是认为 `ThreadLocal` 自己维护了一个大 Map，里面记录每个线程对应的值。

**但更接近真实的设计其实是：**

```text
Thread -> Map<ThreadLocal, Value>
```

也就是说：

- 不是 `ThreadLocal` 持有所有线程的数据
- 而是每个 `Thread` 对象内部，都有一个属于自己的 `ThreadLocalMap`
- 这个线程自己的 `ThreadLocalMap` 里，再记录“针对不同 `ThreadLocal` 对象分别存了什么值”

这个方向一定要搞清楚。

### 7. 为什么这样设计更自然

因为 `ThreadLocal` 的目标就是做“线程私有存储”。

如果设计成一个 `ThreadLocal` 管所有线程的数据，会带来：

- 并发访问复杂
- 生命周期管理更麻烦
- 统一清理更麻烦

而现在的设计是：

- 每个线程管理自己的局部变量账本
- 当前线程访问自己的 `ThreadLocalMap`
- 没必要跟别的线程争抢

这和它“线程隔离”的目标是天然一致的。

### 8. `set()` / `get()` / `remove()` 在做什么

#### 8.1 `set(value)`

本质上会先拿到当前线程，再去当前线程自己的 `ThreadLocalMap` 里存：

- key = 当前这个 `ThreadLocal`
- value = 你传入的值

#### 8.2 `get()`

也是先拿到当前线程，再到它自己的 `ThreadLocalMap` 里，根据当前这个 `ThreadLocal` 找对应的值。

#### 8.3 `remove()`

则是从当前线程自己的 `ThreadLocalMap` 中，把当前这个 `ThreadLocal` 相关的条目删掉。

所以你可以把 `ThreadLocal` 理解成“钥匙”，真正的抽屉其实长在 `Thread` 身上。

### 9. `withInitial()` 和默认值

有时你希望线程第一次 `get()` 时就有默认值，而不是自己判空。

```java
private static final ThreadLocal<Integer> local =
    ThreadLocal.withInitial(() -> 0);
```

这样第一次 `local.get()`，如果当前线程还没 `set()` 过，就会默认拿到 `0`。

这个小功能很实用，能让代码更干净。

### 10. `ThreadLocal` 和 `synchronized` 的区别

这两个特别容易混。

#### 10.1 `synchronized`

它解决的是：

**多个线程共享同一份数据时，怎么保证访问安全。**

也就是“共享，但加锁”。

#### 10.2 `ThreadLocal`

它解决的是：

**干脆别共享，每个线程自己一份。**

也就是“隔离，而不是同步”。

你可以用一个特别通俗的比喻：

- `synchronized`：大家共用一个厕所，但要排队加锁
- `ThreadLocal`：每个人一个独立厕所，根本不用抢

这两种思路完全不同。

### 11. 常见使用场景

#### 11.1 保存当前请求上下文

比如：

- 当前登录用户
- `traceId`
- `requestId`
- 租户 ID

在传统“一次请求通常由一个线程处理”的模型里，这特别常见。

#### 11.2 保存数据库连接或事务上下文

很多框架会把：

- 当前线程绑定的数据库连接
- 当前事务状态
- ORM Session

放到 `ThreadLocal` 里，让同一线程的调用链都能拿到。

#### 11.3 给线程不安全对象做“每线程一份”

比如早年大家常拿 `SimpleDateFormat` 举例，因为它线程不安全。

```java
private static final ThreadLocal<SimpleDateFormat> formatter =
    ThreadLocal.withInitial(() -> new SimpleDateFormat("yyyy-MM-dd"));
```

这样每个线程有自己一份实例，就不会互相打架。

不过现代 Java 更推荐 `java.time` 新时间 API，所以这个例子更多是帮助你理解思想。

### 12. `ThreadLocal` 最大的两个坑

这部分是真正在工程里最重要的内容。

#### 12.1 内存滞留和“看起来像内存泄漏”

经典结论是：

- `ThreadLocalMap` 的 key 对 `ThreadLocal` 是弱引用
- 但 value 不是弱引用，而是强引用

这会导致一种情况：

1. 外部代码已经不再持有某个 `ThreadLocal` 的强引用
2. 这个 `ThreadLocal` 对象被 GC 回收了
3. `ThreadLocalMap` 里的 key 变成了 `null`
4. 但 value 还挂在 `Thread` 的 `ThreadLocalMap` 里
5. 只要线程还活着，这个 value 就可能继续滞留

这就是为什么大家常说 `ThreadLocal` 有“内存泄漏风险”。更准确地说，很多时候是“脏 value 长时间挂在线程上不被及时清掉”。

#### 12.2 在线程池里串请求

这是实际项目里更常见、也更恶心的坑。

原因在于：线程池里的线程会复用。

比如：

1. 请求 A 被线程 1 处理，在线程 1 的 `ThreadLocal` 里放了用户信息
2. 请求结束了，但没有 `remove()`
3. 过一会儿请求 B 也恰好被线程 1 处理
4. 请求 B 一 `get()`，拿到了请求 A 残留的数据

于是就出现了“数据穿越”。

这种问题很难排查，因为它：

- 偶发
- 和线程复用有关
- 看起来像业务逻辑神秘串线

### 13. 为什么一定要 `remove()`

最标准的姿势是：

```java
try {
    local.set(value);
    // 业务逻辑
} finally {
    local.remove();
}
```

尤其在线程池环境里，这是一个非常重要的习惯。

`remove()` 的价值主要有两个：

- 避免线程复用时脏数据串到下一个任务
- 帮助尽早清理不再需要的 value，减少长时间滞留

### 14. 为什么异步模型里不能迷信 `ThreadLocal`

`ThreadLocal` 是和线程绑定的，不是和任务绑定的。

所以一旦你的业务经过：

- 线程池切换
- 异步回调
- `CompletableFuture`
- 响应式链路

你以为“当前上下文还在”，其实很可能已经不在同一个线程上了。

比如：

- 在线程 A 里 `set()` 了一个值
- 后面异步任务切到了线程 B
- 线程 B `get()` 时，拿不到线程 A 的值

这不是 bug，而是 `ThreadLocal` 的设计边界。它天然更适合“单线程贯穿一个请求”的模型，不适合无脑套在频繁线程切换的异步模型上。

### 15. `InheritableThreadLocal` 是什么

它是 `ThreadLocal` 的一个变种，作用是让子线程在创建时可以继承父线程的值。

但要注意两个边界：

- 它是在“创建子线程那一刻”复制一份，不是后续实时同步
- 在线程池场景里往往不符合直觉，因为线程池线程不是你现场新建的子线程

所以它不是万能上下文传递方案。

### 16. 面试里怎么回答更像样

你可以这样答：

`ThreadLocal` 是 Java 提供的一种线程本地变量机制，用来为每个线程保存独立的数据副本，实现线程隔离。  
它不是解决共享变量同步问题的，而是通过“每线程一份”来避免竞争。  
底层上不是 `ThreadLocal` 自己维护一个全局 Map，而是每个 `Thread` 内部维护一个 `ThreadLocalMap`，key 是 `ThreadLocal`，value 是该线程对应的数据。  
常见场景包括保存用户上下文、`traceId`、数据库连接等。  
它的主要风险在线程池场景，因为线程会复用，如果不及时 `remove()`，可能导致脏数据串请求和 value 长时间滞留。  
因此通常建议在 `try-finally` 中 `set()` 后 `remove()`。

## 小结

- `ThreadLocal` 的本质是线程隔离，不是线程共享。
- 更接近真实的底层关系是 `Thread -> ThreadLocalMap`，不是 `ThreadLocal -> Map<Thread, Value>`。
- `set/get/remove` 都是在操作当前线程自己的 `ThreadLocalMap`。
- 在线程池场景里，不 `remove()` 很容易造成脏数据串请求。
- `ThreadLocal` 适合线程绑定的上下文，不适合频繁线程切换的异步链路里无脑使用。

## 问题（检测你对当前章节内容是否了解）

1. 为什么说 `ThreadLocal` 的目标是“隔离”而不是“共享”？
2. `ThreadLocal` 的底层关系为什么更应该理解成 `Thread -> ThreadLocalMap`？
3. `ThreadLocal` 和 `synchronized` 分别在解决什么问题？
4. 为什么在线程池环境里必须特别注意 `remove()`？
5. 为什么 `ThreadLocal` 不适合在线程切换频繁的异步模型里滥用？
