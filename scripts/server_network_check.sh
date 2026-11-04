#!/usr/bin/env bash
# Read-only diagnostics scoped to the site's listener and firewall metadata.
set -euo pipefail
[[ "$(id -un)" == deploy ]] || exit 1
echo 'SITE_LISTENERS_BEGIN'
ss -ltnH 'sport = :8081'
echo 'SITE_LISTENERS_END'
python3 - <<'PY'
from pathlib import Path
import re
import urllib.request

opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
for host in ('127.0.0.1', '31.56.48.8'):
    try:
        with opener.open(f'http://{host}:8081/release.txt', timeout=5) as response:
            print(f'HTTP_FROM_SERVER {host}: {response.status}')
    except OSError as error:
        print(f'HTTP_FROM_SERVER {host}: failed ({error})')
config = Path('/var/www/main-site/.nginx/nginx.conf').read_text()
print('SITE_CONFIG_LISTENS_ON_8081=' + str(bool(re.search(r'\blisten\s+8081\s*;', config))).lower())
for filename, setting in (('/etc/ufw/ufw.conf', 'ENABLED'), ('/etc/default/ufw', 'DEFAULT_INPUT_POLICY')):
    try:
        text = Path(filename).read_text()
        match = re.search(r'^' + setting + r'=(.*)$', text, re.M)
        print(f'UFW_{setting}=' + (match.group(1).strip() if match else 'not_set'))
    except OSError:
        print(f'UFW_{setting}=not_readable_by_deploy')
try:
    rules = Path('/etc/ufw/user.rules').read_text()
    candidates = [line for line in rules.splitlines() if '--dport 8081' in line and '-j ACCEPT' in line]
    print('UFW_8081_ACCEPT_RULE_CANDIDATE_COUNT=' + str(len(candidates)))
except OSError:
    print('UFW_RULES=not_readable_by_deploy')
PY
