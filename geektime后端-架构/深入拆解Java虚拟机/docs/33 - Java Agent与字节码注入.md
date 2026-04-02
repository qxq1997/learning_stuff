关于Java agent，大家可能都听过大名鼎鼎的`premain`方法。顾名思义，这个方法指的就是在`main`方法之前执行的方法。

```
package org.example;

public class MyAgent {
  public static void premain(String args) {
    System.out.println("premain");
  }
}
```

我在上面这段代码中定义了一个`premain`方法。这里需要注意的是，Java虚拟机所能识别的`premain`方法接收的是字符串类型的参数，而并非类似于`main`方法的字符串数组。

为了能够以Java agent的方式运行该`premain`方法，我们需要将其打包成jar包，并在其中的MANIFEST.MF配置文件中，指定所谓的`Premain-class`。具体的命令如下所示：

```
# 注意第一条命令会向manifest.txt文件写入两行数据，其中包括一行空行
$ echo 'Premain-Class: org.example.MyAgent
' > manifest.txt
$ jar cvmf manifest.txt myagent.jar org/
$ java -javaagent:myagent.jar HelloWorld
premain
Hello, World
```

除了在命令行中指定Java agent之外，我们还可以通过Attach API远程加载。具体用法如下面的代码所示：

```
import java.io.IOException;

import com.sun.tools.attach.*;

public class AttachTest {
  public static void main(String[] args)
      throws AttachNotSupportedException, IOException, AgentLoadException, AgentInitializationException {
    if (args.length <= 1) {
      System.out.println("Usage: java AttachTest <PID> /PATH/TO/AGENT.jar");
      return;
    }
    VirtualMachine vm = VirtualMachine.attach(args[0]);
    vm.loadAgent(args[1]);
  }
}

```

使用Attach API远程加载的Java agent不会再先于`main`方法执行，这取决于另一虚拟机调用Attach API的时机。并且，它运行的也不再是`premain`方法，而是名为`agentmain`的方法。

```
public class MyAgent { 
  public static void agentmain(String args) {
    System.out.println("agentmain");
  }
}
```

相应的，我们需要更新jar包中的manifest文件，使其包含`Agent-Class`的配置，例如`Agent-Class: org.example.MyAgent`。

```
$ echo 'Agent-Class: org.example.MyAgent
' > manifest.txt
$ jar cvmf manifest.txt myagent.jar org/
$ java HelloWorld
Hello, World
$ jps
$ java AttachTest <pid> myagent.jar
agentmain
// 最后一句输出来自于运行HelloWorld的Java进程
```

Java虚拟机并不限制Java agent的数量。你可以在java命令后附上多个`-javaagent`参数，或者远程attach多个Java agent，Java虚拟机会按照定义顺序，或者attach的顺序逐个执行这些Java agent。

在`premain`方法或者`agentmain`方法中打印一些字符串并不出奇，我们完全可以将其中的逻辑并入`main`方法，或者其他监听端口的线程中。除此之外，Java agent还提供了一套instrumentation机制，允许应用程序拦截类加载事件，并且更改该类的字节码。

接下来，我们来了解一下基于这一机制的字节码注入。

## 字节码注入

```
package org.example;

import java.lang.instrument.*;
import java.security.ProtectionDomain;

public class MyAgent {
  public static void premain(String args, Instrumentation instrumentation) {
    instrumentation.addTransformer(new MyTransformer());
  }

  static class MyTransformer implements ClassFileTransformer {
    public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined,
        ProtectionDomain protectionDomain, byte[] classfileBuffer) throws IllegalClassFormatException {
      System.out.printf("Loaded %s: 0x%X%X%X%X\n", className, classfileBuffer[0], classfileBuffer[1],
          classfileBuffer[2], classfileBuffer[3]);
      return null;
    }
  }
}
```

我们先来看一个例子。在上面这段代码中，`premain`方法多出了一个`Instrumentation`类型的参数，我们可以通过它来注册类加载事件的拦截器。该拦截器需要实现`ClassFileTransformer`接口，并重写其中的`transform`方法。

`transform`方法将接收一个byte数组类型的参数，它代表的是正在被加载的类的字节码。在上面这段代码中，我将打印该数组的前四个字节，也就是Java class文件的魔数（magic number）0xCAFEBABE。

`transform`方法将返回一个byte数组，代表更新过后的类的字节码。当方法返回之后，Java虚拟机会使用所返回的byte数组，来完成接下来的类加载工作。不过，如果`transform`方法返回null或者抛出异常，那么Java虚拟机将使用原来的byte数组完成类加载工作。

