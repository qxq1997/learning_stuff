你好，我是姚秋辰。

上一课我们学习了如何借助Nacos的服务发现机制获取可用服务节点列表，并发起远程服务调用。在服务调用的环节里，还有一处细节需要你思考一下：Nacos通过服务发现拿到了所有的可用服务节点列表，但服务请求只能发给一个节点，你知道服务调用是根据什么规则选择目标节点的吗？

“小孩子才做选择，大人全都要”，Nacos就是这个全都要的大人。服务列表都被它拿到了手里，但如果要完成一次完整的服务调用，它还需要一个小孩子帮忙做选择，这个做选择题的小孩就是客户端负载均衡组件Spring Cloud Loadbalancer，它根据负载均衡规则，从Nacos获取的服务列表中选取服务调用的目标地址。

那么，Loadbalancer背后是如何工作的呢？今天我就带你了解Spring Cloud御用负载均衡器Loadbalancer的原理。通过这节课，你可以收获以下内容。

1. **负载均衡的作用**：了解负载均衡的两大门派，它们分别是网关层负载均衡和客户端负载均衡。你还会理解客户端负载均衡在微服务架构中的优势；
2. **Loadbalancer工作原理**：了解Loadbalancer如何运用@Loadbalanced注解进行加载；
3. **自定义负载均衡策略**：了解Loadbalancer的自定义扩展点，在实战项目中实现金丝雀测试。

接下来，我们先来看一下负载均衡在微服务中的作用。

## 为什么需要负载均衡

俗话说在生产队薅羊毛不能逮着一只羊薅，在微服务领域也是这个道理。面对一个庞大的微服务集群，如果你每次发起服务调用都只盯着那一两台服务器，在大用户访问量的情况下，这几台被薅羊毛的服务器一定会不堪重负。

因此，我们需要**将访问流量分散到集群中的各个服务器上**，实现雨露均沾，这就是所谓的“**负载均衡技术**”。

道理是这个道理，但实现起来就有两条不同的路径。负载均衡有两大门派，**服务端负载均衡**和**客户端负载均衡**。我们先来聊聊这两个不同门派的使用场景，再来看看本节课的主角Loadbalancer属于哪门哪派。

### 网关层负载均衡

网关层负载均衡也被称为服务端负载均衡，就是在服务集群内设置一个中心化负载均衡器，比如API Gateway服务。发起服务间调用的时候，服务请求并不直接发向目标服务器，而是发给这个全局负载均衡器，它再根据配置的负载均衡策略将请求转发到目标服务。我把这个过程画成了下面这张流程图。

