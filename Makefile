.PHONY: help status start stop cluster-up cluster-down seed-images preload-images deploy-vault deploy-consul deploy-postgres setup-vault-secrets setup-consul-config deploy-gitea deploy-woodpecker deploy-woodpecker-rbac setup-gitea-woodpecker sync-repos deploy-openobserve deploy-fluent-bit setup-openobserve-dashboards deploy-ingress deploy-all deploy-apps urls generate-certs create-tls-secret cleanup-storage deploy-cleanup-cronjob healthcheck lint worktree setup-macos

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
  DOCKER_PUSH_FLAGS ?=
else
  K3D_CONFIG     := k3d-config.yaml
  XDG_RUNTIME_DIR ?= /run/user/$(shell id -u)
  DOCKER_HOST    ?= unix://$(XDG_RUNTIME_DIR)/podman/podman.sock
  export DOCKER_HOST
  DOCKER_PUSH_FLAGS ?= $(shell docker --version 2>/dev/null | grep -qi podman && echo "--tls-verify=false")
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
	@echo "  make deploy-gitea        - Deploy or upgrade Gitea Git Forge via Helm"
	@echo "  make deploy-woodpecker   - Deploy or upgrade Woodpecker CI via Helm"
	@echo "  make deploy-woodpecker-rbac - Apply RBAC for Woodpecker Kubernetes pipeline agents"
	@echo "  make setup-gitea-woodpecker - Configure Gitea OAuth, Woodpecker secret, and seed repos"
	@echo "  make sync-repos [REPO=...] - Sync Gitea repos with GitHub upstream & trigger deployment (all, frontend, backend)"
	@echo "  make deploy-openobserve  - Deploy or upgrade OpenObserve via Helm"
	@echo "  make deploy-fluent-bit   - Deploy or upgrade Fluent Bit log shipper via Helm"
	@echo "  make setup-openobserve-dashboards - Provision initial OpenObserve metrics & log dashboards"
	@echo "  make deploy-ingress      - Apply local Ingress configuration"
	@echo "  make cleanup-storage     - Prune dangling/unused images, volumes, and stopped containers"
	@echo "  make deploy-cleanup-cronjob - Deploy scheduled autonomous storage cleanup CronJob to k8s"
	@echo "  make deploy-all          - Deploy all platform services, TLS, and ingress"
	@echo "  make cluster-up          - Create k3d cluster with local registry"
	@echo "  make seed-images         - Pull upstream images and push them to the local registry"
	@echo "  make preload-images      - Pre-pull all platform container images into k3d containerd cache"
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
	@echo " Woodpecker CI : https://woodpecker.localhost"
	@echo " Gitea Forge   : https://gitea.localhost      (User: gitea_admin, Pass: DevOps_Gitea#2026)"
	@echo " OpenObserve   : https://openobserve.localhost (User: admin@example.com, Pass: DevOps_OpenObserve#2026)"
	@echo " Vault         : https://vault.localhost/ui    (Root Token: root)"
	@echo " Consul        : https://consul.localhost/ui"
	@echo " PostgreSQL    : postgres:5432 / localhost:5432 (Admin: postgres / P0stgr3s_L4b_Adm!n#2026 | ilmiya_db: ilmiya_user / Ilm!y4_Db_P@ss2026#Secure | uwati: uwati / Uwat!_Db_P@ss2026#Secure)"
	@echo " Registry      : http://localhost:5000/v2/_catalog"
	@echo "=========================================================="

generate-certs:
	mkdir -p certs
	mkcert -cert-file certs/local-cert.pem -key-file certs/local-key.pem \
		localhost "*.localhost" vault.localhost consul.localhost woodpecker.localhost gitea.localhost ilmiya.localhost "*.ilmiya.localhost" openobserve.localhost

create-tls-secret:
	kubectl create secret tls local-wildcard-tls --cert=certs/local-cert.pem --key=certs/local-key.pem --dry-run=client -o yaml | kubectl apply -f -

# Helm upgrade flags: --force-conflicts is only supported in Helm v4+ (Server-Side Apply)
HELM_UPGRADE_FLAGS ?= $(shell helm upgrade --help 2>&1 | grep -q -- '--force-conflicts' && echo '--force-conflicts')

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

deploy-gitea:
	helm upgrade --install gitea helm/gitea --timeout 15m $(HELM_UPGRADE_FLAGS)

deploy-woodpecker:
	helm upgrade --install woodpecker woodpecker/woodpecker -f helm/woodpecker/values.yaml --timeout 15m $(HELM_UPGRADE_FLAGS)

