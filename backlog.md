# Backlog: Harbor active-active на KinD

**Статус: черновик, работа не начата** (создан 2026-09-24). База — `harbor-on-kind` @ `b65df71`: рабочая одно-нодовая лаборатория. Её миграционный backlog (Kind 0.17 → 0.30, K8s 1.26 → 1.34, Harbor 2.8 → 2.15.2; Phase 0–6, все закрыты) сохранён в git-истории этого репозитория и в https://github.com/it255ru/harbor-on-kind.

**Цель:** Harbor в active-active — несколько реплик core / portal / registry / jobservice (и, возможно, trivy) за ingress, с общими внешними PostgreSQL, Redis (Valkey) и S3-совместимым хранилищем. Потеря любой одной реплики не должна прерывать push/pull образов и OCI-чартов.

## Целевая архитектура (требование пользователя)

Источники (2026-09-24): таблица узлов «Harbor (compute)» и архитектурная диаграмма «Harbor / Nexus / Consul / Ceph». Назначение: Docker- и Helm-репозитории для ВМ клиентов в PVE-кластере compute; Harbor **проксирует внешние репозитории** (выход в Интернет — стрелка от «Harbor app») и **хранит локальные** (proxy-cache проекты + обычные проекты).

Что на диаграмме куда ходит:

| Поток | Откуда → куда | Заметка |
|-------|---------------|---------|
| Вход | администраторы и клиенты → **Infra LB** → Harbor (и Nexus) | Infra LB общий для Harbor и Nexus и стоит вне блока Harbor |
| Данные приложения | Harbor app → **Harbor LB** → Postgres Cluster / Redis Cluster | Harbor LB — балансировщик *перед PG и Redis*, а не вход в Harbor |
| Блобы registry | Harbor app → Ceph S3 («Данные») | Ceph internal (№14), S3 API |
| Бэкапы | Postgres Cluster и Redis Cluster → Ceph S3 («Бэкапы») | плюс «Выгрузка бэкапов во внутренний контур» |
| Состояние PG-кластера | Postgres Cluster → Consul (green) («Cluster state») | по стрелке — вероятно, DCS для Patroni (подтвердить) |
| Метрики | Prometheus (green) → Consul (green); «Выгрузка метрик во внутренний контур» | |
| Интернет | Harbor app → Интернет | proxy-cache |

Решением пользователя (D8) строки про бэкапы и метрики в лабораторию не входят — оставлены как часть исходной схемы.

Соответствие таблице узлов: `hb-app-01/02` = Harbor app (жёлтые), `hb-lb-01/02` = Harbor LB (зелёные), `hb-pg-01/02` = Postgres Cluster, `hb-redis-01..03` = Redis Cluster. Цвета на обеих схемах совпадают; легенды нет — смысл (вероятно, зоны/контуры) уточнить (D9).

Вне блока Harbor, но на диаграмме: **Nexus** (proxy, repo, LB, собственный Postgres Cluster), второй Consul/Prometheus («yellow»). Входит ли Nexus в лабораторию — D10 (по умолчанию нет: цель — Harbor).

**Что это меняет в первой версии этого раздела:**
- `hb-lb` — не входная точка Harbor, а балансировщик перед PG/Redis; вход обеспечивает Infra LB. Отсюда `database.external.host` = адрес Harbor LB, проблема «chart принимает один host:port» снимается.
- D4 закрыт по смыслу: блобы в S3 (Ceph RGW). В лаборатории S3-стенд-ин — MinIO (Ceph/Rook слишком тяжёл для одной машины) — подтвердить.
- Появились требования, которых раньше не было: Consul как DCS для Patroni и Infra LB как отдельный уровень (бэкапы и Prometheus есть на схеме, но в лабораторию не входят — D8).

**Ограничение соответствия:** на диаграмме «Redis Cluster», а chart 1.19.2 принимает только `redis` и `redis+sentinel` (режима Redis Cluster в values нет). Фактический режим в проде неизвестен — принят Sentinel как предположение (D3).

## Базовая линия (унаследована, проверена на harbor-on-kind)

