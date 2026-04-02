你好，我是盛延敏，今天是网络编程实战性能篇的答疑模块，欢迎回来。

在性能篇中，我主要围绕C10K问题进行了深入剖析，最后引出了事件分发机制和多线程。可以说，基于epoll的事件分发能力，是Linux下高性能网络编程的不二之选。如果你觉得还不过瘾，期望有更深刻的认识和理解，那么在性能篇的答疑中，我就带你一起梳理一下epoll的源代码，从中我们一定可以有更多的发现和领悟。

今天的代码有些多，建议你配合文稿收听音频。

## 基本数据结构

在开始研究源代码之前，我们先看一下epoll中使用的数据结构，分别是eventpoll、epitem和eppoll\_entry。

我们先看一下eventpoll这个数据结构，这个数据结构是我们在调用epoll\_create之后内核侧创建的一个句柄，表示了一个epoll实例。后续如果我们再调用epoll\_ctl和epoll\_wait等，都是对这个eventpoll数据进行操作，这部分数据会被保存在epoll\_create创建的匿名文件file的private\_data字段中。

```
/*
 * This structure is stored inside the "private_data" member of the file
 * structure and represents the main data structure for the eventpoll
 * interface.
 */
struct eventpoll {
    /* Protect the access to this structure */
    spinlock_t lock;

    /*
     * This mutex is used to ensure that files are not removed
     * while epoll is using them. This is held during the event
     * collection loop, the file cleanup path, the epoll file exit
     * code and the ctl operations.
     */
    struct mutex mtx;

    /* Wait queue used by sys_epoll_wait() */
    //这个队列里存放的是执行epoll_wait从而等待的进程队列
    wait_queue_head_t wq;

    /* Wait queue used by file->poll() */
    //这个队列里存放的是该eventloop作为poll对象的一个实例，加入到等待的队列
    //这是因为eventpoll本身也是一个file, 所以也会有poll操作
    wait_queue_head_t poll_wait;

    /* List of ready file descriptors */
    //这里存放的是事件就绪的fd列表，链表的每个元素是下面的epitem
    struct list_head rdllist;

    /* RB tree root used to store monitored fd structs */
    //这是用来快速查找fd的红黑树
    struct rb_root_cached rbr;

    /*
     * This is a single linked list that chains all the "struct epitem" that
     * happened while transferring ready events to userspace w/out
     * holding ->lock.
     */
    struct epitem *ovflist;

    /* wakeup_source used when ep_scan_ready_list is running */
    struct wakeup_source *ws;

    /* The user that created the eventpoll descriptor */
    struct user_struct *user;

    //这是eventloop对应的匿名文件，充分体现了Linux下一切皆文件的思想
    struct file *file;

    /* used to optimize loop detection check */
    int visited;
    struct list_head visited_list_link;

#ifdef CONFIG_NET_RX_BUSY_POLL
    /* used to track busy poll napi_id */
    unsigned int napi_id;
#endif
};
```

你能看到在代码中我提到了epitem，这个epitem结构是干什么用的呢？

每当我们调用epoll\_ctl增加一个fd时，内核就会为我们创建出一个epitem实例，并且把这个实例作为红黑树的一个子节点，增加到eventpoll结构体中的红黑树中，对应的字段是rbr。这之后，查找每一个fd上是否有事件发生都是通过红黑树上的epitem来操作。

```
/*
 * Each file descriptor added to the eventpoll interface will
 * have an entry of this type linked to the "rbr" RB tree.
 * Avoid increasing the size of this struct, there can be many thousands
 * of these on a server and we do not want this to take another cache line.
 */
struct epitem {
    union {
        /* RB tree node links this structure to the eventpoll RB tree */
        struct rb_node rbn;
        /* Used to free the struct epitem */
        struct rcu_head rcu;
    };

    /* List header used to link this structure to the eventpoll ready list */
    //将这个epitem连接到eventpoll 里面的rdllist的list指针
    struct list_head rdllink;

    /*
     * Works together "struct eventpoll"->ovflist in keeping the
     * single linked chain of items.
     */
    struct epitem *next;

    /* The file descriptor information this item refers to */
    //epoll监听的fd
    struct epoll_filefd ffd;

    /* Number of active wait queue attached to poll operations */
    //一个文件可以被多个epoll实例所监听，这里就记录了当前文件被监听的次数
    int nwait;

    /* List containing poll wait queues */
    struct list_head pwqlist;

    /* The "container" of this item */
    //当前epollitem所属的eventpoll
    struct eventpoll *ep;

    /* List header used to link this item to the "struct file" items list */
    struct list_head fllink;

    /* wakeup_source used when EPOLLWAKEUP is set */
    struct wakeup_source __rcu *ws;

    /* The structure that describe the interested events and the source fd */
    struct epoll_event event;
};
```

