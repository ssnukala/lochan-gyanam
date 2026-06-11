#!/usr/bin/env bash
# Regression tests for Tier-3 capture-run sidecar substrate. Pins the
# canonical invariants per Q-CAPTURE-RUN-BIND-MOUNT-LAYOUT = B founder
# ratify 2026-05-31. Pure-bash test composing with util/scripts/
# test-lgit.sh + test-util-scripts-strict-mode.sh canonical patterns.
#
# Why this exists (§W-Capture-Run-Sidecar-Image-Canonical):
#   - Q-CAPTURE-RUN-BIND-MOUNT-LAYOUT = B ratifies sidecar image
#     substrate AS canonical (not the prior bind-mount approach).
#   - This test pins the structural invariants of the sidecar so future
#     edits can't regress to bind-mount + can't drop the canonical
#     image reference + can't omit the Tier-3 build entrypoint.
#
# Canonical invariants pinned:
#   §L.1 docker/03-frontend-playwright.Dockerfile EXISTS + FROM
#        lochan-frontend-base:dev (correct Tier-2 base)
#   §L.2 Dockerfile installs @playwright/test as workspace-root
#        devDependency (pnpm add -D -w @playwright/test@VERSION)
#   §L.3 Dockerfile installs chromium + system deps
#        (npx playwright install chromium && install-deps chromium)
#   §L.4 compose.playwright.yml references the canonical Tier-3 image
#        (image: lochan-frontend-playwright:latest); does NOT use
#        mcr.microsoft.com/playwright (the pre-§6.5W=B base)
#   §L.5 compose.playwright.yml DOES NOT bind-mount /tests
#        (../../framework/lochan/frontend:/tests:ro removed per
#         Q-CAPTURE-RUN-BIND-MOUNT-LAYOUT = B canonical); /screenshots
#        bind-mount preserved (writable output)
#   §L.6 util/scripts/build/build-app.sh declares --with-playwright flag +
#        builds Tier-3 sidecar when flag set
#   §L.7 Dockerfile has substantive doc-block (founder Day-7 BINDING B);
#        ≥20 comment lines documenting WHY (not WHAT)
#
# Usage: bash util/scripts/build/test-capture-run-sidecar-substrate.sh
# Exit:  0 on ALL PASS / non-zero with PASS/FAIL summary on any FAIL

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# SCRIPT_DIR = <gyanam>/util/scripts/build; GYANAM_DIR = <gyanam>
GYANAM_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DOCKERFILE="$GYANAM_DIR/docker/03-frontend-playwright.Dockerfile"
COMPOSE_PLAYWRIGHT="$GYANAM_DIR/docker/compose.playwright.yml"
BUILD_APP_SH="$GYANAM_DIR/util/scripts/build/build-app.sh"

PASS=0
FAIL=0
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
RESET=$'\033[0m'

pass() { echo "${GREEN}PASS${RESET}: $1"; PASS=$((PASS + 1)); }
fail() { echo "${RED}FAIL${RESET}: $1"; FAIL=$((FAIL + 1)); }

# ── §L.1 — Tier-3 Dockerfile exists + FROM canonical Debian base ─────
test_l1_dockerfile_exists_and_uses_bookworm_slim() {
  local desc="§L.1 Tier-3 Dockerfile exists + FROM node:22-bookworm-slim (canonical Playwright base; Q-CAPTURE-RUN-SIDECAR-ALPINE-COMPAT = β)"
  if [[ ! -f "$DOCKERFILE" ]]; then
    fail "$desc — file missing"
    return
  fi
  # Per β fix-forward: independent Tier-3 base; node:22-bookworm-slim
  # (NOT lochan-frontend-base:dev which is Alpine-derived)
  if grep -qE "^FROM node:22-bookworm-slim" "$DOCKERFILE"; then
    # Also verify the Alpine-derived base is NOT used (β explicitly
    # rejects it because Alpine apk has no canonical install-deps recipe)
    if grep -qE "^FROM lochan-frontend-base:dev" "$DOCKERFILE"; then
      fail "$desc — canonical bookworm-slim base used BUT lochan-frontend-base:dev (Alpine-derived) ALSO present (β rejects it)"
      return
    fi
    pass "$desc"
  else
    fail "$desc — FROM directive does not reference node:22-bookworm-slim"
  fi
}

