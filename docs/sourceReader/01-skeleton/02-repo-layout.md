# 仓库目录地图

> 所属层级：第一层（系统骨架） | 建议阅读顺序：2
> 本篇基准提交：`411b64dc7a`（工作区当前 HEAD）

## 这篇讲什么

把上一章提到的每个模块（`main.py`、`router.py`、`proxy_server.py`、Rust 核心……）落到具体目录上。读完你应该能拿到一个符号名就猜出它大概在哪个目录，也能知道「调 LLM 的逻辑」和「当网关的逻辑」分别住在哪里。

## 仓库根目录：已经收敛到很干净

当前基线上，仓库根只有 11 个条目（实测 `ls` 根目录）：

```text
litellm/                                  # Python 包本体：SDK + Router 门面 + proxy 网关，几乎一切都在包内
tests/                                    # 测试（unit/、e2e/、code_coverage_tests/ 等）
docs/                                     # 本套导读 docs/sourceReader/（另有 docs/agent/ 开发备注）
.github/                                  # CI、linters、PyPI 打包脚本
model_prices_and_context_window.json      # 全量模型价目表（成本计算的数据源）
policy_templates.json                     # guardrail 策略模板
provider_endpoints_support.json           # provider 端点支持矩阵
pyproject.toml                            # 构建配置与 console 入口（指向打包后的 litellm_cli.main）
uv.lock                                   # 依赖锁
Makefile                                  # make check / make lint 等开发命令
AGENTS.md / README.md / LICENSE / cosign.pub
```

过去散在根目录的东西（`ui/`、`enterprise/`、`litellm-rust/`、`scripts/`、`ci_cd/`、部署物等）已经全部收进 `litellm/` 包内，所以根目录才这么短。规模实测（基准 `411b64dc7a`）：`litellm/` 含 3432 个 Python 文件、约 112.7 万行；`litellm/rust/` 含 76 个 crate 目录、1052 个 `.rs` 文件、约 22.6 万行。

## 顶层目录职责

| 目录 / 文件 | 职责 | 通俗解释 |
|---|---|---|
| `litellm/` | Python 包本体，SDK 全部逻辑 | 你 `import litellm` 时加载的就是它 |
| `tests/` | 测试，入口约定见 `tests/AGENTS.md` | 改代码前后跑的那个 |
| `docs/` | 本套导读（`docs/sourceReader/`） | 你现在读的这套 |
| `.github/` | CI、linters（`linters/ruff-strict.toml` 等）、打包脚本 `packaging/` | 决定 PR 能不能合并、PyPI 包怎么打 |
| `model_prices_and_context_window.json` | 模型价目与上下文窗口表 | 成本计算的数据源，`cost_calculator.py` 读它 |
| `policy_templates.json`、`provider_endpoints_support.json` | guardrail 策略模板、provider 端点支持矩阵 | 数据文件，不是代码 |

## `litellm/` 包内的六大块

包内文件极多，按「数据流经过的先后」分组看最清楚。下面这张树只画主干：

