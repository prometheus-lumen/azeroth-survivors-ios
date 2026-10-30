#!/usr/bin/env python3
"""Exercise the real loopback HTTP implementation, without creating game progress."""
import argparse
import hashlib
import json
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--port', type=int, default=49761)
args = parser.parse_args()
origin = f'http://127.0.0.1:{args.port}'
root = Path(__file__).resolve().parents[1]


def read(path, method='GET', headers=None):
    with urlopen(Request(origin + path, method=method, headers=headers or {}), timeout=30) as response:
        return response.status, response.headers, response.read()


status, headers, html = read('/')
assert status == 200 and b'Azeroth Survivors' in html
status, headers, wasm = read('/wenilla_bg.wasm')
assert status == 200 and headers.get_content_type() == 'application/wasm'
assert wasm[:8] == b'\x00asm\x01\x00\x00\x00'
assert hashlib.sha256(wasm).digest() == hashlib.sha256((root/'www/wenilla_bg.wasm').read_bytes()).digest()
status, headers, body = read('/wenilla_bg.wasm', 'HEAD')
assert status == 200 and not body and int(headers['Content-Length']) == len(wasm)
status, headers, part = read('/wenilla_bg.wasm', headers={'Range': 'bytes=10-29'})
assert status == 206 and part == wasm[10:30] and headers['Content-Range'] == f'bytes 10-29/{len(wasm)}'
status, headers, part = read('/wenilla_bg.wasm', headers={'Range': 'bytes=-20'})
assert status == 206 and part == wasm[-20:]
for path, extra, code in [
    ('/wenilla_bg.wasm', {'Range': f'bytes={len(wasm)}-'}, 416),
    ('/%2e%2e/Info.plist', {}, 400),
    ('/download/AzerothSurvivorsWindowsNew.rar', {}, 404),
]:
    try:
        read(path, headers=extra)
        raise AssertionError(f'Expected {code}: {path}')
    except HTTPError as error:
        assert error.code == code
manifest = json.loads((root/'www/bundle-manifest.json').read_text())
sample = next(path for path in manifest['data'] if path != 'data/__index')
status, headers, body = read('/' + sample)
assert status == 200 and 'immutable' in headers['Cache-Control'] and body == (root/'www'/sample).read_bytes()
status, headers, index = read('/data/__index')
assert status == 200 and json.loads(index)
print('PASS: core, full WASM hash, MIME, HEAD, ranges, packaged data and path boundaries')
