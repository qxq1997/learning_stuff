你好，我是傅健。

在开始我们第一章的学习之前，我想为你总结下有关Spring最基础的知识，这可以帮助我们后面的学习进展更加顺利一些。

就第一章来说，我们关注的是Spring核心功能使用中的各类错误案例。针对问题的讲解，我们大多都是直奔主题，这也是这个专栏的内容定位。所以对于**很多基础的知识和流程**，我们不会在解析过程中反复介绍，但它们依然是重要的，是我们解决问题的前提。借助这篇导读，我带你梳理下。

回顾Spring本身，什么是Spring最基础的知识呢？

其实就是那些**Spring最本质的实现和思想**。当你最开始学习的时候，你可能困惑于为什么要用Spring，而随着对Spring原理的深入探究和应用，你慢慢会发现，最大的收获其实还是对于这个困惑的理解。接下来我就给你讲讲。

在进行“传统的”Java编程时，对象与对象之间的关系都是紧密耦合的，例如服务类 Service 使用组件 ComponentA，则可能写出这样的代码：

```
public class Service {
    private ComponentA component = new ComponentA("first component");
}
```

在没有Spring之前，你应该会觉得这段代码并没有多大问题，毕竟大家都这么写，而且也没有什么更好的方式。就像只有一条大路可走时，大家都朝一个方向走，你大概率不会反思是不是有捷径。

而随着项目的开发推进，你会发现检验一个方式好不好的硬性标准之一，就是看它**有没有拥抱变化的能力**。假设有一天，我们的ComponentA类的构造器需要更多的参数了，你会发现，上述代码到处充斥着这行需要改进的代码：

> private ComponentA component = new ComponentA("first component");

此时你可能会想了，那我用下面这种方式来构造Service就可以了吧？

```
public class Service {
    private ComponentA component；
    public Service(ComponentA component){
      this.component = component;
    }
}
```

当然不行，你忽略了一点，你在构建Service对象的时候，不还得使用new关键字来构建Component？需要修改的调用处并不少！

很明显，这是一个噩梦。那么，除了这点，还有没有别的不好的地方呢？上面说的是非单例的情况，如果ComponentA本身是一个单例，会不会好些？毕竟我们可能找一个地方new一次ComponentA实例就足够了，但是你可能会发现另外一些问题。

下面是一段用“双重检验锁”实现的CompoentA类：

```
public class ComponentA{  
    private volatile static ComponentA INSTANCE;  
     
    private ComponentA() {}  
     
    public static ComponentA getInstance(){  
        if (INSTANCE== null) {  
            synchronized (ComponentA.class) {  
                if (INSTANCE== null) {  
                    INSTANCE= new ComponentA();  
                }  
            }  
        }  
        return INSTANCE;  
    }  
}
```

其实写了这么多代码，最终我们只是要一个单例而已。而且假设我们有ComponentB、ComponentC、ComponentD等，那上面的重复性代码不都得写一遍？也是烦的不行，不是么？

除了上述两个典型问题，还有不易于测试、不易扩展功能（例如支持AOP）等缺点。说白了，所有问题的根源（之一）就是**对象与对象之间耦合性太强了**。

所以Spring的引入，解决了上面这些零零种种的问题。那么它是怎么解决的呢？

这里套用一个租房的场景。我们为什么喜欢通过中介来租房子呢？因为省事呀，只要花点小钱就不用与房东产生直接的“纠缠”了。

Spring就是这个思路，它就像一个“中介”公司。当你需要一个依赖的对象（房子）时，你直接把你的需求告诉Spring（中介）就好了，它会帮你搞定这些依赖对象，按需创建它们，而无需你的任何额外操作。

不过，在Spring中，房东和租房者都是对象实例，只不过换了一个名字叫 Bean 而已。

可以说，通过一套稳定的生产流程，作为“中介”的Spring完成了生产和预装（牵线搭桥）这些Bean的任务。此时，你可能想了解更多。例如，如果一个Bean（租房者）需要用到另外一个Bean（房子）时，具体是怎么操作呢？

本质上只能从Spring“中介”里去找，有时候我们直接根据名称（小区名）去找，有时候则根据类型（户型），各种方式不尽相同。你就把**Spring理解成一个Map型的公司**即可，实现如下：

```
public class BeanFactory {

    private Map<String, Bean> beanMap = new HashMap<>();
    
    public Bean getBean(String key){
      return beanMap.get(key) ;
    }

}
```

如上述代码所示，Bean所属公司提供了对于Map的操作来完成查找，找到Bean后装配给其它对象，这就是依赖查找、自动注入的过程。

那么回过头看，这些Bean又是怎么被创建的呢？

对于一个项目而言，不可避免会出现两种情况：一些对象是需要Spring来管理的，另外一些（例如项目中其它的类和依赖的Jar中的类）又不需要。所以我们得有一个办法去标识哪些是需要成为Spring Bean，因此各式各样的注解才应运而生，例如Component注解等。

那有了这些注解后，谁又来做“发现”它们的工作呢？直接配置指定自然不成问题，但是很明显“自动发现”更让人省心。此时，我们往往需要一个扫描器，可以模拟写下这样一个扫描器：

```
public class AnnotationScan {
    
    //通过扫描包名来找到Bean
    void scan(String packages) {
         //
    }

}
```

有了扫描器，我们就知道哪些类是需要成为Bean。

那怎么实例化为Bean（也就是一个对象实例而已）呢？很明显，只能通过**反射**来做了。不过这里面的方式可能有多种：

