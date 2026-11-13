# sourceReader 更新规范（UPDATE-SPEC）

## 基准

- 文档基准提交：`df8b3b498e`（upstream/main tip，2026-11-13 快照）。2026-11-13 增量刷新：上一基线 `0608a41a07`（2026-11-12 全量重生成基线）之上 rebase 97 commit，修引用 + 受影响篇语义更新
- 漂移检测：
  ```bash
  git rev-list --count df8b3b498e..HEAD
  ```
- 上游远端：`upstream` = https://github.com/berriai/litellm.git（本仓 origin 为 fork）

## 定位记法（库内统一约定）

一律「文件路径 + 类/函数 + 相对偏移」，`+0` = 定义行，`+N` = 符号体内第 N 行：

```
litellm/proxy/proxy_server.py :: chat_completion() :: +31
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: base_process_llm_request() :: +0
litellm/router_rust/core.py :: RustCore :: acompletion() :: +0
```

- 顶层函数/类省略中间段；模块级常量直接写常量名
- 库内使用 ` :: ` 分隔，**不要混用**其他风格
- **禁止**：`@行号` 写法与「文件名:行号」定位主引用；快照行号只允许出现在 VERIFY.md 历史区且标注「生成时快照」
- 索引类表格只给「符号 → 文件」，不给行号
- 两个文件路径并列时用 `、` 分隔，不要用 `·`（防符号抽取歧义）

## 工具链

```bash
# 定位符号（两遍扫描：先生产树，未命中再扫 tests/scripts）
python3 -I docs/sourceReader/.progress/sr_tools.py locate <SYM>...
# 文件骨架
python3 -I docs/sourceReader/.progress/sr_tools.py outline <FILE> [--top N]
# 取定义行号（换算函数内偏移用）
python3 -I docs/sourceReader/.progress/sr_tools.py offset <FILE> <SYM>
# 体检：@行号=0、疑似失效=0、符号级=0
python3 -I docs/sourceReader/.progress/sr_tools.py verify docs/sourceReader/*.md docs/sourceReader/*/*.md --symbols
```

- `verify` 只查路径可解析性与符号归属；偏移 `+N` 数值正确性必须人工/子代理回代码核对
- **2026-11-12 修复记录**：`locate`/`offset` 原对「定义行前有空行」的符号少报 1-2 行（`^\s*` 跨行吞空行），已改 `^[ \t]*` 并在 `offset` 里优先取真赋值行（跳过同名 kwarg）。修复前算出的偏移一律作废重算
- 写入前用 `grep -n` 对关键 def 行号交叉核对一次；模块级常量若与某 kwarg 同名，以 grep 为准
- ✗ 桶逐条判读：否定语境引用、运行期配置名、示例占位名是豁免档
- 改完必跑 verify，计数归零（豁免除外）

## 文档格式红线

- 每篇头部保留「所属层级 | 阅读顺序/拆解对象」元信息行，覆盖清单按新架构改
- 函数级文档结构固定：引用规范块、职责/参数/返回值/前置/后置/核心算法/错误处理表
- 每篇 ≥1 张图（ASCII 流程或 Mermaid），Mermaid 节点必须映射真实符号
- 新增篇目同步进 README 目录索引；删除篇目清理入链
- 正文中文，代码标识符保留原文；无占位词（TODO/待补充/同上）

## 已确认的架构事实（2026-11-12 实测于 0608a41a07，可采信，推翻前先重测）

### 主链路（survey B 全部回核通过）

1. **openai provider 默认走官方 SDK**（`litellm/llms/openai/openai.py :: OpenAIChatCompletion`）；`BaseLLMHTTPHandler` 仅 `EXPERIMENTAL_OPENAI_BASE_LLM_HTTP_HANDLER`（main.py `use_base_llm_http_handler`，现 2853 行附近）开启时服务 openai，其余 provider 默认走它
2. **`main.acompletion` 把同步 `completion()` 丢线程池**（`run_in_executor`，main.py 945），除非显式传 `fallbacks`
3. **限流器注册类 `PROXY_MaxParallelRequestsHandler_v3`**（`parallel_request_limiter_v3.py`，模块内类名 `_PROXY_MaxParallelRequestsHandler_v3`，`hooks/__init__.py:25` 导出公开别名）
4. **AnthropicConfig 不覆写 `get_complete_url`**（transformation.py 内 0 处定义），URL 在 `main.completion()` anthropic 分支解析
5. **`common_processing_pre_call_logic` 返回 `self.data, logging_obj`**（common_request_processing.py 2893）
6. **gateway/ 与 backend/ 是复用 `proxy_server.app` 的路由裁剪入口**，不是独立服务
7. `ProxyException` 在 `litellm/proxy/_types.py`（3946 起）；`UserAPIKeyAuth` 在 `litellm/types/proxy/auth/user_api_key_auth.py`（132 起）
8. **主链 12 跳入口符号全部未改名**：`proxy_server.py :: chat_completion`（13358 起）→ `common_request_processing.py :: ProxyBaseLLMRequestProcessing.base_process_llm_request`（3175 起）→ `auth/user_api_key_auth.py :: user_api_key_auth`（4565 起）→ `route_llm_request.py :: route_request`（832 起）→ `main.py :: acompletion`（652 起）→ `llms/custom_httpx/llm_http_handler.py :: BaseLLMHTTPHandler.async_completion`（820 起）

