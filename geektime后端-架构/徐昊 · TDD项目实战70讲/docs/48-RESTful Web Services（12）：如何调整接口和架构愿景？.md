你好，我是徐昊。今天我们继续使用TDD的方式实现RESTful Web Services。

## 回顾架构愿景与任务列表

目前我们Spike得到的代码如下：

```
static class Router implements ResourceRouter {
    private Map<Pattern, Class<?>> routerTable = new HashMap<>();
    public Router(Class<Users> rootResource) {
        Path path = rootResource.getAnnotation(Path.class);
        routerTable.put(Pattern.compile(path.value() + "(/.*)?"), rootResource);
    }
    @Override
    public OutboundResponse dispatch(HttpServletRequest request, ResourceContext resourceContext) {
        String path = request.getServletPath();
        Pattern matched = routerTable.keySet().stream().filter(pattern -> pattern.matcher(path).matches()).findFirst().get();
        Class<?> resource = routerTable.get(matched);


        Method method = Arrays.stream(resource.getMethods()).filter(m -> m.isAnnotationPresent(GET.class)).findFirst().get();
        Object object = resourceContext.getResource(resource);
        try {
            Object result = method.invoke(object);
            GenericEntity entity = new GenericEntity(result, method.getGenericReturnType());
            return (OutboundResponse) Response.ok(entity).build();
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }
}
```

构想中的架构愿景是这样的：

![](https://static001.geekbang.org/resource/image/a2/cb/a2e9416a553cea8a5ab079a716eb30cb.jpg?wh=2072x1215)

## 视频演示

那么进入今天的环节：

## 思考题

请Spike Sub-Resource Locator。

欢迎把你的想法分享在留言区，也欢迎把你的项目代码分享出来。相信经过你的思考与实操，学习效果会更好！
<div><strong>精选留言（1）</strong></div><ul>
<li><span>忘川</span> 👍（4） 💬（0）<p>spike 其实是不断让组件 进行磨合 然后发现其中 缺失的部分,然后针对缺失的属性 站在整个设计的角度,考虑怎么合理分配. 感觉出来,经典模式更多是 针对测试用例的重构,然后得出设计.伦敦学派,更多是在spike过程中,根据缺失,进行设计的重构,让组件的边界和关系,在没有细节改动成本最小的时候,及时弥补漏洞.</p>2023-01-07</li><br/>
</ul>