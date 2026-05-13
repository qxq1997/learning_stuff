# 网络排查工具：ss、tcpdump、TCP 状态机与抓包

## 这一章想解决什么

网络问题是线上故障里**最难定位、看起来最玄学**的一类——因为它跨多台机器、跨多层（应用 / TCP / IP / 物理），还有一堆 OS 内核参数和路由器配置在中间。

很多工程师网络排障停留在三招："ping 一下"、"`netstat | grep ESTAB` 看连接数"、"重启大法"。再往下就不会了。

这一章解决三件事：

1. **TCP 状态机必须烂熟于心**——线上 90% 的网络问题都跟 `CLOSE_WAIT`、`TIME_WAIT`、`SYN_SENT` 这些状态有关，看不懂状态机就在瞎猜
2. **`ss` / `tcpdump` / `dig` 三件套**——分别对应"看连接"、"抓包看协议细节"、"看 DNS"，覆盖 95% 网络排障入口
3. **典型问题的诊断 SOP**——CLOSE_WAIT 堆积、TIME_WAIT 堆积、连接超时、DNS 抖动各自的查法

这一章是**工具地图章**。具体问题专题（CLOSE_WAIT 堆积根因、TIME_WAIT 是否要消灭、DNS 抖动）在 §15 展开。

## 一、TCP 状态机：排障前的必修课

### 11 个状态总览

```
                                    +---------+
                                    |  CLOSED |
                                    +---------+
                                    |    ^
                  passive open      |    |  close (Server side)
                                    v    |
                                +-----------+
                                |  LISTEN   |
                                +-----------+
                                  |    |
                  recv SYN       |    | send SYN (active open)
                  send SYN+ACK   v    v
                            +-----------+         +-----------+
                            | SYN_RCVD  |         | SYN_SENT  |
                            +-----------+         +-----------+
                                  |  recv ACK         | recv SYN+ACK
                                  v  send -           | send ACK
                            +-------------------------+
                            |       ESTABLISHED       |
                            +-------------------------+
            close (主动关) /     |                |  recv FIN (被动关)
            send FIN             v                v  send ACK
                            +-----------+     +-------------+
                            | FIN_WAIT1 |     | CLOSE_WAIT  |  ← 被动关方进入
                            +-----------+     +-------------+
                                  |                    | close（业务调用 close()）
                                  | recv ACK           v send FIN
                                  v               +-------------+
                            +-----------+         |  LAST_ACK   |
                            | FIN_WAIT2 |         +-------------+
                            +-----------+              | recv ACK
                                  | recv FIN           v
                                  v send ACK      +----------+
                            +-----------+         |  CLOSED  |
                            | TIME_WAIT |  ←      +----------+
                            +-----------+    主动关方进入
                            等 2*MSL
                            后 → CLOSED
```

### 排障要重点关注的 4 个状态

| 状态 | 谁进入 | 出现大量堆积通常意味着 |
| --- | --- | --- |
| `SYN_SENT` | 客户端发完 SYN 没收到 SYN+ACK | **服务端不可达 / 防火墙拦截 / 服务端 SYN backlog 满** |
| `SYN_RECV`（也叫 SYN_RCVD） | 服务端收 SYN 但没等到 ACK | **SYN flood 攻击 / 客户端到服务端的回程不通** |
| `CLOSE_WAIT` | **被动关闭方**收到了对方的 FIN，但**自己业务还没调 `close()`** | **业务代码 bug**——拿到连接没释放，泄漏 |
| `TIME_WAIT` | **主动关闭方**完成四次挥手后进入，等 2*MSL（默认 60s） | **短连接 + 客户端主动关**——本身正常，但量大会耗端口 |

**这 4 个状态记牢，足够覆盖 80% 的连接类网络故障。**

### 主动关 / 被动关的关键区分

四次挥手哪一方先 `close()` 就是主动关方：

- **主动关方** 走 `FIN_WAIT_1 → FIN_WAIT_2 → TIME_WAIT → CLOSED`
- **被动关方** 走 `CLOSE_WAIT → LAST_ACK → CLOSED`

**TIME_WAIT 和 CLOSE_WAIT 永远不会同时在一台机器上对同一个连接出现**——它们在四次挥手的对端。所以看到自己机器上 TIME_WAIT 多 = 自己是主动关方；看到自己机器上 CLOSE_WAIT 多 = 自己是被动关方。