```text
litellm/
├── __init__.py              # 1. 包初始化：from .main import * 转出公共 API
├── _lazy_imports.py         #    按需导入重型依赖，加快 import litellm
├── _version.py              #    读已安装发行版元数据得到版本号
│
├── main.py                  # 2. SDK 入口：completion / acompletion / embedding ...
├── router.py                #    Router 纯门面（多部署选路对外的那张脸）
├── router_core.py           #    make_core()：无条件造 Rust 核心
├── router_python_host.py    #    PythonHost：核心唯一的对外通道
├── router_rust/             #    Rust 核心的 Python 侧（core / invoke / steps / surface）
├── router_api.py            #    Router 的设置与观察面（Registry / Settings / Health）
├── router_strategy/         #    路由策略实现（least-busy、lowest-latency 等）
│
├── llms/                    # 3. 100+ provider 适配（166 个条目）
│   ├── custom_httpx/llm_http_handler.py   # 统一 HTTP 执行器 BaseLLMHTTPHandler
│   ├── base_llm/                          # 各模态基类
│   └── <provider>/<模态>/transformation.py # 请求/响应/错误三向翻译
│
├── litellm_core_utils/      # 4. 横切工具：日志管线、model 解析、异常映射、流式聚合
├── caching/                 #    LLM 响应缓存（内存 + Redis 两级）
├── cost_calculator.py       #    成本计算
├── exceptions.py            #    全部异常类型
├── types/                   #    Pydantic / TypedDict 类型
├── integrations/            #    CustomLogger 回调体系（Langfuse / Datadog / ...）
│
├── redis/                   # 5. Rust 后端 Redis store 家族（限流 / spend / 冷却 / 用量）
│
├── proxy/                   # 6. AI Gateway：FastAPI app + 全部端点
├── rust_bridge/             #    Python↔Rust 桥接（pyo3 绑定桩 _native.pyi）
├── rust/                    #    Rust Cargo workspace（76 crate，含 router-core）
│
├── runtime/                 # 进程入口：gateway/、backend/、migrations/
├── cli/                     # litellm / lite / litellm-proxy 三个命令实现
├── ui/                      # Dashboard 前端（litellm-dashboard，Node/React）
├── deploy/                  # compose/、docker/、helm/、render/、terraform/
├── enterprise/              # 商业版扩展（单独发布）
├── proxy-extras/            # Proxy 附带物小包（Prisma 迁移工具链）
├── scripts/                 # lint 门禁与 CI 辅助脚本
├── skills/                  # agent skill 定义
└── schema.prisma            # 数据库 schema 唯一来源
```

### 第 1 块，包初始化与延迟导入

`litellm/__init__.py` 暴露 `completion`、`acompletion` 等公共 API（经 `from .main import *` 转出）与全局配置变量。`_lazy_imports.py` 与 `_lazy_imports_registry.py` 负责按需导入重型依赖，让 `import litellm` 更快。`_logging.py` 提供 `verbose_logger` 等日志设施。`_process_defaults.py` 初始化进程级默认值（`__init__.py` 模块开头即调用 `apply_process_defaults()`）。另有 `_redis.py`、`_service_logger.py`、`_internal_context.py` 等：Redis 客户端参数内省、OTel 服务 span 日志、ContextVar 进程内信号。

### 第 2 块，调用入口层与 Router 门面

| 文件 / 目录 | 职责 | 关键锚点 |
|---|---|---|
| `main.py`（9784 行） | `completion()`、`acompletion()`、`embedding()`、`text_completion()` 等全部 SDK 入口 | `litellm/main.py :: completion() :: 5564` |
| `router.py`（506 行） | Router 纯门面：`__init__` 只做 `attach(make_core(...))`，成员读写转发 `_core`，禁子类化 | `litellm/router.py :: Router :: __init__() :: 418` |
| `router_core.py`（55 行） | `RouterCore` 协议 + `make_core()` 工厂，无条件返回 Rust 核心 | `litellm/router_core.py :: make_core() :: 51` |
| `router_rust/` | Rust 核心的 Python 侧：`core.py`（pyo3 句柄）、`invoke/`（端点执行计划）、`steps/`（留在宿主的有状态 step）、`surface/`（模型列表/健康等门面成员） | `litellm/router_rust/core.py :: RustCore :: 1464` |
| `router_python_host.py`（227 行） | 核心的外联宿主，provider 调用经 `.invoke` 回 litellm 执行 | `litellm/router_python_host.py :: PythonHost :: invoke() :: 107` |
| `router_api.py` | Router 的设置与观察面：`RouterRegistry`、`RouterSettings`、`RouterHealth`、`ChangeSet`、`ApplyResult` | `litellm/router_api.py` |
| `router_config.py`、`router_attempt.py`、`router_host.py`、`router_deprecated.py` | 配置构建、单次尝试、宿主绑定、弃用成员 | — |
| `router_strategy/` | 路由策略：`simple_shuffle.py`、`lowest_latency.py`、`lowest_cost.py`、`least_busy.py`、`lowest_tpm_rpm_v2.py`，以及 `adaptive_router/`、`auto_router/`、`complexity_router/`、`quality_router/`、`switchyard_router/` | — |

