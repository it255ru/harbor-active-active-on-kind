# Ранбук: проверка стенда

Как проверить, что лабораторный стенд Harbor active-active собран правильно и здоров. Это те же проверки, которые выполнялись при аудите перед Phase 3 (2026-09-24); их можно запускать самому в любой момент: после `make cluster infra-lb ha-deps`, после правок манифестов, перед началом новой фазы.

Ранбук проверяет **состояние и распределение** (веха 1). Отказоустойчивость (падение primary PostgreSQL, master Redis, HAProxy, ноды) сюда не входит: это Phase 4 / веха 2 в `backlog.md`.

Документ написан так, чтобы его можно было механически перевести в Ansible (см. последний раздел): у каждой проверки есть идентификатор, команда, ожидаемый результат и что делать при отказе.

## Подготовка

Схема стенда (ноды, роли, адреса, порты): `docs/stand-topology.md`.

```bash
cd harbor-active-active-on-kind
make cluster-ctx                     # контекст kind-harbor
kubectl config current-context       # ожидается: kind-harbor
```

Переменные, которые используются в командах ниже:

| Что | Значение | Откуда |
|-----|----------|--------|
| Namespace зависимостей | `harbor-deps` | `hack/ha/00-namespace.yaml` |
| Адрес Infra LB | `172.20.0.100` | `Makefile` (`LB_IP`) |
| Роли и число нод | `app` 2, `lb` 2, `pg` 2, `redis` 3, `consul` 3, `s3` 1 | `hack/config/kind-cluster.yaml` |

Признак успеха везде указан в строке «Ожидается». Если результат отличается, смотрите «При отказе» и раздел «Диагностика» в конце.

## 1. Кластер

**V1.1 Все 14 нод `Ready`**

```bash
kubectl get nodes --no-headers | awk '$2!="Ready"' | wc -l      # Ожидается: 0
kubectl get nodes --no-headers | wc -l                          # Ожидается: 14
```

При отказе: `docker ps` (контейнеры нод живы?), `docker logs harbor-worker<N>`, лимиты inotify (`sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches`, нужно 2048 и 1048576).

**V1.2 Роли нод**

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,ROLE:'.metadata.labels.harbor-ha\/role' --no-headers \
  | awk '{print $2}' | sort | uniq -c
```

Ожидается: `app` 2, `consul` 3, `lb` 2, `pg` 2, `redis` 3, `s3` 1 и одна нода `<none>` (control-plane).

При отказе: кластер собран не из `hack/config/kind-cluster.yaml`. Пересоздать: `make cluster-delete && make cluster`.

**V1.3 Таинты ролей**

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINT:'.spec.taints[*].key' --no-headers | grep -c 'harbor-ha/role'   # Ожидается: 13
```

## 2. Поды и размещение

**V2.1 Нет подов не в `Running`/`Completed`**

```bash
kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"'      # Ожидается: пусто
```

**V2.2 Нет рестартов**

```bash
kubectl get pods -A --no-headers | awk '$5+0>0'                                # Ожидается: пусто
```

Единичный рестарт сразу после сборки не критичен, но его причину стоит посмотреть: `kubectl -n <ns> logs <pod> --previous`.

**V2.3 Предупреждения (информационная)**

```bash
kubectl get events -A --field-selector type=Warning --no-headers | awk '{print $1,$5,$6,$7,$8}' | sort | uniq -c
```

Ничего не «ожидается»: смотреть глазами. Известные безвредные: `Readiness probe failed` при старте `pg-*`/`redis-*`/`consul-*`; `ErrImagePull`/`ImagePullBackOff` при холодной загрузке образов (Docker Hub / quay.io), поды поднимаются сами. Тревожно, если предупреждения повторяются на уже `Running` поде.

**V2.4 Каждый под стоит на ноде своей роли**

```bash
kubectl get nodes -o custom-columns=N:.metadata.name,R:'.metadata.labels.harbor-ha\/role' --no-headers > /tmp/noderoles.txt
kubectl get pods -A -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,NODE:.spec.nodeName,WANT:'.spec.nodeSelector.harbor-ha\/role',PH:.status.phase --no-headers \
  | awk 'NR==FNR{r[$1]=$2; next}
         $1!="kube-system" && $1!="local-path-storage" && $5=="Running" {
           want=$4
           if (want=="<none>" && $2 ~ /^(ingress-nginx|metallb)/) want="lb"   # у этих подов свой способ закрепления (affinity)
           if (want=="<none>") print "NO-SELECTOR", $2
           else if (r[$3]!=want) print "MISPLACED", $2, "want", want, "on", r[$3]
         }' /tmp/noderoles.txt -
```

Ожидается: пусто. Если появились `MISPLACED` — под попал на чужую роль (таинт не сработал или у пода неверный selector). `NO-SELECTOR` — новый компонент без `nodeSelector`/toleration: добавить.

**V2.5 Реплики одной роли на разных нодах**

```bash
kubectl -n harbor-deps get pods --field-selector=status.phase=Running \
  -o custom-columns=APP:.metadata.labels.app,NODE:.spec.nodeName --no-headers | sort | uniq -d
```

Ожидается: пусто (нет двух подов одного приложения на одной ноде). Сводка «сколько подов где»:

```bash
kubectl -n harbor-deps get pods -o wide
```

Ожидается: `consul-*` — 3 разные consul-ноды; `pg-*` — 2 pg-ноды; `redis-*` — 3 redis-ноды; `harbor-lb-*` — 2 lb-ноды; `minio-0` — s3-нода.

## 3. Infra LB

**V3.1 Две реплики ingress-nginx на разных `lb`-нодах**

