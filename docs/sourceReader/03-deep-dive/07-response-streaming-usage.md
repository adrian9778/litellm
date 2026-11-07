# 响应回传、流式与 usage 统计

> 所属层级：第三层（主链路拆解） | 拆解对象：第二层场景的跳 11（含流式分支）

## 本篇回答的问题

响应怎么变回客户端期望的形状？流式请求的 chunk 流怎么统一？usage 什么时候算、算几次？

## 非流式（本场景）

响应沿原链路返回后，`_process_llm_request` 的收尾段（`common_request_processing.py :: ProxyBaseLLMRequestProcessing :: _process_llm_request() :: +95 附近`）做四件事：

```
1. 从 response._hidden_params 取 cache_key / api_base / response_cost
2. data["deployment"] = llm_router.registry().deployment(model_id)   # 记录命中部署
3. 更新请求状态为 success（asyncio.create_task）
4. 组响应头（x-litellm-*）→ 返回 JSON
```

`usage` 字段此时已经就位——它由执行器的 `transform_response` 从 provider 响应原文填进 `ModelResponse`，不是事后统计。

响应头组装在 `ProxyBaseLLMRequestProcessing :: get_custom_headers() :: +0`，核心键值：

| 头 | 值来源 |
|---|---|
| `x-litellm-call-id` | `data["litellm_call_id"]` |
| `x-litellm-model-id` | 命中部署的唯一 id（`_hidden_params`） |
| `x-litellm-response-cost` | `_hidden_params["response_cost"]` |
| `x-litellm-response-cost-*`（original/discount） | 成本拆解（折扣场景） |

## 流式分支

判断入口：`_process_llm_request() :: _is_streaming_request(...)`（请求声明了 `stream=True` 或响应是流包装器）。流式路径返回的不是 dict 而是 `StreamingResponse`（SSE）：

```
litellm/proxy/common_request_processing.py :: select_data_generator 调用段
litellm/proxy/common_request_processing.py :: _UpstreamClosingStreamingResponse :: +1103
```

### CustomStreamWrapper：流的统一包装器

```
litellm/litellm_core_utils/streaming_handler.py :: CustomStreamWrapper :: +397
```

所有 provider 的流（OpenAI SDK 流、httpx 流、Anthropic 流）都被它包一层，职责：

| 职责 | 实现锚点（相对类） |
|---|---|
| chunk 格式统一成 OpenAI `ModelResponseStream` | `chunk_creator() :: +1389` |
| usage 聚合（累加各 chunk usage） | `set_final_usage / finalize` 段 |
| `include_usage` 门控 | `check_send_stream_usage() :: +259` |
| 时间统计（TTFT 等） | `__anext__` 计时段（`+2519`） |
| 断流保护、finish_reason 传播 | 迭代器尾部处理 |

注意一个关键语义（`streaming_handler.py :: +2228 附近的 docstring`）：**网关内部总是聚合完整 usage 用于记账**，`stream_options.include_usage` 只控制客户端看得到什么。

### 流式请求的记账时序

非流式：响应回来 → 算钱 → 回调。流式：

```
SSE 全部 chunk 发完（或客户端断开）
→ finish() 聚合出最终 usage
→ 触发 success 事件（带聚合 usage）
→ completion_cost() 照常算钱
```

客户端中途断开时走 `_dispatch_disconnect_billing_event`（`common_request_processing.py :: _dispatch_disconnect_billing_event() :: +0`），按已收到的部分计费，保证「断开也记账」。

### Proxy 层的流式响应

`_process_llm_request` 流式分支把 `response` 包成 SSE 生成器（`StreamingResponse`），并处理：

- 响应头随首个 chunk 确定部署后刷新（`refresh_stream_headers` 内嵌函数）
- guardrail 需要检查完整输出时，用「延迟分发」模式（`_arm_deferred_stream_dispatch`）：先放行给客户端，后台聚合完整文本做后置审查
- SSE keepalive：`base_process_llm_request` 的 `open_sse_before_first_byte` 在首字节前发 ping，防上游 TTFT 过长导致空闲断连

## usage 的三种来源

| 场景 | usage 从哪来 |
|---|---|
| 非流式 | provider 响应原文的 usage 字段（`transform_response` 直填） |
| 流式 | `CustomStreamWrapper` 聚合；provider 不回 usage 时按 tokenizer 估算（`litellm_core_utils/token_counter.py`） |
| 缓存命中 | 不重新计费，计费逻辑跳过（cost 记 0 或按缓存计价） |

## 响应元数据的暗道

`_hidden_params` 是响应对象的私有属性区（`litellm/types/utils.py` 的 `HiddenParams`），贯穿全链路携带网关内部数据：

```
写入方：执行器（api_base、model_id）、成本层（response_cost）、缓存层（cache_key）
读取方：Proxy 响应头组装、`_process_llm_request` 收尾
边界：模型序列化响应时被 exclude，客户端永远看不到
```

这正是「响应先回客户端、记账异步做」能成立的原因——同步阶段只读 `_hidden_params`，重活全在后台任务。

## 与下一跳的交接

到这里，客户端已拿到响应。还没发生的：成本计算细节、回调怎么被驱动、spend 怎么落库。这就是下一篇。
