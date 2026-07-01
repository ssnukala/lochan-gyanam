# syntax=docker/dockerfile:1.6
# lochan-backend-base — Complete framework backend image (Tier 1 flywheel)
#
# NOTE: the syntax directive above pins the BuildKit dockerfile frontend — REQUIRED
# for the §BUILD-STAGE-PRECOMPUTE ``RUN --mount=type=secret,...,required=false``
# below (secret mounts + required=false are BuildKit-frontend features). Matches
# the ``# syntax=docker/dockerfile:1.6`` the generated app Dockerfile.deps pins.
#
# Contains: All deps (from Tier 0) + framework packages + daksh + source code.
# This image IS a runnable app (empty, no domain packages).
#
# Requires: lochan-deps-backend:latest (Tier 0 — build with docker/01-backend-deps.Dockerfile)
#
# Build (from gyanam/ root):
#   docker build -f docker/02-backend-base.Dockerfile -t lochan-backend-base:latest .
#
# Layer domain packages on top:
#   FROM lochan-backend-base
#   COPY --from=lifelight:latest /pkg/ /app/packages/lifelight/
#   RUN python3 /app/scripts/install-packages.py /app/packages/

# -- Build stage: install framework packages (deps already in base) ----
FROM lochan-deps-backend:latest AS builder
WORKDIR /build

# 1. Framework packages — deps pre-installed in Tier 0, just register entry points
COPY framework/lochan/packages/daksh/backend/daksh/runtime/install-framework-packages.py /build/install-framework-packages.py
COPY framework/lochan/packages/ /build/packages/
RUN python3 /build/install-framework-packages.py /build/packages --install

# §BUILD-STAGE-PRECOMPUTE (S3, 2026-07-01) — bake FRAMEWORK intent-embedding
# artifacts into the base at BUILD time (layered: framework-in-base,
# domain-in-app). The framework packages were just installed above → their
# ``lochan.packages`` entry points are registered → precompute_embeddings.py
# (Design A, context-derived) discovers them via those entry points and writes
# each package's ``ai_intent_seeds_embedded.json`` into its INSTALLED
# site-packages dir. Those artifacts ride the ``COPY --from=builder
# site-packages`` below into the base image, so EVERY app (framework-only fwprod
# OR a domain app) inherits the framework corpus pre-embedded → boot bulk-loads
# in seconds instead of the ~5hr live path.
#
# Provider = Gemini (§PARAM-EMBEDDING #1593 build block: cloud, reachable during
# build, no GPU). The nested embedding config is selected via env
# (``AI_EMBEDDING__{BUILD,RUNTIME}__*`` — enabled by env_nested_delimiter in
# AISettings). Both build+runtime blocks are set to the SAME model to satisfy
# the #1593 same-model vector-space guard. The API key is supplied as a BuildKit
# SECRET (id=gemini_key, sourced into this RUN's env ONLY, never baked into a
# layer). If the secret is absent (offline build), precompute logs loud and the
# base ships WITHOUT framework artifacts (boot degrades to live-compute) — it
# does NOT fail the base build.
# NOTE: the embedding config env is set INLINE in the RUN below (scoped to that
# single build step) — deliberately NOT a Dockerfile ``ENV`` layer, which would
# persist into the base image + every app and force runtime→Gemini, clobbering
# the #1593 DB/admin runtime override + the ollama default. Build-block config
# must exist only for the duration of precompute.
ARG EMBED_BUILD_MODEL=gemini-embedding-001
ARG EMBED_BUILD_DIM=768
RUN --mount=type=secret,id=gemini_key,required=false \
    AI_EMBEDDING__BUILD__PROVIDER=gemini \
    AI_EMBEDDING__BUILD__MODEL="${EMBED_BUILD_MODEL}" \
    AI_EMBEDDING__BUILD__DIMENSION="${EMBED_BUILD_DIM}" \
    AI_EMBEDDING__RUNTIME__PROVIDER=gemini \
    AI_EMBEDDING__RUNTIME__MODEL="${EMBED_BUILD_MODEL}" \
    AI_EMBEDDING__RUNTIME__DIMENSION="${EMBED_BUILD_DIM}" \
    sh -euc 'if [ -f /run/secrets/gemini_key ]; then AI_GEMINI_API_KEY="$(cat /run/secrets/gemini_key)"; export AI_GEMINI_API_KEY; fi; \
      if [ -n "${AI_GEMINI_API_KEY:-}" ]; then \
        echo "[precompute] framework embedding artifacts (Gemini build block, model=${AI_EMBEDDING__BUILD__MODEL})"; \
        python3 -m gyanam.scripts.precompute_embeddings; \
      else \
        echo "[precompute] WARN: AI_GEMINI_API_KEY absent at build — skipping framework precompute; base ships WITHOUT artifacts (boot will live-compute)"; \
      fi'

# Daksh is now a regular framework package (`packages/daksh/`) with
# `backend/pyproject.toml` — it's installed by step (1) above alongside
# every other tier=core package via install-framework-packages.py. The
# daksh-specific COPY+install lines that lived here pre-2026-05-11 are
# retired; install-framework-packages.py is the single uniform entry
# point for all framework Python packages.

