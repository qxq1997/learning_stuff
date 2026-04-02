你好，我是蒋德钧。

Redis作为一个Client-Server架构的数据库，其源码中少不了用来实现网络通信的部分。而你应该也清楚，通常系统实现网络通信的基本方法是**使用Socket编程模型**，包括创建Socket、监听端口、处理连接请求和读写请求。但是，由于基本的Socket编程模型一次只能处理一个客户端连接上的请求，所以当要处理高并发请求时，一种方案就是使用多线程，让每个线程负责处理一个客户端的请求。

而Redis负责客户端请求解析和处理的线程只有一个，那么如果直接采用基本Socket模型，就会影响Redis支持高并发的客户端访问。

因此，为了实现高并发的网络通信，我们常用的Linux操作系统，就提供了select、poll和epoll三种编程模型，而在Linux上运行的Redis，通常就会采用其中的**epoll模型**来进行网络通信。

这里你可能就要问了：**为啥Redis通常会选择epoll模型呢？这三种编程模型之间有什么区别？**如果我们自己要开发高并发的服务器处理程序时，应该如何选择使用呢？

今天这节课，我就来和你聊聊，Redis在高并发网络通信编程模型上的选择和设计思想。通过这节课的学习，你可以掌握select、poll和epoll三种模型的工作机制和使用方法。了解这些内容，一方面可以帮助你理解Redis整体网络通信框架的工作基础，另一方面，也可以让你学会如何进行高并发网络通信的开发。

那么，要想理解select、poll和epoll的优势，我们需要有个对比基础，也就是基本的Socket编程模型。所以接下来，我们就先来了解下基本的Socket编程模型，以及它的不足之处。

## 为什么Redis不使用基本的Socket编程模型？

刚刚我们说过，使用Socket模型实现网络通信时，需要经过创建Socket、监听端口、处理连接和读写请求等多个步骤，现在我们就来具体了解下这些步骤中的关键操作，以此帮助我们分析Socket模型中的不足。

首先，当我们需要让服务器端和客户端进行通信时，可以在服务器端通过以下三步，来创建监听客户端连接的监听套接字（Listening Socket）：

1. 调用socket函数，创建一个套接字。我们通常把这个套接字称为主动套接字（Active Socket）；
2. 调用bind函数，将主动套接字和当前服务器的IP和监听端口进行绑定；
3. 调用listen函数，将主动套接字转换为监听套接字，开始监听客户端的连接。

