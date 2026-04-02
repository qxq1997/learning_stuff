你好，我是郝林，今天我们继续来聊聊panic函数、recover函数以及defer语句的内容。

我在前一篇文章提到过这样一个说法，panic之中可以包含一个值，用于简要解释引发此panic的原因。

如果一个panic是我们在无意间引发的，那么其中的值只能由Go语言运行时系统给定。但是，当我们使用`panic`函数有意地引发一个panic的时候，却可以自行指定其包含的值。我们今天的第一个问题就是针对后一种情况提出的。

## 知识扩展

### 问题 1：怎样让panic包含一个值，以及应该让它包含什么样的值？

这其实很简单，在调用`panic`函数时，把某个值作为参数传给该函数就可以了。由于`panic`函数的唯一一个参数是空接口（也就是`interface{}`）类型的，所以从语法上讲，它可以接受任何类型的值。

但是，我们最好传入`error`类型的错误值，或者其他的可以被有效序列化的值。这里的“有效序列化”指的是，可以更易读地去表示形式转换。

还记得吗？对于`fmt`包下的各种打印函数来说，`error`类型值的`Error`方法与其他类型值的`String`方法是等价的，它们的唯一结果都是`string`类型的。

我们在通过占位符`%s`打印这些值的时候，它们的字符串表示形式分别都是这两种方法产出的。

一旦程序异常了，我们就一定要把异常的相关信息记录下来，这通常都是记到程序日志里。

我们在为程序排查错误的时候，首先要做的就是查看和解读程序日志；而最常用也是最方便的日志记录方式，就是记下相关值的字符串表示形式。

所以，如果你觉得某个值有可能会被记到日志里，那么就应该为它关联`String`方法。如果这个值是`error`类型的，那么让它的`Error`方法返回你为它定制的字符串表示形式就可以了。

对于此，你可能会想到`fmt.Sprintf`，以及`fmt.Fprintf`这类可以格式化并输出参数的函数。

是的，它们本身就可以被用来输出值的某种表示形式。不过，它们在功能上，肯定远不如我们自己定义的`Error`方法或者`String`方法。因此，为不同的数据类型分别编写这两种方法总是首选。

可是，这与传给`panic`函数的参数值又有什么关系呢？其实道理是相同的。至少在程序崩溃的时候，panic包含的那个值字符串表示形式会被打印出来。

另外，我们还可以施加某种保护措施，避免程序的崩溃。这个时候，panic包含的值会被取出，而在取出之后，它一般都会被打印出来或者记录到日志里。

既然说到了应对panic的保护措施，我们再来看下面一个问题。

### 问题 2：怎样施加应对panic的保护措施，从而避免程序崩溃？

Go语言的内建函数`recover`专用于恢复panic，或者说平息运行时恐慌。`recover`函数无需任何参数，并且会返回一个空接口类型的值。

如果用法正确，这个值实际上就是即将恢复的panic包含的值。并且，如果这个panic是因我们调用`panic`函数而引发的，那么该值同时也会是我们此次调用`panic`函数时，传入的参数值副本。请注意，这里强调用法的正确。我们先来看看什么是不正确的用法。

```
package main

import (
 "fmt"
 "errors"
)

func main() {
 fmt.Println("Enter function main.")
 // 引发panic。
 panic(errors.New("something wrong"))
 p := recover()
 fmt.Printf("panic: %s\n", p)
 fmt.Println("Exit function main.")
}
```

在上面这个`main`函数中，我先通过调用`panic`函数引发了一个panic，紧接着想通过调用`recover`函数恢复这个panic。可结果呢？你一试便知，程序依然会崩溃，这个`recover`函数调用并不会起到任何作用，甚至都没有机会执行。

还记得吗？我提到过panic一旦发生，控制权就会讯速地沿着调用栈的反方向传播。所以，在`panic`函数调用之后的代码，根本就没有执行的机会。

那如果我把调用`recover`函数的代码提前呢？也就是说，先调用`recover`函数，再调用`panic`函数会怎么样呢？

这显然也是不行的，因为，如果在我们调用`recover`函数时未发生panic，那么该函数就不会做任何事情，并且只会返回一个`nil`。

换句话说，这样做毫无意义。那么，到底什么才是正确的`recover`函数用法呢？这就不得不提到`defer`语句了。

顾名思义，`defer`语句就是被用来延迟执行代码的。延迟到什么时候呢？这要延迟到该语句所在的函数即将执行结束的那一刻，无论结束执行的原因是什么。

这与`go`语句有些类似，一个`defer`语句总是由一个`defer`关键字和一个调用表达式组成。

