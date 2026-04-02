SQL可以帮我们进行数据处理，总的来说可以分成OLTP和OLAP两种方式。

OLTP称之为联机事务处理，我们之前讲解的对数据进行增删改查，SQL查询优化，事务处理等就属于OLTP的范畴。它对实时性要求高，需要将用户的数据有效地存储到数据库中，同时有时候针对互联网应用的需求，我们还需要设置数据库的主从架构保证数据库的高并发和高可用性。

OLAP称之为联机分析处理，它是对已经存储在数据库中的数据进行分析，帮我们得出报表，指导业务。它对数据的实时性要求不高，但数据量往往很大，存储在数据库（数据仓库）中的数据可能还存在数据质量的问题，比如数据重复、数据中有缺失值，或者单位不统一等，因此在进行数据分析之前，首要任务就是对收集的数据进行清洗，从而保证数据质量。

对于数据分析工作来说，好的数据质量才是至关重要的，它决定了后期数据分析和挖掘的结果上限。数据挖掘模型选择得再好，也只能最大化地将数据特征挖掘出来。

高质量的数据清洗，才有高质量的数据。今天我们就来看下，如何用SQL对数据进行清洗。

1. 想要进行数据清洗有怎样的准则呢？
2. 如何使用SQL对数据进行清洗？
3. 如何对清洗之后的数据进行可视化？

## 数据清洗的准则

我在《数据分析实战45讲》里专门讲到过数据清洗的原则，这里为了方便你理解，我用一个数据集实例讲一遍。

