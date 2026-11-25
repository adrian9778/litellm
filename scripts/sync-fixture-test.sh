#!/usr/bin/env bash
# Offline fixture suite for scripts/sync.sh (git-fork-sync-script skill §6).
# Counters live in files so subshell isolation can't lose them.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${1:?}")" && pwd)/$(basename "${1:?}")"
COUNTERS="$(mktemp -d /tmp/syncctr.XXXXXX)"
trap 'rm -rf "$COUNTERS"' EXIT
: > "$COUNTERS/ok"; : > "$COUNTERS/bad"
pass() { printf '  \033[1;32mPASS\033[0m %s\n' "$1"; echo x >> "$COUNTERS/ok"; }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; echo x >> "$COUNTERS/bad"; }
check()     { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
check_not() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$d"; else pass "$d"; fi; }
eq() { [[ "$1" == "$2" ]]; }

build_fixture() { # $1 = fresh root
  local root="$1"
  git init --bare -q "$root/up.git"
  git init --bare -q "$root/fork.git"
  git clone -q "$root/up.git" "$root/seed"
  git -C "$root/seed" config user.email s@t; git -C "$root/seed" config user.name s; git -C "$root/seed" config commit.gpgsign false
  mkdir -p "$root/seed/f"; echo base > "$root/seed/f/base.txt"
  git -C "$root/seed" add -A; git -C "$root/seed" commit -qm base
  git -C "$root/seed" push -q origin HEAD:refs/heads/main

  git clone -q "$root/up.git" "$root/work"
  git -C "$root/work" config user.email w@t; git -C "$root/work" config user.name w; git -C "$root/work" config commit.gpgsign false
  git -C "$root/work" config commit.gpgsign false
  git -C "$root/work" config pull.rebase false
  git -C "$root/work" remote rename origin upstream
  git -C "$root/work" remote set-url upstream "$root/up.git"
  git -C "$root/work" remote add origin "$root/fork.git"
  git -C "$root/work" push -q origin refs/remotes/upstream/main:refs/heads/main
  git -C "$root/work" checkout -q -b adrian
  mkdir -p "$root/work/f" "$root/work/deep/nested/dir"
  echo a > "$root/work/f/a.txt"; git -C "$root/work" add f/a.txt; git -C "$root/work" commit -qm "own 1"
  echo b > "$root/work/f/b.txt"; git -C "$root/work" add f/b.txt; git -C "$root/work" commit -qm "own 2"
  echo w > "$root/work/f/wip.txt"; git -C "$root/work" add f/wip.txt; git -C "$root/work" commit -qm "own wip"
  echo dirty > "$root/work/f/wip.txt"
  echo untracked > "$root/work/f/untracked.txt"
  git -C "$root/work" push -q -u origin adrian
}

advance_upstream() { # $1 = root
  git -C "$1/seed" checkout -q main
  echo u1 > "$1/seed/f/u1.txt"; git -C "$1/seed" add -A; git -C "$1/seed" commit -qm "up 1"
  echo u2 > "$1/seed/f/u2.txt"; git -C "$1/seed" add -A; git -C "$1/seed" commit -qm "up 2"
  git -C "$1/seed" push -q origin main
}

# adrian's OWN commits (exclude merge commits) as subjects, sorted.
# Must be the SAME set before and after alignment (upstream commits only enter via the merge parent,
# which --no-merges + the adrian-first-parent walk excludes... but adrian gains upstream commits after
# merge, so compare only the branch's own work: base + own N). Filter to the work-branch's own lines.
own_subjects() { git -C "$1/work" log --no-merges --format='%s' adrian | sort | grep -E '^(base|own )'; }
survivors() { own_subjects "$1"; }

scenario() { # scenario <name> <mode> <fn>
  local name="$1" mode="$2" fn="$3" root rc
  root="$(mktemp -d /tmp/syncfix.XXXXXX)"
  printf '\n\033[1;36m== %s [%s] ==\033[0m\n' "$name" "$mode"
  build_fixture "$root"
  (
    cd "$root/work"   # run from a subdirectory-capable stable cwd; script locates root itself
    export UPSTREAM_URL="$root/up.git" WROOT="$root" MODE="$mode" SYNC_MODE="$mode" SCRIPT_PATH="$SCRIPT"
    "$fn"
  ); rc=$?
  [[ $rc -ne 0 ]] && fail "$name [$mode] aborted rc=$rc"
  rm -rf "$root"
}

S_DRYRUN() {
  advance_upstream "$WROOT"
  local ph pr ps prm out rc
  ph="$(git -C "$WROOT/work" rev-parse HEAD)"
  pr="$(git -C "$WROOT/work" show-ref | sort)"
  ps="$(git -C "$WROOT/work" stash list | wc -l | tr -d ' ')"
  prm="$(git -C "$WROOT/work" remote | sort)"
  out="$(bash "$SCRIPT_PATH" --dry-run 2>&1)"; rc=$?
  [[ $rc -eq 0 ]] && pass "exit 0" || fail "exit 0 (rc=$rc)"
  eq "$(git -C "$WROOT/work" rev-parse HEAD)" "$ph" && pass "HEAD unchanged" || fail "HEAD changed"
  eq "$(git -C "$WROOT/work" show-ref | sort)" "$pr" && pass "refs unchanged" || fail "refs changed"
  eq "$(git -C "$WROOT/work" stash list | wc -l | tr -d ' ')" "$ps" && pass "stash count unchanged" || fail "stash changed"
  eq "$(git -C "$WROOT/work" remote | sort)" "$prm" && pass "remote list unchanged" || fail "remote changed"
  printf '%s' "$out" | grep -q '(dry-run)' && pass "marker shown" || fail "marker missing"
}

S_SUCCESS() {
  advance_upstream "$WROOT"
  local pre_own pre_tip pre_unique out rc
  pre_own="$(own_subjects "$WROOT")"
  pre_tip="$(git -C "$WROOT/work" rev-parse adrian)"
  pre_unique="$(git -C "$WROOT/work" rev-list --count main..adrian)"
  out="$(bash "$SCRIPT_PATH" 2>&1)"; rc=$?
  [[ $rc -eq 0 ]] && pass "exit 0" || { fail "exit 0 (rc=$rc)"; printf '%s\n' "$out"; return; }
  eq "$(git -C "$WROOT/work" rev-parse main)" "$(git -C "$WROOT/work" rev-parse upstream/main)" && pass "main == upstream/main" || fail "main not aligned"
  eq "$(git -C "$WROOT/work" merge-base adrian main)" "$(git -C "$WROOT/work" rev-parse main)" && pass "adrian aligned onto main" || fail "adrian not aligned"
  eq "$(survivors "$WROOT")" "$pre_own" && pass "all own commits survived" || fail "own commits lost"
  printf '%s' "$out" | grep -qi 'squash' && fail "no squash" || pass "no squash"
  if [[ "$MODE" == merge ]]; then
    eq "$(git -C "$WROOT/work" rev-parse adrian^2)" "$(git -C "$WROOT/work" rev-parse main)" && pass "merge commit present (main is 2nd parent)" || fail "no merge commit"
    git -C "$WROOT/work" merge-base --is-ancestor "$pre_tip" adrian && pass "original tip SHA preserved" || fail "tip SHA rewritten in merge"
  else
    git -C "$WROOT/work" merge-base --is-ancestor "$pre_tip" adrian && fail "rebase kept old SHA" || pass "rebase rewrote SHA (expected)"
    local nmerge; nmerge="$(git -C "$WROOT/work" rev-list --min-parents=2 adrian | wc -l | tr -d ' ')"
    eq "$nmerge" "0" && pass "linear (no merge commit after rebase)" || fail "linear (found $nmerge merge commits)"
    eq "$(git -C "$WROOT/work" rev-list --count main..adrian)" "$pre_unique" && pass "rebase replayed own commits onto main" || fail "rebase commit count off"
  fi
  eq "$(git -C "$WROOT/fork.git" rev-parse adrian)" "$(git -C "$WROOT/work" rev-parse adrian)" && pass "fork adrian matches" || fail "fork adrian mismatch"
  eq "$(git -C "$WROOT/fork.git" rev-parse main)" "$(git -C "$WROOT/work" rev-parse main)" && pass "fork main matches" || fail "fork main mismatch"
  git -C "$WROOT/work" status --porcelain | grep -q ' f/wip.txt' && pass "WIP restored" || fail "WIP not restored"
  [[ -f "$WROOT/work/f/untracked.txt" ]] && pass "untracked restored" || fail "untracked lost"
  eq "$(git -C "$WROOT/work" stash list | wc -l | tr -d ' ')" "0" && pass "stash cleared" || fail "stash left"
  check_not "backup cleaned" git -C "$WROOT/work" show-ref --verify -q refs/heads/adrian-backup
  eq "$(git -C "$WROOT/work" branch --show-current)" "adrian" && pass "ends on adrian" || fail "ends on $(git -C "$WROOT/work" branch --show-current)"

  local tree0 out2 rc2
  tree0="$(git -C "$WROOT/work" rev-parse adrian^{tree})"
  out2="$(bash "$SCRIPT_PATH" 2>&1)"; rc2=$?
  [[ $rc2 -eq 0 ]] && pass "rerun exit 0" || { fail "rerun exit 0 (rc=$rc2)"; printf '%s\n' "$out2"; }
  eq "$(survivors "$WROOT")" "$pre_own" && pass "rerun own commits intact" || fail "rerun lost commits"
  eq "$(git -C "$WROOT/work" rev-parse adrian^{tree})" "$tree0" && pass "rerun tree identical" || fail "rerun tree differs"
  check_not "rerun no backup" git -C "$WROOT/work" show-ref --verify -q refs/heads/adrian-backup
}

S_USERSTASH() {
  advance_upstream "$WROOT"
  echo secret > "$WROOT/work/f/user.txt"
  git -C "$WROOT/work" add f/user.txt
  git -C "$WROOT/work" stash push -q -m "user own"
  local usha out rc
  usha="$(git -C "$WROOT/work" rev-parse 'stash@{0}')"
  out="$(bash "$SCRIPT_PATH" 2>&1)"; rc=$?
  [[ $rc -eq 0 ]] && pass "exit 0" || { fail "exit 0 (rc=$rc)"; printf '%s\n' "$out"; return; }
  git -C "$WROOT/work" stash list --format='%H' | grep -q "$usha" && pass "user own stash still in stack" || fail "user own stash popped/deleted"
  [[ ! -f "$WROOT/work/f/user.txt" ]] && pass "user stash content not applied" || fail "user stash wrongly applied"
  eq "$(git -C "$WROOT/work" stash list | wc -l | tr -d ' ')" "1" && pass "no script stash left (only user's)" || fail "unexpected stash count"
}

S_FAILURE() {
  advance_upstream "$WROOT"
  # Keep local adrian == origin/adrian (move BOTH to the same new commit) so the divergence
  # pre-check passes and the conflict happens at the real merge/rebase step.
  git -C "$WROOT/work" checkout -q adrian
  echo localversion > "$WROOT/work/f/a.txt"
  git -C "$WROOT/work" add f/a.txt; git -C "$WROOT/work" commit -qm "own conflicts on a.txt"
  git -C "$WROOT/work" push -q origin adrian
  # main gets a conflicting change to the same file
  git -C "$WROOT/seed" checkout -q main
  echo upstreamversion > "$WROOT/seed/f/a.txt"
  git -C "$WROOT/seed" add -A; git -C "$WROOT/seed" commit -qm "up conflicts on a.txt"
  git -C "$WROOT/seed" push -q origin main
  git -C "$WROOT/work" fetch -q origin
  local pre out rc
  pre="$(git -C "$WROOT/work" rev-parse adrian)"
  out="$(bash "$SCRIPT_PATH" 2>&1)"; rc=$?
  [[ $rc -ne 0 ]] && pass "conflict exits non-zero" || fail "conflict should fail (rc=0)"
  eq "$(git -C "$WROOT/work" rev-parse main)" "$(git -C "$WROOT/work" rev-parse upstream/main)" && pass "main still aligned" || fail "main not aligned"
  git -C "$WROOT/work" show-ref --verify -q refs/heads/adrian-backup && pass "backup kept as rollback anchor" || fail "backup missing"
  eq "$(git -C "$WROOT/work" rev-parse adrian)" "$pre" && pass "adrian restored to pre-sync commit" || fail "adrian not restored"
  eq "$(git -C "$WROOT/work" branch --show-current)" "adrian" && pass "ends on adrian" || fail "ends on $(git -C "$WROOT/work" branch --show-current)"
  check_not "no MERGE_HEAD residue" git -C "$WROOT/work" rev-parse -q --verify MERGE_HEAD
  check_not "no rebase-in-progress residue" git -C "$WROOT/work" rev-parse -q --verify rebase-merge
  printf '%s' "$out" | grep -qE '恢复|backup|adrian' && pass "recovery message shown" || fail "no recovery message"
}

S_FROMFEATURE() {
  advance_upstream "$WROOT"
  git -C "$WROOT/work" checkout -q -b feature
  local out rc
  out="$(bash "$SCRIPT_PATH" 2>&1)"; rc=$?
  [[ $rc -eq 0 ]] && pass "exit 0" || fail "exit 0 (rc=$rc)"
  eq "$(git -C "$WROOT/work" branch --show-current)" "adrian" && pass "ends on adrian" || fail "ends on $(git -C "$WROOT/work" branch --show-current)"
  git -C "$WROOT/work" show-ref --verify -q refs/heads/feature && pass "feature branch kept" || fail "feature deleted"
}

S_DIEURL() {
  advance_upstream "$WROOT"
  local n out rc
  n="$WROOT/nourl.sh"
  sed 's#^UPSTREAM_URL=.*#UPSTREAM_URL=""#' "$SCRIPT_PATH" > "$n"
  out="$(UPSTREAM_REMOTE=absentremote bash "$n" 2>&1)"; rc=$?
  [[ $rc -ne 0 ]] && pass "empty URL exits non-zero" || fail "empty URL rc=0"
  printf '%s' "$out" | grep -q 'UPSTREAM_URL\|上游地址' && pass "names UPSTREAM_URL" || fail "no var name"
}

for mode in merge rebase; do
  scenario "dry-run zero side effects" "$mode" S_DRYRUN
  scenario "real sync success"         "$mode" S_SUCCESS
  scenario "pre-existing user stash"   "$mode" S_USERSTASH
  scenario "failure auto-recovery"     "$mode" S_FAILURE
  scenario "from third branch"         "$mode" S_FROMFEATURE
done
scenario "die: empty upstream URL" merge S_DIEURL

printf '\n\033[1;36m== die: illegal SYNC_MODE ==\033[0m\n'
out="$(SYNC_MODE=bogus bash "$SCRIPT" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && pass "illegal SYNC_MODE exits non-zero" || fail "illegal SYNC_MODE rc=0"
printf '%s' "$out" | grep -q 'SYNC_MODE' && pass "names SYNC_MODE" || fail "no var name"

okc="$(wc -l < "$COUNTERS/ok" | tr -d ' ')"; badc="$(wc -l < "$COUNTERS/bad" | tr -d ' ')"
printf '\n\033[1;36m==== result: %d passed, %d failed ====\033[0m\n' "$okc" "$badc"
[[ "$badc" -eq 0 ]]
