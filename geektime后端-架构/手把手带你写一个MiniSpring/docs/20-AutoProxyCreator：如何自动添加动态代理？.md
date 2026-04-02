你好，我是郭屹，今天我们继续手写MiniSpring，这也是AOP正文部分的最后一节。今天我们将完成一个有模有样的AOP解决方案。

## 问题的引出

前面，我们已经实现了通过动态代理技术在运行时进行逻辑增强，并引入了Pointcut，实现了代理方法的通配形式。到现在，AOP的功能貌似已经基本实现了，但目前还有一个较大的问题，具体是什么问题呢？我们查看aplicationContext.xml里的这段配置文件来一探究竟。

```xml
<bean id="realaction" class="com.test.service.Action1" />
<bean id="action" class="com.minis.aop.ProxyFactoryBean">
    <property type="String" name="interceptorName" value="advisor" />
    <property type="java.lang.Object" name="target" ref="realaction"/>	
</bean>
```

看这个配置文件可以发现，在ProxyFactoryBean的配置中，有个Object类型的属性：target。在这里我们的赋值ref是realactionbean，对应Action1这个类。也就是说，给Action1这个Bean动态地插入逻辑，达成AOP的目标。  
在这里，一次AOP的配置对应一个目标对象，如果整个系统就只需要为一个对象进行增强操作，这自然没有问题，配置一下倒也不会很麻烦，但在一个稍微有规模的系统中，我们有成百上千的目标对象，在这种情况下一个个地去配置则无异于一场灾难。

一个实用的AOP解决方案，应该可以**用一个简单的匹配规则代理多个目标对象**。这是我们这节课需要解决的问题。

## 匹配多个目标对象的思路

在上节课，我们其实处理过类似的问题，就是当时我们的目标方法只能是一个固定的方法名doAction()，我们就提出了Pointcut这个概念，用一个模式来通配方法名，如 `do*`、`do*Action` 之类的字符串模式。

Pointcut这个概念解决了一个目标对象内部多个方法的匹配问题。这个办法也能给我们灵感，我们就借鉴这个思路，用类似的手段来解决匹配多个目标对象的问题。

因此，我们想象中当解决方案实现之后，应该是这么配置的。

```plain
<bean id="genaralProxy" class="GeneralProxy" >
    <property type="String" name="pattern" value="action*" />
    <property type="String" name="interceptorName" value="advisor" />
</bean>
```

上面的配置里有一个通用的ProxyBean，它用一个模式串pattern来匹配目标对象，作为例子这里就是 `action*`，表示所有名字以action开头的对象都是目标对象。

这个想法好像成立，但是我们知道，IoC容器内部所有的Bean是相互独立且平等的，这个GeneralProxy也就是一个普通的Bean。那么作为一个普通的Bean，它怎么能影响到别的Bean呢？它如何能做到给别的Bean动态创建代理呢？这个办法有这样一个关键的难点。

我们反过来思考，如果能找个办法让这个General Proxy影响到别的Bean，再根据规则决定给这些Bean加上动态代理（这一点我们之前就实现过了），是不是就可以了？

那么在哪个时序点能做这个事情呢？我们再回顾一下Bean的创建过程：第一步，IoC容器扫描配置文件，加载Bean的定义。第二步，通过getBean()这个方法创建Bean实例，这一步又分成几个子步骤：

1. 创建Bean的毛坯实例；
2. 填充Properties；
3. 执行postProcessBeforeInitialization；
4. 调用init-method方法；
5. 执行postProcessAfterInitialization。

后三个子步骤，实际上都是在每一个Bean实例创建好之后可以进行的后期处理。那么我们就可以利用这个时序，把自动生成代理这件事情交给后期处理来完成。在我们的IoC容器里，有一个现成的机制，叫**BeanPostProcessor**，它能在每一个Bean创建的时候进行后期修饰，也就是上面的3和5两个子步骤其实都是调用的BeanPostProcessor里面的方法。所以现在就比较清晰了，我们考虑用BeanPostProcessor实现自动生成目标对象代理。

## 利用BeanPostProcessor自动创建代理

创建动态代理的核心是**把传进来的Bean包装成一个ProxyFactoryBean**，改头换面变成一个动态的代理，里面包含了真正的业务对象，这一点我们已经在前面的工作中做好了。现在是要自动创建这个动态代理，它的核心就是通过BeanPostProcessor来为每一个Bean自动完成创建动态代理的工作。

我们用一个BeanNameAutoProxyCreator类实现这个功能，顾名思义，这个类就是根据Bean的名字匹配来自动创建动态代理的，你可以看一下相关代码。

