# 06 实战：限流器（Rate Limiter）

限流器是 machine coding 里**并发类**题的代表。它的代码量很小（核心就一个 `allowRequest`），但考点极其集中：**多线程下「读令牌 → 判断 → 扣减」这个复合操作怎么保证线程安全、锁加在什么粒度、能不能无锁**。算法（令牌桶/滑窗）本身是策略，真正拉开差距的是并发处理和「惰性补充」这种工程巧思。这一章把并发当主角讲透。

> 读法同前：每步拆 **🤔 自问 / 🔀 岔路 / 💬 说出口**。这一章的 driver 尤其重要——并发安全不是嘴上说说，要**真的用多线程压出来证明**。

---

## 第 1 步：需求澄清 —— 一个方法定生死

**🤔 自问**：「设计一个限流器」。它对外其实只有一个动作：**给定一个请求，放行还是拒绝**。`boolean allowRequest(clientId)`。整道题都绕着这一个方法转。先把它周围的变量问清楚。

**🔀 岔路：问哪几个结构性问题？**

| 要问的 | 改变什么结构 |
| --- | --- |
| 限流粒度？全局一个限额，还是**每个 client/API key 独立**？ | 决定要不要 `Map<clientId, 限流器>` |
| 限流规则长什么样？「每秒 N 个」？「每分钟 N 个」？ | 决定配置（容量、速率、窗口） |
| 用哪种算法，还是要**可替换**？ | 决定要不要抽策略（令牌桶/滑窗/固定窗口） |
| 超限了是**拒绝**（返回 false）还是**排队等待**？ | MVP 选拒绝；排队是另一套（阻塞/超时） |
| **并发吗？** | 这题答案永远是「是」——**这就是考点本身** |
| 单机还是分布式？ | MVP 单机内存；分布式（Redis）作为扩展 |

**🔀 岔路（最该主动挑明的两件事）**：

1. **「这一定是并发的。」** 限流器天生跑在 API 网关里，无数请求线程同时调 `allowRequest`。所以我从一开始就把线程安全当**第一性需求**，而不是事后补。
2. **单机 vs 分布式。** machine coding 是单进程内存题，我做**单机内存版**；但我会主动说出「跨多台服务器怎么办」——那需要把状态挪到 Redis 并用原子操作（Lua / `INCR`+过期）。这句话能直接把这道题的天花板顶到系统设计层面。

**💬 说出口**：「核心就一个 `allowRequest(clientId)`，每个 client 独立限额。我把令牌桶和滑动窗口做成可替换的算法，超限直接拒绝。**这道题我从一开始就按多线程并发来设计**——限流器本来就跑在高并发入口。我先做单机内存版；分布式版我最后讲怎么用 Redis 原子操作扩展。可以吗？」

```
In scope :
  - allowRequest(clientId) → true 放行 / false 拒绝
  - 每 client 独立限额；算法可替换（令牌桶 / 滑动窗口日志）
  - 线程安全：高并发下计数/令牌不能算错
Out of scope :
  - 超限排队/阻塞、分布式（Redis）、动态改配置、限流维度组合
Assume :
  - 时间可注入（用 TimeProvider），保证可测试 & 可演示，不依赖真实 sleep
  - 超限即拒绝
扩展（被问到再做）：
  - 分布式：状态移到 Redis + Lua 原子脚本；固定窗口的边界突刺问题 → 滑动窗口计数
```

**🔀 岔路（呼应第 3 章的「注入时间」）**：限流强依赖「现在几点」。如果代码里到处 `System.currentTimeMillis()`，演示「令牌过 1 秒补充」就得真 `sleep`，又慢又不确定。我把时间抽成 `TimeProvider` **注入**进去——demo 里用假时钟手动拨时间，确定性、秒级演示。这是 03 学过的「时间作为依赖注入」在并发题里的再次应用。

---

## 第 2 步：名词 → 类 —— 关键是「每 client 的状态放哪」

**🤔 自问**：名词有 **限流器、客户端、请求、令牌桶、窗口、配置、时间**。建什么？

- **接口**：`RateLimiter`（代表**单个 client 的限流器**，有状态：令牌数 / 时间戳队列）
- **实现**：`TokenBucketRateLimiter`、`SlidingWindowLogRateLimiter`
- **门面**：`RateLimiterService`（管所有 client）
- **工具**：`TimeProvider`（可注入时间）

