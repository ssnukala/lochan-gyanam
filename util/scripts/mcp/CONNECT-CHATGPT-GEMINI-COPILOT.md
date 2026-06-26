# Connect ChatGPT · Gemini · Copilot desktop apps to a Lochan app's MCP

**TL;DR — all three connect the SAME way Claude does:** point the app's MCP /
"custom connector" feature at the Lochan app's **SSE endpoint**, and the app
runs the standard OAuth login (the RFC-9728/8414 discovery + DCR flow that
#1534/#1535 fixed). You log in as a real Lochan user; tools then run with that
user's RBAC.

The two live endpoints (both already on the public HTTPS issuer):

| App | MCP SSE endpoint (this is the only URL you paste) |
|---|---|
| **fwprod01** | `https://staging.lochan.ai/api/jharokha/mcp/sse` |
| **longterm01** | `https://staging.longterm366.ai/api/jharokha/mcp/sse` |

> **Why SSE, not the ai-plugin/OpenAPI-Action path:** the modern desktop apps
> all speak **MCP-over-SSE with OAuth** (the same protocol Claude Desktop uses).
> The legacy per-platform `ai-plugin.json` / OpenAPI-Action adapters advertise
> OAuth at `/api/jharokha/auth/{platform}/*`, which 404s (dead routes) — that is
> the OLD ChatGPT-plugin mechanism, NOT how these desktop apps connect. Use the
> SSE endpoint above for all three.

---

## ChatGPT (desktop / web) — Settings → Connectors → Custom MCP

ChatGPT's **Developer mode → Connectors** (Plus/Pro/Business) accepts a custom
MCP server over SSE with OAuth.

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

---

## Google Gemini — Gemini app → Settings → Connectors / MCP

Gemini's connector surface (Gemini app / AI Studio "Connectors") takes an MCP
SSE URL with OAuth, same as Claude.

1. Gemini → **Settings → Connectors** (or **Extensions / MCP servers**) → **Add**.
2. **Transport:** SSE. **URL:** the SSE endpoint from the table above.
3. **Auth:** OAuth (auto-discovered).
4. Log in as a Lochan user in the browser tab Gemini opens → connected.

> Gemini runs in Google's cloud, so it can only reach a **public HTTPS** URL —
> the `staging.*` tunnel URLs above satisfy that (the issuer is already public).
> A bare `localhost` URL will NOT work for Gemini.

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
