# 函数级解析：流式响应（CustomStreamWrapper）

> 所属层级：第四层（源码补齐） | 覆盖：`litellm_core_utils/streaming_handler.py :: CustomStreamWrapper`

补齐第三层第 7 篇承诺的函数级拆解。`CustomStreamWrapper` 是所有 provider 流的统一包装器（类定义 `streaming_handler.py :: CustomStreamWrapper :: +0`）。

## 1. `__init__()`

```
litellm/litellm_core_utils/streaming_handler.py :: CustomStreamWrapper :: __init__() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 持有原始流与全部统计状态 |
| 关键状态 | `completion_stream`（provider 原始迭代器）、`make_call`（断流重拉句柄）、`model_call_details` 引用、`sent_stream_usage`、`chunks`（累计分片）、`highlighted` 计时 |
| 核心算法 | `+59` 附近：`self.stream_options = stream_options or getattr(logging_obj, "stream_options", None)`；`send_stream_usage` 由 `check_send_stream_usage` 决定 |

## 2. `check_send_stream_usage()`

```
litellm/litellm_core_utils/streaming_handler.py :: CustomStreamWrapper :: check_send_stream_usage() :: +0
```

| 项 | 内容 |
|---|---|
| 返回 | `stream_options is not None and stream_options.get("include_usage", False) is True` |
| 语义 | 只控制**客户端**看得到 usage；网关内部聚合不受它影响（`+2228` 一带的 docstring 写明） |

## 3. `chunk_creator()`

```
litellm/litellm_core_utils/streaming_handler.py :: CustomStreamWrapper :: chunk_creator() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 单个 provider 原始 chunk → OpenAI `ModelResponseStream` |
| 参数 | `chunk: Any`（provider 私有形态） |
| 返回 | 标准化 chunk（或 None 表示跳过） |
| 核心算法 | 按 provider 分派解析器（OpenAI delta、Anthropic 事件、Bedrock 结构等），归一 role/content/tool_call/usage 字段；usage chunk 触发 `_new_usage_chunk` 相关聚合；时间戳（TTFT）在首个内容 chunk 时打点 |

## 4. `finish_reason_handler()`

```
litellm/litellm_core_utils/streaming_handler.py :: CustomStreamWrapper :: finish_reason_handler() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 归一流结束原因（stop/length/tool_calls/content_filter），处理 provider 间 finish_reason 语义差 |
| 时机 | 每个 chunk 处理后检查；最终值写进聚合响应 |

## 5. `__anext__()`

```
litellm/litellm_core_utils/streaming_handler.py :: CustomStreamWrapper :: __anext__() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 异步迭代主循环：取原始 chunk → `chunk_creator` → 产出标准 chunk |
| 前置 | `__aiter__ :: +0` 已置位 |
| 错误处理 | 见下方要点 |

核心算法（相对偏移）：

1. `+1`：`self._closed` 已关 → `StopAsyncIteration`
2. `+3`：`custom_llm_provider == "cached_response"` 分支——缓存命中的流重放
3. `+13`：`completion_stream is None` → `await self.fetch_stream()`（延迟拉流）
4. `+16`：逐 chunk 循环——`"None"`/None 跳过，gemini 空 parts 特判
5. `+24` 附近：`processed_chunk is None` → 继续取下一个原始 chunk

两个错误处理要点（源码注释自述）：litellm.Timeout 必须在 try 块**内部**抛出才会携带流上下文，提前检查会绕过它；上游中断时包装错误并触发断流计费路径。

## 6. `_finalize_completed_stream()`

```
litellm/litellm_core_utils/streaming_handler.py :: CustomStreamWrapper :: _finalize_completed_stream() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 流自然结束的收尾：聚合并触发计费 |
| 核心算法 | `+2`：`_async_build_complete_streaming_response()` 用累计 chunks 拼完整响应；`+3`：`_new_usage_chunk()` 造最终 usage chunk；`+5` 附近：`_propagate_usage_cost_to_hidden_params` 把成本写进 `_hidden_params`；`+21` 附近：`async_cache_streaming_response` 写流缓存 |

成功事件在此刻发给日志管线（第三层第 8 篇的时序图），这是「流式请求记账延迟到流结束」的实现位置。

## 7. 断流计费

```
litellm/proxy/common_request_processing.py :: _dispatch_disconnect_billing_event() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 客户端中途断开时，按已收到的部分记账 |
| 核心算法 | 检查 `has_dispatched_final_stream_success` 防止与自然结束重复分发（`+10` 附近）；释放并发槽位（pre-call 限流器占用的）后按 partial usage 触发 success 事件 |

## 8. 同步迭代

```
litellm/litellm_core_utils/streaming_handler.py :: CustomStreamWrapper :: __iter__() :: +0
litellm/litellm_core_utils/streaming_handler.py :: CustomStreamWrapper :: __next__() :: +0
litellm/litellm_core_utils/streaming_handler.py :: CustomStreamWrapper :: fetch_stream() :: +0
```

同步对（`+136`、`+1916`）与异步版结构对称，服务同步 `completion(stream=True)` 调用方；`fetch_stream() :: +0`（`+2114`）是「惰性拉流」的共享句柄，`__anext__` 与 `make_call` 断流重拉都走它。聚合与计费路径共用。
