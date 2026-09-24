#!/usr/bin/env bash
# Idempotent initialisation of the Garage S3 stand-in (run by `make s3` after the StatefulSet is up):
#   1. cluster layout: one node, zone dc1, capacity 8G (the PVC is 10Gi);
#   2. bucket registry-blobs;
#   3. access key `harbor` with the ID/secret from Secret s3-credentials, allowed on that bucket only.
# The image has no shell, so every step is `kubectl exec garage-0 -- /garage ...`.
set -euo pipefail

NS=harbor-deps; POD=garage-0; BUCKET=registry-blobs; KEYNAME=harbor
sec() { kubectl -n "$NS" get secret s3-credentials -o "jsonpath={.data.$1}" | base64 -d; }
# garage logs to stderr; keep stdout for parsing, show stderr only on failure
g() { kubectl -n "$NS" exec "$POD" -- /garage "$@" 2>"$TMP_ERR" || { cat "$TMP_ERR" >&2; return 1; }; }
TMP_ERR="$(mktemp)"; trap 'rm -f "$TMP_ERR"' EXIT

kubectl -n "$NS" wait --for=condition=ready "pod/$POD" --timeout=180s >/dev/null

echo "==> layout"
NODE_ID="$(g node id -q | cut -d@ -f1)"
if g status | grep -q "NO ROLE ASSIGNED"; then
  g layout assign -z dc1 -c 8G "$NODE_ID" >/dev/null
  g layout apply --version 1 >/dev/null
  echo "    layout applied for node ${NODE_ID:0:16}"
else
  echo "    layout already applied"
fi

echo "==> bucket $BUCKET"
if g bucket info "$BUCKET" >/dev/null 2>&1; then echo "    exists"; else g bucket create "$BUCKET" >/dev/null; echo "    created"; fi

echo "==> access key $KEYNAME"
if g key info "$KEYNAME" >/dev/null 2>&1; then
  echo "    exists"
else
  g key import --yes -n "$KEYNAME" "$(sec harbor-access-key)" "$(sec harbor-secret-key)" >/dev/null
  echo "    imported"
fi
g bucket allow --read --write --owner "$BUCKET" --key "$KEYNAME" >/dev/null
echo "    $KEYNAME may read/write/own $BUCKET only"
g bucket info "$BUCKET" | grep -E "^(Size|Objects)" | sed 's/^/    /'
