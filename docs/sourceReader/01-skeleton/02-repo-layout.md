# 仓库目录地图

> 所属层级：第一层（系统骨架） | 建议阅读顺序：2

## 顶层目录

仓库根目录按「核心包 / 服务入口 / 基础设施 / 工程配套」分成四组。规模实测（2026-11-12，基准 `0608a41a07`）：`litellm/` 包含 3169 个 Python 文件、约 108 万行；`litellm-rust/` 包含 76 个 crate 目录、1039 个 `.rs` 文件、约 22 万行。

```text
litellm/                    # Python 包本体：SDK + Router 门面 + proxy 网关
├── router_rust/            #   Rust 路由核心的 Python 侧（core/invoke/steps/surface）
├── router_python_host.py   #   PythonHost：Rust 核心的外联宿主
├── rust_bridge/            #   Python↔Rust 桥接（pyo3 绑定桩 _native.pyi）
├── redis/                  #   Rust 后端 Redis store 家族（限流/spend/冷却/用量）
├── litellm_core_utils/     #   日志管线、model 字符串解析、异常映射、流式聚合
├── llms/                   #   100+ provider 适配
└── proxy/                  #   AI Gateway：FastAPI 应用 + 全部端点
    ├── rust_forward/       #     LITELLM_RUST_FIRST 部署形态（supervisor/peer/server）
    └── server_listener.py  #     gunicorn 私有监听（PrivateListener）
litellm-rust/               # 独立 Cargo workspace（76 个 crate）
├── crates/                 #   router-core、gateway-*、inference-*、redis-* 等
└── docs/                   #   Rust 侧 ADR
gateway/                    # 数据面入口：main.py + launch.py + routes/
backend/                    # 管理面入口：main.py + routes/
litellm_cli/                # litellm / lite / litellm-proxy 命令入口
ui/                         # Dashboard 前端（litellm-dashboard，Node/React）
enterprise/                 # 商业版扩展（enterprise_hooks/、litellm_enterprise/）
litellm-proxy-extras/       # Proxy 附带物独立小包（Prisma 迁移工具链）
docs/                       # docs/adrs/ 决策记录 + docs/sourceReader/ 本套导读
tests/                      # unit/、e2e/、code_coverage_tests/
scripts/、ci_cd/            # lint 门禁与 CI 辅助脚本
schema.prisma               # 数据库 schema 唯一来源（proxy 运行时引用）
migrations/、db_scripts/    # 数据库迁移脚本
model_prices_and_context_window.json   # 全量模型价目表（成本计算数据源）
```

### 核心包

| 目录 | 职责 | 关键内容 |
|---|---|---|
| `litellm/` | Python 包本体，SDK 全部逻辑 | `main.py`、`router.py`、`router_rust/`、`litellm_core_utils/`、`llms/`、`caching/`、`redis/`、`proxy/` |
| `litellm/proxy/`（在包内） | AI Gateway 的 FastAPI 应用 | `proxy_server.py`、`auth/`、`hooks/`、`db/`、`rust_forward/`、`schema.prisma` |
| `litellm-rust/` | 独立 Rust workspace，核心逻辑下沉 | `crates/`（76 个 crate）、自己的 `docs/` |
| `litellm/rust_bridge/`（在包内） | Python↔Rust 桥接层 | `bindings.py`、`_native.pyi`、`host/`、按端点族的 `chat_completions/`、`messages/`、`responses/` 等 |
| `enterprise/` | 商业版扩展（单独发布） | `enterprise_hooks/`、`litellm_enterprise/` |
| `litellm-proxy-extras/` | Proxy 附带物，独立小包 | `litellm_proxy_extras/` 下的 Prisma 迁移工具链与迁移脚本 |

### 服务入口

| 目录/文件 | 职责 |
|---|---|
| `gateway/` | 数据面入口：复用 proxy app 只保留 LLM 转发路由；`gateway/launch.py` 在 worker 起来前组装 `DATABASE_URL` 并先拉起容器内 PgBouncer |
| `backend/` | 管理面入口：复用 proxy app，只保留管理后台路由 |
| `litellm_cli/` | `litellm`、`lite`、`litellm-proxy` 三个命令的 console entry point（`litellm_cli/main.py`） |
| `ui/` | Dashboard 前端（`ui/litellm-dashboard/`，Node/React 项目） |

