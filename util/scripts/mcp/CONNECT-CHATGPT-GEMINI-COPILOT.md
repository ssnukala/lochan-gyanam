# Connect ChatGPT · Gemini · Copilot desktop apps to a Lochan app's MCP

**The three apps do NOT all behave like Claude — each has a different integration
model. Confirmed for Gemini by Gemini itself (2026-06-26): the Gemini app has no
MCP connector.** Don't assume parity with Claude's `mcpServers` config.

The two live MCP SSE endpoints (public HTTPS issuer, already serving):

| App | MCP SSE endpoint |
|---|---|
| **fwprod01** | `https://staging.lochan.ai/api/jharokha/mcp/sse` |
| **longterm01** | `https://staging.longterm366.ai/api/jharokha/mcp/sse` |

| Client | Integration model | How to connect to Lochan |
|---|---|---|
| **Claude** | Native MCP-SSE + OAuth | `claude_desktop_config.json` `mcpServers` → `mcp-remote <sse-url>`. ✅ Working. |
| **Gemini** | **Function calling (NO MCP connector)** | Run **`util/scripts/mcp/gemini-mcp-bridge.py <app>`** — a local runner that pulls Lochan's full MCP tool list (via `mcp-remote`'s OAuth+SSE) and hands them to Gemini's function-calling API. Schema-driven; reuses OAuth+RBAC. (Gemini's own suggested hand-rolled-per-endpoint approach is NOT what we use — it re-encodes what MCP already exposes.) |
| **ChatGPT** | ✅ Native MCP-SSE connector (CONFIRMED by ChatGPT, 2026-06-26) — "ChatGPT does not use a local JSON config file; Settings → Connectors/Tools → Add MCP Server → Remote (http/sse)." Plan/client-version gated. | Settings → Connectors → Add MCP Server → **Remote (http/sse)** → paste the SSE URL. NOTE: do NOT follow ChatGPT's "build a FastMCP server from scratch" advice — Lochan's MCP server already exists at that URL with 32 tools; you're connecting to it, not building one. |
| **Copilot** | ⚠ UNVERIFIED — likely Copilot Studio MCP-server (SSE+OAuth), but NOT confirmed. | Copilot Studio → Tools → Add MCP server → SSE URL. |

> **Verification status (2026-06-26):** Gemini = function-calling, no connector
> (confirmed by Gemini → use `gemini-mcp-bridge.py`). ChatGPT = native MCP-SSE
> connector via Settings → Connectors → Remote (http/sse) (confirmed by ChatGPT;
> plan-gated). **Copilot is still UNVERIFIED** — the Copilot Studio MCP-server
> step below is best-effort; check it against the actual UI. If Copilot turns out
> function-calling-only, the `gemini-mcp-bridge.py` pattern ports to its SDK
> (the tool list is the same Lochan MCP surface).

> **Why SSE / the canonical AS, not the ai-plugin path:** the legacy per-platform
> `ai-plugin.json` / OpenAPI-Action adapters advertise OAuth at
> `/api/jharokha/auth/{platform}/*`, which **404s** (dead routes — the real AS is
> `/api/oauth/provider/*`). That's the OLD ChatGPT-plugin mechanism. All current
> paths (MCP-SSE for Claude, the bridge for Gemini) use the working AS.

---

## Gemini — the MCP→function-calling bridge (NO connector UI)

Gemini's app has **no MCP connector**. Its model is API-side **function calling**
with a local runner. We make that runner schema-driven so Gemini sees Lochan's
ENTIRE autowired tool surface, not hand-coded endpoints:

```bash
pip install google-genai          # not on this host yet — use a venv
export GEMINI_API_KEY=<your Google AI Studio key>

util/scripts/mcp/gemini-mcp-bridge.py fwprod01 --list      # list the bridged Lochan tools (no key needed)
util/scripts/mcp/gemini-mcp-bridge.py fwprod01 --ask "which users exist?"
util/scripts/mcp/gemini-mcp-bridge.py longterm01           # interactive default prompt
```

