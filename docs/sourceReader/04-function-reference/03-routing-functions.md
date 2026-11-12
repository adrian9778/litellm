# 函数级解析：路由函数

> 所属层级：第四层（源码补齐） | 覆盖：`proxy/route_llm_request.py`、`proxy/litellm_pre_call_utils.py`

引用规范：`文件 :: 类 :: 函数 :: +偏移`，`+0` 为定义行。本篇所有偏移已回代码核对（基线 `0608a41a07`）。

## 1. `route_request()`

```
litellm/proxy/route_llm_request.py :: route_request() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 代理层路由的稳定入口：total_timeout scope 校验 + 合并 per-request 设置 + 单次尝试 + 模型未找到时的 read-through 重试 |
| 参数 | `data: dict`、`llm_router: LitellmRouter \| None`、`user_model: str \| None`、`route_type: RouteType`、`user_api_key_dict: UserAPIKeyAuth \| None` |
| 返回 | 未 await 的调用协程（`llm_router.acompletion(**data)` 等） |
| 前置 | `data` 含 model（多数分支） |
| 后置 | 不执行任何 LLM 调用，只做选择；body 里的 `total_timeout`/`router_settings_override` 键已剥离 |
| 错误处理 | `ProxyModelNotFoundError` / `ProxyMissingParamWithoutLoadedModelError` 且可 read-through 时，触发 `model_registry_read_through.attempt(requested_model)` 后用最新 `proxy_server.llm_router` 重试一次 |

核心算法（`+0` 起）：

1. `+11`：`enforce_total_timeout_scope(data)`——把「body total_timeout 用在流式/后台请求」判为不适用（`litellm_core_utils/total_deadline.py :: enforce_total_timeout_scope() :: +0`，162 行）。只在当前请求确实进入 total_timeout scope（`base_process_llm_request` 的 `_within_total_timeout` 已在 `route_request` 外层开启）时才有意义：若请求不可夹（流式或后台），body total_timeout 抛 `TotalTimeoutNotApplicable`（由 `_within_total_timeout` 转 400），header 版本则 `deadline.release()` 停止夹住
2. `+12`：`router_only_settings_from_override = _merge_router_settings_override(data)`——剥走客户端 per-request router 设置并返回被覆盖的键集合
3. `+13`：`try: return await _route_request_single_attempt(...)`
4. `+22`：`except (ProxyModelNotFoundError, ProxyMissingParamWithoutLoadedModelError)`——不可重试（`+25`，`retryable_with_model_read_through` 为假）或没有 model 名（`+26`）→ 直接 `raise`；read-through 失败（`+35`）→ 直接 `raise`；否则用 `proxy_server.llm_router` 重试一次（`+37`）

```python
router_only_settings_from_override = _merge_router_settings_override(data)
try:
    return await _route_request_single_attempt(...)
except (ProxyModelNotFoundError, ProxyMissingParamWithoutLoadedModelError) as e:
    # 不可重试的 / 没有 model 名的 → 直接抛
    # read-through 失败 → 直接抛
    # 否则刷新 router 后再试一次
```

## 2. `_route_request_single_attempt()`

```
litellm/proxy/route_llm_request.py :: _route_request_single_attempt() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 完整决策树（第三层第 3 篇已画全树，此处补函数级细节） |
| 参数 | 同上 + `router_only_settings_from_override: frozenset[str]`（已剥离、不得传给 SDK 的键） |
| 返回 | 调用协程 |
| 错误处理 | 模型不存在 → `ProxyModelNotFoundError`（`route_llm_request.py :: ProxyModelNotFoundError :: +0`，HTTPException 子类，`__init__` 内抛 400 `HTTPException`，带 `retryable_with_model_read_through`） |

执行序（相对偏移）：

