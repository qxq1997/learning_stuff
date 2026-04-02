你好，我是景霄。

众所周知，我们当代的计算机都是图灵机架构。图灵机架构的本质，就是一条无限长的纸带，对应着我们今天的存储器。在工程学的演化中，逐渐出现了寄存器、易失性存储器（内存）和永久性存储器（硬盘）等产品。其实，这本身来自一个矛盾：速度越快的存储器，单位价格也越昂贵。因此，妥善利用好每一寸高速存储器的空间，永远是系统设计的一个核心。

回到 Python 应用层。

我们知道，Python 程序在运行的时候，需要在内存中开辟出一块空间，用于存放运行时产生的临时变量；计算完成后，再将结果输出到永久性存储器中。如果数据量过大，内存空间管理不善就很容易出现 OOM（out of memory），俗称爆内存，程序可能被操作系统中止。

而对于服务器，这种设计为永不中断的系统来说，内存管理则显得更为重要，不然很容易引发内存泄漏。什么是内存泄漏呢？

- 这里的泄漏，并不是说你的内存出现了信息安全问题，被恶意程序利用了，而是指程序本身没有设计好，导致程序未能释放已不再使用的内存。
- 内存泄漏也不是指你的内存在物理上消失了，而是意味着代码在分配了某段内存后，因为设计错误，失去了对这段内存的控制，从而造成了内存的浪费。

那么，Python 又是怎么解决这些问题的？换句话说，对于不会再用到的内存空间，Python 是通过什么机制来回收这些空间的呢？

## 计数引用

我们反复提过好几次， Python 中一切皆对象。因此，你所看到的一切变量，本质上都是对象的一个指针。

那么，怎么知道一个对象，是否永远都不能被调用了呢？

我们上节课提到过的，也是非常直观的一个想法，就是当这个对象的引用计数（指针数）为 0 的时候，说明这个对象永不可达，自然它也就成为了垃圾，需要被回收。

我们来看一个例子：

```
import os
import psutil

# 显示当前 python 程序占用的内存大小
def show_memory_info(hint):
    pid = os.getpid()
    p = psutil.Process(pid)
    
    info = p.memory_full_info()
    memory = info.uss / 1024. / 1024
    print('{} memory used: {} MB'.format(hint, memory))
```

```
def func():
    show_memory_info('initial')
    a = [i for i in range(10000000)]
    show_memory_info('after a created')

func()
show_memory_info('finished')

########## 输出 ##########

initial memory used: 47.19140625 MB
after a created memory used: 433.91015625 MB
finished memory used: 48.109375 MB
```

通过这个示例，你可以看到，调用函数 func()，在列表 a 被创建之后，内存占用迅速增加到了 433 MB：而在函数调用结束后，内存则返回正常。

这是因为，函数内部声明的列表 a 是局部变量，在函数返回后，局部变量的引用会注销掉；此时，列表 a 所指代对象的引用数为 0，Python 便会执行垃圾回收，因此之前占用的大量内存就又回来了。

明白了这个原理后，我们稍微修改一下代码：

```
def func():
    show_memory_info('initial')
    global a
    a = [i for i in range(10000000)]
    show_memory_info('after a created')

func()
show_memory_info('finished')

########## 输出 ##########

initial memory used: 48.88671875 MB
after a created memory used: 433.94921875 MB
finished memory used: 433.94921875 MB
```

新的这段代码中，global a 表示将 a 声明为全局变量。那么，即使函数返回后，列表的引用依然存在，于是对象就不会被垃圾回收掉，依然占用大量内存。

同样，如果我们把生成的列表返回，然后在主程序中接收，那么引用依然存在，垃圾回收就不会被触发，大量内存仍然被占用着：

```
def func():
    show_memory_info('initial')
    a = [i for i in derange(10000000)]
    show_memory_info('after a created')
    return a

a = func()
show_memory_info('finished')

########## 输出 ##########

initial memory used: 47.96484375 MB
after a created memory used: 434.515625 MB
finished memory used: 434.515625 MB
```

这是最常见的几种情况。由表及里，下面，我们深入看一下 Python 内部的引用计数机制。老规矩，先来看代码：

