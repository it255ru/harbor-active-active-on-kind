# CLAUDE.md

Repo: **harbor-active-active-on-kind**. Goal: run **Harbor in active-active (HA) mode** on KinD — several replicas of core/portal/registry/jobservice (maybe trivy) behind ingress, sharing external PostgreSQL, Redis (Valkey) and S3-compatible object storage — and prove it survives losing a replica.

**Provenance:** started 2026-09-24 as a copy of `harbor-on-kind` @ `b65df71` (full git history kept; not a GitHub fork, since GitHub forbids same-owner forks). Original single-node lab: https://github.com/it255ru/harbor-on-kind. Everything under "Baseline" below is verified-working *single-node* behavior inherited from there. **HA work status:** Phases 0–3 done (14-node cluster, Infra LB, Consul, Patroni/PostgreSQL, Valkey/Sentinel, HAProxy, MinIO, Harbor in HA, deploy-app and OCI push/pull working); milestone 1 (H3.5) was accepted by the user on 2026-09-24; Phase 4 (milestone 2, failure tests) is next and now counts — the plan and decisions are in `backlog.md` (written in Russian, source of truth).

See also: `AGENTS.md` (agent orientation), `README.md` (status, requirements and command list; Harbor HA sections get added as Phase 3 lands).

## HA work — read `backlog.md` first

