#!/usr/bin/env bash
# strict-scoreboard.sh — per-package strict-mode score table + 3-bucket gap analysis.
#
# Captures the ad-hoc package-scoring sweep S0 ran 2026-06-11 (founder: "capture
# in util/scripts so we reuse"). Thin wrapper over the canonical `daksh evolve
# --all --strict` — does NOT reimplement scoring. The durable CLI home is
# `daksh report strict-scoreboard` (SCORE-CMD); this script is the runnable
# capture + what that subcommand shells to / mirrors.
#
# Usage:
#   bash util/scripts/build/strict-scoreboard.sh                 # all packages, terminal table
#   bash util/scripts/build/strict-scoreboard.sh --json          # raw json (for tooling)
#   bash util/scripts/build/strict-scoreboard.sh --buckets       # + 3-bucket gap analysis
#   bash util/scripts/build/strict-scoreboard.sh <pkg>           # single package
#
# Buckets (the analysis layer beyond raw evolve output):
#   (A) STALE/WRONG CHECK  — the check is the bug (e.g. autowire-*-stale demanding
#                            gitignored __generated__ files). Fix the check.
#   (B) REAL VIOLATION     — code doesn't conform; fix (or DELETE per pre-release).
#   (C) GRAY               — needs per-package review.
set -euo pipefail

GYANAM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
VENV="$GYANAM_ROOT/framework/lochan/.venv/bin/activate"
DAKSH="$GYANAM_ROOT/framework/lochan/packages/daksh/daksh-cli"

MODE="table"; PKG=""
for arg in "$@"; do
  case "$arg" in
    --json)    MODE="json" ;;
    --buckets) MODE="buckets" ;;
    --*)       echo "unknown flag: $arg" >&2; exit 2 ;;
    *)         PKG="$arg" ;;
  esac
done

# shellcheck disable=SC1090
source "$VENV"

# The canonical sweep — reuse, do not reimplement. --parallel for speed across all.
report_fmt="terminal"; [ "$MODE" = "json" ] && report_fmt="json"
if [ -n "$PKG" ]; then
  "$DAKSH" evolve --strict --report "$report_fmt" "$PKG"
else
  "$DAKSH" evolve --all --strict --parallel --report "$report_fmt"
fi

if [ "$MODE" = "buckets" ]; then
  cat <<'EOF'

──────────────────────────────────────────────────────────────────────
3-BUCKET GAP ANALYSIS (manual classification key — see findings above)
──────────────────────────────────────────────────────────────────────
(A) STALE/WRONG CHECK — the check is the bug, fix the CHECK:
      autowire-{blocks,canvas,events,routes,types,widgets}-stale
        → demand committed __generated__/*.{ts,tsx,json} which are gitignored
          BY DESIGN (build-time output). Retire/rescope. (~16% of gap, all pkgs.)
(B) REAL VIOLATION — code doesn't conform; pre-release = DELETE not deprecate:
      backward-compat / no-deprecation-markers / no-backward-compat-residue
        → DELETE the old-name paths (next release = FIRST release; nothing to
          be compat with). Keep the DETECTING checks — delete the violations.
      callback-into-parent / default-vs-named-export / testing-wave-required
        → real conformance fixes.
(C) GRAY — per-package review: pre-deploy / barrel-re-export / taxonomy.

Path to 100: fix (A) checks → +6-9 pts/pkg free; DELETE (B) backward-compat
→ ~56% of real findings vanish; then (C) long tail per package.
──────────────────────────────────────────────────────────────────────
EOF
fi
