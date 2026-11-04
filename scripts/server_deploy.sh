#!/usr/bin/env bash
# Run after server_preflight.sh in the same SSH session.
set -euo pipefail
token=${1:?release token required}
digest=${2:?SHA256 required}
site_url=${3:?SITE_URL required}
[[ "$token" =~ ^[0-9a-f]{40}-[0-9]+-[0-9]+$ && "$digest" =~ ^[0-9a-f]{64}$ ]] || exit 1
[[ "$site_url" =~ ^https?://[A-Za-z0-9][A-Za-z0-9.:/-]*$ ]] || { echo 'Invalid SITE_URL'; exit 1; }
sha=${token:0:40}
root=/var/www/main-site
[[ "$(id -un)" == deploy && -d "$root" && ! -L "$root" && "$(readlink -f "$root")" == "$root" ]] || exit 1
[[ ! -L "$root/.deploy.lock" ]] || exit 1
exec 9>"$root/.deploy.lock"
flock -w 60 9
# Recheck after taking the server-side lock.
[[ ! -L "$root/releases" ]] || exit 1
mkdir -p "$root/releases"
[[ "$(readlink -f "$root/releases")" == "$root/releases" ]] || exit 1
archive="$root/.upload-$token.tar.gz"
release="$root/releases/$token"
next="$root/.next-$token"
previous=''
if [[ -e "$root/current" || -L "$root/current" ]]; then
  [[ -L "$root/current" ]] || exit 1
  previous=$(readlink -f "$root/current")
  [[ "$previous" == "$root/releases/"* && -d "$previous" ]] || exit 1
fi
[[ -f "$archive" && ! -L "$archive" && ! -e "$release" && ! -L "$release" && ! -e "$next" && ! -L "$next" ]] || exit 1
activated=0
committed=0
finish() {
  status=$?
  trap - EXIT
  if (( activated && ! committed )); then
    if [[ -L "$next" && "$(readlink "$next")" == "$release" ]]; then
      unlink "$next"
    fi
    if [[ -n "$previous" ]]; then
      if ! { ln -s "$previous" "$next" && mv -Tf "$next" "$root/current"; }; then
        echo 'ROLLBACK FAILED: inspect main-site/current before retrying.' >&2
        status=1
      fi
    elif [[ -L "$root/current" && "$(readlink -f "$root/current")" == "$release" ]]; then
      unlink "$root/current"
    fi
    echo 'Health check failed or deploy interrupted: previous current restored.' >&2
  fi
  rm -f -- "$archive"
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
python3 - "$archive" "$digest" "$release" "$sha" <<'PY'
import hashlib, pathlib, shutil, sys, tarfile
archive, digest, target, sha = sys.argv[1:]
archive, target = pathlib.Path(archive), pathlib.Path(target)
if archive.stat().st_size > 100_000_000:
    raise SystemExit('Archive exceeds size limit')
if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
    raise SystemExit('Archive SHA256 mismatch')
with tarfile.open(archive, 'r:gz') as tar:
    members = tar.getmembers()
    if len(members) > 2000 or sum(m.size for m in members) > 100_000_000:
        raise SystemExit('Expanded archive exceeds limits')
    seen = set()
    for m in members:
        p = pathlib.PurePosixPath(m.name)
        if not m.isfile() or p.is_absolute() or '..' in p.parts or '\\' in m.name or m.name in seen:
            raise SystemExit('Unsafe archive member')
        seen.add(m.name)
        if p.suffix not in {'.html', '.js', '.css', '.png', '.svg', '.webmanifest'} and m.name != 'release.txt':
            raise SystemExit('Unexpected archive member')
    if not {'index.html', 'release.txt', 'sw.js', 'manifest.webmanifest'} <= seen:
        raise SystemExit('Required deployment files missing')
    target.mkdir(mode=0o755)
    for m in members:
        dest = target / m.name
        dest.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
        with tar.extractfile(m) as source, dest.open('xb') as output:
            shutil.copyfileobj(source, output)
        dest.chmod(0o644)
if (target / 'release.txt').read_text().strip() != sha:
    raise SystemExit('Archive commit does not match requested release')
PY
ln -s "$release" "$next"
# Mark first so a signal after mv still triggers rollback.
activated=1
mv -Tf "$next" "$root/current"
for attempt in {1..10}; do
  if [[ "$(curl --silent --show-error --fail --connect-timeout 5 --max-time 10 \
      --header 'Cache-Control: no-cache' "${site_url%/}/release.txt" 2>/dev/null || true)" == "$sha" ]] && \
      curl --silent --show-error --fail --connect-timeout 5 --max-time 10 \
      --output /dev/null "${site_url%/}/index.html"; then
    committed=1
    echo "DEPLOY_OK: $sha"
    exit 0
  fi
  sleep 2
done
echo 'Health check failed: nginx must serve main-site/current at SITE_URL.' >&2
exit 1
