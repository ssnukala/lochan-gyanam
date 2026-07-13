#!/usr/bin/env bash
# ============================================================================
# deploy-lochan.sh — reusable bootstrap + deploy for a Lochan gyanam workspace
# ============================================================================
#
# Reads repos.json (next to this script) for the canonical list of repos.
# Pulls every framework + mandi_common repo on every run. Pulls a
# mandi_domain repo only when an app that needs it is requested via --app.
#
# Usage:
#   ./scripts/deploy-lochan.sh --prod    --app fwprod01
#   ./scripts/deploy-lochan.sh --staging --app fwprod01 --app longterm01
#   ./scripts/deploy-lochan.sh --prod --app fwprod01 --app lifestyle01 --app longterm01
#   ./scripts/deploy-lochan.sh --dev  --app fwprod01
#   ./scripts/deploy-lochan.sh --pull-only                # refresh all repos, no build/deploy
#   ./scripts/deploy-lochan.sh --skip-pull --app fwprod01 # use current clones as-is
#   ./scripts/deploy-lochan.sh --skip-build --app fwprod01 # restart only (images already built)
#   ./scripts/deploy-lochan.sh --skip-pkg-builds --app longterm01 # skip Phase 2.5 bundled-pkg
#                                                          # + deps-image staleness gate
#                                                          # (images may be STALE)
#   ./scripts/deploy-lochan.sh --skip-stamp --app fwprod01 # skip daksh stamp-meta (images
#                                                          # ship WITHOUT __pkg_meta__.py;
#                                                          # envelopes report stamped:false)
#
# Compose mode:
#   --prod    → docker compose -f compose.prod.yml ...    (or compose.yml if no .prod.yml)
#   --staging → docker compose -f compose.staging.yml [-f compose.staging.override.yml] ...
#               env=.env.staging. The staging surface = production-shaped app
#               (public-origin URLs at staging.lochan.ai so OAuth issuer + MCP
#               discovery advertise the public origin an external agent resolves).
#               The optional compose.staging.override.yml (single-worker MCP-test
#               stability fix) is auto-included when present.
#   --dev     → docker compose -f compose.dev.yml ...     (default if no mode flag is set)
#
# The script is idempotent. Safe to re-run. Exits non-zero on any build or
# deploy error so CI / cron can detect failures.
# ============================================================================

set -euo pipefail

# ── Locate repo root ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GYANAM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPOS_JSON="$GYANAM_DIR/repos.json"

[[ -f "$REPOS_JSON" ]] || { echo "ERROR: repos.json not found at $REPOS_JSON" >&2; exit 1; }

# ── Colors ─────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
else
  R=''; G=''; Y=''; C=''; B=''; N=''
fi

log()  { echo -e "${G}[✓]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[✗]${N} $*" >&2; }
sect() { echo; echo -e "${B}${C}══════════════════════════════════════════${N}"; echo -e "${B}${C}  $*${N}"; echo -e "${B}${C}══════════════════════════════════════════${N}"; }

# ── Arg parsing ────────────────────────────────────────────────────────────
MODE="dev"           # dev | staging | prod
APPS=()              # list of apps to deploy
PULL=1               # pull repos?
BUILD=1              # build base images?
PKG_BUILDS=1         # rebuild bundled per-package images (Phase 2.5 staleness gate)?
STAMP=1              # run daksh stamp-meta --all before image builds (§8.6 build stamp)?
DEPLOY=1             # start/restart containers?
PULL_ONLY=0          # short-circuit after pull
DEPLOY_FAILED=0      # set to 1 if any app's bring-up fails → exit 1 at the end

while (( $# )); do
  case "$1" in
    --prod)       MODE="prod" ;;
    --staging)    MODE="staging" ;;
    --dev)        MODE="dev"  ;;
    --app)        shift; APPS+=("$1") ;;
    --skip-pull)  PULL=0  ;;
    --skip-build) BUILD=0 ;;
    --skip-pkg-builds) PKG_BUILDS=0 ;;
    --skip-stamp) STAMP=0 ;;
    --skip-deploy)DEPLOY=0;;
    --pull-only)  PULL_ONLY=1; BUILD=0; DEPLOY=0 ;;
    # Pattern-bound range (not a hardcoded end line): print the title banner
    # (2-4), then everything up to the header's CLOSING `# ====` rule — so
    # growing the usage docs can never silently truncate --help again (it
    # did when the block passed the old hardcoded line 32).
    --help|-h)    sed -n '2,4p; 5,/^# =\{20\}/p' "$0"; exit 0 ;;
    *) err "Unknown flag: $1"; exit 2 ;;
  esac
  shift
done

# ── Dependencies ────────────────────────────────────────────────────────────
for cmd in git docker python3; do
  command -v "$cmd" >/dev/null 2>&1 || { err "missing dependency: $cmd"; exit 1; }
done

# ── repos.json helpers ──────────────────────────────────────────────────────
# Python 3 ships json in its stdlib and is already required elsewhere in the
# gyanam build flow — dropping jq trims one install step on fresh Alpine hosts.

