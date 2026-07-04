"""Differential test of the slang ``popcorn_vs`` family against retail bytecode.

The PopcornFX particle vertex shader (72 perms). Retail bytecode is extracted
from ``war3.w3mod/shaders/vs/popcornfx.bls`` into ``re_shaders/popcornfx_vs/``
by ``tools/extract_retail_bls.py`` (run that first if the dir is empty).

Inputs are per-particle vertex attributes (ATTR0..8, all plain float4) plus
``SV_VertexID`` — the billboard corner selector the slang side uses to expand a
particle quad (its low two bits pick the corner), so we cycle it 0..7 across
trials. The only constant buffer read is cb2 (per-draw transform / particle
params). Up to eight outputs (clip position + world pos + varyings).

    python tools/shader_diff_popcorn_vs.py                 # full sweep
    python tools/shader_diff_popcorn_vs.py --perms 0,40 --trials 60

Compares o0..o7. Known-good this project: bit-identical -> ALL MATCH.
"""

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import f2b                               # noqa: E402
from shader_diff import load, compare                     # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "re_shaders" / "popcornfx_vs"
SLANG_DIR  = REPO / "slang_out" / "d3d11" / "popcorn_vs"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 72
OUTPUT_REGS = tuple(range(8))


def popcorn_vs_inputs(seed):
    """Nine plain float4 vertex attributes fed identically to both shaders."""
    r = random.Random(5000 + seed)
    return {("ATTR", c): [f2b(r.uniform(-2, 2)) for _ in range(4)] for c in range(9)}


def popcorn_vs_cbufs(seed):
    rng = random.Random(seed * 13 + 7)
    return {2: [[f2b(rng.uniform(-3, 3)) for _ in range(4)] for _ in range(16)]}


def popcorn_vs_sysvals(seed):
    # SV_VertexID: billboard corner selector (low 2 bits pick the quad corner).
    # Declared via `dcl_input_sgv v#, vertex_id` in both shaders (the input-sig
    # spelling differs in case, SV_VERTEXID vs SV_VertexID, so route it through
    # the sysval name instead). Cycle 0..7 for corner coverage.
    return {"vertex_id": seed % 8}


def feat(idx):
    inner = idx & 7; outer = idx // 8; mode = outer // 3; uv = outer % 3
    f = []
    if inner & 1: f.append("RAND")
    if inner & 2: f.append("VC")
    if inner & 4: f.append("NT")
    f.append(["NoUV", "Basic", "Billboard", "Atlas"][0 if uv == 0 else mode + 1])
    return "+".join(f)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=60)
    ap.add_argument('--tol', type=float, default=1e-4)
    ap.add_argument('--perms', default=None)
    ap.add_argument('--retail-dir', default=str(RETAIL_DIR))
    ap.add_argument('--slang-dir', default=str(SLANG_DIR))
    ap.add_argument('--decompiler', default=str(DECOMPILER))
    args = ap.parse_args(argv)

    perms = ([int(x) for x in args.perms.split(',')] if args.perms
             else list(range(NPERMS)))
    retail = Path(args.retail_dir); slang = Path(args.slang_dir)

    worst_all = 0.0; diverging = []; dm_total = 0
    for idx in perms:
        prog_r = load(retail / f"perm_{idx:03d}.asm")
        prog_s = load(slang / f"perm_{idx:03d}.dxbc", decompiler=args.decompiler)
        res = compare(prog_s, prog_r, trials=args.trials, output_regs=OUTPUT_REGS,
                      tol=args.tol, inputs_fn=popcorn_vs_inputs,
                      cbufs_fn=popcorn_vs_cbufs, sysvals_fn=popcorn_vs_sysvals)
        worst_all = max(worst_all, res.worst)
        dm_total += res.discard_mismatches
        if res.worst > args.tol or res.discard_mismatches:
            diverging.append((idx, res.worst, res.discard_mismatches))
            print(f"  DIVERGE perm_{idx:03d} {feat(idx)}: worst={res.worst:.3e} "
                  f"dm={res.discard_mismatches} at {res.worst_where} (seed {res.worst_seed})")

    print(f"\n=== popcorn_vs: {len(perms)} perms x {args.trials} trials ===")
    print(f"output regs      : {list(OUTPUT_REGS)}")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"discard mismatch : {dm_total}")
    print(f"perms diverging  : {len(diverging)}")
    print("ALL MATCH" if not diverging else f"DIVERGING: {[d[0] for d in diverging]}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
