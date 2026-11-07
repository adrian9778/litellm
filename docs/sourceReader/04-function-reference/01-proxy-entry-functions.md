# 函数级解析：Proxy 入口与请求处理

> 所属层级：第四层（源码补齐） | 覆盖：`proxy_server.py` 端点函数、`common_request_processing.py` 主处理类

引用规范：`文件 :: 类 :: 函数 :: +偏移`，`+0` 为定义行。本篇所有偏移已回代码核对。

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

1. `+31`：`data = await read_request_body(request)`，失败转 `ProxyException`
2. `+32` 至 `+45`：metadata 归一与身份注入（键名见第三层第 1 篇的表）
3. `+50`：构造 `ProxyBaseLLMRequestProcessing(data=data)`
4. `+51`：`base_process_llm_request(route_type="acompletion", ...)`，传入全局 `proxy_logging_obj`、`llm_router`、`proxy_config`、`general_settings`
5. 返回分支：`isinstance(result, BaseModel)` → `model_dump_with_preserved_fields(result, exclude_unset=True)`，否则原样返回

错误处理（`+73` 起的 except 链）：

| 异常 | 处理 |
|---|---|
| `ModifyResponseException` | 构造 `finish_reason="content_filter"` 的响应；流式则转 SSE 单片；先走 `post_call_failure_hook` 留痕 |
| `ProxyException` | 原样返回（统一错误 schema） |
| `Exception` | 包成 500 `ProxyException`，`post_call_failure_hook` 触发失败回调 |

并发：本函数本身无共享状态写；后台任务（状态更新、记账）用 `asyncio.create_task` 发射后不管。

## 2. `ProxyBaseLLMRequestProcessing.__init__()`

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: __init__() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 每请求实例，持有请求数据与处理状态 |
| 参数 | `data: dict`（OpenAI 风格请求体）、`served_model: str \| None`（通配模型解析后的实际模型） |
| 状态字段 | `self.data`、`self.served_model`、`self._tags_before_guardrails`（guardrail 改写 tags 前的快照，用于预算校验一致性）、`self.route_type` |
| 后置 | 实例就绪，等待 `base_process_llm_request` 调用 |

## 3. `base_process_llm_request()`

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: base_process_llm_request() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 处理骨架的外壳：包 SSE keepalive 与迟到失败审计 |
| 参数 | `request`、`fastapi_response`、`user_api_key_dict`、`route_type: ProxyRouteType`、`proxy_logging_obj`、`general_settings`、`proxy_config`、`llm_router`、`model`、`user_*` 全局配置族、`is_streaming_request`、`contents`、`skip_pre_call_logic` |
| 返回 | 委托 `_process_llm_request` 的结果（响应或流） |
| 前置 | `data` 已注入 metadata |
| 后置 | 若 keepalive 已上线，失败只能审计不能改状态码（见 `_audit_late_failure` 内嵌函数 `+31`） |

核心算法：`answers_as_anthropic = route_type == "anthropic_messages"` 决定迟到失败的错误帧格式；然后整个 `_process_llm_request` 协程交给 `open_sse_before_first_byte(...)`（`common_request_processing.py :: open_sse_before_first_byte() :: +1538`），参数 `ping_interval_seconds=ttft_keepalive_interval(self.data, llm_router)`。

## 4. `_process_llm_request()`

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: _process_llm_request() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 主链路真正骨架：pre-call → 路由 → 执行 → 收尾 |
| 返回 | 响应对象或 `StreamingResponse` |
| 前置 | `user_api_key_dict` 有效；`llm_router` 可为 None（无 model_list 时直连 SDK） |
| 后置 | 成功时响应头已组装；spend 写入已发出 |

核心算法（三段）：

**段一 pre-call（`+25` 至 `+50`）**：
- `skip_pre_call_logic=True` 时从 data 里取现成的 `litellm_logging_obj`（没有就 ValueError，避免静默丢日志）
- 否则 `self.data, logging_obj = await self._pre_call_with_fallbacks(...)`

**段二 执行（`+84` 至 `+95`）**：
```python
llm_call = await route_request(data, route_type, llm_router, user_model, user_api_key_dict)
llm_call_task = asyncio.create_task(with_proxy_compaction_executor(llm_call, request))
```
`cancel_on_disconnect` 配置时用 `_await_llm_call_cancelling_on_disconnect` 等待，否则直接 await。

