#!/usr/bin/env bash
# Regression tests for util/scripts/ strict-mode discipline. Pins the
# canonical bash strict-mode invariants across all wrapper scripts so
# future edits cannot accidentally regress exit-code propagation.
#
# Composes with util/scripts/test-lgit.sh smoke-test pattern (PASS/FAIL
# counters + assertion helpers). Pure-bash test; no Python dependency.
#
# Why this exists (§W-Build-App-Sh-Strict-Mode-Regression-Test):
#   - S3 Day-6 surfaced a CATCH that util/scripts/build/build-app.sh "swallows
#     daksh build non-zero exit codes". Empirical Step 4a Gate-2 verify
#     (pipefail+tee synthetic test) REFUTED the swallow — build-app.sh
#     has `set -euo pipefail` since Day-2; pipeline `daksh build | tee`
#     propagates non-zero exit correctly under pipefail.
#   - This regression test pins the canonical invariant against future
#     accidental removal (e.g., a refactor that drops `set -o pipefail`
#     would reintroduce the swallow S3 hypothesized).
#
# Canonical invariants pinned:
#   §A.1 build-app.sh declares `set -euo pipefail` at top
#   §A.2 ALL util/scripts/*.sh declare AT LEAST `set -o pipefail`
#        (drift-scan-2026-05-14.sh has pipefail-only legitimately — it's
#        a scanner that continues past per-package errors; pipefail is
#        the load-bearing invariant for pipeline propagation)
#   §A.3 Empirical pipefail propagation (synthetic subshell: `false | tee`
#        under set -o pipefail exits 1; under no pipefail exits 0)
#   §A.4 build-app.sh line ~80 `daksh build ... | tee` is NOT wrapped in
#        `|| true` / `; true` / `set +e` / other swallow constructs
#
# Memory rules referenced:
#   - feedback-verify-and-reject-step-4a-canonical-outcome (S1 Draft #2
#     BINDING) — empirical verify refuted S3's primary swallow claim;
#     this test pins the verified-correct state as canonical
#   - feedback-empirical-gate-2-iterative-until-stable (S4 draft #4) —
#     first-iteration "drift-scan no strict mode" refined to "drift-scan
#     pipefail-only legitimately"; pinning load-bearing invariant only
#   - feedback-dog-fooding-substrate-check-is-its-own-first-user — the
#     test IS the substrate's own first user; pure bash, no external deps
#   - feedback-no-shims-no-bandaids-longterm-fix-only BINDING — no fix
#     needed for the primary claim (substrate already correct); long-
#     term-right shape is pinning the invariant via regression test
#
# Usage: bash util/scripts/test-util-scripts-strict-mode.sh
# Exit:  0 on ALL PASS / non-zero with PASS/FAIL summary on any FAIL

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GYANAM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
RESET=$'\033[0m'

pass() { echo "${GREEN}PASS${RESET}: $1"; PASS=$((PASS + 1)); }
fail() { echo "${RED}FAIL${RESET}: $1"; FAIL=$((FAIL + 1)); }

# ── §A.1 — build-app.sh declares `set -euo pipefail` ─────────────────
test_a1_build_app_full_strict_mode() {
  local desc="§A.1 build-app.sh declares 'set -euo pipefail' at top"
  if grep -q "^set -euo pipefail" "$SCRIPT_DIR/build/build-app.sh"; then
    pass "$desc"
  else
    fail "$desc — missing or modified"
  fi
}

