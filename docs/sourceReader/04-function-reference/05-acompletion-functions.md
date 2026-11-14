# 函数级解析（五）：acompletion 函数族与 provider 解析

> 所属层级：第四层（函数级解析） | 覆盖主链：第 8 跳（acompletion 准备）、第 9 跳（线程池分发）、第 10 跳前半（校验与 provider 解析）涉及的函数
> 本篇基准提交：`411b64dc7a`（工作区当前 HEAD）
> 引用规范：`文件 :: 符号 :: +偏移`，`+0` = 定义行，`+N` = 函数体内第 N 行

本篇逐个展开主链跳 8、跳 9、跳 10 前半里出现的函数：SDK 异步入口 `main.acompletion` 如何把 router 压缩参数整理成 `completion_kwargs`、控制参数与补充 provider 参数怎么归一、`custom_llm_provider` 缺失时 `get_llm_provider` / `_get_llm_provider` 怎么解析出 openai 四元组、同步 `completion()` 怎么被包成 partial 丢进线程池、返回值三种形态怎么归一，以及 fallback 与消息校验两条支线的函数。

术语首现已解释：`provider 四元组`（`(model, custom_llm_provider, dynamic_api_key, api_base)`，model 字符串解析的产物）、`执行器`（真正发上游请求的对象，OpenAI 走 `OpenAIChatCompletion`，其余走 `BaseLLMHTTPHandler`）、`线程池`（`loop.run_in_executor(None, ...)` 用的默认 `ThreadPoolExecutor`）、`contextvars`（Python 的上下文变量，trace/logging 依赖它跨线程传递）。

第三层《SDK 层》讲的是「第 8 到第 10 跳每一跳发生了什么」，本篇只讲「这些跳里每个函数内部具体怎么实现」；执行器内部见 [06-http-handler-functions.md](06-http-handler-functions.md) 与 [07-provider-transform-functions.md](07-provider-transform-functions.md)。

## 本篇覆盖函数与主链跳的对应

| 主链跳 | 本篇展开的函数 |
|---|---|
| 第 8 跳（准备） | `main.acompletion`、`_resolve_control_options`、`_supplemental_provider_params`、`_REQUEST_KWARGS_ADAPTER` |
| 第 8 跳支线（fallback） | `async_completion_with_fallbacks`、`completion_with_fallbacks` |
| 第 9 跳（分发） | `main.acompletion` 的执行段、`_resolve_dispatched_chat_response`、`_model_response_from_cached_dict` |
| 第 10 跳前半（解析与校验） | `get_llm_provider`、`_get_llm_provider`、`main.completion` 入口校验段、`validate_and_fix_openai_messages`、`validate_chat_completion_user_messages` |

---

### `acompletion`（`litellm/main.py`）

- 职责：SDK 异步 chat 入口。把 router 压缩后的调用参数整理成 `completion()` 能吃的 `completion_kwargs`，解析出 provider，再把同步 `completion()` 丢进线程池执行，是「Rust 选路」与「provider 执行器」之间的搬运与分发站。
- 签名/参数：`async def acompletion(model: str, messages: list = [], ...约 45 个显式参数..., **kwargs) -> ModelResponse | CustomStreamWrapper`（`litellm/main.py :: acompletion :: +0`，绝对行 652）。显式参数是 OpenAI 全集加 litellm 扩展（`thinking`、`web_search_options`、`reasoning_effort`、`service_tier`、`verbosity`、`safety_identifier`、`prompt_cache_key` 等）。被 `@tracer.wrap()` 与 `@client` 两个装饰器包裹（`+0` 之前的 650-651 行）。进来的 `**kwargs` 里已带着 router 展开后的 `api_key`、`api_base`、`metadata`、`litellm_params`、`litellm_logging_obj`。
- 返回：`ModelResponse | CustomStreamWrapper`。本场景（非流式、单 deployment、无 DB）返回 `ModelResponse`。
- 错误/分支：整个执行段包在 `try/except Exception`（`+355` 到 `+363`，行 1007-1015），任何异常先 `custom_llm_provider = custom_llm_provider or "openai"` 兜底，再 `raise exception_type(model=..., custom_llm_provider=..., original_exception=e, completion_kwargs=..., extra_kwargs=...)` 归一为 litellm 异常（`exception_type` 定义在 `litellm/litellm_core_utils/exception_mapping_utils.py :: 2644`，函数体未逐行读取，不臆测其映射表细节）。
- 调用关系：调用方 = `litellm/router_python_host.py :: PythonHost :: invoke`（经 `getattr(litellm, "acompletion")` 回跳）。被调用方 = `_resolve_control_options`、`_supplemental_provider_params`、`get_llm_provider`、`async_completion_with_fallbacks`、`loop.run_in_executor`、`_model_response_from_cached_dict`、`_resolve_dispatched_chat_response`、`maybe_run_chat_completion_agentic_loop`、`bill_first_round_on_failure`。

按执行顺序，函数体内（偏移相对 `+0`）做这些事：

