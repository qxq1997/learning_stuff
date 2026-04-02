你好，我是郭屹。

通过上节课的工作，我们就初步实现了一个原始的MVC框架，并引入了@RequestMapping注解，还通过对指定的包进行全局扫描来简化XML文件配置。但是这个MVC框架是独立运行的，它跟我们之前实现的IoC容器还没有什么关系。

那么这节课，我们就把前面实现的IoC容器与MVC结合在一起，使MVC的Controller可以引用容器中的Bean，这样整合成一个大的容器。

## Servlet服务器启动过程

IoC容器是一个自我实现的服务器，MVC是要符合Web规范的，不能自己想怎么来就怎么来。为了融合二者，我们有必要了解一下Web规范的内容。在Servlet规范中，服务器启动的时候，会根据web.xml文件来配置。下面我们花点时间详细介绍一下这个配置文件。

这个web.xml文件是Java的Servlet规范中规定的，它里面声明了一个Web应用全部的配置信息。按照规定，每个Java Web应用都必须包含一个web.xml文件，且必须放在WEB-INF路径下。它的顶层根是web-app，指定命名空间和schema规定。通常，我们会在web.xml中配置context-param、Listener、Filter和Servlet等元素。

下面是常见元素的说明。

```plain
<display-name></display-name>  
声明WEB应用的名字    
<description></description>   
 声明WEB应用的描述信息    
<context-param></context-param> 
声明应用全局的初始化参数。  
<listener></listener>
声明监听器，它在建立、修改和删除会话或servlet环境时得到事件通知。
<filter></filter> 
声明一个实现javax.servlet.Filter接口的类。    
<filter-mapping></filter-mapping>
声明过滤器的拦截路径。 
<servlet></servlet> 
声明servlet类。    
<servlet-mapping></servlet-mapping> 
声明servlet的访问路径，试一个方便访问的URL。    
<session-config></session-config> 
session有关的配置，超时值。
<error-page></error-page> 
在返回特定HTTP状态代码时，或者特定类型的异常被抛出时，能够制定将要显示的页面。   
```

当Servlet服务器如Tomcat启动的时候，要遵守下面的时序。

1. 在启动Web项目时，Tomcat会读取web.xml中的context-param节点，获取这个Web应用的全局参数。
2. Tomcat创建一个ServletContext实例，是全局有效的。
3. 将context-param的参数转换为键值对，存储在ServletContext里。
4. 创建listener中定义的监听类的实例，按照规定Listener要继承自ServletContextListener。监听器初始化方法是contextInitialized(ServletContextEvent event)。初始化方法中可以通过event.getServletContext().getInitParameter(″Fname″)方法获得上下文环境中的键值对。
5. 当Tomcat完成启动，也就是contextInitialized方法完成后，再对Filter过滤器进行初始化。
6. servlet初始化：有一个参数load-on-startup，它为正数的值越小优先级越高，会自动启动，如果为负数或未指定这个参数，会在servlet被调用时再进行初始化。init-param 是一个servlet整个范围之内有效的参数，在servlet类的init()方法中通过 this.getInitParameter(″param1″)方法获得。

规范中规定的这个时序，就是我们整合两者的关键所在。

## Listener初始化启动IoC容器

由上述服务器启动过程我们知道，我们把web.xml文件里定义的元素加载过程简单归总一下：先获取全局的参数context-param来创建上下文，之后如果配置文件里定义了Listener，那服务器会先启动它们，之后是Filter，最后是Servlet。因此我们可以利用这个时序，把容器的启动放到Web应用的Listener中。

Spring MVC就是这么设计的，它按照这个规范，用ContextLoaderListener来启动容器。我们也模仿它同样来实现这样一个Listener。

