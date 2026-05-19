# MySQL - 第 15 课：锁全景：全局锁、表级锁、MDL、AUTO-INC 与行锁

> 前面几课已经深入讲了行级锁、next-key lock、死锁和幻读。这一课把视角拉高：MySQL 里不只有行锁，还有全局锁、表锁、元数据锁、意向锁、AUTO-INC 锁。线上很多“数据库突然卡死”“DDL 执行不了”“备份影响写入”“自增主键并发异常”的问题，不是只靠 Record Lock / Gap Lock 能解释的，要把锁的层级图建立起来。

## 学习目标（本节结束后你能做到什么）

- 能按加锁范围区分全局锁、表级锁、行级锁。
- 能解释 `FLUSH TABLES WITH READ LOCK` 的作用、用途和风险。
- 能说明为什么 InnoDB 全库逻辑备份更推荐 `mysqldump --single-transaction`。
- 能解释 `LOCK TABLES ... READ/WRITE` 对当前会话和其他会话的限制。
- 能讲清 MDL 读锁、MDL 写锁为什么会让一个 DDL 拖垮整张表的访问。
- 能解释意向锁不是“想加锁”这么简单，而是用来协调表锁和行锁。
- 能说明 AUTO-INC 锁和 `innodb_autoinc_lock_mode` 的关系，以及为什么它和 `binlog_format` 有一致性关系。
- 能把行锁的 Record Lock、Gap Lock、Next-Key Lock 放回整个锁体系里定位。

## 内容讲解（核心概念，用类比、例子、图示说清楚）

从加锁范围看，MySQL 的锁可以粗略分三层：

```text
MySQL 锁
├── 全局锁
│   └── FTWRL: FLUSH TABLES WITH READ LOCK
├── 表级锁
│   ├── 表锁: LOCK TABLES ... READ/WRITE
│   ├── 元数据锁: MDL
│   ├── 意向锁: IS / IX
│   └── AUTO-INC 锁
└── 行级锁（InnoDB）
    ├── Record Lock
    ├── Gap Lock
    ├── Next-Key Lock
    └── Insert Intention Lock
```

这三层不要混：

- 全局锁影响整个实例里的库表写入。
- 表级锁影响某张表或某些表。
- 行级锁影响某个索引记录或索引范围。

很多问题的排查第一步，就是先判断：

**这个阻塞到底发生在全局、表级，还是行级？**

如果判断错了，就会越查越远。

## 全局锁：FTWRL

### 1. 全局锁怎么加？

MySQL 提供了一个全局读锁：

```sql
flush tables with read lock;
```

通常简称 FTWRL。

执行后，整个数据库实例进入只读状态。其他会话的这些操作会被阻塞：

- 数据写入：`insert`、`update`、`delete`。
- 表结构变更：`alter table`、`drop table`、`truncate table` 等。
- 可能改变数据或元数据的操作。

释放全局锁：

```sql
unlock tables;
```

如果持有全局锁的会话断开，锁也会自动释放。

### 2. 全局锁用来干什么？

典型用途是：

**全库逻辑备份。**

比如使用 `mysqldump` 导出整个实例的数据。如果备份期间业务还在写，可能出现跨表不一致。

举个电商下单例子：

1. 备份工具先导出了 `user` 表。
2. 用户下单，扣减用户余额，同时扣减商品库存。
3. 备份工具再导出 `goods` 表。

最后备份文件里可能出现：

| 表 | 备份结果 |
| --- | --- |
| `user` | 余额还没扣 |
| `goods` | 库存已经扣 |

如果用这份备份恢复，就会出现“用户余额没少，但库存少了”的不一致。

FTWRL 的作用就是在备份期间冻结写入，让备份看到一个静止的全库状态。

### 3. 全局锁的代价

FTWRL 很粗暴：

```text
一锁，全库只读。
```

如果数据量很大，逻辑备份可能持续很久。备份期间业务读请求还能走，但写请求会堆积，严重时会造成业务停滞。

所以 FTWRL 不是日常随便用的工具，它适合：

- MyISAM 这类不支持事务一致性快照的表。
- 特殊维护场景。
- 短时间冻结实例状态。

对于 InnoDB，全库逻辑备份通常有更好的方式。

### 4. InnoDB 备份为什么更推荐 `--single-transaction`？

InnoDB 支持 MVCC 和 RR 隔离级别。逻辑备份可以在开始时启动一个事务，创建 Read View，然后整个备份过程都读这个一致性快照。

