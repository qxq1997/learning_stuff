# Nginx - 第 6 课：安全与 HTTPS

## 学习目标（本节结束后你能做到什么）

- 解释 HTTPS 解决的三个核心安全问题：机密性、完整性、身份认证
- 完整描述 TLS 1.2 四步握手流程，说清为什么先非对称再对称
- 理解证书链（根 CA → 中间 CA → 服务器证书），知道漏中间证书是最常见的 HTTPS 故障
- 配置 Nginx 的 HTTPS，包括证书、协议版本、密码套件和 HTTP 到 HTTPS 跳转
- 掌握 HTTPS 性能优化手段：Session 复用、OCSP Stapling、HTTP/2
- 配置安全防护：限流 limit_req、限连接 limit_conn、防盗链、安全响应头

## 内容讲解

### 1. HTTPS 基础：为什么需要加密

HTTP 是明文传输协议。你在浏览器输入的用户名密码、银行卡号，在网络上传输时跟写在明信片上没区别——中间任何一个路由器、WiFi 热点都能看到。

HTTPS = HTTP + TLS（Transport Layer Security），它解决三个问题：

```
┌──────────────┬─────────────────────────────────────────────┐
│   安全问题    │              HTTPS 如何解决                  │
├──────────────┼─────────────────────────────────────────────┤
│   机密性     │ 对称加密（AES）加密传输内容，中间人看不懂      │
│   完整性     │ MAC（消息认证码）校验，篡改内容能被检测出来     │
│   身份认证   │ 数字证书证明服务器身份，防止钓鱼网站冒充        │
└──────────────┴─────────────────────────────────────────────┘
```

**面试高频问：HTTP 和 HTTPS 的区别？**

不要只说"一个加密一个不加密"。要说三个层面：机密性（加密内容）、完整性（防篡改）、身份认证（防冒充）。另外，HTTP 默认 80 端口，HTTPS 默认 443 端口。

### 2. TLS 1.2 握手流程（必考，详细 4 步）

TLS 握手发生在 TCP 三次握手之后、HTTP 请求之前。目标是让双方协商出一个对称加密密钥。

```
客户端 (Browser)                                    服务器 (Nginx)
     │                                                   │
     │  ① Client Hello                                   │
     │  支持的加密算法列表 + 随机数 A                       │
     │──────────────────────────────────────────────────>│
     │                                                   │
     │  ② Server Hello                                   │
     │  选定的加密算法 + 服务器证书 + 随机数 B              │
     │<──────────────────────────────────────────────────│
     │                                                   │
     │  ③ 客户端验证证书                                   │
     │  生成预主密钥 (Pre-Master Secret)                   │
     │  用证书中的公钥加密预主密钥，发给服务器               │
     │──────────────────────────────────────────────────>│
     │                                                   │
     │  ④ 双方计算会话密钥                                 │
     │  会话密钥 = f(随机数A + 随机数B + 预主密钥)          │
     │  之后所有通信都用这个对称密钥加密                     │
     │<═══════════════ 加密通信开始 ═══════════════════>│
     │                                                   │
```

**四步详解：**

**第一步：Client Hello**
客户端发送自己支持的加密算法列表（称为 Cipher Suite，比如 `TLS_RSA_WITH_AES_256_CBC_SHA`），以及一个客户端随机数 A。

**第二步：Server Hello**
服务器从客户端的列表里选一个双方都支持的加密算法，然后发回：选定的算法、服务器的数字证书（里面包含公钥）、服务器随机数 B。

**第三步：客户端验证证书并发送预主密钥**
客户端验证证书是否合法（有没有过期、域名是否匹配、是否被信任的 CA 签发）。验证通过后，客户端生成一个随机的预主密钥（Pre-Master Secret），用证书中的公钥加密后发给服务器。只有服务器有私钥能解密。

**第四步：双方计算对称会话密钥**
客户端和服务器都拥有了三个要素：随机数 A、随机数 B、预主密钥。双方用相同的算法算出一个对称会话密钥（Session Key）。之后的所有 HTTP 通信都用这个对称密钥加密。

**为什么先非对称再对称？**

```
非对称加密（RSA）：安全但慢，加密 1KB 数据需要约 0.5ms
对称加密（AES）：  快但密钥分发难，加密 1KB 数据只需约 0.005ms
                  速度差约 100 倍
```

