#!/usr/bin/env bash
# wave-runner.sh — canonical entry script for launching a Lochan overnight
# wave. Takes a wave-plan markdown doc + a mode flag; prepares the runtime
# (sets active-coord-doc pointer; runs sleep-mode-setup.sh; emits paste-
# ready /loop prompts OR a Workflow invocation hint).
#
# Modes:
#   --mode draft     Print the /loop prompts from plan §4 (Mode B-draft);
#                    founder/S0 pastes them into each window manually.
#                    Auto-merge OFF; sessions push DRAFT PRs.
#   --mode workflow  Print the Claude Code invocation for the saved
#                    `lochan-overnight-wave` Workflow (Mode C; fan-out
#                    via sub-agents with worktree isolation).
#   --mode dry-run   Verify layers + print plan summary; do NOT emit
#                    launch commands.
#
# Usage:
#   ./util/scripts/wave-runner.sh <plan-doc.md>                           # default: dry-run
#   ./util/scripts/wave-runner.sh <plan-doc.md> --mode draft              # Mode B-draft
#   ./util/scripts/wave-runner.sh <plan-doc.md> --mode workflow           # Mode C
#   ./util/scripts/wave-runner.sh <plan-doc.md> --mode draft --apply      # also caffeinate
#
# Authored 2026-06-03 per founder script-authorship discipline +
# claude-expert Mode A/B/C analysis.

set -u

PLAN=""
MODE="dry-run"
APPLY=false

for arg in "$@"; do
  case "$arg" in
    --mode)         shift; MODE="${1:-dry-run}"; shift ;;
    --mode=*)       MODE="${arg#--mode=}" ;;
    --apply)        APPLY=true ;;
    -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
    *)
      if [ -z "$PLAN" ]; then PLAN="$arg"; fi
      ;;
  esac
done

if [ -z "$PLAN" ] || [ ! -f "$PLAN" ]; then
  echo "ERROR: plan doc required as first arg (must exist)." >&2
  echo "Usage: $0 <plan-doc.md> [--mode draft|workflow|dry-run] [--apply]" >&2
  exit 1
fi

PLAN_ABS=$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")

echo "═══ Lochan wave-runner ═══"
echo "  Plan:  $PLAN_ABS"
echo "  Mode:  $MODE"
echo "  Apply: $APPLY"
echo

# ── Step 1: Verify the plan doc shape ─────────────────────────────────────
echo "Step 1 — Verify plan structure"
for section in "§1" "§2" "§3" "§4" "§7" "§9"; do
  if grep -q "^## $section" "$PLAN" || grep -q "## $section\." "$PLAN"; then
    echo "  ✓ $section present"
  else
    echo "  ⚠ $section missing — plan may be malformed (skip if non-standard)"
  fi
done
echo

# ── Step 2: Set the active-coord-doc pointer ─────────────────────────────
echo "Step 2 — active-coord-doc pointer"
POINTER="$HOME/.claude/active-coord-doc"
if [ "$MODE" != "dry-run" ]; then
  printf '%s\n' "$PLAN_ABS" > "$POINTER"
  echo "  ✓ Pointer set: $POINTER → $PLAN_ABS"
  echo "    (UserPromptSubmit hook will now diff this plan; sessions auto-receive coord changes)"
else
  echo "  (dry-run; not modifying pointer)"
fi
echo

# ── Step 3: Run sleep-mode-setup.sh verifier ─────────────────────────────
echo "Step 3 — Layer-1-through-Layer-4 verify"
SETUP="$(dirname "$0")/sleep-mode-setup.sh"
if [ -x "$SETUP" ]; then
  if [ "$APPLY" = true ]; then
    bash "$SETUP" --apply
  else
    bash "$SETUP"
  fi
  echo "  (re-run with --apply to auto-start caffeinate; remaining REDs need manual action)"
else
  echo "  ⚠ sleep-mode-setup.sh not found at $SETUP — verify manually"
fi
echo

# ── Step 4: Emit mode-specific launch instructions ───────────────────────
echo "Step 4 — Launch instructions"
case "$MODE" in
  dry-run)
    echo "  (dry-run; no launch emitted)"
    echo "  Re-run with --mode draft   to emit /loop prompts for paste-launch (Mode B-draft)"
    echo "  Re-run with --mode workflow to emit Workflow invocation (Mode C)"
    ;;
  draft)
    echo "  Mode B-draft launch — paste each /loop block from plan §4 into the corresponding window."
    echo "  Recommended paste order: S0 FIRST (watcher live before workers), then S1-S5."
    echo
    echo "  ─── Extracting /loop blocks from plan §4 ───"
    # Extract each fenced block under §4 that begins with /loop
    awk '/^## §4\./,/^## §5\./' "$PLAN" | awk '
      /^```$/ {if (in_block) {in_block=0; print "─── end block ───"; print ""} next}
      /^### / {print "[" $0 "]"; next}
      /^```/ {in_block=1; print "─── paste this block ───"; next}
      in_block {print}
    '
    echo
    echo "  After all /loops are running:"
    echo "    1. Confirm caffeinate is active (pgrep -f \"caffeinate -d\")"
    echo "    2. Sleep."
    echo "    3. Morning: read coord §5 (PR disposition) + §6 (pending decisions); ratify + merge."
    ;;
  workflow)
    echo "  Mode C — invoke the saved Workflow inside a Claude Code session:"
    echo
    echo "  ─── paste into a Claude Code window ───"
    echo "  Use the Workflow tool with name='lochan-overnight-wave'"
    echo "  args = { plan: \"$PLAN_ABS\" }"
    echo "  ─── end ───"
    echo
    echo "  The Workflow fans out N parallel agents (one per plan §3 task) with"
    echo "  worktree isolation. PushNotify on BLOCK. Returns wave summary on completion."
    echo
    echo "  Saved Workflow location: ~/.claude/workflows/lochan-overnight-wave.js"
    ;;
  *)
    echo "  ERROR: unknown mode '$MODE'. Valid: draft | workflow | dry-run" >&2
    exit 1
    ;;
esac

echo
echo "═══ wave-runner complete ═══"
exit 0
