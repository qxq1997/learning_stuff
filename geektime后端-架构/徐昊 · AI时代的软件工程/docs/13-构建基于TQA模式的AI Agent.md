你好，我是徐昊，今天我们来继续学习AI时代的软件工程。

上节课我们介绍了三种通过大语言模型（Large Language Model，LLM）辅助用户故事编写的形式：通过LLM提取不可言说的业务知识，修改用户故事以及补充完善验收条件。

这三种方式都需要使用到一种特殊的LLM交互模式TQA（Thought-Question-Answer），TQA的主要用途是收集人的反馈，用以提高生成内容的质量。TQA是从推理行动（Reason-Act，ReACT）演化出来的交互模式。那么今天我们就来学习如何构造一个TQA的AI Agent。

## 推理行动（Reason-Act）

ReAct是一种专门为了LLM能执行某些操作任务而设计的模式。举个例子，当LLM收到一个问题时，它可以选择执行一个动作来检索相关信息，然后利用检索到的信息来回答问题。通过ReAct，LLM可以超越其常规功能，利用自然语言推理解决复杂任务。

ReAct也是目前最热门的一个LLM模式。前一阵子（2023年底）大火的ChatGPT Plugin，还有Microsoft开源的Semantic Kernel都是基于ReAct模式。

一个典型的ReAct Prompting通常包含四个部分：

- 上下文提示：提示LLM当前解决问题的上下文是什么。这几乎在所有LLM提示模版中都会用到。目的是让LLM开始了解我们到底想让它做什么。
- ReAct步骤：推理和行动规划的步骤。在所有 ReAct 提示中，思考-行动-观察（Thought-Action-Observation）是一个标准顺序。然而在具体情况中，我们会使用更为具体的“思考 ”行为。
- 推理：通过“根据现状进行思考和推理”这样的通用指令或“让我们一步步思考”这样的思维链提示来实现推理。这部分通常还会包含少样本示例（few shots example），以提供如何将理由与行动联系起来的准确提示。
- 行动：最后一个关键信息是行动指令集，LLM可以从中选择一个行动来响应推理思考。

下面让我们看一个例子：

> Answer the following questions as best you can. You have access to the following tools:  
> //尽你所能地回答下面的问题，你可以使用如下的工具  
>    
> search, calculate  
> //搜索，计算  
>    
> Use the following format:  
> //回答问题时，使用下面的格式  
>    
> Question: the input question you must answer  
> //问题：你必须回答的用户提问  
> Thought: you should always think about what to do  
> //思考：你应该永远思考要做什么  
> Action: the action to take, should be one of \[search, calculate]  
> //行动：你要采取的行动，应该是\[搜索，计算]其中之一  
> Action Input: the input to the action  
> //行动输入：给予工具的输入是什么  
> Observation: the result of the action  
> //观察：行为的结果是什么  
> … (this Thought/Action/Action Input/Observation can repeat N times)  
> //…(思考/行动/行动输入/观察 可以循环多次）  
> Thought: I now know the final answer  
> //思考：现在我知道了最终答案  
> Final Answer: the final answer to the original input question  
> //最终结果：原始问题的最终结果是什么。  
>    
> Begin!  
> //开始！  
>    
> Question: 淘宝去年双十一的营业额，可以买多少瓶可乐  
> Thought:

在上面这个提示词中，四部分分别对应的是：

- 上下文提示：尽可能回答用户提出的问题。
- ReAct步骤：Thought/Action/Action Input/Observation
- 推理：就是展开解释Thought，Action，Action Input，Observation分别要做什么。
- 行动：Search, Calculate

如果我们在ChatGPT中直接使用这个提示词，会得到如下结果：