| 序 | 动作 | 锚点 | 进出与分支 |
|---|---|---|---|
| 1 | `fallbacks = kwargs.get("fallbacks", None) or litellm.model_fallbacks` | `+98`（行 749） | 命中则后面改走回退路径 |
| 2 | `mock_timeout = kwargs.get("mock_timeout", None)`；为 `True` 时 `await _handle_mock_timeout_async(...)` | `+99` 到 `+109`（行 750-760） | 本场景无 mock，跳过 |
| 3 | `loop = asyncio.get_event_loop()` | `+111`（行 762） | 供第 9 跳用 |
| 4 | `custom_llm_provider = kwargs.get("custom_llm_provider", None)`；`_ = _resolve_control_options(kwargs, model)` | `+112` 到 `+113`（行 763-764） | 归一结果写回 kwargs；返回值丢弃（只在 `completion()` 里复用） |
| 5 | prompt management hooks：`AnthropicCacheControlHook.maybe_seed_default_injection_points(...)` 种默认注入点；命中 prompt 管理时 `await litellm_logging_obj.async_get_chat_completion_prompt(...)` 改写 model/messages | `+126`（行 778）到 `+187`（行 839） | 本场景无 prompt 管理，hook 只种默认注入点，messages 不变 |
| 6 | 组装 `completion_kwargs`：显式参数逐个搬进字典，并写 `"acompletion": True` | `+199` 到 `+246`（行 851-898） | 产物是给 `completion()` 的纯关键字字典 |
| 7 | `custom_llm_provider is None` 时调 `get_llm_provider(...)` 解析 provider | `+248` 到 `+259`（行 899-911） | 见下节 |
| 8 | 有 `fallbacks` 走 `async_completion_with_fallbacks(**completion_kwargs, kwargs={...})` 并 return | `+261` 到 `+269`（行 913-921） | 本场景无 fallbacks，不走 |
| 9 | mock delay：`mock_delay and should_run_mock_completion(...)` 命中则 `await asyncio.sleep(mock_delay)` | `+272` 到 `+282`（行 925-934） | 本场景跳过 |
| 10 | 真正执行（第 9 跳） | `+284` 起（行 936 起） | 见下节 |

第 6 步组装的 `completion_kwargs`（贴 `acompletion :: +199` 到 `+246`，行 851-898）是显式参数的逐个搬运，尾部两行决定后续行为：

```python
        "extra_headers": extra_headers,
        "acompletion": True,  # assuming this is a required parameter
        "thinking": thinking,
```

`"acompletion": True` 这个内部标志是第 9 跳执行前要从 kwargs 里 pop 掉的（见下文第 9 跳），它同时是 `OpenAIChatCompletion.completion` 选异步分支的依据（06 篇展开）。

### `acompletion` 第 9 跳：把同步 completion 丢进线程池

锚点：`litellm/main.py :: acompletion() :: +284` 到 `+301`（行 936-953）

```python
    try:
        # Use a partial function to pass your keyword arguments
        kwargs.pop("acompletion", None)
        func: Final = partial(completion, **completion_kwargs, **kwargs)

        # Add the context to the function
        ctx: Final = contextvars.copy_context()
        func_with_context: Final = partial(ctx.run, func)

        init_response: Final = await loop.run_in_executor(None, func_with_context)
        if isinstance(init_response, dict) or isinstance(init_response, ModelResponse):  ## CACHING SCENARIO
            if isinstance(init_response, dict):
                response = _model_response_from_cached_dict(init_response)
            response = init_response
        elif asyncio.iscoroutine(init_response):
            response = await _resolve_dispatched_chat_response(init_response)
        else:
            response = init_response
```

逐点讲清：

- `kwargs.pop("acompletion", None)`（`+286`，行 938）先摘掉内部标志，防止它漏进 `completion()` 的形参。
- `partial(completion, **completion_kwargs, **kwargs)`（`+287`，行 939）把第 8 跳组装的 `completion_kwargs` 与剩余 kwargs 合成一次 `completion()` 调用。
- `contextvars.copy_context()` + `partial(ctx.run, func)`（`+289` 到 `+290`，行 942-943）是关键：`run_in_executor` 把活丢到线程池线程，trace/logging 依赖的 contextvars（`litellm_call_id`、otel span 等）不会自动跨线程，必须显式带过去。
- `loop.run_in_executor(None, func_with_context)`（`+293`，行 945）用默认 `ThreadPoolExecutor`。返回值 `init_response` 有三种形态：`dict`（缓存命中）先经 `_model_response_from_cached_dict` 重建 `ModelResponse`；`ModelResponse` 原样赋给 `response`；协程交给 `_resolve_dispatched_chat_response` await；其余原样赋值。本场景 `completion()` 同步返回 `ModelResponse`，走第一分支。
- 反直觉但重要：异步入口 `acompletion` 的主路径是**把同步的 `completion()` 丢进线程池**，不是各 provider 各写一份异步分发。这样全 provider 的分发逻辑只存在一份（`completion()`），OpenAI 之外的 provider 由执行器自己的异步路径覆盖。

执行后的 agentic loop 收敛点（`acompletion :: +320` 到 `+347`，行 972-999）：拿到 `ModelResponse` 后 `bill_first_round_on_failure(maybe_run_chat_completion_agentic_loop(response=..., model=..., messages=..., optional_params={...非 None 且排除 model/messages/stream/acompletion/deployment_id...}, ...))`。函数体注释写明原因（行 964-971）：chat 路由在此之前的每个 provider 各自分叉（OpenAI 走 `litellm/llms/openai/openai.py` 的 SDK，其余走共享 httpx handler），这里才是所有分叉重新汇聚的唯一位置，所以循环在这里跑一次即可覆盖全部 provider。本场景 `maybe_run_chat_completion_agentic_loop` 判定无需多轮，原样返回响应。