`mysqldump` 可以使用：

```bash
mysqldump --single-transaction ...
```

它会在导出前开启一个事务。备份期间：

- 备份事务看到的是开始备份时的一致性视图。
- 其他业务事务仍然可以继续写入。
- 备份结果对 InnoDB 表来说是事务一致的。

这比 FTWRL 友好很多。

但要注意几个边界：

- `--single-transaction` 主要适用于支持事务的表，比如 InnoDB。
- 如果库里混有 MyISAM 表，MyISAM 表没有事务快照，仍可能不一致。
- 备份期间尽量避免 DDL，因为 DDL 会涉及 MDL、隐式提交和表结构变化，可能破坏备份稳定性或导致阻塞。

所以一个简单判断是：

| 场景 | 更适合 |
| --- | --- |
| 全部 InnoDB，做逻辑备份 | `mysqldump --single-transaction` |
| 有非事务表，必须全局一致 | FTWRL 或其他备份方案 |
| 需要在线热备大库 | 优先考虑物理备份工具和复制架构 |

## 表锁：`LOCK TABLES`

### 5. 表锁怎么用？

MySQL 可以显式给表加锁：

```sql
lock tables t_test read;
```

或者：

```sql
lock tables t_test write;
```

释放当前会话持有的表锁：

```sql
unlock tables;
```

会话断开也会释放表锁。

### 6. READ 表锁的行为

会话 A：

```sql
lock tables t_test read;
```

这表示对 `t_test` 加表级共享锁。

当前会话 A：

- 可以读 `t_test`。
- 不能写 `t_test`。
- 不能访问没有被 `LOCK TABLES` 锁住的其他表。

如果 A 执行：

```sql
update t_test
set name = 'xiaolin'
where id = 1;
```

会报类似错误：

```text
ERROR 1099 (HY000): Table 't_test' was locked with a READ lock and can't be updated
```

如果 A 执行：

```sql
select *
from t_student;
```

也会报错：

```text
ERROR 1100 (HY000): Table 't_student' was not locked with LOCK TABLES
```

其他会话：

- 可以读 `t_test`。
- 写 `t_test` 会阻塞。

### 7. WRITE 表锁的行为

会话 A：

```sql
lock tables t_test write;
```

当前会话 A：

- 可以读 `t_test`。
- 可以写 `t_test`。
- 仍然不能访问未锁住的其他表。

其他会话：

- 读 `t_test` 会阻塞。
- 写 `t_test` 会阻塞。

所以 `LOCK TABLES ... WRITE` 是非常强的锁。

### 8. 表锁的几个坑

`LOCK TABLES` 在 InnoDB 场景下不常用，主要因为它太粗，容易伤并发。

几个容易忽略的点：

1. 它会限制当前会话只能访问已经锁住的表。
2. `LOCK TABLES` 会隐式提交当前事务。
3. 它和 InnoDB 行锁不是一个粒度，混着用很容易让事务语义变复杂。
4. 大部分 InnoDB 业务并发控制，应该优先用事务、行锁、唯一约束和锁定读，而不是手动表锁。

在 InnoDB 表上，如果你只是想保护某几行，通常应该用：

```sql
select *
from t_test
where id = 1
for update;
```

而不是：

```sql
lock tables t_test write;
```

## 元数据锁：MDL

### 9. MDL 是什么？

MDL 是 Metadata Lock，元数据锁。

它保护的是：

**表结构元数据。**

你不需要显式加 MDL。MySQL 会自动加：

| 操作 | 自动加的 MDL |
| --- | --- |
| `select` / `insert` / `update` / `delete` | MDL 读锁 |
| `alter table` / `drop table` / `truncate table` 等 DDL | MDL 写锁 |

MDL 的目的很朴素：

**防止一个会话正在读写表时，另一个会话把表结构改了。**

比如会话 A 正在执行：

```sql
select *
from user
where id = 1;
```

如果会话 B 同时执行：

```sql
alter table user drop column name;
```

那 A 读到一半，列没了，这肯定不行。MDL 就是为了挡住这种元数据并发冲突。

### 10. MDL 的兼容关系

可以简化为：

| 已持有 \ 请求 | MDL 读锁 | MDL 写锁 |
| --- | --- | --- |
| MDL 读锁 | 兼容 | 不兼容 |
| MDL 写锁 | 不兼容 | 不兼容 |