```bash
kubectl get pods -o wide --no-headers | grep ingress-nginx-controller | awk '{print $1,$2,$3,$7}'
```

Ожидается: 2 пода `1/1 Running` на `harbor-worker3` и `harbor-worker4` (или тех нодах, что имеют роль `lb`).

**V3.2 Адрес балансировщика**

```bash
kubectl get svc ingress-nginx-controller --no-headers | awk '{print $4}'       # Ожидается: 172.20.0.100
docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' kind      # Ожидается: содержит 172.20.0.0/16
```

При отказе (подсеть другая): менять `LB_IP` и связанные файлы, см. README, «Load balancer IP».

**V3.3 Балансировщик отвечает с хоста**

```bash
curl -s -o /dev/null -w '%{http_code}\n' -m 5 http://172.20.0.100/              # Ожидается: 404
curl -sk -o /dev/null -w '%{http_code}\n' -m 5 https://172.20.0.100/            # Ожидается: 404
```

`404` от default backend ingress-nginx — норма, пока не установлен Harbor (правил Ingress ещё нет). Отсутствие ответа — см. «Диагностика», раздел MetalLB. `ping` не отвечает и не должен: MetalLB в L2-режиме на ICMP не отвечает.

**V3.4 Компоненты MetalLB**

```bash
kubectl get pods --no-headers | grep -E 'metallb' | awk '{print $1,$2,$3}'
kubectl get ipaddresspool,l2advertisement -A --no-headers
```

Ожидается: controller, 2 speaker, 2 frr-k8s, statuscleaner — все `Running`; пул `172.20.0.100-172.20.0.110` и `l2advertisement`.

## 4. Consul

**V4.1 Кворум и лидер**

```bash
kubectl -n harbor-deps exec consul-0 -- consul operator raft list-peers
kubectl -n harbor-deps exec consul-0 -- consul members
```

Ожидается: три сервера в raft, из них 1 `leader` и 2 `follower` (Voter `true`), у фолловеров `Trails Leader By` = `0 commits`; в `members` три `alive` сервера.

При отказе (`No cluster leader`, менее 3 серверов): `kubectl -n harbor-deps logs consul-0`; типичная причина — одинаковые имена нод (`-node=` не из `POD_NAME`) или потерянные PVC.

**V4.2 Patroni записал состояние в Consul**

```bash
kubectl -n harbor-deps exec consul-0 -- consul kv get service/harbor-pg/leader   # Ожидается: имя текущего лидера, pg-0 или pg-1
```

## 5. PostgreSQL / Patroni

**V5.1 Состояние кластера**

```bash
kubectl -n harbor-deps exec pg-0 -- patronictl -c /etc/patroni/patroni.yml list
```

Ожидается: ровно один `Leader` в состоянии `running` и одна `Replica` в состоянии `streaming`, `Lag` = 0.

**V5.2 REST-проверки Patroni (те же, что использует HAProxy)**

```bash
kubectl -n harbor-deps exec pg-0 -- curl -s -o /dev/null -w 'pg-0 primary %{http_code}\n' http://pg-0.pg-headless:8008/primary
kubectl -n harbor-deps exec pg-0 -- curl -s -o /dev/null -w 'pg-1 primary %{http_code}\n' http://pg-1.pg-headless:8008/primary
kubectl -n harbor-deps exec pg-0 -- curl -s -o /dev/null -w 'pg-1 replica %{http_code}\n' http://pg-1.pg-headless:8008/replica
```

Ожидается (если лидер `pg-0`): `200`, `503`, `200`. Если лидер сменился, значения на нодах меняются местами.

**V5.3 Вход под пользователем Harbor через Harbor LB попадает на primary**

```bash
PGPASS=$(kubectl -n harbor-deps get secret pg-credentials -o jsonpath='{.data.harbor}' | base64 -d)
kubectl -n harbor-deps exec pg-1 -- psql "postgresql://harbor:$PGPASS@harbor-lb.harbor-deps:5432/registry" \
  -Atc "select 'in_recovery=' || pg_is_in_recovery()"
```

Ожидается: `in_recovery=false` (даже если команда запущена из пода реплики: HAProxy отправляет на primary).

**V5.4 Репликация (запись на primary видна на реплике)**

```bash
LEADER=$(kubectl -n harbor-deps exec consul-0 -- consul kv get service/harbor-pg/leader)      # pg-0 или pg-1
REPLICA=$([ "$LEADER" = pg-0 ] && echo pg-1 || echo pg-0)
kubectl -n harbor-deps exec $LEADER  -- psql "postgresql://harbor:$PGPASS@$LEADER.pg-headless:5432/registry" -Atc "create table v54_probe(i int); insert into v54_probe values (42)"
sleep 2
kubectl -n harbor-deps exec $REPLICA -- psql "postgresql://harbor:$PGPASS@$REPLICA.pg-headless:5432/registry" -Atc "select pg_is_in_recovery(), i from v54_probe"
kubectl -n harbor-deps exec $LEADER  -- psql "postgresql://harbor:$PGPASS@$LEADER.pg-headless:5432/registry" -Atc "drop table v54_probe"
```

Ожидается: `t|42` (реплика в recovery и видит строку). Пробная таблица удаляется в последней команде; если проверка оборвалась раньше — удалить `v54_probe` вручную.

## 6. Redis (Valkey + Sentinel)

**V6.1 Роли**

```bash
for i in 0 1 2; do kubectl -n harbor-deps exec redis-$i -c valkey -- valkey-cli role | head -1; done | paste -sd' '
```

