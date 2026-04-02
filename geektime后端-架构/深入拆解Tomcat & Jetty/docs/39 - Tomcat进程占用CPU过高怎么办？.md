在性能优化这个主题里，前面我们聊过了Tomcat的内存问题和网络相关的问题，接下来我们看一下CPU的问题。CPU资源经常会成为系统性能的一个瓶颈，这其中的原因是多方面的，可能是内存泄露导致频繁GC，进而引起CPU使用率过高；又可能是代码中的Bug创建了大量的线程，导致CPU上下文切换开销。

今天我们就来聊聊Tomcat进程的CPU使用率过高怎么办，以及怎样一步一步找到问题的根因。

## “Java进程CPU使用率高”的解决思路是什么？

通常我们所说的CPU使用率过高，这里面其实隐含着一个用来比较高与低的基准值，比如JVM在峰值负载下的平均CPU利用率为40％，如果CPU使用率飙到80%就可以被认为是不正常的。

典型的JVM进程包含多个Java线程，其中一些在等待工作，另一些则正在执行任务。在单个Java程序的情况下，线程数可以非常低，而对于处理大量并发事务的互联网后台来说，线程数可能会比较高。

对于CPU的问题，最重要的是要找到是**哪些线程在消耗CPU**，通过线程栈定位到问题代码；如果没有找到个别线程的CPU使用率特别高，我们要怀疑到是不是线程上下文切换导致了CPU使用率过高。下面我们通过一个实例来学习CPU问题定位的过程。

## 定位高CPU使用率的线程和代码

1.写一个模拟程序来模拟CPU使用率过高的问题，这个程序会在线程池中创建4096个线程。代码如下：

```
@SpringBootApplication
@EnableScheduling
public class DemoApplication {

   //创建线程池，其中有4096个线程。
   private ExecutorService executor = Executors.newFixedThreadPool(4096);
   //全局变量，访问它需要加锁。
   private int count;
   
   //以固定的速率向线程池中加入任务
   @Scheduled(fixedRate = 10)
   public void lockContention() {
      IntStream.range(0, 1000000)
            .forEach(i -> executor.submit(this::incrementSync));
   }
   
   //具体任务，就是将count数加一
   private synchronized void incrementSync() {
      count = (count + 1) % 10000000;
   }
   
   public static void main(String[] args) {
      SpringApplication.run(DemoApplication.class, args);
   }

}
```

2.在Linux环境下启动程序：

```
java -Xss256k -jar demo-0.0.1-SNAPSHOT.jar
```

请注意，这里我将线程栈大小指定为256KB。对于测试程序来说，操作系统默认值8192KB过大，因为我们需要创建4096个线程。

3.使用top命令，我们看到Java进程的CPU使用率达到了262.3%，注意到进程ID是4361。

