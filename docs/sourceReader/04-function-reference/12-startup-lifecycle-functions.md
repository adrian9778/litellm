# 函数级解析：启动与生命周期

> 所属层级：第四层（源码补齐） | 覆盖：`proxy/proxy_cli.py :: run_server`、`proxy/proxy_server.py :: proxy_startup_event`、`ProxyStartupEvent`

主链路之外的另一半真相：进程怎么起来、后台任务有哪些、怎么退场。第一层第 4 篇的宏观生命周期以「请求已可服务」为前提，本篇补齐前提本身。

## 1. `run_server()`

```
litellm/proxy/proxy_cli.py :: run_server() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | `litellm --config ...` CLI 的服务启动编排 |
| 参数 | `cli_args`、`host`、`port`、`api_base`、`api_version`、`model`、config 路径与运行模式旗标 |
| 返回 | 不返回（阻塞运行直到进程退出） |

核心算法（相对偏移）：

1. `+109`：`save_worker_config(...)`——把 CLI/YAML 解析出的配置序列化给子进程/worker（`+1337` 处调用）
2. `+427` 附近：uvicorn 目标写死字符串 `"litellm.proxy.proxy_server:app"`（`+655` 一带），worker 进程按字符串导入 app，保证 reload/多 worker 场景下配置重建
3. `+601`：`uvicorn.run(...)`（`+1829`）——`--run_gunicorn/--run_hypercorn/--run_granian` 走各自分支（AGENTS.md 的 QA 规范提醒：`--reload` 与这三者互斥）

多 worker 与 Redis 的组合语义见根 AGENTS.md 的 QA 规范：两 worker 共享 router 状态必须指向同一 Redis。

## 2. `proxy_startup_event()`

```
litellm/proxy/proxy_server.py :: proxy_startup_event() :: +0
litellm/proxy/proxy_server.py :: _proxy_lifespan() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | FastAPI lifespan。本体是薄壳：`GracefulShutdownManager.capture_sigterm()`（`+1`）+ `AsyncExitStack` 包住真正序列 `_proxy_lifespan`（`+7`） |
| 形态 | `AsyncGenerator[ProxyLifespanState, None]` |
| 前置 | 模块级全局（`llm_router`、`user_api_key_cache`、`proxy_logging_obj`）已创建 |
| 后置 | DB 连接、master key、Router、后台任务全部就绪 |

`_proxy_lifespan` 启动段的真实顺序（偏移相对其 `+0`）：

| 序 | 步骤 | 偏移 |
|---|---|---|
| 1 | `_own_database` + `init_verbose_loggers`，注册 `_forget_prisma_client` 退场回调 | `+20` |
| 2 | worker 启动钩子（`LITELLM_WORKER_STARTUP_HOOKS`，逐个动态导入执行） | `+43` 至 `+75` |
| 3 | premium license 检查 | `+60` 附近（标记行 `+58`） |
| 4 | master key 从 env 读取 | `+64` |
| 5 | 配置加载：`CONFIG_FILE_PATH` / `WORKER_CONFIG` → `proxy_config.load_config` → 赋值全局 `llm_router`/`llm_model_list`/`general_settings` | `+76` 至 `+96` |
| 6 | master key 启动裁决（缺失且配置要求强制时拒绝启动；警告文案的出处） | `+103` |
| 7 | `ProxyStartupEvent.setup_prisma_client` + `migrate_if_requested`（Prisma 迁移在服务流量前同步应用，对应根 AGENTS.md 的迁移规范） | `+125` / `+134` |
| 8 | `ProxyStartupEvent` 系列初始化与警告（见第 3 节） | `+242` 至 `+300` |

关停段（yield 之后）：scheduler 停机、`AsyncExitStack` 逆序执行回调（含 Prisma 连接释放）。

## 3. `ProxyStartupEvent`

```
litellm/proxy/proxy_server.py :: ProxyStartupEvent :: +0
```

静态方法集合（偏移相对类定义行）。多数被 `_proxy_lifespan` 在 `+242` 至 `+300` 区间按序调用：

| 方法 | 偏移 | 职责 |
|---|---|---|
| `attach_router_to_prompt_injection_detectors()` | `+2` | Router 挂到 prompt 注入检测器 |
| `warn_fail_closed_rate_limits_without_redis()` | `+30` | fail-closed 限流 + 无 Redis 的危险组合警告（第四层第 11 篇第 5 节） |
| `initialize_startup_logging()` | `+46` | 启动日志横幅 |
| `warn_if_mock_testing_params_enabled()` | `+61` | mock 参数门禁未关时的生产警告 |
| `validate_redis_transaction_buffer_config()` | `+94` | Redis 事务缓冲配置校验 |
| `init_coordination_redis_from_db()` | `+126` | 从 DB 恢复协调 Redis 配置 |
| `initialize_semantic_tool_filter()` | `+195` | 语义工具过滤初始化 |
| `initialize_jwt_auth()` | `+230` | JWT 公钥/映射装载 |
| `add_proxy_budget_to_db()` | `+266` | 内置 proxy 预算 upsert |
| `warm_global_spend_cache()` | `+329` | 预热全局花费缓存（`GLOBAL_PROXY_SPEND_CACHE_KEY`） |
| `update_default_team_member_budget()` | `+348` | 默认团队预算对齐 |
| `sync_ui_settings_to_general_settings()` | `+368` | UI 存的设置并回 general_settings |
| `initialize_scheduled_background_jobs()` | `+452` | 见下节 |

## 4. 后台任务（APScheduler）

```
litellm/proxy/proxy_server.py :: ProxyStartupEvent :: initialize_scheduled_background_jobs() :: +0
```

| 项 | 内容 |
|---|---|
| 职责 | 创建 `AsyncIOScheduler` 并注册全部周期任务 |
| 核心算法 | scheduler 配 `AwaitableAsyncIOExecutor`（`+21`），关停时可 await 在跑任务；budget 重调度间隔取 `min_time + random(max-min)` 的抖动（`+42`），避免多 worker 同时打 DB；批量写间隔强制 ≥30 秒（`+50` 的注释写明防内存积压） |

注册的任务族：

| 方法 | 偏移 | 任务 |
|---|---|---|
| `_initialize_spend_tracking_background_jobs()` | `+924` | spend 批量落库、预算重置、每日聚合 |
| `_initialize_expired_ui_session_key_cleanup_background_job()` | `+1052` | 过期 UI 会话 key 清理 |
| `_initialize_slack_alerting_jobs()` | `+1169` | Slack 告警（超预算/挂起请求） |

这些任务就是第三层第 8 篇「记账异步化」的另一半：`DBSpendUpdateWriter` 的 flush、预算告警、账本窗口都靠这里注册的 job 驱动。

## 5. 退场

`proxy/shutdown/` 子包承载关停逻辑；`proxy_startup_event` 的 yield 之后执行。语义要点：关停时先停 scheduler 再等 executor 内任务收尾，保证 spend 批量写不因重启丢批。

## 6. 三个入口的汇合

第一层第 1 篇的三种启动方式最终都汇到 `proxy_startup_event`：传统 CLI 经 `run_server`，`gateway/main.py` 与 `backend/main.py` 直接 uvicorn 该 app（它们的模块级 `DatabaseURLSettings.from_env().apply_to_env()` 在导入 proxy_server 前拼好 DATABASE_URL，见各自文件头注释）。
