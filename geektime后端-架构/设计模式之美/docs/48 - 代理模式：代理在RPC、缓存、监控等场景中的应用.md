前面几节，我们学习了设计模式中的创建型模式。创建型模式主要解决对象的创建问题，封装复杂的创建过程，解耦对象的创建代码和使用代码。

其中，单例模式用来创建全局唯一的对象。工厂模式用来创建不同但是相关类型的对象（继承同一父类或者接口的一组子类），由给定的参数来决定创建哪种类型的对象。建造者模式是用来创建复杂对象，可以通过设置不同的可选参数，“定制化”地创建不同的对象。原型模式针对创建成本比较大的对象，利用对已有对象进行复制的方式进行创建，以达到节省创建时间的目的。

从今天起，我们开始学习另外一种类型的设计模式：结构型模式。结构型模式主要总结了一些类或对象组合在一起的经典结构，这些经典的结构可以解决特定应用场景的问题。结构型模式包括：代理模式、桥接模式、装饰器模式、适配器模式、门面模式、组合模式、享元模式。今天我们要讲其中的代理模式。它也是在实际开发中经常被用到的一种设计模式。

话不多说，让我们正式开始今天的学习吧！

## 代理模式的原理解析

**代理模式**（Proxy Design Pattern）的原理和代码实现都不难掌握。它在不改变原始类（或叫被代理类）代码的情况下，通过引入代理类来给原始类附加功能。我们通过一个简单的例子来解释一下这段话。

这个例子来自我们在第25、26、39、40节中讲的性能计数器。当时我们开发了一个MetricsCollector类，用来收集接口请求的原始数据，比如访问时间、处理时长等。在业务系统中，我们采用如下方式来使用这个MetricsCollector类：

```
public class UserController {
  //...省略其他属性和方法...
  private MetricsCollector metricsCollector; // 依赖注入

  public UserVo login(String telephone, String password) {
    long startTimestamp = System.currentTimeMillis();

    // ... 省略login逻辑...

    long endTimeStamp = System.currentTimeMillis();
    long responseTime = endTimeStamp - startTimestamp;
    RequestInfo requestInfo = new RequestInfo("login", responseTime, startTimestamp);
    metricsCollector.recordRequest(requestInfo);

    //...返回UserVo数据...
  }

  public UserVo register(String telephone, String password) {
    long startTimestamp = System.currentTimeMillis();

    // ... 省略register逻辑...

    long endTimeStamp = System.currentTimeMillis();
    long responseTime = endTimeStamp - startTimestamp;
    RequestInfo requestInfo = new RequestInfo("register", responseTime, startTimestamp);
    metricsCollector.recordRequest(requestInfo);

    //...返回UserVo数据...
  }
}
```

很明显，上面的写法有两个问题。第一，性能计数器框架代码侵入到业务代码中，跟业务代码高度耦合。如果未来需要替换这个框架，那替换的成本会比较大。第二，收集接口请求的代码跟业务代码无关，本就不应该放到一个类中。业务类最好职责更加单一，只聚焦业务处理。

为了将框架代码和业务代码解耦，代理模式就派上用场了。代理类UserControllerProxy和原始类UserController实现相同的接口IUserController。UserController类只负责业务功能。代理类UserControllerProxy负责在业务代码执行前后附加其他逻辑代码，并通过委托的方式调用原始类来执行业务代码。具体的代码实现如下所示：

