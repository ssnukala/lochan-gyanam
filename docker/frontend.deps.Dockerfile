# lochan-deps-frontend — Pre-installed npm dependencies (Tier 0 flywheel)
#
# Contains: Node 22 + python3 + ALL npm dependencies.
# Does NOT contain framework source — that's in the base image (Tier 1).
#
# Rebuild: Only when package.json or abhilekh-react/package.json change.
# Frequency: Weekly/monthly. Push to registry for fast pulls.
#
# Build (from gyanam/ root):
#   docker build -f docker/frontend.deps.Dockerfile -t lochan-deps-frontend:latest .

FROM node:22-alpine

RUN apk add --no-cache python3

WORKDIR /app

# abhilekh-react: canonical source
COPY framework/lochan/packages/abhilekh/frontend /abhilekh-react

# Install all npm deps (cached in this image)
COPY framework/lochan/frontend/package*.json ./
RUN sed -i 's|"file:../packages/abhilekh/frontend"|"file:/abhilekh-react"|' package.json
RUN npm install --verbose --fetch-timeout=600000 --fetch-retries=5
