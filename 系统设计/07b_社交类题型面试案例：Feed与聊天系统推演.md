# 系统设计 - 第 7b 课：社交类题型面试案例：Feed 与聊天系统推演

## 这一节怎么用

第 7 课讲的是社交类题型的知识框架：`Feed`、`Timeline`、`聊天` 分别在考什么。  
这一节不重复讲概念，而是模拟真实面试现场：

- 面试官怎么开题
- 候选人怎么澄清需求
- 候选人脑子里怎么判断主矛盾
- 容量估算怎么算
- 架构怎么一步步推出来
- 追问时怎么调整方案
- 最后怎么用 2-3 分钟收束答案

这节的目标不是背一份标准答案，而是训练你在社交类题型里稳定做到：

1. 先分型：这是首页聚合、作者时间线，还是实时消息传递？
2. 先澄清：排序、分页、实时性、离线、已读、多端这些语义到底要不要？
3. 先估算：读写 QPS、fanout 放大、连接数、消息量先有数量级。
4. 再设计：围绕主矛盾选 `push / pull / hybrid`，或者围绕连接、顺序、补拉设计聊天系统。
5. 补异常：删除、取关、重建、重复消息、离线补拉、Gateway 故障都要能解释。

---

## 案例一：设计 Twitter / Home Feed

### 1. 面试官开题

**面试官：**  
我们来设计一个类似 Twitter 的系统。用户可以发 tweet、关注别人，也可以刷自己的首页 Feed。你会怎么设计？

### 2. 候选人的第一反应

**候选人思考：**  
这题不能一上来就说 Redis、Kafka、MySQL。第 7 课里说过，Twitter 题真正难的是 `Home Feed`，不是存 tweet。我要先把 `Author Timeline` 和 `Home Feed` 拆开，再决定 fanout 策略。

我还要先问清楚排序和范围。因为如果首页是强推荐流，答案会偏推荐系统；如果是关注流，答案会偏 fanout 和 timeline。

### 3. 候选人澄清问题

**候选人：**  
我先确认几个边界，避免设计发散：

1. 首页 Feed 是关注流为主，还是要做复杂推荐排序？
2. 作者个人主页的 Timeline 是否要支持完整历史分页？
3. 首页 Feed 是否只要求最近窗口，比如最近几百到几千条候选？
4. 删除 tweet、取关、屏蔽关系是否要求立刻生效？
5. 是否存在大 V 或明星账号，粉丝数可以到千万级？
6. 图片和视频是否需要展开设计，还是只存媒体引用？

**面试官：**  
先做关注流，不做复杂推荐。作者主页要能稳定分页。首页主要看最近内容，不要求深翻历史。删除要尽快生效，取关可以最终一致。存在大 V。媒体先只存引用。

### 4. 候选人收敛题目

**候选人回答：**  
那我把题目收敛成一个关注流系统：

- 支持发 tweet
- 支持关注/取关
- 支持作者个人 Timeline
- 支持首页 Home Feed
- 首页主要展示最近内容
- 排序先按时间为主，不做复杂推荐
- 媒体内容放对象存储，tweet 里只保存引用
- 存在粉丝数极高的大 V，所以 fanout 不能统一处理

这题我会先拆两个对象：

- `Author Timeline`：某个作者自己发过什么，是作者维度的 append-only 列表。
- `Home Feed`：某个读者应该看到什么，是读者维度的派生视图。

这两个不能混成一个表。

---

## 第一轮：容量估算

### 1. 面试官追问

**面试官：**  
你先估一下量级。

### 2. 候选人思考

**候选人思考：**  
Feed 题估算最重要的不是精确数字，而是发现读写比、follow graph 规模、fanout 放大和大 V 极端值。我要把平均值和极端值分开讲。

### 3. 候选人计算过程

**候选人回答：**  
我先给一组合理假设，主要用于确定架构方向：

- 注册用户：`5 亿`
- DAU：`1 亿`
- 平均每个 DAU 每天刷首页：`10 次`
- 每次刷首页取：`20 条`
- 日发 tweet：`1 亿`
- 平均关注数：`200`
- 普通用户粉丝数：几十到几百
- 大 V 粉丝数：`1000 万+`