```java
package com.minis.web;

import javax.servlet.ServletContext;
import javax.servlet.ServletContextEvent;
import javax.servlet.ServletContextListener;

public class ContextLoaderListener implements ServletContextListener {
	public static final String CONFIG_LOCATION_PARAM = "contextConfigLocation";
	private WebApplicationContext context;
	
	public ContextLoaderListener() {
	}
	public ContextLoaderListener(WebApplicationContext context) {
		this.context = context;
	}
	@Override
	public void contextDestroyed(ServletContextEvent event) {
	}
	@Override
	public void contextInitialized(ServletContextEvent event) {
		initWebApplicationContext(event.getServletContext());
	}
	private void initWebApplicationContext(ServletContext servletContext) {
		String sContextLocation = servletContext.getInitParameter(CONFIG_LOCATION_PARAM);
		WebApplicationContext wac = new AnnotationConfigWebApplicationContext(sContextLocation);
		wac.setServletContext(servletContext);
		this.context = wac;
		servletContext.setAttribute(WebApplicationContext.ROOT_WEB_APPLICATION_CONTEXT_ATTRIBUTE, this.context);
	}
}
```

ContextLoaderListener这个类里，先声明了一个常量CONFIG\_LOCATION\_PARAM，它的默认值是contextConfigLocation，这是代表配置文件路径的一个变量，也就是IoC容器的配置文件。这也就意味着，Listener期望web.xml里有一个参数用来配置文件路径。我们可以看一下web.xml文件。

```plain
  <context-param>
    <param-name>contextConfigLocation</param-name>
    <param-value>applicationContext.xml</param-value>
  </context-param>
  <listener>
    <listener-class>
	        com.minis.web.ContextLoaderListener
	    </listener-class>
  </listener>
```

上面这个文件，定义了这个Listener，还定义了全局参数指定配置文件路径。

ContextLoaderListener这个类里还定义了WebApplicationContext对象，目前还不存在这个类。但通过名字可以知道，WebApplicationContext 是一个上下文接口，应用在Web项目里。我们看看如何定义WebApplicationContext。

```java
package com.minis.web;

import javax.servlet.ServletContext;
import com.minis.context.ApplicationContext;

public interface WebApplicationContext extends ApplicationContext {
	String ROOT_WEB_APPLICATION_CONTEXT_ATTRIBUTE = WebApplicationContext.class.getName() + ".ROOT";

	ServletContext getServletContext();
	void setServletContext(ServletContext servletContext);
}
```

可以看出，这个上下文接口指向了Servlet容器本身的上下文ServletContext。

接下来我们继续完善 ContextLoaderListener 这个类， 在初始化的过程中初始化WebApplicationContext， 并把这个上下文放到 servletContext 的 Attribute 某个属性里面。

```java
public void contextInitialized(ServletContextEvent event) {
    initWebApplicationContext(event.getServletContext());     
}
private void initWebApplicationContext(ServletContext servletContext) {
    String sContextLocation = 
servletContext.getInitParameter(CONFIG_LOCATION_PARAM);
    WebApplicationContext wac = new 
AnnotationConfigWebApplicationContext(sContextLocation);
    wac.setServletContext(servletContext);
    this.context = wac;
    servletContext.setAttribute(WebApplicationContext.ROOT_WEB_APPLICATION_CONTEXT_ ATTRIBUTE, this.context);
```

在这段代码中，通过配置文件参数从web.xml中得到配置文件路径，如applicationContext.xml，然后用这个配置文件创建了AnnotationConfigWebApplicationContext这一对象，我们叫WAC，这就成了新的上下文。然后调用servletContext.setAttribute()方法，按照默认的属性值将WAC设置到servletContext里。这样，AnnotationConfigWebApplicationContext 和 servletContext 就能够互相引用了，很方便。

而这个AnnotationConfigWebApplicationContext又是什么呢？我们看下它的定义。

```java
package com.minis.web;

import javax.servlet.ServletContext;
import com.minis.context.ClassPathXmlApplicationContext;

public class AnnotationConfigWebApplicationContext 
					extends ClassPathXmlApplicationContext implements WebApplicationContext{
	private ServletContext servletContext;
	
	public AnnotationConfigWebApplicationContext(String fileName) {
		super(fileName);
	}
	@Override
	public ServletContext getServletContext() {
		return this.servletContext;
	}
	@Override
	public void setServletContext(ServletContext servletContext) {
		this.servletContext = servletContext;
	}
}
```

