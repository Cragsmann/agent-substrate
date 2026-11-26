#!/usr/bin/env bash
# Installs the Agent Substrate control plane from the ghcr release images.
# --kind selects the kind manifests (rustfs S3 snapshots, no GKE dependencies);
# it does not require the cluster to be kind.
set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/env.sh
source "$(dirname "$0")/env.sh"

cd "${WORKTREE}"
ate_setup --rollout-timeout 300s deploy ate-system \
  --sandbox-classes=gvisor \
  --storage-bucket-name=ate-snapshots \
  --image-repo "${ATE_IMAGE_REPO}" --image-tag "${ATE_TAG}" \
  --credential-provider='{"name":"k8s.io"}' \
  --ingress-allowed-spiffe-ids=spiffe://cluster.local/ns/ate-system/sa/atenet-client \
  2>&1 | tee /tmp/ate-deploy.log

oc get pods -n ate-system
