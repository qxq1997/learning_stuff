通过专栏上一期的学习我们知道，浏览器发给服务端的是一个HTTP格式的请求，HTTP服务器收到这个请求后，需要调用服务端程序来处理，所谓的服务端程序就是你写的Java类，一般来说不同的请求需要由不同的Java类来处理。

那么问题来了，HTTP服务器怎么知道要调用哪个Java类的哪个方法呢。最直接的做法是在HTTP服务器代码里写一大堆if else逻辑判断：如果是A请求就调X类的M1方法，如果是B请求就调Y类的M2方法。但这样做明显有问题，因为HTTP服务器的代码跟业务逻辑耦合在一起了，如果新加一个业务方法还要改HTTP服务器的代码。

那该怎么解决这个问题呢？我们知道，面向接口编程是解决耦合问题的法宝，于是有一伙人就定义了一个接口，各种业务类都必须实现这个接口，这个接口就叫Servlet接口，有时我们也把实现了Servlet接口的业务类叫作Servlet。

但是这里还有一个问题，对于特定的请求，HTTP服务器如何知道由哪个Servlet来处理呢？Servlet又是由谁来实例化呢？显然HTTP服务器不适合做这个工作，否则又和业务类耦合了。

于是，还是那伙人又发明了Servlet容器，Servlet容器用来加载和管理业务类。HTTP服务器不直接跟业务类打交道，而是把请求交给Servlet容器去处理，Servlet容器会将请求转发到具体的Servlet，如果这个Servlet还没创建，就加载并实例化这个Servlet，然后调用这个Servlet的接口方法。因此Servlet接口其实是**Servlet容器跟具体业务类之间的接口**。下面我们通过一张图来加深理解。

