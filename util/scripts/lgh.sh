#!/usr/bin/env bash
# lgh — repo-explicit safe-gh wrapper for the Lochan workspace.
#
# Founder ratified 2026-06-09 post wrong-PR-target incident. Both agents
# on PRs #1187 (substream A) + #1188 (G-handoff) were briefed with
# `ssnukala/gyanam` as the PR target; the actual framework repo is
# `ssnukala/lochan` (the shell repo is `ssnukala/lochan-gyanam`). They
# corrected via `git ls-files` — robust, but the brief was the bug.
#
# Structural fix per [[feedback-no-direct-git-commands-use-lgit-wrapper]]:
# this wrapper takes the repo name as a REQUIRED explicit argument +
# resolves it against repos.json (same source as lgit) + injects
# --repo <org/repo> before forwarding to gh. gh's --repo flag makes
# cwd-default-repo behavior irrelevant — but only if it's actually
# passed. lgh forces it.
#
# Usage:
#   bash util/scripts/lgh.sh <org/repo> <gh-subcommand> [args...]
#
# Examples:
#   bash util/scripts/lgh.sh ssnukala/lochan pr list --state open
#   bash util/scripts/lgh.sh ssnukala/lochan pr create --title "..." --body "..."
#   bash util/scripts/lgh.sh ssnukala/lochan pr merge 1187 --squash
#   bash util/scripts/lgh.sh ssnukala/lochan-gyanam release create v1.0.0
#
# Recommended convenience alias (place in shell rc):
#   alias lgh='bash /Users/srinivasnukala/Dropbox/Sites/docker/gyanam/util/scripts/lgh.sh'
#
# Direct gh invocation by sessions + S0 is FORBIDDEN once this ships.
# The 3 exceptions (per CODING-STANDARDS §7 #7 extended):
#   (a) this script itself
#   (b) `gh auth` commands (no repo context; setup-only)
#   (c) `gh api` calls that explicitly URL-encode the org/repo path
#       (the caller MUST cite the org/repo in the URL — same explicit
#       discipline as lgh, just via the API path instead of --repo flag)
#
# Exit codes:
#   0   success (forwarded from gh)
#   2   USAGE              — missing/bad-shape arg
#   3   UNKNOWN_REPO       — <org/repo> not in repos.json + not in fallback map
#   4   STALE_BASE         — `pr merge` on a PR whose branch is BEHIND its
#                            base (W3 guard; override with --allow-stale)
#   *   forwarded from gh on failure
#
# Composes with:
#   - lgit.sh (same repos.json + fallback substrate; sibling discipline)
#   - CODING-STANDARDS §7 #7 (extended to forbid direct gh)
#   - feedback-no-direct-git-commands-use-lgit-wrapper (BINDING; rule
#     extended to cover gh as well — the wrong-repo failure mode is
#     symmetric to the wrong-cwd failure mode lgit was authored for)

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GYANAM_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPOS_JSON="$GYANAM_DIR/repos.json"

# ── Argument parsing ───────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  cat >&2 <<EOF
ERROR: <org/repo> argument required.

Usage: bash util/scripts/lgh.sh <org/repo> <gh-subcommand> [args...]

Examples:
  bash util/scripts/lgh.sh ssnukala/lochan pr list --state open
  bash util/scripts/lgh.sh ssnukala/lochan pr create --title "feat: ..." --body "..."
  bash util/scripts/lgh.sh ssnukala/lochan pr merge 1187 --squash

The first positional arg is REQUIRED — agents/sessions can no longer
default to cwd-inferred repo (the failure mode behind PRs #1187/#1188).
Per [[feedback-no-direct-git-commands-use-lgit-wrapper]] BINDING extended
to gh per 2026-06-09 ratify.
EOF
  exit 2
fi

REPO_ARG="$1"
shift

# Validate REPO_ARG shape: org/repo
if ! [[ "$REPO_ARG" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9._-]+$ ]]; then
  echo "ERROR: <org/repo> arg '$REPO_ARG' must match shape 'org/repo' (e.g., ssnukala/lochan)." >&2
  exit 2
fi

# At least one more arg expected (the gh subcommand)
if [[ $# -lt 1 ]]; then
  echo "ERROR: gh subcommand required after <org/repo>." >&2
  echo "Example: bash util/scripts/lgh.sh ssnukala/lochan pr list" >&2
  exit 2
fi

# ── Built-in fallback map (shared shape with lgit) ─────────────────────
#
# repos.json is the workspace deploy manifest (clones INTO gyanam tree).
# Two repos sit OUTSIDE that manifest but are part of the workflow:
#
#   1. ssnukala/lochan-gyanam — the umbrella repo itself
#   2. ssnukala/claude — the lochan-meta orchestration repo
#
# These match lgit's fallbacks (intentional — same source of truth).
resolve_fallback_repo() {
  case "$1" in
    ssnukala/lochan-gyanam) return 0 ;;
    ssnukala/claude)        return 0 ;;
    *)                      return 1 ;;
  esac
}

