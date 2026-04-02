# Java - 第 3 课：Runnable、Callable、Future 与 CompletableFuture

## 学习目标（本节结束后你能做到什么）

- 分清 `Runnable`、`Callable`、`Future`、`CompletableFuture` 分别处在哪一层抽象上。
- 理解为什么说前两个更像“任务定义”，后两个更像“结果与流程控制”。
- 知道 `Future` 的典型能力和局限。
- 理解 `CompletableFuture` 为什么适合做链式异步编排。
- 能回答 `thenApply`、`thenCompose`、`thenCombine` 这些高频追问。

## 内容讲解（核心概念，用类比、例子、图示说清楚）

### 1. 先给这四个东西画一张总图

你可以先粗暴地这样记：

- `Runnable`：一段要执行的任务，不返回结果
- `Callable`：一段要执行的任务，可以返回结果，还能抛异常
- `Future`：异步任务未来结果的“凭证”或“占位符”
- `CompletableFuture`：更高级的 `Future`，支持链式回调、任务组合、异常处理和异步流程编排

如果只记一句：

**`Runnable` / `Callable` 定义“任务长什么样”，`Future` / `CompletableFuture` 定义“任务执行后怎么拿结果、怎么继续往后编排”。**

### 2. 先看最朴素的 `Runnable`

`Runnable` 本质上就是一段可以在线程里跑的代码。

```java
public interface Runnable {
    void run();
}
```

它的特点非常直观：

- 只有一个 `run()`
- 没有返回值
- 不能直接声明抛出 checked exception

所以它很适合表示这种任务：

- 做一件事
- 不关心返回值
- 只是想异步扔出去执行一下

例如：

```java
Runnable task = () -> {
    System.out.println("do something");
};

new Thread(task).start();
```

你可以把它理解成：交给别人一张纸条，上面写着“帮我把这件事做了”，但你没有要求带回结果。

### 3. `Callable` 为什么会出现

很多任务不只是“做了就完”，而是：

- 我希望另一个线程帮我算个结果
- 算完之后要拿回来
- 任务里可能会抛异常

这时 `Runnable` 就不够用了，于是有了 `Callable<V>`：

```java
public interface Callable<V> {
    V call() throws Exception;
}
```

它和 `Runnable` 最核心的区别有两个：

- `call()` 有返回值
- `call()` 可以抛异常

例如：

```java
Callable<Integer> task = () -> 1 + 2;
```

你可以把它理解成一张升级版纸条：

“帮我把这道题算出来，算完把答案带回来。”

### 4. `Runnable` 和 `Callable` 本质上还只是“任务描述”

这里特别容易卡住。

很多人学到这里会想：我已经定义好了一个 `Callable`，那结果到底怎么拿？

答案是：

- `Runnable` / `Callable` 只是“任务本身”
- 任务真正被提交出去执行以后，才会涉及“异步结果怎么拿”

这就是 `Future` 出场的地方。

### 5. `Future` 是什么

`Future` 可以理解成：

**异步任务结果的票据、凭证或占位符。**

意思是：

- 任务现在可能还没执行完
- 但你先拿到一个 `Future`
- 将来可以通过它问：结果好了没？

典型用法通常是配合线程池：

```java
ExecutorService executor = Executors.newFixedThreadPool(2);

Callable<Integer> task = () -> {
    Thread.sleep(1000);
    return 42;
};

Future<Integer> future = executor.submit(task);
```

这里发生的事情是：

- 你定义了一个 `Callable<Integer>`
- 把它提交给线程池执行
- 线程池立刻返回一个 `Future<Integer>`

这个 `Future` 不是结果本身，而是结果的代理。

### 6. `Future` 常见方法

#### 6.1 `get()`

```java
Integer result = future.get();
```

它会拿任务结果，但如果任务还没完成，当前线程会阻塞等待。

这点非常关键，因为很多人以为“用了 `Future` 就彻底异步了”。其实如果你很快就 `get()`，本质上还是在同步等结果。

#### 6.2 `isDone()`

```java
future.isDone();
```

表示任务是否已经完成。

#### 6.3 `cancel()`

```java
future.cancel(true);
```

尝试取消任务。

#### 6.4 `isCancelled()`

