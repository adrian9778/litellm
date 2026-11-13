#!/usr/bin/env bash
# 把 litellm fork 的 main 同步到上游最新，并把 docs/sourceReader 文档分支
# 同步到最新上游 + 本地文档提交，最后推送到 origin。
#
# 用法: bash sync-fork-and-docs.sh
# 依赖: 已配置 remote origin (fork) 与 upstream (https://github.com/berriai/litellm.git)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

DOC_BRANCH="litellm_source_reader_docs"
DOC_DIR="docs/sourceReader"

step() { printf '\n=== [%s] %s ===\n' "$1" "$2"; }

step "1" "拉取 origin 与 upstream 的最新引用"
git fetch origin
git fetch upstream main
git fetch --all --prune

step "2" "把本地 main fast-forward 到上游最新"
# main 是上游的祖先链，纯前进，绝不 force-with-lease
git checkout main
git merge --ff-only upstream/main

step "3" "把 main 推到 origin（fast-forward，不 force）"
if git merge-base --is-ancestor origin/main main; then
    git push origin main
else
    echo "!! origin/main 不是本地 main 的祖先，拒绝 force 推送；请先人工确认" >&2
    exit 1
fi

step "4" "把文档分支 rebase 到最新上游"
git checkout "$DOC_BRANCH"
git rebase upstream/main

step "5" "全库校验文档引用（verify --symbols 必须 0 硬伤）"
python3 -I "$DOC_DIR/.progress/sr_tools.py" \
    verify "$DOC_DIR"/*.md "$DOC_DIR"/*/*.md --symbols

step "6" "提交并推送文档分支"
git add "$DOC_DIR"
git commit -m "docs(sourceReader): sync to upstream latest" || true
git push --force-with-lease origin "$DOC_BRANCH"

step "完成"
echo "origin/main         = $(git rev-parse origin/main)"
echo "upstream/main       = $(git rev-parse upstream/main)"
echo "doc branch tip      = $(git rev-parse "$DOC_BRANCH")"
echo "工作区脏文件数      = $(git status --porcelain | wc -l | tr -d ' ')"