# ── §L.2 — installs @playwright/test pinned to canonical version ─────
test_l2_installs_playwright_test_pinned() {
  local desc="§L.2 Dockerfile installs @playwright/test pinned to 1.48.0 (matches test-image-pins.json canonical version)"
  # Per β fix-forward: sidecar IS the only workspace (no parent workspace-
  # root); pnpm install reads devDependencies from local package.json.
  # The pinned version 1.48.0 matches test-image-pins.json node_packages.
  if grep -qE '"@playwright/test":\s*"1\.48\.0"' "$DOCKERFILE" && \
     grep -qE "pnpm install" "$DOCKERFILE"; then
    pass "$desc"
  else
    fail "$desc — @playwright/test version pin OR pnpm install missing"
  fi
}

# ── §L.3 — installs chromium ─────────────────────────────────────────
test_l3_installs_chromium_browser() {
  local desc="§L.3 Dockerfile installs chromium browser + system deps"
  if grep -qE "playwright install chromium" "$DOCKERFILE" && \
     grep -qE "playwright install-deps chromium" "$DOCKERFILE"; then
    pass "$desc"
  else
    fail "$desc — chromium install OR install-deps chromium missing"
  fi
}

# ── §L.4 — compose references canonical Tier-3 image ─────────────────
test_l4_compose_uses_canonical_tier3_image() {
  local desc="§L.4 compose.playwright.yml uses lochan-frontend-playwright:latest (NOT mcr.microsoft.com/playwright)"
  if grep -qE "^\s+image:\s+lochan-frontend-playwright:latest" "$COMPOSE_PLAYWRIGHT"; then
    # Also verify the old MS image is NOT in an active service block
    # (it may appear in comments documenting the pivot — that's OK).
    # Check for any `image:` line still referencing mcr.microsoft.com
    if grep -qE "^\s+image:\s+mcr\.microsoft\.com/playwright" "$COMPOSE_PLAYWRIGHT"; then
      fail "$desc — canonical image declared BUT mcr.microsoft.com/playwright still referenced in image: directive"
      return
    fi
    pass "$desc"
  else
    fail "$desc — canonical image directive missing"
  fi
}

# ── §L.5 — /tests bind-mount REMOVED; /screenshots preserved ─────────
test_l5_tests_bindmount_removed_screenshots_preserved() {
  local desc="§L.5 compose.playwright.yml /tests bind-mount REMOVED + /screenshots preserved"
  # Verify /tests bind-mount is NOT in an active volume
  # (matches `../../framework/lochan/frontend:/tests:ro`)
  if grep -qE "^\s*-\s+\.\./\.\./framework/lochan/frontend:/tests:ro" "$COMPOSE_PLAYWRIGHT"; then
    fail "$desc — /tests bind-mount still active in volumes (should be removed per Q-CAPTURE-RUN-BIND-MOUNT-LAYOUT = B)"
    return
  fi
  # Verify /screenshots bind-mount IS preserved (writable output)
  if grep -qE "patent_demos_clickable:/screenshots:rw" "$COMPOSE_PLAYWRIGHT"; then
    pass "$desc"
  else
    fail "$desc — /screenshots writable bind-mount missing (should be preserved)"
  fi
}

# ── §L.6 — build-app.sh declares --with-playwright flag ──────────────
test_l6_build_app_sh_declares_with_playwright_flag() {
  local desc="§L.6 util/scripts/build/build-app.sh declares --with-playwright flag + Tier-3 build invocation"
  if grep -qE -- "--with-playwright\) WITH_PLAYWRIGHT=1" "$BUILD_APP_SH" && \
     grep -qE "WITH_PLAYWRIGHT -eq 1" "$BUILD_APP_SH" && \
     grep -qE "docker build" "$BUILD_APP_SH" && \
     grep -qE "lochan-frontend-playwright:latest" "$BUILD_APP_SH"; then
    pass "$desc"
  else
    fail "$desc — --with-playwright flag OR Tier-3 build invocation missing"
  fi
}

