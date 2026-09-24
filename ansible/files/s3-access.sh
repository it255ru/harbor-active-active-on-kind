#!/usr/bin/env bash
# V8.2: the Harbor S3 key reads/writes registry-blobs and cannot create other buckets.
# Runs the aws CLI against Garage through a temporary port-forward with an isolated config (never touches ~/.aws).
# usage: s3-access.sh <kube-context> <namespace>; prints one line: "rw=<ok|fail> other=<denied|allowed|?>"
set -u
CTX=$1; NS=$2; PORT=${S3_LOCAL_PORT:-13900}
T=$(mktemp -d); PF=""
cleanup() { [ -n "$PF" ] && kill "$PF" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
kubectl --context "$CTX" -n "$NS" port-forward svc/s3 "$PORT":3900 >/dev/null 2>&1 & PF=$!
printf '[default]\nregion = us-east-1\n' > "$T/cfg"; echo probe > "$T/p"
export AWS_CONFIG_FILE=$T/cfg AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_ENDPOINT_URL=http://127.0.0.1:$PORT
AWS_ACCESS_KEY_ID=$(kubectl --context "$CTX" -n "$NS" get secret s3-credentials -o jsonpath='{.data.harbor-access-key}' | base64 -d)
AWS_SECRET_ACCESS_KEY=$(kubectl --context "$CTX" -n "$NS" get secret s3-credentials -o jsonpath='{.data.harbor-secret-key}' | base64 -d)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
for _ in $(seq 20); do (echo > /dev/tcp/127.0.0.1/"$PORT") 2>/dev/null && break; sleep 0.5; done
KEY=v82-$(date +%s)
rw=fail; other='?'
if aws --only-show-errors s3 cp "$T/p" "s3://registry-blobs/$KEY" \
   && [ "$(aws --only-show-errors s3 cp "s3://registry-blobs/$KEY" -)" = probe ]; then rw=ok; fi
aws --only-show-errors s3 rm "s3://registry-blobs/$KEY" >/dev/null 2>&1
out=$(aws s3api create-bucket --bucket v82-other 2>&1)
if echo "$out" | grep -q AccessDenied; then other=denied; elif [ -z "$out" ] || echo "$out" | grep -q Location; then other=allowed; aws s3api delete-bucket --bucket v82-other >/dev/null 2>&1; fi
echo "rw=$rw other=$other"
