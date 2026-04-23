# 后训练 - 第 3 课:本地推理两大路线——llama.cpp/Ollama vs vLLM/SGLang 怎么选

## 学习目标(本节结束后你能做到什么)

- 能把市面上所有主流开源推理引擎按`目标场景`分成两大阵营:**消费级单用户路线**(llama.cpp、Ollama、LM Studio、MLX、Jan)与**服务化高并发路线**(vLLM、SGLang、TensorRT-LLM、TGI、LMDeploy)。
- 能讲清楚为什么同一个 7B 模型在 Ollama 下能做到 80 tokens/s(单用户),而在 vLLM 下能做到 4000 tokens/s(batched)——这不是谁更"快",而是两个引擎在解两个完全不同的优化问题。
- 面对一个真实需求(`Mac M4 Mini 给 3 个同事做代码助手` vs `企业内网 200 QPS 的客服机器人` vs `边缘设备上离线问答`),能画出选型决策树。
- 能讲清楚 Ollama 和 llama.cpp 的关系、vLLM 和 SGLang 的竞争点、TensorRT-LLM 为什么性能最好但还是被 vLLM 压制。
- 知道 2026 年哪些引擎已经原生支持`Prefill/Decode 分离`、`Prefix Caching`、`Multi-LoRA`、`投机解码`——这些是高级能力,第 4-8 课会拆开讲,这一课先建立地图。

## 一、先澄清一个常见误解:推理引擎不是一个东西

很多人第一次接触开源推理时会问:"vLLM 和 Ollama 哪个快?" 这个问题本身就错了。它们不是竞品,而是在**完全不同的坐标系里**做优化。

| 问题 | 消费级单用户路线(llama.cpp/Ollama/MLX) | 服务化高并发路线(vLLM/SGLang/TensorRT-LLM) |
| --- | --- | --- |
| 典型并发 | 1(最多 2-3) | 几十到几千 |
| 目标硬件 | CPU、笔记本 GPU、Mac、消费级 GPU | 数据中心 GPU(A100/H100/H200) |
| 核心 KPI | 单人 token/s、内存占用、启动时间 | 总吞吐、P99 延迟、GPU 利用率 |
| 关键技术 | 量化(GGUF)、SIMD、mmap、Metal/CUDA 小 kernel | PagedAttention、Continuous Batching、RadixAttention、FP8 |
| 典型工作负载 | 和模型一问一答、IDE 插件、桌面助手 | API 服务、对话机器人后端、Agent 平台 |
| 扩展方式 | 换更大的模型或更好的量化 | 加卡、分布式、张量并行 |

一句话概括这两种路线的本质差异:

> **消费级引擎是在"算力稀缺"的约束下优化单人体验;服务级引擎是在"算力充足"的前提下最大化吞吐和多租户效率。**

同一份 Qwen3-8B 权重,拿去在 MacBook 上跑和拿去在 H100 上服务几百人,是两件在工程上几乎毫无共性的事。硬件不同、瓶颈不同、优化手段完全不同。这就是为什么开源社区分化成了两个阵营,彼此很少直接借鉴。

## 二、消费级路线:llama.cpp 是这一派的根

### 2.1 llama.cpp:整个消费级生态的底座

llama.cpp 是 Georgi Gerganov 2023 年写的一个 **纯 C++ 的 LLM 推理库**。2023 年刚出来的时候是业余项目,2026 年已经是消费级 LLM 推理的**事实标准 kernel**。市面上 90% 的本地 LLM 工具——Ollama、LM Studio、Jan、GPT4All、Text Generation WebUI、Cortex——本质都是 llama.cpp 的前端 + 模型管理层。

它为什么能成为底座?有几个关键设计决策:

1. **零依赖 C++**:不依赖 Python、不依赖 PyTorch、不依赖 CUDA。只要你有 C++ 编译器就能编出来。这意味着它能跑在 Mac、Windows、Linux、Android、iOS、树莓派、甚至 ESP32 上。
2. **GGUF 单文件格式**(第 2 课讲过):一个 `.gguf` 文件就是权重 + tokenizer + 元数据,分发极其简单。
3. **极致量化**:从 Q2_K 到 F16 覆盖整个精度-体积权衡曲线。一个 7B 模型 Q4_K_M 大约 4.5GB,能塞进任何 8GB 内存的设备。
4. **多后端**:CPU SIMD(AVX2/AVX-512/NEON)、CUDA、Metal(Apple Silicon 原生)、Vulkan、ROCm、SYCL——**同一份代码跑到你手上任何能跑的硬件上**。
5. **mmap 加载**:模型文件 mmap 进来,多进程共享,启动时间只有几百毫秒。

它的技术取舍也很清晰:**放弃 batched serving,换取单用户极致体验**。llama.cpp 默认是单 batch、单请求(虽然 2024 后加了 server 模式支持简单并发,但它的 Continuous Batching 实现远不如 vLLM 成熟)。你如果想用它扛 100 QPS,几乎不可能——但用它在 MacBook 上和 Claude 聊天、写代码、做 RAG,体验极好。

### 2.2 Ollama:llama.cpp 的 Docker 化封装

Ollama 做了一件很简单但非常聪明的事:**把 llama.cpp 的使用门槛从"编译 + 命令行 + GGUF 路径"压到"一行命令"**。

```bash
ollama run qwen3:8b
```

这一行背后发生了什么:

1. 从 Ollama 的模型仓库拉取 `qwen3:8b` 的 GGUF 文件和 Modelfile(类似 Dockerfile 的描述文件,包含 chat_template、参数、system prompt)。
2. 启动一个后台 daemon(`ollama serve`),用 llama.cpp 作为推理后端。
3. 暴露一个 REST API(OpenAI 兼容)和一个 CLI 交互界面。
4. 自动做显存管理、模型热卸载(一段时间没用就从显存卸载)、多模型切换。

它解决的是**分发和管理**问题,推理性能本身和裸 llama.cpp 基本一致。Modelfile 的设计又让定制化变得很简单:

```
FROM qwen3:8b
SYSTEM "你是一个严谨的后端工程师,回答技术问题时必须给出代码示例。"
PARAMETER temperature 0.6
PARAMETER num_ctx 16384
```

Ollama 的定位非常明确:**给开发者和个人用户的本地 LLM 运行时**。它不追求高并发,不追求分布式,它追求"你 `brew install ollama` 之后五分钟内能在自己电脑上跑起任何开源模型"。2025 年 Ollama 还加了 vision 模型(LLaVA、Llama 3.2 Vision、Qwen3-VL)和 tool calling 的原生支持,进一步巩固了它在桌面场景的地位。

### 2.3 LM Studio、Jan、Cortex:GUI 友好的变体

- **LM Studio**:有漂亮桌面 GUI,内置模型搜索,支持 llama.cpp 和 MLX 两个后端。适合非技术用户。闭源但免费。
- **Jan**:完全开源的 LM Studio 替代品,开箱即用。
- **Cortex**:Jan 背后的推理引擎,也支持 llama.cpp 和 TensorRT-LLM 后端。
- **GPT4All**:早期项目,现在活跃度下降。

这些工具的**技术内核几乎都是 llama.cpp**,区别只在 UI 和模型管理。2026 年选型基本只看三件事:有没有你要的模型、UI 顺不顺手、是否开源。

### 2.4 MLX:Apple Silicon 的原生路线

MLX 是 Apple 2023 年底开源的一个**给 Apple Silicon 量身定做**的机器学习框架。它和 llama.cpp 的定位类似(都是本地推理),但技术路线差别很大:

| 维度 | llama.cpp(Metal 后端) | MLX |
| --- | --- | --- |
| 定位 | 跨平台,Apple 只是众多目标之一 | Apple 原生,深度集成 Metal Performance Shaders |
| 统一内存利用 | 通过 Metal | **原生利用 M 系列的 Unified Memory**,CPU/GPU 零拷贝 |
| 量化 | GGUF(社区量化) | mlx-community 的专用量化(类似 Q4) |
| 生态 | 巨大(Ollama 等都在用) | 较小但增长快 |
| 性能(Mac 上) | 很好 | **通常略快**,因为专门优化 |