### TIME_WAIT 为什么要等 2*MSL

MSL（Maximum Segment Lifetime）= 报文在网络上的最大生存时间，Linux 默认 60s（写死，不能改）。`TIME_WAIT` 状态等 2*MSL = 120s（实际多数发行版是 60s，看 `cat /proc/sys/net/ipv4/tcp_fin_timeout`——这其实是 FIN_WAIT_2 超时，TIME_WAIT 是写死 60s）。

为什么要等：

1. **让最后一个 ACK 确实送达对端**——如果丢了，对端会重传 FIN，主动关方还能再回 ACK
2. **防止旧连接的迷途数据包**串到新连接（同样的四元组立刻被复用，老数据包恰好到达，会造成错乱）

**TIME_WAIT 是 TCP 协议的正确行为**，新手第一反应是"我要消灭它"——错，先理解 §15 里讲的"在什么场景下它确实是问题"再决定要不要调参数。

## 二、ss：现代的 netstat

`netstat` 在新版本 Linux 上已经被标记为过时（`net-tools` 包），`ss`（`iproute2` 包）是替代品，更快、更细。**新机器一律用 `ss`**。

### ss 最常用的 5 个组合

```bash
ss -tnp                # TCP / 数字端口 / 显示进程
ss -tnap               # 上面 + 所有状态（包括 LISTEN、TIME_WAIT 等）
ss -tnp state time-wait | wc -l    # TIME_WAIT 数量
ss -tnp state close-wait           # CLOSE_WAIT 列表（看是哪个进程在泄漏）
ss -s                  # 汇总统计（一行看完所有状态分布）
ss -tnpi               # 加 -i 看每个连接的 RTT / cwnd / 重传等内核内部统计
ss -lntp               # 看本机所有 listen 端口及进程
```

### 关键列含义

```
$ ss -tnp
State    Recv-Q  Send-Q  Local Address:Port    Peer Address:Port   Process
ESTAB    0       523     10.0.1.5:42384        10.0.2.8:3306       users:(("java",pid=1234,fd=128))
ESTAB    0       0       10.0.1.5:8080         10.0.5.20:51200     users:(("java",pid=1234,fd=145))
```

| 列 | 含义 |
| --- | --- |
| `State` | TCP 状态 |
| `Recv-Q` | **关键**：已收到但应用还没读走的字节数。**ESTAB 状态下持续非零** = 应用读慢 / 读卡住（CPU 高 / GC / 死锁） |
| `Send-Q` | **关键**：已发送但对端还没 ACK 的字节数。持续非零 + 涨 = 对端处理慢 / 网络丢包重传 |
| `Local / Peer Address` | 四元组的本端 / 对端 |
| `Process` | 进程信息（`-p` 才有） |

**ESTAB 状态下的 Recv-Q / Send-Q 是诊断"为什么连接慢"的重要线索**：

- Recv-Q 高 = 我读慢了（业务应用问题）
- Send-Q 高 = 我发出去对方收不及（网络或对端问题）

`LISTEN` 状态下含义不同：

- `Recv-Q` = 全连接队列当前长度（accept queue）
- `Send-Q` = 全连接队列上限（backlog）

`Recv-Q` 接近 `Send-Q` 时，说明应用 `accept()` 慢，新连接快被拒了——常见于线程池被 GC / 锁拖住。

### ss -s 一眼看分布

```
$ ss -s
Total: 1820
TCP:   1605 (estab 423, closed 980, orphaned 0, timewait 980)

Transport Total     IP        IPv6
RAW       0         0         0
UDP       8         8         0
TCP       625       625       0
INET      633       633       0
FRAG      0         0         0
```

关键看 `timewait` 数字。`estab` 是当前正常活跃连接数。如果 `closed` 一直涨，说明短连接频繁。

### ss -tnpi 看连接内部细节

```
$ ss -tnpi
ESTAB 0 0 10.0.1.5:42384 10.0.2.8:3306 users:(("java",pid=1234,fd=128))
   cubic wscale:7,7 rto:204 rtt:3.456/1.2 ato:40 mss:1448 cwnd:10 ssthresh:7
   bytes_acked:2384721 segs_out:1820 segs_in:1750 send 33.5Mbps lastsnd:24 lastrcv:24
```

关键字段：

