#!/usr/bin/env bash
# watch-daksh-build.sh — pretty-print live progress of a `daksh build` run.
#
# Filters a daksh build log down to the milestones you actually care about:
# tier headers, framework package installs (one line per package), Docker
# image writes/tags, and any error/failure signature. Everything else (pip
# verbose output, layer copy progress, transfer percentages) is suppressed.
#
# Pairs with `daksh build` so you can run a full rebuild in the background
# and watch what's happening without scrolling through 30k lines of noise.
#
# Usage:
#
#   # 1. Kick off the build, teeing stdout+stderr to a log file:
#   daksh build --from 0 2>&1 | tee /tmp/daksh-build.log &
#
#   # 2. In another terminal (or this session), watch the milestones:
#   bash util/scripts/build/watch-daksh-build.sh
#
#   # Override the log path:
#   bash util/scripts/build/watch-daksh-build.sh /path/to/build.log
#
#   # Watch until the build exits (one-shot poll instead of live tail):
#   bash util/scripts/build/watch-daksh-build.sh --once
#
# What gets surfaced:
#   ✓ lochan-deps-backend built (108s)            ← tier completion
#   ✓ lochan-backend-base built (197s)
#   Successfully installed trishul-0.1.0          ← each framework package
#   Successfully installed muulam-0.1.0
#   #17 writing image sha256:...                  ← Docker image emit
#   #17 naming to docker.io/library/...
#   ── Tier 1: Building backend base image ──     ← daksh phase headers
#   ERROR: ...                                    ← any failure signature
#   FAILED ...
#   Traceback ...
#   exit code: N
#   error: cannot find ...
#
# Founder note (2026-05-12): captured from the daksh-build progress
# monitor I (Claude) was running interactively during the Phase 1 +
# move-PR end-to-end verification. The grep alternation below is the
# minimal-surface filter that proved useful — broad enough to never
# miss a crash, narrow enough that each line is signal.

set -euo pipefail

LOG_PATH="${1:-/tmp/daksh-build.log}"
MODE="follow"

if [[ "${1:-}" == "--once" ]]; then
  MODE="once"
  LOG_PATH="${2:-/tmp/daksh-build.log}"
fi

# Grep alternation: matches every progress and failure signature.
# IMPORTANT: this must remain broad on failure side (otherwise silence
# looks like success during a crashloop). Add new signatures here as
# new failure modes are observed — never narrow.
FILTER='Successfully installed |✓ lochan-|━━|── Tier [0-9]+:|writing image|naming to docker|ERROR:|FAILED|Traceback|exit code [1-9]|error:|cannot find|not found|elapsed'

if [[ ! -f "$LOG_PATH" ]]; then
  echo "watch-daksh-build: log not found at $LOG_PATH" >&2
  echo "                   start daksh build first: daksh build --from 0 2>&1 | tee $LOG_PATH" >&2
  exit 2
fi

if [[ "$MODE" == "once" ]]; then
  grep -E "$FILTER" "$LOG_PATH"
else
  # --line-buffered ensures every match shows up immediately, not after
  # pipe-buffer flushes (which can delay events by minutes on stale builds).
  tail -f "$LOG_PATH" | grep -E --line-buffered "$FILTER"
fi
