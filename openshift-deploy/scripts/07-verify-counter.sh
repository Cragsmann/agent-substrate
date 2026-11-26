#!/usr/bin/env bash
# Creates a counter actor, increments it through the router, suspends it,
# and checks that the next request resumes it with its state intact.
set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/env.sh
source "$(dirname "$0")/env.sh"

ns=ate-demo-counter
actor="${ACTOR:-my-counter-1}"
k="${WORKTREE}/bin/kubectl-ate"

"${k}" get actor "${actor}" -a "${ns}" >/dev/null 2>&1 ||
  "${k}" create actor "${actor}" -a "${ns}" --template counter

proxy_log="$(mktemp -t ate-proxy)"
"${k}" proxy actor "${actor}" -a "${ns}" >"${proxy_log}" 2>&1 &
proxy=$!
trap 'kill "${proxy}" 2>/dev/null || true; rm -f "${proxy_log}"' EXIT
until grep -q '^Proxying' "${proxy_log}" 2>/dev/null; do
  if ! kill -0 "${proxy}" 2>/dev/null; then
    echo "kubectl ate proxy exited:" >&2
    cat "${proxy_log}" >&2
    echo "Is something else on localhost:8000? lsof -nP -iTCP:8000 -sTCP:LISTEN" >&2
    exit 1
  fi
  sleep 1
done

post() { curl -s -m 30 -X POST -w ' [%{http_code} %{time_total}s]\n' http://localhost:8000/; }

echo "== increment"
post; post; post

echo "== suspend"
"${k}" suspend actor "${actor}" -a "${ns}"
"${k}" get actor "${actor}" -a "${ns}"

echo "== resume (counts should continue)"
post; post
"${k}" get actor "${actor}" -a "${ns}"

echo "== worker-side restore timing"
pod="$("${k}" get actor "${actor}" -a "${ns}" | awk 'NR==2{print $5}' | cut -d/ -f2)"
oc logs -n "${ns}" "${pod}" -c worker --since=5m |
  grep '"Restore timing breakdown"' | tail -1 |
  python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print({k.rsplit(".",1)[-1]: round(v*1000,1) for k,v in d.items() if "restore.duration" in k}, "ms")'
