# Java 进程现场工具：jps、jstack、jmap、Arthas、async-profiler

## 这一章想解决什么

§02–§04 给的是 OS 层工具——能看到"这个 Java 进程占了多少 CPU / 内存 / IO"。但要回答"**这个 Java 进程为什么这么忙**"，必须进入 JVM 内部，看：

- 哪些线程在烧 CPU、在干什么
- 堆里什么对象多、有没有泄漏
- GC 频率多高、停顿多长、什么 cause
- 慢方法是哪个、入参出参是什么
- 锁竞争发生在哪
- Native 内存被谁吃了

工具上分两代：

- **JDK 自带**：`jps` / `jstat` / `jstack` / `jmap` / `jcmd` / JFR
- **生产神器**：Arthas（运行时观测、热部署）+ async-profiler（火焰图）

JDK 自带工具的基础原理在 [JVM/09](../JVM/09_JVM问题排查工具：jps、jstat、jstack、jmap、jcmd、JConsole与VisualVM.md) 已经详细讲过。这一章**不重复原理**，专注三件事：

1. **每个工具在什么现象下用**——形成"现象 → 工具"的肌肉记忆
2. **生产环境的坑**——`jmap -dump` 会 STW、`jstack` 在某些版本会 hang、Arthas trace 高频方法会拖垮业务
3. **工具协同 SOP**——CPU 高、GC 风暴、接口慢、内存泄漏 四套标准查法

[JVM/11](../JVM/11_线上故障实战：死锁检测、HeapDump与OutOfMemoryError排查.md) 已经把死锁 / HeapDump / OOM 案例串成完整链路，这一章是它的"工具速查 + 协同视角"。

## 一、症状 → 工具地图

| 现象 | 第一道工具 | 配合 |
| --- | --- | --- |
| CPU 飙高 | `top -H -p` + `jstack` | Arthas `thread -n 3`、async-profiler `cpu` |
| GC 频繁 | `jstat -gc <pid> 1s` | GC 日志 + GCeasy、`jcmd GC.class_histogram` |
| 接口慢 / RT 抖动 | Arthas `trace` / `watch` | JFR、async-profiler `wall` |
| 怀疑内存泄漏 | `jmap -histo:live <pid>` | `jmap -dump` → MAT |
| 死锁 | `jstack <pid>` 看末尾 deadlock 段 | Arthas `thread -b` |
| Native / 堆外内存 | `jcmd VM.native_memory` (NMT) | `pmap`、`gdb` |
| 线程数失控 | `jstack` 数 `tid` 数 | Arthas `dashboard` |
| 想热修复一个方法 | Arthas `jad` + `mc` + `redefine` | — |
| 想知道实际生效的 JVM 参数 | `jcmd VM.flags` 或 `jinfo -flags` | — |

新手最容易犯的错：**只会 `jstack`**，遇到接口慢也拉 `jstack`、内存泄漏也拉 `jstack`、GC 慢也拉 `jstack`——但 `jstack` 只能回答"线程现在在干什么"，**回答不了"过去 5 分钟在干什么"**。所以遇到 GC / 慢方法这种"时间序列"问题，**JFR + Arthas + async-profiler 才是主力**，jstack 只是辅助。

## 二、jps：找进程

```bash
jps -l                    # 显示全类名 / jar 路径
jps -lv                   # 加上 JVM 启动参数
jps -lvm                  # 再加上 main 方法参数
```

`jps` 只显示**当前用户**能看到的 JVM，root 用户能看到所有的。容器里 `jps` 可能因为 `/tmp/hsperfdata_<user>` 权限问题失败——直接用 `ps -ef | grep java` 拿 PID 也行。

**容器环境额外的坑**：宿主机的 `jps` 看不到容器里的 PID（PID namespace 隔离），需要 `kubectl exec` 进去或者用宿主机的 PID（`docker inspect` / `ps -ef | grep java`）。

## 三、jstat：GC 实时统计

```bash
jstat -gc <pid> 1000 10           # 每 1 秒一次，10 次
jstat -gcutil <pid> 1000          # 百分比形式（更直观）
jstat -gccause <pid> 1000         # 加上最近一次 GC 的 cause
```

`-gcutil` 输出：

