#!/bin/bash
# ============================================================================
# Lochan Framework — Full Deployment Script
# ============================================================================
# Downloads all git repos, builds base images, builds domain packages,
# and deploys all apps on a fresh server.
#
# Usage:
#   ./deploy-all.sh                    # Full deploy (clone + build + deploy)
#   ./deploy-all.sh --dir /home/apps/gyanam  # Deploy to a specific directory
#   ./deploy-all.sh --skip-clone       # Skip git clone (repos already present)
#   ./deploy-all.sh --skip-build       # Skip base image build
#   ./deploy-all.sh --prod             # Deploy in production mode
#   ./deploy-all.sh --apps-only        # Only deploy apps (repos + images exist)
#   ./deploy-all.sh --app recruiter01  # Deploy a single app
#
# Bootstrap on a fresh server:
#   mkdir -p /home/apps/gyanam && cd /home/apps/gyanam
#   curl -O https://raw.githubusercontent.com/ssnukala/lochan/main/deploy-all.sh
#   chmod +x deploy-all.sh
#   ./deploy-all.sh --dir /home/apps/gyanam
#
# Prerequisites:
#   - Docker + Docker Compose v2
#   - Git
#   - 8GB+ RAM recommended (10 apps running simultaneously)
#
# ============================================================================

set -euo pipefail

# ── Resolve base directory ──────────────────────────────────────────────────
# Default: script's own directory. Override with --dir <path>.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GYANAM_DIR="$SCRIPT_DIR"

# Parse --dir early so all paths resolve correctly
for i in $(seq 1 $#); do
  arg="${!i}"
  if [ "$arg" = "--dir" ]; then
    next=$((i+1))
    GYANAM_DIR="${!next}"
    mkdir -p "$GYANAM_DIR"
    GYANAM_DIR="$(cd "$GYANAM_DIR" && pwd)"
    break
  fi
done

FRAMEWORK_DIR="$GYANAM_DIR/framework/lochan"
DOMAINPKG_DIR="$GYANAM_DIR/domainpkg"
APPS_DIR="$GYANAM_DIR/apps"
LLMS_DIR="$APPS_DIR/llms"

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
hdr()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $*${NC}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}\n"; }

# ── Flags ───────────────────────────────────────────────────────────────────
SKIP_CLONE=false
SKIP_BUILD=false
PROD_MODE=false
APPS_ONLY=false
SINGLE_APP=""
DEV_MODE="dev"

_skip_next=false
for arg in "$@"; do
  if [ "$_skip_next" = true ]; then
    _skip_next=false
    continue
  fi
  case "$arg" in
    --skip-clone)  SKIP_CLONE=true ;;
    --skip-build)  SKIP_BUILD=true ;;
    --prod)        PROD_MODE=true; DEV_MODE="prod" ;;
    --apps-only)   APPS_ONLY=true; SKIP_CLONE=true; SKIP_BUILD=true ;;
    --dir)         _skip_next=true ;;  # already handled above
    --app)         _skip_next=true ;;  # handled below
    *)             ;;
  esac
done

# Handle --app <name>
i=0
for arg in "$@"; do
  i=$((i+1))
  if [ "$arg" = "--app" ]; then
    j=0
    for a2 in "$@"; do
      j=$((j+1))
      if [ $j -eq $((i+1)) ]; then
        SINGLE_APP="$a2"
        break
      fi
    done
  fi
done

# ── Git Repositories ───────────────────────────────────────────────────────
# Format: local_dir:git_url
FRAMEWORK_REPO="framework/lochan:https://github.com/ssnukala/lochan.git"

