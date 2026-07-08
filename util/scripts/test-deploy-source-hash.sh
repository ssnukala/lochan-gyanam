#!/usr/bin/env bash
# test-deploy-source-hash.sh — regression test for scripts/deploy-lochan.sh
# §D.BUILD-CACHE SOURCE_HASH derivation (2026-07-08).
#
# THE INCIDENT: the script derived the framework tree hash with
# `git rev-parse HEAD:.` — a form newer git REJECTS ("path '.' exists on
# disk, but not in 'HEAD'", exit 128) while still echoing the literal
# `HEAD:.` to stdout. Result: SOURCE_HASH was silently the constant
# "HEAD:.\nunknown" on every deploy, so the cache-bust LABEL never varied
# and the §D.BUILD-CACHE belt-and-suspenders leg was INERT (found live in
# the 2026-07-08 Task-4.0 deploy log). The canonical root-tree form is
# `HEAD^{tree}` — content-addressed, stable across git versions.
#
# Self-contained: extracts the REAL SOURCE_HASH derivation line from the
# deploy script and runs it against a fixture git repo, asserting:
#   1. it yields a 40-hex object id (not the echoed literal, not "unknown")
#   2. the hash CHANGES when tracked content changes (content-addressed)
#   3. the rejected `HEAD:.` form is gone from the script
#
# Run: bash util/scripts/test-deploy-source-hash.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$SCRIPT_DIR/../../scripts/deploy-lochan.sh"
[[ -f "$DEPLOY" ]] || { echo "FAIL: deploy script not found at $DEPLOY" >&2; exit 1; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0; FAIL=0
ok()  { echo "  [✓] $1"; PASS=$((PASS+1)); }
bad() { echo "  [✗] $1" >&2; FAIL=$((FAIL+1)); }

# ── Fixture repo ─────────────────────────────────────────────────────────────
REPO="$ROOT/framework-fixture"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
echo "v1" > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m v1

# ── Harness: run the REAL derivation line against the fixture ────────────────
# The script's line is: SOURCE_HASH="$(git -C "$GYANAM_DIR/framework/lochan" rev-parse <FORM> ...)"
line="$(grep -E '^\s*SOURCE_HASH=' "$DEPLOY" | head -1)"
[[ -n "$line" ]] || { echo "FAIL: SOURCE_HASH derivation line not found (script drifted?)" >&2; exit 1; }

derive() {  # substitute the fixture repo for the framework clone, eval the real line
  local GYANAM_DIR="$ROOT" SOURCE_HASH
  eval "${line/\$GYANAM_DIR\/framework\/lochan/$REPO}"
  echo "$SOURCE_HASH"
}

# ── 1. yields a 40-hex object id ─────────────────────────────────────────────
h1="$(derive)"
if [[ "$h1" =~ ^[0-9a-f]{40}$ ]]; then
  ok "SOURCE_HASH is a 40-hex tree hash ($h1)"
else
  bad "SOURCE_HASH is not a tree hash: '$h1' (the HEAD:. regression shape)"
fi

# ── 2. content-addressed: changes when tracked content changes ───────────────
echo "v2" > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m v2
h2="$(derive)"
if [[ "$h2" =~ ^[0-9a-f]{40}$ && "$h2" != "$h1" ]]; then
  ok "SOURCE_HASH changes with tracked content ($h1 → $h2)"
else
  bad "SOURCE_HASH did not change with content (h1='$h1' h2='$h2')"
fi

# ── 3. the rejected HEAD:. form is gone ──────────────────────────────────────
if grep -qE "rev-parse ['\"]?HEAD:\." "$DEPLOY"; then
  bad "script still uses 'rev-parse HEAD:.' (rejected by newer git)"
else
  ok "rejected 'rev-parse HEAD:.' form absent"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
