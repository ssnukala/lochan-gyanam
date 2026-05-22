#!/usr/bin/env bash
#
# migrate-secrets-to-lockbox.sh
#
# Move an app's app-tier secrets from plaintext .env into LiteVault LOCKBOX.
# Leaves the bootstrap + infra vars in .env (needed before muulam can boot
# and read LOCKBOX). Safe by default — dry-runs + diffs + backs up before
# applying, and you confirm each step.
#
# Usage:
#   ./migrate-secrets-to-lockbox.sh <app>          # interactive (recommended)
#   ./migrate-secrets-to-lockbox.sh <app> --yes    # non-interactive (CI)
#   ./migrate-secrets-to-lockbox.sh --help
#
# Example:
#   ./util/scripts/migrate-secrets-to-lockbox.sh fwprod01
#
# Prerequisites:
#   - The target app must be running: `docker compose ps` in apps/<app>/
#     must show postgres + backend as Up. LOCKBOX is Postgres-backed.
#   - VAULT_LOCKBOX must be set in the app's .env (selects which lockbox
#     namespace to write into).
#   - daksh-cli must be executable at framework/lochan/packages/daksh/daksh-cli.
#
# What this does (in order):
#   1. Safety checks — app dir, .env exists, docker compose is up.
#   2. Backs up the current .env to ~/env-backups/<app>-<date>.env (outside
#      Dropbox on purpose — leaked values shouldn't sync).
#   3. Dry-run `daksh secrets migrate <app>` — writes .env.migrated.
#   4. Shows a diff of current .env vs planned .env.migrated.
#   5. Prompts for confirmation (unless --yes).
#   6. `daksh secrets migrate <app> --apply` — pushes app-tier keys to
#      LOCKBOX and replaces .env with bootstrap+infra-only version.
#   7. `daksh secrets list <app>` — prints KEY names confirming what
#      landed in LOCKBOX (never values).
#   8. `docker compose down && up -d` to restart the app so it re-reads
#      the new .env + picks up LOCKBOX-backed secrets on startup.
#   9. Prints a curl suggestion to smoke-test Gemini / OAuth paths.
#
# Restore (if something breaks after step 8):
#   cp ~/env-backups/<app>-<date>.env apps/<app>/.env
#   cd apps/<app> && docker compose down && docker compose up -d
#
# Shred the backup once you're satisfied the migration holds:
#   shred -u ~/env-backups/<app>-<date>.env    # Linux
#   rm -P  ~/env-backups/<app>-<date>.env      # macOS
#
# ---------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GYANAM_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DAKSH_CLI="${GYANAM_DIR}/framework/lochan/packages/daksh/daksh-cli"

# ---- arg parsing ------------------------------------------------

APP=""
AUTO_YES="false"
SHOW_HELP="false"

for arg in "$@"; do
    case "$arg" in
        --yes|-y)   AUTO_YES="true" ;;
        --help|-h)  SHOW_HELP="true" ;;
        --*)        echo "Unknown flag: $arg" >&2; exit 2 ;;
        *)          APP="$arg" ;;
    esac
done

if [ "$SHOW_HELP" = "true" ] || [ -z "$APP" ]; then
    sed -n '3,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
fi

# ---- safety checks ---------------------------------------------

APP_DIR="${GYANAM_DIR}/apps/${APP}"
ENV_FILE="${APP_DIR}/.env"

