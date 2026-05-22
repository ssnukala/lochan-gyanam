#!/usr/bin/env bash
# backup-encrypted.sh — pg_dump a Lochan app's Postgres and age-encrypt the
# output in one shot. The dump is NEVER written to disk in plaintext; we
# stream pg_dump stdout directly into age.
#
# Why age: modern, simple, audited. Public-key mode lets the backup host
# encrypt to a public key whose matching private key stays offline (on a
# YubiKey or in a password manager). Compromise of the backup host does
# not compromise backups.
#
# Prerequisites:
#   - age installed on the host (`apt install age` / `brew install age`).
#   - docker running with the target app's postgres service reachable.
#   - AGE_PUBLIC_KEY env var set OR --recipient <key> passed.
#   - A destination dir (defaults to ./backups).
#
# Usage:
#   ./backup-encrypted.sh <app-name>
#   ./backup-encrypted.sh fwprod01
#   ./backup-encrypted.sh fwprod01 --recipient age1abc... --dest /mnt/backups
#
# Restore recipe (on a machine with the matching private key):
#   age -d -i ~/.config/age/lochan-backup.txt \
#     backup-fwprod01-20260426-120000.sql.age \
#     > restore.sql
#   psql -U lochan -d fwprod01 -f restore.sql
#
# Key generation (one-time operator setup):
#   age-keygen -o ~/.config/age/lochan-backup.txt
#   # The first line is the age-keygen public key — put it in
#   # AGE_PUBLIC_KEY on the backup host.
#   # Store ~/.config/age/lochan-backup.txt OFFLINE (YubiKey, 1Password,
#   # or a printed page in a safe).

set -euo pipefail

# ── Argument parsing ───────────────────────────────────────────────
APP=""
RECIPIENT="${AGE_PUBLIC_KEY:-}"
DEST_DIR="./backups"
DB_SERVICE="postgres"
DB_USER="${POSTGRES_USER:-lochan}"

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") <app-name> [--recipient <age-public-key>] [--dest <dir>]

Required:
  <app-name>        App folder name under ./apps/ (e.g., fwprod01).

Optional:
  --recipient KEY   age public key (overrides \$AGE_PUBLIC_KEY).
  --dest DIR        Destination directory for the encrypted dump
                    (default: ./backups).
  --db-service N    Postgres service name in compose (default: postgres).
  --db-user U       Postgres user (default: \$POSTGRES_USER or 'lochan').

Environment:
  AGE_PUBLIC_KEY    age recipient public key. REQUIRED unless --recipient
                    is passed.
EOF
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --recipient) RECIPIENT="$2"; shift 2 ;;
        --dest)      DEST_DIR="$2"; shift 2 ;;
        --db-service) DB_SERVICE="$2"; shift 2 ;;
        --db-user)   DB_USER="$2"; shift 2 ;;
        -h|--help)   usage ;;
        -*)          echo "Unknown flag: $1" >&2; usage ;;
        *)
            if [[ -z "$APP" ]]; then
                APP="$1"
            else
                echo "Unexpected extra argument: $1" >&2
                usage
            fi
            shift
            ;;
    esac
done

[[ -n "$APP" ]] || usage

# ── Preflight checks ───────────────────────────────────────────────
if ! command -v age >/dev/null 2>&1; then
    echo "ERROR: 'age' binary not found. Install with:" >&2
    echo "  macOS:  brew install age" >&2
    echo "  Linux:  apt install age  (or download from https://age-encryption.org)" >&2
    exit 3
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: 'docker' not found in PATH." >&2
    exit 3
fi

if [[ -z "$RECIPIENT" ]]; then
    echo "ERROR: no age recipient. Set AGE_PUBLIC_KEY or pass --recipient." >&2
    exit 3
fi

# Accept common age key formats: age1... (X25519) or ssh-ed25519 AAAA...
if [[ ! "$RECIPIENT" =~ ^(age1|ssh-(ed25519|rsa)) ]]; then
    echo "ERROR: recipient does not look like an age or SSH public key:" >&2
    echo "  got: ${RECIPIENT:0:40}..." >&2
    exit 3
fi

APP_DIR="./apps/${APP}"
if [[ ! -d "$APP_DIR" ]]; then
    # Also try from gyanam/ root (script may run from util/scripts)
    APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)/apps/${APP}"
    if [[ ! -d "$APP_DIR" ]]; then
        echo "ERROR: app directory not found: ./apps/${APP}" >&2
        exit 4
    fi
fi

CONTAINER="${APP}-${DB_SERVICE}-1"
# Some compose project naming schemes use underscore instead of dash.
if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    ALT="${APP}_${DB_SERVICE}_1"
    if docker inspect "$ALT" >/dev/null 2>&1; then
        CONTAINER="$ALT"
    else
        echo "ERROR: postgres container not found (tried $CONTAINER and $ALT)." >&2
        echo "Is the app running?  cd apps/${APP} && docker compose ps" >&2
        exit 5
    fi
fi

# ── Dump + encrypt ────────────────────────────────────────────────
mkdir -p "$DEST_DIR"
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
OUT="${DEST_DIR}/backup-${APP}-${TIMESTAMP}.sql.age"

echo "Backing up ${APP} → ${OUT}"
echo "  container:  ${CONTAINER}"
echo "  db_user:    ${DB_USER}"
echo "  recipient:  ${RECIPIENT:0:16}..."

# Stream pg_dump output directly into age; plaintext never touches disk.
# Use --clean --if-exists so the dump can be replayed onto a fresh DB.
if ! docker exec "$CONTAINER" pg_dump \
        --username="$DB_USER" \
        --clean --if-exists \
        --no-owner --no-privileges \
        --format=plain \
        "$DB_USER" \
        | age --recipient "$RECIPIENT" --output "$OUT"
then
    echo "ERROR: pg_dump or age failed." >&2
    # Delete any partial output rather than leaving a truncated file.
    [[ -f "$OUT" ]] && rm -f "$OUT"
    exit 6
fi

# ── Report ────────────────────────────────────────────────────────
SIZE="$(wc -c <"$OUT" | tr -d ' ')"
echo "OK  ${OUT}  (${SIZE} bytes)"
echo ""
echo "Restore recipe:"
echo "  age -d -i <your-private-key-file> ${OUT} | docker exec -i ${CONTAINER} psql -U ${DB_USER}"
