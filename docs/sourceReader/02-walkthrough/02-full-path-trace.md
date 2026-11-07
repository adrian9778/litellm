# 全路径追踪：从 curl 到 JSON 响应

> 所属层级：第二层（真实全路径） | 建议阅读顺序：6

沿着上一章的 curl 请求走完全程。每一跳给出：源码位置（按「文件 :: 类/函数 :: 偏移」规范）、进出数据、关键判断。数据形态用 `→` 标注演变。

## 跳跃总图

```
curl ─▶ [1]FastAPI ─▶ [2]鉴权 ─▶ [3]读body+注metadata ─▶ [4]pre-call
     ─▶ [5]route_request ─▶ [6]Router选部署 ─▶ [7]重试壳 ─▶ [8]acompletion
     ─▶ [9]sync completion() ─▶ [10]HTTP handler ─▶ [11]OpenAI变换+HTTP
     ─▶ [12]响应回传+成本+落库 ─▶ JSON
```

## 跳 1：HTTP 进入，路由匹配

```
litellm/proxy/proxy_server.py :: chat_completion() :: +0
```

FastAPI 按 `@router.post("/v1/chat/completions", dependencies=[Depends(user_api_key_auth)])` 匹配请求。注意装饰器有四层（`/v1/chat/completions`、`/chat/completions`、`/engines/{model}/...`、`/openai/deployments/{model}/...`），四个路径共用这一个函数。

- 进：HTTP 报文
- 出：`Request` 对象 + 一个待执行的鉴权依赖

**关键点**：`Depends(user_api_key_auth)` 让鉴权在函数体之前执行，函数签名里的 `user_api_key_dict: UserAPIKeyAuth = Depends(user_api_key_auth)` 就是鉴权结果。

## 跳 2：鉴权

```
litellm/proxy/auth/user_api_key_auth.py :: user_api_key_auth() :: +0
```

- 进：`Authorization: Bearer sk-litellm-master-...`
- 出：`UserAPIKeyAuth` 对象（api_key、user_id、team_id、org_id、模型权限等）

master key 走的是最短路径：比对出是根凭证后直接构造全权限的 `UserAPIKeyAuth`。普通 key 则要查缓存（`user_api_key_cache`）或 Postgres，然后做预算/模型访问/限流前置检查。细节在第三层第 2 篇展开。

**失败出口**：任何检查不过 → 抛 `ProxyException` → FastAPI 返回 401/403/429，请求到此结束。

## 跳 3：读 body，注入元数据

```
litellm/proxy/proxy_server.py :: chat_completion() :: +31     # read_request_body 调用
litellm/proxy/proxy_server.py :: chat_completion() :: +33     # metadata 注入开始
```

- 进：原始 HTTP body
- 出：`data: dict`（OpenAI 请求格式）+ 注入后的 `data["metadata"]`

```
data 形态变化：
{"model": "gpt-4o-mini", "messages": [...]}
→ metadata 注入后：
{"model": "gpt-4o-mini", "messages": [...],
 "metadata": {"user_api_key_user_id": "...", "user_api_key_team_id": "...", ...}}
```

读 body 的实现在 `litellm/proxy/common_utils/http_parsing_utils.py :: read_request_body() :: +0`。

## 跳 4：Pre-call 处理

```
litellm/proxy/proxy_server.py :: chat_completion() :: +51        # base_process_llm_request 调用
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: base_process_llm_request() :: +0
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: _process_llm_request() :: +0
```

调用链：`chat_completion` → `base_process_llm_request`（外面包了 SSE keepalive 包装 `open_sse_before_first_byte`）→ `_process_llm_request`（真正骨架）→ `common_processing_pre_call_logic`：

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: common_processing_pre_call_logic() :: +0
```

这一步做四件事，顺序固定：

| 顺序 | 动作 | 代码锚点 |
|---|---|---|
| 1 | 注入 `litellm_call_id`（若客户端带了 `x-litellm-call-id` 头则复用） | `_process_llm_request()` 内 `resolve_litellm_call_id` |
| 2 | 执行 `litellm_settings.callbacks` 里各 hook 的 `async_pre_call_hook` | `proxy_logging_obj.pre_call_hook` |
| 3 | `add_litellm_data_to_request`：把 key/team/用户信息、默认参数写进 data | `litellm/proxy/litellm_pre_call_utils.py :: add_litellm_data_to_request() :: +0` |
| 4 | 构造 `Logging` 对象放进 `data["litellm_logging_obj"]` | `_process_llm_request()` 内 |

- 进：`data` dict
- 出：增强后的 `data` + `logging_obj`（回调管线引擎）

## 跳 5：route_request 拿协程

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: _process_llm_request() :: +84    # route_request 调用
litellm/proxy/route_llm_request.py :: route_request() :: +0
```

