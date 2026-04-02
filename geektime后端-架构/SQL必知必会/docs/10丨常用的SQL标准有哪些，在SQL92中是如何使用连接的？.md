今天我主要讲解连接表的操作。在讲解之前，我想先给你介绍下连接（JOIN）在SQL中的重要性。

我们知道SQL的英文全称叫做Structured Query Language，它有一个很强大的功能，就是能在各个数据表之间进行连接查询（Query）。这是因为SQL是建立在关系型数据库基础上的一种语言。关系型数据库的典型数据结构就是数据表，这些数据表的组成都是结构化的（Structured）。你可以把关系模型理解成一个二维表格模型，这个二维表格是由行（row）和列（column）组成的。每一个行（row）就是一条数据，每一列（column）就是数据在某一维度的属性。

正是因为在数据库中，表的组成是基于关系模型的，所以一个表就是一个关系。一个数据库中可以包括多个表，也就是存在多种数据之间的关系。而我们之所以能使用SQL语言对各个数据表进行复杂查询，核心就在于连接，它可以用一条SELECT语句在多张表之间进行查询。你也可以理解为，关系型数据库的核心之一就是连接。

既然连接在SQL中这么重要，那么针对今天的内容，需要你从以下几个方面进行掌握：

1. SQL实际上存在不同的标准，不同标准下的连接定义也有不同。你首先需要了解常用的SQL标准有哪些；
2. 了解了SQL的标准之后，我们从SQL92标准入门，来看下连接表的种类有哪些；
3. 针对一个实际的数据库表，如果你想要做数据统计，需要学会使用跨表的连接进行操作。

## 常用的SQL标准有哪些

在正式开始讲连接表的种类时，我们首先需要知道SQL存在不同版本的标准规范，因为不同规范下的表连接操作是有区别的。

SQL有两个主要的标准，分别是SQL92和SQL99。92和99代表了标准提出的时间，SQL92就是92年提出的标准规范。当然除了SQL92和SQL99以外，还存在SQL-86、SQL-89、SQL:2003、SQL:2008、SQL:2011和SQL:2016等其他的标准。

这么多标准，到底该学习哪个呢？实际上最重要的SQL标准就是SQL92和SQL99。一般来说SQL92的形式更简单，但是写的SQL语句会比较长，可读性较差。而SQL99相比于SQL92来说，语法更加复杂，但可读性更强。我们从这两个标准发布的页数也能看出，SQL92的标准有500页，而SQL99标准超过了1000页。实际上你不用担心要学习这么多内容，基本上从SQL99之后，很少有人能掌握所有内容，因为确实太多了。就好比我们使用Windows、Linux和Office的时候，很少有人能掌握全部内容一样。我们只需要掌握一些核心的功能，满足日常工作的需求即可。

## 在SQL92中是如何使用连接的

相比于SQL99，SQL92规则更简单，更适合入门。在这篇文章中，我会先讲SQL92是如何对连接表进行操作的，下一篇文章再讲SQL99，到时候你可以对比下这两者之间有什么区别。

