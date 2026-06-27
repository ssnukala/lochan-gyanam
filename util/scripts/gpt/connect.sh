#!/usr/bin/env bash
# util/scripts/gpt/connect.sh — one-command "connect ChatGPT to a Lochan app's MCP".
#
# ⚠ WHAT THIS IS (read once): the OpenAI ChatGPT *desktop app* has no "add MCP
# server" box — that UI is gated by OpenAI to Business/Enterprise Developer-mode,
# server-side, off your machine. NO local script can inject it. So this connects
# ChatGPT to Lochan's MCP tools *via the OpenAI API* (a terminal session you drive,
# or your own code), NOT inside the desktop app. The bridges are the per-developer
# stopgap; the real goal is each Lochan app being CERTIFIED as a native MCP
# connector (tracked separately — the framework is agentic by design).
#
# This wrapper just makes the bridge turnkey: it creates/uses a venv, installs
# `openai`, and runs util/scripts/mcp/chatgpt-mcp-bridge.py for you.
#
# Usage:
#   util/scripts/gpt/connect.sh <app> [--local] [--list] [--ask "question"]
#     <app>     fwprod01 | longterm01
#     (no flag) OpenAI Responses-API native remote `mcp` tool — OpenAI's cloud
#               connects to Lochan's SSE endpoint directly (simplest).
#     --local   local bridge: mcp-remote does OAuth+SSE on THIS host, tools are
#               handed to ChatGPT as function tools (login + execution stay local).
#     --list    (with --local) just list the Lochan tools, no OpenAI key needed.
#     --ask Q   one-shot question.
#
# Env:
#   OPENAI_API_KEY   required (except for `--local --list`).
#
# Examples:
#   export OPENAI_API_KEY=sk-...
#   util/scripts/gpt/connect.sh fwprod01 --local --list
#   util/scripts/gpt/connect.sh fwprod01 --ask "which users exist?"
set -euo pipefail

# Derive the gyanam repo root from this script's own location
# (util/scripts/gpt/<script> → three levels up) so it works on any machine.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BRIDGE="$REPO/util/scripts/mcp/chatgpt-mcp-bridge.py"
VENV="$REPO/util/scripts/gpt/.venv"
cd "$REPO"

if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
APP="$1"; shift
case "$APP" in
  fwprod01|longterm01) ;;
  *) echo "unknown app '$APP' — one of: fwprod01, longterm01" >&2; exit 2 ;;
esac

# --list-only with --local needs no OpenAI key and no venv install.
WANT_LIST=0; WANT_LOCAL=0
for a in "$@"; do
  [[ "$a" == "--list" ]] && WANT_LIST=1
  [[ "$a" == "--local" ]] && WANT_LOCAL=1
done

# Provision a venv with the openai SDK (skip the install if only listing tools).
if [[ ! -d "$VENV" ]]; then
  echo "── creating venv at util/scripts/gpt/.venv ──" >&2
  python3 -m venv "$VENV"
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
if [[ "$WANT_LOCAL" -eq 1 && "$WANT_LIST" -eq 1 ]]; then
  : # --local --list: bridge uses stdlib only; no pip needed
else
  python -c "import openai" 2>/dev/null || {
    echo "── installing openai SDK into the venv (one-time) ──" >&2
    pip install --quiet --upgrade pip openai >&2
  }
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    echo "set OPENAI_API_KEY first:  export OPENAI_API_KEY=sk-..." >&2
    echo "(or use '$APP --local --list' to inspect Lochan's tools with no key)" >&2
    exit 3
  fi
fi

echo "── connecting ChatGPT (API) → $APP MCP ──" >&2
echo "   (NOTE: this is the API path, NOT the ChatGPT desktop app — see header)" >&2
exec python "$BRIDGE" "$APP" "$@"
