你好，我是徐昊。今天我们继续使用TDD的方式来实现注入依赖容器。

## 回顾代码与任务列表

到目前为止，我们的代码是这样的：

```
InjectProvider.java:

package geektime.tdd.di;

import jakarta.inject.Inject;
import java.lang.reflect.*;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.function.BiFunction;
import java.util.stream.Stream;
import static java.util.Arrays.stream;
import static java.util.stream.Stream.concat;

class InjectionProvider<T> implements ContextConfig.ComponentProvider<T> {

    private Constructor<T> injectConstructor;
    private List<Field> injectFields;
    private List<Method> injectMethods;
    
    public InjectionProvider(Class<T> component) {
        if (Modifier.isAbstract(component.getModifiers())) throw new IllegalComponentException();
        this.injectConstructor = getInjectConstructor(component);
        this.injectFields = getInjectFields(component);
        this.injectMethods = getInjectMethods(component);
        if (injectFields.stream().anyMatch(f -> Modifier.isFinal(f.getModifiers())))
            throw new IllegalComponentException();
        if (injectMethods.stream().anyMatch(m -> m.getTypeParameters().length != 0))
            throw new IllegalComponentException();
    }
    
    @Override
    public T get(Context context) {
        try {
            T instance = injectConstructor.newInstance(toDependencies(context, injectConstructor));
            for (Field field : injectFields) field.set(instance, toDependency(context, field));
            for (Method method : injectMethods) method.invoke(instance, toDependencies(context, method));
            return instance;
        } catch (InvocationTargetException | InstantiationException | IllegalAccessException e) {
            throw new RuntimeException(e);
        }
    }
    
    @Override
    public List<Type> getDependencies() {
        return concat(concat(stream(injectConstructor.getParameters()).map(Parameter::getParameterizedType),
                        injectFields.stream().map(Field::getGenericType)),
                injectMethods.stream().flatMap(m -> stream(m.getParameters()).map(Parameter::getParameterizedType))).toList();
    }
    
    private static <T> List<Method> getInjectMethods(Class<T> component) {
        List<Method> injectMethods = traverse(component, (methods, current) -> injectable(current.getDeclaredMethods())
                .filter(m -> isOverrideByInjectMethod(methods, m))
                .filter(m -> isOverrideByNoInjectMethod(component, m)).toList());
        Collections.reverse(injectMethods);
        return injectMethods;
    }
    
    private static <T> List<Field> getInjectFields(Class<T> component) {
        return traverse(component, (fields, current) -> injectable(current.getDeclaredFields()).toList());
    }
    
    private static <Type> Constructor<Type> getInjectConstructor(Class<Type> implementation) {
        List<Constructor<?>> injectConstructors = injectable(implementation.getConstructors()).toList();
        if (injectConstructors.size() > 1) throw new IllegalComponentException();
        return (Constructor<Type>) injectConstructors.stream().findFirst().orElseGet(() -> defaultConstructor(implementation));
    }
    
    private static <Type> Constructor<Type> defaultConstructor(Class<Type> implementation) {
        try {
            return implementation.getDeclaredConstructor();
        } catch (NoSuchMethodException e) {
            throw new IllegalComponentException();
        }
    }
    
    private static <T> List<T> traverse(Class<?> component, BiFunction<List<T>, Class<?>, List<T>> finder) {
        List<T> members = new ArrayList<>();
        Class<?> current = component;
        while (current != Object.class) {
            members.addAll(finder.apply(members, current));
            current = current.getSuperclass();
        }
        return members;
    }
    
    private static <T extends AnnotatedElement> Stream<T> injectable(T[] declaredFields) {
        return stream(declaredFields).filter(f -> f.isAnnotationPresent(Inject.class));
    }
    
    private static boolean isOverride(Method m, Method o) {
        return o.getName().equals(m.getName()) && Arrays.equals(o.getParameterTypes(), m.getParameterTypes());
    }
    
    private static <T> boolean isOverrideByNoInjectMethod(Class<T> component, Method m) {
        return stream(component.getDeclaredMethods()).filter(m1 -> !m1.isAnnotationPresent(Inject.class)).noneMatch(o -> isOverride(m, o));
    }
    
    private static boolean isOverrideByInjectMethod(List<Method> injectMethods, Method m) {
        return injectMethods.stream().noneMatch(o -> isOverride(m, o));
    }
    
    private static Object[] toDependencies(Context context, Executable executable) {
        return stream(executable.getParameters()).map(p -> toDependency(context, p.getParameterizedType())).toArray(Object[]::new);
    }
    
    private static Object toDependency(Context context, Field field) {
        return toDependency(context, field.getGenericType());
    }
    
    private static Object toDependency(Context context, Type type) {
        return context.get(type).get();
    }
}

Context.java: 

package geektime.tdd.di;

import java.lang.reflect.Type;
import java.util.Optional;

public interface Context {

    Optional get(Type type);
}

ContextConfig.java:

package geektime.tdd.di;

import jakarta.inject.Provider;
import java.lang.reflect.ParameterizedType;
import java.lang.reflect.Type;
import java.util.*;
import static java.util.List.of;

public class ContextConfig {
    private Map<Class<?>, ComponentProvider<?>> providers = new HashMap<>();
    
    public <Type> void bind(Class<Type> type, Type instance) {
        providers.put(type, (ComponentProvider<Type>) context -> instance);
    }
    
    public <Type, Implementation extends Type>
    void bind(Class<Type> type, Class<Implementation> implementation) {
        providers.put(type, new InjectionProvider<>(implementation));
    }
    
    public Context getContext() {
        providers.keySet().forEach(component -> checkDependencies(component, new Stack<>()));
        return new Context() {
            @Override
            public Optional get(Type type) {
                if (isContainerType(type)) return getContainer((ParameterizedType) type);
                return getComponent((Class<?>) type);
            }
            private <Type> Optional<Type> getComponent(Class<Type> type) {
                return Optional.ofNullable(providers.get(type)).map(provider -> (Type) provider.get(this));
            }
            private Optional getContainer(ParameterizedType type) {
                if (type.getRawType() != Provider.class) return Optional.empty();
                return Optional.ofNullable(providers.get(getComponentType(type)))
                        .map(provider -> (Provider<Object>) () -> provider.get(this));
            }
        };
    }
    
    private Class<?> getComponentType(Type type) {
        return (Class<?>) ((ParameterizedType) type).getActualTypeArguments()[0];
    }
    
    private boolean isContainerType(Type type) {
        return type instanceof ParameterizedType;
    }
    
    private void checkDependencies(Class<?> component, Stack<Class<?>> visiting) {
        for (Type dependency : providers.get(component).getDependencies()) {
            if (isContainerType(dependency)) checkContainerTypeDependency(component, dependency);
            else checkComponentDependency(component, visiting, (Class<?>) dependency);
        }
    }
    
    private void checkContainerTypeDependency(Class<?> component, Type dependency) {
        if (!providers.containsKey(getComponentType(dependency)))
            throw new DependencyNotFoundException(component, getComponentType(dependency));
    }
    
    private void checkComponentDependency(Class<?> component, Stack<Class<?>> visiting, Class<?> dependency) {
        if (!providers.containsKey(dependency)) throw new DependencyNotFoundException(component, dependency);
        if (visiting.contains(dependency)) throw new CyclicDependenciesFoundException(visiting);
        visiting.push(dependency);
        checkDependencies(dependency, visiting);
        visiting.pop();
    }
    
    interface ComponentProvider<T> {
        T get(Context context);
        default List<Type> getDependencies() {
            return of();
        }
    }
}
```

