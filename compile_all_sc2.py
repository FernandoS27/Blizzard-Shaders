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


def module_mtime():
    """Newest mtime across the slang module — the incremental-skip watermark.

    The module is ONE translation unit, so ANY source edit invalidates every
    permutation of every family; a per-file dependency check would be wrong."""
    newest = 0.0
    for p in Path(cfg.SC2_INCLUDE).rglob("*.slang*"):
        newest = max(newest, p.stat().st_mtime)
    return newest


def compile_stage(family, stage, jobs=8, verbose=False, skip_existing=False,
                  watermark=None):
    scfg = cfg.family_cfg(family).get(stage)
    if scfg is None:
        return None
    entry = scfg["slang_entry"]
    out_dir = OUT_BASE / ("%s_%s" % (family, stage))
    out_dir.mkdir(parents=True, exist_ok=True)
    slots = list(cfg.iter_slots(family, stage))
    wm = watermark if watermark is not None else (module_mtime() if skip_existing else 0.0)
    skipped = [0]

    def work(item):
        slot, bv, live, _dedup = item
        out = out_dir / ("perm_%03d.dxbc" % slot)
        if skip_existing and out.exists() and out.stat().st_mtime >= wm:
            skipped[0] += 1
            return slot, True
        defines = cfg.perm_defines(family, stage, bv, live)
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
    print("%-16s %-2s: %6d/%-6d compiled%s%s"
          % (family, stage, ok, len(res),
             "  (%d up to date)" % skipped[0] if skipped[0] else "",
             "" if not fails else "  FAILED slots: %s" % fails[:20]),
          flush=True)
    return ok, len(res), fails


def main(argv=None):
    ap = argparse.ArgumentParser(description="Compile sc2_shaders perms to DXBC.")
    ap.add_argument("--family", help="one family; omit with --all")
    ap.add_argument("--all", action="store_true",
                    help="every family in sc2_shaders.json (M5.1)")
    ap.add_argument("--stage", choices=["ps", "vs"], help="default: both")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--skip-existing", action="store_true",
                    help="keep perms already newer than the newest module source "
                         "(makes a whole-module sweep resumable)")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)
    if not args.all and not args.family:
        ap.error("pass --family <name> or --all")

    families = sorted(cfg.load_families()) if args.all else [args.family]
    stages = [args.stage] if args.stage else ["vs", "ps"]
    # One watermark for the whole sweep: a module edit mid-run must not make the
    # families compiled before it look stale relative to the ones after.
    wm = module_mtime() if args.skip_existing else 0.0
    any_fail = False
    total_ok = total_n = 0
    for fam in families:
        for st in stages:
            r = compile_stage(fam, st, jobs=args.jobs, verbose=args.verbose,
                              skip_existing=args.skip_existing, watermark=wm)
            if r is None:
                continue
            ok, n, fails = r
            total_ok += ok
            total_n += n
            if fails:
                any_fail = True
    if args.all:
        print("\n%d/%d permutations compiled across %d families"
              % (total_ok, total_n, len(families)))
    return 1 if any_fail else 0


if __name__ == "__main__":
    sys.exit(main())