表示任务是否已取消。

### 7. `Future` 的问题是什么

虽然 `Future` 比单纯的 `Runnable` / `Callable` 往前走了一步，但它仍然很“原始”。

它的主要问题包括：

#### 7.1 拿结果太被动

通常你要么：

- 一直轮询 `isDone()`
- 要么直接 `get()` 阻塞

这两种方式都不够优雅。

#### 7.2 不擅长描述复杂异步流程

比如你想做：

- 任务 A 完成后自动开始任务 B
- A 和 B 并行执行，最后汇总
- 谁先完成用谁
- 出错就降级返回默认值

普通 `Future` 做这些会很别扭。

这就是为什么 Java 8 又引入了 `CompletableFuture`。

### 8. `CompletableFuture` 是什么

一句话先说：

**`CompletableFuture` = 更强的 `Future` + 能编排异步流程的工具。**

它比普通 `Future` 强很多，关键在于：

- 它不只是“等结果”
- 它还能“围绕结果继续往后写流程”

这就像把一个“结果票据”升级成了一条“异步流水线”。

### 9. 最常见的两个入口

#### 9.1 `runAsync`

适合没有返回值的异步任务，更接近 `Runnable` 风格。

```java
CompletableFuture<Void> future =
    CompletableFuture.runAsync(() -> {
        System.out.println("异步执行任务");
    });
```

#### 9.2 `supplyAsync`

适合有返回值的异步任务，更接近 `Callable` 风格。

```java
CompletableFuture<Integer> future =
    CompletableFuture.supplyAsync(() -> 100);
```

### 10. `get()` 和 `join()` 怎么理解

```java
Integer result = future.get();
```

或者：

```java
Integer result = future.join();
```

简单理解：

- `get()` 更偏传统 `Future` 风格，会抛 checked exception
- `join()` 更偏函数式风格，抛 unchecked exception

很多链式代码里，`join()` 往往更顺手。

### 11. `CompletableFuture` 真正强的地方：链式编排

这部分才是它的灵魂。

#### 11.1 `thenApply`

上一步完成后，对结果做一个普通转换。

```java
CompletableFuture<Integer> future =
    CompletableFuture.supplyAsync(() -> 10)
        .thenApply(x -> x * 2);
```

含义是：

- 先异步得到 `10`
- 再把它转成 `20`

这个适合“上一步结果出来后，做一个同步转换”。

#### 11.2 `thenAccept`

消费结果，但不再返回新的结果。

```java
CompletableFuture<Void> future =
    CompletableFuture.supplyAsync(() -> 10)
        .thenAccept(System.out::println);
```

适合“我只想用一下结果，不想再产出新值”。

#### 11.3 `thenRun`

不关心上一步结果，只是任务结束后再做点事。

```java
CompletableFuture<Void> future =
    CompletableFuture.supplyAsync(() -> 10)
        .thenRun(() -> System.out.println("done"));
```

### 12. 为什么有 `thenCompose`

这是最值得真正吃透的一个点。

假设：

1. 先异步查用户 ID
2. 再根据用户 ID 异步查订单

第二步本身也是异步任务，这时如果简单用 `thenApply`，结果会变成“Future 套 Future”。

所以要用：

```java
CompletableFuture<String> future =
    CompletableFuture.supplyAsync(() -> "user123")
        .thenCompose(userId ->
            CompletableFuture.supplyAsync(() -> "订单列表 for " + userId)
        );
```

`thenCompose` 的作用可以理解成：

**把两个串行的异步任务接平。**

否则你会得到：

```text
CompletableFuture<CompletableFuture<String>>
```

这就很难用了。

一个很实用的记忆方式是：

- `thenApply` 像 `map`：值变值
- `thenCompose` 像 `flatMap`：值变 future，并自动拍平

### 13. 多个异步任务怎么组合

#### 13.1 `thenCombine`

两个互不依赖的任务并行跑，最后合并结果。

```java
CompletableFuture<Integer> f1 = CompletableFuture.supplyAsync(() -> 10);
CompletableFuture<Integer> f2 = CompletableFuture.supplyAsync(() -> 20);

CompletableFuture<Integer> result =
    f1.thenCombine(f2, Integer::sum);
```

