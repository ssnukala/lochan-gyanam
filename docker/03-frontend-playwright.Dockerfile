# lochan-frontend-playwright — Tier-3 capture-run sidecar (PR-1 canonical)
#
# # Purpose
#
# Per Q-CAPTURE-RUN-BIND-MOUNT-LAYOUT = B founder ratify 2026-05-31:
# author a CANONICAL sidecar image that BAKES IN `@playwright/test` +
# the framework's Playwright config + e2e specs. Replaces the prior
# bind-mount approach (Microsoft's `mcr.microsoft.com/playwright` base
# + bind-mount of `framework/lochan/frontend:/tests:ro`) which coupled
# capture-run state to host pnpm install state and could surface stale
# config + spec versions depending on host checkout timing.
#
# # Why a separate Tier-3 image (NOT extend 02-frontend-base test stage)
#
# `02-frontend-base.Dockerfile` ALREADY has a `test` multi-stage target
# that installs @playwright/test + chromium. That target serves the
# broader test runner role (vitest + integration tests + Playwright).
# This Tier-3 image is CAPTURE-RUN-SPECIFIC + EPHEMERAL:
#
#   - Smaller surface: only what capture-run needs (Playwright + chromium
#     + e2e specs + config). No vitest. No backend test deps.
#   - Opt-in build: only built when capture-run is invoked. Production
#     builds skip Tier-3 entirely per founder pre-release "delete, do
#     not deprecate" — capture-run is testing-infrastructure-only.
#   - Canonical sidecar shape: matches the `compose.playwright.yml`
#     opt-in convention. Image NAME is the canonical artifact
#     (lochan-frontend-playwright:latest); compose.playwright.yml
#     references it by name + tag.
#   - Bind-mount scope reduced: only the screenshots output dir is
#     bind-mounted (writable). Tests + config are image-baked.
#
# # Requires
#
#   - `lochan-frontend-base:dev` (Tier 2, built via
#     docker/02-frontend-base.Dockerfile target=dev). Provides:
#     - Framework source at /app/frontend + /app/packages
#     - Workspace node_modules (from Tier 0)
#     - playwright.config.ts at /app/frontend/playwright.config.ts
#     - e2e/*.spec.ts at /app/frontend/e2e/
#
# # Build (from gyanam/ root)
#
#   docker build -f docker/03-frontend-playwright.Dockerfile -t lochan-frontend-playwright:latest .
#
# # Output
#
# Image tagged `lochan-frontend-playwright:latest`; consumed by
# `docker/compose.playwright.yml` via `image:` reference (no bind-mount
# of /tests; only /screenshots writable bind-mount remains).
#
# # Substrate role (per founder Day-7 BINDING A 4-CORE)
#
# Testing infrastructure is NON-CORE per 4-CORE BINDING. Canonical home
# is docker/ tier alongside 01/02/03-backend-dev — same Tier-N naming
# convention. Production chain never imports this image — separate
# image ancestry preserved per compose.playwright.yml three-hard-rules.
#
# # Composes-with
#
#   - docker/02-frontend-base.Dockerfile (Tier 2 base; dev target)
#   - docker/compose.playwright.yml (sidecar opt-in consumer; updated
#     in same PR to reference this image)
#   - framework/lochan/frontend/playwright.config.ts (canonical config)
#   - framework/lochan/frontend/e2e/*.spec.ts (canonical specs)
#   - [[feedback-no-shims-no-bandaids-longterm-fix-only]] BINDING —
#     bind-mount approach (Option A) NOT shipped; canonical image
#     (Option B) is the start state per pre-release "delete, do not
#     deprecate"
#   - [[feedback-additive-baseline-substrate-as-canonical-s4-contribution-shape]]
#     S4 1st memory rule — canonical 5-part shape applied here
#   - Q-CAPTURE-RUN-BIND-MOUNT-LAYOUT = B founder ratify 2026-05-31

