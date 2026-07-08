# Vardhan Dev Container — for running wrap, scan, diamond extraction, janch
# Mounts /gyanam as volume, has all Python deps pre-installed
#
# Build: docker build -t vardhan-dev util/
# Run:   docker run -it --rm -v $(pwd):/gyanam -w /gyanam --env-file util/.env vardhan-dev
# Shell: docker exec -it vardhan-dev bash

FROM python:3.13-slim

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl jq tree \
    && rm -rf /var/lib/apt/lists/*

# Python packages for Vardhan + Daksh + LLM
# Core
RUN pip install --no-cache-dir \
    pydantic \
    httpx \
    jinja2 \
    pyyaml \
    aiofiles

# LLM integration
RUN pip install --no-cache-dir \
    instructor \
    google-generativeai \
    anthropic

# Code analysis
RUN pip install --no-cache-dir \
    tree-sitter \
    tree-sitter-language-pack \
    sqlglot \
    radon \
    semgrep \
    detect-secrets \
    pip-audit \
    pip-licenses

# Frontend detection (UI pattern strippers)
RUN pip install --no-cache-dir \
    selectolax \
    parsel \
    lxml \
    tinycss2 \
    hamlpy \
    playwright && \
    playwright install chromium --with-deps

# Testing
RUN pip install --no-cache-dir \
    pytest \
    pytest-asyncio

# Node.js for jscpd (cross-language code duplication)
RUN apt-get update && apt-get install -y --no-install-recommends nodejs npm \
    && npm install -g jscpd \
    && rm -rf /var/lib/apt/lists/*

# Working directory
WORKDIR /gyanam

# Environment defaults
ENV GYANAM_DIR=/gyanam
ENV PYTHONPATH=/gyanam/tools/vardhan:/gyanam/tools/daksh:/gyanam/tools/janch

# Convenience aliases
RUN echo 'alias wrap="python3 -m vardhan.cli wrap"' >> /root/.bashrc && \
    echo 'alias scan="python3 -m vardhan.cli scan"' >> /root/.bashrc && \
    echo 'alias daksh="python3 -m daksh"' >> /root/.bashrc && \
    echo 'alias janch="python3 -m daksh janch"' >> /root/.bashrc && \
    echo 'alias evolve="python3 -m daksh evolve"' >> /root/.bashrc && \
    echo 'alias diamond="python3 util/generate-diamond-report.py"' >> /root/.bashrc && \
    echo 'echo "=== Lochan Dev Container ==="' >> /root/.bashrc && \
    echo 'echo "Commands: daksh, janch, evolve, wrap, scan, diamond"' >> /root/.bashrc && \
    echo 'echo "Agent packages: sauda (sales), seva (service), arthik (finance incl. commissions)"' >> /root/.bashrc && \
    echo 'echo "Example:  daksh evolve sauda --strict"' >> /root/.bashrc && \
    echo 'echo "Example:  daksh scaffold myapp --orchestrator"' >> /root/.bashrc && \
    echo 'echo ""' >> /root/.bashrc

CMD ["bash"]
