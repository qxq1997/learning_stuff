你好，我是姚秋辰。

在上一讲中，我带你了解了OpenFeign组件的设计目标和要解决的问题。今天我们来学习如何使用OpenFeign实现**跨服务的调用**，通过这节课的学习，你可以对实战项目中的WebClient请求做大幅度的简化，让跨服务请求就像调用本地方法一样简单。

今天我要带你改造的项目是coupon-customer-serv服务，因为它内部需要调用template和calculation两个服务完成自己的业务逻辑，非常适合用Feign来做跨服务调用的改造。

在集成OpenFeign组件之前，我们需要把它的依赖项spring-cloud-starter-OpenFeign添加到coupon-customer-impl子模块内的pom.xml文件中。

```
<!-- OpenFeign组件 -->
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-openfeign</artifactId>
</dependency>
```

在上面的代码中，你并不需要指定组件的版本号，因为我们在顶层项目中定义的spring-cloud-dependencies依赖项中已经定义了各个Spring Cloud的版本号，它们会随着Maven项目的继承关系传递到子模块中。

添加好依赖项之后，我们就可以进行大刀阔斧的OpenFeign改造了。在coupon-customer-impl子模块下的CouponCustomerServiceImpl类中，我们通过WebClient分别调用了template和calculation的服务。这节课我先来带你对template的远程调用过程进行改造，将其替换为OpenFeign风格的调用。

## 改造Template远程调用

通过上节课的内容我们了解到，OpenFeign组件通过接口代理的方式发起远程调用，那么我们改造过程的第一步就是要定义一个OpenFeign接口。

我在coupon-customer-impl项目下创建了一个package，它的路径是com.geekbang.coupon.customer.feign。在这个路径下我定义了一个叫做TemplateService的Interface，用来实现对coupon-template-serv的远程调用代理。我们来看一下这个接口的源代码。

```
@FeignClient(value = "coupon-template-serv", path = "/template")
public interface TemplateService {
    // 读取优惠券
    @GetMapping("/getTemplate")
    CouponTemplateInfo getTemplate(@RequestParam("id") Long id);
    
    // 批量获取
    @GetMapping("/getBatch")
    Map<Long, CouponTemplateInfo> getTemplateInBatch(@RequestParam("ids") Collection<Long> ids);
}
```

在上面的代码中，我们在接口上声明了一个FeignClient注解，它专门用来标记被OpenFeign托管的接口。

在FeignClient注解中声明的value属性是目标服务的名称，在代码中我指定了coupon-template-serv，你需要确保这里的服务名称和Nacos服务器上显示的服务注册名称是一样的。

此外，FeignClient注解中的path属性是一个可选项，如果你要调用的目标服务有一个统一的前置访问路径，比如coupon-template-serv所有接口的访问路径都以/template开头，那么你可以通过path属性来声明这个前置路径，这样一来，你就不用在每一个方法名上的注解中带上前置Path了。

在项目的启动阶段，OpenFeign会查找所有被FeignClient注解修饰的接口，并代理该接口的所有方法调用。当我们调用接口方法的时候，OpenFeign就会根据方法上定义的注解自动拼装HTTP请求路径和参数，并向目标服务发起真实调用。

因此，我们还需要在方法上定义spring-web注解（如GetMapping、PostMapping），让OpenFeign拼装出正确的Request URL和请求参数。这时你要注意，**OpenFeign接口中定义的路径和参数必须与你要调用的目标服务中的保持一致**。

完成了Feign接口的定义，接下来你就可以替换CouponCustomerServiceImpl中的业务逻辑调用了。

首先，我们在CouponCustomerServiceImpl接口中注入刚才定义的TemplateService接口。

```
@Autowired
private TemplateService templateService;
```

被FeignClient注解修饰的对象，也会被添加到Spring上下文中。因此我们可以通过Autowired注入的方式来使用这些接口。