DOMAIN_REPOS=(
  "lifelight:https://github.com/ssnukala/lifelight.git"
  "longterm:https://github.com/ssnukala/lochan-longterm.git"
  "flow:https://github.com/ssnukala/lochan-flow.git"
  "mediaserver:https://github.com/ssnukala/lochan-mediaserver.git"
  "autonex:https://github.com/ssnukala/lochan-autonex.git"
  "pestpro:https://github.com/ssnukala/lochan-pestpro.git"
  "realtor:https://github.com/ssnukala/lochan-lokavit.git"
  "regsevak:https://github.com/ssnukala/lochan-regsevak.git"
  "vyaparam:https://github.com/ssnukala/lochan-vyaparam.git"
  "covera:https://github.com/ssnukala/lochan-covera.git"
)

# ── App Definitions ─────────────────────────────────────────────────────────
# Format: app_name|primary|packages(comma-sep)|be_port|fe_port|db_port
APP_DEFS=(
  "recruiter01|longterm|longterm,flow,regsevak|8592|8593|5444"
  "lifestyle01|lifelight|lifelight|8596|8597|5435"
  "nukalams01|mediaserver|mediaserver|8598|8599|5436"
  "fwtest01||none|8620|8621|5440"
  "autonex01|autonex|autonex,vyaparam|8640|8641|5459"
  "pestpro01|pestpro|pestpro,vyaparam|8654|8655|5457"
  "covera01|covera|covera,vyaparam|8652|8653|5456"
  "curatel01|curatel|curatel|8656|8657|5458"
  "regsevak01|regsevak|regsevak,vyaparam|8650|8651|5455"
  "realtor01|realtor|realtor,flow,vyaparam|8658|8659|5465"
)

# ============================================================================
# Phase 0: Prerequisites
# ============================================================================
check_prerequisites() {
  hdr "Phase 0: Checking Prerequisites"

  local ok=true

  if ! command -v docker &>/dev/null; then
    err "Docker not found. Install from https://docs.docker.com/get-docker/"
    ok=false
  else
    log "Docker $(docker --version | cut -d' ' -f3 | tr -d ',')"
  fi

  if ! docker compose version &>/dev/null; then
    err "Docker Compose v2 not found."
    ok=false
  else
    log "Docker Compose $(docker compose version --short)"
  fi

  if ! command -v git &>/dev/null; then
    err "Git not found."
    ok=false
  else
    log "Git $(git --version | cut -d' ' -f3)"
  fi

  # Check disk space (need ~15GB for images + containers)
  local avail_gb
  avail_gb=$(df -g "$GYANAM_DIR" 2>/dev/null | tail -1 | awk '{print $4}' || echo "?")
  if [ "$avail_gb" != "?" ] && [ "$avail_gb" -lt 15 ] 2>/dev/null; then
    warn "Low disk space: ${avail_gb}GB available (15GB+ recommended)"
  fi

  if [ "$ok" = false ]; then
    err "Prerequisites not met. Aborting."
    exit 1
  fi
}

# ============================================================================
# Phase 1: Clone Repositories
# ============================================================================
clone_repos() {
  if [ "$SKIP_CLONE" = true ]; then
    warn "Skipping git clone (--skip-clone)"
    return
  fi

  hdr "Phase 1: Cloning Repositories"

  # Create directory structure
  mkdir -p "$GYANAM_DIR/framework" "$DOMAINPKG_DIR" "$APPS_DIR" "$LLMS_DIR"

  # Clone framework
  local fw_dir="${FRAMEWORK_REPO%%:*}"
  local fw_url="${FRAMEWORK_REPO#*:}"
  local fw_path="$GYANAM_DIR/$fw_dir"

  if [ -d "$fw_path/.git" ]; then
    log "Framework already cloned — pulling latest..."
    (cd "$fw_path" && git pull --ff-only 2>/dev/null) || warn "Framework pull failed (may have local changes)"
  else
    log "Cloning framework → $fw_dir"
    git clone "$fw_url" "$fw_path"
  fi

  # Clone domain packages
  for entry in "${DOMAIN_REPOS[@]}"; do
    local name="${entry%%:*}"
    local url="${entry#*:}"
    local path="$DOMAINPKG_DIR/$name"

    if [ -d "$path/.git" ]; then
      log "$name already cloned — pulling latest..."
      (cd "$path" && git pull --ff-only 2>/dev/null) || warn "$name pull failed"
    else
      log "Cloning $name"
      git clone "$url" "$path"
    fi
  done

  log "All repositories cloned."
}