- `rtt` —— 当前 RTT（毫秒）。线上常态 < 5ms（同机房）/ < 50ms（跨机房）/ < 100ms（跨地域）。突然飙到 100ms+ 而对端不变，多半是网络抖动
- `cwnd` —— 拥塞窗口大小（MSS 数）。频繁丢包会让它一直长不大
- `retrans` —— 重传次数（有些版本叫 `lost`），**非零持续累计 = 在丢包**
- `rto` —— 重传超时（毫秒）
- `send` —— 估算的发送速率

排查 RT 抖动时，对可疑连接跑 `ss -tnpi` 看 `rtt` 和 `retrans` 是非常直接的证据。

## 三、netstat：老但还广泛在用

很多老镜像没 `ss`，只有 `netstat`。常用对照：

| netstat | ss 等价 |
| --- | --- |
| `netstat -anp` | `ss -anp` |
| `netstat -tnlp` | `ss -tnlp` |
| `netstat -s` | `ss -s`（信息不完全等价，`netstat -s` 给的协议层统计更细） |

**`netstat -s` 还是有不可替代的价值**——它列出从开机以来累积的 TCP / IP / UDP 协议层异常计数：

```
$ netstat -s | grep -i retr
    8429 segments retransmitted
    Retransmit timer expired
    134 fast retransmits
```

```
$ netstat -s | grep -i listen
    523 times the listen queue of a socket overflowed     ← accept queue 溢出
    523 SYNs to LISTEN sockets dropped                    ← SYN 被丢
```

`listen queue overflowed` 出现且持续涨 = backlog 不够大或应用 `accept()` 跟不上，**接口会出现连接被 reset 或建连失败**。处理：调大 `net.core.somaxconn` 和 `net.ipv4.tcp_max_syn_backlog`，并查应用是不是卡住。

`netstat -s` 输出长达上百行，重点 grep 这些关键词：

- `retransmit` / `retrans` —— 重传
- `listen` —— 监听队列
- `dropped` / `drop` —— 丢包
- `reset` —— RST
- `out-of-order` —— 乱序

## 四、CLOSE_WAIT 堆积——业务 bug 的指纹

线上看到 CLOSE_WAIT 一两百个，是最常见的网络问题之一。机制：

1. 对端（比如 DB）主动关闭连接，发 FIN 过来
2. 内核回 ACK，连接进入 `CLOSE_WAIT`
3. **业务代码应该调用 `close()`**——这一步没做
4. 连接永远卡在 `CLOSE_WAIT`，直到进程退出

**CLOSE_WAIT 持续涨 = 业务代码有连接没关——一定是代码 bug**。

### 定位 SOP

```bash
# 1. 看 CLOSE_WAIT 数量
ss -tnp state close-wait | wc -l

# 2. 看是哪个进程
ss -tnp state close-wait

# 3. 看是连到哪个对端（多半是 DB / Redis / 下游服务）
ss -tnp state close-wait | awk '{print $4}' | sort | uniq -c | sort -rn

# 4. 看具体哪些 fd 在 CLOSE_WAIT
lsof -p <pid> | grep CLOSE_WAIT
```

**根因清单**（按概率排序）：

1. **连接池配置错**：没设 `validateOnBorrow` / `testWhileIdle`，对端关了池子里的连接但没感知
2. **Try-catch 包住 close()**：异常路径里没释放
3. **缺 finally 块**：业务异常时 `connection.close()` 没走到
4. **第三方库 bug**：某些老版本 HttpClient / 数据库驱动有连接泄漏
5. **代码就是忘了关**

修复后 CLOSE_WAIT 数应该回到 0–个位数。线上预警阈值建议 50。

### 紧急止血

如果业务卡住但短期改不了代码：

- **重启进程**：CLOSE_WAIT 会全部释放（最快但要选时机）
- **缩短上游侧的 keepalive 间隔**：让连接被动死掉更快——但这不解决根因

## 五、TIME_WAIT 堆积——通常不是问题

线上看到 TIME_WAIT 一两万，新手第一反应"我要消灭它"。**先冷静**——TIME_WAIT 是 TCP 的正常状态。

### 什么时候 TIME_WAIT 真的是问题

**只有一种场景**：你机器**作为客户端**用大量短连接连同一对端，**且本地端口耗尽**。

- 客户端能用的端口范围：`/proc/sys/net/ipv4/ip_local_port_range`，默认 32768–60999，约 2.8 万
- 每个 `(本地IP, 本地端口, 对端IP, 对端端口)` 四元组占一个端口
- 如果你高频去连同一个 `(对端IP, 对端端口)`，本地端口 60s 内回收不了，约 460 QPS 就会跑光

