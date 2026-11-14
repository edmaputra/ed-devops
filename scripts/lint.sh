#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Platform Static Analysis and Linting Script
# Verifies:
#   1. Bash script syntax (bash -n)
#   2. Helm charts linting (helm lint)
#   3. YAML syntax validation across helm/ and manifests/
#   4. Kubernetes manifest client-side validation (kubectl dry-run)
# ==============================================================================

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASSED=0
FAILED=0

report_pass() {
  echo -e "  [${GREEN}PASS${NC}] $1"
  PASSED=$((PASSED + 1))
}

report_fail() {
  echo -e "  [${RED}FAIL${NC}] $1"
  FAILED=$((FAILED + 1))
}

echo -e "${BOLD}${CYAN}==================================================================${NC}"
echo -e "${BOLD}${CYAN}             ed-devops Platform Static Analysis & Lint            ${NC}"
echo -e "${BOLD}${CYAN}==================================================================${NC}"
echo "Date: $(date)"
echo ""

# ------------------------------------------------------------------------------
# 1. Shell Script Syntax Check
# ------------------------------------------------------------------------------
echo -e "${BOLD}1. Validating Shell Scripts (bash -n)...${NC}"
SHELL_ERRORS=0
for script in scripts/*.sh; do
  if [[ -f "${script}" ]]; then
    if bash -n "${script}" > /dev/null 2>&1; then
      report_pass "${script} syntax OK"
    else
      report_fail "${script} has syntax errors"
      SHELL_ERRORS=$((SHELL_ERRORS + 1))
    fi
  fi
done

# ------------------------------------------------------------------------------
# 2. Helm Chart Linting
# ------------------------------------------------------------------------------
echo ""
echo -e "${BOLD}2. Linting Helm Charts (helm lint)...${NC}"
for chart_dir in helm/*; do
  if [[ -d "${chart_dir}" && -f "${chart_dir}/Chart.yaml" ]]; then
    if helm lint "${chart_dir}" > /dev/null 2>&1; then
      report_pass "Helm chart: ${chart_dir}"
    else
      report_fail "Helm chart lint failed: ${chart_dir}"
    fi
  fi
done

# ------------------------------------------------------------------------------
# 3. YAML Syntax Validation
# ------------------------------------------------------------------------------
echo ""
echo -e "${BOLD}3. Validating YAML Syntaxes (helm/ values and manifests/)...${NC}"
YAML_RESULT=$(python3 -c '
import glob, yaml, sys

# Only parse pure YAML files (exclude helm Go template files which are linted by helm lint)
all_files = glob.glob("helm/**/*.yaml", recursive=True) + \
            glob.glob("helm/**/*.yml", recursive=True) + \
            glob.glob("manifests/**/*.yaml", recursive=True) + \
            glob.glob("manifests/**/*.yml", recursive=True) + \
            glob.glob("*.yaml")

yaml_files = [f for f in all_files if "/templates/" not in f]

errors = []
for f in yaml_files:
    try:
        with open(f, "r") as fp:
            list(yaml.safe_load_all(fp))
    except Exception as e:
        errors.append(f"{f}: {e}")

if errors:
    for err in errors:
        print(f"FAIL|{err}")
    sys.exit(1)
else:
    print(f"OK|{len(yaml_files)}")
' 2>&1 || true)

if [[ "${YAML_RESULT}" =~ ^OK\|([0-9]+) ]]; then
  COUNT="${BASH_REMATCH[1]}"
  report_pass "All ${COUNT} YAML files are syntactically valid"
else
  while IFS= read -r line; do
    if [[ "${line}" =~ ^FAIL\|(.*) ]]; then
      report_fail "${BASH_REMATCH[1]}"
    fi
  done <<< "${YAML_RESULT}"
fi

# ------------------------------------------------------------------------------
# 4. Kubernetes Manifest Dry-Run Validation
# ------------------------------------------------------------------------------
echo ""
echo -e "${BOLD}4. Validating Kubernetes Manifests (kubectl client dry-run)...${NC}"
STANDARD_DIRS=("manifests/ingress" "manifests/jenkins" "manifests/postgres" "manifests/argocd")
ALL_STD_PASS=true
for dir in "${STANDARD_DIRS[@]}"; do
  if [[ -d "${dir}" ]]; then
    if kubectl apply --dry-run=client -R -f "${dir}" > /dev/null 2>&1; then
      report_pass "Manifests in ${dir}"
    else
      report_fail "Manifests in ${dir} failed client dry-run"
      ALL_STD_PASS=false
    fi
  fi
done

# Validate Kustomize apps
for app_dir in manifests/apps/*; do
  if [[ -d "${app_dir}" && -f "${app_dir}/kustomization.yaml" ]]; then
    if kubectl kustomize "${app_dir}" | kubectl apply --dry-run=client -f - > /dev/null 2>&1; then
      report_pass "Kustomize package: ${app_dir}"
    else
      report_fail "Kustomize validation failed for ${app_dir}"
    fi
  fi
done

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${CYAN}==================================================================${NC}"
echo -e "${BOLD}Summary: ${GREEN}${PASSED} passed${NC}, ${RED}${FAILED} failed${NC}"
echo -e "${BOLD}${CYAN}==================================================================${NC}"

if [[ ${FAILED} -gt 0 ]]; then
  exit 1
fi
exit 0