```
public interface IUserController {
  UserVo login(String telephone, String password);
  UserVo register(String telephone, String password);
}

public class UserController implements IUserController {
  //...省略其他属性和方法...

  @Override
  public UserVo login(String telephone, String password) {
    //...省略login逻辑...
    //...返回UserVo数据...
  }

  @Override
  public UserVo register(String telephone, String password) {
    //...省略register逻辑...
    //...返回UserVo数据...
  }
}

public class UserControllerProxy implements IUserController {
  private MetricsCollector metricsCollector;
  private UserController userController;

  public UserControllerProxy(UserController userController) {
    this.userController = userController;
    this.metricsCollector = new MetricsCollector();
  }

  @Override
  public UserVo login(String telephone, String password) {
    long startTimestamp = System.currentTimeMillis();

    // 委托
    UserVo userVo = userController.login(telephone, password);

    long endTimeStamp = System.currentTimeMillis();
    long responseTime = endTimeStamp - startTimestamp;
    RequestInfo requestInfo = new RequestInfo("login", responseTime, startTimestamp);
    metricsCollector.recordRequest(requestInfo);

    return userVo;
  }

  @Override
  public UserVo register(String telephone, String password) {
    long startTimestamp = System.currentTimeMillis();

    UserVo userVo = userController.register(telephone, password);

    long endTimeStamp = System.currentTimeMillis();
    long responseTime = endTimeStamp - startTimestamp;
    RequestInfo requestInfo = new RequestInfo("register", responseTime, startTimestamp);
    metricsCollector.recordRequest(requestInfo);

    return userVo;
  }
}

//UserControllerProxy使用举例
//因为原始类和代理类实现相同的接口，是基于接口而非实现编程
//将UserController类对象替换为UserControllerProxy类对象，不需要改动太多代码
IUserController userController = new UserControllerProxy(new UserController());
```

参照基于接口而非实现编程的设计思想，将原始类对象替换为代理类对象的时候，为了让代码改动尽量少，在刚刚的代理模式的代码实现中，代理类和原始类需要实现相同的接口。但是，如果原始类并没有定义接口，并且原始类代码并不是我们开发维护的（比如它来自一个第三方的类库），我们也没办法直接修改原始类，给它重新定义一个接口。在这种情况下，我们该如何实现代理模式呢？

对于这种外部类的扩展，我们一般都是采用继承的方式。这里也不例外。我们让代理类继承原始类，然后扩展附加功能。原理很简单，不需要过多解释，你直接看代码就能明白。具体代码如下所示：

```
public class UserControllerProxy extends UserController {
  private MetricsCollector metricsCollector;

  public UserControllerProxy() {
    this.metricsCollector = new MetricsCollector();
  }

  public UserVo login(String telephone, String password) {
    long startTimestamp = System.currentTimeMillis();

    UserVo userVo = super.login(telephone, password);

    long endTimeStamp = System.currentTimeMillis();
    long responseTime = endTimeStamp - startTimestamp;
    RequestInfo requestInfo = new RequestInfo("login", responseTime, startTimestamp);
    metricsCollector.recordRequest(requestInfo);

    return userVo;
  }

  public UserVo register(String telephone, String password) {
    long startTimestamp = System.currentTimeMillis();

    UserVo userVo = super.register(telephone, password);

    long endTimeStamp = System.currentTimeMillis();
    long responseTime = endTimeStamp - startTimestamp;
    RequestInfo requestInfo = new RequestInfo("register", responseTime, startTimestamp);
    metricsCollector.recordRequest(requestInfo);

    return userVo;
  }
}
//UserControllerProxy使用举例
UserController userController = new UserControllerProxy();
```

## 动态代理的原理解析

不过，刚刚的代码实现还是有点问题。一方面，我们需要在代理类中，将原始类中的所有的方法，都重新实现一遍，并且为每个方法都附加相似的代码逻辑。另一方面，如果要添加的附加功能的类有不止一个，我们需要针对每个类都创建一个代理类。

如果有50个要添加附加功能的原始类，那我们就要创建50个对应的代理类。这会导致项目中类的个数成倍增加，增加了代码维护成本。并且，每个代理类中的代码都有点像模板式的“重复”代码，也增加了不必要的开发成本。那这个问题怎么解决呢？

我们可以使用动态代理来解决这个问题。所谓**动态代理**（Dynamic Proxy），就是我们不事先为每个原始类编写代理类，而是在运行的时候，动态地创建原始类对应的代理类，然后在系统中用代理类替换掉原始类。那如何实现动态代理呢？

