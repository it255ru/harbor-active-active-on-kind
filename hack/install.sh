#!/usr/bin/env bash

set -euo pipefail

CURDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# metallb + ingress-nginx
$CURDIR/install-infra.sh

# harbor
helm repo add harbor https://helm.goharbor.io
helm repo update
helm upgrade -i harbor harbor/harbor --version 1.19.2 -f $CURDIR/config/harbor.yaml
