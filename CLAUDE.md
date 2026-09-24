# CLAUDE.md

Repo: **harbor-active-active-on-kind**. Goal: run **Harbor in active-active (HA) mode** on KinD — several replicas of core/portal/registry/jobservice (maybe trivy) behind ingress, sharing external PostgreSQL, Redis (Valkey) and S3-compatible object storage — and prove it survives losing a replica.

**Provenance:** started 2026-09-24 as a copy of `harbor-on-kind` @ `b65df71` (full git history kept; not a GitHub fork, since GitHub forbids same-owner forks). Original single-node lab: https://github.com/it255ru/harbor-on-kind. Everything under "Baseline" below is verified-working *single-node* behavior inherited from there. **The HA work itself is not started** — the plan and the open design decisions are in `backlog.md` (written in Russian, source of truth).

See also: `AGENTS.md` (agent orientation), `README.md` (still the single-node runbook; HA sections get added as phases land).

## HA work — read `backlog.md` first

Rules:
- Work `backlog.md` phases in order; tick `- [ ]` → `- [x]` as items finish.
- The open decisions in `backlog.md` ("Открытые решения": D1 node topology, D2 PostgreSQL, D3 Redis, D4 MinIO, D6 success criteria) belong to the user — ask, don't pick silently. D5 (isolation from harbor-on-kind) is settled, see below.
- Don't invent versions. Every new component (PostgreSQL, Redis/Valkey, MinIO, any operator) gets an explicit pinned version recorded in `backlog.md` and the table below **before** it is installed.
- Verify Harbor chart keys against `helm show values harbor/harbor --version 1.19.2`, not memory.
- **One lab cluster at a time (decided 2026-09-24, D5):** `Makefile` deliberately keeps the same defaults as `harbor-on-kind` (`CLUSTER=harbor`, `LB_IP=172.20.0.100`, pool `172.20.0.100–110`) — only one of the two repos' clusters runs at a time, so they can't clash. Before `make cluster` here, `make cluster-delete` the other repo's cluster. The host's `/etc/hosts` entry and Docker `insecure-registries` for `core.harbor.domain` are reused as-is. If HA needs more LB IPs, widen the pool inside the same subnet and update all coupled files (see "Changing the LB IP").
- Keep the single-node baseline working until HA replaces it deliberately; if something breaks it, say so.

## Baseline (inherited, verified on harbor-on-kind)

| Component | Pinned version |
|-----------|----------------|
| Kind CLI | `v0.30.0` |
| Node image | `kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a` |
| MetalLB chart | `0.16.1` |
| ingress-nginx chart | `4.15.1` (app `1.15.1`) |
| Harbor chart / app | `1.19.2` / `2.15.2` |

Chart `1.19.2` HA-relevant keys (checked against its default values): `database.type: external` + `database.external.*`; `redis.type: external` + `redis.external.*` (bundled Redis in 2.15.2 is Valkey); `persistence.imageChartStorage.type: s3` (`disableredirect: true` for MinIO, `caBundleSecretName` for a self-signed store); `replicas` under `core`, `portal`, `registry`, `jobservice`, `trivy` (all `1` by default).

Baseline was proven end to end: `make cluster` → `make add-host` → `make install` → `make deploy-app` → raw-YAML and Helm deploys, `helm test`, OCI chart push/pull.

## Commands

```bash
make help            # list targets
make cluster         # installs ./bin/kind via `go install` if missing, creates cluster "harbor" (context kind-harbor)
make add-host        # appends "$LB_IP $HARBOR_HOST" to /etc/hosts (uses sudo)
make install         # hack/install.sh: helm repos → MetalLB → IPAddressPool → ingress-nginx → Harbor
make deploy-app      # hack/deploy-app.sh: project `python` → docker login/build/push → node CA trust → pull secret → kubectl apply + rollout restart (run after `install`; idempotent)
make cluster-ctx     # kubectl use-context kind-harbor
make cluster-delete

./hack/phase0-prepare.sh [--create-branch] [--init-git]   # host tool checks (docker/helm/go/kubectl); rewrites hack/phase0-baseline.log
```

Overridable Make vars: `CLUSTER`, `KIND_IMAGE`, `KIND_VERSION`, `LB_IP`, `HARBOR_HOST`, `LOCALBIN`.

