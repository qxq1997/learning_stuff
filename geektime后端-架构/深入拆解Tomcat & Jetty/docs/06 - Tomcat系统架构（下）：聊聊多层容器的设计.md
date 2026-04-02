专栏上一期我们学完了连接器的设计，今天我们一起来看一下Tomcat的容器设计。先复习一下，上期我讲到了Tomcat有两个核心组件：连接器和容器，其中连接器负责外部交流，容器负责内部处理。具体来说就是，连接器处理Socket通信和应用层协议的解析，得到Servlet请求；而容器则负责处理Servlet请求。我们通过下面这张图来回忆一下。

![](https://static001.geekbang.org/resource/image/ee/d6/ee880033c5ae38125fa91fb3c4f8cad6.jpg?wh=1580%2A836)

容器，顾名思义就是用来装载东西的器具，在Tomcat里，容器就是用来装载Servlet的。那Tomcat的Servlet容器是如何设计的呢？

## 容器的层次结构

Tomcat设计了4种容器，分别是Engine、Host、Context和Wrapper。这4种容器不是平行关系，而是父子关系。下面我画了一张图帮你理解它们的关系。

![](https://static001.geekbang.org/resource/image/cc/ed/cc968a11925591df558da0e7393f06ed.jpg?wh=1172%2A718)

你可能会问，为什么要设计成这么多层次的容器，这不是增加了复杂度吗？其实这背后的考虑是，**Tomcat通过一种分层的架构，使得Servlet容器具有很好的灵活性。**

Context表示一个Web应用程序；Wrapper表示一个Servlet，一个Web应用程序中可能会有多个Servlet；Host代表的是一个虚拟主机，或者说一个站点，可以给Tomcat配置多个虚拟主机地址，而一个虚拟主机下可以部署多个Web应用程序；Engine表示引擎，用来管理多个虚拟站点，一个Service最多只能有一个Engine。

你可以再通过Tomcat的`server.xml`配置文件来加深对Tomcat容器的理解。Tomcat采用了组件化的设计，它的构成组件都是可配置的，其中最外层的是Server，其他组件按照一定的格式要求配置在这个顶层容器中。

![](https://static001.geekbang.org/resource/image/82/66/82b3f97aab5152dd5fe74e947db2a266.jpg?wh=1230%2A578)

那么，Tomcat是怎么管理这些容器的呢？你会发现这些容器具有父子关系，形成一个树形结构，你可能马上就想到了设计模式中的组合模式。没错，Tomcat就是用组合模式来管理这些容器的。具体实现方法是，所有容器组件都实现了Container接口，因此组合模式可以使得用户对单容器对象和组合容器对象的使用具有一致性。这里单容器对象指的是最底层的Wrapper，组合容器对象指的是上面的Context、Host或者Engine。Container接口定义如下：

```
public interface Container extends Lifecycle {
    public void setName(String name);
    public Container getParent();
    public void setParent(Container container);
    public void addChild(Container child);
    public void removeChild(Container child);
    public Container findChild(String name);
}
```

正如我们期望的那样，我们在上面的接口看到了getParent、setParent、addChild和removeChild等方法。你可能还注意到Container接口扩展了Lifecycle接口，Lifecycle接口用来统一管理各组件的生命周期，后面我也用专门的篇幅去详细介绍。

## 请求定位Servlet的过程

你可能好奇，设计了这么多层次的容器，Tomcat是怎么确定请求是由哪个Wrapper容器里的Servlet来处理的呢？答案是，Tomcat是用Mapper组件来完成这个任务的。

Mapper组件的功能就是将用户请求的URL定位到一个Servlet，它的工作原理是：Mapper组件里保存了Web应用的配置信息，其实就是**容器组件与访问路径的映射关系**，比如Host容器里配置的域名、Context容器里的Web应用路径，以及Wrapper容器里Servlet映射的路径，你可以想象这些配置信息就是一个多层次的Map。

当一个请求到来时，Mapper组件通过解析请求URL里的域名和路径，再到自己保存的Map里去查找，就能定位到一个Servlet。请你注意，一个请求URL最后只会定位到一个Wrapper容器，也就是一个Servlet。

读到这里你可能感到有些抽象，接下来我通过一个例子来解释这个定位的过程。

假如有一个网购系统，有面向网站管理人员的后台管理系统，还有面向终端客户的在线购物系统。这两个系统跑在同一个Tomcat上，为了隔离它们的访问域名，配置了两个虚拟域名：`manage.shopping.com`和`user.shopping.com`，网站管理人员通过`manage.shopping.com`域名访问Tomcat去管理用户和商品，而用户管理和商品管理是两个单独的Web应用。终端客户通过`user.shopping.com`域名去搜索商品和下订单，搜索功能和订单管理也是两个独立的Web应用。

针对这样的部署，Tomcat会创建一个Service组件和一个Engine容器组件，在Engine容器下创建两个Host子容器，在每个Host容器下创建两个Context子容器。由于一个Web应用通常有多个Servlet，Tomcat还会在每个Context容器里创建多个Wrapper子容器。每个容器都有对应的访问路径，你可以通过下面这张图来帮助你理解。

![](https://static001.geekbang.org/resource/image/be/96/be22494588ca4f79358347468cd62496.jpg?wh=1564%2A1140)

假如有用户访问一个URL，比如图中的`http://user.shopping.com:8080/order/buy`，Tomcat如何将这个URL定位到一个Servlet呢？

**首先，根据协议和端口号选定Service和Engine。**

我们知道Tomcat的每个连接器都监听不同的端口，比如Tomcat默认的HTTP连接器监听8080端口、默认的AJP连接器监听8009端口。上面例子中的URL访问的是8080端口，因此这个请求会被HTTP连接器接收，而一个连接器是属于一个Service组件的，这样Service组件就确定了。我们还知道一个Service组件里除了有多个连接器，还有一个容器组件，具体来说就是一个Engine容器，因此Service确定了也就意味着Engine也确定了。

**然后，根据域名选定Host。**

Service和Engine确定后，Mapper组件通过URL中的域名去查找相应的Host容器，比如例子中的URL访问的域名是`user.shopping.com`，因此Mapper会找到Host2这个容器。

**之后，根据URL路径找到Context组件。**

Host确定以后，Mapper根据URL的路径来匹配相应的Web应用的路径，比如例子中访问的是`/order`，因此找到了Context4这个Context容器。

**最后，根据URL路径找到Wrapper（Servlet）。**

Context确定后，Mapper再根据`web.xml`中配置的Servlet映射路径来找到具体的Wrapper和Servlet。

看到这里，我想你应该已经了解了什么是容器，以及Tomcat如何通过一层一层的父子容器找到某个Servlet来处理请求。需要注意的是，并不是说只有Servlet才会去处理请求，实际上这个查找路径上的父子容器都会对请求做一些处理。我在上一期说过，连接器中的Adapter会调用容器的Service方法来执行Servlet，最先拿到请求的是Engine容器，Engine容器对请求做一些处理后，会把请求传给自己子容器Host继续处理，依次类推，最后这个请求会传给Wrapper容器，Wrapper会调用最终的Servlet来处理。那么这个调用过程具体是怎么实现的呢？答案是使用Pipeline-Valve管道。

Pipeline-Valve是责任链模式，责任链模式是指在一个请求处理的过程中有很多处理者依次对请求进行处理，每个处理者负责做自己相应的处理，处理完之后将再调用下一个处理者继续处理。

Valve表示一个处理点，比如权限认证和记录日志。如果你还不太理解的话，可以来看看Valve和Pipeline接口中的关键方法。

```
public interface Valve {
  public Valve getNext();
  public void setNext(Valve valve);
  public void invoke(Request request, Response response)
}
```

由于Valve是一个处理点，因此invoke方法就是来处理请求的。注意到Valve中有getNext和setNext方法，因此我们大概可以猜到有一个链表将Valve链起来了。请你继续看Pipeline接口：

```
public interface Pipeline extends Contained {
  public void addValve(Valve valve);
  public Valve getBasic();
  public void setBasic(Valve valve);
  public Valve getFirst();
}
```

没错，Pipeline中有addValve方法。Pipeline中维护了Valve链表，Valve可以插入到Pipeline中，对请求做某些处理。我们还发现Pipeline中没有invoke方法，因为整个调用链的触发是Valve来完成的，Valve完成自己的处理后，调用`getNext.invoke`来触发下一个Valve调用。

每一个容器都有一个Pipeline对象，只要触发这个Pipeline的第一个Valve，这个容器里Pipeline中的Valve就都会被调用到。但是，不同容器的Pipeline是怎么链式触发的呢，比如Engine中Pipeline需要调用下层容器Host中的Pipeline。

这是因为Pipeline中还有个getBasic方法。这个BasicValve处于Valve链表的末端，它是Pipeline中必不可少的一个Valve，负责调用下层容器的Pipeline里的第一个Valve。我还是通过一张图来解释。

![](https://static001.geekbang.org/resource/image/b0/ca/b014ecce1f64b771bd58da62c05162ca.jpg?wh=1550%2A1160)

整个调用过程由连接器中的Adapter触发的，它会调用Engine的第一个Valve：

```
// Calling the container
connector.getService().getContainer().getPipeline().getFirst().invoke(request, response);
```

Wrapper容器的最后一个Valve会创建一个Filter链，并调用doFilter方法，最终会调到Servlet的service方法。

你可能会问，前面我们不是讲到了Filter，似乎也有相似的功能，那Valve和Filter有什么区别吗？它们的区别是：

- Valve是Tomcat的私有机制，与Tomcat的基础架构/API是紧耦合的。Servlet API是公有的标准，所有的Web容器包括Jetty都支持Filter机制。
- 另一个重要的区别是Valve工作在Web容器级别，拦截所有应用的请求；而Servlet Filter工作在应用级别，只能拦截某个Web应用的所有请求。如果想做整个Web容器的拦截器，必须通过Valve来实现。

## 本期精华

今天我们学习了Tomcat容器的层次结构、根据请求定位Servlet的过程，以及请求在容器中的调用过程。Tomcat设计了多层容器是为了灵活性的考虑，灵活性具体体现在一个Tomcat实例（Server）可以有多个Service，每个Service通过多个连接器监听不同的端口，而一个Service又可以支持多个虚拟主机。一个URL网址可以用不同的主机名、不同的端口和不同的路径来访问特定的Servlet实例。

请求的链式调用是基于Pipeline-Valve责任链来完成的，这样的设计使得系统具有良好的可扩展性，如果需要扩展容器本身的功能，只需要增加相应的Valve即可。

## 课后思考

Tomcat内的Context组件跟Servlet规范中的ServletContext接口有什么区别？跟Spring中的ApplicationContext又有什么关系？

不知道今天的内容你消化得如何？如果还有疑问，请大胆的在留言区提问，也欢迎你把你的课后思考和心得记录下来，与我和其他同学一起讨论。如果你觉得今天有所收获，欢迎你把它分享给你的朋友。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>一路远行</span> 👍（229） 💬（9）<p>1）Servlet规范中ServletContext表示web应用的上下文环境，而web应用对应tomcat的概念是Context，所以从设计上，ServletContext自然会成为tomcat的Context具体实现的一个成员变量。

2）tomcat内部实现也是这样完成的，ServletContext对应tomcat实现是org.apache.catalina.core.ApplicationContext，Context容器对应tomcat实现是org.apache.catalina.core.StandardContext。ApplicationContext是StandardContext的一个成员变量。

3）Spring的ApplicationContext之前已经介绍过，tomcat启动过程中ContextLoaderListener会监听到容器初始化事件，它的contextInitialized方法中，Spring会初始化全局的Spring根容器ApplicationContext，初始化完毕后，Spring将其存储到ServletContext中。

总而言之，Servlet规范中ServletContext是tomcat的Context实现的一个成员变量，而Spring的ApplicationContext是Servlet规范中ServletContext的一个属性。</p>2019-05-23</li><br/><li><span>阿旺</span> 👍（75） 💬（4）<p>你好 请问到业务的controller是从哪部分进去的呢 谢谢</p>2019-05-23</li><br/><li><span>发条橙子 。</span> 👍（70） 💬（4）<p>老师 ， 我之前一直误以为一个 server表示我们一个应用(实际上只是代表一个tomcat实例)，所以一直不理解为什么 server 下通过 host 可以配置多个应用 ，学了这节，发现是一个context对应一个应用， 自己百度了一下，原来可以通过 host 或者 service 来让 tomcat 访问不同的目录来访问多个应用 。

1. 但是我看生产环境中， 配的都是一个 tomcat 对应一个应用, 多个应用就用多个tomcat 。  那么他和一个 tomcat 加载多个应用有什么区别么 。难道用一个tomcat是为了节约内存么， 用一个tomcat加载多个应用都有什么弊端呢 ？？ 比如应用的上限 ，希望老师指点一下 。 而且一个tomcat里多个应用的话， 我们就无法用 ps -ef | grep tomcat 来定位到我们的真实应用了。
2. 老师后面讲的， 通过责任链模式， 一步一步解析到 wrapper 的 servlet ， 那不是应该调用servlet 的 doGet()／doPost() 方法了么 ，老师说的创建一个 filter 链，并调用Servlet 的 service 方法， 这句话我不是很理解 </p>2019-05-26</li><br/><li><span>why</span> 👍（60） 💬（4）<p>- 容器的层次结构
    - Engine, Host, Context, Wrapper, 是嵌套关系
    - 一个 Tomcat 实例包含一个 Engine, 一个 Engine 包含多个 Host, 以此类推
    - 容器采用组合模式, 所有容器组件都实现 Container 接口, 保证使用一致性
- 定位 Servlet 的过程
    - 由 Mapper 组件完成, Mapper 组件保存了容器组件与访问路径的映射关系, 根据请求的 URL 进行定位
        - 端口号定位出 Service 和 Engine
        - 域名定位出 Host
        - URL 路径定位出 Context Web 应用
        - URL 路径定位出 Wrapper ( Servlet )
        - 在各个层次定位过程中, 都会对请求做一些处理
    - 通过 Pipeline-Valve 实现容器间的互相调用 ( 责任链模式 )
        - valve 表示一个处理点 ( 如权限认证, 日志等), 处理请求; valve 通过链表串联, 并由 pipeline 维护
        - valve 会通过 getNext().invoke() 调用下一个 valve, 最后一个 valve ( Basic ) 调用下一层容器的 pipeline 的第一个 valve
        - Adapter 调用 Engine pipeline 的第一个 valve
        - Wrapper 最后一个 valve 会创建一个 Filter 链, 并最终调用 Servlet 的 service 方法
    - valve 与 filter 对比
        - valve 是 Tomcat 的私有机制, Filter 是 Servlet API 公有标准
        - valve 工作在容器级别, 拦截所有应用; Servlet Filter 工作在应用级别, 只能拦截某个应用的请求
- 留言

    &gt; Tomcat 的 Context 是一个 Web 应用; Servlet 的 ServletContext 是 Web 应用上下文, 是 Context 的一个成员变量; Spring 的 ApplicationContext 是 spring 容器, 是 Servlet 的一个属性.</p>2019-05-28</li><br/><li><span>yhh</span> 👍（47） 💬（3）<p>Basic value 有些疑惑。比如engine容器下有多个host容器，那engine容器的basic value是怎么知道要指向哪个host容器的value呢？</p>2019-05-24</li><br/><li><span>永光</span> 👍（27） 💬（3）<p>老师您好，
你看这样理解对吗？，一个Engine可以对应多个Host，一个Host下面可以放多个应用。
问题：
1、如果我有两个应用需要部署，现在就可以有很多种方案了。
     部署在同一个service下（同一个Engine）的同一个Host目录下
     部署在同一个service下（同一个Engine）的不同Host目录下
     部署在不同Service下（不同Engine）的各自Host目录下
这几种部署方式有什么差异以及优缺点？以及分别适用于什么场合呀？
谢谢
</p>2019-06-04</li><br/><li><span>而立斋</span> 👍（24） 💬（3）<p>老师，能提供一份tomcat多host的配置吗？</p>2019-05-27</li><br/><li><span>天天向上</span> 👍（18） 💬（1）<p>Connector和Engine是平级的，并且 Connector可以有多个 容器结构图 xml结构表示的有问题吧</p>2019-05-23</li><br/><li><span>一路远行</span> 👍（17） 💬（1）<p>这段话的描述有些不准确：
“首先，根据协议和端口号选定 Service 和 Engine。”

我的理解是，connector配置中只要有端口号就可以确定service和engine，协议的配置只是为了解析，对请求的路由决策没有起到作用。</p>2019-05-23</li><br/><li><span>yang</span> 👍（15） 💬（0）<p>老师，  关于 MapperHost的构造方法  

        public MappedHost(String name, Host host) {
            super(name, host);
            realHost = this;
            contextList = new ContextList();
            aliases = new CopyOnWriteArrayList&lt;&gt;();
        }

不会存在  this泄露吗？

 public volatile ContextList contextList;

contextList 尽管使用volatile修饰的，可以防止编译指令重拍序，并保证可见性。  

但是，它没办法保证 还没构造完，这个new出来的对象，就不被其他线程使用啊？  求老师解答~！</p>2019-06-10</li><br/><li><span>robert_z_zhang</span> 👍（15） 💬（0）<p>老师，filter中没有办法直接使用@autowired的方式注入bean，是因为filter是tomcat管理，bean是spring容器管理，filter先于spring bean初始化，但是为什么在filter的init方法中使用applicationContext.getBean的方式就可以获取了呢，是因为init方法调用的时候，spring容器已经完全初始化了吗？ init方法调用的时机是什么？</p>2019-06-01</li><br/><li><span>Monday</span> 👍（14） 💬（1）<p>老师，tomcat容器的四层架构是一步一步演化过来的还是一步到位的？如果是演化过来的，是哪些故事推动他们如此演化的？谢谢</p>2019-05-24</li><br/><li><span>-W.LI-</span> 👍（14） 💬（1）<p>老师好!Tomcat，server.xml还是搞不太清楚。最外层是server，一个server对应一个Tomcat实例，server下面可以由很多service组件，service组件是区分协议和端口号(问题1:域名访问的话请求到达这里是已经被解析成port了吗？如果已经解析了后面为啥还能拿到二级域名)。每个service对应多个连接器和一个engine。(问题2:为啥要设置多个连接器对应一个engine，是为了提高连接器接受请求的并发吗？)。engine下面对应host，host区分域名(问题3:不同的二级域名对应多个host?)，host下面就是context对应应用通过服务名(webapps下文件夹名区分)（问题4：域名相同路径不同指向不同的服务，是在这配置的么?之前运维同事搞过，原理不太理解），wrapper就是应用程序web.xml中配置的servlet。默认只有一个dispatchservlet。支持对url进行ant风格配置多个。</p>2019-05-23</li><br/><li><span>allean</span> 👍（8） 💬（1）<p>原文：“所有容器都实现了Container接口，因此组合模式可以使得用户对单容器和组合容器的对象使用具有一致性”
问题：这段话不太理解，这里说的一致性是指什么，麻烦老师指明😁
</p>2019-05-23</li><br/><li><span>永光</span> 👍（7） 💬（1）<p>老师你好，你在回答中Pipeline-value这个机制的详细流程是怎样时提到：“在Tomcat启动的时候，这些Valve都已经设置好了。通过addValve方法向Pipeline中添加Valve，最新添加的总是成为’first‘。“
问题：当engine容器下有多个host容器，那engine容器的basic value，在Tomcat启动时是怎么设置Value的？

谢谢
</p>2019-06-05</li><br/>
</ul>