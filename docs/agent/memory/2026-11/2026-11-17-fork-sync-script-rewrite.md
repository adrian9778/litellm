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
- 2026-11-17 19:25 前已交付用户最终汇总，TASK 标记为 complete，本轮不再追问。

---

# 2026-11-25 按 2026-11-25 版 skill 再次重写：弃 squash，改 merge/rebase 双模式

## 结论

`scripts/sync.sh` 推倒重写（241 行），对齐 `git-fork-sync-script` skill 的 **2026-11-25 版**方法论。核心变化：**彻底弃用 squash**。旧版走「`reset --hard main` → `merge --squash <backup>` → 单提交 → 强推」，会把工作分支的独有提交压没、重写历史，正是新版 skill 明令禁止的做法（skill：绝不用 squash）。新版工作分支对齐改为 **`SYNC_MODE` 双模式可切换（默认 merge）**：`merge` 用 `git merge main`（原提交 SHA 不变、不重写历史、普通推送、多一个 merge commit）；`rebase` 用 `git rebase main`（历史线性、SHA 重写、需 `--force-with-lease`）。两种模式都逐个保留独有提交。新增 `scripts/sync-fixture-test.sh`（203 行）离线 fixture 套件，**83 项断言全过（merge + rebase 各跑一遍）**。

## 依据

- 代码锚点：`scripts/sync.sh:19` `SYNC_MODE="${SYNC_MODE:-merge}"`；`:28-30` 非法 `SYNC_MODE` 校验（`die` 并提示变量名）；`:60,63` `stash push --include-untracked` 后立刻记 `STASH_SHA=$(git rev-parse 'stash@{0}')`；`:73` 还原时按 SHA 在 `git stash list --format='%H %gd'` 里定位具体 ref，`:79` `stash apply --index <ref>` 成功才 `drop`（**永不 `git stash clear`、绝不裸 `pop`**，坑 14：裸 pop 会误弹用户跑脚本前自己的 stash）；`:189` 工作分支对齐前的 `merge-base --is-ancestor` 早退（main 已包含在工作分支就跳过，幂等重跑不再重复 merge/push）；`:208-211` rebase 分支 `--force-with-lease`；`:215` merge 分支的 `--is-ancestor` 判断（已包含则不建 merge commit）；`:99` `DOCS_BRANCH_FINAL` 标志让失败恢复无论从哪个分支起步都停在工作分支 `adrian`。
- 失败恢复顺序（坑 9）：`trap restore_on_failure EXIT` → 先 `rebase --abort` / `merge --abort` 清冲突中间态 → `reset --hard <backup>` 把工作分支自动复原到同步前提交 → 最后才 `restore_one_stash`（按 SHA 只弹自己那条）。顺序错就弹不回来。
- fixture 套件：`bash scripts/sync-fixture-test.sh scripts/sync.sh`，两个 bare 仓当 upstream/fork，从 `deep/nested/dir` 子目录调用脚本顺带验证根定位，全程离线不碰真实远端。每场景独立子 shell + 独立 tmp 目录（早期版本复用同一 `$TMP` 导致克隆撞名、remote 已存在等假红）。覆盖：dry-run 零副作用、真实同步（merge 断言有 merge commit 且原 tip SHA 保留；rebase 断言 SHA 重写且无 merge commit）、幂等重跑（tree 逐字节一致）、既有用户 stash 不被误弹/误删、失败自动恢复、从第三分支起步仍停在工作分支、非法 `SYNC_MODE` 与空 `UPSTREAM_URL` 两个 die 分支。
- 真实仓库只读冒烟：从 `litellm/proxy` 子目录 `--dry-run`，退出码 0，识别出仓库根与 upstream remote，执行前后 HEAD/全部 refs/stash 数/remote 列表零变化。当前 `main` 落后 `upstream/main` 754 个提交，`adrian` 有 2 个独有提交。

## 本轮独有发现（测试器假信号，写下来避免复踩）

第一轮 26 个 FAIL、中途 12/8/4/3 个 FAIL，**逐一定责后全是测试器自己的 bug，脚本逻辑零改动**，与 skill 坑 11「套件全红先分清脚本 bug 还是测试器 bug」完全一致：

1. **rebase 场景全红 → 测试器没传 `SYNC_MODE`**。scenario 导出的是 `MODE="$mode"`，脚本读的是 `SYNC_MODE`，于是所有「rebase」场景其实跑的是 merge 模式，rebase 专属断言全部无意义。改成同时导出 `SYNC_MODE="$mode"`。
2. **`survivors` grep 基线不一致**。基线 `own_subjects` 含 `base` 提交，`survivors` 的 grep 只匹配 `own *`，两边永远不等 → 「own commits lost」恒 FAIL。统一成同一个 grep。
3. **`git stash list | grep -q "$SHA"` 恒失败**。plain `git stash list` 输出不含 SHA（是 `stash@{0}: On adrian: ...`），必须用 `--format='%H'`。直接打 SHA 才发现用户 stash 其实一直还在（脚本没碰它）。
4. **`rev-list --min-parents=2` 空输出假红**。无 merge commit 时它**输出空但退出码 0**，`check_not`（命令成功即 fail）误判成「有 merge commit」。改成 `wc -l` 显式比计数。
5. **`pre_unique` 未声明**。`S_SUCCESS` 里 `local pre_own pre_tip` 漏了 `pre_unique`，`set -u` 下引用未定义变量让整个 rebase 场景 rc=1 中断。
6. **复用同一 `$TMP` + 在被删目录里 cd**。早期所有场景共用一个 tmp 且测完 `rm -rf` 时 shell 还 cd 在里面，重跑报 `getcwd: cannot access parent directories` → rc=1 假红。改成每场景独立 tmp + 独立子 shell。

## 影响 / 遗留

- 用法：`bash scripts/sync.sh [--dry-run]`；`SYNC_MODE=merge|rebase`（默认 merge）；可在任意子目录运行；五个 remote/branch 变量 + `SYNC_MODE` 均可用同名环境变量覆盖。
- 默认工作分支 `DOCS_BRANCH=adrian`（当前工作分支），旧版默认的 `litellm_source_reader_docs` 分支仍在但不再是默认；换分支用 `DOCS_BRANCH=xxx`。
- 真实跑会在 fork（origin）上推 `main`（`--force-with-lease`，丢弃本地 main 相对上游的独有提交）与工作分支（merge 模式普通推、rebase 模式 `--force-with-lease`）。按铁律本轮**只在真实仓库跑 `--dry-run`**，未真实执行 push，是否跑由用户决定；跑前建议先 `--dry-run`。
- 幂等重跑：新增 `:189` 的 `--is-ancestor` 早退后，工作分支已包含 main 时重跑不再重复建 merge commit / 重复 push（fixture 有 tree 逐字节一致断言）。
- 测试脚本已入库：`scripts/sync-fixture-test.sh`（可复跑、离线、自带 fixture），不再只是 `/tmp` 临时件。
