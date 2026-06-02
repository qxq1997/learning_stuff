# 当前检索 benchmark 测试报告

## 目标

这份报告记录的是 **2026-04-02** 对 TalentHub 当前默认检索链路进行的一次真实 benchmark 测试结果。

这轮测试的重点不是再看“能不能跑通”，而是回答下面几个更有价值的问题：

1. 当前系统在多领域、中英混合场景下到底强不强
2. 哪些领域和语言下检索更稳，哪些更容易被噪声干扰
3. 现有指标里哪些值得信，哪些口径其实已经不够用了

## 一、测试上下文

### 1. 当前运行链路

本次 benchmark 运行时读取的是当前本地默认配置：

- `EMBEDDING_PROVIDER=openai`
- `EMBEDDING_MODEL_NAME=text-embedding-3-large`
- `VECTOR_DIMENSION=3072`
- `RERANKER_PROVIDER=voyage`
- `RERANKER_MODEL_NAME=rerank-2.5-lite`
- `QDRANT_COLLECTION_NAME=talenthub_knowledge_chunks`
- `KNOWLEDGE_RETRIEVAL_CANDIDATE_LIMIT=18`
- `KNOWLEDGE_RETRIEVAL_CHUNK_LIMIT=6`

当前检索模式仍然是：

- `OpenAI dense embedding`
- `Qdrant dense retrieval`
- `Voyage rerank-2.5-lite`

### 2. 评测集版本

本次使用的是：

- `backend/evals/retrieval_baseline.json`

当前版本：

- `suite_name = retrieval_benchmark_v3_multidomain`
- `case_count = 41`

### 3. 数据集构成

这次 benchmark 不再只看内部制度和工程规则，还加入了一组**基于 Wikipedia 事实改写的多领域评测文档**，用于观察系统在更通用、更跨领域的知识检索下表现如何。

当前覆盖两类知识源：

- 企业内部知识
  - 入职制度
  - 研发协作
  - 生产事故
  - API 可靠性
  - 发布回滚
  - 权限安全
- Wikipedia 风格知识
  - Python
  - World Wide Web
  - Apollo 11 / Apollo 13
  - Photosynthesis
  - Mount Everest
  - 长城
  - 北京
  - Albert Einstein
  - Mona Lisa

### 4. 领域覆盖

当前按 domain 拆分为：

- `business_operations`
- `software_engineering`
- `site_reliability`
- `release_management`
- `security_access`
- `computing`
- `space_history`
- `science`
- `geography`
- `history_geography`
- `science_history`
- `art_history`

### 5. 语言覆盖

当前按语言拆分为：

- `zh`
- `en`
- `zh-en`

### 6. 一个补充验证

为了确认当前线上 reranker 是否真的可用，我还做了一个最小化直连测试，直接调用 `Voyage rerank-2.5-lite` 对两个候选文本进行排序，接口真实返回 `200`，说明：

- 当前 key 有效
- 当前账号此时具备至少小规模 rerank 调用能力

这和之前曾经出现的 `HTTP 429` 形成了对比：**Voyage 不是一直不可用，而是存在限流波动风险。**

## 二、全局结果

本次 benchmark 的总体结果：

- `MRR@5 = 1.0`
- `NDCG@5 = 1.0`
- `Recall@5 = 1.0`
- `IDBasedContextRecall = 1.0`
- `IDBasedContextPrecision = 0.166667`

## 三、先说结论

这轮结果说明：

- 当前系统在这组 `41` 条多领域、中英混合 benchmark 上，已经能把**正确 chunk 稳定排在第 1**
- 当前链路在“是否能找到正确知识”这件事上，表现已经非常强
- 但当前 `precision` 指标在这套口径下**不再有足够解释力**

换句话说：

- **召回和 top-1 排序：很强**
- **top-k 纯度：仍然要看，但不能只看当前这一个 precision 数字**

## 四、为什么这轮结果几乎满分

### 1. 召回已经足够强

`Recall@5 = 1.0` 和 `IDBasedContextRecall = 1.0` 表明：

- 所有 case 的目标 chunk 都进入了前 `5`
- 当前系统不存在“根本找不到正确文档”的问题

