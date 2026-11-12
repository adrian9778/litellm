# SDK 内部：acompletion 的准备与分发

> 所属层级：第三层（主链路拆解） | 拆解对象：第二层场景的跳 8-9

## 本篇回答的问题

`litellm.acompletion()` 拿到参数后做了哪些规范化？model 字符串怎么变成 provider 四元组？为什么异步入口会跑到线程池里？

## 函数形态

```
litellm/main.py :: acompletion :: +0
```

签名在 `+0 至 +53`（定义 652 行到 `) -> ModelResponse | CustomStreamWrapper` 705 行），共 45 个显式参数（OpenAI 全集 + litellm 扩展如 `thinking`、`web_search_options`、`reasoning_effort`、`service_tier`），尾部 `**kwargs`（704 行）兜底，返回类型是重载区分的 `ModelResponse | CustomStreamWrapper`（`stream=True` 时为流包装器）。签名被 `@tracer.wrap()` 与 `@client` 两个装饰器包裹（`+0` 前的 650-651 行）。

## 执行步骤

`acompletion() :: +0 至 +355`（实现体到函数结尾的 `except` 块为止）按序做：

| 步 | 动作 | 锚点（相对函数） |
|---|---|---|
| 1 | `fallbacks` 取值：`kwargs.get("fallbacks")` 或全局 `litellm.model_fallbacks` | `+97`（749 行 `fallbacks: Final = kwargs.get(...)`） |
| 2 | `mock_timeout` 取值与短路：`_handle_mock_timeout_async`（main.py 1111 起）在请求真正发往前 `await` | `+101`（753 行起 `mock_timeout is True` 分支） |
| 3 | `_resolve_control_options(kwargs, model)`（main.py 407 起）归一控制参数 | `+112`（764 行） |
| 4 | **prompt management hooks**：`AnthropicCacheControlHook.maybe_seed_default_injection_points`（778 行）种注入点；`litellm_logging_obj.async_get_chat_completion_prompt` 改写 model/messages（815 行起） | `+126`（778 行起） |
| 5 | 组装 `completion_kwargs`（显式参数 + `"acompletion": True`） | `+199`（851 行起） |
| 6 | `get_llm_provider()` 解析 provider（`custom_llm_provider is None` 时，901 行起） | `+249`（899 行） |
| 7 | 有 `fallbacks` 走 `async_completion_with_fallbacks`（913 行起） | `+261` |
| 8 | mock delay：`mock_delay`/`mock_response`/`mock_tool_calls`/`mock_timeout`，命中 `should_run_mock_completion` 则 `asyncio.sleep` | `+273`（925 行起） |
| 9 | 执行：默认 `loop.run_in_executor`（945 行） | `+293` |
| 10 | 返回归一：缓存 dict / 协程（`_resolve_dispatched_chat_response`）/ 直接；chat completions agentic loop（`maybe_run_chat_completion_agentic_loop`，litellm_core_utils/chat_completion_agentic_loop.py 441 起） | `+294`（946 行起） |

旧文档把执行步骤写成「model 是 list 拆部署循环」「`_REQUEST_KWARGS_ADAPTER` 校验归一（+254）」，实际均不存在于 `acompletion` 函数体。本基线里：

- `_REQUEST_KWARGS_ADAPTER`（`TypeAdapter(Mapping[str, object])`，main.py 4371）只在两个调用点出现：`get_llm_provider` 分支的 `_supplemental_provider_params`（909 行）与 `completion()` 内（5669 行）校验消息用，不在 `acompletion` 里直接归一参数；
- `model_list` 参数（694 行）在 `completion_kwargs` 里透传（883 行），但 `acompletion` 本层没有拆 model list 成多部署循环。

## get_llm_provider：model 字符串解析

```
litellm/litellm_core_utils/get_llm_provider_logic.py :: get_llm_provider :: +0
```

定义 187 行。返回四元组 `(model, custom_llm_provider, dynamic_api_key, api_base)`。在 `acompletion` 里只用于「用户没显式给 `custom_llm_provider`」时推导：

