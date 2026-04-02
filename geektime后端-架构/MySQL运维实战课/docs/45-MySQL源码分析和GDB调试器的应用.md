你好，我是俊达。

之前在评论区有同学留言问是否能加一讲源代码调试的内容。考虑到这个专栏中有相当多的篇幅是讲MySQL和InnoDB的内部实现机制，而我自己在整理这些内部原理时，也参考了大量的MySQL源码，有时也会用GDB来调试跟踪代码的执行，因此在这一讲中，我们就来聊聊MySQL源码分析和GDB在源码分析中的一些使用场景。

这里我们只讨论MySQL的源码分析，不涉及到怎么修改MySQL源码来实现一些定制化的功能。

## MySQL源码介绍

这一讲中，我们就以当前8.0系列中最新的Release版本8.0.40为例，下载代码并解压。我们先简单看一下MySQL源码文件的组织（只是为了看结构，下面的输出中，把很多内容删减掉了）。

```plain
# tree -d -L 2
...
├── include
├── mysys
├── plugin
│   ├── auth
│   ├── clone
...
│   ├── group_replication
...
│   ├── semisync
│   └── x
......
├── sql
│   ├── auth
│   ├── binlog
│   ├── changestreams
│   ├── conn_handler
│   ├── containers
│   ├── daemon_proxy_keyring
│   ├── dd
│   ├── examples
│   ├── gis
│   ├── histograms
│   ├── iterators
│   ├── join_optimizer
│   ├── locks
│   ├── memory
│   ├── partitioning
│   ├── protobuf
│   ├── raii
│   ├── range_optimizer
│   ├── server_component
│   └── xa
├── sql-common
│   └── oci
├── storage
......
│   ├── innobase
│   └── temptable
└── vio
```

我们先对源码中的一部分目录做一个简单的介绍。

### plugin

plugin目录下是插件的源码，比如专栏中介绍过的clone插件、semisync插件、group\_replication插件，每个plugin的代码在对应的目录下。

### sql

MySQL Server核心模块的大量源代码都在sql目录下。8.0.40版本中，这个目录下有接近100万行源码。

```plain
# find sql -regextype posix-egrep -regex '(.*\.cc)|(.*\.h)' | \
  xargs wc -l | \
  tail -1

940750 total
```

- sql/sql\_yacc.yy是比较特殊的一个文件，这里定义了MySQL中SQL的语法。
- sql/mysqld.cc里定义了mysqld\_main，这是MySQL数据库启动时调用的入口函数。
- sql/iterators目录下是SQL执行引擎的代码，包括表扫描、索引扫描、表连接的执行。
- sql/sql\_optimizer.cc里的JOIN::optimize是优化器的一个入口函数。
- sql/sql\_parse.cc中的do\_command函数，读取客户端发送过来的请求（命令或SQL），并根据请求的类型进行分发（dispatch\_command）。
- sql/conn\_handler目录中是MySQL处理新建连接请求的代码。默认使用connection\_handler\_per\_thread.cc，也就是给每个客户端分配一个独立的线程，处理客户端的请求。
- sql/dd目录下是数据字典的实现代码。数据字典表的定义，初始化数据库（mysqld --initialize）时怎么创建数据字典表，数据库启动时怎么加载数据字典表，很多代码都在这个目录下。
- sql/log\_event.cc里，定义了不同类型Binlog事件的格式。
- sql/handler.cc里实现了handler类。读取或修改表里的数据，都会通过handler接口来实现。存储引擎继承handler类（比如innodb的ha\_innobase），实现数据的读写功能。

### storage/innobase

storage目录中是MySQL支持的各个存储引擎的实现代码。InnoDB的代码在innobase目录中，代码量接近50万行。

```plain
# find storage/innobase -regextype posix-egrep -regex '(.*\.cc)|(.*\.h)|(.*\.ic)' | \
    xargs wc -l | \
    tail -1

460953 total
```

InnoDB的代码，按功能模块，分为多个目录。

