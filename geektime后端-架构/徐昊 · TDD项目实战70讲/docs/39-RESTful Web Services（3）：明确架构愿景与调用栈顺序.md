你好，我是徐昊。今天我们继续使用TDD的方式实现RESTful Web Services。

在上节课，我们通过Spike将DI容器引入了实现，代码如下：

```
static class ResourceServlet extends HttpServlet {
    private final Context context;
    private TestApplication application;
    private Providers providers;
    public ResourceServlet(TestApplication application, Providers providers) {
        this.application = application;
        this.providers = providers;
        context = application.getContext();
    }
    
    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws ServletException, IOException {
        Stream<Class<?>> rootResources = application.getClasses().stream().filter(c -> c.isAnnotationPresent(Path.class));

        ResourceContext rc = application.createResourceContext(req, resp);
        Object result = dispatch(req, rootResources, rc);
        MessageBodyWriter<Object> writer = (MessageBodyWriter<Object>) providers.getMessageBodyWriter(result.getClass(), null, null, null);
        writer.writeTo(result, null, null, null, null, null, resp.getOutputStream());
    }
    
    Object dispatch(HttpServletRequest req, Stream<Class<?>> rootResources, ResourceContext rc) {
        try {
            Class<?> rootClass = rootResources.findFirst().get();
            Object rootResource = rc.initResource(context.get(ComponentRef.of(rootClass)).get());
            Method method = Arrays.stream(rootClass.getMethods()).filter(m -> m.isAnnotationPresent(GET.class)).findFirst().get();
            return method.invoke(rootResource);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }
}
```

在这个Spike的基础上，我们可以进一步细化架构的愿景：

![](https://static001.geekbang.org/resource/image/c4/4b/c4yyfbbe0e0361571e7352f4eefc474b.jpg?wh=2284x1285)

## 明确调用栈顺序

接下来需要稍微Spike一下的，就是Resource Dispatcher的部分：

根据Spike的结果，我们可以得到这部分的架构愿景和调用栈顺序：

![](https://static001.geekbang.org/resource/image/69/f9/69187acce0858b870364248b0f5f99f9.jpg?wh=2284x1285)  
![](https://static001.geekbang.org/resource/image/10/a1/102dee363b2a45734c24ee4ef20c39a1.jpg?wh=2284x1285)  
如上图所示，为大致的组件划分。

- ResourceServlet：以Servlet的形式作为入口，处理Http请求。
- Application：指明RESTful应用所需的所有组件，比如Root Resource、Providers等，也是对于框架提供的服务的访问入口。
- ResourceRouter：Http请求派发算法的实现载体。
- Providers：三个扩展点，也就是MessageBodyWriter，MessageBodyReader以及ExceptionMapper。

明确了这些之后，就可以进入分解任务的环节了。但是，在这之前，我们要如何处理Spike代码呢？

## 思考题

在进入下节课之前，希望你能认真思考如下两个问题。

1. 在当前架构愿景下，我们要如何分解任务？
2. 关于架构愿景的学习，你有什么收获吗？

欢迎把你的想法分享在留言区，也欢迎把你的项目代码分享出来。相信经过你的思考与实操，学习效果会更好！
<div><strong>精选留言（3）</strong></div><ul>
<li><span>aoe</span> 👍（1） 💬（1）<p>留下代码 https:&#47;&#47;github.com&#47;wyyl1&#47;geektime-tdd-framework&#47;tree&#47;3</p>2022-06-16</li><br/><li><span>张铁林</span> 👍（1） 💬（0）<p>https:&#47;&#47;github.com&#47;vfbiby&#47;tdd-restful
</p>2022-06-18</li><br/><li><span>范飞扬</span> 👍（0） 💬（0）<p>好吧，原来dispatcher 变成了ResourceRouter，我说怎么组件元素变少了</p>2024-04-29</li><br/>
</ul>