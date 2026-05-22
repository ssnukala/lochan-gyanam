#!/bin/bash
# Reclaim Docker disk space on localhost.
# Usage: ./util/scripts/docker-cleanup.sh [--safe|--standard|--aggressive] [--yes]
#
# Modes:
#   --safe        Stopped containers + dangling images + build cache (default)
#   --standard    Above + ALL unused images (not referenced by any container)
#   --aggressive  Above + unused volumes (DATA LOSS for detached DB volumes)
#
# --yes skips confirmations.
#
# Always preserves: running containers, images they reference, attached volumes.

set -euo pipefail

MODE="safe"
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --safe)       MODE="safe" ;;
        --standard)   MODE="standard" ;;
        --aggressive) MODE="aggressive" ;;
        --yes|-y)     ASSUME_YES=1 ;;
        -h|--help)    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

confirm() {
    [[ "$ASSUME_YES" -eq 1 ]] && return 0
    read -r -p "$1 [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# Print only the summary line ("Total reclaimed space: ...") from prune output.
# Suppresses the per-entry list which is huge and pointless.
run_prune() {
    local label="$1"; shift
    echo "[$label] running: $*"
    "$@" 2>&1 | grep -E "^(Total reclaimed|Deleted|error)" | tail -5 || true
    echo
}

echo "===== Disk before ====="
df -h /System/Volumes/Data | tail -1
echo
echo "===== Cleanup mode: $MODE ====="
echo

# Phase 1: stopped/exited/created/dead containers (server-side, no enumeration)
if confirm "[phase 1] Prune stopped containers?"; then
    run_prune "phase 1" docker container prune -f
fi

# Phase 2: dangling images
if confirm "[phase 2] Prune dangling images?"; then
    run_prune "phase 2" docker image prune -f
fi

# Phase 3: build cache (biggest reclaim; safe — only affects future build speed)
if confirm "[phase 3] Prune ALL build cache?"; then
    run_prune "phase 3" docker builder prune -af
fi

# Phase 4: unused images (standard + aggressive)
if [[ "$MODE" != "safe" ]]; then
    if confirm "[phase 4] Prune ALL unused images (need re-pull/rebuild)?"; then
        run_prune "phase 4" docker image prune -af
    fi
fi

# Phase 5: unused volumes (aggressive only)
if [[ "$MODE" == "aggressive" ]]; then
    if confirm "[phase 5] Prune unused volumes (DATA LOSS risk)?"; then
        run_prune "phase 5" docker volume prune -f
    fi
fi

echo "===== Disk after ====="
df -h /System/Volumes/Data | tail -1
echo "Done."
