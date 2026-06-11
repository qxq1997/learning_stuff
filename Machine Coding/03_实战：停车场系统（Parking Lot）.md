# 03 实战：停车场系统（Parking Lot）

停车场是 machine coding 出现频率最高的题，没有之一。它小到能在 90 分钟写完，又恰好把策略、工厂、门面、OCP、并发全考到。

> **这一章的读法（也是后面所有实战章的读法）**：第 2 章的七步法只是骨架，真正要练的是**每一步在脑子里怎么推**。所以这章每一步都拆成三层显出来——
> - **🤔 自问**：到这一步，我在问自己什么问题
> - **🔀 岔路**：我想到过哪些选项，为什么选这个、否掉那个（这里藏着最多得分点）
> - **💬 说出口**：嘴上怎么跟面试官讲（machine coding 也是沟通题）
>
> 代码是这三层想清楚之后**自然掉下来的产物**。你要练的是前三层，不是背代码。建议边读边把代码敲进 IDE 跑一遍。

---

## 第 1 步：需求澄清 —— 先别建模，先把题目「问小」

**🤔 自问**：题目只给了一句「设计一个停车场」。这范围可以无限大（会员、月卡、车牌识别、找车、支付、发票……）。我 90 分钟做不完所有，**我得先决定『做哪条主线』**。那么——这个系统**最核心、缺了就不成立**的动作是什么？

推导：一个停车场，剥到只剩骨头，就两个动作——**车进来（要有地方停、要拿凭证）、车出去（要算钱、要把位子腾出来）**。其它全是它俩的衍生。所以 MVP 锁定 `park` + `unpark` 两条主线，别的先不碰。

**🔀 岔路：我该问面试官几个问题？问哪些？**

不是问得越多越好（第 1 章红线：澄清别超过 8 分钟，问太多显得抓不住重点）。我只问**会改变代码结构**的问题，其余用合理假设钉死、说出来让对方有机会纠正：

| 我要问的 | 为什么问（它改变什么结构） |
| --- | --- |
| 单层还是多层？ | 决定 `ParkingFloor` 这个类要不要存在 |
| 车型/车位几种？有匹配规则吗？ | 决定 enum 取值 + 「能不能停」的判定逻辑 |
| 几个出入口？要考虑并发吗？ | 决定要不要加锁——这是后面最容易翻车的点 |
| 怎么收费？按时间？按车型？ | 决定计费要不要做成可替换 |

而像「要不要支付对接 / 持久化 / 会员」，我**不问、直接划到 scope 外**并说一句「这些我先不做」——因为它们不影响核心结构，做了纯属浪费时间。

**💬 说出口**：「我先把范围收一下——我理解核心是『进场分配车位 + 出场计费』两条主线。我打算支持多层、三种车型对三种车位、按时长和车型计费，分配和计费都做成可替换的策略。会员、支付、持久化我先放到扩展里不做。这样可以吗？」

拿到「可以」，把范围写在代码顶部注释（也是给自己看的边界）：

```
In scope :
  - 多层停车场，每层若干车位；三车型(摩托/小车/卡车) × 三车位(小/中/大)，有匹配规则
  - park: 分配车位 + 出停车票；unpark: 按时长计费 + 释放车位
  - 车位分配、计费 两个维度可替换
Out of scope :
  - 多入口排队、会员/月卡、车牌识别、找车、支付、发票、持久化
Assume :
  - 匹配：摩托可停 小/中/大；小车可停 中/大；卡车只能停 大
  - 计费按小时，车型不同费率不同，不足 1 小时按 1 小时
  - 找不到车位 → 抛异常；凭票出场
```

> 这一步的产物**不是代码，是一张边界**。它直接对应评分表「需求覆盖」，更重要的是防住了最惨的失分——写了半天不是面试官想要的。

---

## 第 2 步：名词 → 类 —— 圈名词，再做三选一分类