如果你熟悉的是Java语言，实现动态代理就是件很简单的事情。因为Java语言本身就已经提供了动态代理的语法（实际上，动态代理底层依赖的就是Java的反射语法）。我们来看一下，如何用Java的动态代理来实现刚刚的功能。具体的代码如下所示。其中，MetricsCollectorProxy作为一个动态代理类，动态地给每个需要收集接口请求信息的类创建代理类。

```
public class MetricsCollectorProxy {
  private MetricsCollector metricsCollector;

  public MetricsCollectorProxy() {
    this.metricsCollector = new MetricsCollector();
  }

  public Object createProxy(Object proxiedObject) {
    Class<?>[] interfaces = proxiedObject.getClass().getInterfaces();
    DynamicProxyHandler handler = new DynamicProxyHandler(proxiedObject);
    return Proxy.newProxyInstance(proxiedObject.getClass().getClassLoader(), interfaces, handler);
  }

  private class DynamicProxyHandler implements InvocationHandler {
    private Object proxiedObject;

    public DynamicProxyHandler(Object proxiedObject) {
      this.proxiedObject = proxiedObject;
    }

    @Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
      long startTimestamp = System.currentTimeMillis();
      Object result = method.invoke(proxiedObject, args);
      long endTimeStamp = System.currentTimeMillis();
      long responseTime = endTimeStamp - startTimestamp;
      String apiName = proxiedObject.getClass().getName() + ":" + method.getName();
      RequestInfo requestInfo = new RequestInfo(apiName, responseTime, startTimestamp);
      metricsCollector.recordRequest(requestInfo);
      return result;
    }
  }
}

//MetricsCollectorProxy使用举例
MetricsCollectorProxy proxy = new MetricsCollectorProxy();
IUserController userController = (IUserController) proxy.createProxy(new UserController());
```

实际上，Spring AOP底层的实现原理就是基于动态代理。用户配置好需要给哪些类创建代理，并定义好在执行原始类的业务代码前后执行哪些附加功能。Spring为这些类创建动态代理对象，并在JVM中替代原始类对象。原本在代码中执行的原始类的方法，被换作执行代理类的方法，也就实现了给原始类添加附加功能的目的。

## 代理模式的应用场景

代理模式的应用场景非常多，我这里列举一些比较常见的用法，希望你能举一反三地应用在你的项目开发中。

### 1.业务系统的非功能性需求开发

代理模式最常用的一个应用场景就是，在业务系统中开发一些非功能性需求，比如：监控、统计、鉴权、限流、事务、幂等、日志。我们将这些附加功能与业务功能解耦，放到代理类中统一处理，让程序员只需要关注业务方面的开发。实际上，前面举的搜集接口请求信息的例子，就是这个应用场景的一个典型例子。

如果你熟悉Java语言和Spring开发框架，这部分工作都是可以在Spring AOP切面中完成的。前面我们也提到，Spring AOP底层的实现原理就是基于动态代理。

### 2.代理模式在RPC、缓存中的应用

**实际上，RPC框架也可以看作一种代理模式**，GoF的《设计模式》一书中把它称作远程代理。通过远程代理，将网络通信、数据编解码等细节隐藏起来。客户端在使用RPC服务的时候，就像使用本地函数一样，无需了解跟服务器交互的细节。除此之外，RPC服务的开发者也只需要开发业务逻辑，就像开发本地使用的函数一样，不需要关注跟客户端的交互细节。

