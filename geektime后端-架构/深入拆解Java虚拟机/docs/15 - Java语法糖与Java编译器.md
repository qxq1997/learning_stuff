在前面的篇章中，我们多次提到了Java语法和Java字节码的差异之处。这些差异之处都是通过Java编译器来协调的。今天我们便来列举一下Java编译器的协调工作。

## 自动装箱与自动拆箱

首先要提到的便是Java的自动装箱（auto-boxing）和自动拆箱（auto-unboxing）。

我们知道，Java语言拥有8个基本类型，每个基本类型都有对应的包装（wrapper）类型。

之所以需要包装类型，是因为许多Java核心类库的API都是面向对象的。举个例子，Java核心类库中的容器类，就只支持引用类型。

当需要一个能够存储数值的容器类时，我们往往定义一个存储包装类对象的容器。

对于基本类型的数值来说，我们需要先将其转换为对应的包装类，再存入容器之中。在Java程序中，这个转换可以是显式，也可以是隐式的，后者正是Java中的自动装箱。

```
public int foo() {
  ArrayList<Integer> list = new ArrayList<>();
  list.add(0);
  int result = list.get(0);
  return result;
}
```

以上图中的Java代码为例。我构造了一个Integer类型的ArrayList，并且向其中添加一个int值0。然后，我会获取该ArrayList的第0个元素，并作为int值返回给调用者。这段代码对应的Java字节码如下所示：

```
public int foo();
  Code:
     0: new java/util/ArrayList
     3: dup
     4: invokespecial java/util/ArrayList."<init>":()V
     7: astore_1
     8: aload_1
     9: iconst_0
    10: invokestatic java/lang/Integer.valueOf:(I)Ljava/lang/Integer;
    13: invokevirtual java/util/ArrayList.add:(Ljava/lang/Object;)Z
    16: pop
    17: aload_1
    18: iconst_0
    19: invokevirtual java/util/ArrayList.get:(I)Ljava/lang/Object;
    22: checkcast java/lang/Integer
    25: invokevirtual java/lang/Integer.intValue:()I
    28: istore_2
    29: iload_2
    30: ireturn
```

当向泛型参数为Integer的ArrayList添加int值时，便需要用到自动装箱了。在上面字节码偏移量为10的指令中，我们调用了Integer.valueOf方法，将int类型的值转换为Integer类型，再存储至容器类中。

```
public static Integer valueOf(int i) {
    if (i >= IntegerCache.low && i <= IntegerCache.high)
        return IntegerCache.cache[i + (-IntegerCache.low)];
    return new Integer(i);
}
```

这是Integer.valueOf的源代码。可以看到，当请求的int值在某个范围内时，我们会返回缓存了的Integer对象；而当所请求的int值在范围之外时，我们则会新建一个Integer对象。

在介绍反射的那一篇中，我曾经提到参数java.lang.Integer.IntegerCache.high。这个参数将影响这里面的IntegerCache.high。

也就是说，我们可以通过配置该参数，扩大Integer缓存的范围。Java虚拟机参数-XX:+AggressiveOpts也会将IntegerCache.high调整至20000。

奇怪的是，Java并不支持对IntegerCache.low的更改，也就是说，对于小于-128的整数，我们无法直接使用由Java核心类库所缓存的Integer对象。

```
25: invokevirtual java/lang/Integer.intValue:()I
```

当从泛型参数为Integer的ArrayList取出元素时，我们得到的实际上也是Integer对象。如果应用程序期待的是一个int值，那么就会发生自动拆箱。

在我们的例子中，自动拆箱对应的是字节码偏移量为25的指令。该指令将调用Integer.intValue方法。这是一个实例方法，直接返回Integer对象所存储的int值。

## 泛型与类型擦除

你可能已经留意到了，在前面例子生成的字节码中，往ArrayList中添加元素的add方法，所接受的参数类型是Object；而从ArrayList中获取元素的get方法，其返回类型同样也是Object。

前者还好，但是对于后者，在字节码中我们需要进行向下转换，将所返回的Object强制转换为Integer，方能进行接下来的自动拆箱。

```
13: invokevirtual java/util/ArrayList.add:(Ljava/lang/Object;)Z
...
19: invokevirtual java/util/ArrayList.get:(I)Ljava/lang/Object;
22: checkcast java/lang/Integer
```

之所以会出现这种情况，是因为Java泛型的类型擦除。这是个什么概念呢？简单地说，那便是Java程序里的泛型信息，在Java虚拟机里全部都丢失了。这么做主要是为了兼容引入泛型之前的代码。