尾部 `CustomStreamWrapper` 分支（`+350` 到 `+353`，行 1002-1005）给流包装器 `set_logging_event_loop(loop=loop)`，让同步流式也能跑异步成功回调。本场景非流式，不走。

---

### `_resolve_control_options`（`litellm/main.py`）

- 职责：把 kwargs 里的控制类参数（litellm 自己的开关，如 `drop_params`）解析成强类型 `ControlOptions`，非法值按 drop 语义决定是丢弃还是报 400。
- 签名/参数：`def _resolve_control_options(kwargs: Mapping[str, object], model: str) -> ControlOptions`（`litellm/main.py :: _resolve_control_options :: +0`，绝对行 407）。
- 返回：`ControlOptions`。
- 算法（贴 `_resolve_control_options :: +1` 到 `+11`，行 408-417）：

```python
    control: Final = parse_control_options(kwargs)
    match control:
        case ControlOptions():
            return control
        case InvalidControlOption(param=param, message=message):
            if litellm.drop_params is True or normalize_drop_params(kwargs.get("drop_params")) is True:
                return ControlOptions()
            raise litellm.BadRequestError(message=message, model=model, llm_provider=None, body={"param": param})
        case _:
            return assert_never(control)
```

  `parse_control_options` 产出一个 tagged union：合法则 `ControlOptions()` 原样返回；非法则 `InvalidControlOption`，此时看 `litellm.drop_params` 全局开关或请求级 `drop_params`，任一为真就把非法参数静默丢掉返回空 `ControlOptions()`，否则抛 `BadRequestError`（body 带 `param` 字段）。`case _` 用 `assert_never` 保证穷尽匹配。
- 错误/分支：非法控制参数且未开 drop → `litellm.BadRequestError`。
- 调用关系：调用方 = `main.acompletion :: +113`、`main.completion :: +138`（行 5701）。被调用方 = `parse_control_options`、`normalize_drop_params`、`assert_never`。`parse_control_options` 定义在 `litellm/types/utils.py`（`[源码未确认]` 具体行号未核到，符号名已确认）。

---

### `_supplemental_provider_params`（`litellm/main.py`）

- 职责：从请求 kwargs 里解析出 provider 需要的补充参数（`GenericLiteLLMParams`），并顺带标出哪些键是 litellm 内部键需要从上游请求里剔除。
- 签名/参数：`def _supplemental_provider_params(kwargs: Mapping[str, object], model: str) -> _SupplementalProviderParams`（`litellm/main.py :: _supplemental_provider_params :: +0`，绝对行 458）。
- 返回：`_SupplementalProviderParams`（成功，含 `.params` 与 `.dropped_keys`）；非法时抛错。
- 算法（贴 `_supplemental_provider_params :: +1` 到 `+6`，行 459-464）：

```python
    parsed: Final = _parse_supplemental_provider_params(kwargs)
    if isinstance(parsed, _InvalidSupplementalParams):
        raise litellm.BadRequestError(
            message=parsed.message, model=model, llm_provider=None, body={"param": parsed.param}
        )
    return parsed
```

  解析器 `_parse_supplemental_provider_params`（同文件 `+0`，绝对行 436）同样产出 tagged union：成功给 `_SupplementalProviderParams`，失败给 `_InvalidSupplementalParams`，本函数只负责把失败分支翻译成 `BadRequestError`。
- 调用关系：调用方 = `main.acompletion :: +256`（行 908，喂给 `get_llm_provider` 的 `litellm_params`）、`main.completion :: +126`（行 5689，取 `.dropped_keys` 剔除内部键）。被调用方 = `_parse_supplemental_provider_params`。`_SupplementalProviderParams` TypedDict 定义在 `litellm/main.py :: 425`，`_InvalidSupplementalParams` 在 `431`。
- 关联常量：`_REQUEST_KWARGS_ADAPTER: Final = TypeAdapter(Mapping[str, object])`（`litellm/main.py :: _REQUEST_KWARGS_ADAPTER :: +0`，绝对行 4371），用 Pydantic 的 `TypeAdapter` 把无类型 kwargs 先校验成 `Mapping[str, object]` 再交给上面两个解析器，避免直接把 `Any` 传下去。

---

### `get_llm_provider`（`litellm/litellm_core_utils/get_llm_provider_logic.py`）

- 职责：model 字符串加可选凭证信息解析成 provider 四元组，并对 model 跑一次最新别名归一。SDK 内被调最频繁的纯解析函数。
- 签名/参数：`def get_llm_provider(model: str, custom_llm_provider: str | None = None, api_base: str | None = None, api_key: str | None = None, litellm_params: GenericLiteLLMParams | None = None) -> tuple[str, str, str | None, str | None]`（`litellm/litellm_core_utils/get_llm_provider_logic.py :: get_llm_provider :: +0`，绝对行 187）。
- 返回：`tuple[别名归一后的 model, custom_llm_provider, dynamic_api_key, api_base]`。
- 算法（贴 `get_llm_provider :: +7` 到 `+10`，行 194-197）：

