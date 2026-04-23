# 后训练 - 第 2 课:模型文件到底是什么——safetensors、tokenizer、chat_template、GGUF

## 学习目标(本节结束后你能做到什么)

- 拿到一个陌生的 HuggingFace 仓库(比如 `Qwen/Qwen3-8B` 或 `meta-llama/Llama-3.1-8B-Instruct`),能一眼看懂每个文件的作用,知道哪些是必须、哪些是可选、哪些是历史遗留。
- 能讲清楚 `safetensors` 比 `pickle/pytorch_model.bin` 好在哪里,为什么 2023 年之后这是事实标准。
- 能讲清楚 `tokenizer` 的三大流派(BPE、SentencePiece、Tiktoken-style 字节级 BPE)的差异,以及 `tokenizer.json` 里到底存了什么。
- 能讲清楚为什么 **chat_template** 是整个后训练流程里最容易翻车的 30 行文本——训练时用错,模型会"精神错乱";推理时用错,模型会"答非所问"。
- 能讲清楚 `GGUF` 为什么是单文件格式,以及它怎么把权重、量化信息、tokenizer、chat_template 全部塞到一个 `.gguf` 里。
- 学完这一课,你再下载任何一个开源模型,都应该能告诉我:这个模型能跑在 transformers 吗?能跑在 vLLM 吗?能跑在 llama.cpp 吗?它的 chat 格式是什么?

## 一、先打开一个真实的模型目录看看

学这一课最好的方法是先把一个真实的开源模型目录 `ls` 一下。以 Qwen3-8B(2025 年发布的 dense 模型)为例,你在 HuggingFace 上看到的文件大致是:

```
Qwen/Qwen3-8B/
├── config.json                          # 模型结构配置(必须)
├── generation_config.json               # 生成参数默认值(可选)
├── model.safetensors.index.json         # 分片索引(权重 > 单文件上限时出现)
├── model-00001-of-00005.safetensors     # 权重分片 1
├── model-00002-of-00005.safetensors     # 权重分片 2
├── model-00003-of-00005.safetensors     # 权重分片 3
├── model-00004-of-00005.safetensors     # 权重分片 4
├── model-00005-of-00005.safetensors     # 权重分片 5
├── tokenizer.json                       # tokenizer 核心定义(必须,现代模型)
├── tokenizer_config.json                # tokenizer 元数据 + chat_template
├── vocab.json                           # 词表(历史兼容)
├── merges.txt                           # BPE 合并规则(历史兼容)
├── special_tokens_map.json              # 特殊 token 定义(<|im_start|>、<|endoftext|>…)
├── added_tokens.json                    # 新增 token
├── chat_template.jinja                  # 独立 chat template(2025 新规范)
├── README.md                            # 模型卡
└── LICENSE                              # 许可证
```

我们一个个拆。

## 二、config.json:模型的"建筑图纸"

`config.json` 是加载权重的**前提**。HuggingFace Transformers 用它来知道:这个模型是 Llama 还是 Qwen、有几层、多少头、hidden_size 是多少、用什么位置编码、RoPE 的 θ 是多少、vocab 多大。一个 Qwen3-8B 的典型 `config.json`:

```json
{
  "architectures": ["Qwen3ForCausalLM"],
  "model_type": "qwen3",
  "hidden_size": 4096,
  "intermediate_size": 22016,
  "num_hidden_layers": 36,
  "num_attention_heads": 32,
  "num_key_value_heads": 8,
  "head_dim": 128,
  "max_position_embeddings": 40960,
  "rope_theta": 1000000.0,
  "rope_scaling": null,
  "torch_dtype": "bfloat16",
  "vocab_size": 151936,
  "tie_word_embeddings": false,
  "use_sliding_window": false,
  "sliding_window": 32768,
  "attention_bias": false,
  "_name_or_path": "Qwen/Qwen3-8B"
}
```

需要重点看的几个字段:

