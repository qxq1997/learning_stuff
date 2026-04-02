作为专栏最后一个模块的答疑文章，我想是时候总结一下Tomcat和Jetty的区别了。专栏里也有同学给我留言，询问有关Tomcat和Jetty在系统选型时需要考虑的地方，今天我也会通过一个实战案例来比较一下Tomcat和Jetty在实际场景下的表现，帮你在做选型时有更深的理解。

我先来概括一下Tomcat和Jetty两者最大的区别。大体来说，Tomcat的核心竞争力是**成熟稳定**，因为它经过了多年的市场考验，应用也相当广泛，对于比较复杂的企业级应用支持得更加全面。也因为如此，Tomcat在整体结构上比Jetty更加复杂，功能扩展方面可能不如Jetty那么方便。

而Jetty比较年轻，设计上更加**简洁小巧**，配置也比较简单，功能也支持方便地扩展和裁剪，比如我们可以把Jetty的SessionHandler去掉，以节省内存资源，因此Jetty还可以运行在小型的嵌入式设备中，比如手机和机顶盒。当然，我们也可以自己开发一个Handler，加入Handler链中用来扩展Jetty的功能。值得一提的是，Hadoop和Solr都嵌入了Jetty作为Web服务器。

从设计的角度来看，Tomcat的架构基于一种多级容器的模式，这些容器组件具有父子关系，所有组件依附于这个骨架，而且这个骨架是不变的，我们在扩展Tomcat的功能时也需要基于这个骨架，因此Tomcat在设计上相对来说比较复杂。当然Tomcat也提供了较好的扩展机制，比如我们可以自定义一个Valve，但相对来说学习成本还是比较大的。而Jetty采用Handler责任链模式。由于Handler之间的关系比较松散，Jetty提供HandlerCollection可以帮助开发者方便地构建一个Handler链，同时也提供了ScopeHandler帮助开发者控制Handler链的访问顺序。关于这部分内容，你可以回忆一下专栏里讲的回溯方式的责任链模式。

说了一堆理论，你可能觉得还是有点抽象，接下来我们通过一个实例，来压测一下Tomcat和Jetty，看看在同等流量压力下，Tomcat和Jetty分别表现如何。需要说明的是，通常我们从吞吐量、延迟和错误率这三个方面来比较结果。

