专栏上一期我们分析了JVM GC的基本原理以及监控和分析工具，今天我们接着来聊如何监控Tomcat的各种指标，因为只有我们掌握了这些指标和信息，才能对Tomcat内部发生的事情一目了然，让我们明白系统的瓶颈在哪里，进而做出调优的决策。

在今天的文章里，我们首先来看看到底都需要监控Tomcat哪些关键指标，接着来具体学习如何通过JConsole来监控它们。如果系统没有暴露JMX接口，我们还可以通过命令行来查看Tomcat的性能指标。

Web应用的响应时间是我们关注的一个重点，最后我们通过一个实战案例，来看看Web应用的下游服务响应时间比较长的情况下，Tomcat的各项指标是什么样子的。

## Tomcat的关键指标

Tomcat的关键指标有**吞吐量、响应时间、错误数、线程池、CPU以及JVM内存**。

我来简单介绍一下这些指标背后的意义。其中前三个指标是我们最关心的业务指标，Tomcat作为服务器，就是要能够又快有好地处理请求，因此吞吐量要大、响应时间要短，并且错误数要少。

而后面三个指标是跟系统资源有关的，当某个资源出现瓶颈就会影响前面的业务指标，比如线程池中的线程数量不足会影响吞吐量和响应时间；但是线程数太多会耗费大量CPU，也会影响吞吐量；当内存不足时会触发频繁地GC，耗费CPU，最后也会反映到业务指标上来。

那如何监控这些指标呢？Tomcat可以通过JMX将上述指标暴露出来的。JMX（Java Management Extensions，即Java管理扩展）是一个为应用程序、设备、系统等植入监控管理功能的框架。JMX使用管理MBean来监控业务资源，这些MBean在JMX MBean服务器上注册，代表JVM中运行的应用程序或服务。每个MBean都有一个属性列表。JMX客户端可以连接到MBean Server来读写MBean的属性值。你可以通过下面这张图来理解一下JMX的工作原理：