**真正的问题表现**：`netstat -s | grep -i "TCP: time wait"` 或日志里出现 `Cannot assign requested address`（errno EADDRNOTAVAIL）。

**没看到上面这两个信号，TIME_WAIT 几万都不是问题，不要瞎调内核参数。**

### 真要解决的方案

1. **改用长连接 / 连接池**——根本解法，让连接复用而不是建-断-建
2. `net.ipv4.tcp_tw_reuse = 1` —— 安全的复用，要配合 `tcp_timestamps = 1`（默认开）。Linux 4.12+ 默认行为已经较好
3. ~~`net.ipv4.tcp_tw_recycle`~~ —— **NAT 环境下会出大问题**，Linux 4.12+ 已经移除这个参数。**永远不要用**
4. 调大 `ip_local_port_range`，比如 `1024 65535` —— 治标，但加倍端口数总是好的
5. **服务端永远不用调 TIME_WAIT**——因为是客户端先 `close()` 才有 TIME_WAIT，服务端通常被动关，是 CLOSE_WAIT 那边的问题

### 谁主动关谁倒霉

记住口诀：**TIME_WAIT 留在主动关方**。

- HTTP 短连接，**客户端** `Connection: close` → 客户端 TIME_WAIT
- HTTP 短连接，**服务端**主动 close → 服务端 TIME_WAIT（NGINX 默认就是这样，要看 keepalive 配置）
- 微服务 RPC 短连接，谁先关谁倒霉

**所以"服务端开启长连接"是从源头消除 TIME_WAIT 的最佳实践**。

## 六、端到端连通性测试

排障要快速回答"我这边能不能连到对方"，工具阶梯：

### ping —— 只能验证 ICMP 通

```bash
ping -c 4 10.0.2.8       # 发 4 个包就停
ping -i 0.2 10.0.2.8     # 0.2 秒间隔（高频）
ping -s 1400 10.0.2.8    # 大包测试，看 MTU
```

**ping 通不等于 TCP 通**——很多机房禁 ICMP，ping 不通不代表服务挂了。所以下一阶梯：

### telnet / nc —— 验证 TCP 端口能否建连

```bash
telnet 10.0.2.8 3306                # 老牌，但容器里常不装
nc -vz 10.0.2.8 3306                # 推荐，-z 不发数据只测建连
nc -vzw 3 10.0.2.8 3306             # -w 3 加 3 秒超时
```

`Connected` = TCP 三次握手成功，服务端口活着。`Connection refused` = 服务没监听这个端口或被防火墙拒。`Connection timed out` = 包发出去石沉大海（防火墙 drop / 路由不通 / 对端拥塞）。

### curl -v —— 验证应用层 HTTP

```bash
curl -v https://api.example.com/health
curl -v -H "Host: api.example.com" http://10.0.2.8/health    # 直连 IP 但指定 Host
curl -v --resolve api.example.com:443:10.0.2.8 https://api.example.com/health  # 绕过 DNS
curl -w "@curl-format.txt" -o /dev/null -s https://api.example.com/health
```

`-w` 配合格式文件能输出各阶段耗时：

```
# curl-format.txt
time_namelookup:  %{time_namelookup}s
time_connect:     %{time_connect}s
time_appconnect:  %{time_appconnect}s   (TLS 握手)
time_starttransfer: %{time_starttransfer}s  (首字节)
time_total:       %{time_total}s
```

这套输出是"分阶段定位 HTTP 慢在哪里"的杀手锏：DNS 慢 → `time_namelookup` 大；TCP 慢 → `time_connect` 大；TLS 慢 → `time_appconnect - time_connect` 大；后端处理慢 → `time_starttransfer - time_appconnect` 大。

### traceroute / mtr —— 看中间路径

```bash
traceroute 10.0.2.8       # 看每一跳路由
mtr 10.0.2.8              # 持续测，能看丢包率（推荐）
mtr --tcp --port 3306 10.0.2.8   # 用 TCP 探测，绕过禁 ICMP 的网络
```

`mtr` 输出每一跳的丢包率和延迟。如果**某一跳丢包率高，下一跳起又恢复**，说明是这一跳的中间路由器丢的；**最后一跳丢 = 对端机器丢**。