旧文档列出的 `router_python_core.py`（Python 版路由核心）已被删除，它的选部署、重试、冷却、fallback 职责全部移入 Rust 核心；`as_output_cap`、`stamped_client_ceiling` 等函数迁往 `litellm/router_rust/steps/prerouting.py`。

### 第 3 块，Provider 适配层

`llms/` 下有 166 个条目，每个 provider 一个目录，目录内再按模态分子目录（例如 `anthropic/chat/transformation.py`）。所有走 HTTP 的 provider 共用一个执行器 `llms/custom_httpx/llm_http_handler.py`（14458 行）里的 `BaseLLMHTTPHandler`，统一入口是 `litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: async_completion :: 820`。各模态基类在 `llms/base_llm/`。

### 第 4 块，核心工具层

`litellm_core_utils/` 是全局单例与横切工具的家：`litellm_logging.py`（日志管线，8575 行）、`get_llm_provider_logic.py`（model 字符串解析）、`exception_mapping_utils.py`（错误映射）、`streaming_handler.py`（流式聚合）、`token_counter.py`、`prompt_templates/`。`caching/` 是 LLM 响应缓存（`caching.py` 的 `Cache`、`dual_cache.py`、`caching_handler.py`）。`cost_calculator.py` 算钱（配合根级价目表 JSON）。`exceptions.py` 定义全部异常类型。`types/` 放 Pydantic / TypedDict 类型。`integrations/` 是 `CustomLogger` 回调体系（Langfuse、Datadog、Slack 告警、guardrail 基类等）。

### 第 5 块，`litellm/redis/`（Rust 后端 store 包）

| 文件 / 目录 | 职责 |
|---|---|
| `store_settings.py` | `RedisStoreSettings`：store 的连接与用途设置 |
| `stores/rate_limits/` | 限流计数 store，入口 `RateLimitStore` |
| `stores/spend_counters/`、`stores/auth_cache/` | spend 计数与 auth 缓存 store |
| `stores/router_cooldowns/`、`stores/router_usage/`、`stores/sensitive_route_pins/` | 路由冷却、用量、敏感路由钉扎 store |

v3 限流器、spend counters、路由冷却与用量、auth cache 都已接入这套 store，对应 Rust 实现在 `litellm/rust/crates/` 的 `redis-*` crate 族。

### 第 6 块，各模态 / 协议子包

`responses/`、`chat_completions/`、`messages/`、`embeddings/`、`text_completions/`、`images/`、`rerank_api/` 是各 API 形态的转换逻辑。`anthropic_interface/`、`a2a_protocol/`、`realtime_api/`、`passthrough/` 覆盖 Anthropic 协议、A2A、WebSocket 实时、直通。`assistants/`、`batches/`、`files/`、`fine_tuning/`、`vector_stores/`、`containers/` 是 OpenAI 对应资源的 SDK 封装。`mcp_client/`、`experimental_mcp_client/`、`skills/`、`harness/` 覆盖 MCP 客户端、Skills、agent harness。还有 `budget_manager.py`、`scheduler.py`、`timeout.py`、`guardrails.py` 等顶层封装，以及 `accounting/`、`repositories/`、`tracing/`、`telemetry/`、`models/` 等专项子包。

## `litellm/proxy/` 包内地图

