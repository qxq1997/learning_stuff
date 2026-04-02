上两节课中，我们学习了模板模式。模板模式主要起到代码复用和扩展的作用。除此之外，我们还讲到了回调，它跟模板模式的作用类似，但使用起来更加灵活。它们之间的主要区别在于代码实现，模板模式基于继承来实现，回调基于组合来实现。

今天，我们开始学习另外一种行为型模式，策略模式。在实际的项目开发中，这个模式也比较常用。最常见的应用场景是，利用它来避免冗长的if-else或switch分支判断。不过，它的作用还不止如此。它也可以像模板模式那样，提供框架的扩展点等等。

对于策略模式，我们分两节课来讲解。今天，我们讲解策略模式的原理和实现，以及如何用它来避免分支判断逻辑。下一节课，我会通过一个具体的例子，来详细讲解策略模式的应用场景以及真正的设计意图。

话不多说，让我们正式开始今天的学习吧！

## 策略模式的原理与实现

策略模式，英文全称是Strategy Design Pattern。在GoF的《设计模式》一书中，它是这样定义的：

> Define a family of algorithms, encapsulate each one, and make them interchangeable. Strategy lets the algorithm vary independently from clients that use it.

翻译成中文就是：定义一族算法类，将每个算法分别封装起来，让它们可以互相替换。策略模式可以使算法的变化独立于使用它们的客户端（这里的客户端代指使用算法的代码）。

我们知道，工厂模式是解耦对象的创建和使用，观察者模式是解耦观察者和被观察者。策略模式跟两者类似，也能起到解耦的作用，不过，它解耦的是策略的定义、创建、使用这三部分。接下来，我就详细讲讲一个完整的策略模式应该包含的这三个部分。

### 1.策略的定义

策略类的定义比较简单，包含一个策略接口和一组实现这个接口的策略类。因为所有的策略类都实现相同的接口，所以，客户端代码基于接口而非实现编程，可以灵活地替换不同的策略。示例代码如下所示：

```
public interface Strategy {
  void algorithmInterface();
}

public class ConcreteStrategyA implements Strategy {
  @Override
  public void  algorithmInterface() {
    //具体的算法...
  }
}

public class ConcreteStrategyB implements Strategy {
  @Override
  public void  algorithmInterface() {
    //具体的算法...
  }
}
```

### 2.策略的创建

因为策略模式会包含一组策略，在使用它们的时候，一般会通过类型（type）来判断创建哪个策略来使用。为了封装创建逻辑，我们需要对客户端代码屏蔽创建细节。我们可以把根据type创建策略的逻辑抽离出来，放到工厂类中。示例代码如下所示：

```
public class StrategyFactory {
  private static final Map<String, Strategy> strategies = new HashMap<>();

  static {
    strategies.put("A", new ConcreteStrategyA());
    strategies.put("B", new ConcreteStrategyB());
  }

  public static Strategy getStrategy(String type) {
    if (type == null || type.isEmpty()) {
      throw new IllegalArgumentException("type should not be empty.");
    }
    return strategies.get(type);
  }
}
```

一般来讲，如果策略类是无状态的，不包含成员变量，只是纯粹的算法实现，这样的策略对象是可以被共享使用的，不需要在每次调用getStrategy()的时候，都创建一个新的策略对象。针对这种情况，我们可以使用上面这种工厂类的实现方式，事先创建好每个策略对象，缓存到工厂类中，用的时候直接返回。

相反，如果策略类是有状态的，根据业务场景的需要，我们希望每次从工厂方法中，获得的都是新创建的策略对象，而不是缓存好可共享的策略对象，那我们就需要按照如下方式来实现策略工厂类。

```
public class StrategyFactory {
  public static Strategy getStrategy(String type) {
    if (type == null || type.isEmpty()) {
      throw new IllegalArgumentException("type should not be empty.");
    }

    if (type.equals("A")) {
      return new ConcreteStrategyA();
    } else if (type.equals("B")) {
      return new ConcreteStrategyB();
    }

    return null;
  }
}
```

### 3.策略的使用

刚刚讲了策略的定义和创建，现在，我们再来看一下，策略的使用。

