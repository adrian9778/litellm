# 核心模块职责与依赖关系

> 所属层级：第一层（系统骨架） | 建议阅读顺序：3

## 模块职责表

按一次请求经过的先后顺序排列（职责细节在后三层展开，这里先建立「谁负责什么」的心智地图）：

| 模块 | 文件位置 | 职责 | 输入 | 输出 |
|---|---|---|---|---|
| Proxy 端点 | `litellm/proxy/proxy_server.py` | 注册全部 HTTP 端点，持有全局状态 | HTTP 请求 | 委托给处理流程 |
| 请求处理流程 | `litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing` | LLM 请求的统一处理骨架（读 body、调路由、异常转 HTTP） | 请求数据 dict | LLM 响应或 ProxyException |
| 鉴权 | `litellm/proxy/auth/user_api_key_auth.py` | 校验 API key/JWT，检查预算、模型访问、限流前置 | 请求头/体 | `UserAPIKeyAuth`（已认证身份） |
| Pre-call 注入 | `litellm/proxy/litellm_pre_call_utils.py :: add_litellm_data_to_request()` | 把 key/team/用户元数据写进请求 | data + `UserAPIKeyAuth` | 带元数据的 data |
| 代理层路由 | `litellm/proxy/route_llm_request.py :: route_request()` | 解析 model group、通配模型、per-request 路由设置 | data + Router | 归一化后的 model + 路由参数 |
| Router | `litellm/router.py`（门面）→ `router_python_core.py`（核心） | 多部署负载均衡、冷却、重试、fallback | data + model group | 单个 deployment 的调用结果 |
| SDK 入口 | `litellm/main.py :: acompletion()` | 参数规范化、provider 解析、缓存/日志挂钩、分发执行 | OpenAI 风格参数 | `ModelResponse` 或异步生成器 |
| Provider 解析 | `litellm/litellm_core_utils/get_llm_provider_logic.py :: get_llm_provider()` | 把 model 字符串解析成 provider + model | model 字符串 | `(model, provider, api_key, api_base)` |
| HTTP 执行器 | `litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler` | 统一执行所有 HTTP 型 provider 调用（含流式） | 参数 + ProviderConfig | 原始 httpx 响应 |
| Provider Config | `litellm/llms/<provider>/<模态>/transformation.py` | 请求/响应/错误的三向翻译 | OpenAI 格式 | provider 私有格式（及反向） |
| 日志管线 | `litellm/litellm_core_utils/litellm_logging.py :: Logging` | 驱动全部回调的 pre/post/success/failure 事件 | 调用上下文 + 响应 | 各回调收到标准化事件 |
| 成本计算 | `litellm/cost_calculator.py :: completion_cost()` | 按 usage × 价目表算钱 | 响应/usage | `response_cost: float` |
| Proxy 回调 | `litellm/proxy/hooks/proxy_track_cost_callback.py` | 在 Gateway 里接管成本记账 | 成功事件 + cost | 触发 DB 写入 |
| 花费持久化 | `litellm/proxy/db/db_spend_update_writer.py :: DBSpendUpdateWriter` | 批量聚合 spend 更新，写 Postgres | spend 增量 | `LiteLLM_SpendLogs` 表记录 |
| 缓存 | `litellm/caching/caching.py`、`dual_cache.py`、`caching_handler.py` | LLM 响应缓存（内存+Redis 两级） | 请求参数 | 缓存命中或未命中 |
| 类型系统 | `litellm/types/` | 全部请求/响应/配置的 Pydantic、TypedDict 定义 | — | — |

## 全局状态（proxy 进程内单例）

`proxy_server.py` 在模块级声明了一组全局变量，整个 Gateway 靠它们协作：