所以 TLS 用非对称加密来安全地交换对称密钥（解决密钥分发问题），然后用对称加密来加密实际的数据传输（解决性能问题）。这是一个非常经典的"取长补短"设计。

**TLS 1.3 的改进（加分项）：**

TLS 1.2 握手需要 2-RTT（两个往返），TLS 1.3 优化到 1-RTT：

```
TLS 1.2:  Client Hello → Server Hello → 密钥交换 → 完成   (2-RTT)
TLS 1.3:  Client Hello(含密钥共享) → Server Hello(含密钥共享) → 完成  (1-RTT)
```

TLS 1.3 的三个关键改进：
- **更少的 RTT**：从 2-RTT 降到 1-RTT，减少了握手延迟
- **去掉不安全算法**：RSA 密钥交换被移除（不支持前向保密），全面使用 ECDHE
- **前向保密（Forward Secrecy）**：即使服务器私钥泄露，之前的通信也无法被解密（因为每次会话的密钥都是临时生成的）

### 3. 证书链

浏览器信任一个网站的证书，不是直接信任它，而是通过一条**信任链**：

```
┌─────────────────────────────────┐
│         根 CA 证书               │  ← 内置在操作系统/浏览器中
│    (DigiCert Root CA)           │     全球只有几十个根 CA
│    自签名，绝对信任              │
└──────────┬──────────────────────┘
           │ 签发
           ▼
┌─────────────────────────────────┐
│        中间 CA 证书              │  ← 由根 CA 签发
│  (DigiCert SHA2 Secure CA)      │     负责日常的证书签发工作
│                                 │
└──────────┬──────────────────────┘
           │ 签发
           ▼
┌─────────────────────────────────┐
│       服务器证书                 │  ← 你申请的那个证书
│   (www.example.com)             │     绑定到具体域名
│                                 │
└─────────────────────────────────┘
```

验证过程：浏览器拿到服务器证书 → 用中间 CA 的公钥验证服务器证书的签名 → 用根 CA 的公钥验证中间 CA 的签名 → 根 CA 在浏览器信任列表里 → 整条链可信。

**Nginx 证书文件的关键点：**

Nginx 的 `ssl_certificate` 文件必须把服务器证书和中间证书拼在一个文件里，顺序是服务器证书在前，中间证书在后：

```bash
# 正确做法：拼接证书链
cat server.crt intermediate.crt > fullchain.crt
```

```
fullchain.crt 内容：
-----BEGIN CERTIFICATE-----
（服务器证书，在前面）
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
（中间 CA 证书，在后面）
-----END CERTIFICATE-----
```

**漏了中间证书是最常见的 HTTPS 故障。** 症状是：桌面浏览器能正常访问（因为浏览器缓存了中间证书），但手机 APP 或 curl 报证书错误（它们没有缓存中间证书）。排查时用 `openssl s_client` 检查是否返回了完整的证书链。

### 4. Nginx HTTPS 配置

一个完整的 HTTPS 配置示例：

```nginx
# HTTP 80 跳转 HTTPS 301
server {
    listen 80;
    server_name www.example.com example.com;
    return 301 https://$server_name$request_uri;
}

# HTTPS 443 配置
server {
    listen 443 ssl;
    server_name www.example.com;

    # 证书文件（包含服务器证书 + 中间证书）
    ssl_certificate     /etc/nginx/ssl/fullchain.crt;
    # 私钥文件（权限必须是 600，只有 root 能读）
    ssl_certificate_key /etc/nginx/ssl/private.key;

    # 协议版本：只启用 TLS 1.2 和 1.3，禁用 SSLv3/TLS 1.0/1.1
    ssl_protocols TLSv1.2 TLSv1.3;

    # 密码套件：优先使用 ECDHE（前向保密）+ AES-GCM
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;    # 优先使用服务端的密码套件顺序

    location / {
        proxy_pass http://backend;
    }
}
```

**配置要点：**
- `listen 443 ssl`：443 端口启用 SSL
- `ssl_protocols`：禁用 TLS 1.0 和 1.1（已知有漏洞，PCI DSS 合规要求）
- `ssl_prefer_server_ciphers on`：让服务器决定用哪个密码套件，而不是客户端。这样可以保证用最安全的算法
- HTTP 80 端口用 301 永久重定向到 HTTPS，SEO 友好

