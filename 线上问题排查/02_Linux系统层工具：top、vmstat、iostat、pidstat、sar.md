# Linux 系统层工具：top、vmstat、iostat、pidstat、sar

## 这一章想解决什么

§01 给了决策树——线上现象 90% 进入 CPU / 内存 / IO / 网络 / 依赖 五条路径之一。这一章解决**前三条路径的"入口工具"**：

- CPU 高了，先用什么命令看？
- 内存涨了，先用什么命令看？
- 磁盘 IO 慢了，先用什么命令看？

这一章不会把每个工具的所有参数写一遍（那是 man page 的事），而是回答三个问题：

1. **每个工具最擅长回答什么问题**——为什么有 `top` 还要 `vmstat`？为什么有 `vmstat` 还要 `iostat`？
2. **关键列必须能看懂**——`%wa`、`r/b`、`si/so`、`%util`、`await` 这些列出现时要立刻知道什么意思
3. **典型组合姿势**——从一个症状到最终定位，应该按什么顺序跑哪些命令

学完这一章，你看到机器变慢应该能在 60 秒内完成"整机状态扫一遍"。

## 一、一张地图：四个观测维度对应哪些工具

线上排障的观测维度不是"操作系统全部指标"，而是四个核心维度。每个维度有一个**主力工具** + 几个辅助工具：

| 维度 | 关键问题 | 主力工具 | 辅助工具 |
| --- | --- | --- | --- |
| **整机负载** | 机器忙不忙？什么资源在烧？ | `top` / `uptime` | `htop`、`w` |
| **CPU 分布** | CPU 高是用户态还是内核态？是不是单核独热？ | `vmstat` | `mpstat -P ALL`、`pidstat -u` |
| **内存** | 内存到底紧不紧？有没有换页？ | `free -h` | `vmstat`（si/so）、`pidstat -r`、`/proc/meminfo` |
| **磁盘 IO** | 磁盘瓶颈？读多还是写多？ | `iostat -x` | `pidstat -d`、`iotop` |
| **历史趋势** | 故障发生前后这些指标怎么变的？ | `sar` | `dstat` |

**关键认知**：

- `top` 是"什么都能看一眼"的瑞士军刀——但每一项都不够细
- `vmstat` 是 CPU + 内存 + IO + 上下文切换的**综合视图**——但不分进程
- 分维度看细节就用 `mpstat` / `pidstat` / `iostat` / `free`
- **历史问题**只能靠 `sar`——其他都是实时

新手最常见的错误是只会 `top`，结果遇到"内存压力大但 top 看不出原因"就卡住了。要建立"症状 → 主力工具 → 辅助工具"的肌肉记忆。

## 二、uptime / top：整机视角

### uptime —— 三秒内判断"机器忙不忙"

```
$ uptime
 14:32:01 up 47 days,  3:21,  2 users,  load average: 8.42, 4.15, 2.08
```

三个 load average 数字是 **1 分钟、5 分钟、15 分钟**的平均负载。判断口径：

| 负载 vs CPU 核数 | 含义 |
| --- | --- |
| `load < 核数 × 0.7` | 健康 |
| `核数 × 0.7 ≤ load < 核数` | 偏忙但能扛 |
| `load ≥ 核数` | **CPU 不够用**，开始有任务排队 |
| `load >> 核数`（如 2 倍以上） | 严重过载，业务体感卡顿 |

`8.42, 4.15, 2.08` 这种**递增**模式说明负载在快速上升，是恶化中的故障；如果是 `2.08, 4.15, 8.42` 反过来说明负载在恢复。

**注意**：Linux 的 load average **不等于 CPU 利用率**，它包含 **R（runnable）+ D（uninterruptible sleep，通常是 IO 等）**两类进程。所以 load 高也可能是 IO wait 高，不一定是 CPU。这就是为什么后面要用 `vmstat` 区分。

### top —— 关键列怎么读

`top` 第一屏分两部分，上面是整机汇总，下面是进程列表。

**头部三行**：