| 子目录 / 文件 | 职责 | 关键锚点 |
|---|---|---|
| `proxy_server.py`（23033 行） | FastAPI app + 全部端点注册 + 全局状态（`llm_router`、`user_api_key_cache` 等） | `litellm/proxy/proxy_server.py :: app :: 2168`、`chat_completion() :: 13290` |
| `common_request_processing.py` | 所有 LLM 请求端点的共用处理骨架 | `litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: base_process_llm_request() :: 3180` |
| `route_llm_request.py` | 进入 Router 前的路由决策（model group 解析、通配模型、per-request 路由设置） | `litellm/proxy/route_llm_request.py :: route_request() :: 832` |
| `litellm_pre_call_utils.py` | `add_litellm_data_to_request` 把 key/team/用户信息注入请求 | — |
| `auth/` | 鉴权：`user_api_key_auth.py` 为主入口，另有 `auth_checks.py`、`handle_jwt.py`、`oauth2_check.py` | `litellm/proxy/auth/user_api_key_auth.py :: user_api_key_auth() :: 4761` |
| `hooks/` | Proxy 级回调：限流、成本记账 `proxy_track_cost_callback.py` 等 | `litellm/proxy/hooks/parallel_request_limiter_v3.py :: _PROXY_MaxParallelRequestsHandler_v3 :: +0` |
| `db/` | Prisma 客户端封装：`db_spend_update_writer.py`（花费批量写）、`db_url_settings.py` | — |
| `rust_forward/` | `LITELLM_RUST_FIRST` 部署形态：`mode.py`（开关）、`peer.py`、`server.py`、`supervisor/` | `litellm/proxy/rust_forward/mode.py :: SWITCH_ENV :: +0` |
| `server_listener.py` | gunicorn 私有监听（`PrivateListener`） | `litellm/proxy/server_listener.py :: PrivateListener :: +0` |
| `management_endpoints/`、`spend_tracking/`、`public_endpoints/` | 管理 API（key/team/budget CRUD、花费报表） | — |
| `anthropic_endpoints/`、`response_api_endpoints/`、`vertex_ai_endpoints/`、`google_endpoints/`、`pass_through_endpoints/` | 多协议端点 | — |
| `image_endpoints/`、`batches_endpoints/`、`openai_files_endpoints/`、`rerank_endpoints/`、`vector_store_endpoints/`、`ocr_endpoints/`、`video_endpoints/`、`realtime_endpoints/`、`agent_endpoints/` | OpenAI 资源与新增模态端点 | — |
| `mcp_server/`、`memory/`、`prompts/`、`workflows/`、`lens/` | MCP 服务、memory、prompt 管理、工作流等扩展端点 | — |
| `proxy_cli.py` | `litellm` CLI 服务启动（uvicorn / gunicorn 编排、配置加载） | `litellm/proxy/proxy_cli.py :: run_server() :: +0` |
| `proxy_config.yaml`、`dev_config.yaml` | 默认与开发用配置样例 | — |
| `middleware/`、`guardrails/`、`policy_engine/` | 中间件、guardrail、策略引擎 | — |
| `schema.prisma` | 包内数据库 schema（与 `litellm/schema.prisma` 同步） | — |

## 服务入口与部署物

| 目录 | 职责 |
|---|---|
| `litellm/runtime/gateway/` | 数据面入口：复用 proxy app 只保留 LLM 转发路由；`launch.py` 在 worker 起来前组装 `DATABASE_URL` 并先拉起容器内 PgBouncer |
| `litellm/runtime/backend/` | 管理面入口：复用 proxy app，只保留管理后台路由 |
| `litellm/runtime/migrations/` | 数据库迁移脚本 |
| `litellm/cli/` | `litellm`、`lite`、`litellm-proxy` 三个命令的实现。注意仓库里**没有** `litellm_cli/` 目录：发布时 `.github/packaging/cli_package.py` 把 `litellm/cli` 打包成独立发行包 `litellm_cli`，`pyproject.toml` 的 entry points 写 `litellm_cli.main:*` 指的就是那个发行包的导入路径 |
| `litellm/ui/` | Dashboard 前端（`litellm/ui/litellm-dashboard/`，Node/React 项目） |
| `litellm/deploy/` | 容器与部署物：`compose/`、`docker/`、`helm/`、`render/`、`terraform/` |
| `litellm/enterprise/` | 商业版扩展（单独发布） |
| `litellm/proxy-extras/` | Proxy 附带物独立小包（Prisma 迁移工具链） |
| `litellm/scripts/` | lint 门禁脚本与 CI 辅助 |
| `.github/packaging/` | PyPI 打包脚本：`cli_package.py`、`build_backend.py` |

