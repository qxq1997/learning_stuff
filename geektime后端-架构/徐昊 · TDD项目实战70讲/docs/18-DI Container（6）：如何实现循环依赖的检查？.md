你好，我是徐昊。今天我们继续使用TDD的方式实现注入依赖容器。

## 回顾代码与任务列表

到目前为止，我们的代码是这样的：

```
 ContextConfig.java: 
    
    package geektime.tdd.di;
    
    import jakarta.inject.Inject;
    import java.lang.reflect.Constructor;
    import java.lang.reflect.InvocationTargetException;
    import java.lang.reflect.Parameter;
    import java.util.HashMap;
    import java.util.List;
    import java.util.Map;
    import java.util.Optional;
    import java.util.stream.Collectors;
    import static java.util.Arrays.asList;
    import static java.util.Arrays.stream;
        
    public class ContextConfig {
        private Map<Class<?>, ComponentProvider<?>> providers = new HashMap<>();
        private Map<Class<?>, List<Class<?>>> dependencies = new HashMap<>();
        
        public <Type> void bind(Class<Type> type, Type instance) {
            providers.put(type, context -> instance);
            dependencies.put(type, asList());
        }
        
        public <Type, Implementation extends Type>
        void bind(Class<Type> type, Class<Implementation> implementation) {
            Constructor<Implementation> injectConstructor = getInjectConstructor(implementation);
            providers.put(type, new ConstructorInjectionProvider<>(type, injectConstructor));
            dependencies.put(type, stream(injectConstructor.getParameters()).map(Parameter::getType).collect(Collectors.toList()));
        }
        
        public Context getContext() {
            for (Class<?> component: dependencies.keySet()) {
                for (Class<?> dependency: dependencies.get(component)) {
                    if (!dependencies.containsKey(dependency)) throw new DependencyNotFoundException(component, dependency);
                }
            }
            return new Context() {
                @Override
                public <Type> Optional<Type> get(Class<Type> type) {
                    return Optional.ofNullable(providers.get(type)).map(provider -> (Type) provider.get(this));
                }
            };
        }
        
        interface ComponentProvider<T> {
            T get(Context context);
        }
        
        class ConstructorInjectionProvider<T> implements ComponentProvider<T> {
            private Class<?> componentType;
            private Constructor<T> injectConstructor;
            private boolean constructing = false;
            public ConstructorInjectionProvider(Class<?> componentType, Constructor<T> injectConstructor) {
                this.componentType = componentType;
                this.injectConstructor = injectConstructor;
            }
            @Override
            public T get(Context context) {
                if (constructing) throw new CyclicDependenciesFoundException(componentType);
                try {
                    constructing = true;
                    Object[] dependencies = stream(injectConstructor.getParameters())
                            .map(p -> context.get(p.getType())
                                    .orElseThrow(() -> new DependencyNotFoundException(componentType, p.getType())))
                            .toArray(Object[]::new);
                    return injectConstructor.newInstance(dependencies);
                } catch (CyclicDependenciesFoundException e) {
                    throw new CyclicDependenciesFoundException(componentType, e);
                } catch (InvocationTargetException | InstantiationException | IllegalAccessException e) {
                    throw new RuntimeException(e);
                } finally {
                    constructing = false;
                }
            }
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
    }
        
    Context.java:
        
    package geektime.tdd.di;
        
    import java.util.Optional;
     
    public interface Context {
        <Type> Optional<Type> get(Class<Type> type);
    }
```

任务列表状态为：

