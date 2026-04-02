你好，我是郭屹。今天我们继续手写MiniSpring。

到目前为止，我们已经初步实现了简单的AOP，做到了封装JDK的动态代理，并且定义了Advice，实现了调用前、调用时、调用后三个不同位置对代理对象进行增强的效果，而这些切面的定义也是配置在外部文件中的。我们现在在这个基础之上继续前进，引入Pointcut这个概念，批量匹配需要代理的方法。

## 引入Pointcut

我们再回头看一下代码，前面所有的代理方法，都是同一个名字——doAction。我们用以下代码将该方法名写死了，也就是说我们只认定这一个方法名为代理方法，而且名字是不能改的。

```java
if (method.getName().equals("doAction")) {
}
```

如果我们需要增加代理方法，或者就算不增加，只是觉得这个方法名不好想换一个，怎么办呢？当前这种方法自然不能满足我们的需求了。而这种对多个方法的代理需求又特别重要，因为业务上有可能会想对某一类方法进行增强，统一加上监控日志什么的，这种情况下，如果要逐个指定方法名就太麻烦了。

进一步考虑，即便我们这里可以支持多个方法名，但是匹配条件仍然是equals，也就是说，规则仅仅是按照方法名精确匹配的，这样做太不灵活了。

因此这节课我们考虑用方法名匹配规则进行通配，而这个配置则允许应用开发程序员在XML文件中自定义。这就是我们常说的**切点（Pointcut），按照规则匹配需要代理的方法**。

我们先确定一下，这节课代码改造完毕后，配置文件是什么样子的，我把变动最大的地方放在下面，供你参考。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<beans>
   <bean id="realaction" class="com.test.service.Action1" />
   <bena id="beforeAdvice" class="com.test.service.MyBeforeAdvice" />
   <bean id="advisor" class="com.minis.aop.NameMatchMethodPointcutAdvisor">
      <property type="com.minis.aop.Advice" name="advice" ref="beforeAdvice"/>
      <property type="String" name="mappedName" value="do*"/>
   </bean>
   <bean id="action" class="com.minis.aop.ProxyFactoryBean">
      <property type="String" name="interceptorName" value="advisor" />
      <property type="java.lang.Object" name="target" ref="realaction"/>
   </bean>
</beans>
```

由上述改动可以看出，我们新定义了一个NameMatchMethodPointcutAdvisor类作为Advisor，其中property属性中的value值为do\*，这就是我们说的方法规则，也就是匹配所有以do开头的方法名称。这里你也可以根据实际的业务情况按照一定的规则配置自定义的代理方法，而不仅仅局限于简单的方法名精确相等匹配。

有了这个Pointcut，我们就能用一条规则来支持多个代理方法了，这非常有用。如果能实现这个配置，就达到了我们想要的效果。

为了实现这个目标，最后构建出一个合适的NameMatchMethodPointcutAdvisor，我们定义了MethodMatcher、Pointcut与PointcutAdvisor三个接口。

MethodMatcher这个接口代表的是方法的匹配算法，内部的实现就是看某个名是不是符不符合某个模式。

```java
package com.minis.aop;
public interface MethodMatcher {
    boolean matches(Method method, Class<?> targetCLass);
}
```

Pointcut接口定义了切点，也就是返回一条匹配规则。

```java
package com.minis.aop;
public interface Pointcut {
    MethodMatcher getMethodMatcher();
}
```

PointcutAdvisor接口扩展了Advisor，内部可以返回Pointcut，也就是说这个Advisor有一个特性：能支持切点Pointcut了。这也是一个常规的Advisor，所以可以放到我们现有的AOP框架中，让它负责来增强。

```java
package com.minis.aop;
public interface PointcutAdvisor extends Advisor{
    Pointcut getPointcut();
}
```

接口定义完毕之后，接下来就要有这些接口对应的实现。实际我们在原理上可以实现一系列不同的规则，但是现在我们只能简单地使用名称进行模式匹配，不过能通过这个搞清楚原理就可以了。

## 如何匹配？

我们先来看核心问题：**如何匹配到方法？**我们默认的实现是NameMatchMethodPointcut和NameMatchMethodPointcutAdvisor。

```java
package com.minis.aop;
public class NameMatchMethodPointcut implements MethodMatcher, Pointcut{
    private String mappedName = "";
    public void setMappedName(String mappedName) {
        this.mappedName = mappedName;
    }
    @Override
    public boolean matches(Method method, Class<?> targetCLass) {
        if (mappedName.equals(method.getName()) || isMatch(method.getName(), mappedName)) {
            return true;
        }
        return false;
    }
    //核心方法，判断方法名是否匹配给定的模式
    protected boolean isMatch(String methodName, String mappedName) {
        return PatternMatchUtils.simpleMatch(mappedName, methodName);
    }
    @Override
    public MethodMatcher getMethodMatcher() {
        return null;
    }
}
```

我们看到了，这个类的核心方法就是**isMatch()**，它用到了一个工具类叫**PatterMatchUtils**。我们看一下这个工具类是怎么进行字符串匹配的。

```plain
/**
 * 用给定的模式匹配字符串。
 * 模式格式: "xxx*", "*xxx", "*xxx*" 以及 "xxx*yyy"，*代表若干个字符。
 */
