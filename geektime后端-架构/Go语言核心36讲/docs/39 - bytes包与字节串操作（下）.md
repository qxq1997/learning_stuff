你好，我是郝林，今天我们继续分享bytes包与字节串操作的相关内容。

在上一篇文章中，我们分享了`bytes.Buffer`中已读计数的大致功用，并围绕着这个问题做了解析，下面我们来进行相关的知识扩展。

## 知识扩展

### 问题 1：`bytes.Buffer`的扩容策略是怎样的？

`Buffer`值既可以被手动扩容，也可以进行自动扩容。并且，这两种扩容方式的策略是基本一致的。所以，除非我们完全确定后续内容所需的字节数，否则让`Buffer`值自动去扩容就好了。

在扩容的时候，`Buffer`值中相应的代码（以下简称扩容代码）会**先判断内容容器的剩余容量**，是否可以满足调用方的要求，或者是否足够容纳新的内容。

**如果可以，那么扩容代码会在当前的内容容器之上，进行长度扩充。**

更具体地说，如果内容容器的容量与其长度的差，大于或等于另需的字节数，那么扩容代码就会通过切片操作对原有的内容容器的长度进行扩充，就像下面这样：

```
b.buf = b.buf[:length+need]
```

**反之，如果内容容器的剩余容量不够了，那么扩容代码可能就会用新的内容容器去替代原有的内容容器，从而实现扩容。**

不过，这里还有一步优化。

**如果当前内容容器的容量的一半，仍然大于或等于其现有长度（即未读字节数）再加上另需的字节数的和**，即：

```
cap(b.buf)/2 >= b.Len() + need
```

那么，扩容代码就会复用现有的内容容器，并把容器中的未读内容拷贝到它的头部位置。

这也意味着其中的已读内容，将会全部被未读内容和之后的新内容覆盖掉。

这样的复用预计可以至少节省掉一次后续的扩容所带来的内存分配，以及若干字节的拷贝。

**若这一步优化未能达成**，也就是说，当前内容容器的容量小于新长度的二倍。

那么，扩容代码就只能再创建一个新的内容容器，并把原有容器中的未读内容拷贝进去，最后再用新的容器替换掉原有的容器。这个新容器的容量将会等于原有容量的二倍再加上另需字节数的和。

> 新容器的容量=2\*原有容量+所需字节数

通过上面这些步骤，对内容容器的扩充基本上就完成了。不过，为了内部数据的一致性，以及避免原有的已读内容可能造成的数据混乱，扩容代码还会把已读计数置为`0`，并再对内容容器做一下切片操作，以掩盖掉原有的已读内容。

顺便说一下，对于处在零值状态的`Buffer`值来说，如果第一次扩容时的另需字节数不大于`64`，那么该值就会基于一个预先定义好的、长度为`64`的字节数组来创建内容容器。

在这种情况下，这个内容容器的容量就是`64`。这样做的目的是为了让`Buffer`值在刚被真正使用的时候就可以快速地做好准备。

### 问题2：`bytes.Buffer`中的哪些方法可能会造成内容的泄露？

首先明确一点，什么叫内容泄露？这里所说的内容泄露是指，使用`Buffer`值的一方通过某种非标准的（或者说不正式的）方式，得到了本不该得到的内容。

比如说，我通过调用`Buffer`值的某个用于读取内容的方法，得到了一部分未读内容。我应该，也只应该通过这个方法的结果值，拿到在那一时刻`Buffer`值中的未读内容。

但是，在这个`Buffer`值又有了一些新内容之后，我却可以通过当时得到的结果值，直接获得新的内容，而不需要再次调用相应的方法。

这就是典型的非标准读取方式。这种读取方式是不应该存在的，即使存在，我们也不应该使用。因为它是在无意中（或者说一不小心）暴露出来的，其行为很可能是不稳定的。

在`bytes.Buffer`中，`Bytes`方法和`Next`方法都可能会造成内容的泄露。原因在于，它们都把基于内容容器的切片直接返回给了方法的调用方。

我们都知道，通过切片，我们可以直接访问和操纵它的底层数组。不论这个切片是基于某个数组得来的，还是通过对另一个切片做切片操作获得的，都是如此。

在这里，`Bytes`方法和`Next`方法返回的字节切片，都是通过对内容容器做切片操作得到的。也就是说，它们与内容容器共用了同一个底层数组，起码在一段时期之内是这样的。

以`Bytes`方法为例。它会返回在调用那一刻其所属值中的所有未读内容。示例代码如下：

