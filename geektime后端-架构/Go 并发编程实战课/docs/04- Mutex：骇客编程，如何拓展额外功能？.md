你好，我是鸟窝。

前面三讲，我们学习了互斥锁Mutex的基本用法、实现原理以及易错场景，可以说是涵盖了互斥锁的方方面面。如果你能熟练掌握这些内容，那么，在大多数的开发场景中，你都可以得心应手。

但是，在一些特定的场景中，这些基础功能是不足以应对的。这个时候，我们就需要开发一些扩展功能了。我来举几个例子。

比如说，我们知道，如果互斥锁被某个goroutine获取了，而且还没有释放，那么，其他请求这把锁的goroutine，就会阻塞等待，直到有机会获得这把锁。有时候阻塞并不是一个很好的主意，比如你请求锁更新一个计数器，如果获取不到锁的话没必要等待，大不了这次不更新，我下次更新就好了，如果阻塞的话会导致业务处理能力的下降。

再比如，如果我们要监控锁的竞争情况，一个监控指标就是，等待这把锁的goroutine数量。我们可以把这个指标推送到时间序列数据库中，再通过一些监控系统（比如Grafana）展示出来。要知道，**锁是性能下降的“罪魁祸首”之一，所以，有效地降低锁的竞争，就能够很好地提高性能。因此，监控关键互斥锁上等待的goroutine的数量，是我们分析锁竞争的激烈程度的一个重要指标**。

实际上，不论是不希望锁的goroutine继续等待，还是想监控锁，我们都可以基于标准库中Mutex的实现，通过Hacker的方式，为Mutex增加一些额外的功能。这节课，我就来教你实现几个扩展功能，包括实现TryLock，获取等待者的数量等指标，以及实现一个线程安全的队列。

# TryLock

我们可以为Mutex添加一个TryLock的方法，也就是尝试获取排外锁。PS：在Go 1.18官方标准库中，已经为Mutex/RWMutex增加了TryLock方法。

这个方法具体是什么意思呢？我来解释一下这里的逻辑。当一个goroutine调用这个TryLock方法请求锁的时候，如果这把锁没有被其他goroutine所持有，那么，这个goroutine就持有了这把锁，并返回true；如果这把锁已经被其他goroutine所持有，或者是正在准备交给某个被唤醒的goroutine，那么，这个请求锁的goroutine就直接返回false，不会阻塞在方法调用上。

如下图所示，如果Mutex已经被一个goroutine持有，调用Lock的goroutine阻塞排队等待，调用TryLock的goroutine直接得到一个false返回。