**🤔 自问**：上面那段 scope 里，哪些**名词**是我要建的东西？

先把名词全圈出来：**停车场、楼层、车位、车、停车票、车型、车位类型、车位状态、入口、收费**。

**🔀 岔路：圈出来的名词不是都要建类。每个我过一遍『三选一』**：

- **建成实体类**（有身份、状态会变）：停车场、楼层、车位、车、停车票 → `ParkingLot / ParkingFloor / ParkingSpot / Vehicle / Ticket`
- **建成 enum**（有限取值、用来描述）：车型、车位类型 → `VehicleType / SpotType`。看到「类型/状态/等级」这种词，几乎一定是 enum——这是消灭魔法字符串最便宜的动作
- **不建类**（scope 外或还不需要）：入口、收费员、闸机 → 划在 scope 外，**忍住不要建**。machine coding 里多建一个用不到的类，就是在给自己挖时间坑

**🔀 岔路（关键）：车要不要按车型建子类？**

我的第一反应是 OO 套路——`Car / Bike / Truck extends Vehicle`。停一下，问自己：**这三种车，行为有区别吗？** 现在没有，区别只在「类型不同导致能停的车位不同」，而这个区别我可以用一个 `VehicleType` 字段表达。**没有行为差异就别用继承**（YAGNI）。一个 `Vehicle` + `VehicleType` enum 足够。

> 什么时候才升级成继承？如果将来「卡车要占两个连续车位、摩托可以两辆共用一位」——**行为真的分叉了**，再抽子类。把这句话记住，面试官追问「为什么不用继承」时，这就是满分回答。

**🔀 岔路：「能不能停这种车」这条规则放哪？**

我的第一反应是写在分配逻辑里来个 `if (spotType==SMALL && vehicleType==BIKE)...`。再停一下：这条规则**本质是 `SpotType` 自己的属性**——「我这种车位能容纳哪些车」。按第 2 章「行为跟数据走」，它该长在 `SpotType` 上，而不是飘在外面某个 if。这样将来加车位类型，匹配规则跟着枚举值一起改，不会散落各处。

想清楚了，代码就掉下来了：

```java
public enum VehicleType { BIKE, CAR, TRUCK }

public enum SpotType {
    SMALL, MEDIUM, LARGE;

    // 匹配规则长在 SpotType 自己身上：这种车位能不能停这种车
    public boolean canFit(VehicleType v) {
        switch (this) {
            case SMALL:  return v == VehicleType.BIKE;
            case MEDIUM: return v == VehicleType.BIKE || v == VehicleType.CAR;
            case LARGE:  return true;                       // 大车位什么都能停
            default:     return false;
        }
    }
}
```

```java
public class Vehicle {                                      // 一个类 + 一个 type 字段，不建子类
    private final String licensePlate;
    private final VehicleType type;
    public Vehicle(String licensePlate, VehicleType type) {
        this.licensePlate = licensePlate; this.type = type;
    }
    public String getLicensePlate() { return licensePlate; }
    public VehicleType getType() { return type; }
}
```

```java
public class ParkingSpot {
    private final String id;
    private final SpotType type;
    private Vehicle currentVehicle;          // null = 空闲（用「有没有车」表达状态，不另起 enum）

    public ParkingSpot(String id, SpotType type) { this.id = id; this.type = type; }

    public boolean isFree() { return currentVehicle == null; }
    public boolean canPark(Vehicle v) { return isFree() && type.canFit(v.getType()); } // 空 且 匹配
    public void assign(Vehicle v) { this.currentVehicle = v; }   // 占用：改自己的状态
    public void release()        { this.currentVehicle = null; } // 释放：改自己的状态

    public String getId() { return id; }
    public SpotType getType() { return type; }
}
```

> 注意我刚才又做了个小决定：车位状态（空闲/占用）**没有**单独建 `SpotStatus` enum，而是用 `currentVehicle == null` 表达。因为状态只有两态、且和「停了哪辆车」天然绑定，多一个 enum 反而要维护两份真相。**这种「克制」也是评分点**——不是模式越多越好。

