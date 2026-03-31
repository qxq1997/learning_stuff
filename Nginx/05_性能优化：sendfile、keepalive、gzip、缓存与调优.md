# Nginx - 第 5 课：性能优化：sendfile、keepalive、gzip、缓存与调优

## 学习目标（本节结束后你能做到什么）

- 理解 Nginx 优化不是“开几个开关”，而是在优化不同链路段的资源消耗。
- 说清楚 `sendfile`、零拷贝、`tcp_nopush`、`tcp_nodelay` 的意义。
- 理解客户端到 Nginx、Nginx 到后端两段 keepalive 的价值和区别。
- 掌握 gzip、缓存、worker 参数、文件描述符上限等常见优化点。
- 能以“瓶颈在哪里”为主线，形成一套更像工程实践的优化思路。

## 内容讲解（核心概念，用类比、例子、图示说清楚）

### 1. 性能优化的前提：先知道你在优化哪一段

一个请求从进入 Nginx 到返回，可能经过这些环节：

- TCP 连接建立
- 读取请求
- 匹配配置
- 访问磁盘或代理后端
- 发送响应

所以所谓优化，并不是永远盯着 Nginx 自己，而是看瓶颈在哪一层：

- 如果静态资源很多，磁盘与网络发送路径更关键
- 如果代理请求很多，连接复用与后端连接管理更关键
- 如果出口带宽有限，压缩和缓存更关键
- 如果大量连接堆积，worker 数量、连接数、文件描述符上限更关键

先有这个“按链路分段思考”的意识，优化才不会流于口号。

### 2. `sendfile` 和零拷贝

假设 Nginx 要把一个静态文件发给客户端，如果没有 `sendfile`，数据路径通常更像这样：

```text
磁盘 -> 内核缓冲区 -> 用户态缓冲区(Nginx) -> 内核缓冲区 -> 网卡
```

这意味着：

- 数据被多次拷贝
- 用户态和内核态之间有额外切换

但对于静态文件来说，Nginx 本身并不需要修改内容，它只是搬运工。所以更高效的方式是让内核直接把数据从文件发送到套接字。

这就是 `sendfile` 想做的事：

```nginx
sendfile on;
```

所谓零拷贝，严格讲不是“绝对零次复制”，而是**尽量减少无意义的数据拷贝和上下文切换**。面试里这么回答更稳。

### 3. `tcp_nopush` 和 `tcp_nodelay`

这两个指令经常成对出现，看起来像矛盾，其实针对的是不同阶段。

#### `tcp_nopush`

倾向于把数据攒一攒，尽量凑满包再发，减少小包数量。

适合：

- 发较大的静态文件
- 配合 `sendfile`

#### `tcp_nodelay`

表示有数据就尽快发，不要等。

适合：

- 小响应
- 实时性更敏感的交互

Nginx 常见实践是两者一起开，但你脑中要理解它们在不同阶段作用不同，而不是机械抄模板。

### 4. keepalive：连接复用远比你想象的重要

TCP 建连和断连是有成本的。高并发下，如果每次请求都新建连接，系统会付出大量额外开销。

#### 4.1 客户端到 Nginx 的 keepalive

```nginx
keepalive_timeout 65s;
keepalive_requests 1000;
```

这表示：

- 空闲连接可以保留一段时间
- 一个连接上允许复用多个请求

好处是减少三次握手、四次挥手和频繁创建连接的成本。

#### 4.2 Nginx 到后端的 keepalive

这一步很多人会忽略，但在代理场景里非常关键。

```nginx
upstream backend {
    server 10.0.0.1:8080;
    keepalive 32;
}

location / {
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_pass http://backend;
}
```

这表示每个 worker 会保留一定数量到后端的空闲长连接。

它的价值是：

- 减少 Nginx 和后端之间频繁建连
- 降低后端连接压力
- 降低大量 `TIME_WAIT`、握手和线程池抖动

你可以把它理解为：不只是客户端到 Nginx 可以复用连接，Nginx 到后端也应该尽量复用。