```python
_, custom_llm_provider, _, _ = get_llm_provider(
    model=model,
    custom_llm_provider=None,
    api_base=request_kwargs.get("api_base") or base_url,
    litellm_params=_supplemental_provider_params(
        _REQUEST_KWARGS_ADAPTER.validate_python({**kwargs, "extra_headers": extra_headers}), model
    ).params,
)
```

（main.py 899-911 行，函数内偏移 `+247`。`litellm_params` 由 `_supplemental_provider_params`（main.py 458 起）基于 `_REQUEST_KWARGS_ADAPTER` 校验后的 kwargs 补出。）

解析规则（`get_llm_provider_logic.py` 函数体内）：

```
"openai/gpt-4o-mini"
├─ 显式前缀 "/" → split 出 provider，剩余为 model
├─ "azure/" 特判、cohere/anthropic-text 别名修正
├─ 无前缀 → 按 api_base/api_key/env 推断（openai 默认），
│           再查 litellm.known_tokenizer_set 等已知模型表
└─ "litellm_proxy/" → 走 LiteLLMProxyChatConfig 特殊分支
```

对本场景产出：`model="gpt-4o-mini"`、`custom_llm_provider="openai"`、api_key 从 `OPENAI_API_KEY` 解析、api_base 默认 `https://api.openai.com/v1`。

## 消息校验与缺 role 行为变化（#51124 BREAKING）

`acompletion` 本层**不**校验消息。真正的校验在 `completion()`（main.py 5564 起）入口，`+104`（5668 行）：

```python
messages = validate_and_fix_openai_messages(
    messages=messages, model=model, request_kwargs=_REQUEST_KWARGS_ADAPTER.validate_python(kwargs)
)
```

- `validate_and_fix_openai_messages` 定义在 `litellm/utils.py` 9496 起，**签名加了 `model` 与 `request_kwargs`**（`model: str = "", request_kwargs: Mapping[str, object] | None = None`），尾部把清洗结果交给 `validate_chat_completion_user_messages`（utils.py 9520 调用点，定义 9573 起）；
- 旧文档（以及更早行为）「自动补 role」：当前**只在**消息带 `_ASSISTANT_ONLY_MESSAGE_KEYS`（utils.py 9491，`tool_calls`/`function_call`/`reasoning_content`/`refusal` 等）时补成 `"assistant"`（utils.py 9517-9518）。**普通缺 role 消息不再自动补**，改抛 `MissingMessageRoleError`（utils.py 9593-9601）；
- `MissingMessageRoleError` 定义在 `litellm/exceptions.py` 372 行，继承 `MalformedRequestFieldError`（370 行）→ `BadRequestError`，HTTP 400。错误 body 里 `param="messages[{idx}].role"`。

```
completion() :: +104  messages = validate_and_fix_openai_messages(messages, model, request_kwargs)
                                        │
                                        ▼
litellm/utils.py :: validate_and_fix_openai_messages +0   (# assistant-only keys → role="assistant")
                                        │
                                        ▼
litellm/utils.py :: validate_chat_completion_user_messages +0
                                        │   "role" not in m or not m["role"]
                                        ▼
litellm/exceptions.py :: MissingMessageRoleError +0   (HTTP 400, param="messages[i].role")
```

## ProviderConfigManager：provider 到配置类

```
litellm/utils.py :: ProviderConfigManager :: +0
litellm/utils.py :: ProviderConfigManager :: get_provider_chat_config :: +0
```

`ProviderConfigManager` 定义 utils.py 9722 起。`_PROVIDER_CONFIG_MAP`（9726 行，初始 None）由 `_build_provider_config_map`（9729 起）**惰性构建**——首访 `get_provider_chat_config` 时（10061-10062）才 build，每项是 `(工厂函数, 是否需要 model 参数)` 二元组：

```python
LlmProviders.OPENAI:     (lambda: litellm.OpenAIGPTConfig(), False),
LlmProviders.ANTHROPIC:  (lambda: litellm.AnthropicConfig(), False),
LlmProviders.BEDROCK:    (lambda model: ProviderConfigManager._get_bedrock_config(model), True),
LlmProviders.AZURE_AI:   (lambda model: ProviderConfigManager._get_azure_ai_config(model), True),
...
```