```plain
# tree -d -L 1
.
|-- api
|-- arch
|-- btr
|-- buf
|-- clone
|-- data
|-- ddl
|-- dict
|-- eval
|-- fil
|-- fsp
|-- fts
|-- fut
|-- gis
|-- ha
|-- handler
|-- ibuf
|-- include
|-- lob
|-- lock
|-- log
|-- mach
|-- mem
|-- mtr
|-- os
|-- page
|-- pars
|-- que
|-- read
|-- rem
|-- row
|-- srv
|-- sync
|-- trx
|-- usr
`-- ut
```

这里先做一个简单的介绍。

#### include目录

include目录里是InnoDB代码使用的一些头文件。

fil0types.h中定义了InnoDB页面的基本格式，这里定义了页面头部和尾部中各个字段在页面内的偏移地址。

![图片](https://static001.geekbang.org/resource/image/9e/ae/9eac015161963d542f6a045c13af91ae.png?wh=1310x1148)

fsp0fsp.h中定义了文件头（Space Header）的格式，还定义了Inode、区描述符（XDES）等这些用来管理文件空间的数据结构的存储格式。

![图片](https://static001.geekbang.org/resource/image/c4/73/c4201d80fff8378c9d4429a290de5373.png?wh=1326x1314)

page0types.h中定义了B+树页面头的格式。

![图片](https://static001.geekbang.org/resource/image/e1/66/e194558ca269e784f7824c6831051166.png?wh=1302x888)

在代码里搜索这里定义的常量，能很快找到使用这些常量的代码，就能理解这些字段的作用。比如搜索PAGE\_HEAP\_TOP，看到函数page\_mem\_alloc\_heap中会写入这个字段（page0page.cc 243行）。

![图片](https://static001.geekbang.org/resource/image/4e/e4/4e9d538b4b123fec083ba273bebc0ae4.png?wh=1454x1162)

再搜索page\_mem\_alloc\_heap，发现这个函数在insert时被调用（page0cur.cc page\_cur\_insert\_rec\_low），然后就可以看到insert的记录是怎么写到数据块中了（参考page\_cur\_insert\_rec\_low中标了编号的几行代码注释）。

![图片](https://static001.geekbang.org/resource/image/16/34/161017495c4be2412ebfb699dyy9c434.png?wh=1604x1254)

根据这几个头文件，再到代码中搜索和分析使用了这些常量的一些代码，就能整理出[25](https://time.geekbang.org/column/article/804972)、[26](https://time.geekbang.org/column/article/816184)这两讲中的页面物理格式了。

#### rem

rem目录下是定义和操作行记录格式的代码。rem0rec.cc里定义了InnoDB支持的两大类行格式，一类是REDUNDANT格式，也就是注释中的“OLD STYLE”，另一类是Compact类型，包括compact、dynamic、compressed，也就是注释中的“NEW STYLE”。

![图片](https://static001.geekbang.org/resource/image/3b/ce/3b07c08973f62046a21be87cb18ebace.png?wh=1170x1208)

#### page

page目录下主要是操作B+树页面内容的代码，包括创建B+树页面、往页面中插入记录、删除页面中的记录等代码，还有维护页目录项的代码。

#### btr

btr目录下主要B+树相关的代码。B+树是InnoDB中最核心的一个数据结构。这里包括在B+树中查找记录（btr\_cur\_search\_to\_nth\_level）、插入记录（btr\_cur\_optimistic\_insert，btr\_cur\_pessimistic\_insert）、更新记录（btr\_cur\_update\_in\_place、btr\_cur\_optimistic\_update、btr\_cur\_pessimistic\_update）、删除记录（btr\_cur\_optimistic\_delete、btr\_cur\_pessimistic\_delete）的代码，也包括了维护自适应Hash索引的代码。

#### row

row目录下包括了操作行的相关代码，比如插入行（row\_insert\_for\_mysql）、更新或删除行（row\_update\_for\_mysql）、清理行（row\_purge）。

row\_search\_mvcc是这里比较重要的一个函数，从InnoDB中查询数据，包括执行Select语句，或者执行Delete和Update语句时，都会通过这个函数来查询数据。函数row\_vers\_build\_for\_consistent\_read用来构建记录的历史版本。

MySQL Server层和InnoDB层使用了不同的行和字段存储格式，这里提供了格式转换函数，row\_mysql\_convert\_row\_to\_innobase将MySQL行格式转换成InnoDB行格式，row\_sel\_store\_mysql\_rec将InnoDB行格式转换成MySQL行格式。

这里还包括了回滚行操作的代码（row\_undo，row\_undo\_ins，row\_undo\_mod）。

当表上有Online DDL在执行时，对表的DML操作需要记录到在线变更日志中。在线创建索引时，DML操作通过row\_log\_online\_op记录，DDL执行结束前，通过row\_log\_apply函数应用在线变更日志。在线Rebuild表时，表上的DML操作通过row\_log\_table函数来记录，DDL执行完成前，使用row\_log\_table\_apply应用在线变更日志。

#### trx

trx目录中是事务处理的相关代码，包括事务提交（trx\_commit，trx\_commit\_in\_memory, trx\_release\_impl\_and\_expl\_locks）、事务回滚（trx\_rollback\_for\_mysql）。

Undo日志，通过函数trx\_undo\_report\_row\_operation记录。如果想了解事务执行过程中记录了哪些Undo日志以及Undo日志的具体格式，可以分析这个函数。数据库启动时，要执行崩溃恢复，函数trx\_recover\_for\_mysql用来查找处于Prepared状态的事务。这里还包括了回滚段和Undo段处理的相关代码。

#### buf

buf目录中是InnoDB Buffer Pool的实现代码，包括Buffer Pool的结构，Buffer Pool中的各个链表和Hash表。

#### fsp

fsp目录中是InnoDB表空间管理的相关代码，包括分配页面、释放页面空间等。

#### handler

hander目录下是MySQL 存储引擎Handler接口的实现代码。MySQL Server层调用InnoDB Handler代码，读取或写入数据，提交或回滚事务。类ha\_innobase中实现了访问InnoDB数据的函数。

![图片](https://static001.geekbang.org/resource/image/0f/b1/0fd58956828d9fe5de56d4844fbf07b1.png?wh=1356x1446)

函数innodb\_init中设置了一系列给server层调用的函数。加载InnoDB插件时调用这个函数。

![图片](https://static001.geekbang.org/resource/image/08/00/08318a717cyydc968c660e5dceebac00.png?wh=1324x1274)

#### log

log目录下是Redo的相关代码，包括管理Log Buffer空间，分配Log序列号，将Redo日志写入Log Buffer。

log\_writer、log\_flusher、log\_checkpointer这几个是Redo系统的几个关键线程的主函数，负责Redo日志的持久化。数据库启动时，调用log\_start\_background\_threads函数，启动这些线程，以及其他一些线程。

数据库启动时，调用函数recv\_recovery\_from\_checkpoint\_start，扫描和解析checkpoint之后的所有Redo日志。

函数recv\_scan\_log\_recs解析Redo日志，并将解析出来的日志先加到Hash表中。函数recv\_apply\_hashed\_log\_recs应用hash表中的Redo日志。

#### mtr

mtr目录中是Mini Transaction相关代码。mlog\_write开头的一系列函数（mlog\_open\_and\_write\_index，mlog\_write\_string，mlog\_write\_ulint，mlog\_write\_ull，mlog\_write\_initial\_dict\_log\_record等）生成Redo日志，写到mtr buffer中。在这些函数上设置断点，就能看到事务执行过程中会生成哪些Redo日志，以及日志的格式。

mlog\_parse开头的一系列函数（mlog\_parse\_initial\_log\_record，mlog\_parse\_nbytes，mlog\_parse\_string，mlog\_parse\_index等）从Redo文件中解析日志。mtr\_t是一个比较重要的数据结构，m\_impl.m\_memo记录了mtr执行过程中修改的数据块、获取的锁对象和锁模式，m\_impl.m\_log中记录了Redo日志。mtr提交时（mtr\_t::commit），m\_log中的Redo日志复制到Redo Log Buffer，修改过的脏页添加到Flush链表，mtr执行过程中获取的锁，也会在提交时解锁（memo\_slot\_release）。

#### srv

srv目录下，包括了InnoDB一些服务线程的代码，如srv\_master\_thread、srv\_worker\_thread、srv\_purge\_coordinator\_thread、srv\_monitor\_thread、srv\_error\_monitor\_thread。数据库启动时调用srv\_start启动InnoDB。

## 使用代码分析工具

前面对MySQL的代码做了一个非常简单的介绍，还提供了一些比较关键的函数，这些函数可以作为了解MySQL源码的一个起点。但是MySQL的源码，代码文件数多，代码量大，代码风格不统一，函数调用层次比较深。利用一些工具，能帮我们更好地理解这些代码。

有一些代码分析工具，比如SourceInsight，能分析函数、方法、全局变量、结构、类等符号信息。能显示参考树、类继承图和调用树等，直观地展示函数的调用关系、类的继承层次等。还能迅速搜索整个项目，找到符号的定义位置、被调用位置等所有引用，方便追踪代码的执行路径和数据流向。

这里，我介绍一款轻量，但功能强大的源代码编辑器，VSCode。安装上C/C++扩展后，使用VSCode可以方便地分析MySQL源码。VSCode还可以整合编译、调试工具，不过这里我只用了代码分析功能。如果你有兴趣，也可以尝试在VSCode中整合调试工具。

![图片](https://static001.geekbang.org/resource/image/7c/49/7c3a51702a365f9e8ebf135c87b09a49.png?wh=1232x1108)

### 使用VSCode分析代码

接下来就使用VSCode，来分析下数据库崩溃恢复时，怎么处理Prepared状态的事务。[35 讲](https://time.geekbang.org/column/article/821006)中的“二阶段提交”这一小节中，提到过Prepared状态的事务，在数据库启动时是提交还是回滚，取决于Binlog中是否存在对应的XID事件。

#### 函数trx\_recover\_for\_mysql

innobase/trx/trx0trx.cc中有一个函数trx\_recover\_for\_mysql，看起来和崩溃恢复有关，我们就从这个函数开始分析。

![图片](https://static001.geekbang.org/resource/image/37/2d/3758b4b80b540bb194a699ab430b8b2d.png?wh=1438x1246)

这个函数的逻辑比较简单，就是统计trx\_sys-&gt;rw\_trx\_list中状态为TRX\_STATE\_PREPARED的事务，函数的返回值就是Prepared状态的事务数。

这里还调用了一个函数get\_info\_about\_prepared\_transaction，可以直接跳转到函数的定义中。这里还有一点值得注意，函数get\_info\_about\_prepared\_transaction的第一个参数，传入了一个指针，指向trx\_list的第N个元素，调用这个函数后，就把第N个Prepared状态的事务加到了trx\_list中。

![图片](https://static001.geekbang.org/resource/image/e5/00/e568f3a25665d79a15992db0464b9500.png?wh=1300x726)

#### 链表trx\_sys-&gt;rw\_trx\_list的数据从哪里来？

那么数据库启动时，rw\_trx\_list里的数据是从哪里来的呢？使用查找功能（CMD + SHIFT + F）进行搜索，发现trx0trx.cc中有一处代码会往这个列表中插入数据（UT\_LIST\_ADD\_FIRST）。

![图片](https://static001.geekbang.org/resource/image/a3/27/a3287ceb3f5584786b0543b8e975b427.png?wh=1104x1284)

查看代码，这里只是封装了一个函数trx\_add\_to\_rw\_trx\_list。

![图片](https://static001.geekbang.org/resource/image/f7/7e/f7a6df33afd59051f08810339e0e6f7e.png?wh=1216x382)

接下来要看哪些地方调用了这个函数。这里可以使用全局搜索，也可以使用“查找所有引用”（快捷键ALT + SHIFT + F12）。

![图片](https://static001.geekbang.org/resource/image/44/9d/4493a08f7276c0e2ffa2fb19fa50389d.png?wh=1100x398)

调用这个函数的地方不多，分别查看后，trx\_sys\_init\_at\_db\_start应该是我们想找的函数。

**函数trx\_sys\_init\_at\_db\_start**

![图片](https://static001.geekbang.org/resource/image/fb/f6/fb8641c87924d985ed64409c8f12d6f6.png?wh=1244x1282)

这个函数中主要做了几件事情。

- 扫描每一个Undo表空间中的每一个回滚段，调用trx\_resurrect函数，读取回滚段中所有的Undo段，把未完成的事务识别出来。trx\_resurrect函数中最终会调用trx\_sys\_rw\_trx\_add，把事务加到trx\_sys-&gt;shars中。

<!--THE END-->

![图片](https://static001.geekbang.org/resource/image/6f/a4/6f6faac61ea3a23563e7521ab9byy7a4.png?wh=1228x634)

- 事务加到trxs，按事务ID排序后，加到trx\_sys-&gt;rw\_trx\_list中。

当然，你还可以继续分析回滚段、Undo段中的数据怎么读取。

![图片](https://static001.geekbang.org/resource/image/1b/53/1bcf3712cd2d54b41294aff1f19a5753.png?wh=1184x920)

函数trx\_resurrect中用到了rseg-&gt;insert\_undo\_list，rseg-&gt;update\_undo\_list，分析这几个列表的数据怎么添加，最终可能会发现下面这个调用链路。这里我就不具体展开了。

```plain
trx_rsegs_init -> trx_rseg_mem_create -> 
 -> trx_undo_lists_init -> trx_undo_mem_init
