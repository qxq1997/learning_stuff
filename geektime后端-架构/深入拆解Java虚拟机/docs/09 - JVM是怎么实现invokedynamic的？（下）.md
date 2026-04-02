上回讲到，为了让所有的动物都能参加赛马，Java 7引入了invokedynamic机制，允许调用任意类的“赛跑”方法。不过，我们并没有讲解invokedynamic，而是深入地探讨了它所依赖的方法句柄。

今天，我便来正式地介绍invokedynamic指令，讲讲它是如何生成调用点，并且允许应用程序自己决定链接至哪一个方法中的。

## invokedynamic指令

invokedynamic是Java 7引入的一条新指令，用以支持动态语言的方法调用。具体来说，它将调用点（CallSite）抽象成一个Java类，并且将原本由Java虚拟机控制的方法调用以及方法链接暴露给了应用程序。在运行过程中，每一条invokedynamic指令将捆绑一个调用点，并且会调用该调用点所链接的方法句柄。

在第一次执行invokedynamic指令时，Java虚拟机会调用该指令所对应的启动方法（BootStrap Method），来生成前面提到的调用点，并且将之绑定至该invokedynamic指令中。在之后的运行过程中，Java虚拟机则会直接调用绑定的调用点所链接的方法句柄。

在字节码中，启动方法是用方法句柄来指定的。这个方法句柄指向一个返回类型为调用点的静态方法。该方法必须接收三个固定的参数，分别为一个Lookup类实例，一个用来指代目标方法名字的字符串，以及该调用点能够链接的方法句柄的类型。

除了这三个必需参数之外，启动方法还可以接收若干个其他的参数，用来辅助生成调用点，或者定位所要链接的目标方法。

```
import java.lang.invoke.*;

class Horse {
  public void race() {
    System.out.println("Horse.race()"); 
  }
}

class Deer {
  public void race() {
    System.out.println("Deer.race()");
  }
}

// javac Circuit.java
// java Circuit
public class Circuit {

  public static void startRace(Object obj) {
    // aload obj
    // invokedynamic race()
  }

  public static void main(String[] args) {
    startRace(new Horse());
    // startRace(new Deer());
  }
  
  public static CallSite bootstrap(MethodHandles.Lookup l, String name, MethodType callSiteType) throws Throwable {
    MethodHandle mh = l.findVirtual(Horse.class, name, MethodType.methodType(void.class));
    return new ConstantCallSite(mh.asType(callSiteType));
  }
}
```

我在文稿中贴了一段代码，其中便包含一个启动方法。它将接收前面提到的三个固定参数，并且返回一个链接至Horse.race方法的ConstantCallSite。

这里的ConstantCallSite是一种不可以更改链接对象的调用点。除此之外，Java核心类库还提供多种可以更改链接对象的调用点，比如MutableCallSite和VolatileCallSite。

这两者的区别就好比正常字段和volatile字段之间的区别。此外，应用程序还可以自定义调用点类，来满足特定的重链接需求。

由于Java暂不支持直接生成invokedynamic指令\[1]，所以接下来我会借助之前介绍过的字节码工具ASM来实现这一目的。