# ============================================================================
# Phase 2: Create shared networks + Ollama + Shared DB
# ============================================================================
setup_shared_services() {
  hdr "Phase 2: Shared Services (Networks + Ollama + Shared DB)"

  # Create shared-ai network
  if docker network inspect shared-ai &>/dev/null; then
    log "shared-ai network exists"
  else
    docker network create shared-ai
    log "Created shared-ai Docker network"
  fi

  # Create shared-db-network
  if docker network inspect shared-db-network &>/dev/null; then
    log "shared-db-network exists"
  else
    docker network create shared-db-network
    log "Created shared-db-network Docker network"
  fi

  # ── Ollama ──────────────────────────────────────────────────────────
  mkdir -p "$LLMS_DIR/ollama36"
  if [ ! -f "$LLMS_DIR/ollama36/docker-compose.yml" ]; then
    cat > "$LLMS_DIR/ollama36/docker-compose.yml" <<'OLLAMA_EOF'
services:
  ollama:
    image: ollama/ollama:latest
    container_name: shared-ollama
    ports:
      - "${PORT_OLLAMA:-11434}:11434"
    volumes:
      - ./:/root/.ollama
    networks:
      - shared-ai
    restart: unless-stopped

networks:
  shared-ai:
    name: shared-ai
    driver: bridge
OLLAMA_EOF
    log "Created Ollama compose file"
  fi

  if docker ps --format '{{.Names}}' | grep -q '^shared-ollama$'; then
    log "Ollama already running"
  else
    (cd "$LLMS_DIR/ollama36" && docker compose up -d 2>/dev/null) || warn "Ollama start failed (non-critical)"
    log "Ollama started"
  fi

  # ── Shared PostgreSQL (golden copy + prod DBs) ─────────────────────
  SHARED_DB_DIR="$GYANAM_DIR/apps/shared-db"
  mkdir -p "$SHARED_DB_DIR"
  if [ ! -f "$SHARED_DB_DIR/compose.yml" ]; then
    cat > "$SHARED_DB_DIR/compose.yml" <<'SHAREDDB_EOF'
# shared-db — Persistent databases shared across apps
# Start:  docker compose up -d
# Stop:   docker compose stop
# NEVER:  docker compose down -v  (destroys all data)

services:
  golden-postgres:
    image: pgvector/pgvector:pg16
    container_name: golden-postgres
    ports:
      - "5433:5432"
    environment:
      - POSTGRES_USER=fastauth
      - POSTGRES_PASSWORD=changeme
      - POSTGRES_DB=fastauth
    volumes:
      - golden-pgdata:/var/lib/postgresql/data
    networks:
      - shared-db-network
    restart: unless-stopped

  recruiter-postgres-prod:
    image: pgvector/pgvector:pg16
    container_name: recruiter-postgres-prod
    ports:
      - "5445:5432"
    environment:
      - POSTGRES_USER=fastauth
      - POSTGRES_PASSWORD=changeme
      - POSTGRES_DB=fastauth
    volumes:
      - recruiter-pgdata-prod:/var/lib/postgresql/data
    networks:
      - shared-db-network
    restart: unless-stopped

volumes:
  golden-pgdata:
    name: golden-pgdata
  recruiter-pgdata-prod:
    name: recruiter-pgdata-prod

networks:
  shared-db-network:
    name: shared-db-network
    driver: bridge
SHAREDDB_EOF
    log "Created shared-db compose file"
  fi

  # Start shared databases
  if docker ps --format '{{.Names}}' | grep -q '^golden-postgres$'; then
    log "Golden copy postgres already running"
  else
    (cd "$SHARED_DB_DIR" && docker compose up -d 2>/dev/null) || warn "Shared DB start failed"
    log "Shared databases started (golden-postgres:5433, recruiter-postgres-prod:5445)"
  fi
}

