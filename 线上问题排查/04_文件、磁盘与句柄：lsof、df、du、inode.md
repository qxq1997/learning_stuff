# 文件、磁盘与句柄：lsof、df、du、inode

## 这一章想解决什么

文件 / 磁盘 / 句柄这一类问题有个特点：**故障表现千奇百怪，但根因高度集中**——绕来绕去就是下面几种：

- 磁盘写满了
- inode 满了（**磁盘明明有空间但写不进**）
- 文件被删了但进程还占着 fd，**空间没释放**
- 进程打开太多文件 → `too many open files`，服务起不来或断流
- 某块盘 IO 已经成瓶颈，业务 RT 拖死

排查这些问题，新手往往只会 `df -h`。这一章把工具地图打全：

1. **磁盘容量层**：`df` / `du` —— 多少容量？谁占的？
2. **文件系统层**：inode、`lsof | grep deleted`、`dmesg` —— 不是容量问题但写不进
3. **句柄层**：`lsof`、`/proc/<pid>/fd`、`ulimit` —— `too many open files` 一族
4. **IO 性能层**：`iotop`、`pidstat -d` —— 容量没满但太慢

这一章也是工具地图章。具体问题专题（磁盘写满、句柄泄漏）的现象 → 止血 → 根因，在 §16 / §17 展开。

## 一、一张地图：四类问题 → 工具

| 问题表现 | 主力工具 | 辅助 |
| --- | --- | --- |
| 磁盘满了，"No space left on device" | `df -h` → `du -sh` | `find -size`、`ncdu` |
| 磁盘没满但写不进，仍 "No space left on device" | `df -i` | `find -xdev -type f \| wc -l` |
| `df` 显示满了，`du` 算出来才占一半 | `lsof \| grep deleted` | `/proc/<pid>/fd` |
| `Too many open files` | `lsof -p`、`/proc/<pid>/limits` | `ulimit -n` |
| 磁盘 IO 慢 / `%wa` 高 | `iotop`、`pidstat -d` | `iostat -x`（§02） |
| 服务起不来报 IO 错 | `dmesg` | `mount`、`fsck` |

**对应关系反过来**：

- `df` 看容量
- `df -i` 看 inode
- `du` 看谁占
- `lsof` 看谁打开
- `iotop` / `pidstat -d` 看谁在 IO

新手最大的坑：**只看 `df` 不看 `df -i`**，导致 inode 满了的问题怎么也想不通。第二大坑：**`df` 和 `du` 数字对不上**怎么处理（被删的文件还被进程占着 fd）。

## 二、df：磁盘容量与 inode

### df -h

```
$ df -h
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p1  100G   85G   15G  85% /
/dev/nvme0n1p2  500G  480G   20G  97% /data
tmpfs           7.8G   12K  7.8G   1% /run
overlay         100G   85G   15G  85% /var/lib/docker/...
```

关键列：

- `Use%` —— 容量使用率。> 80% 偏紧，> 90% 危险（写日志的服务直接报错）
- `Avail` —— 还剩多少
- `Mounted on` —— 挂载点

**新手陷阱 1**：盯着 `/` 不看 `/data`。日志和数据通常在独立挂载点上，**根分区满了和数据盘满了是两类完全不同的问题**。要看所有分区。

**新手陷阱 2**：忘了 `tmpfs`。如果某个 `tmpfs`（内存盘）满了，可能影响系统功能（比如 `/run` 满了会让 systemd 异常）。

### df -i：inode 视图

```
$ df -i
Filesystem      Inodes  IUsed   IFree IUse% Mounted on
/dev/nvme0n1p1   6.3M   6.2M     100  100% /            ← 灾难
/dev/nvme0n1p2   32M    1.2M    31M     4% /data
```

**inode 满 = "磁盘上还剩很多空间，但创建新文件失败"**。

`No space left on device` 这个报错既可能是容量满，也可能是 inode 满，**新手以为只可能是容量**，于是删几个大文件——发现还是写不进，懵了。

什么场景容易耗 inode：

- **大量小文件**：日志切割成几亿个小文件、session 文件、缓存目录
- **PHP / Python session 文件目录**：每个 session 一个文件
- **`/tmp` 没清理**：临时文件累积
- **Maildir 邮件存储**：每封邮件一个文件
- **Cron 任务输出**：`/var/spool/mail/<user>` 累积成千上万

