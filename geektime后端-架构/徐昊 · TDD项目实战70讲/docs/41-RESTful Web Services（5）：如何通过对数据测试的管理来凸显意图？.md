你好，我是徐昊。今天我们继续使用TDD的方式实现RESTful Web Services。

## 回顾架构愿景与任务列表

在上节课最后的视频演示中，我们发现了新的扩展点HeaderDelegate，调整后的架构愿景如下图所示：

![](https://static001.geekbang.org/resource/image/ed/2e/ed95e0629105b3fe661590be6ab4af2e.jpg?wh=2284x1285)  
![](https://static001.geekbang.org/resource/image/aa/56/aacdc2230e337d593308c0184b799956.jpg?wh=2284x1285)

调整后的任务列表为：

- ResourceServlet
  
  - 将请求派分给对应的资源（Resource），并根据返回的状态、超媒体类型、内容，响应Http请求
    
    - 使用OutboundResponse的status作为Http Response的状态
    - 使用OutboundResponse的headers作为Http Response的Http Headers
    - 通过MessageBodyWriter将OutboundResponse的GenericEntity写回为Body
    - 如果找不到对应的MessageBodyWriter，则返回500族错误
  - 当资源方法抛出异常时，根据异常影响Http请求
    
    - 如果抛出WebApplicationException，且response不为null，则使用response响应Http
    - 如果抛出WebApplicationException，而response为null，则通过异常的具体类型查找ExceptionMapper，生产response响应Http请求
    - 如果抛出的不是WebApplicationException，则通过异常的具体类型查找ExceptionMapper，生产response响应Http请求
- RuntimeDelegate
  
  - 为MediaType提供HeaderDelegate
  - 为CacheControl提供HeaderDelegate
  - 为Cookie提供HeaderDelegates
  - 为EntityTag提供HeaderDelegate
  - 为Link提供HeaderDelegate
  - 为NewCookie提供HeaderDelegate
  - 为Date提供HeaderDelegate

代码为：

```
package geektime.tdd.rest;

import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.ws.rs.core.MultivaluedMap;
import jakarta.ws.rs.ext.RuntimeDelegate;
import java.io.IOException;

public class ResourceServlet extends HttpServlet {

    private Runtime runtime;
    
    public ResourceServlet(Runtime runtime) {
        this.runtime = runtime;
    }
    
    @Override
    protected void service(HttpServletRequest req, HttpServletResponse resp) throws ServletException, IOException {
        ResourceRouter router = runtime.getResourceRouter();
        OutboundResponse response = router.dispatch(req, runtime.createResourceContext(req, resp));
        resp.setStatus(response.getStatus());
        MultivaluedMap<String, Object> headers = response.getHeaders();
        for (String name : headers.keySet())
            for (Object value : headers.get(name)) {
                RuntimeDelegate.HeaderDelegate headerDelegate = RuntimeDelegate.getInstance().createHeaderDelegate(value.getClass());
                resp.addHeader(name, headerDelegate.toString(value));
            }
    }
}
```

## 视频演示

下面让我们继续：

## 思考题

在进入下节课之前，希望你能认真思考如下两个问题，并选择最有感触的一道进行回答。

1. 有哪些模式可以帮助简化测试数据的管理？
2. 对于重构与重写，你的理解是什么？

欢迎把你的想法分享在留言区，也欢迎把你的项目代码分享出来。相信经过你的思考与实操，学习效果会更好！
<div><strong>精选留言（2）</strong></div><ul>
<li><span>aoe</span> 👍（1） 💬（0）<p>学习感言
1、终于见到了 Builder 模式是怎么写出来的，之前都是自动生成的，不会写！
2、OutboundResponseBuilder 让构造测试数据变的超级简单，太神奇了！

对于重构与重写，你的理解是什么？
重构：在已有功能测试的保障下，按自己的喜好修改代码，但需要保证功能不变，老代码也会随之改变
重写：根据现有功能，按自己的喜好模仿出另一套功能一样的代码，不用理会老代码，也不会影响老代码

代码 https:&#47;&#47;github.com&#47;wyyl1&#47;geektime-tdd-framework&#47;tree&#47;5</p>2022-06-17</li><br/><li><span>张铁林</span> 👍（0） 💬（0）<p>https:&#47;&#47;github.com&#47;vfbiby&#47;tdd-restful
步骤加代码</p>2022-06-20</li><br/>
</ul>