#!/usr/bin/env bash
# test-deploy-deps-staleness-gate.sh — regression tests for scripts/deploy-lochan.sh
# Phase 2.5 per-app DEPS-image staleness gate + build-stamp wiring
# (§DEPS-STALENESS-GATE + §8.6 build stamp, 2026-07-08).
#
# THE INCIDENT THIS GUARDS (4th recurrence of the stale-image trap, S1-P1-DEPLOY
# Finding A): apps/<app>/Dockerfile.backend is `FROM <app>-deps:latest`, and the
# deps image pins a SNAPSHOT of the base it was built FROM. Phase 2 rebuilds
# lochan-backend-base:latest correctly, but nothing re-derived the per-app deps
# layer when its base advanced — so a "successful" deploy shipped a container
# without tarkan.metrics (base had it; the deps snapshot predated it). The gate
# rebuilds (or loudly refuses on) any <app>-deps image whose RootFS layer list
# does not start with the CURRENT base image's layers.
#
# Finding B (same discovery): no image path ran `daksh stamp-meta`, so no
# __pkg_meta__.py shipped and every metrics envelope reported
# build.stamped:false. The deploy now stamps BEFORE any image build; these
# tests pin that wiring (presence + ordering) so it can't silently drop out.
#
# Self-contained: extracts the REAL app_deps_base()/layers_prefix_match() from
# the deploy script (test tracks the live implementation, not a copy) and
# asserts:
#   1. app_deps_base reads the FROM image out of apps/<app>/Dockerfile.deps
#      (the Dockerfile is the source of truth — no hardcoded base name)
#   2. app without a Dockerfile.deps → return 1 (no deps layer to gate)
#   3. layers_prefix_match: identical → match; proper prefix → match
#   4. layers_prefix_match: diverged / truncated / digest-boundary → NO match
#   5. layers_prefix_match: empty/null inputs → NO match (fail closed)
#   6. wiring pins: stamp-meta runs before the first docker build; the deps
#      gate rebuilds via build-app.sh --deps-only; --skip-stamp exists as the
#      loud escape hatch (symmetric with --skip-pkg-builds)
#
# Run: bash util/scripts/test-deploy-deps-staleness-gate.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$SCRIPT_DIR/../../scripts/deploy-lochan.sh"
[[ -f "$DEPLOY" ]] || { echo "FAIL: deploy script not found at $DEPLOY" >&2; exit 1; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0; FAIL=0
ok()   { echo "  [✓] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [✗] $1" >&2; FAIL=$((FAIL+1)); }

# ── Harness: extract the REAL helpers from the deploy script ─────────────────
FUNC_FILE="$ROOT/deps_helpers.sh"
awk '/^app_deps_base\(\) \{/{f=1} f{print} f&&/^\}/{f=0}'       "$DEPLOY" >  "$FUNC_FILE"
awk '/^layers_prefix_match\(\) \{/{f=1} f{print} f&&/^\}/{f=0}' "$DEPLOY" >> "$FUNC_FILE"
grep -q 'Dockerfile.deps' "$FUNC_FILE" || { echo "FAIL: extracted app_deps_base missing Dockerfile.deps read (script drifted?)" >&2; exit 1; }
grep -q 'return 1' "$FUNC_FILE"        || { echo "FAIL: extracted layers_prefix_match missing fail-closed branch (script drifted?)" >&2; exit 1; }
# shellcheck disable=SC1090
source "$FUNC_FILE"

GYANAM_DIR="$ROOT/gyanam"

# ── Fixtures ─────────────────────────────────────────────────────────────────
mkdir -p "$GYANAM_DIR/apps/appx" "$GYANAM_DIR/apps/nodeps"
cat > "$GYANAM_DIR/apps/appx/Dockerfile.deps" <<'EOF'
# syntax=docker/dockerfile:1
# comment line before FROM must not confuse the parser
FROM lochan-backend-base:latest
RUN pip install pyswisseph
EOF
# nodeps: app dir exists, NO Dockerfile.deps

# ── 1. app_deps_base reads the base from the app's own Dockerfile.deps ───────
got="$(app_deps_base appx)"
[[ "$got" == "lochan-backend-base:latest" ]] \
  && ok "app_deps_base reads FROM out of Dockerfile.deps ($got)" \
  || bad "appx expected 'lochan-backend-base:latest', got '$got'"

# ── 2. app without Dockerfile.deps → return 1 ────────────────────────────────
if app_deps_base nodeps >/dev/null; then
  bad "nodeps (no Dockerfile.deps) wrongly resolved a base"
else
  ok "app without Dockerfile.deps returns 1 (nothing to gate)"
fi

# ── 3. layers_prefix_match: identical + proper prefix → MATCH ────────────────
BASE='["sha256:aa","sha256:bb"]'
layers_prefix_match "$BASE" '["sha256:aa","sha256:bb"]' \
  && ok "identical layer lists match" \
  || bad "identical layer lists should match"
layers_prefix_match "$BASE" '["sha256:aa","sha256:bb","sha256:cc"]' \
  && ok "derived image extending the base matches (proper prefix)" \
  || bad "proper-prefix layer list should match"

# ── 4. diverged / truncated / digest-boundary → NO match ─────────────────────
layers_prefix_match "$BASE" '["sha256:aa","sha256:XX","sha256:cc"]' \
  && bad "diverged layer list wrongly matched" \
  || ok "diverged layer list does not match (stale deps detected)"
layers_prefix_match "$BASE" '["sha256:aa"]' \
  && bad "image with FEWER layers than base wrongly matched" \
  || ok "image shorter than its base does not match"
layers_prefix_match "$BASE" '["sha256:aa","sha256:bbX","sha256:cc"]' \
  && bad "digest-boundary superstring wrongly matched (bb vs bbX)" \
  || ok "digest-boundary superstring does not match (bb vs bbX)"

# ── 5. empty/null inputs fail CLOSED ─────────────────────────────────────────
for pair in '[]|["sha256:aa"]' '|["sha256:aa"]' "$BASE|" "$BASE|null" 'null|null'; do
  b="${pair%%|*}"; i="${pair#*|}"
  if layers_prefix_match "$b" "$i"; then
    bad "empty/null input wrongly matched (base='$b' img='$i')"
  else
    ok "empty/null input fails closed (base='$b' img='$i')"
  fi
done

# ── 6. wiring pins in the deploy script ──────────────────────────────────────
stamp_line="$(grep -n 'stamp-meta --all' "$DEPLOY" | head -1 | cut -d: -f1)"
first_build_line="$(grep -n 'docker_build docker/01-backend-deps' "$DEPLOY" | head -1 | cut -d: -f1)"
if [[ -n "$stamp_line" && -n "$first_build_line" ]] && (( stamp_line < first_build_line )); then
  ok "stamp-meta --all runs BEFORE the first base image build (line $stamp_line < $first_build_line)"
else
  bad "stamp-meta --all missing or not ordered before the base builds (stamp=$stamp_line, first build=$first_build_line)"
fi
grep -q -- '--skip-stamp' "$DEPLOY" \
  && ok "--skip-stamp escape hatch exists" \
  || bad "--skip-stamp escape hatch missing"
grep -q 'build-app.sh --deps-only' "$DEPLOY" \
  && ok "deps gate rebuilds via build-app.sh --deps-only" \
  || bad "deps gate rebuild call (build-app.sh --deps-only) missing"

echo
echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
