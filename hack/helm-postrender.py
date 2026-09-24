#!/usr/bin/env python3
"""Helm post-renderer for the Harbor chart (used by hack/install-harbor-ha.sh).

Adds a `preStop` sleep to the client-facing Harbor Deployments (core, registry, portal).

Why: on a rolling update Kubernetes sends SIGTERM to the old pod at the same time as it removes the
pod from the Service endpoints. kube-proxy and ingress-nginx need a moment to stop routing to it, so
for a few seconds requests reach a pod that is already shutting down: core got `connection refused`
from the terminating registry and answered 502 to the client (H4.3). The chart has
terminationGracePeriodSeconds: 120 but no preStop hook and no value to set one.

The sleep keeps the old pod serving until the routing has caught up. Requires PyYAML on the host.
env: PRESTOP_SECONDS (default 15)
"""
import os
import sys

import yaml

SECONDS = os.environ.get("PRESTOP_SECONDS", "15")
TARGETS = {"harbor-core", "harbor-registry", "harbor-portal"}

docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
for d in docs:
    if d.get("kind") == "Deployment" and d["metadata"]["name"] in TARGETS:
        for c in d["spec"]["template"]["spec"]["containers"]:
            c.setdefault("lifecycle", {})["preStop"] = {
                "exec": {"command": ["sh", "-c", f"sleep {SECONDS}"]}
            }
yaml.safe_dump_all(docs, sys.stdout, sort_keys=False, default_flow_style=False)
