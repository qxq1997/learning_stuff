你好，我是郭屹。今天我们继续手写MiniTomcat。

上一节课结束后，我们引入了Container对Servlet进行管理，将原本的Connector功能职责进行拆分，让它专门负责通信的管理。并且在第二个部分中，把Container进一步封装成Wrapper，实现Servlet更加精确、完善的管理。

事实上，Tomcat把Wrapper也看作一种容器，也就是隶属于Context之下的子容器（Child Container），所以在原理上是存在多层容器的。一个Server对外提供HTTP服务，它的内部支持管理多个虚拟主机，而每个虚拟主机下又有多个应用，在每个应用内又包含多个Servlet。因此Container存在多个，属于层层嵌套的关系。

![图片](https://static001.geekbang.org/resource/image/4d/5c/4d787012c15e8034a5167a341c3a0a5c.png?wh=1920x1184)

按照Tomcat官方的定义，自外向内分别分为Engine层、Host层、Context层与Wrapper层。我们也参考这个思路，把ServletContainer改成Context，但是我们不打算实现Engine和Host，只用两层Container。

不考虑使用这么多层Container的主要原因在于，Engine与Host本身的结构复杂，而且其思想已经不再符合现在的主流，现在我们使用了容器技术之后，Engine和Host的概念已经弱化很多了。实际上，当我们部署的时候，一个Tomcat一般就只用一个Engine和一个Host，如果需要多个，就用多个容器。用Context和Wrapper两层容器也可以明白地说明Tomcat的多层容器的概念。

实现了这些功能之后，我们的MiniTomcat也变得有模有样了。但是如果所有的类全部都放在Server包下，显然是不合适的，所以我们还会参考实际的Tomcat项目结构，把各部分代码文件分门别类地整理好。

接下来我们一起来动手实现。

## 项目结构

这节课的项目结构中我们新增Container接口和ContainerBase两个文件，把原来的ServletContainer改名为ServletContext，其他的暂时没有什么变化。

```plain
MiniTomcat
├─ src
│  ├─ main
│  │  ├─ java
│  │  │  ├─ server
│  │  │  │  ├─ Container.java
│  │  │  │  ├─ ContainerBase.java
│  │  │  │  ├─ CookieTools.java
│  │  │  │  ├─ DefaultHeaders.java
│  │  │  │  ├─ HttpConnector.java
│  │  │  │  ├─ HttpHeader.java
│  │  │  │  ├─ HttpProcessor.java
│  │  │  │  ├─ HttpRequest.java
│  │  │  │  ├─ HttpRequestFacade.java
│  │  │  │  ├─ HttpRequestLine.java
│  │  │  │  ├─ HttpResponse.java
│  │  │  │  ├─ HttpResponseFacade.java
│  │  │  │  ├─ HttpServer.java
│  │  │  │  ├─ Request.java
│  │  │  │  ├─ Response.java
│  │  │  │  ├─ ServletContext.java
│  │  │  │  ├─ ServletProcessor.java
│  │  │  │  ├─ ServletWrapper.java
│  │  │  │  ├─ Session.java
│  │  │  │  ├─ SessionFacade.java
│  │  │  │  ├─ SocketInputStream.java
│  │  │  │  ├─ StatisResourceProcessor.java
│  │  ├─ resources
│  ├─ test
│  │  ├─ java
│  │  │  ├─ test
│  │  │  │  ├─ HelloServlet.java
│  │  │  │  ├─ TestServlet.java
│  │  ├─ resources
├─ webroot
│  ├─ test
│  │  ├─ HelloServlet.class
│  │  ├─ TestServlet.class
│  ├─ hello.txt
├─ pom.xml
```

## Context结构改造

基于之前的积累，我们先进行一层抽象，定义一个Container类。

```java
package server;
public interface Container {
    public static final String ADD_CHILD_EVENT = "addChild";
    public static final String REMOVE_CHILD_EVENT = "removeChild";
    public String getInfo();
    public ClassLoader getLoader();
    public void setLoader(ClassLoader loader);
    public String getName();
    public void setName(String name);
    public Container getParent();
    public void setParent(Container container);
    public void addChild(Container child);
    public Container findChild(String name);
    public Container[] findChildren();
    public void invoke(HttpServletRequest request, HttpServletResponse response)
            throws IOException, ServletException;
    public void removeChild(Container child);
}
```

可以看到有Classloader的操作方法、Child和Parent的操作方法，还有invoke等基础方法。

因为存在多层Container，很多特性是共有的，所以我们再定义ContainerBase作为基础类，你可以看一下ContainerBase的定义。

```java
package server;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
public abstract class ContainerBase implements Container {
    //子容器
    protected Map<String, Container> children = new ConcurrentHashMap<>();
    //类加载器
    protected ClassLoader loader = null;
    protected String name = null;
    //父容器
    protected Container parent = null;
    
    //下面是基本的get和set方法
    public abstract String getInfo();
    public ClassLoader getLoader() {
        if (loader != null)
            return (loader);
        if (parent != null)
            return (parent.getLoader());
        return (null);
    }
    public synchronized void setLoader(ClassLoader loader) {
        ClassLoader oldLoader = this.loader;
        if (oldLoader == loader) {
            return;
        }
        this.loader = loader;
    }
    public String getName() {
        return (name);
    }

    public void setName(String name) {
        this.name = name;
    }
    public Container getParent() {
        return (parent);
    }

    public void setParent(Container container) {
        Container oldParent = this.parent;
        this.parent = container;
    }

    //下面是对children map的增删改查操作
    public void addChild(Container child) {
        addChildInternal(child);
    }
    private void addChildInternal(Container child) {
        synchronized(children) {
            if (children.get(child.getName()) != null)
                throw new IllegalArgumentException("addChild:  Child name '" +
                        child.getName() +
                        "' is not unique");
            child.setParent((Container) this);  
            children.put(child.getName(), child);
        }
    }
    public Container findChild(String name) {
        if (name == null)
            return (null);
        synchronized (children) {       // Required by post-start changes
            return ((Container) children.get(name));
        }
    }

    public Container[] findChildren() {
        synchronized (children) {
            Container results[] = new Container[children.size()];
            return ((Container[]) children.values().toArray(results));
        }
    }
    public void removeChild(Container child) {
        synchronized(children) {
            if (children.get(child.getName()) == null)
                return;
            children.remove(child.getName());
        }
        child.setParent(null);
    }
}
```

通过上面这段代码，我们实现了Container接口，提供了部分方法的通用实现。

接下来要做的，就是把ServletContainer更名为ServletContext，我们需要改动几处内容。

第一处：HttpServer.java

```java
public class HttpServer {
    public static final String WEB_ROOT =
            System.getProperty("user.dir") + File.separator + "webroot";
    public static void main(String[] args) {
        HttpConnector connector = new HttpConnector();
        ServletContext container = new ServletContext();
        connector.setContainer(container);
        container.setConnector(connector);
        connector.start();
    }
}
```

这里的Container替换为ServletContext类了。

第二处：HttpConnector.java

```java
public class HttpConnector implements Runnable {
    ServletContext container = null;
    public ServletContext getContainer() {
        return container;
    }
    public void setContainer(ServletContext container) {
        this.container = container;
    }
}
```

第三处：ServletWrapper.java

```java
public class ServletWrapper extends ContainerBase{
    private Servlet instance = null;
    private String servletClass;
    public ServletWrapper(String servletClass,ServletContext parent) {
        this.parent = parent;
        this.servletClass = servletClass;
        try {
            loadServlet();
        } catch (ServletException e) {
            e.printStackTrace();
        }
    }
}
```

ServletContext是Wrapper的parent。

调整完类名之后，我们让ServletContext继承ContainerBase基类，ServletWrapper也可以算作Container，所以也继承ContainerBase基类。

首先是ServletContext.java，你可以看一下我们调整的部分。

```java
package server;
import javax.servlet.ServletException;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.File;
import java.io.IOException;
import java.net.URL;
import java.net.URLClassLoader;
import java.net.URLStreamHandler;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
public class ServletContext extends ContainerBase{
    //与本容器关联的connector
    HttpConnector connector = null;
    //内部管理的servlet类和实例
    Map<String,String> servletClsMap = new ConcurrentHashMap<>(); //servletName - ServletClassName
    Map<String,ServletWrapper> servletInstanceMap = new ConcurrentHashMap<>();//servletName - servletWrapper
    public ServletContext() {
        try {
            // create a URLClassLoader
            URL[] urls = new URL[1];
            URLStreamHandler streamHandler = null;
            File classPath = new File(HttpServer.WEB_ROOT);
            String repository = (new URL("file", null, classPath.getCanonicalPath() + File.separator)).toString() ;
            urls[0] = new URL(null, repository, streamHandler);
            loader = new URLClassLoader(urls);
        } catch (IOException e) {
            System.out.println(e.toString() );
        }
    }
    public String getInfo() {
        return "Minit Servlet Context, vesion 0.1";
    }
    public HttpConnector getConnector() {
        return connector;
    }
    public void setConnector(HttpConnector connector) {
        this.connector = connector;
    }
    //调用servlet的方法
    public void invoke(HttpServletRequest request, HttpServletResponse response)
            throws IOException, ServletException {
        ServletWrapper servletWrapper = null;
        String uri = ((HttpRequest)request).getUri();
        String servletName = uri.substring(uri.lastIndexOf("/") + 1);
        String servletClassName = servletName;
        //从容器中获取servlet wrapper
        servletWrapper = servletInstanceMap.get(servletName);
        if ( servletWrapper == null) {
            servletWrapper = new ServletWrapper(servletClassName,this);
            //servletWrapper.setParent(this);
            this.servletClsMap.put(servletName, servletClassName);
            this.servletInstanceMap.put(servletName, servletWrapper);
        }
        //将调用传递到下层容器即wrapper中
        try {
            HttpServletRequest requestFacade = new HttpRequestFacade(request);
            HttpServletResponse responseFacade = new HttpResponseFacade(response);
            System.out.println("Call service()");
            servletWrapper.invoke(requestFacade, responseFacade);
        }
        catch (Exception e) {
            System.out.println(e.toString());
        }
        catch (Throwable e) {
            System.out.println(e.toString());
        }
    }
}
```

上述代码中，HttpRequestFacade和HttpResponseFacade两个类的构造函数的入参和invoke方法保持一致，也需要对应地做一些调整。

```java
package server;
public class HttpRequestFacade implements HttpServletRequest {
    public HttpRequestFacade(HttpServletRequest request) {
        this.request = request;
    }
}
```

```java
package server;
public class HttpResponseFacade implements HttpServletResponse {
    public HttpResponseFacade(HttpServletResponse response) {
        this.response = response;
    }
}
```

接下来我们关注一下ServletWrapper类的调整。

```java
package server;
public class ServletWrapper extends ContainerBase{
    //wrapper内含了一个servlet实例和类
    private Servlet instance = null;
    private String servletClass;
    
    public ServletWrapper(String servletClass,ServletContext parent) {
        //以ServletContext为parent
        this.parent = parent;
        this.servletClass = servletClass;
        try {
            loadServlet();
        } catch (ServletException e) {
            e.printStackTrace();
        }
    }
    public String getServletClass() {
        return servletClass;
    }
    public void setServletClass(String servletClass) {
        this.servletClass = servletClass;
    }
    public Servlet getServlet(){
        return this.instance;
    }
    //load servlet类，创建新实例，并调用init()方法
    public Servlet loadServlet() throws ServletException {
        if (instance!=null)
            return instance;
        Servlet servlet = null;
        String actualClass = servletClass;
        if (actualClass == null) {
            throw new ServletException("servlet class has not been specified");
        }
        ClassLoader classLoader = getLoader();
        Class classClass = null;
        try {
            if (classLoader!=null) {
                classClass = classLoader.loadClass(actualClass);
            }
        }
        catch (ClassNotFoundException e) {
            throw new ServletException("Servlet class not found");
        }
        try {
            servlet = (Servlet) classClass.newInstance();
        }
        catch (Throwable e) {
            throw new ServletException("Failed to instantiate servlet");
        }
        try {
            servlet.init(null);
        }
        catch (Throwable f) {
            throw new ServletException("Failed initialize servlet.");
        }
        instance =servlet;
        return servlet;
    }
    //wrapper是最底层容器，调用将转化为service()方法
    public void invoke(HttpServletRequest request, HttpServletResponse response)
            throws IOException, ServletException {
        if (instance != null) {
            instance.service(request, response);
        }
    }
    @Override
    public String getInfo() {
        return "Minit Servlet Wrapper, version 0.1";
    }
    public void addChild(Container child) {}
    public Container findChild(String name) {return null;}
    public Container[] findChildren() {return null;}
    public void removeChild(Container child) {}
}
```

ServletWrapper继承了ContainerBase抽象类，主要有两个变化。

1. 原本定义的loader、name、parent域直接使用ContainerBase里的定义。
2. 实现getInfo、addChild、findChild、findChildren、removeChild方法。

到这里我们就改造完了。

## 向Tomcat目录对齐

在这一部分我们开始参考Tomcat的目录结构，来梳理MiniTomcat的程序结构。在Tomcat的项目结构中，主要的类都放在org.apache.catalina包里，基本的子包有startup、core、connector、loader、logger、session和util等等。

我们也参考这个结构，把大的包命名为com.minit，在这个包下构建startup、core、connector、loader、logger、session、util多个子包。

为了更加规范，我们在com.minit包下新增几个接口：Connector、Context、Wrapper、Request、Response、Session、Container。其中Container直接复用之前定义的同名接口，原本定义的Request与Response两个类不再需要使用，可以直接删除。

同时，修改下面这些类的名字并实现上述接口，尽可能和Tomcat保持一致。

```plain
ServletContext改为StandardContext
ServletWrapper改为StandardWrapper
Session改为StandardSession
SessionFacade改为StandardSessionFacade
HttpRequest改为HttpRequestImpl
HttpResponse改为HttpResponseImpl
HttpServer改为Bootstrap
```

改造后的项目结构如下：

```plain
MiniTomcat
├─ src
│  ├─ main
│  │  ├─ java
│  │  │  ├─ com
│  │  │  │  ├─ minit
│  │  │  │  │  ├─ connector
│  │  │  │  │  │  ├─ http
│  │  │  │  │  │  │  ├─ DefaultHeaders.java
│  │  │  │  │  │  │  ├─ HttpConnector.java
│  │  │  │  │  │  │  ├─ HttpHeader.java
│  │  │  │  │  │  │  ├─ HttpProcessor.java
│  │  │  │  │  │  │  ├─ HttpRequestImpl.java
│  │  │  │  │  │  │  ├─ HttpRequestLine.java
│  │  │  │  │  │  │  ├─ HttpResponseImpl.java
│  │  │  │  │  │  │  ├─ ServletProcessor.java
│  │  │  │  │  │  │  ├─ SocketInputStream.java
│  │  │  │  │  │  │  ├─ StatisResourceProcessor.java
│  │  │  │  │  │  ├─ HttpRequestFacade.java
│  │  │  │  │  │  ├─ HttpResponseFacade.java
│  │  │  │  │  ├─ core
│  │  │  │  │  │  ├─ ContainerBase.java
│  │  │  │  │  │  ├─ StandardContext.java
│  │  │  │  │  │  ├─ StandardWrapper.java
│  │  │  │  │  ├─ logger
│  │  │  │  │  ├─ session
│  │  │  │  │  │  ├─ StandardSession.java
│  │  │  │  │  │  ├─ StandardSessionFacade.java
│  │  │  │  │  ├─ startup
│  │  │  │  │  │  ├─ Bootstrap.java
│  │  │  │  │  ├─ util
│  │  │  │  │  │  ├─ CookieTools.java
│  │  │  │  ├─ Connector.java
│  │  │  │  ├─ Container.java
│  │  │  │  ├─ Contexts.java
│  │  │  │  ├─ Request.java
│  │  │  │  ├─ Responses.java
│  │  │  │  ├─ Session.java
│  │  │  │  ├─ Wrapper.java
│  │  ├─ resources
│  ├─ test
│  │  ├─ java
│  │  │  ├─ test
│  │  │  │  ├─ HelloServlet.java
│  │  │  │  ├─ TestServlet.java
│  │  ├─ resources
├─ webroot
│  ├─ test
│  │  ├─ HelloServlet.class
│  │  ├─ TestServlet.class
│  ├─ hello.txt
├─ pom.xml
```

接下来我们分别定义Connector、Context、Wrapper、Request、Response、Session这几个接口。

Connector.java：

```java
package com.minit;
public interface Connector {
    public Container getContainer();
    public void setContainer(Container container);
    public String getInfo();
    public String getScheme();
    public void setScheme(String scheme);
    public Request createRequest();
    public Response createResponse();
    public void initialize();
}
```

Context.java：

```java
package com.minit;
public interface Context extends Container {
    public static final String RELOAD_EVENT = "reload";
    public String getDisplayName();
    public void setDisplayName(String displayName);
    public String getDocBase();
    public void setDocBase(String docBase);
    public String getPath();
    public void setPath(String path);
    public ServletContext getServletContext();
    public int getSessionTimeout();
    public void setSessionTimeout(int timeout);
    public String getWrapperClass();
    public void setWrapperClass(String wrapperClass);
    public Wrapper createWrapper();
    public String findServletMapping(String pattern);
    public String[] findServletMappings();
    public void reload();
}
```

Wrapper.java：

```java
package com.minit;
public interface Wrapper {
    public int getLoadOnStartup();
    public void setLoadOnStartup(int value);
    public String getServletClass();
    public void setServletClass(String servletClass);
    public void addInitParameter(String name, String value);
    public Servlet allocate() throws ServletException;
    public String findInitParameter(String name);
    public String[] findInitParameters();
    public void load() throws ServletException;
    public void removeInitParameter(String name);
}
```

Request.java：

```java
package com.minit;
public interface Request {
    public Connector getConnector();
    public void setConnector(Connector connector);
    public Context getContext();
    public void setContext(Context context);
    public String getInfo();
    public ServletRequest getRequest();
    public Response getResponse();
    public void setResponse(Response response);
    public Socket getSocket();
    public void setSocket(Socket socket);
    public InputStream getStream();
    public void setStream(InputStream stream);
    public Wrapper getWrapper();
    public void setWrapper(Wrapper wrapper);
    public ServletInputStream createInputStream() throws IOException;
    public void finishRequest() throws IOException;
    public void recycle();
    public void setContentLength(int length);
    public void setContentType(String type);
    public void setProtocol(String protocol);
    public void setRemoteAddr(String remote);
    public void setScheme(String scheme);
    public void setServerPort(int port);
}
```

Response.java：

```java
package com.minit;
public interface Response {
    public Connector getConnector();
    public void setConnector(Connector connector);
    public int getContentCount();
    public Context getContext();
    public void setContext(Context context);
    public String getInfo();
    public Request getRequest();
    public void setRequest(Request request);
    public ServletResponse getResponse();
    public OutputStream getStream();
    public void setStream(OutputStream stream);
    public void setError();
    public boolean isError();
    public ServletOutputStream createOutputStream() throws IOException;
    public void finishResponse() throws IOException;
    public int getContentLength();
    public String getContentType();
    public PrintWriter getReporter();
    public void recycle();
    public void resetBuffer();
    public void sendAcknowledgement() throws IOException;
}

```

Session.java：

```java
package com.minit;
public interface Session {
    public static final String SESSION_CREATED_EVENT = "createSession";
    public static final String SESSION_DESTROYED_EVENT = "destroySession";
    public long getCreationTime();
    public void setCreationTime(long time);
    public String getId();
    public void setId(String id);
    public String getInfo();
    public long getLastAccessedTime();
    public int getMaxInactiveInterval();
    public void setMaxInactiveInterval(int interval);
    public void setNew(boolean isNew);
    public HttpSession getSession();
    public void setValid(boolean isValid);
    public boolean isValid();
    public void access();
    public void expire();
    public void recycle();
}
```

最后再给StandardContext、StandardWrapper和StandardSession分别实现Context、Wrapper与Session接口，这节课的改造就实现完了。最后我们再来看一下调整后需要新增的实现方法。

StandardContext.java：

```java
package com.minit.core;
public class StandardContext extends ContainerBase implements Context {
    @Override
    public String getDisplayName() {
        return null;
    }
    @Override
    public void setDisplayName(String displayName) {
    }
    @Override
    public String getDocBase() {
        return null;
    }
    @Override
    public void setDocBase(String docBase) {
    }
    @Override
    public String getPath() {
        return null;
    }
    @Override
    public void setPath(String path) {
    }
    @Override
    public ServletContext getServletContext() {
        return null;
    }
    @Override
    public int getSessionTimeout() {
        return 0;
    }
    @Override
    public void setSessionTimeout(int timeout) {
    }
    @Override
    public String getWrapperClass() {
        return null;
    }
    @Override
    public void setWrapperClass(String wrapperClass) {
    }
    @Override
    public Wrapper createWrapper() {
        return null;
    }
    @Override
    public String findServletMapping(String pattern) {
        return null;
    }
    @Override
    public String[] findServletMappings() {
        return null;
    }
    @Override
    public void reload() {
    }
}
```

StandardWrapper.java：

```java
package com.minit.core;
public class StandardWrapper extends ContainerBase implements Wrapper {
   @Override
    public int getLoadOnStartup() {
        return 0;
    }
    @Override
    public void setLoadOnStartup(int value) {
    }
    @Override
    public void addInitParameter(String name, String value) {
    }
    @Override
    public Servlet allocate() throws ServletException {
        return null;
    }
    @Override
    public String findInitParameter(String name) {
        return null;
    }
    @Override
    public String[] findInitParameters() {
        return null;
    }
    @Override
    public void load() throws ServletException {
    }
    @Override
    public void removeInitParameter(String name) {
    }
}
```

StandardSession.java：

```java
package com.minit.session;
public class StandardSession implements HttpSession, Session {
   @Override
    public String getInfo() {
        return null;
    }
    @Override
    public void setNew(boolean isNew) {
    }
    @Override
    public HttpSession getSession() {
        return null;
    }
    @Override
    public boolean isValid() {
        return false;
    }
    @Override
    public void access() {
    }
    @Override
    public void expire() {
    }
    @Override
    public void recycle() {
    }
}
```

到这里我们就完成了项目结构的改造，可以看出，MiniTomcat和Tomcat已经长得比较像了。

## 测试

这节课没有新增什么对外的功能，所以测试还是和之前的测试方式一样。

## 小结

这节课我们把项目结构进一步抽象成了两层Container，分别是Context和Wrapper，Context对应于我们平常所说的一个应用，Wrapper是对应的一个Servlet的包装。在Context这个容器中有一个map包含了多个Wrapper，这样构成了父子容器的两层结构。

然后我们进一步通用化，提出ContainerBase，只要一个类基于base，就可以当成一个新的容器。通过这些手段实现了一个服务器管理多个容器，而容器又可以管理多个Servlet，层层嵌套，实现系统结构的扩展和管理清晰化。然后在此基础上，参考Tomcat的项目结构，进行对应调整，让它更贴近Tomcat源码本身。这样一来，你去阅读Tomcat源码，难度就会大大降低。

这节课代码参见：[https://gitee.com/yaleguo1/minit-learning-demo/tree/geek\_chapter11](https://gitee.com/yaleguo1/minit-learning-demo/tree/geek_chapter11)

## 思考题

学完了这节课的内容，我们来思考一个问题：我们现在的代码中，servletContext的invoke()方法仅仅只是简单地调用了子容器Wrapper的invoke()，但是原则上每一层的容器的invoke()可以另外加入本层容器特殊的逻辑，有没有合适的设计方案？

欢迎你把你想到的方案分享到评论区，也欢迎你把这节课的内容分享给其他朋友，我们下节课再见！
<div><strong>精选留言（3）</strong></div><ul>
<li><span>peter</span> 👍（0） 💬（1）<p>请教老师两个问题：
Q1：Tomcat中怎么表示多个Host？用不同的IP吗？
Q2：Engine主要功能是什么？感觉所有的主要功能都已经包含在连接处理、servlet处理了，还能有什么比较大的功能由Engine来处理？</p>2024-01-01</li><br/><li><span>HH🐷🐠</span> 👍（0） 💬（2）<p>加入本层特殊逻辑，我的想法是加入一个前置方法和后置方法， 并且子类可以重写这两个方法。</p>2024-01-01</li><br/><li><span>偶来人间，风度翩翩</span> 👍（0） 💬（0）<p>文章一开头说的【并且在第二个部分中，把 Container 进一步封装成 Wrapper，实现 Servlet 更加精确、完善的管理。】，是不是应该是【把 Servlet 进一步封装成 Wrapper，】呀？</p>2024-05-26</li><br/>
</ul>