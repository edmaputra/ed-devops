#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Synchronize internal Gitea repositories with upstream GitHub main branch
# and trigger Woodpecker CI pipelines for automatic cluster deployment.
# ==============================================================================

GITEA_POD=$(kubectl get pod -l app.kubernetes.io/name=gitea -o jsonpath='{.items[0].metadata.name}')
WOODPECKER_URL="${WOODPECKER_URL:-https://woodpecker.localhost}"

sync_repo() {
  local repo_name="$1"
  local upstream_url="$2"
  local repo_id="$3"

  echo "=================================================================="
  echo " Synchronizing ${repo_name} from ${upstream_url}..."
  echo "=================================================================="

  local updated
  updated=$(kubectl exec "${GITEA_POD}" -c gitea -- su git -c "
    set -e
    REPO_DIR=\"/data/git/repositories/gitea_admin/${repo_name}.git\"
    export GIT_AUTHOR_NAME='gitea_admin'
    export GIT_AUTHOR_EMAIL='admin@localhost'
    export GIT_COMMITTER_NAME='gitea_admin'
    export GIT_COMMITTER_EMAIL='admin@localhost'

    git --git-dir=\"\${REPO_DIR}\" fetch \"${upstream_url}\" main:refs/remotes/github/main --tags --force >/dev/null 2>&1

    LOCAL_MAIN=\$(git --git-dir=\"\${REPO_DIR}\" rev-parse main)
    REMOTE_MAIN=\$(git --git-dir=\"\${REPO_DIR}\" rev-parse refs/remotes/github/main)

    if [ \"\${LOCAL_MAIN}\" = \"\${REMOTE_MAIN}\" ] || git --git-dir=\"\${REPO_DIR}\" merge-base --is-ancestor refs/remotes/github/main main; then
      echo 'NO_CHANGE'
      exit 0
    fi

    MERGE_TREE=\$(git --git-dir=\"\${REPO_DIR}\" merge-tree --write-tree main refs/remotes/github/main)
    NEW_COMMIT=\$(git --git-dir=\"\${REPO_DIR}\" commit-tree \"\${MERGE_TREE}\" -p \"\${LOCAL_MAIN}\" -p \"\${REMOTE_MAIN}\" -m \"sync: merge latest updates from github main\")
    git --git-dir=\"\${REPO_DIR}\" update-ref refs/heads/main \"\${NEW_COMMIT}\"
    echo \"UPDATED:\${NEW_COMMIT}\"
  ")

  if [[ "${updated}" == *"NO_CHANGE"* ]]; then
    echo "✓ ${repo_name} is already up to date with GitHub main."
    return 0
  fi

  echo "✓ ${repo_name} merged latest GitHub changes: ${updated}"
  echo "--> Triggering Woodpecker CI pipeline..."

  python3 -c "
import hmac, hashlib, base64, json, urllib.request, ssl, subprocess

k3d_node = 'k3d-dev-cluster-server-0'
pvc_dir = subprocess.check_output(
    ['docker', 'exec', k3d_node, 'sh', '-c', 'ls -d /var/lib/rancher/k3s/storage/*data-woodpecker-server-0* 2>/dev/null | head -n 1']
).decode('utf-8').strip()

subprocess.check_call(['docker', 'cp', f'{k3d_node}:{pvc_dir}/woodpecker.sqlite', '/tmp/wp-sync.sqlite'])
user_hash = subprocess.check_output(['sqlite3', '/tmp/wp-sync.sqlite', 'SELECT hash FROM users WHERE admin = 1 LIMIT 1;']).decode('utf-8').strip()
subprocess.call(['rm', '-f', '/tmp/wp-sync.sqlite'])

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('utf-8')

header = b64url(json.dumps({'alg': 'HS256', 'typ': 'JWT'}).encode('utf-8'))
payload = b64url(json.dumps({'type': 'user', 'user-id': '1'}).encode('utf-8'))
msg = f'{header}.{payload}'.encode('utf-8')
sig = b64url(hmac.new(user_hash.encode('utf-8'), msg, hashlib.sha256).digest())
token = f'{header}.{payload}.{sig}'

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

req = urllib.request.Request(
    '${WOODPECKER_URL}/api/repos/${repo_id}/pipelines',
    data=json.dumps({'branch': 'main'}).encode('utf-8'),
    method='POST'
)
req.add_header('Authorization', f'Bearer {token}')
req.add_header('Content-Type', 'application/json')
with urllib.request.urlopen(req, context=ctx) as resp:
    res = json.loads(resp.read().decode('utf-8'))
    print(f'✓ Triggered Woodpecker pipeline #{res[\"number\"]} for ${repo_name}: ${WOODPECKER_URL}/repos/${repo_id}/pipeline/{res[\"number\"]}')
" || echo "Notice: Woodpecker pipeline can also be triggered manually from the UI (${WOODPECKER_URL}/repos/${repo_id})."
}

TARGET="${1:-all}"

if [ "${TARGET}" = "frontend" ] || [ "${TARGET}" = "all" ]; then
  sync_repo "ilmiya-frontend" "https://github.com/edmaputra/ilmiya-frontend.git" 2
fi

if [ "${TARGET}" = "backend" ] || [ "${TARGET}" = "all" ]; then
  sync_repo "ilmiya" "https://github.com/edmaputra/ilmiya.git" 1
fi
