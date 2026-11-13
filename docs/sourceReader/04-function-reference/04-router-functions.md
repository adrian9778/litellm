# 函数级解析：Router 门面

> 所属层级：第四层（源码补齐） | 覆盖：`router.py` 门面、`router_api.py` 设置与观察面、`router_python_host.py` 宿主边界
>
> 核心边界：`litellm.Router` 是一个**零逻辑门面**。它不选路、不重试、不冷却。所有决策在进程内的 Rust 核心（`litellm/router_rust/core.py :: RustCore`，经 `litellm/rust/crates/router-core`）里完成。Rust 核心只经 `router_python_host.py :: PythonHost` 这一个边界回到 litellm 包执行推理。本篇文章从**门面视角**讲 Router 如何把成员转发给核心；Rust 核心内部（make_core → build → 端点 → steps → _Driver）见 [13-rust-router-core.md](13-rust-router-core.md)。

## 0. 一句话定位

`litellm/router.py`（506 行）定义 `Router` 门面类（`Router` 410 起）：构造期只做 `self._attach(make_core(build_router_config(router_arguments(...)), python_host))`（`Router.__init__` 419），此后**每个成员读写都转发给 `_core`**，类本身不含任何路由逻辑。门面禁止子类化（`__init_subclass__` 411 抛 `TypeError`），扩展走 `register_plugin`（自定义路由）/ `apply`（设置）/ `observe`（结果观察）三条入口。`router_api.py` 里的 `RouterRegistry`、`RouterSettings`、`RouterHealth`、`ChangeSet`、`ApplyResult` 不是"端点方法"，而是**设置与观察面**：真正执行推理的端点是核心经 `RustEndpoints` 服务的。

## 1. 门面与核心的分层

```text
┌─────────────────────────────── 门面层 ───────────────────────────────┐
│ litellm/router.py :: Router（410 起）                                  │
│   __init__ +0: _attach(make_core(build_router_config(...), host))     │
│   _attach +0: self.__dict__["_core"] = core（成员全部转发 _core）        │
│   __getattribute__ +0: 读不到 → getattr(core, name)                    │
│   __setattr__ +0: 写到 _core（patchable 方法同时镜像回门面）             │
│   _RouterType（metaclass, 337 起）: 类级读/打补丁也落到核心类             │
│   __init_subclass__ +0: 抛 TypeError（禁子类化）                       │
└───────────────────────────────┬──────────────────────────────────────┘
                                 │ make_core()（router_core.py 51）
                                 ▼
┌─────────────────────────────── 核心层（Rust） ───────────────────────┐
│ litellm/router_rust/core.py :: RustCore（1394 起）                    │
│   build +0 → __init__ +0：进程内决策体（选路/重试/fallback/冷却/用量）   │
│   _drive +0 → _run_steps +0 → _Driver（attempt/select/pre_route/...） │
│   _endpoints: RustEndpoints（router_rust/invoke/endpoints.py 1431）   │
└───────────────────────────────┬──────────────────────────────────────┘
                                 │ PythonHost.invoke（router_python_host.py 107）
                                 ▼
┌─────────────────────────────── 执行层（litellm 包） ──────────────────┐
│ litellm.<op>（acompletion / aembedding / ...）按 provider 实际发请求     │
│ 执行层由 litellm/rust_bridge/catalog.py 决定（PYTHON_ONLY / RUST_REQUIRED）│
└─────────────────────────────────────────────────────────────────────┘
```

## 2. `Router` 门面类

```
litellm/router.py :: Router :: +0（410 起）
```

| 项 | 内容 |
|---|---|
| 职责 | 零逻辑门面：持有 `_core`，把所有成员读写转发给 Rust 核心；提供类型检查存根（`Router` 265 起，`TYPE_CHECKING` 下）供 IDE 使用 |
| 参数 | `__init__`（`+0`）接受 `*args, **kwargs`，签名由 `Router.__init__.__signature__ = _CORE_SIGNATURE`（`+487`）替换成 `_router_init` 的形参（`_router_init` 57 起） |
| 返回 | 一个已挂好核心的 Router 实例 |
| 前置 | `make_core` 可构造 `RustCore`（Rust 桥可用且参数被核心支持） |
| 后置 | `self._core` 可用；未支持参数时 `build` 抛 `RustBridgeDeclined` |
| 核心算法 | `__init__`（`+0`）仅一行：`self._attach(make_core(build_router_config(router_arguments(*args, **kwargs)), python_host))`。`from_config`（`+421`）是等价入口，直接 `cls.__new__` + `_attach(make_core(config, host))` |
| 错误处理 | `__init_subclass__`（`+0`）对任何子类化抛 `TypeError`，并提示改用 `register_plugin()` / `apply()` / `observe()` |

门面转发靠三个魔法方法：

