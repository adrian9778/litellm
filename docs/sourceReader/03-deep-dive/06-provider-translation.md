# Provider 翻译层：执行器与 Config 变换

> 所属层级：第三层（主链路拆解） | 拆解对象：第二层场景的跳 10

## 本篇回答的问题

统一参数是怎么变成每个 provider 的私有请求的？响应怎么变回来？两条执行器路径（OpenAI SDK、httpx handler）各自长什么样？

## 执行器二分

| 执行器 | 文件 | 服务对象 |
|---|---|---|
| `OpenAIChatCompletion` | `litellm/llms/openai/openai.py :: OpenAIChatCompletion :: +0`（415 行） | `openai` provider（官方 SDK） |
| `BaseLLMHTTPHandler` | `litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: +0`（719 行） | 绝大多数其他 provider（统一 httpx） |

**注意一个易错事实（架构事实 1）**：openai provider **默认走官方 SDK**（`OpenAIChatCompletion`）。`BaseLLMHTTPHandler` 服务 openai **仅当**环境开关 `EXPERIMENTAL_OPENAI_BASE_LLM_HTTP_HANDLER` 开启（`litellm/main.py :: use_base_llm_http_handler :: +0`，定义 2853 行）时才接管 openai；其余 provider 默认走 httpx handler。

两条路径共享同一套 `ProviderConfig` 翻译接口，这是「API-fragmentation-aware」架构的核心：翻译逻辑集中每个 provider 一个 Config 类，执行器只做调度。

```
main.py :: completion()        # 分发器：按 provider 选执行器
        │
        ├─ custom_llm_provider == openai（默认）
        │        └─ openai.py :: OpenAIChatCompletion（官方 SDK）
        │
        ├─ custom_llm_provider == openai 且 EXPERIMENTAL_OPENAI_BASE_LLM_HTTP_HANDLER=1
        │        └─ llm_http_handler.py :: BaseLLMHTTPHandler
        │
        └─ 其余 provider（默认）
                 └─ llm_http_handler.py :: BaseLLMHTTPHandler（统一 httpx）
```

## ProviderConfig 接口

每个 provider 的 `<provider>/<模态>/transformation.py` 定义一个 Config 类（如 `OpenAIGPTConfig`、`AnthropicConfig`）。基类是 `litellm/llms/base_llm/chat/transformation.py :: BaseConfig :: +0`（定义 91 行，ABC），关键方法：

| 方法 | 职责 | 例（OpenAIGPTConfig，litellm/llms/openai/chat/gpt_transformation.py） |
|---|---|---|
| `transform_request()` | OpenAI 格式 → provider 请求体 + 头 | 680 行 |
| `async_transform_request()` | 异步版（部分 provider 需要，如取 token） | 724 行 |
| `transform_response()` | provider 响应 → ModelResponse | 866 行 |
| `get_complete_url()` | 拼 endpoint URL | 922 行 |
| `validate_environment()` | 检查凭证齐全，返回含 key 的头 | 950 行 |
| `map_openai_params()` | OpenAI 参数名 → provider 参数名 | 338 行 |
| `get_supported_openai_params()` | 该 provider 支持哪些 OpenAI 参数 | 262 行 |
| `sign_request()` | AWS 等请求签名（`SignsRequestsWithAWS`） | 基类 325 行 |
| `transform_request_on_unprocessable_entity_error()` | 422 时重造请求体 | 基类 228 行 |
| `should_retry_llm_api_inside_llm_translation_on_http_error()` | HTTP 错误是否在翻译层内重试 | 基类 218 行 |

基类里这些方法（`get_complete_url` 350 行、`transform_request` 371 行、`transform_response` 403 行等）多为占位/抛 `NotImplementedError`，具体行为由子类覆写。

## 路径 A：OpenAI SDK（本场景）

```
litellm/llms/openai/openai.py :: OpenAIChatCompletion :: completion :: +0（同步入口 716 行）
litellm/llms/openai/openai.py :: OpenAIChatCompletion :: acompletion :: +0（异步入口 967 行）
litellm/llms/openai/openai.py :: make_openai_chat_completion_request :: +0（550 行）
litellm/llms/openai/openai.py :: make_sync_openai_chat_completion_request :: +0（606 行）
```

流程（同步 `completion` 716-911 行，异步 `acompletion` 967 行起）：

1. 解析 `provider_config`（`get_provider_chat_config`，OpenAI 特判 O-series/GPT-5/未知 catalog），未命中回退 `OpenAIConfig`（749-759 行）；
2. `completion` 里 `acompletion=True` 且 `stream=True` 走 `async_streaming`（785 行），否则走 `acompletion`（805 行）；`stream=True`（同步）走 `streaming`（834 行）；
3. 变换请求体：同步用 `provider_config.transform_request(...)`（826 行），异步 `acompletion` 用 `await provider_config.async_transform_request(...)`（990 行）——OpenAI 格式本身近乎透传，主要工作是参数清洗；
4. 构造/复用客户端：`_get_openai_client`（openai.py 430 行起），`client` 由 kwargs 控制复用，内部走 `get_cached_openai_client` 缓存（453 行）；workload identity 优先（`AsyncOpenAI(workload_identity=...)` 464-482 行）；
5. 调 SDK：同步 `make_sync_openai_chat_completion_request`（880 行）——内部经 `_request_without_sdk_transform`（openai.py 400 行）+ `openai_client.post("/chat/completions", ...)`（622 行）直接 POST，而非 `chat.completions.create` 语法糖；异步 `make_openai_chat_completion_request`（550 行，`acompletion` 内 1025 行调用）同样 `openai_aclient.post("/chat/completions", ...)`（566 行），`stream` 时用 `AsyncStream[ChatCompletionChunk]`（572 行）；
6. 返回 SDK `ChatCompletion` → `convert_to_model_response_object`（同步 898 行、异步 1041 行，从 `litellm_core_utils` 导入）转成 `ModelResponse`；
7. 异常：`openai.UnprocessableEntityError` 在 912 行捕获，`drop_params` 时重试；其余走 openai 异常映射。