所以多个 CRUD 可以并发，因为它们拿的是 MDL 读锁。

但 DDL 要拿 MDL 写锁，会和 CRUD 的 MDL 读锁冲突。

### 11. MDL 什么时候释放？

这点非常关键：

**MDL 通常在事务结束时释放。**

如果是 autocommit 模式下的一条普通语句，语句执行完，事务也结束，MDL 很快释放。

但如果显式开启了事务：

```sql
begin;

select *
from user
where id = 1;

-- 长时间不 commit
```

这条 `select` 拿到的 MDL 读锁会一直持有到事务提交或回滚。

也就是说：

```sql
commit;
-- 或
rollback;
```

之前，MDL 读锁还在。

### 12. 一个 DDL 为什么会拖垮整张表的访问？

这是线上非常经典的事故。

时序：

| 时间 | 会话 | 操作 | 锁状态 |
| --- | --- | --- | --- |
| T1 | A | `begin; select * from user where id=1;` | 持有 MDL 读锁，不提交 |
| T2 | B | `select * from user where id=2;` | MDL 读锁兼容，正常执行 |
| T3 | C | `alter table user add column c int;` | 申请 MDL 写锁，被 A 阻塞 |
| T4 | D/E/F | 大量新 `select/update` | 排在 C 后面，也被阻塞 |

最迷惑的是 T4：

明明 MDL 读锁之间兼容，为什么后来的 `select` 也被阻塞？

原因是：

**MDL 请求有队列，写锁优先级高。一旦有 MDL 写锁在等待，后续新的 MDL 读锁不能再插队，否则 DDL 可能永远等不到。**

于是一个长事务 A + 一个 DDL C，就可能把后续对这张表的所有请求堵住，线程数迅速上涨。

这类问题常见现象：

- `show processlist` 里大量 `Waiting for table metadata lock`。
- 业务查询突然大量堆积。
- 真正罪魁祸首可能是最早那个没提交的长事务，而不是 DDL 本身。

### 13. MDL 线上排查

常用命令：

```sql
show processlist;
```

看有没有：

```text
Waiting for table metadata lock
```

看长事务：

```sql
select *
from information_schema.innodb_trx\G
```

如果开启了 `performance_schema.metadata_locks`，可以查：

```sql
select *
from performance_schema.metadata_locks
where object_schema = 'your_db'
  and object_name = 'your_table'\G
```

实际处理时要谨慎：

1. 找到最早持有 MDL 读锁的长事务。
2. 确认它是否可以结束或 kill。
3. 如果 DDL 已经排队并阻塞大量请求，要考虑先 kill DDL，让业务恢复，再重新安排 DDL。
4. 线上 DDL 尽量设置超时、低峰执行，并先检查长事务。

例如：

```sql
select trx_id, trx_started, trx_mysql_thread_id, trx_query
from information_schema.innodb_trx
order by trx_started;
```

找到线程后：

```sql
kill <thread_id>;
```

不要机械 kill，要先确认业务影响。

## 意向锁：表锁和行锁之间的协调员

### 14. 意向锁是什么？

InnoDB 的意向锁是表级锁，主要有两种：

| 意向锁 | 英文 | 含义 |
| --- | --- | --- |
| 意向共享锁 | IS | 表示事务准备在表里的某些行上加 S 锁 |
| 意向独占锁 | IX | 表示事务准备在表里的某些行上加 X 锁 |

注意：

**意向锁是表级锁，但它服务于行级锁。**

例如：

```sql
begin;

select *
from user
where id = 1
for share;
```

大致会先在表上加 IS，再在目标行上加 S 锁。

```sql
begin;

select *
from user
where id = 1
for update;
```

大致会先在表上加 IX，再在目标行上加 X 锁。

`insert`、`update`、`delete` 也会涉及 IX，因为它们要修改行。

### 15. 为什么需要意向锁？

假设没有意向锁。

事务 A 已经对表里某一行加了 X 行锁：

```text
user 表中 id = 1 这行被加 X 锁
```

此时事务 B 想加整张表的写锁：

```sql
lock tables user write;
```

为了判断能不能加表写锁，MySQL 需要知道表里有没有任何行已经被锁。

如果没有意向锁，它可能要遍历整张表所有行锁，效率非常差。

有了意向锁后：

