#!/usr/bin/env bash
# probe-mcp-oauth.sh — rerunnable autowired harness for the MCP OAuth-discovery handshake.
#
# Verifies the framework's MCP-over-OAuth onboarding surface end-to-end on a RUNNING app,
# the way Claude Desktop's `mcp-remote` bridge / MCP Inspector exercise it (RFC 9728 + RFC
# 8414 + RFC 7591). The headline check is the RFC 9728 §3.1 PATH-INSERTED protected-resource
# discovery — the route a bare-only registration 404s on (the "Server disconnected"
# regression). See framework/lochan/packages/muulam/backend/muulam/jharokha/agent_card.py.
#
# Promoted to a reusable autowired script per the founder rule "validation runs MUST produce
# reusable autowired scripts" (mirrors probe-chat-writes.sh). It does NOT hardcode ports —
# it reads apps/<app>/.env for the no-token gate check and uses `daksh api` (which self-
# resolves the app + handles auth) for the authenticated discovery/register probes.
#
# What it checks (a scoreboard line per check, PASS/FAIL):
#   1. RFC 8414  AS metadata     GET /.well-known/oauth-authorization-server        -> 200 + endpoints
#   2. RFC 9728  bare PR doc      GET /.well-known/oauth-protected-resource           -> 200 + resource
#   3. RFC 9728  PATH-INSERTED    GET /.well-known/oauth-protected-resource/api/jharokha/mcp/sse
#                                                                                     -> 200  (THE FIX)
#   4. RFC 9728  canonical resource: bare == suffixed payload (suffix only routes the lookup)
#   5. RFC 7591  DCR register     POST /api/oauth/provider/register                   -> 201 + client_id
#   6. B0 gate   MCP data plane unauth (raw curl, no token)  /api/jharokha/mcp/tools  -> 401
#
# The interactive authorize->token leg (steps 4-5 of the MCP-OAuth flow) needs a browser
# login + PKCE auth-code, which a headless script can't complete; it is reported as MANUAL
# with the exact `mcp-remote` / MCP Inspector command to finish + verify RBAC scope. The
# deterministic surface above is what regresses silently, so that is what this gates.
#
# Usage:
#   util/scripts/mcp/probe-mcp-oauth.sh [APP] [USER] [LABEL]
#     APP    default fwprod01
#     USER   default super-admin from apps/<app>/.env (or email:password)
#     LABEL  optional run label (tags the results file; e.g. "post-rfc9728-fix")
#
# Output: util/scripts/mcp/.probe-results/mcp-oauth-<APP>-<LABEL|timestamp>.json + a scoreboard.
# Requires: daksh-cli, python3, curl.
set -euo pipefail

REPO="/Users/srinivasnukala/Dropbox/Sites/docker/gyanam"
CLI="framework/lochan/packages/daksh/daksh-cli"
APP="${1:-fwprod01}"
USER_AUTH="${2:-}"
RUN_LABEL="${3:-}"
cd "$REPO"

ENV_FILE="apps/${APP}/.env"
# Autowire the backend origin from the app's own env (don't hardcode the port).
BACKEND_URL="$(grep -E '^BACKEND_URL=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
if [[ -z "$BACKEND_URL" ]]; then
  PORT_BACKEND="$(grep -E '^PORT_BACKEND=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || echo 8600)"
  BACKEND_URL="http://localhost:${PORT_BACKEND}"
fi

RESULTS_DIR="util/scripts/mcp/.probe-results"
mkdir -p "$RESULTS_DIR"
STAMP="$(python3 -c 'import datetime; print(datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))')"
RESULTS_FILE="$RESULTS_DIR/mcp-oauth-${APP}-${RUN_LABEL:-$STAMP}.json"

PASS=0; FAIL=0
declare -a RESULTS=()

# daksh api wrapper — authenticated GET/POST against the app (self-resolves the app/port).
dapi() {
  local method="$1" path="$2" body="${3:-}"
  local args=("$APP" "$method" "$path")
  [[ -n "$body" ]] && args+=("$body")
  args+=("--format" "json")
  [[ -n "$USER_AUTH" ]] && args+=("--as" "$USER_AUTH")
  "./$CLI" api "${args[@]}" 2>/dev/null || true
}