然后，我们就可以对具体的业务逻辑进行替换了。以CouponCustomerServiceImpl类中的placeOrder下单接口为例，其中有一步是调用coupon-template-serv获取优惠券模板数据，这个服务请求是使用WebClient发起的，我们来看一下改造之前的方法实现。

```
webClientBuilder.build().get()
    .uri("http://coupon-template-serv/template/getTemplate?id=" + templateId)
    .retrieve()
    .bodyToMono(CouponTemplateInfo.class)
    .block();        
```

从上面的代码中你可以看出，我们写了一大长串的代码，只为了发起一次服务请求。如果使用**OpenFeign接口**来替换，那画风就不一样了，我们看一下改造后的服务调用过程。

```
templateService.getTemplate(couponInfo.getTemplateId())
```

你可以看到，使用OpenFeign接口发起远程调用就像使用本地服务一样简单。和WebClient的调用方式相比，**OpenFeign组件不光可以提高代码可读性和可维护性，还降低了远程调用的Coding成本**。

在CouponCustomerServiceImpl类中的findCoupon方法里，我们调用了coupon-template-serv的批量查询接口获取模板信息，这个过程也可以使用OpenFeign接口实现，下面是具体的实现代码。

```
// 获取这些优惠券的模板ID
List<Long> templateIds = coupons.stream()
        .map(Coupon::getTemplateId)
        .distinct()
        .collect(Collectors.toList());

// 发起请求批量查询券模板
Map<Long, CouponTemplateInfo> templateMap = templateService
        .getTemplateInBatch(templateIds);
```

到这里，我们已经把template服务的远程调用改成了OpenFeign接口调用的方式，那么接下来让我们趁热打铁，去搞定calculation服务的远程调用。

## 改造Calculation远程调用

首先，我们在TemplateService同样的目录下创建一个新的接口，名字是CalculationService，后面你会使用它作为coupon-calculation-serv的代理接口。我们来看一下这个接口的源码。

```
@FeignClient(value = "coupon-calculation-serv", path = "/calculator")
public interface CalculationService {

    // 订单结算
    @PostMapping("/checkout")
    ShoppingCart checkout(ShoppingCart settlement);

    // 优惠券试算
    @PostMapping("/simulate")
    SimulationResponse simulate(SimulationOrder simulator);
}
```

我在接口类之上声明了一个FeignClient注解，指向了coupon-calculation-serv服务，并且在path属性中注明了服务访问的前置路径是/calculator。

在接口中我还定义了两个方法，分别指向checkout用户下单接口和simulate优惠券试算接口，这两个接口的访问路径和coupon-calculation-serv中定义的路径是一模一样的。

有了前面template服务的改造经验，相信你应该很轻松就能搞定calculation服务调用的改造。首先，我们需要把刚才定义的CalculationService注入到CouponCustomerServiceImpl中。

```
@Autowired
private CalculationService calculationService;
```

然后，你只用在调用coupon-calculation-serv服务的地方，将WebClient调用替换成下面这种OpenFeign调用的方式就可以了，是不是很简单呢？

```
// order清算
ShoppingCart checkoutInfo = calculationService.checkout(order);

// order试算
calculationService.simulate(order)
```

到这里，我们就完成了template和calculation服务调用过程的改造。在我们启动项目来验证改造成果之前，还有最为关键的一步需要完成，那就是配置OpenFeign的加载路径。

## 配置OpenFeign的加载路径

我们打开coupon-customer-serv项目的启动类，你可以通过在类名之上添加一个EnableFeignClients注解的方式定义OpenFeign接口的加载路径，你可以参考以下代码。

```
// 省略其他无关注解
@EnableFeignClients(basePackages = {"com.geekbang"})
public class Application {

}
```

在这段代码中，我们在EnableFeignClients注解的basePackages属性中定义了一个com.geekbang的包名，这个注解就会告诉OpenFeign在启动项目的时候做一件事儿：找到所有位于com.geekbang包路径（包括子package）之下使用FeignClient修饰的接口，然后生成相关的代理类并添加到Spring的上下文中。这样一来，我们才能够在项目中用Autowired注解注入OpenFeign接口。

