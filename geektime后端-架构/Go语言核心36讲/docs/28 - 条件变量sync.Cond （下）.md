你好，我是郝林，今天我继续分享条件变量sync.Cond的内容。我们紧接着上一篇的内容进行知识扩展。

## 问题 1：条件变量的`Wait`方法做了什么？

在了解了条件变量的使用方式之后，你可能会有这么几个疑问。

1. 为什么先要锁定条件变量基于的互斥锁，才能调用它的`Wait`方法？
2. 为什么要用`for`语句来包裹调用其`Wait`方法的表达式，用`if`语句不行吗？

这些问题我在面试的时候也经常问。你需要对这个`Wait`方法的内部机制有所了解才能回答上来。

条件变量的`Wait`方法主要做了四件事。

1. 把调用它的goroutine（也就是当前的goroutine）加入到当前条件变量的通知队列中。
2. 解锁当前的条件变量基于的那个互斥锁。
3. 让当前的goroutine处于等待状态，等到通知到来时再决定是否唤醒它。此时，这个goroutine就会阻塞在调用这个`Wait`方法的那行代码上。
4. 如果通知到来并且决定唤醒这个goroutine，那么就在唤醒它之后重新锁定当前条件变量基于的互斥锁。自此之后，当前的goroutine就会继续执行后面的代码了。

你现在知道我刚刚说的第一个疑问的答案了吗？

因为条件变量的`Wait`方法在阻塞当前的goroutine之前，会解锁它基于的互斥锁，所以在调用该`Wait`方法之前，我们必须先锁定那个互斥锁，否则在调用这个`Wait`方法时，就会引发一个不可恢复的panic。

为什么条件变量的`Wait`方法要这么做呢？你可以想象一下，如果`Wait`方法在互斥锁已经锁定的情况下，阻塞了当前的goroutine，那么又由谁来解锁呢？别的goroutine吗？

先不说这违背了互斥锁的重要使用原则，即：成对的锁定和解锁，就算别的goroutine可以来解锁，那万一解锁重复了怎么办？由此引发的panic可是无法恢复的。

如果当前的goroutine无法解锁，别的goroutine也都不来解锁，那么又由谁来进入临界区，并改变共享资源的状态呢？只要共享资源的状态不变，即使当前的goroutine因收到通知而被唤醒，也依然会再次执行这个`Wait`方法，并再次被阻塞。

所以说，如果条件变量的`Wait`方法不先解锁互斥锁的话，那么就只会造成两种后果：不是当前的程序因panic而崩溃，就是相关的goroutine全面阻塞。

再解释第二个疑问。很显然，`if`语句只会对共享资源的状态检查一次，而`for`语句却可以做多次检查，直到这个状态改变为止。那为什么要做多次检查呢？

**这主要是为了保险起见。如果一个goroutine因收到通知而被唤醒，但却发现共享资源的状态，依然不符合它的要求，那么就应该再次调用条件变量的`Wait`方法，并继续等待下次通知的到来。**

这种情况是很有可能发生的，具体如下面所示。

1. 有多个goroutine在等待共享资源的同一种状态。比如，它们都在等`mailbox`变量的值不为`0`的时候再把它的值变为`0`，这就相当于有多个人在等着我向信箱里放置情报。虽然等待的goroutine有多个，但每次成功的goroutine却只可能有一个。别忘了，条件变量的`Wait`方法会在当前的goroutine醒来后先重新锁定那个互斥锁。在成功的goroutine最终解锁互斥锁之后，其他的goroutine会先后进入临界区，但它们会发现共享资源的状态依然不是它们想要的。这个时候，`for`循环就很有必要了。
2. 共享资源可能有的状态不是两个，而是更多。比如，`mailbox`变量的可能值不只有`0`和`1`，还有`2`、`3`、`4`。这种情况下，由于状态在每次改变后的结果只可能有一个，所以，在设计合理的前提下，单一的结果一定不可能满足所有goroutine的条件。那些未被满足的goroutine显然还需要继续等待和检查。
3. 有一种可能，共享资源的状态只有两个，并且每种状态都只有一个goroutine在关注，就像我们在主问题当中实现的那个例子那样。不过，即使是这样，使用`for`语句仍然是有必要的。原因是，在一些多CPU核心的计算机系统中，即使没有收到条件变量的通知，调用其`Wait`方法的goroutine也是有可能被唤醒的。这是由计算机硬件层面决定的，即使是操作系统（比如Linux）本身提供的条件变量也会如此。

综上所述，在包裹条件变量的`Wait`方法的时候，我们总是应该使用`for`语句。

好了，到这里，关于条件变量的`Wait`方法，我想你知道的应该已经足够多了。

## 问题 2：条件变量的`Signal`方法和`Broadcast`方法有哪些异同？

