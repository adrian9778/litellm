# 函数级解析：请求限流器

> 所属层级：第四层（源码补齐） | 覆盖：`proxy/hooks/parallel_request_limiter_v3.py :: PROXY_MaxParallelRequestsHandler_v3`

主链路 pre-call 阶段的限流执行者（第三层第 3 篇步骤 8）。类定义 `parallel_request_limiter_v3.py :: PROXY_MaxParallelRequestsHandler_v3 :: +0`，经 `proxy/hooks/__init__.py` 导出表注册进 `PROXY_HOOKS`。

## 1. `__init__()`

```
litellm/proxy/hooks/parallel_request_limiter_v3.py :: PROXY_MaxParallelRequestsHandler_v3 :: __init__() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 组装各维度的计数器句柄 |
| 状态 | TPM/RPM/并发三族的 Redis 计数器引用、内存降级后备、PTU 共享配置 |

## 2. `async_pre_call_hook()`

```
litellm/proxy/hooks/parallel_request_limiter_v3.py :: PROXY_MaxParallelRequestsHandler_v3 :: async_pre_call_hook() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 请求前扣减全部限流额度，超额即抛 429 |
| 参数 | `user_api_key_dict`、`cache`、`data`、`call_type` |
| 返回 | 通常 `None`（放行）或抛 `RateLimitUnverifiableError`（`parallel_request_limiter_v3.py :: RateLimitUnverifiableError :: +0`，HTTPException 子类） |
| 前置 | `UserAPIKeyAuth` 已带出 tpm/rpm 上限（第四层第 2 篇） |
| 后置 | 并发槽位被占用；释放责任在 success/failure 回调或断流计费 |

核心算法：

1. 构造 `RateLimitDescriptor` 序列：key/user/team/org/end-user 多维度，每维带各自的 tpm/rpm 上限
2. 预估本次 token 数：`_estimate_tokens_for_request() :: +0`（`+1256`）——prompt tokenizer 计数 + 输出上限（`_get_explicit_output_cap :: +0` 显式 `max_tokens`；无显式值时 `no_max_tokens_output_floor :: +0`（`+1087`）给保守下限）
3. TPM/RPM 计数原子扣减（Redis INCRBY + 比较；无 Redis 时内存降级）
4. 并发槽：`max_parallel_requests` 上限检查并占位；占位信息存进 request stash，供释放
5. PTU 共享池请求走 `_estimate_ptu_tokens_for_request() :: +0`（`+1304`）的池化额度

## 3. 释放路径（三个入口，一个出口）

```
parallel_request_limiter_v3.py :: PROXY_MaxParallelRequestsHandler_v3 :: _release_parallel_request_slots() :: +0
```

| 入口 | 触发 | 锚点 |
|---|---|---|
| 成功回调 | 响应返回后 | `async_log_success_event() :: +0`（`+5581`） |
| 失败回调 | 异常路径 | `async_log_failure_event() :: +0`（`+5752`） |
| 断流计费 | 客户端断开 | `common_request_processing.py :: _dispatch_disconnect_billing_event() :: +0` 内部调用 |

`_release_parallel_request_slots() :: +0`（`+2223`）统一处理：Redis 槽位 DECR、stash 清理；Redis 不可用时走 `_release_parallel_request_slots_in_memory() :: +0`（`+2301`）。`_release_stashed_parallel_slot() :: +0`（`+2202`）处理按 stash 精确释放单个槽。

## 4. 与鉴权层的分工

| 机制 | 位置 | 状态存储 |
|---|---|---|
| 预算检查（spend ≤ max） | 鉴权（第四层第 2 篇） | Postgres + 缓存 |
| TPM/RPM/并发扣减 | 本模块（pre-call） | Redis 计数器（内存降级） |
| TPM/RPM 值的来源 | `UserAPIKeyAuth` 字段 | 鉴权层带出 |

拆分原因（第三层第 2 篇已述）：限流需要「请求结束归还」的生命周期，必须挂在回调体系上，而鉴权是「校验即结束」。

## 5. 无 Redis 的行为

计数降级为进程内存（`single-flight` 语义仍正确，但多 worker 间不再共享）。`ProxyStartupEvent` 启动时有专门的警告函数（`proxy_server.py :: ProxyStartupEvent :: warn_fail_closed_rate_limits_without_redis() :: +0`，见第四层第 12 篇）——fail-closed 配置配无 Redis 是危险组合，启动即提示。

## 6. v3 与旧版

模块内同时保留 v1/v2 处理器（`hooks/__init__.py` 里 `PROXY_MaxParallelRequestsHandler`、`_PROXY_MaxParallelRequestsHandler` 导出做向后兼容），新配置默认走 v3（descriptor 模型 + PTU 支持）。读代码时按 `PROXY_MaxParallelRequestsHandler_v3` 找，别被同名旧类带偏。
