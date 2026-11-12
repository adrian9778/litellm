# 函数级解析：Proxy 入口与请求处理

> 所属层级：第四层（源码补齐） | 覆盖：`proxy_server.py` 端点函数、`common_request_processing.py` 主处理类

引用规范：`文件 :: 类 :: 函数 :: +偏移`，`+0` 为定义行。本篇所有偏移已回代码核对（基线 `0608a41a07`）。

## 1. `chat_completion()`

```
litellm/proxy/proxy_server.py :: chat_completion() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | `/v1/chat/completions` 等 4 个路径的统一端点；读 body、注入身份、委托处理、异常转 HTTP |
| 参数 | `request: Request`、`fastapi_response: Response`、`model: str \| None`（路径参数）、`user_api_key_dict: UserAPIKeyAuth`（Depends 注入） |
| 返回 | `ModelResponse` 序列化后的 JSON dict，或 `StreamingResponse`，或 `ProxyException` |
| 前置 | `user_api_key_auth` 已通过（装饰器依赖），`llm_router` 已初始化 |
| 后置 | 日志/记账事件已异步发出（不阻塞返回） |

核心算法（按行序）：

1. `+31`：`data = await read_request_body(request=request)`，失败转 `ProxyException`
2. `+32` 至 `+48`：metadata 归一与身份注入（键名见第三层第 1 篇的表）；若 `data.get("metadata")` 不是 dict（缺失或 JSON 字符串，见 `+34` 注释）先置 `{}`，避免下方对字符串下标赋值 500
3. `+50`：构造 `ProxyBaseLLMRequestProcessing(data=data)`
4. `+51` 至 `+70`：`base_process_llm_request(route_type="acompletion", ...)`，传入全局 `proxy_logging_obj`、`llm_router`、`proxy_config`、`general_settings`、`select_data_generator`，以及 `on_passthrough_block=lambda block: _stream_chat_passthrough_block(block, user_api_key_dict, request)`（guardrail 阻断走流式通道）
5. 返回分支（`+71`）：`isinstance(result, BaseModel)` → `model_dump_with_preserved_fields(result, exclude_unset=True)`，否则原样返回

错误处理（`+75` 起的 except 链）：

| 异常 | 处理 |
|---|---|
| `ModifyResponseException` | 流式则转 SSE 单片（`_stream_chat_passthrough_block`）；否则 `_record_passthrough_block` 留痕后 `_passthrough_block_response` 组装 `content_filter` 响应 |
| `RejectedRequestError` | 先走 `post_call_failure_hook` 留痕，再返回携带错误消息的 `ModelResponse`（流式时包 `ModelResponseIterator` + `CustomStreamWrapper`） |
| `Exception` | `base_llm_response_processor.handle_llm_api_exception(...)`（`common_request_processing.py :: ProxyBaseLLMRequestProcessing :: handle_llm_api_exception() :: +0`）统一映射成 `ProxyException` 语义（400/429/500 等） |

并发：本函数本身无共享状态写；后台任务（状态更新、记账）用 `asyncio.create_task` 发射后不管。

## 2. `ProxyBaseLLMRequestProcessing.__init__()`

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: __init__() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 每请求实例，持有请求数据与处理状态 |
| 参数 | `data: dict`（OpenAI 风格请求体）、`served_model: str \| None`（通配模型解析后的实际模型） |
| 状态字段 | `self.data`、`self.served_model`、`self._tags_before_guardrails`（guardrail 改写 tags 前的快照，用于预算校验一致性）、`self.route_type`（`+6`，初次为 None，pre-call 时赋值） |
| 后置 | 实例就绪，等待 `base_process_llm_request` 调用 |

`__init__` 后随附 `litellm_call_id` property（`+8`，回读 `data` 里的 `litellm_call_id`）与静态 `_merge_passthrough_streaming_headers`（`+12`，合并 upstream 流式头并剔除 `transfer-encoding`/`set-cookie` 等 Hop-by-Hop 头，proxy 头优先）。

## 3. `base_process_llm_request()`

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: base_process_llm_request() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 处理骨架的外壳：包 `total_timeout` 与 SSE keepalive，迟到的失败只能审计 |
| 参数 | `request`、`fastapi_response`、`user_api_key_dict`、`route_type: ProxyRouteType`、`proxy_logging_obj`、`general_settings`、`proxy_config`、`select_data_generator`、`llm_router`、`model`、`user_model`、`user_*` 全局配置族、`is_streaming_request`、`contents`、`skip_pre_call_logic`、`sse_framing`、`on_passthrough_block` |
| 返回 | 委托处理的结果（响应或流） |
| 前置 | `data` 已注入 metadata |
| 后置 | 若 keepalive 已上线，失败只能审计不能改状态码（见 `_audit_late_failure` 内嵌函数 `+33`） |

核心算法：

- `+31`：`answers_as_anthropic = route_type == "anthropic_messages"`，决定迟到失败的错误帧格式
- `+33`：内嵌 `_audit_late_failure`——一旦 keepalive 上线，调用方自己的 `except` 不再执行 `post_call_failure_hook`，因此由这里补上（anthropic 路由用 `with_answered_status` 包异常）
- `+43`：`return await open_sse_before_first_byte( self._within_total_timeout(...), ping_interval_seconds=ttft_keepalive_interval(self.data, llm_router), on_late_failure=_audit_late_failure, late_framing=ANTHROPIC_LATE_SSE_FRAMING if answers_as_anthropic else sse_framing.late, on_passthrough_block=on_passthrough_block )`
- 中间的 `self._within_total_timeout(...)`（`+43` 内）包住整段 `_process_llm_request`：**total_timeout 在最外层、SSE keepalive 在其外**，即超时终止的是整个处理协程，keepalive 只在超时未触发且 upstream 首字节迟到时才上线

## 4. `_within_total_timeout()` 与 `total_timeout_for()`

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: total_timeout_for() :: +0
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: _within_total_timeout() :: +0
```

