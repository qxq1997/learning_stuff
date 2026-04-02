通过专栏前面的学习我们知道，当一个新的请求到达时，Tomcat和Jetty会从线程池里拿出一个线程来处理请求，这个线程会调用你的Web应用，Web应用在处理请求的过程中，Tomcat线程会一直阻塞，直到Web应用处理完毕才能再输出响应，最后Tomcat才回收这个线程。

我们来思考这样一个问题，假如你的Web应用需要较长的时间来处理请求（比如数据库查询或者等待下游的服务调用返回），那么Tomcat线程一直不回收，会占用系统资源，在极端情况下会导致“线程饥饿”，也就是说Tomcat和Jetty没有更多的线程来处理新的请求。

那该如何解决这个问题呢？方案是Servlet 3.0中引入的异步Servlet。主要是在Web应用里启动一个单独的线程来执行这些比较耗时的请求，而Tomcat线程立即返回，不再等待Web应用将请求处理完，这样Tomcat线程可以立即被回收到线程池，用来响应其他请求，降低了系统的资源消耗，同时还能提高系统的吞吐量。

今天我们就来学习一下如何开发一个异步Servlet，以及异步Servlet的工作原理，也就是Tomcat是如何支持异步Servlet的，让你彻底理解它的来龙去脉。

## 异步Servlet示例

我们先通过一个简单的示例来了解一下异步Servlet的实现。

```
@WebServlet(urlPatterns = {"/async"}, asyncSupported = true)
public class AsyncServlet extends HttpServlet {

    //Web应用线程池，用来处理异步Servlet
    ExecutorService executor = Executors.newSingleThreadExecutor();

    public void service(HttpServletRequest req, HttpServletResponse resp) {
        //1. 调用startAsync或者异步上下文
        final AsyncContext ctx = req.startAsync();

       //用线程池来执行耗时操作
        executor.execute(new Runnable() {

            @Override
            public void run() {

                //在这里做耗时的操作
                try {
                    ctx.getResponse().getWriter().println("Handling Async Servlet");
                } catch (IOException e) {}

                //3. 异步Servlet处理完了调用异步上下文的complete方法
                ctx.complete();
            }

        });
    }
}
```

上面的代码有三个要点：

1. 通过注解的方式来注册Servlet，除了@WebServlet注解，还需要加上`asyncSupported=true`的属性，表明当前的Servlet是一个异步Servlet。
2. Web应用程序需要调用Request对象的startAsync方法来拿到一个异步上下文AsyncContext。这个上下文保存了请求和响应对象。
3. Web应用需要开启一个新线程来处理耗时的操作，处理完成后需要调用AsyncContext的complete方法。目的是告诉Tomcat，请求已经处理完成。

这里请你注意，虽然异步Servlet允许用更长的时间来处理请求，但是也有超时限制的，默认是30秒，如果30秒内请求还没处理完，Tomcat会触发超时机制，向浏览器返回超时错误，如果这个时候你的Web应用再调用`ctx.complete`方法，会得到一个IllegalStateException异常。

## 异步Servlet原理

通过上面的例子，相信你对Servlet的异步实现有了基本的理解。要理解Tomcat在这个过程都做了什么事情，关键就是要弄清楚`req.startAsync`方法和`ctx.complete`方法都做了什么。

**startAsync方法**

startAsync方法其实就是创建了一个异步上下文AsyncContext对象，AsyncContext对象的作用是保存请求的中间信息，比如Request和Response对象等上下文信息。你来思考一下为什么需要保存这些信息呢？

这是因为Tomcat的工作线程在`request.startAsync`调用之后，就直接结束回到线程池中了，线程本身不会保存任何信息。也就是说一个请求到服务端，执行到一半，你的Web应用正在处理，这个时候Tomcat的工作线程没了，这就需要有个缓存能够保存原始的Request和Response对象，而这个缓存就是AsyncContext。

有了AsyncContext，你的Web应用通过它拿到Request和Response对象，拿到Request对象后就可以读取请求信息，请求处理完了还需要通过Response对象将HTTP响应发送给浏览器。