deploy-woodpecker-rbac:
	kubectl apply -f manifests/woodpecker/woodpecker-deployer-rbac.yaml
	kubectl apply -f manifests/woodpecker/woodpecker-cache-pvcs.yaml

setup-gitea-woodpecker:
	./scripts/setup-gitea-woodpecker.sh

sync-repos:
	./scripts/sync-repos.sh $(REPO)

deploy-openobserve:
	helm upgrade --install openobserve openobserve/openobserve-standalone -f helm/openobserve/values.yaml --timeout 15m $(HELM_UPGRADE_FLAGS)

deploy-fluent-bit:
	helm upgrade --install fluent-bit fluent/fluent-bit -f helm/fluent-bit/values.yaml --timeout 15m $(HELM_UPGRADE_FLAGS)

setup-openobserve-dashboards:
	./scripts/setup-openobserve-dashboards.sh

deploy-ingress:
	kubectl apply -f manifests/ingress/local-ingress.yaml

cleanup-storage:
	./scripts/cleanup-storage.sh

deploy-cleanup-cronjob:
ifeq ($(OS),Darwin)
	@sed 's|/run/podman/podman.sock|/var/run/docker.sock|g' manifests/woodpecker/woodpecker-storage-cleanup-cronjob.yaml | kubectl apply -f -
else
	kubectl apply -f manifests/woodpecker/woodpecker-storage-cleanup-cronjob.yaml
endif

healthcheck:
	./scripts/healthcheck.sh

lint:
	./scripts/lint.sh

worktree:
	./scripts/worktree-helper.sh $(BRANCH) $(TARGET_DIR)

deploy-all: create-tls-secret deploy-ingress deploy-vault deploy-consul deploy-postgres setup-vault-secrets setup-consul-config deploy-gitea deploy-woodpecker-rbac setup-gitea-woodpecker deploy-woodpecker deploy-openobserve deploy-fluent-bit setup-openobserve-dashboards deploy-cleanup-cronjob

deploy-apps:
	kubectl apply -k manifests/apps/ilmiya-backend
	kubectl apply -k manifests/apps/ilmiya-frontend

start:
	@echo "Starting local registry and k3d cluster..."
ifeq ($(OS),Darwin)
	@docker start k3d-dev-cluster-server-0 || true
	@docker start k3d-dev-cluster-serverlb >/dev/null 2>&1 || true
	@docker start k3d-dev-registry || true
	@if docker ps -q -f name=k3d-dev-cluster-serverlb | grep -q .; then \
		for i in $$(seq 1 10); do \
			docker exec k3d-dev-cluster-serverlb nginx -s reload >/dev/null 2>&1 && break || sleep 1; \
		done; \
	fi
else
	@test -S /run/user/$$(id -u)/podman/podman.sock || systemctl --user restart podman.socket || true
	@podman start k3d-dev-cluster-server-0 || true
	@podman start k3d-dev-cluster-serverlb >/dev/null 2>&1 || true
	@podman start k3d-dev-registry || true
	@if podman ps -q -f name=k3d-dev-cluster-serverlb | grep -q .; then \
		for i in $$(seq 1 10); do \
			podman exec k3d-dev-cluster-serverlb nginx -s reload >/dev/null 2>&1 && break || sleep 1; \
		done; \
	fi
endif
	@echo "Waiting for cluster control-plane and nodes to become Ready..."
	@until kubectl wait --for=condition=Ready node --all --timeout=5s >/dev/null 2>&1; do sleep 2; done
	@echo "Cluster is ready."
	@kubectl get nodes

stop:
	@echo "Stopping k3d cluster and local registry..."
	@kubectl delete pod postgres-0 --wait=true --timeout=15s >/dev/null 2>&1 || true
ifeq ($(OS),Darwin)
	@docker stop -t 2 k3d-dev-cluster-serverlb >/dev/null 2>&1 || true
	@docker stop -t 30 k3d-dev-cluster-server-0 >/dev/null 2>&1 || docker kill k3d-dev-cluster-server-0 >/dev/null 2>&1 || true
	@docker stop -t 2 k3d-dev-registry >/dev/null 2>&1 || true
else
	@podman stop -t 2 k3d-dev-cluster-serverlb >/dev/null 2>&1 || true
	@podman stop -t 30 k3d-dev-cluster-server-0 >/dev/null 2>&1 || podman kill k3d-dev-cluster-server-0 >/dev/null 2>&1 || true
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
	$(MAKE) seed-images

