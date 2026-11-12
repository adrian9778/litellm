# 响应回传、流式与 usage 统计

> 所属层级：第三层（主链路拆解） | 拆解对象：第二层场景的跳 11（含流式分支）

## 本篇回答的问题

响应怎么变回客户端期望的形状？流式请求的 chunk 流怎么统一？usage 什么时候算、算几次？

## 非流式（本场景）

响应沿原链路返回后，`_process_llm_request` 的收尾段（`common_request_processing.py :: ProxyBaseLLMRequestProcessing :: _process_llm_request() :: +269` 附近，即命中「到达这里仍未被流式早退路由消费」时的常规收尾）做四件事：

```
1. 从 response._hidden_params 取 cache_key / api_base / response_cost
2. 计算模型 id 后组响应头（x-litellm-*）
3. 调用 prepare_response_cost / finalize_proxy_response_cost 把成本定案并写进 model_call_details
4. 触发 post_call_success_hook，按 _hidden_params 组响应 JSON
```

`usage` 字段此时已经就位——它由执行器的 `transform_response` 从 provider 响应原文填进 `ModelResponse`，不是事后统计。成本定案路径在 `litellm/proxy/spend_tracking/cost_finalization.py :: prepare_response_cost() :: +0` 与 `finalize_proxy_response_cost() :: +0`，前者在非流式分支被收尾段显式调用，把 `completion_cost` 结果落进 `logging_obj.prepared_cost`。

响应头组装在 `common_request_processing.py :: ProxyBaseLLMRequestProcessing :: get_custom_headers() :: +0`，核心键值：

| 头 | 值来源 |
|---|---|
| `x-litellm-call-id` | `data["litellm_call_id"]` |
| `x-litellm-model-id` | 命中部署的唯一 id（`_hidden_params`） |
| `x-litellm-response-cost` | `_hidden_params["response_cost"]` |
| `x-litellm-response-cost-*`（original/discount） | 成本拆解（折扣场景） |

## 流式分支

判断入口：`_process_llm_request()` 的 `_is_streaming_request(...)` 与 `_is_streaming_response(...)`（请求声明了 `stream=True` 或响应是流包装器）。流式路径返回的不是 dict 而是 `create_response` 组装的 SSE `StreamingResponse`（`common_request_processing.py :: create_response() :: +0`）：

```
litellm/proxy/common_request_processing.py :: create_response 调用段
litellm/proxy/common_request_processing.py :: _UpstreamClosingStreamingResponse :: +0
```

`create_response`（`+1479` 附近，`+0` 处起 20 多行即调用 `open_sse_before_first_byte`）把生成器包成上游关闭自同步的 SSE 响应，并传入 `refresh_headers` 内嵌函数在首个 chunk 确定部署后刷新响应头。

### CustomStreamWrapper：流的统一包装器

```
litellm/litellm_core_utils/streaming_handler.py :: CustomStreamWrapper :: +0
```

`CustomStreamWrapper`（类定义在 457 行，类内偏移全部以它为准）无任何类/方法改名搬家，所有 provider 的流（OpenAI SDK 流、httpx 流、Anthropic 流）都被它包一层，职责：

| 职责 | 实现锚点（相对类） |
|---|---|
| chunk 格式统一成 OpenAI `ModelResponseStream` | `chunk_creator() :: +0` |
| usage 聚合（累加各 chunk usage） | `calculate_total_usage()`（模块级，3126 起） |
| `include_usage` 门控 | `check_send_stream_usage() :: +0` |
| 时间统计（TTFT 等） | `__anext__` 计时段 |
| 断流保护、finish_reason 传播 | 迭代器尾部处理（`finish_reason_handler() :: +0`） |
| 首 chunk 的 proxy 自身开销（后续 chunk 继承） | `set_first_chunk_overhead`（`litellm_logging.py :: Logging :: set_first_chunk_overhead() :: +0`，见第 8 篇） |

注意一个关键语义（`streaming_handler.py :: _record_usage_only_chunk() :: +0` 的 docstring）：**网关内部总是聚合完整 usage 用于记账**，`stream_options.include_usage` 只控制客户端看得到什么。providers 回传的 usage-only chunk（如 OpenRouter 的 post-finish chunk）被 `_record_usage_only_chunk` 收进 `self.chunks` 供成本层读取，但绝不回传给调用方。