![](https://static001.geekbang.org/resource/image/8d/cf/8d34c09d686ff130f3606152dc3c85cf.jpg?wh=1323x1098)

可以看到，在一开始LLM就给出了解决问题的思路，先搜索淘宝的双十一的营业额，然后计算可以购买多少可乐。而这个思路则是根据我们提供的行动分解的。

因为我们并不能给ChatGPT提供可执行的行动（search，calculate），所以我们并没得到真正的结果，但是在这个过程中，ChatGPT展示了正确的思路以及在哪个环节需要去调用什么行为。

因此，ReAct模式也成为了LLM与其他工具交互的主要模式。这种由LLM推理并控制其他工具调用的方式，也被称作AI Agent。现在（2024年）主流的LLM框架几乎都支持构建以ReAct为核心的AI Agent。

我们上面例子里的提示词，就来自LangChain的ReAct模板：

> Answer the following questions as best you can. You have access to the following tools:  
>    
> {tools}  
>    
> Use the following format:  
>    
> Question: the input question you must answer  
> Thought: you should always think about what to do  
> Action: the action to take, should be one of \[{tool\_names}]  
> Action Input: the input to the action  
> Observation: the result of the action  
> … (this Thought/Action/Action Input/Observation can repeat N times)  
> Thought: I now know the final answer  
> Final Answer: the final answer to the original input question  
>    
> Begin!  
>    
> Question: {input}  
> Thought:{agent\_scratchpad}

而使用类似下面的代码，就可以真正运行这个agent（当然，需要提供真实的Tool，这部分请自行查阅LangChain或其他框架的文档）：

```plain
import openai
import os
from langchain.llms import OpenAI
from langchain.agents import load_tools
from langchain.agents import initialize_agent
from dotenv import load_dotenv
load_dotenv()

os.environ["OPENAI_API_KEY"] = getpass()
from langchain import OpenAI, Wikipedia
from langchain.agents import initialize_agent, Tool
from langchain.agents import AgentType

tools = [
    Tool(
        name="Search",
        func=...,
        description="useful for when you need to ask with search"
    ),
    Tool(
        name="Calculate",
        func=...,
        description="useful for when you need to calculate"
    )
]
llm = OpenAI(temperature=0, model_name="gpt-3.5-turbo")
react = initialize_agent(tools, llm, agent=AgentType.REACT_DOCSTORE, verbose=True)
react.run("淘宝去年双十一的营业额，可以买多少瓶可乐")
```

需要注意一点，目前与推理有关的提示词受基础语料的影响极大，因而不同语言编写的提示词推理效果有显著差异。对于ChatGPT而言，ReAct形式的提示词，用英语编写会有更好的结果。

## 想-问-答（Thought-Question-Answer）

理解了推理行动模式，那么想-问-答只不过提供了不同的响应步骤而已。那么用于验收条件编写的TQA提示词是这样的：

> You are a business analyst who is familiar with specification by example. I’m the domain expert.  
> //你是一个业务分析师，而我是领域专家  
>    
> ===CONTEXT  
> {context}  
> ===END OF CONTEXT  
>    
> ===USER STORY  
> {story}  
> ===END OF USER STORY  
>    
> Explain the user story as scenarios. Use the following format:  
> //使用 场景 解释用户故事，并遵循如下格式  
>    
> Thought: you should always think about what is still uncertain about the user story. Ignore technical concerns.  
> //思考：你应该考虑用户故事中不清晰的部分。但忽略技术细节  
> Question: the question to ask to clarify the user story  
> //问题：提出问题帮助你澄清这个用户故事  
> Answer: the answer I responded to the question  
> //回答：我给出答案  
> … (this Thought/Question/Answer repeat at least 3 times, at most 10 times)  
> //（Thought/Question/Answer 重复至少3次而不多于10次）  
> Thought: I know enough to explain the user story  
> //思考：我已经对这个用户故事了解了足够多的内容  
> Scenarios: List all possible scenarios with concrete example in  
> Given/When/Then style  
> // 场景：列出所有场景。使用Given/When/Then的格式表述  
> {history}  
> {input}

这是一个典型的ReAct形式的提示词，四部分分别对应的是：

- 上下文提示：你是一个业务分析师，而我是领域专家。与一般的ReAct不同，我们的上下文提示中，还包含了业务背景和具体的用户故事。
- ReAct步骤：Thought/Question/Answer
- 推理：就是展开解释Thought，Question，Answer分别要做什么。
- 行动：行动只有一个，就是Answer（向人来问问题）。

此外，因为是连续发问，我们不希望LLM反复询问同一个问题，也需要保持记录之前提问的内容，所以包含了历史记录（{history}）。

同样，如果我们将这个提示词展开直接放入ChatGPT，并不会得到我们想要的效果：

![](https://static001.geekbang.org/resource/image/a8/0f/a842f47f86126586f91139f2dd585b0f.jpg?wh=1396x7024)

可以看到ChatGPT进入了自问自答模式，并没有给人机会来提供真正的答案。想要实现人与LLM的互动问答，需要使用**LLM API中的停止序列（Stop Sequence）**。在模型生成内容的过程中，如果碰到指定的**停止序列**，模型就会停在那个位置。例如句子或列表的结尾，或者是问答环节中提问的部分。

显而易见，在TQA中，停止序列是 “**Answer:**”，也就是碰到需要等待用户给予反馈的时候停下，等用户输入完成之后，再继续后续的推理和任务。

对于不同的LLM API而言，停止序列的设定各有不同，请详细阅读文档。然后在前面给出的Agent例子中，替换提示词模板，就可以实现一个基于TQA的Agent了。

## 小结

一旦我们理解了ReAct和TQA背后的实现机制，对于它们是如何发出提问，并根据提问继续完成后续任务就有了充分的理解。这里我们需要注意的是，在TQA模式中，起到关键作用的除了ReAct之外，还有上下文和历史记录部分。

这也对应了我们在[上一节课](https://time.geekbang.org/column/article/763970)提到了三种回答方式：

1. 模板中 {context} 表示了业务整体的解决方案：如果LLM提出的问题，包含了对于基础概念或流程的误解，**那么我们要重新修改业务背景说明，**也就是修改了模板中表示业务上下文的部分。
2. 模版中 {story} 表示了当前的用户故事：如果LLM提出的问题，包含了对于操作的误解，**那么我们要重新修改用户故事，**也就是修改了模板中表示用户故事的部分。
3. 模版中 {history} 表示之前回答过的历史记录：如果LLM提出的问题，仅仅是关于交互细节的，那么我们只需要在会话中回答这些细节就可以了，这些细节会被记入历史记录。

因而TQA一个很好的例子，它展示了我们如何在交互过程中利用特定的文本结构，构成有效的反馈。

## 思考题

请根据不同的用户故事场景（前台，API），改写TQA模板，增加LLM反馈的内容。

欢迎你在留言区分享自己的思考或疑惑，我们会把精彩内容置顶供大家学习讨论。
<div><strong>精选留言（6）</strong></div><ul>
<li><span>术子米德</span> 👍（0） 💬（3）<p>🤔☕️🤔☕️🤔
【R】TQA = &lt;想&gt;Thought-&lt;问&gt;Question-&lt;答&gt;Answer
（an evolution of ReACT&lt;Thought&#47;Action&#47;Action Input&#47;Observation&gt;）
用于：提取不可言说的业务知识、修改用户故事、补充完善验收条件。
【Q】告诉LLM从哪方面想&lt;Thought&gt;，然后LLM根据上下文、进行推理后会向我发问&lt;Question&gt;，由我来回答&lt;Answer&gt;，再继续来几轮TQA，如此这般嘛？
如果每轮的Answer由我来回答，那下一轮的Thought是我每次新给出，还是预定义要进行哪几方面的Thought？
— by 术子米德@2024年4月7日</p>2024-04-08</li><br/><li><span>范飞扬</span> 👍（4） 💬（0）<p>实践出真知，直接用我的代码在本地跑起来～

我把老师的方法和 Prompt 做了微调，不需要处理 history 和 Stop Sequence，也不需要手写OutputParser，感觉自己实现还是比较优雅的哈哈~

代码在文章最后~：https:&#47;&#47;mp.weixin.qq.com&#47;s?__biz=Mzg3MDg5MzYyMA==&amp;mid=2247483961&amp;idx=1&amp;sn=792be3eb1c598edd8e256e86359aa398&amp;chksm=ce879362f9f01a74ead04c804e77f9a93e802f51c506cdb6520d641137c4db82576cdccfe255&amp;token=1482009703&amp;lang=zh_CN#rd</p>2024-04-11</li><br/><li><span>范飞扬</span> 👍（0） 💬（0）<p>原文：模板中 {context} 表示了业务整体的解决方案。

这里不准确，根据上一讲[1]， context 不仅包含了整体解决方案，还包含了用户旅程。


[1] 12讲的原文：“ 为 LLM 提供整体解决方案和用户旅程作为业务背景说明；”</p>2024-04-14</li><br/><li><span>范飞扬</span> 👍（0） 💬（0）<p>思考题：请根据不同的用户故事场景（前台，API），改写 TQA 模板，增加 LLM 反馈的内容。

首先，这个思考题我就没太搞懂，我是这么理解的：改写TQA模板，使 LLM 返回 API 文档。
（不知道这样理解对嘛？）

那么，对于这个思考题，我的想法是，修改Prompt的第一句和最后一句就可以了？

比如，
把“You are a business analyst who is familiar with specification by example. ” ，
改成 “You are a software engineer expert who is familar with REST and other best practices in API design.”

再把“Scenarios: List all possible scenarios with concrete example in Given&#47;When&#47;Then style”，
改成“Final Answers: Output the API document using RAML format.”</p>2024-04-11</li><br/><li><span>aoe</span> 👍（0） 💬（0）<p>TQA1 TQA2 包装成 bot 在 coze.com 上发布了「搜索路径 Bot Store -&gt; Learning -&gt; TQA」，效果没有直接使用 workflows 好「TQA2 的 bot 只有一轮就结束了， workflows 经过多轮才得出解决方案」

TQA1 开始数据
context
作为学校的教职员工，我希望学生可以根据录取通知将学籍注册到教学计划上，从而我可以跟踪他们的获取学位的进度
整个学籍管理系统是一个 Web 应用； 当教职员工发放录取通知时，会同步建立学生的账号；学生可以根据身份信息，查询自己的账号；在报道注册时，学生登录账号，按照录取通知书完成学年的注册；

story
1. 我希望学生可以根据录取通知将学籍注册到教学计划上
2. 作为学生，我希望登录之后接收到注册的通知，从而我可以不会错过学期注册的期限

TQA2 拼接 history 数据
context
作为学校的教职员工，我希望学生可以根据录取通知将学籍注册到教学计划上，从而我可以跟踪他们的获取学位的进度
整个学籍管理系统是一个 Web 应用； 当教职员工发放录取通知时，会同步建立学生的账号；学生可以根据身份信息，查询自己的账号；在报道注册时，学生登录账号，按照录取通知书完成学年的注册；

story
1. 我希望学生可以根据录取通知将学籍注册到教学计划上
2. 作为学生，我希望登录之后接收到注册的通知，从而我可以不会错过学期注册的期限

history
学生如何根据录取通知将学籍注册到教学计划上？登录教学系统后完成注册
学生何时可以注册学籍？收到注册手机短信后
学生如何登录账号来完成学年注册？使用手机号码登录注册
学生如何查询自己的账号？使用手机号码查询或注册成功后分配到的学号
学生注册学籍后，是否会收到通知？会收到手机短信通知
学生如何知道学期注册的期限？30天内完成注册</p>2024-04-06</li><br/><li><span>aoe</span> 👍（0） 💬（0）<p>coze 使用 2 个 workflows 半自动实现丐版 TQA

1. TQA_1：根据 context、story 进行提问
2. TQA_2：回答 TQA_1 的问题，并将回答手动录入 history，下一轮提问会知道上一轮的问题与答案
3. 重复多次 TQA_2，直到得出解决方案

测试数据

context
作为学校的教职员工，我希望学生可以根据录取通知将学籍注册到教学计划上，从而我可以跟踪他们的获取学位的进度
整个学籍管理系统是一个 Web 应用； 当教职员工发放录取通知时，会同步建立学生的账号；学生可以根据身份信息，查询自己的账号；在报道注册时，学生登录账号，按照录取通知书完成学年的注册；

story
1. 我希望学生可以根据录取通知将学籍注册到教学计划上
2. 作为学生，我希望登录之后接收到注册的通知，从而我可以不会错过学期注册的期限

TQA_2 中经过多轮循环得到了解决方案</p>2024-04-06</li><br/>
</ul>