**🔀 岔路（这题的建模核心）：每个 client 的状态（令牌、时间戳）放在哪？** 两种设计：

| 设计 | 长相 | 评价 |
| --- | --- | --- |
| A：策略无状态，门面持有所有状态 | 门面存 `Map<clientId, State>`，把 State 传进无状态算法方法 | State 结构随算法变（令牌桶要令牌数、滑窗要时间戳队列），门面得知道每种算法的内部结构，耦合重 |
| **B：每个 client 一个有状态的限流器实例** | 门面存 `Map<clientId, RateLimiter>`，每个实例**自己封装自己的状态和线程安全** | 算法的状态和锁都内聚在自己类里，门面完全不关心。✅ |

选 B。这个选择的妙处：**线程安全的边界天然落在「单个 client 的限流器实例」上**——锁 `this` 就只锁住「同一个 client 的并发请求」，不同 client 之间零竞争。这一点第 6 步还会展开，但建模时就定下来了。

**🔀 岔路：每个 client 的限流器实例谁来造？** 因为每个新 client 都要一个**全新的、带独立状态**的实例，这正是**工厂**的活：`RateLimiterFactory`。把「用哪种算法」编码进工厂——传令牌桶工厂就是令牌桶，传滑窗工厂就是滑窗。换算法 = 换工厂，门面一行不改（OCP）。

```java
public interface TimeProvider { long nowMillis(); }

public class SystemTimeProvider implements TimeProvider {
    @Override public long nowMillis() { return System.currentTimeMillis(); }
}
```

```java
// 单个 client 的限流器：有状态，自己负责自己的线程安全
public interface RateLimiter {
    boolean allowRequest();
}

// 每个新 client 造一个全新实例；"用哪种算法"由工厂决定
public interface RateLimiterFactory {
    RateLimiter create();
}
```

---

## 第 3 步：动词 → 方法归属

**🤔 自问**：动词有 **判断放行、补充令牌、清理过期记录、按 client 路由**。各归谁？

- **补充令牌 / 清理过期记录**：是某个算法**内部**的事 → 放各 `RateLimiter` 实现的私有方法（`refill()` / 清理逻辑）
- **判断放行**：`RateLimiter.allowRequest()` 自己
- **按 clientId 找到对应限流器 + 没有就新建**：跨 client 的路由 → `RateLimiterService` 门面

**🔀 岔路（God class 悬崖）**：别让 `RateLimiterService` 既管路由、又内联令牌桶公式、又内联滑窗清理。门面**只路由**：拿 clientId 找/建限流器，调它的 `allowRequest`。算法细节全在各算法类里。

**💬 说出口**：「门面只做『按 clientId 路由到对应限流器』，每个限流器自己管自己的令牌补充、过期清理和线程安全。算法逻辑不外泄到门面。」

---

## 第 4 步：找变化点 → 抽策略（算法）—— 顺带想清楚每个算法的取舍

**🤔 自问**：变化点是谁？**限流算法**——令牌桶 / 漏桶 / 固定窗口 / 滑动窗口日志 / 滑动窗口计数。能说出一堆变体 ✅ → `RateLimiter` 接口本身就是策略，每个算法一个实现。

### 算法 1：令牌桶（最常用，平滑突发）

**🤔 自问（关键巧思）：令牌每秒补充，是不是要起个后台线程定时加？** 不要！起线程给每个 client 加令牌，成本爆炸还难管理。**惰性补充**：不主动加，而是在每次 `allowRequest` 时，**按『距上次的流逝时间 × 速率』一次性算出该补多少**。无需任何后台线程。这是令牌桶实现的点睛之笔。

```java
public class TokenBucketRateLimiter implements RateLimiter {
    private final long capacity;              // 桶容量（也是突发上限）
    private final double refillPerMilli;      // 每毫秒补充的令牌数
    private final TimeProvider time;
    private double tokens;                     // 当前令牌（用 double 容纳小数补充）
    private long lastRefillMillis;

    public TokenBucketRateLimiter(long capacity, double refillPerSecond, TimeProvider time) {
        this.capacity = capacity;
        this.refillPerMilli = refillPerSecond / 1000.0;
        this.time = time;
        this.tokens = capacity;                // 初始装满
        this.lastRefillMillis = time.nowMillis();
    }

    @Override
    public synchronized boolean allowRequest() {   // ← 补充+判断+扣减 是复合操作，必须同步
        refill();
        if (tokens >= 1.0) { tokens -= 1.0; return true; }
        return false;
    }

    private void refill() {                         // 惰性补充：不需要后台线程
        long now = time.nowMillis();
        double add = (now - lastRefillMillis) * refillPerMilli;
        if (add > 0) {
            tokens = Math.min(capacity, tokens + add);   // 不超过容量
            lastRefillMillis = now;
        }
    }
}
```

