#!/usr/bin/env bash
# Builds the counter demo image with ko, pushes it to kind-registry through a
# port-forward, and pins the demo templates to it and to the ghcr worker image.
# Demo images are not published to ghcr, so this replaces ko:// resolution.
set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/env.sh
source "$(dirname "$0")/env.sh"

cd "${WORKTREE}"
oc port-forward -n ate-system svc/kind-registry 5001:5000 >/tmp/ate-pf.log 2>&1 &
pf=$!
trap 'kill "${pf}" 2>/dev/null || true' EXIT
until curl -sf http://localhost:5001/v2/ >/dev/null; do sleep 1; done

ref="$(KO_DOCKER_REPO=localhost:5001 go run github.com/google/ko@v0.18.0 \
  build --platform linux/amd64 -B ./demos/counter)"
echo "counter image: ${ref}"

cd demos/counter
sed -i.bak "s#image: ko://go.ate.dev/substrate/demos/counter#image: ${ref}#; s#image: localhost:5001/counter@sha256:[0-9a-f]*#image: ${ref}#" \
  counter-template.yaml.tmpl
sed -i.bak "s#workerImage: ko://go.ate.dev/substrate/cmd/ateworker-gvisor#workerImage: ${WORKER_IMAGE}#" \
  counter.yaml.tmpl
rm -f ./*.bak
grep -n "image:" counter-template.yaml.tmpl counter.yaml.tmpl
