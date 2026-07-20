#!/usr/bin/env bash
# generate-vectors-for-app.sh — build the committable embed-artifact corpus for
# an app's full dependency closure, for one embedding model. Sibling of
# build-app.sh; the reusable harness behind the gemini→nomic flip (FW10c/FW10d).
#
# Usage:
#   ./util/scripts/build/generate-vectors-for-app.sh <primary-package> <model> [--force] [--dry-run]
#   ./util/scripts/build/generate-vectors-for-app.sh fwprod01 default          # framework nomic corpus
#   ./util/scripts/build/generate-vectors-for-app.sh longterm default          # framework + longterm's domain adds
#   ./util/scripts/build/generate-vectors-for-app.sh fwprod01 gemini --force    # regenerate a named-model addon layer
#
# Params:
#   <primary-package>  an app (apps/<app>) OR a package that provides CONTEXT.
#                      The tool generates for its FULL declared dependency
#                      closure — every package, not the whole monorepo. Same
#                      "declared-closure, not whole-monorepo" principle as
#                      deploy-lochan.sh (#86).
#   <model>            `default` (= the framework runtime default, nomic-embed-text
#                      today, resolved from the container — NOT hardcoded here) or
#                      a named model id (gemini / claude / …) for an FW10d addon.
#
# Flags:
#   --force    regenerate even if the artifact already exists for <model>/<pkg>.
#   --dry-run  print the resolved closure + per-package plan, generate nothing.
#
# WHY THIS SCRIPT EXISTS (founder-designed 2026-07-20):
#   The embed corpus is a COMMITTED SOURCE artifact (like a lockfile / protoc
#   output), NOT a build output. This tool is the DELIBERATE, manually-invoked
#   generator — run when inputs change (new seeds / new model / new package) →
#   commit the corpus. It is deliberately NOT wired into build-app.sh / daksh
#   build: auto-generating on every build would make builds slow, couple them to
#   the ollama endpoint, and break image reproducibility (embeddings vary
#   run-to-run). The image build stays skip-if-present + live-embeds only
#   genuinely-missing packages as a LOUD fallback; the build's job re: the
#   corpus is to VERIFY it exists, not generate it (that check is FW10d).
#
# WHAT IT REUSES (maximize what exists — does NOT re-encode any of these):
#   1. Dep-closure (DOMAIN leg): deploy-lochan.sh repos_app_deps() — derives an
#      app's mandi domain/common adds from apps/<app>/packages.json.
#   2. Framework closure: the container's registered `lochan.packages` entry
#      points (the same set daksh generate-vectors / precompute consumes).
#      repos_app_deps yields ONLY mandi/domain + mandi/common (deploy-lochan.sh
#      DEP_PREFIXES), never framework pkgs — so for a framework-only app like
#      fwprod01 (packages.json = empty) the framework leg MUST come from the
#      entry points, not from repos_app_deps. (S0-ratified GAP#1, 2026-07-20.)
#   3. Per-package generator: `python3 -m gyanam.scripts.precompute_embeddings
#      --model <m> --package <p> [--force]` (what `daksh generate-vectors` wraps)
#      run IN a backend container on --network shared-ai (reaches shared-ollama).
#
# THE CAPTURE MECHANISM (proven by S2 2026-07-18, baked in here):
#   The generator writes to the CONTAINER's site-packages (artifact_path resolves
#   there by design — the build-time flow), which a throwaway/prod container does
#   not surface on the host. So per package we: pick a container that REGISTERS
#   the package as a lochan.packages entry point (framework → any backend-base;
#   domain → its OWN app image) → docker exec the generator → docker cp the .npz
#   OUT → place it at the FW10c committed path:
#     framework/lochan/data/embed-artifacts/<model>/<tier>/<pkg>/ai_intent_seeds_embedded.npz
#   Precedent: the original 17 gemini artifacts were frozen exactly this way
#   (#1642 — "embedded ONCE … committed as durable source of truth").
#
# Memory rules: [[feedback-maximize-usage-of-every-line-already-in-framework]],
#   [[reference-embed-artifacts-preserved-in-data-folder]] (never re-embed a
#   present artifact), [[feedback-no-silent-try-except-fail-loudly-at-boot]]
#   (every failure here logs + exits non-zero; no silent skip).