![](https://static001.geekbang.org/resource/image/df/01/dfe304d3336f29d833b97f2cfe8d7801.jpg?wh=1468%2A612)

图的左边表示HTTP服务器直接调用具体业务类，它们是紧耦合的。再看图的右边，HTTP服务器不直接调用业务类，而是把请求交给容器来处理，容器通过Servlet接口调用业务类。因此Servlet接口和Servlet容器的出现，达到了HTTP服务器与业务类解耦的目的。

而Servlet接口和Servlet容器这一整套规范叫作Servlet规范。Tomcat和Jetty都按照Servlet规范的要求实现了Servlet容器，同时它们也具有HTTP服务器的功能。作为Java程序员，如果我们要实现新的业务功能，只需要实现一个Servlet，并把它注册到Tomcat（Servlet容器）中，剩下的事情就由Tomcat帮我们处理了。

接下来我们来看看Servlet接口具体是怎么定义的，以及Servlet规范又有哪些要重点关注的地方呢？

## Servlet接口

Servlet接口定义了下面五个方法：

```
public interface Servlet {
    void init(ServletConfig config) throws ServletException;
    
    ServletConfig getServletConfig();
    
    void service(ServletRequest req, ServletResponse res）throws ServletException, IOException;
    
    String getServletInfo();
    
    void destroy();
}
```

其中最重要是的service方法，具体业务类在这个方法里实现处理逻辑。这个方法有两个参数：ServletRequest和ServletResponse。ServletRequest用来封装请求信息，ServletResponse用来封装响应信息，因此**本质上这两个类是对通信协议的封装。**

比如HTTP协议中的请求和响应就是对应了HttpServletRequest和HttpServletResponse这两个类。你可以通过HttpServletRequest来获取所有请求相关的信息，包括请求路径、Cookie、HTTP头、请求参数等。此外，我在专栏上一期提到过，我们还可以通过HttpServletRequest来创建和获取Session。而HttpServletResponse是用来封装HTTP响应的。

你可以看到接口中还有两个跟生命周期有关的方法init和destroy，这是一个比较贴心的设计，Servlet容器在加载Servlet类的时候会调用init方法，在卸载的时候会调用destroy方法。我们可能会在init方法里初始化一些资源，并在destroy方法里释放这些资源，比如Spring MVC中的DispatcherServlet，就是在init方法里创建了自己的Spring容器。

你还会注意到ServletConfig这个类，ServletConfig的作用就是封装Servlet的初始化参数。你可以在`web.xml`给Servlet配置参数，并在程序里通过getServletConfig方法拿到这些参数。

我们知道，有接口一般就有抽象类，抽象类用来实现接口和封装通用的逻辑，因此Servlet规范提供了GenericServlet抽象类，我们可以通过扩展它来实现Servlet。虽然Servlet规范并不在乎通信协议是什么，但是大多数的Servlet都是在HTTP环境中处理的，因此Servet规范还提供了HttpServlet来继承GenericServlet，并且加入了HTTP特性。这样我们通过继承HttpServlet类来实现自己的Servlet，只需要重写两个方法：doGet和doPost。

## Servlet容器

我在前面提到，为了解耦，HTTP服务器不直接调用Servlet，而是把请求交给Servlet容器来处理，那Servlet容器又是怎么工作的呢？接下来我会介绍Servlet容器大体的工作流程，一起来聊聊我们非常关心的两个话题：**Web应用的目录格式是什么样的，以及我该怎样扩展和定制化Servlet容器的功能**。

**工作流程**

当客户请求某个资源时，HTTP服务器会用一个ServletRequest对象把客户的请求信息封装起来，然后调用Servlet容器的service方法，Servlet容器拿到请求后，根据请求的URL和Servlet的映射关系，找到相应的Servlet，如果Servlet还没有被加载，就用反射机制创建这个Servlet，并调用Servlet的init方法来完成初始化，接着调用Servlet的service方法来处理请求，把ServletResponse对象返回给HTTP服务器，HTTP服务器会把响应发送给客户端。同样我通过一张图来帮助你理解。

![](https://static001.geekbang.org/resource/image/b7/15/b70723c89b4ed0bccaf073c84e08e115.jpg?wh=1168%2A572)

**Web应用**

Servlet容器会实例化和调用Servlet，那Servlet是怎么注册到Servlet容器中的呢？一般来说，我们是以Web应用程序的方式来部署Servlet的，而根据Servlet规范，Web应用程序有一定的目录结构，在这个目录下分别放置了Servlet的类文件、配置文件以及静态资源，Servlet容器通过读取配置文件，就能找到并加载Servlet。Web应用的目录结构大概是下面这样的：

```
| -  MyWebApp
      | -  WEB-INF/web.xml        -- 配置文件，用来配置Servlet等
      | -  WEB-INF/lib/           -- 存放Web应用所需各种JAR包
      | -  WEB-INF/classes/       -- 存放你的应用类，比如Servlet类
      | -  META-INF/              -- 目录存放工程的一些信息
```

Servlet规范里定义了**ServletContext**这个接口来对应一个Web应用。Web应用部署好后，Servlet容器在启动时会加载Web应用，并为每个Web应用创建唯一的ServletContext对象。你可以把ServletContext看成是一个全局对象，一个Web应用可能有多个Servlet，这些Servlet可以通过全局的ServletContext来共享数据，这些数据包括Web应用的初始化参数、Web应用目录下的文件资源等。由于ServletContext持有所有Servlet实例，你还可以通过它来实现Servlet请求的转发。

**扩展机制**

不知道你有没有发现，引入了Servlet规范后，你不需要关心Socket网络通信、不需要关心HTTP协议，也不需要关心你的业务类是如何被实例化和调用的，因为这些都被Servlet规范标准化了，你只要关心怎么实现的你的业务逻辑。这对于程序员来说是件好事，但也有不方便的一面。所谓规范就是说大家都要遵守，就会千篇一律，但是如果这个规范不能满足你的业务的个性化需求，就有问题了，因此设计一个规范或者一个中间件，要充分考虑到可扩展性。Servlet规范提供了两种扩展机制：**Filter**和**Listener**。

**Filter**是过滤器，这个接口允许你对请求和响应做一些统一的定制化处理，比如你可以根据请求的频率来限制访问，或者根据国家地区的不同来修改响应内容。过滤器的工作原理是这样的：Web应用部署完成后，Servlet容器需要实例化Filter并把Filter链接成一个FilterChain。当请求进来时，获取第一个Filter并调用doFilter方法，doFilter方法负责调用这个FilterChain中的下一个Filter。

**Listener**是监听器，这是另一种扩展机制。当Web应用在Servlet容器中运行时，Servlet容器内部会不断的发生各种事件，如Web应用的启动和停止、用户请求到达等。 Servlet容器提供了一些默认的监听器来监听这些事件，当事件发生时，Servlet容器会负责调用监听器的方法。当然，你可以定义自己的监听器去监听你感兴趣的事件，将监听器配置在`web.xml`中。比如Spring就实现了自己的监听器，来监听ServletContext的启动事件，目的是当Servlet容器启动时，创建并初始化全局的Spring容器。

到这里相信你对Servlet容器的工作原理有了深入的了解，只有理解了这些原理，我们才能更好的理解Tomcat和Jetty，因为它们都是Servlet容器的具体实现。后面我还会详细谈到Tomcat和Jetty是如何设计和实现Servlet容器的，虽然它们的实现方法各有特点，但是都遵守了Servlet规范，因此你的Web应用可以在这两个Servlet容器中方便的切换。

## 本期精华

今天我们学习了什么是Servlet，回顾一下，Servlet本质上是一个接口，实现了Servlet接口的业务类也叫Servlet。Servlet接口其实是Servlet容器跟具体Servlet业务类之间的接口。Servlet接口跟Servlet容器这一整套规范叫作Servlet规范，而Servlet规范使得程序员可以专注业务逻辑的开发，同时Servlet规范也给开发者提供了扩展的机制Filter和Listener。

最后我给你总结一下Filter和Listener的本质区别：

- **Filter是干预过程的**，它是过程的一部分，是基于过程行为的。
- **Listener是基于状态的**，任何行为改变同一个状态，触发的事件是一致的。

## 课后思考

Servlet容器与Spring容器有什么关系？

不知道今天的内容你消化得如何？如果还有疑问，请大胆的在留言区提问，也欢迎你把你的课后思考和心得记录下来，与我和其他同学一起讨论。如果你觉得今天有所收获，欢迎你把它分享给你的朋友。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>天琊</span> 👍（390） 💬（24）<p>文章中提到
1.SpringMVC 容器实在DispatcherServlet中init方法里创建的。
2.Spring 容器是通过Listener创建的
a、就是说SpringMVC容器和Spring容器还不一样，那么他们是什么关系？
b、他们和Servlet容器又是啥关系？</p>2019-05-16</li><br/><li><span>Monday</span> 👍（51） 💬（2）<p>基于思考题，我在梦中醒来，觉得servlet容器管理的是servlet（把controller也理解成了servlet），spring容器则是管理service，DAO这类bean。这样理解的话springMVC不就是多余的了吗？但是我们项目中都有使用springMVC，存在即合理，所以我的理解是有误的。于是想老师帮忙给出以下三张图。非常感谢，
1，恳求老师能给出servlet，spring，springMVC三个容器的关系图。
2，恳求老师给出初始化三个容器的顺序图
3，恳求老师给出tomcat在响应客户端请求时，以上3个容器的分工以及各自是在什么时候产生作用的。类似于第2节http必知必会中，用户在浏览器输入url到最后浏览器返回展示的那样的11步的图，并做出每一步的解释。
PS：本文通读不少于3遍，收获颇丰。提这个问题是手机敲的字，和整理提问思路一起花了半小时。</p>2019-05-17</li><br/><li><span>neohope</span> 👍（48） 💬（9）<p>Servlet容器，是用于管理Servlet生命周期的。
Spring容器，是用于管理Spring Bean生命周期的。
SpringMVC容器，适用于管理SpringMVC Bean生命周期的。

Tomcat&#47;Jetty启动，对于每个WebApp，依次进行初始化工作：
1、对每个WebApp，都有一个WebApp ClassLoader，和一个ServletContext
2、ServletContext启动时，会扫描web.xml配置文件，找到Filter、Listener和Servlet配置

3、如果Listener中配有spring的ContextLoaderListener
3.1、ContextLoaderListener就会收到webapp的各种状态信息。
3.3、在ServletContext初始化时，ContextLoaderListener也就会将Spring IOC容器进行初始化，管理Spring相关的Bean。
3.4、ContextLoaderListener会将Spring IOC容器存放到ServletContext中

4、如果Servlet中配有SpringMVC的DispatcherServlet
4.1、DispatcherServlet初始化时（其一次请求到达）。
4.2、其中，DispatcherServlet会初始化自己的SpringMVC容器，用来管理Spring MVC相关的Bean。
4.3、SpringMVC容器可以通过ServletContext获取Spring容器，并将Spring容器设置为自己的根容器。而子容器可以访问父容器，从而在Controller里可以访问Service对象，但是在Service里不可以访问Controller对象。
4.2、初始化完毕后，DispatcherServlet开始处理MVC中的请求映射关系。

有一个很坑问题，Servlet默认是单例模式的，Spring的Bean默认是单例模式的，那Spring MVC是如何处理并发请求的呢？</p>2019-05-19</li><br/><li><span>而立斋</span> 👍（40） 💬（3）<p>spring容器中还包含许多的子容器，其中springmvc容器就是其中常用的一个，文中的DispatcherServlet就是springmvc容器中的servlet接口，也是springmvc容器的核心类。spring容器主要用于整个Web应用程序需要共享的一些组件，比如DAO、数据库的ConnectionFactory等,springmvc的容器主要用于和该Servlet相关的一些组件,比如Controller、ViewResovler等。至此就清楚了spring容器内部的关系，那servlet容器跟spring容器又有什么关系呢？有人说spring容器是servlet容器的子容器，但是这个servlet容器到底是tomcat实现的容器呢，还是jetty实现的容器呢？所以我觉得spring容器与servlet容器他们之间并没有直接的血缘关系，可以说spring容器依赖了servlet容器，spring容器的实现遵循了Servlet 规范。不知道这么理解是可以，还请老师给予指导？</p>2019-05-16</li><br/><li><span>Geek_ebda96</span> 👍（32） 💬（2）<p>老师，spring容器指的是spring本身的ioc容器吧，是用来管理所有的bean，servlet本身会把sping的容器设置到上下文中，而spring mvc的容器dispatch servlet相当于是一个具体的servlet的实现，然后会创建一个全局的上下文application context spring的ioc容器会注入到这个上下文中，后面通过上下文getbean，其实是先找到上下文中的ioc容器，然后再从这个容器拿到具体的bean，这是不是对的？</p>2019-05-17</li><br/><li><span>jaryoung</span> 👍（31） 💬（3）<p>没有Spring boot以前，他们的关系为tomcat抱着Spring的关系，有了Spring boot之后他们关系刚好反过来。</p>2019-08-14</li><br/><li><span>xxxxL</span> 👍（27） 💬（1）<p>请问service方法为什么把request和response都当作输入参数，而不是输入参数只有request，response放到返回值里呢？</p>2019-05-31</li><br/><li><span>菜鸡小王子</span> 👍（17） 💬（1）<p>老师问一下  tomcat分为http服务器+sevlet服务器  这个http服务器怎么理解呢</p>2019-05-30</li><br/><li><span>inrtyx</span> 👍（16） 💬（1）<p>老题，问下。springmvc如何实现url到方法的映射</p>2019-05-23</li><br/><li><span>蓝士钦</span> 👍（14） 💬（2）<p>课后思考：
Servlet容器与Spring容器的关系：
1.Servlet容器管理Servlet对象
2.Spring容器管理Spring 的Bean对象（Service和Dao）
3.SpringMVC容器管理 Controller的Bean对象，本质上也是Servlet对象。Servlet容器和SpringMVC容器通过web.xml配置文件产生交集。
Spring容器管理所有的Bean并且包括SpringMVC容器。

疑问：
为什么SpringMVC要实现自己的容器，并且和Spring容器为父子关系，直接用Spring容器不可以吗？Spring是如何区分Bean属于哪个容器的呢？
</p>2019-06-11</li><br/><li><span>王皓月</span> 👍（12） 💬（1）<p>老师您好！请问您的置顶回复中“IoC容器初始化完毕后，Spring将其存储到ServletContext中，便于以后来获取”，对于这句话我不是很理解，想请老师解答一下IoC容器是如何被存储到ServletContext中的，以及为什么要这么做，相应的源码在哪里看。非常感谢老师~</p>2019-05-17</li><br/><li><span>木木木</span> 👍（11） 💬（1）<p>老师能不能大概介绍下tomcat这种容器的具体调试方式，比如结合一个场景，加载实例化serverlet。</p>2019-05-30</li><br/><li><span>石头狮子</span> 👍（11） 💬（1）<p>servlet 容器抽象了网络处理，请求封装等事情，同样提供了可以处理其他非 http 协议的能力。
spring 容器是依赖注入设计模式的体现，其主要抽象了类初始化，注入，依赖解决，动态代理等功能。
两者主要解决的问题不同。
</p>2019-05-16</li><br/><li><span>LoveDlei</span> 👍（10） 💬（1）<p>请问老师：springboot 和tomcat 如何融合到一起的啊？</p>2019-05-24</li><br/><li><span>-W.LI-</span> 👍（10） 💬（3）<p>老师好!我看留言里有同学说，spring上下文负责创建service和dao的bean，MVC负责创建controller的bean。我们平时说的IOC容器是指哪个啊?还有就是controller注解是一个组合注解，我在controller上用service注解一样能注册成功，spring和MVC容器又是怎么区分这个bean是controller还是service,或者是dao，bean的?还是我完全理解错了。</p>2019-05-18</li><br/>
</ul>