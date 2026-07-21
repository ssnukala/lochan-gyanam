# daksh tooling sidecar (`compose.tooling.yml`) — DooD for `daksh install`

The opt-in **Docker-outside-of-Docker** sidecar that lets the `daksh install`
build/deploy wizard (and any daksh build/deploy verb) run on a **venv-less host**
— the zero-host-dependency server model where only `docker` + `git` are present.

## Why it exists

`daksh install --app <app>` runs `preflight → configure → build → db → seed →
verify → deploy`. Steps 3–7 all drive the host docker daemon — they shell out to
the `docker` CLI:

| Step | Verb | docker call | Evidence |
|------|------|-------------|----------|
| 3 | build / build-app | `docker build` | `_build_orchestrator.py:298` |
| 4 | db / migrate | `docker exec <app>-backend` | `lib/docker_client.py:178` |
| 5 | seed-demo | re-exec `docker exec` into the app container | `seed_demo.py` (`_exec_seed_in_container`) |
| 6 | verify | `docker compose ps` + `GET http://localhost:{published_port}` | `verify.py:107-130` |
| 7 | deploy | `docker compose up` | `deploy_wrap.py:245` |
| — | intent-acceptance | `docker exec <app>-backend-1` | `intent_acceptance/live_runner.py:52` |

On a host with no python venv these verbs must run **inside a container** — but
that container then needs to reach the host daemon. That's what this sidecar
provides.

## The shape (one socket-mounted service)

There is **no "pure app-env" verb** — every verb reaches the app *through the host
daemon* (or its published port), not by attaching to the app-network. So the
sidecar is **ONE** socket-mounted service, not two (Q-S2-12 = A, 2026-07-21):

- **`image: lochan-backend-dev:latest`** — the DEV/CI image (base + `daksh[dev]` +
  the static `docker` CLI). Never ships to prod; prod uses `lochan-backend-base`.
- **`-v /var/run/docker.sock:/var/run/docker.sock`** — the DooD seam. The docker
  *client* runs in the container; the *daemon* stays on the host. **NOT** dind /
  `--privileged` / a nested daemon.
- **`-v ../:/gyanam` + `GYANAM_DIR=/gyanam`** — the workspace tree daksh reads
  (`repos.json`, `apps/<app>`, compose files).
- **`network_mode: host`** — `daksh verify` GETs `http://localhost:{published_port}`;
  from inside a container `localhost` is the container, so the sidecar joins the
  host network namespace to make its `localhost` == the host's published ports
  (zero code change to `verify.py`). Q-S2-12 = A removed any app-network need, so
  there is no conflict.

### The docker CLI in the image (Q-S2-13 = C)

The socket alone is insufficient — daksh drives docker via the **CLI binary**
(`subprocess.run(["docker", ...])`), and the base/dev image shipped without one,
so every verb died `rc=127`. `03-backend-dev.Dockerfile` now installs a **static,
version-pinned** `docker` client (from `download.docker.com`, arch-mapped from
`dpkg`) next to the `gcc g++ git` dev-toolkit line. Client-in-image + host-socket
is the canonical DooD recipe (official `docker:cli`, GitLab-runner helper, Jenkins
docker-CLI agent). Static binary → no glibc coupling; pinned → determinism-ratchet.
**The `lochan-backend-dev:latest` image must be rebuilt** with this layer before
the acceptance test.

## Usage (from the gyanam workspace root)

```bash
# Full install wizard for one app (silent = validated build→db→seed→verify→deploy):
APP=longterm01 docker compose \
  -f docker/compose.tooling.yml \
  run --rm daksh-tooling install --app longterm01 --silent

# Any single daksh verb the wizard composes:
APP=longterm01 docker compose -f docker/compose.tooling.yml \
  run --rm daksh-tooling build-app longterm01
APP=longterm01 docker compose -f docker/compose.tooling.yml \
  run --rm daksh-tooling verify longterm01
```

For a **single verb** on a venv-less host you can also use the shell shim
`util/scripts/daksh-docker <verb> …` — it applies the same socket mount +
`network_mode: host` for the DooD verbs (build/build-app/deploy/migrate/seed-demo/
verify/intent-acceptance) and picks the dev image for them automatically. This
compose file is the **wizard-flow vehicle**; `daksh-docker` is the **single-verb**
vehicle. Both share the DooD seam.

## Three hard rules (mirrors `compose.playwright.yml` / `compose.test.yml`)

1. **Prod never imports this.** Separate opt-in file; the tooling image is
   DEV/CI-only. The production build chain never runs it.
2. **Opt-in via `-f docker/compose.tooling.yml`** (`profiles: [tooling]`).
3. **Running app containers are never modified.** The sidecar is an ephemeral
   sibling that drives the daemon; the app's own containers do the DB work (daksh
   `docker exec`s *into* them).

## Fail-loud (no silent swallow)

The daksh verbs fail closed — a non-zero from any verb stops the pipeline
([[no-silent-try-except-fail-loudly-at-boot]]). The `daksh-docker` shim maps a
could-not-start to exit `86` (reserved) so a crash is never mistaken for a
pass/fail verdict. When a DooD verb is invoked but the socket is absent, the shim
fails loud with a corrective message rather than letting the verb die cryptically
mid-run.

## Decision trail

- `daksh-install-wizard-SEQUENCED-PLAN.md` §2 (DooD ratified A) · §0.5 (two-mode
  one-pipeline) · §3.6 (fail-loud contract)
- Q-S2-10 = A (DooD sidecar) · Q-S2-11 = A (cross-repo: this file + `daksh-docker`
  live in gyanam; the wizard wiring in framework) · Q-S2-12 = A (one socket
  service) · Q-S2-13 = C (static docker CLI in the dev image) · host-reach =
  `network_mode: host`
- Precedent: DooD over dind (Petazzoni), Testcontainers socket-mount pattern,
  official `docker:cli`.
