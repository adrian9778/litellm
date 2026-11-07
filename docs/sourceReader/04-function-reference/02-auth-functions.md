# 函数级解析：鉴权模块

> 所属层级：第四层（源码补齐） | 覆盖：`proxy/auth/user_api_key_auth.py` 及 `auth_checks.py` 关键函数

## 1. `user_api_key_auth()`

```
litellm/proxy/auth/user_api_key_auth.py :: user_api_key_auth() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | FastAPI 依赖入口：编排 body 读取与鉴权构建 |
| 参数 | `request: Request`、`api_key`（FastAPI Security 注入的 Bearer 头）、`request_data` 等 |
| 返回 | `UserAPIKeyAuth` |
| 前置 | 全局 `master_key` 已加载（可为 None，即未设 master key） |
| 后置 | 抛出即代表请求被拒 |

核心算法：

1. `+14`：`_read_request_body_deferring_parse_failure(request)` 返回 `(request_data, body_parse_exception)` 二元组——解析错误先记下不抛
2. `+34`：`user_api_key_auth_builder(...)` 执行构建；成功时若 body 解析有遗留异常，此刻抛出（保证 401 优先于 400 的语义由调用方判断）
3. 失败兜底 `+62`：`_authorize_authenticated_request(...)` 尝试用请求里已有的已认证身份恢复（多阶段请求场景），失败才走统一异常处理
4. `+84`：body 解析失败且无身份 → `_record_unparsable_body_failure` 后抛出

## 2. `user_api_key_auth_builder()`

```
litellm/proxy/auth/user_api_key_auth.py :: user_api_key_auth_builder() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 三类凭证的分岔与核心构建 |
| 参数 | `request`、`api_key`、各厂商凭证头（`azure_api_key_header`、`anthropic_api_key_header`、`google_ai_studio_api_key_header`、`azure_apim_header`、`custom_litellm_key_header`）、`request_data` |
| 返回 | `UserAPIKeyAuth` |
| 前置 | 无（自行从 proxy_server 导入全局状态） |
| 后置 | token 有效时未写回缓存写时更新（缓存策略在缓存层） |

核心算法（按行序，偏移相对 `+0` 定义行）：

1. `+10`：从 `proxy_server` 模块导入全部全局单例（延迟导入避免循环依赖）
2. `+28`：`start_time` 优先取 `request.state.litellm_received_at`（入口尽早盖戳，注释说明：body 解析窗口不计入预处理时长）
3. DB 读前检查 `+39`：`pre_db_read_auth_checks`（trace 名 `litellm.proxy.auth.pre_db_read_auth_checks`）
4. 凭证分岔 `+621` 附近：
   - master key：`secrets.compare_digest(api_key, master_key)`，命中 → `_return_user_api_key_auth_obj` 直接构造全权限对象返回
   - `master_key_only_routes` 上的请求：非 master key 一律拒绝
   - 有 master key 已配置但库未连接且 key 不是 master key：明确报错（防误配后全员放行）
5. JWT 路径：`jwt_handler` 已配置且 token 形态像 JWT → `auth_jwt` 校验
6. virtual key 路径：查缓存（`user_api_key_cache.async_get_cache`）→ UI 哈希 → Prisma 查库；`valid_token is None`（`+687`）时给格式提示（`sk-` 前缀、JWT 形态 hint，`+689` 的 `_masked_key` 脱敏），见 `+687` 至 `+700`
7. 拿到 token 后 → `validate_resolved_virtual_key(...)` 做授权检查链

错误处理：全部异常进入 `_return_user_api_key_auth_obj` 之外的统一 except，转 `ProxyException`；`UserAPIKeyAuthExceptionHandler.handle_authentication_error`（`auth_exception_handler.py`）决定 HTTP 映射。

## 3. `validate_resolved_virtual_key()`