inode 总数在文件系统创建时就固定了（ext4 默认每 16KB 数据预留 1 个 inode），**没办法事后扩大**——只能删除文件释放，或者重建文件系统时指定 `mkfs.ext4 -N <number>`。

### 找出谁吃 inode

```bash
# 在某个目录下，看每个子目录文件数（包括递归）
for d in /var/*; do echo "$(find $d -xdev -type f 2>/dev/null | wc -l) $d"; done | sort -rn | head

# 更快但要 ncdu 工具
ncdu --inode /
```

`-xdev` = 不跨文件系统（不进入挂载点），避免 `find` 跑到 `/proc`、`/sys` 浪费时间。

## 三、du：找谁占了空间

`df` 看分区总量，**`du` 找具体目录占多少**。

```bash
du -sh /var/log              # 看 /var/log 总大小
du -sh /var/* | sort -h      # 看 /var 下每个子目录，按大小排序
du -sh /var/* 2>/dev/null | sort -h | tail -10   # 只看最大的 10 个
```

`-h` human readable，`-s` summary（只输出总和而不递归列每个文件），`sort -h` 按人类可读单位排序。

### 经典姿势：从根开始一层层下钻

```bash
# 1. 先看 /
du -sh /* 2>/dev/null | sort -h | tail
# 输出会指向某个目录（比如 /var 占 80G）

# 2. 进 /var
du -sh /var/* 2>/dev/null | sort -h | tail

# 3. 继续往下
du -sh /var/log/* 2>/dev/null | sort -h | tail

# 4. 最后定位到具体文件
ls -lhS /var/log/some-app/ | head
```

或者直接用 `ncdu`（交互式 disk usage 工具，超好用）：

```bash
ncdu /var          # 进入交互模式，方向键浏览
```

### find 找大文件

```bash
find / -xdev -type f -size +1G 2>/dev/null               # 找 > 1GB 的文件
find / -xdev -type f -size +100M -printf '%s %p\n' 2>/dev/null | sort -rn | head
```

`-xdev` 不跨文件系统。`-printf '%s %p\n'` 输出"字节数 路径"，便于排序。

### du 和 ls 数字不一样的小坑

```bash
$ ls -l file.log
-rw-r--r-- 1 root root 100M  Jan 15 file.log

$ du -h file.log
1.0K    file.log
```

这是**稀疏文件**——逻辑大小 100MB，但实际只占 1KB 磁盘块（中间是空洞）。Java 的某些库（比如 Lucene）会产稀疏文件。`du` 看的是物理占用，`ls -l` 看的是逻辑大小。

## 四、df 和 du 数字对不上：被删的文件还在占空间

线上经典坑：

```
$ df -h /var
/dev/sda2   500G  480G   20G  96%  /var

$ du -sh /var
240G    /var          ← 只用了一半？！
```

`df` 说占了 480G，但 `du` 加起来只有 240G——差出来的 240G **去哪了？**

答案：**有进程打开了文件，但文件被 `rm` 删了**。Linux 的 `rm` 只是解除目录项的链接（unlink），如果还有进程持有这个文件的 fd，**inode 不会释放，磁盘空间也不会回收**——文件已经从 `ls` 看不到了，但占用一直在，直到进程关闭 fd 或退出。

### 定位 SOP

```bash
# 1. 列出所有"已删除但还被打开"的文件
lsof | grep deleted

# 2. 按大小排序，找大头
lsof | grep deleted | awk '{print $7, $1, $2, $9}' | sort -rn | head

# 输出形如：
# 268435456 java 1234 /var/log/app.log.20251201 (deleted)
```

第一列是文件大小（字节），第二列进程名，第三列 PID，第九列文件路径。

### 紧急处理（不重启进程释放空间）

如果进程不能立刻重启，又必须立刻回收空间：

```bash
# 已知 PID=1234，删的是 fd=42
ls -l /proc/1234/fd/42        # 确认这就是那个文件
> /proc/1234/fd/42            # 把 fd 截断为 0 字节（清空文件内容）
```

`> /proc/<pid>/fd/<fd>` 这个技巧把已经被 `rm` 但还被打开的文件**就地清空**，磁盘空间立刻释放。**不要 `rm /proc/<pid>/fd/<fd>`，那是 fd 链接，删了会破坏进程**。

### 治本：进程要支持日志轮转

这种问题根因 99% 是**日志没正确轮转**：