# ============================================================================
# Phase 3: Build Base Images
# ============================================================================
build_base_images() {
  if [ "$SKIP_BUILD" = true ]; then
    # Check if images exist
    local missing=false
    for img in lochan-backend-base:latest lochan-frontend-base:dev lochan-frontend-base:prod; do
      if ! docker image inspect "$img" &>/dev/null; then
        warn "Image $img not found — forcing build"
        missing=true
      fi
    done
    if [ "$missing" = false ]; then
      warn "Skipping base image build (--skip-build)"
      return
    fi
  fi

  hdr "Phase 3: Building Base Images (Tier 1)"

  if [ ! -f "$FRAMEWORK_DIR/forge" ]; then
    err "Framework not found at $FRAMEWORK_DIR. Clone repos first."
    exit 1
  fi

  (cd "$FRAMEWORK_DIR" && bash forge build)
  log "Base images built successfully"
}

# ============================================================================
# Phase 4: Build Domain Package Images (Tier 2)
# ============================================================================
build_domain_images() {
  hdr "Phase 4: Building Domain Package Images (Tier 2)"

  # Collect unique packages needed across all apps
  declare -A needed_pkgs

  if [ -n "$SINGLE_APP" ]; then
    # Only build packages for the single app
    for def in "${APP_DEFS[@]}"; do
      IFS='|' read -r app_name primary pkgs be fe db <<< "$def"
      if [ "$app_name" = "$SINGLE_APP" ]; then
        IFS=',' read -ra pkg_list <<< "$pkgs"
        for p in "${pkg_list[@]}"; do
          [ "$p" != "none" ] && needed_pkgs["$p"]=1
        done
      fi
    done
  else
    for def in "${APP_DEFS[@]}"; do
      IFS='|' read -r app_name primary pkgs be fe db <<< "$def"
      IFS=',' read -ra pkg_list <<< "$pkgs"
      for p in "${pkg_list[@]}"; do
        [ "$p" != "none" ] && needed_pkgs["$p"]=1
      done
    done
  fi

  for pkg in "${!needed_pkgs[@]}"; do
    local pkg_dir=""

    # curatel is a framework package, not a domain package
    if [ "$pkg" = "curatel" ]; then
      log "Skipping $pkg (framework package — part of base image)"
      continue
    fi

    pkg_dir="$DOMAINPKG_DIR/$pkg"

    if [ ! -d "$pkg_dir" ]; then
      warn "Domain package $pkg not found at $pkg_dir — skipping"
      continue
    fi

    # Check if build.sh exists
    if [ -f "$pkg_dir/build.sh" ]; then
      log "Building $pkg..."
      (cd "$pkg_dir" && bash build.sh latest) || { err "Failed to build $pkg"; continue; }
    elif [ -f "$pkg_dir/Dockerfile" ]; then
      log "Building $pkg (Dockerfile)..."
      (cd "$pkg_dir" && docker build -t "${pkg}:latest" .) || { err "Failed to build $pkg"; continue; }
    else
      warn "$pkg has no build.sh or Dockerfile — skipping image build"
    fi
  done

  log "Domain package images built"
}