```
import java.io.IOException;
import java.lang.invoke.*;
import java.nio.file.*;

import org.objectweb.asm.*;

// javac -cp /path/to/asm-all-6.0_BETA.jar:. ASMHelper.java
// java -cp /path/to/asm-all-6.0_BETA.jar:. ASMHelper
// java Circuit
public class ASMHelper implements Opcodes {

  private static class MyMethodVisitor extends MethodVisitor {

    private static final String BOOTSTRAP_CLASS_NAME = Circuit.class.getName().replace('.', '/');
    private static final String BOOTSTRAP_METHOD_NAME = "bootstrap";
    private static final String BOOTSTRAP_METHOD_DESC = MethodType
        .methodType(CallSite.class, MethodHandles.Lookup.class, String.class, MethodType.class)
        .toMethodDescriptorString();

    private static final String TARGET_METHOD_NAME = "race";
    private static final String TARGET_METHOD_DESC = "(Ljava/lang/Object;)V";

    public final MethodVisitor mv;

    public MyMethodVisitor(int api, MethodVisitor mv) {
      super(api);
      this.mv = mv;
    }

    @Override
    public void visitCode() {
      mv.visitCode();
      mv.visitVarInsn(ALOAD, 0);
      Handle h = new Handle(H_INVOKESTATIC, BOOTSTRAP_CLASS_NAME, BOOTSTRAP_METHOD_NAME, BOOTSTRAP_METHOD_DESC, false);
      mv.visitInvokeDynamicInsn(TARGET_METHOD_NAME, TARGET_METHOD_DESC, h);
      mv.visitInsn(RETURN);
      mv.visitMaxs(1, 1);
      mv.visitEnd();
    }
  }

  public static void main(String[] args) throws IOException {
    ClassReader cr = new ClassReader("Circuit");
    ClassWriter cw = new ClassWriter(cr, ClassWriter.COMPUTE_FRAMES);
    ClassVisitor cv = new ClassVisitor(ASM6, cw) {
      @Override
      public MethodVisitor visitMethod(int access, String name, String descriptor, String signature,
          String[] exceptions) {
        MethodVisitor visitor = super.visitMethod(access, name, descriptor, signature, exceptions);
        if ("startRace".equals(name)) {
          return new MyMethodVisitor(ASM6, visitor);
        }
        return visitor;
      }
    };
    cr.accept(cv, ClassReader.SKIP_FRAMES);

    Files.write(Paths.get("Circuit.class"), cw.toByteArray());
  }
}
```

你无需理解上面这段代码的具体含义，只须了解它会更改同一目录下Circuit类的startRace(Object)方法，使之包含invokedynamic指令，执行所谓的赛跑方法。

```
 public static void startRace(java.lang.Object);
         0: aload_0
         1: invokedynamic #80,  0 // race:(Ljava/lang/Object;)V
         6: return
```

如果你足够细心的话，你会发现该指令所调用的赛跑方法的描述符，和Horse.race方法或者Deer.race方法的描述符并不一致。这是因为invokedynamic指令最终调用的是方法句柄，而方法句柄会将调用者当成第一个参数。因此，刚刚提到的那两个方法恰恰符合这个描述符所对应的方法句柄类型。

到目前为止，我们已经可以通过invokedynamic调用Horse.race方法了。为了支持调用任意类的race方法，我实现了一个简单的单态内联缓存。如果调用者的类型命中缓存中的类型，便直接调用缓存中的方法句柄，否则便更新缓存。

```
// 需要更改ASMHelper.MyMethodVisitor中的BOOTSTRAP_CLASS_NAME
import java.lang.invoke.*;

public class MonomorphicInlineCache {

  private final MethodHandles.Lookup lookup;
  private final String name;

  public MonomorphicInlineCache(MethodHandles.Lookup lookup, String name) {
    this.lookup = lookup;
    this.name = name;
  }

  private Class<?> cachedClass = null;
  private MethodHandle mh = null;

  public void invoke(Object receiver) throws Throwable {
    if (cachedClass != receiver.getClass()) {
      cachedClass = receiver.getClass();
      mh = lookup.findVirtual(cachedClass, name, MethodType.methodType(void.class));
    }
    mh.invoke(receiver);
  }

  public static CallSite bootstrap(MethodHandles.Lookup l, String name, MethodType callSiteType) throws Throwable {
    MonomorphicInlineCache ic = new MonomorphicInlineCache(l, name);
    MethodHandle mh = l.findVirtual(MonomorphicInlineCache.class, "invoke", MethodType.methodType(void.class, Object.class));
    return new ConstantCallSite(mh.bindTo(ic));
  }
}
```

可以看到，尽管invokedynamic指令调用的是所谓的race方法，但是实际上我返回了一个链接至名为“invoke”的方法的调用点。由于调用点仅要求方法句柄的类型能够匹配，因此这个链接是合法的。

不过，这正是invokedynamic的目的，也就是将调用点与目标方法的链接交由应用程序来做，并且依赖于应用程序对目标方法进行验证。所以，如果应用程序将赛跑方法链接至兔子的睡觉方法，那也只能怪应用程序自己了。

## Java 8的Lambda表达式

在Java 8中，Lambda表达式也是借助invokedynamic来实现的。

具体来说，Java编译器利用invokedynamic指令来生成实现了函数式接口的适配器。这里的函数式接口指的是仅包括一个非default接口方法的接口，一般通过@FunctionalInterface注解。不过就算是没有使用该注解，Java编译器也会将符合条件的接口辨认为函数式接口。