条件变量的`Signal`方法和`Broadcast`方法都是被用来发送通知的，不同的是，前者的通知只会唤醒一个因此而等待的goroutine，而后者的通知却会唤醒所有为此等待的goroutine。

条件变量的`Wait`方法总会把当前的goroutine添加到通知队列的队尾，而它的`Signal`方法总会从通知队列的队首开始，查找可被唤醒的goroutine。所以，因`Signal`方法的通知，而被唤醒的goroutine一般都是最早等待的那一个。

这两个方法的行为决定了它们的适用场景。如果你确定只有一个goroutine在等待通知，或者只需唤醒任意一个goroutine就可以满足要求，那么使用条件变量的`Signal`方法就好了。

否则，使用`Broadcast`方法总没错，只要你设置好各个goroutine所期望的共享资源状态就可以了。

此外，再次强调一下，与`Wait`方法不同，条件变量的`Signal`方法和`Broadcast`方法并不需要在互斥锁的保护下执行。恰恰相反，我们最好在解锁条件变量基于的那个互斥锁之后，再去调用它的这两个方法。这更有利于程序的运行效率。

最后，请注意，条件变量的通知具有即时性。也就是说，如果发送通知的时候没有goroutine为此等待，那么该通知就会被直接丢弃。在这之后才开始等待的goroutine只可能被后面的通知唤醒。

你可以打开demo62.go文件，并仔细观察它与demo61.go的不同。尤其是`lock`变量的类型，以及发送通知的方式。

## 总结

我们今天主要讲了条件变量，它是基于互斥锁的一种同步工具。在Go语言中，我们需要用`sync.NewCond`函数来初始化一个`sync.Cond`类型的条件变量。

`sync.NewCond`函数需要一个`sync.Locker`类型的参数值。

`*sync.Mutex`类型的值以及`*sync.RWMutex`类型的值都可以满足这个要求。另外，后者的`RLocker`方法可以返回这个值中的读锁，也同样可以作为`sync.NewCond`函数的参数值，如此就可以生成与读写锁中的读锁对应的条件变量了。

条件变量的`Wait`方法需要在它基于的互斥锁保护下执行，否则就会引发不可恢复的panic。此外，我们最好使用`for`语句来检查共享资源的状态，并包裹对条件变量的`Wait`方法的调用。

不要用`if`语句，因为它不能重复地执行“检查状态-等待通知-被唤醒”的这个流程。重复执行这个流程的原因是，一个“因为等待通知，而被阻塞”的goroutine，可能会在共享资源的状态不满足其要求的情况下被唤醒。

条件变量的`Signal`方法只会唤醒一个因等待通知而被阻塞的goroutine，而它的`Broadcast`方法却可以唤醒所有为此而等待的goroutine。后者比前者的适应场景要多得多。

这两个方法并不需要受到互斥锁的保护，我们也最好不要在解锁互斥锁之前调用它们。还有，条件变量的通知具有即时性。当通知被发送的时候，如果没有任何goroutine需要被唤醒，那么该通知就会立即失效。

## 思考题

`sync.Cond`类型中的公开字段`L`是做什么用的？我们可以在使用条件变量的过程中改变这个字段的值吗？

