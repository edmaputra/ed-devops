#!/usr/bin/env bash
set -euo pipefail

echo "==> Configuring HashiCorp Consul Key-Value properties for platform applications..."

# Wait for consul-server-0 to be ready
kubectl wait --for=condition=Ready pod/consul-server-0 --timeout=120s

CONSUL_ENDPOINT="${CONSUL_ENDPOINT:-https://consul.localhost}"

put_kv() {
  local key="$1"
  local value="$2"
  echo "Setting Consul KV: ${key}..."
  if ! curl -sk -f -X PUT "${CONSUL_ENDPOINT}/v1/kv/${key}" --data-binary "${value}" > /dev/null 2>&1; then
    # Fallback to in-cluster pod exec if host ingress is not resolving
    kubectl exec -i consul-server-0 -c consul -- curl -s -f -X PUT "http://127.0.0.1:8500/v1/kv/${key}" --data-binary "${value}" > /dev/null
  fi
}

# 1. Shared configuration (config/application/data)
put_kv "config/application/data" 'management:
  endpoints:
    web:
      exposure:
        include: health,info,metrics
  endpoint:
    health:
      show-details: always
      probes:
        enabled: true'

# 2. Ilmiya Backend configuration (config/ilmiya-backend/data)
put_kv "config/ilmiya-backend/data" 'logging:
  level:
    root: INFO
    io.github.edmaputra.ilmiya: DEBUG
ilmiya:
  seed:
    enabled: true'

# 3. Uwati configuration (config/uwati/data)
put_kv "config/uwati/data" 'logging:
  level:
    root: INFO
uwati:
  cache:
    enabled: true'

echo "==> HashiCorp Consul KV properties successfully seeded!"
