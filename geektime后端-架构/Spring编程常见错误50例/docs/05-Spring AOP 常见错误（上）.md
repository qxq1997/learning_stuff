你好，我是傅健。这节课开始，我们聊聊Spring AOP使用中常遇到的一些问题。

Spring AOP是Spring中除了依赖注入外（DI）最为核心的功能，顾名思义，AOP即Aspect Oriented Programming，翻译为面向切面编程。

而Spring AOP则利用CGlib和JDK动态代理等方式来实现运行期动态方法增强，其目的是将与业务无关的代码单独抽离出来，使其逻辑不再与业务代码耦合，从而降低系统的耦合性，提高程序的可重用性和开发效率。因而AOP便成为了日志记录、监控管理、性能统计、异常处理、权限管理、统一认证等各个方面被广泛使用的技术。

追根溯源，我们之所以能无感知地在容器对象方法前后任意添加代码片段，那是由于Spring在运行期帮我们把切面中的代码逻辑动态“织入”到了容器对象方法内，所以说**AOP本质上就是一个代理模式**。然而在使用这种代理模式时，我们常常会用不好，那么这节课我们就来解析下有哪些常见的问题，以及背后的原理是什么。

## 案例1：this调用的当前类方法无法被拦截

假设我们正在开发一个宿舍管理系统，这个模块包含一个负责电费充值的类ElectricService，它含有一个充电方法charge()：

```
@Service
public class ElectricService {

    public void charge() throws Exception {
        System.out.println("Electric charging ...");
        this.pay();
    }

    public void pay() throws Exception {
        System.out.println("Pay with alipay ...");
        Thread.sleep(1000);
    }

}
```

在这个电费充值方法charge()中，我们会使用支付宝进行充值。因此在这个方法中，我加入了pay()方法。为了模拟pay()方法调用耗时，代码执行了休眠1秒，并在charge()方法里使用 this.pay()的方式调用这种支付方法。

但是因为支付宝支付是第三方接口，我们需要记录下接口调用时间。这时候我们就引入了一个@Around的增强 ，分别记录在pay()方法执行前后的时间，并计算出执行pay()方法的耗时。

```
@Aspect
@Service
@Slf4j
public class AopConfig {
    @Around("execution(* com.spring.puzzle.class5.example1.ElectricService.pay()) ")
    public void recordPayPerformance(ProceedingJoinPoint joinPoint) throws Throwable {
        long start = System.currentTimeMillis();
        joinPoint.proceed();
        long end = System.currentTimeMillis();
        System.out.println("Pay method time cost（ms）: " + (end - start));
    }
}
```

最后我们再通过定义一个Controller来提供电费充值接口，定义如下：

```
@RestController
public class HelloWorldController {
    @Autowired
    ElectricService electricService;
    @RequestMapping(path = "charge", method = RequestMethod.GET)
    public void charge() throws Exception{
          electricService.charge();
    };
}
```

完成代码后，我们访问上述接口，会发现这段计算时间的切面并没有执行到，输出日志如下：

> Electric charging ...  
> Pay with alipay ...

回溯之前的代码可知，在@Around的切面类中，我们很清晰地定义了切面对应的方法，但是却没有被执行到。这说明了在类的内部，通过this方式调用的方法，是没有被Spring AOP增强的。这是为什么呢？我们来分析一下。

### 案例解析

我们可以从源码中找到真相。首先来设置个断点，调试看看this对应的对象是什么样的：