关于远程代理的代码示例，我自己实现了一个简单的RPC框架Demo，放到了GitHub中，你可以点击这里的[链接](https://github.com/wangzheng0822/codedesign/tree/master/com/xzg/cd/rpc)查看。

**我们再来看代理模式在缓存中的应用。**假设我们要开发一个接口请求的缓存功能，对于某些接口请求，如果入参相同，在设定的过期时间内，直接返回缓存结果，而不用重新进行逻辑处理。比如，针对获取用户个人信息的需求，我们可以开发两个接口，一个支持缓存，一个支持实时查询。对于需要实时数据的需求，我们让其调用实时查询接口，对于不需要实时数据的需求，我们让其调用支持缓存的接口。那如何来实现接口请求的缓存功能呢？

最简单的实现方法就是刚刚我们讲到的，给每个需要支持缓存的查询需求都开发两个不同的接口，一个支持缓存，一个支持实时查询。但是，这样做显然增加了开发成本，而且会让代码看起来非常臃肿（接口个数成倍增加），也不方便缓存接口的集中管理（增加、删除缓存接口）、集中配置（比如配置每个接口缓存过期时间）。

针对这些问题，代理模式就能派上用场了，确切地说，应该是动态代理。如果是基于Spring框架来开发的话，那就可以在AOP切面中完成接口缓存的功能。在应用启动的时候，我们从配置文件中加载需要支持缓存的接口，以及相应的缓存策略（比如过期时间）等。当请求到来的时候，我们在AOP切面中拦截请求，如果请求中带有支持缓存的字段（比如http://…?..&amp;cached=true），我们便从缓存（内存缓存或者Redis缓存等）中获取数据直接返回。

## 重点回顾

好了，今天的内容到此就讲完了。我们一块来总结回顾一下，你需要掌握的重点内容。

**1.代理模式的原理与实现**

在不改变原始类（或叫被代理类）的情况下，通过引入代理类来给原始类附加功能。一般情况下，我们让代理类和原始类实现同样的接口。但是，如果原始类并没有定义接口，并且原始类代码并不是我们开发维护的。在这种情况下，我们可以通过让代理类继承原始类的方法来实现代理模式。

**2.动态代理的原理与实现**

静态代理需要针对每个类都创建一个代理类，并且每个代理类中的代码都有点像模板式的“重复”代码，增加了维护成本和开发成本。对于静态代理存在的问题，我们可以通过动态代理来解决。我们不事先为每个原始类编写代理类，而是在运行的时候动态地创建原始类对应的代理类，然后在系统中用代理类替换掉原始类。

**3.代理模式的应用场景**

代理模式常用在业务系统中开发一些非功能性需求，比如：监控、统计、鉴权、限流、事务、幂等、日志。我们将这些附加功能与业务功能解耦，放到代理类统一处理，让程序员只需要关注业务方面的开发。除此之外，代理模式还可以用在RPC、缓存等应用场景中。

## 课堂讨论

1. 除了Java语言之外，在你熟悉的其他语言中，如何实现动态代理呢？
2. 我们今天讲了两种代理模式的实现方法，一种是基于组合，一种基于继承，请对比一下两者的优缺点。

欢迎留言和我分享你的思考，如果有收获，也欢迎你把这篇文章分享给你的朋友。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>Kevin</span> 👍（2） 💬（1）<p>基于继承的静态代理实现的demo中稍微有些瑕疵。 
login() 和register() 方法应该直接调用super.login() 和 super.register() ,然后再super前后插入额外的代码 。这样更像在代理，而不是在继承修改父类。给争哥提个不成熟的小建议。

</p>2020-06-02</li><br/><li><span>海贼王</span> 👍（0） 💬（1）<p>文章很有实用性，对于拓展思路很有帮助</p>2020-11-28</li><br/><li><span>成长型思维</span> 👍（0） 💬（1）<p>代理模式也叫中介模式吗</p>2020-11-18</li><br/><li><span>小兵</span> 👍（176） 💬（8）<p>组合模式的优点在于更加灵活，对于接口的所有子类都可以代理，缺点在于不需要扩展的方法也需要进行代理。
继承模式的优点在于只需要针对需要扩展的方法进行代理，缺点在于只能针对单一父类进行代理。
</p>2020-02-23</li><br/><li><span>，</span> 👍（129） 💬（2）<p>      java中,动态代理的实现基于字节码生成技术(代码里就是newProxyInstance片段),可以在jvm运行时动态生成和加载字节码,类似的技术还有asm,cglib,javassist,平时编译java用的javac命令就是字节码生成技术的&quot;老祖宗&quot;
     java中用到字节码生成技术的还有JSP编译器.AOP框架,反射等等
     深入理解java虚拟机第三版里对动态代理的描述:
     动态代理中所说的&quot;动态&quot;,是针对使用Java代码实际编写了代理类的&quot;静态&quot;代理而言的,它的优势不在于省去了编写代理类那一点编码工作量,而是实现了可以在原始类和接口还未知的时候,就确定了代理类的行为,当代理类与原始类脱离直接联系后,就可以很灵活的重用于不同的应用场景之中
     </p>2020-02-21</li><br/><li><span>free2one</span> 👍（32） 💬（7）<p>粗略“翻译”至PHP，中间省略了很多关键的判断，主要是想知道有多少PHPer在看。

interface IUserController 
{
    public function login(String $telephone, String $password);
    public function register(String $telephone, String $password);
}
  
class UserController implements IUserController 
{
    public function login(String $telephone, String $password) 
    {
        echo &#39;is Login&#39; . PHP_EOL;
    }
  
    public function register(String $telephone, String $password) 
    {

    }
}

class MetricsCollector
{
    public function recordRequest($requestInfo)
    {
    }
}

class RequestInfo
{
    public function __construct($apiName, $responseTime, $startTimestamp)
    {
    }
}


class MetricsCollectorProxy 
{
    private $proxiedObject;

    private $metricsCollector;

    public function __construct(MetricsCollector $metricsCollector)
    {
        $this-&gt;metricsCollector = $metricsCollector;
    }
    
    public function createProxy(object $object)
    {
        $this-&gt;proxiedObject = $object;
        return $this;
    }

    public function __call($method, $arguments)
    {
        $ref = new ReflectionClass($this-&gt;proxiedObject);
        if (!$ref-&gt;hasMethod($method))
            throw new Exception(&quot;method not existed&quot;);

        $method = $ref-&gt;getMethod($method);
        $startTimestamp = time();
        $userVo = $this-&gt;callMethod($method, $arguments);
        $endTimeStamp = time();
        $responseTime = $endTimeStamp - $startTimestamp;
        $requestInfo = new RequestInfo(&quot;login&quot;, $responseTime, $startTimestamp);
        $this-&gt;metricsCollector-&gt;recordRequest($requestInfo);

        return $userVo;    
    }


    private function callMethod(\ReflectionMethod $method, $arguments)
    {
        &#47;&#47;前置判断省略
        $method-&gt;invokeArgs($this-&gt;proxiedObject, $arguments);  
    }

}


$proxy = new MetricsCollectorProxy(new MetricsCollector);
$userController = $proxy-&gt;createProxy(new UserController);
$userController-&gt;login(13800138000, &#39;pwd&#39;);
</p>2020-04-11</li><br/><li><span>LJK</span> 👍（28） 💬（5）<p>是时候展示我动态语言Python的彪悍了，通过__getattribute__和闭包的配合实现，其中有个注意点就是在获取target时不能使用self.target，不然会递归调用self.__getattribute__导致堆栈溢出：
class RealClass(object):
    def realFunc(self, s):
        print(f&quot;Real func is coming {s}&quot;)

class DynamicProxy(object):
    def __init__(self, target):
        self.target = target
    
    def __getattribute__(self, name):
        target = object.__getattribute__(self, &quot;target&quot;)
        attr = object.__getattribute__(target, name)
        
        def newAttr(*args, **kwargs):
            print(&quot;Before Calling Func&quot;)
            res = attr(*args, **kwargs)
            print(&quot;After Calling Func&quot;)
            return res
        return newAttr</p>2020-02-21</li><br/><li><span>迷羊</span> 👍（27） 💬（0）<p>Java中的动态代理原理就是运行的时候通过asm在内存中生成一份字节码，而这个字节码就是代理类的字节码，通过System.getProperties().put(&quot;sun.misc.ProxyGenerator.saveGeneratedFiles&quot;, &quot;true&quot;);设置可以保存这份字节码，反编译后看下其源码就知道Java中的动态代理是什么原理了。</p>2020-02-22</li><br/><li><span>辣么大</span> 👍（17） 💬（3）<p>感谢争哥，今天终于学会了“动态代理”
还是要动手试试，代码在这是 https:&#47;&#47;bit.ly&#47;37UqLNf

学有余力的小伙伴，附上一些资料吧：
https:&#47;&#47;docs.oracle.com&#47;javase&#47;8&#47;docs&#47;technotes&#47;guides&#47;reflection&#47;proxy.html
https:&#47;&#47;www.baeldung.com&#47;java-dynamic-proxies</p>2020-02-25</li><br/><li><span>不似旧日</span> 👍（12） 💬（2）<p>笔记：

- 什么是代理模式：它在不改变原始类（或叫被代理类）代码的情况下，通过引入代理类来给原始类附加功能。

- 代理模式得实现：
  - 静态代理
    1. 实现被代理对象口： 要求被代理类和代理类同时实现相应的一套接口，通过代理类调用重写接口的方法，实际上调用的是原始对象的同样的方法。
    2. 继承被代理对象：代理类继承原始类，然后扩展附加功能。
  - 动态代理 ： 在运行的时候，动态地创建原始类对应的代理类，然后在系统中用代理类替换掉原始类。 
    1.  jdk动态代理是利用反射机制生成一个实现代理接口的匿名类，在调用具体方法前调用InvokeHandler来处理。
    2. cglib动态代理是利用asm开源包，对被代理对象类的class文件加载进来，通过修改其字节码生成子类来处理。 </p>2020-02-24</li><br/><li><span>webmin</span> 👍（11） 💬（0）<p>1. .net支持反射和动态代理，所以实现方式和java类似；golang目前看到的都是习惯使用代码生成的方式来达成，根据已有代码生成一份加壳代码，调用方使用加壳代码的方法，例好：easyJson给类加上序列化和反序列化功能；gomock生成mock代理。
2. 组合与继承的优缺点：
没有绝对的优缺点，要看场景比如：
当被代理的类所有功能都需要被代理时，使用继承方式就可以编译器检查（被代理类修改时编译期就可以检查出问题）；
当被代理的类只是部分功能需要被代理时，使用组合方式就可按需代理，但是如果原来不需要的，后来也需要了就比较尴尬了。
继承可能会让代理类被迫实现一些对代理类来说无意义代码，继承方式对代理类的侵入比较大，而组合的侵入影响比继承可控。</p>2020-02-21</li><br/><li><span>小马哥</span> 👍（10） 💬（1）<p>不少同学纠结代理模式与后面要学的装饰器模式在功能上不能区分, 小马哥给个最简单的解释
 *          在行为效果上, 两种设计模式都可以实现增强
 *          代理模式的增强: 添加非业务功能;
 *          装饰器模式的增强: 弥补或者扩展业务功能;
如果你非要使用装饰器进行非业务功能的增强, 以及使用代理模式扩展业务功能是否可以? 可以, 但是我们学习设计模式的目的是为了写出大牛一样专业的代码, 那么就借鉴设计模式的规则.
去高速公路上开车就遵守高速的限速规定</p>2021-05-03</li><br/><li><span>Eden Ma</span> 👍（9） 💬（5）<p>1、OC中通过runtime和分类来实现动态代理.
2、组合优势可以直接使用原始类实例,继承要通过代理类实例来操作,可能会导致有人用原始类有人用代理类.而继承可以不改变原始类代码来使用.</p>2020-02-21</li><br/><li><span>J.Smile</span> 👍（8） 💬（3）<p>动态代理有两种:jdk动态代理和cglib动态代理。</p>2020-02-21</li><br/><li><span>Geek_35cfdd</span> 👍（7） 💬（1）<p>动态代码虽然对使用场景讲了，先不说自己如何实现一个动态代码没有讲。就算拿java的现成接口，是不是最起码应该讲下里面的实现。做到知其然知其所以然呢？你这动态代理讲的就像一个hello world。</p>2020-09-09</li><br/>
</ul>