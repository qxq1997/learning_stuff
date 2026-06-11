# 04 实战：Splitwise 分账系统

Splitwise 是和停车场并列的 machine coding 头号高频题。它的考点和停车场不一样：停车场考「状态 + 并发」，Splitwise 考「**数据建模 + 策略 + 一点算法味**」——「谁欠谁」这张账怎么建模、三种拆分方式怎么不写成一坨 if-else、要不要做债务简化。岔路比停车场更密，正好接着练第 3 章那套思考节奏。

> 读法同 03：每步拆 **🤔 自问 / 🔀 岔路 / 💬 说出口**，代码是想清楚之后掉下来的产物。

---

## 第 1 步：需求澄清 —— 找到那个「缺了就不成立」的动作

**🤔 自问**：「设计一个 Splitwise」也是个能无限发散的题（群组、好友、还款提醒、多币种、消费记录、活动……）。剥到只剩骨头，**这个系统存在的意义是什么**？

推导：一句话——**几个人一起花钱，系统帮你记清「谁该给谁多少」**。所以唯一不可缺的动作是：**记一笔支出（addExpense）→ 它怎么分摊 → 更新「谁欠谁」这张账**。其余全是衍生。MVP 锁定：`addExpense`（带一种拆分方式）+ `showBalances`（看账）。

**🔀 岔路：问哪几个问题？** 还是只问**改变结构**的：

| 要问的 | 它改变什么结构 |
| --- | --- |
| 拆分方式有几种？（均摊 / 精确金额 / 百分比） | 决定要不要、抽几个 `SplitStrategy` |
| 「看账」是看「我欠谁、谁欠我」明细，还是只看一个净额？ | **决定核心数据结构**——这是这题最重要的一问 |
| 要不要「还款 / 结算」(settle up)？ | 决定要不要 `settle` 动作 |
| 要不要把「A 欠 B、B 欠 C」**简化**成更少的转账？ | 经典扩展点，先放扩展、最后做 |

像群组、好友关系、多币种、提醒，我**直接划到 scope 外**——不影响核心账本结构。

**🔀 岔路（很多人忽略、但能立刻拉开差距）：钱怎么存？** 我脑子里第一个蹦出来的是 `double amount`。**立刻否掉**——`0.1 + 0.2 != 0.3`，钱用浮点会在分账累加里越滚越歪。两个干净选择：`BigDecimal`，或**用最小货币单位（分）的整数 `long`**。我选后者：整数没有精度问题，而且后面处理「均摊除不尽的余数」时整数运算最干净。这一句主动说出来，工程素养分就到手了。

**💬 说出口**：「核心动作是『记一笔支出 + 按某种方式分摊 + 更新谁欠谁』。我打算支持均摊、精确、百分比三种拆分；账本要能查到两两之间『谁欠谁』而不只是净额。还款我做一个简单版，债务简化作为扩展最后做。还有——金额我用『分』的整数存，不用 double，避免浮点误差。这样可以吗？」

```
In scope :
  - addExpense：一笔支出由某人垫付，按 均摊/精确/百分比 分摊给若干参与人，更新账本
  - showBalances：查「谁欠谁多少」（两两明细，会自动净额抵消）
  - settle：某人还另一人一笔钱
Out of scope :
  - 群组/好友、多币种、提醒、消费历史、登录
Assume :
  - 金额用「分」(long) 存，杜绝浮点误差
  - 拆分后各份额之和必须严格等于总额（精确）/ 百分比之和必须为 100，否则报错
  - 均摊除不尽时，余数（几分钱）依次分给前几位参与人，保证总额精确闭合
扩展（跑通后/被问到再做）：
  - 债务简化：把账本净额化后，用最少的转账笔数结清
```

---

## 第 2 步：名词 → 类 —— 核心是「谁欠谁」这张账怎么建模

**🤔 自问**：圈名词——**用户、支出、参与人份额、账本、拆分方式**。哪些建类、哪些 enum、哪些不建？

- **实体**：`User`、`Expense`（一笔支出）、`Split`（某参与人在这笔里应承担多少）、`BalanceSheet`（账本）
- **不建**：群组、好友——scope 外