```
top - 14:32:01 up 47 days,  3:21,  2 users,  load average: 8.42, 4.15, 2.08
Tasks: 412 total,   2 running, 410 sleeping,   0 stopped,   0 zombie
%Cpu(s): 38.2 us,  12.5 sy,  0.0 ni, 41.3 id,  7.8 wa,  0.0 hi,  0.2 si,  0.0 st
```

`%Cpu(s)` 这一行是**整机 CPU 分布**，每一列含义和判断：

| 列 | 全称 | 看到很高意味着什么 |
| --- | --- | --- |
| `us` | user | 业务代码在烧——业务逻辑 / 序列化 / 加解密 / 正则 |
| `sy` | system（内核态） | 系统调用 / 内核态忙：GC 上下文切换、网络收发、文件读写 |
| `ni` | nice（被调低优先级的用户态） | 一般不用看 |
| `id` | idle | 空闲，正常应该高 |
| `wa` | iowait | **磁盘 IO 慢**——CPU 在等 IO 返回（注意：高 `wa` 也可能是某个进程在阻塞 IO，不一定是磁盘问题，见后） |
| `hi` | hardware irq | 硬中断（网卡中断密集） |
| `si` | software irq | 软中断（网卡软中断、定时器） |
| `st` | steal | **虚拟化环境特有**——宿主机把 CPU 给了别的 VM，你被偷了。云上看到 `st > 5%` 说明邻居在抢，要联系运维 |

**经验法则**：

- `%us` 高 + `%sy` 低 → 业务代码问题（死循环、低效算法）→ §07
- `%us` + `%sy` 都高 + `%sy` > 30% → 上下文切换 / 系统调用 / GC 风暴 → 查 `vmstat` 的 `cs` 列
- `%wa` > 20% → 磁盘 IO 瓶颈 → §16
- `%si` 突高 → 网络流量大或网卡中断没均衡到多核 → `mpstat -P ALL` 看是不是 CPU0 单核打满
- `%st` > 5% → 云上 noisy neighbor，找运维

**第二行 `Tasks`**：

- `running` 是当前在 CPU 上跑或可运行的进程数——这个数 ≥ CPU 核数说明开始排队
- `zombie` > 0 说明有僵尸进程没人收（父进程没 `wait()`），不影响业务但要查

### top 的常用操作

```bash
top -p <pid>          # 只看某个进程
top -H -p <pid>       # 看进程内的所有线程（重要！排查 Java CPU 高的入口）
top -bn1              # 跑一次就退出，便于脚本 / 重定向到文件
top -c                # 显示完整命令行（默认截断）
```

进入 top 交互界面后的快捷键：

| 按键 | 作用 |
| --- | --- |
| `P` | 按 CPU 排序（默认） |
| `M` | 按内存排序 |
| `T` | 按运行时间排序 |
| `c` | 切换显示完整命令行 |
| `H` | 切换显示线程 |
| `1` | 显示每个 CPU 核的分布（不再只显示平均） |
| `f` | 自定义显示列 |
| `W` | 保存当前显示配置到 `~/.toprc` |

按 `1` 之后能看到每个核单独的 `us / sy / wa` ——这一步**经常被忽略但极其重要**：

```
%Cpu0  : 99.7 us,  0.3 sy,  0.0 ni,  0.0 id,  0.0 wa
%Cpu1  :  2.0 us,  1.0 sy,  0.0 ni, 97.0 id,  0.0 wa
%Cpu2  :  1.5 us,  0.8 sy,  0.0 ni, 97.7 id,  0.0 wa
...
```

**整机 CPU 平均只有 13%，但 CPU0 是 100%**——这是单核独热的典型现象，多半是：

- 单线程程序（业务代码有死循环 / 单线程消费）
- 网卡软中断没均衡（看 `/proc/interrupts`，多核 RPS / RSS 没开）
- 锁竞争退化为单线程（多个线程都在等同一把锁）

### htop —— top 的友好版

`htop` 默认不预装，但比 `top` 直观得多：