```
$ jstat -gcutil 1234 1000
  S0     S1     E      O      M     CCS    YGC     YGCT    FGC    FGCT     GCT
  0.00  47.32  82.41  68.15  95.20  91.05    2843    78.12     12     8.45    86.57
  0.00  47.32  85.20  68.15  95.20  91.05    2843    78.12     12     8.45    86.57
  ...
```

关键列：

| 列 | 含义 |
| --- | --- |
| `S0` / `S1` | Survivor 区使用率 |
| `E` | Eden 使用率（上涨速度 = 分配速率） |
| `O` | Old 区使用率（涨势 = 晋升压力） |
| `M` | Metaspace 使用率（接近 100% 要警惕 Metaspace OOM） |
| `CCS` | Compressed Class Space |
| `YGC` / `YGCT` | Young GC 累计次数 / 累计耗时（秒） |
| `FGC` / `FGCT` | Full GC 累计次数 / 累计耗时 |
| `GCT` | 总 GC 耗时 |

**线上排障的两个关键观察**：

1. **YGC 频率**：`YGC` 增量 / 时间窗口。比如 1 秒内 YGC 涨了 3 次 = 3 Hz YGC，Eden 太小或分配速率太高
2. **Old 区涨势**：连续观察 `O` 列，从 60% → 65% → 70% 持续涨 → 内存泄漏前兆；涨到 80% 后回落到 30%（一次 FGC）→ 正常水平

**注意 `jstat` 拿数据有时延**——它读 `/tmp/hsperfdata_<user>/<pid>` 这个共享内存文件，**默认每 50ms 更新**（`-XX:PerfDataSamplingInterval`）。极端情况下数据可能"卡住几秒"，看着是 GC 突然恢复其实是采样阻塞。

## 四、jstack：线程栈快照

### 这是什么、什么时候用

`jstack` 把 JVM 当前所有线程的栈打印出来——**瞬时快照，不是历史**。适合：

- CPU 高时定位是哪个线程 / 哪个方法在烧
- 死锁检测（jstack 输出末尾会有 `Found N deadlocks`）
- 怀疑某个线程卡住（看它停在什么调用上）

### 关键细节：jstack 安全吗？

`jstack` 默认要等到 **safepoint**（所有线程到达安全点）才能采。如果某个线程**进不了 safepoint**（典型场景：`while(true)` 死循环里没有调用 / 长循环 JIT 优化后去掉了 safepoint poll），`jstack` 会**长时间挂起**，可能拖几十秒。

应对：

```bash
jstack -F <pid>      # force 模式：用 attach API + ptrace 强制采样
                     # 不需要等 safepoint，但拿到的栈信息不那么准（缺局部变量等）
                     # 紧急情况下用
```

> ⚠️ 优先用 `jstack <pid>`，hang 住了再上 `jstack -F`。`-F` 模式在某些 JDK 版本会让进程挂掉，慎用。

### 解读 jstack 输出

```
"http-nio-8080-exec-12" #143 daemon prio=5 os_prio=0 cpu=12345.67ms ...
   java.lang.Thread.State: BLOCKED (on object monitor)
        at com.example.service.OrderService.create(OrderService.java:42)
        - waiting to lock <0x00000000c5f4e198> (a java.lang.Object)
        at com.example.controller.OrderController.create(OrderController.java:18)
        ...
```

关键字段：

| 字段 | 含义 |
| --- | --- |
| 线程名 | 业务可读名（Tomcat / Dubbo / 自定义线程池命名很重要，否则全是 `pool-1-thread-N`） |
| `nid=0x6e0` | 本地线程 ID（**十六进制**），对应 OS 层的 TID |
| `cpu=...ms` | 该线程累计 CPU 时间（JDK 11+ 才有） |
| `Thread.State` | 状态：`RUNNABLE`（在跑或可跑）/ `BLOCKED`（等锁）/ `WAITING`（无超时等）/ `TIMED_WAITING`（带超时等）/ `NEW` / `TERMINATED` |
| `- locked <0x...>` | 持有这把锁 |
| `- waiting to lock <0x...>` | 在等这把锁 |

**线上排障的两个关键观察**：

1. **大量线程相同的栈，状态 BLOCKED**：锁竞争集中，看 `waiting to lock` 的对象 ID，找到持有者
2. **大量线程 RUNNABLE 但栈停在同一个地方**：可能是死循环（jstack 间隔 5 秒采两次，栈不变 = 卡住）

### TID → 十六进制 → 找到栈

CPU 高排查的标准 SOP（§02 已经铺过）：

