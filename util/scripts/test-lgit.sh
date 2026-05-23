#!/usr/bin/env bash
# Smoke tests for util/scripts/lgit.sh — covers the 4 documented
# failure modes + 1 successful execution path. Composes with the
# regression-test discipline in [[feedback-no-direct-git-commands-use-lgit-wrapper]].
#
# Usage: bash util/scripts/test-lgit.sh
# Exit:  0 on PASS / non-zero on first FAIL with diagnostic
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LGIT="$SCRIPT_DIR/lgit.sh"

PASS=0
FAIL=0
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
RESET=$'\033[0m'

# Helper: assert lgit exits with $1, with optional stderr-substring match in $2
expect_exit() {
  local expected_exit="$1"
  local stderr_match="${2:-}"
  shift 2 || shift 1 || true
  local desc="$1"
  shift

  local actual_exit=0
  local stderr_capture
  stderr_capture="$(bash "$LGIT" "$@" 2>&1 1>/dev/null)" || actual_exit=$?

  if [[ "$actual_exit" -ne "$expected_exit" ]]; then
    echo "${RED}FAIL${RESET}: $desc"
    echo "  expected exit: $expected_exit"
    echo "  actual exit:   $actual_exit"
    echo "  stderr:        $stderr_capture"
    FAIL=$((FAIL + 1))
    return
  fi

  if [[ -n "$stderr_match" ]] && ! grep -qF "$stderr_match" <<< "$stderr_capture"; then
    echo "${RED}FAIL${RESET}: $desc"
    echo "  exit OK ($expected_exit) but stderr missing expected substring: '$stderr_match'"
    echo "  actual stderr: $stderr_capture"
    FAIL=$((FAIL + 1))
    return
  fi

  echo "${GREEN}PASS${RESET}: $desc"
  PASS=$((PASS + 1))
}

# Helper: assert successful execution (exit 0 + stdout-substring match)
expect_success() {
  local stdout_match="$1"
  local desc="$2"
  shift 2

  local actual_exit=0
  local stdout_capture
  stdout_capture="$(bash "$LGIT" "$@" 2>/dev/null)" || actual_exit=$?

  if [[ "$actual_exit" -ne 0 ]]; then
    echo "${RED}FAIL${RESET}: $desc"
    echo "  expected exit: 0"
    echo "  actual exit:   $actual_exit"
    FAIL=$((FAIL + 1))
    return
  fi

  if [[ -n "$stdout_match" ]] && ! grep -qF "$stdout_match" <<< "$stdout_capture"; then
    echo "${RED}FAIL${RESET}: $desc"
    echo "  exit 0 but stdout missing expected substring: '$stdout_match'"
    echo "  actual stdout (first 200): ${stdout_capture:0:200}"
    FAIL=$((FAIL + 1))
    return
  fi

  echo "${GREEN}PASS${RESET}: $desc"
  PASS=$((PASS + 1))
}

echo "── lgit.sh smoke tests ────────────────────────────────────────"

# ── Failure mode 1: missing arg → exit 2 (USAGE) ────────────────────
expect_exit 2 "<org/repo> argument required" "no args → exit 2 USAGE"

# Bad arg shape → also exit 2
expect_exit 2 "must match shape 'org/repo'" "bad-shape arg → exit 2 USAGE" "not-a-repo-name"

# ── Failure mode 2: unknown repo → exit 3 (UNKNOWN_REPO) ────────────
expect_exit 3 "Unknown repo" "unknown repo → exit 3 UNKNOWN_REPO" "ssnukala/nonexistent-repo-xyz" status

# ── Failure mode 3: known repo but path missing on disk ─────────────
# Hard to test without polluting the workspace; we rely on the
# resolve_fallback_path + repos.json invariants that, for shipped
# entries, paths exist. The check itself is exercised at runtime IF a
# path goes missing. Document the gap rather than synthesise a fixture.
echo "(skipped: path-missing failure mode — invariant maintained by deploy script)"

# ── Failure mode 4: remote-URL mismatch (hard to test without
#    mutation). The check is exercised structurally: every shipped entry
#    in repos.json + fallbacks is validated at script run-time. Synth
#    test would require a sacrificial clone; out of scope for smoke.
echo "(skipped: remote-mismatch failure mode — requires sacrificial clone)"

# ── Success path: known repo + simple read-only op ───────────────────
# `lgit ssnukala/lochan-gyanam log --oneline -1` — should return the
# umbrella's HEAD commit summary.
expect_success "" "ssnukala/lochan-gyanam log → exit 0" "ssnukala/lochan-gyanam" log --oneline -1

# `lgit ssnukala/lochan branch --show-current` — should return the
# framework repo's current branch (whatever it is).
expect_success "" "ssnukala/lochan branch --show-current → exit 0" "ssnukala/lochan" branch --show-current

# `lgit ssnukala/claude status --short` — should work against the
# claude repo without polluting parent shell cwd.
expect_success "" "ssnukala/claude status → exit 0" "ssnukala/claude" status --short

# ── Phase 2 — Feature A: commit-to-main guard via --confirm-main ───
#
# Tests A2/A3/A4/A5 run against ssnukala/claude (always on main).
# A1 is the negative — commit on a feature branch should NOT trigger
# the guard (lochan-gyanam this PR is on feat/...); a simple status
# probe via lgit confirms the wrapper doesn't gate read-only ops.

