你好，我是徐昊。从今天开始，让我们进入实战中的TDD环节。也就是使用TDD的方式，去实现我们工作中常用的技术框架。

之所以选择常用的技术框架，而不虚构某个业务系统，主要是因为TDD的难点首先在于理解需求，并将需求分解为功能点。虚构的业务系统，难以详尽描述所有的业务假设（功能上、组织上、运营方式上等），不利于你跟随题目自行练习。而使用常用的技术框架，由于你对于大体的功能及其所解决的问题，已经有所了解。我也可以避免无谓的啰嗦。

## RESTful API的开发框架

第一个场景是支撑RESTful API的开发框架，你可以将它想象成mini版本的Dropwizard或者Spring MVC。功能范围包含一个依赖注入容器（Dependency Injection Container/IoC Container）和一个支持RESTful API构建的Web框架。

我们会以Jakarta EE中的Jakarta Dependency Injection和Jakarta RESTful Web Services 为主要功能参考，并对其适当简化，以完成我们的目标。

当我们完成全部功能之后，可以通过类似以下的代码实现RESTful API：

```
package geektime.tdd.resources;
    
import geektime.tdd.model.Student;
import geektime.tdd.model.StudentRepository;
import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import java.util.List;
 
@Path("/students")
public class StudentsResource {
  
    private StudentRepository repository;
    
    @Inject
    public StudentsResource(StudentRepository repository) {
        this.repository = repository;
    }
    
    @GET
    @Produces(MediaType.APPLICATION_JSON)
    public List<Student> all() {
        return repository.all();
    }
    
    @GET
    @Path("{id}")
    @Produces(MediaType.APPLICATION_JSON)
    public Response findById(@PathParam("id") long id) {
        return repository.findById(id).map(Response::ok)
                .orElse(Response.status(Response.Status.NOT_FOUND)).build();
    }
}
```

## 依赖注入容器的大致功能

