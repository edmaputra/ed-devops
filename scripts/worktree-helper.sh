#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Git Worktree Automation Helper
# Ensures origin/main is fetched and up to date before provisioning a new branch
# Usage:
#   ./scripts/worktree-helper.sh <branch-name> [worktree-path]
# ==============================================================================

BRANCH="${1:-}"

if [[ -z "${BRANCH}" ]]; then
  echo "Error: Branch name required."
  echo "Usage: make worktree BRANCH=<branch-name> [TARGET_DIR=<path>]"
  exit 1
fi

TARGET_DIR="${2:-../${BRANCH}}"

echo "==> Fetching latest changes from origin..."
git fetch origin main

echo "==> Creating worktree at '${TARGET_DIR}' on new branch '${BRANCH}' from origin/main..."
git worktree add -b "${BRANCH}" "${TARGET_DIR}" origin/main

echo "==> Worktree successfully created at: ${TARGET_DIR}"
echo "    Branch: ${BRANCH} (based on origin/main: $(git rev-parse --short origin/main))"