```python
    resolved_model, provider, dynamic_api_key, resolved_api_base = _get_llm_provider(
        model, custom_llm_provider, api_base, api_key, litellm_params
    )
    return resolve_model_latest_alias(resolved_model, provider), provider, dynamic_api_key, resolved_api_base
```

  它是个薄包装：真正推断在 `_get_llm_provider`，别名归一在 `resolve_model_latest_alias`。`acompletion` 只取第二个返回值（`acompletion :: +248` 那句 `_, custom_llm_provider, _, _ = get_llm_provider(...)`），因为 router 展开后的 `model` 已是带 `openai/` 前缀的完整名字，`completion()` 会再解析一次。
- 错误/分支：解析不出 provider 时 `_get_llm_provider` 抛 `BadRequestError`，本函数不捕获，沿 `acompletion` 上抛。
- 调用关系：调用方 = `main.acompletion :: +248`。被调用方 = `_get_llm_provider`、`resolve_model_latest_alias`。

---

### `_get_llm_provider`（`litellm/litellm_core_utils/get_llm_provider_logic.py`）

- 职责：provider 推断的真正实现。对带 `/` 前缀的名字拆出 provider，处理各历史别名与特判，无前缀时按 api_base/env 推断。
- 签名/参数：与 `get_llm_provider` 同形（`litellm/litellm_core_utils/get_llm_provider_logic.py :: _get_llm_provider :: +0`，绝对行 200）。
- 返回：`tuple[model, custom_llm_provider, dynamic_api_key, api_base]`（未经别名归一）。
- 算法（分岔顺序，偏移相对 `+0`）：

| 锚点 | 分支 | 行为 |
|---|---|---|
| `+16`（行 216） | `try:` 包住全函数 | 任何异常统一在尾部翻译 |
| `+18`（行 218-219） | `model is None` | `raise ValueError("model parameter is required but was None. ...")` |
| `+21`（行 221-226） | `LiteLLMProxyChatConfig.should_use_litellm_proxy_by_default(litellm_params=...)` 为真 | 转 `litellm_proxy_get_custom_llm_provider_info(...)`，网关自调用分支 |
| `+29`（行 229-233） | 传了 `litellm_params` 且 provider/api_base/api_key 全空 | 从 `litellm_params` 取这三项 |
| `+39`（行 239-242） | `model.split("/", 1)[0] == "azure"` 且 `is_non_openai_azure_model(model)` | provider 强制 `"openai"`，直接返回 |
| `+45`（行 245） | cohere 历史别名 | `handle_cohere_chat_model_custom_llm_provider(model, custom_llm_provider)` |
| `+47`（行 247） | anthropic-text 历史别名 | `handle_anthropic_text_model_custom_llm_provider(...)` |
| `+49`（行 249-252） | `custom_llm_provider` 与 model 前缀不一致 | `model = custom_llm_provider + "/" + model`（如 model=`azure/*` 而 provider=`azure`） |
| `+59`（行 259-263） | openrouter 特判 | 原生 `openrouter/auto` 保持；`openrouter/anthropic/claude-*` 剥成 `anthropic/claude-*` |
| `+66`（行 266-274） | JSON 配置的 provider 优先于枚举 | `JSONProviderRegistry.exists(provider_prefix)` 命中走 `_get_openai_compatible_provider_info(...)` |
| `+78`（行 278-290） | 前缀在 `litellm.provider_list` 且不在 `model_list_set` 且带 `/` | `_get_openai_compatible_provider_info(...)` |
| `+91`（行 291-298） | 前缀在 `litellm.provider_list`（不带额外 `/`） | `custom_llm_provider = 前缀`、`model = 剩余`，校验 api_base/api_key 类型后返回 |
| `+99`（行 299-300） | 前缀是注册的自定义 provider | 返回剩余 model 与前缀 |
| `+101`（行 302-434） | `api_base` 是已知 openai 兼容端点 | 按 `litellm.openai_compatible_endpoints` 逐个匹配，命中给对应 provider 名与 `get_secret_str` 取的 key |

  本场景 `"openai/gpt-4o-mini"`：前缀 `openai` 在 `provider_list` 里、不在 `model_list_set`、带 `/`，走 `+78` 那条 `_get_openai_compatible_provider_info`，产出 `model="gpt-4o-mini", custom_llm_provider="openai", dynamic_api_key=从环境/参数解析, api_base=默认 https://api.openai.com/v1`。
- 错误/分支：所有分支都穷尽后仍未识别 provider，`+386` 到 `+391`（行 586-591）抛 `litellm.exceptions.BadRequestError`（message 提示用 `provider/model` 格式显式指定）。外层 `except Exception`（`+597` 到 `+607`，行 597-607）把非 `BadRequestError` 的异常统一包成 `BadRequestError`（`GetLLMProvider Exception - {e}`），`BadRequestError` 原样重抛。
- 调用关系：调用方 = `get_llm_provider :: +8`。被调用方 = `handle_cohere_chat_model_custom_llm_provider`、`handle_anthropic_text_model_custom_llm_provider`、`is_non_openai_azure_model`、`JSONProviderRegistry.exists`、`_get_openai_compatible_provider_info`、`is_registered_custom_provider`、`_endpoint_matches_api_base`、`get_secret_str`、`litellm.exceptions.BadRequestError`。各 openai 兼容端点分支（行 305-434）只读到枚举段，逐条 endpoint 的 key 环境变量名已确认，其余推断分支未逐行读。