```

你还可以分析trx\_sys\_init\_at\_db\_start是什么时候调用的。最终你可能会发现大致的调用链路是这样的。

```plain
mysqld_main -> process_bootstrap -> dd::init -> Dictionary_impl::init 
 -> bootstrap::initialize -> DDSE_dict_init -> innobase_ddse_dict_init
 -> innobase_init_files -> srv_start -> trx_sys_init_at_db_start
```

当然你也可以在调试器中设置断点，代码运行到trx\_sys\_init\_at\_db\_start时，查看调用栈，这样更方便，也更准确。不过直接阅读源码进行分析也是一个很好的练习。

#### 事务是怎么恢复的

上面我们只是分析了怎么从Undo表空间中把未完结的事务扫描出来。但是这些事务具体是怎么恢复的呢？

回到trx\_recover\_for\_mysql这个函数，谁调用了这个函数呢？很快就找到了innobase\_xa\_recover。

![图片](https://static001.geekbang.org/resource/image/c3/c2/c3ece1379b6d0df0fa8f86b3dff6e1c2.png?wh=1248x678)

谁调用了innobase\_xa\_recover呢？你会发现代码中并没有直接调用这个函数。但是innodb\_init中，这个函数赋值给了innobase\_hton-&gt;recover这个函数指针。执行innobase\_hton-&gt;recover时，实际上就是在执行innobase\_xa\_recover。

![图片](https://static001.geekbang.org/resource/image/e1/56/e1c715bde8252792d1390a08bcbe6e56.png?wh=1276x378)

你可以试着查一下hton-&gt;recover在哪里调用。直接搜索innobase\_hton-&gt;recover或hton-&gt;recover找不到调用的地方，因为在调用的地方，变量名不是innobase\_hton或hton。改成搜索“-&gt;recover(”，可以找到调用的地方。

![图片](https://static001.geekbang.org/resource/image/89/ce/89f66432686e33f3ed487b40d997d5ce.png?wh=1096x816)

**recover\_one\_ht**

recover\_one\_ht中调用了ht-&gt;recover。我们已经知道，调用recover时，会把Prepared状态的事务加到trx链表中，也就是这里的info-&gt;list中。

![图片](https://static001.geekbang.org/resource/image/11/b6/1181ac9378f0fe25cf1a26c32aa2b8b6.png?wh=1294x1390)

208行的循环中，依次处理每一个事务，调用函数recover\_one\_external\_trx或recover\_one\_internal\_trx恢复事务。这个专栏中，没有涉及到XA事务，这里只分析recover\_one\_internal\_trx。

**recover\_one\_internal\_trx**

函数recover\_one\_internal\_trx中，会判断info.commit\_list中是否有当前处理的事务的XID，如果有，就执行ht.commit\_by\_xid提交事务，如果没有，就执行ht.rollback\_by\_xid回滚事务。

![图片](https://static001.geekbang.org/resource/image/4a/19/4a4f8046233534b781bfa72ceea02519.png?wh=1480x1310)

**commit\_list**

接下来我们要分析commit\_list。commit\_list作为参数传给ha\_recover函数。

![图片](https://static001.geekbang.org/resource/image/9f/db/9fd2c3745097cdf69698d7da27c524db.png?wh=1236x702)

**Binlog\_recovery::recover**

ha\_recover由函数Binlog\_recovery::recover调用，传入的参数是this-&gt;m\_internal\_xids。这里的this，就是Binlog\_recovery对象。

![图片](https://static001.geekbang.org/resource/image/a5/50/a50bf808bda0b7bec7dbc4dcc41f7d50.png?wh=1306x448)

**m\_interal\_xids**

再搜索m\_internal\_xids，可以找到Binlog\_recovery::process\_xid\_event函数中会把XID加进来。

![图片](https://static001.geekbang.org/resource/image/38/87/380d8b2648e4bb7058802fe61fd60f87.png?wh=1250x552)

**Binlog\_recovery::recover**

Binlog\_recovery::recover函数中会调用process\_xid\_event。64行的循环中，读取Binlog文件中的每一事件，如果读取到一个XID事件，就把XID加到m\_interal\_xids中。

![图片](https://static001.geekbang.org/resource/image/a2/3f/a2ac3d05570e55614c6a89ed8a3e1a3f.png?wh=1308x1246)

**open\_binlog**

Binlog\_recovery::recover在函数open\_binlog中调用。open\_binlog判断当前的Binlog是不是数据库崩溃时在使用的，这实际上是根据Binlog头部的FORMAT\_DESCRIPTION\_EVENT事件中，是否有LOG\_EVENT\_BINLOG\_IN\_USE\_F标记来判断的。如果有这个标记，就执行Binlog\_recovery::recover，读取Binlog中的所有XID，调用ha\_recover处理Prepared状态的事务。

![图片](https://static001.geekbang.org/resource/image/a5/f1/a59c65225cb7e682f14d48d2d8786df1.png?wh=1324x962)

继续分析，能找到下面这个调用链路。

```plain
mysqld_main -> init_server_components -> open_binlog 
  -> Binlog_recovery::recover -> ha_recover