# Strip bytecode, test suites, docs, and examples from ALL site-packages.
# This also strips pip's own __pycache__ inherited from python:3.13-slim base —
# runs in the builder stage so the COPY to runtime stage carries zero bytecode.
RUN find /usr/local/lib/python3.13/site-packages \
      -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null; \
    find /usr/local/lib/python3.13/site-packages -name '*.pyc' -delete 2>/dev/null; \
    find /usr/local/lib/python3.13/site-packages -type d \
      \( -name tests -o -name test -o -name docs -o -name examples \) \
      -exec rm -rf {} + 2>/dev/null; \
    true

# -- Optional stage: runtime-trace-based site-packages stripping (Gap 3) --
# Opt-in via `docker build --build-arg STRIP_UNUSED=true`. Default is off
# so a bad trace-list doesn't brick production builds. The stripper reads
# docker/site-packages-used.txt (generated by framework/lochan/packages/daksh/scripts/trace-site-packages.py)
# and removes every .py/.so that was NOT observed during a runtime trace.
# Safety rails (ancestor __init__.py protect + lazy-import skiplist +
# 80% sanity gate) live in framework/lochan/packages/daksh/scripts/strip-unused-pyfiles.sh.
#
# See docker/SITE-PACKAGES-STRIPPING.md for the operator playbook.
ARG STRIP_UNUSED=false
COPY framework/lochan/packages/daksh/scripts/strip-unused-pyfiles.sh /build/strip-unused-pyfiles.sh
COPY docker/ /build/docker-ctx/
RUN if [ "$STRIP_UNUSED" = "true" ] && [ -f /build/docker-ctx/site-packages-used.txt ]; then \
      echo "STRIP_UNUSED=true: stripping unused site-packages files..."; \
      bash /build/strip-unused-pyfiles.sh \
           /usr/local/lib/python3.13/site-packages \
           /build/docker-ctx/site-packages-used.txt; \
    elif [ "$STRIP_UNUSED" = "true" ]; then \
      echo "WARNING: STRIP_UNUSED=true but docker/site-packages-used.txt missing — skipping strip."; \
      echo "Run framework/lochan/packages/daksh/scripts/trace-site-packages.py first to generate the used-list."; \
    else \
      echo "STRIP_UNUSED=false (default): full site-packages retained."; \
    fi; \
    rm -rf /build/docker-ctx /build/strip-unused-pyfiles.sh

# -- Runtime stage: lean image with source (clean base, not deps) ------
FROM python:3.13-slim
WORKDIR /app

# Patent + license metadata — visible via `docker inspect`.
LABEL org.lochan.patent.filing="FP11"
LABEL org.lochan.patent.filing_date="2026-04-19"
LABEL org.lochan.patent.claims="33"
LABEL org.lochan.patent.status="filed"
LABEL org.lochan.license="MIT — see /LICENSE"
LABEL org.opencontainers.image.source="https://github.com/ssnukala/lochan"
LABEL org.opencontainers.image.documentation="https://lochan.ai/patent"
LABEL org.opencontainers.image.description="Lochan — AI-agent framework where every patent claim has a clickable demo"
LABEL org.opencontainers.image.vendor="Lochan"
LABEL org.opencontainers.image.licenses="MIT"

# Pre-strip pip's own __pycache__ from the runtime base image (~54 MB) BEFORE
# the COPY overlays site-packages. If we ran this after the COPY, the delete
# would only shadow files in the COPY layer (Docker layers are append-only).
RUN find /usr/local/lib/python3.13/site-packages \
      -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null; \
    find /usr/local/lib/python3.13/site-packages -name '*.pyc' -delete 2>/dev/null; \
    true

# Single copy of site-packages: deps + framework + daksh combined (pre-stripped
# in the builder stage — no __pycache__, no tests/docs/examples).
COPY --from=builder /usr/local/lib/python3.13/site-packages /usr/local/lib/python3.13/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# 3. Framework source code
COPY framework/lochan/backend/src /app/src
COPY framework/lochan/lochan.json /app/lochan.json
COPY framework/lochan/backend/alembic* /app/

# 3b. Framework data files (patent-coverage-status.json drives the FP11 60s
# demo aggregator + claim matrix; muulam.api.patent_coverage walks up from
# its own __file__ looking for a sibling `data/` dir).
COPY framework/lochan/data /app/data

# 4. Helper scripts
COPY framework/lochan/packages/daksh/backend/daksh/runtime/install-packages.py /app/scripts/
COPY framework/lochan/packages/daksh/backend/daksh/runtime/install-domain-packages.py /app/scripts/
COPY framework/lochan/packages/daksh/backend/daksh/runtime/install-framework-packages.py /app/scripts/
COPY framework/lochan/packages/daksh/backend/daksh/runtime/dev-entrypoint.sh /app/scripts/
COPY framework/lochan/packages/daksh/backend/daksh/generators/generate-manifest.py /app/scripts/

# 5. Framework package configs + locales
COPY --from=builder /build/packages/ /tmp/packages/
RUN python3 /app/scripts/install-framework-packages.py /tmp/packages --copy-configs /app/packages \
    && rm -rf /tmp/packages

# 6. Runtime dirs
RUN mkdir -p /app/log /app/data /app/ephe /app/packages

ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONPATH=/app
EXPOSE 5001
CMD ["uvicorn", "src.app:app", "--host", "0.0.0.0", "--port", "5001", "--reload"]
