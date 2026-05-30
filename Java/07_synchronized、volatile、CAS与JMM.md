# Java - 第 7 课：`synchronized`、`volatile`、CAS 与 JMM

## 学习目标（本节结束后你能做到什么）

- 用原子性、可见性、有序性解释常见并发错误。
- 使用 `happens-before` 而不是“立刻刷主内存”的口号理解 JMM。
- 区分 `volatile`、`synchronized`、CAS/原子类分别能保证什么。
- 说清 Java 六种线程状态以及 `wait` / `notify` 的监视器协作过程。
- 判断锁竞争、死锁和双重检查单例中的正确同步方案。

## 内容讲解（核心概念，用类比、例子、图示说清楚）

### 1. 并发 bug 的根源：源码一行不等于不可分割的一步

两个线程各自执行 50 次 `count++`，最终值不一定是 100：

```java
class Counter {
    int count;

    void increment() {
        count++;
    }
}
```

`count++` 至少包含读取旧值、计算新值、写回结果这些动作。两个线程都读到 `10`，再各自写回 `11`，就丢掉了一次更新。

这不是“CPU 不够快”，而是多个执行流在共享状态上缺少协议。Java 并发中最重要的三个问题由此出现：

| 问题 | 典型表现 | 需要的保证 |
| --- | --- | --- |
| 原子性 | `count++` 丢更新、余额扣减错误 | 复合修改不可被其他线程交错观察 |
| 可见性 | 一个线程更新停止标记，另一个线程迟迟看不到 | 写入应按规则对读者可见 |
| 有序性 | 发布对象引用时，其他线程看见未安全初始化的状态 | 跨线程观察必须有顺序约束 |

### 2. JMM 不是内存布局图，而是线程交互规则

Java Memory Model（JMM）定义的是**线程如何合法地观察共享变量读写**。教材常用“主内存”和“工作内存”帮助理解：线程可能从寄存器、缓存或编译优化后的结果中读取状态，不应假定每条普通读写都会自动被另一个线程按源码顺序看见。

更准确、也更能用于推理的概念是 `happens-before`：

> 如果操作 A happens-before 操作 B，那么 B 必须能够观察到 A 的效果，并且 A 在内存语义上先于 B。

高频规则包括：

| 规则 | 工程意义 |
| --- | --- |
| 程序次序规则 | 一个线程内，前面的操作 happens-before 后续操作 |
| monitor 锁规则 | 对同一 monitor 的解锁 happens-before 后续加锁 |
| `volatile` 规则 | 对同一变量的 `volatile` 写 happens-before 后续 `volatile` 读 |
| 线程启动规则 | 调用 `Thread.start()` 前的操作 happens-before 新线程中的操作 |
| 线程终止规则 | 线程内操作 happens-before 另一个线程成功从 `join()` 返回 |
| 传递性 | A 在 B 前，B 在 C 前，则 A 在 C 前 |

写并发代码时，你真正要回答的是：**读线程通过哪条 happens-before 路径获得对写入的合法观察？** 没有路径就可能是数据竞争。

### 3. `volatile`：发布最新状态，但不替你完成复合修改

`volatile` 非常适合“一个线程写状态，其他线程读取状态”的场景：

```java
class Worker implements Runnable {
    private volatile boolean running = true;

    @Override
    public void run() {
        while (running) {
            doOneUnitOfWork();
        }
    }

    void stop() {
        running = false;
    }
}
```

`stop()` 对 `running` 的写与工作线程后续对它的读建立顺序关系，因此工作线程能可靠观察停止请求。`volatile` 还限制围绕该读写的不合法重排序，使它可用于安全发布某些状态。

但它不让下面的代码变安全：

```java
private volatile int count;

void increment() {
    count++; // 读取 + 加一 + 写回，仍不是一个原子动作
}
```

多线程计数应选择：

```java
private final AtomicInteger count = new AtomicInteger();

void increment() {
    count.incrementAndGet();
}
```

或者在一个需要维护多个字段共同不变量的临界区使用锁。

### 4. 双重检查单例为什么既有锁也有 `volatile`

```java
final class Config {
    private static volatile Config instance;

    static Config getInstance() {
        Config current = instance;
        if (current == null) {
            synchronized (Config.class) {
                current = instance;
                if (current == null) {
                    current = new Config();
                    instance = current;
                }
            }
        }
        return current;
    }
}
```

- `synchronized` 保证初始化临界区内不会创建多个实例。
- `volatile` 保证实例引用的发布与构造完成之间具有正确的跨线程可见性和顺序约束。

不带 `volatile` 时，读线程在锁外读取 `instance`，没有一条足够的安全发布路径；它可能观察到引用已经非空，却无法依赖对象的初始化状态已经正确可见。

实际项目里，静态内部类持有者或 `enum` 单例通常更简单，但这道题很好地串联了锁与 JMM。