- 上方有每核 CPU 条形图 + 内存 / Swap 条
- 支持鼠标点击列排序
- 树形显示父子进程
- `F5` 树形视图、`F6` 切排序列、`F9` 杀进程

**生产环境一般装一个，应急用 `htop` 更快，脚本里用 `top -bn1`。**

## 三、vmstat：CPU + 内存 + IO 的综合视图

`top` 只能看一个瞬间，且按进程分组。`vmstat` 给出**机器整体的吞吐流水**，是排障第二步必看。

```
$ vmstat 1 5
procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
 8  2      0 152340 102400 8421340    0    0    32   180 8520 12300 38 12 41  8  0
12  0      0 151200 102400 8421340    0    0     0   240 9120 13500 42 13 38  7  0
...
```

每一列含义（按重要性排序）：

| 列 | 含义 | 关键判断 |
| --- | --- | --- |
| `r` | 当前 runnable 队列长度（含正在跑的） | `r > CPU 核数` = CPU 排队，过载信号 |
| `b` | uninterruptible sleep 的进程数（多半 IO 阻塞） | `b > 0` 持续存在 = 有进程被 IO 卡住 |
| `cs` | 每秒上下文切换次数 | 突然飙升（10W+/s）= 线程过多 / 锁竞争 / 中断风暴 |
| `in` | 每秒中断次数 | 高且 `si` 也高 = 网络中断频繁 |
| `si/so` | swap in / swap out（KB/s） | **任何非零都是坏信号**——内存不够开始换页，性能崩塌 |
| `bi/bo` | 块设备读 / 写（KB/s） | 异常高 = 磁盘大量读 / 写，配合 `iostat` 看 |
| `us/sy/id/wa/st` | 同 `top` | 同上 |

### vmstat 的杀手锏：si / so

**这一列是判断"内存到底紧不紧"最直接的信号**。

`free -h` 看到 free 内存很少时，新手经常慌。其实 Linux 的内存管理会把空闲内存大量用作 page cache，**`free` 小不代表内存紧张**。真正紧张的信号是 `si/so` 持续非零——意味着内核已经被迫把内存换到 swap 上去。

```
si  so
 0   0    ← 健康，没在换页
 0   1280 ← 内存吃紧，开始往 swap 写
2048 3000 ← 严重，内存几乎压垮，业务一定有体感
```

**生产环境正确做法**：Java 应用一般**关 swap**（`swapoff -a` 或 `vm.swappiness=0`）。原因是 JVM 一旦堆被换到 swap，GC 会拖死整机（GC 要扫描全堆，遇到 swap 页就触发 disk IO，雪崩）。所以 Java 服务器上 `si/so` 应该永远是 0；如果不是，先查 swap 是不是开了。

### vmstat 的杀手锏：cs

`cs`（context switch）每秒 1–2 万是正常水平。突然飙到 10 万 / 50 万说明：

- 线程数失控（每个请求新建线程、线程池配置过大）
- 锁竞争激烈（线程频繁被阻塞唤醒）
- 中断风暴（网卡问题、定时器风暴）

配合 `pidstat -w` 看是哪个进程贡献的 `cs`：

```
$ pidstat -w 1
   PID    cswch/s nvcswch/s  Command
  1234     5320     12000    java          ← 这个 java 进程一秒被切换 1.7w 次
```

`cswch/s` 是**自愿**切换（等 IO / 锁），`nvcswch/s` 是**非自愿**切换（被抢占 / 时间片用完）。后者高说明 CPU 抢占激烈。

### vmstat 的姿势

```bash
vmstat 1            # 每秒刷一次，永久输出（Ctrl+C 退出）
vmstat 1 60         # 每秒刷一次，跑 60 次
vmstat -S M 1       # 内存列用 MB 显示（默认 KB，看着累）
vmstat -w 1         # 宽格式，列对齐更好读
```

**第一行 vmstat 的输出是开机以来的累积值，不是实时的——一律忽略，从第二行看起**。