```

上面分析了Prepared状态的事务，在恢复时的处理逻辑。

继续搜索trx\_sys-&gt;rw\_trx\_list，还能找到活动的事务的处理过程。

![图片](https://static001.geekbang.org/resource/image/62/a7/62b5096ed7b7abe15e45aa9be3ae21a7.png?wh=1920x1006)

从代码中，还能找到下面这个调用链路。

```plain
trx_recovery_rollback_thread -> trx_recovery_rollback 
  -> trx_rollback_or_clean_recovered -> trx_rollback_or_clean_resurrected
```

trx\_recovery\_rollback\_thread是回滚线程的主函数，这个线程在srv\_start\_threads\_after\_ddl\_recovery中创建。

![图片](https://static001.geekbang.org/resource/image/8d/82/8d701f49fc516e79f3e50047b8d79482.png?wh=1312x710)

调用链路大概这这样的。

```plain
mysqld_main -> init_server_components -> ha_post_recover 
  -> post_recover_handlerton -> post_recover 
  -> innobase_post_recover -> srv_start_threads_after_ddl_recovery
```

## 使用GDB调试MySQL源码

现在我们对MySQL的源码结构已经有了一定的了解，并且可以借助一些工具来分析源码。但是，MySQL是不是一定按我们理解的方式在运行呢？毕竟MySQL有上百万行代码，看代码时，有时候很容易忽略掉一些细节。而且有些情况下，代码比较复杂，并不一定能完全理解代码的含义。

- 传给函数的参数取什么值是怎么确定的？比如函数row\_search\_mvcc的参数中，参数mode、prebuilt、match\_mode是怎么确定的，和执行的SQL有什么关系？
- 函数执行时，会走到哪个分支？
- 事务提交过程中，执行到哪一行代码后，修改的数据对其他会话可见？

使用调试器，就能观察程序在运行时的状态，查看参数和变量具体的值，分析函数的调用栈。还能使用调试器来构建一些边界条件。比如要调试Prepared事务在恢复时的处理逻辑，就得先生成一些Prepared状态的事务，然后重启数据库。使用调试器，就能让事务停留在Prepared状态。

接下来，我会通过一些调试场景，来初步介绍GDB的一些用法。

先准备一个调试环境，Build一个Debug版本的MySQL，创建一个数据库。具体的步骤在[第1讲](https://time.geekbang.org/column/article/801720)介绍过，这里就不重复了。

如果遇到下面这样的报错，很可能是gdb的版本太低，可以安装一个高版本的试试。

```plain
Reading symbols from /usr/local/mysql/bin/mysqld...
Dwarf Error: wrong version in compilation unit header (is 5, should be 2, 3, or 4) [in module /usr/local/mysql/bin/mysqld]
(no debugging symbols found)...
done.
```

我的测试环境是CentOS 7.9的系统，用了devtoolset-11。

```plain
yum install devtoolset-11-gdb
source /opt/rh/devtoolset-11/enable
```

### SQL如何执行？

[第 8 讲](https://time.geekbang.org/column/article/804972)中介绍过“SELECT语句是怎么执行的”，到gdb中验证一下。先运行gdb，attach到mysqld进程。先给do\_command函数设置一个断点（break do\_command），执行continue命令。

```plain
# gdb /opt/mysql8.0/bin/mysqld 12312
GNU gdb (GDB) Red Hat Enterprise Linux 10.2-6.el7