| 全局变量 | 类型 | 定义位置 | 赋值时机 |
|---|---|---|---|
| `llm_router` | `Router \| None` | `proxy_server.py :: 模块级 :: llm_router` | 启动/配置变更时 `_update_llm_router()` 里 `litellm.Router.from_config(...)` |
| `user_api_key_cache` | `UserApiKeyCache` | `proxy_server.py :: 模块级 :: user_api_key_cache` | 进程启动即创建 |
| `proxy_logging_obj` | `ProxyLogging` | `proxy_server.py :: 模块级 :: proxy_logging_obj` | 进程启动即创建 |
| `llm_model_list` | `list \| None` | `proxy_server.py :: 模块级 :: llm_model_list` | 随 Router 配置一起更新 |
| `general_settings`、`user_model` 等 | 配置项 | `proxy_server.py :: 模块级` | 加载 YAML 配置时 |

## 模块依赖关系图

**请求路径上的依赖（自上而下单向）**：

```mermaid
graph TD
    EP["proxy_server.py<br/>端点 chat_completion()"] --> AUTH["proxy/auth/<br/>user_api_key_auth"]
    EP --> PROC["common_request_processing.py<br/>ProxyBaseLLMRequestProcessing"]
    AUTH --> CACHE["UserApiKeyCache / DualCache / Redis"]
    AUTH --> DB[("PostgreSQL<br/>PrismaClient")]
    PROC --> PRE["litellm_pre_call_utils<br/>add_litellm_data_to_request"]
    PROC --> ROUTED["route_llm_request<br/>route_request"]
    ROUTED --> RT["router.py Router 门面"]
    RT --> CORE["router_python_core<br/>PythonCore"]
    CORE --> MAIN["main.py<br/>acompletion"]
    MAIN --> PROV["get_llm_provider_logic<br/>get_llm_provider"]
    MAIN --> HANDLER["llms/custom_httpx/<br/>llm_http_handler.py"]
    HANDLER --> CFG["llms/&lt;provider&gt;/chat/<br/>transformation.py"]
    HANDLER --> HTTP[("Provider HTTP API")]
    MAIN --> LOG["litellm_core_utils/<br/>litellm_logging.py"]
    LOG --> COST["cost_calculator.py<br/>completion_cost"]
    LOG --> CB["integrations/ 回调 +<br/>proxy/hooks/ 回调"]
    CB --> WRITER["proxy/db/<br/>db_spend_update_writer.py"]
    WRITER --> DB
```

**关键读法**：

- 依赖是严格分层的，上层只认识下一层的公共接口。`proxy_server.py` 不直接碰 `llms/`，`main.py` 不直接碰数据库
- 类型定义（`litellm/types/`）是所有模块的公共依赖，图中省略以免连线爆炸
- 日志管线（`Logging`）是唯一一个「回流」点：请求结束后由它反向驱动所有回调（含写 DB），主链路不直接写库

**Proxy 与 SDK 的边界**：

```
litellm/proxy/**   只做「网关的事」：鉴权、限流、记账、管理 API、多协议暴露
litellm/**（其余） 只做「调 LLM 的事」：翻译、执行、缓存、重试、成本
边界处只传两种东西：OpenAI 风格的参数 dict，和 litellm_logging.Logging 对象
```

## 两条横切线

横切线 1，回调（callback）体系。所有「额外动作」（可观测、限流、guardrail、记账）都实现 `CustomLogger` 接口（`litellm/integrations/custom_logger.py`），注册进 `litellm.callbacks`（SDK 侧）或 `proxy_server.py` 的 `load_callbacks_from_config()`（Proxy 侧），由日志管线在固定时机调用：

| 时机 | 回调方法 | 典型用途 |
|---|---|---|
| 请求前 | `async_pre_call_hook` | 限流、guardrail 注入 |
| 调用成功后 | `async_log_success_event` | 上报 Langfuse、记账 |
| 调用失败后 | `async_log_failure_event` | 告警、错误统计 |

横切线 2，配置体系。`litellm/proxy/proxy_config.yaml` 定义模型列表、router 设置、回调、数据库连接，由 `proxy_cli.py` 加载后喂给 `Router.from_config()`。绝大多数行为差异最终都能追溯到这份 YAML 的某个键。

下一篇把一次请求的宏观生命周期串起来。
