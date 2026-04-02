我在上两篇文章中，详细地讲述了Go语言中的错误处理，并从两个视角为你总结了错误类型、错误值的处理技巧和设计方式。

在本篇，我要给你展示Go语言的另外一种错误处理方式。不过，严格来说，它处理的不是错误，而是异常，并且是一种在我们意料之外的程序异常。

## 前导知识：运行时恐慌panic

这种程序异常被叫做panic，我把它翻译为运行时恐慌。其中的“恐慌”二字是由panic直译过来的，而之所以前面又加上了“运行时”三个字，是因为这种异常只会在程序运行的时候被抛出来。

我们举个具体的例子来看看。

比如说，一个Go程序里有一个切片，它的长度是5，也就是说该切片中的元素值的索引分别为`0`、`1`、`2`、`3`、`4`，但是，我在程序里却想通过索引`5`访问其中的元素值，显而易见，这样的访问是不正确的。

Go程序，确切地说是程序内嵌的Go语言运行时系统，会在执行到这行代码的时候抛出一个“index out of range”的panic，用以提示你索引越界了。

当然了，这不仅仅是个提示。当panic被抛出之后，如果我们没有在程序里添加任何保护措施的话，程序（或者说代表它的那个进程）就会在打印出panic的详细情况（以下简称panic详情）之后，终止运行。

现在，就让我们来看一下这样的panic详情中都有什么。

```
panic: runtime error: index out of range

goroutine 1 [running]:
main.main()
 /Users/haolin/GeekTime/Golang_Puzzlers/src/puzzlers/article19/q0/demo47.go:5 +0x3d
exit status 2
```

这份详情的第一行是“panic: runtime error: index out of range”。其中的“runtime error”的含义是，这是一个`runtime`代码包中抛出的panic。在这个panic中，包含了一个`runtime.Error`接口类型的值。`runtime.Error`接口内嵌了`error`接口，并做了一点点扩展，`runtime`包中有不少它的实现类型。

实际上，此详情中的“panic：”右边的内容，正是这个panic包含的`runtime.Error`类型值的字符串表示形式。

此外，panic详情中，一般还会包含与它的引发原因有关的goroutine的代码执行信息。正如前述详情中的“goroutine 1 \[running]”，它表示有一个ID为`1`的goroutine在此panic被引发的时候正在运行。

注意，这里的ID其实并不重要，因为它只是Go语言运行时系统内部给予的一个goroutine编号，我们在程序中是无法获取和更改的。

我们再看下一行，“main.main()”表明了这个goroutine包装的`go`函数就是命令源码文件中的那个`main`函数，也就是说这里的goroutine正是主goroutine。再下面的一行，指出的就是这个goroutine中的哪一行代码在此panic被引发时正在执行。

这包含了此行代码在其所属的源码文件中的行数，以及这个源码文件的绝对路径。这一行最后的`+0x3d`代表的是：此行代码相对于其所属函数的入口程序计数偏移量。不过，一般情况下它的用处并不大。

最后，“exit status 2”表明我的这个程序是以退出状态码`2`结束运行的。在大多数操作系统中，只要退出状态码不是`0`，都意味着程序运行的非正常结束。在Go语言中，因panic导致程序结束运行的退出状态码一般都会是`2`。

综上所述，我们从上边的这个panic详情可以看出，作为此panic的引发根源的代码处于demo47.go文件中的第5行，同时被包含在`main`包（也就是命令源码文件所在的代码包）的`main`函数中。

那么，我的第一个问题也随之而来了。我今天的问题是：**从panic被引发到程序终止运行的大致过程是什么？**

**这道题的典型回答是这样的。**

我们先说一个大致的过程：某个函数中的某行代码有意或无意地引发了一个panic。这时，初始的panic详情会被建立起来，并且该程序的控制权会立即从此行代码转移至调用其所属函数的那行代码上，也就是调用栈中的上一级。

这也意味着，此行代码所属函数的执行随即终止。紧接着，控制权并不会在此有片刻的停留，它又会立即转移至再上一级的调用代码处。控制权如此一级一级地沿着调用栈的反方向传播至顶端，也就是我们编写的最外层函数那里。

这里的最外层函数指的是`go`函数，对于主goroutine来说就是`main`函数。但是控制权也不会停留在那里，而是被Go语言运行时系统收回。

随后，程序崩溃并终止运行，承载程序这次运行的进程也会随之死亡并消失。与此同时，在这个控制权传播的过程中，panic详情会被逐渐地积累和完善，并会在程序终止之前被打印出来。

## 问题解析

panic可能是我们在无意间（或者说一不小心）引发的，如前文所述的索引越界。这类panic是真正的、在我们意料之外的程序异常。不过，除此之外，我们还是可以有意地引发panic。

Go语言的内建函数`panic`是专门用于引发panic的。`panic`函数使程序开发者可以在程序运行期间报告异常。