**段三 收尾（`+97` 起）**：
1. 从 `_hidden_params` 取 `cache_key`/`api_base`/`response_cost`/`additional_headers`
2. `data["deployment"]` 记录命中部署
3. 流式判断：`_is_streaming_request(...)` 或响应本身是流 → SSE 分支（`_stream_response_headers` 组头、`_arm_deferred_stream_dispatch` 延迟 guardrail）
4. 非流式：`post_call_success_hook`（可改写响应）→ `get_custom_headers` → 返回

错误处理：异常沿 `route_type` 映射为 `ProxyException`；`asyncio.CancelledError` 特殊处理（断连计费，见 `_dispatch_disconnect_billing_event`）。

## 5. `_pre_call_with_fallbacks()`

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: _pre_call_with_fallbacks() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 包一层异常处理的 pre-call：任何 pre-call 异常也触发 `post_call_failure_hook` |
| 返回 | `(data, logging_obj)` 二元组 |
| 核心算法 | try: `common_processing_pre_call_logic(...)`；except: 记录失败 → re-raise |
| 并发 | 无 |

## 6. `common_processing_pre_call_logic()`

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: common_processing_pre_call_logic() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 鉴权后的全部请求加工：注入、配置合并、Logging 构建、hook 执行 |
| 参数 | `request`、`general_settings`、`proxy_logging_obj`、`user_api_key_dict`、`route_type`、`proxy_config`、`llm_router`、`user_model` 等 |
| 返回 | `self.data, logging_obj`——调用方按 `self.data, logging_obj = await self._pre_call_with_fallbacks(...)` 解包（`common_request_processing.py :: ProxyBaseLLMRequestProcessing :: _pre_call_with_fallbacks()` 尾部 return） |
| 前置 | `self.data` 已含 metadata |
| 后置 | `data["litellm_logging_obj"]` 就位；限流已扣减（hook 内） |

九步清单与偏移见第三层第 3 篇的表（+123 / +180 / +192 / +205 / +251 / +261 / +293 / +320），此处不重复。两个易错点：

- `function_setup` 返回的 logging_obj 会同时写回 `self.data["litellm_logging_obj"]`，后续所有层从 kwargs 里拿它
- guardrail（如 Presidio）可能改写 `messages`，所以 messages 刷新在 pre_call_hook 之后（`+320`），保证日志与实际发送内容一致

## 7. `get_custom_headers()`

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: get_custom_headers() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 组装 `x-litellm-*` 响应头 |
| 参数 | `user_api_key_dict`、`call_id`、`model_id`、`response_cost`、`hidden_params`、`litellm_logging_obj` 等（全关键字参数） |
| 返回 | `dict[str, str]` |
| 核心算法 | 值解析链：显式参数 → `hidden_params` → `request_data` → logging_obj 计时（`read_timing_from_logging_obj` 控制）；空值统一剔除（`exclude_values = {"", None, "None"}`） |
| 后置 | 头在 `litellm/constants.py` 的常量约束下（如 `x-litellm-response-cost`，`common_request_processing.py :: cost_headers() :: +14` 的字面量） |

## 8. `read_request_body()`

```
litellm/proxy/common_utils/http_parsing_utils.py :: read_request_body() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 容错读 body 并解析为 dict |
| 参数 | `request: Request \| None` |
| 返回 | `dict`（解析失败/空 body → `{}`，不抛） |
| 核心算法 | 分支树见第三层第 1 篇；关键是解析结果缓存在 `request.scope["parsed_body"]`（`_safe_get_request_parsed_body :: +414`），或json + pydantic `TypeAdapter` 校验 + surrogate 修复重试 |
| 错误处理 | JSONDecodeError → 修复重试；表单 metadata 为 JSON 字符串 → 二次解析 |

## 9. `open_sse_before_first_byte()`

```
litellm/proxy/common_request_processing.py :: open_sse_before_first_byte() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 上游首字节前的 SSE 保活包装 |
| 参数 | 内层协程、`ping_interval_seconds`（None 则不包装）、`on_late_failure`、`late_failure_frames` |
| 返回 | 响应或已开始发送的 SSE 流 |
| 核心算法 | 竞速：上游响应 vs ping 定时器；一旦 ping 上线，后续异常只能以 SSE 错误帧发出（`on_late_failure` 审计），HTTP 状态码已无法修改 |
| 并发 | 内部用 `asyncio` 任务组管理 ping 与主协程 |

## 本篇覆盖之外的端点

`proxy_server.py` 里 embeddings/responses/messages 等端点与 `chat_completion` 同构（读 body → 构造 `ProxyBaseLLMRequestProcessing` → `base_process_llm_request(route_type=...)`），差异只在 `route_type` 与少量端点特有逻辑，不再重复展开。
