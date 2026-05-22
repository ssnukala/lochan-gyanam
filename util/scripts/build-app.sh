#!/usr/bin/env bash
# build-app.sh — canonical wrapper to build + verify a Lochan app via daksh
#
# Usage:
#   ./util/scripts/build-app.sh <app>              # build + verify
#   ./util/scripts/build-app.sh <app> --no-verify  # build only
#   ./util/scripts/build-app.sh fwprod01           # most common — framework canonical test app
#
# What it does:
#   1. Sources the lochan venv (framework/lochan/.venv) so daksh-cli auto-picks the venv's python3
#      (daksh-cli's for-loop scans for python3.13/12/11/10 via `command -v`; activated venv wins)
#   2. Runs `daksh build --from 1 <app>` — Tier 1+ rebuild + container restart
#   3. Runs `daksh verify <app>` (unless --no-verify)
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
GYANAM_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
FRAMEWORK_DIR="$GYANAM_DIR/framework/lochan"
DAKSH_CLI="$FRAMEWORK_DIR/packages/daksh/daksh-cli"
VENV_ACTIVATE="$FRAMEWORK_DIR/.venv/bin/activate"

# ── Arg parsing ──
if [[ $# -lt 1 ]]; then
  echo "ERROR: app name required" >&2
  echo "Usage: $0 <app> [--no-verify]" >&2
  echo "Example: $0 fwprod01" >&2
  exit 2
fi

APP="$1"
VERIFY=1
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-verify) VERIFY=0; shift ;;
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
echo "── build-app.sh: building $APP ──"
echo "  Tip: in another terminal, tail pretty-printed progress with:"
echo "    bash $SCRIPT_DIR/watch-daksh-build.sh /tmp/daksh-build.log"
echo "  (filters noise; shows tier completion + per-package installs + errors)"
echo ""
"$DAKSH_CLI" build --from 1 "$APP" 2>&1 | tee /tmp/daksh-build.log

# ── Verify ──
if [[ $VERIFY -eq 1 ]]; then
  echo "── build-app.sh: verifying $APP ──"
  if "$DAKSH_CLI" verify "$APP"; then
    echo "✓ build-app.sh: $APP BUILT + VERIFIED GREEN"
  else
    echo "✗ build-app.sh: $APP verify FAILED — see output above"
    echo "  Common follow-ups:"
    echo "    - docker logs ${APP}-backend-1 --tail 60       # check actual errors"
    echo "    - docker compose -f apps/$APP/compose.dev.yml down -v && up -d  # if DB state corrupted"
    exit 1
  fi
fi