1. `+8`：`raise_if_required_body_param_missing(route_type, data, llm_router)`——路由前参数完整性门禁
2. `+10`：`await add_shared_session_to_data(data)`——共享 aiohttp 会话注入（`route_llm_request.py :: add_shared_session_to_data() :: +0`，连接复用防冷启动）
3. `+12`：`raise_if_mock_testing_params_disallowed(data, allowed=mock_testing_params_allowed())`
4. `+14`：`direct_litellm_kwargs()` 内嵌函数——用 `JSON_OBJECT_ADAPTER.validate_python` 校验后剔除 `router_only_settings_from_override` 键，包成 `MappingProxyType`（只读视图）
5. `+23`：`team_id = get_team_id_from_data(data)`；`+24` `router_model_names = llm_router.registry().names(kind="group_set")`；`+25` `is_proxy_admin_without_team`
6. `+28`：Google GenAI 特判（`generationConfig` → `config`）
7. `+32` 至末尾：完整分岔树（`api_key/api_base` 直连 → `user_config` 自带 router → router 存在的多分支 → 无 router 直连 SDK）

分支细节补充（第三层未展开的）：

| 分支 | 条件 | 行为 |
|---|---|---|
| 凭证注入直连 | `data` 带 `api_key` 或 `api_base` | 有 router 时 `getattr(llm_router, route_type)(**data)`，无 router 时 `getattr(litellm, route_type)(**direct_litellm_kwargs())` |
| 批量（逗号分隔模型） | `route_type == "acompletion"` 且 `data["model"]` 含逗号 | `fastest_response` 走 `abatch_completion_fastest_response`，否则拆模型列表走 `abatch_completion(models=...)` |
| `user_config` 自带 router | `"user_config" in data` | `_route_user_config_request(data, route_type)` |
| Evals/Container/Interactions/Agents API | route_type 命中各自清单 | 部分提取部署凭证后直连 `litellm`，部分直连 `llm_router`，跳过模型路由 |
| 无 model 的团队文件调用 | `_model_less_team_vector_store_file_call` 命中（`+169`，vector_store 文件路由且带 team 凭证的 custom_llm_provider） | `_authorized_team_file_deployment` 取团队可用部署（`+172`），用 `_with_team_deployment_attribution`（`+177`）注入 model_group/deployment/model_info 元数据后直连 `litellm` |
| deployment_names / 通配模型 | model 不在 group_set | 按 `pass_through_all_models` → `default_deployment`/wildcard → `deployment_names` 顺序匹配（`+65` 起）；wildcard 用 `registry().patterns()` |
| 团队模型 | `team_model_name = registry().resolve(data["model"], kind="team_model", team_id=...)` | 命中则写回 `data["model"]` 走 router（`+47` 起） |
| proxy admin 无团队 + team_public | `is_proxy_admin_without_team` 且 model 在 `names(kind="team_public")` | router 调用 |
| 全放行 | 无 router 但 `user_model is not None` 或 `allm_passthrough_route` | `litellm` 直调（`+135`） |
| 兜底 | 全部未命中 | `raise ProxyModelNotFoundError(route, model_name)`（`+139`） |

## 3. `raise_if_required_body_param_missing()`

