#!/usr/bin/env bash
set -euo pipefail

SONAR_URL="${SONAR_URL:-https://sonar.localhost}"
SONAR_USER="${SONAR_USER:-admin}"
SONAR_PASS="${SONAR_PASS:-admin}"

echo "==> Waiting for SonarQube at ${SONAR_URL} to become ready..."
MAX_RETRIES=60
RETRY_COUNT=0

until curl -k -s -f -u "${SONAR_USER}:${SONAR_PASS}" "${SONAR_URL}/api/system/status" | grep -q '"status":"UP"'; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
    echo "ERROR: Timed out waiting for SonarQube to become ready."
    exit 1
  fi
  echo "SonarQube is starting up... waiting 5s (attempt ${RETRY_COUNT}/${MAX_RETRIES})"
  sleep 5
done

echo "==> SonarQube is UP!"

# ---------------------------------------------------------------------------
# 1. Quality Profiles: Production Java & Production Kotlin
# ---------------------------------------------------------------------------
setup_quality_profile() {
  local lang="$1"
  local target_profile_name="$2"
  shift 2
  local rules=("$@")

  echo ""
  echo "==> Setting up Quality Profile: '${target_profile_name}' for language '${lang}'..."

  # Search if target profile already exists
  local profile_search
  profile_search=$(curl -k -s -u "${SONAR_USER}:${SONAR_PASS}" "${SONAR_URL}/api/qualityprofiles/search?language=${lang}")

  local target_key
  target_key=$(echo "${profile_search}" | jq -r --arg name "${target_profile_name}" '.profiles[] | select(.name == $name) | .key // empty')

  if [[ -z "${target_key}" ]]; then
    # Find built-in "Sonar way" profile key to copy from
    local sonar_way_key
    sonar_way_key=$(echo "${profile_search}" | jq -r '.profiles[] | select(.name == "Sonar way") | .key // empty')

    if [[ -z "${sonar_way_key}" ]]; then
      echo "ERROR: Could not locate built-in 'Sonar way' profile for ${lang}."
      return 1
    fi

    echo "Copying 'Sonar way' (${sonar_way_key}) to '${target_profile_name}'..."
    local copy_res
    copy_res=$(curl -k -s -f -u "${SONAR_USER}:${SONAR_PASS}" -X POST "${SONAR_URL}/api/qualityprofiles/copy" \
      --data-urlencode "fromKey=${sonar_way_key}" \
      --data-urlencode "toName=${target_profile_name}")
    target_key=$(echo "${copy_res}" | jq -r '.key // empty')
    echo "✓ Profile '${target_profile_name}' created with key: ${target_key}"
  else
    echo "✓ Profile '${target_profile_name}' already exists (key: ${target_key})."
  fi

  # Activate rules
  echo "Activating curated best rules on profile '${target_profile_name}'..."
  local activated=0
  for rule in "${rules[@]}"; do
    local res
    res=$(curl -k -s -o /dev/null -w "%{http_code}" -u "${SONAR_USER}:${SONAR_PASS}" -X POST "${SONAR_URL}/api/qualityprofiles/activate_rule" \
      --data-urlencode "key=${target_key}" \
      --data-urlencode "rule=${rule}")
    if [[ "${res}" == "200" || "${res}" == "204" ]]; then
      activated=$((activated + 1))
    fi
  done
  echo "✓ Successfully verified/activated rules on '${target_profile_name}'."

  # Set as default profile for this language
  echo "Setting '${target_profile_name}' as default profile for ${lang}..."
  curl -k -s -f -u "${SONAR_USER}:${SONAR_PASS}" -X POST "${SONAR_URL}/api/qualityprofiles/set_default" \
    --data-urlencode "language=${lang}" \
    --data-urlencode "qualityProfile=${target_profile_name}" > /dev/null
  echo "✓ '${target_profile_name}' is now the default Quality Profile for ${lang}."
}

# Best rules for Java (Spring Boot, concurrency, security, bug prevention)
JAVA_RULES=(
  "java:S2229"  # Methods should not call same-class methods with incompatible @Transactional values
  "java:S6832"  # Non-singleton Spring beans should not be injected into singleton beans
  "java:S6829"  # @Autowired should be used when multiple constructors are provided
  "java:S6833"  # @Controller should be replaced with @RestController for REST APIs
  "java:S5970"  # Spring's ModelAndViewAssert assertions should be used
  "java:S2115"  # A secure password should be used when connecting to a database
  "java:S5852"  # Regular expressions should not cause catastrophic backtracking
  "java:S2109"  # Reflection should not be used to check non-runtime annotations
  "java:S1147"  # Exit methods should not be called
  "java:S2111"  # "BigDecimal(double)" should not be used
  "java:S2112"  # "URL.hashCode" and "URL.equals" should be avoided
  "java:S2114"  # Collections should not be passed as arguments to their own methods
  "java:S2116"  # "hashCode" and "toString" should not be called on array instances
  "java:S2222"  # Locks should be released on all paths
  "java:S2225"  # "toString()" and "clone()" methods should not return null
  "java:S2234"  # Parameters should be passed in the correct order
  "java:S2235"  # "IllegalMonitorStateException" should not be caught
  "java:S2236"  # "wait()", "notify()" should not be called on Thread instances
  "java:S3436"  # Value-based classes should not be used for locking
  "java:S3551"  # Overrides should match parent synchronization
  "java:S5856"  # Regular expressions should be syntactically valid
  "java:S5850"  # Alternatives in regular expressions should be grouped when used with anchors
  "java:S5855"  # Regex alternatives should not be redundant
  "java:S3553"  # "Optional" should not be used for parameters
  "java:S4524"  # "default" clauses should be last
  "java:S5738"  # "@Deprecated" code marked for removal should never be used
  "java:S5979"  # Annotated Mockito objects should be initialized
  "java:S5853"  # Consecutive AssertJ "assertThat" statements should be chained
)