每次当一个fd关联到一个epoll实例，就会有一个eppoll\_entry产生。eppoll\_entry的结构如下：

```
/* Wait structure used by the poll hooks */
struct eppoll_entry {
    /* List header used to link this structure to the "struct epitem" */
    struct list_head llink;

    /* The "base" pointer is set to the container "struct epitem" */
    struct epitem *base;

    /*
     * Wait queue item that will be linked to the target file wait
     * queue head.
     */
    wait_queue_entry_t wait;

    /* The wait queue head that linked the "wait" wait queue item */
    wait_queue_head_t *whead;
};
```

## epoll\_create

我们在使用epoll的时候，首先会调用epoll\_create来创建一个epoll实例。这个函数是如何工作的呢?

首先，epoll\_create会对传入的flags参数做简单的验证。

```
/* Check the EPOLL_* constant for consistency.  */
BUILD_BUG_ON(EPOLL_CLOEXEC != O_CLOEXEC);

if (flags & ~EPOLL_CLOEXEC)
    return -EINVAL;
/*
```

接下来，内核申请分配eventpoll需要的内存空间。

```
/* Create the internal data structure ("struct eventpoll").
*/
error = ep_alloc(&ep);
if (error < 0)
  return error;
```

在接下来，epoll\_create为epoll实例分配了匿名文件和文件描述字，其中fd是文件描述字，file是一个匿名文件。这里充分体现了UNIX下一切都是文件的思想。注意，eventpoll的实例会保存一份匿名文件的引用，通过调用fd\_install函数将匿名文件和文件描述字完成了绑定。

这里还有一个特别需要注意的地方，在调用anon\_inode\_get\_file的时候，epoll\_create将eventpoll作为匿名文件file的private\_data保存了起来，这样，在之后通过epoll实例的文件描述字来查找时，就可以快速地定位到eventpoll对象了。

最后，这个文件描述字作为epoll的文件句柄，被返回给epoll\_create的调用者。

```
/*
 * Creates all the items needed to setup an eventpoll file. That is,
 * a file structure and a free file descriptor.
 */
fd = get_unused_fd_flags(O_RDWR | (flags & O_CLOEXEC));
if (fd < 0) {
    error = fd;
    goto out_free_ep;
}
file = anon_inode_getfile("[eventpoll]", &eventpoll_fops, ep,
             O_RDWR | (flags & O_CLOEXEC));
if (IS_ERR(file)) {
    error = PTR_ERR(file);
    goto out_free_fd;
}
ep->file = file;
fd_install(fd, file);
return fd;
```

## epoll\_ctl

接下来，我们看一下一个套接字是如何被添加到epoll实例中的。这就要解析一下epoll\_ctl函数实现了。

### 查找epoll实例

首先，epoll\_ctl函数通过epoll实例句柄来获得对应的匿名文件，这一点很好理解，UNIX下一切都是文件，epoll的实例也是一个匿名文件。

```
//获得epoll实例对应的匿名文件
f = fdget(epfd);
if (!f.file)
    goto error_return;
```

接下来，获得添加的套接字对应的文件，这里tf表示的是target file，即待处理的目标文件。

```
/* Get the "struct file *" for the target file */
//获得真正的文件，如监听套接字、读写套接字
tf = fdget(fd);
if (!tf.file)
    goto error_fput;
```

再接下来，进行了一系列的数据验证，以保证用户传入的参数是合法的，比如epfd真的是一个epoll实例句柄，而不是一个普通文件描述符。

```
/* The target file descriptor must support poll */
//如果不支持poll，那么该文件描述字是无效的
error = -EPERM;
if (!tf.file->f_op->poll)
    goto error_tgt_fput;
...
```

如果获得了一个真正的epoll实例句柄，就可以通过private\_data获取之前创建的eventpoll实例了。

```
/*
 * At this point it is safe to assume that the "private_data" contains
 * our own data structure.
 */
ep = f.file->private_data;
```

### 红黑树查找

接下来epoll\_ctl通过目标文件和对应描述字，在红黑树中查找是否存在该套接字，这也是epoll为什么高效的地方。红黑树（RB-tree）是一种常见的数据结构，这里eventpoll通过红黑树跟踪了当前监听的所有文件描述字，而这棵树的根就保存在eventpoll数据结构中。