先算首页读：

```text
首页请求 / day = 1 亿 DAU * 10 = 10 亿次 / day
平均首页 QPS = 10 亿 / 86400 ≈ 1.16 万 QPS
峰值按 10 倍估算 ≈ 10 万 - 12 万 QPS
```

再算发帖写：

```text
发帖 / day = 1 亿
平均发帖 QPS = 1 亿 / 86400 ≈ 1157 QPS
峰值按 5-10 倍估算 ≈ 6000 - 12000 QPS
```

再算关注边：

```text
follow edge ≈ 5 亿用户 * 200 = 1000 亿条关系
```

这个规模说明 follow graph 本身需要独立存储和缓存，不可能每次首页请求都临时扫大量关系。

再看 fanout 写放大。  
如果普通用户平均粉丝 `100`：

```text
普通 tweet fanout entries / day ≈ 1 亿 * 100 = 100 亿条 Home Feed entry / day
```

如果每条 Home Feed entry 只存：

```text
user_id + tweet_id + author_id + created_at + score/version
```

按 `32-64B` 粗估：

```text
100 亿 * 64B ≈ 640GB / day 原始 entry
加索引和副本后可能到 1-2TB / day
```

这个量对于大系统可以接受，但大 V 是另一个问题。  
如果一个大 V 有 `1000 万` 粉丝：

```text
1 条 tweet = 1000 万条 fanout entry
10 条 tweet = 1 亿条 fanout entry
```

这会把写路径打爆，所以不能所有作者都 fanout-on-write。

### 4. 候选人的估算结论

**候选人回答：**  
从估算看，这题的主矛盾是：

- 首页读远大于发帖写，所以普通用户适合写时分发来换低读延迟。
- 但关注图极不均匀，大 V 会导致极端写扩散，所以大 V 不适合全量写时分发。
- 因此我会采用混合 fanout：普通用户 push，大 V pull。

---

## 第二轮：核心数据模型

### 1. 面试官追问

**面试官：**  
你会怎么建模？

### 2. 候选人思考

**候选人思考：**  
这里要主动说清“真相源”和“派生视图”。Tweet Store 和 Author Timeline 更接近真相，Home Feed 是可重建的派生视图。这样后面删除、取关、重建才讲得通。

### 3. 候选人回答

**候选人回答：**  
我会拆几类核心对象。

第一，tweet 内容：

```text
tweet
- tweet_id
- author_id
- text
- media_refs
- visibility
- created_at
- deleted_at
```

第二，关注关系：

```text
follow_edge
- follower_id
- followee_id
- created_at
- status
```

查询路径需要支持：

- 查某个用户关注了谁：`follower_id -> followee_id list`
- 查某个作者有哪些粉丝：`followee_id -> follower_id list`

第三，作者时间线：

```text
author_timeline
- author_id
- tweet_id
- created_at
```

这个表用于用户主页，按 `author_id + created_at desc` 查询。

第四，首页候选列表：

```text
home_timeline
- user_id
- tweet_id
- author_id
- created_at
- source_type
```

这里最好只存引用，不存完整 tweet 正文。  
因为 tweet 正文、作者信息、互动计数可以通过对象缓存批量加载。

第五，fanout 任务：

```text
fanout_job
- tweet_id
- author_id
- status
- cursor
- retry_count
- created_at
```

它用于异步推进普通用户的写时分发，也用于失败重试和补偿。

---

## 第三轮：主链路设计

### 1. 发 tweet 链路

**面试官：**  
用户发一条 tweet，链路怎么走？

**候选人回答：**  
发 tweet 我会分同步和异步两段。

同步链路：

```text
客户端发 tweet
-> API 校验登录、内容、权限
-> Tweet Service 写 tweet store
-> 写 author_timeline
-> 发送 TweetCreated 事件或写 outbox
-> 返回发布成功
```

异步链路：

```text
Fanout Service 消费 TweetCreated
-> 判断作者类型：普通用户 / 大 V
-> 普通用户：取粉丝列表，批量写入粉丝 home_timeline
-> 大 V：不全量写入，只标记为 pull source 或更新热点缓存
```

