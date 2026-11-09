.PHONY: help status cluster-up cluster-down deploy-vault deploy-consul deploy-postgres setup-vault-secrets setup-consul-config deploy-jenkins deploy-argocd deploy-sonarqube deploy-ingress deploy-jenkins-rbac seed-jobs deploy-all urls generate-certs create-tls-secret

help:
	@echo "Available commands:"
	@echo "  make status              - Show cluster status, pods, and ingress"
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
	@echo "  make deploy-ingress      - Apply local Ingress configuration"
	@echo "  make deploy-jenkins-rbac - Apply RBAC for Jenkins dynamic build agents"
	@echo "  make seed-jobs           - Seed centralized local deployment pipeline jobs into Jenkins"
	@echo "  make deploy-all          - Deploy all platform services, TLS, and ingress"
	@echo "  make cluster-up          - Create k3d cluster with local registry"
	@echo "  make cluster-down        - Destroy k3d cluster and registry"

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
	@echo " Vault      : https://vault.localhost/ui  (Root Token: root)"
	@echo " Consul     : https://consul.localhost/ui"
	@echo " PostgreSQL : postgres:5432 / localhost:5432 (Admin: postgres / P0stgr3s_L4b_Adm!n#2026 | ilmiya_db: ilmiya_user / Ilm!y4_Db_P@ss2026#Secure | uwati: uwati / Uwat!_Db_P@ss2026#Secure)"
	@echo " Registry   : http://localhost:5000/v2/_catalog"
	@echo "=========================================================="

generate-certs:
	mkdir -p certs
	mkcert -cert-file certs/local-cert.pem -key-file certs/local-key.pem \
		localhost "*.localhost" vault.localhost consul.localhost jenkins.localhost argocd.localhost sonar.localhost sonarqube.localhost

create-tls-secret:
	kubectl create secret tls local-wildcard-tls --cert=certs/local-cert.pem --key=certs/local-key.pem --dry-run=client -o yaml | kubectl apply -f -

deploy-vault:
	helm upgrade --install vault hashicorp/vault -f helm/vault/values.yaml --timeout 15m

deploy-consul:
	helm upgrade --install consul hashicorp/consul -f helm/consul/values.yaml --timeout 15m

deploy-postgres:
	helm upgrade --install postgres helm/postgres --timeout 15m

setup-vault-secrets:
	./scripts/setup-vault-secrets.sh

setup-consul-config:
	./scripts/setup-consul-config.sh

deploy-jenkins:
	helm upgrade --install jenkins jenkins/jenkins -f helm/jenkins/values.yaml --timeout 15m

deploy-argocd:
	helm upgrade --install argocd argo/argo-cd -f helm/argocd/values.yaml --timeout 15m

deploy-sonarqube:
	helm upgrade --install sonarqube sonarqube/sonarqube -f helm/sonarqube/values.yaml --timeout 15m

deploy-ingress:
	kubectl apply -f manifests/ingress/local-ingress.yaml

deploy-jenkins-rbac:
	kubectl apply -f manifests/jenkins/jenkins-deployer-rbac.yaml

seed-jobs:
	./scripts/seed-jenkins-jobs.sh

deploy-all: deploy-vault deploy-consul deploy-postgres setup-vault-secrets setup-consul-config deploy-jenkins deploy-jenkins-rbac deploy-argocd deploy-sonarqube create-tls-secret deploy-ingress seed-jobs

cluster-up:
	k3d registry create --default-network podman dev-registry --port 0.0.0.0:5000 || true
	k3d cluster create --config k3d-config.yaml

cluster-down:
	k3d cluster delete dev-cluster || true
	k3d registry delete dev-registry || true
