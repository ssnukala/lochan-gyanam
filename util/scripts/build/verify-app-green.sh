#!/usr/bin/env bash
# verify-app-green.sh — canonical FULL-STACK green check for a Lochan app
#
# Usage:
#   ./util/scripts/build/verify-app-green.sh <app>            # full 5-gate green check
#   ./util/scripts/build/verify-app-green.sh fwprod01
#   ./util/scripts/build/verify-app-green.sh <app> --no-screenshot   # skip the headless render gate
#
# WHY THIS EXISTS (founder directive 2026-06-07):
#   "fwprod is green when both frontend and backend logs are clean and the url
#    actually pulls up the site without any errors."
#   The build session repeatedly declared an app "green" off `daksh verify`
#   (backend-centric: health/manifest/schema/auth/patent) WITHOUT checking the
#   frontend container state, the frontend logs, or whether the URL actually
#   renders. That under-verification shipped 3 false-green claims (MSG-013/017/018)
#   while the frontend was down (Layer-6 compose drift) and then while the SPA had
#   14 TypeScript errors + backend OAuth was broken (MSG-022). This script encodes
#   the REAL definition of green so it never relies on judgment again.
#
# GREEN = ALL FIVE gates pass:
#   1. CONTAINERS  — every service (backend + frontend + postgres) is `running`/Up
#                    (NOT `created`/`exited`/`restarting`)
#   2. BACKEND LOG — no ERROR / Traceback / Exception / AssertionError
#                    (excludes sqlalchemy.engine echo noise)
#   3. FRONTEND LOG— no Vite/TypeScript compile errors (ERROR(TypeScript) /
#                    "Found N errors" / [vite] error / transform failed)
#   4. BACKEND URL — GET <backend>/health → 200
#   5. FRONTEND URL— GET <frontend>/ → 200 AND headless render is clean
#                    (daksh screenshot — Playwright; catches runtime/console errors
#                     the SPA throws on load, e.g. missing module exports)
#
# Exit 0 only if ALL gates pass. Any gate fails → exit 1 + a per-gate report.
# NEVER claim an app green without this returning 0.
#
# Memory rules referenced:
#   - feedback-fwprod01-canonical-test-build-app (fwprod01 = framework verify target)
#   - feedback-endpoint-prefix-mismatch-vs-image-staleness-discrimination (4-class triage on a RED gate)
#   - feedback-multi-layer-bug-stack-honest-disclosure (surface ALL failing gates, not the first)

set -uo pipefail   # NOT -e: we want to run every gate + aggregate, not bail on first failure

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GYANAM_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FRAMEWORK_DIR="$GYANAM_DIR/framework/lochan"
DAKSH_CLI="$FRAMEWORK_DIR/packages/daksh/daksh-cli"
VENV_ACTIVATE="$FRAMEWORK_DIR/.venv/bin/activate"

# ── Arg parsing ──
if [[ $# -lt 1 ]]; then
  echo "ERROR: app name required" >&2
  echo "Usage: $0 <app> [--no-screenshot]" >&2
  exit 2
fi
APP="$1"; shift || true
DO_SCREENSHOT=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-screenshot) DO_SCREENSHOT=0; shift ;;
    *) echo "ERROR: unknown flag $1" >&2; exit 2 ;;
  esac
done

COMPOSE="$GYANAM_DIR/apps/$APP/compose.dev.yml"
if [[ ! -f "$COMPOSE" ]]; then
  echo "ERROR: compose file not found: $COMPOSE" >&2
  exit 2
fi
DC=(docker compose -f "$COMPOSE")

# ── Result tracking ──
FAILURES=()
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILURES+=("$1"); }
note() { printf '    \033[2m%s\033[0m\n' "$1"; }

echo "── verify-app-green.sh: full-stack green check for $APP ──"
echo ""

# ─────────────────────────────────────────────────────────────────────
# GATE 1 — CONTAINERS: every service Up (not created/exited/restarting)
# ─────────────────────────────────────────────────────────────────────
echo "[1/5] Containers — all services running"
SERVICES="$("${DC[@]}" config --services 2>/dev/null)"
if [[ -z "$SERVICES" ]]; then
  fail "could not enumerate services from $COMPOSE"
