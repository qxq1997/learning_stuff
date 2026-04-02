你好，我是胡夕。今天我们来聊聊Kafka中位移提交的那些事儿。

之前我们说过，Consumer端有个位移的概念，它和消息在分区中的位移不是一回事儿，虽然它们的英文都是Offset。今天我们要聊的位移是Consumer的消费位移，它记录了Consumer要消费的下一条消息的位移。这可能和你以前了解的有些出入，不过切记是下一条消息的位移，而不是目前最新消费消息的位移。

我来举个例子说明一下。假设一个分区中有10条消息，位移分别是0到9。某个Consumer应用已消费了5条消息，这就说明该Consumer消费了位移为0到4的5条消息，此时Consumer的位移是5，指向了下一条消息的位移。

**Consumer需要向Kafka汇报自己的位移数据，这个汇报过程被称为提交位移**（Committing Offsets）。因为Consumer能够同时消费多个分区的数据，所以位移的提交实际上是在分区粒度上进行的，即**Consumer需要为分配给它的每个分区提交各自的位移数据**。

提交位移主要是为了表征Consumer的消费进度，这样当Consumer发生故障重启之后，就能够从Kafka中读取之前提交的位移值，然后从相应的位移处继续消费，从而避免整个消费过程重来一遍。换句话说，位移提交是Kafka提供给你的一个工具或语义保障，你负责维持这个语义保障，即如果你提交了位移X，那么Kafka会认为所有位移值小于X的消息你都已经成功消费了。

这一点特别关键。因为位移提交非常灵活，你完全可以提交任何位移值，但由此产生的后果你也要一并承担。假设你的Consumer消费了10条消息，你提交的位移值却是20，那么从理论上讲，位移介于11～19之间的消息是有可能丢失的；相反地，如果你提交的位移值是5，那么位移介于5～9之间的消息就有可能被重复消费。所以，我想再强调一下，**位移提交的语义保障是由你来负责的，Kafka只会“无脑”地接受你提交的位移**。你对位移提交的管理直接影响了你的Consumer所能提供的消息语义保障。

鉴于位移提交甚至是位移管理对Consumer端的巨大影响，Kafka，特别是KafkaConsumer API，提供了多种提交位移的方法。**从用户的角度来说，位移提交分为自动提交和手动提交；从Consumer端的角度来说，位移提交分为同步提交和异步提交**。

我们先来说说自动提交和手动提交。所谓自动提交，就是指Kafka Consumer在后台默默地为你提交位移，作为用户的你完全不必操心这些事；而手动提交，则是指你要自己提交位移，Kafka Consumer压根不管。

开启自动提交位移的方法很简单。Consumer端有个参数enable.auto.commit，把它设置为true或者压根不设置它就可以了。因为它的默认值就是true，即Java Consumer默认就是自动提交位移的。如果启用了自动提交，Consumer端还有个参数就派上用场了：auto.commit.interval.ms。它的默认值是5秒，表明Kafka每5秒会为你自动提交一次位移。

为了把这个问题说清楚，我给出了完整的Java代码。这段代码展示了设置自动提交位移的方法。有了这段代码做基础，今天后面的讲解我就不再展示完整的代码了。

```
Properties props = new Properties();
     props.put("bootstrap.servers", "localhost:9092");
     props.put("group.id", "test");
     props.put("enable.auto.commit", "true");
     props.put("auto.commit.interval.ms", "2000");
     props.put("key.deserializer", "org.apache.kafka.common.serialization.StringDeserializer");
     props.put("value.deserializer", "org.apache.kafka.common.serialization.StringDeserializer");
     KafkaConsumer<String, String> consumer = new KafkaConsumer<>(props);
     consumer.subscribe(Arrays.asList("foo", "bar"));
     while (true) {
         ConsumerRecords<String, String> records = consumer.poll(100);
         for (ConsumerRecord<String, String> record : records)
             System.out.printf("offset = %d, key = %s, value = %s%n", record.offset(), record.key(), record.value());
     }
```

