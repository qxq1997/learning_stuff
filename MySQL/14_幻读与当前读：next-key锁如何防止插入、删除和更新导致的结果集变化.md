# MySQL - 第 14 课：幻读与当前读：next-key 锁如何防止插入、删除和更新导致的结果集变化

> 这一课回答一个很容易把人问懵的面试追问：在可重复读隔离级别下，记录锁 + 间隙锁能防止“删除操作导致的幻读”吗？答案是：对于当前读，可以。更准确地说，next-key lock 的记录锁部分能阻止已有结果行被删除或修改，间隙锁部分能阻止新结果行被插入；两者合起来，才能让同一条当前读谓词在事务期间维持稳定的结果集。

## 学习目标（本节结束后你能做到什么）

- 能说清“幻读”到底是结果集变化，而不只是“多插入了一行”。
- 能区分快照读防幻读和当前读防幻读的机制差异。
- 能解释为什么 `select ... for update` 后，其他事务删除命中记录会被阻塞。
- 能推导没有 `age` 索引时，`where age > 20 for update` 为什么会接近锁全表。
- 能推导有 `age` 索引时，二级索引和主键索引分别加什么锁。
- 能解释为什么 `update age = 20 where id = 1` 这种看起来不进入 `age > 20` 结果集的语句，也可能被锁住。
- 能用面试语言回答“记录锁 + 间隙锁能不能防删除导致的幻读”。

## 内容讲解（核心概念，用类比、例子、图示说清楚）

先把答案说清楚：

**如果事务 A 执行的是当前读，例如 `select ... for update`，InnoDB 会通过 next-key lock 保护谓词结果集。已有结果行被记录锁保护，所以其他事务不能删除或修改这些行；可能插入新结果行的位置被间隙锁保护，所以其他事务不能插入幻影记录。**

所以，不要把 next-key lock 只理解成“防插入”。它由两部分组成：

```text
Next-Key Lock = Gap Lock + Record Lock
```

- Gap Lock：防止别人插入新记录，避免结果集多出行。
- Record Lock：防止别人删除或修改已有记录，避免结果集少掉行或行从谓词范围内移出。

这正是“记录锁 + 间隙锁可以防止删除导致结果集变化”的根本原因。

### 1. 幻读到底是什么？

MySQL 文档对 phantom problem 的描述大意是：

> 在一个事务中，同一个查询在不同时间产生了不同的行集合，就出现了幻象问题。比如第一次 `select` 没有返回某行，第二次 `select` 返回了这行，这行就是 phantom row。

很多人只记住了“第二次多出一行”，于是把幻读狭义理解成：

```text
其他事务 insert 了一行，导致我第二次 select 多查到一行。
```

这个理解抓住了最典型场景，但不够稳。

从“同一谓词的结果集是否稳定”这个角度看，结果集变化可以有三类：

| 其他事务操作 | 结果集变化 | 例子 |
| --- | --- | --- |
| `insert` | 多出原来没有的行 | 原来 `age > 20` 有 6 行，后来有 7 行 |
| `delete` | 少掉原来有的行 | 原来 `age > 20` 有 6 行，后来有 5 行 |
| `update` | 行进入或离开谓词范围 | 把 `age = 19` 改成 `21`，或者把 `age = 21` 改成 `19` |

严格的教材和数据库实现里，幻读最常用来描述“范围查询多出新行”，删除已有行也常被一些语境归到“结果集不稳定”的幻象问题里。面试时遇到这个追问，最好的回答方式不是争定义，而是说清：

**无论叫幻读、谓词读不稳定，还是当前读结果集变化，InnoDB 的 next-key lock 都是通过“记录锁保护已有行 + 间隙锁保护插入位置”来避免它。**

### 2. MySQL 用两套机制处理幻读

InnoDB 在 RR（Repeatable Read，可重复读）隔离级别下，针对不同读类型，用的机制不一样。

| 读类型 | 典型语句 | 防幻读方式 |
| --- | --- | --- |
| 快照读 | 普通 `select` | MVCC / Read View |
| 当前读 | `select ... for update`、`select ... for share`、`update`、`delete` | next-key lock |

普通 `select` 是快照读：

```sql
select *
from t_user
where age > 20;
```

