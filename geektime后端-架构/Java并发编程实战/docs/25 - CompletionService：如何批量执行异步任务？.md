在[《23 | Future：如何用多线程实现最优的“烧水泡茶”程序？》](https://time.geekbang.org/column/article/91292)的最后，我给你留了道思考题，如何优化一个询价应用的核心代码？如果采用“ThreadPoolExecutor+Future”的方案，你的优化结果很可能是下面示例代码这样：用三个线程异步执行询价，通过三次调用Future的get()方法获取询价结果，之后将询价结果保存在数据库中。

```
// 创建线程池
ExecutorService executor =
  Executors.newFixedThreadPool(3);
// 异步向电商S1询价
Future<Integer> f1 = 
  executor.submit(
    ()->getPriceByS1());
// 异步向电商S2询价
Future<Integer> f2 = 
  executor.submit(
    ()->getPriceByS2());
// 异步向电商S3询价
Future<Integer> f3 = 
  executor.submit(
    ()->getPriceByS3());
    
// 获取电商S1报价并保存
r=f1.get();
executor.execute(()->save(r));
  
// 获取电商S2报价并保存
r=f2.get();
executor.execute(()->save(r));
  
// 获取电商S3报价并保存  
r=f3.get();
executor.execute(()->save(r));

```

上面的这个方案本身没有太大问题，但是有个地方的处理需要你注意，那就是如果获取电商S1报价的耗时很长，那么即便获取电商S2报价的耗时很短，也无法让保存S2报价的操作先执行，因为这个主线程都阻塞在了 `f1.get()` 操作上。这点小瑕疵你该如何解决呢？

估计你已经想到了，增加一个阻塞队列，获取到S1、S2、S3的报价都进入阻塞队列，然后在主线程中消费阻塞队列，这样就能保证先获取到的报价先保存到数据库了。下面的示例代码展示了如何利用阻塞队列实现先获取到的报价先保存到数据库。

```
// 创建阻塞队列
BlockingQueue<Integer> bq =
  new LinkedBlockingQueue<>();
//电商S1报价异步进入阻塞队列  
executor.execute(()->
  bq.put(f1.get()));
//电商S2报价异步进入阻塞队列  
executor.execute(()->
  bq.put(f2.get()));
//电商S3报价异步进入阻塞队列  
executor.execute(()->
  bq.put(f3.get()));
//异步保存所有报价  
for (int i=0; i<3; i++) {
  Integer r = bq.take();
  executor.execute(()->save(r));
}  
```

## 利用CompletionService实现询价系统

不过在实际项目中，并不建议你这样做，因为Java SDK并发包里已经提供了设计精良的CompletionService。利用CompletionService不但能帮你解决先获取到的报价先保存到数据库的问题，而且还能让代码更简练。

CompletionService的实现原理也是内部维护了一个阻塞队列，当任务执行结束就把任务的执行结果加入到阻塞队列中，不同的是CompletionService是把任务执行结果的Future对象加入到阻塞队列中，而上面的示例代码是把任务最终的执行结果放入了阻塞队列中。

**那到底该如何创建CompletionService呢？**

CompletionService接口的实现类是ExecutorCompletionService，这个实现类的构造方法有两个，分别是：

1. `ExecutorCompletionService(Executor executor)`；
2. `ExecutorCompletionService(Executor executor, BlockingQueue<Future<V>> completionQueue)`。

这两个构造方法都需要传入一个线程池，如果不指定completionQueue，那么默认会使用无界的LinkedBlockingQueue。任务执行结果的Future对象就是加入到completionQueue中。

下面的示例代码完整地展示了如何利用CompletionService来实现高性能的询价系统。其中，我们没有指定completionQueue，因此默认使用无界的LinkedBlockingQueue。之后通过CompletionService接口提供的submit()方法提交了三个询价操作，这三个询价操作将会被CompletionService异步执行。最后，我们通过CompletionService接口提供的take()方法获取一个Future对象（前面我们提到过，加入到阻塞队列中的是任务执行结果的Future对象），调用Future对象的get()方法就能返回询价操作的执行结果了。

```
// 创建线程池
ExecutorService executor = 
  Executors.newFixedThreadPool(3);
// 创建CompletionService
CompletionService<Integer> cs = new 
  ExecutorCompletionService<>(executor);
// 异步向电商S1询价
cs.submit(()->getPriceByS1());
// 异步向电商S2询价
cs.submit(()->getPriceByS2());
// 异步向电商S3询价
cs.submit(()->getPriceByS3());
// 将询价结果异步保存到数据库
for (int i=0; i<3; i++) {
  Integer r = cs.take().get();
  executor.execute(()->save(r));
}
```

## CompletionService接口说明

下面我们详细地介绍一下CompletionService接口提供的方法，CompletionService接口提供的方法有5个，这5个方法的方法签名如下所示。

其中，submit()相关的方法有两个。一个方法参数是`Callable<V> task`，前面利用CompletionService实现询价系统的示例代码中，我们提交任务就是用的它。另外一个方法有两个参数，分别是`Runnable task`和`V result`，这个方法类似于ThreadPoolExecutor的 `<T> Future<T> submit(Runnable task, T result)` ，这个方法在[《23 | Future：如何用多线程实现最优的“烧水泡茶”程序？》](https://time.geekbang.org/column/article/91292)中我们已详细介绍过，这里不再赘述。

CompletionService接口其余的3个方法，都是和阻塞队列相关的，take()、poll()都是从阻塞队列中获取并移除一个元素；它们的区别在于如果阻塞队列是空的，那么调用 take() 方法的线程会被阻塞，而 poll() 方法会返回 null 值。 `poll(long timeout, TimeUnit unit)` 方法支持以超时的方式获取并移除阻塞队列头部的一个元素，如果等待了 timeout unit时间，阻塞队列还是空的，那么该方法会返回 null 值。

```
Future<V> submit(Callable<V> task);
Future<V> submit(Runnable task, V result);
Future<V> take() 
  throws InterruptedException;
Future<V> poll();
Future<V> poll(long timeout, TimeUnit unit) 
  throws InterruptedException;
```

## 利用CompletionService实现Dubbo中的Forking Cluster

Dubbo中有一种叫做**Forking的集群模式**，这种集群模式下，支持**并行地调用多个查询服务，只要有一个成功返回结果，整个服务就可以返回了**。例如你需要提供一个地址转坐标的服务，为了保证该服务的高可用和性能，你可以并行地调用3个地图服务商的API，然后只要有1个正确返回了结果r，那么地址转坐标这个服务就可以直接返回r了。这种集群模式可以容忍2个地图服务商服务异常，但缺点是消耗的资源偏多。

```
geocoder(addr) {
  //并行执行以下3个查询服务， 
  r1=geocoderByS1(addr);
  r2=geocoderByS2(addr);
  r3=geocoderByS3(addr);
  //只要r1,r2,r3有一个返回
  //则返回
  return r1|r2|r3;
}
```

利用CompletionService可以快速实现 Forking 这种集群模式，比如下面的示例代码就展示了具体是如何实现的。首先我们创建了一个线程池executor 、一个CompletionService对象cs和一个`Future<Integer>`类型的列表 futures，每次通过调用CompletionService的submit()方法提交一个异步任务，会返回一个Future对象，我们把这些Future对象保存在列表futures中。通过调用 `cs.take().get()`，我们能够拿到最快返回的任务执行结果，只要我们拿到一个正确返回的结果，就可以取消所有任务并且返回最终结果了。

```
// 创建线程池
ExecutorService executor =
  Executors.newFixedThreadPool(3);
// 创建CompletionService
CompletionService<Integer> cs =
  new ExecutorCompletionService<>(executor);
// 用于保存Future对象
List<Future<Integer>> futures =
  new ArrayList<>(3);
//提交异步任务，并保存future到futures 
futures.add(
  cs.submit(()->geocoderByS1()));
futures.add(
  cs.submit(()->geocoderByS2()));
futures.add(
  cs.submit(()->geocoderByS3()));
// 获取最快返回的任务执行结果
Integer r = 0;
try {
  // 只要有一个成功返回，则break
  for (int i = 0; i < 3; ++i) {
    r = cs.take().get();
    //简单地通过判空来检查是否成功返回
    if (r != null) {
      break;
    }
  }
} finally {
  //取消所有任务
  for(Future<Integer> f : futures)
    f.cancel(true);
}
// 返回结果
return r;
```

## 总结

当需要批量提交异步任务的时候建议你使用CompletionService。CompletionService将线程池Executor和阻塞队列BlockingQueue的功能融合在了一起，能够让批量异步任务的管理更简单。除此之外，CompletionService能够让异步任务的执行结果有序化，先执行完的先进入阻塞队列，利用这个特性，你可以轻松实现后续处理的有序性，避免无谓的等待，同时还可以快速实现诸如Forking Cluster这样的需求。

CompletionService的实现类ExecutorCompletionService，需要你自己创建线程池，虽看上去有些啰嗦，但好处是你可以让多个ExecutorCompletionService的线程池隔离，这种隔离性能避免几个特别耗时的任务拖垮整个应用的风险。

## 课后思考

本章使用CompletionService实现了一个询价应用的核心功能，后来又有了新的需求，需要计算出最低报价并返回，下面的示例代码尝试实现这个需求，你看看是否存在问题呢？

```
// 创建线程池
ExecutorService executor = 
  Executors.newFixedThreadPool(3);
// 创建CompletionService
CompletionService<Integer> cs = new 
  ExecutorCompletionService<>(executor);
// 异步向电商S1询价
cs.submit(()->getPriceByS1());
// 异步向电商S2询价
cs.submit(()->getPriceByS2());
// 异步向电商S3询价
cs.submit(()->getPriceByS3());
// 将询价结果异步保存到数据库
// 并计算最低报价
AtomicReference<Integer> m =
  new AtomicReference<>(Integer.MAX_VALUE);
for (int i=0; i<3; i++) {
  executor.execute(()->{
    Integer r = null;
    try {
      r = cs.take().get();
    } catch (Exception e) {}
    save(r);
    m.set(Integer.min(m.get(), r));
  });
}
return m;
```

欢迎在留言区与我分享你的想法，也欢迎你在留言区记录你的思考过程。感谢阅读，如果你觉得这篇文章对你有帮助的话，也欢迎把它分享给更多的朋友。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>张天屹</span> 👍（139） 💬（11）<p>我觉得问题出在return m这里需要等待三个线程执行完成，但是并没有。
...
AtomicReference&lt;Integer&gt; m = new AtomicReference&lt;&gt;(Integer.MAX_VALUE);
CountDownLatch latch = new CountDownLatch(3);
for(int i=0; i&lt;3; i++) {
	executor.execute(()-&gt;{
		Integer r = null;
		try {
			r = cs.take().get();
		} catch(Exception e) {}
		save(r);
		m.set(Integer.min(m.get(), r));
		latch.countDown();
	});
	latch.await();
	return m;
}</p>2019-04-25</li><br/><li><span>小华</span> 👍（33） 💬（1）<p>看老师的意图是要等三个比较报假的线程都执行完才能执行主线程的的return  m，但是代码无法保证三个线程都执行完，和主线程执行return的顺序，因此，m的值不是准确的，可以加个线程栈栏，线程执行完计数器，来达到这效果</p>2019-04-25</li><br/><li><span>西行寺咕哒子</span> 👍（31） 💬（8）<p>试过返回值是2147483647，也就是int的最大值。没有等待操作完成就猴急的返回了。 m.set(Integer.min(m.get(), r)... 这个操作也不是原子操作。
试着自己弄了一下：
public Integer run(){
        &#47;&#47; 创建线程池
        ExecutorService executor = Executors.newFixedThreadPool(3);
        &#47;&#47; 创建 CompletionService
        CompletionService&lt;Integer&gt; cs = new ExecutorCompletionService&lt;&gt;(executor);
        AtomicReference&lt;Integer&gt; m = new AtomicReference&lt;&gt;(Integer.MAX_VALUE);
        &#47;&#47; 异步向电商 S1 询价
        cs.submit(()-&gt;getPriceByS1());
        &#47;&#47; 异步向电商 S2 询价
        cs.submit(()-&gt;getPriceByS2());
        &#47;&#47; 异步向电商 S3 询价
        cs.submit(()-&gt;getPriceByS3());
        &#47;&#47; 将询价结果异步保存到数据库
        &#47;&#47; 并计算最低报价
        for (int i=0; i&lt;3; i++) {
            Integer r = logIfError(()-&gt;cs.take().get());
            executor.execute(()-&gt; save(r));
            m.getAndUpdate(v-&gt;Integer.min(v, r));
        }
        return m.get();
    }
不知道可不可行</p>2019-04-25</li><br/><li><span>ipofss</span> 👍（17） 💬（2）<p>老师，并发工具类，这整个一章，感觉听完似懂非懂的，因为实践中没用过，我要如何弥补这部分，还是说只要听说过，然后用的时候再去查看demo吗</p>2019-10-23</li><br/><li><span>linqw</span> 👍（8） 💬（1）<p>老师stampedLock的获取锁源码，老师能帮忙解惑下么？阻塞的读线程cowait是挂在写节点的下方么？老师能解惑下基于的理论模型
private long acquireWrite(boolean interruptible, long deadline) {
        WNode node = null, p;
        for (int spins = -1;;) { &#47;&#47; spin while enqueuing
            long m, s, ns;
            &#47;&#47;如果当前的state是无锁状态即100000000
            if ((m = (s = state) &amp; ABITS) == 0L) {
            	&#47;&#47;设置成写锁
                if (U.compareAndSwapLong(this, STATE, s, ns = s + WBIT))
                    return ns;
            }
            else if (spins &lt; 0)
            	&#47;&#47;当前锁状态为写锁状态，并且队列为空，设置自旋值
                spins = (m == WBIT &amp;&amp; wtail == whead) ? SPINS : 0;
            else if (spins &gt; 0) {
            	&#47;&#47;自旋操作，就是让线程在此自旋
                if (LockSupport.nextSecondarySeed() &gt;= 0)
                    --spins;
            }
            &#47;&#47;如果队列尾元素为空，初始化队列
            else if ((p = wtail) == null) { &#47;&#47; initialize queue
                WNode hd = new WNode(WMODE, null);
                if (U.compareAndSwapObject(this, WHEAD, null, hd))
                    wtail = hd;
            }
            &#47;&#47;当前要加入的元素为空，初始化当前元素，前置节点为尾节点
            else if (node == null)
                node = new WNode(WMODE, p);
            &#47;&#47;队列的稳定性判断，当前的前置节点是否改变，重新设置    
            else if (node.prev != p)
                node.prev = p;
            &#47;&#47;将当前节点加入尾节点中    
            else if (U.compareAndSwapObject(this, WTAIL, p, node)) {
                p.next = node;
                break;
            }
        }

        </p>2019-04-25</li><br/><li><span>Sunqc</span> 👍（3） 💬（1）<p>&#47;&#47; 获取电商 S1 报价并保存
r=f1.get();
executor.execute(()-&gt;save(r));

如果把r=f1.get（）放进execute里应该是也能保证先执行完的先保存</p>2019-05-01</li><br/><li><span>黄海峰</span> 👍（3） 💬（1）<p>我实际测试了第一段代码，确实是异步的，f1.get不会阻塞主线程。。。

public static void main(String[] args) {
        ExecutorService executor = Executors.newFixedThreadPool(3);
        Future&lt;Integer&gt; f1 = executor.submit(()-&gt;getPriceByS1());
        Future&lt;Integer&gt; f2 = executor.submit(()-&gt;getPriceByS2());
        Future&lt;Integer&gt; f3 = executor.submit(()-&gt;getPriceByS3());

        executor.execute(()-&gt; {
            try {
                save(f1.get());
            } catch (InterruptedException e) {
                e.printStackTrace();
            } catch (ExecutionException e) {
                e.printStackTrace();
            }
        });
        executor.execute(()-&gt; {
            try {
                save(f2.get());
            } catch (InterruptedException e) {
                e.printStackTrace();
            } catch (ExecutionException e) {
                e.printStackTrace();
            }
        });
        executor.execute(()-&gt; {
            try {
                save(f3.get());
            } catch (InterruptedException e) {
                e.printStackTrace();
            } catch (ExecutionException e) {
                e.printStackTrace();
            }
        });
    }

    private static Integer getPriceByS1() {
        try {
            Thread.sleep(10000);
        } catch (InterruptedException e) {
            e.printStackTrace();
        }
        return 1;
    }
    private static Integer getPriceByS2() {
        try {
            Thread.sleep(1000);
        } catch (InterruptedException e) {
            e.printStackTrace();
        }
        return 2;
    }
    private static Integer getPriceByS3() {
        try {
            Thread.sleep(1000);
        } catch (InterruptedException e) {
            e.printStackTrace();
        }
        return 3;
    }
    private static void save(Integer i) {
        System.out.println(&quot;save &quot; + i);
    }</p>2019-04-25</li><br/><li><span>Corner</span> 👍（3） 💬（1）<p>1.AtomicReference&lt;Integer&gt;的get方法应该改成使用cas方法
2.最后筛选最小结果的任务是异步执行的，应该在return之前做同步，所以最好使用sumit提交该任务便于判断任务的完成
最后请教老师一下，第一个例子中为什么主线程会阻塞在f1.get()方法呢？</p>2019-04-25</li><br/><li><span>空空空空</span> 👍（2） 💬（1）<p>算低价的时候是用三个不同的线程去计算，是异步的，因此可能算出来并不是预期的结果
老师，这样理解对吗？</p>2019-04-25</li><br/><li><span>梅小西</span> 👍（1） 💬（1）<p>老师讲的挺不错的，看了这个例子，有几点疑问，还希望老师说明下：
&#47;&#47; 这个是老师例子：

&#47;&#47; 创建线程池
ExecutorService executor = 
  Executors.newFixedThreadPool(3);
&#47;&#47; 创建CompletionService
CompletionService&lt;Integer&gt; cs = new 
  ExecutorCompletionService&lt;&gt;(executor);
&#47;&#47; 异步向电商S1询价
cs.submit(()-&gt;getPriceByS1());
&#47;&#47; 异步向电商S2询价
cs.submit(()-&gt;getPriceByS2());
&#47;&#47; 异步向电商S3询价
cs.submit(()-&gt;getPriceByS3());
&#47;&#47; 将询价结果异步保存到数据库
for (int i=0; i&lt;3; i++) {
  Integer r = cs.take().get();
  executor.execute(()-&gt;save(r));
}

首先，CompletionService应该是要绑定泛型，代表异步任务的返回结果，实际应用中，几乎不太可能所有的异步任务的返回类型是一样的，除非设置成Object这种通用型，那又会导致拿到结果后需要强转，代码看起来更难受；
其次，对于返回的结果的处理方式，实际应用中几乎也是不同的，那就要针对每一个take出来的结果做判断，这实际上也是会导致代码很难维护；

综上，CompletionService 看来能够做批量处理异步任务的事情，实际应用中，我感觉不太实用！

以上两点是个人见解，有不对之处请老师指教！</p>2019-10-27</li><br/><li><span>helloworld</span> 👍（1） 💬（1）<p>老师，冒昧的问下：在文章刚开始的例子，无论是三个询价任务（通过submit方法提交），还是保存询价任务（通过execute方法提交）都是异步的执行执行的啊！如果s1询价的时间过长的话，也不会影响到s2保存保价的先执行啊！他只影响到s1保存询价的动作。老师不知道我说的有么有道理，有问题请老师帮忙指正</p>2019-08-30</li><br/><li><span>胡小禾</span> 👍（1） 💬（1）<p>&#47;&#47; 创建线程池
ExecutorService executor =
  Executors.newFixedThreadPool(3);
&#47;&#47; 创建 CompletionService
CompletionService&lt;Integer&gt; cs =
  new ExecutorCompletionService&lt;&gt;(executor);
&#47;&#47; 用于保存 Future 对象
List&lt;Future&lt;Integer&gt;&gt; futures =
  new ArrayList&lt;&gt;(3);
&#47;&#47; 提交异步任务，并保存 future 到 futures 
futures.add(
  cs.submit(()-&gt;geocoderByS1()));
futures.add(
  cs.submit(()-&gt;geocoderByS2()));
futures.add(
  cs.submit(()-&gt;geocoderByS3()));
&#47;&#47; 获取最快返回的任务执行结果
Integer r = 0;
try {
  &#47;&#47; 只要有一个成功返回，则 break
  for (int i = 0; i &lt; 3; ++i) {
    r = cs.take().get();
    &#47;&#47; 简单地通过判空来检查是否成功返回
    if (r != null) {
      break;
    }
  }
  &#47;&#47; **********************************
  &#47;&#47; for 循环其实没有必要吧？
  &#47;&#47; take() 是阻塞的拿到结果，get()也是阻塞的
  &#47;&#47; 只要有个任务完成，这个for循环就结束了
} finally {
  &#47;&#47; 取消所有任务
  for(Future&lt;Integer&gt; f : futures)
    f.cancel(true);
}
&#47;&#47; 返回结果
return r;
</p>2019-07-09</li><br/><li><span>Joker</span> 👍（0） 💬（1）<p>老师，那个futures保存future就是为了后面取消(`cancel()`)，对吧</p>2019-11-06</li><br/><li><span>倚梦流</span> 👍（0） 💬（1）<p>请问老师，任务操作中包含io操作，比如正在增删读写文件，这时候突然cancel，会有什么不良影响吗？或者任务里面包含数据库操作，如果突然cancel，岂不是需要在异步任务中，进行事务回滚？</p>2019-07-28</li><br/><li><span>胡小禾</span> 👍（0） 💬（1）<p>请教下老师，实际生产中，使用BlockingQueue 时，
若重启实例，BQ 的任务可能会丢，对此有何通用方案？</p>2019-07-09</li><br/>
</ul>