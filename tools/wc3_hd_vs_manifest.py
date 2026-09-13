"""Generate wc3_re_shaders/hd_vs/uber_manifest.json from the mixed-radix index.

Unlike the HD pixel shader -- where the permutation index *is* a bit mask --
the HD vertex shader numbers its permutations as a mixed-radix counter, the
same scheme the 2.0.0 engine used (``CalculatePermutationIndex_2_3_2_3_2_2``
there, ``_2_2_3_2_3`` here). :data:`AXES` is that counter in stride order, so
the digits are recovered by successive divmod. See uber.hlsl for what each
digit means.

Every digit is emitted as a define, including the zeros: the defines are then a
literal transcription of the engine's permutation digits rather than a
"features that happen to be on" set, and uber.hlsl does the folding (a weight
index of 0 and 1 are both "no skinning"; the bone-palette source is invisible
without skinning).
"""
import json
import sys
from pathlib import Path

#: (name, radix) in stride order -- stride of digit k is the product of the
#: radices before it: 1, 2, 4, 12, 24.
AXES = [
    ('BONE_BUFFER', 2),
    ('TANGENT', 2),
    ('WEIGHT_INDEX', 3),
    ('VERTEX_COLOR', 2),
    ('UV_COUNT', 3),
]


def digits(idx):
    """Split a permutation index into its mixed-radix digits."""
    out = {}
    for name, radix in AXES:
        out[name] = str(idx % radix)
        idx //= radix
    if idx:
        raise ValueError(f'permutation index out of range by {idx} radix steps')
    return out


def build(folder):
    folder = Path(folder)
    slots = sorted(p.stem[len('perm_'):] for p in folder.glob('perm_*.dxbc'))
    perms = {slot: {'defines': digits(int(slot)), 'validated': False}
             for slot in slots}
    return {'shader': 'hd_vs', 'profile': 'vs_5_0', 'entry': 'main',
            'driver': 'hd_vs', 'perms': perms}


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
    folder = Path(args[0] if args else 'wc3_re_shaders/hd_vs')
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
