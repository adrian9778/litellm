# 函数级解析：acompletion 函数族

> 所属层级：第四层（源码补齐） | 覆盖：`main.py` 的 acompletion 及其直接辅助函数

## 1. `acompletion()`

```
litellm/main.py :: acompletion() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | SDK 异步入口：参数规范化 → provider 解析 → 执行分发 |
| 参数 | 约 60 个显式参数（OpenAI 全集 + litellm 扩展）+ `**kwargs` |
| 返回 | `ModelResponse \| CustomStreamWrapper`（重载按 `stream` 区分，`+0` 处三个 overload） |
| 前置 | `litellm` 包已初始化（回调注册、model_cost 已加载） |
| 后置 | 响应已带 `_hidden_params` 元数据；日志事件已发出 |

核心算法（偏移相对 `+0`）：

1. `+97`：`fallbacks = kwargs.get("fallbacks", None) or litellm.model_fallbacks`
2. `+249`：`get_llm_provider(...)` 解析 model 字符串（provider 未知时）
3. `+254` 附近：`_REQUEST_KWARGS_ADAPTER.validate_python` 参数校验归一
4. `+261`：fallbacks 非空 → `async_completion_with_fallbacks(**completion_kwargs, kwargs={"fallbacks": ..., **caller_kwargs})`
5. `+271`：mock 参数短路（`mock_delay` + `should_run_mock_completion`）
6. `+284` 至 `+293`：同步 `completion()` 打包为 partial，`contextvars.copy_context()` 保留上下文，`loop.run_in_executor(None, func_with_context)` 执行
7. `+295` 至 `+320`：返回值归一——dict → `ModelResponse`（`litellm/main.py :: _model_response_from_cached_dict() :: +0`）、协程 → await（`litellm/main.py :: _resolve_dispatched_chat_response() :: +0`）
8. `+330` 附近：text-completion provider 的响应对象转换
9. 尾部：agentic loop 接入点（`maybe_run_chat_completion_agentic_loop`，注释写明这是所有 provider 的汇聚点）

## 2. `get_llm_provider()`

```
litellm/litellm_core_utils/get_llm_provider_logic.py :: get_llm_provider() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | model 字符串 → 四元组。SDK 内被调最频繁的纯函数 |
| 参数 | `model: str`、`custom_llm_provider: str \| None`、`api_base`、`api_key`、`litellm_params` |
| 返回 | `tuple[model, custom_llm_provider, dynamic_api_key, api_base]` |
| 前置 | `model` 非 None（`+20` 检查，否则 ValueError） |
| 后置 | 无副作用（纯解析） |

核心算法（分岔顺序）：

```
+25  "litellm_proxy/" 前缀 → LiteLLMProxyChatConfig 特殊分支（网关自调用）
+40  "azure/" 前缀特判（可能映射为 openai provider）
+46  cohere / anthropic-text 的历史别名修正
+50  custom_llm_provider 与 model 前缀不一致的调和
     （如 model="azure/gpt-4o" 而 provider="azure"）
后半 无显式前缀时：按 api_base/api_key/env 推断 provider，
     再查已知模型表（tokenizer 集、模型价目表键）
```

推断失败时抛 `litellm.exceptions.BadRequestError`（提示用 `provider/model` 格式显式指定）。

## 3. `ProviderConfigManager.get_provider_chat_config()`

```
litellm/utils.py :: ProviderConfigManager :: get_provider_chat_config() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | provider（+ 可选 base_model）→ Config 实例 |
| 参数 | `model: str`、`provider: LlmProviders`、`base_model: str \| None` |
| 返回 | `BaseConfig` 子类实例（每次新实例，无共享可变状态） |
| 核心算法 | `_PROVIDER_CONFIG_MAP` 懒构建（类 docstring 写明避免循环导入与运行时 `inspect.signature` 开销）；表项 `(工厂函数, needs_model_parameter)`：需要 model 的（bedrock/vertex/azure_ai/cohere…）按 model 细分到子配置；AZURE 特判在 `get_provider_chat_config()` 内以支持 `base_model` 线程化 |

## 4. `function_setup()`

```
litellm/utils.py :: function_setup() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 为一次 LLM 调用构建 Logging 对象并做最后参数修正 |
| 参数 | `original_function: str`、`rules_obj: Rules`、`start_time: datetime`、`*args`、`is_async_call: bool`、`**kwargs` |
| 返回 | `tuple[LiteLLMLoggingObject, dict[str, Any]]`（logging_obj, kwargs） |
| 后置 | 返回的 kwargs 可直接交给执行器 |

核心算法：

1. `+22`：`get_applied_guardrails(kwargs)` 收集本次调用命中的 guardrail
2. `+32`：`dynamic_callbacks = kwargs.pop("callbacks", None)`——调用级回调并入
3. 构建 `LiteLLMLoggingObject`：聚合全局回调（`litellm.callbacks`）+ 动态回调 + `success_callback`/`failure_callback` 环境变量回调
4. Google GenAI 适配特判（`contents` 参数形态）

## 5. `async_completion_with_fallbacks()`

```
litellm/litellm_core_utils/fallback_utils.py :: async_completion_with_fallbacks() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | SDK 层回退：主模型失败后逐个试 fallback 模型 |
| 参数 | `**kwargs`（含 `kwargs: dict` 嵌套，里面有 `fallbacks` 列表） |
| 返回 | 第一个成功的 `ModelResponse`（带 `x-litellm-attempted-fallbacks` 头信息） |
| 后置 | 全部失败 → 抛聚合异常（附最后一次错误文本） |

核心算法（`+17` 至 `+80`）：

1. `fallbacks = [original_model] + 嵌套 fallbacks`——主模型是第 0 次尝试
2. 每次尝试 `safe_deep_copy(base_kwargs)`（隔离 dict 型 fallback 的配置污染），dict 型 fallback 弹出 `model` 并 merge 其余键
3. `filter_internal_params` 过滤内部参数
4. `await litellm.acompletion(...)` 递归调用自身入口（此时 fallbacks 已消费，不会无限递归）
5. 成功 → `add_fallback_headers_to_response` 标注尝试次数后返回

注意与 Router fallback 的层次差异：这是「直接调 SDK 时」的回退；走 Proxy 时回退由 Router 层（第四层第 4 篇第 5 节）承担。

## 6. `_resolve_dispatched_chat_response()`

```
litellm/main.py :: _resolve_dispatched_chat_response() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | `acompletion` 的执行结果若是协程，await 它并处理 dispatch 包装 |
| 参数/返回 | 内部协程 → `ModelResponse \| CustomStreamWrapper` |
| 核心算法 | await 后按类型分发（ModelResponse 直接返回；流包装器保持惰性） |