### 算法 2：滑动窗口日志（精确，但费内存）

**🤔 自问：固定窗口（每分钟清零计数）有什么毛病？** 有**边界突刺**：限「每分钟 100」，如果 0:59 来 100 个、1:01 又来 100 个，相邻 2 秒内放了 200 个——窗口一翻页计数清零导致的。**滑动窗口日志**用「记下每个请求的时间戳、只数最近一个窗口内的」根治它，代价是要存时间戳（每 client O(max) 内存）。

```java
public class SlidingWindowLogRateLimiter implements RateLimiter {
    private final int maxRequests;
    private final long windowMillis;
    private final TimeProvider time;
    private final Deque<Long> timestamps = new ArrayDeque<>();   // 窗口内的请求时间戳

    public SlidingWindowLogRateLimiter(int maxRequests, long windowMillis, TimeProvider time) {
        this.maxRequests = maxRequests; this.windowMillis = windowMillis; this.time = time;
    }

    @Override
    public synchronized boolean allowRequest() {
        long now = time.nowMillis();
        long boundary = now - windowMillis;
        while (!timestamps.isEmpty() && timestamps.peekFirst() <= boundary)
            timestamps.pollFirst();                 // 把滑出窗口的旧时间戳清掉
        if (timestamps.size() < maxRequests) {
            timestamps.addLast(now);
            return true;
        }
        return false;
    }
}
```

**💬 说出口**：「我实现两个：令牌桶用**惰性补充**（无需后台线程），它能平滑突发；滑动窗口日志精确、能避免固定窗口的边界突刺，代价是存时间戳更费内存。两者都实现 `RateLimiter` 接口，换算法只换工厂。固定窗口我会提一下它的边界突刺问题作为对比。」

---

## 第 5 步：门面 API —— 并发的第一道关卡就在这里

**🤔 自问**：门面 `allowRequest(clientId)` 内部要「按 clientId 找限流器，没有就新建」。**这一步本身就有并发问题**：两个线程同时为新 client X 调用，会不会各建一个实例、互相覆盖？

**🔀 岔路：怎么原子地『取或建』？**

- 普通 `HashMap` + `if (!containsKey) put`：典型 check-then-act 竞态，会重复建、丢状态。否
- `ConcurrentHashMap.computeIfAbsent`：**原子**的「不存在才建」，并发安全且只建一次。✅

```java
public class RateLimiterService {
    private final ConcurrentHashMap<String, RateLimiter> limiters = new ConcurrentHashMap<>();
    private final RateLimiterFactory factory;

    public RateLimiterService(RateLimiterFactory factory) { this.factory = factory; }

    public boolean allowRequest(String clientId) {
        // computeIfAbsent：原子取或建，杜绝并发重复创建
        RateLimiter limiter = limiters.computeIfAbsent(clientId, id -> factory.create());
        return limiter.allowRequest();
    }
}
```

**💬 说出口**：「门面这层的并发点是『为新 client 建限流器』，我用 `ConcurrentHashMap.computeIfAbsent` 保证原子取或建，不会并发重复创建。」

---

## 第 6 步：并发深挖 —— 这一章的真正考点

前面的 `synchronized` 和 `computeIfAbsent` 已经把功能写对了。但面试官在并发题里一定会往下追，把下面这几层想清楚、说出来，才是这道题的得分核心。

**🤔 自问 1：`allowRequest` 里到底什么必须同步？为什么？** `refill()` 读改 `tokens`/`lastRefill`，接着「判断 tokens≥1 再扣减」——这是经典的 **check-then-act**。不同步的话：两个线程同时看到 `tokens==1`，都判断通过、都扣减，放过了 2 个但只该放 1 个。所以「补充+判断+扣减」整段必须在一个临界区里。

**🤔 自问 2（锁粒度，最容易被追问）：锁加在哪？会不会所有请求串行？** 不会——而且这正是第 2 步「每 client 一个实例」的回报：

