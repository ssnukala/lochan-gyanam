#!/usr/bin/env python3
"""verify-app-domains.py — verify repos.json `app_to_domains` against each app's
generated apps/<app>/packages.json (the encoding that is already the truth of
what the app needs — this script VERIFIES it, it does not re-encode it).

Why this exists (2026-07-02 incident): app_to_domains.longterm01 listed only
mandi/domain/longterm while apps/longterm01/packages.json needed longterm +
flow + vyaparam, so deploy-lochan.sh Phase-1b never synced flow/vyaparam and
the server app build failed. This check makes that whole class impossible to
hit silently again: deploy-lochan.sh runs it per requested --app and aborts
loudly on any gap.

Checks per app:
  1. The set of mandi/domain dev-paths derived from apps/<app>/packages.json
     must EQUAL app_to_domains[<app>] (missing entry = deploy won't sync it;
     stale extra = the encoding is lying — both are errors).
  2. Every domain path involved must resolve to a URL in the mandi_domain
     registry (second half of the incident: flow had no registry entry at all,
     so even a correct app_to_domains row could not have cloned it).

Modes:
  --app <name>   verify ONE app; everything is a hard ERROR (exit 1). Used by
                 deploy-lochan.sh at the consumption point. An app with no
                 generated packages.json yet is skipped with a note (fresh
                 bootstrap: apps/ is generated after repo sync).
  --all          audit every apps/*/packages.json (skips apps/shared and
                 *-bak backups). An app that has domain needs but no
                 app_to_domains entry at all is a WARNING here (a local-only
                 app is not declared for deploy; deploying it would make this
                 an ERROR via --app), every other mismatch is an ERROR.

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
    """Domain repo paths the app's packages.json actually points at, or None
    if the app has no generated packages.json (not an error: apps/ is
    generated, so a fresh bootstrap legitimately lacks it)."""
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
    a2d = repos.get("app_to_domains", {})
    registry_urls = {
        e["path"]: e.get("url", "")
        for e in repos.get("mandi_domain", [])
        if isinstance(e, dict) and e.get("path")
    }

    derived = derived_domains(gyanam_dir, app)
    if derived is None:
        warnings.append(f"{app}: no apps/{app}/packages.json — skipped (app not generated yet)")
        return errors, warnings

    mapped = a2d.get(app)
    if mapped is None:
        if derived:
            msg = (f"{app}: needs {', '.join(derived)} but has NO app_to_domains entry "
                   f"— deploy would sync nothing for it")
            (errors if entry_required else warnings).append(msg)
        # no entry + no domain needs = a framework-only local app; nothing to check
    else:
        mapped = sorted(p for p in mapped if isinstance(p, str))
        missing = sorted(set(derived) - set(mapped))
        stale = sorted(set(mapped) - set(derived))
        if missing:
            errors.append(f"{app}: app_to_domains is MISSING {', '.join(missing)} "
                          f"(packages.json needs them; deploy Phase-1b will not sync them)")
        if stale:
            errors.append(f"{app}: app_to_domains lists {', '.join(stale)} "
                          f"which packages.json does not need (stale entry)")

    # Registry completeness: skip the derived side for an app that is not
    # declared for deploy at all in an advisory sweep (same rationale as above).
    check_paths = set(mapped or [])
    if mapped is not None or entry_required:
        check_paths |= set(derived)
    for path in sorted(check_paths):
        if not registry_urls.get(path):
            errors.append(f"{app}: {path} has no URL in the mandi_domain registry "
                          f"— it can never be cloned")
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
        # --app = the deploy consumption point → an unmapped app is a hard error;
        # --all sweep → advisory for local-only apps never declared for deploy.
        entry_required = app in args.app
        errors, warnings = verify_app(app, repos, gyanam_dir, entry_required)
        for w in warnings:
            print(f"NOTE  {w}")
        for e in errors:
            print(f"ERROR {e}", file=sys.stderr)
        all_errors.extend(errors)

    if all_errors:
        print(f"\napp_to_domains verification FAILED: {len(all_errors)} error(s). "
              f"Fix repos.json (app_to_domains and/or mandi_domain registry).", file=sys.stderr)
        return 1
    print(f"app_to_domains verified clean for {len(apps)} app(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
