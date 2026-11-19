#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Autonomous Storage & Woodpecker Build Cleanup Script
# Prunes:
#   1. Unused & dangling Podman / Docker container images
#   2. Orphaned / unattached storage volumes
#   3. Stopped containers
#   4. Unused containerd images inside k3d cluster node
# ==============================================================================

WOODPECKER_URL="${WOODPECKER_URL:-https://woodpecker.localhost}"
IMAGE_RETENTION="${IMAGE_RETENTION:-72h}"

echo "=================================================================="
echo " Starting Autonomous Storage & Build Cleanup"
echo " Date: $(date)"
echo " Retention Policy:"
echo "   - Container Image Age : Prune unused older than ${IMAGE_RETENTION}"
echo "=================================================================="

# ------------------------------------------------------------------------------
# 1. Prune Host Podman / Docker Images & Volumes
# ------------------------------------------------------------------------------
echo ""
echo "==> [1/3] Pruning Host container engine unused images, volumes, and stopped containers..."
if command -v podman > /dev/null 2>&1; then
  echo "-> Pruning stopped containers..."
  podman container prune --force || true

  echo "-> Pruning dangling & unused images older than ${IMAGE_RETENTION}..."
  podman image prune -a --force --filter "until=${IMAGE_RETENTION}" || true

  echo "-> Pruning dangling storage volumes..."
  podman volume prune --force || true
elif command -v docker > /dev/null 2>&1; then
  echo "-> Pruning stopped containers..."
  docker container prune --force || true

  echo "-> Pruning dangling & unused images older than ${IMAGE_RETENTION}..."
  docker image prune -a --force --filter "until=${IMAGE_RETENTION}" || true

  echo "-> Pruning dangling storage volumes..."
  docker volume prune --force || true
fi

# ------------------------------------------------------------------------------
# 2. Prune k3d Cluster Node containerd Images
# ------------------------------------------------------------------------------
echo ""
echo "==> [2/3] Pruning unused CRI containerd images inside k3d cluster node..."
if podman ps --format '{{.Names}}' 2>/dev/null | grep -q "k3d-dev-cluster-server-0"; then
  podman exec k3d-dev-cluster-server-0 crictl rmi --prune || true
elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "k3d-dev-cluster-server-0"; then
  docker exec k3d-dev-cluster-server-0 crictl rmi --prune || true
else
  echo "k3d-dev-cluster-server-0 container not running. Skipping CRI prune."
fi

# ------------------------------------------------------------------------------
# 3. Storage Usage Report
# ------------------------------------------------------------------------------
echo ""
echo "=================================================================="
echo "==> [3/3] Storage Cleanup Summary"
echo "=================================================================="
if command -v podman > /dev/null 2>&1; then
  echo "--- Podman System Storage ---"
  podman system df || true
elif command -v docker > /dev/null 2>&1; then
  echo "--- Docker System Storage ---"
  docker system df || true
fi

echo ""
echo "--- Host Filesystem Storage ---"
df -h /

echo ""
echo "Cleanup completed successfully!"
