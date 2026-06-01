# lochan-frontend-playwright — Tier-3 capture-run sidecar (β fix-forward)
#
# # Purpose
#
# Per Q-CAPTURE-RUN-SIDECAR-ALPINE-COMPAT = β founder ratify 2026-05-31:
# fix-forward on prior #28 substrate. The original `FROM lochan-frontend-
# base:dev` inherited Alpine (via Tier-0 lochan-deps-frontend:latest =
# node:22-alpine) which is INCOMPATIBLE with `npx playwright install-deps
# chromium` (canonical Playwright apt-get recipe; Debian/Ubuntu only).
#
# This iteration pivots to **independent Tier-3 base**: `node:22-bookworm-
# slim` directly. Sidecar is testing-only + ephemeral — no production
# frontend bloat; no coupling to Tier-2 Alpine chain. Isolation IS the
# design intent per Q-CAPTURE-RUN-BIND-MOUNT-LAYOUT = B founder ratify.
#
# # Why independent (NOT derived from lochan-frontend-base:test)
#
# `02-frontend-base.Dockerfile` ALREADY has a `test` multi-stage target
# (FROM node:22-bookworm-slim) that does similar Playwright install. That
# target serves the broader test runner role (vitest + integration tests
# + framework workspace). This Tier-3 sidecar is CAPTURE-RUN-SPECIFIC:
#
#   - Smaller surface: only what capture-run needs (Playwright + chromium
#     + e2e specs + config). NO vitest. NO workspace node_modules.
#   - Independent build: Tier-3 doesn't require Tier-2 test stage to
#     exist; can be built standalone. Decouples capture-run from the
#     broader test pipeline.
#   - Canonical sidecar name: `lochan-frontend-playwright:latest`;
#     compose.playwright.yml references it by name + tag (independent
#     of `lochan-frontend-base:test` tag which serves different role).
#   - Bind-mount scope minimal: only `/screenshots` writable bind-mount
#     remains; e2e specs + playwright.config.ts COPIED into image.
#
# # Why node:22-bookworm-slim (NOT node:22-alpine)
#
# `playwright install-deps chromium` runs `apt-get install` for chromium's
# X / GTK / font / audio dependencies (libnss3, libatk-bridge2.0-0,
# fonts-liberation, libasound2, etc.). Debian package manager only.
# Alpine's apk has no equivalent canonical Playwright recipe. Bookworm-
# slim is the canonical Playwright base per upstream microsoft/playwright
# images + the 02-frontend-base test stage precedent (Layer-7 discovery
# 2026-05-28).
#
# Image-size impact: bookworm-slim base ~75MB vs alpine ~50MB; install-
# deps adds ~120MB of X/audio libs; chromium binary ~150MB; final image
# ~350MB total. Acceptable per founder image-size discipline (sidecar
# is testing-only; not shipped in production chain). Compare to
# microsoft/playwright base ~1.5GB which we're replacing.
#
# # Requires
#
#   - Build context = gyanam-root (must contain framework/lochan/frontend/
#     playwright.config.ts + framework/lochan/frontend/e2e/*.spec.ts)
#
# # Build (from gyanam/ root)
#
#   docker build -f docker/03-frontend-playwright.Dockerfile -t lochan-frontend-playwright:latest .
#
# # Substrate role (per founder Day-7 BINDING A 4-CORE)
#
# Testing infrastructure non-core. Canonical home is docker/ tier
# alongside 01/02/03-backend-dev. Production chain never imports this
# image — independent ancestry preserved per compose.playwright.yml
# three-hard-rules.
#
# # Composes-with
#
#   - docker/compose.playwright.yml (sidecar opt-in consumer)
#   - framework/lochan/frontend/playwright.config.ts (canonical config)
#   - framework/lochan/frontend/e2e/*.spec.ts (canonical specs)
#   - [[feedback-no-shims-no-bandaids-longterm-fix-only]] BINDING — β
#     IS long-term-right per founder ratify rationale (canonical
#     Playwright pattern; install-deps maintained by upstream)
#   - [[feedback-additive-baseline-substrate-as-canonical-s4-contribution-shape]]
#     S4 1st memory rule — canonical 5-part shape applied
#   - Q-CAPTURE-RUN-SIDECAR-ALPINE-COMPAT = β founder ratify 2026-05-31
#   - Q-CAPTURE-RUN-BIND-MOUNT-LAYOUT = B founder ratify 2026-05-31
#     (prior; this is the fix-forward iteration)

