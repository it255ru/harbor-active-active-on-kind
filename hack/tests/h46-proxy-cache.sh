#!/usr/bin/env bash
# H4.6 (backlog): proxy-cache project in front of Docker Hub.
#   * a cold pull through Harbor fetches from Docker Hub and caches the image;
#   * with Docker Hub made unreachable, the cached image is still served BY DIGEST, from any replica
#     (core+registry pods are force-deleted one pair at a time), while a never-cached image fails;
#   * local projects keep working next to the proxy project.
#
# usage: hack/tests/h46-proxy-cache.sh
# env:   KEEP=1 keep the proxy project and the registry endpoint afterwards (default: remove them)
#        CACHED (default library/alpine:3.20)  UNCACHED (default library/hello-world:latest)
#        HARBOR_HOST, HARBOR_AUTH, WORKDIR
#
# Findings that shaped this script (H4.6):
#   * What Harbor caches is the resolved PLATFORM manifest and its blobs, addressed by digest. The tag and the
#     multi-arch index are not stored. With the upstream down a pull BY TAG fails ("artifact ...:3.20 not
#     found": tag -> digest needs the upstream); a pull of the cached PLATFORM digest works from any replica.
#     A pull by the INDEX digest can still succeed for a while (a core pod that already holds a keep-alive
#     connection to Docker Hub), so it is only reported (INFO), not asserted.
#   * The cache is registered asynchronously, ~35-40 s after the first pull.
#   * For endpoints of type docker-hub Harbor ignores the URL field, so breaking the URL does not
#     simulate an outage. Here CoreDNS answers NXDOMAIN for docker.io / docker.com (only inside the
#     cluster) and is restarted to drop its cache; the original Corefile is restored on exit.
#   * The project/endpoint names are unique per run (see RUN): leftovers of an earlier project with the same
#     name in S3 make the cache look empty.
#   * Docker Hub rate limits anonymous pulls: a handful of small pulls only.
set -uo pipefail
HOST=${HARBOR_HOST:-core.harbor.domain}; AUTH=${HARBOR_AUTH:-admin:Harbor12345}
HOST_URL=https://$HOST; API=$HOST_URL/api/v2.0; A=(-sk -u "$AUTH")
CACHED=${CACHED:-library/alpine:3.20}; UNCACHED=${UNCACHED:-library/hello-world:latest}
# unique per run: deleting a repository through the API leaves its manifests/blobs in S3, and re-proxying the
# same path later does not create the artifact record again (the cache looks empty although pulls work)
RUN=$(date +%s); PROJ=dockerhub-proxy-$RUN; EP=dockerhub-$RUN
W="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$W"; cd "$W"
ok=0; bad=0
check() { if [ "$1" = ok ]; then ok=$((ok+1)); echo "   PASS  $2"; else bad=$((bad+1)); echo "   FAIL  $2"; fi; }
pull() { docker rmi "$1" >/dev/null 2>&1; timeout 120 docker pull "$1" 2>&1; }
digest_of() { grep -oE "^Digest: sha256:[0-9a-f]{64}" | head -1 | cut -d' ' -f2; }
secs() { echo "$(date +%s.%N) - $1" | bc | cut -c1-5; }
upstream() {  # prints 401 when Docker Hub is fully reachable (registry API and hub.docker.com), else 000
  a=$(kubectl exec deploy/harbor-core -- curl -s -o /dev/null -m 5 -w '%{http_code}' https://registry-1.docker.io/v2/ 2>/dev/null)
  b=$(kubectl exec deploy/harbor-core -- curl -s -o /dev/null -m 5 -w '%{http_code}' https://hub.docker.com 2>/dev/null)
  if [ "$a" = 401 ] && [ "$b" = 200 ]; then echo 401; else echo 000; fi
}
same() { [ -n "$1" ] && [ "$1" = "$2" ]; }   # never treat two empty digests as equal
wait_upstream() {  # want: 401 (reachable) or 000 (unreachable)
  for _ in $(seq 1 40); do r=$(upstream); [ "$r" = "$1" ] && return 0; sleep 3; done; return 1
}
reg_id() { curl "${A[@]}" "$API/registries" | python3 -c "import sys,json; print(next((r['id'] for r in json.load(sys.stdin) if r['name']=='$EP'),''))"; }
repo_names() { curl "${A[@]}" "$API/projects/$PROJ/repositories" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for x in (d if isinstance(d,list) else []): print(x['name'].split('/',1)[1].replace('/','%252F'))" 2>/dev/null; }

# ---- CoreDNS: always restore the original Corefile
COREFILE_ORIG="$W/Corefile.orig"
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' > "$COREFILE_ORIG"
apply_corefile() {
  kubectl -n kube-system create cm coredns --from-file=Corefile="$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  kubectl -n kube-system rollout restart deploy/coredns >/dev/null && kubectl -n kube-system rollout status deploy/coredns --timeout=90s >/dev/null
}
cleanup() {
  apply_corefile "$COREFILE_ORIG"
  if [ "${KEEP:-0}" != 1 ]; then
    echo "== cleanup: remove proxy project and endpoint"
    for r in $(repo_names); do curl "${A[@]}" -o /dev/null -X DELETE "$API/projects/$PROJ/repositories/$r"; done
    echo "   project: $(curl "${A[@]}" -o /dev/null -w '%{http_code}' -X DELETE "$API/projects/$PROJ")"
    RID=$(reg_id); [ -n "$RID" ] && echo "   endpoint: $(curl "${A[@]}" -o /dev/null -w '%{http_code}' -X DELETE "$API/registries/$RID")"
  fi
  for i in "$CACHED" "$UNCACHED"; do docker rmi "$HOST/$PROJ/$i" >/dev/null 2>&1; done
}
trap cleanup EXIT

echo "== 1. endpoint and proxy-cache project"
wait_upstream 401 || { echo "!! Docker Hub is not reachable from the Harbor pods, cannot run"; exit 1; }
echo "   egress from a Harbor pod: $(upstream) (401 = reachable)"
RID=$(reg_id)
if [ -z "$RID" ]; then
  CODE=$(curl "${A[@]}" -o "$W/ep.out" -w '%{http_code}' -X POST "$API/registries" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$EP\",\"type\":\"docker-hub\",\"url\":\"https://hub.docker.com\",\"insecure\":false}")
  RID=$(reg_id)
  [ "$CODE" = 201 ] && [ -n "$RID" ] || { echo "!! cannot create the registry endpoint (HTTP $CODE): $(head -c 200 "$W/ep.out")"; exit 1; }
fi
[ "$(curl "${A[@]}" -o /dev/null -w '%{http_code}' "$API/projects/$PROJ")" = 200 ] || \
  curl "${A[@]}" -o /dev/null -X POST "$API/projects" -H 'Content-Type: application/json' -d "{\"project_name\":\"$PROJ\",\"registry_id\":$RID,\"public\":true}"
check "$([ "$(curl "${A[@]}" "$API/projects/$PROJ" | python3 -c "import sys,json; print(json.load(sys.stdin).get('registry_id'))")" = "$RID" ] && echo ok || echo bad)" "project $PROJ is a proxy-cache project (registry_id=$RID)"

echo "== 2. cold pull of $CACHED through Harbor (fetched from Docker Hub, then cached)"
REF=$HOST/$PROJ/$CACHED; REPO=${CACHED%%:*}; TAGN=${CACHED##*:}; REPOURL=${REPO//\//%252F}
s=$(date +%s.%N); OUT=$(pull "$REF"); D=$(echo "$OUT" | digest_of); echo "   $(secs $s)s  digest $D"
TOKEN=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$REPO:pull" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
UP=$(curl -sI -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" "https://registry-1.docker.io/v2/$REPO/manifests/$TAGN" | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')
check "$(same "$D" "$UP" && echo ok || echo bad)" "digest through Harbor equals the digest on Docker Hub ($UP)"
[ -n "$D" ] || { echo "!! cold pull failed: $(echo "$OUT" | tail -2 | cut -c1-200)"; exit 1; }
t0=$SECONDS; P=""
for _ in $(seq 1 45); do
  P=$(curl "${A[@]}" "$API/projects/$PROJ/repositories/$REPOURL/artifacts?page_size=10" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d[0]['digest'] if isinstance(d,list) and d else '')" 2>/dev/null)
  [ -n "$P" ] && break; sleep 2
done
echo "   cache registered after $((SECONDS-t0)) s of waiting; cached platform manifest: ${P:-none}"
check "$([ -n "$P" ] && echo ok || echo bad)" "the image is cached in the project (asynchronously, ~35-40 s after the pull)"
[ -n "$P" ] || { echo "!! nothing cached, cannot continue"; exit 1; }

echo "== 3. Docker Hub made unreachable (CoreDNS NXDOMAIN for docker.io / docker.com)"
python3 - "$COREFILE_ORIG" "$W/Corefile.block" <<'EOF'
import sys
s = open(sys.argv[1]).read()
block = "    template IN ANY docker.io docker.com {\n        rcode NXDOMAIN\n    }\n"
i = s.index("    forward .")
open(sys.argv[2], "w").write(s[:i] + block + s[i:])
EOF
apply_corefile "$W/Corefile.block"
wait_upstream 000; r=$(upstream)
check "$([ "$r" = 000 ] && echo ok || echo bad)" "Harbor pods can no longer reach Docker Hub (curl -> $r)"

echo "== 4. with the upstream down"
OUT=$(pull "$REF@$D"); D2=$(echo "$OUT" | digest_of); echo "   INFO  by INDEX digest: ${D2:-$(echo "$OUT" | tail -1 | cut -c1-120)}"
OUT=$(pull "$HOST/$PROJ/$REPO@$P"); D2=$(echo "$OUT" | digest_of); echo "   by platform digest: ${D2:-$(echo "$OUT" | tail -1 | cut -c1-140)}"
check "$(same "$D2" "$P" && echo ok || echo bad)" "cached image pulled BY DIGEST (platform manifest) with Docker Hub unreachable"
# docker keeps layers in its own content store after `rmi`, so a fast pull alone does not prove the layer came
# from Harbor's cache: fetch the manifest and the layer straight from Harbor and verify the sha256 ourselves
MJ=$(curl "${A[@]}" -H "Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" "$HOST_URL/v2/$PROJ/$REPO/manifests/$P")
LD=$(echo "$MJ" | python3 -c "import sys,json; print(json.load(sys.stdin)['layers'][0]['digest'])" 2>/dev/null)
GOT=$(curl "${A[@]}" "$HOST_URL/v2/$PROJ/$REPO/blobs/$LD" | sha256sum | cut -d' ' -f1)
check "$([ -n "$LD" ] && [ "sha256:$GOT" = "$LD" ] && echo ok || echo bad)" "layer $LD downloaded through Harbor with the upstream down and its sha256 verifies"
OUT=$(pull "$REF"); echo "   INFO  by tag ($CACHED): $(echo "$OUT" | grep -E '^Digest|rror' | head -1 | cut -c1-150)"
OUT=$(pull "$HOST/$PROJ/$UNCACHED")
echo "   control (never cached, by tag): $(echo "$OUT" | tail -1 | cut -c1-140)"
check "$(echo "$OUT" | grep -q '^Digest' && echo bad || echo ok)" "an image that was never cached cannot be pulled while the upstream is down"

echo "== 5. any replica: kill one core+registry pair, pull the cached platform digest; then the other pair"
for idx in 0 1; do
  C=$(kubectl get pods -l component=core -o name | sed -n "$((idx+1))p"); R=$(kubectl get pods -l component=registry -o name | sed -n "$((idx+1))p")
  echo "   force-delete $C and $R"; kubectl delete $C $R --grace-period=0 --force >/dev/null 2>&1
  OUT=$(pull "$HOST/$PROJ/$REPO@$P"); D3=$(echo "$OUT" | digest_of)
  check "$(same "$D3" "$P" && echo ok || echo bad)" "pull of the cached platform digest with pair #$((idx+1)) down served by the surviving core+registry (${D3:-$(echo "$OUT" | tail -1 | cut -c1-100)})"
  for _ in $(seq 1 60); do
    [ "$(kubectl get deploy harbor-core harbor-registry --no-headers | awk '{print $2}' | grep -c '^2/2$')" = 2 ] && break; sleep 3
  done
done

echo "== 6. local projects next to the proxy project"
OUT=$(pull "$HOST/python/hello:1.0"); DL=$(echo "$OUT" | digest_of)
check "$([ -n "$DL" ] && echo ok || echo bad)" "python/hello:1.0 (local project) pulls fine (digest $DL)"
docker tag "$HOST/python/hello:1.0" "$HOST/$PROJ/library/h46-push-test:1" 2>/dev/null
OUT=$(docker push "$HOST/$PROJ/library/h46-push-test:1" 2>&1); echo "   $(echo "$OUT" | tail -1 | cut -c1-160)"
check "$(echo "$OUT" | grep -q 'digest:' && echo bad || echo ok)" "pushing into the proxy-cache project is rejected"
docker rmi "$HOST/$PROJ/library/h46-push-test:1" >/dev/null 2>&1

echo "== 7. upstream back: the never-cached image and the tag pull work again"
apply_corefile "$COREFILE_ORIG"; wait_upstream 401; echo "   Docker Hub reachable again: $(upstream)"
OUT=$(pull "$HOST/$PROJ/$UNCACHED"); D4=$(echo "$OUT" | digest_of)
check "$([ -n "$D4" ] && echo ok || echo bad)" "never-cached image pulls once Docker Hub is reachable (digest $D4)"
OUT=$(pull "$REF"); D5=$(echo "$OUT" | digest_of)
check "$(same "$D5" "$D" && echo ok || echo bad)" "pull by tag works again ($D5)"

echo "== result: $ok passed, $bad failed"
[ "$bad" = 0 ]
