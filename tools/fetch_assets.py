#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mirror Azeroth Survivors' public boot/world resources for a personal cached client.

Generated www/ is build output, not source. Do not commit or redistribute game assets
under the wrapper's source-code licence. Uses Python's standard library; curl is a
fallback only if the server insists on Brotli despite Accept-Encoding: identity.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import gzip
from html.parser import HTMLParser
from http.client import HTTPException
import json
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urljoin, urlsplit
from urllib.request import Request, urlopen

ORIGIN = 'https://wow.aethus.pl/'
UA = 'Mozilla/5.0 (iPad; CPU OS 26_0 like Mac OS X) AppleWebKit/605.1.15 Version/26.0 Mobile/15E148 Safari/604.1'


class PageDependencies(HTMLParser):
    def __init__(self):
        super().__init__()
        self.paths = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        value = attrs.get('src') if tag == 'script' else attrs.get('href') if tag == 'link' else None
        if value and urlsplit(urljoin(ORIGIN, value)).netloc == urlsplit(ORIGIN).netloc:
            path = urlsplit(value).path.lstrip('./')
            if path.endswith(('.js', '.css')):
                self.paths.append(path)


class Mirror:
    def __init__(self, output, budget, seconds, workers):
        self.output = output
        self.budget = budget
        self.deadline = time.monotonic() + seconds
        self.workers = workers
        self.lock = threading.Lock()
        self.bytes = 0
        self.failures = []
        self.core = set()
        self.data = set()
        self.build = ''

    def download(self, path, query='', core=False):
        relative = Path(path)
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Unsafe output path: ' + path)
        destination = self.output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        limit = 160 * 1024 * 1024 if path.endswith('.wasm') else 96 * 1024 * 1024
        temporary = destination.with_name(destination.name + f'.{threading.get_ident()}.partial')
        url = ORIGIN + '/'.join(quote(part, safe='') for part in path.split('/')) + query
        last_error = None
        for attempt in range(3):
            if time.monotonic() >= self.deadline:
                raise TimeoutError('Asset download time budget reached')
            try:
                with self.lock:
                    if self.bytes >= self.budget:
                        raise ValueError('Asset byte budget reached')
                request = Request(url, headers={'User-Agent': UA, 'Accept-Encoding': 'identity'})
                with urlopen(request, timeout=25) as response:
                    encoding = response.headers.get('Content-Encoding', '').strip().lower()
                    expected_decoded = response.headers.get('X-Decoded-Length')
                    expected_size = int(expected_decoded or response.headers.get('Content-Length') or 0)
                    if encoding == 'br' or path.endswith('.wasm') or expected_size > 2 * 1024 * 1024:
                        response.close()
                        subprocess.run(['curl', '--fail', '--silent', '--show-error', '--location', '--compressed',
                                        '--connect-timeout', '15', '--max-time', str(max(1, int(self.deadline - time.monotonic()))), '--max-filesize', str(limit),
                                        '--user-agent', UA, '--output', str(temporary), url], check=True)
                        size = temporary.stat().st_size
                    else:
                        source = gzip.GzipFile(fileobj=response) if encoding == 'gzip' else response
                        size = 0
                        with temporary.open('wb') as file:
                            while True:
                                chunk = source.read(512 * 1024)
                                if not chunk:
                                    break
                                size += len(chunk)
                                if size > limit or time.monotonic() >= self.deadline:
                                    raise ValueError('Asset exceeds file or time budget')
                                file.write(chunk)
                    if size > limit or size == 0:
                        raise ValueError('Empty or oversized asset')
                    if expected_decoded and size != int(expected_decoded):
                        raise ValueError('Incomplete decoded asset')
                    if not encoding and expected_size and size != expected_size:
                        raise ValueError('Incomplete asset response')
                if path.endswith('.wasm'):
                    with temporary.open('rb') as file:
                        if file.read(4) != b'\x00asm':
                            raise ValueError('Invalid WebAssembly header')
                if path.endswith('.json') or path == 'data/__index':
                    json.loads(temporary.read_text())
                with self.lock:
                    if self.bytes + size > self.budget:
                        raise ValueError('Asset byte budget reached')
                    self.bytes += size
                    (self.core if core else self.data).add(path)
                temporary.replace(destination)
                return destination
            except (OSError, ValueError, HTTPException, HTTPError, URLError, subprocess.CalledProcessError) as error:
                last_error = error
                temporary.unlink(missing_ok=True)
                if isinstance(error, HTTPError) and error.code in (404, 410):
                    break
                if attempt < 2:
                    time.sleep(.3 * (attempt + 1))
        raise RuntimeError(f'{path}: {last_error}')

    def batch(self, paths, core=False):
        paths = sorted(set(paths))
        failures = []
        with ThreadPoolExecutor(max_workers=self.workers) as pool:
            pending = {pool.submit(self.download, path,
                                   '?v=' + self.build if core or path == 'data/__index' else '', core): path
                       for path in paths}
            for count, future in enumerate(as_completed(pending), 1):
                path = pending[future]
                try:
                    future.result()
                except Exception as error:
                    failures.append({'path': path, 'error': str(error)})
                if count % 100 == 0 or count == len(paths):
                    print(f'  {count}/{len(paths)} checked; {self.bytes / 1048576:.1f} MiB saved', flush=True)
        self.failures.extend(failures)
        return failures


