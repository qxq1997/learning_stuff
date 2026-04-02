你好，我是郭屹。今天我们继续手写MiniTomcat。

上节课我们实现了Context类的预加载，并引入server.xml和web.xml，分别对服务端和Servlet进行自定义配置。到目前为止我们的MiniTomcat已经是一个完整的小型Tomcat了。

考虑到在目前大部分的场景中，依托于Spring框架编写的项目大多使用Tomcat服务器进行启动，而我们之前已经完成过MiniSpring框架的构建，所以很自然地，我们就会想到**将现有的MiniTomcat与之前完成的MiniSpring进行集成。**

从原理上来说，只要是按照Servlet规范实现的服务器，就可以将MiniSpring直接放在webapps目录下运行，不用做任何额外的工作。所以从道理上讲，MiniTomcat和MiniSpring的集成也是这样的。

不过，因为MiniTomcat毕竟是一个麻雀版的Tomcat，并没有完整地实现Servlet规范，所以现在这么直接绑在一起是不能顺利运行的，我们还需要做一点完善的工作。

我们先回顾一下，MiniSpring启动的时候，依赖Tomcat环境做什么事情。一切的起点都在web.xml文件中，里面定义了Listener、Filter和Servlet。为了让MiniSpring启动起来，我们要实现一个ContextLoaderListener，这个Listener的目的是启动MiniSpring的IoC容器。然后用一个DispatcherServlet来拦截一切路径，通过这个DispatcherServlet来使用MiniSpring的MVC。

