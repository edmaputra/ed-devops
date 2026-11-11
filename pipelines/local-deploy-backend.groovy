properties([
    buildDiscarder(logRotator(
        daysToKeepStr: '2',
        numToKeepStr: '10',
        artifactDaysToKeepStr: '2',
        artifactNumToKeepStr: '5'
    )),
    parameters([
        string(name: 'REPO_URL', defaultValue: 'git@github.com:edmaputra/ilmiya.git', description: 'Git repository URL'),
        string(name: 'BRANCH', defaultValue: 'main', description: 'Git branch or tag to deploy'),
        string(name: 'IMAGE_NAME', defaultValue: 'ilmiya-backend', description: 'Container image name'),
        booleanParam(name: 'RUN_TESTS', defaultValue: true, description: 'Run Gradle integration tests with Testcontainers and verify code coverage'),
        string(name: 'MIN_COVERAGE', defaultValue: '80', description: 'Minimum required test code coverage percentage (default 80%)'),
        booleanParam(name: 'RUN_SONAR', defaultValue: true, description: 'Run SonarQube code quality scan'),
        string(name: 'SONAR_URL', defaultValue: 'http://sonarqube:9000', description: 'SonarQube Server URL'),
        string(name: 'SONAR_TOKEN', defaultValue: 'sqa_4394c471fbb13c9ae9dc54d59fec7734feec172c', description: 'SonarQube Authentication Token'),
        booleanParam(name: 'SONAR_WAIT_QUALITY_GATE', defaultValue: true, description: 'Wait for SonarQube Quality Gate and fail build if gate fails'),
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
          cpu: 1000m
          memory: 1024Mi
        limits:
          cpu: 3000m
          memory: 4096Mi
      env:
        - name: GRADLE_USER_HOME
          value: /root/.gradle
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
        - name: gradle-cache
          mountPath: /root/.gradle
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
    - name: gradle-cache
      persistentVolumeClaim:
        claimName: jenkins-gradle-cache
"""

podTemplate(yaml: podYaml) {
    node(POD_LABEL) {
        stage('Checkout Code') {
            deleteDir()
            git branch: params.BRANCH, credentialsId: 'github-ssh-key', url: params.REPO_URL
        }

        if (params.RUN_TESTS) {
            stage('Run Tests & Verify Coverage') {
                container('builder') {
                    sh """
                    echo "==> Running integration and unit tests with coverage reporting..."
                    ./gradlew check jacocoAggregateReport --parallel --build-cache --no-daemon

                    echo "==> Verifying code coverage meets minimum threshold (${params.MIN_COVERAGE}%)..."
                    MIN_COV="${params.MIN_COVERAGE}"
                    REPORT_CSV="build/reports/jacoco/aggregate/jacoco.csv"

                    if [ ! -f "\${REPORT_CSV}" ]; then
                      REPORT_FILES=\$(find . -path "*/build/reports/jacoco/*/*.csv" 2>/dev/null || true)
                    else
                      REPORT_FILES="\${REPORT_CSV}"
                    fi

                    if [ -z "\${REPORT_FILES}" ]; then
                      echo "ERROR: No JaCoCo coverage reports found. Unable to verify coverage threshold."
                      exit 1
                    fi

                    awk -F',' -v min_cov="\${MIN_COV}" '
                      NR > 1 && \$4 ~ /^[0-9]+\$/ {
                        inst_miss += \$4; inst_cov += \$5;
                        branch_miss += \$6; branch_cov += \$7;
                        line_miss += \$8; line_cov += \$9;
                      }
                      END {
                        inst_total = inst_miss + inst_cov;
                        line_total = line_miss + line_cov;
                        branch_total = branch_miss + branch_cov;

                        if (line_total == 0 && inst_total == 0) {
                          print "ERROR: Coverage reports contain 0 lines and 0 instructions.";
                          exit 1;
                        }

                        line_pct = (line_total > 0) ? (line_cov / line_total) * 100 : 0;
                        inst_pct = (inst_total > 0) ? (inst_cov / inst_total) * 100 : 0;
                        branch_pct = (branch_total > 0) ? (branch_cov / branch_total) * 100 : 0;

                        printf "\\n==========================================================\\n";
                        printf " JaCoCo Code Coverage Verification Summary\\n";
                        printf "==========================================================\\n";
                        printf "  Line Coverage        : %6.2f%% (%d / %d lines)\\n", line_pct, line_cov, line_total;
                        printf "  Instruction Coverage : %6.2f%% (%d / %d instructions)\\n", inst_pct, inst_cov, inst_total;
                        if (branch_total > 0) {
                          printf "  Branch Coverage      : %6.2f%% (%d / %d branches)\\n", branch_pct, branch_cov, branch_total;
                        }
                        printf "  Required Threshold   : %6.2f%%\\n", min_cov;
                        printf "==========================================================\\n\\n";

                        eval_pct = (line_total > 0) ? line_pct : inst_pct;
                        if (eval_pct < min_cov) {
                          printf "FAILED: Code coverage (%.2f%%) is below the required threshold of %.2f%%!\\n", eval_pct, min_cov;
                          exit 1;
                        } else {
                          printf "PASSED: Code coverage (%.2f%%) satisfies the required threshold of %.2f%%.\\n\\n", eval_pct, min_cov;
                        }
                      }
                    ' \${REPORT_FILES}
                    """
                }
            }
        }

        if (params.RUN_SONAR) {
            stage('SonarQube Code Analysis & Quality Gate') {
                container('builder') {
                    sh """
                    cat << 'EOF' > init-sonar.gradle
initscript {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
    dependencies {
        classpath 'org.sonarsource.scanner.gradle:sonarqube-gradle-plugin:7.5.0.8588'
    }
}
allprojects {
    apply plugin: org.sonarqube.gradle.SonarQubePlugin
}
EOF
                    ./gradlew --init-script init-sonar.gradle sonar \
                      -Dsonar.host.url=${params.SONAR_URL} \
                      -Dsonar.token=${params.SONAR_TOKEN} \
                      -Dsonar.projectName=${params.IMAGE_NAME} \
                      -Dsonar.projectKey=${params.IMAGE_NAME} \
                      -Dsonar.coverage.jacoco.xmlReportPaths=build/reports/jacoco/aggregate/jacoco.xml,**/build/reports/jacoco/test/jacocoTestReport.xml \
                      -Dsonar.qualitygate.wait=${params.SONAR_WAIT_QUALITY_GATE} \
                      --parallel --build-cache --no-daemon
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
                  --destination=k3d-dev-registry:5000/${params.IMAGE_NAME}:${env.BUILD_NUMBER} \
                  --destination=k3d-dev-registry:5000/${params.IMAGE_NAME}:latest \
                  --insecure \
                  --skip-tls-verify
                """
            }
        }

        if (params.TRIGGER_ROLLOUT) {
            stage('Update Deployment') {
                echo "Image k3d-dev-registry:5000/${params.IMAGE_NAME}:${env.BUILD_NUMBER} published to local registry."
                echo "ArgoCD / GitOps will detect or can be synced."
            }
        }
    }
}