- 进：`(data, route_type="acompletion", llm_router)`
- 出：`llm_call`，一个尚未执行的协程

`route_request` 内部按 `route_type` 查表，把 `llm_router.acompletion` 绑定上参数。函数上方注释强调 "Do not change this - it should be a constant time fetch - ALWAYS"。随后：

```python
llm_call_task: Final = asyncio.create_task(with_proxy_compaction_executor(llm_call, request))
```

真正的调度从这一刻开始。

## 跳 6：Router 选部署

```
litellm/router_api.py :: Router :: acompletion() :: +0            # 门面方法
litellm/router_core.py :: make_core() :: +0                       # 构造期已选定核心
litellm/router_python_core.py :: PythonCore :: acompletion() :: +0
litellm/router_python_core.py :: PythonCore :: _core_async_get_healthy_deployments() :: +0
litellm/router_strategy/simple_shuffle.py :: simple_shuffle() :: +0
```

- 进：`data`（model="gpt-4o-mini"）
- 出：1 个 deployment（含 `litellm_params`：model 字符串、api_key、api_base…）

单部署场景下选部署几乎是直通的，但流程一样不少：

```
model="gpt-4o-mini"
→ registry 查 group → [deployment#1]
→ 过滤冷却部署（async_get_cooldown_deployments）
→ 策略函数（simple_shuffle：加权随机）选中 deployment#1
```

## 跳 7：重试壳

```
litellm/router_python_core.py :: PythonCore :: async_function_with_retries() :: +0
litellm/router_python_core.py :: PythonCore :: async_function_with_fallbacks() :: +0
```

执行顺序是「fallbacks 在外、retries 在内」。每次尝试内部真正执行的是：

```python
response = await self._host.invoke("acompletion")(**compacted_input)
```

（`router_python_core.py :: PythonCore :: 单次尝试体内 :: _host.invoke("acompletion")`）

**架构要点**：Router 核心从不直接 `import litellm`，所有外部触达都经过 `PythonHost`（`litellm/router_python_host.py :: PythonHost :: invoke()`）。`invoke("acompletion")` 绑定的就是 `litellm.acompletion`。这样 Rust 核心可以实现同样的接口。

失败时的路径：抛异常 → 判定是否可重试 → `set_cooldown_deployments` 记冷却 → 换部署重试 → 重试耗尽 → fallback group。本场景成功，直接往下走。

## 跳 8：main.acompletion

```
litellm/main.py :: acompletion() :: +0
```

- 进：OpenAI 风格全参数（`model="openai/gpt-4o-mini"`、messages、**kwargs）
- 出：`ModelResponse`

`acompletion` 做三件准备工作后进入执行：

1. 若 model 是 list（多部署内联）则先归一化
2. `get_llm_provider()` 解析 provider（见跳 9 的说明）
3. 组装 `completion_kwargs`，然后：

```python
init_response: Final = await loop.run_in_executor(None, func_with_context)
```

（`litellm/main.py :: acompletion() :: run_in_executor 调用`）

**反直觉但重要**：`acompletion` 把**同步**的 `completion()` 丢进线程池执行，这是当前实现里异步入口的真实路径。有显式 `fallbacks` 时才走 `async_completion_with_fallbacks`。

## 跳 9：get_llm_provider + 同步 completion 分发

```
litellm/litellm_core_utils/get_llm_provider_logic.py :: get_llm_provider() :: +0
litellm/main.py :: completion() :: +0
```

`get_llm_provider` 对 `"openai/gpt-4o-mini"` 的解析结果：

```
model="gpt-4o-mini", custom_llm_provider="openai",
api_key=环境变量值, api_base="https://api.openai.com/v1"（默认）
```

`completion()` 内部按 `custom_llm_provider` 走一长串 if/elif 分发（每个 provider 一个 `_complete_*` 函数或直接分支）。对本例的 `openai`：

```python
response = openai_chat_completions.completion(
    model=model, messages=messages, ...
)
```

（`litellm/main.py :: completion() :: openai 分支 :: openai_chat_completions.completion 调用`）

模块级单例：`litellm/main.py :: openai_chat_completions = OpenAIChatCompletion() :: +0`。

**执行器分工**（容易混淆的点）：

