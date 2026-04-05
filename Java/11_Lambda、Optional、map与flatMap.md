# Java - 第 11 课：Lambda、Optional、map 与 flatMap

## 学习目标（本节结束后你能做到什么）

- 理解 `lambda` 到底在解决什么问题，而不是只会写 `()->{}` 这种语法。
- 分清函数式接口、`lambda`、方法引用三者的关系。
- 理解 `Optional` 想解决的核心问题，以及它适合用在什么地方、不适合用在什么地方。
- 能讲清 `map` 和 `flatMap` 的共同抽象与关键区别。
- 能在 `Stream` 和 `Optional` 两种场景里正确使用 `map` / `flatMap`。

## 内容讲解（核心概念，用类比、例子、图示说清楚）

### 1. 为什么 Java 里会有 lambda

在 Java 8 之前，如果你想把“一段行为”传给另一个方法，通常要写匿名内部类，代码会比较啰嗦。

例如，对一个线程传入任务：

```java
new Thread(new Runnable() {
    @Override
    public void run() {
        System.out.println("hello");
    }
}).start();
```

Java 8 之后可以写成：

```java
new Thread(() -> System.out.println("hello")).start();
```

两段代码表达的是同一件事：

- 给 `Thread` 传入一段“以后要执行的行为”

所以 `lambda` 的核心价值不是“语法更酷”，而是：

**让“行为”也能像“数据”一样被传递。**

也就是说，你不仅能传一个 `int`、一个 `String`、一个 `User`，还可以传一段逻辑。

### 2. lambda 不是凭空存在的，它必须依附函数式接口

很多人会把 `lambda` 当成 Java 新增的一种“函数类型”，其实不完全准确。

Java 里的 `lambda` 本质上是：

**一个函数式接口的实例的更简洁写法。**

函数式接口指的是：

- 接口里只有一个抽象方法

例如：

```java
@FunctionalInterface
public interface Runnable {
    void run();
}
```

```java
@FunctionalInterface
public interface Callable<V> {
    V call() throws Exception;
}
```

```java
@FunctionalInterface
public interface Function<T, R> {
    R apply(T t);
}
```

所以：

- `() -> System.out.println("hello")` 可以赋值给 `Runnable`
- `x -> x + 1` 可以赋值给 `Function<Integer, Integer>`
- `x -> x > 0` 可以赋值给 `Predicate<Integer>`

一句话记：

**lambda 是“写法”，函数式接口是“落地的类型”。**

### 3. 最常见的四类函数式接口

如果把函数式编程里最常见的动作抽象一下，通常就是下面这四类：

#### 3.1 `Function<T, R>`

输入一个 `T`，产出一个 `R`。

```java
Function<String, Integer> f = s -> s.length();
```

适合表示“转换”。

#### 3.2 `Consumer<T>`

输入一个 `T`，不返回值。

```java
Consumer<String> c = s -> System.out.println(s);
```

适合表示“消费”或“处理”。

#### 3.3 `Supplier<T>`

不需要输入，返回一个 `T`。

```java
Supplier<Long> s = () -> System.currentTimeMillis();
```

适合表示“提供”或“懒加载”。

#### 3.4 `Predicate<T>`

输入一个 `T`，返回 `boolean`。

```java
Predicate<Integer> p = x -> x > 10;
```

适合表示“条件判断”。

面试里如果你能把 `lambda` 和这四类接口关联起来，就不会显得只会背语法。

### 4. 方法引用是什么

有些 `lambda` 只是简单调用了一个已有方法，这时候可以进一步简化成方法引用。

```java
list.forEach(System.out::println);
```

它等价于：

```java
list.forEach(x -> System.out.println(x));
```

常见形式有三种：

- `对象::实例方法`
- `类名::静态方法`
- `类名::实例方法`

例如：

```java
String::length
Integer::parseInt
System.out::println
```

方法引用不是新能力，只是 `lambda` 的进一步简化。

### 5. `Optional` 到底在解决什么问题

`Optional<T>` 的设计目标不是“让 Java 没有 null”，而是：

**把“这个值可能不存在”显式表达出来，减少到处写空指针判断的混乱。**

例如，一个用户可能查得到，也可能查不到：

```java
Optional<User> userOpt = userService.findById(1L);
```

这比直接返回 `null` 的好处是：

- 调用方一眼就知道：这里不是一定有值
- 你会被迫思考“没有值怎么办”
- 代码的意图更清晰

最常见的用法：

```java
Optional<User> userOpt = Optional.ofNullable(user);
```

```java
String name = userOpt
        .map(User::getName)
        .orElse("unknown");
```

上面这段的含义是：

- 如果有 `user`
- 就继续取 `name`
- 如果中间没有值，最后给默认值 `"unknown"`

### 6. `Optional` 适合用在哪里，不适合用在哪里

这是工程里很容易被滥用的点。

适合：

- 作为方法返回值，表达“可能没有结果”
- 在链式取值时减少层层判空

不太适合：

- 作为实体类字段
- 作为 DTO / VO 属性
- 作为方法参数
- 在需要序列化、ORM 映射的对象里到处用

原因很简单：

- `Optional` 是为了“调用方处理返回值”设计的
- 不是为了“把所有字段都包起来”设计的

所以更自然的习惯通常是：

- 返回值用 `Optional`
- 字段本身还是正常字段

### 7. 先抽象理解 `map`

`map` 这个词最核心的意思是：

**把一个值，通过一个规则，映射成另一个值。**

你可以先不管它是在 `Stream` 里还是在 `Optional` 里，它的本质都一样：

