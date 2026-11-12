# macOS Setup Guide

This guide covers running the full Local Kubernetes DevOps Lab on **macOS** (Apple Silicon arm64 or Intel x86_64) using **OrbStack** as the container backend instead of rootless Podman.

---

## Why OrbStack Instead of Podman on macOS?

On Linux, Podman runs containers natively and rootlessly using the kernel's user-namespace features. On macOS, containers always run inside a lightweight VM — both Podman Machine and Docker Desktop do this, but **OrbStack** provides the best developer experience:

| Feature | Podman Machine | Docker Desktop | **OrbStack** |
|:---|:---:|:---:|:---:|
| Docker-compatible API | ✓ | ✓ | ✓ |
| k3d compatibility | ✓ | ✓ | ✓ |
| Performance (Apple Silicon) | Moderate | Moderate | **Excellent** |
| Rosetta 2 / multi-arch | Manual | Manual | **Built-in** |
| Free for personal use | ✓ | Limited | ✓ |
| Memory footprint | High | High | **Low** |
| Startup time | ~15 s | ~20 s | **~2 s** |

> [!NOTE]
> This project uses OrbStack's Docker-compatible socket (`/var/run/docker.sock` → `~/.orbstack/run/docker.sock`). No Podman installation is needed on macOS.

---

## 1. Install Prerequisites

### Step 1.1: Install Homebrew
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### Step 1.2: Install OrbStack
Download from **[https://orbstack.dev](https://orbstack.dev)** and install. Launch it from your Applications folder. OrbStack will create:
- `/var/run/docker.sock` → `~/.orbstack/run/docker.sock` (symlink)
- A fast, low-footprint Linux VM for container workloads

### Step 1.3: Run the macOS Setup Script
This single script installs all CLI tools, configures DNS, and sets up TLS trust:

```bash
./scripts/setup-macos.sh
```

This script installs: `k3d`, `helm`, `kubectl`, `mkcert`, `jq` via Homebrew, then:
- Adds `DOCKER_HOST` pointing to OrbStack's socket in your shell RC file
- Creates `/etc/resolver/localhost` for `*.localhost` DNS resolution (see below)
- Runs `mkcert -install` to trust the local root CA
- Adds all required Helm chart repositories

---

## 2. macOS-Specific: `*.localhost` DNS Resolution

> [!IMPORTANT]
> Unlike Linux (which follows RFC 6761 and resolves `*.localhost` automatically), **macOS does not** resolve `*.localhost` subdomains to `127.0.0.1` by default. The setup script handles this automatically, but here is what it does:

macOS uses a directory-based DNS resolver (`/etc/resolver/`) that is read by `mDNSResponder`. The script creates `/etc/resolver/localhost` with:

```
nameserver 127.0.0.1
port 53
```

This tells macOS to resolve **all `.localhost` subdomains** using localhost's DNS, which falls back to `127.0.0.1`. After running the setup script, verify it works:

```bash
# After cluster-up, all of these should resolve:
ping -c 1 jenkins.localhost
ping -c 1 argocd.localhost
ping -c 1 vault.localhost
```

If ping still fails, flush the DNS cache:
```bash
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
```

---

## 3. Cluster Architecture Differences on macOS

The macOS k3d cluster config (`k3d-config.macos.yaml`) differs from the Linux one in two key ways:

### 3.1: No Podman Socket Mount
Linux mounts the Podman socket into the k3d node so Jenkins build agents can run containers for Testcontainers. On macOS with OrbStack:
- The OrbStack socket is a macOS filesystem socket — it **cannot be bind-mounted** into k3d container nodes directly.
- Jenkins agents that need Testcontainers use a **`docker:dind` sidecar** in the agent pod spec instead.

### 3.2: No `KubeletInUserNamespace` Feature Gate
The Linux config includes `--kubelet-arg=feature-gates=KubeletInUserNamespace=true` to support rootless Podman. Under OrbStack, containers run as root inside the VM, so this is not needed.

---

## 4. Quick Start

```bash
# 1. One-time setup (installs tools, configures DNS & TLS trust)
./scripts/setup-macos.sh

# 2. Generate local wildcard TLS certificates
make generate-certs

# 3. Create the k3d cluster (uses k3d-config.macos.yaml automatically on macOS)
make cluster-up

# 4. Apply TLS secret and deploy all platform services
make create-tls-secret
make deploy-all

# 5. Verify everything is healthy
make healthcheck

# 6. Display service URLs and credentials
make urls
```

---

## 5. Helm Repository Setup

If you skipped the setup script, add repos manually:

```bash
helm repo add hashicorp   https://helm.releases.hashicorp.com
helm repo add jenkins     https://charts.jenkins.io
helm repo add argo        https://argoproj.github.io/argo-helm
helm repo add sonarqube   https://SonarSource.github.io/helm-chart-sonarqube
helm repo add openobserve https://charts.openobserve.ai
helm repo add fluent      https://fluent.github.io/helm-charts
helm repo update
```

---

## 6. Testcontainers in Jenkins Agent Pods (macOS)

Since the OrbStack socket cannot be bind-mounted into k3d nodes, use the `docker:dind` sidecar pattern in the pipeline's `podTemplate`:

```groovy
podTemplate(containers: [
  containerTemplate(
    name: 'gradle',
    image: 'gradle:jdk25',
    env: [
      envVar(key: 'DOCKER_HOST',              value: 'tcp://localhost:2375'),
      envVar(key: 'DOCKER_TLS_VERIFY',        value: '0'),
      envVar(key: 'TESTCONTAINERS_HOST_OVERRIDE', value: 'localhost'),
    ]
  ),
  containerTemplate(
    name: 'dind',
    image: 'docker:dind',
    privileged: true,
    env: [envVar(key: 'DOCKER_TLS_CERTDIR', value: '')]
  ),
]) { ... }
```

This is already the documented pattern in the main `SETUP_GUIDE.md` §4 and works identically on both Linux and macOS.

---

## 7. Troubleshooting (macOS-Specific)

### `k3d cluster create` fails with "no such host" or socket error
Ensure OrbStack is running and `DOCKER_HOST` is set:
```bash
export DOCKER_HOST="unix://$HOME/.orbstack/run/docker.sock"
docker info   # should show OrbStack
```

### `*.localhost` not resolving in browser after `make cluster-up`
1. Verify the resolver file: `cat /etc/resolver/localhost`
2. Flush DNS: `sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder`
3. Check that ports 80/443 are bound: `kubectl get svc -A | grep LoadBalancer`

### `net::ERR_CERT_AUTHORITY_INVALID` in Safari / Chrome
Run `mkcert -install` and completely quit and reopen your browser (Cmd+Q, not just close the window).

### Ports 80/443 already in use
macOS does not restrict low ports for containers (OrbStack's VM handles binding). If you get a port conflict, check for other services:
```bash
sudo lsof -i :80 -i :443
```
Common culprits: Apache (`apachectl stop`), Nginx, another Docker Compose project.

### `make cleanup-storage` on macOS
The script auto-detects `docker` vs `podman` and uses whichever is available. Under OrbStack, `docker` is used. The k3d containerd CRI prune still works via `docker exec k3d-dev-cluster-server-0 crictl rmi --prune`.
