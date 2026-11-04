#!/usr/bin/env bash
set -euo pipefail
source scripts/ssh_setup.sh
cat scripts/server_preflight.sh scripts/server_readiness.sh | \
  ssh -p "$SERVER_PORT" "${SSH_ARGS[@]}" "$SERVER_USER@$SERVER_HOST" 'bash -s'
if [[ "${DEPLOY_MODE:-preflight}" == preflight ]]; then
  exit 0
fi
[[ "${DEPLOY_ENABLED:-}" == true && "${GITHUB_REF:-}" == refs/heads/main ]] || { echo 'Deploy is disabled or branch is not main'; exit 1; }
[[ "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ && "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ && "${GITHUB_RUN_ATTEMPT:-}" =~ ^[0-9]+$ ]] || exit 1
[[ "${SITE_URL:-}" =~ ^https?://[A-Za-z0-9][A-Za-z0-9.:/-]*$ ]] || { echo 'Set a valid SITE_URL'; exit 1; }
# Prevent an older queued run from overwriting a more recent main commit.
latest=$(git ls-remote https://github.com/Z0sya/ruslan_hub.git refs/heads/main | cut -f1)
[[ "$latest" == "$GITHUB_SHA" ]] || { echo 'Skipping superseded main commit'; exit 0; }
(cd dist && sha256sum --check site.tar.gz.sha256)
digest=$(sha256sum dist/site.tar.gz | cut -d ' ' -f1)
token="$GITHUB_SHA-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
# No rsync --delete, no sudo, and no nginx reload.
scp -P "$SERVER_PORT" "${SSH_ARGS[@]}" dist/site.tar.gz "$SERVER_USER@$SERVER_HOST:/var/www/main-site/.upload-$token.tar.gz"
printf -v command 'bash -s -- %q %q %q' "$token" "$digest" "$SITE_URL"
cat scripts/server_preflight.sh scripts/server_deploy.sh | \
  ssh -p "$SERVER_PORT" "${SSH_ARGS[@]}" "$SERVER_USER@$SERVER_HOST" "$command"
