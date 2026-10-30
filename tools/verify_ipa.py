#!/usr/bin/env python3
"""Verify device package structure, resources and the arm64 iOS executable."""
import hashlib
import json
import plistlib
import struct
import sys
import zipfile
from pathlib import Path

ipa = Path(sys.argv[1])
with zipfile.ZipFile(ipa) as archive:
    assert archive.testzip() is None, 'ZIP checksum mismatch'
    prefix = 'Payload/AzerothSurvivors.app/'
    plist = plistlib.loads(archive.read(prefix + 'Info.plist'))
    assert plist['CFBundleIdentifier'] == 'com.azerothsurvivors.app'
    assert plist['CFBundleSupportedPlatforms'] == ['iPhoneOS']
    assert plist['UIDeviceFamily'] == [1, 2]
    assert plist['MinimumOSVersion'] == '26.0'
    assert 'UIApplicationSceneManifest' not in plist
    assert prefix + 'Assets.car' in archive.namelist()
    executable = prefix + plist['CFBundleExecutable']
    assert archive.getinfo(executable).external_attr >> 16 & 0o111
    binary = archive.read(executable)
    magic, cpu, subtype, kind, commands, command_bytes, flags, reserved = struct.unpack_from('<8I', binary)
    assert magic == 0xfeedfacf and cpu == 0x100000c and kind == 2
    offset, platform = 32, None
    for _ in range(commands):
        command, size = struct.unpack_from('<II', binary, offset)
        if command == 0x32:
            platform = struct.unpack_from('<I', binary, offset + 8)[0]
        offset += size
    assert platform == 2, 'Not an iOS device binary'
    assert not any(n.endswith('embedded.mobileprovision') for n in archive.namelist())
    manifest = json.loads(archive.read(prefix + 'www/bundle-manifest.json'))
    assert not manifest['partial'] and not manifest['failures'], 'Required resources incomplete'
    assert not any(n.endswith('.partial') for n in archive.namelist()), 'Unfinished download packaged'
    for path in manifest['core'] + manifest['data']:
        assert prefix + 'www/' + path in archive.namelist(), path
    assert archive.read(prefix + 'www/wenilla_bg.wasm')[:8] == b'\x00asm\x01\x00\x00\x00'
    assert archive.read(prefix + 'www/index.html').startswith(b'<!doctype html>')
    print(json.dumps({'bundle_id': plist['CFBundleIdentifier'], 'version': plist['CFBundleShortVersionString'],
                      'game_build': manifest['build'], 'architecture': 'arm64', 'core_files': len(manifest['core']),
                      'cached_assets': len(manifest['data']), 'bytes': ipa.stat().st_size,
                      'sha256': hashlib.sha256(ipa.read_bytes()).hexdigest(), 'package_validation': 'passed',
                      'signing': 'unsigned; sign with your own profile before installation'}, indent=2))
