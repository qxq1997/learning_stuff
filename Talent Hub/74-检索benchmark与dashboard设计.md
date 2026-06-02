# 检索 benchmark 与 dashboard 设计

## 目标

TalentHub 现在已经有：

- embedding
- Qdrant
- reranker
- `Ragas + ranx` 评测脚本

但如果只停在“能跑评测脚本”，仍然很难回答两个关键问题：

1. 当前系统在不同检索场景下到底强不强
2. 以后每次换 embedding、reranker、chunking 或阈值时，应该看哪组指标

这篇文档专门回答这两个问题，并把 benchmark 和 dashboard 的设计口径固定下来。

## 一、先说结论：当前系统检索能力到哪一步了

### 1. 当前默认运行链路

当前本地默认运行配置来自：

- `docker-compose.local.yml`

默认链路是：

- `OpenAI text-embedding-3-large`
- `Qdrant dense retrieval`
- `Voyage rerank-2.5-lite`

也就是说，**当前系统默认运行时**是：

- dense 检索
- 线上 reranker

### 2. 当前仓库里最新留存的 benchmark 快照

当前最新留存的 benchmark 报告在：

- `storage_data/evaluations/retrieval_baseline_latest.json`

这份快照对应的是一条**历史评测链路**：

- `BGE-M3`
- `Qdrant hybrid retrieval`
- `bge-reranker-v2-m3`

当前快照结果是：

- `MRR@5 = 1.0`
- `NDCG@5 = 1.0`
- `Recall@5 = 1.0`
- `IDBasedContextRecall = 1.0`
- `IDBasedContextPrecision = 0.2`

### 3. 这说明什么

这组结果说明：

- 正确目标 chunk 已经稳定进入前 `5`
- 并且多数情况下排在非常靠前的位置
- 对“短问题 -> 明确制度句子”的检索，当前链路是能打的

但它也同时说明：

- top-k 结果不够干净
- 前 `5` 里仍然有不少“相关但不是目标 chunk”的噪声
- 当前评测集过小，且更偏“短事实问答”

所以，当前 TalentHub 的真实检索能力应该被描述成：

### 当前可确认的强项

- 短 query 的精确制度召回
- 明确时间点、步骤、命名规范、规则型问句
- 小规模中文内部文档的 top-1 / top-5 命中

### 当前还不能下强结论的地方

- 中英混合 query
- 缩写、别名、术语变体
- 多文档综合检索
- 长文档噪声干扰
- 网页导入文档与本地文档混合场景
- 判卷后学习建议场景的真实有效性

换句话说：

- **当前系统已经证明“能命中”**
- 但还没有充分证明“在复杂真实场景里也稳定强”。

## 二、为什么现有 benchmark 还不够

当前评测脚本：

- `backend/scripts/eval_retrieval_baseline.py`

当前评测数据：

- `backend/evals/retrieval_baseline.json`

它的优点是：

- 可重复
- 成本低
- 能快速验证主链路有没有退化

但它的问题也很明显：

- 样本太少，当前只有 `6` 条 case
- 过于偏“单文档短事实召回”
- 没有区分场景类型
- 没有对 web import / bilingual / noisy docs / multi-hop 做覆盖
- 没有“按场景聚合”的输出

所以现在的 baseline 更像：

- **smoke + 最小可信基线**

而不是：

- **完整 benchmark 体系**

## 三、TalentHub 应该怎么定义 benchmark

我建议 TalentHub 的检索 benchmark 按“场景”来分，而不是只按 query 堆一大坨。

### 建议的一级场景

1. `exact_fact`
2. `policy_rule`
3. `term_and_alias`
4. `numeric_and_deadline`
5. `cross_document`
6. `long_document_noise`
7. `web_import_content`
8. `bilingual_query`
9. `learning_reference`
10. `practice_generation`

下面分别解释。

### 1. exact_fact

目标：

- 验证系统能否命中“明确答案就在某一句”的内容

典型 query：

- 日报最晚几点提交
- hotfix 分支命名规范是什么

重要指标：

- `MRR@5`
- `Recall@5`

