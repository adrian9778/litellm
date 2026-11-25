#!/usr/bin/env bash
set -euo pipefail

# 把 fork 的 main 严格对齐上游 upstream/main, 再把工作分支对齐到最新 main, 保留其独有提交。
# 用法: bash scripts/sync.sh [--dry-run]
#
# SYNC_MODE 两种取值:
#   merge  (默认) git merge main  → 原提交 SHA 不变、不重写历史、普通推送; 多一个 merge commit
#   rebase        git rebase main → 历史线性; 但 SHA 重写、需 --force-with-lease
# 两种都不丢工作分支的独有提交。绝不用 squash(会把独有提交压没)。
#
# 安全边界: 上游只读、从不 push; 所有写操作只落自己的 fork; main 严格等于上游; 工作分支的处理只在 $DOCS_BRANCH 上做。

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/berriai/litellm.git}"
MAIN_REMOTE="${MAIN_REMOTE:-origin}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"
DOCS_BRANCH="${DOCS_BRANCH:-adrian}"
SYNC_MODE="${SYNC_MODE:-merge}"

DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run|-n) DRY_RUN=1 ;;
  *) printf '未知参数: %s (仅支持 --dry-run)\n' "$1" >&2; exit 1 ;;
esac

case "$SYNC_MODE" in
  merge|rebase) ;;
  *) printf '非法 SYNC_MODE: %s (仅支持 merge | rebase)\n' "$SYNC_MODE" >&2; exit 1 ;;
esac

STASHED=0
STASH_SHA=""
BACKUP_BRANCH=""
DOCS_BRANCH_FINAL=0

log()  { printf '\033[1;34m[sync]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[sync]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[sync]\033[0m %s\n' "$*" >&2; exit 1; }

run() {
  if (( DRY_RUN )); then log "(dry-run) $*"; else log "\$ $*"; "$@"; fi
}

cd_to_git_root() {
  local toplevel
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || die "不在 git 仓库里"
  cd "$toplevel"
}

stash_workdir() {
  if [[ -z "$(git status --porcelain)" ]]; then STASHED=0; return; fi
  if (( DRY_RUN )); then
    log "(dry-run) git stash push --include-untracked (真跑时未提交改动会先收进 stash)"
    STASHED=0
    return
  fi
  local out
  out="$(git stash push --include-untracked -m "sync.sh auto-stash $(date '+%F %T')")" || die "stash 失败"
  log "$out"
  STASHED=1
  STASH_SHA="$(git rev-parse 'stash@{0}' 2>/dev/null || true)"
}

restore_one_stash() {
  if (( ! STASHED )); then return; fi
  if [[ -z "$STASH_SHA" ]]; then
    warn "未记录到本次 stash 的 SHA, 跳过自动还原, 请手动 git stash list 检查"
    return
  fi
  local match
  match="$(git stash list --format='%H %gd' | awk -v s="$STASH_SHA" '$1==s{print $2; exit}')"
  if [[ -z "$match" ]]; then
    warn "本次 stash 已不在栈中, 跳过还原"
    STASHED=0
    return
  fi
  if git stash apply --index "$match"; then
    git stash drop "$match" >/dev/null 2>&1 || true
    STASHED=0
  else
    warn "stash 还原有冲突, 本次改动仍完整保留在 $match, 请手动处理(不要 git stash clear)"
  fi
}

cleanup_backup() {
  if [[ -n "$BACKUP_BRANCH" ]] && git show-ref --verify -q "refs/heads/$BACKUP_BRANCH"; then
    run git branch -D "$BACKUP_BRANCH"
  fi
  BACKUP_BRANCH=""
}

