#!/usr/bin/env bash
# ============================================================================
# deploy-lochan.sh — reusable bootstrap + deploy for a Lochan gyanam workspace
# ============================================================================
#
# Reads repos.json (next to this script) for the canonical list of repos.
# Pulls every framework + mandi_common repo on every run. Pulls a
# mandi_domain repo only when an app that needs it is requested via --app.
#
# Usage:
#   ./scripts/deploy-lochan.sh --prod --app fwprod01
#   ./scripts/deploy-lochan.sh --prod --app fwprod01 --app lifestyle01 --app longterm01
#   ./scripts/deploy-lochan.sh --dev  --app fwprod01
#   ./scripts/deploy-lochan.sh --pull-only                # refresh all repos, no build/deploy
#   ./scripts/deploy-lochan.sh --skip-pull --app fwprod01 # use current clones as-is
#   ./scripts/deploy-lochan.sh --skip-build --app fwprod01 # restart only (images already built)
#
# Compose mode:
#   --prod → docker compose -f compose.prod.yml ...   (or compose.yml if no .prod.yml)
#   --dev  → docker compose -f compose.dev.yml ...    (default if neither flag is set)
#
# The script is idempotent. Safe to re-run. Exits non-zero on any build or
# deploy error so CI / cron can detect failures.
# ============================================================================

set -euo pipefail

# ── Locate repo root ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GYANAM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPOS_JSON="$GYANAM_DIR/repos.json"

[[ -f "$REPOS_JSON" ]] || { echo "ERROR: repos.json not found at $REPOS_JSON" >&2; exit 1; }

# ── Colors ─────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
else
  R=''; G=''; Y=''; C=''; B=''; N=''
fi

log()  { echo -e "${G}[✓]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[✗]${N} $*" >&2; }
sect() { echo; echo -e "${B}${C}══════════════════════════════════════════${N}"; echo -e "${B}${C}  $*${N}"; echo -e "${B}${C}══════════════════════════════════════════${N}"; }

# ── Arg parsing ────────────────────────────────────────────────────────────
MODE="dev"           # dev | prod
APPS=()              # list of apps to deploy
PULL=1               # pull repos?
BUILD=1              # build base images?
DEPLOY=1             # start/restart containers?
PULL_ONLY=0          # short-circuit after pull

while (( $# )); do
  case "$1" in
    --prod)       MODE="prod" ;;
    --dev)        MODE="dev"  ;;
    --app)        shift; APPS+=("$1") ;;
    --skip-pull)  PULL=0  ;;
    --skip-build) BUILD=0 ;;
    --skip-deploy)DEPLOY=0;;
    --pull-only)  PULL_ONLY=1; BUILD=0; DEPLOY=0 ;;
    --help|-h)    sed -n '2,30p' "$0"; exit 0 ;;
    *) err "Unknown flag: $1"; exit 2 ;;
  esac
  shift
done

# ── Dependencies ────────────────────────────────────────────────────────────
for cmd in git docker python3; do
  command -v "$cmd" >/dev/null 2>&1 || { err "missing dependency: $cmd"; exit 1; }
done

# ── repos.json helpers ──────────────────────────────────────────────────────
# Python 3 ships json in its stdlib and is already required elsewhere in the
# gyanam build flow — dropping jq trims one install step on fresh Alpine hosts.

# Emit TSV rows of (path, url) for every entry in the given bucket
# (framework, mandi_common, mandi_domain). Skips entries without both fields
# and anything that is not a dict (repos.json uses a _comment array at the
# top level for docs).
repos_bucket_tsv() {
  local bucket="$1"
  python3 - "$REPOS_JSON" "$bucket" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for entry in data.get(sys.argv[2], []):
    if not isinstance(entry, dict):
        continue
    path = entry.get("path")
    url = entry.get("url")
    if path and url:
        print(f"{path}\t{url}")
PY
}

# List domain repo paths for a given app from app_to_domains.
# Prints one path per line; prints nothing (exit 0) for unknown apps.
repos_app_domains() {
  local app="$1"
  python3 - "$REPOS_JSON" "$app" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for p in data.get("app_to_domains", {}).get(sys.argv[2], []) or []:
    if isinstance(p, str):
        print(p)
PY
}

# Look up the git URL for a domain path in mandi_domain.
# Prints the URL (or nothing + exit 0) for the first matching entry.
repos_domain_url() {
  local domain_path="$1"
  python3 - "$REPOS_JSON" "$domain_path" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for entry in data.get("mandi_domain", []):
    if isinstance(entry, dict) and entry.get("path") == sys.argv[2]:
        url = entry.get("url", "")
        if url:
            print(url)
        break
PY
}

