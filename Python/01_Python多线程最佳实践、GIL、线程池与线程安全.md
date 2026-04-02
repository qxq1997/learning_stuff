# Python - 第 1 课：Python 多线程最佳实践、GIL、线程池与线程安全

## 学习目标（本节结束后你能做到什么）

- 理解为什么 Python 明明有线程，但很多人仍然说“CPU 密集型别指望多线程加速”。
- 知道 GIL 对 CPython 多线程的真实影响。
- 能根据任务类型判断何时用线程、何时用多进程、何时考虑 `asyncio`。
- 理解为什么工程实践里更推荐 `ThreadPoolExecutor` 而不是大量裸 `threading.Thread`。
- 知道多线程程序里共享状态、异常处理、退出机制、日志这些工程要点。

## 内容讲解（核心概念，用类比、例子、图示说清楚）

### 1. 先给一个最实用的结论

Python 多线程不是不能用，而是要分场景。

如果你现在只想先记住一句话，那就是：

**I/O 密集型任务适合多线程，CPU 密集型任务通常不适合。**

这几乎就是 Python 多线程最佳实践的起点。

### 2. 为什么会有这个结论：先看 GIL

如果你说的是最常见的 CPython，那么它有一个非常关键的机制：GIL，也就是全局解释器锁。

你先不用死抠定义，先记住它带来的直观结果：

**同一个进程里的多个 Python 线程，很多时候不能真正同时执行 Python 字节码。**

也就是说：

- 你可以开很多线程
- 线程确实都存在
- 但对纯 Python 计算来说，很多时候同一时刻只有一个线程在真正跑 Python 代码

这就是为什么 Python 线程的价值判断必须看任务类型。

### 3. CPU 密集型为什么通常不适合 Python 多线程

所谓 CPU 密集型，就是任务主要花时间在计算上，比如：

- 大量数学计算
- 大规模纯 Python 循环
- 复杂 JSON 处理后又做很多计算
- 图像逐像素处理

在这种场景里，多线程通常不会明显加速，甚至可能更慢。原因有两个：

- GIL 让很多纯 Python 计算线程本质上是在轮流跑
- 线程切换本身也有额外开销

于是结果就变成：

- 线程没少开
- CPU 没真并行起来
- 反而增加了切换和管理成本

所以纯 CPU 密集场景更常见的建议是：

- 用 `multiprocessing`
- 或用 `ProcessPoolExecutor`
- 或把重计算放到 NumPy、C 扩展、Numba、Cython 等能绕开纯 Python 解释执行瓶颈的方案里

### 4. I/O 密集型为什么很适合多线程

I/O 密集型任务的特点是：大量时间花在“等”上，而不是算上。

例如：

- 并发请求 HTTP 接口
- 查数据库
- 读写文件
- 调 Redis
- 调第三方 API
- socket 网络通信

这类场景下，多线程非常有价值。因为线程在等待 I/O 时，解释器通常会释放 GIL，让别的线程去跑。

这意味着：

- 线程 A 在等网络返回
- 线程 B 可以趁机继续执行
- 多个等待时间能被重叠起来

所以 Python 多线程真正擅长的战场，是 I/O 并发，而不是纯 CPU 并行。

### 5. 最佳实践第一条：先判断任务类型

这是所有后续选择的前提。

#### 5.1 I/O 密集型

优先考虑多线程。

典型例子：

- 爬虫抓多个网页
- 并发请求多个接口
- 同时下载多个文件
- 大量磁盘或网络等待

这类场景最推荐的工具通常是：

- `concurrent.futures.ThreadPoolExecutor`

#### 5.2 CPU 密集型

优先考虑多进程。

典型例子：

- 批量计算
- 大规模数据变换
- 纯 Python 重计算

这时更适合：

- `multiprocessing`
- `concurrent.futures.ProcessPoolExecutor`

### 6. 最佳实践第二条：优先用线程池，不要随手乱开线程

很多人初学时会这样写：

```python
import threading

for _ in range(1000):
    t = threading.Thread(target=do_work)
    t.start()
```

这种写法 demo 里没问题，但工程上通常不够好。原因包括：

- 线程创建有成本
- 线程太多会抢资源
- 不方便统一限制并发度
- 生命周期管理麻烦
- 异常收集和回收也更难做

所以更推荐：

**用线程池复用线程，并控制并发度。**

### 7. 为什么 `ThreadPoolExecutor` 很适合工程实践

推荐写法大概是这样：