```bash
top -H -p <pid>           # 找到 CPU% 高的 TID
printf "%x\n" <tid>       # 转十六进制
jstack <pid> | grep -A 30 "nid=0x<hex>"
```

整合脚本：

```bash
#!/bin/bash
# top_thread.sh <pid>
PID=$1
TIDS=$(top -bn1 -H -p $PID | awk 'NR>7 && $9>50 {print $1}')   # CPU% > 50
jstack $PID > /tmp/jstack.$$
for tid in $TIDS; do
    hex=$(printf "%x\n" $tid)
    echo "===== TID=$tid (0x$hex) ====="
    grep -A 30 "nid=0x$hex " /tmp/jstack.$$
done
```

### 3 次采样的姿势

单次 jstack 是瞬时快照。**3 次相隔 5 秒采样**才能区分"真的卡住"和"瞬间经过"：

```bash
for i in 1 2 3; do
    jstack <pid> > /tmp/jstack.$i.log
    sleep 5
done

# 找三次都在同一个栈的线程（多半是卡住）
```

## 五、jmap：堆 dump 和 histogram

`jmap` 三个常用姿势：

```bash
jmap -heap <pid>                                       # 看堆配置和占用（旧版本可用，新版本推荐 jcmd）
jmap -histo:live <pid> | head -30                      # 类对象数 + 总大小，按大小排序
jmap -dump:live,format=b,file=/tmp/heap.hprof <pid>    # 全堆 dump
```

### jmap -histo:live 是线上排障神器

```
$ jmap -histo:live 1234 | head
 num     #instances         #bytes  class name
   1:       8204135      328165400  [B (java.lang.byte[])
   2:       1830240      131777280  java.util.HashMap$Node
   3:       1820300       58249600  java.lang.String
   4:        924134       29572288  com.example.dto.Order
...
```

`#instances` 实例数、`#bytes` 总字节数、按大小降序。**线上判断内存泄漏的快路径**：

- 隔 5 分钟拉两次 `-histo:live`，对比看哪个类的 `#instances` 一直涨
- 如果某个业务对象（如 `com.example.dto.Order`）实例数持续增长不回落 → 大概率泄漏

⚠️ **注意**：`-histo:live` 加 `live` 会触发一次 **Full GC**（为了只统计活对象）。生产环境业务还在受影响的机器上**慎用 live**——它会把业务停顿几百毫秒到几秒。**故障节点已经摘掉的情况下，放心用**。

不加 `live`（`jmap -histo`）则不触发 GC，但会包含死对象，数据不准。

### jmap -dump 的代价

```bash
jmap -dump:live,format=b,file=/tmp/heap.hprof <pid>
```

**会触发 Full GC + STW**，时长 ≈ 堆大小 × 复杂度。8GB 堆可能停顿 10–30 秒。**所以**：

- 业务还在跑的机器：**不要 dump**，先摘节点
- 故障节点已摘：dump 之前确认磁盘够（hprof 文件大小 ≈ 堆使用量）
- 容器环境：`-file=/tmp/heap.hprof` 写到挂载的 PV，否则 Pod 重启就丢
- JDK 9+ 推荐 `jcmd <pid> GC.heap_dump /tmp/heap.hprof`，行为等价于 jmap，但 jmap 已被标记为 deprecated

### dump 之后用 MAT / jhat 分析

`heap.hprof` 文件用 Eclipse MAT 打开分析。常用视图：

- **Histogram** —— 按类聚合（类似 `jmap -histo`）
- **Dominator Tree** —— 哪些对象 retain 了最多内存
- **Path to GC Roots → exclude weak/soft refs** —— 找泄漏对象为什么没被回收
- **Leak Suspects** —— MAT 自动分析的泄漏嫌疑

详细的 MAT 操作链回 [JVM/11](../JVM/11_线上故障实战：死锁检测、HeapDump与OutOfMemoryError排查.md)。

## 六、jcmd：现代瑞士军刀

JDK 7+ 内置，**未来会逐步取代 `jstack` / `jmap` / `jinfo`**。常用：

