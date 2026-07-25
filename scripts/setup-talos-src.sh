#!/bin/bash
# Clone the Talos source fork to the target directory.
# Usage: ./scripts/setup-talos-src.sh [target_dir]
#
# Defaults to $TALOS_SRC_DIR or ~/talos-src-v1.13.7.
# Idempotent: if the dir exists with the right branch, no-op.

set -eou pipefail

TALOS_SRC_DIR="${1:-${TALOS_SRC_DIR:-$HOME/talos-src-v1.13.7}}"
BRANCH="${TALOS_BRANCH:-v1.13.7-rk3528}"
FORK_URL="${TALOS_FORK_URL:-https://github.com/nhz-io/sidero-talos.git}"

if [ -d "${TALOS_SRC_DIR}/.git" ]; then
  # Verify it's our fork; if not, abort rather than clobber.
  remote_url=$(git -C "${TALOS_SRC_DIR}" remote get-url origin 2>/dev/null || echo "")
  if [[ "${remote_url}" != *"nhz-io/sidero-talos"* && "${remote_url}" != *"siderolabs/talos"* ]]; then
    echo "ERROR: ${TALOS_SRC_DIR} exists but is not our talos fork (remote: ${remote_url})"
    exit 1
  fi
  # Check out the branch if needed
  current=$(git -C "${TALOS_SRC_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ "${current}" != "${BRANCH}" ]; then
    git -C "${TALOS_SRC_DIR}" fetch origin "${BRANCH}" 2>&1 | tail -2
    git -C "${TALOS_SRC_DIR}" checkout "${BRANCH}" 2>&1 | tail -2
  fi
  echo "Talos source already set up at ${TALOS_SRC_DIR} (branch ${BRANCH})"
else
  echo "Cloning talos fork ${FORK_URL} (branch ${BRANCH}) to ${TALOS_SRC_DIR}"
  git clone --branch "${BRANCH}" --depth 1 "${FORK_URL}" "${TALOS_SRC_DIR}"
fi