# ── §L.7 — Dockerfile has substantive doc-block (founder Day-7 B) ────
test_l7_dockerfile_has_substantive_docblock() {
  local desc="§L.7 Dockerfile has substantive doc-block ≥20 comment lines per founder Day-7 BINDING (B)"
  # Count comment-only lines (starts with optional whitespace + #)
  local comment_lines
  comment_lines=$(awk '/^#/{count++} END{print count+0}' "$DOCKERFILE")
  if [[ "$comment_lines" -ge 20 ]]; then
    pass "$desc (comment-lines=$comment_lines)"
  else
    fail "$desc — doc-block too thin (comment-lines=$comment_lines; expected ≥20)"
  fi
}

# ── §L.8 — Dockerfile COPIES canonical specs (independent of Tier-2) ─
test_l8_dockerfile_copies_canonical_specs() {
  local desc="§L.8 Dockerfile COPIES framework Playwright config + e2e specs (independent Tier-3 IS the design; no Tier-2 dependency)"
  if grep -qE "^COPY framework/lochan/frontend/playwright\.config\.ts" "$DOCKERFILE" && \
     grep -qE "^COPY framework/lochan/frontend/e2e" "$DOCKERFILE"; then
    pass "$desc"
  else
    fail "$desc — COPY directives for playwright.config.ts + e2e/ missing"
  fi
}

# ── §L.9 — sidecar package.json declares "type": "module" ────────────
test_l9_sidecar_package_json_type_module() {
  local desc="§L.9 Sidecar package.json heredoc declares \"type\": \"module\" (mirrors host framework/lochan/frontend/package.json; Q-SIDECAR-PACKAGE-JSON-TYPE-MODULE = ratified)"
  # Verify the heredoc line includes "type": "module" — without it,
  # Node.js evaluates spec.ts files as CommonJS and import.meta.url
  # triggers ReferenceError at parse-time per S5 empirical patch-test
  # 2026-05-31.
  if grep -qE '"name": "lochan-frontend-playwright-sidecar".*"type": "module"' "$DOCKERFILE"; then
    pass "$desc"
  else
    fail "$desc — \"type\": \"module\" key missing from sidecar package.json heredoc"
  fi
}

# ── §L.10 — ENV PLAYWRIGHT_BROWSERS_PATH precedes install RUN ────────
test_l10_env_browsers_path_precedes_install() {
  local desc="§L.10 ENV PLAYWRIGHT_BROWSERS_PATH precedes 'playwright install chromium' RUN (Q-SIDECAR-PLAYWRIGHT-BROWSERS-PATH; Layer 11)"
  # Verify ENV declaration appears BEFORE the install RUN in line order
  # so the installer writes browser binaries to the env-declared path
  # (S5 empirical: install needs ENV pre-set; runtime needs ENV too).
  local env_line
  local install_line
  env_line=$(grep -nE "^ENV PLAYWRIGHT_BROWSERS_PATH=" "$DOCKERFILE" | head -1 | cut -d: -f1)
  install_line=$(grep -nE "^RUN npx playwright install chromium" "$DOCKERFILE" | head -1 | cut -d: -f1)
  if [[ -z "$env_line" ]] || [[ -z "$install_line" ]]; then
    fail "$desc — ENV or RUN line not found (env_line=$env_line install_line=$install_line)"
    return
  fi
  if (( env_line < install_line )); then
    pass "$desc (ENV at line $env_line; install RUN at line $install_line)"
  else
    fail "$desc — ENV at line $env_line is NOT BEFORE install RUN at line $install_line"
  fi
}

