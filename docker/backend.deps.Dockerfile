# lochan-deps-backend — Pre-installed pip dependencies (Tier 0 flywheel)
#
# Two-stage build: compile with gcc, then copy to clean runtime image.
# Contains: Python 3.13 + ALL pip dependencies for framework + domain packages.
# Does NOT contain: build tools, framework source, or daksh dev deps.
#
# Phase 5 of `claude/daksh/plans/spicy-drifting-muffin-2026-05-01.md`:
# uses `uv pip install` (drop-in pip replacement, 10-100× faster) instead of
# plain pip. The extract-all-deps.py flow is unchanged — combined deps still
# flow through the same merge step; just install is faster.
#
# Rebuild: Only when dependencies change (requirements.txt, pyproject.toml).
# Frequency: Weekly/monthly. Push to registry for fast pulls.
#
# Build (from gyanam/ root):
#   docker build -f docker/backend.deps.Dockerfile -t lochan-deps-backend:latest .

# syntax=docker/dockerfile:1.6

# -- Stage 1: Build (has gcc for any C extensions) ---------------------
FROM python:3.13-slim AS builder

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    gcc g++ git \
    && rm -rf /var/lib/apt/lists/*

# Install uv (Astral) — drop-in pip replacement, 10-100× faster.
# Per Phase 5 of spicy-drifting-muffin packaging refactor.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

WORKDIR /build

# Copy everything needed for dependency extraction (direct from monorepo)
COPY tools/daksh/build/runtime/extract-all-deps.py /build/
COPY framework/lochan/backend/requirements.txt /build/backend/
COPY framework/lochan/packages/ /build/packages/
COPY tools/daksh/pyproject.toml /build/.daksh/pyproject.toml

# Generate combined deps file and install everything via uv.
# BuildKit cache mount on /root/.cache/uv: wheels persist across rebuilds so
# only changed deps redownload. Zero image-size impact (mount is host-side).
RUN --mount=type=cache,target=/root/.cache/uv,sharing=locked \
    python3 extract-all-deps.py /build > /build/all-deps.txt \
    && echo "=== Installing $(wc -l < /build/all-deps.txt) dependencies via uv ===" \
    && cat /build/all-deps.txt \
    && uv pip install --system -r /build/all-deps.txt

# Strip bloat before copying to runtime stage
RUN find /usr/local/lib/python3.13/site-packages \
      -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null; \
    find /usr/local/lib/python3.13/site-packages -name '*.pyc' -delete 2>/dev/null; \
    # Strip package test suites, docs, examples (never imported at runtime) \
    find /usr/local/lib/python3.13/site-packages -type d \
      \( -name tests -o -name test -o -name docs -o -name examples \) \
      -exec rm -rf {} + 2>/dev/null; \
    # Strip googleapiclient's offline discovery_cache (~95 MB of JSON for every \
    # Google API). google-generativeai uses build_from_document with a runtime \
    # HTTP fetch, not this cache. No framework code calls discovery.build(). \
    rm -rf /usr/local/lib/python3.13/site-packages/googleapiclient/discovery_cache/documents 2>/dev/null; \
    # NOTE: Do NOT uninstall pip/setuptools — domain packages need pip install at runtime \
    find /usr/local/lib/python3.13/site-packages -path '*.dist-info/*' \
      ! -name METADATA ! -name entry_points.txt ! -name top_level.txt ! -name RECORD \
      -delete 2>/dev/null; \
    true

# -- Stage 2: Clean runtime (no gcc, no git, no build artifacts) -------
FROM python:3.13-slim

# Install uv in runtime too (Tier 1 backend.base.Dockerfile builder uses
# `uv pip install --no-deps daksh/`). ~10MB; saves much more in Tier 1
# build-time speed.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

COPY --from=builder /usr/local/lib/python3.13/site-packages /usr/local/lib/python3.13/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

ENV PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