# Emit TSV rows of (path, url) for every entry in the given bucket
# (framework, mandi_common, mandi_domain). Skips entries without both fields
# and anything that is not a dict (repos.json uses a _comment array at the
# top level for docs).
repos_bucket_tsv() {
  local bucket="$1"
  python3 - "$REPOS_JSON" "$bucket" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for entry in data.get(sys.argv[2], []):
    if not isinstance(entry, dict):
        continue
    path = entry.get("path")
    url = entry.get("url")
    if path and url:
        print(f"{path}\t{url}")
PY
}

# List domain repo paths for a given app from app_to_domains.
# Prints one path per line; prints nothing (exit 0) for unknown apps.
repos_app_domains() {
  local app="$1"
  python3 - "$REPOS_JSON" "$app" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for p in data.get("app_to_domains", {}).get(sys.argv[2], []) or []:
    if isinstance(p, str):
        print(p)
PY
}

# Look up the git URL for a domain path in mandi_domain.
# Prints the URL (or nothing + exit 0) for the first matching entry.
repos_domain_url() {
  local domain_path="$1"
  python3 - "$REPOS_JSON" "$domain_path" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for entry in data.get("mandi_domain", []):
    if isinstance(entry, dict) and entry.get("path") == sys.argv[2]:
        url = entry.get("url", "")
        if url:
            print(url)
        break
PY
}

# ── Repo helpers ────────────────────────────────────────────────────────────
clone_or_pull() {
  local path="$1" url="$2"
  local full="$GYANAM_DIR/$path"
  if [[ -d "$full/.git" ]]; then
    echo -n "  pull $path ... "
    # FAIL LOUD on stale source (§D.BUILD-CACHE, 2026-07-03). The old code
    # `git pull --ff-only … || warn "leaving as-is"` silently CONTINUED on the
    # PRE-pull commit whenever the pull couldn't fast-forward (non-ff, dirty
    # tree, transient fetch error) — the build context then kept last-run's
    # source, the Tier-0/Tier-1 COPY layers saw identical bytes, and the base
    # cache-hit STALE (this is how #1621 never landed on the server: 3 deploy
    # failures on old code until a forced no-cache rebuild). The Docker cache
    # key was never the bug; the sync silently leaving stale source was.
    # Fix at the source: fetch, then require the branch to advance to (or
    # already be at) origin. If it can't, abort the deploy — never build on a
    # tree we failed to update. (blanket --no-cache was REJECTED: it rebuilds
    # the SAME stale source slower and still ships the old code.)
    local before after
    before="$(git -C "$full" rev-parse HEAD 2>/dev/null || echo none)"
    if ! git -C "$full" fetch --quiet origin 2>/dev/null; then
      err "$path: git fetch failed (network/remote) — deploy aborted, refusing to build on unverified source"
      DEPLOY_FAILED=1; return 1
    fi
    if ! git -C "$full" merge --ff-only --quiet '@{u}' 2>/dev/null; then
      err "$path: cannot fast-forward to origin (non-ff or dirty tree) — still at ${before:0:9}; deploy aborted, refusing to build on stale source"
      DEPLOY_FAILED=1; return 1
    fi
    after="$(git -C "$full" rev-parse HEAD 2>/dev/null || echo none)"
    if [[ "$before" == "$after" ]]; then
      echo "ok (already at ${after:0:9})"
    else
      echo "ok (${before:0:9} → ${after:0:9})"
    fi
  elif [[ -d "$full" && -n "$(ls -A "$full" 2>/dev/null)" ]]; then
    err "$path exists but isn't a git repo — deploy aborted (cannot verify source is current)"
    DEPLOY_FAILED=1; return 1
  else
    echo -n "  clone $path ... "
    mkdir -p "$(dirname "$full")"
    if git clone --quiet "$url" "$full" 2>/dev/null; then
      echo "ok"
    else
      err "clone failed for $url"
      DEPLOY_FAILED=1; return 1
    fi
  fi
}

pull_bucket() {
  local bucket="$1"
  local count=0
  while IFS=$'\t' read -r path url; do
    [[ -z "$path" ]] && continue
    # `|| true` so one repo's fail-loud (DEPLOY_FAILED=1 + return 1) does not
    # abort the loop under `set -e` — every repo is attempted, then the
    # post-Phase-1 gate (below) aborts the run cleanly with the full picture.
    clone_or_pull "$path" "$url" || true
    count=$((count + 1))
  done < <(repos_bucket_tsv "$bucket")
  log "$bucket: $count repo(s) synced"
}

# ── Bundled-package helpers (Phase 2.5) ─────────────────────────────────────
# List the package images an app bundles: every `FROM <img>:latest AS pkg-*`
# stage in its backend/frontend Dockerfiles (the bundled-package convention —
# apps/<app>/Dockerfile.backend COPYs each stage into /app/packages/<pkg>/).
app_bundled_pkgs() {
  local app="$1" df
  for df in "$GYANAM_DIR/apps/$app/Dockerfile.backend" "$GYANAM_DIR/apps/$app/Dockerfile.frontend"; do
    [[ -f "$df" ]] || continue
    sed -n -E 's/^FROM[[:space:]]+([A-Za-z0-9._-]+):latest[[:space:]]+AS[[:space:]]+pkg-.*/\1/p' "$df"
  done | sort -u
}

