你好，我是刘超。

JVM调优是一个系统而又复杂的过程，但我们知道，在大多数情况下，我们基本不用去调整JVM内存分配，因为一些初始化的参数已经可以保证应用服务正常稳定地工作了。

但所有的调优都是有目标性的，JVM内存分配调优也一样。没有性能问题的时候，我们自然不会随意改变JVM内存分配的参数。那有了问题呢？有了什么样的性能问题我们需要对其进行调优呢？又该如何调优呢？这就是我今天要分享的内容。

## JVM内存分配性能问题

谈到JVM内存表现出的性能问题时，你可能会想到一些线上的JVM内存溢出事故。但这方面的事故往往是应用程序创建对象导致的内存回收对象难，一般属于代码编程问题。

但其实很多时候，在应用服务的特定场景下，JVM内存分配不合理带来的性能表现并不会像内存溢出问题这么突出。可以说如果你没有深入到各项性能指标中去，是很难发现其中隐藏的性能损耗。

JVM内存分配不合理最直接的表现就是频繁的GC，这会导致上下文切换等性能问题，从而降低系统的吞吐量、增加系统的响应时间。因此，如果你在线上环境或性能测试时，发现频繁的GC，且是正常的对象创建和回收，这个时候就需要考虑调整JVM内存分配了，从而减少GC所带来的性能开销。

## 对象在堆中的生存周期

了解了性能问题，那需要做的势必就是调优了。但先别急，在了解JVM内存分配的调优过程之前，我们先来看看一个新创建的对象在堆内存中的生存周期，为后面的学习打下基础。