```
/* RB tree root used to store monitored fd structs */
struct rb_root_cached rbr;
```

对于每个被监听的文件描述字，都有一个对应的epitem与之对应，epitem作为红黑树中的节点就保存在红黑树中。

```
/*
 * Try to lookup the file inside our RB tree, Since we grabbed "mtx"
 * above, we can be sure to be able to use the item looked up by
 * ep_find() till we release the mutex.
 */
epi = ep_find(ep, tf.file, fd);
```

红黑树是一棵二叉树，作为二叉树上的节点，epitem必须提供比较能力，以便可以按大小顺序构建出一棵有序的二叉树。其排序能力是依靠epoll\_filefd结构体来完成的，epoll\_filefd可以简单理解为需要监听的文件描述字，它对应到二叉树上的节点。

可以看到这个还是比较好理解的，按照文件的地址大小排序。如果两个相同，就按照文件文件描述字来排序。

```
struct epoll_filefd {
	struct file *file; // pointer to the target file struct corresponding to the fd
	int fd; // target file descriptor number
} __packed;

/* Compare RB tree keys */
static inline int ep_cmp_ffd(struct epoll_filefd *p1,
                            struct epoll_filefd *p2)
{
	return (p1->file > p2->file ? +1:
		   (p1->file < p2->file ? -1 : p1->fd - p2->fd));
}
```

在进行完红黑树查找之后，如果发现是一个ADD操作，并且在树中没有找到对应的二叉树节点，就会调用ep\_insert进行二叉树节点的增加。

```
case EPOLL_CTL_ADD:
    if (!epi) {
        epds.events |= POLLERR | POLLHUP;
        error = ep_insert(ep, &epds, tf.file, fd, full_check);
    } else
        error = -EEXIST;
    if (full_check)
        clear_tfile_check_list();
    break;
```

### ep\_insert

ep\_insert首先判断当前监控的文件值是否超过了/proc/sys/fs/epoll/max\_user\_watches的预设最大值，如果超过了则直接返回错误。

```
user_watches = atomic_long_read(&ep->user->epoll_watches);
if (unlikely(user_watches >= max_user_watches))
    return -ENOSPC;
```

接下来是分配资源和初始化动作。

```
if (!(epi = kmem_cache_alloc(epi_cache, GFP_KERNEL)))
        return -ENOMEM;

    /* Item initialization follow here ... */
    INIT_LIST_HEAD(&epi->rdllink);
    INIT_LIST_HEAD(&epi->fllink);
    INIT_LIST_HEAD(&epi->pwqlist);
    epi->ep = ep;
    ep_set_ffd(&epi->ffd, tfile, fd);
    epi->event = *event;
    epi->nwait = 0;
    epi->next = EP_UNACTIVE_PTR;
```

再接下来的事情非常重要，ep\_insert会为加入的每个文件描述字设置回调函数。这个回调函数是通过函数ep\_ptable\_queue\_proc来进行设置的。这个回调函数是干什么的呢？其实，对应的文件描述字上如果有事件发生，就会调用这个函数，比如套接字缓冲区有数据了，就会回调这个函数。这个函数就是ep\_poll\_callback。这里你会发现，原来内核设计也是充满了事件回调的原理。

```
/*
 * This is the callback that is used to add our wait queue to the
 * target file wakeup lists.
 */
static void ep_ptable_queue_proc(struct file *file, wait_queue_head_t *whead,poll_table *pt)
{
    struct epitem *epi = ep_item_from_epqueue(pt);
    struct eppoll_entry *pwq;

    if (epi>nwait >= 0 && (pwq = kmem_cache_alloc(pwq_cache, GFP_KERNEL))) {
        init_waitqueue_func_entry(&pwq->wait, ep_poll_callback);
        pwq->whead = whead;
        pwq->base = epi;
        if (epi->event.events & EPOLLEXCLUSIVE)
            add_wait_queue_exclusive(whead, &pwq->wait);
        else
            add_wait_queue(whead, &pwq->wait);
        list_add_tail(&pwq->llink, &epi->pwqlist);
        epi->nwait++;
    } else {
        /* We have to signal that an error occurred */
        epi->nwait = -1;
    }
}
```

### ep\_poll\_callback

ep\_poll\_callback函数的作用非常重要，它将内核事件真正地和epoll对象联系了起来。它又是怎么实现的呢？