# ============================================================================
# Phase 5: Deploy Apps
# ============================================================================
deploy_app() {
  local app_name="$1"
  local primary="$2"
  local pkgs="$3"
  local be_port="$4"
  local fe_port="$5"
  local db_port="$6"

  local app_dir="$APPS_DIR/$app_name"

  echo -e "\n${BLUE}── Deploying ${BOLD}$app_name${NC}${BLUE} (be:$be_port fe:$fe_port db:$db_port) ──${NC}"

  # Create app directory
  mkdir -p "$app_dir"

  # Stop existing containers if the app is already running (frees ports)
  if [ -d "$app_dir" ]; then
    for cf in compose.dev.yml compose.yml compose.prod.yml; do
      if [ -f "$app_dir/$cf" ]; then
        (cd "$app_dir" && docker compose -f "$cf" down 2>/dev/null) || true
        break
      fi
    done
  fi

  # ── Generate packages.json ──
  local pkg_json="{\n"
  if [ -n "$primary" ]; then
    pkg_json+="  \"primary\": \"$primary\",\n"
  fi
  pkg_json+="  \"packages\": {"

  if [ "$pkgs" = "none" ]; then
    pkg_json+="}\n}"
  else
    IFS=',' read -ra pkg_list <<< "$pkgs"
    local first=true
    for p in "${pkg_list[@]}"; do
      [ "$first" = true ] && first=false || pkg_json+=","

      # Determine dev path
      local dev_path
      if [ "$p" = "curatel" ]; then
        dev_path="../../framework/lochan/packages/curatel"
      else
        dev_path="../../domainpkg/$p"
      fi

      pkg_json+="\n    \"$p\": {\n      \"image\": \"${p}:latest\",\n      \"dev\": \"$dev_path\"\n    }"
    done
    pkg_json+="\n  }\n}"
  fi

  echo -e "$pkg_json" > "$app_dir/packages.json"

  # ── Generate .env ──
  local jwt_secret enc_key
  # Preserve existing secrets if .env already exists
  if [ -f "$app_dir/.env" ]; then
    jwt_secret=$(grep '^JWT_SECRET=' "$app_dir/.env" | cut -d= -f2)
    enc_key=$(grep '^ENCRYPTION_KEY=' "$app_dir/.env" | cut -d= -f2)
  fi
  # Generate new if empty
  if [ -z "${jwt_secret:-}" ]; then
    jwt_secret=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))" 2>/dev/null || openssl rand -base64 32)
  fi
  if [ -z "${enc_key:-}" ]; then
    enc_key=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null || python3 -c "import base64,os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())")
  fi

  cat > "$app_dir/.env" <<ENV_EOF
# ── ${app_name} — Auto-generated by deploy-all.sh ──
# PostgreSQL
POSTGRES_USER=fastauth
POSTGRES_PASSWORD=changeme
POSTGRES_DB=fastauth

# Ports
PORT_DB=${db_port}
PORT_BACKEND=${be_port}
PORT_FRONTEND=${fe_port}

# Security (auto-generated, do not share)
JWT_SECRET=${jwt_secret}
ENCRYPTION_KEY=${enc_key}

# URLs
FRONTEND_URL=http://localhost:${fe_port}
CORS_ORIGINS=http://localhost:${fe_port}
DATABASE_URL=postgresql+asyncpg://fastauth:changeme@golden-postgres:5432/fastauth

# Super Admin
SUPER_ADMIN_EMAIL=admin@example.com
SUPER_ADMIN_USERNAME=admin
SUPER_ADMIN_PASSWORD=changeme

# AI Services (via shared-ai network)
AI_OLLAMA_BASE_URL=http://shared-ollama:11434

# OAuth (blank = disabled)
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
GOOGLE_REDIRECT_URI=http://localhost:${be_port}/api/oauth/google/callback
MICROSOFT_CLIENT_ID=
MICROSOFT_CLIENT_SECRET=
MICROSOFT_REDIRECT_URI=http://localhost:${be_port}/api/oauth/microsoft/callback

# Rate Limiting
RATE_LIMIT_LOGIN=5/minute
RATE_LIMIT_REGISTER=3/minute

