# 全路径追踪：从 curl 到 JSON 响应

> 所属层级：第二层（真实全路径） | 建议阅读顺序：6

沿着上一章的 curl 请求走完全程。每一跳给出：源码位置（按「文件 :: 类/函数 :: 偏移」规范）、进出数据、关键判断。数据形态用 `→` 标注演变。

## 跳跃总图

```
curl ─▶ [1]FastAPI ─▶ [2]鉴权 ─▶ [3]读body+注metadata ─▶ [4]pre-call
     ─▶ [5]route_request ─▶ [6]Router门面→RustCore选路 ─▶ [7]重试/fallback + PythonHost回Python
     ─▶ [8]acompletion ─▶ [9]sync completion() ─▶ [10]OpenAI变换+HTTP
     ─▶ [11]响应回传 ─▶ [12]成本+日志+响应头 ─▶ JSON
```

下方为逐跳的 ASCII 序列图（方框 = 源码文件 :: 符号，箭头 = 数据流转）：

```
curl
  │  HTTP POST /v1/chat/completions
  ▼
[1] proxy_server.py :: chat_completion           路由匹配（4 个路径共用）
  │  read_request_body → data: dict
  ▼
[2] auth/user_api_key_auth.py :: user_api_key_auth    鉴权依赖（函数体之前）
  │  Authorization 头 → UserAPIKeyAuth 对象
  ▼
[3] proxy_server.py :: chat_completion  (+31)  读 body + 注入 metadata
  │  data["metadata"]["user_api_key_*"] = ...
  ▼
[4] common_request_processing.py :: base_process_llm_request
  │   ├─ _within_total_timeout（外层，total_timeout 408 拦截）
  │   └─ _process_llm_request
  │        └─ common_processing_pre_call_logic：call_id、pre_call_hook、add_litellm_data_to_request、Logging 对象
  ▼
[5] common_request_processing.py :: _process_llm_request (+86) → route_llm_request.py :: route_request
  │  按 route_type 查表，绑定 llm_router.acompletion 返回协程
  ▼
[6] router.py :: Router（门面，纯转发）
  │  __init__ 时 make_core → router_core.py :: make_core
  │   → router_rust/core.py :: RustCore.build → RustCore.acompletion
  │   → router_rust/invoke/endpoints.py :: RustEndpoints.acompletion
  │   → RustCore._drive → _run_steps（进程内选路步骤：select / attempt / allow_fallback）
  │
  │  选路步骤 host 侧：selection.py :: StrategySelectors / prerouting.py（有状态 LB 与 pre-routing）
  ▼
[7] router_rust/core.py :: _Driver.attempt / _routed_attempt
  │  重试（RustRetries）/ fallback（RustFallbacks）都在 Rust core
  │  provider 调用：_Driver._routed_attempt → PythonHost.invoke("acompletion")
  ▼
[8] router_python_host.py :: PythonHost.invoke → litellm.acompletion（main.py :: acompletion）
  │  同步 completion() 丢线程池：run_in_executor
  ▼
[9] litellm_core_utils/get_llm_provider_logic.py :: get_llm_provider
  │  main.py :: completion：按 custom_llm_provider 分发 → openai 分支 openai_chat_completions.completion
  ▼
[10] llms/openai/openai.py :: OpenAIChatCompletion.completion → acompletion
  │   make_openai_chat_completion_request → openai_aclient.post("/chat/completions")
  │   （官方 OpenAI SDK 客户端，raw post 以便拿响应头）
  ▼
[11] 响应原路返回：_routed_attempt → _process_llm_request 提取 hidden_params
  ▼
[12] cost_calculator.py :: completion_cost + litellm_logging 回调
  │   common_request_processing.py :: ProxyBaseLLMRequestProcessing.get_custom_headers
  ▼
JSON + x-litellm-* 头
```

## 跳 1：HTTP 进入，路由匹配

```
litellm/proxy/proxy_server.py :: chat_completion() :: +0
```

