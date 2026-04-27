# lochan-test-base — CI-stable test bundle (Decision #5, WG-A4)
#
# Layered ABOVE lochan-deps-backend, SIBLING to lochan-backend-base. The prod
# chain (lochan-backend-base → <app>-deps → <app>-backend) NEVER imports from
# this image. The 600MB of test packages physically cannot enter a prod image.
#
# Founder rule (2026-04-26): "layer the images in a way that will facilitate
# the testing process, so we have a clean dev image to do all the testing and
# the production build does not carry the test package overheads."
#
# Bundle (locked, no HMR, CI-stable):
#   • pytest + pytest-xdist + pluggy           ← Python test substrate
#   • Playwright (Python) + Chromium           ← E2E + screenshot tests
#   • Vitest + happy-dom + jsdom + MSW         ← Frontend unit/component
#   • axe-core                                 ← A11y assertions
#
# Security Gate 1 (Frontend Testing Expert): Chromium + Playwright pinned by
# sha256 digest, NOT floating tags. The image reference is verified at build
# time via cosign keyless OIDC verification (handled in CI workflow); the
# digest pin makes a supply-chain swap detectable.
#
# Layering (Decision #5):
#   lochan-deps-backend
#     ├─→ lochan-backend-base    (PROD — never sees test packages)
#     ├─→ lochan-test-base       (CI-stable, opt-in via target=test)
#     └─→ lochan-fwtest-base     (HMR live-debug, never CI)
#
# Build (from gyanam/ root):
#   docker build -f docker/backend.test.Dockerfile -t lochan-test-base:latest .
#
# Layer app-test on top:
#   FROM lochan-test-base
#   COPY <app>/ /app/
#   RUN pytest -m "smoke or regression"

# syntax=docker/dockerfile:1.6

# ── Pinned upstream digests (Security Gate 1) ─────────────────────────
# Playwright Python image — pinned to a sha256 digest, not a floating tag.
# Carries Chromium + system libs already validated by Microsoft. Refresh by
# running `docker pull mcr.microsoft.com/playwright/python:v1.48.0-jammy &&
# docker images --digests` and updating the line below + the Chromium digest
# pin in framework/lochan/docker/PINS.json.
#
# Pin policy: refreshed monthly on the 1st via tools/daksh/scripts/refresh-test-pins.sh,
# cosign-verified in build-sign-images.yml before this Dockerfile is invoked.
ARG PLAYWRIGHT_DIGEST=sha256:6bbd515848db4042068571135979b6ee6d330a794b28e037e3a6ccd7f2abfa26
ARG PLAYWRIGHT_VERSION=1.48.0

# ── Stage 1: Test-toolkit prep ────────────────────────────────────────
# Sources Chromium from a digest-pinned Playwright base, then COPYs the
# /ms-playwright cache into the lochan-deps-backend layer below. This keeps
# the parent image (`get_image_parent` test) reading `lochan-deps-backend` —
# Chromium is content, not a parent.
FROM mcr.microsoft.com/playwright/python@${PLAYWRIGHT_DIGEST} AS chromium-source

# Confirm the Chromium binary exists at the expected location so a wrong
# digest fails fast at build time, not at first test run.
RUN test -d /ms-playwright \
    && find /ms-playwright -maxdepth 2 -name 'chrome*' -type f | head -1 | grep -q chrome

# ── Stage 2: lochan-test-base ─────────────────────────────────────────
FROM lochan-deps-backend:latest

# Patent + license metadata
LABEL org.lochan.patent.filing="FP11"
LABEL org.lochan.patent.filing_date="2026-04-19"
LABEL org.lochan.patent.claims="33"
LABEL org.lochan.patent.status="filed"
LABEL org.lochan.license="MIT — see /LICENSE"
LABEL org.opencontainers.image.source="https://github.com/ssnukala/lochan"
LABEL org.opencontainers.image.documentation="https://lochan.ai/patent"
LABEL org.opencontainers.image.description="Lochan test substrate — pytest + Playwright + Chromium + Vitest + happy-dom + jsdom + MSW + axe-core (CI-stable, no HMR)"
LABEL org.opencontainers.image.vendor="Lochan"
LABEL org.opencontainers.image.licenses="MIT"

