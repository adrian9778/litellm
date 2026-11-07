# 函数级解析：持久化与缓存

> 所属层级：第四层（源码补齐） | 覆盖：`proxy/db/db_spend_update_writer.py`、`caching/` 三层、`proxy/utils.py` 的缓存门面

## 1. `DBSpendUpdateWriter`

```
litellm/proxy/db/db_spend_update_writer.py :: DBSpendUpdateWriter :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | spend 写入的唯一出口：明细行 + 累计列，聚合批量化 |
| 构造 | 依赖注入 Prisma 客户端句柄与 flush 配置（进程启动时建一个实例，挂在 proxy 全局） |

### `update_database()`

```
litellm/proxy/db/db_spend_update_writer.py :: DBSpendUpdateWriter :: update_database() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 记录一次请求的 spend，返回「成本是否仍需入账」 |
| 参数 | `token`、`user_id`、`end_user_id`、`team_id`、`org_id`、`kwargs`、`completion_response`、`start_time`、`end_time`、`response_cost`、`project_id` |
| 返回 | `bool`：`False` 仅当 batch/video 轮询的成本行已被另一次轮询写入（docstring 自述，防重复计费） |
| 前置 | `response_cost` 已算出（上游 `_ProxyDBLogger`） |
| 后置 | payload 已入队，等待 flush；不直接等 DB 完成 |

核心算法（`+0` 至 `+110`）：

1. `+45`：`ProxyUpdateSpend.disable_spend_updates()` 为真（无 DB）→ 直接返回
2. `+48`：`sk-` key 哈希化（`hash_token`），杜绝明文 key 进 DB/日志
3. `+69` 至 `+94`：按五个维度（key/user/team/org/end-user）构造 spend 增量；`use_ledger` 时写时间窗账本键（`accounting_window_keys(hashed_token, team_id)`），`settle-once` 行（`_is_settle_once_cost_row`）只结一次
4. 明细行 payload 组装（`SpendLogsPayload`）：request id、model、tokens、cost、metadata（`_parse_spend_log_metadata` 解析既有 metadata；`_is_billed_retry_attempt` 判定重试是否已计费）
5. 入队等待后台 flush 聚合提交

### 幂等与防御

| 机制 | 位置 | 防什么 |
|---|---|---|
| `_is_settle_once_cost_row` | 193 行处 | 轮询型成本重复入账 |
| `_is_billed_retry_attempt` | 417 行处 | Router 重试导致的重复计费 |
| `hash_token` | `+48` | 明文 key 泄露 |
| `_cost_row_to_write` | 214 行处 | `disable_spend_logs` 时跳过明细行，仅保留累计 |

## 2. `Cache`（SDK 层 LLM 响应缓存）

```
litellm/caching/caching.py :: Cache :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 单一后端（内存/Redis/S3 等）的 KV 缓存 |
| 关键方法 | `set_cache`、`get_cache`、`async_set_cache`、`batch_get_cache`、`async_set_cache_pipeline` |
| 键策略 | 请求参数归一化哈希（provider、model、messages、参数），可加 namespace 前缀 |

## 3. `DualCache`

```
litellm/caching/dual_cache.py :: DualCache :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 内存 + Redis 两级读写 |
| 关键方法与偏移 | `set_cache :: +140`（local_only 参数控制只写内存）、`batch_get_cache :: +208`、`async_get_cache :: +251`、`async_set_cache_pipeline :: +517`、`async_set_cache :: +1140` |
| 核心算法 | 读：先内存，未命中穿 Redis，回填内存；写：默认双层，`local_only=True` 只写本进程（用于本进程私有状态） |

多 worker 部署下，限流计数、冷却表、key 缓存都靠 Redis 层保持一致（AGENTS.md 的 QA 规范要求两 worker 共享同一 Redis 正是这个原因）。

## 4. `LLMCachingHandler`

```
litellm/caching/caching_handler.py :: LLMCachingHandler :: +0
```

| 项 | 职责 |
|---|---|
| 职责 | LLM 调用与缓存的编排：调用前查缓存、调用后写缓存、流式缓存的分片累积 |
| 核心算法 | 查缓存 → 命中则回放（含流式缓存命中转为重放流）；未命中 → 放行调用，响应回来后按 TTL 写入；`control-cache` 语义按请求的 `cache` 参数开关 |

## 5. `UserApiKeyCache`（Proxy 的 key/限流缓存）

```
litellm/proxy/common_utils/user_api_key_cache.py :: UserApiKeyCache :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | `DualCache` 的 Proxy 特化子类：缓存 `LiteLLM_VerificationToken`、team membership、end-user 行 |
| 核心算法 | 鉴权链（第四层第 2 篇）的读路径都走它；DB 回读后回填；TTL 与 DB 变更事件（管理 API 改 key）触发失效 |
| 并发语义 | 多 worker 下 Redis 层共享，保证改 key 立即对全部 worker 生效（在 TTL 窗口内） |

## 6. 缓存的三种用途对照

| 用途 | 类 | 内容 | 生命周期 |
|---|---|---|---|
| LLM 响应缓存 | `Cache`/`DualCache`（`caching.py`/`dual_cache.py`） | 完整响应/流分片 | 请求参数哈希键，TTL |
| 网关状态缓存 | `UserApiKeyCache`、Router 冷却表 | key/team/冷却/计数 | 短 TTL + 事件失效 |
| spend 聚合缓冲 | `DBSpendUpdateWriter` 内部队列 | spend 增量 | flush 周期 |

三者都可在无 Redis 时降级为纯内存（单 worker 正确，多 worker 退化），有 Redis 时跨 worker 一致。

## 7. 数据落库的完整路径（成功请求）

```
completion_cost 算出 response_cost
→ _ProxyDBLogger.async_log_success_event（可离载则投递事件，否则直进）
→ _PROXY_track_cost_callback（预算预留结算）
→ DBSpendUpdateWriter.update_database
→ 入队 → flush 聚合
→ Prisma 批量写：LiteLLM_SpendLogs（明细）+ LiteLLM_VerificationToken/UserTable/TeamTable（spend 累计列）
```

失败请求对称走 `async_log_failure_event`：预留释放、部分 usage 记账或记 0。

---

至此四层文档全部完成。附录式的核对清单见本目录下 `VERIFY.md`。
