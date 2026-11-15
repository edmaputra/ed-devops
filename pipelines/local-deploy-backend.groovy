properties([
    buildDiscarder(logRotator(
        daysToKeepStr: '2',
        numToKeepStr: '10',
        artifactDaysToKeepStr: '2',
        artifactNumToKeepStr: '5'
    )),
    parameters([
        string(name: 'REPO_URL', defaultValue: 'https://github.com/edmaputra/ilmiya.git', description: 'Git repository URL'),
        string(name: 'BRANCH', defaultValue: 'main', description: 'Git branch or tag to deploy'),
        string(name: 'IMAGE_NAME', defaultValue: 'ilmiya-backend', description: 'Container image name'),
        booleanParam(name: 'RUN_TESTS', defaultValue: true, description: 'Run Gradle integration tests with Testcontainers and verify code coverage'),
        string(name: 'MIN_COVERAGE', defaultValue: '80', description: 'Minimum required test code coverage percentage (default 80%)'),
        booleanParam(name: 'RUN_SEMGREP', defaultValue: true, description: 'Run Semgrep static code analysis and security vulnerability scan'),
        booleanParam(name: 'SEMGREP_FAIL_ON_ERROR', defaultValue: false, description: 'Fail build if Semgrep detects blocking security vulnerabilities'),
        booleanParam(name: 'ENABLE_CACHE', defaultValue: true, description: 'Enable Kaniko layer caching in local container registry (k3d-dev-registry:5000/kaniko-cache)'),
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
    - name: semgrep
      image: k3d-dev-registry:5000/semgrep:latest
      command: ['/bin/sh', '-c']
      args: ['cat']
      tty: true
      env:
        - name: SEMGREP_SRC_DIRECTORY
          value: .
      resources:
        requests:
          cpu: 200m
          memory: 256Mi
        limits:
          cpu: 1000m
          memory: 1024Mi
    - name: kaniko
      image: gcr.io/kaniko-project/executor:debug
      command: ['/busybox/cat']
      tty: true
      env:
        - name: GODEBUG
          value: "http2client=0"
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
                try {
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
                } finally {
                    junit testResults: '**/build/test-results/**/*.xml', allowEmptyResults: true
                }
            }
        }

        if (params.RUN_SEMGREP) {
            stage('Semgrep Security & Quality Scan') {
                try {
                    container('semgrep') {
                        def failFlag = params.SEMGREP_FAIL_ON_ERROR ? "--error" : ""
                        sh """
                        echo "==> Running Semgrep static security and code quality analysis..."
                        unset SEMGREP_IN_DOCKER || true
                        export SEMGREP_SRC_DIRECTORY=.
                        semgrep scan --config=auto --sarif --output=semgrep.sarif . || true
                        semgrep_status=0
                        semgrep scan --config=auto --json --output=semgrep.json ${failFlag} . || semgrep_status=\$?

                        echo "==> Scan completed. Findings summary:"
                        if [ -f semgrep.json ]; then
                          python3 -c "
import json
try:
    with open('semgrep.json') as f:
        data = json.load(f)
    results = data.get('results', [])
    errors = sum(1 for r in results if r.get('extra', {}).get('severity') == 'ERROR')
    warnings = sum(1 for r in results if r.get('extra', {}).get('severity') == 'WARNING')
    infos = sum(1 for r in results if r.get('extra', {}).get('severity') == 'INFO')
    print(f'Total Semgrep findings: {len(results)} (Errors: {errors}, Warnings: {warnings}, Info: {infos})')
except Exception as e:
    print('Failed to parse semgrep findings:', e)
" || true
                        fi

                        if [ \$semgrep_status -ne 0 ]; then
                          echo "ERROR: Semgrep detected blocking security issues (exit code \$semgrep_status)."
                          exit \$semgrep_status
                        fi
                        """
                    }
                } finally {
                    archiveArtifacts artifacts: 'semgrep.sarif,semgrep.json', allowEmptyArchive: true

                    // Ingest into OpenObserve for central security dashboard
                    sh """
                    if [ -f semgrep.json ] && [ -s semgrep.json ]; then
                      echo "==> Ingesting Semgrep findings into OpenObserve stream 'semgrep'..."
                      curl -k -s -u admin@example.com:DevOps_OpenObserve#2026 \
                        https://openobserve.localhost/api/default/semgrep/_json \
                        -H 'Content-Type: application/json' \
                        -d @semgrep.json >/dev/null 2>&1 || true
                    fi
                    """

                    // Publish SARIF to Jenkins Warnings NG dashboard if plugin present
                    try {
                        recordIssues tools: [sarif(pattern: 'semgrep.sarif', id: 'semgrep', name: 'Semgrep Security & Quality')]
                    } catch (Exception e) {
                        echo "Notice: Warnings NG SARIF publisher skipped: ${e.message}"
                    }
                }
            }
        }

        stage('Build & Push Container (Kaniko)') {
            container('kaniko') {
                def cacheFlags = params.ENABLE_CACHE ? "--cache=true --cache-copy-layers=true --cache-run-layers=true --cache-repo=k3d-dev-registry:5000/kaniko-cache --cache-ttl=72h --compressed-caching=false" : "--cache=false"
                sh """
                /kaniko/executor \
                  --context=dir://. \
                  --dockerfile=Dockerfile \
                  --destination=k3d-dev-registry:5000/${params.IMAGE_NAME}:${env.BUILD_NUMBER} \
                  --destination=k3d-dev-registry:5000/${params.IMAGE_NAME}:latest \
                  ${cacheFlags} \
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
                echo "Image k3d-dev-registry:5000/${params.IMAGE_NAME}:${env.BUILD_NUMBER} published to local registry."
                echo "ArgoCD / GitOps will detect or can be synced."
            }
        }
    }
}