# Logging
LOG_LEVEL=INFO
DEBUG=true
ENV_EOF

  # Copy .env to .env.dev
  cp "$app_dir/.env" "$app_dir/.env.dev"

  # ── Run generate-app-config.py ──
  local gen_script="$FRAMEWORK_DIR/forge.d/generators/generate-app-config.py"
  if [ -f "$gen_script" ]; then
    local gen_args="--config $app_dir/packages.json"
    if [ "$PROD_MODE" = true ]; then
      gen_args+=" --prod"
    fi
    python3 "$gen_script" $gen_args || {
      # Fallback: use forge deploy if generate-app-config.py fails
      warn "Config generator failed — using forge deploy"
      _deploy_via_forge "$app_name" "$primary" "$pkgs" "$be_port" "$fe_port" "$db_port"
      return
    }
  else
    _deploy_via_forge "$app_name" "$primary" "$pkgs" "$be_port" "$fe_port" "$db_port"
    return
  fi

  # ── Start containers ──
  _start_app "$app_name" "$app_dir"
}

_deploy_via_forge() {
  local app_name="$1" primary="$2" pkgs="$3" be_port="$4" fe_port="$5" db_port="$6"

  local forge_cmd="bash $FRAMEWORK_DIR/forge deploy $app_name --ports ${be_port}:${fe_port} --db-port ${db_port}"

  if [ "$pkgs" = "none" ]; then
    # Framework-only app
    forge_cmd+=""
  else
    IFS=',' read -ra pkg_list <<< "$pkgs"
    local first_pkg=true
    for p in "${pkg_list[@]}"; do
      forge_cmd+=" --package ${p}:latest"
      if [ "$first_pkg" = true ] && [ -n "$primary" ]; then
        forge_cmd+=" --primary"
        first_pkg=false
      fi
    done
  fi

  if [ "$PROD_MODE" = true ]; then
    forge_cmd+=" --prod"
  fi

  # forge deploy expects to be run from framework dir
  (cd "$FRAMEWORK_DIR" && eval "$forge_cmd") || warn "forge deploy $app_name may have issues"
}

_start_app() {
  local app_name="$1" app_dir="$2"
  local compose_file="compose.dev.yml"

  if [ "$PROD_MODE" = true ] && [ -f "$app_dir/compose.prod.yml" ]; then
    compose_file="compose.prod.yml"
  elif [ ! -f "$app_dir/$compose_file" ]; then
    compose_file="compose.yml"
  fi

  if [ ! -f "$app_dir/$compose_file" ]; then
    warn "$app_name: No compose file found — skipping start"
    return
  fi

  (cd "$app_dir" && docker compose -f "$compose_file" up -d) || warn "$app_name failed to start"

  # Connect backend to shared-db-network so it can reach golden-postgres
  local backend_container="${app_name}-backend-1"
  if docker ps --format '{{.Names}}' | grep -q "^${backend_container}$"; then
    docker network connect shared-db-network "$backend_container" 2>/dev/null || true
  fi

  log "$app_name started ($compose_file)"
}

deploy_all_apps() {
  hdr "Phase 5: Deploying Apps"

  for def in "${APP_DEFS[@]}"; do
    IFS='|' read -r app_name primary pkgs be_port fe_port db_port <<< "$def"

    # If single app mode, skip others
    if [ -n "$SINGLE_APP" ] && [ "$app_name" != "$SINGLE_APP" ]; then
      continue
    fi

    deploy_app "$app_name" "$primary" "$pkgs" "$be_port" "$fe_port" "$db_port"
  done
}

# ============================================================================
# Phase 6: Health Check
# ============================================================================
health_check() {
  hdr "Phase 6: Health Check (waiting for apps to start...)"

  sleep 30

  local all_ok=true
  local results=""

  for def in "${APP_DEFS[@]}"; do
    IFS='|' read -r app_name primary pkgs be_port fe_port db_port <<< "$def"

    if [ -n "$SINGLE_APP" ] && [ "$app_name" != "$SINGLE_APP" ]; then
      continue
    fi

    # Check backend
    local be_code
    be_code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${be_port}/health" 2>/dev/null || echo "000")

    # Check frontend
    local fe_code
    fe_code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${fe_port}/" 2>/dev/null || echo "000")

    local status_icon="✓"
    if [ "$be_code" != "200" ] || [ "$fe_code" != "200" ]; then
      status_icon="✗"
      all_ok=false
    fi

    results+="  ${status_icon} ${app_name}  be:${be_port}→${be_code}  fe:${fe_port}→${fe_code}\n"
  done

  echo -e "\n${BOLD}App Status:${NC}"
  echo -e "$results"

  if [ "$all_ok" = true ]; then
    log "All apps healthy!"
  else
    warn "Some apps not responding — they may still be starting. Check with:"
    echo "  docker logs <app>-backend-1 2>&1 | tail -20"
  fi
}