restore_on_failure() {
  local rc=$?
  trap - EXIT
  git rebase --abort >/dev/null 2>&1 || true
  git merge --abort >/dev/null 2>&1 || true
  if (( DOCS_BRANCH_FINAL )) || [[ "$(git branch --show-current)" == "$DOCS_BRANCH" ]]; then
    git checkout -f "$DOCS_BRANCH" >/dev/null 2>&1 || true
  fi
  if [[ -n "$BACKUP_BRANCH" ]] && git show-ref --verify -q "refs/heads/$BACKUP_BRANCH"; then
    if [[ "$(git branch --show-current)" == "$DOCS_BRANCH" ]]; then
      git reset --hard "$BACKUP_BRANCH" >/dev/null 2>&1 || true
    else
      git reset --hard >/dev/null 2>&1 || true
      git branch -f "$DOCS_BRANCH" "$BACKUP_BRANCH" >/dev/null 2>&1 || true
      git checkout -f "$DOCS_BRANCH" >/dev/null 2>&1 || true
    fi
  else
    git reset --hard >/dev/null 2>&1 || true
  fi
  if (( STASHED )); then
    warn "中途失败(rc=$rc), 恢复现场与 stash 改动"
    restore_one_stash
  fi
  if [[ -n "$BACKUP_BRANCH" ]]; then
    warn "$DOCS_BRANCH 已恢复为同步前状态, $BACKUP_BRANCH 保留作回滚锚点, 确认无误后 git branch -D $BACKUP_BRANCH"
  fi
  warn "结束, 停在工作分支 $DOCS_BRANCH"
  exit "$rc"
}

cleanup_backup_and_finish() {
  cleanup_backup
  restore_one_stash
  log "结束, 停在工作分支 $DOCS_BRANCH"
}

ensure_upstream_remote() {
  if git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
    log "remote '$UPSTREAM_REMOTE' 已存在: $(git remote get-url "$UPSTREAM_REMOTE")"
    return
  fi
  if [[ -z "$UPSTREAM_URL" ]]; then
    die "未配置 remote '$UPSTREAM_REMOTE' 且 UPSTREAM_URL 为空, 请在脚本顶部或环境变量里给出上游地址"
  fi
  run git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
}

sync_main() {
  ensure_upstream_remote
  run git fetch "$UPSTREAM_REMOTE" --prune
  run git fetch "$MAIN_REMOTE" --prune
  if (( DRY_RUN )); then
    log "(dry-run) 跳过 main 与上游比对/硬重置(需要真实 fetch 后的新 ref)"
    run git push --force-with-lease "$MAIN_REMOTE" "$MAIN_BRANCH"
    return
  fi
  local local_main upstream_main ahead
  local_main="$(git rev-parse --verify "$MAIN_BRANCH")" || die "本地没有分支 $MAIN_BRANCH"
  upstream_main="$(git rev-parse --verify "$UPSTREAM_REMOTE/$MAIN_BRANCH")" || die "上游没有分支 $MAIN_BRANCH"
  if [[ "$local_main" == "$upstream_main" ]]; then
    log "$MAIN_BRANCH 已与上游一致"
  else
    ahead="$(git rev-list --count "$upstream_main..$local_main")"
    if (( ahead > 0 )); then
      warn "本地 $MAIN_BRANCH 有 $ahead 个 fork 独有提交, 将被 reset --hard 丢弃(可用 reflog 找回)"
    fi
    run git checkout "$MAIN_BRANCH"
    run git reset --hard "$UPSTREAM_REMOTE/$MAIN_BRANCH"
  fi
  run git push --force-with-lease "$MAIN_REMOTE" "$MAIN_BRANCH"
}