### 5. gzip 压缩：拿 CPU 换带宽

```nginx
gzip on;
gzip_min_length 1k;
gzip_comp_level 4;
gzip_types text/plain text/css application/json application/javascript;
```

gzip 的本质，是让响应体更小，减少网络传输量。

但它也不是免费午餐，因为压缩要消耗 CPU。

所以正确理解是：

- 对文本类响应，通常值得压缩
- 对图片、视频、压缩包这类本身已经压缩过的内容，再 gzip 收益很小，反而浪费 CPU

面试里比较好的回答不是“gzip 能提高性能”，而是“gzip 用 CPU 换带宽，适合文本响应，不适合已压缩资源”。

### 6. 缓存：能不打后端，就尽量别打

如果某些响应短时间内变化不大，Nginx 可以缓存后端返回结果：

```nginx
proxy_cache_path /tmp/nginx_cache levels=1:2 keys_zone=my_cache:10m max_size=1g;

location / {
    proxy_pass http://backend;
    proxy_cache my_cache;
    proxy_cache_valid 200 10m;
    proxy_cache_valid 404 1m;
}
```

它能显著降低：

- 后端 QPS
- 后端数据库压力
- 接口平均响应时间

缓存不仅能缓存 200，还能有策略地缓存 404，这对防缓存穿透也很有帮助。

但缓存也带来新问题：

- 什么时候失效
- 如何避免把不该缓存的个性化数据缓存住
- 缓存命中率到底高不高

所以缓存不是“打开就完事”，而是需要结合业务语义设计。

### 7. worker 参数和连接容量

最常见的两个参数：

```nginx
worker_processes auto;
worker_connections 65535;
```

理论上最大连接数近似于：

```text
worker_processes * worker_connections
```

但真实代理场景下不能机械套这个公式，因为：

- 一个客户端连接可能对应一个后端连接
- 文件描述符不是无限的
- 内核队列、内存和网络资源也都有限

所以更专业的表述应该是：

`worker_processes * worker_connections` 只是上限估算的第一步，不是最终吞吐结论。

### 8. 别忘了文件描述符上限和内核参数

Nginx 的每个连接、文件、socket，本质上都要占文件描述符。

如果系统层面的 `ulimit -n` 太小，即使 Nginx 配置写得再大也没用。

常见关注点包括：

- `worker_rlimit_nofile`
- 系统文件描述符上限
- `net.core.somaxconn`
- backlog 队列
- 临时端口与 TIME_WAIT 行为

这些内容面试里不用死背参数，但要知道：Nginx 的性能上限不只由它自己决定，还受宿主机内核和资源限制。

### 9. 静态资源、动态代理的优化重点不同

这是工程上非常重要的思维方式。

#### 如果以静态资源为主

重点通常是：

- `sendfile`
- 文件系统与磁盘性能
- 缓存头
- CDN 前移

#### 如果以动态代理为主

重点通常是：

- upstream keepalive
- 超时配置
- 缓存策略
- 后端容量与慢接口治理

所以别把所有优化都看成“调 Nginx 参数”，很多问题最后会指向后端服务本身。

### 10. 一套更靠谱的优化思路

真实场景里，优化最好按这个顺序做：

1. 先量化现状：QPS、RT、错误率、连接数、CPU、带宽、缓存命中率
2. 判断瓶颈在静态发送、网络传输、连接建立还是后端处理
3. 针对瓶颈启用对应优化，不要盲调
4. 每调一次都做压测和回归，确认收益和副作用

这比“网上模板全抄一遍”要成熟得多。

## 小结

- 性能优化要先问“瓶颈在哪一段”，再决定调什么。
- `sendfile` 的核心价值是减少无意义的数据拷贝和上下文切换。
- keepalive 不只对客户端到 Nginx 重要，对 Nginx 到后端同样关键。
- gzip 是拿 CPU 换带宽，缓存是拿存储换后端压力。
- worker 参数、文件描述符、内核队列等系统限制，决定了 Nginx 的真实上限。

