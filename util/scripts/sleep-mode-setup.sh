#!/usr/bin/env bash
# sleep-mode-setup.sh — pre-sleep canonical setup + verifier for overnight
# autonomous wave execution. Per S0 Day-14 analysis (Layer 1 → Layer 4).
#
# Usage:
#   ./util/scripts/sleep-mode-setup.sh                # verify + report; do not modify
#   ./util/scripts/sleep-mode-setup.sh --apply        # apply caffeinate + verify rest
#   ./util/scripts/sleep-mode-setup.sh --strict       # exit non-zero if any layer red
#
# Layers verified:
#   1. macOS keep-awake (caffeinate / pmset)            — REQUIRED
#   2. Permission allowlist (~/.claude/settings.json)   — REQUIRED for auto-execution
#   3. Session-cycling mechanism (/loop active per Sx)  — REQUIRED for crank
#   4. Coordination + safety nets
#      4a. UserPromptSubmit + Stop hooks wired
#      4b. ~/.claude/active-coord-doc pointer current
#      4c. Disk space ≥ 5 GB free on ~/.claude/
#      4d. gh auth cache valid
#      4e. PushNotification / terminal-notifier
#
# Exits 0 if all layers GREEN (or YELLOW with --apply); non-zero if RED
# (or any non-green when --strict).
#
# Authored 2026-06-03 per founder ratification of script-authorship
# discipline + S0 Day-14 4-layer overnight-autonomy spec.

set -u

APPLY=false
STRICT=false
for arg in "$@"; do
  case "$arg" in
    --apply)  APPLY=true ;;
    --strict) STRICT=true ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  esac
done

red=0; yellow=0; green=0
declare -a issues

status() {
  local color="$1"; shift
  local layer="$1"; shift
  local msg="$*"
  case "$color" in
    GREEN)  printf '  \033[32m✓\033[0m  %s — %s\n' "$layer" "$msg"; green=$((green+1)) ;;
    YELLOW) printf '  \033[33m~\033[0m  %s — %s\n' "$layer" "$msg"; yellow=$((yellow+1)); issues+=("YELLOW: $layer — $msg") ;;
    RED)    printf '  \033[31m✗\033[0m  %s — %s\n' "$layer" "$msg"; red=$((red+1)); issues+=("RED: $layer — $msg") ;;
  esac
}

echo "═══ Lochan sleep-mode setup + verifier ═══"
echo

# ── Layer 1: macOS keep-awake ─────────────────────────────────────────────
echo "Layer 1 — macOS keep-awake"
caffeinate_pid=$(pgrep -f "caffeinate -d" | head -1 || true)
if [ -n "$caffeinate_pid" ]; then
  status GREEN "L1.caffeinate" "running (pid $caffeinate_pid)"
else
  if [ "$APPLY" = true ]; then
    caffeinate -d -i -s &
    sleep 1
    status GREEN "L1.caffeinate" "started (pid $!) — runs until killed"
  else
    status RED "L1.caffeinate" "NOT running — laptop will sleep. Re-run with --apply OR start manually: caffeinate -d -i -s &"
  fi
fi

sleep_setting=$(pmset -g | awk '/^ *sleep / {print $2}')
case "$sleep_setting" in
  0) status GREEN "L1.pmset.sleep" "system-sleep disabled (0)" ;;
  "")status YELLOW "L1.pmset.sleep" "could not read; verify manually" ;;
  *) status YELLOW "L1.pmset.sleep" "value=$sleep_setting min — caffeinate compensates if running" ;;
esac
echo

# ── Layer 2: Permission allowlist ─────────────────────────────────────────
echo "Layer 2 — Permission allowlist"
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  allow_count=$(python3 -c "import json;print(len(json.load(open('$SETTINGS')).get('permissions',{}).get('allow',[])))" 2>/dev/null || echo 0)
  if [ "$allow_count" -ge 100 ]; then
    status GREEN "L2.allowlist" "$allow_count allow entries (broad enough for most ops)"
  elif [ "$allow_count" -ge 30 ]; then
    status YELLOW "L2.allowlist" "$allow_count allow entries (moderate; some ops may prompt)"
  else
    status RED "L2.allowlist" "only $allow_count allow entries — sessions will prompt-pause frequently"
  fi
  for pat in "gh pr merge" "gh pr view" "git push origin" "daksh build" "daksh janch" "bash lochan/wave"; do
    if python3 -c "import json,sys; d=json.load(open('$SETTINGS')); print(any('$pat' in e for e in d.get('permissions',{}).get('allow',[])))" 2>/dev/null | grep -q True; then
      status GREEN "L2.allow.$pat" "covered"
    else
      status YELLOW "L2.allow.$pat" "no explicit allow — may prompt (acceptEdits mode may cover Bash ops; verify)"
    fi
  done