在 RR 下，同一事务里的普通快照读通常复用同一个 Read View。即使其他事务后来插入或删除了数据，本事务再次执行普通 `select` 时，仍然按照旧快照判断可见性，所以结果集保持稳定。

但当前读不一样：

```sql
select *
from t_user
where age > 20
for update;
```

当前读要读取最新版本，并且要准备修改或保护这些记录。如果不加锁，其他事务就可能在事务 A 两次当前读之间插入、删除或更新相关记录，导致结果集变化。

所以当前读靠 next-key lock。

一个关键区别：

- MVCC 的快照读是“我不阻止你改，但我看不见你的新改动”。
- 当前读加锁是“我直接阻止你改会影响我结果集的记录和间隙”。

### 3. 实验表：先只有主键索引

假设有一张用户表：

```sql
create table t_user (
  id bigint primary key,
  name varchar(64) not null,
  age int not null,
  reward bigint not null
) engine = InnoDB;
```

先注意：此时只有主键索引，没有 `age` 索引。

表中数据如下：

| id | name | age | reward |
| --- | --- | --- | --- |
| 1 | 路飞 | 19 | 3000000000 |
| 2 | 索隆 | 21 | 11100000000 |
| 3 | 山治 | 21 | 1000000000 |
| 4 | 乌索普 | 19 | 500000000 |
| 5 | 香克斯 | 39 | 4000000000 |
| 6 | 鹰眼 | 43 | 3500000000 |
| 7 | 罗 | 23 | 3000000000 |
| 8 | 基德 | 23 | 3000000000 |
| 9 | 乔巴 | 17 | 1000 |

事务 A 执行：

```sql
begin;

select *
from t_user
where age > 20
for update;
```

查询结果是 6 行：

| id | name | age |
| --- | --- | --- |
| 2 | 索隆 | 21 |
| 3 | 山治 | 21 |
| 5 | 香克斯 | 39 |
| 6 | 鹰眼 | 43 |
| 7 | 罗 | 23 |
| 8 | 基德 | 23 |

如果事务 B 此时执行：

```sql
begin;

delete from t_user
where id = 2;
```

它会被阻塞。

原因很直接：

**事务 A 的当前读已经锁住了结果集中的 `id = 2` 这条记录。事务 B 删除这条记录也需要对它加 X 锁，两个 X 锁冲突，所以 B 等待。**

如果 B 能删掉 `id = 2`，事务 A 再执行同一条当前读：

```sql
select *
from t_user
where age > 20
for update;
```

结果就会从 6 行变成 5 行。这就是同一谓词结果集不稳定。记录锁部分正是在阻止这件事。

### 4. 没有 `age` 索引时，为什么锁住了整张表？

事务 A 的 SQL 是：

```sql
select *
from t_user
where age > 20
for update;
```

但表里没有 `age` 索引。

执行计划大概率是：

```text
type: ALL
key: NULL
Extra: Using where
```

这表示全表扫描。

InnoDB 行锁是加在索引上的；没有 `age` 索引时，只能沿着主键索引 `PRIMARY` 扫描整张表，然后逐行判断 `age > 20` 是否成立。

在 RR 下，`select ... for update` 是当前读。为了避免当前读结果集被并发写破坏，InnoDB 会在扫描索引的过程中加锁。

主键索引顺序是：

```text
1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8 -> 9 -> supremum
```

事务 A 可能在主键索引上加这些 X 型 next-key lock：

| 索引 | 锁类型 | 范围 |
| --- | --- | --- |
| `PRIMARY` | X 型 next-key lock | `(-∞,1]` |
| `PRIMARY` | X 型 next-key lock | `(1,2]` |
| `PRIMARY` | X 型 next-key lock | `(2,3]` |
| `PRIMARY` | X 型 next-key lock | `(3,4]` |
| `PRIMARY` | X 型 next-key lock | `(4,5]` |
| `PRIMARY` | X 型 next-key lock | `(5,6]` |
| `PRIMARY` | X 型 next-key lock | `(6,7]` |
| `PRIMARY` | X 型 next-key lock | `(7,8]` |
| `PRIMARY` | X 型 next-key lock | `(8,9]` |
| `PRIMARY` | X 型 next-key lock | `(9,+∞]` |

