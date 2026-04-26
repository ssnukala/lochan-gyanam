# lochan-fwtest-base — HMR-enabled live-debug image (Decision #5, WG-A4)
#
# Layered ABOVE lochan-deps-backend, SIBLING to lochan-backend-base and
# lochan-test-base. Closes the long-standing fwtest-no-HMR pain memory
# (memory: feedback-fwtest-no-hmr.md, 2026-04-11).
#
# Founder rule (2026-04-26): determinism comes from lochan-test-base;
# ergonomics come from lochan-fwtest-base. NEVER USED IN CI.
#
# Differences from lochan-test-base:
#   • HMR-friendly:   --reload server, mounted-volume support
#   • No locked bundle: latest Vitest/Playwright (live-debug, not deterministic)
#   • Chromium present (digest-pinned for supply-chain hygiene only)
#   • PYTHONDONTWRITEBYTECODE=0   ← bytecode allowed for warm reloads
#
# Layering (Decision #5):
#   lochan-deps-backend
#     ├─→ lochan-backend-base    (PROD)
#     ├─→ lochan-test-base       (CI)
#     └─→ lochan-fwtest-base     (THIS — fwtest01 only, never CI)
#
# Build (from gyanam/ root):
#   docker build -f docker/backend.fwtest.Dockerfile -t lochan-fwtest-base:latest .

# syntax=docker/dockerfile:1.6

ARG PLAYWRIGHT_DIGEST=sha256:a06d5c1b50b3c5cf4f0e5e5f9a3e9c9d0e2a8f4b6e8c0d2a4b6e8c0d2a4b6e8c
ARG PLAYWRIGHT_VERSION=1.48.0

# ── Stage 1: Chromium source (same digest pin as test-base) ───────────
FROM mcr.microsoft.com/playwright/python@${PLAYWRIGHT_DIGEST} AS chromium-source

RUN test -d /ms-playwright \
    && find /ms-playwright -maxdepth 2 -name 'chrome*' -type f | head -1 | grep -q chrome

# ── Stage 2: lochan-fwtest-base ───────────────────────────────────────
FROM lochan-deps-backend:latest

LABEL org.lochan.patent.filing="FP11"
LABEL org.lochan.patent.filing_date="2026-04-19"
LABEL org.lochan.patent.claims="33"
LABEL org.lochan.patent.status="filed"
LABEL org.lochan.license="MIT — see /LICENSE"
LABEL org.opencontainers.image.source="https://github.com/ssnukala/lochan"
LABEL org.opencontainers.image.documentation="https://lochan.ai/patent"
LABEL org.opencontainers.image.description="Lochan fwtest substrate — HMR + Chromium for live-debug iteration (NEVER CI; founder use)"
LABEL org.opencontainers.image.vendor="Lochan"
LABEL org.opencontainers.image.licenses="MIT"

# Decision #5 introspection labels
LABEL org.lochan.image.parent="lochan-deps-backend"
LABEL org.lochan.image.role="fwtest-base"
LABEL org.lochan.image.layering_decision="decision-5-2026-04-26"
LABEL org.lochan.image.never_in_ci="true"
LABEL org.lochan.image.closes_memory="feedback-fwtest-no-hmr.md"

ARG PLAYWRIGHT_DIGEST
ARG PLAYWRIGHT_VERSION

LABEL org.lochan.test.playwright_version="${PLAYWRIGHT_VERSION}"
LABEL org.lochan.test.playwright_digest="${PLAYWRIGHT_DIGEST}"
LABEL org.lochan.test.chromium_pinned_by="digest"

USER root

# ── 1. System libs for Chromium + dev tooling ────────────────────────
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates fonts-liberation libnss3 libatk1.0-0 \
      libatk-bridge2.0-0 libcups2 libdrm2 libgbm1 libgtk-3-0 libxcomposite1 \
      libxdamage1 libxrandr2 libpango-1.0-0 libcairo2 libasound2 libxshmfence1 \
      curl gnupg git inotify-tools \
    && rm -rf /var/lib/apt/lists/*

# ── 2. Node 22 for live Vitest iteration ─────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── 3. Python test toolkit + watch tools (LATEST not pinned — live-debug) ──
# Floating versions are intentional here: founder iterates against current
# upstream behaviour, and CI never consumes this image so reproducibility is
# not a goal. lochan-test-base owns determinism.
RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    pip install --no-cache-dir \
      pytest \
      pytest-asyncio \
      pytest-watch \
      httpx \
      aiosqlite \
      "playwright==${PLAYWRIGHT_VERSION}" \
      watchdog

# ── 4. Chromium from digest-pinned source ────────────────────────────
COPY --from=chromium-source /ms-playwright /ms-playwright
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

# ── 5. Frontend live-debug bundle (latest, not pinned) ───────────────
RUN npm install -g --no-fund --no-audit --no-progress \
      vitest \
      happy-dom \
      jsdom \
      msw \
      axe-core \
      '@playwright/test'
ENV NODE_PATH=/usr/local/lib/node_modules

WORKDIR /app

# HMR-friendly env — bytecode caching ON for fast reloads, --reload server.
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=0
ENV LOCHAN_FWTEST_MODE=hmr
ENV LOCHAN_TEST_MODE=fwtest
EXPOSE 5001
CMD ["uvicorn", "src.app:app", "--host", "0.0.0.0", "--port", "5001", "--reload"]
