#!/usr/bin/env bash
# util/scripts/gemini/chat_gemini.sh — interactive chat with a Lochan app via Gemini.
#
# An interactive REPL (read-eval-print loop): you type a question, Gemini answers —
# calling the Lochan app's MCP tools as needed — and the conversation context
# carries across turns. The closest thing to "chatting with the Gemini app",
# except it runs in your terminal and talks to YOUR staging app.
#
#   you> how many users are there?
#   gemini> There are 3 users in the system.
#   you> what are their names?            (it remembers the previous turn)
#   gemini> ...
#   you> exit
#
# ⚠ This is NOT the Gemini desktop app — that app has no way to connect to a
# custom server. This is Gemini-the-model talking to staging.lochan.ai via the
# bridge. It's a founder self-test tool; the durable goal is each Lochan app
# being CERTIFIED as a native connector (tracked separately).
#
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║ ⚠ DATA PRIVACY — YOUR APP DATA IS SENT TO GOOGLE. THIS IS NOT LOCAL-ONLY. ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# When Gemini calls a Lochan tool, the TOOL RESULTS — the actual rows it queried
# (user names, emails, records, any field it asked for) — plus your question and
# the tool schemas are sent to Google's Gemini API so the model can answer. The
# script runs on your machine, but it is a PIPE TO GOOGLE, not a local sandbox.
#   • Stays local: your OAuth token / Lochan login, the database itself.
#   • Goes to Google: the question, the 331 tool schemas, and the data Gemini
#     requests via tool calls (the results).
#   • RBAC still applies AT THE SOURCE: Gemini only receives data the logged-in
#     Lochan user is allowed to see — but whatever that user can see and Gemini
#     asks for, Google receives.
#   • The key in apps/<app>/.env is a free Google AI-Studio key; on the free tier
#     Google MAY USE THIS DATA TO IMPROVE ITS PRODUCTS. DO NOT point this at real
#     customer PII on a free key. For privacy: use Vertex with a data-processing
#     agreement, or Lochan's own chat with a self-hosted model.
#
# It's turnkey: creates/uses a venv, installs google-genai, sources the Gemini
# key from the app's own .env (AI_GEMINI_API_KEY), and runs the bridge in --chat.
#
# Usage:
#   util/scripts/gemini/chat_gemini.sh [app]
#     app   fwprod01 (default) | longterm01
#
# Override the key explicitly if you don't want the one in apps/<app>/.env:
#   GEMINI_API_KEY=... util/scripts/gemini/chat_gemini.sh fwprod01
set -euo pipefail

# Derive the gyanam repo root from this script's own location
# (util/scripts/gemini/<script> → three levels up) so it works on any machine.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BRIDGE="$REPO/util/scripts/mcp/gemini-mcp-bridge.py"
VENV="$REPO/util/scripts/gemini/.venv"
cd "$REPO"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
APP="${1:-fwprod01}"
case "$APP" in
  fwprod01|longterm01) ;;
  *) echo "unknown app '$APP' — one of: fwprod01, longterm01" >&2; exit 2 ;;
esac

# Source the Gemini key from the app's .env unless already set in the environment.
if [[ -z "${GEMINI_API_KEY:-}" ]]; then
  key="$(grep -E '^AI_GEMINI_API_KEY=' "apps/$APP/.env" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  if [[ -z "$key" ]]; then
    echo "no AI_GEMINI_API_KEY in apps/$APP/.env and GEMINI_API_KEY not set" >&2
    exit 3
  fi
  export GEMINI_API_KEY="$key"
  echo "── using AI_GEMINI_API_KEY from apps/$APP/.env (${#GEMINI_API_KEY} chars) ──" >&2
fi

# Provision the venv with google-genai (one-time).
if [[ ! -d "$VENV" ]]; then
  echo "── creating venv at util/scripts/gemini/.venv ──" >&2
  python3 -m venv "$VENV"
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -c "import google.genai" 2>/dev/null || {
  echo "── installing google-genai into the venv (one-time) ──" >&2
  pip install --quiet --upgrade pip google-genai >&2
}

echo "── chatting with $APP via Gemini (Ctrl-D or 'exit' to quit) ──" >&2
echo "⚠ PRIVACY: data Gemini queries from $APP (tool results — real rows/fields) is" >&2
echo "  sent to Google's Gemini API to answer. NOT local. Free AI-Studio key may be" >&2
echo "  used by Google to improve products — do NOT use with real customer PII." >&2
exec python "$BRIDGE" "$APP" --chat