上面的第3、第4行代码，就是开启自动提交位移的方法。总体来说，还是很简单的吧。

和自动提交相反的，就是手动提交了。开启手动提交位移的方法就是设置enable.auto.commit为false。但是，仅仅设置它为false还不够，因为你只是告诉Kafka Consumer不要自动提交位移而已，你还需要调用相应的API手动提交位移。

最简单的API就是**KafkaConsumer#commitSync()**。该方法会提交KafkaConsumer#poll()返回的最新位移。从名字上来看，它是一个同步操作，即该方法会一直等待，直到位移被成功提交才会返回。如果提交过程中出现异常，该方法会将异常信息抛出。下面这段代码展示了commitSync()的使用方法：

```
while (true) {
            ConsumerRecords<String, String> records =
                        consumer.poll(Duration.ofSeconds(1));
            process(records); // 处理消息
            try {
                        consumer.commitSync();
            } catch (CommitFailedException e) {
                        handle(e); // 处理提交失败异常
            }
}
```

可见，调用consumer.commitSync()方法的时机，是在你处理完了poll()方法返回的所有消息之后。如果你莽撞地过早提交了位移，就可能会出现消费数据丢失的情况。那么你可能会问，自动提交位移就不会出现消费数据丢失的情况了吗？它能恰到好处地把握时机进行位移提交吗？为了搞清楚这个问题，我们必须要深入地了解一下自动提交位移的顺序。

一旦设置了enable.auto.commit为true，Kafka会保证在开始调用poll方法时，提交上次poll返回的所有消息。从顺序上来说，poll方法的逻辑是先提交上一批消息的位移，再处理下一批消息，因此它能保证不出现消费丢失的情况。但自动提交位移的一个问题在于，**它可能会出现重复消费**。

在默认情况下，Consumer每5秒自动提交一次位移。现在，我们假设提交位移之后的3秒发生了Rebalance操作。在Rebalance之后，所有Consumer从上一次提交的位移处继续消费，但该位移已经是3秒前的位移数据了，故在Rebalance发生前3秒消费的所有数据都要重新再消费一次。虽然你能够通过减少auto.commit.interval.ms的值来提高提交频率，但这么做只能缩小重复消费的时间窗口，不可能完全消除它。这是自动提交机制的一个缺陷。

反观手动提交位移，它的好处就在于更加灵活，你完全能够把控位移提交的时机和频率。但是，它也有一个缺陷，就是在调用commitSync()时，Consumer程序会处于阻塞状态，直到远端的Broker返回提交结果，这个状态才会结束。在任何系统中，因为程序而非资源限制而导致的阻塞都可能是系统的瓶颈，会影响整个应用程序的TPS。当然，你可以选择拉长提交间隔，但这样做的后果是Consumer的提交频率下降，在下次Consumer重启回来后，会有更多的消息被重新消费。

鉴于这个问题，Kafka社区为手动提交位移提供了另一个API方法：**KafkaConsumer#commitAsync()**。从名字上来看它就不是同步的，而是一个异步操作。调用commitAsync()之后，它会立即返回，不会阻塞，因此不会影响Consumer应用的TPS。由于它是异步的，Kafka提供了回调函数（callback），供你实现提交之后的逻辑，比如记录日志或处理异常等。下面这段代码展示了调用commitAsync()的方法：

```
while (true) {
            ConsumerRecords<String, String> records = 
	consumer.poll(Duration.ofSeconds(1));
            process(records); // 处理消息
            consumer.commitAsync((offsets, exception) -> {
	if (exception != null)
	handle(exception);
	});
}
```

commitAsync是否能够替代commitSync呢？答案是不能。commitAsync的问题在于，出现问题时它不会自动重试。因为它是异步操作，倘若提交失败后自动重试，那么它重试时提交的位移值可能早已经“过期”或不是最新值了。因此，异步提交的重试其实没有意义，所以commitAsync是不会重试的。

