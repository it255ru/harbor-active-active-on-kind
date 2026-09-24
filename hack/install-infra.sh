#!/usr/bin/env bash
# Infra LB: MetalLB + ingress-nginx, both pinned to the `lb` nodes.

set -euo pipefail

CURDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Charts: the archive cached by `make images-save` is preferred, so the build does not depend on the chart repositories.
CHARTS="${IMAGE_CACHE:-$HOME/.cache/harbor-ha}/charts"
if [ -f "$CHARTS/metallb-0.16.1.tgz" ] && [ -f "$CHARTS/ingress-nginx-4.15.1.tgz" ]; then
  METALLB_CHART="$CHARTS/metallb-0.16.1.tgz"; NGINX_CHART="$CHARTS/ingress-nginx-4.15.1.tgz"
else
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm repo add metallb https://metallb.github.io/metallb
  helm repo update
  METALLB_CHART=metallb/metallb; NGINX_CHART=ingress-nginx/ingress-nginx
fi

# metallb
helm upgrade -i metallb $METALLB_CHART --version 0.16.1 -f $CURDIR/config/metallb.yaml
kubectl wait --for=condition=ready pod --selector=app.kubernetes.io/name=metallb --timeout=180s
kubectl apply -f $CURDIR/config/lb-ipaddresspool.yaml

# nginx
helm upgrade -i ingress-nginx $NGINX_CHART --version 4.15.1 -f $CURDIR/config/nginx.yaml
kubectl wait --for=condition=ready pod --selector=app.kubernetes.io/name=ingress-nginx --timeout=120s