```
litellm/proxy/route_llm_request.py :: raise_if_required_body_param_missing() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | route_type 对应的必需参数缺失时提前 400，别等到 provider 报错 |
| 核心算法 | `+6`：`missing_param = _find_missing_required_body_param(route_type, data, llm_router)`；`missing_param is None` → 放行；否则按 `model_deployments_loaded` 选错误类——已加载部署时抛 `ProxyMissingRequiredParamError`（`+10`），否则抛 `ProxyMissingParamWithoutLoadedModelError`（可触发 read-through 重试） |
| 错误处理 | 抛带明确 param 名的 `ProxyException`（400） |

`_find_missing_required_body_param`（`route_llm_request.py :: _find_missing_required_body_param() :: +0`，324 行）检查三张表：`REQUIRED_ONE_OF_BODY_PARAMS_BY_ROUTE`（one-of，如 `acreate_interaction` 的 model/agent）、`REQUIRED_BODY_PARAMS_BY_ROUTE`（必需，如 acompletion 的 messages）、`REQUIRED_PRESENT_BODY_PARAMS_BY_ROUTE`（键须存在）+ `BODY_PARAM_ALTERNATIVES_BY_ROUTE`（替代键，如 `avector_store_search` 的 query 可用 query_image 替代；`acreate_interaction` 的 input 可用 continuation_token 替代）。

## 4. `raise_if_mock_testing_params_disallowed()`

```
litellm/proxy/route_llm_request.py :: raise_if_mock_testing_params_disallowed() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 门禁 mock 参数：客户端传 `mock_testing_*` / `mock_timeout` / `mock_delay` 时默认拒绝 |
| 参数 | `data`、`allowed: bool` |
| 核心算法 | `allowed` 为真（`mock_testing_params_allowed()` 读到 `general_settings.dangerously_allow_mock_testing_request_params`）→ 放行；否则 `+16`：`present = tuple(name for name in GATED_MOCK_PARAM_NAMES if name in data)`，非空则抛 `MockTestingParamsDisabledError`（`route_llm_request.py :: MockTestingParamsDisabledError :: +0`，400，消息指引管理员开 `MOCK_TESTING_CONFIG_KEY`） |
| 设计动机 | 拒绝（而非静默丢弃）保证「请求要合成失败却返回成功」这种假绿不会出现 |

`GATED_MOCK_PARAM_NAMES` 常量在 `route_llm_request.py :: GATED_MOCK_PARAM_NAMES :: +0`（40 行，含 `mock_testing_fallbacks`/`mock_testing_context_fallbacks`/`mock_testing_content_policy_fallbacks`/`mock_testing_rate_limit_error`/`mock_timeout`/`mock_delay`），与 `litellm/types/router.py :: MockRouterTestingParams` 由测试 `test_gated_mock_params_cover_mock_router_testing_params` 锁同步。

## 5. `_merge_router_settings_override()`

```
litellm/proxy/route_llm_request.py :: _merge_router_settings_override() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 从 data 里剥离客户端覆盖的 per-request router 设置，并把覆盖值合并回 data |
| 返回 | `frozenset[str]`：被覆盖且属于 router-only 的键名集合（`_ROUTER_ONLY_SETTINGS`） |
| 后置 | 覆盖值已写入 data（`+43`，`data.update(router_settings_from_override)`）；`router_settings_override` 原键已从 data 剥离，防止误传给 SDK |

核心算法：

- `+3`：`data.pop("enable_tag_filtering", None)`
- `+4`：`drop_params` 为真时用 `_JSON_OBJECT_OR_DROPPED_ADAPTER`（容错），否则 `_OPTIONAL_JSON_OBJECT_ADAPTER`
- `+10`：`data.pop("router_settings_override", None)` 解析；`ValidationError` → 抛 400 `ProxyException("router_settings_override must be a JSON object.")`
- `+13`：`user_config` 为 None 值则剥掉；`+14` 解析 `data.get("user_config")`
- `+15` 起：只有 `_PER_REQUEST_ROUTER_SETTINGS` 里的键、且 data/user_config 未自带时，才从 override 合并
- `+43`：`data.update(router_settings_from_override)`；`+44` 返回 `_ROUTER_ONLY_SETTINGS.intersection(...)`

`_PER_REQUEST_ROUTER_SETTINGS` 常量在 `route_llm_request.py :: _PER_REQUEST_ROUTER_SETTINGS :: +0`（59 行：`fallbacks`/`context_window_fallbacks`/`content_policy_fallbacks`/`num_retries`/`timeout`/`model_group_retry_policy`/`routing_strategy`/`enable_tag_filtering`）；`_ROUTER_ONLY_SETTINGS` 是其子集（`fallbacks`/`context_window_fallbacks`/`content_policy_fallbacks`/`model_group_retry_policy`）。

## 6. `add_litellm_data_to_request()`

```
litellm/proxy/litellm_pre_call_utils.py :: add_litellm_data_to_request() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 把网关掌握的一切注入请求：身份、头、call id、oauth、缓存控制，并剥离客户端伪造的内部键 |
| 参数 | `data`、`request`、`user_api_key_dict`、`proxy_config`、`general_settings`、`version` |
| 返回 | 增强后的 `data`（原位改 + 回绑） |
| 前置 | `data["metadata"]` 已被端点归一为 dict |
| 后置 | data 可直接交给 Router/SDK |