FastAPI 按 `@router.post("/v1/chat/completions", dependencies=[Depends(user_api_key_auth)])` 匹配请求。装饰器有四层（`/v1/chat/completions`、`/chat/completions`、`/engines/{model}/...`、`/openai/deployments/{model}/...`），四个路径共用这一个函数。

- 进：HTTP 报文
- 出：`Request` 对象 + 一个待执行的鉴权依赖

**关键点**：`Depends(user_api_key_auth)` 让鉴权在函数体之前执行，函数签名里的 `user_api_key_dict: UserAPIKeyAuth = Depends(user_api_key_auth)`（`chat_completion` 的签名，13362 行）就是鉴权结果。

## 跳 2：鉴权

```
litellm/proxy/auth/user_api_key_auth.py :: user_api_key_auth() :: +0
```

- 进：`Authorization: Bearer sk-litellm-master-...`
- 出：`UserAPIKeyAuth` 对象（api_key、user_id、team_id、org_id、模型权限等）

master key 走的是最短路径：比对出是根凭证后直接构造全权限的 `UserAPIKeyAuth`。普通 key 则要查缓存（`user_api_key_cache`）或 Postgres，然后做预算/模型访问/限流前置检查。预算按「服务所用模型」计算（`litellm/proxy/auth/user_api_key_auth.py :: budget_served_model`，365 行起；`_normalize_model_for_auth`，477 行起）。细节在第三层第 2 篇展开。

**失败出口**：任何检查不过 → 抛 `ProxyException` → FastAPI 返回 401/403/429，请求到此结束。

## 跳 3：读 body，注入元数据

```
litellm/proxy/proxy_server.py :: chat_completion() :: +31     # read_request_body 调用（13389 行）
litellm/proxy/proxy_server.py :: chat_completion() :: +32     # metadata 注入开始（13390 行起）
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
litellm/proxy/proxy_server.py :: chat_completion() :: +51        # base_process_llm_request 调用（13409 行）
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: base_process_llm_request() :: +0
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: _process_llm_request() :: +0
```

调用链：`chat_completion` → `base_process_llm_request`。`base_process_llm_request` 在最外层包了 `total_timeout` 拦截（`_within_total_timeout`，3219 行），再包 SSE keepalive（`open_sse_before_first_byte`，模块级函数，1719 行起），真正的骨架在 `_process_llm_request`，再往里是 `common_processing_pre_call_logic`：

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: common_processing_pre_call_logic() :: +0
```

`_process_llm_request` 在非跳过 pre-call 时走 `_pre_call_with_fallbacks`（3345 行，+43），后者进入 `common_processing_pre_call_logic`。这一步做四件事，顺序固定：

| 顺序 | 动作 | 代码锚点 |
|---|---|---|
| 1 | 注入 `litellm_call_id`（若客户端带了 `x-litellm-call-id` 头则复用） | `common_processing_pre_call_logic()` 内 `resolve_litellm_call_id`（`litellm/proxy/common_request_processing.py :: resolve_litellm_call_id`，387 行） |
| 2 | 执行 `litellm_settings.callbacks` 里各 hook 的 `async_pre_call_hook` | `proxy_logging_obj.pre_call_hook` |
| 3 | `add_litellm_data_to_request`：把 key/team/用户信息、默认参数写进 data | `litellm/proxy/litellm_pre_call_utils.py :: add_litellm_data_to_request() :: +0`（2692 行） |
| 4 | 构造 `Logging` 对象放进 `data["litellm_logging_obj"]` | `common_processing_pre_call_logic()` 内（2812 行起） |

- 进：`data` dict
- 出：增强后的 `data` + `logging_obj`（回调管线引擎）

**行为变化（写进这一跳）**：消息校验在 pre-call 之前/期间对 OpenAI 路径做。缺 `role` 的消息由 `litellm/utils.py :: validate_and_fix_openai_messages() :: +0`（9496 行）归一化后交给 `validate_chat_completion_user_messages`（9573 行），后者对无 `role` 的条目抛 `MissingMessageRoleError`（`litellm/exceptions.py` 372 行，`BadRequestError` 子类，HTTP 400）。这是 #51124 的 BREAKING 行为：不再自动补 `role`。

## 跳 5：route_request 拿协程

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: _process_llm_request() :: +86    # route_request 调用（3388 行）
litellm/proxy/route_llm_request.py :: route_request() :: +0
```

