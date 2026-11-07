# 函数级解析：日志管线与成本计算

> 所属层级：第四层（源码补齐） | 覆盖：`litellm_core_utils/litellm_logging.py :: Logging`、`cost_calculator.py`

## 1. `Logging.__init__()`

```
litellm/litellm_core_utils/litellm_logging.py :: Logging :: __init__() :: +0（731 行处）
```

| 项 | 内容 |
|---|---|
| 职责 | 每请求一个的日志引擎构造：收集调用上下文与回调清单 |
| 参数 | `model`、`messages`、`stream`、`call_type`、`start_time`、`litellm_call_id`、`function_id`、`litellm_params`、`kwargs` 等 |
| 状态字段 | `self.model`（`+34`）、`self.stream`（`+41`）、`model_call_details: dict`（全程事件流记录）、回调管理器实例 |
| 核心算法 | `+60`：`stream_usage_injected` 标记（防止流式 usage 重复注入）；回调聚合：全局 `litellm.callbacks` + 调用级动态回调 + 环境变量回调，去重后入 `LoggingCallbackManager` |

## 2. `pre_call()` / `post_call()`

```
litellm/litellm_core_utils/litellm_logging.py :: Logging :: pre_call() :: +0（1631 行处）
litellm/litellm_core_utils/litellm_logging.py :: Logging :: post_call() :: +0（1844 行处）
```

| 函数 | 职责 |
|---|---|
| `pre_call` | 广播 `log_pre_api_call` 给同步回调；把输入快照进 `model_call_details` |
| `post_call` | 广播 `log_post_api_call`；记录原始响应骨架 |

## 3. `success_handler()` / `async_success_handler()`

```
litellm/litellm_core_utils/litellm_logging.py :: Logging :: success_handler() :: +0（3595 行处）
litellm/litellm_core_utils/litellm_logging.py :: Logging :: async_success_handler() :: +0（4109 行处）
```

| 项 | 内容 |
|---|---|
| 职责 | 成功事件的完整处理：元数据更新 → 成本计算 → 回调广播 |
| 参数 | `result`（ModelResponse/流）、`start_time`、`end_time`、`cache_hit` |
| 前置 | `pre_call` 已执行（`model_call_details` 有输入） |
| 后置 | `_hidden_params["response_cost"]` 已写入；回调已收到标准化事件 |

`async_success_handler` 的内部顺序（`+4109` 起，主体在 `_async_success_handler_body :: +18`）：

1. 批量场景短路：batch 结果直接 `set_hidden_param(result, "response_cost", ...)`（`+48`、`+84` 相对函数）
2. `+102`：`_success_handler_helper_fn(...)` 更新元数据（等同 update_response_metadata 职责）
3. `+137`：缓存命中时 `model_call_details["response_cost"] = 0.0`；否则 `+142` 调 `self.response_cost_calculator(...)` 算钱
4. `dispatch`：`LoggingCallbackManager` 并行调用各回调的 `async_log_success_event`

流式请求的成功事件延迟到流结束（`CustomStreamWrapper.finish()` 触发），聚合 usage 传入。

## 4. `response_cost_calculator()`

```
litellm/litellm_core_utils/litellm_logging.py :: Logging :: response_cost_calculator() :: +0（2093 行处）
```

| 项 | 内容 |
|---|---|
| 职责 | Logging 侧的成本入口：决定用哪种计价路径 |
| 参数 | `response_cost_calculator_kwargs`（`+2183` 组装） |
| 核心算法 | `+2234`：同步场景走 `litellm.response_cost_calculator`（即 `cost_calculator.completion_cost` 的包装）；`+2274` 别名 `_response_cost_calculator`；异步版 `+2453` |
| 返回 | `float`（写进 `_hidden_params["response_cost"]`） |

## 5. `failure_handler()` / `async_failure_handler()`

```
litellm/litellm_core_utils/litellm_logging.py :: Logging :: failure_handler() :: +0（4621 行处）
litellm/litellm_core_utils/litellm_logging.py :: Logging :: async_failure_handler() :: +0（4826 行处）
```

| 项 | 内容 |
|---|---|
| 职责 | 失败事件广播（异常对象、traceback 进 `model_call_details`） |
| 参数 | `exception`、`traceback_exception`、`end_time` |
| 后置 | 失败回调收到标准化异常；Router 的重试层不依赖它（重试决策在异常路径同步做） |

## 6. `completion_cost()`

```
litellm/cost_calculator.py :: completion_cost() :: +0（1764 行处）
```

| 项 | 内容 |
|---|---|
| 职责 | usage × 单价 → 美元成本 |
| 参数 | `completion_response`（带 usage 的响应，可选）、`model`、`custom_llm_provider`、`call_type`、`custom_cost_per_token`、`custom_cost_per_second`、`total_time`、`pricing_provider` 等 |
| 返回 | `float` |
| 前置 | 能解析出一个有定价的 model 名（`+43` docstring：解析不到就抛，提示用 `litellm.register_model` 注册） |
| 后置 | 无副作用 |

核心算法（`+1764` 至 `+1900`）：

1. `+48`：DecisionsResponse 特判——无 usage 直接 ValueError
2. 模型名解析链：`completion_response.model` → `model` 参数 → `base_model`（deployment 的 underlying model）；价格查询 `litellm.model_cost`（启动时从 `model_prices_and_context_window.json` 加载），支持前缀/通配定价条目
3. token 计价：`prompt_tokens × input_price + completion_tokens × output_price`（cache read/write token 按各自单价）；按秒计价的 provider（视频等）用 `total_time × 单价`
4. `custom_cost_per_token` 显式覆盖一切表价
5. 折扣/预算策略在外层（`cost_discount` 等 helper，`litellm_core_utils/cost_discount.py`）叠加

## 7. 设计要点

**要点 1：回调失败隔离。** `LoggingCallbackManager`（`litellm_core_utils/logging_callback_manager.py :: LoggingCallbackManager :: +0`）逐个 try/except 调用回调并打日志，一个回调崩溃不影响其余回调与主请求。

**要点 2：`model_call_details` 是单一事实源。** pre_call 输入、原始响应、耗时、成本全部累加进这个 dict，任何回调要上下文都从这拿。

**要点 3：同步/异步双轨。** 同步 `success_handler` 服务纯 SDK 用户；Proxy 走 `async_success_handler`。两轨共享同一套 helper（元数据更新、成本计算）。
