# 端点与请求解析

> 所属层级：第三层（主链路拆解） | 拆解对象：第二层场景的跳 1-3

## 本篇回答的问题

HTTP 报文到达 4000 端口之后、鉴权完成之后，body 是怎么变成带元数据的 `data` dict 的？中间有哪些防御性处理？

## 调用链

```
FastAPI 路由
└─ chat_completion()                       proxy_server.py :: chat_completion
   ├─ Depends(user_api_key_auth)           先于函数体（见下一篇）
   ├─ read_request_body()                  common_utils/http_parsing_utils.py
   ├─ metadata 注入                        proxy_server.py :: chat_completion 函数体前段
   └─ ProxyBaseLLMRequestProcessing(data)  common_request_processing.py :: 构造器
```

## 端点函数解剖

```
litellm/proxy/proxy_server.py :: chat_completion() :: +0
```

签名只有四个参数：`request`、`fastapi_response`、可选的路径参数 `model`、鉴权产物 `user_api_key_dict`。请求体不在签名里，因为 body 要在函数体内手动读（多个路径共享此函数，且 body 读取需要容错）。

函数体前半段做两件事：

**第一件事，读 body**：

```python
data: Final = await read_request_body(request=request)
```

（`proxy_server.py :: chat_completion() :: +31`）

**第二件事，metadata 注入**（`proxy_server.py :: chat_completion() :: +33 至 +47`）：

```python
if not isinstance(data.get("metadata"), dict):
    data["metadata"] = {}
if hasattr(user_api_key_dict, "user_id") and user_api_key_dict.user_id is not None:
    data["metadata"]["user_api_key_user_id"] = user_api_key_dict.user_id
...
```

注入键与来源一一对应：

| 注入键 | 来源字段 | 用途 |
|---|---|---|
| `user_api_key_user_id` | `UserAPIKeyAuth.user_id` | 记账归属到用户 |
| `user_api_key_team_id` | `UserAPIKeyAuth.team_id` | 记账归属到团队 |
| `user_api_key_org_id` | `UserAPIKeyAuth.org_id` | 记账归属到组织 |
| `user_api_key_org_alias` | `UserAPIKeyAuth.organization_alias` | 展示用 |
| `agent_id` | `UserAPIKeyAuth.agent_id` | agent 归因 |

防御点：metadata 缺失或不是 dict（比如 multipart 表单里是 JSON 字符串）时先归一为空 dict，否则后面的 `data["metadata"][k] = v` 会在字符串上抛 TypeError。这个防御有对应的内联注释。

## read_request_body 的完整逻辑

```
litellm/proxy/common_utils/http_parsing_utils.py :: read_request_body() :: +0
```

分支树：

```
read_request_body(request)
├─ request is None → {}
├─ is_otlp_trace_request → {}          # OTLP 追踪上报走独立解析
├─ 请求对象上已有缓存的解析结果 → 直接复用   # _safe_get_request_parsed_body
├─ content-type 是二进制（音频/图片等）→ _parse_binary_body
├─ content-type 是表单 → 读 form，metadata 若是 JSON 字符串则解析
└─ 否则（常规 JSON）
   ├─ body 为空 → {}
   ├─ orjson.loads 成功 → 经 _JSON_REQUEST_BODY（pydantic TypeAdapter）校验
   └─ JSONDecodeError → surrogate 修复后重试（处理非法 UTF-16 代理对）
```

设计意图解读：

| 处理 | 为什么需要 |
|---|---|
| 解析结果缓存到 request 对象 | 同一请求的 body 可能被读多次（端点、hook、guardrail），避免重复消费流 |
| orjson 而非标准 json | 热路径性能 |
| pydantic TypeAdapter 校验 | 在入口处把非 dict 的顶层 JSON（数组、字符串）挡下来 |
| surrogate 修复重试 | 客户端发非法编码时不至于 500 |

## ProxyBaseLLMRequestProcessing 构造

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: __init__() :: +0
```

```python
def __init__(self, data: dict, served_model: str | None = None):
    self.data = data
    self.served_model = served_model
    self._tags_before_guardrails: frozenset[str] | None = None
    self.route_type: str | None = None
```

这个类是所有 LLM 端点的共享处理骨架：chat completions、responses API、Anthropic messages、embeddings 等端点都用它，靠 `route_type`（如 `"acompletion"`、`"anthropic_messages"`）区分后续分发到哪个 SDK 方法。实例是每请求新建的，无共享可变状态。

## 错误传播从这里开始成形

端点函数把 `base_process_llm_request` 包在 try/except 里，异常分派表：

| 异常 | 端点层处理 | 源码锚点 |
|---|---|---|
| `ModifyResponseException` | 构造 `finish_reason="content_filter"` 的假响应（guardrail 拦截） | `proxy_server.py :: chat_completion() :: except ModifyResponseException` |
| `ProxyException` | 原样序列化返回（统一错误 schema） | `chat_completion() :: 尾部 except` |
| 其他 `Exception` | 包成 `ProxyException` 返回 500 | 同上 |

`ProxyException` 定义在 `litellm/proxy/_types.py :: ProxyException :: +0`，是所有端点对外错误的一致形状（OpenAI 风格 error 对象 + code/message/param）。

## 与下一跳的交接

本篇结束时，`data` 已含 metadata，`ProxyBaseLLMRequestProcessing` 实例已持有它。下一步是 `base_process_llm_request` → 鉴权后的 pre-call 处理（继续第三层第 3 篇）。鉴权本身先于这一切，见下一篇。