当然，并不是每一个泛型参数被擦除类型后都会变成Object类。对于限定了继承类的泛型参数，经过类型擦除后，所有的泛型参数都将变成所限定的继承类。也就是说，Java编译器将选取该泛型所能指代的所有类中层次最高的那个，作为替换泛型的类。

```
class GenericTest<T extends Number> {
  T foo(T t) {
    return t;
  }
}
```

举个例子，在上面这段Java代码中，我定义了一个T extends Number的泛型参数。它所对应的字节码如下所示。可以看到，foo方法的方法描述符所接收参数的类型以及返回类型都为Number。方法描述符是Java虚拟机识别方法调用的目标方法的关键。

```
T foo(T);
  descriptor: (Ljava/lang/Number;)Ljava/lang/Number;
  flags: (0x0000)
  Code:
    stack=1, locals=2, args_size=2
       0: aload_1
       1: areturn
  Signature: (TT;)TT;
```

不过，字节码中仍存在泛型参数的信息，如方法声明里的T foo(T)，以及方法签名（Signature）中的“(TT;)TT;”。这类信息主要由Java编译器在编译他类时使用。

既然泛型会被类型擦除，那么我们还有必要用它吗？

我认为是有必要的。Java编译器可以根据泛型参数判断程序中的语法是否正确。举例来说，尽管经过类型擦除后，ArrayList.add方法所接收的参数是Object类型，但是往泛型参数为Integer类型的ArrayList中添加字符串对象，Java编译器是会报错的。

```
ArrayList<Integer> list = new ArrayList<>();
list.add("0"); // 编译出错
```

## 桥接方法

泛型的类型擦除带来了不少问题。其中一个便是方法重写。在第四篇的课后实践中，我留了这么一段代码：

```
class Merchant<T extends Customer> {
  public double actionPrice(T customer) {
    return 0.0d;
  }
}

class VIPOnlyMerchant extends Merchant<VIP> {
  @Override
  public double actionPrice(VIP customer) {
    return 0.0d;
  }
}
```

VIPOnlyMerchant中的actionPrice方法是符合Java语言的方法重写的，毕竟都使用@Override来注解了。然而，经过类型擦除后，父类的方法描述符为(LCustomer;)D，而子类的方法描述符为(LVIP;)D。这显然不符合Java虚拟机关于方法重写的定义。

为了保证编译而成的Java字节码能够保留重写的语义，Java编译器额外添加了一个桥接方法。该桥接方法在字节码层面重写了父类的方法，并将调用子类的方法。

```
class VIPOnlyMerchant extends Merchant<VIP>
...
  public double actionPrice(VIP);
    descriptor: (LVIP;)D
    flags: (0x0001) ACC_PUBLIC
    Code:
         0: dconst_0
         1: dreturn

  public double actionPrice(Customer);
    descriptor: (LCustomer;)D
    flags: (0x1041) ACC_PUBLIC, ACC_BRIDGE, ACC_SYNTHETIC
    Code:
         0: aload_0
         1: aload_1
         2: checkcast class VIP
         5: invokevirtual actionPrice:(LVIP;)D
         8: dreturn

// 这个桥接方法等同于
public double actionPrice(Customer customer) {
  return actionPrice((VIP) customer);
}
```

在我们的例子中，VIPOnlyMerchant类将包含一个桥接方法actionPrice(Customer)，它重写了父类的同名同方法描述符的方法。该桥接方法将传入的Customer参数强制转换为VIP类型，再调用原本的actionPrice(VIP)方法。

当一个声明类型为Merchant，实际类型为VIPOnlyMerchant的对象，调用actionPrice方法时，字节码里的符号引用指向的是Merchant.actionPrice(Customer)方法。Java虚拟机将动态绑定至VIPOnlyMerchant类的桥接方法之中，并且调用其actionPrice(VIP)方法。

需要注意的是，在javap的输出中，该桥接方法的访问标识符除了代表桥接方法的ACC\_BRIDGE之外，还有ACC\_SYNTHETIC。它表示该方法对于Java源代码来说是不可见的。当你尝试通过传入一个声明类型为Customer的对象作为参数，调用VIPOnlyMerchant类的actionPrice方法时，Java编译器会报错，并且提示参数类型不匹配。

```
    Customer customer = new VIP();
    new VIPOnlyMerchant().actionPrice(customer); // 编译出错    
```

当然，如果你实在想要调用这个桥接方法，那么你可以选择使用反射机制。

```
class Merchant {
  public Number actionPrice(Customer customer) {
    return 0;
  }
}

class NaiveMerchant extends Merchant {
  @Override
  public Double actionPrice(Customer customer) {
    return 0.0D;
  }
}
```