![](https://static001.geekbang.org/resource/image/ce/4c/cebe21e8012af25ae8b11824cd73c44c.jpg?wh=6294x10999)

## 视频演示

让我们进入今天的部分：  

## 思考题

为了我们更好的交流与互动，从这节课开始，思考题目除了固定的技术问题外，我还会设置一道较为轻松的题目，供你选择与回答。

1. 在当前的代码结构下，后续任务需要做何种改变？
2. 在学习课程的过程中，你对TDD的认识有发生什么变化吗？

欢迎把你的想法分享在留言区，也欢迎把你的项目代码的链接分享出来。相信经过你的思考与实操，学习效果会更好！
<div><strong>精选留言（10）</strong></div><ul>
<li><span>aoe</span> 👍（5） 💬（0）<p>老师在微信群中提了一个思考题：学习重构这部分需要注意的地方
- 第一个，你们可以反思一下，bad smell 是什么的，是怎么发现的。这个最重要。
- 第二个，对比重构前和重构后的代码结构。到底做了什么改变。这个慢慢你们就会养成习惯，有重构的大局观。
- 第三个，列一下用的重构手法，看如何改变的。这个反而没那么重要，每个人做法也不一样。

我的理解

- 一、bad smell 是什么的，是怎么发现的
  - 违反**DRY原则**（Don’t repeat yourself）的最多
    - 实现逻辑：代码重复基本可以直接看出来（收留心观察就行）
    - 测试类：需要在重构后留意是否有重复的逻辑
  - 违反**YAGNI原则**（You ain’t gonna need it）
    - 实现逻辑：一波操作后，Idea 会提示没有被用到的变量、方法
    - 测试类：需要在重构后留意是否有没有被用到的代码
  - 违反 **KISS原则**（Keep it simple, stupid）
    - 实现逻辑：尽量让代码朝着更简单的方向发展
  - 违反**单一职责原则**
    - 一个类或方法承担了多个职责
  - 总结：设计原则的时候，就是 bad smell，需要及时重构
- 二、对比重构前和重构后的代码结构，到底做了什么改变
  - 重构前：
    - 简单粗暴实现功能，不要给我说什么设计原则、设计模式、数据结构、拿起键盘就是干！一把梭！
    - 对测试友好（因为是 TDD，代码再烂也不能直接翻车）
    - 对后期维护不友好，代码有点乱
  - 重构后：
    - 大部分代码符合设计原则、合理套用设计模式、正确使用数据结构
    - 对测试友好
    - 对后期维护友好，代码整洁、逻辑清晰
- 三、列一下用的重构手法，看如何改变的
  - 使用 Idea 快捷键进行重构（Extract 变量、方法参数、方法、类；inLine 方法；构造工厂方法；尽量使用接口等）
  - 通过**绞杀植物模式**替换旧的实现
    - 姚琪琳老师的 [遗留系统现代化实战 | 06 | 以增量演进为手段：为什么历时一年的改造到头来是一场空？](http:&#47;&#47;gk.link&#47;a&#47;11lAM)中有详细介绍

附录
设计原则：https:&#47;&#47;wyyl1.com&#47;post&#47;18&#47;02&#47;#51-%E4%B8%BA%E4%BD%95%E8%A6%81%E5%85%B3%E5%BF%83%E8%AE%BE%E8%AE%A1

格式化后的思考题：https:&#47;&#47;wyyl1.com&#47;post&#47;19&#47;wq&#47;#%E8%AF%B4%E4%B8%80%E4%B8%8B%E5%AD%A6%E4%B9%A0%E9%87%8D%E6%9E%84%E8%BF%99%E9%83%A8%E5%88%86-</p>2022-04-24</li><br/><li><span>aoe</span> 👍（1） 💬（1）<p>奇怪的问题
单独运行测试 void should_throw_exception_if_transitive_dependency_not_found() 不通过
整体运行 ContainerTest 则通过
使用命令运行和老师的测试结果一样：.&#47;gradlew test
代码：https:&#47;&#47;github.com&#47;wyyl1&#47;geektime-tdd-di-container&#47;tree&#47;di-container-6-strange
开发工具：IntelliJ IDEA 2021.3.3 (Community Edition)
环境：openjdk version &quot;17.0.1&quot; 2021-10-19</p>2022-04-24</li><br/><li><span>favorlm</span> 👍（0） 💬（0）<p>我对问题2感触颇深：让我理解了TDD是驱动的架构，在完成本课程的学习过程中，我忘记了大学学的图监测环的算法，这也让我意识到，一些实现的知识和学习TDD驱动方法，并不冲突。</p>2024-04-20</li><br/><li><span>奇小易</span> 👍（0） 💬（0）<p>Q1：在当前的代码结构下，后续任务需要做何种改变？
按照现有代码结构下，方法注入和字段注入的实现可以预见应该是提供两个provider的实现来完成。
按照这个预期可以直接将这两部分的功能直接分到新的测试单元中进行测试。
因为目前的结构比较清晰，而最开始的时候并没有一个清晰的结构。
其它的功能目前同样没有明确的结构，所以不需要调整。这是我的理解。

Q2：在学习课程的过程中，你对 TDD 的认识有发生什么变化吗？
1、必须要在多种场景下见识下，TDD能够自己演进出合理的结构，才能真正的相信这种假设。
（这次重构后再次感受这种现实）
2、感觉在调整整个结构时的满足感好像比前面的重构更大。</p>2022-05-18</li><br/><li><span>新的一页</span> 👍（0） 💬（0）<p>1. 我觉得后续的调整可以这样走，happy path放在config中，sadly path放在provider里面；
2. 实践TDD的时候，我发现需要一台好的机器，以支持我频繁的跑测试。</p>2022-05-09</li><br/><li><span>keep_curiosity</span> 👍（0） 💬（0）<p>循环依赖抛出异常时，抛出具体要实例化的类型相比只抛接口的类型是不是对用户更友好？
本节课跟练结束后的tag：https:&#47;&#47;github.com&#47;codingthought&#47;TDD-DI&#47;releases&#47;tag&#47;18</p>2022-05-01</li><br/><li><span>胡小寒</span> 👍（0） 💬（1）<p>测试</p>2022-04-25</li><br/><li><span>临风</span> 👍（0） 💬（1）<p>重构到contextConfig部分的时候，和老师的实现有所不同。我的理解中，老师是将通过一个context接口，将get逻辑通过context接口进行了二次的封装，来间接调用provider中的ComponentProvider来获取实例，再将原有的get方法从contextConfig调用，改为context调用，有点像对get方法做了一个aop的增强，这样就能实现dependencies的前置校验校验。
在我的实现中，我是将原本的context变为contextConfiguration，代码基本保持不变，新增initContainer方法。通过该方法将providers生成的实例，直接传递给新的Context类，在新的Context中保存在Map&lt;Class&lt;?&gt;, Object&gt; container中，然后把get方法移到Context类中。这样contextConfiguration只有bind的逻辑，而新的Context只有get的逻辑。但是我不知道我这样写会有什么问题，希望老师能指点一下。
https:&#47;&#47;github.com&#47;lenwind&#47;TDD-Learn</p>2022-04-22</li><br/><li><span>aoe</span> 👍（0） 💬（0）<p>消除坏味道，这句语气很可爱</p>2022-04-21</li><br/><li><span>Flynn</span> 👍（0） 💬（0）<p>加餐想老师搞一节Android开发的TDD</p>2022-04-19</li><br/>
</ul>