# ── Repo helpers ────────────────────────────────────────────────────────────
clone_or_pull() {
  local path="$1" url="$2"
  local full="$GYANAM_DIR/$path"
  if [[ -d "$full/.git" ]]; then
    echo -n "  pull $path ... "
    if git -C "$full" pull --ff-only --quiet 2>/dev/null; then
      echo "ok"
    else
      warn "pull non-fast-forward or dirty — leaving as-is"
    fi
  elif [[ -d "$full" && -n "$(ls -A "$full" 2>/dev/null)" ]]; then
    warn "$path exists but isn't a git repo — skipping clone"
  else
    echo -n "  clone $path ... "
    mkdir -p "$(dirname "$full")"
    if git clone --quiet "$url" "$full" 2>/dev/null; then
      echo "ok"
    else
      err "clone failed for $url"
      return 1
    fi
  fi
}

pull_bucket() {
  local bucket="$1"
  local count=0
  while IFS=$'\t' read -r path url; do
    [[ -z "$path" ]] && continue
    clone_or_pull "$path" "$url"
    count=$((count + 1))
  done < <(repos_bucket_tsv "$bucket")
  log "$bucket: $count repo(s) synced"
}

# ── Phase 1: repo sync ─────────────────────────────────────────────────────
if (( PULL )); then
  sect "Phase 1: Sync framework + common repos"
  pull_bucket framework
  pull_bucket mandi_common

  if (( ${#APPS[@]} > 0 )); then
    sect "Phase 1b: Sync domain repos for requested apps"
    local_domains=()
    for app in "${APPS[@]}"; do
      mapfile -t app_doms < <(repos_app_domains "$app")
      for d in "${app_doms[@]}"; do local_domains+=("$d"); done
    done
    # dedupe
    mapfile -t local_domains < <(printf "%s\n" "${local_domains[@]}" | sort -u)

    if (( ${#local_domains[@]} == 0 )); then
      warn "no domain repos needed for requested apps (framework-only)"
    else
      for dom in "${local_domains[@]}"; do
        url=$(repos_domain_url "$dom")
        [[ -z "$url" ]] && { warn "no url for $dom in repos.json"; continue; }
        clone_or_pull "$dom" "$url"
      done
      log "domain repos: ${#local_domains[@]} synced"
    fi
  fi
else
  warn "skipping pull (--skip-pull)"
fi

(( PULL_ONLY )) && { log "pull-only mode — done."; exit 0; }

# ── Phase 2: build base images (Tier 0 + Tier 1) ───────────────────────────
if (( BUILD )); then
  sect "Phase 2: Build framework base images"
  cd "$GYANAM_DIR"

  docker_build() {
    local file="$1" tag="$2"
    echo -n "  build $tag ($file) ... "
    if docker build --quiet -f "$file" -t "$tag" . >/dev/null; then
      echo "ok"
    else
      err "build failed: $tag"; return 1
    fi
  }

  docker_build docker/backend.deps.Dockerfile  lochan-deps-backend:latest
  docker_build docker/frontend.deps.Dockerfile lochan-deps-frontend:latest
  docker_build docker/backend.base.Dockerfile  lochan-backend-base:latest
  docker_build docker/frontend.base.Dockerfile lochan-frontend-base:latest
else
  warn "skipping base image builds (--skip-build)"
fi

# ── Phase 3: deploy apps ───────────────────────────────────────────────────
if (( DEPLOY )) && (( ${#APPS[@]} > 0 )); then
  sect "Phase 3: Deploy apps ($MODE mode)"
  for app in "${APPS[@]}"; do
    app_dir="$GYANAM_DIR/apps/$app"
    [[ -d "$app_dir" ]] || { err "app not found: $app_dir"; continue; }

    compose_file="compose.${MODE}.yml"
    [[ -f "$app_dir/$compose_file" ]] || compose_file="compose.yml"
    [[ -f "$app_dir/$compose_file" ]] || { err "$app: no compose file (tried compose.${MODE}.yml, compose.yml)"; continue; }

    echo "  [$app] using $compose_file"
    (
      cd "$app_dir"
      docker compose -f "$compose_file" up -d --force-recreate --build
    )
    log "$app: restarted"
  done
elif (( ${#APPS[@]} == 0 )); then
  warn "no apps requested — use --app <name> to deploy one or more"
fi

sect "Done"
log "workspace: $GYANAM_DIR"
log "mode:      $MODE"
log "apps:      ${APPS[*]:-(none)}"
