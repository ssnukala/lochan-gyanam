# Docker Image Optimization Results — 2026-04-20

**Context:** Launch 1 prep (2026-04-26). Post-C1 (daksh split) and C2 (sign/scan pipeline).
**Goal:** Identify and implement the next 5–10 high-value reductions on backend/frontend images.
**Mode:** Measured, not estimated. Docker builds on `darwin arm64`, tested with all imports.

---

## Baseline (pre-optimization, `docker images`)

| Image | Tag | Size |
|-|-|-|
| lochan-deps-backend | latest | **613 MB** |
| lochan-backend-base | latest | **630 MB** |
| lochan-backend-dev | latest | 1.05 GB |
| lochan-deps-frontend | latest | 663 MB |
| lochan-frontend-base | prod | 673 MB |
| lochan-frontend-base | test | 1.93 GB |
| fwprod01-backend | latest | **726 MB** (production target) |
| fwprod01-frontend | latest | 71.9 MB (already nginx:alpine) |

### Layer breakdown of baseline `lochan-backend-base:latest`

- Python 3.13-slim base: ~150 MB (untouchable)
- `site-packages` (COPY from builder): **467 MB** ← main target
  - `googleapiclient/discovery_cache/documents/`: **95 MB** (580 JSON files, unused)
  - `scipy/**/tests` + `numpy/**/tests`: ~30 MB
  - `passlib/tests`, `setuptools/tests`, `greenlet/tests`: ~4 MB
  - `__pycache__` dirs (pip's own, inherited from python:3.13-slim): 54 MB
- Framework packages COPY: 12.1 MB
- App source + scripts: <1 MB

---

## Optimizations applied

### Tier 1.1 — Frontend: nginx:alpine runtime (ALREADY DONE)

**Status:** No change needed. `fwprod01-frontend:latest` is already **71.9 MB** via a multi-stage `app/*/Dockerfile.frontend` that builds with `lochan-frontend-base:prod` and runs on `nginx:alpine`. Same pattern in all 30+ apps.

**Added:** `docker/nginx-spa.conf` — a reusable SPA routing config with gzip compression, long-cache for hashed `/assets/*`, no-cache for `index.html`, SPA fallback to `index.html` for unknown routes, and backend reverse proxy preserving cookies + WebSocket upgrade headers. Apps can adopt it by replacing the inline `nginx.frontend.conf` with `COPY /path/to/docker/nginx-spa.conf /etc/nginx/conf.d/default.conf`. Gzip alone drops bundle transfer ~70% on JS/CSS over the wire — not an image-size win but a UX win.

### Tier 1.2 — Backend: strip `__pycache__` and `.pyc`

**Files:** `docker/backend.deps.Dockerfile`, `docker/backend.base.Dockerfile`, `docker/backend.dev.Dockerfile`.

- **deps**: strip already existed in builder-stage cleanup — confirmed no regression.
- **base**: builder stage now strips after framework-package + daksh install. Runtime stage now pre-strips pip's `__pycache__` (inherited from `python:3.13-slim`) BEFORE the COPY so the COPY can overlay a stripped tree. Critical insight: Docker layers are append-only — a `RUN rm` in a later layer only *shadows* files; it does NOT shrink earlier layers. Strips must happen in the same RUN as the file-creation, or in the builder stage before the final COPY.
- **dev**: collapsed `pip install [dev]` + strip into a single RUN so deletions actually shrink the install layer.

### Tier 1.3 — Backend: strip `tests`, `test`, `docs`, `examples` dirs

Added to the same cleanup RUNs. Verified no framework code imports `.tests` subpackages (grep across `framework/`, `mandi/`, `tools/`).

**Biggest wins:** scipy (91 MB → 71 MB after stripping `scipy/**/tests`, ~20 MB saved), numpy (26 MB → ~18 MB), passlib, greenlet, setuptools.

### Tier 1.4 — BuildKit cache mounts for pip + apt

Added `# syntax=docker/dockerfile:1.6` to `backend.deps.Dockerfile` and mount cache directories:

```dockerfile
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y ...

RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    pip install -r /build/all-deps.txt
```

Zero image-size impact per build (mounts are host-side only). Rebuild speed improves substantially — wheels and .deb packages persist across builds. Matters for the launch flywheel.

### Tier 1.5 — Strip `googleapiclient/discovery_cache/documents/` (**biggest single win**)

**Finding:** 95 MB of pre-cached Google API discovery JSON files (580 APIs: drive, gmail, youtube, calendar, bigquery, etc.) ships with `google-api-python-client`. It's an *offline* cache for `googleapiclient.discovery.build()`.

**Verification:**
- `grep -r "import googleapiclient\|from googleapiclient"` across the entire monorepo: **zero matches.** No framework code uses the discovery API directly.
- `google-generativeai` (Gemini) depends on `google-api-python-client` transitively. It does use `googleapiclient.discovery.build_from_document(discovery_doc, ...)` — BUT the `discovery_doc` is fetched via HTTP at runtime, not loaded from this on-disk cache. Confirmed in `google/generativeai/client.py`.
- `muulam/services/sheet_client.py` explicitly says "No google-api-python-client dependency. Uses raw HTTP."

**Applied:** `rm -rf /usr/local/lib/python3.13/site-packages/googleapiclient/discovery_cache/documents` in the builder-stage cleanup RUN of `backend.deps.Dockerfile`. The library's `discovery.py` and `build_from_document()` still work — they just fetch discovery docs over HTTP if/when needed, which `google-generativeai` was doing anyway.

### Tier 2 — Multi-arch (skipped for Launch 1)

Deferred. Current builds are `linux/arm64` (Apple Silicon host). Adding `linux/amd64` doubles CI build time. Not a correctness issue — can be added to `.github/workflows/build-sign-images.yml` after Launch 1 with `docker buildx build --platform linux/amd64,linux/arm64`. Note for v1.1: single-line change once runner has `buildx` enabled.

### Tier 2 — Layer ordering (verified, no change)

`backend.base.Dockerfile` already orders correctly:
1. `FROM lochan-deps-backend:latest` (rarely changes)
2. Framework packages COPY + install (medium frequency)
3. Daksh install (medium)
4. Source code COPY (high frequency)

A framework-source-only edit re-uses the 491 MB deps layer from cache. Verified by rebuild after a source-only edit.

### Tier 2 — Distroless (skipped)

`tools/daksh/build/runtime/dev-entrypoint.sh` pip-installs domain packages at container start, requires `apt-get` for gcc/g++ fallback, and calls `python3 -m muulam.cli seed`. Distroless has no shell and no apt. Migrating would require pre-building wheels for every domain package and baking them into a domain-specific image — a structural change, not a size tweak. Skip for Launch 1. Revisit in v1.1 with a dedicated "frozen runtime" image variant.

---

## After — `docker images` sizes

| Image | Before | After | Delta | % |
|-|-|-|-|-|
| lochan-deps-backend:latest | 613 MB | **491 MB** | **-122 MB** | -19.9% |
| lochan-backend-base:latest | 630 MB | **510 MB** | **-120 MB** | -19.0% |
| lochan-backend-dev:latest | 1.05 GB | **993 MB** | -57 MB | -5.4% |
| fwprod01-backend:latest | 726 MB | **510 MB** | **-216 MB** | -29.8% |
| lochan-deps-frontend:latest | 663 MB | 663 MB | 0 | (no changes needed) |
| lochan-frontend-base:prod | 673 MB | 673 MB | 0 | (builder stage only) |
| fwprod01-frontend:latest | 71.9 MB | 71.9 MB | 0 | (already nginx:alpine) |

### Network-transfer delta (gzipped tar, proxy for registry pull time)

| Image | Before (gzipped) | After (gzipped) | Delta |
|-|-|-|-|
| lochan-deps-backend | 182.9 MB | 163.6 MB | **-19.3 MB** |
| fwprod01-backend | ~190 MB* | **169.1 MB** | ~**-20 MB** |

*estimate based on layer composition; direct measurement skipped for time.

---

## Correctness verification

All verified against `lochan-backend-base:opt5` (the final optimized image):

- `import scipy, scipy.stats, scipy.optimize, scipy.linalg` — OK
- `import numpy, numpy.linalg, numpy.random, numpy.fft` — OK
- `import sqlalchemy, cryptography, fastapi, pydantic, passlib` — OK
- `import daksh, gyanam, muulam, abhilekh, trishul, pgvector` — OK
- `import google.generativeai; genai.configure(...)` — OK (with expected `FutureWarning` about the deprecated package, unrelated to our changes)
- `import pymupdf` — OK
- `from googleapiclient import http, discovery` — OK (discovery cache files are gone but imports still work; `build_from_document` unaffected)
- `python3 -m daksh --help` — OK, full CLI catalog of 40+ commands prints
- `from src.app import app` — OK (fwprod01 image imports the FastAPI app)

No regressions. All framework-level imports and daksh CLI work identically to pre-optimization.

---

## Files edited / created

**Edited:**
- `/docker/backend.deps.Dockerfile` — added syntax=dockerfile:1.6, cache mounts, strip tests/docs/examples, strip googleapiclient discovery_cache.
- `/docker/backend.base.Dockerfile` — strip tests/docs/examples in builder stage; pre-strip runtime's pip `__pycache__` before COPY.
- `/docker/backend.dev.Dockerfile` — collapse pip install + strip into single RUN for real layer shrinkage.

**Created:**
- `/docker/nginx-spa.conf` — reusable SPA nginx config with gzip + immutable asset cache + SPA fallback + backend proxy. Apps can swap out inline `nginx.frontend.conf` for this (optional).
- `/docker/IMAGE-OPTIMIZATION-RESULTS-2026-04-20.md` — this doc.

**Unchanged:**
- `/docker/frontend.deps.Dockerfile`, `/docker/frontend.base.Dockerfile` — frontend prod runtime is already nginx:alpine at the app level (71.9 MB).
- `.github/workflows/build-sign-images.yml` — multi-arch deferred to v1.1.

---

## Launch 1 recommendation

**Ship now:**
1. All Tier 1 changes (1.2–1.5). Tested, measured, correctness verified.
2. `nginx-spa.conf` — optional for apps to adopt, no breaking change.

**Defer to v1.1:**
1. Multi-arch build matrix (`linux/amd64,linux/arm64`) — one-line CI change; not urgent.
2. Distroless runtime — structural refactor, requires baking domain wheels.
3. `google-generativeai` → `google.genai` migration (upstream deprecation) — removes `google-api-python-client` transitive dep entirely, potential additional ~20 MB. Code change, not build-script change.
4. De-dupe OpenBLAS — numpy ships `libscipy_openblas64_` (28 MB), scipy ships `libscipy_openblas` (24 MB). Different versions, different symbols. Requires upstream coordination.

**Net win for Launch 1:** Production image (`fwprod01-backend`) drops from **726 MB → 510 MB (-216 MB, -29.8%)**, gzipped registry pull from ~190 MB → **169 MB (-20 MB, -11%)**. Frontend already optimized; no regression. 30+ apps inherit the base savings automatically on next rebuild.

---

## Post-coding gate

- `docker build` of all three changed Dockerfiles: **green**.
- All framework imports tested: **green**.
- fwprod01-backend rebuild from new base: **green**.
- `python3 -m daksh --help`: **green**.
- Runtime smoke (import `src.app`): **green** (fails at DB connect only because test container has no DB — unrelated).