set -euo pipefail

# ── Resolve paths (mirror build-app.sh) ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GYANAM_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FRAMEWORK_DIR="$GYANAM_DIR/framework/lochan"
ARTIFACT_ROOT="$FRAMEWORK_DIR/data/embed-artifacts"
ARTIFACT_NPZ="ai_intent_seeds_embedded.npz"
SHARED_AI_NET="shared-ai"

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING — REFERENCE IMPLEMENTATION (founder 2026-07-20)
# This block is the canonical logging pattern for Lochan build scripts: get it
# right here, then propagate to build-app.sh / deploy-lochan.sh / the rest, so
# every step of the interactive build wizard reads the same way.
#
# Model (npm-install style): scroll live per-item detail while working, then
# CONSOLIDATE to a clean summary. Design rules:
#   • All human output → stderr; stdout is reserved for a machine-readable
#     summary a wizard/caller can parse (kept clean, never mixed with logs).
#   • Colors + live-overwrite auto-disable when stderr isn't a TTY (piped, CI,
#     captured, wizard-driven) → captured output is one clean line per item.
#   • Honors NO_COLOR (https://no-color.org). --verbose streams the underlying
#     engine firehose; default hides it and surfaces it only on failure.
# ─────────────────────────────────────────────────────────────────────────────
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  _c_dim=$'\033[2m'; _c_bold=$'\033[1m'; _c_grn=$'\033[32m'; _c_yel=$'\033[33m'
  _c_red=$'\033[31m'; _c_cyn=$'\033[36m'; _c_rst=$'\033[0m'; _TTY=1
else
  _c_dim=; _c_bold=; _c_grn=; _c_yel=; _c_red=; _c_cyn=; _c_rst=; _TTY=
fi

step()  { printf '\n%s▸ %s%s\n' "$_c_bold" "$*" "$_c_rst" >&2; }
log()   { printf '  %s\n'        "$*" >&2; }
info()  { printf '  %s%s%s\n'    "$_c_dim" "$*" "$_c_rst" >&2; }
ok()    { printf '  %s✓%s %s\n'  "$_c_grn" "$_c_rst" "$*" >&2; }
skip()  { printf '  %s○%s %s%s%s\n' "$_c_yel" "$_c_rst" "$_c_dim" "$*" "$_c_rst" >&2; }
warn()  { printf '  %s!%s %s\n'  "$_c_yel" "$_c_rst" "$*" >&2; }
die()   { printf '\n%s✗ %s%s\n'  "$_c_red" "$*" "$_c_rst" >&2; exit "${2:-1}"; }

# work <msg> — transient "· msg …" line on a TTY, overwritten by the next
# ok/skip/warn (npm-style). No-op on a non-TTY, so captured output stays 1
# result-line per item. Pair each work() with a clr() before the result line.
work()  { [ -n "$_TTY" ] && printf '  %s· %s …%s\r' "$_c_cyn" "$*" "$_c_rst" >&2 || true; }
clr()   { [ -n "$_TTY" ] && printf '\033[2K\r' >&2 || true; }

# ── Args ──
[ $# -ge 2 ] || die "usage: generate-vectors-for-app.sh <primary-package> <model> [--force] [--dry-run]" 2
PRIMARY="$1"; MODEL_ARG="$2"; shift 2
FORCE=""; DRY_RUN=""; VERBOSE=""
for a in "$@"; do
  case "$a" in
    --force)   FORCE="--force" ;;
    --dry-run) DRY_RUN=1 ;;
    --verbose) VERBOSE=1 ;;
    *) die "unknown flag: $a" 2 ;;
  esac
done

