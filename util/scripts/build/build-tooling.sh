#!/usr/bin/env bash
# build-tooling.sh — the sanctioned build path for the daksh DooD tooling image.
#
# Builds lochan-backend-dev:latest from docker/03-backend-dev.Dockerfile (base +
# daksh[dev] + the static docker CLI). This is the DEV/CI image the `daksh install`
# tooling sidecar (docker/compose.tooling.yml) runs, so the wizard's build/deploy
# verbs work on a venv-less host.
#
# Usage:
#   ./util/scripts/build/build-tooling.sh
#
# WHY THIS IS STANDALONE (not a --with-tooling flag on build-app.sh):
#   The tooling image is `FROM lochan-backend-base` and INDEPENDENT of any app —
#   it has nothing to do with a carrier app's build or verify. The original
#   `build-app.sh --with-tooling` flag coupled it to an app build that runs first
#   under `set -euo pipefail`: when the carrier app's `daksh build` returned
#   non-zero (a later tier failing — e.g. fwtest01 "deployer build — FAIL"), the
#   script aborted at that pipe BEFORE ever reaching the tooling block, so the
#   image never built even though the base was present. Decoupling is the fix at
#   source: the tooling image builds whenever the base exists, regardless of any
#   app. (Same sanctioned-wrapper role as build-app.sh — it wraps the raw image
#   build the check-tooling hook blocks, so the build goes through a permitted
#   path.)
#
# Precedent: build-app.sh's --with-playwright builds a sidecar IMAGE the same way
# (Dockerfile-existence guard + `docker build --pull=false`); this script is the
# app-independent equivalent for the backend tooling image.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SCRIPT_DIR = <gyanam>/util/scripts/build; GYANAM_DIR = <gyanam> (3 up).
GYANAM_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TOOLING_DOCKERFILE="$GYANAM_DIR/docker/03-backend-dev.Dockerfile"
BASE_IMAGE="lochan-backend-base:latest"
TOOLING_IMAGE="lochan-backend-dev:latest"

# ── Preconditions (fail loud, never silent) ──
if [[ ! -f "$TOOLING_DOCKERFILE" ]]; then
  echo "ERROR: tooling Dockerfile not found at $TOOLING_DOCKERFILE" >&2
  exit 2
fi
# The dev image is FROM the base; a missing base would emit a confusing FROM
# error mid-build. Fail loud with the exact remedy instead.
if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
  echo "ERROR: $BASE_IMAGE absent — the tooling image is FROM it." >&2
  echo "  Build the base first (any app build produces it at Tier ≤1), e.g.:" >&2
  echo "    $SCRIPT_DIR/build-app.sh fwprod01 --no-verify" >&2
  exit 2
fi

# ── Build ──
echo "── build-tooling.sh: building daksh DooD tooling image ($TOOLING_IMAGE) ──"
docker build \
  -f "$TOOLING_DOCKERFILE" \
  -t "$TOOLING_IMAGE" \
  --pull=false \
  "$GYANAM_DIR"

# ── Verify the image actually carries the docker CLI (the whole point) ──
# The DooD sidecar is useless without a working `docker` client in the image;
# assert it here so a broken build fails the script rather than surfacing later
# as an rc=127 mid-wizard.
echo "── build-tooling.sh: verifying the docker CLI is present in $TOOLING_IMAGE ──"
docker run --rm --entrypoint sh "$TOOLING_IMAGE" -c 'docker --version'

echo "  ✓ Tooling image built + verified: $TOOLING_IMAGE (daksh[dev] + docker CLI)"
echo "  Usage: docker compose -f $GYANAM_DIR/docker/compose.tooling.yml \\"
echo "                        run --rm daksh-tooling install --app <app> --silent"
