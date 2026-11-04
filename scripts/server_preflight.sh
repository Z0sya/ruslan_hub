#!/usr/bin/env bash
# Read-only: no sudo, no nginx changes, no reading VPN configuration.
set -euo pipefail
[[ "$(id -un)" == deploy ]] || { echo 'Expected deploy user'; exit 1; }
root=/var/www/main-site
[[ -d "$root" && ! -L "$root" && "$(readlink -f "$root")" == "$root" ]] || { echo 'Unsafe or missing main-site directory'; exit 1; }
[[ -w "$root" && -x "$root" ]] || { echo 'deploy cannot write main-site'; exit 1; }
for tool in python3 tar curl flock readlink mv ln; do
  command -v "$tool" >/dev/null || { echo "Missing server tool: $tool"; exit 1; }
done
python3 -c 'import sys; assert sys.version_info >= (3, 10), "Python 3.10+ required"'
if [[ -e "$root/releases" || -L "$root/releases" ]]; then
  [[ -d "$root/releases" && ! -L "$root/releases" && -w "$root/releases" ]] || { echo 'Unsafe releases directory'; exit 1; }
fi
if [[ -e "$root/current" || -L "$root/current" ]]; then
  [[ -L "$root/current" ]] || { echo 'current must be a symlink; existing data will not be replaced'; exit 1; }
  target=$(readlink -f "$root/current")
  [[ "$target" == "$root/releases/"* && -d "$target" ]] || { echo 'Unsafe current target'; exit 1; }
fi
[[ ! -L "$root/.deploy.lock" ]] || { echo 'Unsafe lock file'; exit 1; }
echo 'PREFLIGHT_OK: deploy can publish inside /var/www/main-site; decoy and nginx were not modified.'