Ожидается: один `master` и два `slave` (порядок зависит от того, кто мастер).

**V6.2 Кворум Sentinel и текущий master**

```bash
kubectl -n harbor-deps exec redis-0 -c sentinel -- valkey-cli -p 26379 sentinel ckquorum mymaster
kubectl -n harbor-deps exec redis-0 -c sentinel -- valkey-cli -p 26379 sentinel get-master-addr-by-name mymaster
kubectl -n harbor-deps exec redis-0 -c sentinel -- valkey-cli -p 26379 sentinel master mymaster | paste -sd' ' | grep -oE 'flags [^ ]+|num-slaves [0-9]+|num-other-sentinels [0-9]+|quorum [0-9]+'
```

Ожидается: `OK 3 usable Sentinels...`; адрес `redis-N.redis-headless...` и порт `6379`; `flags master` (не `s_down`/`o_down`), `num-slaves 2`, `num-other-sentinels 2`, `quorum 2`.

**V6.3 Пароль обязателен, запись реплицируется**

```bash
kubectl -n harbor-deps exec redis-0 -c valkey -- sh -c 'env -u REDISCLI_AUTH valkey-cli ping'      # Ожидается: NOAUTH Authentication required.
kubectl -n harbor-deps exec redis-0 -c valkey -- sh -c 'valkey-cli -h harbor-lb.harbor-deps set v63 ok'     # OK (на мастере, через Harbor LB)
kubectl -n harbor-deps exec redis-2 -c valkey -- valkey-cli get v63                                           # ok (читается с любой реплики)
kubectl -n harbor-deps exec redis-0 -c valkey -- sh -c 'valkey-cli -h harbor-lb.harbor-deps del v63'         # 1
```

Пароль берётся из переменной окружения контейнера (`REDISCLI_AUTH`), в командной строке не передаётся.

## 7. Harbor LB (HAProxy)

**V7.1 Два пода на разных `lb`-нодах**

```bash
kubectl -n harbor-deps get pods -l app=harbor-lb -o wide --no-headers | awk '{print $1,$2,$3,$7}'
```

Ожидается: 2 пода `1/1 Running` на разных нодах.

**V7.2 Бэкенды: по одному живому на PG и на Redis (на каждом HAProxy)**

```bash
for p in $(kubectl -n harbor-deps get pods -l app=harbor-lb -o name); do
  kubectl -n harbor-deps exec $p -- wget -qO- 'http://127.0.0.1:8404/stats;csv' \
    | awk -F, '($1=="postgres"||$1=="redis")&&$2!="BACKEND"&&$2!="FRONTEND"{printf "%s:%s=%s ",$1,$2,$18}'; echo
done
```

Ожидается, для обоих подов: `postgres:<primary>=UP`, второй PG `DOWN`; `redis:<master>=UP`, две реплики `DOWN`. `DOWN` у реплик — норма: HAProxy пускает трафик только на primary/master. Если `UP` нет ни у одного PG или Redis — HAProxy не видит primary/master (см. V5.2 и V6.1).

Веб-статистика: `kubectl -n harbor-deps port-forward deploy/harbor-lb 8404:8404`, затем http://127.0.0.1:8404/stats.

## 8. MinIO

**V8.1 Под на `s3`-ноде, инициализация выполнена**

```bash
kubectl -n harbor-deps get pod minio-0 -o wide --no-headers | awk '{print $1,$2,$3,$7}'     # Ожидается: 1/1 Running на s3-ноде
kubectl -n harbor-deps get job minio-init --no-headers                                       # Ожидается: Complete 1/1
kubectl -n harbor-deps logs job/minio-init | tail -1                                         # Ожидается: init done
```

**V8.2 Доступ пользователя Harbor только к своему бакету**

```bash
AK=$(kubectl -n harbor-deps get secret minio-credentials -o jsonpath='{.data.harbor-access-key}' | base64 -d)
SK=$(kubectl -n harbor-deps get secret minio-credentials -o jsonpath='{.data.harbor-secret-key}' | base64 -d)
MC=quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727
kubectl run v82 --rm -i --restart=Never --image=$MC \
  --overrides='{"spec":{"nodeSelector":{"harbor-ha/role":"app"},"tolerations":[{"key":"harbor-ha/role","operator":"Equal","value":"app","effect":"NoSchedule"}]}}' \
  --command -- sh -c "export MC_CONFIG_DIR=/tmp/mc; mc alias set h http://minio.harbor-deps:9000 $AK $SK >/dev/null \
    && echo probe > /tmp/p && mc cp /tmp/p h/registry-blobs/v82 && mc cat h/registry-blobs/v82 && mc rm h/registry-blobs/v82; \
    mc mb h/other 2>&1 | tail -1"
```

Ожидается: запись, чтение (`probe`) и удаление в `registry-blobs` проходят; `mc mb h/other` — `Access Denied`. Тест-под запускается на `app`-ноде (как будет работать Harbor) и удаляется сам (`--rm`).

## 9. Доступность из namespace Harbor

Проверяет цепочку так, как её увидит Harbor: тестовые поды в namespace `default` на `app`-ноде ходят на единые адреса. Образы берутся те же, что и в манифестах (закреплены по digest).

