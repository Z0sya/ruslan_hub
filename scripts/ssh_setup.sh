#!/usr/bin/env bash
# Source this file. Secrets are read only through environment variables.
set -euo pipefail
for name in SERVER_HOST SERVER_USER SERVER_SSH_KEY SERVER_KNOWN_HOSTS; do
  if [[ -z "${!name:-}" ]]; then
    echo "::error::Missing GitHub secret: $name"
    exit 1
  fi
done
[[ "$SERVER_USER" == deploy ]] || { echo 'SERVER_USER must be deploy'; exit 1; }
# Environment input; presence was checked through the indirect expansion above.
# shellcheck disable=SC2153
[[ "$SERVER_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { echo 'Invalid SERVER_HOST'; exit 1; }
SERVER_PORT=${SERVER_PORT:-22}
[[ "$SERVER_PORT" =~ ^[0-9]{1,5}$ ]] && (( SERVER_PORT > 0 && SERVER_PORT < 65536 ))
SSH_DIR=$(mktemp -d)
cleanup_ssh() { rm -f -- "$SSH_DIR/key" "$SSH_DIR/known_hosts"; rmdir -- "$SSH_DIR"; }
trap cleanup_ssh EXIT
chmod 700 "$SSH_DIR"
printf '%s\n' "$SERVER_SSH_KEY" | tr -d '\r' > "$SSH_DIR/key"
printf '%s\n' "$SERVER_KNOWN_HOSTS" | tr -d '\r' > "$SSH_DIR/known_hosts"
chmod 600 "$SSH_DIR/key" "$SSH_DIR/known_hosts"
unset SERVER_SSH_KEY SERVER_KNOWN_HOSTS
ssh-keygen -y -P '' -f "$SSH_DIR/key" >/dev/null 2>&1 || { echo 'SSH key is invalid or needs a passphrase'; exit 1; }
# Used by publish.sh after sourcing this file.
# shellcheck disable=SC2034
SSH_ARGS=(-F /dev/null -i "$SSH_DIR/key" -o BatchMode=yes -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$SSH_DIR/known_hosts"
  -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=15 -o ConnectionAttempts=1
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o LogLevel=ERROR)
echo 'All four SSH secrets are present; key format checked (values hidden).'