除了创建AsyncContext对象，startAsync还需要完成一个关键任务，那就是告诉Tomcat当前的Servlet处理方法返回时，不要把响应发到浏览器，因为这个时候，响应还没生成呢；并且不能把Request对象和Response对象销毁，因为后面Web应用还要用呢。

在Tomcat中，负责flush响应数据的是CoyoteAdapter，它还会销毁Request对象和Response对象，因此需要通过某种机制通知CoyoteAdapter，具体来说是通过下面这行代码：

```
this.request.getCoyoteRequest().action(ActionCode.ASYNC_START, this);
```

你可以把它理解为一个Callback，在这个action方法里设置了Request对象的状态，设置它为一个异步Servlet请求。

我们知道连接器是调用CoyoteAdapter的service方法来处理请求的，而CoyoteAdapter会调用容器的service方法，当容器的service方法返回时，CoyoteAdapter判断当前的请求是不是异步Servlet请求，如果是，就不会销毁Request和Response对象，也不会把响应信息发到浏览器。你可以通过下面的代码理解一下，这是CoyoteAdapter的service方法，我对它进行了简化：

```
public void service(org.apache.coyote.Request req, org.apache.coyote.Response res) {
    
   //调用容器的service方法处理请求
    connector.getService().getContainer().getPipeline().
           getFirst().invoke(request, response);
   
   //如果是异步Servlet请求，仅仅设置一个标志，
   //否则说明是同步Servlet请求，就将响应数据刷到浏览器
    if (request.isAsync()) {
        async = true;
    } else {
        request.finishRequest();
        response.finishResponse();
    }
   
   //如果不是异步Servlet请求，就销毁Request对象和Response对象
    if (!async) {
        request.recycle();
        response.recycle();
    }
}
```

接下来，当CoyoteAdapter的service方法返回到ProtocolHandler组件时，ProtocolHandler判断返回值，如果当前请求是一个异步Servlet请求，它会把当前Socket的协议处理者Processor缓存起来，将SocketWrapper对象和相应的Processor存到一个Map数据结构里。

```
private final Map<S,Processor> connections = new ConcurrentHashMap<>();
```

之所以要缓存是因为这个请求接下来还要接着处理，还是由原来的Processor来处理，通过SocketWrapper就能从Map里找到相应的Processor。

**complete方法**

接着我们再来看关键的`ctx.complete`方法，当请求处理完成时，Web应用调用这个方法。那么这个方法做了些什么事情呢？最重要的就是把响应数据发送到浏览器。

这件事情不能由Web应用线程来做，也就是说`ctx.complete`方法不能直接把响应数据发送到浏览器，因为这件事情应该由Tomcat线程来做，但具体怎么做呢？

我们知道，连接器中的Endpoint组件检测到有请求数据达到时，会创建一个SocketProcessor对象交给线程池去处理，因此Endpoint的通信处理和具体请求处理在两个线程里运行。

在异步Servlet的场景里，Web应用通过调用`ctx.complete`方法时，也可以生成一个新的SocketProcessor任务类，交给线程池处理。对于异步Servlet请求来说，相应的Socket和协议处理组件Processor都被缓存起来了，并且这些对象都可以通过Request对象拿到。

讲到这里，你可能已经猜到`ctx.complete`是如何实现的了：

```
public void complete() {
    //检查状态合法性，我们先忽略这句
    check();
    
    //调用Request对象的action方法，其实就是通知连接器，这个异步请求处理完了
request.getCoyoteRequest().action(ActionCode.ASYNC_COMPLETE, null);
    
}
```

我们可以看到complete方法调用了Request对象的action方法。而在action方法里，则是调用了Processor的processSocketEvent方法，并且传入了操作码OPEN\_READ。

```
case ASYNC_COMPLETE: {
    clearDispatches();
    if (asyncStateMachine.asyncComplete()) {
        processSocketEvent(SocketEvent.OPEN_READ, true);
    }
    break;
}
```

我们接着看processSocketEvent方法，它调用SocketWrapper的processSocket方法：