| Компонент | Версия |
|-----------|--------|
| Kind CLI | `v0.30.0` |
| Node image | `kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a` |
| MetalLB chart | `0.16.1` |
| ingress-nginx chart | `4.15.1` (app `1.15.1`) |
| Harbor chart / app | `1.19.2` / `2.15.2` |

Ключи chart `1.19.2`, относящиеся к HA (сверено по `helm show values harbor/harbor --version 1.19.2`): `database.type: external` + `database.external.*`; `redis.type: external` + `redis.external.*` (встроенный Redis в 2.15.2 — Valkey, `goharbor/valkey-photon`); `persistence.imageChartStorage.type: s3` (для MinIO — `disableredirect: true`, для самоподписанного сертификата хранилища — `caBundleSecretName`); `replicas` у `core`, `portal`, `registry`, `jobservice`, `trivy` (по умолчанию везде `1`).

## Решения и открытые вопросы

**Открытых решений нет** (все закрыты 2026-09-24). Если что-то изменится — вернуть сюда.

**Решено / закрыто:**

- **D6 — критерий успеха в два этапа** (2026-09-24, пользователь): *первым* успехом считается работа всего стенда **с учётом распределения по 14 нодам** (веха 1, ниже); *только после неё* засчитываются остальные проверки (Phase 4, веха 2). Проверки Phase 4 до успеха вехи 1 успехом не считаются.
- **D1 — 14 нод** (2026-09-24): 1 control-plane + 13 воркеров, роль узла — label/taint: `app`×2, `lb`×2, `pg`×2, `redis`×3, `consul`×3, `s3`×1. Consul и MinIO живут на отдельных нодах, Consul — 3 сервера. *Предположение:* MinIO — одна нода (число не называлось). Имена нод в лаборатории — по аналогии с `hb-*` из прод-схемы. Infra LB — ingress-nginx на имеющихся нодах.
- **D2 — Patroni + Consul** (подтверждено пользователем 2026-09-24): PostgreSQL на 2 узла, состояние кластера в Consul. Версии и способ развёртывания — в Phase 2.
- **D3 — Redis: Sentinel (1 master + 2 replica) — ПРЕДПОЛОЖЕНИЕ.** Боевой режим пользователю неизвестен; на схеме «Redis Cluster», а chart 1.19.2 его не поддерживает (только `redis` и `redis+sentinel`). Пересмотреть, если станет известен реальный режим.
- **D4 — блобы registry в S3** (закрыто схемой: Ceph RGW №14; подтверждено: в лаборатории MinIO вместо Ceph).
- **D5 — один лабораторный кластер за раз** (2026-09-24): `CLUSTER=harbor`, `LB_IP=172.20.0.100` и пул `172.20.0.100–110` остаются как в `harbor-on-kind`. Перед `make cluster` здесь — `make cluster-delete` в старом репо (записи в `/etc/hosts` и `insecure-registries` переиспользуются).
- **D7 — Harbor LB = HAProxy ×2** на `lb`-нодах (подтверждено пользователем 2026-09-24). PG: health-check через Patroni REST API (эндпоинт роли primary — сверить по документации выбранной версии Patroni). Redis: проверка роли master. Harbor обращается к PG и Redis по одному адресу Service перед двумя HAProxy; при таком фронте Harbor получает обычный `redis`-адрес (режим `redis+sentinel` остаётся запасным вариантом). **Отклонение от прода:** там общий адрес, вероятно, держит keepalived, в лаборатории — ClusterIP Service. Infra LB — ingress-nginx + MetalLB.
- **D8 — минимальный объём** (2026-09-24): воспроизводим Harbor app ×2, Harbor LB ×2, PostgreSQL ×2 + Consul (Patroni), Redis ×3, S3 для блобов (MinIO), Infra LB. **Бэкапы PG/Redis и Prometheus с диаграммы в лабораторию не входят.**
- **D9 — цвета green/yellow:** для лаборатории не важны; сетевую сегментацию не делаем.
- **D10 — Nexus не входит** (не запрошен; находится вне блока Harbor на диаграмме).

## Критерии успеха (D6)

**Веха 1 — «стенд работает в распределении по 14 нодам».** Принимается, только когда выполнено всё:

1. 14 нод `Ready`; на воркерах роли по label/taint: `app`×2, `lb`×2, `pg`×2, `redis`×3, `consul`×3, `s3`×1.
2. Каждый компонент запущен на ноде *своей* роли (`kubectl get pods -A -o wide`): нет подов Harbor/PG/Redis/Consul/HAProxy/MinIO на чужих нодах; реплики одной роли лежат на *разных* нодах.
3. Кластерные сервисы здоровы: Consul — 3 сервера и есть лидер; Patroni — 1 leader + 1 replica (репликация идёт); Redis — 1 master + 2 replica и кворум Sentinel; HAProxy ×2 оба `Ready`; Harbor core / portal / registry / jobservice — по 2 реплики на двух `app`-нодах; бакет MinIO доступен.
4. Сквозной путь через всю цепочку (Infra LB → Harbor app → Harbor LB → PG/Redis, блобы в MinIO): UI отвечает `200`; push/pull образа и OCI-чарта проходят; `make deploy-app` проходит; блобы лежат в бакете MinIO, а не в томе registry.
5. Нагрузка действительно распределяется: серия pull/запросов через Infra LB обслуживается **обеими** `app`-репликами; HAProxy отдаёт трафик на текущий primary PG.

**Веха 2 — проверки отказоустойчивости** (Phase 4, H4.1–H4.7): выполняются и засчитываются только после успеха вехи 1.

## Последовательный план

Выполнять по фазам. Любой новый компонент (PostgreSQL, Redis, MinIO, операторы) — только с явно зафиксированной pinned-версией здесь и в `CLAUDE.md` до установки.

### Phase 0 — Решения и подготовка

- [ ] **H0.1** Закрыть D6 (остальные решены — см. выше) и зафиксировать pinned-версии Patroni/PostgreSQL, Consul, HAProxy, Redis/Sentinel, MinIO в этом файле и в `CLAUDE.md` до установки.
- [x] **H0.2** `CLUSTER` / `LB_IP` / MetalLB-пул оставлены как в `harbor-on-kind` (D5). Если HA потребует больше LB-IP — расширить пул в той же подсети и обновить связанные файлы.
- [ ] **H0.3** Сверить, что именно нужно шарить между репликами Harbor: логи jobservice (`jobservice.jobLoggers`), хранилище registry, Trivy-кэш — проверить по `helm show values` и документации Harbor HA, не по памяти.

### Phase 1 — Кластер

- [x] **H1.0** Предусловия хоста для multi-node KinD (выполнено 2026-09-24): `fs.inotify.max_user_instances=512` и `max_user_watches=524288` (постоянно, в `/etc/sysctl.d/99-kind.conf` — это настройка хоста, в репозитории её нет; на другой машине повторить); свободное место на `/` — 109 ГБ (было 32 ГБ при 97%; каждая нода хранит образы только своей роли — оценка ≈ 5–10 ГБ, не измерялась); RAM: доступно ≈ 31 ГБ из 38 (пользователь подтвердил ~30 ГБ), 16 CPU. Остальные лимиты хоста проверены и достаточны: `fs.file-max`, `kernel.pid_max`, nofile Docker (524288), `TasksMax`, conntrack (262144).
- [x] **H1.0a** Лимиты inotify подняты с запасом под 14 нод (выполнено пользователем 2026-09-24): `fs.inotify.max_user_instances=2048`, `fs.inotify.max_user_watches=1048576` (было 512 / 524288) — постоянно, в `/etc/sysctl.d/99-kind.conf`; значения проверены в живой системе. Это настройка хоста, в репозитории её нет.
- [ ] **H1.1** kind-конфиг на 14 нод (D1) с label/taint по ролям → `make cluster`, все ноды `Ready`. **Сразу после создания, до установки чего-либо:** измерить RAM всех нод (`docker stats --no-stream`) и сверить с доступными ≈ 30 ГБ (оценка потребления ≈ 12–13 ГБ); если kubelet/containerd падают с «too many open files» — поднять `fs.inotify.max_user_instances` (512 может не хватить на 14 нод; нужен `sudo`).
- [ ] **H1.2** Infra LB: MetalLB + ingress-nginx на multi-node; реплик ingress-nginx ≥ 2 (иначе он сам — единая точка отказа).
- [ ] **H1.3** LB IP достижим с хоста; проверить `docker network inspect kind` заново (subnet мог измениться).

