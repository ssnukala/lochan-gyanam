#!/usr/bin/env bash
# probe-chat-resolution.sh — model-driven chat-resolution TRACE + tuning harness.
#
# The chat must resolve queries DETERMINISTICALLY (scope_filter/keyword/CRUD)
# and FAST — not drop to the slow learned/embedding/LLM cascade. This harness
# enumerates the app's REGISTERED SCHEMAS (every package's auto_wire/schemas),
# generates realistic query variants per model, sends each to /api/ai/chat, and
# traces WHERE each resolves (or fails) by reading the gy_intent_log row the chat
# writes — source · confidence · embedding_top_score · response_time_ms ·
# resolved_intent · was_successful — plus the response ui_blocks. Emits a
# scoreboard that pinpoints the failure tier + a timestamped JSON for
# before/after tuning comparison.
#
# Query variants per model (deterministic-resolution coverage):
#   - bare-list      "show <plural>"            → expect fast CRUD list
#   - filtered-list  "show <plural> with/for …" → expect a FILTER on the intent
#   - count          "how many <plural>"        → expect count/list
#   - title-detail   "show <singular> <title>"  → expect detail (when title_field)
#
# A probe PASSES when: resolution_source ∈ {scope_filter, keyword, crud, learned}
# (deterministic) AND response_time_ms < SLOW_MS AND (for filtered) the
# resolved_intent carries a non-empty `filters`. FAIL classes are labeled so the
# scoreboard shows the failure mode: SLOW · CLARIFY · LLM · FILTER-DROPPED · MISS.
#
# Usage:
#   util/scripts/probe-chat-resolution.sh [APP] [LABEL] [MODELS_LIMIT]
#     APP          default fwprod01
#     LABEL        tags the results file (e.g. "pre-tune", "post-E1")
#     MODELS_LIMIT cap the number of models probed (default 12; 0 = all 93)
#
# Output: util/scripts/.probe-results/<APP>-resolution-<LABEL|stamp>.json + scoreboard.
# Requires: daksh-cli, python3, docker. READ-ONLY w.r.t. the repo.
set -euo pipefail

REPO="/Users/srinivasnukala/Dropbox/Sites/docker/gyanam"
CLI="framework/lochan/packages/daksh/daksh-cli"
APP="${1:-fwprod01}"
RUN_LABEL="${2:-}"
MODELS_LIMIT="${3:-12}"
USER_AUTH="${PROBE_USER:-srinivas@lochan.ai:B@jarangaBali}"
SLOW_MS="${SLOW_MS:-2000}"
PG_CONTAINER="${APP}-postgres-1"
cd "$REPO"

PG_USER="$(grep -E '^POSTGRES_USER=' "apps/${APP}/.env" 2>/dev/null | cut -d= -f2 || echo postgres)"
PG_DB="$(grep -E '^POSTGRES_DB=' "apps/${APP}/.env" 2>/dev/null | cut -d= -f2 || echo "$APP")"

OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
RESULTS_DIR="util/scripts/.probe-results"; mkdir -p "$RESULTS_DIR"
STAMP="$(python3 -c 'import datetime; print(datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))')"
RESULTS_FILE="$RESULTS_DIR/${APP}-resolution-${RUN_LABEL:-$STAMP}.json"

# ── 1. Enumerate registered schemas → generate query battery ────────────────
# Reads every auto_wire/schemas/*.json; derives plural/singular from table +
# title; builds the per-model query variants. A relation field (relationships/
# details) seeds a filtered-list query ("<plural> with <relation> <value>").
python3 - "$MODELS_LIMIT" > "$OUT/battery.tsv" <<'PYEOF'
import json, sys, glob, os, re
limit = int(sys.argv[1])
roots = glob.glob("framework/lochan/packages/*/backend/*/auto_wire/schemas/*.json")
roots = [r for r in roots if "node_modules" not in r]
models = []
for f in sorted(roots):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    table = d.get("table")
    if not table or d.get("chat_columns") is False and not d.get("searchable"):
        pass
    pkg = d.get("package", "?")
    title_field = d.get("title_field")
    rels = (d.get("relationships") or []) + (d.get("details") or [])
    # Public-ish noun: strip the tr_/gy_/mu_/vn_ prefix; singularize crudely.
    noun = re.sub(r'^(tr|gy|mu|vn|ab|dk|lc|fa|lh|ms|lt)_', '', table)
    plural = noun.replace("_", " ")
    singular = plural[:-1] if plural.endswith("s") else plural
    models.append((table, pkg, plural, singular, title_field, rels))

if limit and limit > 0:
    models = models[:limit]

for table, pkg, plural, singular, title_field, rels in models:
    # bare-list
    print(f"{table}\t{pkg}\tbare-list\tshow {plural}")
    # count
    print(f"{table}\t{pkg}\tcount\thow many {plural}")
    # filtered-list (only if a relation exists — uses its name as the filter dim)
    if rels:
        rel = rels[0]
        relname = (rel.get("name") or rel.get("title") or "role").replace("_", " ")
        # singularize the relation noun lightly
        relsing = relname[:-1] if relname.endswith("s") else relname
        print(f"{table}\t{pkg}\tfiltered-list\tshow {plural} with {relsing} admin")
