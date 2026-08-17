#!/usr/bin/env python3
"""Whole-module behavioural validation: every ported sc2_shaders family, both stages,
slang candidate vs the fxc-original `.fx` reference through dxbc_interp.

Each permutation is bucketed by its EXPECTED exactness, because the random-input
harness has documented transcendental floors that real (in-range) inputs never hit:

  exact  — no transcendental left  -> require worst <= 1e-6 (absorbs the float32
           reassociation ULP, e.g. the 2^-28 vertex-lighting sum on the VS side).
  trans  — a pow()/log2() survives (Blinn specular, team-colour / fresnel /
           spherical-envio pow, blur-mip log2) -> require worst <= 5e-3.  fxc and
           slangc round these differently; real inputs stay in [0,1].
  pom    — a parallax ray-march -> a genuine discontinuity floor (a random view ray
           tips the discrete intersection to a different step).  The POM LOGIC is
           proven bit-exact separately under a constant TextureModel; here the slot
           is COUNTED but not required to be exact (bounded only as a sanity check).

`ref_reject` = fxc rejects the ORIGINAL .fx for that perm (its own loop-unroll ceiling
at high b_iSoftShadowTaps, or a compile-time-OOB READ_INTERPOLANT_UV index).  There is
no ground truth for those, so they are reported and excluded — they are not slang bugs.

Usage:
  python tools/sc2_validate_all.py                       # all families, both stages, full
  python tools/sc2_validate_all.py --family Water TerrainBlend
  python tools/sc2_validate_all.py --stage ps --sample 400 --jobs 12
"""
import argparse
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import sc2_slang_validate as V
import sc2_shaders_cfg as cfg

SCRATCH = os.path.join(HERE, "_sc2_val_all")

# Thresholds per expected-exactness bucket.
THRESH = {"exact": 1e-6, "trans": 5e-3, "pom": 0.9}

# The 18 material layers (psmaterial.fx SETUP_LAYER); each can carry a pow via its
# team-colour / fresnel mode, its team-add op, or a spherical-envio sample.
_LAYERS = ["Diffuse", "Specular", "Decal", "Emissive", "Emissive2", "AlphaMask",
           "AlphaMask2", "Lightmap", "AmbientOcclusion", "SpecularExponent", "Normal",
           "Envio", "EnvioMask", "NormalBlendMask", "NormalBlendMask2",
           "NormalBlendNormal", "NormalBlendNormal2", "Heightmap"]
_ENVIO_UVMAPS = {2, 3, 7, 8}
_TEAMADD_OPS = {4, 5}


def _has_pow(bv):
    """True if a pow()/log2() survives DCE for this permutation (-> trans bucket)."""
    # Blinn specular: pow(saturate(dot(N,H)), specularity).
    if bv.get("b_iUseSpecular", 0) or bv.get("b_useSpecular", 0):
        return True
    # Diffuse/specular team colour + team-colour-specular all pow(alpha, intensity).
    if bv.get("b_iDiffuseTeamColorMode", 0) or bv.get("b_iSpecularTeamColorMode", 0):
        return True
    if bv.get("b_useTeamColorSpecular", 0):
        return True
    for L in _LAYERS:
        if not bv.get("b_i%sLayerEnable" % L, 0):
            continue
        if bv.get("b_i%sTeamColorMode" % L, 0):
            return True
        if bv.get("b_i%sFresnelMode" % L, 0):
            return True
        if bv.get("b_i%sOp" % L, 0) in _TEAMADD_OPS:
            return True
        if (not bv.get("b_i%sUseConstantColor" % L, 0)
                and bv.get("b_i%sUVMapping" % L, 0) in _ENVIO_UVMAPS):
            return True
    if bv.get("b_iBlurEnvironmentMap", 0):
        return True
    return False


def _bucket(family, stage, bv):
    if stage == "vs":
        # VS floor is the vertex-lighting-sum reassociation ULP; 1e-6 exact absorbs it.
        return "exact"
    if bv.get("b_useParallaxMapping", 0):
        return "pom"
    # water.fx's pretty branch always runs the pow-fresnel; env/cheap don't.
    if family == "Water" and not bv.get("b_iCheapWater", 0) and not bv.get("b_envMapPass", 0):
        return "trans"
    if _has_pow(bv):
        return "trans"
    return "exact"


