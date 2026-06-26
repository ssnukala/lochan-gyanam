# Connect ChatGPT · Gemini · Copilot to a Lochan app's MCP — moved

**This guide is now the canonical framework doc:**
[`framework/lochan/packages/muulam/docs/features/MCP-CLIENT-ONBOARDING.md`](../../../framework/lochan/packages/muulam/docs/features/MCP-CLIENT-ONBOARDING.md)

It covers all four clients (Claude · ChatGPT · Gemini · Copilot) × both staging
apps (`staging.lochan.ai`, `staging.longterm366.ai`), the per-client integration
models, the verify-before-trust gotchas, and the data-privacy warnings — one
source of truth, living with the framework it documents.

The runnable tooling stays here in `util/scripts/`:

| Tool | What it does |
|---|---|
| `util/scripts/mcp/gemini-mcp-bridge.py <app>` | Bridges Lochan's autowired MCP tools to Gemini's function-calling API (Gemini has no MCP connector). |
| `util/scripts/mcp/chatgpt-mcp-bridge.py <app>` | Connects ChatGPT via the Responses-API `mcp` tool (or `--local` function-calling). |
| `util/scripts/gpt/connect.sh <app>` | Turnkey ChatGPT bridge wrapper (auto-venv + `openai` + key check). |
| `util/scripts/gemini/chat_gemini.sh <app>` | Turnkey Gemini bridge wrapper. |
| `util/scripts/mcp/probe-mcp-oauth.sh <app>` | The 7-check MCP-OAuth readiness probe. |

See the canonical doc above for how to use them per client.
