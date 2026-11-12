.PHONY: help status start stop cluster-up cluster-down deploy-vault deploy-consul deploy-postgres setup-vault-secrets setup-consul-config deploy-jenkins deploy-argocd deploy-sonarqube setup-sonarqube-rules deploy-openobserve deploy-fluent-bit setup-openobserve-dashboards deploy-ingress deploy-jenkins-rbac seed-jobs deploy-all deploy-apps deploy-argocd-apps urls generate-certs create-tls-secret cleanup-storage deploy-cleanup-cronjob healthcheck lint worktree setup-macos

# ---------------------------------------------------------------------------
# Detect OS and set the correct k3d config and container socket.
# On macOS (OrbStack): use k3d-config.macos.yaml, DOCKER_HOST via OrbStack.
# On Linux (Rootless Podman): use k3d-config.yaml, DOCKER_HOST via Podman.
# ---------------------------------------------------------------------------
OS := $(shell uname -s)
ifeq ($(OS),Darwin)
  K3D_CONFIG     := k3d-config.macos.yaml
  DOCKER_HOST    ?= unix://$(HOME)/.orbstack/run/docker.sock
  export DOCKER_HOST
else
  K3D_CONFIG     := k3d-config.yaml
  XDG_RUNTIME_DIR ?= /run/user/$(shell id -u)
  DOCKER_HOST    ?= unix://$(XDG_RUNTIME_DIR)/podman/podman.sock
  export DOCKER_HOST
endif

help:
	@echo "Available commands:"
	@echo "  make setup-macos         - Install all tools & configure DNS/TLS for macOS (OrbStack)"
	@echo "  make start               - Start existing k3d cluster and local registry"
	@echo "  make stop                - Stop running k3d cluster and registry (preserves state)"
	@echo "  make status              - Show cluster status, pods, and ingress"
	@echo "  make healthcheck         - Comprehensive verification of cluster, services, APIs & DB"
	@echo "  make lint                - Static analysis & linting (Helm, YAML, Shell, K8s manifests)"
	@echo "  make worktree BRANCH=... - Create a new git worktree safely synced from origin/main"
	@echo "  make urls                - Display all local access URLs and credentials"
	@echo "  make generate-certs      - Generate local TLS certificates with explicit SANs via mkcert"
	@echo "  make create-tls-secret   - Create Kubernetes secret with local wildcard TLS cert"
	@echo "  make deploy-vault        - Deploy or upgrade HashiCorp Vault via Helm"
	@echo "  make deploy-consul       - Deploy or upgrade HashiCorp Consul via Helm"
	@echo "  make deploy-postgres     - Deploy or upgrade PostgreSQL via Helm"
	@echo "  make setup-vault-secrets - Configure Vault Kubernetes auth and app database secrets"
	@echo "  make setup-consul-config - Seed application configuration into HashiCorp Consul KV"
	@echo "  make deploy-jenkins      - Deploy or upgrade Jenkins CI/CD via Helm"
	@echo "  make deploy-argocd       - Deploy or upgrade ArgoCD via Helm"
	@echo "  make deploy-sonarqube    - Deploy or upgrade SonarQube via Helm"
	@echo "  make setup-sonarqube-rules - Configure Java/Kotlin quality profiles and 80% coverage quality gate"
	@echo "  make deploy-openobserve  - Deploy or upgrade OpenObserve via Helm"
	@echo "  make deploy-fluent-bit   - Deploy or upgrade Fluent Bit log shipper via Helm"
	@echo "  make setup-openobserve-dashboards - Provision initial OpenObserve metrics & log dashboards"
	@echo "  make deploy-ingress      - Apply local Ingress configuration"
	@echo "  make deploy-jenkins-rbac - Apply RBAC for Jenkins dynamic build agents"
	@echo "  make seed-jobs           - Seed centralized local deployment pipeline jobs into Jenkins"
	@echo "  make cleanup-storage     - Prune older Jenkins builds, dangling/unused images & volumes"
	@echo "  make deploy-cleanup-cronjob - Deploy scheduled autonomous storage cleanup CronJob to k8s"
	@echo "  make deploy-all          - Deploy all platform services, TLS, and ingress"
	@echo "  make cluster-up          - Create k3d cluster with local registry"
	@echo "  make cluster-down        - Destroy k3d cluster and registry"

