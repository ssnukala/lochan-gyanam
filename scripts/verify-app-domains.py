#!/usr/bin/env python3
"""verify-app-domains.py — verify each app's DERIVED dep set (domain + common)
resolves to a clone URL in the registry.

B1 (2026-07-13): the deploy now DERIVES an app's dep set directly from
`apps/<app>/packages.json` (deploy-lochan.sh `repos_app_deps`), which is the
single source of truth — it is what the generated Dockerfile COPYs its
packages from. So the old `app_to_domains` block in repos.json is RETIRED, and
with it the app_to_domains-vs-packages.json DRIFT check this script used to do
(the two can no longer disagree — there is only one source). What survives is
the OTHER half of the 2026-07-02 outage class:

  Every dep path an app derives from packages.json MUST resolve to a URL — else
  it can never be cloned (flow had no registry entry at all, so even a correct
  mapping could not have cloned it).

B4 (2026-07-17): the per-app check now covers BOTH `mandi/domain/` and
`mandi/common/` deps, matching deploy-lochan.sh's widened Phase-1b dep-scoped
sync — so a missing COMMON url (e.g. arthik) also aborts in Phase 0, before any
build, instead of surfacing later in the Phase-1b clone loop.

Checks per app:
  1. The app has a generated `packages.json` (fail loud if not — cannot derive
     the dep set; a deploy that cannot derive must abort, not silently sync
     zero deps).
  2. Every `mandi/{domain,common}/<pkg>` dev-path derived from that
     packages.json resolves to a URL (own mandi.json first, then the registry).

Modes:
  --app <name>   verify ONE app; everything is a hard ERROR (exit 1). Used by
                 deploy-lochan.sh Phase-0 at the consumption point.
  --all          audit every apps/*/packages.json (skips apps/shared and
                 *-bak backups). Registry gaps are errors; a fresh app with no
                 packages.json is a NOTE (not deployed here, so not an error in
                 an advisory sweep — but a hard error via --app at deploy time).

Exit: 0 = clean, 1 = at least one ERROR.
"""

import argparse
import json
import os
import sys

DOMAIN_PREFIX = "mandi/domain/"
DEP_PREFIXES = ("mandi/domain/", "mandi/common/")


def load_json(path):
    with open(path) as f:
        return json.load(f)


def derived_deps(gyanam_dir, app):
    """Every mandi dep repo path (domain + common) the app's packages.json points
    at, or None if the app has no generated packages.json.

    This is the single source of truth the deploy derives its clone-set from
    (mirrored in deploy-lochan.sh `repos_app_deps`)."""
    pkg_file = os.path.join(gyanam_dir, "apps", app, "packages.json")
    if not os.path.isfile(pkg_file):
        return None
    doc = load_json(pkg_file)
    needs = set()
    packages = doc.get("packages", {}) if isinstance(doc, dict) else {}
    values = packages.values() if isinstance(packages, dict) else packages
    for spec in values:
        dev = spec.get("dev", "") if isinstance(spec, dict) else ""
        if not dev:
            continue
        rel = os.path.normpath(os.path.join("apps", app, dev))
        if rel.startswith(DEP_PREFIXES):
            needs.add(rel)
    return sorted(needs)


def scan_domain_dirs(gyanam_dir):
    """DERIVE which mandi/domain/<pkg> paths exist by scanning the directory
    (B2, 2026-07-13). Excludes ``*-bak`` backups and dot-dirs. Replaces the
    hand-maintained repos.json mandi_domain path-list (which drifted: 14 dirs
    on disk vs 12 registry entries).

    Scans by DIRECTORY existence, not mandi.json presence — some real domains
    (e.g. duta, a cross-cutting substrate domain) carry no mandi.json but are
    valid clone targets via the registry. A domain is "real" iff it is a
    non-backup directory under mandi/domain/; whether it resolves to a url is
    the separate completeness check (verify_domain_registry)."""
    base = os.path.join(gyanam_dir, "mandi", "domain")
    if not os.path.isdir(base):
        return []
    found = []
    for name in sorted(os.listdir(base)):
        if name.endswith("-bak") or name.startswith("."):
            continue
        d = os.path.join(base, name)
        if not os.path.isdir(d):
            continue
        # Exclude wrap-baseline artifacts (a legacy app captured as a wrap
        # reference, e.g. opencats — migrated_from + 'wrap-baseline' tag) — they
        # are not standalone deployable domain repos.
        mj = os.path.join(d, "mandi.json")
        if os.path.isfile(mj):
            try:
                cfg = load_json(mj) or {}
                if cfg.get("migrated_from") or "wrap-baseline" in (cfg.get("tags") or []):
                    continue
            except (json.JSONDecodeError, OSError):
                pass
        found.append(f"mandi/domain/{name}")
    return found


