在上一讲中，我分析了Java并发包中的部分内容，今天我来介绍一下线程安全队列。Java标准库提供了非常多的线程安全队列，很容易混淆。

今天我要问你的问题是，并发包中的ConcurrentLinkedQueue和LinkedBlockingQueue有什么区别？

## 典型回答

有时候我们把并发包下面的所有容器都习惯叫作并发容器，但是严格来讲，类似ConcurrentLinkedQueue这种“Concurrent\*”容器，才是真正代表并发。

关于问题中它们的区别：

- Concurrent类型基于lock-free，在常见的多线程访问场景，一般可以提供较高吞吐量。
- 而LinkedBlockingQueue内部则是基于锁，并提供了BlockingQueue的等待性方法。

不知道你有没有注意到，java.util.concurrent包提供的容器（Queue、List、Set）、Map，从命名上可以大概区分为Concurrent\*、CopyOnWrite*和Blocking*等三类，同样是线程安全容器，可以简单认为：

- Concurrent类型没有类似CopyOnWrite之类容器相对较重的修改开销。
- 但是，凡事都是有代价的，Concurrent往往提供了较低的遍历一致性。你可以这样理解所谓的弱一致性，例如，当利用迭代器遍历时，如果容器发生修改，迭代器仍然可以继续进行遍历。
- 与弱一致性对应的，就是我介绍过的同步容器常见的行为“fail-fast”，也就是检测到容器在遍历过程中发生了修改，则抛出ConcurrentModificationException，不再继续遍历。
- 弱一致性的另外一个体现是，size等操作准确性是有限的，未必是100%准确。
- 与此同时，读取的性能具有一定的不确定性。

## 考点分析

今天的问题是又是一个引子，考察你是否了解并发包内部不同容器实现的设计目的和实现区别。

队列是非常重要的数据结构，我们日常开发中很多线程间数据传递都要依赖于它，Executor框架提供的各种线程池，同样无法离开队列。面试官可以从不同角度考察，比如：

- 哪些队列是有界的，哪些是无界的？（很多同学反馈了这个问题）
- 针对特定场景需求，如何选择合适的队列实现？
- 从源码的角度，常见的线程安全队列是如何实现的，并进行了哪些改进以提高性能表现？

为了能更好地理解这一讲，需要你掌握一些基本的队列本身和数据结构方面知识，如果这方面知识比较薄弱，《数据结构与算法分析》是一本比较全面的参考书，专栏还是尽量专注于Java领域的特性。

## 知识扩展

**线程安全队列一览**

