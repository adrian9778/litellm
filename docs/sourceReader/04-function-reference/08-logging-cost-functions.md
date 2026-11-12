# 函数级解析：日志管线与成本计算

> 所属层级：第四层（源码补齐） | 覆盖：`litellm/litellm_core_utils/litellm_logging.py :: Logging`、`litellm/cost_calculator.py`

## 1. `Logging.__init__()`

```
litellm/litellm_core_utils/litellm_logging.py :: Logging :: +0
litellm/litellm_core_utils/litellm_logging.py :: Logging :: __init__() :: +62
```

`Logging` 类在 `litellm_core_utils/litellm_logging.py` 第 731 行起（`litellm_core_utils/litellm_logging.py :: Logging :: +0`）。

| 项 | 内容 |
|---|---|
| 职责 | 每请求一个的日志引擎构造：收集调用上下文与回调清单 |
| 参数 | `model`、`messages`、`stream`、`call_type`、`start_time`、`litellm_call_id`、`function_id`、`litellm_trace_id`、四类 `dynamic_*_callbacks`、`applied_guardrails`、`kwargs`、`log_raw_request_response`、`supports_correlation_logging`、`raw_request_only` |
| 状态字段 | `self.model`（`+33`）、`self.stream`（`+42`）、`model_call_details: dict`（全程事件流记录）、回调管理器实例 |
| 核心算法 | `+59`：`stream_usage_injected` 标记（防止流式 usage 重复注入）；回调聚合：全局 `litellm.callbacks` + 调用级动态回调 + 环境变量回调，去重后入 `LoggingCallbackManager` |

构造先做消息归一（字符串输入转单条 user 消息、字符串列表逐条转 `{"role":"user","content":m}`），再浅拷贝外层列表（`+37`，内层 dict 共享但日志层不就地改消息）。`trace_id`/`session_id` 从 contextvar 读入（`+57` 至 `+78`），`supports_correlation_logging` 为真且开启请求相关日志时才写回 contextvar（`+68`）；同步 SDK 入口（`utils.wrapper`）不置此开关，避免线程池回收导致 id 串到无关请求。动态回调初始化走 `initialize_standard_callback_dynamic_params`（`+103`）与 `process_dynamic_callbacks`（`+110`）。

## 2. `pre_call()` / `post_call()`

```
litellm/litellm_core_utils/litellm_logging.py :: Logging :: pre_call() :: +970
litellm/litellm_core_utils/litellm_logging.py :: Logging :: post_call() :: +1193
```

| 函数 | 职责 |
|---|---|
| `pre_call` | 广播 `log_pre_api_call` 给同步回调；把输入快照进 `model_call_details` |
| `post_call` | 广播 `log_post_api_call`；记录原始响应骨架 |

## 3. 新增的小方法族

### `set_first_chunk_overhead()`

```
litellm/litellm_core_utils/litellm_logging.py :: Logging :: set_first_chunk_overhead() :: +291
```

把 proxy 处理流式首分片本身耗时（`seconds * 1000` 存 `first_chunk_overhead_ms`，仅当首次未设时写入）记为后续每个分片都继承的固定延迟，供首分片成本 / TTFT 统计扣减。

### `is_usage_explicitly_free()`

```
litellm/litellm_core_utils/litellm_logging.py :: Logging :: is_usage_explicitly_free() :: +1734
```

判定 usage 是否「显式免费」（费率为 0，即 #51093）。先取 `get_usage_object`；无 usage 或已有 cost 失败诊断时返回 `False`。有自定义定价时以 `custom_model_info` / `custom_cost_per_token` 走 `is_explicitly_free_usage`；否则解析定价条目（`pricing_entry_for_cost_calc`），`pricing is None` 返回 `False`，否则对该条目做免费判定。流式路径 `streaming_handler._stamp_usage_cost` 用它决定显式 0 成本是否落账。

### `_carry_parked_success()`

```
litellm/litellm_core_utils/litellm_logging.py :: Logging :: _carry_parked_success() :: +2135
```

Router 因 safeguard 拒绝而回退丢弃的已计费响应，其成功日志被「停靠」（`deferred_success_result`）后，由结束请求的那次 attempt 承接记账，而不是在其位置记一条。`deferred_success_result` 为空或未排队时返回 `False`；清空停靠字段后，若 `served_round` 无 served 结果也返回 `True`；有 served 则把 `served` 追加进 `failed_attempts_usage` 与 `_failed_attempts_owed_on_success`。

### `_model_call_details_with_request_messages()`

```
litellm/litellm_core_utils/litellm_logging.py :: Logging :: _model_call_details_with_request_messages() :: +4403
```

把 `turn_off_message_logging` 原地抹掉的请求消息放回事件负载，供只按请求路由、绝不落日志内容的回调使用。返回 `model_call_details` 的展开副本，其中 `messages` 与 `standard_logging_object["messages"]` 都换回原始 `self.messages`。

## 4. `success_handler()` / `async_success_handler()`

