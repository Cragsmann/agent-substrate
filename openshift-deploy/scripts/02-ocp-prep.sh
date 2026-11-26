#!/usr/bin/env bash
# Admission prep for Agent Substrate on OpenShift. Demo/dev clusters only:
# grants anyuid to every SA in ate-system and otel-system, privileged to
# atelet, and creates ateworker-spc (privileged with forced spc_t) for workers.
set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/env.sh
source "$(dirname "$0")/env.sh"

for ns in ate-system otel-system podcertificate-controller-system; do
  oc create ns "${ns}" --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc label ns "${ns}" --overwrite \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged >/dev/null
done

# postgres (UID 70), rustfs (10001), envoy/atenet (65532), prometheus (65534)
# pin UIDs that restricted-v2 rejects.
oc adm policy add-scc-to-group anyuid \
  system:serviceaccounts:ate-system system:serviceaccounts:otel-system
# atelet: root, hostPaths, extra capabilities.
oc adm policy add-scc-to-user privileged -z atelet -n ate-system

# Workers: the WorkerPool template exposes no securityContext, so this SCC
# injects spc_t. scripts/06 binds it in each demo namespace.
oc get scc privileged -o json | python3 -c '
import json, sys
scc = json.load(sys.stdin)
scc["metadata"] = {"name": "ateworker-spc"}
scc["seLinuxContext"] = {"type": "MustRunAs", "seLinuxOptions": {"type": "spc_t"}}
scc["users"] = []
scc["groups"] = []
json.dump(scc, sys.stdout)' | oc apply -f -