```bash
OV='{"spec":{"nodeSelector":{"harbor-ha/role":"app"},"tolerations":[{"key":"harbor-ha/role","operator":"Equal","value":"app","effect":"NoSchedule"}]}}'
g(){ kubectl -n harbor-deps get secret "$1" -o jsonpath="{.data.$2}" | base64 -d; }
PGI=postgres:18.6-alpine3.24@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873
VKI=valkey/valkey:9.0.6-alpine3.24@sha256:187679e3bd4036959631e3f03983ab2ba503ab21e6fd0454d508e909db2ee989

# V9.1 PostgreSQL через Harbor LB + V9.2 Consul
kubectl run v91 --rm -i --restart=Never --image=$PGI --overrides="$OV" --env=PGPASSWORD=$(g pg-credentials harbor) --command -- sh -c '
  psql "host=harbor-lb.harbor-deps port=5432 user=harbor dbname=registry connect_timeout=5" -Atc "select not pg_is_in_recovery()";
  wget -qO- http://consul.harbor-deps:8500/v1/status/leader; echo'

# V9.3 Redis через Harbor LB
kubectl run v93 --rm -i --restart=Never --image=$VKI --overrides="$OV" --env=REDISCLI_AUTH=$(g redis-credentials password) --command -- \
  sh -c 'valkey-cli -h harbor-lb.harbor-deps set v93 ok && valkey-cli -h harbor-lb.harbor-deps get v93 && valkey-cli -h harbor-lb.harbor-deps del v93'
```

Ожидается: `t` и адрес лидера Consul в кавычках (V9.1–V9.2); `OK`, `ok`, `1` (V9.3). Доступность MinIO из `default` проверяется командой V8.2 (она уже запускается в `default`). Служебные строки `If you don't see a command prompt` и `pod ... deleted` — норма.

## 10. Ресурсы хоста

```bash
docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' | sort -k2 -h       # память по нодам
free -g | sed -n 2p                                                              # свободная память хоста
df -h /                                                                          # свободное место
sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches                 # 2048 и 1048576
```

Ориентиры (2026-09-24, без Harbor): около 3,9 ГиБ на 14 нод; control-plane около 740 МиБ, `lb`-ноды 500–540, `pg` 290–310, `s3` около 360, остальные 120–180. Со всем стендом оценка 12–13 ГиБ.

## 11. Harbor (после `make harbor-ha` и `make deploy-app`)

**V11.1 Реплики и размещение**

```bash
kubectl get pods -o custom-columns=C:.metadata.labels.component,NODE:.spec.nodeName --no-headers | grep -E '^(core|portal|registry|jobservice)' | sort | uniq -c
kubectl get pods --no-headers | grep -E 'harbor-(database|redis)' | wc -l      # внутренних БД и Redis нет: ожидается 0
```

Ожидается: 8 строк с `1` (по одному поду каждого компонента на `harbor-worker` и `harbor-worker2`, то есть на обеих `app`-нодах); значение `2` в строке означает, что обе реплики на одной ноде (проверять после каждого rollout); `0` внутренних баз. Размещение по ролям проверяет V2.4. У jobservice 2-3 рестарта после первого запуска — штатная гонка со стартом core.

**V11.2 UI, API и токены**

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://core.harbor.domain/                  # Ожидается: 200
curl -sk -o /dev/null -w '%{http_code}\n' https://core.harbor.domain/v2/               # Ожидается: 401 (registry жив, нужен токен)
echo Harbor12345 | docker login core.harbor.domain -u admin --password-stdin           # Ожидается: Login Succeeded
```

Если `docker login` даёт 500 и в логах core `unable to get PrivateKey from PEM type: PRIVATE KEY` — ключ токена в формате PKCS#8; см. «Диагностика».

**V11.3 Push/pull образа и OCI-чарта**

```bash
make deploy-app                                                                          # проект, build/push, деплой; в конце Demo app ready
curl -s http://172.20.0.101:5000/                                                        # Hello, Kube! (from <pod>)
```

Чарт: `helm registry login` → `helm package helm-hello-kube` → `helm push ... oci://core.harbor.domain/python/hello --ca-file ca.crt` → `helm pull`/`helm install` из OCI → `helm test hello-kube` (Phase: Succeeded), команды — в README.

**V11.4 Блобы лежат в MinIO, а не в томе**

```bash
kubectl get pvc --no-headers | awk '{print $1}'                                          # Ожидается: только data-harbor-trivy-0
# объекты бакета: mc ls --recursive h/registry-blobs (см. V8.2 для запуска mc); после push должны быть docker/registry/v2/blobs/...
```

**V11.5 Данные Harbor во внешних сервисах**

```bash
PGPASS=$(kubectl -n harbor-deps get secret pg-credentials -o jsonpath='{.data.harbor}' | base64 -d)
kubectl -n harbor-deps exec pg-0 -- psql "postgresql://harbor:$PGPASS@harbor-lb.harbor-deps:5432/registry" -Atc "select count(*) from project"     # Ожидается: >= 1
kubectl -n harbor-deps exec redis-0 -c valkey -- sh -c 'valkey-cli -n 0 dbsize'          # Ожидается: > 0 на текущем master (номер пода может отличаться, см. V6.1)
```

**V11.6 Rolling update не блокируется**

```bash
kubectl rollout restart deploy/harbor-core && kubectl rollout status deploy/harbor-core --timeout=180s     # Ожидается: successfully rolled out
```

Если обновление зависает с `Pending`-подом и `didn't satisfy existing pods anti-affinity rules` — в спеке остался обязательный `podAntiAffinity` (см. «Диагностика»).

## 12. Распределение нагрузки (критерий 5 вехи 1)

Проверяет, что запросы через Infra LB обслуживаются обеими репликами. Приложения Harbor не пишут access-логи, поэтому считаем по логам ingress-nginx: в записи есть адрес пода-получателя (`upstream`).

