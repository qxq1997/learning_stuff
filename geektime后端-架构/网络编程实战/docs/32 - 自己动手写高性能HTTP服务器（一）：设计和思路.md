你好，我是盛延敏，这里是网络编程实战第32讲，欢迎回来。

从这一讲开始，我们进入实战篇，开启一个高性能HTTP服务器的编写之旅。

在开始编写高性能HTTP服务器之前，我们先要构建一个支持TCP的高性能网络编程框架，完成这个TCP高性能网络框架之后，再增加HTTP特性的支持就比较容易了，这样就可以很快开发出一个高性能的HTTP服务器程序。

## 设计需求

在第三个模块性能篇中，我们已经使用这个网络编程框架完成了多个应用程序的开发，这也等于对网络编程框架提出了编程接口方面的需求。综合之前的使用经验，TCP高性能网络框架需要满足的需求有以下三点。

第一，采用reactor模型，可以灵活使用poll/epoll作为事件分发实现。

第二，必须支持多线程，从而可以支持单线程单reactor模式，也可以支持多线程主-从reactor模式。可以将套接字上的I/O事件分离到多个线程上。

第三，封装读写操作到Buffer对象中。

按照这三个需求，正好可以把整体设计思路分成三块来讲解，分别包括反应堆模式设计、I/O模型和多线程模型设计、数据读写封装和buffer。今天我们主要讲一下主要的设计思路和数据结构，以及反应堆模式设计。

## 主要设计思路

### 反应堆模式设计

反应堆模式，按照性能篇的讲解，主要是设计一个基于事件分发和回调的反应堆框架。这个框架里面的主要对象包括：

- ### event\_loop

你可以把event\_loop这个对象理解成和一个线程绑定的无限事件循环，你会在各种语言里看到event\_loop这个抽象。这是什么意思呢？简单来说，它就是一个无限循环着的事件分发器，一旦有事件发生，它就会回调预先定义好的回调函数，完成事件的处理。

具体来说，event\_loop使用poll或者epoll方法将一个线程阻塞，等待各种I/O事件的发生。

- ### channel

对各种注册到event\_loop上的对象，我们抽象成channel来表示，例如注册到event\_loop上的监听事件，注册到event\_loop上的套接字读写事件等。在各种语言的API里，你都会看到channel这个对象，大体上它们表达的意思跟我们这里的设计思路是比较一致的。

- ### acceptor

acceptor对象表示的是服务器端监听器，acceptor对象最终会作为一个channel对象，注册到event\_loop上，以便进行连接完成的事件分发和检测。

- ### event\_dispatcher

event\_dispatcher是对事件分发机制的一种抽象，也就是说，可以实现一个基于poll的poll\_dispatcher，也可以实现一个基于epoll的epoll\_dispatcher。在这里，我们统一设计一个event\_dispatcher结构体，来抽象这些行为。

- ### channel\_map

channel\_map保存了描述字到channel的映射，这样就可以在事件发生时，根据事件类型对应的套接字快速找到channel对象里的事件处理函数。

### I/O模型和多线程模型设计

I/O线程和多线程模型，主要解决event\_loop的线程运行问题，以及事件分发和回调的线程执行问题。

- ### thread\_pool

thread\_pool维护了一个sub-reactor的线程列表，它可以提供给主reactor线程使用，每次当有新的连接建立时，可以从thread\_pool里获取一个线程，以便用它来完成对新连接套接字的read/write事件注册，将I/O线程和主reactor线程分离。

- ### event\_loop\_thread

event\_loop\_thread是reactor的线程实现，连接套接字的read/write事件检测都是在这个线程里完成的。

### Buffer和数据读写

- ### buffer

buffer对象屏蔽了对套接字进行的写和读的操作，如果没有buffer对象，连接套接字的read/write事件都需要和字节流直接打交道，这显然是不友好的。所以，我们也提供了一个基本的buffer对象，用来表示从连接套接字收取的数据，以及应用程序即将需要发送出去的数据。

- ### tcp\_connection

