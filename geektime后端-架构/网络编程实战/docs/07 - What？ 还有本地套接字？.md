你好，我是盛延敏，这里是网络编程实战第7讲，欢迎回来。

上一篇文章中，我们讲了UDP。很多同学都知道TCP和UDP，但是对本地套接字却不甚了解。

实际上，本地套接字是IPC，也就是本地进程间通信的一种实现方式。除了本地套接字以外，其它技术，诸如管道、共享消息队列等也是进程间通信的常用方法，但因为本地套接字开发便捷，接受度高，所以普遍适用于在同一台主机上进程间通信的各种场景。

那么今天我们就来学习下本地套接字方面的知识，并且利用本地套接字完成可靠字节流和数据报两种协议。

## 从例子开始

现在最火的云计算技术是什么？无疑是Kubernetes和Docker。在Kubernetes和Docker的技术体系中，有很多优秀的设计，比如Kubernetes的CRI（Container Runtime Interface），其思想是将Kubernetes的主要逻辑和Container Runtime的实现解耦。

我们可以通过netstat命令查看Linux系统内的本地套接字状况，下面这张图列出了路径为/var/run/dockershim.socket的stream类型的本地套接字，可以清楚地看到开启这个套接字的进程为kubelet。kubelet是Kubernetes的一个组件，这个组件负责将控制器和调度器的命令转化为单机上的容器实例。为了实现和容器运行时的解耦，kubelet设计了基于本地套接字的客户端-服务器GRPC调用。