`base_process_llm_request` 把 `_process_llm_request` 交给 `_within_total_timeout`（`+105`，即 3280 行）夹住，后者再委托 SSE keepalive。

`_within_total_timeout` 核心：

1. `+1`：调 `total_timeout_for(request, route_type, is_streaming_request)`（`+77`，即 3252 行）解析 `total_timeout`；body 键 `total_timeout`（`_REQUEST_FIELDS` 校验）或请求头 `x-litellm-total-timeout`（`TOTAL_TIMEOUT_HEADER`）均可携带
2. `+77` 的 `total_timeout_for`：`route_type in _TOTAL_TIMEOUT_ROUTE_TYPES`（`{"acompletion","aresponses","anthropic_messages"}`，模块级 607 行）**且** 非流式 且 `bounded_by_total_timeout(body)` 才被视为「夹得住」；body 键只对可夹的请求生效，否则抛 `_total_timeout_refused`（400）；header 键在不可夹时静默忽略（`+89` 注释）并返回 None
3. `+15`：若 `total_timeout` 为 None（未配置或不可夹），直接 `return await processing`
4. `+17` 起：`async with total_deadline(total_timeout.seconds, from_body=...)`（`litellm_core_utils/total_deadline.py :: total_deadline() :: +0`）夹住处理；超时抛 `TotalTimeoutExpired` → 转为 `ProxyException(message=..., type="timeout", param=..., code=408)`（**408 语义**）；`TotalTimeoutNotApplicable`（如流式请求的 body total_timeout 传给只夹非流式的 scope）→ `_total_timeout_refused`（400）

`base_process_llm_request` 调用 `_within_total_timeout` 之前，`total_timeout_for` 已经用 `self.data.pop(TOTAL_TIMEOUT_FIELD, None)`（`total_timeout_for` 内）把 body 里的 `total_timeout` 从 data 剥离，避免它作为未知参数漏给 SDK。

## 5. `_process_llm_request()`

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: _process_llm_request() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 主链路真正骨架：pre-call → 并行路由与 moderation → 执行 → 收尾 → 响应头 |
| 返回 | 响应对象或 `StreamingResponse` |
| 前置 | `user_api_key_dict` 有效；`llm_router` 可为 None（无 model_list 时直连 SDK） |
| 后置 | 成功时响应头已组装；spend 写入已发出 |

核心算法（三段）：

**段一 pre-call（`+26` 至 `+60`）**：
- `+26`：`client_model = get_client_requested_model(request) or self.data.get("model")`，记为 `requested_model_from_client`（用于下游把响应 `model` 字段还原为客户端原始名）
- `+30`：`skip_pre_call_logic=True` 时从 data 取现成的 `litellm_logging_obj`（没有就 `ValueError`，避免静默丢日志）
- `+43` 至 `+59`：否则 `self.data, logging_obj = await self._pre_call_with_fallbacks(...)`，随后 `+60` 发 `phase_event("litellm.request.pre_call_completed")`