- 我 `synchronized` 的是**每个 `TokenBucketRateLimiter` 实例自己**（锁 `this`）
- 所以**只有同一个 client 的并发请求**会互斥；**不同 client 走不同实例、不同锁，完全并行**
- 没有全局大锁 → 没有跨 client 的伪竞争。这是「细粒度锁」的典型正确姿势

**🔀 岔路 3：能不能无锁（CAS）？** 能讨论，但要诚实：

- 令牌桶有**两个耦合字段**（`tokens` 和 `lastRefillMillis`），纯 `AtomicLong` CAS 很难一次原子更新两个；要么打包进一个 `long`/用 `AtomicReference<不可变状态对象>` + CAS 重试循环，复杂度陡增
- 而锁本来就是 **per-client** 的，竞争只发生在「同一 client 高并发」——这种场景下 `synchronized` 的开销完全可接受
- **结论：MVP 用 `synchronized`，清晰且正确；无锁是真有单 client 极高并发热点时才考虑的优化。** 主动讲出这个权衡，比硬写一个有 bug 的 CAS 强得多

**🔀 岔路 4：分布式怎么办？** 单机内存版的状态在 JVM 里，多台网关各算各的，限额会被放大 N 倍。扩展方案：

- 状态移到 **Redis**，用 **Lua 脚本**把「读计数 → 判断 → 自增/扣减」做成一次**原子**执行（Redis 单线程执行 Lua，天然互斥）
- 令牌桶可用 `INCR` + `EXPIRE` 或 Redis 的 `CL.THROTTLE`（RedisCell 模块）
- 这就从「单机线程安全」升级成「分布式一致性」——**和你笔记里的系统设计专题接上了**

**💬 说出口**：「同步的是每个限流器实例自己，所以只有同一 client 的并发请求互斥，不同 client 完全并行——没有全局锁。无锁 CAS 这里不划算，因为令牌桶有两个耦合字段、且竞争本就是 per-client 的。要做分布式，我会把状态放 Redis 用 Lua 脚本保证『读-判断-改』原子。」

---

## 第 7 步：Driver —— 并发安全要「压」出来，不是嘴上说

**🤔 自问**：我要证明两件事，且**第二件必须用多线程真压**：①令牌桶限额 + 惰性补充对（用假时钟，确定性）；②**高并发下不超发**（线程安全的硬证据）。

```java
public class Driver {
    public static void main(String[] args) throws InterruptedException {
        // ① 令牌补充演示：容量 5、每秒补 1，用假时钟拨时间，无需真 sleep
        FakeTimeProvider clock = new FakeTimeProvider();
        RateLimiter bucket = new TokenBucketRateLimiter(5, 1.0, clock);
        int pass = 0;
        for (int i = 0; i < 8; i++) if (bucket.allowRequest()) pass++;
        System.out.println("t=0 连发 8 次，通过 = " + pass);     // 期望 5（桶里 5 个令牌）
        clock.advance(3000);                                    // 拨快 3 秒 → 补 3 个令牌
        pass = 0;
        for (int i = 0; i < 8; i++) if (bucket.allowRequest()) pass++;
        System.out.println("t=3s 再连发 8 次，通过 = " + pass);   // 期望 3

        // ② 并发安全硬证据：50 个令牌，200 线程在同一瞬间抢，结果必须恰好 50
        FakeTimeProvider clock2 = new FakeTimeProvider();
        RateLimiterService svc = new RateLimiterService(() -> new TokenBucketRateLimiter(50, 1.0, clock2));
        int threads = 200;
        AtomicInteger allowed = new AtomicInteger();
        ExecutorService pool = Executors.newFixedThreadPool(threads);
        CountDownLatch start = new CountDownLatch(1);           // 起跑线：让所有线程同一刻冲，放大竞态
        CountDownLatch done  = new CountDownLatch(threads);
        for (int i = 0; i < threads; i++) {
            pool.submit(() -> {
                try { start.await(); if (svc.allowRequest("userX")) allowed.incrementAndGet(); }
                catch (InterruptedException ignored) {}
                finally { done.countDown(); }
            });
        }
        start.countDown();                                      // 发令
        done.await();
        pool.shutdown();
        System.out.println("200 线程并发抢 50 令牌，通过 = " + allowed.get()); // 必须恰好 50

        // ③ 边界：不同 client 互不影响
        RateLimiterService svc2 = new RateLimiterService(() -> new TokenBucketRateLimiter(2, 1.0, new FakeTimeProvider()));
        System.out.println("A: " + svc2.allowRequest("A") + svc2.allowRequest("A") + svc2.allowRequest("A")); // truetrue false
        System.out.println("B: " + svc2.allowRequest("B"));     // B 独立，仍 true
    }

    static class FakeTimeProvider implements TimeProvider {     // 可拨动的假时钟
        private final AtomicLong millis = new AtomicLong(0);
        public long nowMillis() { return millis.get(); }
        public void advance(long ms) { millis.addAndGet(ms); }
    }
}
```

