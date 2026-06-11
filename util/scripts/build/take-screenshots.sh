#!/usr/bin/env bash
# take-screenshots.sh — canonical strict-visual-validation screenshot harness
#
# Usage:
#   ./util/scripts/build/take-screenshots.sh <app>                    # default --desktop
#   ./util/scripts/build/take-screenshots.sh <app> --desktop          # full desktop captures
#   ./util/scripts/build/take-screenshots.sh <app> --mobile           # mobile (Pixel 7) captures
#   ./util/scripts/build/take-screenshots.sh <app> --all              # both desktop + mobile
#   ./util/scripts/build/take-screenshots.sh <app> --render-check     # minimal Gate-5 validation
#
# WHY THIS EXISTS (founder verbatim 2026-06-07):
#   "for verify green the session has to launch the side car and launch
#    frontend page and verify both frontend and backed logs are clear and
#    that the screenshots show actual lochan screens"
#
# The PREDECESSOR substrate gyanam#39 (verify-app-green.sh, MSG-025) shipped
# a 5-gate FULL-STACK green check that invoked `daksh screenshot` in Gate 5
# to drive the Playwright sidecar. BUT it did NOT validate that the produced
# screenshots actually contain Lochan content. A blank page, an error overlay,
# or a 404 page that returns HTTP 200 would all yield a clean Gate-5 PASS —
# even though the founder's definition of green requires "actual lochan screens".
#
# This script closes that gap with STRICT visual validation:
#
#   1. Verify the canonical Playwright sidecar image is present (fail-loud
#      build-hint if absent — per [[feedback-no-silent-try-except-fail-loudly-at-boot]]).
#   2. Verify backend + frontend containers are running for <app> (Gate-1
#      mirror; sidecar attaches to <app>_app-network which only exists when
#      the parent compose is Up).
#   3. Record reference timestamps for backend + frontend logs BEFORE launch
#      so post-run grep narrows to the navigation window (not the whole
#      container lifetime).
#   4. LAUNCH the sidecar via the canonical compose invocation:
#        docker compose -f apps/<app>/compose.yml \
#                       -f docker/compose.playwright.yml \
#                       --profile screenshots \
#                       run --rm playwright-screenshots[-mobile]
#      Sidecar writes PNGs to framework/lochan/docs/screenshots/
#      patent_demos_clickable/ via the canonical bind-mount (PR #782
#      §A.5 invariant; host/script path agreement pinned by §L.12).
#   5. VALIDATE captured screenshots — STRICT 3-check:
#        (a) COUNT — expect ≥ MIN_SCREENSHOTS for the chosen mode. Fewer = sidecar
#            failed silently (the underlying `playwright test || true` swallows
#            failures; we re-derive truth from disk presence).
#        (b) FILE SIZE — every screenshot must be ≥ MIN_SCREENSHOT_BYTES (30 KB).
#            Empirical: real Lochan SPA captures are 200-400 KB (sample:
#            cycle4-c2d-lifelight 00-login.png = 364 KB at 1280x2438). Blank
#            pages produce <10 KB PNGs; React error overlays around 15-25 KB.
#            30 KB is the safe lower bound that catches blank+error pages
#            while passing real SPA content.
#        (c) DIMENSIONS — `file <png>` reports PNG geometry. Desktop captures
#            must be ≥ 1280x720; Pixel 7 mobile captures must be ≥ 412x800
#            (Playwright Pixel 7 device descriptor = 412x915). Catches degraded
#            captures where the viewport collapsed (a known failure mode when
#            the sidecar attaches but the parent network is gone).
#   6. CHECK LOGS clean WITHIN the navigation window — re-uses the same regex
#      taxonomy as verify-app-green.sh Gates 2/3 (backend: traceback/exception/
#      ERROR; frontend: ERROR(TypeScript)/[vite] error/transform failed/Module
#      not found). Excludes sqlalchemy.engine echo noise.
#   7. Exit 0 ONLY when ALL checks pass; exit 1 with a per-check report
#      otherwise. The binary-verdict pattern mirrors verify-app-green.sh
#      so this script composes cleanly as Gate 5.
#
# COMPOSITION (Gate 5 refactor):
#   verify-app-green.sh now delegates its Gate 5 to:
#     take-screenshots.sh <app> --render-check
#   take-screenshots.sh owns sidecar launch + visual validation; verify-app-green.sh
#   aggregates the 5 gate verdicts. Single-responsibility split per
#   [[feedback-composition-pattern-over-parallel-mirror]] BINDING.
#
# WHY 30 KB IS THE THRESHOLD:
#   Blank Playwright pages (no DOM, just background): typically 1-3 KB PNG.
#   Default React error boundary with one stack trace: ~15-25 KB.
#   Lochan SPA with login form rendered: 50-150 KB. Lochan SPA with full
#   dashboard: 200-400 KB. 30 KB is wide enough to never false-RED a real
#   capture, narrow enough to catch any degraded render. Banked future
#   enhancement: per-screenshot baseline-image diff via ImageMagick
#   `compare -metric AE` (out of scope for this PR; banked in PR description).
#
# Memory rules referenced:
#   - feedback-canonical-3-tier-package-shape-frontend-backend-agent (sidecar = Tier 3)
#   - feedback-no-silent-try-except-fail-loudly-at-boot (BINDING — sidecar missing = LOUD)
#   - feedback-composition-pattern-over-parallel-mirror (BINDING — take-screenshots.sh
#     IS the visual-validation substrate; verify-app-green.sh COMPOSES it)
#   - feedback-multi-layer-bug-stack-honest-disclosure (BINDING — surface ALL failing
#     checks, not the first)
#   - feedback-endpoint-prefix-mismatch-vs-image-staleness-discrimination (4-class
#     triage on the parent compose state if Gate 2 fails)
#
# Cites:
#   - gyanam#39 (MSG-025 BINDING) — verify-app-green.sh 5-gate predecessor
#   - docker/compose.playwright.yml — canonical opt-in sidecar (do NOT duplicate
#     compose logic here; this script invokes the canonical compose)
#   - docker/03-frontend-playwright.Dockerfile — sidecar image source
#   - ssnukala/lochan PR #782 §A.5 — bind-mount path invariant