```
import sys

a = []

# 两次引用，一次来自 a，一次来自 getrefcount
print(sys.getrefcount(a))

def func(a):
    # 四次引用，a，python 的函数调用栈，函数参数，和 getrefcount
    print(sys.getrefcount(a))

func(a)

# 两次引用，一次来自 a，一次来自 getrefcount，函数 func 调用已经不存在
print(sys.getrefcount(a))

########## 输出 ##########

2
4
2
```

简单介绍一下，sys.getrefcount() 这个函数，可以查看一个变量的引用次数。这段代码本身应该很好理解，不过别忘了，**getrefcount 本身也会引入一次计数**。

另一个要注意的是，在函数调用发生的时候，会产生额外的两次引用，一次来自函数栈，另一个是函数参数。

```
import sys

a = []

print(sys.getrefcount(a)) # 两次

b = a

print(sys.getrefcount(a)) # 三次

c = b
d = b
e = c
f = e
g = d

print(sys.getrefcount(a)) # 八次

########## 输出 ##########

2
3
8
```

看到这段代码，需要你稍微注意一下，a、b、c、d、e、f、g 这些变量全部指代的是同一个对象，而sys.getrefcount() 函数并不是统计一个指针，而是要统计一个对象被引用的次数，所以最后一共会有八次引用。

理解引用这个概念后，引用释放是一种非常自然和清晰的思想。相比 C 语言里，你需要使用 free 去手动释放内存，Python 的垃圾回收在这里可以说是省心省力了。

不过，我想还是会有人问，如果我偏偏想手动释放内存，应该怎么做呢？

方法同样很简单。你只需要先调用 del a 来删除对象的引用；然后强制调用 gc.collect()，清除没有引用的对象，即可手动启动垃圾回收。

```
import gc

show_memory_info('initial')

a = [i for i in range(10000000)]

show_memory_info('after a created')

del a
gc.collect()

show_memory_info('finish')
print(a)

########## 输出 ##########

initial memory used: 48.1015625 MB
after a created memory used: 434.3828125 MB
finish memory used: 48.33203125 MB

---------------------------------------------------------------------------
NameError                                 Traceback (most recent call last)
<ipython-input-12-153e15063d8a> in <module>
     11 
     12 show_memory_info('finish')
---> 13 print(a)

NameError: name 'a' is not defined
```

到这里，是不是觉得垃圾回收非常简单呀？

我想，肯定有人觉得自己都懂了，那么，如果此时有面试官问：引用次数为 0 是垃圾回收启动的充要条件吗？还有没有其他可能性呢？

这个问题，你能回答的上来吗？

## 循环引用

如果你也被困住了，别急。我们不妨小步设问，先来思考这么一个问题：如果有两个对象，它们互相引用，并且不再被别的对象所引用，那么它们应该被垃圾回收吗？

请仔细观察下面这段代码：

```
def func():
    show_memory_info('initial')
    a = [i for i in range(10000000)]
    b = [i for i in range(10000000)]
    show_memory_info('after a, b created')
    a.append(b)
    b.append(a)

func()
show_memory_info('finished')

########## 输出 ##########

initial memory used: 47.984375 MB
after a, b created memory used: 822.73828125 MB
finished memory used: 821.73046875 MB
```

这里，a 和 b 互相引用，并且，作为局部变量，在函数 func 调用结束后，a 和 b 这两个指针从程序意义上已经不存在了。但是，很明显，依然有内存占用！为什么呢？因为互相引用，导致它们的引用数都不为 0。

试想一下，如果这段代码出现在生产环境中，哪怕 a 和 b 一开始占用的空间不是很大，但经过长时间运行后，Python 所占用的内存一定会变得越来越大，最终撑爆服务器，后果不堪设想。

当然，有人可能会说，互相引用还是很容易被发现的呀，问题不大。可是，更隐蔽的情况是出现一个引用环，在工程代码比较复杂的情况下，引用环还真不一定能被轻易发现。

那么，我们应该怎么做呢？

事实上，Python 本身能够处理这种情况，我们刚刚讲过的，可以显式调用 gc.collect() ，来启动垃圾回收。

```
import gc

def func():
    show_memory_info('initial')
    a = [i for i in range(10000000)]
    b = [i for i in range(10000000)]
    show_memory_info('after a, b created')
    a.append(b)
    b.append(a)

func()
gc.collect()
show_memory_info('finished')

########## 输出 ##########

initial memory used: 49.51171875 MB
after a, b created memory used: 824.1328125 MB
finished memory used: 49.98046875 MB
```

