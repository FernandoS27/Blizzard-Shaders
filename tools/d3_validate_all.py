#!/usr/bin/env python3
"""Whole-module Diablo III validation: every built slot against its retail program.

For each bundle, every slot with a built D3D11 blob (``compile_all_d3.py``) is
checked twice, against the retail program of its slot:

* **D2** -- declaration surface (``d3_decl_surface.compare``): signatures,
  registers, cbuffer layout and bank declarations, row for row.
* **D4** -- behaviour (``d3_diff.compare_slot``): the slot's full trial schedule
  through the canonical interpreter, classified ``exact`` / ``order-only`` /
  ``fail`` (plan 3.3).

A blob older than any module source fails outright -- a stale build is not
evidence ([[project_build_artifact_staleness]]).

    python tools/d3_validate_all.py --bundle ps_actor
    python tools/d3_validate_all.py --all [--fold]
    python tools/d3_validate_all.py --dump ps_actor:7        # one slot, full report
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import traceback
from collections import Counter
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
import d3_decl_surface as D2              # noqa: E402
import d3_diff as DF                      # noqa: E402
import d3_drivers as DR                   # noqa: E402
import d3_perm_manifest as M              # noqa: E402
import d3_retail as R                     # noqa: E402



def slot_blobs(bid: str, target: str = 'd3d11', subfamilies=None, roots=None):
    """``(slot, retail .dxbc, candidate .dxbc or None)`` for every slot."""
    import compile_all_d3 as CA
    for s in M.load(bid):
        if subfamilies or roots:
            spec, _problem = CA.slot_spec(s, subfamilies, roots)
            if spec is None:
                continue
        r0 = s['retail'][0]
        retail = R.key_dxbc(r0)
        cand = CA.out_path(target, bid, s['slot'])
        yield s['slot'], retail, (cand if cand.exists() else None)


def built_from(bid: str, slot: dict, cand: Path) -> bool:
    """Was this blob compiled from the slot's current spec (compile_all_d3 stamps it)?"""
    import compile_all_d3 as CA
    spec, _problem = CA.slot_spec(slot)
    stamp = Path(str(cand) + '.spec')
    return spec is not None and stamp.exists() and stamp.read_text('utf-8') == repr(spec.key())


def check_slot(job):
    bid, slot, retail, cand, watermark = job
    row = {'bid': bid, 'slot': slot}
    try:
        if Path(cand).stat().st_mtime < watermark:
            row.update(d2=['blob older than module source'], d4='stale')
            return row
        if not built_from(bid, M.load(bid)[slot], Path(cand)):
            row.update(d2=["blob not built from this slot's current spec"], d4='stale')
            return row
        row['d2'] = D2.compare(D2.retail_surface(retail), D2.slang_surface(cand))
        measured = M.load(bid)[slot]['measured']
        ref = DF.Leg.load(retail, slang=False)
        leg = DF.Leg.load(cand, slang=True)
        res = DF.compare_slot(ref, leg, measured, DR.slot_seed(M.load(bid)[slot]['retail'][0]['hash']),
                              DF.input_formats(retail))
        row['d4'] = res.status
        row['result'] = res.as_dict()
    except Exception as e:                                   # noqa: BLE001
        tb = traceback.extract_tb(e.__traceback__)[-1]
        row.update(d4='exception', error='%s: %s @%s:%d' % (type(e).__name__, str(e)[:160],
                                                           Path(tb.filename).name, tb.lineno))
    return row


