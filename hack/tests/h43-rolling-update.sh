#!/usr/bin/env bash
# H4.3 (backlog): rolling update of core and registry while clients pull continuously.
#
# usage: hack/tests/h43-rolling-update.sh [component ...]        (default: core registry)
# env:   HARBOR_HOST, HARBOR_AUTH (default admin:Harbor12345), WORKDIR (default: a fresh mktemp dir)
#
# Load (all through the Infra LB, deliberately light: the lab shares one host disk):
#   manifest : GET /v2/python/hello/manifests/1.0            every ~0.1 s   (core -> registry -> S3)
#   blob     : GET the biggest layer of python/hello:1.0     every ~0.4 s   (13 MB, streamed by registry from MinIO)
#   pull     : docker rmi + docker pull python/hello:1.0     back to back   (real client with its own retries)
# curl does NOT retry, so every error the load generators log is an error a client would have seen.
# Each component gets `kubectl rollout restart` and we wait for `rollout status`; the load keeps running
# a few seconds before and after. The analysis is printed at the end (hack/tests/h43_analyze.py).
set -uo pipefail
COMPS=("$@"); [ ${#COMPS[@]} -eq 0 ] && COMPS=(core registry)
HOST=${HARBOR_HOST:-core.harbor.domain}; AUTH=${HARBOR_AUTH:-admin:Harbor12345}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$W"; cd "$W"
IMG=$HOST/python/hello:1.0
now_ms() { date +%s%3N; }

echo "== precondition"
kubectl get deploy --no-headers | grep -E "harbor-(core|registry)" | awk '{print $1,$2}' | paste -sd';'
echo "load: $(cut -d' ' -f1-3 /proc/loadavg)"
MANIFEST=$(curl -sk -u "$AUTH" -H "Accept: application/vnd.docker.distribution.manifest.v2+json" "https://$HOST/v2/python/hello/manifests/1.0")
BLOB=$(echo "$MANIFEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(max(d['layers'],key=lambda l:l['size'])['digest'])")
echo "blob under test: $BLOB"

: > manifest.log; : > blob.log; : > pull.log; : > events.log
STOP=$W/stop; rm -f "$STOP"

prober() {  # name url interval
  local name=$1 url=$2 iv=$3
  while [ ! -e "$STOP" ]; do
    r=$(curl -sk -u "$AUTH" -o /dev/null -w "%{http_code} %{time_total}" -m 30 "$url" 2>/dev/null); rc=$?
    echo "$(now_ms) ${r:-000 0} rc=$rc" >> "$name.log"
    sleep "$iv"
  done
}
puller() {
  while [ ! -e "$STOP" ]; do
    docker rmi "$IMG" >/dev/null 2>&1
    s=$(now_ms); out=$(docker pull "$IMG" 2>&1); rc=$?
    echo "$s $(now_ms) rc=$rc $(echo "$out" | grep -ciE 'retry|retrying')" >> pull.log
    [ $rc -ne 0 ] && echo "$s FAIL: $(echo "$out" | tail -1)" >> pull-errors.log
  done
}
prober manifest "https://$HOST/v2/python/hello/manifests/1.0" 0.1 &
prober blob "https://$HOST/v2/python/hello/blobs/$BLOB" 0.4 &
puller &
sleep 8
echo "$(now_ms) baseline-end" >> events.log

for c in "${COMPS[@]}"; do
  echo "== rollout restart harbor-$c"
  echo "$(now_ms) start-$c" >> events.log
  kubectl rollout restart "deploy/harbor-$c" >/dev/null
  kubectl rollout status "deploy/harbor-$c" --timeout=300s | tail -1
  echo "$(now_ms) done-$c" >> events.log
  echo "   pods: $(kubectl get pods -l component=$c --no-headers | awk '{print $1":"$2":"$3}' | paste -sd' ')"
  sleep 10
  echo "$(now_ms) settled-$c" >> events.log
done

touch "$STOP"; wait
echo "== analysis"
python3 "$HERE/h43_analyze.py" "$W"
echo "logs in $W"