### 2. policy_rule

目标：

- 验证系统能否命中制度、流程、职责分工类规则

典型 query：

- 发生事故后第一步要做什么
- 跨团队接口变更前必须做什么

重要指标：

- `MRR@5`
- `NDCG@5`

### 3. term_and_alias

目标：

- 验证术语、别名、缩写、简称能否命中正确文档

典型 query：

- RD 日报规范
- 紧急修复是不是 hotfix

重要指标：

- `Recall@5`
- `IDBasedContextPrecision`

### 4. numeric_and_deadline

目标：

- 验证时间、数值、编号、阈值这类信息检索是否稳定

典型 query：

- 多久内要完成第一次状态同步
- 第几个工作日前开通权限

重要指标：

- `MRR@5`
- `Recall@5`

### 5. cross_document

目标：

- 验证需要两份以上文档共同支持的问题

典型 query：

- 基于入职制度和协作规范，生成涵盖流程和评审的题

这类 case 不只是“命中一个 chunk”，而是要看：

- top-k 是否覆盖多个必要来源

重要指标：

- `IDBasedContextRecall`
- 场景化 coverage

### 6. long_document_noise

目标：

- 验证长文档和大量噪声信息存在时，相关段落是否仍能被排到前面

重要指标：

- `NDCG@5`
- `IDBasedContextPrecision`

### 7. web_import_content

目标：

- 验证网页导入文档能否稳定参与检索
- 验证网页正文、列表、图片线索转换成文本后，是否能支持检索

重要指标：

- `Recall@5`
- `MRR@5`

### 8. bilingual_query

目标：

- 验证中文 query 查英文文档、英文 query 查中文文档、混合术语场景

重要指标：

- `Recall@5`
- `IDBasedContextRecall`

### 9. learning_reference

目标：

- 验证判卷后推荐资料是否能优先回到真正相关的知识来源

这里不只是检索问题，还和学习闭环相关。

重要指标：

- `Recall@5`
- 推荐命中率
- 推荐去重率

### 10. practice_generation

目标：

- 验证专项练习在按标签扩召、范围扩大后，是否仍能命中高相关内容

重要指标：

- `Recall@5`
- `IDBasedContextPrecision`

## 四、benchmark 数据应该怎么组织

当前的 `retrieval_baseline.json` 只有：

- documents
- cases

后续 benchmark 数据建议扩成：

```json
{
  "suite_name": "retrieval_benchmark_v1",
  "documents": [],
  "cases": [
    {
      "id": "daily-report-deadline",
      "scenario": "exact_fact",
      "source_kind": "manual_import",
      "query_text": "日报最晚几点提交",
      "expected_document_title": "[EVAL] 入职制度基础",
      "expected_anchor": "日报需要在每个工作日 18:00 前提交",
      "difficulty": "easy",
      "notes": "短事实问答"
    }
  ]
}
```

建议增加的字段：

- `scenario`
- `source_kind`
- `difficulty`
- `language`
- `requires_multi_document`
- `notes`

这样后续报告就可以：

- 按场景聚合
- 按来源聚合
- 按难度聚合

## 五、dashboard 应该展示什么

这里说的 dashboard，不一定是前端页面，也可以是文档化的固定观察视图。

我建议 dashboard 至少分五层。

### 第一层：运行上下文卡片

先显示这次 benchmark 到底是在什么链路下跑的：

- `embedding_provider`
- `embedding_model_name`
- `vector_dimension`
- `retrieval_mode`
- `reranker_provider`
- `reranker_model_name`
- `retrieval_candidate_limit`
- `retrieval_chunk_limit`
- `suite_name`
- `case_count`
- `generated_at`

原因很简单：

- 指标脱离上下文没有意义

### 第二层：全局总览卡片

这里放最核心的全局指标：

- `MRR@5`
- `NDCG@5`
- `Recall@5`
- `IDBasedContextRecall`
- `IDBasedContextPrecision`

建议同时给解释：

- `Recall` 看有没有找到
- `MRR/NDCG` 看排得靠不靠前
- `Precision` 看结果干不干净

