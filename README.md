# harbor-active-active-on-kind

Harbor in active-active mode on KinD: several replicas of core, portal, registry and jobservice behind ingress, sharing external PostgreSQL, Redis (Valkey) and S3-compatible object storage, with the goal of surviving the loss of a replica.

**Status:** in progress. Phases 0-2 are done: the 14-node cluster, Infra LB, Consul, PostgreSQL under Patroni, Valkey with Sentinel, HAProxy (Harbor LB) and MinIO are up (`make cluster infra-lb ha-deps`). Harbor itself is not yet deployed in HA mode (Phase 3), so `make install` and `make deploy-app` do not work on this cluster yet. The plan, design decisions (D1-D10) and acceptance criteria are in [backlog.md](backlog.md) (written in Russian). The Harbor sections below describe the inherited single-node baseline from [harbor-on-kind](https://github.com/it255ru/harbor-on-kind).

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

- Linux host with Docker, Go, `kubectl`, `helm` 3.x and `openssl` (`kubectl` within one minor version of the pinned Kubernetes)
- Host inotify limits raised for 14 nodes: `fs.inotify.max_user_instances=2048`, `fs.inotify.max_user_watches=1048576` (persist in `/etc/sysctl.d/`; needs `sudo`, not managed by this repo)
- Resources: with Phases 0-2 up (no Harbor yet) the 14 node containers use about 4 GiB RAM; the full stand with Harbor is estimated at 12-13 GiB (not yet measured). Docker images take about 8 GB of disk.
- Internet access to Docker Hub and quay.io; every node pulls the images of its own role
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
| MinIO client `mc` | `RELEASE.2025-08-13T08-35-41Z` |

## Building the stand

```bash
make cluster       # 14-node kind cluster "harbor" (hack/config/kind-cluster.yaml), context kind-harbor
make infra-lb      # MetalLB + ingress-nginx x2 on the lb nodes
make ha-deps       # consul, postgres, redis, harbor-lb, minio - in this order
make cluster-delete
```

`make ha-deps` runs these individually runnable targets, and the order matters: `consul` -> `postgres` (Patroni needs Consul) -> `redis` -> `harbor-lb` (HAProxy needs PostgreSQL and Redis backends) -> `minio`. Every target is idempotent.

Measured from scratch (2026-09-24): `cluster` + `infra-lb` about 7 min, `ha-deps` about 4 min, dominated by image pulls.

Harbor itself is **not** deployed in HA mode yet (backlog Phase 3): `make install` and `make deploy-app` still target the single-node baseline values and will not work on this cluster, because every worker is tainted by role and `hack/config/harbor.yaml` has no tolerations. `make add-host` and the Docker `insecure-registries` step below are only needed once Harbor is up.

### Topology and placement

Workers carry the label and taint `harbor-ha/role=<role>` (`NoSchedule`). kind names them `harbor-worker` (app), `harbor-worker2` (app), `3-4` (lb), `5-6` (pg), `7-9` (redis), `10-12` (consul), `13` (s3). Anything new must set both a `nodeSelector` and a matching toleration, otherwise it stays `Pending`. Which pod lands on which node within a role is not fixed; check with `kubectl get pods -A -o wide`.

The Infra LB shares the `lb` nodes with HAProxy (there are no dedicated ingress nodes in the 14-node layout).

Everything HA-related lives in namespace `harbor-deps`; manifests are in `hack/ha/`:

| Component | Manifest | In-cluster address |
|-----------|----------|--------------------|
| Consul x3 | `consul.yaml` | `consul.harbor-deps:8500` |
| PostgreSQL x2 + Patroni | `postgres.yaml`, `patroni/` | via HAProxy: `harbor-lb.harbor-deps:5432` (database `registry`, user `harbor`) |
| Valkey x3 + Sentinel sidecars | `redis.yaml` | via HAProxy: `harbor-lb.harbor-deps:6379` |
| HAProxy x2 (Harbor LB) | `haproxy.yaml` | `harbor-lb.harbor-deps` (stats: `:8404/stats`) |
| MinIO | `minio.yaml` | `minio.harbor-deps:9000` (bucket `registry-blobs`) |

### Credentials

Passwords are generated with `openssl rand` on the first run of each target and stored only in Secrets in `harbor-deps` (`pg-credentials`, `redis-credentials`, `minio-credentials`); nothing is committed. Read one with, for example:

```bash
kubectl -n harbor-deps get secret pg-credentials -o jsonpath='{.data.harbor}' | base64 -d
```

The services keep their state on PVCs, and that state contains the passwords that were current at initialisation. To reset a component, delete its Secret **and** its PVCs (`data-<name>-N`) together; deleting only the Secret makes the next run generate a password that no longer matches the data. After `make cluster-delete` everything starts clean.

### Verifying the stand

The full step-by-step runbook (what to run, what to expect, what to do on failure, and a plan to port it to Ansible) is in [docs/verification-runbook.md](docs/verification-runbook.md). Quick smoke test:

```bash
kubectl get nodes                                    # 14 x Ready
kubectl get pods -A -o wide                          # every pod on a node of its own role
kubectl -n harbor-deps exec consul-0 -- consul operator raft list-peers            # 1 leader + 2 followers
kubectl -n harbor-deps exec pg-0 -- patronictl -c /etc/patroni/patroni.yml list    # 1 Leader + 1 Replica (streaming)
kubectl -n harbor-deps exec redis-0 -c sentinel -- valkey-cli -p 26379 sentinel ckquorum mymaster
kubectl -n harbor-deps exec deploy/harbor-lb -- wget -qO- 'http://127.0.0.1:8404/stats;csv'   # postgres/redis backends: one UP each
curl -s -o /dev/null -w '%{http_code}\n' http://172.20.0.100/                      # 404 from ingress-nginx until Harbor is installed
```

### Things to know

- **Image pulls can fail transiently** on a cold start (`ErrImagePull`/`ImagePullBackOff`, e.g. Docker Hub token fetch errors or a quay.io `NotFound`). Kubernetes retries and the pods recover on their own; do not re-create the cluster because of it.
- **The PostgreSQL+Patroni image is built locally** (`make pg-image`, run by `make postgres`) and loaded with `kind load` into the two `pg` nodes only (`imagePullPolicy: Never`). It disappears with the cluster; `make postgres` rebuilds it. It needs Docker Hub and PyPI access at build time.
- **HAProxy does not reload on config change.** After editing `haproxy-config` in `hack/ha/haproxy.yaml`, bump the `config-version` pod annotation so the Deployment rolls.
- **Kubernetes does not expand `$(HOSTNAME)`** in `args`; use the downward API (`POD_NAME`) as `consul.yaml` does. Three Consul servers sharing one node name never form a quorum.
- **MinIO** is a single node with a single drive (no erasure coding) and the community edition is no longer maintained; it stands in for Ceph RGW only.
- **Consul has no ACL/TLS, Redis Sentinel has no password, PostgreSQL replication is asynchronous** - deliberate for the lab (backlog D8).
- Failure behaviour (Patroni failover, Sentinel failover, losing an HAProxy) has **not** been tested yet: those checks belong to milestone 2 (Phase 4) and count only after milestone 1 is accepted.

## Baseline: single-node Harbor (inherited, currently not usable on this cluster)

```bash
make add-host      # adds "$LB_IP core.harbor.domain" to /etc/hosts (sudo)
make install       # infra-lb, then Harbor with baseline values
make deploy-app    # project, image build/push, CA trust, pull secret, demo app
```

`make help` lists all targets. Overridable variables: `CLUSTER`, `KIND_IMAGE`, `KIND_VERSION`, `LB_IP`, `HARBOR_HOST`, `LOCALBIN`, `PG_IMAGE`.

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