- 应用直接写 `/var/log/app.log`
- 运维 `mv app.log app.log.old` + `rm app.log.old`，但应用没收到 SIGHUP，fd 还在写
- 旧文件被删了但永远释放不了

**正确做法**：用 `logrotate` + `copytruncate` 模式（或应用支持 SIGHUP 重开文件）：

```
# /etc/logrotate.d/myapp
/var/log/myapp/*.log {
    daily
    rotate 14
    compress
    copytruncate         ← 关键，复制后截断，不需要应用响应信号
    missingok
    notifempty
}
```

Java 应用建议直接用 Logback / Log4j2 的 RollingFileAppender，**应用自己控制轮转**，不依赖外部 logrotate。

## 五、lsof：句柄之王

`lsof` = list open files。在 Linux 里"一切都是文件"——普通文件、socket、pipe、设备、目录都是文件，所以 `lsof` 能看几乎所有句柄。

### 五个最常用姿势

```bash
lsof -p <pid>                  # 某个进程的所有句柄
lsof -i :8080                  # 谁占了 8080 端口
lsof -i tcp:8080               # 同上但限定 TCP
lsof <file>                    # 这个文件被谁打开了
lsof -u root                   # root 用户打开的所有文件
```

进阶：

```bash
lsof -p <pid> | wc -l                    # 进程句柄数（看是不是泄漏）
lsof -p <pid> -nP                        # 不解析 host 和 port（更快）
lsof -p <pid> | awk '{print $5}' | sort | uniq -c   # 按 fd 类型聚合：REG（文件）/ DIR / IPv4 / IPv6 / sock
lsof -nP -i                              # 看本机所有网络连接
lsof +D /var/log                         # 递归看某个目录下所有被打开的文件
```

### 输出列含义

```
$ lsof -p 1234 -nP | head
COMMAND   PID USER   FD   TYPE  DEVICE SIZE/OFF     NODE NAME
java     1234 root  cwd    DIR  259,1     4096  2097153 /opt/app
java     1234 root  txt    REG  259,1   100624  2097200 /usr/lib/jvm/.../bin/java
java     1234 root  mem    REG  259,1   8421376 2097250 /usr/lib/.../libjvm.so
java     1234 root    0u   CHR    1,3      0t0     1029 /dev/null
java     1234 root    1u   REG  259,1     1024  2097301 /var/log/app.log
java     1234 root    2u   REG  259,1     2048  2097302 /var/log/app.err
java     1234 root    3r   REG  259,1   524288  2097303 /opt/app/config.yaml
java     1234 root   42u  IPv4  812345      0t0      TCP 10.0.1.5:42384->10.0.2.8:3306 (ESTABLISHED)
```

- `FD` 列：
  - `cwd` 当前目录，`rtd` 根目录，`txt` 可执行文件，`mem` mmap 的文件
  - 数字（如 `0u`、`1u`、`42u`）= 真正的 fd 编号，`u` = 读写，`r` 只读，`w` 只写
  - 0/1/2 永远是 stdin/stdout/stderr
- `TYPE`：`REG`（普通文件）、`DIR`（目录）、`CHR`（字符设备）、`IPv4`/`IPv6`（socket）、`FIFO`（管道）、`sock`（unix socket）

### 直接用 /proc/<pid>/fd

`lsof` 调用慢（要扫所有进程），高负载机器上可能秒级阻塞。等价的快路径：

```bash
ls -l /proc/<pid>/fd | head           # 看 fd 列表
ls /proc/<pid>/fd | wc -l             # 数 fd 总数
```

输出：

```
lrwx------ 1 root root 64 May 13 14:32 0 -> /dev/null
lrwx------ 1 root root 64 May 13 14:32 1 -> /var/log/app.log
lrwx------ 1 root root 64 May 13 14:32 42 -> socket:[812345]
```

`/proc/<pid>/fd` 是 fd → 实际文件 / socket 的软链接，可以直接 `cat /proc/<pid>/fd/1` 看应用 stdout 输出（救命场景：忘了 `-Xloggc` 但需要看 GC 日志输出到了哪）。

## 六、Too many open files：句柄限制

最常见的报错之一：

```
java.net.SocketException: Too many open files
java.io.FileNotFoundException: ... (Too many open files)
```

意味着进程打开的 fd 达到了上限。

### 三个限制层级

Linux 的 fd 限制是**三层**的，从严到宽：

