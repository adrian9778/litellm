# 函数级解析：持久化与缓存

> 所属层级：第四层（源码补齐） | 覆盖：`proxy/db/db_spend_update_writer.py`、`caching/` 三层、`proxy/spend_tracking/spend_log_api_key_scope.py`、`litellm/redis/` store 家族

## 1. `DBSpendUpdateWriter`

```
litellm/proxy/db/db_spend_update_writer.py :: DBSpendUpdateWriter :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | spend 写入的唯一出口：明细行 + 累计列，聚合批量化 |
| 构造 | 依赖注入 Redis 句柄与会计时钟（`+3`）；初始化 `RedisUpdateBuffer`、`PodLockManager`、`spend_update_queue`、每日/时间窗各维度的队列与 `Cadence` 节奏控制 |

### `update_database()`

```
litellm/proxy/db/db_spend_update_writer.py :: DBSpendUpdateWriter :: update_database() :: +31
```

| 项 | 内容 |
|---|---|
| 职责 | 记录一次请求的 spend，返回「成本是否仍需入账」 |
| 参数 | `token`、`user_id`、`end_user_id`、`team_id`、`org_id`、`kwargs`、`completion_response`、`start_time`、`end_time`、`response_cost`、`project_id` |
| 返回 | `bool`：`False` 仅当 batch/video 轮询的成本行已被另一次轮询写入（docstring 自述，防重复计费） |
| 前置 | `response_cost` 已算出（上游 `_ProxyDBLogger`） |
| 后置 | payload 已入队，等待 flush；不直接等 DB 完成 |

核心算法（`update_database :: +0` 至 `+80`）：

1. `+33`：`use_spend_logs_ledger`（默认真）决定是否写时间窗账本键；`_SPEND_METADATA_ADAPTER` 归一 kwargs。
2. `+45`：`ProxyUpdateSpend.disable_spend_updates()` 为真（无 DB）→ 直接返回。
3. `+48`：`sk-` key 哈希化（`hash_token`），杜绝明文 key 进 DB/日志。
4. `+58`：`get_logging_payload` 组装 `SpendLogsPayload`；`_billable_cost(response_cost, payload)` 折算计费成本。
5. `+67`（#51110 守卫）：`disable_responses_id_security is True` 且 `call_type ∈ {aget_responses, acancel_responses}` 且 `status == "success"` 且 `billable_cost` 为假 → 不写创建行直接返回 `True`（free responses 读写不落账）。
6. `+73` 起：`payload["spend"] = billable_cost or 0.0`；补 `organization_id`/`team_id`；按维度构造 spend 增量；`use_ledger` 时写 `accounting_window_keys(hashed_token, team_id)`，`settle-once` 行（`_is_settle_once_cost_row`）只结一次。
7. 明细行 payload 组装：request id、model、tokens、cost、metadata（`_parse_spend_log_metadata` 解析既有 metadata；`_is_billed_retry_attempt` 判定重试是否已计费）。
8. 入队等待后台 flush 聚合提交。

### 幂等与防御

| 机制 | 锚点 | 防什么 |
|---|---|---|
| `_is_settle_once_cost_row` | `db_spend_update_writer.py :: _is_settle_once_cost_row() :: +0` | 轮询型成本重复入账（batch 记 cost 后缀、video 记 cost 后缀的轮询才结算） |
| `_is_billed_retry_attempt` | `db_spend_update_writer.py :: _is_billed_retry_attempt() :: +0` | Router 重试导致的重复计费 |
| `hash_token` | `update_database :: +48` | 明文 key 泄露 |
| `_cost_row_to_write` | `db_spend_update_writer.py :: _cost_row_to_write() :: +0` | `disable_spend_logs` 时跳过明细行，仅保留累计 |
| `_parse_spend_log_metadata` | `db_spend_update_writer.py :: _parse_spend_log_metadata() :: +0` | 既有 metadata 的解析与并入 |
| `_billable_cost` | `db_spend_update_writer.py :: _billable_cost() :: +0` | 计费成本与已记账成本的折算（#51110 守卫依赖它判 free） |

## 2. `_narrowing_keys`（owner 限定读的新基线文件）

```
litellm/proxy/spend_tracking/spend_log_api_key_scope.py :: _narrowing_keys() :: +0
```

> 该文件为上一基线后新增（#51127）。

把 owner 维度（user/team）日志窗口里能带该 owner 的 `api_key` 清单收窄成可下推的 WHERE 范围。`_API_KEY_ROWS`（TypeAdapter）校验每行 `api_key`；去重为键元组后，若为空或超过 `SPEND_LOG_API_KEY_SCOPE_MAX_KEYS` 则返回 `None`（无法收窄），否则**把空串 `""` 追加进返回元组**（`+10`：`return keys if "" in keys else (*keys, "")`），保证读查询把「无 key 归属」的日志行也覆盖进来。入口 `spend_log_api_keys_for_user`（`+59`）与 `spend_log_api_keys_for_teams`（`+71`）分别喂 user / team 两套 SQL 窗口。

## 3. `Cache`（SDK 层 LLM 响应缓存）

```
litellm/caching/caching.py :: Cache :: +0
litellm/caching/caching.py :: Cache :: get_cache() :: +571
litellm/caching/caching.py :: Cache :: get_cache_key() :: +282
litellm/caching/caching.py :: Cache :: add_cache() :: +667
```

| 项 | 内容 |
|---|---|
| 职责 | 单一后端（内存/Redis/S3/GCS/Azure 等）的 KV 缓存，`type` 选后端 |
| 关键方法 | `get_cache`（`+571`）、`get_cache_key`（`+282`）、`add_cache`（`+667`）；同步/异步双版都走 `get_cache_logic`（`+509`）做 TTL 与归一 |
| 键策略 | `get_cache_key`：provider、model、messages、参数归一哈希，可加 namespace 前缀（`_add_namespace_to_cache_key`），支持语义缓存与 preset key |

`get_cache`（`+571`）流程：`should_use_cache` 守卫 → `response_cache_phase("get")` → 取 `cache_key`（`kwargs["cache_key"]` 或 `get_cache_key`）→ 按 `cache` 参数里的 `s-max-age`/`s-maxage` 解 max_age → 透传给 `dynamic_cache_object` 或 `self.cache` 的后端 `get_cache` → `_update_metadata_from_cache_lookup_kwargs` 回写元数据 → `get_cache_logic` 判定是否过期。全程 try/except，任何异常都返回 `None`（绝不阻塞调用）。

## 4. `DualCache`

```
litellm/caching/dual_cache.py :: DualCache :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 内存 + Redis 两级读写 |
| 关键方法与偏移 | `set_cache :: +72`（local_only 参数控制只写内存）、`batch_get_cache :: +140`、`async_get_cache :: +183`、`async_set_cache :: +411`、`async_set_cache_pipeline :: +449` |
| 核心算法 | 读：先内存，未命中穿 Redis，回填内存；写：默认双层，`local_only=True` 只写本进程（用于本进程私有状态） |