```bash
jcmd                                       # 列出所有 JVM PID
jcmd <pid> help                            # 看这个 JVM 支持的所有命令
jcmd <pid> VM.version                      # 版本
jcmd <pid> VM.flags                        # 当前生效的 JVM 参数
jcmd <pid> VM.system_properties            # 系统属性
jcmd <pid> Thread.print                    # 等价于 jstack
jcmd <pid> GC.heap_info                    # 堆信息
jcmd <pid> GC.class_histogram              # 等价于 jmap -histo
jcmd <pid> GC.heap_dump /tmp/heap.hprof    # 等价于 jmap -dump
jcmd <pid> GC.run                          # 显式触发 Full GC（调试用，生产慎用）
jcmd <pid> VM.native_memory summary        # NMT 概要
jcmd <pid> VM.native_memory baseline       # NMT 基线
jcmd <pid> VM.native_memory summary.diff   # NMT 差分（最关键的 Native 内存排查姿势）
jcmd <pid> JFR.start duration=60s filename=/tmp/recording.jfr   # 开始 JFR 录制
jcmd <pid> Compiler.codecache              # 看 JIT 代码缓存使用情况
```

`jcmd` 比 `jstack` / `jmap` 更新更稳，**线上脚本里建议优先用 `jcmd`**。

### NMT (Native Memory Tracking)

排查"堆没满但进程内存涨"的核心工具。**前提**：进程启动时加了 `-XX:NativeMemoryTracking=summary`（或 `detail`）。

```bash
jcmd <pid> VM.native_memory summary
```

输出（节选）：

```
Native Memory Tracking:

Total: reserved=8421376KB, committed=4218304KB
-                 Java Heap (reserved=4194304KB, committed=2097152KB)
-                     Class (reserved=1075840KB, committed=15040KB)
-                    Thread (reserved=156672KB, committed=156672KB)
-                      Code (reserved=247808KB, committed=15936KB)
-                        GC (reserved=189440KB, committed=189440KB)
-                  Internal (reserved=1024KB, committed=1024KB)
-                    Symbol (reserved=12288KB, committed=12288KB)
-    Native Memory Tracking (reserved=2240KB, committed=2240KB)
```

判断要点：

- **`Java Heap`** = 堆，对应 `-Xmx` 设的值
- **`Thread`** 大 = 线程数多 × 每线程栈大小（默认 1MB）
- **`Code`** 持续涨 = JIT 代码缓存膨胀，调 `-XX:ReservedCodeCacheSize`
- **`Class`** 持续涨 = 类加载没卸载（CGLIB / Groovy 动态生成大量类）
- **`Internal`** + 业务总和远小于 RSS = 内存被**非 JVM 管理的 native 库**吃了（Netty DirectByteBuffer、JNI、glibc malloc 不还）

`VM.native_memory baseline` + `VM.native_memory summary.diff` 拉两次差分，看哪一类涨得最快——这是 Native 内存排查的"jstat-for-native"。

详细 Native 内存排障思路链回 [JVM/15](../JVM/15_CMS常见问题（下）：收集器退化、堆外内存OOM与JNI问题.md) 和 [JVM/20](../JVM/20_线上JVM调优案例拆解：接口GAP大、特殊OOM、Native内存与YGC暴涨.md)。

## 七、JFR (Java Flight Recorder)

JDK 11+ 默认内置（OracleJDK 8 也有，OpenJDK 8 从 8u262+ backport）。**这是回答"过去 5 分钟发生了什么"的唯一标准工具**。

### 为什么 JFR 重要

`jstack` / `jstat` 都是**瞬时**的——你拉的时候才有数据。但线上故障经常是"刚才出问题，现在恢复了"，事后 jstack 啥也看不到。

JFR 是**持续低开销采样**（默认开销 < 1%），把 GC、方法调用、IO、锁竞争、异常这些事件流持续记录，事后用 JMC（Java Mission Control）可视化分析。

### 怎么用

**方式 1：业务进程已经在跑，临时开**：

```bash
jcmd <pid> JFR.start duration=60s filename=/tmp/recording.jfr
# 60 秒后自动结束并写文件

# 或者
jcmd <pid> JFR.start name=continuous maxsize=500m maxage=1h
# 持续记录，环形缓冲 500M / 1 小时

# 主动 dump 当前缓冲
jcmd <pid> JFR.dump name=continuous filename=/tmp/snapshot.jfr

# 停止
jcmd <pid> JFR.stop name=continuous
```

**方式 2：启动时配置**：

```
-XX:+UnlockCommercialFeatures   # JDK 8u262 之前 OracleJDK 需要
-XX:+FlightRecorder
-XX:StartFlightRecording=duration=60s,filename=/tmp/jfr.jfr
```