public static boolean simpleMatch( String pattern,  String str) {
    //先判断串或者模式是否为空
	if (pattern == null || str == null) {
		return false;
	}
    //再判断模式中是否包含*
	int firstIndex = pattern.indexOf('*');
	if (firstIndex == -1) {
		return pattern.equals(str);
	}
    //是否首字符就是*,意味着这个是*XXX格式		
    if (firstIndex == 0) {
		if (pattern.length() == 1) {  //模式就是*,通配全部串
			return true;
		}
		//尝试查找下一个*
        int nextIndex = pattern.indexOf('*', 1);
		if (nextIndex == -1) { //没有下一个*，说明后续不需要再模式匹配了，直接endsWith判断
			return str.endsWith(pattern.substring(1));
		}
        //截取两个*之间的部分
		String part = pattern.substring(1, nextIndex);
		if (part.isEmpty()) { //这部分为空，形如**，则移到后面的模式进行匹配
			return simpleMatch(pattern.substring(nextIndex), str);
		}
        //两个*之间的部分不为空，则在串中查找这部分子串
		int partIndex = str.indexOf(part);
		while (partIndex != -1) {
            //模式串移位到第二个*之后，目标字符串移位到字串之后，递归再进行匹配
			if (simpleMatch(pattern.substring(nextIndex), str.substring(partIndex + part.length()))) {
				return true;
			}
			partIndex = str.indexOf(part, partIndex + 1);
		}
		return false;
	}

    //对不是*开头的模式，前面部分要精确匹配，然后后面的子串重新递归匹配
	return (str.length() >= firstIndex &&
		pattern.substring(0, firstIndex).equals(str.substring(0, firstIndex)) &&
		simpleMatch(pattern.substring(firstIndex), str.substring(firstIndex)));
}
```

看代码，整个匹配过程是一种扫描算法，从前往后扫描，按照 `*` 分节段一节一节匹配，因为长度不定，所以要用递归，详细说明代码上有注释。模式格式可以是:`"xxx*", "*xxx", "*xxx*"`以及`"xxx*yyy"`等。

有了上面的实现，我们就有了具体的匹配工具了。下面我们就来使用PatternMatchUtils这个工具类来进行字符串的匹配。

NameMatchMethodPointcutAdvisor的实现也比较简单，就是在内部增加了NameMatchMethodPointcut属性和MappedName属性。

```java
package com.minis.aop;
public class NameMatchMethodPointcutAdvisor implements PointcutAdvisor{
	private Advice advice = null;
	private MethodInterceptor methodInterceptor;
	private String mappedName;
	private final NameMatchMethodPointcut pointcut = new NameMatchMethodPointcut();
	public NameMatchMethodPointcutAdvisor() {
	}
	public NameMatchMethodPointcutAdvisor(Advice advice) {
		this.advice = advice;
	}
	public void setMethodInterceptor(MethodInterceptor methodInterceptor) {
		this.methodInterceptor = methodInterceptor;
	}
	public MethodInterceptor getMethodInterceptor() {
		return this.methodInterceptor;
	}
	public void setAdvice(Advice advice) {
		this.advice = advice;
		MethodInterceptor mi = null;
		if (advice instanceof BeforeAdvice) {
			mi = new MethodBeforeAdviceInterceptor((MethodBeforeAdvice)advice);
		}
		else if (advice instanceof AfterAdvice){
			mi = new AfterReturningAdviceInterceptor((AfterReturningAdvice)advice);
		}
		else if (advice instanceof MethodInterceptor) {
			mi = (MethodInterceptor)advice;
		}
		setMethodInterceptor(mi);
	}
	@Override
	public Advice getAdvice() {
		return this.advice;
	}
	@Override
	public Pointcut getPointcut() {
		return pointcut;
	}
	public void setMappedName(String mappedName) {
		this.mappedName = mappedName;
		this.pointcut.setMappedName(this.mappedName);
	}
}
```

上述实现代码对新增的Pointcut和MappedName属性进行了处理，这正好与我们定义的XML配置文件保持一致。而匹配的工作，则交给NameMatchMethodPointcut中的matches方法完成。如配置文件中的mappedName设置成了 `"do*"`，意味着所有do开头的方法都会匹配到。

```plain
<bean id="advisor" class="com.minis.aop.NameMatchMethodPointcutAdvisor">
    <property type="com.minis.aop.Advice" name="advice" ref="beforeAdvice"/>
    <property type="String" name="mappedName" value="do*"/>