seed-images:
	@echo "=== Seeding required images into local registry ==="
	@echo "--- Fluent Bit ---"
	docker pull cr.fluentbit.io/fluent/fluent-bit:3.2
	docker tag  cr.fluentbit.io/fluent/fluent-bit:3.2 localhost:5000/fluent-bit:latest
	docker push $(DOCKER_PUSH_FLAGS) localhost:5000/fluent-bit:latest

	@echo "--- OpenObserve ---"
	docker pull public.ecr.aws/zinclabs/openobserve:latest
	docker tag  public.ecr.aws/zinclabs/openobserve:latest localhost:5000/openobserve:latest
	docker push $(DOCKER_PUSH_FLAGS) localhost:5000/openobserve:latest

	@echo "--- BusyBox ---"
	docker pull busybox:1.36
	docker tag  busybox:1.36 localhost:5000/busybox:latest
	docker push $(DOCKER_PUSH_FLAGS) localhost:5000/busybox:latest

	@echo "--- Gitea ---"
	docker pull docker.io/gitea/gitea:latest
	docker tag  docker.io/gitea/gitea:latest localhost:5000/gitea:latest
	docker push $(DOCKER_PUSH_FLAGS) localhost:5000/gitea:latest

	@echo "--- Woodpecker CI Server & Agent ---"
	docker pull docker.io/woodpeckerci/woodpecker-server:v3.2.0
	docker tag  docker.io/woodpeckerci/woodpecker-server:v3.2.0 localhost:5000/woodpecker-server:latest
	docker push $(DOCKER_PUSH_FLAGS) localhost:5000/woodpecker-server:latest

	docker pull docker.io/woodpeckerci/woodpecker-agent:v3.2.0
	docker tag  docker.io/woodpeckerci/woodpecker-agent:v3.2.0 localhost:5000/woodpecker-agent:latest
	docker push $(DOCKER_PUSH_FLAGS) localhost:5000/woodpecker-agent:latest

	@echo "--- Semgrep ---"
	docker pull docker.io/semgrep/semgrep:latest
	docker tag  docker.io/semgrep/semgrep:latest localhost:5000/semgrep:latest
	docker push $(DOCKER_PUSH_FLAGS) localhost:5000/semgrep:latest

	@echo "--- Eclipse Temurin JDK 25 ---"
	docker pull docker.io/library/eclipse-temurin:25-jdk
	docker tag  docker.io/library/eclipse-temurin:25-jdk localhost:5000/eclipse-temurin:25-jdk
	docker push $(DOCKER_PUSH_FLAGS) localhost:5000/eclipse-temurin:25-jdk

	@echo "--- Kaniko Executor ---"
	docker pull gcr.io/kaniko-project/executor:debug
	docker tag  gcr.io/kaniko-project/executor:debug localhost:5000/kaniko:debug
	docker push $(DOCKER_PUSH_FLAGS) localhost:5000/kaniko:debug

	@echo "--- Flutter SDK ---"
	docker pull ghcr.io/cirruslabs/flutter:stable
	docker tag  ghcr.io/cirruslabs/flutter:stable localhost:5000/flutter:stable
	docker push $(DOCKER_PUSH_FLAGS) localhost:5000/flutter:stable
	@echo "=== Image seeding complete ==="

preload-images: seed-images
	@echo "=== Pre-pulling platform images into k3d cluster containerd cache ==="
	@for img in \
		docker.io/woodpeckerci/woodpecker-server:v3.2.0 \
		docker.io/woodpeckerci/woodpecker-agent:v3.2.0 \
		docker.io/gitea/gitea:latest \
		docker.io/hashicorp/vault:2.0.4 \
		docker.io/hashicorp/vault-k8s:1.7.6 \
		docker.io/hashicorp/consul:2.1.0 \
		docker.io/hashicorp/consul-k8s-control-plane:2.1.0 \
		docker.io/library/postgres:latest \
		docker.io/curlimages/curl:8.23.0 \
		k3d-dev-registry:5000/fluent-bit:latest \
		k3d-dev-registry:5000/openobserve:latest \
		k3d-dev-registry:5000/busybox:latest \
		k3d-dev-registry:5000/semgrep:latest \
		k3d-dev-registry:5000/eclipse-temurin:25-jdk \
		k3d-dev-registry:5000/kaniko:debug \
		k3d-dev-registry:5000/flutter:stable; do \
		echo "--> Pulling $$img..."; \
		docker exec k3d-dev-cluster-server-0 crictl pull "$$img" || true; \
	done
	@echo "=== Platform images pre-pull complete ==="

cluster-down:
	k3d cluster delete dev-cluster || true
	k3d registry delete dev-registry || true
