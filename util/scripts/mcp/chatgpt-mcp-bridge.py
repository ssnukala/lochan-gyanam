#!/usr/bin/env python3
"""chatgpt-mcp-bridge.py — use a Lochan app's MCP tools from ChatGPT (the API).

⚠ READ THIS FIRST — what this does and does NOT do:
  - This is a TERMINAL program that talks to the OpenAI **API**. It does NOT, and
    cannot, add MCP tools to your installed ChatGPT **desktop app** — that app has
    no "add MCP server" box, and that UI is gated by OpenAI to Business/Enterprise
    "Developer mode", server-side, off your machine. No local script can inject it.
  - So: this bridge gives YOU (from a terminal / your own script) a ChatGPT model
    that can call Lochan's MCP tools. The desktop ChatGPT app stays as-is.

There are TWO ways the OpenAI API can reach Lochan's MCP, and this script does the
one that needs no extra moving parts:

  PRIMARY — OpenAI Responses API native remote `mcp` tool (DEFAULT here).
    OpenAI's servers connect DIRECTLY to Lochan's MCP SSE endpoint and run the
    OAuth + tools/list + tools/call themselves. You pass the server_url; you do
    NOT run mcp-remote and you do NOT convert tools. Simplest + most robust.
    Requirement: Lochan's SSE endpoint must be reachable FROM OpenAI's cloud
    (it is — staging.* is public HTTPS). The OAuth login happens via OpenAI's
    MCP connector flow.

  FALLBACK — local function-calling bridge (--local), the exact twin of
    gemini-mcp-bridge.py: spawn mcp-remote (OAuth+SSE on YOUR machine), tools/list,
    convert each tool to an OpenAI function tool, run the chat tool-call loop.
    Use this if the Responses-API mcp tool isn't available on your account, or if
    you want the login + execution to stay on your host.

Requirements:
  - `pip install openai` (NOT on this host — use a venv).
  - `OPENAI_API_KEY` env var.
  - For --local only: `npx mcp-remote` (cached on this host).

Usage:
  pip install openai
  export OPENAI_API_KEY=...
  util/scripts/mcp/chatgpt-mcp-bridge.py <app> --ask "which users exist?"     # Responses-API mcp tool
  util/scripts/mcp/chatgpt-mcp-bridge.py <app> --local --ask "..."            # local mcp-remote bridge
  util/scripts/mcp/chatgpt-mcp-bridge.py <app> --local --list                 # list bridged tools (no key)
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
from itertools import count

APP_SSE = {
    "fwprod01": "https://staging.lochan.ai/api/jharokha/mcp/sse",
    "longterm01": "https://staging.longterm366.ai/api/jharokha/mcp/sse",
}

MODEL = "gpt-5"  # adjust to a model your account has; the bridge is model-agnostic


# ── PRIMARY: OpenAI Responses API native remote MCP tool ─────────────────────
def run_responses_mcp(sse_url: str, app: str, prompt: str) -> int:
    """Let OpenAI's servers connect to Lochan's MCP directly (no local bridge)."""
    try:
        from openai import OpenAI
    except ImportError:
        print("openai not installed: python3 -m venv .venv && . .venv/bin/activate "
              "&& pip install openai", file=sys.stderr)
        return 3
    if not os.environ.get("OPENAI_API_KEY"):
        print("set OPENAI_API_KEY", file=sys.stderr)
        return 3
    client = OpenAI()
    print(f"── ChatGPT (Responses API) → {app} MCP ──  {sse_url}", file=sys.stderr)
    print("(OpenAI's cloud connects to the MCP server + runs OAuth; approve the "
          "connector login when prompted in the API/console)", file=sys.stderr)
    resp = client.responses.create(
        model=MODEL,
        input=prompt,
        tools=[{
            "type": "mcp",
            "server_label": f"lochan-{app}",
            "server_url": sse_url,
            "require_approval": "never",
        }],
    )
    print(getattr(resp, "output_text", None) or resp)
    return 0


# ── FALLBACK: local mcp-remote function-calling bridge (twin of the Gemini one) ─
class McpStdioClient:
    """Minimal MCP JSON-RPC client over an mcp-remote stdio subprocess."""

    def __init__(self, sse_url: str):
        self._proc = subprocess.Popen(
            ["npx", "-y", "mcp-remote", sse_url, "--transport", "sse-only"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr,
            text=True, bufsize=1,
        )
        self._ids = count(1)
        self._lock = threading.Lock()

    def _rpc(self, method: str, params: dict | None = None) -> dict:
        rid = next(self._ids)
        req = {"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}}
        with self._lock:
            assert self._proc.stdin and self._proc.stdout
            self._proc.stdin.write(json.dumps(req) + "\n")
            self._proc.stdin.flush()
            for line in self._proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if msg.get("id") == rid:
                    if "error" in msg:
                        raise RuntimeError(f"MCP {method} error: {msg['error']}")
                    return msg.get("result", {})
        raise RuntimeError(f"MCP {method}: stream closed before a response")

    def initialize(self) -> dict:
        return self._rpc("initialize", {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "chatgpt-mcp-bridge", "version": "1.0"}})

    def list_tools(self) -> list[dict]:
        return self._rpc("tools/list").get("tools", [])

    def call_tool(self, name: str, arguments: dict) -> dict:
        return self._rpc("tools/call", {"name": name, "arguments": arguments})

    def close(self) -> None:
        try:
            if self._proc.stdin:
                self._proc.stdin.close()
            self._proc.terminate()
        except Exception:  # OK silent: best-effort subprocess teardown
            pass


def mcp_tool_to_openai(tool: dict) -> dict:
    """Convert one MCP tool to an OpenAI Chat Completions function tool."""
    return {
        "type": "function",
        "function": {
            "name": tool["name"],
            "description": (tool.get("description") or "")[:1024],
            "parameters": tool.get("inputSchema") or {"type": "object", "properties": {}},
        },
    }


def _result_text(result: dict) -> str:
    parts = []
    for block in result.get("content", []) or []:
        if isinstance(block, dict) and block.get("type") == "text":
            parts.append(block.get("text", ""))
        else:
            parts.append(json.dumps(block, default=str))
    return "\n".join(parts) if parts else json.dumps(result, default=str)


def run_local_bridge(sse_url: str, app: str, prompt: str | None, list_only: bool) -> int:
    print(f"── local bridge {app} MCP → ChatGPT ──  {sse_url}", file=sys.stderr)
    mcp = McpStdioClient(sse_url)
    try:
        mcp.initialize()
        tools = mcp.list_tools()
        print(f"  {len(tools)} Lochan tools available over MCP", file=sys.stderr)
        if list_only:
            for t in tools:
                print(f"  - {t['name']}: {(t.get('description') or '')[:80]}")
            return 0
        try:
            from openai import OpenAI
        except ImportError:
            print("openai not installed (pip install openai). --list works without it.",
                  file=sys.stderr)
            return 3
        if not os.environ.get("OPENAI_API_KEY"):
            print("set OPENAI_API_KEY", file=sys.stderr)
            return 3
        client = OpenAI()
        oai_tools = [mcp_tool_to_openai(t) for t in tools]
        messages = [{"role": "user", "content": prompt or
                     "List the tools you have and what each does."}]
        for _turn in range(8):
            resp = client.chat.completions.create(
                model=MODEL, messages=messages, tools=oai_tools)
            msg = resp.choices[0].message
            if not msg.tool_calls:
                print(msg.content or "(no text)")
                return 0
            messages.append(msg.model_dump())
            for tc in msg.tool_calls:
                args = json.loads(tc.function.arguments or "{}")
                print(f"  → ChatGPT calls {tc.function.name}({args})", file=sys.stderr)
                result = mcp.call_tool(tc.function.name, args)
                messages.append({
                    "role": "tool", "tool_call_id": tc.id,
                    "content": _result_text(result)})
        print("(stopped after 8 tool-call turns)", file=sys.stderr)
        return 0
    finally:
        mcp.close()


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0
    app = sys.argv[1]
    if app not in APP_SSE:
        print(f"unknown app '{app}' — one of: {', '.join(APP_SSE)}", file=sys.stderr)
        return 2
    sse_url = APP_SSE[app]
    local = "--local" in sys.argv
    list_only = "--list" in sys.argv
    ask = None
    if "--ask" in sys.argv:
        i = sys.argv.index("--ask")
        ask = sys.argv[i + 1] if i + 1 < len(sys.argv) else None

    if local or list_only:
        return run_local_bridge(sse_url, app, ask, list_only)
    return run_responses_mcp(sse_url, app, ask or
                             "List the tools you have and what each one does.")


if __name__ == "__main__":
    sys.exit(main())