## 七、DNS 排查

DNS 抖动是接口 P99 突刺的常见隐藏元凶——95 分位看不出来，但 P99 / P999 全是 DNS 慢。

### dig —— 标准查 DNS 工具

```bash
dig api.example.com                       # 默认查 A 记录
dig api.example.com @8.8.8.8              # 指定 DNS 服务器
dig +short api.example.com                # 只输出 IP
dig +trace api.example.com                # 看完整解析路径（从根到权威）
dig -x 10.0.2.8                           # 反向解析
dig api.example.com +stats                # 看耗时
```

`dig` 输出的 `Query time` 列是 DNS 查询耗时——线上应该 < 5ms（命中本地缓存）/ < 50ms（命中递归服务器缓存）。**如果 `Query time > 200ms`，说明 DNS 解析慢，对接口 RT 直接拉高**。

### nslookup —— 简化版

```bash
nslookup api.example.com
```

用 `dig` 就行，`nslookup` 信息少且已过时。

### Linux DNS 缓存的真相

**Linux 默认 glibc 不缓存 DNS**——每次 `getaddrinfo()` 都会走一次完整查询。这就是为什么 Java 应用首次访问域名总是慢。

缓解方式：

1. **JVM 层**：`networkaddress.cache.ttl` 控制 JVM 内部 DNS 缓存时长（默认 30s，永久缓存是 -1）
2. **OS 层装 nscd / systemd-resolved / dnsmasq**：本地 DNS 缓存
3. **改用 IP 直连**（容器/微服务通过服务发现拿 IP）

### DNS 排查 SOP

```bash
# 1. 配置看一眼
cat /etc/resolv.conf

# 2. 直接查目标域名，看是否解析正常
dig api.example.com +short

# 3. 看耗时
dig api.example.com +stats | grep "Query time"

# 4. 看完整路径，找慢在哪一层
dig api.example.com +trace

# 5. 看本机缓存（如装了 systemd-resolved）
systemd-resolve --statistics
```

线上常见坑：`/etc/resolv.conf` 写了一个挂掉的 DNS 服务器，默认 5 秒超时，每次请求多 5 秒——业务 RT 直接爆炸。

## 八、tcpdump：抓包分析

前面的工具看不到协议细节，最终大招是 `tcpdump`。会用 `tcpdump` 是后端工程师的分水岭。

### 抓包基本语法

```bash
tcpdump -i any -nn -tttt 'tcp port 3306 and host 10.0.2.8'
```

- `-i any` 所有网卡（容器 / 多网卡机器很重要）
- `-i eth0` 指定网卡
- `-nn` 不解析 IP / 端口为名字（不查 DNS、不查 `/etc/services`，避免抓包过程被反查 DNS 拖慢）
- `-tttt` 完整时间戳（带日期）
- `-vv` 更详细输出
- `-c 100` 抓 100 个包就停
- `-s 0` 抓完整包（默认 262144 字节够了，老版本默认 96 字节只抓头）
- `-w cap.pcap` 写到文件（**生产抓包标配**，事后用 Wireshark 看）
- `-r cap.pcap` 读 pcap 文件

过滤表达式（BPF 语法）：

```bash
'tcp'                            # 只抓 TCP
'host 10.0.2.8'                  # 该 IP 的所有包（双向）
'src host 10.0.2.8'              # 该 IP 发出的
'dst port 3306'                  # 目的端口
'tcp port 3306 and host 10.0.2.8'
'tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) != 0'   # 只抓 SYN/FIN/RST 等控制包
'tcp[tcpflags] & tcp-rst != 0'   # 只抓 RST
```

### 抓 TCP 握手

```bash
tcpdump -i any -nn 'tcp port 3306 and (tcp-syn|tcp-ack) != 0' -c 10
```

正常握手三次：

```
14:32:01.123 IP 10.0.1.5.42384 > 10.0.2.8.3306: Flags [S], seq 1000   ← SYN
14:32:01.124 IP 10.0.2.8.3306 > 10.0.1.5.42384: Flags [S.], seq 5000, ack 1001  ← SYN+ACK
14:32:01.124 IP 10.0.1.5.42384 > 10.0.2.8.3306: Flags [.], ack 5001    ← ACK
```

`[S]` = SYN，`[S.]` = SYN+ACK（`.` 是 ACK 标记），`[F]` = FIN，`[R]` = RST，`[P]` = PSH，`[.]` = 纯 ACK。