- 输入一个东西
- 做一次转换
- 得到新的东西

#### 7.1 `Stream` 里的 `map`

```java
List<String> names = List.of("alice", "bob", "carol");

List<Integer> lengths = names.stream()
        .map(String::length)
        .toList();
```

这里的含义是：

- 原来流里是字符串
- 每个字符串经过 `String::length`
- 变成了整数

所以：

- `Stream<String>` 经过 `map`
- 变成 `Stream<Integer>`

这是一对一转换。

#### 7.2 `Optional` 里的 `map`

```java
Optional<User> userOpt = Optional.of(new User("alice"));

Optional<String> nameOpt = userOpt.map(User::getName);
```

这里的含义是：

- 如果 `Optional` 里有 `User`
- 就把 `User` 映射成 `name`
- 得到一个新的 `Optional<String>`

这里的抽象和 `Stream` 完全一致，只是容器不同。

### 8. 再抽象理解 `flatMap`

`flatMap` 比 `map` 多做了一件事：

**不仅做转换，还顺手把“嵌套的一层包装”拍平。**

这是它最本质的点。

### 9. 为什么 `map` 不够，必须要有 `flatMap`

先看 `Optional` 场景。

假设：

```java
class User {
    Optional<Address> getAddress() {
        ...
    }
}
```

如果你这样写：

```java
Optional<Optional<Address>> result = userOpt.map(User::getAddress);
```

你会得到：

- 外层一个 `Optional`
- 里面又套了一个 `Optional`

这通常不是你想要的。

这时候就应该用 `flatMap`：

```java
Optional<Address> result = userOpt.flatMap(User::getAddress);
```

所以在 `Optional` 里你可以这样记：

- 映射函数返回普通值，用 `map`
- 映射函数返回 `Optional`，用 `flatMap`

### 10. `Stream` 里的 `flatMap`

`Stream` 场景也一样。

例如：

```java
List<List<String>> data = List.of(
        List.of("a", "b"),
        List.of("c", "d")
);
```

如果你用 `map`：

```java
List<Stream<String>> result = data.stream()
        .map(List::stream)
        .toList();
```

你得到的是“流的列表”，结构还嵌套着。

如果你想把所有元素打平：

```java
List<String> result = data.stream()
        .flatMap(List::stream)
        .toList();
```

这样得到的就是：

```java
["a", "b", "c", "d"]
```

所以在 `Stream` 里也可以这样记：

- `map`：一个元素变一个元素
- `flatMap`：一个元素变一批元素，并把这一批元素摊平到同一条流里

### 11. 一张统一理解图

你可以把它们统一记成这样：

#### 11.1 `map`

```text
A -> B
```

或：

```text
Container<A> -> Container<B>
```

#### 11.2 `flatMap`

```text
A -> Container<B>
```

然后把结果“拍平”为：

```text
Container<B>
```

所以二者真正的区别不在“名字”，而在：

- 映射函数返回的是普通值
- 还是已经被包了一层的值

### 12. 一个特别好记的判断口诀

如果你总是记混，可以直接用这个判断方式：

- 如果转换函数返回普通对象，用 `map`
- 如果转换函数返回 `Optional` / `Stream` / 其他容器，用 `flatMap`

例如：

```java
userOpt.map(User::getName);
```

因为 `getName()` 返回 `String`。

```java
userOpt.flatMap(User::getAddress);
```

因为 `getAddress()` 返回 `Optional<Address>`。

```java
orders.stream().map(Order::getId);
```

因为 `getId()` 返回普通值。

```java
orders.stream().flatMap(order -> order.getItems().stream());
```

因为这里返回的是一个 `Stream<Item>`。

### 13. 常见误区

#### 13.1 误区一：lambda 会自动带来异步或高性能

不会。

`lambda` 只是更简洁地表达一段行为，它本身不代表：

- 新线程
- 异步
- 并行
- 更快

是否异步，取决于你把这段行为交给谁执行，比如线程池、`CompletableFuture`、并行流等。

#### 13.2 误区二：`Optional` 就是为了替代所有 `null`

也不是。

`Optional` 更像是“明确表达可能为空的返回值”，不是要把每个字段、每个参数都包起来。

#### 13.3 误区三：`map` 和 `flatMap` 只在 `Stream` 里有意义

不是。

它们本质上是一种通用的“容器变换”思维：

- `Optional` 能用
- `Stream` 能用
- `CompletableFuture` 里也能看到类似思想

#### 13.4 误区四：链式写法越长越高级

也不是。

如果链式调用太长、异常处理太复杂、业务规则太多，反而会降低可读性。  
这时候拆成几个局部变量或几个方法，通常更清晰。

## 一句话小结

- `lambda` 让“行为”可以被更轻量地传递。
- `lambda` 依附于函数式接口存在。
- `Optional` 用来显式表达“值可能不存在”。
- `map` 是普通映射，`flatMap` 是“映射后再拍平”。
- 判断 `map` 还是 `flatMap`，重点看映射函数返回的是普通值还是容器。

## 你现在应该能回答的问题

- Java 里的 `lambda` 为什么必须依附函数式接口？
- `Function`、`Consumer`、`Supplier`、`Predicate` 分别表示什么？
- `Optional` 为什么更适合作为返回值而不是字段？
- `Optional.map()` 和 `Stream.map()` 在抽象上有什么共同点？
- 为什么说 `flatMap` 的本质是“避免嵌套包装”？
- `Optional<Optional<T>>` 和 `Stream<Stream<T>>` 分别应该怎么拍平？
