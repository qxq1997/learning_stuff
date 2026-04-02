你好，我是郭屹，从今天开始我们来学习手写MiniSpring。

这一章，我们将从一个最简单的程序开始，一步步堆积演化，最后实现Spring这一庞大框架的核心部分。这节课，我们就来构造第一个程序，也是最简单的一个程序，将最原始的IoC概念融入我们的框架之中，**我们就用这个原始的IoC容器来管理一个Bean。**不过要说的是，它虽然原始，却也是一个可以运行的IoC容器。

## IoC容器

如果你使用过Spring或者了解Spring框架，肯定会对IoC容器有所耳闻。它的意思是使用Bean容器管理一个个的Bean，最简单的Bean就是一个Java的业务对象。在Java中，创建一个对象最简单的方法就是使用 new 关键字。IoC容器，也就是**BeanFactory，存在的意义就是将创建对象与使用对象的业务代码解耦**，让业务开发人员无需关注底层对象（Bean）的构建和生命周期管理，专注于业务开发。

那我们可以先想一想，怎样实现Bean的管理呢？我建议你不要直接去参考Spring的实现，那是大树长成之后的模样，复杂而庞大，令人生畏。

作为一颗种子，它其实可以非常原始、非常简单。实际上我们只需要几个简单的部件：我们用一个部件来对应Bean内存的映像，一个定义在外面的Bean在内存中总是需要有一个映像的；一个XML reader 负责从外部XML文件获取Bean的配置，也就是说这些Bean是怎么声明的，我们可以写在一个外部文件里，然后我们用XML reader从外部文件中读取进来；我们还需要一个反射部件，负责加载Bean Class并且创建这个实例；创建实例之后，我们用一个Map来保存Bean的实例；最后我们提供一个getBean() 方法供外部使用。我们这个IoC容器就做好了。

