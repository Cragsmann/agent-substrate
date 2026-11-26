#!/usr/bin/env bash
# Removes the demo, the control plane, and the OpenShift admission grants.
set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/env.sh
source "$(dirname "$0")/env.sh"

cd "${WORKTREE}"
ate_setup delete all || true
oc delete -n ate-system deploy/kind-registry svc/kind-registry --ignore-not-found
oc adm policy remove-scc-from-group anyuid \
  system:serviceaccounts:ate-system system:serviceaccounts:otel-system || true
oc adm policy remove-scc-from-user privileged -z atelet -n ate-system || true
oc delete scc ateworker-spc --ignore-not-found