# ── Tier-3: Playwright sidecar (independent Debian base) ─────────────
FROM node:22-bookworm-slim AS playwright

WORKDIR /tests

# Patent + license metadata — visible via `docker inspect`.
LABEL org.lochan.patent.filing="FP11"
LABEL org.lochan.patent.filing_date="2026-04-19"
LABEL org.lochan.patent.claims="33"
LABEL org.lochan.patent.status="filed"
LABEL org.lochan.license="MIT — see /LICENSE"
LABEL org.lochan.image.tier="3-playwright-sidecar"
LABEL org.lochan.image.role="capture-run-sidecar"
LABEL org.lochan.image.base="node:22-bookworm-slim"
LABEL org.opencontainers.image.source="https://github.com/ssnukala/lochan-gyanam"
LABEL org.opencontainers.image.documentation="https://lochan.ai/patent"
LABEL org.opencontainers.image.description="Lochan capture-run sidecar — Playwright + chromium + canonical specs (Q-CAPTURE-RUN-SIDECAR-ALPINE-COMPAT = β fix-forward)"
LABEL org.opencontainers.image.vendor="Lochan"
LABEL org.opencontainers.image.licenses="MIT"

# Install pnpm@10 (matches Tier-0 tooling so package resolution mirrors
# the production frontend chain; sidecar isolation does NOT mean
# diverging tooling).
RUN npm install -g pnpm@10

# Copy canonical Playwright config + e2e specs from the framework. The
# image is independent of Tier-2 lochan-frontend-base, so we COPY these
# explicitly rather than inheriting via a prior stage. This is the
# trade-off of independence: ~few-KB of source duplication for full
# isolation from the production frontend chain.
COPY framework/lochan/frontend/playwright.config.ts ./playwright.config.ts
COPY framework/lochan/frontend/e2e ./e2e

# Author a minimal package.json declaring @playwright/test devDep +
# pinned to canonical test-image-pins.json version (@playwright/test =
# 1.48.0; matches 02-frontend-base test stage + compose.playwright.yml
# runtime expectations). Pinning here makes the sidecar reproducible
# without depending on workspace lockfile drift.
RUN printf '{\n  "name": "lochan-frontend-playwright-sidecar",\n  "version": "0.0.0",\n  "private": true,\n  "devDependencies": { "@playwright/test": "1.48.0" }\n}\n' > package.json

# Install @playwright/test into the sidecar workspace. The sidecar IS
# the only workspace (no parent workspace-root); plain `pnpm install`
# resolves the devDependency declared above.
RUN pnpm install

# Install chromium browser + apt deps via canonical Playwright recipe.
# `install-deps chromium` runs apt-get install for the X / GTK / font /
# audio libs chromium requires for headless rendering. Debian/Ubuntu
# canonical pattern; the reason this PR pivots from Alpine to bookworm-
# slim is precisely so this command works (Alpine apk has no equivalent
# upstream recipe).
RUN npx playwright install chromium && \
    npx playwright install-deps chromium

# Screenshot output landing zone — bind-mount target in compose.playwright.yml
# (`/screenshots`) needs a valid mount point. Actual screenshots written
# here by Playwright then propagate via bind-mount to the host.
RUN mkdir -p /screenshots

# Playwright browser cache path — pre-set to match the install location.
# Playwright runtime reads this env var to locate chromium binary.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

# Default command is help — real capture-run invocations override via
# compose.playwright.yml `command:` (the `npx playwright test
# --project=screenshots --config=/tests/playwright.config.ts` pattern).
CMD ["sh", "-c", "echo 'lochan-frontend-playwright sidecar — invoke via docker compose -f compose.yml -f docker/compose.playwright.yml run --rm playwright-screenshots' && exit 0"]
