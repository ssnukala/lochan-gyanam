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
exec env GH_REPO="$REPO_ARG" gh "$@"