显然，如果是手动提交，我们需要将commitSync和commitAsync组合使用才能达到最理想的效果，原因有两个：

1. 我们可以利用commitSync的自动重试来规避那些瞬时错误，比如网络的瞬时抖动，Broker端GC等。因为这些问题都是短暂的，自动重试通常都会成功，因此，我们不想自己重试，而是希望Kafka Consumer帮我们做这件事。
2. 我们不希望程序总处于阻塞状态，影响TPS。

我们来看一下下面这段代码，它展示的是如何将两个API方法结合使用进行手动提交。

```
   try {
           while(true) {
                        ConsumerRecords<String, String> records = 
                                    consumer.poll(Duration.ofSeconds(1));
                        process(records); // 处理消息
                        commitAysnc(); // 使用异步提交规避阻塞
            }
} catch(Exception e) {
            handle(e); // 处理异常
} finally {
            try {
                        consumer.commitSync(); // 最后一次提交使用同步阻塞式提交
	} finally {
	     consumer.close();
}
}
```

这段代码同时使用了commitSync()和commitAsync()。对于常规性、阶段性的手动提交，我们调用commitAsync()避免程序阻塞，而在Consumer要关闭前，我们调用commitSync()方法执行同步阻塞式的位移提交，以确保Consumer关闭前能够保存正确的位移数据。将两者结合后，我们既实现了异步无阻塞式的位移管理，也确保了Consumer位移的正确性，所以，如果你需要自行编写代码开发一套Kafka Consumer应用，那么我推荐你使用上面的代码范例来实现手动的位移提交。

我们说了自动提交和手动提交，也说了同步提交和异步提交，这些就是Kafka位移提交的全部了吗？其实，我们还差一部分。

实际上，Kafka Consumer API还提供了一组更为方便的方法，可以帮助你实现更精细化的位移管理功能。刚刚我们聊到的所有位移提交，都是提交poll方法返回的所有消息的位移，比如poll方法一次返回了500条消息，当你处理完这500条消息之后，前面我们提到的各种方法会一次性地将这500条消息的位移一并处理。简单来说，就是**直接提交最新一条消息的位移**。但如果我想更加细粒度化地提交位移，该怎么办呢？

设想这样一个场景：你的poll方法返回的不是500条消息，而是5000条。那么，你肯定不想把这5000条消息都处理完之后再提交位移，因为一旦中间出现差错，之前处理的全部都要重来一遍。这类似于我们数据库中的事务处理。很多时候，我们希望将一个大事务分割成若干个小事务分别提交，这能够有效减少错误恢复的时间。

在Kafka中也是相同的道理。对于一次要处理很多消息的Consumer而言，它会关心社区有没有方法允许它在消费的中间进行位移提交。比如前面这个5000条消息的例子，你可能希望每处理完100条消息就提交一次位移，这样能够避免大批量的消息重新消费。

庆幸的是，Kafka Consumer API为手动提交提供了这样的方法：commitSync(Map&lt;TopicPartition, OffsetAndMetadata&gt;)和commitAsync(Map&lt;TopicPartition, OffsetAndMetadata&gt;)。它们的参数是一个Map对象，键就是TopicPartition，即消费的分区，而值是一个OffsetAndMetadata对象，保存的主要是位移数据。

就拿刚刚提过的那个例子来说，如何每处理100条消息就提交一次位移呢？在这里，我以commitAsync为例，展示一段代码，实际上，commitSync的调用方法和它是一模一样的。

```
private Map<TopicPartition, OffsetAndMetadata> offsets = new HashMap<>();
int count = 0;
……
while (true) {
            ConsumerRecords<String, String> records = 
	consumer.poll(Duration.ofSeconds(1));
            for (ConsumerRecord<String, String> record: records) {
                        process(record);  // 处理消息
                        offsets.put(new TopicPartition(record.topic(), record.partition()),
                                   new OffsetAndMetadata(record.offset() + 1)；
                       if（count % 100 == 0）
                                    consumer.commitAsync(offsets, null); // 回调处理逻辑是null
                        count++;
	}
}
```