## 四、mpstat：CPU 分核明细

`top` 按 `1` 也能看每核，但 `mpstat` 输出更稳定，适合脚本化：

```
$ mpstat -P ALL 1 3
14:35:01     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %idle
14:35:02     all   28.50    0.00    8.20    3.50    0.00    0.50    0.00   59.30
14:35:02       0   99.00    0.00    1.00    0.00    0.00    0.00    0.00    0.00  ← 独热
14:35:02       1    5.00    0.00    2.00    0.50    0.00    0.00    0.00   92.50
14:35:02       2    4.50    0.00    1.80    0.20    0.00    0.00    0.00   93.50
...
```

主要看两类情况：

1. **单核打满，其他核闲** → 单线程瓶颈 / 锁竞争退化 / 软中断没分散
2. **所有核 `%soft` 都高** → 网络流量大，软中断密集

**网络相关的判断**：如果 `%soft` 集中在某一两个核（比如 CPU0、CPU1），说明 RPS / RSS 没配好，所有网卡软中断都打到一个核——这在大流量场景下会成为瓶颈。

## 五、pidstat：进程 / 线程级明细

`top` 看进程，`pidstat` 看得更细——可以分**线程级**，分**资源类型**：

```bash
pidstat 1                    # 每秒输出所有进程的 CPU 使用
pidstat -p <pid> 1           # 只看一个进程
pidstat -t -p <pid> 1        # 看进程内所有线程！这是 §07 CPU 飙高排查的关键
pidstat -u 1                 # CPU
pidstat -r 1                 # 内存（页错误、RSS）
pidstat -d 1                 # 磁盘 IO（kB_rd/s、kB_wr/s）
pidstat -w 1                 # 上下文切换（cswch/s、nvcswch/s）
```

线程级输出：

```
$ pidstat -t -p 1234 1
14:38:01      TGID       TID    %usr %system  %CPU   CPU  Command
14:38:02      1234         -    85.0    5.0   90.0     5  java
14:38:02         -      1240    78.0    2.0   80.0     5  |__java          ← 这个线程独占
14:38:02         -      1245     3.0    1.0    4.0     2  |__java
14:38:02         -      1250     2.0    0.5    2.5     1  |__java
```

`TID` 是线程 ID。**把 TID 转十六进制（`printf "%x\n" 1240`），到 `jstack` 输出里 grep**，就能直接找到这个线程的 Java 栈——这就是 §07 CPU 飙高的标准 SOP。

`pidstat -r` 还能看 `minflt/s`（次缺页）和 `majflt/s`（主缺页）：

- `majflt` 高 = 需要从磁盘读页（swap-in 或 mmap 文件冷启动）
- `minflt` 高 = 只是 page table 没建，不查盘

`majflt > 0` 持续出现说明内存压力，需要查 swap 和文件 cache。

## 六、iostat：磁盘 IO

`top` 的 `%wa` 告诉你"CPU 在等 IO"，但**等哪块盘的 IO、读还是写、为什么慢**——必须 `iostat`：

```
$ iostat -x 1 3
Device   r/s   w/s     rkB/s   wkB/s  rrqm/s wrqm/s  %rrqm %wrqm  r_await w_await  aqu-sz rareq-sz wareq-sz  %util
sda     5.20  120.50    640    8200    0.00   12.30   0.00  9.30    1.20   25.30    3.20    123.0     68.0  98.30
sdb     0.50    2.00      4      32    0.00    0.10   0.00  4.80    0.50    1.00    0.01      8.0     16.0   0.50
```

关键列（必须能看懂）：

| 列 | 含义 | 判断 |
| --- | --- | --- |
| `r/s`、`w/s` | 每秒读 / 写次数（IOPS） | 高 IOPS 但 BW 低 = 小文件随机读写多 |
| `rkB/s`、`wkB/s` | 每秒读 / 写带宽（KB/s） | 总和接近盘上限 = 带宽瓶颈 |
| `r_await`、`w_await` | 每个 IO 请求的平均等待时间（ms） | **关键指标**。SSD 应该 < 1ms，HDD < 10ms；> 20ms 必定有问题 |
| `aqu-sz` | 平均请求队列长度（avgqu-sz 旧名） | > 1 说明请求开始排队 |
| `%util` | 设备被使用的时间百分比 | > 80% 偏忙，但不等于打满 |

