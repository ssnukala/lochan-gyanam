# lochan-backend-dev — Full dev image with daksh[dev] extras layered on top
# of the production base. Used for: fwtest01, CI runners, any environment
# that needs evolve/janch/deployer/MCP-admin tooling.
#
# Requires: lochan-backend-base:latest (Tier 1 — build with docker/backend.base.Dockerfile)
#
# Build (from gyanam/ root):
#   docker build -f docker/backend.dev.Dockerfile -t lochan-backend-dev:latest .
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

# Re-install daksh with [dev] extras and strip bloat in a SINGLE layer.
# Doing the strip in a separate RUN only shadows files (layers are append-only),
# which wouldn't shrink the image. The combined RUN ensures the deletes
# actually reduce the layer size.
COPY tools/daksh/ /build/daksh/
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
CMD ["uvicorn", "src.app:app", "--host", "0.0.0.0", "--port", "5001", "--reload"]