注入/清洗清单（相对偏移，函数体顺序）：

| 偏移 | 动作 |
|---|---|
| `+31` 起 | 按 key/team 权限剥离 `_UNTRUSTED_ROOT_CONTROL_FIELDS`（mock/redaction 控制字段例外）；`+35` `_reject_url_valued_destinations` 拒 URL 值目标 |
| `+36` 起 | `metadata` / `litellm_metadata` 二选一归一（JSON 字符串也解析，`+42` 的 `_normalized_metadata_object`） |
| `+48` | 剥离客户端伪造的 `user_api_key_*` 前缀键（`+52`，安全：proxy 只写一个 metadata dict，伪造的会污染 guardrail/spend/审计） |
| `+55` | `_raw_headers = RedactedDict(safe_get_request_headers(request))`；`+62` `clean_headers` 按 `forward_llm_auth` 决定是否转发 LLM 凭证头 |
| `+76` 起 | MCP 上游凭证头提取 + `redact_credential_headers` 得 `_logging_safe_headers`（脱敏，进日志） |
| `+85` | `forward_llm_auth` 且头带 `x-api-key` → `data["api_key"] = _headers["x-api-key"]`（`+86` 覆盖部署 key） |
| `+105` 起 | `data["proxy_server_request"]`：URL/方法/`_logging_safe_headers`/`credential_fields`/`arrival_time`（优先 `request.state.litellm_received_at`，让排队时间窗不含 auth 阶段） |
| `+114` | `safe_add_api_version_from_query_params(data, request)` |
| `+115` | `_metadata_variable_name` 定位；`+120` `add_litellm_data_for_backend_llm_call`（写 `litellm_metadata` 等）；`+129` `add_litellm_metadata_from_request_headers` |
| `+133` | `add_otel_trace_id_to_request`（父 span 透传）；`+141` `apply_missing_session_id_policy` |
| `+153` | `add_headers_to_llm_call_by_model_group`（按 model_group 转发头） |
| `+159` 起 | `add_internal_user_from_user_mapping`；`+164` `get_user_from_headers`（回退 `user_header_name`）→ `data["user"]`；`+172` `overwrite_user_with_key_hash` 时用 `_stampable_key_hash`（`+175`）写 `data["user"]` |
| `+176` | `data["secret_fields"] = SecretFields(raw_headers=_raw_headers)`（供 SecretManager 类回调，不进日志） |
| `+189` | `query_dict.get("api-version")` → `data["api_version"]`（动态 Azure api version） |
| `+193` | `add_provider_specific_headers_to_request`（OAuth token 交换后的 provider 专有头）→ `used_client_oauth_token`；`+197` `caller_credential_fields` |
| `+200` | Cache-Control 头的 `s-maxage` → `data["ttl"]`（`+203`） |
| `+224` 起 | 二次剥 `user_api_key_*`/`_UNTRUSTED_METADATA_CONTROL_FIELDS`（JSON 字符串 metadata 此时已变 dict，`+17` 的 isinstance 守卫才拦得住）；`+242` 未授权时 `_strip_client_pricing_overrides`；`+243` `strip_client_guardrail_information`/`_strip_router_reserved_metadata`；`+246` `_strip_client_callback_credentials`；`+248` 关消息日志时 `_strip_client_message_redaction_opt_out` |
| `+266` | `refresh_proxy_server_request_body_snapshot(data)`——在清洗后才填 body 快照，保证审计/记账看到的是干净的 metadata（排 `secret_fields` 与自引用） |
| `+274` 起 | `requester_metadata` 快照 + `_promoted_trace_control_fields`；`+284` 起 `litellm_metadata` 合并进 metadata dict |
| `+300` | `add_user_api_key_auth_to_request_metadata`；`+303` `litellm_api_version = version`；`+306` `global_max_parallel_requests` |
| `+314` 起 | `add_key_level_controls`、`add_team_and_project_level_controls`、`inherited_tags`（tag 策略合并，防伪造） |