### `%util` 100% 的陷阱

新手经常看到 `%util` 接近 100% 就喊"磁盘打满了"。其实：

- **`%util` 的定义是"过去 1 秒内有 IO 请求的时间比例"**，不是"吞吐打满"
- 现代 SSD / 多盘 RAID 可以**并发处理多个请求**，`%util` 100% 不代表带宽 / IOPS 用满
- 判断真正瓶颈要看 `await`、`aqu-sz` 和 `r/s + w/s` 是否接近盘的官方上限

**正确的瓶颈判断**：

- `%util` 高 + `await` 飙升（比基线高 5–10 倍） + `aqu-sz` > 1 ── 这才是真的 IO 瓶颈
- `%util` 高 + `await` 正常 + `aqu-sz < 1` ── 盘在干活但没排队，没问题

### iostat 的姿势

```bash
iostat -x 1            # 扩展统计 + 每秒刷新（标配）
iostat -xm 1           # MB/s 单位
iostat -xdh 1          # human readable（KiB / MiB）
iostat -p sda 1        # 只看某块盘
```

定位是哪个进程在烧 IO，要用 `pidstat -d 1` 或 `iotop -oP`：

```
$ iotop -oP
  PID  PRIO  USER   DISK READ DISK WRITE  COMMAND
 1234  be/4 app    0.00 B/s    45.20 M/s  java
```

`-o` 只显示有 IO 的进程，`-P` 显示进程级（不是线程）。

## 七、free：内存到底紧不紧

```
$ free -h
              total        used        free      shared  buff/cache   available
Mem:           32Gi        18Gi       512Mi       1.2Gi        14Gi        12Gi
Swap:           0B          0B          0B
```

**这一行看懂的人不多。关键列**：

| 列 | 含义 |
| --- | --- |
| `total` | 物理内存总量 |
| `used` | 已分配给进程的内存（不含 buff/cache） |
| `free` | **完全没用**的内存——通常很小，因为内核会把空闲内存用作 cache |
| `shared` | 共享内存（tmpfs） |
| `buff/cache` | **可回收的内存**——内核做的文件缓存，应用要的时候可以让出来 |
| `available` | **真正"还能用"的内存**——`free` + 可回收的 `buff/cache` |

**判断内存紧不紧只看一个数：`available`**。

- `available > 20%` 总内存 → 健康
- `available < 10%` → 偏紧
- `available < 5%` + `swap used > 0` + `vmstat si/so > 0` → 真的紧，准备触发 OOM Killer

**反模式**：看到 `free` 只有 512Mi 就慌——其实 `available` 12Gi，根本没事。Linux 的 page cache 设计本身就是"有内存就拿来缓存"，应用真要时立刻让出。

### /proc/meminfo —— 更细的内存视图

`free` 是 `/proc/meminfo` 的简化版。深入排查时直接看 `/proc/meminfo`：

```bash
cat /proc/meminfo | head -20
```

关键行：

- `MemAvailable` — 同 `free` 的 `available`
- `Cached` — page cache
- `Buffers` — block IO 缓存
- `SReclaimable` — 可回收的 slab（dentry / inode 缓存）
- `Slab` — 内核 slab 分配器用的内存（总量）

**线上常见坑**：`Slab` 异常大（比如 5GB+），多半是 dentry cache 爆了——某个进程在大量打开/关闭小文件。处理：`echo 2 > /proc/sys/vm/drop_caches`（释放 dentry / inode cache），治标；治本要让业务停掉狂打开文件的行为。

## 八、sar：历史数据

前面所有工具都是**实时**的。故障已经过去半小时，你想看"故障发生时 CPU 怎么变化的"，只能靠 `sar`。