```
int x = ..
IntStream.of(1, 2, 3).map(i -> i * 2).map(i -> i * x);
```

举个例子，上面这段代码会对IntStream中的元素进行两次映射。我们知道，映射方法map所接收的参数是IntUnaryOperator（这是一个函数式接口）。也就是说，在运行过程中我们需要将i-&gt;i*2和i-&gt;i*x 这两个Lambda表达式转化成IntUnaryOperator的实例。这个转化过程便是由invokedynamic来实现的。

在编译过程中，Java编译器会对Lambda表达式进行解语法糖（desugar），生成一个方法来保存Lambda表达式的内容。该方法的参数列表不仅包含原本Lambda表达式的参数，还包含它所捕获的变量。(注：方法引用，如Horse::race，则不会生成生成额外的方法。)

在上面那个例子中，第一个Lambda表达式没有捕获其他变量，而第二个Lambda表达式（也就是i-&gt;i\*x）则会捕获局部变量x。这两个Lambda表达式对应的方法如下所示。可以看到，所捕获的变量同样也会作为参数传入生成的方法之中。

```
  // i -> i * 2
  private static int lambda$0(int);
    Code:
       0: iload_0
       1: iconst_2
       2: imul
       3: ireturn

  // i -> i * x
  private static int lambda$1(int, int);
    Code:
       0: iload_1
       1: iload_0
       2: imul
       3: ireturn
```

第一次执行invokedynamic指令时，它所对应的启动方法会通过ASM来生成一个适配器类。这个适配器类实现了对应的函数式接口，在我们的例子中，也就是IntUnaryOperator。启动方法的返回值是一个ConstantCallSite，其链接对象为一个返回适配器类实例的方法句柄。

根据Lambda表达式是否捕获其他变量，启动方法生成的适配器类以及所链接的方法句柄皆不同。

如果该Lambda表达式没有捕获其他变量，那么可以认为它是上下文无关的。因此，启动方法将新建一个适配器类的实例，并且生成一个特殊的方法句柄，始终返回该实例。

如果该Lambda表达式捕获了其他变量，那么每次执行该invokedynamic指令，我们都要更新这些捕获了的变量，以防止它们发生了变化。

另外，为了保证Lambda表达式的线程安全，我们无法共享同一个适配器类的实例。因此，在每次执行invokedynamic指令时，所调用的方法句柄都需要新建一个适配器类实例。

在这种情况下，启动方法生成的适配器类将包含一个额外的静态方法，来构造适配器类的实例。该方法将接收这些捕获的参数，并且将它们保存为适配器类实例的实例字段。

你可以通过虚拟机参数-Djdk.internal.lambda.dumpProxyClasses=/DUMP/PATH导出这些具体的适配器类。这里我导出了上面这个例子中两个Lambda表达式对应的适配器类。

```
// i->i*2 对应的适配器类
final class LambdaTest$$Lambda$1 implements IntUnaryOperator {
 private LambdaTest$$Lambda$1();
  Code:
    0: aload_0
    1: invokespecial java/lang/Object."<init>":()V
    4: return

 public int applyAsInt(int);
  Code:
    0: iload_1
    1: invokestatic LambdaTest.lambda$0:(I)I
    4: ireturn
}

// i->i*x 对应的适配器类
final class LambdaTest$$Lambda$2 implements IntUnaryOperator {
 private final int arg$1;

 private LambdaTest$$Lambda$2(int);
  Code:
    0: aload_0
    1: invokespecial java/lang/Object."<init>":()V
    4: aload_0
    5: iload_1
    6: putfield arg$1:I
    9: return

 private static java.util.function.IntUnaryOperator get$Lambda(int);
  Code:
    0: new LambdaTest$$Lambda$2
    3: dup
    4: iload_0
    5: invokespecial "<init>":(I)V
    8: areturn

 public int applyAsInt(int);
  Code:
    0: aload_0
    1: getfield arg$1:I
    4: iload_1
    5: invokestatic LambdaTest.lambda$1:(II)I
    8: ireturn
}
```

可以看到，捕获了局部变量的Lambda表达式多出了一个get$Lambda的方法。启动方法便会所返回的调用点链接至指向该方法的方法句柄。也就是说，每次执行invokedynamic指令时，都会调用至这个方法中，并构造一个新的适配器类实例。

这个多出来的新建实例会对程序性能造成影响吗？