### Rust 路由核心（本次最大架构变化，survey A 回核通过）

9. **Router 是纯门面**（`router.py` 506 行）：`__init__` 仅 `attach(make_core(...))`，成员读写转发 `_core`；禁子类化，扩展走 `register_plugin` / `apply` / `observe`；端点名清单在 `router_rust/invoke/endpoints.py :: endpoint_names`（686 起）
10. **`router_core.py :: make_core`（51 起，全文件 55 行）无条件 `RustCore.build`**。双核时代（`Route.ROUTER`、`PythonCore`、`router_python_core.py`）已被 #50178 终结
11. **`router_rust/core.py :: RustCore`（1394 起）是 pyo3 句柄**（经 `rust_bridge/_native.pyi` 绑定 `litellm/rust/crates/router-core`，#51000 已把 workspace 从根级 `litellm-rust/` 挪进 `litellm/rust/`），进程内拥有选路、重试、fallback、cooldown、用量；有状态 LB 与 pre-routing 留宿主 step（`router_rust/steps/` 下 selection、prerouting；`steps/prerouting.py :: as_output_cap`、`stamped_client_ceiling`）；provider 调用经 `router_python_host.py :: PythonHost`（58 起）`.invoke` 回 litellm 执行
12. **执行层由 catalog 决定**：`chat_completions` 是 PYTHON_ONLY 执行；anthropic messages 是 RUST_REQUIRED（#51119），`litellm/messages/dispatch.py :: _rust_only_refusal`（189 起）抛 `UnsupportedParamsError`。两路由走同一个 Router
13. **`LITELLM_RUST_FIRST`（`proxy/rust_forward/mode.py` SWITCH_ENV，17 起）独立于 `LITELLM_RUST`**：经 `rust_forward/supervisor` 起 Rust 网关占公网端口、Python 退 loopback（`RustPeerMiddleware` 还原客户端地址），起不来回退纯 Python；gunicorn 私有监听走 `proxy/server_listener.py :: PrivateListener`（#50871 `gunicorn_overrides`）。两者互不启用
14. **`litellm/redis/` 新顶级包**：Rust 后端 store 家族（`stores/rate_limits :: RateLimitStore`、`stores/spend_counters`、`stores/auth_cache`、`store_settings :: RedisStoreSettings`），v3 限流器 / spend counters / 路由冷却与用量 / auth cache 已接入（#50169/#50170）

### 行为变化清单（写给相关篇目）

