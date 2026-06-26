#!/usr/bin/env python3
"""gemini-mcp-bridge.py — expose a Lochan app's FULL MCP tool surface to Gemini.

The Gemini desktop app has no MCP connector (unlike Claude). Gemini integrates
via API-side **function calling**: a local runner defines tools, Gemini emits
tool-call requests, the runner executes them, results go back. This bridge makes
that runner **schema-driven** instead of hand-rolled-per-endpoint:

  1. It spawns `mcp-remote` (the same OAuth+SSE bridge Claude Desktop uses —
     already on this host) pointed at the app's MCP SSE endpoint. mcp-remote
     handles the browser OAuth login + the RFC-9728/8414 discovery (the layer
     #1534/#1535 fixed) and exposes the server as a local STDIO MCP server.
  2. It speaks MCP JSON-RPC over mcp-remote's stdio: `initialize` → `tools/list`.
  3. It converts EACH Lochan MCP tool's JSON-Schema into a Gemini
     `FunctionDeclaration` — so Gemini sees ALL of Lochan's autowired tools
     (32 on fwprod01), with zero per-endpoint Python. New app / new tool = no
     code change. The login user's RBAC gates which tools actually succeed.
  4. It runs the Gemini ↔ tool-call loop: Gemini decides → this runner calls
     `tools/call` over MCP → result back to Gemini → final answer.

This is the long-term-right shape (consume the existing MCP surface, don't
re-encode it — [[feedback-maximize-usage-of-every-line-already-in-framework]]),
the analog of Claude's mcp-remote entry but for a function-calling client.

WHY mcp-remote and not a pure-Python MCP client: it already implements the OAuth
handshake, token cache, and SSE transport correctly. Reimplementing that in the
runner would duplicate exactly what #1534/#1535 verified. The runner stays a thin
stdio JSON-RPC speaker + a schema adapter.

Requirements:
  - `npx mcp-remote` (cached on this host) — handles OAuth + SSE.
  - `pip install google-genai` (NOT on this host yet — install in a venv).
  - `GEMINI_API_KEY` env var (Google AI Studio key).

Usage:
  pip install google-genai
  export GEMINI_API_KEY=...
  util/scripts/mcp/gemini-mcp-bridge.py <app>            # fwprod01 | longterm01 (one-shot default prompt)
  util/scripts/mcp/gemini-mcp-bridge.py <app> --list     # just list the bridged tools (no Gemini key needed)
  util/scripts/mcp/gemini-mcp-bridge.py <app> --ask "which users exist?"   # one-shot question
  util/scripts/mcp/gemini-mcp-bridge.py <app> --chat     # interactive REPL chat (context carries across turns)

First run opens a browser for the Lochan OAuth login (once; mcp-remote caches
the token under ~/.mcp-auth). You log in as a real Lochan user → RBAC applies.

⚠ DATA PRIVACY — NOT LOCAL-ONLY. When Gemini calls a Lochan tool, the tool RESULTS
(the actual rows/fields it queried) + your question + the tool schemas are sent to
Google's Gemini API so the model can answer. RBAC gates what the logged-in user
(hence Gemini) can access; the OAuth token stays local. A free Google AI-Studio
key may have its data used by Google to improve products — do NOT use with real
customer PII (use Vertex + a DPA, or Lochan's own chat with a self-hosted model).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
from itertools import count

# The two staging apps' MCP SSE endpoints (public issuer, already live).
APP_SSE = {
    "fwprod01": "https://staging.lochan.ai/api/jharokha/mcp/sse",
    "longterm01": "https://staging.longterm366.ai/api/jharokha/mcp/sse",
}


class McpStdioClient:
    """Minimal MCP JSON-RPC client over an mcp-remote stdio subprocess.

    Speaks only what the bridge needs: initialize, tools/list, tools/call.
    mcp-remote owns OAuth + SSE; we own the line-delimited JSON-RPC framing.
    """

    def __init__(self, sse_url: str):
        # mcp-remote as a STDIO MCP server proxying the remote SSE endpoint.
        self._proc = subprocess.Popen(
            ["npx", "-y", "mcp-remote", sse_url, "--transport", "sse-only"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=sys.stderr,  # let the OAuth "open this URL" prompt reach the user
            text=True,
            bufsize=1,
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
            # Read until we get the response with our id (skip notifications).
            for line in self._proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue  # non-JSON log line from mcp-remote
                if msg.get("id") == rid:
                    if "error" in msg:
                        raise RuntimeError(f"MCP {method} error: {msg['error']}")
                    return msg.get("result", {})
        raise RuntimeError(f"MCP {method}: stream closed before a response")

    def initialize(self) -> dict:
        return self._rpc(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "gemini-mcp-bridge", "version": "1.0"},
            },
        )

    def list_tools(self) -> list[dict]:
        return self._rpc("tools/list").get("tools", [])

    def call_tool(self, name: str, arguments: dict) -> dict:
        return self._rpc("tools/call", {"name": name, "arguments": arguments})

    def close(self) -> None:
        try:
            if self._proc.stdin:
                self._proc.stdin.close()
            self._proc.terminate()
        except Exception:  # OK silent: best-effort teardown of a subprocess
            pass


def mcp_tool_to_gemini(tool: dict) -> dict:
    """Convert one MCP tool (name/description/inputSchema) to a Gemini
    FunctionDeclaration dict. The shapes are deliberately close — MCP's
    `inputSchema` IS a JSON Schema, which is what Gemini's `parameters` wants."""
    return {
        "name": tool["name"],
        "description": (tool.get("description") or "")[:1024],
        "parameters": tool.get("inputSchema") or {"type": "object", "properties": {}},
    }