```
litellm/litellm_core_utils/litellm_logging.py :: Logging :: success_handler() :: +3004
litellm/litellm_core_utils/litellm_logging.py :: Logging :: async_success_handler() :: +3522
litellm/litellm_core_utils/litellm_logging.py :: Logging :: _async_success_handler_body() :: +3540
```

| 项 | 内容 |
|---|---|
| 职责 | 成功事件的完整处理：元数据更新 → 成本计算 → 回调广播 |
| 参数 | `result`（ModelResponse/流）、`start_time`、`end_time`、`cache_hit` |
| 前置 | `pre_call` 已执行（`model_call_details` 有输入） |
| 后置 | `_hidden_params["response_cost"]` 已写入；回调已收到标准化事件 |

`async_success_handler` 只做两件事：进 `post_response_phase()` / `outside_mirrored_call()` 上下文调 `_async_success_handler_body`，`finally` 里 `_restore_correlation_context()` 恢复 trace/session contextvar。真正的主体现在 `_async_success_handler_body`（`+3540`）。

`_async_success_handler_body` 的内部顺序：

1. 去重守卫：`+12`：非流式已组装的流或 `should_run_logging("async_success")` 为假则直接返回。
2. batch 短路：`+18` 至 `+77`：`aretrieve_batch` 且 `LiteLLMBatch` 时，无日志的轮询直接返回；有显式 `batch_cost`/`batch_usage`/`batch_models` 直接 `set_hidden_param(result, "response_cost", ...)` 并 `set_cost_breakdown`；否则 `batch_cost_is_final` 时调 `handle_completed_batch` 算费并写回。
3. `+78`：`truncated_messages_for_logging` 做 base64 截断归一。
4. `+84`：`_success_handler_helper_fn(...)` 更新元数据（等同 update_response_metadata 职责），返回归一后的 `start_time/end_time/result`。
5. `+103`：构建完整流式响应（`_get_assembled_streaming_response`）；缓存命中时 `model_call_details["response_cost"] = 0.0`（`+118`），否则 `+124` 调 `self.response_cost_calculator(...)` 算钱，`NotFoundError`/任意异常都降级为 `response_cost = None`。
6. `+166`：`pass_through_endpoint` 走独立分支，仅在未算过时置 cost 为 None 并补标准负载。
7. `+188` 起：合并回调清单（`get_combined_callback_list`）、脱敏（`redact_message_input_output_from_logging`）、logging hook（`async_logging_hook`，一个失败不阻断其余）、`mark_logging_complete("async_success")`，最后逐回调按 `should_run_callback` 过滤后调用 `async_log_success_event`。

流式请求的成功事件延迟到流结束（`CustomStreamWrapper.finish()` 触发），聚合 usage 传入。

## 5. `response_cost_calculator()`

```
litellm/litellm_core_utils/litellm_logging.py :: Logging :: response_cost_calculator() :: +1442
```

| 项 | 内容 |
|---|---|
| 职责 | Logging 侧的成本入口：决定用哪种计价路径 |
| 参数 | `result`、`cache_hit`、`litellm_model_name`、`router_model_id`、`ignore_stamped_cost` |
| 核心算法 | `+16`：`cache_hit` 为真直接返 0.0；`OpenAIStream`/`OpenAIAsyncStream` 返 `None`；`is_unbilled_non_inference_call` 返 0.0；已盖章 `response_cost` 优先复用；`+90` 组装 `response_cost_calculator_kwargs` 递给 `litellm.response_cost_calculator`（`cost_calculator.completion_cost` 的包装） |
| 返回 | `float`（写进 `_hidden_params["response_cost"]`） |

先尝试 `_generate_content_result_as_model_response` 把原生 Google `:generateContent` 的 `usageMetadata` 转成 `ModelResponse`（否则始终记 0）；`batch_cost_is_final` 为假或免记轮询的 batch 返 0.0。`custom_pricing` 为真时才把 `custom_cost_per_token`/`custom_cost_per_second`/`custom_model_info` 传下去，避免自定义价混进表价。

## 6. `failure_handler()` / `async_failure_handler()`

```
litellm/litellm_core_utils/litellm_logging.py :: Logging :: failure_handler() :: +4051
litellm/litellm_core_utils/litellm_logging.py :: Logging :: async_failure_handler() :: +4256
```

| 项 | 内容 |
|---|---|
| 职责 | 失败事件广播（异常对象、traceback 进 `model_call_details`） |
| 参数 | `exception`、`traceback_exception`、`start_time`、`end_time`；同步版多 `for_async_request` |
| 后置 | 失败回调收到标准化异常；Router 的重试层不依赖它（重试决策在异常路径同步做） |

`failure_handler`（`+4051`）是上下文恢复薄壳，主体在 `_failure_handler_body`：`should_run_logging("sync_failure")` 守卫后调 `_failure_handler_helper_fn` 归一时间与元数据，再对 `lunary`/`sentry`/`supabase`/`langfuse`/`traceloop`/`logfire` 等内置回调与 `CustomLogger` 逐个广播 `log_failure_event`，`for_async_request` 且该 logger 的异步失败也会跑时跳过同步钩子。`async_failure_handler`（`+4256`）同样只做上下文包裹。

