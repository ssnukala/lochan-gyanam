#!/usr/bin/env bash
# build-app.sh — canonical wrapper to build + verify a Lochan app via daksh
#
# Usage:
#   ./util/scripts/build/build-app.sh <app>              # build + verify
#   ./util/scripts/build/build-app.sh <app> --no-verify  # build only
#   ./util/scripts/build/build-app.sh <app> --with-playwright  # also build Tier-3 sidecar
#   ./util/scripts/build/build-app.sh <app> --staging    # build the BUILT app images (domain pkg baked) via compose.staging.yml
#   ./util/scripts/build/build-app.sh <app> --no-cache   # force a clean rebuild (no Docker layer cache) — rebakes edited domain source
#   ./util/scripts/build/build-app.sh fwprod01           # most common — framework canonical test app
#
# --staging vs default:
#   The default (dev) build serves the hot-reload compose. To deploy a LOCAL
#   domain-schema change (e.g. a healed RBAC schema) you need the production-
#   shaped staging surface that bakes the domain package INTO the app image —
#   pass --staging (→ `daksh build --staging`, which selects compose.staging.yml).
#   Pair with --no-cache to force the edited source to rebake (Docker otherwise
#   layer-caches the COPY . /pkg/ step → stale image). Both pass straight through
#   to `daksh build` — this wrapper does not reinvent the build, it wraps it.
#
# What it does:
#   1. Sources the lochan venv (framework/lochan/.venv) so daksh-cli auto-picks the venv's python3
#      (daksh-cli's for-loop scans for python3.13/12/11/10 via `command -v`; activated venv wins)
#   2. Runs `daksh build --from 1 <app>` — Tier 1+ rebuild + container restart
#   3. Runs the 2-step verify (unless --no-verify):
#        a) `daksh verify <app>`               — backend-centric gates
#        b) `verify-app-green.sh <app>`        — FULL-STACK 5-gate green
#           (containers + backend log + frontend log + backend /health 200
#            + frontend / 200 AND Playwright sidecar render clean).
#      Step (b) is the canonical "GREEN" definition per MSG-025 BINDING
#      (founder ratify 2026-06-07): "fwprod is green when both frontend
#      and backend logs are clean and the url actually pulls up the site
#      without any errors". `daksh verify` alone is NOT sufficient.
#   4. With --with-playwright: builds Tier-3 canonical capture-run sidecar
#      (docker/03-frontend-playwright.Dockerfile → lochan-frontend-playwright:latest)
#      per Q-CAPTURE-RUN-BIND-MOUNT-LAYOUT = B founder ratify 2026-05-31.
#      Skipped by default (production builds don't need capture-run substrate).
#
# Why this script exists (per founder 2026-05-21 PM):
#   - Avoid every session reinventing the `source venv && daksh-cli build` invocation
#   - Single canonical entry-point for the dev build+verify loop
#   - PYTHON env-var prefix does NOT work with daksh-cli (line 12 clobbers the inherited var);
#     venv activation is the correct mechanism
#
# Memory rules referenced:
#   - feedback-fwprod01-canonical-test-build-app (fwprod01 = canonical framework verify target)
#   - feedback-s0-owns-merges-and-builds + interactive-session EXCEPTION (developer sessions own
#     full loop including build/verify when iterating on a blocker)
#   - feedback-gh-pr-merge-needs-local-pull (run `git -C framework/lochan pull --ff-only` BEFORE
#     this script if you just merged a PR; this script does NOT pull for you)

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SCRIPT_DIR = <gyanam>/util/scripts/build; GYANAM_DIR = <gyanam> (3 up)
GYANAM_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FRAMEWORK_DIR="$GYANAM_DIR/framework/lochan"
DAKSH_CLI="$FRAMEWORK_DIR/packages/daksh/daksh-cli"
VENV_ACTIVATE="$FRAMEWORK_DIR/.venv/bin/activate"

# ── Arg parsing ──
if [[ $# -lt 1 ]]; then
  echo "ERROR: app name required" >&2
  echo "Usage: $0 <app> [--no-verify] [--with-playwright] [--staging] [--no-cache]" >&2
  echo "Example: $0 fwprod01" >&2
  exit 2
fi

APP="$1"
VERIFY=1
WITH_PLAYWRIGHT=0
# --staging / --no-cache pass straight through to `daksh build` (see header).
STAGING=0
NO_CACHE=0
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-verify) VERIFY=0; shift ;;
    --with-playwright) WITH_PLAYWRIGHT=1; shift ;;
    --staging) STAGING=1; shift ;;
    --no-cache) NO_CACHE=1; shift ;;
    *) echo "ERROR: unknown flag $1" >&2; exit 2 ;;
  esac
done

# ── Safety checks ──
if [[ ! -d "$GYANAM_DIR/apps/$APP" ]]; then
  echo "ERROR: app dir not found: $GYANAM_DIR/apps/$APP" >&2
  exit 2
fi
if [[ ! -x "$DAKSH_CLI" ]]; then
  echo "ERROR: daksh-cli not executable at $DAKSH_CLI" >&2
  exit 2
fi
if [[ ! -f "$VENV_ACTIVATE" ]]; then
  echo "ERROR: lochan venv not found at $VENV_ACTIVATE" >&2
  echo "  Run: uv sync in $FRAMEWORK_DIR to create it" >&2
  exit 2
fi

# ── Activate venv ──
# shellcheck source=/dev/null
source "$VENV_ACTIVATE"