**生产建议**：开 `continuous` 模式，环形缓冲 1 小时，**故障后立刻 dump**——这样故障前的 1 小时数据全有，是事后复盘的金矿。

### 怎么看 jfr 文件

下载到本地，用 **JDK Mission Control (JMC)** 打开。关键视图：

- **Method Profiling** —— 火焰图样式的 CPU 时间分布
- **Garbage Collection** —— 每次 GC 的 cause、停顿时间、回收量
- **Allocation by Class** —— 哪些类的分配速率最高（**找 GC 元凶的杀手锏**）
- **Hot Methods** —— 最热的方法
- **Lock Instances** —— 锁竞争分布
- **Socket I/O** / **File I/O** —— IO 耗时

JFR + JMC 的能力**远超** `jstack` + `jstat`，**真出过线上事故的团队都应该养成开 continuous JFR 的习惯**。

## 八、Arthas：阿里开源的运行时观测神器

Arthas 是过去 5 年最好用的 Java 排障工具，没有之一。**不需要重启进程**就能挂上去看内部状态、跟踪方法、改方法字节码。

### 安装与启动

```bash
# 下载
curl -O https://arthas.aliyun.com/arthas-boot.jar

# 启动并 attach 到目标进程
java -jar arthas-boot.jar
# 它会列出所有 JVM PID，选一个回车
# 进入交互式 shell
```

容器环境：把 `arthas-boot.jar` 放到镜像里，或 `kubectl cp` 进去。

### 必学的核心命令

#### dashboard —— 一屏看完所有

```
[arthas@1234]$ dashboard
ID     NAME                          GROUP          PRIORITY   STATE    %CPU    DELTA_TIME
12     http-nio-8080-exec-2          system         5          RUNN     85.20   0.852
13     http-nio-8080-exec-3          system         5          RUNN     12.10   0.121
...

Memory                          used    total    max     usage    GC
heap                            2.1G    4.0G     4.0G    52.50%   gc.g1_young.count   2843
   g1_eden_space                512M    1.5G     -1      33.33%   gc.g1_young.time(ms)78120
   g1_old_gen                   1.5G    2.5G     2.5G    60.00%   gc.g1_old.count     12
nonheap                         256M    512M     -1      50.00%
Runtime                                                            os.name             Linux
                                                                   os.version          ...
```

一屏看完线程 CPU、内存、GC——比 top + jstat 拼起来高效得多。

#### thread —— 比 jstack 友好

```bash
thread                       # 列所有线程（CPU、状态、name）
thread -n 3                  # 看 CPU 占用 Top 3 的线程栈（直接给你答案，不用 top -H + 转 hex）
thread -b                    # 死锁检测
thread <tid>                 # 看特定线程的栈
thread --state BLOCKED       # 只看 BLOCKED 状态的
```

`thread -n 3` 一条命令搞定"哪些线程吃 CPU"，不用 §02 的 top → printf → grep 三步。

#### trace —— 找方法慢在哪里

```bash
trace com.example.OrderService createOrder
```

输出树形展开：

```
+---[100.521ms] com.example.OrderService:createOrder()
    +---[2.131ms] com.example.OrderRepository:save() #45
    +---[95.832ms] com.example.PaymentClient:charge() #50   ← 慢在这里
    +---[1.523ms] com.example.NotifyService:send() #60
```

每一行的时间是耗时，`#数字` 是行号。**接口慢的排查神器**——一眼看到耗时在哪个子调用。

进阶过滤：

```bash
trace com.example.OrderService createOrder '#cost > 100'   # 只显示总耗时 > 100ms 的调用
trace -E com.example.* '.*Service$' createOrder            # 正则匹配
trace --skipJDKMethod false com...                         # 包含 JDK 方法（默认排除，看完整链）
```

#### watch —— 看入参、出参、异常

```bash
watch com.example.OrderService createOrder '{params, returnObj, throwExp}' -x 2
```

`-x 2` 是展开深度。`{params, returnObj, throwExp}` 是 OGNL 表达式，可以取任意上下文。

```bash
watch com.example.OrderService createOrder 'params[0]' 'params[0].userId == 12345'
# 只看 userId=12345 的调用
```

`watch` 是定位"线上出错了但本地复现不了"问题的**唯一手段**——能拿到实际入参，根本不用猜。

#### profiler —— 集成 async-profiler

