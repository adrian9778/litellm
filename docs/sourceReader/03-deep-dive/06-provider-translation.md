# Provider 翻译层：执行器与 Config 变换

> 所属层级：第三层（主链路拆解） | 拆解对象：第二层场景的跳 10

## 本篇回答的问题

统一参数是怎么变成每个 provider 的私有请求的？响应怎么变回来？两条执行器路径（OpenAI SDK、httpx handler）各自长什么样？

## 执行器二分

| 执行器 | 文件 | 服务对象 |
|---|---|---|
| `OpenAIChatCompletion` | `litellm/llms/openai/openai.py :: OpenAIChatCompletion :: +405` | `openai` provider（官方 SDK） |
| `BaseLLMHTTPHandler` | `litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: +694` | 绝大多数其他 provider（统一 httpx） |

两条路径共享同一套 `ProviderConfig` 翻译接口，这是「API-fragmentation-aware」架构的核心：翻译逻辑集中每个 provider 一个 Config 类，执行器只做调度。

## ProviderConfig 接口

每个 provider 的 `<provider>/<模态>/transformation.py` 定义一个 Config 类（如 `OpenAIGPTConfig`、`AnthropicConfig`），关键方法：

| 方法 | 职责 | 例（OpenAIGPTConfig） |
|---|---|---|
| `transform_request()` | OpenAI 格式 → provider 请求体 + 头 | `gpt_transformation.py :: transform_request :: +0` |
| `async_transform_request()` | 异步版（部分 provider 需要，如取 token） | 同文件 `+687` |
| `transform_response()` | provider 响应 → ModelResponse | `gpt_transformation.py :: transform_response :: +0` |
| `get_complete_url()` | 拼 endpoint URL | Config 类内 |
| `validate_environment()` | 检查凭证齐全，返回含 key 的头 | Config 类内 |
| `map_openai_params()` | OpenAI 参数名 → provider 参数名 | Config 类内 |
| `get_supported_openai_params()` | 该 provider 支持哪些 OpenAI 参数 | Config 类内 |

## 路径 A：OpenAI SDK（本场景）

```
litellm/llms/openai/openai.py :: OpenAIChatCompletion :: completion() :: +0（同步路径）
```

流程：

1. `validate_environment` 确保 `OPENAI_API_KEY` 就位
2. 构造/复用 `openai.OpenAI` 客户端（客户端复用由 kwargs 里的 `client` 参数控制）
3. 调 SDK：默认 `chat.completions.create`，需要响应头时用 `create.with_raw_response` 变体（类内 SDK 调用辅助方法的 docstring 写明这两种模式，`openai.py :: OpenAIChatCompletion :: make_call 类辅助 :: +0`）
4. SDK 返回 `ChatCompletion` 对象 → `convert_to_model_response_object`（`litellm_core_utils` 的转换器）转成 `ModelResponse`
5. 异常走 SDK 异常捕获 → 统一异常映射

OpenAI 格式本身无需翻译，这条路的主要工作是凭证、客户端生命周期、参数归一。

## 路径 B：统一 httpx handler

```
litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: completion() :: +0
litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: async_completion() :: +0
```

以异步版为例（`async_completion` 的内部顺序，`+0 至 +150`）：

```
1. provider_config.transform_request(...)          # OpenAI dict → provider 请求体
   （uses_async_transform_request=True 时改走 async_transform_request，+1018 相对处）
2. get_complete_url(...)                            # 拼 URL（+918 相对处）
3. sign_and_log(...)                                # 请求签名与审计日志
4. make_async_call(...)                             # httpx.AsyncClient 发送
5. 非 2xx → raise_for_status 前先读 body，交异常映射
6. provider_config.transform_response(...)          # → ModelResponse（+840 相对处）
```

同步版 `completion()` 结构相同（`transform_request` 在 `+1041` 相对处、`make_sync_call` 等），额外处理 `stream` 分支：流式时返回 `completion_stream` 包装器而不是一次性 `ModelResponse`。

**422/400 自愈细节**：`_make_common_async_call`（`+695`）在 provider 拒绝请求体时调用 `transform_request_on_unprocessable_entity_error` 重造请求再试一次（`+728`、`+778` 两处）。

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

这套变换的实现在 `litellm/llms/anthropic/chat/transformation.py :: AnthropicConfig :: transform_request() :: +0`，函数级拆解在第四层第 7 篇。

## 响应回程

| 路径 | 响应入口 | 转换器 |
|---|---|---|
| OpenAI SDK | SDK `ChatCompletion` | `convert_to_model_response_object`（`litellm_core_utils`） |
| httpx handler | httpx `Response` | `provider_config.transform_response` |

转换后统一是 `ModelResponse`（Pydantic，OpenAI schema）。`transform_response` 同时把 provider 特有的元数据（如 headers、raw 响应）写进 `_hidden_params`，这正是第三层第 8 篇提取 `response_cost` 的数据源。

## 流式分支预览

`stream=True` 时：

- OpenAI SDK 路径：SDK 返回事件流，`OpenAIChatCompletionResponseIterator`（`litellm/llms/openai/openai.py :: OpenAIChatCompletionResponseIterator :: +0`）逐 chunk 转换
- httpx 路径：handler 返回 provider 流迭代器，外面包一层 `CustomStreamWrapper`（`litellm_core_utils/streaming_handler.py :: CustomStreamWrapper :: +0`）统一做 usage 聚合、时间统计、guardrail

详细拆解见第三层第 7 篇。

## 失败的统一出口

无论哪条路径，provider 的 HTTP 错误都进入异常映射层：`litellm/litellm_core_utils/exception_mapping_utils.py :: exception_mapping_worked() 一族`，把 401/429/500/超时翻译成 litellm 异常类型（`AuthenticationError`、`RateLimitError`…），Router 的重试层据此分类决策。
