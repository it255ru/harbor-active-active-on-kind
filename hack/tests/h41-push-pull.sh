#!/usr/bin/env bash
# H4.1 (backlog): push/pull of images and an OCI chart with all replicas up.
#   * two images with random 40 MB layers are pushed IN PARALLEL (multipart uploads to S3, concurrent writes);
#   * after `docker rmi` both are pulled back and the digests must equal the pushed ones;
#   * a pod started from a pushed image (containerd on the node pulls it with the pull secret);
#   * an OCI chart: helm push -> pull (same digest) -> install from OCI -> helm test;
#   * both registry and core replicas took part (log counters).
# Everything created here is removed BY DIGEST/version at the end.
#
# usage: hack/tests/h41-push-pull.sh          env: HARBOR_HOST, HARBOR_AUTH, WORKDIR
set -uo pipefail
HOST=${HARBOR_HOST:-core.harbor.domain}; AUTH=${HARBOR_AUTH:-admin:Harbor12345}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
W="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$W"; cd "$W"
API=https://$HOST/api/v2.0; RUN=$(date +%s)
ok=0; bad=0
check() { if [ "$1" = ok ]; then ok=$((ok+1)); echo "   PASS  $2"; else bad=$((bad+1)); echo "   FAIL  $2"; fi; }
same() { [ -n "$1" ] && [ "$1" = "$2" ]; }
DIGESTS=(); CHART_DIGEST=""
cleanup() {
  for d in "${DIGESTS[@]}"; do curl -sk -o /dev/null -u "$AUTH" -X DELETE "$API/projects/python/repositories/hello/artifacts/$d"; done
  [ -n "$CHART_DIGEST" ] && curl -sk -o /dev/null -u "$AUTH" -X DELETE "$API/projects/python/repositories/hello%252Fhello-kube/artifacts/$CHART_DIGEST"
  for n in a b; do docker rmi "$HOST/python/hello:h41-$RUN-$n" >/dev/null 2>&1; done
  kubectl delete pod "p41-$RUN" --ignore-not-found --wait=false >/dev/null 2>&1
  helm uninstall hello-kube >/dev/null 2>&1; kubectl delete pod hello-kube-test-connection --ignore-not-found >/dev/null 2>&1
}
trap cleanup EXIT

T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "== precondition: $(kubectl get deploy harbor-core harbor-registry --no-headers | awk '{print $1"="$2}' | paste -sd' ') load $(cut -d' ' -f1 /proc/loadavg)"
printf 'FROM %s/python/hello:1.0\nARG N\nRUN dd if=/dev/urandom of=/blob-$N bs=1M count=40 2>/dev/null\n' "$HOST" > Dockerfile
for n in a b; do docker build -q --build-arg N=$n -t "$HOST/python/hello:h41-$RUN-$n" . >/dev/null; done

echo "== 1. two images pushed in parallel"
( docker push "$HOST/python/hello:h41-$RUN-a" > push-a.log 2>&1 ) & ( docker push "$HOST/python/hello:h41-$RUN-b" > push-b.log 2>&1 ) & wait
for n in a b; do DG=$(grep -oE "digest: sha256:[0-9a-f]{64}" push-$n.log | head -1 | cut -d' ' -f2); eval "PUSHED_$n=$DG"; [ -n "$DG" ] && DIGESTS+=("$DG"); done
check "$([ -n "$PUSHED_a" ] && [ -n "$PUSHED_b" ] && [ "$PUSHED_a" != "$PUSHED_b" ] && echo ok || echo bad)" "both pushes finished with distinct digests ($PUSHED_a / $PUSHED_b)"

echo "== 2. pull back after docker rmi"
docker rmi "$HOST/python/hello:h41-$RUN-a" "$HOST/python/hello:h41-$RUN-b" >/dev/null 2>&1
for n in a b; do
  eval "P=\$PUSHED_$n"; GOT=$(docker pull "$HOST/python/hello:h41-$RUN-$n" 2>&1 | grep -E '^Digest' | cut -d' ' -f2)
  check "$(same "$GOT" "$P" && echo ok || echo bad)" "image $n pulled back with the pushed digest"
done

echo "== 3. a pod started from a pushed image (containerd pulls through Harbor)"
kubectl run "p41-$RUN" --image="$HOST/python/hello:h41-$RUN-a" --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}],"imagePullSecrets":[{"name":"harbor"}]}}' >/dev/null
kubectl wait --for=condition=ready "pod/p41-$RUN" --timeout=120s >/dev/null 2>&1
IID=$(kubectl get pod "p41-$RUN" -o jsonpath='{.status.containerStatuses[0].imageID}' 2>/dev/null | sed 's/.*@//')
check "$(same "$IID" "$PUSHED_a" && echo ok || echo bad)" "pod is Ready and runs the pushed digest"

echo "== 4. OCI chart"
curl -sk "$API/systeminfo/getcert" -o ca.crt
echo "${AUTH#*:}" | helm registry login "$HOST" -u "${AUTH%%:*}" --password-stdin --ca-file ca.crt >/dev/null 2>&1
helm package --version 0.1.9 "$ROOT/helm-hello-kube" >/dev/null 2>&1
PUSH=$(helm push --ca-file ca.crt hello-kube-0.1.9.tgz "oci://$HOST/python/hello" 2>&1); CD=$(echo "$PUSH" | grep -oE "sha256:[0-9a-f]{64}" | head -1); CHART_DIGEST=$CD
rm -f hello-kube-0.1.9.tgz; PULL=$(helm pull --ca-file ca.crt "oci://$HOST/python/hello/hello-kube" --version 0.1.9 2>&1); CD2=$(echo "$PULL" | grep -oE "sha256:[0-9a-f]{64}" | head -1)
check "$(same "$CD" "$CD2" && echo ok || echo bad)" "chart pushed and pulled with the same digest ($CD)"
helm install hello-kube --ca-file ca.crt "oci://$HOST/python/hello/hello-kube" --version 0.1.9 >/dev/null 2>&1
kubectl rollout status deploy/hello-kube --timeout=120s >/dev/null 2>&1
check "$(helm test hello-kube 2>&1 | grep -q 'Phase: *Succeeded' && echo ok || echo bad)" "helm install from OCI and helm test succeed"

echo "== 5. both replicas took part since the start of the test"
for c in registry core; do
  for p in $(kubectl get pods -l component=$c -o name); do
    if [ "$c" = registry ]; then n=$(kubectl logs "$p" -c registry --since-time="$T0" | grep -cE 'PUT /v2/|PATCH /v2/'); else n=$(kubectl logs "$p" --since-time="$T0" 2>/dev/null | wc -l); fi
    echo "   $c ${p#pod/}: $n"; eval "cnt_${c}_${p##*-}=$n"
  done
done
R=$(kubectl get pods -l component=registry -o name); a=0; for p in $R; do n=$(kubectl logs "$p" -c registry --since-time="$T0" | grep -cE 'PUT /v2/|PATCH /v2/'); [ "$n" -gt 0 ] && a=$((a+1)); done
check "$([ "$a" = 2 ] && echo ok || echo bad)" "both registry replicas received upload requests"
echo "== S3 store: $(kubectl -n harbor-deps exec garage-0 -- /garage bucket info registry-blobs 2>/dev/null | grep -E '^(Size|Objects)' | paste -sd' ')"
echo "== result: $ok passed, $bad failed"
[ "$bad" = 0 ]
