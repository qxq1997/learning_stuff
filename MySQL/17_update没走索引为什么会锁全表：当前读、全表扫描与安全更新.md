# MySQL - 第 17 课：update 没走索引为什么会锁全表：当前读、全表扫描与安全更新

> 这一课讨论一个很真实的线上事故：一条 `update` 忘了带主键条件，或者 `where` 条件没有走索引，结果把业务打停了。它不是因为 InnoDB 真的给表加了一个“表锁”，而是因为 `update` 是当前读，没走索引时只能全表扫描，扫描过程中会给大量索引记录加行级锁，效果接近把整张表锁住。

## 学习目标

- 能解释为什么 `update` 会加 X 锁，并且锁通常到事务提交才释放。
- 能区分“真的表锁”和“全表扫描导致大量行级锁，效果像锁全表”。
- 能从索引扫描路径推导：唯一索引命中时只锁一行，没走索引时会锁住大量 next-key 区间。
- 能说明为什么 `where` 里写了索引列，也不一定真的走索引。
- 能用 `EXPLAIN UPDATE`、`performance_schema.data_locks` 和 `data_lock_waits` 验证锁范围与阻塞关系。
- 能给出生产环境执行 `update/delete` 前的安全检查清单。

## 事故为什么会发生？

很多线上事故不是 SQL 写错成：

```sql
update t_stu
set score = 100;
```

这种一眼能看出来的全表更新，而是写成了看似只会改一行的语句：

```sql
update t_stu
set score = 100
where name = '小林';
```

如果 `name` 没有索引，InnoDB 找不到一条“直接定位到小林”的访问路径，只能从头到尾扫描表。扫描过程中，`update` 又不是普通快照读，而是当前读，需要对扫描到的索引记录加锁。

于是，业务上你以为它只是在改 `name = '小林'` 这一行；存储引擎视角里，它却可能扫描并锁住了整张表的聚簇索引记录和间隙。

这就是事故的本质：

```text
不是 update 天然锁全表，
而是 update 没走索引 -> 全表扫描 -> 扫描到的索引记录大量加锁 -> 效果接近锁全表。
```

下面用一个小表把这个过程拆开。

## 实验表

假设有一张表 `t_stu`：

```sql
create table t_stu (
  id bigint primary key,
  name varchar(64),
  score int
) engine = InnoDB;
```

其中 `id` 是主键索引，`name` 没有索引。

表中数据：

| id | name | score |
| --- | --- | --- |
| 1 | 小林 | 50 |
| 5 | 小明 | 68 |
| 10 | 小红 | 86 |
| 15 | 小飞 | 87 |

主键索引顺序是：

```text
1 -> 5 -> 10 -> 15
```

主键记录之间的间隙是：

```text
(-∞,1), (1,5), (5,10), (10,15), (15,+∞)
```

接下来的讨论基于：

- 存储引擎：InnoDB。
- 隔离级别：RR，可重复读。
- SQL 在显式事务中执行，锁会持有到事务提交或回滚。

## 情况一：where 使用唯一索引，只锁命中的记录

事务 A：

```sql
begin;

update t_stu
set score = 100
where id = 1;
```

事务 B：

```sql
begin;

update t_stu
set score = 77
where id = 5;
```

因为 `id` 是主键索引，`where id = 1` 是唯一索引等值查询，并且记录存在。InnoDB 可以直接在主键 B+ 树上定位到 `id = 1` 这一条记录。

在 RR 下，唯一索引等值查询命中记录时，next-key lock 会退化成记录锁，所以事务 A 主要加的是：

```text
PRIMARY 上 id = 1 的 X 型记录锁
```

用 `data_locks` 看，大致会出现：

```text
LOCK_TYPE: TABLE
LOCK_MODE: IX
LOCK_STATUS: GRANTED

LOCK_TYPE: RECORD
INDEX_NAME: PRIMARY
LOCK_MODE: X,REC_NOT_GAP
LOCK_STATUS: GRANTED
LOCK_DATA: 1
```

这里 `X,REC_NOT_GAP` 表示 X 型记录锁，只锁 `id = 1` 这条记录，不锁它前后的间隙。

因此事务 B 更新 `id = 5` 不会被事务 A 阻塞：

```text
事务 A 锁 id = 1
事务 B 锁 id = 5
两者不是同一条记录，不冲突
```

这就是“带主键条件”的正常状态：锁很小，影响面可控。

## 情况二：where 没走索引，效果接近锁全表

现在把事务 A 的 SQL 改成：

```sql
begin;

update t_stu
set score = 100
where name = '小林';
```

`name` 没有索引，优化器只能选择全表扫描。InnoDB 实际扫描的是聚簇索引，也就是主键索引：