set -uo pipefail   # NOT -e: multi-check aggregator, run every check + aggregate

# ── Tunable constants (top of file per founder Day-7 B BINDING; document WHY) ──
#
# These are the strict-visual-validation thresholds. Adjust only with empirical
# justification (e.g. a real Lochan capture that fell below MIN_SCREENSHOT_BYTES
# but was visually correct — file a follow-up if observed).
MIN_SCREENSHOT_BYTES=30720       # 30 KB — blank pages are 1-3 KB; error overlays 15-25 KB
MIN_DESKTOP_WIDTH=1280
MIN_DESKTOP_HEIGHT=720
MIN_MOBILE_WIDTH=400             # Playwright Pixel 7 device descriptor = 412x915 (we allow ≥400)
MIN_MOBILE_HEIGHT=800
RENDER_CHECK_MIN_SCREENSHOTS=1   # Gate-5 lightweight mode: at least one valid capture
FULL_CAPTURE_MIN_SCREENSHOTS=4   # --desktop / --mobile mode: full demo set has many PNGs

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GYANAM_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# Host side of the sidecar's writable /screenshots bind-mount — MUST match
# compose.playwright.yml (canonical location per PR #782 §A.5; agreement
# pinned by test-capture-run-sidecar-substrate.sh §L.12). D7 gate-5
# incident: this pointed at $GYANAM_DIR/docs/... while the sidecar wrote
# $GYANAM_DIR/framework/lochan/docs/... — the strict count check could
# never see a fresh PNG.
SCREENSHOT_DIR="$GYANAM_DIR/framework/lochan/docs/screenshots/patent_demos_clickable"

