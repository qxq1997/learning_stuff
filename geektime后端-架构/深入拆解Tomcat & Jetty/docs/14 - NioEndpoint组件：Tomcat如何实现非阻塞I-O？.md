UNIX系统下的I/O模型有5种：同步阻塞I/O、同步非阻塞I/O、I/O多路复用、信号驱动I/O和异步I/O。这些名词我们好像都似曾相识，但这些I/O通信模型有什么区别？同步和阻塞似乎是一回事，到底有什么不同？等一下，在这之前你是不是应该问自己一个终极问题：什么是I/O？为什么需要这些I/O模型？

所谓的**I/O就是计算机内存与外部设备之间拷贝数据的过程**。我们知道CPU访问内存的速度远远高于外部设备，因此CPU是先把外部设备的数据读到内存里，然后再进行处理。请考虑一下这个场景，当你的程序通过CPU向外部设备发出一个读指令时，数据从外部设备拷贝到内存往往需要一段时间，这个时候CPU没事干了，你的程序是主动把CPU让给别人？还是让CPU不停地查：数据到了吗，数据到了吗……

这就是I/O模型要解决的问题。今天我会先说说各种I/O模型的区别，然后重点分析Tomcat的NioEndpoint组件是如何实现非阻塞I/O模型的。

## Java I/O模型

对于一个网络I/O通信过程，比如网络数据读取，会涉及两个对象，一个是调用这个I/O操作的用户线程，另外一个就是操作系统内核。一个进程的地址空间分为用户空间和内核空间，用户线程不能直接访问内核空间。

当用户线程发起I/O操作后，网络数据读取操作会经历两个步骤：

- **用户线程等待内核将数据从网卡拷贝到内核空间。**
- **内核将数据从内核空间拷贝到用户空间。**

各种I/O模型的区别就是：它们实现这两个步骤的方式是不一样的。

**同步阻塞I/O**：用户线程发起read调用后就阻塞了，让出CPU。内核等待网卡数据到来，把数据从网卡拷贝到内核空间，接着把数据拷贝到用户空间，再把用户线程叫醒。