这里发布成功的语义是：

- tweet 已经持久化
- 作者主页可见
- 首页分发可以最终一致

这能避免用户发帖卡在 fanout 上。

### 2. 读 Home Feed 链路

**面试官：**  
那用户刷首页呢？

**候选人回答：**  
读首页时，我会用混合读取。

```text
客户端请求 Home Feed
-> Feed Service 读取 user_id 的 home_timeline 候选
-> 同时读取该用户关注的大 V 最近 tweet
-> 合并普通候选 + 大 V 候选
-> 按时间或轻量 score 排序
-> 批量加载 tweet 详情、作者信息、计数
-> 过滤删除、屏蔽、不可见内容
-> 返回页面和 next_cursor
```

这里有几个关键点：

1. `home_timeline` 存的是候选 ID，不是最终完整页面。
2. 大 V 内容在读时合并，避免写扩散。
3. 删除和屏蔽在返回前再做一次过滤，避免派生视图里有旧数据。
4. 分页用 cursor，不用 offset。

---

## 第四轮：fanout 策略追问

### 1. 面试官追问

**面试官：**  
为什么不所有人都 fanout-on-read？这样写入不是更简单吗？

### 2. 候选人回答

**候选人回答：**  
纯读时合并的发帖链路确实简单，但首页读路径会很重。

假设一个用户关注 `1000` 人。每次刷首页都要：

- 拉 1000 个作者最近 tweet
- 多路 merge
- 排序、过滤、去重
- 再分页

在首页峰值 `10 万+ QPS` 时，这个读放大会非常重，而且每个用户关注集合不同，缓存命中率也差。

所以普通作者的内容更适合提前推到粉丝 home_timeline，换取读路径简单。

### 3. 面试官继续追问

**面试官：**  
那为什么不所有人都 fanout-on-write？

### 4. 候选人回答

**候选人回答：**  
纯写时 fanout 对普通用户很好，但大 V 会造成极端写扩散。

如果大 V 有 `1000 万` 粉丝，一条 tweet 就要写 `1000 万` 条 inbox entry。  
这不仅成本高，还会让发布延迟、队列积压、缓存更新都变得不可控。

所以我会按作者粉丝数或活跃粉丝数分层：

- 普通作者：fanout-on-write
- 中等作者：可以写时 fanout 到活跃粉丝，冷粉丝读时补
- 超级大 V：fanout-on-read，加热点缓存

这个策略的核心是：  
不要按“用户平均值”设计，而要按关注图的长尾分布设计。

---

## 第五轮：分页、删除、取关和重建

### 1. 面试官追问分页

**面试官：**  
首页分页怎么避免重复和漏数据？

**候选人回答：**  
我会用 cursor-based pagination，而不是 offset。

cursor 可以包含：

```text
last_score / last_created_at
last_tweet_id
feed_version
```

下一页用：

```text
WHERE (score, tweet_id) < (?, ?)
ORDER BY score DESC, tweet_id DESC
LIMIT 20
```

如果只是时间倒序，cursor 可以是：

```text
last_created_at + last_tweet_id
```

这样比 offset 更稳定，也更适合不断有新 tweet 插入的时间流。

### 2. 面试官追问删除

**面试官：**  
如果作者删除了 tweet，已经 fanout 到很多人的首页了怎么办？

**候选人回答：**  
我不会同步清理所有 home_timeline entry，因为成本太高，而且可能造成大规模写风暴。

我会把 tweet store 作为真相源：

1. Tweet 标记 `deleted_at`
2. Feed 返回前批量加载详情时过滤已删除内容
3. 异步清理热门缓存和部分 timeline entry
4. 后台任务慢慢清理派生视图

所以首页 timeline 是派生视图，可以短时间有脏引用，但不能返回已删除内容。  
最终返回前的权限和删除过滤是兜底。

### 3. 面试官追问取关

**面试官：**  
用户取关后，旧内容怎么处理？

**候选人回答：**  
我会区分新请求语义和历史残留。