需要 model 参数的 provider（bedrock、azure_ai、vertex_ai、cohere…）按 model 细分到具体 Config 子类。`get_provider_chat_config`（10028 起）先特判 OPENAI 的 O-series / GPT-5 / 未知 catalog 模型、再处理 AZURE 特例，然后 O(1) map 查表，未命中回退到 JSONProviderRegistry（10077 起）。

`completion()` 内部用解析出的 provider 调它拿 `provider_config`，供执行器做参数校验与翻译（`litellm/main.py :: completion :: provider_config 赋值段`）。

## 为什么异步入口跑在线程池

```
litellm/main.py :: acompletion :: +285 至 +302
```

（937-953 行）

```python
kwargs.pop("acompletion", None)
func: Final = partial(completion, **completion_kwargs, **kwargs)
ctx: Final = contextvars.copy_context()
func_with_context: Final = partial(ctx.run, func)
init_response: Final = await loop.run_in_executor(None, func_with_context)
if isinstance(init_response, dict) or isinstance(init_response, ModelResponse):  ## CACHING SCENARIO
    ...
elif asyncio.iscoroutine(init_response):
    response = await _resolve_dispatched_chat_response(init_response)
else:
    response = init_response
```

- 同步 `completion()` 是全 provider 的唯一完整分发器（每 provider 的 `_complete_*` 分支只在此存在），异步分发不做第二份；
- OpenAI 走官方 SDK（同步客户端），httpx handler 的同步路径也是成熟的；异步化收益最大的场景由各 handler 自己的 `acompletion` 覆盖；
- `contextvars.copy_context()` 保证 trace/logging 上下文跨线程不丢；
- `init_response` 若是协程（`asyncio.iscoroutine`，部分 provider 内部已异步），交给 `_resolve_dispatched_chat_response`（`litellm/main.py :: _resolve_dispatched_chat_response :: +0`，1018 行）await——该函数只是个极薄的透传：`return await pending`（1021 行）；
- 返回前还有一层 chat completions agentic loop：`maybe_run_chat_completion_agentic_loop`（`litellm/litellm_core_utils/chat_completion_agentic_loop.py :: maybe_run_chat_completion_agentic_loop :: +0`，441 行）包 `bill_first_round_on_failure`（同文件 64 行起），在 main.py 972-1001 行调用，作为 provider 无关的 agentic 循环统一分发点。

有显式 `fallbacks` 时走 `async_completion_with_fallbacks`（`litellm/litellm_core_utils/fallback_utils.py :: async_completion_with_fallbacks :: +0`，定义 17 行），在 `acompletion` 内 913-921 行：

```python
if fallbacks is not None:
    response = await async_completion_with_fallbacks(
        **completion_kwargs, kwargs={"fallbacks": fallbacks, **caller_kwargs}
    )
    if response is None:
        raise Exception("No response from fallbacks. Got none. ...")
    return response
```

注意这是在 SDK 层再套一层回退循环——与 Router 的 fallback 是两个不同层，SDK 层只在直接调用 `litellm.acompletion(fallbacks=...)`（或 `litellm.model_fallbacks` 全局）时生效。`async_completion_with_fallbacks` 的完整语义在 `fallback_utils.py` 内，不属于本篇主线。

## 缓存检查在这一层吗

在。`Logging` 对象（`function_setup` 创建，`litellm/utils.py :: function_setup :: +0`，定义 1288 行）挂到 kwargs 后，缓存命中判断发生在 `completion()` 内部执行前（`litellm_core_utils/litellm_logging.py` 与 `caching_handler` 协作）。`acompletion` 本层对缓存无感知——命中与否在 `run_in_executor` 里由 `completion()` 决定；`init_response` 若是 `dict`（缓存命中序列化结果），本层用 `_model_response_from_cached_dict`（main.py 1024 起）还原成 `ModelResponse`（947-948 行）。本场景未配缓存，直接进入执行器。

## 与下一跳的交接

`completion()` 已解析 provider、选定执行器分支。下一跳进入执行器内部（OpenAI SDK 路径或 httpx handler），看请求怎么翻译、发送、翻译回来。关键是把 `custom_llm_provider` 与 `provider_config`（经 `ProviderConfigManager.get_provider_chat_config` 解析）一起交给执行器。