else
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    cid="$("${DC[@]}" ps -q "$svc" 2>/dev/null)"
    if [[ -z "$cid" ]]; then
      fail "service '$svc' has no container (never created / removed)"
      continue
    fi
    state="$(docker inspect "$cid" --format '{{.State.Status}}' 2>/dev/null)"
    exitc="$(docker inspect "$cid" --format '{{.State.ExitCode}}' 2>/dev/null)"
    err="$(docker inspect "$cid" --format '{{.State.Error}}' 2>/dev/null)"
    if [[ "$state" == "running" ]]; then
      pass "service '$svc' is Up"
    else
      fail "service '$svc' is '$state' (exit=$exitc)"
      [[ -n "$err" ]] && note "container error: $err"
    fi
  done <<< "$SERVICES"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────
# GATE 2 — BACKEND LOG clean
# ─────────────────────────────────────────────────────────────────────
echo "[2/5] Backend logs — no errors/tracebacks"
BE_LOG="$("${DC[@]}" logs backend 2>&1)"
# Exclude sqlalchemy.engine echo lines + the literal word in non-error context.
BE_ERR="$(printf '%s\n' "$BE_LOG" \
  | grep -iE 'traceback|exception|assertionerror|\[ERR ?\]|\bERROR\b|unhandled|critical|fatal' \
  | grep -viE 'sqlalchemy\.engine|no error|0 error|error_code.:.null|send_no_error' )"
if [[ -z "$BE_ERR" ]]; then
  pass "backend logs clean"
else
  cnt="$(printf '%s\n' "$BE_ERR" | grep -c .)"
  fail "backend logs have $cnt error line(s)"
  printf '%s\n' "$BE_ERR" | tail -8 | while IFS= read -r l; do note "$l"; done
fi
echo ""

# ─────────────────────────────────────────────────────────────────────
# GATE 3 — FRONTEND LOG clean (Vite / TypeScript compile)
# ─────────────────────────────────────────────────────────────────────
echo "[3/5] Frontend logs — no Vite/TypeScript errors"
FE_LOG="$("${DC[@]}" logs frontend 2>&1)"
FE_ERR="$(printf '%s\n' "$FE_LOG" \
  | grep -iE 'ERROR\(TypeScript\)|Found [0-9]+ error|\[vite\][^a-z]*error|transform failed|failed to (resolve|load)|does not provide an export|has no exported member|Internal server error' )"
if [[ -z "$FE_ERR" ]]; then
  pass "frontend logs clean"
else
  cnt="$(printf '%s\n' "$FE_ERR" | grep -c .)"
  fail "frontend logs have $cnt error line(s)"
  printf '%s\n' "$FE_ERR" | tail -10 | while IFS= read -r l; do note "$l"; done
fi
echo ""

# ─────────────────────────────────────────────────────────────────────
# GATE 4 — BACKEND URL /health → 200
# ─────────────────────────────────────────────────────────────────────
echo "[4/5] Backend URL — /health 200"
BE_HOSTPORT="$("${DC[@]}" port backend 5001 2>/dev/null | head -1)"
if [[ -z "$BE_HOSTPORT" ]]; then
  fail "could not resolve backend published port (service down?)"
else
  BE_PORT="${BE_HOSTPORT##*:}"
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${BE_PORT}/health" 2>/dev/null)"
  if [[ "$code" == "200" ]]; then
    pass "GET http://localhost:${BE_PORT}/health → 200"
  else
    fail "GET http://localhost:${BE_PORT}/health → ${code:-no-response}"
  fi
fi
echo ""

# ─────────────────────────────────────────────────────────────────────
# GATE 5 — FRONTEND URL 200 + headless render clean
# ─────────────────────────────────────────────────────────────────────
echo "[5/5] Frontend URL — / 200 + headless render clean"
FE_HOSTPORT="$("${DC[@]}" port frontend 3000 2>/dev/null | head -1)"
if [[ -z "$FE_HOSTPORT" ]]; then
  fail "could not resolve frontend published port (service down?)"