```text
1 -> 5 -> 10 -> 15
```

在 RR 隔离级别下，`update` 是当前读。当前读为了保证读到的是最新可修改版本，同时避免幻读，会在扫描过程中对索引记录加锁。

这时事务 A 可能加到这些 next-key lock：

```text
(-∞,1]
(1,5]
(5,10]
(10,15]
(15,+∞]
```

换成更直观的说法：

- 4 条已有记录都被锁住：`1`、`5`、`10`、`15`。
- 5 个间隙也被锁住：`(-∞,1)`、`(1,5)`、`(5,10)`、`(10,15)`、`(15,+∞)`。

这就等价于：

```text
表里的已存在记录不能被其他事务更新/删除；
表里几乎所有位置也不能插入新记录。
```

所以当事务 B 执行：

```sql
begin;

update t_stu
set score = 77
where id = 5;
```

事务 B 需要给 `id = 5` 加 X 型记录锁。但事务 A 的全表扫描已经持有包含 `id = 5` 的 next-key lock，也包含 `id = 5` 这个记录锁部分，所以事务 B 会被阻塞。

这个现象很容易让人说成：

> update 没加索引会加表锁。

但更准确的说法是：

> update 没走索引会全表扫描，扫描过程中给大量索引项加行级锁，效果接近锁住整张表。

这两句话在排查上差别很大。前者会让你只去找表锁；后者会让你去看执行计划、扫描路径和 `data_locks` 里的行级锁。

## 为什么只匹配一行，也会锁很多行？

问题来了：

```sql
where name = '小林'
```

最后明明只有 `id = 1` 这一行符合条件，为什么 `id = 5` 也会被锁？

原因是：没有索引时，InnoDB 无法提前知道哪一行是“小林”。它只能沿着聚簇索引一行行扫描。

扫描过程大致是：

```text
读 id=1，判断 name 是否等于 '小林'
读 id=5，判断 name 是否等于 '小林'
读 id=10，判断 name 是否等于 '小林'
读 id=15，判断 name 是否等于 '小林'
```

对 `update/delete/select ... for update` 这种当前读来说，扫描不是“无锁看一眼”。为了保证当前读和后续修改的正确性，它会对扫描路径上的索引记录加锁。

所以锁范围不是由“最终改了几行”决定的，而是由：

```text
执行计划选择了什么访问路径
扫描了哪些索引记录
隔离级别下当前读需要怎样加锁
```

共同决定。

这也是线上最危险的一点：

```text
Rows affected = 1
不代表 Rows locked = 1
```

一条 SQL 最后可能只改 1 行，但它为了找到这一行，扫描并锁住了大量记录。

## 不是有 where 条件就安全

很多人会把风险简化成：

```text
update/delete 一定要带 where
```

这句话只说对了一半。

生产上真正要检查的是：

```text
where 条件是否能走合适的索引？
优化器最终是否真的选择了索引扫描？
扫描行数是否可控？
事务会持锁多久？
```

例如下面这条 SQL 虽然带了 `where`，但如果 `name` 没有索引，仍然危险：

```sql
update t_stu
set score = 100
where name = '小林';
```

再比如，`name` 有索引，也不代表一定安全。下面这些情况都可能让优化器放弃索引，或者让索引失效：

- 对索引列使用函数：`where lower(name) = 'xiaolin'`。
- 对索引列做计算：`where id + 1 = 10`。
- 隐式类型转换：字符串列拿数字比较。
- 字符集或排序规则不一致导致转换。
- 模糊查询左通配：`where name like '%林'`。
- 选择性太差，优化器认为全表扫描更便宜。
- 统计信息过旧，优化器估算错误。

所以安全标准不是“看 SQL 文本里有没有索引列”，而是看执行计划。

## 如何确认 update 是否走索引？

执行前先看执行计划：

```sql
explain
update t_stu
set score = 100
where name = '小林';
```

重点看这些列：

| 字段 | 关注点 |
| --- | --- |
| `type` | 是否为 `ALL`。`ALL` 通常表示全表扫描 |
| `possible_keys` | 理论上可用的索引 |
| `key` | 优化器最终选择的索引 |
| `rows` | 预计扫描行数 |
| `filtered` | 条件过滤比例 |
| `Extra` | 是否出现 `Using where`、`Using index condition` 等 |

如果看到：

```text
type: ALL
key: NULL
rows: 很大
```

这条 `update` 就非常危险。

对于生产变更，更建议直接用同样谓词做多层确认：

```sql
explain
update t_stu
set score = 100
where name = '小林';

select count(*)
from t_stu
where name = '小林';

select id
from t_stu
where name = '小林'
limit 20;
```