1. **系统级**：`/proc/sys/fs/file-max` —— 整机最大 fd 数（通常几百万）
2. **用户级**：`ulimit -n` 或 `/etc/security/limits.conf` —— 单用户的 soft / hard limit
3. **进程级**：`/proc/<pid>/limits` —— 进程实际生效的限制

排查时**只看进程级**——`/proc/<pid>/limits` 是当前进程真正受的限制：

```bash
cat /proc/1234/limits | grep "open files"
# Max open files            1024                 4096                 files
```

第一列 soft limit（实际生效）、第二列 hard limit（上限）。**1024 是默认值，对 Java 服务远远不够**。

### 看当前用了多少

```bash
ls /proc/<pid>/fd | wc -l               # 当前打开的 fd 数
lsof -p <pid> | wc -l                    # 同上但慢，且包含 cwd/rtd/txt 等"假 fd"
```

如果接近 `soft limit`，说明**马上要爆**或者**已经爆过**。

### 调高 limit 的正确姿势

**临时**（仅对当前 shell 启动的进程有效）：

```bash
ulimit -n 65536     # 临时
```

**永久 - 传统 init 系统**：

```bash
# /etc/security/limits.conf
*    soft   nofile  65536
*    hard   nofile  65536
root soft   nofile  65536
root hard   nofile  65536
```

需要重新登录生效。

**永久 - systemd**：

```ini
# /etc/systemd/system/myapp.service
[Service]
LimitNOFILE=65536
```

`limits.conf` 对 systemd 启动的服务**不生效**——很多新手踩过这个坑：明明改了 `limits.conf`，服务还是 1024。systemd 服务必须在 unit file 里写 `LimitNOFILE`。

**容器**：

```yaml
# Pod spec
spec:
  containers:
  - name: myapp
    securityContext:
      capabilities:
        add: ["SYS_RESOURCE"]
# 或者 K8s 节点上调内核参数 + Pod 内 ulimit
```

容器环境下 ulimit 还受 Docker / containerd 的 `default-ulimits` 影响，不一定能在容器内 `ulimit -n` 改。**Pod spec 是最干净的方式**。

### 看 fd 在干什么——区分泄漏类型

```bash
lsof -p <pid> -nP | awk '{print $5}' | sort | uniq -c | sort -rn
```

输出可能是：

```
12000  IPv4         ← 网络连接占大头，多半是 socket 没关
  500  REG          ← 普通文件，文件没关
  200  sock
   50  CHR
```

如果 `IPv4` 占大头 → 配合 `lsof -p <pid> | grep IPv4` 找连接对端，定位是哪个外部服务的 socket 没关。如果 `REG` 占大头 → 看是哪个目录的文件，定位代码层面没关流。

具体根因排查在 §17 展开。

## 七、iotop / pidstat -d：分进程的 IO

`iostat -x`（§02）告诉你"哪块盘忙"，`iotop` 告诉你"哪个进程在烧 IO"。

```bash
iotop -oP             # -o 只显示有 IO 的、-P 进程级（默认线程级）
iotop -bo -n 5        # 批处理 + 跑 5 次（脚本用）
```

输出：

```
Total DISK READ:    0.00 B/s | Total DISK WRITE:   45.20 M/s
  PID  PRIO  USER     DISK READ   DISK WRITE  SWAPIN  IO>   COMMAND
 1234  be/4 root      0.00 B/s    45.20 M/s   0.00 % 92.30 % java
 5678  be/4 root      0.00 B/s     1.20 M/s   0.00 %  2.10 % rsyslogd
```

`IO>` 列是该进程被 IO 阻塞的时间比例——**80%+ 表明这个进程已经被 IO 卡死**。

`pidstat -d 1` 是 iotop 的替代品，不依赖 root：

```
$ pidstat -d 1
   PID   kB_rd/s   kB_wr/s kB_ccwr/s  iodelay  Command
  1234      0.00  46285.30      0.00    1820  java
```

`iodelay` 是该进程被 IO 阻塞的时长（时钟数），高值 = 进程在等 IO。

### 看进程在读 / 写哪个文件

```bash
# 看进程正在做的系统调用
strace -p <pid> -e trace=read,write,open,close 2>&1 | head -50

# 看进程的 IO 累计统计
cat /proc/<pid>/io
```

`/proc/<pid>/io`：

```
rchar: 1820345600       ← 通过 read() 系统调用读的字节数（含 page cache 命中）
wchar: 982341230        ← write() 写的
read_bytes: 1024000     ← 真正从磁盘读的字节
write_bytes: 982300000  ← 真正写到磁盘的字节
cancelled_write_bytes: 0
```

