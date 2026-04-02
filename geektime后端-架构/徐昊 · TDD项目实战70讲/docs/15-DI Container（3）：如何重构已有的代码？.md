你好，我是徐昊。今天我们继续使用TDD的方式来实现注入依赖容器。

## 回顾代码与任务列表

到目前为止，我们的代码是这样的：

```
package geektime.tdd.di;

import jakarta.inject.Inject;
import jakarta.inject.Provider;
import java.lang.reflect.Constructor;
import java.util.HashMap;
import java.util.Map;
 
import static java.util.Arrays.stream;
public class Context {
    private Map<Class<?>, Provider<?>> providers = new HashMap<>();
    
    public <Type> void bind(Class<Type> type, Type instance) {
        providers.put(type, (Provider<Type>) () -> instance);
    }
    
    public <Type, Implementation extends Type>
    void bind(Class<Type> type, Class<Implementation> implementation) {
        Constructor<?>[] injectConstructors = stream(implementation.getConstructors()).filter(c -> c.isAnnotationPresent(Inject.class))
                .toArray(Constructor<?>[]::new);
        if (injectConstructors.length > 1) throw new IllegalComponentException();
        if (injectConstructors.length == 0 && stream(implementation.getConstructors())
                .filter(c -> c.getParameters().length == 0).findFirst().map(c -> false).orElse(true))
            throw new IllegalComponentException();
        providers.put(type, (Provider<Type>) () -> {
            try {
                Constructor<Implementation> injectConstructor = getInjectConstructor(implementation);
                Object[] dependencies = stream(injectConstructor.getParameters())
                        .map(p -> get(p.getType()))
                        .toArray(Object[]::new);
                return injectConstructor.newInstance(dependencies);
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        });
    }
    
    private <Type> Constructor<Type> getInjectConstructor(Class<Type> implementation) {
        return (Constructor<Type>) stream(implementation.getConstructors())
                .filter(c -> c.isAnnotationPresent(Inject.class)).findFirst().orElseGet(() -> {
                    try {
                        return implementation.getConstructor();
                    } catch (NoSuchMethodException e) {
                        throw new RuntimeException(e);
                    }
                });
    }
    
    public <Type> Type get(Class<Type> type) {
        return (Type) providers.get(type).get();
    }
}
```

任务列表状态为：

- 无需构造的组件——组件实例
- 如果注册的组件不可实例化，则抛出异常
  
  - 抽象类
  - 接口
- 构造函数注入
  
  - 无依赖的组件应该通过默认构造函数生成组件实例
  - 有依赖的组件，通过Inject标注的构造函数生成组件实例
  - 如果所依赖的组件也存在依赖，那么需要对所依赖的组件也完成依赖注入
  - 如果组件有多于一个Inject标注的构造函数，则抛出异常
  - 如果组件没有Inject标注的构造函数，也没有默认构造函数（新增任务）
  - 如果组件需要的依赖不存在，则抛出异常
  - 如果组件间存在循环依赖，则抛出异常
- 字段注入
  
  - 通过Inject标注将字段声明为依赖组件
  - 如果组件需要的依赖不存在，则抛出异常
  - 如果字段为final则抛出异常
  - 如果组件间存在循环依赖，则抛出异常
- 方法注入
  
  - 通过Inject标注的方法，其参数为依赖组件
  - 通过Inject标注的无参数方法，会被调用
  - 按照子类中的规则，覆盖父类中的Inject方法
  - 如果组件需要的依赖不存在，则抛出异常
  - 如果方法定义类型参数，则抛出异常
  - 如果组件间存在循环依赖，则抛出异常
- 对Provider类型的依赖
  
  - 注入构造函数中可以声明对于Provider的依赖
  - 注入字段中可以声明对于Provider的依赖
  - 注入方法中可声明对于Provider的依赖
- 自定义Qualifier的依赖
  
  - 注册组件时，可额外指定Qualifier
  - 注册组件时，可从类对象上提取Qualifier
  - 寻找依赖时，需同时满足类型与自定义Qualifier标注
  - 支持默认Qualifier——Named