### Phase 2 — Общие зависимости

- [ ] **H2.1** Consul ×3 (DCS для Patroni) на отдельных `consul`-нодах.
- [ ] **H2.2** PostgreSQL на 2 узла под Patroni + Consul (D2), база и пользователь для Harbor.
- [ ] **H2.3** Redis ×3 с Sentinel (D3, предположение).
- [ ] **H2.4** Harbor LB: HAProxy ×2 на `lb`-нодах перед PG (health-check по Patroni REST) и Redis (проверка роли master); один адрес Service для Harbor (D7).
- [ ] **H2.5** MinIO на отдельной `s3`-ноде (вместо Ceph RGW) + бакет для блобов registry.
- [ ] **H2.6** Доступность всего перечисленного из namespace Harbor.

### Phase 3 — Harbor в HA

- [ ] **H3.1** `hack/config/harbor-ha.yaml`: внешние БД/Redis, `imageChartStorage: s3`, `replicas ≥ 2` для core / portal / registry / jobservice.
- [ ] **H3.2** Trivy: реплицировать ли (StatefulSet со своим хранилищем) — решить и записать.
- [ ] **H3.3** Установка с pinned-версиями (отдельный `make`-таргет или параметр `install`); все поды `Ready`.
- [ ] **H3.4** Доверие CA (нода/хост) к новому Harbor; `make deploy-app` проходит.
- [ ] **H3.5** **Приёмка вехи 1** — все пять пунктов раздела «Критерии успеха (D6)» выполнены и результат записан сюда (команды и вывод кратко).

### Phase 4 — Проверка отказоустойчивости (веха 2: начинать только после H3.5)

- [ ] **H4.1** push/pull образа и OCI-чарта при всех репликах.
- [ ] **H4.2** Удалить один под registry/core *во время* push — push завершается (или корректно повторяется) без потери данных.
- [ ] **H4.3** Rolling update core/registry во время непрерывных pull (цикл `docker pull` / `curl /v2/`) — без ошибок у клиента.
- [ ] **H4.4** Потеря worker-ноды (если D1 = multi-node): сервис продолжает отвечать.
- [ ] **H4.5** demo-app: rollout после push нового тега, поды подтягивают образ; по `Hello, Kube! (from <pod>)` видно распределение по репликам.
- [ ] **H4.6** Proxy-cache: проект-прокси к внешнему registry (например Docker Hub) — pull через Harbor с любой реплики, повторный pull отдаётся из кэша; локальные проекты продолжают работать рядом.
- [ ] **H4.7** Отказ по ролям схемы: по очереди остановить `app` (1 из 2), Harbor LB (1 из 2), `pg` (primary — Patroni переключает через Consul), `redis` (master — Sentinel), Consul (по D1); сервис отвечает, push/pull проходят.

### Phase 5 — Документация

- [ ] **H5.1** `README.md`: HA-раздел, актуальные примеры вывода.
- [ ] **H5.2** `AGENTS.md` / `CLAUDE.md` под фактическое состояние.
- [ ] **H5.3** Acceptance с нуля: `cluster-delete` → `cluster` → зависимости → `install` (HA) → `deploy-app` → проверки Phase 4.

## Риски и заметки

- 14 нод-контейнеров на одной машине: потребление RAM не измерялось (доступно ≈ 30 ГБ, оценка ≈ 12–13 ГБ) — см. H1.1; при нехватке ресурсов сокращать по согласованию (например, число Consul-серверов), не молча.
- Один хост Docker: «HA» здесь учебная — общий диск, общее ядро, реальной изоляции отказов нет.
- Самоподписанный CA Harbor пересоздаётся при каждой установке → доверие на ноде надо обновлять после каждого `install` (`make deploy-app` это уже делает).
- Ресурсы: PostgreSQL + Redis + MinIO + N реплик Harbor на локальной машине — оценить RAM до старта.
- Уроки базовой линии, которые легко повторить: непинованные зависимости ломают сборку со временем (случай Flask/Werkzeug); MetalLB L2 не держит анонс сервиса без Ready-эндпоинтов — при «зависшем» LB IP сначала смотреть `kubectl get endpoints`.
