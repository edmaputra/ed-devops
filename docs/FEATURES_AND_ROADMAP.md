# Features and Roadmap: Local Kubernetes DevOps Laboratory

This document outlines the architectural features, current capabilities, and strategic roadmap for the `ed-devops` local Kubernetes platform.

---

## 1. Executive Summary & Architecture Vision

`ed-devops` is an enterprise-grade, rootless-compatible local DevOps and GitOps platform. It simulates real-world production engineering environments on a local workstation using lightweight, open-source technologies:
- **Zero-Warning Local TLS** (`mkcert`) on **Standard Ports (`80` / `443`)**
- **Rootless Podman + k3d (k3s)** with cgroup v2 delegation
- **In-Cluster CI/CD Engine** (Jenkins with dynamic Kubernetes agent pods & Kaniko rootless image builds)
- **GitOps Continuous Delivery** (ArgoCD with automated drift reconciliation)
- **Code Quality & Security Governance** (SonarQube with strict 80% coverage quality gates)
- **Enterprise Secret & Config Management** (HashiCorp Vault with Kubernetes Auth & Consul KV)
- **Autonomous Resource Maintenance** (Scheduled build discarding, image pruning, and volume cleanup)

```mermaid
graph TD
    User([Developer / Browser]) -->|HTTPS Port 443 / HTTP Port 80| Traefik[Traefik Ingress Controller]
    
    subgraph K3sCluster [k3d Kubernetes Cluster: dev-cluster]
        Traefik --> Jenkins[Jenkins CI/CD]
        Traefik --> ArgoCD[ArgoCD GitOps]
        Traefik --> SonarQube[SonarQube Quality Gate]
        Traefik --> OpenObserve[OpenObserve Unified Observability]
        Traefik --> Vault[HashiCorp Vault]
        Traefik --> Consul[HashiCorp Consul]
        Traefik --> Apps[Applications: Backend & Frontend]
        
        K3sCluster -.->|Pod Logs & Node Metrics| FluentBit[Fluent Bit DaemonSet]
        FluentBit -->|HTTP Ingest| OpenObserve
        
        Jenkins -->|Ephemeral Pods| Kaniko[Kaniko Builder]
        Kaniko -->|Push Images| Registry[Local Registry :5000]
        ArgoCD -->|Reconcile State| Apps
        Vault -->|Inject Secrets| Apps
    end
```

---

## 2. Platform Capability Matrix

| Capability | Current State | Target Future State | Status |
| :--- | :--- | :--- | :--- |
| **Container Engine** | Rootless Podman 4/5 + k3d | Rootless Podman + k3d | ✅ Implemented |
| **Ingress & Networking** | Traefik Ingress (Ports 80/443), mkcert TLS | Gateway API / Traefik Ingress | ✅ Implemented |
| **CI Engine** | Jenkins JCasC + Ephemeral Agent Pods | Jenkins + Shared Library | 🟡 In Progress |
| **Build Optimization** | Gradle PVC Cache, Kaniko builders | Kaniko Registry Caching, Flutter Pub Cache | 🟡 In Progress |
| **Code Quality** | SonarQube + 80% coverage Quality Gate | SonarQube + Dynamic Credentials | 🟡 In Progress |
| **GitOps CD** | ArgoCD Raw Manifests | ArgoCD + Kustomize Overlays + Image Updater | ⚪ Planned |
| **Secret Management** | Vault KV-v2 + K8s Auth Injector | Vault Auto-rotation & Dynamic DB Credentials | 🟡 Implemented |
| **Observability** | OpenObserve + Fluent Bit (Unified Logs & Metrics) | OpenObserve Tracing & Alerting Rules | ✅ Implemented |
| **Storage Lifecycle** | Autonomous Build & Image Cleanup CronJob | Autonomous Cleanup + Metrics Alerting | ✅ Implemented |
| **Developer Experience** | Makefile commands (`start`, `stop`, `urls`) | One-click healthcheck, linting, worktree helpers | ⚪ Planned |

---

## 3. Strategic Improvement Roadmap

### Milestone 1: CI/CD Build Optimization & Performance (Current Focus)
**Objective**: Drastically reduce build times, preserve network bandwidth, and provide rich test analytics.

