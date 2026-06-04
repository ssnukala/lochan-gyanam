#!/usr/bin/env bash
# migrate-locales-to-canonical.sh — i18n convention-reversal codemod helper (i18n-M1/M2/M3)
#
# PURPOSE
#   Move ONE package's locale files from the bespoke Lochan path to the ratified
#   industry-standard canonical path (founder ratify 2026-06-04). Designed to be run by
#   an i18n-M{1,2,3} MIGRATE-leg session inside its own lgit-created worktree, one package
#   at a time (Shape-3-degenerate per-package OR clustered).
#
#   Bespoke  : <pkg>/locales/frontend/<locale>.json   +   <pkg>/locales/backend/<locale>.json
#   Canonical: <pkg>/frontend/src/locales/<locale>.json   (backend locale file RETIRED —
#              the backend is locale-agnostic; it returns i18n keys, the frontend resolves)
#
# WHAT IT DOES (idempotent; git-history-preserving)
#   1. git mv each <pkg>/locales/frontend/<locale>.json -> <pkg>/frontend/src/locales/<locale>.json
#   2. git rm each <pkg>/locales/backend/<locale>.json  (backend locale-agnostic)
#   3. remove the now-empty <pkg>/locales/ tree
#   GENERATED copies under */auto_wire/* are NEVER touched — they regenerate from the
#   canonical source via the locale-walker / generate-domain-manifest (the i18n-WIRE leg).
#   Already-canonical packages are a no-op.
#
# USAGE
#   bash util/scripts/migrate-locales-to-canonical.sh <pkg-dir> [--dry-run]
#     <pkg-dir>   path to the package root (e.g. framework/lochan/packages/shabd,
#                 mandi/common/ankana, mandi/domain/longterm)
#     --dry-run   print the planned git mv / git rm without executing
#
# CANONICAL REFS
#   decision  lochan-meta/decisions/i18n-convention-bespoke-vs-industry-standard-2026-06-04.md
#   pattern   lochan/process/PATTERNS/canonical-autowire-i18n-locales.md
#   check     janch locales-path-industry-standard (lochan #1028)
#
# NOTE ON git: this helper uses `git mv`/`git rm` directly (history-preserving codemod).
#   It is run BY a session INSIDE an lgit-created worktree (the worktree's cwd is the repo),
#   so the lgit-wrapper cwd-safety concern does not apply — paths are explicit + repo-local.
set -euo pipefail

PKG_DIR="${1:-}"
DRY_RUN="${2:-}"
if [[ -z "$PKG_DIR" ]]; then
  echo "usage: $0 <pkg-dir> [--dry-run]" >&2
  exit 2
fi
if [[ ! -d "$PKG_DIR" ]]; then
  echo "error: package dir not found: $PKG_DIR" >&2
  exit 2
fi

BESPOKE_FRONTEND="$PKG_DIR/locales/frontend"
BESPOKE_BACKEND="$PKG_DIR/locales/backend"
CANONICAL_DIR="$PKG_DIR/frontend/src/locales"

run() {  # echo in dry-run; execute otherwise
  if [[ "$DRY_RUN" == "--dry-run" ]]; then echo "  [dry-run] $*"; else echo "  + $*"; "$@"; fi
}

moved=0
if [[ -d "$BESPOKE_FRONTEND" ]]; then
  run mkdir -p "$CANONICAL_DIR"
  # move every <locale>.json from the bespoke frontend dir to the canonical dir
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    run git mv "$f" "$CANONICAL_DIR/$base"
    moved=$((moved + 1))
  done < <(find "$BESPOKE_FRONTEND" -maxdepth 1 -name '*.json' -print0)
fi

# backend locale files are RETIRED (backend is locale-agnostic — returns i18n keys)
if [[ -d "$BESPOKE_BACKEND" ]]; then
  while IFS= read -r -d '' f; do
    run git rm -q "$f"
  done < <(find "$BESPOKE_BACKEND" -maxdepth 1 -name '*.json' -print0)
fi

# remove the now-empty bespoke locales/ tree (frontend + backend dirs, then parent)
for d in "$BESPOKE_FRONTEND" "$BESPOKE_BACKEND" "$PKG_DIR/locales"; do
  if [[ -d "$d" ]] && [[ -z "$(find "$d" -type f ! -name '.gitkeep' 2>/dev/null)" ]]; then
    run rm -rf "$d"
  fi
done

if [[ "$moved" -eq 0 ]] && [[ ! -d "$BESPOKE_BACKEND" ]]; then
  echo "  (no bespoke locale files in $PKG_DIR — already canonical or none)"
fi
echo "done: $PKG_DIR  (moved=$moved; canonical=$CANONICAL_DIR)"
