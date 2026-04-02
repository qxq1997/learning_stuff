你好，我是鸟窝。

在写Go程序之前，我曾经写了10多年的Java程序，也面试过不少Java程序员。在Java面试中，经常被问到的一个知识点就是等待/通知（wait/notify）机制。面试官经常会这样考察候选人：请实现一个限定容量的队列（queue），当队列满或者空的时候，利用等待/通知机制实现阻塞或者唤醒。

在Go中，也可以实现一个类似的限定容量的队列，而且实现起来也比较简单，只要用条件变量（Cond）并发原语就可以。Cond并发原语相对来说不是那么常用，但是在特定的场景使用会事半功倍，比如你需要在唤醒一个或者所有的等待者做一些检查操作的时候。

那么今天这一讲，我们就学习下Cond这个并发原语。

## Go标准库的Cond

Go标准库提供Cond原语的目的是，为等待/通知场景下的并发问题提供支持。Cond通常应用于等待某个条件的一组goroutine，等条件变为true的时候，其中一个goroutine或者所有的goroutine都会被唤醒执行。

顾名思义，Cond是和某个条件相关，这个条件需要一组goroutine协作共同完成，在条件还没有满足的时候，所有等待这个条件的goroutine都会被阻塞住，只有这一组goroutine通过协作达到了这个条件，等待的goroutine才可能继续进行下去。

那这里等待的条件是什么呢？等待的条件，可以是某个变量达到了某个阈值或者某个时间点，也可以是一组变量分别都达到了某个阈值，还可以是某个对象的状态满足了特定的条件。总结来讲，等待的条件是一种可以用来计算结果是true还是false的条件。