| 变化 | 出处 | 影响篇目 |
|---|---|---|
| 缺 role 消息改抛 `MissingMessageRoleError`（exceptions.py 372，BadRequestError 子类，HTTP 400），不再自动补 role（#51124 BREAKING）；校验在 `main.py :: validate_and_fix_openai_messages`（5668 起，签名加了 model/request_kwargs）+ `validate_chat_completion_user_messages`（utils.py 9496 附近） | B | 01-endpoint/02-full-path-trace/05-sdk/01-proxy-entry |
| 请求体凭证字段清洗：`auth_utils.py` `_BANNED_REQUEST_BODY_PARAMS` 加 Azure Entra 字段，`_reject_secret_references` 拒 os.environ//oidc/ 前缀；api_base 重定向时 `clientside_credential_handler.py` 清管理员字段（#51254） | B | 02-auth-pipeline/02-auth-functions |
| path 参数模型访问检查：`get_model_from_request` 新增 `_handler_selected_model`（Google/images 路由，#51226）；`proxy_server.py :: user_model_view` 新增 | B | 02-auth 篇 |
| `token_counter` 端点回 `x-litellm-call-id`（#51037，`token_count_log.py :: answered_with_litellm_call_id` 143 起；常量 `LITELLM_CALL_ID_HEADER`） | B | 01-endpoint |
| `total_timeout`（body 或头 `x-litellm-total-timeout`）非流式超时 408：`base_process_llm_request` 包 `_within_total_timeout`（`total_deadline.py`）；`route_llm_request.py :: enforce_total_timeout_scope` | B | 03-pre-call/01-proxy-entry/02-full-path-trace |
| SSE keepalive 后 guardrail block 流式返回（#51114 `on_passthrough_block`）；`open_sse_before_first_byte` ttft keepalive 仍在 | B | 03-pre-call/07-streaming |
| auth 预算按「服务所用模型」：`user_api_key_auth.py :: budget_served_model`（365 起）+ `litellm_pre_call_utils.py` served-model 助手族（#51058）；`_normalize_model_for_auth`（477 起，model_group_alias/Codex 解析）；`_should_skip_budget_checks` 改 **async**；auth prefetch `arm_routing_cooldowns` + `_spend_counter_store()` | B | 02-auth 两篇 |
| pre-call 新增注入/读取：`without_credential_headers`、`resolve_tenant_otel_destinations`（#50728）、`get_tenant_logging_metadata`（#50135）、Claude Code subagent 会话头（x-claude-code-session-id/agent-id）、`x-litellm-total-timeout`、`x-litellm-priority` 读取 | B | 03-routing-functions/03-pre-call |
| 显式免费费率 cost=0 落账：streaming `_stamp_usage_cost`（streaming_handler.py 114 起）+ `Logging.is_usage_explicitly_free`（#51093） | C | 07-streaming/10-streaming/08-logging-cost |
| 429 头新增 `rate_limited_by: descriptor_key`（parallel_request_limiter_v3.py 3350，#51228）；per-customer per-model tpm/rpm（#50857 `RateLimitedModel`、`_end_user_model_rate_limit_descriptor`）；fallback 目标预检 `async_fallback_target_allowed`（#50994/#51082）；限流计数接 Rust store（#50170） | C | 11-rate-limiter |
| spend 守卫：`DBSpendUpdateWriter.update_database` 对 free aget/acancel responses 不写创建行（#51110）；owner 限定读把空 key 行补回 `spend_log_api_key_scope.py :: _narrowing_keys`（#51127，该文件为基线后新增） | C | 08-cost-logging/09-persistence |
| reasoning item id 稳定化在 `litellm/responses/`（streaming_iterator.py、utils.py `ResponsesAPIRequestUtils.affinity_*`）+ Rust `ids.rs`，**不在** CustomStreamWrapper（#51243） | C | 10-streaming（澄清归属） |
| gunicorn 私有监听 `server_listener.py :: PrivateListener`（InheritedFd|AssignedPort）+ `run_gunicorn_server` 新参 `private_listener`（#50871）；启动先 `rust_forward/supervisor :: supervise`（#49606）；lifespan 与后台任务未动 | C | 12-startup |
| OTel v2 目的地 metadata keys：全部在 `litellm/integrations/otel/`（baggage.py `parse_destination_metadata_keys` ≤20 键、destination.py `metadata_keys` 字段），litellm_logging.py 只加 4 个小方法 | C | 08-logging-cost |

### 已消失符号与替代（写错即硬伤）

| 旧引用 | 现状 |
|---|---|
| `router_python_core.py` 全文件（`PythonCore`、`as_output_cap`、`stamped_client_ceiling`、`model_info_is_active_for_environment`、双核 `make_core`、`Route.ROUTER`） | 已删除；替代：`router_rust/core.py :: RustCore`、`router_rust/steps/prerouting.py`（前两个函数）、`router_rust/surface/registry.py :: model_info_is_active_for_environment`、`router_core.py :: make_core` |
| `proxy_server.py :: _swap_in_model_cost_map` | 删，改 `reload_result.model_count` |
| `proxy/auth/_spend_counter_redis_cache` | 删，改 `_spend_counter_store()`（`redis/stores/spend_counters`） |
| `_should_skip_budget_checks` | 仍在但改 async，调用处需 await |
| `async_completion_handler` | 从不存在（BASE/tip 均无），正名 `async_completion`（llm_http_handler.py 820） |

### 2026-11-13 刷新已确认变化（0608a41a07 → df8b3b498e，97 commit，写给本次派活）