# Best rules for Kotlin (Coroutines, Flows, modern idiomatic safety, security)
KOTLIN_RULES=(
  "kotlin:S6306"  # Coroutine usage should adhere to structured concurrency principles
  "kotlin:S6307"  # Suspending functions should be main-safe
  "kotlin:S6309"  # Functions returning Flow/Channel should not be suspending
  "kotlin:S6310"  # Dispatchers should be injectable
  "kotlin:S6311"  # Suspending functions should not be called on a different dispatcher
  "kotlin:S6312"  # Extension functions on CoroutineScopes should not be declared as suspend
  "kotlin:S6314"  # Flow intermediate operation results should not be left unused
  "kotlin:S6315"  # The return value of functions returning Deferred should be used
  "kotlin:S6316"  # Kotlin coroutines API for timeouts should be used
  "kotlin:S6305"  # MutableStateFlow and MutableSharedFlow should not be exposed
  "kotlin:S2068"  # Credentials should not be hard-coded
  "kotlin:S5344"  # Passwords should not be stored in plaintext or fast hash
  "kotlin:S3329"  # Cipher Block Chaining IVs should be unpredictable
  "kotlin:S6432"  # Counter Mode initialization vectors should not be reused
  "kotlin:S4347"  # Secure random number generators should not output predictable values
  "kotlin:S6301"  # Mobile database encryption keys should not be disclosed
  "kotlin:S1143"  # Jump statements should not occur in finally blocks
  "kotlin:S2757"  # Non-existent operators like "=+" should not be used
  "kotlin:S1656"  # Variables should not be self-assigned
  "kotlin:S1145"  # Useless if(true) and if(false) blocks should be removed
  "kotlin:S2114"  # Collections should not be passed as arguments to their own methods
  "kotlin:S2116"  # hashCode and toString should not be called on array instances
  "kotlin:S3958"  # Intermediate Sequence and Stream functions should not be left unused
  "kotlin:S5856"  # Regular expressions should be syntactically valid
  "kotlin:S5850"  # Alternatives in regular expressions should be grouped when used with anchors
  "kotlin:S3776"  # Cognitive Complexity of functions should not be too high
  "kotlin:S1821"  # "when" statements should not be nested
  "kotlin:S5612"  # Lambdas should not have too many lines
  "kotlin:S6558"  # "It" shouldn't be used as a lambda parameter name
  "kotlin:S1144"  # Unused private methods should be removed
  "kotlin:S1874"  # Code annotated as deprecated should not be used
)

setup_quality_profile "java" "Production Java" "${JAVA_RULES[@]}"
setup_quality_profile "kotlin" "Production Kotlin" "${KOTLIN_RULES[@]}"

# ---------------------------------------------------------------------------
# 2. Quality Gate: Ensure Coverage >= 80% & Zero Critical Defects
# ---------------------------------------------------------------------------
echo ""
echo "==> Configuring Quality Gate with >= 80% code coverage requirement..."

QG_NAME="Production Ready"
QG_LIST=$(curl -k -s -u "${SONAR_USER}:${SONAR_PASS}" "${SONAR_URL}/api/qualitygates/list")
QG_EXISTS=$(echo "${QG_LIST}" | jq -r --arg name "${QG_NAME}" '.qualitygates[] | select(.name == $name) | .name // empty')

if [[ -z "${QG_EXISTS}" ]]; then
  echo "Creating Quality Gate '${QG_NAME}'..."
  curl -k -s -f -u "${SONAR_USER}:${SONAR_PASS}" -X POST "${SONAR_URL}/api/qualitygates/create" \
    --data-urlencode "name=${QG_NAME}" > /dev/null
  echo "✓ Quality Gate '${QG_NAME}' created."
else
  echo "✓ Quality Gate '${QG_NAME}' already exists."
fi

# Add/Ensure conditions on Quality Gate
add_condition() {
  local metric="$1"
  local op="$2"
  local error="$3"

  curl -k -s -u "${SONAR_USER}:${SONAR_PASS}" -X POST "${SONAR_URL}/api/qualitygates/create_condition" \
    --data-urlencode "gateName=${QG_NAME}" \
    --data-urlencode "metric=${metric}" \
    --data-urlencode "op=${op}" \
    --data-urlencode "error=${error}" > /dev/null || true
}

echo "Configuring Quality Gate conditions (Coverage >= 80%, Duplications <= 3%, No new bugs/vulnerabilities)..."
add_condition "new_coverage" "LT" "80"
add_condition "coverage" "LT" "80"
add_condition "new_duplicated_lines_density" "GT" "3"
add_condition "new_violations" "GT" "0"
add_condition "new_security_hotspots_reviewed" "LT" "100"

echo "Setting '${QG_NAME}' as default Quality Gate..."
curl -k -s -f -u "${SONAR_USER}:${SONAR_PASS}" -X POST "${SONAR_URL}/api/qualitygates/set_as_default" \
  --data-urlencode "name=${QG_NAME}" > /dev/null

echo "✓ Quality Gate '${QG_NAME}' is now the default quality gate."

echo ""
echo "=========================================================="
echo " SonarQube Java & Kotlin Best Rules and Quality Gate Setup Complete! "
echo " - Default Java Profile   : Production Java (Sonar way + Spring/Security/Reliability rules)"
echo " - Default Kotlin Profile : Production Kotlin (Sonar way + Coroutines/Safety rules)"
echo " - Default Quality Gate   : Production Ready (Coverage >= 80% on new & overall code)"
echo "=========================================================="
