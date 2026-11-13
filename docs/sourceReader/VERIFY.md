# 引用核对清单

生成基线 `upstream/main @ 0608a41a07`（2026-11-12 全量重生成）。每篇文档抽样 3~5 处源码引用回代码核对，全部通过后才收录。核对方式：以文档中的「文件 + 类/函数 + 偏移」换算回绝对行号，与 `grep`/`sed`/`sr_tools offset` 实测对照。

## 每篇的核对记录

| 文档 | 抽核点（文档中的引用） | 实测 | 结论 |
|---|---|---|---|
| README.md | 目录文件名与各层篇目一致（第四层现 13 篇） | 逐条比对实际文件树 | 通过 |
| 01-skeleton/01-what-is-litellm.md | `main.py :: acompletion :: +0`（652 行）；`router_core.py :: make_core :: +0`（51 行）；`messages/dispatch.py :: _rust_only_refusal :: +0`（189 行）；版本 1.110.0 | grep/sed 实测 | 通过 |
| 02-repo-layout.md | `litellm/router.py` 506 行；`proxy_server.py` 23099 行；新增 `router_rust/`、`rust_bridge/`、`redis/`、`rust_forward/`、根级 `litellm-rust/`；已删除的 `router_python_core.py`（不存在） | `wc -l`/`ls`/`git ls-tree` 实测 | 通过 |
| 03-modules-and-dependencies.md | 全局单例 `llm_router`（3173）、`user_api_key_cache`（3205）、`proxy_logging_obj`（3288）；`_within_total_timeout`（3280）；`router_core.py :: make_core`（51）；`RedisStoreSettings`（store_settings.py 20） | grep 实测 | 通过 |
| 04-request-lifecycle.md | 端点装饰器 `dependencies=[Depends(user_api_key_auth)]`；`_process_llm_request`（3302）route_request 调用（3388，+86）；`MissingMessageRoleError`（exceptions.py 372）；`LITELLM_CALL_ID_HEADER`（19）；`resolve_litellm_call_id`（387） | sed 实测并修正 6 处偏移 | 通过 |
| 02-walkthrough/01 | `rust_forward_mode`（mode.py 47）；默认路径纯 Python uvicorn；master key 警告（proxy_server.py 7354/7362）；run_server（proxy_cli.py 1298） | cat/grep 实测 | 通过 |
| 02-walkthrough/02 | `chat_completion`（13358）；`user_api_key_auth`（4565）；`base_process_llm_request`（3175）；`route_request`（832）；`make_core`（51）→`RustCore.build`（1519）→`RustEndpoints.acompletion`（1998）→`PythonHost.invoke`（107）；`get_custom_headers`（2419）/`cost_headers`（2096） | grep 实测，已删除的旧 `router_python_core.py` 引用全部重写 | 通过 |
| 03-deep-dive/01 | `chat_completion` metadata 注入（13391~13405，+33~+47）；`MissingMessageRoleError`（exceptions.py 372）；`answered_with_litellm_call_id`（token_count_log.py 143）；`open_sse_before_first_byte`（1719） | sed 实测并修正偏移 | 通过 |
| 03-deep-dive/02 | `user_api_key_auth`（4565）；`_should_skip_budget_checks`（4282，async）；`budget_served_model`（365）；`_normalize_model_for_auth`（477）；`_spend_counter_store`（4479）；`_BANNED_REQUEST_BODY_PARAMS`（auth_utils.py 498）；`get_model_from_request`（2762）`_handler_selected_model`（2833） | grep/sed 实测 | 通过 |
| 03-deep-dive/03 | pre-call 九步锚点；`add_litellm_data_to_request`；served-model 助手族（#51058）；`route_request`（832）；`enforce_total_timeout_scope`（162） | grep 实测 | 通过 |
| 03-deep-dive/04 | `router.py :: Router.__init__`（418）只 attach；`make_core`（51）无条件 `RustCore.build`（1519）；`RustCore`（1394）`_drive`（2880）`_run_steps`（2930）；`_Driver.attempt`（5214）`_routed_attempt`（5238）`select`（5380）`pre_route`（5401）；`StrategySelectors`（97）`pick_async`（261）；`PythonHost.invoke`（107）；`RouterCooldownsHandle`（router_cooldowns/handle.py 11） | grep 实测，旧 `router_python_core.py` 已不存在，引用全部重写 | 通过 |
| 03-deep-dive/05 | `acompletion`（652）；`run_in_executor`（945）；`get_llm_provider`（get_llm_provider_logic.py 187）；`validate_and_fix_openai_messages`（utils.py 9496）；缺 role 400 | grep 实测 | 通过 |
| 03-deep-dive/06 | `OpenAIChatCompletion`（openai.py，SDK 路径）；`BaseLLMHTTPHandler.async_completion`（820）；`use_base_llm_http_handler`（main.py 2853）；`transform_request`/`transform_response` | grep 实测 | 通过 |
| 03-deep-dive/07 | `CustomStreamWrapper`（457）；`chunk_creator`（1867）；`_stamp_usage_cost`（115，#51093）；`ResponsesAPIRequestUtils.affinity_*`（responses/utils.py）；#51243 归属 | grep 实测 | 通过 |
| 03-deep-dive/08 | `Logging`（731）；`async_success_handler`（+3522 壳）`_async_success_handler_body`（+3540）；`completion_cost`（cost_calculator.py 1779）；`DBSpendUpdateWriter.update_database`（742）+ #51110；`_narrowing_keys`（spend_log_api_key_scope.py）；OTel metadata keys 归位 | grep/sed 实测 | 通过 |
| 04-function-reference/01 | `chat_completion`（13358）偏移；`base_process_llm_request`（3175）；`_process_llm_request`（3302，+86 route_request）；`_within_total_timeout`（3280）；`get_custom_headers`（2419）；`cost_headers`（2096） | grep 实测 | 通过 |
| 04-function-reference/02 | `user_api_key_auth_builder`（2329）检查序；`budget_served_model`（365）；`_normalize_model_for_auth`（477）；`_should_skip_budget_checks`（4282 async）；`_spend_counter_store`（4479） | grep 实测并修正 4 处 | 通过 |
| 04-function-reference/03 | `route_request`（832）；`_route_request_single_attempt`；`enforce_total_timeout_scope`（162）；`add_litellm_data_to_request` 注入序；served-model 助手族 | grep 实测 | 通过 |
| 04-function-reference/04 | `Router`（410）/`__init__`（418）门面；`RouterCore` Protocol；`make_core`（51）无条件 `RustCore.build`；`RustEndpoints.acompletion`（1998）；`RouterRegistry`（581）视图面 | grep 实测，旧 PythonCore 引用重写 | 通过 |
| 04-function-reference/05 | `acompletion`（652）；fallbacks 取值；`run_in_executor`（945）；`async_completion_with_fallbacks`（fallback_utils 17）；缺 role 400（#51124） | grep 实测 | 通过 |
| 04-function-reference/06 | `BaseLLMHTTPHandler.async_completion`（820）；内部链重测；openai 默认走 SDK | grep 实测 | 通过 |
| 04-function-reference/07 | `AnthropicConfig`（648）；`get_supported_openai_params`（934）；`map_openai_params`（2026）；`transform_request`（2503）`transform_response`（3406）；`validate_environment`（common_utils 1575）；`anthropic_messages_pt`（factory 3015）；不覆写 `get_complete_url` | grep/sed 实测 | 通过 |
| 04-function-reference/08 | `Logging`（731）；`async_success_handler`（+3522 壳）`_async_success_handler_body`（+3540）；`response_cost_calculator`（+1442）；`completion_cost`（1779）；四新方法；OTel 归位 | grep/sed 实测并修正偏移 | 通过 |
| 04-function-reference/09 | `DBSpendUpdateWriter`（711）`update_database`（742）+ #51110；`_narrowing_keys`；`Cache`（128）`DualCache`（70）`LLMCachingHandler`（374）`UserApiKeyCache`（50）；Redis store 家族 | grep/sed 实测 | 通过 |
| 04-function-reference/10 | `CustomStreamWrapper`（457）；方法偏移全重测；`_dispatch_disconnect_billing_event`/`_UpstreamClosingStreamingResponse`/`_late_block_or_failure`/`open_sse_before_first_byte` 归位 `common_request_processing.py`；#51243 归属 | grep 实测 | 通过 |
| 04-function-reference/11 | `_PROXY_MaxParallelRequestsHandler_v3`（709）；`rate_limited_by` 头（3350，#51228）；`RateLimitedModel`（158）；`RateLimitStore`（rate_limits/__init__.py 67，#50170） | grep 实测 | 通过 |
| 04-function-reference/12 | `run_server`（1298）分支重测；`server_listener.py :: PrivateListener`（22）；`rust_forward_mode`（47）；`supervise`（supervisor 22）；`_proxy_lifespan` 序列；`ProxyStartupEvent`（11249） | grep 实测 | 通过 |
| 04-function-reference/13（新） | `make_core`（51）；`RustCore`（1394）`_drive`（2880）`_run_steps`（2930）；`StrategySelectors`（97）`as_output_cap`（627）`stamped_client_ceiling`（639）；`RustRetries`（retries.py 235）`RustFallbacks`（fallbacks.py 115）；`resolved_retry_policy`（24）；`PythonHost.invoke`（107）；`catalog.py :: RouteRule`（108） | grep 实测 | 通过 |

