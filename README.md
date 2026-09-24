# harbor-active-active-on-kind

Harbor in active-active mode on KinD: several replicas of core, portal, registry and jobservice behind ingress, sharing external PostgreSQL, Redis (Valkey) and S3-compatible object storage, with the goal of surviving the loss of a replica.

**Status:** the HA work is planned, not started. The plan, design decisions (D1-D10) and acceptance criteria are in [backlog.md](backlog.md) (written in Russian). What `Makefile` and `hack/` implement today is the inherited single-node baseline from [harbor-on-kind](https://github.com/it255ru/harbor-on-kind); the runbook below covers that baseline. HA sections are added as backlog phases land.

## Target architecture

14 KinD nodes: 1 control-plane plus 13 workers, with the role set by label/taint.

| Role | Nodes | Component |
|------|-------|-----------|
| app | 2 | Harbor core / portal / registry / jobservice |
| lb | 2 | HAProxy in front of PostgreSQL and Redis (not the Harbor ingress) |
| pg | 2 | PostgreSQL under Patroni |
| redis | 3 | Valkey with Sentinel (assumption, D3) |
| consul | 3 | Consul servers, DCS for Patroni |
| s3 | 1 | MinIO, stands in for Ceph RGW; registry blobs |

Entry point: ingress-nginx + MetalLB (Infra LB). Backups, Prometheus and Nexus are out of scope.

Success is two-staged: first the whole stand works across the 14 nodes (milestone 1), only then do the failure tests count (milestone 2). See `backlog.md`.

## Requirements

- Linux host with Docker, Go and `kubectl` (within one minor version of the pinned Kubernetes)
- `helm` 3.x
- Host inotify limits raised for a 14-node cluster: `fs.inotify.max_user_instances=2048`, `fs.inotify.max_user_watches=1048576` (persist in `/etc/sysctl.d/`)
- Roughly 30 GB free RAM and 10 GB free disk for the full stand (estimate, not yet measured)
- Only one lab cluster at a time: `make cluster-delete` the `harbor-on-kind` cluster before `make cluster` here (same cluster name, LB IP and pool)

## Pinned versions

Every component is pinned. Changing a pin means updating `Makefile` / `hack/install.sh`, this table, `CLAUDE.md` and `backlog.md` together.

Baseline (installed by `make install`):

| Component | Version |
|-----------|---------|
| Kind CLI | `v0.30.0` |
| KinD node image | `kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a` |
| MetalLB chart | `0.16.1` |
| ingress-nginx chart | `4.15.1` (app `1.15.1`) |
| Harbor chart / app | `1.19.2` / `2.15.2` |

HA components (pinned in Phase 0, not installed yet; image digests are in `backlog.md`):

| Component | Version |
|-----------|---------|
| PostgreSQL | `18.6-alpine3.24` |
| Patroni | `4.1.5` |
| Consul | `1.22.7` |
| HAProxy | `3.4.4-alpine3.24` |
| Valkey + Sentinel | `9.0.6-alpine3.24` |
| MinIO | `RELEASE.2025-09-07T16-13-09Z` |

## Quick start (single-node baseline)

```bash
make cluster       # kind cluster "harbor", context kind-harbor
make add-host      # adds "$LB_IP core.harbor.domain" to /etc/hosts (sudo)
make install       # MetalLB, ingress-nginx, Harbor with pinned versions
make deploy-app    # project, image build/push, CA trust, pull secret, demo app
make cluster-delete
```

`make help` lists all targets. Overridable variables: `CLUSTER`, `KIND_IMAGE`, `KIND_VERSION`, `LB_IP`, `HARBOR_HOST`, `LOCALBIN`.

One-time host step that `make deploy-app` cannot do (needs interactive `sudo`): add the registry to Docker `insecure-registries` and reload.

```bash
# merge into the existing /etc/docker/daemon.json
{ "insecure-registries": ["core.harbor.domain"] }
sudo systemctl reload docker    # reload, not restart, while a cluster is running
```

Harbor UI: https://core.harbor.domain (`admin` / `Harbor12345`, lab-only default).

## Load balancer IP

Docker picks the subnet of the `kind` network per machine. After `make cluster`, check it:

```bash
docker network inspect -f '{{.IPAM.Config}}' kind
```

The defaults assume `172.20.0.0/16`. If yours differs, update together: `LB_IP` in `Makefile`, `hack/config/lb-ipaddresspool.yaml`, `hack/config/nginx.yaml`, host `/etc/hosts` and the node's `/etc/hosts`. `hack/add_host.sh` skips the entry if the hostname already exists, so it will not correct a wrong IP.

## What `make deploy-app` does

Idempotent; safe to re-run after editing `hello.py`.

1. Creates the `python` project in Harbor.
2. Logs in, builds `core.harbor.domain/python/hello:1.0` from `python-docker-hello-kube/` and pushes it.
3. Installs Harbor's CA in the KinD node (`update-ca-certificates`, hosts entry, `systemctl restart containerd`). Harbor's self-signed CA regenerates on every install, so this is redone every time. Running pods are not affected.
4. Creates the `harbor` docker-registry pull secret.
5. Applies `deployment.yml` and restarts the rollout.

Manual CA fetch, if needed: `curl -sk https://core.harbor.domain/api/v2.0/systeminfo/getcert -o ca.crt`.

## Demo app

`python-docker-hello-kube/hello.py` is stdlib-only (`http.server`, no pip dependencies), port 5000:

- `GET /` returns `Hello, Kube! (from <pod hostname>)`, which shows which replica answered
- `GET /healthz` returns `ok` (used by the readiness/liveness probes)

Deploy options:

```bash
kubectl apply -f deployment.yml                 # 2 replicas + LoadBalancer Service hello-service
helm install hello-kube ./helm-hello-kube       # release must be named hello-kube for `helm test`
```

Values that must stay identical across the Dockerfile usage, `deployment.yml` and `helm-hello-kube/values.yaml`: image `core.harbor.domain/python/hello:1.0`, pull secret `harbor`, port `5000`.

Helm charts go to Harbor over OCI (ChartMuseum is deprecated):

```bash
helm package helm-hello-kube
helm registry login core.harbor.domain -u admin --ca-file ./ca.crt
helm push hello-kube-0.1.0.tgz oci://core.harbor.domain/python/hello --ca-file ./ca.crt
helm install hello-kube oci://core.harbor.domain/python/hello/hello-kube --version 0.1.0 --ca-file ./ca.crt
```

## Troubleshooting

- A `LoadBalancer` IP does not respond (ARP `(incomplete)`, MetalLB speaker flapping `serviceAnnounced`/`serviceWithdrawn`): check `kubectl get endpoints <svc>` and pod status first. MetalLB does not hold an announcement for a Service without Ready endpoints.
- `make` fails even for `make help`: Go must be on `PATH` (the Makefile runs `go env GOBIN` at parse time).
- After bumping `KIND_VERSION`, delete `./bin/kind`, otherwise Make will not reinstall it.
- Kind clusters are not upgraded in place: `make cluster-delete`, then `make cluster`.

## Credits

Based on [mmontes11/harbor-kind](https://github.com/mmontes11/harbor-kind) via [harbor-on-kind](https://github.com/it255ru/harbor-on-kind).