由 AnnotationConfigWebApplicationContext 的继承关系可看出，该类其实质就是我们IoC容器中的ClassPathXmlApplicationContext，只是在此基础上增加了 servletContext 的属性，这样就成了一个适用于Web场景的上下文。

我们在这个过程中用到了一个配置文件applicationContext.xml，它是由定义在web.xml里的一个参数指明的。

```plain
  <context-param>
    <param-name>contextConfigLocation</param-name>
    <param-value>applicationContext.xml</param-value>
  </context-param>
```

这个配置文件就是我们现在的IoC容器的配置文件，主要作用是声明Bean，如：

```plain
<?xml version="1.0" encoding="UTF-8"?>
<beans>
	<bean id="bbs" class="com.test.service.BaseBaseService"> 
	    <property type="com.test.service.AServiceImpl" name="as" ref="aservice"/>
	</bean>
	<bean id="aservice" class="com.test.service.AServiceImpl"> 
		<constructor-arg type="String" name="name" value="abc"/>
		<constructor-arg type="int" name="level" value="3"/>
        <property type="String" name="property1" value="Someone says"/>
        <property type="String" name="property2" value="Hello World!"/>
        <property type="com.test.service.BaseService" name="ref1" ref="baseservice"/>
	</bean>
	<bean id="baseservice" class="com.test.service.BaseService"> 
	</bean>	
</beans>
```

回顾一下，现在完整的过程是：当Sevlet服务器启动时，Listener会优先启动，读配置文件路径，启动过程中初始化上下文，然后启动IoC容器，这个容器通过refresh()方法加载所管理的Bean对象。这样就实现了Tomcat启动的时候同时启动IoC容器。

## 改造DispatcherServlet，关联WAC

好了，到了这一步，IoC容器启动了，我们回来再讨论MVC这边的事情。我们已经知道，在服务器启动的过程中，会注册 Web应用上下文，也就是WAC。 这样方便我们通过属性拿到启动时的 WebApplicationContext 。

```java
this.webApplicationContext = (WebApplicationContext) this.getServletContext().getAttribute(WebApplicationContext.ROOT_WEB_APPLICATION _CONTEXT_ATTRIBUTE);
```

因此我们改造一下DispatcherServlet这个核心类里的init()方法。

```java
public void init(ServletConfig config) throws ServletException {          super.init(config);
    this.webApplicationContext = (WebApplicationContext) 
this.getServletContext().getAttribute(WebApplicationContext.ROOT_WEB_APPLICATION _CONTEXT_ATTRIBUTE);
    sContextConfigLocation = config.getInitParameter("contextConfigLocation");
    URL xmlPath = null;
	try {
		xmlPath = this.getServletContext().getResource(sContextConfigLocation);
	} catch (MalformedURLException e) {
		e.printStackTrace();
	}         
    this.packageNames = XmlScanComponentHelper.getNodeValue(xmlPath);        Refresh();
}
```

首先在Servlet初始化的时候，从sevletContext里获取属性，拿到Listener启动的时候注册好的WebApplicationContext，然后拿到Servlet配置参数contextConfigLocation，这个参数代表的是配置文件路径，这个时候是我们的MVC用到的配置文件，如minisMVC-servlet.xml，之后再扫描路径下的包，调用refresh()方法加载Bean。这样，DispatcherServlet也就初始化完毕了。

然后是改造initMapping()方法，按照新的办法构建URL和后端程序之间的映射关系：查找使用了注解 @RequestMapping 的方法，将 URL 存放到 urlMappingNames 里，再把映射的对象存放到 mappingObjs 里，映射的方法存放到 mappingMethods 里。用这个方法取代过去解析 Bean 得到的映射，省去了XML文件里的手工配置。你可以看一下相关代码。

```java
protected void initMapping() {
    for (String controllerName : this.controllerNames) {
        Class<?> clazz = this.controllerClasses.get(controllerName);             Object obj = this.controllerObjs.get(controllerName);
        Method[] methods = clazz.getDeclaredMethods();
        if (methods != null) {
            for (Method method : methods) {
                boolean isRequestMapping = 
method.isAnnotationPresent(RequestMapping.class);
                if (isRequestMapping) {
                    String methodName = method.getName();
                    String urlMapping = 
method.getAnnotation(RequestMapping.class).value();
                    this.urlMappingNames.add(urlMapping);
                    this.mappingObjs.put(urlMapping, obj);
                    this.mappingMethods.put(urlMapping, method);
                }
            }
        }
    }
}
```