![](https://static001.geekbang.org/resource/image/e0/50/e0db4c399cbbf83924a505a9cd619150.png?wh=1036%2A446)

4.接着我们用更精细化的top命令查看这个Java进程中各线程使用CPU的情况：

```
#top -H -p 4361
```

![](https://static001.geekbang.org/resource/image/4a/8d/4a52b5335daf5bfe0b60128a1c13558d.png?wh=1095%2A725)

从图上我们可以看到，有个叫“scheduling-1”的线程占用了较多的CPU，达到了42.5%。因此下一步我们要找出这个线程在做什么事情。

5.为了找出线程在做什么事情，我们需要用jstack命令生成线程快照，具体方法是：

```
jstack 4361
```

jstack的输出比较大，你可以将输出写入文件：

```
jstack 4361 > 4361.log
```

然后我们打开4361.log，定位到第4步中找到的名为“scheduling-1”的线程，发现它的线程栈如下：

![](https://static001.geekbang.org/resource/image/da/8e/dae7a6f02563051a1d4dd3752d9f5e8e.png?wh=1871%2A845)

从线程栈中我们看到了`AbstractExecutorService.submit`这个函数调用，说明它是Spring Boot启动的周期性任务线程，向线程池中提交任务，这个线程消耗了大量CPU。

## 进一步分析上下文切换开销

一般来说，通过上面的过程，我们就能定位到大量消耗CPU的线程以及有问题的代码，比如死循环。但是对于这个实例的问题，你是否发现这样一个情况：Java进程占用的CPU是262.3%， 而“scheduling-1”线程只占用了42.5%的CPU，那还有将近220%的CPU被谁占用了呢？

不知道你注意到没有，我们在第4步用`top -H -p 4361`命令看到的线程列表中还有许多名为“pool-1-thread-x”的线程，它们单个的CPU使用率不高，但是似乎数量比较多。你可能已经猜到，这些就是线程池中干活的线程。那剩下的220%的CPU是不是被这些线程消耗了呢？

要弄清楚这个问题，我们还需要看jstack的输出结果，主要是看这些线程池中的线程是不是真的在干活，还是在“休息”呢？

![](https://static001.geekbang.org/resource/image/68/bf/68bb91e5c1405940b470c08851d13cbf.png?wh=1885%2A325)

通过上面的图我们发现这些“pool-1-thread-x”线程基本都处于WAITING的状态，那什么是WAITING状态呢？或者说Java线程都有哪些状态呢？你可以通过下面的图来理解一下：

![](https://static001.geekbang.org/resource/image/0e/43/0e2336814a4b9fc39bcdf991949a7e43.png?wh=650%2A442)

从图上我们看到“Blocking”和“Waiting”是两个不同的状态，我们要注意它们的区别：

- Blocking指的是一个线程因为等待临界区的锁（Lock或者synchronized关键字）而被阻塞的状态，请你注意的是处于这个状态的线程**还没有拿到锁。**
- Waiting指的是一个线程拿到了锁，但是需要等待其他线程执行某些操作。比如调用了Object.wait、Thread.join或者LockSupport.park方法时，进入Waiting状态。**前提是这个线程已经拿到锁了**，并且在进入Waiting状态前，操作系统层面会自动释放锁，当等待条件满足，外部调用了Object.notify或者LockSupport.unpark方法，线程会重新竞争锁，成功获得锁后才能进入到Runnable状态继续执行。

回到我们的“pool-1-thread-x”线程，这些线程都处在“Waiting”状态，从线程栈我们看到，这些线程“等待”在getTask方法调用上，线程尝试从线程池的队列中取任务，但是队列为空，所以通过LockSupport.park调用进到了“Waiting”状态。那“pool-1-thread-x”线程有多少个呢？通过下面这个命令来统计一下，结果是4096，正好跟线程池中的线程数相等。

![](https://static001.geekbang.org/resource/image/f7/3d/f7b4611b87a8bd65fa25a2c4c7228b3d.png?wh=635%2A69)

你可能好奇了，那剩下的220%的CPU到底被谁消耗了呢？分析到这里，我们应该怀疑CPU的上下文切换开销了，因为我们看到Java进程中的线程数比较多。下面我们通过vmstat命令来查看一下操作系统层面的线程上下文切换活动：

![](https://static001.geekbang.org/resource/image/07/c4/07cccbe33337df20a2544947281c71c4.png?wh=1118%2A558)

如果你还不太熟悉vmstat，可以在[这里](https://linux.die.net/man/8/vmstat)学习如何使用vmstat和查看结果。其中cs那一栏表示线程上下文切换次数，in表示CPU中断次数，我们发现这两个数字非常高，基本证实了我们的猜测，线程上下文切切换消耗了大量CPU。那么问题来了，具体是哪个进程导致的呢？

我们停止Spring Boot测试程序，再次运行vmstat命令，会看到in和cs都大幅下降了，这样就证实了引起线程上下文切换开销的Java进程正是4361。

![](https://static001.geekbang.org/resource/image/5f/fa/5f0a5dadc0659da607fd6e5f0c96dffa.png?wh=1094%2A408)

## 本期精华

当我们遇到CPU过高的问题时，首先要定位是哪个进程的导致的，之后可以通过`top -H -p pid`命令定位到具体的线程。其次还要通jstack查看线程的状态，看看线程的个数或者线程的状态，如果线程数过多，可以怀疑是线程上下文切换的开销，我们可以通过vmstat和pidstat这两个工具进行确认。

## 课后思考

哪些情况可能导致程序中的线程数失控，产生大量线程呢？

不知道今天的内容你消化得如何？如果还有疑问，请大胆的在留言区提问，也欢迎你把你的课后思考和心得记录下来，与我和其他同学一起讨论。如果你觉得今天有所收获，欢迎你把它分享给你的朋友。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>a、</span> 👍（19） 💬（3）<p>1.使用了Java的newCachedThreadPool，因为最大线程数是int最大值
2.自定义线程池最大线程数设置不合理
3.线程池的拒绝策略，选择了如果队列满了并且线程达到最大线程数后，提交的任务交给提交任务线程处理</p>2019-08-10</li><br/><li><span>802.11</span> 👍（9） 💬（2）<p>老师这些都是一些实时的操作，但是大部分情况CPU高的时候并没有及时的在服务器上观察，一旦错过了这个发生的时间点，事后该怎样去判断和定位呢</p>2019-08-10</li><br/><li><span>802.11</span> 👍（4） 💬（3）<p> TIMED_WAITING 是什么意思呢？有什么寓意呢</p>2019-08-10</li><br/><li><span>陆离</span> 👍（0） 💬（1）<p>容器在启动起来之后就被kill掉的原因有哪些？和CPU过高有关系吗</p>2019-08-10</li><br/><li><span>新世界</span> 👍（5） 💬（0）<p>线程池和等待队列设置不合理以及拒绝策略设置不合理会导致线程数失控，比如线程池设置小，等到队列也不大，拒绝策略选择用主线程继续执行，瞬间大量请求，会导致等到队列占满，进而用主线程执行任务，导致tomcat线程被打满，线程数失控</p>2019-08-10</li><br/><li><span>Edward Lee</span> 👍（3） 💬（0）<p>课后思考

之前做了一个与第三方系统的集成，在未设置读超时时间的前提下发生读超时（卡着接近2分钟），导致Tomcat线程耗尽，并同时出现假死情况</p>2020-12-06</li><br/><li><span>花花大脸猫</span> 👍（1） 💬（0）<p>大量处理时间很长的请求，外加未规划的tomcat连接配置，会导致线程数随着请求量的增大无限递增。</p>2022-06-22</li><br/><li><span>JamesZhou</span> 👍（1） 💬（0）<p>排查CPU过高，发现一个小工具可以试试：https:&#47;&#47;github.com&#47;oldratlee&#47;useful-scripts&#47;blob&#47;dev-2.x&#47;docs&#47;java.md#-show-busy-java-threads</p>2020-05-31</li><br/><li><span>花花世界小人物</span> 👍（0） 💬（0）<p>Blocking 指的是一个线程因为等待临界区的锁（Lock 或者 synchronized 关键字）而被阻塞的状态，请你注意的是处于这个状态的线程还没有拿到锁

老师 Blocking状态只有synchronized阻塞的时候才会有这个状态。我试了一下ReentrantLock锁是WAITING
&quot;222&quot; #14 prio=5 os_prio=31 tid=0x00007f852d20a800 nid=0x9503 waiting on condition [0x0000000306dc1000]
   java.lang.Thread.State: WAITING (parking)
	at sun.misc.Unsafe.park(Native Method)
	- parking to wait for  &lt;0x000000076cb6eb48&gt; (a java.util.concurrent.locks.ReentrantLock$NonfairSync)
	at java.util.concurrent.locks.LockSupport.park(LockSupport.java:175)
	at java.util.concurrent.locks.AbstractQueuedSynchronizer.parkAndCheckInterrupt(AbstractQueuedSynchronizer.java:836)
	at java.util.concurrent.locks.AbstractQueuedSynchronizer.acquireQueued(AbstractQueuedSynchronizer.java:870)
	at java.util.concurrent.locks.AbstractQueuedSynchronizer.acquire(AbstractQueuedSynchronizer.java:1199)
	at java.util.concurrent.locks.ReentrantLock$NonfairSync.lock(ReentrantLock.java:209)
	at java.util.concurrent.locks.ReentrantLock.lock(ReentrantLock.java:285)
	at cn.labnetwork.service.order.requisition.RequisitionController$1.run(RequisitionController.java:123)
	at java.lang.Thread.run(Thread.java:750)</p>2023-03-03</li><br/><li><span>DY</span> 👍（0） 💬（0）<p>老师真牛</p>2021-05-17</li><br/><li><span>James</span> 👍（0） 💬（0）<p>top -H -p 4361 最后一个指标全部显示java。。。而不是具体的线程名字。。</p>2021-03-31</li><br/><li><span>惘 闻</span> 👍（0） 💬（0）<p>waiting是线程拿到过锁进入过临界区后因为等待条件而释放锁,blocking是从未拿到过锁从未进入过临界区.两个状态都是不占有锁的状态.老师我理解的对吗?</p>2021-01-27</li><br/><li><span>maybe</span> 👍（0） 💬（0）<p>1、cpu使用过高定位思路：先看看有没有占用高得线程，如果没有择可以考虑线程数太多导致上下文切换带来的开销大
2、思考题：使用newcachedthreadpool，因为最大线程数为int最大值相当于无限制，会无限制创建线程。使用自定义线程池，设置和newcachedthreadpool差不多。</p>2020-08-18</li><br/><li><span>Chris</span> 👍（0） 💬（1）<p>老师，线程栈那么多信息，怎么直接定位到了submit的问题呢</p>2020-07-22</li><br/><li><span>许童童</span> 👍（0） 💬（0）<p>哪些情况可能导致程序中的线程数失控，产生大量线程呢？
创建线程池时参数是计算出来的，而计算的过程是有bug的，导致结果有问题，从而创建了大量线程。
这种需要对程序进行测试，线上持续进行性能监控，发现并解决问题。</p>2019-08-10</li><br/>
</ul>