MLX 的一个独特优势是可以利用 Mac Studio / MacBook Pro 的**超大统一内存**——比如 M3 Ultra 的 Mac Studio 能配到 512GB 统一内存,相当于一个"显存 512GB" 的推理设备。跑一个 405B 的模型,Q4 量化后大概占 200GB,MLX 可以直接 mmap 进来跑,这是任何 GPU 方案都做不到的(单卡最大 H200 显存 141GB)。这就是 2026 年你经常看到 Mac Studio 被当成"在家跑 70B 以上模型" 的首选。

### 2.5 消费级路线的盲区

这一派绝对不要拿去做**高并发 API 服务**。常见翻车:

- 用 Ollama 给公司内部 100 人做 API,晚高峰所有人一起发请求,P99 延迟直接飙到 30 秒以上。Ollama 内部虽然有排队,但它是**串行执行**,一个请求处理完才处理下一个。
- 用 llama.cpp server 跑多并发,显存占用会随着请求数线性增长(每个请求独立 KV Cache,没有共享),10 个并发就把 40GB 显存吃光。
- 用 Ollama 做 Agent 框架的后端,每个 tool call 都是一次独立请求,实际吞吐惨不忍睹。

这些场景**必须走服务化路线**。

## 三、服务化路线:vLLM 是 2024-2026 的王

### 3.1 vLLM:PagedAttention 把推理工业化

vLLM 是 2023 年 UC Berkeley SkyLab 出的一篇论文 `Efficient Memory Management for Large Language Model Serving with PagedAttention` 的开源实现。它一出来就炸场,因为它的核心洞察解决了一个此前**所有推理栈都在受苦但没人真正治根**的问题——**KV Cache 的内存碎片**。

这个问题第 4 课会深挖,这里先给出直觉:

- LLM 推理中每个请求都有一份 KV Cache,大小随生成长度动态增长。
- 传统做法是给每个请求**预分配一个最大长度的连续内存**,用多少算多少——浪费率极高(典型的 60-80% 显存被"可能用到但没用到"的部分占掉)。
- PagedAttention 借鉴**操作系统虚拟内存的分页思想**:把 KV Cache 切成固定大小的 block(默认 16 个 token),按需分配,不要求连续。结果是**显存利用率从 20-40% 提升到 90%+**,同样的显存能扛 2-4 倍的并发。

再叠加 vLLM 的另外两个核心设计:

- **Continuous Batching**:不等一个 batch 里所有请求都生成完,任何请求一结束就立即把它的位置让给新请求。这让 GPU 永远是满的。
- **Prefix Caching**:system prompt 或 few-shot 前缀被多个请求共享时,只算一次 KV,其他请求复用。对 RAG、Agent 系统吞吐提升显著。

vLLM 的优势 2024 年之后越来越清晰:

- **生态最大**:支持几乎所有主流模型(Llama、Qwen、Mistral、DeepSeek、Phi、Gemma、MoE、Vision 模型),新模型发布当天往往 vLLM 就支持了。
- **OpenAI API 兼容**:启动一个 vLLM 服务后,客户端代码就当它是 OpenAI API 用,迁移成本几乎为零。
- **多 LoRA 动态加载**:同一个 base model 上挂 100 个 LoRA adapter,按请求动态切换,给多租户微调场景省 100 倍显存。
- **Disaggregated Prefill/Decode**(2025 年底加入):P/D 分离架构,第 8 课详讲。
- **投机解码**(EAGLE、Medusa)原生集成。

2026 年的 vLLM 基本已经是**生产级推理栈的默认选项**,阿里、字节、Meta、Anthropic 的内部推理基础设施都在不同程度上借鉴或 fork vLLM。

### 3.2 SGLang:2025 年追上来的对手

