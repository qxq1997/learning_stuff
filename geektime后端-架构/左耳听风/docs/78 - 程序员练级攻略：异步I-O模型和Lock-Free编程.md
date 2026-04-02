你好，我是陈皓，网名左耳朵耗子。

# 异步I/O模型

异步I/O模型是我个人觉得所有程序员都必需要学习的一门技术或是编程方法，这其中的设计模式或是解决方法可以借鉴到分布式架构上来。再说一遍，学习这些模型，是非常非常重要的，你千万要认真学习。

史蒂文斯（Stevens）在《[UNIX网络编程](https://book.douban.com/subject/4859464/)》一书6.2 I/O Models中介绍了五种I/O模型。

- 阻塞I/O
- 非阻塞I/O
- I/O的多路复用（select和poll）
- 信号驱动的I/O（SIGIO）
- 异步I/O（POSIX的aio\_functions）

然后，在前面我们也阅读过了 - [C10K Problem](https://en.wikipedia.org/wiki/C10k_problem) 。相信你对I/O模型也有了一定的了解。 这里，我们需要更为深入地学习I/O模型，尤其是其中的异步I/O模型。

首先，我们看一篇和Java相关的I/O模型的文章来复习一下之前的内容。[Thousands of Threads and Blocking I/O: The Old Way to Write Java Servers Is New Again (and Way Better)](https://www.slideshare.net/e456/tyma-paulmultithreaded1) ，这个PPT中不仅回顾和比较了各种I/O模型，而且还有各种比较细节的方案和说明，是一篇非常不错的文章。

然后，你可以看一篇Java相关的PPT - 道格·莱亚（Doug Lea）的 [Scalable IO in Java](http://gee.cs.oswego.edu/dl/cpjslides/nio.pdf)，这样你会对一些概念有个了解。

接下来，我们需要了解一下各种异步I/O的实现和设计方式。

- [IBM - Boost application performance using asynchronous I/O](https://developer.ibm.com/technologies/linux/articles/l-async/) ，这是一篇关于AIO的文章。
- [Lazy Asynchronous I/O For Event-Driven Servers](https://www.usenix.org/legacy/event/usenix04/tech/general/full_papers/elmeleegy/elmeleegy_html/html.html) ，这篇文章也很不错。
- 另外，异步I/O模型中的 [Windows I/O Completion Ports](https://docs.microsoft.com/en-us/windows/desktop/FileIO/i-o-completion-ports) ,你也需要了解一下。如果MSDN上的这个手册不容易读，你可以看看这篇文章 [Inside I/O Completion Ports](http://sysinternals.d4rk4.ru/Information/IoCompletionPorts.html)。另外，关于Windows，[Windows Internals](https://book.douban.com/subject/6935552/) 这本书你可以仔细读一下，非常不错的。其中有一节I/O Processing也是很不错的，这里我给一个网上免费的链接[I/O Processing](https://flylib.com/books/en/4.491.1.85/1/) 你可以看看Windows是怎么玩的。
- 接下来是Libevent。你可以看一下其主要维护人员尼克·马修森（Nick Mathewson）写的 [Libevent 2.0 book](http://www.wangafu.net/~nickm/libevent-book/)。还有一本国人写的电子书 《[Libevent深入浅出](https://aceld.gitbooks.io/libevent/content/)》。
- 再接下来是 Libuv。你可以看一下其官网的 [Libuv Design Overview](http://docs.libuv.org/en/v1.x/design.html) 了解一下。

我简单总结一下，基本上来说，异步I/O模型的发展技术是： select -&gt; poll -&gt; epoll -&gt; aio -&gt; libevent -&gt; libuv。Unix/Linux用了好几十年走过这些技术的变迁，然而，都不如Windows I/O Completion Port 设计得好（免责声明：这个观点纯属个人观点。相信你仔细研究这些I/O模型后，你会有自己的判断）。

看过这些各种异步I/O模式的实现以后，相信你会看到一个编程模式——Reactor模式。下面是这个模式的相关文章（读这三篇就够了）。

- [Understanding Reactor Pattern: Thread-Based and Event-Driven](https://dzone.com/articles/understanding-reactor-pattern-thread-based-and-eve)
- [Reactor Pattern](https://www.dre.vanderbilt.edu/~schmidt/PDF/Reactor2-93.pdf)
- [The reactor pattern and non-blocking IO](https://www.celum.com/en/blog/technology/the-reactor-pattern-and-non-blocking-io)

然后是几篇有意思的延伸阅读文章。

- [The Secret To 10 Million Concurrent Connections -The Kernel Is The Problem, Not The Solution](http://highscalability.com/blog/2013/5/13/the-secret-to-10-million-concurrent-connections-the-kernel-i.html) - C10M问题来了……
- 还有几篇可能有争议的文章，让你从不同的角度思考。
  
  - [Select is fundamentally broken](https://idea.popcount.org/2017-01-06-select-is-fundamentally-broken/)
  - [Epoll is fundamentally broken 1/2](https://idea.popcount.org/2017-02-20-epoll-is-fundamentally-broken-12/)
  - [Epoll is fundamentally broken 2/2](https://idea.popcount.org/2017-03-20-epoll-is-fundamentally-broken-22/)

# Lock-Free编程相关

Lock-Free - 无锁技术越来越被开发人员重视，因为锁对于性能的影响实在是太大了，所以如果想开发出一个高性能的程序，你就非常有必要学习 Lock-Free的编程方式。

关于无锁的数据结构，有几篇教程你可以看一下。

- [Dr.Dobb’s: Lock-Free Data Structures](http://www.drdobbs.com/lock-free-data-structures/184401865)
- [Andrei Alexandrescu: Lock-Free Data Structures](https://erdani.com/publications/cuj-2004-10.pdf)

然后强烈推荐一本免费的电子书：[Is Parallel Programming Hard, And, If So, What Can You Do About It?](https://www.kernel.org/pub/linux/kernel/people/paulmck/perfbook/perfbook.html) ，这是大牛 [保罗·麦肯尼（Paul E. McKenney）](https://www.linkedin.com/in/paulmckenney/) 写的书。这本书堪称并行编程的经典书，必看。

此时，Wikipedia上有三个词条你要看一下，以此了解并发编程中的一些概念：[Non-blocking algorithm](https://en.wikipedia.org/wiki/Non-blocking_algorithm) 、[Read-copy-update](https://en.wikipedia.org/wiki/Read-copy-update) 和 [Seqlock](https://en.wikipedia.org/wiki/Seqlock)。

接下来，读一下以下两篇论文 。

- [Implementing Lock-Free Queues](http://citeseerx.ist.psu.edu/viewdoc/download?doi=10.1.1.53.8674&rep=rep1&type=pdf)， 这也是一篇很不错的论文，我把它介绍在了我的网站上 ，文章为“[无锁队列的实现](https://coolshell.cn/articles/8239.html)”。
- [Simple, Fast, and Practical Non-Blocking and Blocking Concurrent Queue Algorithms](http://www.cs.rochester.edu/~scott/papers/1996_PODC_queues.pdf) ，这篇论文给出了一个无阻塞和阻塞的并发队列算法。

最后，有几个博客你要订阅一下。

- [1024cores](http://www.1024cores.net/) - 德米特里·伐由科夫（Dmitry Vyukov）的和 lock-free 编程相关的网站。
- [Paul E. McKenney](http://paulmck.livejournal.com/) - 保罗（Paul）的个人网站。
- [Concurrency Freaks](http://concurrencyfreaks.blogspot.com/) - 关于并发算法和相关模式的网站。
- [Preshing on Programming](http://preshing.com/) - 加拿大程序员杰夫·普莱辛（Jeff Preshing）的技术博客，主要关注C++和Python两门编程语言。他用C++11实现了类的反射机制，用C++编写了3D小游戏Hop Out，还为该游戏编写了一个游戏引擎。他还讨论了很多C++的用法，比如C++14推荐的代码写法、新增的某些语言构造等，和Python很相似。阅读这个技术博客上的内容能够深深感受到博主对编程世界的崇敬和痴迷。
- [Sutter’s Mill](http://herbsutter.com/) - 赫布·萨特（Herb Sutter）是一位杰出的C++专家，曾担任ISO C++标准委员会秘书和召集人超过10年。他的博客有关于C++语言标准最新进展的信息，其中也有他的演讲视频。博客中还讨论了其他技术和C++的差异，如C#和JavaScript，它们的性能特点、怎样避免引入性能方面的缺陷等。
- [Mechanical Sympathy](http://mechanical-sympathy.blogspot.com/) - 博主是马丁·汤普森（Martin Thompson），他是一名英国的技术极客，探索现代硬件的功能，并提供开发、培训、性能调优和咨询服务。他的博客主题是Hardware and software working together in harmony，里面探讨了如何设计和编写软件使得它在硬件上能高性能地运行。非常值得一看。

接下来，是一些编程相关的一些C/C++的类库，这样你就不用从头再造轮子了（对于Java的，请参看JDK里的Concurrent开头的一系列的类）。

- [Boost.Lockfree](http://www.boost.org/doc/libs/1_60_0/doc/html/lockfree.html) - Boost库中的无锁数据结构。
- [ConcurrencyKit](https://github.com/concurrencykit/ck) - 并发性编程的原语。
- [Folly](https://github.com/facebook/folly) - Facebook的开源库（它对MPMC队列做了一个很好的实现）。
- [Junction](https://github.com/preshing/junction) - C++中的并发数据结构。
- [MPMCQueue](https://github.com/rigtorp/MPMCQueue) - 一个用C++11编写的有边界的“多生产者-多消费者”无锁队列。
- [SPSCQueue](https://github.com/rigtorp/SPSCQueue) - 一个有边界的“单生产者-单消费者”的无等待、无锁的队列。
- [Seqlock](https://github.com/rigtorp/Seqlock) - 用C++实现的Seqlock。
- [Userspace RCU](http://liburcu.org/) - liburcu是一个用户空间的RCU（Read-copy-update，读-拷贝-更新）库。
- [libcds](https://github.com/khizmax/libcds) - 一个并发数据结构的C++库。
- [liblfds](https://liblfds.org/) - 一个用C语言编写的可移植、无许可证、无锁的数据结构库。

# 其它

- 关于64位系统编程，只要去一个地方就行了： [All about 64-bit programming in one place](https://software.intel.com/en-us/blogs/2011/07/07/all-about-64-bit-programming-in-one-place/)，这是一个关于64位编程相关的收集页面，其中包括相关的文章、28节课程，还有知识库和相关的blog。
- [What Scalable Programs Need from Transactional Memory](https://dl.acm.org/citation.cfm?id=3037750) ，事务性内存（TM）一直是许多研究的重点，它在诸如IBM Blue Gene/Q和Intel Haswell等处理器中得到了支持。许多研究都使用STAMP基准测试套件来评估其设计。然而，我们所知的所有TM系统上的STAMP基准测试所获得的加速比较有限。
  
  例如，在IBM Blue Gene/Q上有64个线程，我们观察到使用Blue Gene/Q硬件事务内存（HTM）的中值加速比为1.4倍，使用软件事务内存（STM）的中值加速比为4.1倍。什么限制了这些TM基准的性能？在本论文中，作者认为问题在于用于编写它们的编程模型和数据结构上，只要使用合适的模型和数据结构，程序的性能可以有10多倍的提升。
- [Improving OpenSSL Performance](https://software.intel.com/en-us/articles/improving-openssl-performance) ，这篇文章除了教你如何提高OpenSSL的执行性能，还讲了一些底层的性能调优知识。
- 关于压缩的内容。为了避免枯燥，主要推荐下面这两篇实践性很强的文章。
  
  - [How eBay’s Shopping Cart used compression techniques to solve network I/O bottlenecks](https://www.ebayinc.com/stories/blogs/tech/how-ebays-shopping-cart-used-compression-techniques-to-solve-network-io-bottlenecks/) ，这是一篇很好的文章，讲述了eBay是如何通过压缩数据来提高整体服务性能的，其中有几个比较好的压缩算法。除了可以让你学到相关的技术知识，还可以让你看到一种比较严谨的工程师文化。
  - [Linkedin: Boosting Site Speed Using Brotli Compression](https://engineering.linkedin.com/blog/2017/05/boosting-site-speed-using-brotli-compression) ，LinkedIn在2017年早些时候开始使用 [Brotli](https://en.wikipedia.org/wiki/Brotli) 来替换 gzip，以此带来更快的访问，这篇文章讲述了什么是Brotli以及与其它压缩程序的比较和所带来的性能提升。
- 这里有两篇关于SSD硬盘性能测试的文章。[Performance Testing with SSDs, Part 1](https://devs.mailchimp.com/blog/performance-testing-with-ssds-part-1/) 和 [Performance Testing with SSDs Part 2](https://devs.mailchimp.com/blog/performance-testing-with-ssds-pt-2/) ，这两篇文章介绍了测试SSD硬盘性能以及相关的操作系统调优方法。
- [Secure Programming HOWTO - Creating Secure Software](https://www.dwheeler.com/secure-programs/) ，这是一本电子书，其中有繁体中文的翻译，这本电子书讲了Linux/Unix下的一些安全编程方面的知识。

# 相关论文

- [Hints for Computer System Design](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/acrobat-17.pdf) ，计算机设计的忠告，这是ACM图灵奖得主 [Butler Lampson](https://en.wikipedia.org/wiki/Butler_Lampson) 在Xerox PARC工作时的一篇论文。这篇论文简明扼要地总结了他在做系统设计时的一些想法，非常值得一读。（用他的话来说，“Studying the design and implementation of a number of computer has led to some general hints for system design. They are described here and illustrated by many examples, ranging from hardware such as the Alto and the Dorado to application programs such as Bravo and Star“。）
- [The 5 minute rule for trading memory for disc accesses and the 5 byte rule for trading memory for CPU time](http://www.hpl.hp.com/techreports/tandem/TR-86.1.pdf) ，根据文章名称也可以看出，5分钟法则是用来衡量内存与磁盘的，而5字节法则则是在内存和CPU之间的权衡。这两个法则是Jim Gray和Franco Putzolu在1986年的文章。
  
  在该论文发表10年后的1997年，Jim Gray和Goetz Graefe 又在 [The Five-Minute Rule Ten Years Later and Other Computer Storage Rules of Thumb](http://research.microsoft.com/en-us/um/people/gray/5_min_rule_SIGMOD.pdf) 中对该法则进行了重新审视。2007年，也就是该论文发表20年后，这年的1月28日，Jim Gray驾驶一艘40英尺长的船从旧金山港出海，目的是航行到附近的费拉隆岛，在那里撒下母亲的骨灰。出海之后，他就同朋友和亲属失去了联系。为了纪念和向大师致敬，时隔10多年后的2009年Goetz Graefe又发表了 [The Five-Minute Rule 20 Years Later (and How Falsh Memory Changes the Rules)](http://cacm.acm.org/magazines/2009/7/32091-the-five-minute-rule-20-years-later/fulltext)。
  
  注明一下，Jim Gray是关系型数据库领域的大师。因在数据库和事务处理研究和实现方面的开创性贡献而获得1998年图灵奖。美国科学院、工程院两院院士，ACM和IEEE两会会士。他25岁成为加州大学伯克利分校计算机科学学院第一位博士。在IBM工作期间参与和主持了IMS、System R、SQL／DS、DB2等项目的开发。后任职于微软研究院，主要关注应用数据库技术来处理各学科的海量信息。

# 小结

好了，总结一下今天的内容。异步I/O模型是我个人觉得所有程序员都必需要学习的一门技术或是编程方法，这其中的设计模式或是解决方法可以借鉴到分布式架构上来。而且我认为，学习这些模型非常重要，你千万要认真学习。

接下来是Lock-Free方面的内容，由于锁对于性能的影响实在是太大了，所以它越来越被开发人员所重视。如果想开发出一个高性能的程序，你非常有必要学习 Lock-Free的编程方式。随后，我给出系统底层方面的其它一些重要知识，如64位编程、提高OpenSSL的执行性能、压缩、SSD硬盘性能测试等。最后介绍了几篇我认为对学习和巩固这些知识非常有帮助的论文，都很经典，推荐你务必看看。

下面是《程序员练级攻略》系列文章的目录。

- [开篇词](https://time.geekbang.org/column/article/8136)
- 入门篇
  
  - [零基础启蒙](https://time.geekbang.org/column/article/8216)
  - [正式入门](https://time.geekbang.org/column/article/8217)
- 修养篇
  
  - [程序员修养](https://time.geekbang.org/column/article/8700)
- 专业基础篇
  
  - [编程语言](https://time.geekbang.org/column/article/8701)
  - [理论学科](https://time.geekbang.org/column/article/8887)
  - [系统知识](https://time.geekbang.org/column/article/8888)
- 软件设计篇
  
  - [软件设计](https://time.geekbang.org/column/article/9369)
- 高手成长篇
  
  - [Linux系统、内存和网络（系统底层知识）](https://time.geekbang.org/column/article/9759)
  - [异步I/O模型和Lock-Free编程（系统底层知识）](https://time.geekbang.org/column/article/9851)
  - [Java底层知识](https://time.geekbang.org/column/article/10216)
  - [数据库](https://time.geekbang.org/column/article/10301)
  - [分布式架构入门（分布式架构）](https://time.geekbang.org/column/article/10603)
  - [分布式架构经典图书和论文（分布式架构）](https://time.geekbang.org/column/article/10604)
  - [分布式架构工程设计(分布式架构)](https://time.geekbang.org/column/article/11232)
  - [微服务](https://time.geekbang.org/column/article/11116)
  - [容器化和自动化运维](https://time.geekbang.org/column/article/11665)
  - [机器学习和人工智能](https://time.geekbang.org/column/article/11669)
  - [前端基础和底层原理（前端方向）](https://time.geekbang.org/column/article/12271)
  - [前端性能优化和框架（前端方向）](https://time.geekbang.org/column/article/12389)
  - [UI/UX设计（前端方向）](https://time.geekbang.org/column/article/12486)
  - [技术资源集散地](https://time.geekbang.org/column/article/12561)
<div><strong>精选留言（15）</strong></div><ul>
<li><span>李小红</span> 👍（51） 💬（6）<p>全部放链接？一篇文章下来全是推荐看其他文章，有时间看那么多文章还订阅这个嘛？</p>2018-06-28</li><br/><li><span>喬海軍</span> 👍（22） 💬（1）<p>老陈领进门，修行靠个人，感谢陈老师给出的这些资料。</p>2018-06-28</li><br/><li><span>子非鱼焉知鱼之乐</span> 👍（16） 💬（5）<p>对专栏还是比较失望，觉得远远没有达预期，没有什么自己深入理解的东西，更像是罗列一些资料和使用经验，越听越失望，即便是介绍的这些资料，也根本没兴趣去查，都有自己的学习资料，不是来听这个的，以为有自己独特的想法和研究，还是名副其实的少。</p>2018-07-20</li><br/><li><span>echo</span> 👍（14） 💬（1）<p>看了这个系列的文章，惊叹于是如何收集如此多的链接。想问下耗子哥，这些链接是平常查询时遇到，觉得很好就分类整理了，并经常查看（手册类）或偶尔回看（经验类）?还是先收藏下来，每一段时间有一个整理的习惯?</p>2018-06-29</li><br/><li><span>poetess</span> 👍（8） 💬（1）<p>对新手一点都不友好啊这个系列</p>2018-06-28</li><br/><li><span>江小田</span> 👍（66） 💬（0）<p>专栏本来就是方向指导性质的，并不会有什么可以让你直接看了就能用，能涨工资的所谓干货，订阅前都提醒过了，干嘛还有那么多抱怨？</p>2018-06-28</li><br/><li><span>yzz</span> 👍（42） 💬（0）<p>如果一本书一篇文章就能让你精通某个技术，那说明这个技术本身就没什么难度（价值），技术就是要静下心来。给这么多干货还不知道感激，感谢陈老师。</p>2018-06-28</li><br/><li><span>vooc</span> 👍（20） 💬（0）<p>看了很多文章下的评论，感觉挺奇怪的。不少人期待的是什么呢，看几篇文章就希望能成为大神？都总想着走捷径，学习是持续的过程，能力也不是一朝一夕就起来的，都只看到大神的风光，却没有看到别人背后的努力跟付出。</p>2018-06-28</li><br/><li><span>流浪</span> 👍（10） 💬（0）<p>这个专栏的干货太多太多了，衷心感谢作者大大的分享！希望作者大大不要像云风一样被其他人的评论影响了，冲冠一怒把专栏删了，损失的是我们😂</p>2018-07-31</li><br/><li><span>mz</span> 👍（10） 💬（0）<p>今年补了一下英语，虽然文章里面还是有很多单词不认识，但是现在已经乐于看英文文章了。</p>2018-06-28</li><br/><li><span>CookeCooler</span> 👍（6） 💬（0）<p>这些干货， 可能是你一辈子都发现不了的好资源。
耗子叔如此慷慨的告诉我们。
这难道不是厚道和良心？</p>2018-12-27</li><br/><li><span>杜小琨</span> 👍（6） 💬（0）<p>赞这一句：技术是严谨的，很难独特。

没有捷径啊，哪怕你是实战出身，最终还是要回归到理论基础，才能触类旁通。最近工作忙，学习时间少了，感觉老了，如果不能做到触类旁通，学一份顶别人学五份，那时间真不够用，这辈子也就这样了。</p>2018-08-16</li><br/><li><span>少年姜太公</span> 👍（6） 💬（0）<p>这类文章很好，囊括相关技术的书籍、博客、论文和框架库，有视野之广度和深度，相比纯粹技术知识分享更有裨益。</p>2018-06-28</li><br/><li><span>Phoenix</span> 👍（6） 💬（0）<p>每周二和周四最期待的事情就是看耗子叔的专栏更新啦</p>2018-06-28</li><br/><li><span>Allen5g</span> 👍（4） 💬（0）<p>打卡第78篇，对于目前水平有太多不懂得地方，昨天晚上梳理了学习路线，后边就是按图索骥，不停的添加，工作两年多了，读了大佬的文章，唯一还合格的技术可能就是英语了</p>2020-03-29</li><br/>
</ul>