### 显式免费费率的落账

流式末尾 `_finalize_completed_stream`（`CustomStreamWrapper :: _finalize_completed_stream() :: +0`）组装出完整流式响应后调用模块级 `_stamp_usage_cost`（`streaming_handler.py :: _stamp_usage_cost() :: +0`）。它在 `bill == 0` 且完整响应的 `usage.cost == 0` 时也照样给最终 usage chunk 盖上 `litellm_bill`，配合 `Logging.is_usage_explicitly_free`（`litellm_logging.py :: Logging :: is_usage_explicitly_free() :: +0`）把显式免费费率（#51093）也落账，避免「cost=0 的免费调用」被当成「没算钱」而漏掉记账。

### 流式请求的记账时序

非流式：响应回来 → 算钱 → 回调。流式：

```
SSE 全部 chunk 发完（或客户端断开）
→ _finalize_completed_stream() 聚合出最终 usage
→ dispatch_success_handlers 触发 success 事件（带聚合 usage）
→ async_success_handler 里 completion_cost() 照常算钱
→ 走第 8 篇的 _ProxyDBLogger 落账
```

客户端中途断开时走 `_dispatch_disconnect_billing_event`（`common_request_processing.py :: _dispatch_disconnect_billing_event() :: +0`）：先检查是否已有自然 end-of-stream 事件（有则跳过不再记），否则用 `stream_chunk_builder` 把已收到的 chunks 组装出部分响应，按已收到的部分计费，保证「断开也记账」。

### Proxy 层的流式响应

`_process_llm_request` 流式分支把 `response` 包成 SSE 生成器（`create_response` 组装 `StreamingResponse`），并处理：

- 响应头随首个 chunk 确定部署后刷新（`refresh_stream_headers` 内嵌函数）
- guardrail 需要检查完整输出时，用「延迟分发」模式（`_arm_deferred_stream_dispatch()` :: +0）：先放行给客户端，后台聚合完整文本做后置审查
- SSE keepalive：`open_sse_before_first_byte`（`common_request_processing.py :: open_sse_before_first_byte() :: +0`）在首字节前发 `: ping` 注释，防上游 TTFT 过长导致空闲断连（AWS ALB/nginx 默认 60s 读超时）。一旦 ping 已发出而后续又发生 guardrail 拦截，走 `on_passthrough_block`（`common_request_processing.py :: _late_block_or_failure() :: +0`）把 guardrail 构造的拦截流以 SSE 帧中继给客户端（#51114），而不是断开连接。

## usage 的三种来源

| 场景 | usage 从哪来 |
|---|---|
| 非流式 | provider 响应原文的 usage 字段（`transform_response` 直填） |
| 流式 | `CustomStreamWrapper` 聚合；provider 不回 usage 时按 tokenizer 估算（`litellm/litellm_core_utils/token_counter.py`） |
| 缓存命中 | 不重新计费，计费逻辑跳过（cost 记 0 或按缓存计价） |

## 响应元数据的暗道

`_hidden_params` 是响应对象的私有属性区（`litellm/types/utils.py` 的 `HiddenParams`），贯穿全链路携带网关内部数据：

```
写入方：执行器（api_base、model_id）、成本层（response_cost）、缓存层（cache_key）
读取方：Proxy 响应头组装、_process_llm_request 收尾、成本定案（prepare_response_cost 从它读 response_cost）
边界：模型序列化响应时被 exclude，客户端永远看不到
```

这正是「响应先回客户端、记账异步做」能成立的原因——同步阶段只读 `_hidden_params`，重活全在后台任务。

## 与下一跳的交接

到这里，客户端已拿到响应。还没发生的：成本计算细节、回调怎么被驱动、spend 怎么落库。这就是下一篇。

补充一个归属澄清：reasoning item id 的稳定化（#51243）不在 `CustomStreamWrapper`，而是分散在 `litellm/responses/`（`streaming_iterator.py :: BaseResponsesAPIStreamingIterator`、`utils.py :: ResponsesAPIRequestUtils :: affinity_item_id() :: +0`）与 Rust `litellm-rust/crates/inference-responses/src/ids.rs`（`encitem_` 前缀 + 加密内容亲和）。responses 流的统一与计费在第四层第 10 篇（`04-function-reference/10-streaming-functions.md`）单独覆盖。