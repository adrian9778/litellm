# 函数级解析：路由函数

> 所属层级：第四层（源码补齐） | 覆盖：`proxy/route_llm_request.py`、`proxy/litellm_pre_call_utils.py`

## 1. `route_request()`

```
litellm/proxy/route_llm_request.py :: route_request() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 代理层路由的稳定入口：合并 per-request 设置 + 单次尝试 + 模型未找到时的 read-through 重试 |
| 参数 | `data: dict`、`llm_router: LitellmRouter \| None`、`user_model: str \| None`、`route_type: RouteType`、`user_api_key_dict: UserAPIKeyAuth \| None` |
| 返回 | 未 await 的调用协程（`llm_router.acompletion(**data)` 等） |
| 前置 | `data` 含 model（多数分支） |
| 后置 | 不执行任何 LLM 调用，只做选择 |
| 错误处理 | `ProxyModelNotFoundError` / `ProxyMissingParamWithoutLoadedModelError` 且可 read-through 时，触发 `model_registry_read_through.attempt(requested_model)` 后用最新 `proxy_server.llm_router` 重试一次 |

核心算法：

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
| 错误处理 | 模型不存在 → `ProxyModelNotFoundError`（`+226`，HTTPException 子类） |

执行序（相对偏移）：

1. `+8`：`raise_if_required_body_param_missing(route_type, data, llm_router)`——路由前参数完整性门禁
2. `+10`：`await add_shared_session_to_data(data)`——共享会话注入
3. `+12`：`raise_if_mock_testing_params_disallowed(data, allowed=mock_testing_params_allowed())`
4. `+14`：`direct_litellm_kwargs()` 内嵌函数——用 `JSON_OBJECT_ADAPTER.validate_python` 校验后剔除 router-only 键，包成 `MappingProxyType`（只读视图）
5. `+28`：Google GenAI 特判（`generationConfig` → `config`）
6. `+32` 至末尾：完整分岔树（`api_key/api_base` 直连 → `user_config` 自带 router → router 存在的六分支 → 无 router 直连 SDK）

分支细节补充（第三层未展开的）：

| 分支 | 条件 | 行为 |
|---|---|---|
| 凭证注入直连 | `data` 带 `api_key` 或 `api_base` | 有 router 时 `getattr(llm_router, route_type)(**data)`，无 router 时 `litellm` 直调 |
| 部署凭证借用 | model 不在 group 但 registry 有同名 deployment | `registry().credentials(model)` 取第一健康部署的凭证直调 |
| deployment_names | 精确部署名 | `getattr(llm_router, route_type)(**data, specific_deployment=True)` |
| 通配模型 | wildcard 配置命中 | router 调用 |
| 全放行 | `pass_through_all_models` | `litellm` 直调 |
| team 模型 | team 的 model 配置命中 | router 调用 |

## 3. `raise_if_required_body_param_missing()`

```
litellm/proxy/route_llm_request.py :: raise_if_required_body_param_missing() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | route_type 对应的必需参数缺失时提前 400，别等到 provider 报错 |
| 核心算法 | `missing_param is None` → 放行；`model_deployments_loaded` 特判（`+11`）——模型是「已加载的部署名」时放宽 |
| 错误处理 | 抛带明确 param 名的 `ProxyException` |

## 4. `raise_if_mock_testing_params_disallowed()`

```
litellm/proxy/route_llm_request.py :: raise_if_mock_testing_params_disallowed() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 门禁 mock 参数：客户端传 `mock_testing_*` / `mock_timeout` / `mock_delay` 时默认拒绝 |
| 参数 | `data`、`allowed: bool` |
| 核心算法 | `+16`：`present = tuple(name for name in GATED_MOCK_PARAM_NAMES if name in data)`，非空且未配置 `dangerously_allow_mock_testing_request_params` → 抛异常 |
| 设计动机 | 函数注释写明：mock 参数让调用「看起来成功」实际是合成的，会污染生产指标 |

`GATED_MOCK_PARAM_NAMES` 常量在 `+36`，与 `litellm/types/router.py :: MockRouterTestingParams` 由测试 `test_gated_mock_params_cover_mock_router_testing_params` 锁同步。

## 5. `_merge_router_settings_override()`

```
litellm/proxy/route_llm_request.py :: _merge_router_settings_override() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 从 data 里剥离客户端覆盖的 per-request router 设置（fallbacks、num_retries、routing_strategy 等，`_PER_REQUEST_ROUTER_SETTINGS` 常量在 `+59`） |
| 返回 | `frozenset[str]`：被覆盖的键名集合 |
| 后置 | 覆盖值已写入对应处理路径；原键从 data 剥离，防止误传给 SDK |

## 6. `add_litellm_data_to_request()`

```
litellm/proxy/litellm_pre_call_utils.py :: add_litellm_data_to_request() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 把网关掌握的一切注入请求：身份、头、call id、oauth、缓存控制 |
| 参数 | `data`、`user_api_key_dict`、`request`、`general_settings`、`proxy_config` 等 |
| 返回 | 增强后的 `data` |
| 前置 | `data["metadata"]` 已被端点归一为 dict |
| 后置 | data 可直接交给 Router/SDK |

注入清单（相对偏移，函数体顺序）：

| 偏移 | 动作 |
|---|---|
| `+37` | `metadata` / `litellm_metadata` 二选一归一（JSON 字符串也解析） |
| `+48` | 剥离客户端伪造的 `user_api_key_*` 键 |
| `+58` | 按配置决定是否转发 LLM 凭证头（`forward_llm_auth`），`x-api-key` → `data["api_key"]`（`+86`） |
| `+106` | `data["proxy_server_request"]`：请求方法/URL/头快照，供日志与回调 |
| `+118` 至 `+150` | metadata 初始化并写入脱敏头 `_logging_safe_headers` |
| `+170` | `data["user"]`：end user 身份（可哈希化，`+175` 的 `stampable_hash`） |
| `+177` | `data["secret_fields"]`：原始头打包（供 SecretManager 类回调，不进日志） |
| `+191` | 动态 api_version 注入 |
| `+194` | OAuth token 交换后的 provider 专有头 |
| `+204` | 缓存 TTL（`s-maxage` → `data["ttl"]`） |

## 7. 模块级常量与类型

| 名 | 位置 | 作用 |
|---|---|---|
| `GATED_MOCK_PARAM_NAMES` | `route_llm_request.py :: +36` | mock 参数门禁清单 |
| `_PER_REQUEST_ROUTER_SETTINGS` | `route_llm_request.py :: +59` | 允许 per-request 覆盖的 router 设置 |
| `ProxyModelNotFoundError` | `route_llm_request.py :: ProxyModelNotFoundError :: +0`（`+226`） | 404 语义路由错误 |

两文件均为纯函数风格：`data` 是显式的共享可变 dict（代码注释用 `mutable-ok: request body is the proxy-wide mutable dict contract` 自我标注），除它之外没有全局可变状态。