1. 事务 A 给某行加 X 锁前，先在表上加 IX。
2. 事务 B 想加表写锁时，只要发现表上有 IX，就知道表里有行正被独占锁保护。
3. B 直接等待，不需要扫描每行。

所以：

**意向锁的核心作用，是让表级锁快速判断表内是否存在行级锁。**

### 16. 意向锁和谁冲突？

意向锁之间通常不冲突：

| 已持有 \ 请求 | IS | IX |
| --- | --- | --- |
| IS | 兼容 | 兼容 |
| IX | 兼容 | 兼容 |

因为多个事务当然可以同时准备锁不同的行。

意向锁主要和显式表锁冲突。

可以简化理解：

| 表级锁请求 | 遇到 IS | 遇到 IX |
| --- | --- | --- |
| `LOCK TABLES ... READ` | 通常兼容 | 冲突 |
| `LOCK TABLES ... WRITE` | 冲突 | 冲突 |

不要把意向锁和插入意向锁混淆：

| 名称 | 级别 | 作用 |
| --- | --- | --- |
| IS / IX 意向锁 | 表级锁 | 协调表锁和行锁 |
| Insert Intention Lock 插入意向锁 | 行级锁中的特殊 gap lock | 表示想往某个间隙插入记录 |

名字相似，但不是一类东西。

## AUTO-INC 锁：自增主键背后的锁

### 17. AUTO_INCREMENT 怎么保证分配自增值？

表里常见主键：

```sql
id bigint primary key auto_increment
```

插入时可以不指定 `id`：

```sql
insert into user(name)
values('Luffy');
```

MySQL 会自动分配递增值。

这个分配过程需要并发控制，否则多个事务同时插入可能拿到重复或乱序的自增值。

InnoDB 里有 AUTO-INC 相关锁机制。

传统 AUTO-INC 锁是表级锁：

1. 插入语句开始。
2. 获取 AUTO-INC 锁。
3. 分配自增值。
4. 执行插入语句。
5. 语句结束后释放 AUTO-INC 锁。

它不是等事务提交才释放，而是语句结束释放。

### 18. 为什么 AUTO-INC 锁会影响并发？

如果一个大批量插入语句执行很久：

```sql
insert into t2(c, d)
select c, d
from t;
```

传统 AUTO-INC 锁会持有到整个语句结束。其他事务想往同一张表插入，也要等它释放。

这能保证一个语句内分配到的自增值连续，但会牺牲插入并发。

### 19. `innodb_autoinc_lock_mode`

InnoDB 提供参数控制自增锁模式：

```sql
show variables like 'innodb_autoinc_lock_mode';
```

常见取值：

| 值 | 模式 | 含义 |
| --- | --- | --- |
| `0` | traditional | 传统 AUTO-INC 表锁，语句结束释放 |
| `1` | consecutive | 简单插入用轻量级互斥，批量插入仍可能持有到语句结束 |
| `2` | interleaved | 分配自增值后尽快释放，插入并发最好，但同一语句的自增值可能不连续 |

简单插入：

```sql
insert into t(c, d)
values(1, 1);
```

批量插入：

```sql
insert into t(c, d)
select c, d
from source_table;
```

`mode = 1` 会对这两类语句区别对待。

`mode = 2` 并发最好，因为申请到自增值后就释放锁，不等语句结束。

### 20. AUTO-INC 和 binlog 为什么有关？

问题出在：

```text
主库并发执行，备库按 binlog 顺序串行回放。
```

假设 `innodb_autoinc_lock_mode = 2`，两个会话并发往同一张自增表插入。

主库可能出现这种分配：

| 时刻 | 会话 | 操作 | 得到的自增 id |
| --- | --- | --- | --- |
| T1 | B | `insert into t2(c,d) select c,d from t` 的前两行 | 1, 2 |
| T2 | A | `insert into t2 values(null,5,5)` | 3 |
| T3 | B | 同一个批量插入继续执行 | 4, 5 |

这样 B 这条语句生成的 id 不是连续的。

如果 `binlog_format = statement`，binlog 记录的是原始 SQL。备库回放时，SQL 是顺序执行的，不会和主库一样交错执行，因此备库上自增 id 可能分配成另一种结果，造成主从不一致。

解决方式：

```text
innodb_autoinc_lock_mode = 2
+ binlog_format = ROW
```

ROW 格式记录的是每行最终写入结果，包括主库分配好的自增值。备库按行结果回放，就不会因为自增分配时序不同而不一致。

