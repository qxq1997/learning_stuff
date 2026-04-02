你好，我是徐昊，今天我们继续使用TDD的方式实现注入依赖容器。

## 回顾代码与任务列表

到目前为止，我们的代码是这样的：

```
package geektime.tdd.di;
    
import jakarta.inject.Inject;
import jakarta.inject.Provider;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.stream.Collectors;
import static java.util.Arrays.stream;
   
public class Context {
    private Map<Class<?>, Provider<?>> providers = new HashMap<>();
    
    public <Type> void bind(Class<Type> type, Type instance) {
        providers.put(type, (Provider<Type>) () -> instance);
    }
    
    public <Type, Implementation extends Type>
    void bind(Class<Type> type, Class<Implementation> implementation) {
        Constructor<Implementation> injectConstructor = getInjectConstructor(implementation);
        providers.put(type, (Provider<Type>) () -> {
            try {
                Object[] dependencies = stream(injectConstructor.getParameters())
                        .map(p -> get(p.getType()).orElseThrow(DependencyNotFoundException::new))
                        .toArray(Object[]::new);
                return injectConstructor.newInstance(dependencies);
            } catch (InvocationTargetException | InstantiationException | IllegalAccessException e) {
                throw new RuntimeException(e);
            }
        });
    }
    
    private <Type> Constructor<Type> getInjectConstructor(Class<Type> implementation) {
        List<Constructor<?>> injectConstructors = stream(implementation.getConstructors())
                .filter(c -> c.isAnnotationPresent(Inject.class)).collect(Collectors.toList());
        if (injectConstructors.size() > 1) throw new IllegalComponentException();
        return (Constructor<Type>) injectConstructors.stream().findFirst().orElseGet(() -> {
                    try {
                        return implementation.getConstructor();
                    } catch (NoSuchMethodException e) {
                        throw new IllegalComponentException();
                    }
                });
    }
    
    public <Type> Optional<Type> get(Class<Type> type) {
        return Optional.ofNullable(providers.get(type)).map(provider -> (Type)provider.get());
    }
}
```

任务列表状态为:

![](https://static001.geekbang.org/resource/image/3d/f1/3dbd7ede7cc98a5ea9d1bf275b362ff1.jpg?wh=6259x10979)

## 视频演示

让我们进入今天的部分：

## 思考题

为了我们更好的交流与互动，从这节课开始，思考题目除了固定的技术问题外，我还会设置一道较为轻松的题目，供你选择与回答。

1. 对于依赖的检测，目前代码的实现是在实际创建组件对象时进行的。如果改为预先检查，我们要做哪些改变呢？
2. 在今天这节课中，最让你有收获的地方是什么？为什么？

欢迎把你的想法分享在留言区，也欢迎把你的项目代码的链接分享出来。相信经过你的思考与实操，学习效果会更好！
<div><strong>精选留言（10）</strong></div><ul>
<li><span>xiaobang</span> 👍（2） 💬（1）<p>预先检查的实现思路，维护一张Map，其中Key为Component，value为依赖该Component的Component集合。bind时检查当前Component依赖的Component不在依赖当前Component的集合里，同时维护该Map</p>2022-04-24</li><br/><li><span>Jason</span> 👍（1） 💬（1）<p>老师你好我有个问题：
实现检查是否循环依赖的代码，如果是在多线程的情况下是不是会出现bug。如果两个线程同时get一个component.class,其中一个不就会抛出异常？
这个问题的衍生就是：
在实际业务场景中，TDD如何自然的使用任务列表以及对应的testcase，推导出有关多线程的需求实现代码？</p>2022-06-04</li><br/><li><span>临风</span> 👍（1） 💬（0）<p>改为预先检查，我认为就要一开始就把实例创建好放入容器中去。这就导致你必须知道依赖的实例要怎么创建。
我想到的方式就是用spring的方式，1.通过@Component来指明实现类；2.通过xml或者@Configuration来指明如何初始化。
还想到一个方法就是bind必须按照顺序初始化，无依赖的先初始化，类似有向图，没有出度的节点先初始化。</p>2022-04-20</li><br/><li><span>努力努力再努力</span> 👍（0） 💬（0）<p>问题1：对于依赖的检测，目前代码的实现是在实际创建组件对象时进行的。如果改为预先检查，我们要做哪些改变呢？
如果改为在 bind 处检查，可以维护一个哈希表，key是componentType， value 是构造函数参数的集合。每绑定一个组件的时候，获取构造函数的参数到哈希表中查询，如果存在，判断对应的 value 中是否包含 component，包含则可以认为 存在循环依赖，抛出异常。


问题2：在今天这节课中，最让你有收获的地方是什么？为什么？
最有收获的是老师在编码过程中，将突发想到的问题，转化为测试用例记录在案。这让我想到一些平时在工作中，前一个月修复的Bug，基本都是在生产代码上直接进行修改的，有时候可能仅仅是加了一个 if 分支的判断，然而个把月后突然看到这个分支，完全想不起来当初为什么会这样加。如果有测试用例可以回溯，那么也方便后续的问题跟踪</p>2022-09-23</li><br/><li><span>蝴蝶</span> 👍（0） 💬（0）<p>问题 1：增加类似 builder 模式里面 build 的方法来检查依赖。</p>2022-08-13</li><br/><li><span>Geek_874b6f</span> 👍（0） 💬（0）<p>Idea 支持将匿名类转化内部类的</p>2022-05-31</li><br/><li><span>keep_curiosity</span> 👍（0） 💬（0）<p>使用Set存放循环依赖的组件不能保证组件依赖的顺序吧？如何构造有效的测试验证顺序呢？
我的跟练：https:&#47;&#47;github.com&#47;codingthought&#47;TDD-DI</p>2022-05-01</li><br/><li><span>枫中的刀剑</span> 👍（0） 💬（0）<p>解决循环依赖的思路确实妙啊，后来查看guice的源码里发现也是这样判断循环依赖的。</p>2022-04-27</li><br/><li><span>ACE丶8</span> 👍（0） 💬（0）<p>收获：在实现循环依赖，自己的思路是将依赖信息，在构造的过程中不断传递，当构造的时候发现，构造信息中已经出现过该类，就抛出异常，最终没有解决。老师的思路是通过一个代理类，携带上构造信息，让循环依赖的检查变得更加简单，学习了。</p>2022-04-25</li><br/><li><span>aoe</span> 👍（0） 💬（0）<p>最大收获：测试可以及时发现 Bug，将排查范围缩减到最小，虽然不停回放视频比对代码很吃力，但还是能看到希望。
原因：如果没有测试的代码，以下两个小细节导致的 Bug，找一天也不一定能发现！

跟着视频敲代码，卡住2次，都来自 public T get() 方法：
1、constructing = true; 的位置比老师的靠后（我天真的想法：靠前靠后关系大吗？赋值就行）
2、try 的作用域比老师的小（我天真的想法：要尽量将 try 的作用域减小，专注真正需要捕获异常的部分；提升性能）

可以使用 HashSet&lt;Class&lt;?&gt;&gt; classes = Sets.newHashSet(exception.getComponents());
需要导入依赖：implementation &#39;com.google.guava:guava:31.1-jre&#39;</p>2022-04-20</li><br/>
</ul>