---

### `_resolve_dispatched_chat_response` 与 `_model_response_from_cached_dict`（`litellm/main.py`）

- 职责：`acompletion` 执行结果的两种非主流形态归一——协程则 await，缓存 dict 则重建 `ModelResponse`。
- 签名/参数：
  - `async def _resolve_dispatched_chat_response(pending: Coroutine[object, object, ModelResponse | CustomStreamWrapper]) -> ModelResponse | CustomStreamWrapper`（`litellm/main.py :: _resolve_dispatched_chat_response :: +0`，绝对行 1018）。
  - `def _model_response_from_cached_dict(cached_response_dict: Mapping[str, object]) -> ModelResponse`（`litellm/main.py :: _model_response_from_cached_dict :: +0`，绝对行 1024）。
- 返回：前者 await 后的响应；后者新建的 `ModelResponse`。
- 算法（贴两个函数体全文）：

```python
    return await pending                    # _resolve_dispatched_chat_response :: +3，行 1021

    return ModelResponse(**cached_response_dict)   # _model_response_from_cached_dict :: +1，行 1025
```

  两者都是极简转发，无类型分派逻辑（类型分派在 `acompletion` 主体 `+294` 到 `+301` 完成）。
- 调用关系：调用方 = `main.acompletion :: +299`（行 951）、`main.acompletion :: +295`（行 948）。被调用方 = `await pending` / `ModelResponse(**...)`。

---

### `async_completion_with_fallbacks`（`litellm/litellm_core_utils/fallback_utils.py`）

- 职责：SDK 层回退。主模型失败后逐个试 fallback 模型，第一个成功即返回。
- 签名/参数：`async def async_completion_with_fallbacks(**kwargs)`（`litellm/litellm_core_utils/fallback_utils.py :: async_completion_with_fallbacks :: +0`，绝对行 17）。`**kwargs` 里含一个嵌套 `kwargs` dict（`acompletion` 传入 `kwargs={"fallbacks": fallbacks, **caller_kwargs}`）。
- 返回：第一个成功的 `ModelResponse`（带 `x-litellm-attempted-fallbacks` 头信息，由 `add_fallback_headers_to_response` 附加）。
- 算法（贴 `async_completion_with_fallbacks :: +17` 到 `+62`，行 34-81）：

```python
    nested_kwargs: Final = kwargs.pop("kwargs", {})
    original_model: Final = kwargs["model"]
    model = original_model
    fallbacks: Final = [original_model] + nested_kwargs.pop("fallbacks", [])
    kwargs.pop("acompletion", None)  # Remove to prevent keyword conflicts
    litellm_call_id: Final = str(uuid.uuid4())
    base_kwargs: Final = {**kwargs, **nested_kwargs, "litellm_call_id": litellm_call_id}
    base_kwargs.pop("model", None)  # Remove model as it will be set per fallback
    litellm_logging_obj: Final = base_kwargs.pop("litellm_logging_obj", None)
    most_recent_exception_str: str | None = None
    for attempted_fallbacks, fallback in enumerate(fallbacks):
        try:
            completion_kwargs = safe_deep_copy(base_kwargs)
            if isinstance(fallback, dict):
                fallback_config = safe_deep_copy(dict(fallback))
                model = fallback_config.pop("model", original_model)
                completion_kwargs.update(fallback_config)
            else:
                model = fallback
            completion_kwargs = filter_internal_params(completion_kwargs)
            response = await litellm.acompletion(
                **completion_kwargs, model=model, litellm_logging_obj=litellm_logging_obj,
            )
            if response is not None:
                return add_fallback_headers_to_response(response=response, attempted_fallbacks=attempted_fallbacks)
        except Exception as e:
            verbose_logger.exception("Fallback attempt failed for model %s: %s", model, e)
            most_recent_exception_str = str(e)
            continue
    raise Exception(f"{most_recent_exception_str}. All fallback attempts failed. ...")
```

  分步：`+17` 弹出嵌套 kwargs、主模型作第 0 次尝试拼进 `fallbacks` 列表、摘掉 `acompletion` 标志防关键字冲突、生成新 `litellm_call_id`、组 `base_kwargs` 并摘掉 model 与 logging_obj（这两项每轮单独设）。`+31` 循环枚举 fallbacks：每轮 `safe_deep_copy` 隔离 dict 型 fallback 配置的污染，dict 型则 pop 出 model 并 merge 其余键，再 `filter_internal_params` 剔内部参数，递归调 `litellm.acompletion`（此时 `fallbacks` 已被消费，不会无限递归）。成功即加 fallback 头返回；失败记最近异常文本并 `continue`。
- 错误/分支：全部失败 → `raise Exception(f"{most_recent_exception_str}. All fallback attempts failed. ...")`（`+62` 到 `+64`，行 79-81）。单个 fallback 失败只记日志不中断循环。
- 调用关系：调用方 = `main.acompletion :: +262`（行 914）。被调用方 = `safe_deep_copy`、`filter_internal_params`、`litellm.acompletion`（递归）、`add_fallback_headers_to_response`、`verbose_logger`。
- 层次差异：这是「直接调 SDK 时」的回退；走 Proxy 时回退由 Router 层（第四层第 4 篇）承担。