- **`architectures`**:决定加载哪个 Python 类。`Qwen3ForCausalLM` 意味着 `transformers` 会去 `modeling_qwen3.py` 里找这个类。如果这个类不存在(transformers 版本太老),加载直接失败——这就是为什么升级 HF 大模型经常要同时升级 `transformers`。
- **`num_attention_heads` 和 `num_key_value_heads`**:两者不相等说明用了 **GQA(Grouped Query Attention)** ——32 个 Q head 共享 8 组 K/V head。这个细节直接决定了 KV Cache 显存占用(本课程第 4 课会深挖)。
- **`rope_theta` 和 `rope_scaling`**:位置编码。`rope_theta = 1000000` 是 long-context 的信号(传统是 10000)。`rope_scaling` 非 null 表示用了 YaRN / NTK 之类的外推方法(第 20 课深讲)。
- **`torch_dtype`**:原始训练精度。`bfloat16` 是 2024 年之后的主流,`float16` 是老模型。BF16 的数值范围更大,训练更稳。
- **`vocab_size`**:词表大小,必须和 tokenizer 对齐,否则 embedding 查表越界。

**一个容易踩的坑**:你 LoRA 微调后如果扩了词表(加了新 token)但忘记同步修改 `config.json` 的 `vocab_size`,加载时会报 embedding 维度不匹配。

## 三、权重文件:从 pytorch_model.bin 到 safetensors

### 3.1 2023 年之前的 pytorch_model.bin 噩梦

早期 HuggingFace 模型权重用 PyTorch 默认的 `torch.save` 序列化成 `pytorch_model.bin`,本质是 Python 的 `pickle`。问题是:**pickle 可以执行任意代码**。一个带毒的 `pytorch_model.bin`,你 `torch.load()` 的那一秒,它就能在你的机器上 `os.system("rm -rf ~")`。这不是理论风险,HuggingFace 2023 年之后开始强制扫描上传的 pickle 文件,就是因为出过事。

除了安全,pickle 还有几个具体毛病:

1. **加载慢**:pickle 反序列化要解包 Python 对象,7B 模型的 `torch.load` 在 SSD 上都要 30-60 秒。
2. **不支持 memory-mapped 加载**:必须把整个文件读到内存,多卡分发时容易 OOM。
3. **不跨语言**:Rust / Go / JS 想读 PyTorch 的 pickle,几乎不可能。

### 3.2 safetensors:HuggingFace 2022 年开始推的替代品

safetensors 格式极其简单:**一个 JSON header + 一段裸张量数据**。具体布局:

```
┌─────────────────┐
│ 8 bytes         │ header 长度(uint64,little-endian)
├─────────────────┤
│ N bytes         │ JSON header,描述每个 tensor 的名字、dtype、shape、offset
├─────────────────┤
│                 │
│ 裸 tensor 数据  │ 按 header 里的 offset 顺序排列
│                 │
└─────────────────┘
```

一个典型 header 长这样:

```json
{
  "model.embed_tokens.weight": {
    "dtype": "BF16",
    "shape": [151936, 4096],
    "data_offsets": [0, 1244512256]
  },
  "model.layers.0.self_attn.q_proj.weight": {
    "dtype": "BF16",
    "shape": [4096, 4096],
    "data_offsets": [1244512256, 1278066688]
  },
  ...
}
```

它解决了 pickle 的三个问题:

1. **零代码执行**:就是读字节,没有 eval。
2. **memory-mapped 加载**:因为数据是裸的、偏移固定,可以 `mmap` 上来按需读。7B 模型加载从 30 秒降到 2-3 秒。
3. **跨语言**:Rust 写的 `candle`、Go 写的 `ollama-rs`、JS 写的 `transformers.js` 都能直接读。

### 3.3 为什么要分片?model-00001-of-00005.safetensors

单个 HTTP 下载文件 HuggingFace 推荐不超过 50GB。一个 70B BF16 模型权重是 140GB,必须分片。分片后会有一个 `model.safetensors.index.json` 描述每个 tensor 在哪个文件里:

```json
{
  "metadata": {"total_size": 16060522496},
  "weight_map": {
    "model.embed_tokens.weight": "model-00001-of-00005.safetensors",
    "model.layers.0.self_attn.q_proj.weight": "model-00001-of-00005.safetensors",
    "model.layers.35.mlp.down_proj.weight": "model-00005-of-00005.safetensors",
    ...
  }
}
```

这样 `from_pretrained` 就知道从哪个文件拉哪个 tensor,还能支持断点续传。

## 四、Tokenizer:被严重低估的一层