## 2026-11-13 增量刷新（workspace 包搬家 + 行为变化）

- **基线更新**：`0608a41a07` → `upstream/main @ df8b3b498e`（2026-11-13），上游再 +97 commit（rebase 至本分支）
- **结构搬家（#51000/#51006/#50992/#50981/#50966）**：workspace 包全数收进 `litellm/` 包内——`litellm-rust/` → `litellm/rust/`、`ui/` → `litellm/ui/`、`scripts/` → `litellm/scripts/`、`deploy/` → `litellm/deploy/`；根级 `ARCHITECTURE.md`/`gateway/`/`backend/` 删除或合并。`sr_tools` 的 `PROD_ROOTS` 收窄到 `("litellm",)`，`FALLBACK_ROOTS` 到 `("tests",".github")`
- **路径修正**：5 篇文档 12 处 `litellm-rust/crates/...` → `litellm/rust/crates/...`（04-router-decision、13-rust-router-core、04-router-functions、10-streaming、07-streaming）；`x-litellm-rust-peer` 是 HTTP 头名，未改
- **新增行为覆盖**：
  - 11-rate-limiter 新增 §8b 团队模型限额借用机制（`BorrowingTeamModelLimits`/`inherited_team_model_limit`/`borrowing_team_model_limits`/`team_model_limit_max_borrow_multiple` + dynamic_rate_limiter_v3 的 `AlternateGrant`/`SteeredModel`/`_team_model_settlement` + `priority_class_share.py`，#51328/#51359/#51366/#51350/#51417/#51415/#51367）
  - 02-auth-pipeline 新增 §#51428 先头拒绝（`_reject_from_headers_before_reading_body`，blocked/over-limit key 凭头信息先拒、不读 body）
  - 01-endpoint 补 token_counter 计数口径（`_tool_change_tokens`/`_is_text_block`/`has_only_text_content`，#51447/#51334）