### 5. `synchronized`：monitor 上的互斥与内存语义

`synchronized` 锁定的是一个 monitor：

```java
private final Object lock = new Object();
private int balance;

void deposit(int amount) {
    synchronized (lock) {
        balance += amount;
    }
}
```

它同时提供两类保证：

1. 同一 monitor 的同步块在同一时刻只允许一个线程执行，保护复合不变量。
2. 一个线程退出同步块的解锁 happens-before 另一个线程随后获取同一 monitor，写入能够被后来持锁线程观察。

字节码层面要区分两种写法：

- 同步代码块通常由 `monitorenter` 与 `monitorexit` 表达，编译器还要确保异常路径释放 monitor。
- 同步方法通过方法访问标志 `ACC_SYNCHRONIZED` 表达，由 JVM 在调用时处理 monitor。

实例同步方法锁的是 `this`；静态同步方法锁的是对应的 `Class` 对象。锁对象不同，就不存在同一把锁上的互斥关系。

### 6. 可重入、等待集与 `wait` / `notify`

`synchronized` 是可重入的：已经持有某对象 monitor 的线程，可以再次进入由同一 monitor 保护的方法或代码块；退出次数与进入次数匹配后，锁才真正释放。

`Object.wait()` 则是**持有 monitor 后主动释放锁并等待条件**：

```java
final class Mailbox {
    private final Object lock = new Object();
    private String value;

    String take() throws InterruptedException {
        synchronized (lock) {
            while (value == null) {
                lock.wait();
            }
            String result = value;
            value = null;
            return result;
        }
    }

    void put(String newValue) {
        synchronized (lock) {
            value = newValue;
            lock.notifyAll();
        }
    }
}
```

必须记住四点：

1. `wait()`、`notify()`、`notifyAll()` 必须在持有同一个对象 monitor 时调用，否则抛出 `IllegalMonitorStateException`。
2. `wait()` 会释放当前 monitor；`Thread.sleep()` 不会释放已经持有的锁。
3. `notify()` 只选择某一个等待线程，API 不保证选中顺序；被通知的线程仍要重新竞争 monitor。
4. 等待条件必须写成 `while`，因为线程可能被错误条件的通知唤醒，也可能发生伪唤醒，拿到锁后必须重新验证条件。

复杂的多条件协作通常可用 `ReentrantLock` 配合多个 `Condition`，或直接选用 `BlockingQueue` 等更高层工具。AQS 与这些显式同步器的底座已在第 4 课说明。

### 7. Java 的六种线程状态：不要额外背一个 `RUNNING`

`Thread.State` 公开的状态只有六种：

| 状态 | 何时出现 | 常见触发 |
| --- | --- | --- |
| `NEW` | 已创建但尚未启动 | `new Thread(...)` |
| `RUNNABLE` | 可被调度或正在执行 | `start()` 后运行；Java 不另暴露 READY/RUNNING |
| `BLOCKED` | 等待进入 monitor | 竞争失败的 `synchronized` |
| `WAITING` | 无限期等待某事件 | `Object.wait()`、`Thread.join()`、`LockSupport.park()` |
| `TIMED_WAITING` | 有期限等待 | `sleep()`、限时 `wait/join/park` |
| `TERMINATED` | `run()` 已结束 | 正常返回或未捕获异常退出 |

最容易讲混的是 `BLOCKED` 和 `WAITING`：

- `BLOCKED` 是想进入 `synchronized` 却拿不到 monitor，锁释放后有机会重新竞争。
- `WAITING` 通常是已经放弃当前推进条件，等待通知、目标线程结束或 `unpark`；例如 `wait()` 已释放原 monitor，被通知后还需再次竞争锁。

注意 `ReentrantLock` 获取失败时底层常通过 `LockSupport.park()` 挂起，因此从 `Thread.State` 观察可能是 `WAITING`/`TIMED_WAITING`，而不是专属于 monitor 竞争的 `BLOCKED`。

### 8. `synchronized` 与 `ReentrantLock` 如何选择

两者都是可重入互斥方案，也都能形成正确的内存可见性边界，但能力形状不同：

| 对比点 | `synchronized` | `ReentrantLock` |
| --- | --- | --- |
| 释放方式 | 退出代码块时自动释放 | 必须 `finally` 中显式 `unlock()` |
| 等待锁时响应中断 | 不提供中断式 monitor 获取 API | `lockInterruptibly()` |
| 尝试/超时获取 | 不提供 | `tryLock()` / 限时 `tryLock()` |
| 公平选项 | 没有公平顺序承诺 | 构造时可选公平策略 |
| 条件队列 | 每个 monitor 一套等待机制 | 可建立多个 `Condition` |
| 实现位置 | JVM monitor 机制 | JDK 层基于 AQS 的同步器 |