def fold(bid: str, subfamilies=None, roots=None) -> list:
    """D5: distinct slots must not compile to identical programs."""
    import hashlib
    seen = {}
    problems = []
    import compile_all_d3 as CA
    mine = {slot for slot, _r, cand in slot_blobs(bid, subfamilies=subfamilies, roots=roots) if cand}
    # a filtered or workspace run must still fold against every other slot's blob: the main
    # tree's built bundle stands in for the slots this run did not build (a residue program
    # that differs from a v1 program only in instruction order or binding names compiles to
    # that program's blob)
    main_out = CA.REPO / 'd3_slang_out' / 'd3d11' / bid
    others = [(slot, CA.out_path('d3d11', bid, slot)) for slot in range(len(M.load(bid))) if slot not in mine]
    if CA.OUT_ROOT != CA.REPO / 'd3_slang_out':
        others += [(slot, main_out / ('slot_%04d.dxbc' % slot)) for slot in range(len(M.load(bid)))
                   if slot not in mine]
    for slot, path in others:
        if path.exists():
            seen.setdefault(hashlib.sha1(path.read_bytes()[20:]).hexdigest(), slot)
    for slot, _retail, cand in slot_blobs(bid, subfamilies=subfamilies, roots=roots):
        if cand is None:
            continue
        text = Path(cand).with_suffix('.asm')
        body = Path(cand).read_bytes()
        h = hashlib.sha1(body[20:]).hexdigest()   # past the container hash
        if h in seen:
            problems.append('%s: slots %d and %d compile to one program' % (bid, seen[h], slot))
        seen[h] = slot
    return problems


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--bundle', action='append', default=[])
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--fold', action='store_true')
    ap.add_argument('--dump', default=None)
    ap.add_argument('--jobs', type=int, default=max(1, (os.cpu_count() or 2) - 2))
    ap.add_argument('--subfamily', action='append', default=[])
    ap.add_argument('--root', action='append', default=[])
    args = ap.parse_args(argv)
    import compile_all_d3 as CA
    subs, roots = set(args.subfamily) or None, set(args.root) or None
    REPORTS = CA.OUT_ROOT / '_reports'
    wm = CA.module_mtime()
    if args.dump:
        bid, slot = args.dump.split(':')
        for s, retail, cand in slot_blobs(bid):
            if s == int(slot):
                print(json.dumps(check_slot((bid, s, retail, cand, wm)), indent=1, default=str))
        return 0
    bids = [R.bundle_id(d, s) for d, s in R.bundles()] if args.all else args.bundle
    jobs = [(bid, s, retail, cand, wm) for bid in bids
            for s, retail, cand in slot_blobs(bid, subfamilies=subs, roots=roots) if cand]
    with ProcessPoolExecutor(args.jobs) as ex:
        rows = list(ex.map(check_slot, jobs, chunksize=1))
    REPORTS.mkdir(parents=True, exist_ok=True)
    bad = 0
    for bid in bids:
        mine = [r for r in rows if r['bid'] == bid]
        total = sum(1 for _ in slot_blobs(bid, subfamilies=subs, roots=roots))
        st = Counter(r['d4'] for r in mine)
        d2 = sum(1 for r in mine if r.get('d2'))
        (REPORTS / ('%s.json' % bid)).write_text(json.dumps(mine, indent=1, default=str), 'utf-8')
        print('%-11s built %4d/%-4d  D2 differs %3d  D4 %s' % (bid, len(mine), total, d2, dict(st)))
        # a slot that has a translator but no blob is a failed or missing build, not a pass
        unbuilt = [s['slot'] for s in M.load(bid)
                   if CA.slot_spec(s, subs, roots)[0] is not None
                   and not CA.out_path('d3d11', bid, s['slot']).exists()]
        if unbuilt:
            bad += len(unbuilt)
            print('   %d ported slot(s) have no built blob: %s' % (len(unbuilt), unbuilt[:12]))
        for r in mine:
            if r.get('d2') or r['d4'] not in ('exact', 'order-only'):
                bad += 1
                print('   slot %4d  d4=%-10s %s  %s' % (r['slot'], r['d4'],
                      (r.get('result') or {}).get('error', '') or r.get('error', ''),
                      ' | '.join(r.get('d2') or [])[:300]))
        if args.fold:
            for p in fold(bid, subs, roots):
                bad += 1
                print('   D5 ' + p)
    print('OK' if not bad else '%d problem(s)' % bad)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
