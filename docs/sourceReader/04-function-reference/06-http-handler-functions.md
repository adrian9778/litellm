# 函数级解析：BaseLLMHTTPHandler

> 所属层级：第四层（源码补齐） | 覆盖：`litellm/llms/custom_httpx/llm_http_handler.py`（1.4 万行）的 `BaseLLMHTTPHandler` 关键方法

## 0. 一句话定位

`BaseLLMHTTPHandler` 是 litellm 的共享同步/异步 HTTP 执行器：把「翻译请求 → 发 HTTP → 翻译响应」做成 provider 无关的统一链路。关键事实（UPDATE-SPEC 事实 1）：**openai provider 默认不走它**，而是走官方 SDK（`litellm/llms/openai/openai.py :: OpenAIChatCompletion`）；只有当环境变量 `EXPERIMENTAL_OPENAI_BASE_LLM_HTTP_HANDLER` 开启（`litellm/main.py :: use_base_llm_http_handler`，行 2853）时才服务 openai，其余 provider 默认走它。**`async_completion_handler` 从不存在**，旧文档若引用该名一律改为 `async_completion`。

```
provider 默认路由：
  openai ─► OpenAIChatCompletion（openai.py :: completion，行 716）——官方 SDK
  openai + EXPERIMENTAL_OPENAI_BASE_LLM_HTTP_HANDLER ─► BaseLLMHTTPHandler.completion（行 893）
  其余 provider ─► base_llm_http_handler.completion（实例在 llm_http_handler.py 行 395）
```

## 1. `completion()`

```
litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: completion() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 同步统一执行器：翻译 → 发送 → 翻译（全 provider 共用） |
| 参数 | `model`、`messages`、`api_base`、`custom_llm_provider`、`model_response`、`encoding`、`logging_obj`、`optional_params`、`timeout`、`litellm_params`、`acompletion: bool`、`stream`、`fake_stream`、`api_key`、`headers`、`client`、`provider_config`、`shared_session` |
| 返回 | `ModelResponse`（非流）或 `CustomStreamWrapper`（流）或协程（`acompletion=True` 时） |
| 前置 | `provider_config` 已解析（None 时内部补解析，`+24`） |
| 后置 | 日志 post_call 已触发；`_hidden_params` 已填充 |

核心算法（偏移相对 `+0`，定义行实测 893，grep 交叉核对）：

1. `+21`：`json_mode`/`extra_body` 从 `optional_params` 弹出
2. `+24`：`provider_config = provider_config or ProviderConfigManager.get_provider_chat_config(...)`，None 时抛 `ValueError`
3. `+30`：`fake_stream` 判定（显式 / optional_params / `provider_config.should_fake_stream`）
4. `+37`：`provider_config.validate_environment(...)` 取凭证与默认头
5. `+50`：`provider_config.get_complete_url(...)` 拼 URL
6. `+59`：`sign_and_log` 内嵌函数定义（`+0`），内部 `transform_extra_body` + `sign_request`（AWS 签名）+ `logging_obj.pre_call`，产出 `(data, signed_headers, signed_json_body)`
7. `+101`：`dispatch_async` 内嵌定义——`stream=True` 走 `acompletion_stream_function`（`+1`），否则 `async_completion`（`+0`）
8. `+150`：`acompletion is True and provider_config.uses_async_transform_request` → 返回 `transform_then_dispatch()` 协程（先 `async_transform_request` 再签名再 dispatch）
9. `+172`：`sign_and_log(provider_config.transform_request(...))` 产出三元组
10. `+182`：`acompletion is True` → `return dispatch_async(...)`（协程，供 acompletion 层 await）
11. `+185`：`stream is True` → `_add_stream_param_to_request_body` 补 body；`has_custom_stream_wrapper` 时返回 provider 的同步自定义流包装，否则 `make_sync_call`（`+0`）拿流迭代器再包 `CustomStreamWrapper`
12. `+238`：非流式 `_make_common_sync_call`（`+0`）发请求，随后 `provider_config.transform_response` 转换

```
completion(+0)
  ├─ acompletion=True + async_transform → transform_then_dispatch() 协程
  ├─ acompletion=True → dispatch_async → stream? acompletion_stream_function | async_completion
  ├─ stream=True → make_sync_call → CustomStreamWrapper
  └─ 非流 → _make_common_sync_call → transform_response
```

注意参数名的翻译（`map_openai_params`）不发生在 handler 里：chat 的 OpenAI 参数校验与映射在 `main.completion()` 内经 `litellm/utils.py :: get_optional_params() :: +0` 完成后才传入。

## 2. `async_completion()`

```
litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: async_completion() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 异步统一执行器（非流分支的异步发送） |
| 参数 | `custom_llm_provider`、`provider_config`、`api_base`、`headers`、`data`、`timeout`、`model`、`model_response`、`logging_obj`、`messages`、`optional_params`、`litellm_params`、`encoding`、`api_key`、`client: AsyncHTTPHandler \| None`、`json_mode`、`signed_json_body`、`shared_session` |
| 返回 | `ModelResponse` |
| 前置 | 与 `completion()` 相同 |

核心算法（定义行实测 820，grep 交叉核对）：

1. `+21`：client 缺省时 `get_async_httpx_client(...)`（按 provider 取连接池复用客户端，`ssl_verify`、`shared_session` 透传）
2. `+33`：`await self._make_common_async_call(stream=False, ...)` 发送
3. `+45`：`provider_config.transform_response(...)` 得 `initial_response`
4. `+60`：`await self._call_agentic_chat_completion_hooks(...)` 得 `final_response`
5. `+71`：`return final_response if final_response is not None else initial_response`