![](https://static001.geekbang.org/resource/image/e0/5f/e0f4b047228fac437d57f56dcd18185f.png?wh=700%2A332)

可以看到，this对应的就是一个普通的ElectricService对象，并没有什么特别的地方。再看看在Controller层中自动装配的ElectricService对象是什么样：

![](https://static001.geekbang.org/resource/image/b2/f9/b24f00b4b96c46983295da05180174f9.png?wh=1112%2A258)

可以看到，这是一个被Spring增强过的Bean，所以执行charge()方法时，会执行记录接口调用时间的增强操作。而this对应的对象只是一个普通的对象，并没有做任何额外的增强。

为什么this引用的对象只是一个普通对象呢？这还要从Spring AOP增强对象的过程来看。但在此之前，有些基础我需要在这里强调下。

**1. Spring AOP的实现**

Spring AOP的底层是动态代理。而创建代理的方式有两种，**JDK的方式和CGLIB的方式**。JDK动态代理只能对实现了接口的类生成代理，而不能针对普通类。而CGLIB是可以针对类实现代理，主要是对指定的类生成一个子类，覆盖其中的方法，来实现代理对象。具体区别可参考下图：

![](https://static001.geekbang.org/resource/image/99/a1/99c74d82d811ec567b28a24ccd6e85a1.png?wh=1191%2A573)

**2. 如何使用Spring AOP**

在Spring Boot中，我们一般只要添加以下依赖就可以直接使用AOP功能：

> &lt;dependency&gt;  
> &lt;groupId&gt;org.springframework.boot&lt;/groupId&gt;  
> &lt;artifactId&gt;spring-boot-starter-aop&lt;/artifactId&gt;  
> &lt;/dependency&gt;

而对于非Spring Boot程序，除了添加相关AOP依赖项外，我们还常常会使用@EnableAspectJAutoProxy来开启AOP功能。这个注解类引入（Import）AspectJAutoProxyRegistrar，它通过实现ImportBeanDefinitionRegistrar的接口方法来完成AOP相关Bean的准备工作。

补充完最基本的Spring底层知识和使用知识后，我们具体看下创建代理对象的过程。先来看下调用栈：

![](https://static001.geekbang.org/resource/image/1f/2a/1fb3735e51a8e06833f065a175517c2a.png?wh=1565%2A570)

创建代理对象的时机就是创建一个Bean的时候，而创建的的关键工作其实是由AnnotationAwareAspectJAutoProxyCreator完成的。它本质上是一种BeanPostProcessor。所以它的执行是在完成原始Bean构建后的初始化Bean（initializeBean）过程中。而它到底完成了什么工作呢？我们可以看下它的postProcessAfterInitialization方法：

```
public Object postProcessAfterInitialization(@Nullable Object bean, String beanName) {
   if (bean != null) {
      Object cacheKey = getCacheKey(bean.getClass(), beanName);
      if (this.earlyProxyReferences.remove(cacheKey) != bean) {
         return wrapIfNecessary(bean, beanName, cacheKey);
      }
   }
   return bean;
}
```

上述代码中的关键方法是wrapIfNecessary，顾名思义，**在需要使用AOP时，它会把创建的原始的Bean对象wrap成代理对象作为Bean返回**。具体到这个wrap过程，可参考下面的关键代码行：

```
protected Object wrapIfNecessary(Object bean, String beanName, Object cacheKey) {
   // 省略非关键代码
   Object[] specificInterceptors = getAdvicesAndAdvisorsForBean(bean.getClass(), beanName, null);
   if (specificInterceptors != DO_NOT_PROXY) {
      this.advisedBeans.put(cacheKey, Boolean.TRUE);
      Object proxy = createProxy(
            bean.getClass(), beanName, specificInterceptors, new SingletonTargetSource(bean));
      this.proxyTypes.put(cacheKey, proxy.getClass());
      return proxy;
   }
   // 省略非关键代码 
}

```

上述代码中，第6行的createProxy调用是创建代理对象的关键。具体到执行过程，它首先会创建一个代理工厂，然后将通知器（advisors）、被代理对象等信息加入到代理工厂，最后通过这个代理工厂来获取代理对象。一些关键过程参考下面的方法：

```
protected Object createProxy(Class<?> beanClass, @Nullable String beanName,
      @Nullable Object[] specificInterceptors, TargetSource targetSource) {
  // 省略非关键代码
  ProxyFactory proxyFactory = new ProxyFactory();
  if (!proxyFactory.isProxyTargetClass()) {
   if (shouldProxyTargetClass(beanClass, beanName)) {
      proxyFactory.setProxyTargetClass(true);
   }
   else {
      evaluateProxyInterfaces(beanClass, proxyFactory);
   }
  }
  Advisor[] advisors = buildAdvisors(beanName, specificInterceptors);
  proxyFactory.addAdvisors(advisors);
  proxyFactory.setTargetSource(targetSource);
  customizeProxyFactory(proxyFactory);
   // 省略非关键代码
  return proxyFactory.getProxy(getProxyClassLoader());
}
```

经过这样一个过程，一个代理对象就被创建出来了。我们从Spring中获取到的对象都是这个代理对象，所以具有AOP功能。而之前直接使用this引用到的只是一个普通对象，自然也就没办法实现AOP的功能了。

### 问题修正

从上述案例解析中，我们知道，**只有引用的是被动态代理创建出来的对象，才会被Spring增强，具备AOP该有的功能**。那什么样的对象具备这样的条件呢？

有两种。一种是被@Autowired注解的，于是我们的代码可以改成这样，即通过@Autowired的方式，在类的内部，自己引用自己：

```
@Service
public class ElectricService {
    @Autowired
    ElectricService electricService;
    public void charge() throws Exception {
        System.out.println("Electric charging ...");
        //this.pay();
        electricService.pay();
    }
    public void pay() throws Exception {
        System.out.println("Pay with alipay ...");
        Thread.sleep(1000);
    }
}
```

另一种方法就是直接从AopContext获取当前的Proxy。那你可能会问了，AopContext是什么？简单说，它的核心就是通过一个ThreadLocal来将Proxy和线程绑定起来，这样就可以随时拿出当前线程绑定的Proxy。

不过使用这种方法有个小前提，就是需要在@EnableAspectJAutoProxy里加一个配置项exposeProxy = true，表示将代理对象放入到ThreadLocal，这样才可以直接通过 AopContext.currentProxy()的方式获取到，否则会报错如下：

![](https://static001.geekbang.org/resource/image/0e/98/0e42f3129e1c098b0f860f1f7f2e6298.png?wh=1489%2A563)

按这个思路，我们修改下相关代码：

```
import org.springframework.aop.framework.AopContext;
import org.springframework.stereotype.Service;
@Service
public class ElectricService {
    public void charge() throws Exception {
        System.out.println("Electric charging ...");
        ElectricService electric = ((ElectricService) AopContext.currentProxy());
        electric.pay();
    }
    public void pay() throws Exception {
        System.out.println("Pay with alipay ...");
        Thread.sleep(1000);
    }
}
```

同时，不要忘记修改EnableAspectJAutoProxy注解的exposeProxy属性，示例如下：

```
@SpringBootApplication
@EnableAspectJAutoProxy(exposeProxy = true)
public class Application {
    // 省略非关键代码
}
```

这两种方法的效果其实是一样的，最终我们打印出了期待的日志，到这，问题顺利解决了。

```
Electric charging ...
Pay with alipay ...
Pay method time cost(ms): 1005
```

## 案例2：直接访问被拦截类的属性抛空指针异常

接上一个案例，在宿舍管理系统中，我们使用了charge()方法进行支付。在统一结算的时候我们会用到一个管理员用户付款编号，这时候就用到了几个新的类。

User类，包含用户的付款编号信息：

```
public class User {
    private String payNum;
    public User(String payNum) {
        this.payNum = payNum;
    }
    public String getPayNum() {
        return payNum;
    }
    public void setPayNum(String payNum) {
        this.payNum = payNum;
    }
}
```

AdminUserService类，包含一个管理员用户（User），其付款编号为202101166；另外，这个服务类有一个login()方法，用来登录系统。

```
@Service
public class AdminUserService {
    public final User adminUser = new User("202101166");
    
    public void login() {
        System.out.println("admin user login...");
    }
}
```

我们需要修改ElectricService类实现这个需求：在电费充值时，需要管理员登录并使用其编号进行结算。完整代码如下：

```
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
@Service
public class ElectricService {
    @Autowired
    private AdminUserService adminUserService;
    public void charge() throws Exception {
        System.out.println("Electric charging ...");
        this.pay();
    }

    public void pay() throws Exception {
        adminUserService.login();
        String payNum = adminUserService.adminUser.getPayNum();
        System.out.println("User pay num : " + payNum);
        System.out.println("Pay with alipay ...");
        Thread.sleep(1000);
    }
}
```

代码完成后，执行charge()操作，一切正常：

```
Electric charging ...
admin user login...
User pay num : 202101166
Pay with alipay ...
```

这时候，由于安全需要，就需要管理员在登录时，记录一行日志以便于以后审计管理员操作。所以我们添加一个AOP相关配置类，具体如下：

```
@Aspect
@Service
@Slf4j
public class AopConfig {
    @Before("execution(* com.spring.puzzle.class5.example2.AdminUserService.login(..)) ")
    public void logAdminLogin(JoinPoint pjp) throws Throwable {
        System.out.println("! admin login ...");
    }
}
```

添加这段代码后，我们执行charge()操作，发现不仅没有相关日志，而且在执行下面这一行代码的时候直接抛出了NullPointerException：

> String payNum = dminUserService.user.getPayNum();

本来一切正常的代码，因为引入了一个AOP切面，抛出了NullPointerException。这会是什么原因呢？我们先debug一下，来看看加入AOP后调用的对象是什么样子。

![](https://static001.geekbang.org/resource/image/cd/a2/cd48479a45c2b06621c2e07a33f519a2.png?wh=917%2A419)

可以看出，加入AOP后，我们的对象已经是一个代理对象了，如果你眼尖的话，就会发现在上图中，属性adminUser确实为null。为什么会这样？为了解答这个诡异的问题，我们需要进一步理解Spring使用CGLIB生成Proxy的原理。

### 案例解析

我们在上一个案例中解析了创建Spring Proxy的大体过程，在这里，我们需要进一步研究一下通过Proxy创建出来的是一个什么样的对象。正常情况下，AdminUserService只是一个普通的对象，而AOP增强过的则是一个AdminUserService $$EnhancerBySpringCGLIB$$xxxx。

这个类实际上是AdminUserService的一个子类。它会overwrite所有public和protected方法，并在内部将调用委托给原始的AdminUserService实例。

从具体实现角度看，CGLIB中AOP的实现是基于org.springframework.cglib.proxy包中 Enhancer和MethodInterceptor两个接口来实现的。

**整个过程，我们可以概括为三个步骤：**

- 定义自定义的MethodInterceptor负责委托方法执行；
- 创建Enhance并设置Callback为上述MethodInterceptor；
- enhancer.create()创建代理。

接下来，我们来具体分析一下Spring的相关实现源码。

在上个案例分析里，我们简要提及了Spring的动态代理对象的初始化机制。在得到Advisors之后，会通过ProxyFactory.getProxy获取代理对象：

```
public Object getProxy(ClassLoader classLoader) {
	return createAopProxy().getProxy(classLoader);
}
```

在这里，我们以CGLIB的Proxy的实现类CglibAopProxy为例，来看看具体的流程：

```
public Object getProxy(@Nullable ClassLoader classLoader) {
    // 省略非关键代码
    // 创建及配置 Enhancer
    Enhancer enhancer = createEnhancer();
    // 省略非关键代码
    // 获取Callback：包含DynamicAdvisedInterceptor，亦是MethodInterceptor
    Callback[] callbacks = getCallbacks(rootClass);
    // 省略非关键代码
    // 生成代理对象并创建代理（设置 enhancer 的 callback 值）
    return createProxyClassAndInstance(enhancer, callbacks);
    // 省略非关键代码
}
```

上述代码中的几个关键步骤大体符合之前提及的三个步骤，其中最后一步一般都会执行到CglibAopProxy子类ObjenesisCglibAopProxy的createProxyClassAndInstance()方法：

```
protected Object createProxyClassAndInstance(Enhancer enhancer, Callback[] callbacks) {
   //创建代理类Class
   Class<?> proxyClass = enhancer.createClass();
   Object proxyInstance = null;
   //spring.objenesis.ignore默认为false
   //所以objenesis.isWorthTrying()一般为true
   if (objenesis.isWorthTrying()) {
      try {
         // 创建实例
         proxyInstance = objenesis.newInstance(proxyClass, enhancer.getUseCache());
      }
      catch (Throwable ex) {
          // 省略非关键代码
      }
   }
       
    if (proxyInstance == null) {
       // 尝试普通反射方式创建实例
       try {
          Constructor<?> ctor = (this.constructorArgs != null ?
                proxyClass.getDeclaredConstructor(this.constructorArgTypes) :
                proxyClass.getDeclaredConstructor());
          ReflectionUtils.makeAccessible(ctor);
          proxyInstance = (this.constructorArgs != null ?
                ctor.newInstance(this.constructorArgs) : ctor.newInstance());
      //省略非关键代码
       }
    }
   // 省略非关键代码
   ((Factory) proxyInstance).setCallbacks(callbacks);
   return proxyInstance;
}
```

这里我们可以了解到，Spring会默认尝试使用objenesis方式实例化对象，如果失败则再次尝试使用常规方式实例化对象。现在，我们可以进一步查看objenesis方式实例化对象的流程。

![](https://static001.geekbang.org/resource/image/42/34/422160a6fd0c3ee1af8b05769a015834.png?wh=1027%2A397)

参照上述截图所示调用栈，objenesis方式最后使用了JDK的ReflectionFactory.newConstructorForSerialization()完成了代理对象的实例化。而如果你稍微研究下这个方法，你会惊讶地发现，这种方式创建出来的对象是不会初始化类成员变量的。

所以说到这里，聪明的你可能已经觉察到真相已经暴露了，我们这个案例的核心是代理类实例的默认构建方式很特别。在这里，我们可以总结和对比下通过反射来实例化对象的方式，包括：

- java.lang.Class.newInsance()
- java.lang.reflect.Constructor.newInstance()
- sun.reflect.ReflectionFactory.newConstructorForSerialization().newInstance()

前两种初始化方式都会同时初始化类成员变量，但是最后一种通过ReflectionFactory.newConstructorForSerialization().newInstance()实例化类则不会初始化类成员变量，这就是当前问题的最终答案了。

### 问题修正

了解了问题的根本原因后，修正起来也就不困难了。既然是无法直接访问被拦截类的成员变量，那我们就换个方式，在UserService里写个getUser()方法，从内部访问获取变量。

我们在AdminUserService里加了个getUser()方法：

```
public User getUser() {
    return user;
}
```

在ElectricService里通过getUser()获取User对象：

> //原来出错的方式：  
> //String payNum = = adminUserService.adminUser.getPayNum();  
> //修改后的方式：  
> String payNum = adminUserService.getAdminUser().getPayNum();

运行下来，一切正常，可以看到管理员登录日志了：

```
Electric charging ...
! admin login ...
admin user login...
User pay num : 202101166
Pay with alipay ...
```

但你有没有产生另一个困惑呢？既然代理类的类属性不会被初始化，那为什么可以通过在AdminUserService里写个getUser()方法来获取代理类实例的属性呢？

我们再次回顾createProxyClassAndInstance的代码逻辑，创建代理类后，我们会调用setCallbacks来设置拦截后需要注入的代码：

```
protected Object createProxyClassAndInstance(Enhancer enhancer, Callback[] callbacks) {
   Class<?> proxyClass = enhancer.createClass();
   Object proxyInstance = null;
   if (objenesis.isWorthTrying()) {
      try {
         proxyInstance = objenesis.newInstance(proxyClass, enhancer.getUseCache());
      }
   // 省略非关键代码
   ((Factory) proxyInstance).setCallbacks(callbacks);
   return proxyInstance;
}
```

通过代码调试和分析，我们可以得知上述的callbacks中会存在一种服务于AOP的DynamicAdvisedInterceptor，它的接口是MethodInterceptor（callback的子接口），实现了拦截方法intercept()。我们可以看下它是如何实现这个方法的：

```
public Object intercept(Object proxy, Method method, Object[] args, MethodProxy methodProxy) throws Throwable {
   // 省略非关键代码
    TargetSource targetSource = this.advised.getTargetSource();
    // 省略非关键代码 
      if (chain.isEmpty() && Modifier.isPublic(method.getModifiers())) {
         Object[] argsToUse = AopProxyUtils.adaptArgumentsIfNecessary(method, args);
         retVal = methodProxy.invoke(target, argsToUse);
      }
      else {
         // We need to create a method invocation...
         retVal = new CglibMethodInvocation(proxy, target, method, args, targetClass, chain, methodProxy).proceed();
      }
      retVal = processReturnType(proxy, target, method, retVal);
      return retVal;
   }
   //省略非关键代码
}
```

当代理类方法被调用，会被Spring拦截，从而进入此intercept()，并在此方法中获取被代理的原始对象。而在原始对象中，类属性是被实例化过且存在的。因此代理类是可以通过方法拦截获取被代理对象实例的属性。

说到这里，我们已经解决了问题。但如果你看得仔细，就会发现，其实你改变一个属性，也可以让产生的代理对象的属性值不为null。例如修改启动参数spring.objenesis.ignore如下：

![](https://static001.geekbang.org/resource/image/83/7e/83e34cbd460ac74c5d623905dce0497e.png?wh=933%2A185)

此时再调试程序，你会发现adminUser已经不为null了：

![](https://static001.geekbang.org/resource/image/3b/b1/3b2dd77392c3b439d0a182f5817045b1.png?wh=801%2A294)

所以这也是解决这个问题的一种方法，相信聪明的你已经能从前文贴出的代码中找出它能够工作起来的原理了。

## 重点回顾

通过以上两个案例的介绍，相信你对Spring AOP动态代理的初始化机制已经有了进一步的了解，这里总结重点如下：

1. 使用AOP，实际上就是让Spring自动为我们创建一个Proxy，使得调用者能无感知地调用指定方法。而Spring有助于我们在运行期里动态织入其它逻辑，因此，AOP本质上就是一个动态代理。
2. 我们只有访问这些代理对象的方法，才能获得AOP实现的功能，所以通过this引用是无法正确使用AOP功能的。在不能改变代码结果前提下，我们可以通过@Autowired、AopContext.currentProxy()等方式获取相应的代理对象来实现所需的功能。
3. 我们一般不能直接从代理类中去拿被代理类的属性，这是因为除非我们显示设置spring.objenesis.ignore为true，否则代理类的属性是不会被Spring初始化的，我们可以通过在被代理类中增加一个方法来间接获取其属性。

## 思考题

第二个案例中，我们提到了通过反射来实例化类的三种方式：

- java.lang.Class.newInsance()
- java.lang.reflect.Constructor.newInstance()
- sun.reflect.ReflectionFactory.newConstructorForSerialization().newInstance()

其中第三种方式不会初始化类属性，你能够写一个例子来证明这一点吗？

期待你的思考，我们留言区见！
<div><strong>精选留言（15）</strong></div><ul>
<li><span>jerry guo</span> 👍（1） 💬（2）<p>这篇太难了 没看懂</p>2022-03-20</li><br/><li><span>阿璐4r</span> 👍（24） 💬（1）<p>我一点也不聪明</p>2021-12-24</li><br/><li><span>子房</span> 👍（9） 💬（0）<p>本质原因是 bean 初始化后被创建为代理 bean ，只有访问代理对象 方法才会被拦截</p>2021-05-08</li><br/><li><span>安迪密恩</span> 👍（5） 💬（1）<p>hi 傅哥， 案例一的解决方案一，需要加@Lazy否则会出现循环依赖。
  @Lazy
  @Autowired private ElectricService electricService;</p>2022-03-09</li><br/><li><span>Ball</span> 👍（5） 💬（0）<p>🤔总结一下，今天以两个 AOP 场景下的问题为线索，深入 Spring 源码探讨了 Spring 的动态代理机制，还分享了 AOP 场景下问题的 debug 技巧。结合问题定位的过程，最终给出了问题的多种解决方案。👍</p>2021-04-30</li><br/><li><span>Monday</span> 👍（4） 💬（1）<p>案例2：user的命名一会user一会adminUser，不统一啊</p>2021-06-19</li><br/><li><span>Bumblebee</span> 👍（2） 💬（0）<p>今日收获（总结的不对的希望老师同学们多多指正）

① JDK 动态代理只能对实现了接口的类生成代理，而不能针对普通类。而 CGLIB 是可以针对类实现代理，主要是对指定的类生成一个子类，覆盖其中的方法，来实现代理对象。

② this调用的当前类方法无法被拦截（可以通过@Autowired、AopContext.currentProxy() 方式解决）；

③ 我们一般不能直接从代理类中去拿被代理类的属性，这是因为除非我们显示设置 spring.objenesis.ignore 为 true，否则代理类的属性是不会被 Spring 初始化的，我们可以通过在被代理类中增加一个方法来间接获取其属性。


总结：我觉得SpringAop生成的代理类是对被代理类的一个包装，代理类对象仅被代理对象方法执行前后进行增强，原始方法的调用还是由被代理对象自己执行；</p>2022-05-30</li><br/><li><span>小林桑</span> 👍（1） 💬（0）<p>这个课好像没见到老师来答疑？ </p>2024-01-14</li><br/><li><span>Geek_930ce1</span> 👍（1） 💬（4）<p>ReflectionFactory reflectionFactory = ReflectionFactory.getReflectionFactory();
        Constructor&lt;AdminUserService&gt; constructor1  = AdminUserService.class.getConstructor();
        Constructor constructor2 = reflectionFactory.newConstructorForSerialization(AdminUserService.class,constructor1);
        AdminUserService adminUserService3 = (AdminUserService)constructor2.newInstance();
        System.out.println(&quot;sun.reflect.ReflectionFactory.newConstructorForSerialization().newInstance()&quot;+adminUserService3);
经过尝试，还是存在成员变量，是为什么</p>2022-06-10</li><br/><li><span>Bo</span> 👍（0） 💬（0）<p>关于思考题，不知道为什么用老师的AdminUserService就还是会初始化类属性，自定义的类就可以验证不会初始化，后面再关注。

验证代码如下：（参考https:&#47;&#47;blog.csdn.net&#47;Zong_0915&#47;article&#47;details&#47;126512236）
public class Test {
    public final User user = new User(&quot;LJJ&quot;);
    public User user2 = new User(&quot;LJJ&quot;);
    public String name = &quot;Hello&quot;;
    public final String str = &quot;ssss&quot;;
    public Integer a = 12222;
    public final Integer b = 12222;
    public int aa = 1;
    public final int bb = 2;

    public static void main(String[] args) throws Exception {
        ReflectionFactory reflectionFactory = ReflectionFactory.getReflectionFactory();
        Constructor constructor = reflectionFactory.newConstructorForSerialization(Test.class, Object.class.getDeclaredConstructor());
        constructor.setAccessible(true);
        Test t = (Test) constructor.newInstance();
        System.out.println(&quot;final user: &quot; + t.user);
        System.out.println(&quot;user: &quot; + t.user2);
        System.out.println(&quot;final String: &quot; + t.str);
        System.out.println(&quot;String: &quot; + t.name);
        System.out.println(&quot;final Integer: &quot; + t.b);
        System.out.println(&quot;Integer: &quot; + t.a);
        System.out.println(&quot;final int: &quot; + t.bb);
        System.out.println(&quot;int: &quot; + t.aa);
    }
}

注意：
- sun.reflect在Java 9以上才引入
- 如果编译报错“package sun.reflect does not exist”，但是在代码里其实可以看到源码，则可以尝试在IDEA设置里搜索Java Compiler，取消勾选 `Use &#39;--release&#39; option for cross-compilation` 选项即可，亲试有效。参考[IntelliJ says the package does not exist, But I can access the package](https:&#47;&#47;stackoverflow.com&#47;questions&#47;40448203&#47;intellij-says-the-package-does-not-exist-but-i-can-access-the-package)——StackOverFlow</p>2023-03-01</li><br/><li><span>饮水偲源</span> 👍（0） 💬（0）<p>第3种构造方式，成员属性不会初始化的代码
       
 ReflectionFactory reflectionFactory = ReflectionFactory.getReflectionFactory();
        Constructor constructor = reflectionFactory.newConstructorForSerialization(AdminUserService.class);
        AdminUserService adminUserService = (AdminUserService) constructor.newInstance();
        System.out.println(adminUserService.adminUser.payNum);

但是
reflectionFactory.newConstructorForSerialization这个方法还有种入参，传入指定构造方法时，其可以完成成员属性初始化。
Constructor&lt;?&gt; newConstructorForSerialization(Class&lt;?&gt; var1, Constructor&lt;?&gt; var2)</p>2022-09-01</li><br/><li><span>蝴蝶</span> 👍（0） 💬（0）<p>        Constructor&lt;Object&gt; constructor = Object.class.getDeclaredConstructor();
        Constructor&lt;?&gt; constructor1 = ReflectionFactory.getReflectionFactory()
                .newConstructorForSerialization(Person.class, constructor);

        constructor1.s        Constructor&lt;Object&gt; constructor = Object.class.getDeclaredConstructor();
        Constructor&lt;?&gt; constructor1 = ReflectionFactory.getReflectionFactory()
                .newConstructorForSerialization(Person.class, constructor);

        constructor1.setAccessible(true);
        Person personByReflection = (Person) constructor1.newInstance();
        
        System.out.println(personByReflection);etAccessible(true);
        Person personByReflection = (Person) constructor1.newInstance();
        
        System.out.println(personByReflection);</p>2022-07-14</li><br/><li><span>蝴蝶</span> 👍（0） 💬（0）<p>        Constructor&lt;Object&gt; constructor = Object.class.getDeclaredConstructor();
        Constructor&lt;?&gt; constructor1 = ReflectionFactory.getReflectionFactory()
                .newConstructorForSerialization(Person.class, constructor);

        constructor1.setAccessible(true);
        Person personByReflection = (        Constructor&lt;Object&gt; constructor = Object.class.getDeclaredConstructor();
        Constructor&lt;?&gt; constructor1 = ReflectionFactory.getReflectionFactory()
                .newConstructorForSerialization(Person.class, constructor);

        constructor1.setAccessible(true);
        Person personByReflection = (Person) constructor1.newInstance();
                Constructor&lt;Object&gt; constructor = Object.class.getDeclaredConstructor();
        Constructor&lt;?&gt; constructor1 = ReflectionFactory.getReflectionFactory()
                .newConstructorForSerialization(Person.class, constructor);

        constructor1.setAccessible(true);
        Person personByReflection = (Person) constructor1.newInstance();
        11111
        System.out.println(personByReflectio11n);
        System.out.println(personByReflection);) constructor1.newInstance();
        
        System.out.println(personByReflection);</p>2022-07-14</li><br/><li><span>胡同学</span> 👍（0） 💬（0）<p>@@Lookup 也可以实现案例一</p>2022-05-13</li><br/><li><span>安迪密恩</span> 👍（0） 💬（1）<p>hi 傅哥， 那是不是说 private 方法无法被AOP 增强？</p>2022-03-09</li><br/>
</ul>