`ParkingFloor` 和 `Ticket` 是纯粹的承载，没什么可纠结的：

```java
public class ParkingFloor {
    private final int floorNumber;
    private final List<ParkingSpot> spots;
    public ParkingFloor(int floorNumber, List<ParkingSpot> spots) {
        this.floorNumber = floorNumber; this.spots = spots;
    }
    public List<ParkingSpot> getSpots() { return spots; }
    public int getFloorNumber() { return floorNumber; }
}
```

```java
public class Ticket {                                       // 进场凭证，出场时拿它算钱
    private final String id;
    private final Vehicle vehicle;
    private final ParkingSpot spot;
    private final Instant entryTime;
    public Ticket(String id, Vehicle vehicle, ParkingSpot spot, Instant entryTime) {
        this.id = id; this.vehicle = vehicle; this.spot = spot; this.entryTime = entryTime;
    }
    public String getId() { return id; }
    public Vehicle getVehicle() { return vehicle; }
    public ParkingSpot getSpot() { return spot; }
    public Instant getEntryTime() { return entryTime; }
}
```

---

## 第 3 步：动词 → 方法归属 —— 每个动作「该归谁管」

**🤔 自问**：scope 里的**动词**有哪些？每一个，**该是哪个类的方法**？这一步决定我会不会写出 God class。

圈动词：**进场、出场、找车位、占用、释放、计费、出票**。逐个定位——

- **占用 / 释放**：改的是 `ParkingSpot` 的状态 → 已经放在 `ParkingSpot.assign/release`（第 2 步顺手定了）。✅
- **找车位**：要遍历楼层挑一个 → 这是会变的规则，先记着，第 4 步抽成策略
- **计费**：按时长算钱 → 也是会变的规则，第 4 步抽成策略
- **进场 / 出场**：这俩是**编排**——把「找位 + 占用 + 出票」「算钱 + 释放」串起来。**它归谁？**

**🔀 岔路：`park` 这个方法到底挂在哪个类上？** 我列三个候选，逐一验：

| 候选 | 试着放上去 | 否掉的理由 |
| --- | --- | --- |
| `vehicle.park(lot)` | 让车自己去停 | 车得持有整个停车场的引用，职责严重错位——现实里也是「场」管车，不是「车」管场。否 |
| `spot.park(vehicle)` | 让车位接车 | 车位不该知道「停车票」「计费」「别的楼层」。让它编排全局，越权。否 |
| 新建 `ParkingLot` 门面 | 由停车场统一编排 | ✅ 它本来就该是这套系统对外的入口，编排进出场天经地义 |

所以 `park / unpark` 落在 `ParkingLot`。

**🔀 岔路（这是 God class 的悬崖）**：定了门面，紧接着一个危险念头会冒出来——「那找车位、算钱我也顺手写在 `ParkingLot` 里吧」。**打住。** 如果我把遍历找位、费率计算全塞进 `ParkingLot`，它就成了那个「既管车位又算钱又出票」的上帝类，职责单一这栏直接挂。

**正确的分工，一句话**：`ParkingLot` **只做编排**（调谁、按什么顺序），具体的「怎么找位」「怎么算钱」**委托出去**给策略。所以——

**💬 说出口**：「进出场的编排我放在 `ParkingLot` 门面里，但它只负责串流程；找车位和计费这两个『具体怎么算』的逻辑我会委托给独立的策略对象，避免 `ParkingLot` 变成什么都管的上帝类。」

这句话同时交代了「门面」和「为什么要策略」，顺势进入第 4 步。

---

## 第 4 步：找变化点 → 抽接口 —— 这是 OCP，也是这道题的灵魂

**🤔 自问**：第 3 步留了「找车位」「计费」两个委托出去的点。但我凭什么断定它们**值得抽成接口**，而不是过度设计？判据（第 2 章那句口诀）：**我能不能说出它至少两个真实变体？**