这里存在一些限制，有一些调用表达式是不能出现在这里的，包括：针对Go语言内建函数的调用表达式，以及针对`unsafe`包中的函数的调用表达式。

顺便说一下，对于`go`语句中的调用表达式，限制也是一样的。另外，在这里被调用的函数可以是有名称的，也可以是匿名的。我们可以把这里的函数叫做`defer`函数或者延迟函数。注意，被延迟执行的是`defer`函数，而不是`defer`语句。

我刚才说了，无论函数结束执行的原因是什么，其中的`defer`函数调用都会在它即将结束执行的那一刻执行。即使导致它执行结束的原因是一个panic也会是这样。正因为如此，我们需要联用`defer`语句和`recover`函数调用，才能够恢复一个已经发生的panic。

我们来看一下经过修正的代码。

```
package main

import (
 "fmt"
 "errors"
)

func main() {
 fmt.Println("Enter function main.")
 defer func(){
  fmt.Println("Enter defer function.")
  if p := recover(); p != nil {
   fmt.Printf("panic: %s\n", p)
  }
  fmt.Println("Exit defer function.")
 }()
 // 引发panic。
 panic(errors.New("something wrong"))
 fmt.Println("Exit function main.")
}
```

在这个`main`函数中，我先编写了一条`defer`语句，并在`defer`函数中调用了`recover`函数。仅当调用的结果值不为`nil`时，也就是说只有panic确实已发生时，我才会打印一行以“panic:”为前缀的内容。

紧接着，我调用了`panic`函数，并传入了一个`error`类型值。这里一定要注意，我们要尽量把`defer`语句写在函数体的开始处，因为在引发panic的语句之后的所有语句，都不会有任何执行机会。

也只有这样，`defer`函数中的`recover`函数调用才会拦截，并恢复`defer`语句所属的函数，及其调用的代码中发生的所有panic。

至此，我向你展示了两个很典型的`recover`函数的错误用法，以及一个基本的正确用法。

我希望你能够记住错误用法背后的缘由，同时也希望你能真正地理解联用`defer`语句和`recover`函数调用的真谛。

在命令源码文件demo50.go中，我把上述三种用法合并在了一段代码中。你可以运行该文件，并体会各种用法所产生的不同效果。

下面我再来多说一点关于`defer`语句的事情。

### 问题 3：如果一个函数中有多条`defer`语句，那么那几个`defer`函数调用的执行顺序是怎样的？

如果只用一句话回答的话，那就是：在同一个函数中，`defer`函数调用的执行顺序与它们分别所属的`defer`语句的出现顺序（更严谨地说，是执行顺序）完全相反。

当一个函数即将结束执行时，其中的写在最下边的`defer`函数调用会最先执行，其次是写在它上边、与它的距离最近的那个`defer`函数调用，以此类推，最上边的`defer`函数调用会最后一个执行。

如果函数中有一条`for`语句，并且这条`for`语句中包含了一条`defer`语句，那么，显然这条`defer`语句的执行次数，就取决于`for`语句的迭代次数。

并且，同一条`defer`语句每被执行一次，其中的`defer`函数调用就会产生一次，而且，这些函数调用同样不会被立即执行。

那么问题来了，这条`for`语句中产生的多个`defer`函数调用，会以怎样的顺序执行呢？

为了彻底搞清楚，我们需要弄明白`defer`语句执行时发生的事情。

其实也并不复杂，在`defer`语句每次执行的时候，Go语言会把它携带的`defer`函数及其参数值另行存储到一个链表中。

这个链表与该`defer`语句所属的函数是对应的，并且，它是先进后出（FILO）的，相当于一个栈。

在需要执行某个函数中的`defer`函数调用的时候，Go语言会先拿到对应的链表，然后从该链表中一个一个地取出`defer`函数及其参数值，并逐个执行调用。

这正是我说“`defer`函数调用与其所属的`defer`语句的执行顺序完全相反”的原因了。

下面该你出场了，我在demo51.go文件中编写了一个与本问题有关的示例，其中的核心代码很简单，只有几行而已。

我希望你先查看代码，然后思考并写下该示例被运行时，会打印出哪些内容。

如果你实在想不出来，那么也可以先运行示例，再试着解释打印出的内容。总之，你需要完全搞明白那几行内容为什么会以那样的顺序出现的确切原因。

## 总结

我们这两期的内容主要讲了两个函数和一条语句。`recover`函数专用于恢复panic，并且调用即恢复。

它在被调用时会返回一个空接口类型的结果值。如果在调用它时并没有panic发生，那么这个结果值就会是`nil`。

而如果被恢复的panic是我们通过调用`panic`函数引发的，那么它返回的结果值就会是我们传给`panic`函数参数值的副本。