**`read_bytes / wchar` 比值低 = cache 命中率高**；`write_bytes` 持续高增长 = 进程在拼命刷盘。

## 八、文件系统层异常

### dmesg —— 看内核事件

```bash
dmesg -T | tail -100                  # 看最近的内核消息（-T 显示时间）
dmesg -T | grep -i "error\|fail\|fault"
dmesg -T | grep -i "ext4\|xfs"        # 文件系统相关
dmesg -T | grep -i "io"
```

**关键模式**：

- `EXT4-fs error` / `XFS: corruption` → 文件系统损坏，立刻备份数据并 `fsck`（或重建）
- `Buffer I/O error on device sda` → 磁盘硬件错误前兆，**立刻迁移数据**
- `Out of memory: Kill process` → OOM Killer 出手，看是谁被杀
- `task XXX blocked for more than 120 seconds` → 进程在内核态卡住超过 2 分钟，多半是 IO hang

### 文件系统满载的另一种隐患：fragmentation

ext4 在容量 > 90% 时性能急剧下降（碎片化），xfs 好一些但也有影响。所以**线上分区使用率不要超过 80%**——不是因为容量本身不够，是因为再写下去性能会断崖。

### tmpfs / overlayfs 的特殊问题

- `tmpfs` 用内存，写满了会导致 OOM
- 容器的 `overlayfs` 写满了 = Docker 数据盘满了，所有容器都受影响

```bash
mount | grep -E 'tmpfs|overlay'    # 看挂载的 tmpfs 和 overlay
df -h | grep -E 'tmpfs|overlay'    # 看使用情况
```

## 九、典型组合姿势

### 姿势 1：磁盘满了告警

```bash
# 1. 看哪个分区
df -h

# 2. 是容量还是 inode
df -i

# 3. 容量满，定位大目录
du -sh /var/* 2>/dev/null | sort -h | tail
du -sh /var/log/* 2>/dev/null | sort -h | tail
# 或者 ncdu /var

# 4. 找大文件
find /var -xdev -type f -size +1G 2>/dev/null

# 5. df 和 du 数字对不上，看 deleted
lsof | grep deleted | awk '{print $7, $1, $2, $9}' | sort -rn | head

# 6. 找到 deleted 文件，紧急处理
> /proc/<pid>/fd/<fd>
```

### 姿势 2：inode 满了

```bash
# 1. 确认
df -i

# 2. 找哪个目录文件数多
for d in /var/* /tmp /home/*; do
  echo "$(find $d -xdev -type f 2>/dev/null | wc -l) $d"
done | sort -rn | head

# 3. 进入大头目录继续下钻
ls /var/spool/somewhere/ | wc -l
ls /tmp | wc -l

# 4. 删除
find /var/some-dir -xdev -type f -mtime +7 -delete    # 删 7 天前的
```

### 姿势 3：`too many open files`

```bash
# 1. 看进程当前 fd 数
ls /proc/<pid>/fd | wc -l

# 2. 看进程的 limit
cat /proc/<pid>/limits | grep "open files"

# 3. fd 类型分布，区分泄漏类型
lsof -p <pid> -nP | awk '{print $5}' | sort | uniq -c | sort -rn

# 4. 找泄漏方向
lsof -p <pid> -nP | grep IPv4 | head      # socket 泄漏
lsof -p <pid> -nP | grep REG | head       # 文件泄漏

# 5. 临时调高 limit（systemd 服务）
systemctl edit myapp
# [Service]
# LimitNOFILE=65536
systemctl daemon-reload && systemctl restart myapp

# 6. 治本：看代码（§17）
```

### 姿势 4：磁盘 IO 慢

```bash
# 1. iostat 看是哪块盘
iostat -x 1 3

# 2. iotop 看是哪个进程
iotop -oP

# 3. 进程内具体在干什么
cat /proc/<pid>/io
strace -p <pid> -e trace=read,write 2>&1 | head

# 4. dmesg 看有没有硬件错
dmesg -T | grep -i "io\|sda\|nvme"
```

## 十、几个常见反模式