所以你看，Python 的垃圾回收机制并没有那么弱。

Python 使用标记清除（mark-sweep）算法和分代收集（generational），来启用针对循环引用的自动垃圾回收。你可能不太熟悉这两个词，这里我简单介绍一下。

先来看标记清除算法。我们先用图论来理解不可达的概念。对于一个有向图，如果从一个节点出发进行遍历，并标记其经过的所有节点；那么，在遍历结束后，所有没有被标记的节点，我们就称之为不可达节点。显而易见，这些节点的存在是没有任何意义的，自然的，我们就需要对它们进行垃圾回收。

当然，每次都遍历全图，对于 Python 而言是一种巨大的性能浪费。所以，在 Python 的垃圾回收实现中，mark-sweep 使用双向链表维护了一个数据结构，并且只考虑容器类的对象（只有容器类对象才有可能产生循环引用）。具体算法这里我就不再多讲了，毕竟我们的重点是关注应用。

而分代收集算法，则是另一个优化手段。

Python 将所有对象分为三代。刚刚创立的对象是第 0 代；经过一次垃圾回收后，依然存在的对象，便会依次从上一代挪到下一代。而每一代启动自动垃圾回收的阈值，则是可以单独指定的。当垃圾回收器中新增对象减去删除对象达到相应的阈值时，就会对这一代对象启动垃圾回收。

事实上，分代收集基于的思想是，新生的对象更有可能被垃圾回收，而存活更久的对象也有更高的概率继续存活。因此，通过这种做法，可以节约不少计算量，从而提高 Python 的性能。

学了这么多，刚刚面试官的问题，你应该能回答得上来了吧！没错，引用计数是其中最简单的实现，不过切记，引用计数并非充要条件，它只能算作充分非必要条件；至于其他的可能性，我们所讲的循环引用正是其中一种。

## 调试内存泄漏

不过，虽然有了自动回收机制，但这也不是万能的，难免还是会有漏网之鱼。内存泄漏是我们不想见到的，而且还会严重影响性能。有没有什么好的调试手段呢？

答案当然是肯定的，接下来我就为你介绍一个“得力助手”。

它就是objgraph，一个非常好用的可视化引用关系的包。在这个包中，我主要推荐两个函数，第一个是show\_refs()，它可以生成清晰的引用关系图。

通过下面这段代码和生成的引用调用图，你能非常直观地发现，有两个 list 互相引用，说明这里极有可能引起内存泄露。这样一来，再去代码层排查就容易多了。

```
import objgraph

a = [1, 2, 3]
b = [4, 5, 6]

a.append(b)
b.append(a)

objgraph.show_refs([a])
```

