你好，我是蔡元楠，极客时间《大规模数据处理实战》专栏的作者。今天我想和你分享的主题是：metaclass，是潘多拉魔盒还是阿拉丁神灯？

Python中有很多黑魔法，比如今天我将分享的metaclass。我认识许多人，对于这些语言特性有两种极端的观点。

- 一种人觉得这些语言特性太牛逼了，简直是无所不能的阿拉丁神灯，必须找机会用上才能显示自己的Python实力。
- 另一种观点则是认为这些语言特性太危险了，会蛊惑人心去滥用，一旦打开就会释放“恶魔”，让整个代码库变得难以维护。

其实这两种看法都有道理，却又都浅尝辄止。今天，我就带你来看看，metaclass到底是潘多拉魔盒还是阿拉丁神灯？

市面上的很多中文书，都把metaclass译为“元类”。我一直认为这个翻译很糟糕，所以也不想在这里称metaclass为元类。因为如果仅从字面理解，“元”是“本源”“基本”的意思，“元类”会让人以为是“基本类”。难道Python的metaclass，指的是Python 2的Object吗？这就让人一头雾水了。

事实上，meta-class的meta这个词根，起源于希腊语词汇meta，包含下面两种意思：

1. “Beyond”，例如技术词汇metadata，意思是描述数据的超越数据；
2. “Change”，例如技术词汇metamorphosis，意思是改变的形态。

metaclass，一如其名，实际上同时包含了“超越类”和“变形类”的含义，完全不是“基本类”的意思。所以，要深入理解metaclass，我们就要围绕它的**超越变形**特性。接下来，我将为你展开metaclass的超越变形能力，讲清楚metaclass究竟有什么用？怎么应用？Python语言设计层面是如何实现metaclass的 ？以及使用metaclass的风险。

## metaclass的超越变形特性有什么用？