同时还会有表级意向锁：

```text
LOCK_TYPE: TABLE
LOCK_MODE: IX
```

注意：

**锁是在扫描索引时加的，不是只对最终返回的 6 行加锁。**

因为没有 `age` 索引，InnoDB 不能直接定位 `age > 20` 的索引范围，只能扫主键索引。于是主键上几乎每个 next-key 区间都被锁住，效果接近锁全表。

这会导致：

- 删除 `id = 2` 被阻塞，因为 `id = 2` 的记录被锁住。
- 更新 `id = 1` 也可能被阻塞，即使它 `age = 19` 不在结果集里。
- 插入新主键记录也会被阻塞，因为主键间隙被锁住。

这就是线上最危险的一类锁问题：

**SQL 看起来只查 `age > 20`，但因为没走索引，锁范围扩大成整张表。**

### 5. `LOCK_TYPE = RECORD` 不等于记录锁

通过下面语句可以看锁：

```sql
select *
from performance_schema.data_locks\G
```

你可能会看到很多行：

```text
LOCK_TYPE: RECORD
LOCK_MODE: X
INDEX_NAME: PRIMARY
LOCK_DATA: 1
```

这里要再次强调：

**`LOCK_TYPE = RECORD` 表示这是行级锁，不代表它是 Record Lock。**

真正判断记录锁、间隙锁、next-key lock，要看 `LOCK_MODE`：

| `LOCK_MODE` | 含义 |
| --- | --- |
| `X` | X 型 next-key lock |
| `X,REC_NOT_GAP` | X 型记录锁 |
| `X,GAP` | X 型间隙锁 |
| `X,INSERT_INTENTION` | X 型插入意向锁 |

当 `LOCK_MODE = X` 且 `LOCK_DATA = 2` 时，如果当前锁在主键索引上，通常可以理解成：

```text
右边界是 2 的 next-key lock
范围是：(上一条主键值, 2]
```

例如主键顺序里 `2` 的上一条是 `1`，所以范围是 `(1,2]`。

### 6. 为什么 next-key lock 能防 delete？

这个问题可以拆成两半：

```text
next-key lock = gap lock + record lock
```

假设事务 A 对主键 `id = 2` 持有 `(1,2]` 的 X 型 next-key lock。

它包含：

- `(1,2)` 的 gap lock。
- `id = 2` 的 record lock。

事务 B 执行：

```sql
delete from t_user
where id = 2;
```

`delete` 本身也是当前读 + 写操作。它需要对 `id = 2` 加 X 型记录锁。

但事务 A 已经持有 `id = 2` 的 X 锁，X 锁与 X 锁不兼容，所以 B 被阻塞。

所以：

- 防插入，主要靠 gap lock。
- 防删除，主要靠 record lock。
- 防“同一谓词结果集变化”，靠 next-key lock 两部分一起工作。

### 7. 为什么 next-key lock 也能防 update？

`update` 可能造成两类结果集变化：

1. 把结果集里的行改出范围。
2. 把结果集外的行改进范围。

例如事务 A 锁住：

```sql
select *
from t_user
where age > 20
for update;
```

如果事务 B 执行：

```sql
update t_user
set age = 19
where id = 2;
```

它试图把 `id = 2` 从 `age > 20` 的结果集中移出去。这个操作需要更新 `id = 2` 的真实记录，因此会和事务 A 持有的记录锁冲突。

如果事务 C 执行：

```sql
update t_user
set age = 21
where id = 1;
```

它试图把 `id = 1` 从结果集外改进 `age > 20` 的范围。是否被阻塞，取决于执行计划和索引锁范围：

- 没有 `age` 索引时，全表扫描锁了主键各个 next-key 区间，`id = 1` 本身也被锁住，所以会被阻塞。
- 有 `age` 索引时，更新 `age` 会修改二级索引项；如果新二级索引位置落在事务 A 的 `age` 索引锁范围内，也会被阻塞。

所以，next-key lock 防的不只是 insert。

## 有 `age` 索引时，锁范围会小很多

现在给 `age` 建索引：

```sql
alter table t_user
add index index_age(age);
```

事务 A 再执行：

```sql
begin;

select *
from t_user
where age > 20
for update;
```

执行计划会变成范围扫描：