- **计费**：按小时？前 30 分钟免费？周末打折？会员折扣？——一口气能说四五个。✅ 值得抽
- **车位分配**：就近优先？随机？按楼层负载均衡？给残疾车留近位？——也能说好几个。✅ 值得抽

**🔀 岔路：哪些我故意『不抽』？** 同样用这把尺子量一遍：

- 「停车票 id 怎么生成」——UUID 就够，我想不出第二种**业务**变体 → 不抽，写死
- 「车位 id 格式」——同理 → 不抽

> 这一正一反才是这一步的精髓：**会变的抽、不变的写死**。两边都做对，才能同时拿下「可扩展」和「不过度设计」两栏。只抽不写死会过度设计，只写死不抽会不可扩展。

想清楚「抽哪两个」，接口和实现就掉下来了：

```java
// 变化点 1：车位分配。入参给全部楼层 + 车，返回选中的车位（可能没有 → Optional）
public interface SpotAllocationStrategy {
    Optional<ParkingSpot> findSpot(List<ParkingFloor> floors, Vehicle vehicle);
}

public class NearestFirstStrategy implements SpotAllocationStrategy {  // 默认：从低楼层起，第一个能停的
    @Override
    public Optional<ParkingSpot> findSpot(List<ParkingFloor> floors, Vehicle vehicle) {
        for (ParkingFloor floor : floors) {
            for (ParkingSpot spot : floor.getSpots()) {
                if (spot.canPark(vehicle)) return Optional.of(spot);
            }
        }
        return Optional.empty();
    }
}
```

```java
// 变化点 2：计费。入参给票（含进场时间、车型）+ 出场时间，返回金额
public interface FeeStrategy {
    double calculate(Ticket ticket, Instant exitTime);
}

public class HourlyFeeStrategy implements FeeStrategy {
    private static final Map<VehicleType, Double> RATE = Map.of(   // 车型 → 元/小时
            VehicleType.BIKE, 1.0, VehicleType.CAR, 2.0, VehicleType.TRUCK, 4.0);
    @Override
    public double calculate(Ticket ticket, Instant exitTime) {
        long minutes = Duration.between(ticket.getEntryTime(), exitTime).toMinutes();
        long hours = Math.max(1, (long) Math.ceil(minutes / 60.0));  // 不足 1 小时按 1 小时
        return hours * RATE.get(ticket.getVehicle().getType());
    }
}
```

**💬 说出口（这就是扩展性追问的标准答案，提前埋好）**：「计费和分配我都抽成了接口。比如你等会儿要我加一个『前 30 分钟免费』的规则，我只需要新增一个 `FreeFirst30MinFeeStrategy implements FeeStrategy`，构造停车场时传进去，`ParkingLot` 一行都不用改——这就是开闭原则。」

---

## 第 5 步：设计门面 API —— 定方法签名时，每个返回值/参数都有理由

**🤔 自问**：driver 只跟 `ParkingLot` 打交道。它对外就两个方法，但**签名怎么定**？我逐个抠入参、返回、异常——这些细节最能体现工程素养。

**🔀 岔路 1：`park` 返回什么？** 第一反应 `void`。但马上想到：车出场时拿什么来对应它停的位子、它的进场时间？**调用方需要一个凭证** → 返回 `Ticket`。

**🔀 岔路 2：`unpark` 的出场时间，是参数传进来，还是方法内部 `Instant.now()`？** 这个点很关键。如果内部 `now()`，我在 driver 里**没法演示「停了 90 分钟」**——总不能真等 90 分钟。把 `exitTime` 作为**参数**传进来：既可测试、又可演示。

> 这是个会被面试官暗暗加分的细节：**把时间作为入参注入，而不是在方法里取当前时间**——可测试性的典型体现。主动说出来。

