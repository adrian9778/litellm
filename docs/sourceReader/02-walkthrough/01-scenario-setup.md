# 场景定义与环境准备：一次最小可复现的网关请求

> 所属层级：第二层（真实全路径） | 建议阅读顺序：5
> 本篇基准提交：`411b64dc7a`（工作区当前 HEAD）

## 场景一句话

一台跑着 LiteLLM Proxy 的机器收到一个 `POST /v1/chat/completions`，请求要 `gpt-4o-mini`，代理鉴权通过后把它路由到配置里的那一个 OpenAI deployment，拿到上游 JSON，算好成本，把 OpenAI 格式的响应连同一批 `x-litellm-*` 头还给客户端。第二层的两篇只追这一条主成功路径，从一个 curl 到一份 JSON 为止。

## 选场景的三条标准

| 要素 | 选择 | 为什么这样选 |
|---|---|---|
| 端点 | `POST /v1/chat/completions` | 数据面最核心的端点，鉴权、pre-call、路由、执行、成本、响应头六段全部经过 |
| 上游模型 | `openai/gpt-4o-mini` | 仓库自带配置样例就有这一条，OpenAI 路径最典型，不需要额外 provider 适配 |
| deployment 数 | 1 个 | 排除负载均衡和 fallback 干扰，聚焦「选路怎么走」而不是「选哪个」 |
| 流式 | 否（请求里不传 `stream`） | 先看一次性响应的完整往返，流式在第三层单独展开 |
| 持久化 | 只配 master key，不配数据库 | 最小启动。配了 DB 会多出 spend 落库路径，本篇会标注差异但不展开 |

## 前置条件

一台装了 Python 3.10+ 的机器，一个可用的 `OPENAI_API_KEY`（用来让上游真的回话）。在仓库根目录执行：

```bash
pip install -e .
```

两个必需的环境变量：

```bash
export OPENAI_API_KEY="sk-..."                  # 上游 OpenAI 的凭证
export LITELLM_MASTER_KEY="sk-litellm-master-..."   # 代理自己签发的根凭证，本场景的请求就用它
```

`LITELLM_MASTER_KEY` 在这个场景里同时充当客户端访问代理的凭证，也就是 curl 里 `Authorization: Bearer` 后面那一串。

## 写一份最小配置

把下面内容存成 `my-config.yaml`：

```yaml
model_list:
  - model_name: gpt-4o-mini          # 客户端请求里写的名字（model group）
    litellm_params:
      model: openai/gpt-4o-mini      # 真正发给上游的 model 字符串，前缀决定适配器
      api_key: os.environ/OPENAI_API_KEY   # os.environ/ 前缀表示启动时从环境变量取

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

这份 YAML 的每个字段被谁消费：

| 字段 | 被谁消费 | 变成什么 |
|---|---|---|
| `model_list[].model_name` | Router 的注册表 | model group 名，路由匹配的目标 |
| `model_list[].litellm_params.model` | provider 解析逻辑 | 前缀 `openai/` 决定 provider 与适配类 |
| `model_list[].litellm_params.api_key` | 该 deployment 的调用参数 | 上游调用的凭证 |
| `general_settings.master_key` | 鉴权层 | 代理自己签发的根凭证 |

不想自己写配置的话，仓库自带的 `litellm/proxy/dev_config.yaml` 第 195 行起就是这条 `gpt-4o-mini` 条目（`- model_name: gpt-4o-mini`、`model: openai/gpt-4o-mini`），第 200 行起的 `general_settings.master_key: os.environ/LITELLM_MASTER_KEY` 也已经写好，直接拿它当 `--config` 参数即可。

`master_key` 若省略，代理不会拒绝请求，而是把每个请求都当 `INTERNAL_USER` 处理并在启动时打印一条 critical 日志，这是最小配置最容易踩的坑。

## 启动服务

标准方式（装好的 console 入口）：

```bash
litellm --config my-config.yaml --port 4000
```

本仓库的开发方式（带调试日志，与 AGENTS.md 的 QA 流程一致）：

```bash
python litellm/proxy/proxy_cli.py --config my-config.yaml --port 4000 --detailed_debug
```

两条命令最终都落到 `litellm/proxy/proxy_cli.py :: run_server() :: +0`。默认路径（不设 `LITELLM_RUST_FIRST`）是纯 Python：`run_server` 读 `rust_forward_mode(os.environ)`，未设开关时返回 disabled，于是跳过 Rust 网关前置分支，直接用 uvicorn 拉起 `litellm.proxy.proxy_server:app`。

启动成功的标志是日志里出现：

```text
INFO: Uvicorn running on http://0.0.0.0:4000
```

如果忘了设 `LITELLM_MASTER_KEY`，会看到一条 critical 级别的警告，说明所有请求都会被当成 `INTERNAL_USER` 处理。这条警告来自 `litellm/proxy/proxy_server.py :: ProxyConfig :: 模块加载时的 master_key 检查`。

LiteLLM 还支持一种「Rust 网关占公网端口、Python 退 loopback」的前置模式，开关是环境变量 `LITELLM_RUST_FIRST`（`litellm/proxy/rust_forward/mode.py :: rust_forward_mode() :: +0`，开关名 `SWITCH_ENV` 定义在 `+16`），与只影响 SDK 内 Rust 路径的 `LITELLM_RUST` 相互独立。本场景不设它，走纯 Python 主链路，Rust 前置的细节留到第三层启动篇。

## 发起请求

```bash
curl -X POST http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -d '{
    "model": "gpt-4o-mini",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