**🔀 岔路（这题的命门）：「谁欠谁」用什么数据结构？** 我列两个方案当面权衡：

| 方案 | 长相 | 问题 |
| --- | --- | --- |
| A：每人一个净额 | `Map<用户, 净额>`，正=别人欠他，负=他欠别人 | 丢了「**对谁**」的信息——回答不了「我欠 Bob 多少」。否（除非只做债务简化） |
| B：两两账本 | `Map<债务人, Map<债权人, 金额>>`，`balances[A][B]` = A 欠 B 多少 | 能回答任意两人之间，是 Splitwise 的核心诉求。✅ |

选 B。关键技巧：每次记账**同时更新两个方向**——`balances[A][B] += x` 且 `balances[B][A] -= x`。这样「B 先欠 A 500、A 又欠 B 400」会自动净额抵成「B 欠 A 100」，查账时天然抵消，不用额外算。

**🔀 岔路：要不要建一个 `SplitType { EQUAL, EXACT, PERCENT }` 枚举？** 第一反应想建。停一下——第 4 步我会为每种拆分建一个**策略类**，**策略对象本身就代表了「类型」**。再加个 enum 就是两份真相（加一种拆分要同时改 enum 和加类）。所以**不建** enum，直接用策略对象。（呼应 03「车位状态不另建 enum」那个克制。）

想清楚，实体就掉下来了：

```java
public class User {
    private final String id;
    private final String name;
    public User(String id, String name) { this.id = id; this.name = name; }
    public String getId() { return id; }
    public String getName() { return name; }
}
```

```java
// 某参与人在某笔支出里应承担的份额（金额单位：分）
public class Split {
    private final String userId;
    private final long amountCents;
    public Split(String userId, long amountCents) { this.userId = userId; this.amountCents = amountCents; }
    public String getUserId() { return userId; }
    public long getAmountCents() { return amountCents; }
}
```

```java
public class BalanceSheet {
    // balances.get(A).get(B) = A 欠 B 的钱（分）；负数表示 B 欠 A
    private final Map<String, Map<String, Long>> balances = new HashMap<>();

    /** 记一笔：debtor 欠 creditor amount 分；两个方向同时更新，实现自动净额抵消 */
    public void adjust(String debtor, String creditor, long amount) {
        balances.computeIfAbsent(debtor,   k -> new HashMap<>()).merge(creditor, amount,  Long::sum);
        balances.computeIfAbsent(creditor, k -> new HashMap<>()).merge(debtor,  -amount, Long::sum);
    }

    /** 打印所有「X 欠 Y」的正向条目（负向是镜像，跳过避免重复） */
    public void show() {
        for (var debtorEntry : balances.entrySet()) {
            for (var credEntry : debtorEntry.getValue().entrySet()) {
                long owed = credEntry.getValue();
                if (owed > 0) {
                    System.out.printf("%s 欠 %s %.2f%n",
                            debtorEntry.getKey(), credEntry.getKey(), owed / 100.0);
                }
            }
        }
    }

    public long owed(String debtor, String creditor) {
        return balances.getOrDefault(debtor, Map.of()).getOrDefault(creditor, 0L);
    }

    /** 单人视图：该用户欠谁、谁欠该用户 */
    public void showFor(String userId) {
        for (var e : balances.getOrDefault(userId, Map.of()).entrySet()) {
            long v = e.getValue();
            if (v > 0)      System.out.printf("%s 欠 %s %.2f%n", userId, e.getKey(), v / 100.0);
            else if (v < 0) System.out.printf("%s 欠 %s %.2f%n", e.getKey(), userId, -v / 100.0);
        }
    }
}
```

---

## 第 3 步：动词 → 方法归属 —— 谁算拆分、谁动账本、谁编排

**🤔 自问**：动词有 **拆分、记账、查账、还款**。各归谁？

- **查账 / 记账**：动的是账本这张表 → 已放在 `BalanceSheet.show / adjust`（第 2 步顺手定了）✅
- **拆分计算**：会变的规则 → 第 4 步抽策略
- **addExpense 编排**：把「调策略算份额 → 逐个更新账本」串起来 → 谁来？

