# 函数级解析：Router

> 所属层级：第四层（源码补齐） | 覆盖：`router.py` 门面、`router_api.py` 端点方法、`router_python_core.py` 核心

## 1. `Router.acompletion()`

```
litellm/router_api.py :: Router :: acompletion() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 门面端点：一行委托 |
| 参数 | `**kwargs`（调用方原样转发） |
| 返回 | `await self._router.acompletion(**kwargs)`（`+4`） |
| 设计 | `router_api.py` 里所有端点方法同构（aresponses、aembedding、adecisions、aanthropic_messages…全部一行委托给 `self._router`），保证门面零逻辑 |

`self._router` 是构造期由 `router.py :: Router.__init__()` 经 `make_core()` + host 绑定建好的宿主对象。门面在 `router.py :: Router :: +0` 的 docstring 中自述：「Router holds no routing logic」。

## 2. `PythonCore.acompletion()`

```
litellm/router_python_core.py :: PythonCore :: acompletion() :: +0（重载 +3762，实现 +3782）
```

| 项 | 内容 |
|---|---|
| 职责 | 包装洋葱：把 `_acompletion` 标记为 original_function，套上 retries（必要时再套 fallbacks） |
| 参数 | `model: str`、`messages: list[AllMessageValues]`、`stream: bool`、`**kwargs` |
| 返回 | `ModelResponse | CustomStreamWrapper`（重载按 `stream` 区分） |
| 前置 | model 是 registry 里的 group 名（或通配/部署名，由上游 `route_request` 保证） |
| 后置 | 异常向上抛（重试与回退耗尽后） |

实现体核心（`+3782` 至 `+3830`）：

```python
kwargs["original_function"] = self._acompletion
self._update_kwargs_before_fallbacks(model=model, kwargs=kwargs)
original_function = (self.async_function_with_retries 若无 fallbacks 配置，否则 fallbacks 包装)
response = await original_function(**request_kwargs)
```

`_update_kwargs_before_fallbacks` 在回退发生前把 model group 存进 metadata（回退后要能还原原始 group）。

## 3. `_acompletion()`

```
litellm/router_python_core.py :: PythonCore :: _acompletion() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 单次尝试：选部署 → 预检 → 调用 → 后置指标 |
| 参数 | `model`、展开的 OpenAI 参数（Router 会把 deployment 的 `litellm_params` 融进 kwargs） |
| 返回 | `ModelResponse | CustomStreamWrapper` |
| 前置 | 重试层已就位 |
| 后置 | 成功：`success_calls` 计数 + 部署指标记录；失败：冷却写入 |

核心算法（`+5004` 至 `+5140`）：

1. `+14`：流式 fallback 快照（`mid_stream_fallback_snapshot_kwargs`，流中断回退用）
2. `+21`：`deployment = await self._core_async_get_available_deployment(...)`
3. `+40`：`call_type="async_get_available_deployment"` 的遥测
4. 并发闸门：`max_parallel_requests_limit` 用 `contextlib.AsyncExitStack` 进入（`+94` 附近）
5. `+101`：`await self.async_routing_strategy_pre_call_checks(deployment, logging_obj, parent_otel_span)`——TPM/RPM 计数
6. `+106`：`response = await self._host.invoke("acompletion")(**compacted_input)`——真调用；`compacted_input` 由 `compact_to_fit` 压缩超长输入
7. `+110`：ContentPolicyViolation 检查（`_should_raise_content_policy_error`），需要时把正常响应转异常（触发 content policy fallback）
8. `+127`：`CustomStreamWrapper` 首块预读（`_aread_first_chunk`，让重试层能尽早发现空流）
9. `+130` 起：`success_calls` 计数、`"200 OK"` 日志、`_track_deployment_metrics`

## 4. `async_function_with_retries()`