## Lambda以及方法句柄的性能分析

我再次请出测试反射调用性能开销的那段代码，并将其改造成使用Lambda表达式的v6版本。

```
// v6版本
import java.util.function.IntConsumer;

public class Test {
  public static void target(int i) { }

  public static void main(String[] args) throws Exception {
    long current = System.currentTimeMillis();
    for (int i = 1; i <= 2_000_000_000; i++) {
      if (i % 100_000_000 == 0) {
        long temp = System.currentTimeMillis();
        System.out.println(temp - current);
        current = temp;
      }

      ((IntConsumer) j -> Test.target(j)).accept(128);
      // ((IntConsumer) Test::target.accept(128);
    }
  }
}
```

测量结果显示，它与直接调用的性能并无太大的区别。也就是说，即时编译器能够将转换Lambda表达式所使用的invokedynamic，以及对IntConsumer.accept方法的调用统统内联进来，最终优化为空操作。

这个其实不难理解：Lambda表达式所使用的invokedynamic将绑定一个ConstantCallSite，其链接的目标方法无法改变。因此，即时编译器会将该目标方法直接内联进来。对于这类没有捕获变量的Lambda表达式而言，目标方法只完成了一个动作，便是加载缓存的适配器类常量。

另一方面，对IntConsumer.accept方法的调用实则是对适配器类的accept方法的调用。

如果你查看了accept方法对应的字节码的话，你会发现它仅包含一个方法调用，调用至Java编译器在解Lambda语法糖时生成的方法。

该方法的内容便是Lambda表达式的内容，也就是直接调用目标方法Test.target。将这几个方法调用内联进来之后，原本对accept方法的调用则会被优化为空操作。

下面我将之前的代码更改为带捕获变量的v7版本。理论上，每次调用invokedynamic指令，Java虚拟机都会新建一个适配器类的实例。然而，实际运行结果还是与直接调用的性能一致。

```
// v7版本
import java.util.function.IntConsumer;

public class Test {
  public static void target(int i) { }

  public static void main(String[] args) throws Exception {
    int x = 2;

    long current = System.currentTimeMillis();
    for (int i = 1; i <= 2_000_000_000; i++) {
      if (i % 100_000_000 == 0) {
        long temp = System.currentTimeMillis();
        System.out.println(temp - current);
        current = temp;
      }

      ((IntConsumer) j -> Test.target(x + j)).accept(128);
    }
  }
}
```

显然，即时编译器的逃逸分析又将该新建实例给优化掉了。我们可以通过虚拟机参数-XX:-DoEscapeAnalysis来关闭逃逸分析。果然，这时候测得的值约为直接调用的2.5倍。

尽管逃逸分析能够去除这些额外的新建实例开销，但是它也不是时时奏效。它需要同时满足两件事：invokedynamic指令所执行的方法句柄能够内联，和接下来的对accept方法的调用也能内联。

只有这样，逃逸分析才能判定该适配器实例不逃逸。否则，我们会在运行过程中不停地生成适配器类实例。所以，我们应当尽量使用非捕获的Lambda表达式。

## 总结与实践

今天我介绍了invokedynamic指令以及Lambda表达式的实现。

invokedymaic指令抽象出调用点的概念，并且将调用该调用点所链接的方法句柄。在第一次执行invokedynamic指令时，Java虚拟机将执行它所对应的启动方法，生成并且绑定一个调用点。之后如果再次执行该指令，Java虚拟机则直接调用已经绑定了的调用点所链接的方法。

Lambda表达式到函数式接口的转换是通过invokedynamic指令来实现的。该invokedynamic指令对应的启动方法将通过ASM生成一个适配器类。

对于没有捕获其他变量的Lambda表达式，该invokedynamic指令始终返回同一个适配器类的实例。对于捕获了其他变量的Lambda表达式，每次执行invokedynamic指令将新建一个适配器类实例。

不管是捕获型的还是未捕获型的Lambda表达式，它们的性能上限皆可以达到直接调用的性能。其中，捕获型Lambda表达式借助了即时编译器中的逃逸分析，来避免实际的新建适配器类实例的操作。

在上一篇的课后实践中，你应该测过这一段代码的性能开销了。我这边测得的结果约为直接调用的3.5倍。