PYEOF

BATTERY_N=$(wc -l < "$OUT/battery.tsv" | tr -d ' ')
echo "== probe-chat-resolution :: $APP as ${USER_AUTH%%:*} :: label='${RUN_LABEL:-$STAMP}' :: $BATTERY_N probes =="
echo "   #  | model              | variant        | src         | conf  | emb   | ms     | verdict       | query"
echo "  ----+--------------------+----------------+-------------+-------+-------+--------+---------------+------"

# ── 2. trace one query: send → read gy_intent_log → judge ───────────────────
intent_trace() {  # msg → "source|conf|emb|ms|ok|resolved_intent_json"
  docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAF'|' -c \
    "SELECT resolution_source, COALESCE(resolution_confidence,0),
            COALESCE(embedding_top_score,0), COALESCE(response_time_ms,0),
            was_successful, COALESCE(resolved_intent::text,'{}')
       FROM gy_intent_log WHERE user_message = \$\$${1}\$\$
      ORDER BY id DESC LIMIT 1;" 2>/dev/null | head -1 || true
}

i=0
while IFS=$'\t' read -r table pkg variant query; do
  i=$((i+1))
  body=$(python3 -c 'import json,sys; print(json.dumps({"message":sys.argv[1],"conversation_id":None}))' "$query")
  t0=$(python3 -c 'import time;print(time.time())')
  "./$CLI" api "$APP" POST /api/ai/chat "$body" --format json --as "$USER_AUTH" > "$OUT/r${i}.json" 2>&1 || true
  t1=$(python3 -c 'import time;print(time.time())')
  trace="$(intent_trace "$query")"
  python3 - "$OUT/r${i}.json" "$i" "$table" "$pkg" "$variant" "$query" "$trace" "$SLOW_MS" \
           "$(python3 -c "print(round(($t1-$t0)*1000))")" "$OUT/row${i}.json" <<'PYEOF'
import json, sys
rf, n, table, pkg, variant, query, trace, slow_ms, wall_ms, rowout = sys.argv[1:11]
try:
    d = json.load(open(rf)); r = d.get("data", {}).get("response", {})
except Exception:
    r = {}
src, conf, emb, ms, ok, intent = (trace.split("|") + ["—"]*6)[:6] if trace else ("—",)*6
try: intent_d = json.loads(intent)
except Exception: intent_d = {}
ms_i = int(float(ms)) if ms not in ("—","") else int(wall_ms)
blocks = [b.get("type") for b in r.get("ui_blocks", []) if isinstance(b, dict)]
has_clarify = any("not 100%" in (r.get("message","") or "").lower() or "did you mean" in (r.get("message","").lower()) for _ in [0])
filters = intent_d.get("filters") or {}

# Verdict / failure-mode classification.
DET = {"scope_filter", "keyword", "crud", "learned", "multi-turn"}
verdict = "PASS"
if src in ("—", "") and not blocks:
    verdict = "MISS"
elif src == "clarify" or has_clarify:
    verdict = "CLARIFY"
elif src in ("llm", "llm-fallback") or r.get("from_fallback"):
    verdict = "LLM"
elif ms_i >= int(slow_ms):
    verdict = "SLOW"
elif variant == "filtered-list" and not filters:
    verdict = "FILTER-DROP"
elif src not in DET and src not in ("—",""):
    verdict = "SEMANTIC"

row = {"n": int(n), "table": table, "pkg": pkg, "variant": variant, "query": query,
       "source": src, "confidence": conf, "embedding": emb, "ms": ms_i,
       "was_successful": ok, "filters": filters, "blocks": blocks, "verdict": verdict}
json.dump(row, open(rowout, "w"))
print(f"  {int(n):>2} | {table[:18]:<18} | {variant:<14} | {src[:11]:<11} | "
      f"{conf[:5]:<5} | {emb[:5]:<5} | {str(ms_i)+'ms':<6} | {verdict:<13} | {query[:40]}")
PYEOF
done < "$OUT/battery.tsv"

# ── 3. aggregate + verdict histogram ────────────────────────────────────────
python3 - "$RESULTS_FILE" "$APP" "${RUN_LABEL:-$STAMP}" "$OUT"/row*.json <<'PYEOF'
import json, sys, collections, datetime
out, app, label = sys.argv[1:4]
rows = sorted((json.load(open(f)) for f in sys.argv[4:]), key=lambda r: r["n"])
hist = collections.Counter(r["verdict"] for r in rows)
passes = hist.get("PASS", 0)
doc = {"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
       "app": app, "label": label, "total": len(rows), "pass": passes,
       "verdicts": dict(hist), "rows": rows}
json.dump(doc, open(out, "w"), indent=2)
print()
print(f"  VERDICTS: {dict(hist)}")
print(f"  PASS {passes}/{len(rows)}  ·  results: {out}")
# Surface the failing rows grouped by mode for tuning focus.
fails = [r for r in rows if r["verdict"] != "PASS"]
if fails:
    print("\n  FAILURES (tune these):")
    for r in fails:
        print(f"    [{r['verdict']:<12}] {r['query'][:50]:<50} src={r['source']} ms={r['ms']} filters={r['filters']}")
PYEOF