基于这一类加载事件的拦截功能，我们可以实现字节码注入（bytecode instrumentation），往正在被加载的类中插入额外的字节码。

在工具篇中我曾经介绍过字节码工程框架ASM的用法。下面我将演示它的[tree包](https://search.maven.org/artifact/org.ow2.asm/asm-tree/7.0-beta/jar)（依赖于[基础包](https://search.maven.org/artifact/org.ow2.asm/asm/7.0-beta/jar)），用面向对象的方式注入字节码。

```
package org.example;

import java.lang.instrument.*;
import java.security.ProtectionDomain;
import org.objectweb.asm.*;
import org.objectweb.asm.tree.*;

public class MyAgent {
  public static void premain(String args, Instrumentation instrumentation) {
    instrumentation.addTransformer(new MyTransformer());
  }

  static class MyTransformer implements ClassFileTransformer, Opcodes {
    public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined,
        ProtectionDomain protectionDomain, byte[] classfileBuffer) throws IllegalClassFormatException {
      ClassReader cr = new ClassReader(classfileBuffer);
      ClassNode classNode = new ClassNode(ASM7);
      cr.accept(classNode, ClassReader.SKIP_FRAMES);

      for (MethodNode methodNode : classNode.methods) {
        if ("main".equals(methodNode.name)) {
          InsnList instrumentation = new InsnList();
          instrumentation.add(new FieldInsnNode(GETSTATIC, "java/lang/System", "out", "Ljava/io/PrintStream;"));
          instrumentation.add(new LdcInsnNode("Hello, Instrumentation!"));
          instrumentation
              .add(new MethodInsnNode(INVOKEVIRTUAL, "java/io/PrintStream", "println", "(Ljava/lang/String;)V", false));

          methodNode.instructions.insert(instrumentation);
        }
      }

      ClassWriter cw = new ClassWriter(ClassWriter.COMPUTE_FRAMES | ClassWriter.COMPUTE_MAXS);
      classNode.accept(cw);
      return cw.toByteArray();
    }
  }
}
```

上面这段代码不难理解。我们将使用`ClassReader`读取所传入的byte数组，并将其转换成`ClassNode`。然后我们将遍历`ClassNode`中的`MethodNode`节点，也就是该类中的构造器和方法。

当遇到名字为`"main"`的方法时，我们会在方法的入口处注入`System.out.println("Hello, Instrumentation!");`。运行结果如下所示：

```
$ java -javaagent:myagent.jar -cp .:/PATH/TO/asm-7.0-beta.jar:/PATH/TO/asm-tree-7.0-beta.jar HelloWorld
Hello, Instrumentation!
Hello, World!
```

Java agent还提供了另外两个功能`redefine`和`retransform`。这两个功能针对的是已加载的类，并要求用户传入所要`redefine`或者`retransform`的类实例。

其中，`redefine`指的是舍弃原本的字节码，并替换成由用户提供的byte数组。该功能比较危险，一般用于修复出错了的字节码。

`retransform`则将针对所传入的类，重新调用所有已注册的`ClassFileTransformer`的`transform`方法。它的应用场景主要有如下两个。

第一，在执行`premain`或者`agentmain`方法前，Java虚拟机早已加载了不少类，而这些类的加载事件并没有被拦截，因此也没有被注入。使用`retransform`功能可以注入这些已加载但未注入的类。

第二，在定义了多个Java agent，多个注入的情况下，我们可能需要移除其中的部分注入。当调用`Instrumentation.removeTransformer`去除某个注入类后，我们可以调用`retransform`功能，重新从原始byte数组开始进行注入。

Java agent的这些功能都是通过JVMTI agent，也就是C agent来实现的。JVMTI是一个事件驱动的工具实现接口，通常，我们会在C agent加载后的入口方法`Agent_OnLoad`处注册各个事件的钩子（hook）方法。当Java虚拟机触发了这些事件时，便会调用对应的钩子方法。

```
JNIEXPORT jint JNICALL
Agent_OnLoad(JavaVM *vm, char *options, void *reserved);
```

举个例子，我们可以为JVMTI中的`ClassFileLoadHook`事件设置钩子，从而在C层面拦截所有的类加载事件。关于JVMTI的其他事件，你可以参考该[链接](https://docs.oracle.com/en/java/javase/11/docs/specs/jvmti.html#EventIndex)。

## 基于字节码注入的profiler

我们可以利用字节码注入来实现代码覆盖工具（例如[JaCoCo](https://www.jacoco.org/jacoco/)），或者各式各样的profiler。

通常，我们会定义一个运行时类，并在某一程序行为的周围，注入对该运行时类中方法的调用，以表示该程序行为正要发生或者已经发生。

```
package org.example;

import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

public class MyProfiler {
  public static ConcurrentHashMap<Class<?>, AtomicInteger> data = new ConcurrentHashMap<>();

  public static void fireAllocationEvent(Class<?> klass) {
    data.computeIfAbsent(klass, kls -> new AtomicInteger())
        .incrementAndGet();
  }

  public static void dump() {
    data.forEach((kls, counter) -> {
      System.err.printf("%s: %d\n", kls.getName(), counter.get());
    });
  }

  static {
    Runtime.getRuntime().addShutdownHook(new Thread(MyProfiler::dump));
  }
}
```

举个例子，上面这段代码便是一个运行时类。该类维护了一个`HashMap`，用来统计每个类所新建实例的数目。当程序退出时，我们将逐个打印出每个类的名字，以及其新建实例的数目。

在Java agent中，我们会截获正在加载的类，并且在每条`new`字节码之后插入对`fireAllocationEvent`方法的调用，以表示当前正在新建某个类的实例。具体的注入代码如下所示：

```
package org.example;

import java.lang.instrument.*;
import java.security.ProtectionDomain;

import org.objectweb.asm.*;
import org.objectweb.asm.tree.*;

public class MyAgent {

  public static void premain(String args, Instrumentation instrumentation) {
    instrumentation.addTransformer(new MyTransformer());
  }

  static class MyTransformer implements ClassFileTransformer, Opcodes {
    public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined,
        ProtectionDomain protectionDomain, byte[] classfileBuffer) throws IllegalClassFormatException {
      if (className.startsWith("java")    ||
          className.startsWith("javax")   || 
          className.startsWith("jdk")     ||
          className.startsWith("sun")     ||
          className.startsWith("com/sun") ||
          className.startsWith("org/example")) {
        // Skip JDK classes and profiler classes
        return null;
      }

      ClassReader cr = new ClassReader(classfileBuffer);
      ClassNode classNode = new ClassNode(ASM7);
      cr.accept(classNode, ClassReader.SKIP_FRAMES);

      for (MethodNode methodNode : classNode.methods) {
        for (AbstractInsnNode node : methodNode.instructions.toArray()) {
          if (node.getOpcode() == NEW) {
            TypeInsnNode typeInsnNode = (TypeInsnNode) node;

            InsnList instrumentation = new InsnList();
            instrumentation.add(new LdcInsnNode(Type.getObjectType(typeInsnNode.desc)));
            instrumentation.add(new MethodInsnNode(INVOKESTATIC, "org/example/MyProfiler", "fireAllocationEvent",
                "(Ljava/lang/Class;)V", false));

            methodNode.instructions.insert(node, instrumentation);
          }
        }
      }

      ClassWriter cw = new ClassWriter(ClassWriter.COMPUTE_FRAMES | ClassWriter.COMPUTE_MAXS);
      classNode.accept(cw);
      return cw.toByteArray();
    }
  }

}
```

你或许已经留意到，我们不得不排除对JDK类以及该运行时类的注入。这是因为，对这些类的注入很可能造成死循环调用，并最终抛出`StackOverflowException`异常。

举个例子，假设我们在`PrintStream.println`方法入口处注入`System.out.println("blahblah")`，由于`out`是`PrintStream`的实例，因此当执行注入代码时，我们又会调用`PrintStream.println`方法，从而造成死循环。

解决这一问题的关键在于设置一个线程私有的标识位，用以区分应用代码的上下文以及注入代码的上下文。当即将执行注入代码时，我们将根据标识位判断是否已经位于注入代码的上下文之中。如果不是，则设置标识位并正常执行注入代码；如果是，则直接返回，不再执行注入代码。

字节码注入的另一个技术难点则是命名空间。举个例子，不少应用程序都依赖于字节码工程库ASM。当我们的注入逻辑依赖于ASM时，便有可能出现注入使用最新版本的ASM，而应用程序使用较低版本的ASM的问题。

JDK本身也使用了ASM库，如用来生成Lambda表达式的适配器类。JDK的做法是重命名整个ASM库，为所有类的包名添加`jdk.internal`前缀。我们显然不好直接更改ASM的包名，因此需要借助自定义类加载器来隔离命名空间。

除了上述技术难点之外，基于字节码注入的工具还有另一个问题，那便是观察者效应（observer effect）对所收集的数据造成的影响。

举个利用字节码注入收集每个方法的运行时间的例子。假设某个方法调用了另一个方法，而这两个方法都被注入了，那么统计被调用者运行时间的注入代码所耗费的时间，将不可避免地被计入至调用者方法的运行时间之中。

再举一个统计新建对象数目的例子。我们知道，即时编译器中的逃逸分析可能会优化掉新建对象操作，但它不会消除相应的统计操作，比如上述例子中对`fireAllocationEvent`方法的调用。在这种情况下，我们将统计没有实际发生的新建对象操作。

另一种情况则是，我们所注入的对`fireAllocationEvent`方法的调用，将影响到方法内联的决策。如果该新建对象的构造器调用恰好因此没有被内联，从而造成对象逃逸。在这种情况下，原本能够被逃逸分析优化掉的新建对象操作将无法优化，我们也将统计到原本不会发生的新建对象操作。

总而言之，当使用字节码注入开发profiler时，需要辩证地看待所收集的数据。它仅能表示在被注入的情况下程序的执行状态，而非没有注入情况下的程序执行状态。

## 面向方面编程

说到字节码注入，就不得不提面向方面编程（Aspect-Oriented Programming，AOP）。面向方面编程的核心理念是定义切入点（pointcut）以及通知（advice）。程序控制流中所有匹配该切入点的连接点（joinpoint）都将执行这段通知代码。

举个例子，我们定义一个指代所有方法入口的切入点，并指定在该切入点执行的“打印该方法的名字”这一通知。那么每个具体的方法入口便是一个连接点。

面向方面编程的其中一种实现方式便是字节码注入，比如[AspectJ](https://www.eclipse.org/aspectj/)。

在前面的例子中，我们也相当于使用了面向方面编程，在所有的`new`字节码之后执行了下面这样一段通知代码。

```
`MyProfiler.fireAllocationEvent(<Target>.class)`
```

我曾经参与开发过一个应用了面向方面编程思想的字节码注入框架[DiSL](https://disl.ow2.org/)。它支持用注解来定义切入点，用普通Java方法来定义通知。例如，在方法入口处打印所在的方法名，可以简单表示为如下代码：

```
@Before(marker = BodyMarker.class)
static void onMethodEntry(MethodStaticContext msc) {
  System.out.println(msc.thisMethodFullName());
}
```

如果有同学对这个工具感兴趣，或者有什么需求或者建议，欢迎你在留言中提出。

## 总结与实践

今天我介绍了Java agent以及字节码注入。

我们可以通过Java agent的类加载拦截功能，修改某个类所对应的byte数组，并利用这个修改过后的byte数组完成接下来的类加载。

基于字节码注入的profiler，可以统计程序运行过程中某些行为的出现次数。如果需要收集Java核心类库的数据，那么我们需要小心避免无限递归调用。另外，我们还需通过自定义类加载器来解决命名空间的问题。

由于字节码注入会产生观察者效应，因此基于该技术的profiler所收集到的数据并不能反映程序的真实运行状态。它所反映的是程序在被注入的情况下的执行状态。

* * *

今天的实践环节，请你思考如何注入方法出口。除了正常执行路径之外，你还需考虑异常执行路径。
<div><strong>精选留言（13）</strong></div><ul>
<li><span>蚂蚁内推+v</span> 👍（13） 💬（1）<p>用attach的方式注入字节码的时候遇到了99线升高的性能问题，看一些资料说 class redefinition 的时候会阻塞线程。请问能详细讲下吗？</p>2018-11-19</li><br/><li><span>Scott</span> 👍（4） 💬（1）<p>我看到了jvmti可以回调异常事件，但是java.lang.instrument包下没有处理这个事件的，只能在load时回调，处理异常究竟是怎么做的？</p>2018-10-06</li><br/><li><span>Scott</span> 👍（4） 💬（1）<p>出方法时需要注入的字节码除了返回，还有几种情况，如果没有catch块，就拦截throw，如果有，但是catch块里面可能有很多层，只是遍历inst应该是不可以的</p>2018-10-06</li><br/><li><span>钱</span> 👍（28） 💬（1）<p>阅过留痕

1：Java agent 是啥玩意？
      这个概念老师没有详细讲解，我的理解是Java语言的一个特性，这个特性能够实现Java字节码的注入

2：Java字节码的注入有什么用处呢？
在平时编程几乎没有使用到这方面的功能，应该是在一些框架的设计的时候才使用吧！比如：专栏中提到的面相切面编程。

3：Java agent 本质上是通过 c agent 来实现的，那 c agent 本质上是怎么实现的呢？
C agent是一个事件驱动的工具实现接口，通常我们会在 C agent 加载后的入口方案 Agent_OnLoad处注册各个事件的钩子方法。当Java虚拟机触发了这些事件时，便会调用对应的钩子方法

4：留个话头
      写代码实现某些功能，我的理解有三个时间段
      第一个：源码阶段，最常用的，也是编程的主要活动时间
      第二个：字节码阶段，有些功能可能会在加载字节码时修改或者添加某些字节码，某些框架做的事情
      第三个：运行阶段，某些工具，在程序运行时修改代码，实现运行时功能分支的控制</p>2018-10-13</li><br/><li><span>feng</span> 👍（10） 💬（1）<p>第一个实验做的不严谨，第一，木有定义HelloWord类，第二，没有执行编译操作，不知道是有意为之，还是不小心把步骤漏掉了</p>2018-10-07</li><br/><li><span>the geek</span> 👍（7） 💬（0）<p>大概说一下我自己的理解(望老师指正):
1. Agent就是一个调用JVMTI函数的一个程序。
2. JVMTI能够提供的函数能够获得JVM的运行信息，还可以修改JVM的运行态。
3. JVMTI能够修改JVM运行态是因为JVM已经在运行流程中埋下了钩子函数，JVMTI中的函数可以传递具体逻辑给钩子函数。
4. JVMTI函数是C语言实现的JNI方法。
5. 通过Instrumentation我们可以用Java语言调用大部分JVMTI函数。
6. JVM在启动时会加载Agent 入口函数Agent_OnLoad,我们可以在此函数中注册Agent。
7. JVM在运行中可以通过Agent_OnAttach函数来加载Agent,我们可以在此函数中注册Agent。
8. B虚拟机调用attach方法attach到A虚拟机后，可以将Agent程序作为参数调用A虚拟机的Agent_OnAttach函数。
9. premain方法中的程序逻辑会被注册到Agent_OnLoad函数中。
10. agentmain方法中的程序逻辑会被注册到Agent_OnAttach函数中。
11. 在premain或agentmain方法中的拿到的Instrumentation引用，可以理解成拿到了JVMTI的引用(大部分函数)。

以上全是个人抽象理解，不是具体实现。</p>2020-02-12</li><br/><li><span>随心而至</span> 👍（3） 💬（0）<p>把老师给的程序都跑了一篇，发现想要彻底搞懂，还需要多学习，C&#47;C++的知识不能丢了，因为HotSpot JVM 的源码基本上都是用它来实现的。
不过跑了一下代码，最起码可以表面上搞懂了像Lombok，AOP这些都是如何实现的。</p>2019-11-01</li><br/><li><span>饭粒</span> 👍（1） 💬（0）<p>profiler 示例，文中省略了 HelloWorld.java 和编译提及下更好。
# cat HelloWorld.java 

public class HelloWorld {

    public static void main(String[] args) {
        System.out.println(&quot;Hello World!&quot;);
        HelloWorld w = new HelloWorld();
    }
}

# java -javaagent:myagent.jar -cp $CLASS_PATH:.&#47;asm-7.0-beta.jar:.&#47;asm-tree-7.0-beta.jar HelloWorld
Hello World!
HelloWorld: 1</p>2019-12-28</li><br/><li><span>一缕阳光</span> 👍（1） 💬（0）<p>实习的时候有幸做过一个利用Instrumentation实现自动打点和性能监控的项目。受益匪浅啊  哈哈哈哈  ，不得不说里面坑还是挺多的</p>2019-07-07</li><br/><li><span>奇奇</span> 👍（1） 💬（1）<p>ASM7 GETSTATIC这些常量是哪里来的？</p>2019-04-29</li><br/><li><span>吃饭</span> 👍（0） 💬（0）<p>一直不理解java的debug是怎么实现的</p>2024-06-03</li><br/><li><span>房艳</span> 👍（0） 💬（0）<p>https:&#47;&#47;www.jianshu.com&#47;p&#47;b72f66da679f 可参考</p>2021-02-02</li><br/><li><span>feng</span> 👍（0） 💬（0）<p>还有个问题想请教下，每次启动的时候都会打印如下信息，objc[2614]: Class JavaLaunchHelper is implemented in both &#47;Library&#47;Java&#47;JavaVirtualMachines&#47;jdk1.8.0_31.jdk&#47;Contents&#47;Home&#47;bin&#47;java (0x102f6f4c0) and &#47;Library&#47;Java&#47;JavaVirtualMachines&#47;jdk1.8.0_31.jdk&#47;Contents&#47;Home&#47;jre&#47;lib&#47;libinstrument.dylib (0x104f384e0). One of the two will be used. Which one is undefined.

请问怎么可以消除，谢谢</p>2018-10-07</li><br/>
</ul>