# ── §L.11 — compose declares SCREENSHOT_DIR env (β config-driven) ────
test_l11_compose_screenshot_dir_env() {
  local desc="§L.11 compose.playwright.yml declares SCREENSHOT_DIR=/screenshots env (Q-SIDECAR-SCREENSHOT-DIR-PATH = β; sister to spec.ts env-driven default)"
  # Verify SCREENSHOT_DIR env var is declared in the playwright-screenshots
  # service environment block — pairs with spec.ts env-driven default
  # (sister PR in ssnukala/lochan) to make image generic + spec env-aware.
  if grep -qE "^\s+-\s+SCREENSHOT_DIR=/screenshots" "$COMPOSE_PLAYWRIGHT"; then
    pass "$desc"
  else
    fail "$desc — SCREENSHOT_DIR=/screenshots env declaration missing from compose"
  fi
}

# ── §L.12 — validator SCREENSHOT_DIR == compose bind-mount host path ─
test_l12_screenshot_dir_matches_compose_bindmount() {
  local desc="§L.12 take-screenshots.sh SCREENSHOT_DIR equals the compose /screenshots bind-mount host path (D7 gate-5: validator counted PNGs in a dir the sidecar never writes — strict count check could never pass)"
  local ts="$SCRIPT_DIR/take-screenshots.sh"
  # Host side of the writable /screenshots bind-mount, relative to the
  # compose file's directory ($GYANAM_DIR/docker).
  local mount_rel mount_abs script_abs
  mount_rel="$(grep -oE '^[[:space:]]*-[[:space:]]*[^:]+:/screenshots' "$COMPOSE_PLAYWRIGHT" | head -1 | sed -E 's/^[[:space:]]*-[[:space:]]*//; s|:/screenshots$||')" || true
  if [[ -z "$mount_rel" ]]; then
    fail "$desc — could not extract /screenshots bind-mount host path from compose"
    return
  fi
  # Textual normalization (no filesystem dependence — worktrees don't
  # materialize the nested framework repo): the mount path is relative
  # to the compose file's dir ($GYANAM_DIR/docker), so '../../X' ≡
  # '$GYANAM_DIR/X'. A future compose layout change breaks this pin
  # loudly, which is the point.
  mount_abs="$GYANAM_DIR/${mount_rel#../../}"
  # Resolve the SCREENSHOT_DIR assignment exactly as the script would
  # (its only input variable is GYANAM_DIR, which we share).
  script_abs="$(GYANAM_DIR="$GYANAM_DIR" bash -c "$(grep -E '^SCREENSHOT_DIR=' "$ts" | head -1); printf '%s' \"\$SCREENSHOT_DIR\"")" || true
  if [[ -z "$script_abs" ]]; then
    fail "$desc — could not extract SCREENSHOT_DIR= assignment from take-screenshots.sh"
    return
  fi
  if [[ "$script_abs" == "$mount_abs" ]]; then
    pass "$desc ($mount_abs)"
  else
    fail "$desc — script counts in '$script_abs' but sidecar writes to '$mount_abs'"
  fi
}

echo "── Tier-3 Playwright sidecar substrate regression (β + type:module + L11 + L12) ──"
echo ""
test_l1_dockerfile_exists_and_uses_bookworm_slim
test_l2_installs_playwright_test_pinned
test_l3_installs_chromium_browser
test_l4_compose_uses_canonical_tier3_image
test_l5_tests_bindmount_removed_screenshots_preserved
test_l6_build_app_sh_declares_with_playwright_flag
test_l7_dockerfile_has_substantive_docblock
test_l8_dockerfile_copies_canonical_specs
test_l9_sidecar_package_json_type_module
test_l10_env_browsers_path_precedes_install
test_l11_compose_screenshot_dir_env
test_l12_screenshot_dir_matches_compose_bindmount

echo ""
TOTAL=$((PASS + FAIL))
if [[ "$FAIL" -eq 0 ]]; then
  echo "${GREEN}ALL PASS${RESET} — $PASS/$TOTAL"
  exit 0
else
  echo "${RED}FAIL${RESET} — $PASS passed / $FAIL failed / $TOTAL total"
  exit 1
fi