| 反模式 | 正确做法 |
| --- | --- |
| 看到磁盘满只看 `df -h` 不看 `df -i` | 两个都看；`No space` 报错先排除 inode |
| `rm` 完大文件没看 `lsof \| grep deleted` | 文件被进程占着，空间不会释放；`> /proc/<pid>/fd/<fd>` 解决 |
| 改了 `/etc/security/limits.conf` 但 systemd 服务不生效 | systemd 服务必须在 unit file 里写 `LimitNOFILE` |
| Java 服务用默认 1024 fd | 至少 65536，建议 1048576（容器场景） |
| 日志靠 `mv` + `rm` 轮转 | 用 `logrotate copytruncate` 或应用层 Logback |
| 用 `lsof` 不加 `-n -P` | DNS 反查会卡住 lsof，永远加 `-n -P` |
| `du -sh /` 在 1TB 数据盘等十分钟 | 用 `ncdu` 交互式，或 `du -sh /var/*` 分目录看 |
| 看到 `task XXX blocked for more than 120 seconds` 直接重启 | 这是 IO hang 信号，多半磁盘有问题，先看 dmesg 和 SMART |
| 容器里改 `ulimit` 不生效就放弃 | 改 Pod spec 的 securityContext / Docker 的 default-ulimits |
| 直接 `fsck` 还在用的分区 | **会损坏数据**，必须先卸载或单用户模式 |

## 十一、磁盘健康监控

线上机器**应该**长期监控的指标：

| 指标 | 工具 / 来源 |
| --- | --- |
| 分区使用率 > 80% 告警 | Prometheus `node_filesystem_avail_bytes` |
| inode 使用率 > 80% 告警 | Prometheus `node_filesystem_files_free` |
| IO 等待 > 20% 告警 | Prometheus `node_cpu_seconds_total{mode="iowait"}` |
| 磁盘 SMART 状态 | `smartctl -a /dev/sda` |
| `dmesg` 关键错误 | Filebeat 抓 dmesg 上送 |

**SMART 是磁盘健康的早期预警**：

```bash
smartctl -a /dev/sda | grep -E "Reallocated|Pending|Uncorrectable|Power_On_Hours"
```

`Reallocated_Sector_Ct` 非零 = 已经有坏块在重映射；`Current_Pending_Sector` 非零 = 即将损坏的扇区。**任何一项持续增长就要准备换盘**。

## 十二、本章小结与下一步

### 小结

- 磁盘问题分四层：容量、inode、deleted 文件占用、IO 性能
- **`df -h` 和 `df -i` 都要看**——后者是新手最容易忘
- **`df` 显示满了 `du` 算不出来 = 有被删但被打开的文件**，`lsof | grep deleted` 找到，`> /proc/<pid>/fd/<fd>` 释放
- `lsof` 慢就用 `/proc/<pid>/fd` 直接看
- 句柄限制三层：系统 / 用户 / 进程，排查只看 `/proc/<pid>/limits`
- systemd 服务的 `LimitNOFILE` 在 unit file 里，**`limits.conf` 不生效**
- `iotop -oP` 找谁在烧 IO，`/proc/<pid>/io` 看进程级 IO 统计
- 监控分区使用率不能等满了再告警，**80% 就该警**

### 与后面章节的衔接

- §05 Java 进程现场工具 —— `jstack` / `jmap` / Arthas，是 Java 线程 / 堆 / Native 排障的入口
- §16 磁盘问题专题 —— 这一章工具落到具体场景：写满怎么止血、日志暴写怎么治、文件系统损坏怎么处理
- §17 文件句柄泄漏专题 —— Java 应用句柄泄漏的根因清单、Netty / HttpClient / JDBC 常见坑

### 留给下一章的问题

- §05 把"OS 层工具地图"切换到"JVM 层工具地图"——`jps` / `jstack` / `jmap` / `jcmd` / Arthas / async-profiler，分别在什么场景用？为什么 `jstack` 会触发 STW？怎么避免？

---

## 未定问题清单

- 是否单独写一节 **`strace` / `ltrace` 详解**？这一章浅提了 `strace`，但实战中 `strace -f -e trace=...` 的高级用法值得展开。倾向放在 §05 末尾"老司机进阶"附近，或者作为 §07/§09 的工具补充。
- 文件系统调优（ext4 vs xfs 选型、`noatime` 挂载、`barrier` 等）是否要单独讲？对 Java 后端价值不大，倾向跳过；如果你跑大量 IO 密集型业务（搜索引擎 / 日志写入服务）再补。

---

写完了。请确认这一章的组织和深度，以及上面两个未定问题如何选择。确认后进入 §05 Java 进程现场工具。
