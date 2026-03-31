# Nginx - 第 3 课：配置体系：server、location、rewrite 与变量

## 学习目标（本节结束后你能做到什么）

- 理解 Nginx 配置的层级结构和继承关系，而不是把配置文件看成平铺的文本。
- 说清楚 `http`、`server`、`location` 分别负责什么。
- 掌握 `location` 的匹配优先级，并能手工推演一个 URL 最终命中哪个块。
- 理解 `rewrite`、`root`、`alias`、常见变量的差异和坑点。
- 面对“为什么明明写了配置却没生效”的问题时，知道从哪里排查。

## 内容讲解（核心概念，用类比、例子、图示说清楚）

### 1. 配置不是平铺的，而是有层级的

Nginx 的配置像一棵树：

```text
main
├── events { }
├── http { }
│   ├── server { }
│   │   ├── location { }
│   │   └── location { }
│   └── server { }
└── stream { }
```

最常见的 HTTP 场景里，你重点盯住四层就够了：

- main：全局级别
- events：连接事件相关
- http：HTTP 服务全局设置
- server：虚拟主机
- location：URL 匹配与处理规则

为什么理解层级很重要？因为很多指令是会继承的。

比如你在 `http` 里开了 `gzip on;`，下面所有 `server`、`location` 默认都继承这个行为；如果某个更内层位置明确写了 `gzip off;`，那它会覆盖外层。

所以 Nginx 配置不是“后写的生效”这么简单，而是“先看作用域，再看继承和覆盖”。

### 2. server 是什么

`server` 可以理解为一个虚拟站点。

常见写法：

```nginx
server {
    listen 80;
    server_name example.com;

    location / {
        root /var/www/html;
        index index.html;
    }
}
```

这里表达的是：

- 监听 80 端口
- 当请求的 Host 匹配 `example.com` 时
- 用这个 `server` 里的规则处理请求

如果同一台机器上有多个域名，比如 `a.com`、`b.com`，你通常会写多个 `server` 块。

### 3. server_name 匹配和默认 server

一个常见面试追问是：如果请求的 `Host` 没有匹配上任何 `server_name` 怎么办？

答案是：进入默认 server。

如果你没有显式指定 `default_server`，通常就是同端口下第一个被加载的 `server`。

所以线上常见做法是加一个兜底 server：

- 不认识的域名直接返回 444 或 404
- 避免请求误落到其他站点

这属于很基础但很实用的防御性配置意识。

### 4. location 才是请求处理的核心入口

`server` 负责先按域名和端口大致归类，真正决定“这个 URL 怎么处理”的，往往是 `location`。

比如：

```nginx
location /static/ { }
location /api/ { }
location ~ \.php$ { }
location = /healthz { }
```

面试特别喜欢考：同一个请求到底命中哪个 `location`。

### 5. location 匹配优先级

必须掌握的顺序是：

1. `=` 精确匹配
2. `^~` 前缀匹配，命中后不再继续看正则
3. `~` 和 `~*` 正则匹配
4. 普通前缀匹配，取最长前缀

更准确地说，匹配过程可以这样理解：

1. 先找精确匹配 `=`
2. 如果没有，再找最长前缀匹配
3. 如果这个最长前缀是 `^~`，直接使用
4. 否则继续按书写顺序测试正则
5. 如果正则有匹配，第一个匹配上的正则胜出
6. 如果正则没有匹配，就使用之前记住的最长普通前缀

来看经典例子：

```nginx
location /api/ { return 200 "A"; }
location = /api/health { return 200 "B"; }
location ~ ^/api/ { return 200 "C"; }
```

- 请求 `/api/health` 命中 `B`，因为精确匹配优先级最高。
- 请求 `/api/users`，先记住普通前缀 `/api/`，但还要继续看正则，正则也匹配，于是命中 `C`。

如果把第一条改成：

```nginx
location ^~ /api/ { return 200 "A"; }
```

那 `/api/users` 就会直接命中 `A`，因为 `^~` 表示“命中这个前缀后，不再看正则”。

### 6. root 和 alias 很容易混

这是非常经典的坑。

#### root

`root` 是把 URI 原样拼到某个根目录后面。

```nginx
location /images/ {
    root /data/www;
}
```

请求 `/images/a.png` 时，实际找的是：

```text
/data/www/images/a.png
```

#### alias

`alias` 则是用指定目录替换掉当前匹配前缀。

```nginx
location /images/ {
    alias /data/static/;
}
```

请求 `/images/a.png` 时，实际找的是：

```text
/data/static/a.png
```

一句话记忆：

- `root` 更像“在前面加个根目录”
- `alias` 更像“把匹配到的路径前缀换掉”

很多“文件明明存在却 404”的问题，最后都能追到 `root` 和 `alias` 用错。

### 7. rewrite 到底在干什么

`rewrite` 的本质是修改 URI。

比如：

```nginx
rewrite ^/old/(.*)$ /new/$1 permanent;
```

表示把 `/old/xxx` 重定向到 `/new/xxx`。

但 `rewrite` 不只有“重定向给浏览器”这一种用法，还有内部改写。

几个常见 flag：

- `permanent`：301，告诉浏览器地址永久变化
- `redirect`：302，临时跳转
- `last`：内部重写后，重新走一次 location 匹配
- `break`：内部重写后，不再重新匹配 location，留在当前上下文继续执行

面试里最常考的是 `last` 和 `break`：

- `last`：换了 URI 后重新分流
- `break`：换了 URI 但不再换路

### 8. 常用变量一定要理解“语义边界”

Nginx 有很多变量，最容易考的是这些：

- `$host`
- `$remote_addr`
- `$uri`
- `$request_uri`
- `$args`
- `$scheme`

其中一个特别容易混的是：

- `$uri`：当前内部处理中的 URI，可能被 rewrite 改过
- `$request_uri`：客户端原始请求 URI，保留原值，通常带查询串

这两个变量长得像，但用途不同。排障时如果你想记录用户最初发来的地址，通常更应该看 `$request_uri`。

### 9. 一套理解配置生效顺序的实战思路

当你发现“为什么这个请求没走到我以为的配置”时，可以按这条链路查：

1. 请求到底打到了哪个端口
2. 这个端口命中了哪个 `server`
3. `Host` 是否符合预期
4. 在这个 `server` 里最终命中了哪个 `location`
5. 是否有 `rewrite` 导致 URI 改写
6. 是否有 `try_files`、`root`、`alias`、`proxy_pass` 造成后续行为差异

你会发现，大多数 Nginx 配置问题，本质都是“你脑中的匹配路径”和“它实际执行的匹配路径”不一致。

## 小结

- Nginx 配置是有层级和作用域的，不是平铺脚本。
- `server` 主要按端口和域名分站点，`location` 主要按路径分处理逻辑。
- `location` 匹配的关键规则是：精确匹配最高，`^~` 可阻止正则，正则按书写顺序匹配，普通前缀取最长。
- `root` 和 `alias` 的语义不同，是静态文件配置里的经典坑。
- `rewrite`、变量、继承与覆盖，是理解 Nginx 配置行为的关键地基。