我们知道，策略模式包含一组可选策略，客户端代码一般如何确定使用哪个策略呢？最常见的是运行时动态确定使用哪种策略，这也是策略模式最典型的应用场景。

这里的“运行时动态”指的是，我们事先并不知道会使用哪个策略，而是在程序运行期间，根据配置、用户输入、计算结果等这些不确定因素，动态决定使用哪种策略。接下来，我们通过一个例子来解释一下。

```
// 策略接口：EvictionStrategy
// 策略类：LruEvictionStrategy、FifoEvictionStrategy、LfuEvictionStrategy...
// 策略工厂：EvictionStrategyFactory

public class UserCache {
  private Map<String, User> cacheData = new HashMap<>();
  private EvictionStrategy eviction;

  public UserCache(EvictionStrategy eviction) {
    this.eviction = eviction;
  }

  //...
}

// 运行时动态确定，根据配置文件的配置决定使用哪种策略
public class Application {
  public static void main(String[] args) throws Exception {
    EvictionStrategy evictionStrategy = null;
    Properties props = new Properties();
    props.load(new FileInputStream("./config.properties"));
    String type = props.getProperty("eviction_type");
    evictionStrategy = EvictionStrategyFactory.getEvictionStrategy(type);
    UserCache userCache = new UserCache(evictionStrategy);
    //...
  }
}

// 非运行时动态确定，在代码中指定使用哪种策略
public class Application {
  public static void main(String[] args) {
    //...
    EvictionStrategy evictionStrategy = new LruEvictionStrategy();
    UserCache userCache = new UserCache(evictionStrategy);
    //...
  }
}
```

从上面的代码中，我们也可以看出，“非运行时动态确定”，也就是第二个Application中的使用方式，并不能发挥策略模式的优势。在这种应用场景下，策略模式实际上退化成了“面向对象的多态特性”或“基于接口而非实现编程原则”。

## 如何利用策略模式避免分支判断？

实际上，能够移除分支判断逻辑的模式不仅仅有策略模式，后面我们要讲的状态模式也可以。对于使用哪种模式，具体还要看应用场景来定。 策略模式适用于根据不同类型的动态，决定使用哪种策略这样一种应用场景。

我们先通过一个例子来看下，if-else或switch-case分支判断逻辑是如何产生的。具体的代码如下所示。在这个例子中，我们没有使用策略模式，而是将策略的定义、创建、使用直接耦合在一起。

```
public class OrderService {
  public double discount(Order order) {
    double discount = 0.0;
    OrderType type = order.getType();
    if (type.equals(OrderType.NORMAL)) { // 普通订单
      //...省略折扣计算算法代码
    } else if (type.equals(OrderType.GROUPON)) { // 团购订单
      //...省略折扣计算算法代码
    } else if (type.equals(OrderType.PROMOTION)) { // 促销订单
      //...省略折扣计算算法代码
    }
    return discount;
  }
}
```

如何来移除掉分支判断逻辑呢？那策略模式就派上用场了。我们使用策略模式对上面的代码重构，将不同类型订单的打折策略设计成策略类，并由工厂类来负责创建策略对象。具体的代码如下所示：

```
// 策略的定义
public interface DiscountStrategy {
  double calDiscount(Order order);
}
// 省略NormalDiscountStrategy、GrouponDiscountStrategy、PromotionDiscountStrategy类代码...

// 策略的创建
public class DiscountStrategyFactory {
  private static final Map<OrderType, DiscountStrategy> strategies = new HashMap<>();

  static {
    strategies.put(OrderType.NORMAL, new NormalDiscountStrategy());
    strategies.put(OrderType.GROUPON, new GrouponDiscountStrategy());
    strategies.put(OrderType.PROMOTION, new PromotionDiscountStrategy());
  }

  public static DiscountStrategy getDiscountStrategy(OrderType type) {
    return strategies.get(type);
  }
}

// 策略的使用
public class OrderService {
  public double discount(Order order) {
    OrderType type = order.getType();
    DiscountStrategy discountStrategy = DiscountStrategyFactory.getDiscountStrategy(type);
    return discountStrategy.calDiscount(order);
  }
}
```