# Record a check result + print a scoreboard line.
record() {
  local id="$1" verdict="$2" detail="$3"
  if [[ "$verdict" == "PASS" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
  RESULTS+=("$(python3 -c "import json,sys; print(json.dumps({'check':sys.argv[1],'verdict':sys.argv[2],'detail':sys.argv[3]}))" "$id" "$verdict" "$detail")")
  printf '  %-4s %-46s %s\n' "[$verdict]" "$id" "$detail"
}

# Extract a JSON field from a daksh-api json envelope (data may be at top level or under .data).
jget() {
  python3 -c "
import json,sys
raw=sys.stdin.read().strip()
try: o=json.loads(raw)
except Exception: print(''); sys.exit()
o=o.get('data',o) if isinstance(o,dict) else o
cur=o
for k in sys.argv[1].split('.'):
    if isinstance(cur,dict) and k in cur: cur=cur[k]
    else: print(''); sys.exit()
print(cur if isinstance(cur,str) else json.dumps(cur))
" "$1"
}

echo "── MCP OAuth-discovery probe ── app=$APP  backend=$BACKEND_URL ──"

# 1. RFC 8414 — Authorization-Server metadata.
AS_DOC="$(dapi GET /.well-known/oauth-authorization-server)"
AS_AUTHZ="$(printf '%s' "$AS_DOC" | jget authorization_endpoint)"
if [[ -n "$AS_AUTHZ" ]]; then
  record "rfc8414-as-metadata" PASS "authorization_endpoint=$AS_AUTHZ"
else
  record "rfc8414-as-metadata" FAIL "no authorization_endpoint (doc: ${AS_DOC:0:80})"
fi

# 2. RFC 9728 — bare protected-resource doc.
PR_BARE="$(dapi GET /.well-known/oauth-protected-resource)"
PR_RES="$(printf '%s' "$PR_BARE" | jget resource)"
if [[ -n "$PR_RES" ]]; then
  record "rfc9728-bare" PASS "resource=$PR_RES"
else
  record "rfc9728-bare" FAIL "no resource field (doc: ${PR_BARE:0:80})"
fi

# 3. RFC 9728 §3.1 — PATH-INSERTED protected-resource discovery (THE FIX).
#    A bare-only registration 404s here -> mcp-remote can't discover the AS.
PR_SUFFIX="$(dapi GET /.well-known/oauth-protected-resource/api/jharokha/mcp/sse)"
PR_SUFFIX_RES="$(printf '%s' "$PR_SUFFIX" | jget resource)"
if [[ -n "$PR_SUFFIX_RES" ]]; then
  record "rfc9728-path-inserted" PASS "resource=$PR_SUFFIX_RES (suffixed discovery resolves)"
else
  record "rfc9728-path-inserted" FAIL "404/empty — the 'Server disconnected' regression (doc: ${PR_SUFFIX:0:80})"
fi

# 4. Canonical-resource invariant: suffixed doc == bare doc (suffix only routes the lookup).
if [[ -n "$PR_RES" && "$PR_RES" == "$PR_SUFFIX_RES" ]]; then
  record "rfc9728-canonical-resource" PASS "bare==suffixed resource ($PR_RES)"
else
  record "rfc9728-canonical-resource" FAIL "bare='$PR_RES' suffixed='$PR_SUFFIX_RES' (must match)"
fi

# 5. RFC 7591 — dynamic client registration.
REG="$(dapi POST /api/oauth/provider/register '{"client_name":"probe-mcp-oauth","redirect_uris":["http://localhost:9999/cb"]}')"
CLIENT_ID="$(printf '%s' "$REG" | jget client_id)"
if [[ -n "$CLIENT_ID" ]]; then
  record "rfc7591-dcr-register" PASS "client_id=$CLIENT_ID"
else
  record "rfc7591-dcr-register" FAIL "no client_id (resp: ${REG:0:80})"
fi

# 6. B0 gate — MCP data plane rejects an unauthenticated request. RAW CURL (no token) is the
#    correct tool here (daksh api always carries a session and would mask the gate); this is
#    the documented no-token exception from MCP-CLIENT-ONBOARDING.md.
GATE_CODE="$(curl -s -o /dev/null -w '%{http_code}' "${BACKEND_URL}/api/jharokha/mcp/tools" 2>/dev/null || echo 000)"
if [[ "$GATE_CODE" == "401" ]]; then
  record "b0-unauth-gate" PASS "/api/jharokha/mcp/tools -> 401 (gated)"
else
  record "b0-unauth-gate" FAIL "/api/jharokha/mcp/tools -> $GATE_CODE (expected 401)"
fi

# Manual leg — the interactive authorize->token->RBAC check (browser login + PKCE).
echo
echo "  [MANUAL] Complete the handshake + RBAC-scope check (browser-interactive PKCE leg):"
echo "    npx -y mcp-remote ${BACKEND_URL}/api/jharokha/mcp/sse"
echo "    # or: npx @modelcontextprotocol/inspector  (SSE, URL ${BACKEND_URL}/api/jharokha/mcp/sse)"
echo "    # log in as super-admin -> tools/list -> tools/call (list users) sees ALL rows;"
echo "    # log in as a scoped user -> the same call sees only their rows (AGENT_CARD rbac_scope)."

# Emit results JSON.
python3 -c "
import json,sys
checks=[json.loads(x) for x in sys.argv[3:]]
json.dump({'app':sys.argv[1],'backend':sys.argv[2],'checks':checks,
           'pass':sum(c['verdict']=='PASS' for c in checks),
           'fail':sum(c['verdict']=='FAIL' for c in checks)},
          open('$RESULTS_FILE','w'), indent=2)
" "$APP" "$BACKEND_URL" "${RESULTS[@]}"

echo
echo "── SCOREBOARD: ${PASS} PASS / ${FAIL} FAIL  (deterministic checks) ──"
echo "── results: $RESULTS_FILE ──"
[[ "$FAIL" -eq 0 ]] || exit 1