适合：两个任务能并发，最后再汇总。

#### 13.2 `allOf`

等多个任务都完成。

```java
CompletableFuture<Void> all =
    CompletableFuture.allOf(f1, f2);
```

它返回的是 `CompletableFuture<Void>`，表示“都完成了”。如果还要拿各自结果，一般再配合 `join()`。

#### 13.3 `anyOf`

谁先完成就先用谁。

```java
CompletableFuture<Object> any =
    CompletableFuture.anyOf(f1, f2);
```

适合多个下游抢答、谁先返回用谁的场景。

### 14. 异常处理为什么也是它的强项

#### 14.1 `exceptionally`

出错时返回默认值。

```java
CompletableFuture<Integer> future =
    CompletableFuture.supplyAsync(() -> {
        throw new RuntimeException("出错");
    }).exceptionally(ex -> 0);
```

#### 14.2 `handle`

不管成功失败都处理，还能改结果。

```java
CompletableFuture<String> future =
    CompletableFuture.supplyAsync(() -> "ok")
        .handle((result, ex) -> ex == null ? result + "!" : "默认值");
```

#### 14.3 `whenComplete`

更像收尾通知，通常不改结果。

```java
CompletableFuture<Integer> future =
    CompletableFuture.supplyAsync(() -> 100)
        .whenComplete((result, ex) -> {
            System.out.println("结果: " + result);
        });
```

### 15. 这四个东西怎么放在一张图里理解

现在你可以把它们放回一条能力演进链：

#### 15.1 `Runnable`

定义一个无返回值任务。

#### 15.2 `Callable`

定义一个有返回值、可抛异常任务。

#### 15.3 `Future`

任务提交后，拿到一个未来结果凭证。

#### 15.4 `CompletableFuture`

不只是拿结果，还可以继续做链式回调、多个任务组合和异常恢复。

所以更准确地说：

- 前两个定义“做什么”
- 后两个定义“做完后怎么办”

### 16. 实际开发里怎么选

#### 16.1 用 `Runnable` 的时候

- 只是想扔个后台任务
- 不关心返回值
- 逻辑简单

#### 16.2 用 `Callable + Future` 的时候

- 需要返回值
- 任务在线程池中执行
- 流程不复杂
- 只是简单异步提交一下

#### 16.3 用 `CompletableFuture` 的时候

- 有多个异步步骤
- 想串行编排或并行组合
- 想优雅处理异常和降级
- 不想写一堆阻塞式 `get()`

### 17. 面试里怎么回答更像样

可以这样组织：

`Runnable` 表示一个无返回值的任务，`Callable` 表示一个有返回值并且可以抛异常的任务。  
`Future` 表示异步任务未来的结果，可以查询状态、取消任务、阻塞获取结果。  
但普通 `Future` 的编排能力较弱，通常只能通过 `get()` 被动获取结果。  
`CompletableFuture` 是对 `Future` 的增强，除了表示异步结果，还支持链式回调、任务组合、异常处理和异步流程编排，更适合复杂并发场景。  
其中 `thenApply` 用于结果转换，`thenCompose` 用于串联异步任务并拍平嵌套 future，`thenCombine` 用于并行任务结果汇总。

## 小结

- `Runnable` 和 `Callable` 更偏任务定义，`Future` 和 `CompletableFuture` 更偏结果与流程控制。
- `Runnable` 无返回值，`Callable` 有返回值且可抛异常。
- `Future` 解决了“异步提交后怎么拿结果”的问题，但编排能力有限。
- `CompletableFuture` 的核心价值在于链式回调、任务组合和异常处理。
- `thenApply` 是值到值，`thenCompose` 是值到 future 并自动拍平。

## 问题（检测你对当前章节内容是否了解）

1. 为什么说 `Runnable` / `Callable` 更像“任务模板”，而 `Future` / `CompletableFuture` 更像“结果控制”？
2. `Callable` 相比 `Runnable` 多了哪两个关键能力？
3. 普通 `Future` 为什么不适合复杂异步编排？
4. `thenApply` 和 `thenCompose` 的核心区别是什么？
5. 在什么场景下你会优先考虑 `CompletableFuture`？
