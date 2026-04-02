你好，我是徐昊。今天我们继续使用TDD的方式实现注入依赖容器。

## 回顾代码与任务列表

到目前为止，我们的代码是这样的：

```
ContextConfig.java:

package geektime.tdd.di;

import java.util.*;
import static java.util.List.of;

public class ContextConfig {
    private Map<Class<?>, ComponentProvider<?>> providers = new HashMap<>();
    
    public <Type> void bind(Class<Type> type, Type instance) {
        providers.put(type, new ComponentProvider<Type>() {
            @Override
            public Type get(Context context) {
                return instance;
            }
            @Override
            public List<Class<?>> getDependencies() {
                return of();
            }
        });
    }
    
    public <Type, Implementation extends Type>
    void bind(Class<Type> type, Class<Implementation> implementation) {
        providers.put(type, new ConstructorInjectionProvider<>(implementation));
    }
    
    public Context getContext() {
        providers.keySet().forEach(component -> checkDependencies(component, new Stack<>()));
        return new Context() {
            @Override
            public <Type> Optional<Type> get(Class<Type> type) {
                return Optional.ofNullable(providers.get(type)).map(provider -> (Type) provider.get(this));
            }
        };
    }
    
    private void checkDependencies(Class<?> component, Stack<Class<?>> visiting) {
        for (Class<?> dependency: providers.get(component).getDependencies()) {
            if (!providers.containsKey(dependency)) throw new DependencyNotFoundException(component, dependency);
            if (visiting.contains(dependency)) throw new CyclicDependenciesFoundException(visiting);
            visiting.push(dependency);
            checkDependencies(dependency, visiting);
            visiting.pop();
        }
    }
    
    interface ComponentProvider<T> {
        T get(Context context);
        List<Class<?>> getDependencies();
    }
}
    
ConstructorInjectionProvider.java:
    
package geektime.tdd.di;
    
import jakarta.inject.Inject;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Parameter;
import java.util.List;
import java.util.stream.Collectors;
import static java.util.Arrays.stream;


class ConstructorInjectionProvider<T> implements ContextConfig.ComponentProvider<T> {
    private Constructor<T> injectConstructor;
    
    public ConstructorInjectionProvider(Class<T> component) {
        this.injectConstructor = getInjectConstructor(component);
    }
    
    private static <Type> Constructor<Type> getInjectConstructor(Class<Type> implementation) {
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
    
    @Override
    public T get(Context context) {
        try {
            Object[] dependencies = stream(injectConstructor.getParameters())
                    .map(p -> context.get(p.getType()).get())
                    .toArray(Object[]::new);
            return injectConstructor.newInstance(dependencies);
        } catch (InvocationTargetException | InstantiationException | IllegalAccessException e) {
            throw new RuntimeException(e);
        }
    }
    
    @Override
    public List<Class<?>> getDependencies() {
        return stream(injectConstructor.getParameters()).map(Parameter::getType).collect(Collectors.toList());
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

在进入下节课之前，希望你能认真思考如下两个问题，并选择最有感触的一道进行回答。

1. 要如何实现Method Injection部分的功能呢？
2. 在你看来，这节课的难易程度如何？有遇到什么卡壳的地方吗？

欢迎把你的想法分享在留言区，也欢迎把你的项目代码的链接分享出来。相信经过你的思考与实操，学习效果会更好！
<div><strong>精选留言（7）</strong></div><ul>
<li><span>枫中的刀剑</span> 👍（5） 💬（1）<p>这节个人感觉比较重要的就是对于同样的功能，在不同上下文环境下对测试风格的选择方式问题。
在某些情况下，不同的风格传递的信息或者说知识是不太一样的。而伴随你不同风格的选择可能直接影响后续功能实现的难易程度。TDD主要的难点还是在于设计，在于你对知识的理解，究竟是以一种怎样的方式呈现出来。</p>2022-04-27</li><br/><li><span>张铁林</span> 👍（2） 💬（0）<p>config.bind(ComponentWithFieldInjection.class, ComponentWithFieldInjection.class);
干嘛要把自己绑定到自己身上？
老师说：不像写个接口[抠鼻]，懒。
我说我看得云里雾里，我在这给大家提个醒。</p>2022-04-26</li><br/><li><span>常文龙</span> 👍（0） 💬（0）<p>有点恍然大悟，TDD恰恰不是自上而下的分而治之，而是自下而上的不断调整</p>2023-07-23</li><br/><li><span>奇小易</span> 👍（0） 💬（0）<p>思考：
在不同功能上下文内完成任务项时，
有时候在更大范围的功能上下文的测试更好，有时在更小范围的功能上下文的测试更好。
故选择在哪个功能上下文进行编写测试时，需要思考不同功能上下文编写的测试会有什么差别。
然后再决定在哪个功能上下文进行编写。</p>2022-05-25</li><br/><li><span>新的一页</span> 👍（0） 💬（0）<p>难的还是思维的转变，比如对于测试的整理，多少才算够。</p>2022-05-10</li><br/><li><span>aoe</span> 👍（0） 💬（0）<p>在你看来，这节课的难易程度如何？
很早就对逻辑实现一知半解了，坚持跟着视频敲代码，运行测试。每当测试通过时都会感觉：哇！好神奇！对于这个目标，难度可以接受。

有遇到什么卡壳的地方吗？
和之前一样，细小的差别，测试没通过，略微检查一下就过去了</p>2022-04-27</li><br/><li><span>张铁林</span> 👍（0） 💬（0）<p>对比时，写了4、5个例子，没太理解有什么差别。</p>2022-04-26</li><br/>
</ul>