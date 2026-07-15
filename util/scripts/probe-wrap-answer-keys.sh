#!/usr/bin/env bash
# probe-wrap-answer-keys.sh — cross-app wrap answer-key accuracy harness.
#
# The wrap track mints, per wrapped app, a tier-2 SEMANTIC answer key: a set of
# natural-language utterances each mapped to the tool they SHOULD resolve to
# (plus `defer` rows that must NOT resolve above the confidence floor — an
# out-of-scope utterance correctly dropping to llm-fallback/clarify). This
# harness runs one (or all) of those keys against a TARGET app instance's LIVE
# intent corpus (`IntentEmbeddingIndex.search`) and reports per-app accuracy —
# the reproducible measure of whether the wrapped app's tool-intents are
# retrievable in that instance's corpus.
#
# ⚠ SCOPE MATTERS (the F2 finding this harness makes reproducible): a key only
# measures what it should if the target instance's corpus actually CARRIES the
# tool-phrases under test. A smriti/wrap key run on a longterm+framework-scoped
# instance scores near-zero because top-1 is polluted by unrelated framework
# intents — that is a corpus-scope mismatch, NOT a tool defect. Run each key on
# an instance whose corpus loads that app's (and, for the smriti key, smriti's
# wrap tool-phrases) intents. The scoreboard surfaces the miss detail so a
# scope mismatch is visible rather than mistaken for a regression.
#
# Usage:
#   util/scripts/probe-wrap-answer-keys.sh [APP] [KEY|all] [THRESHOLD]
#     APP        target app instance (default longterm01); uses <APP>-backend-1
#     KEY        one of: opencats | dotnetdesk | jtrac | smriti | all (default all)
#     THRESHOLD  confidence floor for a match / defer ceiling (default 0.55)
#
# Fixtures: the answer keys are git-tracked smriti acceptance fixtures at
#   framework/lochan/packages/smriti/backend/tests/fixtures/answer_keys/*.json
# (smriti owns the wrap capability all four validate). The harness reads them from
# the host source tree and docker-cp's each into the target container's /tmp — no
# dependency on what's baked into the app image.
#
# Output: util/scripts/.probe-results/<APP>-answerkeys-<stamp>.json + a scoreboard.
# Requires: docker (the app backend must be Up), python3. READ-ONLY w.r.t. the repo
# and the app DB (the harness only reads the corpus; it writes nothing to the app).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

APP="${1:-longterm01}"
WHICH="${2:-all}"
THRESHOLD="${3:-0.55}"
BACKEND="${APP}-backend-1"
KEYS_DIR="framework/lochan/packages/smriti/backend/tests/fixtures/answer_keys"
SCORER="util/scripts/probe-wrap-answer-keys.py"

# ── Preflight (fail loud) ───────────────────────────────────────────────────
[ -f "$SCORER" ] || { echo "FATAL: scorer not found: $SCORER" >&2; exit 2; }
[ -d "$KEYS_DIR" ] || { echo "FATAL: answer-key dir not found: $KEYS_DIR" >&2; exit 2; }
if ! docker ps --format '{{.Names}}' | grep -qx "$BACKEND"; then
  echo "FATAL: app backend container '$BACKEND' is not running (start app '$APP' first)." >&2
  exit 3
fi

if [ "$WHICH" = "all" ]; then
  KEY_FILES=$(find "$KEYS_DIR" -maxdepth 1 -name '*.json' | sort)
else
  KF="$KEYS_DIR/${WHICH}.json"
  [ -f "$KF" ] || { echo "FATAL: no answer key '$WHICH' at $KF" >&2; exit 2; }
  KEY_FILES="$KF"
fi

RESULTS_DIR="util/scripts/.probe-results"; mkdir -p "$RESULTS_DIR"
STAMP="$(python3 -c 'import datetime; print(datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))')"
RESULTS_FILE="$RESULTS_DIR/${APP}-answerkeys-${STAMP}.json"

echo "== probe-wrap-answer-keys :: app=$APP :: keys=$WHICH :: thresh=$THRESHOLD =="
echo "  key         |  pass/total | accuracy | notes"
echo "  ------------+-------------+----------+---------------------------------------"

# Stage the scorer once into the container.
docker cp "$SCORER" "$BACKEND:/tmp/probe-wrap-answer-keys.py"

TMP_OUT="$(mktemp -d)"; trap 'rm -rf "$TMP_OUT"' EXIT
ROW_FILES=()

for KF in $KEY_FILES; do
  name="$(basename "$KF" .json)"
  docker cp "$KF" "$BACKEND:/tmp/_answerkey.json"
  # Run the in-container scorer; capture only the ANSWERKEY_JSON line.
  raw="$(docker exec "$BACKEND" python /tmp/probe-wrap-answer-keys.py \
           /tmp/_answerkey.json "$THRESHOLD" 2>/dev/null | grep '^ANSWERKEY_JSON ' || true)"
  if [ -z "$raw" ]; then
    echo "  $(printf '%-11s' "$name") |     ERROR   |    —     | scorer produced no verdict (see container logs)"
    printf '{"package":"%s","error":"no verdict"}\n' "$name" > "$TMP_OUT/${name}.json"
    ROW_FILES+=("$TMP_OUT/${name}.json")
    continue
  fi
  echo "${raw#ANSWERKEY_JSON }" > "$TMP_OUT/${name}.json"
  ROW_FILES+=("$TMP_OUT/${name}.json")
  python3 - "$TMP_OUT/${name}.json" <<'PYEOF'
import json, sys
r = json.load(open(sys.argv[1]))
pkg = r.get("package", "?")
if "error" in r:
    print(f"  {pkg[:11]:<11} |     ERROR   |    —     | {r['error']}")
else:
    pt = f"{r['pass']}/{r['total']}"
    note = "clean" if not r["misses"] else f"{len(r['misses'])} miss (top: " + \
        (r['misses'][0]['got_tool'] or 'none') + f" @ {r['misses'][0]['got_score']})"
    print(f"  {pkg[:11]:<11} | {pt:^11} | {str(r['accuracy_pct'])+'%':>7}  | {note}")
PYEOF
done

# ── Aggregate → results JSON ─────────────────────────────────────────────────
python3 - "$RESULTS_FILE" "$APP" "$WHICH" "$THRESHOLD" "${ROW_FILES[@]}" <<'PYEOF'
import json, sys, datetime
out, app, which, thresh = sys.argv[1:5]
rows = [json.load(open(f)) for f in sys.argv[5:]]
doc = {
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "app": app, "keys": which, "threshold": float(thresh),
    "results": rows,
}
json.dump(doc, open(out, "w"), indent=2)
scored = [r for r in rows if "error" not in r]
if scored:
    tot_pass = sum(r["pass"] for r in scored)
    tot = sum(r["total"] for r in scored)
    print()
    print(f"  OVERALL {tot_pass}/{tot} = {round(100*tot_pass/tot,1)}%  ·  results: {out}")
else:
    print(f"\n  NO scored keys (all errored)  ·  results: {out}")
PYEOF
