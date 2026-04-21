# lochan-gyanam

Workspace bootstrap for a [Lochan](https://github.com/ssnukala/lochan) deployment.
Cloned at the **root** of the gyanam workspace. Holds the Docker build context,
deploy scripts, and the canonical list of repos that the workspace composes.

## What's here

```
/
├── docker/          # Dockerfiles — the framework build context.
│                    # Build from this root (docker build -f docker/... .).
├── scripts/
│   ├── deploy-lochan.sh    # Reusable deploy (clone/pull, build, restart).
│   ├── deploy-all.sh       # Legacy full-deploy (kept for parity; prefer deploy-lochan.sh).
│   └── restart.sh          # Quick frontend-only restart.
├── repos.json       # Canonical list: framework repos, common packages,
│                    # domain packages. Script reads this.
└── README.md        # this file
```

Everything else in the workspace — `framework/lochan/`, `tools/daksh/`,
`mandi/common/*`, `mandi/domain/*`, `apps/*` — lives in its own git repo and
is ignored here (see `.gitignore`). `deploy-lochan.sh` clones or pulls each
one as needed.

## Bootstrap a fresh server

```bash
mkdir -p /home/apps/gyanam && cd /home/apps/gyanam
git clone https://github.com/ssnukala/lochan-gyanam.git .
./scripts/deploy-lochan.sh --prod --app fwprod01
```

That's it. The script reads `repos.json`, clones every framework + common
repo, clones the domain repos needed for `fwprod01` (in this case: none —
`fwprod01` is a framework-only app), builds the Tier 0 + Tier 1 base images,
and starts the app in prod mode.

## Day-to-day usage

```bash
# Refresh everything and redeploy the main app in prod:
./scripts/deploy-lochan.sh --prod --app fwprod01

# Deploy several apps in one run:
./scripts/deploy-lochan.sh --prod --app fwprod01 --app lifestyle01 --app longterm01

# Dev mode (uses compose.dev.yml with volume mounts, hot reload):
./scripts/deploy-lochan.sh --dev --app fwprod01

# Just refresh repos (no rebuild, no restart):
./scripts/deploy-lochan.sh --pull-only

# Reuse existing clones without pulling (useful during iteration):
./scripts/deploy-lochan.sh --skip-pull --app fwprod01

# Skip base-image rebuild (when only compose.yml or app config changed):
./scripts/deploy-lochan.sh --skip-build --app fwprod01
```

## Adding a new common package

Common packages live in `mandi/common/*` and are pulled on **every** deploy.
To add one:

1. Create the GitHub repo (e.g. `ssnukala/lochan-newpkg`).
2. Add one line to `repos.json` under `mandi_common`:

   ```json
   { "path": "mandi/common/newpkg", "url": "https://github.com/ssnukala/lochan-newpkg.git" }
   ```

3. PR this repo. On the next deploy the new package gets cloned automatically.

## Adding a new domain app

Domain packages live in `mandi/domain/*` and are pulled **only when the
corresponding `--app` is requested**. To wire a new one:

1. Create the domain-package repo (e.g. `ssnukala/lochan-foobar`).
2. Create the app dir (e.g. `ssnukala/lochan` contributes `apps/foobar01/`).
3. Add two entries to `repos.json`:

   ```json
   "mandi_domain": [
     { "path": "mandi/domain/foobar", "url": "https://github.com/ssnukala/lochan-foobar.git" }
   ],
   "app_to_domains": {
     "foobar01": ["mandi/domain/foobar"]
   }
   ```

4. `./scripts/deploy-lochan.sh --prod --app foobar01` and you're live.

## Boundaries (things intentionally *not* here)

- **Framework code** — lives in `ssnukala/lochan` (`framework/lochan/`).
- **CLI tooling** — lives in `ssnukala/lochan-daksh` (`tools/daksh/`).
- **Packages** — each common / domain package is its own repo under
  `mandi/common/*` or `mandi/domain/*`.
- **Apps** — each app (`apps/<name>/`) is directory inside its framework
  repo (currently `apps/` lives in `ssnukala/lochan` itself).
- **Personal founder scripts** — `util/` lives in a separate **private**
  repo (`ssnukala/lochan-util`), never deployed to servers.

If a change crosses one of those boundaries, it probably belongs in that
other repo's PR, not this one.
