# lochan-backend-dev — Full dev image with daksh[dev] extras layered on top
# of the production base. Used for: fwtest01, CI runners, any environment
# that needs evolve/janch/deployer/MCP-admin tooling.
#
# Requires: lochan-backend-base:latest (Tier 1 — build with docker/02-backend-base.Dockerfile)
#
# Build (from gyanam/ root):
#   docker build -f docker/03-backend-dev.Dockerfile -t lochan-backend-dev:latest .
#
# The production base already has daksh installed without extras. This image
# layers the dev extras on top, so a single `pip install daksh[dev]` would
# double-install daksh. We install `daksh[dev]` with the same source tree
# used to build the base, targeting only the extras that differ.
#
# NOTE: This Dockerfile is for DEV/CI only. Production deployments use
# lochan-backend-base directly.

FROM lochan-backend-base:latest

# Patent + license metadata — visible via `docker inspect`.
# (Re-applied on top of base labels so dev-only image is clearly tagged too.)
LABEL org.lochan.patent.filing="FP11"
LABEL org.lochan.patent.filing_date="2026-04-19"
LABEL org.lochan.patent.claims="33"
LABEL org.lochan.patent.status="filed"
LABEL org.lochan.license="MIT — see /LICENSE"
LABEL org.opencontainers.image.source="https://github.com/ssnukala/lochan"
LABEL org.opencontainers.image.documentation="https://lochan.ai/patent"
LABEL org.opencontainers.image.description="Lochan — AI-agent framework where every patent claim has a clickable demo (dev image — includes daksh[dev] extras)"
LABEL org.opencontainers.image.vendor="Lochan"
LABEL org.opencontainers.image.licenses="MIT"

# Optional build-time deps (gcc) — needed if any dev extras have C extensions.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc g++ git \
    && rm -rf /var/lib/apt/lists/*

# ── docker CLI (client only) — the second half of the DooD tooling sidecar ──
# The `daksh install` tooling sidecar (docker/compose.tooling.yml) mounts the
# host docker socket and drives build/db/migrate/seed-demo/verify/deploy by
# shelling out to the `docker` CLI (daksh.lib.docker_client → subprocess.run
# (["docker", ...]); _build_orchestrator → `docker build`; deploy_wrap →
# `docker compose up`; intent_acceptance.live_runner → `docker exec`). The
# socket mount alone is NOT enough — without a `docker` binary on PATH every
# verb dies rc=127. This installs the docker CLIENT here; the DAEMON stays on
# the host (docker-OUTSIDE-of-docker, NOT dind/--privileged). Canonical recipe:
# official `docker:cli`, GitLab-runner helper, Jenkins docker-CLI agent all ship
# the client + mount the host socket. Q-S2-13 = C (2026-07-21): static pinned
# binary over apt-repo plumbing — leaner, no apt key/repo, version pinned per the
# determinism-ratchet doctrine. DEV/CI-only image → zero prod-image-size impact.
#
# Static binary (self-contained Go, no glibc coupling) from download.docker.com;
# arch mapped from dpkg (arm64→aarch64, amd64→x86_64) so it builds on either.
# Version pinned; the client negotiates the API version with the host daemon.
ARG DOCKER_CLI_VERSION=27.5.1
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && case "$(dpkg --print-architecture)" in \
         arm64) DOCKER_ARCH=aarch64 ;; \
         amd64) DOCKER_ARCH=x86_64 ;; \
         *) echo "unsupported arch for docker static CLI: $(dpkg --print-architecture)" >&2; exit 1 ;; \
       esac \
    && curl -fsSL "https://download.docker.com/linux/static/stable/${DOCKER_ARCH}/docker-${DOCKER_CLI_VERSION}.tgz" \
         -o /tmp/docker.tgz \
    && tar -xzf /tmp/docker.tgz -C /tmp \
    && install -m 0755 /tmp/docker/docker /usr/local/bin/docker \
    && rm -rf /tmp/docker /tmp/docker.tgz \
    && apt-get purge -y curl \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* \
    && docker --version

# Re-install daksh with [dev] extras and strip bloat in a SINGLE layer.
# Doing the strip in a separate RUN only shadows files (layers are append-only),
# which wouldn't shrink the image. The combined RUN ensures the deletes
# actually reduce the layer size.
# Daksh is installed by install-framework-packages.py alongside every
# other framework package (line 21-23 of backend.base). For dev image we
# additionally re-install with [dev] extras — pulls in fastmcp + libcst
# + httpx that don't ship in the prod base.
#
# `daksh`'s pyproject + package both live under `backend/` (pyproject uses
# `[tool.setuptools.packages.find] where = ["."]`, so pip must run against the
# directory that holds BOTH pyproject.toml AND the daksh/ package — i.e.
# `backend/`). Copy that ONE tree and install it directly, exactly as the base
# image does via install-framework-packages.py → pip install <pkg>/backend. The
# prior two-COPY split (pyproject to /build/daksh, backend to /build/daksh/backend)
# never resolved: the source path omitted `backend/` AND the split put pyproject
# and package in different dirs so `where=["."]` couldn't find the package.
COPY framework/lochan/packages/daksh/backend /build/daksh
RUN pip install --no-cache-dir /build/daksh[dev] \
    && rm -rf /build/daksh \
    && find /usr/local/lib/python3.13/site-packages \
        -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null; \
    find /usr/local/lib/python3.13/site-packages -name '*.pyc' -delete 2>/dev/null; \
    find /usr/local/lib/python3.13/site-packages -type d \
      \( -name tests -o -name test -o -name docs -o -name examples \) \
      -exec rm -rf {} + 2>/dev/null; \
    true

# Retain all the env + ports + cmd from the base image.
EXPOSE 5001 9500
# --reload watches source only, never the compiled-bytecode churn it creates.
# Without --reload-dir, WatchFiles walks the entire cwd recursively — including
# __pycache__/*.pyc. On a bind-mount dev container, one backend edit writes a
# .pyc, which the watcher sees as a change, which triggers a reload, which
# writes more .pyc — a self-sustaining reload-storm (measured 25 reloads →
# backend crash-cycle on sanchalak, 2026-07-17). Scope the watch to the two
# real source roots and exclude bytecode so an edit reloads exactly once:
#   /app/src      — framework app entry (WORKDIR=/app, src.app:app = /app/src/app.py)
#   /app/packages — domain + framework packages (bind-mounted in dev)
# (uvicorn's own --reload-exclude docs prescribe exactly this for the .pyc case.)
CMD ["uvicorn", "src.app:app", "--host", "0.0.0.0", "--port", "5001", \
     "--reload", "--reload-dir", "/app/src", "--reload-dir", "/app/packages", \
     "--reload-exclude", "*.pyc", "--reload-exclude", "__pycache__/*"]