| 方法 | 行为 |
|---|---|
| `__getattribute__`（`+0`） | 先找自身，找不到则 `getattr(core, name)`；核心也没有时重新抛成"Router 没有该属性" |
| `__setattr__`（`+0`） | `_core` 还没挂时写入 `_pending`；挂好后 `setattr(core, name, value)`，`_patchable_method`（`+401`）判定为可补丁方法时镜像回门面自身（`mock.patch.object(router, ...)` 才找得到） |
| `__delattr__`（`+0`） | 从 `_core` 删除同名成员 |
| `_attach`（`+0`） | 存入 `self.__dict__["_core"]`，并把 `_pending` 里的值 flush 到核心；核心记 `_core_owner` 反向引用门面 |

`_RouterType` 元类（`+337`）让**类级**访问（`Router._helper`）、`dir()` 和类级打补丁同样落到核心类，所以 `Mock(spec=Router)` 能看到核心成员与端点（`+375` `__dir__` 并入 `endpoint_names()`）。

## 3. `router_arguments()` 与 `build_router_config()`

```
litellm/router.py :: router_arguments() :: +0（214 起）
litellm/router_config.py :: build_router_config() :: [源码未读取，由 `router.py :: __init__` 调用]
```

| 项 | 内容 |
|---|---|
| 职责 | `router_arguments` 把构造参数按名快照成 `MappingProxyType`（位置参数绑定到形参），供 `route_request` 里 read-through 复用 |
| 核心算法 | `_CORE_SIGNATURE.bind_partial(None, *args, **kwargs)`（`+220`），`TypeError` 时抛 `TypeError(f"Router.__init__() {error}")`；逐值 `_PASSED_VALUE.validate_python`（`+211`） |
| 返回 | `Mapping[str, object]`（构造参数名 → 值，不含 `self`） |

## 4. 设置与观察面（`router_api.py`）

`router_api.py` **不定义 `Router` 类，也不定义端点方法**（全库 grep 无 `class Router(`）。它定义核心向门面暴露的视图与变更类型，真正的端点由核心的 `RustEndpoints` 服务：

| 符号 | 位置 | 职责 |
|---|---|---|
| `RouterRegistry` | `router_api.py :: RouterRegistry` 581 | 部署注册表视图（`registry()` 返回），读自核心句柄 |
| `RouterSettings` | `router_api.py :: RouterSettings` 1457 | 设置视图（`settings()` 返回），读自核心句柄 |
| `RouterHealth` | `router_api.py :: RouterHealth` 1582 | 健康视图（`health()` 返回） |
| `ChangeSet` | `router_api.py :: ChangeSet` 1706 | 变更集：`assign` / `settings` / `upsert` / `delete` / `redis_cache` / `refresh_model_info` |
| `ApplyResult` | `router_api.py :: ApplyResult` 1729 | `apply()` 的结果：`version` / `upserted` / `deleted` |
| `RoutingObservers` | `router_api.py :: RoutingObservers` 1738 | `observe()` 的结果：Slack alerting logger |
| `RoutingContext` | `router_api.py :: RoutingContext` 1816 | 路由插件/策略的运行上下文（读 `registry()` / `settings()` / `health()` / `select()`） |

这些类型由 `router_core.py :: RouterCore`（Protocol，27 起）和 `RustCore` 的方法返回：`registry()`、`settings()`、`health()`、`select()`、`apply()`、`observe()`、`register_plugin()`、`retire()`、`call()`（`router_core.py` 27-48）。

## 5. 扩展入口：`register_plugin` / `apply` / `observe`

```
litellm/router_rust/core.py :: RustCore :: register_plugin() :: +0（1992 起）
litellm/router_rust/core.py :: RustCore :: apply() :: +0（2033 起）
litellm/router_rust/core.py :: RustCore :: observe() :: +0（1980 起）
```

| 函数 | 职责 | 参数 | 返回 | 核心算法与错误处理 |
|---|---|---|---|---|
| `register_plugin`（`+0`） | 让一个 `CustomRoutingStrategyBase` 从今起替核心选部署 | `plugin` | `None` | 存 `_custom_strategy`；重绑 `_custom_discovery`；`self.__dict__["get_available_deployment"] = _custom_sync_pick(plugin)`（同步 pick）；删掉旧 `_core_async_get_available_deployment`。`pre_route` 步骤会先问这个自定义策略 |
| `apply`（`+0`） | 应用 `ChangeSet`：先 `_assign_host_settings`，再 `_apply_settings`，再 upsert/delete，最后挂 redis cache | `changes: ChangeSet` | `ApplyResult` | `changes.refresh_model_info` 抛 `TypeError`（要 `aapply`）；未知 assign 名抛 `ValueError`；Rust 核心不支持的设置抛 `RustCoreUnsupported`；`settings` 更新失败时 `raise update.failure`，已应用的设置保留 |
| `observe`（`+0`） | 返回路由观察器 | `logging_obj`（请求的 logging）、`request_scoped` | `RoutingObservers` | `request_scoped` 时走 `_serve_through_request_logging`；核心自身不注册 outcome callbacks，改由 `OptionalChecks.outcome_callbacks` 读请求原本会跑的回调 |