- java.lang.Class.newInsance()
- java.lang.reflect.Constructor.newInstance()
- ReflectionFactory.newConstructorForSerialization()

**有了创建，有了装配，一个Bean才能成为自己想要的样子。**

而需求总是源源不断的，我们有时候想记录一个方法调用的性能，有时候我们又想在方法调用时输出统一的调用日志。诸如此类，我们肯定不想频繁再来个散弹式的修改。所以我们有了AOP，帮忙拦截方法调用，进行功能扩展。拦截谁呢？在Spring中自然就是Bean了。

其实AOP并不神奇，结合刚才的Bean（中介）公司来讲，假设我们判断出一个Bean需要“增强”了，我们直接让它从公司返回的时候，就使用一个代理对象作为返回不就可以了么？示例如下：

```
public class BeanFactory {

    private Map<String, Bean> beanMap = new HashMap<>();
    
    public Bean getBean(String key){
       //查找是否创建过
       Bean bean = beanMap.get(key);
       if(bean != null){
         return bean;
       }
       //创建一个Bean
       Bean bean = createBean();
       //判断要不要AOP
       boolean needAop = judgeIfNeedAop(bean);
       try{
           if(needAop)
              //创建代理对象
              bean = createProxyObject(bean);
              return bean;
           else:
              return bean
       }finally{
           beanMap.put(key, bean);
       }
    }
}
```

那么怎么知道一个对象要不要AOP？既然一个对象要AOP，它肯定被标记了一些“规则”，例如拦截某个类的某某方法，示例如下：

```
@Aspect
@Service
public class AopConfig {
    @Around("execution(* com.spring.puzzle.ComponentA.execute()) ")
    public void recordPayPerformance(ProceedingJoinPoint joinPoint) throws Throwable {
      //
    }
}
```

这个时候，很明显了，假设你的Bean名字是ComponentA，那么就应该返回ComponentA类型的代理对象了。至于这些规则是怎么建立起来的呢？你看到它上面使用的各种注解大概就能明白其中的规则了，无非就是**扫描注解，根据注解创建规则**。

以上即为Spring的一些核心思想，包括**Bean的构建、自动注入和AOP**，这中间还会掺杂无数的细节，不过这不重要，抓住这个核心思想对你接下来理解各种类型的错误案例才是大有裨益的！

你好，我是傅健，这节课我们来聊一聊 Spring Bean 的初始化过程及销毁过程中的一些问题。

虽然说 Spring 容器上手简单，可以仅仅通过学习一些有限的注解，即可达到快速使用的目的。但在工程实践中，我们依然会从中发现一些常见的错误。尤其当你对 Spring 的生命周期还没有深入了解时，类初始化及销毁过程中潜在的约定就不会很清楚。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>undefined</span> 👍（21） 💬（0）<p>掌握了核心思想，下一步就是挑战魔鬼细节了。

The devil is in the details

[2021-04-19 21:55:05]</p>2021-04-19</li><br/><li><span>Monday</span> 👍（10） 💬（0）<p>用了这么多年的spring，也看过相关书籍。但就是没底，所以我来了</p>2021-05-08</li><br/><li><span>YANG</span> 👍（7） 💬（0）<p>Spring核心思想：Bean的创建、自动注入、AOP</p>2021-04-20</li><br/><li><span>jjn0703</span> 👍（6） 💬（0）<p>清晰明了！</p>2021-04-27</li><br/><li><span>LGY001</span> 👍（6） 💬（0）<p>老师讲的很清晰明白，之前都是一直知道怎么用，但是不知道为什么是这样，希望我能坚持学下去！！！</p>2021-04-23</li><br/><li><span>民鹏</span> 👍（3） 💬（0）<p>怀着空杯心态，学起来！</p>2021-04-25</li><br/><li><span>心宇</span> 👍（2） 💬（0）<p>老师讲的很好，通俗易懂，期待下一章节</p>2021-04-23</li><br/><li><span>William</span> 👍（1） 💬（0）<p>我纯粹是为了抢沙发来的</p>2022-01-07</li><br/><li><span>伟伟</span> 👍（1） 💬（0）<p>老师总结的很好</p>2021-06-13</li><br/><li><span>zhongmin</span> 👍（1） 💬（5）<p>不是常说，放射影响性能，那岂不是Sprint创建的Bean的性能消耗，远大于直接new的对象</p>2021-04-27</li><br/><li><span>Krystal</span> 👍（1） 💬（0）<p>期待</p>2021-04-20</li><br/><li><span>Geek_582a5d</span> 👍（0） 💬（0）<p>讲解的很棒，很通俗</p>2025-02-20</li><br/><li><span>花花Binki</span> 👍（0） 💬（0）<p>如果不是为了快速上手工作，其实在 spring 之前应该学一下最开始的 Java EE，从原始 new，到 struts，spring 等框架，再到 spring boot 自动配置。过高的封装简易了开发，也藏住了细节。
老师这门课的开头抓住了技术演进的本质，让我可以省略学习成本，极好的</p>2024-09-10</li><br/><li><span>cake</span> 👍（0） 💬（0）<p>老师，有源码地址吗</p>2023-04-16</li><br/><li><span>棒棒糖</span> 👍（0） 💬（0）<p>1.为什么要使用spring?（spring解决了什么问题）
2.spring的生命周期原理
3.使用aop做一个优化:给某一个类中所有方法 装配:性能记录➕日志记录（石头老师➕周瑜老师）</p>2023-02-04</li><br/>
</ul>