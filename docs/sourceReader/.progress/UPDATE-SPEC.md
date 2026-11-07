# sourceReader 更新规范（UPDATE-SPEC）

## 基准

- 文档基准提交：`3f4dc93b40`（2026-11-07 快照）。首次生成与 2026-11-07 规范化刷新均基于它，二者之间上游代码 **0 commit**
- 当前 HEAD 与基准的漂移检测：
  ```bash
  git rev-list --count 3f4dc93b40..HEAD
  ```
- 漂移 > 50 commit 或出现 god-file 拆分/模块搬家类合并时，按 skill 流程重估骨架；小漂移只修引用

## 定位记法（库内统一约定）

一律「文件路径 + 类/函数 + 相对偏移」，`+0` = 定义行，`+N` = 符号体内第 N 行：

```
litellm/proxy/proxy_server.py :: chat_completion() :: +31
litellm/proxy/common_request_processing.py :: ProxyBaseLLMRequestProcessing :: base_process_llm_request() :: +0
litellm/llms/base_llm/chat/transformation.py :: BaseConfig :: get_complete_url() :: +0
```

- 顶层函数/类省略中间段；模块级常量直接写常量名
- 库内使用 ` :: ` 分隔（skill 推荐的 ` · ` 是等价风格，**不要混用**，全库保持 ` :: `）
- **禁止**：`@行号` 写法，以及「文件名后跟冒号行号」的写法作为定位主引用；快照行号只允许出现在 VERIFY.md 的历史核对记录里且必须标注「生成时快照」
- 索引类表格只给「符号 → 文件」，不给行号

## 工具链

```bash
# 定位符号（两遍扫描：先 litellm/gateway/backend/enterprise/CLI 树，未命中再扫 tests/scripts）
python3 -I docs/sourceReader/.progress/sr_tools.py locate <SYM>...
# 文件骨架（省 token 的侦查入口）
python3 -I docs/sourceReader/.progress/sr_tools.py outline <FILE> [--top N]
# 取定义行号（换算函数内偏移用）
python3 -I docs/sourceReader/.progress/sr_tools.py offset <FILE> <SYM>
# 全库/单篇体检：@行号=0、疑似失效路径=0；--symbols 追加符号级校验
python3 -I docs/sourceReader/.progress/sr_tools.py verify docs/sourceReader/*.md --symbols
```

- `verify` 的 ✗ 桶要逐条判读：说明性引用（"已删除"等否定语境）、运行期配置名（`my-config.yaml`）、示例占位名是豁免档，不是错误
- `verify` 只查路径可解析性；`:: 引用` 的符号归属由 `--symbols` 查，偏移 `+N` 数值正确性仍需人工读代码
- 改完文档必跑：`verify docs/sourceReader/*.md --symbols`，四个计数必须归零（分类豁免除外）

## 文档格式红线

- 每篇头部保留「所属层级 | 阅读顺序/拆解对象」元信息行
- 函数级文档结构固定：引用规范块、职责/参数/返回值/前置/后置/核心算法/错误处理表
- 新增篇目必须同步进 README 目录索引；删除篇目必须清理 README 与其他文档的入链
- Mermaid 图与 ASCII 流程改动时，重新核对每条边的「调用方 → 被调用方」真实存在

## 已确认的架构事实（防重复侦查，勘误记录）

以下结论在基准提交上实测过（详见 VERIFY.md），后续更新可直接采信，推翻前先重测：

1. **openai provider 默认走官方 SDK**（`litellm/llms/openai/openai.py :: OpenAIChatCompletion`），不走 `BaseLLMHTTPHandler`；后者仅在 `EXPERIMENTAL_OPENAI_BASE_LLM_HTTP_HANDLER` 开启时服务 openai，其余大多数 provider 默认走它
2. **`main.acompletion` 把同步 `completion()` 丢进线程池**（`loop.run_in_executor`），除非显式传 `fallbacks`（此时走 `async_completion_with_fallbacks`）
3. **限流器注册类是 `PROXY_MaxParallelRequestsHandler_v3`**（`parallel_request_limiter_v3.py`，`hooks/__init__.py` 导出），模块内另有同名 v1/v2 类勿混淆
4. **Router 是薄门面**：`router.py`(212 行) → `make_core()` 选核心 → `router_python_core.py`(1.8 万行) 持有全部路由逻辑；核心不直接 import litellm，外部触达全走 `PythonHost.invoke()`
5. **AnthropicConfig 不覆写 `get_complete_url`**，URL 在 `main.completion()` 的 anthropic 分支解析（默认 `https://api.anthropic.com/v1/messages` + `ensure_api_route` 补后缀）
6. **`common_processing_pre_call_logic` 返回 `self.data, logging_obj`**（该顺序，非反序）
7. **gateway/ 与 backend/ 是复用 `proxy_server.app` 的路由裁剪入口**（数据面/管理面分离），不是独立服务
8. `ProxyException` 在 `litellm/proxy/_types.py`；`UserAPIKeyAuth` 在 `litellm/types/proxy/auth/user_api_key_auth.py`

## 更新流程（下次执行 source-doc-refresh 时）

1. 第 0 步量化漂移（commit 数、`verify` 计数、核心符号抽检），产出漂移报告
2. 让用户选深度（只修引用 / 骨架修补 / 全量重生成），不替用户决定
3. 若架构级变化（模块拆分/搬家），先更新本文件「已确认事实」清单，再派活
4. 收尾四零标准：`@行号`=0、疑似失效=0、断链=0、孤儿=0；更新 state.json 与 tasks.json
