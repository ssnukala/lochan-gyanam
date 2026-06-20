#!/usr/bin/env bash
# persona-screenshots.sh — autowired per-persona screenshot capture for ANY Lochan app.
#
# WHY: domain apps declare their personas as a convention
# (<pkg>/backend/<pkg>/seeds/personas/*.json — each with users[0].{email,password}).
# Rather than hand-rolling a pw-login + capture loop per app, this wrapper
# AUTOWIRES the persona list from that convention and drives the EXISTING
# canonical capture path (take-screenshots.sh + daksh pw-login/screenshot) once
# per persona. One script serves every domain package (longterm, lifelight,
# vyaparam, regsevak, realtor, covera, autonex, …) with zero per-app code.
#
# It does NOT reinvent the sidecar/capture — it calls take-screenshots.sh with
# the new --user/--password pass-through so each run authenticates AS that
# persona. Captures are foldered per persona for a day-in-the-life set.
#
# Usage:
#   persona-screenshots.sh <app> [--persona <name>|all] [--mode desktop|mobile|all] [--list]
#     <app>              app instance (e.g. longterm01) — resolves its domain pkg
#                        from apps/<app>/packages.json "primary".
#     --persona <name>   capture one persona (the _avatar_id / filename stem).
#     --persona all      capture every declared persona (DEFAULT).
#     --mode <m>         desktop (default) | mobile | all — forwarded to take-screenshots.sh.
#     --list             print the autowired personas (name + email + role) and exit.
#
# Examples:
#   persona-screenshots.sh longterm01 --list
#   persona-screenshots.sh longterm01 --persona compliance
#   persona-screenshots.sh longterm01            # all personas, desktop
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAKE_SCREENSHOTS_SH="$SCRIPT_DIR/take-screenshots.sh"

# Resolve the CANONICAL gyanam root, not the worktree. Our runtime targets —
# generated apps/ (gitignored), the running containers, and the sidecar's
# screenshot output under framework/lochan/docs/ — are singletons that live in
# the MAIN checkout, never in a per-worktree copy. So when this script runs from
# a worktree (where apps/ is empty), SCRIPT_DIR/../../.. would point at the
# worktree and find nothing. git's common-dir always points at the main .git,
# whose parent is the canonical root. Honour an explicit $GYANAM_DIR override if
# set; else fall back to SCRIPT_DIR/../../.. when git isn't available.
if [[ -n "${GYANAM_DIR:-}" ]]; then
  GYANAM_DIR="$(cd "$GYANAM_DIR" && pwd)"
elif _common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
  GYANAM_DIR="$(cd "$(dirname "$_common")" && pwd)"
else
  GYANAM_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi

ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[0;31m✗\033[0m %s\n' "$1" >&2; }
note() { printf '    \033[2m%s\033[0m\n' "$1"; }
die()  { bad "$1"; exit "${2:-1}"; }

# ── Args ───────────────────────────────────────────────────────────────
[[ $# -ge 1 ]] || die "app name required. Usage: $0 <app> [--persona <name>|all] [--mode <m>] [--list]" 2
APP="$1"; shift || true
PERSONA="all"; MODE="desktop"; LIST_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --persona) PERSONA="${2:?--persona needs a name or 'all'}"; shift 2 ;;
    --mode)    MODE="${2:?--mode needs desktop|mobile|all}"; shift 2 ;;
    --list)    LIST_ONLY=1; shift ;;
    *) die "unknown flag $1" 2 ;;
  esac
done

# ── Resolve the app's domain package (convention: packages.json "primary") ──
PACKAGES_JSON="$GYANAM_DIR/apps/$APP/packages.json"
[[ -f "$PACKAGES_JSON" ]] || die "no packages.json for app '$APP' at $PACKAGES_JSON (is it a valid app?)" 3
PKG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("primary",""))' "$PACKAGES_JSON")"
[[ -n "$PKG" ]] || die "packages.json for '$APP' has no \"primary\" domain package" 3

# ── Autowire the persona list from the package's seed convention ──
PERSONA_DIR="$GYANAM_DIR/mandi/domain/$PKG/backend/$PKG/seeds/personas"
[[ -d "$PERSONA_DIR" ]] || die "no personas dir for package '$PKG' at $PERSONA_DIR" 3