如果你忘记声明EnableFeignClients注解了呢？那么启动项目的时候，你就会收到一段异常，告诉你目标服务在Spring上下文中未找到。我把具体的报错信息贴在了这里，你可以参考一下。如果碰到这类启动异常，你就可以先去查看启动类上有没有定义EnableFeignClients注解。

```
Field templateService in com.geekbang.coupon.customer.service.CouponCustomerServiceImpl 
required a bean of type 'com.geekbang.coupon.customer.feign.TemplateService' that could not be found.
```

上面就是使用包路径扫描的方式来加载FeignClient接口。除此之外，你还可以通过直接加载指定FeignClient接口类的方式，或者从指定类所在的目录进行扫包的方式来加载FeignClient接口。我把这两种加载方式的代码写在了下面，你可以参考一下。

```
// 通过指定Client类来加载
@EnableFeignClients(clients = {TemplateService.class, CalculationService.class})

// 扫描特定类所在的包路径下的FeignClient
@EnableFeignClients(basePackageClasses = {TemplateService.class})
```

在这三种加载方式中，我比较推荐你在项目中使用一劳永逸的“包路径”加载的方式。因为不管以后你添加了多少新的FeignClient接口，只要这些接口位于com.geekbang包路径之下，你就不用操心加载路径的配置。

到这里，我们就完成了OpenFeign的实战项目改造，你可以在本地启动项目来验证改造后的程序是否可以正常工作。

## 总结

现在，我们来回顾一下这节课的重点内容。今天我们使用OpenFeign替代了项目中的WebClient组件，实现了跨服务的远程调用。在这个过程中有两个重要步骤。

- **FeignClient**：使用该注解修饰OpenFeign的代理接口，你需要确保接口中每个方法的寻址路径和你要调用的目标服务保持一致。除此之外，FeignClient中指定的服务名称也要和Nacos服务端中的服务注册名称保持一致；
- **EnableFeignClients**：在启动类上声明EnableFeignClients注解，使用本课程中学习的三种扫包方式的任意一种加载FeignClient接口，这样OpenFeign组件才能在你的程序启动之后对FeignClient接口进行初始化和动态代理。

通过这节课的学习，相信你已经能够掌握Spring Cloud体系下的微服务远程调用的方法了。在后面的课程中，我将带你进一步了解OpenFeign组件的其他高级玩法。

## 思考题

在这节课中，我把OpenFeign接口定义在了调用方这一端。如果你的服务需要暴露给很多业务方使用，每个业务方都要维护一套独立的OpenFeign接口似乎也不太方便，你能想到什么更好的接口管理办法吗？欢迎在留言区写下自己的思考，与我一起讨论。

好啦，这节课就结束啦。欢迎你把这节课分享给更多对Spring Cloud感兴趣的朋友。我是姚秋辰，我们下节课再见！
<div><strong>精选留言（15）</strong></div><ul>
<li><span>金灶沐</span> 👍（29） 💬（4）<p>服务提供方提取一层接口出来， 由服务提供方维护请求路径，    服务消费方，直接声明一个接口extends消费方的接口， 加上@FeignClients即可
</p>2022-01-10</li><br/><li><span>so long</span> 👍（15） 💬（2）<p>每个服务提供方单独添加一个openfeign的模块，服务调用方添加对应的openfeign模块即可</p>2022-01-10</li><br/><li><span>so long</span> 👍（8） 💬（1）<p>老师，我用spring cloud alibaba搭建了公司的一个项目，服务启动后，接口的首次请求需要2-3秒钟，后续请求都在100ms左右，请问有哪些优化措施可以提高首次接口请求速度？之前使用ribbon可是设置为饿汉式加载，但是spring cloud loadbalancer好像没有饿汉式加载的配置。</p>2022-01-10</li><br/><li><span>ᯤ⁵ᴳ</span> 👍（6） 💬（1）<p>请求异常，多次重试等使用Webclient会比较方便，@FeignClient 如何处理呢</p>2022-01-11</li><br/><li><span>Geek_e93c48</span> 👍（6） 💬（1）<p>关于老师的思考题：
做成将提供方的OpenFeign做成中间件抽离出来。
个人建议：老师是否可以在后边的文章中不仅仅讲技术落地，加入一些使用该技术在生产上的遇到的问题和排查思路，这些才是我们需要的（手动滑稽）</p>2022-01-10</li><br/><li><span>欢沁</span> 👍（4） 💬（1）<p>老师你好，微服务的数据库分库后，如果A服务要展示的数据需要和B数据库的表关联，微服务划分后，数据库层面就没法做join操作，企业现在通用的方式是怎么处理的。我目前的解决方法是通过feign来调用其他服务获取数据，再插到A服务的对象中，如果遇到关联的表多，就需要feign调用多次，我不认为这是一个好的解决方法，这样的话代码量会堆积非常多，如果没有划分数据库的话，只要通过join就解决问题了。