### 基础设施与部署

| 目录/文件 | 职责 |
|---|---|
| `docker/`、`Dockerfile`、`docker-compose.yml`、`docker-compose.liteadmin.yml` | 容器构建与编排 |
| `helm/`、`terraform/`、`render.yaml` | K8s/Terraform/Render 部署 |
| `schema.prisma` | 数据库 schema 唯一来源（根目录，`litellm/proxy/schema.prisma` 与其同步） |
| `migrations/`、`db_scripts/` | 数据库迁移脚本 |
| `model_prices_and_context_window.json` | 全量模型价目表/上下文窗口表（成本计算的数据源） |
| `prometheus.yml`、`policy_templates.json`、`provider_endpoints_support.json` | 监控、guardrail 策略模板、provider 端点支持矩阵等数据文件 |

### 工程配套

| 目录/文件 | 职责 |
|---|---|
| `docs/` | 架构决策记录（`docs/adrs/`）与本套导读（`docs/sourceReader/`） |
| `tests/` | 测试（`unit/`、`e2e/`、`code_coverage_tests/` 等，入口约定见 `tests/AGENTS.md`） |
| `scripts/`、`ci_cd/` | lint 门禁脚本（`check_type_discipline.py`、`check_test_quality.py` 等）与 CI 辅助 |
| `skills/`、`packaging/`、`.devcontainer/`、`vscode-extension/` | agent skill 定义、发布打包、开发容器、IDE 扩展 |
| `Makefile` | `make check`、`make lint` 等开发命令 |
| `pyproject.toml`、`uv.lock`、`ruff.toml`、`ruff-strict.toml`、`ruff-tests.toml`、`pyrightconfig.json` | 构建与质量工具配置 |
| `AGENTS.md`、`ARCHITECTURE.md` | 贡献路由 hub 与架构总览 |

## `litellm/` 包内地图（按功能分组）

包内文件极多，按数据流顺序分组看最清晰。

### 1. 包初始化与延迟导入

| 文件 | 职责 |
|---|---|
| `litellm/__init__.py` | 暴露 `completion`、`acompletion` 等公共 API（经 `from .main import *` 转出）与全局配置变量 |
| `_lazy_imports.py` + `_lazy_imports_registry.py` | 按需导入重型依赖，加快 `import litellm` 速度 |
| `_logging.py` | `verbose_logger` 等日志设施 |
| `_process_defaults.py` | 进程级默认值初始化（`__init__.py` 模块开头即调用 `apply_process_defaults()`） |
| `_redis.py`、`_redis_credential_provider.py`、`_service_logger.py`、`_internal_context.py` | redis 客户端参数内省、Redis 凭证提供方、OTel 服务 span 日志、ContextVar 进程内信号 |

### 2. 调用入口层（Router 架构重写后）

| 文件/目录 | 职责 |
|---|---|
| `main.py`（9784 行） | `completion()`、`acompletion()`、`embedding()`、`text_completion()` 等全部 SDK 入口 |
| `router.py`（506 行） | Router 纯门面：`litellm/router.py :: Router :: __init__() :: +0` 只做 `attach(make_core(...))`，成员读写转发给核心，禁子类化 |
| `router_core.py`（55 行） | `litellm/router_core.py :: RouterCore :: +0` 协议与 `litellm/router_core.py :: make_core() :: +0` 工厂，无条件返回 Rust 核心 |
| `router_rust/` | Rust 核心的 Python 侧：`core.py`（`litellm/router_rust/core.py :: RustCore :: +0` pyo3 句柄）、`invoke/`（端点执行计划，端点名清单在 `litellm/router_rust/invoke/endpoints.py :: endpoint_names() :: +0`）、`steps/`（留宿主的有状态 step）、`surface/`（模型列表/健康/回退等门面成员）、`routing_stores.py` |
| `router_python_host.py` | `litellm/router_python_host.py :: PythonHost :: +0`：核心外联宿主，provider 调用经 `.invoke` 回 litellm 执行 |
| `router_api.py`（2026 行） | Router 的设置与观察面：`RouterRegistry`、`RouterSettings`、`RouterHealth`、`ChangeSet`、`ApplyResult` 等类型与工具函数 |
| `router_config.py` / `router_attempt.py` / `router_host.py` / `router_deprecated.py` | 配置构建、单次尝试、宿主绑定、弃用成员 |
| `router_strategy/` | 路由策略实现（`simple_shuffle.py`、`lowest_latency.py`、`lowest_cost.py`、`least_busy.py`、`lowest_tpm_rpm_v2.py` 等，以及 `adaptive_router/`、`auto_router/`、`complexity_router/`、`quality_router/`、`switchyard_router/`） |

