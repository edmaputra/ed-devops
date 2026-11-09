#!/usr/bin/env bash
set -euo pipefail

echo "==> Configuring HashiCorp Vault secrets and Kubernetes auth..."

# Wait for vault-0 to be ready
kubectl wait --for=condition=Ready pod/vault-0 --timeout=120s

# Enable Kubernetes authentication if not enabled
if ! kubectl exec vault-0 -- vault auth list | grep -q "^kubernetes/"; then
  echo "Enabling Kubernetes auth method in Vault..."
  kubectl exec vault-0 -- vault auth enable kubernetes
fi

# Configure Kubernetes auth
kubectl exec vault-0 -- vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

# Store database credentials
echo "Writing database secrets to Vault KV engine..."
kubectl exec vault-0 -- vault kv put secret/database/ilmiya \
  url="jdbc:postgresql://postgres:5432/ilmiya_db" \
  username="ilmiya_user" \
  password="Ilm!y4_Db_P@ss2026#Secure" \
  database="ilmiya_db"

kubectl exec vault-0 -- vault kv put secret/database/uwati \
  url="jdbc:postgresql://postgres:5432/uwati" \
  username="uwati" \
  password="Uwat!_Db_P@ss2026#Secure" \
  database="uwati"

# Store Spring Cloud Vault application secrets
echo "Writing Spring Cloud Vault secrets to Vault KV engine..."
kubectl exec vault-0 -- vault kv put secret/ilmiya-backend \
  spring.datasource.url="jdbc:postgresql://postgres:5432/ilmiya_db" \
  spring.datasource.username="ilmiya_user" \
  spring.datasource.password="Ilm!y4_Db_P@ss2026#Secure" \
  iam.jwt.secret="super-secret-jwt-signing-key-for-ilmiya-school-platform-which-must-be-at-least-256-bits!"

# Store frontend application configuration/secrets
echo "Writing frontend configuration to Vault KV engine..."
kubectl exec vault-0 -- vault kv put secret/frontend/ilmiya \
  apiBaseUrl="https://ilmiya.localhost" \
  defaultTenantId="01940000-0000-7000-8000-000000000001" \
  mockMode=false

# Create Vault ACL policies
echo "Applying Vault access policies..."
kubectl exec -i vault-0 -- vault policy write ilmiya-policy - << 'EOF'
path "secret/data/database/ilmiya" {
  capabilities = ["read"]
}
path "secret/data/ilmiya-backend" {
  capabilities = ["read"]
}
path "secret/data/application" {
  capabilities = ["read"]
}
EOF

kubectl exec -i vault-0 -- vault policy write ilmiya-frontend-policy - << 'EOF'
path "secret/data/frontend/ilmiya" {
  capabilities = ["read"]
}
EOF

kubectl exec -i vault-0 -- vault policy write uwati-policy - << 'EOF'
path "secret/data/database/uwati" {
  capabilities = ["read"]
}
EOF

# Bind Kubernetes ServiceAccounts to Vault roles
echo "Binding Kubernetes ServiceAccounts to Vault roles..."
kubectl exec vault-0 -- vault write auth/kubernetes/role/ilmiya-backend \
  bound_service_account_names=ilmiya-backend \
  bound_service_account_namespaces=default \
  policies=ilmiya-policy \
  ttl=24h

kubectl exec vault-0 -- vault write auth/kubernetes/role/uwati \
  bound_service_account_names=uwati \
  bound_service_account_namespaces=default \
  policies=uwati-policy \
  ttl=24h

kubectl exec vault-0 -- vault write auth/kubernetes/role/ilmiya-frontend \
  bound_service_account_names=ilmiya-frontend \
  bound_service_account_namespaces=default \
  policies=ilmiya-frontend-policy \
  ttl=24h

echo "==> HashiCorp Vault successfully configured with database secrets and Kubernetes auth!"