| provider | 默认执行器 |
|---|---|
| `openai`（本例） | `OpenAIChatCompletion`，走官方 OpenAI SDK |
| 绝大多数其他 provider | `BaseLLMHTTPHandler`，走统一 httpx 执行器（`litellm/main.py :: base_llm_http_handler`） |
| `openai` + 环境变量 `EXPERIMENTAL_OPENAI_BASE_LLM_HTTP_HANDLER` | 强制切到 `BaseLLMHTTPHandler` |

## 跳 10：OpenAI SDK 调用

```
litellm/llms/openai/openai.py :: OpenAIChatCompletion :: completion() :: +0
litellm/llms/openai/openai.py :: OpenAIChatCompletion :: 类内 SDK 调用辅助函数 :: chat.completions.create 注释处
```

`OpenAIChatCompletion` 用官方 OpenAI SDK 发请求（`chat.completions.create`，需要响应头时用 `create.with_raw_response` 变体，见该类方法 docstring 注释）。OpenAI 格式的请求几乎原样透传。

对照参考：非 OpenAI provider 在这一跳的形态是 `BaseLLMHTTPHandler.completion()` + `ProviderConfig.transform_request()/transform_response()`（如 `litellm/llms/openai/chat/gpt_transformation.py :: OpenAIGPTConfig :: transform_request() :: +0`，服务 httpx 路径），细节在第三层第 6 篇展开。

- 进：`data` dict + `logging` 对象
- 出：`ModelResponse`（choices/usage 齐全），上游原始 JSON 存进 `logging.model_call_details``

## 跳 11：回到 Router 与处理骨架

响应原路返回：`OpenAIChatCompletion` → `completion()` → `acompletion()` → `_host.invoke` 返回点（跳 7）→ 重试壳检查响应（内容审查判断 `_should_raise_content_policy_error`）→ Router 记录 `success_calls` 并打日志 `litellm.acompletion(model=...) 200 OK`（`router_python_core.py :: PythonCore :: 单次尝试尾部`）→ `_process_llm_request` 拿到 `response`。

`_process_llm_request` 从响应的 `_hidden_params` 里提取：

```python
cache_key, api_base, response_cost = (
    hidden_params.get("cache_key", None) or "",
    hidden_params.get("api_base", None) or "",
    _response_cost_header_value(hidden_params),
)
```

（`proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: _process_llm_request() :: +50 附近`）

## 跳 12：成本、日志、响应头

```
litellm/litellm_core_utils/litellm_logging.py :: Logging :: async_success_handler() :: +0
litellm/cost_calculator.py :: completion_cost() :: +0
litellm/proxy/hooks/proxy_track_cost_callback.py :: _ProxyDBLogger :: async_log_success_event() :: +0
litellm/proxy/db/db_spend_update_writer.py :: DBSpendUpdateWriter :: update_database() :: +0
```

顺序与线程语义：

1. 日志管线触发 `completion_cost()`：`usage.tokens × 价目表（model_prices_and_context_window.json 里 gpt-4o-mini 单价）` → `response_cost`，写进 `_hidden_params`
2. 各回调 `async_log_success_event` 并行执行（Langfuse 上报、Prometheus 计数…）
3. `_ProxyDBLogger` 把 spend 增量交给 `DBSpendUpdateWriter`，后者聚合后异步批量写 Postgres（本场景没配 DB，此步自动降级为仅内存计数）
4. 响应头组装：`x-litellm-response-cost`、`x-litellm-call-id`、`x-litellm-model-id`（`common_request_processing.py :: cost_headers() :: +0`，字面量在 `+14`）

客户端拿到 JSON。全程状态变化复述一遍：metadata 被注入、call id 生成、deployment 被选中并记数、成本被算出、spend 被异步累加、响应头携带审计字段。

## 数据形态演变汇总表

| 跳 | 数据 | 形态 |
|---|---|---|
| 0 | 原始请求 | HTTP bytes |
| 3 | 请求体 | `dict`（OpenAI 格式）+ metadata |
| 4 | 增强请求 | dict + `litellm_call_id` + `litellm_logging_obj` |
| 6 | 选中部署 | `Deployment`（model_name + litellm_params） |
| 8 | SDK 入参 | OpenAI 风格 kwargs（model 前缀 `openai/`） |
| 9 | 解析产物 | `(model, provider, api_key, api_base)` 四元组 |
| 10a | 上游请求 | OpenAI JSON（官方 SDK `chat.completions.create` 发送） |
| 10b | 上游响应 | OpenAI JSON |
| 10c | 翻译后 | `ModelResponse`（Pydantic） |
| 11 | 带元数据响应 | ModelResponse + `_hidden_params["response_cost"]` |
| 12 | 客户端响应 | JSON + `x-litellm-*` 头 |

第二层结束。第三层开始按跳拆解，每跳一篇。
