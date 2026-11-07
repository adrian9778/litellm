# 函数级解析：Provider 变换函数（以 AnthropicConfig 为例）

> 所属层级：第四层（源码补齐） | 覆盖：`litellm/llms/anthropic/chat/transformation.py :: AnthropicConfig`

选 Anthropic 做例子的原因：它是「翻译最重」的典型（system 抽离、thinking 块、prompt cache、tool 循环），吃透它就掌握了所有非透传 provider 的变换模式。OpenAI 那类透传 provider 的 Config 只覆盖能力矩阵与少量特判。

## 0. 类定义

```
litellm/llms/anthropic/chat/transformation.py :: AnthropicConfig :: +0
```

继承 `AnthropicModelInfo, BaseConfig`（`BaseConfig` 定义在 `litellm/llms/base_llm/chat/transformation.py :: BaseConfig :: +0`；`AnthropicModelInfo` 在 `litellm/llms/anthropic/common_utils.py :: AnthropicModelInfo :: +0`）。无实例状态，方法是纯变换。

## 1. `get_supported_openai_params()`

```
litellm/llms/anthropic/chat/transformation.py :: AnthropicConfig :: get_supported_openai_params() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 声明该 provider 接受哪些 OpenAI 参数（能力矩阵） |
| 返回 | `list[str]` |
| 核心算法 | 基础列表（`stream`、`stop`、`temperature`、`top_p`、`max_tokens`、`tools`、`response_format`、`cache_control` 等 16 项，见 `+2` 至 `+22`）；按模型能力动态追加：`thinking`/`reasoning_effort` 仅当模型名含 `claude-3-7-sonnet` 或 `supports_reasoning()` 为真（`+25` 至 `+37`）；`service_tier` 按 provider 集合（`+39`） |

消费方：`get_optional_params`（`litellm/utils.py :: get_optional_params() :: +0`）拿它决定「传了不支持的参数怎么办」。

## 2. `map_openai_params()`

```
litellm/llms/anthropic/chat/transformation.py :: AnthropicConfig :: map_openai_params() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | OpenAI 参数名/值 → Anthropic 参数名/值 |
| 核心算法 | 逐参数映射：`max_tokens` 必填兜底（Anthropic 强制，缺失时 litellm 填默认）；`stop` → `stop_sequences`；`response_format` → JSON mode 的 tool schema 或 `output_format`；`thinking`/`reasoning_effort` → Anthropic thinking 配置；不认识的原样保留或按 `drop_params` 丢弃 |

## 3. `transform_request()`

```
litellm/llms/anthropic/chat/transformation.py :: AnthropicConfig :: transform_request() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | OpenAI 消息格式 → Anthropic `/v1/messages` 请求体 |
| 参数 | `model`、`messages`、`optional_params`、`litellm_params`、`headers` |
| 返回 | Anthropic 请求体 dict（调用方还会经 `get_complete_url` + `validate_environment` 组装完整 HTTP 请求） |
| 前置 | `map_openai_params` 已跑完（`optional_params` 已是 Anthropic 形） |
| 后置 | 无副作用 |

核心算法（偏移相对 `+0`，均为真实代码顺序）：

1. `+13`：docstring 写明的自愈规则——messages 含 tool 块但没带 `tools` 时注入 dummy tool（不需要 `modify_params` 开关）
2. `+28`：prompt cache 断点翻译（`translates_prompt_cache_breakpoint(model)` 时处理 cache_control）
3. `+41`：`if "tools" not in optional_params and has_tool_call_blocks(capped_messages):` 注入 dummy tool
4. `+44` 至 `+60`：thinking 一致性清理——`thinking` 开启但 assistant 消息缺 `thinking_blocks` 时丢弃 thinking 参数（仅当整段对话没有任何 thinking 块），且仅在 `litellm.modify_params` 时打警告
5. `+110`：`split_leading_system_run(request_messages)`——只把**开头连续**的 system 消息提升为顶层 `system` 字段；中段的 system 消息保持原位（注释解释：提升会改写缓存前缀）
6. `+112`：`optional_params["system"] = anthropic_system_message_list`
7. `+117`：中段 system 的位置处理（按模型是否支持 mid-conversation system 分支）
8. `+129`：`anthropic_messages_pt(...)`（`litellm/litellm_core_utils/prompt_templates/factory.py :: anthropic_messages_pt :: +0`）做消息体逐条翻译（role/content/tool_use/tool_result 九种块）
9. `+151`：`strip_advisor_blocks_from_messages` 清理非 Anthropic 块

## 4. `transform_response()`

```
litellm/llms/anthropic/chat/transformation.py :: AnthropicConfig :: transform_response() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | Anthropic 响应 JSON → `ModelResponse`（OpenAI 形） |
| 参数 | `model`、`response`（httpx 响应）、`model_response`、`logging_obj`、`api_key`、`request_data`、`litellm_params`、`encoding` |
| 返回 | `ModelResponse` |
| 后置 | usage（含 cache 读写 token）、stop_reason 映射（`end_turn`→`stop`、`max_tokens`→`length`、`tool_use`→`tool_calls`）进结果 |

