# Complete Step-by-Step Setup Guide: Local Kubernetes DevOps Laboratory

This guide explains in detail how the entire local DevOps platform is architected and built from scratch using **k3d**, **Rootless Podman**, **Jenkins**, **HashiCorp Vault**, **HashiCorp Consul**, **mkcert Local TLS**, and **Traefik Ingress**.

---

## 1. Architectural Overview

```mermaid
graph TD
    User([Browser / Developer]) -->|HTTPS Port 443 / HTTP Port 80| Traefik[Traefik Ingress Controller<br/>Ports 80 & 443 with local-wildcard-tls]
    
    subgraph Host [Host Machine - Ubuntu Linux / Rootless Podman]
        subgraph PodmanNet [Podman Network: podman]
            Reg[Local Container Registry<br/>k3d-dev-registry:5000]
            
            subgraph K3sCluster [k3d Kubernetes Cluster: dev-cluster]
                Traefik -->|https://jenkins.localhost| Jenkins[Jenkins Controller<br/>Port 8080]
                Traefik -->|https://vault.localhost| Vault[HashiCorp Vault<br/>Port 8200]
                Traefik -->|https://consul.localhost| Consul[HashiCorp Consul<br/>Port 80]
                
                Traefik -->|https://ilmiya.localhost/| Frontend[Flutter Web / Nginx<br/>Port 80]
                Traefik -->|https://ilmiya.localhost/api| Backend[Kotlin Spring Boot<br/>Port 8080]
                
                Backend -->|jdbc:postgresql| Postgres[PostgreSQL 17<br/>Port 5432]
                
                Jenkins -.->|Dynamic agent pods via Kaniko| K8sAgents[Kubernetes Build Agents]
                K8sAgents -.->|Push Images| Reg
                
                VaultInjector[Vault Agent Injector] -.->|Injects Secrets| Backend
            end
        end
    end
```

### Key Architectural Decisions
1. **Clean URLs on Standard Ports**: All traffic runs on standard port `80` (HTTP) and `443` (HTTPS). No explicit ports like `:8080` or `:3000` in the browser.
2. **Zero-Warning Local TLS (`mkcert`)**: Root CA installed in system and browser NSS trust stores, generating valid certificates with explicit SANs for `*.localhost`.
3. **Single Origin Microservices (Zero CORS)**: Flutter Web (`/`) and Spring Boot API (`/api`) share `https://ilmiya.localhost`, completely eliminating Cross-Origin Resource Sharing (CORS) blocks and preflight delays.
4. **Rootless Podman Compatibility**: 100% daemonless, rootless container execution with cgroup v2 delegation and unprivileged port access.
5. **In-Cluster Dynamic Builds**: Jenkins uses ephemeral Kubernetes Pods running **Kaniko** to compile and push images without needing Docker-in-Docker or root permissions.

---

## 2. Host Prerequisites & Rootless Configuration

### Step 2.1: Enable Cgroup v2 `cpuset` Delegation
By default, Ubuntu user sessions only delegate `cpu memory pids`. Kubelet requires the `cpuset` controller to manage CPU core allocations.

```bash
sudo mkdir -p /etc/systemd/system/user@.service.d
sudo tee /etc/systemd/system/user@.service.d/delegate.conf << 'EOF'
[Service]
Delegate=cpu cpuset io memory pids
EOF

sudo systemctl daemon-reload
systemctl --user daemon-reexec
```
*Verification:*
```bash
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/cgroup.controllers
# Output must include: cpuset cpu io memory pids
```

### Step 2.2: Enable Unprivileged Port 80 & 443 Binding
Linux restricts ports below 1024 to root. To allow rootless Podman to bind ports `80` and `443`:

```bash
sudo tee /etc/sysctl.d/99-rootless.conf << 'EOF'
net.ipv4.ip_unprivileged_port_start=80
EOF

sudo sysctl --system
```
*Verification:*
```bash
cat /proc/sys/net/ipv4/ip_unprivileged_port_start
# Output must be: 80
```

### Step 2.3: Podman Docker-Compatible Socket
k3d interacts with container engines via the Docker REST API. Ensure the user socket is running:
```bash
systemctl --user enable --now podman.socket
```

Set environment variables in `~/.bashrc`:
```bash
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
export DOCKER_SOCK="$XDG_RUNTIME_DIR/podman/podman.sock"
```

---

## 3. Tooling Installation

Install all required command-line tools into `~/bin/` (or `/usr/local/bin/`):