注意，这与从函数返回错误值的意义是完全不同的。当我们的函数返回一个非`nil`的错误值时，函数的调用方有权选择不处理，并且不处理的后果往往是不致命的。

这里的“不致命”的意思是，不至于使程序无法提供任何功能（也可以说僵死）或者直接崩溃并终止运行（也就是真死）。

但是，当一个panic发生时，如果我们不施加任何保护措施，那么导致的直接后果就是程序崩溃，就像前面描述的那样，这显然是致命的。

为了更清楚地展示答案中描述的过程，我编写了demo48.go文件。你可以先查看一下其中的代码，再试着运行它，并体会它打印的内容所代表的含义。

我在这里再提示一点。panic详情会在控制权传播的过程中，被逐渐地积累和完善，并且，控制权会一级一级地沿着调用栈的反方向传播至顶端。

因此，在针对某个goroutine的代码执行信息中，调用栈底端的信息会先出现，然后是上一级调用的信息，以此类推，最后才是此调用栈顶端的信息。

比如，`main`函数调用了`caller1`函数，而`caller1`函数又调用了`caller2`函数，那么`caller2`函数中代码的执行信息会先出现，然后是`caller1`函数中代码的执行信息，最后才是`main`函数的信息。

```
goroutine 1 [running]:
main.caller2()
 /Users/haolin/GeekTime/Golang_Puzzlers/src/puzzlers/article19/q1/demo48.go:22 +0x91
main.caller1()
 /Users/haolin/GeekTime/Golang_Puzzlers/src/puzzlers/article19/q1/demo48.go:15 +0x66
main.main()
 /Users/haolin/GeekTime/Golang_Puzzlers/src/puzzlers/article19/q1/demo48.go:9 +0x66
exit status 2
```