这段 curl 与端点函数 docstring 里的示例一致，见 `litellm/proxy/proxy_server.py :: chat_completion() :: +0` 起的 docstring（docstring 里给的是 `gpt-4o`，本场景换成配置里有的 `gpt-4o-mini`）。

`role` 必须给全：缺 `role` 的消息现在会抛 `MissingMessageRoleError`（HTTP 400），不再自动补 `role`。校验入口在 `litellm/utils.py :: validate_and_fix_openai_messages() :: +0` 与 `litellm/utils.py :: validate_chat_completion_user_messages() :: +0`。

## 预期响应形态

成功时收到 OpenAI chat completion 格式的 JSON。下面的示例是按 OpenAI schema 还原的示意结构，具体 `id`、`created`、`content` 文本与 token 数每次调用都不同，属 `[待运行验证]`：

```json
{
  "id": "chatcmpl-...",
  "object": "chat.completion",
  "created": 1762400000,
  "model": "gpt-4o-mini",
  "choices": [{
    "index": 0,
    "message": {"role": "assistant", "content": "Hello! How can I help you today?"},
    "finish_reason": "stop"
  }],
  "usage": {
    "prompt_tokens": 9,
    "completion_tokens": 12,
    "total_tokens": 21
  }
}
```

响应头里值得注意的代理附加字段，由 `litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: get_custom_headers() :: +0` 组装：

```text
x-litellm-response-cost: 0.0000165        ← 这次调用算出的美元成本（示意值）
x-litellm-call-id: ...                    ← 本次调用在日志与审计里的关联 id
x-litellm-model-id: <deployment 唯一 id>  ← 命中的具体部署
```

这三个头的字面量就在 `get_custom_headers` 的 headers 字典里，成本类头由同文件 `cost_headers() :: +0` 展开。

失败时的典型形态（对照第三层的错误传播分析）：

| 现象 | HTTP 状态 | 根因 |
|---|---|---|
| 忘带 `Authorization` | 401 | 鉴权层拒绝 |
| `model` 名不在 `model_list` | 400 | 路由层找不到 group |
| `messages` 里某条缺 `role` | 400 | 消息校验抛 `MissingMessageRoleError` |
| `OPENAI_API_KEY` 无效 | 401 | 上游错误被异常映射层翻译 |
| 全部 deployment 冷却中 | 429 | Router 无健康部署 |
| 非流式请求带 `total_timeout` 且超时 | 408 | `total_timeout` 拦截生效 |

## 本场景覆盖与不覆盖什么

| 路径 | 覆盖情况 |
|---|---|
| 鉴权（master key 路径）、路由、翻译、执行、成本、响应头 | 完整覆盖，下一篇逐跳展开 |
| 流式响应 | 不覆盖，第三层流式篇展开 |
| 数据库落库（spend、日志持久化） | 不覆盖，本场景无 DB，spend 只在内存计数 |
| 多部署负载均衡、fallback、冷却 | 不覆盖，本场景单 deployment，第三层路由决策篇展开 |
| Rust 网关前置（`LITELLM_RUST_FIRST`） | 不覆盖，第三层启动篇展开 |

下一篇 `02-full-path-trace.md` 从这个 curl 开始逐跳追踪到 JSON 响应。
