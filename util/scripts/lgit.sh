#!/usr/bin/env bash
# lgit — repo-explicit safe-git wrapper for the Lochan workspace.
#
# Founder ratified 2026-05-24 PM post wrong-cwd-incident (chained `cd … &&
# git reset --hard` blew away uncommitted edits when cwd drifted across
# Bash batches). Structural fix per
# `[[feedback-no-direct-git-commands-use-lgit-wrapper]]`: instead of
# requiring every session to verify `pwd && git remote -v` before each
# destructive op, this wrapper takes the repo name as a REQUIRED
# explicit argument + resolves the canonical path itself + sanity-checks
# the remote URL before forwarding to git.
#
# Usage:
#   bash util/scripts/lgit.sh <org/repo> <git-subcommand> [args...]
#
# Examples:
#   bash util/scripts/lgit.sh ssnukala/lochan status
#   bash util/scripts/lgit.sh ssnukala/lochan-gyanam log --oneline -5
#   bash util/scripts/lgit.sh ssnukala/claude commit -m "docs(coord): closure"
#   bash util/scripts/lgit.sh ssnukala/lochan-pestpro reset --hard origin/main
#
# Recommended convenience alias (place in shell rc):
#   alias lgit='bash /Users/srinivasnukala/Dropbox/Sites/docker/gyanam/util/scripts/lgit.sh'
#
# Failure modes (each prints a clear error to stderr + exits non-zero):
#   1. <org/repo> arg missing                            → exit 2 (USAGE)
#   2. <org/repo> not in canonical map                    → exit 3 (UNKNOWN_REPO)
#   3. canonical path missing on disk                     → exit 4 (PATH_MISSING)
#   4. remote URL at canonical path doesn't match request → exit 5 (REMOTE_MISMATCH)
#   (git's own exit code is forwarded on success/git-error)
#
# Direct git invocation by sessions + S0 is FORBIDDEN once this ships.
# The 3 exceptions (per CODING-STANDARDS §7b):
#   (a) this script itself
#   (b) initial workspace bootstrap `git clone`
#   (c) `gh pr <op>` commands (gh is NOT git; --repo flag makes cwd irrelevant)
set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GYANAM_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPOS_JSON="$GYANAM_DIR/repos.json"

# ── Argument parsing ───────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  cat >&2 <<EOF
ERROR: <org/repo> argument required.

Usage: bash util/scripts/lgit.sh <org/repo> <git-subcommand> [args...]

Examples:
  bash util/scripts/lgit.sh ssnukala/lochan status
  bash util/scripts/lgit.sh ssnukala/claude commit -m "msg"

The first positional arg is REQUIRED — sessions can no longer drift via
chained-cd batches. Per [[feedback-no-direct-git-commands-use-lgit-wrapper]].
EOF
  exit 2
fi

REPO_ARG="$1"
shift

# Validate REPO_ARG shape: org/repo (lowercase + digits + dashes + underscores)
if ! [[ "$REPO_ARG" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9._-]+$ ]]; then
  echo "ERROR: <org/repo> arg '$REPO_ARG' must match shape 'org/repo' (e.g., ssnukala/lochan)." >&2
  exit 2
fi

# ── Built-in fallback map (repos NOT listed in repos.json) ─────────────
#
# repos.json is the workspace deploy manifest — it lists repos the
# deploy script clones INTO the gyanam tree. Two repos sit OUTSIDE that
# manifest but are part of the developer workflow:
#
#   1. ssnukala/lochan-gyanam — the umbrella repo itself (where this
#      wrapper lives); deploy script doesn't clone "itself"
#   2. ssnukala/claude — the lochan-meta orchestration repo at
#      /docker/claude (separate workspace; carries plans + coord docs +
#      profiles + memory rules)
#
# These are hard-coded fallbacks per the founder's incident-driven
# spec. New external repos require a one-line entry here (no schema
# extension to repos.json which the deploy script depends on).
resolve_fallback_path() {
  case "$1" in
    ssnukala/lochan-gyanam)
      printf '%s\n' "$GYANAM_DIR"
      ;;
    ssnukala/claude)
      printf '%s\n' "/Users/srinivasnukala/Dropbox/Sites/docker/claude"
      ;;
    *)
      return 1
      ;;
  esac
}

