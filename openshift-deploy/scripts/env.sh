# shellcheck shell=bash
# Shared settings for the OpenShift deploy scripts. Sourced, not run.
# Override any value by exporting it before running a script.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "${SCRIPTS_DIR}")"
REPO_DIR="$(dirname "${DEPLOY_DIR}")"

# Upstream release whose manifests and ghcr images are installed. The manifests
# must match the image tag, so the scripts work in a worktree of that tag.
ATE_TAG="${ATE_TAG:-v1.0.1}"
ATE_UPSTREAM="${ATE_UPSTREAM:-https://github.com/agent-substrate/substrate.git}"
ATE_IMAGE_REPO="${ATE_IMAGE_REPO:-ghcr.io/agent-substrate/substrate}"
WORKTREE="${WORKTREE:-$(dirname "${REPO_DIR}")/substrate-${ATE_TAG}}"

# Worker image for the counter demo, pinned by digest
# (crane digest ghcr.io/agent-substrate/substrate/ateworker-gvisor:v1.0.1).
WORKER_IMAGE="${WORKER_IMAGE:-${ATE_IMAGE_REPO}/ateworker-gvisor:${ATE_TAG}@sha256:fd0c6a46d6c69d485856171e632906e774594bea9d00011a4d7038be3e084a2a}"

# Plain-HTTP registry for actor images (crane digest registry:3).
REGISTRY_IMAGE="${REGISTRY_IMAGE:-docker.io/library/registry:3@sha256:82f6ff4a7f982960c8aa51617fea3aabc485df6e55cce80d22deb1de36f1bc3c}"

# ate-setup --kind runs `docker info` as a preflight. Nothing in this install
# builds with Docker, so a stub satisfies it when Docker Desktop is not running.
SHIM_DIR="${SHIM_DIR:-/tmp/ate-shim}"

CONTEXT="${CONTEXT:-$(oc config current-context)}"
export NO_DEV_ENV=1

ate_setup() {
  if ! docker info >/dev/null 2>&1; then
    mkdir -p "${SHIM_DIR}"
    printf '#!/bin/sh\nexit 0\n' > "${SHIM_DIR}/docker"
    chmod +x "${SHIM_DIR}/docker"
    PATH="${SHIM_DIR}:${PATH}" "${WORKTREE}/bin/ate-setup" --context "${CONTEXT}" --kind "$@"
  else
    "${WORKTREE}/bin/ate-setup" --context "${CONTEXT}" --kind "$@"
  fi
}