```
// v8版本
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;

public class Test {
  public static void target(int i) { }

  public static void main(String[] args) throws Exception {
    MethodHandles.Lookup l = MethodHandles.lookup();
    MethodType t = MethodType.methodType(void.class, int.class);
    MethodHandle mh = l.findStatic(Test.class, "target", t);

    long current = System.currentTimeMillis();
    for (int i = 1; i <= 2_000_000_000; i++) {
      if (i % 100_000_000 == 0) {
        long temp = System.currentTimeMillis();
        System.out.println(temp - current);
        current = temp;
      }

      mh.invokeExact(128);
    }
  }
}
```

实际上，它与使用Lambda表达式或者方法引用的差别在于，即时编译器无法将该方法句柄识别为常量，从而无法进行内联。那么如果将它变成常量行不行呢？

一种方法便是将其赋值给final的静态变量，如下面的v9版本所示：

```
// v9版本
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;

public class Test {
  public static void target(int i) { }

  static final MethodHandle mh;
  static {
    try {
      MethodHandles.Lookup l = MethodHandles.lookup();
      MethodType t = MethodType.methodType(void.class, int.class);
      mh = l.findStatic(Test.class, "target", t);
    } catch (Throwable e) {
      throw new RuntimeException(e);
    }
  }

  public static void main(String[] args) throws Throwable {
    long current = System.currentTimeMillis();
    for (int i = 1; i <= 2_000_000_000; i++) {
      if (i % 100_000_000 == 0) {
        long temp = System.currentTimeMillis();
        System.out.println(temp - current);
        current = temp;
      }

      mh.invokeExact(128);
    }
  }
}
```

这个版本测得的数据和直接调用的性能数据一致。也就是说，即时编译器能够将该方法句柄完全内联进来，成为空操作。

今天的实践环节，我们来继续探索方法句柄的性能。运行下面的v10版本以及v11版本，比较它们的性能并思考为什么。

```
// v10版本
import java.lang.invoke.*;

public class Test {
  public static void target(int i) {
  }

  public static class MyCallSite {

    public final MethodHandle mh;

    public MyCallSite() {
      mh = findTarget();
    }

    private static MethodHandle findTarget() {
      try {
        MethodHandles.Lookup l = MethodHandles.lookup();
        MethodType t = MethodType.methodType(void.class, int.class);
        return l.findStatic(Test.class, "target", t);
      } catch (Throwable e) {
        throw new RuntimeException(e);
      }
    }
  }

  private static final MyCallSite myCallSite = new MyCallSite();

  public static void main(String[] args) throws Throwable {
    long current = System.currentTimeMillis();
    for (int i = 1; i <= 2_000_000_000; i++) {
      if (i % 100_000_000 == 0) {
        long temp = System.currentTimeMillis();
        System.out.println(temp - current);
        current = temp;
      }

      myCallSite.mh.invokeExact(128);
    }
  }
}

// v11版本
import java.lang.invoke.*;

public class Test {
  public static void target(int i) {
  }

  public static class MyCallSite extends ConstantCallSite {

    public MyCallSite() {
      super(findTarget());
    }

    private static MethodHandle findTarget() {
      try {
        MethodHandles.Lookup l = MethodHandles.lookup();
        MethodType t = MethodType.methodType(void.class, int.class);
        return l.findStatic(Test.class, "target", t);
      } catch (Throwable e) {
        throw new RuntimeException(e);
      }
    }
  }

  public static final MyCallSite myCallSite = new MyCallSite();

  public static void main(String[] args) throws Throwable {
    long current = System.currentTimeMillis();
    for (int i = 1; i <= 2_000_000_000; i++) {
      if (i % 100_000_000 == 0) {
        long temp = System.currentTimeMillis();
        System.out.println(temp - current);
        current = temp;
      }

      myCallSite.getTarget().invokeExact(128);
    }
  }
}
```

感谢你的收听，我们下次再见。

