#!/usr/bin/env python3
"""Place residue programs by trying the specs of their nearest ported slots (plan M7).

A residue program (``tools/d3_residue.py``) has no RE uber and no local defines,
but most of them are permutations of subfamilies already ported: the same root
with a combination no v1 key happened to use, or a v1 combination under a
different signature or register layout. For each pending program this

1. ranks every ported slot of the same stage by how alike the two retail
   instruction streams are (opcode histogram, then a line-level diff of the
   normalized body);
2. takes the distinct specializations of the nearest slots -- each also with
   its alpha-test policy re-read from the residue program's own compare;
3. compiles each one with the residue program's measured declarations and
   judges it exactly as ``d3_validate_all.py`` does: D2, then a short D4 screen,
   then the full D4 schedule;
4. records the first spec that passes -- unless another program already has
   that spec or compiles to the same blob (D1 / D5): two retail programs that
   differ only in instruction order or binding names pass each other's D4, and
   the placement must then come from porting, not from a neighbour.

Nothing found here is a guess: a placement is written only for a spec that is
D2-identical and D4 exact or order-only on the full schedule, and ``--apply``
drops every pair of new placements that share a spec or a blob.

    python tools/d3_spec_search.py [--bundle ps_legacy] [--top 6] [--jobs 20]
    python tools/d3_spec_search.py --apply        # merge the passes into d3_residue.json
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
import re
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
import d3_dxbc as DX                      # noqa: E402
import d3_perm_manifest as M              # noqa: E402
import d3_retail as R                     # noqa: E402
import d3_shaders_cfg as C                # noqa: E402

REPORT = R.REPO / 'd3_perms' / '_spec_search.json'
_TOKEN = [(re.compile(r'\br\d+\b'), 'r'), (re.compile(r'\b([tsvo])\d+\b'), r'\1'),
          (re.compile(r'\bicb\[\d+\]'), 'icb[]')]
ALPHA_POLICIES = set(C._ALPHA.values()) | {'AlphaTestOff'}


def body(dxbc: Path) -> list:
    """Instruction lines past the declarations, temps and I/O registers anonymized."""
    out = []
    for line in DX.asm_path(dxbc, refresh=False).read_text('utf-8', errors='replace').splitlines():
        s = line.strip()
        if not s or s.startswith(('//', 'dcl_', 'ps_', 'vs_')):
            continue
        for rx, rep in _TOKEN:
            s = rx.sub(rep, s)
        out.append(s)
    return out


def library(stage: str) -> list:
    """``(bid, slot, spec, retail dxbc)`` for every ported slot of one stage."""
    import compile_all_d3 as CA
    out = []
    for d, s in R.bundles():
        if s != stage:
            continue
        bid = R.bundle_id(d, s)
        for slot in M.load(bid):
            spec, _problem = CA.slot_spec(slot)
            if spec is not None:
                out.append((bid, slot['slot'], spec, R.key_dxbc(slot['retail'][0])))
    return out


def candidates(target: list, lib: list, measured: dict, top: int) -> list:
    """Distinct ``(entry, specialize)`` of the nearest library slots, best first."""
    ops = Counter(line.split(' ', 1)[0] for line in target)
    scored = []
    for bid, slot, spec, dx in lib:
        other = LIB_BODIES[dx]
        o2 = Counter(line.split(' ', 1)[0] for line in other)
        inter = sum((ops & o2).values())
        union = sum((ops | o2).values()) or 1
        scored.append((inter / union, bid, slot, spec, dx))
    scored.sort(key=lambda x: -x[0])
    ranked = []
    for _j, bid, slot, spec, dx in scored[:max(40, top * 6)]:
        ratio = difflib.SequenceMatcher(None, target, LIB_BODIES[dx], autojunk=False).ratio()
        ranked.append((ratio, bid, slot, spec))
    ranked.sort(key=lambda x: -x[0])
    seen, out = set(), []
    want = C.alpha_test(measured)
    for ratio, bid, slot, spec in ranked:
        variants = [spec.specialize]
        swapped = tuple(want if s in ALPHA_POLICIES else s for s in spec.specialize)
        if swapped != spec.specialize:
            variants.insert(0, swapped)
        for sp in variants:
            key = (spec.entry, sp)
            if key in seen:
                continue
            seen.add(key)
            out.append({'root': spec.entry, 'specialize': list(sp), 'near': '%s/%d' % (bid, slot),
                        'similarity': round(ratio, 4)})
        if len(out) >= top:
            break
    return out[:top]


LIB_BODIES = {}
LIBS = {}
USED_SPECS = set()
USED_BLOBS = set()


def blob_id(dxbc: Path) -> str:
    """A compiled program's identity past its container hash (as D5 counts it)."""
    return hashlib.sha1(Path(dxbc).read_bytes()[20:]).hexdigest()


