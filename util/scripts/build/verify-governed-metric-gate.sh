#!/usr/bin/env bash
# verify-governed-metric-gate.sh — pre-deploy governed-metric acceptance gate
#
# Usage:
#   ./util/scripts/build/verify-governed-metric-gate.sh <app> <domain> <metric> [--expected-sha <sha>]
#   ./util/scripts/build/verify-governed-metric-gate.sh longterm01 arthik revenue
#   ./util/scripts/build/verify-governed-metric-gate.sh longterm01 arthik revenue --expected-sha 8a4b77e43
#
# WHY THIS EXISTS (iter-8 P0, Q-S1-06 + Q-S1-08 ratified):
#   Iteration-8 shipped a `tk_metric_query` NoneType.metadata regression that
#   was RED on the LIVE deployed executor for EVERY domain, yet passed CI (every
#   unit test injected the `service` test-seam, so the deployed `service is None`
#   path was never exercised). No deploy gate ran a governed-metric query, so the
#   break shipped. This gate makes that class UN-SHIPPABLE: a deploy is not green
#   until a real governed-metric query executes cleanly against the running app.
#
#   It ALSO catches the stale-image false-negative class (BLOCKER-C): an
#   incremental build that silently reuses a cached framework layer can leave the
#   deployed image WITHOUT a merged fix. The metric envelope carries the in-image
#   build stamp (`meta.build.source_commit`, from tarkan `__pkg_meta__`); the
#   gate asserts it matches the SHA the deploy built from — so a stale image
#   fails LOUD instead of being probed as healthy.
#
# TRANSPORT (Q-S1-08 = A): the gate hits the SYNCHRONOUS MCP tool-call door
#   (`POST /mcp/rpc`, muulam.jharokha) — NOT the chat door (BI-phrasing NL routing
#   is flaky → false-negatives) and NOT the SSE door (stateful stream-parse is
#   fragile in a shell gate). One deterministic authed call executes the tool by
#   name with explicit {domain,metric} args and returns the typed envelope.
#
# GREEN = ALL of:
#   1. The tool call returns HTTP 200 and isError=false.
#   2. The envelope carries a NUMERIC summary.value (the query resolved, no crash).
#   3. (if --expected-sha) meta.build.source_commit == the expected SHA (fresh image).
#
# Exit 0 only if all assertions pass. Any failure → exit 1 + a per-assertion report.
set -uo pipefail

APP="${1:-}"
DOMAIN="${2:-}"
METRIC="${3:-}"
EXPECTED_SHA=""
PERSONA="${GOVERNED_METRIC_GATE_PERSONA:-}"   # default: super-admin (daksh api default)

shift 3 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected-sha) EXPECTED_SHA="$2"; shift 2 ;;
    --as)           PERSONA="$2"; shift 2 ;;
    *) echo "verify-governed-metric-gate: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

if [[ -z "$APP" || -z "$DOMAIN" || -z "$METRIC" ]]; then
  echo "usage: verify-governed-metric-gate.sh <app> <domain> <metric> [--expected-sha <sha>] [--as <email[:pw]>]" >&2
  exit 2
fi

GYANAM_DIR="${GYANAM_DIR:-/Users/srinivasnukala/Dropbox/Sites/docker/gyanam}"
DAKSH="$GYANAM_DIR/framework/lochan/packages/daksh/daksh-cli"
[[ -x "$DAKSH" ]] || DAKSH="daksh"

echo "── Governed-metric gate: $APP  ($DOMAIN/$METRIC) ──"

# The synchronous MCP tool-call (Q-S1-08 A) — deterministic, no NL, no SSE.
BODY="$(printf '{"name":"tk_metric_query","arguments":{"domain":"%s","metric":"%s"}}' "$DOMAIN" "$METRIC")"
as_args=()
[[ -n "$PERSONA" ]] && as_args=(--as "$PERSONA")

RESP="$("$DAKSH" api "$APP" POST /mcp/rpc "$BODY" --format json "${as_args[@]}" 2>&1)" || {
  echo "  ✗ tool-call transport failed (daksh api POST /mcp/rpc):" >&2
  echo "$RESP" | tail -5 >&2
  exit 1
}

# The envelope: call_tool returns {"content":[{"text": <json>}], "isError": bool}.
# Extract the inner tk_metric_query envelope (data/meta/summary) and assert on it.
# jq does the parsing — fail loud if the shape is not what we expect.
if ! command -v jq >/dev/null 2>&1; then
  echo "  ✗ jq not found — the gate needs jq to parse the envelope" >&2
  exit 2
fi

IS_ERROR="$(printf '%s' "$RESP" | jq -r '.isError // empty' 2>/dev/null)"
INNER="$(printf '%s' "$RESP" | jq -r '.content[0].text // empty' 2>/dev/null)"
if [[ -z "$INNER" ]]; then
  echo "  ✗ no envelope in tool-call response (unexpected shape):" >&2
  printf '%s\n' "$RESP" | head -5 >&2
  exit 1
fi

# Assertion 1 — the tool did not error/crash.
if [[ "$IS_ERROR" == "true" ]]; then
  echo "  ✗ tool returned isError=true (query crashed or was rejected):" >&2
  printf '%s\n' "$INNER" | head -5 >&2
  exit 1
fi

# Assertion 2 — numeric summary.value (the query RESOLVED; the iter-8 P0 would
# fail here — a NoneType crash surfaces as an error envelope, never a number).
VALUE="$(printf '%s' "$INNER" | jq -r '(.summary.value // .data.rows[1][0] // empty)' 2>/dev/null)"
if [[ -z "$VALUE" || ! "$VALUE" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
  echo "  ✗ summary.value is not numeric (got: '${VALUE:-<none>}') — governed query did not resolve:" >&2
  printf '%s\n' "$INNER" | head -8 >&2
  exit 1
fi
echo "  ✓ governed query resolved: $DOMAIN/$METRIC summary.value = $VALUE"

# Assertion 3 (optional) — the deployed image is FRESH (carries the merged fix).
if [[ -n "$EXPECTED_SHA" ]]; then
  STAMPED="$(printf '%s' "$INNER" | jq -r '.meta.build.stamped // empty' 2>/dev/null)"
  GOT_SHA="$(printf '%s' "$INNER" | jq -r '.meta.build.source_commit // empty' 2>/dev/null)"
  if [[ "$STAMPED" != "true" || -z "$GOT_SHA" ]]; then
    echo "  ✗ stale-image check: envelope not build-stamped (stamped=$STAMPED) — cannot verify the deployed image's source_commit" >&2
    exit 1
  fi
  # Prefix-match: SOURCE_COMMIT_SHA may be full-length; --expected-sha may be short.
  if [[ "$GOT_SHA" != "$EXPECTED_SHA"* && "$EXPECTED_SHA" != "$GOT_SHA"* ]]; then
    echo "  ✗ STALE IMAGE: deployed source_commit=$GOT_SHA != expected $EXPECTED_SHA (the build reused a cached layer WITHOUT the merged fix)" >&2
    exit 1
  fi
  echo "  ✓ fresh image: source_commit=$GOT_SHA matches expected $EXPECTED_SHA"
fi

echo "✓ $APP governed-metric gate GREEN ($DOMAIN/$METRIC = $VALUE)"
exit 0
