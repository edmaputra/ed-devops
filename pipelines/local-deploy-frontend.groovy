properties([
    parameters([
        string(name: 'REPO_URL', defaultValue: 'git@github.com:edmaputra/ilmiya-frontend.git', description: 'Git repository URL'),
        string(name: 'BRANCH', defaultValue: 'main', description: 'Git branch or tag to deploy'),
        string(name: 'IMAGE_NAME', defaultValue: 'ilmiya-frontend', description: 'Container image name'),
        string(name: 'API_BASE_URL', defaultValue: 'https://ilmiya.localhost', description: 'API Base URL for Flutter Web'),
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
  containers:
    - name: kaniko
      image: gcr.io/kaniko-project/executor:debug
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

        stage('Build & Push Container (Kaniko)') {
            container('kaniko') {
                sh """
                /kaniko/executor \
                  --context=dir://. \
                  --dockerfile=Dockerfile \
                  --build-arg=ILMIYA_API_BASE_URL=\${params.API_BASE_URL} \
                  --destination=k3d-dev-registry:5000/\${params.IMAGE_NAME}:\${BUILD_NUMBER} \
                  --destination=k3d-dev-registry:5000/\${params.IMAGE_NAME}:latest \
                  --insecure \
                  --skip-tls-verify
                """
            }
        }

        if (params.TRIGGER_ROLLOUT) {
            stage('Update Deployment') {
                echo "Image k3d-dev-registry:5000/\${params.IMAGE_NAME}:\${BUILD_NUMBER} published to local registry."
                echo "ArgoCD / GitOps will detect or can be synced."
            }
        }
    }
}
