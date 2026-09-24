# Agent context: harbor-active-active-on-kind

Goal: **Harbor in active-active (HA) mode** on **KinD** — multiple replicas behind ingress with shared external PostgreSQL, Redis and S3 storage. Started as a copy of `harbor-on-kind` @ `b65df71`, a working single-node lab (Harbor + a tiny stdlib-only Python demo app pushed to Harbor and deployed via kubectl/Helm).

## HA work: Phases 0–4 done and re-verified from scratch

Work follows **`backlog.md`** (HA Phases 0→5). No design decisions are open (see `backlog.md`: 14 nodes, Patroni + Consul ×3, HAProxy as Harbor LB, Garage (S3) on its own node, D3 Redis Sentinel as an assumption). Success is two-staged: first the whole stand working across the 14 nodes (milestone 1, `H3.5`), only then the Phase 4 failure tests count. Target architecture: see `backlog.md` → "Целевая архитектура" (`hb-lb` balances PG/Redis, it is not the Harbor ingress). Do not invent versions: any new component gets a pinned version recorded first. Done so far: 14-node cluster (`hack/config/kind-cluster.yaml`), Infra LB, Consul, Patroni/PostgreSQL, Valkey/Sentinel, HAProxy, MinIO (`make cluster infra-lb ha-deps`; manifests in `hack/ha/`, dependencies live in namespace `harbor-deps`, generated credentials in Secrets there). Harbor itself runs in HA (`make harbor-ha`, `hack/config/harbor-ha.yaml`) and `make deploy-app` works (the demo app runs on the control-plane node). Milestone 1 (H3.5) was accepted by the user on 2026-09-24; the milestone 2 failure tests (H4.1–H4.7) and a from-scratch rebuild (H5.3) passed. **Left:** final documentation review (H5.1/H5.2), Ansible port of the runbook (H5.4), image cache for rebuilds (H5.5, needs the user's decision). The "baseline" sections below describe the inherited single-node behavior.

## Layout

| Path | Role |
|------|------|
| `backlog.md` | Harbor active-active plan, open decisions, pins — source of truth |
| `Makefile` | KinD cluster lifecycle + Harbor install entrypoints |
| `hack/install-infra.sh` | Infra LB: MetalLB → ingress-nginx on the `lb` nodes (`make infra-lb`), **with chart version pins** |
| `hack/install.sh` | `install-infra.sh`, then Harbor (Helm) — baseline values, not HA yet |
| `docs/stand-topology.md` | Stand map: nodes and roles, addresses and ports, data locations, secrets (Russian) |
| `docs/verification-runbook.md` | Stand verification runbook (V1..V10 checks with expected results); to be ported to Ansible (H5.4) |
| `hack/install-harbor-ha.sh` | Harbor HA install (`make harbor-ha`): Secrets in `default`, then pinned Helm chart with `hack/config/harbor-ha.yaml` |
| `hack/tests/` | Failure-test scripts for Phase 4 (`h42-kill-during-push.sh`, `h43-rolling-update.sh` + `h43_analyze.py`, `h44-node-loss.sh` + `h44_analyze.py`, `h45-app-rollout.sh`, `h46-proxy-cache.sh`, `h41-push-pull.sh`, `h47-role-failure.sh` + `h47_analyze.py`) |
| `hack/helm-postrender.py` | Helm post-renderer for Harbor: adds `preStop` sleep to core/registry/portal (needs PyYAML) |
| `hack/ha/` | HA dependency manifests: `consul.yaml`, `postgres.yaml` + `patroni/` (image build), `redis.yaml`, `haproxy.yaml`, `s3.yaml` + `s3-init.sh` |
| `hack/deploy-app.sh` | Build/push demo image, trust Harbor's CA on the node, deploy the app (`make deploy-app`, run after `install`) |
| `hack/phase0-prepare.sh` | Phase 0 baseline checks → `hack/phase0-baseline.log` |
| `hack/config/` | `kind-cluster.yaml` (14 nodes), Helm values / MetalLB pool (`harbor.yaml`, `nginx.yaml`, `metallb.yaml`, `lb-ipaddresspool.yaml`) |
| `hack/add_host.sh` | Append Harbor hostname to `/etc/hosts` |
| `python-docker-hello-kube/` | Sample stdlib `http.server` app, Dockerfile, raw `deployment.yml` |
| `helm-hello-kube/` | Helm chart for the same app |
| `bin/` | Local tools (kind); gitignored |

## Canonical defaults (baseline stack, single-node)

- Cluster name: `harbor` → context `kind-harbor`
- Kind CLI: `v0.30.0` (under `./bin`; delete stale binary after version bump)
- KinD node: `kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a`
- MetalLB chart: `0.16.1`
- ingress-nginx chart: `4.15.1` (app `1.15.1`)
- Harbor chart / app: `1.19.2` / `2.15.2`
- LB IP / Harbor host: match your Docker `kind` network (this lab: `172.20.0.100` → `core.harbor.domain`)
- MetalLB pool: `<LB_IP>–<LB_IP>+10` (this lab: `172.20.0.100–172.20.0.110`)
- Harbor admin: `admin` / `Harbor12345`
- Demo project / image: `core.harbor.domain/python/hello:1.0`
- App pull secret name: `harbor`
- App listens on port `5000`; `GET /` → `Hello, Kube! (from <pod hostname>)`, `GET /healthz` → `ok` (readiness/liveness probe target)

**Note:** LB subnet must match the Docker `kind` network (`docker network inspect kind`). Adjust `LB_IP` and YAML pools if the host subnet differs.

## Typical flow

1. `make cluster` → `make add-host` → `make install`
2. Host Docker must trust `HARBOR_HOST` (`insecure-registries`) — one-time, needs interactive `sudo`, `make deploy-app` checks and tells you the exact command if missing
3. `make deploy-app` — creates project `python`, logs in, builds/pushes the image, trusts Harbor's CA on the KinD node, creates the pull secret, deploys the raw-YAML app
4. Optional: deploy via `helm-hello-kube` instead/as well, or `helm package` + OCI push to Harbor (see README)
5. Cleanup: `make cluster-delete`

## Conventions for agents

- Follow `backlog.md` phase order; mark checklist items done when finished.
- Prefer `make` targets over ad-hoc kind/helm one-liners when they exist.
- Always pin Helm chart `--version` in `install.sh` (no floating latest).
- Keep Harbor hostname, credentials, and image paths consistent across Dockerfile tags, `deployment.yml`, and `helm-hello-kube/values.yaml`.
- Prefer Helm OCI (`oci://…`) over ChartMuseum for chart distribution.
- Do not commit secrets, `ca.crt`, or contents of `bin/`.
- README is the human runbook (still the single-node one until HA phases add to it); this file is agent orientation.
- `CLUSTER` / `LB_IP` defaults intentionally match `harbor-on-kind` (only one lab cluster runs at a time — decision D5): `make cluster-delete` the other repo's cluster before `make cluster` here.