(gdb) break do_command
Breakpoint 1 at 0x330a841: file /root/buildenv/mysql-8.0.40/sql/sql_parse.cc, line 1311.
(gdb) c
Continuing.
```

连接到MySQL，执行一个简单的SQL语句。

```plain
mysql> select * from ta;
```

执行next命令，单步跟踪。执行完dispatch\_command后，你会发现SQL执行完成了。

```plain
Thread 44 "connection" hit Breakpoint 1, do_command (thd=0x7fa5d8017480)
    at /root/buildenv/mysql-8.0.40/sql/sql_parse.cc:1311
1311	  NET *net = nullptr;
(gdb) n
1312	  enum enum_server_command command = COM_SLEEP;
(gdb)
1314	  DBUG_TRACE;
(gdb)
1315	  assert(thd->is_classic_protocol());
(gdb)
1321	  thd->lex->set_current_query_block(nullptr);
(gdb)
1329	  thd->clear_error();  // Clear error message
......
1438	  DEBUG_SYNC(thd, "before_command_dispatch");
(gdb)
1440	  return_value = dispatch_command(thd, &com_data, command);
(gdb)
```

所以需要跟踪到dispatch\_command函数里面去。可以在这里设置一个断点，或者使用step命令。

这里我们在sql\_parse.cc的1440行设置一个断点，运行到这里后，执行step命令进到函数dispatch\_command里。执行backtrace命令查看调用堆。

```plain
(gdb) break /root/buildenv/mysql-8.0.40/sql/sql_parse.cc:1440
```

![图片](https://static001.geekbang.org/resource/image/23/2b/235a75620a9b87c287yy949a9c11512b.png?wh=1306x638)

类似这样，你可以继续单步跟踪执行。因为我们知道查询数据时，会调用row\_search\_mvcc获取记录，因此就给函数row\_search\_mvcc设置一个断点。

```plain
(gdb) break row_search_mvcc
Breakpoint 3 at 0x4c85040: file /root/buildenv/mysql-8.0.40/storage/innobase/row/row0sel.cc, line 4423.


