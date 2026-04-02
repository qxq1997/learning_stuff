和Web应用程序一样，Tomcat作为一个Java程序也跑在JVM中，因此如果我们要对Tomcat进行调优，需要先了解JVM调优的原理。而对于JVM调优来说，主要是JVM垃圾收集的优化，一般来说是因为有问题才需要优化，所以对于JVM GC来说，如果你观察到Tomcat进程的CPU使用率比较高，并且在GC日志中发现GC次数比较频繁、GC停顿时间长，这表明你需要对GC进行优化了。

在对GC调优的过程中，我们不仅需要知道GC的原理，更重要的是要熟练使用各种监控和分析工具，具备GC调优的实战能力。CMS和G1是时下使用率比较高的两款垃圾收集器，从Java 9开始，采用G1作为默认垃圾收集器，而G1的目标也是逐步取代CMS。所以今天我们先来简单回顾一下两种垃圾收集器CMS和G1的区别，接着通过一个例子帮你提高GC调优的实战能力。

## CMS vs G1

CMS收集器将Java堆分为**年轻代**（Young）或**年老代**（Old）。这主要是因为有研究表明，超过90％的对象在第一次GC时就被回收掉，但是少数对象往往会存活较长的时间。

CMS还将年轻代内存空间分为**幸存者空间**（Survivor）和**伊甸园空间**（Eden）。新的对象始终在Eden空间上创建。一旦一个对象在一次垃圾收集后还幸存，就会被移动到幸存者空间。当一个对象在多次垃圾收集之后还存活时，它会移动到年老代。这样做的目的是在年轻代和年老代采用不同的收集算法，以达到较高的收集效率，比如在年轻代采用复制-整理算法，在年老代采用标记-清理算法。因此CMS将Java堆分成如下区域：

