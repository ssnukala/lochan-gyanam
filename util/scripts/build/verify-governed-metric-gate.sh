#!/usr/bin/env bash
# verify-governed-metric-gate.sh — pre-deploy governed-metric acceptance gate
#
# Usage:
#   ./util/scripts/build/verify-governed-metric-gate.sh <app> [--expected-sha <sha>] [--as <email[:pw]>]
#   ./util/scripts/build/verify-governed-metric-gate.sh longterm01
#   ./util/scripts/build/verify-governed-metric-gate.sh longterm01 --expected-sha 01666ec5a
#
# WHY THIS EXISTS (iter-8 P0, Q-S1-06 + Q-S1-08 ratified):
#   Iteration-8 shipped a `tk_metric_query` NoneType.metadata regression that
#   was RED on the LIVE deployed executor for EVERY domain, yet passed CI (every
#   unit test injected the `service` test-seam, so the deployed `service is None`
#   path was never exercised). No deploy gate ran a governed-metric query, so the
#   break shipped. This gate makes that class UN-SHIPPABLE: a deploy is not green
#   until every deploy-gate metric executes cleanly against the running app.
#
#   It ALSO catches the stale-image false-negative class (BLOCKER-C): an
#   incremental build that silently reuses a cached framework layer can leave the
#   deployed image WITHOUT a merged fix. The metric envelope carries the in-image
#   build stamp (`meta.build.source_commit`, from tarkan `__pkg_meta__`); the
#   gate asserts it matches the SHA the deploy built from — so a stale image
#   fails LOUD instead of being probed as healthy.
#
# OPT-IN IS DECLARATIVE + AUTOWIRED (founder-ruled 2026-07-10):
#   A metric self-declares `@metric(..., deploy_gate=True)`. This gate DISCOVERS
#   the gate-flagged metrics off the LIVE registry — it reads the app's domains
#   from apps/<app>/packages.json, calls `describe_metrics(domain)` over the
#   /mcp/rpc sync door for each, and probes every metric whose contract carries
#   `deploy_gate: true`. NO per-app .env/manifest hand-config, no drift — the
#   registry (the same one tk_metric_query reads) is the source of truth.
#
# TRANSPORT (Q-S1-08 = A): all calls hit the SYNCHRONOUS MCP tool-call door
#   (`POST /mcp/rpc`, muulam.jharokha) — NOT the chat door (flaky BI-phrasing NL
#   routing → false-negatives) and NOT the SSE door (fragile stream-parse). One
#   deterministic authed call per tool invocation returns the typed envelope.
#
# GREEN (per discovered deploy_gate metric) = ALL of:
#   1. The tk_metric_query call returns isError=false.
#   2. The envelope carries a NUMERIC summary.value (query resolved, no crash).
#   3. (if --expected-sha) meta.build.source_commit == expected SHA (fresh image).
#
# Exit 0 if every deploy_gate metric passes (or the app declares none — clean
# no-op). Any failure → exit 1 + a per-assertion report.
set -uo pipefail

APP="${1:-}"
EXPECTED_SHA=""
PERSONA="${GOVERNED_METRIC_GATE_PERSONA:-}"   # default: super-admin (daksh api default)

shift 1 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected-sha) EXPECTED_SHA="$2"; shift 2 ;;
    --as)           PERSONA="$2"; shift 2 ;;
    *) echo "verify-governed-metric-gate: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

if [[ -z "$APP" ]]; then
  echo "usage: verify-governed-metric-gate.sh <app> [--expected-sha <sha>] [--as <email[:pw]>]" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "  ✗ jq not found — the gate needs jq" >&2; exit 2; }

GYANAM_DIR="${GYANAM_DIR:-/Users/srinivasnukala/Dropbox/Sites/docker/gyanam}"
DAKSH="$GYANAM_DIR/util/scripts/daksh-docker"  # shared shim: host venv or containerized (server has no venv)
readonly EX_DAKSH_COULDNT_RUN=86
PKG_JSON="$GYANAM_DIR/apps/$APP/packages.json"
as_args=(); [[ -n "$PERSONA" ]] && as_args=(--as "$PERSONA")

echo "── Governed-metric gate: $APP ──"

# _rpc <tool-name> <arguments-json> — one deterministic sync tool call.
_rpc() {
  local name="$1" args="$2" out rc
  out="$("$DAKSH" api "$APP" POST /api/jharokha/mcp/rpc \
    "$(printf '{"name":"%s","arguments":%s}' "$name" "$args")" \
    --format json ${as_args[@]+"${as_args[@]}"} 2>&1)"
  rc=$?
  # crash≠verdict: daksh-couldn't-run must abort loud as infra (2), never flow
  # downstream as a response for _envelope/jq to misparse into a false gate verdict.
  if [ "$rc" -eq "$EX_DAKSH_COULDNT_RUN" ]; then
    echo "  ✗ daksh could not run (exit $rc) — the governed-metric gate could NOT execute; infra failure, NOT a metric-governance failure." >&2
    printf '%s\n' "$out" | tail -5 >&2
    exit 2
  fi
  printf '%s' "$out"
}

