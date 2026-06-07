#!/usr/bin/env bash
# Regression tests for verify-app-green.sh — canonical FULL-STACK green
# check substrate. Pins the canonical invariants per Build session
# MSG-025 + founder ratify 2026-06-07 ("fwprod is green when both
# frontend and backend logs are clean and the url actually pulls up the
# site without any errors"). Pure-bash test mirroring the
# test-capture-run-sidecar-substrate.sh canonical pattern.
#
# Why this exists (§V-Verify-App-Green-Substrate-Pinning):
#   - MSG-025 BINDING ratifies verify-app-green.sh AS the canonical
#     definition of "green" (5-gate full-stack vs daksh-verify backend-
#     only). The 3-incident streak (MSG-013/017/018/022 false-green)
#     justifies a regression suite, not just a doc note.
#   - This test pins the structural invariants of verify-app-green.sh +
#     its adoption in build-app.sh so future edits can't regress to
#     "judgment-based green" + can't drop a gate + can't bypass the
#     full-stack check at the build wrapper layer.
#   - Sister to feedback-discipline-fix-validates-via-n-consecutive-
#     clean-pr-streak BINDING: substrate-pinning regression test IS the
#     mechanism by which the discipline survives N future sessions.
#
# Canonical invariants pinned:
#   §V.1 util/scripts/build/verify-app-green.sh EXISTS + is executable
#   §V.2 Script declares all 5 gate headers ([1/5]..[5/5]) + canonical
#        gate names (CONTAINERS / BACKEND LOG / FRONTEND LOG / BACKEND
#        URL / FRONTEND URL+render)
#   §V.3 Script resolves backend + frontend ports dynamically via
#        `docker compose port` (NOT hardcoded :5001 / :3000 host ports)
#   §V.4 Script references the canonical Playwright sidecar image
#        (lochan-frontend-playwright:latest) for the render gate +
#        fails-with-build-hint when the image is missing (per
#        [[feedback-no-silent-try-except-fail-loudly-at-boot]] BINDING)
#   §V.5 util/.gitignore force-includes util/scripts/build/ subfolder
#        so future verify-app-green.sh-style edits aren't silently
#        masked by the broad `build/` ignore rule
#   §V.6 util/scripts/build/build-app.sh INVOKES verify-app-green.sh as
#        Step 2/2 of its verify path (NOT replaced by daksh verify alone)
#   §V.7 build-app.sh preserves --no-verify flag semantics (skips BOTH
#        daksh verify + verify-app-green.sh; no half-verify mode)
#   §V.8 verify-app-green.sh exits 0 ONLY if all 5 gates pass; exits 1
#        with PASS/FAIL summary on any FAIL (binary verdict, no "mostly
#        green" — per founder canonical-green definition)
#   §V.9 Script has substantive doc-block (founder Day-7 BINDING B);
#        ≥20 comment lines documenting WHY (not WHAT)
#   §V.10 Script uses `set -uo pipefail` WITHOUT -e (canonical multi-gate
#        aggregator pattern; -e would bail on first RED gate, defeating
#        the multi-layer honest-disclosure requirement per
#        [[feedback-multi-layer-bug-stack-honest-disclosure]])
#
# Usage: bash util/scripts/build/test-verify-app-green-script.sh
# Exit:  0 on ALL PASS / non-zero with PASS/FAIL summary on any FAIL

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# SCRIPT_DIR = <gyanam>/util/scripts/build; GYANAM_DIR = <gyanam>
GYANAM_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VERIFY_GREEN_SH="$GYANAM_DIR/util/scripts/build/verify-app-green.sh"
BUILD_APP_SH="$GYANAM_DIR/util/scripts/build/build-app.sh"
GITIGNORE_UTIL="$GYANAM_DIR/util/.gitignore"

PASS=0
FAIL=0
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
RESET=$'\033[0m'