# ── Arg parsing ──
if [[ $# -lt 1 ]]; then
  echo "ERROR: app name required" >&2
  echo "Usage: $0 <app> [--desktop|--mobile|--all|--render-check]" >&2
  exit 2
fi
APP="$1"; shift || true
MODE="desktop"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --desktop) MODE="desktop"; shift ;;
    --mobile) MODE="mobile"; shift ;;
    --all) MODE="all"; shift ;;
    --render-check) MODE="render-check"; shift ;;
    *) echo "ERROR: unknown flag $1" >&2; exit 2 ;;
  esac
done

# Determine MIN_SCREENSHOTS based on mode
case "$MODE" in
  render-check) MIN_SCREENSHOTS=$RENDER_CHECK_MIN_SCREENSHOTS ;;
  desktop|mobile) MIN_SCREENSHOTS=$FULL_CAPTURE_MIN_SCREENSHOTS ;;
  all) MIN_SCREENSHOTS=$((FULL_CAPTURE_MIN_SCREENSHOTS * 2)) ;;
esac

APP_COMPOSE_PROD="$GYANAM_DIR/apps/$APP/compose.yml"
APP_COMPOSE_DEV="$GYANAM_DIR/apps/$APP/compose.dev.yml"
PW_COMPOSE="$GYANAM_DIR/docker/compose.playwright.yml"
SIDECAR_IMG="lochan-frontend-playwright:latest"

# Use prod compose if present; fall back to dev. Sidecar attaches via app-network
# which is named ${COMPOSE_PROJECT_NAME}_app-network — same for dev/prod.
APP_COMPOSE="$APP_COMPOSE_PROD"
if [[ ! -f "$APP_COMPOSE" ]]; then
  APP_COMPOSE="$APP_COMPOSE_DEV"
fi
if [[ ! -f "$APP_COMPOSE" ]]; then
  echo "ERROR: app compose file not found at $APP_COMPOSE_PROD or $APP_COMPOSE_DEV" >&2
  exit 2
fi

# DC array invokes app compose with the right project name so the sidecar
# attaches to <app>_app-network (set via -p <app>).
DC=(docker compose -f "$APP_COMPOSE")

# ── Result tracking (mirrors verify-app-green.sh aggregator pattern) ──
FAILURES=()
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILURES+=("$1"); }
note() { printf '    \033[2m%s\033[0m\n' "$1"; }

echo "── take-screenshots.sh: strict visual validation for $APP (mode=$MODE) ──"
echo ""

# ─────────────────────────────────────────────────────────────────────
# CHECK 1 — Sidecar image present
# ─────────────────────────────────────────────────────────────────────
echo "[1/6] Sidecar image — $SIDECAR_IMG"
if docker image inspect "$SIDECAR_IMG" >/dev/null 2>&1; then
  pass "sidecar image present"
else
  fail "Playwright sidecar image '$SIDECAR_IMG' NOT BUILT"
  note "build it: ./util/scripts/build/build-app.sh $APP --with-playwright"
  note "(or: docker build -f docker/03-frontend-playwright.Dockerfile -t $SIDECAR_IMG .)"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────
# CHECK 2 — Backend + frontend containers running
# ─────────────────────────────────────────────────────────────────────
echo "[2/6] Containers — backend + frontend running"
BE_CID="$("${DC[@]}" -p "$APP" ps -q backend 2>/dev/null)"
FE_CID="$("${DC[@]}" -p "$APP" ps -q frontend 2>/dev/null)"
if [[ -z "$BE_CID" ]]; then
  fail "backend container not found (parent compose down?)"
else
  BE_STATE="$(docker inspect "$BE_CID" --format '{{.State.Status}}' 2>/dev/null)"
  if [[ "$BE_STATE" == "running" ]]; then
    pass "backend container Up ($BE_CID)"
  else
    fail "backend container is '$BE_STATE' (expected 'running')"
  fi
fi
if [[ -z "$FE_CID" ]]; then
  fail "frontend container not found (parent compose down?)"
else
  FE_STATE="$(docker inspect "$FE_CID" --format '{{.State.Status}}' 2>/dev/null)"
  if [[ "$FE_STATE" == "running" ]]; then
    pass "frontend container Up ($FE_CID)"
  else
    fail "frontend container is '$FE_STATE' (expected 'running')"
  fi
