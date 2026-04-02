上两节课中，我们学习了工厂模式，讲了工厂模式的应用场景，并带你实现了一个简单的DI容器。今天，我们再来学习另外一个比较常用的创建型设计模式，**Builder模式**，中文翻译为**建造者模式**或者**构建者模式**，也有人叫它**生成器模式**。

实际上，建造者模式的原理和代码实现非常简单，掌握起来并不难，难点在于应用场景。比如，你有没有考虑过这样几个问题：直接使用构造函数或者配合set方法就能创建对象，为什么还需要建造者模式来创建呢？建造者模式和工厂模式都可以创建对象，那它们两个的区别在哪里呢？

话不多说，带着上面两个问题，让我们开始今天的学习吧！

## 为什么需要建造者模式？

在平时的开发中，创建一个对象最常用的方式是，使用new关键字调用类的构造函数来完成。我的问题是，什么情况下这种方式就不适用了，就需要采用建造者模式来创建对象呢？你可以先思考一下，下面我通过一个例子来带你看一下。

假设有这样一道设计面试题：我们需要定义一个资源池配置类ResourcePoolConfig。这里的资源池，你可以简单理解为线程池、连接池、对象池等。在这个资源池配置类中，有以下几个成员变量，也就是可配置项。现在，请你编写代码实现这个ResourcePoolConfig类。

