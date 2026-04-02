你好，我是傅健。

上一节课，我们介绍了 Spring AOP 常遇到的几个问题，通过具体的源码解析，相信你对 Spring AOP 的基本原理已经有所了解了。不过，AOP 毕竟是 Spring 的核心功能之一，不可能规避那零散的两三个问题就一劳永逸了。所以这节课，我们继续聊聊 Spring AOP 中还会有哪些易错点。实际上，当一个系统采用的切面越来越多时，因为执行顺序而导致的问题便会逐步暴露出来，下面我们就重点看一下。

## 案例1：错乱混合不同类型的增强

还是沿用上节课的宿舍管理系统开发场景。

这里我们先回顾下，你就不用去翻代码了。这个宿舍管理系统保护了一个电费充值模块，它包含了一个负责电费充值的类 ElectricService，还有一个充电方法 charge()：

```
@Service
public class ElectricService {
    public void charge() throws Exception {
        System.out.println("Electric charging ...");
    }
}
```

为了在执行 charge() 之前，鉴定下调用者的权限，我们增加了针对于 Electric 的切面类 AopConfig，其中包含一个 @Before 增强。这里的增强没有做任何事情，仅仅是打印了一行日志，然后模拟执行权限校验功能（占用 1 秒钟）。

```
//省略 imports
@Aspect
@Service
@Slf4j
public class AspectService {
  @Before("execution(* com.spring.puzzle.class6.example1.ElectricService.charge()) ")
  public void checkAuthority(JoinPoint pjp) throws Throwable {
      System.out.println("validating user authority");
      Thread.sleep(1000);
  }
}
```

执行后，我们得到以下 log，接着一切按照预期继续执行：

```
validating user authority
Electric charging ...
```

一段时间后，由于业务发展，ElectricService 中的 charge() 逻辑变得更加复杂了，我们需要仅仅针对 ElectricService 的 charge() 做性能统计。为了不影响原有的业务逻辑，我们在 AopConfig 中添加了另一个增强，代码更改后如下：

```
//省略 imports
@Aspect
@Service
public class AopConfig {
    @Before("execution(* com.spring.puzzle.class6.example1.ElectricService.charge()) ")
    public void checkAuthority(JoinPoint pjp) throws Throwable {
        System.out.println("validating user authority");
        Thread.sleep(1000);
    }

    @Around("execution(* com.spring.puzzle.class6.example1.ElectricService.charge()) ")
    public void recordPerformance(ProceedingJoinPoint pjp) throws Throwable {
        long start = System.currentTimeMillis();
        pjp.proceed();
        long end = System.currentTimeMillis();
        System.out.println("charge method time cost: " + (end - start));
    }
}
```

执行后得到日志如下：

> validating user authority  
> Electric charging …  
> charge method time cost 1022 (ms)

通过性能统计打印出的日志，我们可以得知 charge() 执行时间超过了 1 秒钟。然而，该方法仅打印了一行日志，它的执行不可能需要这么长时间。

因此我们很容易看出问题所在：当前 ElectricService 中 charge() 的执行时间，包含了权限验证的时间，即包含了通过 @Around 增强的 checkAuthority() 执行的所有时间。这并不符合我们的初衷，我们需要统计的仅仅是 ElectricService.charge() 的性能统计，它并不包含鉴权过程。

当然，这些都是从日志直接观察出的现象。实际上，这个问题出现的根本原因和 AOP 的执行顺序有关。针对这个案例而言，当同一个切面（Aspect）中同时包含多个不同类型的增强时（Around、Before、After、AfterReturning、AfterThrowing 等），它们的执行是有顺序的。那么顺序如何？我们不妨来解析下。

### 案例解析

