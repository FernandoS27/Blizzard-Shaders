#!/usr/bin/env python3
"""The Diablo III DXBC programs ``$D3_RE`` leaves out (plan M7).

``$D3_RE`` holds the 2,848 retail keys of the 105 families with two or more
permutations. The shader atlas ships 4,117 DXBC keys; the other 1,269 are the
**residue**, in three kinds (``d3_uber_perms.assign``):

* ``singleton`` -- the only permutation of its ``(fx, entry)`` family (132);
* ``no_shd``    -- no shipped Shaders asset names the key (888);
* ``disputed``  -- the assets naming it disagree on the entry point (249).

``extract`` copies every residue program out of the atlas into
``$D3_RE_RESIDUE/<stage>/<hash>.dxbc`` (+ ``.asm``) and writes the evidence the
atlas has for each key to ``d3_perms/_residue_keys.json``. The tree is generated
input like ``$D3_RE``; the key file is committed.

A residue key has no RE uber and no local defines. Where it lands is decided by
what reproduces it, not by the evidence:

* a key whose bytes equal a program already in a bundle joins that slot;
* a ``singleton`` is a real subfamily ``<Fx>__<entry>``, placed in a root by
  ``d3_shaders.json`` and translated like any other;
* every other key belongs to the pseudo-subfamily ``Residue__<stage>``, and its
  program's root and specialization are data in ``d3_residue.json``, found by
  ``tools/d3_spec_search.py`` or by porting, and proven by D2 + D4.

    python tools/d3_residue.py extract            # (re)write the tree + key file
    python tools/d3_residue.py --check            # census: RE + residue == atlas, bytes agree
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import d3_dxbc as DX                      # noqa: E402
import d3_retail as R                     # noqa: E402

ATLAS = Path(os.environ.get('D3_ATLAS', r'C:\Projects\WhiteoutLib\Corpus\D3ShaderAtlas'))
ATLAS_TOOLS = Path(os.environ.get('D3_ATLAS_TOOLS', r'C:\Projects\WhiteoutFlakes\tools\d3_shader_atlas'))
KEYS = R.REPO / 'd3_perms' / '_residue_keys.json'


def _atlas():
    sys.path.insert(0, str(ATLAS_TOOLS))
    import atlas as A                     # noqa: E402
    import d3_uber_perms as P             # noqa: E402
    return A, P


def atlas_keys() -> dict:
    """``{(stage, hash): record}`` for every DXBC key the atlas ships, with its bytes'
    program id and the atlas's attribution evidence."""
    A, P = _atlas()
    shaders, stem_entries, _passes, programs, stem_progs, cod_dir = P.load_atlas(str(ATLAS))
    owner, _why = P.assign(programs, stem_entries)
    fams = collections.defaultdict(set)
    for (h, stage), fe in owner.items():
        fams[(stage,) + fe].add(h)
    stem_fx = {n.lower(): sorted({p['fx'] for p in s['passes']}) for n, s in shaders.items()}
    prog_fx = A.attribute(programs, stem_progs, stem_fx)
    guess, _votes = A.infer_by_signature(programs, prog_fx)
    out = {}
    for (h, stage), rec in programs.items():
        if rec['api'] != 'dxbc':
            continue
        blob = (cod_dir / rec['file']).read_bytes()[P.HEADER_BYTES:]
        known = [stem_entries[stage][t] for t in rec['stems'] if t in stem_entries[stage]]
        if (h, stage) in owner:
            fx, entry = owner[(h, stage)]
            kind = 'singleton' if len(fams[(stage, fx, entry)]) == 1 else 'family'
            sub = P.family_dir(fx, entry)
        else:
            kind, sub = ('no_shd' if not known else 'disputed'), None
        out[(stage, h)] = {
            'kind': kind,
            'subfamily': sub,
            'program': hashlib.sha1(blob).hexdigest(),
            'blob': blob,
            'shaders': sorted(rec['stems']),
            'fx': prog_fx.get((h, stage)) or [],
            'fxGuess': guess.get((h, stage)),
            'entries': sorted({'%s|%s' % fe for s in known for fe in s}),
        }
    return out


def re_keys() -> dict:
    """``{(stage, hash): (subfamily, program)}`` for every key in ``$D3_RE``."""
    return {(sf.stage, k.hash): (sf.name, R.program_id(k.dxbc))
            for sf in R.subfamilies().values() for k in sf.keys}


def extract() -> int:
    keys = atlas_keys()
    have = re_keys()
    rows = {}
    for (stage, h), rec in sorted(keys.items()):
        if (stage, h) in have:
            continue
        path = R.RESIDUE_DIR / stage / ('%s.dxbc' % h)
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists() or path.read_bytes() != rec['blob']:
            path.write_bytes(rec['blob'])
        DX.asm_path(path)
        rows['%s/%s' % (stage, h)] = {k: v for k, v in rec.items() if k != 'blob'}
    KEYS.write_text(json.dumps(rows, indent=1, sort_keys=True) + '\n', 'utf-8')
    print('residue: %d keys -> %s, evidence -> %s' % (len(rows), R.RESIDUE_DIR, KEYS.name))
    print('  by kind:', dict(collections.Counter(r['kind'] for r in rows.values())))
    return 0


def check() -> list:
    """The census's manifest instrument: every shipped DXBC key is in exactly one of
    ``$D3_RE`` / the residue, with the same bytes, and the residue tree is current."""
    problems = []
    keys = atlas_keys()
    have = re_keys()
    committed = json.loads(KEYS.read_text('utf-8'))
    for (stage, h), (sub, pid) in have.items():
        rec = keys.get((stage, h))
        if rec is None:
            problems.append('$D3_RE key %s/%s is not in the atlas' % (sub, h))
        elif rec['program'] != pid:
            problems.append('$D3_RE key %s/%s differs from the atlas bytes' % (sub, h))
    for (stage, h), rec in keys.items():
        name = '%s/%s' % (stage, h)
        if (stage, h) in have:
            if name in committed:
                problems.append('%s is in $D3_RE and in the residue' % name)
            continue
        row = committed.get(name)
        if row is None:
            problems.append('atlas key %s is in neither $D3_RE nor the residue' % name)
            continue
        if row['program'] != rec['program']:
            problems.append('residue key %s: committed program differs from the atlas' % name)
        path = R.RESIDUE_DIR / stage / ('%s.dxbc' % h)
        if not path.exists() or R.program_id(path) != rec['program']:
            problems.append('residue tree is stale at %s -- run extract' % name)
    extra = set(committed) - {'%s/%s' % k for k in keys}
    if extra:
        problems.append('%d residue keys are not in the atlas (e.g. %s)' % (len(extra), sorted(extra)[:3]))
    print('census: atlas %d DXBC keys = $D3_RE %d + residue %d'
          % (len(keys), len(have), len(committed)))
    return problems


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', nargs='?', choices=['extract'])
    ap.add_argument('--check', action='store_true')
    args = ap.parse_args(argv)
    if args.command == 'extract':
        return extract()
    if args.check:
        problems = check()
        for p in problems[:40]:
            print('FAIL', p)
        print('OK' if not problems else '%d problem(s)' % len(problems))
        return 1 if problems else 0
    ap.error('pass extract or --check')


if __name__ == '__main__':
    sys.exit(main())