# ── repos.json lookup ──────────────────────────────────────────────────
#
# repos.json schema (canonical, per /docker/gyanam/repos.json):
#   {
#     "framework":    [ { "path": "<rel-path>", "url": "<git-url>" }, ... ],
#     "mandi_common": [ ... same shape ... ],
#     "mandi_domain": [ ... same shape ... ]
#   }
#
# A URL like https://github.com/ssnukala/lochan-pestpro.git resolves to
# org/repo = "ssnukala/lochan-pestpro" via strip-prefix + strip-.git.
resolve_repos_json_path() {
  local repo_arg="$1"
  [[ -f "$REPOS_JSON" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  # jq script: walk the 3 buckets, emit "<org/repo> <rel-path>" pairs,
  # then grep for the requested org/repo (exact match).
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
    # repos.json paths are RELATIVE to GYANAM_DIR
    printf '%s\n' "$GYANAM_DIR/$match"
    return 0
  fi
  return 1
}

# ── Resolve canonical path ─────────────────────────────────────────────
CANONICAL_PATH=""
if CANONICAL_PATH="$(resolve_repos_json_path "$REPO_ARG")"; then
  :  # repos.json hit
elif CANONICAL_PATH="$(resolve_fallback_path "$REPO_ARG")"; then
  :  # fallback hit (umbrella self OR claude)
else
  cat >&2 <<EOF
ERROR: Unknown repo '$REPO_ARG'.

Searched:
  - $REPOS_JSON
  - lgit.sh built-in fallbacks (ssnukala/lochan-gyanam, ssnukala/claude)

If this repo is part of the workspace deploy manifest, add it to
repos.json. If it's an external developer-workflow repo (like
ssnukala/claude), add a one-line entry to resolve_fallback_path() in
util/scripts/lgit.sh.

Per [[feedback-no-direct-git-commands-use-lgit-wrapper]]: bypassing
the wrapper is forbidden; either fix the map or use the documented
exception (gh pr <op> for GitHub-API ops; initial git clone for
bootstrap).
EOF
  exit 3
fi

# ── Validate path exists ───────────────────────────────────────────────
if [[ ! -d "$CANONICAL_PATH/.git" ]] && [[ ! -f "$CANONICAL_PATH/.git" ]]; then
  cat >&2 <<EOF
ERROR: Canonical path for '$REPO_ARG' is not a git repository.
  resolved path: $CANONICAL_PATH

Either the repo has not been cloned yet (run the deploy script for
workspace repos) or the path entry in repos.json / lgit.sh fallbacks
is stale.
EOF
  exit 4
fi

# ── Sanity-check the remote URL matches the requested repo ─────────────
ACTUAL_URL="$(git -C "$CANONICAL_PATH" remote get-url origin 2>/dev/null || true)"
ACTUAL_REPO=""
if [[ -n "$ACTUAL_URL" ]]; then
  # Strip https://github.com/ prefix + optional .git suffix
  ACTUAL_REPO="${ACTUAL_URL#https://github.com/}"
  ACTUAL_REPO="${ACTUAL_REPO%.git}"
  # Also handle git@github.com:org/repo.git form
  ACTUAL_REPO="${ACTUAL_REPO#git@github.com:}"
fi

if [[ "$ACTUAL_REPO" != "$REPO_ARG" ]]; then
  cat >&2 <<EOF
ERROR: Remote-URL mismatch at canonical path for '$REPO_ARG'.
  resolved path: $CANONICAL_PATH
  expected origin: $REPO_ARG
  actual origin:   ${ACTUAL_REPO:-<no remote>} (raw: ${ACTUAL_URL:-<none>})

This catches stale repos.json entries + accidentally-pointed-elsewhere
clones. Fix the map OR the working clone before running git ops here.
EOF
  exit 5
fi

# ── Execute git in the canonical directory ─────────────────────────────
# Use `git -C <path>` rather than `cd` so the parent shell's cwd is
# untouched (the whole point: cwd never matters at the call site).
exec git -C "$CANONICAL_PATH" "$@"
