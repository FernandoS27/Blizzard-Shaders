#!/usr/bin/env python3
"""Freeze the Diablo III permutation SET into ``d3_perms/`` and check it (D0, D1).

A **slot** is one distinct retail program (identical ``.dxbc`` bytes) inside one
bundle (stage x domain). Every retail key of every subfamily placed in that
bundle by ``d3_shaders.json`` belongs to exactly one slot. Slots are ordered by
the smallest retail hash they hold -- hashes carry no order, and this one
survives any refactor of the axis schema.

Each slot also records what the bytes say that no manifest does (design 4.3):
the transport and stream signatures, the texture/sampler registers, the bank
declarations and the alpha-test compare spelling.

    python tools/d3_perm_manifest.py                 # (re)write d3_perms/
    python tools/d3_perm_manifest.py --check         # D0: set bijection + manifest not stale
    python tools/d3_perm_manifest.py --partition-local
        # M0 D1: within each subfamily, (local defines + measured axes) never
        # merges two programs -- the key is complete for everything bytes record
    python tools/d3_perm_manifest.py --partition [--bundle ps_actor]
        # D1: the compile spec map_d3 produces splits programs exactly as bytes do
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import d3_dxbc as DX                      # noqa: E402
import d3_retail as R                     # noqa: E402

OUT = R.REPO / 'd3_perms'


def measured(dxbc: Path, stage: str) -> dict:
    blob = dxbc.read_bytes()
    text = dxbc.with_suffix('.asm').read_text('utf-8', errors='replace')
    rd = DX.rdef(blob)
    dcl = DX.dcl_facts(text)
    res = [[r['register'], r['kind'], r['dim'], r['comparison'], r['name'].lstrip('$')]
           for r in rd['resources'] if r['kind'] in ('texture', 'sampler')]
    m = {
        'transport': [list(r) for r in DX.signature(blob, 'ISGN' if stage == 'ps' else 'OSGN')],
        'resources': sorted(res),
        'banks': {str(k): list(v) for k, v in sorted(dcl['cbuffers'].items())},
        'alphaCompare': R.alpha_compares(text),
        'lights': ('cb2[%d]' % R.NUM_LIGHTS_ROW) in text,
    }
    if '_aoffimmi(' in text:
        # a neighbourhood filter (FXAA): its deep branches need the denser R1 schedule
        m['offsets'] = True
    if stage == 'vs':
        m['streams'] = [list(r) for r in DX.signature(blob, 'ISGN')]
    else:
        m['outputs'] = [list(r) for r in DX.signature(blob, 'OSGN')]
    return m


#: provisional bundle of a residue program nothing has placed yet, by the atlas's .fx evidence
FX_DOMAIN = {
    'Legacy.fx': 'legacy', 'Billboard.fx': 'legacy', 'SoftBillboard.fx': 'legacy',
    'Distortion.fx': 'legacy', 'SoftParticleLegacy.fx': 'legacy',
    'Scene.fx': 'surface', 'Prop.fx': 'surface', 'Landscape.fx': 'surface',
    'InteractiveFog.fx': 'surface', 'Reflection.fx': 'surface', 'Puddle.fx': 'surface',
    'Actor.fx': 'actor', 'ActorIrrad.fx': 'actor', 'banner.fx': 'actor',
    'TextureFilter.fx': 'utility', 'PostFX.fx': 'utility', 'FSAA.fx': 'utility',
    'FSAA AMD.fx': 'utility', 'Minimap.fx': 'utility', 'Shadows.fx': 'utility',
}


def provisional_domain(keys: list) -> str:
    """Where a pending residue program waits: its singleton's .fx, else the attributed or
    guessed .fx, else its assets' names. Placement (``d3_residue.json``) overrides it."""
    votes = defaultdict(int)
    for k in keys:
        fxs = ([k.subfamily.split('__')[0]] if k.kind == 'singleton' else
               k.evidence['fx'] or ([k.evidence['fxGuess']] if k.evidence['fxGuess'] else []))
        for fx in fxs:
            if fx in FX_DOMAIN:
                votes[FX_DOMAIN[fx]] += 1
        for s in k.shaders:
            votes['actor' if s.startswith('actor') else
                  'surface' if s.split('_')[0] in ('scene', 'sm3', 'terrain', 'terrain4', 'tree', 'cloud')
                  else 'legacy'] += 0.5
    return max(sorted(votes), key=lambda d: votes[d]) if votes else 'legacy'


#: residue programs no slot holds and d3_residue.json does not place (filled by build)
PENDING = {}


