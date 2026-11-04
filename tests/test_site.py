import hashlib
import importlib.util
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('check_site', REPO / 'scripts/check_site.py')
site = importlib.util.module_from_spec(spec)
spec.loader.exec_module(site)


class SiteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'site'
        shutil.copytree(REPO / 'site', self.root)

    def test_supplied_site_and_archive(self):
        output = Path(self.tmp.name) / 'dist'
        files = site.validate(self.root)
        site.build(self.root, output, 'a' * 40)
        with tarfile.open(output / 'site.tar.gz') as tar:
            self.assertEqual(len(tar.getnames()), len(files) + 1)
            self.assertEqual(tar.extractfile('release.txt').read(), b'a' * 40 + b'\n')
            self.assertEqual(tar.extractfile('index.html').read(), (self.root / 'index.html').read_bytes())
        self.assertEqual((output / 'site.tar.gz.sha256').read_text().split()[0],
                         hashlib.sha256((output / 'site.tar.gz').read_bytes()).hexdigest())

    def test_missing_entry_asset_fails(self):
        (self.root / 'icon-192.png').unlink()
        with self.assertRaises(ValueError):
            site.validate(self.root)

    def test_missing_lazy_chunk_fails(self):
        next((self.root / 'assets').glob('DeanWorld-*.js')).unlink()
        with self.assertRaisesRegex(ValueError, 'Missing JS chunk'):
            site.validate(self.root)

    def test_private_file_is_not_published(self):
        (self.root / '.env').write_text('test fixture')
        with self.assertRaisesRegex(ValueError, 'Unexpected file'):
            site.validate(self.root)

    def test_html_path_traversal_fails(self):
        index = self.root / 'index.html'
        index.write_text(index.read_text(encoding='utf-8') + '<img src="../private.png">', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'Missing local reference'):
            site.validate(self.root)