step() { printf '\n\033[1;34m[%s]\033[0m %s\n' "$1" "$2"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$1"; }
die()  { printf '  \033[1;31m✗\033[0m %s\n' "$1" >&2; exit 1; }

step 1/9 "Safety checks"

[ -d "$APP_DIR" ]   || die "No app directory at $APP_DIR"
[ -f "$ENV_FILE" ]  || die "No .env at $ENV_FILE"
[ -x "$DAKSH_CLI" ] || die "daksh-cli not executable at $DAKSH_CLI"

# Is the app running? LOCKBOX is Postgres-backed; the container must be up.
if ! (cd "$APP_DIR" && docker compose ps --status running 2>/dev/null | grep -qE '(postgres|backend)'); then
    warn "$APP doesn't look like it's running (docker compose ps)."
    warn "Start it first:  cd apps/$APP && docker compose up -d"
    if [ "$AUTO_YES" != "true" ]; then
        read -r -p "  Continue anyway? [y/N] " response
        [[ "$response" =~ ^[Yy]$ ]] || exit 0
    fi
fi

ok  "App directory + .env + daksh-cli found"

# ---- backup ----------------------------------------------------

step 2/9 "Back up current .env OUTSIDE Dropbox"

BACKUP_DIR="${HOME}/env-backups"
BACKUP_FILE="${BACKUP_DIR}/${APP}-$(date +%Y%m%d-%H%M%S).env"
mkdir -p "$BACKUP_DIR"
cp "$ENV_FILE" "$BACKUP_FILE"
chmod 600 "$BACKUP_FILE"
ok "Backed up to $BACKUP_FILE (chmod 600)"
warn "Shred this file once migration is verified: rm -P \"$BACKUP_FILE\""

# ---- dry-run ---------------------------------------------------

step 3/9 "Dry-run — writes .env.migrated without touching .env"

"$DAKSH_CLI" secrets migrate "$APP"
ok "Dry-run complete"

MIGRATED_FILE="${APP_DIR}/.env.migrated"
[ -f "$MIGRATED_FILE" ] || die "Expected .env.migrated at $MIGRATED_FILE, not found"

# ---- diff ------------------------------------------------------

step 4/9 "Diff: current .env vs planned .env.migrated"

if diff -u "$ENV_FILE" "$MIGRATED_FILE"; then
    warn "No differences — either already migrated or .env has no app-tier keys."
    exit 0
fi

# ---- confirmation ---------------------------------------------

if [ "$AUTO_YES" != "true" ]; then
    step 5/9 "Confirm"
    printf '  This will PUSH app-tier keys into LOCKBOX and REPLACE %s.\n' "$ENV_FILE"
    read -r -p "  Proceed with --apply? [y/N] " response
    [[ "$response" =~ ^[Yy]$ ]] || { ok "Aborted. No changes made."; exit 0; }
else
    step 5/9 "Auto-confirm (--yes)"
fi

# ---- apply -----------------------------------------------------

step 6/9 "Apply migration — push to LOCKBOX + rewrite .env"

"$DAKSH_CLI" secrets migrate "$APP" --apply
ok "Migration applied"

# ---- list ------------------------------------------------------

step 7/9 "Verify LOCKBOX contents (key names only)"

"$DAKSH_CLI" secrets list "$APP" || warn "secrets list failed — verify manually"

# ---- restart ---------------------------------------------------

step 8/9 "Restart $APP so it re-reads the new .env + LOCKBOX"

if [ "$AUTO_YES" != "true" ]; then
    read -r -p "  docker compose down + up -d now? [y/N] " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        (cd "$APP_DIR" && docker compose down && docker compose up -d)
        ok "$APP restarted"
    else
        warn "Skipped restart. Run manually: cd apps/$APP && docker compose down && docker compose up -d"
    fi
else
    (cd "$APP_DIR" && docker compose down && docker compose up -d)
    ok "$APP restarted"
fi

# ---- smoke test hint ------------------------------------------

step 9/9 "Smoke-test the app"

cat <<HINT
  The migration is complete. Smoke-test the LLM + OAuth paths next:

    # Hit a chat endpoint and confirm Gemini/Claude responds
    curl -s http://localhost:\${BACKEND_PORT:-8000}/api/health | jq .
    curl -s -X POST http://localhost:\${BACKEND_PORT:-8000}/api/chat \\
         -H 'Content-Type: application/json' \\
         -d '{"message": "hello"}' | jq .

  If anything fails, restore from backup:
    cp "$BACKUP_FILE" "$ENV_FILE"
    cd "$APP_DIR" && docker compose down && docker compose up -d

  When you're confident the migration holds, shred the backup:
    rm -P "$BACKUP_FILE"   # macOS
    shred -u "$BACKUP_FILE"   # Linux
HINT

ok "Done."
