你好，我是陈皓，网名左耳朵耗子。

这节课，我着重介绍一下Go编程中的Pipeline模式。对于Pipeline，用过Unix/Linux命令行的人都不会陌生，**它是一种把各种命令拼接起来完成一个更强功能的技术方法**。

现在的流式处理、函数式编程、应用网关对微服务进行简单的API编排，其实都是受Pipeline这种技术方式的影响。Pipeline可以很容易地把代码按单一职责的原则拆分成多个高内聚低耦合的小模块，然后轻松地把它们拼装起来，去完成比较复杂的功能。

## HTTP 处理

这种Pipeline的模式，我在[上节课](https://time.geekbang.org/column/article/332608)中有过一个示例，我们再复习一下。

上节课，我们有很多 `WithServerHead()` 、`WithBasicAuth()` 、`WithDebugLog()`这样的小功能代码，在需要实现某个HTTP API 的时候，我们就可以很轻松地把它们组织起来。

原来的代码是下面这个样子：

```
http.HandleFunc("/v1/hello", WithServerHeader(WithAuthCookie(hello)))
http.HandleFunc("/v2/hello", WithServerHeader(WithBasicAuth(hello)))
http.HandleFunc("/v3/hello", WithServerHeader(WithBasicAuth(WithDebugLog(hello))))
```

通过一个代理函数：

```
type HttpHandlerDecorator func(http.HandlerFunc) http.HandlerFunc
func Handler(h http.HandlerFunc, decors ...HttpHandlerDecorator) http.HandlerFunc {
    for i := range decors {
        d := decors[len(decors)-1-i] // iterate in reverse
        h = d(h)
    }
    return h
}
```

我们就可以移除不断的嵌套，像下面这样使用了：

```
http.HandleFunc("/v4/hello", Handler(hello,
                WithServerHeader, WithBasicAuth, WithDebugLog))
```

## Channel 管理

当然，如果你要写出一个[泛型的Pipeline框架](https://coolshell.cn/articles/17929.html#%E6%B3%9B%E5%9E%8B%E7%9A%84%E4%BF%AE%E9%A5%B0%E5%99%A8)并不容易，可以使用[Go Generation](https://coolshell.cn/articles/21179.html)实现，但是，我们别忘了，Go语言最具特色的 Go Routine 和 Channel 这两个神器完全可以用来构造这种编程。

Rob Pike在 [Go Concurrency Patterns: Pipelines and cancellation](https://blog.golang.org/pipelines) 这篇博客中介绍了一种编程模式，下面我们来学习下。

### Channel转发函数

首先，我们需要一个 `echo()`函数，它会把一个整型数组放到一个Channel中，并返回这个Channel。

```
func echo(nums []int) <-chan int {
  out := make(chan int)
  go func() {
    for _, n := range nums {
      out <- n
    }
    close(out)
  }()
  return out
}
```

然后，我们依照这个模式，就可以写下下面的函数。

### 平方函数

```
func sq(in <-chan int) <-chan int {
  out := make(chan int)
  go func() {
    for n := range in {
      out <- n * n
    }
    close(out)
  }()
  return out
}
```

### 过滤奇数函数

```
func odd(in <-chan int) <-chan int {
  out := make(chan int)
  go func() {
    for n := range in {
      if n%2 != 0 {
        out <- n
      }
    }
    close(out)
  }()
  return out
}
```

### 求和函数

```
func sum(in <-chan int) <-chan int {
  out := make(chan int)
  go func() {
    var sum = 0
    for n := range in {
      sum += n
    }
    out <- sum
    close(out)
  }()
  return out
}
```

用户端的代码如下所示（注：你可能会觉得，sum()，odd() 和 sq()太过于相似，其实，你可以通过Map/Reduce编程模式或者是Go Generation的方式合并一下）：

```
var nums = []int{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
for n := range sum(sq(odd(echo(nums)))) {
  fmt.Println(n)
}
```

上面的代码类似于我们执行了Unix/Linux命令： `echo $nums | sq | sum`。同样，如果你不想有那么多的函数嵌套，就可以使用一个代理函数来完成。

```
type EchoFunc func ([]int) (<- chan int) 
type PipeFunc func (<- chan int) (<- chan int) 

func pipeline(nums []int, echo EchoFunc, pipeFns ... PipeFunc) <- chan int {
  ch  := echo(nums)
  for i := range pipeFns {
    ch = pipeFns[i](ch)
  }
  return ch
}
```

然后，就可以这样做了：

```
var nums = []int{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}    
for n := range pipeline(nums, gen, odd, sq, sum) {
    fmt.Println(n)
  }
```

## Fan in/Out

**动用Go语言的 Go Routine和 Channel还有一个好处，就是可以写出1对多，或多对1的Pipeline，也就是Fan In/ Fan Out**。下面，我们来看一个Fan in的示例。

假设我们要通过并发的方式对一个很长的数组中的质数进行求和运算，我们想先把数组分段求和，然后再把它们集中起来。

下面是我们的主函数：

```
func makeRange(min, max int) []int {
  a := make([]int, max-min+1)
  for i := range a {
    a[i] = min + i
  }
  return a
}

func main() {
  nums := makeRange(1, 10000)
  in := echo(nums)

  const nProcess = 5
  var chans [nProcess]<-chan int
  for i := range chans {
    chans[i] = sum(prime(in))
  }

  for n := range sum(merge(chans[:])) {
    fmt.Println(n)
  }
}
```

再看我们的 `prime()` 函数的实现 ：

```
func is_prime(value int) bool {
  for i := 2; i <= int(math.Floor(float64(value) / 2)); i++ {
    if value%i == 0 {
      return false
    }
  }
  return value > 1
}

func prime(in <-chan int) <-chan int {
  out := make(chan int)
  go func ()  {
    for n := range in {
      if is_prime(n) {
        out <- n
      }
    }
    close(out)
  }()
  return out
}
```

我来简单解释下这段代码。

- 首先，我们制造了从1到10000的数组；
- 然后，把这堆数组全部 `echo`到一个Channel里—— `in`；
- 此时，生成 5 个 Channel，接着都调用 `sum(prime(in))` ，于是，每个Sum的Go Routine都会开始计算和；
- 最后，再把所有的结果再求和拼起来，得到最终的结果。

其中的merge代码如下：

```
func merge(cs []<-chan int) <-chan int {
  var wg sync.WaitGroup
  out := make(chan int)

  wg.Add(len(cs))
  for _, c := range cs {
    go func(c <-chan int) {
      for n := range c {
        out <- n
      }
      wg.Done()
    }(c)
  }
  go func() {
    wg.Wait()
    close(out)
  }()
  return out
}
```

整个程序的结构如下图所示：

![](https://static001.geekbang.org/resource/image/f9/b3/f9d2b599620d5bc191194ff239f0a1b3.jpg?wh=3875%2A2250)

## 参考文档

如果你还想了解更多类似的与并发相关的技术，我再给你推荐一些资源：

- [Go Concurrency Patterns – Rob Pike – 2012 Google I/O presents the basics of Go‘s concurrency primitives and several ways to apply them.](https://www.youtube.com/watch?v=f6kdp27TYZs)
- [Advanced Go Concurrency Patterns – Rob Pike – 2013 Google I/O](https://blog.golang.org/advanced-go-concurrency-patterns)  
  [covers more complex uses of Go’s primitives, especially select.](https://blog.golang.org/advanced-go-concurrency-patterns)
- [Squinting at Power Series – Douglas McIlroy’s paper](https://swtch.com/~rsc/thread/squint.pdf)  
  [shows how Go-like concurrency provides elegant support for complex calculations.](https://swtch.com/~rsc/thread/squint.pdf)

好了，这节课就到这里。如果你觉得今天的内容对你有所帮助，欢迎你帮我分享给更多人。
<div><strong>精选留言（5）</strong></div><ul>
<li><span>Geek_Fantasy</span> 👍（5） 💬（0）<p>判断一个数是否是质数的方法可以优化一下。只需要枚举到value的平方根就可以，可以把复杂度从O(n)降到O(sqrt(n))。</p>2021-01-20</li><br/><li><span>ano</span> 👍（0） 💬（0）<p>merge 中的  wg.Wait() 为什么必须要放到一个单独的 goroutine 中呢？</p>2022-09-03</li><br/><li><span>Geek_ce6971</span> 👍（0） 💬（0）<p>pipeline 最后返回 &lt;- chan  类型，就像 java stream编程的输出流</p>2022-01-29</li><br/><li><span>方勇(gopher)</span> 👍（0） 💬（0）<p>Pipeline使用场景还是很多的，在做任务发布的时候会经常用到</p>2021-12-27</li><br/><li><span>你为啥那么牛</span> 👍（0） 💬（1）<p>没看明白 你是怎么分组的</p>2021-08-16</li><br/>
</ul>