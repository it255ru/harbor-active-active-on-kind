# CLAUDE.md

Repo: **harbor-on-kind**. Local lab: **Harbor** on a single-node **KinD** cluster (MetalLB + ingress-nginx in front), plus a tiny stdlib-only Python app that is built, pushed to Harbor, and deployed via raw YAML or a Helm chart. No application code to speak of, no tests, no CI — the "code" is a Makefile, a few shell scripts, and Helm/K8s YAML.

See also: `AGENTS.md` (agent orientation), `README.md` (human runbook — now current, updated in Phase 6).

## Migration complete (2026-09-24) — `backlog.md` has the full history

`backlog.md` (written in Russian) is the source of truth for *how* this got here. All phases (0→6) are done; the playground moved from Kind `v0.17` / K8s `1.26` / Harbor `2.8` to the pins below, now live:

| Component | Pinned version (current) |
|-----------|-----------|
| Kind CLI | `v0.30.0` |
| Node image | `kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a` |
| MetalLB chart | `0.16.1` |
| ingress-nginx chart | `4.15.1` (app `1.15.1`) |
| Harbor chart / app | `1.19.2` / `2.15.2` |

Rules (still apply for any future re-bump — don't assume "done" means "static"):
- Don't invent other versions without updating `backlog.md`/this table/`README.md` together. If the Kind CLI changes, re-check the node digest in Kind release notes.
- Never install Harbor on a new node image using an old Kind CLI — bump tooling + cluster first, Harbor last.
- The demo app's Chart `appVersion: "1.16.0"` mismatch (vs. image tag `1.0`) is still **out of scope**. (The app's Flask code *was* rewritten on 2026-09-24, user-authorized, because it was actually broken — see Phase 5 note in `backlog.md`, not a scope change to this migration.)
- A future **Harbor active-active** initiative is noted in `backlog.md` ("Задел на будущее") but explicitly not started — don't begin it without the user re-opening that work.

**Verified state (as of 2026-09-24, clean acceptance run):** `kubectl v1.34.12` installed (`~/.local/bin`); repo is a git repo on branch `chore/k8s-1.34-stack` (no commits yet — nothing has been committed this session). Full `make cluster-delete` → `make cluster` → `make add-host` → `make install` → project `python` → CA/node trust → `docker push` → raw-YAML deploy → Helm deploy round-trip was re-run from scratch and passed: `helm list` = `metallb-0.16.1`, `ingress-nginx-4.15.1`/app `1.15.1`, `harbor-1.19.2`/app `2.15.2`; UI `200`; ingress `CLASS nginx`; `hello-deployment` pods Ready immediately (no CrashLoop); `helm test hello-kube` → `Succeeded`; OCI chart push/pull/install round-tripped. `make help` and `make cluster-ctx` also confirmed working.

## Commands

```bash
make help            # list targets
make cluster         # installs ./bin/kind via `go install` if missing, creates cluster "harbor" (context kind-harbor)
make add-host        # appends "$LB_IP $HARBOR_HOST" to /etc/hosts (uses sudo)
make install         # hack/install.sh: helm repos → MetalLB → IPAddressPool → ingress-nginx → Harbor
make deploy-app      # hack/deploy-app.sh: project `python` → docker login/build/push → node CA trust → pull secret → kubectl apply + rollout restart (run after `install`; idempotent, safe to re-run after editing hello.py)
make cluster-ctx     # kubectl use-context kind-harbor
make cluster-delete

./hack/phase0-prepare.sh [--create-branch] [--init-git]   # Phase 0 checks; rewrites hack/phase0-baseline.log; exit 1 = blockers
```

Overridable Make vars: `CLUSTER`, `KIND_IMAGE`, `KIND_VERSION`, `LB_IP`, `HARBOR_HOST`, `LOCALBIN`.

Gotchas:
- The Makefile runs `go env GOBIN` at parse time — Go must be on `PATH` even for `make help`.
- `$(KIND)` is a file target: after bumping `KIND_VERSION`, **delete `./bin/kind`** or Make won't reinstall.
- `make install` uses the current kube-context; run `make cluster-ctx` if unsure.
- `hack/add_host.sh` greps for the hostname as a substring and skips if found — it won't fix a wrong IP.
- Kind clusters are never upgraded in place: `make cluster-delete` then `make cluster`.
- `make deploy-app` fails fast with copy-pasteable instructions if the host Docker isn't yet in `insecure-registries` for `HARBOR_HOST` — that one step needs interactive `sudo` and can't be automated in a non-interactive session.
- `make deploy-app` always redoes the KinD node's CA trust + `systemctl restart containerd` (needed fresh after every `cluster-delete`/`cluster`, since Harbor's self-signed CA regenerates). Pods survive the restart, but ones already `Terminating` from a just-prior `kubectl delete` may take noticeably longer to actually disappear — that's transient, not a hang.

## Architecture / coupling

```
host ── /etc/hosts: core.harbor.domain → 172.20.0.100
          │
   MetalLB L2 pool 172.20.0.100–110 (hack/config/lb-ipaddresspool.yaml, metallb.io/v1beta1)
          │
   ingress-nginx Service pinned to 172.20.0.100 (hack/config/nginx.yaml annotation metallb.universe.tf/loadBalancerIPs)
          │
   Harbor (expose.type=ingress, host core.harbor.domain, self-signed TLS) — hack/config/harbor.yaml
```