对`recover`函数的调用只有在`defer`语句中才能真正起作用。`defer`语句是被用来延迟执行代码的。

更确切地说，它会让其携带的`defer`函数的调用延迟执行，并且会延迟到该`defer`语句所属的函数即将结束执行的那一刻。

在同一个函数中，延迟执行的`defer`函数调用，会与它们分别所属的`defer`语句的执行顺序完全相反。还要注意，同一条`defer`语句每被执行一次，就会产生一个延迟执行的`defer`函数调用。

这种情况在`defer`语句与`for`语句联用时经常出现。这时更要关注`for`语句中，同一条`defer`语句产生的多个`defer`函数调用的实际执行顺序。

以上这些，就是关于Go语言中特殊的程序异常，及其处理方式的核心知识。这里边可以衍生出很多面试题目。

## 思考题

我们可以在`defer`函数中恢复panic，那么可以在其中引发panic吗？

[戳此查看Go语言专栏文章配套详细代码。](https://github.com/hyper0x/Golang_Puzzlers)
<div><strong>精选留言（15）</strong></div><ul>
<li><span>wesleydeng</span> 👍（95） 💬（9）<p>从语言设计上，不使用try-catch而是用defer-recover有什么优势？c++和java作为先驱都使用try-catch，也比较清晰，为什么go作为新语言却要发明一个这样的新语法？有何设计上的考量？</p>2019-04-09</li><br/><li><span>凌惜沫</span> 👍（23） 💬（3）<p>如果defer中引发panic，那么在该段defer函数之前，需要另外一个defer来捕获该panic，并且代码中最后一个panic会被抛弃，由defer中的panic来成为最后的异常返回。</p>2019-04-22</li><br/><li><span>小龙虾</span> 👍（17） 💬（2）<p>我感觉还是go的这种设计好用，它会强迫开发者区别对待错误和异常，并做出不同的处理。相比try{}catch，我在开发中经常看到开发者把大段大段的代码或者整个处理写到try{}中，这本身就是对try{}catch的乱用</p>2019-04-23</li><br/><li><span>名:海东</span> 👍（4） 💬（3）<p>&#47;&#47;测试场景1
func Test()  {
	defer func() {
		if errRecover := recover(); errRecover != nil {
			fmt.Println(&quot;recover2...&quot;)
		}
		fmt.Println(&quot;no recover2...&quot;)
	}()
	defer func() {
		test01()  &#47;&#47; test01()方法在defer func(){}中执行
	}()
	b := 0
	a := 1 &#47; b
	fmt.Println(a)
	return
}

func test01() {
	if e := recover(); e != nil {
		fmt.Println(&quot;recover...&quot;)
	} else {
		fmt.Println(&quot;no recover...&quot;)
	}
	fmt.Println(&quot;defer exe...&quot;)
}

func main() {
	Test()
}
&#47;&#47;输出：
no recover...
defer exe...
recover2...
no recover2...

&#47;&#47;测试场景2
func Test()  {
	defer func() {
		if errRecover := recover(); errRecover != nil {
			fmt.Println(&quot;recover2...&quot;)
		}
		fmt.Println(&quot;no recover2...&quot;)
	}()
	defer test01()  &#47;&#47;test01()直接放到defer后面 
	b := 0
	a := 1 &#47; b
	fmt.Println(a)
	return
}

func test01() {
	if e := recover(); e != nil {
		fmt.Println(&quot;recover...&quot;)
	} else {
		fmt.Println(&quot;no recover...&quot;)
	}
	fmt.Println(&quot;defer exe...&quot;)
}

func main() {
	Test()
}
&#47;&#47;输出：
recover...
defer exe...
no recover2...

我的问题是：为什么场景1中出现panic没有在defer func() {
		test01()
	}()中被recover，而在defer func() {
		if errRecover := recover(); errRecover != nil {
			fmt.Println(&quot;recover2...&quot;)
		}
		fmt.Println(&quot;no recover2...&quot;)
	}()中被recover。
场景2使用defer test01 的写法后就可以被recover。</p>2020-07-08</li><br/><li><span>疯琴</span> 👍（4） 💬（1）<p>试验了一下在 goroutine 里面 panic，其他的 goroutine（比如main）是 recover()不到的：

func main() {
	fmt.Println(&quot;start&quot;)
	defer func() {
		if p := recover(); p != nil {
			fmt.Println(p)
		}
	}()
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer func() {
		    wg.Done()
		}()
		panic(errors.New(&quot;panic in goroutine&quot;))

	}()
	wg.Wait()
}</p>2019-12-07</li><br/><li><span>Zz~</span> 👍（3） 💬（2）<p>老师，您好，我想问一下，如果在main函数里调用一个我自定义的panic方法，recover可以恢复；但是如果我将自定义的panic方法改为go mypanic这样，recover就不能恢复。这是什么原因呢？下面是我实验的代码


