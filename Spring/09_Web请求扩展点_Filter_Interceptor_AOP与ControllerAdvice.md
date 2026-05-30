# Web 请求扩展点：Filter、Interceptor、AOP 与 ControllerAdvice

## 核心结论

Filter、Interceptor、AOP、`ControllerAdvice` 都能对请求处理过程做扩展，但它们所在层级不同。Filter 在 Servlet 容器层，Interceptor 在 Spring MVC 层，AOP 在 Bean 方法调用层，`ControllerAdvice` 偏 Controller 异常处理、数据绑定和响应体增强。

排查问题时先判断扩展点发生在哪个位置，再判断能拿到哪些上下文、能拦截哪些调用。

## 执行顺序

典型顺序可以简化为：

```text
Filter 前置
  DispatcherServlet
    HandlerInterceptor.preHandle
      Controller 方法
        Service AOP / 事务代理
      HandlerInterceptor.postHandle
      视图渲染或消息转换
    HandlerInterceptor.afterCompletion
Filter 后置
```

如果 Controller 抛异常，异常可能由 `HandlerExceptionResolver` 或 `ControllerAdvice` 处理，`afterCompletion` 仍有机会执行。

## Filter

Filter 属于 Servlet 规范，在请求进入 `DispatcherServlet` 前后执行。

适合：

- 请求日志。
- 编码处理。
- CORS。
- 鉴权入口。
- 读取和包装请求体。
- 链路追踪 TraceId 初始化。
- 安全框架过滤链。

特点：

- 能覆盖所有进入 Servlet 容器的请求。
- 不依赖 Spring MVC Handler。
- 不了解具体 Controller 方法。
- 执行粒度更粗。

## Interceptor

Interceptor 属于 Spring MVC，基于 HandlerExecutionChain。

适合：

- 登录态校验。
- 权限校验。
- Controller 方法前后的上下文处理。
- 请求耗时统计。
- 多租户上下文。

三个方法：

- `preHandle`：Controller 调用前，返回 false 可以中断请求。
- `postHandle`：Controller 正常执行后、视图渲染前。
- `afterCompletion`：请求完成后，无论成功失败都适合清理上下文。

它能拿到 Handler，因此可以基于 HandlerMethod 读取 Controller 方法和注解。

## AOP

AOP 是 Bean 方法级增强。它不关心 HTTP 协议本身，而是增强 Spring Bean 方法调用。

适合：

- 事务。
- 方法级权限。
- 方法耗时。
- 业务审计。
- 幂等注解。
- 缓存注解。

不适合：

- 处理所有静态资源请求。
- 读取原始请求体。
- 替代 Servlet 安全过滤链。

## ControllerAdvice

`@ControllerAdvice` 可以全局增强 Controller 层，常见用法：

- `@ExceptionHandler`：统一异常处理。
- `@InitBinder`：数据绑定初始化。
- `@ModelAttribute`：全局模型数据。
- 配合 `ResponseBodyAdvice`：统一响应包装或加密。

典型统一异常：

```java
@RestControllerAdvice
class GlobalExceptionHandler {
    @ExceptionHandler(BusinessException.class)
    public ErrorResponse handle(BusinessException ex) {
        return ErrorResponse.of(ex.getCode(), ex.getMessage());
    }
}
```

注意不要在全局异常里吞掉所有异常后返回成功状态，否则监控、调用方和排错都会变困难。

## 怎么选择

- 需要处理原始 HTTP 请求、跨所有资源：Filter。
- 需要知道 Controller 方法和注解：Interceptor。
- 需要增强 Service 或任意 Bean 方法：AOP。
- 需要统一 Controller 异常、绑定、响应：ControllerAdvice。

## 常见组合

### 登录鉴权

可用 Filter 或 Interceptor。若需要在 Spring MVC 层读取 `HandlerMethod` 上的权限注解，Interceptor 更直接；如果是统一安全框架入口，Filter 更常见。

### 接口耗时统计

粗粒度请求耗时用 Filter 或 Interceptor；方法级耗时用 AOP。两者可以配合，一个看端到端耗时，一个看业务方法耗时。

### TraceId

通常在 Filter 最前面生成或读取 TraceId，放入 MDC 或上下文；请求结束后在 finally 中清理，避免线程复用导致串数据。

### 参数校验异常

通常用 `ControllerAdvice` 捕获参数绑定和校验异常，统一返回错误响应。

## 常见追问

### Interceptor 能拦截静态资源吗？

取决于资源是否经过 Spring MVC 处理以及拦截器配置路径。Filter 更靠外层，覆盖范围通常更广。

### AOP 和 Interceptor 谁先执行？

一般请求进入 Spring MVC 后先执行 Interceptor 的 `preHandle`，再调用 Controller。如果 AOP 增强的是 Controller 方法，Controller AOP 会在方法调用处执行；如果增强的是 Service 方法，则发生在 Controller 调用 Service 时。

### 为什么 ThreadLocal 上下文要清理？

Web 容器线程会复用。如果请求结束后不清理 ThreadLocal、MDC、租户上下文等数据，后续请求可能读到上一个请求的上下文。