# Emit "name<TAB>email<TAB>password<TAB>role" for each persona file, autowired.
read_personas() {
  python3 - "$PERSONA_DIR" <<'PY'
import json, sys, pathlib
d = pathlib.Path(sys.argv[1])
for f in sorted(d.glob("*.json")):
    try:
        j = json.loads(f.read_text())
    except Exception as e:
        sys.stderr.write(f"  skip {f.name}: bad json ({e})\n"); continue
    users = j.get("users") or []
    if not users:
        sys.stderr.write(f"  skip {f.name}: no users[] declared\n"); continue
    u = users[0]
    name = j.get("_avatar_id") or f.stem
    email = u.get("email", ""); pw = u.get("password", ""); role = u.get("role", "")
    if not email or not pw:
        sys.stderr.write(f"  skip {f.name}: user missing email/password\n"); continue
    print(f"{name}\t{email}\t{pw}\t{role}")
PY
}

echo "── persona-screenshots.sh: $APP (domain pkg: $PKG) ──"
# Read rows into an array (bash 3.2-compatible — macOS ships 3.2, no `mapfile`).
PERSONA_ROWS=()
while IFS= read -r _row; do
  [[ -n "$_row" ]] && PERSONA_ROWS+=("$_row")
done < <(read_personas)
[[ ${#PERSONA_ROWS[@]} -gt 0 ]] || die "no usable personas found in $PERSONA_DIR" 3

if [[ $LIST_ONLY -eq 1 ]]; then
  ok "autowired ${#PERSONA_ROWS[@]} personas for $APP ($PKG):"
  for row in "${PERSONA_ROWS[@]}"; do
    IFS=$'\t' read -r name email pw role <<<"$row"
    printf "    %-16s %-32s %s\n" "$name" "$email" "$role"
  done
  exit 0
fi

# ── Select persona(s) ──
SELECTED=()
if [[ "$PERSONA" == "all" ]]; then
  SELECTED=("${PERSONA_ROWS[@]}")
else
  for row in "${PERSONA_ROWS[@]}"; do
    IFS=$'\t' read -r name _ _ _ <<<"$row"
    [[ "$name" == "$PERSONA" ]] && SELECTED+=("$row")
  done
  [[ ${#SELECTED[@]} -gt 0 ]] || die "persona '$PERSONA' not found. Run --list to see available personas." 3
fi
note "capturing ${#SELECTED[@]} persona(s), mode=$MODE"

# ── Capture loop — one canonical run per persona, foldered per persona ──
CAPTURE_ROOT="$GYANAM_DIR/framework/lochan/docs/screenshots/personas/$APP"
FAILED=0; CAPTURED=0
for row in "${SELECTED[@]}"; do
  IFS=$'\t' read -r name email pw role <<<"$row"
  echo ""
  echo "── persona: $name  ($email · ${role:-no-role}) ──"
  if "$TAKE_SCREENSHOTS_SH" "$APP" --"$MODE" --user "$email" --password "$pw"; then
    # take-screenshots.sh writes to .../patent_demos_clickable; fold this
    # persona's fresh captures into a per-persona dir for the day-in-the-life set.
    dest="$CAPTURE_ROOT/$name"; mkdir -p "$dest"
    src="$GYANAM_DIR/framework/lochan/docs/screenshots/patent_demos_clickable"
    if compgen -G "$src/*.png" > /dev/null; then
      cp "$src"/*.png "$dest/" 2>/dev/null || true
      ok "$name: captured → $dest"
      CAPTURED=$((CAPTURED+1))
    else
      bad "$name: take-screenshots.sh passed but no PNGs found in $src"
      FAILED=$((FAILED+1))
    fi
  else
    bad "$name: take-screenshots.sh failed (see output above)"
    FAILED=$((FAILED+1))
  fi
done

echo ""
echo "────────────────────────────────────────────────────────"
if [[ $FAILED -eq 0 ]]; then
  ok "persona-screenshots.sh: $APP — $CAPTURED/${#SELECTED[@]} personas captured → $CAPTURE_ROOT"
  echo "  ⚠ NOTE: authenticated per-persona capture depends on the sidecar cookie-attach"
  echo "    path working (diagnose-auth-screenshots.sh <app> verifies it). If captures show"
  echo "    a logged-out nav, run that diagnostic before trusting the per-persona set."
  exit 0
else
  die "persona-screenshots.sh: $APP — $FAILED/${#SELECTED[@]} personas FAILED (captured $CAPTURED)" 1
fi
