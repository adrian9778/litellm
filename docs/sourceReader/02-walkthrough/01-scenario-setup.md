# 场景：一次最小可复现的代理请求

> 所属层级：第二层（真实全路径） | 建议阅读顺序：5

## 场景定义

选定场景要满足「真实、最小、可复现」三条标准：

| 要素 | 选择 | 为什么 |
|---|---|---|
| 端点 | `POST /v1/chat/completions` | Gateway 最核心的数据面端点，覆盖所有核心模块 |
| 上游模型 | `openai/gpt-4o-mini` | 配置样例自带，OpenAI 兼容路径最典型 |
| 部署数 | 1 个 deployment | 排除负载均衡干扰，聚焦主链路 |
| 流式 | 否（`stream` 不传） | 先看一次性响应，流式在第三层单独展开 |
| 持久化 | 仅 master key，不配 DB | 最小启动。有 DB 时多出 spend 落库路径，文档会标注差异 |

对应源码配置样例：仓库自带的 `litellm/proxy/dev_config.yaml` 里就有这一条目（`- model_name: gpt-4o-mini / litellm_params: model: openai/gpt-4o-mini`）。

## 环境准备

前置：Python 3.10+，一个可用的 `OPENAI_API_KEY`。在仓库根目录执行：

```bash
# 安装本仓库的 litellm 包
pip install -e .

# 两个必需密钥
export OPENAI_API_KEY="sk-..."
export LITELLM_MASTER_KEY="sk-litellm-master-..."   # 同时充当代理的访问凭证
```

写一个最小配置文件 `my-config.yaml`：

```yaml
model_list:
  - model_name: gpt-4o-mini          # 客户端请求时用的名字（model group）
    litellm_params:
      model: openai/gpt-4o-mini      # 真正发给上游的 model 字符串（provider 前缀决定适配器）
      api_key: os.environ/OPENAI_API_KEY   # os.environ/ 前缀表示从环境变量取

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

这份 YAML 每个字段的去向：

| 字段 | 被谁消费 | 变成什么 |
|---|---|---|
| `model_list[].model_name` | Router 注册表 | model group 名，路由的目标 |
| `model_list[].litellm_params.model` | `get_llm_provider()` | 前缀 `openai/` 决定 provider 与适配类 |
| `model_list[].litellm_params.api_key` | deployment 参数 | 上游调用的凭证 |
| `general_settings.master_key` | 鉴权层 | 代理自身签发的根凭证 |

## 启动服务

标准方式（CLI）：

```bash
litellm --config my-config.yaml --port 4000
```

仓库开发方式（与 AGENTS.md 的 QA 流程一致）：

```bash
python litellm/proxy/proxy_cli.py --config my-config.yaml --port 4000 --detailed_debug
```

两条命令最终都走到 `litellm/proxy/proxy_cli.py :: run_server() :: +0`，由 uvicorn 拉起 `litellm.proxy.proxy_server:app`。启动日志里能看到的两个关键事件：

```
INFO: Uvicorn running on http://0.0.0.0:4000
...
# master_key 缺失时会打印警告：
# "LITELLM_MASTER_KEY is not set! All requests will be treated as INTERNAL_USER..."
```

这条警告来自 `litellm/proxy/proxy_server.py :: 模块级 startup 逻辑 :: master_key 检查`。

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

（这段 curl 与端点函数的 docstring 里的示例一致，见 `litellm/proxy/proxy_server.py :: chat_completion() :: docstring`）

## 预期响应

成功时收到 OpenAI 格式的 JSON（字段为 OpenAI schema，`litellm-*` 头是代理附加的）：

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

响应头里值得注意的代理附加字段：

```
x-litellm-response-cost: 0.0000165        ← 这次调用算出的美元成本
x-litellm-call-id: ...                    ← 本次调用在日志/审计里的关联 id
x-litellm-model-id: <deployment 唯一 id>  ← 命中的具体部署
```

失败时的典型响应（对照后面几层的错误传播分析）：

| 现象 | HTTP 状态 | 根因 |
|---|---|---|
| 忘带 `Authorization` | 401 | 鉴权层拒绝 |
| `model` 名不在 `model_list` | 400 | 路由层找不到 group |
| `OPENAI_API_KEY` 无效 | 401 | 上游错误被异常映射层翻译 |
| 全部 deployment 冷却中 | 429 | Router 无健康部署 |

## 本场景覆盖与不覆盖的路径

| 路径 | 覆盖情况 |
|---|---|
| 鉴权（master key 路径）、路由、翻译、执行、成本、响应头 | 完整覆盖 |
| 流式响应、DB 落库、多部署负载均衡、fallback | 不覆盖，第三/四层分析时会引用同一批模块的对应分支 |

下一篇开始逐跳追踪这个请求。