对应地，`router.py` 门面 docstring（第 4-8 行）自述：`Router holds no routing logic...the endpoint methods (acompletion, aembedding, aresponses, aanthropic_messages, ...) and the entry points (registry, settings, health, select, apply, observe, register_plugin, retire)` 全都被委托给核心。

## 6. `PythonHost` 宿主边界

```
litellm/router_python_host.py :: PythonHost :: +0（60 起）
litellm/router_python_host.py :: PythonHost :: invoke() :: +0（overload 存根在定义行前的同名重载，实现体 `+0`）
```

| 项 | 内容 |
|---|---|
| 职责 | Rust 核心与 litellm 包的**唯一边界**：推理调用、sleep、回调列表、进程缓存、用量存储都经 host。核心从不再回调进 Python router（`core.py` docstring 第 9-13 行） |
| `invoke(op)` | 在调用期查 `litellm.<op>`（`+107`）：点号路径走 `_dotted`，查不到抛 `AttributeError`，不可调用抛 `TypeError`。大量 `@overload` 存根（66-106）只为类型检查器标注每个 op 的返回类型 |
| `sleep` / `sleep_sync` | 重试退避的 `asyncio.sleep` / `time.sleep` |
| `dynamic()` | 进程级 `RouterDynamicConfig`，每次访问实时读 |
| `callbacks` / `callback_list` / `set_callback_list` | 进程回调清单（成功/失败/输入回调） |
| `global_cache` / `set_global_cache` | litellm 进程级 `Cache` |
| `routing_cache(config)` | 构建 `DualCache`（内存 + 可选 Redis），供冷却/失败计数/用量读写；由 `redis_cache_for`（`+162`）按 `redis_*` 参数解析 Redis |
| `router_usage(redis)` | 部署 tpm/rpm 的 `RouterUsageStore`（`redis/stores/router_usage`） |

`python_host: Final = PythonHost()`（模块级常量）是 `router.py` 用的单例，也是 `_router_init` 的 `_host` 默认值。

## 7. 类型与边界速查

| 名 | 位置 | 说明 |
|---|---|---|
| `RouterCore`（Protocol） | `router_core.py :: RouterCore` 27 | 核心接口（`runtime_checkable`）：`call` / `registry` / `settings` / `health` / `select` / `apply` / `observe` / `register_plugin` / `retire` |
| `make_core()` | `router_core.py :: make_core` 51 | 无条件 `RustCore.build(config, host)`；全文件 55 行 |
| `RustCore` | `router_rust/core.py :: RustCore` 1394 | 进程内 Rust 核心句柄（详见 13 篇） |
| `RustEndpoints` | `router_rust/invoke/endpoints.py :: RustEndpoints` 1431 | 端点服务类；`acompletion` 实现 1998，overload 存根 154 |
| `endpoint_names()` | `router_rust/invoke/endpoints.py :: endpoint_names` 686 | 所有可服务端点名集合（`dir()` 用） |
| `PythonHost` | `router_python_host.py :: PythonHost` 60 | 宿主边界 |

## 8. 已纠正的旧描述

| 旧描述 | 现状（新） |
|---|---|
| 「`router_api.py` 里的 `Router` 类有 `acompletion` 门面端点方法」 | `router_api.py` 无 `Router` 类；acompletion 是 `RustCore` 端点，实现走 `RustEndpoints.acompletion`（endpoints.py 1998），门面 `Router.__init__` 只挂核心 |
| `router_python_core.py :: PythonCore`（Python 核心、双核 `make_core`） | 文件已删除；`make_core`（router_core.py 51）无条件返回 `RustCore` |
| `_acompletion` / `async_function_with_retries` / `async_function_with_fallbacks` 在 `router_python_core.py` | 均已删除；单次尝试、重试、回退改由 Rust 核心句柄驱动，宿主步骤在 `_Driver` 中 |
| `router_utils/cooldown_handlers.py` 承担冷却读写核心 | 冷却改由 `litellm/redis/stores/router_cooldowns` 的 `RouterCooldownStore` + `RouterCooldownsHandle`（handle.py 11）驱动；用量由 `redis/stores/router_usage` |
| `Router` 成员在门面里实现 | 门面零逻辑，成员读写全转发 `_core`（`__getattribute__`/`__setattr__`） |

## 9. 跨篇导航

- [13-rust-router-core.md](13-rust-router-core.md)：Rust 核心内部专题（make_core → RustCore.build → 端点 → steps → _Driver → PythonHost.invoke）
- [05-acompletion-functions.md](05-acompletion-functions.md)：`main.acompletion` 经线程池的执行路径
- [06-http-handler-functions.md](06-http-handler-functions.md)：执行层 `BaseLLMHTTPHandler.async_completion`
- [03-routing-functions.md](03-routing-functions.md)：proxy 侧 `route_request` 怎么进入 Router