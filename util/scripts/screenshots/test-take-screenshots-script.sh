#!/usr/bin/env bash
# Regression tests for take-screenshots.sh — canonical strict-visual-validation
# screenshot substrate. Pins the canonical invariants per founder verbatim
# 2026-06-07: "for verify green the session has to launch the side car and
# launch frontend page and verify both frontend and backed logs are clear and
# that the screenshots show actual lochan screens".
#
# Why this exists (§T-Take-Screenshots-Substrate-Pinning):
#   - gyanam#39 verify-app-green.sh shipped a Gate-5 render check that
#     invoked `daksh screenshot` but did NOT validate that the produced
#     screenshots actually contained Lochan content (blank pages / error
#     overlays / 404-as-200 all yielded false-green at Gate 5).
#   - This followup pulls sidecar launch + STRICT visual validation into a
#     dedicated substrate (take-screenshots.sh) so that:
#       (a) Gate 5 of verify-app-green.sh composes a single check via
#           `take-screenshots.sh <app> --render-check`
#       (b) Manual captures (--desktop / --mobile / --all) use the same
#           strict-validation harness
#   - This regression test pins the structural invariants so future edits
#     can't regress to "trust the sidecar exit code" or "skip the size/dim
#     checks".
#
# Canonical invariants pinned:
#   §T.1 util/scripts/screenshots/take-screenshots.sh EXISTS + is executable
#   §T.2 Script supports all four mode flags: --desktop, --mobile, --all,
#        --render-check
#   §T.3 MIN_SCREENSHOT_BYTES constant present at 30 KB (= 30720) — the
#        empirically-derived threshold that catches blank pages + error
#        overlays while passing real Lochan SPA captures
#   §T.4 Dimension constants present for desktop (≥1280x720) + mobile
#        (≥400x800; Playwright Pixel 7 = 412x915)
#   §T.5 Script references the canonical Playwright sidecar image
#        (lochan-frontend-playwright:latest) + fails-loud-with-build-hint
#        when the image is absent (per
#        [[feedback-no-silent-try-except-fail-loudly-at-boot]] BINDING)
#   §T.6 Script invokes the canonical compose extension
#        (docker/compose.playwright.yml) — does NOT duplicate compose logic
#   §T.7 Script does strict screenshot validation: size check + dimensions
#        check + count check (three independent visual gates)
#   §T.8 Script re-checks both backend + frontend container logs WITHIN
#        the navigation window (--since LOG_REF), not whole container life
#   §T.9 verify-app-green.sh Gate 5 invokes take-screenshots.sh
#        --render-check (composition; no parallel-mirror substrate)
#   §T.10 Script has substantive doc-block ≥30 comment lines per founder
#         Day-7 BINDING (B); cites the founder 2026-06-07 verbatim quote
#   §T.11 Script uses `set -uo pipefail` WITHOUT -e (multi-check aggregator
#         pattern; mirrors verify-app-green.sh per
#         [[feedback-multi-layer-bug-stack-honest-disclosure]] BINDING)
#
# Usage: bash util/scripts/screenshots/test-take-screenshots-script.sh
# Exit:  0 on ALL PASS / non-zero with PASS/FAIL summary on any FAIL

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GYANAM_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TAKE_SCREENSHOTS_SH="$GYANAM_DIR/util/scripts/screenshots/take-screenshots.sh"
VERIFY_GREEN_SH="$GYANAM_DIR/util/scripts/build/verify-app-green.sh"

PASS=0
FAIL=0
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
RESET=$'\033[0m'

pass() { echo "${GREEN}PASS${RESET}: $1"; PASS=$((PASS + 1)); }
fail() { echo "${RED}FAIL${RESET}: $1"; FAIL=$((FAIL + 1)); }

# ── §T.1 — take-screenshots.sh exists + executable ────────────────────
test_t1_script_exists_and_executable() {
  local desc="§T.1 util/scripts/screenshots/take-screenshots.sh EXISTS + is executable"
  if [[ ! -f "$TAKE_SCREENSHOTS_SH" ]]; then
    fail "$desc — file missing at $TAKE_SCREENSHOTS_SH"
    return
  fi
  if [[ ! -x "$TAKE_SCREENSHOTS_SH" ]]; then
    fail "$desc — file present but NOT executable"
    return
  fi
  pass "$desc"
}

