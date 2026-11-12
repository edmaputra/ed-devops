# Local DevOps Lab (k3d + Jenkins + ArgoCD + SonarQube + Vault + Consul + PostgreSQL + OpenObserve)

Runs on **Linux** (Rootless Podman) and **macOS** (OrbStack). Sets up a complete local Kubernetes DevOps platform containing:

- **k3d (k3s in Docker/Podman)** with built-in Traefik Ingress Controller
- **Local Container Registry** (`localhost:5000` from host, `k3d-dev-registry:5000` from cluster)
- **Jenkins CI/CD** with dynamic Kubernetes Pod agents and Kaniko builders
- **ArgoCD GitOps CD** for declarative Kubernetes deployment and drift reconciliation
- **SonarQube** for automated code quality, security analysis, and Quality Gate enforcement
- **OpenObserve** for cloud-native unified observability (logs, metrics, traces, and dashboards)
- **PostgreSQL Latest** database service with automatic application user/database initialization
- **HashiCorp Vault** (with Vault Agent Injector for secret injection)
- **HashiCorp Consul** (Service discovery & mesh)
- **Clean Standard Ports & Zero-Warning TLS**: Standard ports `80` (HTTP) and `443` (HTTPS) with `mkcert` root CA certificates

---

## Getting Started

### 🍎 macOS (OrbStack)

