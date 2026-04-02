你好，我是郭屹。从这节课开始，我们开启一个新的部分：MVC。

前面一章，我们实现了一个简单的IoC。麻雀虽小，五脏俱全，相比原生Spring框架而言，我们写的MiniSpring功能简单，但其核心功能已具备。我们会在这个基础上进一步扩展我们的框架。

这一章我们来实现Spring MVC。MVC，全名对应Model（模型）、View（视图）、Controller（控制器）。它的基本流程是：前端发送请求到控制器，控制器寻找对应模型，找到模型后返回结果，渲染视图返回给前端生成页面。这是标准的前端请求数据的模型。实现了MVC之后，我们会把MVC和之前我们已经实现的IoC结合起来，这是我们这一章的整体思路。

![图片](https://static001.geekbang.org/resource/image/a7/41/a79dc2ca9b96c2f4904c2f389926fb41.png?wh=1660x916)

这节课我们就开启Spring MVC的第一步，先实现一个原始的MVC。目标是通过一个Controller来拦截用户请求，找到相应的处理类进行逻辑处理，然后将处理的结果发送给客户端。

## 调整目录

按照惯例，我们还是参照Spring的目录结构来调整。MVC是Web模型，所以我们先调整一下目前的项目结构，采用Web的项目结构。同时，我们还要引入Tomcat服务器以及Tomcat的jar包。

你可以看一下项目目录结构，主要是新增一个和src目录同级的WebContent目录，在这个目录里存储部分前端页面需要的静态资源，还有各项XML配置文件。

```java
src
└── com
│ ├── minis
│ │ ├── web
│ │ ├── util
│ │ └── test
WebContent
├── WEB-INF
│ ├── lib
│ ├── web.xml
│ ├── minisMVC-servlet.xml
└── META-INF
│ └── MANIFEST.MF
```

参考Spring MVC，我们定义web.xml和minisMVC-servlet.xml这两个配置文件的内容。

1. minisMVC-servlet.xml

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<beans>
  <bean id="/helloworld" class="com.minis.test.HelloWorldBean" value="doGet"/>
</beans>
```

2. web.xml

```java
<?xml version="1.0" encoding="UTF-8"?>
<web-app xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
xmlns:web="http://xmlns.jcp.org/xml/ns/javaee"
xsi:schemaLocation="http://xmlns.jcp.org/xml/ns/javaee
http://java.sun.com/xml/ns/javaee/web-app_2_5.xsd" id="WebApp_ID">
  <servlet>
    <servlet-name>minisMVC</servlet-name>
    <servlet-class>com.minis.web.DispatcherServlet</servlet-class>
      <init-param>
        <param-name>contextConfigLocation</param-name>
        <param-value>/WEB-INF/minisMVC-servlet.xml</param-value>
      </init-param>
      <load-on-startup>1</load-on-startup>
  </servlet>
  <servlet-mapping>
    <servlet-name>minisMVC</servlet-name>
    <url-pattern>/</url-pattern>
  </servlet-mapping>
</web-app>
```

这两个XML文件里，minisMVC-servlet.xml是我们很熟悉的Bean配置，只是把id设置成了一个URL的形式，来匹配后端的程序，访问/helloworld的时候，对应调用HelloWorldBean类里的doGet()方法。

## Servlet

接下来我们重点关注web.xml。MVC里有一个核心概念是Servlet，通俗理解成运行在Web服务器上的程序。针对上面的XML配置，我们解读一下里面几个标签的含义。

![](https://static001.geekbang.org/resource/image/3f/f6/3f618deba5608e66ca0174ac1ba82ef6.png?wh=2554x1102)

整个结构就是一个标准的JavaEE结构，我们按照规范解释它，就是当Servlet容器启动的时候，先读取web.xml配置，加载配置文件中的servlet，也就是DispatcherServlet，并规定它拦截所有的HTTP请求，所以它就是控制器。

我们注意到这个控制器DispatcherServlet有一个参数 contextConfigLocation，它配置了控制器要找的逻辑处理类的文件minisMVC-servlet.xml。

```java
      <init-param>
        <param-name>contextConfigLocation</param-name>
        <param-value>/WEB-INF/minisMVC-servlet.xml</param-value>
      </init-param>
```

因此，为了启动这个servlet，我们要提前解析minisMVC-servlet.xml文件。

### 解析servlet.xml

首先定义实体类MappingValue里的三个属性：uri、clz与method，分别与minisMVC-servlet.xml中标签的属性id、class与value对应。

```java
package com.minis.web;

public class MappingValue {
	String uri;
	public String getUri() {
		return uri;
	}
	public void setUri(String uri) {
		this.uri = uri;
	}
	String clz;
	public String getClz() {
		return clz;
	}
	public void setClz(String clz) {
		this.clz = clz;
	}
	String method;
	public String getMethod() {
		return method;
	}
	public void setMethod(String method) {
		this.method = method;
	}
	
	public MappingValue(String uri, String clz, String method) {
		this.uri = uri;
		this.clz = clz;
		this.method = method;
	}
}
```

然后我们定义Resource用来加载配置文件。

```java
package com.minis.web;
import java.util.Iterator;
public interface Resource extends Iterator<Object>{
}
```

这是具体的实现。

```java
package com.minis.web;

import java.net.URL;
import java.util.Iterator;
import java.util.List;
import org.dom4j.Document;
import org.dom4j.DocumentException;
import org.dom4j.Element;
import org.dom4j.io.SAXReader;

public class ClassPathXmlResource implements Resource {
	Document document;
	Element rootElement;
	Iterator<Element> elementIterator;
	
	public ClassPathXmlResource(URL xmlPath) {
        SAXReader saxReader=new SAXReader();
        try {
			this.document = saxReader.read(xmlPath);
			this.rootElement=document.getRootElement();
			this.elementIterator=this.rootElement.elementIterator();
		} catch (DocumentException e) {
			e.printStackTrace();
		}		
	}
	@Override
	public boolean hasNext() {
		return this.elementIterator.hasNext();
	}
	@Override
	public Object next() {
		return this.elementIterator.next();
	}
}
```

```java
package com.minis.web;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.dom4j.Element;

public class XmlConfigReader {
	public XmlConfigReader() {
	}
	public Map<String,MappingValue> loadConfig(Resource res) {
		Map<String,MappingValue> mappings = new HashMap<>();
		
        while (res.hasNext()) { //读所有的节点，解析id, class和value
        	Element element = (Element)res.next();
            String beanID=element.attributeValue("id");
            String beanClassName=element.attributeValue("class");
            String beanMethod=element.attributeValue("value");

            mappings.put(beanID, new MappingValue(beanID,beanClassName,beanMethod));
        }
        
        return mappings;
	}
}
```

上述几段代码，是不是似曾相识？和我们前一部分编写的解析IoC的配置文件基本没什么差别，通过这些方法就能把XML里配置的Bean加载到内存里了，这里我就不再多说了。

### 实现MVC的核心启动类DispatcherSevlet

现在项目的搭建和前期准备工作已经完成，我们开始着手实现web.xml中配置的com.minis.web.DispatcherServlet这个MVC的核心启动类，完成URL映射机制。

**MVC的基本思路是屏蔽Servlet的概念，让程序员主要写业务逻辑代码**。浏览器访问的URL通过映射机制找到实际的业务逻辑方法。按照Servlet规范，可以通过Filter拦截，也可以通过Servlet拦截。MiniSpring的实现过程中，我模仿Spring MVC通过Servlet拦截所有请求，处理映射关系，调用业务逻辑代码，处理返回值回递给浏览器。程序员写的业务逻辑程序，也叫做Bean。

在DispatcherSevlet内，定义了三个Map，分别记录URL对应的MappingValue对象、对应的类和对应的方法。

```java
private Map<String, MappingValue> mappingValues;
private Map<String, Class<?>> mappingClz = new HashMap<>();
private Map<String, Object> mappingObjs = new HashMap<>();
```

随后实现Servlet初始化方法，初始化主要处理从外部传入的资源，将XML文件内容解析后存入mappingValues内。最后调用Refresh()函数创建Bean，这节课的例子就是HelloWorldBean，这些Bean的类和实例存放在mappingClz和mappingObjs里。

```java
    public void init(ServletConfig config) throws ServletException {
    	super.init(config);
    	
        sContextConfigLocation = config.getInitParameter("contextConfigLocation");       
        URL xmlPath = null;
		try {
			xmlPath = this.getServletContext().getResource(sContextConfigLocation);
		} catch (MalformedURLException e) {
			e.printStackTrace();
		}
		Resource rs = new ClassPathXmlResource(xmlPath);
        XmlConfigReader reader = new XmlConfigReader();
        mappingValues = reader.loadConfig(rs);
        Refresh();
    }
```

下面是Refresh()方法。

```plain
//对所有的mappingValues中注册的类进行实例化，默认构造函数
protected void Refresh() {
 	for (Map.Entry<String,MappingValue> entry : mappingValues.entrySet()) {
    	String id = entry.getKey();
    	String className = entry.getValue().getClz();
    	Object obj = null;
    	Class<?> clz = null;
		try {
			clz = Class.forName(className);
			obj = clz.newInstance();
		} catch (Exception e) {
			e.printStackTrace();
		}
		mappingClz.put(id, clz);
    	mappingObjs.put(id, obj);
    }
}
```

Refresh()就是通过读取mappingValues中的Bean定义，加载类，创建实例。这个方法完成之后，整个DispatcherSevlet就准备好了。

DispatcherSevlet用来处理所有的Web请求，但是目前我们只是简单地实现了Get请求的处理，通过Bean的id获取其对应的类和方法，依赖反射机制进行调用。你可以看一下相关代码。

```java
protected void doGet(HttpServletRequest request, HttpServletResponse response) throws ServletException, IOException {
    String sPath = request.getServletPath(); //获取请求的path
	if (this.mappingValues.get(sPath) == null) {
		return;
	}

    Class<?> clz = this.mappingClz.get(sPath); //获取bean类定义
    Object obj = this.mappingObjs.get(sPath);  //获取bean实例
    String methodName = this.mappingValues.get(sPath).getMethod(); //获取调用方法名
    Object objResult = null;
    try {
        Method method = clz.getMethod(methodName);
        objResult = method.invoke(obj); //方法调用
    } catch (Exception e) {
    }
    //将方法返回值写入response
    response.getWriter().append(objResult.toString());
}
```

到这里，一个最简单的DispatcherServlet就完成了，DispatcherServlet就是一个普通的Servlet，并不神秘，只要我们有一个Servlet容器，比如Tomcat，它就能跑起来。

这个实现很简陋，调用的方法没有参数，返回值只是String，直接通过response回写。

我们试一个简单的测试类。

```java
package com.minis.test;

public class HelloWorldBean {
	public String doGet() {
		return "hello world!";
	}
	public String doPost() {
		return "hello world!";
	}
}
```

启动Tomcat，在浏览器内键入localhost:8080/helloworld，就能显示返回结果"hello world for doGet!"。

到这里，我们初步实现了MVC的框架，支持了一个简单的请求由Controller控制器（DispatcherServlet），到底层查找模型结构Model（helloWorldBean），最后返回前端渲染视图View（response.getWriter().append()）的过程。

## 扩展MVC

在这个简陋的模型基础之上，我们一步步扩展，引入@RequestMapping，还会实现ComponentScan，简化配置工作。

### 简化配置

首先我们来简化XML中的繁琐配置，在minisMVC-servlet.xml里新增和两个标签，分别表示组件配置以及组件的扫描配置。也就是说，扫描一个包，自动配置包内满足条件的类，省去手工配置过程。你可以参考下面的代码。

```xml
(minisMVC-servlet.xml)
<?xml version="1.0" encoding="UTF-8" ?>
<components>
    <component-scan base-package="com.minis.test" />
</components>
```

上述文件将扫描com.minis.test里所有的类文件，加载并实例化它们。

### 引入@RequestMapping

接下来我们引入@RequestMapping，将 URL 和业务处理类中的某个方法对应起来，这样也就不再需要手工地将映射关系写到XML配置文件里，省去我们的手工配置工作。在Spring框架里， @RequestMapping 注解可支持定义在类上，但我们这里暂时不支持该注解定义在类上，只定义在方法上。我们看一下注解定义。

```java
package com.minis.web;

import java.lang.annotation.Retention;
import java.lang.annotation.Target;
import java.lang.annotation.ElementType;
import java.lang.annotation.RetentionPolicy;

@Target(value={ElementType.METHOD})
@Retention(RetentionPolicy.RUNTIME)
public @interface RequestMapping {
    String value() default "";
}

```

@RequestMapping定义很简单，现在只有value一个字段，用来接收配置的URL。

有了注解定义，我们就可以动手编程实现了。因为修改了minisMVC-servlet.xml这个文件内的标签结构，因此我们提供一个新类 XmlScanComponentHelper，专门用来解析新定义的标签结构。

```java
package com.minis.web;

import java.net.URL;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import org.dom4j.Document;
import org.dom4j.DocumentException;
import org.dom4j.Element;
import org.dom4j.Node;
import org.dom4j.io.SAXReader;

public class XmlScanComponentHelper {
    public static List<String> getNodeValue(URL xmlPath) {
        List<String> packages = new ArrayList<>();
        SAXReader saxReader = new SAXReader();
        Document document = null;
        try {
            document = saxReader.read(xmlPath); //加载配置文件
        } catch (DocumentException e) {
            e.printStackTrace();
        }
        Element root = document.getRootElement();
        Iterator it = root.elementIterator();
        while (it.hasNext()) { //得到XML中所有的base-package节点
            Element element = (Element) it.next();
            packages.add(element.attributeValue("base-package"));              }
        return packages;
    }
}
```

程序也很简单，原有的XmlConfigReadder 、Resource 、MappingValue 和ClassPathXmlResource 不再需要使用，取而代之的是XmlScanComponentHelper ，把扫描到的package 存储在List packages 这个结构里。代码的核心就是获取“base-package”参数值，加载到内存里。

### 修改 DispatcherServlet

经过上面这些步骤之后，接下来我们需要进一步修改 DispatcherServlet ，因为最终一切的落脚点都在这个类里，这个类承载了所有请求的解析和处理请求的步骤。我们在 DispatcherServlet 里使用下面的数据结构来存储配置。

```java
private List<String> packageNames = new ArrayList<>();
private Map<String,Object> controllerObjs = new HashMap<>();
private List<String> controllerNames = new ArrayList<>();
private Map<String,Class<?>> controllerClasses = new HashMap<>();         private List<String> urlMappingNames = new ArrayList<>();
private Map<String,Object> mappingObjs = new HashMap<>();
private Map<String,Method> mappingMethods = new HashMap<>();
```

我们看下这些变量的作用。

![](https://static001.geekbang.org/resource/image/2a/c9/2ae701e90ef7b180646a1a9f3fa6bac9.png?wh=1936x906)

接下来，Servlet初始化时我们把 minisMVC-servlet.xml 里扫描出来的 package 名称存入 packageNames 列表，初始化方法 init 中增加以下这行代码。

```java
this.packageNames = XmlScanComponentHelper.getNodeValue(xmlPath);
```

注：原有的与 ClassPathXmlResource 、Resource 相关代码要清除。

我们再将 refresh()方法分成两步：第一步初始化 controller ，第二步则是初始化 URL 映射。

对应的 refresh() 方法进行如下抽象：

```java
protected void refresh() {
    initController(); // 初始化 controller     
    initMapping(); // 初始化 url 映射
}
```

接下来完善initController() ，其主要功能是对扫描到的每一个类进行加载和实例化，与类的名字建立映射关系，分别存在 controllerClasses 和 controllerObjs 这两个map里，类名就是key的值。

```java
protected void initController() {
    //扫描包，获取所有类名       
    this.controllerNames = scanPackages(this.packageNames);  
    for (String controllerName : this.controllerNames) {
        Object obj = null;
        Class<?> clz = null;
        try {
            clz = Class.forName(controllerName); //加载类
            this.controllerClasses.put(controllerName, clz);             
        } catch (Exception e) {
        }
        try {
            obj = clz.newInstance(); //实例化bean
            this.controllerObjs.put(controllerName, obj); 
        } catch (Exception e) {
        }
    }
```

扫描程序是对文件目录的递归处理，最后的结果就是把所有的类文件扫描出来。

```java
private List<String> scanPackages(List<String> packages) {
    List<String> tempControllerNames = new ArrayList<>();
    for (String packageName : packages) {
        tempControllerNames.addAll(scanPackage(packageName));         
    }
    return tempControllerNames;
}
private List<String> scanPackage(String packageName) {         
    List<String> tempControllerNames = new ArrayList<>();         
    URI uri = null;
    //将以.分隔的包名换成以/分隔的uri
    try {
        uri = this.getClass().getResource("/" + 
packageName.replaceAll("\\.", "/")).toURI();
    } catch (Exception e) {
    }
    File dir = new File(uri);
    //处理对应的文件目录
    for (File file : dir.listFiles()) { //目录下的文件或者子目录
        if(file.isDirectory()){ //对子目录递归扫描
            scanPackage(packageName+"."+file.getName());
        }else{ //类文件
            String controllerName = packageName +"." 
+file.getName().replace(".class", "");
            tempControllerNames.add(controllerName);
        }
    }
    return tempControllerNames;
}
```

然后完善initMapping() ，功能是初始化 URL 映射，找到使用了注解@RequestMapping 的方法，URL 存放到 urlMappingNames 里，映射的对象存放到 mappingObjs 里，映射的方法存放到 mappingMethods 里。用这个方法取代了过去解析 Bean 得到的映射。

```java
protected void initMapping() {
    for (String controllerName : this.controllerNames) {
        Class<?> clazz = this.controllerClasses.get(controllerName);
             Object obj = this.controllerObjs.get(controllerName);
        Method[] methods = clazz.getDeclaredMethods();
        if (methods != null) {
            for (Method method : methods) {
                //检查所有的方法
                boolean isRequestMapping = 
method.isAnnotationPresent(RequestMapping.class);
                if (isRequestMapping) { //有RequestMapping注解
                    String methodName = method.getName();
                    //建立方法名和URL的映射
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

最后略微调整 doGet() 方法内的代码，去除不再使用的结构。

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
    } catch (Exception e) {
    }
    response.getWriter().append(objResult.toString());     
}
```

修改一下测试类，在com.minis.test.HelloworldBean内的测试方法上，增加@RequestMapping注解。

```java
package com.minis.test;

import com.minis.web.RequestMapping;

public class HelloWorldBean {
    @RequestMapping("/test")
    public String doTest() {
        return "hello world for doGet!";     
    }
}
```

启动Tomcat进行测试，在浏览器输入框内键入：localhost:8080/test。

## 小结

![](https://static001.geekbang.org/resource/image/a3/64/a36a0e7a21cdb86d7d9975d932b99364.jpg?wh=3250x3064)

我们这节课构建了一个DispatcherServlet，它是Tomcat中注册的唯一的Servlet，它承担了所有请求的处理功能。由它来解析请求中的路径与业务类Bean中方法的映射关系，调用Bean的相应方法，返回给response。

这种映射关系的建立，我们一开始是让用户自己在XML配置文件中手动声明，然后我们引入RequestMapping注解，扫描包中的类，检查注解，自动注册映射关系。这样我们初步实现了比较原始的MVC。在这个框架下，应用程序员不用再关心Servlet的使用，他们可以直接建立业务类，加上注解就可以运行。

完整源代码参见 [https://github.com/YaleGuo/minis](https://github.com/YaleGuo/minis)，mvc分支。

## 课后题

学完这节课，我也给你留一道思考题。我们在MVC中也使用了Bean这个概念，它跟我们以前章节中的Bean是什么关系？欢迎你在留言区与我交流讨论，也欢迎你把这节课分享给需要的朋友。我们下节课见！
<div><strong>精选留言（15）</strong></div><ul>
<li><span>Geek4329</span> 👍（2） 💬（3）<p>    private List&lt;String&gt; scanPackage(String packageName) {
    	List&lt;String&gt; tempControllerNames = new ArrayList&lt;&gt;();
        URL url  =this.getClass().getClassLoader().getResource(&quot;&#47;&quot;+packageName.replaceAll(&quot;\\.&quot;, &quot;&#47;&quot;));
        File dir = new File(url.getFile());
        for (File file : dir.listFiles()) {
            if(file.isDirectory()){
            	scanPackage(packageName+&quot;.&quot;+file.getName());
            }else{
                String controllerName = packageName +&quot;.&quot; +file.getName().replace(&quot;.class&quot;, &quot;&quot;);
                tempControllerNames.add(controllerName);
            }
        }
        return tempControllerNames;
    }
这个方法写的没问题么？照理说应该是递归把所有的类文件都加载进去，应该是tempControllerNames.addAll(scanPackage(packageName+&quot;.&quot;+file.getName()))
是我理解有问题么？</p>2024-02-28</li><br/><li><span>风轻扬</span> 👍（2） 💬（4）<p>思考题。我理解：MVC中的bean是为了标识这是一个controller，用来接收处理web层请求，而Spring中的bean感觉是一种服务能力，哪个地方需要这种能力，注入后就可以使用。不知道理解的对不对。
另外，跟代码的过程中，发现一个问题，如果包下有接口，Class.newInstance就会报错的。老师，将controller实例化处的代码是不是应该加个Class.isInstance()的判断呢？</p>2023-04-02</li><br/><li><span>KernelStone</span> 👍（1） 💬（1）<p>搞了半天这节内容对我这种工程小白而言，难是难在从IDEA中进行项目部署。终于跑通了，参考链接如下：
1、https:&#47;&#47;blog.csdn.net&#47;Wxy971122&#47;article&#47;details&#47;123508532
2、https:&#47;&#47;blog.csdn.net&#47;fannyoona&#47;article&#47;details&#47;113933113
3、另外有需要可以搜一下Tomcat控制台乱码问题

还有感谢评论区的帮助！</p>2023-06-03</li><br/><li><span>零零后糖豆豆</span> 👍（1） 💬（1）<p>response设置contentType避免返回中文乱码
response.setContentType(&quot;text&#47;html; charset=UTF-8&quot;);</p>2023-05-12</li><br/><li><span>云韵</span> 👍（1） 💬（1）<p>老师 文中的代码和下载的代码分支geek-mvc1 对应不上</p>2023-03-29</li><br/><li><span>x-arts</span> 👍（1） 💬（2）<p>源码给的过于随意了。。。。</p>2023-03-28</li><br/><li><span>睿智的仓鼠</span> 👍（1） 💬（1）<p>加入注解后改造的initMapping()方法中
Class&lt;?&gt; clazz = this.controllerClasses.get(controllerName);下面缺少了一行：
Object obj = this.controllerObjs.get(controllerName);</p>2023-03-27</li><br/><li><span>Yangjing</span> 👍（0） 💬（2）<p>老师，扩展MVC前，启动 Tomcat，是要怎么配置 Tomcat、MiniS 配合启动的呢</p>2023-04-09</li><br/><li><span>睿智的仓鼠</span> 👍（0） 💬（1）<p>请问郭老师，最后DispatcherServlet中的controllerObjs和mappingObjs这两个map，存储的都是请求地址和处理请求的bean的映射关系，这里为什么要维护两份？我能理解它们的思想不同，但也想不出维护两份后期会有什么扩展。后期会体现出这样做的好处吗？</p>2023-03-28</li><br/><li><span>Ben Guo</span> 👍（5） 💬（1）<p>关于启动Tomcat，可以加入 embeded tomcat的依赖，然后用下面的代码 跑起来

public class App 
{
    public static void main( String[] args ) throws LifecycleException {
        System.out.println( &quot;Hello World!&quot; );
        Tomcat tomcat = new Tomcat();
        String webappDirLocation = &quot;WebContent&quot;;
        StandardContext context = (StandardContext) tomcat.addWebapp(&quot;&#47;&quot;, new File(webappDirLocation).getAbsolutePath());
        Connector connector = new Connector();
        connector.setPort(8080);
        tomcat.setConnector(connector);
        tomcat.start();
        tomcat.getServer().await();
    }
}</p>2023-07-11</li><br/><li><span>adelyn</span> 👍（2） 💬（0）<p>感谢老师，之前没注意过requestMapping为什么是mapping，今天恍然大悟，原来是用url做key维护了一个mapping，</p>2023-04-09</li><br/><li><span>adelyn</span> 👍（1） 💬（0）<p>上条写错了，维护了三个mapping，三个mapping正好提供了反射的三个条件，看源码太爽了</p>2023-04-09</li><br/><li><span>马儿</span> 👍（1） 💬（0）<p>思考题：mvc中的bean只是项目中的一种bean，而ioc管理的是整个项目的bean。可以说mvc中的bean是整个ioc bean的子集</p>2023-03-28</li><br/><li><span>撇目双人聿</span> 👍（0） 💬（0）<p>Mac OS 上 Tomcat的启动参考：https:&#47;&#47;medium.com&#47;@raju6508&#47;a-beginners-guide-installing-apache-tomcat-on-your-mac-11fa0995f3c7 (一步
一步照着做就可以正常启动，特别要注意的是去官网下载 tomcat 的 tar 文件不要下载错了!)
</p>2024-11-09</li><br/><li><span>dirtychill</span> 👍（0） 💬（0）<p>MVC的bean指的是controller，是一种特殊的bean</p>2024-05-20</li><br/>
</ul>