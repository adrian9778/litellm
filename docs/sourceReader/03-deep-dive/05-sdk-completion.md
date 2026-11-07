# SDK 内部：acompletion 的准备与分发

> 所属层级：第三层（主链路拆解） | 拆解对象：第二层场景的跳 8-9

## 本篇回答的问题

`litellm.acompletion()` 拿到参数后做了哪些规范化？model 字符串怎么变成 provider 四元组？为什么异步入口会跑到线程池里？

## 函数形态

```
litellm/main.py :: acompletion() :: +0
```

签名约 60 个显式参数（OpenAI 全集 + litellm 扩展如 `thinking`、`reasoning_effort`），尾部 `**kwargs` 兜底，返回类型是重载区分的 `ModelResponse | CustomStreamWrapper`（`stream=True` 时为流包装器）。

## 执行步骤

`acompletion() :: +0 至 +366`（实现体到 `run_in_executor` 为止）按序做：

| 步 | 动作 | 锚点（相对函数） |
|---|---|---|
| 1 | model 是 list？拆成多部署循环 | docstring 与参数注释（`model_list` 参数） |
| 2 | `router_obj` 检测：Router 内部调用会带 `litellm.router_obj`，此时直接透传，避免递归 | `acompletion() :: +0 附近的 router_obj 分支`（类 `LiteLLM` 定义段） |
| 3 | 参数经 `_REQUEST_KWARGS_ADAPTER`（pydantic TypeAdapter）校验归一 | `acompletion() :: +254 附近` |
| 4 | `get_llm_provider()` 解析 provider | `+249`（`main.py:887`） |
| 5 | 组装 `completion_kwargs`，处理 `fallbacks` | `+97`（fallbacks 取值）、`+261` |
| 6 | mock 参数短路（`mock_response` 等） | `+271` 起 |
| 7 | 执行：默认 `run_in_executor`（`+293`），有 fallbacks 时 `async_completion_with_fallbacks`（`+261`） |

## get_llm_provider：model 字符串解析

```
litellm/litellm_core_utils/get_llm_provider_logic.py :: get_llm_provider() :: +0
```

返回四元组 `(model, custom_llm_provider, dynamic_api_key, api_base)`。解析规则（`+186 起的实现体`）：

```
"openai/gpt-4o-mini"
├─ 显式前缀 "/" → split 出 provider，剩余为 model
├─ "azure/" 特判、cohere/anthropic-text 别名修正
├─ 无前缀 → 按 api_base/api_key/env 推断（openai 默认），
│           再查 litellm.known_tokenizer_set 等已知模型表
└─ "litellm_proxy/" → 走 LiteLLMProxyChatConfig 特殊分支
```

对本场景产出：`model="gpt-4o-mini"`、`custom_llm_provider="openai"`、api_key 从 `OPENAI_API_KEY` 解析、api_base 默认 `https://api.openai.com/v1`。

## ProviderConfigManager：provider 到配置类

```
litellm/utils.py :: ProviderConfigManager :: +0
litellm/utils.py :: ProviderConfigManager :: get_provider_chat_config() :: +0
```

懒构建的 O(1) 映射表（`_PROVIDER_CONFIG_MAP`，首次访问时构建以避免循环导入），每项是 `(工厂函数, 是否需要 model 参数)`：

```python
LlmProviders.OPENAI: (lambda: litellm.OpenAIGPTConfig(), False),
LlmProviders.ANTHROPIC: (lambda: litellm.AnthropicConfig(), False),
LlmProviders.BEDROCK: (lambda model: ProviderConfigManager._get_bedrock_config(model), True),
...
```

需要 model 参数的 provider（bedrock、vertex、azure_ai…）按 model 细分到具体 Config 子类。`completion()` 内部用解析出的 provider 调它拿到 `provider_config`（`main.py :: completion() :: provider_config 赋值段，main.py:5936 一带`），供执行器做参数校验与翻译。

## 为什么异步入口跑在线程池

```
litellm/main.py :: acompletion() :: run_in_executor 段
```

```python
func: Final = partial(completion, **completion_kwargs, **kwargs)
ctx: Final = contextvars.copy_context()
func_with_context: Final = partial(ctx.run, func)
init_response: Final = await loop.run_in_executor(None, func_with_context)
```

- 同步 `completion()` 是全 provider 的唯一完整分发器（每 provider 的 `_complete_*` 分支只在此存在），异步分发不做第二份
- OpenAI 走官方 SDK（同步客户端），httpx handler 的同步路径也是成熟的；异步化收益最大的场景由各 handler 自己的 `acompletion` 覆盖
- `contextvars.copy_context()` 保证 trace/logging 上下文跨线程不丢
- 返回值如果是协程（`asyncio.iscoroutine(init_response)`，部分 provider 内部已异步），会被 `_resolve_dispatched_chat_response` await（`main.py :: _resolve_dispatched_chat_response() :: +0`）

有显式 `fallbacks` 时走 `async_completion_with_fallbacks`（`main.py :: async_completion_with_fallbacks() :: +0`），在 SDK 层再套一层回退循环——注意这与 Router 的 fallback 是两个不同层，SDK 层只在直接调用 `litellm.acompletion(fallbacks=...)` 时生效。

## 缓存检查在这一层吗

在。`Logging` 对象（`function_setup` 创建，`litellm/utils.py :: function_setup() :: +0`）挂到 kwargs 后，缓存命中判断发生在 `completion()` 内部执行前（`litellm_core_utils/litellm_logging.py` 与 `caching_handler` 协作）。本场景未配缓存，直接进入执行器。

## 与下一跳的交接

`completion()` 已解析 provider、选定执行器分支。下一跳进入执行器内部（OpenAI SDK 路径或 httpx handler），看请求怎么翻译、发送、翻译回来。
