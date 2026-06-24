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
#   bash util/scripts/lgit.sh <org/repo>[@<chunk-id>] <git-subcommand> [args...]
#   bash util/scripts/lgit.sh <org/repo> create-worktree <chunk-id> [--branch <b>] [--base <ref>]
#   bash util/scripts/lgit.sh <org/repo> delete-worktree <chunk-id> [--force]
#
# Examples (primary checkout):
#   bash util/scripts/lgit.sh ssnukala/lochan status
#   bash util/scripts/lgit.sh ssnukala/lochan-gyanam log --oneline -5
#   bash util/scripts/lgit.sh ssnukala/claude commit --confirm-main -m "docs(coord): closure"
#
# Examples (worktree routing via @ syntax):
#   bash util/scripts/lgit.sh ssnukala/lochan@my-feature status
#   bash util/scripts/lgit.sh ssnukala/lochan@my-feature commit -m "feat: ..."
#
# Examples (worktree lifecycle):
#   bash util/scripts/lgit.sh ssnukala/lochan create-worktree my-feature
#   bash util/scripts/lgit.sh ssnukala/lochan delete-worktree my-feature
#
# Recommended convenience alias (place in shell rc):
#   alias lgit='bash /Users/srinivasnukala/Dropbox/Sites/docker/gyanam/util/scripts/lgit.sh'
#
# Exit codes:
#   0   success (forwarded from git on success; or wrapper-success for
#       create-worktree / delete-worktree subcommands)
#   2   USAGE              — missing/bad-shape arg
#   3   UNKNOWN_REPO       — <org/repo> not in repos.json + not in fallback map
#   4   PATH_MISSING       — canonical path resolves but .git/ not on disk
#   5   REMOTE_MISMATCH    — git remote get-url origin doesn't match request
#   6   PROTECTED_BRANCH   — commit/push on branch 'main' without --confirm-main
#   7   WORKTREE_NOT_FOUND — @<chunk-id> doesn't resolve to a live worktree
#   8   WORKTREE_EXISTS    — create-worktree target chunk-id already exists
#   9   WORKTREE_DIRTY     — delete-worktree refused; uncommitted work (without --force)
#   (git's own exit code is forwarded on success/git-error paths)
#
# Protected-branch flag-gate (per founder ratification 2026-05-24 PM
# follow-on + [[feedback-no-direct-commits-to-main-pr-required]] BINDING):
# `git commit` / `git push` while the current branch is `main` REQUIRES
# the explicit `--confirm-main` flag in the args. The wrapper strips
# the flag before forwarding to git so the caller's git invocation
# stays clean. NO static per-repo carve-out — every commit/push to
# main from every repo (including ssnukala/claude orchestration
# metadata) requires explicit affirmation. The flag IS the choice;
# absence of the flag is absence of intent.
#
# Worktree routing (per founder ratification 2026-05-24 PM follow-on):
# the @ syntax lets a session operate IN a worktree without `cd`. The
# resolver prefers `git -C <primary> worktree list --porcelain` (the
# canonical git-native source); falls back to direct-path existence
# check at `<gyanam>/.worktrees/<chunk-id>/`. All other lgit features
# (protected-branch guard, remote verification) apply at worktree level.
#
# Direct git invocation by sessions + S0 is FORBIDDEN once this ships.
# The 3 exceptions (per CODING-STANDARDS §7 #7):
#   (a) this script itself
#   (b) initial workspace bootstrap `git clone`
#   (c) `gh pr <op>` commands (gh is NOT git; --repo flag makes cwd irrelevant)
set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GYANAM_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPOS_JSON="$GYANAM_DIR/repos.json"