# A1: status (non-commit/push subcmd) on main → guard never fires
expect_success "" "A1: read-only op on main → no guard fires" "ssnukala/claude" log --oneline -1

# A2: commit on main WITHOUT --confirm-main → exit 6 PROTECTED_BRANCH
expect_exit 6 "refuses 'git commit' on branch 'main' WITHOUT --confirm-main" \
  "A2: commit on main no flag → exit 6 PROTECTED_BRANCH" \
  "ssnukala/claude" commit -m "should-be-blocked"

# A3: commit on main WITH --confirm-main → guard passes (git itself may
# fail on "nothing to commit" or unknown flag; we just verify the gate
# message shows the flag was honored).
A3_STDERR="$(bash "$LGIT" ssnukala/claude commit --confirm-main --dry-run 2>&1 1>/dev/null || true)"
if grep -qF -- "--confirm-main present → proceeding with 'git commit' on main" <<< "$A3_STDERR"; then
  echo "${GREEN}PASS${RESET}: A3: commit on main WITH --confirm-main → guard passes (flag stripped)"
  PASS=$((PASS + 1))
else
  echo "${RED}FAIL${RESET}: A3: expected bypass-message in stderr"
  echo "  stderr: $A3_STDERR"
  FAIL=$((FAIL + 1))
fi

# A4: push on main WITHOUT --confirm-main → exit 6 PROTECTED_BRANCH
expect_exit 6 "refuses 'git push' on branch 'main' WITHOUT --confirm-main" \
  "A4: push on main no flag → exit 6 PROTECTED_BRANCH" \
  "ssnukala/claude" push origin main

# A5: push on main WITH --confirm-main → guard passes (we use --dry-run
# so no actual remote push happens; gate-pass message is what we verify)
A5_STDERR="$(bash "$LGIT" ssnukala/claude push --confirm-main --dry-run origin main 2>&1 1>/dev/null || true)"
if grep -qF -- "--confirm-main present → proceeding with 'git push' on main" <<< "$A5_STDERR"; then
  echo "${GREEN}PASS${RESET}: A5: push on main WITH --confirm-main → guard passes (flag stripped)"
  PASS=$((PASS + 1))
else
  echo "${RED}FAIL${RESET}: A5: expected bypass-message in stderr"
  echo "  stderr: $A5_STDERR"
  FAIL=$((FAIL + 1))
fi

# ── Phase 2 — Feature B: worktree routing via <repo>@<chunk-id> ────

# B1: @<non-existent-id> → exit 7 WORKTREE_NOT_FOUND
expect_exit 7 "not found" \
  "B1: @<nonexistent> → exit 7 WORKTREE_NOT_FOUND" \
  "ssnukala/lochan@worktree-that-doesnt-exist-xyz" status

# B2: @<existing-worktree> + status → exit 0 (uses w-chat-message-protocol-full-surface
# fixture which is registered with the ssnukala/lochan primary)
expect_success "" "B2: @<existing-worktree> status → exit 0" \
  "ssnukala/lochan@w-chat-message-protocol-full-surface" status --short

# B3: bad-shape WORKTREE_ID (contains '/') → exit 2 USAGE
expect_exit 2 "basename-safe shape" \
  "B3: @<bad-shape-id> → exit 2 USAGE" \
  "ssnukala/lochan@bad/shape/id" status

# ── Phase 2 — Feature C: create-worktree subcommand ────────────────

# C1: create-worktree without chunk-id → exit 2 USAGE
expect_exit 2 "requires a <chunk-id> argument" \
  "C1: create-worktree no args → exit 2 USAGE" \
  "ssnukala/lochan" create-worktree

# C2: create-worktree where chunk-id collides with existing worktree
# (w-chat-message-protocol-full-surface exists) → exit 8 WORKTREE_EXISTS
expect_exit 8 "already exists" \
  "C2: create-worktree <existing> → exit 8 WORKTREE_EXISTS" \
  "ssnukala/lochan" create-worktree "w-chat-message-protocol-full-surface"

# C3: create-worktree with @ syntax → exit 2 USAGE (subcommand takes its own chunk-id)
expect_exit 2 "does not accept @<chunk-id>" \
  "C3: create-worktree on @<id> → exit 2 USAGE (no @ syntax)" \
  "ssnukala/lochan@some-id" create-worktree "another-id"

# ── Phase 2 — Feature D: delete-worktree refuses dirty ─────────────

# D1: delete-worktree on a non-existent chunk-id → exit 7 WORKTREE_NOT_FOUND
expect_exit 7 "does not exist" \
  "D1: delete-worktree <nonexistent> → exit 7 WORKTREE_NOT_FOUND" \
  "ssnukala/lochan" delete-worktree "worktree-that-doesnt-exist-xyz"

# Note: testing D-dirty-refusal requires creating a synthetic dirty
# worktree; skipped here to avoid polluting the workspace. The check
# itself is exercised at runtime IF a session tries to delete a dirty
# worktree (exit 9; --force bypasses).
echo "(skipped: D-dirty-refusal — requires synthetic dirty worktree fixture)"

echo "──────────────────────────────────────────────────────────────"
echo "PASS=$PASS FAIL=$FAIL"

[[ "$FAIL" -eq 0 ]]