### `completion_with_fallbacks`（`litellm/litellm_core_utils/fallback_utils.py`）

- 职责：把上面的异步回退同步化，给同步 `completion()` 用。
- 签名/参数：`def completion_with_fallbacks(**kwargs)`（`litellm/litellm_core_utils/fallback_utils.py :: completion_with_fallbacks :: +0`，绝对行 84）。
- 返回：同 `async_completion_with_fallbacks`。
- 算法（贴全文）：`return run_async_function(async_function=async_completion_with_fallbacks, **kwargs)`（`+1`，行 85）。`run_async_function` 来自 `.asyncify`。
- 调用关系：调用方 = 同步 `completion()` 的 fallback 分支。被调用方 = `run_async_function` → `async_completion_with_fallbacks`。

---

### `main.completion` 入口校验段（`litellm/main.py`）

- 职责：同步分发器的入口校验。消息、tools、tool_choice、optional params、thinking 逐项校验，通过后才做 provider 解析与执行器选择。校验在 `completion()` 入口做，不在 `acompletion` 本层，所以经 router 回跳的请求同样过这道门。
- 签名/参数：`def completion(model, messages=[], ...)`（`litellm/main.py :: completion :: +0`，绝对行 5564）。
- 返回：`ModelResponse | CustomStreamWrapper`（由选定执行器产出）。
- 算法（校验段，`completion :: +100` 到 `+121`，行 5664-5685）：

```python
    if model is None:
        raise ValueError("model param not passed in.")
    messages = validate_and_fix_openai_messages(
        messages=messages, model=model, request_kwargs=_REQUEST_KWARGS_ADAPTER.validate_python(kwargs)
    )
    tools = validate_and_fix_openai_tools(tools=tools)
    requested_tool_choice: Final = cast(object, tool_choice)
    tool_choice = validate_chat_completion_tool_choice(
        tool_choice=tool_choice, model=model,
        drop_params=drops_unsupported_params(cast("Mapping[str, object]", kwargs).get("drop_params")),
    )
    stop = validate_openai_optional_params(stop=stop)
    thinking = validate_and_fix_thinking_param(thinking=thinking)
```

| 校验 | 锚点 | 行为 |
|---|---|---|
| `model is None` | `+101`（行 5665-5666） | 抛 `ValueError("model param not passed in.")` |
| 消息校验 | `+104` 到 `+106`（行 5668-5670） | `validate_and_fix_openai_messages(...)`，签名带 `model`/`request_kwargs` |
| tools 校验 | `+107`（行 5671） | `validate_and_fix_openai_tools(tools=tools)` |
| tool_choice 校验 | `+108` 到 `+118`（行 5673-5682） | `validate_chat_completion_tool_choice(...)`，按 `drop_params` 决定是否丢弃不支持的值 |
| optional params 校验 | `+120`（行 5684） | `validate_openai_optional_params(stop=stop)` |
| thinking 参数 | `+121`（行 5685） | `validate_and_fix_thinking_param(thinking=thinking)` |

  紧接着 `+122` 到 `+138`（行 5687-5701）做 kwargs 解包与控制参数归一：`_locals_snapshot(locals())` 快照、`_supplemental_provider_params(...)` 取 `.dropped_keys` 并逐个 `kwargs.pop`、`kwargs.pop("_skip_responses_api_bridge", False)`、`control_options = _resolve_control_options(kwargs, model)`。
- 错误/分支：见上表；MCP 网关分支（`+139` 到 `+188`，行 5703-5752）在 tools 命中 `may_name_litellm_mcp_gateway` 时改走 `acompletion_with_mcp`，本场景 tools 为空不走。
- 调用关系：调用方 = 线程池里的 `partial(completion, ...)`（`acompletion :: +287`）。被调用方 = `validate_and_fix_openai_messages`、`validate_and_fix_openai_tools`、`validate_chat_completion_tool_choice`、`validate_openai_optional_params`、`validate_and_fix_thinking_param`、`_supplemental_provider_params`、`_resolve_control_options`。

### `validate_and_fix_openai_messages` 与 `validate_chat_completion_user_messages`（`litellm/utils.py`）

- 职责：OpenAI 消息格式校验。前者对带 assistant 专属字段的消息补 role，后者对每条消息查 role 并校验 user content 类型。
- 签名/参数：
  - `validate_and_fix_openai_messages(messages=..., model=..., request_kwargs=...)`（`litellm/utils.py :: validate_and_fix_openai_messages :: +0`，绝对行 9495）。
  - `validate_chat_completion_user_messages(new_messages, model, request_kwargs)`（`litellm/utils.py :: validate_chat_completion_user_messages :: +0`，绝对行 9572）。
