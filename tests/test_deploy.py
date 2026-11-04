"""Run the real deployment logic in a temporary tree with mocked identity/HTTP.

No SSH or production paths are touched. Only the hardcoded root is relocated.
"""
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SHA = 'a' * 40
TOKEN = SHA + '-123-1'


@unittest.skipUnless(os.name == 'posix' and shutil.which('bash'), 'Linux deployment simulation')
class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.root = self.base / 'main-site'
        self.old = self.root / 'releases' / 'old'
        self.old.mkdir(parents=True)
        (self.old / 'index.html').write_text('old release')
        (self.root / 'current').symlink_to(self.old)
        self.decoy = self.base / 'decoy'
        self.decoy.mkdir()
        (self.decoy / 'index.html').write_text('VPN decoy untouched')
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        for name, content in {
            'id': '#!/bin/sh\nprintf deploy',
            'sleep': '#!/bin/sh\nexit 0',
            'curl': '#!/bin/sh\n[ "$MOCK_HEALTH" = ok ] || exit 22\nprintf "$MOCK_SHA"',
        }.items():
            path = self.bin / name
            path.write_text(content + '\n')
            path.chmod(0o755)
        self.script = self.base / 'deploy.sh'
        source = (REPO / 'scripts/server_deploy.sh').read_text()
        self.script.write_text(source.replace('root=/var/www/main-site', f'root={self.root}'))
        self.archive = self.root / f'.upload-{TOKEN}.tar.gz'
        self.make_archive()

    def make_archive(self, traversal=False):
        with tarfile.open(self.archive, 'w:gz') as tar:
            data = {'index.html': b'new release', 'release.txt': (SHA + '\n').encode(),
                    'sw.js': b'// service worker', 'manifest.webmanifest': b'{}'}
            if traversal:
                data['../../decoy/index.html'] = b'bad'
            for name, contents in data.items():
                info = tarfile.TarInfo(name)
                info.size = len(contents)
                tar.addfile(info, io.BytesIO(contents))

    def run_deploy(self, health='ok', digest=None):
        digest = digest or hashlib.sha256(self.archive.read_bytes()).hexdigest()
        env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                   MOCK_HEALTH=health, MOCK_SHA=SHA)
        return subprocess.run(['bash', str(self.script), TOKEN, digest, 'http://localhost'],
                              env=env, text=True, capture_output=True, timeout=20)

    def tearDown(self):
        self.assertEqual((self.decoy / 'index.html').read_text(), 'VPN decoy untouched')
        self.assertEqual((self.old / 'index.html').read_text(), 'old release')

    def test_success_switches_current_and_keeps_previous(self):
        result = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'current').resolve(), self.root / 'releases' / TOKEN)

    def test_failed_health_restores_previous(self):
        result = self.run_deploy(health='fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('previous current restored', result.stderr)
        self.assertEqual((self.root / 'current').resolve(), self.old)

    def test_bad_checksum_cannot_replace_previous(self):
        result = self.run_deploy(digest='0' * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SHA256 mismatch', result.stderr)
        self.assertEqual((self.root / 'current').resolve(), self.old)

    def test_failed_first_release_does_not_leave_current(self):
        (self.root / 'current').unlink()
        self.assertNotEqual(self.run_deploy(health='fail').returncode, 0)
        self.assertFalse((self.root / 'current').is_symlink())

    def test_regular_current_directory_is_preserved(self):
        (self.root / 'current').unlink()
        (self.root / 'current').mkdir()
        (self.root / 'current' / 'keep.txt').write_text('do not replace')
        self.assertNotEqual(self.run_deploy().returncode, 0)
        self.assertEqual((self.root / 'current' / 'keep.txt').read_text(), 'do not replace')

    def test_archive_traversal_cannot_escape_site(self):
        self.make_archive(traversal=True)
        result = self.run_deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unsafe archive member', result.stderr)
        self.assertEqual((self.root / 'current').resolve(), self.old)

    def test_releases_symlink_is_refused(self):
        (self.root / 'current').unlink()
        self.old.rename(self.base / 'saved-old')
        self.old = self.base / 'saved-old'
        (self.root / 'releases').rmdir()
        (self.root / 'releases').symlink_to(self.decoy)
        self.assertNotEqual(self.run_deploy().returncode, 0)