**🔀 岔路 3：失败怎么表达？** 找不到车位，返回 `null`？返回 `-1`？——都不好：调用方容易漏判，语义也不清。用**自定义异常**，名字本身就是文档：

```java
public class ParkingFullException extends RuntimeException {
    public ParkingFullException(String plate) {
        super("没有适配车位，车辆 " + plate + " 无法进场");
    }
}
```

于是门面契约定稿（先写签名 + 注释，实现下一步填）：

```java
public class ParkingLot {
    Ticket park(Vehicle vehicle);                  // 进场：成功返回票；无适配车位 → 抛 ParkingFullException
    double unpark(String ticketId, Instant exitTime); // 出场：返回费用；票无效 → 抛 IllegalArgumentException
}
```

**💬 说出口**：「`park` 返回一张票作为出场凭证；`unpark` 我特意把出场时间作为参数传入而不是方法内部取当前时间，这样既好测试也好演示。失败我用自定义异常表达，而不是返回 null。」

---

## 第 6 步：实现门面 —— 装配，以及「到底要不要加锁」

**🤔 自问 1：编码顺序？** 按依赖从底到上：enum → model → 接口 → 策略 → **门面** → driver。前面几层都写完了，现在装配门面。门面持有什么？楼层、两个策略、一份「在场票据」的存储。策略**由构造函数注入**（依赖接口不依赖实现，DIP）。

**🤔 自问 2（这道题最容易翻车的点）：我到底要不要处理并发？** 回到第 1 步——我问过「几个入口」。如果是多入口，就有多个线程同时 `park`。那竞态到底在哪？

**🔀 岔路：把竞态想具体，而不是笼统说『加个锁』。** 两个线程 A、B 同时给两辆车找位：

```
线程A: findSpot 遍历 → 看到 spot#5 是空的
线程B: findSpot 遍历 → 也看到 spot#5 是空的   ← 二者都基于「空」做了决定
线程A: spot#5.assign(carA)
线程B: spot#5.assign(carB)   ← carA 被覆盖！两辆车占了同一个位
```

这是典型的 **check-then-act（先检查后动作）竞态**。

**🔀 岔路：用 `ConcurrentHashMap` 能解决吗？** 不能！`ConcurrentHashMap` 只保证**单次 put/get 原子**，但「遍历找空位」+「占用」是**两个动作的组合**，它管不了。要保证组合原子，必须把「找位 + 占位」整段包进同一个临界区 —— `synchronized`（或 `ReentrantLock`）。票据存储另说，那个用 `ConcurrentHashMap` 没问题。

> 这正是很多人答错的地方：以为换上并发容器就线程安全了。**线程安全的边界是『复合操作』，不是『单个数据结构』。** 能讲清这一点，并发这栏稳拿。

想清楚锁加在哪、为什么，实现就掉下来了：

```java
public class ParkingLot {
    private final List<ParkingFloor> floors;
    private final SpotAllocationStrategy allocationStrategy;   // 依赖接口，构造注入（DIP）
    private final FeeStrategy feeStrategy;
    private final Map<String, Ticket> activeTickets = new ConcurrentHashMap<>();
    private final Object lock = new Object();                  // 专门保护「找位+占位」复合操作

    public ParkingLot(List<ParkingFloor> floors,
                      SpotAllocationStrategy allocationStrategy,
                      FeeStrategy feeStrategy) {
        this.floors = floors;
        this.allocationStrategy = allocationStrategy;
        this.feeStrategy = feeStrategy;
    }

    public Ticket park(Vehicle vehicle) {
        synchronized (lock) {                                  // ← 找位 + 占位 必须在同一临界区
            ParkingSpot spot = allocationStrategy.findSpot(floors, vehicle)
                    .orElseThrow(() -> new ParkingFullException(vehicle.getLicensePlate()));
            spot.assign(vehicle);
            Ticket ticket = new Ticket(UUID.randomUUID().toString(),
                                       vehicle, spot, Instant.now());
            activeTickets.put(ticket.getId(), ticket);
            return ticket;
        }
    }

    public double unpark(String ticketId, Instant exitTime) {
        Ticket ticket = activeTickets.remove(ticketId);
        if (ticket == null) throw new IllegalArgumentException("无效或已使用的停车票: " + ticketId);
        double fee = feeStrategy.calculate(ticket, exitTime);  // 算钱委托给策略，门面不碰公式
        synchronized (lock) { ticket.getSpot().release(); }    // 释放也是写状态，进锁
        return fee;
    }
}
```