setup-macos:
	./scripts/setup-macos.sh

status:
	@echo "=== Nodes ==="
	@kubectl get nodes -o wide
	@echo "\n=== Pods ==="
	@kubectl get pods -A
	@echo "\n=== Ingress ==="
	@kubectl get ingress -A

urls:
	@echo "=========================================================="
	@echo " Local Services Dashboard (HTTPS Port 443 & HTTP Port 80) "
	@echo "=========================================================="
	@echo " Jenkins    : https://jenkins.localhost   (User: admin, Pass: admin123)"
	@echo " ArgoCD     : https://argocd.localhost    (User: admin, Pass: admin123)"
	@echo " SonarQube  : https://sonar.localhost     (User: admin, Pass: admin)"
	@echo " OpenObserve: https://openobserve.localhost (User: admin@example.com, Pass: DevOps_OpenObserve#2026)"
	@echo " Vault      : https://vault.localhost/ui  (Root Token: root)"
	@echo " Consul     : https://consul.localhost/ui"
	@echo " PostgreSQL : postgres:5432 / localhost:5432 (Admin: postgres / P0stgr3s_L4b_Adm!n#2026 | ilmiya_db: ilmiya_user / Ilm!y4_Db_P@ss2026#Secure | uwati: uwati / Uwat!_Db_P@ss2026#Secure)"
	@echo " Registry   : http://localhost:5000/v2/_catalog"
	@echo "=========================================================="

generate-certs:
	mkdir -p certs
	mkcert -cert-file certs/local-cert.pem -key-file certs/local-key.pem \
		localhost "*.localhost" vault.localhost consul.localhost jenkins.localhost argocd.localhost sonar.localhost sonarqube.localhost ilmiya.localhost "*.ilmiya.localhost" openobserve.localhost

create-tls-secret:
	kubectl create secret tls local-wildcard-tls --cert=certs/local-cert.pem --key=certs/local-key.pem --dry-run=client -o yaml | kubectl apply -f -

# Helm upgrade flags: --force-conflicts ensures Server-Side Apply (Helm v4) handles field ownership conflicts gracefully
HELM_UPGRADE_FLAGS := --force-conflicts

deploy-vault:
	helm upgrade --install vault hashicorp/vault -f helm/vault/values.yaml --timeout 15m $(HELM_UPGRADE_FLAGS)

deploy-consul:
	helm upgrade --install consul hashicorp/consul -f helm/consul/values.yaml --timeout 15m $(HELM_UPGRADE_FLAGS)

deploy-postgres:
	helm upgrade --install postgres helm/postgres --timeout 15m $(HELM_UPGRADE_FLAGS)

setup-vault-secrets:
	./scripts/setup-vault-secrets.sh

setup-consul-config:
	./scripts/setup-consul-config.sh

deploy-jenkins:
	helm upgrade --install jenkins jenkins/jenkins -f helm/jenkins/values.yaml --timeout 15m $(HELM_UPGRADE_FLAGS)

deploy-argocd:
	helm upgrade --install argocd argo/argo-cd -f helm/argocd/values.yaml --timeout 15m $(HELM_UPGRADE_FLAGS)

deploy-sonarqube:
	helm upgrade --install sonarqube sonarqube/sonarqube -f helm/sonarqube/values.yaml --timeout 25m $(HELM_UPGRADE_FLAGS)

setup-sonarqube-rules:
	./scripts/setup-sonarqube-rules.sh

deploy-openobserve:
	helm upgrade --install openobserve openobserve/openobserve-standalone -f helm/openobserve/values.yaml --timeout 15m $(HELM_UPGRADE_FLAGS)

