# Local DevOps Lab (k3d + Jenkins + ArgoCD + SonarQube + Vault + Consul + PostgreSQL)

This repository sets up a complete, rootless-compatible local Kubernetes DevOps platform containing:
- **k3d (k3s in Docker/Podman)** with built-in Traefik Ingress Controller
- **Local Container Registry** (`localhost:5000` from host, `k3d-dev-registry:5000` from cluster)
- **Jenkins CI/CD** with dynamic Kubernetes Pod agents and Kaniko builders
- **ArgoCD GitOps CD** for declarative Kubernetes deployment and drift reconciliation
- **SonarQube** for automated code quality, security analysis, and Quality Gate enforcement
- **PostgreSQL Latest** database service with automatic application user/database initialization
- **HashiCorp Vault** (with Vault Agent Injector for secret injection)
- **HashiCorp Consul** (Service discovery & mesh)
- **Clean Standard Ports & Zero-Warning TLS**: Standard ports `80` (HTTP) and `443` (HTTPS) with `mkcert` root CA certificates

---

## Service URLs & Credentials

All services run on **standard ports (80 / 443)** with **valid local TLS certificates**:

| Service | Local URL | Credentials / Tokens |
| :--- | :--- | :--- |
| **Jenkins CI/CD** | [https://jenkins.localhost](https://jenkins.localhost) | User: `admin` <br> Password: `admin123` |
| **ArgoCD GitOps** | [https://argocd.localhost](https://argocd.localhost) | User: `admin` <br> Password: `admin123` |
| **SonarQube** | [https://sonar.localhost](https://sonar.localhost) | User: `admin` <br> Password: `admin` |
| **PostgreSQL** | `postgres:5432` (k8s) <br> `localhost:5432` (host) | Superuser: `postgres` / `P0stgr3s_L4b_Adm!n#2026`<br>Ilmiya DB: `ilmiya_db` / `ilmiya_user` / `Ilm!y4_Db_P@ss2026#Secure`<br>Uwati DB: `uwati` / `uwati` / `Uwat!_Db_P@ss2026#Secure` |
| **HashiCorp Vault** | [https://vault.localhost/ui](https://vault.localhost/ui) | Method: `Token` <br> Token: `root` |
| **HashiCorp Consul** | [https://consul.localhost/ui](https://consul.localhost/ui) | Service Discovery & Key-Value |
| **Local Registry** | [http://localhost:5000/v2/_catalog](http://localhost:5000/v2/_catalog) | Docker registry endpoint |

> **Note on Local Domains**: All modern Linux operating systems and web browsers automatically resolve any `*.localhost` domain to `127.0.0.1` (per RFC 6761). No `/etc/hosts` changes are required.

---

## Architecture & Setup Guide

For a comprehensive step-by-step installation, rootless cgroup delegation, sysctl port binding, and browser NSS trust store configuration, see:
- [Complete Environment Setup Guide](docs/SETUP_GUIDE.md)

---

## Quick Commands (`Makefile`)

```bash
# Check status of cluster nodes, pods, and ingress
make status

# Display the dashboard URLs and passwords
make urls

# Generate local wildcard TLS certificates (mkcert)
make generate-certs

# Deploy or upgrade PostgreSQL
make deploy-postgres

# Deploy or upgrade ArgoCD
make deploy-argocd

# Deploy or upgrade SonarQube
make deploy-sonarqube

# Seed centralized local deployment pipeline jobs into Jenkins
make seed-jobs

# Re-deploy all platform services, TLS, and Ingress
make deploy-all

# Stop and delete cluster & registry
make cluster-down

# Re-create cluster & registry from scratch
make cluster-up
```