`set_cache`（`+72`）：先写 `in_memory_cache`（`ttl` 缺省时取 `default_in_memory_ttl`），`redis_cache` 存在且 `local_only is False` 时再写 Redis。多 worker 部署下，限流计数、冷却表、key 缓存都靠 Redis 层保持一致（AGENTS.md 的 QA 规范要求两 worker 共享同一 Redis 正是这个原因）。

## 5. `LLMCachingHandler`

```
litellm/caching/caching_handler.py :: LLMCachingHandler :: +0
litellm/caching/caching_handler.py :: LLMCachingHandler :: reads_cache() :: +122
litellm/caching/caching_handler.py :: LLMCachingHandler :: sync_get_cache() :: +194
litellm/caching/caching_handler.py :: LLMCachingHandler :: sync_set_cache() :: +960
litellm/caching/caching_handler.py :: LLMCachingHandler :: _convert_cached_stream_response() :: +860
```

| 项 | 职责 |
|---|---|
| 职责 | LLM 调用与缓存的编排：调用前查缓存、调用后写缓存、流式缓存的分片累积 |
| 核心算法 | `reads_cache`（`+122`）判该 call type 是否读缓存；`sync_get_cache`（`+194`）查缓存，命中转 `_convert_cached_result_to_model_response` / `_convert_cached_stream_response`（流式命中转重放流，`+860`）；未命中放行调用，响应回来后 `sync_set_cache`（`+960`）按 `should_store_result_in_cache` 决定写库并算 TTL；`control-cache` 语义按请求的 `cache` 参数开关 |