**段二 执行（`+84` 至 `+111`）**：
```python
# +86
llm_call: Final = await route_request(
    data=self.data, route_type=route_type, llm_router=llm_router,
    user_model=user_model, user_api_key_dict=user_api_key_dict,
)   # route_request 调用点 = 3302 + 86 = 3388 行
llm_call_task: Final = asyncio.create_task(with_proxy_compaction_executor(llm_call, request))   # +93
```
- `+69`：`during_call_hook`（moderation）作为独立 task 先行发射，与 LLM 调用并行（`asyncio.gather`，`+97`）
- `+102`：`cancel_on_disconnect` 配置时用 `_await_llm_call_cancelling_on_disconnect` 等待，否则直接 `await llm_responses`
- `+106`：`asyncio.CancelledError` 时若 `_total_timeout_expired()` 真，则 `_cost_a_call_answered_past_its_total_timeout` 补计「超时后已产生的成本」
- `+110`：`finally` 里 `_cancel_pending_gather_tasks(tasks)` 清理未完成 task

**段三 收尾（`+113` 起）**：
1. `+117`：从 `_hidden_params` 取 `cache_key`/`api_base`/`response_cost`/`fastest_response_batch_completion`/`additional_headers`
2. `+131`：`data["deployment"] = llm_router.registry().deployment(model_id)` 记录命中部署
3. 流式判断（`+139`）：`_is_streaming_request(...) or _is_streaming_response(response)` → SSE 分支（`_stream_response_headers` 组头、`_arm_deferred_stream_dispatch` 延迟 guardrail、`refresh_stream_headers` 回读 fallback 后换部署的头）；`anthropic_messages` 专用 `async_sse_data_generator` + `wrap_sse_stream_with_keepalive_pings`；`allm_passthrough_route` 直透 upstream 字节
4. 非流式（`+3639+...`）：`post_call_success_hook`（可改写响应）→ `prepare_response_cost` → `get_custom_headers` 更新 `fastapi_response.headers` → `_override_openai_response_model` 还原客户端 model → `post_call_response_headers_hook`

错误处理：外层 `except (Exception, asyncio.CancelledError)`（`+3639` 起）在 `logging_obj.prepared_cost` 已备时用 `anyio.CancelScope(shield=True)` 强制落成本（`finalize_proxy_response_cost`），随后 re-raise；`finally` 里 `_flush_deferred_async_logging` 与「孤儿流 closure」清理（`+50` 起）。

## 6. `_pre_call_with_fallbacks()`

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: _pre_call_with_fallbacks() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 包一层异常处理的 pre-call：任何 pre-call 异常也触发 `post_call_failure_hook`，并支持 per-model 限流回退 |
| 返回 | `(data, logging_obj)` 二元组 |
| 核心算法 | `+30` 判定 per-model 硬限流（`PER_MODEL_RATE_LIMIT_DESCRIPTOR_KEYS` 且禁用回退）；`+36` 取 `_configured_fallbacks`；`+41` 有回退时 `independent_snapshot(self.data)` 备份原始体；`+43` try: `common_processing_pre_call_logic(...)`；except: 记录失败 → re-raise |
| 并发 | 无 |

## 7. `common_processing_pre_call_logic()`

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: common_processing_pre_call_logic() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 鉴权后的全部请求加工：注入、配置合并、Logging 构建、hook 执行 |
| 参数 | `request`、`general_settings`、`proxy_logging_obj`、`user_api_key_dict`、`route_type`、`proxy_config`、`llm_router`、`user_model` 等 |
| 返回 | `self.data, logging_obj`——函数尾部 `+324` 的 `return self.data, logging_obj`（即 2569 + 324 = 2893 行）；调用方按 `self.data, logging_obj = await self._pre_call_with_fallbacks(...)` 解包 |
| 前置 | `self.data` 已含 metadata |
| 后置 | `data["litellm_logging_obj"]` 就位；限流已扣减（hook 内） |

执行序（相对偏移，部分摘自第三层第 3 篇的表）：