```bash
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for i in $(seq 1 100); do curl -sk -o /dev/null https://core.harbor.domain/api/v2.0/systeminfo; done   # core
for i in $(seq 1 100); do curl -sk -o /dev/null https://core.harbor.domain/; done                       # portal
for c in $(kubectl get pods -l app.kubernetes.io/name=ingress-nginx -o name); do kubectl logs $c --since-time=$T0; done > /tmp/ing.log
```

Затем разобрать `/tmp/ing.log`: для каждой строки взять имя backend-сервиса в квадратных скобках (`[default-harbor-core-80]` или `[default-harbor-portal-80]`) и IP пода сразу после него, сопоставить IP с подами (`kubectl get pods -o custom-columns=N:.metadata.name,IP:.status.podIP`) и посчитать запросы на каждый под.

Ожидается: у `core` и у `portal` запросы разделены между двумя подами (в приёмке 2026-09-24: core 127/131, portal 50/50). Для registry: после серии `docker rmi` + `docker pull` (например, 20 раз) команда `kubectl logs <registry-pod> -c registry --since-time=$T0 | grep -c 'GET /v2/'` даёт ненулевое значение у обоих подов (в приёмке 20 и 18).

HAProxy отправляет запросы БД на primary:

```bash
kubectl -n harbor-deps exec pg-0 -- sh -c "PGPASSWORD=\$PATRONI_SUPERUSER_PASSWORD psql -U postgres -h pg-0.pg-headless -Atc \"select count(*), count(distinct client_addr) from pg_stat_activity where usename='harbor'\""
```

Ожидается на primary: `N|2` (соединения `harbor` от двух адресов, то есть от обоих HAProxy); на реплике `0`. Если лидер сменился, поменять `pg-0` на текущего лидера (V4.2).

## 13. Phase 4 (веха 2): проверки отказоустойчивости

Выполняются только после приёмки вехи 1. Здесь описываются по мере выполнения; результаты и выводы — в `backlog.md` (H4.x).

### P4.1 push/pull образа и OCI-чарта при всех репликах

Не разрушающая: все реплики работают, проверяется путь данных (в том числе multipart-загрузка в S3 и параллельные записи). Тестовые артефакты удаляются в конце.

```bash
mkdir /tmp/p41 && cd /tmp/p41
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > Dockerfile <<'EOF'
FROM core.harbor.domain/python/hello:1.0
ARG N
RUN dd if=/dev/urandom of=/blob-$N bs=1M count=40 2>/dev/null
EOF
for n in a b; do docker build -q --build-arg N=$n -t core.harbor.domain/python/hello:h41-$n . >/dev/null; done
docker push core.harbor.domain/python/hello:h41-a & docker push core.harbor.domain/python/hello:h41-b & wait        # параллельный push, digest у обоих
docker rmi core.harbor.domain/python/hello:h41-a core.harbor.domain/python/hello:h41-b
docker pull core.harbor.domain/python/hello:h41-a; docker pull core.harbor.domain/python/hello:h41-b               # digest должны совпасть с pushed
```

Ожидается: оба `push` завершаются с `digest: sha256:...`, оба `pull` возвращают те же digest. Дальше:

```bash
# 1) pull через containerd ноды (pull secret harbor), под на control-plane
kubectl run p41 --image=core.harbor.domain/python/hello:h41-a --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}],"imagePullSecrets":[{"name":"harbor"}]}}'
kubectl wait --for=condition=ready pod/p41 --timeout=120s; kubectl get pod p41 -o jsonpath='{.status.containerStatuses[0].imageID}'; echo   # тот же digest
kubectl delete pod p41

# 2) OCI-чарт
curl -sk https://core.harbor.domain/api/v2.0/systeminfo/getcert -o ca.crt
echo Harbor12345 | helm registry login core.harbor.domain -u admin --password-stdin --ca-file ca.crt
helm package --version 0.1.1 <репозиторий>/helm-hello-kube
helm push --ca-file ca.crt hello-kube-0.1.1.tgz oci://core.harbor.domain/python/hello
rm hello-kube-0.1.1.tgz; helm pull --ca-file ca.crt oci://core.harbor.domain/python/hello/hello-kube --version 0.1.1      # тот же digest
helm install hello-kube --ca-file ca.crt oci://core.harbor.domain/python/hello/hello-kube --version 0.1.1
helm test hello-kube; helm uninstall hello-kube; kubectl delete pod hello-kube-test-connection --ignore-not-found
```

Ожидается: `helm test` — `Phase: Succeeded`.

Участие обеих реплик (счётчики с момента `T0`):

```bash
for p in $(kubectl get pods -l component=registry -o name); do
  echo "$p PATCH=$(kubectl logs $p -c registry --since-time=$T0 | grep -c 'PATCH /v2/') PUT=$(kubectl logs $p -c registry --since-time=$T0 | grep -c 'PUT /v2/')"
done
```

Ожидается: ненулевые PATCH/PUT у обоих подов registry; для core — разбор логов ingress-nginx как в разделе 12 (фильтр путей `/v2/`). В MinIO размер бакета вырастает примерно на объём загруженных слоёв (`mc du h/registry-blobs`, см. V8.2).

Очистка тестовых данных:

```bash
curl -sk -u admin:Harbor12345 -X DELETE "https://core.harbor.domain/api/v2.0/projects/python/repositories/hello/artifacts/h41-a"
curl -sk -u admin:Harbor12345 -X DELETE "https://core.harbor.domain/api/v2.0/projects/python/repositories/hello/artifacts/h41-b"
curl -sk -u admin:Harbor12345 -X DELETE "https://core.harbor.domain/api/v2.0/projects/python/repositories/hello%252Fhello-kube/artifacts/0.1.1"
```