```bash
profiler start                        # 默认 cpu 模式
profiler start --event alloc          # alloc 模式：分配热点
profiler start --event lock           # lock 模式：锁竞争
profiler stop --file /tmp/flame.html  # 停止并生成火焰图
```

Arthas 已经把 async-profiler 嵌进来了，不用单独装。**推荐用 Arthas 的 profiler 而不是直接装 async-profiler**——更新更快、命令更简单。

#### jad / mc / redefine —— 热部署

```bash
jad com.example.OrderService                          # 反编译看实际跑的代码
jad --source-only com.example.OrderService > /tmp/OrderService.java
# 改 /tmp/OrderService.java
mc /tmp/OrderService.java -d /tmp                     # 在线编译
redefine /tmp/com/example/OrderService.class          # 热加载新 class
```

⚠️ **生产环境慎用 redefine**——改了字节码不会留痕，下次重启就回到老版本，运维一脸懵。仅在"必须紧急 patch 一行，回滚来不及"的场景用，且 1 小时内必须走正式发布流程。

#### 其他常用

| 命令 | 作用 |
| --- | --- |
| `sysprop` | 看 / 改 system property |
| `vmoption` | 看 / 改 JVM option |
| `getstatic com.X.Y FIELD` | 看类的静态字段值（debug 配置很有用） |
| `sc -d com.example.X` | 看类详情（loader、source jar） |
| `sm com.example.X` | 看类的方法签名 |
| `logger --name ROOT --level DEBUG` | 动态改日志等级（无需重启） |
| `stack com.example.X foo` | 看 `foo` 方法被谁调用 |

### Arthas 的生产坑

1. **trace / watch 高频方法会拖垮业务**——一个 QPS 5000 的接口，trace 它一秒生成几 MB 输出，Arthas 自身的 SocketChannel 都吞不下。生产 trace 务必加 `-n 5`（采 5 次就停）或者条件过滤
2. **不能 attach 不同版本 JDK**——Arthas 自身用 JDK 8 启动只能 attach JDK 8 进程，JDK 11 进程要用 JDK 11 的 Arthas
3. **退出后清现场**：`stop` 命令清理增强，否则字节码增强会留着影响性能
4. **生产环境只读模式**：建议用 `--no-exec` 或团队约定只读命令（dashboard、thread、trace、watch、jad），禁用 redefine

## 九、async-profiler：火焰图之王

async-profiler 是基于 perf_events 的低开销 profiler。它的**杀手锏**是利用 AsyncGetCallTrace API + perf_events，**避免 JVM safepoint 偏差**——而 JVisualVM、JFR（旧版）的 sampling 都是 safepoint biased，会漏掉很多真实的热点。

### 四种 event 模式

```bash
./profiler.sh -e cpu -d 60 -f /tmp/cpu.html <pid>      # CPU 火焰图（默认）
./profiler.sh -e alloc -d 60 -f /tmp/alloc.html <pid>  # 内存分配火焰图（找 GC 元凶）
./profiler.sh -e lock -d 60 -f /tmp/lock.html <pid>    # 锁竞争火焰图
./profiler.sh -e wall -d 60 -f /tmp/wall.html <pid>    # wall clock（包括阻塞 / IO，找"接口为什么慢"）
```

四种模式对应的问题：

- **cpu**：找 CPU 烧在哪——业务死循环 / 序列化 / 加解密 / GC
- **alloc**：找谁在分配大量短命对象——根治 YGC 频繁的关键
- **lock**：找锁竞争——`synchronized` / `ReentrantLock` 的争用
- **wall**：找接口耗时分布——**和 cpu 不同**，wall 把阻塞时间也算进去，所以你能看到"线程在等 DB 返回"这种情况

**为什么 wall 模式比 cpu 模式更适合排查接口慢**：cpu 模式只看 RUNNABLE 时间，看不到 BLOCKED / WAITING；如果接口慢是因为在等 DB / Redis，cpu 火焰图根本看不出来，wall 火焰图能。

### 怎么读火焰图

```
[根]
 ├── [Tomcat 入口]
 │    └── [Controller.foo]
 │         ├── [Service.bar]                ← 宽度 60%，重灾区
 │         │    └── [Repository.find]
 │         │         └── [JDBC.execute]      ← 宽度 50%，瓶颈在这
 │         └── [Service.baz]                ← 宽度 5%
 │              └── ...
 └── [GC 线程]                              ← 宽度 10%
```

