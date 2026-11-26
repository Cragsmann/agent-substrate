#!/usr/bin/env bash
# Deploys the counter demo. ate-setup recreates the ate-demo-counter namespace,
# so while it runs this labels the namespace privileged, binds ateworker-spc to
# the ateworker SA, and adds the low-port sysctl to the worker Deployment.
set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/env.sh
source "$(dirname "$0")/env.sh"

ns=ate-demo-counter
cd "${WORKTREE}"

ate_setup --rollout-timeout 300s \
  --image-repo "${ATE_IMAGE_REPO}" --image-tag "${ATE_TAG}" \
  deploy demo counter >/tmp/ate-demo.log 2>&1 &
deploy=$!

until oc get sa ateworker -n "${ns}" >/dev/null 2>&1; do sleep 2; done
oc label ns "${ns}" --overwrite \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged >/dev/null
oc adm policy add-scc-to-user ateworker-spc -z ateworker -n "${ns}"

until oc get deploy counter -n "${ns}" >/dev/null 2>&1; do sleep 2; done
oc patch deploy counter -n "${ns}" --type=strategic -p \
  '{"spec":{"template":{"spec":{"securityContext":{"sysctls":[{"name":"net.ipv4.ip_unprivileged_port_start","value":"0"}]}}}}}'

if wait "${deploy}"; then
  echo "deploy demo counter: ok"
else
  echo "deploy demo counter failed; see /tmp/ate-demo.log" >&2
  tail -20 /tmp/ate-demo.log >&2
  exit 1
fi
oc get workerpools,pods -n "${ns}"
