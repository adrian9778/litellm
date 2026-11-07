# LiteLLM 是什么

> 所属层级：第一层（系统骨架） | 建议阅读顺序：1

## 一句话定位

LiteLLM 用一套统一接口，把「调用 100+ 家 LLM API」和「把 LLM API 做成企业网关」两件事打包成了一个 Python 项目。它对外呈现两种形态：

```
形态一：SDK（库）          你的 Python 代码 ──▶ litellm.completion() ──▶ OpenAI / Anthropic / Bedrock / ...
形态二：Gateway（服务）    任意 HTTP 客户端 ──▶ litellm-proxy (FastAPI) ──▶ 内部仍调用 SDK ──▶ LLM API
```

两种形态是包含关系而非并列关系：Gateway 在每个请求里调用 SDK 完成真正的 LLM 调用。仓库根目录的 `ARCHITECTURE.md` 开头就是这张关系图。

## 包元数据

| 项 | 值 | 源码位置 |
|---|---|---|
| 包名 | `litellm` | `pyproject.toml` 顶部 |
| 版本 | `1.109.0` | `litellm/_version.py :: _installed_version()` |
| 一句话描述 | "Library to easily interface with LLM API providers" | `pyproject.toml` |

## SDK 形态能做什么

SDK 的入口集中在 `litellm/main.py`，全部是 OpenAI 风格签名，换模型只换 `model` 字符串前缀：

| 函数 | 用途 | 源码位置 |
|---|---|---|
| `litellm.completion()` | 同步 chat completion | `litellm/main.py :: completion() :: +0` |
| `litellm.acompletion()` | 异步 chat completion（Gateway 内部用的就是它） | `litellm/main.py :: acompletion() :: +0` |
| `litellm.embedding()` | 向量嵌入 | `litellm/main.py :: embedding() :: +0` |
| `litellm.text_completion()` | 文本补全 | `litellm/main.py :: text_completion() :: +0` |
| `litellm.completion_with_retries()` | 带重试包装 | `litellm/main.py :: completion_with_retries() :: +0` |

一个最小例子（SDK 直用）：

```python
import litellm
resp = litellm.completion(model="anthropic/claude-sonnet-4-5", messages=[{"role": "user", "content": "hi"}])
```

`model` 字符串的「前缀/路由」解析由 `litellm/litellm_core_utils/get_llm_provider_logic.py :: get_llm_provider()` 负责，这是 SDK 里被调用最频繁的纯函数之一。

## Gateway 形态能做什么

Gateway 是 `litellm/proxy/` 下的 FastAPI 应用，入口在 `litellm/proxy/proxy_server.py`（约 2.3 万行，单文件包含全部端点注册）。它在 SDK 之上叠加了企业能力：

| 能力 | 说明 | 主要源码位置 |
|---|---|---|
| 鉴权 | API key / JWT / OAuth2 / SSO 校验 | `litellm/proxy/auth/user_api_key_auth.py` |
| 限流 | 按 key/user/team 的 TPM/RPM/并发限制 | `litellm/proxy/hooks/parallel_request_limiter_v3.py` |
| 预算与计费 | 每次调用算钱、累加 spend、超预算拒绝 | `litellm/cost_calculator.py`、`litellm/proxy/db/db_spend_update_writer.py` |
| 多部署路由 | 按负载/延迟/成本在多个 deployment 间调度，支持冷却、重试、回退 | `litellm/router_api.py`、`litellm/router_python_core.py` |
| 持久化 | PostgreSQL（Prisma schema）存 key、团队、花费日志；Redis 做共享缓存与计数 | `litellm/proxy/schema.prisma` |
| 管理 UI | 内置 dashboard 的后端接口 | `litellm/proxy/management_endpoints/` |
| 协议兼容 | 同时暴露 OpenAI `/v1/chat/completions`、Anthropic `/v1/messages`、Responses API 等 | `litellm/proxy/proxy_server.py`、`litellm/proxy/anthropic_endpoints/` |

## 三种进程入口

同一个 FastAPI app 有三个启动方式，这是近期架构演进的结果（数据面与管理面分离）：

| 入口 | 端口 | 暴露什么 | 源码位置 |
|---|---|---|---|
| 传统 `litellm --config ...` | 4000 | 全部端点（数据面 + 管理面） | `litellm/proxy/proxy_cli.py :: run_server()` |
| `gateway.main:app` | 4000 | 只裁剪保留 LLM 数据面路由 | `gateway/main.py :: 模块级路由裁剪` |
| `backend.main:app` | 4001 | 只保留管理/后台路由 | `backend/main.py :: 模块级路由裁剪` |

`gateway/main.py` 的模块 docstring 写明：它复用 `litellm.proxy.proxy_server` 的 app，仅做「additive（纯增量）」的路由裁剪，不修改任何既有模块。

## Rust 成分（了解即可）

仓库正在把部分核心逻辑下沉到 Rust：

- `litellm-rust/`：独立 Cargo workspace（Rust 核心）
- `litellm/router_rust/`：Router 的 Rust 实现分支，`litellm/router_core.py :: make_core() :: +0` 在构造时为 Router「选择一个 RouterCore」（Python 或 Rust）
- `litellm/rust_bridge/`：Python 与 Rust 的桥接层

本套文档的主链路（chat completion 请求）当前仍走 Python 核心（`router_python_core.py`），Rust 分支只在骨架篇提及。

## 输入输出总览

| 形态 | 输入 | 输出 |
|---|---|---|
| SDK | Python 函数调用（OpenAI 风格参数） | OpenAI 风格的 `ModelResponse` 对象 |
| Gateway | HTTP 请求（OpenAI/Anthropic/Responses 等协议） | 同协议的 HTTP 响应 + `x-litellm-*` 元数据头 |
| Gateway 管理 | 配置 YAML / 管理 API / UI 操作 | key、预算、模型配置等 CRUD 结果 |

下一篇我们去走一遍仓库目录，把上面提到的每个模块落到具体目录上。
