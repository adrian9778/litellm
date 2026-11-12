# 函数级解析：acompletion 函数族

> 所属层级：第四层（源码补齐） | 覆盖：`litellm/main.py :: acompletion` 及其直接辅助函数

## 0. 一句话定位

`acompletion` 是 litellm SDK 的异步 chat 入口。它本身几乎不做 provider 特有逻辑，而是把同步 `completion()` 打包成 partial 丢进线程池（`run_in_executor`），并处理 fallback 分发、mock 短路、缓存 dict 归一与协程结果 await。主链 12 跳中它是 `route_llm_request.py :: route_request` → `main.py :: acompletion` 之后、执行层之前的那一环（UPDATE-SPEC 事实 8）。

## 1. `acompletion()`

```
litellm/main.py :: acompletion() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | SDK 异步入口：参数规范化 → provider 解析 → fallback 分发 → 线程池执行同步 completion |
| 参数 | 约 60 个显式参数（OpenAI 全集 + litellm 扩展）+ `**kwargs` |
| 返回 | `ModelResponse \| CustomStreamWrapper` |
| 前置 | `litellm` 包已初始化（回调注册、model_cost 已加载） |
| 后置 | 响应已带 `_hidden_params` 元数据；日志事件已发出 |

核心算法（偏移相对 `+0`，行号以 grep 实测为准）：

1. `+97`（行 749）：`fallbacks = kwargs.get("fallbacks", None) or litellm.model_fallbacks`——fallback 列表取值
2. `+110`（行 762）：`loop = asyncio.get_event_loop()`——事件循环句柄，供后续 `run_in_executor` 使用
3. `+249`（行 901）：`custom_llm_provider is None` 时调 `get_llm_provider(...)` 解析 provider
4. `+262`（行 914）：`fallbacks is not None` → `await async_completion_with_fallbacks(**completion_kwargs, kwargs={"fallbacks": fallbacks, **caller_kwargs})` 并直接返回
5. `+273`（行 925 起）：mock 参数短路——`mock_delay = kwargs.get("mock_delay")`，若 `mock_delay and should_run_mock_completion(...)` 则 `await asyncio.sleep(mock_delay)`
6. `+287`（行 939 起）：构造 `partial(completion, **completion_kwargs, **kwargs)`，`contextvars.copy_context()` 保留上下文，`partial(ctx.run, func)` 包成 `func_with_context`，行 945 `await loop.run_in_executor(None, func_with_context)`
7. `+294` 至 `+301`（行 946-953）：返回值归一——`dict` → `_model_response_from_cached_dict(...)`；`ModelResponse` 直接返回；协程 → `await _resolve_dispatched_chat_response(...)`
8. `+307`（行 955）：text-completion provider 响应对象转换（`OpenAITextCompletionConfig().convert_to_chat_model_response_object`）
9. `+320`（行 972 起）：agentic loop 接入点——`maybe_run_chat_completion_agentic_loop`（注释写明这是所有 provider 的汇聚点，OpenAI 走 SDK、其余走共享 httpx handler，此处重汇）
10. 尾部异常统一进 `exception_type(...)` 映射为 litellm 异常

```
调用方 route_request → acompletion(+0)
   ├─ 有 fallbacks ─────────────────────────────► async_completion_with_fallbacks(+0)
   └─ 无 fallbacks
        ├─ mock_delay ──► should_run_mock_completion ──► sleep
        └─ run_in_executor(completion) ──► 同步 completion()
             ├─ dict 结果 ──► _model_response_from_cached_dict(+0)
             └─ 协程结果 ──► await _resolve_dispatched_chat_response(+0)
```

## 2. `get_llm_provider()`

```
litellm/litellm_core_utils/get_llm_provider_logic.py :: get_llm_provider() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | model 字符串 → 四元组。SDK 内被调最频繁的纯函数 |
| 参数 | `model: str`、`custom_llm_provider: str \| None`、`api_base`、`api_key`、`litellm_params` |
| 返回 | `tuple[model, custom_llm_provider, dynamic_api_key, api_base]` |
| 前置 | `model` 非 None |
| 后置 | 无副作用（纯解析） |

核心算法（`+0` 至 `+10`）：

```
get_llm_provider(+0) 只做两件事：
  1. 调 _get_llm_provider(+13) 得到原始四元组
  2. 对 resolved_model 套 resolve_model_latest_alias(...)（最新别名解析）
  返回 (alias_resolved_model, provider, dynamic_api_key, resolved_api_base)
```

实际的 provider 推断、前缀调和都在 `_get_llm_provider()`（`+13` 起）内完成，分岔顺序（偏移相对 `_get_llm_provider` 的 `+0` 定义行 200）：