**🔀 岔路：`addExpense` 挂哪？** 和 03 同款三候选：

- `user.addExpense(...)`？用户得持有全局账本，职责错位。否
- `expense.apply(...)`？让一笔支出去操作全局账本，越权。否
- → 需要一个协调者：`Splitwise` 门面。✅

**🔀 岔路（God class 悬崖）**：定了门面后，危险念头——「拆分公式、百分比校验、账本矩阵运算，我都写门面里」。**打住**。正确分工：

- **拆分公式 + 合法性校验** → 各 `SplitStrategy` 自己（百分比要不要等于 100、精确要不要等于总额，**规则本身就随拆分方式变**，所以校验天然属于策略）
- **账本矩阵的加减** → `BalanceSheet`
- **门面只编排**：要谁付钱、拿到份额后逐个 `adjust`

**💬 说出口**：「`addExpense` 放在 `Splitwise` 门面里做编排；具体怎么拆、份额合不合法交给拆分策略自己校验，账本的加减交给 `BalanceSheet`。门面不碰公式也不碰矩阵，避免变成上帝类。」

---

## 第 4 步：找变化点 → 抽策略 —— 顺带解决「三种拆分入参不一样」的难题

**🤔 自问**：变化点是谁？**拆分方式**——均摊 / 精确 / 百分比，将来还可能「按权重/份数」。能轻松说出 ≥2 个变体 → 该抽 `SplitStrategy`。

**🔀 岔路（这步真正的难点）：三种拆分的入参不一样，接口怎么统一？**

- 均摊：不需要额外参数（知道总额和人数就行）
- 精确：需要「每人具体多少钱」
- 百分比：需要「每人百分之几」

如果给三个不同签名的方法，就没法统一成一个接口了。我权衡两个办法：

| 办法 | 评价 |
| --- | --- |
| 每种策略一个完全不同的方法 | 没法多态，门面又得 if 分支判类型，白抽了 |
| 统一签名 `calculate(总额, 参与人, values)`，`values` 由各策略**自行解释** | 均摊忽略它、精确当成金额、百分比当成百分数。能多态，代价是 `values` 语义偏弱类型——但可接受 |

选后者，并在接口注释里把 `values` 的含义写清楚。**主动承认这个取舍**（弱类型换多态），比假装没看见强。

**🔀 岔路（加分点：均摊除不尽怎么办？）**：1000 分均摊给 3 人，1000/3=333……少 1 分。绝不能让账对不上。决定：**base = 总额/人数，余数 = 总额%人数，把余数 1 分 1 分依次分给前几位**。整数运算，总额严丝合缝闭合。这就是第 1 步坚持「用分的整数」的回报。

想清楚，策略就掉下来了：

```java
public interface SplitStrategy {
    /**
     * @param totalCents   总额（分）
     * @param participants 参与人 id
     * @param values       由各实现自行解释：EQUAL 忽略；EXACT=各人金额(分)；PERCENT=各人百分数
     * @return 每个参与人的份额；实现内部负责校验合法性，非法则抛 InvalidSplitException
     */
    List<Split> calculateSplits(long totalCents, List<String> participants, List<Long> values);
}
```

```java
public class EqualSplitStrategy implements SplitStrategy {
    @Override
    public List<Split> calculateSplits(long total, List<String> participants, List<Long> values) {
        int n = participants.size();
        if (n == 0) throw new InvalidSplitException("参与人不能为空");
        long base = total / n;
        long remainder = total % n;                 // 除不尽的零头（分）
        List<Split> splits = new ArrayList<>();
        for (int i = 0; i < n; i++) {
            long share = base + (i < remainder ? 1 : 0);  // 前 remainder 位各多担 1 分
            splits.add(new Split(participants.get(i), share));
        }
        return splits;                              // sum 严格等于 total
    }
}
```

```java
public class ExactSplitStrategy implements SplitStrategy {
    @Override
    public List<Split> calculateSplits(long total, List<String> participants, List<Long> values) {
        if (values.size() != participants.size())
            throw new InvalidSplitException("精确拆分：金额个数必须等于参与人数");
        long sum = values.stream().mapToLong(Long::longValue).sum();
        if (sum != total)
            throw new InvalidSplitException("精确拆分：各份额之和(" + sum + ")必须等于总额(" + total + ")");
        List<Split> splits = new ArrayList<>();
        for (int i = 0; i < participants.size(); i++)
            splits.add(new Split(participants.get(i), values.get(i)));
        return splits;
    }
}
```