(gdb) continue
Continuing.

Thread 44 "connection" hit Breakpoint 3, row_search_mvcc (buf=0x7fa5d8008420 "\375\351\a",
    mode=PAGE_CUR_G, prebuilt=0x7fa5d8b3c9a8, match_mode=0, direction=0)
    at /root/buildenv/mysql-8.0.40/storage/innobase/row/row0sel.cc:4423
4423	  DBUG_TRACE;
```

查看调用堆，可以看到很多函数调用。

![图片](https://static001.geekbang.org/resource/image/47/ae/4773982b0775803a5d866247acd3e0ae.png?wh=1494x1172)

经过一些分析，发现sql\_union.cc的1771行可能有我们感兴趣的代码。

![图片](https://static001.geekbang.org/resource/image/2e/c9/2e7d23a7f353b85210019c0b2b96d9c9.png?wh=1184x1234)

在函数ExecuteIteratorQuery中，可以看到SQL引擎的一个基本执行过程。

- 1771行，调用存储引擎接口，获取数据。
- 1774行，判断存储引擎的返回码，如果数据取完了，就退出for循环。如果有异常，直接返回。
- 1786行，调用send\_data，将数据发送给客户端。
- 1798行，数据取完了，发送一个结束标记给客户端。

但是，再仔细观察一下，你可能会有一个疑惑，存储引擎中获取的记录，是怎么传递给send\_data函数的呢？从函数的返回值、参数中都看不出来。

回到前面这个调用栈，可以发现一些线索。

![图片](https://static001.geekbang.org/resource/image/5c/a7/5cd8d59d0e84300355ef80189b137ca7.png?wh=1492x494)

handler::ha\_index\_first有一个buf参数，分析代码（row\_search\_mvcc）后可以知道，InnoDB是将查到的记录写到了这个buf中。

这个参数是IndexScanIterator::Read中传入的。

![图片](https://static001.geekbang.org/resource/image/eb/1e/ebb83f5c085e32621d9b75e6dc344b1e.png?wh=950x594)

这个m\_record又是从哪里来的呢？这是IndexScanIterator类的一个成员，在构造函数中初始化成table-&gt;record\[0]。

![图片](https://static001.geekbang.org/resource/image/de/05/ded72d8b98ebcced2b121ae854f22505.png?wh=1372x706)

我们可以在IndexScanIterator的构造函数上加一个断点。

```plain
(gdb) break IndexScanIterator<true>::IndexScanIterator
Breakpoint 4 at 0x389096e: file /root/buildenv/mysql-8.0.40/sql/iterators/basic_row_iterators.cc, line 67.