[YAML](https://pyyaml.org/wiki/PyYAMLDocumentation)是一个家喻户晓的Python工具，可以方便地序列化/逆序列化结构数据。YAMLObject的一个**超越变形能力**，就是它的任意子类支持序列化和反序列化（serialization &amp; deserialization）。比如说下面这段代码：

```
class Monster(yaml.YAMLObject):
  yaml_tag = u'!Monster'
  def __init__(self, name, hp, ac, attacks):
    self.name = name
    self.hp = hp
    self.ac = ac
    self.attacks = attacks
  def __repr__(self):
    return "%s(name=%r, hp=%r, ac=%r, attacks=%r)" % (
       self.__class__.__name__, self.name, self.hp, self.ac,      
       self.attacks)

yaml.load("""
--- !Monster
name: Cave spider
hp: [2,6]    # 2d6
ac: 16
attacks: [BITE, HURT]
""")

Monster(name='Cave spider', hp=[2, 6], ac=16, attacks=['BITE', 'HURT'])

print yaml.dump(Monster(
    name='Cave lizard', hp=[3,6], ac=16, attacks=['BITE','HURT']))

# 输出
!Monster
ac: 16
attacks: [BITE, HURT]
hp: [3, 6]
name: Cave lizard
```

这里YAMLObject的特异功能体现在哪里呢？

你看，调用统一的yaml.load()，就能把任意一个yaml序列载入成一个Python Object；而调用统一的yaml.dump()，就能把一个YAMLObject子类序列化。对于load()和dump()的使用者来说，他们完全不需要提前知道任何类型信息，这让超动态配置编程成了可能。在我的实战经验中，许多大型项目都需要应用这种超动态配置的理念。

比方说，在一个智能语音助手的大型项目中，我们有1万个语音对话场景，每一个场景都是不同团队开发的。作为智能语音助手的核心团队成员，我不可能去了解每个子场景的实现细节。

在动态配置实验不同场景时，经常是今天我要实验场景A和B的配置，明天实验B和C的配置，光配置文件就有几万行量级，工作量真是不小。而应用这样的动态配置理念，我就可以让引擎根据我的文本配置文件，动态加载所需要的Python类。

对于YAML的使用者，这一点也很方便，你只要简单地继承yaml.YAMLObject，就能让你的Python Object具有序列化和逆序列化能力。是不是相比普通Python类，有一点“变态”，有一点“超越”？

事实上，我在Google见过很多Python开发者，发现能深入解释YAML这种设计模式优点的人，大概只有10%。而能知道类似YAML的这种动态序列化/逆序列化功能正是用metaclass实现的人，更是凤毛麟角，可能只有1%了。

## metaclass的超越变形特性怎么用？

刚刚提到，估计只有1%的Python开发者，知道YAML的动态序列化/逆序列化是由metaclass实现的。如果你追问，YAML怎样用metaclass实现动态序列化/逆序列化功能，可能只有0.1%的人能说得出一二了。

因为篇幅原因，我们这里只看YAMLObject的load()功能。简单来说，我们需要一个全局的注册器，让YAML知道，序列化文本中的 `!Monster` 需要载入成 Monster这个Python类型。

一个很自然的想法就是，那我们建立一个全局变量叫 registry，把所有需要逆序列化的YAMLObject，都注册进去。比如下面这样：

```
registry = {}

def add_constructor(target_class):
    registry[target_class.yaml_tag] = target_class
```

然后，在Monster 类定义后面加上下面这行代码：

```
add_constructor(Monster)
```

但这样的缺点也很明显，对于YAML的使用者来说，每一个YAML的可逆序列化的类Foo定义后，都需要加上一句话，`add_constructor(Foo)`。这无疑给开发者增加了麻烦，也更容易出错，毕竟开发者很容易忘了这一点。

那么，更优的实现方式是什么样呢？如果你看过YAML的源码，就会发现，正是metaclass解决了这个问题。

```
# Python 2/3 相同部分
class YAMLObjectMetaclass(type):
  def __init__(cls, name, bases, kwds):
    super(YAMLObjectMetaclass, cls).__init__(name, bases, kwds)
    if 'yaml_tag' in kwds and kwds['yaml_tag'] is not None:
      cls.yaml_loader.add_constructor(cls.yaml_tag, cls.from_yaml)
  # 省略其余定义

# Python 3
class YAMLObject(metaclass=YAMLObjectMetaclass):
  yaml_loader = Loader
  # 省略其余定义

# Python 2
class YAMLObject(object):
  __metaclass__ = YAMLObjectMetaclass
  yaml_loader = Loader
  # 省略其余定义
```

你可以发现，YAMLObject把metaclass都声明成了YAMLObjectMetaclass，尽管声明方式在Python 2 和3中略有不同。在YAMLObjectMetaclass中， 下面这行代码就是魔法发生的地方：

```
cls.yaml_loader.add_constructor(cls.yaml_tag, cls.from_yaml) 
```

YAML应用metaclass，拦截了所有YAMLObject子类的定义。也就说说，在你定义任何YAMLObject子类时，Python会强行插入运行下面这段代码，把我们之前想要的`add_constructor(Foo)`给自动加上。

```
cls.yaml_loader.add_constructor(cls.yaml_tag, cls.from_yaml)
```

所以YAML的使用者，无需自己去手写`add_constructor(Foo)` 。怎么样，是不是其实并不复杂？

看到这里，我们已经掌握了metaclass的使用方法，超越了世界上99.9%的Python开发者。更进一步，如果你能够深入理解，Python的语言设计层面是怎样实现metaclass的，你就是世间罕见的“Python大师”了。

## **Python底层语言设计层面是如何实现metaclass的？**

刚才我们提到，metaclass能够拦截Python类的定义。它是怎么做到的？

要理解metaclass的底层原理，你需要深入理解Python类型模型。下面，我将分三点来说明。

### 第一，所有的Python的用户定义类，都是type这个类的实例。

可能会让你惊讶，事实上，类本身不过是一个名为 type 类的实例。在Python的类型世界里，type这个类就是造物的上帝。这可以在代码中验证：

```
# Python 3和Python 2类似
class MyClass:
  pass

instance = MyClass()

type(instance)
# 输出
<class '__main__.C'>

type(MyClass)
# 输出
<class 'type'>
```

你可以看到，instance是MyClass的实例，而MyClass不过是“上帝”type的实例。

### 第二，用户自定义类，只不过是type类的`__call__`运算符重载。

当我们定义一个类的语句结束时，真正发生的情况，是Python调用type的`__call__`运算符。简单来说，当你定义一个类时，写成下面这样时：

```
class MyClass:
  data = 1
```

Python真正执行的是下面这段代码：

```
class = type(classname, superclasses, attributedict)
```

这里等号右边的`type(classname, superclasses, attributedict)`，就是type的`__call__`运算符重载，它会进一步调用：

```
type.__new__(typeclass, classname, superclasses, attributedict)
type.__init__(class, classname, superclasses, attributedict)
```

当然，这一切都可以通过代码验证，比如下面这段代码示例：

```
class MyClass:
  data = 1
  
instance = MyClass()
MyClass, instance
# 输出
(__main__.MyClass, <__main__.MyClass instance at 0x7fe4f0b00ab8>)
instance.data
# 输出
1

MyClass = type('MyClass', (), {'data': 1})
instance = MyClass()
MyClass, instance
# 输出
(__main__.MyClass, <__main__.MyClass at 0x7fe4f0aea5d0>)

instance.data
# 输出
1
```

由此可见，正常的MyClass定义，和你手工去调用type运算符的结果是完全一样的。

### 第三，metaclass是type的子类，通过替换type的`__call__`运算符重载机制，“超越变形”正常的类。

其实，理解了以上几点，我们就会明白，正是Python的类创建机制，给了metaclass大展身手的机会。

一旦你把一个类型MyClass的metaclass设置成MyMeta，MyClass就不再由原生的type创建，而是会调用MyMeta的`__call__`运算符重载。

```
class = type(classname, superclasses, attributedict) 
# 变为了
class = MyMeta(classname, superclasses, attributedict)
```

所以，我们才能在上面YAML的例子中，利用YAMLObjectMetaclass的`__init__`方法，为所有YAMLObject子类偷偷执行`add_constructor()`。

## **使用metaclass的风险**

前面的篇幅，我都是在讲metaclass的原理和优点。的的确确，只有深入理解metaclass的本质，你才能用好metaclass。而不幸的是，正如我开头所说，深入理解metaclass的Python开发者，只占了0.1%不到。

不过，凡事有利必有弊，尤其是metaclass这样“逆天”的存在。正如你所看到的那样，metaclass会"扭曲变形"正常的Python类型模型。所以，如果使用不慎，对于整个代码库造成的风险是不可估量的。

换句话说，metaclass仅仅是给小部分Python开发者，在开发框架层面的Python库时使用的。而在应用层，metaclass往往不是很好的选择。

也正因为这样，据我所知，在很多硅谷一线大厂，使用Python metaclass需要特例特批。

## 总结

这节课，我们通过解读YAML的源码，围绕metaclass的设计本意“超越变形”，解析了metaclass的使用场景和使用方法。接着，我们又进一步深入到Python语言设计层面，搞明白了metaclass的实现机制。

正如我取的标题那样，metaclass是Python黑魔法级别的语言特性。天堂和地狱只有一步之遥，你使用好metaclass，可以实现像YAML那样神奇的特性；而使用不好，可能就会打开潘多拉魔盒了。

所以，今天的内容，一方面是帮助有需要的同学，深入理解metaclass，更好地掌握和应用；另一方面，也是对初学者的科普和警告：不要轻易尝试metaclass。

## 思考题

学完了上节课的Python装饰器和这节课的metaclass，你知道了，它们都能干预正常的Python类型机制。那么，你觉得装饰器和metaclass有什么区别呢？欢迎留言和我讨论。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>尘墨</span> 👍（96） 💬（9）<p>我尝试着自己写了一个例子，发现好像清晰多了，没有看懂的大家可以看一下
class Mymeta(type):
    def __init__(self, name, bases, dic):
        super().__init__(name, bases, dic)
        print(&#39;===&gt;Mymeta.__init__&#39;)
        print(self.__name__)
        print(dic)
        print(self.yaml_tag)

    def __new__(cls, *args, **kwargs):
        print(&#39;===&gt;Mymeta.__new__&#39;)
        print(cls.__name__)
        return type.__new__(cls, *args, **kwargs)

    def __call__(cls, *args, **kwargs):
        print(&#39;===&gt;Mymeta.__call__&#39;)
        obj = cls.__new__(cls)
        cls.__init__(cls, *args, **kwargs)
        return obj
    
class Foo(metaclass=Mymeta):
    yaml_tag = &#39;!Foo&#39;

    def __init__(self, name):
        print(&#39;Foo.__init__&#39;)
        self.name = name

    def __new__(cls, *args, **kwargs):
        print(&#39;Foo.__new__&#39;)
        return object.__new__(cls)

foo = Foo(&#39;foo&#39;)
把上面的例子运行完之后就会明白很多了，正常情况下我们在父类中是不能对子类的属性进行操作，但是元类可以。换种方式理解：元类、装饰器、类装饰器都可以归为元编程(引用自 python-cook-book 中的一句话)。</p>2019-06-20</li><br/><li><span>KaitoShy</span> 👍（6） 💬（3）<p>yaml.load(&quot;&quot;&quot;
--- !Monster
name: Cave spider
hp: [2,6]    # 2d6
ac: 16
attacks: [BITE, HURT]
&quot;&quot;&quot;)
运行时报错，pyyaml版本PyYAML-5.1，将语句改成
yaml.load(&quot;&quot;&quot;
--- !Monster
name: Cave spider
hp: [2,6]    # 2d6
ac: 16
attacks: [BITE, HURT]
&quot;&quot;&quot;，Loader=yaml.Loader)即可，参见&quot;https:&#47;&#47;github.com&#47;yaml&#47;pyyaml&#47;issues&#47;266&quot;</p>2019-06-19</li><br/><li><span>TKbook</span> 👍（4） 💬（2）<p>一开始还以为我打开错专栏了。   目前看了好多解释metaclass的文章，感觉这一篇看起来最明了。</p>2019-06-19</li><br/><li><span>隔壁家老鲍</span> 👍（1） 💬（1）<p>感觉入门了，不过还是有一些问题
@修饰符是在python里是怎么实现的呢
老师如果看到了可以给点意见么</p>2019-12-16</li><br/><li><span>jackstraw</span> 👍（0） 💬（1）<p>这代码跑都跑不通</p>2020-01-12</li><br/><li><span>奔跑的蜗牛</span> 👍（123） 💬（5）<p>看不懂了 😄</p>2019-06-19</li><br/><li><span>=_=</span> 👍（41） 💬（0）<p>基础不够，之前没接触过metaclass，这一讲读起来太费劲了</p>2019-06-19</li><br/><li><span>程序员人生</span> 👍（36） 💬（1）<p>装饰器像AOP，metaclass像反射机制</p>2019-06-19</li><br/><li><span>Hoo-Ah</span> 👍（28） 💬（0）<p>之前讲装饰器的时候讲到函数装饰器和类装饰器，而类装饰器就是在雷里面定义了__call__方法，之后在函数执行的时候会调用类的__call__方法。
在metaclass中重载了__call__方法，在使用metaclass实例化生成类的时候也是调用了__call__方法，从这方面来讲是很像。
要说不一样的话，一个是在执行层面，一个是在生成层面。
可以讲讲type和object的区别吗以及可以用一篇专栏讲讲python的魔术方法。</p>2019-06-19</li><br/><li><span>建强</span> 👍（24） 💬（0）<p>1.metaclass拦截了类的构造，类似于黑客，改变了类的行为，在某些场合可简化程序设计。
2.python装饰器：不会去改变类的行为，但通过装饰类，可以加强类的功能，通过不同的装饰器使类的功能更加丰富。</p>2019-09-25</li><br/><li><span>你看起来很好吃</span> 👍（9） 💬（7）<p>‘用户自定义类，只不过是 type 类的__call__运算符’
景老师，这里这段是不是有点问题，我做了以下实验：

class MyMeta(type):
    def __init__(cls, name, bases, dict):
        print(&#39;MyMeta __init__&#39;)

    def __new__(cls, name, bases, dict):
        print(&#39;MyMeta __new__&#39;)
        return type.__new__(cls, name, bases, dict)

    def __call__(cls):
        print(&#39;MyMeta __call__&#39;)
        return type.__call__(cls)

class Test(metaclass=MyMeta):
    a = 10

    def __init__(self):
        pass

    def __new__(cls):
        return super(Test, cls).__new__(cls)

test = Test()
我发现在使用class Test()定义类时，会依次调用MyMeta的__new__和__init__方法构建Test类，然后在使用test = Test()创建类对象时，才会调用MyMeta的__call__方法来调用Test类的__new__和__init__方法。好像和您说的不一样？
我看您说的意思是，在使用class定义类的时候，先调用metaclass的__call__,然后再调用metaclass的__new__和__init__？</p>2019-06-19</li><br/><li><span>Wing·三金</span> 👍（8） 💬（1）<p>个人粗浅的理解是：metaclass 与 类装饰器相似，大多数情况下本质上都是重载了 __call__ 函数，但有一个明显的区别是前者对【继承了 metaclass 的子类本身】的属性造成了影响，而类装饰器是对【作为装饰器本身的类】造成影响而已，对【被装饰的类】的属性没有直接影响（间接影响就看被装饰的函数怎么操作了）。</p>2019-06-22</li><br/><li><span>Jon徐</span> 👍（8） 💬（3）<p>之前没有接触过 metaclass，感觉用metaclass的作用就是超动态生成类。这节课感觉确实比较魔术，跟上一节装饰器还要再细想一下。

pyyaml 5.1以上，这段代码会报错，要把 yaml.load() 改成 yaml.load_all()
yaml.load(&quot;&quot;&quot;
--- !Monster
name: Cave spider
hp: [2,6]    # 2d6
ac: 16
attacks: [BITE, HURT]
&quot;&quot;&quot;)


</p>2019-06-20</li><br/><li><span>向南</span> 👍（5） 💬（0）<p>metaclass的应用：单例模式、ORM模式</p>2020-03-08</li><br/><li><span>Ray</span> 👍（5） 💬（0）<p>我的感觉装饰器是通过正常的函数的调用、闭包等方法实现附加的功能。metaclass直接就是一种hack的方法。另外，在前面type类的说明代码中：
type(instance)# 输出 &lt;class &#39;__main__.C&#39;&gt;  --&gt; 应该是&lt;class &#39;__main__.MyClass&#39;&gt;？</p>2020-02-22</li><br/>
</ul>