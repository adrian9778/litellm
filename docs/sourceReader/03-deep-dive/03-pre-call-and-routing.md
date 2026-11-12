# Pre-call 处理与路由决策

> 所属层级：第三层（主链路拆解） | 拆解对象：第二层场景的跳 4-5

## 本篇回答的问题

鉴权通过之后、Router 接手之前，请求经历了什么加工？`model` 字符串是怎么对上 model group 的？兜底分支有哪些？

## 调用链

```
_process_llm_request()
└─ _pre_call_with_fallbacks()                              common_request_processing.py :: +0
   └─ common_processing_pre_call_logic()                  common_request_processing.py :: +0
      ├─ add_litellm_data_to_request()                    litellm_pre_call_utils.py :: +0
      ├─ 配置合并（user_*、model alias、层级 router 设置、priority 头）
      ├─ function_setup() → logging_obj                   litellm/utils.py :: function_setup
      ├─ check_and_merge_model_level_guardrails()         合并 DB/UI 级 guardrail
      ├─ pre_call_hook()（含限流、guardrail）              proxy_logging_obj
      └─ 返回 (增强 data, logging_obj)
```

`_pre_call_with_fallbacks`（`common_request_processing.py :: _pre_call_with_fallbacks :: +0`）的职责是把 pre-call 本身的异常也纳入回调（失败也要留痕），正常路径直接透传到 `common_processing_pre_call_logic`。

## common_processing_pre_call_logic 的步骤清单

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: common_processing_pre_call_logic() :: +0
```

按源码顺序（相对本函数 `+0`）：

| 步 | 动作 | 源码锚点（相对本函数） |
|---|---|---|
| 1 | `add_litellm_data_to_request` 注入网关数据（见下节） | `+123` |
| 2 | 记录请求元数据、queue 时间（`arrival_time` 到 `start_time` 的窗口） | `+134` 至 `+165` |
| 3 | 应用全局默认：`user_temperature` / `user_request_timeout` / `user_max_tokens` / `user_api_base` | `+180` 至 `+188` |
| 4 | `global_then_key_alias_target` 别名解析 | `+194` |
| 5 | 层级 router 设置更新（DB 覆盖 YAML），含 model_group_alias | `+196` 至 `+207` |
| 6 | scheduled 路由：`router.health().priority_header_fields` 读 `x-litellm-priority` 头 | `+209` |
| 7 | `litellm_call_id` 解析、telemetry 绑定 | `+216` 至 `+223` |
| 8 | `litellm.utils.function_setup` 构造 `Logging` 对象 | `+243`，随后写入 `data["litellm_logging_obj"]` |
| 9 | 合并 model 级 guardrail 配置（`check_and_merge_model_level_guardrails`） | `+268` |
| 10 | `proxy_logging_obj.pre_call_hook`（执行全部 pre-call 回调） | `+285` |
| 11 | guardrail 之后的 message 刷新（PII 掩码可能改写 messages）、served model 解析 | `+311` 至 `+324` |

步骤 10 是限流真正发生的地方：`PROXY_HOOKS` 注册的限流器实现了 `async_pre_call_hook`，在 Redis 上扣 TPM/RPM/并发计数，超出即抛 429（`litellm/proxy/hooks/parallel_request_limiter_v3.py :: PROXY_MaxParallelRequestsHandler_v3 :: async_pre_call_hook() :: +0`；注册见 `litellm/proxy/hooks/__init__.py` 的导出表）。429 响应带 `rate_limited_by: descriptor_key` 头（`parallel_request_limiter_v3.py :: +3350`，#51228），per-customer per-model tpm/rpm 用 `RateLimitedModel`/`_end_user_model_rate_limit_descriptor` 描述。这个 429 是 pre-call 限流，与 Router 内部的 deployment 冷却（04 篇）是两条独立的失败路径。

## add_litellm_data_to_request 的安全设计

```
litellm/proxy/litellm_pre_call_utils.py :: add_litellm_data_to_request() :: +0
```

两个值得注意的点（函数体开头）：

**防伪造**：客户端 metadata 里以 `user_api_key_` 开头的键一律删除（`+49` 起）——这些键是网关的身份注入区，客户端不得自己写。同时清洗 `_UNTRUSTED_ROOT_CONTROL_FIELDS` 里的内部键、拒 URL 型 OTel destination。

```python
if isinstance(_user_metadata, dict):
    for _mk in list(_user_metadata.keys()):
        if _mk.startswith("user_api_key_"):
            del _user_metadata[_mk]
