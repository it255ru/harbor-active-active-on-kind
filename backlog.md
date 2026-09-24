# Backlog: Harbor active-active на KinD

**Статус: черновик, работа не начата** (создан 2026-09-24). База — `harbor-on-kind` @ `b65df71`: рабочая одно-нодовая лаборатория. Её миграционный backlog (Kind 0.17 → 0.30, K8s 1.26 → 1.34, Harbor 2.8 → 2.15.2; Phase 0–6, все закрыты) сохранён в git-истории этого репозитория и в https://github.com/it255ru/harbor-on-kind.

**Цель:** Harbor в active-active — несколько реплик core / portal / registry / jobservice (и, возможно, trivy) за ingress, с общими внешними PostgreSQL, Redis (Valkey) и S3-совместимым хранилищем. Потеря любой одной реплики не должна прерывать push/pull образов и OCI-чартов.

## Базовая линия (унаследована, проверена на harbor-on-kind)

| Компонент | Версия |
|-----------|--------|
| Kind CLI | `v0.30.0` |
| Node image | `kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a` |
| MetalLB chart | `0.16.1` |
| ingress-nginx chart | `4.15.1` (app `1.15.1`) |
| Harbor chart / app | `1.19.2` / `2.15.2` |

Ключи chart `1.19.2`, относящиеся к HA (сверено по `helm show values harbor/harbor --version 1.19.2`): `database.type: external` + `database.external.*`; `redis.type: external` + `redis.external.*` (встроенный Redis в 2.15.2 — Valkey, `goharbor/valkey-photon`); `persistence.imageChartStorage.type: s3` (для MinIO — `disableredirect: true`, для самоподписанного сертификата хранилища — `caBundleSecretName`); `replicas` у `core`, `portal`, `registry`, `jobservice`, `trivy` (по умолчанию везде `1`).

## Открытые решения (решает пользователь — не выбирать молча)

- **D1. Топология KinD:** multi-node (1 control-plane + N worker) или одна нода с несколькими репликами? Multi-node нужен, чтобы проверять потерю *ноды*; одна нода проверяет только потерю *пода*.
- **D2. PostgreSQL:** оператор (CloudNativePG / Zalando / Crunchy), Bitnami `postgresql-ha` или один внешний под (без HA самой БД). Выбор + pinned-версия.
- **D3. Redis/Valkey:** одиночный внешний экземпляр или Sentinel. Выбор + pinned-версия.
- **D4. Object storage:** MinIO в кластере (какой chart/режим) для `imageChartStorage.type: s3`.
- ~~**D5. Изоляция от `harbor-on-kind`**~~ — **решено 2026-09-24:** одновременно запускается только один кластер, поэтому `CLUSTER=harbor`, `LB_IP=172.20.0.100` и пул `172.20.0.100–110` остаются как в `harbor-on-kind`. Перед `make cluster` здесь — `make cluster-delete` в старом репо (записи в `/etc/hosts` и `insecure-registries` переиспользуются).
- **D6. Критерии успеха:** подтвердить список проверок из Phase 4.

## Последовательный план

Выполнять по фазам. Любой новый компонент (PostgreSQL, Redis, MinIO, операторы) — только с явно зафиксированной pinned-версией здесь и в `CLAUDE.md` до установки.

### Phase 0 — Решения и подготовка

- [ ] **H0.1** Закрыть D1–D4 и D6 (D5 уже решён), записать выбор и pinned-версии в этот файл и в `CLAUDE.md`.
- [x] **H0.2** `CLUSTER` / `LB_IP` / MetalLB-пул оставлены как в `harbor-on-kind` (D5). Если HA потребует больше LB-IP — расширить пул в той же подсети и обновить связанные файлы.
- [ ] **H0.3** Сверить, что именно нужно шарить между репликами Harbor: логи jobservice (`jobservice.jobLoggers`), хранилище registry, Trivy-кэш — проверить по `helm show values` и документации Harbor HA, не по памяти.

### Phase 1 — Кластер

- [ ] **H1.1** kind-конфиг с нужным числом нод (D1) → `make cluster`, все ноды `Ready`.
- [ ] **H1.2** MetalLB + ingress-nginx на multi-node; реплик ingress-nginx ≥ 2 (иначе он сам — единая точка отказа).
- [ ] **H1.3** LB IP достижим с хоста; проверить `docker network inspect kind` заново (subnet мог измениться).

### Phase 2 — Общие зависимости

- [ ] **H2.1** PostgreSQL (D2) + база и пользователь для Harbor.
- [ ] **H2.2** Redis/Valkey (D3).
- [ ] **H2.3** MinIO + bucket (D4).
- [ ] **H2.4** Доступность всех трёх из namespace Harbor.

### Phase 3 — Harbor в HA

- [ ] **H3.1** `hack/config/harbor-ha.yaml`: внешние БД/Redis, `imageChartStorage: s3`, `replicas ≥ 2` для core / portal / registry / jobservice.
- [ ] **H3.2** Trivy: реплицировать ли (StatefulSet со своим хранилищем) — решить и записать.
- [ ] **H3.3** Установка с pinned-версиями (отдельный `make`-таргет или параметр `install`); все поды `Ready`.
- [ ] **H3.4** Доверие CA (нода/хост) к новому Harbor; `make deploy-app` проходит.

### Phase 4 — Проверка отказоустойчивости

- [ ] **H4.1** push/pull образа и OCI-чарта при всех репликах.
- [ ] **H4.2** Удалить один под registry/core *во время* push — push завершается (или корректно повторяется) без потери данных.
- [ ] **H4.3** Rolling update core/registry во время непрерывных pull (цикл `docker pull` / `curl /v2/`) — без ошибок у клиента.
- [ ] **H4.4** Потеря worker-ноды (если D1 = multi-node): сервис продолжает отвечать.
- [ ] **H4.5** demo-app: rollout после push нового тега, поды подтягивают образ; по `Hello, Kube! (from <pod>)` видно распределение по репликам.

### Phase 5 — Документация

- [ ] **H5.1** `README.md`: HA-раздел, актуальные примеры вывода.
- [ ] **H5.2** `AGENTS.md` / `CLAUDE.md` под фактическое состояние.
- [ ] **H5.3** Acceptance с нуля: `cluster-delete` → `cluster` → зависимости → `install` (HA) → `deploy-app` → проверки Phase 4.

## Риски и заметки

- Один хост Docker: «HA» здесь учебная — общий диск, общее ядро, реальной изоляции отказов нет.
- Самоподписанный CA Harbor пересоздаётся при каждой установке → доверие на ноде надо обновлять после каждого `install` (`make deploy-app` это уже делает).
- Ресурсы: PostgreSQL + Redis + MinIO + N реплик Harbor на локальной машине — оценить RAM до старта.
- Уроки базовой линии, которые легко повторить: непинованные зависимости ломают сборку со временем (случай Flask/Werkzeug); MetalLB L2 не держит анонс сервиса без Ready-эндпоинтов — при «зависшем» LB IP сначала смотреть `kubectl get endpoints`.