旧文档列出的 `router_python_core.py`（1.8 万行 Python 版路由核心）已被删除，其选部署、重试、冷却、fallback 职责全部移入 Rust 核心；`as_output_cap`、`stamped_client_ceiling` 等函数迁往 `litellm/router_rust/steps/prerouting.py`。

### 3. Provider 适配层

| 目录 | 职责 |
|---|---|
| `llms/` | 100+ provider 目录（实测 166 个条目），每个目录内按模态分子目录（如 `anthropic/chat/transformation.py`） |
| `llms/custom_httpx/llm_http_handler.py`（14455 行） | `BaseLLMHTTPHandler`：所有走 HTTP 的 provider 的统一执行器 |
| `llms/base_llm/` | 各模态的基类（`BaseLLM` 等） |

### 4. 核心工具层

| 目录/文件 | 职责 |
|---|---|
| `litellm_core_utils/` | 全局单例与横切工具：`litellm_logging.py`（日志管线，8491 行）、`get_llm_provider_logic.py`（`litellm/litellm_core_utils/get_llm_provider_logic.py :: get_llm_provider() :: +0`）、`exception_mapping_utils.py`（错误映射）、`streaming_handler.py`（流式聚合）、`token_counter.py`、`prompt_templates/` |
| `caching/` | LLM 响应缓存：`caching.py`（`litellm/caching/caching.py :: Cache :: +0`）、`dual_cache.py`、`caching_handler.py` |
| `cost_calculator.py` | 成本计算（4264 行，配合价目表 JSON） |
| `exceptions.py` | 全部异常类型定义 |
| `types/` | Pydantic/TypedDict 类型（OpenAI 兼容请求响应模型等） |
| `integrations/` | `CustomLogger` 回调体系：Langfuse、Datadog、Slack 告警、guardrail 基类等 |

### 5. 各模态/协议子包

| 目录 | 职责 |
|---|---|
| `responses/`、`chat_completions/`、`messages/`、`embeddings/`、`text_completions/`、`images/`、`rerank_api/` | 各 API 形态的转换逻辑 |
| `anthropic_interface/`、`a2a_protocol/`、`realtime_api/`、`passthrough/` | Anthropic 协议、A2A、WebSocket 实时、直通 |
| `assistants/`、`batches/`、`files/`、`fine_tuning/`、`vector_stores/`、`containers/` | OpenAI 对应资源的 SDK 封装 |
| `mcp_client/`、`experimental_mcp_client/`、`skills/`、`harness/` | MCP 客户端、Skills、agent harness |
| `budget_manager.py`、`scheduler.py`、`timeout.py`、`guardrails.py` | 预算、调度、超时、guardrail 顶层封装 |
| `accounting/`、`repositories/`、`decisions/`、`tracing/`、`telemetry/`、`models/`、`proxy_auth/`、`sandbox/`、`search/`、`rag/`、`ocr/`、`videos/` | 其他专项子包：账务投影、仓储层、决策、追踪、遥测与更多模态封装 |

### 6. `litellm/redis/`（Rust 后端 store 包）

| 文件/目录 | 职责 |
|---|---|
| `litellm/redis/store_settings.py` | `litellm/redis/store_settings.py :: RedisStoreSettings :: +0`：store 的连接与用途设置 |
| `stores/rate_limits/` | 限流计数 store，入口 `litellm/redis/stores/rate_limits/__init__.py :: RateLimitStore :: +0` |
| `stores/spend_counters/`、`stores/auth_cache/` | spend 计数与 auth 缓存 store |
| `stores/router_cooldowns/`、`stores/router_usage/`、`stores/sensitive_route_pins/` | 路由冷却、用量、敏感路由钉扎 store |

v3 限流器、spend counters、路由冷却与用量、auth cache 都已接入这套 store（对应的 Rust 实现在 `litellm-rust/crates/` 的 `redis-*` crate 族）。