![](https://static001.geekbang.org/resource/image/8a/7a/8a4e63a4dc5c7f1c0ba19afd748aee7a.png?wh=736%2A115)

与CMS相比，G1收集器有两大特点：

- G1可以并发完成大部分GC的工作，这期间不会“Stop-The-World”。
- G1使用**非连续空间**，这使G1能够有效地处理非常大的堆。此外，G1可以同时收集年轻代和年老代。G1并没有将Java堆分成三个空间（Eden、Survivor和Old），而是将堆分成许多（通常是几百个）非常小的区域。这些区域是固定大小的（默认情况下大约为2MB）。每个区域都分配给一个空间。 G1收集器的Java堆如下图所示：

![](https://static001.geekbang.org/resource/image/14/9e/14fed64d57fc1e56bdcd472440444d9e.png?wh=718%2A106)

图上的U表示“未分配”区域。G1将堆拆分成小的区域，一个最大的好处是可以做局部区域的垃圾回收，而不需要每次都回收整个区域比如年轻代和年老代，这样回收的停顿时间会比较短。具体的收集过程是：

- 将所有存活的对象将从**收集的区域**复制到**未分配的区域**，比如收集的区域是Eden空间，把Eden中的存活对象复制到未分配区域，这个未分配区域就成了Survivor空间。理想情况下，如果一个区域全是垃圾（意味着一个存活的对象都没有），则可以直接将该区域声明为“未分配”。
- 为了优化收集时间，G1总是优先选择垃圾最多的区域，从而最大限度地减少后续分配和释放堆空间所需的工作量。这也是G1收集器名字的由来——Garbage-First。

## GC调优原则

GC是有代价的，因此我们调优的根本原则是**每一次GC都回收尽可能多的对象**，也就是减少无用功。因此我们在做具体调优的时候，针对CMS和G1两种垃圾收集器，分别有一些相应的策略。

**CMS收集器**

对于CMS收集器来说，最重要的是**合理地设置年轻代和年老代的大小**。年轻代太小的话，会导致频繁的Minor GC，并且很有可能存活期短的对象也不能被回收，GC的效率就不高。而年老代太小的话，容纳不下从年轻代过来的新对象，会频繁触发单线程Full GC，导致较长时间的GC暂停，影响Web应用的响应时间。

**G1收集器**

对于G1收集器来说，我不推荐直接设置年轻代的大小，这一点跟CMS收集器不一样，这是因为G1收集器会根据算法动态决定年轻代和年老代的大小。因此对于G1收集器，我们需要关心的是Java堆的总大小（`-Xmx`）。

此外G1还有一个较关键的参数是`-XX:MaxGCPauseMillis = n`，这个参数是用来限制最大的GC暂停时间，目的是尽量不影响请求处理的响应时间。G1将根据先前收集的信息以及检测到的垃圾量，估计它可以立即收集的最大区域数量，从而尽量保证GC时间不会超出这个限制。因此G1相对来说更加“智能”，使用起来更加简单。

## 内存调优实战

下面我通过一个例子实战一下Java堆设置得过小，导致频繁的GC，我们将通过GC日志分析工具来观察GC活动并定位问题。

1.首先我们建立一个Spring Boot程序，作为我们的调优对象，代码如下：

```
@RestController
public class GcTestController {

    private Queue<Greeting> objCache =  new ConcurrentLinkedDeque<>();

    @RequestMapping("/greeting")
    public Greeting greeting() {
        Greeting greeting = new Greeting("Hello World!");

        if (objCache.size() >= 200000) {
            objCache.clear();
        } else {
            objCache.add(greeting);
        }
        return greeting;
    }
}

@Data
@AllArgsConstructor
class Greeting {
   private String message;
}
```

上面的代码就是创建了一个对象池，当对象池中的对象数到达200000时才清空一次，用来模拟年老代对象。

2.用下面的命令启动测试程序：

```
java -Xmx32m -Xss256k -verbosegc -Xlog:gc*,gc+ref=debug,gc+heap=debug,gc+age=trace:file=gc-%p-%t.log:tags,uptime,time,level:filecount=2,filesize=100m -jar target/demo-0.0.1-SNAPSHOT.jar
```

我给程序设置的堆的大小为32MB，目的是能让我们看到Full GC。除此之外，我还打开了verbosegc日志，请注意这里我使用的版本是Java 12，默认的垃圾收集器是G1。

3.使用JMeter压测工具向程序发送测试请求，访问的路径是`/greeting`。

![](https://static001.geekbang.org/resource/image/bd/85/bd3a55b83f85b3c6a050cbe7aa288485.png?wh=1512%2A336)

4.使用GCViewer工具打开GC日志，我们可以看到这样的图：

![](https://static001.geekbang.org/resource/image/7a/a2/7aab9535570082e1dd19c158012e05a2.png?wh=1366%2A687)

我来解释一下这张图：

- 图中上部的蓝线表示已使用堆的大小，我们看到它周期的上下震荡，这是我们的对象池要扩展到200000才会清空。
- 图底部的绿线表示年轻代GC活动，从图上看到当堆的使用率上去了，会触发频繁的GC活动。
- 图中的竖线表示Full GC，从图上看到，伴随着Full GC，蓝线会下降，这说明Full GC收集了年老代中的对象。

基于上面的分析，我们可以得出一个结论，那就是Java堆的大小不够。我来解释一下为什么得出这个结论：

- GC活动频繁：年轻代GC（绿色线）和年老代GC（黑色线）都比较密集。这说明内存空间不够，也就是Java堆的大小不够。
- Java的堆中对象在GC之后能够被回收，说明不是内存泄漏。

我们通过GCViewer还发现累计GC暂停时间有55.57秒，如下图所示：

![](https://static001.geekbang.org/resource/image/2a/06/2a0dddc7e9fc5c61339e5d515c449806.png?wh=426%2A362)

因此我们的解决方案是调大Java堆的大小，像下面这样：

```
java -Xmx2048m -Xss256k -verbosegc -Xlog:gc*,gc+ref=debug,gc+heap=debug,gc+age=trace:file=gc-%p-%t.log:tags,uptime,time,level:filecount=2,filesize=100m -jar target/demo-0.0.1-SNAPSHOT.jar
```

生成的新的GC log分析图如下：

![](https://static001.geekbang.org/resource/image/30/99/3027354c1ae0b359dab025c53b297599.png?wh=1457%2A368)

你可以看到，没有发生Full GC，并且年轻代GC也没有那么频繁了，并且累计GC暂停时间只有3.05秒。

![](https://static001.geekbang.org/resource/image/9f/1b/9f1b3655cebf6e8f40148dfa6d6c111b.png?wh=421%2A403)

## 本期精华

今天我们首先回顾了CMS和G1两种垃圾收集器背后的设计思路以及它们的区别，接着分析了GC调优的总体原则。

对于CMS来说，我们要合理设置年轻代和年老代的大小。你可能会问该如何确定它们的大小呢？这是一个迭代的过程，可以先采用JVM的默认值，然后通过压测分析GC日志。

如果我们看年轻代的内存使用率处在高位，导致频繁的Minor GC，而频繁GC的效率又不高，说明对象没那么快能被回收，这时年轻代可以适当调大一点。

如果我们看年老代的内存使用率处在高位，导致频繁的Full GC，这样分两种情况：如果每次Full GC后年老代的内存占用率没有下来，可以怀疑是内存泄漏；如果Full GC后年老代的内存占用率下来了，说明不是内存泄漏，我们要考虑调大年老代。

对于G1收集器来说，我们可以适当调大Java堆，因为G1收集器采用了局部区域收集策略，单次垃圾收集的时间可控，可以管理较大的Java堆。

## 课后思考

如果把年轻代和年老代都设置得很大，会有什么问题？

不知道今天的内容你消化得如何？如果还有疑问，请大胆的在留言区提问，也欢迎你把你的课后思考和心得记录下来，与我和其他同学一起讨论。如果你觉得今天有所收获，欢迎你把它分享给你的朋友。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>新世界</span> 👍（30） 💬（3）<p>设置过大，回收频率会降低，导致单次回收时间过长，因为需要回收的对象更多，导致GC stop the world时间过长，卡顿明显，导致请求无法及时处理</p>2019-07-30</li><br/><li><span>-W.LI-</span> 👍（14） 💬（5）<p>李老师好!感觉老师今天偷懒了，CMS负责老年代回收，年轻代一般配合parNew使用。
大概啥情况下使用G1比较好啊?之前看见网上说，大堆多核，jdk9以及以上可以使用G1，jdk8的话除非cms满足不了需求不然不建议使用G1。
G1不太了解老师能推荐下资料么?
我觉得工具，可以提高效率，初学者优先搞清楚原理扎实基础比较好。</p>2019-07-30</li><br/><li><span>弃</span> 👍（2） 💬（1）<p>老师，我想问个问题:在docker中运行的springboot(使用默认的tomcat容器)，如何查看tomcat的gc日志?</p>2019-07-30</li><br/><li><span>Wyatt</span> 👍（1） 💬（2）<p>
执行命令：java -Xmx2048m -Xss256k -verbosegc -Xlog:gc*,gc+ref=debug,gc+heap=debug,gc+age=trace:file=gc-%p-%t.log:tags,uptime,time,level:filecount=2,filesize=100m -jar target&#47;demo-0.0.1-SNAPSHOT.jar
java -Xmx2048m -Xss256k -verbosegc -Xlog:gc*,gc+ref=debug,gc+heap=debug,gc+age=trace:file=gc-%p-%t.log:tags,uptime,time,level:filecount=2,filesize=100m -jar target&#47;demo-0.0.1-SNAPSHOT.jar
报错：
Unrecognized option: -Xlog:gc*,gc+ref=debug,gc+heap=debug,gc+age=trace:file=gc-%p-%t.log:tags,uptime,time,level:filecount=2,filesize=100m
</p>2019-08-01</li><br/><li><span>锦</span> 👍（0） 💬（3）<p>对于CMS来说，设置很大的堆内存，在导致单次STW时间长，会导致服务不可用，定时器出问题？对响应敏感的系统来说不太友好，但堆内存设置太小又会导致频道GC，所以需要综合评估。那么如何使用超大机器内存呢？可以使用集群方式部署，单个应用设置较小的堆内存。
对于G1来说，文中有提到可以设置较大内存，因为G1是局部收集，但极端情况下，区域之间的对象引用关系非常多，也会导致大面积回收，STW时间会较长。
目前Java8使用CMS的较多，那么G1普及可能还需要时间吗？</p>2019-07-30</li><br/><li><span>-W.LI-</span> 👍（45） 💬（0）<p>年轻代设置过大:
1.生命周期长的对象会长时间停留在年轻代，在S0和S1来回复制，增加复制开销。
2.年轻代太大会增加YGC每次停顿的时间，不过通过根节点遍历，OopMap，old scan等优化手段这一部分的开销其实比较少。
3.浪费内存。内存也是钱啊虽然现在租的很便宜
老年代设置过大:
1.降低FGC频率，有些堆外内存比如直接内存，需要靠FGC辅佐回收的，就会无法释放。万一剩余的堆外内存不够程序也会宕机的吧
2.单次FGC时间变长，如果在夜深人静的时候主动触发FGC内啥影响，如果白天业务繁忙的时候就凉凉
3.增加YGC的时间，old scan阶段会扫描老年代，而且这个阶段耗时在YGC总比重很大。

最好别让太多老年代对象引用年轻代对象，这个坑很痛。</p>2019-07-30</li><br/><li><span>业余草</span> 👍（6） 💬（0）<p>需要实际操作一遍，光看是记不住的，过一段时间就忘记了。</p>2019-07-30</li><br/><li><span>nightmare</span> 👍（5） 💬（0）<p>分情况，如果是G1大年轻代和大老年代没什么问题    如果是cms parnew的话  也需要看情况  如果你的并发比较大并且很快占满eden区  或者 用jstat监控 supervisor区占比一直高于百分之70这个时候 这个时候加大新生代就没有什么问题   如果要很久才占满eden区 或者supervisor区占比比较小 这个时候就要把 新生代 设置小一点 减少新生代回收时间            老年代也要看年轻代晋升到老年代平均占多大  如果晋升很快并且对象占比较大 大一点没问题  否则就需要减少老年代</p>2019-07-30</li><br/><li><span>QQ怪</span> 👍（3） 💬（0）<p>设置过大回收频率降低，单次回收的对象量大，回收stw时间过长，设置大也不好，过小也不好，设置适合的才是最好的</p>2019-07-30</li><br/><li><span>James</span> 👍（1） 💬（0）<p>一句话：纸上谈兵终觉浅 绝知此事要躬行</p>2021-03-27</li><br/><li><span>maybe</span> 👍（1） 💬（0）<p>1、cms把堆分为老年代、年轻代。年轻代又细分为幸存区和伊甸园。对象创建在伊甸园，发生一次ygc后如果有幸存对象就移到幸存区。如果多次ygc后还存活的对象就移到老年代。老年代空间不足会发生fullgc。g1大部分回收工作都是可并行，这期间不会出现stop the world。g1不像cms分老年代和年轻代，而是分为一个个小区域，默认2m大小，这样就可以更小范围的进行垃圾回收。减少垃圾回收的时间。
2、cms调优需要根据需求划分好老年代和年轻代大小。
g1比较职能一般设置下堆大小就行。
3、课后思考：如果分配很大，一次垃圾回收需要的时间很会比较长，影响应用相应时间。还有浪费内存空间。</p>2020-08-17</li><br/><li><span>小唐</span> 👍（1） 💬（0）<p>老师可以把code分享到github吗？我想自己执行一遍加深印象，这样我们就不用自己配置了，多谢老师！</p>2019-08-13</li><br/><li><span>月如钩</span> 👍（1） 💬（0）<p>实操很重要呀，朋友们，纸上谈兵很容易忘</p>2019-08-01</li><br/><li><span>615</span> 👍（0） 💬（0）<p>JDK8 运行参数：

-Xmx2048m
-Xss256k
-Xloggc:.&#47;garbage-collection.log
-XX:+PrintGCDateStamps
-XX:+PrintGCDetails

Refer: https:&#47;&#47;docs.oracle.com&#47;javase&#47;8&#47;docs&#47;technotes&#47;tools&#47;windows&#47;java.html</p>2023-04-14</li><br/><li><span>Geek_88463d</span> 👍（0） 💬（0）<p>这个标题配图有意思，哈哈哈哈</p>2020-12-19</li><br/>
</ul>