Удаление артефакта не освобождает блобы в MinIO: место вернёт только сборка мусора registry (GC), в лаборатории она не запускается.

### P4.2 Удаление пода registry/core во время push

Разрушающая проверка: убивается под, который прямо сейчас принимает загрузку. Скрипт `hack/tests/h42-kill-during-push.sh` делает всё сам (сборка образа, ограничение скорости, поиск активного пода, убийство, сравнение digest, очистка по digest).

```bash
hack/tests/h42-kill-during-push.sh registry registry h42-reg      # под registry (контейнер registry)
hack/tests/h42-kill-during-push.sh core core h42-core            # под core (контейнер core)
# необязательно: LAYERS=2 SIZE_MB=200 RATE=80mbit THRESHOLD=2000000
```

Условия и предосторожности:

- Все реплики должны быть в норме до запуска (`kubectl get deploy harbor-core harbor-registry`: `2/2`) и загрузка хоста низкой (`cut -d' ' -f1 /proc/loadavg` меньше 3; скрипт ждёт этого сам).
- Не увеличивать объём данных: гигабайты записи на общий диск ломают control-plane и Sentinel (см. «Диагностика»). Значения по умолчанию (2 слоя по 200 МБ) проверены.
- Ограничение скорости (`tc`, 80 Мбит/с на исходящем трафике `harbor-worker` и `harbor-worker2`) нужно, чтобы загрузка длилась около двух минут: на localhost без него 1–4 ГБ уходят за секунды. Скрипт снимает ограничение при любом выходе; проверить вручную: `docker exec harbor-worker tc qdisc show dev eth0` должно вернуть `noqueue`.
- Активный под определяется по росту счётчика `eth0 rx` (`grep eth0 /proc/net/dev`, в контейнерах registry нет `awk`, разбор на стороне хоста).

Ожидается:

- Скрипт печатает `active pod: <под>` и `FORCE DELETE <под>`.
- `docker push` завершается с `exit=0` и `digest: sha256:...`, в выводе клиента есть строки `Retrying in N s` (клиент повторил загрузку слоя после 502).
- В сводке кодов ingress-nginx: небольшое число `PATCH 502` в момент убийства, затем успешные `PATCH 202` и `PUT 201`.
- В конце `pull back` возвращает тот же digest, что и push (целостность).
- Убитая реплика пересоздана (`kubectl get pods -l component=registry` или `core`: `2/2 Running`, Deployment `2/2`).

Если `no active pod detected` — push закончился раньше, чем детектор увидел трафик: проверить ограничение скорости (`tc`) и порог `THRESHOLD`. Если push упал с `unauthorized` — проверить Redis/Sentinel и загрузку хоста (V6.x, V7.2): при недоступном Redis core временно отклоняет авторизацию.

После проверки в MinIO остаются нулевые `_uploads/<uuid>/data` (незавершённые multipart) — штатный мусор S3-драйвера, есть и у пушей без сбоев. Тестовые артефакты удаляются скриптом по digest; блобы в S3 остаются до сборки мусора (GC).

### P4.3 Rolling update core и registry во время непрерывных pull

Проверяет, что обновление реплик не даёт ошибок клиентам. Не разрушает данные; кратковременно заменяет поды core и registry по очереди.

```bash
hack/tests/h43-rolling-update.sh              # core, затем registry (по умолчанию)
hack/tests/h43-rolling-update.sh registry     # только registry
# необязательно: WORKDIR=<каталог для логов> HARBOR_AUTH=admin:Harbor12345
```

Что делает: запускает через Infra LB три нагрузки (запрос манифеста каждые ~0,1 с; скачивание блоба 13 МБ каждые ~0,4 с; `docker rmi` + `docker pull` подряд), выполняет `kubectl rollout restart` и `rollout status` для каждого компонента, держит нагрузку до и после и печатает разбор по фазам (`baseline`, `rollout-core`, `after-core`, `rollout-registry`, ...). curl не повторяет запросы, то есть каждая ошибка в логе — это ошибка, которую увидел бы клиент; у `docker pull` есть собственные повторы клиента.

Ожидается: в каждой фазе `errors=0` у `manifest` и `blob`, `failed=0` у `docker pull`, самый медленный запрос порядка долей секунды (в приёмке 0,3–0,5 с). Один прогон длится около минуты; для статистики повторить несколько раз (в H4.3 — 4 прогона до исправления и 4 после).

Перед запуском: все реплики `2/2`, загрузка хоста низкая. Нагрузка лёгкая намеренно (общий диск, см. P4.2).

Если появляются `502` (`http=502`) или паузы около 5 с: смотреть логи core на `proxy error: ... connection refused` и проверить наличие `preStop` (строка в «Диагностике»); `preStop: sleep 15` добавляет `hack/helm-postrender.py` при `make harbor-ha`.

### P4.4 Потеря worker-ноды

Разрушающая проверка: контейнер `app`-ноды убивается без корректной остановки (`docker kill`) и в конце запускается обратно. При сбое скрипта ноду нужно вернуть вручную: `docker start harbor-worker2` (или `harbor-worker`).

```bash
hack/tests/h44-node-loss.sh harbor-worker2               # нода с trivy; ждёт вытеснения подов (~7 мин)
EVICT_WAIT=0 hack/tests/h44-node-loss.sh harbor-worker   # без ожидания вытеснения (~3,5 мин)
```

