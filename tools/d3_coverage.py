#!/usr/bin/env python3
"""Gate D4c -- does the D4 schedule reach both outcomes of every retail decision?

A differential can only find a wrong branch the inputs actually take. This runs
the RETAIL leg of every slot over its full D4 schedule (``d3_drivers.schedule``,
tie trials included) and records, per instruction, which outcomes occurred:

* every written lane of every compare (``lt ge eq ne ieq ige ilt ine ult uge``);
* every ``if`` / ``breakc`` / ``continuec`` / ``discard`` / ``retc`` condition.

A decision that only ever goes one way is a hole in the drivers, not a property
of the shader -- unless it is listed in ``d3_perms/_reach_exceptions.json``
with the reason the retail program cannot reach the other outcome.

It needs no slang, so it is an M0 gate: run it against the R0-only schedule to
see the plan's measured 107 lanes (``--regimes R0``), and against the full one
for the gate.

    python tools/d3_coverage.py [--bundle ps_surface] [--regimes R0,R1] [--jobs 22]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import d3_diff as DF                      # noqa: E402
import d3_drivers as DR                   # noqa: E402
import d3_perm_manifest as M              # noqa: E402
import d3_retail as R                     # noqa: E402
import dxbc_interp as DI                  # noqa: E402

EXCEPTIONS = M.OUT / '_reach_exceptions.json'
CMP = {'lt', 'ge', 'eq', 'ne', 'ieq', 'ige', 'ilt', 'ine', 'ult', 'uge'}
CTRL = {'if', 'breakcz', 'continuecz', 'discard', 'retc'}


def _walk(nodes, acc, path=()):
    for i, n in enumerate(nodes):
        acc.append(n)
        if n[0] == 'if':
            _walk(n[3], acc); _walk(n[4], acc)
        elif n[0] == 'loop':
            _walk(n[1], acc)
        elif n[0] == 'switch':
            for _v, body in n[2]:
                _walk(body, acc)


def _cond_lane(opd):
    return 0 if opd[0] == 'lit' else opd[4][0]


def _describe(n):
    if n[0] == 'op':
        return '%s %s' % (n[1], ', '.join(n[4]))
    return '%s' % n[0]


def slot_reach(job):
    bid, slot, regimes = job
    r0 = slot['retail'][0]
    dx = R.key_dxbc(r0)
    leg = DF.Leg.load(dx, slang=False)
    fm = DF.input_formats(dx)
    seed0 = DR.slot_seed(r0['hash'])
    seen = defaultdict(set)

    def tr(vm, node, phase):
        if node[0] == 'op':
            if phase == 'post' and node[1] in CMP and node[2] and node[2][0] == 'r':
                arr = vm.r[node[2][1]]
                for c in node[2][3]:
                    seen[(id(node), c)].add(arr[c] != 0)
            elif (phase == 'post' and node[1].endswith('_sat') and node[2]
                  and node[2][0] in ('r', 'o')):
                # clamp decision: did the saturate bind (result exactly 0 or 1) or not
                arr = vm.r[node[2][1]] if node[2][0] == 'r' else vm.o[node[2][1]]
                for c in node[2][3]:
                    v = DI.b2f(arr[c])
                    seen[(id(node), c)].add(v == 0.0 or v == 1.0)
            elif phase == 'pre' and node[1] in ('min', 'max') and node[2] and node[2][0] in ('r', 'o'):
                # selection decision: which operand the min/max returned
                a, b = vm.fread(node[3][0]), vm.fread(node[3][1])
                for c in node[2][3]:
                    if a[c] == a[c] and b[c] == b[c] and a[c] != b[c]:
                        seen[(id(node), c)].add(a[c] < b[c])
        elif node[0] in CTRL and phase == 'pre':
            cond = node[1] if node[0] != 'if' else node[2]
            seen[(id(node), -1)].add(vm.uread(cond)[_cond_lane(cond)] != 0)

    for regime, off in DR.schedule(slot['measured']):
        if regime not in regimes:
            continue
        overrides = None
        if regime == 'T':
            overrides, ok = DF.tie_overrides(leg, seed0 + off, fm)
            if not ok:
                continue
        elif regime == 'N':
            overrides = {(0, DR.ALPHA_REF_ROW, 3): DR.NAN_BITS}
        leg.run(seed0 + off, regime, fm, overrides=overrides, trace=tr)

    nodes = []
    _walk(leg.prog.ast, nodes)
    holes, total = [], 0
    for pos, n in enumerate(nodes):
        if n[0] == 'op' and n[1] in CMP and n[2] and n[2][0] == 'r':
            lanes = n[2][3]
        elif n[0] == 'op' and n[2] and n[2][0] in ('r', 'o') and (
                n[1].endswith('_sat') or n[1] in ('min', 'max')):
            lanes = n[2][3]
            if any(s[0] == 'lit' for s in n[3][:2]) and n[1] in ('min', 'max') and \
                    all(s[0] == 'lit' for s in n[3][:2]):
                continue
        elif n[0] in CTRL:
            lanes = [-1]
        else:
            continue
        for c in lanes:
            total += 1
            s = seen.get((id(n), c), set())
            if len(s) < 2:
                holes.append({'at': pos, 'lane': 'xyzw'[c] if c >= 0 else '', 'insn': _describe(n),
                              'seen': sorted(s)})
    return {'bid': bid, 'slot': slot['slot'], 'sub': r0['subfamily'], 'decisions': total, 'holes': holes}


def load_exceptions() -> dict:
    if not EXCEPTIONS.exists():
        return {}
    return json.loads(EXCEPTIONS.read_text('utf-8'))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--bundle', action='append', default=[])
    ap.add_argument('--regimes', default=','.join(DR.REGIMES))
    ap.add_argument('--jobs', type=int, default=max(1, (os.cpu_count() or 2) - 2))
    ap.add_argument('--dump', default=None, help='write every hole to this JSON')
    args = ap.parse_args(argv)
    regimes = set(args.regimes.split(','))
    bids = args.bundle or [R.bundle_id(d, s) for d, s in R.bundles()]
    jobs = [(bid, s, regimes) for bid in bids for s in M.load(bid)]
    with ProcessPoolExecutor(args.jobs) as ex:
        out = list(ex.map(slot_reach, jobs, chunksize=4))
    exc = load_exceptions()
    total = sum(o['decisions'] for o in out)
    holes = [(o, h) for o in out for h in o['holes']]
    unexplained = [(o, h) for o, h in holes
                   if not any(e['insn'] == h['insn'] and e['lane'] == h['lane']
                              and (e.get('subfamily') in (None, o['sub']))
                              for e in exc.get('decisions', []))]
    by_sub = Counter(o['sub'] for o, _ in unexplained)
    kinds = Counter((h['insn'].split(' ')[0], tuple(h['seen'])) for _o, h in unexplained)
    print('decisions %d, one-sided or unreached %d, excepted %d, unexplained %d (in %d slots)'
          % (total, len(holes), len(holes) - len(unexplained), len(unexplained),
             len({(o['bid'], o['slot']) for o, _ in unexplained})))
    print('by subfamily:', by_sub.most_common(12))
    print('by kind:', kinds.most_common(12))
    if args.dump:
        Path(args.dump).write_text(json.dumps([dict(h, bid=o['bid'], slot=o['slot'], sub=o['sub'])
                                               for o, h in unexplained], indent=1), 'utf-8')
    return 1 if unexplained else 0


if __name__ == '__main__':
    sys.exit(main())
