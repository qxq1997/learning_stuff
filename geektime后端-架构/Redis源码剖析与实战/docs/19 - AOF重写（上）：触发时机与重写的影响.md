你好，我是蒋德钧。

我们知道，Redis除了使用内存快照RDB来保证数据可靠性之外，还可以使用AOF日志。不过，RDB文件是将某一时刻的内存数据保存成一个文件，而AOF日志则会记录接收到的所有写操作。如果Redis server的写请求很多，那么AOF日志中记录的操作也会越来越多，进而就导致AOF日志文件越来越大。

所以，为了避免产生过大的AOF日志文件，Redis会对AOF文件进行重写，也就是针对当前数据库中每个键值对的最新内容，记录它的插入操作，而不再记录它的历史写操作了。这样一来，重写后的AOF日志文件就能变小了。

**那么，AOF重写在哪些时候会被触发呢？以及AOF重写需要写文件，这个过程会阻塞Redis的主线程，进而影响Redis的性能吗？**

今天这节课，我就来给你介绍下AOF重写的代码实现过程，通过了解它的代码实现，我们就可以清楚地了解到AOF重写过程的表现，以及它对Redis server的影响。这样，当你再遇到Redis server性能变慢的问题时，你就可以排查是否是AOF重写导致的了。

好，接下来，我们先来看下AOF重写函数以及它的触发时机。

## AOF重写函数与触发时机

