# 缓存策略与 Redis 设计

本文档说明 TalentHub 当前哪些地方使用 Redis 缓存、为什么使用，以及缓存和数据库之间的边界。

结论先写在前面：

- 数据库仍然是唯一事实来源
- Redis 只做性能优化，不参与业务正确性
- 缓存命中失败或 Redis 短暂异常时，不允许影响核心写入链路

## 1. 设计原则

TalentHub 当前缓存设计遵守这几条规则：

1. 只缓存“读多写少、可重算”的结果。
2. 不把缓存当数据库，不把缓存当状态机。
3. 写链路优先保证数据库成功，再做缓存失效。
4. 缓存失败时记录日志，但不偷偷改写业务语义。
5. TTL 必须显式配置，不使用无限期缓存。

## 2. 当前已经落地的缓存点

### 2.1 题库标签列表缓存

接口：

- `GET /api/v1/question-bank/tags`

缓存原因：

- 标签列表会被题库筛选、出题工作台、后续组卷入口反复读取
- 它是典型的读多写少接口

缓存键：

- `question_bank:tags:v1:limit={limit}:offset={offset}:keyword={keyword}`

当前 TTL：

- `QUESTION_BANK_TAG_CACHE_TTL_SECONDS`
- 默认 `300` 秒

失效策略：

- 新建草稿题成功后失效
- 编辑题目并更新标签后失效

这里采用的是“按前缀清理”：

- `question_bank:tags:v1:*`

原因是标签列表本身维度不高，直接整组清理更简单，也更符合当前项目规模。

### 2.2 网页抓取结果缓存

接口：

- `POST /api/v1/question-bank/generation-previews/from-web-page`

缓存原因：

- 同一个 URL 在短时间内可能会被重复试出题范围、重复确认分页、重复生成
- JS 渲染抓取成本高，复用结果能明显减少等待时间

缓存键：

- `question_bank:web_page_fetch:v1:{sha256(url + nested_link_scope)}`

当前 TTL：

- `WEB_PAGE_FETCH_CACHE_TTL_SECONDS`
- 默认 `900` 秒

缓存内容：

- 页面标题
- 正文文本
- 图片线索
- 检测到的同域子页候选

失效策略：

- 当前不做主动失效
- 完全依赖 TTL 过期

这是一个刻意的选择，因为网页内容本身就是外部来源，短 TTL 即可，不需要把缓存一致性做得像内部数据库那样复杂。

## 3. 为什么当前不缓存这些地方

当前明确不缓存：

- 题目编辑详情
- 题库分页列表
- 考试提交
- 判卷结果写入
- 用户权限判断
- 学习路径进度

原因：

- 这些链路对一致性更敏感
- 当前读写量还没有高到必须用缓存换复杂度
- 先把数据库索引和查询路径做好，收益更稳

## 4. 缓存异常时怎么处理

TalentHub 当前对 Redis 的处理遵守“优化失败不影响主链路”：

- 读缓存失败：记录日志，然后直接查数据库或重新抓网页
- 写缓存失败：记录日志，但不回滚已经成功的主业务写入
- 缓存数据结构不合法：直接视为异常缓存，当前请求失败，不猜测修复方式

这里的重点是：

- 不让 Redis 影响题目保存、题目编辑这类核心写链路
- 但也不做静默修复和模糊兜底

## 5. 当前配置项

当前缓存相关配置位于：

- [backend/app/shared/config/settings.py](/Users/xinqi/WebstormProjects/TalentHub/backend/app/shared/config/settings.py)
- [backend/.env.example](/Users/xinqi/WebstormProjects/TalentHub/backend/.env.example)

主要包括：

- `REDIS_URL`
- `QUESTION_BANK_TAG_CACHE_TTL_SECONDS`
- `WEB_PAGE_FETCH_CACHE_TTL_SECONDS`

推荐第一版保持默认值：

- 标签列表：`300` 秒
- 网页抓取：`900` 秒

## 6. 后续扩展方向

当 TalentHub 后面继续长大时，优先考虑新增这些缓存，而不是一开始就全站缓存：

- 报表聚合结果缓存
- 首页统计卡片缓存
- 知识库检索结果短 TTL 缓存

仍然不建议把下面这些做成依赖缓存才能正确运行的路径：

- 考试状态流转
- 判卷总分计算
- 权限边界判断
- 幂等写入控制

一句话总结：

当前 Redis 的角色是“减少重复计算和重复抓取”，不是“接管业务状态”。