```
+17   "model is None" → ValueError
+21   LiteLLMProxyConfig.should_use_litellm_proxy_by_default(...) 为真 → litellm_proxy 网关自调用分支
+42   model 前缀 "azure/" 且 is_non_openai_azure_model → 映射为 openai provider
+45   handle_cohere_chat_model_custom_llm_provider / handle_anthropic_text 历史别名修正
+62   custom_llm_provider 与 model 前缀不一致时 model = custom_llm_provider + "/" + model
+72   openrouter 特判（保留原生 "openrouter/*" 或剥成 "anthropic/*"）
后半    无显式前缀时：按 api_base/api_key/env 推断 provider，再查已知模型表
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

`ProviderConfigManager` 类定义在 `utils.py :: ProviderConfigManager`（`+0`，grep 实测 9722）；`get_provider_chat_config` 方法在 `utils.py :: get_provider_chat_config`（`+0`，实测 10028）。

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

核心算法（偏移相对 `+0`，定义行实测 1288）：

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

核心算法（`+0` 至 `+64`，定义行实测 17，全函数 68 行）：

```
+17  函数定义
+17  nested_kwargs = kwargs.pop("kwargs", {})        # 弹嵌套 dict
+19  original_model = kwargs["model"]
+20  fallbacks = [original_model] + nested_kwargs.pop("fallbacks", [])   # 主模型是第 0 次尝试
+21  kwargs.pop("acompletion", None)                 # 防关键字冲突
+22  litellm_call_id = uuid4()
+23  base_kwargs = {**kwargs, **nested_kwargs, "litellm_call_id": ...}
+26  base_kwargs.pop("model", None)                  # model 每轮单独设
+27  litellm_logging_obj = base_kwargs.pop("litellm_logging_obj", None)
+31  循环枚举 fallbacks：
+33      completion_kwargs = safe_deep_copy(base_kwargs)   # 隔离 dict 型 fallback 配置污染
+35      fallback 是 dict → pop("model") 并 merge 其余键；否则 model = fallback
+43      completion_kwargs = filter_internal_params(...)
+45      await litellm.acompletion(**completion_kwargs, model=model, litellm_logging_obj=...)
+       # 递归调自身入口（此时 fallbacks 已消费，不会无限递归）
+51      成功 → add_fallback_headers_to_response(attempted_fallbacks=...) 后返回
+57  全部失败 → raise Exception(最后一次错误文本)
```

模块尾 `completion_with_fallbacks`（`+67`）用 `run_async_function` 把本异步函数同步化。

注意与 Router fallback 的层次差异：这是「直接调 SDK 时」的回退；走 Proxy 时回退由 Router 层（第四层第 4 篇第 5 节）承担。

## 6. `_resolve_dispatched_chat_response()` 与 `_model_response_from_cached_dict()`

```
litellm/main.py :: _resolve_dispatched_chat_response() :: +0
litellm/main.py :: _model_response_from_cached_dict() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | `acompletion` 的执行结果若是协程则 await；若是 dict 则构建 ModelResponse |
| 参数 | `_resolve_dispatched_chat_response(pending: Coroutine)`；`_model_response_from_cached_dict(cached_response_dict: Mapping)` |
| 返回 | `ModelResponse \| CustomStreamWrapper`（前者）；`ModelResponse`（后者） |

核心算法（定义行实测 1018 / 1024）：

```
_resolve_dispatched_chat_response(+0) → 仅 return await pending
_model_response_from_cached_dict(+0) → return ModelResponse(**cached_response_dict)
```

这两个都是极简转发。旧文档描述「await 后按类型分发 ModelResponse/流包装器」已过时：当前实现只透传 await 结果，无类型分派（类型分派在 `acompletion()` 主体 946-953 行完成）。

## 7. 缺 role 消息的行为变化（#51124 BREAKING）

旧版本对缺 role 消息自动补 `role`；现在缺 role 抛 `MissingMessageRoleError`（HTTP 400），不再自动补。校验链（全部锚点已实测）：

```
main.py :: completion() 调用点（+104，行 5668）
  validate_and_fix_openai_messages(messages=..., model=model,
      request_kwargs=_REQUEST_KWARGS_ADAPTER.validate_python(kwargs))   # 签名已加 model/request_kwargs
    └─ litellm/utils.py :: validate_and_fix_openai_messages(+0, 行 9496)
          # 只对"无 role 但含 _ASSISTANT_ONLY_MESSAGE_KEYS"的消息补 role="assistant"（issue #8661）
          # 其余交给下面对每个消息查 role
          └─ validate_chat_completion_user_messages(new_messages, model, request_kwargs)
             └─ litellm/utils.py :: validate_chat_completion_user_messages(+0, 行 9573)
                   # "role" not in m or not m["role"] → raise MissingMessageRoleError(...)
                   # 再校验 user 消息 content 类型（ValidUserMessageContentTypes）
```

异常类层级（litellm/exceptions.py）：

```
BadRequestError
  └─ MalformedRequestFieldError（行 368）
       └─ MissingMessageRoleError（行 372，HTTP 400）
```

`validate_chat_completion_user_messages` 抛错时读 `_deployment_provider({**request_kwargs, "model": model})` 取名 provider。这是 SDK 侧的校验；Proxy 侧的预检链在 03-pre-call/01-proxy-entry 篇详述。