### 2. 排序也很稳

`MRR@5 = 1.0` 和 `NDCG@5 = 1.0` 表明：

- 不只是召回正确
- 而且每一条 case 的目标 chunk 都排在了第 `1`

这比上一轮 benchmark 有明显提升。

### 3. 为什么 `IDBasedContextPrecision` 还是 `0.166667`

这是这轮最值得强调的**评测口径问题**。

当前 benchmark 的设置是：

- 每个 case 只标注 **1 个 reference chunk**
- 检索结果固定返回 **6 个 chunk**

只要：

- 正确 chunk 被召回
- 而且只有这 1 个 chunk 被标成 relevant

那么：

- `precision = 1 / 6 = 0.166667`

也就是说，这个数现在更多反映的是：

- “当前每题固定看 top-6，且每题只定义了一个 gold chunk”

而不是：

- “系统真的每次只有 16.7% 的结果是好结果”

所以本轮之后，`IDBasedContextPrecision` 不再适合作为最核心的判断指标，至少不能单独看。

## 五、按场景看结果

当前 scenario 拆分结果全部都是：

- `hit_at_1 = 1.0`
- `MRR@5 = 1.0`
- `NDCG@5 = 1.0`
- `Recall@5 = 1.0`

覆盖这些场景：

- `exact_fact`
- `policy_rule`
- `numeric_and_deadline`
- `numeric_fact`
- `entity_fact`
- `term_and_alias`
- `bilingual_query`
- `confusable_entity`
- `long_document_noise`

这说明：

- 现在不只是“数字题稳”
- 也不只是“企业规则稳”
- 连带有混淆实体、跨语言 query、Wikipedia 通用知识的场景，也都能把 gold chunk 放到 top-1

## 六、按领域看结果

当前所有 domain 的 top-1 命中也都达到了 `1.0`。

但如果结合这轮新增的 `avg_top_score_gap` 来看，领域间仍然存在“稳不稳”的差异。

### 相对更稳的领域

- `release_management`
  - `avg_top_score_gap = 0.601562`
- `history_geography`
  - `avg_top_score_gap = 0.504883`
- `site_reliability`
  - `avg_top_score_gap = 0.417969`

这说明：

- 发布回滚
- 长城/历史地理
- 站点可靠性规则

这些 query 的 top-1 和 top-2 拉得更开，排序信心更足。

### 相对更脆弱的领域

- `science`
  - `avg_top_score_gap = 0.297851`
- `computing`
  - `avg_top_score_gap = 0.330729`
- `art_history`
  - `avg_top_score_gap = 0.357422`

这些领域虽然仍然 top-1 正确，但：

- top-1 和 top-2 的差距更小
- 更容易在更大语料、更复杂 query 下受到噪声干扰

## 七、按语言看结果

语言维度也全部命中了 top-1，但 `avg_top_score_gap` 有明显差异：

- `en`
  - `avg_top_score_gap = 0.450521`
- `zh`
  - `avg_top_score_gap = 0.438021`
- `zh-en`
  - `avg_top_score_gap = 0.341797`

这说明：

- 英文 query 和纯中文 query 当前都比较稳
- **中英混合 query 仍然是最脆弱的一档**

虽然现在 mixed query 也能命中 top-1，但相较纯中文/纯英文，它更接近“险胜”，不是“碾压”。

## 八、最值得看的“险胜” case

如果只看命中率，很容易误以为现在所有 case 都一样强。  
但加入 `top_score_gap` 后，可以看出一些“虽然对了，但并不特别稳”的问题点。

当前最小 gap 的代表性 case：

### 1. `beijing-capital`

- query：`北京是什么城市`
- `top_score_gap = 0.128906`

说明：

- 这条虽然答对了
- 但和天气/城市类无关文本仍然有较强相似度
- 这是很典型的“高频地名 + 大语料噪声”问题

### 2. `web-hyperlink-purpose`

- query：`万维网依靠什么来访问互联网上的资源`
- `top_score_gap = 0.154297`

说明：

- 通用计算机知识类 query 在面对 AI/agent 文档时，仍会被周边技术文本干扰

### 3. `python-indentation`

