#!/usr/bin/env python3
"""Compile every sc2_shaders permutation slot to D3D11 DXBC.

For each (family, stage) the cache-order manifest (sc2_perms/<Family>_<stage>.json)
gives one slot per retail permutation; we compile the family's slang entry with
that slot's decoded `b_*` define set and write `perm_<NNN>.dxbc` in slot order.
build_sc2_bls.py then bundles those blobs, in the same order, into the family BLS.

Output: sc2_slang_out/d3d11/<Family>_<stage>/perm_<NNN>.dxbc   (mirrors
compile_all_slang.py's slang_out/<target>/<family>/ layout).

Usage:
  python compile_all_sc2.py [--family Simple] [--stage ps|vs] [--jobs 8]
"""
import os
import sys
import argparse
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor

REPO_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(REPO_ROOT / "tools"))
import compile_all_slang as cas
import sc2_shaders_cfg as cfg

OUT_BASE = REPO_ROOT / "sc2_slang_out" / "d3d11"
PROFILE = {"vs": "vs_5_0", "ps": "ps_5_0"}


def compile_stage(family, stage, jobs=8, verbose=False):
    scfg = cfg.family_cfg(family).get(stage)
    if scfg is None:
        return None
    entry = scfg["slang_entry"]
    out_dir = OUT_BASE / ("%s_%s" % (family, stage))
    out_dir.mkdir(parents=True, exist_ok=True)
    slots = list(cfg.iter_slots(family, stage))

    def work(item):
        slot, bv, live, _dedup = item
        defines = cfg.perm_defines(family, stage, bv, live)
        out = out_dir / ("perm_%03d.dxbc" % slot)
        ok = cas.invoke_slangc(entry, "dxbc", PROFILE[stage], [], out,
                               Path(cfg.SC2_MODULE),
                               include_dirs=[Path(cfg.SC2_INCLUDE)],
                               defines=defines)
        return slot, ok

    if jobs <= 1:
        res = [work(it) for it in slots]
    else:
        with ThreadPoolExecutor(max_workers=jobs) as ex:
            res = list(ex.map(work, slots))
    ok = sum(1 for _, o in res if o)
    fails = [s for s, o in res if not o]
    print("%s %s: %d/%d compiled -> %s%s"
          % (family, stage, ok, len(res), out_dir,
             "" if not fails else "  FAILED slots: %s" % fails))
    return ok, len(res), fails


def main(argv=None):
    ap = argparse.ArgumentParser(description="Compile sc2_shaders perms to DXBC.")
    ap.add_argument("--family", required=True)
    ap.add_argument("--stage", choices=["ps", "vs"], help="default: both")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)

    stages = [args.stage] if args.stage else ["vs", "ps"]
    any_fail = False
    for st in stages:
        r = compile_stage(args.family, st, jobs=args.jobs, verbose=args.verbose)
        if r and r[2]:
            any_fail = True
    return 1 if any_fail else 0


if __name__ == "__main__":
    sys.exit(main())