### 第三层：按场景聚合

这层是最重要的。

示例表格：

| Scenario | Case Count | Recall@5 | MRR@5 | NDCG@5 | Context Recall | Context Precision | Status |
|---|---:|---:|---:|---:|---:|---:|---|
| exact_fact | 20 | 1.00 | 0.98 | 0.99 | 1.00 | 0.45 | strong |
| policy_rule | 20 | 0.95 | 0.90 | 0.92 | 0.95 | 0.38 | acceptable |
| bilingual_query | 20 | 0.70 | 0.55 | 0.61 | 0.72 | 0.24 | weak |

这样你一眼就能看出：

- 系统到底强在哪
- 弱在哪

### 第四层：失败案例区

每次 benchmark 都要明确列出：

- 没召回正确 chunk 的 case
- 召回到了但排序太靠后的 case
- precision 很低的 case

这部分对调优价值最大。

建议每条 case 至少展示：

- query
- scenario
- expected doc
- expected anchor
- top-5 retrieved docs
- first correct rank
- failure reason 归类

### 第五层：版本对比

真正有价值的 dashboard 不是“这次 0.92”，而是：

- 比上一次提升还是退化

所以建议固定保留：

- latest
- previous
- best

并看：

- `delta_recall@5`
- `delta_mrr@5`
- `delta_precision`

## 六、建议的 dashboard 状态灯

为了让 dashboard 更直观，建议对不同指标定义粗粒度状态：

### 全局状态建议

- `strong`
  - `Recall@5 >= 0.95`
  - `MRR@5 >= 0.90`
- `acceptable`
  - `Recall@5 >= 0.85`
  - `MRR@5 >= 0.75`
- `weak`
  - 不满足上面条件

### precision 状态建议

因为当前 top-k 常常会故意放多个候选，precision 不应追求过度苛刻。

- `clean`
  - `IDBasedContextPrecision >= 0.45`
- `noisy`
  - `0.25 <= precision < 0.45`
- `very_noisy`
  - `< 0.25`

注意：

- 这是 dashboard 解释口径
- 不是线上 hard threshold

## 七、怎么理解当前 latest 报告

基于当前仓库里的最新 benchmark 快照，可以得出一个非常重要的结论：

### 1. 召回和排序已经过线

因为：

- `Recall@5 = 1.0`
- `MRR@5 = 1.0`
- `NDCG@5 = 1.0`

说明：

- 正确 chunk 能被稳定找回来
- 并且往往就在最前面

### 2. 结果纯度还明显不够

因为：

- `IDBasedContextPrecision = 0.2`

说明：

- top-k 里仍然混入不少“相关但不是目标”的 chunk
- 对“给大模型喂最干净上下文”这件事来说，仍有优化空间

### 3. 当前最像什么能力水平

可以把当前系统描述成：

- **短事实检索强**
- **复杂场景能力未知或偏弱**
- **top-k 纯度一般，需要继续优化**

这比说“我们现在检索已经很好了”更准确。

## 八、TalentHub 下一步最该做的 benchmark 扩展

如果只做三件事，我建议：

1. 扩到 `30~50` 个 case，并明确 `scenario`
2. 至少补齐：
   - `bilingual_query`
   - `web_import_content`
   - `long_document_noise`
   - `learning_reference`
3. 每次报告都固定输出：
   - 全局指标
   - 场景指标
   - top failure cases

这样 TalentHub 就能真正回答：

- 当前检索在什么场景下强
- 什么场景下弱
- 下一步优化该打哪

## 九、一句话总结

TalentHub 当前已经有“能跑的评测脚本”，但还没有“完整 benchmark 体系”。  
现阶段最准确的判断是：

- **系统已经证明自己能稳定命中短事实型知识**
- **还没有充分证明自己在复杂、混合、噪声场景下同样强**

因此，接下来真正该做的是：

- 用场景化 benchmark 把“当前能力边界”测清楚
- 用 dashboard 口径把“强弱分布”表达清楚

这样每次技术调优才不会只停留在体感层面。