> **Prerequisite**: Install [OrbStack](https://orbstack.dev) (free for personal use) and [Homebrew](https://brew.sh). OrbStack provides the Docker-compatible container backend — no Podman needed.

```bash
# Step 1 — One-time setup: installs k3d, helm, mkcert, jq via Homebrew,
#           configures *.localhost DNS, and installs the local root CA.
./scripts/setup-macos.sh

# Step 2 — Generate local wildcard TLS certificates
make generate-certs

# Step 3 — Create the k3d cluster (auto-selects k3d-config.macos.yaml)
make cluster-up

# Step 4 — Deploy all platform services
make create-tls-secret
make deploy-all

# Step 5 — Verify everything is healthy
make healthcheck
```

See [docs/MACOS_SETUP.md](docs/MACOS_SETUP.md) for the full macOS guide and troubleshooting.

---

### 🐧 Linux (Rootless Podman)

> **Prerequisite**: Ubuntu/Fedora with Podman installed and rootless configured (cgroup v2 delegation + unprivileged ports). See [docs/SETUP_GUIDE.md](docs/SETUP_GUIDE.md) §2 for the full host configuration steps.

```bash
# Step 1 — Enable the Podman socket for the current user
systemctl --user enable --now podman.socket
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"

# Step 2 — Install CLI tools (kubectl, helm, k3d, mkcert)
#           Follow docs/SETUP_GUIDE.md §3 for binary installation steps.

# Step 3 — Add Helm repositories
helm repo add hashicorp   https://helm.releases.hashicorp.com
helm repo add jenkins     https://charts.jenkins.io
helm repo add argo        https://argoproj.github.io/argo-helm
helm repo add sonarqube   https://SonarSource.github.io/helm-chart-sonarqube
helm repo add openobserve https://charts.openobserve.ai
helm repo add fluent      https://fluent.github.io/helm-charts
helm repo update

# Step 4 — Generate local wildcard TLS certificates
make generate-certs

# Step 5 — Create the k3d cluster (auto-selects k3d-config.yaml)
make cluster-up

# Step 6 — Deploy all platform services
make create-tls-secret
make deploy-all

# Step 7 — Verify everything is healthy
make healthcheck
```

See [docs/SETUP_GUIDE.md](docs/SETUP_GUIDE.md) for the full Linux guide including cgroup delegation, unprivileged port config, and the k3d wrapper script.

---

## How the Makefile Detects Your OS

The `Makefile` auto-detects the OS via `uname -s` and selects the right config and container runtime — **no manual flags needed**:

| | Linux | macOS |
|:---|:---|:---|
| **Container runtime** | `podman` | `docker` (OrbStack) |
| **k3d config** | `k3d-config.yaml` | `k3d-config.macos.yaml` |
| **`DOCKER_HOST`** | `unix://$XDG_RUNTIME_DIR/podman/podman.sock` | `unix://$HOME/.orbstack/run/docker.sock` |
| **Registry network** | `--default-network podman` | `--default-network bridge` |
| **CronJob socket** | `/run/podman/podman.sock` | `/var/run/docker.sock` (patched inline) |

---

## Service URLs & Credentials

All services run on **standard ports (80 / 443)** with **valid local TLS certificates**:

| Service | Local URL | Credentials / Tokens |
| :--- | :--- | :--- |
| **Jenkins CI/CD** | [https://jenkins.localhost](https://jenkins.localhost) | User: `admin` / Password: `admin123` |
| **ArgoCD GitOps** | [https://argocd.localhost](https://argocd.localhost) | User: `admin` / Password: `admin123` |
| **SonarQube** | [https://sonar.localhost](https://sonar.localhost) | User: `admin` / Password: `admin` |
| **OpenObserve** | [https://openobserve.localhost](https://openobserve.localhost) | User: `admin@example.com` / Password: `DevOps_OpenObserve#2026` |
| **PostgreSQL** | `postgres:5432` (k8s) / `localhost:5432` (host) | Superuser: `postgres` / `P0stgr3s_L4b_Adm!n#2026`<br>Ilmiya DB: `ilmiya_db` / `ilmiya_user` / `Ilm!y4_Db_P@ss2026#Secure`<br>Uwati DB: `uwati` / `uwati` / `Uwat!_Db_P@ss2026#Secure` |
| **HashiCorp Vault** | [https://vault.localhost/ui](https://vault.localhost/ui) | Method: `Token` / Token: `root` |
| **HashiCorp Consul** | [https://consul.localhost/ui](https://consul.localhost/ui) | Service Discovery & Key-Value |
| **Local Registry** | [http://localhost:5000/v2/_catalog](http://localhost:5000/v2/_catalog) | Docker registry endpoint |

> **Note on Local Domains**:
> - **Linux**: `*.localhost` resolves automatically to `127.0.0.1` (RFC 6761). No `/etc/hosts` changes needed.
> - **macOS**: `setup-macos.sh` creates `/etc/resolver/localhost` so `mDNSResponder` resolves `*.localhost` → `127.0.0.1`.

---

## Architecture, Features & Roadmap

- [Complete Linux Setup Guide](docs/SETUP_GUIDE.md)
- [macOS Setup Guide (OrbStack)](docs/MACOS_SETUP.md)
- [Features and Strategic Roadmap](docs/FEATURES_AND_ROADMAP.md)

---

## Daily-Use Commands

```bash
# Start an existing cluster & registry (preserves all data/apps)
make start

# Stop cluster & registry without losing data
make stop

# Check cluster nodes, pods, and ingress
make status

# Display dashboard URLs and credentials
make urls

# Run comprehensive health check (cluster, APIs, TLS, DB)
make healthcheck
```

## Cluster Lifecycle

```bash
# Create cluster & registry from scratch
make cluster-up

# Destroy cluster & registry (data is lost)
make cluster-down

# Generate local wildcard TLS certificates
make generate-certs

# Upload TLS certificate as a Kubernetes secret
make create-tls-secret

# Deploy all platform services in one shot
make deploy-all
```

## Individual Service Deployment

```bash
make deploy-vault          # HashiCorp Vault
make setup-vault-secrets   # Configure Vault auth & secrets

make deploy-consul         # HashiCorp Consul
make setup-consul-config   # Seed Consul KV config

make deploy-postgres       # PostgreSQL

make deploy-jenkins        # Jenkins CI/CD
make deploy-jenkins-rbac   # RBAC for dynamic agent pods
make seed-jobs             # Seed pipeline jobs into Jenkins

make deploy-argocd         # ArgoCD GitOps
make deploy-argocd-apps    # Apply ArgoCD Application manifests

make deploy-sonarqube      # SonarQube
make setup-sonarqube-rules # Java/Kotlin profiles & 80% Quality Gate

make deploy-openobserve             # OpenObserve observability
make deploy-fluent-bit              # Fluent Bit log shipper
make setup-openobserve-dashboards   # Provision dashboards

make deploy-ingress        # Apply Traefik Ingress rules
```

## Maintenance & Tooling

```bash
# Lint: Helm, YAML, shell scripts, Kubernetes manifests
make lint

# Prune Jenkins builds, container images, and volumes
make cleanup-storage

# Deploy the scheduled autonomous cleanup CronJob to Kubernetes
make deploy-cleanup-cronjob

# Create a new git worktree safely synced from origin/main
make worktree BRANCH=feat/my-feature

# macOS only: install all tools and configure the environment
make setup-macos
```

---

## Autonomous Storage & Build Cleanup Mechanism

To prevent disk saturation and continuously reclaim storage, the platform includes a multi-layered autonomous cleanup architecture:

1. **Job-Level Build Discarder (`logRotator`)**:
   - `deploy-ilmiya-backend` and `deploy-ilmiya-frontend` pipelines are configured with `buildDiscarder` to automatically retain only the **10 most recent builds** (max age **2 days**, max **5 artifact runs**).

2. **Jenkins Global Build Discarder (JCasC)**:
   - Configured in [helm/jenkins/values.yaml](helm/jenkins/values.yaml) via Jenkins Configuration as Code (`SimpleGlobalBuildDiscarderStrategy`), enforcing a global safety limit on all jobs.

3. **Scheduled Jenkins Maintenance Pipeline (`system-storage-cleanup`)**:
   - Seeded automatically via `make seed-jobs` from [pipelines/autonomous-storage-cleanup.groovy](pipelines/autonomous-storage-cleanup.groovy).
   - Runs automatically on a daily cron schedule (`H 2 * * *`) or manually with parameter overrides (`MAX_BUILDS_TO_KEEP`, `DAYS_TO_KEEP`, `IMAGE_RETENTION_HOURS`, etc.).
   - Prunes build records across all jobs and connects to the container engine socket to prune dangling images, unreferenced images older than 72 hours, stopped containers, and unattached volumes.

4. **Kubernetes Scheduled CronJob (`jenkins-storage-cleanup`)**:
   - Declared in [manifests/jenkins/jenkins-storage-cleanup-cronjob.yaml](manifests/jenkins/jenkins-storage-cleanup-cronjob.yaml) and deployed via `make deploy-cleanup-cronjob`.
   - Runs autonomously in the cluster daily at `02:00 UTC` without requiring external triggers.
   - On **macOS**, `make deploy-cleanup-cronjob` automatically patches the socket path to `/var/run/docker.sock` (OrbStack).

5. **Manual CLI Execution (`make cleanup-storage`)**:
   - Run [scripts/cleanup-storage.sh](scripts/cleanup-storage.sh) anytime via `make cleanup-storage` to instantly prune builds, container images, volumes, and k3d CRI containerd cache.
   - Auto-detects `podman` (Linux) or `docker` (macOS/OrbStack).

