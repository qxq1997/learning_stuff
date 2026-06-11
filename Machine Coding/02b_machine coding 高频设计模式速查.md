# 02b Machine Coding 高频设计模式速查

machine coding 这一轮**不考你背 23 个 GoF 模式**,只考一件事:在该用模式的地方恰当地用,在不该用的地方克制住。所以这章不是模式百科,而是一张实战速查表——

> **从「需求里的信号」直接查到「该上哪个模式」,给出最小 Java 骨架,并标注什么时候千万别用。**

它和第 2 章的七步法咬合:**七步法第 4 步「找变化点」找出的那个变化点,它的「形状」决定你用哪个模式。** 这章就是把「形状 → 模式」这张映射表给你。

---

## 怎么用这张速查表

写代码前,把需求里的关键句对照下面这张表,信号命中就候选对应模式。**但记住:候选不等于必用**——还要过一遍最后一节「什么时候不该上模式」。

| 你在需求里看到 / 脑子里想到 | 八成要用 | 典型落点 |
| --- | --- | --- |
| 「按**不同规则**计算 / 选择 / 拆分 / 淘汰」 | **策略 Strategy** | 计费、分配、拆分、限流算法、缓存淘汰 |
| 「**根据 type** 创建不同对象」 | **工厂 Factory** | 按车型造车、按渠道造通知、按类型造棋子 |
| 「对象有**生命周期 / 状态流转**,每个状态行为不同」 | **状态 State** | 订单、电梯、售货机、ATM、红绿灯 |
| 「一个事件要**通知多个**对象」「状态变了要推送」 | **观察者 Observer** | 订单推送、空位大屏、库存预警、广播 |
| 「全局**唯一**的 X」 | **单例 Singleton** | 系统门面、Logger、ID 生成器、注册表 |
| 「构造参数多 / 可选项多 / 分步构建」 | **建造者 Builder** | 复杂配置、棋盘/停车场初始化 |
| 「在基础能力上**叠加 / 组合**可选特性」 | **装饰器 Decorator** | 咖啡加料、计费叠券、包装 Logger |
| 「把**操作变成对象**」「支持撤销 / 重做 / 排队」 | **命令 Command** | 编辑器 undo、遥控器、任务队列 |
| 「请求**依次经过**多个处理者」「逐级处理」 | **责任链 CoR** | 日志级别、ATM 出钞、审批流、拦截器 |
| 「实体要**存取**,但想和业务解耦」 | **仓储 Repository** | 几乎每道题的内存存储 |

下面分两个梯队展开。**第一梯队 5 个模式覆盖了 80% 的 machine coding 题**,务必熟到能默写骨架;第二梯队看到特定信号才上。

---

## 第一梯队:80% 的题都会用到

### 1. 策略 Strategy ⭐ 最高频

- **触发信号**:「按不同规则计算 / 选择 / 拆分 / 淘汰」——任何「同一件事有多种做法且会变」的维度
- **典型落点**:停车场计费 & 车位分配、Splitwise 拆分(均摊/精确/百分比)、限流算法(令牌桶/滑窗)、缓存淘汰(LRU/LFU)、打车计价、支付方式
- **它就是 OCP 的化身**:新增做法 = 加新实现类,门面一行不改

```java
interface FeeStrategy { double calculate(Ticket t, Instant exit); }

class HourlyFeeStrategy   implements FeeStrategy { /* 按小时 */ }
class FreeFirst30Strategy implements FeeStrategy { /* 前30分钟免费 */ }  // 新增不动老代码

class ParkingLot {
    private final FeeStrategy feeStrategy;                 // 依赖接口
    ParkingLot(FeeStrategy feeStrategy){ this.feeStrategy = feeStrategy; } // 构造注入(DIP)
}
```

> **落地三连**:抽接口 → 写多个实现 → 门面持接口字段并由构造注入。这三步就是 OCP 在 machine coding 里的标准动作,记死。
>
> **别滥用**:只有一种实现、且你想不出第二种变体时,别为它抽策略——那是过度设计。

