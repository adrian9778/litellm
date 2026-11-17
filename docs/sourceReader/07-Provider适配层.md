---
title: Provider适配层
layer: 4
---

# Provider 适配层

> **代码基准**：`main@e46fe2e2dc1bdd19f7953bd47dc3d770876ac74e（工作区干净）`；核实日期：2026-11-17。
> **范围**：Provider 适配层的请求/流式/参数抽象层（`BaseLLM` + `CustomLLM` + `llms/<name>/` 下的每个供应商）。
> **前置**：U02 已确认供应商 HTTP 调用由 `CustomLLM` 完成；U03 确认选择器。

## 0. 结论速览

LiteLLM 把 100+ 供应商的请求调用统一抽象为 **`BaseLLM`** 上的四个方法：
1. `completion`（同步）
2. `acompletion`（异步）
3. `streaming`（同步流）
4. `astreaming`（异步流）

每供应商继承 `BaseLLM`（如 `OpenAIChatCompletion(BaseLLM, BaseOpenAILLM)`），填这四类 & 别的过程。请求体走 `litellm.llms.custom_llm.CustomLLM` 到里面的 `litellm.llms.custom_httpx.http_handler` 发出（`httpx` 真正执行）。

## 1. 适配器（Adapter）树

```
litellm/llms/
├── custom_llm.py       → CustomLLM: 基类所有的连接
├── base.py             → BaseLLM: 核心抽象（process_response 等）
├── openai/
│   ├── openai.py       → OpenAIChatCompletion / OpenAITextCompletion / ...
│   ├── completion/handler.py  → OpenAITextCompletion 实现
│   └── ...
├── anthropic/          → AnthropicChatCompletion 实现
├── bedrock/            → BedrockChatCompletion
├── vertex_ai/          → VertexAI chat / embedding
├── azure/              → Azure OpenAI adapter
├── vllm, mistral, cohere, groq, ...
```

**所有供应商的公共约定**：
- `provider/<name>.completion(model, messages, streaming, api_key, api_base, custom_prompt_dict)` 必写文档标准。
- 返回 `ModelResponse`。

## 2. 每个提供商实现世界的类

`litellm.llms.custom_llm.CustomLLM` 定义了标准接口：
- `completion(...)` — 同步调用
- `streaming(...)` — 同步流
- `acompletion(...)` — 异步
- `astreaming(...)` — 异步流
- `create_embedding(...)`（非所有）
- `transform_response(...)`（Stream)

`process_response`（`litellm/llms/base.py`）在 `BaseLLM` 上：把 httpx 返回的 `Response` 转化为 litellm `ModelResponse`/`CustomStreamWrapper`。每供应商如果其原始格式不标准，需要覆盖自己的。

各供应商请求通过 e.类 `litellm.llms.custom_httpx.http_handler`（`AsyncHTTPHandler`/`HTTPHandler`）发往供应商，再经 `litellm.litellm_core_utils.litellm_logging` 记录（trace）到 `logging_obj`。

## 3. 请求体（`data`）`和` model 参数

各大供应商统一那四个参数：
- `model`
- `messages`
- `api_key` / `api_base`
- `custom_prompt_dict` + `encoding`（anthropic 的 system 消息 re-formatting）

每个 provider 在 `completion` 里会做 **provider-specific kwargs** 把方位（如 `max_tokens`, `models`, `stream_options`）设置到 `litellm_params`。

## 4. stream 层

`litellm/llms/base.py` 上的 `streaming`/`astreaming` 要做到 `CustomStreamWrapper`（`litellm.litellm_core_utils.streaming_well`）。主要 stream 抽象：
- 每个供应商的流首先被包装为 `ModelResponseStream`，一个 chunk 是 `chunk_parser` 或 `parse`。
- `CustomLLM` 外层：`streaming` with `print_verbose`，SJ 的 `errors`。

## 5. 到 `custom_httpx`

供应商实现在 `if self.client is None: self.client = HTTPHandler(...)`，进去就是 `httpx`，超时和状态块都在 `litellm.litellm_core_utils.litellm_logging` 里。

## 6. 特殊供应商默认 agent（A2A、langgraph）

供应商内 by agent protocols（`litellm/llms/a2a/main.py`），使用 `a2a_protocol` 包。

## 7. 测试与覆盖

每个 provider 下面有：
- `tests/unit/...provider/` 下，各 provider 下的 `litellm.llms/<name>`
- `LitellmAdapter`（所有）对 `litellm/utils.py` 的 `model_alias`。

这个检查 `litellm/__init__.py` 里跑 `_populate_provider_model_sets` 时可用性。