![](https://static001.geekbang.org/resource/image/71/6b/714fa2e12380122599be077c10375a6b.png?wh=579%2A351)

Tomcat定义了一系列MBean来对外暴露系统状态，接下来我们来看看如何通过JConsole来监控这些指标。

## 通过JConsole监控Tomcat

首先我们需要开启JMX的远程监听端口，具体来说就是设置若干JVM参数。我们可以在Tomcat的bin目录下新建一个名为`setenv.sh`的文件（或者`setenv.bat`，根据你的操作系统类型），然后输入下面的内容：

```
export JAVA_OPTS="${JAVA_OPTS} -Dcom.sun.management.jmxremote"
export JAVA_OPTS="${JAVA_OPTS} -Dcom.sun.management.jmxremote.port=9001"
export JAVA_OPTS="${JAVA_OPTS} -Djava.rmi.server.hostname=x.x.x.x"
export JAVA_OPTS="${JAVA_OPTS} -Dcom.sun.management.jmxremote.ssl=false"
export JAVA_OPTS="${JAVA_OPTS} -Dcom.sun.management.jmxremote.authenticate=false"
```

重启Tomcat，这样JMX的监听端口9001就开启了，接下来通过JConsole来连接这个端口。

```
jconsole x.x.x.x:9001
```

我们可以看到JConsole的主界面：

![](https://static001.geekbang.org/resource/image/80/d7/80f14c4bd4eead05f4d84937ed7726d7.png?wh=899%2A753)

前面我提到的需要监控的关键指标有**吞吐量、响应时间、错误数、线程池、CPU以及JVM内存**，接下来我们就来看看怎么在JConsole上找到这些指标。

**吞吐量、响应时间、错误数**

在MBeans标签页下选择GlobalRequestProcessor，这里有Tomcat请求处理的统计信息。你会看到Tomcat中的各种连接器，展开“http-nio-8080”，你会看到这个连接器上的统计信息，其中maxTime表示最长的响应时间，processingTime表示平均响应时间，requestCount表示吞吐量，errorCount就是错误数。

![](https://static001.geekbang.org/resource/image/ff/9c/ff0a9163fbeeed8eb84ed89c3f71799c.png?wh=862%2A420)

**线程池**

选择“线程”标签页，可以看到当前Tomcat进程中有多少线程，如下图所示：

![](https://static001.geekbang.org/resource/image/78/b8/78858a3264107e1f1a0b6a78d43113b8.png?wh=855%2A635)

图的左下方是线程列表，右边是线程的运行栈，这些都是非常有用的信息。如果大量线程阻塞，通过观察线程栈，能看到线程阻塞在哪个函数，有可能是I/O等待，或者是死锁。

**CPU**

在主界面可以找到CPU使用率指标，请注意这里的CPU使用率指的是Tomcat进程占用的CPU，不是主机总的CPU使用率。

![](https://static001.geekbang.org/resource/image/1b/9f/1bb88cc3d5f2b9a80377a29b0b80e19f.png?wh=421%2A282)

**JVM内存**

选择“内存”标签页，你能看到Tomcat进程的JVM内存使用情况。

![](https://static001.geekbang.org/resource/image/f2/02/f22eca547ca76eb5edba03b39082fa02.png?wh=891%2A714)

你还可以查看JVM各内存区域的使用情况，大的层面分堆区和非堆区。堆区里有分为Eden、Survivor和Old。选择“VM Summary”标签，可以看到虚拟机内的详细信息。

![](https://static001.geekbang.org/resource/image/cc/a0/cc91bb5b7b8d8b0b46dad946617b01a0.png?wh=868%2A489)

## 命令行查看Tomcat指标

极端情况下如果Web应用占用过多CPU或者内存，又或者程序中发生了死锁，导致Web应用对外没有响应，监控系统上看不到数据，这个时候需要我们登陆到目标机器，通过命令行来查看各种指标。

1.首先我们通过ps命令找到Tomcat进程，拿到进程ID。

![](https://static001.geekbang.org/resource/image/84/9a/8477832ebe079cf92e3cd58766754e9a.png?wh=709%2A29)

2.接着查看进程状态的大致信息，通过`cat/proc/<pid>/status`命令：

![](https://static001.geekbang.org/resource/image/d8/b3/d812ac93be2ac882e689f77e5d8e12b3.png?wh=418%2A799)

3.监控进程的CPU和内存资源使用情况：

![](https://static001.geekbang.org/resource/image/6e/d6/6e7e0730e92e3d8846f37ea8a14973d6.png?wh=883%2A239)

4.查看Tomcat的网络连接，比如Tomcat在8080端口上监听连接请求，通过下面的命令查看连接列表：

![](https://static001.geekbang.org/resource/image/14/61/14ba365d585f0ec79543efc1a9b32961.png?wh=887%2A257)

你还可以分别统计处在“已连接”状态和“TIME\_WAIT”状态的连接数：

![](https://static001.geekbang.org/resource/image/aa/2c/aaab0fb1156bb8ec92ee6c02b149cf2c.jpg?wh=936%2A180)

5.通过ifstat来查看网络流量，大致可以看出Tomcat当前的请求数和负载状况。

![](https://static001.geekbang.org/resource/image/67/b2/67a9a29b8bf071152ccc1bc108adc4b2.png?wh=216%2A176)

## 实战案例

在这个实战案例中，我们会创建一个Web应用，根据传入的参数latency来休眠相应的秒数，目的是模拟当前的Web应用在访问下游服务时遇到的延迟。然后用JMeter来压测这个服务，通过JConsole来观察Tomcat的各项指标，分析和定位问题。

主要的步骤有：

1.创建一个Spring Boot程序，加入下面代码所示的一个RestController：

```
@RestController
public class DownStreamLatency {

    @RequestMapping("/greeting/latency/{seconds}")
    public Greeting greeting(@PathVariable long seconds) {

        try {
            Thread.sleep(seconds * 1000);
        } catch (InterruptedException e) {
            e.printStackTrace();
        }

        Greeting greeting = new Greeting("Hello World!");

        return greeting;
    }
}
```

从上面的代码我们看到，程序会读取URL传过来的seconds参数，先休眠相应的秒数，再返回请求。这样做的目的是，客户端压测工具能够控制服务端的延迟。

为了方便观察Tomcat的线程数跟延迟之间的关系，还需要加大Tomcat的最大线程数，我们可以在`application.properties`文件中加入这样一行：

```
server.tomcat.max-threads=1000server.tomcat.max-threads=1000
```

2.启动JMeter开始压测，这里我们将压测的线程数设置为100：

![](https://static001.geekbang.org/resource/image/89/51/895c7c986d0c86b0a869a604c9c6af51.png?wh=1057%2A410)

请你注意的是，我们还需要将客户端的Timeout设置为1000毫秒，这是因为JMeter的测试线程在收到响应之前，不会发出下一次请求，这就意味我们没法按照固定的吞吐量向服务端加压。而加了Timeout以后，JMeter会有固定的吞吐量向Tomcat发送请求。

![](https://static001.geekbang.org/resource/image/3e/a5/3e275c10132680995ac83460f29a1aa5.png?wh=1291%2A396)

3.开启测试，这里分三个阶段，第一个阶段将服务端休眠时间设为2秒，然后暂停一段时间。第二和第三阶段分别将休眠时间设置成4秒和6秒。

![](https://static001.geekbang.org/resource/image/8b/0d/8b071d99cbf8875c138f14bd17f0ed0d.png?wh=1428%2A236)

4.最后我们通过JConsole来观察结果：

![](https://static001.geekbang.org/resource/image/dd/b3/ddb8609042469ee73ddc3fb68f676eb3.png?wh=1331%2A690)

下面我们从线程数、内存和CPU这三个指标来分析Tomcat的性能问题。

- 首先看线程数，在第一阶段时间之前，线程数大概是40，第一阶段压测开始后，线程数增长到250。为什么是250呢？这是因为JMeter每秒会发出100个请求，每一个请求休眠2秒，因此Tomcat需要200个工作线程来干活；此外Tomcat还有一些其他线程用来处理网络通信和后台任务，所以总数是250左右。第一阶段压测暂停后，线程数又下降到40，这是因为线程池会回收空闲线程。第二阶段测试开始后，线程数涨到了420，这是因为每个请求休眠了4秒；同理，我们看到第三阶段测试的线程数是620。
- 我们再来看CPU，在三个阶段的测试中，CPU的峰值始终比较稳定，这是因为JMeter控制了总体的吞吐量，因为服务端用来处理这些请求所需要消耗的CPU基本也是一样的。
- 各测试阶段的内存使用量略有增加，这是因为线程数增加了，创建线程也需要消耗内存。

从上面的测试结果我们可以得出一个结论：对于一个Web应用来说，下游服务的延迟越大，Tomcat所需要的线程数越多，但是CPU保持稳定。所以如果你在实际工作碰到线程数飙升但是CPU没有增加的情况，这个时候你需要怀疑，你的Web应用所依赖的下游服务是不是出了问题，响应时间是否变长了。

## 本期精华

今天我们学习了Tomcat中的关键的性能指标以及如何监控这些指标：主要有**吞吐量、响应时间、错误数、线程池、CPU以及JVM内存。**

在实际工作中，我们需要通过观察这些指标来诊断系统遇到的性能问题，找到性能瓶颈。如果我们监控到CPU上升，这时我们可以看看吞吐量是不是也上升了，如果是那说明正常；如果不是的话，可以看看GC的活动，如果GC活动频繁，并且内存居高不下，基本可以断定是内存泄漏。

## 课后思考

请问工作中你如何监控Web应用的健康状态？遇到性能问题的时候是如何做问题定位的呢？

不知道今天的内容你消化得如何？如果还有疑问，请大胆的在留言区提问，也欢迎你把你的课后思考和心得记录下来，与我和其他同学一起讨论。如果你觉得今天有所收获，欢迎你把它分享给你的朋友。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>陆离</span> 👍（18） 💬（4）<p>老师，不是很明白线程sleep时间越长，为什么tomcat启动的线程就越多</p>2019-08-01</li><br/><li><span>dingdongfm</span> 👍（9） 💬（1）<p>请教一个细节，Timeout 设置为 1000 毫秒，接口延迟4S，那么ERROR不是100%么？</p>2019-09-29</li><br/><li><span>-W.LI-</span> 👍（5） 💬（1）<p>李老师好。
第二三阶段，有很多TIME_WAIT状态的线程。可是CPU使用率并没有增加很多。老师说CPU使用率和吞吐量有关，吞吐量由JMETER控制一直没变。频繁线程切换会消耗很多CPU支援，如果只是阻塞，切换不频繁。对CPU使用率还是比较小的是么?</p>2019-08-01</li><br/><li><span>Geek_ebda96</span> 👍（3） 💬（1）<p>老师请问一下，windows机器上用jconsole工具，不能看到tomcat的进程，是什么原因</p>2019-08-13</li><br/><li><span>尔东橙</span> 👍（2） 💬（3）<p>内存泄露的原因是什么呢？代码写的有问题？</p>2019-08-16</li><br/><li><span>Geek_28b75e</span> 👍（1） 💬（1）<p>老师，通过监控工具看到了有哪些线程，但是发现有些线程大部分都在等待，怎么找到这些线程创建位置，进而调整线程池初始化大小？</p>2019-08-07</li><br/><li><span>许童童</span> 👍（29） 💬（1）<p>使用prometheus + grafana 监控各种指标，每天上班前看一下昨天的情况，设置好阈值，如果达到就报警。</p>2019-08-01</li><br/><li><span>nightmare</span> 👍（10） 💬（2）<p>先查看日志，那些方法耗时较大，用阿里爸爸开源arthas监控有问题的方法，排查问题</p>2019-08-01</li><br/><li><span>仙道</span> 👍（9） 💬（0）<p>如果这样类型的内容能够再深入点、再广一点就好了。因为作为普通开发，很难有机会接触到这方面的知识，也无从学起</p>2019-09-27</li><br/><li><span>Geek_28b75e</span> 👍（4） 💬（4）<p>老师，springboot内嵌tomcat怎么使用jmx? 
</p>2019-08-07</li><br/><li><span>despacito</span> 👍（2） 💬（1）<p>文中提到的上下游服务概念有问题吧，服务的提供方是上游，调用别人的服务是调用上游服务</p>2021-02-26</li><br/><li><span>旭东(Frank)</span> 👍（2） 💬（1）<p>文中线程数的配置是否重复了</p>2019-08-09</li><br/><li><span>a、</span> 👍（2） 💬（0）<p>监控系统会每隔一段时间，ping下我们系统，我们系统会pong回监控系统，并带上ip地址，jvm当前使用率，cpu使用率等信息，如果超过一定数值，监控系统就会发出预警信息，我们就需要去生产管理通过日志和命令查看，到底出了什么问题。</p>2019-08-01</li><br/><li><span>| ~浑蛋~</span> 👍（1） 💬（0）<p>为啥不是上游服务器，NGINX的都叫upstream</p>2022-08-02</li><br/><li><span>费城的二鹏</span> 👍（1） 💬（0）<p>老师，jmeter压测30线程，发现接口95%的请求返回是50ms内，其余请求会达到170ms，如何监控这些延迟的请求做了什么导致缓慢。</p>2020-05-14</li><br/>
</ul>