# ── resolve-repo: map a workspace PATH/GLOB → owning org/repo ───────────
#
# The INVERSE of resolve_repos_json_path() (which maps org/repo → on-disk
# path). This maps a path/glob (a §8.1 file-glob, a package dir, a single
# file) → the org/repo that owns it, via longest-prefix-match against the
# repos.json registry — the industry-standard tree-of-repos resolution
# (Nx `affected`, Turborepo, pnpm `--filter`, Bazel all do longest-prefix
# match of a path against a project registry). repos.json is the registry
# lgit/lgh/deploy already trust; we add NO parallel mapping.
#
# Why longest-prefix-match against the registry, NOT is_dir(): a file-glob
# can name a FILE (`.../engine.py`), a brace/comma set (`{a,b}.py`), or a
# path NOT YET on disk — none of which is_dir() resolves. A STRING prefix
# match against the registry resolves all of them; when the path IS on
# disk we additionally confirm with git (ground-truth, agrees with the
# registry by construction).
#
# Output: prints the org/repo on success (exit 0); on failure prints a
# clear error to stderr + exits non-zero — NEVER prints a wrong/guessed
# repo (the silent-wrong-repo fallback was the bug this retires).
#
# Usage: lgit resolve-repo <path-or-glob>
#   The <path-or-glob> may be absolute, or relative to the gyanam root.
cmd_resolve_repo() {
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    echo "ERROR: resolve-repo requires a <path-or-glob> argument." >&2
    echo "       Usage: lgit resolve-repo <path-or-glob>" >&2
    return 2
  fi
  if [[ -f "$REPOS_JSON" ]] && command -v jq >/dev/null 2>&1; then :; else
    echo "ERROR: resolve-repo needs repos.json + jq (registry lookup)." >&2
    echo "       repos.json: $REPOS_JSON" >&2
    return 2
  fi

  # 1. Normalize the glob to a single candidate path RELATIVE to gyanam.
  local cand="$raw"
  cand="${cand#"$GYANAM_DIR"/}"        # strip an absolute gyanam prefix if present
  cand="${cand#/}"                      # strip a stray leading slash
  cand="${cand%%,*}"                    # brace/comma set → FIRST component
  cand="${cand//\{/}"; cand="${cand//\}/}"  # drop any leftover brace chars
  cand="${cand%%\**}"                   # strip from the first '*' onward (handles /** and *.py)
  cand="${cand%/}"                      # strip a trailing slash
  if [[ -z "$cand" ]]; then
    echo "ERROR: could not derive a path from glob '$raw'." >&2
    echo "       Pass a path-glob (e.g. framework/lochan/packages/X/**) or --repo <org/repo>." >&2
    return 1
  fi

  # 2. Longest-prefix-match against the registry. Registry holds
  #    path<TAB>org/repo (the repos.json entries). We pick the LONGEST
  #    registry path that is a prefix of the candidate (the most-specific
  #    repo). A pure string match — works even when the path isn't on disk
  #    yet (the key advantage over is_dir()).
  #
  #    NO umbrella catch-all: if no registry path is a prefix, we FAIL LOUD
  #    rather than silently returning the superproject. The silent
  #    superproject fallback IS the bug this subcommand retires (G4 — it
  #    landed all 3 workers in the wrong repo). Prose / unresolvable input
  #    → non-zero exit, nothing printed (per [[no-silent-try-except]]).
  local registry
  registry="$(jq -r '
      [.framework[]?, .mandi_common[]?, .mandi_domain[]?]
      | .[]
      | select(.path? and .url?)
      | .path + "\t" + (.url | sub("^https://github.com/"; "") | sub("\\.git$"; ""))
    ' "$REPOS_JSON")"

  local best_path="" best_repo="" rpath rrepo
  while IFS=$'\t' read -r rpath rrepo; do
    [[ -n "$rpath" && -n "$rrepo" ]] || continue
    if [[ "$cand" == "$rpath" || "$cand" == "$rpath"/* ]]; then
      if [[ ${#rpath} -gt ${#best_path} ]]; then
        best_path="$rpath"; best_repo="$rrepo"
      fi
    fi
  done <<< "$registry"

  if [[ -z "$best_repo" ]]; then
    echo "ERROR: could not resolve repo for '$raw' (candidate path '$cand')." >&2
    echo "       No repos.json registry path is a prefix of it. Pass --repo <org/repo>" >&2
    echo "       or give a §8.1 row a resolvable package file-glob." >&2
    return 1
  fi

  # 3. If the path IS on disk, confirm with git (ground-truth). git must
  #    agree with the registry; a mismatch means a stale clone/registry —
  #    fail loud rather than emit a possibly-wrong repo.
  local on_disk="$GYANAM_DIR/$best_path"
  if [[ -e "$on_disk" ]]; then
    local git_url git_repo
    git_url="$(git -C "$on_disk" remote get-url origin 2>/dev/null || true)"
    if [[ -n "$git_url" ]]; then
      git_repo="$git_url"
      git_repo="${git_repo#https://github.com/}"
      git_repo="${git_repo#git@github.com:}"
      git_repo="${git_repo%.git}"
      if [[ -n "$git_repo" && "$git_repo" != "$best_repo" ]]; then
        echo "ERROR: registry says '$best_repo' for '$cand' but git origin at $on_disk is '$git_repo'." >&2
        echo "       Stale repos.json or mis-pointed clone — fix the map/clone before resolving." >&2
        return 5
      fi
    fi
  fi

  printf '%s\n' "$best_repo"
  return 0
}

# ── Argument parsing ───────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  cat >&2 <<EOF
ERROR: <org/repo> argument required.

Usage: bash util/scripts/lgit.sh <org/repo>[@<chunk-id>] <git-subcommand> [args...]

Examples:
  bash util/scripts/lgit.sh ssnukala/lochan status
  bash util/scripts/lgit.sh ssnukala/claude commit --confirm-main -m "msg"
  bash util/scripts/lgit.sh ssnukala/lochan@my-feature status

The first positional arg is REQUIRED — sessions can no longer drift via
chained-cd batches. Per [[feedback-no-direct-git-commands-use-lgit-wrapper]].
EOF
  exit 2
fi

REPO_ARG_RAW="$1"
shift

# ── resolve-repo dispatch (path→org/repo) ──────────────────────────────
# Intercepted BEFORE the @-split + org/repo-shape validation: its argument
# is a workspace PATH/GLOB, not an org/repo. Owned by lgit because lgit owns
# repos.json — one authoritative path→repo resolver, reused by claim-task +
# any tooling that needs "which repo owns this path" (fix-at-source: no 3rd
# inline copy).
if [[ "$REPO_ARG_RAW" == "resolve-repo" ]]; then
  cmd_resolve_repo "$@"
  exit $?
fi

# Split optional @<chunk-id> suffix for worktree routing.
WORKTREE_ID=""
REPO_ARG="$REPO_ARG_RAW"
if [[ "$REPO_ARG_RAW" == *"@"* ]]; then
  REPO_ARG="${REPO_ARG_RAW%@*}"
  WORKTREE_ID="${REPO_ARG_RAW##*@}"
  if [[ -z "$WORKTREE_ID" ]]; then
    echo "ERROR: worktree suffix '@' present but empty in '$REPO_ARG_RAW'." >&2
    exit 2
  fi
fi

# Validate REPO_ARG shape: org/repo (lowercase + digits + dashes + underscores)
if ! [[ "$REPO_ARG" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9._-]+$ ]]; then
  echo "ERROR: <org/repo> arg '$REPO_ARG' must match shape 'org/repo' (e.g., ssnukala/lochan)." >&2
  exit 2
fi

# Validate WORKTREE_ID shape if set (basename-safe characters only).
if [[ -n "$WORKTREE_ID" ]] && ! [[ "$WORKTREE_ID" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "ERROR: worktree id '$WORKTREE_ID' must match basename-safe shape '^[a-zA-Z0-9._-]+\$'." >&2
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

# ── Resolve canonical (primary) path ───────────────────────────────────
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
repos.json. If it's an external developer-workflow repo, add a one-line
entry to resolve_fallback_path() in util/scripts/lgit.sh.

Per [[feedback-no-direct-git-commands-use-lgit-wrapper]]: bypassing
the wrapper is forbidden; either fix the map or use the documented
exception (gh pr <op> for GitHub-API ops; initial git clone for bootstrap).
EOF
  exit 3
fi

# ── Validate primary path exists ───────────────────────────────────────
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
  ACTUAL_REPO="${ACTUAL_URL#https://github.com/}"
  ACTUAL_REPO="${ACTUAL_REPO%.git}"
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

# ── Worktree resolver ──────────────────────────────────────────────────
#
# Prefer `git -C <primary> worktree list --porcelain` (canonical git-
# native source); fallback to direct path existence check at
# <gyanam>/.worktrees/<chunk-id>/ (the workspace convention).
_list_known_worktrees() {
  git -C "$CANONICAL_PATH" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree / { print "  - " $2 }'
}

_resolve_worktree_path() {
  local chunk_id="$1"
  # Primary lookup — git's authoritative worktree list
  while IFS= read -r _line; do
    case "$_line" in
      "worktree "*)
        local _wt_path="${_line#worktree }"
        if [[ "$(basename "$_wt_path")" == "$chunk_id" ]]; then
          printf '%s\n' "$_wt_path"
          return 0
        fi
        ;;
    esac
  done < <(git -C "$CANONICAL_PATH" worktree list --porcelain 2>/dev/null)
  # Fallback — direct path at <gyanam>/.worktrees/<chunk-id>/
  local _fallback="$GYANAM_DIR/.worktrees/$chunk_id"
  if [[ -d "$_fallback/.git" ]] || [[ -f "$_fallback/.git" ]]; then
    printf '%s\n' "$_fallback"
    return 0
  fi
  return 1
}

# ── Built-in subcommands: create-worktree / delete-worktree ────────────
#
# These run AGAINST the primary checkout (git worktree state lives in
# the primary repo's .git/worktrees/ directory). They do NOT accept the
# @ syntax (the chunk-id is a positional subcommand arg instead).
cmd_create_worktree() {
  if [[ -n "$WORKTREE_ID" ]]; then
    echo "ERROR: 'create-worktree' does not accept @<chunk-id> on the repo arg." >&2
    echo "       Use: lgit $REPO_ARG create-worktree <chunk-id> [--branch <b>] [--base <ref>]" >&2
    exit 2
  fi
  if [[ $# -lt 1 ]]; then
    echo "ERROR: 'create-worktree' requires a <chunk-id> argument." >&2
    echo "       Usage: lgit $REPO_ARG create-worktree <chunk-id> [--branch <b>] [--base <ref>]" >&2
    exit 2
  fi
  local chunk_id="$1"
  shift

  if ! [[ "$chunk_id" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "ERROR: chunk-id '$chunk_id' must match basename-safe shape '^[a-zA-Z0-9._-]+\$'." >&2
    exit 2
  fi

  local branch="$chunk_id"
  local base="origin/main"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch)
        [[ $# -ge 2 ]] || { echo "ERROR: --branch requires a value." >&2; exit 2; }
        branch="$2"; shift 2 ;;
      --base)
        [[ $# -ge 2 ]] || { echo "ERROR: --base requires a value." >&2; exit 2; }
        base="$2"; shift 2 ;;
      *)
        echo "ERROR: unknown flag for create-worktree: '$1'." >&2
        echo "       Allowed: --branch <b> | --base <ref>" >&2
        exit 2 ;;
    esac
  done

  local wt_path="$GYANAM_DIR/.worktrees/$chunk_id"
  if [[ -e "$wt_path" ]]; then
    cat >&2 <<EOF
ERROR: Worktree '$chunk_id' already exists at:
  $wt_path

Existing worktrees on $REPO_ARG:
$(_list_known_worktrees)

Use 'lgit $REPO_ARG delete-worktree $chunk_id' to remove first, OR
choose a different chunk-id.
EOF
    exit 8
  fi

  echo "lgit: creating worktree '$chunk_id' on '$REPO_ARG' (branch=$branch base=$base)" >&2
  # Refresh the base ref so the new worktree starts off latest.
  git -C "$CANONICAL_PATH" fetch origin "${base#origin/}" >/dev/null 2>&1 || true
  exec git -C "$CANONICAL_PATH" worktree add -b "$branch" "$wt_path" "$base"
}

cmd_delete_worktree() {
  if [[ -n "$WORKTREE_ID" ]]; then
    echo "ERROR: 'delete-worktree' does not accept @<chunk-id> on the repo arg." >&2
    echo "       Use: lgit $REPO_ARG delete-worktree <chunk-id> [--force]" >&2
    exit 2
  fi
  if [[ $# -lt 1 ]]; then
    echo "ERROR: 'delete-worktree' requires a <chunk-id> argument." >&2
    echo "       Usage: lgit $REPO_ARG delete-worktree <chunk-id> [--force]" >&2
    exit 2
  fi
  local chunk_id="$1"
  shift

  local force=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force="--force"; shift ;;
      *)
        echo "ERROR: unknown flag for delete-worktree: '$1'." >&2
        echo "       Allowed: --force" >&2
        exit 2 ;;
    esac
  done

  local wt_path="$GYANAM_DIR/.worktrees/$chunk_id"
  if [[ ! -d "$wt_path" ]]; then
    cat >&2 <<EOF
ERROR: Worktree '$chunk_id' does not exist at:
  $wt_path

Known worktrees on $REPO_ARG:
$(_list_known_worktrees)
EOF
    exit 7
  fi

  if [[ -z "$force" ]]; then
    local dirty
    dirty="$(git -C "$wt_path" status --porcelain 2>/dev/null || true)"
    if [[ -n "$dirty" ]]; then
      cat >&2 <<EOF
ERROR: Worktree '$chunk_id' has uncommitted changes — refusing to delete.

Uncommitted state at $wt_path:
$dirty

To remove anyway (DESTROYS uncommitted work):
  lgit $REPO_ARG delete-worktree $chunk_id --force

To preserve the work first, commit or stash it via:
  lgit ${REPO_ARG}@${chunk_id} status
  lgit ${REPO_ARG}@${chunk_id} add <files>
  lgit ${REPO_ARG}@${chunk_id} commit -m "wip: ..."
EOF
      exit 9
    fi
  fi

  exec git -C "$CANONICAL_PATH" worktree remove $force "$wt_path"
}

# Dispatch built-in subcommands BEFORE the @-resolution (they take their
# own chunk-id arg + operate against the primary).
if [[ $# -ge 1 ]]; then
  case "$1" in
    create-worktree)
      shift; cmd_create_worktree "$@" ;;
    delete-worktree)
      shift; cmd_delete_worktree "$@" ;;
  esac
fi

# ── Resolve effective path (primary OR worktree) ───────────────────────
EFFECTIVE_PATH="$CANONICAL_PATH"
if [[ -n "$WORKTREE_ID" ]]; then
  if ! EFFECTIVE_PATH="$(_resolve_worktree_path "$WORKTREE_ID")"; then
    cat >&2 <<EOF
ERROR: Worktree '$WORKTREE_ID' not found for '$REPO_ARG'.

Known worktrees (per 'git worktree list' against $CANONICAL_PATH):
$(_list_known_worktrees)

Fallback path checked: $GYANAM_DIR/.worktrees/$WORKTREE_ID
(directory does not exist or is not a git worktree)

To create: lgit $REPO_ARG create-worktree $WORKTREE_ID
EOF
    exit 7
  fi
fi

# ── Protected-branch guard (commit / push on main require --confirm-main) ──
#
# Extract subcmd (first non-flag positional in forwarded args). Then
# scan for --confirm-main + strip it before exec. Refuses with exit 6
# if the flag is absent.
_subcmd=""
for _a in "$@"; do
  case "$_a" in
    -*) continue ;;
    *)  _subcmd="$_a"; break ;;
  esac
done

if [[ "$_subcmd" == "commit" ]] || [[ "$_subcmd" == "push" ]]; then
  _current_branch="$(git -C "$EFFECTIVE_PATH" branch --show-current 2>/dev/null || echo "")"
  if [[ "$_current_branch" == "main" ]]; then
    # Scan args for --confirm-main; strip the FIRST occurrence; track presence
    _has_confirm=0
    _filtered=()
    for _a in "$@"; do
      if [[ "$_has_confirm" -eq 0 && "$_a" == "--confirm-main" ]]; then
        _has_confirm=1
        continue
      fi
      _filtered+=("$_a")
    done
    if [[ "$_has_confirm" -eq 0 ]]; then
      cat >&2 <<EOF
ERROR: lgit refuses 'git $_subcmd' on branch 'main' WITHOUT --confirm-main.
  repo: $REPO_ARG${WORKTREE_ID:+@$WORKTREE_ID}
  path: $EFFECTIVE_PATH

Per [[feedback-no-direct-commits-to-main-pr-required]] BINDING + founder
ratification 2026-05-24 PM: every commit/push to main is an EXPLICIT
affirmation; no static carve-out (including ssnukala/claude). The flag
IS the choice; absence of the flag is absence of intent.

To proceed (use sparingly — this is the explicit-affirmation path):
  lgit $REPO_ARG_RAW $_subcmd --confirm-main <other-args>

If you intended to commit to a feature branch (not main), check
'lgit $REPO_ARG${WORKTREE_ID:+@$WORKTREE_ID} branch --show-current' first.
EOF
      exit 6
    fi
    echo "lgit: --confirm-main present → proceeding with 'git $_subcmd' on main for '$REPO_ARG${WORKTREE_ID:+@$WORKTREE_ID}'" >&2
    # Replace positional args with the filtered version (flag stripped)
    set -- "${_filtered[@]}"
  fi
fi

# ── Execute git in the effective directory ─────────────────────────────
# Use `git -C <path>` rather than `cd` so the parent shell's cwd is
# untouched (the whole point: cwd never matters at the call site).
exec git -C "$EFFECTIVE_PATH" "$@"