注意：`select` 的执行计划不一定与 `update` 完全相同，所以最终仍要以 `EXPLAIN UPDATE` 为准。

## where 有索引但优化器不走怎么办？

如果 `where` 条件已经有合适索引，但优化器因为统计信息或成本估算选择了全表扫描，可以先考虑：

```sql
analyze table t_stu;
```

让统计信息更新后，再重新看执行计划。

如果仍然选错，并且你确认使用某个索引更安全，可以使用索引提示：

```sql
update t_stu force index(PRIMARY)
set score = 100
where id = 1;
```

或：

```sql
update t_stu force index(idx_name)
set score = 100
where name = '小林';
```

但 `force index` 不应该变成常规偷懒手段。它把选择权从优化器手里拿回来，也意味着未来数据分布变化后，这条 SQL 可能继续被强行绑定在一个不再合适的索引上。

更稳的顺序是：

1. 先确认索引设计是否正确。
2. 再确认统计信息是否准确。
3. 再看 SQL 写法是否破坏了 SARGable。
4. 最后才考虑 `force index`。

## 用 data_locks 验证到底锁了什么

如果你已经在测试环境复现，可以用：

```sql
select *
from performance_schema.data_locks\G
```

好情况：唯一索引命中一行。

```text
INDEX_NAME: PRIMARY
LOCK_TYPE: RECORD
LOCK_MODE: X,REC_NOT_GAP
LOCK_STATUS: GRANTED
LOCK_DATA: 1
```

说明它锁的是 `id = 1` 这一条记录。

坏情况：全表扫描。

你可能看到一串行级锁：

```text
INDEX_NAME: PRIMARY
LOCK_TYPE: RECORD
LOCK_MODE: X
LOCK_DATA: 1

INDEX_NAME: PRIMARY
LOCK_TYPE: RECORD
LOCK_MODE: X
LOCK_DATA: 5

INDEX_NAME: PRIMARY
LOCK_TYPE: RECORD
LOCK_MODE: X
LOCK_DATA: 10

INDEX_NAME: PRIMARY
LOCK_TYPE: RECORD
LOCK_MODE: X
LOCK_DATA: 15

INDEX_NAME: PRIMARY
LOCK_TYPE: RECORD
LOCK_MODE: X
LOCK_DATA: supremum pseudo-record
```

在 `data_locks` 中：

| 表现 | 含义 |
| --- | --- |
| `LOCK_TYPE=RECORD` | 行级锁，不等于“记录锁” |
| `LOCK_MODE=X` | X 型 next-key lock |
| `LOCK_MODE=X,REC_NOT_GAP` | X 型记录锁 |
| `LOCK_MODE=X,GAP` | X 型间隙锁 |
| `LOCK_DATA=supremum pseudo-record` | 最大记录之后的虚拟边界，常对应最后一个间隙 |

如果事务 B 被阻塞，可以继续看等待关系：

```sql
select *
from performance_schema.data_lock_waits\G
```

也可以关联事务表：

```sql
select
  r.trx_id as waiting_trx_id,
  r.trx_mysql_thread_id as waiting_thread,
  r.trx_query as waiting_sql,
  b.trx_id as blocking_trx_id,
  b.trx_mysql_thread_id as blocking_thread,
  b.trx_query as blocking_sql
from performance_schema.data_lock_waits w
join information_schema.innodb_trx r
  on w.requesting_engine_transaction_id = r.trx_id
join information_schema.innodb_trx b
  on w.blocking_engine_transaction_id = b.trx_id\G
```

这类查询的目标不是背字段，而是回答三个问题：

```text
谁在等？
等哪把锁？
这把锁被谁持有？
```

## 普通 select 会被阻塞吗？

在 RR 或 RC 下，普通 `select` 通常是快照读，靠 MVCC 读历史版本，不会因为这些行锁而阻塞：

```sql
select *
from t_stu
where id = 5;
```

但下面这些会进入当前读或写路径，可能被阻塞：

```sql
select *
from t_stu
where id = 5
for update;

update t_stu
set score = 77
where id = 5;

delete from t_stu
where id = 5;

insert into t_stu(id, name, score)
values(3, '新同学', 60);
```

如果事务 A 全表扫描加了大量 next-key lock，其他事务的 `update/delete/insert/select ... for update` 都可能被影响。业务表现就是：读接口可能还活着，但写链路大量卡住。

## sql_safe_updates：给手工操作加护栏

MySQL 提供了一个安全更新模式：

```sql
set session sql_safe_updates = 1;
```

开启后，MySQL 会拒绝一些危险的 `update/delete`。典型效果是：如果 `update/delete` 没有使用 key 条件，也没有 `limit` 约束，就不允许执行。

例如：

```sql
update t_stu
set score = 100
where name = '小林';
```

