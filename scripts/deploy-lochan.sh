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
DEPLOY_FAILED=0      # set to 1 if any app's bring-up fails → exit 1 at the end

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

# ── Phase 0: verify app→domain mapping (class-prevention, 2026-07-02) ──────
# app_to_domains drift is how the longterm01 server deploy silently skipped
# flow/vyaparam (mapping listed only longterm). Verify the mapping against
# each requested app's generated packages.json BEFORE doing any work and fail
# loud on any gap — including a domain path missing from the mandi_domain
# registry. Apps not generated yet are skipped inside the verifier (fresh
# bootstrap: apps/ appears after the first sync + generate).
if (( ${#APPS[@]} > 0 )); then
  sect "Phase 0: Verify app_to_domains vs apps/<app>/packages.json"
  verify_args=()
  for app in "${APPS[@]}"; do verify_args+=(--app "$app"); done
  if python3 "$SCRIPT_DIR/verify-app-domains.py" --gyanam "$GYANAM_DIR" "${verify_args[@]}"; then
    log "app_to_domains mapping verified"
  else
    err "app_to_domains mapping is WRONG for a requested app — fix repos.json (app_to_domains / mandi_domain) before deploying"
    exit 1
  fi
fi

# ── Phase 1: repo sync ─────────────────────────────────────────────────────
if (( PULL )); then
  sect "Phase 1: Sync framework + common repos"
  pull_bucket framework
  pull_bucket mandi_common

  if (( ${#APPS[@]} > 0 )); then
    sect "Phase 1b: Sync domain repos for requested apps"
    local_domains=()
    for app in "${APPS[@]}"; do
      # bash-3.2-compatible array read (macOS host bash is 3.2.57; `mapfile`
      # is bash-4+). The while-read-into-array idiom is the portable equivalent.
      app_doms=()
      while IFS= read -r _line; do app_doms+=("$_line"); done < <(repos_app_domains "$app")
      # guard empty-array expansion under set -u (bash 3.2)
      (( ${#app_doms[@]} > 0 )) && for d in "${app_doms[@]}"; do local_domains+=("$d"); done
    done
    # dedupe (bash-3.2-compatible — see note above). Guard the empty-array
    # expansion: under `set -u`, bash 3.2 errors on "${arr[@]}" when arr is
    # empty (unbound variable), so only dedupe when there's something to read.
    if (( ${#local_domains[@]} > 0 )); then
      _deduped=()
      while IFS= read -r _line; do _deduped+=("$_line"); done \
        < <(printf "%s\n" "${local_domains[@]}" | sort -u)
      local_domains=("${_deduped[@]}")
    fi

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

  # docker_build <dockerfile> <tag> [target]
  # The optional <target> selects a specific stage of a multi-stage Dockerfile.
  # Without it `docker build` builds the LAST stage — which for the multi-stage
  # 02-frontend-base.Dockerfile is `test` (a Playwright sidecar whose
  # `npx playwright install` is irrelevant to + breaks the deploy). The deploy
  # must target the mode's runtime stage, matching what the app Dockerfiles
  # consume (compose.dev.yml → `lochan-frontend-base:dev`; Dockerfile.frontend
  # → `lochan-frontend-base:prod`). Mirrors build-app.sh's targeted builds.
  docker_build() {
    local file="$1" tag="$2" target="${3:-}"
    local target_args=()
    [[ -n "$target" ]] && target_args=(--target "$target")
    # §FIX-TIER1-SECRET — 02-backend-base.Dockerfile precomputes the framework
    # embedding artifacts (§BUILD-STAGE-PRECOMPUTE Gemini build block). Thread
    # the API key as an env-sourced BuildKit secret; the Dockerfile mounts it
    # required=false, so a key-less build still succeeds — but SILENTLY ships
    # the base artifact-less (boot live-computes). Backend-base ONLY: no other
    # dockerfile mounts gemini_key. Mirrors daksh cli_dispatch.py Tier-1 +
    # services/deployer/_build.py.
    local secret_args=()
    if [[ "$file" == *02-backend-base.Dockerfile && -n "${AI_GEMINI_API_KEY:-}" ]]; then
      secret_args=(--secret "id=gemini_key,env=AI_GEMINI_API_KEY")
    fi
    echo -n "  build $tag ($file${target:+ --target $target}) ... "
    # ${arr[@]+"${arr[@]}"} — bash-3.2-safe expansion of a possibly-empty array
    # under set -u (a bare "${arr[@]}" errors "unbound variable" when empty).
    # DOCKER_BUILDKIT=1 on every build (required for the secret mount; matches
    # services/deployer/_build.py which enables it for all image builds).
    if DOCKER_BUILDKIT=1 docker build --quiet ${target_args[@]+"${target_args[@]}"} ${secret_args[@]+"${secret_args[@]}"} -f "$file" -t "$tag" . >/dev/null; then
      echo "ok"
    else
      err "build failed: $tag"; DEPLOY_FAILED=1; return 1
    fi
  }

  # Single-final-stage images — no target needed (last stage IS the artifact).
  docker_build docker/01-backend-deps.Dockerfile  lochan-deps-backend:latest
  docker_build docker/01-frontend-deps.Dockerfile lochan-deps-frontend:latest
  docker_build docker/02-backend-base.Dockerfile  lochan-backend-base:latest
  # Multi-stage frontend base (dev → prod → test): build the MODE's runtime
  # stage + tag it as the app Dockerfiles expect (NOT :latest = the test stage).
  docker_build docker/02-frontend-base.Dockerfile "lochan-frontend-base:${MODE}" "$MODE"
else
  warn "skipping base image builds (--skip-build)"
fi

# ── Phase 3: deploy apps ───────────────────────────────────────────────────
if (( DEPLOY )) && (( ${#APPS[@]} > 0 )); then
  sect "Phase 3: Deploy apps ($MODE mode)"
  for app in "${APPS[@]}"; do
    app_dir="$GYANAM_DIR/apps/$app"
    [[ -d "$app_dir" ]] || { err "app not found: $app_dir"; DEPLOY_FAILED=1; continue; }

    compose_file="compose.${MODE}.yml"
    [[ -f "$app_dir/$compose_file" ]] || compose_file="compose.yml"
    [[ -f "$app_dir/$compose_file" ]] || { err "$app: no compose file (tried compose.${MODE}.yml, compose.yml)"; DEPLOY_FAILED=1; continue; }

    echo "  [$app] using $compose_file"
    # Prod/staging compose declares `env_file: ${ENV_FILE:-.env.prod}`, but no
    # app ships a `.env.prod` — only `.env`. Without this, compose falls back to
    # a non-existent file and the bring-up fails INSIDE the subshell. Resolve
    # the env file loudly: prefer the mode-specific file, else `.env`, else
    # fail (do NOT silently proceed with a missing env — [[no-silent-try-except]]).
    app_env_file=".env.${MODE}"
    if [[ ! -f "$app_dir/$app_env_file" ]]; then
      if [[ -f "$app_dir/.env" ]]; then
        app_env_file=".env"
      else
        err "$app: no env file (tried .env.${MODE}, .env) — cannot deploy"
        DEPLOY_FAILED=1
        continue
      fi
    fi

    # Surface the subshell's exit status — a failed `docker compose up` must
    # NOT be reported as "restarted". The original printed success
    # unconditionally after the subshell, masking a failed bring-up as exit-0.
    if (
      # NOTE: `set -e` does NOT help here — bash disables errexit inside a
      # subshell used as an `if` condition (POSIX), so each step must check its
      # OWN exit with `|| exit 1` to abort the subshell → the outer `if` sees
      # non-zero → "deploy FAILED" not "[✓] deployed".
      cd "$app_dir" || exit 1
      export ENV_FILE="$app_env_file"

      # Build as its OWN step, BEFORE `up`. `docker compose up --build` can
      # return 0 even when the image BUILD failed (docker/compose#8213 — the
      # up-phase swallows the build exit code, worse under --force-recreate),
      # which is how a broken prod frontend build (`pnpm run build`) printed
      # "[✓] deployed" while zero containers came up. A standalone `build`
      # surfaces the real exit; `|| exit 1` aborts loudly; `up` then only starts
      # already-built images. [[tee-pipe-masks-exit-code]] — no masked exit.
      docker compose -f "$compose_file" build || exit 1
      docker compose -f "$compose_file" up -d --force-recreate || exit 1

      # Dev bring-up B1 (founder-ratified 2026-06-19): the generated
      # compose.dev.yml delivers domain/common packages via `develop.watch`
      # (#1330 mount-consolidation), which is INERT under plain `up -d`. And
      # activation alone is insufficient: `compose watch` can't combine with
      # `-d`, so it syncs AFTER `up -d`, but dev-entrypoint.sh installs domain
      # packages ONCE at boot against an empty /app/packages/ -> framework-only
      # boot. So: spawn watch (initial sync lands the packages) -> restart the
      # backend so the entrypoint re-installs editable with packages present
      # (`--skip-existing` makes the framework re-scan cheap). Dev-only; prod/
      # staging compose have no watch rules. Mirrors the daksh deployer's
      # activate_dev_watch_with_reinstall (sister PR in ssnukala/lochan).
      if [[ "$MODE" == "dev" ]]; then
        mkdir -p log
        docker compose -f "$compose_file" watch >log/compose-watch.log 2>&1 &
        sleep 8   # let the initial sync land the domain/common packages
        docker compose -f "$compose_file" restart backend \
          || warn "$app: backend restart after watch sync failed — domain packages may be absent (app could boot framework-only)"
      fi
    ); then
      log "$app: deployed ($compose_file, env=$app_env_file)"
    else
      err "$app: deploy FAILED (docker compose bring-up exited non-zero) — see output above"
      DEPLOY_FAILED=1
    fi
  done
  # Fail the whole run loudly if any app failed to deploy — never exit 0 on a
  # partial/failed deploy ([[no-silent-try-except]]; the old behavior masked
  # Phase-1b/Phase-3 failures as exit-0 "deployed nothing").
  if (( ${DEPLOY_FAILED:-0} )); then
    err "one or more apps failed to deploy"
    exit 1
  fi
elif (( ${#APPS[@]} == 0 )); then
  warn "no apps requested — use --app <name> to deploy one or more"
fi

sect "Done"
log "workspace: $GYANAM_DIR"
log "mode:      $MODE"
log "apps:      ${APPS[*]:-(none)}"