首先，实现AOF重写的函数是**rewriteAppendOnlyFileBackground**，它是在[aof.c](https://github.com/redis/redis/tree/5.0/src/aof.c)文件中实现的。在这个函数中，会调用fork函数创建一个AOF重写子进程，来实际执行重写操作。关于这个函数的具体实现，我稍后会给你详细介绍。这里呢，我们先来看看，这个函数会被哪些函数调用，这样我们就可以了解AOF重写的触发时机了。

实际上，rewriteAppendOnlyFileBackground函数一共会在三个函数中被调用。

**第一个是bgrewriteaofCommand函数。**这个函数是在aof.c文件中实现的，对应了我们在Redis server上执行bgrewriteaof命令，也就是说，我们手动触发了AOF rewrite的执行。

不过，即使我们手动执行了bgrewriteaof命令，bgrewriteaofCommand函数也会根据以下两个条件，来判断是否实际执行AOF重写。

- **条件一：当前是否已经有AOF重写的子进程正在执行。**如果有的话，那么bgrewriteaofCommand函数就不再执行AOF重写了。
- **条件二：当前是否有创建RDB的子进程正在执行。**如果有的话，bgrewriteaofCommand函数会把全局变量server的aof\_rewrite\_scheduled成员变量设置为1，这个标志表明Redis server已经将AOF重写设为待调度运行，等后续条件满足时，它就会实际执行AOF重写（我们一会儿就会看到，当aof\_rewrite\_scheduled设置为1以后，Redis server会在哪些条件下实际执行重写操作）。

所以这也就是说，只有当前既没有AOF重写子进程也没有RDB子进程，bgrewriteaofCommand函数才会立即调用rewriteAppendOnlyFileBackground函数，实际执行AOF重写。

以下代码展示了bgrewriteaofCommand函数的基本执行逻辑，你可以看下。

```
void bgrewriteaofCommand(client *c) {
    if (server.aof_child_pid != -1) {
        .. //有AOF重写子进程，因此不执行重写
    } else if (server.rdb_child_pid != -1) {
        server.aof_rewrite_scheduled = 1; //有RDB子进程，将AOF重写设置为待调度运行
        ...
    } else if (rewriteAppendOnlyFileBackground() == C_OK) { //实际执行AOF重写
        ...
    } 
    ...
}
```

**第二个是startAppendOnly函数。**这个函数也是在aof.c文件中实现的，它本身会被configSetCommand函数（在[config.c](https://github.com/redis/redis/tree/5.0/src/config.c)文件中）和restartAOFAfterSYNC函数（在[replication.c](https://github.com/redis/redis/tree/5.0/src/replication.c)文件中）调用。

首先，对于configSetCommand函数来说，它对应了我们在Redis中执行config命令启用AOF功能，如下所示：

```
config set appendonly yes
```

这样，一旦AOF功能启用后，configSetCommand函数就会调用startAppendOnly函数，执行一次AOF重写。

而对于restartAOFAfterSYNC函数来说，它会在主从节点的复制过程中被调用。简单来说，就是当主从节点在进行复制时，如果从节点的AOF选项被打开，那么在加载解析RDB文件时，AOF选项就会被关闭。然后，无论从节点是否成功加载了RDB文件，restartAOFAfterSYNC函数都会被调用，用来恢复被关闭的AOF功能。

那么在这个过程中，restartAOFAfterSYNC函数就会调用startAppendOnly函数，并进一步调用rewriteAppendOnlyFileBackground函数，来执行一次AOF重写。

这里你要注意，和bgrewriteaofCommand函数类似，**startAppendOnly函数也会判断当前是否有RDB子进程在执行**，如果有的话，它会将AOF重写设置为待调度执行。除此之外，如果startAppendOnly函数检测到有AOF重写子进程在执行，那么它就会把该子进程先kill掉，然后再调用rewriteAppendOnlyFileBackground函数进行AOF重写。

所以到这里，我们其实可以发现，无论是bgrewriteaofCommand函数还是startAppendOnly函数，当它们检测到有RDB子进程在执行的时候，就会把aof\_rewrite\_scheduled变量设置为1，这表示AOF重写操作将在条件满足时再被执行。

**那么，Redis server什么时候会再检查AOF重写操作的条件是否满足呢？**这就和rewriteAppendOnlyFileBackground函数被调用的第三个函数，serverCron函数相关了。

**第三个是serverCron函数。**在Redis server运行时，serverCron函数是会被周期性执行的。然后它在执行的过程中，会做两次判断来决定是否执行AOF重写。

首先，serverCron函数会检测当前是否**没有RDB子进程和AOF重写子进程在执行**，并检测是否**有AOF重写操作被设置为了待调度执行**，也就是aof\_rewrite\_scheduled变量值为1。

如果这三个条件都满足，那么serverCron函数就会调用rewriteAppendOnlyFileBackground函数来执行AOF重写。serverCron函数里面的这部分执行逻辑如下所示：

```
//如果没有RDB子进程，也没有AOF重写子进程，并且AOF重写被设置为待调度执行，那么调用rewriteAppendOnlyFileBackground函数进行AOF重写
if (server.rdb_child_pid == -1 && server.aof_child_pid == -1 &&
        server.aof_rewrite_scheduled)
{
        rewriteAppendOnlyFileBackground();
}
```

事实上，这里的代码也回答了我们刚才提到的问题：待调度执行的AOF重写会在什么时候执行？

其实，如果AOF重写没法立即执行的话，我们也不用担心。因为**只要aof\_rewrite\_scheduled变量被设置为1了，那么serverCron函数就默认会每100毫秒执行并检测这个变量值**。所以，如果正在执行的RDB子进程和AOF重写子进程结束了之后，被调度执行的AOF重写就可以很快得到执行。

其次，即使AOF重写操作没有被设置为待调度执行，serverCron函数也会**周期性判断是否需要执行AOF重写**。这里的判断条件主要有三个，分别是AOF功能已启用、AOF文件大小比例超出阈值，以及AOF文件大小绝对值超出阈值。

这样一来，当这三个条件都满足时，并且也没有RDB子进程和AOF子进程在运行的话，此时，serverCron函数就会调用rewriteAppendOnlyFileBackground函数执行AOF重写。这部分的代码逻辑如下所示：

```
//如果AOF功能启用、没有RDB子进程和AOF重写子进程在执行、AOF文件大小比例设定了阈值，以及AOF文件大小绝对值超出了阈值，那么，进一步判断AOF文件大小比例是否超出阈值
if (server.aof_state == AOF_ON && server.rdb_child_pid == -1 && server.aof_child_pid == -1 && server.aof_rewrite_perc && server.aof_current_size > server.aof_rewrite_min_size) {
   //计算AOF文件当前大小超出基础大小的比例
   long long base = server.aof_rewrite_base_size ? server.aof_rewrite_base_size : 1;
   long long growth = (server.aof_current_size*100/base) - 100;
   //如果AOF文件当前大小超出基础大小的比例已经超出预设阈值，那么执行AOF重写
   if (growth >= server.aof_rewrite_perc) {
      ...
      rewriteAppendOnlyFileBackground();
   }
}
```

那么，从这里的代码中，你会看到，为了避免AOF文件过大导致占用过多的磁盘空间，以及增加恢复时长，你其实可以通过设置redis.conf文件中的以下两个阈值，来让Redis server自动重写AOF文件。

- **auto-aof-rewrite-percentage**：AOF文件大小超出基础大小的比例，默认值为100%，即超出1倍大小。
- **auto-aof-rewrite-min-size**：AOF文件大小绝对值的最小值，默认为64MB。

好了，到这里，我们就了解了AOF重写的四个触发时机，这里我也给你总结下，方便你回顾复习。

- 时机一：bgrewriteaof命令被执行。
- 时机二：主从复制完成RDB文件解析和加载（无论是否成功）。
- 时机三：AOF重写被设置为待调度执行。
- 时机四：AOF被启用，同时AOF文件的大小比例超出阈值，以及AOF文件的大小绝对值超出阈值。

另外，这里你还需要注意，在这四个时机下，其实都不能有正在执行的RDB子进程和AOF重写子进程，否则的话，AOF重写就无法执行了。

所以接下来，我们就来学习下AOF重写的基本执行过程。

## AOF重写的基本过程

首先，我们再来看下刚才介绍的rewriteAppendOnlyFileBackground函数。这个函数的主体逻辑比较简单，一方面，它会通过调用fork函数创建一个子进程，然后在子进程中调用rewriteAppendOnlyFile函数进行AOF文件重写。

rewriteAppendOnlyFile函数是在aof.c文件中实现的。它主要会调用**rewriteAppendOnlyFileRio函数**（在aof.c文件中）来完成AOF日志文件的重写。具体来说，就是rewriteAppendOnlyFileRio函数会遍历Redis server的每一个数据库，把其中的每个键值对读取出来，然后记录该键值对类型对应的插入命令，以及键值对本身的内容。

比如，如果读取的是一个String类型的键值对，那么rewriteAppendOnlyFileRio函数，就会记录SET命令和键值对本身内容；而如果读取的是Set类型键值对，那么它会记录SADD命令和键值对内容。这样一来，当需要恢复Redis数据库时，我们重新执行一遍AOF重写日志中记录的命令操作，就可以依次插入所有键值对了。

另一方面，在父进程中，这个rewriteAppendOnlyFileBackground函数会**把aof\_rewrite\_scheduled变量设置为0**，同时记录AOF重写开始的时间，以及记录AOF子进程的进程号。

此外，rewriteAppendOnlyFileBackground函数还会调用**updateDictResizePolicy函数**，禁止在AOF重写期间进行rehash操作。这是因为rehash操作会带来较多的数据移动操作，对于AOF重写子进程来说，这就意味着父进程中的内存修改会比较多。因此，AOF重写子进程就需要执行更多的写时复制，进而完成AOF文件的写入，这就会给Redis系统的性能造成负面影响。

以下代码就展示了rewriteAppendOnlyFileBackground函数的基本执行逻辑，你可以看下。

```
int rewriteAppendOnlyFileBackground(void) {
   ...
   if ((childpid = fork()) == 0) {  //创建子进程
      ...
      //子进程调用rewriteAppendOnlyFile进行AOF重写
      if (rewriteAppendOnlyFile(tmpfile) == C_OK) {
            size_t private_dirty = zmalloc_get_private_dirty(-1);
            ...
            exitFromChild(0);
        } else {
            exitFromChild(1);
        }
   }
   else{ //父进程执行的逻辑
      ...
      server.aof_rewrite_scheduled = 0;  
      server.aof_rewrite_time_start = time(NULL);
      server.aof_child_pid = childpid; //记录重写子进程的进程号
      updateDictResizePolicy(); //关闭rehash功能
}
```

而从这里，你可以看到，AOF重写和RDB创建是比较类似的，它们都会创建一个子进程来遍历所有的数据库，并把数据库中的每个键值对记录到文件中。不过，AOF重写和RDB文件又有两个不同的地方：

- 一是，AOF文件中是以“命令+键值对”的形式，来记录每个键值对的插入操作，而RDB文件记录的是键值对数据本身；
- 二是，在AOF重写或是创建RDB的过程中，主进程仍然可以接收客户端写请求。不过，因为RDB文件只需要记录某个时刻下数据库的所有数据就行，而AOF重写则需要尽可能地把主进程收到的写操作，也记录到重写的日志文件中。所以，AOF重写子进程就需要有相应的机制来和主进程进行通信，以此来接收主进程收到的写操作。

下图就展示了rewriteAppendOnlyFileBackground函数执行的基本逻辑、主进程和AOF重写子进程各自执行的内容，以及主进程和子进程间的通信过程，你可以再来整体回顾下。

![](https://static001.geekbang.org/resource/image/01/dd/01ce2381652fee284c081f7a376006dd.jpg?wh=2000x1125)

到这里，我们就大概掌握了AOF重写的基本执行过程。但是在这里，你可能还会有疑问，比如说，AOF重写的子进程和父进程，它们之间的通信过程是怎么样的呢？

其实，这个通信过程是通过操作系统的**管道机制**（pipe）来实现的，不过你也别着急，这部分内容，我会在下一讲给你详细介绍。

## 小结

今天这节课我给你介绍了Redis AOF重写机制的实现，你需要重点关注以下两个要点：

- **AOF重写的触发时机**。这既包括了我们主动执行bgrewriteaof命令，也包括了Redis server根据AOF文件大小而自动触发的重写。此外，在主从复制的过程中，从节点也会启动AOF重写，形成一份完整的AOF日志，以便后续进行恢复。当然你也要知道，当要触发AOF重写时，Redis server是不能运行RDB子进程和AOF重写子进程的。
- **AOF重写的基本执行过程**。AOF重写和RDB创建的过程类似，它也是创建了一个子进程来完成重写工作。这是因为AOF重写操作，实际上需要遍历Redis server上的所有数据库，把每个键值对以插入操作的形式写入日志文件，而日志文件又要进行写盘操作。所以，Redis源码使用子进程来实现AOF重写，这就避免了阻塞主线程，也减少了对Redis整体性能的影响。

不过，你需要注意的是，虽然AOF重写和RDB创建都用了子进程，但是它们也有不同的地方，AOF重写过程中父进程收到的写操作，也需要尽量写入AOF重写日志，在这里，Redis源码是使用了**管道机制**来实现父进程和AOF重写子进程间的通信的。在下一讲中，我就会重点给你介绍，Redis是如何使用管道完成父子进程的通信，以及它们通过管道又传递了哪些数据或信息。

## 每课一问

RDB文件的创建是由一个子进程来完成的，而AOF重写也是由一个子进程完成的，这两个子进程可以各自单独运行。那么请你思考一下，为什么Redis源码中在有RDB子进程运行时，不会启动AOF重写子进程呢？
<div><strong>精选留言（5）</strong></div><ul>
<li><span>Kaito</span> 👍（19） 💬（5）<p>1、AOF 记录的是每个命令的「操作历史」，随着时间增长，AOF 文件会越来越大，所以需要 AOF 重写来「瘦身」，减小文件体积

2、AOF 重写时，会扫描整个实例中的数据，把数据以「命令 + 键值对」的格式，写到 AOF 文件中

3、触发 AOF 重写的时机有 4 个：

- 执行 bgrewriteaof 命令
- 手动打开 AOF 开关（config set appendonly yes）
- 从库加载完主库 RDB 后（AOF 被启动的前提下）
- 定时触发：AOF 文件大小比例超出阈值、AOF 文件大小绝对值超出阈值（AOF 被启动的前提下）

这 4 个时机，都不能有 RDB 子进程，否则 AOF 重写会延迟执行。

4、AOF 重写期间会禁用 rehash，不让父进程调整哈希表大小，目的是父进程「写时复制」拷贝大量内存页面

课后题：为什么 Redis 源码中在有 RDB 子进程运行时，不会启动 AOF 重写子进程？

无论是生成 RDB 还是 AOF 重写，都需要创建子进程，然后把实例中的所有数据写到磁盘上，这个过程中涉及到两块：

- CPU：写盘之前需要先迭代实例中的所有数据，在这期间会耗费比较多的 CPU 资源，两者同时进行，CPU 资源消耗大
- 磁盘：同样地，RDB 和 AOF 重写，都是把内存数据落盘，在这期间 Redis 会持续写磁盘，如果同时进行，磁盘 IO 压力也会较大

整体来说都是为了资源考虑，所以不会让它们同时进行。</p>2021-09-09</li><br/><li><span>曾轼麟</span> 👍（7） 💬（0）<p>先回答老师的问题：RDB和AOF进程为什么不能同时运行？
答：有多方的原因
    1、AOF-RDB混合持久化
        现在Redis官方主推的是AOF-RDB混合持久化方案，同时运行AOF进程重写和RDB进程保存必然会带来不必要的冲突。

    2、两个都是fork出来的
        由于AOF重写进程和RDB保存进程都是通过fork出来的，AOF在重写期间还会继续保存来自主进程的命令操作，那么同时运行必然带来风险也需要考虑更多问题。

    3、更高的资源消耗 
        AOF和RDB都是高IO的操作，而且业务场景也非必须同时进行，同时进行对资源是较大的浪费。

总结：
    本次老师介绍了AOF重写是如何进行的，和上一篇文章一样AOF重写是高IO操作，并且是一个异步缓慢的过程为了避免阻塞主进程Redis是通过fork子进程进行的，但是与RDB不同的是AOF重写期间还需要同步重写期间来自主进程的命令，并在重写完成后同步到文件中，在这里老师也引出了管道技术，为AOF进程同步主进程命令买下伏笔（期待老师的下篇文章）

    其次值得注意的是updateDictResizePolicy函数，文章中提到updateDictResizePolicy是在AOF进行中调用，目的是为了阻止渐进式Rehash从而减少【写时复制】带来的大量内存开销，除了AOF意外其实bgsave 异步保存RDB文件也会调用这个方法来避免同样的问题。</p>2021-09-09</li><br/><li><span>William</span> 👍（0） 💬（3）<p>这里有疑问，“在父进程中，这个 rewriteAppendOnlyFileBackground 函数会把 aof_rewrite_scheduled 变量设置为 0，同时记录 AOF 重写开始的时间，以及记录 AOF 子进程的进程号。”

我看这是if..else 结构呀？ 进来的时候 是 if ((childpid = fork()) == 0) { ....} , 怎么会既有fork子进程重写AOF, 又有父进程，对这个标记调整为0 ？ 

查到的资料： fock函数调用一次却返回两次；向父进程返回子进程的ID，向子进程中返回0；

所以父子进程的业务逻辑都会执行。

请老师解惑是不是这样？ </p>2021-09-24</li><br/><li><span>静心</span> 👍（0） 💬（1）<p>我有一个疑问没搞明白：
在AOF重写的时候，是新创建一个文件来写，写完之后再替换旧的AOF文件呢？还是重写先在内存中进行，然后再覆盖旧的AOF文件？</p>2021-09-15</li><br/><li><span>Milittle</span> 👍（0） 💬（1）<p>问答题：我的考虑是为了并发安全</p>2021-09-09</li><br/>
</ul>