![](https://static001.geekbang.org/resource/image/c7/6b/c75a8467a84f30e523917f28f2f4266b.jpg?wh=2998%2A1346)  
眼尖的同学可能发现列表里还有docker-containerd.sock等其他本地套接字，是的，Docker其实也是大量使用了本地套接字技术来构建的。

如果我们在/var/run目录下将会看到docker使用的本地套接字描述符:

![](https://static001.geekbang.org/resource/image/a0/4d/a0e6f8ca0f9c5727f554323a26a9c14d.jpg?wh=1843%2A394)

## 本地套接字概述

本地套接字一般也叫做UNIX域套接字，最新的规范已经改叫本地套接字。在前面的TCP/UDP例子中，我们经常使用127.0.0.1完成客户端进程和服务器端进程同时在本机上的通信，那么，这里的本地套接字又是什么呢？

本地套接字是一种特殊类型的套接字，和TCP/UDP套接字不同。TCP/UDP即使在本地地址通信，也要走系统网络协议栈，而本地套接字，严格意义上说提供了一种单主机跨进程间调用的手段，减少了协议栈实现的复杂度，效率比TCP/UDP套接字都要高许多。类似的IPC机制还有UNIX管道、共享内存和RPC调用等。

比如X Window实现，如果发现是本地连接，就会走本地套接字，工作效率非常高。

现在你可以回忆一下，在前面介绍套接字地址时，我们讲到了本地地址，这个本地地址就是本地套接字专属的。

![](https://static001.geekbang.org/resource/image/ed/58/ed49b0f1b658e82cb07a6e1e81f36b58.png?wh=3979%2A3770)

## 本地字节流套接字

我们先从字节流本地套接字开始。

这是一个字节流类型的本地套接字服务器端例子。在这个例子中，服务器程序打开本地套接字后，接收客户端发送来的字节流，并往客户端回送了新的字节流。

```
#include  "lib/common.h"

int main(int argc, char **argv) {
    if (argc != 2) {
        error(1, 0, "usage: unixstreamserver <local_path>");
    }

    int listenfd, connfd;
    socklen_t clilen;
    struct sockaddr_un cliaddr, servaddr;

    listenfd = socket(AF_LOCAL, SOCK_STREAM, 0);
    if (listenfd < 0) {
        error(1, errno, "socket create failed");
    }

    char *local_path = argv[1];
    unlink(local_path);
    bzero(&servaddr, sizeof(servaddr));
    servaddr.sun_family = AF_LOCAL;
    strcpy(servaddr.sun_path, local_path);

    if (bind(listenfd, (struct sockaddr *) &servaddr, sizeof(servaddr)) < 0) {
        error(1, errno, "bind failed");
    }

    if (listen(listenfd, LISTENQ) < 0) {
        error(1, errno, "listen failed");
    }

    clilen = sizeof(cliaddr);
    if ((connfd = accept(listenfd, (struct sockaddr *) &cliaddr, &clilen)) < 0) {
        if (errno == EINTR)
            error(1, errno, "accept failed");        /* back to for() */
        else
            error(1, errno, "accept failed");
    }

    char buf[BUFFER_SIZE];

    while (1) {
        bzero(buf, sizeof(buf));
        if (read(connfd, buf, BUFFER_SIZE) == 0) {
            printf("client quit");
            break;
        }
        printf("Receive: %s", buf);

        char send_line[MAXLINE];
        sprintf(send_line, "Hi, %s", buf);

        int nbytes = sizeof(send_line);

        if (write(connfd, send_line, nbytes) != nbytes)
            error(1, errno, "write error");
    }

    close(listenfd);
    close(connfd);

    exit(0);

}
```

我对这个程序做一个详细的解释：

- 第12～15行非常关键，**这里创建的套接字类型，注意是AF\_LOCAL，并且使用字节流格式**。你现在可以回忆一下，TCP的类型是AF\_INET和字节流类型；UDP的类型是AF\_INET和数据报类型。在前面的文章中，我们提到AF\_UNIX也是可以的，基本上可以认为和AF\_LOCAL是等价的。
- 第17～21行创建了一个本地地址，这里的本地地址和IPv4、IPv6地址可以对应，数据类型为sockaddr\_un，这个数据类型中的sun\_family需要填写为AF\_LOCAL，最为关键的是需要对sun\_path设置一个本地文件路径。我们这里还做了一个unlink操作，以便把存在的文件删除掉，这样可以保持幂等性。
- 第23～29行，分别执行bind和listen操作，这样就监听在一个本地文件路径标识的套接字上，这和普通的TCP服务端程序没什么区别。
- 第41～56行，使用read和write函数从套接字中按照字节流的方式读取和发送数据。

我在这里着重强调一下本地文件路径。关于本地文件路径，需要明确一点，它必须是“绝对路径”，这样的话，编写好的程序可以在任何目录里被启动和管理。如果是“相对路径”，为了保持同样的目的，这个程序的启动路径就必须固定，这样一来，对程序的管理反而是一个很大的负担。

另外还要明确一点，这个本地文件，必须是一个“文件”，不能是一个“目录”。如果文件不存在，后面bind操作时会自动创建这个文件。

还有一点需要牢记，在Linux下，任何文件操作都有权限的概念，应用程序启动时也有应用属主。如果当前启动程序的用户权限不能创建文件，你猜猜会发生什么呢？这里我先卖个关子，一会演示的时候你就会看到结果。

下面我们再看一下客户端程序。

```
#include "lib/common.h"

int main(int argc, char **argv) {
    if (argc != 2) {
        error(1, 0, "usage: unixstreamclient <local_path>");
    }

    int sockfd;
    struct sockaddr_un servaddr;

    sockfd = socket(AF_LOCAL, SOCK_STREAM, 0);
    if (sockfd < 0) {
        error(1, errno, "create socket failed");
    }

    bzero(&servaddr, sizeof(servaddr));
    servaddr.sun_family = AF_LOCAL;
    strcpy(servaddr.sun_path, argv[1]);

    if (connect(sockfd, (struct sockaddr *) &servaddr, sizeof(servaddr)) < 0) {
        error(1, errno, "connect failed");
    }

    char send_line[MAXLINE];
    bzero(send_line, MAXLINE);
    char recv_line[MAXLINE];

    while (fgets(send_line, MAXLINE, stdin) != NULL) {

        int nbytes = sizeof(send_line);
        if (write(sockfd, send_line, nbytes) != nbytes)
            error(1, errno, "write error");

        if (read(sockfd, recv_line, MAXLINE) == 0)
            error(1, errno, "server terminated prematurely");

        fputs(recv_line, stdout);
    }

    exit(0);
}
```

下面我带大家理解一下这个客户端程序。

- 11～14行创建了一个本地套接字，和前面服务器端程序一样，用的也是字节流类型SOCK\_STREAM。
- 16～18行初始化目标服务器端的地址。我们知道在TCP编程中，使用的是服务器的IP地址和端口作为目标，在本地套接字中则使用文件路径作为目标标识，sun\_path这个字段标识的是目标文件路径，所以这里需要对sun\_path进行初始化。
- 20行和TCP客户端一样，发起对目标套接字的connect调用，不过由于是本地套接字，并不会有三次握手。
- 28～38行从标准输入中读取字符串，向服务器端发送，之后将服务器端传输过来的字符打印到标准输出上。

总体上，我们可以看到，本地字节流套接字和TCP服务器端、客户端编程最大的差异就是套接字类型的不同。本地字节流套接字识别服务器不再通过IP地址和端口，而是通过本地文件。

接下来，我们就运行这个程序来加深对此的理解。

### 只启动客户端

第一个场景中，我们只启动客户端程序：

```
$ ./unixstreamclient /tmp/unixstream.sock
connect failed: No such file or directory (2)
```

我们看到，由于没有启动服务器端，没有一个本地套接字在/tmp/unixstream.sock这个文件上监听，客户端直接报错，提示我们没有文件存在。

### 服务器端监听在无权限的文件路径上

还记得我们在前面卖的关子吗？在Linux下，执行任何应用程序都有应用属主的概念。在这里，我们让服务器端程序的应用属主没有/var/lib/目录的权限，然后试着启动一下这个服务器程序 ：

```
$ ./unixstreamserver /var/lib/unixstream.sock
bind failed: Permission denied (13)
```

这个结果告诉我们启动服务器端程序的用户，必须对本地监听路径有权限。这个结果和你期望的一致吗？

试一下root用户启动该程序：

```
sudo ./unixstreamserver /var/lib/unixstream.sock
(阻塞运行中)
```

我们看到，服务器端程序正常运行了。

打开另外一个shell，我们看到/var/lib下创建了一个本地文件，大小为0，而且文件的最后结尾有一个（=）号。其实这就是bind的时候自动创建出来的文件。

```
$ ls -al /var/lib/unixstream.sock
rwxr-xr-x 1 root root 0 Jul 15 12:41 /var/lib/unixstream.sock=
```

如果我们使用netstat命令查看UNIX域套接字，就会发现unixstreamserver这个进程，监听在/var/lib/unixstream.sock这个文件路径上。

![](https://static001.geekbang.org/resource/image/58/b1/58d259d15b7012645d168a9c5d9f3fb1.jpg?wh=2369%2A334)  
看看，很简单吧，我们写的程序和鼎鼎大名的Kubernetes运行在同一机器上，原理和行为完全一致。

### 服务器-客户端应答

现在，我们让服务器和客户端都正常启动，并且客户端依次发送字符：

```
$./unixstreamserver /tmp/unixstream.sock
Receive: g1
Receive: g2
Receive: g3
client quit
```

```
$./unixstreamclient /tmp/unixstream.sock
g1
Hi, g1
g2
Hi, g2
g3
Hi, g3
^C
```

我们可以看到，服务器端陆续收到客户端发送的字节，同时，客户端也收到了服务器端的应答；最后，当我们使用Ctrl+C，让客户端程序退出时，服务器端也正常退出。

## 本地数据报套接字

我们再来看下在本地套接字上使用数据报的服务器端例子：

```
#include  "lib/common.h"

int main(int argc, char **argv) {
    if (argc != 2) {
        error(1, 0, "usage: unixdataserver <local_path>");
    }

    int socket_fd;
    socket_fd = socket(AF_LOCAL, SOCK_DGRAM, 0);
    if (socket_fd < 0) {
        error(1, errno, "socket create failed");
    }

    struct sockaddr_un servaddr;
    char *local_path = argv[1];
    unlink(local_path);
    bzero(&servaddr, sizeof(servaddr));
    servaddr.sun_family = AF_LOCAL;
    strcpy(servaddr.sun_path, local_path);

    if (bind(socket_fd, (struct sockaddr *) &servaddr, sizeof(servaddr)) < 0) {
        error(1, errno, "bind failed");
    }

    char buf[BUFFER_SIZE];
    struct sockaddr_un client_addr;
    socklen_t client_len = sizeof(client_addr);
    while (1) {
        bzero(buf, sizeof(buf));
        if (recvfrom(socket_fd, buf, BUFFER_SIZE, 0, (struct sockadd *) &client_addr, &client_len) == 0) {
            printf("client quit");
            break;
        }
        printf("Receive: %s \n", buf);

        char send_line[MAXLINE];
        bzero(send_line, MAXLINE);
        sprintf(send_line, "Hi, %s", buf);

        size_t nbytes = strlen(send_line);
        printf("now sending: %s \n", send_line);

        if (sendto(socket_fd, send_line, nbytes, 0, (struct sockadd *) &client_addr, client_len) != nbytes)
            error(1, errno, "sendto error");
    }

    close(socket_fd);

    exit(0);
}
```

本地数据报套接字和前面的字节流本地套接字有以下几点不同：

- 第9行创建的本地套接字，**这里创建的套接字类型，注意是AF\_LOCAL**，协议类型为SOCK\_DGRAM。
- 21～23行bind到本地地址之后，没有再调用listen和accept，回忆一下，这其实和UDP的性质一样。
- 28～45行使用recvfrom和sendto来进行数据报的收发，不再是read和send，这其实也和UDP网络程序一致。

然后我们再看一下客户端的例子：

```
#include "lib/common.h"

int main(int argc, char **argv) {
    if (argc != 2) {
        error(1, 0, "usage: unixdataclient <local_path>");
    }

    int sockfd;
    struct sockaddr_un client_addr, server_addr;

    sockfd = socket(AF_LOCAL, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        error(1, errno, "create socket failed");
    }

    bzero(&client_addr, sizeof(client_addr));        /* bind an address for us */
    client_addr.sun_family = AF_LOCAL;
    strcpy(client_addr.sun_path, tmpnam(NULL));

    if (bind(sockfd, (struct sockaddr *) &client_addr, sizeof(client_addr)) < 0) {
        error(1, errno, "bind failed");
    }

    bzero(&server_addr, sizeof(server_addr));
    server_addr.sun_family = AF_LOCAL;
    strcpy(server_addr.sun_path, argv[1]);

    char send_line[MAXLINE];
    bzero(send_line, MAXLINE);
    char recv_line[MAXLINE];

    while (fgets(send_line, MAXLINE, stdin) != NULL) {
        int i = strlen(send_line);
        if (send_line[i - 1] == '\n') {
            send_line[i - 1] = 0;
        }
        size_t nbytes = strlen(send_line);
        printf("now sending %s \n", send_line);

        if (sendto(sockfd, send_line, nbytes, 0, (struct sockaddr *) &server_addr, sizeof(server_addr)) != nbytes)
            error(1, errno, "sendto error");

        int n = recvfrom(sockfd, recv_line, MAXLINE, 0, NULL, NULL);
        recv_line[n] = 0;

        fputs(recv_line, stdout);
        fputs("\n", stdout);
    }

    exit(0);
}
```

这个程序和UDP网络编程的例子基本是一致的，我们可以把它当作是用本地文件替换了IP地址和端口的UDP程序，不过，这里还是有一个非常大的不同的。

这个不同点就在16～22行。你可以看到16～22行将本地套接字bind到本地一个路径上，然而UDP客户端程序是不需要这么做的。本地数据报套接字这么做的原因是，它需要指定一个本地路径，以便在服务器端回包时，可以正确地找到地址；而在UDP客户端程序里，数据是可以通过UDP包的本地地址和端口来匹配的。

下面这段代码就展示了服务器端和客户端通过数据报应答的场景：

```
 ./unixdataserver /tmp/unixdata.sock
Receive: g1
now sending: Hi, g1
Receive: g2
now sending: Hi, g2
Receive: g3
now sending: Hi, g3
```

```
$ ./unixdataclient /tmp/unixdata.sock
g1
now sending g1
Hi, g1
g2
now sending g2
Hi, g2
g3
now sending g3
Hi, g3
^C
```

我们可以看到，服务器端陆续收到客户端发送的数据报，同时，客户端也收到了服务器端的应答。

## 总结

我在开头已经说过，本地套接字作为常用的进程间通信技术，被用于各种适用于在同一台主机上进程间通信的场景。关于本地套接字，我们需要牢记以下两点：

- 本地套接字的编程接口和IPv4、IPv6套接字编程接口是一致的，可以支持字节流和数据报两种协议。
- 本地套接字的实现效率大大高于IPv4和IPv6的字节流、数据报套接字实现。

## 思考题

讲完本地套接字之后，我给你留几道思考题。

1. 在本地套接字字节流类型的客户端-服务器例子中，我们让服务器端以root账号启动，监听在/var/lib/unixstream.sock这个文件上。如果我们让客户端以普通用户权限启动，客户端可以连接上/var/lib/unixstream.sock吗？为什么呢？
2. 我们看到客户端被杀死后，服务器端也正常退出了。看下退出后打印的日志，你不妨判断一下引起服务器端正常退出的逻辑是什么？
3. 你有没有想过这样一个奇怪的场景：如果自己不小心写错了代码，本地套接字服务器端是SOCK\_DGRAM，客户端使用的是SOCK\_STREAM，路径和其他都是正确的，你觉得会发生什么呢？

欢迎你在评论区写下你的思考，我会和你一起交流这些问题。如果这篇文章帮你弄懂了本地套接字，不妨把它分享给你的朋友或者同事，一起交流一下它吧！
<div><strong>精选留言（15）</strong></div><ul>
<li><span>supermouse</span> 👍（96） 💬（6）<p>问题一：连接不上。错误提示是“Permission denied”

问题二：在服务端的代码中，对收到的客户端发送的数据长度做了判断，如果长度为0，则主动关闭服务端程序。这是杀死客户端后引发服务端关闭的原因。这也说明客户端在被强行终止的时候，会最后向服务端发送一条空消息，告知服务器自己这边的程序关闭了。

问题三：客户端在连接时会报错，错误提示是“Protocol wrong type for socket (91)”</p>2019-11-03</li><br/><li><span>GeekAmI</span> 👍（23） 💬（2）<p>问题1：
$ sudo .&#47;unixstreamserver &#47;var&#47;lib&#47;unixstream.sock

$ .&#47;unixstreamclient &#47;var&#47;lib&#47;unixstream.sock
connect failed: Permission denied (13)

问题2：
client: Ctrl + C -&gt; exit(0) -&gt; 发送FIN包；
server:满足条件read(connfd, buf, BUFFER_SIZE) == 0，结束。

问题3：
$ .&#47;unixdataserver &#47;tmp&#47;unixdata.sock

$ .&#47;unixstreamclient &#47;tmp&#47;unixdata.sock
connect failed: Protocol wrong type for socket (41)</p>2019-10-17</li><br/><li><span>衬衫的价格是19美元</span> 👍（20） 💬（1）<p>为什么AF_LOCAL+DGRAM的时候,客户端需要bind一个本地文件？
因为服务器收到来自客户端的数据想要给客户端回复的时候，需要知道发给谁。在其他情况下，服务器都有办法：
1.当使用STREAM时，不管是AF_INET还是AF_LOCAL, 都有连接的概念，所以服务器可以使用原来的连接
2.当使用AF_INET时，不管是DGRAM还是STREAM, 都能知道对方的ip+port, 也能确定一个唯一的进程
只有AF_LOCAL+DGRAM的时候，没有连接，也没有ip_+port,   只能显式的指定一个标志告诉服务端
</p>2020-06-26</li><br/><li><span>15652790052</span> 👍（6） 💬（1）<p>1.sock文件具体内容什么呢，为什么需要sock文件？
2.本地套接字底层时怎么实现的呢？
3.为什么没有了端口的概念？</p>2019-08-29</li><br/><li><span>奕</span> 👍（6） 💬（5）<p>文章中说 TCP 和 UDP 的scoket 通讯 是走网络协议的，本地socket 通讯减少了网络协议的实现，是说明本地scoket通讯一点都不走网络协议吗？ 还是会走其中的一部分网络协议？ 

如果本地 socket 通讯不走网络协议，那通讯的标准是什么呢？ 只是对 socket 文件的读写操作吗？</p>2019-08-17</li><br/><li><span>Sylar.</span> 👍（6） 💬（1）<p>老师您好，方便把全部代码放git吗，因为示例缺少依赖</p>2019-08-17</li><br/><li><span>J.M.Liu</span> 👍（3） 💬（1）<p>datagram client中，为什么还要bind一个本地地址呀？没有看出这个这个本地地址有什么用呀。难道它是用来作为接受数据的缓冲区的吗？好像没有它也并不影响数据收发，换句话说，client_addr.sun_path填什么好像都无所谓啊。</p>2019-08-30</li><br/><li><span>刘丹</span> 👍（3） 💬（3）<p>请问老师本地套接字是否支持一对多、多对多通信？</p>2019-08-16</li><br/><li><span>重小楼不吃素</span> 👍（2） 💬（2）<p>老师你好，我在讨论区看到“一对多，多对多通信”这样的概念，有点不明白。请问一对多指的是建立一个套接字可以允许多个客户端连接的意思吗？  如果是的话，本地套接字的 SOCK_STREAM 方式也能一对多呀，老师为什么只提到 SOCK_DGRAM 可以？
问题二：
TCP\UDP\本地套接字 是否都有发送缓冲区、接收缓冲区，TCP的发送&#47;接收缓冲区很好理解，其余两个我没有查找到说得比较透彻的资料</p>2020-08-24</li><br/><li><span>蚂蚁哈哈哈</span> 👍（1） 💬（1）<p>答案：
问题1: 客户端报错： &quot;connect failed: Permission denied&quot;
问题2:  下面这段代码中 == 0 的代码表示的就是客户端推出，这时候服务端打印 &quot;client quit&quot;, 然后推出 read 循环，关闭服务端程序。

`if (read(connfd, buf, BUFFER_SIZE) == 0) {
      printf(&quot;client quit&quot;);
      break;
    }`

问题三： 客户端报错 &quot;connect failed: Protocol wrong type for socket&quot;</p>2021-01-30</li><br/><li><span>夏雨</span> 👍（1） 💬（2）<p>既然是本地套接字不走网路协议， 那本地套接字的TCP 和 UDP 又有什么去别， UDP在缓存里也不会丢包乱序。</p>2020-06-24</li><br/><li><span>郑祖煌</span> 👍（1） 💬（1）<p>这边举例的本地套接字是一个服务器对应着一个客户端。 那想问一下能不能一个服务器对应着多个客户端。如果对应的多个客户端，他们还是通过一个文件就可以进行通信？ 还是要设置说一对关系要通过一个文件进行通信？</p>2020-06-12</li><br/><li><span>HunterYuan</span> 👍（1） 💬（1）<p>对于第二个问题，第五讲已进行了充分说明：read 函数要求操作系统内核从套接字描述字 socketfd读取最多多少个字节（size），并将结果存储到 buffer 中。返回值告诉我们实际读取的字节数目，也有一些特殊情况，如果返回值为 0，表示 EOF（end-of-file），这在网络中表示对端发送了 FIN 包，要处理断连的情况。
也就是说，只有流方式会遇到这种情况：
client: Ctrl + C -&gt; exit(0) -&gt; 发送FIN包；
server:满足条件read(connfd, buf, BUFFER_SIZE) == 0，结束。</p>2019-11-28</li><br/><li><span>Kepler</span> 👍（1） 💬（1）<p>lib&#47;common.h 的绝对路径是啥，有这个文件吗？</p>2019-09-22</li><br/><li><span>knull</span> 👍（1） 💬（2）<p>老师，你好，我练习写了一个echoserver（用AF_UNIX）,客户端主动断链。
发现在客户端close的时候，echoserver会读取到数据，并且最后一次write。但是，这个时候连接已经断了，会报错broken pipe。程序直接挂掉了。。。
这种情况该怎么处理呢？</p>2019-08-26</li><br/>
</ul>