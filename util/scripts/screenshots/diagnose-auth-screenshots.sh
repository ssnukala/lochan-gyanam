#!/usr/bin/env bash
# diagnose-auth-screenshots.sh — why did authenticated persona screenshots fail?
#
# take-screenshots.sh PASSES on unauthenticated patent-demo captures even when
# the authenticated_admin.spec aborts with `authenticated=false`. This wrapper
# isolates WHERE the auth chain breaks so you don't hand-roll the probe each time.
#
# It checks, in order:
#   1. pw-login runs + writes storageState.json
#   2. the storageState cookie DOMAIN + origin (the #1420 fix target — must be
#      the sidecar browse host <app>-frontend-1, NOT localhost)
#   3. /api/manifest authenticated=true WITH those cookies as a header
#      (proves the cookies themselves are valid), vs the no-cookie control
#
# If (3) is TRUE-with-cookies but the sidecar spec still says authenticated=false,
# the break is in the Playwright spec's cookie ATTACH logic (storageState load /
# domain match), NOT in pw-login or the backend — route to the screenshot-harness
# owner (daksh/S3 lane), don't re-run pw-login.
#
# Usage:  util/scripts/build/diagnose-auth-screenshots.sh <app>   (default fwprod01)
set -euo pipefail

APP="${1:-fwprod01}"
GYANAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$GYANAM_DIR"
DAKSH_CLI="$GYANAM_DIR/util/scripts/daksh-docker"  # shared shim: host venv or containerized (server has no venv)
STORAGE="$GYANAM_DIR/apps/$APP/storageState.json"
FRONTEND_CTR="${APP}-frontend-1"
BROWSE_HOST="${APP}-frontend-1"
BROWSE_URL="http://${BROWSE_HOST}:3000"

ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[0;31m✗\033[0m %s\n' "$1"; }
note() { printf '    \033[2m%s\033[0m\n' "$1"; }

echo "── diagnose-auth-screenshots.sh: auth-chain probe for $APP ──"

# ── 1. containers present ──────────────────────────────────────────────
echo "[1/4] Containers"
if docker ps --format '{{.Names}}' | grep -qx "$FRONTEND_CTR"; then
  ok "$FRONTEND_CTR running"
else
  bad "$FRONTEND_CTR NOT running — bring the app up first"; exit 2
fi

# ── 2. pw-login + storageState ─────────────────────────────────────────
echo "[2/4] pw-login + storageState cookie domain (#1420 fix target)"
if [[ ! -x "$DAKSH_CLI" ]]; then bad "daksh-cli not executable at $DAKSH_CLI"; exit 2; fi
if PW_OUT="$("$DAKSH_CLI" pw-login "$APP" 2>&1)"; then
  ok "daksh pw-login $APP PASS"
else
  bad "daksh pw-login $APP FAILED:"; printf '%s\n' "$PW_OUT" | tail -3 | sed 's/^/      /'; exit 3
fi
if [[ ! -f "$STORAGE" ]]; then bad "no storageState.json at $STORAGE"; exit 3; fi

# inspect cookie domains + origins (the thing #1420 changed)
DOMAIN_REPORT="$(python3 - "$STORAGE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
cookies = d.get("cookies", [])
origins = [o.get("origin") for o in d.get("origins", [])]
doms = sorted({c.get("domain") for c in cookies})
print("count=%d" % len(cookies))
print("domains=%s" % ",".join(doms))
print("origins=%s" % ",".join(origins))
PY
)"
COUNT="$(sed -n 's/^count=//p' <<<"$DOMAIN_REPORT")"
DOMAINS="$(sed -n 's/^domains=//p' <<<"$DOMAIN_REPORT")"
ORIGINS="$(sed -n 's/^origins=//p' <<<"$DOMAIN_REPORT")"
note "cookies=$COUNT  domains=[$DOMAINS]  origins=[$ORIGINS]"
if grep -q "$BROWSE_HOST" <<<"$DOMAINS"; then
  ok "cookie domain targets sidecar browse host ($BROWSE_HOST) — #1420 applied"
elif grep -q "localhost" <<<"$DOMAINS"; then
  bad "cookie domain is localhost — #1420 NOT applied (sidecar won't attach these)"
else
  note "cookie domain is [$DOMAINS] — neither host nor localhost; inspect manually"
fi

# ── 3. authenticated manifest probe (cookies-as-header) ────────────────
echo "[3/4] /api/manifest authenticated check — from inside the sidecar network"
COOKIE_HDR="$(python3 - "$STORAGE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(";".join("{}={}".format(c["name"], c["value"]) for c in d.get("cookies", [])))
PY
)"
AUTH_WITH="$(docker exec "$FRONTEND_CTR" sh -c "wget -qO- --header='Cookie: $COOKIE_HDR' $BROWSE_URL/api/manifest 2>/dev/null" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("authenticated"))' 2>/dev/null || echo "ERR")"
AUTH_WITHOUT="$(docker exec "$FRONTEND_CTR" sh -c "wget -qO- $BROWSE_URL/api/manifest 2>/dev/null" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("authenticated"))' 2>/dev/null || echo "ERR")"
note "manifest authenticated WITH cookies    = $AUTH_WITH"
note "manifest authenticated WITHOUT cookies = $AUTH_WITHOUT  (control, expect False)"

# ── 4. verdict ─────────────────────────────────────────────────────────
echo "[4/4] Verdict"
if [[ "$AUTH_WITH" == "True" ]]; then
  ok "cookies authenticate at the HTTP layer — storageState + #1420 are CORRECT."
  echo ""
  echo "  → If take-screenshots.sh STILL reports authenticated=false, the break is"
  echo "    in the Playwright spec's cookie ATTACH path (storageState load / domain"
  echo "    match in authenticated_admin.spec.ts), NOT pw-login/backend. Route to the"
  echo "    screenshot-harness owner (daksh/S3 lane). Do NOT re-run pw-login — it's fine."
  exit 0
elif [[ "$AUTH_WITHOUT" == "True" ]]; then
  bad "backend returns authenticated=true even WITHOUT cookies — auth gate misconfigured (backend lane)."
  exit 4
else
  bad "cookies do NOT authenticate ($AUTH_WITH) — pw-login wrote an invalid/expired session, or the"
  echo "    user lacks access. Re-check pw-login credentials / the seeded login user."
  exit 4
fi