==============可以恢复的==============
package main

import (
	&quot;errors&quot;
	&quot;fmt&quot;
)

func myRecover() {
	if err := recover(); err != nil {
		fmt.Printf(&quot;panic is %s&quot;, err)
	}
}

func myPanic() {
	panic(errors.New(&quot;自定义异常&quot;))
}

func main() {
	defer myRecover()
	myPanic()
}


=================不可以恢复的==============
package main

import (
	&quot;errors&quot;
	&quot;fmt&quot;
	&quot;time&quot;
)

func myRecover() {
	if err := recover(); err != nil {
		fmt.Printf(&quot;panic is %s&quot;, err)
	}
}

func myPanic() {
	panic(errors.New(&quot;自定义异常&quot;))
}

func main() {
	defer myRecover()
	go myPanic()
	time.Sleep(time.Second * 5)
}
</p>2021-01-02</li><br/><li><span>翼江亭赋</span> 👍（3） 💬（3）<p>iava世界里曾经try catch满天飞，现在还能看到不少这种代码，但逐渐大家认同了在去掉这种代码。

因为大部分catch住异常以后只是打个log再重新throw，这个交给框架代码在最外层catch住以后统一处理即可。非框架代码极少需要处理异常。

go世界里，err guard满天飞，但大部分的处理也是层层上传。但做不到不用，因为不像try那样去掉catch后会自动往上传递，不检查err的话就丢失了，所以这种代码去不掉。只能继续满天飞。

底层实现其实都是setjmp，主要的区别之一我认为是go设计者认为java异常的性能代价大。</p>2019-10-31</li><br/><li><span>来碗绿豆汤</span> 👍（3） 💬（1）<p>可以 defer 有点类似java中的final语句，里面还可以抛出异常。这样的好处是，我们捕获panic之后，可以对起内容进行查看，如果不是我们关注的panic那么可以继续抛出去</p>2018-10-01</li><br/><li><span>honnkyou</span> 👍（2） 💬（2）<p>「延迟到什么时候呢？这要延迟到该语句所在的函数即将执行结束的那一刻，无论结束执行的原因是什么。」
以该节课中代码为例的话是要吃到main函数快结束时执行是吗？执行defer函数。</p>2019-05-14</li><br/><li><span>有匪君子</span> 👍（2） 💬（1）<p>这个问题就引发了另一个问题。defer可以在同一个函数中嵌套使用吗？感觉这两个问题答案应该一致</p>2018-10-01</li><br/><li><span>张sir</span> 👍（1） 💬（1）<p>您好，请问defer函数压𣏾的时候，为什么把当时的入参也放入𣏾中呢
```
func test() {
	var a, b = 1, 1
	defer func(flag int) {
		fmt.Println(flag)
	}(a + b)

	a = 2
	b = 2

}

```

这个输出的２不是４的理论论据是什么呢</p>2020-03-12</li><br/><li><span>Pana</span> 👍（1） 💬（1）<p>在defer 中 recover 了panic ，是否还能让函数返回错误呢</p>2020-03-05</li><br/><li><span>大雄</span> 👍（0） 💬（1）<p>是否可以理解，我们一般自己返回的error都是可以预见的业务异常（例如：手机号码格式不正确等），可以灵活判断。
panic则是意料外的，但不需要终止进程，所以需要要recover恢复</p>2022-10-14</li><br/><li><span>jxs1211</span> 👍（0） 💬（2）<p>如果	s5 := s1[5]引发panic，可以在函数退出前通过defer语句中recover捕获并处理，哪是否有办法让函数继续执行完引发panic时后面哪些代码，像其他语言用try catch一样，能继续向下执行完整个函数的代码，还是说go的设计并不是如此，一定要在引发异常处立即返回
func caller2() (err error) {
	defer func() {
		p := recover()
		if p != nil {
			err = fmt.Errorf(&quot;error: %s\n&quot;, p)
		}
	}()
	fmt.Println(&quot;Enter function caller2.&quot;)
	s1 := []int{1, 2, 3, 4, 5}
	s5 := s1[5]
	_ = s5
	fmt.Println(&quot;Exit function caller2.&quot;)
	return err
}</p>2021-12-15</li><br/><li><span>爱学习的好孩子</span> 👍（0） 💬（1）<p>看不懂，defer函数和defer语句是什么关系？</p>2021-11-06</li><br/>
</ul>