# ============================================================================
# Phase 7: Run Seeds
# ============================================================================
seed_apps() {
  hdr "Phase 7: Seeding Databases"

  for def in "${APP_DEFS[@]}"; do
    IFS='|' read -r app_name primary pkgs be_port fe_port db_port <<< "$def"

    if [ -n "$SINGLE_APP" ] && [ "$app_name" != "$SINGLE_APP" ]; then
      continue
    fi

    # Check if backend is healthy first
    local be_code
    be_code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${be_port}/health" 2>/dev/null || echo "000")

    if [ "$be_code" = "200" ]; then
      # Run setup (creates tables) then seed (creates admin + demo data)
      docker exec "${app_name}-backend-1" python3 /app/scripts/setup.py 2>/dev/null && \
        log "$app_name: tables created" || warn "$app_name: setup may have failed"

      docker exec "${app_name}-backend-1" python3 /app/scripts/seed.py 2>/dev/null && \
        log "$app_name: seeded" || warn "$app_name: seed may have failed"
    else
      warn "$app_name: backend not healthy (HTTP $be_code) — skipping seed"
    fi
  done
}

# ============================================================================
# Summary
# ============================================================================
print_summary() {
  hdr "Deployment Complete"

  echo -e "${BOLD}Directory Structure:${NC}"
  echo "  $GYANAM_DIR/"
  echo "  ├── framework/lochan/     # Framework (Forge CLI here)"
  echo "  ├── domainpkg/            # Domain package repos"
  echo "  └── apps/                 # Deployed apps"
  echo ""

  echo -e "${BOLD}App Endpoints:${NC}"
  printf "  %-14s  %-10s  %-10s  %-8s  %s\n" "APP" "BACKEND" "FRONTEND" "DB" "PACKAGES"
  printf "  %-14s  %-10s  %-10s  %-8s  %s\n" "───────────" "────────" "────────" "─────" "────────"

  for def in "${APP_DEFS[@]}"; do
    IFS='|' read -r app_name primary pkgs be_port fe_port db_port <<< "$def"
    printf "  %-14s  :%-9s  :%-9s  :%-7s  %s\n" "$app_name" "$be_port" "$fe_port" "$db_port" "$pkgs"
  done

  echo ""
  echo -e "${BOLD}Shared Services:${NC}"
  echo "  Ollama:           http://localhost:11434"
  echo ""
  echo -e "${BOLD}Admin Login (all apps):${NC}"
  echo "  Email:    admin@example.com"
  echo "  Password: changeme"
  echo ""
  echo -e "${BOLD}Useful Commands:${NC}"
  echo "  cd framework/lochan && ./forge build          # Rebuild base images"
  echo "  cd apps/<app> && docker compose -f compose.dev.yml logs -f backend"
  echo "  cd apps/<app> && docker compose -f compose.dev.yml restart backend"
  echo "  curl http://localhost:<port>/health            # Health check"
  echo "  curl http://localhost:<port>/health/auto-wire  # Package discovery"
}

# ============================================================================
# Main
# ============================================================================
main() {
  echo -e "${BOLD}${CYAN}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║   Lochan (लोचन) — Full Deployment Script    ║"
  echo "  ║   Framework + 10 Domain Apps                 ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${NC}"

  check_prerequisites

  if [ "$APPS_ONLY" = false ]; then
    clone_repos
    setup_shared_services
    build_base_images
    build_domain_images
  else
    setup_shared_services
  fi

  deploy_all_apps
  health_check
  seed_apps
  print_summary
}

main