def resolve_dep_url(gyanam_dir, repos, dep_path):
    """Resolve a dep path's clone URL — PREFER its own mandi.json ``repo``
    (the canonical url field in mandi.json), FALL BACK to the repos.json
    registry (B2). B4: the fallback searches BOTH mandi_domain and mandi_common,
    so a common dep (arthik) resolves from its own bucket. Returns "" if neither
    source has a url. Mirrors deploy-lochan.sh repos_dep_url."""
    mj = os.path.join(gyanam_dir, dep_path, "mandi.json")
    if os.path.isfile(mj):
        try:
            url = (load_json(mj) or {}).get("repo", "")
            if url:
                return url
        except (json.JSONDecodeError, OSError):
            pass
    for bucket in ("mandi_domain", "mandi_common"):
        for e in repos.get(bucket, []):
            if isinstance(e, dict) and e.get("path") == dep_path:
                return e.get("url", "")
    return ""


def verify_app(app, repos, gyanam_dir, entry_required):
    """Returns (errors, warnings) message lists for one app."""
    errors, warnings = [], []

    derived = derived_deps(gyanam_dir, app)
    if derived is None:
        # No generated packages.json → cannot derive. A hard error at the deploy
        # consumption point (--app); an advisory NOTE in the --all sweep.
        msg = (f"{app}: no apps/{app}/packages.json — cannot derive its dep "
               f"set (generate it before deploying)")
        (errors if entry_required else warnings).append(msg)
        return errors, warnings

    # URL completeness: every dep (domain + common) the app derives from
    # packages.json must resolve to a clone URL (own mandi.json first, then the
    # registry — either bucket).
    for path in derived:
        if not resolve_dep_url(gyanam_dir, repos, path):
            errors.append(f"{app}: {path} (needed per packages.json) resolves to "
                          f"NO url (checked mandi.json + mandi_domain/mandi_common "
                          f"registry) — it can never be cloned")
    return errors, warnings


def verify_domain_registry(repos, gyanam_dir):
    """Registry-completeness over the SCANNED domain dirs (B2): every existing
    mandi/domain/<pkg> (with a mandi.json, non-backup) must resolve to a url.
    This surfaces the 14-vs-12 drift (a domain dir on disk with no clone url)
    without hand-listing which paths exist."""
    errors = []
    for path in scan_domain_dirs(gyanam_dir):
        if not resolve_dep_url(gyanam_dir, repos, path):
            errors.append(f"{path}: domain dir exists (has mandi.json) but resolves "
                          f"to NO url (mandi.json + mandi_domain registry) — cannot clone")
    return errors


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--app", action="append", default=[], help="verify one app (repeatable)")
    ap.add_argument("--all", action="store_true", help="audit every generated app")
    ap.add_argument("--gyanam", default=None, help="gyanam workspace root (default: parent of this script's dir)")
    args = ap.parse_args()
    if not args.app and not args.all:
        ap.error("pass --app <name> and/or --all")

    gyanam_dir = args.gyanam or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    repos = load_json(os.path.join(gyanam_dir, "repos.json"))

    apps = list(args.app)
    if args.all:
        apps_dir = os.path.join(gyanam_dir, "apps")
        for name in sorted(os.listdir(apps_dir)) if os.path.isdir(apps_dir) else []:
            if name == "shared" or name.endswith("-bak"):
                continue
            if os.path.isfile(os.path.join(apps_dir, name, "packages.json")) and name not in apps:
                apps.append(name)

    all_errors = []
    for app in apps:
        # --app = the deploy consumption point → a missing packages.json is a
        # hard error; --all sweep → advisory NOTE for not-yet-generated apps.
        entry_required = app in args.app
        errors, warnings = verify_app(app, repos, gyanam_dir, entry_required)
        for w in warnings:
            print(f"NOTE  {w}")
        for e in errors:
            print(f"ERROR {e}", file=sys.stderr)
        all_errors.extend(errors)

    # B2: on a full sweep, also audit the DERIVED domain registry — every
    # mandi/domain/<pkg> that exists on disk must resolve to a clone url. This
    # is the 14-vs-12 drift guard, now structural (dir-scan, not a hand-list).
    if args.all:
        for e in verify_domain_registry(repos, gyanam_dir):
            print(f"ERROR {e}", file=sys.stderr)
            all_errors.append(e)

    if all_errors:
        print(f"\ndep verification FAILED: {len(all_errors)} error(s). "
              f"Fix the mandi_domain/mandi_common registry / mandi.json url / regenerate packages.json.",
              file=sys.stderr)
        return 1
    print(f"deps verified clean for {len(apps)} app(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
