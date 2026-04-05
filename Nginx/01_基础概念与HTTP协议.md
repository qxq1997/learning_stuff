# Nginx - 第 1 课：基础概念与HTTP协议

## 学习目标（本节结束后你能做到什么）

- 说清 HTTP 请求-响应的完整流程和报文结构
- 记住面试必考的 10 个状态码，尤其能区分 502 和 504
- 理解 Nginx 的三大核心用途：静态文件服务、反向代理、负载均衡
- 能写出最基础的静态文件配置和反向代理配置
- 掌握 Nginx 的安装、关键文件路径和常用命令

## 内容讲解

### 1. HTTP 协议基础：请求-响应流程

HTTP 是整个 Web 世界的通信基础。理解 Nginx 之前，必须先搞清楚 HTTP 的工作方式。

一次完整的 HTTP 请求-响应流程：

```
客户端(浏览器)                                   服务器(Nginx)
    |                                              |
    |  1. DNS 解析，拿到服务器 IP                     |
    |  2. TCP 三次握手建立连接                        |
    |------- 3. 发送 HTTP 请求报文 -------->          |
    |                                   4. 解析请求   |
    |                                   5. 处理请求   |
    |                                   6. 构建响应   |
    |<------ 7. 返回 HTTP 响应报文 ---------          |
    |  8. 浏览器渲染页面                              |
    |  9. TCP 四次挥手断开连接（或保持 keepalive）      |
    |                                              |
```

关键点：HTTP 是无状态协议，每次请求之间互不关联。服务器不会记住你上次请求了什么。要保持状态，需要借助 Cookie、Session、Token 等机制。

### 2. 请求报文格式

HTTP 请求报文由三部分组成：请求行、请求头、请求体。

```
POST /api/users HTTP/1.1          <-- 请求行：方法 + URI + 协议版本
Host: www.example.com             <-- 请求头开始
Content-Type: application/json
Accept: text/html
Connection: keep-alive
User-Agent: Mozilla/5.0
Content-Length: 27
                                  <-- 空行，分隔头和体
{"name":"test","age":25}          <-- 请求体（GET 请求通常没有）
```

**请求行三要素：**

| 要素 | 说明 | 常见值 |
|------|------|--------|
| 方法 | 要做什么操作 | GET、POST、PUT、DELETE、PATCH |
| URI | 请求的资源路径 | /api/users、/index.html |
| 协议版本 | HTTP 版本 | HTTP/1.0、HTTP/1.1、HTTP/2 |

**常用请求头：**

- `Host`：目标域名，Nginx 用它来区分虚拟主机
- `Content-Type`：请求体的数据格式（application/json、multipart/form-data）
- `Accept`：客户端能接受的响应格式
- `Connection`：是否保持连接（keep-alive）
- `Authorization`：认证信息（Bearer Token 等）

### 3. 响应报文格式

HTTP 响应报文同样由三部分组成：状态行、响应头、响应体。

```
HTTP/1.1 200 OK                   <-- 状态行：协议版本 + 状态码 + 原因短语
Server: nginx/1.24.0             <-- 响应头开始
Content-Type: text/html
Content-Length: 1234
Cache-Control: max-age=3600
Set-Cookie: session_id=abc123
                                  <-- 空行
<html>...</html>                  <-- 响应体
```

**状态行三要素：** 协议版本、状态码、原因短语（如 OK、Not Found）。

### 4. 必记状态码（面试高频）

| 状态码 | 含义 | 面试要点 |
|--------|------|----------|
| **200** | OK，请求成功 | 最基本的成功响应 |
| **301** | 永久重定向 | 浏览器会缓存，SEO 权重转移。比如 http 跳 https |
| **302** | 临时重定向 | 浏览器不缓存，下次还请求原地址。比如登录后跳转 |
| **304** | Not Modified | 资源没变，用本地缓存。配合 If-Modified-Since / ETag |
| **400** | Bad Request | 客户端请求格式错误，参数不对 |
| **403** | Forbidden | 服务器理解请求但拒绝执行，权限不足 |
| **404** | Not Found | 资源不存在 |
| **500** | Internal Server Error | 服务器内部错误，代码崩了 |
| **502** | Bad Gateway | **Nginx 作为代理，连上了后端但后端返回了无效响应（后端挂了、返回了乱码）** |
| **504** | Gateway Timeout | **Nginx 作为代理，等后端响应超时了（后端太慢没回来）** |

**502 vs 504 的区别（面试必考）：**

```
502 Bad Gateway:
  浏览器 --> Nginx --> 后端服务
                       后端挂了/返回无效响应
  Nginx 连上了后端，但后端给了一个"废"的回复，或者进程直接崩了。

504 Gateway Timeout:
  浏览器 --> Nginx --> 后端服务
                       后端处理太慢...超时了
  Nginx 连上了后端，但等了很久（超过 proxy_read_timeout）后端还没回复。
```

简单记忆：**502 是后端"死了"，504 是后端"慢了"。**

### 5. Nginx 的三大核心用途

Nginx（发音 engine-x）是一个高性能的 HTTP 服务器和反向代理服务器。它有三个最核心的用途：

**用途一：静态文件服务**

