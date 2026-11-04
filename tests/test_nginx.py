"""Exercise a real isolated nginx in a temporary tree, never system nginx."""
import getpass
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from urllib.request import urlopen

REPO = Path(__file__).resolve().parents[1]
NGINX = shutil.which('nginx') or '/usr/sbin/nginx'


@unittest.skipUnless(os.name == 'posix' and Path(NGINX).is_file(), 'nginx integration requires Linux/nginx')
class NginxTests(unittest.TestCase):
    def test_real_start_and_idempotent_restart(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            root = base / 'main-site'
            current = root / 'current'
            current.mkdir(parents=True)
            (current / 'index.html').write_text('isolated website')
            bindir = base / 'bin'
            bindir.mkdir()
            for name, body in {'id': 'printf deploy', 'systemctl': 'exit 1'}.items():
                path = bindir / name
                path.write_text('#!/bin/sh\n' + body + '\n')
                path.chmod(0o755)
            script = base / 'bootstrap.sh'
            source = (REPO / 'scripts/server_bootstrap.sh').read_text()
            source = source.replace('/var/www/main-site', str(root))
            source = source.replace('"$owner" == deploy', '"$owner" == ' + getpass.getuser())
            script.write_text(source)
            env = dict(os.environ, PATH=str(bindir) + ':' + os.environ['PATH'])
            try:
                first = subprocess.run(['bash', str(script)], env=env, capture_output=True, text=True, timeout=30)
                log = root / '.nginx/error.log'
                self.assertEqual(first.returncode, 0, first.stdout + first.stderr + (log.read_text() if log.exists() else ''))
                pidfile = root / '.nginx/nginx.pid'
                pid = pidfile.read_text()
                for attempt in range(20):
                    try:
                        with urlopen('http://127.0.0.1:8081/', timeout=2) as response:
                            self.assertEqual(response.read(), b'isolated website')
                        break
                    except OSError:
                        if attempt == 19:
                            raise
                        time.sleep(0.1)
                second = subprocess.run(['bash', str(script)], env=env, capture_output=True, text=True, timeout=30)
                self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
                self.assertEqual(pidfile.read_text(), pid)
            finally:
                runtime = root / '.nginx'
                if (runtime / 'nginx.pid').exists():
                    subprocess.run([NGINX, '-e', str(runtime / 'error.log'), '-p', str(runtime) + '/',
                                    '-c', str(runtime / 'nginx.conf'), '-s', 'quit'],
                                   capture_output=True, timeout=10)
                    time.sleep(0.2)
