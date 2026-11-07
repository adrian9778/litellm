# 引用核对清单

生成基线 `main @ 3f4dc93b40`。每篇文档抽样 3~5 处源码引用回代码核对，全部通过后才收录。核对方式：以文档中的「文件 + 类/函数 + 偏移」换算回绝对行号，与 `grep`/`sed` 实测对照。

## 每篇的核对记录

| 文档 | 抽核点（文档中的引用） | 实测 | 结论 |
|---|---|---|---|
| README.md | 目录文件名与各层篇目一致 | 逐条比对实际文件树 | 通过 |
| 01-what-is-litellm.md | `main.py :: acompletion :: +0`（638 行）；`_version.py :: _installed_version :: +0`（6 行）；`dev_config.yaml` 含 gpt-4o-mini 条目；`gateway/main.py` docstring；`Router.from_config` 在 `_update_llm_router`（8092 行） | grep/sed 实测全部命中 | 通过 |
| 02-repo-layout.md | `litellm/router.py` 212 行；`proxy_server.py` 2.3 万行；`litellm-proxy-extras` README 描述；`router_python_core.py` 1.8 万行 | `wc -l`/`ls` 实测 | 通过 |
| 03-modules-and-dependencies.md | `llm_router` 全局（3116 行）；`user_api_key_cache`（3143）；`proxy_logging_obj`（3217）；`x-litellm-response-cost` 字面量（1921）；`make_core`（router_core.py 54 行） | grep 实测 | 通过 |
| 04-request-lifecycle.md | 端点装饰器 `dependencies=[Depends(user_api_key_auth)]`（13102-13105）；`route_request` 调用注释 "constant time fetch"（3127）；`open_sse_before_first_byte`（1538） | sed 实测 | 通过 |
| 02-walkthrough/01 | dev_config.yaml 的 model_list/master_key 结构；`run_server`（proxy_cli.py 1228）；master key 警告文案（proxy_server.py 7294） | cat/grep 实测 | 通过 |
| 02-walkthrough/02 | `read_request_body`（http_parsing_utils.py 252）；头 `x-litellm-call-id`/`model-id`（2280-2281）；`simple_shuffle`（strategy 43）；`async_function_with_retries`（9717）；`OpenAIChatCompletion`（llms/openai/openai.py 405）；`use_base_llm_http_handler` 仅实验开关（2839） | grep 实测；openai 走 SDK 路径的错误 initially 已在文中修正 | 通过 |
| 03-deep-dive/01 | `read_request_body` 分支树（252 起）；`ProxyException`（_types.py 3874）；构造器字段（2196 起）；metadata 归一注释（13156） | sed 实测 | 通过 |
| 03-deep-dive/02 | `user_api_key_auth`（4344）；`user_api_key_auth_builder`（2189）；`secrets.compare_digest`（2810）；`validate_resolved_virtual_key`（2947）；`UserAPIKeyAuth`（types/proxy/auth 129）；检查序列注释（2996 起） | grep/sed 实测 | 通过 |
| 03-deep-dive/03 | pre-call 九步锚点（2503/2560/2572/2585/2631/2641/2673/2700 换算偏移）；`route_request`（747）；`_route_request_single_attempt` 分支（820-1046）；mock 门禁（481） | grep 实测并修正 3 处偏移 | 通过 |
| 03-deep-dive/04 | `PythonCore.acompletion` 实现（3782）；`_acompletion`（5004）；healthy 过滤链（15973 起）；`simple_shuffle` 调用（16421）；`set_cooldown_deployments`（10481/10873） | grep 实测 | 通过 |
| 03-deep-dive/05 | `acompletion`（638）；`get_llm_provider` 调用（887）；`fallbacks` 取值（735）；`run_in_executor`（931）；`ProviderConfigManager`（utils.py 9773） | grep 实测 | 通过 |
| 03-deep-dive/06 | `OpenAIChatCompletion.completion`（706）；SDK `chat.completions.create` 注释（549/605）；`BaseLLMHTTPHandler.completion`（868）；`async_completion`（795）；`transform_request`（handler 1041） | grep 实测 | 通过 |
| 03-deep-dive/07 | `CustomStreamWrapper`（397）；`check_send_stream_usage`（656，偏移 +259）；`chunk_creator`（1786，偏移 +1389）；`_UpstreamClosingStreamingResponse`（1103）；`_dispatch_disconnect_billing_event`（559） | grep 实测并修正 2 处偏移 | 通过 |
| 03-deep-dive/08 | `Logging`（669）；`success_handler`（3595）；`async_success_handler`（4109）；`completion_cost`（1764）；`DBSpendUpdateWriter.update_database`（682）；`_ProxyDBLogger.async_log_success_event`（417） | grep 实测 | 通过 |
| 04-function-reference/01 | `chat_completion`（13123）内部偏移（+31/+32-45/+50/+51/+73）；`base_process_llm_request`（2976）；`_process_llm_request`（3044）route_request 调用（3128，+84）；`common_processing_pre_call_logic` 返回（2712）；`open_sse_before_first_byte`（1538）；解析缓存在 `request.scope["parsed_body"]`（http_parsing_utils 414） | sed/grep 实测并修正 3 处 | 通过 |
| 04-function-reference/02 | builder 内部（2199/2217/2228/2699/2810/2876/2878 换算偏移）；`validate_resolved_virtual_key` 检查序（2996/3061/3090）；预算函数族（468/497/519/563/581）；`handle_authentication_error`（auth_exception_handler 141） | grep 实测并修正 4 处 | 通过 |
| 04-function-reference/03 | `_route_request_single_attempt` 体（800/802/804/806/815/820/824 换算偏移）；`ProxyModelNotFoundError`（226）；`add_litellm_data_to_request`（2611）注入序（2664 等） | grep 实测并修正 3 处 | 通过 |
| 04-function-reference/04 | 门面委托（router_api 1548）；`_acompletion` 内部（5105/5110/5114/5131/5134 换算偏移）；选择函数（16313/16336/2704）；`_deployment_num_retries`（982） | grep 实测并修正 1 处 | 通过 |
| 04-function-reference/05 | acompletion 步骤（735/887/899/909/931）；`_resolve_dispatched_chat_response`（1004）；`_model_response_from_cached_dict`（1010）；`function_setup` 签名与返回类型（utils.py 1261）；`async_completion_with_fallbacks`（fallback_utils 17） | grep/sed 实测并修正 2 处 | 通过 |
| 04-function-reference/06 | handler 内部（890/905/918/927/1040/1074/1106 换算偏移）；`get_optional_params`（utils.py 5505）；`make_sync_call`（1131）；`make_async_call_stream_helper`（1270）；`OpenAIGPTConfig.transform_response`（831） | grep 实测并修正 4 处 | 通过 |
| 04-function-reference/07 | `AnthropicConfig`（543）；`get_supported_openai_params`（829）列表与动态追加；`transform_request` 内部（2423/2436/2439/2505/2524/2546 换算偏移）；`transform_response`（3298）；`validate_environment`（common_utils 1549）；`BaseConfig`（base_llm/chat 91）；`get_complete_url` 默认实现（base_llm/chat 350）；URL 解析（main.py 3095-3106）；`anthropic_messages_pt`（factory 2976） | grep/sed/ast 实测并修正 6 处 | 通过 |
| 04-function-reference/08 | `Logging.__init__`（731）；`response_cost_calculator`（2093）与调用（2234/2296/2453）；`async_success_handler` 主体序（batch 短路/helper/0 成本/算钱，相对偏移实测）；`failure_handler`（4621/4826）；`completion_cost`（1764） | grep/sed 实测并修正 1 处 | 通过 |
| 04-function-reference/09 | `DBSpendUpdateWriter`（656）/`update_database`（682）内部（727/730/751/776 换算偏移）；防御函数（193/214/398/417）；`Cache`（caching.py 117）；`DualCache`（70）方法（140/208/251/517/1140）；`LLMCachingHandler`（270）；`UserApiKeyCache`（user_api_key_cache.py 38） | grep/sed 实测并修正 3 处 | 通过 |