- 进：`(data, route_type="acompletion", llm_router)`
- 出：`llm_call`，一个尚未执行的协程

`route_request` 内部按 `route_type` 查表，把 `llm_router.acompletion` 绑定上参数（`litellm/proxy/route_llm_request.py :: _route_request_single_attempt`，878 行，按分支 `getattr(llm_router, "acompletion")(**data)`）。函数内先 `enforce_total_timeout_scope(data)`（842 行，+10）：对 body 带 `total_timeout` 的非流式请求，把超时作用域挂进当前上下文。函数上方注释强调 "Do not change this - it should be a constant time fetch - ALWAYS"。随后回到 `_process_llm_request`：

```python
llm_call_task: Final = asyncio.create_task(with_proxy_compaction_executor(llm_call, request))
```

（`_process_llm_request() :: +93`，3395 行）真正的调度从这一刻开始。

## 跳 6：Router 门面与 Rust 核心选路

旧文这一段引用 `router_python_core.py :: PythonCore`，该文件已被删除（双核时代 #50178 终结）。现在是一条门面委托到 Rust 核心的路径：

```
litellm/router.py :: Router :: __init__() :: +0                       # 门面：__init__ 只 attach(make_core(...))
litellm/router_core.py :: make_core() :: +0                           # 无条件 RustCore.build
litellm/router_rust/core.py :: RustCore :: build() :: +0              # pyo3 句柄构造
litellm/router_rust/core.py :: RustCore :: acompletion() :: +0        # 端点方法，转发给 _endpoints
litellm/router_rust/invoke/endpoints.py :: RustEndpoints :: acompletion() :: +0   # 拆 model、选调度或 drive
litellm/router_rust/core.py :: RustCore :: _drive() :: +0             # 驱动一次调用
litellm/router_rust/core.py :: RustCore :: _run_steps() :: +0         # 步骤循环
litellm/router_rust/steps/selection.py :: StrategySelectors :: pick_async() :: +0   # 有状态 LB 留在宿主 step
```

- 进：`data`（model="gpt-4o-mini"）
- 出：1 个 deployment（含 `litellm_params`：model 字符串、api_key、api_base…）

`Router` 是纯门面（`litellm/router.py` 410 行起）：`__init__` 只做 `self._attach(make_core(build_router_config(...)))`（419 行），成员读写都转发 `_core`，禁子类化（`__init_subclass__` 直接 `TypeError`）。`make_core`（`litellm/router_core.py :: make_core`，51 行，全文件 55 行）无条件 `RustCore.build`。

`RustCore.acompletion`（`litellm/router_rust/core.py` 2547 行）把请求交给 `RustEndpoints.acompletion`（`litellm/router_rust/invoke/endpoints.py` 1998 行），后者在 `_routed_acompletion`（2012 行）拆 `priority`：无优先级时 `await self._core.drive(plan, rest)`。`_drive`（2880 行）构建一次 `RouterCall`，`_run_steps`（2930 行）对步骤循环，每步由宿主（Python）应答。选路步骤（`select`）在宿主侧 `_answer_select`（3393 行）执行，走 `litellm/router_rust/steps/selection.py :: StrategySelectors`；有状态 LB 与 pre-routing 步骤在 `router_rust/steps/`（prerouting.py、selection.py）。

单部署场景下选部署几乎是直通的，但流程一样不少：

```
model="gpt-4o-mini"
→ registry 查 group → [deployment#1]
→ 过滤冷却部署（cooldown）
→ 策略（selection.py 的 selector）选中 deployment#1
```

**行为变化（写进这一跳）**：预路由 host 侧会先跑 `pre_route` 步骤；选部署的尝试会做 pre-call 检查（`litellm/router_rust/steps/selection.py :: routing_pre_call_checks`，350 行）。

## 跳 7：重试 / fallback 与回 Python 执行