![图片](https://static001.geekbang.org/resource/image/80/b7/8050b2159902d45ee645b41212489fb7.png?wh=1920x981)

但我们现在的MiniTomcat有局限性，所以需要做一些调整。

1. 首先表现在对web.xml的解析中，Listener读不了初始化参数context-param，而且Servlet还配置不了url-pattern和init-param。
2. 还有我们的Listener接口不符合servlet规范，不支持ServletContextListener，所以MiniTomcat还不能通过Listener把MiniSpring启动起来。
3. 另外，以前在HttpProcessor里只是简单地判断路径，带有/servlet/路径的就认为是要调用一个后台的Servlet，这点也需要调整一下。同时Servlet的名字是直接从URI中截取的，现在应该改用查找url-pattern通过路径匹配某个Servlet了。

现在我们一起来动手改造。

## MiniSpring中的Bean

以前在MiniSpring项目中，我们自己实现了@RequestMapping等Spring中的常用注解，并且利用注解在HelloWorldBean类中对接口进行了定义。这个bean也仍然是我们的实现目标，也就是说通过这个bean来验证MiniTomcat和MiniSpring的集成。之前bean的代码主体如下：

```java
package com.test.controller;
public class HelloWorldBean {
    @Autowired
    BaseService baseservice;
    @Autowired
    UserService userService;
    
    @RequestMapping("/test2")
    public void doTest2(HttpServletRequest request, HttpServletResponse response) {
       String str = "test 2, hello world!";
       try {
          response.getWriter().write(str);
       } catch (IOException e) {
          // TODO Auto-generated catch block
          e.printStackTrace();
       }
    }
    @RequestMapping("/test5")
    public ModelAndView doTest5(User user) {
       ModelAndView mav = new ModelAndView("test","msg",user.getName());
       return mav;
    }
    
    @Autowired
    IAction action;
    @RequestMapping("/testaop2")
    public void doTestAop2(HttpServletRequest request, HttpServletResponse response) {
       action.doSomething();
       
       String str = "test aop 2, hello world!";
       try {
          response.getWriter().write(str);
       } catch (IOException e) {
          // TODO Auto-generated catch block
          e.printStackTrace();
       }
    }  
}
```

之前我们通常是采用嵌入式的方式使Spring业务项目与Tomcat结合在一起，即项目中内嵌一个Tomcat的Web服务器，这是因为Tomcat本身提供了内嵌这一种模式。

而目前这种内嵌模式我们还没有实现，我们实现的是依托于MiniTomcat项目本身，将业务服务代码打包成App的形式，在项目中运行。这个时候MiniTomcat是一个独立运行的容器，管理多个webapp。

在后续集成过程中，我们会将MiniSpring这一项目整体编译，然后通过类似Servlet调用方式，例如 `http://localhost:8080/app/test2` 进行接口测试。

## 项目结构

这节课我们把所有的ClassLoader移到/loader目录下，然后使用server.xml和web.xml分别管理Host启动配置与Servlet加载配置，这也是我们这节课的重点，你可以看一下参考目录。

```plain
MiniTomcat
├─ conf
│  ├─ server.xml
├─ src
│  ├─ main
│  │  ├─ java
│  │  │  ├─ com
│  │  │  │  ├─ minit
│  │  │  │  │  ├─ connector
│  │  │  │  │  │  ├─ http
│  │  │  │  │  │  │  ├─ DefaultHeaders.class
│  │  │  │  │  │  │  ├─ HttpConnector.class
│  │  │  │  │  │  │  ├─ HttpHeader.class
│  │  │  │  │  │  │  ├─ HttpProcessor.class
│  │  │  │  │  │  │  ├─ HttpRequestImpl.class
│  │  │  │  │  │  │  ├─ HttpRequestLine.class
│  │  │  │  │  │  │  ├─ HttpResponseImpl.class
│  │  │  │  │  │  │  ├─ ServletProcessor.class
│  │  │  │  │  │  │  ├─ SocketInputStream.class
│  │  │  │  │  │  │  ├─ StatisResourceProcessor.class
│  │  │  │  │  │  ├─ HttpRequestFacade.class
│  │  │  │  │  │  ├─ HttpResponseFacade.class
│  │  │  │  │  ├─ core
│  │  │  │  │  │  ├─ ApplicationFilterChain.class
│  │  │  │  │  │  ├─ ApplicationFilterConfig.class
│  │  │  │  │  │  ├─ ContainerBase.class
│  │  │  │  │  │  ├─ ContainerListenerDef.class
│  │  │  │  │  │  ├─ FilterDef.class
│  │  │  │  │  │  ├─ FilterMap.class
│  │  │  │  │  │  ├─ StandardContext.class
│  │  │  │  │  │  ├─ StandardContextValve.class
│  │  │  │  │  │  ├─ StandardHost.class
│  │  │  │  │  │  ├─ StandardHostValve.class
│  │  │  │  │  │  ├─ StandardPipeline.class
│  │  │  │  │  │  ├─ StandardServletConfig.class
│  │  │  │  │  │  ├─ StandardServletContext.class
│  │  │  │  │  │  ├─ StandardWrapper.class
│  │  │  │  │  │  ├─ StandardWrapperValve.class
│  │  │  │  │  ├─ loader
│  │  │  │  │  │  ├─ CommonClassLoader.class
│  │  │  │  │  │  ├─ CommonLoader.class
│  │  │  │  │  │  ├─ WebappClassLoader.class
│  │  │  │  │  │  ├─ WebappLoader.resources.class
│  │  │  │  │  ├─ logger
│  │  │  │  │  │  ├─ Constants.class
│  │  │  │  │  │  ├─ FileLogger.class
│  │  │  │  │  │  ├─ LoggerBase.class
│  │  │  │  │  │  ├─ SystemErrLogger.class
│  │  │  │  │  │  ├─ SystemOutLogger.class
│  │  │  │  │  ├─ session
│  │  │  │  │  │  ├─ StandardSession.class
│  │  │  │  │  │  ├─ StandardSessionFacade.class
│  │  │  │  │  ├─ startup
│  │  │  │  │  │  ├─ BootStrap.class
│  │  │  │  │  ├─ util
│  │  │  │  │  │  ├─ CookieTools.class
│  │  │  │  │  │  ├─ StringManager.class
│  │  │  │  │  │  ├─ URLDecoder.class
│  │  │  │  │  ├─ valves
│  │  │  │  │  │  ├─ AccessLogValve.class
│  │  │  │  │  │  ├─ ValveBase.class
│  │  │  │  ├─ Connector.class
│  │  │  │  ├─ Container.class
│  │  │  │  ├─ ContainerEvent.class
│  │  │  │  ├─ ContainerListener.class
│  │  │  │  ├─ Context.class
│  │  │  │  ├─ InstanceEvent.class
│  │  │  │  ├─ InstanceListener.class
│  │  │  │  ├─ Loader.class
│  │  │  │  ├─ Logger.class
│  │  │  │  ├─ Pipeline.class
│  │  │  │  ├─ Request.class
│  │  │  │  ├─ Response.class
│  │  │  │  ├─ Session.class
│  │  │  │  ├─ SessionEvent.class
│  │  │  │  ├─ SessionListener.class
│  │  │  │  ├─ Valve.class
│  │  │  │  ├─ ValveContext.class
│  │  │  │  ├─ Wrapper.class
│  │  ├─ resources
│  ├─ test
│  │  ├─ java
│  │  │  ├─ test
│  │  │  │  ├─ HelloServlet.class
│  │  │  │  ├─ TestFilter.class
│  │  │  │  ├─ TestListener.class
│  │  │  │  ├─ TestServlet.class
│  │  ├─ resources
├─ webapps
│  ├─ app-minispring
│  │  ├─ WEB-INF
│  │  │  ├─ lib
│  │  │  ├─ classes
│  │  │  │  ├─ com
│  │  │  │  │  ├─ minis
│  │  │  │  │  ├─ test
│  │  │  │  ├─ applicationContext.xml
│  │  │  ├─ minisMVC-servlet.xml
│  │  │  ├─ web.xml
├─ pom.xml
```

其中app-minispring下的代码是我们从minis最终代码中编译得到的，都放置在WEB-INF/classes/com目录下，这里就不再依次列出了。

## 调整web.xml的解析

我们知道，一个应用的启动，依赖于解析web.xml，从这个XML配置文件中指定要启动的Listener和Servlet。我们的目标是通过Listener启动minis的IoC，随后所有的调用都通过DispatcherServlet，转发到应用内部进行处理。

接下来我们先看看一个标准的web.xml具备哪些元素。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<web-app version="3.0"
         xmlns="http://java.sun.com/xml/ns/javaee"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://java.sun.com/xml/ns/javaee
    http://java.sun.com/xml/ns/javaee/web-app_3_0.xsd">
    <context-param>
        <param-name>contextConfigLocation</param-name>
        <param-value>applicationContext.xml</param-value>
    </context-param>
    <listener>
        <listener-class>com.minis.web.context.ContextLoaderListener</listener-class>
    </listener>
    <servlet>
        <servlet-name>minisMVC</servlet-name>
        <servlet-class>com.minis.web.servlet.DispatcherServlet</servlet-class>
        <init-param>
            <param-name>contextConfigLocation</param-name>
            <param-value>minisMVC-servlet.xml</param-value>
        </init-param>
        <load-on-startup>1</load-on-startup>
    </servlet>
    <servlet-mapping>
        <servlet-name>minisMVC</servlet-name>
        <url-pattern>/</url-pattern>
    </servlet-mapping>
</web-app>
```

参考目前我们对web.xml的解析可以发现，`<context-param>`、`<servlet>` 标签下的 `<init-param>` 与 `<servlet-mapping>` 标签都没有解析，所以这是我们要增加的解析部分。

一个web.xml代表一个应用的配置，对应的容器是Context，所以我们要先在StandardContext中的start()方法内进行改造。

```java
    public void start(){
        Logger logger = new FileLogger();
        setLogger(logger);
        
        //scan web.xml
        String file = System.getProperty("minit.base") + File.separator + 
               this.docbase + File.separator + "WEB-INF" + File.separator + "web.xml";
        
        SAXReader reader = new SAXReader();
        Document document;
       try {
          document = reader.read(file);
          Element root = document.getRootElement();
          // 解析context-param
          List<Element> contextParams = root.elements("context-param");
          for (Element contextParam : contextParams) {
             Element element = contextParam.element("param-name");
             String paramName = element.getText();
             Element paramValueElement = contextParam.element("param-value");
             String paramValue = paramValueElement.getText();
             initParametersMap.put(paramName, paramValue);
          }
          servletContext = new StandardServletContext(this.docbase, initParametersMap);
            
          //解析servlet
          List<Element> servlets = root.elements("servlet");
            for (Element servlet : servlets) {
                Element servletname = servlet.element("servlet-name");
                String servletnamestr = servletname.getText();
                Element servletclass = servlet.element("servlet-class");
                String servletclassstr = servletclass.getText();
                //解析init-param
             Element servletInitParamElement = servlet.element("init-param");
             Element servletInitParamNameElement = servletInitParamElement.element("param-name");
             String servletInitParamName = servletInitParamNameElement.getText();
             Element servletInitParamValueElement = servletInitParamElement.element("param-value");
             String servletInitParamValue = servletInitParamValueElement.getText();
             Map<String, String> servletInitParamMap = new ConcurrentHashMap<>();
             servletInitParamMap.put(servletInitParamName, servletInitParamValue);
             servletInitParametersMap.put(servletclassstr, servletInitParamMap);
                Element loadonstartup = servlet.element("load-on-startup");
                String loadonstartupstr = null;
                if (loadonstartup != null) {
                   loadonstartupstr = loadonstartup.getText();
                }
                
                System.out.println("servlet " + servletnamestr + servletclassstr);
                this.servletClsMap.put(servletnamestr, servletclassstr);
                if (loadonstartupstr != null) {
                   getWrapper(servletnamestr);
                }
                
            }
          // 解析servlet-mapping
          List<Element> servletMappings = root.elements("servlet-mapping");
          for (Element servletMapping : servletMappings) {
             Element servletname = servletMapping.element("servlet-name");
             String servletnamestr = servletname.getText();
             Element servletclass = servletMapping.element("url-pattern");
             String urlPatternStr = servletclass.getText();
             servletMappingMap.put(urlPatternStr, servletnamestr);
          }
       } catch (DocumentException e) {
          e.printStackTrace();
       }
        System.out.println("Context started.........");
 }  
```

上面的代码列出了对 `<context-param>`、`<servlet>` 标签下的 `<init-param>` 与 `<servlet-mapping>` 标签的解析，我们分别定义initParametersMap、servletInitParamMap、servletMappingMap三个Map数据结构，来存储解析的数据。后续的程序就可以从这里获取到这些配置信息了。

然后我们再来看看Listener，我们已经说过，Listener是Tomcat和Spring的初始结合点，那么MiniSpring也是在这里与MiniTomcat进行第一次接触的。MiniSpring遵从了Servlet的规范，所以为了让我们的Minit能顺利运行MiniSpring，我们也要适配Servlet规范，支持ServletContextListener。

我们将StandardContext里用到自定义ContainerListener的地方全部替换成ServletContextListener，ServletContextListener是javax.servlet包中定义的接口。所以我们可以启动MiniSpring的ContextLoaderListener，进而启动Minis的IoC。

你可以看一下MiniSpring里对ServletContextListener的contextInitialized方法的实现。

```java
@Override
public void contextInitialized(ServletContextEvent event) {
    initWebApplicationContext(event.getServletContext());
}
```

在代码实现中，initWebApplicationContext传入了一个ServletContext类型的参数，因此在MiniTomcat中我们需要考虑做一个ServletContext接口的实现类。

在MiniTomcat中定义了StandardServletContext，你可以看一下代码的主体部分。

```java
package com.minit.core;
public class StandardServletContext implements ServletContext {
    private Map<String, String> initParametersMap = new ConcurrentHashMap<>();
    private Map<String, Object> attributeMap = new ConcurrentHashMap<>();
    private String docbase;
    public StandardServletContext() {
    }
    public StandardServletContext(String docbase, Map<String, String> initParametersMap) {
        this.initParametersMap = initParametersMap;
        this.docbase = docbase;
    }
    @Override
    public URL getResource(String s) throws MalformedURLException {
        try {
            URLStreamHandler urlStreamHandler = null;
            File classPath = new File(System.getProperty("minit.base"));
            String repository = (new URL("file", null, classPath.getCanonicalPath() + File.separator)).toString() ;
            repository = repository + this.docbase + File.separator;
            repository = repository + "WEB-INF" + File.separator;
            return new URL(null, repository + s, urlStreamHandler);
        } catch (IOException e) {
            throw new MalformedURLException(e.getMessage());
        }
    }
    @Override
    public String getInitParameter(String s) {
        return initParametersMap.get(s);
    }
    @Override
    public Object getAttribute(String s) {
        return this.attributeMap.get(s);
    }
    @Override
    public void setAttribute(String s, Object o) {
        this.attributeMap.put(s, o);
    }
}

```

为了遵从规范，需要定义的方法比较多，但我们的实际需求只是简单地将它们运行起来，以此来说明原理，我们只需要实现getResource、getInitParameter、getAttribute、setAttribute就可以了，其他的暂时用不到。后续MiniSpring启动时调用的ServletContext，其内部就是调用MiniTomcat的StandardServletContext。  
同理，在MiniToimcat的StandardWrapper里，需要调用loadServlet加载应用的Servlet，在web.xml中我们配置了DispatcherServlet。因而在loadServlet中，有一行 `servlet.init(null)`，此时我们需要进行一定的改造，传入具体的ServletConfig实现，里面包含一个Servlet的元信息，如名字、初始化参数、上下文context等。

所以我们在MiniTomcat中也就要实现一个StandardServletConfig。

```java
package com.minit.core;
public class StandardServletConfig implements ServletConfig {
    private Map<String, String> servletInitParamMap = new ConcurrentHashMap<>();
    private ServletContext servletContext;
    private String servletName;
    public StandardServletConfig(String servletName, ServletContext servletContext, Map<String, String> servletInitParamMap) {
        this.servletInitParamMap = servletInitParamMap;
        this.servletContext = servletContext;
        this.servletName = servletName;
    }
    @Override
    public String getServletName() {
        return servletName;
    }
    @Override
    public ServletContext getServletContext() {
        return this.servletContext;
    }
    @Override
    public String getInitParameter(String s) {
        return servletInitParamMap.get(s);
    }
    @Override
    public Enumeration<String> getInitParameterNames() {
        return null;
    }
}
```

这个时候StandardWrapper里的loadServlet方法需要改造一下。

```java
public Servlet loadServlet() throws ServletException {
    // Call the initialization method of this servlet
    try {
      servlet.init(new StandardServletConfig(servletClass,
            standardContext.getServletContext(),
            standardContext.getServletInitParametersMap().get(servletClass)));
    }
    catch (Throwable f) {
      throw new ServletException("Failed initialize servlet.");
    }
}
```

主要改动在于在调用servlet的init()时，将原来传入的null，改为了传入一个ServletConfig，通过这个方法的调用，我们就可以加载MiniSpring中的DispatcherServlet。注意了，这也是系统中唯一一个Servlet。

还有一处需要改动，就是我们之前调用应用的Servlet，会以路径中最后一个分隔符（/）为界，最后面一段字符串代表Servlet的名称。而我们现在调用MiniSpring的时候，则是考虑最后路径为@RequestMapping注解里配置的值，而这个时候这个值并不是Servlet的名称，其实整个系统现在只有一个Servlet，也就是DispatcherServlet，其他的都被MiniSpring封装了。因此在MiniTomcat里，解析请求路径的StandardContextValve类里的invoke方法也需要调整。

你可以看一下这个方法调整之后的样子。

```java
package com.minit.core;
final class StandardContextValve extends ValveBase {
    public void invoke(Request request, Response response, ValveContext valveContext)
        throws IOException, ServletException {
        System.out.println("StandardContextValve invoke()");
        StandardWrapper servletWrapper = null;
        String uri = ((HttpRequestImpl)request).getUri();
        //通过uri拿到pattern
        String servletPattern = uri.substring(uri.lastIndexOf("/"));
        //通过pattern找到合适的servlet名
        String servletName = this.urlMatch(servletPattern);
        StandardContext context = (StandardContext)getContainer();
        
        servletWrapper = (StandardWrapper)context.getWrapper(servletName); 
        try {
           System.out.println("Call service()");
           servletWrapper.invoke(request, response);
        }
        catch (Exception e) {
           System.out.println(e.toString());
        }
        catch (Throwable e) {
           System.out.println(e.toString());
        }
    }
    //简单的匹配规则，以url-pattern开头继任为匹配上
    private String urlMatch(String urlPattern) {
       Map<String, String> servletMappingMap = standardContext.getServletMappingMap();
       Set<String> keySet = servletMappingMap.keySet();
       for (Map.Entry<String, String> entry : servletMappingMap.entrySet()) {
          String key = entry.getKey();
          if (urlPattern.startsWith(key)) {
             return entry.getValue();
          }
       }
       return null;
    }
}
```

关键的改动在于我们解析了ServletMapping，并要求ServletMapping中定义的ServletName与Servlet标签匹配。这里如果我们指定url-pattern为斜杠（/），表示不做任何拦截。

因此在invoke方法中，我们获取到了最后一段字符串，类似 `”/test2“` 这种，就是调用到Minis的DispatcherServlet中，之后代码逻辑都转到MiniSpring中去处理了。

在这些主要的改动调整完毕后，我们编译部署，你可以看一下运行目录。

```plain
MiniTomcat
├─ conf
│  ├─ server.xml
├─ classes
│  ├─ com
│  │  ├─ minit
│  │  │  ├─ connector
│  │  │  │  ├─ http
│  │  │  ├─ core
│  │  │  ├─ loader
│  │  │  ├─ logger
│  │  │  ├─ session
│  │  │  ├─ startup
│  │  │  ├─ util
│  │  │  ├─ valves
├─ lib
├─ logs
├─ webapps
│  ├─ app-minispring
│  │  ├─ WEB-INF
│  │  │  ├─ lib
│  │  │  ├─ classes
│  │  │  │  ├─ com
│  │  │  │  │  ├─ minis
│  │  │  │  │  ├─ test
│  │  │  │  ├─ applicationContext.xml
│  │  │  ├─ minisMVC-servlet.xml
│  │  │  ├─ web.xml
├─ startup.bat
```

startup.bat是启动程序，直接双击startup.bat启动MiniTomcat和MiniSpring。你从控制台的输出中就能看到IoC和MVC分别启动了。

## 测试

在浏览器地址栏上输入 `http://localhost:8080/app-minispring/test2`，可以看到浏览器页面上输出 `”test2，hello world!“`，这样就表示MiniSpring顺利地在MiniTomcat中运行起来了。

## 小结

这节课我们将MiniSpring与MiniTomcat进行集成，构成了一个更大的框架。我们采取的方案是将MiniTomcat作为独立服务器启动，然后把MiniSpring作为一个应用装载在MiniTomcat里。

为了能够集成，我们做的改造工作是按照规范解析web.xml，增加context-param、servlet-mapping、init-param的解析。然后我们实现了ServletContextListener接口，通过Listener MiniTomcat和MiniSpring有了一个最初的结合点。后面我们又实现了ServletConfig，以便初始化DispatcherServlet，同时也不再是通过/servlet/目录来判断是否是一个servlet了，而是通过servlet mapping去获得的。

总之只要符合Servlet规范，就能将Tomcat和Spring集成起来。

这节课代码参见：[https://gitee.com/yaleguo1/minit-learning-demo/tree/geek\_chapter17](https://gitee.com/yaleguo1/minit-learning-demo/tree/geek_chapter17)

## 思考题

学完了这节课的内容，你来思考一个问题：我们现在集成后的MiniTomcat + MiniSpring跟实际的Tomcat+Spring结构上还有一些什么区别？你可以举例说明。

欢迎你把你的想法分享到评论区，也欢迎你把这节课的内容分享给其他朋友，我们下节课再见！
<div><strong>精选留言（1）</strong></div><ul>
<li><span>peter</span> 👍（1） 💬（1）<p>请教老师几个问题：
Q1：从编码角度怎么遵守servlet规范？
写出符合servlet规范的servlet，需要怎么做？查看规范文档，照着文档写吗？还是继承某个已经存在的符合规范的接口？

Q2：以前开发的项目中spring与tomcat是什么关系？
本课程中，spring是作为一个webapp，放到tomcat的应用目录中；用户请求是先到tomcat，tomcat再转发给spring；而且spring是tomcat负责启动的。总之，tomcat好像是spring的管理者。

比较早的时候，还没有使用springBoot的时候，用IDE创建一个项目，直接创建的是spring项目，直接感觉到的是spring MVC，并没有感觉到tomcat的存在，但需要配置tomcat。 此种情况下，tomcat和spring是什么关系？还是我们本专栏的关系吗？即tomcat管理spring？

现在的开发中，IDE一般都是用Idea，然后使用springBoot创建项目，直接创建的也是spring项目，也没有感觉到tomcat的存在，甚至感觉不到spring的存在。不过还是需要配置tomcat。 此种情况下，springBoot和tomcat、spring是什么样的关系？

Q3：miniSpring相当于原来的servlet处理部分吗？？
本课之前，servlet由miniT的servlet部分处理。本课集成minis以后，原来的servlet处理部分就没有了，由minis处理。这样的话，minis相当于接管了原来的servlet处理部分，相当于一个大的servlet。是这样吗？

Q4：集成mins以后，原来的静态处理部分由谁处理？
本课之前，一部分是处理servelt，另外一部分是处理静态文本文件。集成minis以后，处理静态文本文件部分是谁处理？

Q5：集成minis以后，正常的应用怎么办？
Minit集成了minis,那其他web应用怎么办？原来是把应用放在webapp目录下面，那现在怎么办？</p>2024-01-16</li><br/>
</ul>