所以概括就是，我需要关联到其他服务的数据库的表，没法join，我应该怎么做，谢谢老师。</p>2022-02-25</li><br/><li><span>mars</span> 👍（4） 💬（3）<p>老师，能问下微服务下调用其他服务，其他服务是其他厂商的web接口，只提供过输入输出和请求地址这种，注册中心也不在一个，这种常规的http请求在微服务架构下的最佳调用实践是咋样的呢？还是继续open feign做url吗？</p>2022-02-07</li><br/><li><span>梁中华</span> 👍（3） 💬（1）<p>要加自定义的header头怎么办？</p>2022-02-09</li><br/><li><span>Geek_a5c816</span> 👍（2） 💬（1）<p>这种原始openFegin的实现消费者调用提供者的时候,无法传递headers中的参数,怎么处理呢?</p>2022-03-18</li><br/><li><span>寥若晨星</span> 👍（1） 💬（1）<p>为啥不可以直接在服务实现的接口上加@FeignClient注解呢</p>2022-03-11</li><br/><li><span>Geek_f76b23</span> 👍（1） 💬（1）<p>cusmter服务通过openFeign调用template提供的服务，@FeignClient(value = &quot;coupon-template-serv&quot;), @FeignClient的value指定了调用服务的名称？

如果我把项目里的template-serv复制一份命名为template-serv-copy,用来模拟集群，这个时候copy的服务名称也要叫coupon-template-serv</p>2022-02-27</li><br/><li><span>黄叶</span> 👍（1） 💬（2）<p>老师，命名方面，我喜欢写成TestServiceFeign进行命名（方面我知道这是个Feign远程调用接口），但看老师是TestService来命名，想请问 这两种方式那种更好</p>2022-01-16</li><br/><li><span>Geek_eca226</span> 👍（0） 💬（2）<p>openfeign是rpc框架吗，和dubbo那个用的多呢</p>2022-07-18</li><br/><li><span>~</span> 👍（0） 💬（1）<p>思考题：既然每个业务方都要自行维护一套 OpenFeign 接口，还容易出现沟通不利接口出错的问题，不如业务提供方自行创建一套 OpenFeign 接口，单独抽出作为一个依赖，调用方只需要依赖这个就可以调用了。以后业务有改动也可以提供方自行维护，有变动或者需求更改直接给通知就可以了
但是一旦是重大的 bug 需要改动已经被多个调用方使用的依赖，会不会通知起来很麻烦，配合改动也很麻烦？这样改动也不是直接删除吧，新添加一个，之前的改为不建议使用就可以了吧</p>2022-01-14</li><br/><li><span>tornado</span> 👍（0） 💬（3）<p>能讲讲feign的负载均衡么？查了一下了解的是feign集成了robbin？那robbin和LoadBalancer之间有什么关系呢？</p>2022-01-10</li><br/>
</ul>