### 2. 工厂 Factory（Simple Factory / Factory Method）

- **触发信号**:「根据 type 创建不同对象」——创建逻辑有分支、或想把「new 谁」从业务里挪走
- **典型落点**:按 `VehicleType` 造 `Vehicle`、按渠道造 `Notifier`(SMS/Email/Push)、按类型造棋子
- **和策略的区别**:工厂解决「**创建谁**」,策略解决「**行为怎么变**」。常一起用——工厂造出策略对象

```java
class NotifierFactory {                                   // Simple Factory:够用、最常见
    static Notifier create(Channel channel) {
        switch (channel) {
            case SMS:   return new SmsNotifier();
            case EMAIL: return new EmailNotifier();
            case PUSH:  return new PushNotifier();
            default:    throw new IllegalArgumentException("未知渠道: " + channel);
        }
    }
}
```

> 何时升级到 **Factory Method**(把创建延迟到子类):创建逻辑本身也会随产品族变化时。machine coding 里 **90% 用 Simple Factory 就够**,别上来就抽象工厂。

### 3. 状态 State

- **触发信号**:「对象有生命周期,在不同状态下**同一个动作行为不同**,且状态会流转」
- **典型落点**:订单(待支付/已支付/已发货/已完成)、电梯(上行/下行/空闲)、售货机、ATM、红绿灯
- **它替代的坏味道**:`enum 状态 + 满地的 switch(state)`——加一个状态要改 N 处 switch,极易漏改

```java
interface OrderState {                                    // 每个状态知道自己能干什么、下一步去哪
    void pay(OrderContext ctx);
    void ship(OrderContext ctx);
}
class CreatedState implements OrderState {
    public void pay(OrderContext ctx){ ctx.setState(new PaidState()); }   // 合法流转
    public void ship(OrderContext ctx){ throw new IllegalStateException("未支付不能发货"); }
}
class PaidState implements OrderState {
    public void pay(OrderContext ctx){ throw new IllegalStateException("重复支付"); }
    public void ship(OrderContext ctx){ ctx.setState(new ShippedState()); }
}
class OrderContext {                                      // Context 持有当前状态,把动作委托出去
    private OrderState state = new CreatedState();
    void setState(OrderState s){ this.state = s; }
    void pay(){ state.pay(this); }
    void ship(){ state.ship(this); }
}
```

> **别强上**:状态 ≤ 3 个且转换简单(比如开/关),`enum` + 一个方法就够,上 State 反而啰嗦。状态多、转换规则复杂、非法转换要拦截时才值得。

### 4. 观察者 Observer

- **触发信号**:「一个事件发生,要通知**多个**互不相关的对象」「状态变了要推送 / 广播」
- **典型落点**:订单状态推送给用户+商家+物流、停车场空位变化刷新大屏、库存低于阈值告警、聊天室广播

```java
interface OrderObserver { void onStatusChanged(Order order); }

class Order {                                             // Subject
    private final List<OrderObserver> observers = new ArrayList<>();
    void subscribe(OrderObserver o){ observers.add(o); }
    void setStatus(Status s){
        this.status = s;
        observers.forEach(o -> o.onStatusChanged(this));  // 一变,全员通知
    }
}
// SmsObserver / DashboardObserver / WarehouseObserver 各自实现,互不知道对方
```

> **别滥用**:只有一个固定下游时,直接调用即可,别为「将来可能有更多下游」就提前上观察者——那是过度设计的典型借口。

### 5. 单例 Singleton

- **触发信号**:「系统里全局**唯一**的 X」——系统门面、配置、ID 生成器、内存注册表
- **典型落点**:全局唯一的 `ParkingLot`、`Logger`、`IdGenerator`
- **首选写法:枚举单例**(线程安全、防反射/反序列化破坏,最简洁)

```java
enum IdGenerator {
    INSTANCE;
    private final AtomicLong seq = new AtomicLong();
    public long next(){ return seq.incrementAndGet(); }
}
// 用:IdGenerator.INSTANCE.next();
```

