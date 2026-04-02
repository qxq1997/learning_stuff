你好，我是姚秋辰。

上节课我们对Nacos功能体系有了全面的认识。今天我们就来动手搭建Nacos服务注册中心。通过这节课，你可以知道如何搭建一个高可用的Nacos服务集群，以及如何使用MySQL作为Nacos的底层数据存储方案。这些内容可以帮助你理解什么是“高可用架构”。

我们在做系统架构的时候，首要目标就是保障系统的高可用性。不管你的系统架构多么精妙，用的技术多么先进，如果系统的可用性无法得到保障，那么你做什么都是白忙活。

这就像我们的人生一样，事业、家庭、地位都是0，健康才是一串0前面的那个1，没有1则一切皆无。所以，系统的高可用性，就是系统架构层面的那个1。

保障系统的高可用性有两个大道至简的方向。

- **避免单点故障**：在做系统架构的时候，你应该假设任何服务器都有可能挂掉。如果某项任务依赖单一服务资源，那么这就会成为一个“单点”，一旦这个服务资源挂掉就表示整个功能变为不可用。所以你要尽可能消灭一切“单点”；
- **故障机器状态恢复**：尽快将故障机器返回到故障前的状态。对于像Nacos这类中心化注册中心来说，因故障而下线的机器在重新上线后，应该有能力从某个地方获取故障发生前的服务注册列表。

那Nacos是如何解决上面这两个问题，来保证自己的高可用性的呢？很简单，就是构建服务集群。集群环境不仅可以有效规避单点故障引发的问题，同时对于故障恢复的场景来说，重新上线的机器也可以从集群中的其他节点同步数据信息，恢复到故障前的状态。

那么，接下来我就带你手把手搭建Nacos Server的集群环境。

## 下载Nacos Server

