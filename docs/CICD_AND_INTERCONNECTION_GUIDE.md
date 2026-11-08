# Full Guide: Microservices Interconnection, Clean Local Domain, and CI/CD with Jenkins

This guide details the complete blueprint to build, deploy, and interconnect your **Flutter Web Frontend** and **Kotlin Spring Boot Backend** (`ilmiya`) in your local Kubernetes (`k3d`) environment with:
- **Clean URLs** on standard ports (`80` HTTP, `443` HTTPS — no `:8080` port in the browser).
- **Single Dedicated Local Domain** (`https://ilmiya.localhost`) eliminating all CORS issues.
- **Trusted Local TLS Certificate** via `mkcert` (zero browser security warnings).
- **Automated CI/CD** using **Jenkins** running dynamically on Kubernetes with **Kaniko**.

---

## 1. Interconnection Architecture

```
                                  Client Browser
                                        │
                         https://ilmiya.localhost
                                        │
                                        ▼
                  ┌───────────────────────────────────────────┐
                  │      k3d Traefik Ingress Controller       │
                  │   (Ports 80 & 443 with local-wildcard-tls)│
                  └─────────────┬───────────────┬─────────────┘
                                │               │
          Path: /api/*,         │               │  Path: /* (default)
          /swagger-ui, /api-docs│               │
                                ▼               ▼
                    ┌──────────────────┐  ┌───────────────────┐
                    │  ilmiya-backend  │  │  ilmiya-frontend  │
                    │   (Spring Boot)  │  │   (Flutter Web)   │
                    │     Port 8080    │  │    Nginx Port 80  │
                    └────────┬─────────┘  └───────────────────┘
                             │
                             ▼
                    ┌──────────────────┐
                    │ ilmiya-postgres  │
                    │   PostgreSQL 17  │
                    │     Port 5432    │
                    └──────────────────┘
```

### Why This Eliminates CORS and Port Numbers
1. **Identical Origin**: Both the Flutter Web SPA and the Spring Boot REST API share `https://ilmiya.localhost`. The browser treats calls to `/api/...` as same-origin requests (`window.location.origin`), completely eliminating Cross-Origin Resource Sharing (CORS) blocks and preflight `OPTIONS` overhead.
2. **Standard Ports**: Traefik is bound to ports `80` and `443` on the host, so URLs are clean (e.g., `https://ilmiya.localhost` instead of `https://localhost:8080` or `http://localhost:3000`).
3. **Cookie & Token Safety**: `HttpOnly`, `SameSite=Lax/Strict`, and `Secure` cookies work seamlessly because the domain matches between client and server.

---

## 2. Kubernetes Manifests

The cluster configuration is declaratively defined in `manifests/apps/ilmiya-stack.yaml`:

- **Database**: `ilmiya-postgres` running PostgreSQL 17 with an internal Service `ilmiya-postgres:5432`.
- **Backend**: `ilmiya-backend` running Kotlin Spring Boot, connected to `jdbc:postgresql://ilmiya-postgres:5432/ilmiya_db`.
- **Frontend**: `ilmiya-frontend` running Nginx serving compiled Flutter Web static files on port 80.
- **Ingress**: Traefik Ingress routing:
  - `/api` ➔ `ilmiya-backend:8080`
  - `/swagger-ui` ➔ `ilmiya-backend:8080`
  - `/api-docs` ➔ `ilmiya-backend:8080`
  - `/` ➔ `ilmiya-frontend:80`
  - TLS Secret: `local-wildcard-tls`

Deploy or update at any time with:
```bash
kubectl apply -f manifests/apps/ilmiya-stack.yaml
```

---

## 3. Frontend & Backend Docker Configurations

### Backend (`ilmiya/Dockerfile`)
The backend is already equipped with a multi-stage Gradle builder and Eclipse Temurin runtime.

### Frontend (`ilmiya-frontend/Dockerfile` & `nginx.conf`)
Located in `/home/edmaputra/Projects/ilmiya-frontend/`:
- **Stage 1**: Compiles Flutter Web with:
  ```bash
  flutter build web --release --dart-define=ILMIYA_API_BASE_URL=https://ilmiya.localhost
  ```
- **Stage 2**: Lightweight Alpine Nginx image with SPA fallback routing:
  ```nginx
  location / {
      try_files $uri $uri/ /index.html;
  }
  ```

---

## 4. Automated CI/CD with Jenkins on Kubernetes

Because our host runs rootless Podman and Kubernetes, Jenkins utilizes the **Kubernetes Cloud Plugin** to launch ephemeral build pods instead of requiring a privileged Docker daemon.

Image building inside Kubernetes is handled by **Kaniko** (`gcr.io/kaniko-project/executor`), which builds container images without root or Docker-in-Docker, pushing directly to our local registry (`k3d-dev-registry:5000`).

### Pipeline 1: Backend (`ilmiya/Jenkinsfile`)
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

### Pipeline 2: Frontend (`ilmiya-frontend/Jenkinsfile`)
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

## 5. Quick Verification & URLs

| Service | Protocol / Port | Local URL | Credentials |
| :--- | :--- | :--- | :--- |
| **Unified Application** | HTTPS (443) | `https://ilmiya.localhost` | - |
| **API Backend Documentation** | HTTPS (443) | `https://ilmiya.localhost/swagger-ui.html` | - |
| **Jenkins CI/CD** | HTTPS (443) | `https://jenkins.localhost` | `admin` / `admin123` |
| **HashiCorp Vault UI** | HTTPS (443) | `https://vault.localhost/ui/` | Token: `root` |
| **HashiCorp Consul UI** | HTTPS (443) | `https://consul.localhost/ui/` | - |
| **Local Container Registry** | HTTP (5000) | `http://localhost:5000/v2/_catalog` | - |