```text
type: range
key: index_age
Extra: Using index condition
```

这时 InnoDB 可以直接沿着 `index_age` 扫描 `age > 20` 的范围，不需要扫完整张主键索引。

### 8. 先画出 `age` 二级索引顺序

二级索引的排序不是只看 `age`，而是看：

```text
(age, id)
```

因为非唯一二级索引允许 `age` 相同，InnoDB 会用主键值作为二级索引叶子项的一部分来保证顺序唯一。

`index_age` 顺序是：

```text
(17,9)
-> (19,1)
-> (19,4)
-> (21,2)
-> (21,3)
-> (23,7)
-> (23,8)
-> (39,5)
-> (43,6)
-> supremum
```

查询条件是：

```sql
where age > 20
```

第一条满足条件的二级索引记录是：

```text
(21,2)
```

它的上一条二级索引记录是：

```text
(19,4)
```

所以第一个 next-key lock 的左边界会从 `(19,4)` 开始，而不是从数学意义上的 `20` 开始。

这就是很多人第一次看锁范围时觉得奇怪的地方：

**InnoDB 锁的是 B+ 树相邻索引记录之间的物理间隙，不是精确到谓词表达式里的每一个数值。**

### 9. `age` 二级索引上加了什么锁？

对 `age > 20` 的范围扫描，事务 A 会在 `index_age` 上对扫描到的二级索引项加 X 型 next-key lock。

按完整 `(age,id)` 表示，锁范围大致是：

| 索引 | 锁类型 | 精确区间 |
| --- | --- | --- |
| `index_age` | X 型 next-key lock | `((19,4),(21,2)]` |
| `index_age` | X 型 next-key lock | `((21,2),(21,3)]` |
| `index_age` | X 型 next-key lock | `((21,3),(23,7)]` |
| `index_age` | X 型 next-key lock | `((23,7),(23,8)]` |
| `index_age` | X 型 next-key lock | `((23,8),(39,5)]` |
| `index_age` | X 型 next-key lock | `((39,5),(43,6)]` |
| `index_age` | X 型 next-key lock | `((43,6),+∞]` |

如果只按 `age` 值简化，可以说：

```text
age 索引锁住了 (19,+∞]
```

但工程分析时要知道，这个简化会丢掉主键维度。真正判断某条插入是否被阻塞，仍然要回到 `(age,id)` 排序。

### 10. 主键索引上加了什么锁？

这条 SQL 是：

```sql
select *
from t_user
where age > 20
for update;
```

查询返回的是完整行。通过二级索引 `index_age` 找到匹配记录后，还要回表到聚簇索引读取完整行。

同时，为了防止这些已经命中的真实行被删除或修改，事务 A 会在主键索引上给匹配行加 X 型记录锁。

匹配行是：

| id | age |
| --- | --- |
| 2 | 21 |
| 3 | 21 |
| 7 | 23 |
| 8 | 23 |
| 5 | 39 |
| 6 | 43 |

主键索引上的锁：

| 索引 | 锁类型 | 范围 |
| --- | --- | --- |
| `PRIMARY` | X 型记录锁 | `id = 2` |
| `PRIMARY` | X 型记录锁 | `id = 3` |
| `PRIMARY` | X 型记录锁 | `id = 5` |
| `PRIMARY` | X 型记录锁 | `id = 6` |
| `PRIMARY` | X 型记录锁 | `id = 7` |
| `PRIMARY` | X 型记录锁 | `id = 8` |

所以有 `age` 索引时，事务 A 的锁可以概括成：

```text
index_age: 锁住 age > 20 相关的二级索引范围，粗略是 (19,+∞]
PRIMARY: 锁住结果集中 6 条真实记录的主键记录
```

这比没有 `age` 索引时“主键上几乎全表 next-key lock”要小很多。

### 11. 有 `age` 索引后，哪些操作会被阻塞？

事务 A 持有：

```sql
select *
from t_user
where age > 20
for update;
```

之后，下面这些操作都会被阻塞。

#### 删除结果集中的记录

```sql
delete from t_user
where id = 2;
```

`id = 2` 是结果集中的行。事务 A 在 `PRIMARY` 上持有 `id = 2` 的 X 型记录锁，所以删除被阻塞。