## 7. `completion_cost()`

```
litellm/cost_calculator.py :: completion_cost() :: +0
litellm/cost_calculator.py :: cost_per_token() :: +0
```

> 路径为 `litellm/cost_calculator.py`（不在 `litellm_core_utils/` 下）。

| 项 | 内容 |
|---|---|
| 职责 | usage × 单价 → 美元成本 |
| 参数 | `completion_response`（带 usage 的响应，可选）、`model`、`custom_llm_provider`、`call_type`、`custom_cost_per_token`、`custom_cost_per_second`、`total_time`、`pricing_provider`、`service_tier`、`data_residency`、`vertex_location`、`base_model` 等 |
| 返回 | `float` |
| 前置 | 能解析出一个有定价的 model 名（`+41` docstring：解析不到就抛，提示用 `litellm.register_model` 注册） |
| 后置 | 无副作用 |

核心算法（`+45` 起）：

1. `+46`：`infer_call_type` 定 call type；`DecisionsResponse` 无 usage 直接 `ValueError`；`pricing_provider` 覆写 `custom_llm_provider`；Responses WebSocket 流日志对象按 service tier 拆分后递归求和。
2. 模型名解析链：`completion_response.model` → `model` 参数 → `base_model`（deployment 的 underlying model）；价格查询 `litellm.model_cost`（启动时从 `model_prices_and_context_window.json` 加载），支持前缀/通配定价条目。
3. token 计价：`prompt_tokens × input_price + completion_tokens × output_price`（cache read/write token 按各自单价）；按秒计价的 provider（视频等）用 `total_time × 单价`。
4. `custom_cost_per_token` 显式覆盖一切表价。
5. 折扣/预算策略在外层（`cost_discount` 等 helper，`litellm_core_utils/cost_discount.py`）叠加。

### 内部新增计价 helper（都在 `litellm/cost_calculator.py`）

| 符号 | 锚点 | 职责 |
|---|---|---|
| `_bedrock_cost_registration` | `cost_calculator.py :: _bedrock_cost_registration() :: +0` | 从 Bedrock 运行时模型注册里取第一个带价条目（#50997） |
| `_served_image_service_tier` | `cost_calculator.py :: _served_image_service_tier() :: +0` | 图像请求从不回传 tier，只能用 provider 上报的 served tier 计价（#51017） |
| `_optional_batch_rate` | `cost_calculator.py :: _optional_batch_rate() :: +0` | 按 token 量查多模态（audio/image/video）批量费率表 |
| `_cached_modality_rate` | `cost_calculator.py :: _cached_modality_rate() :: +0` | 多模态 cache-read 费率：批量率 > 批量 cache-read 率 > 标准费率 > cache-read 率，逐级回退 |
| `_half_price_prompt_cost` | `cost_calculator.py :: _half_price_prompt_cost() :: +0` | 半价 prompt 成本：cache-creation 与 cache-read 按单价减半，多模态按 `_batch_or_half` 回退 |

## 8. OTel 目的地 metadata keys（归属澄清）

`litellm_logging.py` 不持有这些键。OTel v2 目的地的 metadata keys 全部在 `litellm/integrations/otel/model/` 下：

```
litellm/integrations/otel/model/baggage.py :: parse_destination_metadata_keys() :: +0
litellm/integrations/otel/model/baggage.py :: MAX_DESTINATION_METADATA_KEYS :: +0
litellm/integrations/otel/model/destination.py :: <metadata_keys 字段> :: +0
```

`baggage.py` 是 baggage 唯一定义处：`_PROMOTABLE`（`+32`）映射可提级的代理身份键，`DEFAULT_BAGGAGE_METADATA_KEYS`（`+58`）为默认提级子集，`parse_destination_metadata_keys`（`+106`）把目的地 `baggage_metadata_keys` 解析成键元组，超 `MAX_DESTINATION_METADATA_KEYS`（= 20，`+79`）或命中保留键 / 请求头即判非法。`destination.py` 的 `metadata_keys` 字段（`+64`）是目的地配置项，在全局 `baggage_metadata_keys` 之上追加该目的地专属 span 元数据键。

## 9. 设计要点

**要点 1：回调失败隔离。** `LoggingCallbackManager`（`litellm_core_utils/logging_callback_manager.py :: LoggingCallbackManager :: +0`）逐个 try/except 调用回调并打日志，一个回调崩溃不影响其余回调与主请求。

**要点 2：`model_call_details` 是单一事实源。** pre_call 输入、原始响应、耗时、成本全部累加进这个 dict，任何回调要上下文都从这拿。

**要点 3：同步/异步双轨。** 同步 `success_handler` 服务纯 SDK 用户；Proxy 走 `async_success_handler`。两轨共享同一套 helper（元数据更新、成本计算）。