#!/usr/bin/env python3
"""Create Xcode's app icon catalog from the original 1024px design."""
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
catalog = root / 'Assets.xcassets'
icons = catalog / 'AppIcon.appiconset'
icons.mkdir(parents=True, exist_ok=True)
metadata = {'author': 'xcode', 'version': 1}
def write_changed(path, text):
    if not path.exists() or path.read_text() != text:
        path.write_text(text)

write_changed(catalog / 'Contents.json', json.dumps({'info': metadata}))
entries = []
for idiom, points, scales in [
    ('iphone', [20, 29, 40, 60], [2, 3]),
    ('ipad', [20, 29, 40, 76], [1, 2]),
    ('ipad', [83.5], [2]),
    ('ios-marketing', [1024], [1]),
]:
    for point in points:
        for scale in scales:
            pixels = int(point * scale)
            filename = f'Icon-{pixels}.png'
            source = root / 'Design/AppIcon.png'
            target = icons / filename
            if not target.exists() or target.stat().st_mtime < source.stat().st_mtime:
                subprocess.run(['sips', '-z', str(pixels), str(pixels),
                                str(source), '--out', str(target)],
                               check=True, stdout=subprocess.DEVNULL)
            entries.append({'idiom': idiom, 'size': f'{point}x{point}', 'scale': f'{scale}x', 'filename': filename})
write_changed(icons / 'Contents.json', json.dumps({'images': entries, 'info': metadata}, indent=2))
color = catalog / 'LaunchBackground.colorset'
color.mkdir(exist_ok=True)
write_changed(color / 'Contents.json', json.dumps({'colors': [{'idiom': 'universal', 'color': {
    'color-space': 'srgb', 'components': {'red': '0.020', 'green': '0.016', 'blue': '0.012', 'alpha': '1.000'}
}}], 'info': metadata}, indent=2))