def validate_stage(family, stage, *, sample=0, jobs=8, trials=8, verbose=False):
    fcfg = cfg.family_cfg(family)
    if stage not in fcfg:
        return None
    scfg = fcfg[stage]
    fxfile = cfg.fx_path(family)
    fx_entry = scfg["fx_entry"]
    slang_entry = scfg["slang_entry"]
    inject = scfg.get("inject_preamble", True)
    os.makedirs(SCRATCH, exist_ok=True)

    slots = list(cfg.iter_slots(family, stage))
    if sample and len(slots) > sample:
        step = max(1, len(slots) // sample)
        slots = slots[::step][:sample]

    def work(item):
        slot, bv, live, dedup = item
        tag = "%s_%s_%d" % (family, stage, slot)
        bk = _bucket(family, stage, bv)
        uvm = cfg.uv_mappings(bv)
        ref, rerr = V.compile_reference(
            fxfile, fx_entry, stage, bv, live,
            os.path.join(SCRATCH, tag + "_ref.fx"),
            uv_mappings=uvm, inject_preamble=inject,
            uv_random_offsets=cfg.uv_random_offsets(bv))
        if ref is None:
            # fxc rejecting the ORIGINAL .fx (X3504 loop unroll / OOB interp index) has
            # no ground truth; everything else is a real reference-compile bug.
            kind = "ref_reject" if ("X3504" in str(rerr) or "X3500" in str(rerr)
                                    or "X4014" in str(rerr)) else "ref_error"
            return slot, bk, None, (kind, str(rerr)[:120])
        defines = cfg.perm_defines(family, stage, bv, live)
        cand, cerr = V.compile_slang(
            cfg.SC2_MODULE, slang_entry, stage, defines,
            os.path.join(SCRATCH, tag + "_cand"), include_dirs=[cfg.SC2_INCLUDE])
        if cand is None:
            return slot, bk, None, ("slang_error", str(cerr)[:160])
        if stage == "vs":
            diffs, derr = V.compare_vs(
                ref, cand, trials=trials,
                input_domains=cfg.VS_INPUT_DOMAINS.get(family),
                const_domains=cfg.VS_CONST_DOMAINS.get(family))
        else:
            diffs, derr = V.compare_d3d11(ref, cand, trials=trials)
        if derr:
            return slot, bk, None, ("compare_error", derr[:160])
        worst = max(diffs.values()) if diffs else 0.0
        return slot, bk, worst, None

    if jobs <= 1:
        results = [work(it) for it in slots]
    else:
        with ThreadPoolExecutor(max_workers=jobs) as ex:
            results = list(ex.map(work, slots))

    from collections import Counter
    tot = Counter(); grn = Counter()
    ref_reject = 0; fails = []
    for slot, bk, worst, err in results:
        if err is not None:
            kind, msg = err
            if kind == "ref_reject":
                ref_reject += 1
            else:
                fails.append((slot, bk, kind, msg))
            continue
        tot[bk] += 1
        if worst <= THRESH[bk]:
            grn[bk] += 1
        else:
            fails.append((slot, bk, "worst", "%.5f > %g" % (worst, THRESH[bk])))

    n = len(results)
    gtot = sum(grn.values())
    parts = " ".join("%s=%d/%d" % (b, grn[b], tot[b]) for b in ("exact", "trans", "pom") if tot[b])
    tail = ("  [sampled %d]" % n) if sample else ""
    print("  %-13s %-2s  %d/%d matched  (%s%s%s)%s"
          % (family, stage, gtot, sum(tot.values()), parts,
             "  ref_reject=%d" % ref_reject if ref_reject else "",
             "  FAILS=%d" % len(fails) if fails else "", tail))
    if verbose or fails:
        for slot, bk, kind, msg in fails[:25]:
            print("      FAIL slot=%-6d [%s] %s: %s" % (slot, bk, kind, msg))
    return {"family": family, "stage": stage, "n": n, "green": gtot,
            "counted": sum(tot.values()), "ref_reject": ref_reject,
            "buckets": {b: (grn[b], tot[b]) for b in tot}, "fails": fails}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Validate all ported sc2_shaders families.")
    ap.add_argument("--family", nargs="*", help="families (default: all in config)")
    ap.add_argument("--stage", choices=["ps", "vs"], help="default: both")
    ap.add_argument("--sample", type=int, default=0, help="~N slots/stage (0 = full)")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--trials", type=int, default=8)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)

    fams = args.family or list(cfg.load_families().keys())
    stages = [args.stage] if args.stage else ["vs", "ps"]
    all_ok = True
    summaries = []
    print("sc2_validate_all: families=%s stages=%s sample=%s jobs=%d trials=%d\n"
          % (",".join(fams), stages, args.sample or "full", args.jobs, args.trials))
    for fam in fams:
        for st in stages:
            r = validate_stage(fam, st, sample=args.sample, jobs=args.jobs,
                               trials=args.trials, verbose=args.verbose)
            if r is None:
                continue
            summaries.append(r)
            if r["fails"]:
                all_ok = False

    print("\n=== SUMMARY ===")
    tg = tc = trr = 0
    for r in summaries:
        tg += r["green"]; tc += r["counted"]; trr += r["ref_reject"]
    print("matched %d/%d counted perms  (ref_reject=%d excluded)  -> %s"
          % (tg, tc, trr, "ALL GREEN" if all_ok else "FAILURES PRESENT"))
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
