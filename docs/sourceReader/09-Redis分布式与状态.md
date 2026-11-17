---
title: Redis分布式与状态
layer: 4
---

# Redis 分布式与状态

> **代码基准**：`main@e46fe2e2dc1bdd19f7953bd47dc3d770876ac74e（工作区干净）`；核实日期：2026-11-17。
> **范围**：Redis 在 LiteLLM 中的使用：连接、Store、rate limits、spend counters、auth cache、router state。
> **前置**：U03 确认 `DualCache`/`router_cooldowns`；U04 确认 `spend_counter`。

## 0. 结论速览

Redis 是 LiteLLM Proxy 里 **7 个核心状态域**：
1. `rate_limits`（每 key/team/被告的限额，滑动窗口）
2. `spend_counters`/`committed_spend`（花费计数，window 分割）
3. `auth_cache`（key 查表补过缓存，TTL 5min）
4. `router_cooldowns`（失败后 cooldown 状态）
5. `router_session_pins`（session pin：将请求打在同一个 deployment）
6. `deployment_health`（部署健康检查频率/结果）
7. `route/` sliced connection（`_route.py` 的 `Batch` / `NativeSend`）

连接参数全部通过 `GeneralSettings.redis_*` 字段（`redis_password`, `redis_host`, `redis_port`, `redis_url`, `redis_ca`, `redis_use_cluster`）；`litellm/redis/stores/connection.py` 维护了一个池。

## 1. 连接与池

`litellm/redis/` 下的所有 store 通过 `Redis` 基类取连接（`litellm/redis/redis_wrapper.py` — `_redis_wrapper`）：
- `Redis` 的 `pool` 和 `connection`。
- `cluster` 使用 RedisCluster。
- `get_redis_client` 的 error 特殊处理。
- `environment` 可以有 `redis_password` 池。
- `chat_completion` 缓存请求在 `cache/` 下。

## 2. Store 树

```
litellm/redis/stores/
├── __init__.py (Empty)
├── _route.py (Batch/NativeSend/Reply/Await)
├── auth_cache/ (key/user/team cache)
├── connection.py (连接池)
├── deployment_health/ (health 조회)
├── rate_limits/ (rate limit)
├── router_cooldowns/ (cooldown)
├── router_session_pins/ (session pin)
├── router_usage/ (router usage)
├── spend_counters/ (counters/committed)
└── window_time.py (window)
```

### 2.1 `rate_limits`（滑动窗口）

`rate_limits/__init__.py 67` `RateLimitStore`：
- `check_and_increment` — 核心幂等操作；查询 hib `counters`。
- `sliding_window(...)` — 滑动窗口。
- `rate_limits` 的 entry 结构：`{key, unit, window}`。

### 2.2 `spend_counters`

`spend_counters/__init__.py`：
- `SpendCounterStore.get(key)` / `set` — 每个 entity 窗口被分割成 `{key}, {window}` 两种 counter。
- `committed_counter` — 独立的 `committed_spend` twin（Prometheus 用）。
- `window_counter` — 窗口粒度。
- `end_user_counter`, `team_counter`, `user_counter`, `org_counter` — 实体。

### 2.3 `auth_cache`

`auth_cache/__init__.py`：
- `auth_cache` 存储每个 key 的 `entity_id`。
- `user_cache` 存储 `user_model`。

### 2.4 `router_cooldowns`

`router_cooldowns` 给定 deployment 的 cooldown。

## 3. 使用侧

- `rate_limits`：`proxy/auth/auth_checks.py` 里 `check_valid_key -> rate limits`。
- `spend`：`spend_tracking` 批量写。
- `health`：`deployment_health` 在 proxy startup 时查询。
- `session pin`：`router_session_pins` 让一个 session 绑到 backend。

## 4. 集群和哨兵

`connection.py` 的 `RedisCluster` 支持 `--redis_cluster=True`。
