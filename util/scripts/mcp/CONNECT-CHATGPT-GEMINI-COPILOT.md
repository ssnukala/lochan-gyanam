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
| **ChatGPT** | ⚠ NO usable custom-MCP UI in the consumer desktop app (founder verified 2026-06-26: the "Add MCP Server → Remote" flow ChatGPT's own answer described **does not exist in the installed app**, v1.2026.160). The app's "Connectors" are pre-built (Drive/HubSpot/…), not arbitrary remote MCP. Custom remote-MCP is an Enterprise/Business "Developer mode" or API-Platform feature. | **Two real options:** (1) if you have ChatGPT Business/Enterprise with Developer-mode connectors, register the remote MCP there (SSE URL + OAuth); (2) otherwise use the **bridge** — OpenAI's Responses API supports a remote `mcp` tool, OR the same `gemini-mcp-bridge.py` pattern ported to the OpenAI SDK (tools = the same Lochan MCP list). The consumer desktop app has no path. |
| **Copilot** | ✅ Native MCP (CONFIRMED by Copilot, 2026-06-26) — "Copilot does not use a local JSON config file"; connects via **Cloud MCP Integration** (register the remote endpoint) or **app-embedded** `copilot.attachMcpServer({...})`. | Register the Lochan MCP endpoint with Copilot. ⚠ Copilot's answer got 3 Lochan specifics WRONG (corrected below): use the **SSE** URL `…/api/jharokha/mcp/sse` (NOT `wss://…/mcp` — Lochan has no WebSocket and no bare `/mcp` route), and **OAuth** (NOT a static pasted bearer token). |

> **Verification status (2026-06-26) — TRUST THE ACTUAL UI, NOT THE APP'S ANSWER.**
> Each app, asked "how do I connect to an MCP server", wrote a confident answer —
> and each answer was partly WRONG about its own app:
> • **Gemini** — correctly said it has no connector (→ `gemini-mcp-bridge.py`).
> • **ChatGPT** — claimed "Settings → Connectors → Add MCP Server → Remote"; the
>   founder checked the installed app (v1.2026.160) and **that UI does not exist**.
>   Consumer ChatGPT has pre-built connectors only; custom remote-MCP is
>   Enterprise/Developer-mode/API-Platform. → use the bridge / Responses API.
> • **Copilot** — said native MCP (true) but gave wrong specifics (`wss://…/mcp`,
>   static token). Needs UI verification like ChatGPT before relying on it.
> Plus all three suggested BUILDING a new FastMCP/ws server from scratch — ignore:
> Lochan's MCP server ALREADY exists at `…/api/jharokha/mcp/sse` with 32 tools.
> **Lochan facts (verified in source):** transport = SSE (`/api/jharokha/mcp/sse`),
> NOT WebSocket/`wss://`, NOT bare `/mcp`; auth = OAuth (discovery+DCR), NOT a
> static pasted bearer token. **Lesson: an app's self-description is a claim;
> only its installed UI is ground truth — verify there before trusting the answer.**

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

## ChatGPT — ⚠ NO custom-MCP UI in the consumer desktop app (founder-verified)

ChatGPT's written answer claimed a "Settings → Connectors → Add MCP Server →
Remote (http/sse)" flow. **The founder checked the installed app (v1.2026.160):
that UI does not exist.** Consumer ChatGPT's "Connectors" are pre-built
(Google Drive, HubSpot, …) — there is no "add an arbitrary remote MCP server"
box. Custom remote-MCP is gated to **ChatGPT Business/Enterprise "Developer mode"
connectors** or the **OpenAI API Platform**, neither of which is the standard
desktop app.

So, two real paths (pick by what you actually have):

**A. If you have ChatGPT Business/Enterprise with Developer-mode connectors:**
register the remote MCP there — server URL = the Lochan **SSE** endpoint from the
table above, auth = **OAuth** (DCR auto). (Verify the box exists in YOUR tier
first — don't trust the written answer.)

**B. Otherwise — the bridge (works on any plan, via the API):** OpenAI's
**Responses API** has a first-class remote `mcp` tool:

```python
client.responses.create(
    model="gpt-5", input="which users exist?",
    tools=[{"type": "mcp", "server_label": "lochan",
            "server_url": "https://staging.lochan.ai/api/jharokha/mcp/sse",
            "require_approval": "never"}],
)
```

or run **`util/scripts/mcp/chatgpt-mcp-bridge.py <app>`** (already built) — its
default path uses the Responses-API `mcp` tool above; `--local` uses the same
`mcp-remote` function-calling pattern as the Gemini bridge. Turnkey wrapper:
`util/scripts/gpt/connect.sh <app>` (auto-venv + `openai` + key check).

> ⚠ Ignore ChatGPT's advice to *build* a FastMCP server from scratch — Lochan's
> server already exists with 32 tools; you connect to it (Responses-API `mcp` tool
> or the bridge), you don't build one.
>
> (Gemini has NO such connector — see the Gemini section above; use the bridge.)

---

## Microsoft Copilot — ✅ register the Lochan MCP endpoint (Cloud Integration)

**Confirmed by Copilot (2026-06-26):** "Unlike Claude Desktop, Copilot does not
use a local JSON config file." It connects via **Cloud MCP Integration** (register
your remote MCP server with Copilot — name + endpoint + auth + capabilities) or
**app-embedded** (`copilot.attachMcpServer({ name, url, auth })` via the Copilot
SDK, for embedding Copilot in your own web app).

Register Lochan via **Copilot Studio** (Agents → Tools → Add an MCP server) or the
Cloud MCP registration surface, with these **CORRECTED Lochan values** (Copilot's
own answer got these wrong):

1. **Server name:** `lochan` (or `lochan-longterm`).
2. **Endpoint URL:** the **SSE** URL from the table above — e.g.
   `https://staging.lochan.ai/api/jharokha/mcp/sse`.
   - ❌ NOT `wss://staging.lochan.ai/mcp` — **Lochan has no WebSocket transport**
     (verified: zero `websocket` routes in jharokha) and no bare `/mcp` route.
     The transport is **SSE** at `/api/jharokha/mcp/sse` (+ POST `/mcp/message`).
3. **Auth:** **OAuth 2.0** (the RFC-9728/8414 discovery + DCR is automatic).
   - ❌ NOT a static pasted bearer token (`"token": "<YOUR_TOKEN>"`). Lochan mints
     the token through the OAuth login — you authenticate as a real Lochan user,
     and that user's RBAC gates the tools. There is no long-lived token to paste.
4. **Capabilities:** tools (+ resources/prompts). Lochan exposes 32 autowired tools.

> ⚠ Copilot's answer also walks you through BUILDING a Node `ws` MCP server from
> scratch (`new WebSocketServer`, a `hello` tool, a `lochan-mcp/` project). Ignore
> all of it — Lochan's MCP server already exists at the SSE URL. You're registering
> the existing endpoint, not writing a new server. (Copilot didn't know yours exists.)
>
> If a Copilot surface only offers a **plugin manifest / OpenAPI** path instead of
> MCP, that path needs the per-platform OAuth routes which are currently dead (see
> the framework note below) — prefer the MCP path, which uses the working
> `/api/oauth/provider/*` AS.

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

---

## ⚠ DATA PRIVACY — bridges/connectors send your app data to the AI vendor

Any of these paths (the Gemini/ChatGPT bridges, or a native MCP connector) makes
the AI client a **pipe to the vendor's cloud** — it is NOT local-only:

| Stays local | Goes to the vendor (Google/OpenAI/Microsoft) |
|---|---|
| Your OAuth token / Lochan login | Your question text |
| The bridge process (your machine) | The tool schemas (all 331) |
| Lochan's database itself | **Tool RESULTS — the actual rows/fields the model queried** |

When a model calls e.g. `search_records(tr_users)` and gets 3 users back, **those
user records (names, emails, fields) are sent to the vendor** so the model can
phrase the answer. Inherent to cloud-LLM function calling — the model can't answer
about data it never sees.

**Protections that DO hold:** Lochan RBAC gates what the logged-in user (hence the
model) can access; the OAuth token never reaches the vendor.

**The caveat:** the keys in `apps/<app>/.env` are free-tier (e.g. Google AI-Studio)
— on the free tier the vendor **may use the data to improve its products**. **Do
NOT point a bridge at real customer PII on a free key.** For privacy-preserving
use: a paid/Cloud tier with a data-processing agreement (Vertex for Gemini), or
**Lochan's own chat with a self-hosted model** (data stays under your control —
this is a core reason the framework's own chat matters). Data-residency/governance
is a per-vendor **certification** requirement, tracked in the cert-readiness work.
