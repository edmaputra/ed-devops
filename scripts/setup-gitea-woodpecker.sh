#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Automated Provisioning Script for Gitea + Woodpecker CI Integration
# Configures:
#   1. Gitea Admin User & OAuth2 Application for Woodpecker
#   2. Woodpecker Gitea OAuth Kubernetes Secret
#   3. Local Repository Seeding (ilmiya, ilmiya-frontend) with Woodpecker CI Pipelines
#   4. Woodpecker Deployer RBAC & Scheduled Autonomous Storage Cleaner
# ==============================================================================

GITEA_URL="${GITEA_URL:-https://gitea.localhost}"
GITEA_USER="${GITEA_USER:-gitea_admin}"
GITEA_PASS="${GITEA_PASS:-DevOps_Gitea#2026}"
GITEA_EMAIL="${GITEA_EMAIL:-admin@localhost}"
WOODPECKER_URL="${WOODPECKER_URL:-https://woodpecker.localhost}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=================================================================="
echo " Setting up Gitea & Woodpecker CI Integration"
echo " Date: $(date)"
echo "=================================================================="

# 1. Wait for Gitea to become ready
echo "==> [1/5] Waiting for Gitea at ${GITEA_URL} to become ready..."
MAX_RETRIES=60
RETRY_COUNT=0
until curl -k -s -f "${GITEA_URL}/api/v1/version" > /dev/null 2>&1; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
    echo "ERROR: Timed out waiting for Gitea to become ready."
    exit 1
  fi
  sleep 2
done
echo "✓ Gitea is online."

# 2. Ensure Admin User exists
echo "==> [2/5] Verifying Gitea admin user (${GITEA_USER})..."
if ! curl -k -s -f -u "${GITEA_USER}:${GITEA_PASS}" "${GITEA_URL}/api/v1/user" > /dev/null 2>&1; then
  echo "Creating Gitea admin user via container CLI..."
  kubectl exec deployment/gitea -- su-exec git gitea admin user create \
    --admin --username "${GITEA_USER}" --password "${GITEA_PASS}" --email "${GITEA_EMAIL}" --must-change-password=false || true
fi
echo "✓ Gitea admin user verified."

# 3. Create or retrieve OAuth2 Application for Woodpecker CI
echo "==> [3/5] Configuring OAuth2 Application in Gitea for Woodpecker CI..."
OAUTH_APPS=$(curl -k -s -u "${GITEA_USER}:${GITEA_PASS}" "${GITEA_URL}/api/v1/user/applications/oauth2")
CLIENT_ID=$(echo "${OAUTH_APPS}" | jq -r '.[] | select(.name=="Woodpecker CI") | .client_id' 2>/dev/null | head -n 1 || true)

if [[ -z "${CLIENT_ID}" ]]; then
  echo "Registering new Woodpecker CI OAuth2 application in Gitea..."
  NEW_APP=$(curl -k -s -X POST "${GITEA_URL}/api/v1/user/applications/oauth2" \
    -u "${GITEA_USER}:${GITEA_PASS}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"Woodpecker CI\",
      \"redirect_uris\": [
        \"${WOODPECKER_URL}/authorize\"
      ],
      \"confidential_client\": true
    }")
  CLIENT_ID=$(echo "${NEW_APP}" | jq -r '.client_id')
  CLIENT_SECRET=$(echo "${NEW_APP}" | jq -r '.client_secret')
else
  echo "Found existing Woodpecker CI OAuth2 application (client_id: ${CLIENT_ID})."
  # Fetch existing secret if secret exists in k8s
  CLIENT_SECRET=$(kubectl get secret woodpecker-gitea-oauth -o jsonpath='{.data.WOODPECKER_GITEA_SECRET}' 2>/dev/null | base64 -d || true)
  if [[ -z "${CLIENT_SECRET}" ]]; then
    # Recreate OAuth app to get secret
    APP_ID=$(echo "${OAUTH_APPS}" | jq -r '.[] | select(.name=="Woodpecker CI") | .id')
    curl -k -s -X DELETE "${GITEA_URL}/api/v1/user/applications/oauth2/${APP_ID}" -u "${GITEA_USER}:${GITEA_PASS}" >/dev/null 2>&1 || true
    NEW_APP=$(curl -k -s -X POST "${GITEA_URL}/api/v1/user/applications/oauth2" \
      -u "${GITEA_USER}:${GITEA_PASS}" \
      -H "Content-Type: application/json" \
      -d "{
        \"name\": \"Woodpecker CI\",
        \"redirect_uris\": [
          \"${WOODPECKER_URL}/authorize\"
        ],
        \"confidential_client\": true
      }")
    CLIENT_ID=$(echo "${NEW_APP}" | jq -r '.client_id')
    CLIENT_SECRET=$(echo "${NEW_APP}" | jq -r '.client_secret')
  fi
fi

echo "Updating Kubernetes secret woodpecker-gitea-oauth..."
kubectl create secret generic woodpecker-gitea-oauth \
  --from-literal=WOODPECKER_GITEA_CLIENT="${CLIENT_ID}" \
  --from-literal=WOODPECKER_GITEA_SECRET="${CLIENT_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "✓ Woodpecker OAuth credentials synchronized."

