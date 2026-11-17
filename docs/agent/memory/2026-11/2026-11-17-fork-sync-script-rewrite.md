# scripts/sync.sh 按 git-fork-sync-script skill 重写

## 结论

`scripts/sync.sh`（185 行）按 skill 设计整体重写：先 stash 含未跟踪的全部未提交改动并挂 `trap restore_on_failure EXIT`，`main` 以 `reset --hard upstream/main` 严格对齐上游后 `--force-with-lease` 推 fork，工作分支 `litellm_source_reader_docs` 走「`branch -f <work>-backup` → `reset --hard main` → `merge --squash <backup>` → 单提交 → `--force-with-lease` 强推」，成功自动删 backup、失败保留 backup 并把工作分支恢复到同步前状态后原样弹回 stash。`--dry-run` 下所有改状态命令只打印不执行。旧脚本（含 docs 分支专用的 sr_tools verify、legacy seeding 逻辑）与当时未提交 WIP 已备份到 `/tmp/sync-sh-backup-20261117/`。真实推送未执行，等用户决定。

## 依据

- 代码锚点（重写后）：`scripts/sync.sh:5-9` 五个环境变量可覆盖的配置（`UPSTREAM_REMOTE=upstream`、`UPSTREAM_URL=https://github.com/berriai/litellm.git`、`MAIN_REMOTE=origin`、`MAIN_BRANCH=main`、`DOCS_BRANCH=litellm_source_reader_docs`）；`:32` `git rev-parse --show-toplevel` 自动定位仓库根；`:43` `stash push --include-untracked`；`:48-70` 失败恢复 trap（先 `checkout -f $START_BRANCH` + `merge --abort` 清掉 squash 冲突中间态，再 `reset --hard` 回 backup，最后 `stash pop`，顺序错就弹不回来）；`:98,114,153` 三处推送全部 `--force-with-lease`；`:145-151` 工作分支 squash 三步（skill 指定，规避 add/add 冲突）；`:176` trap 挂载点在 stash 之前。
- 实测（临时目录 fixture，三 bare 仓 upstream/fork + seed + work 克隆，从 `deep/nested/dir` 子目录运行）：42 项断言全过（PASS=42 FAIL=0），覆盖 6 组场景——dry-run 零副作用（refs/stash/remotes 前后哈希一致）、真实同步（main 严格等于 upstream/main、adrian 为 main 顶单提交、净变更 patch 与同步前逐字节一致、中间态文件未进 squash 提交、WIP 与未跟踪文件弹回）、幂等重跑、无 upstream remote 场景（dry-run 只打印不真加）、失败自动恢复（上游改同一行制造 squash 冲突：退出码非 0、backup 保留且指向同步前提交、工作分支自动复原、WIP 弹回、无 MERGE_HEAD 残留）。
- 实测（真实仓库只读冒烟）：`cd docs && bash ../scripts/sync.sh --dry-run` 退出码 0，识别出仓库根 `/Users/vincent/workspace/16_AI/litellm` 与 upstream remote，净变更列出 34 个文件（sourceReader 文档 + scripts/sync.sh 本身），执行前后 HEAD/全部 refs/stash 数量/remote 列表零变化。
- 备份：旧脚本 `/tmp/sync-sh-backup-20261117/sync.sh.old`（3906 字节）+ 当时未提交 WIP diff `/tmp/sync-sh-backup-20261117/sync.sh.worktree.diff`（3116 字节，含 sr_tools verify 与 legacy seeding 逻辑）。
- 测试脚本（临时件，可复跑）：`/tmp/forksync-test/run.sh <sync.sh 绝对路径>`，自带 fixture 生成，不依赖真实网络。
- 排查结论（写下来避免复踩）：第一轮测试 11 个 FAIL 全是测试器自己的 bug，不是脚本 bug——`run_sync` 的 dry 标志写成 `${dry:+--dry-run}` 把 `0` 也当真；`git remote | grep -qx upstream` 在 fixture 本来就有 upstream 时恒真，应比对 remote 列表前后不变；skill 规定的 `${VAR:-默认}` 语义下显式传空串会回退到内置默认 URL，所以「空 URL 报错」只能对默认 URL 置空的模板副本验证（副本实测退出码非 0 且提示 UPSTREAM_URL）。

## 影响 / 遗留

- 用法：`bash scripts/sync.sh [--dry-run]`，可在任意子目录运行；环境变量可覆盖五个默认值（如换工作分支 `DOCS_BRANCH=xxx`）。
- 真实跑会在 fork（origin）上强推 `main` 与 `litellm_source_reader_docs`，并丢弃本地 main 相对上游的全部独有提交（脚本会先警告并提示 reflog 找回）。按铁律未在 litellm 仓库真实执行，是否跑由用户决定；跑前建议先 `--dry-run` 看一遍净变更清单。
- 失败路径若 `stash pop` 仍有冲突，改动会保留在 stash 里等手工处理（脚本有明示提示），不会丢。
- 旧脚本里的 sr_tools verify、legacy seeding 逻辑随重写移除，已留在 `/tmp/sync-sh-backup-20261117/` 备份与 WIP diff 中，需要时可回捞。
- 用户级 skill `git-fork-sync-script` 已按本轮实测结论更新（2026-11-17，真源 250 行）：修正 §2 骨架 `restore_on_failure`（原骨架直接 pop stash、不复原工作分支，即上述冲突弹不回的坑）与 `sync_main`/`sync_work`（补 dry-run 短路与分支缺失 fallback，原骨架注释与代码矛盾）；新增坑 9（失败恢复顺序）、坑 10（`${VAR:-}` 空串语义与 die 分支测法）、坑 11（fixture 测试器五类假信号 + 定责纪律）与 §6 fixture 测试方法；已同步 5 个镜像根与 `202 BAK/skills/01-工程流程与文档/git-fork-sync-script.md` 快照，diff 校验一致。