- 返回：清洗后的 messages（前者）；无返回值、只在校验失败时抛（后者）。
- 算法：`validate_and_fix_openai_messages` 只在消息带 assistant 专属字段（`tool_calls`/`function_call`/`reasoning_content`/`refusal` 等）时才把缺 role 补成 `"assistant"`；普通消息缺 role 不再自动补，转交 `validate_chat_completion_user_messages`，后者 `"role" not in m or not m["role"]` 命中即 `raise MissingMessageRoleError(...)`，再校验 user 消息 content 类型（`ValidUserMessageContentTypes`）。抛错时读 `_deployment_provider({**request_kwargs, "model": model})` 取 provider 名。

  两个函数体内偏移本篇未逐行核到（属第四层校验细节），上面按符号名与调用点描述，`[推断]`。
- 错误/分支：缺 role → `MissingMessageRoleError`。异常类层级（`litellm/exceptions.py`）：`BadRequestError` → `MalformedRequestFieldError`（行 368）→ `MissingMessageRoleError`（行 372，HTTP 400），错误 body 里 `param="messages[{idx}].role"`。这是 #51124 的 BREAKING 行为变化：旧版自动补 role，现在抛 400。
- 调用关系：调用方 = `main.completion :: +104`。被调用方 = `validate_chat_completion_user_messages`、`MissingMessageRoleError`、`_deployment_provider`。

---

## 调用关系表（关键边）

| 调用方与符号 | 关系 | 被调用方与符号 | 触发与输入 | 返回与后续处理 | 错误、状态与副作用 |
|---|---|---|---|---|---|
| `PythonHost.invoke("acompletion")` | await | `main.acompletion :: +0` | 压缩后的调用参数 | 返回 `ModelResponse`/流包装器 | op 查不到抛 `AttributeError` |
| `acompletion :: +113` | 同步归一 | `_resolve_control_options :: +0` | kwargs + model | `ControlOptions`（返回值丢弃） | 非法且未 drop 抛 `BadRequestError` |
| `acompletion :: +256` | 条件解析 | `_supplemental_provider_params :: +0` | 校验后的 kwargs + model | `.params` 喂 `get_llm_provider` | 非法抛 `BadRequestError` |
| `acompletion :: +248` | 条件调用 | `get_llm_provider :: +0` | `model="openai/gpt-4o-mini"` + api_base + litellm_params | 四元组，只取 provider | 解析失败抛 `BadRequestError` |
| `get_llm_provider :: +8` | 委托 | `_get_llm_provider :: +0` | `model="openai/gpt-4o-mini"` + api_base + litellm_params | 原始四元组 | 尾部统一包成 `BadRequestError` |
| `_get_llm_provider :: +78` | 前缀匹配 | `_get_openai_compatible_provider_info :: +0` | `openai/gpt-4o-mini` | `("gpt-4o-mini", "openai", key, api_base)` | 未知 provider 回退后续分支 |
| `acompletion :: +287` | 线程池执行 | `loop.run_in_executor(None, func_with_context)` | `partial(completion, **completion_kwargs)` | `ModelResponse`/dict/协程 | 线程内异常上抛到 try |
| `acompletion :: +289` | 上下文拷贝 | `contextvars.copy_context()` | 当前协程上下文 | 可跨线程的 ctx | 不拷贝会丢 call id/otel span |
| `acompletion :: +295` | 条件重建 | `_model_response_from_cached_dict :: +0` | 缓存 dict | `ModelResponse` | 字段非法由 Pydantic 抛 |
| `acompletion :: +299` | 条件 await | `_resolve_dispatched_chat_response :: +0` | `init_response` 是协程时 | await 后的响应 | 协程异常原样上抛 |
| `acompletion :: +262` | 条件回退 | `async_completion_with_fallbacks :: +0` | completion_kwargs + fallbacks | 第一个成功的响应 | 全失败抛聚合 `Exception` |
| `async_completion_with_fallbacks :: +45` | 递归调用 | `litellm.acompletion :: +0` | 单个 fallback model + 清洗后 kwargs | 响应 | 失败记日志 `continue` |
| `completion :: +104` | 校验 | `validate_and_fix_openai_messages :: +0` | messages + model + request_kwargs | 清洗后的 messages | 缺 role 抛 `MissingMessageRoleError` 400 |
| `completion :: +138` | 同步归一 | `_resolve_control_options :: +0` | kwargs + model | `ControlOptions` | 非法且未 drop 抛 `BadRequestError` |

## 未确认项

- `AnthropicCacheControlHook.maybe_seed_default_injection_points`、`async_get_chat_completion_prompt`、`get_custom_logger_for_prompt_management`、`should_run_prompt_management_hooks`、`maybe_run_chat_completion_agentic_loop`、`bill_first_round_on_failure`、`should_run_mock_completion` 的函数体未逐行读取，本篇只引用其调用点与函数名（`litellm/main.py` 行 778、819、791、799、974、973、929），内部实现未读取，不臆测。
- `_get_llm_provider` 内各 openai 兼容端点分支只读到枚举段（行 302-434）与尾部错误翻译（行 580-607），中段 `_get_openai_compatible_provider_info`（行 622 起）函数体未逐行读；本场景（`openai/` 前缀）路径已确认。
- `parse_control_options`、`normalize_drop_params`、`resolve_model_latest_alias`、`_parse_supplemental_provider_params`、`run_async_function`、`filter_internal_params`、`safe_deep_copy`、`add_fallback_headers_to_response` 只确认符号名与调用点，定义行未全部核到，属 `[源码未确认]`。
- `validate_and_fix_openai_messages`（`litellm/utils.py` 9495）与 `validate_chat_completion_user_messages`（`litellm/utils.py` 9572）的函数体内偏移未逐行核到，按符号名与调用点描述，属 `[推断]`。
- `exception_type`（`litellm/litellm_core_utils/exception_mapping_utils.py :: 2644`）的映射表未逐行读，只确认 `acompletion` 尾部调用它归一异常。
- `EXPERIMENTAL_OPENAI_BASE_LLM_HTTP_HANDLER` 开关的实际运行取值属 `[待运行验证]`，本场景按未设置（`get_secret_bool` 返回 `None`，即 falsy）处理，走 OpenAI SDK 路径。