- 版本 1.110.0 → 1.111.0；`proxy_server.py` 23099 → 23033 行

## 2026-11-12 全量重生成（本次）

- **基线更新**：`3f4dc93b40`（2026-11-04）→ `upstream/main @ 0608a41a07`（2026-11-12），上游 392 commit、`litellm/` 下 907 文件
- **架构级变化重写**：`router_python_core.py`（1.8 万行 PythonCore）被 #50178 移除（已删除），Rust 核心接管（`router_rust/`、`rust_bridge/`、`litellm-rust/` crate）。波及 7 篇引用该文件的文档，全部重写为 Rust 决策链语义（门面 `Router` → `make_core` → `RustCore` → steps → `PythonHost.invoke`）
- **新增第 4 层第 13 篇** `13-rust-router-core.md`（Rust 路由核心专题）
- **新增/迁移子包写入**：`litellm/redis/` store 家族（限流/冷却/用量/auth cache）、`litellm/proxy/rust_forward/`（LITELLM_RUST_FIRST 监督）、`server_listener.py`（gunicorn 私有监听）、`gateway/launch.py`、`litellm_cli.main:proxy_worker_app`
- **工具修复**：`sr_tools.py` 的 `offset`/`locate` 对「定义行前有空行」的符号少报 1-2 行（`^\s*` 跨行吞空行），改 `^[ \t]*`；`offset` 优先取真赋值行（跳过同名 kwarg）。修复后用 offset + `grep -n` 全库重测，修正多处偏移/快照行号
- **行为变化写实**：#51124 缺 role 400、#51093 显式免费 cost=0、#51228 `rate_limited_by` 头、#51114 SSE keepalive guardrail block、#51254 凭证清洗、#51226 path 模型访问、#50857 per-customer per-model 限流、#51110/#51127 spend 守卫、#50871/#49606 启动路径

## 2026-11-08 复检与补篇

- **复检**：漂移为 0（`3f4dc93b40..HEAD` 无上游代码变更）；全库 `verify --symbols` 通过，修复 VERIFY.md 自身 5 处引用
- **补篇**（第四层 9 → 12 篇）：`10-streaming-functions.md`（CustomStreamWrapper）、`11-rate-limiter-functions.md`（PROXY_MaxParallelRequestsHandler_v3）、`12-startup-lifecycle-functions.md`（run_server → _proxy_lifespan → ProxyStartupEvent）

## 偏移换算规则备忘

文档统一 `+0` = 定义行本身，`+N` = 定义行向下第 N 行。文中形如「+0（NNNN 行处）」的括号行号是生成时快照，仅帮助定位，漂移以偏移语义为准。

## 2026-11-07 规范化刷新（source-doc-refresh）

- **漂移审计**：基准 `3f4dc93b40` 与 HEAD 间上游代码 0 commit，16 组核心「文件+符号」抽检全部命中
- **记法净化**：清除 41 处绝对行号残留，全库改纯「符号 + 偏移」定位
- **符号级校验纠错**：修正 2 处臆造符号名、2 处文件归属（详见上表对应行）
- **上游文档扫描（4b）**：修复 `tests/e2e/AGENTS.md` fixture 路径（实际在 `tests/e2e/ui/fixtures/` 下）
- **工具落地**：`.progress/sr_tools.py`、`.progress/UPDATE-SPEC.md`、`.progress/state.json`、`.progress/tasks.json`
