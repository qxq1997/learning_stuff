上几节课我们讲到了Spring框架，剖析了背后蕴含的一些通用设计思想，以及用到的十几种设计模式。从今天开始，我们再剖析另外一个Java项目开发中经常用到的框架：MyBatis。因为内容比较多，同样，我们也分三节课来讲解。

- 第一节课，我们分析MyBatis如何权衡代码的易用性、性能和灵活性。
- 第二节课，我们学习如何利用职责链与代理模式实现MyBatis Plugin。
- 第三节课，我们总结罗列一下MyBatis框架中用到的十几种设计模式。

话不多说，让我们正式开始今天的学习吧！

## Mybatis和ORM框架介绍

熟悉Java的同学应该知道，MyBatis是一个ORM（Object Relational Mapping，对象-关系映射）框架。ORM框架主要是根据类和数据库表之间的映射关系，帮助程序员自动实现对象与数据库中数据之间的互相转化。说得更具体点就是，ORM负责将程序中的对象存储到数据库中、将数据库中的数据转化为程序中的对象。实际上，Java中的ORM框架有很多，除了刚刚提到的MyBatis之外，还有Hibernate、TopLink等。

在剖析Spring框架的时候，我们讲到，如果用一句话来总结框架作用的话，那就是简化开发。MyBatis框架也不例外。它简化的是数据库方面的开发。那MyBatis是如何简化数据库开发的呢？我们结合[第59讲](https://time.geekbang.org/column/article/212802)中的JdbcTemplate的例子来说明一下。

在第59讲中，我们讲到，Java提供了JDBC类库来封装不同类型的数据库操作。不过，直接使用JDBC来进行数据库编程，还是有点麻烦的。于是，Spring提供了JdbcTemplate，对JDBC进一步封装，来进一步简化数据库编程。

使用JdbcTemplate进行数据库编程，我们只需要编写跟业务相关的代码（比如，SQL语句、数据库中数据与对象之间的互相转化的代码），其他流程性质的代码（比如，加载驱动、创建数据库连接、创建statement、关闭连接、关闭statement等）都封装在了JdbcTemplate类中，不需要我们重复编写。

当时，为了展示使用JdbcTemplate是如何简化数据库编程的，我们还举了一个查询数据库中用户信息的例子。还是同样这个例子，我再来看下，使用MyBatis该如何实现，是不是比使用JdbcTemplate更加简单。

因为MyBatis依赖JDBC驱动，所以，在项目中使用MyBatis，除了需要引入MyBatis框架本身（mybatis.jar）之外，还需要引入JDBC驱动（比如，访问MySQL的JDBC驱动实现类库mysql-connector-java.jar）。将两个jar包引入项目之后，我们就可以开始编程了。使用MyBatis来访问数据库中用户信息的代码如下所示：

```
// 1. 定义UserDO
public class UserDo {
  private long id;
  private String name;
  private String telephone;
  // 省略setter/getter方法
}

// 2. 定义访问接口
public interface UserMapper {
  public UserDo selectById(long id);
}

// 3. 定义映射关系：UserMapper.xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE mapper PUBLIC "-//mybatis.org/DTD Mapper 3.0//EN"
        "http://mybatis.org/dtd/mybatis-3-mapper.dtd" >
<mapper namespace="cn.xzg.cd.a87.repo.mapper.UserMapper">
    <select id="selectById" resultType="cn.xzg.cd.a87.repo.UserDo">
        select * from user where id=#{id}
    </select>
</mapper>

// 4. 全局配置文件: mybatis.xml
<?xml version="1.0" encoding="UTF-8" ?>
<!DOCTYPE configuration
        PUBLIC "-//mybatis.org//DTD Config 3.0//EN"
        "http://mybatis.org/dtd/mybatis-3-config.dtd">
<configuration>
    <environments default="dev">
        <environment id="dev">
            <transactionManager type="JDBC"></transactionManager>
            <dataSource type="POOLED">
                <property name="driver" value="com.mysql.jdbc.Driver" />
                <property name="url" value="jdbc:mysql://localhost:3306/test?useUnicode=true&characterEncoding=UTF-8" />
                <property name="username" value="root" />
                <property name="password" value="..." />
            </dataSource>
        </environment>
    </environments>
    <mappers>
        <mapper resource="mapper/UserMapper.xml"/>
    </mappers>
</configuration>
```

需要注意的是，在UserMapper.xml配置文件中，我们只定义了接口和SQL语句之间的映射关系，并没有显式地定义类（UserDo）字段与数据库表（user）字段之间的映射关系。实际上，这就体现了“约定优于配置”的设计原则。类字段与数据库表字段之间使用了默认映射关系：类字段跟数据库表中拼写相同的字段一一映射。当然，如果没办法做到一一映射，我们也可以自定义它们之间的映射关系。

有了上面的代码和配置，我们就可以像下面这样来访问数据库中的用户信息了。

```
public class MyBatisDemo {
  public static void main(String[] args) throws IOException {
    Reader reader = Resources.getResourceAsReader("mybatis.xml");
    SqlSessionFactory sessionFactory = new SqlSessionFactoryBuilder().build(reader);
    SqlSession session = sessionFactory.openSession();
    UserMapper userMapper = session.getMapper(UserMapper.class);
    UserDo userDo = userMapper.selectById(8);
    //...
  }
}
```

从代码中，我们可以看出，相对于使用JdbcTemplate的实现方式，使用MyBatis的实现方式更加灵活。在使用JdbcTemplate的实现方式中，对象与数据库中数据之间的转化代码、SQL语句，是硬编码在业务代码中的。而在使用MyBatis的实现方式中，类字段与数据库字段之间的映射关系、接口与SQL之间的映射关系，是写在XML配置文件中的，是跟代码相分离的，这样会更加灵活、清晰，维护起来更加方便。

## 如何平衡易用性、性能和灵活性？

刚刚我们对MyBatis框架做了简单介绍，接下来，我们再对比一下另外两个框架：JdbcTemplate和Hibernate。通过对比我们来看，MyBatis是如何权衡代码的易用性、性能和灵活性的。

我们先来看JdbcTemplate。相对于MyBatis来说，JdbcTemplate更加轻量级。因为它对JDBC只做了很简单的封装，所以性能损耗比较少。相对于其他两个框架来说，它的性能最好。但是，它的缺点也比较明显，那就是SQL与代码耦合在一起，而且不具备ORM的功能，需要自己编写代码，解析对象跟数据库中的数据之间的映射关系。所以，在易用性上它不及其他两个框架。

我们再来看Hibernate。相对于MyBatis来说，Hibernate更加重量级。Hibernate提供了更加高级的映射功能，能够根据业务需求自动生成SQL语句。我们不需要像使用MyBatis那样自己编写SQL。因此，有的时候，我们也把MyBatis称作半自动化的ORM框架，把Hibernate称作全自动化的ORM框架。不过，虽然自动生成SQL简化了开发，但是毕竟是自动生成的，没有针对性的优化。在性能方面，这样得到的SQL可能没有程序员编写得好。同时，这样也丧失了程序员自己编写SQL的灵活性。

实际上，不管用哪种实现方式，从数据库中取出数据并且转化成对象，这个过程涉及的代码逻辑基本是一致的。不同实现方式的区别，只不过是哪部分代码逻辑放到了哪里。有的框架提供的功能比较强大，大部分代码逻辑都由框架来完成，程序员只需要实现很小的一部分代码就可以了。这样框架的易用性就更好些。但是，框架集成的功能越多，为了处理逻辑的通用性，就会引入更多额外的处理代码。比起针对具体问题具体编程，这样性能损耗就相对大一些。

所以，粗略地讲，有的时候，框架的易用性和性能成对立关系。追求易用性，那性能就差一些。相反，追求性能，易用性就差一些。除此之外，使用起来越简单，那灵活性就越差。这就好比我们用的照相机。傻瓜相机按下快门就能拍照，但没有复杂的单反灵活。

实际上，JdbcTemplate、MyBatis、Hibernate这几个框架也体现了刚刚说的这个规律。

JdbcTemplate提供的功能最简单，易用性最差，性能损耗最少，用它编程性能最好。Hibernate提供的功能最完善，易用性最好，但相对来说性能损耗就最高了。MyBatis介于两者中间，在易用性、性能、灵活性三个方面做到了权衡。它支撑程序员自己编写SQL，能够延续程序员对SQL知识的积累。相对于完全黑盒子的Hibernate，很多程序员反倒是更加喜欢MyBatis这种半透明的框架。这也提醒我们，过度封装，提供过于简化的开发方式，也会丧失开发的灵活性。

## 重点回顾

好了，今天的内容到此就讲完了。我们一块来总结回顾一下，你需要重点掌握的内容。

如果你熟悉Java和MyBatis，那你应该掌握今天讲到JDBC、JdbcTemplate、MyBatis、Hibernate之间的区别。JDBC是Java访问数据库的开发规范，提供了一套抽象的统一的开发接口，隐藏不同数据库的访问细节。

JdbcTemplate、MyBatis、Hibernate都是对JDBC的二次封装，为的是进一步简化数据库开发。其中，JdbcTemplate不能算得上是ORM框架，因为还需要程序员自己编程来实现对象和数据库数据之间的互相转化。相对于Hibernate这种连SQL都不用程序员自己写的全自动ORM框架，MyBatis算是一种半自动化的ORM框架。

如果你不熟悉Java和MyBatis，作为背景介绍，那你简单了解一下MyBatis和ORM就可以了。不过，在你熟悉的语言中，应该也有相应的ORM框架，你也可以对比着去分析一下。

今天的内容除了起到对MyBatis做背景介绍之外，我们还学习了代码的易用性、性能、灵活性之间的关系。一般来讲，提供的高级功能越多，那性能损耗就会越大些；用起来越简单，提供越简化的开发方式，那灵活性也就相对越低。

## 课堂讨论

在你的项目开发中，有没有用过哪些框架，能够切实地提高开发效率，减少不必要的体力劳动？

欢迎留言和我分享你的想法。如果有收获，也欢迎你把这篇文章分享给你的朋友。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>，</span> 👍（71） 💬（2）<p>工作中做过一些c++的东西,做起来相当复杂,每引入一个第三方类库,都要自己去github上找,找到再clone下来,打包,才能引入,模板编程面向对象面向过程基于对象函数式,眼花缭乱,指针引用const傻傻分不清楚,cmake打包异常,只有求助大佬才能维持生活
做java就像回家一样,做开发有spring全家桶,打包部署有maven,在csdn比家里感觉好多了,里面各个是人才,说话又好听,只需要CTRL C V就能完成工作,我超喜欢里面的!</p>2020-05-22</li><br/><li><span>Demon.Lee</span> 👍（33） 💬（0）<p>易用性：Hibernate &gt; MyBatis &gt; JdbcTemplate
性能：JdbcTemplate &gt; MyBatis &gt; Hibernate
灵活性：MyBatis &gt; JdbcTemplate &gt; Hibernate</p>2020-05-22</li><br/><li><span>寒溪</span> 👍（27） 💬（2）<p>netty是个反例，兼顾易用性和性能。</p>2020-05-22</li><br/><li><span>Monday</span> 👍（23） 💬（1）<p>mybatis系列
1、mybatis plus 作用如其名，mybatis增强功能封装好了一些crud的方法
2、mybatis-generator自动生成器，自动生成实体、mapper、Mapper.xml等
3、mybatis分页插件PageHelper，无需关心分页的问题</p>2020-05-22</li><br/><li><span>L🚲🐱</span> 👍（15） 💬（1）<p>Mybatis Plus 可以说是 大大的提高了 Mybatis 的使用效率</p>2020-06-01</li><br/><li><span>Amon Tin</span> 👍（8） 💬（0）<p>jooq，试用了一年多了，非常好用，把SQL语法换成了select().from().where().and()这类的Java语法，同时也支持直接写SQL，orm的定义和映射关系也可以根据表结构自动生成，性能可匹敌mybatis，易用性不比hibernate差，可读性比上面两个都强，实乃新一代orm框架之王</p>2021-07-01</li><br/><li><span>君哥聊技术</span> 👍（8） 💬（0）<p>比如做限流的时候可以直接使用guava中的限流器</p>2020-05-22</li><br/><li><span>子豪sirius</span> 👍（7） 💬（8）<p>mybatis可以让开发人员自己写SQL，相比hibernate给了更多控制权。不过在实际开发中有个问题，有些开发人员会写很复杂的SQL，美其名曰是性能更好，但实际性能提升多少，不清楚；反而因为SQL写得巨长巨复杂，带来了阅读困难、调试和查错不便等等问题。明明这部分代码用Java写，业务逻辑是更清晰的～</p>2020-05-22</li><br/><li><span>我是曾经那个少年</span> 👍（5） 💬（0）<p>1:  Spring Boot技术栈，集成外部框架方便。
2：Spring Cloud Alibaba 微服务的技术组件基本够用。
3：hutool工具类方便好用。该有的都有。
4：Mybatis-Plus 避免了最简单的增删改查的实现，以及数据库主键自增，数据字段填充，多数据源的支持。
</p>2021-12-12</li><br/><li><span>test</span> 👍（5） 💬（2）<p>SpringCloud全家桶</p>2020-05-22</li><br/><li><span>iamjohnnyzhuang</span> 👍（4） 💬（0）<p>golang 用的gorm框架。感觉做的算是比较好，又有ORM的特性可以直接做对象转换，又开放了SQL编写，比较灵活。但是有一点，就是sql都编写在代码里和jdbctemplate一致，不是特别好维护。</p>2020-08-06</li><br/><li><span>杨逸林</span> 👍（3） 💬（4）<p>学习 JPA 和 Hibernate 的成本很高，一般人根本不知道什么 HQL，还有 hbm 文件，以及 OneToMany，ManyToMany，ManyToOne，用起来其实很麻烦。而 Mybatis 只要你会写 SQL 就行了，根本不要你了解那些，虽然设计数据库表的时候会用。</p>2020-09-27</li><br/><li><span>夕林语</span> 👍（3） 💬（0）<p>在项目开发当中用到lombok可以减少重复的geter seter方法，虽然有点违背面向对象的特性；还有一些工具类库的使用，比如google guava，一些集合类和字符串的操作大大简化</p>2020-06-02</li><br/><li><span>javaadu</span> 👍（3） 💬（0）<p>目前用过的最好用的框架还是Spring Boot</p>2020-05-24</li><br/><li><span>辣么大</span> 👍（2） 💬（3）<p>使用MyBatis，之前项目组写sql规范中要求不让写 select * 这种sql，说是影响性能。

每个DO都有很多字段，每次写sql写的要吐，没办法自己写了个程序自动生成简单的DO查询sql。</p>2020-05-29</li><br/>
</ul>