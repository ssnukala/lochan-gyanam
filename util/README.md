# Gyanam Util Scripts

Dev tools for building, testing, and deploying Lochan apps locally.

## Quick Start

```bash
cd /Users/srinivasnukala/Dropbox/Sites/docker/gyanam

# Start the dev container (has all Python/Node deps)
./util/scripts/dev-shell.sh

# Inside the container:
daksh evolve sauda --strict       # Validate a package
daksh janch sauda                  # Run tests on a package
daksh scaffold myapp --orchestrator  # Create a thin orchestrator domain package
```

## Scripts Reference

### App Lifecycle

| Script | Usage | What It Does |
|--------|-------|-------------|
| `deploy-package.sh` | `./util/scripts/deploy-package.sh wrap/v6/lochan-opencats apps/opencats06` | Full deploy: build app + start + seed + verify |
| `seed-app.sh` | `./util/scripts/seed-app.sh grahaka01 [--demo]` | Run seed scripts in a running app |
| `restart-app.sh` | `./util/scripts/restart-app.sh grahaka01` | Restart app containers |
| `rebuild-frontend.sh` | `./util/scripts/rebuild-frontend.sh grahaka01` | Clear vite cache + restart frontend |
| `exec-backend.sh` | `./util/scripts/exec-backend.sh grahaka01` | Open bash shell in backend container |
| `logs-app.sh` | `./util/scripts/logs-app.sh grahaka01` | Tail app container logs |
| `status-apps.sh` | `./util/scripts/status-apps.sh [app-name]` | Show running status of all/one app |

### Testing & Validation

| Script | Usage | What It Does |
|--------|-------|-------------|
| `run-janch.sh` | `./util/scripts/run-janch.sh sauda` | Run janch validation on a package |
| `run-janch.sh` | `./util/scripts/run-janch.sh --all --test` | Validate + test all packages |
| `run-janch-e2e.sh` | `./util/scripts/run-janch-e2e.sh grahaka01` | End-to-end tests against running app |
| `run-janch-matrix.sh` | `./util/scripts/run-janch-matrix.sh` | Coverage matrix across all packages |
| `run-janch-seed.sh` | `./util/scripts/run-janch-seed.sh sauda` | Test seed data generation |
| `run-janch-security.sh` | `./util/scripts/run-janch-security.sh` | Security audit across packages |
| `run-janch-fix.sh` | `./util/scripts/run-janch-fix.sh sauda` | Auto-fix janch findings |
| `run-janch-load.sh` | `./util/scripts/run-janch-load.sh grahaka01` | Load testing |

### Wrap & Analysis

| Script | Usage | What It Does |
|--------|-------|-------------|
| `run-wrap.sh` | `./util/scripts/run-wrap.sh extpackages/opencats` | Wrap a legacy app into Lochan |
| `run-scan.sh` | `./util/scripts/run-scan.sh extpackages/opencats` | Scan a source app |
| `run-diamond-pipeline.sh` | `./util/scripts/run-diamond-pipeline.sh` | Full diamond analysis pipeline |
| `run-audit-analysis.sh` | `./util/scripts/run-audit-analysis.sh` | Audit analysis across packages |
| `run-dossier.sh` | `./util/scripts/run-dossier.sh pestpro` | Generate package dossier |

### Dev Container

| Script | Usage | What It Does |
|--------|-------|-------------|
| `dev-shell.sh` | `./util/scripts/dev-shell.sh` | Start/attach to vardhan-dev container |
| `compose.yml` | `docker compose -f util/compose.yml up -d` | Start dev container via compose |

## Testing the New Agent Packages

The 4 new common capability agents (Wave 1 of agentic decomposition):

| Agent | Sanskrit | Location | Evolve Command |
|-------|----------|----------|----------------|
| **Sauda** (Sales Pipeline) | सौदा | `mandi/common/sauda` | `daksh evolve sauda --strict` |
| **Seva** (Service Ops) | सेवा | `mandi/common/seva` | `daksh evolve seva --strict` |
| **Sulka** (Billing) | शुल्क | `mandi/common/sulka` | `daksh evolve sulka --strict` |
| **Prapti** (Commission) | प्राप्ति | `mandi/common/prapti` | `daksh evolve prapti --strict` |

### Validate all 4 agents:
```bash
daksh evolve sauda --strict
daksh evolve seva --strict
daksh evolve sulka --strict
daksh evolve prapti --strict
```

### Run janch checks:
```bash
daksh janch sauda
daksh janch seva
daksh janch sulka
daksh janch prapti
```

### New checks added this session:
- `sub-package-antipattern` (evolve) — flags any packages/ subdirectory
- `cross-agent-fk` (evolve) — detects ForeignKey refs crossing agent boundaries
- `orchestrator-completeness` (evolve) — scores thin orchestrator packages
- `agent-contract` (janch) — validates AGENT_CARD capabilities have handlers
- `orchestrator-wiring` (janch) — validates data_source: "agent" schemas reference valid agents

### Deploy an app with new agents:
```bash
# Add to app's packages.json:
# "sauda": "latest", "seva": "latest", "sulka": "latest"

# Then rebuild:
daksh rebuild --from 1 pestpro01
```

## Architecture Reference

- **Plan**: `claude/lochan/plans/agentic-package-decomposition-thin-orchestrators.md`
- **Architecture doc**: `framework/lochan/docs/architecture/AGENTIC-COMPOSITION.md`
- **Naming**: `names.md` (Sanskrit, Chaldean 6)