最后稍微调整一下 doGet() 方法内的代码，去除不再使用的结构。

```java
protected void doGet(HttpServletRequest request, HttpServletResponse response) throws ServletException, IOException {
    String sPath = request.getServletPath();
	if (!this.urlMappingNames.contains(sPath)) {
		return;
	}

    Object obj = null;
    Object objResult = null;
    try {
        Method method = this.mappingMethods.get(sPath);
        obj = this.mappingObjs.get(sPath);
        objResult = method.invoke(obj);
    } catch (Exception e) {
		e.printStackTrace();
	}
    response.getWriter().append(objResult.toString());     
}
```

代码里的这个doGet()方法从请求中获取访问路径，按照路径和后端程序的映射关系，获取到需要调用的对象和方法，调用方法后直接把结果返回给response。

到这里，整合了IoC容器的MVC就完成了。

## 验证

下面进行测试，我们先看一下Tomcat使用的web.xml文件配置。

```plain
<?xml version="1.0" encoding="UTF-8"?>
<web-app xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:web="http://xmlns.jcp.org/xml/ns/javaee" xsi:schemaLocation="http://xmlns.jcp.org/xml/ns/javaee http://java.sun.com/xml/ns/javaee/web-app_2_5.xsd" id="WebApp_ID">
  <context-param>
    <param-name>contextConfigLocation</param-name>
    <param-value>applicationContext.xml</param-value>
  </context-param>
  <listener>
    <listener-class>
	        com.minis.web.ContextLoaderListener
	    </listener-class>
  </listener>
  <servlet>
    <servlet-name>minisMVC</servlet-name>
    <servlet-class>com.minis.web.DispatcherServlet</servlet-class>
    <init-param>
      <param-name>contextConfigLocation</param-name>
      <param-value> /WEB-INF/minisMVC-servlet.xml </param-value>
    </init-param>
    <load-on-startup>1</load-on-startup>
  </servlet>
  <servlet-mapping>
    <servlet-name>minisMVC</servlet-name>
    <url-pattern>/</url-pattern>
  </servlet-mapping>
</web-app>
```

然后是IoC容器使用的配置文件applicationContext.xml。

```plain
<?xml version="1.0" encoding="UTF-8"?>
<beans>
	<bean id="bbs" class="com.test.service.BaseBaseService"> 
	    <property type="com.test.service.AServiceImpl" name="as" ref="aservice"/>
	</bean>
	<bean id="aservice" class="com.test.service.AServiceImpl"> 
		<constructor-arg type="String" name="name" value="abc"/>
		<constructor-arg type="int" name="level" value="3"/>
        <property type="String" name="property1" value="Someone says"/>
        <property type="String" name="property2" value="Hello World!"/>
        <property type="com.test.service.BaseService" name="ref1" ref="baseservice"/>
	</bean>
	<bean id="baseservice" class="com.test.service.BaseService"> 
	</bean>
</beans>
```

MVC扫描的配置文件minisMVC-servlet.xml。

```plain
<?xml version="1.0" encoding="UTF-8" ?>
<components>
<component-scan base-package="com.test"/>
</components>
```

最后，在com.minis.test.HelloworldBean内的测试方法上，增加@RequestMapping注解。

```java
package com.test;

import com.minis.web.RequestMapping;

public class HelloWorldBean {
    @RequestMapping("/test")
    public String doTest() {
        return "hello world for doGet!";     
    }
}
```

启动Tomcat进行测试，在浏览器输入框内键入：localhost:8080/test。  
注：这个端口号可以自定义，也可依据实际情况在请求路径前增加上下文。  
运行成功，学到这里，看到这个结果，你应该很开心吧。

## 小结

