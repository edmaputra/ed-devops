properties([
    buildDiscarder(logRotator(
        daysToKeepStr: '14',
        numToKeepStr: '15',
        artifactDaysToKeepStr: '14',
        artifactNumToKeepStr: '5'
    )),
    pipelineTriggers([
        cron('H 2 * * *')
    ]),
    parameters([
        string(name: 'MAX_BUILDS_TO_KEEP', defaultValue: '10', description: 'Maximum number of recent builds to retain per job'),
        string(name: 'DAYS_TO_KEEP', defaultValue: '7', description: 'Maximum age in days for build retention (0 disables age limit)'),
        booleanParam(name: 'PRUNE_CONTAINER_IMAGES', defaultValue: true, description: 'Prune unused and dangling container images from storage'),
        string(name: 'IMAGE_RETENTION_HOURS', defaultValue: '72h', description: 'Filter images older than this duration (e.g. 24h, 72h, or empty for all unreferenced)'),
        booleanParam(name: 'PRUNE_CONTAINER_VOLUMES', defaultValue: true, description: 'Prune dangling/unused container storage volumes'),
        booleanParam(name: 'PRUNE_STOPPED_CONTAINERS', defaultValue: true, description: 'Prune dead/stopped containers'),
        string(name: 'JENKINS_SERVICE_URL', defaultValue: 'http://jenkins.default.svc.cluster.local:8080', description: 'Internal Jenkins service URL')
    ])
])

def podYaml = """
apiVersion: v1
kind: Pod
metadata:
  labels:
    jenkins-agent: storage-cleanup-agent
spec:
  containers:
    - name: cleaner
      image: docker.io/curlimages/curl:8.23.0
      command: ['cat']
      tty: true
      securityContext:
        runAsUser: 0
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          cpu: 500m
          memory: 512Mi
      volumeMounts:
        - name: podman-sock
          mountPath: /var/run/docker.sock
  volumes:
    - name: podman-sock
      hostPath:
        path: /run/podman/podman.sock
"""