```python
from concurrent.futures import ThreadPoolExecutor

def fetch(url):
    return f"done: {url}"

urls = ["a.com", "b.com", "c.com"]

with ThreadPoolExecutor(max_workers=10) as executor:
    results = list(executor.map(fetch, urls))
```

它的优点很直接：

- 线程数可控
- 线程自动复用
- `with` 结束时自动清理
- API 相对统一，和 `ProcessPoolExecutor` 思路也接近

所以如果你问一个很务实的建议，我会说：

**Python 多线程实战里，`ThreadPoolExecutor` 基本是主角。**

### 8. 最佳实践第三条：线程数不要乱配

很多人会问：

`max_workers` 设多少合适？

没有绝对值，但有一个很重要的认知：

#### 8.1 I/O 密集型线程池

线程数可以比 CPU 核数大很多，因为大量时间在等待 I/O。

例如：

- 8 核机器开 20、50 个线程都可能合理

但这不等于可以无限大。因为线程太多仍然会带来：

- 上下文切换开销
- 内存占用增长
- 下游被打爆
- 请求超时和队列堆积

#### 8.2 CPU 密集型

线程数再多通常也没有本质帮助，因为问题不是线程不够，而是 GIL 和 CPU 竞争模型不对。

这种场景更应该切换思路，而不是盲目加线程。

#### 8.3 真正的工程做法

从一个保守值开始，结合压测、超时、下游承载能力再调。

不要把线程池当成“无限并发机器”。

### 9. 最佳实践第四条：共享状态越少越好

多线程最麻烦的通常不是“怎么开线程”，而是：

**多个线程同时改同一份数据怎么办。**

例如：

```python
counter = 0
```

多个线程同时做：

```python
counter += 1
```

结果不一定正确，因为这不是原子操作。

这里有两个层次的正确思路。

#### 9.1 第一优先级：尽量少共享

这是最好的办法。

例如：

- 每个线程只处理自己的输入
- 最后由主线程统一汇总结果

这比大家一起抢一个全局变量稳得多。

#### 9.2 需要共享时再用锁

```python
import threading

counter = 0
lock = threading.Lock()

def work():
    global counter
    for _ in range(10000):
        with lock:
            counter += 1
```

加锁之后，多个线程不会同时改同一段共享状态。

但更高级的实践是：

**能不共享就不共享，能消息传递就别大家一起改状态。**

### 10. 最佳实践第五条：生产者-消费者优先用 `queue.Queue`

如果你有这种模型：

- 一个线程或一组线程生产任务
- 多个线程消费任务

那就不要自己拿 `list` 硬堆。

更推荐：

```python
import queue
```

因为 `queue.Queue` 天生就是线程安全的，特别适合做线程间任务传递。

典型模式如下：

```python
import threading
import queue
import time

q = queue.Queue()

def worker():
    while True:
        item = q.get()
        if item is None:
            break
        print(f"processing {item}")
        time.sleep(1)
        q.task_done()
```

这个模型特别经典，适合：

- 批量任务处理
- 下载器
- 后台消费
- 异步日志

### 11. 最佳实践第六条：异常处理一定要设计好

线程里的异常如果你不主动处理，主线程通常不会自动优雅替你兜底。

在线程池里比较推荐的模式是显式拿 `future` 并统一处理：

```python
from concurrent.futures import ThreadPoolExecutor, as_completed

def task(x):
    if x == 2:
        raise ValueError("bad input")
    return x * 2

with ThreadPoolExecutor(max_workers=4) as executor:
    futures = [executor.submit(task, i) for i in range(5)]

    for future in as_completed(futures):
        try:
            result = future.result()
            print("result:", result)
        except Exception as e:
            print("error:", e)
```

这样做的好处是：

- 哪个任务失败你知道
- 失败不会悄悄吞掉
- 方便统一日志和告警

### 12. 最佳实践第七条：线程要能优雅退出

裸线程很容易写出这种程序：

- 主线程结束了，子线程还在跑
- 程序卡着不退出
- 或者用 daemon 线程让它粗暴退出，导致收尾不干净

更推荐的做法是：

- 短生命周期任务用线程池和 `with`
- 长生命周期线程显式设计停止信号

例如用 `Event`：

```python
import threading
import time

stop_event = threading.Event()

def worker():
    while not stop_event.is_set():
        print("working...")
        time.sleep(1)
```

这个模式比“写个全局布尔变量随便轮询”更规范。

### 13. 最佳实践第八条：日志带上线程信息

多线程程序调试最烦的事情之一是：

你不知道日志是谁打的。

所以日志格式里最好加线程名：

