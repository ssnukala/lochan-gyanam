#!/usr/bin/env bash
# test-verify-app-domains.sh — regression tests for scripts/verify-app-domains.py
#
# B1 (2026-07-13): the domain set is DERIVED from apps/<app>/packages.json (the
# single source of truth), so repos.json's app_to_domains block is retired and
# with it the old drift-check. This suite guards the SURVIVING contract:
#   1. all derived domains resolve in the registry     → exit 0
#   2. a derived domain absent from the registry        → exit 1  (flow-outage
#                                                          class: can't clone)
#   3. app with no packages.json, via --app             → exit 1  (fail-loud:
#                                                          can't derive, must not
#                                                          silent-zero-clone)
#   4. app with no packages.json, via --all             → exit 0  (advisory NOTE:
#                                                          not deployed in a sweep)
#   5. framework-only app (no domains) resolves          → exit 0
#
# Self-contained: builds a throwaway fixture workspace under mktemp (no
# dependency on the live apps/ tree).
#
# Run: bash util/scripts/test-verify-app-domains.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$SCRIPT_DIR/../../scripts/verify-app-domains.py"
[[ -f "$CHECKER" ]] || { echo "FAIL: checker not found at $CHECKER" >&2; exit 1; }

FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

PASS=0; FAIL=0

# base_repos — resets the fixture (fresh apps/ each test — no cross-test leak)
# and writes a repos.json with a fixed 2-entry mandi_domain registry (alpha +
# beta) and NO app_to_domains block (retired by B1).
base_repos() {
  rm -rf "$FIXTURE/apps" "$FIXTURE/mandi"
  cat > "$FIXTURE/repos.json" <<'EOF'
{
  "mandi_domain": [
    { "path": "mandi/domain/alpha", "url": "https://example.com/alpha.git" },
    { "path": "mandi/domain/beta",  "url": "https://example.com/beta.git" }
  ]
}
EOF
}

# app_pkgjson <app> <packages-json-body>
app_pkgjson() {
  mkdir -p "$FIXTURE/apps/$1"
  printf '%s\n' "$2" > "$FIXTURE/apps/$1/packages.json"
}

# check <name> <expected-exit> <checker args...>
check() {
  local name="$1" want="$2"; shift 2
  local got=0
  python3 "$CHECKER" --gyanam "$FIXTURE" "$@" >/dev/null 2>&1 || got=$?
  if [[ "$got" == "$want" ]]; then
    echo "ok   $name"; PASS=$((PASS + 1))
  else
    echo "FAIL $name (exit $got, wanted $want)"; FAIL=$((FAIL + 1))
  fi
}

# 1. all derived domains resolve in the registry → clean
base_repos
app_pkgjson goodapp '{ "packages": {
    "alpha": { "dev": "../../mandi/domain/alpha" },
    "beta":  { "dev": "../../mandi/domain/beta" }
} }'
check "derived domains resolve → clean" 0 --app goodapp

# 2. a derived domain absent from the registry → fail (flow-outage class)
base_repos
app_pkgjson badapp '{ "packages": {
    "alpha": { "dev": "../../mandi/domain/alpha" },
    "gamma": { "dev": "../../mandi/domain/gamma" }
} }'
check "unregistered derived domain fails" 1 --app badapp

# 3. no packages.json, via --app → fail-loud (cannot derive, no silent skip)
base_repos
check "no packages.json --app fails loud" 1 --app nosuchapp

# 4. no packages.json, via --all → advisory (exit 0; not deployed in a sweep)
base_repos
app_pkgjson goodapp '{ "packages": {
    "alpha": { "dev": "../../mandi/domain/alpha" },
    "beta":  { "dev": "../../mandi/domain/beta" }
} }'
check "no packages.json --all is advisory" 0 --all

# 5. framework-only app (no mandi/domain deps) resolves clean
base_repos
app_pkgjson fwapp '{ "packages": { "somepkg": { "dev": "../../mandi/common/somepkg" } } }'
check "framework-only app resolves clean" 0 --app fwapp

# ── B2: url from own mandi.json (repo field) + dir-scan + wrap-exclude ────────

# domain_mandi <name> <mandi-json-body> — create a mandi/domain/<name>/mandi.json
domain_mandi() {
  mkdir -p "$FIXTURE/mandi/domain/$1"
  printf '%s\n' "$2" > "$FIXTURE/mandi/domain/$1/mandi.json"
}

# 6. url resolves from the domain's OWN mandi.json `repo` (B2 — prefer over
#    registry). gamma is NOT in the registry but HAS a mandi.json repo → clean.
base_repos
domain_mandi gamma '{ "name": "gamma", "tier": "domain", "repo": "https://example.com/gamma.git" }'
app_pkgjson gapp '{ "packages": { "gamma": { "dev": "../../mandi/domain/gamma" } } }'
check "url from own mandi.json repo resolves" 0 --app gapp

# 7. --all dir-scan: a domain DIR with a mandi.json but NO url anywhere → fail
base_repos
domain_mandi orphan '{ "name": "orphan", "tier": "domain" }'
check "scanned domain with no url fails --all" 1 --all

# 8. --all dir-scan EXCLUDES a wrap-baseline artifact (migrated_from tag) — an
#    orphan wrap domain must NOT trip the registry audit.
base_repos
domain_mandi wrapbase '{ "name": "wrapbase", "tier": "domain", "migrated_from": "legacy-1.0", "tags": ["wrap-baseline"] }'
check "wrap-baseline domain excluded from scan" 0 --all

echo
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