SGLang 是 LMSys(做 Arena 那个组)2024 年出的推理引擎,2025 年开始爆发式增长。它最初的差异化是**把推理和 prompt DSL 合在一起**,提供声明式的分支、循环、多轮调用——但后来发现工程师要的是**更快的引擎**,于是 SGLang 逐渐演化成一个**专注于性能和结构化生成的 vLLM 竞品**。

SGLang 相对 vLLM 的核心突破是 **RadixAttention**——一种用前缀树(radix tree)管理 KV Cache 的结构,让**任意共享前缀**(不只是 batch 头部)都能自动去重。典型场景:

- RAG 多轮对话,历史上下文越来越长,RadixAttention 能让每一轮的 KV 都最大化复用。
- Agent 的 tool call loop,system prompt + 工具定义这段 4K token 前缀被所有 tool call 共享。
- 思考模型的多采样(self-consistency),同一个问题采样 8 次,prefix 100% 相同。

加上它对**结构化输出**(JSON Schema、regex、context-free grammar)的一等支持、对 thinking 模型 `<think>` tag 的原生处理,SGLang 2025-2026 年在**Agent、RAG、推理模型**这些长 prefix 场景下的吞吐经常比 vLLM 高 20-50%。

2026 年的选型建议是:

- **通用 API 服务、多模型管理**:vLLM 生态更成熟。
- **Agent、RAG、长前缀、结构化输出**:SGLang 更强。
- **团队内部两个都会一点的话**:跑 benchmark 对比你的真实流量,差异经常比文档上的数字更戏剧性。

### 3.3 TensorRT-LLM:性能最好,但代价很高

TensorRT-LLM 是 NVIDIA 官方推理库,**在 NVIDIA 硬件上理论性能最高**,因为它能直接用 TensorRT 做图级别的融合优化、FP8 kernel、硬件感知的 kernel 选择。但它有几个"反开源"的特性让它在生态上吃了大亏:

- **闭源内核**:很多核心 kernel 是编译好的 `.so`,不能改。
- **模型必须转 engine**:每次换模型或改 batch size,要跑 `trtllm-build` 编译一次,耗时几十分钟到几小时。
- **新模型支持慢**:一个新模型发布,vLLM 可能当天 PR 就合了,TensorRT-LLM 往往要等官方发个 release。
- **调试链条长**:出 bug 很难排查,堆栈到 C++ 就断了。

结果是:TensorRT-LLM **在能用的时候性能无敌**(比 vLLM 快 30-80% 不罕见),但**绝大多数团队用不动**。它主要活跃在:

- NVIDIA 云服务(NIM)和 DGX Cloud 内部。
- 像字节 / 腾讯这种有专职 Infra 团队愿意为性能付出维护代价的公司。
- Triton Inference Server 的后端之一。

2026 年一个折中路线是 **vLLM + TensorRT-LLM 后端模式**——vLLM 作为上层调度,底层 kernel 调 TensorRT-LLM。这让"又要 vLLM 生态又要极致性能"成为可能,但配置复杂度极高。

### 3.4 TGI、LMDeploy 和其他

- **TGI(Text Generation Inference)**:HuggingFace 官方推理栈。2023 年领先过一阵,2024 年开始被 vLLM 全面超过。目前主要活跃在 HuggingFace 自家的 Inference Endpoints 产品里,开源社区选型中已经不是首选。
- **LMDeploy**:上海 AI Lab 出的推理引擎,在国内生态里有一定份额,对 InternLM 系列支持最好。相对 vLLM 在某些量化(W4A16、AWQ)上性能更好,其他方面基本持平或稍弱。
- **MII**:Microsoft 的推理引擎,基于 DeepSpeed。热度下降。
- **Triton Inference Server**(不是那个 Triton Language):NVIDIA 的通用推理服务框架,可以作为**调度层**套在 vLLM / TensorRT-LLM 前面做多模型管理、gRPC 服务化、模型版本管理。大规模生产常用。