### 5. HTTPS 性能优化

HTTPS 比 HTTP 慢，主要慢在 TLS 握手上。以下优化可以大幅减少握手开销：

**SSL Session 复用：**

```nginx
ssl_session_cache shared:SSL:50m;   # 50MB 共享缓存，约能存 20 万个会话
ssl_session_timeout 1d;             # 会话有效期 1 天
ssl_session_tickets on;             # 开启 Session Ticket（无状态复用）
```

原理：客户端第一次完成完整握手后，服务器把会话信息缓存起来。客户端下次连接时带上 Session ID，服务器查到缓存就跳过完整握手，直接复用之前的密钥。这把 2-RTT 的握手优化成 1-RTT。

**OCSP Stapling：**

```nginx
ssl_stapling on;
ssl_stapling_verify on;
ssl_trusted_certificate /etc/nginx/ssl/ca-bundle.crt;
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 5s;
```

**什么是 OCSP？** 浏览器拿到证书后，需要检查这个证书是否被吊销。传统方式是浏览器自己去 CA 的 OCSP 服务器查询，这会增加延迟和隐私泄露（CA 知道你在访问哪个网站）。

**什么是 OCSP Stapling？** 由 Nginx 主动去 CA 查询证书状态，把查询结果"钉"在 TLS 握手中发给客户端。客户端不用再单独去查，既减少延迟又保护隐私。

**HTTP/2：**

```nginx
listen 443 ssl http2;    # 同时启用 SSL 和 HTTP/2
```

HTTP/2 的核心优势是**多路复用**：一个 TCP 连接上可以同时传输多个请求和响应，不再有 HTTP/1.1 的队头阻塞问题。配合 HTTPS 使用，虽然加了加密层，但多路复用带来的性能提升远大于加密开销。

### 6. 安全防护配置

#### 6.1 限流 limit_req_zone（漏桶算法）

限流是防止恶意攻击或突发流量压垮服务的第一道防线。Nginx 用漏桶算法实现限流。

```
漏桶算法原理：

     请求流入（速度不固定）
         │ │ │ │ │ │ │
         ▼ ▼ ▼ ▼ ▼ ▼ ▼
    ┌───────────────────┐
    │    桶 (burst)      │  ← 桶满了，新请求被丢弃（503）
    │   ┌─────────────┐ │
    │   │ 排队的请求    │ │
    │   └─────────────┘ │
    └────────┬──────────┘
             │
             ▼
      匀速流出（rate 控制）
      比如 10r/s 就是每 100ms 放一个
```

```nginx
# 在 http 块中定义限流区域
http {
    # $binary_remote_addr：按客户端 IP 限流
    # zone=api_limit:10m：10MB 共享内存，约存 16 万个 IP
    # rate=10r/s：每秒最多 10 个请求（每 100ms 放行一个）
    limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;

    server {
        location /api/ {
            # burst=20：桶大小 20，允许突发 20 个请求排队
            # nodelay：排队的请求不等待，立刻处理（但仍受总速率限制）
            limit_req zone=api_limit burst=20 nodelay;
            limit_req_status 429;    # 超限返回 429 Too Many Requests
        }
    }
}
```

**三个参数的含义：**
- **rate=10r/s**：平均速率，每秒放行 10 个请求。本质是每 100ms 放行一个
- **burst=20**：突发容量。超过 rate 的请求先放进桶里排队，桶最多容纳 20 个
- **nodelay**：排队的请求立刻处理，不用等到下一个 100ms 时间窗口。如果不加 nodelay，排队的请求会严格按 100ms 间隔放行，延迟很高

#### 6.2 限连接数 limit_conn_zone

```nginx
http {
    limit_conn_zone $binary_remote_addr zone=conn_limit:10m;

    server {
        location /download/ {
            limit_conn conn_limit 5;    # 每个 IP 最多 5 个并发连接
            limit_conn_log_level warn;
            limit_conn_status 503;
        }
    }
}
```

限流（limit_req）控制的是请求速率，限连接（limit_conn）控制的是同时保持的连接数。两者通常配合使用：限流防刷接口，限连接防下载带宽被占满。

