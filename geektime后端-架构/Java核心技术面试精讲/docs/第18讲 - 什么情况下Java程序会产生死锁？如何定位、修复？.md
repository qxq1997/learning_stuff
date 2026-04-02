今天，我会介绍一些日常开发中类似线程死锁等问题的排查经验，并选择一两个我自己修复过或者诊断过的核心类库死锁问题作为例子，希望不仅能在面试时，包括在日常工作中也能对你有所帮助。

今天我要问你的问题是，什么情况下Java程序会产生死锁？如何定位、修复？

## 典型回答

死锁是一种特定的程序状态，在实体之间，由于循环依赖导致彼此一直处于等待之中，没有任何个体可以继续前进。死锁不仅仅是在线程之间会发生，存在资源独占的进程之间同样也可能出现死锁。通常来说，我们大多是聚焦在多线程场景中的死锁，指两个或多个线程之间，由于互相持有对方需要的锁，而永久处于阻塞的状态。

你可以利用下面的示例图理解基本的死锁问题：

![](https://static001.geekbang.org/resource/image/ea/6c/ea88719ec112dead21334034c9ef8a6c.png?wh=551%2A356)

定位死锁最常见的方式就是利用jstack等工具获取线程栈，然后定位互相之间的依赖关系，进而找到死锁。如果是比较明显的死锁，往往jstack等就能直接定位，类似JConsole甚至可以在图形界面进行有限的死锁检测。

如果程序运行时发生了死锁，绝大多数情况下都是无法在线解决的，只能重启、修正程序本身问题。所以，代码开发阶段互相审查，或者利用工具进行预防性排查，往往也是很重要的。

## 考点分析

今天的问题偏向于实用场景，大部分死锁本身并不难定位，掌握基本思路和工具使用，理解线程相关的基本概念，比如各种线程状态和同步、锁、Latch等并发工具，就已经足够解决大多数问题了。

针对死锁，面试官可以深入考察：

- 抛开字面上的概念，让面试者写一个可能死锁的程序，顺便也考察下基本的线程编程。
- 诊断死锁有哪些工具，如果是分布式环境，可能更关心能否用API实现吗？
- 后期诊断死锁还是挺痛苦的，经常加班，如何在编程中尽量避免一些典型场景的死锁，有其他工具辅助吗？

## 知识扩展

在分析开始之前，先以一个基本的死锁程序为例，我在这里只用了两个嵌套的synchronized去获取锁，具体如下：

```
public class DeadLockSample extends Thread {
	private String first;
	private String second;
	public DeadLockSample(String name, String first, String second) {
    	super(name);
    	this.first = first;
    	this.second = second;
	}

	public  void run() {
    	synchronized (first) {
        	System.out.println(this.getName() + " obtained: " + first);
        	try {
            	Thread.sleep(1000L);
            	synchronized (second) {
                	System.out.println(this.getName() + " obtained: " + second);
            	}
        	} catch (InterruptedException e) {
            	// Do nothing
        	}
    	}
	}
	public static void main(String[] args) throws InterruptedException {
    	String lockA = "lockA";
    	String lockB = "lockB";
    	DeadLockSample t1 = new DeadLockSample("Thread1", lockA, lockB);
    	DeadLockSample t2 = new DeadLockSample("Thread2", lockB, lockA);
    	t1.start();
    	t2.start();
    	t1.join();
    	t2.join();
	}
}
```

这个程序编译执行后，几乎每次都可以重现死锁，请看下面截取的输出。另外，这里有个比较有意思的地方，为什么我先调用Thread1的start，但是Thread2却先打印出来了呢？这就是因为线程调度依赖于（操作系统）调度器，虽然你可以通过优先级之类进行影响，但是具体情况是不确定的。

![](https://static001.geekbang.org/resource/image/86/0e/869f3a3d7b759fbfb794f8c81047f30e.png?wh=328%2A57)

下面来模拟问题定位，我就选取最常见的jstack，其他一些类似JConsole等图形化的工具，请自行查找。

首先，可以使用jps或者系统的ps命令、任务管理器等工具，确定进程ID。

其次，调用jstack获取线程栈：

```
${JAVA_HOME}\bin\jstack your_pid
```

然后，分析得到的输出，具体片段如下：

![](https://static001.geekbang.org/resource/image/1f/8b/1fcc1a521b801a5f7428d5229525a38b.png?wh=605%2A308)

最后，结合代码分析线程栈信息。上面这个输出非常明显，找到处于BLOCKED状态的线程，按照试图获取（waiting）的锁ID（请看我标记为相同颜色的数字）查找，很快就定位问题。 jstack本身也会把类似的简单死锁抽取出来，直接打印出来。

在实际应用中，类死锁情况未必有如此清晰的输出，但是总体上可以理解为：

**区分线程状态 -&gt; 查看等待目标 -&gt; 对比Monitor等持有状态**

所以，理解线程基本状态和并发相关元素是定位问题的关键，然后配合程序调用栈结构，基本就可以定位到具体的问题代码。

如果我们是开发自己的管理工具，需要用更加程序化的方式扫描服务进程、定位死锁，可以考虑使用Java提供的标准管理API，[ThreadMXBean](https://docs.oracle.com/javase/9/docs/api/java/lang/management/ThreadMXBean.html#findDeadlockedThreads--)，其直接就提供了findDeadlockedThreads​()方法用于定位。为方便说明，我修改了DeadLockSample，请看下面的代码片段。

```
public static void main(String[] args) throws InterruptedException {

	ThreadMXBean mbean = ManagementFactory.getThreadMXBean();
	Runnable dlCheck = new Runnable() {

    	@Override
    	public void run() {
        	long[] threadIds = mbean.findDeadlockedThreads();
        	if (threadIds != null) {
                     ThreadInfo[] threadInfos = mbean.getThreadInfo(threadIds);
                     System.out.println("Detected deadlock threads:");
            	for (ThreadInfo threadInfo : threadInfos) {
                	System.out.println(threadInfo.getThreadName());
            	}
          }
       }
    };

       ScheduledExecutorService scheduler =Executors.newScheduledThreadPool(1);
       // 稍等5秒，然后每10秒进行一次死锁扫描
        scheduler.scheduleAtFixedRate(dlCheck, 5L, 10L, TimeUnit.SECONDS);
// 死锁样例代码…
}
```

重新编译执行，你就能看到死锁被定位到的输出。在实际应用中，就可以据此收集进一步的信息，然后进行预警等后续处理。但是要注意的是，对线程进行快照本身是一个相对重量级的操作，还是要慎重选择频度和时机。

**如何在编程中尽量预防死锁呢？**

首先，我们来总结一下前面例子中死锁的产生包含哪些基本元素。基本上死锁的发生是因为：

- 互斥条件，类似Java中Monitor都是独占的，要么是我用，要么是你用。
- 互斥条件是长期持有的，在使用结束之前，自己不会释放，也不能被其他线程抢占。
- 循环依赖关系，两个或者多个个体之间出现了锁的链条环。

所以，我们可以据此分析可能的避免死锁的思路和方法。

**第一种方法**

如果可能的话，尽量避免使用多个锁，并且只有需要时才持有锁。否则，即使是非常精通并发编程的工程师，也难免会掉进坑里，嵌套的synchronized或者lock非常容易出问题。

我举个[例子](https://bugs.openjdk.java.net/browse/JDK-8198928)， Java NIO的实现代码向来以锁多著称，一个原因是，其本身模型就非常复杂，某种程度上是不得不如此；另外是在设计时，考虑到既要支持阻塞模式，又要支持非阻塞模式。直接结果就是，一些基本操作如connect，需要操作三个锁以上，在最近的一个JDK改进中，就发生了死锁现象。

我将其简化为下面的伪代码，问题是暴露在HTTP/2客户端中，这是个非常现代的反应式风格的API，非常推荐学习使用。

```
/// Thread HttpClient-6-SelectorManager:
readLock.lock();
writeLock.lock();
// 持有readLock/writeLock，调用close（）需要获得closeLock
close();
// Thread HttpClient-6-Worker-2 持有closeLock
implCloseSelectableChannel (); //想获得readLock

```

在close发生时， HttpClient-6-SelectorManager线程持有readLock/writeLock，试图获得closeLock；与此同时，另一个HttpClient-6-Worker-2线程，持有closeLock，试图获得readLock，这就不可避免地进入了死锁。

这里比较难懂的地方在于，closeLock的持有状态（就是我标记为绿色的部分）**并没有在线程栈中显示出来**，请参考我在下图中标记的部分。

![](https://static001.geekbang.org/resource/image/b7/24/b7961a84838b5429a8f59826b91ed724.png?wh=1457%2A686)  
﻿  
更加具体来说，请查看[SocketChannelImpl](http://hg.openjdk.java.net/jdk/jdk/file/ce06058197a4/src/java.base/share/classes/sun/nio/ch/SocketChannelImpl.java)的663行，对比implCloseSelectableChannel()方法实现和[AbstractInterruptibleChannel.close()](http://hg.openjdk.java.net/jdk/jdk/file/ce06058197a4/src/java.base/share/classes/java/nio/channels/spi/AbstractInterruptibleChannel.java)在109行的代码，这里就不展示代码了。

所以，从程序设计的角度反思，如果我们赋予一段程序太多的职责，出现“既要…又要…”的情况时，可能就需要我们审视下设计思路或目的是否合理了。对于类库，因为其基础、共享的定位，比应用开发往往更加令人苦恼，需要仔细斟酌之间的平衡。

**第二种方法**

如果必须使用多个锁，尽量设计好锁的获取顺序，这个说起来简单，做起来可不容易，你可以参看著名的[银行家算法](https://en.wikipedia.org/wiki/Banker%27s_algorithm)。

一般的情况，我建议可以采取些简单的辅助手段，比如：

- 将对象（方法）和锁之间的关系，用图形化的方式表示分别抽取出来，以今天最初讲的死锁为例，因为是调用了同一个线程所以更加简单。

<!--THE END-->

![](https://static001.geekbang.org/resource/image/1e/59/1e23562b6ff34206b11c5ec07608fb59.png?wh=241%2A448)

- 然后根据对象之间组合、调用的关系对比和组合，考虑可能调用时序。

<!--THE END-->

![](https://static001.geekbang.org/resource/image/ee/75/ee413b86e8775c63e7947955646db975.png?wh=444%2A604)

- 按照可能时序合并，发现可能死锁的场景。

![](https://static001.geekbang.org/resource/image/9b/e7/9bbad67e205e54e8f7ec8ad37872a9e7.png?wh=368%2A440)  
﻿  
**第三种方法**

使用带超时的方法，为程序带来更多可控性。

类似Object.wait(…)或者CountDownLatch.await(…)，都支持所谓的timed\_wait，我们完全可以就不假定该锁一定会获得，指定超时时间，并为无法得到锁时准备退出逻辑。

并发Lock实现，如ReentrantLock还支持非阻塞式的获取锁操作tryLock()，这是一个插队行为（barging），并不在乎等待的公平性，如果执行时对象恰好没有被独占，则直接获取锁。有时，我们希望条件允许就尝试插队，不然就按照现有公平性规则等待，一般采用下面的方法：

```
if (lock.tryLock() || lock.tryLock(timeout, unit)) {
  	// ...
   }

```

**第四种方法**

业界也有一些其他方面的尝试，比如通过静态代码分析（如FindBugs）去查找固定的模式，进而定位可能的死锁或者竞争情况。实践证明这种方法也有一定作用，请参考[相关文档](https://plugins.jetbrains.com/plugin/3847-findbugs-idea)。

除了典型应用中的死锁场景，其实还有一些更令人头疼的死锁，比如类加载过程发生的死锁，尤其是在框架大量使用自定义类加载时，因为往往不是在应用本身的代码库中，jstack等工具也不见得能够显示全部锁信息，所以处理起来比较棘手。对此，Java有[官方文档](https://docs.oracle.com/javase/7/docs/technotes/guides/lang/cl-mt.html)进行了详细解释，并针对特定情况提供了相应JVM参数和基本原则。

今天，我从样例程序出发，介绍了死锁产生原因，并帮你熟悉了排查死锁基本工具的使用和典型思路，最后结合实例介绍了实际场景中的死锁分析方法与预防措施，希望对你有所帮助。

## 一课一练

关于今天我们讨论的题目你做到心中有数了吗？今天的思考题是，有时候并不是阻塞导致的死锁，只是某个线程进入了死循环，导致其他线程一直等待，这种问题如何诊断呢？

请你在留言区写写你对这个问题的思考，我会选出经过认真思考的留言，送给你一份学习奖励礼券，欢迎你与我一起讨论。

你的朋友是不是也在准备面试呢？你可以“请朋友读”，把今天的题目分享给好友，或许你能帮到他。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>石头狮子</span> 👍（181） 💬（1）<p>1. 死锁的另一个好朋友就是饥饿。死锁和饥饿都是线程活跃性问题。
实践中死锁可以使用 jvm 自带的工具进行排查。
2. 课后题提出的死循环死锁可以认为是自旋锁死锁的一种，其他线程因为等待不到具体的信号提示。导致线程一直饥饿。
这种情况下可以查看线程 cpu 使用情况，排查出使用 cpu 时间片最高的线程，再打出该线程的堆栈信息，排查代码。
3. 基于互斥量的锁如果发生死锁往往 cpu 使用率较低，实践中也可以从这一方面进行排查。</p>2018-06-16</li><br/><li><span>I am a psycho</span> 👍（66） 💬（2）<p>当是死循环引起的其他线程阻塞，会导致cpu飙升，可以先看下cpu的使用率。</p>2018-06-16</li><br/><li><span>curlev3</span> 👍（56） 💬（3）<p>回答老师的问题
可以通过linux下top命令查看cpu使用率较高的java进程，进而用top -Hp ➕pid查看该java进程下cpu使用率较高的线程。再用jstack命令查看线程具体调用情况，排查问题。</p>2018-06-26</li><br/><li><span>西鄉十六夜</span> 👍（32） 💬（1）<p>老师，面试遇到过一个很刁钻的问题。如何在jvm不重启的情况下杀死一个线程，在stop被移除后，如果线程存在死锁那是否意味着必须要修复代码再重启虚拟机呢？</p>2018-07-10</li><br/><li><span>残阳</span> 👍（12） 💬（1）<p>以前做排查的时候看thread dump, 一般都会直接按一些关键字搜索。比如wait，lock之类，然后再找重复的内存地址。看完这遍文章之后感觉对死锁的理解更深刻。</p>2018-06-17</li><br/><li><span>陈一嘉</span> 👍（11） 💬（1）<p>任务线程规范命名，详细记录逻辑运行日志。jstack查看线程状态。</p>2018-06-16</li><br/><li><span>肖一林</span> 👍（8） 💬（1）<p>初学nio的时候确实动不动就发生死锁。现在好像也没有特别好的教程，都是一些java.io的教程。很多教程跟不上技术的迭代。也可能是因为直接io编程在项目实践中偏少。

另外，这个小程序的图片不能放大看，不知道是微信的原因还是小程序的原因。老师看到了帮忙反馈一下。</p>2018-06-16</li><br/><li><span>jacy</span> 👍（5） 💬（1）<p>尽然可以用ThreadMXBean来抓线程死锁信息，受教了。
循环死锁，会导致cpu某线程的cpu时间片占用率相当高，可以结合操作系统工具分析出线程号，然后用jstack分析线程</p>2018-06-22</li><br/><li><span>肖一林</span> 👍（5） 💬（1）<p>一课一练：
最典型的场景是nio的Selector类，这个类内部有三个集合，并且对这些集合做了同步。如果多个线程同时操作一个Selector，就很容易发生死锁。它的select方法会一直拿着锁，并且循环等待事件发生。如果有其他线程在修改它内部的集合数据，就死锁了。

同样用jstack可以发现问题，找出被阻塞的线程，看它等待哪个锁，再找到持有这把锁的线程，这个线程一搬处于运行状态</p>2018-06-16</li><br/><li><span>洗头用酱油</span> 👍（1） 💬（1）<p>杨老师，有点迷糊，所以说一个对象偏向一个线程后，这个线程就有工作了优先权吗？ 问题我记得不特殊设置的话，JVM是随机执行线程的呀？</p>2018-07-22</li><br/><li><span>coolboy</span> 👍（0） 💬（1）<p>杨老师，问个小白问题，java的线程状态有BLOCK、WAITING状态，使用java的内置关键字sychronized时，会出现BLOCK状态。但如果用java的reentrantLock时，也会出现BLOCK状态的吗，不应该只有WAITING状态的？</p>2018-06-25</li><br/><li><span>Miaozhe</span> 👍（0） 💬（1）<p>杨老师，我Win7系统，Java 8上运行Dead Lock Simple例子，通过Jstack获取的Thread 1和Thread 2的线程状态，都是Runnable,但是Waiting on Condition[0x 000000000]。
但是，我通过Thread Group打印出来，两个线程状态都是Block。
晕乎了。。。。</p>2018-06-21</li><br/><li><span>tracer</span> 👍（30） 💬（0）<p>看了下jconsole检测死锁功能的源码，果然也是用ThreadMXBean获取死锁线程并分组，然后打印相关线程信息的。</p>2018-06-27</li><br/><li><span>格非</span> 👍（6） 💬（0）<p>操作系统中学过进程死锁发成的四个必要条件：1、互斥条件，2、占有和等待条件，3、不可抢占条件，4、循环等待条件；破环这四个必要条件中的一个就可以避免发生死锁</p>2019-10-12</li><br/><li><span>随心而至</span> 👍（4） 💬（0）<p>一：死锁的主要原因：
不同线程获取锁的顺序不一致导致。
二：解决方法：
1.确保按照一定顺序获取锁，比如两个类似lockA, lockB的hash值比较，如果相等（概率很低），再添加一把另外的锁tieLock ，具体示例 参加 JCIP 10-3
2.开放调用 不要同时获取多把锁 具体示例 参见JCIP 10-6
3.使用定时的锁 ，tryLock() 或者tryLock(timeout) 

三：死锁检测：
3.1 jstack pid &gt; app.dump 然后在文件中查找线程状态（比如搜索Blocking) -&gt; 查看等待目标 -&gt; 对比 Monitor...
3.2 ThreadMXBean   



</p>2019-09-18</li><br/>
</ul>