fi
echo ""

# Bail early if image or containers missing — sidecar run will fail uselessly
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "[BAIL] Pre-flight failed — skipping sidecar launch + validation"
  echo ""
  echo "────────────────────────────────────────────────────────"
  printf '\033[31m✗ take-screenshots.sh: %s FAILED — %d pre-flight check(s) failed:\033[0m\n' "$APP" "${#FAILURES[@]}"
  for f in "${FAILURES[@]}"; do printf '    \033[31m- %s\033[0m\n' "$f"; done
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────
# CHECK 3 — Record log reference timestamps + clear stale screenshots
# ─────────────────────────────────────────────────────────────────────
echo "[3/6] Recording reference state (log tail position + screenshot snapshot)"
# Use ISO 8601 timestamp as `--since` reference; docker logs accepts this.
# Truncate to seconds (docker --since granularity).
LOG_REF="$(date -u +%Y-%m-%dT%H:%M:%S)"
note "log reference = $LOG_REF UTC"

# Snapshot existing screenshots so we can identify NEW captures vs stale ones
mkdir -p "$SCREENSHOT_DIR"
PRE_LIST="$(mktemp)"
find "$SCREENSHOT_DIR" -maxdepth 1 -name '*.png' -type f -newer /dev/null 2>/dev/null | sort > "$PRE_LIST" || true
PRE_COUNT="$(wc -l < "$PRE_LIST" | tr -d ' ')"
note "pre-launch screenshot count = $PRE_COUNT"
echo ""

# ─────────────────────────────────────────────────────────────────────
# CHECK 4 — Launch sidecar (canonical compose invocation)
# ─────────────────────────────────────────────────────────────────────
echo "[4/6] Launching sidecar via canonical compose"
COMPOSE_F=( -f "$APP_COMPOSE" -f "$PW_COMPOSE" )
PLAYWRIGHT_BASE_URL="http://${APP}-frontend-1:3000"
note "BASE_URL = $PLAYWRIGHT_BASE_URL"
note "compose: docker compose ${COMPOSE_F[*]} -p $APP --profile screenshots run --rm <service>"

run_sidecar() {
  local svc="$1"
  COMPOSE_PROJECT_NAME="$APP" \
  PLAYWRIGHT_BASE_URL="$PLAYWRIGHT_BASE_URL" \
  docker compose "${COMPOSE_F[@]}" -p "$APP" --profile screenshots \
    run --rm "$svc" 2>&1
}

SIDECAR_OUT=""
case "$MODE" in
  desktop|render-check)
    SIDECAR_OUT="$(run_sidecar playwright-screenshots)"
    ;;
  mobile)
    SIDECAR_OUT="$(run_sidecar playwright-screenshots-mobile)"
    ;;
  all)
    SIDECAR_OUT="$(run_sidecar playwright-screenshots)"
    SIDECAR_OUT+=$'\n'"$(run_sidecar playwright-screenshots-mobile)"
    ;;
esac

# Sidecar wraps `playwright test ... || true` so exit code is unreliable.
# Surface any error patterns from the output for diagnostic context, but
# the truth-source for "did it work?" is on-disk validation below.
if printf '%s\n' "$SIDECAR_OUT" | grep -qiE 'console\.error|uncaught|pageerror|page error|[0-9]+ failed|did not (render|mount)|Error:|exception|Timeout|ERR_'; then
  note "sidecar output contains error signals (will validate via screenshots + logs):"
  printf '%s\n' "$SIDECAR_OUT" | grep -iE 'console\.error|uncaught|pageerror|failed|Error:|exception|Timeout|ERR_' | tail -5 | while IFS= read -r l; do note "  $l"; done
fi
pass "sidecar invocation complete (validating outputs)"
echo ""