pass() { echo "${GREEN}PASS${RESET}: $1"; PASS=$((PASS + 1)); }
fail() { echo "${RED}FAIL${RESET}: $1"; FAIL=$((FAIL + 1)); }

# ── §V.1 — verify-app-green.sh exists + executable ────────────────────
test_v1_script_exists_and_executable() {
  local desc="§V.1 util/scripts/build/verify-app-green.sh EXISTS + is executable"
  if [[ ! -f "$VERIFY_GREEN_SH" ]]; then
    fail "$desc — file missing at $VERIFY_GREEN_SH"
    return
  fi
  if [[ ! -x "$VERIFY_GREEN_SH" ]]; then
    fail "$desc — file present but NOT executable (chmod +x missing)"
    return
  fi
  pass "$desc"
}

# ── §V.2 — script declares all 5 gates with canonical names ──────────
test_v2_five_gate_headers_present() {
  local desc="§V.2 Script declares all 5 gate headers [1/5]..[5/5] + canonical names (CONTAINERS / BACKEND LOG / FRONTEND LOG / BACKEND URL / FRONTEND URL)"
  local missing=()
  # The gate progress headers in the script are echoed as `[1/5]`..[5/5].
  for n in 1 2 3 4 5; do
    if ! grep -qE "echo \"\[$n/5\]" "$VERIFY_GREEN_SH"; then
      missing+=("[$n/5]")
    fi
  done
  # Canonical GATE-N comment headers (per MSG-025 spec)
  for name in "GATE 1" "GATE 2" "GATE 3" "GATE 4" "GATE 5"; do
    if ! grep -q "$name " "$VERIFY_GREEN_SH"; then
      missing+=("$name comment")
    fi
  done
  # Canonical gate-NAME tokens (in either header text OR doc-block)
  for token in CONTAINERS "BACKEND LOG" "FRONTEND LOG" "BACKEND URL" "FRONTEND URL"; do
    if ! grep -q "$token" "$VERIFY_GREEN_SH"; then
      missing+=("$token")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    pass "$desc"
  else
    fail "$desc — missing: ${missing[*]}"
  fi
}

# ── §V.3 — ports resolved dynamically via `docker compose port` ──────
test_v3_dynamic_port_resolution() {
  local desc="§V.3 Script resolves backend + frontend ports dynamically via 'docker compose port' (NOT hardcoded host ports)"
  # Must call `compose port backend 5001` and `compose port frontend 3000`
  # using the DC array (i.e., container-port lookups; host port is derived
  # from output via parameter expansion).
  if grep -qE 'port backend 5001' "$VERIFY_GREEN_SH" && \
     grep -qE 'port frontend 3000' "$VERIFY_GREEN_SH"; then
    # Negative guard: confirm we don't hardcode `localhost:5001` or
    # `localhost:3000` as the verify target (those would bypass dynamic
    # resolution — fwprod publishes on 5301/5300, not 5001/3000).
    if grep -qE 'http://localhost:5001/' "$VERIFY_GREEN_SH" || \
       grep -qE 'http://localhost:3000/' "$VERIFY_GREEN_SH"; then
      fail "$desc — dynamic resolution present BUT hardcoded :5001 or :3000 also present"
      return
    fi
    pass "$desc"
  else
    fail "$desc — 'port backend 5001' or 'port frontend 3000' dynamic lookup missing"
  fi
}

# ── §V.4 — Playwright sidecar image referenced + fail-loud on missing ─
test_v4_playwright_sidecar_reference_and_failloud() {
  local desc="§V.4 Script references canonical Playwright sidecar image (lochan-frontend-playwright:latest) + fails-loud-with-build-hint when image missing"
  if ! grep -qE 'lochan-frontend-playwright:latest' "$VERIFY_GREEN_SH"; then
    fail "$desc — canonical sidecar image reference missing"
    return
  fi
  # Must check `docker image inspect` for the sidecar + emit a build-hint
  # message ("build it" + the build-app.sh invocation) on miss. This
  # encodes [[feedback-no-silent-try-except-fail-loudly-at-boot]]: don't
  # silently SKIP gate 5 when sidecar absent — fail the gate with a path
  # to remediation.
  if grep -qE 'docker image inspect' "$VERIFY_GREEN_SH" && \
     grep -qE 'build-app\.sh .* --with-playwright' "$VERIFY_GREEN_SH"; then
    pass "$desc"
  else
    fail "$desc — image-inspect guard OR build-hint message missing (silent-skip risk)"
  fi
}

