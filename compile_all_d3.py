#!/usr/bin/env python3
"""Compile d3_shaders slots to a graphics-API target.

Each bundle (``ps_actor``, ``vs_legacy``, ...) has one slot per distinct retail
program (``d3_perms/<bundle>.json``). A slot is compiled from the spec
``tools/d3_shaders_cfg.map_d3`` gives its retail keys and written as
``d3_slang_out/<target>/<bundle>/slot_<NNNN>.<ext>`` in slot order;
``build_d3_bls.py`` packs those blobs, in the same order, into the bundle.

Only slots whose subfamily has a translator are compiled -- a root lands
bundle by bundle -- and every key of a slot must map to the same spec (a slot
whose keys disagree is a D1 failure and is not compiled). D3D11 compiles at
shader model 4, the profile every retail Diablo III program uses.

Usage:
  python compile_all_d3.py --bundle ps_actor [--bundle vs_actor] [--jobs 22]
  python compile_all_d3.py --all --skip-existing
  python compile_all_d3.py --all --target d3d12,vulkan --sample 12
"""

from __future__ import annotations

import argparse
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / 'tools'))
import compile_all_slang as cas             # noqa: E402
import d3_perm_manifest as M                # noqa: E402
import d3_retail as R                       # noqa: E402
import d3_shaders_cfg as C                  # noqa: E402

OUT_ROOT = Path(os.environ.get('D3_SLANG_OUT') or (REPO / 'd3_slang_out'))
TARGETS = cas.TARGETS
DEFAULT_TARGET = 'd3d11'


def module_mtime() -> float:
    """Newest mtime across the module: ONE translation unit, so any edit
    invalidates every slot ([[project_build_artifact_staleness]])."""
    return max(p.stat().st_mtime for p in C.INCLUDE.rglob('*.slang*'))


def slot_spec(slot: dict, subfamilies=None, roots=None):
    """``(spec, problem)`` for one manifest slot; spec None when unported."""
    specs = {}
    for r in slot['retail']:
        if subfamilies and r['subfamily'] not in subfamilies:
            continue
        spec = C.row_spec(r, slot['measured'], slot['program'])
        if spec is not None:
            specs.setdefault(spec.key(), []).append(r['subfamily'])
    if not specs:
        return None, None
    if len(specs) > 1:
        return None, 'keys disagree on the spec: %s' % sorted({s for v in specs.values() for s in v})
    spec = C.Spec(*next(iter(specs)))
    if roots and spec.entry not in roots:
        return None, None
    return spec, None


def out_path(target: str, bid: str, slot: int) -> Path:
    return OUT_ROOT / target / bid / ('slot_%04d.%s' % (slot, TARGETS[target]['ext']))


def compile_bundle(bid: str, target: str, jobs: int, skip_existing: bool, sample: int = 0,
                   subfamilies=None, roots=None, only_slots=None):
    stage = bid.split('_', 1)[0]
    tgt = TARGETS[target]
    profile = tgt[stage]
    if target == 'd3d11':
        profile = profile.replace('_5_0', '_4_0')
    slots = M.load(bid)
    work, problems = [], []
    for s in slots:
        if only_slots and s['slot'] not in only_slots:
            continue
        spec, problem = slot_spec(s, subfamilies, roots)
        if problem:
            problems.append((s['slot'], problem))
        elif spec:
            work.append((s['slot'], spec))
    if sample and len(work) > sample:
        step = len(work) / sample
        work = [work[int(k * step)] for k in range(sample)]
    wm = module_mtime() if skip_existing else 0.0
    (OUT_ROOT / target / bid).mkdir(parents=True, exist_ok=True)
    skipped = [0]

    def one(item):
        slot, spec = item
        out = out_path(target, bid, slot)
        # the spec a blob was built from sits beside it: residue slot numbers move when a
        # program is placed in another bundle, so a newer blob is not necessarily this slot's
        stamp = out.with_suffix(out.suffix + '.spec')
        key = repr(spec.key())
        if (skip_existing and out.exists() and out.stat().st_mtime >= wm and stamp.exists()
                and stamp.read_text('utf-8') == key):
            skipped[0] += 1
            return slot, True
        err = out.with_suffix(out.suffix + '.err')
        for stale in (err, stamp):
            if stale.exists():
                stale.unlink()
        spec = C.for_target(spec, target, stage)
        ok = cas.invoke_slangc(spec.entry, tgt['target'], profile, list(spec.specialize), out,
                               C.MODULE, extra=tgt['extra'], include_dirs=[C.INCLUDE],
                               defines=list(spec.defines))
        if ok:
            stamp.write_text(key, 'utf-8')
        return slot, ok

    with ThreadPoolExecutor(max_workers=max(1, jobs)) as ex:
        res = list(ex.map(one, work))
    # a slot that no longer compiles from this module must not leave an old blob behind
    live = {slot for slot, _ in work}
    if not sample and not subfamilies and not roots and not only_slots:
        for p in (OUT_ROOT / target / bid).glob('slot_*.%s' % tgt['ext']):
            if int(p.stem.split('_')[1]) not in live:
                p.unlink()
    fails = [slot for slot, ok in res if not ok]
    print('%-7s %-11s %4d/%-4d slots compiled%s%s%s'
          % (target, bid, len(res) - len(fails), len(res),
             '  (%d up to date)' % skipped[0] if skipped[0] else '',
             '  of %d' % len(slots) if len(work) < len(slots) else '',
             '  FAILED: %s' % fails[:12] if fails else ''), flush=True)
    for slot, problem in problems:
        print('  D1 slot %d: %s' % (slot, problem))
    return len(fails) + len(problems)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--bundle', action='append', default=[])
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--target', default=DEFAULT_TARGET)
    ap.add_argument('--jobs', type=int, default=16)
    ap.add_argument('--skip-existing', action='store_true')
    ap.add_argument('--sample', type=int, default=0)
    ap.add_argument('--subfamily', action='append', default=[], help='only slots holding these subfamilies')
    ap.add_argument('--root', action='append', default=[], help='only slots of these entry points')
    ap.add_argument('--slot', action='append', type=int, default=[], help='only these slot numbers (with one --bundle)')
    args = ap.parse_args(argv)
    bids = [R.bundle_id(d, s) for d, s in R.bundles()] if args.all else args.bundle
    if not bids:
        ap.error('pass --bundle <id> or --all')
    targets = sorted(TARGETS) if args.target == 'all' else args.target.split(',')
    bad = 0
    for tg in targets:
        for bid in bids:
            bad += compile_bundle(bid, tg, args.jobs, args.skip_existing, args.sample,
                                  set(args.subfamily) or None, set(args.root) or None,
                                  set(args.slot) or None)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