## 7. 新增的 served-model 助手族

```
litellm/proxy/litellm_pre_call_utils.py :: request_served_model() :: +0
litellm/proxy/litellm_pre_call_utils.py :: pre_call_served_model() :: +0
litellm/proxy/litellm_pre_call_utils.py :: caller_alias_target() :: +0
litellm/proxy/litellm_pre_call_utils.py :: key_alias_target() :: +0
litellm/proxy/litellm_pre_call_utils.py :: team_alias_target() :: +0
litellm/proxy/litellm_pre_call_utils.py :: global_then_key_alias_target() :: +0
```

这一族（`#51058`）供 auth 层按「服务所用模型」核对预算（`user_api_key_auth.py :: budget_served_model`）。各函数均为纯函数，按别名改写顺序组合：

| 函数 | 作用 |
|---|---|
| `team_alias_target(model, uak, llm_router)`（3698 行） | 查 `user_api_key_dict.team_model_aliases`，返回团队别名改写后的目标；含陈旧别名（`_TeamAliasRewrite.warning`）与 `LITELLM_ENABLE_TEAM_STALE_ALIAS_BYPASS` 旁路逻辑（`_team_alias_rewrite` 内） |
| `key_alias_target(model, uak)`（3777 行） | `key_model_aliases_for_auth_check` 里 key 级别名改写，未命中返回原 model |
| `caller_alias_target(model, uak, llm_router)`（3786 行） | 团队别名后再 key 别名——即 `add_litellm_data_to_request` 之后请求体留下的 model |
| `global_then_key_alias_target(model, uak)`（3792 行） | 全局 `model_alias_map` 后再 key 别名——即 `common_processing_pre_call_logic` 之后留下的 model |
| `pre_call_served_model(model, uak, model_group_alias)`（3798 行） | `global_then_key_alias_target` 后再 `resolve_model_group_alias`——pre-call 发送所到的 model group |
| `request_served_model(model, uak, model_group_alias, llm_router)`（3804 行） | `caller_alias_target` 后再 `pre_call_served_model`——body 命名 model 经全部别名改写后真正发送到的 model group |

## 8. 其他新增读取/注入

```
litellm/proxy/litellm_pre_call_utils.py :: without_credential_headers() :: +0
litellm/proxy/litellm_pre_call_utils.py :: resolve_tenant_otel_destinations() :: +0
litellm/proxy/litellm_pre_call_utils.py :: LiteLLMProxyRequestSetup :: get_tenant_logging_metadata() :: +0
```

| 符号 | 作用 |
|---|---|
| `without_credential_headers(headers)`（1672 行） | 按 `_is_credential_header` 过滤，返回去掉凭证头的头映射（用于把请求头转发给上游/回调又不泄露凭证） |
| `resolve_tenant_otel_destinations(uak, request_headers)`（1429 行） | OTel V2 目的地下发（`#50728`）：key 级动态 logging 设置 > team 级，返回该请求应导出到的 OTLP 目的地元组；`failure`-only 条目跳过（dest 在 auth 期解析，尚不知结局）；`x-litellm-disable-callbacks` 禁用的 backend 不产生目的地 |
| `LiteLLMProxyRequestSetup.get_tenant_logging_metadata(uak)`（1683 行） | 提取 `user_api_key_metadata` / `user_api_key_team_metadata`（`strip_callback_config` 去掉回调配置，防凭证泄漏），供租户日志元数据（`#50135`） |

