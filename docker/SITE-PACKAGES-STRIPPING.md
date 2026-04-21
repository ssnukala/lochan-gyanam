# Site-Packages Stripping (Pass 2) — Operator Playbook

**Status:** Opt-in, off by default. Launch 1 backend images ship with full
site-packages. Enabling this feature can save an estimated **40–80 MB**
on top of the 216 MB already saved by the 2026-04-20 image-optimization
pass.

**Date:** 2026-04-20
**Scope:** Backend images only. Frontend is already minimal (nginx:alpine).

---

## Table of Contents

1. [What this does](#what-this-does)
2. [Quick start](#quick-start)
3. [How to generate / update the used-list](#how-to-generate--update-the-used-list)
4. [Safety rails](#safety-rails)
5. [What to do if a container crashes](#what-to-do-if-a-container-crashes)
6. [Skiplist — modules that are always kept](#skiplist--modules-that-are-always-kept)
7. [FAQ](#faq)

---

## What this does

1. **Trace:** `util/scripts/trace-site-packages.py` runs a target command
   (test suite, CLI entry point, boot sequence) and records every
   `.py` / `.so` file imported during that run. Writes a newline-delimited
   list to `docker/site-packages-used.txt`.

2. **Strip:** `util/scripts/strip-unused-pyfiles.sh` reads that list and
   deletes every `.py` / `.so` / `.pyc` under site-packages that was NOT
   observed. Runs inside the Docker builder stage, gated by
   `--build-arg STRIP_UNUSED=true`.

Result: a production image that contains only the Python code the app
actually executes. Everything else — test fixtures, docs, unused
provider adapters, dev utilities — is gone.

## Quick start

```bash
# Step 1: generate an initial used-list by tracing whatever you've got.
# Run multiple times against different entry points to accumulate coverage.
cd /Users/srinivasnukala/Dropbox/Sites/docker/gyanam

# App boot:
python3 util/scripts/trace-site-packages.py -- \
    python3 -c "from muulam import create_app; app = create_app()"

# Seeding path:
python3 util/scripts/trace-site-packages.py -- \
    python3 -m muulam.cli seed

# Test suite:
python3 util/scripts/trace-site-packages.py -- \
    pytest framework/lochan/tests -x

# Step 2: inspect the result.
python3 util/scripts/trace-site-packages.py --show

# Step 3: build a stripped image.
docker build \
    -f docker/backend.base.Dockerfile \
    --build-arg STRIP_UNUSED=true \
    -t lochan-backend-base:stripped \
    .

# Step 4: compare sizes.
docker images | grep lochan-backend-base
```

## How to generate / update the used-list

The trace script is additive — every run appends to
`docker/site-packages-used.txt` and re-sorts/deduplicates. Partial
coverage is fine; re-run against more entry points to grow the set.

### Recommended coverage targets

For the Lochan backend, the following traces together give ~90% coverage:

```bash
# 1. App boot — loads muulam + all framework packages.
python3 util/scripts/trace-site-packages.py -- \
    python3 -c "from muulam import create_app; create_app()"

# 2. Seed command — covers pyCRUD + SQLModel write paths.
python3 util/scripts/trace-site-packages.py -- \
    python3 -m muulam.cli seed

# 3. Smoke test suite — covers auth, routes, health.
python3 util/scripts/trace-site-packages.py -- \
    pytest framework/lochan/tests/smoke -x --no-header

# 4. Agentic tests — covers tools, events, contexts.
python3 util/scripts/trace-site-packages.py -- \
    pytest tools/daksh/tests -x --no-header

# 5. Patent coverage verification — covers every claim-tagged path.
python3 util/scripts/trace-site-packages.py -- \
    python3 tools/daksh/scripts/run-patent-coverage.py
```

Commit `docker/site-packages-used.txt` to the repo. Re-regenerate on
every framework release.

## Safety rails

The stripper has three independent safety rails. Any one of them triggers,
no strip happens.

1. **Ancestor `__init__.py` protection.** If ANY file under
   `site-packages/foo/bar/` is in the used-list, both
   `site-packages/foo/__init__.py` and `site-packages/foo/bar/__init__.py`
   are preserved. Without this, Python can't resolve the import chain even
   if the target module is kept.

2. **Lazy-import skiplist.** Pattern-matched list of packages that are
   imported only on specific runtime paths (error handlers, provider
   adapters, format converters) and won't appear in a standard trace.
   Full list below.

3. **80% sanity gate.** If the stripper would delete more than 80% of
   candidate files, it refuses to strip anything and exits cleanly. This
   catches the common "I ran trace against an empty command" footgun.

On top of those, two Docker-level rails:

4. **Opt-in by default.** `STRIP_UNUSED=false` is the default. You
   explicitly pass `--build-arg STRIP_UNUSED=true` to engage.

5. **Dev images never strip.** `docker/backend.dev.Dockerfile` has no
   STRIP_UNUSED arg — dev keeps everything for iteration.

## What to do if a container crashes

### Symptom: `ModuleNotFoundError: No module named 'X'` on startup or mid-request.

**Immediate mitigation (no redeploy needed for the dev/staging path):**

```bash
# Rebuild WITHOUT stripping.
docker build \
    -f docker/backend.base.Dockerfile \
    --build-arg STRIP_UNUSED=false \
    -t lochan-backend-base:latest \
    .

# Or, even simpler — omit the build-arg entirely (default is false):
docker build -f docker/backend.base.Dockerfile -t lochan-backend-base:latest .
```

Your image is back to full size but booting correctly. Now fix the root cause:

### Fix: add the missing module to the used-list.

```bash
# Trace the path that triggered the error.
python3 util/scripts/trace-site-packages.py -- \
    python3 -c "import X; X.the_function_that_raised()"

# Or add the module to the skiplist in strip-unused-pyfiles.sh if
# it's a broad lazy-load pattern (e.g. "all of anthropic/").
```

Then re-trace the happy paths and commit the updated `site-packages-used.txt`.

### Fix: add to the skiplist.

Edit `util/scripts/strip-unused-pyfiles.sh`. The `SKIPLIST_PATTERNS` array
is a list of extended regex patterns matched against
`site-packages/<package>/...` paths. Add your pattern and re-run the
strip. Don't forget to commit both changes together.

## Skiplist — modules that are always kept

The current skiplist (see `util/scripts/strip-unused-pyfiles.sh` for the
source of truth):

| Pattern | Reason |
|---------|--------|
| `pip/`, `setuptools/`, `wheel/` | Python install tooling. Needed if any package does a runtime install. |
| `anthropic/`, `openai/`, `google/generativeai/` | LLM adapters — loaded only when that provider is selected. |
| `asyncpg/`, `httpx/`, `aiohttp/` | Async drivers — first request, not boot. |
| `babel/locale-data/`, `tzdata/`, `zoneinfo/` | Locale/timezone data — lazy-loaded by format paths. |
| `alembic/` | Migration CLI — not imported by running app. |
| `fastapi/`, `starlette/`, `pydantic/`, `pydantic_core/`, `sqlalchemy/`, `sqlmodel/` | Framework deps — the trace is never complete enough to safely strip these. |
| `*.dist-info/`, `*.egg-info/` | Package metadata needed by `pip list`, `importlib.metadata`. |

## FAQ

**Q: What's the expected savings?**
A: Estimated 40–80 MB on the 510 MB backend image. Measured number will
land in `docker/IMAGE-OPTIMIZATION-RESULTS-*.md` after the first stripped
build.

**Q: Does this help with cold-start time?**
A: Mildly. Fewer files to mmap on boot. The dominant cost is still
interpreter startup + framework-package discovery.

**Q: Does the used-list change when I upgrade Python (3.13 → 3.14)?**
A: Paths are stored as `site-packages/foo.py` (no Python version in the
prefix), so the list is portable across minor versions. Major upgrades
(3 → 4) would require re-tracing.

**Q: Can I run the trace inside a running container?**
A: Yes. `docker compose exec backend python3 /app/util/scripts/trace-site-packages.py -- pytest`.
The resulting file lives inside the container; copy it out with
`docker cp` and commit to the repo.

**Q: What about dev images?**
A: Dev images (`docker/backend.dev.Dockerfile`) don't accept the
`STRIP_UNUSED` arg at all. Dev keeps full site-packages for
iteration — you need pip, pytest, IPython, etc., most of which a
happy-path trace would miss.
