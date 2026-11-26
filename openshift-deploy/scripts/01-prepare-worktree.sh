#!/usr/bin/env bash
# Creates a worktree of the upstream release, builds ate-setup and kubectl-ate,
# and applies the OpenShift manifest patch (atelet spc_t, api-server sysctl).
set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/env.sh
source "$(dirname "$0")/env.sh"

if [[ ! -d "${WORKTREE}" ]]; then
  git -C "${REPO_DIR}" fetch -q "${ATE_UPSTREAM}" "refs/tags/${ATE_TAG}:refs/tags/${ATE_TAG}"
  git -C "${REPO_DIR}" worktree add -q "${WORKTREE}" "${ATE_TAG}"
fi

cd "${WORKTREE}"
if git apply --check "${DEPLOY_DIR}/manifests.patch" 2>/dev/null; then
  git apply "${DEPLOY_DIR}/manifests.patch"
  echo "applied manifests.patch"
else
  echo "manifests.patch already applied (or does not apply); skipping"
fi

go build -o bin/ate-setup ./cmd/ate-setup
go build -o bin/kubectl-ate ./cmd/kubectl-ate
echo "built ${WORKTREE}/bin/{ate-setup,kubectl-ate}"