def build() -> dict:
    """``{bundle id: [slot, ...]}`` from ``$D3_RE`` plus the residue.

    A slot holds ``$D3_RE`` rows first (so ``retail[0]``, the seed and the translator
    key of every v1 slot are unchanged), then residue rows. Slots with a ``$D3_RE``
    row keep their v1 order; residue-only slots follow, by smallest residue hash."""
    subs = R.subfamilies()
    progs = {R.bundle_id(d, s): defaultdict(list) for d, s in R.bundles()}
    for sf in subs.values():
        for k in sf.keys:
            row = {'subfamily': sf.name, 'hash': k.hash, 'defines': k.defines, 'shaders': k.shaders}
            progs[R.bundle_id(sf.domain, sf.stage)][R.program_id(k.dxbc)].append((row, k.dxbc, sf.root))
    where = {pid: bid for bid, by in progs.items() for pid in by}
    placed = R.residue_config()
    residue = defaultdict(list)
    for k in R.residue_keys():
        residue[k.program].append(k)
    PENDING.clear()
    for pid, keys in sorted(residue.items()):
        stage = keys[0].stage
        root = placed.get(pid, {}).get('root')
        if pid in where:
            bid = where[pid]
        elif root and R.root_bundle(root):
            bid = R.bundle_id(*R.root_bundle(root))
        else:
            bid = R.bundle_id(provisional_domain(keys), stage)
            PENDING[pid] = bid
        for k in keys:
            row = {'subfamily': k.subfamily, 'hash': k.hash, 'defines': {}, 'shaders': k.shaders,
                   'residue': k.kind}
            progs[bid][pid].append((row, k.dxbc, root))
    out = {}
    for domain, stage in R.bundles():
        bid = R.bundle_id(domain, stage)
        slots = []
        for pid, members in progs[bid].items():
            members.sort(key=lambda m: (bool(m[0].get('residue')), m[0]['hash']))
            slots.append({
                'program': pid,
                'roots': sorted({root for _row, _dx, root in members if root}),
                'retail': [row for row, _dx, _root in members],
                'measured': measured(members[0][1], stage),
            })
        slots.sort(key=lambda s: (bool(s['retail'][0].get('residue')), s['retail'][0]['hash']))
        for i, s in enumerate(slots):
            s['slot'] = i
        out[bid] = slots
    return out


def write(manifest: dict) -> None:
    OUT.mkdir(exist_ok=True)
    index = {'hash': {}, 'slots': {}}
    for bid, slots in manifest.items():
        rows = [{k: s[k] for k in ('slot', 'roots', 'program', 'retail', 'measured')} for s in slots]
        (OUT / ('%s.json' % bid)).write_text(json.dumps(rows, indent=1) + '\n', 'utf-8')
        for s in slots:
            for r in s['retail']:
                index['hash']['%s/%s' % (r['subfamily'], r['hash'])] = [bid, s['slot']]
            index['slots']['%s/%d' % (bid, s['slot'])] = sorted({r['subfamily'] for r in s['retail']})
    (OUT / '_index.json').write_text(json.dumps(index, indent=1, sort_keys=True) + '\n', 'utf-8')
    pending = [{'program': pid, 'bundle': bid,
                'slot': next(s['slot'] for s in manifest[bid] if s['program'] == pid)}
               for pid, bid in sorted(PENDING.items(), key=lambda kv: (kv[1], kv[0]))]
    for p in pending:
        p['slot'] = '%s/%d' % (p.pop('bundle'), p['slot'])
    (OUT / '_residue_pending.json').write_text(json.dumps(pending, indent=1) + '\n', 'utf-8')


def load(bid: str) -> list:
    return json.loads((OUT / ('%s.json' % bid)).read_text('utf-8'))


# --------------------------------------------------------------------------
# D0
# --------------------------------------------------------------------------

def check(manifest: dict, allow_pending: bool = False) -> list:
    problems = []
    cfg = R.load_config()
    if R.unplaced():
        problems.append('RE subfamilies placed in no root: %s' % R.unplaced())
    seen_keys = {}
    all_keys = {(sf.name, k.hash) for sf in R.subfamilies().values() for k in sf.keys}
    all_keys |= {(k.subfamily, k.hash) for k in R.residue_keys()}
    for pid, spec in R.residue_config().items():
        if not R.root_bundle(spec.get('root', '')):
            problems.append('d3_residue.json: program %s names unknown root %r' % (pid[:8], spec.get('root')))
        if pid not in {k.program for k in R.residue_keys()}:
            problems.append('d3_residue.json: program %s is not a residue program' % pid[:8])
    for bid, slots in manifest.items():
        stage, domain = bid.split('_', 1)
        want = cfg[domain][stage]['slots']
        if len(slots) != want:
            problems.append('%s: %d slots, config says %d' % (bid, len(slots), want))
        pids = [s['program'] for s in slots]
        if len(set(pids)) != len(pids):
            problems.append('%s: two slots share one program' % bid)
        for s in slots:
            if not s['roots'] and s['program'] in PENDING:
                if not allow_pending:
                    problems.append('%s slot %d: residue program %s is not placed yet'
                                    % (bid, s['slot'], s['program'][:8]))
            elif len(s['roots']) != 1:
                problems.append('%s slot %d: one program spans roots %s -- regroup'
                                % (bid, s['slot'], s['roots']))
            for r in s['retail']:
                key = (r['subfamily'], r['hash'])
                if key in seen_keys:
                    problems.append('key %s/%s in two slots' % key)
                seen_keys[key] = (bid, s['slot'])
                if R.program_id(R.key_dxbc(r)) != s['program']:
                    problems.append('%s slot %d: key %s is not the slot program' % (bid, s['slot'], r['hash']))
    if PENDING:
        print('D0: %d residue program(s) pending placement%s'
              % (len(PENDING), ' (allowed)' if allow_pending else ''))
    missing = all_keys - set(seen_keys)
    if missing:
        problems.append('%d retail keys in no slot (e.g. %s)' % (len(missing), sorted(missing)[:3]))
    # committed manifest must equal a rebuild
    for bid, slots in manifest.items():
        path = OUT / ('%s.json' % bid)
        if not path.exists():
            problems.append('%s missing -- run tools/d3_perm_manifest.py' % path.name)
            continue
        committed = json.loads(path.read_text('utf-8'))
        fresh = json.loads(json.dumps([{k: s[k] for k in ('slot', 'roots', 'program', 'retail', 'measured')}
                                       for s in slots]))
        if committed != fresh:
            problems.append('%s is stale against $D3_RE -- rebuild it' % path.name)
    return problems


