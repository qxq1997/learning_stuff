你好，我是何辉。

今天我们用视频形式，统一梳理Dubbo日常开发必须掌握的基础特性，帮你查漏补缺。

视频是我之前录的，在网上发布过，这次统一整理了一下，你可以按需学习。之后遇到类似实现需要，你也可以回来复习。主要会涉及这几个知识点：

- XML配置发布与服务调用
- Java代码发布与服务调用
- 服务提供方异步化实践：AsyncContext#startAsync、返回CompletableFuture
- 服务消费方异步化实践：getFuture方式、setCallback方式、getCompletableFuture方式
- 常用配置参数：启动时服务依赖检查参数、读写请求重试次数设置参数、调用失败时的容错设置、负载均衡策略设置、线程模型设置、服务提供方超时中断流程设置、导出线程堆栈设置。

好，我们直接开始吧。

## XML配置发布与服务调用

1. 服务提供方provider的样例代码开发

<!--THE END-->

2. 服务消费方consumer的样例代码开发

<!--THE END-->

3. 服务消费方从Zookeeper获取地址调用提供方

## Java代码发布与服务调用

1. 启动服务提供方provider

<!--THE END-->

2. 启动服务消费方consumer

## 服务提供方异步化实践

1. 通过AsyncContext#startAsync实现提供方

<!--THE END-->

2. 通过返回CompletableFuture实现提供方

## 服务消费方异步化实践

1. 通过getFuture方式从provider拿到结果

<!--THE END-->

2. 通过setCallback方式从provider拿到结果

<!--THE END-->

3. 通过getCompletableFuture方式从provider拿到结果

## 常用配置参数

1. 启动时服务依赖检查参数check=false

<!--THE END-->

2. 读写请求重试次数设置参数retries=2

<!--THE END-->

3. 调用失败时的容错设置cluster=failover

<!--THE END-->

4. 负载均衡策略设置loadbalance=random

<!--THE END-->

5. 线程模型设置dispatcher=all

<!--THE END-->

6. 服务提供方超时中断流程设置all2

<!--THE END-->

7. 导出线程堆栈设置dump.directory=path

下一讲我们回归正文，应用框架中的高级特性，解决实际问题。下一讲见。
<div><strong>精选留言（8）</strong></div><ul>
<li><span>熊悟空的凶</span> 👍（4） 💬（1）<p>我是工作了5年多的，科班出身，本讲视频我全部学习了，并且都敲了一遍，来回看了好几遍，课程觉得非常实用，老师基本都是手把手教，值得一学，只要自己虚心学习。</p>2022-12-21</li><br/><li><span>天天有吃的</span> 👍（1） 💬（1）<p>后续的课程都是视频的方式吗</p>2022-12-19</li><br/><li><span>cheems</span> 👍（0） 💬（1）<p>老师视频课程的代码，有git地址吗</p>2023-03-14</li><br/><li><span>星期八</span> 👍（0） 💬（1）<p> RpcContext.getContext().getFuture().get() 这种调用方式怎么知道  就提调用的是哪个方法呢？</p>2023-02-20</li><br/><li><span>陌兮</span> 👍（0） 💬（1）<p>nice!</p>2023-02-10</li><br/><li><span>aoe</span> 👍（0） 💬（1）<p>学习了一下 Dubbo 基础知识，感谢老师</p>2023-01-04</li><br/><li><span>大吖大鳄鱼</span> 👍（0） 💬（1）<p>老师代码有没有git地址</p>2022-12-20</li><br/><li><span>jizhi7</span> 👍（1） 💬（0）<p>dubbo 的基础视频在哪有发布么？</p>2023-08-20</li><br/>
</ul>