![](https://static001.geekbang.org/resource/image/75/b5/755871b87002c5b85b2db5e16362b5b5.jpg?wh=2000x1338)

网关层负载均衡的应用范围非常广，它不依赖于服务发现技术，客户端并不需要拉取完整的服务列表；同时，发起服务调用的客户端也不用操心该使用什么负载均衡策略。

不过，网关层负载均衡的劣势也很明显。

1. **网络消耗**：多了一次客户端请求网关层的网络开销，在线上高并发场景下这层调用会增加10ms～20ms左右的服务响应时间。别小瞧了这十几毫秒的时间，在超高QPS的场景下，性能损耗也会被同步放大，降低系统的吞吐量；
2. **复杂度和故障率提升**：需要额外搭建内部网关组件作为负载均衡器，增加了系统复杂度，而多出来的那一次的网络调用无疑也增加了请求失败率。

Spring Cloud Loadbalancer可以很好地弥补上面的劣势，那么它是如何做到的呢？

### 客户端负载均衡

Spring Cloud Loadbalancer采用了客户端负载均衡技术，每个发起服务调用的客户端都存有完整的目标服务地址列表，根据配置的负载均衡策略，由客户端自己决定向哪台服务器发起调用。

![](https://static001.geekbang.org/resource/image/13/ce/13bb64bfbd9c6a9515d53e66d441a6ce.jpg?wh=2000x1191)

客户端负载均衡的优势很明显。

1. **网络开销小**：由客户端直接发起点对点的服务调用，没有中间商赚差价；
2. **配置灵活**：各个客户端可以根据自己的需要灵活定制负载均衡策略。

不过呢，如果想要应用客户端负载均衡，那么还需要满足一个前置条件，发起服务调用的客户端需要获取所有目标服务的地址，这样它才能使用负载均衡规则选取要调用的服务。也就是说，**客户端负载均衡技术往往需要依赖服务发现技术来获取服务列表**。

所以，Nacos和Loadbalancer自然而然地走到了一起，一个通过服务发现获取服务列表，另一个使用负载均衡规则选出目标服务器。

了解了负载均衡的作用之后，我们来看看Loadbalancer的工作原理。

## Loadbalancer工作原理

你一定还记得我们在Nacos实战部分使用WebClient发起服务调用的过程吧。我在coupon-customer-serv中声明WebClient的时候加了一个机关，那就是@Loadbalanced注解，这个注解就是开启负载均衡功能的玄机。

```
@Bean
@LoadBalanced
public WebClient.Builder register() {
    return WebClient.builder();
}
```

Loadbalancer组件通过@Loadbalanced注解对WebClient动了一番手脚，在启动过程中利用了自动装配器机制，分三步偷偷摸摸地向WebClient中塞了一个特殊的Filter（过滤器），通过过滤器实现了负载均衡功能。

```
Builder filter(ExchangeFilterFunction filter);
```

接下来，我们深入源码，看看Loadbalancer是如何通过注解将过滤器添加到WebClient对象中的，这个过程分为三步。

**第一步，声明负载均衡过滤器**。ReactorLoadBalancerClientAutoConfiguration是一个自动装配器类，我们在项目中引入了WebClient和ReactiveLoadBalancer类之后，自动装配流程就开始忙活起来了。在这个过程中，它会初始化一个实现了ExchangeFilterFunction的实例，在后面的步骤中，该实例将作为过滤器被注入到WebClient。

下面是自动装配器的源码。

```
@Configuration(proxyBeanMethods = false)
// 只要Path路径上能加载到WebClient和ReactiveLoadBalancer
// 则开启自动装配流程
@ConditionalOnClass(WebClient.class)
@ConditionalOnBean(ReactiveLoadBalancer.Factory.class)
public class ReactorLoadBalancerClientAutoConfiguration {

   // 如果开启了Loadbalancer重试功能(默认开启）
   // 则初始化RetryableLoadBalancerExchangeFilterFunction
   @ConditionalOnMissingBean
   @ConditionalOnProperty(value = "spring.cloud.loadbalancer.retry.enabled", havingValue = "true")
   @Bean
   public RetryableLoadBalancerExchangeFilterFunction retryableLoadBalancerExchangeFilterFunction(
         ReactiveLoadBalancer.Factory<ServiceInstance> loadBalancerFactory, LoadBalancerProperties properties,
         LoadBalancerRetryPolicy retryPolicy) {
      return new RetryableLoadBalancerExchangeFilterFunction(retryPolicy, loadBalancerFactory, properties);
   }
   
    // 如果关闭了Loadbalancer的重试功能
    // 则初始化ReactorLoadBalancerExchangeFilterFunction对象
    @ConditionalOnMissingBean
    @ConditionalOnProperty(value = "spring.cloud.loadbalancer.retry.enabled", havingValue = "false",
        matchIfMissing = true)
    @Bean
    public ReactorLoadBalancerExchangeFilterFunction loadBalancerExchangeFilterFunction(
        ReactiveLoadBalancer.Factory<ServiceInstance> loadBalancerFactory, LoadBalancerProperties properties) {
        return new ReactorLoadBalancerExchangeFilterFunction(loadBalancerFactory, properties);
    }
   // ...省略部分代码
}
```

**第二步，声明后置处理器**。LoadBalancerBeanPostProcessorAutoConfiguration是第二个登场的自动装配器，它的主要作用是将第一步中创建的ExchangeFilterFunction拦截器实例添加到一个后置处理器（LoadBalancerWebClientBuilderBeanPostProcessor）中。

```
// 省略部分代码
public class LoadBalancerBeanPostProcessorAutoConfiguration {

   // 内部配置类
   @Configuration(proxyBeanMethods = false)
   @ConditionalOnBean(ReactiveLoadBalancer.Factory.class)
   protected static class ReactorDeferringLoadBalancerFilterConfig {
      
      // 将第一步中创建的ExchangeFilterFunction实例封装到另一个名为
      // DeferringLoadBalancerExchangeFilterFunction的过滤器中
      @Bean
      @Primary
      DeferringLoadBalancerExchangeFilterFunction<LoadBalancedExchangeFilterFunction> reactorDeferringLoadBalancerExchangeFilterFunction(
            ObjectProvider<LoadBalancedExchangeFilterFunction> exchangeFilterFunctionProvider) {
         return new DeferringLoadBalancerExchangeFilterFunction<>(exchangeFilterFunctionProvider);
      }
   }
   
   // 将过滤器打包到后置处理器中
   @Bean
   public LoadBalancerWebClientBuilderBeanPostProcessor loadBalancerWebClientBuilderBeanPostProcessor(
         DeferringLoadBalancerExchangeFilterFunction deferringExchangeFilterFunction, ApplicationContext context) {
      return new LoadBalancerWebClientBuilderBeanPostProcessor(deferringExchangeFilterFunction, context);
   }
}
```

**第三步，添加过滤器到WebClient**。LoadBalancerWebClientBuilderBeanPostProcessor后置处理器开始发挥作用，将过滤器添加到WebClient中。注意**不是所有的WebClient都会被注入过滤器，只有被@Loadbalanced注解修饰的WebClient实例才能享受这个待遇**。

```
public class LoadBalancerWebClientBuilderBeanPostProcessor implements BeanPostProcessor {
   // ... 省略部分代码
   
   // 对过滤器动手脚
   @Override
   public Object postProcessBeforeInitialization(Object bean, String beanName) throws BeansException {
      // 如果满足以下条件，则将过滤器添加到WebClient中
      // 1) 当前Bean是WebClient.Builder实例
      // 2) WebClient被@LoadBalanced注解修饰
      if (bean instanceof WebClient.Builder) {
         if (context.findAnnotationOnBean(beanName, LoadBalanced.class) == null) {
            return bean;
         }
         // 添加过滤器
         ((WebClient.Builder) bean).filter(exchangeFilterFunction);
      }
      return bean;
   }

}
```

好了，到这里Loadbalancer组件就完成了过滤器的注入。过滤器是一个搭建在WebClient和负载均衡策略之间的桥梁，在WebClient发出一个请求前，过滤器会横插一脚，召唤出负载均衡策略，决定这个请求要发配到哪一台服务器。如果你感兴趣，可以自己阅读过滤器的源码，深入了解它是如何从LoadBalancerFactory中获取到具体的负载均衡策略的。

了解了Loadbalancer的底层原理，接下来我带你深入了解Loadbalancer组件的负载均衡扩展点，看一看如何**深度定制一个属于自己的负载均衡策略**。

## 自定义负载均衡策略实现金丝雀测试

Loadbalancer提供了两种内置负载均衡策略。

- **RandomLoadBalancer**：在服务列表中随机挑选一台服务器发起调用，属于拼人品系列；
- **RoundRobinLoadBalancer**：通过内部保存的一个position计数器，按照次序从上到下依次调用服务，每次调用后计数器+1，属于排好队一个个来系列。

如果以上负载均衡策略无法满足你的要求，那么应该怎么实现自定义的负载均衡策略呢？

Loadbalancer提供了一个顶层的抽象接口ReactiveLoadBalancer，你可以通过继承这个接口，来实现自定义的负载均衡策略。现在我就带你沿着这个路子实现一个用于“金丝雀测试”的负载均衡策略，在动手之前，我先带你了解一下什么是“金丝雀测试”。

### 金丝雀测试

金丝雀测试是灰度测试的一种。

我们的线上应用平稳运行在一个集群中，当你想要上线一个涉及上下游代码改动的线上应用的时候，首先想到的是先要做一个线上测试。这个测试必须在极小规模的范围内进行，不能影响到整个集群。

我们可以把代码改动部署到极个别的几台机器上，这几台机器就叫做“金丝雀”。只有带着“**测试流量标记**”的请求会被发到这几台服务器上，而正常的流量只会打到集群中的其它机器上。下面的图解释了金丝雀测试的流程。

![](https://static001.geekbang.org/resource/image/cd/11/cd5687f2e678d2da14eaaf660c50d111.jpg?wh=2000x1191)

现在你了解了金丝雀测试，接下来我们就将它应用在用户领券这个场景中。

用户领券的接口位于coupon-customer-serv子模块中，它通过负载均衡策略调用了coupon-template-serv完成了领券操作。我把负载均衡策略定义在coupon-customer-serv中，把coupon-template-serv作为金丝雀测试的目标服务，项目实战这就开始了！

首先我们需要在项目中编写自定义的负载均衡策略。

### 编写CanaryRule负载均衡

我在项目中创建了一个叫CanaryRule的负载均衡规则类，它继承自Loadbalancer项目的标准接口ReactorServiceInstanceLoadBalancer。

CanaryRule借助Http Header中的属性和Nacos服务节点的metadata完成测试流量的负载均衡。在这个过程里，它需要准确识别哪些请求是测试流量，并且把测试流量导向到正确的目标服务。

**CanaryRule如何识别测试流量**：如果WebClient发出一个请求，其Header的key-value列表中包含了特定的流量Key：traffic-version，那么这个请求就被识别为一个测试请求，只能发送到特定的金丝雀服务器上。

**CanaryRule如何对测试流量做负载均衡**：包含了新的代码改动的服务器就是这个金丝雀，我会在这台服务器的Nacos元数据中插入同样的流量密码：traffic-version。如果Nacos元数据中的traffic-version值与测试流量Header中的一样，那么这个Instance就是我们要找的那只金丝雀。

我们先来看看CanaryRule的源码。

```
// 可以将这个负载均衡策略单独拎出来，作为一个公共组件提供服务
@Slf4j
public class CanaryRule implements ReactorServiceInstanceLoadBalancer {
    private ObjectProvider<ServiceInstanceListSupplier> serviceInstanceListSupplierProvider;
    private String serviceId;
    // 定义一个轮询策略的种子
    final AtomicInteger position;
    
    // ...省略构造器代码
    
    // 这个服务是Loadbalancer的标准接口，也是负载均衡策略选择服务器的入口方法
    @Override
    public Mono<Response<ServiceInstance>> choose(Request request) {
        ServiceInstanceListSupplier supplier = serviceInstanceListSupplierProvider
                .getIfAvailable(NoopServiceInstanceListSupplier::new);
        return supplier.get(request).next()
                .map(serviceInstances -> processInstanceResponse(supplier, serviceInstances, request));
    }
    
    // 省略该方法内容，本方法主要完成了对getInstanceResponse的调用
    private Response<ServiceInstance> processInstanceResponse(
    }
    
    // 根据金丝雀的规则返回目标节点
    Response<ServiceInstance> getInstanceResponse(List<ServiceInstance> instances, Request request) {
        // 注册中心无可用实例 返回空
        if (CollectionUtils.isEmpty(instances)) {
            log.warn("No instance available {}", serviceId);
            return new EmptyResponse();
        }
        // 从WebClient请求的Header中获取特定的流量打标值
        // 注意：以下代码仅适用于WebClient调用，使用RestTemplate或者Feign则需要额外适配
        DefaultRequestContext context = (DefaultRequestContext) request.getContext();
        RequestData requestData = (RequestData) context.getClientRequest();
        HttpHeaders headers = requestData.getHeaders();
        // 获取到header中的流量标记
        String trafficVersion = headers.getFirst(TRAFFIC_VERSION);
        
        // 如果没有找到打标标记，或者标记为空，则使用RoundRobin规则进行查找
        if (StringUtils.isBlank(trafficVersion)) {
            // 过滤掉所有金丝雀测试的节点，即Nacos Metadaba中包含流量标记的节点
            // 从剩余的节点中进行RoundRobin查找
            List<ServiceInstance> noneCanaryInstances = instances.stream()
                    .filter(e -> !e.getMetadata().containsKey(TRAFFIC_VERSION))
                    .collect(Collectors.toList());
            return getRoundRobinInstance(noneCanaryInstances);
        }
        
        // 如果WelClient的Header里包含流量标记
        // 循环每个Nacos服务节点，过滤出metadata值相同的instance，再使用RoundRobin查找
        List<ServiceInstance> canaryInstances = instances.stream().filter(e -> {
            String trafficVersionInMetadata = e.getMetadata().get(TRAFFIC_VERSION);
            return StringUtils.equalsIgnoreCase(trafficVersionInMetadata, trafficVersion);
        }).collect(Collectors.toList());
        return getRoundRobinInstance(canaryInstances);
    }
    
    // 使用RoundRobin机制获取节点
    private Response<ServiceInstance> getRoundRobinInstance(List<ServiceInstance> instances) {
        // 如果没有可用节点，则返回空
        if (instances.isEmpty()) {
            log.warn("No servers available for service: " + serviceId);
            return new EmptyResponse();
        }
        
        // 每一次计数器都自动+1，实现轮询的效果
        int pos = Math.abs(this.position.incrementAndGet());
        ServiceInstance instance = instances.get(pos % instances.size());
        return new DefaultResponse(instance);
    }
}
```

完成了负载均衡规则的编写之后，我们还要将这个负载均衡策略配置到方法调用过程中去。

### 配置负载均衡策略

CanaryRule负载均衡规则位于coupon-customer-serv项目里，那么相对应的配置类也放到同一个项目中。我创建了一个名为CanaryRuleConfiguration的类，因为我不希望把这个负载均衡策略应用到全局，所以我没有为这个配置类添加@Configuration注解。

```
// 注意这里不要写上@Configuration注解
public class CanaryRuleConfiguration {

    @Bean
    public ReactorLoadBalancer<ServiceInstance> reactorServiceInstanceLoadBalancer(
            Environment environment,
            LoadBalancerClientFactory loadBalancerClientFactory) {
        String name = environment.getProperty(LoadBalancerClientFactory.PROPERTY_NAME);
        // 在Spring上下文中声明了一个CanaryRule规则
        return new CanaryRule(loadBalancerClientFactory.getLazyProvider(name,
                ServiceInstanceListSupplier.class), name);
    }
}
```

写好配置类之后，我们需要在coupon-customer-serv的启动类上添加一个@LoadBalancerClient注解，将Configuration类和目标服务关联起来。

```
// 发到coupon-template-serv的调用，使用CanaryRuleConfiguration中定义的负载均衡Rule
@LoadBalancerClient(value = "coupon-template-serv", configuration = CanaryRuleConfiguration.class)
public class Application {
   // xxx省略方法
}
```

配置好负载均衡方案后，我们就要想办法将“测试流量标记”传入到WebClient的header里。

### 测试流量打标

测试流量打标的方法有很多种，比如添加一个特殊的key-value到Http header，或者塞一个值到RPC Context中。为了方便演示，我这里采用了一种更为简单的方式，直接在用户领券接口的请求参数对象RequestCoupon中添加了一个trafficVersion成员变量，用来标识测试流量。

```
public class RequestCoupon {
  //.. 省略其他成员变量

  // Loadbalancer - 用作测试流量打标
  private String trafficVersion;
}
```

同时，我对用户领券接口中调用coupon-template-serv的部分做了一个小改动。在构造WebClient对象的时候，我将RequestCoupon中的流量标记放在了WebClient请求的header中。这样一来，CanaryRule负载均衡策略就可以根据header判断当前请求是否为测试流量。

```
@Override
public Coupon requestCoupon(RequestCoupon request) {
    CouponTemplateInfo templateInfo = webClientBuilder.build().get()
            .uri("http://coupon-template-serv/template/getTemplate?id=" + request.getCouponTemplateId())
            // 将流量标记传入WebClient请求的Header中
            .header(TRAFFIC_VERSION, request.getTrafficVersion())
            .retrieve()
            .bodyToMono(CouponTemplateInfo.class)
            .block();
 
    // xxx 省略以下代码           
}
```

一切配置妥当之后，我们还剩最后一步：借助Nacos元数据将coupon-template-serv标记为一只金丝雀。

### 添加Nacos元数据

我在本地启动了两个coupon-template-serv实例，接下来我将其中一个实例设置为金丝雀。

你可以打开Nacos的服务列表页面，点击coupon-template-serv服务右方的“详情”按钮，进入到服务详情页。

![](https://static001.geekbang.org/resource/image/ab/3a/ab045fd51ee5a8103e45b4df3d11f33a.jpg?wh=2000x876)

在服务详情页中，你可以看到本地启动的两个coupon-template-serv应用，然后选中其中的一个instance，点击图中的“编辑”按钮，添加一个新的变量到元数据中：traffic-version=coupon-template-test001。

![](https://static001.geekbang.org/resource/image/bc/d8/bcac234c6a3760372cde4cc50ce8d1d8.jpg?wh=2000x1830)

好，到这里，我们的金丝雀负载均衡策略的就已经完成了。

你可以在本地启动项目并调用coupon-customer-serv的用户领券接口做测试。如果你在请求参数中指定了traffic-version=coupon-template-test001，那么这个请求将调用到金丝雀服务器；如果没有指定traffic-version，那么请求会被转发到正常的服务节点；如果你乱填了一个错误的traffic-version，那么方法会返回503-Service Unavailable的异常。

## 总结

现在，我们来回顾一下这节课的重点内容。今天我们了解了负载均衡技术在微服务领域的应用，深入理解了Spring Cloud Loadbalancer的底层原理和扩展点，并且通过一个“金丝雀测试”的例子，动手编写了一个自定义负载均衡策略。

这里需要注意的是，**课程中编写的自定义负载均衡策略主要是针对WebClient方式的远程调用，如果你使用RestTemplate或者Feign发起调用，则需要在实现层面做一些额外的定制**。希望这节课讲到的原理和方法能够起到一个授之以渔的作用，启发你向下深挖Loadbalancer如何支持其它HTTP调用方式。

我还想和你聊一聊我的一个学习心得，很多技术人员都会以为只学习工作里用到的技术就够了，其实这个想法会极大程度限制他以后的职业发展。我举个例子，负载均衡技术Loadbalancer，它并不是一个日常工作里经常用到的技术，在大公司通常这类框架层面的组件都由Framework团队封装好给到开发人员直接使用就可以了，所以你可能会认为并不需要学习。

但我的经验告诉自己，技术人员的成长来源于两个方面，一个是工作中用到的新技术和高并发挑战，另一个就是自己主动的拓展。而越到后期，你会发现第二个方向对自己的提升逐渐占据了主导地位。为什么呢？当你工作积累到一定年限之后，很容易发现工作内的业务需求已经没有太多的技术挑战，你的技术积累也足以应付每天的工作。这时候如果没有自己由内向外的主动拓展，你很容易就陷入了一个原地踏步的境地。

所以，希望你不要在技术学习上给自己设界，多去了解更多技术框架的全貌，积累到一定程度之后，这些努力都会在未来某一个时刻给你回报。

## 思考题

你能设计一个自定义负载均衡策略，实现集群优先的负载均衡吗？即优先调用同一个Cluster的服务器，如果同一个Cluster中没有可用服务，再调用其他Cluster的服务。

实现这个功能并不难，但是需要你仔细阅读Nacos和Loadbalancer的源码，找到获取当前服务和远程服务的Cluster Name的方法。

当然了，方法有很多，还要看你能否找到一个简单优雅的方式实现这个需求。如果你能够完成这个小挑战，那你的源码阅读能力一定是相当不错的，在评论区说出你的奇思妙想吧！

好啦，这节课就结束啦。欢迎你把这节课分享给更多对Spring Cloud感兴趣的朋友。我是姚秋辰，我们下节课再见！
<div><strong>精选留言（15）</strong></div><ul>
<li><span>peter</span> 👍（12） 💬（3）<p>老师我有个关于代理的问题：一般用nginx将请求转发到后端多个应用服务器上。现在用了API网关，由API网关将请求转发到后端应用服务器上。这样的话，API网关和nginx的功能就重复了，就不需要nginx了，对吗？ 尤其对于中小公司，服务器数量不是很多，nginx就足够了，或者用API网关就足够了，两者选一个就够了啊。</p>2022-01-06</li><br/><li><span>Geek_0b93c0</span> 👍（10） 💬（1）<p>集群优先代码

    private Response&lt;ServiceInstance&gt; getSameClusterService(Request request, List&lt;ServiceInstance&gt; instances) {
        String clusterName = environment.resolvePlaceholders(&quot;${spring.cloud.nacos.discovery.cluster-name:}&quot;);
        List&lt;ServiceInstance&gt; instanceList = instances.stream().filter(v -&gt; {
            Map&lt;String, String&gt; metadata = v.getMetadata();
            String serviceClusterName = metadata.get(&quot;nacos.cluster&quot;);
            return clusterName.equals(serviceClusterName);
        }).collect(Collectors.toList());
        &#47;&#47;有同集群下服务 RoundRobin算法挑选
        if (CollectionUtils.isNotEmpty(instanceList)){
            return getRoundRobinInstance(instanceList);
        }else {
            return getRoundRobinInstance(instances);
        }
    }</p>2022-05-31</li><br/><li><span>与路同飞</span> 👍（10） 💬（2）<p>现在公司所有api服务都是注册到api网关上去了。api网关替我们做了负载均衡和路由规则。那业务团队是不是就不需要引用负载均衡组件了</p>2022-01-20</li><br/><li><span>何衍其</span> 👍（9） 💬（2）<p>&#47;&#47; 当前服务的集群名称
 String clusterName = environment.resolvePlaceholders(&quot;${spring.cloud.nacos.discovery.cluster-name:}&quot;);

&#47;&#47; 服务实列所属集群名称
serviceInstance.getMetadata().get(&quot;nacos.cluster&quot;);</p>2022-04-13</li><br/><li><span>~</span> 👍（5） 💬（3）<p>说一下思考题我的思路：
从 CanaryRule 就可以看出来了，其实实现负载均衡的逻辑就在getRoundRobinInstance中，我们只需要改造这里就可以了。我的想法是设置一个缓存（map 也好，其他的也好），存放上次选择出的 serverInstance，如果是第一次选择，那么使用老逻辑选出一个，如果上次选择的服务已经不可用了，就从缓存中清除，重新选一个就可以了。
补充2点：
1. 怎么判断一个服务是否可用？其实在这里的代码中，传入的 List&lt;ServiceInstance&gt; 参数就是从 nacos 中获取到的可用服务的列表。那么只需要判断缓存中存放的 serviceInstance 是否也在 list 中就可以了。具体怎么获取到可用服务列表的，需要进一步查看源码才能了解。
2. 仅做一个猜想，不具有实际意义，老师如果能解答也再好不过了：能否直接在获取可用服务列表那步就直接确定一个服务？其他的逻辑也是如此。就算可行其实设计上也是不合理的，因为获取可用服务的代码就应该只负责相关逻辑，负载均衡代码就应该只管负载均衡。提出这个猜想只不过是想对源码有进一步了解，设计上还是各司其职更合理。

以上就是我的思考，附上代码（超过字数限制了，放在我的留言的回复里了），如果有问题，欢迎指出问题~
</p>2022-01-16</li><br/><li><span>Yarnbo</span> 👍（1） 💬（1）<p>姚总好，学习了您的本节课受益匪浅。虽然照葫芦画瓢也实现了“优先调用同一个 Cluster 的服务器”，但是这样做的意义有哪些，能结合您的经验介绍下吗？（我能盲猜到的是，假如服务以集群为基本单元提供服务能力，将来方便弹性扩展机器）</p>2022-09-29</li><br/><li><span>二饼</span> 👍（1） 💬（2）<p>Nacos-服务管理-服务列表-开发环境 `coupon-template-serv` 只有一个实例，不是两个，我又把前面的文章看了一遍，没有发现什么地方又说定义了两个实例，和示例代码比对了一下配置文件没看出什么问题，请教一下老师我这是什么造成的？</p>2022-08-21</li><br/><li><span>胖子菜</span> 👍（1） 💬（1）<p>dubbo整合了nacos后，因为我用的最新版本的nacos没有自带ribbon,我又引入了loadbalancer依赖，我想问下dubbo有负载均衡机制，loadbancer也有，他们冲突么，谁会生效呢</p>2022-05-07</li><br/><li><span>靠人品去赢</span> 👍（1） 💬（1）<p>像金丝雀这些线上验证，会产生线上数据，万一没搞好打标打错了或者没配置好，导入到正常服务的机器上没有到金丝雀上，怎么辨别消除影响呢？</p>2022-04-01</li><br/><li><span>rrbbt</span> 👍（0） 💬（1）<p>老师能详细讲一下这句话吗？没太看懂，为什么不应用到全局？不加@Configuration就能不应用到全局吗？===========[原文]&quot;因为我不希望把这个负载均衡策略应用到全局，所以我没有为这个配置类添加 @Configuration 注解&quot;</p>2023-06-24</li><br/><li><span>乘风</span> 👍（0） 💬（1）<p>金丝雀负载均衡策略好像并没有强依赖WebClient呀，为什么说它是专门针对WebClient方式的远程调用，难道openFeigh用不了？</p>2022-09-20</li><br/><li><span>Jaising</span> 👍（0） 💬（2）<p>半仙老师，遇到个负载失效的问题帮忙排查下怎么回事，应用中引入了两个二方库starter A和B，两个starter都各自定义了一个RestTemplate，A做了LoadBalance，B没有，单独引入A或B都可以正常发起http调用，但是同时引入两个starter后，B正常，A却负载失效了报错no instances available，这是咋回事</p>2022-06-22</li><br/><li><span>Geek_5d68ab</span> 👍（0） 💬（1）<p>把老师的代码down下来之后，启动服务，请求接口不经过CanaryRule是怎么回事？</p>2022-05-27</li><br/><li><span>丶凯</span> 👍（0） 💬（1）<p>包含了新的代码改动的服务器就是这个金丝雀,  老师这句话什么意思？
</p>2022-04-01</li><br/><li><span>密码123456</span> 👍（0） 💬（2）<p>LoadBalancerClientFactory.getLazyProvider这个方法，为什么name随便写一个值不行？必须是服务名称？</p>2022-02-07</li><br/>
</ul>