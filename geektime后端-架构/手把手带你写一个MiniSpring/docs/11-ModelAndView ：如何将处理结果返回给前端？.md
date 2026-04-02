你好，我是郭屹。今天我们继续手写MiniSpring。这也是MVC内容的最后一节。

上节课，我们对HTTP请求传入的参数进行了自动绑定，并调用了目标方法。我们再看一下整个MVC的流程，现在就到最后一步了，也就是把返回数据回传给前端进行渲染。

![图片](https://static001.geekbang.org/resource/image/a5/f3/a51576e7bc6a3dba052274546f5311f3.png?wh=1660x916)

调用目标方法得到返回值之后，我们有两条路可以返回给前端。第一，返回的是简单的纯数据，第二，返回的是一个页面。

最近几年，第一种情况渐渐成为主流，也就是我们常说的“前后端分离”，后端处理完成后，只是把数据返回给前端，由前端自行渲染界面效果。比如前端用React或者Vue.js自行组织界面表达，这些前端脚本只需要从后端service拿到返回的数据就可以了。

第二种情况，由后端controller根据某种规则拿到一个页面，把数据整合进去，然后整个回传给前端浏览器，典型的技术就是JSP。这条路前些年是主流，最近几年渐渐不流行了。

我们手写MiniSpring的目的是深入理解Spring框架，剖析它的程序结构，所以作为学习的对象，这两种情况我们都会分析到。

## 处理返回数据

和绑定传入的参数相对，处理返回数据是反向的，也就是说，要从后端把方法得到的返回值（一个Java对象）按照某种字符串格式回传给前端。我们以这个@ResponseBody注解为例，来分析一下。

先定义一个接口，增加一个功能，让controller返回给前端的字符流数据可以进行格式转换。

```plain
package com.minis.web;

import java.io.IOException;
import javax.servlet.http.HttpServletResponse;

public interface HttpMessageConverter {
	void write(Object obj, HttpServletResponse response) throws IOException;
}
```

我们这里给一个默认的实现——DefaultHttpMessageConverter，把Object转成JSON串。

```plain
package com.minis.web;

import java.io.IOException;
import java.io.PrintWriter;
import javax.servlet.http.HttpServletResponse;

public class DefaultHttpMessageConverter implements HttpMessageConverter {
	String defaultContentType = "text/json;charset=UTF-8";
	String defaultCharacterEncoding = "UTF-8";
	ObjectMapper objectMapper;
	
	public ObjectMapper getObjectMapper() {
		return objectMapper;
	}
	public void setObjectMapper(ObjectMapper objectMapper) {
		this.objectMapper = objectMapper;
	}
	public void write(Object obj, HttpServletResponse response) throws IOException {
        response.setContentType(defaultContentType);
        response.setCharacterEncoding(defaultCharacterEncoding);
        writeInternal(obj, response);
        response.flushBuffer();
	}
	private void writeInternal(Object obj, HttpServletResponse response) throws IOException{
		String sJsonStr = this.objectMapper.writeValuesAsString(obj);
		PrintWriter pw = response.getWriter();
		pw.write(sJsonStr);
	}
}
```

这个message converter很简单，就是给response写字符串，用到的工具是ObjectMapper。我们就重点看看这个mapper是怎么做的。

定义一个接口ObjectMapper。

```plain
package com.minis.web;
public interface ObjectMapper {
	void setDateFormat(String dateFormat);
	void setDecimalFormat(String decimalFormat);
	String writeValuesAsString(Object obj);
}
```

最重要的接口方法就是writeValuesAsString()，将对象转成字符串。

我们给一个默认的实现——DefaultObjectMapper，在writeValuesAsString中拼JSON串。

```plain
package com.minis.web;

import java.lang.reflect.Field;
import java.math.BigDecimal;
import java.text.DecimalFormat;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.Date;

public class DefaultObjectMapper implements ObjectMapper{
	String dateFormat = "yyyy-MM-dd";
	DateTimeFormatter datetimeFormatter = DateTimeFormatter.ofPattern(dateFormat);
	
	String decimalFormat = "#,##0.00";
	DecimalFormat decimalFormatter = new DecimalFormat(decimalFormat);

	public DefaultObjectMapper() {
	}
	
	@Override
	public void setDateFormat(String dateFormat) {
		this.dateFormat = dateFormat;
		this.datetimeFormatter = DateTimeFormatter.ofPattern(dateFormat);
	}

	@Override
	public void setDecimalFormat(String decimalFormat) {
		this.decimalFormat = decimalFormat;
		this.decimalFormatter = new DecimalFormat(decimalFormat);
	}
	public String writeValuesAsString(Object obj) {
		String sJsonStr = "{";		
		Class<?> clz = obj.getClass();
		
		Field[] fields = clz.getDeclaredFields();
        //对返回对象中的每一个属性进行格式转换
		for (Field field : fields) {
			String sField = "";
			Object value = null;
			Class<?> type = null;
			String name = field.getName();
			String strValue = "";
			field.setAccessible(true);
			value = field.get(obj);
			type = field.getType();
			
            //针对不同的数据类型进行格式转换
			if (value instanceof Date) {
				LocalDate localDate = ((Date)value).toInstant().atZone(ZoneId.systemDefault()).toLocalDate();
				strValue = localDate.format(this.datetimeFormatter);
			}
			else if (value instanceof BigDecimal || value instanceof Double || value instanceof Float){
				strValue = this.decimalFormatter.format(value);
			}
			else {
				strValue = value.toString();
			}
			
            //拼接Json串
			if (sJsonStr.equals("{")) {
				sField = "\"" + name + "\":\"" + strValue + "\"";
			}
			else {
				sField = ",\"" + name + "\":\"" + strValue + "\"";	
			}
			
			sJsonStr += sField;
		}
		sJsonStr += "}";
		return sJsonStr;
	}
}
```

实际转换过程用到了LocalDate和DecimalFormatter。从上述代码中也可以看出，目前为止，我们也只支持Date、Number和String三种类型。你自己可以考虑扩展到更多的数据类型。

那么我们在哪个地方用这个工具来处理返回的数据呢？其实跟绑定参数一样，数据返回之前，也是要经过方法调用。所以我们还是要回到RequestMappingHandlerAdapter这个类，增加一个属性messageConverter，通过它来转换数据。

程序变成了这个样子。

```plain
	public class RequestMappingHandlerAdapter implements HandlerAdapter {
		private WebBindingInitializer webBindingInitializer = null;
		private HttpMessageConverter messageConverter = null;
```

现在既有传入的webBingingInitializer，也有传出的messageConverter。  
在关键方法invokeHandlerMethod()里增加对@ResponseBody的处理，也就是调用messageConverter.write()把方法返回值转换成字符串。

```plain
	protected ModelAndView invokeHandlerMethod(HttpServletRequest request,
		HttpServletResponse response, HandlerMethod handlerMethod) throws Exception {
		... ...
		if (invocableMethod.isAnnotationPresent(ResponseBody.class)){ //ResponseBody
	        this.messageConverter.write(returnObj, response);
		}	
		... ...
	}
```

同样的webBindingInitializer和messageConverter都可以通过配置注入。

```plain
	<bean id="handlerAdapter" class="com.minis.web.servlet.RequestMappingHandlerAdapter"> 
	 <property type="com.minis.web.HttpMessageConverter" name="messageConverter" ref="messageConverter"/>
	 <property type="com.minis.web.WebBindingInitializer" name="webBindingInitializer" ref="webBindingInitializer"/>
	</bean>
	
	<bean id="webBindingInitializer" class="com.test.DateInitializer" /> 
	
	<bean id="messageConverter" class="com.minis.web.DefaultHttpMessageConverter"> 
	 <property type="com.minis.web.ObjectMapper" name="objectMapper" ref="objectMapper"/>
	</bean>
	<bean id="objectMapper" class="com.minis.web.DefaultObjectMapper" >
	 <property type="String" name="dateFormat" value="yyyy/MM/dd"/>
	 <property type="String" name="decimalFormat" value="###.##"/>
	</bean>
```

最后在DispatcherServlet里，通过getBean获取handlerAdapter，当然这里需要约定一个名字，整个过程就连起来了。

```plain
	protected void initHandlerAdapters(WebApplicationContext wac) {
 		this.handlerAdapter = (HandlerAdapter) wac.getBean(HANDLER_ADAPTER_BEAN_NAME);
    }
```

测试的客户程序HelloWorldBean修改如下：

```plain
	@RequestMapping("/test7")
	@ResponseBody
	public User doTest7(User user) {
		user.setName(user.getName() + "---");
		user.setBirthday(new Date());
		return user;
	}	
```

程序里面声明了一个注解@ResponseBody，程序中返回的是对象User，框架处理的时候用message converter将其转换成JSON字符串返回。

到这里，我们就知道MVC是如何把方法返回对象自动转换成response字符串的了。我们在调用目标方法后，通过messageConverter进行转换，它要分别转换每一种数据类型的格式，同时格式可以由用户自己指定。

## ModelAndView

调用完目标方法，得到返回值，把数据按照指定格式转换好之后，就该处理它们，并把它们送到前端去了。我们用一个统一的结构，包装调用方法之后返回的数据，以及需要启动的前端页面，这个结构就是ModelAndView，我们看下它的定义。

```plain
package com.minis.web.servlet;

import java.util.HashMap;
import java.util.Map;

public class ModelAndView {
	private Object view;
	private Map<String, Object> model = new HashMap<>();

	public ModelAndView() {
	}
	public ModelAndView(String viewName) {
		this.view = viewName;
	}
	public ModelAndView(View view) {
		this.view = view;
	}
	public ModelAndView(String viewName, Map<String, ?> modelData) {
		this.view = viewName;
		if (modelData != null) {
			addAllAttributes(modelData);
		}
	}
	public ModelAndView(View view, Map<String, ?> model) {
		this.view = view;
		if (model != null) {
			addAllAttributes(model);
		}
	}
	public ModelAndView(String viewName, String modelName, Object modelObject) {
		this.view = viewName;
		addObject(modelName, modelObject);
	}
	public ModelAndView(View view, String modelName, Object modelObject) {
		this.view = view;
		addObject(modelName, modelObject);
	}
	public void setViewName(String viewName) {
		this.view = viewName;
	}
	public String getViewName() {
		return (this.view instanceof String ? (String) this.view : null);
	}
	public void setView(View view) {
		this.view = view;
	}
	public View getView() {
		return (this.view instanceof View ? (View) this.view : null);
	}
	public boolean hasView() {
		return (this.view != null);
	}
	public boolean isReference() {
		return (this.view instanceof String);
	}
	public Map<String, Object> getModel() {
		return this.model;
	}
	private void addAllAttributes(Map<String, ?> modelData) {
		if (modelData != null) {
			model.putAll(modelData);
		}
	}
	public void addAttribute(String attributeName, Object attributeValue) {
		model.put(attributeName, attributeValue);
	}
	public ModelAndView addObject(String attributeName, Object attributeValue) {
		addAttribute(attributeName, attributeValue);
		return this;
	}
}
```

这个类里面定义了Model和View，分别代表返回的数据以及前端表示，我们这里就是指JSP。

有了这个结构，我们回头看调用目标方法之后返回的那段代码，把类RequestMappingHandlerAdapter的方法invokeHandlerMethod()返回值改为ModelAndView。

```plain
protected ModelAndView invokeHandlerMethod(HttpServletRequest request,
       			HttpServletResponse response, HandlerMethod handlerMethod) throws Exception {
	ModelAndView mav = null;
    //如果是ResponseBody注解，仅仅返回值，则转换数据格式后直接写到response
	if (invocableMethod.isAnnotationPresent(ResponseBody.class)){ //ResponseBody
	        this.messageConverter.write(returnObj, response);
	}
	else { //返回的是前端页面
		if (returnObj instanceof ModelAndView) {
			mav = (ModelAndView)returnObj;
		}
		else if(returnObj instanceof String) { //字符串也认为是前端页面
			String sTarget = (String)returnObj;
			mav = new ModelAndView();
			mav.setViewName(sTarget);
		}
	}
		
	return mav;
}
```

通过上面这段代码我们可以知道，调用方法返回的时候，我们处理了三种情况。

1. 如果声明返回的是ResponseBody，那就用MessageConvert把结果转换一下，之后直接写回response。
2. 如果声明返回的是ModelAndView，那就把结果包装成一个ModelAndView对象返回。
3. 如果声明返回的是字符串，就以这个字符串为目标，最后还是包装成ModelAndView返回。

## View

到这里，调用方法就返回了。不过事情还没完，之后我们就把注意力转移到MVC环节的最后一部分：View层。View，顾名思义，就是负责前端界面展示的部件，当然它最主要的功能就是，把数据按照一定格式显示并输出到前端界面上，因此可以抽象出它的核心方法render()，我们可以看下View接口的定义。

```plain
package com.minis.web.servlet;

import java.util.Map;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;

public interface View {
	void render(Map<String, ?> model, HttpServletRequest request, HttpServletResponse response)
			throws Exception;
	default String getContentType() {
		return null;
	}
	void setContentType(String contentType);
	void setUrl(String url);
	String getUrl();
	void setRequestContextAttribute(String requestContextAttribute);
	String getRequestContextAttribute();
}
```

这个render()方法的思路很简单，就是获取HTTP请求的request和response，以及中间产生的业务数据Model，最后写到response里面。request和response是HTTP访问时由服务器创建的，ModelAndView是由我们的MiniSpring创建的。

准备好数据之后，我们以JSP为例，来看看怎么把结果显示在前端界面上。其实，这跟我们自己手工写JSP是一样的，先设置属性值，然后把请求转发（forward）出去，就像下面我给出的这几行代码。

```plain
	request.setAttribute(key1, value1);
	request.setAttribute(key2, value2);
	request.getRequestDispatcher(url).forward(request, response);
```

照此办理，DispatcherServlet的doDispatch()方法调用目标方法后，可以通过一个render()来渲染这个JSP，你可以看一下doDispatch()相关代码。

```plain
	HandlerAdapter ha = this.handlerAdapter;
	mv = ha.handle(processedRequest, response, handlerMethod);
	render(processedRequest, response, mv);
```

这个render()方法可以考虑这样实现。

```plain
	//用jsp 进行render
	protected void render( HttpServletRequest request, HttpServletResponse response,ModelAndView mv) throws Exception {
		//获取model，写到request的Attribute中：
		Map<String, Object> modelMap = mv.getModel();
		for (Map.Entry<String, Object> e : modelMap.entrySet()) {
			request.setAttribute(e.getKey(),e.getValue());
		}
        //输出到目标JSP
		String sTarget = mv.getViewName();
		String sPath = "/" + sTarget + ".jsp";
		request.getRequestDispatcher(sPath).forward(request, response);
	}
```

我们看到了，程序从Model里获取数据，并将其作为属性值写到request的attribute里，然后获取页面路径，再显示出来，跟手工写JSP过程一样，简明有效。

但是上面的程序有两个问题，一是这个程序是怎么找到显示目标View的呢？上面的例子，我们是写了一个固定的路径/xxxx.jsp，但实际上这些应该是可以让用户自己来配置的，不应该写死在代码中。二是拿到View后，直接用的是request的forward()方法，这只对JSP有效，没办法扩展到别的页面，比如说Excel、PDF。所以上面的render()是需要改造的。

先解决第一个问题，怎么找到需要显示的目标View? 这里又得引出了一个新的部件ViewResolver，由它来根据某个规则或者是用户配置来确定View在哪里，下面是它的定义。

```plain
package com.minis.web.servlet;

public interface ViewResolver {
	View resolveViewName(String viewName) throws Exception;
}
```

这个ViewResolver就是根据View的名字找到实际的View，有了这个ViewResolver，就不用写死JSP路径，而是可以通过resolveViewName()方法来获取一个View。拿到目标View之后，我们把实际渲染的功能交给View自己完成。我们把程序改成下面这个样子。

```plain
	protected void render( HttpServletRequest request, HttpServletResponse response,ModelAndView mv) throws Exception {
		String sTarget = mv.getViewName();
		Map<String, Object> modelMap = mv.getModel();
		View view = resolveViewName(sTarget, modelMap, request);
		view.render(modelMap, request, response);
	}
```

在MiniSpring里，我们提供一个InternalResourceViewResolver，作为启动JSP的默认实现，它是这样定位到显示目标View的。

```plain
package com.minis.web.servlet.view;

import com.minis.web.servlet.View;
import com.minis.web.servlet.ViewResolver;

public class InternalResourceViewResolver implements ViewResolver{
	private Class<?> viewClass = null;
	private String viewClassName = "";	
	private String prefix = "";
	private String suffix = "";
	private String contentType;
	
	public InternalResourceViewResolver() {
		if (getViewClass() == null) {
			setViewClass(JstlView.class);			
		}
	}
	
	public void setViewClassName(String viewClassName) {
		this.viewClassName = viewClassName;
		Class<?> clz = null;
		try {
			clz = Class.forName(viewClassName);
		} catch (ClassNotFoundException e) {
			e.printStackTrace();
		}
		setViewClass(clz);
	}
	
	protected String getViewClassName() {
		return this.viewClassName;
	}
	public void setViewClass(Class<?> viewClass) {
		this.viewClass = viewClass;
	}
	protected Class<?> getViewClass() {
		return this.viewClass;
	}
	public void setPrefix(String prefix) {
		this.prefix = (prefix != null ? prefix : "");
	}
	protected String getPrefix() {
		return this.prefix;
	}
	public void setSuffix(String suffix) {
		this.suffix = (suffix != null ? suffix : "");
	}
	protected String getSuffix() {
		return this.suffix;
	}
	public void setContentType(String contentType) {
		this.contentType = contentType;
	}
	protected String getContentType() {
		return this.contentType;
	}

	@Override
	public View resolveViewName(String viewName) throws Exception {
		return buildView(viewName);
	}

	protected View buildView(String viewName) throws Exception {
		Class<?> viewClass = getViewClass();

		View view = (View) viewClass.newInstance();
		view.setUrl(getPrefix() + viewName + getSuffix());

		String contentType = getContentType();
		view.setContentType(contentType);

		return view;
	}
}
```

从代码里可以知道，它先创建View实例，通过配置生成URL定位到显示目标，然后设置ContentType。这个过程也跟我们手工写JSP是一样的。通过这个resolver，就解决了第一个问题，框架会根据配置从/jsp/路径下拿到xxxx.jsp页面。

对于第二个问题，DispatcherServlet是不应该负责实际的渲染工作的，它只负责控制流程，并不知道如何渲染前端，这些工作由具体的View实现类来完成。所以我们不再把request forward()这样的代码写到DispatcherServlet里，而是写到View的render()方法中。

MiniSpring也提供了一个默认的实现：JstlView。

```plain
package com.minis.web.servlet.view;

import java.util.Map;
import java.util.Map.Entry;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import com.minis.web.servlet.View;

public class JstlView implements View{
	public static final String DEFAULT_CONTENT_TYPE = "text/html;charset=ISO-8859-1";
	private String contentType = DEFAULT_CONTENT_TYPE;
	private String requestContextAttribute;
	private String beanName;
	private String url;

	public void setContentType(String contentType) {
		this.contentType = contentType;
	}
	public String getContentType() {
		return this.contentType;
	}
	public void setRequestContextAttribute(String requestContextAttribute) {
		this.requestContextAttribute = requestContextAttribute;
	}
	public String getRequestContextAttribute() {
		return this.requestContextAttribute;
	}
	public void setBeanName(String beanName) {
		this.beanName = beanName;
	}
	public String getBeanName() {
		return this.beanName;
	}
	public void setUrl(String url) {
		this.url = url;
	}
	public String getUrl() {
		return this.url;
	}
	public void render(Map<String, ?> model, HttpServletRequest request, HttpServletResponse response)
			throws Exception {
		for (Entry<String, ?> e : model.entrySet()) {
			request.setAttribute(e.getKey(),e.getValue());
		}	
		request.getRequestDispatcher(getUrl()).forward(request, response);
	}
}
```

从代码里可以看到，程序其实还是一样的，因为要完成的任务是一样的，只不过现在这个代码移到了View这个位置。但是这个位置的移动，就让前端的渲染工作解耦了，DispatcherServlet不负责渲染了，我们可以由此扩展到多种前端，如Excel、PDF等等。

然后，对于InternalResourceViewResolver和JstlView，我们可以再次利用IoC容器机制通过配置进行注入。

```plain
    <bean id="viewResolver" class="com.minis.web.servlet.view.InternalResourceViewResolver" >
	 <property type="String" name="viewClassName" value="com.minis.web.servlet.view.JstlView" />
	 <property type="String" name="prefix" value="/jsp/" />
	 <property type="String" name="suffix" value=".jsp" />
    </bean>
```

当DispatcherServlet初始化的时候，根据配置获取实际的ViewResolver和View。

整个过程就完美结束了。

## 小结

这节课，我们重点探讨了MVC调用目标方法之后的处理过程，如何自动转换数据、如何找到指定的View、如何去渲染页面。我们可以看到，作为一个框架，我们没有规定数据要如何转换格式，而是交给了MessageConverter去做；我们也没有规定如何找到这些目标页面，而是交给了ViewResolver去做；我们同样没有规定如何去渲染前端界面，而是通过View这个接口去做。我们可以自由地实现具体的场景。

这里，我们的重点并不是去看具体代码如何实现，而是要学习Spring框架如何分解这些工作，把专门的事情交给专门的部件去完成。虽然现在已经不流行JSP，我们不用特地去学习它，但是把这些部件解耦的框架思想，却是值得我们好好琢磨的。

完整源代码参见：[https://github.com/YaleGuo/minis](https://github.com/YaleGuo/minis)

## 课后题

学完这节课，我也给你留一道思考题。现在我们返回的数据只支持Date、Number和String三种类型，如何扩展到更多的数据类型？现在也只支持JSP，如何扩展到别的前端？欢迎你在留言区和我交流讨论，也欢迎你把这节课分享给需要的朋友。我们下节课见！
<div><strong>精选留言（7）</strong></div><ul>
<li><span>Geek3485</span> 👍（1） 💬（1）<p>老师的minitomcat源码在哪可以看到</p>2023-08-04</li><br/><li><span>马儿</span> 👍（0） 💬（2）<p>1.目前如果加了ResponseBody注解返回String的话返回的是String在内存中的信息，而需要的字符串值字段在这个json中也是内存中的地址值，这将导致结果不符合预期，这里应该还需要对writeValuesAsString这个函数优化一下，或者是拓展一些其他的实现。
2. 目前在InternalResourceViewResolver中写死了处理Jsp的View，可以在加一个有参构造函数，传入参数为资源类型，InternalResourceViewResolver内部维护一个资源类型和View的Map

希望老师可以抽时间加一些答疑课，对之前一些同学问到的问题在课上统一解答一下。或者是将一些mini-spring中的一些拓展点提供一个思路，比如上节课遇到的传参数不支持基本类型和自定义类型中WebDataBinder不可用的问题。谢谢老师。</p>2023-04-08</li><br/><li><span>peter</span> 👍（0） 💬（1）<p>请教老师几个问题：
Q1：本文所讲的内容，就是模仿SpringMVC，对吗？
Q2：很多信息都存在request中，那这个request对象会占用很大内存吗？对于一个用户，一般地讲，会占用多大内存？比如10M？
Q3：View这个类，是生成一个页面文件吗？还是把数据填充到已经存在的页面上？</p>2023-04-06</li><br/><li><span>梦某人</span> 👍（2） 💬（0）<p>打卡成功，从理解上这节课并不难，虽然很多代码（主要是User类和一些辅助）需要参考GitHub不然无法进行。但是调整环境浪费了接近2个小时，因为访问jsp一直报404的错误，后来意识到是没在idea的Project Structe 中的 Module设置资源文件夹。。。。另外目前的返回来讲，string包装成了 ModelAndView，但是这样做在reander的时候无法辨别，导致最基础的 &#47;test反而无法访问。思考题来说，View的两个类，一个负责分析内容，一个负责渲染内容，将 ViewResolver 进行扩展就可以解决相关问题了。</p>2023-04-18</li><br/><li><span>Geek_b3425a</span> 👍（1） 💬（0）<p>最新版初始化的handleAdapter的时候并没有给webBindingInitialize赋值，只给了一个set方法但是没有找到调用的地方，这样有请求进来的时候不会就空指针了吗？是我漏看东西了吗</p>2023-09-14</li><br/><li><span>Geek_b3425a</span> 👍（0） 💬（0）<p>

有点不懂，老师仓库代码，handleMaping和handleAdapter都实现了applicationContextAware接口，类中applicationContext属性是abstractApplicationContext在getBean的时候给set进去的，不懂得是在容器启动的时候并没有这个bean相应的实体对象，并不会调用这个方法，我本地handleMapping中容器属性也是空，并没有掉set方法给他赋值</p>2023-09-14</li><br/><li><span>C.</span> 👍（0） 💬（1）<p>结束结束！</p>2023-04-06</li><br/>
</ul>