#!/usr/bin/env bash
# probe-bi-provider.sh — deterministic probe of the tarkan BI provider seam.
#
# Reproduces the root cause of the iteration-4 staging failure ("No
# simulation provider for domain 'longterm'. Available: ['demo']") WITHOUT
# depending on chat intent resolution or an MCP client. The failure class
# (GAP-17): the image bundles a simulation_provider.py whose import is
# broken (pre-#92: dead `rupayan.providers`), the boot autowire's
# try_import SILENTLY swallows it, the provider never registers, and
# tk_bi_query's registry lookup raises at tarkan/registry.py.
#
# The probe is the LOUD version of exactly that seam, inside the app's
# backend container (the shipped image + venv):
#   1. import <domain>.simulation_provider  → surfaces the exact broken
#      import the autowire swallows (stale image = ModuleNotFoundError HERE)
#   2. resolve the provider the same two ways wire_simulation_provider does
#      (get_provider() factory, else SimulationDataProvider subclass)
#   3. register + resolve through the real SimDataRegistry
#
# PASS = import + provider resolution + registry round-trip all good.
# FAIL = the exact exception, printed (not swallowed).
#
# Scope note: a fresh `python -c` process has an EMPTY registry (boot wiring
# ran in the uvicorn worker, not here) — so the probe re-drives the wiring
# seam itself rather than reading another process's memory. get_metrics()
# execution (async + db session) is validated end-to-end over MCP (Desktop
# iteration probes); this probe pins the registration seam deterministically.
#
# Runs inside the app's backend container via `daksh exec` (wrapper-first —
# no raw docker exec). Reusable before/after any deploy; pairs with the
# Phase 2.5 staleness gate in scripts/deploy-lochan.sh (§PKG-STALENESS-GATE).
#
# Usage:
#   util/scripts/probe-bi-provider.sh [APP] [DOMAIN]
#     APP     default longterm01
#     DOMAIN  default longterm

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# env-overridable so the probe also runs from a worktree/CI checkout that has
# no sibling framework clone; default = the primary workspace this file is in.
GYANAM_DIR="${GYANAM_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
DAKSH="$GYANAM_DIR/framework/lochan/packages/daksh/daksh-cli"
[[ -x "$DAKSH" ]] || { echo "FAIL: daksh-cli not found at $DAKSH" >&2; exit 1; }

APP="${1:-longterm01}"
DOMAIN="${2:-longterm}"

echo "── probe-bi-provider: app=$APP domain=$DOMAIN ──"

"$DAKSH" exec "$APP" python -c "
import importlib, sys, traceback
from tarkan.providers import SimulationDataProvider
from tarkan.registry import SimDataRegistry

# 1. the import the boot autowire silently swallows — done LOUDLY here
try:
    mod = importlib.import_module('$DOMAIN.simulation_provider')
except Exception as e:
    # terminal exception FIRST (one line) — daksh exec truncates long output,
    # and the root cause must survive truncation
    print(f'FAIL: $DOMAIN.simulation_provider does not import (the GAP-17 stale-image class): {type(e).__name__}: {e}')
    traceback.print_exc()
    sys.exit(1)
print('import $DOMAIN.simulation_provider: ok')

# 2. resolve the provider exactly as muulam wire_simulation_provider does
provider = None
getter = getattr(mod, 'get_provider', None)
if callable(getter):
    provider = getter()
else:
    for name in dir(mod):
        obj = getattr(mod, name)
        if (isinstance(obj, type) and issubclass(obj, SimulationDataProvider)
                and obj is not SimulationDataProvider and not name.startswith('_')):
            provider = obj()
            break
if provider is None:
    print('FAIL: no get_provider() factory or SimulationDataProvider subclass in module')
    sys.exit(1)
print(f'provider: {type(provider).__module__}.{type(provider).__name__} (domain={provider.domain})')
if provider.domain != '$DOMAIN':
    print(f'FAIL: provider.domain {provider.domain!r} != requested {\"$DOMAIN\"!r}')
    sys.exit(1)

# 3. real registry round-trip
SimDataRegistry.register(provider)
resolved = SimDataRegistry.get_provider('$DOMAIN')
if resolved is not provider:
    print(f'FAIL: registry returned a different instance: {resolved!r}')
    sys.exit(1)
print(f'registry round-trip: ok ({sorted(SimDataRegistry._providers.keys())})')
print(f'capabilities: {sorted(provider.capabilities)}')
print('PASS')
"
