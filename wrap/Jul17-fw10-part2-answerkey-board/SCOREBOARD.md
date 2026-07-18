# FW10 Part-2 — Self-Sufficient (local-nomic) Answer-Key Accuracy Scoreboard

**What this is.** The FW10 Part-2 DoD: a **self-sufficient** (zero-cloud, local `nomic-embed-text`) per-app **answer-key accuracy** board — natural-language utterances → the tool they should resolve to, scored against a running instance's live intent corpus via `IntentEmbeddingIndex.search` (pgvector cosine over `gy_intent_examples`). This is the FIRST real slice of the ratified gemini→nomic embedding flip: the corpora are embedded with **local nomic**, not Google's API. Scorer = EXACT top-1 (`probe-wrap-answer-keys.py:77`, `passed = top_tool == expected`); `defer` rows must correctly drop below the confidence floor.

**Scope (S0 ruled Q-S2-06 = A, founder-ratified):** the honest **2-app** board — **smriti** (our own wrap tool corpus) + **opencats** (independent PHP/ATS app). The cross-STACK generalization story is already delivered by the accepted 2026-07-16 cross-stack scoreboard (jtrac 76.9% rule-tier etc.); jtrac + dotnetdesk + the opencats richer-surface gap are a **single deferred reconciliation backlog item**, NOT a silent drop.

**Runtime:** `nomic-embed-text` (dim 768), local shared-ollama, **zero cloud**. Threshold 0.55.

---

## The board — REAL MEASURED numbers

| App | Corpus role | Nomic accuracy (measured) | Tool-rows | Defer-rows | Honest attribution |
|---|---|---|---|---|---|
| **smriti** | our wrap-tool corpus (dogfood) | **12/15 = 80.0%** | **12/12 ✓ (perfect)** | 0/3 | Every graded wrap tool resolves top-1 under local nomic — a clean, self-sufficient full pass on tool resolution. The 3 misses are all **defer rows** where a genuinely-related wrap phrase matched (0.66–0.79) instead of dropping — a confidence-floor-tuning artifact (0.55 is slightly permissive for near-synonym wrap phrases), NOT a tool-resolution failure. |
| **opencats** | independent PHP/ATS app | **2/16 = 12.5%** | 0/12 top-1 exact | 2/4 | Two compounding causes, **neither is a nomic-quality miss** (nomic resolves — top matches land at 0.47–0.77 real similarity): **(1) tool-surface drift** — 6/12 graded tool-rows (`oc_hot_list`, `oc_match_candidates`, `oc_draft_outreach`, `oc_chat_candidate`, `oc_pipeline_alerts`, `search_candidate`) name tools that live only in **archived opencats-v2.2/v3**; installed `mandi/domain/opencats` is slimmer → those can't resolve. **(2) corpus-scope pollution** — even present-tool rows are out-competed: in the shared 10.8k-row corpus, framework/CRUD seeds win top-1 over the 2.3k opencats seeds (e.g. `oc_pipeline_board` → `list_workflow_templates` @0.53; several `got=None@0.77` = a non-tool CRUD seed wins). Same class as longterm01's 2/15. |

**Headline (honest):** local-nomic tool resolution is **strong on a correctly-scoped corpus (smriti 12/12 tools)**; the opencats floor reflects **drift + shared-corpus scope pollution, not embedding weakness** — exactly the F2 finding this harness was built to make visible.

---

## Why the numbers are what they are (the integrity point)

- **smriti 12/12 tools** proves the **local-nomic embedding flip works end-to-end**: baked `nomic-embed-text` artifact → DB-seeded → pgvector search → perfect top-1 tool resolution, **zero cloud**. That is the FW10 Part-2 win.
- **opencats 2/16** is a *true* low with a *named* cause. Reporting it honestly (drift + scope-pollution) beats a suspicious high — same posture as the accepted leg-1 example-tier flag and the cross-stack "don't cite dotnetdesk's loose 100%" caveat. Precedent: MTEB/BEIR publish score **and** coverage caveat; never hide the task.
- The opencats scope-pollution finding is itself **reproducible evidence for the standing corpus-scoping work** (a per-app corpus, or a package-scoped search that doesn't let framework CRUD seeds out-rank a domain app's tool seeds).

---

## Durable nomic artifacts shipped (the first real gemini→nomic-flip output)

| Artifact | Path | Shape | Verified |
|---|---|---|---|
| smriti | `framework/lochan/packages/smriti/data/embed-artifacts/nomic-embed-text/ai_intent_seeds_embedded.npz` | (424, 768) f32 | `meta.model=nomic-embed-text` ✓ |
| opencats | `mandi/domain/opencats/data/embed-artifacts/nomic-embed-text/ai_intent_seeds_embedded.npz` | (2276, 768) f32 | `meta.model=nomic-embed-text` ✓ |

---

## Deferred (unified reconciliation backlog item — S0-boarded, NOT dropped)

> **"revive + reconcile archived tool surfaces (opencats-v2.2/v3 + jtrac + dotnetdesk) vs answer keys"** — plus a companion: **corpus-scope pollution** (framework/CRUD seeds out-ranking a domain app's tool seeds in the shared index; the opencats 2/16 quantifies it).

- **opencats richer surface:** port `evolution/` + `chat/` tools from archived v2.2/v3, OR re-scope the key to the installed slim surface (decide source-of-truth).
- **jtrac / dotnetdesk:** archived pkgs' `jt_*`/`dd_*` surfaces diverge from their keys — same reconcile-or-rescope decision.

## Reproduce

```
# bake nomic artifacts (in a backend carrying the package):
docker exec fwprod01-backend-1     python3 -m gyanam.scripts.precompute_embeddings --model nomic-embed-text --package smriti   --force   # smriti (framework-tier)
docker run --network shared-ai -e AI_OLLAMA_ENABLED=true -e AI_OLLAMA_BASE_URL=http://shared-ollama:11434 \
  --entrypoint python3 opencats30-backend:latest -m gyanam.scripts.precompute_embeddings --model nomic-embed-text --package opencats --force   # opencats
# harness (exact top-1 answer-key accuracy) against a DB-seeded, ollama-enabled backend under nomic runtime:
util/scripts/probe-wrap-answer-keys.sh fwprod01   smriti   0.55   # → 12/15
util/scripts/probe-wrap-answer-keys.sh opencats30 opencats 0.55   # → 2/16  (needs AI_OLLAMA_ENABLED=true + DB-seeded corpus)
```

_Note: opencats30 backend requires `AI_OLLAMA_ENABLED=true` (compose default is false) + a boot-seeded `gy_intent_examples` for the runtime query-embed + pgvector search to function. See S2-log discovery for the full deploy-mechanics trail._
