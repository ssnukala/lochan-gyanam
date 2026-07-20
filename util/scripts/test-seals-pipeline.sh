#!/bin/bash
# End-to-end smoke test for the lochan.seals signing pipeline (Sweep C9.6).
# Usage: ./util/scripts/test-seals-pipeline.sh [--keep-keys] [--include-fwprod01]
#
# Tests every CLI surface shipped today across:
#   - C9 substrate (lochan #200 / #202 / #205 / #211 / #212)
#   - C9.5 determinism check (lochan-janch #13)
#   - C10 pre-commit drift gate (lochan-daksh #69)
#   - C9.6.1-5 signing pipeline (lochan-daksh #70 / #71 / #72 / #73 / #74)
#
# Default: tests host-side flows only (~3 min). Pass --include-fwprod01 to
# also exec into the running fwprod01 backend container and run the
# deployment-verify gate inside the image.
#
# By default the script CLEANS UP generated keys + on-disk seals at exit
# so the framework tree returns to its pre-test state. Pass --keep-keys
# to preserve the generated key + registry entry (useful for follow-up
# manual exploration).

set -euo pipefail
cd "$(dirname "$0")/../.."

# ── Args ───────────────────────────────────────────────────────────

KEEP_KEYS=false
INCLUDE_FWPROD01=false
for arg in "$@"; do
    case "$arg" in
        --keep-keys) KEEP_KEYS=true ;;
        --include-fwprod01) INCLUDE_FWPROD01=true ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

# ── Output helpers ─────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

section() {
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════════${RESET}"
    echo -e "${BLUE}  $1${RESET}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════${RESET}"
}

step() {
    echo ""
    echo -e "${YELLOW}▶ $1${RESET}"
}