首先，通过这个文件的wait\_queue\_entry\_t对象找到对应的epitem对象，因为eppoll\_entry对象里保存了wait\_queue\_entry\_t，根据wait\_queue\_entry\_t这个对象的地址就可以简单计算出eppoll\_entry对象的地址，从而可以获得epitem对象的地址。这部分工作在ep\_item\_from\_wait函数中完成。一旦获得epitem对象，就可以寻迹找到eventpoll实例。

```
/*
 * This is the callback that is passed to the wait queue wakeup
 * mechanism. It is called by the stored file descriptors when they
 * have events to report.
 */
static int ep_poll_callback(wait_queue_entry_t *wait, unsigned mode, int sync, void *key)
{
    int pwake = 0;
    unsigned long flags;
    struct epitem *epi = ep_item_from_wait(wait);
    struct eventpoll *ep = epi->ep;
```

接下来，进行一个加锁操作。

```
spin_lock_irqsave(&ep->lock, flags);
```

下面对发生的事件进行过滤，为什么需要过滤呢？为了性能考虑，ep\_insert向对应监控文件注册的是所有的事件，而实际用户侧订阅的事件未必和内核事件对应。比如，用户向内核订阅了一个套接字的可读事件，在某个时刻套接字的可写事件发生时，并不需要向用户空间传递这个事件。

```
/*
 * Check the events coming with the callback. At this stage, not
 * every device reports the events in the "key" parameter of the
 * callback. We need to be able to handle both cases here, hence the
 * test for "key" != NULL before the event match test.
 */
if (key && !((unsigned long) key & epi->event.events))
    goto out_unlock;
```

接下来，判断是否需要把该事件传递给用户空间。

```
if (unlikely(ep->ovflist != EP_UNACTIVE_PTR)) {
  if (epi->next == EP_UNACTIVE_PTR) {
      epi->next = ep->ovflist;
      ep->ovflist = epi;
      if (epi->ws) {
          /*
           * Activate ep->ws since epi->ws may get
           * deactivated at any time.
           */
          __pm_stay_awake(ep->ws);
      }
  }
  goto out_unlock;
}
```

如果需要，而且该事件对应的event\_item不在eventpoll对应的已完成队列中，就把它放入该队列，以便将该事件传递给用户空间。

```
/* If this file is already in the ready list we exit soon */
if (!ep_is_linked(&epi->rdllink)) {
    list_add_tail(&epi->rdllink, &ep->rdllist);
    ep_pm_stay_awake_rcu(epi);
}
```

我们知道，当我们调用epoll\_wait的时候，调用进程被挂起，在内核看来调用进程陷入休眠。如果该epoll实例上对应描述字有事件发生，这个休眠进程应该被唤醒，以便及时处理事件。下面的代码就是起这个作用的，wake\_up\_locked函数唤醒当前eventpoll上的等待进程。

```
/*
 * Wake up ( if active ) both the eventpoll wait list and the ->poll()
 * wait list.
 */
if (waitqueue_active(&ep->wq)) {
    if ((epi->event.events & EPOLLEXCLUSIVE) &&
                !((unsigned long)key & POLLFREE)) {
        switch ((unsigned long)key & EPOLLINOUT_BITS) {
        case POLLIN:
            if (epi->event.events & POLLIN)
                ewake = 1;
            break;
        case POLLOUT:
            if (epi->event.events & POLLOUT)
                ewake = 1;
            break;
        case 0:
            ewake = 1;
            break;
        }
    }
    wake_up_locked(&ep->wq);
}
```

### 查找epoll实例

epoll\_wait函数首先进行一系列的检查，例如传入的maxevents应该大于0。

```
/* The maximum number of event must be greater than zero */
if (maxevents <= 0 || maxevents > EP_MAX_EVENTS)
    return -EINVAL;

/* Verify that the area passed by the user is writeable */
if (!access_ok(VERIFY_WRITE, events, maxevents * sizeof(struct epoll_event)))
    return -EFAULT;
```

和前面介绍的epoll\_ctl一样，通过epoll实例找到对应的匿名文件和描述字，并且进行检查和验证。

```
/* Get the "struct file *" for the eventpoll file */
f = fdget(epfd);
if (!f.file)
    return -EBADF;

/*
 * We have to check that the file structure underneath the fd
 * the user passed to us _is_ an eventpoll file.
 */
error = -EINVAL;
if (!is_file_epoll(f.file))
    goto error_fput;
```

还是通过读取epoll实例对应匿名文件的private\_data得到eventpoll实例。

```
/*
 * At this point it is safe to assume that the "private_data" contains
 * our own data structure.
 */
ep = f.file->private_data;
```

接下来调用ep\_poll来完成对应的事件收集并传递到用户空间。