# ── §V.5 — util/.gitignore force-includes scripts/build/ subfolder ────
test_v5_gitignore_allows_build_scripts_folder() {
  local desc="§V.5 util/.gitignore force-includes scripts/build/ subfolder (! exception) so new build-wrapper scripts aren't silently masked"
  if [[ ! -f "$GITIGNORE_UTIL" ]]; then
    fail "$desc — util/.gitignore missing"
    return
  fi
  # The broad `build/` ignore must be paired with an explicit `!scripts/build/`
  # un-ignore so future verify-app-green.sh-shaped edits land in git
  # tracking by default. Without this, the build session's authored
  # script sat untracked-for-days (the trigger for this PR).
  if grep -qE '^!scripts/build/' "$GITIGNORE_UTIL"; then
    pass "$desc"
  else
    fail "$desc — '!scripts/build/' un-ignore line missing; new scripts will be silently masked by the 'build/' rule"
  fi
}

# ── §V.6 — build-app.sh invokes verify-app-green.sh as Step 2 ────────
test_v6_build_app_sh_invokes_verify_app_green() {
  local desc="§V.6 build-app.sh INVOKES verify-app-green.sh as the full-stack verify step (NOT replaced by 'daksh verify' alone)"
  if grep -qE 'verify-app-green\.sh' "$BUILD_APP_SH" && \
     grep -qE '\$VERIFY_GREEN_SH" "\$APP"' "$BUILD_APP_SH"; then
    pass "$desc"
  else
    fail "$desc — verify-app-green.sh invocation missing from build-app.sh"
  fi
}

# ── §V.7 — build-app.sh preserves --no-verify flag semantics ─────────
test_v7_build_app_sh_no_verify_flag_skips_both() {
  local desc="§V.7 build-app.sh --no-verify flag SKIPS both daksh verify + verify-app-green.sh (no half-verify mode)"
  # Both invocations must live INSIDE the `if [[ $VERIFY -eq 1 ]]; then`
  # block so --no-verify (which sets VERIFY=0) skips both atomically.
  local verify_block_start
  local verify_block_end
  verify_block_start=$(grep -nE 'if \[\[ \$VERIFY -eq 1 \]\]; then' "$BUILD_APP_SH" | head -1 | cut -d: -f1)
  # Find the matching closing `fi` after the start; assume it's the last
  # `^fi$` line in the file (the verify block is the final block).
  verify_block_end=$(grep -nE '^fi$' "$BUILD_APP_SH" | tail -1 | cut -d: -f1)
  if [[ -z "$verify_block_start" || -z "$verify_block_end" ]]; then
    fail "$desc — could not locate VERIFY block boundaries (start=$verify_block_start end=$verify_block_end)"
    return
  fi
  # Both `daksh-cli verify` and `verify-app-green.sh` invocations must be
  # within [start, end].
  local daksh_line
  local green_line
  daksh_line=$(grep -nE '"\$DAKSH_CLI" verify "\$APP"' "$BUILD_APP_SH" | head -1 | cut -d: -f1)
  green_line=$(grep -nE '"\$VERIFY_GREEN_SH" "\$APP"' "$BUILD_APP_SH" | head -1 | cut -d: -f1)
  if [[ -z "$daksh_line" || -z "$green_line" ]]; then
    fail "$desc — daksh verify or verify-app-green.sh invocation not found in build-app.sh"
    return
  fi
  if (( daksh_line > verify_block_start && daksh_line < verify_block_end && \
        green_line > verify_block_start && green_line < verify_block_end )); then
    pass "$desc (verify block lines $verify_block_start..$verify_block_end; daksh=$daksh_line; green=$green_line)"
  else
    fail "$desc — at least one invocation is OUTSIDE the VERIFY guard block (would run even with --no-verify)"
  fi
}

