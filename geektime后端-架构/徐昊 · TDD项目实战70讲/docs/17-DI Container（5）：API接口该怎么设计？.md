你好，我是徐昊。今天我们继续使用TDD的方式实现注入依赖容器。

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
        providers.put(type, new ConstructorInjectionProvider(type, injectConstructor));
    }
    
    public <Type> Optional<Type> get(Class<Type> type) {
        return Optional.ofNullable(providers.get(type)).map(provider -> (Type) provider.get());
    }
    
    class ConstructorInjectionProvider<T> implements Provider<T> {
        private Class<?> componentType;
        private Constructor<T> injectConstructor;
        private boolean constructing = false;
        
        public ConstructorInjectionProvider(Class<?> componentType, Constructor<T> injectConstructor) {
            this.componentType = componentType;
            this.injectConstructor = injectConstructor;
        }
        
        @Override
        public T get() {
            if (constructing) throw new CyclicDependenciesFoundException(componentType);
            try {
                constructing = true;
                Object[] dependencies = stream(injectConstructor.getParameters())
                        .map(p -> Context.this.get(p.getType())
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
```

任务列表状态为：

![](https://static001.geekbang.org/resource/image/ce/a1/ce5cab496bda4a51f449689ac6bedfa1.jpg?wh=6905x10949)

## 视频演示

让我们进入今天的部分：

## 思考题

为了我们更好的交流与互动，从这节课开始，思考题目除了固定的技术问题外，我还会设置一道较为轻松的题目，供你选择与回答。

1. 在当前结构下，如何实现对循环依赖的检查？
2. 你学习这节课的方式是什么？写实现代码了吗？有遇到卡壳的地方吗？

欢迎把你的想法分享在留言区，也欢迎把你的项目代码的链接分享出来。相信经过你的思考与实操，学习效果会更好！
<div><strong>精选留言（6）</strong></div><ul>
<li><span>aoe</span> 👍（5） 💬（0）<p>这节课的重点讲的是重构：
1、构造一个更强大的新接口
2、实现类同时 implements 老接口,新接口
3、实现新接口
4、删除老接口

学习方式：
刚开始：看完所有视频后，再跟着视频敲代码。以为可以独立完成功能，实际则翻车了，自由发挥过头了，都不知道哪错了，测试横竖通不过
昨天：先看完一节课视频，再跟着视频敲代码。一个方法内，两个小细节，花了两个小时找bug
今天：边看视频边敲代码，战战兢兢，一次通过

卡克：
虽然没有完全理解 DI 的实现思路，无脑跟着老师敲代码，也略有感悟：原来 TDD 是这样啊！</p>2022-04-20</li><br/><li><span>奇小易</span> 👍（3） 💬（0）<p>思考题一：

递归思路：
找出一个组件的所有依赖。
判断所有依赖中是否存在当前组件。
存在则抛循环依赖。
不存在则将依赖当成组件来进行第一步操作。（未实现）


思考题二：
你学习这节课的方式是什么？写实现代码了吗？有遇到卡壳的地方吗？
以每个小步为一个单元。
看完老师的演示。
理解老师的意图。
自己尝试复现。
不行就回看老师的内容，复现结果。
如此往复，完成该课程内容。

</p>2022-05-16</li><br/><li><span>leesper</span> 👍（0） 💬（0）<p>我在学这一部分课的时候记录了两个进度：读进度和写进度。读进度用来跟着老师听课，写进度用来跟着老师敲代码</p>2023-02-01</li><br/><li><span>davix</span> 👍（0） 💬（0）<p>其實第二個重構保持Provider的名字改動很小。
```
@@ -1,7 +1,6 @@
 package geektime.tdd.di;
 
 import jakarta.inject.Inject;
-import jakarta.inject.Provider;
 
 import java.lang.reflect.Constructor;
 import java.lang.reflect.InvocationTargetException;
@@ -16,8 +15,12 @@ import static java.util.Arrays.stream;
 public class ContextConfig {
     private Map&lt;Class&lt;?&gt;, Provider&lt;?&gt;&gt; providers = new HashMap&lt;&gt;();
 
+    interface Provider&lt;T&gt; {
+        T get(Context context);
+    }
+
     public &lt;T&gt; void bind(Class&lt;T&gt; type, T instance) {
-        providers.put(type, (Provider&lt;T&gt;) () -&gt; instance);
+        providers.put(type, (Provider&lt;T&gt;) context -&gt; instance);
     }
 
     public &lt;T, Impl extends T&gt; void bind(Class&lt;T&gt; type, Class&lt;Impl&gt; implementation) {
@@ -30,7 +33,7 @@ public class ContextConfig {
         return new Context() {
             @Override
             public &lt;T&gt; Optional&lt;T&gt; get(Class&lt;T&gt; type) {
-                return Optional.ofNullable(providers.get(type)).map(p -&gt; (T) p.get());
+                return Optional.ofNullable(providers.get(type)).map(p -&gt; (T) p.get(this));
             }
         };
     }
@@ -46,12 +49,12 @@ public class ContextConfig {
         }
 
         @Override
-        public T get() {
+        public T get(Context context) {
             if (constructing) throw new CyclicDependenciesFound(type);
             try {
                 constructing = true;
                 Object[] dependencies = stream(constructor.getParameters())
-                        .map(p -&gt; getContext().get(p.getType()).orElseThrow(() -&gt; new DependencyNotFoundException(type, p.getType())))
+                        .map(p -&gt; context.get(p.getType()).orElseThrow(() -&gt; new DependencyNotFoundException(type, p.getType())))
                         .toArray(Object[]::new);
                 return (T) constructor.newInstance(dependencies);
             } catch (CyclicDependenciesFound e) {
```</p>2022-06-09</li><br/><li><span>新的一页</span> 👍（0） 💬（0）<p>回答：
1. 我在provider定义了一个check方法，检查循环依赖和依赖未找到；获取上下文的时候循环调用provider中的check方法；check方法的实现和原先的在get中去检查方法一致。
2. 我学习课程的方法是先按照课程的标题 &#47; 课后思考题来做自己的实现，遇到自己对于实现思路不清晰的时候，先会去网上搜搜一般DI框架是怎么做的，然后在依据已有的代码构造一下思路，如果发现构思后的路径和现有的代码逻辑有重大冲突的时候，就会去看看老师的视频，验证是否会有无大结构调整的实现方法，如果发现实现思路和自己想的一致，就会停下视频，自己做实现，实现后再去看视频补充一些自己没考虑到的细节还有代码实现的结构等问题。
问题2举例，在bind的时候做循环依赖的检查必定是失败的，因为总会有一个依赖不存在，然后抛出的异常是DependencyNotFound，这个时候就要引入类似生命周期的概念，在初始化的时候去检查，这时候就会有大的代码结构调整，我在这个时候就会去看下视频，验证下自己的思路是否和老师的一致。</p>2022-05-09</li><br/><li><span>ACE丶8</span> 👍（0） 💬（0）<p>1.在查找依赖的时候，把查找到的依赖都添加到一个set集合中，递归查找的时候传递set，判断set是否已经存在
2.跟着老师敲~~</p>2022-04-28</li><br/>
</ul>