回头看这个门面，每行都对应一栏评分——**这就是『想清楚』的回报**：

- 计费委托 `feeStrategy`、找位委托 `allocationStrategy`、占用/释放委托 `ParkingSpot`，门面自己不算钱不遍历 → **职责单一**，没有 God class
- 只持有接口、构造注入 → **可扩展（OCP/DIP）**
- `synchronized` 包住 check-then-act、票据用并发容器 → **并发**
- 满了抛 `ParkingFullException`、票无效抛 `IllegalArgumentException` → **异常处理**

---

## 第 7 步：写 Driver —— 演示脚本要「证明什么」，反推该跑哪几条

**🤔 自问**：driver 不是随便 `new` 几下打印一下。它是**演示脚本**，我要想清楚「我想向面试官证明哪几件事」，再反推跑哪几条 case：

1. 证明**主流程通**：一辆车进场→出场，费用算对 → happy path
2. 证明**满了会拦**：把唯一的大车位占掉，再来一辆卡车 → 触发 `ParkingFullException`（正好演示第 5 步定的异常出口 1）
3. 证明**乱输入不崩**：拿不存在的票出场 → 触发 `IllegalArgumentException`（演示异常出口 2）

边界不是随便选的——**它们对应我亲手定义的两个异常出口**，把「异常处理」这栏从「我写了」变成「我演给你看了」。

```java
public class Driver {
    public static void main(String[] args) {
        // 造一个 2 层停车场（这段造对象逻辑较长，是 Builder/工厂的天然候选，见下文模式地图）
        ParkingFloor f1 = new ParkingFloor(1, List.of(
                new ParkingSpot("1-S1", SpotType.SMALL),
                new ParkingSpot("1-M1", SpotType.MEDIUM),
                new ParkingSpot("1-L1", SpotType.LARGE)));
        ParkingFloor f2 = new ParkingFloor(2, List.of(
                new ParkingSpot("2-M1", SpotType.MEDIUM)));

        ParkingLot lot = new ParkingLot(
                List.of(f1, f2),
                new NearestFirstStrategy(),     // ← 换分配策略只改这一行（OCP 的可见证据）
                new HourlyFeeStrategy());

        // —— happy path：小车进场又出场 ——
        Vehicle car = new Vehicle("京A·12345", VehicleType.CAR);
        Ticket t = lot.park(car);
        System.out.println("进场，车位=" + t.getSpot().getId());          // 期望 1-M1（就近，跳过只容摩托的 S）
        double fee = lot.unpark(t.getId(), t.getEntryTime().plus(Duration.ofMinutes(90)));
        System.out.println("出场，停 90 分钟，费用=" + fee);                // 期望 2 小时 × 2 = 4.0

        // —— 边界 1：卡车只能停 LARGE，占掉唯一的 L，再来一辆 ——
        lot.park(new Vehicle("京B·truck1", VehicleType.TRUCK));           // 占掉 1-L1
        try {
            lot.park(new Vehicle("京B·truck2", VehicleType.TRUCK));       // 没 LARGE 了
        } catch (ParkingFullException e) {
            System.out.println("预期异常: " + e.getMessage());
        }

        // —— 边界 2：用一张无效票出场 ——
        try { lot.unpark("不存在的票", Instant.now()); }
        catch (IllegalArgumentException e) { System.out.println("预期异常: " + e.getMessage()); }
    }
}
```