# ── Build ──
# Assemble the daksh build flags. --staging / --no-cache are pure pass-throughs
# to `daksh build` (they are declared there); this wrapper only forwards them so
# a local domain-schema change can be baked + rebaked without hand-invoking the
# venv + daksh incantation.
BUILD_FLAGS=(--from 1)
[[ $STAGING -eq 1 ]] && BUILD_FLAGS+=(--staging)
[[ $NO_CACHE -eq 1 ]] && BUILD_FLAGS+=(--no-cache)
echo "── build-app.sh: building $APP (${BUILD_FLAGS[*]}) ──"
echo "  Tip: in another terminal, tail pretty-printed progress with:"
echo "    bash $SCRIPT_DIR/watch-daksh-build.sh /tmp/daksh-build.log"
echo "  (filters noise; shows tier completion + per-package installs + errors)"
echo ""
"$DAKSH_CLI" build "${BUILD_FLAGS[@]}" "$APP" 2>&1 | tee /tmp/daksh-build.log

# ── Tier-3 Playwright sidecar (opt-in; Q-CAPTURE-RUN-BIND-MOUNT-LAYOUT = B) ──
#
# Builds lochan-frontend-playwright:latest from docker/03-frontend-playwright.Dockerfile
# when --with-playwright flag is passed. Tier-staleness gate: skip if the
# sidecar image is newer than 02-frontend-base:dev source mtime
# (matches #857 Q-PNPM-OFFLINE-ROOT-CAUSE Option A canonical staleness
# detection pattern — image-mtime vs source-mtime check).
if [[ $WITH_PLAYWRIGHT -eq 1 ]]; then
  echo "── build-app.sh: building Tier-3 Playwright sidecar (capture-run substrate) ──"
  SIDECAR_DOCKERFILE="$GYANAM_DIR/docker/03-frontend-playwright.Dockerfile"
  if [[ ! -f "$SIDECAR_DOCKERFILE" ]]; then
    echo "  ERROR: Tier-3 Dockerfile not found at $SIDECAR_DOCKERFILE" >&2
    exit 2
  fi
  # Tier-staleness: rebuild sidecar if 02-frontend-base:dev image OR
  # framework/lochan/frontend mtime is newer than sidecar image creation.
  # Defer to docker's own layer caching for fine-grained skip; just always
  # invoke the build with --pull=false (rely on local Tier 2 dev base).
  docker build \
    -f "$SIDECAR_DOCKERFILE" \
    -t lochan-frontend-playwright:latest \
    --pull=false \
    "$GYANAM_DIR"
  echo "  ✓ Tier-3 sidecar built: lochan-frontend-playwright:latest"
  echo "  Usage: docker compose -f apps/$APP/compose.yml \\"
  echo "                        -f $GYANAM_DIR/docker/compose.playwright.yml \\"
  echo "                        run --rm playwright-screenshots"
fi

# ── Verify ──
#
# 2-step canonical verify (Build session MSG-025, founder ratify 2026-06-07):
#
#   Step 1: `daksh verify <app>` — backend-centric (health/manifest/schema/
#           auth/patent endpoints). Necessary but NOT sufficient.
#   Step 2: `verify-app-green.sh <app>` — FULL-STACK 5-gate green check
#           (containers running + backend log clean + frontend log clean +
#            backend /health 200 + frontend / 200 AND Playwright sidecar
#            render clean).
#
# Founder directive (verbatim): "fwprod is green when both frontend and
# backend logs are clean and the url actually pulls up the site without
# any errors". `daksh verify` ALONE checks backend gates only — it ships
# false-green when frontend is down OR the SPA errors on render
# (MSG-013/017/018/022). Both gates run; either RED → exit 1.
#
# --no-verify skips BOTH steps. There is no half-verify; per
# [[feedback-discipline-fix-validates-via-n-consecutive-clean-pr-streak]]
# we don't want a build mode that runs "some" verification.
if [[ $VERIFY -eq 1 ]]; then
  VERIFY_RC=0

  echo "── build-app.sh: verifying $APP (Step 1/2 — daksh verify backend gates) ──"
  if "$DAKSH_CLI" verify "$APP"; then
    echo "✓ build-app.sh: $APP daksh verify PASSED (backend gates)"
  else
    echo "✗ build-app.sh: $APP daksh verify FAILED — see output above"
    echo "  Common follow-ups:"
    echo "    - docker logs ${APP}-backend-1 --tail 60       # check actual errors"
    echo "    - docker compose -f apps/$APP/compose.dev.yml down -v && up -d  # if DB state corrupted"
    VERIFY_RC=1
  fi

  echo ""
  echo "── build-app.sh: verifying $APP (Step 2/2 — verify-app-green.sh full-stack 5-gate) ──"
  VERIFY_GREEN_SH="$SCRIPT_DIR/verify-app-green.sh"
  if [[ ! -x "$VERIFY_GREEN_SH" ]]; then
    echo "✗ build-app.sh: verify-app-green.sh missing or not executable at $VERIFY_GREEN_SH" >&2
    echo "  This script is the canonical FULL-STACK green check (MSG-025 BINDING)." >&2
    exit 2
  fi
  if "$VERIFY_GREEN_SH" "$APP"; then
    echo "✓ build-app.sh: $APP verify-app-green.sh PASSED (all 5 gates GREEN)"
  else
    echo "✗ build-app.sh: $APP verify-app-green.sh FAILED — see per-gate report above"
    VERIFY_RC=1
  fi

  if [[ $VERIFY_RC -eq 0 ]]; then
    echo "✓ build-app.sh: $APP BUILT + VERIFIED GREEN (daksh verify + verify-app-green.sh both PASS)"
  else
    echo "✗ build-app.sh: $APP verify FAILED — at least one of (daksh verify | verify-app-green.sh) RED"
    exit 1
  fi
fi