重构之后的代码就没有了if-else分支判断语句了。实际上，这得益于策略工厂类。在工厂类中，我们用Map来缓存策略，根据type直接从Map中获取对应的策略，从而避免if-else分支判断逻辑。等后面讲到使用状态模式来避免分支判断逻辑的时候，你会发现，它们使用的是同样的套路。本质上都是借助“查表法”，根据type查表（代码中的strategies就是表）替代根据type分支判断。

但是，如果业务场景需要每次都创建不同的策略对象，我们就要用另外一种工厂类的实现方式了。具体的代码如下所示：

```
public class DiscountStrategyFactory {
  public static DiscountStrategy getDiscountStrategy(OrderType type) {
    if (type == null) {
      throw new IllegalArgumentException("Type should not be null.");
    }
    if (type.equals(OrderType.NORMAL)) {
      return new NormalDiscountStrategy();
    } else if (type.equals(OrderType.GROUPON)) {
      return new GrouponDiscountStrategy();
    } else if (type.equals(OrderType.PROMOTION)) {
      return new PromotionDiscountStrategy();
    }
    return null;
  }
}
```

这种实现方式相当于把原来的if-else分支逻辑，从OrderService类中转移到了工厂类中，实际上并没有真正将它移除。关于这个问题如何解决，我今天先暂时卖个关子。你可以在留言区说说你的想法，我在下一节课中再讲解。

## 重点回顾

好了，今天的内容到此就讲完了。我们一块来总结回顾一下，你需要重点掌握的内容。

策略模式定义一族算法类，将每个算法分别封装起来，让它们可以互相替换。策略模式可以使算法的变化独立于使用它们的客户端（这里的客户端代指使用算法的代码）。

策略模式用来解耦策略的定义、创建、使用。实际上，一个完整的策略模式就是由这三个部分组成的。

- 策略类的定义比较简单，包含一个策略接口和一组实现这个接口的策略类。
- 策略的创建由工厂类来完成，封装策略创建的细节。
- 策略模式包含一组策略可选，客户端代码如何选择使用哪个策略，有两种确定方法：编译时静态确定和运行时动态确定。其中，“运行时动态确定”才是策略模式最典型的应用场景。

除此之外，我们还可以通过策略模式来移除if-else分支判断。实际上，这得益于策略工厂类，更本质上点讲，是借助“查表法”，根据type查表替代根据type分支判断。

## 课堂讨论

今天我们讲到，在策略工厂类中，如果每次都要返回新的策略对象，我们还是需要在工厂类中编写if-else分支判断逻辑，那这个问题该如何解决呢？

欢迎留言和我分享你的想法。如果有收获，也欢迎你把这篇文章分享给你的朋友。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>卖火柴的托儿索</span> 👍（9） 💬（3）<p>这个策略和多态有什么区别？感觉用法差不多</p>2020-04-26</li><br/><li><span>改名不换人</span> 👍（3） 💬（3）<p>请问各位一个问题：如果在spring应用中，Map策略表中的对象应该是new创建的，还是用autowired注入？</p>2020-07-30</li><br/><li><span>宁锟</span> 👍（275） 💬（22）<p>仍然可以用查表法，只不过存储的不再是实例，而是class，使用时获取对应的class，再通过反射创建实例</p>2020-03-20</li><br/><li><span>下雨天</span> 👍（86） 💬（3）<p>策略模式和工厂模式区别：

工厂模式
1.目的是创建不同且相关的对象
2.侧重于&quot;创建对象&quot;
3.实现方式上可以通过父类或者接口
4.一般创建对象应该是现实世界中某种事物的映射，有它自己的属性与方法！