(gdb) break IndexScanIterator<false>::IndexScanIterator
Breakpoint 5 at 0x3890bd8: file /root/buildenv/mysql-8.0.40/sql/iterators/basic_row_iterators.cc, line 67.

(gdb) c
Continuing.

Thread 44 "connection" hit Breakpoint 5, IndexScanIterator<false>::IndexScanIterator (this=0x7fa5d8af8d28, thd=0x7fa5d8017480, table=0x7fa5d80063a0, idx=0, use_order=false, expected_rows=4,
    examined_rows=0x7fa5d8af7ea0) at /root/buildenv/mysql-8.0.40/sql/iterators/basic_row_iterators.cc:67
67	      m_examined_rows(examined_rows) {}
```

就可以看到这样的调用栈，看起来是在优化SQL的时候传进来的table变量。

![图片](https://static001.geekbang.org/resource/image/f9/b8/f9da9c2237c9c3ba4e652f80a8192fb8.png?wh=1504x1170)

这里的table是一个重要的结构，我们说的Open table cache里缓存的，是不是就是这个table结构呢？

可以用print命令查看变量table的值。

![图片](https://static001.geekbang.org/resource/image/04/d8/049979a61c499491c564a3f3fed2b1d8.png?wh=1440x392)

好了，这个调试案例就先到这儿。借助GDB，我们分析了一个简单的SELECT语句执行的基本步骤，我们还知道了MySQL Server层和InnoDB存储引擎之间，是通过TABLE结构体的record buffer来传递数据的。

### 数据库启动流程分析

上一个案例中，我们使用gdb attach到一个运行中的mysqld进程上进行调试。如果要调试MySQL的启动过程，就要在gdb中启动MySQL。

我们先看一下当前mysqld进程的运行参数。

```plain
# ps -elf | grep mysqld 