- Singleton生命周期
  
  - 注册组件时，可额外指定是否为Singleton
  - 注册组件时，可从类对象上提取Singleton标注
  - 对于包含Singleton标注的组件，在容器范围内提供唯一实例
  - 容器组件默认不是Single生命周期
- 自定义Scope标注
  
  - 可向容器注册自定义Scope标注的回调

## 视频演示

让我们进入今天的部分：

## 思考题

如何实现循环依赖的检测？

欢迎把你的思考和想法分享在留言区，也欢迎你扫描详情页的二维码加入读者交流群。我们下节课再见！
<div><strong>精选留言（7）</strong></div><ul>
<li><span>小5</span> 👍（4） 💬（0）<p>学习了这节课的内容，想到了之前章节的一段话：

Kent Beck 作为极限编程（Exetreme Programming）的创始人，将勇气（Courage）作为极限编程的第一原则，提出编程的第一大敌是恐惧（Fear），实在是有非凡的洞见。同时，他也花了极大的篇幅，说明为什么 TDD 可以让我们免于恐惧：重构使得我们在实现功能时，不恐惧于烂代码；测试使得我们在重构时，不恐惧于功能破坏。

我们平时常说：代码看不懂、改不动、不敢改。
看不懂是指认知负载太高，导致代码很难改，改了一个地方影响很多地方，甚至不知道影响多少地方，也就自然不敢改了，改出问题了谁负责，改一个bug改出多了几个新bug，以前公司老人常说千万不要在现有的代码上改，要把方法copy一份，然后再改，调用新的方法😂，多么痛的领悟。

在做练习的重构过程中明白了因为对所有的代码都有测试，改了代码跑一下如果有错误就很容易发现，所以给了我们改代码的勇气。</p>2022-09-25</li><br/><li><span>escray</span> 👍（4） 💬（0）<p>进入到第二阶段的课程之后，给出的代码相对比较详细，虽然实现的功能比起前面要复杂一些，但是跟上节奏就不那么困难了。

这个专栏的门槛还是挺高的。

实现循环依赖检测，比较容易想到的就是在每个依赖添加一个标志位，但是这个似乎不那么容易实现；那么另一个方式，就是增加一个记录依赖的列表，每次都去判断是否存在循环依赖。

代码不太会写，只能先想一下。

本课的代码链接：https:&#47;&#47;github.com&#47;escray&#47;TDDCourse&#47;tree&#47;ch15</p>2022-04-28</li><br/><li><span>汗香</span> 👍（3） 💬（0）<p>获取一个依赖前，先从已有依赖获取，
    若获取结果不为空则获取成功，
    若获取结果为空，先将被获取依赖类型放入一个待创建集合中，并判断当前组件本身是否在集合中，若在，说明有循环依赖
</p>2022-04-25</li><br/><li><span>努力努力再努力</span> 👍（1） 💬（0）<p>哭了，上一个留言发现有问题，自己实现的时候才发现单纯一个 set 集合记录正在创建的bean还不行，得利用 TLS（https:&#47;&#47;time.geekbang.org&#47;column&#47;article&#47;93745） 模式做线程隔离，否则多线程的测试用例下，就会出现明明没有循环依赖而报错的问题。</p>2022-09-23</li><br/><li><span>努力努力再努力</span> 👍（1） 💬（0）<p>循环依赖，可以加一个 bean 在创建中的标识，当 bean 被创建完之后，就把标识去掉，这样如果创建过程中发现这个 bean 正在创建中，就可以认为是发生循环依赖了</p>2022-09-23</li><br/><li><span>蝴蝶</span> 👍（0） 💬（0）<p>@Inject注解的构造方法如果没有参数，那肯定是有问题的，这次看明白了。</p>2022-08-13</li><br/><li><span>davix</span> 👍（0） 💬（0）<p>get() 重構受啟發！雖然看過《重構》了解其中的方法，但平時如果get()設計變化我通常還是直接改。這回直觀感受引入get_()的好處。</p>2022-05-25</li><br/>
</ul>