```
/* Time to fish for events ... */
error = ep_poll(ep, events, maxevents, timeout);
```

### ep\_poll

还记得[第23讲](https://time.geekbang.org/column/article/143245)里介绍epoll函数的时候，对应的timeout值可以是大于0，等于0和小于0么？这里ep\_poll就分别对timeout不同值的场景进行了处理。如果大于0则产生了一个超时时间，如果等于0则立即检查是否有事件发生。

```
*/
static int ep_poll(struct eventpoll *ep, struct epoll_event __user *events,int maxevents, long timeout)
{
int res = 0, eavail, timed_out = 0;
unsigned long flags;
u64 slack = 0;
wait_queue_entry_t wait;
ktime_t expires, *to = NULL;

if (timeout > 0) {
    struct timespec64 end_time = ep_set_mstimeout(timeout);
    slack = select_estimate_accuracy(&end_time);
    to = &expires;
    *to = timespec64_to_ktime(end_time);
} else if (timeout == 0) {
    /*
     * Avoid the unnecessary trip to the wait queue loop, if the
     * caller specified a non blocking operation.
     */
    timed_out = 1;
    spin_lock_irqsave(&ep->lock, flags);
    goto check_events;
}
```

接下来尝试获得eventpoll上的锁：

```
spin_lock_irqsave(&ep->lock, flags);
```

获得这把锁之后，检查当前是否有事件发生，如果没有，就把当前进程加入到eventpoll的等待队列wq中，这样做的目的是当事件发生时，ep\_poll\_callback函数可以把该等待进程唤醒。

```
if (!ep_events_available(ep)) {
    /*
     * Busy poll timed out.  Drop NAPI ID for now, we can add
     * it back in when we have moved a socket with a valid NAPI
     * ID onto the ready list.
     */
    ep_reset_busy_poll_napi_id(ep);

    /*
     * We don't have any available event to return to the caller.
     * We need to sleep here, and we will be wake up by
     * ep_poll_callback() when events will become available.
     */
    init_waitqueue_entry(&wait, current);
    __add_wait_queue_exclusive(&ep->wq, &wait);
```

紧接着是一个无限循环, 这个循环中通过调用schedule\_hrtimeout\_range，将当前进程陷入休眠，CPU时间被调度器调度给其他进程使用，当然，当前进程可能会被唤醒，唤醒的条件包括有以下四种：

1. 当前进程超时；
2. 当前进程收到一个signal信号；
3. 某个描述字上有事件发生；
4. 当前进程被CPU重新调度，进入for循环重新判断，如果没有满足前三个条件，就又重新进入休眠。

对应的1、2、3都会通过break跳出循环，直接返回。

```
//这个循环里，当前进程可能会被唤醒，唤醒的途径包括
//1.当前进程超时
//2.当前进行收到一个signal信号
//3.某个描述字上有事件发生
//对应的1.2.3都会通过break跳出循环
//第4个可能是当前进程被CPU重新调度，进入for循环的判断，如果没有满足1.2.3的条件，就又重新进入休眠
for (;;) {
    /*
     * We don't want to sleep if the ep_poll_callback() sends us
     * a wakeup in between. That's why we set the task state
     * to TASK_INTERRUPTIBLE before doing the checks.
     */
    set_current_state(TASK_INTERRUPTIBLE);
    /*
     * Always short-circuit for fatal signals to allow
     * threads to make a timely exit without the chance of
     * finding more events available and fetching
     * repeatedly.
     */
    if (fatal_signal_pending(current)) {
        res = -EINTR;
        break;
    }
    if (ep_events_available(ep) || timed_out)
        break;
    if (signal_pending(current)) {
        res = -EINTR;
        break;
    }

    spin_unlock_irqrestore(&ep->lock, flags);

    //通过调用schedule_hrtimeout_range，当前进程进入休眠，CPU时间被调度器调度给其他进程使用
    if (!schedule_hrtimeout_range(to, slack, HRTIMER_MODE_ABS))
        timed_out = 1;

    spin_lock_irqsave(&ep->lock, flags);
}
```

如果进程从休眠中返回，则将当前进程从eventpoll的等待队列中删除，并且设置当前进程为TASK\_RUNNING状态。

```
//从休眠中结束，将当前进程从wait队列中删除，设置状态为TASK_RUNNING，接下来进入check_events，来判断是否是有事件发生
    __remove_wait_queue(&ep->wq, &wait);
    __set_current_state(TASK_RUNNING);
```

最后，调用ep\_send\_events将事件拷贝到用户空间。

```
//ep_send_events将事件拷贝到用户空间
/*
 * Try to transfer events to user space. In case we get 0 events and
 * there's still timeout left over, we go trying again in search of
 * more luck.
 */
if (!res && eavail &&
    !(res = ep_send_events(ep, events, maxevents)) && !timed_out)
    goto fetch_events;


return res;
```

### ep\_send\_events

ep\_send\_events这个函数会将ep\_send\_events\_proc作为回调函数并调用ep\_scan\_ready\_list函数，ep\_scan\_ready\_list函数调用ep\_send\_events\_proc对每个已经就绪的事件循环处理。

ep\_send\_events\_proc循环处理就绪事件时，会再次调用每个文件描述符的poll方法，以便确定确实有事件发生。为什么这样做呢？这是为了确定注册的事件在这个时刻还是有效的。

可以看到，尽管ep\_send\_events\_proc已经尽可能的考虑周全，使得用户空间获得的事件通知都是真实有效的，但还是有一定的概率，当ep\_send\_events\_proc再次调用文件上的poll函数之后，用户空间获得的事件通知已经不再有效，这可能是用户空间已经处理掉了，或者其他什么情形。还记得[第22讲](https://time.geekbang.org/column/article/141573)吗，在这种情况下，如果套接字不是非阻塞的，整个进程将会被阻塞，这也是为什么将非阻塞套接字配合epoll使用作为最佳实践的原因。

在进行简单的事件掩码校验之后，ep\_send\_events\_proc将事件结构体拷贝到用户空间需要的数据结构中。这是通过\_\_put\_user方法完成的。

```
//这里对一个fd再次进行poll操作，以确认事件
revents = ep_item_poll(epi, &pt);

/*
 * If the event mask intersect the caller-requested one,
 * deliver the event to userspace. Again, ep_scan_ready_list()
 * is holding "mtx", so no operations coming from userspace
 * can change the item.
 */
if (revents) {
    if (__put_user(revents, &uevent->events) ||
        __put_user(epi->event.data, &uevent->data)) {
        list_add(&epi->rdllink, head);
        ep_pm_stay_awake(epi);
        return eventcnt ? eventcnt : -EFAULT;
    }
    eventcnt++;
    uevent++;
```

## Level-triggered VS Edge-triggered

在[前面的](https://time.geekbang.org/column/article/143245)[文章](https://time.geekbang.org/column/article/143245)里，我们一直都在强调level-triggered和edge-triggered之间的区别。

从实现角度来看其实非常简单，在ep\_send\_events\_proc函数的最后，针对level-triggered情况，当前的epoll\_item对象被重新加到eventpoll的就绪列表中，这样在下一次epoll\_wait调用时，这些epoll\_item对象就会被重新处理。

在前面我们提到，在最终拷贝到用户空间有效事件列表中之前，会调用对应文件的poll方法，以确定这个事件是不是依然有效。所以，如果用户空间程序已经处理掉该事件，就不会被再次通知；如果没有处理，意味着该事件依然有效，就会被再次通知。

```
//这里是Level-triggered的处理，可以看到，在Level-triggered的情况下，这个事件被重新加回到ready list里面
//这样，下一轮epoll_wait的时候，这个事件会被重新check
else if (!(epi->event.events & EPOLLET)) {
    /*
     * If this file has been added with Level
     * Trigger mode, we need to insert back inside
     * the ready list, so that the next call to
     * epoll_wait() will check again the events
     * availability. At this point, no one can insert
     * into ep->rdllist besides us. The epoll_ctl()
     * callers are locked out by
     * ep_scan_ready_list() holding "mtx" and the
     * poll callback will queue them in ep->ovflist.
     */
    list_add_tail(&epi->rdllink, &ep->rdllist);
    ep_pm_stay_awake(epi);
}
```

## epoll VS poll/select

最后，我们从实现角度来说明一下为什么epoll的效率要远远高于poll/select。

首先，poll/select先将要监听的fd从用户空间拷贝到内核空间, 然后在内核空间里面进行处理之后，再拷贝给用户空间。这里就涉及到内核空间申请内存，释放内存等等过程，这在大量fd情况下，是非常耗时的。而epoll维护了一个红黑树，通过对这棵黑红树进行操作，可以避免大量的内存申请和释放的操作，而且查找速度非常快。

下面的代码就是poll/select在内核空间申请内存的展示。可以看到select 是先尝试申请栈上资源, 如果需要监听的fd比较多, 就会去申请堆空间的资源。

```
int core_sys_select(int n, fd_set __user *inp, fd_set __user *outp,
               fd_set __user *exp, struct timespec64 *end_time)
{
    fd_set_bits fds;
    void *bits;
    int ret, max_fds;
    size_t size, alloc_size;
    struct fdtable *fdt;
    /* Allocate small arguments on the stack to save memory and be faster */
    long stack_fds[SELECT_STACK_ALLOC/sizeof(long)];

    ret = -EINVAL;
    if (n < 0)
        goto out_nofds;

    /* max_fds can increase, so grab it once to avoid race */
    rcu_read_lock();
    fdt = files_fdtable(current->files);
    max_fds = fdt->max_fds;
    rcu_read_unlock();
    if (n > max_fds)
        n = max_fds;

    /*
     * We need 6 bitmaps (in/out/ex for both incoming and outgoing),
     * since we used fdset we need to allocate memory in units of
     * long-words. 
     */
    size = FDS_BYTES(n);
    bits = stack_fds;
    if (size > sizeof(stack_fds) / 6) {
        /* Not enough space in on-stack array; must use kmalloc */
        ret = -ENOMEM;
        if (size > (SIZE_MAX / 6))
            goto out_nofds;


        alloc_size = 6 * size;
        bits = kvmalloc(alloc_size, GFP_KERNEL);
        if (!bits)
            goto out_nofds;
    }
    fds.in      = bits;
    fds.out     = bits +   size;
    fds.ex      = bits + 2*size;
    fds.res_in  = bits + 3*size;
    fds.res_out = bits + 4*size;
    fds.res_ex  = bits + 5*size;
    ...
```

第二，select/poll从休眠中被唤醒时，如果监听多个fd，只要其中有一个fd有事件发生，内核就会遍历内部的list去检查到底是哪一个事件到达，并没有像epoll一样, 通过fd直接关联eventpoll对象，快速地把fd直接加入到eventpoll的就绪列表中。

```
static int do_select(int n, fd_set_bits *fds, struct timespec64 *end_time)
{
    ...
    retval = 0;
    for (;;) {
        unsigned long *rinp, *routp, *rexp, *inp, *outp, *exp;
        bool can_busy_loop = false;

        inp = fds->in; outp = fds->out; exp = fds->ex;
        rinp = fds->res_in; routp = fds->res_out; rexp = fds->res_ex;

        for (i = 0; i < n; ++rinp, ++routp, ++rexp) {
            unsigned long in, out, ex, all_bits, bit = 1, mask, j;
            unsigned long res_in = 0, res_out = 0, res_ex = 0;

            in = *inp++; out = *outp++; ex = *exp++;
            all_bits = in | out | ex;
            if (all_bits == 0) {
                i += BITS_PER_LONG;
                continue;
            }
        
        if (!poll_schedule_timeout(&table, TASK_INTERRUPTIBLE,
                   to, slack))
        timed_out = 1;
...
```

## 总结

在这次答疑中，我希望通过深度分析epoll的源码实现，帮你理解epoll的实现原理。

epoll维护了一棵红黑树来跟踪所有待检测的文件描述字，黑红树的使用减少了内核和用户空间大量的数据拷贝和内存分配，大大提高了性能。

同时，epoll维护了一个链表来记录就绪事件，内核在每个文件有事件发生时将自己登记到这个就绪事件列表中，通过内核自身的文件file-eventpoll之间的回调和唤醒机制，减少了对内核描述字的遍历，大大加速了事件通知和检测的效率，这也为level-triggered和edge-triggered的实现带来了便利。

通过对比poll/select的实现，我们发现epoll确实克服了poll/select的种种弊端，不愧是Linux下高性能网络编程的皇冠。我们应该感谢Linux社区的大神们设计了这么强大的事件分发机制，让我们在Linux下可以享受高性能网络服务器带来的种种技术红利。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>herongwei</span> 👍（24） 💬（2）<p>这篇文章写得非常棒！之前学 epoll，只会流于表面，也很少去深度剖析底层的数据结构，多读几遍!
另外分享一个大佬同学 epoll 内核源码详解发的帖子：https:&#47;&#47;www.nowcoder.com&#47;discuss&#47;26226</p>2019-10-26</li><br/><li><span>鱼向北游</span> 👍（20） 💬（1）<p>select这种是把等待队列和就绪队列混在一起，epoll根据这两种队列的特性用两种数据结构把这两个队列分开，果然在程序世界没有解决不了的事情，如果有，就加一个中间层</p>2019-10-18</li><br/><li><span>HerofH</span> 👍（9） 💬（1）<p>首先感谢老师的精彩分析。

然后说下我的个人理解：epoll之所以效率比select高，原因在于select要做的事情太多，每次调用select不仅需要将描述符集添加到监听队列中，还要负责监听事件发生后的处理，以及select最后的清理工作等等...
而epoll则把这么多事情分到了epoll_ctl和epoll_wait去处理，调用epoll_ctl可以开启事件的监听工作，epoll_wait则可以完成对已激活的事件的处理工作，最后close(epfd)完成epoll的清理工作。
而select和epoll_wait是循环中反复调用的，epoll_wait做的事情比select少多了，因此从这个角度来说epoll效率会比select效率高。
除此之外，个人感觉epoll还有一个妙处就是就绪链表，当监听的事件发生后，相应的epitem会自动在监听回调中将其添加到就绪链表中，而对于select来说，则需要不停对所有监听的描述符进行遍历，来检查它们的状态。

不知道理解是否正确，敬请指正。
</p>2020-01-15</li><br/><li><span>凉人。</span> 👍（8） 💬（1）<p>感觉这一章是最难以理解，如果多一些结构图，流程图，会好很多。</p>2020-02-11</li><br/><li><span>fackgc17</span> 👍（4） 💬（1）<p>可以提供一下分析用的 kernel 版本吗</p>2019-10-26</li><br/><li><span>heyman</span> 👍（3） 💬（4）<p>请问一下，为什么要用红黑树？是因为要排序吗？排序的意义又在哪里？确保查找、插入和删除的高效还不够吗？</p>2020-04-18</li><br/><li><span>瓜牛</span> 👍（2） 💬（1）<p>还是没明白为啥epoll有红黑树之后就不用在用户空间和内核空间之间拷贝了，或者说poll&#47;select为啥要在用户空间和内核空间之间拷贝？</p>2021-11-05</li><br/><li><span>钱</span> 👍（2） 💬（1）<p>功力不够，读起来有些费劲，好似拿到了九阴真经，不过需要黄姑娘翻译一下！
如果能来个图，就好了😁</p>2019-12-01</li><br/><li><span>xupeng1644</span> 👍（1） 💬（1）<p>老师 在Level-triggered VS Edge-triggered小节中给出了Level-triggered的实现机制，可以再给下Edge-triggered的吗</p>2020-02-28</li><br/><li><span>J.M.Liu</span> 👍（1） 💬（1）<p>老师，我请教两个问题：
1.ep_send_events_proc这个函数在把events列表拷贝到用户空间前会调用ep_item_poll函数，已确定对应的fd上的事件依旧有效。那ep_item_poll是根据什么来确定事件的有效性呢？
2.在ep_send_events_proc处理level-triggered的时候，有这么一段话“At this point, no one can insert into ep-&gt;rdllist besides us. The epoll_ctl()  callers are locked out by ep_scan_ready_list() holding &quot;mtx&quot; and the  poll callback will queue them in ep-&gt;ovflist.”意思是说epoll_ctl（）的调用者也被锁在外面了。这个锁是说在ep_send_events_proc还没处理完的时候，epoll_ctl()无法操纵rdllist，但是之后是可以的，以实现再次注册感兴趣的时间。是这样吗？</p>2019-10-29</li><br/><li><span>沉淀的梦想</span> 👍（1） 💬（1）<p>缺乏C语言和linux内核基础的人读起这些源码来相当吃力，虽然老师讲得很好</p>2019-10-19</li><br/><li><span>西门吹牛</span> 👍（0） 💬（1）<p>当内核监测到有就绪事件后，将对应的fd 加入就绪 队列，这里其实还会涉及到将有事件的fd拷贝到用户空间，可不可以让用户空间和内核空间采用共享内存的方式，避免拷贝呢</p>2022-01-27</li><br/><li><span>Geek_68d3d2</span> 👍（0） 💬（3）<p> epi&gt;nwait &gt;= 0请问这行代码什么意思</p>2020-01-08</li><br/><li><span>haozhang</span> 👍（0） 💬（1）<p>老师   进程阻塞的形式是什么呢   是for死循环吗     还是加入到等待队列呢，我看for循环前面不是加入到等待队列了吗？</p>2019-11-06</li><br/><li><span>初见</span> 👍（0） 💬（5）<p>老师，我之前面试被问到过说，epoll 更适合连接很多，但活跃的连接较少的情况

那么，连接很多，活跃连接也很多的情况下，用什么方案呢？  堆机器嘛</p>2019-10-25</li><br/>
</ul>