## `litellm/proxy/` 包内地图

| 子目录/文件 | 职责 |
|---|---|
| `proxy_server.py`（23099 行） | FastAPI app（`litellm/proxy/proxy_server.py :: app :: +0`）+ 全部端点注册（如 `litellm/proxy/proxy_server.py :: chat_completion() :: +0`）+ 全局状态（`llm_router`、`user_api_key_cache` 等） |
| `common_request_processing.py` | `litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: base_process_llm_request() :: +0`：所有 LLM 请求端点的共用处理流程 |
| `route_llm_request.py` | 请求进入 Router 前的路由决策（`litellm/proxy/route_llm_request.py :: route_request() :: +0`：model group 解析、通配模型、per-request 路由设置） |
| `litellm_pre_call_utils.py`、`_router_host.py` | `add_litellm_data_to_request` 注入 key/team/用户信息；proxy 侧 RouterHost（回答 pass-through 凭证、auto-router 访问等问题） |
| `auth/` | 鉴权：`user_api_key_auth.py` 为主入口，`auth_checks.py`、`handle_jwt.py`、`oauth2_check.py` 等 |
| `hooks/` | Proxy 级回调：限流（`litellm/proxy/hooks/parallel_request_limiter_v3.py :: _PROXY_MaxParallelRequestsHandler_v3 :: +0`）、成本记账 `proxy_track_cost_callback.py` 等 |
| `db/` | Prisma 客户端封装：`db_spend_update_writer.py`（花费批量写）、`db_url_settings.py` |
| `rust_forward/` | `LITELLM_RUST_FIRST` 部署形态：`mode.py`（开关 `litellm/proxy/rust_forward/mode.py :: SWITCH_ENV :: +0`）、`peer.py`（Rust 网关对端，还原客户端地址）、`server.py`、`supervisor/`（起 Rust 网关占公网端口） |
| `server_listener.py` | gunicorn 私有监听（`litellm/proxy/server_listener.py :: PrivateListener :: +0`，InheritedFd/AssignedPort） |
| `management_endpoints/`、`spend_tracking/`、`public_endpoints/` | 管理 API（key/team/budget CRUD、花费报表） |
| `anthropic_endpoints/`、`response_api_endpoints/`、`vertex_ai_endpoints/`、`google_endpoints/`、`pass_through_endpoints/` | 多协议端点 |
| `image_endpoints/`、`batches_endpoints/`、`openai_files_endpoints/`、`rerank_endpoints/`、`vector_store_endpoints/`、`ocr_endpoints/`、`video_endpoints/`、`realtime_endpoints/`、`agent_endpoints/` | OpenAI 资源与新增模态端点 |
| `mcp_server/`、`memory/`、`prompts/`、`workflows/`、`lens/` | MCP 服务、memory、prompt 管理、工作流等扩展端点 |
| `proxy_cli.py` | `litellm` CLI 服务启动（`litellm/proxy/proxy_cli.py :: run_server() :: +0`，uvicorn/gunicorn 编排、配置加载） |
| `proxy_config.yaml`、`dev_config.yaml` | 默认与开发用配置样例 |
| `middleware/`、`guardrails/`、`policy_engine/` | 中间件、guardrail、策略引擎 |

## 找代码的经验法则

| 想找什么 | 去哪里 |
|---|---|
| 某端点的 HTTP 处理函数 | `litellm/proxy/proxy_server.py` 搜路径字符串 |
| 路由决策（选部署/重试/冷却） | `litellm-rust/crates/router-core`（决策本体）与 `litellm/router_rust/`（Python 侧句柄与 step） |
| Router 的端点名与执行计划 | `litellm/router_rust/invoke/endpoints.py` |
| 某模型参数如何翻译 | `litellm/llms/<provider>/<模态>/transformation.py` |
| model 字符串怎么变成 provider | `litellm/litellm_core_utils/get_llm_provider_logic.py` |
| 某错误如何映射 | `litellm/litellm_core_utils/exception_mapping_utils.py` |
| 某回调/可观测平台 | `litellm/integrations/<平台名>.py` |
| 限流/spend 的 Redis 读写 | `litellm/redis/stores/` |
| 某类型的定义 | `litellm/types/` 下按模块名找 |