**宽度 = 占用 CPU / wall 时间的比例**。从下往上看（调用链由根到叶），找最宽的叶子就是热点。

### 火焰图的生产姿势

- 用 Arthas 的 `profiler` 命令包装，比直接 async-profiler 简单
- 持续时间 30–60 秒够用，更长不是更准
- 生成 HTML 火焰图（`-f xxx.html`），浏览器打开能搜索 / 缩放
- 火焰图最重要的能力是**和基线对比**：保存正常时的火焰图作为 baseline，故障时拉一张对比

### async-profiler 的限制

- 需要内核支持 `perf_events`（容器内可能受限，需要 `CAP_SYS_ADMIN` 或 `kernel.perf_event_paranoid <= 1`）
- 不能跨容器 attach（容器内的 PID namespace 隔离）

## 十、工具选型决策树

```
现象
 ├── CPU 高
 │    1. top -H -p / Arthas thread -n
 │    2. jstack / Arthas thread <tid>
 │    3. async-profiler cpu（持续 60s）
 │
 ├── GC 频繁
 │    1. jstat -gcutil 1s
 │    2. GC 日志 → GCeasy
 │    3. async-profiler alloc 找谁分配多
 │    4. jcmd GC.class_histogram
 │
 ├── 接口慢 / RT 抖动
 │    1. Arthas trace <Class> <method>
 │    2. Arthas watch 看入参
 │    3. async-profiler wall 看阻塞
 │    4. JFR continuous 拉 1 小时回放
 │
 ├── 内存疑似泄漏
 │    1. jmap -histo:live 隔 5min 拉两次对比
 │    2. jmap -dump → MAT
 │    3. async-profiler alloc 找分配源头
 │
 ├── 锁竞争
 │    1. jstack 找 BLOCKED + 同一锁对象 ID
 │    2. Arthas thread -b 死锁检测
 │    3. async-profiler lock
 │
 ├── 堆外 / Native 内存涨
 │    1. jcmd VM.native_memory summary.diff
 │    2. pmap -x <pid> 看 RSS 分布
 │    3. （高级）gdb attach 看 native 栈
 │
 ├── 线程数失控
 │    1. jstack 数线程总数 + 名字聚合
 │    2. Arthas dashboard 实时看
 │
 └── 想知道实际生效的参数
      jcmd VM.flags 或 jinfo -flags <pid>
```

## 十一、典型组合姿势

### 姿势 1：Java 进程 CPU 90%

```bash
# 老姿势（不用 Arthas）
top -bn1 -H -p <pid> | head -15           # 找 TID
printf "%x\n" <tid>                       # 转 hex
jstack <pid> > /tmp/jstack.log
grep -A 30 "nid=0x<hex>" /tmp/jstack.log

# 新姿势（用 Arthas）
java -jar arthas-boot.jar
> thread -n 3                              # 一行搞定
> profiler start; sleep 60; profiler stop --file /tmp/flame.html
```

### 姿势 2：YGC 突然飙到 5 Hz

```bash
# 1. jstat 确认 YGC 频率
jstat -gcutil <pid> 1000

# 2. 看 Eden / Old 涨速
# 3. 找谁在大量分配
java -jar arthas-boot.jar
> profiler start --event alloc
> # 等 60 秒
> profiler stop --file /tmp/alloc.html
# 浏览器打开火焰图，找分配热点
```

具体根因看 [JVM/17](../JVM/17_G1常见问题（上）：Young GC频繁、Humongous Allocation与Young区压力.md)。

### 姿势 3：接口 P99 慢 500ms

```bash
java -jar arthas-boot.jar
> trace com.example.OrderController create '#cost > 200' -n 10
# 找出哪段子调用慢

> watch com.example.PaymentClient charge '{params, returnObj}' -x 2 -n 5
# 看具体调用细节，是不是某些参数特别慢
```

或者：

```bash
> profiler start --event wall
> # 等业务自然产生慢请求 60 秒
> profiler stop --file /tmp/wall.html
# wall 火焰图找阻塞热点
```

### 姿势 4：可疑内存泄漏

```bash
# 5 分钟前
jmap -histo:live <pid> | head -50 > /tmp/h1.txt

# 5 分钟后
jmap -histo:live <pid> | head -50 > /tmp/h2.txt

# 对比
diff /tmp/h1.txt /tmp/h2.txt
# 找 #instances 持续上涨的类

# 进一步：堆 dump（先确认是故障节点）
jcmd <pid> GC.heap_dump /tmp/heap.hprof
# 拷回本地用 MAT 分析
```