模型看到的不是字符,是 token id。`tokenizer` 干的事情就是字符串 ↔ token id 的双向转换。这一层如果理解不到位,后面所有微调都会有诡异 bug(常见表现:训练 loss 一直在 7 降不下来,推理输出乱码,或者遇到特殊符号就崩溃)。

### 4.1 三大流派

| 流派 | 代表模型 | 核心思想 | 优点 | 缺点 |
| --- | --- | --- | --- | --- |
| **Word-level BPE** | GPT-2 | 先按空格切词再 BPE 合并 | 英文高效 | 不适合中文/日文(没有空格) |
| **SentencePiece BPE/Unigram** | Llama 1/2/3、Mistral、Gemma | 把原文当成一个字节流,不预分词,按 BPE 合并 | 跨语言鲁棒 | 需要训练语料,词表固定 |
| **Byte-level BPE (Tiktoken-style)** | GPT-3.5/4、Qwen、DeepSeek、Claude | 先把任意字符串转成 UTF-8 字节流,再在字节空间做 BPE | 零 OOV(out of vocabulary)、多语言极友好、压缩率高 | 实现复杂、token 对人不直观 |

**2024-2026 的主流是 byte-level BPE**。原因是它解决了 SentencePiece 的一个硬伤:遇到训练时没见过的字符(生僻汉字、emoji、特殊符号)会吐出 `<unk>` 或乱码。字节级 BPE 因为在字节空间工作,任何 UTF-8 字符串最差也能被拆成字节序列,永远有解。

### 4.2 tokenizer.json 里到底存了什么

打开 Qwen3 的 `tokenizer.json`,你会看到类似:

```json
{
  "version": "1.0",
  "truncation": null,
  "padding": null,
  "added_tokens": [
    {"id": 151643, "content": "<|endoftext|>", "special": true},
    {"id": 151644, "content": "<|im_start|>", "special": true},
    {"id": 151645, "content": "<|im_end|>", "special": true},
    ...
  ],
  "normalizer": null,
  "pre_tokenizer": {
    "type": "ByteLevel",
    "add_prefix_space": false
  },
  "model": {
    "type": "BPE",
    "vocab": { "Ġthe": 0, "Ġand": 1, ... },
    "merges": ["Ġ t", "Ġt h", "Ġth e", ...]
  },
  "post_processor": { ... },
  "decoder": {"type": "ByteLevel"}
}
```

关键结构:

- **`pre_tokenizer`**:字符串进来先做什么预处理(ByteLevel 会把每个字节映射到可打印字符,比如空格变成 `Ġ`)。
- **`model`**:核心词表和合并规则。BPE 的训练产物就是 `vocab` + `merges`。
- **`post_processor`**:tokenize 完之后自动加什么(比如 BOS/EOS)。
- **`decoder`**:反向解码的规则。

`vocab.json` 和 `merges.txt` 是**旧版分开存放的历史遗留**,现在 `tokenizer.json` 已经把它们合并了。新模型只依赖 `tokenizer.json`,旧模型保留两者是为了兼容 transformers 老版本。

### 4.3 特殊 Token:后训练里最容易出事的点

每个模型都有一组**特殊 token**用来区分对话角色、结束标志、工具调用、推理模式等:

| 模型 | 关键特殊 token |
| --- | --- |
| Llama 3 | `<\|begin_of_text\|>`、`<\|start_header_id\|>`、`<\|end_header_id\|>`、`<\|eot_id\|>` |
| Qwen2/3 | `<\|im_start\|>`、`<\|im_end\|>`、`<\|endoftext\|>`、`<think>`、`</think>` |
| Mistral | `[INST]`、`[/INST]`、`<s>`、`</s>`(注意这些不是特殊 token,是字面量) |
| DeepSeek-R1 | `<｜begin▁of▁sentence｜>`、`<｜User｜>`、`<｜Assistant｜>`、`<think>`、`</think>` |
| ChatGLM3/4 | `<\|user\|>`、`<\|assistant\|>`、`<\|system\|>`、`<\|observation\|>` |

