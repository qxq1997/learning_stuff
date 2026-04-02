你好，我是七牛云许式伟。

基于 HTTP 协议提供服务的好处是显然的。除了 HTTP 服务有很多现成的客户端、服务端框架可以直接使用外，在 HTTP 服务的调试、测试、监控、负载均衡等领域都有现成的相关工具支撑。

在七牛，我们绝大部分的服务，包括内部服务，都是基于 HTTP 协议来提供服务。所以我们需要思考如何更有效地进行 HTTP 服务的测试。

七牛早期 HTTP 服务的测试方法很朴素：第一步先写好服务端，然后写一个客户端 SDK，再基于这个客户端 SDK 写测试案例。

这种方法多多少少会遇到一些问题。首先，客户端 SDK 的修改可能会导致测试案例编不过。其次，客户端 SDK 通常是使用方友好，而不是测试方友好。服务端开发过程和客户端 SDK 的耦合容易过早地陷入“客户端 SDK 如何抽象更合理” 的细节，而不能专注于测试服务逻辑本身。

我的核心诉求是对服务端开发过程和客户端开发过程进行解耦。在网络协议定好了以后，整个系统原则上就可以编写测试案例，而不用等客户端 SDK的成熟。

不写客户端 SDK 而直接做 HTTP 测试，一个直观的思路是直接基于 http.Client 类来写测试案例。这种方式的问题是代码比较冗长，而且它的业务逻辑表达不直观，很难一眼就看出这句话想干什么。虽然可以写一些辅助函数来改观，但做多了就会逐渐有写测试专用 SDK 的倾向。这种写法看起来也不是很可取，毕竟为测试写一个专门的 SDK，看起来成本有些高了。

七牛当前的做法是引入一种 httptest DSL 文法。这是七牛为 HTTP 测试而写的领域专用语言。这个 httptest 工具当前已经开源，项目主页为：

