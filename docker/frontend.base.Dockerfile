# lochan-frontend-base — Complete framework frontend image (Tier 1 flywheel)
#
# Contains: All npm deps (from Tier 0) + framework frontend source + package configs.
# This image IS a runnable dev server (empty, no domain pages).
#
# Requires: lochan-deps-frontend:latest (Tier 0 — build with docker/frontend.deps.Dockerfile)
#
# Build (from gyanam/ root):
#   docker build -f docker/frontend.base.Dockerfile --target dev -t lochan-frontend-base:dev .
#   docker build -f docker/frontend.base.Dockerfile --target prod -t lochan-frontend-base:prod .

# ── Dev base: deps already installed, just add source ────────────────
FROM lochan-deps-frontend:latest AS dev
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

# 1. Framework frontend source — Phase 5 of spicy-drifting-muffin:
# we copy the SPA's frontend/ AND the workspace member packages so pnpm's
# symlink resolution (already populated in Tier 0 deps image) finds them
# at /app/packages/<name>/frontend/. The vendor-copy hacks (abhilekh-react-src,
# lochan-templates-src, roop-src, rupayan-src, app-src, lib-src, components-src,
# providers-src, types-src, hooks-src) DELETED — workspace symlinks replace
# them. See vite.config.ts: customResolver no longer checks `*-src` paths.
COPY framework/lochan/frontend/ ./frontend/
COPY framework/lochan/packages/ ./packages/

# pnpm install in Tier 0 created node_modules with symlinks to the
# workspace package.json files. Re-run `pnpm install --offline` here to
# wire the now-present workspace SOURCE into the existing node_modules
# symlinks (no network; just metadata reconciliation).
RUN pnpm install --frozen-lockfile --offline

# 3. Scripts (direct from daksh tool — no staging)
COPY tools/daksh/build/runtime/frontend-entrypoint.sh /app/scripts/
COPY tools/daksh/daksh/generators/generate-domain-manifest.py /app/scripts/
RUN chmod +x /app/scripts/frontend-entrypoint.sh

# 4. Framework package configs + locales + framework-tier mandi catalog stub
COPY tools/daksh/build/runtime/install-frontend-configs.py /tmp/
COPY tools/daksh/build/runtime/generate-framework-catalog.py /tmp/
COPY framework/lochan/packages/ /tmp/packages/
RUN python3 /tmp/install-frontend-configs.py /tmp/packages /app/framework-packages \
    && python3 /tmp/generate-framework-catalog.py /tmp/packages /app/src/data/mandi-catalog.json \
    && rm -rf /tmp/packages /tmp/install-frontend-configs.py /tmp/generate-framework-catalog.py

# 5. Runtime dirs
RUN mkdir -p /app/log /app/packages

EXPOSE 3000
ENTRYPOINT ["sh", "/app/scripts/frontend-entrypoint.sh"]
CMD ["pnpm", "run", "dev"]

# ── Prod base: same as dev, used for vite build stage ────────────────
FROM dev AS prod

# ── Test runner: Debian-based with Playwright + bundled browser ──────
FROM node:22-bookworm-slim AS test

# Phase 5: install pnpm in test runner base (matches dev stage tooling).
RUN npm install -g pnpm@10

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

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 curl ca-certificates fonts-liberation libnss3 libatk1.0-0 \
    libatk-bridge2.0-0 libcups2 libdrm2 libgbm1 libgtk-3-0 libxcomposite1 \
    libxdamage1 libxrandr2 libpango-1.0-0 libcairo2 libasound2 libxshmfence1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=dev /app /app

# Phase 5: dropped `COPY --from=dev /abhilekh-react /abhilekh-react`
# (vendor copy from old dev stage; no longer exists post-Phase 3).
# Workspace symlinks inside /app/node_modules/abhilekh-react point at
# /app/packages/abhilekh/frontend/ directly, copied via the COPY above.

RUN pnpm add -D @playwright/test && \
    npx playwright install chromium && \
    npx playwright install-deps chromium

RUN mkdir -p /app/log /app/packages /tmp/pw-auth

EXPOSE 3000
ENTRYPOINT ["sh", "/app/scripts/frontend-entrypoint.sh"]
CMD ["pnpm", "run", "dev"]