如果 `name` 没有索引，安全更新模式可能直接报错，避免你在交互式终端里一把梭。

`mysql` 命令行客户端也可以开启安全模式：

```bash
mysql --safe-updates
```

不过要注意：

**`sql_safe_updates` 是护栏，不是最终安全保证。**

原因有三个：

1. 它主要防手工误操作，不能替代 SQL 审核和执行计划检查。
2. 有索引列不代表优化器一定选择索引。
3. `limit` 可以防止一次改太多行，但不能保证锁范围一定小。

所以生产上不要把安全寄托在一个参数上。

## 生产执行 update/delete 前的检查清单

建议把下面这份清单变成团队习惯。

### 1. 必须先确认执行计划

```sql
explain
update ...
```

确认：

- `type` 不是危险的 `ALL`。
- `key` 是预期索引。
- `rows` 在可接受范围。
- 谓词没有函数、隐式转换、左模糊等索引失效问题。

### 2. 必须先确认影响行数

```sql
select count(*)
from ...
where ...;
```

如果影响行数超过预期，先停下来。

### 3. 大批量更新要拆批

不要一次更新几十万、几百万行。用主键分批：

```sql
update t_stu
set score = score + 1
where id > 10000
  and id <= 11000;
```

每批提交一次，降低单个事务持锁时间。

### 4. 事务要短

不要：

```sql
begin;
update ...
然后去查日志、看监控、等人工确认;
commit;
```

锁会一直持有到提交。事务越长，阻塞范围越难控。

### 5. 给手工会话设置超时

可以在手工变更会话里设置：

```sql
set session innodb_lock_wait_timeout = 5;
set session sql_safe_updates = 1;
```

`innodb_lock_wait_timeout` 不能防止你锁别人，但可以避免你长时间等待别人时把现场拖得更乱。

### 6. 变更前准备回滚方案

只会写：

```sql
update ...
```

还不够。生产变更还要提前准备：

- 备份或可逆 SQL。
- 影响行数预估。
- 执行窗口。
- 失败时回滚方式。
- 监控指标：锁等待、慢 SQL、错误率、连接数。

## 面试答法：update 没加索引为什么会锁全表？

可以这样回答：

> InnoDB 的行锁是加在索引上的。`update/delete/select ... for update` 属于当前读，会对扫描到的索引记录加锁。如果 `where` 条件使用主键或唯一索引等值命中记录，next-key lock 可以退化成记录锁，只锁目标行。但如果 `where` 条件没走索引，执行计划变成全表扫描，InnoDB 会沿着聚簇索引扫描表，在 RR 隔离级别下对扫描到的记录加 next-key lock。这样虽然不是加了真正的表锁，但表中大量记录和间隙都被锁住，效果接近锁全表，其他写操作就会被阻塞。

继续补一句会更完整：

> 所以线上执行 update/delete 不能只看有没有 where，还要看 where 是否走索引，以及优化器最终是否选择索引扫描。执行前应该 `EXPLAIN UPDATE`，看 `type/key/rows`，必要时更新统计信息或使用索引提示。手工操作可以开启 `sql_safe_updates` 做护栏。

## 小结

这一课重点记住五句话：

1. `update` 会加 X 锁，锁通常持有到事务提交或回滚。
2. InnoDB 行锁加在索引上，不是直接加在“行对象”上。
3. `where` 使用唯一索引命中记录时，锁范围通常很小，只锁目标记录。
4. `where` 没走索引时会全表扫描，扫描路径上的大量索引项会被加锁，效果接近锁全表。
5. 生产执行 `update/delete` 前，不只要看 `where`，还要看执行计划和预计扫描行数。

一句工程化总结：

```text
不要用“我觉得只改一行”判断风险；
要用执行计划、扫描路径和锁范围判断风险。
```

## 问题（用于检验有没有真的理解）

1. 为什么 `update t_stu set score=100 where id=1` 不会阻塞更新 `id=5`？
2. 为什么 `update t_stu set score=100 where name='小林'` 可能阻塞更新 `id=5`？
3. “update 没加索引会加表锁”这句话哪里不准确？
4. `Rows affected = 1` 为什么不代表只锁了 1 行？
5. `data_locks` 中 `LOCK_TYPE=RECORD` 为什么不等于记录锁？
6. `LOCK_MODE=X`、`X,REC_NOT_GAP`、`X,GAP` 分别表示什么？
7. 普通 `select` 为什么通常不会被这些行锁阻塞？
8. `where` 中出现索引列，为什么仍然可能全表扫描？
9. 生产执行 `update/delete` 前，为什么要用 `EXPLAIN UPDATE` 而不只看 SQL 文本？
10. `sql_safe_updates` 能防什么，不能防什么？
