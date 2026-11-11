#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Autonomous Storage & Jenkins Build Cleanup Script
# Prunes:
#   1. Older Jenkins build records & artifacts beyond retention threshold
#   2. Unused & dangling Podman / Docker images
#   3. Orphaned / unattached storage volumes
#   4. Stopped containers
#   5. Unused containerd images inside k3d cluster node
# ==============================================================================

JENKINS_URL="${JENKINS_URL:-https://jenkins.localhost}"
JENKINS_USER="${JENKINS_USER:-admin}"
JENKINS_PASS="${JENKINS_PASS:-admin123}"
DAYS_TO_KEEP="${DAYS_TO_KEEP:-2}"
MAX_BUILDS_TO_KEEP="${MAX_BUILDS_TO_KEEP:-10}"
IMAGE_RETENTION="${IMAGE_RETENTION:-72h}"

echo "=================================================================="
echo " Starting Autonomous Storage & Build Cleanup"
echo " Date: $(date)"
echo " Retention Policy:"
echo "   - Jenkins Builds to Keep : ${MAX_BUILDS_TO_KEEP} per job (Max Age: ${DAYS_TO_KEEP} days)"
echo "   - Container Image Age    : Prune unused older than ${IMAGE_RETENTION}"
echo "=================================================================="

# ------------------------------------------------------------------------------
# 1. Jenkins Build Discarding & Cleanup
# ------------------------------------------------------------------------------
if curl -k -s -f -u "${JENKINS_USER}:${JENKINS_PASS}" "${JENKINS_URL}/api/json" > /dev/null 2>&1; then
  echo ""
  echo "==> [1/4] Jenkins is accessible. Cleaning older builds..."
  COOKIE_JAR=$(mktemp)
  trap 'rm -f "${COOKIE_JAR}"' EXIT

  CRUMB_JSON=$(curl -k -s -c "${COOKIE_JAR}" -u "${JENKINS_USER}:${JENKINS_PASS}" "${JENKINS_URL}/crumbIssuer/api/json" || echo "{}")
  CRUMB=$(echo "${CRUMB_JSON}" | jq -r '.crumb // empty')
  CRUMB_FIELD=$(echo "${CRUMB_JSON}" | jq -r '.crumbRequestField // empty')

  CRUMB_HEADER=()
  if [[ -n "${CRUMB}" && -n "${CRUMB_FIELD}" ]]; then
    CRUMB_HEADER=(-H "${CRUMB_FIELD}: ${CRUMB}")
  fi

  GROOVY_SCRIPT="
int maxKeep = Integer.parseInt('${MAX_BUILDS_TO_KEEP}')
int daysKeep = Integer.parseInt('${DAYS_TO_KEEP}')
long now = System.currentTimeMillis()
long maxAgeMs = daysKeep * 24L * 60L * 60L * 1000L

int totalDeleted = 0
jenkins.model.Jenkins.get().getAllItems(hudson.model.Job.class).each { job ->
    def builds = job.getBuilds()
    int kept = 0
    int jobDeleted = 0
    builds.each { build ->
        boolean shouldDelete = false
        if (kept >= maxKeep) {
            shouldDelete = true
        } else if (daysKeep > 0 && (now - build.getTimeInMillis()) > maxAgeMs) {
            shouldDelete = true
        }
        
        if (shouldDelete) {
            try {
                println '[PRUNED] ' + job.name + ' #' + build.number
                build.delete()
                jobDeleted++
                totalDeleted++
            } catch (Exception e) {
                println '[ERROR] Failed deleting ' + job.name + ' #' + build.number + ': ' + e.message
            }
        } else {
            kept++
        }
    }
    println '--> ' + job.name + ': ' + jobDeleted + ' builds deleted, ' + kept + ' kept.'
}
println 'TOTAL_BUILDS_PRUNED=' + totalDeleted
"

  curl -k -s -X POST -b "${COOKIE_JAR}" \
    -u "${JENKINS_USER}:${JENKINS_PASS}" \
    "${CRUMB_HEADER[@]}" \
    --data-urlencode "script=${GROOVY_SCRIPT}" \
    "${JENKINS_URL}/scriptText"
else
  echo "==> [1/4] Jenkins is not running or not accessible at ${JENKINS_URL}. Skipping build pruning."
fi

# ------------------------------------------------------------------------------
# 2. Prune Host Podman / Docker Images & Volumes
# ------------------------------------------------------------------------------
echo ""
echo "==> [2/4] Pruning Host Podman unused images, volumes, and stopped containers..."
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
# 3. Prune k3d Cluster Node containerd Images
# ------------------------------------------------------------------------------
echo ""
echo "==> [3/4] Pruning unused CRI containerd images inside k3d cluster node..."
if podman ps --format '{{.Names}}' 2>/dev/null | grep -q "k3d-dev-cluster-server-0"; then
  podman exec k3d-dev-cluster-server-0 crictl rmi --prune || true
elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "k3d-dev-cluster-server-0"; then
  docker exec k3d-dev-cluster-server-0 crictl rmi --prune || true
else
  echo "k3d-dev-cluster-server-0 container not running. Skipping CRI prune."
fi

# ------------------------------------------------------------------------------
# 4. Storage Usage Report
# ------------------------------------------------------------------------------
echo ""
echo "=================================================================="
echo "==> [4/4] Storage Cleanup Summary"
echo "=================================================================="
if command -v podman > /dev/null 2>&1; then
  echo "--- Podman System Storage ---"
  podman system df || true
fi

echo ""
echo "--- Host Filesystem Storage ---"
df -h /

echo ""
echo "Cleanup completed successfully!"
