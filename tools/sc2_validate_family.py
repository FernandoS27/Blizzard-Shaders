#!/usr/bin/env python3
"""Validate an sc2_shaders family: for every retail permutation slot, does the
slang port reproduce the ORIGINAL `.fx` behavior?

Per (family, stage) slot (cache order, from the manifest):
  1. decode the slot -> (b_values, live)   [sc2_perm_manifest / sc2_family_decode]
  2. reference : compile the original `.fx` entry with those defines (fxc ps_5_0/
     vs_5_0)                                [sc2_slang_validate.compile_reference]
  3. candidate : compile the slang entry with the `-D b_*` define set (slangc ->
     ps_5_0/vs_5_0)                         [sc2_slang_validate.compile_slang]
  4. compare both through dxbc_interp on identical random inputs
       ps -> compare_d3d11 (per SV_Target)
       vs -> compare_vs    (per output-signature semantic)
  5. green when the worst per-slot abs diff <= eps (0 for non-POM families).

Both legs target the SAME profile (our own fxc/slangc), so a nonzero diff is a
real slang<->original divergence, not toolchain drift.

Usage:
  python tools/sc2_validate_family.py --family Simple [--stage ps|vs]
                                      [--eps 0] [--trials 12] [--jobs 8]
                                      [--sample N] [--verbose]
"""
import os
import sys
import argparse
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sc2_slang_validate as V
import sc2_shaders_cfg as cfg

SCRATCH = os.environ.get("SC2_SCRATCH", os.path.join(HERE, "_sc2_val_tmp"))


def _validate_stage(family, stage, *, eps=0.0, trials=12, jobs=8,
                    sample=0, verbose=False):
    fcfg = cfg.family_cfg(family)
    if stage not in fcfg:
        return None
    scfg = fcfg[stage]
    fxfile = cfg.fx_path(family)
    fx_entry = scfg["fx_entry"]
    slang_entry = scfg["slang_entry"]
    os.makedirs(SCRATCH, exist_ok=True)

    slots = list(cfg.iter_slots(family, stage))
    if sample and len(slots) > sample:
        step = max(1, len(slots) // sample)
        slots = slots[::step][:sample]

    def work(item):
        slot, bv, live, dedup = item
        tag = "%s_%s_%d" % (family, stage, slot)
        # model.fx's `int b_iUVMapping[8]` is an engine-filled ARRAY, not a define:
        # the reference's InitShader stub fills it from `uv_mappings`, the candidate
        # gets the same values as SC2_UVMAPPING<i> defines (sc2_shaders_cfg).
        uvm = cfg.uv_mappings(bv)
        # Own-IO families (terrainblend.fx declares its own `VertexTransport`) set
        # inject_preamble=false in the config so the shared gen_preamble transport is
        # NOT spliced into the reference compile (it would collide).  Default true.
        ref, rerr = V.compile_reference(fxfile, fx_entry, stage, bv, live,
                                        os.path.join(SCRATCH, tag + "_ref.fx"),
                                        uv_mappings=uvm,
                                        inject_preamble=scfg.get("inject_preamble", True),
                                        uv_random_offsets=cfg.uv_random_offsets(bv))
        if ref is None:
            return slot, None, "ref compile failed: %s" % (rerr,)
        defines = cfg.perm_defines(family, stage, bv, live)
        cand, cerr = V.compile_slang(cfg.SC2_MODULE, slang_entry, stage, defines,
                                     os.path.join(SCRATCH, tag + "_cand"),
                                     include_dirs=[cfg.SC2_INCLUDE])
        if cand is None:
            return slot, None, "slang compile failed: %s" % (cerr,)
        if stage == "vs":
            # Attributes/constants this family uses as array INDICES must be drawn
            # from their engine-legal range (see sc2_shaders_cfg.VS_INPUT_DOMAINS).
            diffs, derr = V.compare_vs(
                ref, cand, trials=trials,
                input_domains=cfg.VS_INPUT_DOMAINS.get(family),
                const_domains=cfg.VS_CONST_DOMAINS.get(family))
        else:
            diffs, derr = V.compare_d3d11(ref, cand, trials=trials)
        if derr:
            return slot, None, "compare error: %s" % (derr,)
        worst = max(diffs.values()) if diffs else 0.0
        return slot, worst, None

    results = []
    if jobs <= 1:
        results = [work(it) for it in slots]
    else:
        with ThreadPoolExecutor(max_workers=jobs) as ex:
            results = list(ex.map(work, slots))
    results.sort(key=lambda r: r[0])

    green = 0
    fails = []
    for slot, worst, err in results:
        ok = (err is None) and (worst <= eps)
        if ok:
            green += 1
        else:
            fails.append((slot, worst, err))
        if verbose or not ok:
            tag = "OK  " if ok else "FAIL"
            print("  [%s] %-3s slot %-4d worst=%s %s"
                  % (tag, stage, slot,
                     ("%.6g" % worst) if worst is not None else "-",
                     err or ""))
    print("%s %s: %d/%d green (eps=%g, trials=%d)%s"
          % (family, stage, green, len(results), eps, trials,
             "" if sample == 0 else "  [sampled %d]" % len(results)))
    return green, len(results), fails


def main(argv=None):
    ap = argparse.ArgumentParser(description="Validate an sc2_shaders family "
                                             "(slang vs original .fx).")
    ap.add_argument("--family", required=True)
    ap.add_argument("--stage", choices=["ps", "vs"], help="default: both")
    ap.add_argument("--eps", type=float, default=0.0)
    ap.add_argument("--trials", type=int, default=12)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--sample", type=int, default=0,
                    help="validate only ~N slots (0 = all)")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)

    stages = [args.stage] if args.stage else ["vs", "ps"]
    total_green = total = 0
    any_fail = False
    for st in stages:
        r = _validate_stage(args.family, st, eps=args.eps, trials=args.trials,
                            jobs=args.jobs, sample=args.sample,
                            verbose=args.verbose)
        if r is None:
            continue
        g, n, fails = r
        total_green += g
        total += n
        if fails:
            any_fail = True
    print("\n%s: %d/%d slots green%s"
          % (args.family, total_green, total,
             "  -> PASS" if (not any_fail and total) else "  -> FAIL"))
    return 0 if (not any_fail and total) else 1


if __name__ == "__main__":
    sys.exit(main())
