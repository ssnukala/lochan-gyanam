#!/usr/bin/env bash
# test-deploy-sync-fail-loud.sh — regression tests for scripts/deploy-lochan.sh
# clone_or_pull() fail-loud sync (§D.BUILD-CACHE, 2026-07-03).
#
# THE INCIDENT THIS GUARDS: the old `git pull --ff-only || warn "leaving
# as-is"` silently CONTINUED on the pre-pull commit whenever the pull couldn't
# fast-forward — the deploy then built base images from STALE source that
# cache-hit "clean" (#1621 never landed on the server; 3 deploy failures on old
# code until a forced no-cache rebuild). The fix fails loud (DEPLOY_FAILED=1 +
# return 1) so the post-Phase-1 gate aborts BEFORE building on stale source.
#
# Self-contained: builds throwaway bare "remotes" + local clones under mktemp,
# extracts the REAL clone_or_pull from the deploy script (so the test tracks the
# live implementation, not a copy), and asserts return code + DEPLOY_FAILED for
# every behavior class:
#   1. up-to-date clone         → return 0, DEPLOY_FAILED stays 0 ("already at")
#   2. behind, fast-forwardable → return 0, advances (before → after)
#   3. DIVERGED (non-ff)        → return 1, DEPLOY_FAILED=1  (THE incident)
#   4. dirty tree blocks ff     → return 1, DEPLOY_FAILED=1
#   5. path exists, not a repo  → return 1, DEPLOY_FAILED=1
#
# Run: bash util/scripts/test-deploy-sync-fail-loud.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$SCRIPT_DIR/../../scripts/deploy-lochan.sh"
[[ -f "$DEPLOY" ]] || { echo "FAIL: deploy script not found at $DEPLOY" >&2; exit 1; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0; FAIL=0
ok()   { echo "  [✓] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [✗] $1" >&2; FAIL=$((FAIL+1)); }

# ── Harness: extract the REAL clone_or_pull() from the deploy script ──────────
# We source ONLY the function (awk-slice from its `clone_or_pull() {` to the
# matching close), with stub log/warn/err + a settable GYANAM_DIR + DEPLOY_FAILED
# so the function runs in isolation exactly as it does mid-deploy.
FUNC_FILE="$ROOT/clone_or_pull.sh"
awk '/^clone_or_pull\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DEPLOY" > "$FUNC_FILE"
grep -q 'DEPLOY_FAILED=1' "$FUNC_FILE" || { echo "FAIL: extracted function missing fail-loud (script drifted?)" >&2; exit 1; }

log()  { :; }
warn() { :; }
err()  { :; }
# shellcheck disable=SC1090
source "$FUNC_FILE"

# ── Fixture builders ─────────────────────────────────────────────────────────
make_remote() {  # $1=name → echoes bare remote path with one initial commit
  local name="$1"
  local remote="$ROOT/$name.git"
  local work="$ROOT/seed-$name"
  git init --quiet --bare "$remote"
  git clone --quiet "$remote" "$work" 2>/dev/null
  ( cd "$work"; git config user.email t@t; git config user.name t; \
    echo v1 > f.txt; git add f.txt; git commit --quiet -m init; \
    git push --quiet origin HEAD:refs/heads/main >/dev/null 2>&1 )
  echo "$remote"
}
advance_remote() {  # $1=remote → add a new commit on main (so a clone is "behind")
  local remote="$1"
  local work="$ROOT/adv-$$-$RANDOM"
  git clone --quiet "$remote" "$work" 2>/dev/null
  ( cd "$work"; git config user.email t@t; git config user.name t; \
    echo v2 >> f.txt; git add f.txt; git commit --quiet -m advance; \
    git push --quiet origin HEAD:main >/dev/null 2>&1 )
  rm -rf "$work"
}

run_case() {  # $1=path-under-GYANAM_DIR $2=url → runs clone_or_pull, sets RC/DF
  DEPLOY_FAILED=0
  set +e
  clone_or_pull "$1" "$2" >/dev/null 2>&1
  RC=$?
  set -e
  DF=$DEPLOY_FAILED
}

# ── Case 1: up-to-date clone → return 0, DEPLOY_FAILED 0 ──────────────────────
GYANAM_DIR="$ROOT/ws1"; mkdir -p "$GYANAM_DIR"
R=$(make_remote r1)
git clone --quiet "$R" "$GYANAM_DIR/repo" 2>/dev/null
( cd "$GYANAM_DIR/repo"; git branch --set-upstream-to=origin/main --quiet 2>/dev/null || true )
run_case repo "$R"
{ [[ $RC -eq 0 && $DF -eq 0 ]] && ok "up-to-date → rc=0, DEPLOY_FAILED=0"; } || bad "up-to-date: rc=$RC df=$DF (want 0/0)"

# ── Case 2: behind but fast-forwardable → return 0, advances ──────────────────
GYANAM_DIR="$ROOT/ws2"; mkdir -p "$GYANAM_DIR"
R=$(make_remote r2)
git clone --quiet "$R" "$GYANAM_DIR/repo" 2>/dev/null
( cd "$GYANAM_DIR/repo"; git branch --set-upstream-to=origin/main --quiet 2>/dev/null || true )
BEFORE=$(git -C "$GYANAM_DIR/repo" rev-parse HEAD)
advance_remote "$R"
run_case repo "$R"
AFTER=$(git -C "$GYANAM_DIR/repo" rev-parse HEAD)
{ [[ $RC -eq 0 && $DF -eq 0 && "$BEFORE" != "$AFTER" ]] && ok "behind → rc=0, fast-forwarded ${BEFORE:0:7}→${AFTER:0:7}"; } || bad "behind: rc=$RC df=$DF advanced=$([[ $BEFORE != $AFTER ]] && echo y || echo n)"

# ── Case 3: DIVERGED (non-ff) → return 1, DEPLOY_FAILED 1 — THE incident ──────
GYANAM_DIR="$ROOT/ws3"; mkdir -p "$GYANAM_DIR"
R=$(make_remote r3)
git clone --quiet "$R" "$GYANAM_DIR/repo" 2>/dev/null
( cd "$GYANAM_DIR/repo"; git branch --set-upstream-to=origin/main --quiet 2>/dev/null || true )
# local diverges: a local-only commit; remote advances differently → non-ff
( cd "$GYANAM_DIR/repo"; git config user.email t@t; git config user.name t; \
  echo local > g.txt; git add g.txt; git commit --quiet -m local-divergent )
advance_remote "$R"
run_case repo "$R"
{ [[ $RC -eq 1 && $DF -eq 1 ]] && ok "DIVERGED non-ff → rc=1, DEPLOY_FAILED=1 (aborts before build)"; } || bad "diverged: rc=$RC df=$DF (want 1/1 — THE INCIDENT REGRESSED)"

# ── Case 4: dirty tree blocks ff → return 1, DEPLOY_FAILED 1 ──────────────────
GYANAM_DIR="$ROOT/ws4"; mkdir -p "$GYANAM_DIR"
R=$(make_remote r4)
git clone --quiet "$R" "$GYANAM_DIR/repo" 2>/dev/null
( cd "$GYANAM_DIR/repo"; git branch --set-upstream-to=origin/main --quiet 2>/dev/null || true )
advance_remote "$R"
# uncommitted change to the SAME file the remote advances → ff refuses
( cd "$GYANAM_DIR/repo"; echo dirty >> f.txt )
run_case repo "$R"
{ [[ $RC -eq 1 && $DF -eq 1 ]] && ok "dirty tree blocks ff → rc=1, DEPLOY_FAILED=1"; } || bad "dirty: rc=$RC df=$DF (want 1/1)"

# ── Case 5: path exists but isn't a git repo → return 1, DEPLOY_FAILED 1 ──────
GYANAM_DIR="$ROOT/ws5"; mkdir -p "$GYANAM_DIR/repo"
echo notarepo > "$GYANAM_DIR/repo/stray.txt"
run_case repo "https://example.invalid/x.git"
{ [[ $RC -eq 1 && $DF -eq 1 ]] && ok "non-repo dir → rc=1, DEPLOY_FAILED=1"; } || bad "non-repo: rc=$RC df=$DF (want 1/1)"

echo
echo "──────────────────────────────────────────"
echo "  PASS: $PASS   FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || { echo "  RESULT: FAILED" >&2; exit 1; }
echo "  RESULT: all fail-loud sync contracts green"