## 源码索引

| 符号 | 文件 :: 符号 | 绝对定义行 |
|---|---|---|
| 异步入口 | `litellm/main.py :: acompletion` | 652 |
| 控制参数归一 | `litellm/main.py :: _resolve_control_options` | 407 |
| 补充 provider 参数 | `litellm/main.py :: _supplemental_provider_params` | 458 |
| 补充参数解析器 | `litellm/main.py :: _parse_supplemental_provider_params` | 436 |
| 补充参数类型 | `litellm/main.py :: _SupplementalProviderParams` | 425 |
| 请求参数适配器 | `litellm/main.py :: _REQUEST_KWARGS_ADAPTER` | 4371 |
| 同步分发器 | `litellm/main.py :: completion` | 5564 |
| 协程透传 | `litellm/main.py :: _resolve_dispatched_chat_response` | 1018 |
| 缓存 dict 重建 | `litellm/main.py :: _model_response_from_cached_dict` | 1024 |
| mock 超时 | `litellm/main.py :: _handle_mock_timeout_async` | 1111 |
| OpenAI 执行器单例 | `litellm/main.py :: openai_chat_completions` | 358 |
| httpx 执行器单例 | `litellm/main.py :: base_llm_http_handler` | 395 |
| provider 解析 | `litellm/litellm_core_utils/get_llm_provider_logic.py :: get_llm_provider` | 187 |
| provider 解析实现 | `litellm/litellm_core_utils/get_llm_provider_logic.py :: _get_llm_provider` | 200 |
| openai 兼容 provider 信息 | `litellm/litellm_core_utils/get_llm_provider_logic.py :: _get_openai_compatible_provider_info` | 622 |
| 异常归一 | `litellm/litellm_core_utils/exception_mapping_utils.py :: exception_type` | 2644 |
| 异步回退 | `litellm/litellm_core_utils/fallback_utils.py :: async_completion_with_fallbacks` | 17 |
| 同步回退包装 | `litellm/litellm_core_utils/fallback_utils.py :: completion_with_fallbacks` | 84 |
| Logging 对象构建 | `litellm/utils.py :: function_setup` | 1288 |
| 消息校验 | `litellm/utils.py :: validate_and_fix_openai_messages` | 9495 |
| user 消息校验 | `litellm/utils.py :: validate_chat_completion_user_messages` | 9572 |
| 宿主回跳 | `litellm/router_python_host.py :: PythonHost :: invoke` | 107 |

## 本篇函数调用关系图

```mermaid
flowchart TD
    PH["PythonHost.invoke<br/>router_python_host.py 107"] --> AC["acompletion<br/>main.py 652"]
    AC --> RCO["_resolve_control_options<br/>main.py 407"]
    AC --> SPP["_supplemental_provider_params<br/>main.py 458"]
    SPP --> RKA["_REQUEST_KWARGS_ADAPTER<br/>main.py 4371"]
    AC -->|"custom_llm_provider is None"| GLP["get_llm_provider<br/>get_llm_provider_logic.py 187"]
    GLP -->["_get_llm_provider"] GLLP["_get_llm_provider<br/>get_llm_provider_logic.py 200"]
    GLP --> OCO["_get_openai_compatible_provider_info<br/>get_llm_provider_logic.py 622"]
    GLP -->|"穷尽未识别"| BRE["BadRequestError<br/>exceptions.py"]
    AC -->|"有 fallbacks"| FBF["async_completion_with_fallbacks<br/>fallback_utils.py 17"]
    FBF -->|"递归"| AC
    AC --> RIE["loop.run_in_executor<br/>+ copy_context"]
    RIE --> CO["completion<br/>main.py 5564"]
    CO --> VAM["validate_and_fix_openai_messages<br/>utils.py 9495"]
    VAM --> VCU["validate_chat_completion_user_messages<br/>utils.py 9572"]
    VCU --> MMR["MissingMessageRoleError<br/>exceptions.py 372"]
    CO --> EXE["执行器选择<br/>见 06/07 篇"]
    EXE --> MR["ModelResponse"]
    MR --> AC
    AC -->|"dict 结果"| MRC["_model_response_from_cached_dict<br/>main.py 1024"]
    AC -->|"协程结果"| RDC["_resolve_dispatched_chat_response<br/>main.py 1018"]
    AC -->|"ModelResponse"| AGL["maybe_run_chat_completion_agentic_loop<br/>+ bill_first_round_on_failure"]
    AC -->|"异常"| ET["exception_type<br/>exception_mapping_utils.py 2644"]
```