... /opt/mysql8.0/bin/mysqld --defaults-file=/data/mysql8.0/my.cnf --basedir=/opt/mysql8.0 --datadir=/data/mysql8.0/data --plugin-dir=/opt/mysql8.0/lib/plugin --user=mysql --log-error=/data/mysql8.0/log/alert.log --open-files-limit=1024 --pid-file=/data/mysql8.0/run/mysqld.pid --socket=/data/mysql8.0/run/mysql.sock --port=3380
```

启动gdb，加载mysqld。

```plain
# gdb /opt/mysql8.0/bin/mysqld
GNU gdb (GDB) Red Hat Enterprise Linux 10.2-6.el7
```

设置断点，比如在崩溃恢复的一些函数上设置断点。

```plain
(gdb) break trx_sys_init_at_db_start
Breakpoint 1 at 0x4d3627f: file /root/buildenv/mysql-8.0.40/storage/innobase/trx/trx0sys.cc, line 440.

(gdb) break open_binlog
Breakpoint 2 at 0x44e2953: open_binlog. (2 locations)

(gdb) break recv_recovery_from_checkpoint_start
Breakpoint 3 at 0x4b5afee: file /root/buildenv/mysql-8.0.40/storage/innobase/log/log0recv.cc, line 3770.

(gdb) break do_command
```

然后用run命令，启动MySQL。

```plain
(gdb) run --defaults-file=/data/mysql8.0/my.cnf --basedir=/opt/mysql8.0 --datadir=/data/mysql8.0/data --plugin-dir=/opt/mysql8.0/lib/plugin --user=mysql --log-error=/data/mysql8.0/log/alert.log --open-files-limit=1024 --pid-file=/data/mysql8.0/run/mysqld.pid --socket=/data/mysql8.0/run/mysql.sock --port=3380
```

会先运行Redo恢复。

![图片](https://static001.geekbang.org/resource/image/ed/39/edd683ddaed1dbfc96138e1c61d3cc39.png?wh=1462x826)

运行fininish命令，执行完recv\_recovery\_from\_checkpoint\_start后，可以接着调试。

```plain
(gdb) fin
Run till exit from #0  recv_recovery_from_checkpoint_start (log=..., flush_lsn=43940320)
    at /root/buildenv/mysql-8.0.40/storage/innobase/log/log0recv.cc:3770
0x0000000004cc4cea in srv_start (create_new_db=false)
    at /root/buildenv/mysql-8.0.40/storage/innobase/srv/srv0start.cc:1986
1986	    err = recv_recovery_from_checkpoint_start(*log_sys, flushed_lsn);
Value returned is $1 = DB_SUCCESS
```

你会发现接下来先运行到trx\_sys\_init\_at\_db\_start处的断点，然后再运行到open\_binlog。在一些关键的代码点上设置断点，可以观察到一些代码的运行顺序。比如数据库启动时，先执行Redo，再执行Undo。

### GDB命令参考

gdb的功能很强大，我把一些基本的命令整理到了下面这个表格中。可以使用命令的简称，比如执行c就是执行continue命令。

![](https://static001.geekbang.org/resource/image/e0/26/e0e511f84ab77a348fe6eaebb6b74826.jpg?wh=1928x1412)

## 总结

MySQL使用C/C++编写，因此理论上，你只要熟悉C/C++，就能看懂MySQL的实现。当然，由于MySQL的代码量比较多，分析这些代码需要花比较多的时间。这一讲中提到的一些方法，可以供你参考，更重要的其实是花大量的时间去尝试。

## 思考题

MySQL是一个多线程的服务器，代码运行到一个断点时，所有线程都会暂停运行。有些情况下，我们可能只想调试其中一个线程，调试过程中，其他线程要保持运行状态。使用GDB，怎么实现这一点呢？

期待你的思考，欢迎在留言区中与我交流。如果今天的课程让你有所收获，也欢迎转发给有需要的朋友。我们下节课再见。
<div><strong>精选留言（2）</strong></div><ul>
<li><span>小猪猪猪蛋</span> 👍（1） 💬（1）<p>讲的非常详细，一步一步跟下来 受益匪浅！ 谢谢老师</p>2024-12-16</li><br/><li><span>hDEC2突变</span> 👍（0） 💬（1）<p>进入某个线程用thread n ，info threads显示当前的所有线程，正在运行的前面有*号
老师，有个问题，就是p thread_id和info threads里面的线程id都不对应，我想知道某个函数运行的时候调用的哪个线程，如何确定？</p>2025-01-27</li><br/>
</ul>