![](https://static001.geekbang.org/resource/image/21/59/21f970b7c0d6b5afa6aa09ca14f55059.jpg?wh=2463%2A936)

只要你稍微有点开发经验，那实现这样一个类对你来说并不是件难事。最常见、最容易想到的实现思路如下代码所示。因为maxTotal、maxIdle、minIdle不是必填变量，所以在创建ResourcePoolConfig对象的时候，我们通过往构造函数中，给这几个参数传递null值，来表示使用默认值。

```
public class ResourcePoolConfig {
  private static final int DEFAULT_MAX_TOTAL = 8;
  private static final int DEFAULT_MAX_IDLE = 8;
  private static final int DEFAULT_MIN_IDLE = 0;

  private String name;
  private int maxTotal = DEFAULT_MAX_TOTAL;
  private int maxIdle = DEFAULT_MAX_IDLE;
  private int minIdle = DEFAULT_MIN_IDLE;

  public ResourcePoolConfig(String name, Integer maxTotal, Integer maxIdle, Integer minIdle) {
    if (StringUtils.isBlank(name)) {
      throw new IllegalArgumentException("name should not be empty.");
    }
    this.name = name;

    if (maxTotal != null) {
      if (maxTotal <= 0) {
        throw new IllegalArgumentException("maxTotal should be positive.");
      }
      this.maxTotal = maxTotal;
    }

    if (maxIdle != null) {
      if (maxIdle < 0) {
        throw new IllegalArgumentException("maxIdle should not be negative.");
      }
      this.maxIdle = maxIdle;
    }

    if (minIdle != null) {
      if (minIdle < 0) {
        throw new IllegalArgumentException("minIdle should not be negative.");
      }
      this.minIdle = minIdle;
    }
  }
  //...省略getter方法...
}
```

现在，ResourcePoolConfig只有4个可配置项，对应到构造函数中，也只有4个参数，参数的个数不多。但是，如果可配置项逐渐增多，变成了8个、10个，甚至更多，那继续沿用现在的设计思路，构造函数的参数列表会变得很长，代码在可读性和易用性上都会变差。在使用构造函数的时候，我们就容易搞错各参数的顺序，传递进错误的参数值，导致非常隐蔽的bug。

```
// 参数太多，导致可读性差、参数可能传递错误
ResourcePoolConfig config = new ResourcePoolConfig("dbconnectionpool", 16, null, 8, null, false , true, 10, 20，false， true);
```

解决这个问题的办法你应该也已经想到了，那就是用set()函数来给成员变量赋值，以替代冗长的构造函数。我们直接看代码，具体如下所示。其中，配置项name是必填的，所以我们把它放到构造函数中设置，强制创建类对象的时候就要填写。其他配置项maxTotal、maxIdle、minIdle都不是必填的，所以我们通过set()函数来设置，让使用者自主选择填写或者不填写。

```
public class ResourcePoolConfig {
  private static final int DEFAULT_MAX_TOTAL = 8;
  private static final int DEFAULT_MAX_IDLE = 8;
  private static final int DEFAULT_MIN_IDLE = 0;

  private String name;
  private int maxTotal = DEFAULT_MAX_TOTAL;
  private int maxIdle = DEFAULT_MAX_IDLE;
  private int minIdle = DEFAULT_MIN_IDLE;
  
  public ResourcePoolConfig(String name) {
    if (StringUtils.isBlank(name)) {
      throw new IllegalArgumentException("name should not be empty.");
    }
    this.name = name;
  }

  public void setMaxTotal(int maxTotal) {
    if (maxTotal <= 0) {
      throw new IllegalArgumentException("maxTotal should be positive.");
    }
    this.maxTotal = maxTotal;
  }

  public void setMaxIdle(int maxIdle) {
    if (maxIdle < 0) {
      throw new IllegalArgumentException("maxIdle should not be negative.");
    }
    this.maxIdle = maxIdle;
  }

  public void setMinIdle(int minIdle) {
    if (minIdle < 0) {
      throw new IllegalArgumentException("minIdle should not be negative.");
    }
    this.minIdle = minIdle;
  }
  //...省略getter方法...
}
```

接下来，我们来看新的ResourcePoolConfig类该如何使用。我写了一个示例代码，如下所示。没有了冗长的函数调用和参数列表，代码在可读性和易用性上提高了很多。

```
// ResourcePoolConfig使用举例
ResourcePoolConfig config = new ResourcePoolConfig("dbconnectionpool");
config.setMaxTotal(16);
config.setMaxIdle(8);
```

至此，我们仍然没有用到建造者模式，通过构造函数设置必填项，通过set()方法设置可选配置项，就能实现我们的设计需求。如果我们把问题的难度再加大点，比如，还需要解决下面这三个问题，那现在的设计思路就不能满足了。

- 我们刚刚讲到，name是必填的，所以，我们把它放到构造函数中，强制创建对象的时候就设置。如果必填的配置项有很多，把这些必填配置项都放到构造函数中设置，那构造函数就又会出现参数列表很长的问题。如果我们把必填项也通过set()方法设置，那校验这些必填项是否已经填写的逻辑就无处安放了。
- 除此之外，假设配置项之间有一定的依赖关系，比如，如果用户设置了maxTotal、maxIdle、minIdle其中一个，就必须显式地设置另外两个；或者配置项之间有一定的约束条件，比如，maxIdle和minIdle要小于等于maxTotal。如果我们继续使用现在的设计思路，那这些配置项之间的依赖关系或者约束条件的校验逻辑就无处安放了。
- 如果我们希望ResourcePoolConfig类对象是不可变对象，也就是说，对象在创建好之后，就不能再修改内部的属性值。要实现这个功能，我们就不能在ResourcePoolConfig类中暴露set()方法。

为了解决这些问题，建造者模式就派上用场了。

我们可以把校验逻辑放置到Builder类中，先创建建造者，并且通过set()方法设置建造者的变量值，然后在使用build()方法真正创建对象之前，做集中的校验，校验通过之后才会创建对象。除此之外，我们把ResourcePoolConfig的构造函数改为private私有权限。这样我们就只能通过建造者来创建ResourcePoolConfig类对象。并且，ResourcePoolConfig没有提供任何set()方法，这样我们创建出来的对象就是不可变对象了。

我们用建造者模式重新实现了上面的需求，具体的代码如下所示：

```
public class ResourcePoolConfig {
  private String name;
  private int maxTotal;
  private int maxIdle;
  private int minIdle;

  private ResourcePoolConfig(Builder builder) {
    this.name = builder.name;
    this.maxTotal = builder.maxTotal;
    this.maxIdle = builder.maxIdle;
    this.minIdle = builder.minIdle;
  }
  //...省略getter方法...

  //我们将Builder类设计成了ResourcePoolConfig的内部类。
  //我们也可以将Builder类设计成独立的非内部类ResourcePoolConfigBuilder。
  public static class Builder {
    private static final int DEFAULT_MAX_TOTAL = 8;
    private static final int DEFAULT_MAX_IDLE = 8;
    private static final int DEFAULT_MIN_IDLE = 0;

    private String name;
    private int maxTotal = DEFAULT_MAX_TOTAL;
    private int maxIdle = DEFAULT_MAX_IDLE;
    private int minIdle = DEFAULT_MIN_IDLE;

    public ResourcePoolConfig build() {
      // 校验逻辑放到这里来做，包括必填项校验、依赖关系校验、约束条件校验等
      if (StringUtils.isBlank(name)) {
        throw new IllegalArgumentException("...");
      }
      if (maxIdle > maxTotal) {
        throw new IllegalArgumentException("...");
      }
      if (minIdle > maxTotal || minIdle > maxIdle) {
        throw new IllegalArgumentException("...");
      }

      return new ResourcePoolConfig(this);
    }

    public Builder setName(String name) {
      if (StringUtils.isBlank(name)) {
        throw new IllegalArgumentException("...");
      }
      this.name = name;
      return this;
    }

    public Builder setMaxTotal(int maxTotal) {
      if (maxTotal <= 0) {
        throw new IllegalArgumentException("...");
      }
      this.maxTotal = maxTotal;
      return this;
    }

    public Builder setMaxIdle(int maxIdle) {
      if (maxIdle < 0) {
        throw new IllegalArgumentException("...");
      }
      this.maxIdle = maxIdle;
      return this;
    }

    public Builder setMinIdle(int minIdle) {
      if (minIdle < 0) {
        throw new IllegalArgumentException("...");
      }
      this.minIdle = minIdle;
      return this;
    }
  }
}

// 这段代码会抛出IllegalArgumentException，因为minIdle>maxIdle
ResourcePoolConfig config = new ResourcePoolConfig.Builder()
        .setName("dbconnectionpool")
        .setMaxTotal(16)
        .setMaxIdle(10)
        .setMinIdle(12)
        .build();
```



实际上，使用建造者模式创建对象，还能避免对象存在无效状态。我再举个例子解释一下。比如我们定义了一个长方形类，如果不使用建造者模式，采用先创建后set的方式，那就会导致在第一个set之后，对象处于无效状态。具体代码如下所示：

```
Rectangle r = new Rectange(); // r is invalid
r.setWidth(2); // r is invalid
r.setHeight(3); // r is valid
```

为了避免这种无效状态的存在，我们就需要使用构造函数一次性初始化好所有的成员变量。如果构造函数参数过多，我们就需要考虑使用建造者模式，先设置建造者的变量，然后再一次性地创建对象，让对象一直处于有效状态。

实际上，如果我们并不是很关心对象是否有短暂的无效状态，也不是太在意对象是否是可变的。比如，对象只是用来映射数据库读出来的数据，那我们直接暴露set()方法来设置类的成员变量值是完全没问题的。而且，使用建造者模式来构建对象，代码实际上是有点重复的，ResourcePoolConfig类中的成员变量，要在Builder类中重新再定义一遍。

## 与工厂模式有何区别？

从上面的讲解中，我们可以看出，建造者模式是让建造者类来负责对象的创建工作。上一节课中讲到的工厂模式，是由工厂类来负责对象创建的工作。那它们之间有什么区别呢？

实际上，工厂模式是用来创建不同但是相关类型的对象（继承同一父类或者接口的一组子类），由给定的参数来决定创建哪种类型的对象。建造者模式是用来创建一种类型的复杂对象，通过设置不同的可选参数，“定制化”地创建不同的对象。

网上有一个经典的例子很好地解释了两者的区别。

顾客走进一家餐馆点餐，我们利用工厂模式，根据用户不同的选择，来制作不同的食物，比如披萨、汉堡、沙拉。对于披萨来说，用户又有各种配料可以定制，比如奶酪、西红柿、起司，我们通过建造者模式根据用户选择的不同配料来制作披萨。

实际上，我们也不要太学院派，非得把工厂模式、建造者模式分得那么清楚，我们需要知道的是，每个模式为什么这么设计，能解决什么问题。**只有了解了这些最本质的东西，我们才能不生搬硬套，才能灵活应用，甚至可以混用各种模式创造出新的模式，来解决特定场景的问题。**

## 重点回顾

好了，今天的内容到此就讲完了。我们一块来总结回顾一下，你需要重点掌握的内容。

建造者模式的原理和实现比较简单，重点是掌握应用场景，避免过度使用。

如果一个类中有很多属性，为了避免构造函数的参数列表过长，影响代码的可读性和易用性，我们可以通过构造函数配合set()方法来解决。但是，如果存在下面情况中的任意一种，我们就要考虑使用建造者模式了。

- 我们把类的必填属性放到构造函数中，强制创建对象的时候就设置。如果必填的属性有很多，把这些必填属性都放到构造函数中设置，那构造函数就又会出现参数列表很长的问题。如果我们把必填属性通过set()方法设置，那校验这些必填属性是否已经填写的逻辑就无处安放了。
- 如果类的属性之间有一定的依赖关系或者约束条件，我们继续使用构造函数配合set()方法的设计思路，那这些依赖关系或约束条件的校验逻辑就无处安放了。
- 如果我们希望创建不可变对象，也就是说，对象在创建好之后，就不能再修改内部的属性值，要实现这个功能，我们就不能在类中暴露set()方法。构造函数配合set()方法来设置属性值的方式就不适用了。

除此之外，在今天的讲解中，我们还对比了工厂模式和建造者模式的区别。工厂模式是用来创建不同但是相关类型的对象（继承同一父类或者接口的一组子类），由给定的参数来决定创建哪种类型的对象。建造者模式是用来创建一种类型的复杂对象，可以通过设置不同的可选参数，“定制化”地创建不同的对象。

## 课堂讨论

在下面的ConstructorArg类中，当isRef为true的时候，arg表示String类型的refBeanId，type不需要设置；当isRef为false的时候，arg、type都需要设置。请根据这个需求，完善ConstructorArg类。

```
 public class ConstructorArg {
    private boolean isRef;
    private Class type;
    private Object arg;
    // TODO: 待完善...
  }
```

欢迎留言和我分享你的想法，如果有收获，你也可以把这篇文章分享给你的朋友。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>zhengyu.nie</span> 👍（47） 💬（2）<p>依赖关系（Dependencies）、合法校验（Preconditions）、不可变（Immutable）。
争哥这几个描述很精准！
借着思路延伸一下的话，很多库和设计都是以上这些理念的。
比如com.google.guava的校验、不可变集合，多线程设计模式中的Immutable模式、保护性拷贝（其中又可以分深浅api），java.lang.String的不可变设计。还有关于类状态的控制，还有Effective Java中类创建这一章中对于构造方法、set方法、Builder构建、枚举、静态工厂方法构建等对比，像Guava Lists、Sets、Maps、ImmutableList这种创建方式现在也很主流了</p>2020-04-28</li><br/><li><span>苏暮沉觞</span> 👍（4） 💬（1）<p>       小争哥，我在学习建造者模式的时候，发现传统的构建者模式写法跟文中的不太一样，传统的构建者模式存在监工，抽象Builder，具体Builder，产品类。可以通过不同的具体Builder，创建对应的产品类。而你在文章中的设计模式的写法，在某些文章中，被称为变种的构造者模式。
       我比较了一下两种方式，感觉传统的构建者模式需要提前定义好你要生产的产品对应的属性，而文中这种方法则是在构建产品时，自己动态的设置产品属性，虽然说这种方法更加灵活，但是侵入性更高。
      那么考虑到以后需求变更，是不是应该是用传统的构建者模式呢？不然要是资源池对应的参数变了，就要修改业务代码中的参数了。</p>2020-05-21</li><br/><li><span>是非～成败～</span> 👍（1） 💬（2）<p>&#47;**
 * 需求：
 * 当 isRef 为 true 的时候，arg 表示 String 类型的 refBeanId，type 不需要设置；
 * 当 isRef 为 false 的时候，arg、type 都需要设置。
 * 请根据这个需求，完善 ConstructorArg 类。
 *&#47;
public class ConstructorArg_02 {
    private boolean isRef;
    private Class type;
    private Object arg;

    private ConstructorArg_02(Builder builder) {
        this.isRef = builder.isRef;
        this.type = builder.type;
        this.arg = builder.arg;
    }

    public static class Builder {
        private boolean isRef;
        private Class type;
        private Object arg;

        &#47;&#47; 后面两个参数依赖isRef，所以isRef设置成必选参数
        public Builder(boolean isRef) {
            this.isRef = isRef;
        }

        public ConstructorArg_02 build() {
            return new ConstructorArg_02(this);
        }

        public Builder setType(Class type) {
            this.type = type;
            return this;
        }

        public Builder setArg(Object arg) {
            &#47;&#47; isRef为true, arg不是String类型就报错
            if (isRef &amp;&amp; arg.getClass() != String.class) {
                throw new RuntimeException(&quot;参数错误&quot;);
            }
            this.arg = arg;
            return this;
        }
    }
}
咱也不知道写的好不好，希望争哥看到了检视指导一二</p>2020-11-16</li><br/><li><span>悠南</span> 👍（1） 💬（3）<p>你这建造者模式代码，看不懂，构造方法私有了，怎么来的Builder 方法</p>2020-06-22</li><br/><li><span>Morse</span> 👍（0） 💬（5）<p>为什么定义了一个长方形类，如果不使用建造者模式，采用先创建后 set 的方式，那就会导致在第一个 set 之后，对象处于无效状态？求大佬解答</p>2020-08-03</li><br/><li><span>Darren</span> 👍（128） 💬（4）<p>简单理解就是：工厂模式是根据不同的条件生成不同Class的对象，构建者模式是根据不同参数生成一个class的不同对象。</p>2020-04-10</li><br/><li><span>webmin</span> 👍（114） 💬（13）<p>public class ConstructorArg {
    private boolean isRef;
    private Class type;
    private Object arg;

    public boolean isRef() {
        return isRef;
    }

    public Class getType() {
        return type;
    }

    public Object getArg() {
        return arg;
    }

    private ConstructorArg(Builder builder) {
        this.isRef = builder.isRef;
        this.type = builder.type;
        this.arg = builder.arg;
    }

    public static class Builder {
        private boolean isRef;
        private Class type;
        private Object arg;

        public ConstructorArg build() {
            if(isRef &amp;&amp; type != null) {
                throw new IllegalArgumentException(&quot;...&quot;);
            }

            if (!isRef &amp;&amp; type == null) {
                throw new IllegalArgumentException(&quot;...&quot;);
            }

            if (this.isRef &amp;&amp; (arg != null &amp;&amp; arg.getClass() != String.class)) {
                throw new IllegalArgumentException(&quot;...&quot;);
            }

            if (!this.isRef &amp;&amp; arg == null) {
                throw new IllegalArgumentException(&quot;...&quot;);
            }

            return new ConstructorArg(this);
        }

        public Builder setRef(boolean ref) {
            if(ref &amp;&amp; this.type != null) {
                throw new IllegalArgumentException(&quot;...&quot;);
            }
            this.isRef = ref;
            return this;
        }

        public Builder setType(Class type) {
            if (this.isRef || type == null) {
                throw new IllegalArgumentException(&quot;...&quot;);
            }
            this.type = type;
            return this;
        }

        public Builder setArg(Object arg) {
            if (this.isRef &amp;&amp; (arg != null &amp;&amp; arg.getClass() != String.class)) {
                throw new IllegalArgumentException(&quot;...&quot;);
            }

            if (!this.isRef &amp;&amp; arg == null) {
                throw new IllegalArgumentException(&quot;...&quot;);
            }
            this.arg = arg;
            return this;
        }
    }
}</p>2020-02-17</li><br/><li><span>相逢是缘</span> 👍（55） 💬（4）<p>打卡
一、使用场景：
1）类的构造函数必填属性很多，通过set设置，没有办法校验必填属性
2）如果类的属性之间有一定的依赖关系，构造函数配合set方式，无法进行依赖关系和约束条件校验
3）需要创建不可变对象，不能暴露set方法。
（前提是需要传递很多的属性，如果属性很少，可以不需要建造者模式）
二、实现方式：
把构造函数定义为private，定义public static class Builder 内部类，通过Builder 类的set方法设置属性，调用build方法创建对象。

三、和工厂模式的区别：
1）工厂模式：创建不同的同一类型对象（集成同一个父类或是接口的一组子类），由给定的参数来创建哪种类型的对象；
2）建造者模式：创建一种类型的复杂对象，通过很多可设置参数，“定制化”的创建对象</p>2020-02-17</li><br/><li><span>javaadu</span> 👍（52） 💬（0）<p>课堂讨论题：

&#47;**
 * 在下面的 ConstructorArg 类中，
 * 当 isRef 为 true 的时候，arg 表示 String 类型的 refBeanId，type 不需要设置；
 * 当 isRef 为 false 的时候，arg、type 都需要设置
 *
 * @author javaadu
 *&#47;
public class ConstructorArg {
    private boolean isRef;
    private Class type;
    private Object arg;

    private ConstructorArg(Builder builder) {
        this.isRef = builder.isRef;
        this.type = builder.type;
        this.arg = builder.arg;
    }

    public static class Builder {
        private boolean isRef;
        private Class type;
        private Object arg;

        public ConstructorArg build() {
            if (arg == null) {
                throw new IllegalArgumentException(&quot;arg必须设置&quot;);
            }
            if (isRef) {
                if (!(arg instanceof String)) {
                    throw new IllegalArgumentException(&quot;arg必须为String类型的对象&quot;);
                }
            } else {
                if (type == null) {
                    throw new IllegalArgumentException(&quot;arg必须设置&quot;);
                }
            }

            return new ConstructorArg(this)
        }

        public Builder setRef(boolean ref) {
            isRef = ref;
            return this;
        }

        public Builder setArg(Object arg) {
            this.arg = arg;
            return this;
        }

        public Builder setType(Class type) {
            this.type = type;
            return this;
        }
    }
}</p>2020-02-17</li><br/><li><span>小文同学</span> 👍（18） 💬（0）<p>说说自己读了 Builder 模式的最大感悟：
1、Builder 模式可以保证对象的状态。
2、Builder 模式可以把对象的构造鉴定逻辑写在Builder类中，保证了类的简洁。

平时普普通通地使用 lombok 生成 Builder，应该更加深入地了解一下。</p>2020-03-07</li><br/><li><span>黄林晴</span> 👍（12） 💬（2）<p>打卡~
最近半年用的最多的就是Builder模式了</p>2020-02-17</li><br/><li><span>王涛</span> 👍（9） 💬（0）<p>最近，在学习本专栏的过程中。
逐渐体会到“知其然，更知其所以然”的感觉
</p>2020-02-17</li><br/><li><span>业余爱好者</span> 👍（7） 💬（0）<p>创建型模式的作用在于，将对象“获取”（没有用创建）的过程独立出来，形成单独的类。这在获取复杂或者有特殊需求的对象时可以更好的体现单一职责原则---我负责拿到（ready to use）对象,你只管使用就可以了。你不需要关系我是不是懒加载之类的问题。

一个可以使用的对象，它的意义绝不单单是new一下就完事了，还有一系列其他的考量。
如果要求一个类只有一个全局唯一的对象，如基本不变化的配置信息类，这就是单例模式。如何控制只有一个对象，当然是拦截掉所有其他创建对象的路径，只留下一条路---使用类唯一的静态方法获取对象。这就是为什么，单例一般都要求将构造方法私有化。（spring的单例bean其实只是一种单例的约定，你完全可以自己new一个。）单例模式还设计到懒加载的问题，不过由于只有一个访问入口，处理起来比较简单。

工厂模式就比较纯粹了，工厂的意义就是在于获取一个对象。简单工工厂类如果是无状态的话，完全可以使用静态方法的形式，没有必要每创建一个对象都先弄个完全一样的工厂出来。
当需要有根据不同情况创建不同子类的时候，如果分支不多的话，完全可以使用if else,不过也可以考虑使用多态。不同的情况创建不同的工厂，将相应子类各异的创建逻辑分开。这就是工厂方法。
而如果是创建一个产品系列的话，就使用抽象工厂模式。

建造者用于处理创建参数过多的情形，同时可以校验参数，避免对象创建过程中的不一致状态。

原型用于快速拷贝一个对象。</p>2020-08-02</li><br/><li><span>1024</span> 👍（7） 💬（2）<p>做了一下课后题，和其他同学的答案比较了下，还是有些疑惑，疑惑在属性的判断逻辑是放在Builder的setAttr()内还是放在build()内
个人认为：
setAttr()放属性自己的逻辑判断，比如不要为null，不能大于或小于某个常量
build()方法放多个属性间的校验逻辑，因为调用builde()时，属性都set完成，这时候才有机会通过builde()来全局考虑所有属性的逻辑。
基于此，我的答案如下
public class ConstructorArg {
    private boolean isRef;
    private Class type;
    private Object arg;

    private ConstructorArg(Builder builder) {
        this.isRef = builder.isRef;
        this.type = builder.type;
        this.arg = builder.arg;
    }
    &#47;&#47; 省略getter方法

    public static class Builder {
        private Object arg;
        private Class type;
        private boolean isRef;

        private ConstructorArg build() {
            if (isRef) {
                if (!(arg instanceof String)) {
                    &#47;&#47;这里refBeanId是ConstructorArg吗？只是判断了下arg类型是否为String
                    throw new IllegalArgumentException(&quot;当 isRef 为 true 的时候，arg 表示 String 类型refBeanId&quot;);
                }
                if (type != null) {
                    throw new IllegalArgumentException(&quot;当 isRef 为 true 的时候，type 不需要设置&quot;);
                }
            }
            if (!isRef) {
                if (arg == null || type == null) {
                    throw new IllegalArgumentException(&quot;当 isRef 为 false 的时候，arg、type 都需要设置&quot;);
                }
            }
            return new ConstructorArg(this);
        }

        public Builder setRef(boolean ref) {
            isRef = ref;
            return this;
        }

        public Builder setArg(Object arg) {
            this.arg = arg;
            return this;
        }

        public Builder setType(Class type) {
            this.type = type;
            return this;
        }
    }
public static void main(String[] args) {
        ConstructorArg.Builder builder = new ConstructorArg.Builder();
&#47;&#47;        java.lang.IllegalArgumentException: 当 isRef 为 true 的时候，arg 表示 String 类型refBeanId
        builder.setRef(true).setArg(1).build();
    }</p>2020-03-07</li><br/><li><span>啦啦啦</span> 👍（7） 💬（0）<p>用php实现了一个
&lt;?php
class ResourcePoolConfig{
    private $maxTotal;
    private $maxIdle;
    private $minIdle;
    public function __construct(build $build)
    {
        $this-&gt;maxTotal = $build-&gt;maxTotal;
        $this-&gt;maxIdle = $build-&gt;maxIdle;
        $this-&gt;minIdle = $build-&gt;minIdle;
        echo &#39;maxTotal&#39;.$this-&gt;maxTotal;
        echo &#39;&lt;br &#47;&gt;&#39;;
        echo &#39;maxIdle&#39;.$this-&gt;maxIdle;
        echo &#39;&lt;br &#47;&gt;&#39;;
        echo &#39;minIdle&#39;.$this-&gt;minIdle;
        echo &#39;&lt;br &#47;&gt;&#39;;
    }
}

class Builder{
    public $maxTotal;
    public $maxIdle;
    public $minIdle;
    public function noodleValidate(){
        if($this-&gt;maxIdle&gt;$this-&gt;maxTotal){
            throw new Exception(&quot;maxIdle抛出异常&quot;);
        }
        if($this-&gt;minIdle&gt;$this-&gt;maxTotal){
            throw new Exception(&quot;minIdle抛出异常&quot;);
        }
    }

    public function setMaxTotal($value=20){
        $this-&gt;maxTotal = $value;
        return $this;
    }

    public function setMaxIdle($value=10){
        $this-&gt;maxIdle = $value;
        return $this;
    }

    public function setMinIdle($value=10){
        $this-&gt;minIdle = $value;
        return $this;
    }
}

$b = new Builder();
$b-&gt;setMaxTotal(5)-&gt;setMaxIdle()-&gt;setMinIdle()-&gt;noodleValidate();
new ResourcePoolConfig($b);</p>2020-02-17</li><br/>
</ul>