## 找代码的经验法则

| 想找什么 | 去哪里 |
|---|---|
| 某端点的 HTTP 处理函数 | `litellm/proxy/proxy_server.py` 搜路径字符串 |
| 路由决策（选部署 / 重试 / 冷却） | `litellm/rust/crates/router-core`（决策本体）与 `litellm/router_rust/`（Python 侧句柄与 step） |
| Router 认识哪些端点名 | `litellm/router_rust/invoke/endpoints.py` |
| 某模型参数如何翻译 | `litellm/llms/<provider>/<模态>/transformation.py` |
| model 字符串怎么变成 provider | `litellm/litellm_core_utils/get_llm_provider_logic.py` |
| 某错误如何映射 | `litellm/litellm_core_utils/exception_mapping_utils.py` |
| 某回调 / 可观测平台 | `litellm/integrations/<平台名>.py` |
| 限流 / spend 的 Redis 读写 | `litellm/redis/stores/` |
| 某类型的定义 | `litellm/types/` 下按模块名找 |

## 源码索引

- `pyproject.toml` :: 构建配置与 entry points
- `.github/packaging/cli_package.py :: PACKAGE_NAME`、`PACKAGE_DIR`
- `litellm/__init__.py`、`litellm/_lazy_imports.py`、`litellm/_process_defaults.py`
- `litellm/main.py :: completion() :: 5564`
- `litellm/router.py :: Router :: __init__() :: 418`
- `litellm/router_core.py :: make_core() :: 51`
- `litellm/router_rust/core.py :: RustCore :: 1464`
- `litellm/router_python_host.py :: PythonHost :: invoke() :: 107`
- `litellm/router_rust/steps/prerouting.py :: as_output_cap`、`stamped_client_ceiling`
- `litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: async_completion :: 820`
- `litellm/litellm_core_utils/get_llm_provider_logic.py :: get_llm_provider() :: 187`
- `litellm/litellm_core_utils/litellm_logging.py`
- `litellm/caching/caching.py :: Cache`、`litellm/caching/dual_cache.py`
- `litellm/cost_calculator.py`
- `litellm/redis/store_settings.py :: RedisStoreSettings`、`litellm/redis/stores/rate_limits/__init__.py :: RateLimitStore`
- `litellm/proxy/proxy_server.py :: app :: 2168`、`chat_completion() :: 13290`
- `litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: base_process_llm_request() :: 3180`
- `litellm/proxy/route_llm_request.py :: route_request() :: 832`
- `litellm/proxy/auth/user_api_key_auth.py :: user_api_key_auth() :: 4761`
- `litellm/proxy/hooks/parallel_request_limiter_v3.py :: _PROXY_MaxParallelRequestsHandler_v3 :: +0`
- `litellm/proxy/proxy_cli.py :: run_server() :: +0`
- `litellm/proxy/rust_forward/mode.py :: SWITCH_ENV :: +0`
- `litellm/proxy/server_listener.py :: PrivateListener :: +0`
- `litellm/runtime/gateway/`、`litellm/runtime/backend/`、`litellm/runtime/migrations/`、`litellm/runtime/gateway/launch.py`
- `litellm/schema.prisma`、`litellm/ui/litellm-dashboard/`、`litellm/deploy/`、`litellm/enterprise/`、`litellm/proxy-extras/`