## 四、一个系统化的选型决策树

```
你的场景是什么?
│
├── 单人本地用(笔记本/Mac/桌面 GPU)
│   ├── Apple Silicon 且追求极致性能 → MLX
│   ├── 想要命令行 + API,低摩擦 → Ollama
│   ├── 想要图形界面 → LM Studio / Jan
│   └── 嵌入式/跨平台/极端硬件(树莓派、手机) → llama.cpp 裸用
│
├── 内部 < 10 人共享的小服务
│   ├── 流量不大、愿意容忍偶发排队 → Ollama(最省事)
│   └── 要稳定并发、已有 GPU → vLLM 单卡模式
│
├── 生产 API(10-1000 并发)
│   ├── 通用 chat 服务 → vLLM(首选)
│   ├── Agent / RAG / 长前缀场景 → SGLang
│   ├── 有专职 Infra、追极致性能 → TensorRT-LLM
│   └── 要原生 gRPC + 多模型版本管理 → Triton + vLLM 后端
│
├── 多租户微调平台(LoRA 热切换)
│   └── vLLM 的 Multi-LoRA(最成熟)
│
└── 边缘 / 离线设备(机器人、车机、医疗嵌入式)
    ├── ARM / 无 GPU → llama.cpp + CPU/NEON
    ├── 有 Qualcomm NPU → llama.cpp + QNN 或 mediapipe
    └── Apple 生态 → MLX / CoreML
```

## 五、一组真实的性能对比数据(仅供定位,不保证复现)

下面这组数据来自 2025 下半年社区和各家官方 benchmark 的**典型值**,用 Qwen3-8B 模型、A100-80G、2048 input / 1024 output、BF16 精度。不同版本、不同硬件、不同请求模式都会让数字漂移,但量级是可信的。

| 引擎 | 单请求延迟(TTFT) | 单请求吞吐 | 批量吞吐(64 并发) | 显存占用 |
| --- | --- | --- | --- | --- |
| Ollama(llama.cpp Q4_K_M) | 150 ms | 85 tok/s | 不适用(串行) | 5.5 GB |
| vLLM(BF16) | 180 ms | 90 tok/s | **4200 tok/s** | 65 GB |
| vLLM(AWQ W4A16) | 160 ms | 120 tok/s | 3800 tok/s | 18 GB |
| SGLang(BF16) | 170 ms | 95 tok/s | **4600 tok/s**(长 prefix 场景更高) | 65 GB |
| TensorRT-LLM(FP8) | 95 ms | 165 tok/s | **6200 tok/s** | 35 GB |
| llama.cpp(CUDA、F16) | 200 ms | 75 tok/s | ~250 tok/s(弱并发) | 16 GB |

读这组数字要抓住的主干:

1. **单请求延迟** Ollama 和 vLLM 差不多——说明单用户场景下 vLLM 没优势,Ollama 还更省显存。
2. **批量吞吐** vLLM/SGLang/TensorRT-LLM 是 llama.cpp/Ollama 的 **15-25 倍**——这不是 5%、10% 的差距,是数量级差距,根源是 PagedAttention + Continuous Batching。
3. **TensorRT-LLM 再快 30-50%**——值得,但维护成本要自己评估。
4. **AWQ W4A16 的吞吐没掉太多,显存掉到 1/3**——意味着 QPS 受显存约束时,量化是最值得的优化。

## 六、2026 年的一个新趋势:Prefill / Decode 分离架构

2025 年下半年开始,vLLM 和 SGLang 都原生支持了 **Disaggregated Serving**(Prefill 和 Decode 跑在不同的机器或不同的 GPU)。这个架构的起源是:

- **Prefill 阶段**是**算力瓶颈**(compute-bound),长 prompt 就会把 GPU 算力打满,但显存压力不大。
- **Decode 阶段**是**访存瓶颈**(memory-bound),每生成 1 个 token 都要读一遍 KV Cache,显存带宽决定吞吐,但算力用不上。
- 两者混在一个 GPU 上,一定互相挤:长 prompt 正在 prefill,新的 decode 请求被阻塞;大 batch 在 decode,prefill 排队。