```
litellm/proxy/auth/user_api_key_auth.py :: validate_resolved_virtual_key() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 已解析 token 的授权检查链（模型访问 + 九级预算） |
| 参数 | `request`、`request_data`、`valid_token: UserAPIKeyAuth \| None`、`api_key`、`route`、`start_time`、`parent_otel_span`、`end_user_id`、`end_user_params`、`_end_user_object` |
| 返回 | 校验增强后的 `UserAPIKeyAuth` |
| 前置 | `valid_token` 非 None（master key/JWT 路径不经过此函数） |
| 后置 | 抛出即拒绝 |

检查序列（函数头 `noqa: C901` 注释自述「保持既有共享授权检查顺序」，实现体顺序）：

1. `+49`：`enforce_key_and_fallback_model_access`——key 允许模型 + 客户端声明的 fallback 模型一起校验
2. `+114`：team member 预算（`valid_token.team_member_spend` 非空时）——先查缓存 `team_membership_auth_cache_key`，未命中查 `LiteLLM_TeamMembership` 回填缓存
3. `+143` 附近：end user 预算与 `end_user_params` 合并
4. key 按模型预算：`resolve_model_budget` 解析 `model_max_budget` JSON 列（列损坏不崩鉴权，`UserAPIKeyAuth` 字段注释写明原因），各 limiter 逐级检查（`_KeyModelBudgetLimiter` 等 Protocol，`user_api_key_auth.py :: _KeyModelBudgetLimiter :: +364`）
5. 组织级、全局（`every-model`）预算：`_is_within_every_model_budget :: +581`

## 4. `_return_user_api_key_auth_obj()`

```
litellm/proxy/auth/user_api_key_auth.py :: _return_user_api_key_auth_obj() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 最终组装返回对象（DB 行 + 请求上下文） |
| 参数 | `valid_token`、`response`（含 user/team/org 关联数据）、`route`、`start_time`、`end_user_id` 等 |
| 返回 | `UserAPIKeyAuth` |
| 核心算法 | 字段铺开：DB 列 → Pydantic 字段；附加 `request_route`、`parent_otel_span`、per-model 限流映射；master key 路径传的是合成全权限 token |
| 错误处理 | 关联对象缺失（user/team 被删）→ 对应 HTTP 异常 |

## 5. `_can_object_call_model()`

```
litellm/proxy/auth/auth_checks.py :: _can_object_call_model() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 判断某身份对象（key/team/user）能否调用某模型 |
| 返回 | bool（不抛） |
| 核心算法 | 三层匹配：精确名 → `fnmatch` 通配（`*`、`anthropic/*`）→ model group 展开（alias、通配配置）。`models=["*"]` 全放行；空列表按 `general_settings` 语义处理 |

上游还有一层组织（`auth_checks.py :: _can_object_call_model` 的调用方 `enforce_key_and_fallback_model_access`）把 key/team/user/end-user 各自的结论 AND 起来。

## 6. 预算检查族

同构的一组函数（本文件 `+468` 至 `+720` 区间）：

| 函数 | 检查对象 |
|---|---|
| `_read_user_model_max_budget :: +468` | 读 user 级按模型预算 |
| `_check_user_model_budget :: +497` | user 预算 |
| `_check_team_model_budget :: +519` | team 预算 |
| `_check_end_user_model_budget :: +563` | end user 预算 |
| `_is_within_every_model_budget :: +581` | 每模型全局预算 |

共同模式：`spend + 本次预估 > max_budget` 则抛预算异常；预估用的 token 数来自请求的 tokenizer 计数（`admission_input_tokens` 等）。

## 7. 异常翻译

```
litellm/proxy/auth/auth_exception_handler.py :: UserAPIKeyAuthExceptionHandler :: handle_authentication_error() :: +0
```

| 异常类型 | HTTP |
|---|---|
| `HTTPException`（鉴权抛出） | 原状态码 |
| `ProxyException` | 原状态码 |
| `Exception` | 500，脱敏后返回 |

所有响应体保持 OpenAI error schema（`error.message/code/type`）。
