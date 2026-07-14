#!/usr/bin/env python3
"""verify-app-domains.py — verify each app's DERIVED domain set resolves in the
`mandi_domain` registry.

B1 (2026-07-13): the deploy now DERIVES an app's domain set directly from
`apps/<app>/packages.json` (deploy-lochan.sh `repos_app_domains`), which is the
single source of truth — it is what the generated Dockerfile COPYs its domain
packages from. So the old `app_to_domains` block in repos.json is RETIRED, and
with it the app_to_domains-vs-packages.json DRIFT check this script used to do
(the two can no longer disagree — there is only one source). What survives is
the OTHER half of the 2026-07-02 outage class:

  Every domain path an app derives from packages.json MUST resolve to a URL in
  the `mandi_domain` registry — else it can never be cloned (flow had no
  registry entry at all, so even a correct mapping could not have cloned it).

Checks per app:
  1. The app has a generated `packages.json` (fail loud if not — cannot derive
     the domain set; a deploy that cannot derive must abort, not silently sync
     zero domains).
  2. Every `mandi/domain/<pkg>` dev-path derived from that packages.json
     resolves to a URL in the `mandi_domain` registry.

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


def load_json(path):
    with open(path) as f:
        return json.load(f)


def derived_domains(gyanam_dir, app):
    """Domain repo paths the app's packages.json points at, or None if the app
    has no generated packages.json.

    This is the single source of truth the deploy derives its clone-set from
    (mirrored in deploy-lochan.sh `repos_app_domains`)."""
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
        if rel.startswith(DOMAIN_PREFIX):
            needs.add(rel)
    return sorted(needs)


def verify_app(app, repos, gyanam_dir, entry_required):
    """Returns (errors, warnings) message lists for one app."""
    errors, warnings = [], []
    registry_urls = {
        e["path"]: e.get("url", "")
        for e in repos.get("mandi_domain", [])
        if isinstance(e, dict) and e.get("path")
    }

    derived = derived_domains(gyanam_dir, app)
    if derived is None:
        # No generated packages.json → cannot derive. A hard error at the deploy
        # consumption point (--app); an advisory NOTE in the --all sweep.
        msg = (f"{app}: no apps/{app}/packages.json — cannot derive its domain "
               f"set (generate it before deploying)")
        (errors if entry_required else warnings).append(msg)
        return errors, warnings

    # Registry completeness: every derived domain must have a clone URL.
    for path in derived:
        if not registry_urls.get(path):
            errors.append(f"{app}: {path} (needed per packages.json) has no URL "
                          f"in the mandi_domain registry — it can never be cloned")
    return errors, warnings


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

    if all_errors:
        print(f"\nderived-domain verification FAILED: {len(all_errors)} error(s). "
              f"Fix the mandi_domain registry / regenerate packages.json.", file=sys.stderr)
        return 1
    print(f"derived domains verified clean for {len(apps)} app(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