所以可以这样记：

- 想要并发高，倾向 `innodb_autoinc_lock_mode = 2`。
- 使用 `mode = 2` 时，复制安全性要配合 `binlog_format = ROW`。
- 如果是 statement 格式，要非常小心自增值在并发批量插入下的不确定性。

## 行级锁：放回全景图里看

前面第 13、14 课已经详细讲过行级锁，这里只做总览。

### 21. 普通 select 不加行锁

普通查询：

```sql
select *
from user
where id = 1;
```

在 InnoDB RR 下是快照读，依靠 MVCC，不加行级锁。

### 22. 锁定读会加行锁

共享锁：

```sql
select *
from user
where id = 1
for share;
```

老写法：

```sql
select *
from user
where id = 1
lock in share mode;
```

独占锁：

```sql
select *
from user
where id = 1
for update;
```

写操作：

```sql
update user set name = 'x' where id = 1;
delete from user where id = 1;
```

这些都会进入当前读和行锁体系。

锁会持有到事务提交或回滚：

```sql
commit;
-- 或
rollback;
```

### 23. 三类核心行锁

| 锁 | 含义 | 区间 |
| --- | --- | --- |
| Record Lock | 锁一条真实索引记录 | 单点 |
| Gap Lock | 锁两条索引记录之间的间隙，不含记录本身 | `(a,b)` |
| Next-Key Lock | Gap Lock + Record Lock | `(a,b]` |

Record Lock 有 S/X 之分：

| 已持有 \ 请求 | S | X |
| --- | --- | --- |
| S | 兼容 | 不兼容 |
| X | 不兼容 | 不兼容 |

Gap Lock 之间通常兼容，因为它的目标是阻止插入幻影记录，不是保护某条真实记录。

Next-Key Lock 既能阻止往间隙插入，也能保护右边界记录不被删除或修改。

### 24. 插入意向锁

插入意向锁（Insert Intention Lock）名字里有“意向”，但它不是表级意向锁。

它是行级锁体系中的一种特殊 gap lock。

当事务 B 想插入 `id = 4`，但 `(3,5)` 间隙已经被事务 A 锁住时：

```text
事务 A: 持有 (3,5) gap lock
事务 B: 想插入 id=4，生成 insert intention lock，状态 WAITING
```

插入意向锁表示：

**我想往这个间隙里的某个点插入，但现在被 gap lock 挡住了。**

多个插入意向锁之间，如果插入位置不冲突，通常可以并发；但插入意向锁和已有 gap lock / next-key lock 会冲突。

## 锁全景排查：先判断是哪一层

线上遇到阻塞，不要一上来就说“行锁冲突”。可以先按层级排：

### 25. 是否全局锁？

现象：

- 整个实例大量写入阻塞。
- 可能有人执行了 FTWRL 或备份任务。

排查：

```sql
show processlist;
```

看是否有备份、FTWRL、长时间 Sleep 但持有锁的会话。

### 26. 是否 MDL？

现象：

```text
Waiting for table metadata lock
```

排查：

```sql
show processlist;

select *
from information_schema.innodb_trx\G

select *
from performance_schema.metadata_locks
where object_schema = 'your_db'
  and object_name = 'your_table'\G
```

重点找长事务和等待 DDL。

### 27. 是否表锁？

现象：

- 某些表被 `LOCK TABLES` 锁住。
- 当前会话报 `was not locked with LOCK TABLES`。
- 其他会话读写阻塞。

排查：

```sql
show open tables where in_use > 0;
show processlist;
```

### 28. 是否 AUTO-INC 锁？

现象：

- 大批量插入自增表时，同表插入互相等待。
- 并发 insert 性能异常。

排查：

```sql
show variables like 'innodb_autoinc_lock_mode';
show variables like 'binlog_format';
show processlist;
```

结合是否有 `insert ... select`、`load data`、批量 insert。

### 29. 是否行锁？

现象：

- 某条 `update/delete/select ... for update` 等待。
- 可能有死锁或锁等待超时。

排查：

```sql
select *
from performance_schema.data_locks\G

select *
from performance_schema.data_lock_waits\G

show engine innodb status\G
```

结合：

```sql
explain <你的 SQL>;
```

判断锁在哪个索引、哪个范围。

## 常见面试题答法

### 30. MySQL 有哪些锁？

可以这样答：