> **最易被滥用的模式**:别把单例当全局变量到处塞,它会让代码难测试、隐藏依赖。**能用构造注入就别用单例**;只有「逻辑上确实全局唯一」时才用。面试官看到滥用单例会扣「可测试性 / 职责」分。

---

## 第二梯队:看到特定信号才上

### 6. 建造者 Builder

- **信号**:对象构造参数多 / 可选项多 / 想分步、可读地构建
- **落点**:复杂配置对象、棋盘或停车场的初始化、复杂请求对象

```java
ParkingLot lot = ParkingLot.builder()
        .addFloor(floor1).addFloor(floor2)
        .allocation(new NearestFirstStrategy())
        .fee(new HourlyFeeStrategy())
        .build();
```

> 把第 3 章 driver 里那段冗长的「造停车场」逻辑收敛掉,正是 Builder 的用武之地。

### 7. 装饰器 Decorator

- **信号**:在一个基础能力上**动态叠加多个**可选特性(注意是「叠加」,不是「二选一」)
- **落点**:咖啡 / 披萨加料、计费在基础上叠折扣券 + 会员减免、给 `Logger`/`DataSource` 套一层
- **vs 策略**:策略是「在几种做法里**选一个**」,装饰器是「把多个增强**层层包起来**」

```java
interface Coffee { double cost(); }
class Espresso implements Coffee { public double cost(){ return 10; } }

abstract class AddOn implements Coffee {                  // 装饰器:同接口 + 持有被装饰者
    protected final Coffee inner;
    AddOn(Coffee inner){ this.inner = inner; }
}
class Milk  extends AddOn { Milk(Coffee c){super(c);}  public double cost(){ return inner.cost()+2; } }
class Sugar extends AddOn { Sugar(Coffee c){super(c);} public double cost(){ return inner.cost()+1; } }
// new Sugar(new Milk(new Espresso())).cost()  →  13,可任意叠加
```

### 8. 命令 Command

- **信号**:「把一个**操作封装成对象**」——需要撤销/重做、排队、记录日志、参数化操作
- **落点**:文本编辑器 undo/redo、遥控器、任务队列、事务操作日志

```java
interface Command { void execute(); void undo(); }
class InsertTextCommand implements Command {
    private final Document doc; private final String text;
    InsertTextCommand(Document doc, String text){ this.doc = doc; this.text = text; }
    public void execute(){ doc.append(text); }
    public void undo(){ doc.removeLast(text.length()); }  // undo 的关键:命令记得怎么回滚自己
}
// Invoker 维护一个 Deque<Command> 历史栈,撤销就 pop 出来 undo()
```

### 9. 责任链 Chain of Responsibility

- **信号**:「请求**依次经过**多个处理者」「逐级处理 / 谁能处理谁处理」
- **落点**:日志按级别过滤、ATM 按面额逐级出钞、审批流、Web 中间件/拦截器、敏感词多级校验

```java
abstract class Handler {
    protected Handler next;
    Handler setNext(Handler next){ this.next = next; return next; }
    abstract void handle(Request req);
    protected void passToNext(Request req){ if (next != null) next.handle(req); }
}
// InfoHandler -> WarnHandler -> ErrorHandler,每个处理自己该处理的,其余转交 next
```

> 你「飞猪敏感词校验」专题里的「自建词库 → 未命中调第三方」其实就是一条责任链的雏形,可以互相印证。

### 10. 仓储 Repository / 内存 DAO（非 GoF,但 machine coding 必用）

- **信号**:machine coding 全程内存态,但你想把「存取实体」和「业务逻辑」分开,让门面不直接操作 `Map`
- **落点**:几乎每道题的实体存储

```java
interface BookRepository {
    void save(Book book);
    Optional<Book> findByIsbn(String isbn);
}
class InMemoryBookRepository implements BookRepository {  // 现在用 Map
    private final Map<String, Book> store = new ConcurrentHashMap<>();
    public void save(Book b){ store.put(b.getIsbn(), b); }
    public Optional<Book> findByIsbn(String isbn){ return Optional.ofNullable(store.get(isbn)); }
}
```