```java
public class PercentSplitStrategy implements SplitStrategy {
    @Override
    public List<Split> calculateSplits(long total, List<String> participants, List<Long> values) {
        if (values.size() != participants.size())
            throw new InvalidSplitException("百分比拆分：百分数个数必须等于参与人数");
        long pctSum = values.stream().mapToLong(Long::longValue).sum();
        if (pctSum != 100)
            throw new InvalidSplitException("百分比之和必须为 100，实际为 " + pctSum);
        List<Split> splits = new ArrayList<>();
        long allocated = 0;
        for (int i = 0; i < participants.size(); i++) {
            long share = (i == participants.size() - 1)
                    ? total - allocated                 // 最后一人兜底，吸收四舍五入零头
                    : total * values.get(i) / 100;
            allocated += share;
            splits.add(new Split(participants.get(i), share));
        }
        return splits;
    }
}
```

**💬 说出口**：「三种拆分我统一成一个 `calculateSplits` 接口，靠 `values` 参数自行解释——代价是 values 弱类型了一点，但换来门面对三种拆分完全多态、零 if 分支。每种策略**自己负责校验**（百分比和为 100、精确和为总额），不合法就抛异常。还有两个细节：均摊除不尽时把零头逐分摊给前几人，百分比让最后一人兜底，保证总额精确闭合。」

```java
public class InvalidSplitException extends RuntimeException {
    public InvalidSplitException(String msg) { super(msg); }
}
```

---

## 第 5 步：门面 API —— 抠 addExpense 的签名

**🤔 自问**：driver 跟 `Splitwise` 打交道。`addExpense` 的签名怎么定？

```java
public class Splitwise {
    void addUser(User user);
    // 谁垫的钱 / 多少分 / 参与人(含垫付人) / 怎么拆 / 拆分参数
    void addExpense(String paidBy, long amountCents, List<String> participants,
                    SplitStrategy strategy, List<Long> values);
    void settle(String fromUser, String toUser, long amountCents);  // from 还 to
    void showBalances();
    void showBalance(String userId);
}
```

**🔀 岔路：参与人列表要不要包含垫付人自己？** 要——垫付人通常也消费了（一起吃饭他也吃了）。所以 `participants` 含 `paidBy`；编排时跳过「自己欠自己」即可。这个边界不说清楚，分账会算错。

**💬 说出口**：「`participants` 包含垫付人本人，因为他自己那份也算消费；记账时跳过他自己对自己那条。`strategy` 和 `values` 一起决定怎么拆。」

---

## 第 6 步：实现门面 —— 编排三行，干净得能一眼读完

**🤔 自问**：门面持有什么？用户表 + 一个 `BalanceSheet`。`addExpense` 的逻辑：调策略算份额 → 每个参与人（除垫付人）欠垫付人他那份。

想清楚分工后，`addExpense` 短到只有编排、没有业务公式——**这正是前面所有「想清楚」的回报**：

```java
public class Splitwise {
    private final Map<String, User> users = new HashMap<>();
    private final BalanceSheet balanceSheet = new BalanceSheet();

    public void addUser(User user) { users.put(user.getId(), user); }

    public void addExpense(String paidBy, long amountCents, List<String> participants,
                           SplitStrategy strategy, List<Long> values) {
        validateUsersExist(paidBy, participants);
        List<Split> splits = strategy.calculateSplits(amountCents, participants, values); // 算+校验
        for (Split split : splits) {
            if (split.getUserId().equals(paidBy)) continue;          // 跳过垫付人自己那份
            balanceSheet.adjust(split.getUserId(), paidBy, split.getAmountCents()); // 参与人欠垫付人
        }
    }

    public void settle(String fromUser, String toUser, long amountCents) {
        // from 还钱给 to：等价于 to 这个"债权人"对 from 的债权减少
        balanceSheet.adjust(toUser, fromUser, amountCents);
    }

    public void showBalances() { balanceSheet.show(); }

    public void showBalance(String userId) { balanceSheet.showFor(userId); } // 单人视图

    private void validateUsersExist(String paidBy, List<String> participants) {
        if (!users.containsKey(paidBy)) throw new InvalidSplitException("垫付人不存在: " + paidBy);
        for (String p : participants)
            if (!users.containsKey(p)) throw new InvalidSplitException("参与人不存在: " + p);
    }
}
```