## 3. `_make_common_async_call()` 与 `_make_common_sync_call()`

```
litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: _make_common_async_call() :: +0
litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: _make_common_sync_call() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 「发一次 HTTP」的完整细节：URL、头、body、重试一次 4xx 自愈、异常映射 |
| 参数 | `*_httpx_client`、`provider_config`、`api_base`、`headers`、`data`、`timeout`、`litellm_params`、`stream: bool`、`logging_obj`、`signed_json_body` |
| 返回 | httpx `Response` |

核心算法（`_make_common_async_call` 定义行实测 720，`_make_common_sync_call` 定义行实测 770；两函数结构相同）：

```
+0   定义
+14  max_retry_on_unprocessable_entity_error = provider_config.max_retry_on_unprocessable_entity_error
+17  循环 range(max(retry, 1))：
+19      httpx_client.post(url=api_base, headers=headers,
              data=(signed_json_body or json.dumps(data)), timeout, stream, logging_obj)
+27      except httpx.HTTPStatusError:
              should_retry = provider_config.should_retry_llm_api_inside_llm_translation_on_http_error(e, litellm_params)
              if should_retry and not hit_max_retry:
                  data = provider_config.transform_request_on_unprocessable_entity_error(e, data)   # 重造请求
                  continue
              else: raise self._handle_error(e, provider_config)
+37      except Exception: raise self._handle_error(...)
+41      break
+43  response is None → provider_config.get_error_class("No response...", status_code=422)
```

- body 优先用预签名的 `signed_json_body`，否则 `json.dumps(data)`
- 422/400 自愈在 `except httpx.HTTPStatusError` 分支：命中 `should_retry` 且未达上限时重造请求重发一次
- 异常统一进 `self._handle_error` 映射为 litellm 异常类型后抛出

## 4. `acompletion_stream_function()` / `make_async_call_stream_helper()` / `make_sync_call()`

```
litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: acompletion_stream_function() :: +0
litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: make_async_call_stream_helper() :: +0
litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: make_sync_call() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 流式分支的发送：返回原始字节流迭代器 |
| 返回 | `tuple[迭代器, headers]` |
| 核心算法 | httpx `stream=True` 请求；`iter_bytes()`/`aiter_text()` 逐块 yield；首字节前超时受 `timeout` 控制；连接中断转 `litellm.APIConnectionError` |

- `acompletion_stream_function`（定义行实测 1235）：`has_custom_stream_wrapper` 时返回 provider 的异步自定义流包装；否则调 `make_async_call_stream_helper` 拿流迭代器，包 `CustomStreamWrapper` 返回
- `make_async_call_stream_helper`（定义行实测 1295）：client 缺省时 `get_async_httpx_client`；`fake_stream=True` 时 `stream=False` 并转成 `MockResponseIterator`（先 `transform_response` 得整包响应），否则 `provider_config.get_model_response_iterator_for_request(aiter_sse_lines(response.aiter_text()))`；`logging_obj.post_call` 后返回 `(completion_stream, response.headers)`
- `make_sync_call`（定义行实测 1156）：同步侧等价物，返回字节流迭代器 + headers

```
completion(+0) 流式分支
  acompletion=True ─► acompletion_stream_function(+0)
       ├─ has_custom_stream_wrapper → provider 异步自定义包装
       └─ make_async_call_stream_helper(+0)
            ├─ fake_stream → MockResponseIterator（非真流）
            └─ get_model_response_iterator_for_request(aiter_sse_lines) → BaseModelResponseIterator
  sync ─► make_sync_call(+0) ─► CustomStreamWrapper
```

## 5. `transform_request()` / `transform_response()` 的职责边界（以 OpenAIGPTConfig 为参照）

```
litellm/llms/openai/chat/gpt_transformation.py :: OpenAIGPTConfig :: transform_request() :: +0
litellm/llms/openai/chat/gpt_transformation.py :: OpenAIGPTConfig :: transform_response() :: +0
```

| 项 | 内容 |
|---|---|
| `transform_request`（定义行实测 680） | 参数 `model/messages/optional_params/litellm_params/headers`；`_transform_messages` + `_messages_and_tools_in_cache_mark_dialect` 重排消息，归一 tools，返回 `{"model", "messages", **optional_params, ...}` 作为 HTTP body |
| `transform_response`（定义行实测 866） | 参数含 `model/raw_response: httpx.Response/model_response/...`；`response.json()` → `convert_to_model_response_object(...)` → usage/finish_reason 归一 → `_hidden_params` 填充（api_base、model_id、响应头） |
| 错误处理 | 响应体不是合法 JSON / 缺 choices → 转 `litellm.APIConnectionError` 或对应 provider 异常 |

`transform_request` 返回的 dict 正是 `completion()` 中传给 `sign_and_log`、继而作为 body 的 `data`。注意 OpenAIGPTConfig 是 `BaseLLMModelInfo` 子类，其 `async_transform_request`（`+44`）在 `uses_async_transform_request` 为真时被 `completion()` 的 `transform_then_dispatch` 分支调用。

## 6. 客户端复用

```
litellm/llms/custom_httpx/http_handler.py :: get_async_httpx_client() :: +0
litellm/llms/custom_httpx/http_handler.py :: get_httpx_client() :: +0
```

按 provider 维护连接池级单例；`client` 参数允许调用方注入自己的实例（Router 场景按 deployment 复用）。`get_async_httpx_client` 定义行实测 1972。这是 Gateway 高并发下不泄露连接的关键。