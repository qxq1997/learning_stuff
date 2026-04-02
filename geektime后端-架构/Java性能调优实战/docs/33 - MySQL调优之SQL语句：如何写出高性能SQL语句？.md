你好，我是刘超。

从今天开始，我将带你一起学习MySQL的性能调优。MySQL数据库是互联网公司使用最为频繁的数据库之一，不仅仅因为它开源免费，MySQL卓越的性能、稳定的服务以及活跃的社区都成就了它的核心竞争力。

我们知道，应用服务与数据库的交互主要是通过SQL语句来实现的。在开发初期，我们更加关注的是使用SQL实现业务功能，然而系统上线后，随着生产环境数据的快速增长，之前写的很多SQL语句就开始暴露出性能问题。

在这个阶段中，我们应该尽量避免一些慢SQL语句的实现。但话说回来，SQL语句慢的原因千千万，除了一些常规的慢SQL语句可以直接规避，其它的一味去规避也不是办法，我们还要学会如何去分析、定位到其根本原因，并总结一些常用的SQL调优方法，以备不时之需。

那么今天我们就重点看看慢SQL语句的几种常见诱因，从这点出发，找到最佳方法，开启高性能SQL语句的大门。

## 慢SQL语句的几种常见诱因

### 1. 无索引、索引失效导致慢查询

如果在一张几千万数据的表中以一个没有索引的列作为查询条件，大部分情况下查询会非常耗时，这种查询毫无疑问是一个慢SQL查询。所以对于大数据量的查询，我们需要建立适合的索引来优化查询。

虽然我们很多时候建立了索引，但在一些特定的场景下，索引还有可能会失效，所以索引失效也是导致慢查询的主要原因之一。针对这点的调优，我会在第34讲中详解。

### 2. 锁等待

我们常用的存储引擎有 InnoDB 和 MyISAM，前者支持行锁和表锁，后者只支持表锁。

如果数据库操作是基于表锁实现的，试想下，如果一张订单表在更新时，需要锁住整张表，那么其它大量数据库操作（包括查询）都将处于等待状态，这将严重影响到系统的并发性能。

这时，InnoDB 存储引擎支持的行锁更适合高并发场景。但在使用 InnoDB 存储引擎时，我们要特别注意行锁升级为表锁的可能。在批量更新操作时，行锁就很可能会升级为表锁。

MySQL认为如果对一张表使用大量行锁，会导致事务执行效率下降，从而可能造成其它事务长时间锁等待和更多的锁冲突问题发生，致使性能严重下降，所以MySQL会将行锁升级为表锁。还有，行锁是基于索引加的锁，如果我们在更新操作时，条件索引失效，那么行锁也会升级为表锁。

因此，基于表锁的数据库操作，会导致SQL阻塞等待，从而影响执行速度。在一些更新操作（insert\\update\\delete）大于或等于读操作的情况下，MySQL不建议使用MyISAM存储引擎。

除了锁升级之外，行锁相对表锁来说，虽然粒度更细，并发能力提升了，但也带来了新的问题，那就是死锁。因此，在使用行锁时，我们要注意避免死锁。关于死锁，我还会在第35讲中详解。

### 3. 不恰当的SQL语句

使用不恰当的SQL语句也是慢SQL最常见的诱因之一。例如，习惯使用&lt;SELECT \*&gt;，&lt;SELECT COUNT(\*)&gt; SQL语句，在大数据表中使用&lt;LIMIT M,N&gt;分页查询，以及对非索引字段进行排序等等。

## 优化SQL语句的步骤

通常，我们在执行一条SQL语句时，要想知道这个SQL先后查询了哪些表，是否使用了索引，这些数据从哪里获取到，获取到数据遍历了多少行数据等等，我们可以通过EXPLAIN命令来查看这些执行信息。这些执行信息被统称为执行计划。

### 1. 通过EXPLAIN分析SQL执行计划

假设现在我们使用EXPLAIN命令查看当前SQL是否使用了索引，先通过SQL EXPLAIN导出相应的执行计划如下：

