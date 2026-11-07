# 仓库目录地图

> 所属层级：第一层（系统骨架） | 建议阅读顺序：2

## 顶层目录

仓库根目录按「核心包 / 服务入口 / 基础设施 / 工程配套」分成四组。

### 核心包

| 目录 | 职责 | 关键内容 |
|---|---|---|
| `litellm/` | Python 包本体，SDK 全部逻辑 | `main.py`、`router*.py`、`litellm_core_utils/`、`llms/`、`caching/`、`proxy/` |
| `litellm/proxy/`（在包内） | AI Gateway 的 FastAPI 应用 | `proxy_server.py`、`auth/`、`hooks/`、`db/`、`schema.prisma` |
| `litellm-rust/` | 独立 Rust workspace，核心逻辑下沉 | `crates/`、自己的 `docs/adrs/` |
| `litellm/rust_bridge/`（在包内） | Python↔Rust 桥接 | `bindings.py`、`_native.pyi` |
| `enterprise/` | 商业版扩展（单独发布） | `enterprise_hooks/`、`litellm_enterprise/` |
| `litellm-proxy-extras/` | Proxy 附带物，独立小包 | Prisma `migration.sql` 文件（其 README 说明：减小主包体积） |

### 服务入口

| 目录/文件 | 职责 |
|---|---|
| `gateway/` | 数据面入口：复用 proxy app，只保留 LLM 转发路由 |
| `backend/` | 管理面入口：复用 proxy app，只保留管理后台路由 |
| `litellm_cli/` | CLI 装饰层（`litellm` 命令的入口包装） |
| `ui/` | Dashboard 前端（Node/React 项目） |

### 基础设施与部署

| 目录/文件 | 职责 |
|---|---|
| `docker/`、`Dockerfile`、`docker-compose*.yml` | 容器构建与编排 |
| `helm/`、`terraform/`、`render.yaml` | K8s/Terraform/Render 部署 |
| `schema.prisma` | 数据库 schema 唯一来源（根目录，proxy 运行时引用） |
| `migrations/`、`db_scripts/` | 数据库迁移脚本 |
| `model_prices_and_context_window.json` | 全量模型价目表/上下文窗口表（成本计算的数据源） |

### 工程配套

| 目录/文件 | 职责 |
|---|---|
| `docs/` | 架构决策记录（`docs/adrs/`）与本套导读（`docs/sourceReader/`） |
| `tests/` | 测试（`unit/`、`e2e/`、`code_coverage_tests/` 等） |
| `scripts/`、`ci_cd/` | lint 门禁脚本、CI 辅助（如 `check_file_length.py`） |
| `cookbook/`、`examples/` | 使用示例 |
| `Makefile` | `make check`、`make lint` 等开发命令 |
| `pyproject.toml`、`uv.lock`、`ruff*.toml`、`pyrightconfig.json` | 构建与质量工具配置 |

## `litellm/` 包内地图（按功能分组）

包内文件极多，按数据流顺序分组看最清晰。

### 1. 包初始化与延迟导入

| 文件 | 职责 |
|---|---|
| `litellm/__init__.py` | 暴露 `completion`、`acompletion` 等公共 API 与全局配置变量 |
| `_lazy_imports.py` + `_lazy_imports_registry.py` | 按需导入重型依赖，加快 `import litellm` 速度 |
| `_logging.py` | `verbose_logger` 等日志设施 |
| `_process_defaults.py` | 进程级默认值初始化（`__init__.py` 第一行就执行它） |

### 2. 调用入口层

| 文件 | 职责 |
|---|---|
| `main.py`（9634 行） | `completion()`、`acompletion()`、`embedding()`、`text_completion()` 等全部入口函数 |
| `router.py`（212 行） | Router 门面：构建配置、选一个 RouterCore、把成员全部委托出去 |
| `router_api.py` | Router 的端点方法（`acompletion`、`aembedding`、`aresponses` 等） |
| `router_python_core.py`（1.8 万行） | Python 版路由核心：选部署、重试、冷却、fallback |
| `router_core.py` | `RouterCore` 抽象与 `make_core()` 工厂 |
| `router_config.py` / `router_attempt.py` / `router_host.py` / `router_deprecated.py` | 配置构建、单次尝试、宿主绑定、弃用成员 |
| `router_strategy/` | 路由策略实现（`simple_shuffle.py`、`lowest_latency.py`、`lowest_cost.py` 等） |
| `router_rust/` | Rust 版核心的 Python 侧封装 |