> 按范围分，MySQL 有全局锁、表级锁和行级锁。全局锁典型是 `flush tables with read lock`，主要用于全库逻辑备份，但会让整个实例只读。表级锁包括显式表锁、MDL、意向锁、AUTO-INC 锁；MDL 用于保护表结构元数据，意向锁用于协调表锁和行锁，AUTO-INC 锁用于自增值分配。行级锁主要是 InnoDB 的 Record Lock、Gap Lock、Next-Key Lock，以及插入意向锁。

### 31. 为什么 DDL 会阻塞普通查询？

可以这样答：

> DDL 要拿 MDL 写锁，普通 CRUD 会拿 MDL 读锁。读读兼容，读写互斥。如果有长事务持有 MDL 读锁，DDL 的 MDL 写锁会等待；一旦写锁进入等待队列，后续新的 CRUD 读锁也不能插队，所以后面的普通查询也会被阻塞。这就是线上 `Waiting for table metadata lock` 可能造成雪崩的原因。

### 32. 意向锁有什么用？

可以这样答：

> 意向锁是表级锁，用来表示表中某些行即将或已经被加 S/X 行锁。它不和普通行锁冲突，主要和表锁冲突。它的作用是让表锁快速判断表里有没有行锁，不需要遍历所有行。比如事务要加 X 行锁前，会先加 IX；另一个事务想加表写锁时，看到 IX 就知道不能直接加。

### 33. AUTO-INC 锁为什么和 binlog 有关系？

可以这样答：

> `innodb_autoinc_lock_mode=2` 时，自增值分配后很快释放锁，并发插入性能最好，但同一条批量 insert 语句拿到的自增值可能被其他会话插队，导致不连续。如果 `binlog_format=statement`，从库按语句顺序回放，不会复现主库并发交错的自增分配过程，可能主从不一致。因此 mode=2 通常要配合 row 格式 binlog，由 binlog 记录最终行数据和自增值。

## 小结

这一课重点建立锁的地图：

1. **全局锁 FTWRL**：让整个实例只读，常用于非事务表一致性备份，但影响极大。
2. **表锁 `LOCK TABLES`**：显式锁表，也限制当前会话访问范围，InnoDB 业务中应谨慎使用。
3. **MDL**：自动加，用来保护表结构；长事务 + DDL 等待可能阻塞后续所有 CRUD。
4. **意向锁 IS/IX**：表级锁，用来协调表锁和行锁，让表锁快速判断表内是否有行锁。
5. **AUTO-INC 锁**：保护自增值分配；`innodb_autoinc_lock_mode` 在连续性、并发性、复制一致性之间权衡。
6. **行级锁**：InnoDB 的核心并发能力，锁的是索引记录或索引范围。

真正排查问题时，先判断阻塞在哪个层级，再选工具：

| 层级 | 常用排查工具 |
| --- | --- |
| 全局锁 | `show processlist` |
| 表锁 | `show open tables`、`show processlist` |
| MDL | `metadata_locks`、`innodb_trx`、`show processlist` |
| AUTO-INC | 参数 + 插入 SQL 类型 + `show processlist` |
| 行锁 | `data_locks`、`data_lock_waits`、`show engine innodb status` |

一句话收尾：

**MySQL 锁问题不要只盯着行锁。全局锁、MDL、表锁和 AUTO-INC 锁同样可能是线上阻塞的真正源头。**

## 问题（用于检验有没有真的理解）

1. `flush tables with read lock` 会阻塞哪些操作？为什么它适合全库逻辑备份？
2. InnoDB 为什么可以用 `mysqldump --single-transaction` 做一致性备份？
3. `LOCK TABLES t read` 后，当前会话为什么不能写 `t`，也不能访问未锁住的其他表？
4. MDL 读锁和 MDL 写锁分别由哪些 SQL 自动申请？
5. 为什么一个等待中的 DDL 会让后续普通查询也被阻塞？
6. 意向锁 IS/IX 是表级锁还是行级锁？它解决了什么效率问题？
7. 意向锁和插入意向锁有什么区别？
8. `innodb_autoinc_lock_mode` 的 0、1、2 分别有什么差异？
9. 为什么 `innodb_autoinc_lock_mode=2` 搭配 `binlog_format=statement` 可能导致主从不一致？
10. 线上遇到“数据库卡住”，你会如何先判断是 MDL、表锁、AUTO-INC 还是行锁？