```
litellm/router_rust/core.py :: _Driver :: attempt() :: +0            # 一次尝试（5214 行）
litellm/router_rust/core.py :: _Driver :: _routed_attempt() :: +0     # 真正发起 provider 调用（5238 行）
litellm/router_rust/core.py :: RustRetries :: ...                     # 重试策略 mixin
litellm/router_rust/core.py :: RustFallbacks :: ...                   # fallback mixin
litellm/router_python_host.py :: PythonHost :: invoke() :: +0         # 回 Python 执行
```

重试与 fallback 的逻辑（`RustRetries`、`RustFallbacks` mixin）都在 Rust core 的 `_run_steps` 循环里：失败 → 判定是否可重试 → `set_cooldown` 记冷却 → 换部署重试 → 重试耗尽 → fallback group。`_run_steps` 内 `attempt`、`sleep`、`allow_fallback`、`select`、`pre_route` 等步骤由 `_Driver` 应答。

每次尝试真正执行 provider 调用的点是 `_routed_attempt`（`litellm/router_rust/core.py` 5238 行）：

```python
host: Final = self._core._host
compacted: Final = await compacted_attempt(...)
pending: Final = host.invoke(call.host_op)(**compacted)
answered: Final = await pending if awaited else pending
```

（`_routed_attempt` 内 `host.invoke` 调用，5287 行）

**架构要点**：Rust core 从不直接 `import litellm`，所有外部触达都经过 `PythonHost`（`litellm/router_python_host.py :: PythonHost :: invoke()`，107 行）。`invoke("acompletion")` 返回的就是 `litellm.acompletion`。对 chat_completions，执行层由 catalog 定为 PYTHON_ONLY，所以始终经 host 回 Python。

**行为变化（写进这一跳）**：非流式请求的总超时（body `total_timeout` 或头 `x-litellm-total-timeout`）超时后抛 `TotalTimeoutExpired`（`litellm/litellm_core_utils/total_deadline.py :: TotalTimeoutExpired`，103 行），映射为 HTTP 408。429 限流失败会带 `rate_limited_by: descriptor_key` 响应头（`litellm/proxy/hooks/parallel_request_limiter_v3.py` 3350 行，#51228）。

## 跳 8：main.acompletion