# 4. Seed Local Repositories and Woodpecker Pipelines
echo "==> [4/5] Seeding repositories and Woodpecker pipelines in Gitea..."
seed_repo() {
  local repo_name="$1"
  local upstream_url="$2"
  local pipeline_file="$3"

  # Check if repository already exists in Gitea
  local status_code
  status_code=$(curl -k -s -o /dev/null -w "%{http_code}" -u "${GITEA_USER}:${GITEA_PASS}" "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${repo_name}")

  if [[ "${status_code}" != "200" ]]; then
    echo "Importing ${repo_name} from ${upstream_url}..."
    curl -k -s -X POST "${GITEA_URL}/api/v1/repos/migrate" \
      -u "${GITEA_USER}:${GITEA_PASS}" \
      -H "Content-Type: application/json" \
      -d "{
        \"clone_addr\": \"${upstream_url}\",
        \"repo_name\": \"${repo_name}\",
        \"service\": \"git\"
      }" > /dev/null 2>&1 || true
    echo "✓ Repository ${repo_name} imported."
  else
    echo "Repository ${repo_name} already exists."
  fi

  # Patch .gitmodules if it contains SSH URLs (e.g. git@github.com:) to use HTTPS
  local gitmodules_check
  gitmodules_check=$(curl -k -s -u "${GITEA_USER}:${GITEA_PASS}" "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${repo_name}/contents/.gitmodules")
  local gm_sha
  gm_sha=$(echo "${gitmodules_check}" | jq -r '.sha // empty')
  if [[ -n "${gm_sha}" ]]; then
    local gm_content
    gm_content=$(echo "${gitmodules_check}" | jq -r '.content // empty' | tr -d '\n' | base64 -d 2>/dev/null || true)
    if [[ "${gm_content}" == *"git@github.com:"* ]]; then
      echo "Patching .gitmodules in ${repo_name} to use HTTPS public URLs..."
      local patched_gm
      patched_gm=$(echo "${gm_content}" | sed 's|git@github.com:|https://github.com/|g')
      local patched_gm_b64
      patched_gm_b64=$(echo "${patched_gm}" | base64 | tr -d '\n')
      curl -k -s -X PUT "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${repo_name}/contents/.gitmodules" \
        -u "${GITEA_USER}:${GITEA_PASS}" \
        -H "Content-Type: application/json" \
        -d "{
          \"message\": \"fix(gitmodules): use public HTTPS submodule url\",
          \"content\": \"${patched_gm_b64}\",
          \"sha\": \"${gm_sha}\",
          \"branch\": \"main\"
        }" > /dev/null 2>&1 || true
      echo "✓ .gitmodules patched in ${repo_name}."
    fi
  fi

  # Commit .woodpecker.yaml pipeline if present
  if [[ -f "${pipeline_file}" ]]; then
    local content_b64
    content_b64=$(base64 -i "${pipeline_file}" | tr -d '\n')
    
    # Check if .woodpecker.yaml already exists in repo
    local file_check
    file_check=$(curl -k -s -u "${GITEA_USER}:${GITEA_PASS}" "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${repo_name}/contents/.woodpecker.yaml")
    local sha
    sha=$(echo "${file_check}" | jq -r '.sha // empty')

    if [[ -z "${sha}" ]]; then
      echo "Creating .woodpecker.yaml in ${repo_name}..."
      curl -k -s -X POST "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${repo_name}/contents/.woodpecker.yaml" \
        -u "${GITEA_USER}:${GITEA_PASS}" \
        -H "Content-Type: application/json" \
        -d "{
          \"message\": \"Add Woodpecker CI pipeline\",
          \"content\": \"${content_b64}\",
          \"branch\": \"main\"
        }" > /dev/null 2>&1 || true
    else
      echo "Updating .woodpecker.yaml in ${repo_name}..."
      curl -k -s -X PUT "${GITEA_URL}/api/v1/repos/${GITEA_USER}/${repo_name}/contents/.woodpecker.yaml" \
        -u "${GITEA_USER}:${GITEA_PASS}" \
        -H "Content-Type: application/json" \
        -d "{
          \"message\": \"Update Woodpecker CI pipeline\",
          \"content\": \"${content_b64}\",
          \"sha\": \"${sha}\",
          \"branch\": \"main\"
        }" > /dev/null 2>&1 || true
    fi
    echo "✓ .woodpecker.yaml synced to ${repo_name}."
  fi
}

seed_repo "ilmiya" "https://github.com/edmaputra/ilmiya.git" "${ROOT_DIR}/pipelines/ilmiya-backend.woodpecker.yaml"
seed_repo "ilmiya-frontend" "https://github.com/edmaputra/ilmiya-frontend.git" "${ROOT_DIR}/pipelines/ilmiya-frontend.woodpecker.yaml"

# 5. Apply RBAC and CronJob
echo "==> [5/5] Applying Woodpecker deployer RBAC and storage cleanup CronJob..."
kubectl apply -f "${ROOT_DIR}/manifests/woodpecker/woodpecker-deployer-rbac.yaml"

OS="$(uname -s)"
if [[ "${OS}" == "Darwin" ]]; then
  sed 's|/run/podman/podman.sock|/var/run/docker.sock|g' "${ROOT_DIR}/manifests/woodpecker/woodpecker-storage-cleanup-cronjob.yaml" | kubectl apply -f -
else
  kubectl apply -f "${ROOT_DIR}/manifests/woodpecker/woodpecker-storage-cleanup-cronjob.yaml"
fi
echo "✓ Woodpecker RBAC and CronJob applied."

echo ""
echo "=================================================================="
echo " Gitea & Woodpecker CI Setup Complete!"
echo " Woodpecker UI : https://woodpecker.localhost"
echo " Gitea Web UI  : https://gitea.localhost (User: ${GITEA_USER} / Pass: ${GITEA_PASS})"
echo "=================================================================="