**为什么这些会出事?** 因为在 SFT 阶段,这些 token 必须被当作原子单元训练——`<|im_start|>` 应该是 **一个** token,而不是 `<`、`|`、`im`、`_`、`start`、`|`、`>` 七个子词。如果你做 SFT 时用错了 tokenizer(比如用 Llama tokenizer 处理 Qwen 数据),这些边界信号就失效了,模型学到一堆乱码。本课程第 9 课会专门讲这个坑。

## 五、chat_template:这 30 行 Jinja 决定了你的模型会不会说话

### 5.1 为什么需要 chat_template

基座模型看到的只有一段连续文本。把一段对话塞给它,必须用 **特殊标记** 区分 system / user / assistant,让模型知道每句话是谁说的、从哪里该自己接话。这个"怎么把结构化对话变成一段字符串"的规则,就叫 chat_template。

Qwen3 的 chat_template(存在 `tokenizer_config.json` 的 `chat_template` 字段,或独立的 `chat_template.jinja`)大致长这样(简化版):

```jinja
{%- for message in messages %}
{%- if message['role'] == 'system' %}
<|im_start|>system
{{ message['content'] }}<|im_end|>
{%- elif message['role'] == 'user' %}
<|im_start|>user
{{ message['content'] }}<|im_end|>
{%- elif message['role'] == 'assistant' %}
<|im_start|>assistant
{{ message['content'] }}<|im_end|>
{%- endif %}
{%- endfor %}
{%- if add_generation_prompt %}
<|im_start|>assistant
{%- endif %}
```

拿一段对话走一遍:

```python
messages = [
    {"role": "system", "content": "你是一个严谨的技术助手。"},
    {"role": "user", "content": "什么是 LoRA?"},
]
```

应用 chat_template + `add_generation_prompt=True` 后,喂给模型的实际字符串是:

```
<|im_start|>system
你是一个严谨的技术助手。<|im_end|>
<|im_start|>user
什么是 LoRA?<|im_end|>
<|im_start|>assistant
```

模型从这个"assistant\n" 后面开始续写,遇到 `<|im_end|>` 就知道自己说完了。

### 5.2 不同模型的格式差异(坑的重灾区)

同一段对话,不同模型的 chat 字符串长得完全不一样:

```
Llama 3:
<|begin_of_text|><|start_header_id|>system<|end_header_id|>

You are helpful.<|eot_id|><|start_header_id|>user<|end_header_id|>

Hello<|eot_id|><|start_header_id|>assistant<|end_header_id|>


Qwen3:
<|im_start|>system
You are helpful.<|im_end|>
<|im_start|>user
Hello<|im_end|>
<|im_start|>assistant


Mistral Instruct:
<s>[INST] You are helpful.

Hello [/INST]


DeepSeek-R1:
<｜begin▁of▁sentence｜><｜User｜>Hello<｜Assistant｜><think>
```

注意 DeepSeek-R1 的最后一行:它推理模式下会在 assistant 前自动加一个 `<think>`,这是触发"思考模式"的关键。如果你的代码在推理时漏掉了这个,模型不会展开 CoT。

### 5.3 训练和推理必须严格一致

这是整个后训练最常见的翻车点:

- **训练时**用 `chat_template=A` 构造数据,loss mask 覆盖 assistant 部分。
- **推理时**用 `chat_template=B` 格式化输入(可能来自某个老版本的 `tokenizer_config.json`)。
- 结果:模型见到的格式和训练不一致,表现像是"有点会但又不对劲"。

**定位这个 bug 的最快方法**:训练和推理各 dump 一条样本的原始 token id 序列,diff 一下。90% 的时候你会发现两边的 BOS 个数不一样,或者一边用 `<|im_end|>` 一边用 `<|eot_id|>`。

### 5.4 2025 的新规范:独立的 chat_template.jinja

早期 chat_template 是塞在 `tokenizer_config.json` 的一个字符串字段里,JSON 里写 Jinja 很难维护(要手动转义换行和引号)。2025 年之后 HuggingFace 开始推荐把 template 拆到独立的 `chat_template.jinja` 文件里,Qwen3、Llama 3.2 之后的版本都这么做了。

## 六、generation_config.json:采样默认值

一个经常被忽视的小文件:

```json
{
  "bos_token_id": 151643,
  "eos_token_id": [151645, 151643],
  "pad_token_id": 151643,
  "do_sample": true,
  "temperature": 0.7,
  "top_p": 0.8,
  "top_k": 20,
  "repetition_penalty": 1.05,
  "max_new_tokens": 32768
}
```

几个细节:

- `eos_token_id` 是数组说明**多个 token 都可以停止生成**。Qwen3 把 `<|im_end|>` 和 `<|endoftext|>` 都列为停止符。推理时任何一个出现就停。
- `temperature`、`top_p`、`top_k` 是模型作者推荐的默认采样参数——**不代表最优**,不代表你业务上该用。但至少说明作者是在这个参数组合下做的内部评测。
- 不同模型卡(model card)里推荐的 thinking 模式参数通常不同。比如 Qwen3 的 non-thinking 模式建议 `temperature=0.7`,thinking 模式建议 `temperature=0.6, top_p=0.95`。

## 七、GGUF:llama.cpp 的单文件格式

### 7.1 为什么要另起一个格式

llama.cpp 的目标是 **不依赖 Python / PyTorch / CUDA,纯 C++ 跑 LLM,跑在 Mac、跑在树莓派、跑在手机上**。HuggingFace 的那堆分散文件对这个场景不友好:

1. 分散文件在移动端/嵌入式场景部署麻烦。
2. safetensors 存的是 FP16/BF16,消费级硬件跑不动 7B+,必须量化。
3. safetensors 不存 tokenizer、不存 chat_template,llama.cpp 需要把这些也打包进去。

于是 2023 年 llama.cpp 社区搞了 **GGUF(GGML Universal Format)**,前身是 GGML / GGJT。核心设计原则是:**一个 .gguf 文件 = 权重(量化后) + 元数据 + tokenizer + chat_template + 架构参数**,自包含、单文件、可 mmap、可版本化。

### 7.2 GGUF 文件结构

```
┌──────────────────────────────┐
│ Magic: "GGUF"                │ 4 bytes
├──────────────────────────────┤
│ Version: 3                   │ 4 bytes
├──────────────────────────────┤
│ Tensor count                 │ 8 bytes
├──────────────────────────────┤
│ Metadata KV count            │ 8 bytes
├──────────────────────────────┤
│ Metadata KV pairs            │ 可变长度
│   general.architecture = "qwen3"
│   general.name = "Qwen3-8B"
│   qwen3.context_length = 40960
│   qwen3.embedding_length = 4096
│   qwen3.attention.head_count = 32
│   qwen3.attention.head_count_kv = 8
│   tokenizer.ggml.model = "gpt2"
│   tokenizer.ggml.tokens = [...]
│   tokenizer.ggml.merges = [...]
│   tokenizer.chat_template = "{%- for message in ... %}"
├──────────────────────────────┤
│ Tensor info table            │ 每个 tensor 的 name/shape/dtype/offset
├──────────────────────────────┤
│                              │
│ Tensor data(量化后)         │ mmap 友好的对齐布局
│                              │
└──────────────────────────────┘
```

一个文件就包含了 transformers 那堆文件里所有能跑的信息。

### 7.3 GGUF 的量化命名法(看懂 Q4_K_M、Q5_0、IQ3_XS)

llama.cpp 的量化方案命名像天书,我们拆开看:

```
Q4_K_M
│ │ └─ Mixed precision 策略:S(small)、M(medium)、L(large)
│ └─── K-quant 家族(分块 + 学习偏移)
└───── 平均 bit 数(每个权重大约 4 bit)

Q5_0
│ │
│ └─── 老版本 legacy,不带 K
└───── 5 bit

IQ3_XS
│  │ └─ size 等级
│  └─── 3 bit
└────── Importance quantization(新家族,2024 引入)
```

工程经验:

- **Q4_K_M** 是 2024-2026 社区的默认选择,压缩比 ~4x,质量损失 < 1%。
- **Q5_K_M** 是"几乎无损"档,大约损失 < 0.3%。
- **Q3_K_S / IQ3_XS / IQ2_S** 是极限压缩档,质量损失明显,只在低配设备用。
- **Q8_0** 是近似无损,但压缩比只有 2x,一般只用在 embedding 层或小模型。

量化原理第 6 课会深讲,这里只要知道`一个 Q4_K_M 的 Qwen3-8B.gguf 大概 5GB、能塞进一张 8GB 显存`就够了。