### 抓 RST（连接被重置）

```bash
tcpdump -i any -nn 'tcp[tcpflags] & tcp-rst != 0'
```

看到 RST 频繁出现：

- **客户端发 RST** = 客户端"暴力关连接"（多半是连接池销毁 / SO_LINGER 设了 0）
- **服务端发 RST** = 服务端拒绝（端口没监听 / 数据包发到了一个已经关掉的连接 / iptables drop）

### 抓重传

```bash
# 配合 -v 看 seq / ack 编号，能识别重复 seq
tcpdump -i any -nn -v 'tcp port 3306'
```

更直接是 `ss -tnpi` 看 `retrans`，或 `netstat -s | grep retrans`。

### 生产环境抓包的注意事项

1. **永远先用 `-w` 写文件，事后 Wireshark 分析**——直接命令行看包看几条就晕
2. **过滤条件越精确越好**——`tcpdump -i any` 不加 filter 在大流量机器上会瞬间生成 GB 级文件
3. **`-s 0` 抓完整包**——但写盘大，根据带宽估算
4. **抓包本身有性能开销**——大流量机器开 `tcpdump` 可能让 CPU 涨 5%–10%
5. **`-i any` 在 Linux 上是 cooked 模式**，看不到 MAC 地址（无所谓，但要知道）
6. **抓完用 `editcap` 切割**，便于 Wireshark 打开大文件：`editcap -c 10000 big.pcap split.pcap`

### Wireshark 关键技巧

- 加载 pcap 后，过滤栏：`tcp.stream eq 5` —— 只看某一个 TCP 流（流编号从 0 开始）
- 右键某个包 → Follow → TCP Stream，看完整数据交互
- `tcp.analysis.retransmission` —— 过滤所有重传包
- `tcp.flags.reset == 1` —— 过滤所有 RST
- Statistics → Conversations → TCP，看连接级统计（包数、字节数、持续时间）
- Statistics → I/O Graph，画流量曲线

## 九、流量带宽工具

`iftop` —— 实时看每个连接的带宽：

```bash
iftop -i eth0
iftop -nNP    # n 不解析 host、N 不解析 port、P 显示 port
```

`nload` —— 单网卡整体带宽：

```bash
nload eth0
```

`sar -n DEV 1` —— 看每秒收发字节、包数：

```
14:32:01     IFACE   rxpck/s   txpck/s    rxkB/s    txkB/s
14:32:02     eth0   12453.0   11250.0   8420.50   7820.30
```

`ethtool` —— 看网卡硬件信息和统计：

```bash
ethtool eth0                  # 看速率、双工、连接状态
ethtool -S eth0               # 看网卡硬件级统计（rx_dropped、tx_errors 等）
ethtool -g eth0               # 看 ring buffer 大小
```

`ethtool -S` 输出的 `rx_dropped`、`rx_no_buffer_count`、`tx_dropped` 持续涨 = 网卡 ring buffer 太小或软中断处理不及。处理：调大 ring buffer（`ethtool -G eth0 rx 4096 tx 4096`），开 RPS / RSS 分散软中断。

## 十、典型组合姿势

### 姿势 1：接口超时，怀疑网络

```
1. ping <对端 IP>                # 验证 ICMP 通
2. nc -vz <对端 IP> <端口>        # 验证 TCP 端口能建连
3. curl -v -w "@curl-format.txt" <URL>   # 看 HTTP 各阶段耗时
4. mtr --tcp --port <端口> <对端 IP>     # 看路径丢包
5. ss -tnpi | grep <对端 IP>     # 看现有连接的 RTT / 重传
```

### 姿势 2：CLOSE_WAIT 一直涨

```
1. ss -tnp state close-wait | wc -l   # 数量
2. ss -tnp state close-wait | awk '{print $4}' | sort | uniq -c   # 按对端聚合
3. lsof -p <pid> | grep CLOSE_WAIT    # 看具体 fd
4. jstack <pid> > /tmp/jstack.log     # 看 Java 栈，找连接管理代码
```

→ 根因排查见 §15。

### 姿势 3：TIME_WAIT 几万，但要先确认是不是问题

```
1. ss -s                               # 看 TIME_WAIT 总数
2. netstat -s | grep -i "TCP: time wait"   # 看是否有溢出
3. dmesg | grep -i "time-wait"         # 看内核告警
4. 业务日志 grep "Cannot assign requested address"   # 确认是否真的端口耗尽
```