| 变化 | 出处 | 影响篇目 |
|---|---|---|
| **#51000 workspace 包搬家**：`litellm-rust/` → `litellm/rust/`（76 crate 全数挪入 litellm 包，路径前缀改写即可）；`ui/` → `litellm/ui/`。注意 `x-litellm-rust-peer` 是 HTTP 头名不是路径，不改 | db6dfb6bb6 | 全库 9 篇正文 |
| **litellm_cli 澄清**：repo 无 `litellm_cli/` 目录。`.github/packaging/cli_package.py :: PACKAGE_NAME` 把 `litellm/cli`（`PACKAGE_DIR`）打包成独立发行包 `litellm_cli`，pyproject entry points（`litellm`/`lite`/`litellm-proxy`）写 `litellm_cli.main:*` 指的是该发行包的导入路径 | .github/packaging/cli_package.py | 02-repo-layout |
| **dynamic_rate_limiter_v3 借用机制**（本轮最大行为变化）：团队模型 TPM/RPM 限额可从其他团队借空闲容量（`team_model_limit_borrows_idle_capacity_from_other_teams`，#51328）；`team_model_limit_max_borrow_multiple` 封顶借多远（#51359）；priority class 份额在活跃团队间均分（新文件 `litellm/proxy/hooks/priority_class_share.py`，#51366）；flexible 团队在偏好模型饱和时被引导到定价相近的备选模型（`AlternateGrant`/`alternate_grant_for`/`alternates_for`/`_priced_within`，#51350）；prometheus per team+model 的 share/borrowed/throttle 指标（#51417）；模型饱和后 borrower 归还全额 share（#51415）；router fallbacks、嵌套调用、WebSocket turns、超大 prompt 也受借用约束（#51367）。`parallel_request_limiter_v3.py` 新符号：`BorrowingTeamModelLimits`（`share`/`borrow_ceiling`）、`inherited_team_model_limit`、`team_model_limit_max_borrow_multiple()`、`borrowing_team_model_limits()`、`dynamic_rate_limiter_covers()`、request stash 重构（`claim_request_stash_for_data`/`request_stash_for_callback`）。dynamic_rate_limiter_v3.py 新符号：`AlternateGrant`、`ModelPreference`、`SteeredModel`、`_BorrowingTeamShare`（`enforced`）、`_SettlementMetadata`/`_SettlementLoggingObject`、`_team_model_settlement`、`_tightest_team_share`、`_priority_class`/`_team_class_share` | #51328/#51359/#51366/#51350/#51417/#51415/#51367 | 11-rate-limiter（大改）、03-pre-call、02-auth（fallback_rate_limit.py +15） |
| **auth 读 body 前先拒**：`user_api_key_auth.py :: _reject_from_headers_before_reading_body`（blocked/over-limit key 凭头信息先拒，不再读请求体，#51428）；JWT end-user budget rate limits 执行（#51405）；`_team_obj_from_token` 返回类型改 `LiteLLM_TeamRebuiltFromToken` | #51428/#51405 | 02-auth 两篇 |
| **token_counter 计入工具变更**：mid-conversation tool 变更计入 token 数（`_tool_change_tokens`，#51447）；Anthropic server tool history 计入（#51334）；新函数 `_is_text_block`/`_has_only_text_content`/`has_only_text_content` | #51447/#51334 | 01-endpoint、07-streaming、01-proxy-entry |
| **otel 失败用量与 GenAI 模型**：chat 失败 span 区分 missing usage 与 prompt 估算（`opentelemetry.py :: _set_failure_usage_attributes`，#51443）；experimental GenAI traces 报 provider model（`otel/model/spans.py :: _semconv_response_model`，#51430） | #51443/#51430 | 08 两篇 |
| **anthropic messages native streaming**：signed empty thinking blocks 在 rust 侧保留（#51349）；重试时 rust 丢弃 null thinking signature（#51461）；rust stream transport error 命名 deployment（#51358）；idle Messages streams 期望走 rust（#51364）；`rust_bridge/host/routes/messages.py` 只把 anthropic metadata `user_id` 交给 rust（#51355） | #51349/#51461/#51358/#51364/#51355 | 10-streaming、07-streaming |
| **rust registry 读视频/计费单元成本**：`router_rust/surface/registry.py`、`router_rust/surface/model_info.py` 读 `output_cost_per_video`（#51433）与 `output_cost_per_billable_unit`（#51365） | #51433/#51365 | 13-rust-router-core、04-router-decision、04-router-functions |

## 更新流程（下次执行 source-doc-refresh 时）

1. 第 0 步量化漂移（commit 数、verify 计数、核心符号抽检），产出漂移报告
2. 让用户选深度（只修引用 / 骨架修补 / 全量重生成），不替用户决定
3. 架构级变化先更新本文件事实清单再派活
4. 收尾四零标准：`@行号`=0、疑似失效=0、断链=0、孤儿=0；更新 state.json 与 tasks.json