### 姿势 5：堆外 RSS 涨但 -Xmx 没变

```bash
# 前提：启动加了 -XX:NativeMemoryTracking=summary
jcmd <pid> VM.native_memory baseline    # 设基线
sleep 600                                # 等 10 分钟
jcmd <pid> VM.native_memory summary.diff
# 看哪一类内存涨得最多

# 如果 NMT 总和 << RSS，说明被非 JVM 管理的内存吃了
pmap -x <pid> | sort -k 3 -nr | head    # 看大块匿名内存
```

## 十二、几个常见反模式

| 反模式 | 正确做法 |
| --- | --- |
| 任何 Java 问题都先 jstack | 看现象选工具：CPU 用 jstack/profiler、慢用 trace/wall、内存用 alloc/jmap |
| 生产业务还在跑就 jmap -dump | 触发 Full GC + STW，先摘节点再 dump |
| jmap -histo 不加 live | 包含死对象，数据不准 |
| jstack 单次采样下结论 | 至少 3 次相隔 5 秒采，对比看哪些线程"卡着不动" |
| Arthas trace 高 QPS 接口不加 `-n` 或条件 | 拖垮业务，永远加次数限制和过滤条件 |
| Arthas 用完不 `stop` | 增强代码留着影响性能 |
| 没装 sysstat 也没开 continuous JFR | 故障过去就什么也分析不了 |
| 在容器外 jps 找不到容器内 PID | PID namespace 隔离，要 `kubectl exec` 进去 |
| 用 OracleJDK 8 + JFR 不知道要 unlock | `-XX:+UnlockCommercialFeatures`（8u262+ 不需要） |
| `jstack -F` 当默认用 | 优先 `jstack`，hang 住才 `-F`，`-F` 有 crash 风险 |

## 十三、本章小结与下一步

### 小结

- 工具按"现象 → 工具"组织，不要养成"什么问题都 jstack"的习惯
- **JDK 自带**：`jps` / `jstat` / `jstack` / `jmap` 是基础；`jcmd` 是现代瑞士军刀，未来标配；**JFR continuous 是事后复盘的金矿**
- **Arthas** 在运行时观测和热部署上吊打 JDK 自带：`dashboard` / `thread -n` / `trace` / `watch` / `profiler` 是核心五件套
- **async-profiler** 的 wall 模式专治"接口慢但 CPU 不高"
- **生产环境的坑**：jmap -dump STW、jstack 等 safepoint、Arthas trace 高频接口拖垮业务、容器 PID namespace
- **NMT** + `jcmd VM.native_memory summary.diff` 是堆外排查的标准姿势
- 启动参数建议加：`-XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=` 防 OOM 现场丢失，加 `-XX:NativeMemoryTracking=summary` 准备好 NMT，加 continuous JFR

### 与后面章节的衔接

- §06 可观测性三件套 —— Metrics / Log / Trace。Arthas / jstack / JFR 是"摸现场"，三件套是"日常持续监控"，互补
- §07 CPU 飙高专题 —— 这一章的"top -H + jstack" 和"Arthas thread -n + profiler" 会成为标准 SOP
- §08 内存暴涨与 OOM —— 这一章的 jmap / NMT / async-profiler alloc 会和 MAT、Heap Dump 工作流连起来
- §11 FullGC 频繁 —— jstat + GC 日志 + alloc 火焰图 是标准三件套

### 留给下一章的问题

- §06 要回答的核心问题：Metrics（Prometheus）、Log（ELK / Loki）、Trace（SkyWalking / Jaeger）三者**各自能回答什么、不能回答什么**？排障时三者的进入顺序是什么？

---

## 未定问题清单

- 是否单独写一节 **`strace` / `perf` 详解**？这两个是 OS 层工具但和 Java 排障耦合很深（`strace` 看系统调用、`perf` 看 CPU 性能事件）。倾向作为附录在本章末尾或 §07 / §15 嵌入。
- **BTrace** / **byteman** 这种"老一代字节码增强工具"是否提一下？倾向不提，Arthas 已经覆盖 99% 场景，这两个学习成本高且生态萎缩。

---

写完了。请确认这一章的组织和深度，以及上面两个未定问题如何选择。确认后进入 §06 可观测性三件套。