除了前面介绍的泛型重写会生成桥接方法之外，如果子类定义了一个与父类参数类型相同的方法，其返回类型为父类方法返回类型的子类，那么Java编译器也会为其生成桥接方法。

```
class NaiveMerchant extends Merchant
  public java.lang.Double actionPrice(Customer);
    descriptor: (LCustomer;)Ljava/lang/Double;
    flags: (0x0001) ACC_PUBLIC
    Code:
      stack=2, locals=2, args_size=2
         0: dconst_0
         1: invokestatic Double.valueOf:(D)Ljava/lang/Double;
         4: areturn

  public java.lang.Number actionPrice(Customer);
    descriptor: (LCustomer;)Ljava/lang/Number;
    flags: (0x1041) ACC_PUBLIC, ACC_BRIDGE, ACC_SYNTHETIC
    Code:
      stack=2, locals=2, args_size=2
         0: aload_0
         1: aload_1
         2: invokevirtual actionPrice:(LCustomer;)Ljava/lang/Double;
         5: areturn         
```

我之前曾提到过，class文件里允许出现两个同名、同参数类型但是不同返回类型的方法。这里的原方法和桥接方法便是其中一个例子。由于该桥接方法同样标注了ACC\_SYNTHETIC，因此，当在Java程序中调用NaiveMerchant.actionPrice时，我们只会调用到原方法。

## 其他语法糖

在前面的篇章中，我已经介绍过了变长参数、try-with-resources以及在同一catch代码块中捕获多种异常等语法糖。下面我将列举另外两个常见的语法糖。

foreach循环允许Java程序在for循环里遍历数组或者Iterable对象。对于数组来说，foreach循环将从0开始逐一访问数组中的元素，直至数组的末尾。其等价的代码如下面所示：

```
public void foo(int[] array) {
  for (int item : array) {
  }
}
// 等同于
public void bar(int[] array) {
  int[] myArray = array;
  int length = myArray.length;
  for (int i = 0; i < length; i++) {
    int item = myArray[i];
  }
}
```

对于Iterable对象来说，foreach循环将调用其iterator方法，并且用它的hasNext以及next方法来遍历该Iterable对象中的元素。其等价的代码如下面所示：

```
public void foo(ArrayList<Integer> list) {
  for (Integer item : list) {
  }
}
// 等同于
public void bar(ArrayList<Integer> list) {
  Iterator<Integer> iterator = list.iterator();
  while (iterator.hasNext()) {
    Integer item = iterator.next();
  }
}
```

字符串switch编译而成的字节码看起来非常复杂，但实际上就是一个哈希桶。由于每个case所截获的字符串都是常量值，因此，Java编译器会将原来的字符串switch转换为int值switch，比较所输入的字符串的哈希值。

由于字符串哈希值很容易发生碰撞，因此，我们还需要用String.equals逐个比较相同哈希值的字符串。

如果你感兴趣的话，可以自己利用javap分析字符串switch编译而成的字节码。

## 总结与实践

今天我主要介绍了Java编译器对几个语法糖的处理。

基本类型和其包装类型之间的自动转换，也就是自动装箱、自动拆箱，是通过加入\[Wrapper].valueOf（如Integer.valueOf）以及\[Wrapper].\[primitive]Value（如Integer.intValue）方法调用来实现的。

Java程序中的泛型信息会被擦除。具体来说，Java编译器将选取该泛型所能指代的所有类中层次最高的那个，作为替换泛型的具体类。

由于Java语义与Java字节码中关于重写的定义并不一致，因此Java编译器会生成桥接方法作为适配器。此外，我还介绍了foreach循环以及字符串switch的编译。

今天的实践环节，你可以探索一下Java 10的var关键字，是否保存了泛型信息？是否支持自动装拆箱？

```
  public void foo() {
    var value = 1;
    var list = new ArrayList<Integer>();
    list.add(value);
    // list.add("1"); 这一句能够编译吗？
  }

```
<div><strong>精选留言（15）</strong></div><ul>
<li><span>钱</span> 👍（61） 💬（1）<p>本节还是比较容易理解的，也搞清楚了泛型相关的疑惑点，非常感谢。
小结如下：
1:Java语法糖-是一种帮助开发人员提高开发效率的小甜点，原理是将一些繁琐的事情交给编译器来处理，开发人员少做一些事情，当然，本纸上这些事情还必须要做，只是有编译器来做了

2:Java语法糖有那几种呢？如下所示：
2-1:包装类型和基本类型间的转换，自动装箱和拆箱的设计
2-2:泛型的设计
2-3:变长参数的设计
2-4:try-with-resources，关闭资源的设计
2-5:在同一个catch代码块中捕获多种异常
2-6:finally代码块总是被执行的设计
2-7:foreach循环数组的设计
2-8:foreach循环Iterable对象的设计