# Resolve a bundled package name to its source clone (the dir its build.sh
# builds from). Same search order as daksh's PackageResolver.
pkg_src_dir() {
  local pkg="$1" base
  for base in mandi/domain mandi/common framework/lochan/packages; do
    if [[ -f "$GYANAM_DIR/$base/$pkg/build.sh" ]]; then
      echo "$GYANAM_DIR/$base/$pkg"
      return 0
    fi
  done
  return 1
}

# ── Deps-image helpers (Phase 2.5 deps-staleness extension) ─────────────────
# §DEPS-STALENESS-GATE (2026-07-08; 4th recurrence of the stale-image trap).
# apps/<app>/Dockerfile.backend is `FROM <app>-deps:latest`, and that deps
# image pins a SNAPSHOT of the base it was built FROM. Phase 2 rebuilds the
# base correctly, but nothing re-derived the deps layer when its base advanced
# — a "successful" deploy shipped a container missing framework code the base
# already had (2026-07-08: longterm01 without tarkan.metrics). Same doctrine
# as §PKG-STALENESS-GATE: determinism, not detection — verify the derived
# image sits on the CURRENT base, rebuild it when it doesn't, refuse loudly
# when it can't be rebuilt.

# The base image an app's deps layer derives FROM, read from the app's own
# Dockerfile.deps — the Dockerfile is the source of truth, never a hardcoded
# base name. Return 1 when the app has no deps layer.
#
# ⚠ Multi-stage: the runtime base is the FINAL stage's FROM, NOT the first.
# A wheel-bundled app (e.g. lifestyle01) opens with a `FROM <pkg>:latest AS
# pkg-<name>` wheel-source stage, THEN `FROM lochan-backend-base:latest` as the
# real base. The deps image sits on that LAST stage. Taking `head -1` resolved
# the wheel-source `pkg-*` stage as the "base" → the layer-prefix gate compared
# against the wrong parent, never matched, and aborted the deploy on a phantom
# staleness (2026-07-12, lifestyle01 — the first wheel-bundled app to exercise
# this path). Skip any `FROM … AS <stage>` stage-declaration (an intermediate
# build stage is never the runtime base) and return the last bare FROM — the
# final target, exactly as `docker build` with no --target resolves it.
app_deps_base() {
  local app="$1" df base
  df="$GYANAM_DIR/apps/$app/Dockerfile.deps"
  [[ -f "$df" ]] || return 1
  # bare `FROM <img>` lines only (exclude `FROM … AS <stage>`), last one wins.
  base="$(sed -n -E 's/^FROM[[:space:]]+([^[:space:]]+)[[:space:]]*$/\1/p' "$df" | tail -1)"
  [[ -n "$base" ]] || return 1
  echo "$base"
}

# layers_prefix_match <base_layers_json> <img_layers_json>
# True (0) when the base image's RootFS.Layers JSON array is a PREFIX of the
# derived image's — i.e. the derived image really sits on the CURRENT base.
# Inputs are `docker image inspect -f '{{json .RootFS.Layers}}'` output
# (compact JSON, hex digests — glob-safe). Pure string logic so the
# regression test (util/scripts/test-deploy-deps-staleness-gate.sh) can
# exercise it docker-free. Empty/null input fails CLOSED (treat as stale).
layers_prefix_match() {
  local base="$1" img="$2"
  [[ -n "$base" && -n "$img" ]] || return 1
  [[ "$base" != "null" && "$img" != "null" && "$base" != "[]" ]] || return 1
  [[ "$img" == "$base" ]] && return 0
  # Proper prefix: the derived list continues the base list after a comma.
  # "${base%]}" strips the closing bracket; requiring "," right after it
  # prevents a digest-boundary false match ("sha256:bb" vs "sha256:bbX").
  [[ "$img" == "${base%]},"* ]]
}