### Step 3.1: Install `kubectl`, `helm`, and `k3d`
```bash
mkdir -p ~/bin

# 1. kubectl
KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
curl -Lo ~/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
chmod +x ~/bin/kubectl

# 2. helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | USE_SUDO=false HELM_INSTALL_DIR=~/bin bash

# 3. k3d
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | USE_SUDO=false K3D_INSTALL_DIR=~/bin bash
```

### Step 3.2: k3d Wrapper Script for Podman
To ensure every invocation of `k3d` automatically targets Podman's rootless socket:
```bash
mv ~/bin/k3d ~/bin/k3d.bin
cat << 'EOF' > ~/bin/k3d
#!/usr/bin/env bash
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
export DOCKER_HOST=${DOCKER_HOST:-unix://$XDG_RUNTIME_DIR/podman/podman.sock}
export DOCKER_SOCK=${DOCKER_SOCK:-$XDG_RUNTIME_DIR/podman/podman.sock}
exec "$HOME/bin/k3d.bin" "$@"
EOF
chmod +x ~/bin/k3d
```

### Step 3.3: Install `mkcert` and Browser Trust Tooling
To prevent browser `net::ERR_CERT_AUTHORITY_INVALID` warnings, install `libnss3-tools` (`certutil`) so `mkcert` can inject its Root CA into Chrome/Firefox NSS databases:

```bash
sudo apt update && sudo apt install -y libnss3-tools

# Download mkcert binary
curl -Lo ~/bin/mkcert https://github.com/FiloSottile/mkcert/releases/download/v1.4.4/mkcert-v1.4.4-linux-amd64
chmod +x ~/bin/mkcert

# Install local root CA into system and browser trust stores
mkcert -install
```

> [!NOTE]
> Completely close and reopen your browser after running `mkcert -install` to reload the certificate database.

---

## 4. Local TLS Certificates Generation

Because browsers and OpenSSL enforce RFC 6125 §6.4.3 (rejecting wildcards on single-level domains like `*.localhost`), we issue certificates with **explicit Subject Alternative Names (SANs)**:

```bash
mkdir -p certs
mkcert -cert-file certs/local-cert.pem -key-file certs/local-key.pem \
  localhost \
  "*.localhost" \
  vault.localhost \
  consul.localhost \
  jenkins.localhost \
  ilmiya.localhost \
  "*.ilmiya.localhost"
```

---

## 5. Local Container Registry & Cluster Creation

### Step 5.1: Create Local Registry
```bash
k3d registry create --default-network podman dev-registry --port 0.0.0.0:5000
```
*Accessible from host:* `http://localhost:5000/v2/_catalog`  
*Accessible within cluster:* `k3d-dev-registry:5000`

### Step 5.2: Cluster Configuration (`k3d-config.yaml`)
```yaml
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  name: dev-cluster
servers: 1
agents: 0
kubeAPI:
  hostPort: "6443"
ports:
  - port: 80:80
    nodeFilters:
      - loadbalancer
  - port: 443:443
    nodeFilters:
      - loadbalancer
registries:
  use:
    - k3d-dev-registry:5000
options:
  k3s:
    extraArgs:
      - arg: "--kubelet-arg=feature-gates=KubeletInUserNamespace=true"
        nodeFilters:
          - server:0
```

### Step 5.3: Start Cluster
```bash
k3d cluster create --config k3d-config.yaml
```

### Step 5.4: Apply TLS Secret to Kubernetes
```bash
kubectl create secret tls local-wildcard-tls \
  --cert=certs/local-cert.pem \
  --key=certs/local-key.pem \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

## 6. Deploying Platform Services via Helm

### Step 6.1: HashiCorp Vault
Add repository:
```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

Configuration (`helm/vault/values.yaml`):
```yaml
global:
  enabled: true
server:
  dev:
    enabled: true
    devRootToken: "root"
ui:
  enabled: true
  serviceType: "ClusterIP"
injector:
  enabled: true
```

Deploy:
```bash
helm upgrade --install vault hashicorp/vault -f helm/vault/values.yaml
```

---

### Step 6.2: HashiCorp Consul
Configuration (`helm/consul/values.yaml`):
```yaml
global:
  name: consul
  installK8sNetworkingCRDs: false
server:
  replicas: 1
  bootstrapExpect: 1
ui:
  enabled: true
  service:
    enabled: true
    type: ClusterIP
client:
  enabled: false
connectInject:
  enabled: false
```
> [!IMPORTANT]
> `connectInject: enabled: false` and `installK8sNetworkingCRDs: false` prevent mutating webhook crashes from blocking subsequent pod creations across the cluster.

