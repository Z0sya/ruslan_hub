#!/usr/bin/env bash
# A separate unprivileged nginx master. No system nginx or VPN configuration.
set -euo pipefail
root=/var/www/main-site
runtime="$root/.nginx"
[[ "$(id -un)" == deploy && "$(readlink -f "$root")" == "$root" && -w "$root" ]] || exit 1
[[ ! -L "$runtime" ]] || exit 1
if [[ -d "$runtime" && ! -f "$runtime/managed-by-ci" ]]; then
  echo 'Refusing to overwrite an unmanaged nginx runtime directory' >&2
  exit 1
fi
mkdir -p "$runtime"
[[ "$(readlink -f "$runtime")" == "$runtime" ]] || exit 1
for name in managed-by-ci nginx.conf nginx.pid error.log access.log; do
  [[ ! -L "$runtime/$name" ]] || exit 1
done
printf '%s\n' 'ruslan-hub-isolated-nginx-v1' > "$runtime/managed-by-ci"
nginx=$(command -v nginx || true)
nginx=${nginx:-/usr/sbin/nginx}
[[ -x "$nginx" && -r /etc/nginx/mime.types ]] || { echo 'nginx or mime.types unavailable'; exit 1; }
python3 - "$runtime" <<'PY'
from pathlib import Path
import sys
runtime = Path(sys.argv[1])
config = '''# Managed by ruslan_hub CI; dedicated unprivileged instance.
worker_processes 1;
pid /var/www/main-site/.nginx/nginx.pid;
error_log /var/www/main-site/.nginx/error.log warn;
events { worker_connections 256; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/www/main-site/.nginx/access.log;
    client_body_temp_path /var/www/main-site/.nginx/client_temp;
    proxy_temp_path /var/www/main-site/.nginx/proxy_temp;
    fastcgi_temp_path /var/www/main-site/.nginx/fastcgi_temp;
    uwsgi_temp_path /var/www/main-site/.nginx/uwsgi_temp;
    scgi_temp_path /var/www/main-site/.nginx/scgi_temp;
    server_tokens off;
    server {
        listen 8081;
        server_name _;
        root /var/www/main-site/current;
        index index.html;
        location / { try_files $uri $uri/ /index.html; }
        location /assets/ { try_files $uri =404; }
        location = /release.txt {
            add_header Cache-Control "no-store" always;
            try_files $uri =404;
        }
        location = /index.html {
            add_header Cache-Control "no-cache" always;
            try_files $uri =404;
        }
        location = /sw.js {
            add_header Cache-Control "no-cache" always;
            try_files $uri =404;
        }
    }
}
'''
path = runtime / 'nginx.conf'
if path.exists() and path.read_text() != config:
    raise SystemExit('Existing nginx config differs; refusing to overwrite it')
if not path.exists():
    path.write_text(config)
PY
"$nginx" -e "$runtime/error.log" -p "$runtime/" -c "$runtime/nginx.conf" -t
running=false
if [[ -f "$runtime/nginx.pid" ]]; then
  pid=$(cat "$runtime/nginx.pid")
  [[ "$pid" =~ ^[0-9]+$ ]] || exit 1
  if kill -0 "$pid" 2>/dev/null; then
    owner=$(ps -p "$pid" -o user= | tr -d ' ')
    args=$(ps -p "$pid" -o args=)
    [[ "$owner" == deploy && "$args" == *"$runtime/nginx.conf"* ]] || { echo 'PID belongs to another process'; exit 1; }
    running=true
  fi
fi
if [[ "$running" == false ]]; then
  python3 - <<'PY'
import socket
with socket.socket() as sock:
    try:
        sock.bind(('0.0.0.0', 8081))
    except OSError:
        raise SystemExit('Port 8081 is occupied; refusing to disturb its listener')
PY
  "$nginx" -e "$runtime/error.log" -p "$runtime/" -c "$runtime/nginx.conf"
fi
echo 'ISOLATED_NGINX_READY: port 8081, root /var/www/main-site/current'
# Preserve all existing per-user cron entries. Never change system cron.
if command -v crontab >/dev/null && systemctl is-active --quiet cron; then
  python3 - "$nginx" "$runtime" <<'PY'
import os
import shlex
import subprocess
import sys
binary, runtime = sys.argv[1:]
env = dict(os.environ, LC_ALL='C')
result = subprocess.run(['crontab', '-l'], capture_output=True, text=True, env=env)
if result.returncode and 'no crontab' not in result.stderr.lower():
    raise SystemExit('Cannot read user crontab; existing entries left unchanged')
line = '@reboot ' + shlex.join([binary, '-e', runtime + '/error.log', '-p', runtime + '/', '-c', runtime + '/nginx.conf'])
if line not in result.stdout.splitlines():
    content = result.stdout.rstrip() + '\n# ruslan_hub isolated nginx\n' + line + '\n'
    subprocess.run(['crontab', '-'], input=content, text=True, check=True, env=env)
print('USER_CRON_REBOOT_ENTRY=ready')
PY
else
  echo 'USER_CRON_REBOOT_ENTRY=unavailable; restart after reboot requires a deploy run'
fi
