你好，我是蒋德钧。

时间过得真快，从7月26日上线到现在，我们已经走过了一个半月的学习之旅，不知道你的收获如何呢？

前面我其实也说过，阅读和学习Redis源码确实是一个比较烧脑的任务，需要你多花些时间钻研。而从我的经验来看，阶段性的验证和总结是非常重要的。所以在这里，我特别设置了期中考试周，从9月13日开始到9月19日结束，这期间我们会暂停更新正文内容，你可以好好利用这一周的时间，去回顾一下前20讲的知识，做一个巩固。

有标准才有追求，有追求才有动力，有动力才有进步。一起来挑战一下吧，开启你的期中考试之旅。

我给你出了一套测试题，包括一套选择题和一套问答题。

- 选择题：满分共 100 分，包含4道单选题和6道多选题。提交试卷之后，系统会自动评分。
- 问答题：包括2道题目，不计入分数，但我希望你能认真回答这些问题，可以把你的答案写在留言区。在9月16日这一天，我会公布答案。

### 选择题

[![](https://static001.geekbang.org/resource/image/28/a4/28d1be62669b4f3cc01c36466bf811a4.png)](http://time.geekbang.org/quiz/intro?act_id=926&exam_id=2699)

### 问答题

**第一题**

Redis源码中实现的哈希表在rehash时，会调用dictRehash函数。dictRehash函数的原型如下，它的参数n表示本次rehash要搬移n个哈希桶（bucket）中的数据。假设dictRehash被调用，并且n的传入值为10。但是，在dictRehash查找的10个bucket中，前5个bucket有数据，而后5个bucket没有数据，那么，本次调用dictRehash是否就只搬移了前5个bucket中的数据？

```
int dictRehash(dict *d, int n) 
```

**第二题**

Redis的事件驱动框架是基于操作系统IO多路复用机制进行了封装，以Linux的epoll机制为例，该机制调用epoll\_create函数创建epoll实例，再调用epoll\_ctl将监听的套接字加入监听列表，最后调用epoll\_wait获取就绪的套接字再进行处理。请简述Redis事件驱动框架中哪些函数和epoll机制各主要函数有对应的调用关系。

好了，这节课就到这里。希望你能抓住期中周的机会，查漏补缺，快速提升Redis源码的阅读和学习能力。我们下节课再见！
<div><strong>精选留言（3）</strong></div><ul>
<li><span>曾轼麟</span> 👍（6） 💬（0）<p>问题一：
	应该是只搬运了前5个bucket数据，在函数中会初始化empty_visits为10倍的n，在每次调用改函数的时候最多会遍历10*n个空元素，并且每次只是递减empty_visits，最终当empty_visits为0的时候，方法会直接返回1，结束本次rehash并等待下一次继续，代码如下(返回1代表下次还需要rehash,返回0代表已经完成rehash)：

	int empty_visits = n*10; &#47;* Max number of empty buckets to visit. *&#47;
	while(d-&gt;ht[0].table[d-&gt;rehashidx] == NULL) {
        d-&gt;rehashidx++;
        if (--empty_visits == 0) return 1;
    }

    此外注意到后面也有一个while，其主要的目的就是遍历每个bucket底下的链表，代码如下：

    de = d-&gt;ht[0].table[d-&gt;rehashidx];
    while(de) {
    nextde = de-&gt;next;
    ............(此处省略)............
    de = nextde;
    }



问题二：
以epoll为例子
	1、epoll_create
		对应的调用函数有aeApiCreate，主要是创建epoll的数组最终整体赋值给aeEventLoop中的apidata，在Redis中所有的IO多路复用是封装成了aeApiState的结构体进行调用的。以epoll为例子，在aeApiState中epfd就是epoll的文件描述符数组。

	2、epoll_ctl
		对应的函数有aeApiAddEvent和aeApiDelEvent，其中aeApiAddEvent主要是将已经创建的socket文件描述符，通过调用epoll_ctl方法交给epoll进行管理。而aeApiDelEvent就是移除或者修改对目标socket的管理。

	3、epoll_wait
		对应的函数有aeApiPoll，调用epoll_wait后会返回当前已经触发事件(产生了读，写的socket)，并将对应的socket文件描述符指针和读写类型掩码mask，记录在fired数组上等待后续IO线程的处理。

	整体来说Redis就是通过封装实现了多个aeApixxx方法，从而抽象了各种IO多路复用的方法，并且能按照操作系统类型选择对应的IO多路复用的方式（在宏定义中修改头文件的方式）。
</p>2021-09-14</li><br/><li><span>Milittle</span> 👍（2） 💬（0）<p>1. 第一个问题：empty_visits=n*10，空的都跳过，然后打满n个bucket以后，就停止本次rehash，不管empty_visits满不满无所谓。
2. 从上层到底层：
ae.c:aeCreateEventLoop-&gt;ae_epoll.c:aeApiCreate-&gt;epoll_create
ae.c:aeCreateFileEvent-&gt;ae_epoll.c:aeApiAddEvent-&gt;epoll_ctl
ae.c:aeMain-&gt;aeProcessEvents-&gt;ae_epoll.c:aeApiPoll-&gt;epoll_wait</p>2021-09-14</li><br/><li><span>可怜大灰狼</span> 👍（0） 💬（0）<p>1.empty_visits来控制最大空桶访问数，且是10倍n，所以实际访问桶的数量在[5, 55]。2.在初始化Eventloop的时候会调用aeApiCreate，初始化aeApiState，然后调用epoll_create打开epoll文件描述符。aeApiAddEvent新增事件和aeApiDelEvent删除事件调用epoll_ctl来设置epoll_event。aeProcessEvents获取事件通过aeApiPoll来调用epoll_wait</p>2021-09-14</li><br/>
</ul>