sync_work() {
  DOCS_BRANCH_FINAL=1
  if ! git show-ref --verify -q "refs/heads/$DOCS_BRANCH"; then
    if git ls-remote --exit-code --heads "$MAIN_REMOTE" "$DOCS_BRANCH" >/dev/null 2>&1; then
      run git checkout -b "$DOCS_BRANCH" "$MAIN_REMOTE/$DOCS_BRANCH"
    else
      run git checkout -b "$DOCS_BRANCH"
      run git push -u "$MAIN_REMOTE" "$DOCS_BRANCH"
    fi
    return
  fi
  run git checkout "$DOCS_BRANCH"
  run git fetch "$MAIN_REMOTE" --prune
  if git ls-remote --exit-code --heads "$MAIN_REMOTE" "$DOCS_BRANCH" >/dev/null 2>&1; then
    [[ "$(git rev-parse "$DOCS_BRANCH")" == "$(git rev-parse "$MAIN_REMOTE/$DOCS_BRANCH")" ]] \
      || die "本地 $DOCS_BRANCH 与 $MAIN_REMOTE/$DOCS_BRANCH 不一致, 先手动处理再同步"
  else
    run git push -u "$MAIN_REMOTE" "$DOCS_BRANCH"
  fi
  if (( DRY_RUN )); then
    log "(dry-run) 跳过 $DOCS_BRANCH 与 $MAIN_BRANCH 的对齐(需要真实 fetch 后的新 ref)"
    return
  fi
  if git merge-base --is-ancestor "$MAIN_BRANCH" "$DOCS_BRANCH"; then
    log "$MAIN_BRANCH 已包含在 $DOCS_BRANCH 中, 无需对齐"
    return
  fi
  [[ "$(git rev-parse "$MAIN_REMOTE/$DOCS_BRANCH")" == "$(git rev-parse "$MAIN_BRANCH")" ]] && { log "$DOCS_BRANCH 已与 $MAIN_BRANCH 一致"; return; }

  local backup="${DOCS_BRANCH}-backup"
  run git branch -f "$backup" "$DOCS_BRANCH"
  BACKUP_BRANCH="$backup"
  local base unique
  base="$(git merge-base "$DOCS_BRANCH" "$MAIN_BRANCH")"
  unique="$(git rev-list --count "$base..$DOCS_BRANCH")"
  if [[ "$unique" -eq 0 ]]; then
    log "无独有提交, 快进到 $MAIN_BRANCH"
    run git reset --hard "$MAIN_BRANCH"
    cleanup_backup
    return
  fi

  if [[ "$SYNC_MODE" == "rebase" ]]; then
    log "$DOCS_BRANCH 有 $unique 个独有提交, [rebase] 重放到 $MAIN_BRANCH 之后(逐个保留, 历史重写, 需强推)"
    run git rebase "$MAIN_BRANCH"
    run git push --force-with-lease "$MAIN_REMOTE" "$DOCS_BRANCH"
    run git reset --hard "$MAIN_REMOTE/$DOCS_BRANCH"
  else
    log "$DOCS_BRANCH 有 $unique 个独有提交, [merge] 把 $MAIN_BRANCH 合并进来(原提交 SHA 不变, 不重写历史, 普通推送)"
    if git merge-base --is-ancestor "$MAIN_BRANCH" "$DOCS_BRANCH"; then
      log "$MAIN_BRANCH 已包含在 $DOCS_BRANCH 中, 无需合并"
    else
      run git merge "$MAIN_BRANCH" --no-edit -m "merge: 同步 $MAIN_BRANCH 到 $DOCS_BRANCH"
    fi
    run git push "$MAIN_REMOTE" "$DOCS_BRANCH"
  fi
  cleanup_backup
}

main() {
  cd_to_git_root
  local start_branch
  start_branch="$(git branch --show-current)"
  if [[ -z "$start_branch" ]]; then die "detached HEAD, 先切到分支再同步"; fi
  log "仓库根: $(pwd)"
  log "当前分支: $start_branch | upstream: $UPSTREAM_REMOTE | fork: $MAIN_REMOTE | main: $MAIN_BRANCH | 工作分支: $DOCS_BRANCH | 模式: $SYNC_MODE | dry-run: $DRY_RUN"
  trap restore_on_failure EXIT
  stash_workdir
  sync_main
  sync_work
  trap - EXIT
  cleanup_backup_and_finish
  log "全部完成"
}

main "$@"