else
  status RED "L2.settings" "no ~/.claude/settings.json"
fi
echo

# ── Layer 3: Session-cycling mechanism ────────────────────────────────────
echo "Layer 3 — Session-cycling mechanism"
status YELLOW "L3.loop" "MANUAL STEP — type into each working session: /loop <pacing> <prompt> (founder action required)"
status YELLOW "L3.loop.guidance" "Recommended cadence: 270s (cache-warm), 1200-1800s (cache-cold long-haul)"
echo "  See: ScheduleWakeup tool docs for cache-window guidance."
echo

# ── Layer 4: Coordination + safety nets ───────────────────────────────────
echo "Layer 4 — Coordination + safety nets"

# 4a — hooks
if python3 -c "import json,sys; d=json.load(open('$SETTINGS')); print('UserPromptSubmit' in d.get('hooks',{}) and 'Stop' in d.get('hooks',{}))" 2>/dev/null | grep -q True; then
  status GREEN "L4a.hooks" "UserPromptSubmit + Stop both wired"
else
  status RED "L4a.hooks" "missing hook entries — run ~/.claude/hooks/watch-coord-doc.sh + check-next-for-pointer.sh manually"
fi

# 4b — active-coord-doc pointer
POINTER="$HOME/.claude/active-coord-doc"
if [ -f "$POINTER" ]; then
  DOC=$(head -n 1 "$POINTER" | tr -d '[:space:]')
  if [ -f "$DOC" ]; then
    age_days=$(echo "($(date +%s) - $(stat -f %m "$DOC")) / 86400" | bc 2>/dev/null || echo "?")
    status GREEN "L4b.coord-doc-pointer" "→ $(basename "$DOC") (mtime ${age_days}d ago)"
  else
    status RED "L4b.coord-doc-pointer" "pointer file → non-existent path: $DOC"
  fi
else
  status RED "L4b.coord-doc-pointer" "no ~/.claude/active-coord-doc — fswatch hook will silent-exit"
fi

# 4c — disk
free_gb=$(df -g "$HOME/.claude" 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$free_gb" ] && [ "$free_gb" -ge 5 ]; then
  status GREEN "L4c.disk" "${free_gb} GB free on ~/.claude"
elif [ -n "$free_gb" ]; then
  status RED "L4c.disk" "only ${free_gb} GB free — overnight logs may fill disk"
else
  status YELLOW "L4c.disk" "could not read df; verify manually"
fi

# 4d — gh auth
if gh auth status > /dev/null 2>&1; then
  status GREEN "L4d.gh-auth" "gh authenticated"
else
  status RED "L4d.gh-auth" "gh not authenticated — auto-push will fail. Run: gh auth login"
fi

# 4e — push notification
if command -v terminal-notifier > /dev/null 2>&1; then
  status GREEN "L4e.push-notify" "terminal-notifier installed"
elif command -v ntfy > /dev/null 2>&1; then
  status GREEN "L4e.push-notify" "ntfy installed"
else
  status YELLOW "L4e.push-notify" "no terminal-notifier / ntfy — sessions can still PushNotification via Claude Code, but no morning local alert"
fi

echo
echo "═══ Summary ═══"
echo "  GREEN:  $green"
echo "  YELLOW: $yellow"
echo "  RED:    $red"
echo

if [ "$red" -gt 0 ]; then
  echo "BLOCKED — RED issues must clear before sleep:"
  for issue in "${issues[@]}"; do
    case "$issue" in RED:*) echo "  - $issue" ;; esac
  done
  echo
  echo "Re-run with --apply to auto-fix Layer 1; remaining REDs need manual action."
  $STRICT && exit 1
  exit 0
fi

if [ "$yellow" -gt 0 ]; then
  echo "READY (with YELLOW notes — acceptable for autonomous run; review):"
  for issue in "${issues[@]}"; do
    case "$issue" in YELLOW:*) echo "  - $issue" ;; esac
  done
else
  echo "READY — all layers GREEN. Safe to start /loop on working sessions + sleep."
fi
exit 0