```
litellm/router_python_core.py :: PythonCore :: async_function_with_retries() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 部署级重试循环 |
| 参数 | `*args, **kwargs`（透传给 `_acompletion`；`original_function` 已在 kwargs 里） |
| 返回 | 成功的响应 |
| 后置 | 每次失败：冷却写入、retry 计数进 metadata（spend logs 用） |

核心算法（`+9717` 至 `+9900`）：

1. `+2`：`original_function = kwargs.pop("original_function")`
2. `+9`：`model_group_retry_policy` 支持 per-request 覆盖（key/team 级）
3. `+11` 至 `+16`：`num_retries` 解析链：请求参数 → `self.num_retries` → 0（deployment 级配置在 `_deployment_num_retries :: +982`）
4. `+28`：`_metadata["max_retries"] = num_retries`
5. 循环体：try `original_function` → 成功即返回；except → retry policy 优先于通用判断（`+65` 注释：Check retry policy FIRST），再按错误类型决定是否可重试、换不换部署

## 5. `async_function_with_fallbacks()`

```
litellm/router_python_core.py :: PythonCore :: async_function_with_fallbacks() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | group 级回退循环（retries 的外层） |
| 参数 | 同上 |
| 核心算法 | `+32`：`fallbacks = kwargs.get("fallbacks", self._core_fallbacks)`；`include_fallback_errors`、`disable_fallbacks` 处理；按 fallback 类型（普通/context window/content policy）逐组重跑 retries 链；`ROUTER_MAX_FALLBACKS` 限深 |

## 6. `_core_async_get_healthy_deployments()`

```
litellm/router_python_core.py :: PythonCore :: _core_async_get_healthy_deployments() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | model group → 健康部署列表（五级过滤链） |
| 参数 | `model`、`parent_otel_span`、过滤上下文 |
| 返回 | 部署 dict 列表 |
| 核心算法 | 过滤链与偏移：team 过滤 `+31`、web-search 过滤 `+43`、route 过滤 `+51`、健康检查过滤 `+72`（注释强调在冷却之前）、冷却过滤 `+82` 至 `+93`。冷却旁路的安全阀：`+97` 注释写明只有健康检查路由在驱动冷却（`allowed_fails_policy` 已设）时才允许旁路 |

## 7. `_async_get_available_deployment()`

```
litellm/router_python_core.py :: PythonCore :: _async_get_available_deployment() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 在健康部署里按策略选 1 个 |
| 参数 | `model`、`healthy_deployments`（或内部自取）、`request_kwargs`、`parent_otel_span` |
| 返回 | 1 个部署 dict |
| 核心算法 | `+7` 注释：策略在 pre-routing hook 之后解析；`_get_routing_context :: +2704` 返回 `(strategy, strategy_selector)`；`simple-shuffle` 分支 `+41` 调 `simple_shuffle(...)`（`router_strategy/simple_shuffle.py :: simple_shuffle :: +0`），其余策略走各自 selector。tag 过滤（`get_deployments_for_tag`）在策略前先行 |

`simple_shuffle` 的算法：读每个部署的 `rpm`/权重（无配置则等权），加权随机抽样，同时负责 RPM 计数扣减。

## 8. 冷却读写

```
litellm/router_utils/cooldown_handlers.py :: async_get_cooldown_deployments() :: +0
litellm/router_utils/cooldown_handlers.py :: set_cooldown_deployments() :: +0
```

| 函数 | 职责 |
|---|---|
| `async_get_cooldown_deployments` | 读冷却中的部署 id 集（DualCache，多 worker 共享） |
| `set_cooldown_deployments` | 失败后写入冷却（`allowed_fails` 判定 + `cooldown_time` 窗口）；调用点在 `_acompletion` 异常路径（`router_python_core.py :: PythonCore :: _acompletion()` 内两处） |

## 9. 类型与边界

| 名 | 位置 | 说明 |
|---|---|---|
| `RouterCore` 协议 | `router_core.py :: RouterCore :: +0` | Python/Rust 双实现的接口约束 |
| `make_core()` | `router_core.py :: make_core() :: +0` | 按配置返回 PythonCore 或 Rust 核心 |
| `PythonHost.invoke()` | `router_python_host.py :: PythonHost :: invoke() :: +0` | 核心与 litellm 包的唯一边界（推理调用、sleep、回调注册、进程缓存都走 host） |
| `router_arguments()` | `router.py :: router_arguments() :: +0` | 构造参数的按名快照（`route_request` 里 read-through 复用） |