# ── §T.2 — supports all four mode flags ──────────────────────────────
test_t2_four_mode_flags_supported() {
  local desc="§T.2 Script supports all four mode flags (--desktop, --mobile, --all, --render-check)"
  local missing=()
  # Use grep -e to disambiguate from BSD grep parsing the literal `--` as flag start
  for flag in --desktop --mobile --all --render-check; do
    if ! grep -qE -e "${flag}\)" "$TAKE_SCREENSHOTS_SH"; then
      missing+=("$flag")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    pass "$desc"
  else
    fail "$desc — missing case-branch for: ${missing[*]}"
  fi
}

# ── §T.3 — MIN_SCREENSHOT_BYTES = 30720 (30 KB) ──────────────────────
test_t3_min_screenshot_bytes_constant() {
  local desc="§T.3 MIN_SCREENSHOT_BYTES constant present at 30 KB (=30720)"
  if grep -qE '^MIN_SCREENSHOT_BYTES=30720' "$TAKE_SCREENSHOTS_SH"; then
    pass "$desc"
  else
    fail "$desc — MIN_SCREENSHOT_BYTES=30720 line missing or set to different value"
  fi
}

# ── §T.4 — dimension constants present ────────────────────────────────
test_t4_dimension_constants_present() {
  local desc="§T.4 Dimension constants present (desktop ≥1280x720; mobile ≥400x800)"
  local missing=()
  for kv in 'MIN_DESKTOP_WIDTH=1280' 'MIN_DESKTOP_HEIGHT=720' 'MIN_MOBILE_WIDTH=400' 'MIN_MOBILE_HEIGHT=800'; do
    if ! grep -qE "^${kv}" "$TAKE_SCREENSHOTS_SH"; then
      missing+=("$kv")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    pass "$desc"
  else
    fail "$desc — missing constants: ${missing[*]}"
  fi
}

# ── §T.5 — sidecar image reference + fail-loud build hint ────────────
test_t5_sidecar_image_failloud() {
  local desc="§T.5 Script references canonical sidecar image + fails-loud-with-build-hint when missing"
  if ! grep -qE 'lochan-frontend-playwright:latest' "$TAKE_SCREENSHOTS_SH"; then
    fail "$desc — canonical sidecar image reference missing"
    return
  fi
  if grep -qE 'docker image inspect' "$TAKE_SCREENSHOTS_SH" && \
     grep -qE 'build-app\.sh .* --with-playwright' "$TAKE_SCREENSHOTS_SH"; then
    pass "$desc"
  else
    fail "$desc — image-inspect guard OR build-hint message missing (silent-skip risk)"
  fi
}

# ── §T.6 — invokes canonical compose extension ────────────────────────
test_t6_canonical_compose_invocation() {
  local desc="§T.6 Script invokes the canonical compose extension (docker/compose.playwright.yml; no duplicated compose logic)"
  if grep -qE 'compose\.playwright\.yml' "$TAKE_SCREENSHOTS_SH" && \
     grep -qE '\-\-profile screenshots' "$TAKE_SCREENSHOTS_SH" && \
     grep -qE 'playwright-screenshots' "$TAKE_SCREENSHOTS_SH"; then
    pass "$desc"
  else
    fail "$desc — canonical compose invocation pattern missing"
  fi
}