podTemplate(yaml: podYaml) {
    node(POD_LABEL) {
        stage('Initialize & Pre-check') {
            echo "=================================================================="
            echo " Autonomous Storage & Build Cleanup Starting"
            echo " Retention Policy:"
            echo "   Max Builds Per Job   : ${params.MAX_BUILDS_TO_KEEP}"
            echo "   Max Build Age (Days) : ${params.DAYS_TO_KEEP}"
            echo "   Prune Images         : ${params.PRUNE_CONTAINER_IMAGES} (Threshold: ${params.IMAGE_RETENTION_HOURS})"
            echo "   Prune Volumes        : ${params.PRUNE_CONTAINER_VOLUMES}"
            echo "   Prune Stopped Pods   : ${params.PRUNE_STOPPED_CONTAINERS}"
            echo "=================================================================="
        }

        stage('Prune Older Jenkins Builds') {
            container('cleaner') {
                sh """
                echo "==> Enforcing build retention policy on all Jenkins jobs..."
                
                # Fetch Jenkins crumb and session
                COOKIE_JAR=\$(mktemp)
                trap 'rm -f "\${COOKIE_JAR}"' EXIT

                CRUMB_JSON=\$(curl -s -c "\${COOKIE_JAR}" -u "\${JENKINS_USER:-admin}:\${JENKINS_PASS:-admin123}" "${params.JENKINS_SERVICE_URL}/crumbIssuer/api/json" || echo "{}")
                CRUMB=\$(echo "\${CRUMB_JSON}" | sed -n 's/.*"crumb":"\\([^"]*\\)".*/\\1/p')
                CRUMB_FIELD=\$(echo "\${CRUMB_JSON}" | sed -n 's/.*"crumbRequestField":"\\([^"]*\\)".*/\\1/p')

                CRUMB_HEADER=""
                if [ -n "\${CRUMB}" ] && [ -n "\${CRUMB_FIELD}" ]; then
                    CRUMB_HEADER="-H \${CRUMB_FIELD}:\${CRUMB}"
                fi

                # Execute Groovy script to prune builds across all jobs
                GROOVY_SCRIPT="
int maxKeep = Integer.parseInt('${params.MAX_BUILDS_TO_KEEP}')
int daysKeep = Integer.parseInt('${params.DAYS_TO_KEEP}')
long now = System.currentTimeMillis()
long maxAgeMs = daysKeep * 24L * 60L * 60L * 1000L

int totalDeleted = 0
jenkins.model.Jenkins.get().getAllItems(hudson.model.Job.class).each { job ->
    def builds = job.getBuilds()
    int kept = 0
    int jobDeleted = 0
    builds.each { build ->
        boolean shouldDelete = false
        if (kept >= maxKeep) {
            shouldDelete = true
        } else if (daysKeep > 0 && (now - build.getTimeInMillis()) > maxAgeMs) {
            shouldDelete = true
        }
        
        if (shouldDelete) {
            println '[PRUNED] ' + job.name + ' #' + build.number + ' (Created: ' + new Date(build.getTimeInMillis()) + ')'
            try {
                build.delete()
                jobDeleted++
                totalDeleted++
            } catch (Exception e) {
                println '[ERROR] Failed to delete ' + job.name + ' #' + build.number + ': ' + e.message
            }
        } else {
            kept++
        }
    }
    if (jobDeleted > 0) {
        println '--> Job ' + job.name + ': pruned ' + jobDeleted + ' builds, ' + kept + ' retained.'
    } else {
        println '--> Job ' + job.name + ': ' + kept + ' builds within retention policy.'
    }
}
println 'TOTAL_BUILDS_PRUNED=' + totalDeleted
"

                echo "Executing Jenkins build prune operation via Script Console..."
                curl -s -X POST -b "\${COOKIE_JAR}" \
                     -u "\${JENKINS_USER:-admin}:\${JENKINS_PASS:-admin123}" \
                     \${CRUMB_HEADER} \
                     --data-urlencode "script=\${GROOVY_SCRIPT}" \
                     "${params.JENKINS_SERVICE_URL}/scriptText"
                """
            }
        }

        if (params.PRUNE_CONTAINER_IMAGES) {
            stage('Prune Unused Container Images') {
                container('cleaner') {
                    sh """
                    echo "==> Pruning unreferenced container images via engine socket..."
                    if [ ! -S /var/run/docker.sock ]; then
                        echo "WARNING: Docker/Podman socket not available at /var/run/docker.sock. Skipping image prune."
                        exit 0
                    fi

                    # Prune dangling images first
                    echo "-> Pruning dangling images..."
                    DANGLING_RESP=\$(curl -s -X POST --unix-socket /var/run/docker.sock "http://localhost/v1.41/images/prune?filters=%7B%22dangling%22%3A%5B%22true%22%5D%7D")
                    echo "\${DANGLING_RESP}"

                    # Prune unreferenced images matching age filter if provided
                    if [ -n "${params.IMAGE_RETENTION_HOURS}" ]; then
                        echo "-> Pruning unused images older than ${params.IMAGE_RETENTION_HOURS}..."
                        FILTER_JSON=\$(printf '{"dangling":["false"],"until":["%s"]}' "${params.IMAGE_RETENTION_HOURS}")
                        ENCODED_FILTER=\$(printf '%s' "\${FILTER_JSON}" | sed 's/"/%22/g; s/{/%7B/g; s/}/%7D/g; s/:/%3A/g; s/\\[/%5B/g; s/\\]/%5D/g')
                        UNUSED_RESP=\$(curl -s -X POST --unix-socket /var/run/docker.sock "http://localhost/v1.41/images/prune?filters=\${ENCODED_FILTER}")
                        echo "\${UNUSED_RESP}"
                    fi
                    """
                }
            }
        }

        if (params.PRUNE_CONTAINER_VOLUMES) {
            stage('Prune Unused Container Volumes') {
                container('cleaner') {
                    sh """
                    echo "==> Pruning unattached storage volumes via engine socket..."
                    if [ ! -S /var/run/docker.sock ]; then
                        echo "WARNING: Socket not available at /var/run/docker.sock. Skipping volume prune."
                        exit 0
                    fi

                    VOL_RESP=\$(curl -s -X POST --unix-socket /var/run/docker.sock "http://localhost/v1.41/volumes/prune")
                    echo "\${VOL_RESP}"
                    """
                }
            }
        }

        if (params.PRUNE_STOPPED_CONTAINERS) {
            stage('Prune Stopped Containers') {
                container('cleaner') {
                    sh """
                    echo "==> Pruning dead/stopped containers via engine socket..."
                    if [ ! -S /var/run/docker.sock ]; then
                        echo "WARNING: Socket not available at /var/run/docker.sock. Skipping container prune."
                        exit 0
                    fi

                    CONTAINER_RESP=\$(curl -s -X POST --unix-socket /var/run/docker.sock "http://localhost/v1.41/containers/prune")
                    echo "\${CONTAINER_RESP}"
                    """
                }
            }
        }

        stage('Storage Summary & Health Check') {
            container('cleaner') {
                sh """
                echo "=================================================================="
                echo " Storage Cleanup Operation Completed Successfully"
                echo " Current Engine Storage State:"
                echo "=================================================================="
                if [ -S /var/run/docker.sock ]; then
                    DF_SUMMARY=\$(curl -s --unix-socket /var/run/docker.sock "http://localhost/v1.41/system/df" || echo "{}")
                    echo "\${DF_SUMMARY}"
                fi
                """
            }
        }
    }
}