> **并发**：Splitwise 不像停车场那样以并发为考点，但要能说出来——「如果多线程同时记账，`BalanceSheet.adjust` 的『读-改-写』要加锁（给 `BalanceSheet` 加 `synchronized` 或对涉及的两个用户键加锁），否则净额会算错」。点到为止，别为它把 MVP 复杂化。

---

## 第 7 步：Driver —— 反推要证明什么

**🤔 自问**：我要证明：①三种拆分都能算对；②净额会自动抵消（B 先欠 A、A 又欠 B，最后只剩差额）；③非法拆分会被拦。

```java
public class Driver {
    public static void main(String[] args) {
        Splitwise app = new Splitwise();
        app.addUser(new User("Alice", "Alice"));
        app.addUser(new User("Bob", "Bob"));
        app.addUser(new User("Charlie", "Charlie"));

        // ① 均摊：Alice 垫 1500 分晚饭，3 人均摊 → 每人 500
        app.addExpense("Alice", 1500, List.of("Alice", "Bob", "Charlie"),
                       new EqualSplitStrategy(), List.of());
        // ② 精确：Bob 垫 900 分打车，指定 A:400 B:200 C:300
        app.addExpense("Bob", 900, List.of("Alice", "Bob", "Charlie"),
                       new ExactSplitStrategy(), List.of(400L, 200L, 300L));
        System.out.println("=== 两笔之后的账本（注意 Alice/Bob 已净额抵消）===");
        app.showBalances();
        // 期望：Bob 欠 Alice 1.00（500 - 400）；Charlie 欠 Alice 5.00；Charlie 欠 Bob 3.00

        // ③ 百分比 + 还款
        app.addExpense("Charlie", 1000, List.of("Alice", "Charlie"),
                       new PercentSplitStrategy(), List.of(50L, 50L)); // Alice 欠 Charlie 500
        app.settle("Bob", "Alice", 100);                               // Bob 还清欠 Alice 的 1.00
        System.out.println("=== 再记一笔百分比 + Bob 还款后 ===");
        app.showBalances();

        // ④ 边界：百分比之和不为 100 → 抛异常
        try {
            app.addExpense("Alice", 1000, List.of("Alice", "Bob"),
                           new PercentSplitStrategy(), List.of(60L, 30L)); // 90 != 100
        } catch (InvalidSplitException e) {
            System.out.println("预期异常: " + e.getMessage());
        }

        // ⑤ 边界：均摊除不尽 1000/3 → 334/333/333，总额闭合
        Splitwise app2 = new Splitwise();
        app2.addUser(new User("X", "X")); app2.addUser(new User("Y", "Y")); app2.addUser(new User("Z", "Z"));
        app2.addExpense("X", 1000, List.of("X", "Y", "Z"), new EqualSplitStrategy(), List.of());
        System.out.println("=== 均摊 1000/3 的余数处理 ===");
        app2.showBalances(); // Y 欠 X 3.33, Z 欠 X 3.33（X 自己担 3.34）
    }
}
```

**💬 说出口**：「我跑三种拆分各一笔，重点演示第二笔之后 Alice 和 Bob 的债务自动净额抵消；再演示百分比不为 100 被拦、以及均摊除不尽时余数怎么闭合。」

跑通它，你交出的是：**三种拆分多态、账本自动净额、金额零误差、非法输入被拦、可演示**——评分九栏到手。

---

## 扩展：债务图简化（被问到 / 有余力再做）

**🤔 自问**：现在账本里可能有「Bob 欠 Alice 1、Charlie 欠 Alice 5、Charlie 欠 Bob 3」这种链。能不能用**最少的转账笔数**结清？

