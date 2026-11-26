#!/usr/bin/env bash
# Checks that the logged-in cluster can run Agent Substrate.
# Requires Kubernetes 1.37+ (OCP 5.1+), where ClusterTrustBundle and
# PodCertificateRequest are GA in certificates.k8s.io/v1.
set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/env.sh
source "$(dirname "$0")/env.sh"

echo "context: ${CONTEXT}"
oc whoami --show-server
oc version | tail -2
oc get infrastructure cluster -o jsonpath='platform: {.status.platform}{"\n"}'
oc get nodes -o custom-columns=NAME:.metadata.name,TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type,ARCH:.status.nodeInfo.architecture

missing=0
for r in clustertrustbundles podcertificaterequests; do
  if oc api-resources --api-group=certificates.k8s.io -o name | grep -q "^${r}\."; then
    echo "ok: ${r}"
  else
    echo "MISSING: ${r} (needs Kubernetes 1.37+ / OCP 5.1+)" >&2
    missing=1
  fi
done
exit "${missing}"
