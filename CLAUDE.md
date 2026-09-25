# CLAUDE.md

Repo: **harbor-active-active-on-kind**. Harbor in active-active (HA) mode on KinD: two replicas each of core/portal/registry/jobservice behind ingress, sharing external PostgreSQL (Patroni + Consul), Redis (Valkey + Sentinel) and S3 (Garage), on a 14-node cluster. It started on 2026-09-24 as a copy of `harbor-on-kind` @ `b65df71` (https://github.com/it255ru/harbor-on-kind, full history kept, not a GitHub fork).

**Status:** Phases 0–4 are done and were re-verified on a stand rebuilt from scratch (milestone 1 accepted by the user on 2026-09-24; failure tests H4.1–H4.7 and the from-scratch acceptance H5.3 passed). H5.4 is done (Ansible port of the runbook, `make verify`). H5.5 is done (image cache, `make images-save` / `images-load`). Phase 6 is done too (H6.1 offline cluster branch from the cache, H6.2 Patroni `synchronous_mode` measured, left off by default). Nothing is open in `backlog.md`. `backlog.md` (Russian) is the source of truth; see also `AGENTS.md` (layout, flow) and `README.md` (human runbook).

## Rules

- Work `backlog.md` in order and tick `- [ ]` → `- [x]` when an item is finished, with the result recorded there.
- **Ask when a new decision appears, do not pick silently.** All current decisions are in `backlog.md` ("Решения и открытые вопросы"): D1 14 nodes (1 control-plane + app×2, lb×2, pg×2, redis×3, consul×3, s3×1), D2 Patroni + Consul, D3 Redis Sentinel (an *assumption*, the prod mode is unknown), D4/D4a S3 = Garage (MinIO's images became private), D5 one lab cluster at a time, D6 two-stage success, D7 HAProxy as Harbor LB, D8 minimum scope, D9/D10 colors ignored and Nexus out of scope.
- **Don't invent versions.** Every new component gets an explicit pinned version (and image digest) recorded in `backlog.md`, `README.md` and the table below **before** it is installed. Verify Harbor chart keys with `helm show values harbor/harbor --version 1.19.2`, not from memory.
- Target architecture: Harbor app ×2 → Harbor LB ×2 (HAProxy, in front of PostgreSQL and Redis, **not** the Harbor ingress) → PostgreSQL ×2 under Patroni with state in Consul ×3, Redis ×3; blobs in S3 (Ceph in prod, Garage here); Infra LB (ingress-nginx + MetalLB) in front. Backups, Prometheus and Nexus are out of scope.
- **One lab cluster at a time (D5):** the defaults (`CLUSTER=harbor`, `LB_IP=172.20.0.100`, pool `172.20.0.100–110`) match `harbor-on-kind`; `make cluster-delete` the other repo's cluster before `make cluster` here. The host's `/etc/hosts` entry and Docker `insecure-registries` for `core.harbor.domain` are reused.
- The failure tests kill real nodes and pods. Say what you are about to break before doing it, run one test at a time on a healthy stand, wait for the host load to settle (`cut -d' ' -f1 /proc/loadavg` < 3), and clean up by digest.
- Before `make cluster-delete` of a working stand, run `make images-save` (cache complete) and `make images-check` (pinned images and charts still pullable; `MISSING` = the registry answered not found/unauthorized, `UNKNOWN` = timeout or network/CDN error on this host, not absence; rerun). MinIO's images vanished from quay.io between two builds. A new third-party image must be added to `hack/images.txt` with its node roles.
- Report faithfully: a failed or skipped check is reported as such, with its output.
- `sudo` is interactive-only in agent sessions: `make add-host` (missing entry) and the Docker `insecure-registries` change are run by the user; `make deploy-app` prints the exact commands.
- Never write to the user's `~/.aws` (no `aws configure set`); for S3 checks use an isolated `AWS_CONFIG_FILE` / `AWS_SHARED_CREDENTIALS_FILE` (runbook V8.2).
- `hack/config/harbor.yaml` (single-node values) is legacy: HA replaced the single-node baseline on purpose (H3.3) and no target uses it.

## Pinned versions

| Component | Pinned version |
|-----------|----------------|
| Kind CLI | `v0.30.0` |
| Node image | `kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a` |
| MetalLB chart | `0.16.1` |
| ingress-nginx chart | `4.15.1` (app `1.15.1`) |
| Harbor chart / app | `1.19.2` / `2.15.2` |
| PostgreSQL | `18.6-alpine3.24` (Harbor 2.15.2 bundles 18.3) |
| Patroni | `4.1.5` (PyPI, own image, extras `consul`, `psycopg3`) |
| Consul | `1.22.7` (not 2.0.x) |
| HAProxy | `3.4.4-alpine3.24` (LTS) |
| Valkey + Sentinel | `9.0.6-alpine3.24` (Harbor bundles 9.0.3) |
| Garage (S3) | `v2.4.1` (Docker Hub `dxflrs/garage`) |

Images are also pinned by digest in the manifests; full refs and rationale are in `backlog.md` → "Версии компонентов HA". Chart `1.19.2` HA keys in use: `database.type` / `redis.type: external` + `*.external.*`, `persistence.imageChartStorage.type: s3` (`disableredirect: true`), `replicas`, `nodeSelector`, `tolerations`, `topologySpreadConstraints`, `livenessProbe` under `core`/`portal`/`registry`/`jobservice`/`trivy`, `expose.tls.certSource: secret`, `caSecretName`.

## Commands

```bash
make help            # list targets
make cluster         # installs ./bin/kind if missing, creates the 14-node cluster "harbor" (hack/config/kind-cluster.yaml, context kind-harbor)
make infra-lb        # MetalLB + ingress-nginx x2 on the lb nodes (hack/install-infra.sh)
make ha-deps         # consul -> postgres -> redis -> harbor-lb -> s3, in this order; each can run alone
                     #   consul | pg-image | postgres | redis | harbor-lb | s3   (hack/ha/*.yaml, namespace harbor-deps, secrets generated on first run)
make add-host        # "$LB_IP $HARBOR_HOST" into /etc/hosts (sudo)
make harbor-ha       # hack/install-harbor-ha.sh: Secrets in `default` (once), then helm install with hack/config/harbor-ha.yaml + hack/helm-postrender.py; DRY_RUN=1 renders only
make install         # infra-lb + harbor-ha
make deploy-app      # project `python`, build/push demo image, CA trust on the control-plane node, pull secret, deploy (idempotent)
make verify          # ansible/verify.yml: checks V1..V12 with a PASS/FAIL table, non-zero exit on FAIL (TAGS=V5,V6, EXTRA='-e verify_rollout=true'); needs pip `kubernetes` + collection kubernetes.core
make images-save     # hack/image-cache.sh: pinned third-party images + charts (hack/images.txt) into ~/.cache/harbor-ha (IMAGE_CACHE=)
make images-load     # cached images into the nodes of the right role (run before `make cluster` for the Docker daemon, again after it for the nodes); images-check / images-status
make cluster-ctx     # kubectl use-context kind-harbor
make cluster-delete
```

Variables: `CLUSTER`, `KIND_IMAGE`, `KIND_VERSION`, `LB_IP`, `HARBOR_HOST`, `LOCALBIN`, `PG_IMAGE`. Tests: `hack/tests/h41…h47`, `h62-sync-mode.sh` (see `README.md`). Checks: `docs/verification-runbook.md` (V1–V12, P4.1–P4.7); run the relevant ones after any change to `hack/ha/` or `hack/config/` and keep the runbook in sync.

## Gotchas

**Build and host**

- The Makefile runs `go env GOBIN` at parse time: Go must be on `PATH` even for `make help`. `$(KIND)` is a file target: after bumping `KIND_VERSION` delete `./bin/kind`. Kind clusters are never upgraded in place.
- `hack/add_host.sh` skips the entry if the hostname is present (it will not fix a wrong IP). Use `systemctl reload docker`, not `restart`, while a cluster runs.
- The subnet of the Docker `kind` network varies per machine (`docker network inspect kind`; here `172.20.0.0/16`). Changing `LB_IP` means updating together: `Makefile`, `hack/config/lb-ipaddresspool.yaml`, `hack/config/nginx.yaml`, host `/etc/hosts`, the node's `/etc/hosts`, README examples.
- Everything shares one host disk: gigabytes of writes (image builds with `dd`, big pushes) stall etcd/apiserver, crash controller-manager/scheduler (leader election; lease 60/40/10 s is set in `kind-cluster.yaml`) and trigger Sentinel failovers (`down-after` 15000). Keep test data small.
- Image cache (`hack/image-cache.sh`): `docker save` drops the name of a digest-pinned image, so images are saved under `cache.local/...:cached` and re-tagged inside the node with `ctr -n k8s.io images tag` to the pinned name; do not replace this with a plain `kind load docker-image`.
- Cold-start image pulls fail transiently (`ErrImagePull`): pods self-heal. Third-party images can vanish (MinIO). The output of `make pg-image` is loaded with `kind load` into the `pg` nodes only and disappears with the cluster.
- MetalLB L2: if a `LoadBalancer` IP never resolves (ARP `(incomplete)`, speaker flapping `serviceAnnounced`/`serviceWithdrawn`), check `kubectl get endpoints <svc>` and pod status first.

**Harbor chart, TLS, rollouts**

- The chart resolves `existingSecret` with `lookup` at render time: the Secrets must exist before `helm install`; validate with `DRY_RUN=1 make harbor-ha`, not `helm template`.
- The token key must be PKCS#1 (`openssl genrsa -traditional`). The CA is created once (Secret `harbor-ha-ingress-tls`, `certSource: secret`): with `auto` every `helm upgrade` regenerates it and new pulls on the node fail with `x509: unknown authority`. `deploy-app` trusts it on the node (needed once).
- The chart has no `preStop`: `hack/helm-postrender.py` (PyYAML, used by `install-harbor-ha.sh`) adds `preStop: sleep 15` to core/registry/portal; without it rolling updates give 502s. Keep it when changing the install path.
- 2 replicas on a 2-node role: `topologySpreadConstraints` (maxSkew 1) with `matchLabelKeys: [pod-template-hash]`, not a required `podAntiAffinity` (it deadlocks rolling updates). `harbor-lb` rolls with `maxSurge: 0`; HAProxy needs a `config-version` annotation bump to roll after a config change.
- Every worker is tainted `harbor-ha/role=<role>:NoSchedule`: any new workload needs a `nodeSelector` and a toleration. The demo app runs on the control-plane node (the only place `deploy-app.sh` installs the CA).
- `kubernetes.core.k8s_exec` splits `command` with shlex and runs no shell: use `sh -c "... $VAR ..."` (a `\$VAR` stays literal). Ansible checks (`ansible/`): each role appends to `verify_results`; skip `Terminating` pods (`deletionTimestamp`), they still report `Running`.
- Kubernetes does not expand `$(HOSTNAME)` in `args`: use the downward API (`POD_NAME`).

**Redis, HAProxy, S3**

- A restarted `redis-0` must not become master before it has asked the peers (`start-valkey.sh`: fresh volume vs restart); Valkey runs with `min-replicas-to-write 1`; the HAProxy Redis check requires `role:master` and a connected replica (regex `role:master[^a-z]{1,4}connected_slaves:[1-9]`; in HAProxy regexes `.` does not match a newline). Harbor core/jobservice liveness is relaxed (5 s x 6): their probes hang while Redis is unreachable.
- The Garage image has no shell: `hack/ha/s3-init.sh` runs `/garage` with `kubectl exec`. Bucket `registry-blobs`, key `harbor` (Secret `s3-credentials`).

**Failure tests and Harbor test data**

- Delete Harbor test artifacts by **digest**, never by tag: deleting an artifact removes all its tags (a test tag on the digest of `python/hello:1.0` deleted the demo image once).
- The scripts always restore what they change (killed node started again, `tc` removed, CoreDNS Corefile restored). If one is interrupted: `docker start <node>`, check `kubectl get nodes`, `docker exec harbor-worker tc qdisc show dev eth0` (expect `noqueue`) and `kubectl -n kube-system get cm coredns` (the original Corefile has no `template` block; then `rollout restart deploy/coredns`).
- H4.6 needs a fresh proxy project name per run (deleting through the API leaves blobs in S3) and does its cold pull with `curl`: docker's content store hides blobs from Harbor. Cached content is addressed by digest, tag pulls need the upstream.

## Coupling of the entry path

```
host: /etc/hosts core.harbor.domain -> 172.20.0.100
  MetalLB L2 pool 172.20.0.100-110 (hack/config/lb-ipaddresspool.yaml)
  ingress-nginx x2 on the lb nodes, Service pinned to 172.20.0.100 (hack/config/nginx.yaml, metallb.universe.tf/loadBalancerIPs)
  Harbor (expose.type=ingress, className nginx, host core.harbor.domain, TLS from Secret harbor-ha-ingress-tls) - hack/config/harbor-ha.yaml
```

Registry trust outside `deploy-app`: host Docker `insecure-registries: ["core.harbor.domain"]`; for the node, fetch `ca.crt` (`curl -sk https://core.harbor.domain/api/v2.0/systeminfo/getcert`), `docker cp` it to `<cluster>-control-plane:/usr/local/share/ca-certificates/`, `update-ca-certificates`, add the hosts entry, `systemctl restart containerd`.

## Demo app

- `python-docker-hello-kube/hello.py` is stdlib-only `http.server` (no pip dependencies: the original Flask app broke on an unpinned Werkzeug). `GET /` → `Hello, Kube! (from <pod hostname>)` (shows which replica answered), `GET /healthz` → `ok`, port 5000. The Dockerfile pins `python:3-alpine@sha256:9e9fde4d…`.
- `deployment.yml` (2 replicas + LoadBalancer `hello-service`, label `app: hello`) and `helm-hello-kube/templates/deployment.yaml` have probes on `/healthz`; both carry the control-plane `nodeSelector`/toleration.
- `helm-hello-kube/`: Deployment/Service names and the `app: hello-kube` selector are hardcoded; `helm test` works only for a release named `hello-kube`. Chart `appVersion: "1.16.0"` differs from image tag `1.0`: harmless.
- Must stay identical across the Dockerfile usage, `deployment.yml` and `helm-hello-kube/values.yaml`: image `core.harbor.domain/python/hello:1.0`, pull secret `harbor` (`docker-registry`), port `5000`. Charts go via Helm OCI (`helm push … oci://core.harbor.domain/python/hello --ca-file ./ca.crt`), not ChartMuseum.

## Conventions

- Always pass `--version` to every `helm upgrade -i` (`hack/install-infra.sh`, `hack/install-harbor-ha.sh`, any new script). Prefer `make` targets over ad-hoc kind/helm commands.
- Don't commit `bin/`, `ca.crt`, `*.tgz` or real credentials (`admin` / `Harbor12345` is the lab-only default); generated passwords live only in Secrets. `.gitignore` covers the files.
- Keep `README.md` and `AGENTS.md` in sync with `Makefile` / `hack/` whenever pins, topology or the demo app change.