Deploy:
```bash
helm upgrade --install consul hashicorp/consul -f helm/consul/values.yaml
```

---

### Step 6.3: Jenkins CI/CD
Add repository:
```bash
helm repo add jenkins https://charts.jenkins.io
helm repo update
```

Configuration (`helm/jenkins/values.yaml`):
```yaml
controller:
  admin:
    username: "admin"
    password: "admin123"
  resources:
    requests:
      cpu: "200m"
      memory: "1024Mi"
    limits:
      cpu: "2000m"
      memory: "2048Mi"
  javaOpts: "-Xmx1536m -Xms512m"
  initContainerResources:
    requests:
      cpu: "200m"
      memory: "512Mi"
    limits:
      cpu: "2000m"
      memory: "2048Mi"
  initContainerEnv:
    - name: JAVA_OPTS
      value: "-Xmx1024m -Xms256m"
  installLatestPlugins: false
persistence:
  enabled: true
  size: "5Gi"
```

Deploy:
```bash
helm upgrade --install jenkins jenkins/jenkins -f helm/jenkins/values.yaml
```

---

### Step 6.4: Ingress for Platform Services
Defined in `manifests/ingress/local-ingress.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: local-ingress
  namespace: default
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - vault.localhost
        - consul.localhost
        - jenkins.localhost
      secretName: local-wildcard-tls
  rules:
    - host: vault.localhost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: vault-ui
                port:
                  number: 8200
    - host: consul.localhost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: consul-ui
                port:
                  number: 80
    - host: jenkins.localhost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: jenkins
                port:
                  number: 8080
```
Apply:
```bash
kubectl apply -f manifests/ingress/local-ingress.yaml
```

---

## 7. Deploying Microservices (Flutter Web + Spring Boot Backend)

### Step 7.1: Frontend Dockerfile & Nginx Config
In `/home/edmaputra/Projects/ilmiya-frontend/`:

**`nginx.conf`** (SPA routing fallback):
```nginx
server {
    listen 80;
    server_name localhost;

    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|wasm|ttf|woff|woff2)$ {
        expires 1y;
        add_header Cache-Control "public, no-transform";
    }

    location = /index.html {
        add_header Cache-Control "no-store, no-cache, must-revalidate";
    }
}
```