我在[专栏第8讲](http://time.geekbang.org/column/article/7810)中介绍过，常见的集合中如LinkedList是个Deque，只不过不是线程安全的。下面这张图是Java并发类库提供的各种各样的**线程安全**队列实现，注意，图中并未将非线程安全部分包含进来。

![](https://static001.geekbang.org/resource/image/79/79/791750d6fe7ef88ecb3897e1d029f079.png?wh=851%2A359)

我们可以从不同的角度进行分类，从基本的数据结构的角度分析，有两个特别的[Deque](https://docs.oracle.com/javase/9/docs/api/java/util/Deque.html)实现，ConcurrentLinkedDeque和LinkedBlockingDeque。Deque的侧重点是支持对队列头尾都进行插入和删除，所以提供了特定的方法，如:

- 尾部插入时需要的[addLast(e)](https://docs.oracle.com/javase/9/docs/api/java/util/Deque.html#addLast-E-)、[offerLast(e)](https://docs.oracle.com/javase/9/docs/api/java/util/Deque.html#offerLast-E-)。
- 尾部删除所需要的[removeLast()](https://docs.oracle.com/javase/9/docs/api/java/util/Deque.html#removeLast--)、[pollLast()](https://docs.oracle.com/javase/9/docs/api/java/util/Deque.html#pollLast--)。

从上面这些角度，能够理解ConcurrentLinkedDeque和LinkedBlockingQueue的主要功能区别，也就足够日常开发的需要了。但是如果我们深入一些，通常会更加关注下面这些方面。

从行为特征来看，绝大部分Queue都是实现了BlockingQueue接口。在常规队列操作基础上，Blocking意味着其提供了特定的等待性操作，获取时（take）等待元素进队，或者插入时（put）等待队列出现空位。

```
 /**
 * 获取并移除队列头结点，如果必要，其会等待直到队列出现元素
…
 */
E take() throws InterruptedException;

/**
 * 插入元素，如果队列已满，则等待直到队列出现空闲空间
   …
 */
void put(E e) throws InterruptedException;  
```

另一个BlockingQueue经常被考察的点，就是是否有界（Bounded、Unbounded），这一点也往往会影响我们在应用开发中的选择，我这里简单总结一下。

- ArrayBlockingQueue是最典型的的有界队列，其内部以final的数组保存数据，数组的大小就决定了队列的边界，所以我们在创建ArrayBlockingQueue时，都要指定容量，如

```
public ArrayBlockingQueue(int capacity, boolean fair)
```

- LinkedBlockingQueue，容易被误解为无边界，但其实其行为和内部代码都是基于有界的逻辑实现的，只不过如果我们没有在创建队列时就指定容量，那么其容量限制就自动被设置为Integer.MAX\_VALUE，成为了无界队列。
- SynchronousQueue，这是一个非常奇葩的队列实现，每个删除操作都要等待插入操作，反之每个插入操作也都要等待删除动作。那么这个队列的容量是多少呢？是1吗？其实不是的，其内部容量是0。
- PriorityBlockingQueue是无边界的优先队列，虽然严格意义上来讲，其大小总归是要受系统资源影响。
- DelayedQueue和LinkedTransferQueue同样是无边界的队列。对于无边界的队列，有一个自然的结果，就是put操作永远也不会发生其他BlockingQueue的那种等待情况。

如果我们分析不同队列的底层实现，BlockingQueue基本都是基于锁实现，一起来看看典型的LinkedBlockingQueue。

```
/** Lock held by take, poll, etc */
private final ReentrantLock takeLock = new ReentrantLock();

/** Wait queue for waiting takes */
private final Condition notEmpty = takeLock.newCondition();

/** Lock held by put, offer, etc */
private final ReentrantLock putLock = new ReentrantLock();

/** Wait queue for waiting puts */
private final Condition notFull = putLock.newCondition();
```

我在介绍ReentrantLock的条件变量用法的时候分析过ArrayBlockingQueue，不知道你有没有注意到，其条件变量与LinkedBlockingQueue版本的实现是有区别的。notEmpty、notFull都是同一个再入锁的条件变量，而LinkedBlockingQueue则改进了锁操作的粒度，头、尾操作使用不同的锁，所以在通用场景下，它的吞吐量相对要更好一些。

下面的take方法与ArrayBlockingQueue中的实现，也是有不同的，由于其内部结构是链表，需要自己维护元素数量值，请参考下面的代码。

```
public E take() throws InterruptedException {
    final E x;
    final int c;
    final AtomicInteger count = this.count;
    final ReentrantLock takeLock = this.takeLock;
    takeLock.lockInterruptibly();
    try {
        while (count.get() == 0) {
            notEmpty.await();
        }
        x = dequeue();
        c = count.getAndDecrement();
        if (c > 1)
            notEmpty.signal();
    } finally {
        takeLock.unlock();
    }
    if (c == capacity)
        signalNotFull();
    return x;
}
```

类似ConcurrentLinkedQueue等，则是基于CAS的无锁技术，不需要在每个操作时使用锁，所以扩展性表现要更加优异。

相对比较另类的SynchronousQueue，在Java 6中，其实现发生了非常大的变化，利用CAS替换掉了原本基于锁的逻辑，同步开销比较小。它是Executors.newCachedThreadPool()的默认队列。

**队列使用场景与典型用例**

在实际开发中，我提到过Queue被广泛使用在生产者-消费者场景，比如利用BlockingQueue来实现，由于其提供的等待机制，我们可以少操心很多协调工作，你可以参考下面样例代码：

```
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;

public class ConsumerProducer {
    public static final String EXIT_MSG  = "Good bye!";
    public static void main(String[] args) {
// 使用较小的队列，以更好地在输出中展示其影响
        BlockingQueue<String> queue = new ArrayBlockingQueue<>(3);
        Producer producer = new Producer(queue);
        Consumer consumer = new Consumer(queue);
        new Thread(producer).start();
        new Thread(consumer).start();
    }


    static class Producer implements Runnable {
        private BlockingQueue<String> queue;
        public Producer(BlockingQueue<String> q) {
            this.queue = q;
        }

        @Override
        public void run() {
            for (int i = 0; i < 20; i++) {
                try{
                    Thread.sleep(5L);
                    String msg = "Message" + i;
                    System.out.println("Produced new item: " + msg);
                    queue.put(msg);
                } catch (InterruptedException e) {
                    e.printStackTrace();
                }
            }

            try {
                System.out.println("Time to say good bye!");
                queue.put(EXIT_MSG);
            } catch (InterruptedException e) {
                e.printStackTrace();
            }
        }
    }

    static class Consumer implements Runnable{
        private BlockingQueue<String> queue;
        public Consumer(BlockingQueue<String> q){
            this.queue=q;
        }

        @Override
        public void run() {
            try{
                String msg;
                while(!EXIT_MSG.equalsIgnoreCase( (msg = queue.take()))){
                    System.out.println("Consumed item: " + msg);
                    Thread.sleep(10L);
                }
                System.out.println("Got exit message, bye!");
            }catch(InterruptedException e) {
                e.printStackTrace();
            }
        }
    }
}
```

上面是一个典型的生产者-消费者样例，如果使用非Blocking的队列，那么我们就要自己去实现轮询、条件判断（如检查poll返回值是否null）等逻辑，如果没有特别的场景要求，Blocking实现起来代码更加简单、直观。

前面介绍了各种队列实现，在日常的应用开发中，如何进行选择呢？

以LinkedBlockingQueue、ArrayBlockingQueue和SynchronousQueue为例，我们一起来分析一下，根据需求可以从很多方面考量：

- 考虑应用场景中对队列边界的要求。ArrayBlockingQueue是有明确的容量限制的，而LinkedBlockingQueue则取决于我们是否在创建时指定，SynchronousQueue则干脆不能缓存任何元素。
- 从空间利用角度，数组结构的ArrayBlockingQueue要比LinkedBlockingQueue紧凑，因为其不需要创建所谓节点，但是其初始分配阶段就需要一段连续的空间，所以初始内存需求更大。
- 通用场景中，LinkedBlockingQueue的吞吐量一般优于ArrayBlockingQueue，因为它实现了更加细粒度的锁操作。
- ArrayBlockingQueue实现比较简单，性能更好预测，属于表现稳定的“选手”。
- 如果我们需要实现的是两个线程之间接力性（handoff）的场景，按照[专栏上一讲](http://time.geekbang.org/column/article/9373)的例子，你可能会选择CountDownLatch，但是[SynchronousQueue](http://www.baeldung.com/java-synchronous-queue)也是完美符合这种场景的，而且线程间协调和数据传输统一起来，代码更加规范。
- 可能令人意外的是，很多时候SynchronousQueue的性能表现，往往大大超过其他实现，尤其是在队列元素较小的场景。

今天我分析了Java中让人眼花缭乱的各种线程安全队列，试图从几个角度，让每个队列的特点更加明确，进而希望减少你在日常工作中使用时的困扰。

## 一课一练

关于今天我们讨论的题目你做到心中有数了吗？ 今天的内容侧重于Java自身的角度，面试官也可能从算法的角度来考察，所以今天留给你的思考题是，指定某种结构，比如栈，用它实现一个BlockingQueue，实现思路是怎样的呢？

请你在留言区写写你对这个问题的思考，我会选出经过认真思考的留言，送给你一份学习奖励礼券，欢迎你与我一起讨论。

你的朋友是不是也在准备面试呢？你可以“请朋友读”，把今天的题目分享给好友，或许你能帮到他。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>爱新觉罗老流氓</span> 👍（4） 💬（2）<p>杨老师，“与弱一致性对应的，就是我介绍过的同步容器常见的行为“fast-fail”，也就是检测到容器在遍历过程中发生了修改，则抛出 ConcurrentModificationException，不再继续遍历。” 
这一段落里，快速失败的英文在doc上是“fail-fast”，在ArrayList源码中文档可以搜到。
还有，同步容器不应该是“fail-safe”吗？</p>2018-07-03</li><br/><li><span>灰飞灰猪不会灰飞.烟灭</span> 👍（3） 💬（1）<p>老师 线程池中如果线程已经运行结束则删除该线程。如何判断线程已经运行结束了呢？源码中我看见按照线程的状态，我不清楚这些状态值哪来的。java代码有判断线程状态的方法吗？谢谢老师</p>2018-06-21</li><br/><li><span>Invocker.C</span> 👍（2） 💬（2）<p>求老师解答一个困扰已久的问题，就是初始化arrayblockingqueue的时候，capacity的大小如何评估和设置？望解答</p>2018-06-27</li><br/><li><span>杭州</span> 👍（0） 💬（1）<p>杨老师你好，遇到个问题，200个并发线程池阻塞读linkBlockingQueue队列，偶尔会出现阻塞时会线程cpu很好。jstack看了很多lock。会不会出现线程离开线程池，去干别的任务，干了一半又回到线程池中干活。两边出现死锁？</p>2018-11-10</li><br/><li><span>夏洛克的救赎</span> 👍（0） 💬（1）<p>老师你好，问个题外问题，在jdk10源码  string类中，成员变量coder起到什么作用？如何理解？</p>2018-06-21</li><br/><li><span>sunlight001</span> 👍（94） 💬（0）<p>这个看着很吃力啊，都没接触过😂</p>2018-06-21</li><br/><li><span>丘壑</span> 👍（49） 💬（7）<p>栈来实现blockqueue，个人感觉比较好的有
方案一：总共3个栈，其中2个写入栈（A、B），1个消费栈栈C（消费数据），但是有1个写入栈是空闲的栈（B），随时等待写入，当消费栈(C)中数据为空的时候，消费线程（await），触发数据转移，原写入栈(A)停止写入，，由空闲栈（B）接受写入的工作，原写入栈(A)中的数据转移到消费栈（C）中，转移完成后继续（sign）继续消费，2个写入栈，1个消费栈优点是：不会堵塞写入，但是消费会有暂停

方案二：总共4个栈，其中2个写入栈（A、B），2个消费栈（C、D）,其中B为空闲的写入栈，D为空闲的消费栈，当消费栈（C）中的数据下降到一定的数量，则触发数据转移，这时候A栈停止写入，由B栈接受写入数据，然后将A栈中的数据转入空闲的消费栈D，当C中的数据消费完了后，则C栈转为空闲，D栈转为激活消费状态，当D栈中的数据消费到一定比例后，重复上面过程，该方案优点即不堵塞写入，也不会造成消费线程暂停


</p>2018-09-13</li><br/><li><span>吕倩</span> 👍（20） 💬（2）<p>老师你好，在读ArrayBlockingQueue源码的时候，发现很多地方都有 final ReentrantLock lock = this.lock; 这样的语句，处于什么原因会将类变量复制一份到局部变量，然后再使用呢？</p>2018-12-03</li><br/><li><span>Lighters</span> 👍（14） 💬（0）<p>希望能够增加一些具体的业务使用场景，否则只是单纯的分析，太抽象了
</p>2019-04-27</li><br/><li><span>石头狮子</span> 👍（13） 💬（0）<p>实现课后题过程中把握以下几个维度，
1，数据操作的锁粒度。
2，计数，遍历方式。
3，数据结构空，满时线程的等待方式，有锁或无锁方式。
4，使用离散还是连续的存储结构。</p>2018-06-21</li><br/><li><span>crazyone</span> 👍（8） 💬（0）<p>从上面这些角度，能够理解 ConcurrentLinkedDeque 和 LinkedBlockingQueue 的主要功能区别。  这段应该是 &quot;ConcurrentLinkedDeque 和 LinkedBlockingDeque 的主要功能区别&quot;</p>2018-06-22</li><br/><li><span>猕猴桃 盛哥</span> 👍（8） 💬（2）<p>{
    &quot;test&quot;:[
        [
            89,
            90,
            [
                [
                    1093,
                    709
                ],
                [
                    1056,
                    709
                ]
            ]
        ]
    ]
}

测试题：这个json用java对象怎么表示？</p>2018-06-22</li><br/><li><span>无呢可称</span> 👍（4） 💬（3）<p>@Jerry银银。用两个栈可以实现fifo的队列

</p>2018-06-27</li><br/><li><span>石头狮子</span> 👍（4） 💬（0）<p>实现课后题过程中把握以下几个维度，
1，数据操作的锁粒度。
2，计数，遍历方式。
3，数据结构空，满时线程的等待方式，有锁或无锁方式。
4，使用离散还是连续的存储结构。</p>2018-06-21</li><br/><li><span>Geek_8c5f9c</span> 👍（3） 💬（2）<p>fail-fast不是同步容器的行为， fail-safe才是。</p>2020-02-03</li><br/>
</ul>