#!/usr/bin/env bash
# probe-gap18-compliance-score.sh — runtime confirm for §GAP-18 (security
# compliance score returns a real score, NOT "schema_service not available").
#
# WHAT IT DOES
#   Hits the admin-gated GET /health/security endpoint on a running app (via
#   `daksh api`, which resolves the app's localhost port + auth), reads the
#   compliance block, and asserts:
#     PASS  → result.compliance.compliance_score is a number in [0,100]
#             AND result.compliance.status == "complete"
#     FAIL  → result.compliance.status == "skipped"/"unavailable"
#             (the "schema_service not available" GAP-18 failure), a crash,
#             or a missing score.
#   /health/security calls trishul.dristi.validate_all_schemas() directly (no
#   LLM/chat), so this is a deterministic single-shot probe.
#
# WHY THIS EXISTS (§GAP-18 runtime-confirm)
#   The GAP-18 acceptance criterion is a RUNTIME behavior, not a grep — a
#   prior grep-scoped "already closed" read was wrong (founder rule: don't
#   claim closed on a grep; [[feedback-validation-runs-must-produce-reusable-
#   autowired-scripts]]). Promoted to a reusable autowired script so the
#   before/after (RED bug → GREEN fix) is directly comparable and re-runnable.
#
#   Root cause the probe surfaces (verified at HEAD 2026-07-06):
#   trishul/dristi/startup_validator.py:60 imports the DEAD path
#   `from abhilekh.schema_service import get_schema_service` (that module
#   defines no such function → ImportError → caught → returns
#   {"status":"skipped","reason":"schema_service not available"}). Canonical
#   accessor is `from abhilekh import get_schema_service` (abhilekh/package.py:305,
#   re-exported at abhilekh/__init__.py:66; gyanam/router_factory.py:148 uses
#   the correct path). The fix is a stale-import repoint in framework/trishul.
#
# USAGE
#   util/scripts/probe-gap18-compliance-score.sh [APP] [USER_AUTH] [LABEL]
#     APP        default longterm01
#     USER_AUTH  default super_admin (email:password) — /health/security is admin-gated
#     LABEL      optional run label (e.g. "pre-fix", "post-fix") — tags the results file
#
#   Output: util/scripts/.probe-results/<APP>-gap18-<LABEL|timestamp>.json + scoreboard.
#   Exit:   0 = PASS (real score) · 1 = FAIL (skipped/unavailable/error) · 2 = probe error.
#
# Requires: daksh-cli, python3, a running <APP>.
set -euo pipefail

REPO="/Users/srinivasnukala/Dropbox/Sites/docker/gyanam"
CLI="framework/lochan/packages/daksh/daksh-cli"
APP="${1:-longterm01}"
USER_AUTH="${2:-srinivas@lochan.ai:B@jarangaBali}"
RUN_LABEL="${3:-}"
cd "$REPO"

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
RESULTS_DIR="util/scripts/.probe-results"
mkdir -p "$RESULTS_DIR"
STAMP="$(python3 -c 'import datetime; print(datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))')"
RESULTS_FILE="$RESULTS_DIR/${APP}-gap18-${RUN_LABEL:-$STAMP}.json"

echo "== probe-gap18-compliance-score :: $APP as ${USER_AUTH%%:*} :: run='${RUN_LABEL:-$STAMP}' =="

# Single-shot: GET /health/security (admin-gated; calls validate_all_schemas()).
RAW="$OUT/health-security.json"
if ! "./$CLI" api "$APP" GET /health/security --format json --as "$USER_AUTH" > "$RAW" 2>"$OUT/err.txt"; then
  echo "  PROBE ERROR — daksh api call failed (is $APP running + reachable?):"
  sed 's/^/    /' "$OUT/err.txt" | head -20
  exit 2
fi

# Parse + assert. Verdict logic lives in python (never hand-rolled JSON in bash).
python3 - "$RAW" "$RESULTS_FILE" "$APP" "${RUN_LABEL:-$STAMP}" <<'PYEOF'
import json, sys

raw_path, out_path, app, label = sys.argv[1:5]
try:
    payload = json.load(open(raw_path))
except Exception as e:
    print(f"  FAIL — response was not JSON: {e}")
    json.dump({"app": app, "label": label, "verdict": "FAIL",
               "reason": f"non-json response: {e}"}, open(out_path, "w"), indent=2)
    sys.exit(1)

compliance = (payload or {}).get("compliance", {}) if isinstance(payload, dict) else {}
status = compliance.get("status")
score = compliance.get("compliance_score")
reason = compliance.get("reason") or compliance.get("error")

# GAP-18 FAIL conditions: the schema_service skip, an unavailable block, or no score.
is_schema_service_skip = (status == "skipped" and
                          isinstance(reason, str) and "schema_service" in reason)
score_is_number = isinstance(score, (int, float)) and not isinstance(score, bool)

if is_schema_service_skip:
    verdict, why = "FAIL", f"GAP-18 OPEN — compliance skipped: {reason!r} (status={status!r})"
elif status == "unavailable":
    verdict, why = "FAIL", f"compliance unavailable: {reason!r}"
elif not score_is_number:
    verdict, why = "FAIL", f"no numeric compliance_score (status={status!r}, score={score!r})"
elif not (0 <= score <= 100):
    verdict, why = "FAIL", f"compliance_score out of range [0,100]: {score}"
elif status != "complete":
    verdict, why = "FAIL", f"score present but status!='complete' (status={status!r}, score={score})"
else:
    verdict, why = "PASS", f"compliance_score={score} status={status!r}"

icon = "✓" if verdict == "PASS" else "✗"
print(f"  {icon} {verdict} — {why}")
json.dump({"app": app, "label": label, "verdict": verdict, "reason": why,
           "compliance": compliance}, open(out_path, "w"), indent=2)
print(f"  Results: {out_path}")
print("  (GAP-18 fix = repoint trishul/dristi/startup_validator.py:60 "
      "`from abhilekh.schema_service import get_schema_service` "
      "→ `from abhilekh import get_schema_service`.)")
sys.exit(0 if verdict == "PASS" else 1)
PYEOF