def _init(stage_libs):
    import compile_all_d3 as CA
    LIBS.update(stage_libs)
    for lib in stage_libs.values():
        for bid, slot, spec, dx in lib:
            LIB_BODIES[dx] = body(dx)
            USED_SPECS.add(spec.key())
            built = CA.out_path('d3d11', bid, slot)
            if built.exists():
                USED_BLOBS.add(blob_id(built))


def judge(retail: Path, cand: Path, measured: dict, seed_hash: str) -> dict:
    d2 = D2.compare(D2.retail_surface(retail), D2.slang_surface(cand))
    if d2:
        return {'d2': d2[:4], 'd4': 'skipped'}
    ref = DF.Leg.load(retail, slang=False)
    leg = DF.Leg.load(cand, slang=True)
    fm = DF.input_formats(retail)
    seed0 = DR.slot_seed(seed_hash)
    full = DR.schedule(measured)
    screen = [e for e in full if e[0] == 'R0'][:16] + [e for e in full if e[0] == 'R1'][:16]
    res = DF.compare_slot(ref, leg, measured, seed0, fm, schedule=screen)
    if not res.ok():
        return {'d2': [], 'd4': 'screen-' + res.status, 'error': res.error[:200]}
    res = DF.compare_slot(ref, leg, measured, seed0, fm)
    return {'d2': [], 'd4': res.status, 'error': res.error[:200]}