Nacos Server的安装包可以从Alibaba官方GitHub中的[Release页面](https://github.com/alibaba/nacos/releases)下载。当前最新的稳定版本是2.0.3，我们课程的实战项目也使用该版本的Nacos做为注册中心和配置中心。

在选择Nacos版本的时候你要注意，一定要选择**稳定版**使用，不要选择版本号中带有BETA字样的版本（比如2.0.0-BETA）。后者通常是重大版本更新前预发布的试用版，往往会有很多潜在的Bug或者兼容性问题。

Nacos 2.0.3 Release note下方的Assets面板中包含了该版本的下载链接，你可以在nacos-server-2.0.3.tar.gz和nacos-server-2.0.3.zip这两个压缩包中任选一个下载。如果你对Nacos的源码比较感兴趣，也可以下载Source code源码包来学习。

![](https://static001.geekbang.org/resource/image/12/be/12b9e8acf953d20f30c0053yyc0f07be.jpg?wh=2000x807)

下载完成后，你可以在本地将Nacos Server压缩包解压，并将解压后的目录名改为“nacos-cluster1”，再复制一份同样的文件到nacos-cluster2，我们以此来模拟一个由两台Nacos Server组成的集群。

![](https://static001.geekbang.org/resource/image/52/a6/52a819b63e3f0d5281e08de6f99cdca6.jpg?wh=2000x807)

到这里，我们就完成了Nacos服务器的下载安装，接下来，我带你去修改Nacos Server的启动项参数。

## 修改启动项参数

Nacos Server的启动项位于conf目录下的application.properties文件里，别看这个文件里的配置项密密麻麻一大串，但大部分都不用你操心，直接使用默认值就好。你只需要修改这里面的服务启动端口和数据库连接串就好了。

因为你需要在一台机器上同时启动两台Nacos Server来模拟一个集群环境，所以这两台Nacos Server需要使用不同的端口，否则在启动阶段会报出端口冲突的异常信息。

Nacos Server的启动端口由server.port属性指定，默认端口是8848。我们在nacos-cluster1中仍然使用8848作为默认端口，你只需要把nacos-cluster2中的端口号改掉就可以了，这里我把它改为8948。

![](https://static001.geekbang.org/resource/image/ab/4f/abb1736f537681d270bd5a9557ea6b4f.jpg?wh=2000x516)

接下来，你需要对Nacos Server的DB连接串做一些修改。在默认情况下，Nacos Server会使用Derby作为数据源，用于保存配置管理数据。Derby是Apache基金会旗下的一款非常小巧的嵌入式数据库，可以随Nacos Server在本地启动。但从系统的可用性角度考虑，我们需要将Nacos Server的数据源迁移到更加稳定的**MySQL数据库**中。

你需要修改三处Nacos Server的数据库配置。

1. **指定数据源**：spring.datasource.platform=mysql这行配置默认情况下被注释掉了，它用来指定数据源为mysql，你需要将这行注释放开；
2. **指定DB实例数**：放开db.num=1这一行的注释；
3. **修改JDBC连接串**：db.url.0指定了数据库连接字符串，我指向了localhost 3306端口的nacos数据库，稍后我将带你对这个数据库做初始化工作；db.user.0和db.password.0分别指定了连接数据库的用户名和密码，我使用了默认的无密码root账户。

下面的图是完整的数据库配置项。

![](https://static001.geekbang.org/resource/image/74/93/7492a76dbc53de8aea7573c620675e93.jpg?wh=2000x1143)

修改完数据库配置项之后，接下来我带你去MySQL中创建Nacos Server所需要用到的数据库Schema和数据库表。

## 创建DB Schema和Table

Nacos Server的数据库用来保存配置信息、Nacos Portal登录用户、用户权限等数据，下面我们分两步来创建数据库。

**第一步，创建Schema**。你可以通过数据库控制台或者DataGrip之类的可视化操作工具，执行下面这行SQL命令，创建一个名为nacos的schema。

```
create schema nacos;
```

**第二步，创建数据库表**。Nacos已经把建表语句准备好了，就放在你解压后的Nacos Server安装目录中。打开Nacos Server安装路径下的conf文件夹，找到里面的nacos-mysql.sql文件，你所需要的数据库建表语句都在这了。你也可以直接到源码仓库的[资源文件](https://gitee.com/banxian-yao/geekbang-coupon-center/tree/master/%E8%B5%84%E6%BA%90%E6%96%87%E4%BB%B6)中获取Nacos建表语句的SQL文件。

将文件中的SQL命令复制下来，在第一步中创建的schema下执行这些SQL命令。执行完之后，你就可以在在数据库中看到这些tables了，总共有12张数据库表。

![](https://static001.geekbang.org/resource/image/e7/87/e75b4cd0yye902048406305feabbcf87.jpg?wh=2000x1047)

数据库准备妥当之后，我们还剩最后一项任务：添加集群机器列表。添加成功后就可以完成集群搭建了。

## 添加集群机器列表

Nacos Server可以从一个本地配置文件中获取所有的Server地址信息，从而实现服务器之间的数据同步。

所以现在我们要在Nacos Server的conf目录下创建cluster.conf文件，并将nacos-cluster1和nacos-cluster2这两台服务器的IP地址+端口号添加到文件中。下面是我本地的cluster.conf文件的内容。

```
## 注意，这里的IP不能是localhost或者127.0.0.1
192.168.1.100:8848
192.168.1.100:8948
```

这里需要注意的是，你不能在cluster.conf文件中使用localhost或者127.0.0.1作为服务器IP，否则各个服务器无法在集群环境下同步服务注册信息。这里的IP应该使用你本机分配到的内网IP地址。

如果你使用的是mac或者linux系统，可以在命令行使用 ifconfig | grep “inet” 命令来获取本机IP地址，下图中红框标出的这行inet地址192.168.1.100就是本机的IP地址。

![](https://static001.geekbang.org/resource/image/c8/65/c87c972be62d4328a8ae5f595a7ff565.jpg?wh=2000x807)

到这里，我们已经完成了所有集群环境的准备工作，接下来我带你去启动Nacos Server验证一下效果。

## 启动Nacos Server

Nacos的启动脚本位于安装目录下的bin文件夹，下图是bin目录下的启动脚本。其中Windows操作系统对应的启动脚本和关闭脚本分别是startup.cmd和shutdown.cmd，Mac和Linux系统对应的启动和关闭脚本是startup.sh和shutdown.sh。

![](https://static001.geekbang.org/resource/image/37/76/375f132670e5a956bf93d0a8aa780776.jpg?wh=2000x1047)

以Mac操作系统为例，如果你希望以单机模式（非集群模式）启动一台Nacos服务器，可以在bin目录下通过命令行执行下面这行命令：

```
 sh startup.sh -m standalone
```

通过-m standalone参数，我指定了服务器以单机模式启动。Nacos Server在单机模式下不会主动向其它服务器同步数据，因此这个模式只能用于开发和测试阶段，对于生产环境来说，我们必须以Cluster模式启动。

如果希望将Nacos Server以集群模式启动，只需要在命令行直接执行sh startup.sh命令就可以了。这时控制台会打印以下两行启动日志。

```
nacos is starting with cluster
nacos is starting，you can check the /Users/banxian/workspace/dev/middleware/nacos-cluster1/logs/start.out
```

这两行启动日志没有告诉你Nacos Server最终是启动成功还是失败，不过你可以在第二行日志中找到一些蛛丝马迹。这行日志告诉了我们启动日志所在的位置是nacos-cluster1/logs/start.out，在启动日志中你可以查看到一行成功消息“Nacos started successfully in cluster mode”。当然了，如果启动失败，你也可以在这里看到具体的Error Log。

![](https://static001.geekbang.org/resource/image/63/6f/631aef2a8a6f741b24bc9430c960666f.jpg?wh=2000x1500)

我们用同样的方式先后启动nacos-cluster1和nacos-cluster2，如上图所示，在启动日志中显示了成功消息“started successfully in cluster mode”，这代表服务器已经成功启动了，接下来你就可以登录Nacos控制台了。

## 登录Nacos控制台

在Nacos的控制台中，我们可以看到服务注册列表、配置项管理、集群服务列表等信息。在浏览器中打开[nacos-cluster1](http://127.0.0.1:8848/nacos)或者[nacos-cluster2](http://127.0.0.1:8948/nacos)的地址，注意这两台服务器的端口分别是8848和8948。你可以看到下面的Nacos的登录页面。

![](https://static001.geekbang.org/resource/image/e8/56/e8337b81f3d9f59bc3f47fed7c090356.jpg?wh=2000x1296)

你可以使用Nacos默认创建好的用户nacos登录系统，用户名和密码都是nacos。当然了，你也可以在登录后的权限控制-&gt;用户列表页面新增系统用户。成功登录后，你就可以看到Nacos控制台首页了。

为了验证集群环境处于正常状态，你可以在左侧导航栏中打开“集群管理”下的“节点列表”页面，在这个页面上显示了集群环境中所有的Nacos Server节点以及对应的状态，在下面的图中我们可以看到192.168.1.100:8848和192.168.1.100:8948两台服务器，并且它们的节点状态都是绿色的“UP”，这表示你搭建的集群环境一切正常。

![](https://static001.geekbang.org/resource/image/59/64/595e5e94382f54c382ae6a7598c63a64.jpg?wh=2000x1008)

好，到这里，我们的Nacos集群环境搭建就完成了。如果你在搭建环境的过程中发现Nacos无法启动，只需要到启动日志/logs/start.out中就能找到具体的报错信息。如果你碰到了启动失败的问题，不妨先去检查以下两个地方：

1. **端口占用**：即server.port所指定的端口已经被使用，你需要更换一个端口重新启动服务；
2. **MySQL连不上**：你需要检查application.properties里配置的MySQL连接信息是否正确，并确认MySQL服务处于运行状态。

如果是其它的异常报错，欢迎发表到评论区，我和热心的同学们都会帮替你诊断的。

## 总结

现在，我们来回顾一下这节课的重点内容。今天我们了解了如何搭建高可用的Nacos集群，在这个过程中，我将底层存储切换成了MySQL数据源，实现了配置项的持久化。

在实际的项目中，如果某个微服务Client要连接到Nacos集群做服务注册，我们并不会把Nacos集群中的所有服务器都配置在Client中，否则每次Nacos集群增加或删除了节点，我都要对所有Client做一次代码变更并重新发布。那么正确的做法是什么呢？

常见的一个做法是提供一个VIP URL给到Client，VIP URL是一个虚拟IP地址，我们可以把真实的Nacos服务器地址列表“隐藏”在虚拟IP后面，客户端只需要连接到虚IP即可，由提供虚IP的组件负责将请求转发给背后的服务器列表。这样一来，即便Nacos集群机器数量发生了变动，也不会对客户端造成任何感知。

提供虚IP的技术手段有很多，比如通过搭建Nginx+LVS或者keepalived技术实现高可用集群。如果你对这些技术感兴趣，我鼓励你尝试自己搭建一个虚IP的环境，锻炼一下技术调研能力。

## 思考题

在开始接下来的实战课之前，我们来做一些课前预习作业。请你从Nacos的[官方文档](https://nacos.io/zh-cn/docs/what-is-nacos.html)中了解Nacos的功能特性以及集成方案，欢迎在评论区留下你的自学笔记。

好啦，这节课就结束啦。欢迎你把这节课分享给更多对Spring Cloud感兴趣的朋友。我是姚秋辰，我们下节课再见！
<div><strong>精选留言（15）</strong></div><ul>
<li><span>Unknown</span> 👍（37） 💬（2）<p>这边windows本地 搭建的时候，端口不要连续，如果连续的话，在启动时候，会报端口占用 的错误
nacos 中的其他服务会占用相邻的端口grpc</p>2022-02-10</li><br/><li><span>~</span> 👍（3） 💬（4）<p>Intel 的 mac，如果启动 nacos 时候，报错: 「找不到或无法加载主类，原因: java.lang.ClassNotFoundException」，八成是你的 jdk 版本不是 8，可以参照这个博客解决（我是按照方案 2 改动脚本，成功启动）。https:&#47;&#47;blog.csdn.net&#47;shentian885&#47;article&#47;details&#47;120718915
另：老师能否出个加餐讲一下使用 docker 启动的方式，或者指点我一下吗？我根据你之前评论的链接尝试安装却失败了。主要原因我认为有二：1 是我把 MySQL 也通过 docker 安装了，nacos 启动时候会报错找不到 DataSource；2 是我不知道 nacos1 和 nacos2 两个容器之间的 ip 地址改怎么设置，是使用 docker 的「内部 ip（我也不清楚是不是这么叫）」，还是 localhost 直接设置，还是用我本机分配的内网 ip？
还麻烦老师解答一下，谢谢老师！！</p>2022-01-07</li><br/><li><span>前行</span> 👍（8） 💬（3）<p>windows 环境下单机模拟集群部署，需要注意的是在两个 Nacos Server 的 conf 文件夹下 都配置 cluster.conf 文件，其他配置按照文章来，启动时在两个 Nacos Server 的 bin 文件下执行 .\startup.cmd 即可。</p>2021-12-29</li><br/><li><span>Sally Kang 蓝</span> 👍（7） 💬（2）<p>姚老师 我有个问题需要请教。Nacos 2.0.3 集群环境搭建后，假设3个Nacos节点，点击集群管理 -&gt; 节点列表 -&gt; 任意下线某个节点后，该节点没办法重新上线(重新加入集群)。问题: 是Nacos没有提供集群节点上线功能？还是这是一个Bug？还是需要通过参数配置进行设置。</p>2021-12-29</li><br/><li><span>yu</span> 👍（4） 💬（3）<p>Mac M1 历经劫难，终于启动了单机nacos
docker pull zhusaidong&#47;nacos-server-m1:2.0.3

docker run -d -p 8848:8848 -p 9848:9848 -p 9555:9555 --name nacos-server \
-e PREFER_HOST_MODE=hostname \
-e MODE=standalone \
-e SPRING_DATASOURCE_PLATFORM= \
-e MYSQL_SERVICE_HOST=127.0.0.1 \
-e MYSQL_SERVICE_DB_NAME=nacos \
-e MYSQL_SERVICE_PORT=3306 \
-e MYSQL_SERVICE_USER=root \
-e MYSQL_SERVICE_PASSWORD= \
-e MYSQL_SERVICE_DB_PARAM=allowPublicKeyRetrieval=true \
--restart on-failure \
zhusaidong&#47;nacos-server-m1:2.0.3

</p>2022-04-19</li><br/><li><span>码小呆</span> 👍（3） 💬（1）<p>一次就搭建成功了哇</p>2022-02-23</li><br/><li><span>Magic</span> 👍（3） 💬（4）<p>我的是m1芯片，采用老师在评论中回复的镜像搭建的。暂时还没翻车😀
# 拉取适合m1的镜像。
docker pull zhusaidong&#47;nacos-server-m1:2.0.3

# nacos-cluster1
docker run -d \
-e PREFER_HOST_MODE=hostname \
-e MODE=cluster \
-e NACOS_APPLICATION_PORT=8848 \
-e NACOS_SERVERS=&quot;192.168.96.126:8848 192.168.96.126:8948&quot; \
-e SPRING_DATASOURCE_PLATFORM=mysql \
-e MYSQL_SERVICE_HOST=192.168.96.126 \
-e MYSQL_SERVICE_PORT=3306 \
-e MYSQL_SERVICE_USER=root \
-e MYSQL_SERVICE_PASSWORD=123456 \
-e MYSQL_SERVICE_DB_NAME=nacos \
-e NACOS_SERVER_IP=192.168.96.126 \
-p 8848:8848 \
--name my-nacos1 \
zhusaidong&#47;nacos-server-m1:2.0.3

# nacos-cluster2
docker run -d \
-e PREFER_HOST_MODE=hostname \
-e MODE=cluster \
-e NACOS_APPLICATION_PORT=8948 \
-e NACOS_SERVERS=&quot;192.168.96.126:8848 192.168.96.126:8948&quot; \
-e SPRING_DATASOURCE_PLATFORM=mysql \
-e MYSQL_SERVICE_HOST=192.168.96.126 \
-e MYSQL_SERVICE_PORT=3306 \
-e MYSQL_SERVICE_USER=root \
-e MYSQL_SERVICE_PASSWORD=123456 \
-e MYSQL_SERVICE_DB_NAME=nacos \
-e NACOS_SERVER_IP=192.168.96.126 \
-p 8948:8948 \
--name my-nacos2 \
zhusaidong&#47;nacos-server-m1:2.0.3</p>2022-02-14</li><br/><li><span>密码123456</span> 👍（3） 💬（1）<p>遇到了一个问题，目录不能用中文，目录不能用中文，目录不能用中文。</p>2022-01-25</li><br/><li><span>kernel</span> 👍（3） 💬（2）<p>1、用腾讯云搭建nacos集群，在配置cluster.conf 后，启动，会在配置文件中多了一个
内网IP+端口？这是为什么？
10.0.16.14:8948  --- 这个是启动后自动加上的，对应的IP是腾讯云的内网ip
101.42.237.141:8848
101.42.237.141:8948
2、在idea中起服务，会报这个错误 
failed to req API:&#47;nacos&#47;v1&#47;ns&#47;instance after all servers([101.42.237.141:8848]) tried: ErrCode:400
网上查是说cluster.conf文件中配置了其他nacos时，若其他未启动，则会出现上述报错！是不是那个内网ip+端口导致的？</p>2022-01-18</li><br/><li><span>Geek_ebdb72</span> 👍（2） 💬（3）<p>我用的docker-compose搭建的但是启动总是报no datasource set 请问有交流群么</p>2022-02-11</li><br/><li><span>wxyz2z</span> 👍（2） 💬（1）<p>m1的mac启动不了，看了日志have &#39;x86_64&#39;, need &#39;arm64e&#39;，请问老师怎么解决</p>2022-01-05</li><br/><li><span>会飞的鱼</span> 👍（1） 💬（3）<p>不知道为啥，Nacos服务端总是启动失败，控制台、日志都看不出问题来，老师可以帮忙远程看下吗

添加集群机器列表时，用到的IP地址还用到application.properties中配置吗
## 注意，这里的IP不能是localhost或者127.0.0.1
192.168.1.100:8848
192.168.1.100:8948</p>2022-02-13</li><br/><li><span>Earthkiid</span> 👍（1） 💬（1）<p>mysql版本太低了也不行，搞了半天一直都无法绑定数据源，后面查看日志才发现是有表没查到，然后才发现应该是导入sql时没注意，只成功建了五六个表，有的语句貌似执行不了？然后升级到5.7再重新来一次就行了。。</p>2022-01-29</li><br/><li><span>西门吹牛</span> 👍（1） 💬（1）<p>Nacos 可以做服务注册中心，可以做配置中心
注册中心以高可用为主(AP)，采用最终一致性协议，和Gossip 不一样，每个节点只负责把自己管理的数据同步给集群中其他节点
做配置中心以一致性为主(CP)，采用强一致性协议，基于raft 实现</p>2022-01-22</li><br/><li><span>超级芒果冰</span> 👍（1） 💬（1）<p>nacos在使用集群部署的时候，是不是一定配置外置的mysql数据库，不能使用内置的Derby数据库</p>2022-01-12</li><br/>
</ul>