测试的计划是这样的，我们还是用[专栏第36期](http://time.geekbang.org/column/article/112271)中的Spring Boot应用程序。首先用Spring Boot默认的Tomcat作为内嵌式Web容器，经过一轮压测后，将内嵌式的Web容器换成Jetty，再做一轮测试，然后比较结果。为了方便观察各种指标，我在本地开发机器上做这个实验。

我们会在每个请求的处理过程中休眠1秒，适当地模拟Web应用的I/O等待时间。JMeter客户端的线程数为100，压测持续10分钟。在JMeter中创建一个Summary Report，在这个页面上，可以看到各种统计指标。

![](https://static001.geekbang.org/resource/image/88/b6/888ff5dc207d7bc746663c2be2d3dbb6.png?wh=1911%2A235)

第一步，压测Tomcat。启动Spring Boot程序和JMeter，持续10分钟，以下是测试结果，结果分为两部分：

**吞吐量、延迟和错误率**

![](https://static001.geekbang.org/resource/image/eb/c9/eb8f119a6106da2ada200a86436df8c9.png?wh=1455%2A224)

**资源使用情况**

![](https://static001.geekbang.org/resource/image/8a/c6/8ad606fd374a375ccedae71c5eaadcc6.png?wh=1149%2A650)

第二步，我们将Spring Boot的Web容器替换成Jetty，具体步骤是在pom.xml文件中的spring-boot-starter-web依赖修改下面这样：

```
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-web</artifactId>
    <exclusions>
        <exclusion>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-tomcat</artifactId>
        </exclusion>
    </exclusions>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-jetty</artifactId>
</dependency>
```

编译打包，启动Spring Boot，再启动JMeter压测，以下是测试结果：

**吞吐量、延迟和错误率**

![](https://static001.geekbang.org/resource/image/16/c6/1613eca65656b08e467eae63238252c6.png?wh=1474%2A242)

**资源使用情况**

![](https://static001.geekbang.org/resource/image/60/9f/6039f999094dd390bb7a60ec63c5b19f.png?wh=1148%2A647)

下面我们通过一个表格来对比Tomcat和Jetty：

![](https://static001.geekbang.org/resource/image/82/4f/824b67dbdb1cd7205427ab67a3ab864f.jpg?wh=1248%2A272)

从表格中的数据我们可以看到：

- **Jetty在吞吐量和响应速度方面稍有优势，并且Jetty消耗的线程和内存资源明显比Tomcat要少，这也恰好说明了Jetty在设计上更加小巧和轻量级的特点。**
- **但是Jetty有2.45%的错误率，而Tomcat没有任何错误，并且我经过多次测试都是这个结果。因此我们可以认为Tomcat比Jetty更加成熟和稳定。**

当然由于测试场景的限制，以上数据并不能完全反映Tomcat和Jetty的真实能力。但是它可以在我们做选型的时候提供一些参考：如果系统的目标是资源消耗尽量少，并且对稳定性要求没有那么高，可以选择轻量级的Jetty；如果你的系统是比较关键的企业级应用，建议还是选择Tomcat比较稳妥。

最后用一句话总结Tomcat和Jetty的区别：**Tomcat好比是一位工作多年比较成熟的工程师，轻易不会出错、不会掉链子，但是他有自己的想法，不会轻易做出改变。而Jetty更像是一位年轻的后起之秀，脑子转得很快，可塑性也很强，但有时候也会犯一点小错误。**

不知道今天的内容你消化得如何？如果还有疑问，请大胆的在留言区提问，也欢迎你把你的课后思考和心得记录下来，与我和其他同学一起讨论。如果你觉得今天有所收获，欢迎你把它分享给你的朋友。
<div><strong>精选留言（12）</strong></div><ul>
<li><span>undefined</span> 👍（7） 💬（0）<p>jetty 那 2% 的错误主要是什么导致的哈？</p>2021-04-08</li><br/><li><span>chun1123</span> 👍（7） 💬（0）<p>同样意犹未尽！</p>2019-08-15</li><br/><li><span>完美世界</span> 👍（3） 💬（0）<p>jetty 吞吐量高，适合做网关。tomcat成熟稳定，更适合做核心应用。
springboot 内置了三个容器：1.undertow;2.jetty;3.tomcat。默认的是tomcat。
详细对比可以参考：https:&#47;&#47;examples.javacodegeeks.com&#47;enterprise-java&#47;spring&#47;tomcat-vs-jetty-vs-undertow-comparison-of-spring-boot-embedded-servlet-containers
</p>2019-09-17</li><br/><li><span>任鹏斌</span> 👍（2） 💬（0）<p>第一遍读完了打算开始第二遍细细品味</p>2019-12-18</li><br/><li><span>Zzz</span> 👍（1） 💬（0）<p>这门课是一个宝藏!</p>2020-07-19</li><br/><li><span>许童童</span> 👍（1） 💬（0）<p>这篇文章有点短，没学够的感觉。</p>2019-08-15</li><br/><li><span>QQ怪</span> 👍（1） 💬（0）<p>学的意犹未尽</p>2019-08-15</li><br/><li><span>托尼斯威特</span> 👍（0） 💬（0）<p>Jetty ErrorRate&gt;0的原因是什么? 是因为有些请求分配不到线程所以超时了吗？</p>2020-08-31</li><br/><li><span>小熊</span> 👍（0） 💬（0）<p>最后的示例很形象，哈哈</p>2020-05-03</li><br/><li><span>wakaka</span> 👍（0） 💬（0）<p>为啥选择100个线程模拟客户端请求呢？对于本地单机压测，这个数值是高还是低呢？</p>2020-04-28</li><br/><li><span>Demon.Lee</span> 👍（0） 💬（0）<p>一刷结束，我还会回来的，我要先去把基础的书学习一遍。另外，我也学习课程的时候在提了些问题，老师基本都没回复。我现在想想，之前因项目要用tomcat，一些东西不懂，时间紧张，问题提的都不是好问题，老师都不用回了，我会自己去思考。谢谢老师！</p>2020-03-22</li><br/><li><span>妥协</span> 👍（0） 💬（0）<p>阅读tomcat源码，有个地方不明白，NioEndpoint在处理感兴趣的IO事件时，在processKey函数中，调用了unreg(sk, attachment, sk.readyOps()); 这个不是在selector上取消了感兴趣感兴趣的事件吗？为何要这么处理？？tomcat源码版本8.5.38</p>2019-10-12</li><br/>
</ul>