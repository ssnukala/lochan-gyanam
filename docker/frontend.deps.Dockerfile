# lochan-deps-frontend — Pre-installed npm dependencies (Tier 0 flywheel)
#
# Contains: Node 22 + python3 + pnpm + ALL workspace dependencies.
# Does NOT contain framework source beyond package.json files — that's in
# the base image (Tier 1).
#
# Phase 5 of `claude/daksh/plans/spicy-drifting-muffin-2026-05-01.md`:
# switched from `npm install` (with the SED file:-rewrite hack) to
# `pnpm install --frozen-lockfile` from framework/lochan/pnpm-lock.yaml.
# Workspace deps (`abhilekh-react: workspace:*`) resolve via pnpm's symlink
# hoisting natively — no manual rewrite needed.
#
# Rebuild: Only when pnpm-lock.yaml or any package.json changes.
# Frequency: Weekly/monthly. Push to registry for fast pulls.
#
# Build (from gyanam/ root):
#   docker build -f docker/frontend.deps.Dockerfile -t lochan-deps-frontend:latest .

FROM node:22-alpine

RUN apk add --no-cache python3

# Install pnpm 10 (matches framework/lochan/pnpm-lock.yaml format).
# Per Phase 5 of spicy-drifting-muffin packaging refactor.
RUN npm install -g pnpm@10

WORKDIR /app

# Phase 5: copy the FULL workspace metadata tree (root package.json,
# pnpm-workspace.yaml, pnpm-lock.yaml + every workspace-member package.json)
# so pnpm can install the entire workspace deterministically.
#
# We copy package.json files only (not source) at this Tier 0 layer so the
# image rebuilds only when lockfile or any package.json changes.
COPY framework/lochan/package.json framework/lochan/pnpm-workspace.yaml framework/lochan/pnpm-lock.yaml ./
COPY framework/lochan/frontend/package.json ./frontend/
COPY framework/lochan/packages/abhilekh/frontend/package.json ./packages/abhilekh/frontend/
COPY framework/lochan/packages/duta/frontend/package.json ./packages/duta/frontend/
COPY framework/lochan/packages/flow/frontend/package.json ./packages/flow/frontend/
COPY framework/lochan/packages/lighthouse/frontend/package.json ./packages/lighthouse/frontend/
COPY framework/lochan/packages/litevault/frontend/package.json ./packages/litevault/frontend/
COPY framework/lochan/packages/muulam/frontend/package.json ./packages/muulam/frontend/
COPY framework/lochan/packages/pratyuttar/frontend/package.json ./packages/pratyuttar/frontend/
COPY framework/lochan/packages/trishul/frontend/package.json ./packages/trishul/frontend/
COPY framework/lochan/packages/vicharan/frontend/package.json ./packages/vicharan/frontend/

# Workspace install (deterministic, fails on lockfile drift).
RUN pnpm install --frozen-lockfile
