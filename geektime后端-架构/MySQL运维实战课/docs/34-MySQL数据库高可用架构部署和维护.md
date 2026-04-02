你好，我是俊达。

从这一讲开始，我们来聊一聊怎么构建和运维MySQL高可用环境。高可用的重要性和必要性，这里就不多说了。实现高可用，需要在IT系统的整个链路上消除单点。MySQL要实现高可用，最基本的就是数据复制技术。

## MySQL数据复制技术简介

数据复制是MySQL一直以来最受欢迎的功能之一。应用程序访问主库，对主库的修改操作都记录到Binlog中。备库从主库同步Binlog、执行Binlog，这样，备库和主库始终保持一致。

![图片](https://static001.geekbang.org/resource/image/35/0b/35201d05c58c91f74a2b704f35a1b80b.jpg?wh=1195x765)

基于数据复制，可以实现多种高可用架构。

- 高可用

应用程序只访问主库，备库作为主库的热备。当主库发生故障，或者主库需要停机维护时，将业务流量切到备库上，减少停机时间。在备库上进行数据库备份等运维操作。

![图片](https://static001.geekbang.org/resource/image/cc/4b/cc4fdaed31d6129394d901e5da68b54b.png?wh=818x254)

- 读写分离

将应用的一部分读流量分发（select）到备库上执行。MySQL支持一主多备的数据复制架构，在读多写少的场景下，可以增加多个备库，来提高数据库集群的业务支撑能力。

![图片](https://static001.geekbang.org/resource/image/53/0a/536d21d821b25ed860e790b7b5e8300a.jpg?wh=1228x558)

还可以使用备库来支持一些分析类的大查询、数据抽取等资源消耗较高的操作，避免影响主库业务。

- 报表库

![图片](https://static001.geekbang.org/resource/image/9a/71/9a298065bfea34a5605ayy845fdbd871.jpg?wh=1140x564)

### MySQL数据复制的基本原理

我们把整个数据库看作是一个状态。每个事务将数据库转换到一个新的状态。虽然主库上事务可以并发执行，但是事务具备原子性和隔离性，因此可以设想主库的事务按顺序执行。如果备库和主库拥有相同的初始状态，并且按相同的顺序执行主库上执行过的事件，那么备库和主库就应该是完全一致的。

下面这张图中，备库先同步了状态Y的主库，然后再开始执行Binlog事件。

![图片](https://static001.geekbang.org/resource/image/a7/99/a738a444b3dddc551d17104a597ce999.jpg?wh=1296x607)

搭建一个备库，有两个核心步骤。

第一步：同步初始状态。有几种常用的方法来设置备库的初始状态。

- 使用第9讲、第10讲中介绍的数据导入导出工具，比如mysqldump。
- 使用物理备份工具，如xtrabackup。
- 在MySQL 8.0中，你也可以使用clone插件。
- 使用文件系统或块设备的快照功能，得到主库的一个一致的快照。

当然，如果主库和备库都是刚刚新安装的，那么它们当前的状态应该是一样的，就可以跳过这一步了。

第二步：应用Binlog。

MySQL将一个事务中对数据库做的所有修改都封装到Binlog事件中，同一个事务的Binlog事件，在binlog文件中连续存放。假设在第一步中备库初始化到状态Y，这个状态下，主库上Binlog位点指向事务y对应的binlog事件的结尾处，那么备库就要从这个地方开始同步和应用Binlog。

![图片](https://static001.geekbang.org/resource/image/6c/fb/6c920ce2d34c43656888bcf87222c2fb.jpg?wh=1380x726)

binlog位点使用（bin\_log\_file，bin\_log\_pos）来表示，bin\_log\_file是binlog文件名，bin\_log\_pos是binlog文件中的偏移量，指向下一个要执行的binlog事件的起始地址。

当然，这里面还有很多细节没讲。

- 主库和备库之间的关系如何建立？如何判断备库是否健康？
- 备库会不会影响主库上事务的执行和提交？主库提交事务时，要等待备库确认吗？
- 主库上事务可以并行执行，那么备库上事务是不是也能并行执行，怎么执行？
- 主库或备库崩溃后，数据复制是否会出现异常？

别急，这些问题后续都会一一解答。

## 搭建一套主备复制环境

接下来我们通过一个例子来演示如何搭建一个基本的主备复制环境。

### 1. 主库开启binlog

主库要先开启binlog。

```plain
server_id=100
log_bin=/data/mysql3306/binlog/mysql-binlog
binlog_format=ROW

#enforce_gtid_consistency=ON
#gtid_mode=ON
```

- server\_id：主备库server\_id要设置成不同的值。
- log\_bin：binlog文件的前缀，可以指定绝对路径，也可以只指定文件名。如果不指定路径，binlog默认存放在datadir目录中。这里我们将binlog放到了单独的目录中。如果不配置这个参数，在8.0中，binlog默认也是开启的。
- binlog\_format：可设置为STATEMENT、MIXED、ROW这几种模式。一般建议使用ROW模式。

上面这些参数中，log\_bin不能动态修改，需要重启mysql才能生效。

使用show global variables确认主库binlog已经开启。

```plain
mysql> show variables like 'log_bin%';
+---------------------------------+-------------------------------------------+
| Variable_name                   | Value                                     |
+---------------------------------+-------------------------------------------+
| log_bin                         | ON                                        |
| log_bin_basename                | /data/mysql3306/binlog/mysql-binlog       |
| log_bin_index                   | /data/mysql3306/binlog/mysql-binlog.index |
| log_bin_trust_function_creators | OFF                                       |
| log_bin_use_v1_row_events       | OFF                                       |
+---------------------------------+-------------------------------------------+
```

使用show binary logs命令查看主库binlog列表：

```plain
mysql> show binary logs;
+---------------+-----------+
| Log_name      | File_size |
+---------------+-----------+
| binlog.000001 |       120 |
+---------------+-----------+
1 row in set (0.00 sec)
```

### 2. 主库创建复制账号

主库要创建一个复制账号。备库会使用复制账号连接到主库，获取binlog。

```plain
mysql> create user 'rep'@'%' identified by 'rep123';
Query OK, 0 rows affected (0.00 sec)

mysql> grant replication client, replication slave on *.* to 'rep'@'%';
Query OK, 0 rows affected (0.00 sec)
```

复制账号需要replication slave权限，一般我会将replication client权限也赋给复制账号。

### 3. 备库参数配置

备库上也要设置参数server\_id，server\_id的值要和主库设置成不一样。如果要搭建级联复制或双主架构，备库上也要开启binlog，并设置log\_slave\_updates，这样，当备库执行了从主库上复制过来的事务后，会在自己的Binlog中记录相关的事件。

下面这个配置文件中，设置了一些最基本的参数。

```plain
server_id=236
log_bin=/data/mysql3306/binlog/mysql-binlog
binlog_format=ROW

log_slave_updates=ON
relay_log=/data/mysql3306/relaylog/relaylog
```

- server\_id，和主库设置成不一样的值。
- log\_slave\_updates，记录从主库复制过来的binlog。
- relay\_log，设置releylog的存放路径，这里将relaylog放到单独的目录中。

### 4. 初始化备库的数据

可以用物理备份（如percona开源的xtrabackup）、mysqldump等工具创建主库的一致性备份，并恢复到备库中。如果主备库都是新初始化的数据库实例，主库binlog没有缺失，也可以跳过这个步骤，直接开启复制。

下面这个例子中，用mysqldump创建了一个全库的一致性备份，可以用这个备份文件来初始化一个备库。

```plain
mysqldump -uroot -h127.0.0.1 -P3306 -pabc123 \
   --single-transaction \
   --all-databases \
   --master-data=2 \
   --routines \
   --triggers \
   --events \
   --flush-privileges > /data/backup/mysql3306_dump.sql
```

这里的参数需要做一些说明。

- –single-transaction：使用innodb的一致性读取机制实现一致性数据库备份，不锁表。但是对非InnoDB引擎（如MyISAM）无效。同时备份过程中不能有DDL。
- –all-databases --routines --triggers --events：备份所有数据库，包括存储过程、触发器、定时事件。
- –master-data=2：记录数据库当前binlog位点。指定master-data后，会自动加上lock-tables选项，锁定数据库。我们这个案例中，加上–single-transaction，所以不会锁表。
- –flush-privileges：备份完mysql数据库后，加上flush privileges命令。数据恢复时，恢复完mysql数据库后就会执行flush privileges命令，恢复出来的用户信息才会生效。
- –gtid-mode=auto：如果数据库开启了GTID，则备份文件中会加入set global GTID\_PURGED=xxx;。

当然，正式的环境中，在主库上执行备份可能会带来一些性能开销，这里的开销包括获取全局锁，以及导出数据时会消耗一些资源。操作前要评估好对业务的影响。我们的例子中，使用了master-data=2来获取发起备份时，主库的binlog位点。备份文件恢复到备库后，要从这个位点开始同步binlog。

在备库上，恢复刚才生成的备份文件。

```plain
# mysql -uroot -h127.0.0.1 -P3306 -psomepass -e 'set sql_log_bin=0; source mysql3306_dump.sql;'
```

由于mysqldump生成的逻辑备份默认包含了DROP操作，我们在恢复数据时，临时关闭了binlog，不然在双主架构下，可能会导致主库的库表被DROP。

### 5. 备库创建复制通道

备库数据恢复完成后，就可以执行命令建立到主库的复制关系。先从备份文件中找到Binlog位点。

```plain
# head -40 /data/backup/mysql3306_dump.sql | grep 'CHANGE MASTER TO'
-- CHANGE MASTER TO MASTER_LOG_FILE='mysql-binlog.000001', MASTER_LOG_POS=1040;
```

然后再执行命令，建立复制关系，启动复制，查看复制状态。

```plain
mysql> change replication source to source_host='172.16.121.234',source_port=3306,source_user='rep',source_password='rep123',source_log_file='mysql-binlog.000001', source_log_pos=1040, get_source_public_key=1;

mysql> start replica;

mysql> show replica status\G
*************************** 1. row ***************************
             Replica_IO_State: Waiting for source to send event
                  Source_Host: 172.16.121.234
                  Source_User: rep
                  Source_Port: 3306
                Connect_Retry: 60
              Source_Log_File: mysql-binlog.000001
          Read_Source_Log_Pos: 1572
               Relay_Log_File: relaylog.000002
                Relay_Log_Pos: 861
        Relay_Source_Log_File: mysql-binlog.000001
           Replica_IO_Running: Yes
          Replica_SQL_Running: Yes
```

上面的命令中，加上了get\_source\_public\_key选项，可以避免下面这个报错。

```plain
Last_IO_Error: error connecting to master 'rep@172.16.121.234:3306' - retry-time: 60 retries: 1 message: Authentication plugin 'caching_sha2_password' reported error: Authentication requires secure connection.
```

如果遇到了上面这个报错，也没有关系，执行下面这几个命令，设置get\_source\_public\_key就可以了。

```plain
mysql> stop replica;

mysql> change replication source to get_source_public_key=1;

mysql> start replica;
```

## 开启GTID复制

用Binlog位点来建立复制，存在一个问题，在级联复制架构下，调整复制关系时，确定新主库的Binlog位点比较麻烦。为了解决这个问题，MySQL从5.6开始引入了GTID。开启GTID之后，主库上提交的每一个事务都有一个全局唯一的ID，并且事务复制到备库时，这个GTID也不会变。使用GTID有很多优点。

- MySQL会把每一个提交的事务的GTID记录下来，这样可以避免重复执行同一个事务。如果没有开启GTID，建立复制关系时，如果指定的位点不对，可能会重复执行事务，引起主备数据不一致或复制中断。
- 建立复制关系时，MySQL可以根据当前实例已经执行过的GTID事务，来自动判断需要同步主库的哪些binlog，不再需要指定具体的Binlog位点。

GTID由两部分组成：server\_uuid和事务序列号。初始化数据库时，会生成一个全局唯一的server\_uuid，server\_uuid保存在datadir下的auto.cnf中。

```plain
# cat auto.cnf
[auto]
server-uuid=e7ce5684-09b8-11ee-9dd0-fa8338b09400
```

如果删除auto.cnf，重启实例时会重新生成一个server\_uuid。事务序列号在事务提交时按顺序生成。

搭建开启GTID的复制架构，操作步骤上和搭建基于位点的复制差别不大，下面我们主要讨论不同的几个地方。

### 1. 主库开启GTID

除了常规的参数，主库上还要设置gtid\_mode、enforce\_gtid\_consistency参数

```plain
enforce_gtid_consistency=ON
gtid_mode=ON
```

### 2. 备库配置

5.6版本开启GTID时，备库上要开启binlog，并设置log-slave-updates参数，否则数据库会无法启动。

```plain
log_bin=/data/mysql5.6/binlog/mysql-binlog
log_slave_updates=ON
binlog_format=ROW
enforce_gtid_consistency=ON
gtid_mode=ON
```

不过从5.7版本开始，备库不开启binlog和log-slave-updates也可以使用GTID了。

### 3. 备份主库

备份主库时，要记录主库的gtid\_executed变量。前面的例子中，我们使用了mysqldump来备份数据库，选项gtid-mode默认为auto，如果主库使用了GTID，生产的备份文件中已经记录了备份时，主库的GTID\_executed变量。这可以从文件中直接看到。

```plain
# more mysql3306_dump.sql
-- MySQL dump 10.13  Distrib 8.0.32, for Linux (x86_64)

......


SET @MYSQLDUMP_TEMP_LOG_BIN = @@SESSION.SQL_LOG_BIN;
SET @@SESSION.SQL_LOG_BIN= 0;

--
-- GTID state at the beginning of the backup
--

SET @@GLOBAL.GTID_PURGED=/*!80000 '+'*/ '7caa9a48-b325-11ed-8541-fab81f64ee00:1-16329,
c1a67221-f9fc-11ed-bffd-fa8338b09400:1-106';
```

### 4. 备库创建复制通道

建立复制通道时，不要指定主库的Binlog位点，要使用source\_auto\_position。

```plain
mysql> change replication source to source_host='172.16.121.234',source_port=3306,source_user='rep',source_password='rep123', source_auto_position=1, get_source_public_key=1;
```

我们在前面的例子中，本来已经建立了基于位点的复制，还可以使用下面这个命令，将复制改成GTID自动定位。replica status的输出中，Auto\_Position为1，说明复制通道使用了自动定位。

```plain
mysql> stop replica;

mysql> change replication source to source_auto_position=1;

mysql> start replica;

mysql> show replica status\G
...
                Auto_Position: 1
              
```

## 管理数据复制

搭建一个MySQL的数据复制集群，操作上不复杂，不过在实际环境中，可能会遇到各种各样的问题，导致数据复制中断，或者主备数据不一致。至少有几十种情况会导致复制中断，这里无法穷举所有的情况。不过当你了解复制的核心原理后，大部分问题都是可以解决的。后面我们也会介绍一些典型的复制异常的案例。

### 理解复制原理

参考下面这个数据复制的架构图。

![图片](https://static001.geekbang.org/resource/image/b7/69/b7yyb5475d3052518byy1b8d27f24269.jpg?wh=1822x845)

我们需要了解几个关键点。

- 用户执行DML操作的过程中，会生成binlog事件，事务提交时，Binlog事件写入到Binlog文件中。
- 备库上，由IO线程负责从主库同步Binlog。IO线程作为一个客户端，连接主库，发起同步Binlog的请求，并接收主库发送过来的Binlog事件，将Binlog事件写到本地的Relaylog中。
- 主库上，Dump线程负责将Binlog发送给备库的IO线程。
- 备库上，SQL线程（使用多线程复制时，SQL线程也称为协调线程）从RelayLog中解析出Binlog事件，并执行Binlog，或将Binlog分发给Worker线程执行。

这里面任何一个环节都有可能会出错。

### 查看复制状态

分析复制相关的问题时，我们经常会用到一些命令，这里先做一个简单的介绍。

- show master status

使用show master status命令查看主库当前的binlog位点。

```plain
mysql> show master status\G
*************************** 1. row ***************************
             File: mysql-binlog.000001
         Position: 61103
     Binlog_Do_DB:
 Binlog_Ignore_DB:
Executed_Gtid_Set: 7caa9a48-b325-11ed-8541-fab81f64ee00:1-16333,
c1a67221-f9fc-11ed-bffd-fa8338b09400:1-106
```

- show binary logs

使用show binary logs命令查看当前实例中的binlog列表。

```plain
mysql> show binary logs;
+---------------------+-----------+-----------+
| Log_name            | File_size | Encrypted |
+---------------------+-----------+-----------+
| mysql-binlog.000001 |     61153 | No        |
| mysql-binlog.000002 |       197 | No        |
+---------------------+-----------+-----------+
```

- mysqlbinlog

mysqlbinlog是一个用来解析binlog内容的命令行工具，我们可以用mysqlbinlog来验证binlog文件是否损坏。下面这个例子中，指定的位点不是某个事件的起始地址，所以会报错。

```plain
# mysqlbinlog --start-position 12345 mysql-binlog.000001
......
ERROR: Could not read entry at offset 12345: Error in log format or read error 1.
ERROR: Event too big
```

- show replica status / show slave status

使用show replica status或show slave status命令查看复制状态。

```plain
mysql> show replica status\G
*************************** 1. row ***************************
             Replica_IO_State: Waiting for source to send event
                  Source_Host: 172.16.121.234
                  Source_User: rep
                  Source_Port: 3306
                Connect_Retry: 60
              Source_Log_File: mysql-binlog.000001
          Read_Source_Log_Pos: 61965
               Relay_Log_File: relaylog.000004
                Relay_Log_Pos: 319
        Relay_Source_Log_File: mysql-binlog.000001
           Replica_IO_Running: Yes
          Replica_SQL_Running: Yes
              Replicate_Do_DB:
          Replicate_Ignore_DB:
           Replicate_Do_Table:
       Replicate_Ignore_Table:
      Replicate_Wild_Do_Table:
  Replicate_Wild_Ignore_Table:
                   Last_Errno: 0
                   Last_Error:
                 Skip_Counter: 0
          Exec_Source_Log_Pos: 61965
              Relay_Log_Space: 834
              Until_Condition: None
               Until_Log_File:
                Until_Log_Pos: 0
           Source_SSL_Allowed: No
           Source_SSL_CA_File:
           Source_SSL_CA_Path:
              Source_SSL_Cert:
            Source_SSL_Cipher:
               Source_SSL_Key:
        Seconds_Behind_Source: 0
Source_SSL_Verify_Server_Cert: No
                Last_IO_Errno: 0
                Last_IO_Error:
               Last_SQL_Errno: 0
               Last_SQL_Error:
  Replicate_Ignore_Server_Ids:
             Source_Server_Id: 119
                  Source_UUID: 7caa9a48-b325-11ed-8541-fab81f64ee00
             Source_Info_File: mysql.slave_master_info
                    SQL_Delay: 0
          SQL_Remaining_Delay: NULL
    Replica_SQL_Running_State: Replica has read all relay log; waiting for more updates
           Source_Retry_Count: 86400
                  Source_Bind:
      Last_IO_Error_Timestamp:
     Last_SQL_Error_Timestamp:
               Source_SSL_Crl:
           Source_SSL_Crlpath:
           Retrieved_Gtid_Set: 7caa9a48-b325-11ed-8541-fab81f64ee00:16333
            Executed_Gtid_Set: 7caa9a48-b325-11ed-8541-fab81f64ee00:1-16333,
c1a67221-f9fc-11ed-bffd-fa8338b09400:1-106
                Auto_Position: 1
         Replicate_Rewrite_DB:
                 Channel_Name:
           Source_TLS_Version:
       Source_public_key_path:
        Get_Source_public_key: 1
            Network_Namespace:
```

监控备库状态时，要关注SQL线程和IO线程的状态，Replica\_IO\_Running和Replica\_SQL\_Running是否都为ON，如果有异常，查看Last\_IO\_Error、Last\_SQL\_Error，分析原因。此外，还要看备库是否有延迟，可以查看Seconds\_Behind\_Source。

这个命令输出内容比较多，下面表格中整理了其中部分字段的含义。  
![图片](https://static001.geekbang.org/resource/image/df/93/df947fac24b72e9b226083c8c4aeb693.png?wh=1920x1173)

使用多线程复制时，有时候还要看各个worker的状态，可以查询performance\_schema.replication\_applier\_status\_by\_worker表。

```plain
mysql> show slave status\G
*************************** 1. row ***************************
               Slave_IO_State: Waiting for source to send event
                  Master_Host: 172.16.121.236
                  Master_User: rpl_user
                  Master_Port: 3306
......
                   Last_Errno: 1205
                   Last_Error: Coordinator stopped because there were error(s) in the worker(s). The most recent failure being: Worker 1 failed executing transaction '0511eeb3-fad6-11ed-9a0f-fab81f64ee00:2000014' at master log binlog.000003, end_log_pos 6574. See error log and/or performance_schema.replication_applier_status_by_worker table for more details about this failure or others, if any.
```

```plain
mysql> select * from performance_schema.replication_applier_status_by_worker\G
*************************** 1. row ***************************
                                           CHANNEL_NAME:
                                              WORKER_ID: 1
                                              THREAD_ID: NULL
                                          SERVICE_STATE: OFF
                                      LAST_ERROR_NUMBER: 1205
                                     LAST_ERROR_MESSAGE: Worker 1 failed executing transaction '0511eeb3-fad6-11ed-9a0f-fab81f64ee00:2000014' at master log binlog.000003, end_log_pos 6574; Lock wait timeout exceeded; try restarting transaction
......
       APPLYING_TRANSACTION_LAST_TRANSIENT_ERROR_NUMBER: 1205
      APPLYING_TRANSACTION_LAST_TRANSIENT_ERROR_MESSAGE: Lock wait timeout exceeded; try restarting transaction
    APPLYING_TRANSACTION_LAST_TRANSIENT_ERROR_TIMESTAMP: 2023-06-06 17:32:33.891670
```

接下来我们看一下数据复制中可能会遇到的一些问题。

### 主库上的问题

主库是整个数据复制的源头，如果主库有问题，那么数据就无法正常复制。这里列举了几种情况。

- 主库异常崩溃可能会导致binlog损坏。如果binlog损坏了，备库的IO线程会中断。

```plain
Last_IO_Error: Got fatal error 1236 from source when reading data from binary log: 'Client requested source to start replication from position > file size'
```

- 主库上清理了Binlog，备库没来得及同步这些binlog。服务器的存储空间是有限的，因此一般会定期清理Binlog。如果备库由于各种原因，没有及时同步这些被清理掉的Binlog，备库就无法正常工作了。

```plain
Got fatal error 1236 from master when reading data from binary log: 'Could not find first log file name in binary log index file'
```

遇到这种情况时，通常的做法是重搭备库。如果你在清理binlog前将binlog备份下来了，那么还可以尝试将备份的binlog应用到备库，避免重搭。

- 主库使用了Statement格式的binlog，并且执行了一些不安全的SQL。这里不安全的SQL，是指同一个SQL在主备库上执行时，会有不同的结果。比如使用了sysdate()函数。

### IO线程相关问题

#### 连接不上主库

IO线程要先连接到主库，然后才能同步Binlog。连接不上主库，可能是网络的问题、复制账号的问题，也可能是主库有异常。

```plain
Last_IO_Error: Error reconnecting to source 'rep@172.16.121.234:3307'. This was attempt 3/86400, with a delay of 60 seconds between attempts. Message: Can't connect to MySQL server on '172.16.121.234:3307' (111)

Last_IO_Error: error connecting to master 'rep@172.16.121.234:3380' - retry-time: 60 retries: 1 message: Authentication plugin 'caching_sha2_password' reported error: Authentication requires secure connection.
```

#### 从错误的位点复制数据

备库上指定了错误的位点时，会出现各种报错。下面提供了一些报错的例子。这些错误也可能是因为主库Binlog损坏了，可以用mysqlbinlog解析主库的binlog，看看是否会报错。

```plain
Last_IO_Error: Got fatal error 1236 from master when reading data from binary log: 'bogus data in log event; the first event 'mysql-binlog.000001' at 12345, the last event read from '/data/mysql3306/binlog/mysql-binlog.000001' at 126, the last byte read from '/data/mysql3306/binlog/mysql-binlog.000001' at 12364.'

Last_IO_Error: Got fatal error 1236 from master when reading data from binary log: 'Client requested master to start replication from position > file size'

Last_IO_Error: Got fatal error 1236 from master when reading data from binary log: 'binlog truncated in the middle of event; consider out of disk space on master; the first event 'mysql-binlog.000002' at 198, the last event read from '/data/mysql3306/binlog/mysql-binlog.000002' at 126, the last byte read from '/data/mysql3306/binlog/mysql-binlog.000002' at 474.'
```

一般如果主库有Binlog损坏了，要检查下主备库的数据是否一致。我们可以尝试从主库的下一个Binlog开始复制。

#### 主库Binlog缺失

这可能是主库binlog被清理了，也有可能是备库上gtid\_purged设置不正确引起的。使用GTID Auto Position时，Dump线程会根据备库发送过来的GTID信息自动判断。如果存在一些GTID，备库是需要的，但是在主库上已经被Purge了，也会报这个错。

```plain
Last_IO_Error: Got fatal error 1236 from master when reading data from binary log: 'Cannot replicate because the master purged required binary logs. Replicate the missing transactions from elsewhere, or provision a new slave from backup. Consider increasing the master's binary log expiration period. The GTID set sent by the slave is '7caa9a48-b325-11ed-8541-fab81f64ee00:1-16333,
c1a67221-f9fc-11ed-bffd-fa8338b09400:1-106', and the missing transactions are '0511eeb3-fad6-11ed-9a0f-fab81f64ee00:1-178:1000007-1000053:2000009-2000029''
```

如果确实是主库Binlog缺失了，就需要重搭备库。

#### 备库GTID比主库多

备库上GTID\_EXECUTED中，相对于主库的SERVER\_UUID，GTID比主库还多，也会报错。这可能是主库异常Crash时，一些Binlog发送到了备库，但是在主库丢失了。

```plain
Last_IO_Error: Got fatal error 1236 from master when reading data from binary log: 'Slave has more GTIDs than the master has, using the master's SERVER_UUID. This may indicate that the end of the binary log was truncated or that the last binary log file was lost, e.g., after a power or disk failure when sync_binlog != 1. The master may or may not have rolled back transactions that were already replicated to the slave. Suggest to replicate any transactions that master has rolled back from slave to master, and/or commit empty transactions on master to account for transactions that have been'
```

遇到这种问题时，要检查下主库和备库数据的一致性。并重新设置备库的GTID\_PURGED变量，再开启复制。

### SQL线程相关问题

备库上，SQL线程应用Binlog时，也可能会遇到各种问题。

#### 主备数据不一致

如果主备库数据不一致，备库上应用Binlog事件时就可能会报错。报错分为几种情况。

1. 执行insert事件时，备库已经存在主键（或唯一索引）相同的数据，这样会报主键冲突的错误。

```plain
Could not execute Write_rows event on table helloworld.test1; Duplicate entry '200' for key 'PRIMARY', Error_code: 1062; handler error HA_ERR_FOUND_DUPP_KEY; the event's master log binlog.000001, end_log_pos 1372
```

2. 执行update和delete事件时，备库上找不到记录，会报找不到记录的错误。

```plain
Could not execute Update_rows event on table helloworld.test1; Can't find record in 'test1', Error_code: 1032; handler error HA_ERR_KEY_NOT_FOUND; the event's master log binlog.000001, end_log_pos 1590
Could not execute Delete_rows event on table helloworld.test1; Can't find record in 'test1', Error_code: 1032; handler error HA_ERR_KEY_NOT_FOUND; the event's master log binlog.000001, end_log_pos 1798
```

遇到数据不一致引起复制中断时，一般需要先修复不一致的数据。通常有这几种做法。

- 重做备库。以主库的数据为准，备份主库数据，将数据恢复到备库。当然业务上要先确认备库上不一致的数据是否可以忽略。
- 对比数据并修复。对比主库和备库的数据，修复不一致的数据。如果不一致的数据比较多，这么做工作量可能会比较大。
- 跳过不一致的数据。如果开启了GTID自动定位，可以在备库上设置GTID，执行一个空的事务。这样SQL线程就可以跳过一个事务。如果使用基于位点的复制，可以设置sql\_slave\_skip\_counter=1，跳过一个事件。还可以设置参数slave\_skip\_errors，跳过数据冲突类的报错，但是不建议使用。如果备库的数据和主库不一致，可能会带来严重的业务问题。

当然，还要找到引起数据不一致的原因，从根源上避免问题。引起主备数据不一致的原因可能会比较多，要具体分析。下面列举了一些可能的情况。

- 使用了memory引擎。备库重启后，memory引擎的数据被清空了。
- 使用了非事务型存储引擎，如MyISAM存储引擎。
- 主库和备库上都有写操作，也就是常说的“双写”。
- 备库有延迟的情况下，发生了主备切换，业务在新的主库上写入了数据。
- MySQL复制代码中的BUG有时也会引起主备数据冲突。

#### 开启了GTID模式，使用基于位点的复制时，从错误的位点复制数据

主备库开启GTID后，如果备库上还是使用基于位点的复制，SQL线程可能会遇到下面这个报错。

```plain
mysql> show replica status\G
......
Last_SQL_Error: Coordinator stopped because there were error(s) in the worker(s). The most recent failure being: Worker 1 failed executing transaction 'NOT_YET_DETERMINED' at master log mysql-binlog.000002, end_log_pos 350. See error log and/or performance_schema.replication_applier_status_by_worker table for more details about this failure or others, if any.

mysql> select * from performance_schema.replication_applier_status_by_worker \G
......
LAST_ERROR_NUMBER: 1782
LAST_ERROR_MESSAGE: Worker 1 failed executing transaction 'NOT_YET_DETERMINED' at master log mysql-binlog.000002, end_log_pos 350; Error '@@SESSION.GTID_NEXT cannot be set to ANONYMOUS when @@GLOBAL.GTID_MODE = ON.' on query. Default database: 'rep'. Query: 'BEGIN'
```

Binlog中，一个完整的事务由多个Binlog事件组成，包括GTID事件、BEGIN事件、Table\_map事件、DML事件、XID事件。下面例子中是一个Delete语句对应Binlog事件。

备库上复制数据时，要指向GTID事件，比如例子中的位点197。如果从其他位点，比如276开始复制，备库上不知道事件的GTID，就会发生上面这个报错。

```plain
# at 197
#241017 16:13:23 server id 119  end_log_pos 276 CRC32 0x1d7504de 	GTID	last_committed=0	sequence_number=1	rbr_only=yes	original_committed_timestamp=1729152803997127	immediate_commit_timestamp=1729152803997127	transaction_length=277
SET @@SESSION.GTID_NEXT= '7caa9a48-b325-11ed-8541-fab81f64ee00:16334'/*!*/;

# at 276
#241017 16:13:23 server id 119  end_log_pos 350 CRC32 0xdc3b60fa 	Query	thread_id=42	exec_time=0	error_code=0
BEGIN
/*!*/;

# at 350
#241017 16:13:23 server id 119  end_log_pos 399 CRC32 0x13726bf2 	Table_map: `rep`.`txx` mapped to number 625

# at 399
#241017 16:13:23 server id 119  end_log_pos 443 CRC32 0x31cf2356 	Delete_rows: table id 625 flags: STMT_END_F

# at 443
#241017 16:13:23 server id 119  end_log_pos 474 CRC32 0x51b2b82c 	Xid = 6660
COMMIT/*!*/;
```

#### 备库relaylog损坏

备库异常崩溃时，如果relaylog损坏了，也会导致SQL线程无法启动。这种情况下，可能要清空relaylog，从主库重新复制数据。

```plain
[ERROR] [MY-013121] [Repl] Slave SQL for channel '': Relay log read failure: Could not parse relay log event entry. The possible reasons are: the master's binary log is corrupted (you can check this by running 'mysqlbinlog' on the binary log), the slave's relay log is corrupted (you can check this by running 'mysqlbinlog' on the relay log), a network problem, the server was unable to fetch a keyring key required to open an encrypted relay log file, or a bug in the master's or slave's MySQL code. If you want to check the master's binary log or slave's relay log, you will be able to know their names by issuing 'SHOW SLAVE STATUS' on this slave. Error_code: MY-013121
```

#### 其他问题

- myisam表损坏
- 备库SQL执行超时
- 主备参数不一致引起备库SQL执行失败

[第六讲](https://time.geekbang.org/column/article/803251)思考题中的那个问题，就是由于主库innodb\_strict\_mode为OFF，而备库innodb\_strict\_mode为ON。主库上执行SQL时，只是报了一个Warning，但是备库上执行就失败了。

### 级联复制架构下的一些问题

级联复制架构下，有时还会遇到一些其他的问题。

#### server\_id重复导致的问题

MySQL复制关系中，主库和备库的server\_id如果相同，IO线程会直接报错。但是在级联复制的架构下，可能会出现server\_id相同的问题。

![图片](https://static001.geekbang.org/resource/image/37/69/37ef4dfac0c85d16a19862099fc1ea69.jpg?wh=1026x292)

图里的这个例子中，主和备1的server\_id不同，备2和备1的server\_id也不同，但是备2和主库的server\_id相同，这会导致一个问题：备2的IO线程从备1获取binlog事件时，发现事件的server\_id和自己的server\_id一样，就会忽略这些事件，从而备2会缺少数据。这种情况下，备2不会产生任何异常日志。

#### Binlog事件无限循环复制

如果没有开启GTID，并且使用了语句模式的Binlog，复制链路存在环路时，还可能会出现Binlog事件无限循环复制。

考虑下面这个复制链路。

![图片](https://static001.geekbang.org/resource/image/e2/58/e2327277b1d46db1a919d9b43d80a258.jpg?wh=1013x268)

由于某些原因，需要下线主，备1和备2组成双向复制架构。

![图片](https://static001.geekbang.org/resource/image/a6/88/a6b2296a32614173f598b8813d4a8788.jpg?wh=982x369)

为了修改复制架构，执行了下面这几个步骤。

1. 备1上执行stop slave。
2. 备2上执行show master status，查看当前binlog位点。
3. 备1上执行change master命令，使用从步骤2获取到的binlog位点。

如果在第2步的时候，备2上有延迟，那么取到的位点后，可能还会生成server\_id为100的binlog事件，这些事件是从原来的主库上复制过来的。当备1指向备2时，这些server\_id为100的事件，就可能会在备1和备2之间循环复制，因为备1和备2的server id都不是100。

如果开启了GTID，就不会发生这种问题了。

### 备库延迟问题

MySQL复制延迟，也是平时比较常见的问题，这个话题比较复杂，我们后续再讨论。

## 总结

数据复制是构建MySQL高可用架构的基础，这一讲中我们对数据复制的基本概念、运维操作做了基本的介绍。

MySQL 8.0开始，在术语上做了一些调整，从原先的Master / Slave，改成了 Source / Replica，相应的，一些命令和参数也做了修改。当前版本下，两套命令和参数还都能用，使用老的这一套命令和参数时，会有一些warning。

主要的修改包括：

- change master改成change replication source，命令中的master改成source；
- start/stop/show slave改成start/stop/show replica；
- reset slave改成reset replica；
- show slave hosts改成show replicas；
- 一些参数名中的master改成source；
- 一些参数名中的slave改成replica。

## 思考题

MySQL主备数据复制默认是异步的。如果主库执行成功，但binlog还没来得及发送给备库，可能会存在备库的事务比主库少的情况。反过来，有没有可能出现备库事务比主库多的情况呢（不考虑业务在备库上写入数据的情况）？

期待你的思考，欢迎在留言区中与我交流。如果今天的课程让你有所收获，也欢迎转发给有需要的朋友。我们下节课再见。
<div><strong>精选留言（2）</strong></div><ul>
<li><span>一本书</span> 👍（1） 💬（1）<p>“如果主库使用了 GTID，生产的备份文件中已经记录了备份时，主库的 GTID_executed 变量。这可以从文件中直接看到。”，老师，我看下方的代码中是SET @@GLOBAL.GTID_PURGED=...，难道 GTID_executed 与GTID_PURGED变量之间是有什么关联吗？</p>2024-11-18</li><br/><li><span>叶明</span> 👍（0） 💬（1）<p>当 sync_binlog != 1 时，source 上的 sync binlog 操作可能并没有使 binlog 落盘，如果没有落盘，那么在 engine commit 前，source 掉电，然后恢复，那么这个事务会被回滚（处于 prepare 状态，但没完整的 binlog），但是 replica 可能已经收到该事务并执行，这个时候就会出现 Slave 比 Master 多的情况。
可参考 http:&#47;&#47;mysql.taobao.org&#47;monthly&#47;2017&#47;04&#47;01&#47;</p>2024-11-08</li><br/>
</ul>