![](https://static001.geekbang.org/resource/image/fc/ae/fc3b0355ecfdbac5a7b48aa014208aae.png?wh=1039%2A547)

而另一个非常有用的函数，是 show\_backrefs()。下面同样为示例代码和生成图，你可以自己先阅读一下：

```
import objgraph

a = [1, 2, 3]
b = [4, 5, 6]

a.append(b)
b.append(a)

objgraph.show_backrefs([a])
```

![](https://static001.geekbang.org/resource/image/92/27/9228289bac4976cfa9b11e08c05a7a27.png?wh=2011%2A1277)

相比刚才的引用调用图，这张图显得稍微复杂一些。不过，我仍旧推荐你掌握它，因为这个 API 有很多有用的参数，比如层数限制（max\_depth）、宽度限制（too\_many）、输出格式控制（filename output）、节点过滤（filter, extra\_ignore）等。所以，建议你使用之前，先认真看一下[文档](https://mg.pov.lt/objgraph/)。

## 总结

最后，带你来总结一下。今天这节课，我们深入了解了Python 的垃圾回收机制，我主要强调下面这几点：

1. 垃圾回收是 Python 自带的机制，用于自动释放不会再用到的内存空间；
2. 引用计数是其中最简单的实现，不过切记，这只是充分非必要条件，因为循环引用需要通过不可达判定，来确定是否可以回收；
3. Python 的自动回收算法包括标记清除和分代收集，主要针对的是循环引用的垃圾收集；
4. 调试内存泄漏方面， objgraph 是很好的可视化分析工具。

## 思考题

最后给你留一道思考题。你能否自己实现一个垃圾回收判定算法呢？我的要求很简单，输入是一个有向图，给定起点，表示程序入口点；给定有向边，输出不可达节点。

希望你可以认真思考这个问题，并且在留言区写下你的答案与我讨论。也欢迎你把这篇文章分享出去，我们一起交流，一起进步。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>Jingxiao</span> 👍（38） 💬（2）<p>思考题答案：

事实上算法可以写的很简单，这是个很经典的 dfs （深度优先搜索）遍历，从起点开始遍历，对遍历到的节点做个记号。遍历完成后，再对所有节点扫一遍，没有被做记号的，就是需要垃圾回收的。</p>2019-07-06</li><br/><li><span>陈迪</span> 👍（24） 💬（4）<p>1. 循环引用情况下Python不立即回收内存，如果放任不管，即不显式调用gc.collect的话，Python的垃圾回收器自己会什么时候处理？
2. 最后介绍了内存泄露排查工具，哪种算内存泄露呢？接问题1，不立即回收算内存泄露吗？还是有其他场景</p>2019-07-03</li><br/><li><span>天凉好个秋</span> 👍（10） 💬（3）<p>本文讲的垃圾回收算法在Java中也都有，当初在设计的时候是不是参考了Java？而且，Java中还有标记整理算法，可以解决回收内存不连续的问题，这个在Python中有没有考虑呢？</p>2019-07-03</li><br/><li><span>　　星豪</span> 👍（5） 💬（1）<p>1. 在读文章的时候找了一个可能是错别字的地方，在循环引用那一节中，第四段试想一下，如果这段代码出现在生产环境中...但经过长时间运行“候”...。这一侯应该是后来的后吧？
2. 当垃圾回收器中新增对象减去删除对象达到相应的阈值时，就会对这一代对象启动垃圾回收。这一句话不是很明白，新增对象我理解的是新创建的对象或者是从上一代挪过来的对象，那么删除对象指的是哪些呢？或者说是如何进行指定哪些是应该被删除的对象呢？</p>2019-07-04</li><br/><li><span>MirkoWei</span> 👍（3） 💬（1）<p>windows下使用objgraph遇到个问题：
`failed to execute [&#39;dot&#39;, &#39;-Tpdf&#39;], make sure the Graphviz executables are on your systems&#39; path`

安装objgraph的时候，需要的前置条件graphviz、xdot都安装了，系统环境变量也添加了，仍然找不到路径

之后通过stackoverflow得到解决办法，就是每次使用的时候，需要在代码前面手动添加环境变量
```
import os

os.environ[&quot;PATH&quot;] += os.pathsep + &#39;xxx&#47;Graphviz2.38&#47;bin&#47;&#39;
```
问题是解决了，但是每次都需要手动添加环境变量也太麻烦了，不知道是否有更好的解决办法</p>2020-05-19</li><br/><li><span>wangkx</span> 👍（1） 💬（1）<p>课程越往后越有意思，发现了很多知识点盲区，这门课很值！</p>2020-07-02</li><br/><li><span>Switch</span> 👍（23） 💬（1）<p>思考题：
from typing import Set


class Graph:
    def __init__(self, value, nodes=None):
        self._value = value
        self._nodes: list = [] if nodes is None else nodes

    @property
    def value(self):
        return self._value

    @property
    def nodes(self):
        return self._nodes

    def node_add(self, node):
        self._nodes.append(node)

    def node_adds(self, nodes):
        self._nodes.extend(nodes)

    def node_del(self, node):
        self._nodes.remove(node)

    def __str__(self):
        return &quot;Graph {} nodes {}&quot;.format(self._value, [node.value for node in self.nodes])

    def __repr__(self):
        return self.__str__()


def dfs(start: Graph, includes: Set[Graph] = None) -&gt; Set[Graph]:
    if includes is None:
        includes = set()
    if start in includes:
        return includes
    includes.add(start)
    for s in start.nodes:
        includes.update(dfs(s, includes))
    return includes


if __name__ == &#39;__main__&#39;:
    A = Graph(&#39;A&#39;)
    B = Graph(&#39;B&#39;)
    C = Graph(&#39;C&#39;)
    D = Graph(&#39;D&#39;)
    E = Graph(&#39;E&#39;)
    F = Graph(&#39;F&#39;)
    has_nodes = {A, B, C, D, E, F}

    # A-&gt;B-&gt;E
    #  -&gt;C-&gt;E
    # B-&gt;A
    # D-&gt;F
    # F-&gt;D
    A.node_adds([B, C])
    B.node_adds([A, E])
    C.node_adds([E])
    D.node_adds([F])
    F.node_adds([D])
    graph_nodes = dfs(A, set())
    # OUT: {Graph B nodes [&#39;A&#39;, &#39;E&#39;], Graph E nodes [], Graph C nodes [&#39;E&#39;], Graph A nodes [&#39;B&#39;, &#39;C&#39;]}
    print(graph_nodes)
    # OUT: {Graph F nodes [&#39;D&#39;], Graph D nodes [&#39;F&#39;]}
    print(has_nodes - graph_nodes)
</p>2019-07-08</li><br/><li><span>youaresherlock</span> 👍（8） 💬（1）<p>四次引用，a，python 的函数调用栈，函数参数，和 getrefcount
不理解这里的函数调用栈、函数参数为什么增加了2次，这里有什么区别？他们两个不是一样的吗，函数参数在函数调用栈里，应该是一次啊</p>2020-07-06</li><br/><li><span>你说呢</span> 👍（5） 💬（0）<p>可以这样理解么：python的垃圾回收机制，以引用计数算法为主、标记-删除算法为辅 来确定内存中哪些对象可以回收；而分代回收算法确定了垃圾是什么时候被回收。
</p>2021-03-17</li><br/><li><span>程序员人生</span> 👍（5） 💬（10）<p>请问一下，老师
执行关于objgraph代码，出现如下错误：
Graph viewer (xdot) and image renderer (dot) not found, not doing anything else
是不是还要安装什么软件？</p>2019-07-03</li><br/><li><span>cool</span> 👍（3） 💬（1）<p>Python 的自动回收算法包括标记清除 ，标记清除怎么来解决循环引用垃圾回收的，专栏中讲解的没听懂，循环引用 能在图中遍历到</p>2020-07-01</li><br/><li><span>微风漂过</span> 👍（3） 💬（0）<p>开头的代码
运行出错：ModuleNotFoundError: No module named &#39;psutil&#39;
安装出错：
pip install --upgrade psutil
Collecting psutil
  Retrying (Retry(total=4, connect=None, read=None, redirect=None, status=None)) after connection broken by &#39;ReadTimeoutError(&quot;HTTPSConnectionPool(host=&#39;pypi.org&#39;, port=443): Read timed out. (read timeout=15)&quot;)&#39;: &#47;simple&#47;psutil&#47;
  Could not find a version that satisfies the requirement psutil (from versions: )
No matching distribution found for psutil
请问这是什么原因？</p>2020-01-31</li><br/><li><span>响雨</span> 👍（2） 💬（0）<p>思考题看的我一脸蒙蔽，无从下手</p>2019-07-03</li><br/><li><span>ァSgr</span> 👍（1） 💬（0）<p>思考题：
def dfs(graph: dict, start: str):
    visited = set()
    stack = [start]

    while stack:
        node = stack.pop()
        if node not in visited:
            visited.add(node)
            stack.extend(graph[node] - visited)

    return visited

def unreachable_nodes(graph: dict, start: str):
    reachable_nodes = dfs(graph, start)
    all_nodes = set(node for nodes in graph.values() for node in nodes).union(graph.keys())
    return all_nodes - reachable_nodes

# 示例图结构
graph = {
    &quot;A&quot;: {&quot;B&quot;, &quot;C&quot;},
    &quot;B&quot;: {&quot;A&quot;, &quot;D&quot;, &quot;E&quot;},
    &quot;C&quot;: {&quot;A&quot;, &quot;F&quot;},
    &quot;D&quot;: {&quot;B&quot;},
    &quot;E&quot;: {&quot;B&quot;, &quot;F&quot;},
    &quot;F&quot;: {&quot;C&quot;, &quot;E&quot;},
    &quot;G&quot;: {&quot;H&quot;},
    &quot;H&quot;: {&quot;G&quot;}
}

print(unreachable_nodes(graph, &#39;A&#39;))

# 输出
{&#39;G&#39;, &#39;H&#39;}</p>2023-05-16</li><br/><li><span>瞌睡的咸鱼</span> 👍（1） 💬（0）<p>思考题——通过有向图的拓扑排序可以求出（可以参考《算法导论》去理解）</p>2019-07-03</li><br/>
</ul>