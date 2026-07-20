#!/usr/bin/env bash
# verify-acceptance-battery.sh — per-deploy metric acceptance battery
#
# Usage:
#   ./util/scripts/build/verify-acceptance-battery.sh <app> [--as <email[:pw]>] [--battery <path>]
#   ./util/scripts/build/verify-acceptance-battery.sh longterm01
#
# WHY THIS EXISTS (Phase-1 Build-5 companion; Q-S3-B5 ruled A):
#   verify-governed-metric-gate.sh proves a governed metric RESOLVES (numeric
#   value, build-stamp). This battery proves the value is CORRECT and the SAME
#   through both doors — the layer that "would have caught the iter-7 regression
#   at build time." Per case, up to four legs:
#     1. SELF-RECONCILE — summary.value == sum(the returned series rows).
#     2. RECONCILE-TO-RAW — summary.value == an independent raw-read tool's field
#        (e.g. pipeline_stage_count == lt_application_pipeline.total). When the
#        raw-read tool doesn't exist yet, the case declares `pending_tool` and
#        this leg is SKIPPED-LOUD (reported PENDING, tracked — never silently
#        passed, never a fabricated provider; Pact-style, Q-S3-B5).
#     3. PARITY — the SAME metric over the CHAT door == the MCP door (identical
#        numbers both doors; the one check that guards chat!=MCP drift).
#     4. GOVERNANCE — data-only over MCP (ui_blocks==[]) / empty-slice graceful
#        (success + meta.empty, no crash on zero rows).
#
# TRANSPORT: MCP = POST /api/jharokha/mcp/rpc (deterministic sync door, same as
#   the metric gate). CHAT = POST /api/ai/chat (the in-app IntentResolver door).
#   Both authed via `daksh api` (super-admin default; --as to override).
#
# EXIT: 0 all legs pass (PENDING legs don't fail the gate) · 1 a reconcile/parity
#   assertion FAILED · 2 infra (app unreachable / battery unreadable).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# Route daksh through the shared shim (host venv if present, else containerized —
# the server has no venv by design). The shim exits 86 = "daksh could not run"
# (distinct from any daksh verdict), which _rpc below turns into a LOUD infra
# abort instead of feeding a crash's stderr into jq as a false "did not reconcile"
# verdict — the exact misdirection this gate's `2>&1`-into-value pattern caused.
DAKSH="${DAKSH:-$REPO_ROOT/util/scripts/daksh-docker}"
readonly EX_DAKSH_COULDNT_RUN=86
APP=""
BATTERY="$REPO_ROOT/util/scripts/build/acceptance_battery.json"
as_args=()
STRICT_PARITY=0   # chat-vs-MCP parity: WARN by default, FAIL with --strict-parity

while [ $# -gt 0 ]; do
  case "$1" in
    --as) as_args=(--as "$2"); shift 2 ;;
    --battery) BATTERY="$2"; shift 2 ;;
    --strict-parity) STRICT_PARITY=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) APP="$1"; shift ;;
  esac
done
[ -n "$APP" ] || { echo "usage: verify-acceptance-battery.sh <app> [--as ..] [--battery ..]" >&2; exit 2; }
[ -f "$BATTERY" ] || { echo "✗ battery not found: $BATTERY" >&2; exit 2; }
command -v jq >/dev/null || { echo "✗ jq required" >&2; exit 2; }