- 取关关系本身要尽快写入 follow graph
- 后续新 fanout 不再进入这个用户首页
- 已经在 home_timeline 里的旧内容可以异步清理
- 返回前也可以基于最新 follow graph 做过滤

如果产品要求取关后立刻看不到对方所有内容，那读路径就必须做最新关系过滤，代价更高。  
如果允许短暂残留，可以降低成本。

这里我会向产品确认语义，而不是默认强一致。

### 4. 面试官追问重建

**面试官：**  
如果 home_timeline 因为 bug 或丢数据坏了，怎么恢复？

**候选人回答：**  
因为 home_timeline 是派生视图，所以要支持重建。

重建方式可以是：

1. 读取用户关注列表
2. 拉取关注作者最近一段时间的 author_timeline
3. 合并排序
4. 重新写入该用户 home_timeline

对于活跃用户可以优先重建，冷用户可以 lazy rebuild，也就是用户打开首页时发现缺失再构建。

---

## 第六轮：候选人 3 分钟完整回答

**面试官：**  
你用几分钟完整总结一下方案。

**候选人回答：**  
这个 Twitter Feed 系统我会先拆成 tweet 真相源、作者时间线和首页时间线三个核心对象。Tweet Store 保存正文和元数据；Author Timeline 是作者维度的 append-only 列表，用于个人主页；Home Feed 是读者维度的派生候选列表，用于首页低延迟读取。

从容量估算看，首页读 QPS 会远大于发帖 QPS，而且关注图有明显长尾：普通用户 fanout 成本可控，但大 V 一条 tweet 可能要写千万级 timeline entry。因此我不会选择单一的 fanout 策略，而会做混合方案：普通用户 fanout-on-write，把 tweet_id 写入粉丝的 home_timeline；超级大 V fanout-on-read，在用户刷首页时从大 V 的 author_timeline 或热点缓存拉取并合并。

发帖同步链路只负责写 tweet store、写 author timeline、产生 TweetCreated 事件，然后返回成功；fanout 异步执行。读首页时，Feed Service 读取用户 home_timeline 候选，再合并大 V 最近内容，批量加载 tweet 详情、作者信息和计数，并在返回前做删除、屏蔽和权限过滤。

分页使用 cursor，不用 offset。删除 tweet 时，tweet store 标记删除，返回前过滤，派生 timeline 异步清理。取关后，新 fanout 停止进入首页，旧候选可以异步清理或读时过滤。整体上，Home Feed 是最终一致的派生视图，Tweet Store 和 Author Timeline 更接近真相源。

---

## 案例二：面试官切到聊天系统

### 1. 面试官开题

**面试官：**  
如果我把题目换成聊天系统，比如 WhatsApp / Slack，你会怎么调整思路？

### 2. 候选人的第一反应

**候选人思考：**  
这就是第 7 课的另一个分型。聊天不是首页聚合问题，而是实时传递、连接路由、会话内顺序、多端同步、离线补拉问题。我要先明确这个转变，避免继续拿 Feed 的 fanout 逻辑硬套。

### 3. 候选人回答

**候选人回答：**  
聊天系统和 Feed 最大的区别是主矛盾变了。

Feed 主要是：

- 内容如何分发给很多读者
- 首页如何低延迟聚合
- 写扩散和读扩散怎么权衡

聊天系统主要是：

- 长连接如何接入和扩容
- 消息如何持久化
- 如何路由到接收者在线设备
- 会话内顺序怎么保证
- 离线后怎么补拉
- 多端状态怎么同步

所以我会先从消息语义和连接规模开始，而不是从缓存首页候选开始。

---

## 聊天系统的澄清与估算

### 1. 候选人澄清问题

**候选人：**  
我会先确认：

1. 支持单聊还是也支持群聊？
2. 群规模上限是多少？
3. 是否允许多端同时在线？
4. 顺序要求是全局有序，还是会话内有序？
5. “发送成功”是指服务端持久化，还是对方已收到？
6. 是否需要已读、未读和离线消息？
7. 图片、语音、文件是否需要展开？

**面试官：**  
支持单聊和普通群聊，群最大先按 500 人。支持多端。只要求会话内顺序。发送成功指服务端持久化。需要离线消息和已读未读。媒体只存引用。