```bash
sar -u 1 5             # 实时 CPU，等价于一个简化的 mpstat
sar -u                 # 看今天所有时间点的 CPU 历史（默认 10 分钟一个采样）
sar -u -f /var/log/sa/sa15  # 看 15 号的 CPU 历史
sar -r                 # 内存历史
sar -d                 # 磁盘历史
sar -n DEV             # 网卡历史
sar -n TCP,ETCP        # TCP 连接历史
sar -B                 # 换页 / 内存压力历史
sar -q                 # load average 和运行队列历史
```

**前提**：得装 `sysstat` 包并启用采集（`/etc/cron.d/sysstat`），默认 10 分钟一个采样，留 7–28 天。**生产机器一定要装并开**，否则事后查无凭据。

### sar 的典型用法：故障复盘

```bash
# 故障时间是 14:00–14:15，看看 CPU、内存、磁盘
sar -u -s 14:00:00 -e 14:15:00
sar -r -s 14:00:00 -e 14:15:00
sar -d -s 14:00:00 -e 14:15:00
```

`-s` 起始时间、`-e` 结束时间。能把故障窗口里的整机状态序列拉出来，配合 Prometheus 监控截图，是复盘必备。

## 九、典型组合姿势

把上面所有工具串成"症状 → 工具链"的查法。

### 姿势 1：机器突然变慢，不知道哪里出问题

```
1. uptime                       # 30 秒，看 load 量级和趋势
2. top -bn1 -c | head -20      # 整机 CPU 分布 + 前 20 个进程
3. vmstat 1 5                  # 5 秒采样，看 r/b/si/so/cs 维度
4. iostat -x 1 3               # 3 秒采样，看磁盘瓶颈
5. free -h                      # 看内存压力
```

**判断分叉**：

- `top` 里 `%us` 高 → §07 CPU 排查
- `top` 里 `%wa` 高 → 走 `iostat`，定位是哪块盘、哪个进程（`iotop`）→ §16
- `vmstat` 里 `si/so` 非零 → 内存紧张 → `pidstat -r` 找元凶 → §08
- `vmstat` 里 `cs` 飙升 → `pidstat -w` 找元凶 → 线程数 / 锁竞争 → §10

### 姿势 2：某个 Java 进程吃 CPU

```
1. top -bn1 | grep java         # 确认 PID 和总 CPU%
2. top -H -p <pid>              # 看进程内每个线程的 CPU
3. pidstat -t -p <pid> 1 3      # 更稳定的线程级输出
4. printf "%x\n" <tid>          # 把高 CPU 的 TID 转十六进制
5. jstack <pid> > /tmp/jstack.log
6. grep -A 30 "<hex_tid>" /tmp/jstack.log    # 找到对应栈
```

具体在 §07 详细展开。

### 姿势 3：内存看着够但 free 很小，心里没底

```
1. free -h                      # 重点看 available 而不是 free
2. vmstat 1 5                   # 看 si/so 是不是 0
3. cat /proc/meminfo | head     # 看 Cached / Slab 占多少
4. pidstat -r 1 3 | sort -k 8   # 按 RSS 排序，看是谁占大头
```

**判断**：`available` > 20% 总内存 + `si/so = 0` = 没事，free 小是 cache 撑的。

### 姿势 4：故障已过 30 分钟，复盘 14:00–14:15 的指标

```
sar -u -s 14:00:00 -e 14:15:00     # CPU 历史
sar -r -s 14:00:00 -e 14:15:00     # 内存历史
sar -B -s 14:00:00 -e 14:15:00     # 换页历史
sar -d -s 14:00:00 -e 14:15:00     # 磁盘历史
sar -n DEV -s 14:00:00 -e 14:15:00 # 网卡历史
sar -q -s 14:00:00 -e 14:15:00     # 运行队列 / load 历史
```

任何一个指标的突变点都可能是故障入口，按 §01 的"找最早的突变指标"原则推因果链。