\[1] [http://openjdk.java.net/jeps/303](http://openjdk.java.net/jeps/303)
<div><strong>精选留言（15）</strong></div><ul>
<li><span>Shine</span> 👍（27） 💬（1）<p>一直没理解“逃逸分析”啥意思？</p>2018-08-14</li><br/><li><span>　素丶　　</span> 👍（21） 💬（3）<p>https:&#47;&#47;zhuanlan.zhihu.com&#47;p&#47;26389041
https:&#47;&#47;zhuanlan.zhihu.com&#47;p&#47;30936412
可以和 Shijie 大大的两篇文章配合着看。</p>2018-11-07</li><br/><li><span>karl</span> 👍（20） 💬（1）<p>看了两遍 勉强有个概念了 
还是基础不够 看不懂啊</p>2018-08-14</li><br/><li><span>ext4</span> 👍（17） 💬（1）<p>我知道Java对Lambda有个规定：“The variable used in Lambda should be final or effectively final&quot;，也就是说Lambda表达式捕获的变量必须是final或等同于final的。而文中您又讲到：“对于捕获了变量的Lambda，每次invokedynamic都需要新建适配器类实例，以防止他们发生变化”。JVM之所以这么做，是因为这种final的要求仅限于Java source层面，在bytecode层面是是无法保证的。我理解的对吗？</p>2018-08-11</li><br/><li><span>Scott</span> 👍（4） 💬（1）<p>老师你好，我有两个问题，1是我看了几个有invokedynmaic指令的文件，都是invokedynamic #31,  0这种形式，似乎后面这个0没有什么作用，网上invokedynamic的解说也大多过时，我使用的是1.8.0_181版本。2. v10版本和v11版本性能的差距我猜想是v10版本不能正确的内联方法吧？虽然mh是final的，但是字节码层面已经丢失这个信息了。</p>2018-08-19</li><br/><li><span>小橙橙</span> 👍（2） 💬（1）<p>其实有个地方一直没有想透，为什么要学习字节码，学习字节码对我们日常开发有什么作用吗，老师能否给指点迷津一下？</p>2018-08-19</li><br/><li><span>Void_seT</span> 👍（0） 💬（1）<p>单态内联缓存的实现代码段，bootstrap方法的实现有问题，没有return一个CallSite类型返回值。另外，这篇有点难度了，看了三遍，勉强理解。</p>2018-08-11</li><br/><li><span>lantern</span> 👍（4） 💬（1）<p>用invokedynamic实现lambda发生了什么是看懂了，但没有完全想明白这么做的必要性，这样做相比于编译时解lambda语法糖生成一个匿名类有什么好处呢
是因为对于不捕获局部变量的lambda不用反复new对象吗，那么对于需要捕获局部变量的情况invokedynamic的实现方式还有什么其他的好处吗</p>2020-08-16</li><br/><li><span>Kfreer</span> 👍（4） 💬（1）<p>如果该 Lambda 表达式捕获了其他变量，那么每次执行该 invokedynamic 指令，我们都要更新这些捕获了的变化。
问题：捕获的变量必须是final，为什么还会变呢，为什么会线程不安全呢？</p>2019-02-17</li><br/><li><span>猴哥一一 cium</span> 👍（3） 💬（0）<p>看到大家都不懂，我就放心了 😁</p>2023-06-17</li><br/><li><span>小鳄鱼</span> 👍（3） 💬（2）<p>老师，看来上一篇和这篇，又两个问题：
1. 尽管逃逸分析能够去除这些额外的新建实例开销，但是它也不是时时奏效。那么什么情况下不奏效呢？
2. 什么情况下编译器会将句柄识别成常量？除了本文中将MethodHandler定义为常量外，在其他什么情况下能识别为常量呢</p>2018-11-15</li><br/><li><span>snakorse</span> 👍（2） 💬（0）<p>老师，请教个问题：java为什么采用在jvm上通过invokedynamic方式来实现lambda，而不直接通过在编译阶段直接生成和替换代码的方式实现？</p>2020-04-08</li><br/><li><span>ppyh</span> 👍（1） 💬（0）<p>有一点不太明白，invokeddynamic为什么要用methodHandle来实现。</p>2021-08-23</li><br/><li><span>zjiash</span> 👍（0） 💬（0）<p>V11可以达到和直接调用近似的执行效率，但是V10不可以，应该是方法没有内联。另外，V9如果不使用静态常量，而是在V8基础上使用常量，形如final MethodHandle mh = l.findStatic(Test.class, &quot;target&quot;, t); 执行性能也会比较差。这样和V10类似，不知道为什么这2种情况没有进行内联？</p>2023-10-27</li><br/><li><span>Geek_a7016f</span> 👍（0） 💬（0）<p>老师能提供一些前置基础资料吗？文章感觉有点难度。</p>2022-08-31</li><br/>
</ul>