# ── Pick a framework-carrying backend container (source of the entry-point set
#    + the exec host for every FRAMEWORK package). Any running *-backend-* built
#    on lochan-backend-base registers the full framework entry-point set. ──
pick_framework_container() {
  local c
  for c in fwprod01-backend-1 $(docker ps --format '{{.Names}}' | grep -E -- '-backend-1$'); do
    if docker ps --format '{{.Names}}' | grep -qx "$c"; then echo "$c"; return 0; fi
  done
  return 1
}
FW_CONTAINER="$(pick_framework_container)" \
  || die "no running *-backend-1 container found — start one (e.g. 'daksh start fwprod01') so the framework entry points + shared-ollama are reachable."

# ── Resolve <model>: 'default' → the framework runtime default, read FROM the
#    container (gyanam.config), never hardcoded here so it can't drift. ──
if [ "$MODEL_ARG" = "default" ]; then
  # The default = the framework RUNTIME embedding model (the flip target),
  # EmbeddingConfig().runtime.model — read from the container, never hardcoded.
  MODEL="$(docker exec "$FW_CONTAINER" python3 -c \
    'from gyanam.config import EmbeddingConfig; print(EmbeddingConfig().runtime.model)' 2>/dev/null)" \
    || die "could not read the default embedding model from $FW_CONTAINER (gyanam.config.EmbeddingConfig().runtime.model)."
  [ -n "$MODEL" ] || die "default embedding model resolved empty from $FW_CONTAINER."
  log "model 'default' → '$MODEL' (from $FW_CONTAINER gyanam.config)"
else
  MODEL="$MODEL_ARG"
fi

# ── Resolve the FRAMEWORK closure: the container's registered lochan.packages
#    entry-point names. This is the set precompute/generate-vectors operate on. ──
step "Resolving closure for '$PRIMARY' @ '$MODEL'"
# (portable read loop — macOS ships bash 3.2 without mapfile)
FRAMEWORK_PKGS=()
while IFS= read -r _pkg; do
  [ -n "$_pkg" ] && FRAMEWORK_PKGS+=("$_pkg")