```
protected void processSocketEvent(SocketEvent event, boolean dispatch) {
    SocketWrapperBase<?> socketWrapper = getSocketWrapper();
    if (socketWrapper != null) {
        socketWrapper.processSocket(event, dispatch);
    }
}
```

而SocketWrapper的processSocket方法会创建SocketProcessor任务类，并通过Tomcat线程池来处理：

```
public boolean processSocket(SocketWrapperBase<S> socketWrapper,
        SocketEvent event, boolean dispatch) {
        
      if (socketWrapper == null) {
          return false;
      }
      
      SocketProcessorBase<S> sc = processorCache.pop();
      if (sc == null) {
          sc = createSocketProcessor(socketWrapper, event);
      } else {
          sc.reset(socketWrapper, event);
      }
      //线程池运行
      Executor executor = getExecutor();
      if (dispatch && executor != null) {
          executor.execute(sc);
      } else {
          sc.run();
      }
}
```

请你注意createSocketProcessor函数的第二个参数是SocketEvent，这里我们传入的是OPEN\_READ。通过这个参数，我们就能控制SocketProcessor的行为，因为我们不需要再把请求发送到容器进行处理，只需要向浏览器端发送数据，并且重新在这个Socket上监听新的请求就行了。

最后我通过一张在帮你理解一下整个过程：