#### 删除或修改 `age = 23` 的记录

```sql
delete from t_user
where age = 23;
```

`age = 23` 对应 `id = 7` 和 `id = 8`，都属于结果集。这些行的主键记录被事务 A 锁住，二级索引项也在锁范围里，所以删除会被阻塞。

#### 插入新的 `age > 20` 记录

```sql
insert into t_user(id, name, age, reward)
values(10, '新用户', 100, 1000);
```

新二级索引项是：

```text
(100,10)
```

它要插入到 `(43,6)` 之后，落在事务 A 持有的 `((43,6),+∞]` 这段 next-key lock 保护范围里，因此插入意向锁会等待。

#### 把 `age = 19` 改成 `age = 20`

原文实验中有一个看起来很反直觉的阻塞：

```sql
update t_user
set age = 20
where id = 1;
```

`age = 20` 明明不满足 `age > 20`，为什么也可能被阻塞？

因为二级索引 `index_age` 中没有 `age = 20`，新索引项 `(20,1)` 要插入的位置在：

```text
(19,4) 和 (21,2) 之间
```

而事务 A 的第一段 next-key lock 正是：

```text
((19,4),(21,2)]
```

这段物理间隙覆盖了 `age = 20` 的插入位置。InnoDB 的锁粒度是相邻索引记录之间的间隙，不是谓词 `age > 20` 的数学精确边界，所以这个 update 会被挡住。

这不是逻辑上“必须阻塞 age = 20”，而是实现上“锁住 `(19,4)` 到 `(21,2)` 这段索引间隙时顺带阻塞了它”。

### 12. 有索引与无索引的锁范围对比

| 场景 | 执行计划 | 主要锁范围 | 后果 |
| --- | --- | --- | --- |
| 没有 `age` 索引 | `type=ALL`，全表扫描 | 主键索引上 `(-∞,+∞]` 被 next-key 覆盖 | 效果接近锁全表 |
| 有 `age` 索引 | `type=range`，走 `index_age` | `index_age` 上约 `(19,+∞]`，主键上锁 6 条结果行 | 锁范围明显缩小，但仍可能比谓词边界宽 |

这个对比是本课最有工程价值的地方：

**加锁 SQL 是否走索引，决定的不只是查询速度，还决定锁范围。**

慢一点还只是性能问题，锁范围过大则会变成并发问题。

## 回到面试题：删除会不会导致幻读？

面试官的问题通常是：

> 可重复读下，当前读用记录锁 + 间隙锁解决幻读。间隙锁防插入我理解，那如果其他事务执行删除，会不会导致幻读？记录锁 + 间隙锁能防住吗？

可以这样回答：

> 可以防住。幻读本质上是同一谓词前后两次查询返回的行集合发生变化。插入会让结果集多出行，删除会让结果集少掉行，更新可能让行进入或离开范围。InnoDB 对当前读使用 next-key lock，它是 gap lock + record lock 的组合。gap lock 防止其他事务往范围内插入新记录，record lock 防止已经扫描到的记录被删除或修改。所以如果事务 A 执行 `select ... where age > 20 for update`，事务 B 删除结果集里的某行时，需要拿这行的 X 记录锁，会和 A 已持有的 X 锁冲突，因此被阻塞。

再补一句工程意识：

> 不过具体锁范围取决于执行计划。如果 `age` 没有索引，这条当前读可能全表扫描，并在主键索引上对每个扫描到的记录加 next-key lock，效果接近锁全表；如果 `age` 有索引，锁范围会收敛到 `age` 二级索引范围，并对匹配行的主键加记录锁。因此线上执行 `select ... for update`、`update`、`delete` 前一定要看 `EXPLAIN`。

这样回答就把定义、机制和工程风险都覆盖了。

## 常见误区

### 误区一：幻读只可能由 insert 造成

insert 是最典型的 phantom row 来源，但从结果集稳定性看，delete/update 也可能让同一谓词结果集变化。

更稳的说法是：

**幻读讨论的是谓词范围内的行集合稳定性。**

### 误区二：间隙锁能防删除

间隙锁本身不锁真实记录，所以它不负责防删除。

防删除的是记录锁。

next-key lock 能防删除，是因为它包含 record lock。