def search(job) -> dict:
    import compile_all_d3 as CA
    import compile_all_slang as cas
    bid, slot, top = job
    stage = bid.split('_', 1)[0]
    lib = LIBS[stage]
    retail = R.key_dxbc(slot['retail'][0])
    row = {'program': slot['program'], 'slot': '%s/%d' % (bid, slot['slot']), 'tried': [], 'placed': None}
    try:
        measured = slot['measured']
        decl = tuple(sorted(C.declaration_defines(measured)))
        tgt = cas.TARGETS['d3d11']
        work = CA.OUT_ROOT / '_search' / bid
        work.mkdir(parents=True, exist_ok=True)
        for k, cand in enumerate(candidates(body(retail), lib, measured, top)):
            if (cand['root'], tuple(cand['specialize']), decl) in USED_SPECS:
                cand['d4'] = 'spec-taken'
                row['tried'].append(cand)
                continue
            out = work / ('%s_%d.dxbc' % (slot['program'][:12], k))
            for stale in (out, out.with_suffix('.asm')):
                if stale.exists():
                    stale.unlink()
            ok = cas.invoke_slangc(cand['root'], tgt['target'], tgt[stage].replace('_5_0', '_4_0'),
                                   cand['specialize'], out, C.MODULE, extra=tgt['extra'],
                                   include_dirs=[C.INCLUDE], defines=list(decl))
            if ok and blob_id(out) in USED_BLOBS:
                verdict = {'d4': 'blob-taken'}
            else:
                verdict = judge(retail, out, measured, slot['retail'][0]['hash']) if ok else {'d4': 'nocompile'}
            cand.update(verdict)
            row['tried'].append(cand)
            if verdict['d4'] in ('exact', 'order-only'):
                row['placed'] = {'root': cand['root'], 'specialize': cand['specialize']}
                row['spec'] = hashlib.sha1(repr((cand['root'], tuple(cand['specialize']), decl)).encode()).hexdigest()
                row['blob'] = blob_id(out)
                break
    except Exception as e:                                   # noqa: BLE001
        tb = traceback.extract_tb(e.__traceback__)[-1]
        row['error'] = '%s: %s @%s:%d' % (type(e).__name__, str(e)[:160], Path(tb.filename).name, tb.lineno)
    return row


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--bundle', action='append', default=[])
    ap.add_argument('--top', type=int, default=6)
    ap.add_argument('--jobs', type=int, default=max(1, (os.cpu_count() or 2) - 2))
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--apply', action='store_true')
    args = ap.parse_args(argv)

    if args.apply:
        rows = [r for r in json.loads(REPORT.read_text('utf-8')) if r.get('placed')]
        cfg = json.loads(R.RESIDUE_CONFIG.read_text('utf-8')) if R.RESIDUE_CONFIG.exists() else {}
        spec_n = Counter(r.get('spec') for r in rows)
        blob_n = Counter(r.get('blob') for r in rows)
        added, dropped = 0, 0
        for r in rows:
            if spec_n[r.get('spec')] > 1 or blob_n[r.get('blob')] > 1:
                dropped += 1
                continue
            if r['program'] not in cfg:
                cfg[r['program']] = r['placed']
                added += 1
        if dropped:
            print('dropped %d placement(s) sharing a spec or a blob with another' % dropped)
        R.RESIDUE_CONFIG.write_text(json.dumps(cfg, indent=1, sort_keys=True) + '\n', 'utf-8')
        print('placed %d program(s) into %s' % (added, R.RESIDUE_CONFIG.name))
        return 0

    M.build()
    pending = json.loads((M.OUT / '_residue_pending.json').read_text('utf-8'))
    jobs_by_stage = {}
    for p in pending:
        bid, n = p['slot'].split('/')
        if args.bundle and bid not in args.bundle:
            continue
        jobs_by_stage.setdefault(bid.split('_')[0], []).append((bid, M.load(bid)[int(n)]))
    if args.limit:
        jobs_by_stage = {s: v[:args.limit] for s, v in jobs_by_stage.items()}
    libs = {s: library(s) for s in jobs_by_stage}
    print('pending %s; library %s' % ({s: len(v) for s, v in jobs_by_stage.items()},
                                      {s: len(v) for s, v in libs.items()}), flush=True)
    jobs = [(bid, slot, args.top) for s, v in jobs_by_stage.items() for bid, slot in v]
    rows = []
    with ProcessPoolExecutor(args.jobs, initializer=_init, initargs=(libs,)) as ex:
        for i, row in enumerate(ex.map(search, jobs, chunksize=1)):
            rows.append(row)
            if (i + 1) % 25 == 0:
                print('  %d/%d searched, %d placed' % (i + 1, len(jobs), sum(1 for r in rows if r['placed'])),
                      flush=True)
    old = {r['program']: r for r in json.loads(REPORT.read_text('utf-8'))} if REPORT.exists() else {}
    old.update({r['program']: r for r in rows})
    REPORT.write_text(json.dumps(sorted(old.values(), key=lambda r: r['slot']), indent=1) + '\n', 'utf-8')
    st = Counter((r['placed'] or {}).get('root', 'unplaced') for r in rows)
    print('placed %d/%d: %s' % (sum(1 for r in rows if r['placed']), len(rows), dict(st)))
    errs = [r for r in rows if r.get('error')]
    for r in errs[:10]:
        print('  error', r['slot'], r['error'])
    return 0


if __name__ == '__main__':
    sys.exit(main())