没有 4 的日志和 2 的溢出，TIME_WAIT 几万就不是问题，不要乱调内核参数。

### 姿势 4：怀疑 DNS 慢

```
1. cat /etc/resolv.conf                # 看配置的 DNS
2. dig api.example.com +stats          # 看 Query time
3. dig api.example.com @<另一个 DNS>   # 横向对比
4. tcpdump -i any -nn 'port 53'        # 抓 DNS 包，看是不是丢
```

### 姿势 5：怀疑某个 TCP 流有问题（高级）

```
1. tcpdump -i any -nn -s 0 -w cap.pcap 'host <对端 IP> and port <端口>'
2. （等问题复现几分钟）Ctrl+C
3. scp cap.pcap 到本地
4. Wireshark 打开，过滤 tcp.stream eq N
5. 看 retransmission、Zero Window、Dup ACK
```

## 十一、几个常见反模式

| 反模式 | 正确做法 |
| --- | --- |
| 看到 TIME_WAIT 多就调 `tcp_tw_recycle` | **永远不要用 `tcp_tw_recycle`**，看本章第五节 |
| ping 不通就说"网络坏了" | ICMP 经常被禁，用 `nc -vz` 才是 TCP 层验证 |
| `tcpdump -i any` 不加过滤 | 生产机器秒生成 GB 文件，永远加 BPF filter |
| Wireshark 直接看几 GB 包 | 用 `editcap -c` 切割，或者 `tshark` 命令行预过滤 |
| 排查 CLOSE_WAIT 只重启进程 | 重启是止血，根因是代码连接泄漏 |
| 用 `netstat -anp` 在百万连接的机器上 | 慢得像狗，用 `ss` |
| DNS 慢只查 `dig` 不看 resolv.conf | DNS 配错（写了个挂的 DNS 服务器）是最常见原因 |
| 抓包看不懂直接放弃 | 抓 pcap 文件保存下来，慢慢分析或拉熟悉的人看 |
| 怀疑网络但没有数据 | 必须给出 `mtr` / `tcpdump` / `ss -i` 三选一证据 |

## 十二、本章小结与下一步

### 小结

- TCP 状态机的 4 个状态必背：`SYN_SENT`、`CLOSE_WAIT`、`TIME_WAIT`、`ESTAB`
- **TIME_WAIT 是正常状态，大多数情况不需要消灭**
- **CLOSE_WAIT 持续涨一定是业务 bug**，连接没关
- `ss` 替代 `netstat`，但 `netstat -s` 看协议层统计还是有用
- `ss -tnpi` 看连接级 RTT / 重传，是 RT 抖动排障的杀手锏
- `curl -w` 加阶段计时是分段定位 HTTP 慢的标准方法
- `dig +stats` 看 DNS 耗时，DNS 是 P99 突刺的常见隐藏元凶
- `tcpdump -w` 写文件，事后 Wireshark 分析；现场看包永远要加过滤
- ICMP 通不等于 TCP 通，TCP 通不等于应用层通——分层验证

### 与后面章节的衔接

- §04 文件、磁盘、句柄 —— `lsof` 这一章会用到，但更系统地展开
- §15 网络问题专题 —— 把这一章的工具用到具体场景：CLOSE_WAIT 根因分析、TIME_WAIT 真问题判断、DNS 抖动复盘
- §09 接口 RT 抖动 —— 网络层这一段的拆解会用到 `ss -tnpi`、`curl -w`、`mtr`

### 留给下一章的问题

- 服务起不来报 `too many open files`——除了句柄，还要看什么？这是 §04 文件、磁盘、句柄的主题
- `lsof` 输出怎么读？`lsof -p` 和 `lsof -i` 的区别？

---

## 未定问题清单

- 是否要单独写一节 **eBPF 网络观测**（`tcplife`、`tcpretrans`、`tcpconnect`）？比 `tcpdump` 高效得多，但学习曲线陡。倾向作为 §05 / §15 的附录提一下。
- TLS 握手抓包是否要单独讲？如果业务在做 TLS 性能优化（mTLS、握手缓存）这部分有价值，否则可以省略。

---

写完了。请确认这一章的组织、深度、以及上面两个未定问题如何选择。确认后进入 §04 文件、磁盘、句柄。
