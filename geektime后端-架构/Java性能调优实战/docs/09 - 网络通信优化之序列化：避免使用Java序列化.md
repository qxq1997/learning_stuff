你好，我是刘超。

当前大部分后端服务都是基于微服务架构实现的。服务按照业务划分被拆分，实现了服务的解耦，但同时也带来了新的问题，不同业务之间通信需要通过接口实现调用。两个服务之间要共享一个数据对象，就需要从对象转换成二进制流，通过网络传输，传送到对方服务，再转换回对象，供服务方法调用。**这个编码和解码过程我们称之为序列化与反序列化。**

在大量并发请求的情况下，如果序列化的速度慢，会导致请求响应时间增加；而序列化后的传输数据体积大，会导致网络吞吐量下降。所以一个优秀的序列化框架可以提高系统的整体性能。

我们知道，Java提供了RMI框架可以实现服务与服务之间的接口暴露和调用，RMI中对数据对象的序列化采用的是Java序列化。而目前主流的微服务框架却几乎没有用到Java序列化，SpringCloud用的是Json序列化，Dubbo虽然兼容了Java序列化，但默认使用的是Hessian序列化。这是为什么呢？

今天我们就来深入了解下Java序列化，再对比近两年比较火的Protobuf序列化，看看Protobuf是如何实现最优序列化的。

## Java序列化

在说缺陷之前，你先得知道什么是Java序列化以及它的实现原理。

Java提供了一种序列化机制，这种机制能够将一个对象序列化为二进制形式（字节数组），用于写入磁盘或输出到网络，同时也能从网络或磁盘中读取字节数组，反序列化成对象，在程序中使用。

