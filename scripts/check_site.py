"""Validate and package the supplied prebuilt site; Python standard library only."""
import argparse
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import tarfile
from urllib.parse import unquote, urlsplit


class References(HTMLParser):
    def __init__(self):
        super().__init__()
        self.refs = []
        self.has_root = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.has_root |= attrs.get('id') == 'root'
        for key in ('src', 'href'):
            if key in attrs:
                self.refs.append(attrs[key])


def validate(root):
    root = Path(root).resolve()
    required = ('index.html', 'sw.js', 'manifest.webmanifest', 'character.png',
                'favicon.svg', 'icon-192.png', 'icon-512.png')
    for name in required:
        if not (root / name).is_file() or not (root / name).stat().st_size:
            raise ValueError(f'Missing or empty required file: {name}')
    files = sorted(root.rglob('*'))
    allowed = {'.html', '.js', '.css', '.png', '.svg', '.webmanifest'}
    for path in files:
        if path.is_symlink():
            raise ValueError(f'Symlink is not allowed: {path.name}')
        if path.is_file() and (path.suffix not in allowed or path.name.startswith('.')):
            raise ValueError(f'Unexpected file: {path.relative_to(root)}')
    refs = References()
    refs.feed((root / 'index.html').read_text(encoding='utf-8'))
    if not refs.has_root:
        raise ValueError('React mount point is missing')
    manifest = json.loads((root / 'manifest.webmanifest').read_text(encoding='utf-8'))
    for icon in manifest['icons']:
        refs.refs.append(icon['src'])
    for css in root.rglob('*.css'):
        for ref in re.findall(r'url\(\s*[\"\']?([^\)\"\']+)', css.read_text(encoding='utf-8')):
            parsed = urlsplit(ref)
            if not parsed.scheme and not parsed.netloc and parsed.path:
                target = root / unquote(parsed.path).lstrip('/') if parsed.path.startswith('/') else css.parent / unquote(parsed.path)
                if not target.resolve().is_relative_to(root) or not target.is_file():
                    raise ValueError(f'Missing CSS asset: {css.name}: {ref}')
    for js in root.rglob('*.js'):
        # The supplied bundler uses quoted ./chunk.js dependencies.
        refs_from_js = re.findall(r'[\"\'](\./[^\"\']+\.(?:js|css))[\"\']', js.read_text(encoding='utf-8'))
        for ref in refs_from_js:
            if ref == './sw.js':
                # serviceWorker.register resolves from the document, not this JS chunk.
                continue
            if not (js.parent / ref).is_file():
                raise ValueError(f'Missing JS chunk: {js.name}: {ref}')
    for ref in refs.refs:
        parsed = urlsplit(ref)
        if parsed.scheme or parsed.netloc or not parsed.path:
            continue
        target = root / unquote(parsed.path).lstrip('/')
        if not target.resolve().is_relative_to(root) or not target.is_file():
            raise ValueError(f'Missing local reference: {ref}')
    return [p for p in files if p.is_file()]


def build(root, output, sha):
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('Expected a full commit SHA')
    root = Path(root).resolve()
    files = validate(root)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    metadata = output / 'release.txt'
    metadata.write_bytes((sha + '\n').encode('ascii'))
    archive = output / 'site.tar.gz'
    with tarfile.open(archive, 'w:gz') as tar:
        for file in files:
            tar.add(file, arcname=file.relative_to(root).as_posix(), recursive=False)
        tar.add(metadata, arcname='release.txt')
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / 'site.tar.gz.sha256').write_text(digest + '  site.tar.gz\n', encoding='ascii')
    print(f'Validated {len(files)} website files; created site.tar.gz')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--site', default='site', type=Path)
    parser.add_argument('--output', default='dist', type=Path)
    parser.add_argument('--sha')
    args = parser.parse_args()
    if args.sha:
        build(args.site, args.output, args.sha)
    else:
        print(f'Validated {len(validate(args.site))} website files')