# ── §T.7 — strict three-check visual validation ───────────────────────
test_t7_strict_three_check_validation() {
  local desc="§T.7 Script does STRICT three-check visual validation (count + file size + dimensions)"
  local missing=()
  # Count check
  if ! grep -qE 'MIN_SCREENSHOTS' "$TAKE_SCREENSHOTS_SH"; then
    missing+=("count-check (MIN_SCREENSHOTS)")
  fi
  # File-size check via stat
  if ! grep -qE 'MIN_SCREENSHOT_BYTES' "$TAKE_SCREENSHOTS_SH" || \
     ! grep -qE 'stat (-f %z|-c %s)' "$TAKE_SCREENSHOTS_SH"; then
    missing+=("size-check (stat + MIN_SCREENSHOT_BYTES compare)")
  fi
  # Dimensions check via `file` PNG output parse
  if ! grep -qE 'PNG image data' "$TAKE_SCREENSHOTS_SH" || \
     ! grep -qE 'MIN_DESKTOP_WIDTH|MIN_DESKTOP_HEIGHT|MIN_MOBILE_WIDTH|MIN_MOBILE_HEIGHT' "$TAKE_SCREENSHOTS_SH"; then
    missing+=("dimensions-check")
  fi
  if [[ ${#missing[@]} -eq 0 ]]; then
    pass "$desc"
  else
    fail "$desc — missing: ${missing[*]}"
  fi
}

# ── §T.8 — log re-check within navigation window ─────────────────────
test_t8_log_window_recheck() {
  local desc="§T.8 Script re-checks backend + frontend logs WITHIN the navigation window (--since LOG_REF)"
  if grep -qE 'docker logs --since' "$TAKE_SCREENSHOTS_SH" && \
     grep -qE 'LOG_REF' "$TAKE_SCREENSHOTS_SH"; then
    pass "$desc"
  else
    fail "$desc — log-window re-check missing (--since LOG_REF pattern absent)"
  fi
}

# ── §T.9 — verify-app-green.sh Gate 5 invokes take-screenshots.sh ────
test_t9_verify_app_green_composes_take_screenshots() {
  local desc="§T.9 verify-app-green.sh Gate 5 invokes take-screenshots.sh --render-check (composition; no parallel-mirror)"
  if grep -qE 'take-screenshots\.sh' "$VERIFY_GREEN_SH" && \
     grep -qE '\-\-render-check' "$VERIFY_GREEN_SH"; then
    pass "$desc"
  else
    fail "$desc — verify-app-green.sh Gate 5 does NOT compose take-screenshots.sh --render-check"
  fi
}

# ── §T.10 — substantive doc-block ≥30 comment lines ───────────────────
test_t10_substantive_docblock() {
  local desc="§T.10 take-screenshots.sh has substantive doc-block ≥30 comment lines per founder Day-7 BINDING (B)"
  local comment_lines
  comment_lines=$(awk '/^#/{count++} END{print count+0}' "$TAKE_SCREENSHOTS_SH")
  if [[ "$comment_lines" -ge 30 ]]; then
    # Also verify the founder 2026-06-07 verbatim quote is cited
    if grep -qE 'launch the side car' "$TAKE_SCREENSHOTS_SH"; then
      pass "$desc (comment-lines=$comment_lines; founder verbatim cited)"
    else
      fail "$desc — doc-block thick enough but founder 2026-06-07 verbatim not cited"
    fi
  else
    fail "$desc — doc-block too thin (comment-lines=$comment_lines; expected ≥30)"
  fi
}

# ── §T.11 — `set -uo pipefail` WITHOUT -e (multi-check aggregator) ───
test_t11_no_set_e_multi_check_aggregator() {
  local desc="§T.11 Script uses 'set -uo pipefail' WITHOUT -e (multi-check aggregator; mirrors verify-app-green.sh pattern)"
  if grep -qE '^set -uo pipefail' "$TAKE_SCREENSHOTS_SH" && \
     ! grep -qE '^set -e' "$TAKE_SCREENSHOTS_SH" && \
     ! grep -qE '^set -eu' "$TAKE_SCREENSHOTS_SH"; then
    pass "$desc"
  else
    fail "$desc — script either uses -e (would bail early) OR omits -uo pipefail"
  fi
}

echo "── take-screenshots.sh substrate regression (gyanam#39 followup; strict visual validation) ──"
echo ""
test_t1_script_exists_and_executable
test_t2_four_mode_flags_supported
test_t3_min_screenshot_bytes_constant
test_t4_dimension_constants_present
test_t5_sidecar_image_failloud
test_t6_canonical_compose_invocation
test_t7_strict_three_check_validation
test_t8_log_window_recheck
test_t9_verify_app_green_composes_take_screenshots
test_t10_substantive_docblock
test_t11_no_set_e_multi_check_aggregator

echo ""
TOTAL=$((PASS + FAIL))
if [[ "$FAIL" -eq 0 ]]; then
  echo "${GREEN}ALL PASS${RESET} — $PASS/$TOTAL"
  exit 0
else
  echo "${RED}FAIL${RESET} — $PASS passed / $FAIL failed / $TOTAL total"
  exit 1
fi