# _rpc <tool> <args-json> — one deterministic MCP sync tool call (mirrors the
# governed-metric gate's transport so both gates unwrap identically).
_rpc() {
  local out rc
  out="$("$DAKSH" api "$APP" POST /api/jharokha/mcp/rpc \
    "$(printf '{"name":"%s","arguments":%s}' "$1" "$2")" \
    --format json ${as_args[@]+"${as_args[@]}"} 2>&1)"
  rc=$?
  # crash≠verdict: daksh-couldn't-run must NOT flow downstream as a response for
  # jq to (mis)parse into a false reconcile failure. Abort loud with the infra
  # exit (2), never let a crash masquerade as a semantic verdict.
  if [ "$rc" -eq "$EX_DAKSH_COULDNT_RUN" ]; then
    echo "✗ daksh could not run (exit $rc) — acceptance battery could NOT execute; this is an infra failure, NOT a metric-reconcile failure." >&2
    printf '%s\n' "$out" | tail -5 >&2
    exit 2
  fi
  printf '%s' "$out"
}
# _mcp_result <tool> <args-json> — the unwrapped tool result object.
_mcp_result() {
  _rpc "$1" "$2" | jq -c '
    (.data.response // .) as $b
    | ($b.content[0].text // empty) | fromjson
    | (.data.data.result // .data.result // .result // .)' 2>/dev/null
}
# _chat_summary_value <domain> <metric> — value the CHAT door returns for a
# metric (via the natural "what's our <metric>" phrasing → IntentResolver →
# tk_metric_query). Returns the numeric summary.value or empty.
_chat_summary_value() {
  local dom="$1" met="$2"
  local resp rc
  # The chat door drives shared-ollama → needs the shared-ai network so the
  # containerized shim can resolve the ollama service by name (host net can't).
  resp="$(DAKSH_DOCKER_NETWORK=shared-ai "$DAKSH" api "$APP" POST /api/ai/chat \
    "$(printf '{"message":"what is %s for %s"}' "$met" "$dom")" \
    --format json ${as_args[@]+"${as_args[@]}"} 2>&1)"
  rc=$?
  # same crash≠verdict guard as _rpc: a daksh crash on the chat door must not
  # surface as a phantom parity value.
  if [ "$rc" -eq "$EX_DAKSH_COULDNT_RUN" ]; then
    echo "✗ daksh could not run (exit $rc) on the chat door — infra failure, not a parity miss." >&2
    exit 2
  fi
  printf '%s' "$resp" | jq -r '
    .. | objects | select(has("summary")) | .summary.value? // empty' 2>/dev/null | head -1
}

_metric_args() { # <case-json> → the tk_metric_query arguments object
  jq -c --arg d "$1" '{domain:$d, metric:.metric} + (.arguments // {})' <<<"$2"
}

PASS=0; FAIL=0; PEND=0; WARN=0
_ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
_bad()  { echo "  ✗ $1" >&2; FAIL=$((FAIL+1)); }
_pend() { echo "  ⧗ PENDING $1"; PEND=$((PEND+1)); }

echo "── acceptance battery: $APP ($(jq '.acceptance_cases|length' "$BATTERY") cases) ──"

CASES="$(jq -c '.acceptance_cases[]' "$BATTERY")"
while IFS= read -r c; do
  id="$(jq -r '.id' <<<"$c")"; dom="$(jq -r '.domain' <<<"$c")"; met="$(jq -r '.metric' <<<"$c")"
  margs="$(_metric_args "$dom" "$c")"
  res="$(_mcp_result tk_metric_query "$margs")"
  if [ -z "$res" ] || [ "$res" = "null" ]; then _bad "$id: tk_metric_query returned no result"; continue; fi

  # governance: empty-slice graceful — success + meta.empty, no crash
  if jq -e '.assert_governance | test("meta.empty")' <<<"$c" >/dev/null 2>&1; then
    if [ "$(jq -r '.meta.empty // false' <<<"$res")" = "true" ]; then _ok "$id: empty-slice graceful (meta.empty)"
    else _bad "$id: empty slice did not set meta.empty"; fi
    continue
  fi
  # governance: data-only over MCP — ui_blocks must be [] on the MCP door
  if jq -e '.assert_governance | test("ui_blocks")' <<<"$c" >/dev/null 2>&1; then
    n="$(_rpc tk_metric_query "$margs" | jq -c '.. | objects | select(has("ui_blocks")) | .ui_blocks' 2>/dev/null | head -1)"
    if [ -z "$n" ] || [ "$n" = "[]" ]; then _ok "$id: data-only over MCP (ui_blocks empty)"
    else _bad "$id: MCP door leaked ui_blocks: $n"; fi
    continue
  fi
  # governance: build-stamped
  if jq -e '.assert_governance | test("build.stamped")' <<<"$c" >/dev/null 2>&1; then
    if [ "$(jq -r '.meta.build.stamped // false' <<<"$res")" = "true" ] \
       && [ "$(jq -r '.meta.build.source_commit // "null"' <<<"$res")" != "null" ]; then _ok "$id: build-stamped"
    else _bad "$id: not build-stamped (stale-image risk)"; fi
    continue
  fi

  val="$(jq -r '.summary.value // empty' <<<"$res")"
  if [ -z "$val" ]; then _bad "$id: no summary.value"; continue; fi

  # variance
  if jq -e 'has("assert_variance")' <<<"$c" >/dev/null 2>&1; then
    tgt="$(jq -r '.summary.target // empty' <<<"$res")"; var="$(jq -r '.summary.variance // empty' <<<"$res")"
    if [ -z "$tgt" ]; then _pend "$id: no target declared (variance leg pends)"
    elif awk "BEGIN{exit !(($val)-($tgt) == ($var))}"; then _ok "$id: variance == value - target"
    else _bad "$id: variance $var != value-$tgt"; fi
    continue
  fi

  # 1. self-reconcile: summary.value == sum of series rows
  rowsum="$(jq -r '[.data.rows[1][]? // empty] | add // empty' <<<"$res" 2>/dev/null)"
  if [ -n "$rowsum" ]; then
    if awk "BEGIN{exit !(($val)==($rowsum))}"; then _ok "$id: self-reconcile ($val == Σrows)"
    else _bad "$id: self-reconcile $val != Σrows $rowsum"; fi
  fi

  # 2. reconcile-to-raw (or PENDING)
  if jq -e '.reconcile_to.pending_tool' <<<"$c" >/dev/null 2>&1; then
    _pend "$id: reconcile-to-raw ($(jq -r '.reconcile_to.pending_tool' <<<"$c") not a @tool yet — Q-S3-B5 follow-on)"
  elif jq -e '.reconcile_to.tool' <<<"$c" >/dev/null 2>&1; then
    rtool="$(jq -r '.reconcile_to.tool' <<<"$c")"; rfield="$(jq -r '.reconcile_to.field // "total"' <<<"$c")"
    raw="$(_mcp_result "$rtool" '{}')"
    # raw-read tools nest their payload variably (e.g. lt_application_pipeline →
    # .data.data.total); search recursively for the named field so the gate
    # isn't coupled to one envelope depth.
    rawval="$(jq -r --arg f "$rfield" 'first(.. | objects | select(has($f)) | .[$f]) // empty' <<<"$raw")"
    if [ -z "$rawval" ]; then _bad "$id: reconcile tool $rtool returned no .$rfield"
    elif awk "BEGIN{exit !(($val)==($rawval))}"; then _ok "$id: reconcile-to-raw ($val == $rtool.$rfield)"
    else _bad "$id: reconcile $val != $rtool.$rfield $rawval"; fi
  fi

  # 3. chat-vs-MCP parity. WARN by default (the chat-corpus metric-routing is an
  # evolving surface — a hard parity gate would red every app until every metric
  # phrasing routes to tk_metric_query over chat). --strict-parity makes it a
  # hard failure once an app's chat corpus is proven. A parity MISS is always
  # REPORTED (tracked, never silent) — only its gate-blocking-ness is gated.
  if [ "$(jq -r '.parity // false' <<<"$c")" = "true" ]; then
    cval="$(_chat_summary_value "$dom" "$met")"
    if [ -n "$cval" ] && awk "BEGIN{exit !(($val)==($cval))}"; then _ok "$id: chat==MCP parity ($val)"
    elif [ "$STRICT_PARITY" -eq 1 ]; then
      _bad "$id: parity — chat door value '${cval:-<none>}' != MCP $val (strict)"
    else
      echo "  ⚠ WARN $id: chat!=MCP parity (chat '${cval:-<none>}' vs MCP $val — chat metric-routing gap; --strict-parity to enforce)"
      WARN=$((WARN+1))
    fi
  fi
done <<<"$CASES"

echo "── battery: $PASS passed · $FAIL failed · $PEND pending · $WARN warn ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