对于短小、作用域清楚的互斥，优先用 `synchronized` 往往更不容易遗漏解锁。确实需要中断获取、限时获取、公平策略或多个条件队列时，再使用 `ReentrantLock`。不能笼统宣称后者在现代 JVM 下一定更快。

### 9. 锁优化与对象头：区分历史模型和现代结论

在较早 HotSpot 教材中，经常看到：

```text
无锁 -> 偏向锁 -> 轻量级锁 -> 重量级锁
```

其中对象头中的 Mark Word 会被用于承载哈希、锁记录指针或 monitor 关联信息；短期低竞争时可尝试避免立即挂起线程，竞争加剧时再膨胀到 monitor。

但将这条路径原样背成所有当前 JDK 的固定事实并不准确：偏向锁已经在较新的 JDK 中退出默认运行路径。面试和工程分析中更稳妥的表达是：

- `synchronized` 由 JVM monitor 语义保证正确性。
- HotSpot 会根据实现版本和竞争情况做锁消除、自旋、轻量级锁与 monitor 膨胀等优化。
- 这些优化不改变程序依赖的互斥与 happens-before 语义，应用代码不应依赖某一种对象头状态。

### 10. CAS 与原子类：无锁更新也有边界

CAS（compare-and-set）可以概括为：

```text
如果当前位置仍然等于预期旧值 A，就原子地替换为新值 B；否则失败。
```

`AtomicInteger.incrementAndGet()` 可以在不建立互斥临界区的情况下，对单变量进行原子更新。CAS 适合竞争可控、更新逻辑较短的状态，例如计数或状态切换。

它并非银弹：

| 问题 | 说明 | 常见处理 |
| --- | --- | --- |
| 高竞争自旋 | 失败后不断重试会消耗 CPU | 降低共享热点、分段累加、改用阻塞同步 |
| ABA | 值从 A 变 B 又变 A，CAS 只看当前值无法发现过程 | `AtomicStampedReference` 等携带版本标记 |
| 多字段不变量 | 多个字段必须共同成功，单字段 CAS 难表达 | 锁、不可变快照或原子引用整体替换 |

第 4 课中的 AQS 便利用 `volatile state` 与 CAS 尝试更新同步状态；获取失败时再将线程排队和挂起，而不是让所有竞争者无限自旋。

### 11. 死锁：不是“线程慢”，而是等待环无法自行解除

死锁同时需要四个条件：

1. 资源互斥。
2. 线程持有一个资源并继续等待另一个资源。
3. 已持有的资源不能被强行剥夺。
4. 等待关系形成环。

下面的获取顺序就可能形成环：

```java
synchronized (accountA) {
    synchronized (accountB) {
        transfer();
    }
}
```

如果另一线程反向先锁 `accountB` 再锁 `accountA`，两个线程都可能无法前进。常见防线包括：

- 全局规定加锁顺序，例如始终按账户 ID 从小到大获取。
- 减小同时持有多把锁的范围。
- 需要失败退出时，使用 `tryLock` 超时并在失败后释放已持资源。
- 排障时分析线程转储中的锁等待环，而不是只调大线程池。

### 12. 面试表达模板

> JMM 定义线程间观察共享读写的规则，核心问题是原子性、可见性和有序性，推理工具是 `happens-before`。`volatile` 写与后续读形成可见性和顺序保证，适合状态发布，但不让 `i++` 这类复合修改原子化。`synchronized` 通过同一 monitor 的互斥保护临界区，其解锁与后续加锁也建立 happens-before；竞争 monitor 的线程是 `BLOCKED`，调用 `wait()` 则释放 monitor 进入等待，通知后还要重抢锁。CAS/原子类适合单状态无锁更新，但有自旋、ABA 与多字段一致性边界。需要可中断、限时、公平或多条件等待时可选基于 AQS 的 `ReentrantLock`。

## 小结（3-5 条关键点）

1. 共享状态的正确性要分别检查原子性、可见性、有序性，并找出 happens-before 路径。
2. `volatile` 负责发布和顺序边界，不负责复合写操作原子性。
3. `synchronized` 同时提供 monitor 互斥和跨临界区的内存可见性；`wait()` 必须围绕条件循环使用。
4. Java 公开线程状态只有六种，monitor 竞争的 `BLOCKED` 与主动等待的 `WAITING` 语义不同。
5. CAS、显式锁、线程池和死锁治理都是选择合适并发协议，而不是互相替代的万能解法。

## 问题（检测你对当前章节内容是否了解）

1. 为什么 `volatile int count` 仍不能安全支持多个线程执行 `count++`？
2. 双重检查单例中，内层 `synchronized` 已存在时，`volatile` 解决的是哪条锁外读路径的问题？
3. 一个线程调用 `lock.wait()` 后，锁与线程状态分别发生什么变化？
4. `ReentrantLock` 等锁竞争失败的线程为什么未必表现为 `BLOCKED`？
5. CAS 的 ABA 问题和死锁问题分别属于哪一种失败机制？