# ── Phase 0: verify app→domain mapping (class-prevention, 2026-07-02) ──────
# app_to_domains drift is how the longterm01 server deploy silently skipped
# flow/vyaparam (mapping listed only longterm). Verify the mapping against
# each requested app's generated packages.json BEFORE doing any work and fail
# loud on any gap — including a domain path missing from the mandi_domain
# registry. Apps not generated yet are skipped inside the verifier (fresh
# bootstrap: apps/ appears after the first sync + generate).
if (( ${#APPS[@]} > 0 )); then
  sect "Phase 0: Verify app_to_domains vs apps/<app>/packages.json"
  verify_args=()
  for app in "${APPS[@]}"; do verify_args+=(--app "$app"); done
  if python3 "$SCRIPT_DIR/verify-app-domains.py" --gyanam "$GYANAM_DIR" "${verify_args[@]}"; then
    log "app_to_domains mapping verified"
  else
    err "app_to_domains mapping is WRONG for a requested app — fix repos.json (app_to_domains / mandi_domain) before deploying"
    exit 1
  fi
fi

# ── Phase 1: repo sync ─────────────────────────────────────────────────────
if (( PULL )); then
  sect "Phase 1: Sync framework + common repos"
  pull_bucket framework
  pull_bucket mandi_common

  if (( ${#APPS[@]} > 0 )); then
    sect "Phase 1b: Sync domain repos for requested apps"
    local_domains=()
    for app in "${APPS[@]}"; do
      # bash-3.2-compatible array read (macOS host bash is 3.2.57; `mapfile`
      # is bash-4+). The while-read-into-array idiom is the portable equivalent.
      app_doms=()
      while IFS= read -r _line; do app_doms+=("$_line"); done < <(repos_app_domains "$app")
      # guard empty-array expansion under set -u (bash 3.2)
      (( ${#app_doms[@]} > 0 )) && for d in "${app_doms[@]}"; do local_domains+=("$d"); done
    done
    # dedupe (bash-3.2-compatible — see note above). Guard the empty-array
    # expansion: under `set -u`, bash 3.2 errors on "${arr[@]}" when arr is
    # empty (unbound variable), so only dedupe when there's something to read.
    if (( ${#local_domains[@]} > 0 )); then
      _deduped=()
      while IFS= read -r _line; do _deduped+=("$_line"); done \
        < <(printf "%s\n" "${local_domains[@]}" | sort -u)
      local_domains=("${_deduped[@]}")
    fi

    if (( ${#local_domains[@]} == 0 )); then
      warn "no domain repos needed for requested apps (framework-only)"
    else
      for dom in "${local_domains[@]}"; do
        url=$(repos_domain_url "$dom")
        [[ -z "$url" ]] && { warn "no url for $dom in repos.json"; continue; }
        clone_or_pull "$dom" "$url" || true   # see pull_bucket note; gate below
      done
      log "domain repos: ${#local_domains[@]} synced"
    fi
  fi

  # ── Post-Phase-1 gate: abort BEFORE building on stale/unverified source ────
  # §D.BUILD-CACHE (2026-07-03). Any clone_or_pull that could not bring a repo
  # to its origin set DEPLOY_FAILED=1. We stop HERE — before Phase 2 builds —
  # because building on stale source is the exact incident this fixes: a base
  # image built from last-run's code cache-hits "clean" and silently ships the
  # OLD framework. Fail loud at the source of the staleness, not after the
  # wasted build ([[no-silent-try-except]] / fix-at-source).
  if (( ${DEPLOY_FAILED:-0} )); then
    err "Phase 1 could not sync one or more repos to origin — aborting BEFORE build (refusing to build/deploy on stale source)"
    exit 1
  fi
else
  warn "skipping pull (--skip-pull)"
fi

(( PULL_ONLY )) && { log "pull-only mode — done."; exit 0; }

# ── Phase 2: build base images (Tier 0 + Tier 1) ───────────────────────────
if (( BUILD )); then
  sect "Phase 2: Build framework base images"
  cd "$GYANAM_DIR"

  # §D.BUILD-CACHE class-prevention (2026-07-03). SOURCE_HASH = the git TREE
  # hash of the framework/lochan subtree (content-addressed: changes iff any
  # tracked framework byte changes). Threaded as a --build-arg into every base
  # build; each base Dockerfile references it in a cheap LABEL right after FROM
  # so it participates in the layer cache key. Effect: a framework-source change
  # forces the base chain to re-derive from that point down, even in the (rare)
  # case a COPY-checksum bust is missed or BuildKit mis-reuses a layer. This is
  # belt-and-suspenders ON TOP of Leg 1 (which already guarantees the source is
  # current before we get here) — NOT a substitute for it, and NOT blanket
  # --no-cache (which would rebuild identical current source slower for nothing).
  # `HEAD^{tree}` is the canonical root-tree form. The previous `HEAD:.`
  # is REJECTED by newer git (exit 128) while still echoing the literal to
  # stdout — so SOURCE_HASH was silently the constant "HEAD:.\nunknown"
  # and this whole leg was inert (found live 2026-07-08; regression test:
  # util/scripts/test-deploy-source-hash.sh).
  SOURCE_HASH="$(git -C "$GYANAM_DIR/framework/lochan" rev-parse 'HEAD^{tree}' 2>/dev/null || echo unknown)"
  log "framework source hash: ${SOURCE_HASH:0:12}"

  # ── Stamp package provenance BEFORE any image build (§8.6 build stamp) ────
  # Finding B (S1-P1-DEPLOY, 2026-07-08): no image path ran `daksh
  # stamp-meta`, so no __pkg_meta__.py shipped and every metrics envelope
  # reported build.stamped:false — the stale-image ambiguity the stamp exists
  # to kill. Stamp HERE, before the base build and the Phase 2.5 pkg builds,
  # so the per-package stamps ride the EXISTING copy paths into every image:
  # the base bakes framework packages (pip install from the COPYed source),
  # each pkg build.sh COPYs its just-synced clone, and <app>-deps inherits
  # the base's site-packages. Reuses the canonical daksh surface (stamp_meta
  # --all writes real per-repo git SHAs — impossible inside a docker build,
  # where .git is dockerignored). daksh-cli is present on any host after
  # Phase 1 (the framework clone ships it); failure REFUSES the build —
  # silently shipping unstamped images is the bug this fixes. --skip-stamp
  # is the loud, explicit escape hatch (symmetric with --skip-pkg-builds).
  if (( STAMP )); then
    DAKSH_CLI="$GYANAM_DIR/framework/lochan/packages/daksh/daksh-cli"
    echo -n "  stamp package provenance (daksh stamp-meta --all) ... "
    if [[ -x "$DAKSH_CLI" ]] && _stamp_out="$("$DAKSH_CLI" stamp-meta --all --gyanam-root "$GYANAM_DIR" 2>&1)"; then
      echo "ok"
      log "$(printf '%s\n' "$_stamp_out" | grep -m1 '^stamped ' || echo 'provenance stamped')"
    else
      echo "FAILED"
      err "stamp-meta failed (or daksh-cli not runnable at $DAKSH_CLI) — refusing to build UNSTAMPED images (every metrics envelope would report build.stamped:false; pass --skip-stamp to bypass loudly)"
      [[ -n "${_stamp_out:-}" ]] && printf '%s\n' "$_stamp_out" | tail -20 >&2
      exit 1
    fi
  else
    warn "skipping stamp-meta (--skip-stamp) — images ship WITHOUT __pkg_meta__.py; metrics envelopes will report build.stamped:false"
  fi

  # docker_build <dockerfile> <tag> [target]
  # The optional <target> selects a specific stage of a multi-stage Dockerfile.
  # Without it `docker build` builds the LAST stage — which for the multi-stage
  # 02-frontend-base.Dockerfile is `test` (a Playwright sidecar whose
  # `npx playwright install` is irrelevant to + breaks the deploy). The deploy
  # must target the mode's runtime stage, matching what the app Dockerfiles
  # consume (compose.dev.yml → `lochan-frontend-base:dev`; Dockerfile.frontend
  # → `lochan-frontend-base:prod`). Mirrors build-app.sh's targeted builds.
  docker_build() {
    local file="$1" tag="$2" target="${3:-}"
    local target_args=()
    [[ -n "$target" ]] && target_args=(--target "$target")
    # §FIX-TIER1-SECRET — 02-backend-base.Dockerfile precomputes the framework
    # embedding artifacts (§BUILD-STAGE-PRECOMPUTE Gemini build block). Thread
    # the API key as an env-sourced BuildKit secret; the Dockerfile mounts it
    # required=false, so a key-less build still succeeds — but SILENTLY ships
    # the base artifact-less (boot live-computes). Backend-base ONLY: no other
    # dockerfile mounts gemini_key. Mirrors daksh cli_dispatch.py Tier-1 +
    # services/deployer/_build.py.
    local secret_args=()
    if [[ "$file" == *02-backend-base.Dockerfile && -n "${AI_GEMINI_API_KEY:-}" ]]; then
      secret_args=(--secret "id=gemini_key,env=AI_GEMINI_API_KEY")
    fi
    echo -n "  build $tag ($file${target:+ --target $target}) ... "
    # §D.BUILD-CACHE: pass the framework source tree-hash so a source change
    # invalidates the base cache from the SOURCE_HASH LABEL down (each base
    # Dockerfile declares `ARG SOURCE_HASH` + a LABEL referencing it right after
    # FROM). Harmless when unchanged (same hash = same cache key).
    # ${arr[@]+"${arr[@]}"} — bash-3.2-safe expansion of a possibly-empty array
    # under set -u (a bare "${arr[@]}" errors "unbound variable" when empty).
    # DOCKER_BUILDKIT=1 on every build (required for the secret mount; matches
    # services/deployer/_build.py which enables it for all image builds).
    if DOCKER_BUILDKIT=1 docker build --quiet --build-arg "SOURCE_HASH=${SOURCE_HASH:-unknown}" ${target_args[@]+"${target_args[@]}"} ${secret_args[@]+"${secret_args[@]}"} -f "$file" -t "$tag" . >/dev/null; then
      echo "ok"
    else
      err "build failed: $tag"; DEPLOY_FAILED=1; return 1
    fi
  }

  # Single-final-stage images — no target needed (last stage IS the artifact).
  docker_build docker/01-backend-deps.Dockerfile  lochan-deps-backend:latest
  docker_build docker/01-frontend-deps.Dockerfile lochan-deps-frontend:latest
  docker_build docker/02-backend-base.Dockerfile  lochan-backend-base:latest
  # Multi-stage frontend base (dev → prod → test): build the MODE's runtime
  # stage + tag it as the app Dockerfiles expect (NOT :latest = the test stage).
  # STAGING maps to the PROD base stage+tag: staging is production-shaped (the
  # 02-frontend-base.Dockerfile has NO `staging` target — only dev/prod/test),
  # and the app `Dockerfile.frontend` FROMs `lochan-frontend-base:prod`. So a
  # bare `--target staging` fails ("target stage staging could not be found")
  # and a `:staging` tag would never be consumed. Build+tag as prod for staging.
  base_stage="$MODE"
  [[ "$MODE" == "staging" ]] && base_stage="prod"
  docker_build docker/02-frontend-base.Dockerfile "lochan-frontend-base:${base_stage}" "$base_stage"
else
  warn "skipping base image builds (--skip-build)"
fi

# ── Phase 2.5: rebuild bundled package images (staleness gate) ──────────────
# §PKG-STALENESS-GATE (2026-07-07; third recurrence of the stale-pkg-image
# trap). Phase 2 rebuilds ONLY the deps/base images; each app's Dockerfiles
# then do `FROM <pkg>:latest AS pkg-<name>` + COPY — so a `<pkg>:latest` built
# before a fix landed silently bakes the OLD package into a "successful"
# deploy (2026-07-04 BaseService wave: backend crash-loop from a dead import;
# 2026-07-07: longterm:latest still bundled pre-GAP-17 source even though its
# CreatedAt was 16 min AFTER the fix commit — the image was built before the
# clone was pulled, so timestamp comparison is provably unreliable for
# staleness). Fix = determinism, not detection: ALWAYS rebuild each requested
# app's bundled package images from the just-synced clones (Phase 1 already
# guarantees clone == origin, fail-loud). Docker's layer cache makes the
# unchanged case a cache-hit no-op, so the guarantee costs seconds — same
# doctrine as Phase 2's SOURCE_HASH: never deploy an image you can't tie to
# current source. Runs the package's own build.sh, exactly what daksh
# build-pkg does (services/deployer/_build.py::build_package) — inlined so a
# fresh bootstrap host needs no daksh venv. `--skip-pkg-builds` is the loud,
# explicit escape hatch (symmetric with --skip-build; skipping prints a STALE
# warning). Skipped under --skip-build too: that flag means "restart only,
# images already built".
if (( BUILD )) && (( PKG_BUILDS )) && (( ${#APPS[@]} > 0 )); then
  sect "Phase 2.5: Rebuild bundled package images (staleness gate)"
  pkg_list=()
  for app in "${APPS[@]}"; do
    while IFS= read -r _p; do [[ -n "$_p" ]] && pkg_list+=("$_p"); done < <(app_bundled_pkgs "$app")
  done
  # dedupe (bash-3.2-compatible; guard empty expansion under set -u)
  if (( ${#pkg_list[@]} > 0 )); then
    _deduped=()
    while IFS= read -r _line; do _deduped+=("$_line"); done \
      < <(printf "%s\n" "${pkg_list[@]}" | sort -u)
    pkg_list=("${_deduped[@]}")
  fi
  if (( ${#pkg_list[@]} == 0 )); then
    log "no bundled package images referenced by requested apps (framework-only)"
  else
    for pkg in "${pkg_list[@]}"; do
      if ! src_dir="$(pkg_src_dir "$pkg")"; then
        err "$pkg: bundled by a requested app but no source clone with build.sh found (searched mandi/domain, mandi/common, framework/lochan/packages) — cannot tie ${pkg}:latest to current source"
        DEPLOY_FAILED=1
        continue   # attempt every package, then abort with the full picture
      fi
      echo -n "  build ${pkg}:latest (from ${src_dir#"$GYANAM_DIR"/}) ... "
      # Capture output; print it only on failure (fail loud with evidence,
      # quiet on the common cache-hit success path).
      if _build_out="$(cd "$src_dir" && bash build.sh latest 2>&1)"; then
        echo "ok"
      else
        echo "FAILED"
        err "$pkg: package image build failed — refusing to deploy on a stale/unbuildable package image"
        printf '%s\n' "$_build_out" | tail -20 >&2
        DEPLOY_FAILED=1
      fi
    done
  fi
  # ── Phase 2.5b: per-app deps-image staleness gate (§DEPS-STALENESS-GATE) ──
  # See the deps-image helpers block above for the incident. For each
  # requested app: read the deps layer's base from its own Dockerfile.deps,
  # verify <app>-deps:latest layer-prefix-matches the CURRENT base image, and
  # rebuild the deps layer (build-app.sh --deps-only — it threads the Gemini
  # BuildKit secret itself) on any mismatch or absence. Rebuild-then-verify;
  # refuse loudly when the rebuild fails or still doesn't sit on the base.
  for app in "${APPS[@]}"; do
    if ! deps_base="$(app_deps_base "$app")"; then
      log "$app: no Dockerfile.deps — no deps layer to gate"
      continue
    fi
    deps_img="${app}-deps:latest"
    if ! base_layers="$(docker image inspect "$deps_base" -f '{{json .RootFS.Layers}}' 2>/dev/null)"; then
      err "$app: deps base image '$deps_base' not present locally — cannot tie $deps_img to a current base (build the base first, or --skip-pkg-builds to bypass loudly)"
      DEPLOY_FAILED=1
      continue
    fi
    deps_layers="$(docker image inspect "$deps_img" -f '{{json .RootFS.Layers}}' 2>/dev/null || true)"
    if layers_prefix_match "$base_layers" "$deps_layers"; then
      log "$app: $deps_img sits on current $deps_base (layer-prefix verified)"
      continue
    fi
    if [[ -z "$deps_layers" ]]; then
      warn "$app: $deps_img not built yet — building it now"
    else
      warn "$app: $deps_img was built on an OLD $deps_base (layer prefix mismatch) — rebuilding"
    fi
    if [[ ! -f "$GYANAM_DIR/apps/$app/build-app.sh" ]]; then
      err "$app: no apps/$app/build-app.sh to rebuild the deps layer with — refusing to deploy on a stale $deps_img"
      DEPLOY_FAILED=1
      continue
    fi
    echo -n "  rebuild $deps_img (apps/$app/build-app.sh --deps-only) ... "
    if _deps_out="$(cd "$GYANAM_DIR/apps/$app" && bash build-app.sh --deps-only 2>&1)"; then
      echo "ok"
    else
      echo "FAILED"
      err "$app: deps layer rebuild failed — refusing to deploy on a stale/unbuildable $deps_img"
      printf '%s\n' "$_deps_out" | tail -20 >&2
      DEPLOY_FAILED=1
      continue
    fi
    # Verify-after: the rebuilt image MUST now sit on the current base — if it
    # doesn't, Dockerfile.deps FROMs something other than what we compared
    # against, and deploying would re-ship the exact staleness this gate kills.
    deps_layers="$(docker image inspect "$deps_img" -f '{{json .RootFS.Layers}}' 2>/dev/null || true)"
    if layers_prefix_match "$base_layers" "$deps_layers"; then
      log "$app: $deps_img rebuilt on current $deps_base (verified)"
    else
      err "$app: $deps_img STILL not on $deps_base after rebuild — Dockerfile.deps FROM drift? Refusing to deploy"
      DEPLOY_FAILED=1
    fi
  done

  if (( ${DEPLOY_FAILED:-0} )); then
    err "Phase 2.5 could not produce current bundled package / deps images — aborting BEFORE deploy"
    exit 1
  fi
elif (( ${#APPS[@]} > 0 )) && (( ! PKG_BUILDS || ! BUILD )); then
  warn "skipping bundled package image rebuild + deps staleness gate ($( (( PKG_BUILDS )) && echo --skip-build || echo --skip-pkg-builds )) — bundled <pkg>:latest and <app>-deps:latest images may be STALE vs the synced source"
fi

# ── Phase 3: deploy apps ───────────────────────────────────────────────────
if (( DEPLOY )) && (( ${#APPS[@]} > 0 )); then
  sect "Phase 3: Deploy apps ($MODE mode)"
  for app in "${APPS[@]}"; do
    app_dir="$GYANAM_DIR/apps/$app"
    [[ -d "$app_dir" ]] || { err "app not found: $app_dir"; DEPLOY_FAILED=1; continue; }

    compose_file="compose.${MODE}.yml"
    [[ -f "$app_dir/$compose_file" ]] || compose_file="compose.yml"
    [[ -f "$app_dir/$compose_file" ]] || { err "$app: no compose file (tried compose.${MODE}.yml, compose.yml)"; DEPLOY_FAILED=1; continue; }

    # Base compose file + any mode override layered on top (staging ships a
    # `compose.staging.override.yml` single-worker MCP-test stability fix; it is
    # OPTIONAL and only applied when present — a missing override is fine, but a
    # PRESENT one MUST be included or the 4-worker prod CMD reaps in a loop → 502,
    # which is exactly the failure the override exists to prevent). Generalized as
    # `compose.${MODE}.override.yml` so any mode can carry a local override.
    compose_args=(-f "$compose_file")
    override_file="compose.${MODE}.override.yml"
    if [[ -f "$app_dir/$override_file" ]]; then
      compose_args+=(-f "$override_file")
      echo "  [$app] using $compose_file + $override_file"
    else
      echo "  [$app] using $compose_file"
    fi
    # Prod/staging compose declares `env_file: ${ENV_FILE:-.env.prod}`, but no
    # app ships a `.env.prod` — only `.env`. Without this, compose falls back to
    # a non-existent file and the bring-up fails INSIDE the subshell. Resolve
    # the env file loudly: prefer the mode-specific file, else `.env`, else
    # fail (do NOT silently proceed with a missing env — [[no-silent-try-except]]).
    app_env_file=".env.${MODE}"
    if [[ ! -f "$app_dir/$app_env_file" ]]; then
      if [[ -f "$app_dir/.env" ]]; then
        app_env_file=".env"
      else
        err "$app: no env file (tried .env.${MODE}, .env) — cannot deploy"
        DEPLOY_FAILED=1
        continue
      fi
    fi

    # Surface the subshell's exit status — a failed `docker compose up` must
    # NOT be reported as "restarted". The original printed success
    # unconditionally after the subshell, masking a failed bring-up as exit-0.
    if (
      # NOTE: `set -e` does NOT help here — bash disables errexit inside a
      # subshell used as an `if` condition (POSIX), so each step must check its
      # OWN exit with `|| exit 1` to abort the subshell → the outer `if` sees
      # non-zero → "deploy FAILED" not "[✓] deployed".
      cd "$app_dir" || exit 1
      export ENV_FILE="$app_env_file"

      # Build as its OWN step, BEFORE `up`. `docker compose up --build` can
      # return 0 even when the image BUILD failed (docker/compose#8213 — the
      # up-phase swallows the build exit code, worse under --force-recreate),
      # which is how a broken prod frontend build (`pnpm run build`) printed
      # "[✓] deployed" while zero containers came up. A standalone `build`
      # surfaces the real exit; `|| exit 1` aborts loudly; `up` then only starts
      # already-built images. [[tee-pipe-masks-exit-code]] — no masked exit.
      docker compose "${compose_args[@]}" build || exit 1
      docker compose "${compose_args[@]}" up -d --force-recreate || exit 1

      # Dev bring-up B1 (founder-ratified 2026-06-19): the generated
      # compose.dev.yml delivers domain/common packages via `develop.watch`
      # (#1330 mount-consolidation), which is INERT under plain `up -d`. And
      # activation alone is insufficient: `compose watch` can't combine with
      # `-d`, so it syncs AFTER `up -d`, but dev-entrypoint.sh installs domain
      # packages ONCE at boot against an empty /app/packages/ -> framework-only
      # boot. So: spawn watch (initial sync lands the packages) -> restart the
      # backend so the entrypoint re-installs editable with packages present
      # (`--skip-existing` makes the framework re-scan cheap). Dev-only; prod/
      # staging compose have no watch rules. Mirrors the daksh deployer's
      # activate_dev_watch_with_reinstall (sister PR in ssnukala/lochan).
      if [[ "$MODE" == "dev" ]]; then
        mkdir -p log
        docker compose "${compose_args[@]}" watch >log/compose-watch.log 2>&1 &
        sleep 8   # let the initial sync land the domain/common packages
        docker compose "${compose_args[@]}" restart backend \
          || warn "$app: backend restart after watch sync failed — domain packages may be absent (app could boot framework-only)"
      fi
    ); then
      log "$app: deployed ($compose_file, env=$app_env_file)"
    else
      err "$app: deploy FAILED (docker compose bring-up exited non-zero) — see output above"
      DEPLOY_FAILED=1
    fi
  done
  # Fail the whole run loudly if any app failed to deploy — never exit 0 on a
  # partial/failed deploy ([[no-silent-try-except]]; the old behavior masked
  # Phase-1b/Phase-3 failures as exit-0 "deployed nothing").
  if (( ${DEPLOY_FAILED:-0} )); then
    err "one or more apps failed to deploy"
    exit 1
  fi

  # ── Phase 3b: governed-metric acceptance gate (iter-8 P0 class-prevention) ──
  # A governed metric query MUST execute cleanly against the freshly-deployed
  # app before we call the deploy green. Iteration-8 shipped a live
  # tk_metric_query crash that passed CI (unit tests injected the test-seam), so
  # NOTHING ran a real governed query pre-deploy. This gate closes that class:
  # it hits the synchronous MCP tool-call door (Q-S1-08 = A) and asserts a
  # numeric summary.value + (stale-image check) the deployed image's build-stamp
  # source_commit == the SHA we just built from. Same fail-loud contract as the
  # Phase-1 post-sync + Phase-2.5 staleness gates: a RED here → DEPLOY_FAILED=1.
  #
  # Opt-in is DECLARATIVE + AUTOWIRED (founder-ruled 2026-07-10): a metric
  # self-declares `@metric(..., deploy_gate=True)`. The gate script DISCOVERS the
  # gate-flagged metrics off the LIVE registry (via describe_metrics over the
  # app's domains) — NO per-app .env/manifest hand-config, no drift. An app with
  # zero deploy_gate metrics is a clean no-op (the script reports "none", exit 0).
  GATE_SCRIPT="$GYANAM_DIR/util/scripts/build/verify-governed-metric-gate.sh"
  EXPECTED_SHA="$(git -C "$GYANAM_DIR/framework/lochan" rev-parse HEAD 2>/dev/null || echo '')"
  if [[ -x "$GATE_SCRIPT" ]]; then
    sect "Phase 3b: Governed-metric acceptance gate"
    for app in "${APPS[@]}"; do
      # The script discovers deploy_gate metrics for the app + probes each; it
      # exits 0 when an app has none (clean no-op) or all pass, non-zero on any
      # failure or a stale image.
      sha_arg=(); [[ -n "$EXPECTED_SHA" ]] && sha_arg=(--expected-sha "$EXPECTED_SHA")
      if GYANAM_DIR="$GYANAM_DIR" "$GATE_SCRIPT" "$app" "${sha_arg[@]}"; then
        log "$app: governed-metric gate GREEN"
      else
        err "$app: governed-metric gate FAILED — a deploy_gate metric cannot serve a governed query (iter-8 P0 class) or the image is stale"
        DEPLOY_FAILED=1
      fi
    done
    if (( ${DEPLOY_FAILED:-0} )); then
      err "governed-metric gate failed for one or more apps — refusing to call this deploy green"
      exit 1
    fi
  else
    warn "governed-metric gate script not found at $GATE_SCRIPT — skipping Phase 3b (the iter-8 P0 class is NOT gated this run)"
  fi
elif (( ${#APPS[@]} == 0 )); then
  warn "no apps requested — use --app <name> to deploy one or more"
fi

sect "Done"
log "workspace: $GYANAM_DIR"
log "mode:      $MODE"
log "apps:      ${APPS[*]:-(none)}"
