# Pre-call 处理与路由决策

> 所属层级：第三层（主链路拆解） | 拆解对象：第二层场景的跳 4-5

## 本篇回答的问题

鉴权通过之后、Router 接手之前，请求经历了什么加工？`model` 字符串是怎么对上 model group 的？兜底分支有哪些？

## 调用链

```
_process_llm_request()
└─ _pre_call_with_fallbacks()                                  common_request_processing.py :: +2714
   └─ common_processing_pre_call_logic()                       common_request_processing.py :: +2380
      ├─ add_litellm_data_to_request()                         litellm_pre_call_utils.py :: +2611
      ├─ 配置合并（user_*、model alias、层级 router 设置）
      ├─ function_setup() → logging_obj                        litellm/utils.py :: function_setup
      ├─ pre_call_hook()（含限流、guardrail）                    proxy_logging_obj
      └─ 返回 (增强 data, logging_obj)
```

`_pre_call_with_fallbacks` 的职责是把 pre-call 本身的异常也纳入回调（失败也要留痕），正常路径直接透传到 `common_processing_pre_call_logic`。

## common_processing_pre_call_logic 的步骤清单

```
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: common_processing_pre_call_logic() :: +0
```

按源码顺序（`+117` 起）：

| 步 | 动作 | 源码锚点（相对本函数） |
|---|---|---|
| 1 | `add_litellm_data_to_request` 注入网关数据 | `+123` |
| 2 | 记录请求元数据、queue 时间 | `+134` 至 `+165` |
| 3 | 应用全局默认：`user_temperature` / `user_request_timeout` / `user_max_tokens` / `user_api_base` | `+180` 至 `+188` |
| 4 | `litellm.model_alias_map` 别名解析 | `+192` |
| 5 | 层级 router 设置更新（DB 覆盖 YAML） | `+205` |
| 6 | `litellm.utils.function_setup` 构造 `Logging` 对象 | `+251`，随后写入 `data["litellm_logging_obj"]` |
| 7 | 合并 model 级 guardrail 配置 | `+261` |
| 8 | `proxy_logging_obj.pre_call_hook`（执行全部 pre-call 回调） | `+293` |
| 9 | guardrail 之后的 message 刷新（PII 掩码可能改写 messages） | `+320` |

步骤 8 是限流真正发生的地方：`PROXY_HOOKS` 注册的限流器实现了 `async_pre_call_hook`，在 Redis 上扣 TPM/RPM/并发计数，超出即抛 429（`litellm/proxy/hooks/parallel_request_limiter_v3.py :: PROXY_MaxParallelRequestsHandler_v3 :: async_pre_call_hook() :: +0`，4415 行处；注册见 `litellm/proxy/hooks/__init__.py :: +24`）。

## add_litellm_data_to_request 的安全设计

```
litellm/proxy/litellm_pre_call_utils.py :: add_litellm_data_to_request() :: +0
```

两个值得注意的点（函数体开头）：

**防伪造**：客户端 metadata 里以 `user_api_key_` 开头的键一律删除（`+48 至 +53`）——这些键是网关的身份注入区，客户端不得自己写。

```python
if isinstance(_user_metadata, dict):
    for _mk in list(_user_metadata.keys()):
        if _mk.startswith("user_api_key_"):
            del _user_metadata[_mk]
```

**凭证转发**：按 `general_settings.forward_llm_auth` 决定是否把客户端的 `x-api-key`/`Authorization` 转给上游（`+58 至 +86`）；MCP 凭证头会被过滤。

其余注入：`litellm_call_id`（客户端可传 `x-litellm-call-id` 复用）、trace id、key 的 metadata 等。

## route_request 决策树

```
litellm/proxy/route_llm_request.py :: route_request() :: +0
```

入口先做两件外围事：

1. `_merge_router_settings_override(data)`：允许客户端按请求覆盖 router 设置（fallbacks、num_retries、routing_strategy 等），但受 `GATED_MOCK_PARAM_NAMES` 门禁约束——mock 类参数（`mock_testing_rate_limit_error` 等）默认禁止，需配置 `dangerously_allow_mock_testing_request_params` 放行
2. 模型找不到时做一次 registry read-through 重试（`route_request() :: except ProxyModelNotFoundError 分支`）

主体 `_route_request_single_attempt`（`route_llm_request.py :: _route_request_single_attempt() :: +0`）的完整决策树：

```
data 里有 api_key 或 api_base？
├─ 是 → 绕过 model_list，直接调（router 或 litellm）
├─ data 里有 user_config（自带 router 配置）→ 建临时 router 调用
└─ llm_router 存在？
   ├─ model 是 pass-through 全放行（pass_through_all_models）→ litellm 直调
   ├─ model 命中通配（wildcard 配置）→ router 调用
   ├─ model 是 deployment_names（精确部署名）→ router 调用（specific_deployment=True）
   ├─ model 在 team 的 model 配置里 → router 调用
   ├─ model 在 registry group 集合 → getattr(llm_router, route_type)(**data)
   └─ 都不匹配 → raise ProxyModelNotFoundError   # route_llm_request.py :: ProxyModelNotFoundError :: +226
└─ llm_router 不存在 → getattr(litellm, route_type)(...)  # 无 router 时直连 SDK
```

对本场景：`model="gpt-4o-mini"` 在 `model_list` 里 → registry group 命中 → `llm_router.acompletion(**data)`。

`route_request` 的返回值是 `getattr` 拿到的**方法调用协程**，没有 await——它只负责「选函数」，执行在 `_process_llm_request` 里的 `asyncio.create_task` 之后。

## 决策树的状态影响

| 阶段 | data 里新增/变化的键 |
|---|---|
| pre-call 前 | `metadata`（含网关注入） |
| pre-call 后 | `litellm_call_id`、`litellm_logging_obj`、别名解析后的 `model`、guardrail 改写后的 `messages` |
| route 后 | 无变化（只是选出协程），router-only 设置已被剥离出 data |

## 失败传播

pre-call 阶段的失败有两类：

- 业务失败（限流 429、guardrail 拦截）：走 `ProxyException` 直接回客户端
- pre-call 自身崩溃：`_pre_call_with_fallbacks` 保证回调收到 failure 事件后才向上抛

路由失败（`ProxyModelNotFoundError`）已是 404 语义的 `HTTPException` 子类，端点层原样返回。

下一跳进入 Router 内部：deployment 是怎么被选中的。