**分离后**:prefill 机器一组,decode 机器一组,KV Cache 通过 RDMA / NVLink 在两组之间传递。Mooncake、DistServe、Splitwise 三篇论文提出了这个思路,2026 年已经进入 vLLM/SGLang 主线。第 8 课会详细展开这个架构和它的实现挑战。

你只需要现在先知道:**2026 年的生产级推理不再是"起一个 vLLM 就完事了",而是一个多角色的小型集群**。

## 七、一个常被问的问题:自建 vs 调 API

决策框架:

| 情况 | 自建(vLLM/SGLang) | 调 API(Qwen API / DeepSeek API / OpenAI / Anthropic) |
| --- | --- | --- |
| 日 token 量 < 1 亿 | 不划算(闲置 GPU 费用高) | **划算** |
| 日 token 量 1-10 亿 | 临界区,看具体模型和场景 | 仍然划算 |
| 日 token 量 > 10 亿 | **划算**(自建单位成本显著低) | 贵 |
| 有微调需求 | 必须自建 | 部分厂商支持微调但代价高 |
| 有数据合规/本地化要求 | 必须自建 | 不适用 |
| 追求最新最强模型 | 劣势(开源模型略落后前沿 3-6 个月) | 优势 |

**2026 年的普遍实践是混合架构**:自家后训练过的垂直模型走 vLLM,通用 / 复杂推理 / 开源追不上的任务走 API。

## 八、小结

1. **推理引擎分两派**:消费级单用户(llama.cpp 生态)和服务化高并发(vLLM 生态),它们在优化完全不同的问题,不是竞品。
2. **llama.cpp 是消费级的底座**,Ollama/LM Studio/Jan 都是它的前端。纯 C++、多后端、单文件 GGUF,让 LLM 能跑到几乎任何设备上。
3. **MLX 在 Apple Silicon 上利用 Unified Memory 有独特优势**,能用 Mac Studio 跑 70B-405B 级别的超大模型,GPU 方案做不到。
4. **vLLM 是服务化路线的事实标准**:PagedAttention + Continuous Batching + Prefix Caching + OpenAI 兼容 API + 活跃生态。
5. **SGLang 在 Agent/RAG/长 prefix 场景追平甚至超越 vLLM**,靠的是 RadixAttention 和对结构化输出的一等支持。
6. **TensorRT-LLM 性能极致但维护代价高**,适合有 Infra 团队的大厂。
7. **2026 年的新常态是 Prefill/Decode 分离**——单机 vLLM 已经不是最优架构。
8. **选型看并发和场景**,不看"谁更快"。Ollama 给单人、vLLM/SGLang 给多人、MLX 给 Mac、TensorRT-LLM 给追极致的大厂。

## 问题(检测你对本章的掌握)

1. 你们公司的产品经理说:"我们想做一个内部知识问答,初期 30 人用,晚高峰可能 10 个人同时提问。我们已经有一台 A100-40G,请你选推理引擎。" 请给出你的选型,并用本章提到的至少 3 个技术点解释为什么。(提示:10 并发算高并发吗?KV Cache 的压力够不够触发 PagedAttention 的价值?)

2. 有人在团队里主张"我们上 TensorRT-LLM,性能最好",另一人主张"我们上 vLLM,生态最好"。假设你们是一个 5 人的算法工程团队、没有专职 Infra、业务流量每天 5 亿 token、有 8 张 H100。请给出你的决策,并列出至少 4 条**可量化的评估维度**来支撑你的判断。

3. 为什么同一个 Qwen3-8B,在 Ollama 上单用户 85 tok/s,在 vLLM 上 64 并发时能到 4200 tok/s(每个请求约 65 tok/s)?请用你对 PagedAttention、Continuous Batching、GPU 利用率这三个词的理解来解释——为什么并发数增加吞吐几乎线性增长,但单请求的速度反而略微下降?
