#!/usr/bin/env bash
# Deploys a plain-HTTP registry named kind-registry in ate-system.
# The kind profile runs atelet with --localhost-registry-replacement=kind-registry:5000,
# so actor images referenced as localhost:5001/... are pulled from this
# Service over HTTP. No CA bundle or registry auth is needed.
set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/env.sh
source "$(dirname "$0")/env.sh"

oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kind-registry
  namespace: ate-system
spec:
  replicas: 1
  selector:
    matchLabels: {app: kind-registry}
  template:
    metadata:
      labels: {app: kind-registry}
    spec:
      containers:
      - name: registry
        image: ${REGISTRY_IMAGE}
        ports:
        - containerPort: 5000
        volumeMounts:
        - {name: data, mountPath: /var/lib/registry}
      volumes:
      - name: data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: kind-registry
  namespace: ate-system
spec:
  selector: {app: kind-registry}
  ports:
  - port: 5000
    targetPort: 5000
EOF
oc rollout status -n ate-system deploy/kind-registry --timeout=180s