## 十、几个常见反模式

| 反模式 | 正确做法 |
| --- | --- |
| 只跑一次 `top` 不看趋势 | `top` 至少看 3–5 秒；脚本化用 `vmstat 1 N` |
| 看到 `free` 小就慌 | 看 `available`，看 `si/so` |
| 看到 `%util` 100% 就喊 IO 满 | 看 `await` 和 `aqu-sz` |
| `vmstat` 看第一行数据 | **第一行是开机累计值，忽略**，从第二行起 |
| 忘了 `top` 按 `1` 看每核 | CPU 平均不代表每核——单核独热经常被掩盖 |
| 故障过后才想看 sar | 没装 sysstat 就什么都没有，**生产机必须预先装好** |
| 排障时只看应用层日志 | OS 指标是最早的客观证据，先看再 grep 日志 |

## 十一、生产环境的预安装清单

很多线上机器临时排障时才发现工具没装。建议**镜像里预置**这些：

| 包 | 提供的命令 |
| --- | --- |
| `procps-ng` | `top`、`free`、`vmstat`、`uptime`、`ps` |
| `sysstat` | `mpstat`、`pidstat`、`iostat`、`sar`、`sadf` |
| `htop` | `htop` |
| `iotop` | `iotop` |
| `iproute` | `ss` |
| `nettools` | `netstat`（虽然过时但有人习惯） |
| `tcpdump` | `tcpdump` |
| `lsof` | `lsof` |
| `strace` | `strace` |
| `bcc-tools` / `bpftrace` | 高级 eBPF 工具（开机即用） |

容器镜像通常是 `distroless` 或 `alpine`，没有这些工具——这是另一个话题：**容器里排障靠 sidecar / debug 容器**，§18 会展开。

## 十二、本章小结与下一步

### 小结

四个观测维度 → 主力工具：

- 整机：`uptime` / `top`
- CPU 分布：`vmstat` / `mpstat -P ALL` / `pidstat -t`
- 内存：`free -h` + `vmstat` 的 `si/so` + `/proc/meminfo`
- 磁盘：`iostat -x` + `iotop` + `pidstat -d`
- 历史：`sar`

关键认知：

- `load` 包含 IO 等待，不等于 CPU 利用率
- `top` 按 `1` 看每核，避免被平均值欺骗
- `vmstat` 的 `si/so` 是判断内存压力的金标准
- `free` 看 `available` 不是 `free`
- `iostat` 的 `%util` 不等于瓶颈，要配合 `await` 和 `aqu-sz`
- **生产机必装 sysstat**，否则事后查无凭据

### 与后面章节的衔接

- §03 网络层工具（`ss` / `netstat` / `tcpdump` / TCP 状态机）
- §04 文件、磁盘、句柄（`lsof` / `df` / `du` / inode）
- §05 Java 进程现场工具（`jstack` / `jmap` / Arthas / async-profiler）—— §02 的 `top -H` 和 `pidstat -t` 给出 TID，§05 教你怎么把 TID 落到 Java 栈

### 留给下一章的问题

- §03 网络章会回答："`top` 看到 `%si` 高、`vmstat` 看到 `cs` 飙升、`netstat` 看到 TIME_WAIT 一万——这些都指向网络层，但哪个才是因？"
- 抓包工具 `tcpdump` 的输出怎么读？什么场景必须抓包，什么场景看 `ss -s` 就够了？

---

## 未定问题清单

- 是否要单独写一节 **eBPF 工具地图**（`bcc-tools`、`bpftrace`、`perf`）？这些是新一代生产排障工具，比 `strace` 安全得多，但学习曲线陡。目前倾向放在 §05 末尾作为"老司机进阶"附录。
- `dstat` / `nmon` 这种"all-in-one"工具是否单独讲？目前没单列，因为信息量都是上面工具的并集，但有些团队默认装。如果你公司常用可以加一节。

---

写完了。请确认这一章的组织和深度，以及上面两个未定问题如何选择。确认后进入 §03：网络排查工具。
