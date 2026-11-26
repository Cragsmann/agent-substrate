#!/usr/bin/env bash
# Deploys the claude-code-multiplex demo: three Claude Code agents sharing a
# two-pod WorkerPool. Needs ANTHROPIC_API_KEY exported and podman running.
# podman-docker/docker builds the workload image in place of docker buildx.
set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/env.sh
source "$(dirname "$0")/env.sh"

: "${ANTHROPIC_API_KEY:?export ANTHROPIC_API_KEY first}"
ns=claude-multiplex-demo
pool=claude-workerpool

cd "${WORKTREE}"
tmpl=demos/claude-code-multiplex/claude-code-multiplex.yaml.tmpl
sed -i.bak "s#workerImage: ko://go.ate.dev/substrate/cmd/ateworker-gvisor#workerImage: ${WORKER_IMAGE}#" "${tmpl}"
rm -f "${tmpl}.bak"

if lsof -nP -iTCP:5001 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "localhost:5001 is already in use; is another deploy still running?" >&2
  lsof -nP -iTCP:5001 -sTCP:LISTEN >&2
  exit 1
fi
# Restarts the port-forward if it drops during the long build and push.
(
  while true; do
    oc port-forward -n ate-system svc/kind-registry 5001:5000 >>/tmp/ate-pf.log 2>&1 || true
    sleep 1
  done
) &
pf=$!
ui=""
stop_pf() {
  pkill -P "${pf}" 2>/dev/null
  kill "${pf}" 2>/dev/null
  pkill -f "port-forward -n ate-system svc/kind-registry 5001:5000" 2>/dev/null || true
}
cleanup() {
  stop_pf
  # go run starts the built binary as a child, so stop both.
  if [[ -n "${ui}" ]]; then
    pkill -P "${ui}" 2>/dev/null
    kill "${ui}" 2>/dev/null || true
  fi
}
trap cleanup EXIT
until curl -sf http://localhost:5001/v2/ >/dev/null; do sleep 1; done

export PATH="${SCRIPTS_DIR}/podman-docker:${PATH}"
# The kind profile ignores KO_DEFAULTPLATFORMS and builds for the host arch,
# so the nodes' platform has to be a flag.
ate_setup --rollout-timeout 600s --ko-default-platforms=linux/amd64 \
  --image-repo "${ATE_IMAGE_REPO}" --image-tag "${ATE_TAG}" \
  deploy demo claude-code-multiplex >/tmp/ate-claude.log 2>&1 &
deploy=$!

until oc get sa ateworker -n "${ns}" >/dev/null 2>&1; do
  kill -0 "${deploy}" 2>/dev/null || break
  sleep 2
done
oc label ns "${ns}" --overwrite \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged >/dev/null
oc adm policy add-scc-to-user ateworker-spc -z ateworker -n "${ns}"

until oc get deploy "${pool}" -n "${ns}" >/dev/null 2>&1; do
  kill -0 "${deploy}" 2>/dev/null || break
  sleep 2
done
oc patch deploy "${pool}" -n "${ns}" --type=strategic -p \
  '{"spec":{"template":{"spec":{"securityContext":{"sysctls":[{"name":"net.ipv4.ip_unprivileged_port_start","value":"0"}]}}}}}'

if ! wait "${deploy}"; then
  echo "deploy demo claude-code-multiplex failed; see /tmp/ate-claude.log" >&2
  tail -20 /tmp/ate-claude.log >&2
  exit 1
fi
oc get workerpools,pods -n "${ns}"
"${WORKTREE}/bin/kubectl-ate" get actors -a "${ns}"
stop_pf

# Dashboard on the first free port from 8091, opened in the browser. It runs
# from this checkout, whose server.go shows only this namespace's workers;
# upstream v1.0.1 also lists other demos' workers and fails to read their logs.
port=8091
while lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1; do
  port=$((port + 1))
done
url="http://localhost:${port}"
(cd "${REPO_DIR}/demos/claude-code-multiplex/ui" && PORT="${port}" go run .) &
ui=$!
until curl -sf "${url}/healthz" >/dev/null 2>&1; do
  if ! kill -0 "${ui}" 2>/dev/null; then
    echo "dashboard exited before it started serving" >&2
    exit 1
  fi
  sleep 1
done
if command -v open >/dev/null; then
  open "${url}"
elif command -v xdg-open >/dev/null; then
  xdg-open "${url}"
fi
echo
echo "Dashboard: ${url}  (click \"Give a task\"; Ctrl-C stops it)"
wait "${ui}"
