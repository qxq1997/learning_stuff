你好，我是盛延敏，这里是网络编程实战的第20讲，欢迎回来。

这一讲是性能篇的第一讲。在性能篇里，我们将把注意力放到如何设计高并发高性能的网络服务器程序上。我希望通过这一模块的学习，让你能够掌握多路复用、异步I/O、多线程等知识，从而可以写出支持并发10K以上的高性能网络服务器程序。

还等什么呢？让我们开始吧。

## 什么是I/O多路复用

在[第11讲](https://time.geekbang.org/column/article/126126)中，我们设计了这样一个应用程序，该程序从标准输入接收数据输入，然后通过套接字发送出去，同时，该程序也通过套接字接收对方发送的数据流。

我们可以使用fgets方法等待标准输入，但是一旦这样做，就没有办法在套接字有数据的时候读出数据；我们也可以使用read方法等待套接字有数据返回，但是这样做，也没有办法在标准输入有数据的情况下，读入数据并发送给对方。

I/O多路复用的设计初衷就是解决这样的场景。我们可以把标准输入、套接字等都看做I/O的一路，多路复用的意思，就是在任何一路I/O有“事件”发生的情况下，通知应用程序去处理相应的I/O事件，这样我们的程序就变成了“多面手”，在同一时刻仿佛可以处理多个I/O事件。

像刚才的例子，使用I/O复用以后，如果标准输入有数据，立即从标准输入读入数据，通过套接字发送出去；如果套接字有数据可以读，立即可以读出数据。

select函数就是这样一种常见的I/O多路复用技术，我们将在后面继续讲解其他的多路复用技术。使用select函数，通知内核挂起进程，当一个或多个I/O事件发生后，控制权返还给应用程序，由应用程序进行I/O事件的处理。

这些I/O事件的类型非常多，比如：

- 标准输入文件描述符准备好可以读。
- 监听套接字准备好，新的连接已经建立成功。
- 已连接套接字准备好可以写。
- 如果一个I/O事件等待超过了10秒，发生了超时事件。

## select函数的使用方法

select函数的使用方法有点复杂，我们先看一下它的声明：

```
int select(int maxfd, fd_set *readset, fd_set *writeset, fd_set *exceptset, const struct timeval *timeout);

返回：若有就绪描述符则为其数目，若超时则为0，若出错则为-1
```

在这个函数中，maxfd表示的是待测试的描述符基数，它的值是待测试的最大描述符加1。比如现在的select待测试的描述符集合是{0,1,4}，那么maxfd就是5，为啥是5，而不是4呢? 我会在下面进行解释。

紧接着的是三个描述符集合，分别是读描述符集合readset、写描述符集合writeset和异常描述符集合exceptset，这三个分别通知内核，在哪些描述符上检测数据可以读，可以写和有异常发生。

那么如何设置这些描述符集合呢？以下的宏可以帮助到我们。

```
void FD_ZERO(fd_set *fdset);　　　　　　
void FD_SET(int fd, fd_set *fdset);　　
void FD_CLR(int fd, fd_set *fdset);　　　
int  FD_ISSET(int fd, fd_set *fdset);
```

如果你刚刚入门，理解这些宏可能有些困难。没有关系，我们可以这样想象，下面一个向量代表了一个描述符集合，其中，这个向量的每个元素都是二进制数中的0或者1。

```
a[maxfd-1], ..., a[1], a[0]
```

我们按照这样的思路来理解这些宏：

- FD\_ZERO用来将这个向量的所有元素都设置成0；
- FD\_SET用来把对应套接字fd的元素，a\[fd]设置成1；
- FD\_CLR用来把对应套接字fd的元素，a\[fd]设置成0；
- FD\_ISSET对这个向量进行检测，判断出对应套接字的元素a\[fd]是0还是1。

其中0代表不需要处理，1代表需要处理。

怎么样，是不是感觉豁然开朗了？

实际上，很多系统是用一个整型数组来表示一个描述字集合的，一个32位的整型数可以表示32个描述字，例如第一个整型数表示0-31描述字，第二个整型数可以表示32-63描述字，以此类推。

这个时候再来理解为什么描述字集合{0,1,4}，对应的maxfd是5，而不是4，就比较方便了。

因为这个向量对应的是下面这样的：

```
a[4],a[3],a[2],a[1],a[0]
```

待测试的描述符个数显然是5， 而不是4。

三个描述符集合中的每一个都可以设置成空，这样就表示不需要内核进行相关的检测。

最后一个参数是timeval结构体时间：

```
struct timeval {
  long   tv_sec; /* seconds */
  long   tv_usec; /* microseconds */
};
```

这个参数设置成不同的值，会有不同的可能：

第一个可能是设置成空(NULL)，表示如果没有I/O事件发生，则select一直等待下去。

第二个可能是设置一个非零的值，这个表示等待固定的一段时间后从select阻塞调用中返回，这在[第12讲](https://time.geekbang.org/column/article/127900)超时的例子里曾经使用过。

第三个可能是将tv\_sec和tv\_usec都设置成0，表示根本不等待，检测完毕立即返回。这种情况使用得比较少。

## 程序例子

下面是一个具体的程序例子，我们通过这个例子来理解select函数。

```
int main(int argc, char **argv) {
    if (argc != 2) {
        error(1, 0, "usage: select01 <IPaddress>");
    }
    int socket_fd = tcp_client(argv[1], SERV_PORT);

    char recv_line[MAXLINE], send_line[MAXLINE];
    int n;

    fd_set readmask;
    fd_set allreads;
    FD_ZERO(&allreads);
    FD_SET(0, &allreads);
    FD_SET(socket_fd, &allreads);

    for (;;) {
        readmask = allreads;
        int rc = select(socket_fd + 1, &readmask, NULL, NULL, NULL);

        if (rc <= 0) {
            error(1, errno, "select failed");
        }

        if (FD_ISSET(socket_fd, &readmask)) {
            n = read(socket_fd, recv_line, MAXLINE);
            if (n < 0) {
                error(1, errno, "read error");
            } else if (n == 0) {
                error(1, 0, "server terminated \n");
            }
            recv_line[n] = 0;
            fputs(recv_line, stdout);
            fputs("\n", stdout);
        }

        if (FD_ISSET(STDIN_FILENO, &readmask)) {
            if (fgets(send_line, MAXLINE, stdin) != NULL) {
                int i = strlen(send_line);
                if (send_line[i - 1] == '\n') {
                    send_line[i - 1] = 0;
                }

                printf("now sending %s\n", send_line);
                size_t rt = write(socket_fd, send_line, strlen(send_line));
                if (rt < 0) {
                    error(1, errno, "write failed ");
                }
                printf("send bytes: %zu \n", rt);
            }
        }
    }

}
```

程序的12行通过FD\_ZERO初始化了一个描述符集合，这个描述符读集合是空的：

![](https://static001.geekbang.org/resource/image/ce/68/cea07eee264c1abf69c04aacfae56c68.png?wh=628%2A192)  
接下来程序的第13和14行，分别使用FD\_SET将描述符0，即标准输入，以及连接套接字描述符3设置为待检测：

![](https://static001.geekbang.org/resource/image/71/f2/714f4fb84ab9afb39e51f6bcfc18def2.png?wh=640%2A200)  
接下来的16-51行是循环检测，这里我们没有阻塞在fgets或read调用，而是通过select来检测套接字描述字有数据可读，或者标准输入有数据可读。比如，当用户通过标准输入使得标准输入描述符可读时，返回的readmask的值为：

![](https://static001.geekbang.org/resource/image/b9/bd/b90d1df438847d5e11d80485a23817bd.png?wh=632%2A194)  
这个时候select调用返回，可以使用FD\_ISSET来判断哪个描述符准备好可读了。如上图所示，这个时候是标准输入可读，37-51行程序读入后发送给对端。

如果是连接描述字准备好可读了，第24行判断为真，使用read将套接字数据读出。

我们需要注意的是，这个程序的17-18行非常重要，初学者很容易在这里掉坑里去。

第17行是每次测试完之后，重新设置待测试的描述符集合。你可以看到上面的例子，在select测试之前的数据是{0,3}，select测试之后就变成了{0}。

这是因为select调用每次完成测试之后，内核都会修改描述符集合，通过修改完的描述符集合来和应用程序交互，应用程序使用FD\_ISSET来对每个描述符进行判断，从而知道什么样的事件发生。

第18行则是使用socket\_fd+1来表示待测试的描述符基数。切记需要+1。

## 套接字描述符就绪条件

当我们说select测试返回，某个套接字准备好可读，表示什么样的事件发生呢？

第一种情况是套接字接收缓冲区有数据可以读，如果我们使用read函数去执行读操作，肯定不会被阻塞，而是会直接读到这部分数据。

第二种情况是对方发送了FIN，使用read函数执行读操作，不会被阻塞，直接返回0。

第三种情况是针对一个监听套接字而言的，有已经完成的连接建立，此时使用accept函数去执行不会阻塞，直接返回已经完成的连接。

第四种情况是套接字有错误待处理，使用read函数去执行读操作，不阻塞，且返回-1。

总结成一句话就是，内核通知我们套接字有数据可以读了，使用read函数不会阻塞。

不知道你是不是和我一样，刚开始理解某个套接字可写的时候，会有一个错觉，总是从应用程序角度出发去理解套接字可写，我开始是这样想的，当应用程序完成相应的计算，有数据准备发送给对端了，可以往套接字写，对应的就是套接字可写。

其实这个理解是非常不正确的，select检测套接字可写，**完全是基于套接字本身的特性来说**的，具体来说有以下几种情况。

第一种是套接字发送缓冲区足够大，如果我们使用阻塞套接字进行write操作，将不会被阻塞，直接返回。

第二种是连接的写半边已经关闭，如果继续进行写操作将会产生SIGPIPE信号。

第三种是套接字上有错误待处理，使用write函数去执行写操作，不阻塞，且返回-1。

总结成一句话就是，内核通知我们套接字可以往里写了，使用write函数就不会阻塞。

## 总结

今天我讲了select函数的使用。select函数提供了最基本的I/O多路复用方法，在使用select时，我们需要建立两个重要的认识：

- 描述符基数是当前最大描述符+1；
- 每次select调用完成之后，记得要重置待测试集合。

## 思考题

和往常一样，给你布置两道思考题：

第一道， select可以对诸如UNIX管道(pipe)这样的描述字进行检测么？如果可以，检测的就绪条件是什么呢？

第二道，根据我们前面的描述，一个描述符集合哪些描述符被设置为1，需要进行检测是完全可以知道的，你认为select函数里一定需要传入描述字基数这个值么？请你分析一下这样设计的目的又是什么呢？

欢迎你在评论区写下你的思考，也欢迎把这篇文章分享给你的朋友或者同事，一起交流一下。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>拂尘</span> 👍（52） 💬（3）<p>我一直很好奇，为啥说select函数对fd有1024的限制，找了点资料共勉：
首先，man select，搜索FD_SETSIZE会看到如下的内容
An fd_set is a fixed size buffer. Executing FD_CLR() or FD_SET() with a value of fd that is negative or is equal to or larger than FD_SETSIZE will result in undefined behavior. Moreover, POSIX requires fd to be a valid file descriptor.
其中最关键的是FD_SETSIZE，是在bitmap位图运算的时候会受到他的影响
其次，sys&#47;select.h头文件有如下定义：
#define FD_SETSIZE __FD_SETSIZE
typesizes.h头文件有如下定义：
#define __FD_SETSIZE 1024

由此，终于看到了1024的准确限制。

同时man里也说明了一个限制，不是0-1023的fd会导致未定义的行为。</p>2020-02-29</li><br/><li><span>Keep-Moving</span> 👍（16） 💬（9）<p>allreads = {0, 3};
老师，这一步是怎么实现的？没看出来
</p>2019-09-23</li><br/><li><span>无名</span> 👍（14） 💬（4）<p>对于套接字可写状态中说的：套接字发送缓冲区足够大，怎么样算足够大呢？</p>2019-11-04</li><br/><li><span>钱</span> 👍（12） 💬（5）<p>1：I&#47;O 多路复用的设计初衷就是解决这样的场景，把标准输入、套接字等都看做 I&#47;O 的一路，多路复用的意思，就是在任何一路 I&#47;O 有“事件”发生的情况下，通知应用程序去处理相应的 I&#47;O 事件，这样我们的程序就变成了“多面手”，在同一时刻仿佛可以处理多个 I&#47;O 事件。
2：select 函数就是这样一种常见的 I&#47;O 多路复用技术，使用 select 函数，通知内核挂起进程，当一个或多个 I&#47;O 事件发生后，控制权返还给应用程序，由应用程序进行 I&#47;O 事件的处理。

int select(int maxfd, fd_set *readset, fd_set *writeset, fd_set *exceptset, const struct timeval *timeout);

返回：若有就绪描述符则为其数目，若超时则为 0，若出错则为 -1

在这个函数中，maxfd 表示的是待测试的描述符基数，它的值是待测试的最大描述符加 1。
紧接着的是三个描述符集合，分别是读描述符集合 readset、写描述符集合 writeset 和异常描述符集合 exceptset，这三个分别通知内核，在哪些描述符上检测数据可以读，可以写和有异常发生。
三个描述符集合中的每一个都可以设置成空，这样就表示不需要内核进行相关的检测。
timeout设置成不同的值，会有不同的可能：
第一个可能是设置成空 (NULL)，表示如果没有 I&#47;O 事件发生，则 select 一直等待下去。
第二个可能是设置一个非零的值，这个表示等待固定的一段时间后从 select 阻塞调用中返回。
第三个可能是将 tv_sec 和 tv_usec 都设置成 0，表示根本不等待，检测完毕立即返回。这种情况使用得比较少。

3：内核通知我们套接字有数据可以读了，使用 read 函数不会阻塞。
内核通知我们套接字可以往里写了，使用 write 函数就不会阻塞。

读了几遍，感觉还是没有抓住核心，所以，就将文中的要点摘录下来。
对IO多路复用的大概理解是，通过select函数去监听一组文件描述符，如果有事件就绪就交给应用程序去做对应的处理。</p>2019-11-24</li><br/><li><span>无名</span> 👍（11） 💬（1）<p>size_t rt = write(socket_fd, send_line, strlen(send_line));
if (rt &lt; 0) {
     error(1, errno, &quot;write failed &quot;);
 }
这个代码中有错吧，应该将size_t改为sszie_t，size_t为unsigned long，这样错误-1被转换了。</p>2019-09-27</li><br/><li><span>乔丹</span> 👍（10） 💬（1）<p>老师，两个疑问：
1. 为什么socket_fd一定是3呢？ 
2. 如果socket_fd = 2000, 那么传入select函数的值就是2001了， 这样不是大于1024了吗？
这个点我没有想通。</p>2020-12-20</li><br/><li><span>awmthink</span> 👍（7） 💬（1）<p>老师，哪种场景下需要多路复用　“写描述符”　呢？ 什么时候能写应用程序不知道吗？</p>2020-04-16</li><br/><li><span>莫珣</span> 👍（7） 💬（2）<p>我有些疑问，select的FD数组大小默认是1024，但是Linux的文件描述符大小一定不是1024，假设现在使用ulimit将一个进程可以打开的文件数设置成了65535，那么大于1024的文件描述符怎么加到FD数组中去呢，如果按照文本里说的，文件描述符代表数组下标的话不就加不进去了？

第二个问题，套接字有两个属性，接收低水位线和发送低水位线，当接收缓冲区中待接收的字节数大于接收低水位线，一个可读事件产生，那么如果永远都不能达到接收低水位线呢？
</p>2019-09-23</li><br/><li><span>нáпの゛</span> 👍（5） 💬（2）<p>第一道题，理解管道也是文件，往管道输入数据和输出数据对应可读可写的就绪条件。
第二道题，我理解fd_set本身是数组，如果不传入描述字基数，无法得知fd_set的具体大小，应该是无法进行遍历操作的。</p>2020-09-01</li><br/><li><span>rongyefeng</span> 👍（4） 💬（1）<p>“第一种是套接字发送缓冲区足够大，如果我们使用非阻塞套接字进行 write 操作，将不会被阻塞，直接返回。”
老师，请问这里是不是应该写成“如果我们使用阻塞套接字进行write操作......”才对？</p>2020-05-19</li><br/><li><span>麻雀</span> 👍（4） 💬（1）<p>您好，
第一，想问下select是不是能够在处理数据的同时继续轮询（监听）是否有新的套接字来到，它的内部是不是多线程呢？因为accept就是因为单线程在处理数据时，不能对这段时间内到来的套接字进行监听。 
第二，FD_SET它是一个unsigned long数组，那么它怎么实现Bitmap，只是对数组的每个元素例如fd_set[10]对文件描述符为10的套接字来数据的时候设置为1吗？</p>2019-12-30</li><br/><li><span>Joker</span> 👍（3） 💬（1）<p>小明原来只在一个家书店里等着，后来发现等着无聊，回家，然后在去书店等；后来发现别的书店，索性就好几家一起问，问了这个去下一家，看看哪家书到了，就先买哪一家的。</p>2020-04-17</li><br/><li><span>打奥特曼的小怪兽</span> 👍（3） 💬（1）<p>关于 FD_SET() 函数，debug看了下内存结构，{0,3} 如果设置了，实际上存储的是 2^0 + 2^3 = 9,并不会像图示的在每个位置上设置1。</p>2019-11-06</li><br/><li><span>imsunv</span> 👍（2） 💬（2）<p>内核通知我们套接字可以往里写了，使用 write 函数就不会阻塞 。
那么如果写的内容超过了 缓冲区的大小，会阻塞么</p>2020-08-09</li><br/><li><span>小仙女</span> 👍（2） 💬（1）<p>int select(int maxfd, fd_set *readset, fd_set *writeset, fd_set *exceptset, const struct timeval *timeout);
这里的fd_set 是什么结构

0:标准输入
1：标准输出
2：标准错误
3：socket

是这样吗？？
</p>2020-07-23</li><br/>
</ul>