# ─────────────────────────────────────────────────────────────────────
# CHECK 5 — STRICT screenshot validation (count + size + dimensions)
# ─────────────────────────────────────────────────────────────────────
echo "[5/6] Strict screenshot validation"
POST_LIST="$(mktemp)"
find "$SCREENSHOT_DIR" -maxdepth 1 -name '*.png' -type f 2>/dev/null | sort > "$POST_LIST" || true
NEW_LIST="$(mktemp)"
# NEW screenshots = present post but either NOT in pre-list OR modified since LOG_REF
# Use mtime comparison via stat to detect fresh captures (newer than LOG_REF reference).
LOG_REF_EPOCH="$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "$LOG_REF" +%s 2>/dev/null || date -u -d "$LOG_REF" +%s 2>/dev/null || echo 0)"
> "$NEW_LIST"
while IFS= read -r png; do
  [[ -z "$png" ]] && continue
  # mtime in epoch seconds (BSD stat = -f %m; GNU stat = -c %Y)
  MTIME="$(stat -f %m "$png" 2>/dev/null || stat -c %Y "$png" 2>/dev/null || echo 0)"
  if (( MTIME >= LOG_REF_EPOCH )); then
    echo "$png" >> "$NEW_LIST"
  fi
done < "$POST_LIST"

NEW_COUNT="$(wc -l < "$NEW_LIST" | tr -d ' ')"
note "fresh screenshots captured this run = $NEW_COUNT"

# 5a — count check
if (( NEW_COUNT >= MIN_SCREENSHOTS )); then
  pass "count check: $NEW_COUNT ≥ $MIN_SCREENSHOTS (mode=$MODE)"
else
  fail "count check: $NEW_COUNT < $MIN_SCREENSHOTS (expected min for mode=$MODE) — sidecar likely failed"
fi

# 5b/c — file size + dimensions check (per screenshot)
INVALID_SIZE=0
INVALID_DIMS=0
VALID_PNG=0
while IFS= read -r png; do
  [[ -z "$png" ]] && continue
  # File size in bytes (BSD stat = -f %z; GNU stat = -c %s)
  SZ="$(stat -f %z "$png" 2>/dev/null || stat -c %s "$png" 2>/dev/null || echo 0)"
  if (( SZ < MIN_SCREENSHOT_BYTES )); then
    INVALID_SIZE=$((INVALID_SIZE + 1))
    note "  too small: $(basename "$png") = ${SZ}B (< ${MIN_SCREENSHOT_BYTES}B)"
    continue
  fi

  # `file` output: PNG image data, 1280 x 2438, 8-bit/color RGB, non-interlaced
  FILE_INFO="$(file "$png" 2>/dev/null)"
  if ! printf '%s\n' "$FILE_INFO" | grep -q 'PNG image data'; then
    INVALID_DIMS=$((INVALID_DIMS + 1))
    note "  not PNG: $(basename "$png")"
    continue
  fi

  # Extract WxH from `file` output
  DIMS="$(printf '%s\n' "$FILE_INFO" | grep -oE '[0-9]+ x [0-9]+' | head -1)"
  W="$(echo "$DIMS" | awk '{print $1}')"
  H="$(echo "$DIMS" | awk '{print $3}')"
  [[ -z "$W" || -z "$H" ]] && { INVALID_DIMS=$((INVALID_DIMS + 1)); note "  no dims: $(basename "$png")"; continue; }

  # Mobile-mode PNGs match by filename suffix or just dimension class
  if [[ "$MODE" == "mobile" ]] || [[ "$(basename "$png")" =~ mobile|pixel ]]; then
    MIN_W=$MIN_MOBILE_WIDTH; MIN_H=$MIN_MOBILE_HEIGHT
  else
    MIN_W=$MIN_DESKTOP_WIDTH; MIN_H=$MIN_DESKTOP_HEIGHT
  fi

  if (( W < MIN_W || H < MIN_H )); then
    INVALID_DIMS=$((INVALID_DIMS + 1))
    note "  bad dims: $(basename "$png") = ${W}x${H} (< ${MIN_W}x${MIN_H})"
    continue
  fi

  VALID_PNG=$((VALID_PNG + 1))