从开发实践上，我们真正使用Cond的场景比较少，因为一旦遇到需要使用Cond的场景，我们更多地会使用Channel的方式（我会在第12和第13讲展开Channel的用法）去实现，因为那才是更地道的Go语言的写法，甚至Go的开发者有个“把Cond从标准库移除”的提议（[issue 21165](https://github.com/golang/go/issues/21165)）。而有的开发者认为，Cond是唯一难以掌握的Go并发原语。至于其中原因，我先卖个关子，到这一讲的后半部分我再和你解释。

今天，这一讲我们就带你仔细地学一学Cond这个并发原语吧。

## Cond的基本用法

标准库中的Cond并发原语初始化的时候，需要关联一个Locker接口的实例，一般我们使用Mutex或者RWMutex。

我们看一下Cond的实现：

```
type Cond
  func NeWCond(l Locker) *Cond
  func (c *Cond) Broadcast()
  func (c *Cond) Signal()
  func (c *Cond) Wait()
```

首先，Cond关联的Locker实例可以通过c.L访问，它内部维护着一个先入先出的等待队列。

然后，我们分别看下它的三个方法Broadcast、Signal和Wait方法。

**Signal方法**，允许调用者Caller唤醒一个等待此Cond的goroutine。如果此时没有等待的goroutine，显然无需通知waiter；如果Cond等待队列中有一个或者多个等待的goroutine，则需要从等待队列中移除第一个goroutine并把它唤醒。在其他编程语言中，比如Java语言中，Signal方法也被叫做notify方法。

调用Signal方法时，不强求你一定要持有c.L的锁。

**Broadcast方法**，允许调用者Caller唤醒所有等待此Cond的goroutine。如果此时没有等待的goroutine，显然无需通知waiter；如果Cond等待队列中有一个或者多个等待的goroutine，则清空所有等待的goroutine，并全部唤醒。在其他编程语言中，比如Java语言中，Broadcast方法也被叫做notifyAll方法。

同样地，调用Broadcast方法时，也不强求你一定持有c.L的锁。

**Wait方法**，会把调用者Caller放入Cond的等待队列中并阻塞，直到被Signal或者Broadcast的方法从等待队列中移除并唤醒。

调用Wait方法时必须要持有c.L的锁。

Go实现的sync.Cond的方法名是Wait、Signal和Broadcast，这是计算机科学中条件变量的[通用方法名](https://en.wikipedia.org/wiki/Monitor_%28synchronization%29#Condition_variables_2)。比如，C语言中对应的方法名是pthread\_cond\_wait、pthread\_cond\_signal和 pthread\_cond\_broadcast。

知道了Cond提供的三个方法后，我们再通过一个百米赛跑开始时的例子，来学习下**Cond的使用方法**。10个运动员进入赛场之后需要先做拉伸活动活动筋骨，向观众和粉丝招手致敬，在自己的赛道上做好准备；等所有的运动员都准备好之后，裁判员才会打响发令枪。

每个运动员做好准备之后，将ready加一，表明自己做好准备了，同时调用Broadcast方法通知裁判员。因为裁判员只有一个，所以这里可以直接替换成Signal方法调用。调用Broadcast方法的时候，我们并没有请求c.L锁，只是在更改等待变量的时候才使用到了锁。

裁判员会等待运动员都准备好（第22行）。虽然每个运动员准备好之后都唤醒了裁判员，但是裁判员被唤醒之后需要检查等待条件是否满足（**运动员都准备好了**）。可以看到，裁判员被唤醒之后一定要检查等待条件，如果条件不满足还是要继续等待。

```
func main() {
    c := sync.NewCond(&sync.Mutex{})
    var ready int

    for i := 0; i < 10; i++ {
        go func(i int) {
            time.Sleep(time.Duration(rand.Int63n(10)) * time.Second)

            // 加锁更改等待条件
            c.L.Lock()
            ready++
            c.L.Unlock()

            log.Printf("运动员#%d 已准备就绪\n", i)
            // 广播唤醒所有的等待者
            c.Broadcast()
        }(i)
    }

    c.L.Lock()
    for ready != 10 {
        c.Wait()
        log.Println("裁判员被唤醒一次")
    }
    c.L.Unlock()

    //所有的运动员是否就绪
    log.Println("所有运动员都准备就绪。比赛开始，3，2，1, ......")
}
```

你看，Cond的使用其实没那么简单。它的复杂在于：一，这段代码有时候需要加锁，有时候可以不加；二，Wait唤醒后需要检查条件；三，条件变量的更改，其实是需要原子操作或者互斥锁保护的。所以，有的开发者会认为，Cond是唯一难以掌握的Go并发原语。

我们继续看看Cond的实现原理。

## Cond的实现原理

其实，Cond的实现非常简单，或者说复杂的逻辑已经被Locker或者runtime的等待队列实现了。我们直接看看Cond的源码吧。

```
type Cond struct {
    noCopy noCopy

    // 当观察或者修改等待条件的时候需要加锁
    L Locker

    // 等待队列
    notify  notifyList
    checker copyChecker
}

func NewCond(l Locker) *Cond {
    return &Cond{L: l}
}

func (c *Cond) Wait() {
    c.checker.check()
    // 增加到等待队列中
    t := runtime_notifyListAdd(&c.notify)
    c.L.Unlock()
    // 阻塞休眠直到被唤醒
    runtime_notifyListWait(&c.notify, t)
    c.L.Lock()
}

func (c *Cond) Signal() {
    c.checker.check()
    runtime_notifyListNotifyOne(&c.notify)
}

func (c *Cond) Broadcast() {
    c.checker.check()
    runtime_notifyListNotifyAll(&c.notify）
}
```

这部分源码确实很简单，我来带你学习下其中比较关键的逻辑。

runtime\_notifyListXXX是运行时实现的方法，实现了一个等待/通知的队列。如果你想深入学习这部分，可以再去看看runtime/sema.go代码中。

copyChecker是一个辅助结构，可以在运行时检查Cond是否被复制使用。

Signal和Broadcast只涉及到notifyList数据结构，不涉及到锁。

Wait把调用者加入到等待队列时会释放锁，在被唤醒之后还会请求锁。在阻塞休眠期间，调用者是不持有锁的，这样能让其他goroutine有机会检查或者更新等待变量。

我们继续看看使用Cond常见的两个错误，一个是调用Wait的时候没有加锁，另一个是没有检查条件是否满足程序就继续执行了。

## 使用Cond的2个常见错误

我们先看**Cond最常见的使用错误，也就是调用Wait的时候没有加锁**。

以前面百米赛跑的程序为例，在调用cond.Wait时，把前后的Lock/Unlock注释掉，如下面的代码中的第20行和第25行：

```
func main() {
    c := sync.NewCond(&sync.Mutex{})
    var ready int

    for i := 0; i < 10; i++ {
        go func(i int) {
            time.Sleep(time.Duration(rand.Int63n(10)) * time.Second)

            // 加锁更改等待条件
            c.L.Lock()
            ready++
            c.L.Unlock()

            log.Printf("运动员#%d 已准备就绪\n", i)
            // 广播唤醒所有的等待者
            c.Broadcast()
        }(i)
    }

    // c.L.Lock()
    for ready != 10 {
        c.Wait()
        log.Println("裁判员被唤醒一次")
    }
    // c.L.Unlock()

    //所有的运动员是否就绪
    log.Println("所有运动员都准备就绪。比赛开始，3，2，1, ......")
}
```

再运行程序，就会报释放未加锁的panic：

![](https://static001.geekbang.org/resource/image/47/76/4780dca40087277be0d183674bc42c76.jpeg?wh=877%2A367)

出现这个问题的原因在于，cond.Wait方法的实现是，把当前调用者加入到notify队列之中后会释放锁（如果不释放锁，其他Wait的调用者就没有机会加入到notify队列中了），然后一直等待；等调用者被唤醒之后，又会去争抢这把锁。如果调用Wait之前不加锁的话，就有可能Unlock一个未加锁的Locker。所以切记，**调用cond.Wait方法之前一定要加锁**。

使用Cond的另一个常见错误是，只调用了一次Wait，没有检查等待条件是否满足，结果条件没满足，程序就继续执行了。出现这个问题的原因在于，误以为Cond的使用，就像WaitGroup那样调用一下Wait方法等待那么简单。比如下面的代码中，把第21行和第24行注释掉：

```
func main() {
    c := sync.NewCond(&sync.Mutex{})
    var ready int

    for i := 0; i < 10; i++ {
        go func(i int) {
            time.Sleep(time.Duration(rand.Int63n(10)) * time.Second)

            // 加锁更改等待条件
            c.L.Lock()
            ready++
            c.L.Unlock()

            log.Printf("运动员#%d 已准备就绪\n", i)
            // 广播唤醒所有的等待者
            c.Broadcast()
        }(i)
    }

    c.L.Lock()
    // for ready != 10 {
    c.Wait()
    log.Println("裁判员被唤醒一次")
    // }
    c.L.Unlock()

    //所有的运动员是否就绪
    log.Println("所有运动员都准备就绪。比赛开始，3，2，1, ......")
}
```

运行这个程序，你会发现，可能只有几个运动员准备好之后程序就运行完了，而不是我们期望的所有运动员都准备好才进行下一步。原因在于，每一个运动员准备好之后都会唤醒所有的等待者，也就是这里的裁判员，比如第一个运动员准备好后就唤醒了裁判员，结果这个裁判员傻傻地没做任何检查，以为所有的运动员都准备好了，就继续执行了。

所以，我们一定要**记住**，waiter goroutine被唤醒**不等于**等待条件被满足，只是有goroutine把它唤醒了而已，等待条件有可能已经满足了，也有可能不满足，我们需要进一步检查。你也可以理解为，等待者被唤醒，只是得到了一次检查的机会而已。

到这里，我们小结下。如果你想在使用Cond的时候避免犯错，只要时刻记住调用cond.Wait方法之前一定要加锁，以及waiter goroutine被唤醒不等于等待条件被满足这两个知识点。

## 知名项目中Cond的使用

Cond在实际项目中被使用的机会比较少，原因总结起来有两个。

第一，同样的场景我们会使用其他的并发原语来替代。Go特有的Channel类型，有一个应用很广泛的模式就是通知机制，这个模式使用起来也特别简单。所以很多情况下，我们会使用Channel而不是Cond实现wait/notify机制。

第二，对于简单的wait/notify场景，比如等待一组goroutine完成之后继续执行余下的代码，我们会使用WaitGroup来实现。因为WaitGroup的使用方法更简单，而且不容易出错。比如，上面百米赛跑的问题，就可以很方便地使用WaitGroup来实现。

所以，我在这一讲开头提到，Cond的使用场景很少。先前的标准库内部有几个地方使用了Cond，比如io/pipe.go等，后来都被其他的并发原语（比如Channel）替换了，sync.Cond的路越走越窄。但是，还是有一批忠实的“粉丝”坚持在使用Cond，原因在于Cond有三点特性是Channel无法替代的：

- Cond和一个Locker关联，可以利用这个Locker对相关的依赖条件更改提供保护。
- Cond可以同时支持Signal和Broadcast方法，而Channel只能同时支持其中一种。
- Cond的Broadcast方法可以被重复调用。等待条件再次变成不满足的状态后，我们又可以调用Broadcast再次唤醒等待的goroutine。这也是Channel不能支持的，Channel被close掉了之后不支持再open。

开源项目中使用sync.Cond的代码少之又少，包括标准库原先一些使用Cond的代码也改成使用Channel实现了，所以别说找Cond相关的使用Bug了，想找到的一个使用的例子都不容易，我找了Kubernetes中的一个例子，我们一起看看它是如何使用Cond的。

Kubernetes项目中定义了优先级队列 [PriorityQueue](https://github.com/kubernetes/kubernetes/blob/master/pkg/scheduler/internal/queue/scheduling_queue.go) 这样一个数据结构，用来实现Pod的调用。它内部有三个Pod的队列，即activeQ、podBackoffQ和unschedulableQ，其中activeQ就是用来调度的活跃队列（heap）。

Pop方法调用的时候，如果这个队列为空，并且这个队列没有Close的话，会调用Cond的Wait方法等待。

你可以看到，调用Wait方法的时候，调用者是持有锁的，并且被唤醒的时候检查等待条件（队列是否为空）。

```
// 从队列中取出一个元素
func (p *PriorityQueue) Pop() (*framework.QueuedPodInfo, error) {
		p.lock.Lock()
		defer p.lock.Unlock()
		for p.activeQ.Len() == 0 { // 如果队列为空
			if p.closed {
				return nil, fmt.Errorf(queueClosed)
			}
			p.cond.Wait() // 等待，直到被唤醒
		}
		......
		return pInfo, err
	}

```

当activeQ增加新的元素时，会调用条件变量的Boradcast方法，通知被Pop阻塞的调用者。

```
// 增加元素到队列中
func (p *PriorityQueue) Add(pod *v1.Pod) error {
		p.lock.Lock()
		defer p.lock.Unlock()
		pInfo := p.newQueuedPodInfo(pod)
		if err := p.activeQ.Add(pInfo); err != nil {//增加元素到队列中
			klog.Errorf("Error adding pod %v to the scheduling queue: %v", nsNameForPod(pod), err)
			return err
		}
		......
		p.cond.Broadcast() //通知其它等待的goroutine，队列中有元素了

		return nil
	}
```

这个优先级队列被关闭的时候，也会调用Broadcast方法，避免被Pop阻塞的调用者永远hang住。

```
func (p *PriorityQueue) Close() {
		p.lock.Lock()
		defer p.lock.Unlock()
		close(p.stop)
		p.closed = true
		p.cond.Broadcast() //关闭时通知等待的goroutine，避免它们永远等待
}
```

你可以思考一下，这里为什么使用Cond这个并发原语，能不能换成Channel实现呢？

## 总结

好了，我们来做个总结。

Cond是为等待/通知场景下的并发问题提供支持的。它提供了条件变量的三个基本方法Signal、Broadcast和Wait，为并发的goroutine提供等待/通知机制。

在实践中，处理等待/通知的场景时，我们常常会使用Channel替换Cond，因为Channel类型使用起来更简洁，而且不容易出错。但是对于需要重复调用Broadcast的场景，比如上面Kubernetes的例子，每次往队列中成功增加了元素后就需要调用Broadcast通知所有的等待者，使用Cond就再合适不过了。

使用Cond之所以容易出错，就是Wait调用需要加锁，以及被唤醒后一定要检查条件是否真的已经满足。你需要牢记这两点。

虽然我们讲到的百米赛跑的例子，也可以通过WaitGroup来实现，但是本质上WaitGroup和Cond是有区别的：WaitGroup是主goroutine等待确定数量的子goroutine完成任务；而Cond是等待某个条件满足，这个条件的修改可以被任意多的goroutine更新，而且Cond的Wait不关心也不知道其他goroutine的数量，只关心等待条件。而且Cond还有单个通知的机制，也就是Signal方法。

![](https://static001.geekbang.org/resource/image/47/5d/477157d2dbe1b7e4511f56c2c9c2105d.jpg?wh=2251%2A1332)

## 思考题

1. 一个Cond的waiter被唤醒的时候，为什么需要再检查等待条件，而不是唤醒后进行下一步？
2. 你能否利用Cond实现一个容量有限的queue？

欢迎在留言区写下你的思考和答案，我们一起交流讨论。如果你觉得有所收获，也欢迎你把今天的内容分享给你的朋友或同事。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>那时刻</span> 👍（13） 💬（1）<p>老师，上节课你提到noCopy，是一个辅助的、用来帮助 vet 检查用的类型，而Cond还有个copyChecker 是一个辅助结构，可以在运行时检查 Cond 是否被复制使用。

nocpoy是静态检查，copyChecker是运行时检查，不是理解是否正确？

另外不是是否有其他区别呢？</p>2020-10-26</li><br/><li><span>myrfy</span> 👍（4） 💬（1）<p>还是没有想明白k8s为什么不能用channel通知
close可以实现broadcast的功效，在pop的时候，也是只有一个goroutine可以拿到数据，感觉除了关闭队列之外，不存在需要broadcast的情况。也就是感觉不需要多次broadcast，这样channel应该是满足要求的……请老师明示</p>2020-10-28</li><br/><li><span>chongsheng</span> 👍（2） 💬（1）<p>关于Cond还有一种会不小心误用的场景，因为一些原因导致Wait执行的时候，Signal&#47;Broadcast就已经执行完了，导致Wait一直等待无法唤醒。比如这里的例子
https:&#47;&#47;stackoverflow.com&#47;questions&#47;36857167&#47;how-to-correctly-use-sync-cond</p>2022-01-06</li><br/><li><span>moooofly</span> 👍（1） 💬（2）<p>请教一个问题，nocpoy 是用于 vet 静态检查，copyChecker 是为了运行时检查，都是为了检查 copy 问题，为啥 Cond 要在两处检查，而 Mutex 只需要一处？</p>2020-10-27</li><br/><li><span>hhhccp</span> 👍（0） 💬（1）<p>不知道现在发还会不会被看到😂，浇给作业
package main

import (
	&quot;fmt&quot;
	&quot;sync&quot;
	&quot;sync&#47;atomic&quot;
)

type TaskQueue struct {
	q        []interface{}
	capacity int
	size     int32
	front    int
	rear     int
	popLock  sync.Mutex
	pushLock sync.Mutex
	pushCon  *sync.Cond
	popCon   *sync.Cond
}

func NewTaskQueue(capacity int) *TaskQueue {
	tq := &amp;TaskQueue{
		q: make([]interface{}, capacity),
		capacity: capacity,
		front: 0,
		rear: 0,
		size: 0,
	}
	tq.pushCon = sync.NewCond(&amp;tq.pushLock)
	tq.popCon = sync.NewCond(&amp;tq.popLock)
	return tq
} 

func (tq *TaskQueue) Size() int {
	return int(atomic.LoadInt32(&amp;tq.size))
}

func (tq *TaskQueue) PushTask(v interface{}) {
	tq.pushLock.Lock()
	defer tq.pushLock.Unlock()
	for tq.Size() == tq.capacity {
		tq.pushCon.Wait()
	}

	tq.q[tq.rear] = v
	tq.rear = (tq.rear + 1) % tq.capacity
	atomic.AddInt32(&amp;tq.size, 1)
	tq.popCon.Signal()
}

func (tq *TaskQueue) PopTask() interface{} {
	tq.popLock.Lock()
	defer tq.popLock.Unlock()
	for tq.Size() == 0 {
		tq.popCon.Wait()
	}

	v := tq.q[tq.front]
	tq.front = (tq.front + 1) % tq.capacity
	atomic.AddInt32(&amp;tq.size, -1)
	tq.pushCon.Signal()
	return v
}</p>2024-12-01</li><br/><li><span>叶君度</span> 👍（0） 💬（1）<p>对比waitGroup。cond 实质是将waitGroup 的 计数能力 暴露给开发者，让开发自定义”计数”，waitGroup的计数state是atomic的原子操作，cond 通过 mutex来保证原子操作。所以在 更新 和 判断时，需要加锁检查。</p>2024-04-16</li><br/><li><span>Krean</span> 👍（0） 💬（1）<p>不知道现在发还会不会被看到😂，浇给作业
type queue struct {
	vals []int
	cap int
	cond *sync.Cond
}

func (q *queue) enQueue(v int) {
	if q.cap == len(q.vals) {
		q.cond.L.Lock()
		q.cond.Wait()
		q.cond.L.Unlock()
	}
	q.vals = append(q.vals, v)
	q.cond.Signal()
}

func (q *queue) deQueue() int {
	if len(q.vals) == 0 {
		q.cond.L.Lock()
		q.cond.Wait()
		q.cond.L.Unlock()
	}
	ret := q.vals[0]
	q.vals = q.vals[1:]
	q.cond.Signal()
	return ret
}</p>2024-03-22</li><br/><li><span>kyo</span> 👍（0） 💬（2）<p>
func main() {
    c := sync.NewCond(&amp;sync.Mutex{})
    var ready int

    for i := 0; i &lt; 10; i++ {
        go func(i int) {
            time.Sleep(time.Duration(rand.Int63n(10)) * time.Second)

            &#47;&#47; 加锁更改等待条件
            c.L.Lock()
            ready++
            c.L.Unlock()

            log.Printf(&quot;运动员#%d 已准备就绪\n&quot;, i)
            &#47;&#47; 广播唤醒所有的等待者
            c.Broadcast()
        }(i)
    }

    c.L.Lock()
    for ready != 10 {
        c.Wait()
        log.Println(&quot;裁判员被唤醒一次&quot;)
    }
    c.L.Unlock()

    &#47;&#47;所有的运动员是否就绪
    log.Println(&quot;所有运动员都准备就绪。比赛开始，3，2，1, ......&quot;)
}

这个例子有问题吧.  这里的 ready 变量共享了变量 c 的锁.  会导致在 c.Wait() 语句执行前 for 中的   goroutine 全部堵塞. 在 c.Wait() 前加句 time.Sleep(time.Second * 10) 试试就知道了. 是不是应该给 ready 变量单独定义一个 Mutex?</p>2022-12-04</li><br/><li><span>Geek_b45293</span> 👍（0） 💬（1）<p>有个问题，为什么 Mutex 不使用 copyChecker 来检测是否被复制呢？</p>2022-09-26</li><br/><li><span>授人以🐟，不如授人以渔</span> 👍（0） 💬（1）<p>文章中在描述 Cond 的复杂性时，说明了 3 点，第三点：「条件变量的更改」 是否可需改为：「等待条件的更改」？</p>2021-11-03</li><br/><li><span>bearlu</span> 👍（0） 💬（1）<p>老师请教一个问题，如果Wait前加锁，然后执行完Wait又Unlock有什么作用，我把Wait后面的Unlock去掉，好似程序也能正常运行。是我漏了什么？</p>2021-07-24</li><br/><li><span>网管</span> 👍（0） 💬（1）<p>老师，Kubernetes  PriorityQueue的那个Pop方法里没有使用p.cond.L.Lock()方法，他们是怎么防止不出现释放未加锁的panic啊。</p>2020-11-01</li><br/><li><span>S.S Mr Lin</span> 👍（0） 💬（2）<p>每次调用wait前都要加锁，为啥加锁语句放在了fo的外面？第二次wait是不是就没有加锁了？</p>2020-10-28</li><br/><li><span>syuan</span> 👍（0） 💬（1）<p>Wait 方法，会把调用者 Caller 放入 Cond 的等待队列中并阻塞，直到被 Signal 或者 Broadcast 的方法从等待队列中移除并唤醒。
百米跑代码第22行:    c.Wait(),把调用者加入队列阻塞，不理解? for循环一直检查，是把c一直加入阻塞队列吗？还是waiter方法自已生成t对象加入阻塞队列？如果是，同一个c对应t( t := runtime_notifyListAdd(&amp;c.notify)对象唯一吗？</p>2020-10-26</li><br/><li><span>儿戏</span> 👍（0） 💬（1）<p>老师，请教个课程外的问题，使用httputil.ReverseProxy 做方向代理，压测的时候大量报出 http: proxy error: context canceled 这个错误。linux 打开文件数调整了，time_waite也都优化过了，一直没有找到问题，您的博客也看了还是不能定位，求赐教</p>2020-10-26</li><br/>
</ul>