Что делает: под лёгкой нагрузкой через Infra LB (манифест, блоб, `docker pull`, без повторов в curl) убивает ноду, ждёт `NotReady`, обновления Endpoints, при `EVICT_WAIT=1` — вытеснения подов (~5 мин, `tolerationSeconds: 300`), затем запускает ноду, ждёт `Ready` и `2/2` у всех Deployment'ов Harbor, печатает разбор по фазам (`node-down` до `NotReady`, `endpoints-updated`, `degraded-steady`, `evicted`, `node-up`, `node-ready`, `recovered`).

Ожидается:

- нода `NotReady` примерно через 50 с; в этот момент её поды исчезают из Endpoints;
- ошибок клиентов нет или единичные `502` у запросов, оборванных в момент падения; `docker pull` завершаются успешно;
- в фазе `node-down` (до `NotReady`) возможны задержки: манифест/блоб до ~10 с, `docker pull` до ~30 с; после `NotReady` — доли секунды;
- при ожидании вытеснения (~5 мин) замены core/portal/registry/jobservice в `Pending` (`didn't match pod topology spread constraints`), trivy `Terminating` на мёртвой ноде;
- после `docker start` нода `Ready` за секунды, Deployment'ы `2/2` примерно за минуту, распределение 1+1 (V11.1), trivy на своей ноде.

Что не проверяется: постоянная потеря ноды без возврата и потеря нод других ролей (pg, redis, consul, lb, s3): это H4.7.

### P4.5 demo-app: rollout после push нового тега

Не разрушает данные (вариант `DEGRADE=1` убивает по одному поду registry и core, они пересоздаются). Проверяет полный цикл доставки: push тега в Harbor, rollout приложения, pull образа kubelet-ом из Harbor, распределение запросов по репликам.

```bash
hack/tests/h45-app-rollout.sh                # Harbor целиком
DEGRADE=1 hack/tests/h45-app-rollout.sh      # перед rollout убиты один registry и один core
```

Ожидается:

- `docker push` нового тега завершается с `digest: sha256:...`;
- `rollout status` заканчивается `successfully rolled out` (порядка 10 с);
- новые поды на `imageID` = запушенному digest (блок `new pods`);
- в событиях kubelet для нового тега `Pulling` и `Successfully pulled image ...` (без `ErrImagePull`);
- пробник: `0 failed`; до rollout отвечают обе старые реплики, после — обе новые (`pods answering`), в конце 40 запросов делятся между ними;
- скрипт возвращает `hello:1.0` и удаляет тестовый артефакт по digest (`delete test artifact by digest: 200`).

Если новый под в `ErrImagePull` с `x509: certificate signed by unknown authority` — containerd ноды не доверяет текущему CA Harbor (см. «Диагностику»). После завершения проверить, что `hello:1.0` на месте: `curl -sk -u admin:Harbor12345 https://core.harbor.domain/api/v2.0/projects/python/repositories/hello/artifacts`.

## Диагностика

| Симптом | Куда смотреть |
|---------|---------------|
| Под `Pending` | `kubectl describe pod`: чаще всего нет toleration/`nodeSelector` под таинт роли; либо `podAntiAffinity` не находит свободной ноды |
| `ErrImagePull` / `ImagePullBackOff` при старте | временный сбой Docker Hub/quay.io — ждать ретрая; образ Patroni `harbor-ha/patroni:4.1.5-pg18.6` грузится только `make pg-image` (`imagePullPolicy: Never`), после пересоздания кластера нужен `make postgres` |
| Consul без лидера | `kubectl -n harbor-deps logs consul-0`; одинаковые имена нод (`-node=`), потерянные PVC |
| Patroni не выбирает лидера | `patronictl ... list`, `logs pg-0`; доступность `consul.harbor-deps:8500`; пароли `pg-credentials` не совпадают с данными на PVC (Secret удалён, PVC остался) |
| HAProxy: у PG/Redis нет `UP` | V5.2 и V6.1: primary/master есть? `logs deploy/harbor-lb`; после правки конфига HAProxy не перечитывает его сам — поднять аннотацию `config-version` в `hack/ha/haproxy.yaml` |
| Sentinel: `flags s_down`/`o_down` | `logs redis-N -c sentinel`; резолвинг `redis-N.redis-headless.harbor-deps.svc.cluster.local` |
| MinIO `Access Denied` у Harbor | `minio-init` не завершился (V8.1); повторить `make minio` |
| `172.20.0.100` не отвечает | `kubectl get endpoints ingress-nginx-controller` (нет Ready-подов — MetalLB не держит анонс), `kubectl logs -l app.kubernetes.io/component=speaker`, подсеть `kind` (V3.2) |
| `docker login` → 500, в логах core `unable to get PrivateKey from PEM type: PRIVATE KEY` | Secret `harbor-ha-token` создан с ключом PKCS#8. Удалить его и выполнить `make harbor-ha` (скрипт создаёт PKCS#1), затем `kubectl rollout restart deploy/harbor-core` |
| Rolling update завис, новый под `Pending`, `didn't satisfy existing pods anti-affinity rules` | обязательный `podAntiAffinity` на двух нодах блокирует surge-под; использовать `topologySpreadConstraints` (как в `harbor-ha.yaml`) или `maxSurge: 0` (как у `harbor-lb`); уже застрявшие Deployment'ы — `scale 0` → `2` |
| control-plane: `kube-controller-manager`/`kube-scheduler` в `CrashLoopBackOff`, поды не пересоздаются | лог `leaderelection lost`/`context deadline exceeded` — перегрузка общего диска (load average > 10, `iotop`); подождать спада нагрузки (компоненты поднимаются сами), не запускать тяжёлые push/сборки; тайминги leader-election заданы в `kind-cluster.yaml` (lease 60 s) |
| Sentinel часто переключает master, в логах Valkey `AOF fsync is taking too long` | перегрузка диска; `down-after-milliseconds` = 15000 (`SENTINEL SET mymaster down-after-milliseconds 15000` на всех трёх Sentinel); HAProxy сам находит нового master, смотреть V6.1/V7.2 |
| После очистки пропал `hello:1.0` | артефакт удалён вместе с чужим тегом на том же digest; `make deploy-app` (тот же digest); удалять тестовые артефакты по digest, не по тегу |
| При rolling update клиенты получают 502, в логах core `proxy error: dial tcp <ClusterIP registry>:5000: connect: connection refused` | под останавливается раньше, чем маршрутизация убрала его; проверить `preStop` у core/registry/portal (`kubectl get deploy harbor-registry -o jsonpath='{.spec.template.spec.containers[*].lifecycle}'`); `preStop` добавляет `hack/helm-postrender.py` при `make harbor-ha` (нужен PyYAML) |
| После потери ноды поды Harbor остались `Pending` (`didn't match pod topology spread constraints`) | так и должно быть, пока жива одна `app`-нода: `maxSkew: 1` не пускает вторую реплику на ту же ноду; сервис работает на одной реплике, после возврата ноды Deployment'ы возвращаются к `2/2` сами (≈ 1 мин); `harbor-trivy-0` ждёт свою ноду (PVC привязан к ней) |
| Новые pod-ы приложения в `ErrImagePull`: `x509: certificate signed by unknown authority` при pull с `core.harbor.domain` | containerd ноды не доверяет текущему CA Harbor. С `harbor-ha-ingress-tls` CA стабилен и не меняется при `helm upgrade`; если ошибка есть, сравнить серийники: `curl -sk https://core.harbor.domain/api/v2.0/systeminfo/getcert \| openssl x509 -noout -serial` и `docker exec harbor-control-plane openssl x509 -in /usr/local/share/ca-certificates/harbor-ca.crt -noout -serial`; при различии `make deploy-app` (переустанавливает доверие) |
| Сбросить один компонент | удалить его Secret **и** PVC (`data-<имя>-N`), затем `make <таргет>`; удалять только Secret нельзя: новый пароль не совпадёт с данными |
| Всё сломалось | `make cluster-delete && make cluster && make infra-lb && make ha-deps` (около 11 минут) |