**Claude Code subagent 会话头读取**：`litellm_pre_call_utils.py :: _claude_code_subagent_tier_session`（`+0`，230 行）读 `x-claude-code-session-id` + `x-claude-code-agent-id` 两个请求头，两者都匹配 `_SESSION_ID_VALUE_RE` 时合成 `"{session}:{agent}"` 作为 subagent tier 会话标识（配合 `_child_tier_session_metadata`/`_parent_session_id` 构成 tier 级会话链）。

## 9. 模块级常量与类型

| 名 | 位置 | 作用 |
|---|---|---|
| `GATED_MOCK_PARAM_NAMES` | `route_llm_request.py :: GATED_MOCK_PARAM_NAMES :: +0`（40 行） | mock 参数门禁清单 |
| `_PER_REQUEST_ROUTER_SETTINGS` | `route_llm_request.py :: _PER_REQUEST_ROUTER_SETTINGS :: +0`（59 行） | 允许 per-request 覆盖的 router 设置 |
| `BODY_PARAM_ALTERNATIVES_BY_ROUTE` | `route_llm_request.py :: BODY_PARAM_ALTERNATIVES_BY_ROUTE :: +0`（282 行） | 必需参数的替代键表（如 vector_store_search.query 可用 query_image 替代） |
| `ProxyModelNotFoundError` | `route_llm_request.py :: ProxyModelNotFoundError :: +0`（234 行） | 400 语义路由错误，带 `retryable_with_model_read_through` |
| `ProxyMissingParamWithoutLoadedModelError` | `route_llm_request.py :: ProxyMissingParamWithoutLoadedModelError :: +0`（314 行） | 缺参且模型未加载 → 触发 read-through 重试 |
| `enforce_total_timeout_scope` | `litellm/litellm_core_utils/total_deadline.py :: enforce_total_timeout_scope() :: +0`（162 行） | 流式/后台请求的 body total_timeout 判不适用 |

两文件均为纯函数风格：`data` 是显式的共享可变 dict（代码注释用 `mutable-ok: request body is the proxy-wide mutable dict contract` 自我标注），除它之外没有全局可变状态。

## 行为变化速览（相对上一基线 `3f4dc93b40`）

- **`enforce_total_timeout_scope`**（`litellm_core_utils/total_deadline.py :: enforce_total_timeout_scope() :: +0`）新进 `route_request` 首步（`+11`）：把 body `total_timeout` 用在流式/后台请求判为不适用，与 `base_process_llm_request` 的 `_within_total_timeout` 包夹配合
- **`BODY_PARAM_ALTERNATIVES_BY_ROUTE`**（`route_llm_request.py :: BODY_PARAM_ALTERNATIVES_BY_ROUTE :: +0`）新增：必需参数允许替代键（`acreate_interaction`/`avector_store_search`）
- **无 model 的团队文件调用授权**：`_route_request_single_attempt` 的 `_model_less_team_vector_store_file_call`/`_authorized_team_file_deployment`（`+169` 起）——vector_store 文件路由无 model 但带团队凭证时，按团队可用部署授权并注入元数据直连 `litellm`
- **served-model 助手族**（`#51058`）：`request_served_model`/`pre_call_served_model`/`caller_alias_target`/`key_alias_target`/`team_alias_target`/`global_then_key_alias_target`（`litellm_pre_call_utils.py` 3698-3804 行）
- **`without_credential_headers`**（`litellm_pre_call_utils.py :: without_credential_headers() :: +0`）
- **`resolve_tenant_otel_destinations`**（`#50728`，`litellm_pre_call_utils.py :: resolve_tenant_otel_destinations() :: +0`）与 **`get_tenant_logging_metadata`**（`#50135`，`LiteLLMProxyRequestSetup.get_tenant_logging_metadata`）
- **Claude Code subagent 会话头**：`x-claude-code-session-id` / `x-claude-code-agent-id` 读取（`litellm_pre_call_utils.py :: _claude_code_subagent_tier_session`）
- **`_swap_in_model_cost_map` 已删**：若旧文引用过 `proxy_server.py :: _swap_in_model_cost_map`，现在应改 `reload_result.model_count`（`#` 基线后删除）