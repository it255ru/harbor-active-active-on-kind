# harbor-active-active-on-kind

Harbor in active-active mode on KinD: several replicas of core, portal, registry and jobservice behind ingress, sharing external PostgreSQL, Redis (Valkey) and S3-compatible object storage, with the goal of surviving the loss of a replica.

**Status:** in progress. Phases 0-3 are done: the 14-node cluster, Infra LB, Consul, PostgreSQL under Patroni, Valkey with Sentinel, HAProxy (Harbor LB), MinIO and Harbor itself (2 replicas each of core, portal, registry and jobservice) are up, and image and OCI chart push/pull work through the full chain (`make cluster infra-lb ha-deps harbor-ha deploy-app`). Milestone 1 (the whole stand working across the 14 nodes) was accepted on 2026-09-24; the failure tests (Phase 4, milestone 2) are next. The plan, design decisions (D1-D10) and acceptance criteria are in [backlog.md](backlog.md) (written in Russian).

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

- Linux host with Docker, Go, `kubectl`, `helm` 3.x, `openssl` and `python3` with PyYAML (used by the Helm post-renderer) (`kubectl` within one minor version of the pinned Kubernetes)
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

HA components (installed by `make ha-deps`; image digests are in `backlog.md`):

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

Then install Harbor and the demo app:

```bash
make harbor-ha     # Harbor 1.19.2 in HA mode (hack/config/harbor-ha.yaml); DRY_RUN=1 renders against the cluster only
make add-host      # adds "$LB_IP core.harbor.domain" to /etc/hosts (sudo, once)
make deploy-app    # project, image build/push, CA trust, pull secret, demo app
```

`make install` runs `infra-lb` and `harbor-ha` in one go. Before `make deploy-app`, the host Docker daemon must trust the registry (see below). The single-node baseline values (`hack/config/harbor.yaml`) are no longer used by any target.

### Topology and placement

Full map of the nodes, roles, addresses, ports, data locations and secrets: [docs/stand-topology.md](docs/stand-topology.md).

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

- **Harbor rolling updates rely on `topologySpreadConstraints` with `matchLabelKeys: [pod-template-hash]`, not a required `podAntiAffinity`.** Without `matchLabelKeys` old and new pods are counted together and a rollout can leave both replicas on one node (running pods are never rebalanced). With 2 replicas on 2 `app` nodes a required anti-affinity deadlocks every rolling update (the surge pod has no third node and `maxUnavailable` rounds down to 0). `harbor-lb` keeps anti-affinity but rolls with `maxSurge: 0`. Keep this in mind for any new 2-replica workload on a 2-node role.
- **The Harbor token key must be PKCS#1** (`BEGIN RSA PRIVATE KEY`). A PKCS#8 key makes core answer 500 on `/v2/` (`unable to get PrivateKey from PEM type: PRIVATE KEY`); `hack/install-harbor-ha.sh` generates it correctly. If `harbor-ha-token` was created by an older version of the script, delete the Secret and re-run `make harbor-ha`.
- **jobservice restarts 2-3 times on first start** (core is not accepting connections yet) and then runs normally.
- **The demo app runs on the control-plane node** (workers are tainted by role, and `deploy-app.sh` installs Harbor's CA only there); `deployment.yml` and the `helm-hello-kube` chart carry the matching `nodeSelector`/toleration.
- **The Harbor chart resolves `existingSecret` with `lookup` at render time**, so the Secrets must exist before `helm install`; `helm template` without a cluster shows empty passwords. Use `DRY_RUN=1 make harbor-ha`.
- **Rolling updates of core/registry/portal need the `preStop` sleep.** The Harbor chart has no `preStop` hook, so a terminating registry pod was still receiving requests from core for a few seconds and core answered `502` (and requests stalled for ~5 s). `hack/helm-postrender.py`, applied by `make harbor-ha` as a Helm post-renderer, adds `preStop: sleep 15`; with it, continuous pulls during rolling updates showed 0 errors (H4.3).
- **Everything shares one host disk.** Bursts of I/O (image builds with `dd`, pushes of gigabytes) can stall etcd and the apiserver: `kube-controller-manager` and `kube-scheduler` then lose their leader-election lease and crash-loop for minutes (pods are not recreated meanwhile), Valkey logs `AOF fsync is taking too long`, and Sentinel may fail over. Lease timings (60/40/10 s) and Sentinel `down-after-milliseconds` (15000) are tuned for this; still, keep test data small and let the load settle. The `kind-cluster.yaml` leader-election patch has not been verified by a full rebuild yet.
- **Delete test artifacts from Harbor by digest, not by tag.** Deleting an artifact removes all its tags; a test tag on the same digest as `python/hello:1.0` deletes the demo image (`make deploy-app` restores it).
- **Image pulls can fail transiently** on a cold start (`ErrImagePull`/`ImagePullBackOff`, e.g. Docker Hub token fetch errors or a quay.io `NotFound`). Kubernetes retries and the pods recover on their own; do not re-create the cluster because of it.
- **The PostgreSQL+Patroni image is built locally** (`make pg-image`, run by `make postgres`) and loaded with `kind load` into the two `pg` nodes only (`imagePullPolicy: Never`). It disappears with the cluster; `make postgres` rebuilds it. It needs Docker Hub and PyPI access at build time.
- **HAProxy does not reload on config change.** After editing `haproxy-config` in `hack/ha/haproxy.yaml`, bump the `config-version` pod annotation so the Deployment rolls.
- **Kubernetes does not expand `$(HOSTNAME)`** in `args`; use the downward API (`POD_NAME`) as `consul.yaml` does. Three Consul servers sharing one node name never form a quorum.
- **MinIO** is a single node with a single drive (no erasure coding) and the community edition is no longer maintained; it stands in for Ceph RGW only.
- **Consul has no ACL/TLS, Redis Sentinel has no password, PostgreSQL replication is asynchronous** - deliberate for the lab (backlog D8).
- Failure behaviour (Patroni failover, Sentinel failover, losing an HAProxy) has **not** been tested yet: those checks belong to milestone 2 (Phase 4) and count only after milestone 1 is accepted.

## Host setup, Harbor and demo app

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