任务列表的状态为：

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
  - 如果字段为final则抛出异常
  - 依赖中应包含Inject Field声明的依赖
- 方法注入
  
  - 通过Inject标注的方法，其参数为依赖组件
  - 通过Inject标注的无参数方法，会被调用
  - 按照子类中的规则，覆盖父类中的Inject方法
  - 如果方法定义类型参数，则抛出异常
  - 依赖中应包含Inject Method声明的依赖
- 对Provider类型的依赖
  
  - 从容器中取得组件的Provider（新增任务）
  - 注入构造函数中可以声明对于Provider的依赖
  - 注入字段中可以声明对于Provider的依赖
  - 注入方法中可声明对于Provider的依赖
  - 将构造函数中的Provider加入依赖（新增任务）
  - 将字段中的Provider加入依赖（新增任务）
  - 将方法中的Provider加入依赖（新增任务）
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

1. 如果我们选择行为封装会怎样？
2. 课程更新快三个月了，你在写代码上有什么进步或变化吗？

**编辑来信**：

> 第二期“TDD·代码评点”活动启动啦！为了帮助你更平滑地过渡到第三个实战项目，徐老师发起了代码评点活动。  
> 　  
> 你可以填写[学习问卷](https://jinshuju.net/f/fnh84B)提交项目代码，而后，徐老师会一一查看，并进行评点与答疑。关于评点的详细内容，我们也将制成加餐展示在专栏里，供其他同学学习与参考。  
> 　  
> 请注意，此次收集时间截至5月27日晚上12点。此外，我也会从中选出1-2位同学，送出《重构与模式》一书。请抓紧上车，入股不亏哦！

欢迎把你的想法分享在留言区，也欢迎把你的项目代码的链接分享出来。相信经过你的思考与实操，学习效果会更好！
<div><strong>精选留言（9）</strong></div><ul>
<li><span>aoe</span> 👍（6） 💬（0）<p>1.  经常使用 inLine、extra修改代码
2. 感觉 Idea 的重构快捷键功能比 Copilot 插件更强大，写代码更开心了
3. 在工作中使用 TDD 整体开发效率提高了很多（再也不用在一堆日志中找 Bug 了）
4. 当需求变更或者有更好的想法时可以放心的重构代码，实现了《代码整洁之道》中提到的“最好的重构时机就是：即时重构”
5. 发现了自己对如何写出易维护、易使用的代码几乎没有经验，正在通过 2 种方式努力：一、跟着老师敲代码，在大师的熏陶下成长；二、通过阅读书籍，了解一下基础知识

已读：《代码整洁之道》、《测试驱动开发的艺术》、《Java 测试驱动开发》
在读：《修改代码的艺术》、《领域特定语言》
待读：《重构与模式》、《重构：改善既有代码的设计》、《Google软件测试之道》、《分析模式》、《领域驱动设计精粹》、《实现领域驱动设计》

我收集的书单 https:&#47;&#47;wyyl1.com&#47;post&#47;3&#47;1
</p>2022-05-20</li><br/><li><span>人间四月天</span> 👍（3） 💬（0）<p>我都是看了2遍，然后再敲一遍，感受一下TDD威力，其实，还能学学重构，很多时候，不敢对烂代码下手。
重构除掉坏味道，重构到设计，重构到模式。
</p>2022-05-11</li><br/><li><span>枫中的刀剑</span> 👍（1） 💬（0）<p>这节老师最后提到的一个细节就是对于API的优化，应该要让API的使用尽可能的友好。这点好像在平时中很少注意，但往往就在这些细微之处才是专业的体现。</p>2022-05-28</li><br/><li><span>张铁林</span> 👍（1） 💬（0）<p>以前看的很多tdd都是kata一类的，就是逻辑比较短，还体会不到太多的TDD的好处，以及它的威力。通过老师这个项目的学习，学到了很多。本节代码已经跟着敲完了，有需要参考https:&#47;&#47;github.com&#47;vfbiby&#47;tdd-di-container&#47;tree&#47;master</p>2022-05-11</li><br/><li><span>蝴蝶</span> 👍（0） 💬（0）<p>这操作好Sao啊.jpg</p>2022-09-01</li><br/><li><span>大碗</span> 👍（0） 💬（0）<p>assertArrayEquals dependencies 为啥抽成一个方法呢，重复修改好多次了</p>2022-08-22</li><br/><li><span>davix</span> 👍（0） 💬（0）<p>這個項目從頭TDD，有全面的測試覆蓋，否則敢這麼多重構（再設計）嗎</p>2022-08-20</li><br/><li><span>tdd学徒</span> 👍（0） 💬（0）<p>照着写的时候，错把Ref构造函数里面的
this.container = container.getRawType(); 写成了 this.container = container；
一运行出错了，顿时有点慌，但是因为有测试，立马回退，然后加一行，跑一下测试，很快就发现问题了</p>2022-05-20</li><br/><li><span>Geek_wip5z8</span> 👍（0） 💬（0）<p>1. 学会了很多重构的小技巧，IDE的快捷键，理解了为啥重构和测试是紧密相连的。
2. 读了很多关于测试的书，里面讲到测试的抗重构性，行为验证不如状态验证，抗重构性高，学到27讲算是体会到了。</p>2022-05-11</li><br/>
</ul>