## 路径 B：统一 httpx handler

```
litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: async_completion :: +0（820 行）
litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: completion :: +0（893 行）
litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: acompletion_stream_function :: +0（1235 行）
litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: make_sync_call :: +0（1156 行）
litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: make_async_call_stream_helper :: +0（1295 行）
```

**正名**：旧文档写 `async_completion_handler` 从不存在（BASE/tip 均无），本基线方法名是 `async_completion`（820 行）。

以 `completion`（893 行起）为例，它是同步/异步的统一入口（`acompletion` 标志区分）。核心顺序：

```
completion()（893 行）
  1. provider_config = get_provider_chat_config(...)        # 917 行
  2. fake_stream 判定（should_fake_stream）                  # 923 行
  3. request_headers = provider_config.validate_environment(...)  # 930 行
  4. api_base = provider_config.get_complete_url(...)        # 943 行
  5. sign_and_log(transformed) 闭包（952 行）:
        data = transformed + transform_extra_body(...)        # 955-964 行
        signed = provider_config.sign_request(...)            # 965 行（AWS 走 run_aws_signing）
        logging_obj.pre_call(...)                             # 981 行
        → (data, signed_headers, signed_json_body)
  6. 变换请求体：
        acompletion 且 uses_async_transform_request:
            await provider_config.async_transform_request(...)  # 1048 行
        else:
            provider_config.transform_request(...)              # 1066 行
  7. 分支：
        acompletion → dispatch_async（994 行）→ acompletion_stream_function / async_completion
        stream      → _add_stream_param_to_request_body + make_sync_call → CustomStreamWrapper
        sync        → _make_common_sync_call → transform_response
```

`async_completion`（820 行）是异步非流式路径：`_make_common_async_call`（853 行）发请求 → `provider_config.transform_response`（865 行）→ `_call_agentic_chat_completion_hooks`（880 行）→ 返回 `ModelResponse`。

`_make_common_async_call`（720 行）与同步版 `_make_common_sync_call`（770 行）是真正的 HTTP 发送与错误处理：`async_httpx_client.post(url=api_base, ...)`（739 行），在 `httpx.HTTPStatusError` 时查 `provider_config.should_retry_llm_api_inside_llm_translation_on_http_error`（749 行），命中则 `transform_request_on_unprocessable_entity_error` 重造请求体重试（753 行），最多 `max_retry_on_unprocessable_entity_error` 次（737 行循环）；其余异常交 `_handle_error`（6705 行）映射。

流式分支（本篇预览，详细见第三层第 7 篇）：

- `acompletion_stream_function`（1235 行）：provider 有自己的异步流包装器时走 `get_async_custom_stream_wrapper`（1254 行），否则 `make_async_call_stream_helper`（1269 行）→ 外部包 `CustomStreamWrapper`（1286 行）；
- 同步 `completion` 内 `stream=True` 时 `make_sync_call`（1099 行）→ `CustomStreamWrapper`（1116 行）。

## 一个具体例子：Anthropic 的翻译

对照 OpenAI，看非透传 provider 的翻译有多重（第三层后续篇与第四层会反复用到 Anthropic 作为例子）：

```
OpenAI 入参:  messages=[{"role":"system","content":"..."},{"role":"user","content":"hi"}], max_tokens=100
Anthropic 请求体:
{
  "system": "...",                    ← system 从 messages 里抽出，单独字段
  "messages": [{"role":"user","content":"hi"}],
  "max_tokens": 100,                  ← Anthropic 必填，litellm 会兜底默认值
  "model": "claude-sonnet-4-5"
}
头: x-api-key + anthropic-version
URL: https://api.anthropic.com/v1/messages
```

这套变换的实现在 `litellm/llms/anthropic/chat/transformation.py :: AnthropicConfig :: transform_request :: +0`，函数级拆解在第四层第 7 篇。

## 响应回程

| 路径 | 响应入口 | 转换器 |
|---|---|---|
| OpenAI SDK | SDK `ChatCompletion` | `convert_to_model_response_object`（`litellm_core_utils`） |
| httpx handler | httpx `Response` | `provider_config.transform_response` |

转换后统一是 `ModelResponse`（Pydantic，OpenAI schema）。`transform_response` 同时把 provider 特有的元数据（如 headers、raw 响应）写进 `_hidden_params`，这正是第三层第 8 篇提取 `response_cost` 的数据源。

## 流式分支预览

`stream=True` 时：

- OpenAI SDK 路径：SDK 返回事件流，`OpenAIChatCompletionResponseIterator`（`litellm/llms/openai/openai.py :: OpenAIChatCompletionResponseIterator :: +0`，371 行）逐 chunk 转换；
- httpx 路径：handler 返回 provider 流迭代器，外面包一层 `CustomStreamWrapper`（`litellm_core_utils/streaming_handler.py :: CustomStreamWrapper :: +0`）统一做 usage 聚合、时间统计、guardrail。

详细拆解见第三层第 7 篇。

## 失败的统一出口

无论哪条路径，provider 的 HTTP 错误都进入异常映射层：`litellm/litellm_core_utils/exception_mapping_utils.py :: exception_mapping_worked() 一族`，把 401/429/500/超时翻译成 litellm 异常类型（`AuthenticationError`、`RateLimitError`…），Router 的重试层据此分类决策。