[戳此查看Go语言专栏文章配套详细代码。](https://github.com/hyper0x/Golang_Puzzlers)
<div><strong>精选留言（15）</strong></div><ul>
<li><span>不记年</span> 👍（20） 💬（1）<p>老师，我有一个疑问，对于cond来说，每次只唤醒一个goruntine，如果这么goruntine发现消息不是自己想要的就会从新阻塞在wait函数中，那么真正需要这个消息的goruntine还会被唤醒吗？</p>2019-07-24</li><br/><li><span>Laughing</span> 👍（15） 💬（1）<p>L公开变量代表cond初始化时传递进来的锁，这个锁的状态是可以改变的，但会影响cond对互斥锁的控制。</p>2018-10-15</li><br/><li><span>Lywane</span> 👍（6） 💬（1）<p>```
	lock.Lock()
	for mailbox == 1 {
		sendCond.Wait()
	}
	mailbox = 1
	lock.Unlock()
	recvCond.Signal()
```
只要共享资源的状态不变，即使当前的 goroutine 因收到通知而被唤醒，也依然会再次执行这个Wait方法，并再次被阻塞。

老师我对这句话有个疑问，假设Wait不解锁，直接阻塞了当前goroutine，那么当收到通知时，mailbox的值应该已经被改成0了，此时唤醒，应该不满足for循环条件了呀，为什么会再次执行Wait方法呢？

我思考的结论是：Wait解锁是为了让其他goroutine去修改mailbox的值，不知道这么理解对吗。</p>2020-03-27</li><br/><li><span>Geek_a8be59</span> 👍（2） 💬（1）<p>老实您好，不太明白为什么一定要用条件变量呢。我看了 go并发编程第2版和你这边的做了对应，书上是已生成者消费者为例，我想的是用两个互斥量不行么？生成一个锁，消费一个锁，只是说可能会浪费在循环判断是否可生成，是否可消费中，还有可能因为某些不成功导致一直不能解锁的状况。  难不成条件变量主要就是优化上述问题的么？</p>2019-08-12</li><br/><li><span>樂文💤</span> 👍（2） 💬（3）<p>所以如果用的signal方法只通知一个go routine的话 条件变量的判断方法改成if应该是没问题的 但如果是多个go routine 同时被唤醒就可能导致多个go routine 在不满足唤醒状态的时候被唤醒而导致处理错误，这时候就必须用for来不断地进行检测可以这么理解么</p>2019-08-03</li><br/><li><span>手指饼干</span> 👍（1） 💬（1）<p>老师您好，关于发送通知是否需要在锁的保护下调用，还是有些疑问，以下想法请老师帮忙看看是否理解正确：
一个在等待通知的 goroutine 收到通知信号被唤醒，接下来执行的是条件变量 c.L.Lock() 操作，无论信号的发送方是否是在锁的保护下发送信号，该 goroutine 已经不是在等待通知的状态了，而是在尝试获取锁的状态，即使被阻塞，也是因为获取不到锁。区别只是，如果信号发送方在 Unlock() 之后发送信号，那么该 goroutine 被唤醒后获得锁可能会衔接得更好一点。
对于某些场景，比如说函数的开头两行代码就是
mutex.Lock() 
defer mutex.Unlock()
这种情况是否可以允许通知在 Unlock() 之前调用</p>2020-08-01</li><br/><li><span>黄仲辉</span> 👍（0） 💬（1）<p>sync.crod 类比 java的 监视器锁</p>2022-09-04</li><br/><li><span>Geek_108cb5</span> 👍（0） 💬（1）<p>试了一下把互斥锁改成读写锁， 中途会发生一个发送消息被两个接受者同时收到的场景， 导致最后发送者阻塞， 此时主线程的信道也阻塞了， 接受者协程执行完毕， 整体是死锁的情况。 那假如发送者和接收者都是无限循环， 而且多个接收者接收者接到同一份消息不会对业务有影响的情况下， 使用读写锁应该也是没有问题的？</p>2022-03-01</li><br/><li><span>HiNeNi</span> 👍（0） 💬（1）<p>func testCond() {
	mu := sync.Mutex{}
	cond := sync.NewCond(&amp;mu)
	s := &quot;&quot;

	go func () {
		fmt.Println(&quot;This is consumer&quot;)
		for {
			mu.Lock()

			for len(s) == 0 {
				cond.Wait()
			}
			&#47;&#47;time.Sleep(time.Second * 1)
			fmt.Println(&quot;consumer, s:&quot;, s)
			s = &quot;&quot;
			mu.Unlock()
			cond.Signal()
		}
	}()

	go func () {
		fmt.Println(&quot;This is producer&quot;)
		for {
			mu.Lock()
			for len(s) &gt; 0 {
				cond.Wait()
			}
			fmt.Println(&quot;produce a string&quot;)
			s = &quot;generate s resource&quot;
			mu.Unlock()
			cond.Signal()
		}

	}()

	time.Sleep(time.Second * 10)
}
==========================================
自己测的时候发现用一个Cond就可以满足生产者消费者的简单模型，谁能告诉我为什么例子一定要使用两个Cond？</p>2021-11-11</li><br/><li><span>传说中的成大大</span> 👍（0） 💬（1）<p>看了你下面的留言 感觉条件变量主要是为了避免互斥锁或者读写锁 锁竞争条件</p>2020-04-07</li><br/><li><span>传说中的成大大</span> 👍（0） 💬（1）<p>今天主要讲的go的同步 条件变量
总的来说我又去看了一下unix环境高级编程的条件变量感觉二者一样
这两个方法并不需要受到互斥锁的保护，我们也最好不要在解锁互斥锁之前调用它们
关于这个结论的我猜测是如果没有解锁 某个goroutine 还没解锁又被唤醒了 但是又不是它想要的共享状态 然后又加锁 又进入wait导致死锁？</p>2020-04-07</li><br/><li><span>Lywane</span> 👍（0） 💬（1）<p>它们都在等mailbox变量的值不为0的时候再把它的值变为0，这就相当于有多个人在等着我向信箱里放置情报。

老师这里不对吧，上一讲说的是`mailbox 代表信箱。0代表信箱是空的，1代表信箱是满的`。大家等着把mailbox设置为0，应该是都在等着拿信</p>2020-03-27</li><br/><li><span>疯琴</span> 👍（0） 💬（1）<p>wait的原理讲解很清晰。

请问老师两个问题：
1. 收信人也修改了mailbox，为什么不用写锁？我试了一下，如果把收信人分成两个goroutine，一个循环2次另一个循环3次，有可能两个收信人先后连续收了信，这样最后一步是发信人发信。recvCond.Signal()只唤醒一个收信人，为什么会有两个收信人先后连续收信呢？我把recvCond改成用写锁就恢复正常了。用写锁是为了演示一下获取写锁的方法么？
package main

import (
	&quot;log&quot;
	&quot;sync&quot;
	&quot;time&quot;
)

func main() {
	var mailbox uint8
	var lock sync.RWMutex
	sendCond := sync.NewCond(&amp;lock)
	recvCond := sync.NewCond(lock.RLocker())

	sign := make(chan struct{}, 3)
	max := 5

	&#47;&#47; 发信
	go func(max int) {
		defer func() {
			sign &lt;- struct{}{}
		}()

		for i := 1; i &lt;= max; i++ {
			time.Sleep(time.Millisecond * 500)
			lock.Lock()
			for mailbox == 1 {
				sendCond.Wait()
			}
			log.Printf(&quot;sender [%d]: the mail box is empty.&quot;, i)
			mailbox = 1
			log.Printf(&quot;sender [%d]: the letter has been send.&quot;, i)
			lock.Unlock()
			recvCond.Signal()
		}
	}(max)

	&#47;&#47; 收信
	go func(max int) {
		defer func() {
			sign &lt;- struct{}{}
		}()
		for j := 1; j &lt;= max; j++ {
			time.Sleep(time.Millisecond * 500)
			lock.RLock()
			for mailbox == 0 {
				recvCond.Wait()
			}
			log.Printf(&quot;receiver [%d]: the mail box is full.&quot;, j)
			mailbox = 0
			log.Printf(&quot;receiver [%d]: the letter has been received.&quot;, j)
			lock.RUnlock()
			sendCond.Signal()
		}
	}(2)

	&#47;&#47; 收信
	go func(max int) {
		defer func() {
			sign &lt;- struct{}{}
		}()
		for j := 1; j &lt;= max; j++ {
			time.Sleep(time.Millisecond * 500)
			lock.RLock()
			for mailbox == 0 {
				recvCond.Wait()
			}
			log.Printf(&quot;receiver [%d]: the mail box is full.&quot;, j)
			mailbox = 0
			log.Printf(&quot;receiver [%d]: the letter has been received.&quot;, j)
			lock.RUnlock()
			sendCond.Signal()
		}
	}(3)

	&lt;-sign
	&lt;-sign
	&lt;-sign

	log.Println(mailbox)
}
2. “当通知被发送的时候，如果没有任何 goroutine 需要被唤醒，那么该通知就会立即失效。”这一点我没有理解。我让收信人启动更晚一点，也就是发信人执行Signal()的时候收信人还没有Wait()，但是依然正常执行了。</p>2019-12-10</li><br/><li><span>K_night</span> 👍（0） 💬（1）<p>send := func(id int, index int) {
		&#47;&#47; defer func() {
		&#47;&#47; 	sign &lt;- struct{}{}
		&#47;&#47; }()
		lock.Lock()
		wakeupNum := 0
		log.Printf(&quot;wait before wakeupNum: [%d]&quot;, wakeupNum)
		for msgbox == 1 {
			fmt.Printf(&quot;wait before in for wakeupNum: [%d]&quot;, wakeupNum)
			&#47;&#47; log.Printf(&quot;wait before in for wakeupNum: [%d]&quot;, wakeupNum)
			sendCond.Wait()
			&#47;&#47; log.Printf(&quot;other Broadcast&quot;)
			wakeupNum = 1
			log.Printf(&quot;wait after wakeupNum: [%d]&quot;, wakeupNum)
		}
		log.Printf(&quot;sender: id:[%d] index:[%d] msgbox is empty&quot;, id, index)
		log.Printf(&quot;wakeupNum: [%d]&quot;, wakeupNum)
		sendNum = wakeupNum
		msgbox = 1
		log.Printf(&quot;sender: id:[%d] index:[%d] mail has been send&quot;, id, index)
		lock.Unlock()
		recvCond.Broadcast()
	}
for循环里面的代码被优化了吗。怎么没有执行呢。望老师解惑感谢</p>2019-11-26</li><br/><li><span>NIXUS</span> 👍（0） 💬（4）<p>请教老师一个问题: 
demo62.go中, 收信只是读数据, 可是为什么使用RLock()和RUnlock()就报错, 而必须要使用Lock()和Ulock()呢?</p>2019-04-15</li><br/>
</ul>