# --------------------------------------------------------------------------
# D1
# --------------------------------------------------------------------------

def _partition_report(groups_by_key: dict, what: str) -> tuple:
    """``groups_by_key``: {key: set(program)}. Merges = keys naming >1 program."""
    merges = {k: v for k, v in groups_by_key.items() if len(v) > 1}
    return merges


def partition_local(manifest: dict) -> list:
    """Within each subfamily: does (local defines, measured axes) name one program?"""
    problems = []
    rescued = 0
    for bid, slots in manifest.items():
        by_local = defaultdict(set)
        by_defines = defaultdict(set)
        for s in slots:
            m = s['measured']
            meas = json.dumps([m['transport'], m.get('streams'), m['resources'],
                               m['alphaCompare']], sort_keys=True)
            for r in s['retail']:
                d = json.dumps(r['defines'], sort_keys=True)
                by_local[(r['subfamily'], d, meas)].add(s['program'])
                by_defines[(r['subfamily'], d)].add(s['program'])
        for key, progs in by_local.items():
            if len(progs) > 1:
                problems.append('%s %s: defines+measured name %d programs' % (bid, key[0], len(progs)))
        rescued += sum(len(v) - 1 for v in by_defines.values() if len(v) > 1)
    print('manifest define maps that name >1 program: %d extra programs, all separated by '
          'measured axes unless listed below' % rescued)
    return problems


def partition_spec(manifest: dict, only: str | None) -> list:
    """D1 proper: the compile spec is the canonical key."""
    import d3_shaders_cfg as C                       # noqa: E402  (lands with M1)
    problems = []
    for bid, slots in manifest.items():
        if only and bid != only:
            continue
        stage, domain = bid.split('_', 1)
        by_spec = defaultdict(set)
        spec_of_prog = defaultdict(set)
        ported = 0
        for s in slots:
            for r in s['retail']:
                spec = C.row_spec(r, s['measured'], s['program'])
                if spec is None:
                    continue
                spec = spec.key()
                by_spec[spec].add(s['program'])
                spec_of_prog[s['program']].add(spec)
                ported += 1
        merges = sum(1 for v in by_spec.values() if len(v) > 1)
        splits = sum(1 for v in spec_of_prog.values() if len(v) > 1)
        print('%-12s keys ported %4d  programs %4d  specs %4d  merges %d  splits %d'
              % (bid, ported, len(spec_of_prog), len(by_spec), merges, splits))
        for spec, progs in by_spec.items():
            if len(progs) > 1:
                problems.append('%s: one spec names %d programs: %s' % (bid, len(progs), spec[:200]))
        for prog, specs in spec_of_prog.items():
            if len(specs) > 1:
                problems.append('%s: program %s gets %d specs (duplicate slot)' % (bid, prog[:8], len(specs)))
    return problems


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--partition-local', action='store_true')
    ap.add_argument('--partition', action='store_true')
    ap.add_argument('--bundle', default=None)
    ap.add_argument('--allow-pending', action='store_true',
                    help='D0 during M7: residue programs not yet placed are reported, not failed')
    args = ap.parse_args(argv)

    manifest = build()
    if not (args.check or args.partition_local or args.partition):
        write(manifest)
        for bid, slots in manifest.items():
            print('%-12s %4d slots  %4d keys' % (bid, len(slots), sum(len(s['retail']) for s in slots)))
        return 0
    problems = []
    if args.check:
        problems += check(manifest, args.allow_pending)
        print('D0: %d bundles, %d slots, %d keys' % (len(manifest), sum(map(len, manifest.values())),
              sum(len(s['retail']) for v in manifest.values() for s in v)))
    if args.partition_local:
        problems += partition_local(manifest)
    if args.partition:
        problems += partition_spec(manifest, args.bundle)
    for p in problems:
        print('FAIL', p)
    print('OK' if not problems else '%d problem(s)' % len(problems))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
