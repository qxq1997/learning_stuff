前不久，同事小灰工作中遇到一个问题，他开发了一个Web项目：Web版的文件浏览器，通过它用户可以在浏览器里查看服务器上的目录和文件。这个项目依赖运维部门提供的文件浏览服务，而这个文件浏览服务只支持消息队列（MQ）方式接入。消息队列在互联网大厂中用的非常多，主要用作流量削峰和系统解耦。在这种接入方式中，发送消息和消费结果这两个操作之间是异步的，你可以参考下面的示意图来理解。

![](https://static001.geekbang.org/resource/image/d1/21/d1ad5ce1df66d85698308c41e4e93a21.png?wh=1142%2A393)

消息队列（MQ）示意图

在小灰的这个Web项目中，用户通过浏览器发过来一个请求，会被转换成一个异步消息发送给MQ，等MQ返回结果后，再将这个结果返回至浏览器。小灰同学的问题是：给MQ发送消息的线程是处理Web请求的线程T1，但消费MQ结果的线程并不是线程T1，那线程T1如何等待MQ的返回结果呢？为了便于你理解这个场景，我将其代码化了，示例代码如下。

```
class Message{
  String id;
  String content;
}
//该方法可以发送消息
void send(Message msg){
  //省略相关代码
}
//MQ消息返回后会调用该方法
//该方法的执行线程不同于
//发送消息的线程
void onMessage(Message msg){
  //省略相关代码
}
//处理浏览器发来的请求
Respond handleWebReq(){
  //创建一消息
  Message msg1 = new 
    Message("1","{...}");
  //发送消息
  send(msg1);
  //如何等待MQ返回的消息呢？
  String result = ...;
}
```

看到这里，相信你一定有点似曾相识的感觉，这不就是前面我们在[《15 | Lock和Condition（下）：Dubbo如何用管程实现异步转同步？》](https://time.geekbang.org/column/article/88487)中曾介绍过的异步转同步问题吗？仔细分析，的确是这样，不过在那一篇文章中我们只是介绍了最终方案，让你知其然，但是并没有介绍这个方案是如何设计出来的，今天咱们再仔细聊聊这个问题，让你知其所以然，遇到类似问题也能自己设计出方案来。

## Guarded Suspension模式

上面小灰遇到的问题，在现实世界里比比皆是，只是我们一不小心就忽略了。比如，项目组团建要外出聚餐，我们提前预订了一个包间，然后兴冲冲地奔过去，到那儿后大堂经理看了一眼包间，发现服务员正在收拾，就会告诉我们：“您预订的包间服务员正在收拾，请您稍等片刻。”过了一会，大堂经理发现包间已经收拾完了，于是马上带我们去包间就餐。

我们等待包间收拾完的这个过程和小灰遇到的等待MQ返回消息本质上是一样的，都是**等待一个条件满足**：就餐需要等待包间收拾完，小灰的程序里要等待MQ返回消息。

那我们来看看现实世界里是如何解决这类问题的呢？现实世界里大堂经理这个角色很重要，我们是否等待，完全是由他来协调的。通过类比，相信你也一定有思路了：我们的程序里，也需要这样一个大堂经理。的确是这样，那程序世界里的大堂经理该如何设计呢？其实设计方案前人早就搞定了，而且还将其总结成了一个设计模式：**Guarded Suspension**。所谓Guarded Suspension，直译过来就是“保护性地暂停”。那下面我们就来看看，Guarded Suspension模式是如何模拟大堂经理进行保护性地暂停的。

下图就是Guarded Suspension模式的结构图，非常简单，一个对象GuardedObject，内部有一个成员变量——受保护的对象，以及两个成员方法——`get(Predicate<T> p)`和`onChanged(T obj)`方法。其中，对象GuardedObject就是我们前面提到的大堂经理，受保护对象就是餐厅里面的包间；受保护对象的get()方法对应的是我们的就餐，就餐的前提条件是包间已经收拾好了，参数p就是用来描述这个前提条件的；受保护对象的onChanged()方法对应的是服务员把包间收拾好了，通过onChanged()方法可以fire一个事件，而这个事件往往能改变前提条件p的计算结果。下图中，左侧的绿色线程就是需要就餐的顾客，而右侧的蓝色线程就是收拾包间的服务员。

![](https://static001.geekbang.org/resource/image/63/dc/630f3eda98a0e6a436953153c68464dc.png?wh=1142%2A503)

Guarded Suspension模式结构图

GuardedObject的内部实现非常简单，是管程的一个经典用法，你可以参考下面的示例代码，核心是：get()方法通过条件变量的await()方法实现等待，onChanged()方法通过条件变量的signalAll()方法实现唤醒功能。逻辑还是很简单的，所以这里就不再详细介绍了。

```
class GuardedObject<T>{
  //受保护的对象
  T obj;
  final Lock lock = 
    new ReentrantLock();
  final Condition done =
    lock.newCondition();
  final int timeout=1;
  //获取受保护对象  
  T get(Predicate<T> p) {
    lock.lock();
    try {
      //MESA管程推荐写法
      while(!p.test(obj)){
        done.await(timeout, 
          TimeUnit.SECONDS);
      }
    }catch(InterruptedException e){
      throw new RuntimeException(e);
    }finally{
      lock.unlock();
    }
    //返回非空的受保护对象
    return obj;
  }
  //事件通知方法
  void onChanged(T obj) {
    lock.lock();
    try {
      this.obj = obj;
      done.signalAll();
    } finally {
      lock.unlock();
    }
  }
}
```

## 扩展Guarded Suspension模式

上面我们介绍了Guarded Suspension模式及其实现，这个模式能够模拟现实世界里大堂经理的角色，那现在我们再来看看这个“大堂经理”能否解决小灰同学遇到的问题。

Guarded Suspension模式里GuardedObject有两个核心方法，一个是get()方法，一个是onChanged()方法。很显然，在处理Web请求的方法handleWebReq()中，可以调用GuardedObject的get()方法来实现等待；在MQ消息的消费方法onMessage()中，可以调用GuardedObject的onChanged()方法来实现唤醒。

```
//处理浏览器发来的请求
Respond handleWebReq(){
  //创建一消息
  Message msg1 = new 
    Message("1","{...}");
  //发送消息
  send(msg1);
  //利用GuardedObject实现等待
  GuardedObject<Message> go
    =new GuardObjec<>();
  Message r = go.get(
    t->t != null);
}
void onMessage(Message msg){
  //如何找到匹配的go？
  GuardedObject<Message> go=???
  go.onChanged(msg);
}
```

但是在实现的时候会遇到一个问题，handleWebReq()里面创建了GuardedObject对象的实例go，并调用其get()方等待结果，那在onMessage()方法中，如何才能够找到匹配的GuardedObject对象呢？这个过程类似服务员告诉大堂经理某某包间已经收拾好了，大堂经理如何根据包间找到就餐的人。现实世界里，大堂经理的头脑中，有包间和就餐人之间的关系图，所以服务员说完之后大堂经理立刻就能把就餐人找出来。

我们可以参考大堂经理识别就餐人的办法，来扩展一下Guarded Suspension模式，从而使它能够很方便地解决小灰同学的问题。在小灰的程序中，每个发送到MQ的消息，都有一个唯一性的属性id，所以我们可以维护一个MQ消息id和GuardedObject对象实例的关系，这个关系可以类比大堂经理大脑里维护的包间和就餐人的关系。

有了这个关系，我们来看看具体如何实现。下面的示例代码是扩展Guarded Suspension模式的实现，扩展后的GuardedObject内部维护了一个Map，其Key是MQ消息id，而Value是GuardedObject对象实例，同时增加了静态方法create()和fireEvent()；create()方法用来创建一个GuardedObject对象实例，并根据key值将其加入到Map中，而fireEvent()方法则是模拟的大堂经理根据包间找就餐人的逻辑。

```
class GuardedObject<T>{
  //受保护的对象
  T obj;
  final Lock lock = 
    new ReentrantLock();
  final Condition done =
    lock.newCondition();
  final int timeout=2;
  //保存所有GuardedObject
  final static Map<Object, GuardedObject> 
  gos=new ConcurrentHashMap<>();
  //静态方法创建GuardedObject
  static <K> GuardedObject 
      create(K key){
    GuardedObject go=new GuardedObject();
    gos.put(key, go);
    return go;
  }
  static <K, T> void 
      fireEvent(K key, T obj){
    GuardedObject go=gos.remove(key);
    if (go != null){
      go.onChanged(obj);
    }
  }
  //获取受保护对象  
  T get(Predicate<T> p) {
    lock.lock();
    try {
      //MESA管程推荐写法
      while(!p.test(obj)){
        done.await(timeout, 
          TimeUnit.SECONDS);
      }
    }catch(InterruptedException e){
      throw new RuntimeException(e);
    }finally{
      lock.unlock();
    }
    //返回非空的受保护对象
    return obj;
  }
  //事件通知方法
  void onChanged(T obj) {
    lock.lock();
    try {
      this.obj = obj;
      done.signalAll();
    } finally {
      lock.unlock();
    }
  }
}
```

这样利用扩展后的GuardedObject来解决小灰同学的问题就很简单了，具体代码如下所示。

```
//处理浏览器发来的请求
Respond handleWebReq(){
  int id=序号生成器.get();
  //创建一消息
  Message msg1 = new 
    Message(id,"{...}");
  //创建GuardedObject实例
  GuardedObject<Message> go=
    GuardedObject.create(id);  
  //发送消息
  send(msg1);
  //等待MQ消息
  Message r = go.get(
    t->t != null);  
}
void onMessage(Message msg){
  //唤醒等待的线程
  GuardedObject.fireEvent(
    msg.id, msg);
}
```

## 总结

Guarded Suspension模式本质上是一种等待唤醒机制的实现，只不过Guarded Suspension模式将其规范化了。规范化的好处是你无需重头思考如何实现，也无需担心实现程序的可理解性问题，同时也能避免一不小心写出个Bug来。但Guarded Suspension模式在解决实际问题的时候，往往还是需要扩展的，扩展的方式有很多，本篇文章就直接对GuardedObject的功能进行了增强，Dubbo中DefaultFuture这个类也是采用的这种方式，你可以对比着来看，相信对DefaultFuture的实现原理会理解得更透彻。当然，你也可以创建新的类来实现对Guarded Suspension模式的扩展。

Guarded Suspension模式也常被称作Guarded Wait模式、Spin Lock模式（因为使用了while循环去等待），这些名字都很形象，不过它还有一个更形象的非官方名字：多线程版本的if。单线程场景中，if语句是不需要等待的，因为在只有一个线程的条件下，如果这个线程被阻塞，那就没有其他活动线程了，这意味着if判断条件的结果也不会发生变化了。但是多线程场景中，等待就变得有意义了，这种场景下，if判断条件的结果是可能发生变化的。所以，用“多线程版本的if”来理解这个模式会更简单。

## 课后思考

有同学觉得用done.await()还要加锁，太啰嗦，还不如直接使用sleep()方法，下面是他的实现，你觉得他的写法正确吗？

```
//获取受保护对象  
T get(Predicate<T> p) {
  try {
    while(!p.test(obj)){
      TimeUnit.SECONDS
        .sleep(timeout);
    }
  }catch(InterruptedException e){
    throw new RuntimeException(e);
  }
  //返回非空的受保护对象
  return obj;
}
//事件通知方法
void onChanged(T obj) {
  this.obj = obj;
}
```

欢迎在留言区与我分享你的想法，也欢迎你在留言区记录你的思考过程。感谢阅读，如果你觉得这篇文章对你有帮助的话，也欢迎把它分享给更多的朋友。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>一道阳光</span> 👍（64） 💬（10）<p>当从消息队列接收消息失败时，while循环会一直执行下去，永远不会结束，回占用大量资源。</p>2019-05-09</li><br/><li><span>Felix Envy</span> 👍（49） 💬（2）<p>老师，感觉如果有方法调用了GuardedObect.create方法但是没有任何其他线程调用fireEvent方法会造成内存泄漏啊，这种情况需要考虑吗？</p>2019-05-12</li><br/><li><span>zhangwei</span> 👍（40） 💬（14）<p>老师，我有个疑问，希望帮忙解答。如果Web应用是集群的，A节点处理HTTP请求后发了MQ，B节点的onMessage消费了回执消息，那么A节点怎么把结果响应给客户端呢？疑问好久了，希望老师给个思路，谢谢！</p>2019-05-18</li><br/><li><span>Mr.Brooks</span> 👍（26） 💬（2）<p>没有锁也无法保证内存可见性吧</p>2019-05-10</li><br/><li><span>朵朵集团总裁</span> 👍（10） 💬（1）<p>如果mq服务挂了无法消费，会引起web请求服务很多线程出于等待状态，是不是应该whlie循环加上超时。</p>2020-04-01</li><br/><li><span>张三</span> 👍（9） 💬（1）<p>接入微信支付支付宝支付里边，也需要提供一个回调函数，onChange()就是一个回调函数吧，不过微信支付宝支付是异步回调，是不是也可以改成这种？微信支付宝里边的其它第三方支付是不是就是这种模式，因为支付成功之后跳转到它们自己的页面，而不是微信支付宝官方的支付成功界面</p>2019-05-10</li><br/><li><span>飞翔</span> 👍（7） 💬（3）<p>老师 future.get 就是guarded suspension 的应用吧</p>2019-09-24</li><br/><li><span>庄墨寒</span> 👍（7） 💬（1）<p>老师, 我觉得您只是举个例子吧. 真实的生成环境, A和B肯定都是一个集群; A 给 B发一个消息. B处理完后再给A发一个消息,  在A 集群中发送和接收消息的大概率两台不同的机器. 解决这个问题两种办法: 1. web 请求长轮询; 2. A集群有分布式的缓存, A的某台机器处理消息后把结果写到缓存, 处理web请求的机器有专门的线程去轮询. </p>2019-09-06</li><br/><li><span>君哥聊技术</span> 👍（7） 💬（1）<p>如果以文中的最后一段示例代码来看，每一个请求生成一个id，对应一个GuardedObject，并没有线程安全问题。我觉得可以去掉锁。
但是加sleep的话，没有办法唤醒，只能等到超时。</p>2019-05-09</li><br/><li><span>ipofss</span> 👍（5） 💬（1）<p>老师，这节听了个大概，不是非常懂。其中有一点没理解，get方法加锁后，while判断一直都为true，也就一直不会释放锁，那onChanged方法进去之后，获取不到锁，双方不久互相死等下去了么，我应该还是哪里没想明白</p>2019-10-30</li><br/><li><span>DFighting</span> 👍（5） 💬（2）<p>问题的原因主要是sleep没办法提供等待-唤醒机制，也就是说极端情况下可能会一直处于睡眠状态。
老师，有个问题，为什么sleep不能被唤醒啊？网上查了下答案，好像是说wait会持有一个对象锁(JVM)提供的，然后在执行notify操作的时候，JVM会释放这个对象锁，并选择一个等待的线程执行。而sleep并没有释放这个锁，所以没办法唤醒？感觉有点道理，但是不知道对不对，望老师不吝赐教</p>2019-09-28</li><br/><li><span>Ab</span> 👍（4） 💬（2）<p>老师， 有一个地方不太理解，扩展 Guarded Suspension 模式 这一节第一个例子，get和onChange方法应该是在同一个GuardedObject上调用的吧，为啥还有维护一个Map来存储msgId和GuardedObject之间的关系呢？</p>2019-08-26</li><br/><li><span>null</span> 👍（2） 💬（4）<p>老师，您好！
我想到了一个场景：​线程 t1 提交了消息 m1，线程 t2 提交了消息 m2，此时都在 get() 方法处等待结果返回。m2 先被处理完，this.obj 对应的是消息 m2 的结果，调用 fireEvent() 唤醒 t1 和 t2，t1 竞争到锁资源，消费了 m2 的结果 this.obj。

如果存在这种场景，再维护一个 ConcurrentHashMap，key 是 msg.id，value 是对应的 obj，是否就能解决结果这问题？

谢谢老师！</p>2019-06-03</li><br/><li><span>Monday</span> 👍（1） 💬（1）<p>guarded suspension模式解决了我工作中的一个问题
client同步掉我的服务a，服务a处理并需要等待一个定时任务的执行结果，</p>2020-12-17</li><br/><li><span>王盛武</span> 👍（1） 💬（2）<p>王老师，请问这里lock是实例私有对象，为什么不用 lock.signal？  感觉文案里的代码不需要signalall函数，因为这个lock是每次都new出来的，线程等待队列里永远只有一个线程，所以signalall意义不大</p>2019-06-17</li><br/>
</ul>