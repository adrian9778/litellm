# LiteLLM 源码导读（sourceReader）

一套面向新手的 LiteLLM 源码文档库：从系统骨架读到函数级实现，每一处结论都可以回到源码定位验证。

- 基线：`upstream/main @ 0608a41a07`（2026-11-12 快照，上游 392 commit 之上的全量重生成）。代码是唯一事实来源，若文档与代码冲突，以代码为准
- 主 traced 场景：AI Gateway（Proxy）收到 `POST /v1/chat/completions`，路由到 OpenAI `gpt-4o-mini` 并返回

## 阅读路线

四层递进，按序阅读效果最好。每层回答一个问题：

| 层 | 目录 | 回答的问题 | 篇目 |
|---|---|---|---|
| 一 | `01-skeleton/` | 项目是什么、由什么组成、请求怎么流转 | 4 |
| 二 | `02-walkthrough/` | 一个真实请求从入口到响应走了哪条路 | 2 |
| 三 | `03-deep-dive/` | 这条路上的每一跳具体发生了什么 | 8 |
| 四 | `04-function-reference/` | 每个关键函数的职责、参数、返回值与算法 | 13 |

## 目录索引

### 第一层：系统骨架

| 文档 | 内容 |
|---|---|
| [01-what-is-litellm.md](01-skeleton/01-what-is-litellm.md) | 项目定位，SDK 与 Gateway 双形态，核心能力清单 |
| [02-repo-layout.md](01-skeleton/02-repo-layout.md) | 仓库目录地图，顶层目录与子包职责 |
| [03-modules-and-dependencies.md](01-skeleton/03-modules-and-dependencies.md) | 核心模块职责表，模块依赖关系图 |
| [04-request-lifecycle.md](01-skeleton/04-request-lifecycle.md) | 一条请求的宏观生命周期，主数据流图 |

### 第二层：真实全路径

| 文档 | 内容 |
|---|---|
| [01-scenario-setup.md](02-walkthrough/01-scenario-setup.md) | 场景定义、环境准备、可复现的启动与请求命令 |
| [02-full-path-trace.md](02-walkthrough/02-full-path-trace.md) | 从 curl 到 JSON 响应的完整 12 跳追踪，含每跳数据形态 |

### 第三层：主链路逐跳拆解

| 文档 | 内容 |
|---|---|
| [01-endpoint-and-parsing.md](03-deep-dive/01-endpoint-and-parsing.md) | FastAPI 入口，请求体读取，metadata 注入 |
| [02-auth-pipeline.md](03-deep-dive/02-auth-pipeline.md) | API key 校验，缓存查询，预算与模型门禁 |
| [03-pre-call-and-routing.md](03-deep-dive/03-pre-call-and-routing.md) | pre-call 参数注入，代理层路由决策 |
| [04-router-decision.md](03-deep-dive/04-router-decision.md) | 部署选择：健康过滤，冷却，负载均衡，重试与回退 |
| [05-sdk-completion.md](03-deep-dive/05-sdk-completion.md) | acompletion 内部：provider 解析，参数校验，分发 |
| [06-provider-translation.md](03-deep-dive/06-provider-translation.md) | HTTP handler 与 provider Config 的请求/响应变换 |
| [07-response-streaming-usage.md](03-deep-dive/07-response-streaming-usage.md) | 响应回传，流式切片，usage 统计 |
| [08-cost-logging-persistence.md](03-deep-dive/08-cost-logging-persistence.md) | 成本计算，日志回调管线，Postgres/Redis 持久化 |

### 第四层：函数级解析

| 文档 | 内容 |
|---|---|
| [01-proxy-entry-functions.md](04-function-reference/01-proxy-entry-functions.md) | `proxy_server.py` 端点函数与 `ProxyBaseLLMRequestProcessing` |
| [02-auth-functions.md](04-function-reference/02-auth-functions.md) | `proxy/auth/user_api_key_auth.py` 等鉴权函数 |
| [03-routing-functions.md](04-function-reference/03-routing-functions.md) | `route_llm_request.py`、`litellm_pre_call_utils.py` |
| [04-router-functions.md](04-function-reference/04-router-functions.md) | Router 门面、`router_api.py` 视图面、`router_core.py::make_core` 关键函数 |
| [05-acompletion-functions.md](04-function-reference/05-acompletion-functions.md) | `main.acompletion` 及其辅助函数 |
| [06-http-handler-functions.md](04-function-reference/06-http-handler-functions.md) | `BaseLLMHTTPHandler` 关键方法 |
| [07-provider-transform-functions.md](04-function-reference/07-provider-transform-functions.md) | 以 Anthropic Config 为例的变换函数 |
| [08-logging-cost-functions.md](04-function-reference/08-logging-cost-functions.md) | `litellm_logging.py`、`cost_calculator.py` 关键函数 |
| [09-persistence-cache-functions.md](04-function-reference/09-persistence-cache-functions.md) | 花费写入器、缓存层关键函数 |
| [10-streaming-functions.md](04-function-reference/10-streaming-functions.md) | `CustomStreamWrapper` 流包装器关键方法 |
| [11-rate-limiter-functions.md](04-function-reference/11-rate-limiter-functions.md) | `PROXY_MaxParallelRequestsHandler_v3` 限流函数 |
| [12-startup-lifecycle-functions.md](04-function-reference/12-startup-lifecycle-functions.md) | `run_server`、lifespan 与后台任务 |
| [13-rust-router-core.md](04-function-reference/13-rust-router-core.md) | Rust 路由核心专题：`make_core`、`RustCore`、steps、`_Driver`、`PythonHost` 边界 |

## 源码定位规范

文档中所有源码引用统一采用「文件路径 + 类/模块 + 函数名 + 相对行偏移」形式，不使用绝对行号，避免代码漂移导致引用失效：

```
litellm/proxy/proxy_server.py :: chat_completion() :: +31   # 端点函数体内第 31 行
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: base_process_llm_request() :: +0
litellm/llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler :: async_completion() :: +12
```

- `+0` 表示该函数/类定义行本身，`+N` 表示自定义行向下的偏移
- 顶层函数省略类名；模块级常量直接写 `常量名`
- 引用片段均为真实代码摘录，未改动的行与 HEAD 一致

## 术语速查

| 术语 | 含义 |
|---|---|
| SDK | `litellm/` 下的 Python 包本体，`litellm.completion()` / `litellm.acompletion()` 所在层 |
| Proxy / Gateway | `litellm/proxy/` 的 FastAPI 服务，在 SDK 之上加鉴权、限流、预算、路由 |
| Router | `litellm/router.py` 门面，负责多部署负载均衡、重试、回退 |
| Deployment | 一条具体可调用的配置（model + api_base + key 等），Router 的调度单位 |
| Provider Config | `litellm/llms/<provider>/chat/transformation.py` 中的适配类，负责请求/响应翻译 |
| hidden_params | 响应对象 `_hidden_params` 里的内部字段（如 `response_cost`），不进 OpenAI schema |
| DualCache | 内存 + Redis 两级缓存抽象 |

## 引用质量

每篇文档的源码引用都做过抽样回核，核对记录与修正历史见 [VERIFY.md](VERIFY.md)。