# ── §A.2 — ALL util/scripts/*.sh declare pipefail ────────────────────
test_a2_all_scripts_have_pipefail() {
  local desc="§A.2 all util/scripts/*.sh declare AT LEAST 'set -o pipefail'"
  local violators=()
  for f in "$SCRIPT_DIR"/*.sh; do
    # Match either `set -euo pipefail` or bare `set -o pipefail` or `set -e -o pipefail` etc.
    if ! grep -qE "^set (-[a-z]+ )?-o pipefail|^set -[a-z]*o[a-z]*[ ]*pipefail|^set -[a-z]+pipefail|^set -euo pipefail" "$f"; then
      violators+=("$(basename "$f")")
    fi
  done
  if [[ ${#violators[@]} -eq 0 ]]; then
    pass "$desc"
  else
    fail "$desc — violators: ${violators[*]}"
  fi
}

# ── §A.3 — empirical pipefail propagation (synthetic subshell) ──────
test_a3_empirical_pipefail_propagation() {
  local desc="§A.3 pipefail empirically propagates non-zero pipeline exit"
  local exit_with_pipefail=0
  local exit_without_pipefail=0
  bash -c 'set -o pipefail; false | tee /dev/null' >/dev/null 2>&1 || exit_with_pipefail=$?
  bash -c 'false | tee /dev/null' >/dev/null 2>&1 || exit_without_pipefail=$?
  if [[ "$exit_with_pipefail" -ne 0 ]] && [[ "$exit_without_pipefail" -eq 0 ]]; then
    pass "$desc (pipefail=$exit_with_pipefail; no-pipefail=$exit_without_pipefail)"
  else
    fail "$desc — pipefail=$exit_with_pipefail (expected non-zero); no-pipefail=$exit_without_pipefail (expected 0)"
  fi
}

# ── §A.4 — build-app.sh daksh pipeline NOT swallow-wrapped ───────────
test_a4_no_swallow_wrappers_on_daksh_pipe() {
  local desc="§A.4 build-app.sh daksh-build pipeline has no swallow wrappers"
  local daksh_line
  daksh_line="$(grep -n 'DAKSH_CLI.*build' "$SCRIPT_DIR/build/build-app.sh" | grep -v '^#' | head -1)"
  if [[ -z "$daksh_line" ]]; then
    fail "$desc — could not locate DAKSH_CLI build invocation line"
    return
  fi
  # Extract the line content (after the line-number prefix from grep -n)
  local content="${daksh_line#*:}"
  # Reject these swallow patterns on the same line:
  #   `|| true` / `|| :` / `; true` / `; :` / `set +e` immediately before
  if [[ "$content" == *"|| true"* ]] || [[ "$content" == *"|| :"* ]] || \
     [[ "$content" == *"; true"* ]] || [[ "$content" == *"; :"* ]]; then
    fail "$desc — swallow wrapper detected: $content"
    return
  fi
  # Also check that `set +e` doesn't precede the daksh line within 5 lines
  local line_num="${daksh_line%%:*}"
  local start=$((line_num - 5))
  [[ $start -lt 1 ]] && start=1
  if sed -n "${start},${line_num}p" "$SCRIPT_DIR/build/build-app.sh" | grep -q "^set +e"; then
    fail "$desc — 'set +e' detected within 5 lines before daksh invocation"
    return
  fi
  pass "$desc"
}

# ── §A.5 — strict-mode discipline doc reference in build-app.sh ─────
test_a5_build_app_doc_block_present() {
  local desc="§A.5 build-app.sh has substantive doc block (founder 2026-05-30 BINDING)"
  # Per [[feedback-doc-blocks-and-comments-for-human-and-agent-maintainability]]:
  # build-app.sh ships with substantive top-of-file documentation explaining
  # WHY it exists + memory-rule references. Pin that the doc block is present
  # to prevent accidental stripping.
  local doc_lines
  doc_lines=$(awk '/^#!/{next} /^#/{count++; next} /^$/{next} {exit} END{print count+0}' "$SCRIPT_DIR/build/build-app.sh")
  # Expect at least 15 comment lines (Usage + What it does + Why + Memory rules)
  if [[ "$doc_lines" -ge 15 ]]; then
    pass "$desc (doc-block lines=$doc_lines)"
  else
    fail "$desc — doc block too thin (lines=$doc_lines; expected ≥15)"
  fi
}

echo "── util/scripts/ strict-mode regression contract ──"
echo ""
test_a1_build_app_full_strict_mode
test_a2_all_scripts_have_pipefail
test_a3_empirical_pipefail_propagation
test_a4_no_swallow_wrappers_on_daksh_pipe
test_a5_build_app_doc_block_present

echo ""
TOTAL=$((PASS + FAIL))
if [[ "$FAIL" -eq 0 ]]; then
  echo "${GREEN}ALL PASS${RESET} — $PASS/$TOTAL"
  exit 0
else
  echo "${RED}FAIL${RESET} — $PASS passed / $FAIL failed / $TOTAL total"
  exit 1
fi