def _result_text(result: dict) -> str:
    """Flatten an MCP tools/call result's content blocks to text for Gemini."""
    parts = []
    for block in result.get("content", []) or []:
        if isinstance(block, dict) and block.get("type") == "text":
            parts.append(block.get("text", ""))
        else:
            parts.append(json.dumps(block, default=str))
    return "\n".join(parts) if parts else json.dumps(result, default=str)


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0
    app = sys.argv[1]
    if app not in APP_SSE:
        print(f"unknown app '{app}' — one of: {', '.join(APP_SSE)}", file=sys.stderr)
        return 2
    sse_url = APP_SSE[app]
    mode_list = "--list" in sys.argv
    mode_chat = "--chat" in sys.argv
    ask = None
    if "--ask" in sys.argv:
        i = sys.argv.index("--ask")
        ask = sys.argv[i + 1] if i + 1 < len(sys.argv) else None

    print(f"── bridging {app} MCP → Gemini ──  {sse_url}", file=sys.stderr)
    print("(first run opens a browser to log in as a Lochan user)", file=sys.stderr)
    mcp = McpStdioClient(sse_url)
    try:
        mcp.initialize()
        tools = mcp.list_tools()
        print(f"  {len(tools)} Lochan tools available over MCP", file=sys.stderr)

        if mode_list:
            for t in tools:
                print(f"  - {t['name']}: {(t.get('description') or '')[:80]}")
            return 0

        # --- Gemini side (needs google-genai + GEMINI_API_KEY) ---
        try:
            from google import genai
            from google.genai import types
        except ImportError:
            print(
                "google-genai not installed. Run:\n"
                "  python3 -m venv .venv && . .venv/bin/activate && pip install google-genai\n"
                "then re-run with GEMINI_API_KEY set. (Use --list to inspect tools without it.)",
                file=sys.stderr,
            )
            return 3
        if not os.environ.get("GEMINI_API_KEY"):
            print("set GEMINI_API_KEY (Google AI Studio key)", file=sys.stderr)
            return 3

        client = genai.Client()
        gemini_tools = [types.Tool(function_declarations=[mcp_tool_to_gemini(t) for t in tools])]

        def resolve(contents: list) -> str:
            """Run one user turn to completion: let Gemini call Lochan MCP tools
            until it produces a final text answer. Mutates `contents` (so chat
            history accumulates) and returns the answer text."""
            for _turn in range(8):
                resp = client.models.generate_content(
                    model="gemini-2.5-flash",
                    contents=contents,
                    config=types.GenerateContentConfig(tools=gemini_tools),
                )
                calls = resp.function_calls or []
                if not calls:
                    contents.append(resp.candidates[0].content)
                    return resp.text or "(no text)"
                contents.append(resp.candidates[0].content)
                tool_parts = []
                for call in calls:
                    print(f"  → Gemini calls {call.name}({dict(call.args)})", file=sys.stderr)
                    result = mcp.call_tool(call.name, dict(call.args))
                    tool_parts.append(types.Part.from_function_response(
                        name=call.name, response={"result": _result_text(result)}))
                contents.append(types.Content(role="user", parts=tool_parts))
            return "(stopped after 8 tool-call turns)"

        if mode_chat:
            # Interactive REPL — conversation context carries across turns.
            print(f"  chat with {app} via Gemini — type a question, Ctrl-D / 'exit' to quit\n",
                  file=sys.stderr)
            history: list = []
            while True:
                try:
                    line = input("you> ").strip()
                except EOFError:
                    print(file=sys.stderr)
                    break
                if line in ("exit", "quit", ":q"):
                    break
                if not line:
                    continue
                history.append(types.Content(role="user", parts=[types.Part(text=line)]))
                print("gemini>", resolve(history))
            return 0

        # One-shot --ask (or the default prompt).
        prompt = ask or "List the tools you have available and what each one does."
        print(resolve([types.Content(role="user", parts=[types.Part(text=prompt)])]))
        return 0
    finally:
        mcp.close()


if __name__ == "__main__":
    sys.exit(main())
