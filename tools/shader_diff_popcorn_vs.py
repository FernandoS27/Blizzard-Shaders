"""Differential test of the slang ``popcorn_vs`` family against retail bytecode.

The Warcraft III Reforged **3.0.0** PopcornFX particle vertex shader: 72 perms,
28 classes, indexed ``idx = inner | 8*outer`` with ``outer = mode*3 + uv``::

    inner bit 0 HAS_RANDOM   1 HAS_VC   2 HAS_NT
    uv        0 NoUV         1 UV       2 (mirror of 1)
    mode      0 Basic        1 Billboard   2 Atlas

Inputs are per-particle vertex attributes (ATTR0..8) plus ``SV_VertexID`` -- the
billboard corner selector whose low two bits pick the quad corner, so it cycles
0..7 across trials. The only constant buffer is cb2, the per-draw transform set.

    python tools/shader_diff_popcorn_vs.py                 # full sweep
    python tools/shader_diff_popcorn_vs.py --perms 0,40 --trials 60

TWO GAPS THIS DRIVER USED TO HAVE, BOTH OF WHICH MADE THE GATE VACUOUS
----------------------------------------------------------------------
Fixed before the 3.0.0 body port, deliberately, because either one alone would
have let P5 report green without testing the thing P5 changes.

1. ``OUTPUT_REGS`` was ``tuple(range(8))`` -- o0 through o7. 3.0.0 adds a world
   position at TEXCOORD8, and **4 of the 72 perms write it to o8**, which was
   therefore never compared. Measured across the shipped blobs, the highest
   output register used is::

       highest o# :  2   3   4   5   6   7   8
       perms      :  6  12  14  18  12   6   4

   It is now ``range(9)``. Note this is not a "the new interpolant" fix: o8 was
   uncompared for every family that reached it, and the count came from the
   blobs rather than from assuming the new one lands last.

2. ``popcorn_vs_cbufs`` built **16** cb2 rows. 3.0.0 moved the particle scale to
   ``cb2[16].y`` -- every vertex position is multiplied by it -- so every perm
   raised ``IndexError: cb2 index 16 outside [0,16)`` and no comparison ran at
   all. It now builds 20.

OUTPUTS ARE COMPARED BY REGISTER, NOT BY SEMANTIC
-------------------------------------------------
``shader_diff.compare`` aligns *inputs* by ``(semantic, index)`` but *outputs*
positionally, by register number. So this gate is only meaningful while both
legs put the same semantic in the same output register -- and that is a real
constraint here, because retail PACKS two scalar semantics into one register in
**32 of the 72** perms (``TEXCOORD1`` and ``TEXCOORD3`` share register 3 in the
atlas perms, for instance). Measured: our declaration order reproduces retail's
map on **72/72**, packing included, because fxc's signature packer does the same
thing to slang's HLSL emit as it did to Blizzard's. If that ever stops being
true the gate starts comparing unrelated lanes, in either direction -- a phantom
divergence or a real one masked -- so it is checked rather than assumed.

WHY THERE IS NO TRIAL CURVE HERE
--------------------------------
The other 3.0.0 families carry a measured retail-against-retail table, because
their axes hide below a trial count. This one does not, and the reason is worth
stating rather than leaving as an omission: **all 72 shipped permutations are
branch-free**. Counting control-flow ops across every retail blob gives exactly
72 ``ret`` and nothing else -- no ``if``, no ``loop``, no ``discard``. Every
trial therefore executes the same straight line, and a divergence shows on the
first seed that reaches it or not at all.

A retail-against-retail probe would also be meaningless here in a way it is not
for the pixel shaders: all three inner axes (HAS_RANDOM, HAS_VC, HAS_NT) change
the output SIGNATURE, so two perms one axis apart have different register maps,
and a positional comparison between them diverges on the register shift rather
than on the axis. There is no pair of shipped perms that differs in behaviour
alone.

What DOES govern coverage is ``SV_VertexID``, the one input with a discrete
domain: it selects the billboard quad corner through its low two bits, and the
driver cycles it as ``seed % 8``. Below 4 trials some corners are never built.
The default of 60 is far above that; it is kept for the arithmetic breadth, not
for branch reachability.
"""

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import f2b                               # noqa: E402
from shader_diff import load, compare, perm_path                     # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "wc3_re_shaders" / "popcornfx_vs"
SLANG_DIR  = REPO / "slang_out" / "d3d11" / "popcorn_vs"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 72

#: o0..o8. NOT range(8) -- see the module docstring; 4 shipped perms write o8.
OUTPUT_REGS = tuple(range(9))

#: cb2 rows the driver builds. 3.0.0 reads up to cb2[16] (retail declares
#: ``float4 cb2[17]``); 20 leaves headroom without pretending to know the size.
CB2_ROWS = 20


def popcorn_vs_inputs(seed):
    """Nine plain float4 vertex attributes fed identically to both shaders."""
    r = random.Random(5000 + seed)
    return {("ATTR", c): [f2b(r.uniform(-2, 2)) for _ in range(4)] for c in range(9)}


def popcorn_vs_cbufs(seed):
    """cb2 -- the 3.0.0 HD per-draw VERTEX layout, which popcorn now shares.

        cb2[ 0.. 3]  world           -> TEXCOORD8, the new world position
        cb2[ 4.. 7]  worldView       -> TEXCOORD7, and the normal / tangent
        cb2[ 8..11]  worldViewProj   -> SV_Position
        cb2[12..15]  not read by this stage
        cb2[16].y    the particle scale every vertex position is multiplied by

    Three DISTINCT matrices, because that is what makes a swapped one visible:
    with a single random block the three transforms would still differ, but a
    candidate that reads rows 4..7 where it should read 0..3 has to produce a
    different number for the gate to notice, and rows that are merely different
    noise do that far less reliably than rows that are structurally different.
    """
    rng = random.Random(seed * 13 + 7)
    rows = [[f2b(rng.uniform(-3, 3)) for _ in range(4)]
            for _ in range(CB2_ROWS)]
    # Keep the scale away from zero: at 0 every position collapses to the
    # origin and the three matrices stop being distinguishable at all.
    rows[16][1] = f2b(rng.choice([-1, 1]) * rng.uniform(0.25, 4.0))
    return {2: rows}


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
    # The clip position is a matrix product of values up to ~3 against
    # attributes up to ~2, so it routinely reaches magnitude 20 -- where a
    # fixed absolute threshold is testing it ~20x more strictly than it tests a
    # varying that stays near 1. Score relative above magnitude 1, absolute
    # below. Pass 0 to score absolutely (2.0.0 was bit-identical, so this
    # changed nothing then and should change nothing now).
    ap.add_argument('--rel-scale', type=float, default=1.0,
                    help='magnitude floor for the diff score (0 = absolute)')
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
        prog_r = load(perm_path(retail, idx, "asm"))
        prog_s = load(perm_path(slang, idx, "dxbc"), decompiler=args.decompiler)
        res = compare(prog_s, prog_r, trials=args.trials, output_regs=OUTPUT_REGS,
                      tol=args.tol, rel_scale=args.rel_scale,
                      inputs_fn=popcorn_vs_inputs,
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
