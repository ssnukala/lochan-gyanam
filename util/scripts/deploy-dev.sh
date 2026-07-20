#!/usr/bin/env bash
#
# deploy-dev.sh
#
# Simple wrapper around `daksh deploy <app> --env dev` for local iteration.
#
# The "dev" env path deliberately SKIPS the encrypted production rails:
#   - no cosign signature verification
#   - no Caddy TLS reverse proxy (app runs on plain http://localhost:<port>)
#   - no backup-encrypted.sh hook
# This is by design — dev is for fast iteration on a trusted workstation.
#
# The encrypted path (staging + prod) is the DEFAULT for everything that
# touches real users. Use deploy-dev.sh ONLY for local iteration.
#
# Usage:
#   ./util/scripts/deploy-dev.sh <app> [package ...]
#   ./util/scripts/deploy-dev.sh --help
#
# Examples:
#   ./util/scripts/deploy-dev.sh fwtest01
#   ./util/scripts/deploy-dev.sh fwprod01 grahaka pestpro
#
# What this does:
#   1. Safety check — app dir + daksh-cli must exist.
#   2. Echoes the staging/prod alternative in case you picked the wrong path.
#   3. Runs `daksh deploy <app> --env dev [--packages ...]`.
#   4. Prints local URLs (backend/frontend/admin-MCP) once backend is healthy.
#
# For the encrypted path, use:
#   ./framework/lochan/packages/daksh/daksh-cli deploy <app> --env staging  # staging first
#   ./framework/lochan/packages/daksh/daksh-cli deploy <app> --env prod     # promote when ready
#
# ---------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GYANAM_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DAKSH_CLI="${GYANAM_DIR}/util/scripts/daksh-docker"  # shared shim: host venv or containerized (server has no venv)

# ---- arg parsing ------------------------------------------------

APP=""
PACKAGES=()
SHOW_HELP="false"

for arg in "$@"; do
    case "$arg" in
        --help|-h) SHOW_HELP="true" ;;
        --*) echo "Unknown flag: $arg" >&2; exit 2 ;;
        *)
            if [ -z "$APP" ]; then
                APP="$arg"
            else
                PACKAGES+=("$arg")
            fi
            ;;
    esac
done

if [ "$SHOW_HELP" = "true" ] || [ -z "$APP" ]; then
    sed -n '3,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
fi

# ---- style helpers ---------------------------------------------

step() { printf '\n\033[1;34m[%s]\033[0m %s\n' "$1" "$2"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$1"; }
die()  { printf '  \033[1;31m✗\033[0m %s\n' "$1" >&2; exit 1; }

# ---- safety checks ---------------------------------------------

APP_DIR="${GYANAM_DIR}/apps/${APP}"

step 1/3 "Safety checks"

[ -x "$DAKSH_CLI" ] || die "daksh-cli not executable at $DAKSH_CLI"

if [ ! -d "$APP_DIR" ]; then
    warn "App '$APP' does not exist yet at $APP_DIR"
    warn "daksh deploy will create it if packages are provided."
    if [ ${#PACKAGES[@]} -eq 0 ]; then
        die "No packages given and app does not exist — nothing to do. Usage: $0 <app> <package> [package ...]"
    fi
fi

ok "daksh-cli found at $DAKSH_CLI"

# ---- reminder --------------------------------------------------

step 2/3 "Environment notice"

warn "This is the DEV path. Skipped: cosign verify, Caddy TLS, backup encryption."
warn "For staging/prod use:  $DAKSH_CLI deploy $APP --env staging  (then --env prod)"

# ---- deploy ----------------------------------------------------

step 3/3 "daksh deploy $APP --env dev"

DEPLOY_CMD=("$DAKSH_CLI" deploy "$APP" --env dev)
if [ ${#PACKAGES[@]} -gt 0 ]; then
    DEPLOY_CMD+=(--packages "${PACKAGES[@]}")
fi

printf '  running: %s\n' "${DEPLOY_CMD[*]}"
"${DEPLOY_CMD[@]}"

# ---- print local URLs ------------------------------------------

# Detect backend port from .env.dev (compose default) or .env.
BACKEND_PORT="8592"
FRONTEND_PORT="3000"
if [ -d "$APP_DIR" ]; then
    for env_name in .env.dev .env; do
        env_file="${APP_DIR}/${env_name}"
        if [ -f "$env_file" ]; then
            while IFS='=' read -r key value; do
                case "$key" in
                    PORT_BACKEND)  BACKEND_PORT="${value//\"/}" ;;
                    PORT_FRONTEND) FRONTEND_PORT="${value//\"/}" ;;
                esac
            done < "$env_file"
            break
        fi
    done
fi

cat <<URLS

  Dev deploy complete. Local URLs:
    Backend API:    http://localhost:${BACKEND_PORT}
    Frontend:       http://localhost:${FRONTEND_PORT}
    Health check:   http://localhost:${BACKEND_PORT}/api/health
    Manifest:       http://localhost:${BACKEND_PORT}/api/manifest
    Patent banner:  curl -sI http://localhost:${BACKEND_PORT}/api/health | grep X-Lochan-Patent

  Next steps:
    docker compose -f apps/${APP}/compose.dev.yml logs -f backend
    docker compose -f apps/${APP}/compose.dev.yml ps

  To promote this app to the encrypted path when it's ready:
    $DAKSH_CLI deploy $APP --env staging
URLS

ok "Done."