### 2. 候选人计算过程

**候选人回答：**  
我给一组估算：

- DAU：`5000 万`
- 峰值在线用户：`1000 万`
- 平均每个在线用户设备数：`1.5`
- 峰值长连接：`1500 万`
- 日消息量：`20 亿`
- 峰值发送 QPS：按平均 10 倍估算

消息 QPS：

```text
平均消息 QPS = 20 亿 / 86400 ≈ 2.3 万 QPS
峰值消息 QPS ≈ 20 万 QPS
```

连接数：

```text
峰值连接数 = 1000 万在线用户 * 1.5 设备 ≈ 1500 万连接
```

如果一台 Gateway 稳定维护 `10 万` 长连接：

```text
Gateway 数量 = 1500 万 / 10 万 = 150 台
加上冗余和多地域，可能要 200-300 台以上
```

存储量：

```text
20 亿消息 / day * 1KB ≈ 2TB / day 原始消息
加索引、副本、元数据后，可能是 5-10TB / day
```

这里的估算结论是：

- 连接层本身就是核心系统
- 消息存储要按 append-only log 思路设计
- 在线投递不能作为可靠性的唯一来源，必须有离线补拉

---

## 聊天系统主方案

### 1. 面试官追问架构

**面试官：**  
那主链路怎么设计？

### 2. 候选人回答

**候选人回答：**  
我会把聊天系统拆成五层：

1. Gateway 连接层  
   维护 WebSocket / 长连接、心跳、鉴权、上下线。

2. Routing 路由层  
   维护 `user_id -> gateway_id/device_id` 的在线路由状态。

3. Conversation 会话层  
   管理单聊、群聊、成员关系和权限。

4. Message Log 消息日志层  
   按 `conversation_id` 保存 append-only 消息，并分配会话内 `seq`。

5. State 状态层  
   维护未读、已读、送达、多端同步状态。

发送链路：

```text
发送端 -> Gateway
-> Chat Service 校验会话权限
-> Message Store 持久化消息
-> 为 conversation 分配递增 seq
-> 返回发送成功 ACK
-> Delivery Service 查询在线路由
-> 推送到接收方在线设备
-> 不在线则等待重连补拉或触发离线 push
```

这里我会定义：

- `发送成功`：服务端已持久化消息
- `送达`：目标设备收到并 ACK
- `已读`：用户把会话读游标推进到某个 seq

这三个语义必须分开。

### 3. 面试官追问顺序

**面试官：**  
会话内顺序怎么保证？

**候选人回答：**  
我只保证 `conversation_id` 维度的局部顺序，不做全局顺序。

做法是：

- 每个 conversation 有递增 `seq`
- 同一 conversation 的消息写入路由到同一个分区或同一个序号分配器
- 客户端展示时按 `seq` 排序
- 如果客户端发现 seq gap，就触发补拉

这样用户关心的一段对话顺序是稳定的，但不同会话之间不追求全局排序。

### 4. 面试官追问离线消息

**面试官：**  
如果接收方离线，消息怎么保证不丢？

**候选人回答：**  
聊天可靠性不能依赖在线推送。  
在线推送只是加速层，真正兜底是 Message Log。

接收方离线时：

1. 消息已经写入 conversation message log
2. 用户会话列表更新 last_seq 和未读摘要
3. 用户重连后带上每个会话的 `last_received_seq` 或 `last_read_seq`
4. 服务端按 seq 补拉缺失消息

所以即使推送失败，用户也可以通过补拉恢复。

### 5. 面试官追问未读

**面试官：**  
未读数怎么做？给每条消息每个用户写一条状态吗？

**候选人回答：**  
不建议默认这么做，尤其群聊会写爆。

更常见的做法是：

```text
conversation_state:
- conversation_id
- last_seq

user_conversation_state:
- user_id
- conversation_id
- last_read_seq
- last_delivered_seq
```

未读数可以近似为：

```text
unread = conversation.last_seq - user_conversation.last_read_seq
```

小群可以支持更精细的逐人已读；大群可以退化成已读人数、最近已读摘要或只维护用户自己的读游标。  
这是一种用精度换写放大的 trade-off。