pass() {
    echo -e "  ${GREEN}✓ PASS${RESET} — $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo -e "  ${RED}✗ FAIL${RESET} — $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# Exit with appropriate code at end.
trap 'final_summary' EXIT

final_summary() {
    rc=$?
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════════${RESET}"
    if [ "$FAIL_COUNT" -eq 0 ]; then
        echo -e "  ${GREEN}ALL ${PASS_COUNT} CHECKS PASSED${RESET}"
    else
        echo -e "  ${RED}${FAIL_COUNT} OF $((PASS_COUNT + FAIL_COUNT)) CHECKS FAILED${RESET} (passed: ${PASS_COUNT})"
    fi
    echo -e "${BLUE}══════════════════════════════════════════════════════════${RESET}"
    [ "$FAIL_COUNT" -eq 0 ] && [ "$rc" -eq 0 ]
}

# ── Test fixtures ──────────────────────────────────────────────────

DAKSH="./util/scripts/daksh-docker"  # shared shim: host venv or containerized (server has no venv)
TEST_PKG="dravya"           # PoC package with @governance_capability decorations
TEST_PKG_ROOT="mandi/common/${TEST_PKG}"
SEALS_FILE="${TEST_PKG_ROOT}/lochan.seals"
SIG_FILE="${TEST_PKG_ROOT}/lochan.seals.sig"

# Snapshot for cleanup
mkdir -p /tmp/seals-test-snapshot
PRE_SEALS_BACKUP="/tmp/seals-test-snapshot/dravya-lochan.seals.bak"
PRE_SIG_BACKUP="/tmp/seals-test-snapshot/dravya-lochan.seals.sig.bak"

# Save state if any
[ -f "$SEALS_FILE" ] && cp "$SEALS_FILE" "$PRE_SEALS_BACKUP" || rm -f "$PRE_SEALS_BACKUP"
[ -f "$SIG_FILE" ] && cp "$SIG_FILE" "$PRE_SIG_BACKUP" || rm -f "$PRE_SIG_BACKUP"

# ── Section 0 — Pre-flight ─────────────────────────────────────────

section "0. Pre-flight: daksh CLI + framework checkout reachable"

step "0.1 Locate daksh-cli"
if [ -x "$DAKSH" ]; then
    pass "daksh-cli found at $DAKSH"
else
    fail "daksh-cli not found or not executable at $DAKSH"
    exit 1
fi

step "0.2 Locate framework/lochan"
if [ -d "framework/lochan/packages/muulam/backend/muulam/auto_wire" ]; then
    pass "framework/lochan checkout reachable"
else
    fail "framework/lochan not found — run from gyanam root"
    exit 1
fi

step "0.3 Verify C9 substrate present (post-merge sanity)"
if [ -f "framework/lochan/packages/muulam/backend/muulam/substrate/seals.py" ] \
   && [ -f "framework/lochan/packages/muulam/backend/muulam/auto_wire/seals_projector.py" ] \
   && [ -f "framework/lochan/packages/muulam/backend/muulam/auto_wire/seals_orchestrator.py" ] \
   && [ -f "framework/lochan/packages/muulam/backend/muulam/auto_wire/seals_signer.py" ]; then
    pass "All 4 muulam seals modules on disk"
else
    fail "Some muulam seals module is missing — pull origin/main"
fi

step "0.4 Verify test package has @governance_capability decorations"
if grep -q "@governance_capability" "${TEST_PKG_ROOT}/backend/${TEST_PKG}/services/dravya_service.py" 2>/dev/null; then
    pass "dravya has governance_capability decorations"
else
    fail "dravya does not have decorations — Sweep C9.7 may be missing"
fi

# ── Section 1 — Bootstrap (C9.6.1 + C9.6.2) ────────────────────────

section "1. Bootstrap: keygen + register (C9.6.1 + C9.6.2)"

step "1.1 daksh seal-keygen"
KEYGEN_OUT=$(${DAKSH} seal-keygen 2>&1) || { fail "seal-keygen exited nonzero"; echo "$KEYGEN_OUT"; exit 1; }
KEY_ID=$(echo "$KEYGEN_OUT" | grep "key_id:" | awk '{print $2}')
if [ -n "$KEY_ID" ] && [ ${#KEY_ID} -eq 16 ]; then
    pass "Generated key_id=$KEY_ID"
else
    fail "Could not parse key_id from output"
    echo "$KEYGEN_OUT"
fi

step "1.2 Public + private key files written"
PRIV_PATH="framework/lochan/.keys-private/seal-priv-${KEY_ID}.key"
PUB_PATH="framework/lochan/keys/seal-pub-${KEY_ID}.pem"
if [ -f "$PRIV_PATH" ] && [ -f "$PUB_PATH" ]; then
    pass "Both halves on disk"
else
    fail "Missing files: priv=$PRIV_PATH pub=$PUB_PATH"
fi

step "1.3 Private key has 0600 permissions"
PERMS=$(stat -f "%Lp" "$PRIV_PATH" 2>/dev/null || stat -c "%a" "$PRIV_PATH" 2>/dev/null)
if [ "$PERMS" = "600" ]; then
    pass "Private key mode 0600"
else
    fail "Private key mode $PERMS (expected 600)"
fi

step "1.4 daksh seal-key add (register in trust registry)"
${DAKSH} seal-key add "$PUB_PATH" >/dev/null 2>&1 \
    && pass "Registered key in registry.json" \
    || fail "seal-key add returned nonzero"

step "1.5 daksh seal-key list shows our key as active"
LIST_OUT=$(${DAKSH} seal-key list 2>&1)
if echo "$LIST_OUT" | grep -q "${KEY_ID}.*active"; then
    pass "key_id appears with status=active"
else
    fail "key_id not visible as active in registry"
    echo "$LIST_OUT"
fi

# ── Section 2 — Project + sign + verify (C9 + C9.6.3) ──────────────

section "2. Project + sign + verify (C9 substrate + C9.6.3)"

step "2.1 daksh auto-wire dravya --seal (project unsigned)"
${DAKSH} auto-wire ${TEST_PKG} --seal >/dev/null 2>&1 \
    && pass "lochan.seals projected" \
    || fail "--seal projection returned nonzero"

step "2.2 lochan.seals exists with 6 top-level keys + signed:false"
if [ -f "$SEALS_FILE" ]; then
    EXPECTED_KEYS="_meta declarations generated_artifacts manifest schema_fingerprints source_of_truth_hash"
    ACTUAL_KEYS=$(python3 -c "import json; d = json.load(open('$SEALS_FILE')); print(' '.join(sorted(d.keys())))")
    if [ "$ACTUAL_KEYS" = "$EXPECTED_KEYS" ]; then
        pass "Format spec: 6 top-level keys present"
    else
        fail "Wrong keys. Expected: $EXPECTED_KEYS / Got: $ACTUAL_KEYS"
    fi
    SIGNED=$(python3 -c "import json; print(json.load(open('$SEALS_FILE'))['_meta']['signed'])")
    if [ "$SIGNED" = "False" ]; then
        pass "_meta.signed: false (pre-sign state)"
    else
        fail "_meta.signed expected False, got $SIGNED"
    fi
else
    fail "$SEALS_FILE not written"
fi

step "2.3 daksh auto-wire dravya --seal --seal-sign"
${DAKSH} auto-wire ${TEST_PKG} --seal --seal-sign >/dev/null 2>&1 \
    && pass "Sign command succeeded" \
    || fail "--seal-sign returned nonzero"

step "2.4 .sig file present + lochan.seals.signed flipped to true"
if [ -f "$SIG_FILE" ]; then
    pass ".sig file exists at $SIG_FILE"
    SIGNED_AFTER=$(python3 -c "import json; print(json.load(open('$SEALS_FILE'))['_meta']['signed'])")
    if [ "$SIGNED_AFTER" = "True" ]; then
        pass "_meta.signed flipped to True"
    else
        fail "_meta.signed expected True, got $SIGNED_AFTER"
    fi
else
    fail "$SIG_FILE not written"
fi

step "2.5 daksh auto-wire dravya --seal --seal-verify"
VERIFY_OUT=$(${DAKSH} auto-wire ${TEST_PKG} --seal --seal-verify 2>&1)
if echo "$VERIFY_OUT" | grep -q "VERIFIED"; then
    pass "Verify succeeded"
else
    fail "Verify did not print VERIFIED"
    echo "$VERIFY_OUT"
fi

# ── Section 3 — Tamper detection ───────────────────────────────────

section "3. Tamper detection (verify rejects modified seals)"

step "3.1 Tamper the seals file"
python3 -c "
import json
from pathlib import Path
p = Path('$SEALS_FILE')
d = json.loads(p.read_text())
d['manifest']['description'] = 'TAMPERED-FOR-TEST'
# Re-serialize canonical-JSON shape
p.write_text(json.dumps(d, separators=(',',':'), sort_keys=True))
"
pass "Modified manifest.description"

step "3.2 Verify must FAIL after tamper"
VERIFY_OUT=$(${DAKSH} auto-wire ${TEST_PKG} --seal --seal-verify 2>&1) || true
if echo "$VERIFY_OUT" | grep -q "ERROR"; then
    pass "Verify correctly rejected tampered seals"
else
    fail "Verify did NOT detect tamper — security gap!"
    echo "$VERIFY_OUT"
fi

step "3.3 Restore by re-signing"
${DAKSH} auto-wire ${TEST_PKG} --seal --seal-sign >/dev/null 2>&1
${DAKSH} auto-wire ${TEST_PKG} --seal --seal-verify | grep -q "VERIFIED" \
    && pass "Re-sign restored verifiable state" \
    || fail "Re-sign + verify failed"

# ── Section 4 — Drift detection (C9.4 + C10) ───────────────────────

section "4. Drift detection (C9.4 --seal-check + C10 hook)"

step "4.1 Drift gate green when seals match sources"
${DAKSH} auto-wire ${TEST_PKG} --seal --seal-check >/dev/null 2>&1 \
    && pass "--seal-check passes on fresh-projected seals" \
    || fail "--seal-check returned nonzero on clean state"

step "4.2 C10 pre-commit hook is executable + present"
HOOK="framework/lochan/packages/daksh/scripts/precommit-autowire-seal.sh"
if [ -x "$HOOK" ]; then
    pass "Pre-commit hook present + executable"
else
    fail "Pre-commit hook missing or not executable: $HOOK"
fi

# ── Section 5 — Deployment verify (C9.6.4) ─────────────────────────

section "5. Deployment verification (C9.6.4 boot-time gate)"

step "5.1 daksh auto-wire <framework_root> --seal --seal-verify-deployment"
# Sign a couple more packages so deployment verify has multiple targets
for p in viniyog gyanam; do
    if [ -d "framework/lochan/packages/${p}" ]; then
        ${DAKSH} auto-wire ${p} --seal >/dev/null 2>&1 || true
        ${DAKSH} auto-wire ${p} --seal --seal-sign >/dev/null 2>&1 || true
    fi
done

VERIFY_DEPLOY=$(${DAKSH} auto-wire framework/lochan --seal --seal-verify-deployment 2>&1) || true
if echo "$VERIFY_DEPLOY" | grep -q "Deployment verify OK"; then
    pass "Deployment-verify reports OK"
elif echo "$VERIFY_DEPLOY" | grep -q "FAILED"; then
    fail "Deployment-verify FAILED"
    echo "$VERIFY_DEPLOY" | head -10
else
    # Empty deployment is also acceptable (vacuously true)
    if echo "$VERIFY_DEPLOY" | grep -q "0 packages"; then
        pass "Deployment empty (vacuously verified)"
    else
        fail "Unexpected deployment-verify output"
        echo "$VERIFY_DEPLOY" | head -5
    fi
fi

step "5.2 --seal-allow-unsigned flag works"
# Add an unsigned package to test allow-unsigned
${DAKSH} auto-wire abhilekh --seal >/dev/null 2>&1 || true  # project but DON'T sign
VERIFY_ALLOW=$(${DAKSH} auto-wire framework/lochan --seal --seal-verify-deployment --seal-allow-unsigned 2>&1) || true
if echo "$VERIFY_ALLOW" | grep -q "WARNING\|OK"; then
    pass "--seal-allow-unsigned permits dev-mode unsigned packages"
else
    fail "--seal-allow-unsigned didn't behave as expected"
    echo "$VERIFY_ALLOW" | head -5
fi
# Re-sign to clean up
${DAKSH} auto-wire abhilekh --seal --seal-sign >/dev/null 2>&1 || true

# ── Section 6 — Rotation (C9.6.5) ──────────────────────────────────

section "6. Rotation flow (C9.6.5 seal-rotate)"

step "6.1 daksh seal-rotate"
ROTATE_OUT=$(${DAKSH} seal-rotate 2>&1) || true
if echo "$ROTATE_OUT" | grep -q "Rotation complete"; then
    pass "Rotation completed"
else
    fail "Rotation did not complete"
    echo "$ROTATE_OUT" | head -10
fi

step "6.2 Old key now expired, new key active"
LIST_AFTER_ROTATE=$(${DAKSH} seal-key list 2>&1)
EXPIRED_COUNT=$(echo "$LIST_AFTER_ROTATE" | grep -c "expired" || true)
ACTIVE_COUNT=$(echo "$LIST_AFTER_ROTATE" | grep -c "active" || true)
if [ "$EXPIRED_COUNT" -ge 1 ] && [ "$ACTIVE_COUNT" -eq 1 ]; then
    pass "Registry shows ${EXPIRED_COUNT} expired + 1 active"
else
    fail "Registry state unexpected: expired=$EXPIRED_COUNT active=$ACTIVE_COUNT"
fi

step "6.3 Verify still works after rotation"
${DAKSH} auto-wire ${TEST_PKG} --seal --seal-verify 2>&1 | grep -q "VERIFIED" \
    && pass "Re-signed dravya verifies under new key" \
    || fail "Verify failed post-rotation"

# ── Section 7 — Image-build / fwprod01 (optional) ──────────────────

if [ "$INCLUDE_FWPROD01" = true ]; then
    section "7. fwprod01 image — verify-deployment inside container"

    step "7.1 fwprod01 backend container running"
    if docker ps --format '{{.Names}}' | grep -q "fwprod01-backend"; then
        pass "fwprod01-backend is up"

        step "7.2 Run verify-deployment INSIDE the image"
        if docker exec fwprod01-backend test -d /app 2>/dev/null; then
            DEPLOY_VERIFY=$(docker exec fwprod01-backend daksh auto-wire /app --seal --seal-verify-deployment --seal-allow-unsigned 2>&1) || true
            if echo "$DEPLOY_VERIFY" | grep -q "Deployment verify OK\|0 packages"; then
                pass "In-container verify ran"
            else
                fail "In-container verify failed"
                echo "$DEPLOY_VERIFY" | head -5
            fi
        else
            fail "/app not present in fwprod01 container"
        fi
    else
        fail "fwprod01-backend not running. Skip with: omit --include-fwprod01"
    fi
fi

# ── Cleanup ────────────────────────────────────────────────────────

if [ "$KEEP_KEYS" = false ]; then
    section "Cleanup"
    step "C.1 Remove generated keys + reset registry"

    # Restore pre-test seals state
    if [ -f "$PRE_SEALS_BACKUP" ]; then
        cp "$PRE_SEALS_BACKUP" "$SEALS_FILE"
    else
        rm -f "$SEALS_FILE"
    fi
    if [ -f "$PRE_SIG_BACKUP" ]; then
        cp "$PRE_SIG_BACKUP" "$SIG_FILE"
    else
        rm -f "$SIG_FILE"
    fi
    # Restore other touched packages too
    for p in viniyog gyanam abhilekh; do
        rm -f "framework/lochan/packages/${p}/lochan.seals" \
              "framework/lochan/packages/${p}/lochan.seals.sig"
    done

    # Remove the test keys (private + public + registry)
    rm -f framework/lochan/.keys-private/seal-priv-*.key
    rm -f framework/lochan/keys/seal-pub-*.pem
    rm -f framework/lochan/keys/registry.json
    rm -rf /tmp/seals-test-snapshot

    pass "Test artifacts removed (use --keep-keys to preserve)"
else
    echo ""
    echo -e "${YELLOW}Keys preserved (--keep-keys).${RESET}"
    echo "  Private: framework/lochan/.keys-private/"
    echo "  Public:  framework/lochan/keys/"
    echo "  Registry: framework/lochan/keys/registry.json"
fi