```java
package com.minis.aop.framework.autoproxy;
public class BeanNameAutoProxyCreator implements BeanPostProcessor{
    String pattern; //代理对象名称模式，如action*
    private BeanFactory beanFactory;
    private AopProxyFactory aopProxyFactory;
    private String interceptorName;
    private PointcutAdvisor advisor;
    public BeanNameAutoProxyCreator() {
        this.aopProxyFactory = new DefaultAopProxyFactory();
    }
    //核心方法。在bean实例化之后，init-method调用之前执行这个步骤。
    @Override
    public Object postProcessBeforeInitialization(Object bean, String beanName) throws BeansException {
        if (isMatch(beanName, this.pattern)) {
            ProxyFactoryBean proxyFactoryBean = new ProxyFactoryBean(); //创建以恶ProxyFactoryBean
            proxyFactoryBean.setTarget(bean);
            proxyFactoryBean.setBeanFactory(beanFactory);
            proxyFactoryBean.setAopProxyFactory(aopProxyFactory);
            proxyFactoryBean.setInterceptorName(interceptorName);
            return proxyFactoryBean;
        }
        else {
            return bean;
        }
    }
    protected boolean isMatch(String beanName, String mappedName) {
        return PatternMatchUtils.simpleMatch(mappedName, beanName);
    }
}
```

通过代码可以知道，在postProcessBeforeInitialization方法中，判断了Bean的名称是否符合给定的规则，也就是isMatch(beanName, this.pattern)这个方法。往下追究一下，发现这个isMatch()就是直接调用的PatternMatchUtils.simpleMatch()，跟上一节课的通配方法名一样。所以如果Bean的名称匹配上了，那我们就用和以前创建动态代理一样的办法来自动生成代理。

```java
ProxyFactoryBean proxyFactoryBean = new ProxyFactoryBean();
proxyFactoryBean.setTarget(bean);
proxyFactoryBean.setBeanFactory(beanFactory);
proxyFactoryBean.setAopProxyFactory(aopProxyFactory);
proxyFactoryBean.setInterceptorName(interceptorName);
```

这里我们还是用到了ProxyFactoryBean，跟以前一样，只不过这里是经过了BeanPostProcessor。因此，按照IoC容器的规则，这一切不再是手工的了，而是对每一个符合规则Bean都会这样做一次动态代理，就可以完成我们的工作了。

现在我们只要把这个BeanPostProcessor配置到XML文件里就可以了。

```plain
<bean id="autoProxyCreator" class="com.minis.aop.framework.autoproxy.BeanNameAutoProxyCreator" >
    <property type="String" name="pattern" value="action*" />
    <property type="String" name="interceptorName" value="advisor" />
</bean>
```

IoC容器扫描配置文件的时候，会把所有的BeanPostProcessor对象加载到Factory中生效，每一个Bean都会过一遍手。

## getBean方法的修改

工具准备好了，这个BeanPostProcessor会自动创建动态代理。为了使用这个Processor，对应的AbstractBeanFactory类里的getBean()方法需要同步修改。你可以看一下修改后getBean的实现。

```java
    public Object getBean(String beanName) throws BeansException{
      Object singleton = this.getSingleton(beanName);
      if (singleton == null) {
         singleton = this.earlySingletonObjects.get(beanName);
         if (singleton == null) {
            BeanDefinition bd = beanDefinitionMap.get(beanName);
            if (bd != null) {
               singleton=createBean(bd);
               this.registerBean(beanName, singleton);
               if (singleton instanceof BeanFactoryAware) {
                  ((BeanFactoryAware) singleton).setBeanFactory(this);
               }
               //用beanpostprocessor进行后期处理
               //step 1 : postProcessBeforeInitialization调用processor相关方法
               singleton = applyBeanPostProcessorsBeforeInitialization(singleton, beanName);
               //step 2 : init-method
               if (bd.getInitMethodName() != null && !bd.getInitMethodName().equals("")) {
                  invokeInitMethod(bd, singleton);
               }
               //step 3 : postProcessAfterInitialization
               applyBeanPostProcessorsAfterInitialization(singleton, beanName);
               this.removeSingleton(beanName);
               this.registerBean(beanName, singleton);
            }
            else {
               return null;
            }
         }
      }
      else {
      }
      //process Factory Bean
      if (singleton instanceof FactoryBean) {
         return this.getObjectForBeanInstance(singleton, beanName);
      }
      else {
      }
      return singleton;
   }
```