- query：`Python 用什么语法形式来分隔代码块`
- `top_score_gap = 0.195312`

说明：

- 编程语言知识和系统内其他 agent/编程材料之间仍存在语义邻近干扰

### 4. `photosynthesis-oxygen`

- query：`光合作用会释放什么气体`
- `top_score_gap = 0.224609`

说明：

- 通用科学知识在当前知识库里也能命中
- 但 scientific fact query 的 top-1 稳定度还不是特别高

## 九、这轮 benchmark 真正说明了什么

### 1. 检索底座已经非常可信

当前链路已经可以比较有把握地说：

- `OpenAI text-embedding-3-large + Qdrant + Voyage rerank`

在 TalentHub 当前语料规模下，能够稳定处理：

- 企业内部规则
- 工程制度
- 安全与发布
- 通用 Wikipedia 风格知识
- 中文、英文和中英混合 query

### 2. 当前系统已经不只是“企业制度检索”

这轮 benchmark 很有价值的一点是，它说明 TalentHub 当前检索能力已经扩展到：

- 多领域知识检索
- 中英混合事实问答
- 混淆实体区分

这让系统更接近“真正可泛化的知识型培训底座”，而不只是内部制度 QA。

### 3. 下一步真正缺的不是“能不能找到”，而是“怎么更好地衡量”

这轮跑到全 `1.0` 以后，下一阶段最需要改的其实不是先盲目换模型，而是：

- 提升 benchmark 的难度
- 改进 precision 的评估口径
- 增加更细的区分性指标

## 十、这轮 benchmark 暴露出的评测问题

### 1. 当前 precision 指标已经失真

因为：

- 每题只有 1 个 gold chunk
- 固定返回 6 条

所以 precision 在成功 case 上天然收敛到 `1/6`。

这意味着下一步要改：

- 为同一文档允许多个 gold chunk
- 或把 precision 改成 `top-1 exactness / top-3 purity / top-k overlap`

### 2. benchmark 仍然偏“单跳事实型”

现在已经覆盖多领域和多语言，但多数 query 仍然是：

- 单实体
- 单事实
- 单跳检索

还缺：

- 跨文档组合事实
- 多跳推理式 retrieval
- 长上下文重排
- 部门/标签过滤下的范围检索 benchmark

### 3. 评测还没直接记录“reranker 成功率”

现在报告里有：

- embedding model
- reranker provider
- 全局 retrieval 指标

但还没有：

- 每次 eval 中 reranker 实际成功次数
- fallback 次数
- 每个 case 是否真正使用了 rerank 排序

这会是下一步很值得补的可观测性增强点。

## 十一、下一步最值得做的优化

如果只做四件事，我建议按这个顺序：

### 1. 升级 benchmark 难度

重点补：

- 多跳 case
- 需要两篇文档联合回答的 case
- 更强 alias / acronym / abbreviation case
- 更长 query 和更长文档

### 2. 升级评测口径

重点补：

- 多 gold chunk 标注
- reranker 成功率
- top-1 margin / hard negative overlap
- scope-filtered retrieval benchmark

### 3. 增加真实业务语料隔离评测

例如分开跑：

- `eval-only collection`
- `full mixed knowledge library`

这样你就能看出：

- 模型本身能力
- 大语料噪声下的真实能力

### 4. 把当前“险胜 case”单独做 hard set

比如：

- `beijing-capital`
- `web-hyperlink-purpose`
- `python-indentation`
- `photosynthesis-oxygen`

这些最适合成为下一轮 hard benchmark 的起点。

## 十二、最终结论

TalentHub 当前默认检索链路的最新真实状态可以概括成一句话：

**在这套 41 条、跨业务和 Wikipedia 多领域、中英混合 benchmark 上，系统已经能稳定把正确知识排到 top-1，但下一阶段的重点已经从“能不能找对”转向“如何更严谨地度量排序纯度、难例稳定性和 reranker 实际收益”。**

更具体一点：

- 召回：强
- top-1 排序：当前 benchmark 下强
- 多领域泛化：已具备
- 中英混合：可用，但 score gap 偏小
- precision 口径：当前不够好
- 下一阶段重点：更难 benchmark + 更细评测指标