**思路（贪心）**：

1. 先把两两账本**净额化**成每人一个净值：`net[u] = 别人欠 u 的 − u 欠别人的`。正数=应收，负数=应付，全员相加为 0
2. 分成两堆：债权人（net>0）、债务人（net<0）
3. 每轮取**欠得最多的人**和**应收最多的人**配对，转 `min(两者绝对值)`，把小的一方清零，大的一方留余额，继续——直到全部归零

```java
// 草图：返回若干 (from, to, amount) 转账
public List<long[]> simplify(Map<String, Long> net) {       // net: userIndex → 净额(分)
    PriorityQueue<long[]> creditors = new PriorityQueue<>((a,b) -> Long.compare(b[1], a[1])); // 应收大顶堆
    PriorityQueue<long[]> debtors   = new PriorityQueue<>((a,b) -> Long.compare(a[1], b[1])); // 应付小顶堆(负)
    // ... 把 net 拆进两个堆，每轮各取堆顶配对、转 min、回填残额 ...
    // 这一步是「有点算法味」的加分项，不是 MVP
    return List.of();
}
```

**💬 说出口（纪律）**：「债务简化我会**在 MVP 跑通之后**做——它是个贪心：净额化 + 大顶堆配对最大债权人和最大债务人。注意它最小化的是**转账笔数**，不保证最优（精确最优是 NP 难），但实践足够。」这句话既展示了你懂算法，又守住了「先跑通再优化」的纪律。

---

## 这道题的设计模式地图

| 模式 | 落在哪 | 哪一步想出来的 |
| --- | --- | --- |
| **策略 Strategy** | `SplitStrategy`（均摊/精确/百分比） | 第 4 步：≥2 变体的维度，且各自带校验 |
| **门面 Facade** | `Splitwise` | 第 3 步：编排归谁，排除 user/expense 后 |
| （扩展）贪心 + 堆 | 债务简化 | 扩展：被问到才做 |

**别过度**：MVP 就是「3 个策略 + 账本 + 门面」。不要一上来上群组继承体系、事件溯源、把账本做成可插拔存储——那是烧时间。

---

## 常见追问与应答

- **「再加一种『按份数/权重』拆分？」** → 新增 `ShareSplitStrategy implements SplitStrategy`，`values` 解释成份数，按份额比例分配 + 余数兜底。门面不动（OCP）
- **「金额为什么不用 double？」** → 浮点累加有误差，分账会对不上；用「分」的整数（或 BigDecimal），均摊余数也好处理
- **「均摊 100 分给 3 人怎么办？」** → base=33，余 1 分给第一人 → 34/33/33，总额闭合（第 4 步）
- **「怎么知道某人总共欠多少 / 净值？」** → 遍历 `balances.get(user)` 求和，正负相抵即净值；这也是债务简化的输入
- **「并发记账安全吗？」** → `adjust` 是读-改-写，多线程要锁；MVP 单线程，能说出锁加在哪即可
- **「能简化债务链吗？」** → 见扩展：净额化 + 贪心配对，最小化转账笔数

---

## 检查站

1. 第 1 步你为什么坚持用「分的整数」而不是 double？这个决定在后面哪两个地方得到了回报？
2. 「谁欠谁」为什么用 `Map<债务人, Map<债权人, 金额>>` 而不是每人一个净额？两个方向同时更新带来什么好处？
3. 三种拆分入参不同，你怎么把它们统一进一个 `SplitStrategy` 接口？这个统一的代价是什么，你为什么接受？
4. 「百分比必须等于 100」「精确必须等于总额」这两个校验，为什么放在各策略内部、而不是门面里？
5. 均摊 1000 分给 3 人，你怎么保证份额之和精确等于 1000？百分比拆分里「最后一人兜底」解决的是同一类什么问题？
6. 债务简化你会在什么时候做？它最小化的是什么、是不是最优解？

下一道实战（规划中 `05`）是 **电梯调度系统**，考点换成**状态机**——电梯的「上行/下行/空闲」状态流转，加上「来了请求该往哪走」的调度策略，我会用同样的节奏带你推一遍状态模式怎么落地。
