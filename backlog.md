# Backlog: переход на Kubernetes ≥ 1.30

Цель: обновить playground со стека Kind `v0.17` / K8s `1.26` / Harbor `2.8` на совместимый с современным Harbor стек **K8s 1.34** (минимум ≥ 1.30).

## Целевой стек (pin)

| Компонент | Было | Станет |
|-----------|------|--------|
| Kind CLI | `v0.17.0` | `v0.30.0` |
| KinD node / Kubernetes | `kindest/node:v1.26.0` | `kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a` |
| MetalLB chart | floating / README `0.13.10` | `metallb/metallb` **`0.16.1`** |
| ingress-nginx chart | floating / README `4.7.1` | `ingress-nginx/ingress-nginx` **`4.15.1`** (app `1.15.1`) |
| Harbor chart | floating / README `1.12.4` | `harbor/harbor` **`1.19.2`** |
| Harbor app | README `2.8.4` | **`2.15.2`** |
| Demo Flask / hello-kube | без изменений | без изменений (не блокер) |

Образ ноды и digest брать из [release notes Kind v0.30.0](https://github.com/kubernetes-sigs/kind/releases/tag/v0.30.0). При смене Kind CLI — сверять digest заново.

---

## Последовательный план

Выполнять **по фазам**. Не ставить Harbor на старый Kind `0.17` с образом `1.34` — сначала tooling + cluster.

### Phase 0 — Подготовка (без изменения кластера)

- [x] **B0.1** Зафиксировать baseline: `docker network inspect kind`, текущий `LB_IP`, версии `kubectl`/`helm`/`go` на хосте.
- [x] **B0.2** Убедиться: Helm ≥ 3.8, Docker работает, Go установлен (нужен для `go install kind`). *(см. блокеры ниже)*
- [x] **B0.3** Если есть живой кластер — задокументировать состояние или `make cluster-delete` перед bump (in-place upgrade Kind-кластера не делаем).
- [x] **B0.4** Создать ветку `chore/k8s-1.34-stack` (или аналог).

#### Phase 0 baseline log (2026-09-07)

| Проверка | Результат |
|----------|-----------|
| Docker | OK `29.8.0`, cgroup v2 |
| Helm | OK `v3.16.1` (≥ 3.8) |
| Go | OK `go1.25.6 linux/amd64` |
| kubectl | **MISSING** — нужен до Phase 1 (`make cluster` / проверка API) |
| `./bin/kind` | отсутствует (установится при `make cluster`) |
| Docker network `kind` | **нет** (кластера KinD нет) |
| Живой кластер Harbor/KinD | **нет** — `cluster-delete` не требуется |
| Makefile `LB_IP` | `172.17.0.100` (подтвердить subnet после `make cluster`: часто бывает `172.18.0.0/16`) |
| `/etc/hosts` | нет `core.harbor.domain`; есть чужая запись `harbor-fmba.cip.lab` |
| Git | **нет репозитория** — ветку создать нельзя без `git init` |

**Блокеры перед Phase 1:** ~~установить `kubectl`; решить по git (`git init` + ветка или внешний remote)~~ — устранены 2026-09-24: `kubectl v1.34.12` установлен в `~/.local/bin`, репозиторий инициализирован, ветка `chore/k8s-1.34-stack` создана и активна. Актуальный снимок — в `hack/phase0-baseline.log` (перегенерируется `./hack/phase0-prepare.sh`).

**Повторный прогон Phase 0:**
```bash
./hack/phase0-prepare.sh                 # проверка + hack/phase0-baseline.log
./hack/phase0-prepare.sh --create-branch # B0.4 (нужен .git)
./hack/phase0-prepare.sh --init-git --create-branch  # git init + ветка
```


### Phase 1 — Kind + Kubernetes

- [x] **B1.1** В `Makefile`: `KIND_VERSION ?= v0.30.0`.
- [x] **B1.2** В `Makefile`: `KIND_IMAGE ?= kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a`.
- [x] **B1.3** Удалить старый `./bin/kind` (иначе Make может не переустановить из‑за существующего файла). *(бинаря не было — n/a)*
- [x] **B1.4** `make cluster` → проверить `kubectl version` (server ≥ 1.30, ожидаем 1.34). *(`v1.34.0`, нода `Ready`)*
- [x] **B1.5** Subnet Docker `kind` оказался `172.20.0.0/16` (не `172.17.0.0/16`) — синхронно обновлены `Makefile` `LB_IP=172.20.0.100`, `hack/config/lb-ipaddresspool.yaml` (`172.20.0.100-172.20.0.110`), `hack/config/nginx.yaml`. `make add-host` выполнен (вручную, с `sudo`) — `/etc/hosts` содержит `172.20.0.100 core.harbor.domain`.

**Критерий готовности Phase 1:** context `kind-harbor`, API server `v1.34.x`, нода Ready. **Достигнуто 2026-09-24.**

### Phase 2 — Pin Helm-чартов в install

- [x] **B2.1** В `hack/install.sh` pin MetalLB:  
  `helm upgrade -i metallb metallb/metallb --version 0.16.1`
- [x] **B2.2** Дождаться MetalLB Ready, применить `lb-ipaddresspool.yaml` (CRD `IPAddressPool`/`L2Advertisement` — без смены API, если chart всё ещё `metallb.io/v1beta1`).
- [x] **B2.3** Pin ingress-nginx:  
  `helm upgrade -i ingress-nginx ingress-nginx/ingress-nginx --version 4.15.1 -f …/nginx.yaml`
- [x] **B2.4** Проверить EXTERNAL-IP контроллера = `LB_IP` (после Phase 1 это `172.20.0.100`, не дефолтный `172.17.0.100` — см. B1.5).
- [x] **B2.5** Pin Harbor:  
  `helm upgrade -i harbor harbor/harbor --version 1.19.2 -f …/harbor.yaml`
- [x] **B2.6** Дождаться Ready подов Harbor (`core`, `portal`, `registry`, `database`, `redis`, `jobservice`, `trivy`).

**Критерий готовности Phase 2:** `helm list` показывает metallb `0.16.1`, ingress-nginx `4.15.1`, harbor `1.19.2` / app `2.15.2`; UI `https://core.harbor.domain` открывается. **Достигнуто 2026-09-24** (`curl -k https://core.harbor.domain` → `200`).

### Phase 3 — Совместимость Harbor values / ingress

- [x] **B3.1** Сверить `hack/config/harbor.yaml` с values chart `1.19.2` (`helm show values harbor/harbor --version 1.19.2`): пароль, `expose.ingress`, hosts. *(diff показал: `notary`/`harbor` под `expose.ingress` — мёртвые ключи, `className` — актуальная замена аннотации)*
- [x] **B3.2** Убрать/заменить deprecated `kubernetes.io/ingress.class: nginx` на актуальный способ — заменено на `expose.ingress.className: nginx`; дублирующиеся дефолтные `*.ingress.kubernetes.io/ssl-redirect`/`proxy-body-size` убраны из оверрайда (наследуются из values chart). `kubectl get ingress` → `CLASS nginx`, доступ к UI не ломался.
- [x] **B3.3** Notary полностью отсутствует в chart `1.19.2` (нет ни шаблонов, ни ключей в values) — блоки `notary:`/`harbor:` в `harbor.yaml` были мёртвым legacy из chart 1.12 и удалены.
- [x] **B3.4** Smoke через Harbor API (эквивалент ручного логина в UI, браузера в окружении нет): `GET /api/v2.0/users/current` → `200`, `POST /api/v2.0/projects {name: python}` → `201`, подтверждено в списке проектов.

**Критерий готовности Phase 3:** UI + project `python` без ошибок; ingress HTTPS работает. **Достигнуто 2026-09-24.**

### Phase 4 — Docker / KinD trust к registry

- [x] **B4.1** Host Docker: `core.harbor.domain` добавлен в `insecure-registries` (`/etc/docker/daemon.json`, слит через `jq` с существующими mirrors/registries), применено через `systemctl reload docker` (не `restart` — кластер `kind-harbor` не пострадал).
- [x] **B4.2** CA Harbor (`GET /api/v2.0/systeminfo/getcert`) установлен в `harbor-control-plane` (`update-ca-certificates`), запись `172.20.0.100 core.harbor.domain` в `/etc/hosts` ноды, `systemctl restart containerd` — нода и поды пережили рестарт без даунтайма.
- [x] **B4.3** `docker login` (admin/Harbor12345) → `docker build` → `docker push core.harbor.domain/python/hello:1.0` — успешно, репозиторий `python/hello` появился в Harbor.
- [x] **B4.4** Trivy-scan включён (`auto_scan` на проекте `python`) и запущен вручную (`POST .../artifacts/1.0/scan` → `202`) — `scan_status: Success`, найдено 3 High/1 Medium/1 Low CVE (регрессия ожидаема, апдейт Flask/Alpine вне скоупа).

**Критерий готовности Phase 4:** образ в проекте `python`, pull с хоста ок. **Достигнуто 2026-09-24** (`docker pull` после `docker rmi` — образ скачан по digest).

### Phase 5 — Deploy demo-приложения

- [x] **B5.1** Создать secret `harbor` (`docker-registry`).
- [x] **B5.2** `kubectl apply -f python-docker-hello-kube/deployment.yml` → pod Running, Service LB, `curl` → `Hello, Kube!`.
- [x] **B5.3** То же через `helm-hello-kube` (install/delete). `helm test` → `Succeeded`.
- [x] **B5.4** `helm package` + OCI push/pull в Harbor — push, pull, install из `.tgz` подтверждены.

**Критерий готовности Phase 5:** оба пути деплоя работают на K8s 1.34. **Достигнуто 2026-09-24**, но не без находки — см. блок ниже.

**Внеплановая находка при B5.2:** поды `hello-deployment` падали в `CrashLoopBackOff` — `ImportError: cannot import name 'url_quote' from 'werkzeug.urls'`. Причина: `requirements.txt` пиновал только `Flask==2.2.2`, без `Werkzeug`; свежий `pip install` в 2026 подтянул несовместимый `Werkzeug 3.x` (в 2023, когда собирали образ впервые, резолвился ещё совместимый `2.2.x`). Проблема не в K8s 1.34 — контейнер не запустился бы ни на каком кластере. По согласованию с пользователем (разрешение выйти за рамки «demo-приложение вне скоупа») приложение переписано на stdlib `http.server` (без pip-зависимостей вообще — исключает весь класс таких багов навсегда):
- `python-docker-hello-kube/hello.py`, `helm-hello-kube` — `/` возвращает `Hello, Kube! (from <hostname пода>)`, добавлен `/healthz`.
- `requirements.txt` удалён (не нужен); `Dockerfile` запинен на `python:3-alpine@sha256:9e9fde4d32eedce0b661d9ab91e826b62dddf28e928c230ec55f1866cac66b01`.
- В `deployment.yml` и `helm-hello-kube/templates/deployment.yaml` добавлены `readinessProbe`/`livenessProbe` на `/healthz`.
- Это частично закрывает пункты из «Задела на будущее» (identity-endpoint и health-пробы) — см. ниже, статус обновлён.

### Phase 6 — Документация и агентский контекст

- [x] **B6.1** Обновить `README.md`: версии Kind/K8s/чартов, устаревшие выводы `helm list`, при необходимости скриншоты/шаги CA. Добавлена таблица «Pinned versions», убраны упоминания Notary (удалён из chart 1.19.2), обновлены все примеры вывода (`kubectl get po/svc`, `docker ps`, OCI push/pull, `helm list`) под текущий стек и реальные digest'ы. Скриншоты (`pictures/*.png`) не перегенерированы — в окружении нет браузера, это визуально из старой версии UI, но шаги актуальны.
- [x] **B6.2** Обновить `AGENTS.md` под новые дефолты (Flask → stdlib `http.server`, LB IP пример, порт/healthz). `.cursor/rules/*.mdc` больше не существует (удалено раньше по отдельному запросу) — ссылки на него убраны из `AGENTS.md` и `CLAUDE.md`.
- [x] **B6.3** `hack/install.sh` пинует все три чарта с Phase 2; в README добавлена явная таблица pinned versions с инструкцией синхронизировать при бампе.
- [x] **B6.4** Финальный acceptance с нуля: `make cluster-delete` → `make cluster` (та же subnet `172.20.0.0/16`) → `make add-host` (уже была запись, sudo не потребовался) → `make install` (`helm list` = metallb `0.16.1`, ingress-nginx `4.15.1`/`1.15.1`, harbor `1.19.2`/`2.15.2`, UI `200`, `CLASS nginx`) → пересоздан project `python`, CA/hosts/containerd на новой ноде переустановлены → `docker push` → raw YAML deploy (Ready сразу, без CrashLoop) → Helm deploy (`helm test` → `Succeeded`) → cleanup. Также проверены `make help` и `make cluster-ctx`.

**Критерий готовности Phase 6:** docs = код; чистый прогон с нуля успешен. **Достигнуто 2026-09-24.**

---

## Порядок коммитов (предложение)

1. `chore: bump kind to v0.30 and node to v1.34`
2. `chore: pin metallb, ingress-nginx, and harbor helm chart versions`
3. `fix: align harbor ingress values with chart 1.19`
4. `docs: update README and agent context for K8s 1.34 stack`

---

## Риски и заметки

| Риск | Митигация |
|------|-----------|
| Subnet Docker `kind` ≠ `172.17.0.0/16` | Сразу править `LB_IP` + MetalLB + nginx annotation |
| Старый `./bin/kind` не обновился | Удалить бинарь перед `make cluster` |
| Breaking values Harbor 1.12 → 1.19 | Сверять `helm show values`, минимальный `harbor.yaml` |
| ingress-nginx 4.15 vs annotation MetalLB | Проверить, что `metallb.universe.tf/loadBalancerIPs` ещё валидна для выбранного MetalLB |
| Floating charts без pin | После Phase 2 всегда `--version` |
| Kind image без digest | Pin `@sha256:…` из release notes используемого Kind |

## Вне скоупа (не блокер K8s ≥ 1.30)

- Обновление Flask `2.2.2` / base image Alpine
- Исправление `appVersion: "1.16.0"` в `helm-hello-kube/Chart.yaml`
- HA Harbor, внешние DB/Redis, production TLS
- Миграция с ChartMuseum (если где-то остался) — OCI уже предпочтителен

## Definition of Done

- [x] Кластер KinD на **Kubernetes 1.34.x**
- [x] Harbor **2.15.2** через chart **1.19.2**
- [x] MetalLB и ingress-nginx с pinned versions из таблицы
- [x] Push образа + deploy YAML и Helm работают
- [x] README / AGENTS отражают новый стек (`.cursor/rules` удалён, см. B6.2)
- [x] Повторный `make cluster` → `install` → smoke проходит на чистом окружении

**Весь план (Phase 0–6) закрыт 2026-09-24.**

## Задел на будущее (не начинать, пока не закрыт этот план)

После Phase 0–6 планируется отдельная инициатива — **Harbor active-active** (несколько core/registry реплик за общим Postgres/Redis/S3, HA не самого приложения, а Harbor). Зафиксировано 2026-09-24 для памяти, реализация не начата:

- ~~Демо-приложение ничего не говорит о том, какая реплика ответила и жива ли она~~ — **сделано попутно в Phase 5** (см. «Внеплановая находка при B5.2» выше): endpoint отдаёт hostname пода, добавлены `/healthz` + readiness/liveness probe в `deployment.yml` и `helm-hello-kube`. Приложение переписано на stdlib `http.server` (без pip-зависимостей).
- Само приложение — не главный объект тестирования Harbor HA; основная проверка — конкурентные push/pull через Harbor API/registry при недоступности одной из реплик.
- Явно вне скоупа текущего плана (см. «Вне скоупа» выше: `HA Harbor` уже туда включено) — эти пункты не трогать, пока не закрыт Definition of Done текущего backlog.