上述代码中主要修改这一行：

```java
singleton = applyBeanPostProcessorsBeforeInitialization(singleton, beanName);
```

代码里会调用Processor的postProcessBeforeInitialization方法，并返回singleton。这一段代码的功能是如果这个Bean的名称符合某种规则，就会自动创建Factory Bean，这个Factory Bean里面会包含一个动态代理对象用来返回自定义的实例。

于是，getBean的时候，除了创建Bean实例，还会用BeanPostProcessor进行后期处理，对满足规则的Bean进行包装，改头换面成为一个Factory Bean。

## 测试

到这里，我们就完成自动创建动态代理的工作了，简单测试一下。

修改applicationContext.xml配置文件，增加一些配置。

```xml
<bean id="autoProxyCreator" class="com.minis.aop.framework.autoproxy.BeanNameAutoProxyCreator" >
    <property type="String" name="pattern" value="action*" />
    <property type="String" name="interceptorName" value="advisor" />
</bean>
	
<bean id="action" class="com.test.service.Action1" /> 
<bean id="action2" class="com.test.service.Action2" /> 
	
<bena id="beforeAdvice" class="com.test.service.MyBeforeAdvice" />
<bean id="advisor" class="com.minis.aop.NameMatchMethodPointcutAdvisor">
    <property type="com.minis.aop.Advice" name="advice" ref="beforeAdvice"/>
    <property type="String" name="mappedName" value="do*"/>
</bean>
```

这里我们配置了两个Bean，BeanPostProcessor和Advisor。

相应地，controller层的HelloWorldBean增加一段代码。

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

@Autowired
IAction action2;