# ── §V.8 — exit 0 ONLY if all 5 gates pass (binary verdict) ──────────
test_v8_binary_verdict_exit_codes() {
  local desc="§V.8 Script exits 0 ONLY if all 5 gates pass; exits 1 on any FAIL (binary verdict, no 'mostly green')"
  # Verify the failure-aggregation pattern: a FAILURES array that gates
  # accumulate into + a final `if [[ \${#FAILURES[@]} -eq 0 ]]; then exit 0; else ... exit 1`.
  if grep -qE 'FAILURES=\(\)' "$VERIFY_GREEN_SH" && \
     grep -qE 'FAILURES\+=' "$VERIFY_GREEN_SH" && \
     grep -qE '\$\{#FAILURES\[@\]\} -eq 0' "$VERIFY_GREEN_SH" && \
     grep -qE '^\s*exit 0' "$VERIFY_GREEN_SH" && \
     grep -qE '^\s*exit 1' "$VERIFY_GREEN_SH"; then
    pass "$desc"
  else
    fail "$desc — FAILURES aggregation pattern OR canonical exit 0/1 pair missing"
  fi
}

# ── §V.9 — substantive doc-block (founder Day-7 B) ────────────────────
test_v9_substantive_docblock() {
  local desc="§V.9 verify-app-green.sh has substantive doc-block ≥20 comment lines per founder Day-7 BINDING (B)"
  local comment_lines
  comment_lines=$(awk '/^#/{count++} END{print count+0}' "$VERIFY_GREEN_SH")
  if [[ "$comment_lines" -ge 20 ]]; then
    pass "$desc (comment-lines=$comment_lines)"
  else
    fail "$desc — doc-block too thin (comment-lines=$comment_lines; expected ≥20)"
  fi
}

# ── §V.10 — `set -uo pipefail` WITHOUT -e (multi-gate aggregator) ────
test_v10_no_set_e_multigate_aggregator() {
  local desc="§V.10 Script uses 'set -uo pipefail' WITHOUT -e (multi-gate aggregator; -e would bail on first RED, hiding downstream failures)"
  # Verify `set -uo pipefail` is present and `set -e` / `set -eu...` is NOT
  # (we want -uo pipefail, NOT -euo pipefail).
  if grep -qE '^set -uo pipefail' "$VERIFY_GREEN_SH" && \
     ! grep -qE '^set -e' "$VERIFY_GREEN_SH" && \
     ! grep -qE '^set -eu' "$VERIFY_GREEN_SH"; then
    pass "$desc"
  else
    fail "$desc — script either uses -e (would bail early) OR omits -uo pipefail"
  fi
}

echo "── verify-app-green.sh substrate regression (MSG-025 canonical green-gate) ──"
echo ""
test_v1_script_exists_and_executable
test_v2_five_gate_headers_present
test_v3_dynamic_port_resolution
test_v4_playwright_sidecar_reference_and_failloud
test_v5_gitignore_allows_build_scripts_folder
test_v6_build_app_sh_invokes_verify_app_green
test_v7_build_app_sh_no_verify_flag_skips_both
test_v8_binary_verdict_exit_codes
test_v9_substantive_docblock
test_v10_no_set_e_multigate_aggregator

echo ""
TOTAL=$((PASS + FAIL))
if [[ "$FAIL" -eq 0 ]]; then
  echo "${GREEN}ALL PASS${RESET} — $PASS/$TOTAL"
  exit 0
else
  echo "${RED}FAIL${RESET} — $PASS passed / $FAIL failed / $TOTAL total"
  exit 1
fi