![](https://static001.geekbang.org/resource/image/bd/e2/bd4bc4b2746f4b005ca26042412f4ee2.png?wh=3255%2A439)

JDK提供的两个输入、输出流对象ObjectInputStream和ObjectOutputStream，它们只能对实现了Serializable接口的类的对象进行反序列化和序列化。

ObjectOutputStream的默认序列化方式，仅对对象的非transient的实例变量进行序列化，而不会序列化对象的transient的实例变量，也不会序列化静态变量。

在实现了Serializable接口的类的对象中，会生成一个serialVersionUID的版本号，这个版本号有什么用呢？它会在反序列化过程中来验证序列化对象是否加载了反序列化的类，如果是具有相同类名的不同版本号的类，在反序列化中是无法获取对象的。

具体实现序列化的是writeObject和readObject，通常这两个方法是默认的，当然我们也可以在实现Serializable接口的类中对其进行重写，定制一套属于自己的序列化与反序列化机制。

另外，Java序列化的类中还定义了两个重写方法：writeReplace()和readResolve()，前者是用来在序列化之前替换序列化对象的，后者是用来在反序列化之后对返回对象进行处理的。

## Java序列化的缺陷

如果你用过一些RPC通信框架，你就会发现这些框架很少使用JDK提供的序列化。其实不用和不好用多半是挂钩的，下面我们就一起来看看JDK默认的序列化到底存在着哪些缺陷。

### 1.无法跨语言

现在的系统设计越来越多元化，很多系统都使用了多种语言来编写应用程序。比如，我们公司开发的一些大型游戏就使用了多种语言，C++写游戏服务，Java/Go写周边服务，Python写一些监控应用。

而Java序列化目前只适用基于Java语言实现的框架，其它语言大部分都没有使用Java的序列化框架，也没有实现Java序列化这套协议。因此，如果是两个基于不同语言编写的应用程序相互通信，则无法实现两个应用服务之间传输对象的序列化与反序列化。

### 2.易被攻击

Java官网安全编码指导方针中说明：“对不信任数据的反序列化，从本质上来说是危险的，应该予以避免”。可见Java序列化是不安全的。

我们知道对象是通过在ObjectInputStream上调用readObject()方法进行反序列化的，这个方法其实是一个神奇的构造器，它可以将类路径上几乎所有实现了Serializable接口的对象都实例化。

这也就意味着，在反序列化字节流的过程中，该方法可以执行任意类型的代码，这是非常危险的。

对于需要长时间进行反序列化的对象，不需要执行任何代码，也可以发起一次攻击。攻击者可以创建循环对象链，然后将序列化后的对象传输到程序中反序列化，这种情况会导致hashCode方法被调用次数呈次方爆发式增长, 从而引发栈溢出异常。例如下面这个案例就可以很好地说明。

```
Set root = new HashSet();  
Set s1 = root;  
Set s2 = new HashSet();  
for (int i = 0; i < 100; i++) {  
   Set t1 = new HashSet();  
   Set t2 = new HashSet();  
   t1.add("foo"); //使t2不等于t1  
   s1.add(t1);  
   s1.add(t2);  
   s2.add(t1);  
   s2.add(t2);  
   s1 = t1;  
   s2 = t2;   
} 
```

2015年FoxGlove Security安全团队的breenmachine发布过一篇长博客，主要内容是：通过Apache Commons Collections，Java反序列化漏洞可以实现攻击。一度横扫了WebLogic、WebSphere、JBoss、Jenkins、OpenNMS的最新版，各大Java Web Server纷纷躺枪。

其实，Apache Commons Collections就是一个第三方基础库，它扩展了Java标准库里的Collection结构，提供了很多强有力的数据结构类型，并且实现了各种集合工具类。

实现攻击的原理就是：Apache Commons Collections允许链式的任意的类函数反射调用，攻击者通过“实现了Java序列化协议”的端口，把攻击代码上传到服务器上，再由Apache Commons Collections里的TransformedMap来执行。

**那么后来是如何解决这个漏洞的呢？**

很多序列化协议都制定了一套数据结构来保存和获取对象。例如，JSON序列化、ProtocolBuf等，它们只支持一些基本类型和数组数据类型，这样可以避免反序列化创建一些不确定的实例。虽然它们的设计简单，但足以满足当前大部分系统的数据传输需求。

我们也可以通过反序列化对象白名单来控制反序列化对象，可以重写resolveClass方法，并在该方法中校验对象名字。代码如下所示：

```
@Override
protected Class resolveClass(ObjectStreamClass desc) throws IOException,ClassNotFoundException {
if (!desc.getName().equals(Bicycle.class.getName())) {

throw new InvalidClassException(
"Unauthorized deserialization attempt", desc.getName());
}
return super.resolveClass(desc);
}
```

### 3.序列化后的流太大

序列化后的二进制流大小能体现序列化的性能。序列化后的二进制数组越大，占用的存储空间就越多，存储硬件的成本就越高。如果我们是进行网络传输，则占用的带宽就更多，这时就会影响到系统的吞吐量。

Java序列化中使用了ObjectOutputStream来实现对象转二进制编码，那么这种序列化机制实现的二进制编码完成的二进制数组大小，相比于NIO中的ByteBuffer实现的二进制编码完成的数组大小，有没有区别呢？

我们可以通过一个简单的例子来验证下：

```
User user = new User();
    	user.setUserName("test");
    	user.setPassword("test");
    	
    	ByteArrayOutputStream os =new ByteArrayOutputStream();
    	ObjectOutputStream out = new ObjectOutputStream(os);
    	out.writeObject(user);
    	
    	byte[] testByte = os.toByteArray();
    	System.out.print("ObjectOutputStream 字节编码长度：" + testByte.length + "\n");
```

```
  ByteBuffer byteBuffer = ByteBuffer.allocate( 2048);

        byte[] userName = user.getUserName().getBytes();
        byte[] password = user.getPassword().getBytes();
        byteBuffer.putInt(userName.length);
        byteBuffer.put(userName);
        byteBuffer.putInt(password.length);
        byteBuffer.put(password);
        
        byteBuffer.flip();
        byte[] bytes = new byte[byteBuffer.remaining()];
    	System.out.print("ByteBuffer 字节编码长度：" + bytes.length+ "\n");

```

运行结果：

```
ObjectOutputStream 字节编码长度：99
ByteBuffer 字节编码长度：16
```

这里我们可以清楚地看到：Java序列化实现的二进制编码完成的二进制数组大小，比ByteBuffer实现的二进制编码完成的二进制数组大小要大上几倍。因此，Java序列后的流会变大，最终会影响到系统的吞吐量。

### 4.序列化性能太差

序列化的速度也是体现序列化性能的重要指标，如果序列化的速度慢，就会影响网络通信的效率，从而增加系统的响应时间。我们再来通过上面这个例子，来对比下Java序列化与NIO中的ByteBuffer编码的性能：

```
	User user = new User();
    	user.setUserName("test");
    	user.setPassword("test");
    	
    	long startTime = System.currentTimeMillis();
    	
    	for(int i=0; i<1000; i++) {
    		ByteArrayOutputStream os =new ByteArrayOutputStream();
        	ObjectOutputStream out = new ObjectOutputStream(os);
        	out.writeObject(user);
        	out.flush();
        	out.close();
        	byte[] testByte = os.toByteArray();
        	os.close();
    	}
    
    	
    	long endTime = System.currentTimeMillis();
    	System.out.print("ObjectOutputStream 序列化时间：" + (endTime - startTime) + "\n");
```

```
long startTime1 = System.currentTimeMillis();
    	for(int i=0; i<1000; i++) {
    		ByteBuffer byteBuffer = ByteBuffer.allocate( 2048);

            byte[] userName = user.getUserName().getBytes();
            byte[] password = user.getPassword().getBytes();
            byteBuffer.putInt(userName.length);
            byteBuffer.put(userName);
            byteBuffer.putInt(password.length);
            byteBuffer.put(password);
            
            byteBuffer.flip();
            byte[] bytes = new byte[byteBuffer.remaining()];
    	}
    	long endTime1 = System.currentTimeMillis();
    	System.out.print("ByteBuffer 序列化时间：" + (endTime1 - startTime1)+ "\n");
```

运行结果：

```
ObjectOutputStream 序列化时间：29
ByteBuffer 序列化时间：6
```

通过以上案例，我们可以清楚地看到：Java序列化中的编码耗时要比ByteBuffer长很多。

## 使用Protobuf序列化替换Java序列化

目前业内优秀的序列化框架有很多，而且大部分都避免了Java默认序列化的一些缺陷。例如，最近几年比较流行的FastJson、Kryo、Protobuf、Hessian等。**我们完全可以找一种替换掉Java序列化，这里我推荐使用Protobuf序列化框架。**

Protobuf是由Google推出且支持多语言的序列化框架，目前在主流网站上的序列化框架性能对比测试报告中，Protobuf无论是编解码耗时，还是二进制流压缩大小，都名列前茅。

Protobuf以一个 .proto 后缀的文件为基础，这个文件描述了字段以及字段类型，通过工具可以生成不同语言的数据结构文件。在序列化该数据对象的时候，Protobuf通过.proto文件描述来生成Protocol Buffers格式的编码。

**这里拓展一点，我来讲下什么是Protocol Buffers存储格式以及它的实现原理。**

Protocol Buffers 是一种轻便高效的结构化数据存储格式。它使用T-L-V（标识 - 长度 - 字段值）的数据格式来存储数据，T代表字段的正数序列(tag)，Protocol Buffers 将对象中的每个字段和正数序列对应起来，对应关系的信息是由生成的代码来保证的。在序列化的时候用整数值来代替字段名称，于是传输流量就可以大幅缩减；L代表Value的字节长度，一般也只占一个字节；V则代表字段值经过编码后的值。这种数据格式不需要分隔符，也不需要空格，同时减少了冗余字段名。

Protobuf定义了一套自己的编码方式，几乎可以映射Java/Python等语言的所有基础数据类型。不同的编码方式对应不同的数据类型，还能采用不同的存储格式。如下图所示：

![](https://static001.geekbang.org/resource/image/ec/eb/ec0ebe4f622e9edcd9de86cb92f15eeb.jpg?wh=1638%2A466)

对于存储Varint编码数据，由于数据占用的存储空间是固定的，就不需要存储字节长度 Length，所以实际上Protocol Buffers的存储方式是 T - V，这样就又减少了一个字节的存储空间。

Protobuf定义的Varint编码方式是一种变长的编码方式，每个字节的最后一位(即最高位)是一个标志位(msb)，用0和1来表示，0表示当前字节已经是最后一个字节，1表示这个数字后面还有一个字节。

对于int32类型数字，一般需要4个字节表示，若采用Varint编码方式，对于很小的int32类型数字，就可以用1个字节来表示。对于大部分整数类型数据来说，一般都是小于256，所以这种操作可以起到很好地压缩数据的效果。

我们知道int32代表正负数，所以一般最后一位是用来表示正负值，现在Varint编码方式将最后一位用作了标志位，那还如何去表示正负整数呢？如果使用int32/int64表示负数就需要多个字节来表示，在Varint编码类型中，通过Zigzag编码进行转换，将负数转换成无符号数，再采用sint32/sint64来表示负数，这样就可以大大地减少编码后的字节数。

Protobuf的这种数据存储格式，不仅压缩存储数据的效果好， 在编码和解码的性能方面也很高效。Protobuf的编码和解码过程结合.proto文件格式，加上Protocol Buffer独特的编码格式，只需要简单的数据运算以及位移等操作就可以完成编码与解码。可以说Protobuf的整体性能非常优秀。

## 总结

无论是网路传输还是磁盘持久化数据，我们都需要将数据编码成字节码，而我们平时在程序中使用的数据都是基于内存的数据类型或者对象，我们需要通过编码将这些数据转化成二进制字节流；如果需要接收或者再使用时，又需要通过解码将二进制字节流转换成内存数据。我们通常将这两个过程称为序列化与反序列化。

Java默认的序列化是通过Serializable接口实现的，只要类实现了该接口，同时生成一个默认的版本号，我们无需手动设置，该类就会自动实现序列化与反序列化。

Java默认的序列化虽然实现方便，但却存在安全漏洞、不跨语言以及性能差等缺陷，所以我强烈建议你避免使用Java序列化。

纵观主流序列化框架，FastJson、Protobuf、Kryo是比较有特点的，而且性能以及安全方面都得到了业界的认可，我们可以结合自身业务来选择一种适合的序列化框架，来优化系统的序列化性能。

## 思考题

这是一个使用单例模式实现的类，如果我们将该类实现Java的Serializable接口，它还是单例吗？如果要你来写一个实现了Java的Serializable接口的单例，你会怎么写呢？

```
public class Singleton implements Serializable{

    private final static Singleton singleInstance = new Singleton();

    private Singleton(){}

    public static Singleton getInstance(){
       return singleInstance; 
    }
}
```

期待在留言区看到你的见解。也欢迎你点击“请朋友读”，把今天的内容分享给身边的朋友，邀请他一起学习。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>陆离</span> 👍（104） 💬（7）<p>序列化会通过反射调用无参构造器返回一个新对象，破坏单例模式。
解决方法是添加readResolve()方法，自定义返回对象策略。</p>2019-06-08</li><br/><li><span>密码123456</span> 👍（26） 💬（7）<p>看到提问，才发现这竟然不是单例。回想内容是因为。可以把类路径上几乎所有实现了 Serializable 接口的对象都实例化。还真不知道怎么写？内部私有类实现，这种可以吗？</p>2019-06-08</li><br/><li><span>尔东橙</span> 👍（9） 💬（1）<p> 它会在反序列化过程中来验证序列化对象是否加载了反序列化的类，如果是具有相同类名的不同版本号的类，在反序列化中是无法获取对象的。老师，这句话能举个例子么，没太明白</p>2019-09-14</li><br/><li><span>kevin</span> 👍（8） 💬（1）<p>老师请教下，为什么spring cloud不使用protobuf, thrift等性能更高、支持跨平台的序列化工具，而且使用json？</p>2019-06-09</li><br/><li><span>-W.LI-</span> 👍（7） 💬（2）<p>文中说Java序列化，不会序列化静态变量，这个单例的静态变量会被怎么处理啊?
</p>2019-06-08</li><br/><li><span>waniz</span> 👍（6） 💬（2）<p>老师您好，Java序列化将数据转化为二进制字节流，json序列化将数据转化为json字符串。但是在物理层数据都是以电信号或模拟信号传输。那么从应用层到物理层数据的编码状态究竟是怎么变化的?出发点不同，最后都是二进制传输…忘解惑</p>2019-07-05</li><br/><li><span>天天向上</span> 👍（4） 💬（1）<p>想知道为什么用非Java的序列化方式的也需要实现Serializable接口？</p>2019-12-28</li><br/><li><span>钱</span> 👍（3） 💬（1）<p>课后思考及问题
1：老师能深入细致的讲讲JAVA怎么实现序列化的嘛？比如：一个对象怎么一步步神奇的变成一个字节数组的？对象中的属性、属性值、方法、以及此对象的信息怎么变成一个字节数组的？
2：我们知道对象是通过在 ObjectInputStream 上调用 readObject() 方法进行反序列化的，这个方法其实是一个神奇的构造器，它可以将类路径上几乎所有实现了 Serializable 接口的对象都实例化。
这个神奇的构造器的实现原理是啥？一个字节数组他怎么将其转换为一个对象的？很好奇，他知道字节数组多少位表示啥意思？然后一段一段的取，一段的翻译嘛？老师给讲讲呗？
老师深入讲一下原理实现细节，API式的讲解不过瘾，和老师要深入理解的风格也不符呀😄</p>2019-09-07</li><br/><li><span>晓杰</span> 👍（1） 💬（2）<p>不是单例，因为在反序列化的时候，会调用ObjectInputStream的readObject方法，该方法可以对实现序列化接口的类进行实例化，所以会破坏单例模式。
可以通过重写readResolve，返回单例对象的方式来避免这个问题</p>2019-06-08</li><br/><li><span>尔东橙</span> 👍（0） 💬（1）<p>序列化对象中加载反序列化的类怎么理解？</p>2020-02-15</li><br/><li><span>王圣军</span> 👍（0） 💬（1）<p>我们有时基于网络通讯的传输，有的不是直接使用实例序列化后传输，很多就是字符串转换为二进制流进行传输，这个应该是不涉及到序列化和反序列化的吧？</p>2019-12-26</li><br/><li><span>td901105</span> 👍（0） 💬（3）<p>老师我想问一下如果使用非Java的序列化方式的话需要实现Serializable接口吗？</p>2019-12-05</li><br/><li><span>尔东橙</span> 👍（0） 💬（1）<p>那么java的NIO用到了java的序列化和反序列化么？有一样的问题么</p>2019-09-14</li><br/><li><span>尔东橙</span> 👍（0） 💬（1）<p> 老师，所有在网络中传输信息都是要序列化么</p>2019-09-14</li><br/><li><span>辉</span> 👍（0） 💬（1）<p>hession是通过什么做序列化的？</p>2019-07-19</li><br/>
</ul>