#!/usr/bin/env bash
# Runs every step: cluster check, worktree, OpenShift prep, registry, control
# plane, counter image, counter demo, and the suspend/resume check.
# Stops at the first failing step. Each step is safe to re-run.
set -o errexit -o nounset -o pipefail

dir="$(cd "$(dirname "$0")" && pwd)"
steps=(
  00-check-cluster.sh
  01-prepare-worktree.sh
  02-ocp-prep.sh
  03-registry.sh
  04-deploy-system.sh
  05-build-counter.sh
  06-deploy-counter.sh
  07-verify-counter.sh
)

for step in "${steps[@]}"; do
  printf '\n==== %s ====\n' "${step}"
  start=${SECONDS}
  if ! "${dir}/${step}"; then
    echo "FAILED at ${step}; fix it and re-run, or run the remaining steps one by one" >&2
    exit 1
  fi
  echo "---- ${step} ok ($((SECONDS - start))s)"
done
printf '\nAll steps passed.\n'