一般而言，数据集或多或少地会存在数据质量问题。这里我们使用泰坦尼克号乘客生存预测数据集，你可以从[GitHub](https://www.kaggle.com/c/titanic/data)上下载这个数据集。

数据集格式为csv，一共有两种文件：train.csv是训练数据集，包含特征信息和存活与否的标签；test.csv是测试数据集，只包含特征信息。

数据集中包括了以下字段，具体的含义如下：

![](https://static001.geekbang.org/resource/image/e7/e0/e717facd7cd53e7e2cfb714937347fe0.png?wh=646%2A530)  
训练集给出了891名乘客幸存与否的结果，以及相关的乘客信息。通过训练集，我们可以对数据进行建模形成一个分类器，从而对测试集中的乘客生存情况进行预测。不过今天我们并不讲解数据分析的模型，而是来看下在数据分析之前，如何对数据进行清洗。

首先，我们可以通过Navicat将CSV文件导入到MySQL数据库中，然后浏览下数据集中的前几行，可以发现数据中存在缺失值的情况还是很明显的。

![](https://static001.geekbang.org/resource/image/54/77/54b1d91f186945bcbb7f3a5df3575e77.png?wh=1729%2A438)  
数据存在数据缺失值是非常常见的情况，此外我们还需要考虑数据集中某个字段是否存在单位标识不统一，数值是否合法，以及数据是否唯一等情况。要考虑的情况非常多，这里我将数据清洗中需要考虑的规则总结为4个关键点，统一起来称之为“完全合一”准则，你可以[点这里](https://time.geekbang.org/column/article/76307)看一下。

“完全合一”是个通用的准则，针对具体的数据集存在的问题，我们还需要对症下药，采取适合的解决办法，甚至为了后续分析方便，有时我们还需要将字符类型的字段替换成数值类型，比如我们想做一个Steam游戏用户的数据分析，统计数据存储在两张表上，一个是user\_game数据表，记录了用户购买的各种Steam游戏，其中数据表中的game\_title字段表示玩家购买的游戏名称，它们都采用英文字符的方式。另一个是game数据表，记录了游戏的id、游戏名称等。因为这两张表存在关联关系，实际上在user\_game数据表中的game\_title对应了game数据表中的name，这里我们就可以用game数据表中的id替换掉原有的game\_title。替换之后，我们在进行数据清洗和质量评估的时候也会更清晰，比如如果还存在某个game\_title没有被替换的情况，就证明这款游戏在game数据表中缺少记录。

## 使用SQL对预测数据集进行清洗

了解了数据清洗的原则之后，下面我们就用SQL对泰坦尼克号数据集中的训练集进行数据清洗，也就是train.csv文件。我们先将这个文件导入到titanic\_train数据表中：

![](https://static001.geekbang.org/resource/image/5d/b5/5ddd7c23f942cc2f90ed9621cb751eb5.png?wh=1397%2A134)

### 检查完整性

在完整性这里，我们需要重点检查字段数值是否存在空值，在此之前，我们需要先统计每个字段空值的个数。在SQL中，我们可以分别统计每个字段的空值个数，比如针对Age字段进行空值个数的统计，使用下面的命令即可：

```
SELECT COUNT(*) as num FROM titanic_train WHERE Age IS NULL
```

运行结果为177。

当然我们也可以同时对多个字段的非空值进行统计：

```
SELECT 
SUM((CASE WHEN Age IS NULL THEN 1 ELSE 0 END)) AS age_null_num, 
SUM((CASE WHEN Cabin IS NULL THEN 1 ELSE 0 END)) AS cabin_null_num
FROM titanic_train
```

运行结果：

![](https://static001.geekbang.org/resource/image/42/bb/42d6d85c533707c29bda5a7cf95ad6bb.png?wh=698%2A105)  
不过这种方式适用于字段个数较少的情况，如果一个数据表存在几十个，甚至更多的字段，那么采用这种方式既麻烦又容易出错。这时我们可以采用存储过程的方式，用程序来进行字段的空值检查，代码如下：

```
CREATE PROCEDURE `check_column_null_num`(IN schema_name VARCHAR(100), IN table_name2 VARCHAR(100))
BEGIN
-- 数据表schema_name中的列名称
DECLARE temp_column VARCHAR(100); 
-- 创建结束标志变量  
DECLARE done INT DEFAULT false;
-- 定义游标来操作每一个COLUMN_NAME
DECLARE cursor_column CURSOR FOR
SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE table_schema = schema_name AND table_name = table_name2;
-- 指定游标循环结束时的返回值  
DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = true;  
-- 打开游标
OPEN cursor_column;
read_loop:LOOP
           FETCH cursor_column INTO temp_column;
           -- 判断游标的循环是否结束 
           IF done THEN 
                    LEAVE read_loop;
           END IF;
           -- 这里需要设置具体的SQL语句temp_query
           SET @temp_query=CONCAT('SELECT COUNT(*) as ', temp_column, '_null_num FROM ', table_name2, ' WHERE ', temp_column, ' IS NULL');
           -- 执行SQL语句
           PREPARE stmt FROM @temp_query;           
           EXECUTE stmt;
END LOOP;
-- 关闭游标
CLOSE cursor_column;
END
```

我来说下这个存储过程的作用，首先我定义了两个输入的参数schema\_name和table\_name2，用来接收想要检查的数据库的名称以及数据表名。

然后使用游标来操作读取出来的column\_name，赋值给变量temp\_column。对于列名，我们需要检查它是否为空，但是这个列名在MySQL中是动态的，我们无法使用@temp\_column 来表示列名，对其进行判断，在这里我们需要使用SQL拼接的方式，这里我设置了@temp\_query表示想要进行查询的SQL语句，然后设置COUNT(\*)的别名为动态别名，也就是temp\_column加上\_null\_num，同样在WHERE条件判断中，我们使用temp\_column进行动态列名的输出，以此来判断这个列数值是否为空。

然后我们执行这个SQL语句，提取相应的结果。

```
call check_column_null_num('wucai', 'titanic_train'); 
```

运行结果如下：

```
Age_null_num：177
Cabin_null_num：687
Embarked_null_num：2
Fare_null_num：0
Name_null_num：0
Parch_null_num：0
PassengerId_null_num：0
Pclass_null_num：0
Sex_null_num：0
SibSp_null_num：0
Survived_null_num：0
Ticket_null_num：0
```

为了浏览方便我调整了运行结果的格式，你能看到在titanic\_train数据表中，有3个字段是存在空值的，其中Cabin空值数最多为687个，Age字段空值个数177个，Embarked空值个数2个。

既然存在空值的情况，我们就需要对它进行处理。针对缺失值，我们有3种处理方式。

1. 删除：删除数据缺失的记录；
2. 均值：使用当前列的均值；
3. 高频：使用当前列出现频率最高的数据。

对于Age字段，这里我们采用均值的方式进行填充，但如果直接使用SQL语句可能会存在问题，比如下面这样。

```
UPDATE titanic_train SET age = (SELECT AVG(age) FROM titanic_train) WHERE age IS NULL
```

这时会报错：

```
1093 - You can't specify target table 'titanic_train' for update in FROM clause
```

也就是说同一条SQL语句不能先查询出来部分内容，再同时对当前表做修改。

这种情况下，最简单的方式就是复制一个临时表titanic\_train2，数据和titanic\_train完全一样，然后再执行下面这条语句：

```
UPDATE titanic_train SET age = (SELECT ROUND(AVG(age),1) FROM titanic_train2) WHERE age IS NULL
```

这里使用了ROUND函数，对age平均值AVG(age)进行四舍五入，只保留小数点后一位。

针对Cabin这个字段，我们了解到这个字段代表用户的船舱位置，我们先来看下Cabin字段的数值分布情况：

```
SELECT COUNT(cabin), COUNT(DISTINCT(cabin)) FROM titanic_train
```

运行结果：

![](https://static001.geekbang.org/resource/image/37/13/379348df1bdd00235646df78ebc54f13.png?wh=891%2A132)  
从结果中能看出Cabin字段的数值分布很广，而且根据常识，我们也可以知道船舱位置每个人的差异会很大，这里既不能删除掉记录航，又不能采用均值或者高频的方式填充空值，实际上这些空值即无法填充，也无法对后续分析结果产生影响，因此我们可以不处理这些空值，保留即可。

然后我们来看下Embarked字段，这里有2个空值，我们可以采用该字段中高频值作为填充，首先我们先了解字段的分布情况使用：

```
SELECT COUNT(*), embarked FROM titanic_train GROUP BY embarked
```

运行结果：

![](https://static001.geekbang.org/resource/image/0e/cc/0efcdf6248e65e482502dbe313c6efcc.png?wh=803%2A282)  
我们可以直接用S来对缺失值进行填充：

```
UPDATE titanic_train SET embarked = 'S' WHERE embarked IS NULL
```

至此，对于titanic\_train这张数据表中的缺失值我们就处理完了。

### 检查全面性

在这个过程中，我们需要观察每一列的数值情况，同时查看每个字段的类型。

![](https://static001.geekbang.org/resource/image/46/77/46d0be3acf6bf3526284cf4e56202277.png?wh=1730%2A692)  
因为数据是直接从CSV文件中导进来的，所以每个字段默认都是VARCHAR(255)类型，但很明显PassengerID、Survived、Pclass和Sibsp应该设置为INT类型，Age和Fare应该设置为DECIMAL类型，这样更方便后续的操作。使用下面的SQL命令即可：

```
ALTER TABLE titanic_train CHANGE PassengerId PassengerId INT(11) NOT NULL PRIMARY KEY;
ALTER TABLE titanic_train CHANGE Survived Survived INT(11) NOT NULL;
ALTER TABLE titanic_train CHANGE Pclass Pclass INT(11) NOT NULL;
ALTER TABLE titanic_train CHANGE Sibsp Sibsp INT(11) NOT NULL;
ALTER TABLE titanic_train CHANGE Age Age DECIMAL(5,2) NOT NULL;
ALTER TABLE titanic_train CHANGE Fare Fare DECIMAL(7,4) NOT NULL;
```

然后我们将其余的字段（除了Cabin）都进行NOT NULL，这样在后续进行数据插入或其他操作的时候，即使发现数据异常，也可以对字段进行约束规范。

在全面性这个检查阶段里，除了字段类型定义需要修改以外，我们没有发现其他问题。

**然后我们来检查下合法性及唯一性。**合法性就是要检查数据内容、大小等是否合法，这里不存在数据合法性问题。

针对数据是否存在重复的情况，我们刚才对PassengerId 字段类型进行更新的时候设置为了主键，并没有发现异常，证明数据是没有重复的。

## 对清洗之后的数据进行可视化

我们之前讲到过如何通过Excel来导入MySQL中的数据，以及如何使用Excel来进行数据透视表和数据透视图的呈现。

这里我们使用MySQL For Excel插件来进行操作，在操作之前有两个工具需要安装。

首先是mysql-for-excel，点击[这里](https://dev.mysql.com/downloads/windows/excel/)进行下载；然后是mysql-connector-odbc，点击[这里](https://dev.mysql.com/downloads/connector/odbc/)进行下载。

安装好之后，我们新建一个空的excel文件，打开这个文件，在数据选项中可以找到“MySQL for Excel”按钮，点击进入，然后输入密码连接MySQL数据库。

然后选择我们的数据库以及数据表名称，在下面可以找到Import MySQL Data按钮，选中后将数据表导入到Excel文件中。

![](https://static001.geekbang.org/resource/image/69/f0/69aa90c22d9ecf107271e1dee38675f0.png?wh=1730%2A732)  
在“插入”选项中找到“数据透视图”，这里我们选中Survived、Sex和Embarked字段，然后将Survive字段放到图例（系列）栏中，将Sex字段放到求和值栏中，可以看到呈现出如下的数据透视表：

![](https://static001.geekbang.org/resource/image/03/74/03b27cf20f5e3dc313014c1018121174.png?wh=1506%2A900)  
从这个透视表中你可以清晰地了解到用户生存情况（Survived）与Embarked字段的关系，当然你也可以通过数据透视图进行其他字段之间关系的探索。

为了让你能更好地理解操作的过程，我录制了一段操作视频。

## 总结

在数据清洗过程中，你能看到通过SQL来进行数据概览的查询还是很方便的，但是使用SQL做数据清洗，会有些繁琐，这时你可以采用存储过程对数据进行逐一处理，当然你也可以使用后端语言，比如使用Python来做具体的数据清洗。

在进行数据探索的过程中，我们可能也会使用到数据可视化，如果不采用Python进行可视化，你也可以选择使用Excel自带的数据透视图来进行可视化的呈现，它会让你对数据有个更直观的认识。

今天讲解的数据清洗的实例比较简单，实际上数据清洗是个反复的过程，有时候我们需要几天时间才能把数据完整清洗好。你在工作中，会使用哪些工具进行数据清洗呢？

另外，数据缺失问题在数据清洗中非常常见，我今天列举了三种填充数据缺失的方式，分别是删除、均值和高频的方式。实际上缺失值的处理方式不局限于这三种，你可以思考下，如果数据量非常大，某个字段的取值分布也很广，那么对这个字段中的缺失值该采用哪种方式来进行数据填充呢？

欢迎你在评论区写下你的思考，也欢迎把这篇文章分享给你的朋友或者同事，一起交流一下。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>JustDoDT</span> 👍（13） 💬（1）<p># Mac只能用Python了
import pandas as pd
import matplotlib.pyplot as plt

# 读入清洗好的数据
df = pd.read_csv(&#39;.&#47;titanic_train.csv&#39;)

# 数据透视表用到的数据 df_temp
df_temp = df[[&#39;Embarked&#39;, &#39;Survived&#39;]]

# 生成数据透视表
## 方法1 
table = pd.pivot_table(df_temp, index=[&#39;Embarked&#39;], columns=[&#39;Survived&#39;], aggfunc=len)
table = pd.pivot_table(df_temp, index=[&#39;Embarked&#39;], columns=[&#39;Survived&#39;], aggfunc=len)
## 方法2 数据交叉表
table = pd.crosstab(df.Embarked, df.Survived)

# 画图
table.plot(kind=&#39;bar&#39;)
plt.show()

----------------分割线 上面是code------------------
talbe
# 输出结果
Survived	0	1
Embarked		
C	75	93
Q	47	30
S	427	219
</p>2019-09-23</li><br/><li><span>骑行的掌柜J</span> 👍（10） 💬（3）<p>陈老师 我对这一节的操作全部用MySQL进行了一个实操 中间遇到一些问题 我也全部做了一个整理补充 放到了我的博客里面：https:&#47;&#47;blog.csdn.net&#47;weixin_41013322&#47;article&#47;details&#47;103616783  希望对后面学习的朋友有帮助 谢谢</p>2019-12-19</li><br/><li><span>ABC</span> 👍（4） 💬（1）<p>WPS同样可以使用,这种方式很方便.所需下载的文件我放到网盘了，地址: 链接: https:&#47;&#47;pan.baidu.com&#47;s&#47;1Wrq7VcypQiofKp70YaQLBA 提取码: 2avt

看了这一课，忽然想去买数据分析的课学习一下.</p>2019-11-30</li><br/><li><span>JustDoDT</span> 👍（3） 💬（1）<p>仅对某一列缺失值处理
时序数据：线性插值
频谱数据：重采样
……</p>2019-09-23</li><br/><li><span>哈66</span> 👍（2） 💬（1）<p>老是想问一下收集过来的数据为什么需要清洗啊，能具体举一些使用场景嘛？</p>2019-12-16</li><br/><li><span>Venom</span> 👍（2） 💬（2）<p>找不到数据集的人，这里能下，我也是刚找到。https:&#47;&#47;download.csdn.net&#47;download&#47;qq_44851287&#47;11142360</p>2019-11-12</li><br/><li><span>Elliot</span> 👍（2） 💬（2）<p>https:&#47;&#47;www.kaggle.com&#47;c&#47;titanic&#47;data 这个属于github的吗？</p>2019-10-27</li><br/><li><span>JustDoDT</span> 👍（2） 💬（1）<p>我的Python代码github地址
https:&#47;&#47;github.com&#47;LearningChanging&#47;sql_must_konw&#47;tree&#47;master&#47;45-%E6%95%B0%E6%8D%AE%E6%B8%85%E6%B4%97%EF%BC%9A%E5%A6%82%E4%BD%95%E4%BD%BF%E7%94%A8SQL%E5%AF%B9%E6%95%B0%E6%8D%AE%E8%BF%9B%E8%A1%8C%E6%B8%85%E6%B4%97%EF%BC%9F</p>2019-09-23</li><br/><li><span>海洋</span> 👍（6） 💬（0）<p>检查全面性修改字段类型时，直接使用Navicat的设计表格功能修改，更快，只不过不利于新手锻炼SQL代码能力，同时可视化这块，一般清洗后，直接导出，然后使用Python或者BI软件进行进一步分析可视化</p>2019-09-23</li><br/><li><span>完美坚持</span> 👍（2） 💬（0）<p>可以用 LOAD DATA 导入，但是要注意，在默认的严格模式下，如果设置 age 列为 numeric 的类型，将会报错无法读取，原因是空字符段无法读取。
即使调整为非严格模式读取成功，Age 和 cabin 空的部分，本来该是NULL，但是在SQL读取后，分别是 0 和 空字符串，并非NULL。
先创建表格：
CREATE TABLE titanic_train(
	passenger_id INT(3) PRIMARY KEY,
	survived INT(1),
	pcalss INT(1),
	name VARCHAR(255),
	sex VARCHAR(6),
	age DECIMAL(4,2),
	sibsp INT(1),
	parch INT(1),
	ticket VARCHAR(20),
	fare DECIMAL(7,4),
	cabin VARCHAR(5),
	embarked CHAR(1)
) ENGINE = InnoDB CHARACTER SET = utf8 COLLATE = utf8_general_ci ROW_FORMAT = Dynamic;
再导入数据：
LOAD DATA INFILE &#39;文件位置&#47;train.csv&#39; 
  INTO TABLE titanic_train
  FIELDS TERMINATED BY &#39;,&#39; OPTIONALLY ENCLOSED BY &#39;&quot;&#39; ESCAPED BY &#39;&quot;&#39;
  LINES TERMINATED BY &#39;\n&#39;
  IGNORE 1 LINES
  (passenger_id, survived, pcalss, name, sex, @age, sibsp, parch, ticket, fare, @cabin, embarked)
  SET age = NULLIF(@age,&#39;&#39;), cabin = NULLIF(@cabin,&#39;&#39;);</p>2021-06-10</li><br/><li><span>完美坚持</span> 👍（1） 💬（0）<p>mport pandas as pd
import matplotlib.pyplot as plt

# Python导入数据
titanic_train1 = pd.read_csv(&#39;train.csv&#39;)
# 大致看下数据，注意到空值可以正常读取为NaN，如果直接用MySQL客户端中LOAD DATA，会出现很多问题
titanic_train1.head(8)

# 完整性
titanic_train1.isnull().sum()

# 简单查看数据
titanic_train1.describe()

# Age 列均值填充
titanic_train1.Age.fillna(titanic_train1.Age.mean(), inplace = True)

# Cabin 列的不重复取值有多少个
titanic_train1.Cabin.nunique()
# Cabin 列一共有多少个非空取值
titanic_train1.Cabin.count()
# 上述两步只用一步就可以得出
titanic_train1.Cabin.describe()
# 只有三种取值
titanic_train1.Embarked.describe()
# 统计离散的登录港口变量，每个港口的个数统计
titanic_train1.Embarked.value_counts()
# 采用高频方式填充控制
titanic_train1.Embarked.fillna(&#39;S&#39;, inplace = True)

# MySQL导入清洗好的数据

# -*- coding: UTF-8 -*-
import mysql.connector
# 打开数据库连接
db = mysql.connector.connect(
       host=&quot;localhost&quot;,
       user=&quot;root&quot;,
       passwd=&quot;***********&quot;, # 写上你的数据库密码
       database=&#39;XXX, 
       auth_plugin=&#39;mysql_native_password&#39;
)
# 获取操作游标 
cursor = db.cursor()
# 执行SQL语句
cursor.execute(&quot;SELECT GROUP_CONCAT(column_name SEPARATOR &#39;, &#39;) FROM information_schema.COLUMNS WHERE table_name = &#39;titanic_train&#39;&quot;)
# 获取一条数据：列名
data = cursor.fetchone()
print(&quot;列名: %s &quot; % data)

cursor.execute(&quot;SELECT * FROM titanic_train&quot;)
# 获取一条数据
data = cursor.fetchall()
titanic_train2 = pd.DataFrame(data, 
                              columns = [&quot;passenger_id&quot;, &quot;Survived&quot;, &quot;pcalss&quot;, &quot;name&quot;, &quot;sex&quot;, &quot;Age&quot;, &quot;Sibsp&quot;, &quot;parch&quot;, &quot;ticket&quot;, &quot;Fare&quot;, &quot;cabin&quot;, &quot;embarked&quot; ])

# 数据可视化

# 数据透视表
table = pd.crosstab(titanic_train1.Embarked, titanic_train1.Survived)
print(table)

# 用得到的数据透视表作数据透视图
table.plot(kind=&#39;bar&#39;, ylabel = &#39;Frequency&#39;)
plt.show()

# 法二直接画图
import seaborn as sns
ax = sns.countplot(x=&quot;Embarked&quot;, hue=&quot;Survived&quot;, data=titanic_train1)</p>2021-06-11</li><br/><li><span>完美坚持</span> 👍（1） 💬（0）<p>LOAD DATA 导入数据 （二）
下面就来解决这个问题：
很容易想到方法一，但是觉得在数据量很大的时候，方法一还要在扫一遍表，而方法二只需要在读取扫描的时候，顺带加一个判断就行了，觉得这样的话，方法一消耗了一些不必要的资源。

**方法一**：导入数据后进行修改（利用 UPDATE）

**方法二**：读取数据时进行判断
参考：【解决Mysql导入csv中空值变为0的问题：导入数据时设定格式】
https:&#47;&#47;blog.csdn.net&#47;duckyamd&#47;article&#47;details&#47;53143639

先获得所有列名，用逗号 &#39;,&#39; 分隔，这样方便我们之后写“读取数据时进行判断”的 LOAD DATA 的代码：

SELECT GROUP_CONCAT(column_name SEPARATOR &#39;, &#39;) FROM information_schema.COLUMNS WHERE table_name = &#39;titanic_train&#39;;
+---------------------------------------------------------------------------------------------+
| GROUP_CONCAT(column_name SEPARATOR &#39;, &#39;)                                                    |
+---------------------------------------------------------------------------------------------+
| passenger_id, survived, pcalss, name, sex, age, sibsp, parch, ticket, fare, cabin, embarked |
+---------------------------------------------------------------------------------------------+
1 row in set (0.02 sec)
参考：GROUP_CONCAT 的官方文档说明：https:&#47;&#47;dev.mysql.com&#47;doc&#47;refman&#47;8.0&#47;en&#47;aggregate-functions.html#function_group-concat

passenger_id, survived, pcalss, name, sex, age, sibsp, parch, ticket, fare, cabin, embarked

# 删除表格数据
DELETE FROM titanic_train

-- 加载数据的时候进行判断
LOAD DATA INFILE &#39;C:&#47;Users&#47;ASUS&#47;Documents&#47;Python Scripts&#47;sql&#47;train_ansi.csv&#39;
  INTO TABLE titanic_train
  FIELDS TERMINATED BY &#39;,&#39; OPTIONALLY ENCLOSED BY &#39;&quot;&#39; ESCAPED BY &#39;&quot;&#39;
  LINES TERMINATED BY &#39;\n&#39;
  IGNORE 1 LINES
  (passenger_id, survived, pcalss, name, sex, @age, sibsp, parch, ticket, fare, @cabin, embarked)
  SET age = NULLIF(@age,&#39;&#39;), cabin = NULLIF(@cabin,&#39;&#39;);
Query OK, 891 rows affected (0.05 sec)
Records: 891  Deleted: 0  Skipped: 0  Warnings: 0
可以看到相应空字符的位置是 null 而不是 0 了
NULLIF 的文档：意思就是如果这个变量是空字符就设置为null
https:&#47;&#47;dev.mysql.com&#47;doc&#47;refman&#47;8.0&#47;en&#47;flow-control-functions.html#function_nullif</p>2021-06-10</li><br/><li><span>完美坚持</span> 👍（1） 💬（0）<p>LOAD DATA 导入数据（没有Navicat）（一）：
CREATE TABLE titanic_train(
	passenger_id INT(3) PRIMARY KEY,
	survived INT(1),
	pcalss INT(1),
	name VARCHAR(255),
	sex VARCHAR(6),
	age DECIMAL(4,2),
	sibsp INT(1),
	parch INT(1),
	ticket VARCHAR(20),
	fare DECIMAL(7,4),
	cabin VARCHAR(5),
	embarked CHAR(1)
) ENGINE = InnoDB CHARACTER SET = utf8 COLLATE = utf8_general_ci ROW_FORMAT = Dynamic;

ALTER TABLE titanic_train MODIFY name VARCHAR(255);
ALTER TABLE titanic_train MODIFY sex VARCHAR(6);
ALTER TABLE titanic_train MODIFY age INT(2) DEFAULT NULL;
ALTER TABLE titanic_train MODIFY fare DECIMAL(7,4);
ALTER TABLE titanic_train MODIFY cabin VARCHAR(255);

SET SESSION sql_mode = &#39;&#39;; -- 严格模式下会报错：Incorrect integer value: &#39;&#39; for column &#39;出错的column&#39; at row 出错的行数
-- 这里将session 的 sql_mode 置为空，就不是严格模式了
-- 另外 这里Setting the SESSION variable affects only the current client. Each client can change its session sql_mode value at any time. 
-- 参考：SQL mode  网址：https:&#47;&#47;dev.mysql.com&#47;doc&#47;refman&#47;8.0&#47;en&#47;sql-mode.html#sqlmode_strict_trans_tables

LOAD DATA INFILE &#39;C:&#47;Users&#47;ASUS&#47;Documents&#47;Python Scripts&#47;sql&#47;train_ansi.csv&#39; 
  INTO TABLE titanic_train
  FIELDS TERMINATED BY &#39;,&#39; OPTIONALLY ENCLOSED BY &#39;&quot;&#39; ESCAPED BY &#39;&quot;&#39;
  LINES TERMINATED BY &#39;\n&#39;
  IGNORE 1 LINES;

SHOW warnings;
-- 在非严格模式下，很多严格模式下的错误会退化为 warnings，此时一定要查看 warnings，发现需要改正的问题。理论上讲，除了要忽略的问题（比如这里空字符无法导入int类型）之外，没有其他问题的时候，用严格模式来忽略这些问题；但是通常我们可能还有其它应该避免、不应该忽略的问题，最好查看一下非严格模式下的warnings.

-- 官方文档和很多资料里，都是 LINES TERMINATED BY &#39;\r\n&#39;，但是我只有用 \n 才能插入成功
-- 发现空字符串不能被正常读取为（数据库中的）NULL，cabin就算了（空字符和NULL的区别可能影响不大），但是age空字符串在非严格模式下（在严格模式下根本无法导入数据，会报错：Incorrect integer value: &#39;&#39; for column &#39;出错的column&#39; at row 出错的行数），空字符导入后就变成了0，但是那些乘客显然不是零岁啊（我的数据里面出错的是 Age 一列）
【mysql 导入csv空值_如何处理csv中的空值】https:&#47;&#47;blog.csdn.net&#47;weixin_29969209&#47;article&#47;details&#47;114795753 这篇文章也提到了这个问题，主要讲了讲可能会带来那些衍生的问题，并且讨论了Python和 mysql 数据交互时，空字符串读取的情况，但是并没有解决问题。
</p>2021-06-10</li><br/><li><span>ClaireToffler</span> 👍（1） 💬（0）<p>LTP 称之为联机事务处理，我们之前讲解的对数据进行增删改查，SQL 查询优化，事务处理等就属于 OLTP 的范畴。它对实时性要求高，需要将用户的数据有效地存储到数据库中，同时有时候针对互联网应用的需求，我们还需要设置数据库的主从架构保证数据库的高并发和高可用性。 忽然感觉平时好像只接触了这个领域</p>2020-04-01</li><br/><li><span>阿飛</span> 👍（1） 💬（0）<p>有没有oracle for excel
</p>2019-12-29</li><br/>
</ul>