![](https://static001.geekbang.org/resource/image/d2/ae/d2d96b7450dff9735989005958fa13ae.png?wh=1016%2A614)

## 本期精华

非阻塞I/O模型可以利用很少的线程处理大量的连接，提高了并发度，本质就是通过一个Selector线程查询多个Socket的I/O事件，减少了线程的阻塞等待。

同样，异步Servlet机制也是减少了线程的阻塞等待，将Tomcat线程和业务线程分开，Tomcat线程不再等待业务代码的执行。

那什么样的场景适合异步Servlet呢？适合的场景有很多，最主要的还是根据你的实际情况，如果你拿不准是否适合异步Servlet，就看一条：如果你发现Tomcat的线程不够了，大量线程阻塞在等待Web应用的处理上，而Web应用又没有优化的空间了，确实需要长时间处理，这个时候你不妨尝试一下异步Servlet。

## 课后思考

异步Servlet将Tomcat线程和Web应用线程分开，体现了隔离的思想，也就是把不同的业务处理所使用的资源隔离开，使得它们互不干扰，尤其是低优先级的业务不能影响高优先级的业务。你可以思考一下，在你的Web应用内部，是不是也可以运用这种设计思想呢？

不知道今天的内容你消化得如何？如果还有疑问，请大胆的在留言区提问，也欢迎你把你的课后思考和心得记录下来，与我和其他同学一起讨论。如果你觉得今天有所收获，欢迎你把它分享给你的朋友。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>echo＿陈</span> 👍（26） 💬（6）<p>我感觉，异步servlet只能说让tomcat有机会接受更多的请求，但并不能提升服务的并发吞吐量，因为如果业务操作本身还是慢的话，业务线程池仍然会被占满，后面提交的任务会等待。</p>2019-07-11</li><br/><li><span>非想</span> 👍（15） 💬（1）<p>老师您好，请问下怎么理解tomcat线程和servlet线程，它们有什么区别，又是怎么关联的呢？</p>2019-07-14</li><br/><li><span>梁中华</span> 👍（10） 💬（1）<p>异步sevlet内部的业务应用中的IO也需要异步IO支持吧，就像vertx的异步模式，否则都堵塞在业务线程上就没意义了</p>2019-07-12</li><br/><li><span>柯察金</span> 👍（5） 💬（2）<p>老师，开启了异步，感觉还是不够啊。有大量请求的时候，socket 链接都有问题。有什么进一步提升的方法吗</p>2019-07-24</li><br/><li><span>Geek_ebda96</span> 👍（4） 💬（2）<p> 老师，请问一个请求进来之后，如果采用异步servlet来处理，原来的请求tomcat线程被回收，那本身这个请求要再相应给客户端，怎么知道是哪个客户端请求过来的，是根据servlet力的request信息，获取客户端地址，相应给客户端吗？这个根你后面讲的complete有关系吗，具体是怎么相应给正确的目的地客户端？</p>2019-07-29</li><br/><li><span>FengX</span> 👍（0） 💬（1）<p>老师， 请问对Map&lt;S,Processor&gt; connections里的Processor的取出操作是在SocketWrapper的processSocket 方法里吗？</p>2019-07-13</li><br/><li><span>libocz</span> 👍（3） 💬（0）<p>老师，文章里边说ctx.complete方法不能直接把响应数据发送到浏览器，因为这件事情应该由Tomcat线程来做。这个是为什么呢？在应用线程里边的reponse直接调用write把数据写到输出流然后刷新这样不行吗？</p>2020-08-04</li><br/><li><span>new life</span> 👍（2） 💬（1）<p>感觉 异步 servlet 只是释放了一个连接器分配的线程，并没有立刻给web响应，在web上感受到的还是同步，老师 我的理解对吗</p>2019-08-07</li><br/><li><span>姑射仙人</span> 👍（1） 💬（0）<p>老师，LongPolling的实现与Servlet异步支持有什么关系吗，还有Spring中的DeferredResult。</p>2021-04-26</li><br/><li><span>惘 闻</span> 👍（1） 💬（2）<p>看晕了... SocketProcessor 到底在一个异步请求中创建了多少个啊.
1. 我们知道，连接器中的 Endpoint 组件检测到有请求数据达到时，会创建一个 SocketProcessor 对象交给线程池去处理
2. 在异步 Servlet 的场景里，Web 应用通过调用ctx.complete方法时，也可以生成一个新的 SocketProcessor 任务类，交给线程池处理。
3.而 SocketWrapper 的 processSocket 方法会创建 SocketProcessor 任务类
这是三句原话..所以是一个请求+响应一共使用了三个SocketProcessor 吗?</p>2021-01-26</li><br/><li><span>wfatec</span> 👍（1） 💬（0）<p>老师您好，我这里有一个疑惑，对于异步 servlet 来说，如果我在 filter 中执行 chain.doFilter() 之后，还需要执行 methodAfterChain() 方法，由于 servlet 是异步的，那么这个时候 methodAfterChain() 方法会等到这个异步 servlet 执行完 complete() 之后才执行，还是会立即执行呢？如果是立即执行，那么应该如何实现对返回结果的包装呢？如果不是立即执行，那原理是什么呢？</p>2019-08-16</li><br/><li><span>Geek_103c22</span> 👍（0） 💬（0）<p>异步servlet 和ajax 请求是一回事吗？</p>2024-09-23</li><br/><li><span>kobe</span> 👍（0） 💬（0）<p>这个调用Request对象的startAsync()方法应该是Tomcat调用的 而不是Web应用程序调用的吧？
</p>2022-08-15</li><br/><li><span>花花大脸猫</span> 👍（0） 💬（0）<p>这个异步的servlet只是缓解了tomcat的connection压力，对于整个应用来说这样处理问题会更大，因为对于长时间处理的业务会不断创建线程去处理，当然也可以使用线程池去处理，对于整个服务而言，感觉有点画蛇添足！！</p>2022-07-06</li><br/><li><span>YsnowLove</span> 👍（0） 💬（0）<p>1. 当一个新的请求到达时，Tomcat 和 Jetty 会从线程池里拿出一个线程来处理请求，这个线程会调用你的 Web 应用，Web 应用在处理请求的过程中，Tomcat 线程会一直阻塞，直到 Web 应用处理完毕才能再输出响应，最后 Tomcat 才回收这个线程。
2. Servlet 3.0 中引入的异步 Servlet。主要是在 Web 应用里启动一个单独的线程来执行这些比较耗时的请求，而 Tomcat 线程立即返回，不再等待 Web 应用将请求处理完....
老师：按我的理解，无论是异步还是同步，web应用都是独立一个线程处理。区别是异步，tomcat会回收线程。 这样理解对吗？  </p>2020-07-22</li><br/>
</ul>