| 偏移 | 动作 |
|---|---|
| `+113` | `start_time = datetime.now()`，先于 guardrail hook 计时 |
| `+118` | `model` 必须是字符串，否则 400 |
| `+123` | `await add_litellm_data_to_request(...)`（`litellm_pre_call_utils.py`），注入请求级数据 |
| `+141` | 未开 `expose_fallback_errors_to_caller` 时剥掉 `include_fallback_errors` |
| `+169` | `model` 为字符串时 `reject_url_valued_destination` 拒 URL 值 |
| `+171` | `resolve_inference_model` 按 `user_model`/`model` 归并 |
| `+194` | `global_then_key_alias_target(prepared_model, user_api_key_dict)`——全局 `model_alias_map` 后再 key 级别名 |
| `+198` 起 | `hierarchical_router_settings_updates`（router 级 alias 映射）、`priority_header_fields`（`x-litellm-priority`） |
| `+216` | `litellm_call_id = resolve_litellm_call_id(request.headers.get("x-litellm-call-id"))` → 写回 data 并 `bind_telemetry_call_id` / `DDSpanTagger` |
| `+243` | `function_setup(...)` 建 `logging_obj` 并写回 `self.data["litellm_logging_obj"]`（后续所有层从 kwargs 拿它） |
| `+268` | `check_and_merge_model_level_guardrails`（合并 DB/UI 配置的模型级 guardrail） |
| `+278` | `_arm_auto_router_compression` |
| `+280` | `self._tags_before_guardrails` 快照（若未快照）→ `RoutingContext(llm_router).arm_read_prefetch` → `pre_call_hook(...)` |
| `+291` | `_enforce_guardrail_added_tag_budgets` |
| `+309` | `refresh_proxy_server_request_body_snapshot(self.data, guardrails_applied=True)`——**pre_call_hook 之后**刷新，保证 body 快照反映 guardrail（如 Presidio）改写后的真实发送内容 |
| `+312` | `logging_obj.update_messages(self.data["messages"])` |
| `+321` | served_model 场景 `llm_router.registry().resolve(aliased_model, kind="served", served_model=self.served_model)` |
| `+324`（函数尾部） | `return self.data, logging_obj` |

两个易错点：

- `function_setup` 返回的 logging_obj 会同时写回 `self.data["litellm_logging_obj"]`，后续所有层从 kwargs 里拿它
- guardrail（如 Presidio）可能改写 `messages`，所以 messages 刷新在 pre_call_hook 之后（`+309`），保证日志与实际发送内容一致

## 8. `get_custom_headers()`

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: get_custom_headers() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 组装 `x-litellm-*` 响应头 |
| 参数 | `user_api_key_dict`、`call_id`、`model_id`、`cache_key`、`api_base`、`version`、`model_region`、`response_cost`、`hidden_params`、`fastest_response_batch_completion`、`request_data`、`timeout`、`litellm_logging_obj`、`read_timing_from_logging_obj`、`**kwargs`（全关键字参数） |
| 返回 | `dict[str, str]` |
| 核心算法 | 值解析链：显式参数 → `hidden_params` → `request_data` → logging_obj 计时（`read_timing_from_logging_obj` 控制）；头字典组装见下；空值统一剔除（`+93`，`exclude_values = {"", None, "None"}`），且最终只保留 `_encodes_as_latin1` 的头（`+98`） |
| 后置 | 头在 `litellm/constants.py` 常量约束下（如 `x-litellm-response-cost`，`common_request_processing.py :: cost_headers() :: +0` 的字面量） |

组装清单（`+46` 起的字典字面量）：

- `+47`：`x-litellm-call-id`（`resolved_call_id`，取值优先级 call_id → `hidden_params.litellm_call_id` → `request_data.litellm_call_id`）
- `+48` 至 `+55`：`x-litellm-model-id`/`x-litellm-model-name`/`x-litellm-cache-key`/`x-litellm-model-api-base`（去 query 防泄露）/`x-litellm-version`/`x-litellm-model-region`
- `+56`：`**cost_headers(response_cost, litellm_logging_obj)`（见下节）
- `+57`：`x-litellm-classifier-cost`
- `+58` 至 `+61`：`x-litellm-key-tpm-limit`/`x-litellm-key-rpm-limit`/`x-litellm-key-max-budget`/`x-litellm-key-spend`（`updated_spend` = 当前 spend + 本次 response_cost，`+31` 起）
- `+62` 至 `+64`：`x-litellm-response-duration-ms`/`x-litellm-overhead-duration-ms`/`x-litellm-callback-duration-ms`
- `+65` 起：`LITELLM_DETAILED_TIMING` 为真时补 `x-litellm-timing-*` 一组；`+75` `x-litellm-fastest_response_batch_completion`；`+78` `x-litellm-timeout`；`+79` `**kwargs` 兜底
- `+81` 起：`request_data` 存在时追加 `get_remaining_tokens_and_requests_from_request_data`（限流余量）、`rate_limit_fallback_headers`、`get_logging_caching_headers`

## 9. `cost_headers()`

