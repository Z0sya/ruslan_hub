#!/usr/bin/env bash
# Read-only diagnostics. Never print nginx/VPN configuration or secret values.
set -euo pipefail
python3 - <<'PY'
from pathlib import Path
import re
import shutil
import socket
import subprocess


def run(args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return None


nginx = shutil.which('nginx') or '/usr/sbin/nginx'
print('NGINX_BINARY_AVAILABLE=' + str(Path(nginx).is_file()).lower())
configs = [Path('/etc/nginx/nginx.conf')]
configs.extend(Path('/etc/nginx/conf.d').glob('*.conf'))
configs.extend(Path('/etc/nginx/sites-enabled').glob('*'))
readable = 0
root_current = False
root_direct = False
for config in configs:
    try:
        text = config.read_text()
    except (OSError, UnicodeError):
        continue
    readable += 1
    text = re.sub(r'#.*', '', text)
    root_current |= bool(re.search(r'\broot\s+["\']?/var/www/main-site/current["\']?\s*;', text))
    root_direct |= bool(re.search(r'\broot\s+["\']?/var/www/main-site/?["\']?\s*;', text))
print(f'READABLE_NGINX_CONFIG_COUNT={readable}')
print('MAIN_SITE_CURRENT_ROOT_FOUND=' + str(root_current).lower())
print('MAIN_SITE_DIRECT_ROOT_FOUND=' + str(root_direct).lower())
with socket.socket() as sock:
    sock.settimeout(2)
    free = sock.connect_ex(('127.0.0.1', 8080)) != 0
print('PORT_8080_HAS_NO_LOOPBACK_LISTENER=' + str(free).lower())
listeners = run(['ss', '-ltnH', 'sport = :8080'])
if listeners is not None:
    print('PORT_8080_AVAILABLE=' + str(listeners.returncode == 0 and not listeners.stdout.strip()).lower())
sudo = run(['sudo', '-n', '-l'])
if sudo is not None:
    permissions = sudo.stdout
    all_allowed = bool(re.search(r'\(ALL(?:\s*:\s*ALL)?\)\s+NOPASSWD:\s*ALL', permissions))
    print('SUDO_ALL_WITHOUT_PASSWORD=' + str(all_allowed).lower())
    print('SUDO_NGINX_RULE_FOUND=' + str('nginx' in permissions and 'NOPASSWD:' in permissions).lower())
nginx_test = run([nginx, '-t'])
print('NGINX_TEST_AS_DEPLOY_OK=' + str(nginx_test is not None and nginx_test.returncode == 0).lower())
PY