在进行连接之前，我们需要用数据表做举例。这里我创建了NBA球员和球队两张表，SQL文件你可以从[GitHub](https://github.com/cystanford/sql_nba_data)上下载。

其中player表为球员表，一共有37个球员，如下所示：

![](https://static001.geekbang.org/resource/image/e3/1b/e327a3eeeb7a7195a7ae0703ebd8e51b.png?wh=879%2A387)  
team表为球队表，一共有3支球队，如下所示：

![](https://static001.geekbang.org/resource/image/b5/39/b5228a60a4ccffa5b2848fe82d575239.png?wh=820%2A225)  
有了这两个数据表之后，我们再来看下SQL92中的5种连接方式，它们分别是笛卡尔积、等值连接、非等值连接、外连接（左连接、右连接）和自连接。

### 笛卡尔积

笛卡尔乘积是一个数学运算。假设我有两个集合X和Y，那么X和Y的笛卡尔积就是X和Y的所有可能组合，也就是第一个对象来自于X，第二个对象来自于Y的所有可能。

我们假定player表的数据是集合X，先进行SQL查询：

```
SELECT * FROM player
```

再假定team表的数据为集合Y，同样需要进行SQL查询：

```
SELECT * FROM team
```

你会看到运行结果会显示出上面的两张表格。

接着我们再来看下两张表的笛卡尔积的结果，这是笛卡尔积的调用方式：

```
SQL: SELECT * FROM player, team
```

运行结果（一共37\*3=111条记录）：

![](https://static001.geekbang.org/resource/image/2e/37/2e66048cba86811a740a85f68d81c537.png?wh=874%2A264)  
笛卡尔积也称为交叉连接，英文是CROSS JOIN，它的作用就是可以把任意表进行连接，即使这两张表不相关。但我们通常进行连接还是需要筛选的，因此你需要在连接后面加上WHERE子句，也就是作为过滤条件对连接数据进行筛选。比如后面要讲到的等值连接。

### 等值连接

两张表的等值连接就是用两张表中都存在的列进行连接。我们也可以对多张表进行等值连接。

针对player表和team表都存在team\_id这一列，我们可以用等值连接进行查询。

```
SQL: SELECT player_id, player.team_id, player_name, height, team_name FROM player, team WHERE player.team_id = team.team_id
```

运行结果（一共37条记录）：

![](https://static001.geekbang.org/resource/image/28/d9/282aa15e7d02c60e9ebba8a0cc9134d9.png?wh=1104%2A400)  
我们在进行等值连接的时候，可以使用表的别名，这样会让SQL语句更简洁：

```
SELECT player_id, a.team_id, player_name, height, team_name FROM player AS a, team AS b WHERE a.team_id = b.team_id
```

需要注意的是，如果我们使用了表的别名，在查询字段中就只能使用别名进行代替，不能使用原有的表名，比如下面的SQL查询就会报错：

```
SELECT player_id, player.team_id, player_name, height, team_name FROM player AS a, team AS b WHERE a.team_id = b.team_id
```

### 非等值连接

当我们进行多表查询的时候，如果连接多个表的条件是等号时，就是等值连接，其他的运算符连接就是非等值查询。

这里我创建一个身高级别表height\_grades，如下所示：

![](https://static001.geekbang.org/resource/image/cf/68/cf5ea984ba0c4501c5a4e1eec19e5b68.png?wh=849%2A278)  
我们知道player表中有身高height字段，如果想要知道每个球员的身高的级别，可以采用非等值连接查询。

```
SQL：SELECT p.player_name, p.height, h.height_level
FROM player AS p, height_grades AS h
WHERE p.height BETWEEN h.height_lowest AND h.height_highest
```

运行结果（37条记录）：

![](https://static001.geekbang.org/resource/image/fa/84/fa049e7e186978e7086eb8e157fdc284.png?wh=876%2A342)

### 外连接

除了查询满足条件的记录以外，外连接还可以查询某一方不满足条件的记录。两张表的外连接，会有一张是主表，另一张是从表。如果是多张表的外连接，那么第一张表是主表，即显示全部的行，而第剩下的表则显示对应连接的信息。在SQL92中采用（+）代表从表所在的位置，而且在SQL92中，只有左外连接和右外连接，没有全外连接。

什么是左外连接，什么是右外连接呢？

左外连接，就是指左边的表是主表，需要显示左边表的全部行，而右侧的表是从表，（+）表示哪个是从表。

```
SQL：SELECT * FROM player, team where player.team_id = team.team_id(+)
```

相当于SQL99中的：

```
SQL：SELECT * FROM player LEFT JOIN team on player.team_id = team.team_id
```

右外连接，指的就是右边的表是主表，需要显示右边表的全部行，而左侧的表是从表。

```
SQL：SELECT * FROM player, team where player.team_id(+) = team.team_id
```

相当于SQL99中的：

```
SQL：SELECT * FROM player RIGHT JOIN team on player.team_id = team.team_id
```

需要注意的是，LEFT JOIN和RIGHT JOIN只存在于SQL99及以后的标准中，在SQL92中不存在，只能用（+）表示。

### 自连接

自连接可以对多个表进行操作，也可以对同一个表进行操作。也就是说查询条件使用了当前表的字段。

比如我们想要查看比布雷克·格里芬高的球员都有谁，以及他们的对应身高：

```
SQL：SELECT b.player_name, b.height FROM player as a , player as b WHERE a.player_name = '布雷克-格里芬' and a.height < b.height
```

运行结果（6条记录）：

![](https://static001.geekbang.org/resource/image/05/94/05e4bf92df00e243601ca2d763fabb94.png?wh=820%2A385)  
如果不用自连接的话，需要采用两次SQL查询。首先需要查询布雷克·格里芬的身高。

```
SQL：SELECT height FROM player WHERE player_name = '布雷克-格里芬'
```

运行结果为2.08。

然后再查询比2.08高的球员都有谁，以及他们的对应身高：

```
SQL：SELECT player_name, height FROM player WHERE height > 2.08
```

运行结果和采用自连接的运行结果是一致的。

## 总结

今天我讲解了常用的SQL标准以及SQL92中的连接操作。SQL92和SQL99是经典的SQL标准，也分别叫做SQL-2和SQL-3标准。也正是在这两个标准发布之后，SQL影响力越来越大，甚至超越了数据库领域。现如今SQL已经不仅仅是数据库领域的主流语言，还是信息领域中信息处理的主流语言。在图形检索、图像检索以及语音检索中都能看到SQL语言的使用。

除此以外，我们使用的主流RDBMS，比如MySQL、Oracle、SQL Sever、DB2、PostgreSQL等都支持SQL语言，也就是说它们的使用符合大部分SQL标准，但很难完全符合，因为这些数据库管理系统都在SQL语言的基础上，根据自身产品的特点进行了扩充。即使这样，SQL语言也是目前所有语言中半衰期最长的，在1992年，Windows3.1发布，SQL92标准也同时发布，如今我们早已不使用Windows3.1操作系统，而SQL92标准却一直持续至今。

当然我们也要注意到SQL标准的变化，以及不同数据库管理系统使用时的差别，比如Oracle对SQL92支持较好，而MySQL则不支持SQL92的外连接。

![](https://static001.geekbang.org/resource/image/e4/0d/e473b216f11cfa7696371bfeadba220d.jpg?wh=3341%2A1410)  
我今天讲解了SQL的连接操作，你能说说内连接、外连接和自连接指的是什么吗？另外，你不妨拿案例中的team表做一道动手题，表格中一共有3支球队，现在这3支球队需要进行比赛，请用一条SQL语句显示出所有可能的比赛组合。

欢迎你在评论区写下你的答案，也欢迎把这篇文章分享给你的朋友或者同事，与他们一起交流一下。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>mickey</span> 👍（102） 💬（12）<p>&#47;*
team 表做一道动手题，表格中一共有 3 支球队，现在这 3 支球队需要进行比赛，请用一条 SQL 语句显示出所有可能的比赛组合。
*&#47;
#分主客队
SELECT CONCAT(kedui.team_name, &#39; VS &#39;, zhudui.team_name) as &#39;客队 VS 主队&#39; FROM team as zhudui LEFT JOIN team as kedui on zhudui.team_id&lt;&gt;kedui.team_id;

客队 VS 主队
------------------------------------
底特律活塞 VS 印第安纳步行者
底特律活塞 VS 亚特兰大老鹰
印第安纳步行者 VS 底特律活塞
印第安纳步行者 VS 亚特兰大老鹰
亚特兰大老鹰 VS 底特律活塞
亚特兰大老鹰 VS 印第安纳步行者

#不分主客队
SELECT a.team_name as &#39;队伍1&#39; ,&#39;VS&#39; , b.team_name as &#39;队伍2&#39; FROM team as a ,team as b where a.team_id&lt;b.team_id;

队伍1    VS    队伍2
------------------------------------
底特律活塞	VS	印第安纳步行者
底特律活塞	VS	亚特兰大老鹰
印第安纳步行者	VS	亚特兰大老鹰</p>2019-07-03</li><br/><li><span>奕</span> 👍（26） 💬（2）<p>有两个问题：
1: 在进行连接查询的时候，查询的顺序是什么呢？ 是先进行笛卡尔积在进行条件条件筛选吗？
2: 在进行连接查询的时候 on 中的条件和 where 中的条件有什么区别呢？ 这两个的筛选顺序一样吗？</p>2019-07-05</li><br/><li><span>长安落雪</span> 👍（22） 💬（1）<p>SELECT t1.team_name,t2.team_name FROM team as t1 LEFT  JOIN team as t2 ON t1.team_id  != t2.team_id

SELECT t1.team_name , t2.team_name  FROM team as t1 ,team as t2 where t1.team_id&lt;t2.team_id;</p>2019-07-04</li><br/><li><span>圆子蛋</span> 👍（5） 💬（3）<p>三队对阵的可能组合：
SELECT * FROM team AS a,team AS b WHERE a.team_id &lt; b.team_id
主客场对阵的可能（只列出名字的话是不是可以这样？）
SELECT a.team_name as 主场,b.team_name as 客场 FROM team AS a,team AS b WHERE a.team_id != b.team_id</p>2019-07-03</li><br/><li><span>Samson</span> 👍（4） 💬（3）<p>SQL：SELECT p.player_name, p.height, h.height_level
FROM player AS p, height_grades AS h
WHERE p.height BETWEEN h.height_lowest AND h.height_highest
 

老师，我还是不能够理解这条语句中WHERE之后的部分，可以麻烦详加解释一番吗？

另外，对于外连接的两个例子，可以把已经结果也贴一下吗？感觉这样子下效果会更好</p>2019-07-05</li><br/><li><span>野马</span> 👍（4） 💬（1）<p>那一个RDBMS支持多个SQL标准吗？</p>2019-07-04</li><br/><li><span>技术修行者</span> 👍（3） 💬（1）<p>目前主流的DNMS应该都是按照SQL99的规定来设计连接操作的，在实际工作中，极少看到SAL语句中带+的情况。我的建议是在介绍了基本概念后，可以直接使用SAL99，这样更有利于实战。</p>2019-10-02</li><br/><li><span>太精</span> 👍（3） 💬（1）<p>select * from team as a, team as b where a.team_id != b.team_id;
+---------+-----------------------+---------+-----------------------+
| team_id | team_name             | team_id | team_name             |
+---------+-----------------------+---------+-----------------------+
|    1002 | 印第安纳步行者        |    1001 | 底特律活塞            |
|    1003 | 亚特兰大老鹰          |    1001 | 底特律活塞            |
|    1001 | 底特律活塞            |    1002 | 印第安纳步行者        |
|    1003 | 亚特兰大老鹰          |    1002 | 印第安纳步行者        |
|    1001 | 底特律活塞            |    1003 | 亚特兰大老鹰          |
|    1002 | 印第安纳步行者        |    1003 | 亚特兰大老鹰          |
+---------+-----------------------+---------+-----------------------+
</p>2019-07-04</li><br/><li><span>xy</span> 👍（2） 💬（2）<p>表怎么下载下来的？</p>2019-07-15</li><br/><li><span>Goal</span> 👍（2） 💬（1）<p>老师好，
1. 文中“等值连接” 的结果图配错了，此处应该是只有：底特律活塞、印第安纳步行者的37名成员的表；
2. 思考题，主客场共计6场比赛
SELECT a.team_name,b.team_name  from team a,team b WHERE a.team_id != b.team_id
SELECT a.team_name,b.team_name FROM team a JOIN team b WHERE a.team_name &lt;&gt; b.team_name</p>2019-07-03</li><br/><li><span>墨禾</span> 👍（1） 💬（1）<p>&#47;*等值连接:两张表存在相同的列属性*&#47;
SELECT player_id, player.team_id, player_name, height, team_name FROM player, team WHERE player.team_id = team.team_id;

&#47;*非等值连接*&#47;
SELECT p.player_name, p.height...

极客时间版权所有: https:&#47;&#47;time.geekbang.org&#47;column&#47;article&#47;104637


&#47;*外连接：包括左连接、右连接、全连接*&#47;
-- 左外连接：左边的表为主表
 select count(*) from team t left outer join player p  on t.team_id = p.team_id;
 &#47;*
1001	底特律活塞	10001	1001	韦恩-艾灵顿	1.93
1001	底特律活塞	10002	1001	雷吉-杰克逊	1.91
1002	印第安纳步行者	10037	1002	Ike Anigbogu	2.08
1003	亚特兰大老鹰				
*&#47;
-- 右外连接：右边的表为主表
select count(*) from team t RIGHT outer join player p  on t.team_id = p.team_id;
&#47;*
1001	底特律活塞	10001	1001	韦恩-艾灵顿	1.93
1001	底特律活塞	10002	1001	雷吉-杰克逊	1.91
1002	印第安纳步行者	10037	1002	Ike Anigbogu	2.08
1003	亚特兰大老鹰				
*&#47;

-- 全连接：两张表做笛卡尔积
select count(*) from team t  outer join player p  on t.team_id = p.team_id;
&#47;*
1001	底特律活塞	10001	1001	韦恩-艾灵顿	1.93
1001	底特律活塞	10002	1001	雷吉-杰克逊	1.91
1002	印第安纳步行者	10037	1002	Ike Anigbogu	2.08
1003	亚特兰大老鹰				
*&#47;


select count(*) from team t  inner join player p  on t.team_id = p.team_id;


-- 自连接：可对单表或多表进行操作
SELECT b.player_name, b.height FROM player as a , player as b WHERE a.player_name = &#39;布雷克 - 格里芬&#39; and a.height &lt; b.height

&#47;*请用一条 SQL 语句显示出所有可能的比赛组合*&#47;
SELECT * FROM team t1 , team t2 WHERE t1.team_id&lt;&gt; t2.team_id
-- 或
SELECT * FROM team t1 , team t2 WHERE t1.team_id !=t2.team_id</p>2019-07-03</li><br/><li><span>高泽林</span> 👍（0） 💬（1）<p>要实际验证一下！</p>2019-12-17</li><br/><li><span>taoist</span> 👍（0） 💬（1）<p>-- MariaDB

-- 主客
SELECT CONCAT( t1.team_name ,&#39;(主)－－－－（客）&#39;, t2.team_name) FROM team t1, team t2
WHERE t1.team_id != t2.team_id;


-- 不分主客
SELECT CONCAT( t1.team_name ,&#39;－－－－&#39;, t2.team_name) FROM team t1, team t2
WHERE t1.team_id &lt; t2.team_id;</p>2019-12-16</li><br/><li><span>程序员花卷</span> 👍（0） 💬（1）<p>外连接不仅可以返回符合条件的行，还可以返回一些不符合条件的行
内连接只能返回符合条件的行，不能返回不符合条件的行
自连接自己连接自己，查询的时候用到了自己的字段，也可以多表进行连接

学习这一节我觉得重点在于理解连接是如何进行的，区分清楚各个连接查询的主表和从表
想要很深刻的理解，还是需要多做题目

练习题
SQL语句
SELECT a.`team_name` AS 主队,b.team_name AS 客队
FROM team AS a,team AS b
WHERE a.`team_id` &lt; b.`team_id`;

</p>2019-12-06</li><br/><li><span>爬行的蜗牛</span> 👍（0） 💬（1）<p>SELECT * FROM team as a, team as b WHERE a.team_name != b.team_name;</p>2019-11-23</li><br/>
</ul>