首先让我们从依赖注入容器开始。关于依赖注入的来龙去脉可以参看Martin Fowler在2004年写的文章[《](https://martinfowler.com/articles/injection.html)[IoC容器与依赖注入模式](https://martinfowler.com/articles/injection.html)[》](https://martinfowler.com/articles/injection.html)。

Jakarta Dependency Injection的功能主要分为三部分：组件的构造、依赖的选择以及生命周期控制。详细说明如视频中所示：

Jakarta Dependency Injection中没有规定而又常用的部分有：配置容器如何配置、容器层级结构以及生命周期回调。详细说明如视频中所示：

## 思考题

那么以此为基础，要如何分解功能点呢？请你自行练习。下节课，我会给出我做的分解列表。

欢迎把你的思考和想法分享在留言区，也欢迎你扫描详情页的二维码加入读者交流群。我们下节课再见！
<div><strong>精选留言（9）</strong></div><ul>
<li><span>🐑</span> 👍（0） 💬（0）<p>TDD专栏福利大合集：

1、打卡赢好礼（4月23日-5月10日）：正在进行中，学习专栏第1-10讲并在留言区打卡，结束后奖励；

2、代码亲手评（5月底）：预计打卡结束后启动，完成前10讲的打卡，即可提交代码练习作业，徐昊老师会亲自点评；

3、线上带你练：根据专栏更新节奏和老师时间安排确定，徐昊老师会线上带四个同学手把手地改代码，敬请期待！

具体活动介绍见 👉 http:&#47;&#47;gk.link&#47;a&#47;11jPi</p>2022-04-28</li><br/><li><span>Flynn</span> 👍（0） 💬（1）<p>&#47;&#47;TODO 1.注入框架是否注册该对象
&#47;&#47;TODO 2.constructor注入获取到的对象是期望的
&#47;&#47;TODO 2.filed注入获取到的对象是期望的
&#47;&#47;TODO 3.method注入获取到的对象是期望的
&#47;&#47;TODO 4.同一scope生命周期是同一个对象
&#47;&#47;TODO 5.不同scope生命周期是不同对象</p>2022-04-16</li><br/><li><span>奇小易</span> 👍（3） 💬（0）<p>&gt; 功能梳理

```text
jakarata dependency injection 核心功能

Q: 组件的构造，指的是什么？
将该组件的实例注入到注入点中。
注入点的常见配置方式有以下三种。
1、构造器注入 
2、字段注入
3、方法注入

Q: 依赖的选择，指的是什么？
指当一个组件的实现有多种时，该如何选择哪一个实现作为当前注入点的实例。

这种选择一方面会导致循环依赖的问题，JSR 330提供Provider接口来解耦它们的直接依赖，从而解决该问题。
另一方面在有不同实现时，可以使用Named注解来标记不同的实现，从而确保实例的选择是符合预期的。

Q: 生命周期的控制，指的是什么？
指一个组件在容器中从创建，到最终的消亡，这整个过程如何实现。
其中需要支持单例和多例的组件构造模式。

```

&gt; 任务列表梳理

```text
TDD工作流程回顾。
首先要基于业务理解分解出功能点，另一方面需要基于架构愿景分解出功能上下文。
最终再在每个功能上下文中分解出具体的任务项。

基于上述内容，可知从业务上核心功能点就是组件的构造、依赖的选择、生命周期的控制。
而对于架构愿景没有很明确的思路，故将功能点作为功能上下文。

此时功能上下文分别是
组件的构造
依赖的选择
生命周期的控制

要将功能上下文分解为任务项，需要思考对外接口以及具体实现方式，最终分解出最小功能单元的测试任务。

&quot;组件的构造&quot;
1、对外接口：在构造器、方法、字段上添加对应注解即可
2、实现思路：扫描指定路径下所有Java文件的注解，分别基于不同类型的注入点，来分别进行处理。

构造器注入
Happy Path:
如果当前类的构造方法中存在&quot;注入注解&quot;，则在容器中创建它之前，给这个参数实例化后再创建。
（感觉这步子有点大）

Sad Path:

字段注入
...
方法注入
...

```

</p>2022-05-04</li><br/><li><span>aoe</span> 👍（3） 💬（0）<p>笔记 https:&#47;&#47;wyyl1.com&#47;post&#47;19&#47;07&#47;

希望留言可以支持 Markdown 格式，这样更容易阅读

## 功能点分解

### happy path

自定义依赖注入的 Annotation

- @Inject：标识这个类可以被容器管理（类似 Spring 的 @Component）
- @Named：可以设置 String 类型的 tag 做唯一标识
- @Scope：标识容器创建的对象是单例、多例的标签
- 支持自定义 Annotation 被容器加入依赖管理（组合 @Inject、@Named、@Scope 实现自定义功能）
- @Constructor：Constructor 注入标签
- @Field：Field 注入标签
- @Method：方法注入标签

将标记的类找到备用

- 扫描项目中所有的类
- 提取出所有标记了依赖注入标签的类的信息
  - 类名称
  - 类的完整路径
  - 类的所有构造器
  - 类上的所有 Annotation
  - 字段上的所有 Annotation
  - 方法上的所有 Annotation
- 解析容器支持的自定义 Annotation
- 将自定义 Annotation 转换为普通的 Annotation
- 收集容器相关的 Annotation 类的信息
- 将这些类的信息存储在容器中

代理类

- 通过代理类实现 Provided 解决循环依赖问题

通过容器获取实例

- 根据 Class 在容器中找到对应的类，返回实例
- 根据 @Named 中的 tag，找到对应的类，返回实例
- 根据 自定义 Annotation 找到对应的类，返回实例
- 利用反射注入：Field 实例
- 利用反射注入：方法参数实例
  
### default path

- @Named：默认去类名（首字母小写）
- @Scope：默认为多例

### sad path

没有匹配到对象

- Class 没有被容器管理
- @Named 没有匹配的字符串
- 不同包下，类名一样
- 多个 @Named 重名
- 不支持第三方 jar 中类由容器统一管理

单例模式下创建对象需要考虑内存消耗、线程安全的问题</p>2022-04-14</li><br/><li><span>于</span> 👍（2） 💬（0）<p>用一个一般复杂度的业务系统更有实用价值，更利于大家跟随、模仿</p>2022-07-02</li><br/><li><span>davix</span> 👍（2） 💬（0）<p>請老師指導下go programmer怎麼學、練習這個項目。</p>2022-05-03</li><br/><li><span>leesper</span> 👍（1） 💬（0）<p>思考题：因为暂时不存在架构愿景，因此可以把功能点当成功能上下文：组件构造、依赖选择、生命周期管理</p>2023-01-21</li><br/><li><span>霜期飞敛</span> 👍（1） 💬（0）<p>
- 组件的构造
  - 扫描指定目录的所有类，识别出所有带有注解@Inject的类
    - sad path：不同包名下的同名class，通过加上包名区分
  - 解析类的注解元素 @Inject，进行归类，用于后续各个阶段的注入
    - 构造器
      - sad path：多个@Inject 注解的构造器，抛出异常
    - 字段
    - 方法
  - 实例的名称
    - 指定的方式
      - sad path：指定多个同名实例，抛出异常
    - default value
      - 默认自动生成的方式：默认类名（首字母小写）的方式
      - 如果有多个 class#1  class#2 这样的方式累加
  - injected constructor
    - 实例化
      - 查找已存在的依赖
      - 通过构造器实例化并注入
    - sad path：循环依赖
  - injected field
    - 实例化
    - 属性设置
      - 依赖查找对应的实例
      - 通过反射实现字段注入
    - sad path：循环依赖
  - method field
    - 实例化
    - 属性设置
      - 依赖查找对应的实例
      - 通过反射调用方法注入
- dependency selection
  - cycle dependency
    - proxy 实现解决循环依赖问题
    - provider(factory) 延迟加载的循环依赖问题
  - by tag
    - by name
    - by annotation
  - sad path：
    - 找不到对应的实例
      - by name
      - by annotation type
    - 找到符合条件的多个实例
      - 通过 @Primary 来进行优先级划分返回
      - sad path：没有 @Primary，抛出异常
- 生命周期控制
  - @Scope
    - singleton 单例实现，多次获取Class的实例返回一个实例
    - prototype 和默认情况相同
    - default value： prototype
</p>2022-04-30</li><br/><li><span>davix</span> 👍（1） 💬（1）<p>學這門課最遺憾的是身為go程序員，不知道Java 這些都是啥</p>2022-04-15</li><br/>
</ul>