直接把磁盘上的 HTML、CSS、JS、图片等文件返回给客户端。这是 Nginx 最基础也是性能最强的场景。

```
浏览器 --请求 /index.html--> Nginx --读取磁盘文件--> 返回文件内容
```

**用途二：反向代理**

客户端以为在和 Nginx 通信，实际上 Nginx 把请求转发给了后端应用服务器（如 Tomcat、Node.js、Go 服务）。客户端感知不到后端服务器的存在。

```
浏览器 --> Nginx(反向代理) --> Tomcat/Node.js/Go
                             后端应用服务器
```

正向代理 vs 反向代理：
- 正向代理：代理客户端，帮客户端访问外部资源（如 VPN）
- 反向代理：代理服务端，帮服务端接收请求并转发（如 Nginx）

**用途三：负载均衡**

当后端有多台服务器时，Nginx 按照一定策略把请求分发到不同的后端机器上，避免单台机器过载。

```
              +--> 后端服务器 A
浏览器 --> Nginx --+--> 后端服务器 B
              +--> 后端服务器 C
```

### 6. 安装方法和关键文件路径

**安装（以 CentOS/Ubuntu 为例）：**

```bash
# CentOS
yum install -y nginx

# Ubuntu
apt-get install -y nginx

# macOS
brew install nginx
```

**关键文件路径：**

| 路径 | 作用 |
|------|------|
| `/etc/nginx/nginx.conf` | 主配置文件，全局配置入口 |
| `/etc/nginx/conf.d/` | 自定义配置目录，推荐把每个站点配置放这里 |
| `/usr/share/nginx/html/` | 默认静态文件目录 |
| `/var/log/nginx/access.log` | 访问日志 |
| `/var/log/nginx/error.log` | 错误日志 |
| `/run/nginx.pid` | Nginx 主进程 PID 文件 |

实际项目中的最佳实践：不直接改 `nginx.conf`，而是在 `conf.d/` 目录下创建 `.conf` 文件，因为 `nginx.conf` 里通常有一行 `include /etc/nginx/conf.d/*.conf;`，会自动加载该目录下的所有配置。

### 7. 最基础的配置示例

**静态文件服务配置：**

```nginx
server {
    listen 80;                          # 监听 80 端口
    server_name www.example.com;        # 域名

    root /usr/share/nginx/html;         # 静态文件根目录
    index index.html index.htm;         # 默认首页文件

    location / {
        try_files $uri $uri/ =404;      # 按顺序尝试：文件 -> 目录 -> 返回404
    }

    location /images/ {
        alias /data/images/;            # alias 替换整个路径
        expires 30d;                    # 图片缓存 30 天
    }
}
```

`root` vs `alias` 的区别：
- `root`：把 location 路径拼接到 root 后面。`location /img/` + `root /data/` = 去 `/data/img/` 找文件
- `alias`：用 alias 的值替换 location 匹配到的部分。`location /img/` + `alias /data/images/` = 去 `/data/images/` 找文件

**反向代理配置：**

```nginx
server {
    listen 80;
    server_name api.example.com;

    location / {
        proxy_pass http://127.0.0.1:8080;    # 转发到后端 8080 端口
        proxy_set_header Host $host;          # 传递原始 Host
        proxy_set_header X-Real-IP $remote_addr;  # 传递客户端真实 IP
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

### 8. 常用命令

```bash
# 启动 Nginx
nginx                        # 或 systemctl start nginx

# 停止 Nginx
nginx -s stop                # 立即停止（强制）
nginx -s quit                # 优雅停止（等当前请求处理完）

# 重新加载配置（不停服务）
nginx -s reload              # 热加载，最常用

# 测试配置文件语法
nginx -t                     # 改完配置后必须先测试再 reload

# 查看 Nginx 版本
nginx -v                     # 简单版本
nginx -V                     # 详细版本（含编译参数）

# 查看 Nginx 进程
ps aux | grep nginx
```

**操作流程的最佳实践：** 每次改配置后的标准操作是先 `nginx -t` 验证语法，没问题了再 `nginx -s reload`。千万不要直接 reload，万一配置写错了，Nginx 会拒绝加载新配置，但如果格式错到一定程度可能导致服务不可用。

## 小结（3-5 条关键点）

- HTTP 请求报文 = 请求行（方法+URI+版本）+ 请求头 + 请求体；响应报文 = 状态行 + 响应头 + 响应体。
- 502 是后端"死了"（返回无效响应），504 是后端"慢了"（等待超时）。这是面试高频考点。
- Nginx 的三大核心用途：静态文件服务、反向代理、负载均衡。反向代理是 Nginx 最常用的场景。
- 改配置的标准流程：编辑配置 -> `nginx -t` 测试 -> `nginx -s reload` 热加载。
- 推荐在 `conf.d/` 目录下按站点创建独立配置文件，而不是把所有配置塞进 `nginx.conf`。

---

## 检查站：请回答以下问题

1. 请画出一次 HTTP 请求-响应的完整流程（从 DNS 解析到连接关闭）。
2. 502 和 504 分别表示什么？在排查时你会从哪些角度入手？
3. root 和 alias 在 Nginx 配置中有什么区别？请举例说明。
4. 改完 Nginx 配置后，标准操作流程是什么？为什么不能直接 reload？
