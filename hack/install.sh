#!/usr/bin/env bash

set -euo pipefail

CURDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# metallb + ingress-nginx (Infra LB)
$CURDIR/install-infra.sh

# harbor in HA mode (requires `make ha-deps`)
$CURDIR/install-harbor-ha.sh