- [https://github.com/qiniu/httptest](https://github.com/qiniu/httptest)（httptest 框架）
- [https://github.com/qiniu/qiniutest](https://github.com/qiniu/qiniutest)（支持七牛帐号与授权机制的 qiniutest 工具）

## httptest 基础文法

这个语言的文法大概在 2012 年就已经被加入到七牛的代码库，后来有个同事根据这个 DSL 文法写了第一版本 qiniutest 程序。在决定推广用这个 DSL 来进行测试的过程中，我们对 DSL 不断地进行了调整和加强。虽然总体思路没有变化，但最终定稿的 DSL 与最初版本有较大的差异。目前来说，我已经可以十分确定地说，这个DSL可以满足 90% 以上的测试需求。它被推荐做为七牛内部的首选测试方案。

![](https://static001.geekbang.org/resource/image/45/82/45e35f9cf7ab35fea48b6135160c0a82.png?wh=865%2A242)

上图是这套 DSL 的 “hello world” 程序。它的执行预期是：下载 www.qiniu.com 首页，要求返回的 HTTP 状态码为 200。如果返回非 200，测试失败；否则测试通过，输出返回包的正文内容（resp.body 变量）。输出 resp.body 的内容通常是调试需要，而不是测试需要。自动化测试是不需要向屏幕去输出什么的。

![](https://static001.geekbang.org/resource/image/c7/ac/c761fdaac0a959f13a5ee14d4eaddaac.png?wh=865%2A664)

我们再看该 DSL 的一个 “quick start（快速入门）” 样例。以 # 开始的内容是程序的注释部分。这里有一个很长很长的注释，描述了一个基本的 HTTP 请求测试的构成。后面我们会对这部分内容进行详细展开，这里暂时跳过。

这段代码的第一句话是定义了一个 auth 别名叫 qiniutest，这只是为了让后面具体的 HTTP 请求中授权语句更简短。紧接着是发起一个 POST 请求，创建一个内容为 {"a": "value1", "b": 1} 的对象，并将返回的对象 id 赋值给一个名为 id1 的变量。后面我们会详细解释这个赋值过程是如何进行的。

接着我们发起一个获取对象内容的 GET 请求，需要注意的是 GET 的 URL 中引用了 id1 变量的值，这意味着我们不是要取别的对象的内容，而是取刚刚创建成功的对象的内容，并且我们期望返回的对象内容和刚才POST上去的一样，也是 {"a": "value1", "b": 1}。这就是一个最基础的 HTTP 测试，它创建了一个对象，确认创建成功，并且尝试去取回这个对象，确认内容与我们期望的一致。这里上下两个请求是通过 id1 这个变量来建立关联的。

对这套DSL文法有了一个大概的印象后，我们开始来解剖它。先来看看它的语法结构。首先这套 httptest DSL 基于命令行文法：

```
command switch1 switch2 … arg1 arg2 …
```

整个命令行先是一个命令，然后紧接着是一个个开关（可选），最后是一个个的命令参数。和大家熟悉的命令行比如 Linux Shell 一样，它也会有一些参数需要转义，如果参数包含空格或其他特殊字符，则可以用 \\ 前缀来进行转义。比如 '\\ ' 表示 ''（空格），‘\\t'表示 TAB 等。另外，我们也支持用 '…' 或者 "…" 去传递一个参数，比如 json 格式的多行文本。同 Linux Shell 类似，'…' 里面的内容没有转义，‘\\ ’ 就是 ‘\\ ’，‘\\t'就是 '\\t'，而不是 TAB。而 "…" 则支持转义。

和 Linux Shell 不同的是，我们的 httptest DSL 虽然基于命令行文法，但是它的每一个参数都是有类型的，也就是说这个语言有类型系统，而不像 Linux Shell 命令行参数只有字符串。我们的 httptest DSL 支持且仅支持所有 json 支持的数据类型，包括：

- string（如："a"、application/json 等，在不引起歧义的情况下，可以省略双引号）
- number（如：3.14159）
- boolean（如：true、false）
- array（如：\[“a”, 200, {“b”: 2}]）
- object/dictionary（如：{“a”: 1, “b”: 2}）

另外，我们的 httptest DSL 也有子命令的概念，它相当于一个函数，可以返回任意类型的数据。比如 qiniu f2weae23e6c9f jg35fae526kbce返回一个 auth object，这是用常规字符串无法表达的。

理解了 httptest DSL 后，我们来看看如何表达一个 HTTP 请求。它的基本形式如下：

```
req <http-method> <url>
header <key1> <val11> <val12>
header <key2> <val21> <val22>
auth <authorization>
body <content-type> <body-data> 
```

第一句是 req 指令，带两个参数： 一个是 http method，即 HTTP 请求的方法，如 GET、POST 等。另一个是要请求的 URL。

接着是一个个自定义的 header（可选），每个 header 指令后面跟一个 key（键）和一个或多个 value（值）。

然后是一个可选的 auth 指令，用来指示这个请求的授权方式。如果没有 auth 语句，那么这个 HTTP 请求是匿名的，否则这就是一个带授权的请求。

最后一句是 body 指令，顾名思义它用来指定 HTTP 请求的正文。body 指令也有两个参数，一个是 content-type（内容格式），另一个是 body-data（请求正文）。

这样说比较抽象，我们看下实际的例子：

无授权的 GET 请求：

```
req GET http://www.qiniu.com/
```

带授权的 POST 请求：

```
req POST http://foo.com/objects
auth `qiniu f2weae23e6c9fjg35fae526kbce`
body application/json '{
  "a": "hello1",
  "b":2
}'
```

也可以简写成：

无授权的GET请求：

```
get http://www.qiniu.com/
```

带授权的Post请求：

```
post http://foo.com/objects
auth `qiniu f2weae23e6c9fjg35fae526kbce`
json '{
  "a": "hello1",
  "b":2
}'
```

发起了 HTTP 请求后，我们就可以收到 HTTP 返回包并对内容进行匹配。HTTP 返回包匹配的基本形式如下：

```
ret <expected-status-code>
header <key1> <expected-val11><expected-val12>
header <key2> <expected-val21><expected-val22>
body <expected-content-type><expected-body-data> 
```

我们先看 ret 指令。实际上，请求发出去的时间是在 ret 指令执行的时候。前面 req、header、auth、body 指令仅仅表达了 HTTP 请求。如果没有调用 ret 指令，那么系统什么也不会发生。

ret 指令可以不带参数。不带参数的 ret 指令，其含义是发起 HTTP 请求，并将返回的 HTTP 返回包解析并存储到 resp 的变量中。而对于带参数的 ret 指令：

```
ret <expected-status-code>
```

它等价于：

```
ret
match <expected-status-code> $(resp.code)
```

## match 指令

这里我们引入了一个新的指令：match 指令。

![](https://static001.geekbang.org/resource/image/ba/c4/bac83312bf630b33c40f1f28ab1d3dc4.png?wh=865%2A486)

七牛所有 HTTP 返回包匹配的匹配文法，都可以用这个 match 来表达：

![](https://static001.geekbang.org/resource/image/52/60/52a851227b667cc52b8ada69667b4060.png?wh=865%2A443)

所以本质上来说，我们只需要一个不带参数的 ret，加上 match 指令，就可以搞定所有的返回包匹配过程。这也是我们为什么说 match 指令是这套 DSL 中最核心的概念的原因。

和其他自动化测试框架类似，这套 DSL 也提供了断言文法。它类似于 CppUnit 或 JUnit 之类的测试框架提供 assertEqual。具体如下：

```
equal <expected> <source>
```

- 与 match 不同，这里 `<expected>、<source>`中都不允许出现未绑定的变量。
- 与 match 不同，equal 要求`<expected>、<source>`的值精确相等。

```
equalSet <expected> <source>
```

- 这里 SET 是指集合的意思。
- 与 equal 不同，equalSet 要求 `<expected>、<source>`都是array，并且对 array 的元素进行排序后判断两者是否精确相等。
- equalSet 的典型使用场景是测试 list 类的 API，比如列出一个目录下的所有文件，你可能预期这个目录下有哪些文件，但是不能预期他们会以什么样的次序返回。

以上介绍基本上就是这套 DSL 最核心的内容了。内容非常精简，但满足了绝大部分测试场景的需求。

## 测试环境的参数化

下面我们谈谈最后一个话题：测试环境的参数化。

为了让测试案例更加通用，我们需要对测试依赖的环境进行参数化。比如，为了让测试脚本能够同时用于 stage 环境和 product 环境，我们需要把服务的 Host 信息参数化。另外，为了方便测试脚本入口，我们通常还需要把 用户名/密码、AK/SK 等敏感性信息参数化，避免直接硬编码到测试案例中。

为了把服务器的 Host 信息（也就是服务器的位置）参数化，我们引入了 host 指令。例如：

```
host foo.com 127.0.0.1:8888
get http://foo.com/objects/a325gea2kgfd
auth qiniutest
ret 200
json '{
  "a": "hello1",
  "b":2
}'
```

这样，后文所有出现请求 foo.com 地方，都会把请求发送到 127.0.0.1:8888 这样一个服务器地址。要想让脚本测试另外的服务器实例，我们只需要调整 host 语句，将 127.0.0.1:8888 调整成其他即可。

除了服务器 Host 需要参数化外，其他常见的参数化需求是 用户名/密码、AK/SK 等。AK/SK 这样的信息非常敏感，如果在测试脚本里面硬编码这些信息，将不利于测试脚本代码的入库。一个典型的测试环境参数化后的测试脚本样例如下：

![](https://static001.geekbang.org/resource/image/a2/fb/a2d588df5daf9cb3535569a6f404acfb.png?wh=715%2A538)

其中，env 指令用于取环境变量对应的值（返回值类型是 string），envdecode 指令则是先取得环境变量对应的值，然后对值进行 json decode 得到相应的 object/dictionary。有了`$(env)` 这个对象`(object)`，就可以通过它获得各种测试环境参数，比如 `$(env.FooHost)`、`$(env.AK)`、`$(env.SK)` 等。

写好了测试脚本后，在执行测试脚本之前，我们需要先配置测试环境：

```
export QiniuTestEnv_stage='{
  "FooHost": "192.168.1.10:8888",
  "AK": "…",
  "SK": "…"
}'

export QiniuTestEnv_product='{
  "FooHost": "foo.com",
  "AK": "…",
  "SK": "…"
}'

```

这样我们就可以执行测试脚本了：

测试 stage 环境：

```
QiniuTestEnv=stage qiniutest ./testfoo.qtf
```

测试 product 环境：

```
QiniuTestEnv=product qiniutest ./testfoo.qtf
```

## 结语

测试是软件质量保障至关重要的一环。一个好的测试工具对提高开发效率的作用巨大。如果能够让开发人员的开发时间从一小时减少到半小时，那么日积月累就会得到惊人的效果。

去关注开发人员日常工作过程中的不爽和低效率是非常有必要的。任何开发效率提升相关的工作，其收益都是指数级的。这也是我们所推崇的做事风格。如果你对今天的内容有什么思考与解读，欢迎给我留言，我们一起讨论。

如果你觉得有所收获，也欢迎把文章分享给你的朋友。感谢你的收听，我们下期再见。
<div><strong>精选留言（11）</strong></div><ul>
<li><span>debugtalk</span> 👍（26） 💬（1）<p>之前我做的一个开源项目 HttpRunner 和这个倒有些相似之处。
https:&#47;&#47;github.com&#47;httprunner&#47;httprunner

对于DSL，有个痛点就是没法像代码那样进行单步调试。所以我也在HttpRunner中探索了语法提示和自动补全功能，以及和 python代码的互转</p>2019-10-04</li><br/><li><span>Aaron Cheung</span> 👍（4） 💬（2）<p>测试先行在目前的开发环境下有无必要 开发人员的边界条件之类有可能没有覆盖业务条件</p>2019-10-08</li><br/><li><span>Charles</span> 👍（1） 💬（2）<p>加餐加的太好了，谢谢！请问下许老师，后端对应的数据库产生的测试数据如何处理的？测试环境还好，生产环境呢？如果是代码处理的话，处理逻辑是放在后端吗？</p>2019-10-08</li><br/><li><span>mickey</span> 👍（0） 💬（1）<p>如果后端是连接数据库的，怎样做动态的自动化测试呢？</p>2019-10-05</li><br/><li><span>丁丁历险记</span> 👍（4） 💬（0）<p>笔记
1  准备上班后下载使用，做中学
2 去关注开发人员日常工作过程中的不爽和低效率是非常有必要的。任何开发效率提升相关的工作，其收益都是指数级的。</p>2019-11-04</li><br/><li><span>ifelse</span> 👍（0） 💬（0）<p>学习打卡</p>2023-09-17</li><br/><li><span>alswl</span> 👍（0） 💬（0）<p>跟之前设计的基于 pyresttest 集成测试（e2e）方案思路挺一致的
https:&#47;&#47;testerhome.com&#47;topics&#47;6134

现在一旦让我设计 DSL，第一反应就是往 YAML 作为载体。</p>2022-12-08</li><br/><li><span>不温暖啊不纯良</span> 👍（0） 💬（0）<p>读完第一段的时候我脑子里出现了一个场景,一个叫http的店铺在街上吆喝:&quot;服务便宜卖,客户端服务1元1斤,服务的服务2元1斤,服务后测试&#47;调试&#47;监控&#47;负载均衡等&quot;,一个叫七牛的人说:&quot;来个服务端的测试服务&quot;.接着他又找到github店铺,看见今日特价:httptest DSL测试工具,心想:&#39;这个不错,刚好好http测试服务配合用,买回家改造改造&#39;.接着就是使用场景了,七牛把客户端和服务端交给了两个不同的人去干,于是用http测试服务使得他俩不用在一起干活,就能完成互相测试.最后是隐藏敏感信息,测试用例是写好了,但ip&#47;密码&#47;AK&#47;SK等信息一定要配置起来,于是就有了后面的 host foo.com等代表敏感信息的单词.</p>2021-05-11</li><br/><li><span>Run</span> 👍（0） 💬（0）<p>很好</p>2021-03-03</li><br/><li><span>Jowin</span> 👍（0） 💬（0）<p>测试用例是移定的，SDK是不断变化的。</p>2020-06-04</li><br/><li><span>南山</span> 👍（0） 💬（0）<p>测试数据一直是耗费精力的地方</p>2020-03-20</li><br/>
</ul>