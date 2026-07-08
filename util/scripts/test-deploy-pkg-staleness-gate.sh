#!/usr/bin/env bash
# test-deploy-pkg-staleness-gate.sh — regression tests for scripts/deploy-lochan.sh
# Phase 2.5 bundled-package staleness gate (§PKG-STALENESS-GATE, 2026-07-07).
#
# THE INCIDENT THIS GUARDS: deploy-lochan.sh rebuilds ONLY deps/base images;
# each app's Dockerfiles do `FROM <pkg>:latest AS pkg-<name>` + COPY, so a
# stale `<pkg>:latest` silently bakes OLD package source into a "successful"
# deploy (3rd recurrence 2026-07-07: longterm:latest bundled pre-GAP-17 source
# while the clone was already fixed — image CreatedAt even LOOKED newer than
# the fix commit). Phase 2.5 always rebuilds every bundled pkg image from the
# just-synced clones; these tests pin the discovery + resolution helpers.
#
# Self-contained: builds fixture app Dockerfiles + package dirs under mktemp,
# extracts the REAL app_bundled_pkgs()/pkg_src_dir() from the deploy script
# (so the test tracks the live implementation, not a copy), and asserts:
#   1. backend + frontend pkg-stages discovered, deduped, sorted
#   2. non-pkg FROM stages (base images, builder, runner) are NOT matched
#   3. framework-only app (no pkg stages) → empty list
#   4. app with no Dockerfiles → empty list
#   5. pkg_src_dir resolves in order: mandi/domain → mandi/common →
#      framework/lochan/packages, requiring build.sh
#   6. pkg dir present but NO build.sh → not resolved (return 1)
#   7. unknown package → return 1
#
# Run: bash util/scripts/test-deploy-pkg-staleness-gate.sh

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
FUNC_FILE="$ROOT/pkg_helpers.sh"
awk '/^app_bundled_pkgs\(\) \{/{f=1} f{print} f&&/^\}/{f=0}' "$DEPLOY" >  "$FUNC_FILE"
awk '/^pkg_src_dir\(\) \{/{f=1} f{print} f&&/^\}/{f=0}'      "$DEPLOY" >> "$FUNC_FILE"
grep -q 'pkg-' "$FUNC_FILE" || { echo "FAIL: extracted app_bundled_pkgs missing pkg-stage match (script drifted?)" >&2; exit 1; }
grep -q 'build.sh' "$FUNC_FILE" || { echo "FAIL: extracted pkg_src_dir missing build.sh check (script drifted?)" >&2; exit 1; }
# shellcheck disable=SC1090
source "$FUNC_FILE"

GYANAM_DIR="$ROOT/gyanam"

# ── Fixtures ─────────────────────────────────────────────────────────────────
mkdir -p "$GYANAM_DIR/apps/appx" "$GYANAM_DIR/apps/fwonly"
cat > "$GYANAM_DIR/apps/appx/Dockerfile.backend" <<'EOF'
# syntax=docker/dockerfile:1
FROM alpha:latest AS pkg-alpha
FROM beta:latest AS pkg-beta
FROM appx-deps:latest
COPY --from=pkg-alpha /pkg/ /app/packages/alpha/
COPY --from=pkg-beta /pkg/ /app/packages/beta/
EOF
cat > "$GYANAM_DIR/apps/appx/Dockerfile.frontend" <<'EOF'
FROM alpha:latest AS pkg-alpha
FROM gamma:latest AS pkg-gamma
FROM lochan-frontend-base:prod AS builder
FROM nginx:alpine AS runner
EOF
cat > "$GYANAM_DIR/apps/fwonly/Dockerfile.backend" <<'EOF'
FROM fwonly-deps:latest
COPY backend/ /app/
EOF

mkdir -p "$GYANAM_DIR/mandi/domain/alpha" \
         "$GYANAM_DIR/mandi/common/alpha" \
         "$GYANAM_DIR/mandi/common/beta" \
         "$GYANAM_DIR/framework/lochan/packages/gamma" \
         "$GYANAM_DIR/mandi/domain/noscript"
touch "$GYANAM_DIR/mandi/domain/alpha/build.sh" \
      "$GYANAM_DIR/mandi/common/alpha/build.sh" \
      "$GYANAM_DIR/mandi/common/beta/build.sh" \
      "$GYANAM_DIR/framework/lochan/packages/gamma/build.sh"
# noscript: dir exists, NO build.sh

# ── 1+2. backend+frontend discovery, dedupe, non-pkg stages excluded ─────────
got="$(app_bundled_pkgs appx | tr '\n' ' ' | sed 's/ $//')"
if [[ "$got" == "alpha beta gamma" ]]; then
  ok "appx bundled pkgs discovered + deduped across both Dockerfiles ($got)"
else
  bad "appx expected 'alpha beta gamma', got '$got'"
fi
case " $got " in
  *" appx-deps "*|*" builder "*|*" runner "*|*" nginx "*|*" lochan-frontend-base "*)
    bad "non-pkg FROM stages leaked into discovery: '$got'" ;;
  *) ok "non-pkg FROM stages (deps/base/builder/runner) excluded" ;;
esac

# ── 3. framework-only app → empty ────────────────────────────────────────────
got="$(app_bundled_pkgs fwonly)"
[[ -z "$got" ]] && ok "framework-only app yields no bundled pkgs" \
                || bad "fwonly expected empty, got '$got'"

# ── 4. app with no Dockerfiles → empty, no error ─────────────────────────────
got="$(app_bundled_pkgs ghost)"
[[ -z "$got" ]] && ok "missing-Dockerfile app yields empty (no crash)" \
                || bad "ghost expected empty, got '$got'"

# ── 5. resolution order: mandi/domain wins over mandi/common ─────────────────
got="$(pkg_src_dir alpha)"
[[ "$got" == "$GYANAM_DIR/mandi/domain/alpha" ]] \
  && ok "pkg_src_dir prefers mandi/domain ($got)" \
  || bad "alpha expected mandi/domain path, got '$got'"
got="$(pkg_src_dir beta)"
[[ "$got" == "$GYANAM_DIR/mandi/common/beta" ]] \
  && ok "pkg_src_dir falls through to mandi/common" \
  || bad "beta expected mandi/common path, got '$got'"
got="$(pkg_src_dir gamma)"
[[ "$got" == "$GYANAM_DIR/framework/lochan/packages/gamma" ]] \
  && ok "pkg_src_dir falls through to framework/lochan/packages" \
  || bad "gamma expected framework path, got '$got'"

# ── 6. dir without build.sh is NOT a source dir ──────────────────────────────
if pkg_src_dir noscript >/dev/null; then
  bad "noscript (no build.sh) wrongly resolved"
else
  ok "package dir without build.sh is not resolved (return 1)"
fi

# ── 7. unknown package → return 1 ────────────────────────────────────────────
if pkg_src_dir nosuchpkg >/dev/null; then
  bad "unknown package wrongly resolved"
else
  ok "unknown package returns 1"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