## Что ранбук не проверяет

- Отказы и переключения (Patroni failover, Sentinel failover, потеря одного HAProxy, потеря ноды): Phase 4 (H4.x) в `backlog.md`, засчитываются только после приёмки вехи 1 (H3.5).
- Производительность и нагрузка.

## Перевод в Ansible (план)

Цель: те же проверки как воспроизводимый плейбук, который запускается одной командой и даёт сводный отчёт.

**Принципы:**

- Одна проверка = одна задача (или блок) с тем же идентификатором (`V5.1` и т.д.) в `name:`; это даёт готовые теги (`--tags V5`) и читаемый отчёт.
- Проверки только читают: `changed_when: false`. Проверки с записью (V5.4, V6.3, V8.2, V9.x) используют уникальные ключи/таблицы и обязательно убирают за собой (`always:` в `block`).
- Ожидаемое значение проверяется через `failed_when`/`assert` (`that:` + `fail_msg:` из колонки «При отказе»), а не глазами.
- Пароли берутся из Secret'ов кластера (`kubernetes.core.k8s_info` + `b64decode`), задачи с ними — `no_log: true`.
- Топология не хардкодится: ожидаемые числа нод по ролям, namespace, `LB_IP` — переменные (`group_vars/all.yml`), источник правды — `hack/config/kind-cluster.yaml` и `Makefile`.

**Соответствие модулям:**

| Проверки | Ansible |
|----------|---------|
| V1, V2, V3.1, V3.2, V3.4, V7.1, V8.1 | `kubernetes.core.k8s_info` (Node, Pod, Service, Job) + `assert` по ответу; V2.4 и V2.5 — расчёт в Jinja2 по списку подов и нод |
| V4, V5.1, V5.2, V6.1, V6.2, V7.2 | `kubernetes.core.k8s_exec` (`consul`, `patronictl`, `curl`, `valkey-cli`, `wget`) с разбором вывода (`patronictl list -f json`, CSV статистики HAProxy) |
| V3.3 | `ansible.builtin.uri` (`status_code: 404`, `validate_certs: false` для HTTPS) |
| V3.2 (подсеть) | `community.docker.docker_network_info` или `command: docker network inspect` |
| V5.3, V5.4, V6.3, V8.2, V9 | `kubernetes.core.k8s` (создание и удаление тест-Pod/Job) + чтение логов через `k8s_log`; либо `k8s_exec` в уже существующие поды, где это возможно |
| V10 | `command: docker stats` / `ansible.builtin.setup` (память и диск хоста), `sysctl` |

**Предполагаемая структура (не создана):**

```text
ansible/
  verify.yml                # playbook: роли по разделам, теги V1..V10
  group_vars/all.yml        # namespace, LB_IP, ожидаемое число нод по ролям
  roles/verify_cluster/ verify_pods/ verify_infra_lb/ verify_consul/
        verify_postgres/ verify_redis/ verify_haproxy/ verify_minio/ verify_e2e/ verify_host/
```

Требуются коллекции `kubernetes.core` (и опционально `community.docker`) и Python-модуль `kubernetes` на управляющей машине. Итог плейбука: сводная таблица «проверка — результат» и ненулевой код возврата при любом отказе, чтобы его можно было запускать по расписанию и в CI. В `backlog.md` это оформлено как H5.4.