```
litellm/proxy/common_request_processing.py :: cost_headers() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 组装 `x-litellm-response-cost-*` 一组成本头 |
| 参数 | `response_cost: float \| str \| None`、`litellm_logging_obj: LiteLLMLoggingObj \| None` |
| 返回 | `Mapping[str, str \| None]` |
| 核心算法 | `+4`：`response_cost == 0` 且 logging 对象已备 `prepared_cost` 且 `price_known` 为假（即显式免费费率、无已知单价）→ 返回 `{}`（不写零成本头）；否则 `_get_cost_breakdown_from_logging_obj` 拆成本明细后展开 |
| 明细键（`+14` 起） | `x-litellm-response-cost` / `-original` / `-discount-amount` / `-margin-amount` / `-margin-percent` / `-input` / `-output` / `-cache-read` / `-cache-creation` / `-reasoning` / `-tool-usage` |

## 10. `read_request_body()`

```
litellm/proxy/common_utils/http_parsing_utils.py :: read_request_body() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 容错读 body 并解析为 dict |
| 参数 | `request: Request \| None` |
| 返回 | `dict`（解析失败/空 body → `{}`，不抛） |
| 核心算法 | 分支树见第三层第 1 篇；关键是解析结果缓存在 `request.scope["parsed_body"]`（`_safe_get_request_parsed_body()`，436 行），或 json + pydantic `TypeAdapter` 校验 + surrogate 修复重试 |
| 错误处理 | JSONDecodeError → 修复重试；表单 metadata 为 JSON 字符串 → 二次解析 |

## 11. `open_sse_before_first_byte()`

```
litellm/proxy/common_request_processing.py :: open_sse_before_first_byte() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 上游首字节前的 SSE 保活包装 |
| 参数 | `produce_response`（内层协程）、`ping_interval_seconds`（None 则不包装）、`media_type`、`on_late_failure`、`late_framing`、`on_passthrough_block` |
| 返回 | 响应或已开始发送的 SSE 流 |
| 核心算法 | `+9`：`coerce_keepalive_interval` 为 None → 原样 await 内层；`+16` 起用 `asyncio.wait((produce_task,), timeout=interval)` 竞速——上游在一个 interval 内答完走快速路径（`+19`，字节等价于未包装）；否则 `+24` 的 `keepalive_then_relay` 生成器上线，循环 `yield SSE_COMMENT_PING_BYTES` + wait，直到 upstream 出结果或异常 |
| 并发 | 内部用 `asyncio` 任务管理 ping 与主协程；`finally`（`+49`）里若 produce 未 done 则 cancel，若已 done 则 `_aclose_late_response` 关闭没被消费的流 |
| 后置 | 一旦首 ping 上线，失败只能以 SSE 错误帧（`late_framing.failure(...)`）发出，HTTP 状态码已无法修改；`on_late_failure` 负责审计（见第 3 节 `_audit_late_failure`） |

## 本篇覆盖之外的端点

`proxy_server.py` 里 embeddings/responses/messages 等端点与 `chat_completion` 同构（读 body → 构造 `ProxyBaseLLMRequestProcessing` → `base_process_llm_request(route_type=...)`），差异只在 `route_type` 与少量端点特有逻辑（如 `completion` 端点用 `atext_completion` 且 `data` 先构造空 dict 再二次 read，见 13560 行附近），不再重复展开。

## 行为变化速览（相对上一基线 `3f4dc93b40`）

- **total_timeout 包夹**：`base_process_llm_request` 现在把 `_process_llm_request` 交给 `_within_total_timeout`（`common_request_processing.py :: ProxyBaseLLMRequestProcessing :: _within_total_timeout() :: +0`）夹住，再交给 `open_sse_before_first_byte`；非流式 `acompletion`/`aresponses`/`anthropic_messages` 超时 → 408 `ProxyException`。body 键 `total_timeout` 或头 `x-litellm-total-timeout` 均可（`common_request_processing.py :: ProxyBaseLLMRequestProcessing :: total_timeout_for() :: +0`）
- **缺 role 消息改抛 400**：`litellm/utils.py :: validate_and_fix_openai_messages()`（`utils.py` 9496 行）→ `validate_chat_completion_user_messages`（`utils.py` 9573 行）对无 role 消息抛 `MissingMessageRoleError`（`exceptions.py :: MissingMessageRoleError :: +0`，`MalformedRequestFieldError`/`BadRequestError` 子类，HTTP 400），不再自动补 role（`#51124` BREAKING）
- **`x-litellm-call-id` 响应头**：`get_custom_headers` 现始终写 `x-litellm-call-id`（`+47`），错误响应头与 `token_counter` 端点也回（`token_count_log.py :: answered_with_litellm_call_id()` 143 行）
- **budget 不可验证 503**：`fail_closed_budget_enforcement` 开启且 spend 无法对账时 `_raise_budget_unverifiable`（`proxy_server.py :: _raise_budget_unverifiable() :: +0`）抛 503
- **`cost_headers` 显式免费费率**：cost=0 且 `price_known=False`（显式免费）时不再写零成本头（`cost_headers :: +4`）