# Agent context: harbor-active-active-on-kind

Harbor in active-active (HA) mode on KinD: two replicas each of core, portal, registry and jobservice behind ingress, sharing external PostgreSQL (Patroni + Consul), Redis (Valkey + Sentinel) and S3 (Garage) on a 14-node cluster. The stand is built and verified (milestone 1 accepted 2026-09-24; failure tests H4.1–H4.7 and a from-scratch rebuild H5.3 passed). It started as a copy of `harbor-on-kind` @ `b65df71`. The runbook is also an Ansible playbook (`make verify`, H5.4). Open work: H5.5 (image cache for rebuilds, needs the user's decision).

Where to start: `backlog.md` (Russian, plan, decisions D1–D10/D4a, pins and results, source of truth), `CLAUDE.md` (rules, pinned versions, commands, gotchas: read it before changing anything), `README.md` (human runbook, sample output, failure behaviour), `docs/stand-topology.md` (nodes, roles, addresses, data, secrets; Russian), `docs/verification-runbook.md` (checks V1–V12 and failure-test procedures P4.1–P4.7; Russian).

## Layout

| Path | Role |
|------|------|
| `Makefile` | Cluster lifecycle and install entry points (`make help`) |
| `hack/config/kind-cluster.yaml` | 14-node topology; role label/taint `harbor-ha/role`, leader-election tuning |
| `hack/install-infra.sh`, `hack/config/{metallb,nginx,lb-ipaddresspool}.yaml` | Infra LB: MetalLB + ingress-nginx x2 on the `lb` nodes (`make infra-lb`) |
| `hack/ha/` | Dependencies in namespace `harbor-deps`: `consul.yaml`, `postgres.yaml` + `patroni/` (image build), `redis.yaml`, `haproxy.yaml`, `s3.yaml` + `s3-init.sh` (`make ha-deps`) |
| `hack/install-harbor-ha.sh`, `hack/config/harbor-ha.yaml`, `hack/helm-postrender.py` | Harbor in HA: Secrets, pinned Helm chart, `preStop` post-renderer (`make harbor-ha`) |
| `hack/install.sh` | `infra-lb`, then `harbor-ha` (`make install`) |
| `hack/deploy-app.sh` | Build/push the demo image, trust Harbor's CA on the node, deploy the app (`make deploy-app`) |
| `hack/tests/` | Failure-test scripts and analyzers: `h41-push-pull.sh`, `h42-kill-during-push.sh`, `h43-rolling-update.sh`, `h44-node-loss.sh`, `h45-app-rollout.sh`, `h46-proxy-cache.sh`, `h47-role-failure.sh` (+ `h4x_analyze.py`) |
| `ansible/` | `verify.yml` + roles `verify_*` (V1..V12), `group_vars/all.yml` (numbers, addresses), `files/s3-access.sh`; run with `make verify` |
| `hack/add_host.sh` | Add the Harbor hostname to `/etc/hosts` |
| `hack/phase0-prepare.sh` | Phase 0 host tool checks, writes `hack/phase0-baseline.log` |
| `hack/config/harbor.yaml` | Legacy single-node Harbor values, no target uses it |
| `python-docker-hello-kube/`, `helm-hello-kube/` | Demo app (stdlib `http.server`), Dockerfile, raw manifest and Helm chart |
| `bin/` | Local tools (kind), gitignored |

## Defaults

- Cluster `harbor` → context `kind-harbor`; LB IP `172.20.0.100` → `core.harbor.domain`; MetalLB pool `172.20.0.100–110`; the demo app service gets `172.20.0.101`. The subnet must match the Docker `kind` network (`docker network inspect kind`, here `172.20.0.0/16`).
- Harbor admin `admin` / `Harbor12345` (lab default); generated passwords live only in Secrets (`harbor-deps`: `pg-credentials`, `redis-credentials`, `s3-credentials`; `default`: `harbor-ha-*`).
- Demo project / image `core.harbor.domain/python/hello:1.0`, pull secret `harbor`, port 5000; `GET /` → `Hello, Kube! (from <pod>)`, `GET /healthz` → `ok`. The demo app runs on the control-plane node.

## Typical flow

1. `make cluster` → `make infra-lb` → `make ha-deps` → `make add-host` → `make harbor-ha`.
2. Once, by the user (interactive `sudo`): host Docker must trust `core.harbor.domain` (`insecure-registries`); `make deploy-app` checks and prints the exact command if missing.
3. `make deploy-app`, then `make verify` (or the runbook checks by hand) and the failure tests in `hack/tests/`.
4. Cleanup: `make cluster-delete`.

## Conventions

- Follow the phase order in `backlog.md`; record results there; ask before making a new design decision.
- Prefer `make` targets over ad-hoc kind/helm commands; always pin `--version` on Helm installs; pin versions before installing anything new.
- Do not commit secrets, `ca.crt`, `*.tgz` or `bin/`. Never touch the user's `~/.aws`.
- `CLUSTER` / `LB_IP` match `harbor-on-kind` on purpose (one lab cluster at a time, D5): `make cluster-delete` the other repo's cluster first.
- Keep `README.md`, `CLAUDE.md` and this file in sync with `Makefile` / `hack/` when pins, topology or the demo app change.