## 6. `UserApiKeyCache`（Proxy 的 key/限流缓存）

```
litellm/proxy/common_utils/user_api_key_cache.py :: UserApiKeyCache :: +0
litellm/proxy/common_utils/user_api_key_cache.py :: UserApiKeyCache :: get_cache() :: +140
litellm/proxy/common_utils/user_api_key_cache.py :: UserApiKeyCache :: set_cache() :: +243
```

| 项 | 内容 |
|---|---|
| 职责 | `DualCache` 的 Proxy 特化子类：缓存 `LiteLLM_VerificationToken`、team membership、end-user 行 |
| 核心算法 | 鉴权链（第四层第 2 篇）的读路径都走它；DB 回读后回填；TTL 与 DB 变更事件（管理 API 改 key）触发失效。`get_cache`（`+140`）优先走 Rust 侧 `AuthCacheStore`（`shared()`），无 Redis 时退回 `_python_memory` |
| 并发语义 | 多 worker 下 Redis 层共享，保证改 key 立即对全部 worker 生效（在 TTL 窗口内） |

## 7. `litellm/redis/` store 家族（Rust 后端持久层）

Rust 路由与限流/用量/认证的跨进程状态统一落在 `litellm/redis/` 新顶级包（#50169/#50170）：

| 配置/Store | 锚点 | 接入点 |
|---|---|---|
| `RedisStoreSettings` | `litellm/redis/store_settings.py :: RedisStoreSettings :: +0` | 从 `RedisCache` 建连时捕获一次的连接配置（redis_kwargs、namespace、default_ttl、breaker） |
| `RateLimitStore` | `litellm/redis/stores/rate_limits :: RateLimitStore :: +0` | v3 限流器的限流/冷却计数 |
| `SpendCounterStore` | `litellm/redis/stores/spend_counters :: SpendCounterStore :: +0` | 用量 spend counter（key/team/user/end-user/org/tag 等维度，`key_counter`/`team_window_counter` 等） |
| `AuthCacheStore` | `litellm/redis/stores/auth_cache :: AuthCacheStore :: +0` | `UserApiKeyCache` 的 key 认证缓存 |
| `RouterUsageStore` / `RouterCooldownsStore` | `litellm/redis/stores/router_usage`、`litellm/redis/stores/router_cooldowns` | 路由用量与冷却表 |

限流（v3）、冷却与用量、auth cache 已通过上述 store 接入；无 Redis 时各 store 退回 Python 内存（单 worker 正确，多 worker 退化）。

## 8. 缓存的三种用途对照

| 用途 | 类 | 内容 | 生命周期 |
|---|---|---|---|
| LLM 响应缓存 | `Cache`/`DualCache`（`caching.py`/`dual_cache.py`） | 完整响应/流分片 | 请求参数哈希键，TTL |
| 网关状态缓存 | `UserApiKeyCache`、Router 冷却表 | key/team/冷却/计数 | 短 TTL + 事件失效 |
| spend 聚合缓冲 | `DBSpendUpdateWriter` 内部队列 | spend 增量 | flush 周期 |

三者都可在无 Redis 时降级为纯内存（单 worker 正确，多 worker 退化），有 Redis 时跨 worker 一致。

## 9. 数据落库的完整路径（成功请求）

```
completion_cost 算出 response_cost
→ _ProxyDBLogger.async_log_success_event（可离载则投递事件，否则直进）
→ _PROXY_track_cost_callback（预算预留结算）
→ DBSpendUpdateWriter.update_database（#51110：free aget/acancel responses 直接短路）
→ 入队 → flush 聚合
→ Prisma 批量写：LiteLLM_SpendLogs（明细）+ LiteLLM_VerificationToken/UserTable/TeamTable（spend 累计列）
```

失败请求对称走 `async_log_failure_event`：预留释放、部分 usage 记账或记 0。

---

至此四层文档全部完成。附录式的核对清单见本目录下 `VERIFY.md`。