![](https://static001.geekbang.org/resource/image/bd/f8/bd11fa15122956719289afea2464eff8.jpg?wh=1974%2A308)

下面对图示中的每一个字段进行一个说明，从中你也能收获到很多零散的知识点。

- id：每个执行计划都有一个id，如果是一个联合查询，这里还将有多个id。
- select\_type：表示SELECT查询类型，常见的有SIMPLE（普通查询，即没有联合查询、子查询）、PRIMARY（主查询）、UNION（UNION中后面的查询）、SUBQUERY（子查询）等。
- table：当前执行计划查询的表，如果给表起别名了，则显示别名信息。
- partitions：访问的分区表信息。
- type：表示从表中查询到行所执行的方式，查询方式是SQL优化中一个很重要的指标，结果值从好到差依次是：system &gt; const &gt; eq\_ref &gt; ref &gt; range &gt; index &gt; ALL。

<!--THE END-->

![](https://static001.geekbang.org/resource/image/8f/0b/8fc6cb3338945524fb09a092f396fa0b.jpg?wh=2240%2A318)

- system/const：表中只有一行数据匹配，此时根据索引查询一次就能找到对应的数据。

<!--THE END-->

![](https://static001.geekbang.org/resource/image/b5/2b/b5ea0778ff22bdde10a57edfc353712b.jpg?wh=2230%2A352)

- eq\_ref：使用唯一索引扫描，常见于多表连接中使用主键和唯一索引作为关联条件。

<!--THE END-->

![](https://static001.geekbang.org/resource/image/d3/50/d390d8c7bb90bdbf26775265ad451c50.jpg?wh=2232%2A320)

- ref：非唯一索引扫描，还可见于唯一索引最左原则匹配扫描。

<!--THE END-->

![](https://static001.geekbang.org/resource/image/40/a4/4020416795c991f68fb057b3e6b80ca4.jpg?wh=2230%2A316)

- range：索引范围扫描，比如，&lt;，&gt;，between等操作。

<!--THE END-->

![](https://static001.geekbang.org/resource/image/7f/c7/7f7a40f88150117f6fe0bb56f52da6c7.jpg?wh=2224%2A322)

- index：索引全表扫描，此时遍历整个索引树。

<!--THE END-->

![](https://static001.geekbang.org/resource/image/d3/7b/d3d7221fec38845145ac0f365196427b.jpg?wh=2228%2A326)

- ALL：表示全表扫描，需要遍历全表来找到对应的行。
- possible\_keys：可能使用到的索引。
- key：实际使用到的索引。
- key\_len：当前使用的索引的长度。
- ref：关联id等信息。
- rows：查找到记录所扫描的行数。
- filtered：查找到所需记录占总扫描记录数的比例。
- Extra：额外的信息。

### 2. 通过Show Profile分析SQL执行性能

上述通过 EXPLAIN 分析执行计划，仅仅是停留在分析SQL的外部的执行情况，如果我们想要深入到MySQL内核中，从执行线程的状态和时间来分析的话，这个时候我们就可以选择Profile。

Profile除了可以分析执行线程的状态和时间，还支持进一步选择ALL、CPU、MEMORY、BLOCK IO、CONTEXT SWITCHES等类型来查询SQL语句在不同系统资源上所消耗的时间。以下是相关命令的注释：

```
SHOW PROFILE [type [, type] ... ]
[FOR QUERY n]
[LIMIT row_count [OFFSET offset]]

type参数：
| ALL：显示所有开销信息
| BLOCK IO：阻塞的输入输出次数
| CONTEXT SWITCHES：上下文切换相关开销信息
| CPU：显示CPU的相关开销信息 
| IPC：接收和发送消息的相关开销信息
| MEMORY ：显示内存相关的开销，目前无用
| PAGE FAULTS ：显示页面错误相关开销信息
| SOURCE ：列出相应操作对应的函数名及其在源码中的调用位置(行数) 
| SWAPS：显示swap交换次数的相关开销信息
```

值得注意的是，MySQL是在5.0.37版本之后才支持Show Profile功能的，如果你不太确定的话，可以通过select @@have\_profiling查询是否支持该功能，如下图所示：

![](https://static001.geekbang.org/resource/image/76/45/76a42789a838dfd6b1735c41dd9f8c45.jpg?wh=2032%2A306)

最新的MySQL版本是默认开启Show Profile功能的，但在之前的旧版本中是默认关闭该功能的，你可以通过set语句在Session级别开启该功能：

![](https://static001.geekbang.org/resource/image/84/91/840fbe1ecdf7526fdc818f4639e22091.jpg?wh=2100%2A318)

Show Profiles只显示最近发给服务器的SQL语句，默认情况下是记录最近已执行的15条记录，我们可以重新设置profiling\_history\_size增大该存储记录，最大值为100。

![](https://static001.geekbang.org/resource/image/54/4f/5488fde01df647508d60b9a77cd1f14f.jpg?wh=1382%2A1000)

获取到Query\_ID之后，我们再通过Show Profile for Query ID语句，就能够查看到对应Query\_ID的SQL语句在执行过程中线程的每个状态所消耗的时间了：

![](https://static001.geekbang.org/resource/image/dc/23/dc7e4046ddd22438c21690e5bc38c123.jpg?wh=1576%2A1082)

通过以上分析可知：SELECT COUNT(\*) FROM \`order\`; SQL语句在Sending data状态所消耗的时间最长，这是因为在该状态下，MySQL线程开始读取数据并返回到客户端，此时有大量磁盘I/O操作。

## 常用的SQL优化

在使用一些常规的SQL时，如果我们通过一些方法和技巧来优化这些SQL的实现，在性能上就会比使用常规通用的实现方式更加优越，甚至可以将SQL语句的性能提升到另一个数量级。

### 1. 优化分页查询

通常我们是使用&lt;LIMIT M,N&gt; +合适的order by来实现分页查询，这种实现方式在没有任何索引条件支持的情况下，需要做大量的文件排序操作（file sort），性能将会非常得糟糕。如果有对应的索引，通常刚开始的分页查询效率会比较理想，但越往后，分页查询的性能就越差。

这是因为我们在使用LIMIT的时候，偏移量M在分页越靠后的时候，值就越大，数据库检索的数据也就越多。例如 LIMIT 10000,10这样的查询，数据库需要查询10010条记录，最后返回10条记录。也就是说将会有10000条记录被查询出来没有被使用到。

我们模拟一张10万数量级的order表，进行以下分页查询：

```
select * from `demo`.`order` order by order_no limit 10000, 20;
```

通过EXPLAIN分析可知：该查询使用到了索引，扫描行数为10020行，但所用查询时间为0.018s，相对来说时间偏长了。

![](https://static001.geekbang.org/resource/image/80/fe/80efe0ba8feb86baa20834fd48c302fe.jpg?wh=2018%2A318)

![](https://static001.geekbang.org/resource/image/58/1c/58e2377b2adcded4c454d410bbab7d1c.jpg?wh=2078%2A332)

- 利用子查询优化分页查询

以上分页查询的问题在于，我们查询获取的10020行数据结果都返回给我们了，我们能否先查询出所需要的20行数据中的最小ID值，然后通过偏移量返回所需要的20行数据给我们呢？我们可以通过索引覆盖扫描，使用子查询的方式来实现分页查询：

```
select * from `demo`.`order` where id> (select id from `demo`.`order` order by order_no limit 10000, 1)  limit 20;
```

通过EXPLAIN分析可知：子查询遍历索引的范围跟上一个查询差不多，而主查询扫描了更多的行数，但执行时间却减少了，只有0.004s。这就是因为返回行数只有20行了，执行效率得到了明显的提升。

![](https://static001.geekbang.org/resource/image/10/2e/10e46817482166d205f319cd0512942e.jpg?wh=2034%2A318)

![](https://static001.geekbang.org/resource/image/49/bb/492ddbbe2ef47d63a6dc797fd44c16bb.jpg?wh=2070%2A308)

### 2. 优化SELECT COUNT(\*)

COUNT()是一个聚合函数，主要用来统计行数，有时候也用来统计某一列的行数量（不统计NULL值的行）。我们平时最常用的就是COUNT(\*)和COUNT(1)这两种方式了，其实两者没有明显的区别，在拥有主键的情况下，它们都是利用主键列实现了行数的统计。

但COUNT()函数在MyISAM和InnoDB存储引擎所执行的原理是不一样的，通常在没有任何查询条件下的COUNT(\*)，MyISAM的查询速度要明显快于InnoDB。

这是因为MyISAM存储引擎记录的是整个表的行数，在COUNT(\*)查询操作时无需遍历表计算，直接获取该值即可。而在InnoDB存储引擎中就需要扫描表来统计具体的行数。而当带上where条件语句之后，MyISAM跟InnoDB就没有区别了，它们都需要扫描表来进行行数的统计。

如果对一张大表经常做SELECT COUNT(\*)操作，这肯定是不明智的。那么我们该如何对大表的COUNT()进行优化呢？

- 使用近似值

有时候某些业务场景并不需要返回一个精确的COUNT值，此时我们可以使用近似值来代替。我们可以使用EXPLAIN对表进行估算，要知道，执行EXPLAIN并不会真正去执行查询，而是返回一个估算的近似值。

- 增加汇总统计

如果需要一个精确的COUNT值，我们可以额外新增一个汇总统计表或者缓存字段来统计需要的COUNT值，这种方式在新增和删除时有一定的成本，但却可以大大提升COUNT()的性能。

### 3. 优化SELECT *

我曾经看过很多同事习惯在只查询一两个字段时，都使用select * from table where xxx这样的SQL语句，这种写法在特定的环境下会存在一定的性能损耗。

MySQL常用的存储引擎有MyISAM和InnoDB，其中InnoDB在默认创建主键时会创建主键索引，而主键索引属于聚簇索引，即在存储数据时，索引是基于B +树构成的，具体的行数据则存储在叶子节点。

而MyISAM默认创建的主键索引、二级索引以及InnoDB的二级索引都属于非聚簇索引，即在存储数据时，索引是基于B +树构成的，而叶子节点存储的是主键值。

假设我们的订单表是基于InnoDB存储引擎创建的，且存在order\_no、status两列组成的组合索引。此时，我们需要根据订单号查询一张订单表的status，如果我们使用select * from order where order\_no='xxx’来查询，则先会查询组合索引，通过组合索引获取到主键ID，再通过主键ID去主键索引中获取对应行所有列的值。

如果我们使用select order\_no, status from order where order\_no='xxx’来查询，则只会查询组合索引，通过组合索引获取到对应的order\_no和status的值。如果你对这些索引还不够熟悉，请重点关注之后的第34讲，那一讲会详述数据库索引的相关内容。

## 总结

在开发中，我们要尽量写出高性能的SQL语句，但也无法避免一些慢SQL语句的出现，或因为疏漏，或因为实际生产环境与开发环境有所区别，这些都是诱因。面对这种情况，我们可以打开慢SQL配置项，记录下都有哪些SQL超过了预期的最大执行时间。首先，我们可以通过以下命令行查询是否开启了记录慢SQL的功能，以及最大的执行时间是多少：

```
Show variables like 'slow_query%';
Show variables like 'long_query_time';
```

如果没有开启，我们可以通过以下设置来开启：

```
set global slow_query_log='ON'; //开启慢SQL日志
set global slow_query_log_file='/var/lib/mysql/test-slow.log';//记录日志地址
set global long_query_time=1;//最大执行时间
```

除此之外，很多数据库连接池中间件也有分析慢SQL的功能。总之，我们要在编程中避免低性能的SQL操作出现，除了要具备一些常用的SQL优化技巧之外，还要充分利用一些SQL工具，实现SQL性能分析与监控。

## 思考题

假设有一张订单表order，主要包含了主键订单编码order\_no、订单状态status、提交时间create\_time等列，并且创建了status列索引和create\_time列索引。此时通过创建时间降序获取状态为1的订单编码，以下是具体实现代码：

```
select order_no from order where status =1 order by create_time desc
```

你知道其中的问题所在吗？我们又该如何优化？

期待在留言区看到你的答案。也欢迎你点击“请朋友读”，把今天的内容分享给身边的朋友，邀请他一起讨论。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>张学磊</span> 👍（98） 💬（13）<p>status和create_time单独建索引，在查询时只会遍历status索引对数据进行过滤，不会用到create_time列索引，将符合条件的数据返回到server层，在server对数据通过快排算法进行排序，Extra列会出现file sort；应该利用索引的有序性，在status和create_time列建立联合索引，这样根据status过滤后的数据就是按照create_time排好序的，避免在server层排序</p>2019-08-06</li><br/><li><span>QQ怪</span> 👍（17） 💬（2）<p>对staus和create_time建立联合索引</p>2019-08-06</li><br/><li><span>Jian</span> 👍（16） 💬（4）<p>因为好久没有做SQL相关的开发了，所以开始没有特别明白【利用子查询优化分页查询】这里面的意思。我来说下自己的想法，请您检证。我看到您贴的截图中，优化后的sql语句，扫描的行数（rows列）分别是90409和10001，多余前一个较慢的查询，可见扫描行数，不是这个性能的主要原因。我推测这个是由于limit [m],n的实现方法导致的，即MySql会把m+n的数据都取出来，然后返回n个数据给用户。如果用第二种SQL语句，子查询只是获得一个id，虽然扫描了很多行，但都是在索引上进行的，切不需要回表获取内容。外查询是根据id获取数据20条内容，速度自然就会快了。我认为这里性能提高的原因还是居于索引的恰当使用。</p>2019-08-12</li><br/><li><span>尔东橙</span> 👍（13） 💬（1）<p>老师，分页查询优化那一块，单从扫描函数看，采用子查询和不采用子查询扫描总行数是差不多的，而不采用子查询，第一个主查询就是返回10020条记录，采用子查询只返回20条记录？我理解是结果集有多少行就是返回多少记录。是因为子查询不返回记录么，它不也扫描了10000行么？</p>2020-02-26</li><br/><li><span>钱</span> 👍（8） 💬（4）<p>课后思考及问题
1：按照效率排序的话，count(字段)&lt;count(主键 id)&lt;count(1)≈count(*)，所以我建议你，尽量使用 count(*)。——MySQL，丁奇老师的结论
如果对一张大表经常做 SELECT COUNT(*) 操作，这肯定是不明智的。——刘老师的结论
同样的问题，不同的老师给出了截然相反的结论，我希望有一天两位老师可以讨论一下为什么?
刘老师具体没讲COUNT(*)的原理，我倾向于认为丁奇老师的结论是正确的。</p>2019-09-14</li><br/><li><span>迎风劲草</span> 👍（5） 💬（3）<p>创建 status create_time order_no 联合索引，避免回表</p>2019-08-06</li><br/><li><span>mumu</span> 👍（4） 💬（2）<p>
select * from `demo`.`order` where id&gt; (select id from `demo`.`order` order by order_no limit 10000, 1)  limit 20;，老师您好，我不懂这样写为什么是正确的，为什么id&gt;子查询结果的20条就是按order_no排序所需的20条？</p>2019-11-04</li><br/><li><span>张三丰</span> 👍（4） 💬（2）<p>就算使用了联合索引，也避免不了排序吧，因为题目要求的是降序，联合索引是保证第一个索引有序的前提下再保证第二个索引有序，那么这个有序是升序，如果没记错的话。</p>2019-10-04</li><br/><li><span>Geek_002ff7</span> 👍（4） 💬（1）<p>真实情况一般不会在status上单独建索引，因为status大部分都是重复值，数据库一般走全表扫描了，感觉漏讲了索引失效的情况</p>2019-08-09</li><br/><li><span>尔东橙</span> 👍（3） 💬（1）<p>为什么分页查询优化那块，主查询扫描这么多行？</p>2019-09-26</li><br/><li><span>IT橘子</span> 👍（2） 💬（1）<p>老师，常用的SQL优化-1.优化分页查询中利用子查询优化分页查询成立的条件是不是order_no建立了唯一索引，即order_no与id（主键）一一对应，并且在order_no的索引上，id是严格单调递增的？</p>2020-03-08</li><br/><li><span>风轻扬</span> 👍（2） 💬（2）<p>select * from `demo`.`order` where id&gt; (select id from `demo`.`order` order by order_no limit 10000, 1)  limit 20;
老师，这个优化后的查询，您是先查询出来的第10001条数据的id，然后 id 大于此值。获取20条数据。这样获取的值不对啊，我试了。这样获取的是10002到10021的数据了，不是10001到10020的数据。子查询获取的值减一就对了</p>2019-09-20</li><br/><li><span>张德</span> 👍（1） 💬（1）<p>没看别人评论  我来说一下  直接查状态为1的订单  索引的区分度太低</p>2019-08-28</li><br/><li><span>拒绝</span> 👍（1） 💬（1）<p>感觉要建立联合索引，但不知具体原因</p>2019-08-09</li><br/><li><span>LW</span> 👍（1） 💬（2）<p>order_no创建主键，status+create_time创建联合索引</p>2019-08-06</li><br/>
</ul>