**💬 说出口**：「我跑一条正常进出场证明主流程，再跑两个边界——车位满和无效票——它们正好对应我前面定的两个异常出口。」

跑通它，你交出的就是一个**能跑、覆盖主流程、职责清晰、两个变化点可扩展、处理了并发与异常、可演示**的系统——评分九栏全部命中。

> 全部类放进一个 `.java` 文件（或一个包）即可编译；`import java.time.*; java.util.*; java.util.concurrent.*;`。

---

## 回看：这道题的设计模式地图

写完再回头标，比一开始就想「我要用哪些模式」健康得多——**模式是想清楚之后的命名，不是出发点**：

| 模式 | 落在哪 | 当初是哪一步「想」出来的 |
| --- | --- | --- |
| **策略 Strategy** | `SpotAllocationStrategy` / `FeeStrategy` | 第 4 步：能说出 ≥2 变体的维度 |
| **门面 Facade** | `ParkingLot` | 第 3 步：编排该归谁，排除车/车位后剩下的 |
| **工厂 / Builder（可选）** | driver 里那段造停车场的逻辑 | 第 7 步：发现构造冗长，可收敛 |
| （慎用）单例 | 全局唯一 `ParkingLot` | 题目若强调「就一个场实例」才加 |

**别过度**：这道题「2 个策略 + 门面」就够拿高分。硬上抽象工厂 + 装饰器（叠折扣）+ 观察者（车位变化推大屏），时间会被烧光、主流程跑不通（第 1 章失分点 #4）。**先跑通这个版本，把省下的时间用来口头讲「要加折扣/通知我会怎么扩展」，比真写出来更划算。**

---

## 常见追问与应答（都用前面的推导直接回）

- **「加一种新车型（电动车要充电桩车位）？」** → `VehicleType` 加枚举值，`SpotType.canFit` 加匹配规则；要新车位类型同理。核心实体不动（呼应第 2 步「没行为差异不建子类」）
- **「加『前 30 分钟免费』计费？」** → 新增一个 `FeeStrategy` 实现，构造注入，门面不动（第 4 步埋好的 OCP）
- **「多入口并发会不会抢到同一个位？」** → 不会，`park` 里 `synchronized` 把 check-then-act 包成原子（第 6 步）；要更高并发可降锁粒度到「每层一把锁」，或用 `AtomicInteger` 维护各类型空位数做无锁预筛
- **「停车场很大，遍历找位慢？」** → 这是优化，不是主流程。可为每种 `SpotType` 维护空闲车位 `Deque`，park 取 O(1)、unpark 还 O(1)。**但只在主流程跑通且有余力时再做**

---

## 检查站

1. 第 1 步你会问面试官哪几个问题、哪些直接假设掉？判断「问还是假设」的标准是什么？
2. 车为什么不按车型建 `Car/Bike/Truck` 子类？什么情况下你才会改用继承？
3. `park` 这个方法，为什么不放在 `Vehicle` 或 `ParkingSpot` 上，而是放在 `ParkingLot` 门面？放上去之后，又要警惕它变成什么？
4. 第 4 步你用什么判据决定「计费」该抽接口、而「停车票 id 生成」不抽？把这两个一起答出来
5. 多入口并发下，为什么把存储换成 `ConcurrentHashMap` **还不够**？竞态具体发生在哪两步之间？锁该加在哪段代码上？
6. `unpark` 为什么把 `exitTime` 作为参数传入，而不是在方法里 `Instant.now()`？
7. 只剩 20 分钟，你砍哪些、保哪些？（用「能跑 > 覆盖 > 干净 > 可扩展 > 优化」回答）

下一道实战（规划中 `04`）是 **Splitwise 分账系统**，我会用同样的「自问 / 岔路 / 说出口」节奏带你推一遍，重点是把策略模式用在「均摊 / 精确 / 百分比」三种拆分上，并处理「余额图简化」这个有点算法味的扩展点。
