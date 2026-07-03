#!/usr/bin/env bash
# test-verify-app-domains.sh — regression tests for scripts/verify-app-domains.py
#
# Self-contained: builds a throwaway fixture workspace under mktemp (no
# dependency on the live apps/ tree), then asserts the checker's exit code +
# key output for every behavior class it guards:
#   1. clean mapping                       → exit 0
#   2. app_to_domains MISSING a domain     → exit 1  (the 2026-07-02 incident)
#   3. stale extra entry in app_to_domains → exit 1
#   4. domain path absent from registry    → exit 1
#   5. app not generated yet (--app)       → exit 0 with skip NOTE (bootstrap)
#   6. undeclared local-only app: --all    → exit 0 (advisory NOTE)
#                                 --app    → exit 1 (hard error at deploy point)
#
# Run: bash util/scripts/test-verify-app-domains.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$SCRIPT_DIR/../../scripts/verify-app-domains.py"
[[ -f "$CHECKER" ]] || { echo "FAIL: checker not found at $CHECKER" >&2; exit 1; }

FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

PASS=0; FAIL=0

# make_fixture <app_to_domains-json-fragment> — writes repos.json with a fixed
# 2-entry registry, plus apps/goodapp + apps/localonly packages.json fixtures.
make_fixture() {
  local a2d="$1"
  mkdir -p "$FIXTURE/apps/goodapp" "$FIXTURE/apps/localonly"
  cat > "$FIXTURE/repos.json" <<EOF
{
  "mandi_domain": [
    { "path": "mandi/domain/alpha", "url": "https://example.com/alpha.git" },
    { "path": "mandi/domain/beta",  "url": "https://example.com/beta.git" }
  ],
  "app_to_domains": { "_comment": "test fixture", $a2d }
}
EOF
  cat > "$FIXTURE/apps/goodapp/packages.json" <<'EOF'
{ "packages": {
    "alpha": { "dev": "../../mandi/domain/alpha" },
    "beta":  { "dev": "../../mandi/domain/beta" }
} }
EOF
  cat > "$FIXTURE/apps/localonly/packages.json" <<'EOF'
{ "packages": { "alpha": { "dev": "../../mandi/domain/alpha" } } }
EOF
}

# check <name> <expected-exit> <checker args...>
check() {
  local name="$1" want="$2"; shift 2
  local got=0
  python3 "$CHECKER" --gyanam "$FIXTURE" "$@" >/dev/null 2>&1 || got=$?
  if [[ "$got" == "$want" ]]; then
    echo "ok   $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name (exit $got, wanted $want)"
    FAIL=$((FAIL + 1))
  fi
}

# 1. clean mapping
make_fixture '"goodapp": ["mandi/domain/alpha", "mandi/domain/beta"]'
check "clean mapping passes" 0 --app goodapp

# 2. missing domain in app_to_domains (the incident class)
make_fixture '"goodapp": ["mandi/domain/alpha"]'
check "missing domain fails" 1 --app goodapp

# 3. stale extra entry
make_fixture '"goodapp": ["mandi/domain/alpha", "mandi/domain/beta", "mandi/domain/alpha-old"]'
check "stale extra entry fails" 1 --app goodapp

# 4. mapped path with no registry URL (flow-not-in-registry class)
make_fixture '"goodapp": ["mandi/domain/alpha", "mandi/domain/beta", "mandi/domain/gamma"]'
cat > "$FIXTURE/apps/goodapp/packages.json" <<'EOF'
{ "packages": {
    "alpha": { "dev": "../../mandi/domain/alpha" },
    "beta":  { "dev": "../../mandi/domain/beta" },
    "gamma": { "dev": "../../mandi/domain/gamma" }
} }
EOF
check "unregistered domain fails" 1 --app goodapp

# 5. app not generated yet → skip, exit 0 (fresh bootstrap must not be blocked)
make_fixture '"goodapp": ["mandi/domain/alpha", "mandi/domain/beta"]'
check "ungenerated app skips" 0 --app nosuchapp

# 6. undeclared local-only app: advisory under --all, hard error under --app
make_fixture '"goodapp": ["mandi/domain/alpha", "mandi/domain/beta"]'
check "undeclared app advisory under --all" 0 --all
check "undeclared app hard error under --app" 1 --app localonly

echo
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