#### 6.3 防盗链 valid_referers

```nginx
location ~* \.(jpg|png|gif|mp4)$ {
    valid_referers none blocked server_names
                   *.example.com example.com;

    if ($invalid_referer) {
        return 403;
    }
}
```

- `none`：允许没有 Referer 的请求（直接在浏览器输入 URL）
- `blocked`：允许 Referer 被防火墙删掉的请求
- `server_names`：允许来自本站域名的请求

其他网站引用你的图片时，Referer 不在白名单中，返回 403。

#### 6.4 安全响应头

```nginx
# 防止页面被嵌入 iframe（防止点击劫持）
add_header X-Frame-Options "SAMEORIGIN" always;

# 防止浏览器 MIME 类型嗅探（上传了一个 .jpg 实际是 .html，浏览器不会当 HTML 执行）
add_header X-Content-Type-Options "nosniff" always;

# 开启浏览器 XSS 过滤器
add_header X-XSS-Protection "1; mode=block" always;

# HSTS：告诉浏览器以后只用 HTTPS 访问此站点
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
```

这些响应头是安全加固的基本操作，面试时说出来能体现你对安全有全面的了解。

### 7. 面试综合题：HTTPS 证书报错排查思路

**题目：用户反馈访问网站时浏览器提示"证书不安全"，怎么排查？**

```
排查流程：

第 1 步：用 openssl s_client 检查证书链
─────────────────────────────────────────
$ openssl s_client -connect www.example.com:443 -servername www.example.com

看输出中的 Certificate chain 是否完整
   0 s:CN = www.example.com      ← 服务器证书
   1 s:CN = DigiCert SHA2 CA     ← 中间证书（如果没有这行，说明漏了中间证书）

第 2 步：检查证书是否过期
──────────────────────────
$ openssl s_client -connect www.example.com:443 | openssl x509 -noout -dates

Not Before: Jan  1 00:00:00 2024 GMT
Not After : Jan  1 00:00:00 2025 GMT   ← 过了这个日期就是过期

第 3 步：检查域名是否匹配
──────────────────────────
证书签发给 www.example.com，但你访问的是 example.com
或者证书是通配符 *.example.com，但你访问的是 sub.sub.example.com（通配符只匹配一级）

第 4 步：检查中间证书
──────────────────────────
最常见的问题！Nginx 的 ssl_certificate 文件只有服务器证书，没有拼接中间证书。
桌面浏览器可能正常（缓存了中间证书），手机 APP 报错。

第 5 步：检查是否有混合内容
──────────────────────────
HTTPS 页面中加载了 HTTP 的资源（JS、CSS、图片），
浏览器会提示"不安全"。检查页面中所有资源链接是否都是 HTTPS。
```

## 小结（3-5 条关键点）

- HTTPS = HTTP + TLS，解决三个问题：机密性（加密）、完整性（防篡改）、身份认证（防冒充）。面试时三个都要说，不能只说"加密"。
- TLS 1.2 握手四步：Client Hello（算法+随机数A）→ Server Hello（算法+证书+随机数B）→ 客户端发加密的预主密钥 → 双方算出对称密钥。先非对称后对称是因为 RSA 慢 AES 快，取长补短。
- 证书链是根 CA → 中间 CA → 服务器证书。Nginx 配置时必须把服务器证书和中间证书拼在一个文件里，漏了中间证书是最常见的 HTTPS 故障（桌面正常、手机报错）。
- 限流 limit_req 用漏桶算法，rate 控制匀速放行，burst 控制突发排队容量，nodelay 让排队的请求立刻处理。限流和限连接是 Nginx 安全防护的第一道防线。
- HTTPS 性能优化三板斧：SSL Session 复用（减少重复握手）、OCSP Stapling（减少证书吊销查询延迟）、HTTP/2 多路复用（抵消加密开销）。

---

## 检查站：请回答以下问题

1. TLS 1.2 握手的四个步骤分别做了什么？为什么要先用非对称加密再转对称加密？
2. 什么是证书链？Nginx 配置 HTTPS 时为什么要把中间证书拼到证书文件里？漏了会怎样？
3. limit_req 中 rate、burst、nodelay 三个参数分别控制什么？不加 nodelay 会怎样？
4. 用户反馈"证书不安全"，你的排查步骤是什么？
