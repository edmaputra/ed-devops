properties([
    buildDiscarder(logRotator(
        daysToKeepStr: '2',
        numToKeepStr: '10',
        artifactDaysToKeepStr: '2',
        artifactNumToKeepStr: '5'
    )),
    parameters([
        string(name: 'REPO_URL', defaultValue: 'https://github.com/edmaputra/ilmiya-frontend.git', description: 'Git repository URL'),
        string(name: 'BRANCH', defaultValue: 'main', description: 'Git branch or tag to deploy'),
        string(name: 'IMAGE_NAME', defaultValue: 'ilmiya-frontend', description: 'Container image name'),
        string(name: 'API_BASE_URL', defaultValue: 'https://ilmiya.localhost', description: 'API Base URL for Flutter Web'),
        booleanParam(name: 'ENABLE_CACHE', defaultValue: true, description: 'Enable Kaniko layer caching in local container registry (k3d-dev-registry:5000/kaniko-cache)'),
        booleanParam(name: 'TRIGGER_ROLLOUT', defaultValue: true, description: 'Trigger immediate rollout on k8s deployment if exists')
    ])
])

def podYaml = """
apiVersion: v1
kind: Pod
metadata:
  labels:
    jenkins-agent: local-frontend-deployer
spec:
  serviceAccountName: jenkins
  containers:
    - name: flutter
      image: k3d-dev-registry:5000/flutter:stable
      command: ['cat']
      tty: true
      resources:
        requests:
          cpu: 1000m
          memory: 1024Mi
        limits:
          cpu: 3000m
          memory: 4096Mi
    - name: kaniko
      image: k3d-dev-registry:5000/kaniko:debug
      command: ['/busybox/cat']
      tty: true
      resources:
        requests:
          cpu: 200m
          memory: 512Mi
        limits:
          cpu: 2000m
          memory: 2048Mi
"""

podTemplate(yaml: podYaml) {
    node(POD_LABEL) {
        stage('Checkout Code') {
            deleteDir()
            git branch: params.BRANCH, credentialsId: 'github-ssh-key', url: params.REPO_URL
        }

        stage('Build Flutter Web Application') {
            container('flutter') {
                sh """
                echo "==> Configuring Flutter Web..."
                flutter config --no-analytics
                flutter config --enable-web

                echo "==> Resolving Flutter dependencies..."
                flutter pub get

                echo "==> Compiling Flutter Web release..."
                flutter build web --release \
                  --no-wasm-dry-run \
                  --dart-define=ILMIYA_API_BASE_URL=${params.API_BASE_URL}

                echo "==> Verifying compiled web output..."
                ls -la build/web/
                test -f build/web/index.html || { echo "ERROR: build/web/index.html missing!"; exit 1; }

                echo "==> Removing .dockerignore so Kaniko does not ignore build/web..."
                rm -f .dockerignore
                """
            }
        }

        stage('Build & Push Container (Kaniko)') {
            writeFile file: 'Dockerfile.prod', text: '''FROM nginx:alpine
RUN rm -rf /usr/share/nginx/html/*
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY build/web /usr/share/nginx/html
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh
EXPOSE 80
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
'''

            container('kaniko') {
                def cacheFlags = params.ENABLE_CACHE ? "--cache=true --cache-run-layers=true --cache-repo=k3d-dev-registry:5000/kaniko-cache --cache-ttl=72h --compressed-caching=false" : "--cache=false"
                sh """
                /kaniko/executor \
                  --context=dir://. \
                  --dockerfile=Dockerfile.prod \
                  --destination=k3d-dev-registry:5000/${params.IMAGE_NAME}:${env.BUILD_NUMBER} \
                  --destination=k3d-dev-registry:5000/${params.IMAGE_NAME}:latest \
                  ${cacheFlags} \
                  --snapshot-mode=redo \
                  --image-download-retry=3 \
                  --image-fs-extract-retry=3 \
                  --push-retry=3 \
                  --insecure \
                  --skip-tls-verify
                """
            }
        }

        if (params.TRIGGER_ROLLOUT) {
            stage('Update Deployment') {
                container('flutter') {
                    sh '''
                    echo "==> Triggering rollout restart for ilmiya-frontend..."
                    TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token 2>/dev/null || true)
                    if [ -n "$TOKEN" ]; then
                      curl -k -s -X PATCH -H "Authorization: Bearer $TOKEN" \
                        -H "Content-Type: application/strategic-merge-patch+json" \
                        https://kubernetes.default.svc/apis/apps/v1/namespaces/default/deployments/ilmiya-frontend \
                        -d "{\\"spec\\":{\\"template\\":{\\"metadata\\":{\\"annotations\\":{\\"kubectl.kubernetes.io/restartedAt\\":\\"$(date -Iseconds)\\"}}}}}"
                      echo "[OK] Rollout restart triggered on Kubernetes."
                    fi
                    '''
                }
            }
        }
    }
}
