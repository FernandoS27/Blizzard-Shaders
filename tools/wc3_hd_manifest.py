"""Generate wc3_re_shaders/hd/uber_manifest.json from the 10-bit feature mask.

The permutation index IS the feature mask -- see the header of uber.hlsl for
what each bit means. Regenerate after changing the axis names.
"""
import json
import sys
from pathlib import Path

AXES = [
    (0, 'AO_MAP'),
    (1, 'SHADOW_CASCADE2'),
    (2, 'MULTI_TARGET'),
    (3, 'DEPTH_PREPASS'),
    (4, 'LIGHT_DEBUG'),
    (5, 'POINT_SHADOWS'),
    (6, 'SHADOW_CASCADE'),
    (7, 'LIGHTING'),
    (8, 'ALPHA_TEST'),
    (9, 'MULTI_LAYER'),
]


def build(folder):
    folder = Path(folder)
    slots = sorted(p.stem[len('perm_'):] for p in folder.glob('perm_*.dxbc'))
    perms = {}
    for slot in slots:
        idx = int(slot)
        defines = {name: '1' for bit, name in AXES if idx >> bit & 1}
        perms[slot] = {'defines': defines, 'validated': False}
    return {'shader': 'hd', 'profile': 'ps_5_0', 'entry': 'main',
            'driver': 'hd', 'perms': perms}


def mark_validated(man, sweep_json):
    """Set ``validated`` from a tools/wc3_uber_sweep.py report."""
    rep = json.loads(Path(sweep_json).read_text('utf-8'))
    for slot, r in rep.get('results', {}).items():
        if slot in man['perms']:
            man['perms'][slot]['validated'] = bool(r.get('ok'))
    return man


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    opts = [a for a in sys.argv[1:] if a.startswith('--')]
    folder = Path(args[0] if args else 'wc3_re_shaders/hd')
    man = build(folder)
    for o in opts:
        if o.startswith('--from-sweep='):
            man = mark_validated(man, o.split('=', 1)[1])
    out = folder / 'uber_manifest.json'
    lines = ['{',
             f'  "shader": {json.dumps(man["shader"])},',
             f'  "profile": {json.dumps(man["profile"])},',
             f'  "entry": {json.dumps(man["entry"])},',
             f'  "driver": {json.dumps(man["driver"])},',
             '  "perms": {']
    keys = list(man['perms'])
    for i, k in enumerate(keys):
        v = man['perms'][k]
        comma = ',' if i + 1 < len(keys) else ''
        lines.append(f'    "{k}": {json.dumps(v, separators=(", ", ": "))}{comma}')
    lines += ['  }', '}', '']
    out.write_text('\n'.join(lines), encoding='utf-8')
    print(f"wrote {out} ({len(keys)} perms)")