这节课，我们把MVC与IoC整合在了一起。具体过程是这样的：在Tomcat启动的过程中先拿context-param，初始化Listener，在初始化过程中，创建IoC容器构建WAC（WebApplicationContext），加载所管理的Bean对象，并把WAC关联到servlet context里。

然后在DispatcherServlet初始化的时候，从sevletContext里获取属性拿到WAC，放到servlet的属性中，然后拿到Servlet的配置路径参数，之后再扫描路径下的包，调用refresh()方法加载Bean，最后配置url mapping。

我们之所以有办法整合这二者，核心的原因是**Servlet规范中规定的时序**，从listerner到filter再到servlet，每一个环节都预留了接口让我们有机会干预，写入我们需要的代码。我们在学习过程中，更重要的是要学习如何构建可扩展体系的思路，在我们自己的软件开发过程中，记住**不要将程序流程固定死**，那样没有任何扩展的余地，而应该想着预留出一些接口理清时序，让别人在关节处也可以插入自己的逻辑。

容器是一个框架，之所以叫做框架而不是应用程序，关键就在于这套可扩展的体系，留给其他程序员极大的空间。读Rodd Johnson这些大师的源代码，就像欣赏一本优美的世界名著，每每都会发出“春风大雅能容物，秋水文章不染尘”的赞叹。希望你可以学到其中的精髓。