@RequestMapping("/testaop3")
public void doTestAop3(HttpServletRequest request, HttpServletResponse response) {
	action2.doAction();
}
@RequestMapping("/testaop4")
public void doTestAop4(HttpServletRequest request, HttpServletResponse response) {
	action2.doSomething();
}
```

这里，我们用到了这两个Bean，action和action2，每个Bean里面都有doAction()和doSomething()两个方法。

通过配置文件可以看到，在Processor的Pattern配置里，通配 `action*` 可以匹配所有以action开头的Bean。在Advisor的MappedName配置里，通配 `do*`，就可以匹配所有以do开头的方法。

运行一下，就可以看到效果了。这两个Bean里的两个方法都加上了增强，说明系统在调用这些Bean的方法时自动插入了逻辑。

## 小结

这节课，我们对匹配Bean的办法进行了扩展，使系统可以按照某个规则来匹配某些Bean，这样就不用一个Bean一个Bean地配置动态代理了。

实现的思路是利用Bean的时序，使用一个BeanPostProcessor进行后期处理。这个Processor接收一个模式串，而这个模式也是可以由用户配置在外部文件里的，然后提供isMatch() 方法，支持根据名称进行模式匹配。具体的字符串匹配工作，和上节课一样，也是采用从前到后的扫描技术，分节段进行校验。匹配上之后，还是利用以前的ProxyFactoryBean创建动态代理。这里要理解一点，就是系统会自动把应用程序员配置的业务Bean改头换面，让它变成一个Factory Bean，里面包含的是业务Bean的动态代理。

这个方案能用是因为之前IoC容器里提供的这个BeanPostProcessor机制，所以这里我们再次看到了IoC容器的强大之处。

到这里，我们的AOP方案就完成了。这是基于JDK的方案，对于理解AOP原理很有帮助。

完整源代码参见 [https://github.com/YaleGuo/minis](https://github.com/YaleGuo/minis)。

## 课后题

学完这节课，我也给你留一道思考题。AOP经常用来处理数据库事务，如何用我们现在的AOP架构实现简单的事务处理呢？欢迎你在留言区与我交流讨论，也欢迎你把这节课分享给需要的朋友。我们下节课见！
<div><strong>精选留言（11）</strong></div><ul>
<li><span>马儿</span> 👍（1） 💬（1）<p>这节课的代码能够做到不需要在beans.xml中额外专门配置来生成代理对象，已经接近spring的雏形了。但是按照之前的代码是跑不起来的，需要对之前的BeanPostProcessor的逻辑修改一下，应该是老师之前讲漏了的部分。主要工作在修改AbstractAutowireCapableBeanFactory类将属性中的beanPostProcessors改为面向接口的列表，其次是修改ClassPathXmlApplicationContext#registerBeanPostProcessors让其可以在配置文件中读到注册的BeanPostProcessors并注册到容器中。最后将我们之前用到的AutowiredAnnotationBeanPostProcessor注册到容器中管理就能够自动发现了。
代码修改可以参考：https:&#47;&#47;github.com&#47;horseLk&#47;mini-spring&#47;commit&#47;7186afebeaf30d622d79b4111970945abca97701</p>2023-04-26</li><br/><li><span>peter</span> 👍（6） 💬（1）<p>问题放在第20课，但问题是关于第19课的：
Q1：Join Point和Pointcut的区别是什么？两个看起来是一回事啊。
Q2：流程方面，Interceptor先拦截，拦截以后再进行增强操作。换一种说法，先是Interceptor工作，然后是Join Point、Pointcut、advice这些登场，对吗？
Q3：19课的总结部分，是这样说的：“Advisor：通知者，它实现了 Advice”。19课的留言解答有这样一句话“advisor则是一个管理类，它包了一个advice，还能寻找到符合条件的方法名进行增强”。 留言的解释很不错，但总结部分，“实现了 Advice”，个人感觉这个措辞不是很合理啊，怎么是“实现”？这个词容易让人理解为接口与实现类的关系。</p>2023-04-27</li><br/><li><span>__@Wong</span> 👍（4） 💬（2）<p>补充一个点，这里需要保证AutowiredAnnotationBeanPostProcessor和BeanNameAutoProxyCreator两个BeanPostProcessor的优先级，AutowiredAnnotationBeanPostProcessor要在之前哦，在xml文件里面AutowiredAnnotationBeanPostProcessor的bean要放前面。</p>2023-06-24</li><br/><li><span>Geek_320730</span> 👍（1） 💬（1）<p>可以定义一个注解@Transaction并实现一个MethodMatcher，根据有没有这个注解来判断方法是否匹配，匹配的话，在方法执行前，手动开启事务，方法结束后，手动提交事务，有异常的话回滚事务。那事务方法调用事务方法的时候不知道会不会报错。。。

另外遇到Bean可以一直嵌套代理的问题，比如上一章手动配置的action,本身就是一个ProxyFactoryBean了，但是他的名字依然符合本章的action*的匹配规则，这样就又加了一层代理，注入的时候就会失败。需要在获取类的时候判断一下类型递归返回，或者在bean匹配规则的时候做一下类型判断，如果本身是个ProxyFactoryBean了，就不做操作返回。</p>2023-04-26</li><br/><li><span>__@Wong</span> 👍（0） 💬（2）<p>将原有的bean替换成代理后的bean那里，如果遇到循环引用会有问题吧， 引用的还是旧的bean。</p>2023-06-20</li><br/><li><span>__Alucard</span> 👍（0） 💬（1）<p>完结撒花，谢谢指导</p>2023-05-29</li><br/><li><span>__Alucard</span> 👍（0） 💬（2）<p>动态代理失效的根本原因是@Autowired注解解析的时候，取到的spring bean还是没代理的对象； 我的临时解决方案是 在BeanNameAutoProxyCreator的postProcessBeforeInitialization手动把创建后的动态代理对象注入进spring ioc中， beanFactory.registerBean(beanName,proxyFactoryBean);  但是这样会导致BeanFactory又对外暴露了注册bean的接口，void registerBean(String beanName, Object obj);明显不合适，这个有没有更好的办法</p>2023-05-29</li><br/><li><span>浩仔是程序员</span> 👍（0） 💬（1）<p>老师你好，怎么github上面这块framework这个包下面有部分代码是重复的呢？建议可以来个代码结构的总结</p>2023-05-02</li><br/><li><span>dirtychill</span> 👍（0） 💬（0）<p>一步步录入代码完成，可运行的，利用lombok简化了代码，便于学习，可能还有一些bug或者一些扩展，可以来维护https:&#47;&#47;github.com&#47;DirtyBit64&#47;Mini-Spring</p>2024-07-06</li><br/><li><span>Geek_28bb47</span> 👍（0） 💬（0）<p>已学完，https:&#47;&#47;github.com&#47;ykexc&#47;minispring，每节课对应一个分支，欢迎大家来参考，感觉懂了一点，还需要看完spring源码再继续品味。</p>2024-04-10</li><br/><li><span>天敌</span> 👍（0） 💬（0）<p>老师，关于使用 Proxy.newProxyInstance 生成的对象在进行 xml 中 ref 的属性绑定过程中，由于生成的代理对象并没有继承被代理对象的类，导致进行赋值时
IllegalArgumentException: argument type mismatch
这个问题，应该如何解决呢？</p>2023-07-23</li><br/>
</ul>