### 误区三：`where age > 20` 只会锁 age 大于 20 的行

不一定。

如果没有 `age` 索引，它可能全表扫描，锁住主键索引上的大量记录和间隙。

如果有 `age` 索引，锁也不是数学意义上的 `(20,+∞)`，而是从第一条匹配记录的上一条索引记录开始，可能表现为 `(19,+∞]`。

### 误区四：`LOCK_TYPE = RECORD` 就是记录锁

不是。

`LOCK_TYPE = RECORD` 表示行级锁。要判断具体是不是记录锁，要看 `LOCK_MODE`：

- `X`：next-key lock。
- `X,GAP`：gap lock。
- `X,REC_NOT_GAP`：record lock。

### 误区五：有索引就不会阻塞不相关更新

也不一定。

例如 `age > 20 for update` 走 `index_age` 后，第一段锁可能是 `((19,4),(21,2)]`。这会阻塞插入或更新出一个 `(20,*)` 的二级索引项，即使 `age = 20` 不满足 `age > 20`。

原因还是那句话：

**InnoDB 锁的是索引记录之间的物理间隙。**

## 线上排查清单

遇到“为什么这条 delete/update 被 select for update 阻塞了”，可以按下面顺序查：

1. 看阻塞 SQL 是快照读还是当前读。
2. 看当前事务隔离级别：

```sql
select @@transaction_isolation;
```

3. 看执行计划：

```sql
explain select *
from t_user
where age > 20
for update;
```

4. 看当前锁：

```sql
select *
from performance_schema.data_locks\G
```

5. 看等待关系：

```sql
select *
from performance_schema.data_lock_waits\G
```

6. 重点确认：

| 信息 | 你要判断什么 |
| --- | --- |
| `EXPLAIN.type` | 是 `ALL` 全表扫描，还是 `range/ref` |
| `EXPLAIN.key` | 实际走了哪个索引 |
| `INDEX_NAME` | 锁在哪个索引上 |
| `LOCK_MODE` | next-key、gap、record、insert intention |
| `LOCK_DATA` | 锁的右边界或具体索引项 |
| 二级索引排序 | 是否需要按 `(二级索引值, 主键值)` 判断插入位置 |

排查时要把 SQL、执行计划、索引顺序、锁等待放在一起看。

## 小结

这一课可以收束成几句话：

1. 幻读本质是同一谓词的结果集在事务中发生变化，insert、delete、update 都可能导致结果集变化。
2. RR 下普通 `select` 是快照读，靠 MVCC 让事务看到稳定快照。
3. `select ... for update` 是当前读，靠 next-key lock 保护当前结果集。
4. next-key lock 的 gap lock 部分防插入，record lock 部分防删除和修改。
5. 没有合适索引时，当前读可能全表扫描，并对主键索引大量加 next-key lock，效果接近锁全表。
6. 有二级索引时，要同时分析二级索引范围锁和主键记录锁；二级索引要按 `(二级索引值, 主键值)` 排序。

最后落到工程上就是一句话：

**所有带锁的 SQL，都要先确认执行计划。索引不仅影响性能，也影响锁范围。**

## 问题（用于检验有没有真的理解）

1. 为什么说幻读关注的是“谓词结果集变化”，而不只是 insert？
2. RR 下普通 `select` 和 `select ... for update` 分别靠什么避免结果集变化？
3. next-key lock 中哪一部分防插入？哪一部分防删除？
4. 没有 `age` 索引时，`where age > 20 for update` 为什么会锁住主键索引上的几乎所有 next-key 区间？
5. 有 `age` 索引时，为什么主键索引还要对 `id = 2/3/5/6/7/8` 加记录锁？
6. 为什么 `age > 20` 的第一个二级索引 next-key lock 可能从 `(19,4)` 开始，而不是从 `20` 开始？
7. 为什么 `update t_user set age = 20 where id = 1` 也可能被 `age > 20 for update` 阻塞？
8. `LOCK_TYPE = RECORD` 和 Record Lock 是一回事吗？应该看哪个字段判断？
9. 如果你在线上看到 `delete where id = 2` 被阻塞，你会用哪些命令还原阻塞链路？
10. 为什么说“索引不仅影响查询性能，也影响锁范围”？
