#!/usr/bin/env bash
# probe-chat-writes.sh — rerunnable regression harness for the chat WRITE-intent path.
#
# Sends a fixed battery of write/read permutations through the real /api/ai/chat endpoint
# (via `daksh api`, which handles auth) and CAPTURES the structured resolution telemetry
# per probe — resolution_source · confidence · was_successful · ui_blocks · suggestions —
# by reading the gy_intent_log row the chat writes for each turn. Emits a one-line-per-probe
# SCOREBOARD and writes a timestamped results JSON so successive runs (before/after each
# slice of the chat-conversational-write plan) are directly comparable.
#
# This is the empirical battery used during the 2026-06-22 design investigation, promoted to
# a reusable autowired script (founder rule: validation runs MUST produce reusable scripts).
# READ-ONLY beyond what the chat itself does (a high-confidence keyword match may auto-write
# one learned-phrasing row — the app's behavior, not this script's).
#
# Usage:
#   util/scripts/probe-chat-writes.sh [APP] [USER] [LABEL]
#     APP    default fwprod01
#     USER   default srinivas@lochan.ai:B@jarangaBali  (super_admin, user_id 1)
#     LABEL  optional run label (e.g. "pre-slice0", "post-slice0") — tags the results file
#
# Output: util/scripts/.probe-results/<APP>-<LABEL|timestamp>.json + a scoreboard to stdout.
# Compare two runs:  util/scripts/probe-chat-writes.sh fwprod01 "" post-slice0
#                    then diff the scoreboard against the pre-slice0 run.
#
# Requires: daksh-cli, python3, docker (for the gy_intent_log readout).
set -euo pipefail

REPO="/Users/srinivasnukala/Dropbox/Sites/docker/gyanam"
CLI="framework/lochan/packages/daksh/daksh-cli"
APP="${1:-fwprod01}"
USER_AUTH="${2:-srinivas@lochan.ai:B@jarangaBali}"
RUN_LABEL="${3:-}"
PG_CONTAINER="${APP}-postgres-1"
cd "$REPO"

# Autowire the DB role/name from the app's own env (don't hardcode — read the config).
PG_USER="$(grep -E '^POSTGRES_USER=' "apps/${APP}/.env" 2>/dev/null | cut -d= -f2 || echo postgres)"
PG_DB="$(grep -E '^POSTGRES_DB=' "apps/${APP}/.env" 2>/dev/null | cut -d= -f2 || echo "$APP")"

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
RESULTS_DIR="util/scripts/.probe-results"
mkdir -p "$RESULTS_DIR"
STAMP="$(python3 -c 'import datetime; print(datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))')"
RESULTS_FILE="$RESULTS_DIR/${APP}-${RUN_LABEL:-$STAMP}.json"

# Fixed battery — the 10 design probes. Each = "shape-label :: message". Edit to extend,
# but keep stable for before/after comparability.
PROBES=(
  "relation|possessive|nonexistent  :: update ssgnukala's role to user"
  "relation|possessive|real-user    :: change srinivas's role to user"
  "relation|no-possessive           :: set srinivas role to admin"
  "relation|make-X-a-Y              :: make srinivas an admin"
  "scalar|email|possessive          :: update srinivas's email to test@x.com"
  "scalar|email|no-possessive       :: change srinivas email to test@x.com"
  "edit|bare-no-value               :: edit user 1"
  "incomplete|slot-no-value         :: srinivas's role"
  "relation|natural-phrasing        :: give srinivas the recruiter role"
  "delete|record-ref                :: delete user 1"
)

# Pull the gy_intent_log row this probe just wrote (latest for the exact message).
# Returns "source|confidence|was_successful" or "—|—|—" if no row / no DB.
intent_log_row() {
  local msg="$1"
  docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAF'|' -c \
    "SELECT resolution_source, COALESCE(resolution_confidence,0), was_successful
       FROM gy_intent_log
      WHERE user_message = \$\$${msg}\$\$
      ORDER BY id DESC LIMIT 1;" 2>/dev/null | head -1 || true
}

run_probe() {
  local n="$1" label="$2" msg="$3"
  local body
  body=$(python3 -c 'import json,sys; print(json.dumps({"message":sys.argv[1],"conversation_id":None}))' "$msg")
  "./$CLI" api "$APP" POST /api/ai/chat "$body" --format json --as "$USER_AUTH" \
    > "$OUT/p${n}.json" 2>&1 || true
  local logrow; logrow="$(intent_log_row "$msg")"
  python3 - "$OUT/p${n}.json" "$n" "$label" "$msg" "$logrow" "$OUT/row${n}.json" <<'PYEOF'
import json, sys
respfile, n, label, msg, logrow, rowout = sys.argv[1:7]
try:
    d = json.load(open(respfile))
    r = d.get("data", {}).get("response", d.get("response", d))
except Exception:
    r = {}
src, conf, ok = (logrow.split("|") + ["", "", ""])[:3] if logrow else ("—", "—", "—")
blocks = [b.get("type") for b in r.get("ui_blocks", []) if isinstance(b, dict)]
sugg   = [s.get("label") for s in r.get("suggestions", []) if isinstance(s, dict)]
row = {
    "n": int(n), "label": label.strip(), "msg": msg,
    "source": src or "—", "confidence": conf or "—", "was_successful": ok or "—",
    "ui_blocks": blocks, "suggestions": sugg,
    "has_confirm": any(b == "actions" for b in blocks),
}
json.dump(row, open(rowout, "w"))
# scoreboard line
print(f"  {int(n):>2} | {row['source']:<11} | conf={row['confidence']:<6} | "
      f"ok={row['was_successful']:<5} | confirm={'Y' if row['has_confirm'] else '-'} | "
      f"blocks={','.join(blocks) or '-':<18} | {label.strip()}")
PYEOF
}

echo "== probe-chat-writes :: $APP as ${USER_AUTH%%:*} :: run='${RUN_LABEL:-$STAMP}' =="
echo "   #  | source      | confidence  | success | confirm | ui_blocks          | shape"
echo "  ----+-------------+-------------+---------+---------+--------------------+------"
i=0
for entry in "${PROBES[@]}"; do
  i=$((i+1)); label="${entry%% :: *}"; msg="${entry##* :: }"
  run_probe "$i" "$label" "$msg"
done

# Aggregate the per-probe rows into the comparable results file.
python3 - "$RESULTS_FILE" "$APP" "${RUN_LABEL:-$STAMP}" "$OUT"/row*.json <<'PYEOF'
import json, sys
out, app, label = sys.argv[1:4]
rows = [json.load(open(f)) for f in sys.argv[4:]]
rows.sort(key=lambda r: r["n"])
execed = sum(1 for r in rows if str(r["was_successful"]).lower() in ("t", "true"))
confirmed = sum(1 for r in rows if r["has_confirm"])
clarify = sum(1 for r in rows if r["source"] == "clarify")
json.dump({"app": app, "label": label, "probes": rows,
           "summary": {"total": len(rows), "executed_or_confirmed": confirmed,
                       "clarify_deadends": clarify, "was_successful": execed}},
          open(out, "w"), indent=2)
print(f"\n  SUMMARY: {len(rows)} probes · {confirmed} produced a confirm card · "
      f"{clarify} dead-ended at clarify · {execed} was_successful")
print(f"  Results: {out}")
print("  Compare:  diff <(jq -r '.probes[]|\"\\(.n) \\(.source) \\(.has_confirm)\"' OLD.json) \\")
print("                 <(jq -r '.probes[]|\"\\(.n) \\(.source) \\(.has_confirm)\"' NEW.json)")
PYEOF