### 3. Provider 适配层

| 目录 | 职责 |
|---|---|
| `llms/` | 100+ provider 目录，每个目录内按模态分子目录（如 `anthropic/chat/transformation.py`） |
| `llms/custom_httpx/llm_http_handler.py`（1.4 万行） | `BaseLLMHTTPHandler`：所有走 HTTP 的 provider 的统一执行器 |
| `llms/base_llm/` | 各模态的基类（`BaseLLM` 等） |

### 4. 核心工具层

| 目录/文件 | 职责 |
|---|---|
| `litellm_core_utils/` | 全局单例与横切工具：`litellm_logging.py`（日志管线，8 千行）、`get_llm_provider_logic.py`（model 字符串解析）、`exception_mapping_utils.py`（错误映射）、`streaming_handler.py`（流式聚合）、`token_counter.py`、`prompt_templates/` |
| `caching/` | LLM 响应缓存：`caching.py`（`Cache` 类）、`dual_cache.py`、`caching_handler.py` |
| `cost_calculator.py` | 成本计算（配合价目表 JSON） |
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

## `litellm/proxy/` 包内地图

| 子目录/文件 | 职责 |
|---|---|
| `proxy_server.py`（2.3 万行） | FastAPI app 定义 + 全部端点注册 + 全局状态（`llm_router`、`user_api_key_cache` 等） |
| `auth/` | 鉴权：`user_api_key_auth.py` 为主入口，`auth_checks.py`、`handle_jwt.py`、`oauth2_check.py` 等 |
| `hooks/` | Proxy 级回调：限流 `parallel_request_limiter_v3.py`、成本记账 `proxy_track_cost_callback.py` 等 |
| `db/` | Prisma 客户端封装：`db_spend_update_writer.py`（花费批量写）、`db_url_settings.py` |
| `common_request_processing.py` | `ProxyBaseLLMRequestProcessing`：所有 LLM 请求端点的共用处理流程 |
| `route_llm_request.py` | 请求进入 Router 前的路由决策（model group 解析、通配模型、per-request 路由设置） |
| `litellm_pre_call_utils.py` | `add_litellm_data_to_request`：把 key/team/用户信息注入请求 |
| `management_endpoints/`、`spend_tracking/`、`public_endpoints/` | 管理 API（key/team/budget CRUD、花费报表） |
| `anthropic_endpoints/`、`response_api_endpoints/`、`vertex_ai_endpoints/`、`google_endpoints/`、`pass_through_endpoints/` | 多协议端点 |
| `image_endpoints/`、`batches_endpoints/`、`openai_files_endpoints/`、`rerank_endpoints/`、`vector_store_endpoints/` | OpenAI 资源端点 |
| `proxy_cli.py` | `litellm` CLI 服务启动（uvicorn/gunicorn 编排、配置加载） |
| `proxy_config.yaml`、`dev_config.yaml` | 默认与开发用配置样例 |
| `middleware/`、`guardrails/`、`policy_engine/` | 中间件、guardrail、策略引擎 |

## 找代码的经验法则

| 想找什么 | 去哪里 |
|---|---|
| 某端点的 HTTP 处理函数 | `litellm/proxy/proxy_server.py` 搜路径字符串 |
| 某模型参数如何翻译 | `litellm/llms/<provider>/<模态>/transformation.py` |
| model 字符串怎么变成 provider | `litellm/litellm_core_utils/get_llm_provider_logic.py` |
| 某错误如何映射 | `litellm/litellm_core_utils/exception_mapping_utils.py` |
| 某回调/可观测平台 | `litellm/integrations/<平台名>.py` |
| 某类型的定义 | `litellm/types/` 下按模块名找 |