在[第20讲](https://time.geekbang.org/column/article/106203)中，我讲过JVM内存模型。我们知道，在JVM内存模型的堆中，堆被划分为新生代和老年代，新生代又被进一步划分为Eden区和Survivor区，最后Survivor由From Survivor和To Survivor组成。

当我们新建一个对象时，对象会被优先分配到新生代的Eden区中，这时虚拟机会给对象定义一个对象年龄计数器（通过参数-XX:MaxTenuringThreshold设置）。

同时，也有另外一种情况，当Eden空间不足时，虚拟机将会执行一个新生代的垃圾回收（Minor GC）。这时JVM会把存活的对象转移到Survivor中，并给对象的年龄+1。对象在Survivor中同样也会经历MinorGC，每经过一次MinorGC，对象的年龄将会+1。

当然了，内存空间也是有设置阈值的，可以通过参数-XX:PetenureSizeThreshold设置直接被分配到老年代的最大对象，这时如果分配的对象超过了设置的阀值，对象就会直接被分配到老年代，这样做的好处就是可以减少新生代的垃圾回收。

## 查看JVM堆内存分配

我们知道了一个对象从创建至回收到堆中的过程，接下来我们再来了解下JVM堆内存是如何分配的。在默认不配置JVM堆内存大小的情况下，JVM根据默认值来配置当前内存大小。我们可以通过以下命令来查看堆内存配置的默认值：

```
java -XX:+PrintFlagsFinal -version | grep HeapSize 
jmap -heap 17284
```

![](https://static001.geekbang.org/resource/image/43/d5/436338cc5251291eeb6dbb57467443d5.png?wh=803%2A118)

![](https://static001.geekbang.org/resource/image/59/de/59941c65600fe4a11e5bc6b8304fe0de.png?wh=704%2A675)

通过命令，我们可以获得在这台机器上启动的JVM默认最大堆内存为1953MB，初始化大小为124MB。

在JDK1.7中，默认情况下年轻代和老年代的比例是1:2，我们可以通过–XX:NewRatio重置该配置项。年轻代中的Eden和To Survivor、From Survivor的比例是8:1:1，我们可以通过-XX:SurvivorRatio重置该配置项。

在JDK1.7中如果开启了-XX:+UseAdaptiveSizePolicy配置项，JVM将会动态调整Java堆中各个区域的大小以及进入老年代的年龄，–XX:NewRatio和-XX:SurvivorRatio将会失效，而JDK1.8是默认开启-XX:+UseAdaptiveSizePolicy配置项的。

还有，在JDK1.8中，不要随便关闭UseAdaptiveSizePolicy配置项，除非你已经对初始化堆内存/最大堆内存、年轻代/老年代以及Eden区/Survivor区有非常明确的规划了。否则JVM将会分配最小堆内存，年轻代和老年代按照默认比例1:2进行分配，年轻代中的Eden和Survivor则按照默认比例8:2进行分配。这个内存分配未必是应用服务的最佳配置，因此可能会给应用服务带来严重的性能问题。

## JVM内存分配的调优过程

我们先使用JVM的默认配置，观察应用服务的运行情况，下面我将结合一个实际案例来讲述。现模拟一个抢购接口，假设需要满足一个5W的并发请求，且每次请求会产生20KB对象，我们可以通过千级并发创建一个1MB对象的接口来模拟万级并发请求产生大量对象的场景，具体代码如下：

```
	
	@RequestMapping(value = "/test1")
	public String test1(HttpServletRequest request) {
		List<Byte[]> temp = new ArrayList<Byte[]>();
		
		Byte[] b = new Byte[1024*1024];
		temp.add(b);
		
		return "success";
	}
```

### AB压测

分别对应用服务进行压力测试，以下是请求接口的吞吐量和响应时间在不同并发用户数下的变化情况：

![](https://static001.geekbang.org/resource/image/8b/26/8b67579af661a666dff89d16ab2e2f26.jpg?wh=980%2A607)

可以看到，当并发数量到了一定值时，吞吐量就上不去了，响应时间也迅速增加。那么，在JVM内部运行又是怎样的呢？

### 分析GC日志

此时我们可以通过GC日志查看具体的回收日志。我们可以通过设置VM配置参数，将运行期间的GC日志 dump下来，具体配置参数如下：

```
 -XX:+PrintGCTimeStamps -XX:+PrintGCDetails -Xloggc:/log/heapTest.log
```

以下是各个配置项的说明：

- -XX:PrintGCTimeStamps：打印GC具体时间；
- -XX:PrintGCDetails ：打印出GC详细日志；
- -Xloggc: path：GC日志生成路径。

收集到GC日志后，我们就可以使用[第22讲](https://time.geekbang.org/column/article/107396)中介绍过的GCViewer工具打开它，进而查看到具体的GC日志如下：

![](https://static001.geekbang.org/resource/image/bf/d1/bffd496963f6bbd345092c1454524dd1.jpeg?wh=1112%2A705)

主页面显示FullGC发生了13次，右下角显示年轻代和老年代的内存使用率几乎达到了100%。而FullGC会导致stop-the-world的发生，从而严重影响到应用服务的性能。此时，我们需要调整堆内存的大小来减少FullGC的发生。

### 参考指标

我们可以将某些指标的预期值作为参考指标，上面的GC频率就是其中之一，那么还有哪些指标可以为我们提供一些具体的调优方向呢？

**GC频率：**高频的FullGC会给系统带来非常大的性能消耗，虽然MinorGC相对FullGC来说好了许多，但过多的MinorGC仍会给系统带来压力。

**内存：**这里的内存指的是堆内存大小，堆内存又分为年轻代内存和老年代内存。首先我们要分析堆内存大小是否合适，其实是分析年轻代和老年代的比例是否合适。如果内存不足或分配不均匀，会增加FullGC，严重的将导致CPU持续爆满，影响系统性能。

**吞吐量：**频繁的FullGC将会引起线程的上下文切换，增加系统的性能开销，从而影响每次处理的线程请求，最终导致系统的吞吐量下降。

**延时：**JVM的GC持续时间也会影响到每次请求的响应时间。

### 具体调优方法

**调整堆内存空间减少FullGC：**通过日志分析，堆内存基本被用完了，而且存在大量FullGC，这意味着我们的堆内存严重不足，这个时候我们需要调大堆内存空间。

```
java -jar -Xms4g -Xmx4g heapTest-0.0.1-SNAPSHOT.jar
```

以下是各个配置项的说明：

- -Xms：堆初始大小；
- -Xmx：堆最大值。

调大堆内存之后，我们再来测试下性能情况，发现吞吐量提高了40%左右，响应时间也降低了将近50%。

![](https://static001.geekbang.org/resource/image/5f/af/5fd7c3f198018cf5e789c25bd4f14caf.png?wh=686%2A389)

再查看GC日志，发现FullGC频率降低了，老年代的使用率只有16%了。

![](https://static001.geekbang.org/resource/image/b9/2e/b924a13d8cb4e383b94e82d34125002e.jpeg?wh=1118%2A707)

**调整年轻代减少MinorGC：**通过调整堆内存大小，我们已经提升了整体的吞吐量，降低了响应时间。那还有优化空间吗？我们还可以将年轻代设置得大一些，从而减少一些MinorGC（[第22讲](https://time.geekbang.org/column/article/107396)有通过降低Minor GC频率来提高系统性能的详解）。

```
java -jar -Xms4g -Xmx4g -Xmn3g heapTest-0.0.1-SNAPSHOT.jar
```

再进行AB压测，发现吞吐量上去了。

![](https://static001.geekbang.org/resource/image/55/04/55de34ab7eccaf9ad83bac846d0cbf04.png?wh=643%2A424)

再查看GC日志，发现MinorGC也明显降低了，GC花费的总时间也减少了。

![](https://static001.geekbang.org/resource/image/75/5d/75f84993ba0c52d6d338d19dd4db1a5d.jpeg?wh=1113%2A707)

**设置Eden、Survivor区比例：**在JVM中，如果开启 AdaptiveSizePolicy，则每次 GC 后都会重新计算 Eden、From Survivor和 To Survivor区的大小，计算依据是 GC 过程中统计的 GC 时间、吞吐量、内存占用量。这个时候SurvivorRatio默认设置的比例会失效。

在JDK1.8中，默认是开启AdaptiveSizePolicy的，我们可以通过-XX:-UseAdaptiveSizePolicy关闭该项配置，或显示运行-XX:SurvivorRatio=8将Eden、Survivor的比例设置为8:2。大部分新对象都是在Eden区创建的，我们可以固定Eden区的占用比例，来调优JVM的内存分配性能。

再进行AB性能测试，我们可以看到吞吐量提升了，响应时间降低了。

![](https://static001.geekbang.org/resource/image/91/c2/91eb734ea45dc8a24b7938401eafb7c2.png?wh=598%2A417)

![](https://static001.geekbang.org/resource/image/cf/fd/cfaef71dbc8ba4f149a6e134482370fd.jpeg?wh=1131%2A704)

## 总结

JVM内存调优通常和GC调优是互补的，基于以上调优，我们可以继续对年轻代和堆内存的垃圾回收算法进行调优。这里可以结合上一讲的内容，一起完成JVM调优。

虽然分享了一些JVM内存分配调优的常用方法，但我还是建议你在进行性能压测后如果没有发现突出的性能瓶颈，就继续使用JVM默认参数，起码在大部分的场景下，默认配置已经可以满足我们的需求了。但满足不了也不要慌张，结合今天所学的内容去实践一下，相信你会有新的收获。

## 思考题

以上我们都是基于堆内存分配来优化系统性能的，但在NIO的Socket通信中，其实还使用到了堆外内存来减少内存拷贝，实现Socket通信优化。你知道堆外内存是如何创建和回收的吗？

期待在留言区看到你的见解。也欢迎你点击“请朋友读”，把今天的内容分享给身边的朋友，邀请他一起讨论。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>bro.</span> 👍（69） 💬（4）<p>堆外内存创建有两种方式:1.使用ByteBuffer.allocateDirect()得到一个DirectByteBuffer对象,初始化堆外内存大小,里面会创建Cleaner对象,绑定当前this.DirectByteBuffer的回收,通过put,get传递进去Byte数组,或者序列化对象,Cleaner对象实现一个虚引用(当内存被回收时,会受到一个系统通知)当Full GC的时候,如果DirectByteBuffer标记为垃圾被回收,则Cleaner会收到通知调用clean()方法,回收改堆外内存DirectByteBuffer</p>2019-07-22</li><br/><li><span>迎风劲草</span> 👍（25） 💬（1）<p>老师，你的这个抢购场景下我理解是不是新生代越大越好，因为对象都是生命周期较短的对象。尽量在新生代中被回收掉。</p>2019-07-18</li><br/><li><span>天天向上</span> 👍（22） 💬（2）<p>如果你在线上环境或性能测试时，发现频繁的 GC，且是正常的对象创建和回收，这个时候就需要考虑调整 JVM 内存分配了。。有个问题，这个频率多久算频繁呢？</p>2020-01-04</li><br/><li><span>QQ怪</span> 👍（11） 💬（1）<p>盲目增大堆内存可能会让吞吐量不增反减，堆内存大了，每次gc扫描对象也就越多也越需要花费时间，反而会适得其反</p>2019-07-16</li><br/><li><span>钱</span> 👍（7） 💬（3）<p>课后思考及问题
1：JVM 内存分配不合理最直接的表现就是频繁的 GC，这会导致上下文切换等性能问题，从而降低系统的吞吐量、增加系统的响应时间。
频繁的GC，GC线程和应用线程会频繁的切入切出，所以，降低了系统的性能。
2：老师好，现在有这么一个问题，我们有一个定时任务跑一次大概会有2亿条数据一条数据大概40kb大小，一次大概7.4TB多的数据，分布式任务50台机器需要刷新2个多小时，我们需要持久化，为了提高性能做了异步发送MQ到另外的机器来持久化，不过MQ积压严重，数据跑一次耗时太长，有什么建议的优化思路嘛？拆分消息会加剧业务处理的复杂度，目前我能想到的是加机器加带宽。请老师给个优化的思考？
</p>2019-09-11</li><br/><li><span>我又不乱来</span> 👍（6） 💬（1）<p>超哥，有两个疑问。
当第一次创建对象的时候 eden 空间不足会进行一次minor gc把存活的对象放到from s区。如果这个时候from s放不下。会发生一次担保进入老年代吗？
当一次创建对象的时候eden空间不足进入from s区。当第二次创建对象的时候eden空间又不足了，这个时候会把，eden和第一次存在from s 区的对象进行gc 存活的放在 to s区，to s区空间不足，进行担保放入老年代？这样的理解对吗。
</p>2019-07-16</li><br/><li><span>恰饭哒</span> 👍（5） 💬（4）<p>超哥好，我们经常发现生产环境内存使用超过90％持续3分钟，没有outofmer,
dump下来堆没有发现问题，这种情况每不确定几小时就会一次，求解答</p>2019-07-16</li><br/><li><span>考休</span> 👍（3） 💬（3）<p>根据老师的教程，在测试项目中，将年轻代的大小调整为3g，发现的确性能提升了，Mirror GC的次数也大大减少，但是Full GC的次数也明显多了几倍，这个是因为年轻代的空间过大，压缩了老年代的内存大小吗？
java -jar -Xms4g -Xmx4g -Xmn3g heapTest-0.0.1-SNAPSHOT.jar</p>2019-11-13</li><br/><li><span>风轻扬</span> 👍（3） 💬（1）<p>老师，如果允许分配担保机制失败。那即使老年代的空间不足以吃下年轻代的对象。jvm也会冒险进行minor gc的。gc之后，如果老年代还是吃不下对象，这个时候才会Full GC。那关闭这个分配担保机制，感觉好一点啊，反正有Full GC兜底呢😃</p>2019-09-10</li><br/><li><span>-W.LI-</span> 👍（3） 💬（1）<p>老师好!堆外缓存实在FGC的时候回收的吧。
AdaptiveSizePolicy这个参数是不是不太智能啊?我项目4G内存默认开启的AdaptiveSizePolicy。发现只给年轻代分配了136M内存。平时运行到没啥问题，没到定时任务的点就频繁FGC。每次定时任务执行完，都会往老年代推40多M，一天会堆300多M到老年代，也不见它把年轻代调大。用的parNew+CMS。后来把年轻代调整到1G(单次YGC耗时从20ms增加到了40ms)，每天老年代内存涨20M左右。</p>2019-07-16</li><br/><li><span>Levvy</span> 👍（1） 💬（2）<p>最大堆内存1593M  还有124M 这俩数字是在哪看的，我怎么找不到</p>2019-12-04</li><br/><li><span>小笨蛋</span> 👍（1） 💬（1）<p>请问堆内存的分配有没有一个大概的标准😭既然都提到了不能太大也不能太小</p>2019-09-17</li><br/><li><span>又双叒叕是一年啊</span> 👍（1） 💬（1）<p>你好，请问G1调优能不能也讲讲。主要应该注意些什么和cms这种调优的差异</p>2019-08-29</li><br/><li><span>Geek_323c91</span> 👍（0） 💬（1）<p>不知道能不能收到回复,我有个以为,网上查了很多资料 也没得到一个答案,-c 1000 -n 100000 和 -c 100000 和-n 10000的区别是什么 自己压测 怎么调整这2个值</p>2020-05-19</li><br/><li><span>小文同学</span> 👍（0） 💬（1）<p>老师，调整发起老年代堆引起full gc的阈值可以起到优化的效果么？一个老项目把这个阈值设成50%存在的原因会是什么？
</p>2020-03-22</li><br/>
</ul>