</bean>
```

另外，我们还要注意setAdvice()这个方法，它现在通过advice来设置相应的Intereceptor，这一段逻辑以前是放在ProxyFactoryBean的initializeAdvisor()方法中的，现在移到了这里。现在这个新的Advisor就可以支持按照规则匹配方法来进行逻辑增强了。

## 相关类的改造

在上述工作完成后，相关的一些类也需要改造。JdkDynamicAopProxy类中的实现，现在我们不再需要将方法名写死了。你可以看一下改造之后的代码。

```java
package com.minis.aop;
public class JdkDynamicAopProxy implements AopProxy, InvocationHandler {
    Object target;
    PointcutAdvisor advisor;
    public JdkDynamicAopProxy(Object target, PointcutAdvisor advisor) {
        this.target = target;
        this.advisor = advisor;
    }
    @Override
    public Object getProxy() {
        Object obj = Proxy.newProxyInstance(JdkDynamicAopProxy.class.getClassLoader(), target.getClass().getInterfaces(), this);
        return obj;
    }
    @Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
        Class<?> targetClass = (target != null ? target.getClass() : null);
        if (this.advisor.getPointcut().getMethodMatcher().matches(method, targetClass)) {
            MethodInterceptor interceptor = this.advisor.getMethodInterceptor();
            MethodInvocation invocation =
                    new ReflectiveMethodInvocation(proxy, target, method, args, targetClass);
            return interceptor.invoke(invocation);
        }
        return null;
    }
}
```

看核心方法**invoke()**，以前的代码是 method.getName().equals(“doAction”)，即判断名字必须等于"doAction"，现在的判断条件则更具备扩展性了，是用Pointcut的matcher进行匹配校验。代码是 `this.advisor.getPointcut().getMethodMatcher().matches(method, targetClass))` 这一句。

原本定义的Advisor改为了更加具有颗粒度的PointcutAdvisor，自然连带着其他引用类也要一并修改。

DefaultAopProxyFactory的createAopProxy()方法中，Advisor参数现在就可以使用PointcutAdvisor类型了。

```java
package com.minis.aop;
public class DefaultAopProxyFactory implements AopProxyFactory{
    @Override
    public AopProxy createAopProxy(Object target, PointcutAdvisor advisor) {
        return new JdkDynamicAopProxy(target, advisor);
    }
}
```

而ProxyFactoryBean可以简化一下。

```java
package com.minis.aop;
public class ProxyFactoryBean implements FactoryBean<Object>, BeanFactoryAware {
    private BeanFactory beanFactory;
    private AopProxyFactory aopProxyFactory;
    private String interceptorName;
    private String targetName;
    private Object target;
    private ClassLoader proxyClassLoader = ClassUtils.getDefaultClassLoader();
    private Object singletonInstance;
    private PointcutAdvisor advisor;
    public ProxyFactoryBean() {
        this.aopProxyFactory = new DefaultAopProxyFactory();
    }

    //省略一些getter/setter
    