3:编译器的具体实现细节不是很清楚，猜测是识别出对应的语法然后填充上对应的代码，将语法糖还原成其本质-一些重复繁琐的代码块

4:之前有同事问我泛型是怎么实现的？
我讲不出来，只晓得使用泛型后，不需要写类型强转的代码了，如果类型不对也会有提示且编译失败，现在知道的多一点了，本质上类型强转的工作还是必须要做的，只是不是有开发人员来做了，由编译器来做，并且编译器会擦除掉对应的泛型信息，使用合适的父类型来代替，可能是Object类也可能是声明泛型时指定的继承的类</p>2018-08-25</li><br/><li><span>^_^</span> 👍（9） 💬（3）<p>C++ 是真泛型，java 较之算是伪泛型</p>2018-11-13</li><br/><li><span>Shine</span> 👍（6） 💬（1）<p>每次看到示例代码的java字节码就犯懵，觉得很复杂，是不是有必要去了解下字节码</p>2018-08-25</li><br/><li><span>任鹏斌</span> 👍（2） 💬（1）<p>有点落后刚升级到jdk8对10还一无所知</p>2018-08-24</li><br/><li><span>李二木</span> 👍（2） 💬（2）<p>从实现上说可以设计一个int类型的list，而jdk中arrayList是object类型，这样做是不是为了通用型考虑呢？</p>2018-08-24</li><br/><li><span>403</span> 👍（0） 💬（1）<p>相比来看，c#的泛型是真泛型</p>2018-08-26</li><br/><li><span>herome</span> 👍（0） 💬（1）<p>求老师画图啊 </p>2018-08-25</li><br/><li><span>钱</span> 👍（0） 💬（1）<p>奇怪的是，Java 并不支持对 IntegerCache.low 的更改，也就是说，对于小于 -128 的整数，我们无法直接使用由 Java 核心类库所缓存的 Integer 对象。
这个奇怪的现象到底是为啥呢？</p>2018-08-25</li><br/><li><span>永烁星光</span> 👍（18） 💬（0）<p>直到这节课逐渐感知到了学习jvm的妙处，我想将这专栏反复看和实践终能消化为自己的知识</p>2018-08-25</li><br/><li><span>曲东方</span> 👍（5） 💬（1）<p>var保存了泛型信息

var定义变量必须直接初始化，基于初始化的值做类型推导，javac编译期间的语法糖

所以不能声明函数的参数为var类型


foreach语法糖，对于实现了迭代器Iterable&lt;T&gt;接口的类型，使用迭代器方法；
foreach对于数组和变长参数的处理方式与上述略有不同，先求数组长度，再做类似while循环遍历
</p>2018-08-26</li><br/><li><span>WL</span> 👍（3） 💬（3）<p>invokestatic Double.valueOf:(D)Ljava&#47;lang&#47;Double;
想请教一下老师这个字节码中的(D)和java前的L的作用是标记什么, 查了半天都没查到, 希望老师回答一下.</p>2018-12-14</li><br/><li><span>剑八</span> 👍（2） 💬（0）<p>java设计也是分内核与外延的设计
内核是整个加载器，执行器，编绎器，堆栈这些是相对稳定的
而语法糖是为了提升开发效率，相当于是多变的外延。
本质上这个语法糖是由编绎器帮开发人员做了转换的工作。
泛型在编绎器转换后会变成字节码层页的object，或者如果泛型有继承某个特定父类则在字节码层面就是这个限定类，最终在存取的时候会做强制转换。</p>2020-06-13</li><br/><li><span>随心而至</span> 👍（1） 💬（0）<p>看老师的课，最好就在电脑边，边看边实践。</p>2019-10-16</li><br/><li><span>随心而至</span> 👍（1） 💬（0）<p>赞，这节课的内容即便全忘了，也完全可以自己跑自己命令，看下字节码文件，知道到底是怎么回事。这就是授人以渔，谢谢老师。</p>2019-10-16</li><br/><li><span>angel😇txy🤓</span> 👍（0） 💬（0）<p>ava 程序中的泛型信息会被擦除。具体来说，Java 编译器将选取该泛型所能指代的所有类中层次最高的那个，作为替换泛型的具体类，具体来说：
若泛型类型没有指定具体类型，用Object作为原始类型；
若有限定类型&lt; T exnteds XClass &gt;，使用XClass作为原始类型；
若有多个限定&lt; T exnteds XClass1 &amp; XClass2 &gt;，使用第一个边界类型XClass1作为原始类型；</p>2022-08-30</li><br/>
</ul>