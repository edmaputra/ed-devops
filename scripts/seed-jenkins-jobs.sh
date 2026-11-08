#!/usr/bin/env bash
set -euo pipefail

JENKINS_URL="${JENKINS_URL:-https://jenkins.localhost}"
JENKINS_USER="${JENKINS_USER:-admin}"
JENKINS_PASS="${JENKINS_PASS:-admin123}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> Waiting for Jenkins at ${JENKINS_URL} to become ready..."
COOKIE_JAR=$(mktemp)
trap 'rm -f "${COOKIE_JAR}"' EXIT

MAX_RETRIES=60
RETRY_COUNT=0
until curl -k -s -f -u "${JENKINS_USER}:${JENKINS_PASS}" "${JENKINS_URL}/api/json" > /dev/null 2>&1; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
    echo "ERROR: Timed out waiting for Jenkins to become ready."
    exit 1
  fi
  echo "Jenkins is starting up... waiting 5s (attempt ${RETRY_COUNT}/${MAX_RETRIES})"
  sleep 5
done
echo "==> Jenkins is ready!"

# Obtain CSRF Crumb
CRUMB_JSON=$(curl -k -s -c "${COOKIE_JAR}" -u "${JENKINS_USER}:${JENKINS_PASS}" "${JENKINS_URL}/crumbIssuer/api/json")
CRUMB=$(echo "${CRUMB_JSON}" | jq -r '.crumb // empty')
CRUMB_FIELD=$(echo "${CRUMB_JSON}" | jq -r '.crumbRequestField // empty')

CRUMB_HEADER=()
if [[ -n "${CRUMB}" && -n "${CRUMB_FIELD}" ]]; then
  CRUMB_HEADER=(-H "${CRUMB_FIELD}: ${CRUMB}")
fi

deploy_job() {
  local job_name="$1"
  local pipeline_file="$2"
  local description="$3"

  if [[ ! -f "${pipeline_file}" ]]; then
    echo "ERROR: Pipeline file not found: ${pipeline_file}"
    return 1
  fi

  local pipeline_script
  pipeline_script=$(cat "${pipeline_file}")

  local tmp_xml
  tmp_xml=$(mktemp)

  cat << XML > "${tmp_xml}"
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <actions/>
  <description>${description}</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script><![CDATA[${pipeline_script}]]></script>
    <sandbox>true</sandbox>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
XML

  # Check if job exists
  local status_code
  status_code=$(curl -k -s -o /dev/null -w "%{http_code}" -u "${JENKINS_USER}:${JENKINS_PASS}" "${JENKINS_URL}/job/${job_name}/config.xml")

  if [[ "${status_code}" == "200" ]]; then
    echo "Updating existing job: ${job_name}..."
    curl -k -s -f -X POST "${JENKINS_URL}/job/${job_name}/config.xml" \
      -b "${COOKIE_JAR}" \
      -u "${JENKINS_USER}:${JENKINS_PASS}" \
      "${CRUMB_HEADER[@]}" \
      -H "Content-Type: application/xml" \
      --data-binary @"${tmp_xml}"
    echo "✓ Job '${job_name}' updated successfully."
  else
    echo "Creating new job: ${job_name}..."
    curl -k -s -f -X POST "${JENKINS_URL}/createItem?name=${job_name}" \
      -b "${COOKIE_JAR}" \
      -u "${JENKINS_USER}:${JENKINS_PASS}" \
      "${CRUMB_HEADER[@]}" \
      -H "Content-Type: application/xml" \
      --data-binary @"${tmp_xml}"
    echo "✓ Job '${job_name}' created successfully."
  fi

  rm -f "${tmp_xml}"
}

# Deploy local deployment pipeline jobs
deploy_job "deploy-ilmiya-backend" "${ROOT_DIR}/pipelines/local-deploy-backend.groovy" "Centralized Local Deployment for Java Spring Boot Backend"
deploy_job "deploy-ilmiya-frontend" "${ROOT_DIR}/pipelines/local-deploy-frontend.groovy" "Centralized Local Deployment for Flutter Web Frontend"

echo ""
echo "All local pipeline jobs successfully seeded in Jenkins!"
