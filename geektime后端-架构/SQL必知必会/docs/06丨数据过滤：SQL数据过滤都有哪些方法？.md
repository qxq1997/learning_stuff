我在上篇文章中讲到过，提升查询效率的一个很重要的方式，就是约束返回结果的数量，还有一个很有效的方式，就是指定筛选条件，进行过滤。过滤可以筛选符合条件的结果，并进行返回，减少不必要的数据行。

那么在今天的内容里，我们来学习如何对SQL数据进行过滤，这里主要使用的就是WHERE子句。

你可能已经使用过WHERE子句，说起来SQL其实很简单，只要能把满足条件的内容筛选出来即可，但在实际使用过程中，不同人写出来的WHERE子句存在很大差别，比如执行效率的高低，有没有遇到莫名的报错等。

在今天的学习中，你重点需要掌握以下几方面的内容：

1. 学会使用WHERE子句，如何使用比较运算符对字段的数值进行比较筛选；
2. 如何使用逻辑运算符，进行多条件的过滤；
3. 学会使用通配符对数据条件进行复杂过滤。

## 比较运算符

在SQL中，我们可以使用WHERE子句对条件进行筛选，在此之前，你需要了解WHERE子句中的比较运算符。这些比较运算符的含义你可以参见下面这张表格：

![](https://static001.geekbang.org/resource/image/3a/e0/3a2667784b4887ef15becc7056f3d3e0.png?wh=799%2A545)

实际上你能看到，同样的含义可能会有多种表达方式，比如小于等于，可以是（&lt;=），也可以是不大于（!&gt;）。同样不等于，可以用（&lt;&gt;），也可以用（!=），它们的含义都是相同的，但这些符号的顺序都不能颠倒，比如你不能写（=&lt;）。需要注意的是，你需要查看使用的DBMS是否支持，不同的DBMS支持的运算符可能是不同的，比如Access不支持（!=），不等于应该使用（&lt;&gt;）。在MySQL中，不支持（!&gt;）（!&lt;）等。

我在上一篇文章中使用了heros数据表，今天还是以这张表格做练习。下面我们通过比较运算符对王者荣耀的英雄属性进行条件筛选。

WHERE子句的基本格式是：`SELECT ……(列名) FROM ……(表名) WHERE ……(子句条件)`

比如我们想要查询所有最大生命值大于6000的英雄：

```
SQL：SELECT name, hp_max FROM heros WHERE hp_max > 6000
```

运行结果（41条记录）：

![](https://static001.geekbang.org/resource/image/9f/c1/9f639dfe0bd9dbfc63944447f92e47c1.png?wh=790%2A323)

想要查询所有最大生命值在5399到6811之间的英雄：

```
SQL：SELECT name, hp_max FROM heros WHERE hp_max BETWEEN 5399 AND 6811
```

运行结果：（41条记录）

![](https://static001.geekbang.org/resource/image/4b/60/4b11a5f32f3f2807c8278f8d5637d460.png?wh=798%2A324)

需要注意的是`hp_max`可以取值到最小值和最大值，即5399和6811。

我们也可以对heros表中的`hp_max`字段进行空值检查。

```
SQL：SELECT name, hp_max FROM heros WHERE hp_max IS NULL
```

运行结果为空，说明heros表中的`hp_max`字段没有存在空值的数据行。

## 逻辑运算符

我刚才介绍了比较运算符，如果我们存在多个WHERE条件子句，可以使用逻辑运算符：

![](https://static001.geekbang.org/resource/image/ae/c1/aeed170c57ae1e5378fbee9f8fb6a8c1.png?wh=796%2A272)

我们还是通过例子来看下这些逻辑运算符的使用，同样采用heros这张表的数据查询。

假设想要筛选最大生命值大于6000，最大法力大于1700的英雄，然后按照最大生命值和最大法力值之和从高到低进行排序。

```
SQL：SELECT name, hp_max, mp_max FROM heros WHERE hp_max > 6000 AND mp_max > 1700 ORDER BY (hp_max+mp_max) DESC
```

运行结果：（23条记录）

![](https://static001.geekbang.org/resource/image/85/4e/859e7e9fcf28a30f9189ef81cfe7284e.png?wh=821%2A323)

如果AND和OR同时存在WHERE子句中会是怎样的呢？假设我们想要查询最大生命值加最大法力值大于8000的英雄，或者最大生命值大于6000并且最大法力值大于1700的英雄。

```
SQL：SELECT name, hp_max, mp_max FROM heros WHERE (hp_max+mp_max) > 8000 OR hp_max > 6000 AND mp_max > 1700 ORDER BY (hp_max+mp_max) DESC
```

运行结果：（33条记录）

![](https://static001.geekbang.org/resource/image/05/ae/052c1fb7031d025d5e0c0027177187ae.png?wh=823%2A322)

你能看出来相比于上一个条件查询，这次的条件查询多出来了10个英雄，这是因为我们放宽了条件，允许最大生命值+最大法力值大于8000的英雄显示出来。另外你需要注意到，当WHERE子句中同时存在OR和AND的时候，AND执行的优先级会更高，也就是说SQL会优先处理AND操作符，然后再处理OR操作符。

如果我们对这条查询语句OR两边的条件增加一个括号，结果会是怎样的呢？

```
SQL：SELECT name, hp_max, mp_max FROM heros WHERE ((hp_max+mp_max) > 8000 OR hp_max > 6000) AND mp_max > 1700 ORDER BY (hp_max+mp_max) DESC
```

运行结果：

![](https://static001.geekbang.org/resource/image/1a/c9/1a41124faad3aac6e8170a72e65de5c9.png?wh=820%2A325)

所以当WHERE子句中同时出现AND和OR操作符的时候，你需要考虑到执行的先后顺序，也就是两个操作符执行的优先级。一般来说()优先级最高，其次优先级是AND，然后是OR。

如果我想要查询主要定位或者次要定位是法师或是射手的英雄，同时英雄的上线时间不在2016-01-01到2017-01-01之间。

```
SQL：
SELECT name, role_main, role_assist, hp_max, mp_max, birthdate
FROM heros 
WHERE (role_main IN ('法师', '射手') OR role_assist IN ('法师', '射手')) 
AND DATE(birthdate) NOT BETWEEN '2016-01-01' AND '2017-01-01'
ORDER BY (hp_max + mp_max) DESC
```

你能看到我把WHERE子句分成了两个部分。第一部分是关于主要定位和次要定位的条件过滤，使用的是`role_main in ('法师', '射手') OR role_assist in ('法师', '射手')`。这里用到了IN逻辑运算符，同时`role_main`和`role_assist`是OR（或）的关系。

第二部分是关于上线时间的条件过滤。NOT代表否，因为我们要找到不在2016-01-01到2017-01-01之间的日期，因此用到了`NOT BETWEEN '2016-01-01' AND '2017-01-01'`。同时我们是在对日期类型数据进行检索，所以使用到了DATE函数，将字段birthdate转化为日期类型再进行比较。关于日期的操作，我会在下一篇文章中再作具体介绍。

这是运行结果（6条记录）：

![](https://static001.geekbang.org/resource/image/70/8e/7048f6ff11215b6d0113b2370103828e.png?wh=981%2A369)

## 使用通配符进行过滤

刚才讲解的条件过滤都是对已知值进行的过滤，还有一种情况是我们要检索文本中包含某个词的所有数据，这里就需要使用通配符。通配符就是我们用来匹配值的一部分的特殊字符。这里我们需要使用到LIKE操作符。

如果我们想要匹配任意字符串出现的任意次数，需要使用（%）通配符。比如我们想要查找英雄名中包含“太”字的英雄都有哪些：

```
SQL：SELECT name FROM heros WHERE name LIKE '%太%'
```

运行结果：（2条记录）

![](https://static001.geekbang.org/resource/image/b1/18/b18de17c2517d7c06c56f324309c4c18.png?wh=199%2A183)  
需要说明的是不同DBMS对通配符的定义不同，在Access中使用的是（\*）而不是（%）。另外关于字符串的搜索可能是需要区分大小写的，比如`'liu%'`就不能匹配上`'LIU BEI'`。具体是否区分大小写还需要考虑不同的DBMS以及它们的配置。

如果我们想要匹配单个字符，就需要使用下划线(*)通配符。（%）和（*）的区别在于，（%）代表零个或多个字符，而（\_）只代表一个字符。比如我们想要查找英雄名除了第一个字以外，包含‘太’字的英雄有哪些。

```
SQL：SELECT name FROM heros WHERE name LIKE '_%太%'
```

运行结果（1条记录）：

![](https://static001.geekbang.org/resource/image/ab/65/ab30c809327a81ee00ce4989e7815065.png?wh=197%2A123)

因为太乙真人的太是第一个字符，而`_%太%`中的太不是在第一个字符，所以匹配不到“太乙真人”，只可以匹配上“东皇太一”。

同样需要说明的是，在Access中使用（?）来代替（`_`），而且在DB2中是不支持通配符（`_`）的，因此你需要在使用的时候查阅相关的DBMS文档。

你能看出来通配符还是很有用的，尤其是在进行字符串匹配的时候。不过在实际操作过程中，我还是建议你尽量少用通配符，因为它需要消耗数据库更长的时间来进行匹配。即使你对LIKE检索的字段进行了索引，索引的价值也可能会失效。如果要让索引生效，那么LIKE后面就不能以（%）开头，比如使用`LIKE '%太%'`或`LIKE '%太'`的时候就会对全表进行扫描。如果使用`LIKE '太%'`，同时检索的字段进行了索引的时候，则不会进行全表扫描。

## 总结

今天我对SQL语句中的WHERE子句进行了讲解，你可以使用比较运算符、逻辑运算符和通配符这三种方式对检索条件进行过滤。

比较运算符是对数值进行比较，不同的DBMS支持的比较运算符可能不同，你需要事先查阅相应的DBMS文档。逻辑运算符可以让我们同时使用多个WHERE子句，你需要注意的是AND和OR运算符的执行顺序。通配符可以让我们对文本类型的字段进行模糊查询，不过检索的代价也是很高的，通常都需要用到全表扫描，所以效率很低。只有当LIKE语句后面不用通配符，并且对字段进行索引的时候才不会对全表进行扫描。

你可能认为学习SQL并不难，掌握这些语法就可以对数据进行筛选查询。但实际工作中不同人写的SQL语句的查询效率差别很大，保持高效率的一个很重要的原因，就是要避免全表扫描，所以我们会考虑在WHERE及ORDER BY涉及到的列上增加索引。

![](https://static001.geekbang.org/resource/image/fb/50/fbd79c2c90a58891b498e7f29d935050.jpg?wh=3341%2A1713)

你能说一下WHERE子句中比较运算符、逻辑运算符和通配符这三者各自的作用吗？以heros数据表为例，请你编写SQL语句，对英雄名称、主要定位、次要定位、最大生命和最大法力进行查询，筛选条件为：主要定位是坦克或者战士，并且次要定位不为空，同时满足最大生命值大于8000或者最大法力小于1500的英雄，并且按照最大生命和最大法力之和从高到底的顺序进行排序。

欢迎你在评论区写下你的思考，也欢迎点击请朋友读，把这篇文章分享给你的朋友或者同事。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>奕</span> 👍（106） 💬（5）<p>就是要避免全表扫描，所以我们会考虑在 WHERE 及 ORDER BY 涉及到的列上增加索引
-----------------------------------------------
where 条件字段上加索引是可以明白的，但是为什么 order by 字段上还要加索引呢？这个时候已经通过 where条件过滤得到了数据，已经不需要在筛选过滤数据了，只需要在排序的时候根据字段排序就好了。不是很明白</p>2019-06-24</li><br/><li><span>极客星星</span> 👍（57） 💬（1）<p>你好  老师 不是很明白您说的对where语句建索引是什么意思 通过sql语句怎么实现
谢谢</p>2019-06-25</li><br/><li><span>Abyssknight</span> 👍（35） 💬（6）<p>关于通配符匹配里的 % 相当于正则表达式里的 .* 表示匹配大于等于0个任意字符，
所以  % 太 % 匹配的是 [大于等于0个任意字符]太[大于等于0个任意字符]，[东皇]太[一] 和 []太[乙真人]都符合；
而 _% 相当于正则表达式里的 .+ 表示匹配至少一个，即大于等于1个，
所以  &#39;_% 太 % 匹配的是 [大于等于1个字符]太[大于等于0个字符]，只有 [东皇]太[一] 符合。</p>2019-06-24</li><br/><li><span>陈扬鸿</span> 👍（33） 💬（1）<p>老师，你好，现在mysql8已经没有frm文件，一旦数据字典丢失，没有表结构就无法恢复单个ibd文件的数据，如何通过mysql8的 sdi文件生成创建表的ddl语句。</p>2019-06-25</li><br/><li><span>怪兽宇</span> 👍（32） 💬（7）<p>老师好, 平日因业务考核需要，一条查询语句查询条件需要写 30 多个 like &quot;%A%&quot;  ，语句跑起来特别慢，请问有什么优化方法吗？</p>2019-06-26</li><br/><li><span>Goal</span> 👍（26） 💬（3）<p>老师关于通配符给的解释，不够清晰！
说明如下：
SQL：SELECT name FROM heros WHERE name LIKE &#39;_% 太 %&#39;

因为太乙真人的太是第一个字符，而_%太%中的太不是在第一个字符，所以匹配不到“太乙真人”，只可以匹配上“东皇太一”。

说明：
&quot;_&quot;：匹配任意一个字符，包括可以匹配到“太乙真人”的太字。 
但是，整体的通配符  &#39;_% 太 %&#39;，需要后面继续匹配到一个&quot;太&quot;字符，显然，&quot;太乙真人&quot;不符合了，如果是，&quot;太乙真人太太&quot;，就可以匹配到。</p>2019-06-24</li><br/><li><span>stormsc</span> 👍（23） 💬（2）<p>有个问题想问老师：
SELECT name,role_main,role_assist from heros where role_assist is not null LIMIT 5 
这样限定的查询结果为5条数据，是随机选择的5条数据吗？</p>2019-06-25</li><br/><li><span>看，有只猪</span> 👍（20） 💬（3）<p>解答一下对使用DATE函数的疑问：
birthdate字段可能会有时间包含在里面，如2019-01-01 00:00:00，如果直接和2019-01-01比较是会失败的，用DATE函数可以提取出原始数据的日期部分</p>2019-06-25</li><br/><li><span>stormsc</span> 👍（11） 💬（4）<p>作业 mysql: select name 英雄名称, role_main 主要定位, role_assist 次要定位,hp_max 最大生命值,mp_max 最大法力值 from heros where (role_main in (&#39;坦克&#39;,&#39;战士&#39;) 
AND role_assist is not null) AND (hp_max &gt; 8000 or mp_max &lt;1500) ORDER BY (hp_max+mp_max) DESC</p>2019-06-25</li><br/><li><span>hlz-123</span> 👍（9） 💬（1）<p>where子句WHERE 子句中比较运算符、逻辑运算符和通配符这三者各自作用？
1、比较运算符，比较数值的大小，数值类型可以是整数，浮点数，字符串，布尔类型等等。
2、逻辑运算符，定义where子句中多个条件之间的关系。
3、通配符，对文本类型字段进行模糊查询。
Mysql查询语句：
SELECT name,role_main,role_assist,hp_max,mp_max FROM heros 
WHERE (role_main in (&#39;坦克&#39;,&#39;战士&#39;) AND role_assist is not null) 
AND (hp_max&gt;8000 OR mp_max&lt;1500) order by (hp_max+mp_max) DESC;</p>2019-06-24</li><br/><li><span>华夏</span> 👍（5） 💬（3）<p>SELECT name, role_main, role_assist, hp_max, mp_max 
FROM heros 
WHERE (role_main IN (&#39;坦克&#39;, &#39;战士&#39;) AND role_assist IS NOT NULL) 
AND (hp_max &gt; 8000 OR mp_max &lt; 1500) 
ORDER BY (hp_max+mp_max) DESC;
+-----------+-----------+-------------+--------+--------+
| name      | role_main | role_assist | hp_max | mp_max |
+-----------+-----------+-------------+--------+--------+
| 牛魔      | 坦克      | 辅助        |   8476 |   1926 |
| 刘邦      | 坦克      | 辅助        |   8073 |   1940 |
| 程咬金    | 坦克      | 战士        |   8611 |      0 |
| 张飞      | 坦克      | 辅助        |   8341 |    100 |
| 亚瑟      | 战士      | 坦克        |   8050 |      0 |
| 吕布      | 战士      | 坦克        |   7344 |      0 |
| 关羽      | 战士      | 坦克        |   7107 |     10 |
| 花木兰    | 战士      | 刺客        |   5397 |    100 |
+-----------+-----------+-------------+--------+--------+
8 rows in set (0.00 sec)
</p>2019-06-30</li><br/><li><span>晓涛</span> 👍（4） 💬（2）<p>sql建立索引是什么意思，老师能详细解释下不？
</p>2019-08-16</li><br/><li><span>不负</span> 👍（4） 💬（1）<p>过滤上线时间 DATE(birthdate) NOT BETWEEN &#39;2016-01-01&#39; AND &#39;2017-01-01&#39;，是MySQL里date类型可以直接与字符串进行比较运算？那这里birthdate可以不用 DATE 函数转换了；Oracle中日期的比较就比较严格，TO_DATE、TO_CHAR 效率也不同</p>2019-06-27</li><br/><li><span>꯭J꯭I꯭N꯭🙃</span> 👍（3） 💬（1）<p>SELECT name, role_main, role_assist,hp_max,mp_max
FROM heros
WHERE (role_main IN (&#39;坦克&#39;,&#39;战士&#39;) AND role_assist IS NOT NULL) 
AND (hp_max &gt; 8000 or mp_max &lt; 1500)
ORDER BY (hp_max+mp_max) DESC;</p>2019-06-25</li><br/><li><span>ballgod</span> 👍（2） 💬（1）<p>关于通配符的问题想问一下老师，有看过python的正则表达式，评论第三位的解释中，+是一个或无穷个，*是零个或无穷个。按照老师说的%和_的含义，_%太%应该是匹配 </p>2019-07-13</li><br/>
</ul>