![](https://static001.geekbang.org/resource/image/99/de/9925741240414d45a3480e976a9eb5de.jpg?wh=590%2A658)

**同步非阻塞I/O**：用户线程不断的发起read调用，数据没到内核空间时，每次都返回失败，直到数据到了内核空间，这一次read调用后，在等待数据从内核空间拷贝到用户空间这段时间里，线程还是阻塞的，等数据到了用户空间再把线程叫醒。

![](https://static001.geekbang.org/resource/image/f6/b9/f609702b40d7fa873f049e472d1819b9.jpg?wh=578%2A664)

**I/O多路复用**：用户线程的读取操作分成两步了，线程先发起select调用，目的是问内核数据准备好了吗？等内核把数据准备好了，用户线程再发起read调用。在等待数据从内核空间拷贝到用户空间这段时间里，线程还是阻塞的。那为什么叫I/O多路复用呢？因为一次select调用可以向内核查多个数据通道（Channel）的状态，所以叫多路复用。

![](https://static001.geekbang.org/resource/image/cd/99/cd2f30b47a690c0fe3b0332203dd3e99.jpg?wh=572%2A656)

**异步I/O**：用户线程发起read调用的同时注册一个回调函数，read立即返回，等内核将数据准备好后，再调用指定的回调函数完成处理。在这个过程中，用户线程一直没有阻塞。

![](https://static001.geekbang.org/resource/image/aa/c3/aacd28f7f9719ceeb2f649db1a6c06c3.jpg?wh=570%2A660)

## NioEndpoint组件

Tomcat的NioEndpoint组件实现了I/O多路复用模型，接下来我会介绍NioEndpoint的实现原理，下一期我会介绍Tomcat如何实现异步I/O模型。

**总体工作流程**

我们知道，对于Java的多路复用器的使用，无非是两步：

1. 创建一个Selector，在它身上注册各种感兴趣的事件，然后调用select方法，等待感兴趣的事情发生。
2. 感兴趣的事情发生了，比如可以读了，这时便创建一个新的线程从Channel中读数据。

Tomcat的NioEndpoint组件虽然实现比较复杂，但基本原理就是上面两步。我们先来看看它有哪些组件，它一共包含LimitLatch、Acceptor、Poller、SocketProcessor和Executor共5个组件，它们的工作过程如下图所示。

![](https://static001.geekbang.org/resource/image/c4/65/c4bbda75005dd5e8519c2bc439359465.jpg?wh=1658%2A1156)

LimitLatch是连接控制器，它负责控制最大连接数，NIO模式下默认是10000，达到这个阈值后，连接请求被拒绝。

Acceptor跑在一个单独的线程里，它在一个死循环里调用accept方法来接收新连接，一旦有新的连接请求到来，accept方法返回一个Channel对象，接着把Channel对象交给Poller去处理。

Poller的本质是一个Selector，也跑在单独线程里。Poller在内部维护一个Channel数组，它在一个死循环里不断检测Channel的数据就绪状态，一旦有Channel可读，就生成一个SocketProcessor任务对象扔给Executor去处理。

Executor就是线程池，负责运行SocketProcessor任务类，SocketProcessor的run方法会调用Http11Processor来读取和解析请求数据。我们知道，Http11Processor是应用层协议的封装，它会调用容器获得响应，再把响应通过Channel写出。

接下来我详细介绍一下各组件的设计特点。

**LimitLatch**

LimitLatch用来控制连接个数，当连接数到达最大时阻塞线程，直到后续组件处理完一个连接后将连接数减1。请你注意到达最大连接数后操作系统底层还是会接收客户端连接，但用户层已经不再接收。LimitLatch的核心代码如下：

```
public class LimitLatch {
    private class Sync extends AbstractQueuedSynchronizer {
     
        @Override
        protected int tryAcquireShared() {
            long newCount = count.incrementAndGet();
            if (newCount > limit) {
                count.decrementAndGet();
                return -1;
            } else {
                return 1;
            }
        }

        @Override
        protected boolean tryReleaseShared(int arg) {
            count.decrementAndGet();
            return true;
        }
    }

    private final Sync sync;
    private final AtomicLong count;
    private volatile long limit;
    
    //线程调用这个方法来获得接收新连接的许可，线程可能被阻塞
    public void countUpOrAwait() throws InterruptedException {
      sync.acquireSharedInterruptibly(1);
    }

    //调用这个方法来释放一个连接许可，那么前面阻塞的线程可能被唤醒
    public long countDown() {
      sync.releaseShared(0);
      long result = getCount();
      return result;
   }
}
```

从上面的代码我们看到，LimitLatch内步定义了内部类Sync，而Sync扩展了AQS，AQS是Java并发包中的一个核心类，它在内部维护一个状态和一个线程队列，可以用来**控制线程什么时候挂起，什么时候唤醒**。我们可以扩展它来实现自己的同步器，实际上Java并发包里的锁和条件变量等等都是通过AQS来实现的，而这里的LimitLatch也不例外。

理解上面的代码时有两个要点：

1. 用户线程通过调用LimitLatch的countUpOrAwait方法来拿到锁，如果暂时无法获取，这个线程会被阻塞到AQS的队列中。那AQS怎么知道是阻塞还是不阻塞用户线程呢？其实这是由AQS的使用者来决定的，也就是内部类Sync来决定的，因为Sync类重写了AQS的**tryAcquireShared()方法**。它的实现逻辑是如果当前连接数count小于limit，线程能获取锁，返回1，否则返回-1。
2. 如何用户线程被阻塞到了AQS的队列，那什么时候唤醒呢？同样是由Sync内部类决定，Sync重写了AQS的**tryReleaseShared()方法**，其实就是当一个连接请求处理完了，这时又可以接收一个新连接了，这样前面阻塞的线程将会被唤醒。

其实你会发现AQS就是一个骨架抽象类，它帮我们搭了个架子，用来控制线程的阻塞和唤醒。具体什么时候阻塞、什么时候唤醒由你来决定。我们还注意到，当前线程数被定义成原子变量AtomicLong，而limit变量用volatile关键字来修饰，这些并发编程的实际运用。

**Acceptor**

Acceptor实现了Runnable接口，因此可以跑在单独线程里。一个端口号只能对应一个ServerSocketChannel，因此这个ServerSocketChannel是在多个Acceptor线程之间共享的，它是Endpoint的属性，由Endpoint完成初始化和端口绑定。初始化过程如下：

```
serverSock = ServerSocketChannel.open();
serverSock.socket().bind(addr,getAcceptCount());
serverSock.configureBlocking(true);
```

从上面的初始化代码我们可以看到两个关键信息：

1. bind方法的第二个参数表示操作系统的等待队列长度，我在上面提到，当应用层面的连接数到达最大值时，操作系统可以继续接收连接，那么操作系统能继续接收的最大连接数就是这个队列长度，可以通过acceptCount参数配置，默认是100。
2. ServerSocketChannel被设置成阻塞模式，也就是说它是以阻塞的方式接收连接的。

ServerSocketChannel通过accept()接受新的连接，accept()方法返回获得SocketChannel对象，然后将SocketChannel对象封装在一个PollerEvent对象中，并将PollerEvent对象压入Poller的Queue里，这是个典型的“生产者-消费者”模式，Acceptor与Poller线程之间通过Queue通信。

**Poller**

Poller本质是一个Selector，它内部维护一个Queue，这个Queue定义如下：

```
private final SynchronizedQueue<PollerEvent> events = new SynchronizedQueue<>();
```

SynchronizedQueue的方法比如offer、poll、size和clear方法，都使用了synchronized关键字进行修饰，用来保证同一时刻只有一个Acceptor线程对Queue进行读写。同时有多个Poller线程在运行，每个Poller线程都有自己的Queue。每个Poller线程可能同时被多个Acceptor线程调用来注册PollerEvent。同样Poller的个数可以通过pollers参数配置。

Poller不断的通过内部的Selector对象向内核查询Channel的状态，一旦可读就生成任务类SocketProcessor交给Executor去处理。Poller的另一个重要任务是循环遍历检查自己所管理的SocketChannel是否已经超时，如果有超时就关闭这个SocketChannel。

**SocketProcessor**

我们知道，Poller会创建SocketProcessor任务类交给线程池处理，而SocketProcessor实现了Runnable接口，用来定义Executor中线程所执行的任务，主要就是调用Http11Processor组件来处理请求。Http11Processor读取Channel的数据来生成ServletRequest对象，这里请你注意：

Http11Processor并不是直接读取Channel的。这是因为Tomcat支持同步非阻塞I/O模型和异步I/O模型，在Java API中，相应的Channel类也是不一样的，比如有AsynchronousSocketChannel和SocketChannel，为了对Http11Processor屏蔽这些差异，Tomcat设计了一个包装类叫作SocketWrapper，Http11Processor只调用SocketWrapper的方法去读写数据。

**Executor**

Executor是Tomcat定制版的线程池，它负责创建真正干活的工作线程，干什么活呢？就是执行SocketProcessor的run方法，也就是解析请求并通过容器来处理请求，最终会调用到我们的Servlet。后面我会用专门的篇幅介绍Tomcat怎么扩展和使用Java原生的线程池。

## 高并发思路

在弄清楚NioEndpoint的实现原理后，我们来考虑一个重要的问题，怎么把这个过程做到高并发呢？

高并发就是能快速地处理大量的请求，需要合理设计线程模型让CPU忙起来，尽量不要让线程阻塞，因为一阻塞，CPU就闲下来了。另外就是有多少任务，就用相应规模的线程数去处理。我们注意到NioEndpoint要完成三件事情：接收连接、检测I/O事件以及处理请求，那么最核心的就是把这三件事情分开，用不同规模的线程数去处理，比如用专门的线程组去跑Acceptor，并且Acceptor的个数可以配置；用专门的线程组去跑Poller，Poller的个数也可以配置；最后具体任务的执行也由专门的线程池来处理，也可以配置线程池的大小。

## 本期精华

I/O模型是为了解决内存和外部设备速度差异的问题。我们平时说的**阻塞或非阻塞**是指应用程序在**发起I/O操作时，是立即返回还是等待**。而**同步和异步**，是指应用程序在与内核通信时，**数据从内核空间到应用空间的拷贝，是由内核主动发起还是由应用程序来触发。**

在Tomcat中，Endpoint组件的主要工作就是处理I/O，而NioEndpoint利用Java NIO API实现了多路复用I/O模型。其中关键的一点是，读写数据的线程自己不会阻塞在I/O等待上，而是把这个工作交给Selector。同时Tomcat在这个过程中运用到了很多Java并发编程技术，比如AQS、原子类、并发容器，线程池等，都值得我们去细细品味。

## 课后思考

Tomcat的NioEndpoint组件的名字中有NIO，NIO是非阻塞的意思，似乎说的是同步非阻塞I/O模型，但是NioEndpoint又是调用Java的的Selector来实现的，我们知道Selector指的是I/O多路复用器，也就是我们说的I/O多路复用模型，这不是矛盾了吗？

不知道今天的内容你消化得如何？如果还有疑问，请大胆的在留言区提问，也欢迎你把你的课后思考和心得记录下来，与我和其他同学一起讨论。如果你觉得今天有所收获，欢迎你把它分享给你的朋友。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>🐛</span> 👍（79） 💬（1）<p>老师，操作系统级的连接指的是什么啊？</p>2019-06-11</li><br/><li><span>Geek_28b75e</span> 👍（42） 💬（1）<p>问一个基础问题，线程的同步，和本节所讲的同步，意义上的不同</p>2019-06-11</li><br/><li><span>QQ怪</span> 👍（38） 💬（1）<p>老师，信号驱动式 I&#47;O与其他io模型的有啥不一样？</p>2019-06-13</li><br/><li><span>BingoJ</span> 👍（27） 💬（2）<p>老师，那我们常说Java中自身的NIO到底是同步非阻塞，还是IO多路复用呢？</p>2019-06-21</li><br/><li><span>你好旅行者</span> 👍（26） 💬（5）<p>对于【同步与异步指的是应用程序在与内核通信时，数据从内核空间到应用空间的拷贝内核主动发起还是应用程序触发。】我有一个问题，以同步非阻塞为例，当网卡接收到数据，要将数据送到用户进程时，此时是由用户进程主动向操作系统请求拷贝网卡的数据吗？老师能不能详细介绍一下这个过程？</p>2019-06-17</li><br/><li><span>Dovelol</span> 👍（22） 💬（2）<p>老师，请教下，”当客户端发起一个http请求时，首先由Acceptor线程run方法中的socket = endpoint.serverSocketAccept();接收连接，然后传递给名称为Poller的线程去侦测I&#47;O事件，Poller线程会一直select，选出内核将数据从网卡拷贝到内核空间的 channel（也就是内核已经准备好数据）然后交给名称为Catalina-exec的线程去处理，这个过程也包括内核将数据从内核空间拷贝到用户空间这么一个过程，所以对于exec线程是阻塞的，此时用户空间（也就是exec线程）就接收到了数据，可以解析然后做业务处理了。
1.想问下老师我对这个流程的理解对吗，如果不对，哪个地方有问题呢？
2.老师讲的2个步骤是融合在这里面的吗？
3.老师说的“当用户线程发起 I&#47;O 操作后，xxx”，这里面应该是哪一步去发起的I&#47;O操作呢？</p>2019-06-12</li><br/><li><span>zyz</span> 👍（18） 💬（1）<p>老师！Tomcat为什么不用Semaphore而是自己实现LimitLatch来限流呢？出于什么考虑？性能？不想强依赖Semaphore？</p>2019-06-20</li><br/><li><span>Monday</span> 👍（17） 💬（1）<p>阻塞与同异步的区别
本节的总结有如下的2句话，1）阻塞与非阻塞指的是应用程序发起i&#47;o操作后是等待还是立即返回。2）同步与异步指的是应用程序在与内核通信时，数据从内核空间到应用空间的拷贝内核主动发起还是应用程序触发。
1，阻塞对应的是等待，非阻塞对应的是立即返回。这句应该好理解。
2，同步对应的是哪个？
3，我的理解是js中ajax请求的有个属性，async为true异步false同步。这个对应了网络IO。好理解
4，我的理解阻塞非阻塞是java的jcu包下ArrayBlockingQueue队列中的offer和put方法的区别。其中前者是非阻塞的，队列满了就直接返回入队失败；后者是阻塞的，如果队列满了就阻塞入队的线程，直到队列有空闲并插入成功后返回true。这里面会牵涉到内核吗？
5，反正学完本节发现不知道的更多了，原来自己一直没分清楚过同&#47;异步和是否阻塞。。。疼疼疼</p>2019-06-12</li><br/><li><span>大卫</span> 👍（13） 💬（2）<p>李老师您好，
我来结合实际问题提3个问题吧。
结合这篇文章请教下线上的遇到的故障，接口响应慢最终导致无法正常响应。

jstack打印了堆栈信息，其中一台台机器，总线程数一共4700多，有3500多个Runnable状态的线程，有WAITING状态的1200多。
另外一台机器总线程数一共1200多，大部分都是WAITING状态。
部署方式是物理机（高配置，一般是24CPU 128G内存）+docker（一个docker）
springboot-tomcat参数设置如下：
server.tomcat.accept-count=1000
server.tomcat.max-threads=1000
server.tomcat.max-connections=1000

其中3500多个Runnable状态的线程栈信息如下所示：
&quot;I&#47;O dispatcher 1098713&quot; #1202019 prio=5 os_prio=0 tid=0x00007fdd24071000 nid=0x221f runnable [0x00007fdd28709000]
   java.lang.Thread.State: RUNNABLE
        at sun.nio.ch.EPollArrayWrapper.epollWait(Native Method)
        at sun.nio.ch.EPollArrayWrapper.poll(EPollArrayWrapper.java:269)
        at sun.nio.ch.EPollSelectorImpl.doSelect(EPollSelectorImpl.java:93)
        at sun.nio.ch.SelectorImpl.lockAndDoSelect(SelectorImpl.java:86)
        - locked &lt;0x00000007504d4020&gt; (a sun.nio.ch.Util$2)
        - locked &lt;0x00000007504d4008&gt; (a java.util.Collections$UnmodifiableSet)
        - locked &lt;0x0000000754258eb8&gt; (a sun.nio.ch.EPollSelectorImpl)
        at sun.nio.ch.SelectorImpl.select(SelectorImpl.java:97)
        at org.apache.http.impl.nio.reactor.AbstractIOReactor.execute(AbstractIOReactor.java:255)
        at org.apache.http.impl.nio.reactor.BaseIOReactor.execute(BaseIOReactor.java:104)
        at org.apache.http.impl.nio.reactor.AbstractMultiworkerIOReactor$Worker.run(AbstractMultiworkerIOReactor.java:588)
        at java.lang.Thread.run(Thread.java:745)

问题1：引起上述大量Runnable线程的原因，是因为tomcat最大连接数默认10000导致，放进来这么多待运行的线程吗？有疑惑，头一次遇到呢。
问题2：有1000多个WAITING状态的，目前分析是因为使用了HttpClient连接池，httpclient版本是4.5.5，其中可能没有合理设置超时参数导致，需要增加connectionRequestTimeout，减少retry重试次数，包括defaultMaxPerRoute参数的合理设置。这里的HttpClient线程池的大小和路由池大小怎么设置更合理呢？（可能跟tomcat没有太直接关系，如果老师有这方面经验不吝赐教）
问题3：上面提到部署方式是docker，其中一台docker压测接口比如qps是100，该接口就是调用了第三方接口聚合下返回结果，但是再在同一台物理机上部署一个docker，nginx负载到这两台docker上，qps还是100，并没有什么提升，这个应该从哪方面分析下原因呢？

问题有点多哦，麻烦老师了~</p>2019-06-12</li><br/><li><span>飞翔</span> 👍（12） 💬（1）<p>，当你的程序通过 CPU 向外部设备发出一个读指令时，数据从...


李老师想问一个问题， cpu发出读指令， 那么是什么东西负责读数据从硬盘到内存这个过程呢？ 不是cpu嘛？</p>2019-06-11</li><br/><li><span>AlfredLover</span> 👍（11） 💬（2）<p>有个疑问：内核数据从内核空间拷贝到用户空间？
这个过程是从内核内存拷贝到用户内存吗？
假如是这样会不会有点浪费？
毕竟实际上只有一块内存，能否直接把内存地址指向用户空间可以读取？</p>2019-10-20</li><br/><li><span>Demter</span> 👍（11） 💬（2）<p>对比同步阻塞和非阻塞，感觉就是多了个read方法循环调用，既然等数据到达用户空间后都会主动把线程唤醒，为什么还需要非阻塞方式中不断的read调用呢？不是多此一举吗？调不调用不是都一样的嘛</p>2019-08-14</li><br/><li><span>星火燎原</span> 👍（8） 💬（1）<p>阻塞 用户线程会一直在那里等待数据，
非阻塞 用户线程不会等待，而是在轮询数据有没有到。
老师我这样理解有问题吗？
</p>2019-06-13</li><br/><li><span>🐟🐙🐬🐆🦌🦍🐑🦃</span> 👍（8） 💬（1）<p>老师，我想问下NioEndpoint类中为什么把serverSock 的阻塞模式设置为true. 代码上是serceSock.configBlocking（true）.一般我们在选择NIo的时候都是设置为false的</p>2019-06-12</li><br/><li><span>兔子临死前</span> 👍（6） 💬（1）<p>多路复用是指异步阻塞么？异步就是不需要用户线程主动去问，而是内核完成数据操作的时候返回的；而阻塞是发起read调用后要等待内核返回数据，不知道这样理解对不对。。</p>2019-06-16</li><br/>
</ul>