```
contents := "ab"
buffer1 := bytes.NewBufferString(contents)
fmt.Printf("The capacity of new buffer with contents %q: %d\n",
 contents, buffer1.Cap()) // 内容容器的容量为：8。
unreadBytes := buffer1.Bytes()
fmt.Printf("The unread bytes of the buffer: %v\n", unreadBytes) // 未读内容为：[97 98]。
```

我用字符串值`"ab"`初始化了一个`Buffer`值，由变量`buffer1`代表，并打印了当时该值的一些状态。

你可能会有疑惑，我只在这个`Buffer`值中放入了一个长度为`2`的字符串值，但为什么该值的容量却变为了`8`。

虽然这与我们当前的主题无关，但是我可以提示你一下：你可以去阅读`runtime`包中一个名叫`stringtoslicebyte`的函数，答案就在其中。

接着说`buffer1`。我又向该值写入了字符串值`"cdefg"`，此时，其容量仍然是`8`。我在前面通过调用`buffer1`的`Bytes`方法得到的结果值`unreadBytes`，包含了在那时其中的所有未读内容。

但是，由于这个结果值与`buffer1`的内容容器在此时还共用着同一个底层数组，所以，我只需通过简单的再切片操作，就可以利用这个结果值拿到`buffer1`在此时的所有未读内容。如此一来，`buffer1`的新内容就被泄露出来了。

```
buffer1.WriteString("cdefg")
fmt.Printf("The capacity of buffer: %d\n", buffer1.Cap()) // 内容容器的容量仍为：8。
unreadBytes = unreadBytes[:cap(unreadBytes)]
fmt.Printf("The unread bytes of the buffer: %v\n", unreadBytes) // 基于前面获取到的结果值可得，未读内容为：[97 98 99 100 101 102 103 0]。
```

如果我当时把`unreadBytes`的值传到了外界，那么外界就可以通过该值操纵`buffer1`的内容了，就像下面这样：

```
unreadBytes[len(unreadBytes)-2] = byte('X') // 'X'的ASCII编码为88。
fmt.Printf("The unread bytes of the buffer: %v\n", buffer1.Bytes()) // 未读内容变为了：[97 98 99 100 101 102 88]。
```

现在，你应该能够体会到，这里的内容泄露可能造成的严重后果了吧？对于`Buffer`值的`Next`方法，也存在相同的问题。

不过，如果经过扩容，`Buffer`值的内容容器或者它的底层数组被重新设定了，那么之前的内容泄露问题就无法再进一步发展了。我在demo80.go文件中写了一个比较完整的示例，你可以去看一看，并揣摩一下。

## 总结

我们结合两篇内容总结一下。与`strings.Builder`类型不同，`bytes.Buffer`不但可以拼接、截断其中的字节序列，以各种形式导出其中的内容，还可以顺序地读取其中的子序列。

`bytes.Buffer`类型使用字节切片作为其内容容器，并且会用一个字段实时地记录已读字节的计数。

虽然我们无法直接计算出这个已读计数，但是由于它在`Buffer`值中起到的作用非常关键，所以我们很有必要去理解它。

无论是读取、写入、截断、导出还是重置，已读计数都是功能实现中的重要一环。

与`strings.Builder`类型的值一样，`Buffer`值既可以被手动扩容，也可以进行自动的扩容。除非我们完全确定后续内容所需的字节数，否则让`Buffer`值自动去扩容就好了。

`Buffer`值的扩容方法并不一定会为了获得更大的容量，替换掉现有的内容容器，而是先会本着尽量减少内存分配和内容拷贝的原则，对当前的内容容器进行重用。并且，只有在容量实在无法满足要求的时候，它才会去创建新的内容容器。

此外，你可能并没有想到，`Buffer`值的某些方法可能会造成内容的泄露。这主要是由于这些方法返回的结果值，在一段时期内会与其所属值的内容容器共用同一个底层数组。

**如果我们有意或无意地把这些结果值传到了外界，那么外界就有可能通过它们操纵相关联`Buffer`值的内容。**

这属于很严重的数据安全问题。我们一定要避免这种情况的发生。最彻底的做法是，在传出切片这类值之前要做好隔离。比如，先对它们进行深度拷贝，然后再把副本传出去。

## 思考题

今天的思考题是：对比`strings.Builder`和`bytes.Buffer`的`String`方法，并判断哪一个更高效？原因是什么？