else
  FE_PORT="${FE_HOSTPORT##*:}"
  FE_URL="http://localhost:${FE_PORT}/"
  code="$(curl -s -o /dev/null -w '%{http_code}' "$FE_URL" 2>/dev/null)"
  if [[ "$code" == "200" ]]; then
    pass "GET ${FE_URL} → 200"
  else
    fail "GET ${FE_URL} → ${code:-no-response}"
  fi

  # Headless RENDER via the canonical Playwright SIDECAR (Tier-3).
  # A 200 on the HTML shell does NOT mean the SPA actually mounts — a runtime
  # error on load (e.g. a missing module export like `read`/`write`) throws in
  # the browser, blanks the page, and NEVER shows up in curl. The sidecar drives
  # a real chromium against the app-network frontend and fails the render if the
  # page errors. This gate is the founder's "the url actually pulls up the site
  # without any errors" requirement — REQUIRES the sidecar (lochan-frontend-playwright).
  if [[ $DO_SCREENSHOT -eq 1 ]]; then
    SIDECAR_IMG="lochan-frontend-playwright:latest"
    PW_COMPOSE="$GYANAM_DIR/docker/compose.playwright.yml"
    APP_COMPOSE_PROD="$GYANAM_DIR/apps/$APP/compose.yml"

    if ! docker image inspect "$SIDECAR_IMG" >/dev/null 2>&1; then
      fail "Playwright sidecar image '$SIDECAR_IMG' NOT BUILT — cannot run render gate"
      note "build it: ./util/scripts/build/build-app.sh $APP --with-playwright"
      note "(or: docker build -f docker/03-frontend-playwright.Dockerfile -t $SIDECAR_IMG .)"
    elif [[ ! -f "$PW_COMPOSE" ]]; then
      fail "sidecar compose not found: $PW_COMPOSE"
    else
      # Prefer the daksh wrapper (single-URL capture) when available; it drives
      # the sidecar under the hood. Fall back to the canonical compose run.
      RENDER_OUT=""
      if [[ -f "$VENV_ACTIVATE" && -x "$DAKSH_CLI" ]]; then
        # shellcheck source=/dev/null
        source "$VENV_ACTIVATE"
        RENDER_OUT="$(APP="$APP" "$DAKSH_CLI" screenshot "$APP" --url "$FE_URL" 2>&1)"
      else
        # Canonical opt-in sidecar run (app-agnostic; attaches to <app>_app-network).
        COMPOSE_F=( -f "${APP_COMPOSE_PROD:-$COMPOSE}" -f "$PW_COMPOSE" )
        RENDER_OUT="$(APP="$APP" PLAYWRIGHT_BASE_URL="http://${APP}-frontend-1:3000" \
          docker compose "${COMPOSE_F[@]}" --profile screenshots \
          run --rm playwright-screenshots 2>&1)"
      fi
      # The sidecar wraps `playwright test ... || true`, so exit code is unreliable;
      # inspect output for render/console failures.
      if printf '%s\n' "$RENDER_OUT" | grep -qiE 'console\.error|uncaught|pageerror|page error|[0-9]+ failed|did not (render|mount)|Error:|exception|Timeout|ERR_'; then
        fail "headless render REPORTED ERRORS — URL returns 200 but the SPA errors on load"
        printf '%s\n' "$RENDER_OUT" | grep -iE 'console\.error|uncaught|pageerror|failed|Error:|exception|Timeout|ERR_' | tail -8 | while IFS= read -r l; do note "$l"; done
      elif printf '%s\n' "$RENDER_OUT" | grep -qiE 'capture complete|screenshot|✓|passed|\.png'; then
        pass "headless render clean (Playwright sidecar)"
      else
        fail "headless render produced no success signal — treat as RED (inspect output)"
        printf '%s\n' "$RENDER_OUT" | tail -8 | while IFS= read -r l; do note "$l"; done
      fi
    fi
  else
    note "headless render skipped (--no-screenshot) — NOT a full green; gate 5 render unproven"
  fi
fi
echo ""

# ─────────────────────────────────────────────────────────────────────
# VERDICT
# ─────────────────────────────────────────────────────────────────────
echo "────────────────────────────────────────────────────────"
if [[ ${#FAILURES[@]} -eq 0 ]]; then
  printf '\033[32m✓ %s is GREEN — all 5 gates passed (containers + backend log + frontend log + backend URL + frontend URL/render)\033[0m\n' "$APP"
  exit 0
else
  printf '\033[31m✗ %s is NOT GREEN — %d gate(s) failed:\033[0m\n' "$APP" "${#FAILURES[@]}"
  for f in "${FAILURES[@]}"; do printf '    \033[31m- %s\033[0m\n' "$f"; done
  echo ""
  echo "  Do NOT claim '$APP green' until this returns 0."
  echo "  Triage each RED gate (4-class taxonomy for build/runtime; check container logs)."
  exit 1
fi