完整源代码参见 [https://github.com/YaleGuo/minis](https://github.com/YaleGuo/minis)

## 课后题

学完这节课，我也给你留一道思考题。我们看到从Dispatcher 内可访问WebApplicationContext里面管理的Bean，那通过WebApplicationContext 可以访问Dispatcher内管理的Bean吗？欢迎你在留言区和我交流讨论，也欢迎你把这节课分享给需要的朋友。我们下节课见！
<div><strong>精选留言（13）</strong></div><ul>
<li><span>风轻扬</span> 👍（10） 💬（1）<p>思考题：Spring中有父子容器的概念。子容器：MVC容器，父容器：Spring容器。子可以访问父，反过来不行，这是由Spring的体系结构决定的，子容器继承父容器，所以子容器是知道父容器的，所以也就能得到父容器的引用，进而得到父容器中的bean。但是父容器是无法知道子容器的，所以也就无法直接获取子容器中的bean，但是可以通过getBeanFactory来得到子容器，从而获取到子容器中的bean，但java的三层模型，controller---&gt;service---&gt;dao，controller注入service对象是正常的，service注入controller有点奇怪，一般不这么干。不知道以上理解的对不对</p>2023-04-03</li><br/><li><span>睿智的仓鼠</span> 👍（7） 💬（1）<p>文中代码实现了webApplicationContext的注入，但排版缺少了很重要的 populateBean()方法，没有使用到初始化好的ioc容器，github中相关的完整的代码是：
```java
DispatcherServlet：

protected void initController() {
        this.controllerNames = scanPackages(this.packageNames);
        for (String controllerName : this.controllerNames) {
            Object obj = null;
            Class&lt;?&gt; clz = null;
            try {
                clz = Class.forName(controllerName);
                obj = clz.newInstance();
            } catch (Exception e) {
                e.printStackTrace();
            }
            this.controllerClasses.put(controllerName, clz);

            populateBean(obj);
            this.controllerObjs.put(controllerName, obj);
        }
    }

    &#47;&#47; 处理controller中的@Autowired注解
    private void populateBean(Object bean) {
        Class&lt;?&gt; clz = bean.getClass();
        Field[] fields = clz.getDeclaredFields();
        for (Field field : fields) {
            boolean isAutowired = field.isAnnotationPresent(Autowired.class);
            if (isAutowired) {
                String fieldName = field.getName();
                Object autowiredBean = this.webApplicationContext.getBean(fieldName);
                field.setAccessible(true);
                try {
                    field.set(bean, autowiredBean);
                } catch (IllegalAccessException e) {
                    throw new RuntimeException(e);
                }
            }
        }
    }
```</p>2023-03-29</li><br/><li><span>不是早晨，就是黄昏</span> 👍（2） 💬（1）<p>最后，在 com.minis.test.HelloworldBean 内的测试方法上
但是你项目代码里有新建了一个test目录，且是和minis同级，而minisMVC-servlet.xml里配置的也是com.test，文章给的代码也是com.test里的，感觉写的有点过于随意了。。。。</p>2023-04-04</li><br/><li><span>Cooler</span> 👍（0） 💬（1）<p>老师，目前wac.setServletContext(servletContext); 这一块相关代码是不是没有用在这一章讲的内容</p>2023-06-16</li><br/><li><span>啊良梓是我</span> 👍（0） 💬（1）<p>课后题，通过WebApplicationContext 可以访问到DispatcherServlet里面的bean吗？
我觉得是分成两种情况来讲的？
根据Servlet的时序来讲的话，那么当初始化好WebApplicationContext的时候，DispatcherServlet还没有进行初始化，所以是空的无法访问的；
但是Servlet初始化完成后呢那应该是可以的？但是怎么访问？用一个方法？
这个方法怎么表明他是IOC的bean的？有点乱了</p>2023-05-18</li><br/><li><span>啊良梓是我</span> 👍（0） 💬（1）<p>黑夜模式，代码里面的标签全没了，作者可以跟后台反馈一下吗 改一下颜色啥的</p>2023-05-18</li><br/><li><span>Geek_b71d2c</span> 👍（0） 💬（1）<p>老师，请问一下servletContext.getInitParameter(CONFIG_LOCATION_PARAM)一直获取到的是空，这是什么原因呀</p>2023-05-06</li><br/><li><span>杨松</span> 👍（0） 💬（1）<p>老师，在代码分支geek_mvc2中，ContextLoaderListener加载了资源文件applicationContext.xml中的bean对象，然后DispatcherServlet会加载&#47;WEB-INF&#47;minisMVC-servlet.xml并扫描包com.test，那么这个包下的对象即被ioc容器加载了，又被DispatcherServlet(mvc容器)加载了，是不是后续的分支会解决这个问题</p>2023-04-18</li><br/><li><span>peter</span> 👍（0） 💬（4）<p>请教老师几个问题：
Q1：我用idea2019创建的后端项目并没有web.xml，为什么？
我创建的是springboot项目，maven项目，src目录下面是main和test，main下面是java和resource，并没有WebContent目录，也没有WEB_INF目录，更没有web.xml文件。这个现象怎么解释？另外，不同的项目有不同的目录结构，目录结构的定义在哪里有官方说明？
Q2：用idea创建的项目缺省是基于tomcat吗？
Q3：spring必须基于tomcat，不能独立工作吗？
按文中的说法，servlet必须要用tomcat这个容器，这样的话，spring并不能独立使用，必须依赖于tomcat。</p>2023-03-31</li><br/><li><span>马儿</span> 👍（0） 💬（1）<p>课后习题：目前Dispatcher可以 访问到WebApplicationContext中的bean，Dispatcher中的bean目前也存在对象的属性中了，但是Dispatcher没有被WebApplicationContext引用所以不能被访问。请问老师spring在管理controller产生的bean的时候是将这些bean统一注册到WebApplicationContext吗？</p>2023-03-30</li><br/><li><span>Shark</span> 👍（0） 💬（1）<p>在tomcat启动的过程中，是先初始化IoC容器，再初始化DispatcherServlet，在初始化DispatcherServlet的过程中记录URI与负责执行的方法和方法的对象关系映射，所以这些URI对应的对象此时是由DispatcherServlet管理的，而非IoC容器，而DispatcherServlet也不是IoC容器管理的，后续是不是会统一到IoC容器中？</p>2023-03-29</li><br/><li><span>7up</span> 👍（1） 💬（0）<p>看代码这里将controller放到Dispatcher容器中，其他bean放到webApplicationContext容器中，在Dispatcher初始化时将两者关联起来，第7节课则是没有区分。统一放到了MVC容器中，没有关联IOC容器。</p>2023-11-15</li><br/><li><span>白不吃</span> 👍（0） 💬（0）<p>看完之后，感觉清晰了很多，不像以前 tomcat 和 spring 对于我来说，就是两个黑盒</p>2025-01-20</li><br/>
</ul>