> **价值**:业务层只依赖 `BookRepository` 接口,将来「换成数据库」只换一个实现类。这正是 DIP,也让面试官看到你有分层意识。machine coding 里这是「优雅但低成本」的加分项。

---

## 每道经典题的模式地图（对照背）

| 经典题 | 主力模式 | 次要模式 |
| --- | --- | --- |
| 停车场 Parking Lot | 策略(计费 + 分配)、门面 | 工厂(造车)、单例、Builder |
| Splitwise 分账 | 策略(均摊/精确/百分比) | 观察者(余额变动通知) |
| 电梯调度 | 状态(运行方向) + 策略(调度算法) | 观察者(楼层显示) |
| 售货机 Vending Machine | 状态(投币/选货/出货) | 策略(找零) |
| 限流器 Rate Limiter | 策略(令牌桶/滑窗) | 单例 |
| 日志框架 Logger | 责任链(级别) + 策略(输出目标) | 单例 |
| 文本编辑器 | 命令(undo/redo) | 备忘录(快照) |
| 订票 BookMyShow | 状态(座位锁定) + 策略(支付) | 观察者(开售通知) |
| 棋类 / 井字棋 | 策略(走子规则) + 工厂(造棋子) | 状态(回合切换) |
| 咖啡机 / 披萨店 | 装饰器(加料) | 工厂(造基底) |

> 这张表的用法:拿到题先归类,八成能在这里找到「主力模式」,直接套七步法第 4 步去抽接口。

---

## 反过度设计:什么时候**不该**上模式

machine coding 评分表里有一栏专门叫「**模式恰当、不过度**」——上错模式和不用模式一样扣分。克制是能力。判断口诀:

> **你能说出至少 2 个真实变体,才值得为这个维度上模式;说不出第二个,就先写死。**

具体红线:

- **只有一种实现** → 别抽策略 / 接口。`FeeStrategy` 只有一个 `HourlyFeeStrategy` 且想不出第二种,就别抽
- **状态 ≤ 3 且转换简单** → 用 `enum` + 一个方法,别上 State 模式
- **只有一个固定下游** → 直接方法调用,别上 Observer
- **构造参数 ≤ 3 个** → 直接构造函数,别上 Builder
- **没有撤销 / 排队需求** → 别把普通方法包成 Command
- **全局唯一是「现在唯一」而非「逻辑必然唯一」** → 用构造注入,别上 Singleton

反面教材:有人把停车场写成「抽象工厂造楼层 + 装饰器叠计费 + 观察者推大屏 + 责任链找车位 + 命令模式记进出场」,90 分钟全花在搭架子上,主流程没跑通——这是 machine coding 最典型的死法(第 1 章失分点 #4)。**先用『2 个策略 + 门面』把它跑通,把省下的时间用来口头讲「如果要加折扣/通知我会怎么扩展」,比真写出来更划算。**

---

## 检查站

1. 给你这三句需求,各自八成该上哪个模式?——①「电梯空闲时和上行时,来了请求处理逻辑不一样」②「计费要支持按小时、前30分钟免费、周末打折」③「订单状态一变,要同时通知用户、商家、物流」
2. 策略和工厂常一起出现,它俩各自解决什么问题?策略和装饰器又有什么本质区别?
3. State 模式替代的是哪种坏味道?什么情况下你**不该**上 State、用 enum 就够?
4. 单例为什么是「最容易被滥用」的模式?你判断「该不该用单例」的标准是什么?
5. 用「能说出≥2个真实变体才抽」这条口诀,判断:停车场题里「车牌号怎么存」该不该抽接口?「计费规则」呢?

下一步可以回到实战:`03` 停车场已经用了策略 + 门面 + 工厂思想,你可以对照这章重新读一遍,看每个模式是怎么落地的;再往后 `04` Splitwise 会把策略模式用到极致。
