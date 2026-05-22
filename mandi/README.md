# Mandi (मंडी) — Lochan Package Marketplace

Every Lochan package is a mandi package. The marketplace is the universal registry for all packages — core, framework, and domain. The `tier` field determines how a package is distributed:

| Tier | Where | How Installed | Example |
|------|-------|---------------|---------|
| **core** | `lochan/packages/` | Always in base image | trishul, abhilekh, gyanam |
| **framework** | `mandi/` | Opt-in via `packages.json` mandi array | shodh, khoj, ankana |
| **domain** | `domainpkg/` | App-specific via `packages.json` packages | longterm, grahaka, lifelight |

All three tiers follow the same conventions: `package.config.json`, `mandi.json`, auto-wire entry points, same scaffold command.

## Directory Structure

```
framework/
├── lochan/              # Core framework
│   └── packages/        # Tier: core (always included)
├── mandi/               # Tier: framework (optional, marketplace)
│   ├── mandi-index.json # Static registry index
│   └── <packages>/      # Each with own git repo
domainpkg/               # Tier: domain (business-specific)
├── longterm/            # Each with own git repo
├── grahaka/
└── ...
```

## How It Works

### 1. Package Structure (each mandi package)
```
mandi/<name>/
├── package.config.json     # Package manifest (name, description, requires, provides)
├── backend/
│   ├── pyproject.toml      # pip-installable Python package
│   └── <name>/             # Python source
│       ├── __init__.py
│       ├── package.py      # startup(), shutdown(), make_routers()
│       ├── models/
│       ├── services/
│       ├── routes/
│       ├── tools/
│       └── schemas/
├── frontend/               # Optional frontend pages/components
├── forge/                  # Optional forge skills
├── scripts/                # Seed scripts
└── README.md
```

### 2. Adding a Mandi Package to an App

In the app's base image build or `packages.json`:
```json
{
  "primary": "longterm",
  "packages": {
    "longterm": { "image": "longterm:latest", "dev": "../../domainpkg/longterm" },
    "flow": { "image": "flow:latest", "dev": "../../domainpkg/flow" }
  },
  "mandi": ["nishchay", "ankana"]
}
```

The `forge build` or `forge deploy` pipeline:
1. Reads `mandi` list from packages.json
2. pip-installs each mandi package into the base image
3. Auto-wire discovers them via entry points (same as core packages)

### 3. Development Mode
In dev compose, mandi packages are volume-mounted:
```yaml
volumes:
  - ../../framework/mandi/nishchay:/mandi-packages/nishchay
```

## Current Marketplace Packages

### Extraction Candidates (from domain builds — extract when 2nd domain needs the pattern)

| Package | Sanskrit | Chaldean | Source | Status |
|---------|----------|----------|--------|--------|
| nishchay | निश्चय (certainty) | 6 | longterm credentials | Backlog |
| swasthya | स्वास्थ्य (wellbeing) | 6 | longterm burnout/retention | Absorbed into ankana |
| chintan | चिन्तन (reflection) | 6 | longterm training/CE | Backlog |
| ankana | अंकन (scoring+signals) | 6 | grahaka scoring + signals + longterm scoring | **Available** (merged with chetana) |
| suchana | सूचना (messaging) | 6 | grahaka CommHub + longterm comm-engine | Backlog |
| guna | गुण (quality) | 6 | grahaka data quality + curatel dedup | Backlog |

### Packages That Should Move from Core to Mandi

Some current core packages are optional and should eventually move:

| Package | Why Move | Risk |
|---------|----------|------|
| curatel | Lead scoring — not needed by all apps | Low — auto-wire, graceful ImportError |
| social-intel | Social scanning — not needed by all apps | Low — auto-wire |
| custom-fields | Dynamic fields — not needed by all apps | Low — auto-wire |
| translate | i18n — some apps are English-only | Low |
| teamchat | Team messaging — not needed by simple apps | Medium — some coupling |

### Packages That Stay in Core

| Package | Why Core |
|---------|----------|
| muulam | Framework foundation |
| trishul | Auth/security — every app needs this |
| abhilekh | CRUD engine — every app needs this |
| gyanam | Chat/AI — primary interface |
| lighthouse | Monitoring/alerts — every app benefits |
| anvaya | State machines — widely used |
| litevault | Document storage — widely used |