    protected AopProxy createAopProxy() {
        return getAopProxyFactory().createAopProxy(target, this.advisor);
    }
    @Override
    public Object getObject() throws Exception {
        initializeAdvisor();
        return getSingletonInstance();
    }
    private synchronized void initializeAdvisor() {
        Object advice = null;
        MethodInterceptor mi = null;
        try {
            advice = this.beanFactory.getBean(this.interceptorName);
        } catch (BeansException e) {
            e.printStackTrace();
        }
        this.advisor = (PointcutAdvisor) advice;
    }
    private synchronized Object getSingletonInstance() {
        if (this.singletonInstance == null) {
            this.singletonInstance = getProxy(createAopProxy());
        }
        return this.singletonInstance;
    }
}
```

可以看到，ProxyFactoryBean中的initializeAdvisor方法里，不再需要判断不同的Interceptor类型，相关实现被抽取到了NameMatchMethodPointcutAdvisor这个类中。

## 测试

最后，我们还是用以前的HelloWorldBean作为测试，现在可以这么写测试程序了。

```plain
	@Autowired
	IAction action;
	
	@RequestMapping("/testaop")
	public void doTestAop(HttpServletRequest request, HttpServletResponse response) {
		action.doAction();
	}
	@RequestMapping("/testaop2")
	public void doTestAop2(HttpServletRequest request, HttpServletResponse response) {
		action.doSomething();
	}	
```

配置文件就是我们最早希望达成的样子。

```plain
<bean id="realaction" class="com.test.service.Action1" /> 
<bena id="beforeAdvice" class="com.test.service.MyBeforeAdvice" />
<bean id="advisor" class="com.minis.aop.NameMatchMethodPointcutAdvisor">
    <property type="com.minis.aop.Advice" name="advice" ref="beforeAdvice"/>
    <property type="String" name="mappedName" value="do*"/>
</bean>  
<bean id="action" class="com.minis.aop.ProxyFactoryBean">
    <property type="String" name="interceptorName" value="advisor" />
    <property type="java.lang.Object" name="target" ref="realaction"/>	
</bean>
```

使用了新的Advisor，**匹配规则是 `"do*"`，真正执行的类是Action1**。

```plain
package com.test.service;
public class Action1 implements IAction {
	@Override
	public void doAction() {
		System.out.println("really do action1");
	}
	@Override
	public void doSomething() {
		System.out.println("really do something");
	}
}
```

这个Action1里面有两个方法，**doAction和doSomething**，名字都是以do开头的。因此，上面的配置规则会使业务程序在调用它们二者的时候，动态插入定义在MyBeforeAdvice里的逻辑。

## 小结

这节课，我们对查找方法名的办法进行了扩展，让系统可以按照某个规则来匹配方法名，这样便于统一处理。这个概念叫做Pointcut，熟悉数据库操作的人，可以把这个概念类比为SQL语句中的where条件。

基本的实现思路是使用一个特殊的Advisor，这个Advisor接收一个模式串，而这个模式串也是可以由用户配置在外部文件中的，然后提供isMatch() 方法，支持按照名称进行模式匹配。具体的字符串匹配工作，采用从前到后的扫描技术，分节段进行校验。

这两节课我们接触到了几个概念，我们再梳理一下。

- Join Point：连接点，连接点的含义是指明切面可以插入的地方，这个点可以在函数调用时，或者正常流程中某一行等位置，加入切面的处理逻辑，来实现代码增强的效果。
- Advice：通知，表示在特定的连接点采取的操作。
- Advisor：通知者，它实现了Advice。
- Interceptor：拦截器，作用是拦截流程，方便处理。
- Pointcut：切点。

完整源代码参见 [https://github.com/YaleGuo/minis](https://github.com/YaleGuo/minis)。

## 课后题

学完这节课的内容，我也给你留一道思考题。

我们现在实现的匹配规则是按照\*模式串进行匹配，如果需要支持不同的规则，应该如何改造我们的框架呢？

欢迎你在留言区与我交流讨论，也欢迎你把这节课分享给需要的朋友。我们下节课见！
<div><strong>精选留言（4）</strong></div><ul>
<li><span>不是早晨，就是黄昏</span> 👍（3） 💬（1）<p>能不能说明以下Advice接口和Advisor接口之间的关系，更进一步的是设计上的关系。</p>2023-04-24</li><br/><li><span>青莲</span> 👍（1） 💬（1）<p>每个匹配模式都可以实现PointcutAdvisor接口，尊循单一职责，如果要同时支持几种能力，可以考虑拐出一个管理类组合几种接口使用</p>2023-05-05</li><br/><li><span>欧阳利</span> 👍（0） 💬（1）<p>为什么Interceptor需要实现Advice接口</p>2023-04-30</li><br/><li><span>Ben Guo</span> 👍（1） 💬（0）<p>1. NameMatchMethodPointcut的getMethodMatcher()应该返回 this，而不是null；
2. JdkDynamicAopProxy的invoke方法，如果方法名不是mappedName匹配，应该要执行method.invoke()。 示例及源码中均返回null，导致该方法没有被执行。</p>2023-08-17</li><br/>
</ul>