Gotchas:
- The Makefile runs `go env GOBIN` at parse time — Go must be on `PATH` even for `make help`.
- `$(KIND)` is a file target: after bumping `KIND_VERSION`, **delete `./bin/kind`** or Make won't reinstall.
- `make install` uses the current kube-context; run `make cluster-ctx` if unsure.
- `hack/add_host.sh` greps for the hostname as a substring and skips if found — it won't fix a wrong IP.
- Kind clusters are never upgraded in place: `make cluster-delete` then `make cluster`.
- `sudo` is interactive-only in agent sessions: `make add-host` (when the entry is missing) and the host Docker `insecure-registries` change must be run by the user. `make deploy-app` fails fast with the exact commands if the latter is missing.
- `make deploy-app` always redoes the node's CA trust + `systemctl restart containerd` (Harbor's self-signed CA regenerates on every install). Pods survive; ones already `Terminating` may take longer to disappear — transient, not a hang.
- Use `systemctl reload docker`, not `restart`, after editing `daemon.json` while a cluster is running.

## Architecture / coupling (baseline, single-node)

```
host ── /etc/hosts: core.harbor.domain → 172.20.0.100
          │
   MetalLB L2 pool 172.20.0.100–110 (hack/config/lb-ipaddresspool.yaml, metallb.io/v1beta1)
          │
   ingress-nginx Service pinned to 172.20.0.100 (hack/config/nginx.yaml annotation metallb.universe.tf/loadBalancerIPs)
          │
   Harbor (expose.type=ingress, className nginx, host core.harbor.domain, self-signed TLS) — hack/config/harbor.yaml
```

**Changing the LB IP** (needed when `docker network inspect kind` isn't the baked-in subnet — here it was `172.20.0.0/16`, not the `172.17.0.0/16` first assumed) means updating together: `Makefile` `LB_IP`, `hack/config/lb-ipaddresspool.yaml`, `hack/config/nginx.yaml`, host `/etc/hosts`, the node's `/etc/hosts`, and IPs in README examples. Always re-check `docker network inspect kind` after a fresh `make cluster`.

**MetalLB L2 gotcha:** if a `LoadBalancer` IP never resolves (ARP `(incomplete)`, speaker logs flapping `serviceAnnounced`/`serviceWithdrawn` with `reason: notOwner`), check `kubectl get endpoints <svc>` and pod status first — MetalLB won't hold a stable announcement for a Service with no Ready endpoints. Restarting the speaker did not help; fixing the crash-looping backend did.

`hack/config/harbor.yaml` uses `expose.ingress.className: nginx`; Notary has no templates or values in chart 1.19.2 (the old `notary` blocks were dead config and are gone).

Registry trust is manual outside `deploy-app`: host Docker `insecure-registries: ["core.harbor.domain"]`; for the KinD node, fetch `ca.crt` (`curl -sk https://core.harbor.domain/api/v2.0/systeminfo/getcert`), `docker cp` it to `<cluster>-control-plane:/usr/local/share/ca-certificates/`, `update-ca-certificates`, add the hosts entry in the node, `systemctl restart containerd`.

## Demo app

- `python-docker-hello-kube/hello.py` — **stdlib-only** `http.server`, no pip deps. `GET /` → `Hello, Kube! (from <pod hostname>)`, `GET /healthz` → `ok`. Port 5000. Handy for HA checks: the response shows which replica answered.
- `Dockerfile` pins `python:3-alpine@sha256:9e9fde4d…` and only `COPY hello.py .`. (History: the original Flask 2.2.2 app broke because `Werkzeug` was unpinned and pip resolved an incompatible 3.x — hence no dependencies at all.)
- `deployment.yml` (2 replicas + LoadBalancer Service `hello-service`, label `app: hello`) and `helm-hello-kube/templates/deployment.yaml` both have readiness/liveness probes on `/healthz`.
- `helm-hello-kube/`: Deployment/Service names and `app: hello-kube` selector are **hardcoded**; `helm test` only works when the release is named `hello-kube`. Chart `appVersion: "1.16.0"` doesn't match image tag `1.0` — known, harmless.
- Values that must stay identical across Dockerfile usage, `deployment.yml` and `helm-hello-kube/values.yaml`: image `core.harbor.domain/python/hello:1.0`, pull secret `harbor` (type `docker-registry`), port `5000`.
- Charts are distributed via Helm OCI (`helm push … oci://core.harbor.domain/python/hello --ca-file ./ca.crt`), not ChartMuseum.

## Conventions

- Always pass `--version` to every `helm upgrade -i` in `hack/install.sh` (and any new install script).
- Prefer `make` targets over ad-hoc kind/helm commands.
- Don't commit `bin/`, `ca.crt`, `*.tgz` or real credentials (`admin` / `Harbor12345` is the lab-only default in `harbor.yaml`). `.gitignore` covers these.
- Keep `README.md` and `AGENTS.md` in sync with `Makefile`/`hack/` whenever pins, topology or the demo app change.