def chain_path(name):
    return 'data/' + '/'.join(part for part in name.replace('\\', '/').lower().split('/') if part)


def populate(args):
    args.output.mkdir(parents=True, exist_ok=True)
    mirror = Mirror(args.output, args.budget_mb * 1024 * 1024, args.seconds, args.workers)
    index = mirror.download('index.html', core=True).read_text()
    stamp = re.search(r'rogue\.js\?v=([A-Za-z0-9._-]+)', index)
    if not stamp:
        raise SystemExit('Cannot identify the upstream game build')
    mirror.build = stamp.group(1)
    print('Mirroring Azeroth Survivors build ' + mirror.build, flush=True)
    dependencies = PageDependencies()
    dependencies.feed(index)
    core = set(dependencies.paths) | {'rogue.js', 'rogue.css', 'boot.js', 'wasi_stubs.js',
                                    'wenilla.js', 'addons.js', 'saves.js', 'ime.js',
                                    'boot-manifest.json', 'world-manifest.json'}
    if mirror.batch(core, core=True):
        raise SystemExit('Required core files failed: ' + json.dumps(mirror.failures, ensure_ascii=False))
    # Resolve local module imports without treating commented data/Windows download links as dependencies.
    known = set(core)
    for _ in range(3):
        additional = set()
        for relative in sorted(known):
            if not relative.endswith('.js'):
                continue
            source = (args.output / relative).read_text()
            for value in re.findall(r'''(?:import\s*\(|new URL\s*\()\s*['"`]([^'"`]+)['"`]''', source):
                value = value.replace('${STAMP}', '').split('?')[0]
                if value.endswith(('.js', '.wasm')) and not value.startswith(('http:', 'https:', '/')):
                    path = urlsplit(urljoin(ORIGIN + relative, value)).path.lstrip('/')
                    if path not in known:
                        additional.add(path)
        if not additional:
            break
        if mirror.batch(additional, core=True):
            raise SystemExit('Required modules failed: ' + json.dumps(mirror.failures, ensure_ascii=False))
        known.update(additional)
    if 'wenilla_bg.wasm' not in mirror.core:
        mirror.download('wenilla_bg.wasm', '?v=' + mirror.build, core=True)
    names = set()
    for manifest in ['boot-manifest.json', 'world-manifest.json']:
        value = json.loads((args.output / manifest).read_text())
        if not isinstance(value.get('names'), list):
            raise SystemExit('Invalid required data manifest: ' + manifest)
        names.update(value['names'])
    supplement = Path(__file__).with_name('startup-manifest.json')
    if supplement.exists():
        value = json.loads(supplement.read_text())
        if value.get('build') == mirror.build:
            names.update(value['names'])
    print(f'Required manifests contain {len(names)} unique data files', flush=True)
    failures = mirror.batch(chain_path(name) for name in names)
    if failures:
        raise SystemExit('Required boot/world data downloads failed: ' + json.dumps(failures, ensure_ascii=False))
    # A deployment during a long mirror must not silently mix two core builds.
    with urlopen(Request(ORIGIN, headers={'User-Agent': UA, 'Accept-Encoding': 'identity'}), timeout=25) as response:
        current = response.read().decode()
    current_stamp = re.search(r'rogue\.js\?v=([A-Za-z0-9._-]+)', current)
    if not current_stamp or current_stamp.group(1) != mirror.build:
        raise SystemExit('Upstream changed during download; retry to obtain one consistent build')
    manifest = {'build': mirror.build, 'source': ORIGIN, 'core': sorted(mirror.core),
                'data': sorted(mirror.data), 'bytes': mirror.bytes, 'failures': mirror.failures,
                'partial': bool(failures), 'generated_at': int(time.time())}
    (args.output / 'bundle-manifest.json').write_text(json.dumps(manifest, indent=2))
    print(json.dumps({'build': mirror.build, 'core': len(mirror.core), 'data': len(mirror.data),
                      'MiB': round(mirror.bytes / 1048576, 1), 'failed': len(mirror.failures)}, indent=2), flush=True)
    if failures:
        raise SystemExit('Required boot/world data downloads failed; see bundle-manifest.json')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', nargs='?', type=Path, default=Path('www'))
    parser.add_argument('--budget-mb', type=int, default=600)
    parser.add_argument('--seconds', type=int, default=1200)
    parser.add_argument('--workers', type=int, default=8)
    args = parser.parse_args()
    destination = args.output.resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Failed downloads must leave a previously working build intact.
    with tempfile.TemporaryDirectory(prefix='azeroth-fetch-', dir=destination.parent) as directory:
        args.output = Path(directory) / 'www'
        populate(args)
        backup = Path(directory) / 'previous'
        if destination.exists():
            destination.rename(backup)
        try:
            args.output.rename(destination)
        except BaseException:
            if backup.exists():
                backup.rename(destination)
            raise


if __name__ == '__main__':
    main()
