#!/usr/bin/env python3
"""M0 retail-only controls: the D3 differential must be right before any slang exists.

1. **Identity.** Every slot's retail program against itself, on its full trial
   schedule, float32 and wide mode: exact, no exceptions. Any exception here is
   a driver producing an input outside the engine's domain.
2. **Tie siblings.** Two retail programs of one subfamily with the same local
   defines that differ only in the alpha compare spelling (design 0.2): exact on
   R0-R3, and the tie trials must catch them.
3. **Signature siblings.** Same defines, different transport: D2 (declaration
   surface) must catch them. Behaviour, compared by semantic, stays exact for a
   pixel pair; a vertex pair's output semantics differ, so D4 catches it too.

    python tools/d3_retail_controls.py [--jobs 22] [--only identity|siblings]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import traceback
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import d3_diff as DF                      # noqa: E402
import d3_drivers as DR                   # noqa: E402
import d3_perm_manifest as M              # noqa: E402
import d3_retail as R                     # noqa: E402

BIDS = [R.bundle_id(d, s) for d, s in R.bundles()]


def identity(job):
    bid, slot = job
    s = slot
    r0 = s['retail'][0]
    dx = R.key_dxbc(r0)
    try:
        leg = DF.Leg.load(dx, slang=False)
        fm = DF.input_formats(dx)
        seed0 = DR.slot_seed(r0['hash'])
        res = DF.compare_slot(leg, leg, s['measured'], seed0, fm)
        # wide identity: the whole schedule in wide mode must also be exact
        wide_bad = 0
        for regime, off in DR.schedule(s['measured']):
            if regime == 'T':
                continue
            a = leg.run(seed0 + off, regime, fm, wide=True)
            b = leg.run(seed0 + off, regime, fm, wide=True)
            if a.discarded != b.discarded or not DF._compare_outputs(leg, leg, a, b)[0]:
                wide_bad += 1
        return {'bid': bid, 'slot': s['slot'], 'status': res.status, 'trials': res.trials,
                'ties': [res.ties_achieved, res.tie_attempts], 'wide_bad': wide_bad,
                'error': res.error}
    except Exception as e:                                   # noqa: BLE001
        tb = traceback.extract_tb(e.__traceback__)[-1]
        return {'bid': bid, 'slot': s['slot'], 'status': 'exception',
                'error': '%s: %s @%s:%d' % (type(e).__name__, e, Path(tb.filename).name, tb.lineno)}


def sibling_pairs():
    pairs = []
    for bid in BIDS:
        slots = M.load(bid)
        by_def = defaultdict(list)
        for s in slots:
            for r in s['retail']:
                if r.get('residue'):     # no local defines: nothing makes two residue programs siblings
                    continue
                by_def[(r['subfamily'], json.dumps(r['defines'], sort_keys=True))].append((s, r))
        for key, members in by_def.items():
            progs = {}
            for s, r in members:
                progs.setdefault(s['program'], (s, r))
            items = list(progs.values())
            for i in range(1, len(items)):
                a, b = items[0], items[i]
                ma, mb = a[0]['measured'], b[0]['measured']
                kind = []
                if ma['alphaCompare'] != mb['alphaCompare']:
                    kind.append('tie')
                if ma['transport'] != mb['transport'] or ma.get('streams') != mb.get('streams'):
                    kind.append('signature')
                if ma['resources'] != mb['resources']:
                    kind.append('resources')
                pairs.append((bid, '+'.join(kind) or 'none', a, b))
    return pairs


def sibling(job):
    bid, kind, a, b = job
    sa, ra = a
    sb, rb = b
    da, db = R.key_dxbc(ra), R.key_dxbc(rb)
    import d3_decl_surface as D2
    d2 = D2.compare(D2.retail_surface(da), D2.retail_surface(db))
    try:
        ref, cand = DF.Leg.load(da, slang=False), DF.Leg.load(db, slang=False)
        res = DF.compare_slot(ref, cand, sa['measured'], DR.slot_seed(ra['hash']), DF.input_formats(da))
        d4 = res.status
        tie = res.tie_mismatch
        err = res.error
    except Exception as e:                                   # noqa: BLE001
        d4, tie, err = 'exception', 0, str(e)
    return {'bid': bid, 'kind': kind, 'sub': ra['subfamily'], 'a': ra['hash'], 'b': rb['hash'],
            'd2_fail': bool(d2), 'd4': d4, 'tie_mismatch': tie, 'error': err[:160]}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--jobs', type=int, default=max(1, (os.cpu_count() or 2) - 2))
    ap.add_argument('--only', choices=('identity', 'siblings'))
    args = ap.parse_args(argv)
    bad = 0
    with ProcessPoolExecutor(args.jobs) as ex:
        if args.only != 'siblings':
            jobs = [(bid, s) for bid in BIDS for s in M.load(bid)]
            out = list(ex.map(identity, jobs, chunksize=4))
            st = Counter(o['status'] for o in out)
            wide = sum(o.get('wide_bad', 0) for o in out)
            ties = [o['ties'] for o in out if o.get('ties') and o['ties'][1]]
            short = [o for o in out if o.get('ties') and o['ties'][1] and o['ties'][0] < 16]
            print('identity: %d slots %s, wide-mode mismatching trials %d, slots with tie trials %d '
                  '(achieved < 16: %d)' % (len(out), dict(st), wide, len(ties), len(short)))
            for o in out:
                if o['status'] != 'exact' or o.get('wide_bad'):
                    bad += 1
                    print('  FAIL %s/%d %s %s' % (o['bid'], o['slot'], o['status'], o['error']))
            for o in short[:20]:
                print('  ties %s/%d achieved %d/%d' % (o['bid'], o['slot'], o['ties'][0], o['ties'][1]))
        if args.only != 'identity':
            pairs = sibling_pairs()
            out = list(ex.map(sibling, pairs))
            print('siblings: %d pairs %s' % (len(out), dict(Counter(o['kind'] for o in out))))
            for o in out:
                caught_d2 = o['d2_fail']
                caught_tie = o['tie_mismatch'] > 0
                if o['kind'] == 'tie':
                    ok = (not caught_d2) and o['d4'] == 'fail' and caught_tie
                elif o['kind'].startswith('signature'):
                    ok = caught_d2
                else:
                    ok = False
                mark = 'ok  ' if ok else 'MISS'
                if not ok:
                    bad += 1
                print('  [%s] %-9s %-40s %s %s d2_fail=%s d4=%s tie_mismatch=%d %s'
                      % (mark, o['kind'], o['sub'], o['a'], o['b'], caught_d2, o['d4'],
                         o['tie_mismatch'], o['error'] if not ok else ''))
    print('OK' if not bad else '%d problem(s)' % bad)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