[戳此查看Go语言专栏文章配套详细代码。](https://github.com/hyper0x/Golang_Puzzlers)
<div><strong>精选留言（15）</strong></div><ul>
<li><span>moonfox</span> 👍（1） 💬（3）<p>文章中说：“如果当前内容容器的容量的一半，仍然大于或等于其现有长度再加上另需的字节数的和，cap(b.buf)&#47;2 &gt;= len(b.buf)+need”。

如果是这样的话，那说明还有很多的未使用的空间，起码有一半，那就不用扩容，直接追加就可以了。所以这里的代码是错的，源码(1.16.2)中是 n &lt;= c&#47;2-m ，即cap(b.buf) &gt;= b.Len() + need，也就是未读字节长度 + 另需的字节数 小于等于容量的一半时，才会把未读字节copy到buf的头部，只有在未读字节较少的时候，才发生copy，如果有太多的未读字节，就不copy到头部了(费时)</p>2021-06-02</li><br/><li><span>Lywane</span> 👍（1） 💬（1）<p>老师，Buffer的Write，WriteString方法返回一个int，一个err，int是参数长度，err永远是nil，感觉这个返回没啥用啊。这么设计是为了实现某些接口么？</p>2020-04-08</li><br/><li><span>疯琴</span> 👍（1） 💬（1）<p>请问老师，用 bytes.Buffer 而不用字节切片是因为它有计数器和一些方法使得操作更方便，还有高效的扩容策略么。这么说对么？</p>2020-01-07</li><br/><li><span>窗外</span> 👍（1） 💬（4）<p>老师你好，为什么我本地的src&#47;runtime包下的stringtoslicebyte方法里面tmpBuf的默认长度是32。
所以文中例子，输出的容量是32</p>2019-08-11</li><br/><li><span>killer</span> 👍（0） 💬（1）<p>2023年了都，大佬还在看评论吗？写了4年go了总感觉差点意思，最近把郝大佬的文章翻出来每篇仔细阅读、做笔记、看源码，另外也在团队给大家分享golang的学习之路特别充实；

对stringtoslicebyte做了debug，没想到cap为8是这么来的

func stringtoslicebyte(buf *tmpBuf, s string) []byte {
	var b []byte
	if buf != nil &amp;&amp; len(s) &lt;= len(buf) {
		*buf = tmpBuf{}
		b = buf[:len(s)]
	} else {
		b = rawbyteslice(len(s))&#47;&#47; bytes.Buffer 初始化 buf 为空，需要调用 rawbyteslice 初始化 slice
	}
	copy(b, s)
	return b
}


func rawbyteslice(size int) (b []byte) {
	cap := roundupsize(uintptr(size))&#47;&#47; roundupsize 计算容量，重点关注这里
	p := mallocgc(cap, nil, false)&#47;&#47; 分配内存
	if cap != uintptr(size) {
		memclrNoHeapPointers(add(p, uintptr(size)), cap-uintptr(size))
	}

	*(*slice)(unsafe.Pointer(&amp;b)) = slice{p, size, int(cap)}
	return
}


&#47;&#47; Returns size of the memory block that mallocgc will allocate if you ask for the size.
func roundupsize(size uintptr) uintptr {
	if size &lt; _MaxSmallSize {
		if size &lt;= smallSizeMax-8 {		&#47;&#47; 以大佬例子为例：contents := &quot;ab&quot; buffer1 := bytes.NewBufferString(contents)，size长度为2，肯定小于smallSizeMax-8
			return uintptr(class_to_size[size_to_class8[divRoundUp(size, smallSizeDiv)]]) &#47;&#47; divRoundUp 函数算出来 为1， size_to_class8[1]=1;class_to_size[1]=8返回的uintptr为8，这里做了一个约定类似于查表
		} else {
			return uintptr(class_to_size[size_to_class128[divRoundUp(size-smallSizeMax, largeSizeDiv)]])
		}
	}
	if size+_PageSize &lt; size {
		return size
	}
	return alignUp(size, _PageSize)
}


&#47;&#47; 这里算出来是1
func divRoundUp(n, a uintptr) uintptr {
	&#47;&#47; a is generally a power of two. This will get inlined and
	&#47;&#47; the compiler will optimize the division.
	return (n + a - 1) &#47; a  &#47;&#47; (8+2-1)&#47; 8=1
}</p>2023-12-20</li><br/><li><span>costaLong</span> 👍（0） 💬（1）<p>	contents := &quot;ab&quot;
	buffer1 := bytes.NewBufferString(contents)
	fmt.Printf(&quot;The capacity of new buffer with content %q: %d\n&quot;, contents, buffer1.Cap()) &#47;&#47; 内容容器的容量：8
单独执行这段代码输出的结果是：The capacity of new buffer with content &quot;ab&quot;: 32
 请问是原因呢</p>2022-02-17</li><br/><li><span>rename</span> 👍（0） 💬（2）<p>如果当前内容容器的容量的一半，仍然大于或等于其现有长度再加上所需的字节数的和，即：cap(b.buf)&#47;2 &gt;= len(b.buf)+need
这边len(b.buf)用b.Len()似乎更准确？才是获取未读部分的实际长度</p>2019-07-14</li><br/><li><span>嘎嘎</span> 👍（0） 💬（1）<p>源码里给了推荐的构建方法
&#47;&#47; To build strings more efficiently, see the strings.Builder type.
func (b *Buffer) String() string {
	if b == nil {
		&#47;&#47; Special case, useful in debugging.
		return &quot;&lt;nil&gt;&quot;
	}
	return string(b.buf[b.off:])
}</p>2019-03-15</li><br/><li><span>失了智的沫雨</span> 👍（34） 💬（3）<p>如果只看strings.Builder 和bytes.Buffer的String方法的话，strings.Builder 更高效一些。
我们可以直接查看两个String方法的源代码，其中strings.Builder String方法中
*(*string)(unsafe.Pointer(&amp;b.buf))  是直接取得buf的地址然后转换成string返回。
而bytes.Buffer的String方法是   string(b.buf[b.off:])
 对buf 进行切片操作,我认为这比直接取址要花费更多的时间。
测试函数:
func BenchmarkStrings(b *testing.B) {
	str := strings.Builder{}&#47;bytes.Buffer{}
	str.WriteString(&quot;test&quot;)
	for i := 0; i &lt; b.N; i++ {
		str.String()
	}
}
结果为
BenchmarkStrings-8   	2000000000	         0.66 ns&#47;op
BenchmarkBuffer-8    	300000000	         5.64 ns&#47;op
所以strings.Builder的String方法更高效</p>2018-11-11</li><br/><li><span>🐻</span> 👍（7） 💬（0）<p>https:&#47;&#47;github.com&#47;golang&#47;go&#47;blob&#47;master&#47;src&#47;strings&#47;builder_test.go#L319-L366

发现最后的问题，Go 的标准库中，已经给出了相关的测试代码了。</p>2019-04-26</li><br/><li><span>1thinc0</span> 👍（5） 💬（0）<p>bytes.Buffer 值的 String() 方法在转换时采用了指针 *(*string)(unsafe.Pointer(&amp;b.buf))，更节省时间和内存</p>2018-11-16</li><br/><li><span>Geek_51aa7f</span> 👍（3） 💬（0）<p>在Byte()或者Next()结果返回的字节切片处理后才可以返回给外部函数
unreadBytes = unreadBytes[:len(unreadBytes):len(unreadBytes)]</p>2020-06-07</li><br/><li><span>骏Jero</span> 👍（3） 💬（0）<p>读了老师的两篇文章，strings.Builder更多是拼接数据和以及拼接完成后的读取使用上应该更适合。而buffer更为动态接受和读取数据时，更为高效。</p>2018-11-09</li><br/><li><span>cygnus</span> 👍（2） 💬（1）<p>```
func (b *Buffer) grow(n int) int {
        ......
	&#47;&#47; Restore b.off and len(b.buf).
	b.off = 0
	b.buf = b.buf[:m+n]
	return m

func (b *Buffer) Grow(n int) {
	if n &lt; 0 {
		panic(&quot;bytes.Buffer.Grow: negative count&quot;)
	}
	m := b.grow(n)
	b.buf = b.buf[:m]
}
```
请问下老师，bytes.Buffer里grow函数返回前做过一次切片b.buf = b.buf[:m+n]，返回后在Grow函数又做了一次切片b.buf = b.buf[:m]，这样做的目的是什么呢？感觉有点冗余</p>2018-11-13</li><br/><li><span>Aeins</span> 👍（0） 💬（0）<p>“你可能会有疑惑，我只在这个Buffer值中放入了一个长度为2的字符串值，但为什么该值的容量却变为了8”

目前，字符串长度小于 32 的直接分配在缓冲区上，Cap 是 32，大于 32 的，再重新分配内存</p>2022-06-10</li><br/>
</ul>