![](https://static001.geekbang.org/resource/image/e7/65/e7787d959b60d66cc3a46ee921098865.jpg?wh=2973%2A1913)

在实际开发中，如果要更新配置数据，我们通常需要加锁，这样可以避免同时有多个goroutine并发修改数据。有的时候，我们也会使用TryLock。这样一来，当某个goroutine想要更改配置数据时，如果发现已经有goroutine在更改了，其他的goroutine调用TryLock，返回了false，这个goroutine就会放弃更改。

很多语言（比如Java）都为锁提供了TryLock的方法，但是，Go官方[issue 6123](https://github.com/golang/go/issues/6123)有一个讨论（后来一些issue中也提到过），标准库的Mutex不会添加TryLock方法。虽然通过Go的Channel我们也可以实现TryLock的功能，但是基于Channel的实现我们会放在Channel那一讲中去介绍，这一次我们还是基于Mutex去实现，毕竟大部分的程序员还是熟悉传统的同步原语，而且传统的同步原语也不容易出错。所以这节课，还是希望带你掌握基于Mutex实现的方法。

那怎么实现一个扩展TryLock方法的Mutex呢？我们直接来看代码。

```
// 复制Mutex定义的常量
const (
    mutexLocked = 1 << iota // 加锁标识位置
    mutexWoken              // 唤醒标识位置
    mutexStarving           // 锁饥饿标识位置
    mutexWaiterShift = iota // 标识waiter的起始bit位置
)

// 扩展一个Mutex结构
type Mutex struct {
    sync.Mutex
}

// 尝试获取锁
func (m *Mutex) TryLock() bool {
    // 如果能成功抢到锁
    if atomic.CompareAndSwapInt32((*int32)(unsafe.Pointer(&m.Mutex)), 0, mutexLocked) {
        return true
    }

    // 如果处于唤醒、加锁或者饥饿状态，这次请求就不参与竞争了，返回false
    old := atomic.LoadInt32((*int32)(unsafe.Pointer(&m.Mutex)))
    if old&(mutexLocked|mutexStarving|mutexWoken) != 0 {
        return false
    }

    // 尝试在竞争的状态下请求锁
    new := old | mutexLocked
    return atomic.CompareAndSwapInt32((*int32)(unsafe.Pointer(&m.Mutex)), old, new)
}
```

第17行是一个fast path，如果幸运，没有其他goroutine争这把锁，那么，这把锁就会被这个请求的goroutine获取，直接返回。

如果锁已经被其他goroutine所持有，或者被其他唤醒的goroutine准备持有，那么，就直接返回false，不再请求，代码逻辑在第23行。

如果没有被持有，也没有其它唤醒的goroutine来竞争锁，锁也不处于饥饿状态，就尝试获取这把锁（第29行），不论是否成功都将结果返回。因为，这个时候，可能还有其他的goroutine也在竞争这把锁，所以，不能保证成功获取这把锁。

我们可以写一个简单的测试程序，来测试我们的TryLock的机制是否工作。

这个测试程序的工作机制是这样子的：程序运行时会启动一个goroutine持有这把我们自己实现的锁，经过随机的时间才释放。主goroutine会尝试获取这把锁。如果前一个goroutine一秒内释放了这把锁，那么，主goroutine就有可能获取到这把锁了，输出“got the lock”，否则没有获取到也不会被阻塞，会直接输出“`can't get the lock`”。

```
func try() {
    var mu Mutex
    go func() { // 启动一个goroutine持有一段时间的锁
        mu.Lock()
        time.Sleep(time.Duration(rand.Intn(2)) * time.Second)
        mu.Unlock()
    }()

    time.Sleep(time.Second)

    ok := mu.TryLock() // 尝试获取到锁
    if ok { // 获取成功
        fmt.Println("got the lock")
        // do something
        mu.Unlock()
        return
    }

    // 没有获取到
    fmt.Println("can't get the lock")
}
```

# 获取等待者的数量等指标

接下来，我想和你聊聊怎么获取等待者数量等指标。

第二讲中，我们已经学习了Mutex的结构。先来回顾一下Mutex的数据结构，如下面的代码所示。它包含两个字段，state和sema。前四个字节（int32）就是state字段。

```
type Mutex struct {
    state int32
    sema  uint32
}
```

Mutex结构中的state字段有很多个含义，通过state字段，你可以知道锁是否已经被某个goroutine持有、当前是否处于饥饿状态、是否有等待的goroutine被唤醒、等待者的数量等信息。但是，state这个字段并没有暴露出来，所以，我们需要想办法获取到这个字段，并进行解析。

怎么获取未暴露的字段呢？很简单，我们可以通过unsafe的方式实现。我来举一个例子，你一看就明白了。

```
const (
    mutexLocked = 1 << iota // mutex is locked
    mutexWoken
    mutexStarving
    mutexWaiterShift = iota
)

type Mutex struct {
    sync.Mutex
}

func (m *Mutex) Count() int {
    // 获取state字段的值
    v := atomic.LoadInt32((*int32)(unsafe.Pointer(&m.Mutex)))
    v = v >> mutexWaiterShift + (v & mutexLocked)
    return int(v)
```

这个例子的第14行通过unsafe操作，我们可以得到state字段的值。第15行我们右移三位（这里的常量mutexWaiterShift的值为3），就得到了当前等待者的数量。如果当前的锁已经被其他goroutine持有，那么，我们就稍微调整一下这个值，加上一个1（第16行），你基本上可以把它看作是当前持有和等待这把锁的goroutine的总数。

state这个字段的第一位是用来标记锁是否被持有，第二位用来标记是否已经唤醒了一个等待者，第三位标记锁是否处于饥饿状态，通过分析这个state字段我们就可以得到这些状态信息。我们可以为这些状态提供查询的方法，这样就可以实时地知道锁的状态了。

```
// 锁是否被持有
func (m *Mutex) IsLocked() bool {
    state := atomic.LoadInt32((*int32)(unsafe.Pointer(&m.Mutex)))
    return state&mutexLocked == mutexLocked
}

// 是否有等待者被唤醒
func (m *Mutex) IsWoken() bool {
    state := atomic.LoadInt32((*int32)(unsafe.Pointer(&m.Mutex)))
    return state&mutexWoken == mutexWoken
}

// 锁是否处于饥饿状态
func (m *Mutex) IsStarving() bool {
    state := atomic.LoadInt32((*int32)(unsafe.Pointer(&m.Mutex)))
    return state&mutexStarving == mutexStarving
}
```

我们可以写一个程序测试一下，比如，在1000个goroutine并发访问的情况下，我们可以把锁的状态信息输出出来：

```
func count() {
    var mu Mutex
    for i := 0; i < 1000; i++ { // 启动1000个goroutine
        go func() {
            mu.Lock()
            time.Sleep(time.Second)
            mu.Unlock()
        }()
    }

    time.Sleep(time.Second)
    // 输出锁的信息
    fmt.Printf("waitings: %d, isLocked: %t, woken: %t,  starving: %t\n", mu.Count(), mu.IsLocked(), mu.IsWoken(), mu.IsStarving())
}
```

有一点你需要注意一下，在获取state字段的时候，并没有通过Lock获取这把锁，所以获取的这个state的值是一个瞬态的值，可能在你解析出这个字段之后，锁的状态已经发生了变化。不过没关系，因为你查看的就是调用的那一时刻的锁的状态。

# 使用Mutex实现一个线程安全的队列

最后，我们来讨论一下，如何使用Mutex实现一个线程安全的队列。

为什么要讨论这个话题呢？因为Mutex经常会和其他非线程安全（对于Go来说，我们其实指的是goroutine安全）的数据结构一起，组合成一个线程安全的数据结构。新数据结构的业务逻辑由原来的数据结构提供，而**Mutex提供了锁的机制，来保证线程安全**。

比如队列，我们可以通过Slice来实现，但是通过Slice实现的队列不是线程安全的，出队（Dequeue）和入队（Enqueue）会有data race的问题。这个时候，Mutex就要隆重出场了，通过它，我们可以在出队和入队的时候加上锁的保护。

```
type SliceQueue struct {
    data []interface{}
    mu   sync.Mutex
}

func NewSliceQueue(n int) (q *SliceQueue) {
    return &SliceQueue{data: make([]interface{}, 0, n)}
}

// Enqueue 把值放在队尾
func (q *SliceQueue) Enqueue(v interface{}) {
    q.mu.Lock()
    q.data = append(q.data, v)
    q.mu.Unlock()
}

// Dequeue 移去队头并返回
func (q *SliceQueue) Dequeue() interface{} {
    q.mu.Lock()
    if len(q.data) == 0 {
        q.mu.Unlock()
        return nil
    }
    v := q.data[0]
    q.data = q.data[1:]
    q.mu.Unlock()
    return v
}
```

因为标准库中没有线程安全的队列数据结构的实现，所以，你可以通过Mutex实现一个简单的队列。通过Mutex我们就可以为一个非线程安全的data interface{}实现线程安全的访问。

# 总结

好了，我们来做个总结。

Mutex是package sync的基石，其他的一些同步原语也是基于它实现的，所以，我们“隆重”地用了四讲来深度学习它。学到后面，你一定能感受到，多花些时间来完全掌握Mutex是值得的。

今天这一讲我和你分享了几个Mutex的拓展功能，这些方法是不是给你带来了一种“骇客”的编程体验呢，通过Hacker的方式，我们真的可以让Mutex变得更强大。

我们学习了基于Mutex实现TryLock，通过unsafe的方式读取到Mutex内部的state字段，这样，我们就解决了开篇列举的问题，一是不希望锁的goroutine继续等待，一是想监控锁。

另外，使用Mutex组合成更丰富的数据结构是我们常见的场景，今天我们就实现了一个线程安全的队列，未来我们还会讲到实现线程安全的map对象。

到这里，Mutex我们就系统学习完了，最后给你总结了一张Mutex知识地图，帮你复习一下。

![](https://static001.geekbang.org/resource/image/5a/0b/5ayy6cd9ec9fe0bcc13113302056ac0b.jpg?wh=2396%2A3131)

# 思考题

你可以为Mutex获取锁时加上Timeout机制吗？会有什么问题吗？

欢迎在留言区写下你的思考和答案，我们一起交流讨论。如果你觉得有所收获，也欢迎你把今天的内容分享给你的朋友或同事。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>+1day</span> 👍（24） 💬（7）<p>老师您好，在获取等待者数量的代码中
如果要加上锁持有者的数量的话，为什么不是 
v = v &gt;&gt; mutexWaiterShift + (v &amp; mutexLocked)
而是
v = v &gt;&gt; mutexWaiterShift &#47;&#47;得到等待者的数值
v = v + (v &amp; mutexLocked) &#47;&#47;再加上锁持有者的数量，0或者1
这样呢？第一步修改了 v 的值，v 的第一位已经不再是记录该锁是否被持有了，那 v&amp;mutexLocked 是不是不对呢？</p>2020-10-23</li><br/><li><span>Panmax</span> 👍（10） 💬（4）<p>如果底层 Mutex 的 state 在某个版本中含义变了，上边写的 TryLock 和监控锁的一些方法就会失效，所以这样做是不是比较危险。</p>2020-10-24</li><br/><li><span>不二</span> 👍（6） 💬（7）<p>请教一个基础问题，为啥 (*int32)(unsafe.Pointer(&amp;m.Mutex)) 可以获取sync.Mutex中state的值，Mutex结构中不是还有sema吗？</p>2020-10-20</li><br/><li><span>天空之城</span> 👍（2） 💬（1）<p>关于 RWLock 的扩展，我这边给出一段代码（评论不好贴代码，贴个 share link）
https:&#47;&#47;go.dev&#47;play&#47;p&#47;X4YNwqZR4ta

```go
package sync

import (
	&quot;sync&quot;
	&quot;sync&#47;atomic&quot;
	&quot;unsafe&quot;
)

type RWMutex struct {
	rw sync.RWMutex
}

const (
	mutexLocked = 1 &lt;&lt; iota
	mutexWake
	mutexStarving
	mutexWaiterShift = iota
)

const (
	rwmutexMaxReaders = 1 &lt;&lt; 30
)

func (e *RWMutex) TryLock() bool {
	if e.GetReader() &lt; 0 {
		return false
	}
	e.rw.Lock()
	return true
}

&#47;&#47; readerCount &gt; 0 =&gt; Reader Hold without Writer, &lt;0 =&gt; Reader Hold and Writer waiting, ==0 =&gt; no reader
&#47;&#47; state.mutexLocked == 1 =&gt; Writer Hold (in the meanwhile, readerWaiter==0, all reader(readerCount) are waiting)
func (e *RWMutex) IsLocked() bool {
	return e.IsWriterLocked() || e.IsReaderLocked()
}

func (e *RWMutex) IsWriterLocked() bool {
	state := atomic.LoadInt32((*int32)(unsafe.Pointer(&amp;e.rw)))
	return state&amp;mutexLocked == mutexLocked
}

func (e *RWMutex) IsReaderLocked() bool {
	return atomic.LoadInt32(e.readerCountPtr()) != 0
}

func (e *RWMutex) HasWriter() bool {
	return atomic.LoadInt32(e.readerCountPtr()) &lt; 0
}

func (e *RWMutex) GetWriter() int32 {
	state := atomic.LoadInt32((*int32)(unsafe.Pointer(&amp;e.rw)))
	return int32((state &gt;&gt; mutexWaiterShift) + (state &amp; mutexLocked))
}

func (e *RWMutex) HasReader() bool {
	return atomic.LoadInt32(e.readerCountPtr()) != 0
}

func (e *RWMutex) GetReader() int32 {
	r := atomic.LoadInt32(e.readerCountPtr())
	if r &lt; 0 {
		r += rwmutexMaxReaders
	}
	return r
}

func (e *RWMutex) readerCountPtr() *int32 {
	return (*int32)(unsafe.Pointer(uintptr(unsafe.Pointer(&amp;e.rw)) + unsafe.Sizeof(sync.Mutex{}) + unsafe.Sizeof(uint32(0))*2))
}

func (e *RWMutex) readerWaitPtr() *int32 {
	return (*int32)(unsafe.Pointer(uintptr(unsafe.Pointer(&amp;e.rw)) + unsafe.Sizeof(sync.Mutex{}) + unsafe.Sizeof(uint32(0))*2 + unsafe.Sizeof((int32(0)))))
}
```

</p>2023-05-12</li><br/><li><span>Gojustforfun</span> 👍（2） 💬（1）<p>1）『获取等待者的数量等指标』小节，『第 15 行我们左移三位（这里的常量 mutexWaiterShift 的值为 3）』应该是右移三位。
2）在now～now+timout内，间隔重试调用TryLock</p>2020-10-20</li><br/><li><span>CrazyCodes</span> 👍（1） 💬（1）<p>你可以为 Mutex 获取锁时加上 Timeout 机制吗？会有什么问题吗？

如果加上timeout机制，就不要用defer 去unlock，因为需要自行判断超时时间，然后直接unlock，如果defer再unlock就会触发panic</p>2023-11-27</li><br/><li><span>斯蒂芬.赵</span> 👍（1） 💬（3）<p>fast path执行失败，直接返回false不就行了，为啥还要往下执行？正常不是多个携程并发只有一个执行成功，其他都是失败么？</p>2021-05-07</li><br/><li><span>Calvin</span> 👍（0） 💬（1）<p>老师，TryLock 那里的以下这段代码，我对比了一下官方 1.18 以后的实现，貌似 mutexWoken 可以排除掉？
old := atomic.LoadInt32((*int32)(unsafe.Pointer(&amp;m.Mutex)))
if old&amp;(mutexLocked|mutexStarving|mutexWoken) != 0 {
	return false
}

官方的实现：
old := m.state
if old&amp;(mutexLocked|mutexStarving) != 0 {	&#47;&#47; 这里和本课程文章中的差别是少了 |mutexWoken
    return false
}

&#47;&#47; There may be a goroutine waiting for the mutex, but we are
&#47;&#47; running now and can try to grab the mutex before that
&#47;&#47; goroutine wakes up.
if !atomic.CompareAndSwapInt32(&amp;m.state, old, old|mutexLocked) {
	return false
}

if race.Enabled {
	race.Acquire(unsafe.Pointer(m))
}
return true</p>2024-05-20</li><br/><li><span>路过</span> 👍（0） 💬（1）<p>想问一下，为什么最后实现线程安全的队列里面的 Dequeue() 方法释放锁不用defer，这样不用写两次unlock</p>2023-04-17</li><br/><li><span>鲁迅原名周树人</span> 👍（0） 💬（2）<p>老师您好，

&#47;&#47; 如果能成功抢到锁 if atomic.CompareAndSwapInt32((*int32)(unsafe.Pointer(&amp;m.Mutex)), 0, mutexLocked) { return true }

在以上代码中，(*int32)(unsafe.Pointer(&amp;m.Mutex))是取的Mutex中state的首地址对嘛?
</p>2021-05-03</li><br/><li><span>黄毅</span> 👍（0） 💬（1）<p>func (m *Mutex) TryLock() bool {
	&#47;&#47; 如果能成功抢到锁
	if atomic.CompareAndSwapInt32((*int32)(unsafe.Pointer(&amp;m.Mutex)), 0, mutexLocked) {
		return true
	}

	&#47;&#47; 如果处于唤醒、加锁或者饥饿状态，这次请求就不参与竞争了，返回false
	old := atomic.LoadInt32((*int32)(unsafe.Pointer(&amp;m.Mutex)))
	fmt.Println(&quot;===old===:&quot;, old)
	if old&amp;(mutexLocked|mutexStarving|mutexWoken) != 0 {
		return false
	}

	&#47;&#47; 尝试在竞争的状态下请求锁
	new := old | mutexLocked
	fmt.Println(&quot;===new===:&quot;, new) &#47;&#47;请问在什么情况下会执行到这里
	return atomic.CompareAndSwapInt32((*int32)(unsafe.Pointer(&amp;m.Mutex)), old, new)
}

func main() {
	var mu Mutex
	go func() { &#47;&#47; 启动一个goroutine持有一段时间的锁
		mu.Lock()
		time.Sleep(time.Duration(rand.Intn(2)) * time.Second)
		mu.Unlock()
	}()

	time.Sleep(time.Second)

	n := int(10)
	var wg sync.WaitGroup
	wg.Add(n)

	for i := 0; i &lt; n; i++ {
		go func() {
			ok := mu.TryLock() &#47;&#47; 尝试获取到锁
			defer wg.Done()
			if ok { &#47;&#47; 获取成功
				fmt.Println(&quot;got the lock&quot;)
				&#47;&#47; do something
				mu.Unlock()
				return
			}
		}()
	}
	&#47;&#47; 没有获取到
	wg.Wait()
}

老师，你好。在main中尝试编写一段逻辑测试TryLock方法，请问在什么情况下会执行fmt.Println(&quot;===new===:&quot;, new) 请老师答疑解惑，谢谢。</p>2020-11-16</li><br/><li><span>樊少</span> 👍（0） 💬（1）<p>在安全Queue的实现中，锁的释放为什么不用defer?</p>2020-11-05</li><br/><li><span>Chen</span> 👍（0） 💬（1）<p>第 15 行我们右移三位（这里的常量 mutexWaiterShift 的值为 3），就得到了当前等待者的数量
=&gt;&gt; 这里看不懂，为什么右移三位=》得到等待者数量</p>2020-10-22</li><br/><li><span>linxs</span> 👍（0） 💬（3）<p>TryLock方法内，对于这段代码有点不理解，为什么要把&amp;m.Mutex转换成*int32，这里的话我直接用&amp;m.Mutex.state是否是一样的

if atomic.CompareAndSwapInt32((*int32)(unsafe.Pointer(&amp;m.Mutex)), 0, mutexLocked) { 
     return true 
}</p>2020-10-20</li><br/><li><span>Junes</span> 👍（34） 💬（2）<p>我来提供个思路~

最简单直接的是采用channel实现，用select监听锁和timeout两个channel，不在今天的讨论范围内。

1. 用for循环+TryLock实现：
先记录开始的时间，用for循环判断是否超时：没有超时则反复尝试tryLock，直到获取成功；如果超时直接返回失败。

问题：高频的CAS自旋操作，如果失败的太多，会消耗大量的CPU。

2. 优化1：TryLock的fast的拆分
TryLock的抢占实现分为两部分，一个是fast path，另一个是竞争状态下的，后者的cas操作很多。我会考虑减少slow方法的频率，比如调用n次fast path失败后，再调用一次整个Trylock。

3. 优化2：借鉴TCP重试机制
for循环中的重试增加休眠时间，每次失败将休眠时间乘以一个系数（如1.5），直到达到上限（如10ms），减少自旋带来的性能损耗</p>2020-10-19</li><br/>
</ul>