**`Dockerfile`**:
```dockerfile
# Stage 1: Build Flutter Web
FROM ghcr.io/cirruslabs/flutter:stable AS builder
WORKDIR /app
RUN flutter config --enable-web --no-analytics
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get
COPY . .
ARG ILMIYA_API_BASE_URL=https://ilmiya.localhost
RUN flutter build web --release --dart-define=ILMIYA_API_BASE_URL=${ILMIYA_API_BASE_URL}

# Stage 2: Serve with Nginx
FROM nginx:alpine AS runner
COPY --from=builder /app/build/web /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

---

### Step 7.2: Unified Application Stack (`manifests/apps/ilmiya-stack.yaml`)
Deploys PostgreSQL 17, Spring Boot Backend, Flutter Web, and path-based Ingress routing under `ilmiya.localhost`:

```bash
kubectl apply -f manifests/apps/ilmiya-stack.yaml
```

---

### Step 7.3: Grant Deployer Permissions to Jenkins
Defined in `manifests/jenkins/jenkins-deployer-rbac.yaml`:
```bash
kubectl apply -f manifests/jenkins/jenkins-deployer-rbac.yaml
```

---

## 8. Jenkins CI/CD Pipelines

Both services are equipped with declarative `Jenkinsfile` configurations using dynamic Kubernetes Pod Agents:

### Backend Pipeline (`ilmiya/Jenkinsfile`)
```groovy
pipeline {
    agent {
        kubernetes {
            yaml """
apiVersion: v1
kind: Pod
spec:
  containers:
    - name: kaniko
      image: gcr.io/kaniko-project/executor:debug
      command: ['/busybox/cat']
      tty: true
    - name: kubectl
      image: bitnami/kubectl:latest
      command: ['cat']
      tty: true
"""
        }
    }
    stages {
        stage('Build & Push Backend') {
            steps {
                container('kaniko') {
                    sh """
                    /kaniko/executor \
                      --context=dir://. \
                      --dockerfile=Dockerfile \
                      --destination=k3d-dev-registry:5000/ilmiya-backend:${BUILD_NUMBER} \
                      --destination=k3d-dev-registry:5000/ilmiya-backend:latest \
                      --insecure \
                      --skip-tls-verify
                    """
                }
            }
        }
        stage('Deploy to Kubernetes') {
            steps {
                container('kubectl') {
                    sh """
                    kubectl set image deployment/ilmiya-backend backend=k3d-dev-registry:5000/ilmiya-backend:${BUILD_NUMBER} --namespace=default
                    kubectl rollout status deployment/ilmiya-backend --timeout=180s --namespace=default
                    """
                }
            }
        }
    }
}
```

### Frontend Pipeline (`ilmiya-frontend/Jenkinsfile`)
```groovy
pipeline {
    agent {
        kubernetes {
            yaml """
apiVersion: v1
kind: Pod
spec:
  containers:
    - name: kaniko
      image: gcr.io/kaniko-project/executor:debug
      command: ['/busybox/cat']
      tty: true
    - name: kubectl
      image: bitnami/kubectl:latest
      command: ['cat']
      tty: true
"""
        }
    }
    stages {
        stage('Build & Push Frontend') {
            steps {
                container('kaniko') {
                    sh """
                    /kaniko/executor \
                      --context=dir://. \
                      --dockerfile=Dockerfile \
                      --destination=k3d-dev-registry:5000/ilmiya-frontend:${BUILD_NUMBER} \
                      --destination=k3d-dev-registry:5000/ilmiya-frontend:latest \
                      --insecure \
                      --skip-tls-verify
                    """
                }
            }
        }
        stage('Deploy to Kubernetes') {
            steps {
                container('kubectl') {
                    sh """
                    kubectl set image deployment/ilmiya-frontend frontend=k3d-dev-registry:5000/ilmiya-frontend:${BUILD_NUMBER} --namespace=default
                    kubectl rollout status deployment/ilmiya-frontend --timeout=120s --namespace=default
                    """
                }
            }
        }
    }
}
```

---

## 9. Troubleshooting & FAQ

### 1. `net::ERR_CERT_AUTHORITY_INVALID` in Chrome / Chromium
- **Cause**: Linux browsers use their own NSS database (`~/.pki/nssdb`) instead of `/etc/ssl/certs`. Without `certutil`, `mkcert -install` cannot automatically register the CA.
- **Fix**:
  ```bash
  sudo apt install -y libnss3-tools
  mkcert -install
  ```
  Then completely close and restart your browser.

### 2. `curl: (60) SSL: no alternative certificate subject name matches target hostname`
- **Cause**: OpenSSL adheres strictly to RFC 6125 §6.4.3, which rejects wildcards matching single-label TLDs (`*.localhost`).
- **Fix**: Re-issue certificates with explicit Subject Alternative Names (`vault.localhost`, `consul.localhost`, `jenkins.localhost`, `ilmiya.localhost`).

### 3. Webhook Failures on Pod Creation
- **Symptom**: `failed calling webhook consul-connect-injector.consul.hashicorp.com: no endpoints available`
- **Fix**: Set `connectInject.enabled: false` in `helm/consul/values.yaml` and delete any stale `mutatingwebhookconfiguration`.

### 4. Jenkins Init Container OOM Stalls
- **Symptom**: Jenkins init container hangs downloading plugins with JVM heap 99% full.
- **Fix**: Provide `initContainerResources` (2GB limit) and set `initContainerEnv` `JAVA_OPTS: "-Xmx1024m"`, with `installLatestPlugins: false`.

---

## 10. Dashboard URLs & Access Directory

| Component | Protocol & Port | URL | Credentials |
| :--- | :--- | :--- | :--- |
| **Ilmiya Frontend (Flutter Web)** | HTTPS (443) | `https://ilmiya.localhost` | - |
| **Ilmiya API Docs (Swagger UI)** | HTTPS (443) | `https://ilmiya.localhost/swagger-ui.html` | - |
| **Jenkins CI/CD** | HTTPS (443) | `https://jenkins.localhost` | `admin` / `admin123` |
| **HashiCorp Vault UI** | HTTPS (443) | `https://vault.localhost/ui/` | Token: `root` |
| **HashiCorp Consul UI** | HTTPS (443) | `https://consul.localhost/ui/` | No auth required |
| **Local Container Registry** | HTTP (5000) | `http://localhost:5000/v2/_catalog` | Docker Registry API |