```

**凭证转发**：按 `general_settings.forward_llm_provider_auth_headers` 决定是否把客户端的 `x-api-key`/`Authorization` 转给上游（`+84` 起）；MCP 凭证头会被过滤，`without_credential_headers`（`litellm_pre_call_utils.py :: without_credential_headers :: +0`）剔掉所有凭证头再记日志。

其余注入（相对本函数 `+115` 起的 `proxy_server_request` 组装）：`litellm_call_id`（客户端可传 `x-litellm-call-id` 复用）、trace id、key 的 metadata 等。几个基线后新增的注入/读取项：

| 注入/读取 | 出处 | 锚点 |
|---|---|---|
| `without_credential_headers` 剔除凭证头再入日志 | `litellm_pre_call_utils.py` | 定义 `+0`，用于 `_logging_safe_headers` 组装 |
| `resolve_tenant_otel_destinations` 租户级 OTel 目的地（#50728） | 同上 | 定义 `+0` |
| `get_tenant_logging_metadata` 租户日志元数据（key/team 的 metadata，剔除 callback 配置，#50135） | `LiteLLMProxyRequestSetup` | 定义 `+0` |
| Claude Code subagent 会话头（`x-claude-code-session-id`/`x-claude-code-agent-id`） | `add_litellm_metadata_from_request_headers` | 定义 `+0`，会话 id 提取约 `+29` |
| `x-litellm-total-timeout` 读取 | `common_request_processing.py :: total_timeout_for` | 见「total_timeout 作用域」节 |
| `x-litellm-priority` 读取（scheduler 路由） | `common_processing_pre_call_logic` | `+209` |
| served-model 助手族（#51058）：`pre_call_served_model` / `request_served_model` | `litellm_pre_call_utils.py` | 定义 `+0` / `+0`，auth 侧 `budget_served_model` |

served-model 预算：`user_api_key_auth.py :: budget_served_model`（`+0`，#51058）只对 chat/completions/responses/messages 路由且 body `model` 与路径一致的请求，按「服务所用模型」判断零成本预算豁免；`_normalize_model_for_auth`（`+0`）做 model_group_alias/Codex 解析。auth 在 pre-call 前已 `arm_routing_cooldowns`（`+0`）预读冷却，并把限流计数接到 Rust store（`_spend_counter_store`）。

## total_timeout 作用域（408）

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: _within_total_timeout() :: +0
litellm/litellm_core_utils/total_deadline.py :: enforce_total_timeout_scope() :: +0
```

`total_timeout` 只约束「非流式、非后台」的 chat/completions、messages、responses 请求。`total_timeout_for`（`common_request_processing.py :: total_timeout_for :: +0`）优先读头 `x-litellm-total-timeout`、其次 body 字段 `total_timeout`；对不能约束的请求，body 值抛 400、头值忽略放行。`_within_total_timeout`（`+0`）用 `total_deadline` 上下文包住整个处理协程，超时抛 `TotalTimeoutExpired` 映射成 408。

在 Router 侧，`route_llm_request.py :: route_request`（`+10`）对 data 再调一次 `enforce_total_timeout_scope`（`total_deadline.py :: enforce_total_timeout_scope :: +0`）；Rust 核心的 `_routed_attempt` 在 provider 调用前也会调它（`router_rust/core.py :: RustCore :: _routed_attempt :: +14`），`_run_steps` 对 `sleep` 步骤会检查重试退避是否超出 deadline（`router_rust/core.py :: _run_steps` 的 sleep 分支）。

## route_request 决策树

```
litellm/proxy/route_llm_request.py :: route_request() :: +0
```

入口先做两件外围事：

1. `_merge_router_settings_override(data)`（`+11`）：允许客户端按请求覆盖 router 设置（fallbacks、num_retries、routing_strategy 等），但受 `GATED_MOCK_PARAM_NAMES` 门禁约束——mock 类参数（`mock_testing_rate_limit_error` 等）默认禁止，需配置 `dangerously_allow_mock_testing_request_params` 放行
2. 模型找不到时做一次 registry read-through 重试（`route_request :: except ProxyModelNotFoundError 分支`，`+21` 至 `+44`）

主体 `_route_request_single_attempt`（`route_llm_request.py :: _route_request_single_attempt() :: +0`）的完整决策树：

```
data 里有 api_key 或 api_base？
├─ 是 → 绕过 model_list，直接调（router 或 litellm）
├─ data 里有 user_config（自带 router 配置）→ 建临时 router 调用
└─ llm_router 存在？
   ├─ model 是 pass-through 全放行（pass_through_all_models）→ litellm 直调
   ├─ model 命中通配（wildcard 配置）或 default_deployment → router 调用
   ├─ model 是 deployment_names（精确部署名）→ router 调用（specific_deployment=True）
   ├─ model 在 team 的 model 配置里 → router 调用
   ├─ model 是 registry group 集合 → getattr(llm_router, route_type)(**data)
   └─ 都不匹配 → raise ProxyModelNotFoundError   # route_llm_request.py :: ProxyModelNotFoundError :: +0
└─ llm_router 不存在 → getattr(litellm, route_type)(...)  # 无 router 时直连 SDK
```

新增的**无 model 团队文件调用授权**（`route_llm_request.py :: _route_request_single_attempt` 内 `_model_less_team_vector_store_file_call`）：vector store 文件类路由（`avector_store_file_*`）在请求无 model 时，若命中团队文件部署，则 `_authorized_team_file_deployment` 取回凭据并直调 litellm（`+123` 至 `+139`）。

对本场景：`model="gpt-4o-mini"` 在 `model_list` 里 → registry group 命中 → `llm_router.acompletion(**data)`。

`route_request` 的返回值是 `getattr` 拿到的**方法调用协程**，没有 await——它只负责「选函数」，执行在 `_process_llm_request` 里的 `asyncio.create_task` 之后。

## 决策树的状态影响

| 阶段 | data 里新增/变化的键 |
|---|---|
| pre-call 前 | `metadata`（含网关注入） |
| pre-call 后 | `litellm_call_id`、`litellm_logging_obj`、别名解析后的 `model`、guardrail 改写后的 `messages`、`proxy_server_request` |
| route 后 | 无变化（只是选出协程），router-only 设置已被剥离出 data |

## 失败传播

pre-call 阶段的失败有两类：

- 业务失败（限流 429、guardrail 拦截）：走 `ProxyException` 直接回客户端；`_pre_call_with_fallbacks` 还会对 per-model 429 尝试配置的 rate-limit fallback
- pre-call 自身崩溃：`_pre_call_with_fallbacks` 保证回调收到 failure 事件后才向上抛

路由失败（`ProxyModelNotFoundError`）已是 404 语义的 `HTTPException` 子类，端点层原样返回。

下一跳进入 Router 内部：deployment 是怎么被选中的。