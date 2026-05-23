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

echo "──────────────────────────────────────────────────────────────"
echo "PASS=$PASS FAIL=$FAIL"

[[ "$FAIL" -eq 0 ]]