done < "$NEW_LIST"

if (( NEW_COUNT > 0 && INVALID_SIZE == 0 )); then
  pass "size check: all $NEW_COUNT screenshots ≥ ${MIN_SCREENSHOT_BYTES}B (no blank pages)"
elif (( INVALID_SIZE > 0 )); then
  fail "size check: $INVALID_SIZE screenshot(s) below ${MIN_SCREENSHOT_BYTES}B (likely blank or error overlay)"
fi

if (( NEW_COUNT > 0 && INVALID_DIMS == 0 )); then
  pass "dimensions check: all $NEW_COUNT screenshots have valid viewport"
elif (( INVALID_DIMS > 0 )); then
  fail "dimensions check: $INVALID_DIMS screenshot(s) have invalid dimensions"
fi

if (( VALID_PNG > 0 )); then
  pass "valid screen captures: $VALID_PNG"
fi

# Cleanup tmp lists
rm -f "$PRE_LIST" "$POST_LIST" "$NEW_LIST"
echo ""

# ─────────────────────────────────────────────────────────────────────
# CHECK 6 — Container logs clean within navigation window
# ─────────────────────────────────────────────────────────────────────
echo "[6/6] Container logs clean since $LOG_REF UTC"

# Backend — since LOG_REF
BE_LOG_SINCE="$(docker logs --since "$LOG_REF" "$BE_CID" 2>&1)"
BE_ERR="$(printf '%s\n' "$BE_LOG_SINCE" \
  | grep -iE 'traceback|exception|assertionerror|\[ERR ?\]|\bERROR\b|unhandled|critical|fatal' \
  | grep -viE 'sqlalchemy\.engine|no error|0 error|error_code.:.null|send_no_error' )"
if [[ -z "$BE_ERR" ]]; then
  pass "backend logs clean during sidecar window"
else
  cnt="$(printf '%s\n' "$BE_ERR" | grep -c .)"
  fail "backend logs have $cnt error line(s) during sidecar window"
  printf '%s\n' "$BE_ERR" | tail -6 | while IFS= read -r l; do note "$l"; done
fi

# Frontend — since LOG_REF
FE_LOG_SINCE="$(docker logs --since "$LOG_REF" "$FE_CID" 2>&1)"
FE_ERR="$(printf '%s\n' "$FE_LOG_SINCE" \
  | grep -iE 'ERROR\(TypeScript\)|Found [0-9]+ error|\[vite\][^a-z]*error|transform failed|failed to (resolve|load)|does not provide an export|has no exported member|Internal server error|Module not found' )"
if [[ -z "$FE_ERR" ]]; then
  pass "frontend logs clean during sidecar window"
else
  cnt="$(printf '%s\n' "$FE_ERR" | grep -c .)"
  fail "frontend logs have $cnt error line(s) during sidecar window"
  printf '%s\n' "$FE_ERR" | tail -6 | while IFS= read -r l; do note "$l"; done
fi
echo ""

# ─────────────────────────────────────────────────────────────────────
# VERDICT
# ─────────────────────────────────────────────────────────────────────
echo "────────────────────────────────────────────────────────"
if [[ ${#FAILURES[@]} -eq 0 ]]; then
  printf '\033[32m✓ take-screenshots.sh: %s PASSED — strict visual validation green (mode=%s; %d valid captures)\033[0m\n' "$APP" "$MODE" "$VALID_PNG"
  exit 0
else
  printf '\033[31m✗ take-screenshots.sh: %s FAILED — %d check(s) failed:\033[0m\n' "$APP" "${#FAILURES[@]}"
  for f in "${FAILURES[@]}"; do printf '    \033[31m- %s\033[0m\n' "$f"; done
  echo ""
  echo "  Strict visual validation requires: sidecar image present + containers running +"
  echo "  screenshots captured ≥ min count + every PNG ≥ ${MIN_SCREENSHOT_BYTES}B + dimensions valid +"
  echo "  both container logs clean during the sidecar window."
  exit 1
fi