# Decision #5 + WG-A4: declare the parent for static introspection. The
# test_test_base_layered_above_deps_backend acceptance test reads this LABEL.
LABEL org.lochan.image.parent="lochan-deps-backend"
LABEL org.lochan.image.role="test-base"
LABEL org.lochan.image.layering_decision="decision-5-2026-04-26"

# Re-declare the digest pin args inside this stage so they survive into LABELs.
ARG PLAYWRIGHT_DIGEST
ARG PLAYWRIGHT_VERSION

# Pin metadata is authoritative — Security Gate 1 acceptance test
# (verify_chromium_pinned_by_digest) reads these LABELs.
LABEL org.lochan.test.playwright_version="${PLAYWRIGHT_VERSION}"
LABEL org.lochan.test.playwright_digest="${PLAYWRIGHT_DIGEST}"
LABEL org.lochan.test.chromium_pinned_by="digest"
LABEL org.lochan.test.cosign_verified="ci-only"

USER root
WORKDIR /test

# ── 1. System libs Chromium needs at runtime (matches Playwright's set) ──
# Same set Playwright's official image installs; copied here so we keep
# Chromium runnable on the slim Python base.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates fonts-liberation libnss3 libatk1.0-0 \
      libatk-bridge2.0-0 libcups2 libdrm2 libgbm1 libgtk-3-0 libxcomposite1 \
      libxdamage1 libxrandr2 libpango-1.0-0 libcairo2 libasound2 libxshmfence1 \
      curl gnupg \
    && rm -rf /var/lib/apt/lists/*

# ── 2. Node 22 (matches frontend.base.Dockerfile) for Vitest/MSW/axe-core ──
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── 3. Python test substrate ──────────────────────────────────────────
# Pinned versions — Decision #9 (rebuild gate) reads these as the canonical
# pytest stack pinning. lochan-deps-backend already carries fastapi/sqlmodel
# etc.; we only add the test-only packages here.
RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    pip install --no-cache-dir \
      'pytest==8.3.3' \
      'pytest-xdist==3.6.1' \
      'pytest-asyncio==0.24.0' \
      'pluggy==1.5.0' \
      'httpx==0.27.2' \
      'aiosqlite==0.20.0' \
      "playwright==${PLAYWRIGHT_VERSION}"

# ── 4. Chromium from digest-pinned Playwright base ────────────────────
# COPY (not pip install) — keeps the binary's provenance traceable to the
# upstream digest, which is the whole point of Security Gate 1.
COPY --from=chromium-source /ms-playwright /ms-playwright
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

# Sanity-check the Chromium binary made it across the COPY and is executable.
RUN find /ms-playwright -maxdepth 3 -name chrome -type f | head -1 | xargs -I{} test -x {}

# ── 5. Frontend test bundle (Vitest + happy-dom + jsdom + MSW + axe-core) ──
# Installed globally so any per-app vitest config can resolve them. Pinned
# to a versions snapshot so CI is reproducible across test-image rebuilds.
WORKDIR /test/frontend
RUN npm install --no-fund --no-audit --no-progress --prefix /usr/local \
      'vitest@2.1.4' \
      'happy-dom@15.7.4' \
      'jsdom@25.0.1' \
      'msw@2.4.9' \
      'axe-core@4.10.0' \
      '@vitest/coverage-v8@2.1.4' \
      '@playwright/test@1.48.0'
ENV NODE_PATH=/usr/local/lib/node_modules

# ── 6. Strip caches from the final layer ──────────────────────────────
RUN find /usr/local/lib/python3.13/site-packages \
      -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null; \
    find /usr/local/lib/python3.13/site-packages -name '*.pyc' -delete 2>/dev/null; \
    npm cache clean --force >/dev/null 2>&1; \
    rm -rf /root/.npm /root/.cache; \
    true

WORKDIR /app

# CI-stable defaults — no --reload, no HMR. Compose target=test overrides CMD
# with the actual test invocation (`pytest -m smoke`, `vitest run`, etc.).
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV CI=true
ENV LOCHAN_TEST_MODE=ci
EXPOSE 5001
CMD ["pytest", "--tb=short", "-q"]