**💬 说出口（这段话是并发题的高分点）**：「光说『我加了 synchronized』不够。我用 `CountDownLatch` 做起跑线，让 200 个线程在同一瞬间抢 50 个令牌——这样最大化竞态窗口；如果线程不安全，通过数会 >50。跑出来恰好 50，才算证明了线程安全。」

跑通它，你交出的是：**正确的令牌桶/滑窗算法、可换算法、惰性补充无后台线程、细粒度 per-client 锁、用多线程压测证明的线程安全、注入时钟的确定性演示**——并发这栏拿满，还附带了分布式的扩展视野。

> 全部类放进一个包/文件即可编译；`import java.util.*; java.util.concurrent.*; java.util.concurrent.atomic.*;`。

---

## 这道题的设计模式地图

| 模式 | 落在哪 | 哪一步想出来的 |
| --- | --- | --- |
| **策略 Strategy** | `RateLimiter`（令牌桶/滑窗） | 第 4 步：算法多变体 |
| **工厂 Factory** | `RateLimiterFactory` 按 client 造实例 | 第 2 步：每 client 要独立状态实例，换算法=换工厂 |
| **门面 Facade** | `RateLimiterService` | 第 3 步：按 client 路由 |
| **依赖注入** | `TimeProvider` 注入 | 第 1 步：可测试 & 可演示 |

---

## 常见追问与应答

- **「`allowRequest` 为什么要 synchronized？」** → 补充+判断+扣减是 check-then-act 复合操作；不同步会两个线程同时看到剩 1 个令牌都放行，超发
- **「会不会所有请求串行、成为瓶颈？」** → 不会，锁的是**每个 client 自己的实例**，只有同一 client 的并发请求互斥，不同 client 完全并行（第 6 步）
- **「能做成无锁吗？」** → 令牌桶两个耦合字段，纯 CAS 复杂且易错；锁本就是 per-client 的，`synchronized` 足够。真有单 client 热点才考虑 `AtomicReference<状态>` + CAS 循环
- **「固定窗口和滑动窗口区别？」** → 固定窗口有边界突刺（窗口翻页计数清零，相邻两窗口边缘可放 2 倍）；滑动窗口日志精确但费内存；滑动窗口计数是二者折中
- **「多台服务器怎么共享限额？」** → 状态移到 Redis + Lua 原子脚本（读-判断-改一次执行），或 RedisCell；从线程安全升级成分布式一致性
- **「换成漏桶 / 滑动窗口计数？」** → 新增一个 `RateLimiter` 实现 + 对应工厂，门面不动（OCP）

---

## 检查站

1. 第 1 步你为什么把「线程安全」当成第一性需求，而不是写完功能再补？为什么坚持把时间做成可注入的 `TimeProvider`？
2. 每个 client 的状态，你为什么选「每 client 一个有状态的限流器实例」而不是「门面持有所有状态、策略无状态」？这个选择对**锁粒度**意味着什么？
3. 令牌桶的「惰性补充」是什么意思？它避免了什么（提示：后台线程）？
4. `allowRequest` 里到底哪几步构成 check-then-act？不加锁会出现什么具体错误？
5. 你 `synchronized` 的是什么对象？为什么这能做到「同一 client 互斥、不同 client 并行」？
6. driver 里为什么要用 `CountDownLatch` 做起跑线？它在证明什么、怎么证明？光写「我加了锁」为什么不够？
7. 要支持多台网关共享同一份限额，单机内存版会出什么问题？你怎么扩展？

下一章 `07` 不再是新题，而是**反模式与时间管理复盘**——把 03～06 跑过的题提炼成一张「失分点 + 救场」checklist，外加「写到一半发现时间不够怎么砍」的实战预案，帮你把这套方法论真正稳定输出。