![](https://static001.geekbang.org/resource/image/60/d7/606ff433a6b58510f215e57792822bd7.png?wh=887%2A1060)

（从panic到程序崩溃）

好了，到这里，我相信你已经对panic被引发后的程序终止过程有一定的了解了。深入地了解此过程，以及正确地解读panic详情应该是我们的必备技能，这在调试Go程序或者为Go程序排查错误的时候非常重要。

## 总结

最近的两篇文章，我们是围绕着panic函数、recover函数以及defer语句进行的。今天我主要讲了panic函数。这个函数是专门被用来引发panic的。panic也可以被称为运行时恐慌，它是一种只能在程序运行期间抛出的程序异常。

Go语言的运行时系统可能会在程序出现严重错误时自动地抛出panic，我们在需要时也可以通过调用`panic`函数引发panic。但不论怎样，如果不加以处理，panic就会导致程序崩溃并终止运行。

## 思考题

一个函数怎样才能把panic转化为`error`类型值，并将其作为函数的结果值返回给调用方？

[戳此查看Go语言专栏文章配套详细代码。](https://github.com/hyper0x/Golang_Puzzlers)
<div><strong>精选留言（15）</strong></div><ul>
<li><span>锋</span> 👍（20） 💬（8）<p>老师，你好，我有一个疑问，请教一下，谢谢~
Go在设计的时候没有设计try...catch...finally这样的方式来捕获异常。
我在网上查很多人用panic、defer和recover组合来实现异常的捕获，甚至很多都将这个二次封装之后作为一个库来进行使用。
我的疑问是，从Go的设计角度为什么要这么做？是出于什么样的目的，还是他俩之间有什么优劣？
非常感谢~，烦请解答。</p>2020-03-06</li><br/><li><span>唐丹</span> 👍（12） 💬（5）<p>郝大，你好，我在golang 8中通过recover处理panic时发现，必须在引发panic的当前协程就处理掉，否则待其传递到父协程直至main方法中，都不能通过recover成功处理掉了，程序会因此结束。请问这样设计的原因是什么？那么协程是通过panic中记录的协程id来区分是不是在当前协程引发的panic的吗？另外，这样的话，我们应用程序中每一个通过go新起的协程都应该在开始的地方recover，否则即使父协程有recover也不能阻止程序因为一个意外的panic而挂掉？盼望解答，谢谢🙏</p>2018-09-28</li><br/><li><span>沐夜星光</span> 👍（4） 💬（2）<p>“控制权如此一级一级地沿着调用栈的反方向传播至顶端，也就是我们编写的最外层函数那里”。最外层函数是go函数，也就说当panic触发，通过其所在的goroutine，将控制权转移给运行时系统时，是不一定经过main函数的吗？另外老师能不能讲讲，go是怎么回收一个进程的，怎么处理运行中的goroutine以及涉及的资源。</p>2020-05-21</li><br/><li><span>MClink</span> 👍（2） 💬（4）<p>初学go都会吐槽说没有 try catch , 应该不止我一个</p>2021-03-25</li><br/><li><span>阿俊</span> 👍（0） 💬（2）<p>请问老师 曾经我也是JAVA程序员 以前做JAVA项目 那时候遇到 例如 编写业务代码 “用户名称”不符合某种条件 业务逻辑代码会写throws 包含错误信息的自定义业务Exception 然后最终做一个try catch 然后catch到业务excption提取其中的message反馈给最终结果；如果在go项目开发中遇到类似问题，是不是可以通过的手动触发panic， 再在最终出口的地方，通过defer结合recover全局捕获相关panic并提取信息反馈给客户端也防止因此整个application崩掉，这种方式是否可取？ 想听听老师的观点，感谢~</p>2023-09-11</li><br/><li><span>Geek_37a441</span> 👍（0） 💬（4）<p>老师，你好，我想问下，panic触发的时机，比如指令执行过程中，在什么时候会调用到相关的panic，比如数组越界是什么时候调用runtime.panicIndex，是有个额外的线程不断检测有异常了吗？</p>2020-12-15</li><br/><li><span>江山如画</span> 👍（37） 💬（3）<p>一个函数如果要把 panic 转化为error类型值，并将其结果返回给调用方，可以考虑把 defer 语句封装到一个匿名函数之中，下面是实验的一个例子，所用函数是一个除法函数，当除数为0的时候会抛出 panic并捕获。

func divide(a, b int) (res int, err error) {
	func() {
		defer func() {
			if rec := recover(); rec != nil {
				err = fmt.Errorf(&quot;%s&quot;, rec)
			}
		}()
		res = a &#47; b
	}()
	return
}

func main() {
	res, err := divide(1, 0)
	fmt.Println(res, err) &#47;&#47; 0 runtime error: integer divide by zero

	res, err = divide(2, 1)
	fmt.Println(res, err) &#47;&#47; 2 &lt;nil&gt;
}
</p>2018-10-08</li><br/><li><span>Bang</span> 👍（14） 💬（0）<p>先使用go中的类似try catch这样的语句，将异常捕获的异常转为相应的错误error就可以了</p>2018-09-28</li><br/><li><span>冰激凌的眼泪</span> 👍（4） 💬（0）<p>panic时，会捕获异常及异常上下文（函数名+文件行）
类似看作有一个异常上下文列表，始于异常触发处，沿着函数调用逆向展开，每一级append自己的异常上下文，直至goroutine入口函数，最终被runtime捕获
最终异常信息被打印，异常上下文列表被顺序打印，程序退出</p>2018-10-02</li><br/><li><span>🐻</span> 👍（2） 💬（0）<p>https:&#47;&#47;gist.github.com&#47;bwangelme&#47;9ce1c606ba9f69c72f82722adf1402e1</p>2019-03-03</li><br/><li><span>A 凡</span> 👍（2） 💬（0）<p>之前自己学习时候的一些模糊点更加清晰了，支持！</p>2018-10-24</li><br/><li><span>MClink</span> 👍（0） 💬（0）<p>这个看起来比较简单
func main() {
	res, err := divide(1, 0)
	if err != nil {
		fmt.Println(err)
	}
	fmt.Println(res)
}

func divide(a, b int) (res int, err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf(&quot;omg, panic ! err:%v&quot;, r)
			return
		}
	}()
	res = a &#47; b
	return
}</p>2022-07-07</li><br/><li><span>Harlan</span> 👍（0） 💬（0）<p>go这种满屏幕都是 判断 err!=nil 这种没有意义的代码  代码侵入性极强  也不优雅</p>2021-08-12</li><br/><li><span>传说中的成大大</span> 👍（0） 💬（0）<p>今日总结
今天主要是讲了panic运行时恐慌，一般发生在运行时
同样也可以自己调用内置的panic来主动引起恐慌 一般用来自己调试程序异常等等
主要掌握panic的执行过程 
首先从某一行引起了panic 然后返回到其调用函数 这样一级一级的返回 直到最顶层也即main函数中 最后把控制权交给了go运行时状态，最后程序奔溃 进程退出
panic的信息一般也在这个返回过程中不断的完善
panic: runtime error: index out of range &#47;&#47;错误信息
&#47;&#47;以下是调用堆栈
goroutine 1 [running]:
main.caller2()
        &#47;home&#47;ubuntu&#47;geek_go&#47;Golang_Puzzlers&#47;src&#47;puzzlers&#47;article19&#47;q1&#47;demo48.go:22 +0x91
main.caller1()
        &#47;home&#47;ubuntu&#47;geek_go&#47;Golang_Puzzlers&#47;src&#47;puzzlers&#47;article19&#47;q1&#47;demo48.go:15 +0x66
main.main()
        &#47;home&#47;ubuntu&#47;geek_go&#47;Golang_Puzzlers&#47;src&#47;puzzlers&#47;article19&#47;q1&#47;demo48.go:9 +0x66
exit status 2
关于思考题 我也先想了一下 我们捕获异常并将错误信息封装到一个error当中最后返回这个err
后来又去翻了解答 好像就是这个 样子的</p>2020-03-25</li><br/><li><span>虢國技醬</span> 👍（0） 💬（0）<p>打卡</p>2019-01-21</li><br/>
</ul>