# _envelope <rpc-response> — unwrap to the tool's `result` object (metrics/summary/meta).
# Three nested wrappers: (1) `daksh api --format json` wraps the HTTP body as the
# OBJECT `.data.response`; (2) MCP call_tool wraps the payload as `.content[0].text`
# (a JSON STRING → fromjson); (3) the tarkan tool nests its envelope at
# `.data.data.result`. Peel all three; hand back the result (.metrics/.summary/.meta).
_envelope() {
  printf '%s' "$1" | jq -c '
    (.data.response // .) as $body
    | ($body.content[0].text // empty) | fromjson
    | (.data.data.result // .data.result // .result // .)
  ' 2>/dev/null
}

# Discover the app's domains from packages.json (primary + siblings) — no
# hand-config; the bundle already declares them.
if [[ ! -f "$PKG_JSON" ]]; then
  echo "  ✗ $PKG_JSON not found — cannot resolve the app's domains" >&2
  exit 1
fi
# `while read` not `mapfile` — mapfile is bash 4+; macOS ships bash 3.2 and the
# gate must run on the deploy host's default shell.
DOMAINS=()
while IFS= read -r _d; do
  [[ -n "$_d" ]] && DOMAINS+=("$_d")
done < <(jq -r '([.primary] + (.packages | keys)) | unique | .[]' "$PKG_JSON" 2>/dev/null)
# No domains = a framework-only app (e.g. fwprod01, the framework test app). It
# structurally CANNOT declare a deploy_gate metric (those live in domain
# packages), so there is nothing to gate — a clean no-op (exit 0), NOT a
# failure. Same contract as the "0 deploy_gate metrics" case below; treating
# it as exit 1 wrongly makes every domainless app un-deployable-green.
if [[ ${#DOMAINS[@]} -eq 0 ]]; then
  echo "  · $APP declares no domains — no domain deploy_gate metrics possible (clean no-op)"
  echo "✓ $APP governed-metric gate GREEN (framework-only, 0 gate metrics)"
  exit 0
fi

# Collect deploy_gate metrics across the app's domains (via describe_metrics).
declare -a GATE_METRICS=()   # "domain metric"
for dom in "${DOMAINS[@]}"; do
  resp="$(_rpc describe_metrics "$(printf '{"domain":"%s"}' "$dom")")"
  env="$(_envelope "$resp")"
  [[ -z "$env" ]] && continue    # a domain with no metric catalog is fine
  while IFS= read -r m; do
    [[ -n "$m" ]] && GATE_METRICS+=("$dom $m")
  done < <(printf '%s' "$env" | jq -r '(.metrics // [])[] | select(.deploy_gate == true) | .name' 2>/dev/null)
done

if [[ ${#GATE_METRICS[@]} -eq 0 ]]; then
  echo "  · $APP declares no deploy_gate metrics — nothing to gate (clean no-op)"
  echo "✓ $APP governed-metric gate GREEN (0 gate metrics)"
  exit 0
fi

FAILED=0
for pair in "${GATE_METRICS[@]}"; do
  dom="${pair%% *}"; met="${pair##* }"
  resp="$(_rpc tk_metric_query "$(printf '{"domain":"%s","metric":"%s"}' "$dom" "$met")")"
  env="$(_envelope "$resp")"
  is_err="$(printf '%s' "$resp" | jq -r '.isError // empty' 2>/dev/null)"

  if [[ -z "$env" ]]; then
    echo "  ✗ $dom/$met: no envelope in tool-call response" >&2
    printf '%s\n' "$resp" | head -3 >&2; FAILED=1; continue
  fi
  # Assertion 1 — no error/crash (the iter-8 P0 surfaces here as isError=true).
  if [[ "$is_err" == "true" ]]; then
    echo "  ✗ $dom/$met: isError=true (query crashed or was rejected):" >&2
    printf '%s\n' "$env" | head -3 >&2; FAILED=1; continue
  fi
  # Assertion 2 — numeric summary.value (the query RESOLVED).
  val="$(printf '%s' "$env" | jq -r '(.summary.value // .data.rows[1][0] // empty)' 2>/dev/null)"
  if [[ -z "$val" || ! "$val" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    echo "  ✗ $dom/$met: summary.value not numeric (got '${val:-<none>}') — did not resolve:" >&2
    printf '%s\n' "$env" | head -6 >&2; FAILED=1; continue
  fi
  # Assertion 3 (optional) — the deployed image is FRESH (carries the merged fix).
  if [[ -n "$EXPECTED_SHA" ]]; then
    stamped="$(printf '%s' "$env" | jq -r '.meta.build.stamped // empty' 2>/dev/null)"
    got_sha="$(printf '%s' "$env" | jq -r '.meta.build.source_commit // empty' 2>/dev/null)"
    if [[ "$stamped" != "true" || -z "$got_sha" ]]; then
      echo "  ✗ $dom/$met: not build-stamped (stamped=$stamped) — cannot verify source_commit" >&2
      FAILED=1; continue
    fi
    if [[ "$got_sha" != "$EXPECTED_SHA"* && "$EXPECTED_SHA" != "$got_sha"* ]]; then
      echo "  ✗ STALE IMAGE ($dom/$met): source_commit=$got_sha != expected $EXPECTED_SHA (build reused a cached layer WITHOUT the merged fix)" >&2
      FAILED=1; continue
    fi
    echo "  ✓ $dom/$met = $val  (fresh image: source_commit=${got_sha:0:12})"
  else
    echo "  ✓ $dom/$met = $val"
  fi
done

if (( FAILED )); then
  echo "✗ $APP governed-metric gate FAILED" >&2
  exit 1
fi
echo "✓ $APP governed-metric gate GREEN (${#GATE_METRICS[@]} gate metric(s))"
exit 0
