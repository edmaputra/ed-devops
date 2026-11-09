#!/usr/bin/env bash
set -euo pipefail

echo "==> Configuring HashiCorp Vault with storage persistence and Kubernetes auth..."

# Wait for vault-0 pod to be running (may be sealed before initialization)
echo "Waiting for vault-0 pod to be running..."
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 --timeout=120s

# Check if Vault is initialized
STATUS=$(kubectl exec vault-0 -c vault -- vault status -format=json 2>/dev/null || true)
INIT=$(echo "$STATUS" | jq -r '.initialized // false' 2>/dev/null || echo "false")

if [ "$INIT" = "false" ]; then
  echo "Initializing Vault with 1 key share and threshold..."
  INIT_RES=$(kubectl exec vault-0 -c vault -- vault operator init -key-shares=1 -key-threshold=1 -format=json)
  UNSEAL_KEY=$(echo "$INIT_RES" | jq -r '.unseal_keys_b64[0]')
  ROOT_TOKEN=$(echo "$INIT_RES" | jq -r '.root_token')

  # Save to certs/vault-keys.json (gitignored)
  mkdir -p certs
  echo "$INIT_RES" > certs/vault-keys.json
  chmod 600 certs/vault-keys.json

  # Save to Kubernetes secret for auto-unseal sidecar
  kubectl create secret generic vault-unseal-keys \
    --from-literal=unseal-key="$UNSEAL_KEY" \
    --from-literal=root-token="$ROOT_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# Ensure Vault is unsealed
STATUS=$(kubectl exec vault-0 -c vault -- vault status -format=json 2>/dev/null || true)
SEALED=$(echo "$STATUS" | jq -r '.sealed // true' 2>/dev/null || echo "true")

if [ "$SEALED" = "true" ]; then
  echo "Unsealing Vault..."
  UNSEAL_KEY=$(kubectl get secret vault-unseal-keys -o jsonpath='{.data.unseal-key}' | base64 -d)
  kubectl exec vault-0 -c vault -- vault operator unseal "$UNSEAL_KEY"
fi

# Wait for Vault to be ready
echo "Waiting for Vault to report Ready condition..."
kubectl wait --for=condition=Ready pod/vault-0 --timeout=120s

# Get root token
ROOT_TOKEN=$(kubectl get secret vault-unseal-keys -o jsonpath='{.data.root-token}' | base64 -d 2>/dev/null || echo "root")

VCMD="kubectl exec vault-0 -c vault -- env VAULT_TOKEN=$ROOT_TOKEN vault"

# Enable KV v2 secret engine if not enabled
if ! $VCMD secrets list | grep -q "^secret/"; then
  echo "Enabling KV-v2 engine at secret/..."
  $VCMD secrets enable -path=secret kv-v2
fi

# Enable Kubernetes authentication if not enabled
if ! $VCMD auth list | grep -q "^kubernetes/"; then
  echo "Enabling Kubernetes auth method in Vault..."
  $VCMD auth enable kubernetes
fi

# Configure Kubernetes auth
$VCMD write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

# Store database credentials
echo "Writing database secrets to Vault KV engine..."
$VCMD kv put secret/database/ilmiya \
  url="jdbc:postgresql://postgres:5432/ilmiya_db" \
  username="ilmiya_user" \
  password="Ilm!y4_Db_P@ss2026#Secure" \
  database="ilmiya_db"

$VCMD kv put secret/database/uwati \
  url="jdbc:postgresql://postgres:5432/uwati" \
  username="uwati" \
  password="Uwat!_Db_P@ss2026#Secure" \
  database="uwati"

# Store Spring Cloud Vault application secrets
echo "Writing Spring Cloud Vault secrets to Vault KV engine..."
$VCMD kv put secret/ilmiya-backend \
  spring.datasource.url="jdbc:postgresql://postgres:5432/ilmiya_db" \
  spring.datasource.username="ilmiya_user" \
  spring.datasource.password="Ilm!y4_Db_P@ss2026#Secure" \
  iam.jwt.secret="super-secret-jwt-signing-key-for-ilmiya-school-platform-which-must-be-at-least-256-bits!"

# Store frontend application configuration/secrets
echo "Writing frontend configuration to Vault KV engine..."
$VCMD kv put secret/frontend/ilmiya \
  apiBaseUrl="https://ilmiya.localhost" \
  defaultTenantId="01940000-0000-7000-8000-000000000001" \
  mockMode=false

# Create Vault ACL policies
echo "Applying Vault access policies..."
kubectl exec -i vault-0 -c vault -- env VAULT_TOKEN="$ROOT_TOKEN" vault policy write ilmiya-policy - << 'EOF'
path "secret/data/database/ilmiya" {
  capabilities = ["read"]
}
path "secret/data/ilmiya-backend" {
  capabilities = ["read"]
}
path "secret/data/ilmiya-backend/*" {
  capabilities = ["read"]
}
path "secret/data/application" {
  capabilities = ["read"]
}
path "secret/data/application/*" {
  capabilities = ["read"]
}
EOF

kubectl exec -i vault-0 -c vault -- env VAULT_TOKEN="$ROOT_TOKEN" vault policy write ilmiya-frontend-policy - << 'EOF'
path "secret/data/frontend/ilmiya" {
  capabilities = ["read"]
}
EOF

kubectl exec -i vault-0 -c vault -- env VAULT_TOKEN="$ROOT_TOKEN" vault policy write uwati-policy - << 'EOF'
path "secret/data/database/uwati" {
  capabilities = ["read"]
}
EOF

# Bind Kubernetes ServiceAccounts to Vault roles
echo "Binding Kubernetes ServiceAccounts to Vault roles..."
$VCMD write auth/kubernetes/role/ilmiya-backend \
  bound_service_account_names=ilmiya-backend \
  bound_service_account_namespaces=default \
  policies=ilmiya-policy \
  ttl=24h

$VCMD write auth/kubernetes/role/uwati \
  bound_service_account_names=uwati \
  bound_service_account_namespaces=default \
  policies=uwati-policy \
  ttl=24h

$VCMD write auth/kubernetes/role/ilmiya-frontend \
  bound_service_account_names=ilmiya-frontend \
  bound_service_account_namespaces=default \
  policies=ilmiya-frontend-policy \
  ttl=24h

echo "==> HashiCorp Vault successfully configured with persistent storage, database secrets, and Kubernetes auth!"