tcp\_connection这个对象描述的是已建立的TCP连接。它的属性包括接收缓冲区、发送缓冲区、channel对象等。这些都是一个TCP连接的天然属性。

tcp\_connection是大部分应用程序和我们的高性能框架直接打交道的数据结构。我们不想把最下层的channel对象暴露给应用程序，因为抽象的channel对象不仅仅可以表示tcp\_connection，前面提到的监听套接字也是一个channel对象，后面提到的唤醒socketpair也是一个 channel对象。所以，我们设计了tcp\_connection这个对象，希望可以提供给用户比较清晰的编程入口。

## 反应堆模式设计

### 概述

下面，我们详细讲解一下以event\_loop为核心的反应堆模式设计。这里有一张event\_loop的运行详图，你可以对照这张图来理解。

![](https://static001.geekbang.org/resource/image/7a/61/7ab9f89544aba2021a9d2ceb94ad9661.jpg?wh=3499%2A1264)

当event\_loop\_run完成之后，线程进入循环，首先执行dispatch事件分发，一旦有事件发生，就会调用channel\_event\_activate函数，在这个函数中完成事件回调函数eventReadcallback和eventWritecallback的调用，最后再进行event\_loop\_handle\_pending\_channel，用来修改当前监听的事件列表，完成这个部分之后，又进入了事件分发循环。

### event\_loop分析

说event\_loop是整个反应堆模式设计的核心，一点也不为过。先看一下event\_loop的数据结构。

在这个数据结构中，最重要的莫过于event\_dispatcher对象了。你可以简单地把event\_dispatcher理解为poll或者epoll，它可以让我们的线程挂起，等待事件的发生。

这里有一个小技巧，就是event\_dispatcher\_data，它被定义为一个void \*类型，可以按照我们的需求，任意放置一个我们需要的对象指针。这样，针对不同的实现，例如poll或者epoll，都可以根据需求，放置不同的数据对象。

event\_loop中还保留了几个跟多线程有关的对象，如owner\_thread\_id是保留了每个event loop的线程ID，mutex和con是用来进行线程同步的。

socketPair是父线程用来通知子线程有新的事件需要处理。pending\_head和pending\_tail是保留在子线程内的需要处理的新事件。

```
struct event_loop {
    int quit;
    const struct event_dispatcher *eventDispatcher;

    /** 对应的event_dispatcher的数据. */
    void *event_dispatcher_data;
    struct channel_map *channelMap;

    int is_handle_pending;
    struct channel_element *pending_head;
    struct channel_element *pending_tail;

    pthread_t owner_thread_id;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    int socketPair[2];
    char *thread_name;
};
```

下面我们看一下event\_loop最主要的方法event\_loop\_run方法，前面提到过，event\_loop就是一个无限while循环，不断地在分发事件。

```
/**
 *
 * 1.参数验证
 * 2.调用dispatcher来进行事件分发,分发完回调事件处理函数
 */
int event_loop_run(struct event_loop *eventLoop) {
    assert(eventLoop != NULL);

    struct event_dispatcher *dispatcher = eventLoop->eventDispatcher;

    if (eventLoop->owner_thread_id != pthread_self()) {
        exit(1);
    }

    yolanda_msgx("event loop run, %s", eventLoop->thread_name);
    struct timeval timeval;
    timeval.tv_sec = 1;

    while (!eventLoop->quit) {
        //block here to wait I/O event, and get active channels
        dispatcher->dispatch(eventLoop, &timeval);

        //handle the pending channel
        event_loop_handle_pending_channel(eventLoop);
    }

    yolanda_msgx("event loop end, %s", eventLoop->thread_name);
    return 0;
}
```

代码很明显地反映了这一点，这里我们在event\_loop不退出的情况下，一直在循环，循环体中调用了dispatcher对象的dispatch方法来等待事件的发生。

### event\_dispacher分析

为了实现不同的事件分发机制，这里把poll、epoll等抽象成了一个event\_dispatcher结构。event\_dispatcher的具体实现有poll\_dispatcher和epoll\_dispatcher两种，实现的方法和性能篇[21](https://time.geekbang.org/column/article/140520)[讲](https://time.geekbang.org/column/article/140520)和[22讲](https://time.geekbang.org/column/article/141573)类似，这里就不再赘述，你如果有兴趣的话，可以直接研读代码。

```
/** 抽象的event_dispatcher结构体，对应的实现如select,poll,epoll等I/O复用. */
struct event_dispatcher {
    /**  对应实现 */
    const char *name;

    /**  初始化函数 */
    void *(*init)(struct event_loop * eventLoop);

    /** 通知dispatcher新增一个channel事件*/
    int (*add)(struct event_loop * eventLoop, struct channel * channel);

    /** 通知dispatcher删除一个channel事件*/
    int (*del)(struct event_loop * eventLoop, struct channel * channel);

    /** 通知dispatcher更新channel对应的事件*/
    int (*update)(struct event_loop * eventLoop, struct channel * channel);

    /** 实现事件分发，然后调用event_loop的event_activate方法执行callback*/
    int (*dispatch)(struct event_loop * eventLoop, struct timeval *);

    /** 清除数据 */
    void (*clear)(struct event_loop * eventLoop);
};
```

### channel对象分析

channel对象是用来和event\_dispather进行交互的最主要的结构体，它抽象了事件分发。一个channel对应一个描述字，描述字上可以有READ可读事件，也可以有WRITE可写事件。channel对象绑定了事件处理函数event\_read\_callback和event\_write\_callback。

```
typedef int (*event_read_callback)(void *data);

typedef int (*event_write_callback)(void *data);

struct channel {
    int fd;
    int events;   //表示event类型

    event_read_callback eventReadCallback;
    event_write_callback eventWriteCallback;
    void *data; //callback data, 可能是event_loop，也可能是tcp_server或者tcp_connection
};
```

### channel\_map对象分析

event\_dispatcher在获得活动事件列表之后，需要通过文件描述字找到对应的channel，从而回调channel上的事件处理函数event\_read\_callback和event\_write\_callback，为此，设计了channel\_map对象。

```
/**
 * channel映射表, key为对应的socket描述字
 */
struct channel_map {
    void **entries;

    /* The number of entries available in entries */
    int nentries;
};
```

channel\_map对象是一个数组，数组的下标即为描述字，数组的元素为channel对象的地址。

比如描述字3对应的channel，就可以这样直接得到。

```
struct chanenl * channel = map->entries[3];
```

这样，当event\_dispatcher需要回调channel上的读、写函数时，调用channel\_event\_activate就可以，下面是channel\_event\_activate的实现，在找到了对应的channel对象之后，根据事件类型，回调了读函数或者写函数。注意，这里使用了EVENT\_READ和EVENT\_WRITE来抽象了poll和epoll的所有读写事件类型。

```
int channel_event_activate(struct event_loop *eventLoop, int fd, int revents) {
    struct channel_map *map = eventLoop->channelMap;
    yolanda_msgx("activate channel fd == %d, revents=%d, %s", fd, revents, eventLoop->thread_name);

    if (fd < 0)
        return 0;

    if (fd >= map->nentries)return (-1);

    struct channel *channel = map->entries[fd];
    assert(fd == channel->fd);

    if (revents & (EVENT_READ)) {
        if (channel->eventReadCallback) channel->eventReadCallback(channel->data);
    }
    if (revents & (EVENT_WRITE)) {
        if (channel->eventWriteCallback) channel->eventWriteCallback(channel->data);
    }

    return 0;
}
```

### 增加、删除、修改channel event

那么如何增加新的channel event事件呢？下面这几个函数是用来增加、删除和修改channel event事件的。

```
int event_loop_add_channel_event(struct event_loop *eventLoop, int fd, struct channel *channel1);

int event_loop_remove_channel_event(struct event_loop *eventLoop, int fd, struct channel *channel1);

int event_loop_update_channel_event(struct event_loop *eventLoop, int fd, struct channel *channel1);
```

前面三个函数提供了入口能力，而真正的实现则落在这三个函数上：

```
int event_loop_handle_pending_add(struct event_loop *eventLoop, int fd, struct channel *channel);

int event_loop_handle_pending_remove(struct event_loop *eventLoop, int fd, struct channel *channel);

int event_loop_handle_pending_update(struct event_loop *eventLoop, int fd, struct channel *channel);
```

我们看一下其中的一个实现，event\_loop\_handle\_pending\_add在当前event\_loop的channel\_map里增加一个新的key-value对，key是文件描述字，value是channel对象的地址。之后调用event\_dispatcher对象的add方法增加channel event事件。注意这个方法总在当前的I/O线程中执行。

```
// in the i/o thread
int event_loop_handle_pending_add(struct event_loop *eventLoop, int fd, struct channel *channel) {
    yolanda_msgx("add channel fd == %d, %s", fd, eventLoop->thread_name);
    struct channel_map *map = eventLoop->channelMap;

    if (fd < 0)
        return 0;

    if (fd >= map->nentries) {
        if (map_make_space(map, fd, sizeof(struct channel *)) == -1)
            return (-1);
    }

    //第一次创建，增加
    if ((map)->entries[fd] == NULL) {
        map->entries[fd] = channel;
        //add channel
        struct event_dispatcher *eventDispatcher = eventLoop->eventDispatcher;
        eventDispatcher->add(eventLoop, channel);
        return 1;
    }

    return 0;
}
```

## 总结

在这一讲里，我们介绍了高性能网络编程框架的主要设计思路和基本数据结构，以及反应堆设计相关的具体做法。在接下来的章节中，我们将继续编写高性能网络编程框架的线程模型以及读写Buffer部分。

## 思考题

和往常一样，给你留两道思考题:

第一道，如果你有兴趣，不妨实现一个select\_dispatcher对象，用select方法实现定义好的event\_dispatcher接口；

第二道，仔细研读channel\_map实现中的map\_make\_space部分，说说你的理解。

欢迎你在评论区写下你的思考，也欢迎把这篇文章分享给你的朋友或者同事，一起交流一下。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>吴小智</span> 👍（7） 💬（2）<p>map_make_space() 函数里 realloc() 和 memset() 两个函数用的很巧妙啊，realloc() 用来扩容，且把旧的内容搬过去，memset() 用来给新申请的内存赋 0 值。赞，C 语言太强大了。</p>2019-10-22</li><br/><li><span>LDxy</span> 👍（7） 💬（1）<p>event_loop_handle_pending_add函数中，
map-&gt;entries[fd] = calloc(1, sizeof(struct channel *));
map-&gt;entries[fd] = channel;
这两行都给map-&gt;entries[fd] 赋值，后一行不是覆盖上一行的赋值了么？有何用意？</p>2019-10-21</li><br/><li><span>酸葡萄</span> 👍（3） 💬（2）<p>老师你好，问个基础的问题：
epoll_dispatcher和poll_dispatcher都有，在添加，删除，更新事件时都有如下的逻辑，其中if条件中的判断怎么理解啊？
if (channel1-&gt;events &amp; EVENT_READ) {
        events = events | POLLRDNORM;
    }

    if (channel1-&gt;events &amp; EVENT_WRITE) {
        events = events | POLLWRNORM;
    }</p>2019-12-01</li><br/><li><span>沉淀的梦想</span> 👍（2） 💬（3）<p>看到map_make_space里面的realloc函数，突然有个疑问，既然操作系统底层支持直接在原数组上扩充内存，为什么Java不支持直接在原数组上扩容呢，ArrayList每次扩容都要重新拷贝一份原来的数据。</p>2019-10-22</li><br/><li><span>凌空飞起的剪刀腿</span> 👍（1） 💬（1）<p>int map_make_space(struct channel_map *map, int slot, int msize) {
    if (map-&gt;nentries &lt;= slot) {
        int nentries = map-&gt;nentries ? map-&gt;nentries : 32;
        void **tmp;

        while (nentries &lt;= slot)
            nentries &lt;&lt;= 1;

        tmp = (void **) realloc(map-&gt;entries, nentries * msize);
        if (tmp == NULL)
            return (-1);

        memset(&amp;tmp[map-&gt;nentries], 0,
               (nentries - map-&gt;nentries) * msize);

        map-&gt;nentries = nentries;
        map-&gt;entries = tmp;
    }

    return (0);
}
老师，fd不一定是连续的吧，这样会浪费内存存储空间吧？</p>2021-06-07</li><br/><li><span>谁家内存泄露了</span> 👍（1） 💬（1）<p>老师好，请问您的代码中关于锁的使用，我想知道您关于每个loop都设计了一个锁，可是这几个mutex都是局部变量吧？他们的作用范围是什么样的呢？这里想不清楚，请指点一下！</p>2021-04-12</li><br/><li><span>Steiner</span> 👍（1） 💬（1）<p>如果Channel是一个管道，他连接着哪两个对象？</p>2021-02-18</li><br/><li><span>漠博嵩</span> 👍（0） 💬（1）<p>感觉就是仿照netty框架做的</p>2022-05-24</li><br/><li><span>菜鸡</span> 👍（0） 💬（1）<p>第二个问题有点疑问。channel_map中元素的空间大小是与fd的值正相关的，而不是跟当前在线的连接数量正相关，这样做是不是有点浪费内存？比如经历了很多次连接、断开之后，fd返回的值比较大，而此时只有几个未断开的连接，那么channel_map有必要申请那么大的内存空间嘛？</p>2022-05-08</li><br/><li><span>群书</span> 👍（0） 💬（1）<p>用sock对通知 唤醒会不会增加逻辑线程或主线程的系统调用次数 限制了吞吐量呢</p>2021-11-12</li><br/><li><span>Steiner</span> 👍（0） 💬（1）<p>我看了下定义，channel_element就像是个链表节点，为什么不用C++来做这块呢？</p>2021-02-18</li><br/><li><span>YUAN</span> 👍（0） 💬（1）<p>老师请问这个channel就相当于libevent中的event结构体吧？</p>2020-11-05</li><br/><li><span>spark</span> 👍（0） 💬（2）<p>盛老师好: 为什么要在下面这个函数中lock和unlock? 不是每个线程都对应一个自己的event_loop吗?
这样的话event_loop就不是shared resource。
int event_loop_handle_pending_channel(struct event_loop *eventLoop) {
    &#47;&#47;get the lock
    pthread_mutex_lock(&amp;eventLoop-&gt;mutex);
    eventLoop-&gt;is_handle_pending = 1;

    struct channel_element *channelElement = eventLoop-&gt;pending_head;
    while (channelElement != NULL) {
        &#47;&#47;save into event_map
        struct channel *channel = channelElement-&gt;channel;
        int fd = channel-&gt;fd;
        if (channelElement-&gt;type == 1) {
            event_loop_handle_pending_add(eventLoop, fd, channel);
        } else if (channelElement-&gt;type == 2) {
            event_loop_handle_pending_remove(eventLoop, fd, channel);
        } else if (channelElement-&gt;type == 3) {
            event_loop_handle_pending_update(eventLoop, fd, channel);
        }
        channelElement = channelElement-&gt;next;
    }

    eventLoop-&gt;pending_head = eventLoop-&gt;pending_tail = NULL;
    eventLoop-&gt;is_handle_pending = 0;

    &#47;&#47;release the lock
    pthread_mutex_unlock(&amp;eventLoop-&gt;mutex);

    return 0;
}</p>2020-09-25</li><br/><li><span>衬衫的价格是19美元</span> 👍（0） 💬（2）<p>channel_map这里map-&gt;entries是一个数组，数组的下标是fd,数组的元素是channel的地址，如果新增的fd跳变很大的话比如从3变成了100，会不会浪费了很多的空间</p>2020-07-23</li><br/><li><span>胤</span> 👍（0） 💬（1）<p>问个c语言的问题，比如event_loop_handle_pending_channel这个函数，返回值是int类型，但是除了函数最后是个return 0，其他地方没有错误处理，为什么要返回0？还是就是一种习惯？</p>2020-05-04</li><br/>
</ul>