策略模式
1.目的实现方便地替换不同的算法类
2.侧重于算法(行为)实现
3.实现主要通过接口
4.创建对象对行为的抽象而非对对象的抽象，很可能没有属于自己的属性。</p>2020-03-20</li><br/><li><span>Michael</span> 👍（48） 💬（0）<p>一般而言Java web开发中我们均使用spring框架，可以使用运行时自定义注解给具体的策略类打上注解，将具体的策略类放于spring 容器中，工厂中注入直接根据类型获取即可.不实用spring框架的话，也可以用Java的反射做到获取到具体的策略类</p>2020-03-20</li><br/><li><span>zhengyu.nie</span> 👍（29） 💬（4）<p>查表策略还是挺常见的，搭配java.util.function各种接口挺好用的。

    private final Map&lt;String, Function&lt;String, String&gt;&gt; PHONE_FUN_FACTORY =
        ImmutableMap.of(
            MessageDestination.LEGAL_PERSON.name(), legalPersonPhoneFunc(),
            MessageDestination.ACTUAL_CONTROL.name(), actualPersonPhoneFunc()
        );

我比较喜欢建一个StrategyContext类，简单工厂+策略模式。
Context类存在一个成员变量xxx，new StrategyContext(xxx).apply();
然后StrategyContext内部存放一个表，value是一堆function，通过成员变量查表找对应的func.apply即可</p>2020-05-06</li><br/><li><span>攻城拔寨</span> 👍（25） 💬（0）<p>策略模式通常跟工厂一起配合使用。
策略侧重如何灵活选择替换，
工厂侧重怎么创建实例</p>2020-03-20</li><br/><li><span>Jasongrass</span> 👍（17） 💬（5）<p>if else 不是必须要解决的问题，如果放在工厂类中，逻辑比较简单，未来的变动也不会很大，就是 OK 的。</p>2020-03-23</li><br/><li><span>aoe</span> 👍（16） 💬（2）<p>原来策略模式的精髓就是：用Map代替冗长的if-else&#47;switch分支判断！
哇！</p>2020-07-28</li><br/><li><span>东征</span> 👍（12） 💬（2）<p>仍然使用查表法，表中存类型和class，根据类型获取对象时，使用class动态创建。或者表中存类型和一个创建函数，根据类型获取对象时，获取到创建函数，调用创建函数创建新对象（java里可以用lambda或者对象代替函数）</p>2020-04-03</li><br/><li><span>岁月</span> 👍（7） 💬（0）<p>课堂讨论
字典里保存好创建新对象的闭包代码块即可，或者说是回调函数，这样就可以创建出新的对象了，我们项目就是用的这个方法</p>2020-04-01</li><br/><li><span>Geek_3231cf</span> 👍（6） 💬（1）<p>可以在策略接口中，再抽象出来一个bool switch(T condition)方法，将判断移至具体策略实现类
工厂中getDiscountStrategy()方法中拿到所有策略类，根据condition找到符合的策略
伪代码：
DiscountStrategy getDiscountStrategy(T condition)
{ 
allStartegys.foreach(
if(switch(condition) 
return thisStartegy;
))}
使用起来就是DiscountStrategyFactory.getDiscountStrategy(condition).discount(order);</p>2020-03-20</li><br/><li><span>Jxin</span> 👍（6） 💬（5）<p>1.业务代码少用反射。这个场景和原型模式的应用场景很贴合。依旧是type查表，只是每次使用的都是type对应策略实例的copy对象。详细请参照spring原型模式的实现。

2.往往业务场景里面，往往不是选择策略这一场景，而是编排策略这一场景。即利用type查表拿出一堆要用到的策略，并按顺序去执行。对于这种场景，栏主怎么看？</p>2020-03-20</li><br/><li><span>Geek_78eadb</span> 👍（5） 💬（3）<p>如果我说，这个例子就是工厂模式，并且可以放到工厂方法的那一章，该怎么反驳我？
1. 为什么算法类的实例化就不是对象（工厂解决的是创建对象的问题，算法类难道不是对象吗）？
2. 工厂模式为什么不能用查表法解决，如果可以，为什么不能说工厂模式与策略模式一样（不要说关注角度不一样，我粗俗认为对象和类可以包含任何情况，比如算法类）？</p>2020-11-21</li><br/><li><span>Michael</span> 👍（4） 💬（0）<p>我觉得结合下Spring中的应用场景讲下，毕竟大家都是依赖Spring开发的</p>2020-03-22</li><br/>
</ul>