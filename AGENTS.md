# Agent context: harbor-on-kind

Local playground: **Harbor** on a **KinD** Kubernetes cluster, plus a tiny stdlib-only Python app (no pip deps) pushed to Harbor and deployed via kubectl/Helm.

## Migration in progress

Work follows **`backlog.md`** (Phases 0→6): bump from Kind `v0.17` / K8s `1.26` / Harbor `2.8` to the target stack below. Prefer implementing backlog items in order; do not invent alternate versions.

Until a phase is done, `Makefile` / `hack/install.sh` may still show old or unpinned values — **target below is canonical**; sync code to match as you execute each phase.

## Layout

| Path | Role |
|------|------|
| `backlog.md` | Migration plan, pins, DoD — source of truth for the upgrade |
| `Makefile` | KinD cluster lifecycle + Harbor install entrypoints |
| `hack/install.sh` | Install MetalLB → ingress-nginx → Harbor (Helm), **with chart version pins** |
| `hack/deploy-app.sh` | Build/push demo image, trust Harbor's CA on the node, deploy the app (`make deploy-app`, run after `install`) |
| `hack/phase0-prepare.sh` | Phase 0 baseline checks → `hack/phase0-baseline.log` |
| `hack/config/` | Helm values / MetalLB pool (`harbor.yaml`, `nginx.yaml`, `lb-ipaddresspool.yaml`) |
| `hack/add_host.sh` | Append Harbor hostname to `/etc/hosts` |
| `python-docker-hello-kube/` | Sample stdlib `http.server` app, Dockerfile, raw `deployment.yml` |
| `helm-hello-kube/` | Helm chart for the same app |
| `bin/` | Local tools (kind); gitignored |

## Canonical defaults (target stack)

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
- README is the human runbook (updated in Phase 6); this file is agent orientation.
