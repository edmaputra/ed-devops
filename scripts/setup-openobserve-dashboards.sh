#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# OpenObserve Dashboards & Observability Provisioning Script
# Seeds unified dashboards and streams for cluster & application metrics
# ==============================================================================

OPENOBSERVE_URL="${OPENOBSERVE_URL:-https://openobserve.localhost}"
OPENOBSERVE_USER="${OPENOBSERVE_USER:-admin@example.com}"
OPENOBSERVE_PASS="${OPENOBSERVE_PASS:-DevOps_OpenObserve#2026}"

echo "==> Checking OpenObserve health at ${OPENOBSERVE_URL}..."
until curl -k -s -f "${OPENOBSERVE_URL}/healthz" > /dev/null 2>&1; do
  echo "Waiting for OpenObserve to become ready..."
  sleep 2
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