**Changing the LB IP** (needed when `docker network inspect kind` isn't the subnet already baked into the config — this lab's Docker `kind` network turned out to be `172.20.0.0/16`, not the `172.17.0.0/16` originally assumed) requires updating together: `Makefile` `LB_IP`, `hack/config/lb-ipaddresspool.yaml`, `hack/config/nginx.yaml`, the host `/etc/hosts`, the node's `/etc/hosts`, and IPs in README examples. Re-running `make cluster-delete` → `make cluster` on the same Docker daemon reliably gave the same subnet here, but that's not guaranteed elsewhere — always re-check with `docker network inspect kind` after a fresh `make cluster`.

**MetalLB L2 gotcha:** if a newly created `LoadBalancer` Service's IP never resolves (ARP shows `(incomplete)`, speaker logs show `serviceAnnounced`/`serviceWithdrawn` flapping with `reason: notOwner`), don't assume it's a MetalLB/speaker bug first — check `kubectl get endpoints <svc>` and pod status. In this repo, the flapping was a symptom of the backend pods being in `CrashLoopBackOff` (no Ready endpoints); MetalLB won't hold a stable L2 announcement for a Service with nothing healthy behind it. Restarting the speaker pod (`kubectl delete pod -l app.kubernetes.io/component=speaker`) did *not* fix it — fixing the app so its pods became Ready did.

`hack/config/harbor.yaml` uses `expose.ingress.className: nginx` (Phase 3: replaced the deprecated `kubernetes.io/ingress.class` annotation and dropped the dead `notary`/`harbor` sub-blocks — Notary has no templates or values keys left in chart 1.19.2). Diffed against `helm show values harbor/harbor --version 1.19.2`.

Registry trust is manual (README / backlog Phase 4): host Docker `insecure-registries: ["core.harbor.domain"]`; for the KinD node, download Harbor's `ca.crt`, `docker cp` it into `harbor-control-plane:/usr/local/share/ca-certificates/`, `update-ca-certificates`, add the hosts entry inside the node, `systemctl restart containerd`.

## Demo app

- `python-docker-hello-kube/hello.py` — **stdlib-only** (`http.server`, no pip deps at all — rewritten 2026-09-24, see below). `GET /` → `Hello, Kube! (from <pod hostname>)`, `GET /healthz` → `ok`. Port 5000.
- `python-docker-hello-kube/Dockerfile` — `python:3-alpine@sha256:9e9fde4d32eedce0b661d9ab91e826b62dddf28e928c230ec55f1866cac66b01` (pinned by digest), just `COPY hello.py .` — no `requirements.txt`, no `pip install` (removed, nothing to install).
- `deployment.yml` (2-replica Deployment + LoadBalancer Service `hello-service`, labels `app: hello`) and `helm-hello-kube/templates/deployment.yaml` both have `readinessProbe`/`livenessProbe` on `GET /healthz`.
- `helm-hello-kube/` — chart `hello-kube`; Deployment/Service names and `app: hello-kube` selector are **hardcoded**, not templated. `templates/tests/test-connection.yaml` targets `<fullname>`, so `helm test` only works when the release is named `hello-kube` (as in README).
- Values that must stay identical across Dockerfile tag usage, `deployment.yml`, and `helm-hello-kube/values.yaml`: image `core.harbor.domain/python/hello:1.0`, pull secret `harbor`, port `5000`.
- Before pushing the image: create Harbor project `python` and `docker login core.harbor.domain` (admin / Harbor12345); the K8s pull secret must be type `docker-registry` (`kubernetes.io/dockerconfigjson`).
- Chart distribution: Helm OCI (`helm push … oci://core.harbor.domain/python/hello`, with `--ca-file ./ca.crt`), not ChartMuseum.

**Why the rewrite:** the original `Flask==2.2.2` app was found `CrashLoopBackOff` in Phase 5 — `requirements.txt` pinned Flask but not `Werkzeug`, and a fresh `pip install` in 2026 resolved an incompatible `Werkzeug 3.x` (`ImportError: cannot import name 'url_quote'`). This wasn't a K8s-1.34 issue; the image was broken on any cluster. User authorized going past the normal "demo app is out of scope" rule to fix it, and the fix was to drop pip entirely (stdlib `http.server`) rather than just re-pin `Werkzeug`, removing this whole class of future dependency-drift breakage. The Chart `appVersion: "1.16.0"` mismatch is untouched and still out of scope.

## Conventions

- Always pass `--version` to every `helm upgrade -i` in `hack/install.sh`.
- Prefer `make` targets over ad-hoc kind/helm commands.
- Don't commit `bin/`, `ca.crt`, or credentials (`admin` / `Harbor12345` is the lab-only default already in `harbor.yaml`). `.gitignore` covers `/bin` and `hack/phase0-baseline.log`.
- Keep `README.md` and `AGENTS.md` in sync with `Makefile`/`hack/` whenever pins or the demo app change — Phase 6 caught up a large drift once; don't let it re-accumulate.