First run opens a browser for the Lochan OAuth login (via `mcp-remote`, cached
under `~/.mcp-auth`); you log in as a real Lochan user → that user's RBAC gates
the tools. The runner: spawns `mcp-remote <sse-url>` (OAuth + SSE), `tools/list`
over MCP, converts each tool's JSON-Schema into a Gemini `FunctionDeclaration`,
then runs the Gemini ↔ `tools/call` loop. New app / new tool = zero code change.

For Gemini IN THE APP (not the SDK): the app itself can't call your private
staging server, so the bridge script is the integration — run it from a terminal
(or wire it into a small local service the Gemini app talks to). There is no
in-app "add MCP server" box to fill.

---

## ChatGPT (desktop / web) — ✅ Settings → Connectors → Add MCP Server (Remote http/sse)

**Confirmed by ChatGPT (2026-06-26):** "Unlike Claude Desktop, ChatGPT does not
use a local JSON config file" — you add the MCP server in-app. Plan/client-version
gated. ⚠ Ignore ChatGPT's accompanying advice to *build* a FastMCP server from
scratch — Lochan's MCP server already exists at the SSE URL; you connect to it.

1. ChatGPT → **Settings → Connectors** (or **Apps & Connectors**) → **Advanced /
   Developer mode** → **Add custom connector** (a.k.a. "Create / Add MCP server").
2. **Name:** `Lochan fwprod01` (or `Lochan longterm`).
3. **MCP Server URL / SSE URL:** paste the SSE endpoint from the table above.
4. **Authentication:** choose **OAuth** (ChatGPT auto-discovers the AS from the
   server — no client id/secret to enter; it does Dynamic Client Registration).
5. Save → ChatGPT opens the Lochan login in a browser → log in as a seeded user
   (e.g. a super-admin, or a scoped user to see RBAC narrowing) → it connects and
   lists Lochan's tools.

> If ChatGPT shows only the older "Actions / Import from URL (OpenAPI)" box,
> that's the legacy plugin path — use the **MCP / connector** box instead. The
> OpenAPI manifest still works for a Custom GPT Action, but it's a separate,
> non-MCP flow.
>
> (Gemini has NO such connector — see the Gemini section above; use the bridge.)

---

## Microsoft Copilot — Copilot Studio / M365 → Add an MCP server

M365 Copilot connects to MCP servers via **Copilot Studio** (Agents → Tools →
Add an MCP server) or the Copilot connectors surface.

1. **Copilot Studio** → your agent → **Tools / Actions → Add → MCP server**
   (or **Connectors → New connection → Model Context Protocol**).
2. **Server URL:** the SSE endpoint from the table above. **Transport:** SSE.
3. **Auth:** OAuth 2.0 (the discovery + DCR is automatic; no manifest upload).
4. Authenticate as a Lochan user → Copilot lists the tools.

> Copilot is the most likely of the three to want a manifest instead of pure
> MCP-SSE on some surfaces. If your Copilot surface asks for a **plugin manifest
> / OpenAPI**, that path needs the per-platform OAuth routes which are currently
> dead (see the framework note below) — prefer the MCP-server (SSE) path, which
> uses the working `/api/oauth/provider/*` AS.

---

## Where the config lives per app (probed on THIS host — 2026-06-26)

**Unlike Claude, none of these three stores MCP config in an editable file** —
so they cannot be configured by writing a file the way Claude can. Verified on
this host:

| App | Installed | Where its MCP/connector config lives | Editable file? |
|---|---|---|---|
| **Claude** (reference) | `/Applications/Claude.app` | `~/Library/Application Support/Claude/claude_desktop_config.json` → `mcpServers` block (spawns `npx mcp-remote <sse-url> --transport sse-only`) | ✅ **YES** — this is the only one that's a hand-editable JSON. Already has `lochan-staging` + `longterm-staging`. |
| **ChatGPT** | `/Applications/ChatGPT.app` (`com.openai.chat`) | Connectors are stored **server-side in your OpenAI account**, configured via the in-app **Settings → Connectors** UI. Locally only opaque `*.data` conversation blobs — no MCP config file. | ❌ GUI-only (in-app) |
| **Gemini** | `/Applications/Gemini.app` (`com.google.GeminiMacOS`) | Settings in opaque `Data/*.store` SQLite-WAL DBs (`app-settings.store`, `minichat-settings.store`). No JSON/plist MCP entry to write. | ❌ GUI-only (in-app) |
| **Copilot** | `/Applications/Copilot.app` (`com.microsoft.copilot-mac`, sandboxed) | Sandboxed container; only a prefs `.plist` + caches. MCP via **Copilot Studio** (web) or in-app connectors. | ❌ GUI-only (in-app/web) |

`npx mcp-remote` is cached on this host (the same OAuth-SSE bridge Claude uses),
but these three don't read a `claude_desktop_config.json`-style file to point at
it — their connector setup is the in-app UI flows above, with OAuth state the app
manages. **So the connect step for these three is GUI-driven (the per-client
sections above); there is no file to pre-seed.** (Editing the apps' opaque
`.store`/sandbox internals would be a fragile reverse-engineering hack that
breaks on the apps' integrity checks — don't.)

You do **not** edit any Lochan file to connect a client — the connection is
configured **inside each desktop app** (the steps above). The app discovers
everything from the server's `.well-known` docs.

What CAN need updating, on the Lochan side, and where:

| Thing | File | When you touch it |
|---|---|---|
| **Public issuer URL** (what the app advertises in discovery) | **`apps/<app>/.env.staging`** (NOT `.env` — `.env` has the `localhost` dev default) → `BACKEND_URL=https://staging.<host>` | Already set for both apps (fwprod01 → `https://staging.lochan.ai`, longterm01 → `https://staging.longterm366.ai`). Only change if the tunnel host changes. The containers must be (re)launched with `.env.staging` — `ENV_FILE=.env.staging docker compose -f compose.dev.yml up -d` — so the running app serves the public issuer (verify: the `resource`/SSE URL in the `.well-known` docs is `https://…`, not `localhost`). |
| **The OAuth AS endpoints** (authorize/token/register) | framework `agent_card.py` (already correct: `/api/oauth/provider/*`) | No edit — this is what #1534/#1535 fixed. |
| **Per-tool RBAC scope** (which user sees which tool) | the app's AGENT_CARD `rbac_scope` declarations (schema-derived) | Only if you want to change which role can call which tool. The login user's role gates it automatically. |

### Verify a target app is connect-ready before you try a client

```bash
util/scripts/mcp/probe-mcp-oauth.sh <app>        # fwprod01 or longterm01
# expect 7/7 deterministic PASS: AS metadata (bare + path-inserted),
# protected-resource (bare + path-inserted), DCR register 201, B0 gate 401.
```

If the probe is green, the three desktop apps will discover + register + log in.
The probe can't click through the browser login, so the human-in-the-loop step
(actually logging in) is the final confirmation — do one client end-to-end and
the rest follow the same flow.

---

## ⚠ Framework follow-up (the per-platform adapters advertise dead OAuth)

`adapters/llm/{chatgpt,gemini}.py` emit OAuth at `/api/jharokha/auth/<platform>/
authorize|callback`, which **404** (the real AS is `/api/oauth/provider/*`).
This only bites the legacy ai-plugin/OpenAPI-Action path (not the MCP-SSE path
these desktop apps use), but it's a real staleness bug — those adapters should
point at the canonical AS (or be retired) the same way #1534 corrected the
discovery routes. Tracked as the multi-client adapter-hygiene follow-up.