```
litellm/router_python_host.py :: PythonHost :: invoke() :: +0     # 绑定 litellm.acompletion
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

（`litellm/main.py :: acompletion() :: +293`，945 行）

**反直觉但重要**：`acompletion` 把**同步**的 `completion()` 丢进线程池执行，这是当前实现里异步入口的真实路径。有显式 `fallbacks` 时才走 `async_completion_with_fallbacks`（913 行）。

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

`completion()`（`litellm/main.py` 5564 行）内部按 `custom_llm_provider` 走一长串 if/elif 分发。对本例的 `openai`：

```python
response = openai_chat_completions.completion(
    model=model, messages=messages, ...
)
```

（`litellm/main.py :: completion() :: openai 分支`，2894 行）

模块级单例：`litellm/main.py :: openai_chat_completions = OpenAIChatCompletion() :: +0`（358 行）。

**执行器分工**（容易混淆的点）：

| provider | 默认执行器 |
|---|---|
| `openai`（本例） | `OpenAIChatCompletion`，走官方 OpenAI SDK |
| 绝大多数其他 provider | `BaseLLMHTTPHandler`，走统一 httpx 执行器（`litellm/main.py :: base_llm_http_handler`，395 行） |
| `openai` + 环境变量 `EXPERIMENTAL_OPENAI_BASE_LLM_HTTP_HANDLER` | 强制切到 `BaseLLMHTTPHandler`（`litellm/main.py :: completion` 内 `use_base_llm_http_handler`，2853 行） |

## 跳 10：OpenAI SDK 调用

```
litellm/llms/openai/openai.py :: OpenAIChatCompletion :: completion() :: +0
litellm/llms/openai/openai.py :: OpenAIChatCompletion :: acompletion() :: +0
litellm/llms/openai/openai.py :: OpenAIChatCompletion :: make_openai_chat_completion_request() :: +0
```

`OpenAIChatCompletion.completion`（`litellm/llms/openai/openai.py` 716 行）在 `acompletion=True` 时委托给 `self.acompletion`（967 行），后者调 `make_openai_chat_completion_request`（550 行）。真正的上游请求是官方 OpenAI SDK 客户端发起的：

```python
raw_response = _raw_chat_response(
    await openai_aclient.post(
        "/chat/completions",
        body=body,
        cast_to=ChatCompletion,
        options=options,
        stream=bool(data.get("stream")),
        stream_cls=AsyncStream[ChatCompletionChunk],
    )
)
```

（`make_openai_chat_completion_request` 内 `openai_aclient.post("/chat/completions")`，566 行）

方法 docstring 仍写「call chat.completions.create 时 return_response_headers」等（559 行起），但当前实现用 SDK 客户端的裸 `post("/chat/completions", ...)`（`AsyncOpenAI.post`），既走官方 SDK 也保留原始响应头。OpenAI 格式的请求几乎原样透传。

对照参考：非 OpenAI provider 在这一跳的形态是 `BaseLLMHTTPHandler.completion()` + `ProviderConfig.transform_request()/transform_response()`（如 `litellm/llms/openai/chat/gpt_transformation.py :: OpenAIGPTConfig :: transform_request() :: +0`，服务 httpx 路径），细节在第三层第 6 篇展开。

- 进：`data` dict + `logging` 对象
- 出：`ModelResponse`（choices/usage 齐全），上游原始 JSON 存进 `logging.model_call_details`

## 跳 11：回到 Router 与处理骨架

响应原路返回：`OpenAIChatCompletion.acompletion` → `completion()` → `acompletion()` → `PythonHost.invoke` 返回点（跳 7）→ `_routed_attempt` 检查响应（内容审查判断 `_should_raise_content_policy_error`）→ Rust core 记 `success_calls` 并打日志 → `_run_steps` 到 `done` → `_drive.finish_async` → `_process_llm_request` 拿到 `response`。

`_process_llm_request` 从响应的 `_hidden_params` 里提取：

```python
cache_key, api_base, response_cost = (
    hidden_params.get("cache_key", None) or "",
    hidden_params.get("api_base", None) or "",
    _response_cost_header_value(hidden_params),
)
```

（`litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: _process_llm_request() :: +119`，3421 行起）

## 跳 12：成本、日志、响应头

```
litellm/litellm_core_utils/litellm_logging.py :: Logging :: async_success_handler() :: +0
litellm/cost_calculator.py :: completion_cost() :: +0
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: get_custom_headers() :: +0
litellm/proxy/common_request_processing.py :: cost_headers() :: +0
```

顺序与线程语义：

1. 日志管线触发 `completion_cost()`：`usage.tokens × 价目表（model_prices_and_context_window.json 里 gpt-4o-mini 单价）` → `response_cost`，写进 `_hidden_params`
2. 各回调 `async_log_success_event` 并行执行（Langfuse 上报、Prometheus 计数…）
3. 响应头组装：`get_custom_headers`（`litellm/proxy/common_request_processing.py` 2419 行）里 `x-litellm-call-id`、`x-litellm-model-id`（2464 行起），成本类头由 `cost_headers`（2096 行）展开出 `x-litellm-response-cost` 等

本场景没配 DB，spend 落库路径自动降级为仅内存计数；有 DB 时 `_ProxyDBLogger` → `DBSpendUpdateWriter` 聚合后异步批量写 Postgres，第三层第 8/9 篇展开。

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
| 10a | 上游请求 | OpenAI JSON（官方 OpenAI SDK `post("/chat/completions")` 发送） |
| 10b | 上游响应 | OpenAI JSON |
| 10c | 翻译后 | `ModelResponse`（Pydantic） |
| 11 | 带元数据响应 | ModelResponse + `_hidden_params["response_cost"]` |
| 12 | 客户端响应 | JSON + `x-litellm-*` 头 |

第二层结束。第三层开始按跳拆解，每跳一篇。