# ── repos.json lookup ──────────────────────────────────────────────────
#
# Same jq query shape as lgit.sh — extracts org/repo from the URL field
# of each entry under framework / mandi_common / mandi_domain. Unlike
# lgit, lgh doesn't need the local path — only confirmation that the
# org/repo is a known workspace repo. We return the path anyway for
# possible future use (e.g., warnings when cwd doesn't match the
# expected repo path).
resolve_repos_json() {
  local repo_arg="$1"
  [[ -f "$REPOS_JSON" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local match
  match="$(jq -r '
    [.framework[]?, .mandi_common[]?, .mandi_domain[]?]
    | .[]
    | select(.path? and .url?)
    | (.url
       | sub("^https://github.com/"; "")
       | sub("\\.git$"; "")
      ) + " " + .path
  ' "$REPOS_JSON" | awk -v r="$repo_arg" '$1 == r { print $2; exit }')"

  if [[ -n "$match" ]]; then
    printf '%s\n' "$GYANAM_DIR/$match"
    return 0
  fi
  return 1
}

# ── Resolve / verify repo is known ─────────────────────────────────────
EXPECTED_PATH=""
if EXPECTED_PATH="$(resolve_repos_json "$REPO_ARG")"; then
  :  # repos.json hit
elif resolve_fallback_repo "$REPO_ARG"; then
  :  # fallback hit (umbrella self OR claude); path not needed for gh
else
  cat >&2 <<EOF
ERROR: Unknown repo '$REPO_ARG'.

Searched:
  - $REPOS_JSON
  - lgh.sh built-in fallbacks (ssnukala/lochan-gyanam, ssnukala/claude)

If you meant the framework code (muulam/drasta/gyanam/daksh/etc.), the
canonical repo is 'ssnukala/lochan' (NOT 'ssnukala/gyanam'; the latter
does not exist). The 'gyanam' workspace shell is 'ssnukala/lochan-gyanam'.

If this is a new workspace repo, add it to repos.json. If it's an
external workflow repo, add it to resolve_fallback_repo() in lgh.sh.
EOF
  exit 3
fi

# ── Optional: warn if cwd doesn't match the requested repo ─────────────
#
# Non-blocking: gh's --repo flag makes cwd irrelevant, but a mismatched
# cwd is often a sign the caller meant a different repo. We warn but
# proceed — the explicit --repo flag is authoritative.
if [[ -n "$EXPECTED_PATH" && -d "$EXPECTED_PATH" ]]; then
  CWD_REAL="$(pwd -P)"
  EXPECTED_REAL="$(cd "$EXPECTED_PATH" && pwd -P)"
  case "$CWD_REAL" in
    "$EXPECTED_REAL"|"$EXPECTED_REAL"/*) : ;;  # cwd is inside expected repo path
    *)
      echo "NOTE: cwd ($CWD_REAL) is outside the expected path for $REPO_ARG ($EXPECTED_REAL). Proceeding with explicit GH_REPO env var." >&2
      ;;
  esac
fi

# ── Forward to gh with GH_REPO env var ─────────────────────────────────
#
# We set GH_REPO instead of injecting --repo because:
#
#   1. UNIVERSAL: GH_REPO works for EVERY gh subcommand that has a repo
#      context (gh pr, gh issue, gh release, gh api with {owner}/{repo}
#      placeholders, even `gh repo view` which takes a positional rather
#      than a --repo flag).
#
#   2. SUBCOMMAND-AGNOSTIC: injecting --repo would break for subcommands
#      that don't accept the flag (e.g., `gh repo view`, where the repo
#      is positional). GH_REPO sidesteps that entire class of bugs.
#
#   3. SUBSTITUTABLE IN URLS: `gh api repos/{owner}/{repo}/...` resolves
#      the placeholders from GH_REPO — so even raw API calls inherit the
#      explicit repo context.
#
# By setting GH_REPO here, we guarantee the wrong-cwd-implies-wrong-repo
# failure mode is structurally impossible — gh treats GH_REPO as
# authoritative when set, ignoring cwd-inferred remotes.

# ── W3: pre-merge stale-base guard (BINDING; 2026-06-23) ───────────────
#
# A PR branch cut BEFORE a since-merged PR silently REVERTS that PR's
# hunks on squash-merge. This caused a REAL regression this wave: §4.1
# re-added a `strict` param that §2.3 had already removed, because §4.1's
# branch was behind main and the squash re-applied the stale state.
#
# Detection consumes GitHub's OWN computed relationship (NOT hand-rolled
# rev-list math against a local clone). Two GitHub-authoritative signals,
# either of which means "behind the base":
#
#   1. mergeStateStatus == BEHIND — gh's canonical stale-base flag (the
#      same mergeState field auto-merge gates CLEAN on; see
#      feedback-clean-prs-merge-without-ratification). HOWEVER this value
#      is ONLY emitted when the base branch has protection rule "require
#      branches up to date before merging" enabled — which needs GitHub
#      Pro/public repos. On this workspace's private repos GitHub reports
#      a behind-but-non-conflicting branch as CLEAN, so BEHIND alone is
#      INERT here (verified 2026-06-23: seva PR behind:1 → CLEAN).
#
#   2. compare API behind_by > 0 — the repos/compare endpoint returns the
#      exact behind count GitHub computes for ANY repo regardless of plan
#      tier or branch protection. This is the load-bearing signal for the
#      §4.1 regression class on this workspace. Still GitHub's own count,
#      not local rev-list math — satisfies "don't hand-roll".
#
# We refuse on EITHER signal; --allow-stale is the explicit, recorded
# override (per long-term-not-bandaid: the override is named so the
# contrast is visible, not silent).
#
# Scope: this guard ONLY refuses the behind-base case of `pr merge`.
# Every other invocation (any other subcommand, a non-behind PR) is
# untouched passthrough.
guard_args=("$@")
is_pr_merge=0
saw_pr=0
for a in "${guard_args[@]}"; do
  if [[ "$a" == "pr" ]]; then
    saw_pr=1
  elif [[ "$saw_pr" -eq 1 && "$a" == "merge" ]]; then
    is_pr_merge=1
    break
  fi
done

if [[ "$is_pr_merge" -eq 1 ]]; then
  # Strip --allow-stale from the forwarded args (gh doesn't know it) and
  # record whether the explicit override was requested.
  allow_stale=0
  filtered_args=()
  for a in "${guard_args[@]}"; do
    if [[ "$a" == "--allow-stale" ]]; then
      allow_stale=1
    else
      filtered_args+=("$a")
    fi
  done
  set -- "${filtered_args[@]}"

  if [[ "$allow_stale" -eq 0 ]]; then
    # Extract the PR number: first numeric arg after `merge`.
    pr_number=""
    saw_merge=0
    for a in "$@"; do
      if [[ "$saw_merge" -eq 1 && "$a" =~ ^[0-9]+$ ]]; then
        pr_number="$a"
        break
      fi
      [[ "$a" == "merge" ]] && saw_merge=1
    done

    if [[ -n "$pr_number" ]]; then
      # One PR query gets both the fast-path flag and the base/head refs.
      pr_meta="$(env GH_REPO="$REPO_ARG" gh pr view "$pr_number" \
        --json mergeStateStatus,baseRefName,headRefName 2>/dev/null || true)"
      merge_state="$(printf '%s' "$pr_meta" | jq -r '.mergeStateStatus // empty' 2>/dev/null || true)"
      base_ref="$(printf '%s' "$pr_meta" | jq -r '.baseRefName // empty' 2>/dev/null || true)"
      head_ref="$(printf '%s' "$pr_meta" | jq -r '.headRefName // empty' 2>/dev/null || true)"

      is_behind=0
      if [[ "$merge_state" == "BEHIND" ]]; then
        is_behind=1
      elif [[ -n "$base_ref" && -n "$head_ref" ]]; then
        # compare API is base...head; behind_by = commits on base the head lacks.
        behind_by="$(env GH_REPO="$REPO_ARG" gh api \
          "repos/$REPO_ARG/compare/$base_ref...$head_ref" \
          -q '.behind_by' 2>/dev/null || true)"
        if [[ "$behind_by" =~ ^[0-9]+$ && "$behind_by" -gt 0 ]]; then
          is_behind=1
        fi
      fi

      if [[ "$is_behind" -eq 1 ]]; then
        cat >&2 <<EOF
ERROR: PR #$pr_number is BEHIND its base branch — merging would silently
revert already-merged work (the §4.1 regression class: a stale branch
re-applies hunks a since-merged PR removed).

Rebase the branch onto current main first:
  bash util/scripts/lgit.sh $REPO_ARG <chunk> rebase origin/main

Then re-run the merge. To override (explicit, recorded), pass --allow-stale:
  bash util/scripts/lgh.sh $REPO_ARG pr merge $pr_number --allow-stale [--squash ...]
EOF
        exit 4
      fi
    fi
  fi
fi
# ── end W3 guard ───────────────────────────────────────────────────────

exec env GH_REPO="$REPO_ARG" gh "$@"