### 7.4 GGUF 和 safetensors 的转换

**safetensors → GGUF**(训练 / 微调后打包给 llama.cpp):

```bash
python llama.cpp/convert_hf_to_gguf.py \
    /path/to/Qwen3-8B-SFT \
    --outfile qwen3-8b-sft-f16.gguf \
    --outtype f16

# 然后量化
./llama-quantize qwen3-8b-sft-f16.gguf qwen3-8b-sft-q4_k_m.gguf Q4_K_M
```

**GGUF → safetensors** 基本不做,因为量化信息的丢失、tokenizer 的格式差异会让逆转变得不完备。**一条原则:GGUF 是部署终点,不是训练中间态**。

## 八、把这一课串起来:如何读一个陌生模型

下次你下载一个新模型,按这个 checklist 过一遍,能避免 90% 的坑:

1. `cat config.json` → 确认架构、参数量、RoPE、GQA 配置。
2. `ls *.safetensors` → 确认是 safetensors(新)还是 pytorch_model.bin(旧)。
3. `cat tokenizer_config.json | jq .chat_template` → 看看 chat 格式长什么样,必要时对比模型卡。
4. `cat special_tokens_map.json` → 看特殊 token 有哪些,尤其是 `<think>`、`<tool_call>` 这种能力标记。
5. `cat generation_config.json` → 看作者推荐的采样参数。
6. README.md → 看是否是 thinking 模型、是否支持 function calling、上下文长度。
7. 如果是 GGUF,`./llama-gguf-dump model.gguf | head -200` 看元数据。

这一套过完,你基本能判断:

- **能跑 transformers 吗**:有 safetensors + config 即可。
- **能跑 vLLM 吗**:架构在 vLLM 支持列表里,且 tokenizer 能被 `tokenizers` 库加载。
- **能跑 llama.cpp 吗**:有现成 GGUF,或者可以用 `convert_hf_to_gguf.py` 转。
- **chat 格式对不对**:训练侧的格式化和推理侧要用同一份 chat_template。

## 九、小结

1. **HF 模型目录的核心文件是 5 类**:架构(config.json)、权重(*.safetensors)、tokenizer(tokenizer.json + tokenizer_config.json)、chat_template(独立或嵌入)、生成参数(generation_config.json)。
2. **safetensors 是 2023 后的事实标准**:零代码执行、mmap 友好、跨语言。pickle 已经是历史包袱。
3. **tokenizer 的 byte-level BPE** 是 2024+ 主流方案,零 OOV、多语言友好。特殊 token 的边界必须在训练和推理一致。
4. **chat_template 是后训练最常见的翻车点**:训练/推理必须严格同步,不同模型的格式差异巨大,改 template 前要 dump token id diff 验证。
5. **GGUF 是 llama.cpp 的单文件格式**:权重 + 元数据 + tokenizer + chat_template 全打包,mmap 友好,量化命名(Q4_K_M、IQ3_XS)有一套语法。
6. **每次下载陌生模型都用那张 checklist 过一遍**——这个习惯能省下你未来几十个小时的"为什么模型在胡说八道"的排查时间。

## 问题(检测你对本章的掌握)

1. 你下载了一个 LoRA 微调好的 Qwen3-8B,放到 vLLM 上推理,发现它总是不会停止生成,一直输出到 max_tokens 才停。请用本章讲过的知识,给出三个可能的根因假设,并说说你会怎么逐个排查。
2. 同一个模型的 `bfloat16 safetensors` 版本大约 16GB,`Q4_K_M GGUF` 版本大约 4.9GB。这 3 倍多的压缩是怎么来的?请从"哪些信息被压缩了、哪些没被压、哪些反而被新增"三个角度分析。(提示:考虑量化、元数据、chat_template 的存储位置。)
3. 有人说:"chat_template 不就是加几个 `<|im_start|>`、`<|im_end|>` 吗,随便写写就行了。" 请用你能想到的最具体的例子反驳他——假设训练时用了 Qwen 格式,推理时 `add_generation_prompt=False` 而且用错了 Llama 格式,这个模型的输出会出现什么具体表现?(提示:想一想 loss mask、停止符、token 边界。)
