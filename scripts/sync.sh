#!/usr/bin/env bash
set -euo pipefail

# 可配置项: 换项目只改这里(均可被同名环境变量覆盖); 用法: bash scripts/sync.sh [--dry-run]
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/berriai/litellm.git}"
MAIN_REMOTE="${MAIN_REMOTE:-origin}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"
DOCS_BRANCH="${DOCS_BRANCH:-adrian}"

DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run|-n) DRY_RUN=1 ;;
  *) printf '未知参数: %s (仅支持 --dry-run)\n' "$1" >&2; exit 1 ;;
esac

STASHED=0
BACKUP_BRANCH=""
START_BRANCH=""

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
    return
  fi
  log "\$ git stash push --include-untracked -m 'sync.sh auto-stash'"
  git stash push --include-untracked -m "sync.sh auto-stash $(date '+%F %T')"
  STASHED=1
}

restore_on_failure() {
  local rc=$?
  trap - EXIT
  git checkout -f "$START_BRANCH" >/dev/null 2>&1 || true
  git merge --abort >/dev/null 2>&1 || true
  if [[ -n "$BACKUP_BRANCH" ]] && git show-ref --verify -q "refs/heads/$BACKUP_BRANCH"; then
    if [[ "$(git branch --show-current)" == "$DOCS_BRANCH" ]]; then
      git reset --hard "$BACKUP_BRANCH" >/dev/null 2>&1 || true
    else
      git reset --hard >/dev/null 2>&1 || true
      git branch -f "$DOCS_BRANCH" "$BACKUP_BRANCH" >/dev/null 2>&1 || true
    fi
  else
    git reset --hard >/dev/null 2>&1 || true
  fi
  if (( STASHED )) && [[ -n "$(git stash list | head -1 || true)" ]]; then
    warn "中途失败(rc=$rc), 恢复现场与 stash 改动"
    if ! git stash pop; then
      warn "stash pop 仍有冲突, 改动仍保留在 stash, 请手动处理"
    fi
  fi
  if [[ -n "$BACKUP_BRANCH" ]]; then
    warn "$DOCS_BRANCH 已恢复为同步前状态, $BACKUP_BRANCH 保留作回滚锚点, 确认无误后 git branch -D $BACKUP_BRANCH"
  fi
  exit "$rc"
}

cleanup_backup() {
  if [[ -n "$BACKUP_BRANCH" ]] && git show-ref --verify -q "refs/heads/$BACKUP_BRANCH"; then
    run git branch -D "$BACKUP_BRANCH"
    BACKUP_BRANCH=""
  fi
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
  if ! git show-ref --verify -q "refs/heads/$DOCS_BRANCH"; then
    if git show-ref --verify -q "refs/remotes/$MAIN_REMOTE/$DOCS_BRANCH"; then
      log "本地无 $DOCS_BRANCH, $MAIN_REMOTE 上有, 建立跟踪分支"
      run git checkout -b "$DOCS_BRANCH" "$MAIN_REMOTE/$DOCS_BRANCH"
    else
      log "本地与 $MAIN_REMOTE 均无 $DOCS_BRANCH, 基于 $MAIN_BRANCH 新建并推送"
      run git checkout "$MAIN_BRANCH"
      run git checkout -b "$DOCS_BRANCH"
      run git push -u "$MAIN_REMOTE" "$DOCS_BRANCH"
    fi
    return
  fi
  run git checkout "$DOCS_BRANCH"
  if [[ "$(git rev-parse "$DOCS_BRANCH")" == "$(git rev-parse "$MAIN_BRANCH")" ]]; then
    log "$DOCS_BRANCH 已与 $MAIN_BRANCH 一致, 无需 squash"
    return
  fi

  local backup="${DOCS_BRANCH}-backup"
  run git branch -f "$backup" "$DOCS_BRANCH"
  if (( ! DRY_RUN )); then BACKUP_BRANCH="$backup"; fi

  local base net
  base="$(git merge-base "$DOCS_BRANCH" "$MAIN_BRANCH")"
  net="$(git diff --name-only "$base" "$DOCS_BRANCH")"
  if [[ -z "$net" ]]; then
    log "相对 $MAIN_BRANCH 净变更为空, 直接硬重置对齐"
    run git reset --hard "$MAIN_BRANCH"
    cleanup_backup
    return
  fi
  log "净变更 $(wc -l <<< "$net" | tr -d ' ') 个文件: $(echo "$net" | tr '\n' ' ')"
  run git reset --hard "$MAIN_BRANCH"
  run git merge --squash "$backup"
  run git commit -m "sync: squash $DOCS_BRANCH onto $MAIN_BRANCH"
  run git push --force-with-lease "$MAIN_REMOTE" "$DOCS_BRANCH"
  cleanup_backup
}

pop_stash_back() {
  if (( ! STASHED )); then return; fi
  if [[ -z "$(git stash list | head -1 || true)" ]]; then
    warn "预期有 stash 但列表为空, 跳过恢复"
    return
  fi
  git checkout "$START_BRANCH" >/dev/null 2>&1 || true
  log "恢复 stash 的工作区改动"
  if ! git stash pop; then
    warn "stash pop 有冲突, 改动仍保留在 stash, 请手动处理"
  fi
}

main() {
  cd_to_git_root
  START_BRANCH="$(git branch --show-current)"
  if [[ -z "$START_BRANCH" ]]; then die "detached HEAD, 先切到分支再同步"; fi
  log "仓库根: $(pwd)"
  log "当前分支: $START_BRANCH | upstream: $UPSTREAM_REMOTE | fork: $MAIN_REMOTE | main: $MAIN_BRANCH | 工作分支: $DOCS_BRANCH | dry-run: $DRY_RUN"
  trap restore_on_failure EXIT
  stash_workdir
  sync_main
  sync_work
  trap - EXIT
  pop_stash_back
  log "全部完成"
}

main "$@"