deploy-fluent-bit:
	helm upgrade --install fluent-bit fluent/fluent-bit -f helm/fluent-bit/values.yaml --timeout 15m $(HELM_UPGRADE_FLAGS)

setup-openobserve-dashboards:
	./scripts/setup-openobserve-dashboards.sh

deploy-ingress:
	kubectl apply -f manifests/ingress/local-ingress.yaml

deploy-jenkins-rbac:
	kubectl apply -f manifests/jenkins/jenkins-deployer-rbac.yaml
	kubectl apply -f manifests/jenkins/jenkins-gradle-cache-pvc.yaml

seed-jobs:
	./scripts/seed-jenkins-jobs.sh

cleanup-storage:
	./scripts/cleanup-storage.sh

deploy-cleanup-cronjob:
ifeq ($(OS),Darwin)
	@sed 's|/run/podman/podman.sock|/var/run/docker.sock|g' manifests/jenkins/jenkins-storage-cleanup-cronjob.yaml | kubectl apply -f -
else
	kubectl apply -f manifests/jenkins/jenkins-storage-cleanup-cronjob.yaml
endif

healthcheck:
	./scripts/healthcheck.sh

lint:
	./scripts/lint.sh

worktree:
	./scripts/worktree-helper.sh $(BRANCH) $(TARGET_DIR)

deploy-all: create-tls-secret deploy-ingress deploy-vault deploy-consul deploy-postgres setup-vault-secrets setup-consul-config deploy-jenkins deploy-jenkins-rbac deploy-argocd deploy-sonarqube setup-sonarqube-rules deploy-openobserve deploy-fluent-bit setup-openobserve-dashboards seed-jobs deploy-cleanup-cronjob
deploy-apps:
	kubectl apply -f manifests/apps/ilmiya-backend/deployment.yaml

deploy-argocd-apps:
	kubectl apply -f manifests/argocd/applications.yaml

start:
	@echo "Starting local registry and k3d cluster..."
ifeq ($(OS),Darwin)
	@docker start k3d-dev-registry || true
	@docker start k3d-dev-cluster-server-0 || true
	@docker start k3d-dev-cluster-serverlb || true
	@docker exec k3d-dev-cluster-serverlb nginx -s reload >/dev/null 2>&1 || true
else
	@podman start k3d-dev-registry || true
	@podman start k3d-dev-cluster-server-0 || true
	@podman start k3d-dev-cluster-serverlb || true
	@podman exec k3d-dev-cluster-serverlb nginx -s reload >/dev/null 2>&1 || true
endif
	@echo "Waiting for cluster control-plane to become ready..."
	@until kubectl get nodes >/dev/null 2>&1; do sleep 1; done
	@echo "Cluster is ready."
	@kubectl get nodes

stop:
	@echo "Stopping k3d cluster and local registry..."
ifeq ($(OS),Darwin)
	@docker stop -t 2 k3d-dev-cluster-serverlb >/dev/null 2>&1 || true
	@docker stop -t 10 k3d-dev-cluster-server-0 >/dev/null 2>&1 || docker kill k3d-dev-cluster-server-0 >/dev/null 2>&1 || true
	@docker stop -t 2 k3d-dev-registry >/dev/null 2>&1 || true
else
	@podman stop -t 2 k3d-dev-cluster-serverlb >/dev/null 2>&1 || true
	@podman stop -t 10 k3d-dev-cluster-server-0 >/dev/null 2>&1 || podman kill k3d-dev-cluster-server-0 >/dev/null 2>&1 || true
	@podman stop -t 2 k3d-dev-registry >/dev/null 2>&1 || true
endif
	@echo "Cluster and registry stopped successfully."

cluster-up:
ifeq ($(OS),Darwin)
	k3d registry create --default-network bridge dev-registry --port 0.0.0.0:5000 || true
else
	k3d registry create --default-network podman dev-registry --port 0.0.0.0:5000 || true
endif
	k3d cluster create --config $(K3D_CONFIG)

cluster-down:
	k3d cluster delete dev-cluster || true
	k3d registry delete dev-registry || true
