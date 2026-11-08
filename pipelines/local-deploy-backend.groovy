properties([
    parameters([
        string(name: 'REPO_URL', defaultValue: 'git@github.com:edmaputra/ilmiya.git', description: 'Git repository URL'),
        string(name: 'BRANCH', defaultValue: 'main', description: 'Git branch or tag to deploy'),
        string(name: 'IMAGE_NAME', defaultValue: 'ilmiya-backend', description: 'Container image name'),
        booleanParam(name: 'RUN_TESTS', defaultValue: false, description: 'Run Gradle integration tests with Testcontainers before packaging'),
        booleanParam(name: 'RUN_SONAR', defaultValue: false, description: 'Run SonarQube code quality scan'),
        string(name: 'SONAR_URL', defaultValue: 'http://sonarqube:9000', description: 'SonarQube Server URL'),
        string(name: 'SONAR_TOKEN', defaultValue: 'squ_d814b7d57dff2b0b58a939e7b4993f04020f3587', description: 'SonarQube Authentication Token'),
        booleanParam(name: 'TRIGGER_ROLLOUT', defaultValue: true, description: 'Trigger immediate rollout on k8s deployment if exists')
    ])
])

def podYaml = """
apiVersion: v1
kind: Pod
metadata:
  labels:
    jenkins-agent: local-backend-deployer
spec:
  containers:
    - name: builder
      image: eclipse-temurin:25-jdk
      command: ['cat']
      tty: true
      securityContext:
        runAsUser: 0
      resources:
        requests:
          cpu: 500m
          memory: 1024Mi
        limits:
          cpu: 2000m
          memory: 3072Mi
      env:
        - name: DOCKER_HOST
          value: unix:///var/run/docker.sock
        - name: TESTCONTAINERS_RYUK_DISABLED
          value: "true"
        - name: TESTCONTAINERS_CHECKS_DISABLE
          value: "true"
        - name: TESTCONTAINERS_HOST_OVERRIDE
          value: host.k3d.internal
      volumeMounts:
        - name: podman-sock
          mountPath: /var/run/docker.sock
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
  volumes:
    - name: podman-sock
      hostPath:
        path: /run/podman/podman.sock
"""

podTemplate(yaml: podYaml) {
    node(POD_LABEL) {
        stage('Checkout Code') {
            deleteDir()
            git branch: params.BRANCH, credentialsId: 'github-ssh-key', url: params.REPO_URL
        }

        if (params.RUN_TESTS) {
            stage('Run Integration Tests (Testcontainers)') {
                container('builder') {
                    sh """
                    ./gradlew check --no-daemon
                    """
                }
            }
        }

        if (params.RUN_SONAR) {
            stage('SonarQube Code Analysis') {
                container('builder') {
                    sh """
                    cat << 'EOF' > init-sonar.gradle
initscript {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
    dependencies {
        classpath 'org.sonarsource.scanner.gradle:sonarqube-gradle-plugin:5.1.0.4882'
    }
}
allprojects {
    apply plugin: org.sonarqube.gradle.SonarQubePlugin
}
EOF
                    ./gradlew --init-script init-sonar.gradle sonar \
                      -Dsonar.host.url=\${params.SONAR_URL} \
                      -Dsonar.token=\${params.SONAR_TOKEN} \
                      -Dsonar.projectName=\${params.IMAGE_NAME} \
                      -Dsonar.projectKey=\${params.IMAGE_NAME} \
                      --no-daemon || true
                    """
                }
            }
        }

        stage('Build & Push Container (Kaniko)') {
            container('kaniko') {
                sh """
                /kaniko/executor \
                  --context=dir://. \
                  --dockerfile=Dockerfile \
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