Rules:
- Work `backlog.md` phases in order; tick `- [ ]` → `- [x]` as items finish.
- No design decisions are open (all settled 2026-09-24, see `backlog.md` "Решения и открытые вопросы"): D1 14 nodes (1 control-plane + app×2, lb×2, pg×2, redis×3, consul×3, s3×1), D2 Patroni + Consul, D3 Redis Sentinel (an *assumption* — prod mode unknown), D4 S3/MinIO, D5 one lab cluster at a time, D7 HAProxy as Harbor LB, D8 minimum scope, D9/D10 colors ignored and Nexus out of scope. Ask if a new decision appears — don't pick silently.
- **Success is two-staged (D6):** first *milestone 1* — the whole stand works with correct distribution over the 14 nodes (roles, placement, healthy Consul/Patroni/Redis, end-to-end push/pull via the full chain, both app replicas serving); only after it passes do the Phase 4 failure tests (*milestone 2*) count. Milestone 1 (`H3.5`) is accepted (2026-09-24), so Phase 4 results now count.
- **Target architecture** is described in `backlog.md` → "Целевая архитектура" (from the user's diagrams): Harbor app ×2 → Harbor LB ×2 (HAProxy) → PostgreSQL ×2 under Patroni with state in Consul ×3, + Redis ×3 (assumed Sentinel); blobs in S3 (Ceph in prod, MinIO stand-in here, own node); Infra LB (shared entry, ingress-nginx + MetalLB here) in front. Backups, Prometheus and Nexus appear on the diagram but are **out of scope** (D8, D10). Note `hb-lb` balances PG/Redis, it is **not** the Harbor ingress.
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

HA component pins (H0.1, 2026-09-24; images also pinned by digest — full refs and rationale in `backlog.md` → "Версии компонентов HA"):

| Component | Pinned version |
|-----------|----------------|
| PostgreSQL | `18.6-alpine3.24` (Harbor 2.15.2 bundles 18.3) |
| Patroni | `4.1.5` (PyPI; own image, extras `consul`, `psycopg3`) |
| Consul | `1.22.7` (not 2.0.x) |
| HAProxy | `3.4.4-alpine3.24` (current LTS) |
| Valkey + Sentinel | `9.0.6-alpine3.24` (Harbor bundles 9.0.3) |
| MinIO | `RELEASE.2025-09-07T16-13-09Z` (quay.io; community edition unmaintained) |
| MinIO client `mc` | `RELEASE.2025-08-13T08-35-41Z` (quay.io; one-shot bucket/user init Job) |

Chart `1.19.2` HA-relevant keys (checked against its default values): `database.type: external` + `database.external.*`; `redis.type: external` + `redis.external.*` (bundled Redis in 2.15.2 is Valkey); `persistence.imageChartStorage.type: s3` (`disableredirect: true` for MinIO, `caBundleSecretName` for a self-signed store); `replicas` under `core`, `portal`, `registry`, `jobservice`, `trivy` (all `1` by default).

Baseline was proven end to end: `make cluster` → `make add-host` → `make install` → `make deploy-app` → raw-YAML and Helm deploys, `helm test`, OCI chart push/pull.

## Verification

`docs/verification-runbook.md` is the runbook for checking the stand (checks V1..V10, expected results, diagnostics). Run the relevant checks after any change to `hack/ha/` or `hack/config/`, and keep the runbook in sync when components or commands change. It is meant to be ported to Ansible later (`backlog.md` H5.4).

## Commands

```bash
make help            # list targets
make cluster         # installs ./bin/kind via `go install` if missing, creates the 14-node cluster "harbor" from hack/config/kind-cluster.yaml (context kind-harbor)
make add-host        # appends "$LB_IP $HARBOR_HOST" to /etc/hosts (uses sudo)
make infra-lb        # hack/install-infra.sh: MetalLB → IPAddressPool → ingress-nginx, both on the `lb` nodes (tolerate the role taint)
make ha-deps        # consul → postgres → redis → harbor-lb → minio in order (after `make cluster infra-lb`); the targets below can also be run individually
make consul          # hack/ha/consul.yaml: Consul x3 StatefulSet in namespace harbor-deps on the consul nodes (DCS for Patroni)
make pg-image        # build hack/ha/patroni (PostgreSQL 18.6 + Patroni 4.1.5) and `kind load` it into the pg nodes
make postgres        # pg-image + hack/ha/postgres.yaml: PostgreSQL x2 under Patroni, Secret pg-credentials generated on first run (needs `make consul`)
make redis           # hack/ha/redis.yaml: Valkey x3 + Sentinel sidecars on the redis nodes, Secret redis-credentials generated on first run
make harbor-lb       # hack/ha/haproxy.yaml: HAProxy x2 on the lb nodes; Service harbor-lb.harbor-deps :5432 (PG primary via Patroni /primary) and :6379 (Redis master)
make minio           # hack/ha/minio.yaml: MinIO on the s3 node + bucket registry-blobs + scoped user for Harbor (Secret minio-credentials generated on first run)
make harbor-ha       # hack/install-harbor-ha.sh: creates Secrets harbor-ha-secrets/-s3/-token in `default` once, then helm-installs Harbor 1.19.2 with hack/config/harbor-ha.yaml (DRY_RUN=1 = server-side dry run only; needs infra-lb + ha-deps)
make install         # hack/install.sh: infra-lb, then harbor-ha (the old single-node values hack/config/harbor.yaml are no longer used)
make deploy-app      # hack/deploy-app.sh: project `python` → docker login/build/push → node CA trust → pull secret → kubectl apply + rollout restart (run after `install`; idempotent)
make cluster-ctx     # kubectl use-context kind-harbor
make cluster-delete

./hack/phase0-prepare.sh [--create-branch] [--init-git]   # host tool checks (docker/helm/go/kubectl); rewrites hack/phase0-baseline.log
```

Overridable Make vars: `CLUSTER`, `KIND_IMAGE`, `KIND_VERSION`, `LB_IP`, `HARBOR_HOST`, `LOCALBIN`, `PG_IMAGE`.

Gotchas:
- The Makefile runs `go env GOBIN` at parse time — Go must be on `PATH` even for `make help`.
- `$(KIND)` is a file target: after bumping `KIND_VERSION`, **delete `./bin/kind`** or Make won't reinstall.
- `make install` uses the current kube-context; run `make cluster-ctx` if unsure.
- `hack/add_host.sh` greps for the hostname as a substring and skips if found — it won't fix a wrong IP.
- Kind clusters are never upgraded in place: `make cluster-delete` then `make cluster`.
- `sudo` is interactive-only in agent sessions: `make add-host` (when the entry is missing) and the host Docker `insecure-registries` change must be run by the user. `make deploy-app` fails fast with the exact commands if the latter is missing.
- `make deploy-app` redoes the node's CA trust + `systemctl restart containerd`. Harbor's CA is now stable across `helm upgrade` (own CA in Secret `harbor-ha-ingress-tls`, `certSource: secret`; the chart's `auto` mode regenerated it on every upgrade and broke new image pulls on the node with `x509: unknown authority`), so this is only needed once after the CA is (re)created. Pods survive; ones already `Terminating` may take longer to disappear — transient, not a hang.
- Use `systemctl reload docker`, not `restart`, after editing `daemon.json` while a cluster is running.
- Harbor chart resolves `existingSecret` with `lookup` at render time: the Secrets must exist before `helm install`; `helm template` without a cluster shows empty passwords — validate with `DRY_RUN=1 make harbor-ha` instead.
- 2-replica workloads on a 2-node role: use `topologySpreadConstraints` (maxSkew 1, plus `matchLabelKeys: [pod-template-hash]` so a rollout still ends 1+1), not a required `podAntiAffinity` — that deadlocks rolling updates (surge pod has no node, maxUnavailable rounds to 0). Harbor's token key must be PKCS#1 (`openssl genrsa -traditional`). The demo app runs on the control-plane node (only place where `deploy-app.sh` installs the CA).
- HA stand: every worker is tainted `harbor-ha/role=<role>:NoSchedule`; any new workload needs a matching `nodeSelector` + toleration. Dependencies live in namespace `harbor-deps` (`hack/ha/`); passwords are generated on the first run into Secrets there — to reset a component delete its Secret **and** PVCs together.
- `make pg-image` output (`harbor-ha/patroni:4.1.5-pg18.6`) is loaded with `kind load` into the `pg` nodes only and vanishes with the cluster.
- Node-loss test (`hack/tests/h44-node-loss.sh`) kills a node container with `docker kill` and restarts it with `docker start`; killing an `app` node leaves replacement pods `Pending` (topology spread, expected) and trivy unavailable until the node returns. It always brings the node back at the end — if it is interrupted, run `docker start <node>` manually.
- H4.6 (proxy-cache): `hack/tests/h46-proxy-cache.sh` temporarily makes Docker Hub unreachable by editing the CoreDNS Corefile (NXDOMAIN for docker.io/docker.com) and restarts CoreDNS; it restores the original on exit. If it is killed, restore with `kubectl -n kube-system get cm coredns` (the original Corefile has no `template` block) and `kubectl -n kube-system rollout restart deploy/coredns`. Use a fresh proxy project name per run: deleting through the API leaves blobs in S3 and a same-name project then looks empty. Cached content is addressed by digest; tag pulls need the upstream.
- Harbor's chart has no `preStop`: without it rolling updates of registry/core give client-visible 502s. `hack/helm-postrender.py` (Helm `--post-renderer` in `install-harbor-ha.sh`, needs PyYAML) adds `preStop: sleep 15` to core/registry/portal — keep it when changing the install path.
- One host disk under everything: large writes (gigabyte pushes, `dd` image builds) stall etcd/apiserver, crash controller-manager/scheduler (leader election) and trigger Sentinel failovers. Keep failure-test data small (`hack/tests/h42-kill-during-push.sh` defaults: 2 x 200 MB, throttled with tc) and wait for the load to settle. Leader-election flags are in `kind-cluster.yaml` (not yet verified by a rebuild — H5.3); Sentinel `down-after-milliseconds` is 15000.
- Delete Harbor test artifacts by **digest**, never by tag: deleting an artifact removes all its tags (a test tag on `python/hello:1.0`'s digest deleted the demo image once).
- Cold-start image pulls fail transiently (`ErrImagePull`); pods self-heal, don't rebuild the cluster.
- Kubernetes does not expand `$(HOSTNAME)` in `args` — use the downward API env (`POD_NAME`).
- HAProxy needs a bump of the `config-version` annotation in `hack/ha/haproxy.yaml` to roll after a config change.

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