![](https://static001.geekbang.org/resource/image/ea/05/eaf5b29b824994a6e9e3bc5bfdeb1a05.jpg?wh=1631x604)

在完成上述三步之后，服务器端就可以接收客户端的连接请求了。为了能及时地收到客户端的连接请求，我们可以运行一个循环流程，在该流程中调用accept函数，用于接收客户端连接请求。

这里你需要注意的是，accept函数是阻塞函数，也就是说，如果此时一直没有客户端连接请求，那么，服务器端的执行流程会一直阻塞在accept函数。一旦有客户端连接请求到达，accept将不再阻塞，而是处理连接请求，和客户端建立连接，并返回已连接套接字（Connected Socket）。

最后，服务器端可以通过调用recv或send函数，在刚才返回的已连接套接字上，接收并处理读写请求，或是将数据发送给客户端。

下面的代码展示了这一过程，你可以看下。

```
listenSocket = socket(); //调用socket系统调用创建一个主动套接字
bind(listenSocket);  //绑定地址和端口
listen(listenSocket); //将默认的主动套接字转换为服务器使用的被动套接字，也就是监听套接字
while (1) { //循环监听是否有客户端连接请求到来
   connSocket = accept(listenSocket); //接受客户端连接
   recv(connsocket); //从客户端读取数据，只能同时处理一个客户端
   send(connsocket); //给客户端返回数据，只能同时处理一个客户端
}
```

不过，从上述代码中，你可能会发现，虽然它能够实现服务器端和客户端之间的通信，但是程序每调用一次accept函数，只能处理一个客户端连接。因此，如果想要处理多个并发客户端的请求，我们就需要使用**多线程**的方法，来处理通过accept函数建立的多个客户端连接上的请求。

使用这种方法后，我们需要在accept函数返回已连接套接字后，创建一个线程，并将已连接套接字传递给创建的线程，由该线程负责这个连接套接字上后续的数据读写。同时，服务器端的执行流程会再次调用accept函数，等待下一个客户端连接。

以下给出的示例代码，就展示了使用多线程来提升服务器端的并发客户端处理能力：

```
listenSocket = socket(); //调用socket系统调用创建一个主动套接字
bind(listenSocket);  //绑定地址和端口
listen(listenSocket); //将默认的主动套接字转换为服务器使用的被动套接字，即监听套接字
while (1) { //循环监听是否有客户端连接到来
   connSocket = accept(listenSocket); //接受客户端连接，返回已连接套接字
   pthread_create(processData, connSocket); //创建新线程对已连接套接字进行处理
   
}

//处理已连接套接字上的读写请求
processData(connSocket){
   recv(connsocket); //从客户端读取数据，只能同时处理一个客户端
   send(connsocket); //给客户端返回数据，只能同时处理一个客户端
}
```

不过，虽然这种方法能提升服务器端的并发处理能力，遗憾的是，**Redis的主执行流程是由一个线程在执行，无法使用多线程的方式来提升并发处理能力。**所以，该方法对Redis并不起作用。

那么，还有没有什么其他方法，能帮助Redis提升并发客户端的处理能力呢？

这就要用到操作系统提供的**IO多路复用功能**了。在基本的Socket编程模型中，accept函数只能在一个监听套接字上监听客户端的连接，recv函数也只能在一个已连接套接字上，等待客户端发送的请求。

而IO多路复用机制，可以让程序通过调用多路复用函数，同时监听多个套接字上的请求。这里既可以包括监听套接字上的连接请求，也可以包括已连接套接字上的读写请求。这样当有一个或多个套接字上有请求时，多路复用函数就会返回。此时，程序就可以处理这些就绪套接字上的请求，比如读取就绪的已连接套接字上的请求内容。

因为Linux操作系统在实际应用中比较广泛，所以这节课，我们主要来学习Linux上的IO多路复用机制。Linux提供的IO多路复用机制主要有三种，分别是select、poll和epoll。下面，我们就分别来学习下这三种机制的实现思路和使用方法。然后，我们再来看看，为什么Redis通常是选择使用epoll这种机制来实现网络通信。

## 使用select和poll机制实现IO多路复用

首先，我们来了解下select机制的编程模型。

不过在具体学习之前，我们需要知道，对于一种IO多路复用机制来说，我们需要掌握哪些要点，这样可以帮助我们快速抓住不同机制的联系与区别。其实，当我们学习IO多路复用机制时，我们需要能回答以下问题：

- 第一，多路复用机制会监听套接字上的哪些事件？
- 第二，多路复用机制可以监听多少个套接字？
- 第三，当有套接字就绪时，多路复用机制要如何找到就绪的套接字？

### select机制与使用

select机制中的一个重要函数就是select函数。对于select函数来说，它的参数包括监听的文件描述符数量`__nfds`、被监听描述符的三个集合`*__readfds`、`*__writefds`和`*__exceptfds`，以及监听时阻塞等待的超时时长`*__timeout`。下面的代码显示了select函数的原型，你可以看下。

```
int select (int __nfds, fd_set *__readfds, fd_set *__writefds, fd_set *__exceptfds, struct timeval *__timeout)
```

这里你需要注意的是，Linux针对每一个套接字都会有一个文件描述符，也就是一个非负整数，用来唯一标识该套接字。所以，在多路复用机制的函数中，Linux通常会用文件描述符作为参数。有了文件描述符，函数也就能找到对应的套接字，进而进行监听、读写等操作。

所以，select函数的参数`__readfds`、`__writefds`和`__exceptfds`表示的是，被监听描述符的集合，其实就是被监听套接字的集合。那么，为什么会有三个集合呢？

这就和我刚才提出的第一个问题相关，也就是**多路复用机制会监听哪些事件**。select函数使用三个集合，表示监听的三类事件，分别是读数据事件（对应`__readfds`集合）、写数据事件（对应`__writefds`集合）和异常事件（对应`__exceptfds`集合）。

我们进一步可以看到，参数\_\_readfds、\_\_writefds和\_\_exceptfds的类型是fd\_set结构体，它主要定义部分如下所示。其中，`__fd_mask`类型是long int类型的别名，\_\_FD\_SETSIZE和\_\_NFDBITS这两个宏定义的大小默认为1024和32。

```
typedef struct {
   …
   __fd_mask  __fds_bits[__FD_SETSIZE / __NFDBITS];
   …
} fd_set
```

所以，fd\_set结构体的定义，其实就是一个long int类型的数组，该数组中一共有32个元素（1024/32=32），每个元素是32位（long int类型的大小），而每一位可以用来表示一个文件描述符的状态。

好了，了解了fd\_set结构体的定义，我们就可以回答刚才提出的第二个问题了。select函数对每一个描述符集合，都可以监听1024个描述符。

接下来，我们再来了解下**如何使用select机制来实现网络通信**。

首先，我们在调用select函数前，可以先创建好传递给select函数的描述符集合，然后再创建监听套接字。而为了让创建的监听套接字能被select函数监控，我们需要把这个套接字的描述符加入到创建好的描述符集合中。

然后，我们就可以调用select函数，并把创建好的描述符集合作为参数传递给select函数。程序在调用select函数后，会发生阻塞。而当select函数检测到有描述符就绪后，就会结束阻塞，并返回就绪的文件描述符个数。

那么此时，我们就可以在描述符集合中查找哪些描述符就绪了。然后，我们对已就绪描述符对应的套接字进行处理。比如，如果是\_\_readfds集合中有描述符就绪，这就表明这些就绪描述符对应的套接字上，有读事件发生，此时，我们就在该套接字上读取数据。

而因为select函数一次可以监听1024个文件描述符的状态，所以select函数在返回时，也可能会一次返回多个就绪的文件描述符。这样一来，我们就可以使用一个循环流程，依次对就绪描述符对应的套接字进行读写或异常处理操作。

我也画了张图，展示了使用select函数进行网络通信的基本流程，你可以看下。

![](https://static001.geekbang.org/resource/image/49/9f/49b513c6b9f9a440e8883ff93b33b49f.jpg?wh=2000x1125)

下面的代码展示的是使用select函数，进行并发客户端处理的关键步骤和主要函数调用：

```
int sock_fd,conn_fd; //监听套接字和已连接套接字的变量
sock_fd = socket() //创建套接字
bind(sock_fd)   //绑定套接字
listen(sock_fd) //在套接字上进行监听，将套接字转为监听套接字

fd_set rset;  //被监听的描述符集合，关注描述符上的读事件
 
int max_fd = sock_fd

//初始化rset数组，使用FD_ZERO宏设置每个元素为0 
FD_ZERO(&rset);
//使用FD_SET宏设置rset数组中位置为sock_fd的文件描述符为1，表示需要监听该文件描述符
FD_SET(sock_fd,&rset);

//设置超时时间 
struct timeval timeout;
timeout.tv_sec = 3;
timeout.tv_usec = 0;
 
while(1) {
   //调用select函数，检测rset数组保存的文件描述符是否已有读事件就绪，返回就绪的文件描述符个数
   n = select(max_fd+1, &rset, NULL, NULL, &timeout);
 
   //调用FD_ISSET宏，在rset数组中检测sock_fd对应的文件描述符是否就绪
   if (FD_ISSET(sock_fd, &rset)) {
       //如果sock_fd已经就绪，表明已有客户端连接；调用accept函数建立连接
       conn_fd = accept();
       //设置rset数组中位置为conn_fd的文件描述符为1，表示需要监听该文件描述符
       FD_SET(conn_fd, &rset);
   }

   //依次检查已连接套接字的文件描述符
   for (i = 0; i < maxfd; i++) {
        //调用FD_ISSET宏，在rset数组中检测文件描述符是否就绪
       if (FD_ISSET(i, &rset)) {
         //有数据可读，进行读数据处理
       }
   }
}
```

不过从刚才的介绍中，你或许会发现select函数存在**两个设计上的不足**：

- 首先，select函数对单个进程能监听的文件描述符数量是有限制的，它能监听的文件描述符个数由\_\_FD\_SETSIZE决定，默认值是1024。
- 其次，当select函数返回后，我们需要遍历描述符集合，才能找到具体是哪些描述符就绪了。这个遍历过程会产生一定开销，从而降低程序的性能。

所以，为了解决select函数受限于1024个文件描述符的不足，poll函数对此做了改进。

### poll机制与使用

poll机制的主要函数是poll函数，我们先来看下它的原型定义，如下所示：

```
int poll (struct pollfd *__fds, nfds_t __nfds, int __timeout);
```

其中，参数\*\_\_fds是pollfd结构体数组，参数\_\_nfds表示的是\*\_\_fds数组的元素个数，而\_\_timeout表示poll函数阻塞的超时时间。

pollfd结构体里包含了要监听的描述符，以及该描述符上要监听的事件类型。这个我们可以从pollfd结构体的定义中看出来，如下所示。pollfd结构体中包含了三个成员变量fd、events和revents，分别表示要监听的文件描述符、要监听的事件类型和实际发生的事件类型。

```
struct pollfd {
    int fd;         //进行监听的文件描述符
    short int events;       //要监听的事件类型
    short int revents;      //实际发生的事件类型
};
```

pollfd结构体中要监听和实际发生的事件类型，是通过以下三个宏定义来表示的，分别是POLLRDNORM、POLLWRNORM和POLLERR，它们分别表示可读、可写和错误事件。

```
#define POLLRDNORM  0x040       //可读事件
#define POLLWRNORM  0x100       //可写事件
#define POLLERR     0x008       //错误事件
```

好了，了解了poll函数的参数后，我们来看下如何使用poll函数完成网络通信。这个流程主要可以分成三步：

- 第一步，创建pollfd数组和监听套接字，并进行绑定；
- 第二步，将监听套接字加入pollfd数组，并设置其监听读事件，也就是客户端的连接请求；
- 第三步，循环调用poll函数，检测pollfd数组中是否有就绪的文件描述符。

而在第三步的循环过程中，其处理逻辑又分成了两种情况：

- 如果是连接套接字就绪，这表明是有客户端连接，我们可以调用accept接受连接，并创建已连接套接字，并将其加入pollfd数组，并监听读事件；
- 如果是已连接套接字就绪，这表明客户端有读写请求，我们可以调用recv/send函数处理读写请求。

我画了下面这张图，展示了使用poll函数的流程，你可以学习掌握下。

![](https://static001.geekbang.org/resource/image/b1/19/b1dab536cc9509f476db2c527fdea619.jpg?wh=2000x1125)

另外，为了便于你掌握在代码中使用poll函数，我也写了一份示例代码，如下所示：

```
int sock_fd,conn_fd; //监听套接字和已连接套接字的变量
sock_fd = socket() //创建套接字
bind(sock_fd)   //绑定套接字
listen(sock_fd) //在套接字上进行监听，将套接字转为监听套接字

//poll函数可以监听的文件描述符数量，可以大于1024
#define MAX_OPEN = 2048

//pollfd结构体数组，对应文件描述符
struct pollfd client[MAX_OPEN];

//将创建的监听套接字加入pollfd数组，并监听其可读事件
client[0].fd = sock_fd;
client[0].events = POLLRDNORM; 
maxfd = 0;

//初始化client数组其他元素为-1
for (i = 1; i < MAX_OPEN; i++)
    client[i].fd = -1; 

while(1) {
   //调用poll函数，检测client数组里的文件描述符是否有就绪的，返回就绪的文件描述符个数
   n = poll(client, maxfd+1, &timeout);
   //如果监听套件字的文件描述符有可读事件，则进行处理
   if (client[0].revents & POLLRDNORM) {
       //有客户端连接；调用accept函数建立连接
       conn_fd = accept();

       //保存已建立连接套接字
       for (i = 1; i < MAX_OPEN; i++){
         if (client[i].fd < 0) {
           client[i].fd = conn_fd; //将已建立连接的文件描述符保存到client数组
           client[i].events = POLLRDNORM; //设置该文件描述符监听可读事件
           break;
          }
       }
       maxfd = i; 
   }
   
   //依次检查已连接套接字的文件描述符
   for (i = 1; i < MAX_OPEN; i++) {
       if (client[i].revents & (POLLRDNORM | POLLERR)) {
         //有数据可读或发生错误，进行读数据处理或错误处理
       }
   }
}
```

其实，和select函数相比，poll函数的改进之处主要就在于，**它允许一次监听超过1024个文件描述符**。但是当调用了poll函数后，我们仍然需要遍历每个文件描述符，检测该描述符是否就绪，然后再进行处理。

**那么，有没有办法可以避免遍历每个描述符呢？**这就是我接下来向你介绍的epoll机制。

## 使用epoll机制实现IO多路复用

首先，epoll机制是使用epoll\_event结构体，来记录待监听的文件描述符及其监听的事件类型的，这和poll机制中使用pollfd结构体比较类似。

那么，对于epoll\_event结构体来说，其中包含了epoll\_data\_t联合体变量，以及整数类型的events变量。epoll\_data\_t联合体中有记录文件描述符的成员变量fd，而events变量会取值使用不同的宏定义值，来表示epoll\_data\_t变量中的文件描述符所关注的事件类型，比如一些常见的事件类型包括以下这几种。

- EPOLLIN：读事件，表示文件描述符对应套接字有数据可读。
- EPOLLOUT：写事件，表示文件描述符对应套接字有数据要写。
- EPOLLERR：错误事件，表示文件描述符对于套接字出错。

下面的代码展示了epoll\_event结构体以及epoll\_data联合体的定义，你可以看下。

```
typedef union epoll_data
{
  ...
  int fd;  //记录文件描述符
  ...
} epoll_data_t;


struct epoll_event
{
  uint32_t events;  //epoll监听的事件类型
  epoll_data_t data; //应用程序数据
};
```

好了，现在我们知道，在使用select或poll函数的时候，创建好文件描述符集合或pollfd数组后，就可以往数组中添加我们需要监听的文件描述符。

但是对于epoll机制来说，我们则需要先调用epoll\_create函数，创建一个epoll实例。这个epoll实例内部维护了两个结构，分别是**记录要监听的文件描述符**和**已经就绪的文件描述符**，而对于已经就绪的文件描述符来说，它们会被返回给用户程序进行处理。

所以，我们在使用epoll机制时，就不用像使用select和poll一样，遍历查询哪些文件描述符已经就绪了。这样一来， epoll的效率就比select和poll有了更高的提升。

在创建了epoll实例后，我们需要再使用epoll\_ctl函数，给被监听的文件描述符添加监听事件类型，以及使用epoll\_wait函数获取就绪的文件描述符。

我画了一张图，展示了使用epoll进行网络通信的流程，你可以看下。

![](https://static001.geekbang.org/resource/image/1e/fb/1ee730305558d9d83ff8e52eb4d966fb.jpg?wh=2000x1050)

下面的代码展示了使用epoll函数的流程，你也可以看下。

```
int sock_fd,conn_fd; //监听套接字和已连接套接字的变量
sock_fd = socket() //创建套接字
bind(sock_fd)   //绑定套接字
listen(sock_fd) //在套接字上进行监听，将套接字转为监听套接字
    
epfd = epoll_create(EPOLL_SIZE); //创建epoll实例，
//创建epoll_event结构体数组，保存套接字对应文件描述符和监听事件类型    
ep_events = (epoll_event*)malloc(sizeof(epoll_event) * EPOLL_SIZE);

//创建epoll_event变量
struct epoll_event ee
//监听读事件
ee.events = EPOLLIN;
//监听的文件描述符是刚创建的监听套接字
ee.data.fd = sock_fd;

//将监听套接字加入到监听列表中    
epoll_ctl(epfd, EPOLL_CTL_ADD, sock_fd, &ee); 
    
while (1) {
   //等待返回已经就绪的描述符 
   n = epoll_wait(epfd, ep_events, EPOLL_SIZE, -1); 
   //遍历所有就绪的描述符     
   for (int i = 0; i < n; i++) {
       //如果是监听套接字描述符就绪，表明有一个新客户端连接到来 
       if (ep_events[i].data.fd == sock_fd) { 
          conn_fd = accept(sock_fd); //调用accept()建立连接
          ee.events = EPOLLIN;  
          ee.data.fd = conn_fd;
          //添加对新创建的已连接套接字描述符的监听，监听后续在已连接套接字上的读事件      
          epoll_ctl(epfd, EPOLL_CTL_ADD, conn_fd, &ee); 
                
       } else { //如果是已连接套接字描述符就绪，则可以读数据
           ...//读取数据并处理
       }
   }
}
```

好了，到这里，你就了解了epoll函数的使用方法了。实际上，也正是因为epoll能自定义监听的描述符数量，以及可以直接返回就绪的描述符，Redis在设计和实现网络通信框架时，就基于epoll机制中的epoll\_create、epoll\_ctl和epoll\_wait等函数和读写事件，进行了封装开发，实现了用于网络通信的事件驱动框架，从而使得Redis虽然是单线程运行，但是仍然能高效应对高并发的客户端访问。

## 小结

今天这节课，我给你介绍了Redis网络通信依赖的操作系统底层机制，也就是IO多路复用机制。

由于Redis是单线程程序，如果使用基本的Socket编程模型的话，只能对一个监听套接字或一个已连接套接字进行监听。而当Redis实例面临很多并发的客户端时，这种处理方式的效率就会很低。

所以，和基本的Socket通信相比，使用IO多路复用机制，就可以一次性获得就绪的多个套接字，从而避免了逐个检测套接字的开销。

这节课，我是以最常用的Linux操作系统为例，给你具体介绍了Linux系统提供的三种IO多路复用机制，分别是select、poll和epoll。这三种机制在能监听的描述符数量和查找就绪描述符的方法上是不一样的，你可以重点参考下图，来掌握它们的不同之处。这些差异，其实也决定了epoll相比于select和poll来说，效率更高，也应用更广泛。

![](https://static001.geekbang.org/resource/image/c0/5c/c04feac38f984a0c407985ec793ca95c.jpg?wh=2000x827)

最后我想说的是，虽然这节课我没有给你介绍Redis的源码，但是学习IO多路复用的机制和使用流程，其实就是掌握Redis事件驱动框架的基础。Redis的[ae\_select.c](https://github.com/redis/redis/tree/5.0/src/ae_select.c)和[ae\_epoll.c](https://github.com/redis/redis/tree/5.0/src/ae_epoll.c)文件，就分别使用了select和epoll这两种机制，实现IO多路复用。而在接下来的第10、11两节课上，我还会给分别你介绍，Redis事件驱动框架是如何基于epoll进行封装开发和运行的，以及Redis事件驱动框架的事件类型和处理方法。这样一来，你就能对Redis事件驱动框架的底层支撑、框架运行和事件类型与处理，有个全面的掌握了。

## 每课一问

在Redis事件驱动框架代码中，分别使用了Linux系统上的select和epoll两种机制，你知道为什么Redis没有使用poll这一机制吗？
<div><strong>精选留言（10）</strong></div><ul>
<li><span>Kaito</span> 👍（65） 💬（2）<p>1、单线程服务器模型，面临的最大的问题就是，一个线程如何处理多个客户端请求？解决这种问题的办法就是「IO 多路复用」。它本质上是应用层不用维护多个客户端的连接状态，而是把它们「托管」给了操作系统，操作系统维护这些连接的状态变化，之后应用层只管问操作系统，哪些 socket 有数据可读&#47;可写就好了，大大简化了应用层的复杂度

2、IO 多路复用机制要想高效使用，一般还需要把 socket 设置成「非阻塞」模式，即 socket 没有数据可读&#47;可写时，应用层去 read&#47;write socket 也不会阻塞住（内核会返回指定错误，应用层可继续重试），这样应用层就可以去处理其它业务逻辑，不会阻塞影响性能

3、为什么 Redis 要使用「单线程」处理客户端请求？本质上是因为，Redis 操作的是内存，操作内存数据是极快的，所以 Redis 的瓶颈不在 CPU，优化的重点就在网络 IO 上，高效的 IO 多路复用机制，正好可以满足这种需求，模型简单，性能也极高

4、但成也萧何败也萧何，因为 Redis 处理请求是「单线程」，所以如果有任意请求在 Server 端发生耗时（例如操作 bigkey，或一次请求数据过多），就会导致后面的请求发生「排队」，业务端就会感知到延迟增大，性能下降

5、基于此，Redis 又做了很多优化：一些耗时的操作，不再放在主线程处理，而是丢到后台线程慢慢执行。例如，异步关闭 fd，异步释放内存、后台 AOF 刷盘这些操作。所以 Redis Server 其实是「多线程」的，只不过最核心的处理请求逻辑是单线程的，这点一定要区分开

课后题：在 Redis 事件驱动框架代码中，分别使用了 Linux 系统上的 select 和 epoll 两种机制，你知道为什么 Redis 没有使用 poll 这一机制吗？

首先要明确一点，select 并不是只有 Linux 才支持的，Windows 平台也支持。

而 Redis 针对不同操作系统，会选择不同的 IO 多路复用机制来封装事件驱动框架，具体代码见 ae.c。

&#47;&#47; ae.c
#ifdef HAVE_EVPORT
#include &quot;ae_evport.c&quot;  &#47;&#47; Solaris
#else
    #ifdef HAVE_EPOLL
    #include &quot;ae_epoll.c&quot;   &#47;&#47; Linux
    #else
        #ifdef HAVE_KQUEUE
        #include &quot;ae_kqueue.c&quot;  &#47;&#47; MacOS
        #else
        #include &quot;ae_select.c&quot;  &#47;&#47; Windows
        #endif
    #endif
#endif

仔细看上面的代码逻辑，先判断了 Solaris&#47;Linux&#47;MacOS 系统，选择对应的多路复用模型，最后剩下的系统都用 select 模型。

所以我理解，select 并不是为 Linux 服务的，而是在 Windows 下使用的。

因为 epoll 性能优于 select 和 poll，所以 Linux 平台下，Redis 直接会选择 epoll。而 Windows 不支持 epoll 和 poll，所以会用 select 模型。
</p>2021-08-14</li><br/><li><span>Darren</span> 👍（33） 💬（1）<p>epoll总结如下：
epoll是在2.6内核中提出的，是之前的select和poll的增强版本。相对于select和poll来说，epoll更加灵活，没有描述符限制。epoll使用一个文件描述符管理多个描述符，将用户关系的文件描述符的事件存放到内核的一个事件表中，这样在用户空间和内核空间的copy只需一次。

int epoll_create(int size)；&#47;&#47;创建一个epoll的句柄，
int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event)；
int epoll_wait(int epfd, struct epoll_event * events, int maxevents, int timeout);


1. int epoll_create(int size);
创建一个epoll的句柄，size用来告诉内核这个监听的数目一共有多大，这个参数不同于select()中的第一个参数，给出最大监听的fd+1的值，参数size并不是限制了epoll所能监听的描述符最大个数，在2.6.8之后这个参数就没有实际价值了，因为内核维护一个动态的队列了。

当创建好epoll句柄后，它就会占用一个fd值，在linux下如果查看&#47;proc&#47;进程id&#47;fd&#47;，是能够看到这个fd的，所以在使用完epoll后，必须调用close()关闭，否则可能导致fd被耗尽。当某一进程调用epoll_create方法时，Linux内核会创建一个eventpoll结构体，这个结构体中有两个成员与epoll的使用方式密切相关。
eventpoll结构体如下所示：
struct eventpoll{
    &#47;&#47; 红黑树的根节点，这棵树中存储着所有添加到epoll中的需要监控的事件
    struct rb_root rbr;
    &#47;&#47; 双链表中则存放着将要通过epoll_wait返回给用户的满足条件的事件
    struct list_head rdlist;
    ...
}
每一个epoll对象都有一个独立的eventpoll结构体，用于存放通过epoll_ctl方法向epoll对象中添加进来的事件。这些事件都会挂载在红黑树中，如此，重复添加的事件就可以通过红黑树而高效的识别出来(红黑树的插入时间效率是lgn，其中n为树的高度)。

而所有添加到epoll中的事件都会与设备(网卡)驱动程序建立回调关系，也就是说，当相应的事件发生时会调用这个回调方法。这个回调方法在内核中叫ep_poll_callback,它会将发生的事件添加到rdlist双链表中。
2. int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event)；

函数是对指定描述符fd执行op操作。

用于向内核注册新的描述符或者是改变某个文件描述符的状态。已注册的描述符在内核中会被维护在一棵红黑树上

epfd：是epoll_create()的返回值。
op：表示op操作，用三个宏来表示：添加EPOLL_CTL_ADD，删除EPOLL_CTL_DEL，修改EPOLL_CTL_MOD。分别添加、删除和修改对fd的监听事件。
fd：是需要监听的fd（文件描述符）
epoll_event：是告诉内核需要监听什么事。

当调用epoll_wait检查是否有事件发生时，只需要检查eventpoll对象中的rdlist双链表中是否有epitem元素即可。如果rdlist不为空，则把发生的事件复制到用户态，同时将事件数量返回给用户 。

3.int epoll_wait(int epfd, struct epoll_event * events, int maxevents, int timeout);

等待epfd上的io事件，最多返回maxevents个事件。
通过回调函数内核会将 I&#47;O 准备好的描述符添加到rdlist双链表管理，进程调用 epoll_wait() 便可以得到事件完成的描述符。
参数events用来从内核得到事件的集合，maxevents告之内核这个events有多大，参数timeout是超时时间（毫秒，正整数时间，0是非阻塞，-1永久阻塞直到事件发生）。该函数返回需要处理的事件数目，如返回0表示已超时。

当然epoll对文件描述符的操作有两种模式：LT (level trigger)（默认）和ET (edge trigger)。LT模式是默认模式。</p>2021-08-17</li><br/><li><span>Darren</span> 👍（7） 💬（0）<p>select、poll总结如下：

int select (int n, fd_set *readfds, fd_set *writefds, fd_set *exceptfds, struct timeval *timeout);
select 函数监视的文件描述符分3类，分别是readfds、writefds、和exceptfds。调用后select函数会阻塞，直到有描述符就绪（有数据 可读、可写、或者有except），或者超时（timeout指定等待时间，如果立即返回设为null即可），函数返回。当select函数返回后，可以 通过遍历fdset，来找到就绪的描述符。

优点：
        select目前几乎在所有的平台(POSIX)上支持，其良好跨平台支持也是它的一个优点。
缺点：
        1、单个进程能够监视的文件描述符的数量存在最大限制，它由FD_SETSIZE设置，默认值是1024。可以通过修改宏定义甚至重新编译内核的方式提升这一限制，但是这样也会造成效率的降低。一般来说这个数目和系统内存关系很大。32位机默认是1024个。64位机默认是2048.
        2、fd集合在内核被置位过，与传入的fd集合不同，不可重用。重复进行FD_ZERO(&amp;rset); FD_SET(fds[i],&amp;rset);操作
        3、每次调⽤用select，都需要把fd集合从用户态拷贝到内核态，这个开销在fd很多时会很大。
        4、每次调用select都需要在内核遍历传递进来的所有fd标志位，O(n)的时间复杂度，这个开销在fd很多时也很大。

int poll (struct pollfd *fds, unsigned int nfds, int timeout);
不同与select使用三个位图bitmap(bit数组)来表示三个fdset的方式，poll使用一个 pollfd的指针实现。
struct pollfd {
    int fd;             &#47;* file descriptor *&#47;
    &#47;&#47;读 POLLIN; 写POLLOUT;
    short events;   &#47;* requested events to watch 要监视的event*&#47;
    short revents;  &#47;* returned events witnessed 发生的event*&#47;
};
优点：
        1、poll用pollfd数组代替了bitmap，没有最大数量限制。（解决select缺点1）
        2、利用结构体pollfd，每次置位revents字段，每次只需恢复revents即可。pollfd可重用。（解决select缺点2）
缺点：
        1、每次调⽤用poll，都需要把pollfd数组从用户态拷贝到内核态，这个开销在fd很多时会很大。（同select缺点3）
        2、和select函数一样，poll返回后，需要轮询pollfd来获取就绪的描述符。事实上，同时连接的大量客户端在一时刻可能只有很少的处于就绪状态，因此随着监视的描述符数量的增长，其效率也会线性下降。（同select缺点4）</p>2021-08-17</li><br/><li><span>可怜大灰狼</span> 👍（7） 💬（0）<p>poll相比select性能上变化不大，反而select可以运行在更多的系统上，兼容性更好。但是我记得rewrite aof的时候会用到poll。所以特意翻了下代码。aof.c中rewriteAppendOnlyFile方法调用了aeWait，aeWait里通过poll来完成阻塞时间。</p>2021-08-15</li><br/><li><span>曾轼麟</span> 👍（5） 💬（0）<p>首先回答老师的问题：为什么Redis没有使用poll这种机制？
select 和 poll其实本质上没有太大的区别（二选一就好了，而select对windows较友好），poll的特点就是突破了select的最大套接字上限的问题，所以poll本身和select一样会存在，遍历所有套接字列表的情况，而如果Redis当前存在大量无效或者空闲的连接，这时候每次都遍历就会带来一定的开销了，而epoll可以直接返回已经触发事件（活跃）的套接字，避免了循环带来的开销。

总结：
今天老师主要和我们介绍了，Redis在IO多路复用的实现和设计思路。我回到源码阅读后大概整理了一下：
	1、redis为了满足各种系统实现了多套IO多路复用，分别有：epoll，select，evport，kqueue
	2、redis在IO多路复用的代码实现进行了抽象，通过同一实现了aeApiState，aeApiCreate，aeApiResize，aeApiFree等等方法（类比接口）实现了多套IO复用，方便在编译期间切换（文件：ae_epoll.c，ae_evport.c，ae_kqueue.c，ae_select.c）
	3、在前面的文章中提到Redis启动的时候，在initServer方法中注册了acceptTcpHandler方法，用于处理连接事件，创建完成连接后交给对应IO多路复用
	4、通过aeApiCreate方法创建对应的IO多路复用，在创建aeEventLoop中创建，然后开始接受处理对应的事件

此外Redis在整个IO多路复用上的实现，预留了很大的灵活空间，实现了类似java接口的效果，这点值得我们学习，能灵活的切换不同的IO复用的方式，并且也方便拓展新的IO复用方式。</p>2021-08-18</li><br/><li><span>lei</span> 👍（2） 💬（0）<p>JDK 里也有 select() 方法，但是底层它是基于 epoll 实现。

select 函数将当前进程轮流加入每个 fd 对应设备的等待队列去询问该 fd 有无可读&#47;写事件。Linux 的开发者想到，找个“代理”的回调函数代替当前进程，去加入 fd 对应设备的等待队列，让这个代理的回调函数去等待设备就绪，当有设备就绪就将自己唤醒，然后该回调函数就把这个设备的 fd 放到一个就绪队列，同时通知可能在等待的轮询进程来这个就绪队列里取已经就绪的 fd。当前轮询的进程不需要遍历整个被侦听的 fd 集合。

简单说：
* epoll 将用户关心的 fd 放到了 Linux 内核里的一个事件表中，而不是像 select&#47;poll 函数那样，每次调用都需要复制 fd 到内核。内核将持久维护加入的 fd，减少了内核和用户空间复制数据的性能开销。
* 当一个 fd 的事件发生（比如说读事件），epoll 机制无须遍历整个被侦听的 fd 集，只要遍历那些被内核 I&#47;O 事件异步唤醒而加入就绪队列的 fd 集合，减少了无用功。
* epoll 机制支持的最大 fd 上限远远大于 1024，在1GB内存的机器上是 10 万左右，具体数目可以 cat&#47;proc&#47;sys&#47;fs&#47;file-max 查看。

epoll缺点：
epoll每次只遍历活跃的 fd (如果是 LT，也会遍历先前活跃的 fd)，在活跃fd较少的情况下就会很有优势，如果大部分fd都是活跃的，epoll的效率可能还不如 select&#47;poll。
</p>2021-11-16</li><br/><li><span>风轻扬</span> 👍（1） 💬（0）<p>看了好几遍，终于看懂了select和epoll的主要区别。
select函数。函数中定义了几个描述符集合，然后内核会关注这些描述符集合中，哪些描述符就绪了，然后返回已就绪的描述符个数，业务程序需要遍历所有的描述符集合，来找到可处理的描述符集合，这个遍历操作，很明显是O(n)的时间复杂度
epoll函数。函数中定义了监听的描述符、就绪的描述符，并且很重要的是：就绪的描述符用一个专门的结构存储，业务程序可以直接遍历这个就绪描述符集合，这样就省了遍历整个集合，在描述符很多时，epoll相比select，性能有肉眼的增长</p>2023-10-20</li><br/><li><span>陌</span> 👍（1） 💬（0）<p>epoll 还有一个非常重要的一点就是会在 TCP&#47;IP 协议栈实现上注册一个回调函数，也就是 `ep_poll_callback`，其作用就是将 epoll 红黑树上的 epitem 对象添加到双向链表中，同时如果此时 `epoll_wait()` 如果被阻塞的话将会唤醒，获得调度机会后将双向链表的数据拷贝到 `evlist` 中，应用程序可直接对其中的 socket fd 进行读写。</p>2021-08-17</li><br/><li><span>Geek_613829</span> 👍（1） 💬（0）<p>天，我居然是第一Σ(￣ロ￣lll)</p>2021-08-14</li><br/><li><span>无风</span> 👍（0） 💬（0）<p>ep_events为什么用malloc呢？我查了下很多demo用malloc，也有的demo直接定义数组。。</p>2021-08-18</li><br/>
</ul>