其实一切都可以从源码中得到真相！在[第04课](https://time.geekbang.org/column/article/367876)我们曾经提到过，Spring 初始化单例类的一般过程，基本都是 getBean()-&gt;doGetBean()-&gt;getSingleton()，如果发现 Bean 不存在，则调用 createBean()-&gt;doCreateBean() 进行实例化。

而如果我们的代码里使用了 Spring AOP，doCreateBean() 最终会返回一个代理对象。至于代理对象如何创建，大体流程我们在上一讲已经概述过了。如果你记忆力比较好的话，应该记得在代理对象的创建过程中，我们贴出过这样一段代码（参考 AbstractAutoProxyCreator#createProxy）：

```
protected Object createProxy(Class<?> beanClass, @Nullable String beanName,
      @Nullable Object[] specificInterceptors, TargetSource targetSource) {
   //省略非关键代码
   Advisor[] advisors = buildAdvisors(beanName, specificInterceptors);
   proxyFactory.addAdvisors(advisors);
   proxyFactory.setTargetSource(targetSource);
   //省略非关键代码
   return proxyFactory.getProxy(getProxyClassLoader());
}
```

其中 advisors 就是增强方法对象，它的顺序决定了面临多个增强时，到底先执行谁。而这个集合对象本身是由 specificInterceptors 构建出来的，而 specificInterceptors 又是由 AbstractAdvisorAutoProxyCreator#getAdvicesAndAdvisorsForBean 方法构建：

```
@Override
@Nullable
protected Object[] getAdvicesAndAdvisorsForBean(
      Class<?> beanClass, String beanName, @Nullable TargetSource targetSource) {
   List<Advisor> advisors = findEligibleAdvisors(beanClass, beanName);
   if (advisors.isEmpty()) {
      return DO_NOT_PROXY;
   }
   return advisors.toArray();
  }
```

简单说，其实就是根据当前的 beanClass、beanName 等信息，结合所有候选的 advisors，最终找出匹配（Eligible）的 Advisor，为什么如此？毕竟 AOP 拦截点可能会配置多个，而我们执行的方法不见得会被所有的拦截配置拦截。寻找匹配 Advisor 的逻辑参考 AbstractAdvisorAutoProxyCreator#findEligibleAdvisors：

```
protected List<Advisor> findEligibleAdvisors(Class<?> beanClass, String beanName) {
   //寻找候选的 Advisor
   List<Advisor> candidateAdvisors = findCandidateAdvisors();
   //根据候选的 Advisor 和当前 bean 算出匹配的 Advisor
   List<Advisor> eligibleAdvisors = findAdvisorsThatCanApply(candidateAdvisors, beanClass, beanName);
   extendAdvisors(eligibleAdvisors);
   if (!eligibleAdvisors.isEmpty()) {
      //排序
      eligibleAdvisors = sortAdvisors(eligibleAdvisors);
   }
   return eligibleAdvisors;
}
```

通过研读代码，最终 Advisors 的顺序是由两点决定：

1. candidateAdvisors 的顺序；
2. sortAdvisors 进行的排序。

这里我们可以重点看下对本案例起关键作用的 candidateAdvisors 排序。实际上，它的顺序是在 @Aspect 标记的 AopConfig Bean 构建时就决定了。具体而言，就是在初始化过程中会排序自己配置的 Advisors，并把排序结果存入了缓存（BeanFactoryAspectJAdvisorsBuilder#advisorsCache）。

后续 Bean 创建代理时，直接拿出这个排序好的候选 Advisors。候选 Advisors 排序发生在 Bean 构建这个结论时，我们也可以通过 AopConfig Bean 构建中的堆栈信息验证：

![](https://static001.geekbang.org/resource/image/61/d1/611f386b14b05c2d151340d31f34e3d1.png?wh=1343%2A275)

可以看到，排序是在 Bean 的构建中进行的，而最后排序执行的关键代码位于下面的方法中（参考 ReflectiveAspectJAdvisorFactory#getAdvisorMethods）：

```
private List<Method> getAdvisorMethods(Class<?> aspectClass) {
   final List<Method> methods = new ArrayList<>();
   ReflectionUtils.doWithMethods(aspectClass, method -> {
      // Exclude pointcuts
      if (AnnotationUtils.getAnnotation(method, Pointcut.class) == null) {
         methods.add(method);
      }
   }, ReflectionUtils.USER_DECLARED_METHODS);
   // 排序
   methods.sort(METHOD_COMPARATOR);
   return methods;
}
```

上述代码的重点是第九行 methods.sort(METHOD\_COMPARATOR)方法。

我们来查看 METHOD\_COMPARATOR 的代码，会发现它是定义在 ReflectiveAspectJAdvisorFactory 类中的静态方法块，代码如下：

```
static {
   Comparator<Method> adviceKindComparator = new ConvertingComparator<>(
         new InstanceComparator<>(
               Around.class, Before.class, After.class, AfterReturning.class, AfterThrowing.class),
         (Converter<Method, Annotation>) method -> {
            AspectJAnnotation<?> annotation =
               AbstractAspectJAdvisorFactory.findAspectJAnnotationOnMethod(method);
            return (annotation != null ? annotation.getAnnotation() : null);
         });
   Comparator<Method> methodNameComparator = new ConvertingComparator<>(Method::getName);
   //合并上面两者比较器
   METHOD_COMPARATOR = adviceKindComparator.thenComparing(methodNameComparator);
}
```

METHOD\_COMPARATOR 本质上是一个连续比较器，由 adviceKindComparator 和 methodNameComparator 这两个比较器通过 thenComparing()连接而成。

通过这个案例，我们重点了解 adviceKindComparator 这个比较器，此对象通过实例化 ConvertingComparator 类而来，而 ConvertingComparator 类是 Spring 中较为经典的一个实现。顾名思义，先转化再比较，它构造参数接受以下这两个参数：

- 第一个参数是基准比较器，即在 adviceKindComparator 中最终要调用的比较器，在构造函数中赋值于 this.comparator；
- 第二个参数是一个 lambda 回调函数，用来将传递的参数转化为基准比较器需要的参数类型，在构造函数中赋值于 this.converter。

查看 ConvertingComparator 比较器核心方法 compare 如下：

```
public int compare(S o1, S o2) {
   T c1 = this.converter.convert(o1);
   T c2 = this.converter.convert(o2);
   return this.comparator.compare(c1, c2);
}
```

可知，这里是先调用从构造函数中获取到的 lambda 回调函数 this.converter，将需要比较的参数进行转化。我们可以从之前的代码中找出这个转化工作：

```
(Converter<Method, Annotation>) method -> {
   AspectJAnnotation<?> annotation =
      AbstractAspectJAdvisorFactory.findAspectJAnnotationOnMethod(method);
   return (annotation != null ? annotation.getAnnotation() : null);
});
```

转化功能的代码逻辑较为简单，就是返回传入方法（method）上标记的增强注解（Pointcut,Around,Before,After,AfterReturning 以及 AfterThrowing）：

```
private static final Class<?>[] ASPECTJ_ANNOTATION_CLASSES = new Class<?>[] {
      Pointcut.class, Around.class, Before.class, After.class, AfterReturning.class, AfterThrowing.class};

protected static AspectJAnnotation<?> findAspectJAnnotationOnMethod(Method method) {
   for (Class<?> clazz : ASPECTJ_ANNOTATION_CLASSES) {
      AspectJAnnotation<?> foundAnnotation = findAnnotation(method, (Class<Annotation>) clazz);
      if (foundAnnotation != null) {
         return foundAnnotation;
      }
   }
   return null;
}
```

经过转化后，我们获取到的待比较的数据其实就是注解了。而它们的排序依赖于 ConvertingComparator 的第一个参数，即最终会调用的基准比较器，以下是它的关键实现代码：

```
new InstanceComparator<>(
      Around.class, Before.class, After.class, AfterReturning.class, AfterThrowing.class)
```

最终我们要调用的基准比较器本质上就是一个 InstanceComparator 类，我们先重点注意下这几个增强注解的传递顺序。继续查看它的构造方法如下：

```
public InstanceComparator(Class<?>... instanceOrder) {
   Assert.notNull(instanceOrder, "'instanceOrder' array must not be null");
   this.instanceOrder = instanceOrder;
}
```

构造方法也是较为简单的，只是将传递进来的 instanceOrder 赋予了类成员变量，继续查看 InstanceComparator 比较器核心方法 compare 如下，也就是最终要调用的比较方法：

```
public int compare(T o1, T o2) {
   int i1 = getOrder(o1);
   int i2 = getOrder(o2);
   return (i1 < i2 ? -1 : (i1 == i2 ? 0 : 1));
}
```

一个典型的 Comparator，代码逻辑按照 i1、i2 的升序排列，即 getOrder() 返回的值越小，排序越靠前。

查看 getOrder() 的逻辑如下：

```
private int getOrder(@Nullable T object) {
   if (object != null) {
      for (int i = 0; i < this.instanceOrder.length; i++) {
         //instance 在 instanceOrder 中的“排号”
         if (this.instanceOrder[i].isInstance(object)) {
            return i;
         }
      }
   }
   return this.instanceOrder.length;
}
```

返回当前传递的增强注解在 this.instanceOrder 中的序列值，序列值越小，则越靠前。而结合之前构造参数传递的顺序，我们很快就能判断出：最终的排序结果依次是 Around.class, Before.class, After.class, AfterReturning.class, AfterThrowing.class。

到此为止，答案也呼之欲出：this.instanceOrder 的排序，即为不同类型增强的优先级，**排序越靠前，优先级越高**。

结合之前的讨论，我们可以得出一个结论：同一个切面中，不同类型的增强方法被调用的顺序依次为Around.class, Before.class, After.class, AfterReturning.class, AfterThrowing.class。

### 问题修正

从上述案例解析中，我们知道 Around 类型的增强被调用的优先级高于 Before 类型的增强，所以上述案例中性能统计所花费的时间，包含权限验证的时间，也在情理之中。

知道了原理，修正起来也就简单了。假设不允许我们去拆分类，我们可以按照下面的思路来修改：

1. 将 ElectricService.charge() 的业务逻辑全部移动到 doCharge()，在 charge() 中调用 doCharge()；
2. 性能统计只需要拦截 doCharge()；
3. 权限统计增强保持不变，依然拦截 charge()。

ElectricService 类代码更改如下：

```
@Service
public class ElectricService {
    @Autowired
    ElectricService electricService;
    public void charge() {
        electricService.doCharge();
    }
    public void doCharge() {
        System.out.println("Electric charging ...");
    }
}
```

切面代码更改如下：

```
//省略 imports
@Aspect
@Service
public class AopConfig {
    @Before("execution(* com.spring.puzzle.class6.example1.ElectricService.charge()) ")
    public void checkAuthority(JoinPoint pjp) throws Throwable {
        System.out.println("validating user authority");
        Thread.sleep(1000);
    }

    @Around("execution(* com.spring.puzzle.class6.example1.ElectricService.doCharge()) ")
    public void recordPerformance(ProceedingJoinPoint pjp) throws Throwable {
    long start = System.currentTimeMillis();
    pjp.proceed();
    long end = System.currentTimeMillis();
    System.out.println("charge method time cost: " + (end - start));
  }
}
```

## 案例 2：错乱混合同类型增强

那学到这里，你可能还有疑问，如果同一个切面里的多个增强方法其增强都一样，那调用顺序又如何呢？我们继续看下一个案例。

这里业务逻辑类 ElectricService 没有任何变化，仅包含一个 charge()：

```
import org.springframework.stereotype.Service;
@Service
public class ElectricService {
    public void charge() {
        System.out.println("Electric charging ...");
    }
}
```

切面类 AspectService 包含两个方法，都是 Before 类型增强。

第一个方法 logBeforeMethod()，目的是在 run() 执行之前希望能输入日志，表示当前方法被调用一次，方便后期统计。另一个方法 validateAuthority()，目的是做权限验证，其作用是在调用此方法之前做权限验证，如果不符合权限限制要求，则直接抛出异常。这里为了方便演示，此方法将直接抛出异常：

```
//省略 imports
@Aspect
@Service
public class AopConfig {
  @Before("execution(* com.spring.puzzle.class5.example2.ElectricService.charge())")
  public void logBeforeMethod(JoinPoint pjp) throws Throwable {
      System.out.println("step into ->"+pjp.getSignature());
  }
  @Before("execution(* com.spring.puzzle.class5.example2.ElectricService.charge()) ")
  public void validateAuthority(JoinPoint pjp) throws Throwable {
      throw new RuntimeException("authority check failed");
  }
}
```

我们对代码的执行预期为：当鉴权失败时，由于 ElectricService.charge() 没有被调用，那么 run() 的调用日志也不应该被输出，即 logBeforeMethod() 不应该被调用，但事实总是出乎意料，执行结果如下：

> step into -&gt;void com.spring.puzzle.class6.example2.Electric.charge()  
> Exception in thread “main” java.lang.RuntimeException: authority check failed

虽然鉴权失败，抛出了异常且 ElectricService.charge() 没有被调用，但是 logBeforeMethod() 的调用日志却被输出了，这将导致后期针对于 ElectricService.charge() 的调用数据统计严重失真。

这里我们就需要搞清楚一个问题：当同一个切面包含多个同一种类型的多个增强，且修饰的都是同一个方法时，这多个增强的执行顺序是怎样的？

### 案例解析

我们继续从源代码中寻找真相！你应该还记得上述代码中，定义 METHOD\_COMPARATOR 的静态代码块吧。

METHOD\_COMPARATOR 本质是一个连续比较器，而上个案例中我们仅仅只看了第一个比较器，细心的你肯定发现了这里还有第二个比较器 methodNameComparator，任意两个比较器都可以通过其内置的 thenComparing() 连接形成一个连续比较器，从而可以让我们按照比较器的连接顺序依次比较：

```
static {
   //第一个比较器，用来按照增强类型排序
   Comparator<Method> adviceKindComparator = new ConvertingComparator<>(
         new InstanceComparator<>(
               Around.class, Before.class, After.class, AfterReturning.class, AfterThrowing.class),
         (Converter<Method, Annotation>) method -> {
            AspectJAnnotation<?> annotation =
               AbstractAspectJAdvisorFactory.findAspectJAnnotationOnMethod(method);
            return (annotation != null ? annotation.getAnnotation() : null);
         })
   //第二个比较器，用来按照方法名排序
   Comparator<Method> methodNameComparator = new ConvertingComparator<>(Method::getName);
   METHOD_COMPARATOR = adviceKindComparator.thenComparing(methodNameComparator);
}
```

我们可以看到，在第 12 行代码中，第 2 个比较器 methodNameComparator 依然使用的是 ConvertingComparator，传递了方法名作为参数。我们基本可以猜测出该比较器是按照方法名进行排序的，这里可以进一步查看构造器方法及构造器调用的内部 comparable()：

```
public ConvertingComparator(Converter<S, T> converter) {
   this(Comparators.comparable(), converter);
}
// 省略非关键代码
public static <T> Comparator<T> comparable() {
   return ComparableComparator.INSTANCE;
}
```

上述代码中的 ComparableComparator 实例其实极其简单，代码如下：

```
public class ComparableComparator<T extends Comparable<T>> implements Comparator<T> {
 
   public static final ComparableComparator INSTANCE = new ComparableComparator();

   @Override
   public int compare(T o1, T o2) {
      return o1.compareTo(o2);
   }
}
```

答案和我们的猜测完全一致，methodNameComparator 最终调用了 String 类自身的 compareTo()，代码如下：

```
public int compareTo(String anotherString) {
    int len1 = value.length;
    int len2 = anotherString.value.length;
    int lim = Math.min(len1, len2);
    char v1[] = value;
    char v2[] = anotherString.value;

    int k = 0;
    while (k < lim) {
        char c1 = v1[k];
        char c2 = v2[k];
        if (c1 != c2) {
            return c1 - c2;
        }
        k++;
    }
    return len1 - len2;
}
```

到这，答案揭晓：如果两个方法名长度相同，则依次比较每一个字母的 ASCII 码，ASCII 码越小，排序越靠前；若长度不同，且短的方法名字符串是长的子集时，短的排序靠前。

### 问题修正

从上述分析我们得知，在同一个切面配置类中，针对同一个方法存在多个同类型增强时，其执行顺序仅和当前增强方法的名称有关，而不是由谁代码在先、谁代码在后来决定。了解了这点，我们就可以直接通过调整方法名的方式来修正程序：

```
//省略 imports
@Aspect
@Service
public class AopConfig {
  @Before("execution(* com.spring.puzzle.class6.example2.ElectricService.charge())")
  public void logBeforeMethod(JoinPoint pjp) throws Throwable {
      System.out.println("step into ->"+pjp.getSignature());
  }
  @Before("execution(* com.spring.puzzle.class6.example2.ElectricService.charge()) ")
  public void checkAuthority(JoinPoint pjp) throws Throwable {
      throw new RuntimeException("authority check failed");
  }
}
```

我们可以将原来的 validateAuthority() 改为 checkAuthority()，这种情况下，**对增强（Advisor）的排序，其实最后就是在比较字符 l 和 字符 c**。显然易见，checkAuthority()的排序会靠前，从而被优先执行，最终问题得以解决。

## 重点回顾

通过学习这两个案例，相信你对 Spring AOP 增强方法的执行顺序已经有了较为深入的理解。这里我来总结下关键点：

- 在同一个切面配置中，如果存在多个不同类型的增强，那么其执行优先级是按照增强类型的特定顺序排列，依次的增强类型为 Around.class, Before.class, After.class, AfterReturning.class, AfterThrowing.class；
- 在同一个切面配置中，如果存在多个相同类型的增强，那么其执行优先级是按照该增强的方法名排序，排序方式依次为比较方法名的每一个字母，直到发现第一个不相同且 ASCII 码较小的字母。

同时，这节课我们也拓展了一些比较器相关的知识：

- 任意两个比较器（Comparator）可以通过 thenComparing() 连接合成一个新的连续比较器；
- 比较器的比较规则有一个简单的方法可以帮助你理解，就是最终一定需要对象两两比较，而比较的过程一定是比较这两个对象的同种属性。你只要抓住这两点：比较了什么属性以及比较的结果是什么就可以了，若比较结果为正数，则按照该属性的升序排列；若为负数，则按属性降序排列。

## 思考题

实际上，审阅上面两个案例的修正方案，你会发现它们虽然改动很小，但是都还不够优美。那么有没有稍微优美点的替代方案呢？如果有，你知道背后的原理及关键源码吗？顺便你也可以想想，我为什么没有用更优美的方案呢？

期待在留言区看到你的思考，我们下节课再见！
<div><strong>精选留言（14）</strong></div><ul>
<li><span>yihang</span> 👍（13） 💬（0）<p>拆分成两个切面，用@Order或Ordered接口控制顺序。个人觉得Spring在排序设计上比较混乱，各种排序规则不统一</p>2021-05-13</li><br/><li><span>luke Y</span> 👍（8） 💬（4）<p>老师你好，请教个问题，案例一的问题修正doCharge() 方法在charge()中调用，这个代理应该不会走到doCharge()的切面吧</p>2021-05-08</li><br/><li><span>大斌啊啊啊</span> 👍（7） 💬（4）<p>&quot;如果两个方法名长度相同，则依次比较每一个字母的 ASCII 码，ASCII 码越小，排序越靠前；若长度不同，且短的方法名字符串是长的子集时，短的排序靠前。&quot; 这里的描述好像有点问题，短的方法名字符串是长的子集时，短的排序不一定靠前。因为子集不能保证起始值相同，比如说”bc“是”abc“的子集，但是abc会排前面吧</p>2021-07-28</li><br/><li><span>Monday</span> 👍（4） 💬（5）<p>这段代码调用doCharge()会失效的。这不是上节课的坑吗？就躺进去了

@Service
public class ElectricService {
 
    public void charge() {
        doCharge();
    }
    public void doCharge() {
        System.out.println(&quot;Electric charging ...&quot;);
    }
}</p>2021-06-22</li><br/><li><span>松松</span> 👍（3） 💬（1）<p>直觉上@Around和@Before是各干各的，容易把优先级理解成“先用@Around包一圈然后把@Before挂前头”，实际上同一个切面配置类里是捆在一起然后判断执行顺序的。
若干切面配置类之间的Order则是优先级高（数字小）的越外层（@Around和@Before先执行），优先级低的在内层。
怎么说呢，有点儿反直觉，特别是后者，圆环套圆环直觉上来说优先级越高越靠近本体来着。
把@Around、@Before、@After拆到三个优先级从高到低的配置类中，那么会变成@Around-&gt;@Before-&gt;proceed()-&gt;@After-&gt;@Around的顺序，和放在同一个配置类中的@Around-&gt;@Before-&gt;proceed()-&gt;@Around()-&gt;@After是不一样的。</p>2021-12-11</li><br/><li><span>尘灬</span> 👍（2） 💬（0）<p>spring5.3.x版本之前的顺序是上面这样的 
之后的顺序是
around前置，before 目标方法 afterreturning&#47;afterthrowing  after  around后置</p>2022-08-15</li><br/><li><span>小飞同学</span> 👍（2） 💬（1）<p>思考题：切面实现Order接口或者增加@Ordered注解
AspectJAwareAdvisorAutoProxyCreator#sortAdvisors  --&gt;  
AnnotationAwareOrderComparator.sort(advisors)    AnnotationAwareOrderComparator

另外有个小问题：PartialOrder.sort(partiallyComparableAdvisors) 这段代码是在干啥，没看明白。
</p>2021-05-06</li><br/><li><span>安迪密恩</span> 👍（1） 💬（0）<p>师傅领进门，修行在个人。
专栏有瑕疵不要紧，知识学到手才是重要的啊同学们。
共勉。</p>2022-03-09</li><br/><li><span>李米</span> 👍（0） 💬（0）<p>请问下案例和示例代码在哪里下载？</p>2023-03-05</li><br/><li><span>中国杰</span> 👍（0） 💬（0）<p>在手机上听了好几节课了，总听音频里说是有附件，电脑上打开文稿看了下，哦，是傅健！</p>2023-03-01</li><br/><li><span>lava</span> 👍（0） 💬（0）<p>应该可以用order注解把，值越小越先执行</p>2022-12-07</li><br/><li><span>行者</span> 👍（0） 💬（0）<p>笔记：
在同一个切面配置中，如果存在多个不同类型的增强，那么其执行优先级是按照增强类型的特定顺序排列，依次的增强类型为 Around.class,Before.class,After.class,AfterReturning.class,AfterThrowing.class;
在同一个切面配置中，如果存在多个相同类型的增强，那么其执行优先级是按照该增强的方法名排序，排序放松依次为比较方法名的每一个字母，直到发现第一个不相同且ASCII码较小的字母</p>2022-04-10</li><br/><li><span>安迪密恩</span> 👍（0） 💬（0）<p>这里的 字符l 是不是写错了， 应该是字符 v？

我们可以将原来的 validateAuthority() 改为 checkAuthority()，这种情况下，对增强（Advisor）的排序，其实最后就是在比较字符 l 和 字符 c。</p>2022-03-09</li><br/><li><span>学习</span> 👍（0） 💬（0）<p>关于doChange()问题，好似后面都重新发文章了，现在是自己注入了自己，看得我一脸懵逼</p>2021-10-27</li><br/>
</ul>