## 已知修正（生成过程中发现并当场改正的事实错误）

1. **openai provider 的执行器**：初稿写 openai 也走 `BaseLLMHTTPHandler`，实测默认走 `OpenAIChatCompletion`（官方 SDK），httpx handler 仅在 `EXPERIMENTAL_OPENAI_BASE_LLM_HTTP_HANDLER` 开启时服务 openai。已修正第 2 层与第 1 层对应文档
2. **限流器类名**：初稿写 `ParallelRequestLimiterV3`，实际注册类是 `PROXY_MaxParallelRequestsHandler_v3`（hooks/__init__.py:24 导出）。已修正
3. **acompletion 执行方式**：初稿按惯例写成直接调 async handler，实测是把同步 `completion()` 丢进线程池（`run_in_executor`）。已如实记录
4. **AnthropicConfig 的 URL 方法**：初稿假设 `get_complete_url` 在 chat/transformation.py 内实现，实测不覆写、用 `BaseConfig` 默认实现，URL 在 `main.completion()` 的 anthropic 分支解析。已修正
5. **`common_processing_pre_call_logic` 返回顺序**：初稿写 `(logging_obj, data)`，实测返回 `self.data, logging_obj`（2712 行）。已修正

## 偏移换算规则备忘

文档统一 `+0` = 定义行本身，`+N` = 定义行向下第 N 行。文中形如「+0（NNNN 行处）」的括号行号是生成时快照，仅帮助定位，漂移以偏移语义为准。