![图片](https://static001.geekbang.org/resource/image/a3/c3/a382d7774c7aa504231721c7d28028c3.png?wh=1905x1253)

好，接下来我们一步步来构造。

## 实现一个原始版本的IoC容器

对于现在要着手实现的原始版本Bean，我们先只管理两个属性：**id与class**。其中，class表示要注入的类，而id则是给这个要注入的类一个别名，它可以简化记忆的成本。我们要做的是把Bean通过XML的方式注入到框架中，你可以看一下XML的配置。

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<beans>
    <bean id = "xxxid" class = "com.minis.xxxclass"></bean>
</beans>
```

接下来我们要做一些准备工作。首先，新建一个Java项目，导入dom4j-1.6.1.jar包。这里导入的dom4j包封装了许多操作XML文件的方法，有助于我们快速处理XML文件中的各种属性，这样就不需要我们自己再写一个XML的解析工具了，同时它也为我们后续处理依托于XML注入的Bean提供了便利。

另外要说明的是，我们写MiniSpring是为了学习Spring框架，所以我们会尽量少地去依赖第三方包，多自己动手，以原始社会刀耕火种的方式写程序，这可以让我们彻底地理解底层原理。希望你能够跟我一起动手，毕竟编程说到底是一个手艺活，要想提高编程水平，唯一的方法就是动手去写。只要不断学，不断想，不断做，就能大有成效。

### 构建BeanDefinition

好了，在有了第一个Java项目后，我们创建com.minis包，我们所有的程序都是放在这个包下的。在这个包下构建第一个类，对应Bean的定义，命名为BeanDefinition。我们在这个类里面定义两个最简单的域：id与className。你可以看一下相关代码。

```java
public class BeanDefinition {
    private String id;
    private String className;
    public BeanDefinition(String id, String className) {
        this.id = id;
        this.className = className;
    }
    //省略getter和setter
```

可以看到，这段代码为这样一个Bean提供了全参数的构造方法，也提供了基本的getter和setter方法，方便我们获取域的值以及对域里的值赋值。

### 实现ClassPathXmlApplicationContext

接下来，我们假定已经存在一个用于注入Bean的XML文件。那我们要做的自然是，按照一定的规则将这个XML文件的内容解析出来，获取Bean的配置信息。我们的第二个类ClassPathXmlApplicationContext就可以做到这一点。通过这个类的名字也可以看出，它的作用是解析某个路径下的XML来构建应用上下文。让我们来看看如何初步实现这个类。

```java
public class ClassPathXmlApplicationContext {
    private List<BeanDefinition> beanDefinitions = new ArrayList<>();
    private Map<String, Object> singletons = new HashMap<>();
    //构造器获取外部配置，解析出Bean的定义，形成内存映像
    public ClassPathXmlApplicationContext(String fileName) {
        this.readXml(fileName);
        this.instanceBeans();
    }
    private void readXml(String fileName) {
        SAXReader saxReader = new SAXReader();
        try {
            URL xmlPath =
this.getClass().getClassLoader().getResource(fileName);
            Document document = saxReader.read(xmlPath);
            Element rootElement = document.getRootElement();
            //对配置文件中的每一个<bean>，进行处理
            for (Element element : (List<Element>) rootElement.elements()) {
                //获取Bean的基本信息
                String beanID = element.attributeValue("id");
                String beanClassName = element.attributeValue("class");
                BeanDefinition beanDefinition = new BeanDefinition(beanID,
beanClassName);
                //将Bean的定义存放到beanDefinitions 
                beanDefinitions.add(beanDefinition);
            }
        } 
    }
    //利用反射创建Bean实例，并存储在singletons中
    private void instanceBeans() {
        for (BeanDefinition beanDefinition : beanDefinitions) {
            try {
                singletons.put(beanDefinition.getId(),
Class.forName(beanDefinition.getClassName()).newInstance());
            } 
        } 
    }
    //这是对外的一个方法，让外部程序从容器中获取Bean实例，会逐步演化成核心方法
    public Object getBean(String beanName) {
        return singletons.get(beanName);
    }
}
```

由上面这一段代码可以看出，ClassPathXmlApplicationContext定义了唯一的构造函数，构造函数里会做两件事：一是提供一个readXml()方法，通过传入的文件路径，也就是XML文件的全路径名，来获取XML内的信息，二是提供一个instanceBeans()方法，根据读取到的信息实例化Bean。接下来让我们看看，readXml和instanceBeans这两个方法分别做了什么。

首先来看readXML，这也是我们解析Bean的核心方法，因为配置在XML内的Bean信息都是文本信息，需要解析之后变成内存结构才能注入到容器中。该方法最开始创建了SAXReader对象，这个对象是dom4j包内提供的。随后，它通过传入的fileName，也就是定义的XML名字，获取根元素，也就是XML里最外层的标签。然后它循环遍历标签中的属性，通过 `element.attributeValue("id")` 和 `element.attributeValue("class")` 拿到配置信息，接着用这些配置信息构建BeanDefinition对象，然后把BeanDefinition对象加入到BeanDefinitions列表中，这个地方就保存了所有Bean的定义。

接下来，我们看看instanceBeans方法实现的功能：实例化一个Bean。因为BeanDefinitions存储的BeanDefinition的class只是一个类的全名，所以我们现在需要将这个名字转换成一个具体的类。我们可以通过Java里的反射机制，也就是Class.forName将一个类的名字转化成一个实际存在的类，转成这个类之后，我们把它放到singletons这个Map里，构建 ID 与实际类的映射关系。

到这里，我们就把XML文件中的Bean信息注入到了容器中。你可能会问，我到现在都没看到BeanFactory呀，是不是还没实现完？

其实不是的，目前的ClassPathXmlApplicationContext兼具了BeanFactory的功能，它通过singletons和beanDefinitions初步实现了Bean的管理，其实这也是Spring本身的做法。后面我会进一步扩展的时候，会分离这两部分功能，来剥离出一个独立的BeanFactory。

### 验证功能

现在，我们已经实现了第一个管理Bean的容器，但还要验证一下我们的功能是不是真的实现了。下面我们就编写一下测试代码。在com.minis目录下，新增test包。你可以看一下相关的测试代码。

```java
public interface AService {
    void sayHello(); 
}
```

这里，我们定义了一个sayHello接口，该接口的实现是在控制台打印出“a service 1 say hello”这句话。

```java
public class AServiceImpl implements AService {
    public void sayHello() {
        System.out.println("a service 1 say hello");
    } 
} 
```

我们将XML文件命名为beans.xml，注入AServiceImpl类，起个别名，为aservice。

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<beans>
    <bean id = "aservice" class = "com.minis.test.AServiceImpl"></bean>
</beans> 
```

除了测试代码，我们还需要启动类，定义main函数。

```java
public class Test1 {
    public static void main(String[] args) {
        ClassPathXmlApplicationContext ctx = new
ClassPathXmlApplicationContext("beans.xml");
        AService aService = (AService)ctx.getBean("aservice");
        aService.sayHello();
    } 
} 
```

在启动函数中可以看到，我们构建了ClassPathXmlApplicationContext，传入文件名为“beans.xml”，也就是我们在测试代码中定义的XML文件名。随后我们通过getBean方法，获取注入到singletons里的这个类AService。aService在这儿是AService接口类型，其底层实现是AServiceImpl，这样再调用AServiceImpl类中的sayHello方法，就可以在控制台打印出“a service 1 say hello”这一句话。

到这里，我们已经成功地构造了一个最简单的程序：**最原始的IoC容器**。在这个过程中我们引入了BeanDefinition的概念，也实现了一个应用的上下文ClassPathXmlApplicationContext，从外部的XML文件中获取文件信息。只用了很少的步骤就实现了IoC容器对Bean的管理，后续就不再需要我们手动地初始化这些Java对象了。

## 解耦ClassPathXmlApplicationContext

但是我们也可以看到，这时的 ClassPathXmlApplicationContext 承担了太多的功能，这并不符合我们常说的对象单一功能的原则。因此，我们需要做的优化扩展工作也就呼之欲出了：分解这个类，主要工作就是两个部分，一是提出一个最基础的核心容器，二是把XML这些外部配置信息的访问单独剥离出去，现在我们只有XML这一种方式，但是之后还有可能配置到Web或数据库文件里，拆解出去之后也便于扩展。

为了看起来更像Spring，我们以Spring的目录结构为范本，重新构造一下我们的项目代码结构。

```java
com.minis.beans;
com.minis.context;
com.minis.core;
com.minis.test;
```

### 定义BeansException

在正式开始解耦工作之前，我们先定义属于我们自己的异常处理类：BeansException。我们来看看异常处理类该如何定义。

```java
public class BeansException extends Exception {
  public BeansException(String msg) {
    super(msg);
  }
}
```

可以看到，现在的异常处理类比较简单，它是直接调用父类（Exception）处理并抛出异常。有了这个基础的BeansException之后，后续我们可以根据实际情况对这个类进行拓展。

### 定义 BeanFactory

首先要拆出一个基础的容器来，刚才我们反复提到了 BeanFactory 这个词，现在我们正式引入BeanFactory这个接口，先让这个接口拥有两个特性：一是获取一个Bean（getBean），二是注册一个BeanDefinition（registerBeanDefinition）。你可以看一下它们的定义。

```java
public interface BeanFactory {
    Object getBean(String beanName) throws BeansException;
    void registerBeanDefinition(BeanDefinition beanDefinition);
}
```

### 定义Resource

刚刚我们将BeanFactory的概念进行了抽象定义。接下来我们要定义Resource这个概念，我们把外部的配置信息都当成Resource（资源）来进行抽象，你可以看下相关接口。

```java
public interface Resource extends Iterator<Object> {
}
```

### 定义ClassPathXmlResource

目前我们的数据来源比较单一，读取的都是XML文件配置，但是有了Resource这个接口后面我们就可以扩展，从数据库还有Web网络上面拿信息。现在有BeanFactory了，有Resource接口了，拆解这两部分的接口也都有了。接下来就可以来实现了。

现在我们读取并解析XML文件配置是在ClassPathXmlApplicationContext类中完成的，所以我们下一步的解耦工作就是定义ClassPathXmlResource，将解析XML的工作交给它完成。

```java
public class ClassPathXmlResource implements Resource{
    Document document;
    Element rootElement;
    Iterator<Element> elementIterator;
    public ClassPathXmlResource(String fileName) {
        SAXReader saxReader = new SAXReader();
        URL xmlPath = this.getClass().getClassLoader().getResource(fileName);
        //将配置文件装载进来，生成一个迭代器，可以用于遍历
        try {
            this.document = saxReader.read(xmlPath);
            this.rootElement = document.getRootElement();
            this.elementIterator = this.rootElement.elementIterator();
        } 
    }
    public boolean hasNext() {
        return this.elementIterator.hasNext();
    }
    public Object next() {
        return this.elementIterator.next();
    }
}
```

操作XML文件格式都是dom4j帮我们做的。

> 注：dom4j这个外部jar包方便我们读取并解析XML文件内容，将XML的标签以及参数转换成Java的对象。当然我们也可以自行写代码来解析文件，但是为了简化代码，避免重复造轮子，这里我们选择直接引用第三方包。

### XmlBeanDefinitionReader

现在我们已经解析好了XML文件，但解析好的XML如何转换成我们需要的BeanDefinition呢？这时XmlBeanDefinitionReader就派上用场了。

```java
public class XmlBeanDefinitionReader {
    BeanFactory beanFactory;
    public XmlBeanDefinitionReader(BeanFactory beanFactory) {
        this.beanFactory = beanFactory;
    }
    public void loadBeanDefinitions(Resource resource) {
        while (resource.hasNext()) {
            Element element = (Element) resource.next();
            String beanID = element.attributeValue("id");
            String beanClassName = element.attributeValue("class");
            BeanDefinition beanDefinition = new BeanDefinition(beanID, beanClassName);
            this.beanFactory.registerBeanDefinition(beanDefinition);
        }
    }
}
```

可以看到，在XmlBeanDefinitionReader中，有一个loadBeanDefinitions方法会把解析的XML内容转换成BeanDefinition，并加载到BeanFactory中。

### BeanFactory功能扩展

首先，定义一个简单的BeanFactory实现类SimpleBeanFactory。

```java
public class SimpleBeanFactory implements BeanFactory{
    private List<BeanDefinition> beanDefinitions = new ArrayList<>();
    private List<String> beanNames = new ArrayList<>();
    private Map<String, Object> singletons = new HashMap<>();
    public SimpleBeanFactory() {
    }

    //getBean，容器的核心方法
    public Object getBean(String beanName) throws BeansException {
        //先尝试直接拿Bean实例
        Object singleton = singletons.get(beanName);
        //如果此时还没有这个Bean的实例，则获取它的定义来创建实例
        if (singleton == null) {
            int i = beanNames.indexOf(beanName);
            if (i == -1) {
                throw new BeansException();
            }
            else {
                //获取Bean的定义
                BeanDefinition beanDefinition = beanDefinitions.get(i);
                try {
                    singleton = Class.forName(beanDefinition.getClassName()).newInstance();
                } 
                //注册Bean实例
                singletons.put(beanDefinition.getId(), singleton);
            }
        }
        return singleton;
    }

    public void registerBeanDefinition(BeanDefinition beanDefinition) {
        this.beanDefinitions.add(beanDefinition);
        this.beanNames.add(beanDefinition.getId());
    }
}
```

由SimpleBeanFactory的实现不难看出，这就是把ClassPathXmlApplicationContext中有关BeanDefinition实例化以及加载到内存中的相关内容提取出来了。提取完之后ClassPathXmlApplicationContext就是一个“空壳子”了，一部分交给了BeanFactory，一部分又交给了Resource和Reader。这时候它又该如何发挥“集成者”的功能呢？我们看看它现在是什么样子的。

```java
public class ClassPathXmlApplicationContext implements BeanFactory{
    BeanFactory beanFactory;
    //context负责整合容器的启动过程，读外部配置，解析Bean定义，创建BeanFactory
    public ClassPathXmlApplicationContext(String fileName) {
        Resource resource = new ClassPathXmlResource(fileName);
        BeanFactory beanFactory = new SimpleBeanFactory();
        XmlBeanDefinitionReader reader = new XmlBeanDefinitionReader(beanFactory);
        reader.loadBeanDefinitions(resource);
        this.beanFactory = beanFactory;
    }
    //context再对外提供一个getBean，底下就是调用的BeanFactory对应的方法
    public Object getBean(String beanName) throws BeansException {
        return this.beanFactory.getBean(beanName);
    }
    public void registerBeanDefinition(BeanDefinition beanDefinition) {
        this.beanFactory.registerBeanDefinition(beanDefinition);
    }
}

```

可以看到，当前的ClassPathXmlApplicationContext在实例化的过程中做了三件事。

1. 解析XML文件中的内容。
2. 加载解析的内容，构建BeanDefinition。
3. 读取BeanDefinition的配置信息，实例化Bean，然后把它注入到BeanFactory容器中。

通过上面几个步骤，我们把XML中的配置转换成Bean对象，并把它交由BeanFactory容器去管理，这些功能都实现了。虽然功能与原始版本相比没有发生任何变化，但这种**一个类只做一件事的思想**是值得我们在编写代码的过程中借鉴的。

## 小结

好了，这节课就讲到这里。通过简简单单几个类，我们就初步构建起了MiniSpring的核心部分：Bean和IoC。

![](https://static001.geekbang.org/resource/image/d1/83/d1bf4d02a949ff0aac9e07fdafa92a83.jpg?wh=3188x1967)

可以看到，通过这节课的构建，我们在业务程序中不需要再手动new一个业务类，只要把它交由框架容器去管理就可以获取我们所需的对象。另外还支持了Resource和BeanFactory，用Resource定义Bean的数据来源，让BeanFactory负责Bean的容器化管理。通过功能解耦，容器的结构会更加清晰明了，我们阅读起来也更加方便。当然最重要的是，这可以方便我们今后对容器进行扩展，适配更多的场景。

以前看似高深的Spring核心概念之一的IoC，就这样被我们拆解成了最简单的概念。它虽然原始，但已经具备了基本的功能，是一颗可以生长发育的种子。我们后面把其他功能一步步添加上去，这个可用的小种子就能发育成一棵大树。

完整源代码参见 [https://github.com/YaleGuo/minis](https://github.com/YaleGuo/minis)

## 课后题

学完这节课，我也给你留一道思考题。IoC的字面含义是“控制反转”，那么它究竟“反转”了什么？又是怎么体现在代码中的？欢迎你在留言区与我交流讨论，也欢迎你把这节课分享给需要的朋友。我们下节课见！
<div><strong>精选留言（15）</strong></div><ul>
<li><span>6点无痛早起学习的和尚</span> 👍（37） 💬（2）<p>内容讲的很清晰，点赞。
这里有几个建议：
1. 每次代码设计之前，能否通过一个 UML 类图来表示，通过类图感觉更容易懂整个类与类之前的关系
2. 发现课程的内容还是有点偏向 Spring 那种感觉，就是有点类似：啊，Spring 是这样拆分几个类功能，那我们就这样拆分，这个方式感觉还是有点死板
感觉应该是：从一个设计者角度来讲，这样拆分更灵活，扩展性更强，叭叭叭等等，这样才能把读者带入进入课程，产生共鸣。

个人想法，欢迎交流，不知道是不是就我自己有这样感受，还是其他....</p>2023-03-13</li><br/><li><span>姐姐</span> 👍（20） 💬（4）<p>从最初的简单ApplicationContext拆解成后面的复杂ApplicationContext，我理解起来还是有困难的，努力理解如下，大神勿喷：1 readxml方法从资源文件读取内容并存入beanDefinitions，这件事情有两个地方不确定，资源的来源不同、资源的格式不同，抽象的Resource的接口，它的不同子类从不同的来源读取，但是最终都是以Resource接口的形式提供给外部访问的，这样解决了第一个不确定来源的问题；但是resource接口中被迭代的object又是根据不同格式不同而不同的，element只是xml格式的，所以又定义了BeanDefinitionReader接口，它的不同子类可以读取不同格式的资源来形成beanDefinition 。 2 . instanceBeans方法取消了 。  3. getBean方法功能增强了，不仅是获得bean，对于未创建的bean还要创建bean  4 新的applicationContext负责组装，可以根据它的名字来体现它的组装功能，例如ClassPathXmlApplicationContext  它组装的Resource的实现类是ClassPathXmlResource  ，然后因为是xml的，所以需要BeanDefinitionReader的实现类XmlBeanDefinitionReader来读取并注册进beanFactory，同时ApplicationContext也提供了getBean底层调用beanfactory的实现，提供了registerBeanDefinition  来向底层的beanFactory注册bean。5 beanFactory 提供了registerBeanDefinition和getBean接口，这样无论是applicationContext还是beanDefinitionReader都可以向它注册beanDefinition，只要向它注册了，就可以调用它的getBean方法，我一直很纠结为什么不是beanfactory调用不同的beanDefinitionReader，写完这些，好像有点理解了，这样beanfactory就很专注自己的getBean方法，别的组件要怎么注入，它都不管了。</p>2023-03-22</li><br/><li><span>adelyn</span> 👍（17） 💬（4）<p>请问会不会穿插讲一下用到的设计模式，单独学设计模式总是学不扎实，如果能讲到就太好了</p>2023-03-13</li><br/><li><span>风轻扬</span> 👍（14） 💬（1）<p>说一下自己对思考题的理解。
控制反转。
控制：java对象创建的控制权。
反转：将java对象创建的控制权从程序员手中反转到IOC容器手中。
另外，说一下学完这一讲的感受。直白点说，很激动。我看过Spring这部分的源码，当时感觉挺简单的，并没有往深处想，其实忽略了“Spring为什么要这样写“的问题，现在感觉这才是源码的核心所在，突然有一点融会贯通的感觉，感觉很好。一直知道Spring的扩展性好，今天实实在在看到了。感谢老师传道解惑</p>2023-03-15</li><br/><li><span>未聞花名</span> 👍（9） 💬（1）<p>给老师个建议，可以点一下为什么类中要放这些属性和方法，突然抽到几个新类感觉过渡有点快，这样对之后自己去设计类也能举一反三，感觉自己平时设计不太好，如果自己实现起来的话比Spring的优雅可读性要差很多。
最后附上dom4j的maven依赖，希望帮助到其他人
```java
&lt;!-- https:&#47;&#47;mvnrepository.com&#47;artifact&#47;dom4j&#47;dom4j --&gt;
        &lt;dependency&gt;
            &lt;groupId&gt;dom4j&lt;&#47;groupId&gt;
            &lt;artifactId&gt;dom4j&lt;&#47;artifactId&gt;
            &lt;version&gt;1.6.1&lt;&#47;version&gt;
        &lt;&#47;dependency&gt;
```</p>2023-03-18</li><br/><li><span>杨松</span> 👍（8） 💬（3）<p>老师这句话没理解呢：“我们用一个部件来对应 Bean 内存的映像”，文中5边型图片对应的其他4个都能理解</p>2023-03-14</li><br/><li><span>Unknown</span> 👍（7） 💬（3）<p>getClass().getClassLoader().getResource(filepath)
类加载器获取资源时 此处的filepath 需要放在resource目录里面(手动创建并标识类型为Resource root) </p>2023-03-15</li><br/><li><span>周润发</span> 👍（5） 💬（2）<p>首先很感谢老师的课程，内容值得细品。
想请教一个问题，为什么在代码中更多使用全局变量而不在方法中使用成员变量呢？有些全局变量只在某个方法会用到，有什么特别的考虑吗？</p>2023-03-15</li><br/><li><span>C.</span> 👍（4） 💬（2）<p>ioc容器5天的版本手敲的，对应章节的代码：https:&#47;&#47;github.com&#47;caozhenyuan&#47;mini-spring.git 点击分支查看对应章节的代码。帮大家跟敲不迷路。</p>2023-03-24</li><br/><li><span>马儿</span> 👍（4） 💬（1）<p>以前的spring的源码都是散的，希望能通过这个课把这些只是串联起来。希望老师讲的时候可以讲一些设计模式，把创建类所在的包也希望能够说明一下，这样的话更方便大家学习了解类的用途和作用。</p>2023-03-13</li><br/><li><span>浅行</span> 👍（3） 💬（4）<p>有两个问题想请教一下：
1. 请问SimpleBeanFactory 为什么是在getBean时才注册实例，而不是registerBeanDefinition就先注册呢？
2. 请问ClassPathXmlApplicationContext 为什么也要实现BeanFactory呢？</p>2023-03-14</li><br/><li><span>兔2🐰🍃</span> 👍（1） 💬（1）<p>感谢郭屹老师，
本节完整代码如下，需要的同学可以照着敲。
https:&#47;&#47;gitee.com&#47;rabbit2&#47;mini-spring&#47;commit&#47;1bf7247dd8568b5ce33134078efa2e4824816cf8</p>2023-04-12</li><br/><li><span>Geek_b7449f</span> 👍（1） 💬（1）<p>真的很详细！从零手敲，然后反反复复看几遍终于把我之前自学所学的散的知识串联起来，真的学有收获，比较期待能把设计模式也能给一起串进来呢。
本人是一名在校的学生，这里我将每一步步骤拆分为提交的方式，希望这样可以更适合所学在校的应届生
不洗勿喷哦~：https:&#47;&#47;github.com&#47;HHXiaoFu&#47;mini-spring</p>2023-03-27</li><br/><li><span>小马哥</span> 👍（1） 💬（1）<p>回答课后题:
1, 反转: 反转的是对Bean的控制权, 使用&quot;new&quot;的方式是由程序员在代码中主动控制; 使用IOC的方式是由容器来主动控制Bean的创建以及后面的DI属性注入;
2, 反转在代码中的体现: 因为容器框架并不知道未来业务中需要注入哪个Bean, 于是通过配置文件等方式告诉容器, 容器使用反射技术管理Bean的创建, 属性注入, 生命周期等.</p>2023-03-19</li><br/><li><span>陈小远</span> 👍（1） 💬（3）<p>Spring在Java编程中是事实的标准，这个无需多言，所以对老师的这个专栏也有比较大的兴趣。看了第一节课，也跟着动手撸了些代码，对有些疑惑的点做一简单阐述：
1、老师给的源码地址感觉应该是最终的成品的地址了，不是按照课程一节一节的区分开来，从学习跟随者的角度看，可能不太友好，无法从源码中找到项目从0到1的那种获得感；
2、针对本节中源码的讲述个人感觉还是有点跳跃了，不过本身Spring体系太过庞杂，无法面面俱到，也无法真的能从0去反推出Spring中相关类设计的原因，所以也表示理解。但有些设计意图还是希望老师能尽量多言一些，而不是因为Spring包或类那样设计的就强行往Spring身上靠，感觉有些突然。比如本节中抽象出了BeanFactory后，为什么又突然来一个SimpleBeanFactory，而ClassPathXmlApplicationContext同样也是实现自该接口，那通过SimpleBeanFactory在组合到ClassPathXmlApplicationContext中实现功能是出于什么考虑呢？ 虽然在评论区实际有看到小伙伴的讨论，大概能明白这样设计的意思。</p>2023-03-18</li><br/>
</ul>