1. **Kaniko Remote Layer Caching**:
   - Enable `--cache=true` and `--cache-repo=k3d-dev-registry:5000/kaniko-cache` in Jenkins pipelines.
   - Cache intermediate Dockerfile layers (e.g. OS dependencies, Flutter SDK, Gradle base image) directly inside the local registry.
   - Accelerate container build times by 5x to 10x for recurring commits.
2. **Persistent Volume Caching for Frontend (Flutter Pub Cache)**:
   - Provide persistent storage for Flutter packages (`/root/.pub-cache`) similar to `jenkins-gradle-cache-pvc`.
   - Prevent re-downloading Flutter dependencies on every build.
3. **JUnit Test Report Analytics**:
   - Integrate `junit` test archiving into backend deployment pipelines.
   - Expose test execution trends, pass/fail ratios, and failure stack traces directly on the Jenkins dashboard.
4. **Credential Decoupling**:
   - Transition hardcoded SonarQube tokens from pipeline parameters to Jenkins Credentials (`sonar-token`) and HashiCorp Vault.

---

### Milestone 2: Developer Experience (DX) & Quality Assurance
**Objective**: Enhance developer workflow velocity and provide automated verification.

1. **Unified Health Check (`make healthcheck`)**:
   - Provide a comprehensive health verification script that validates:
     - All Ingress routes and TLS certificates (`*.localhost`)
     - Jenkins REST API & agent pod spawning
     - ArgoCD application synchronization status
     - SonarQube system health
     - Vault unseal state & Kubernetes auth
     - PostgreSQL database ping and user connections
2. **Automated Worktree Helper (`make worktree BRANCH=<name>`)**:
   - Prevent stale branches by ensuring `origin/main` is automatically fetched and fast-forwarded before creating isolated worktrees.
3. **Static Analysis & Linting (`make lint`)**:
   - Integrate `helm lint` across all platform charts.
   - Add `kubeconform` / `kube-linter` to validate Kubernetes YAML manifests.
   - Add `shellcheck` validation for automation scripts in `scripts/`.

---

### Milestone 3: Observability & Telemetry Stack (Implemented)
**Objective**: Full visibility into cluster resource consumption, application performance, and access logs.

1. **Unified Observability (OpenObserve)**:
   * Single standalone Rust-powered engine (`https://openobserve.localhost`) combining Logs, Metrics, Traces, and Dashboards.
   * Extremely lightweight (~200MB RAM) running locally on k3d with zero-warning TLS.
   * Native Parquet columnar storage with SQL and PromQL querying capabilities.

2. **Automated Log & Metric Ingestion (Fluent Bit)**:
   * DaemonSet forwarding all Kubernetes container stdout/stderr logs across all namespaces into OpenObserve stream `k8s_logs`.
   * Node and pod resource metrics forwarded into OpenObserve stream `k8s_metrics`.

3. **Application & Infrastructure Telemetry**:
   * Scrapes Traefik ingress metrics and health endpoints.
   * Ready for Spring Boot Actuator Micrometer metrics ingestion from `ilmiya-backend`.

---

### Milestone 4: GitOps Standardization & Manifest Architecture
**Objective**: Eliminate imperative rollouts and achieve fully automated GitOps synchronization.

1. **Kustomize / Helm App Manifests**:
   - Refactor `manifests/apps/ilmiya-backend` and `manifests/apps/ilmiya-frontend` from static manifests to structured Kustomize bases and overlays.
   - Standardize resource limits, environment variables, and ingress rules across microservices.
2. **ArgoCD Image Updater**:
   - Deploy ArgoCD Image Updater to continuously track new tags pushed to `k3d-dev-registry:5000`.
   - Automatically reconcile deployments in Kubernetes without manual `kubectl rollout restart` triggers.

---

### Milestone 5: Database Resilience & Disaster Recovery
**Objective**: Guarantee state persistence, safety, and smooth schema evolution.

1. **Automated PostgreSQL Backup & Retention**:
   - Implement scheduled `pg_dump` backups with gzip compression.
   - Support automated restore verification drills.
2. **Database Migration Pre-Flight Checks**:
   - Add automated Flyway/Liquibase schema validation in CI pipelines before triggering application rollouts.