核心算法：主体委托给 `transform_parsed_response(...)`（`+40` 附近），传入 `tool_name_reverse_map`（请求期注册的工具名映射，处理 Anthropic 工具名长度截断）与 json mode 的 schema。JSON mode 特殊处理：Anthropic 把 schema 响应当 tool call 返回，`_convert_tool_response_to_message()`（静态方法，`+50` 附近定义）把它转回普通 message（参数 `response_format_schema` 支持 schema 切分答案）。

## 5. `validate_environment()`

```
litellm/llms/anthropic/common_utils.py :: AnthropicModelInfo :: validate_environment() :: +0（AnthropicConfig 经继承获得）
```

| 项 | 内容 |
|---|---|
| 职责 | 凭证检查 + 组装认证头 |
| 返回 | `dict`（含 `x-api-key` 与 `anthropic-version` 头，缺凭证时抛 `AuthenticationError`） |
| 核心算法 | key 来源链：显式 `api_key` → env `ANTHROPIC_API_KEY` → 可选 token 交换（OAuth/OBO 场景） |

## 6. URL 的真实来源

`AnthropicConfig` **不覆写** `get_complete_url`，用的是 `BaseConfig` 默认实现（`litellm/llms/base_llm/chat/transformation.py :: BaseConfig :: get_complete_url() :: +0`：api_base 为空抛 ValueError，否则原样返回）。URL 在更早的 `main.completion()` anthropic 分支就解析完毕（`litellm/main.py :: completion() :: anthropic 分支`）：

- 默认 `https://api.anthropic.com/v1/messages`
- env `ANTHROPIC_API_BASE` / `ANTHROPIC_BASE_URL` 可覆盖
- `ensure_api_route(api_base, "v1/messages")` 自动补后缀；`LITELLM_ANTHROPIC_DISABLE_URL_SUFFIX` 可关掉补后缀

流式响应由 `litellm/llms/anthropic/chat/handler.py` 的迭代器族解析 SSE 事件（`content_block_delta` 等），再由 `CustomStreamWrapper` 统一包装（第三层第 7 篇）。

## 7. BaseConfig 的公共契约

所有 Config 的方法集由基类约定（`litellm/llms/base_llm/chat/transformation.py :: BaseConfig :: +0`）：

| 方法 | 必须实现？ | 语义 |
|---|---|---|
| `get_supported_openai_params` | 是 | 能力矩阵 |
| `map_openai_params` | 是 | 参数翻译 |
| `transform_request` | 是 | 请求翻译 |
| `transform_response` | 是 | 响应翻译 |
| `get_complete_url` | 是 | URL 拼装 |
| `validate_environment` | 是 | 凭证与头 |
| `transform_request_on_unprocessable_entity_error` | 可选 | 4xx 自愈（默认原样抛出） |
| `uses_async_transform_request` | 可选 | 异步翻译开关（需要取 token 的 provider 置 True） |

新增一个 provider = 实现这组方法 + 在 `ProviderConfigManager` 表里注册（`litellm/utils.py :: ProviderConfigManager :: _build_provider_config_map() :: +0`）。
