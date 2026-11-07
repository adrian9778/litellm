# Router 选部署：健康过滤、冷却、负载均衡、重试与回退

> 所属层级：第三层（主链路拆解） | 拆解对象：第二层场景的跳 6-7

## 本篇回答的问题

`llm_router.acompletion(**data)` 内部，怎么从 N 个 deployment 里选出 1 个？失败后重试和回退按什么顺序发生？冷却是什么？

## 门面与核心的分工

```
litellm/router.py :: Router :: +0                 # 门面（212 行）
litellm/router_core.py :: make_core() :: +0       # 构造期选定核心（Python 或 Rust）
litellm/router_python_core.py :: PythonCore :: acompletion() :: +0   # 真正实现
```

`Router` 的 docstring 写明设计意图：Router 不持有路由逻辑，构造时选一个 `RouterCore`，把所有成员方法委托出去。Python 侧的 `PythonCore`（1.8 万行）持有 registry、冷却、策略、重试、fallback 全部状态。

## acompletion 的洋葱结构

`PythonCore.acompletion` 的实现体（`router_python_core.py :: PythonCore :: acompletion() :: 实现段`）只有一个模式：

```python
kwargs["original_function"] = self._acompletion
...
original_function = self.async_function_with_retries（或 fallbacks 包装）
response = await original_function(**request_kwargs)
```

洋葱从外到内：

```
acompletion()
└─ async_function_with_fallbacks()      # 外层：换 model group
   └─ async_function_with_retries()     # 中层：换部署重试
      └─ _acompletion()                 # 内层：单次尝试
         ├─ _core_async_get_available_deployment()   # 选部署
         ├─ async_routing_strategy_pre_call_checks() # TPM/RPM 预检
         └─ _host.invoke("acompletion")(...)         # 真调用（跳 8）
```

锚点：`async_function_with_fallbacks :: +0`（`router_python_core.py:9577`）、`async_function_with_retries :: +0`（9717）、`_acompletion :: +0`（5004）。

## 选部署：过滤链

`_core_async_get_healthy_deployments`（`router_python_core.py:15973`）按固定顺序过滤：

| 序 | 过滤器 | 作用 |
|---|---|---|
| 1 | `filter_team_based_models` | 剔除别的 team 专属部署 |
| 2 | `filter_web_search_deployments` | 剔除纯 web-search 部署 |
| 3 | route filter | 区域/标签等路由约束 |
| 4 | `_async_filter_health_check_unhealthy_deployments` | 剔除健康检查失败的部署（注释强调：在冷却检查之前） |
| 5 | cooldown filter：`async_get_cooldown_deployments` + `_filter_cooldown_deployments` | 剔除冷却中的部署 |

随后 `_core_async_get_available_deployment`（`_acompletion() :: +21` 调用）在幸存者里按策略挑一个：

| 策略名 | 文件 | 含义 |
|---|---|---|
| `simple-shuffle`（默认） | `router_strategy/simple_shuffle.py :: simple_shuffle :: +0` | 加权随机 |
| `least-busy` | `router_strategy/least_busy.py` | 选进行中请求最少的 |
| `latency-based-routing`（usage-based） | `router_strategy/lowest_latency.py` | 滑动窗口延迟最低 |
| `cost-based-routing` | `router_strategy/lowest_cost.py` | 单价最低 |
| `lar1` | `router_strategy/lar1_routing.py` | 学习型路由（实验） |

策略通过 `self._core_routing_strategy`（`router_python_core.py :: 构造段 :: +1941 附近`）持有，可用 `register_plugin` 换成自定义实现。

## 冷却机制

冷却 = 部署失败太多次后，在时间窗口内被整体跳过。状态存 Router 的共享缓存（内存 + 可选 Redis，多 worker 共享）：

```
litellm/router_utils/cooldown_handlers.py :: async_get_cooldown_deployments() :: +0
litellm/router_utils/cooldown_handlers.py :: set_cooldown_deployments() :: +0
```

写入时机：单次尝试失败后，`_acompletion` 的异常处理里 `set_cooldown_deployments`（`router_python_core.py:10481`、`10873` 两处调用）。是否进入冷却由 `allowed_fails`（允许连续失败次数）与 `cooldown_time`（秒）控制，可按 deployment 或全局配置。

单次尝试伪代码（`_acompletion() :: +0 至 +100`）：

```
deployment = 选部署（上面的过滤链 + 策略）
async with max_parallel_requests_limit:        # 并发闸门（若配置）
    await async_routing_strategy_pre_call_checks(deployment)  # TPM/RPM 计数预检
    response = await _host.invoke("acompletion")(**compacted_input)
    检查 ContentPolicyViolation → 需要时转异常
    记录 success_calls、打 "200 OK" 日志
    return response
（异常路径）set_cooldown_deployments(...) → 向上抛给重试层
```

## 重试层

`async_function_with_retries`（`router_python_core.py:9717`）：

1. 取 `num_retries`：请求参数 > deployment 配置 > 全局配置 > 0（`_deployment_num_retries :: +0`）
2. 循环调用 `original_function`（每次内部重新选部署，冷却会把坏部署自动排除）
3. 异常先过 retry policy（按错误类型/模型定次数，`model_group_retry_policy` 支持 key/team 级覆盖），再判断该错误是否值得重试
4. 重试用尽 → 向上抛给 fallback 层

## Fallback 层

`async_function_with_fallbacks`（`router_python_core.py:9577`）：

1. 记录 `attempted_fallbacks` 计数与 `original_model_group` 进 metadata
2. 三类回退按序尝试（配置于 YAML 的 `router_settings.fallbacks` 等）：

| 类型 | 触发条件 | 行为 |
|---|---|---|
| 普通回退 | 任何重试耗尽 | 换配置的备用 model group 重跑 |
| context window 回退 | `ContextWindowOverflowError` | 换更大窗口的 group |
| content policy 回退 | 内容审查拒绝 | 换审查更宽松的 group |

3. `ROUTER_MAX_FALLBACKS`（常量，`litellm/constants.py`）限制回退深度，防环

本场景（单部署、成功）一次尝试即返回，整个洋葱只穿过最内层。

## 状态与并发

| 状态 | 位置 | 并发语义 |
|---|---|---|
| registry（deployments） | `PythonCore` 内存 + 配置热更新 | 读多写少 |
| 冷却表 | DualCache（内存→Redis） | 多 worker 共享 |
| TPM/RPM 计数 | Redis（无 Redis 时内存降级） | 原子 INCRBY |
| 进行中请求计数（least-busy） | `InMemoryCache` | 进程内 |

## 失败传播到 Proxy

重试与回退都耗尽后，最后一个异常穿过 `_host.invoke` 边界向上抛，`_process_llm_request` 的 try/except 把它交给 Proxy 异常处理（第三层第 8 篇收尾）。Router 在抛出前已完成：冷却记录、retry/fallback 计数写入 metadata、failure 回调触发（由日志管线驱动）。

下一篇进入 SDK 世界：`litellm.acompletion` 内部。
