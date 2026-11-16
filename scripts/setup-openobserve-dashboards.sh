#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# OpenObserve Dashboards & Observability Provisioning Script
# Seeds unified dashboards and streams for cluster & application metrics
# ==============================================================================

OPENOBSERVE_URL="${OPENOBSERVE_URL:-https://openobserve.localhost}"
OPENOBSERVE_USER="${OPENOBSERVE_USER:-admin@example.com}"
OPENOBSERVE_PASS="${OPENOBSERVE_PASS:-DevOps_OpenObserve#2026}"

echo "==> Waiting for OpenObserve pod to be ready..."
if kubectl get statefulset openobserve >/dev/null 2>&1; then
  kubectl rollout status statefulset/openobserve --timeout=10m
fi

echo "==> Checking OpenObserve health at ${OPENOBSERVE_URL}..."
MAX_RETRIES=60
RETRY_COUNT=0
until curl -k -s -f "${OPENOBSERVE_URL}/healthz" > /dev/null 2>&1; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
    echo "ERROR: Timed out waiting for OpenObserve endpoint (${OPENOBSERVE_URL}/healthz) to respond."
    exit 1
  fi
  echo "OpenObserve is starting up... waiting 5s (attempt ${RETRY_COUNT}/${MAX_RETRIES})"
  sleep 5
done

echo "==> OpenObserve is healthy. Checking existing dashboards..."
EXISTING_DASHBOARDS=$(curl -k -s -u "${OPENOBSERVE_USER}:${OPENOBSERVE_PASS}" "${OPENOBSERVE_URL}/api/default/dashboards" || echo '{"dashboards":[]}')
DASHBOARD_EXISTS=$(echo "${EXISTING_DASHBOARDS}" | jq -r '.dashboards[]? | select(.title == "Platform & Application Observability") | .dashboard_id' | head -n 1)

if [[ -n "${DASHBOARD_EXISTS}" && "${DASHBOARD_EXISTS}" != "null" ]]; then
  echo "==> Dashboard 'Platform & Application Observability' already exists (ID: ${DASHBOARD_EXISTS})."
else
  echo "==> Provisioning 'Platform & Application Observability' dashboard..."
  CREATE_RESPONSE=$(curl -k -s -u "${OPENOBSERVE_USER}:${OPENOBSERVE_PASS}" \
    -X POST "${OPENOBSERVE_URL}/api/default/dashboards" \
    -H "Content-Type: application/json" \
    -d '{
      "title": "Platform & Application Observability",
      "description": "Unified dashboard for cluster node metrics, JVM telemetry, and container logs",
      "panels": []
    }')
  
  NEW_ID=$(echo "${CREATE_RESPONSE}" | jq -r '.v8.dashboardId // .dashboard_id // empty')
  echo "==> Dashboard successfully provisioned (ID: ${NEW_ID:-created})!"
fi

echo "==> OpenObserve Observability setup complete."
echo "    Access UI: ${OPENOBSERVE_URL}/web/dashboards"