简单解释一下这段代码。程序先是创建了一个Map对象，用于保存Consumer消费处理过程中要提交的分区位移，之后开始逐条处理消息，并构造要提交的位移值。还记得之前我说过要提交下一条消息的位移吗？这就是这里构造OffsetAndMetadata对象时，使用当前消息位移加1的原因。代码的最后部分是做位移的提交。我在这里设置了一个计数器，每累计100条消息就统一提交一次位移。与调用无参的commitAsync不同，这里调用了带Map对象参数的commitAsync进行细粒度的位移提交。这样，这段代码就能够实现每处理100条消息就提交一次位移，不用再受poll方法返回的消息总数的限制了。

## 小结

好了，我们来总结一下今天的内容。Kafka Consumer的位移提交，是实现Consumer端语义保障的重要手段。位移提交分为自动提交和手动提交，而手动提交又分为同步提交和异步提交。在实际使用过程中，推荐你使用手动提交机制，因为它更加可控，也更加灵活。另外，建议你同时采用同步提交和异步提交两种方式，这样既不影响TPS，又支持自动重试，改善Consumer应用的高可用性。总之，Kafka Consumer API提供了多种灵活的提交方法，方便你根据自己的业务场景定制你的提交策略。

![](https://static001.geekbang.org/resource/image/a6/d1/a6e24c364321aaa44b8fedf3836bccd1.jpg?wh=2069%2A2569)

## 开放讨论

实际上，手动提交也不能避免消息重复消费。假设Consumer在处理完消息和提交位移前出现故障，下次重启后依然会出现消息重复消费的情况。请你思考一下，如何实现你的业务场景中的去重逻辑呢？

欢迎写下你的思考和答案，我们一起讨论。如果你觉得有所收获，也欢迎把文章分享给你的朋友。
<div><strong>精选留言（15）</strong></div><ul>
<li><span>水天一色</span> 👍（59） 💬（15）<p>消费者提了异步 commit 实际还没更新完offset，消费者再不断地poll，其实会有重复消费的情况吧？</p>2019-12-07</li><br/><li><span>Roy Liang</span> 👍（44） 💬（4）<p>要彻底避免消息重复消费，这样是否可行？在consumer端进行幂等操作。这样kafka就可以设置自动提交位移了</p>2020-04-16</li><br/><li><span>ban</span> 👍（25） 💬（8）<p>老师，你好。有个场景不太明白。我做个假设，比如说我的模式是自动提交，自动提交间隔是20秒一次，那我消费了10个消息，很快一秒内就结束。但是这时候我自动提交时间还没到（那是不是意味着不会提交offer），然后这时候我又去poll获取消息，会不会导致一直获取上一批的消息？

还是说如果consumer消费完了，自动提交时间还没到，如果你去poll，这时候会自动提交，就不会出现重复消费的情况。</p>2019-07-13</li><br/><li><span>july</span> 👍（21） 💬（5）<p>老师你好，这里是否可以理解为 自动提交逻辑是在poll方法中，如果间隔大于最小提交间隔，就会运行逻辑进行offset提交，如果小于最小间隔，则忽略offset提交逻辑？也就是说上次poll 的数据即便处理结束，没有调用下一次poll，那么offset也不会提交？</p>2020-04-15</li><br/><li><span>无菇朋友</span> 👍（17） 💬（6）<p>老师您好，有一个疑问，为什么poll之前的提交和按频率自动提交是一个时机，假如频率是5s提交一次，某两次poll之间的间隔是6s，这时候是怎么处理提交的？忘老师解答下，着实没想通这个地方</p>2019-07-21</li><br/><li><span>我已经设置了昵称</span> 👍（13） 💬（1）<p>auto.commit.interval.ms为5秒，且为自动提交
如果业务5秒内还没处理完，这个客户端怎么处理offset</p>2020-05-20</li><br/><li><span>lmtoo</span> 👍（12） 💬（11）<p>对于手动同步和异步提交结合的场景，如果poll出来的消息是500条，而业务处理200条的时候，业务抛异常了，后续消息根本就没有被遍历过，finally里手动同步提交的是201还是000，还是501？</p>2019-07-13</li><br/><li><span>Algoric</span> 👍（7） 💬（8）<p>自动提交一定不会消息丢失吗，如果每次poll的数据过多，在提交时间内没有处理完，这时达到提交时间，那么Kafka还是重复提交上次poll的最大位移吗，还是讲本次poll的消息最大位移提交？</p>2019-09-25</li><br/><li><span>Liam</span> 👍（6） 💬（4）<p>所以自动提交有2个时机吗？

1 固定频率提及，例如5s提及一次
2 poll新数据之前提交前面消费的数据</p>2019-07-15</li><br/><li><span>bbbi</span> 👍（5） 💬（1）<p>老师您好！有一个问题时。Kafka的offset是一个数字，那么这个数值最大时多少？有没有可能存在用完的情况？</p>2020-02-14</li><br/><li><span>Luke</span> 👍（4） 💬（1）<p>我的理解，不管怎样做，单靠Kafka无法保证消息不被重复消费，无论时候自动提交还是手动提交，同步提交还是异步提交，消息的下游消费都要做去重和幂等处理。除非能够保证消息的消费和位点的提交是一个原子操作。而这个原子性太难保证了，基本上又要引入分布式一致性的那一套东西了。</p>2020-10-28</li><br/><li><span>不忘初心丶方得始终</span> 👍（4） 💬（1）<p>老师你好，问个问题，目前公司要用kafka同步老数据库数据，同步过程是按照老数据库的bin.log日志顺序进行同步，但是在同步过程中，有些表是有关联的，加入将数据放到多个分区，不同分区数据消费顺序不一样，就会导致数据同步出现关联问题，如果设置一个分区……这样又太慢，有什么好的建议吗？</p>2019-10-25</li><br/><li><span>Standly</span> 👍（4） 💬（4）<p>try {
        while (true) {
            ConsumerRecords&lt;String, String&gt; records = 
                        consumer.poll(Duration.ofSeconds(1));
            process(records); &#47;&#47; 处理消息
            commitAysnc(); &#47;&#47; 使用异步提交规避阻塞
        }
     } catch (Exception e) {
        handle(e); &#47;&#47; 处理异常
    } finally {
        try {
            consumer.commitSync(); &#47;&#47; 最后一次提交使用同步阻塞式提交
        } finally {
            consumer.close();
        }
    }
这段代码如果异常了，不就退出while循环了么？也就相当于消费者线程异常退出？</p>2019-07-16</li><br/><li><span>kursk.ye</span> 👍（4） 💬（3）<p>我现在有点糊涂了，kafka的offset是以broker发消息给consumer时，broker的offset为准；还是以consumer 的commit offset为准？比如，一个partition现在的offset是99，执行poll(10)方法时，broker给consumer发送了10条记录，在broker中offset变为109；假如 enable.auto.commit 为false，为手动提交consumer offset,但是cosumer在执行consumer.commitSync()或consumer.commitAsync()时进程失败，整个consumer进程都崩溃了；于是一个新的consumer接替原consumer继续消费，那么他是从99开始消费，还是从109开始消费？</p>2019-07-14</li><br/><li><span>J.Smile</span> 👍（3） 💬（1）<p>老师，我真的遇到了无论是自动提交或者是手动提交，没有报错，但是消费位移就是没有增长，心塞塞！！！求助🆘</p>2020-07-21</li><br/>
</ul>