---

## 聊天系统 2 分钟总结

**面试官：**  
你总结一下聊天系统方案。

**候选人回答：**  
聊天系统我会先定义语义：发送成功是服务端持久化，送达是设备 ACK，已读是用户推进会话读游标。系统只保证会话内顺序，不做全局顺序。

架构上分为 Gateway 连接层、Routing 路由层、Conversation 会话层、Message Log 消息层和 State 状态层。发送端通过 Gateway 进来后，Chat Service 校验权限，把消息写入按 conversation 分区的 append-only log，并分配 conversation seq。持久化成功后返回发送 ACK，再由 Delivery Service 根据在线路由推给接收方多端设备。

在线推送只是加速层，不是可靠性真相源。接收方离线或推送失败时，用户重连后根据 last_received_seq / last_read_seq 从 Message Log 补拉。未读不按“每条消息每个用户”写状态，而是维护每个用户在每个会话里的 last_read_seq，用 last_seq 差值计算未读。群聊按规模分层，小群可以做更细已读，大群要控制写放大。

---

## 面试复盘：这一题真正考什么

### 1. Feed 部分的得分点

- 先区分 `Author Timeline` 和 `Home Feed`
- 先做读写和 fanout 估算
- 能解释为什么普通用户 push、大 V pull
- 能说明 Home Feed 是派生视图，不是真相源
- 能处理删除、取关、分页、重建
- 能把缓存对象说成候选 ID、tweet 详情、用户信息，而不是只说 Redis

### 2. 聊天部分的得分点

- 先区分聊天和 Feed 的主矛盾
- 能估算长连接数，而不只估 QPS
- 能定义发送成功、送达、已读三种语义
- 能说明会话内顺序，而不是全局顺序
- 能把在线推送和离线补拉拆开
- 能用 `last_read_seq` 解释未读，而不是逐消息逐用户写状态

### 3. 常见失误

1. 一上来堆组件  
   比如 “Redis + Kafka + MySQL + WebSocket”，但没有解释对象和语义。

2. 把 Feed 和 Timeline 混成一张表  
   结果无法解释首页和作者主页为什么访问模式不同。

3. fanout 策略一刀切  
   不区分普通用户和大 V，忽略关注图长尾。

4. 把聊天当成消息队列题  
   只说 MQ 推送，不讲连接、路由、seq、ACK、补拉、多端。

5. 过度承诺强一致  
   比如首页删除立刻清理所有副本、聊天全局严格有序、消息 exactly-once，这些都很容易被追问打穿。

## 最后记忆模板

社交类题型面试时，可以先问自己：

```text
这是 Feed，Timeline，还是 Chat？
```

如果是 Feed：

```text
对象：Tweet / Follow / Author Timeline / Home Feed
估算：读 QPS / 写 QPS / follow edge / fanout 放大
策略：普通用户 push，大 V pull
异常：删除、取关、分页、重建、热点
```

如果是 Chat：

```text
对象：Gateway / Routing / Conversation / Message Log / Read State
估算：在线连接数 / 消息 QPS / 存储量
语义：发送成功 / 送达 / 已读
策略：会话内顺序、在线推送、离线补拉、多端同步
异常：重复投递、seq gap、Gateway 故障、群聊写放大
```

这套模板背后的核心不是固定答案，而是先识别主矛盾：  
Feed 是首页聚合和分发权衡，聊天是连接路由和状态同步。

---

## 口头练习题

1. 用 3 分钟解释：为什么 Twitter 的 `Home Feed` 不是 `Author Timeline`。
2. 用 5 分钟算一遍：`1 亿 DAU`、每天刷首页 `10 次`、每天发帖 `1 亿`，读写 QPS 和 fanout 放大分别是多少。
3. 用 3 分钟解释：为什么大 V 不适合全量 fanout-on-write。
4. 用 5 分钟解释：聊天系统里“发送成功、送达、已读”为什么不是一回事。
5. 用 5 分钟解释：为什么聊天系统的可靠性要靠 Message Log + 补拉，而不是只靠在线推送。
