# 鉴权管线

> 所属层级：第三层（主链路拆解） | 拆解对象：第二层场景的跳 2

## 本篇回答的问题

`Authorization: Bearer sk-...` 是怎么变成一个 `UserAPIKeyAuth` 对象的？中间做了哪些校验，顺序是什么？限流为什么不在这一步？

## 入口与总体结构

```
litellm/proxy/auth/user_api_key_auth.py :: user_api_key_auth() :: +0
```

函数 docstring 一句话概括：校验用户传来的 API key 或 JWT，合法则返回 `UserAPIKeyAuth`。

外层函数只做编排（`user_api_key_auth() :: +11 至 +60`）：

```
user_api_key_auth(request, api_key, request_data)
├─ _read_request_body_deferring_parse_failure()   # 读 body 但推迟解析错误
├─ user_api_key_auth_builder(...)                 # 真正的鉴权构建器
├─ 失败时 _authorize_authenticated_request()      # 兜底：已认证身份复用
└─ body 解析失败在此刻再抛出
```

「推迟解析失败」是个细节设计：body JSON 坏了也要先试鉴权，这样错误响应里能带上调用者身份（比如 master key 用户能拿到 400 而不是 401）。

## 构建器：三种凭证的分岔

```
litellm/proxy/auth/user_api_key_auth.py :: user_api_key_auth_builder() :: +0
```

按凭证类型分三条路：

| 凭证 | 判定方式 | 路径 |
|---|---|---|
| master key | `secrets.compare_digest(api_key, master_key)` | 最短路径，全权限 |
| JWT | `JWTHandler.is_jwt(token)` / 配置了 jwt_auth | `handle_jwt.py` 解析签名后映射权限 |
| virtual key（`sk-` 开头的代理签发 key） | 默认路径 | 缓存 → DB 查 `LiteLLM_VerificationToken` |

master key 校验（`user_api_key_auth_builder() :: +2800 附近，compare_digest 在其中`）：

```python
is_master_key_valid = secrets.compare_digest(api_key, master_key)
...
if is_master_key_valid:
    _user_api_key_obj = await _return_user_api_key_auth_obj(...)
```

用 `compare_digest` 而非 `==` 防时序攻击。master key 直接拿到 proxy admin 身份，跳过所有预算检查（`user_api_key_auth_builder() :: is_master_key_valid 分支`）。

## virtual key 路径

命中顺序（`user_api_key_auth_builder() :: get_key_object 段`）：

```
1. user_api_key_cache.async_get_cache(cache_key)     # 内存+Redis（UserApiKeyCache）
2. ExperimentalUIJWTToken.get_key_object_from_ui_hash_key()   # UI 会话哈希
3. 未命中 → Prisma 查库（get_key_object_from_db trace 段）
```

查到的行就是 `LiteLLM_VerificationToken`（schema 见 `schema.prisma`），字段直接铺进返回对象：

```
litellm/types/proxy/auth/user_api_key_auth.py :: UserAPIKeyAuth :: +129
```

核心字段速览：

| 字段 | 含义 | 鉴权中的用途 |
|---|---|---|
| `token` / `api_key` | key 本体（哈希形式） | 身份标识 |
| `user_id` / `team_id` / `organization_id` | 归属三级 | 预算与权限的挂载点 |
| `models` | 允许的模型列表 | 模型访问检查 |
| `max_budget` / `spend` | 预算上限 / 已花费 | 预算检查 |
| `tpm_limit` / `rpm_limit` | 限流上限 | 交给限流 hook 用 |
| `user_tpm_limit` / `user_rpm_limit` | 用户级限流 | 同上 |
| `allowed_model_region` | 区域约束 | 部署过滤 |

key 不存在或格式不对时返回 401，并给格式提示（`sk-` 前缀检查、JWT 形态提示），见 `user_api_key_auth_builder() :: valid_token is None 分支`。注意代码注释强调错误提示不能依赖 message 文本判断类型。

## 校验序列（virtual key 路径）

`validate_resolved_virtual_key()`（`user_api_key_auth.py :: validate_resolved_virtual_key() :: +0`）里有一段自注释，就是官方的检查顺序，转写如下：

| 序 | 检查 | 实现锚点 |
|---|---|---|
| 1 | token 能否调用该模型 | `enforce_key_and_fallback_model_access`（含客户端声明的 fallback 模型） |
| 2 | token 的 user 是否超预算 | `_check_user_model_budget`（本文件） |
| 3 | user 在其团队内的花费是否超预算 | 同上系列 |
| 4 | 请求里的 `user` 参数（end user）是否超预算 | `_check_end_user_model_budget` |
| 5-7 | key/team/end-user 的按模型预算（`model_max_budget`） | `resolve_model_budget` + 各 limiter |
| 8 | token 花费是否超 team 预算 | `auth_checks.py` 系列 |
| 9 | team 花费是否超 organization 预算 | 同上 |

模型访问检查的核心在 `litellm/proxy/auth/auth_checks.py :: _can_object_call_model() :: +0`，支持通配（`*`、`anthropic/*` 这类 fnmatch 模式）与 model group 展开另一层含义是限流不在鉴权里做：TPM/RPM/并发的扣减由 pre-call hook `parallel_request_limiter_v3` 完成（见第三层第 3 篇），鉴权只把限流上限带出来放进 `UserAPIKeyAuth`。分工原因是限流需要「请求结束归还」的生命周期，与鉴权的「校验即结束」不同。

## 限流与预算的边界（容易混淆）

| 机制 | 在哪触发 | 状态存哪 |
|---|---|---|
| 预算检查（spend ≤ max_budget） | 鉴权阶段 | Postgres + 缓存 |
| TPM/RPM/并发限流 | pre-call hook 阶段 | Redis 计数器 |
| 部署级冷却 | Router 失败后 | Router 缓存 |

## 返回对象

```
litellm/proxy/auth/user_api_key_auth.py :: _return_user_api_key_auth_obj() :: +0
```

所有检查通过后，DB 行数据加上请求上下文（`request_route`、`parent_otel_span`、per-model 限流映射等）组装成 `UserAPIKeyAuth`，交给 FastAPI 注入端点函数签名。对 master key 请求，这个对象是凭空构造的全权限版本。

## 失败出口

| 检查失败 | 异常 | HTTP |
|---|---|---|
| key 无效/缺失 | `ProxyException`/`HTTPException` | 401 |
| 模型不在允许列表 | `ProxyException` | 403 |
| 预算超限 | `ProxyException`（预算类错误码） | 429 |
| key 只能访问特定路由 | `ProxyException` | 403 |

异常到 HTTP 的翻译在 `litellm/proxy/auth/auth_exception_handler.py :: UserAPIKeyAuthExceptionHandler :: handle_authentication_error() :: +0`。