# ── Tier-3: Playwright sidecar ───────────────────────────────────────
FROM lochan-frontend-base:dev AS playwright

WORKDIR /app

# Patent + license metadata — visible via `docker inspect`. Matches
# Tier 2 base image labels for cross-tier consistency (production
# vs test vs capture-run all carry the same patent attribution).
LABEL org.lochan.patent.filing="FP11"
LABEL org.lochan.patent.filing_date="2026-04-19"
LABEL org.lochan.patent.claims="33"
LABEL org.lochan.patent.status="filed"
LABEL org.lochan.license="MIT — see /LICENSE"
LABEL org.lochan.image.tier="3-playwright-sidecar"
LABEL org.lochan.image.role="capture-run-sidecar"
LABEL org.opencontainers.image.source="https://github.com/ssnukala/lochan-gyanam"
LABEL org.opencontainers.image.documentation="https://lochan.ai/patent"
LABEL org.opencontainers.image.description="Lochan capture-run sidecar — Playwright + chromium + canonical specs (Q-CAPTURE-RUN-BIND-MOUNT-LAYOUT = B canonical)"
LABEL org.opencontainers.image.vendor="Lochan"
LABEL org.opencontainers.image.licenses="MIT"

# Install @playwright/test as workspace-root devDependency.
#
# `-w` flag rationale (mirrors 02-frontend-base test stage Layer-7
# discovery 2026-05-28): pnpm 10 raises ERR_PNPM_ADDING_TO_ROOT without
# `--workspace-root` because @playwright/test is being added at the
# workspace root rather than to an individual workspace member — which
# is exactly what we want (Playwright is a test-tier devDependency
# shared across the workspace; not owned by any one package).
#
# `--frozen-lockfile` would be ideal here but `pnpm add` cannot honor
# it (mutates lockfile). Tier 2 `pnpm install --frozen-lockfile --offline`
# already populated node_modules from the locked state; this `pnpm add`
# layers in @playwright/test specifically pinned to the version below.
RUN pnpm add -D -w "@playwright/test@1.48.0"

# Install chromium browser + system deps for headless rendering.
#
# `chromium` is the only browser used by the capture-run convention
# (per compose.playwright.yml profiles `screenshots` + `screenshots-mobile`
# which both target chromium via playwright.config.ts `screenshots` +
# `screenshots-mobile` projects). Firefox + Webkit deliberately
# excluded — image bloat without capture-run benefit.
#
# `install-deps chromium` installs the apt packages chromium needs
# (libnss3, libatk-bridge2.0-0, fonts-liberation, etc.) which the
# Tier 2 dev base does NOT include (production frontend doesn't need
# them).
RUN npx playwright install chromium && \
    npx playwright install-deps chromium

# Working dir matches compose.playwright.yml /tests convention — but
# WITHOUT bind-mount. The framework source under /app already includes
# frontend/playwright.config.ts + frontend/e2e/*.spec.ts via Tier 2's
# COPY step. We expose them at /tests via symlink so existing capture-run
# commands (which assume /tests as working dir + config path) work
# unchanged.
RUN ln -s /app/frontend /tests

# Screenshot output landing zone — created so the bind-mount target
# in compose.playwright.yml (`/screenshots`) has a valid mount point.
# Actual screenshots written here by Playwright then propagate via
# bind-mount to the host.
RUN mkdir -p /screenshots

# Playwright browser cache path — pre-set to match the install location
# above. Playwright runtime reads this env var to locate chromium binary.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

WORKDIR /tests

# Default command is help; real capture-run invocations override via
# compose.playwright.yml `command:` (the `npx playwright test
# --project=screenshots --config=/tests/playwright.config.ts` pattern).
# A no-op default prevents accidental docker run with no args from
# attempting capture without an attached app-network.
CMD ["sh", "-c", "echo 'lochan-frontend-playwright sidecar — invoke via docker compose -f compose.yml -f docker/compose.playwright.yml run --rm playwright-screenshots' && exit 0"]
