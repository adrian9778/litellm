# 函数级解析：BaseLLMHTTPHandler

> 所属层级：第四层（源码补齐） | 覆盖：`litellm/llms/custom_httpx/llm_http_handler.py`（1.4 万行）的关键方法

## 1. `completion()`

```
litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: completion() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 同步统一执行器：翻译 → 发送 → 翻译（全 provider 共用） |
| 参数 | `model`、`messages`、`api_base`、`custom_llm_provider`、`model_response`、`encoding`、`logging_obj`、`optional_params`、`timeout`、`litellm_params`、`acompletion: bool`、`stream`、`api_key`、`headers`、`client`、`provider_config`、`shared_session` |
| 返回 | `ModelResponse`（非流）或 `CustomStreamWrapper`（流） |
| 前置 | `provider_config` 已解析（None 时内部补解析，`+97`），logging_obj 已就位 |
| 后置 | 日志 post_call 已触发；`_hidden_params` 已填充 |

核心算法（偏移相对 `+0`）：

1. `+22` 至 `+33`：`optional_params` 预处理（`json_mode`、`extra_body`、`fake_stream` 弹出）
2. `+39`：`provider_config.validate_environment(...)` 取凭证与默认头
3. `+50`：`provider_config.get_complete_url(...)` 拼 URL
4. `+59`：`sign_and_log` 内嵌函数定义（`+927`），`+172` 处调用产出 `(data, signed_headers, signed_json_body)`
5. `+206`：流式判断——`stream=True` 走 `make_sync_call`（`+1131`）拿流迭代器再包 `CustomStreamWrapper`
6. `+238`：非流式 `_make_common_sync_call`（`+745`）发请求，随后 `provider_config.transform_response` 转换

注意参数名的翻译（`map_openai_params`）不发生在 handler 里：chat 的 OpenAI 参数校验与映射在 `main.completion()` 内经 `litellm/utils.py :: get_optional_params() :: +0`（5505 行处，`main.py:6042` 一带调用）完成后才传入。

## 2. `async_completion()`

```
litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: async_completion() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 异步统一执行器（结构同 `completion()`，io 全异步） |
| 参数 | 显式列表（见源码 `+0 至 +20`）：`custom_llm_provider`、`provider_config`、`api_base`、`headers`、`data`、`timeout`、`model`、`model_response`、`logging_obj`、`messages`、`optional_params`、`litellm_params`、`encoding`、`api_key`、`client: AsyncHTTPHandler \| None`、`json_mode`、`signed_json_body`、`shared_session` |
| 返回 | `ModelResponse` |
| 前置 | 与 `completion()` 相同 |

核心算法（`+0` 至 `+75`）：

1. `+21`：client 缺省时 `get_async_httpx_client(...)`——按 provider 取连接池复用的客户端（`ssl_verify`、`shared_session` 透传）
2. `+35`：`_make_common_async_call(stream=False, ...)` 发送
3. `+46`：`provider_config.transform_response(...)` 得 `initial_response`
4. `+72`：`return final_response if final_response is not None else initial_response`（final_response 允许 provider config 后处理替换）

## 3. `_make_common_async_call()`

```
litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: _make_common_async_call() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 「发一次 HTTP」的完整细节：URL、头、body、重试一次 4xx 自愈、异常映射 |
| 参数 | `async_httpx_client`、`provider_config`、`api_base`、`headers`、`data`、`timeout`、`litellm_params`、`stream: bool`、`logging_obj`、`signed_json_body` |
| 返回 | httpx `Response`（非流）或流对象 |

核心算法（`+0` 至 `+100`）：

1. URL 组装：`provider_config.get_complete_url(api_base, ...)`，query 参数由 config 决定
2. body：优先用预签名的 `signed_json_body`，否则 `json.dumps(data)`
3. 发送后状态检查：非 2xx 时先读 body 再抛（错误详情保真）
4. 422/400 自愈（`+32` 与 `+82` 两处）：捕获 `UnprocessableEntityError` 族 → `provider_config.transform_request_on_unprocessable_entity_error(e, request_data)` 重造请求 → 重发一次
5. 异常统一进 `exception_mapping_worked` 一族，映射为 litellm 异常类型后抛出

## 4. `make_sync_call()` / `make_async_call_stream_helper()`

```
litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: make_sync_call() :: +0（1131 行处）
litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: make_async_call_stream_helper() :: +0（1270 行处）
```

| 项 | 内容 |
|---|---|
| 职责 | 流式分支的发送：返回原始字节流迭代器 |
| 返回 | `tuple[迭代器, headers]` |
| 核心算法 | httpx `stream=True` 请求；`iter_bytes()` 逐块 yield；首字节前超时受 `timeout` 控制；连接中断转 `litellm.APIConnectionError` |

## 5. `transform_response()` 的职责边界（以 OpenAIGPTConfig 为参照）

```
litellm/llms/openai/chat/gpt_transformation.py :: OpenAIGPTConfig :: transform_response() :: +0（831 行处）
```

| 项 | 内容 |
|---|---|
| 参数 | `model`、`response: httpx.Response`、`model_response`、`logging_obj`、`api_key`、`request_data`、`litellm_params`、`encoding` |
| 返回 | `ModelResponse` |
| 核心算法 | `response.json()` → `convert_to_model_response_object(...)` → usage/finish_reason 归一 → `_hidden_params` 填充（api_base、model_id、响应头） |
| 错误处理 | 响应体不是合法 JSON / 缺 choices → 转 `litellm.APIConnectionError` 或对应 provider 异常 |

## 6. 客户端复用

```
litellm/llms/custom_httpx/async_client_creation.py（get_async_httpx_client 等）
```

按 provider 维护连接池级单例；`client` 参数允许调用方注入自己的实例（Router 场景按 deployment 复用）。这是 Gateway 高并发下不泄露连接的关键。
