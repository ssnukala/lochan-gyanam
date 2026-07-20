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
#                    AND screenshots show ACTUAL Lochan content (not blank, not
#                    error overlay). Gate 5 delegates to take-screenshots.sh
#                    --render-check which: launches the canonical Playwright
#                    sidecar, validates screenshot count/size/dimensions, AND
#                    re-checks both container logs during the navigation window.
#                    Per founder verbatim 2026-06-07: "for verify green the
#                    session has to launch the side car and launch frontend
#                    page and verify both frontend and backed logs are clear
#                    and that the screenshots show actual lochan screens".
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
DAKSH_CLI="$GYANAM_DIR/util/scripts/daksh-docker"  # shared shim: host venv or containerized (server has no venv)
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
# Build session MSG-042 2026-06-07: gate-2 was false-RED'ing on
# WARNING lines. Two compounding causes:
#   (1) the inclusion grep was case-insensitive (`-iE`), so `exception`
#       (lowercase) matched the word inside `WARNING: ConnectionPool
#       exception retry` — a benign WARN-level operational notice, NOT
#       a Python `Exception:` print or `Traceback`. Same trap for the
#       lowercase tokens `critical` / `fatal` / `unhandled` — which all
#       appear inside WARNING messages as plain English nouns.
#   (2) the substring `\bERROR\b` plus `-i` matched the word `Error` /
#       `error` inside WARN message text (e.g. `WARNING: error_handler
#       installed`).
# Fix: drop `-iE` → `-E` (case-sensitive), require all level tokens to
# be UPPERCASE + word-bounded (matches Python `logging` level emission
# `ERROR` / `CRITICAL` / `FATAL` exactly, NOT lowercase descriptive
# prose). Keep `Traceback` (capital T) + `Exception:` (capital E + colon)
# + `AssertionError` as the canonical Python exception markers — those
# are emitted verbatim by the runtime in that case. Belt-and-suspenders:
# add `WARNING|^WARN |WARN:` to the exclusion grep so even if a line
# slips through the inclusion pattern, an explicit WARN line is rejected.
#
# False-positive matrix (pre-fix → post-fix):
#   `WARNING: deprecation notice`                  | RED → GREEN ✓
#   `WARNING: ConnectionPool exception retry`      | RED → GREEN ✓
#   `WARNING: critical_section disabled`           | RED → GREEN ✓
#   `WARNING:root:fatal_on_disconnect=false`       | RED → GREEN ✓
#   `WARN  some.module: error_handler installed`   | RED → GREEN ✓
#   `INFO: Found 0 errors`                         | GREEN → GREEN ✓
#   `ERROR: failed to connect`                     | RED → RED ✓
#   `Traceback (most recent call last):`           | RED → RED ✓
#   `Exception: bare runtime crash`                | RED → RED ✓
#   `AssertionError: test invariant broken`        | RED → RED ✓
#   `CRITICAL:root:db_unreachable`                 | RED → RED ✓
#   `FATAL: unrecoverable boot failure`            | RED → RED ✓
echo "[2/5] Backend logs — no errors/tracebacks"
BE_LOG="$("${DC[@]}" logs backend 2>&1)"
# Inclusion: uppercase/canonical exception markers ONLY (case-sensitive).
# Exclusion: sqlalchemy.engine echo noise + benign `no/0 error` phrases +
# WARN/WARNING level lines (defense-in-depth against future drift).
BE_ERR="$(printf '%s\n' "$BE_LOG" \
  | grep -E 'Traceback|Exception:|AssertionError|\[ERR ?\]|\bERROR\b|\bCRITICAL\b|\bFATAL\b' \
  | grep -viE 'sqlalchemy\.engine|no error|0 error|error_code.:.null|send_no_error|^[^:]*WARNING|^[^:]*\bWARN\b' )"
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
# NOTE: `Found [1-9][0-9]* error` (NOT `Found [0-9]+ error`) — the looser
# pattern false-RED'd on the CLEAN signal `[TypeScript] Found 0 errors`
# (Build session MSG-032 §"Bug in the merged green gate itself" 2026-06-07).
# Zero errors is exactly what we WANT; only N≥1 should trip the gate.
FE_ERR="$(printf '%s\n' "$FE_LOG" \
  | grep -iE 'ERROR\(TypeScript\)|Found [1-9][0-9]* error|\[vite\][^a-z]*error|transform failed|failed to (resolve|load)|does not provide an export|has no exported member|Internal server error' )"
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

  # Headless RENDER via take-screenshots.sh --render-check (canonical
  # composition; see [[feedback-composition-pattern-over-parallel-mirror]]).
  #
  # A 200 on the HTML shell does NOT mean the SPA actually mounts — a runtime
  # error on load (e.g. a missing module export like `read`/`write`) throws in
  # the browser, blanks the page, and NEVER shows up in curl. AND a "clean"
  # sidecar run is not enough either: blank pages and error overlays still
  # produce PNGs that the prior Gate-5 logic accepted. take-screenshots.sh
  # closes both gaps via STRICT visual validation: sidecar launch + per-PNG
  # size/dimension checks + log-window re-grep. Per founder verbatim 2026-06-07:
  # "for verify green the session has to launch the side car and launch
  # frontend page and verify both frontend and backed logs are clear and
  # that the screenshots show actual lochan screens".
  if [[ $DO_SCREENSHOT -eq 1 ]]; then
    # take-screenshots.sh lives in the sibling screenshots/ dir (moved from
    # build/ 2026-06-20 — screenshot tooling consolidated).
    TAKE_SCREENSHOTS_SH="$SCRIPT_DIR/../screenshots/take-screenshots.sh"
    if [[ ! -x "$TAKE_SCREENSHOTS_SH" ]]; then
      fail "take-screenshots.sh missing or not executable at $TAKE_SCREENSHOTS_SH"
      note "Gate 5 strict visual validation requires take-screenshots.sh (predecessor #39 followup)"
    else
      # Q-S2-04=A (2026-07-11): --render-check now asserts CONTENT (every route
      # mounts with real content — no pageerror / placeholder title / blank DOM /
      # unwired lifecycle UI), reading the render-check spec's JSON verdict. This
      # replaced the byte-size PNG heuristic that passed dead shells (v2 opencats30).
      RENDER_OUT="$("$TAKE_SCREENSHOTS_SH" "$APP" --render-check 2>&1)"
      RENDER_RC=$?
      if [[ $RENDER_RC -eq 0 ]]; then
        pass "render content validation clean (take-screenshots.sh --render-check)"
      else
        fail "render content validation FAILED — a route did not render real content (dead shell / pageerror / blank DOM)"
        # Surface the per-check report from take-screenshots.sh for triage
        printf '%s\n' "$RENDER_OUT" | tail -16 | while IFS= read -r l; do note "$l"; done
      fi
    fi
  else
    note "strict visual validation skipped (--no-screenshot) — NOT a full green; gate 5 render unproven"
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