done < <(docker exec "$FW_CONTAINER" python3 -c '
from gyanam.services.intent.seed_generator import _lochan_package_entry_points
for ep in _lochan_package_entry_points():
    print(ep.name)
' 2>/dev/null | sort -u)
[ "${#FRAMEWORK_PKGS[@]}" -gt 0 ] || die "zero lochan.packages entry points in $FW_CONTAINER — is it a real backend image?"
log "framework closure: ${#FRAMEWORK_PKGS[@]} packages (from $FW_CONTAINER entry points)"

# ── Resolve the DOMAIN adds via repos_app_deps (its correct, only scope).
#    Only applies when <primary> is an app with a packages.json; a framework-only
#    app (fwprod01, empty packages.json) yields none — exit 2 there is EXPECTED,
#    not fatal, so we probe for the file first and treat 'no domain adds' as ok. ──
#    deploy-lochan.sh is NOT source-safe (no main-guard → sourcing runs its body
#    + exits), so we cannot import repos_app_deps as a library. We apply the SAME
#    derivation it uses (deploy-lochan.sh:239 DEP_PREFIXES over packages.json
#    dev-paths) inline — a ~10-line parse, single source of the RULE (mandi
#    domain/common only), not a wasteful re-encode of a reusable function.
DOMAIN_PKGS=()
if [ -f "$GYANAM_DIR/apps/$PRIMARY/packages.json" ]; then
  while IFS= read -r dep_path; do
    [ -n "$dep_path" ] || continue
    DOMAIN_PKGS+=("$(basename "$dep_path")")        # mandi/<tier>/<pkg> → <pkg>
  done < <(python3 - "$GYANAM_DIR" "$PRIMARY" <<'PY'
import json, os, sys
gyanam_dir, app = sys.argv[1], sys.argv[2]
with open(os.path.join(gyanam_dir, "apps", app, "packages.json")) as f:
    doc = json.load(f)
DEP_PREFIXES = ("mandi/domain/", "mandi/common/")   # == deploy-lochan.sh:239
packages = doc.get("packages", {}) if isinstance(doc, dict) else {}
specs = packages.values() if isinstance(packages, dict) else packages
seen = set()
for spec in specs:
    dev = spec.get("dev", "") if isinstance(spec, dict) else ""
    if not dev:
        continue
    rel = os.path.normpath(os.path.join("apps", app, dev))
    if rel.startswith(DEP_PREFIXES) and rel not in seen:
        seen.add(rel); print(rel)
PY
)
  log "domain adds (packages.json, mandi-only): ${#DOMAIN_PKGS[@]} packages"
else
  log "no apps/$PRIMARY/packages.json → framework-only closure (expected for fwprod01/lochan)."
fi

# ── FW10c committed path for one package. Framework pkgs live under
#    <model>/framework/<pkg>/; domain under <model>/domain/<pkg>/. Tier is
#    decided by which set the pkg came from (framework closure vs domain adds). ──
committed_path() {  # <tier> <pkg>
  echo "$ARTIFACT_ROOT/$MODEL/$1/$2/$ARTIFACT_NPZ"
}

# ── Generate ONE package's artifact in a container that registers it, then
#    docker cp it OUT to the FW10c committed path. Honors skip-if-present. ──
generate_one() {  # <tier> <pkg> <container>
  local tier="$1" pkg="$2" container="$3"
  local dest; dest="$(committed_path "$tier" "$pkg")"

  if [ -z "$FORCE" ] && [ -f "$dest" ]; then
    skip "$tier/$pkg — already present ($MODEL); --force to regenerate"
    PRESENT=$((PRESENT + 1))
    return 0
  fi

  if [ -n "$DRY_RUN" ]; then
    info "plan  $tier/$pkg → $container → ${dest#"$GYANAM_DIR/"}"
    return 0
  fi

  # Resolve the in-container write path FIRST (artifact_path =
  # <install_dir>/data/embed-artifacts/<model>/<npz>). If the package isn't
  # installed here, that's a routing bug → fatal.
  local in_container_path
  in_container_path="$(docker exec "$container" python3 -c "
from gyanam.scripts.precompute_embeddings import _package_install_dir
from gyanam.services.intent.artifact_io import artifact_path
d = _package_install_dir('$pkg')
print(artifact_path(d, '$MODEL') if d else '', end='')
" 2>/dev/null)"
  [ -n "$in_container_path" ] \
    || die "$tier/$pkg: not installed in $container (routing bug — pkg has no install dir here)."

  # In-container generation on shared-ai (exec inherits the container's network,
  # reaching shared-ollama).
  #
  # ⚠ The engine EXITS 1 for a seedless package (verified: aadhaar→1, muulam→0)
  # — it conflates "no intent seeds" (benign) with a real error in its exit code.
  # So we must NOT trust the exit code; we disambiguate by the written .npz (the
  # authoritative signal) + the `no_artifact` log line:
  #   • .npz present            → success: capture it OUT.
  #   • no .npz + no_artifact ln → pure substrate (0 seeds): EXPECTED SKIP.
  #     aadhaar/drasta/shabd are seedless by design; the gemini ground-truth set
  #     omits them too. Do NOT fabricate an empty artifact.
  #   • no .npz + NO no_artifact → a genuine failure (embed error / crash): DIE.
  work "$tier/$pkg — embedding via $MODEL"
  local rc=0 exec_log
  exec_log="$(docker exec "$container" python3 -m gyanam.scripts.precompute_embeddings \
      --model "$MODEL" --package "$pkg" $FORCE 2>&1)" || rc=$?
  # --verbose: stream the engine firehose (npm --loglevel verbose equivalent).
  [ -n "$VERBOSE" ] && printf '%s\n' "$exec_log" | sed 's/^/    /' >&2

  clr
  if ! docker exec "$container" test -f "$in_container_path"; then
    if printf '%s' "$exec_log" | grep -q "ai.embed.no_artifact"; then
      skip "$tier/$pkg — no seeds (pure substrate); no artifact expected"
      SEEDLESS=$((SEEDLESS + 1))
      return 0
    fi
    printf '%s\n' "$exec_log" | tail -15 | sed 's/^/    /' >&2
    die "$tier/$pkg: precompute wrote no artifact and did NOT report 'no seeds' (rc=$rc) — genuine failure."
  fi

  mkdir -p "$(dirname "$dest")"
  docker cp "$container:$in_container_path" "$dest" 2>/dev/null \
    || die "$tier/$pkg: docker cp OUT failed ($container:$in_container_path → $dest)."
  # Consolidated result line (npm-style): per-package seed count + on-disk size.
  # Parse the count from THIS package's `pkg_saved` line specifically
  # (`<pkg>: <N> seeds (<size>MB) → …`) — NOT a bare `[0-9]+ seeds` match, which
  # would grab the corpus-wide "unique seeds after dedup" total instead.
  local n; n="$(printf '%s' "$exec_log" \
    | grep -oE "${pkg}: [0-9]+ seeds" | grep -oE '[0-9]+ seeds' | tail -1)"
  local sz; sz="$(du -h "$dest" | cut -f1 | tr -d ' ')"
  ok "$tier/$pkg${n:+  ${_c_dim}(${n}, ${sz})${_c_rst}}"
  GENERATED=$((GENERATED + 1))
}

# ── For a DOMAIN package, the framework container will NOT register it
#    (_package_install_dir returns None). Find a running container whose image
#    carries it as a lochan.packages entry point. ──
find_domain_container() {  # <pkg>
  local pkg="$1" c
  for c in $(docker ps --format '{{.Names}}' | grep -E -- '-backend-1$'); do
    if docker exec "$c" python3 -c "
from gyanam.scripts.precompute_embeddings import _package_install_dir
import sys; sys.exit(0 if _package_install_dir('$pkg') else 1)
" >/dev/null 2>&1; then echo "$c"; return 0; fi
  done
  return 1
}

# ── Execute ──
step "Generating $MODEL corpus — ${#FRAMEWORK_PKGS[@]} framework + ${#DOMAIN_PKGS[@]} domain package(s)"
GENERATED=0 SEEDLESS=0 PRESENT=0 MISSING_CONTAINER=()

for pkg in "${FRAMEWORK_PKGS[@]}"; do
  generate_one framework "$pkg" "$FW_CONTAINER"
done

for pkg in ${DOMAIN_PKGS[@]+"${DOMAIN_PKGS[@]}"}; do
  dest="$(committed_path domain "$pkg")"
  if [ -z "$FORCE" ] && [ -f "$dest" ]; then
    skip "domain/$pkg — already present ($MODEL)"; PRESENT=$((PRESENT + 1)); continue
  fi
  if dc="$(find_domain_container "$pkg")"; then
    generate_one domain "$pkg" "$dc"
  else
    # Don't abort the whole run: name the gap so the operator can build/start the
    # app image that carries this domain pkg, then re-run (fail-loud at the end).
    warn "domain/$pkg — no running container registers it; build/start its app image, then re-run"
    MISSING_CONTAINER+=("$pkg")
  fi
done

# ── Consolidated summary (npm-install-style: the detail scrolled above, this is
#    the digest). ──
if [ -n "$DRY_RUN" ]; then
  step "Plan"
  log "would process ${#FRAMEWORK_PKGS[@]} framework + ${#DOMAIN_PKGS[@]} domain package(s) @ $MODEL (dry-run — nothing generated)"
  exit 0
fi

step "Summary"
ok   "generated  $GENERATED artifact(s) → ${ARTIFACT_ROOT#"$GYANAM_DIR/"}/$MODEL/"
skip "seedless   $SEEDLESS (pure substrate — no artifact expected)"
[ "$PRESENT" -gt 0 ] && skip "unchanged  $PRESENT (already present; --force to regenerate)"
if [ "${#MISSING_CONTAINER[@]}" -gt 0 ]; then
  die "$((${#MISSING_CONTAINER[@]})) domain pkg(s) had no carrying container: ${MISSING_CONTAINER[*]-} — build/start their app images and re-run." 3
fi
log ""
log "next: review the .npz set, then commit under $MODEL/ (the freeze) via lgit."