```python
import logging

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(threadName)s %(levelname)s %(message)s'
)
```

这样后面排查并发问题会轻松很多。

### 14. 最佳实践第九条：别想当然共享全局对象

某些对象未必线程安全，比如：

- 某些数据库连接对象
- 某些 session 封装
- 某些第三方 SDK client
- 某些文件句柄或缓存封装

所以最佳实践是：

- 看官方文档是否线程安全
- 不确定就别多个线程乱共享
- 需要时给每线程独立实例
- 或用连接池管理

### 15. 什么时候该换成 `asyncio` 或多进程

这点一定要有边界感。

#### 15.1 如果是大量 I/O 并发

线程池很好用，但如果连接数非常大、任务模型天然适合异步 I/O，那么很多时候 `asyncio` 更合适。

例如：

- 高并发接口聚合
- 异步 Web 服务
- 大量网络连接

#### 15.2 如果是大量 CPU 运算

优先考虑：

- `multiprocessing`
- `ProcessPoolExecutor`

而不是用 Python 原生多线程硬顶。

### 16. 一个更像生产代码的线程池模板

```python
from concurrent.futures import ThreadPoolExecutor, as_completed
import logging
import requests

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(threadName)s %(levelname)s %(message)s'
)

def fetch(url):
    try:
        resp = requests.get(url, timeout=5)
        resp.raise_for_status()
        return url, resp.status_code
    except Exception:
        logging.exception("fetch failed: %s", url)
        raise

urls = [
    "https://example.com",
    "https://example.org",
]

with ThreadPoolExecutor(max_workers=8) as executor:
    futures = [executor.submit(fetch, url) for url in urls]

    for future in as_completed(futures):
        try:
            url, status = future.result()
            logging.info("success %s %s", url, status)
        except Exception as e:
            logging.error("task failed: %s", e)
```

这个模板背后体现的正是最佳实践：

- 用线程池而不是裸线程
- 控制并发数
- 显式收结果
- 统一处理异常
- 日志里能看到线程信息
- 线程池结束时自动回收

### 17. 常见误区

#### 17.1 “Python 多线程完全没用”

不对。对 I/O 密集型任务非常有用。

#### 17.2 “线程越多越快”

不对。线程太多常常更慢、更乱，还可能打爆下游。

#### 17.3 “有 GIL 就完全不能并发”

也不对。GIL 主要限制很多纯 Python CPU 任务的并行性，不等于 I/O 并发没有价值。

#### 17.4 “用了锁就一定安全”

也不完全对。锁只能保护你锁住的那段逻辑，如果整体共享状态太多，设计仍然会很脆弱。

#### 17.5 “裸线程和线程池差不多”

小 demo 看起来差不多，工程上差很多。线程池在并发控制、生命周期管理和异常处理上都更合适。

### 18. 面试里怎么回答更像样

你可以这样答：

Python 多线程的最佳实践首先取决于任务类型。在 CPython 中，因为 GIL 的存在，多线程更适合 I/O 密集型场景，比如网络请求、文件读写、数据库访问；对于 CPU 密集型任务，通常更推荐多进程。  
在实现上，优先使用 `concurrent.futures.ThreadPoolExecutor`，而不是大量手动创建 `threading.Thread`，因为线程池更方便控制并发度、复用线程、统一管理异常和生命周期。  
在数据共享方面，最佳实践是尽量减少共享状态；必须共享时使用 `Lock` 等同步原语，或者通过 `queue.Queue` 做线程安全的任务传递。  
此外，还应注意线程中的异常处理、日志中的线程标识、线程退出机制，以及不要让线程数无限增长。

## 小结

- CPython 下的 GIL 决定了 Python 多线程更适合 I/O 密集型，而不是纯 CPU 密集型。
- 工程实践里优先考虑 `ThreadPoolExecutor`，不要大量手搓裸线程。
- 线程数要控制，不能把线程池当无限并发机器。
- 共享状态越少越好，必须共享时再配合锁或 `queue.Queue`。
- 异常处理、停止机制、日志线程名这些细节，决定了代码是 demo 还是工程代码。

## 问题（检测你对当前章节内容是否了解）

1. 为什么 Python 的多线程在 I/O 密集型场景下通常很有价值？
2. 为什么纯 CPU 密集型任务通常不推荐 Python 原生多线程？
3. `ThreadPoolExecutor` 相比裸 `threading.Thread` 的工程优势是什么？
4. 为什么说“能不共享就不共享”比“到处加锁”更高级？
5. 在什么情况下你会考虑从线程池切换到 `asyncio` 或多进程？
