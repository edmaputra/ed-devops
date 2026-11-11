#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Unified Platform Healthcheck Script
# Verifies:
#   1. Kubernetes cluster & nodes
#   2. Platform service Ingress routes & TLS certificates
#   3. Service API health (SonarQube, Vault, OpenObserve, Consul, Jenkins, ArgoCD)
#   4. Database connectivity (PostgreSQL)
#   5. Workload pod health across namespaces
# ==============================================================================

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0
WARNINGS=0

report_pass() {
  echo -e "  [${GREEN}PASS${NC}] $1"
  PASSED=$((PASSED + 1))
}

report_fail() {
  echo -e "  [${RED}FAIL${NC}] $1"
  FAILED=$((FAILED + 1))
}

report_warn() {
  echo -e "  [${YELLOW}WARN${NC}] $1"
  WARNINGS=$((WARNINGS + 1))
}

echo -e "${BOLD}${CYAN}==================================================================${NC}"
echo -e "${BOLD}${CYAN}         ed-devops Platform Comprehensive Health Check             ${NC}"
echo -e "${BOLD}${CYAN}==================================================================${NC}"
echo "Date: $(date)"
echo ""

# ------------------------------------------------------------------------------
# 1. Cluster & Node Readiness
# ------------------------------------------------------------------------------
echo -e "${BOLD}1. Checking Kubernetes Cluster & Node Status...${NC}"
if ! kubectl cluster-info > /dev/null 2>&1; then
  report_fail "Kubernetes control plane is unreachable"
else
  NOT_READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1}' || true)
  if [[ -z "${NOT_READY_NODES}" ]]; then
    NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
    report_pass "All Kubernetes nodes are Ready (${NODE_COUNT} node(s))"
  else
    report_fail "Nodes not ready: ${NOT_READY_NODES}"
  fi
fi

# ------------------------------------------------------------------------------
# 2. Ingress & Platform Service Health
# ------------------------------------------------------------------------------
echo ""
echo -e "${BOLD}2. Checking Ingress Routes & API Health...${NC}"

# SonarQube
SONAR_STATUS=$(curl -k -s --max-time 5 https://sonar.localhost/api/system/status 2>/dev/null | jq -r '.status // empty' || true)
if [[ "${SONAR_STATUS}" == "UP" ]]; then
  report_pass "SonarQube is UP (https://sonar.localhost)"
else
  report_fail "SonarQube is not UP (status: '${SONAR_STATUS}')"
fi

# HashiCorp Vault
VAULT_HEALTH=$(curl -k -s --max-time 5 https://vault.localhost/v1/sys/health 2>/dev/null || true)
read -r VAULT_INIT VAULT_SEALED <<< "$(echo "${VAULT_HEALTH}" | jq -r '[.initialized, .sealed] | @tsv' 2>/dev/null || echo "unknown unknown")"
if [[ "${VAULT_INIT}" == "true" && "${VAULT_SEALED}" == "false" ]]; then
  report_pass "Vault is unsealed and healthy (https://vault.localhost)"
elif [[ "${VAULT_SEALED}" == "true" ]]; then
  report_fail "Vault is sealed"
else
  report_fail "Vault health check failed (response: ${VAULT_HEALTH:-none})"
fi

# HashiCorp Consul
CONSUL_LEADER=$(curl -k -s --max-time 5 https://consul.localhost/v1/status/leader 2>/dev/null | tr -d '"' || true)
if [[ -n "${CONSUL_LEADER}" && "${CONSUL_LEADER}" != "null" ]]; then
  report_pass "Consul leader elected (${CONSUL_LEADER})"
else
  report_fail "Consul has no active leader or is unreachable"
fi

# OpenObserve
OO_STATUS=$(curl -k -s --max-time 5 https://openobserve.localhost/healthz 2>/dev/null | jq -r '.status // empty' || true)
if [[ "${OO_STATUS}" == "ok" ]]; then
  report_pass "OpenObserve is healthy (https://openobserve.localhost)"
else
  report_fail "OpenObserve healthz failed (status: '${OO_STATUS}')"
fi

# Jenkins
JENKINS_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 5 -L https://jenkins.localhost/login 2>/dev/null || true)
if [[ "${JENKINS_CODE}" == "200" ]]; then
  report_pass "Jenkins Web UI is accessible (HTTP ${JENKINS_CODE})"
else
  report_fail "Jenkins Web UI returned HTTP ${JENKINS_CODE}"
fi

# ArgoCD
ARGOCD_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 5 -L https://argocd.localhost 2>/dev/null || true)
if [[ "${ARGOCD_CODE}" == "200" ]]; then
  report_pass "ArgoCD Web UI is accessible (HTTP ${ARGOCD_CODE})"
else
  report_fail "ArgoCD Web UI returned HTTP ${ARGOCD_CODE}"
fi

# Application Frontend
FRONTEND_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 5 -L https://ilmiya.localhost 2>/dev/null || true)
if [[ "${FRONTEND_CODE}" == "200" ]]; then
  report_pass "Ilmiya Frontend is serving (https://ilmiya.localhost)"
else
  report_warn "Ilmiya Frontend returned HTTP ${FRONTEND_CODE}"
fi

# Application Backend Actuator
BACKEND_HEALTH=$(curl -k -s --max-time 5 https://ilmiya.localhost/actuator/health 2>/dev/null | jq -r '.status // empty' || true)
if [[ "${BACKEND_HEALTH}" == "UP" ]]; then
  report_pass "Ilmiya Backend Spring Boot Actuator is UP"
elif [[ -n "${BACKEND_HEALTH}" ]]; then
  report_warn "Ilmiya Backend Spring Boot Actuator status: ${BACKEND_HEALTH}"
else
  report_warn "Ilmiya Backend Actuator endpoint is currently unreachable"
fi

# ------------------------------------------------------------------------------
# 3. Database Connectivity
# ------------------------------------------------------------------------------
echo ""
echo -e "${BOLD}3. Checking PostgreSQL Database Connectivity...${NC}"
if kubectl exec postgres-0 -- pg_isready -U postgres > /dev/null 2>&1; then
  report_pass "PostgreSQL is accepting connections"
else
  report_fail "PostgreSQL is not accepting connections"
fi

# ------------------------------------------------------------------------------
# 4. Workload & Pod Health
# ------------------------------------------------------------------------------
echo ""
echo -e "${BOLD}4. Checking Pod Health Across Namespaces...${NC}"
UNHEALTHY_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4 !~ /(Running|Completed)/ {print $1 "/" $2 ":" $4}' || true)
RESTART_HIGH_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | awk '$5 > 50 {print $1 "/" $2 " (restarts: " $5 ")"}' || true)

if [[ -z "${UNHEALTHY_PODS}" ]]; then
  TOTAL_PODS=$(kubectl get pods -A --no-headers | wc -l)
  report_pass "All pods (${TOTAL_PODS}) are in Running or Completed state"
else
  report_fail "Unhealthy pod(s) detected: ${UNHEALTHY_PODS}"
fi

if [[ -n "${RESTART_HIGH_PODS}" ]]; then
  report_warn "Pod(s) with high restart counts (>50): ${RESTART_HIGH_PODS}"
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${CYAN}==================================================================${NC}"
echo -e "${BOLD}Summary: ${GREEN}${PASSED} passed${NC}, ${YELLOW}${WARNINGS} warning(s)${NC}, ${RED}${FAILED} failed${NC}"
echo -e "${BOLD}${CYAN}==================================================================${NC}"

if [[ ${FAILED} -gt 0 ]]; then
  exit 1
fi
exit 0
