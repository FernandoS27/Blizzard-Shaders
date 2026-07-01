"""Differential test of the slang ``sd_on_hd_vs`` family against retail bytecode.

A worked example of :mod:`shader_diff` for a VERTEX shader: no textures, nine
possible outputs (SV_POSITION + COLOR + up to seven TEXCOORDs incl. shadow
coords), and — the part random floats can't cover on their own — a
GPU-vertex-skinning path gated on ``dot(blendWeights, 1) != 0``. A uniform
random weight vector is essentially never exactly zero, so the *rigid* branch
(all-zero weights -> identity/world transform) would go completely untested;
we therefore sweep BOTH skin modes explicitly, mirroring the scratch driver.

Input layout (per the retail "// Input signature"), keyed by ATTR index; the
slang ATTRx10 naming (ATTR10 == retail ATTR1, ...) is resolved by
:func:`shader_diff.map_inputs`, and each shader's own signature places the
semantic into the right register:

    ATTR0 position   ATTR1 normal   ATTR2 color   ATTR3 uv0   ATTR4 uv1
    ATTR5 blendWeights   ATTR6 blendIndices (uint)   ATTR7 tangent

Constant buffers are driven with MEANINGFUL matrices (orthonormal rotations +
translation for cb2's world/worldView/worldViewProj, a bone palette in cb3) so
the transform math exercises real values rather than garbage.

It sweeps all 144 perms (retail ``perm_NNN.asm`` vs slang ``perm_NNN.dxbc``)
and compares o0..o8. Run from the repo root::

    python tools/shader_diff_sd_on_hd_vs.py                 # full sweep
    python tools/shader_diff_sd_on_hd_vs.py --perms 71,143  # specific perms
    python tools/shader_diff_sd_on_hd_vs.py --trials 40

Known-good result: sd_on_hd_vs is bit-identical to retail -> ALL MATCH,
worst ~0 at tol=1e-6.
"""

import argparse
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import f2b, i2b                         # noqa: E402
from shader_diff import load, compare                    # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "re_shaders" / "sd_on_hd_vs"
SLANG_DIR  = REPO / "slang_out" / "d3d11" / "sd_on_hd_vs"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 144

# nine possible VS outputs: SV_POSITION, COLOR, TEXCOORD0/1/2/3 (+shadow coords)
OUTPUT_REGS = tuple(range(9))


# --- meaningful matrix helpers -------------------------------------------
# Build proper orthonormal rotations + translation so the transform pipeline
# runs on well-conditioned data (a random 4x4 would still "match" but tells us
# less, and could make the skinning weight-sum land on pathological values).

def _rot(rng):
    """A random orthonormal 3x3 rotation as three row 3-vectors."""
    ax, ay, az = (rng.uniform(-1, 1) for _ in range(3))
    n = math.sqrt(ax * ax + ay * ay + az * az) or 1.0
    ax, ay, az = ax / n, ay / n, az / n
    th = rng.uniform(0, 2 * math.pi)
    c, s, t = math.cos(th), math.sin(th), 1 - math.cos(th)
    return [
        [c + ax * ax * t,      ax * ay * t - az * s, ax * az * t + ay * s],
        [ay * ax * t + az * s, c + ay * ay * t,      ay * az * t - ax * s],
        [az * ax * t - ay * s, az * ay * t + ax * s, c + az * az * t],
    ]


def _affine_rows(rng):
    """A 4x4 affine transform (rotation + translation) as 4 row 4-vectors.

    Translation is kept small (|t|<=2, matching the scratch driver's CB range)
    so composed clip-space magnitudes stay modest: the interpreter runs in
    double precision and reorders large-dot accumulations vs the GPU's float32,
    which would otherwise leave an absolute residual ~1e-6 * |coord| that is
    fp noise, not a logic divergence."""
    r = _rot(rng)
    tx, ty, tz = (rng.uniform(-2, 2) for _ in range(3))
    return [
        [r[0][0], r[0][1], r[0][2], tx],
        [r[1][0], r[1][1], r[1][2], ty],
        [r[2][0], r[2][1], r[2][2], tz],
        [0.0, 0.0, 0.0, 1.0],
    ]


def _rows_bits(rows):
    return [[f2b(x) for x in row] for row in rows]


# --- per-semantic inputs (keyed by ATTR index) ---------------------------

def _unit(rng):
    v = [rng.uniform(-1, 1) for _ in range(3)]
    m = math.sqrt(sum(c * c for c in v)) or 1.0
    return [c / m for c in v]


def sd_on_hd_inputs(seed, zero_w=False):
    """Concrete per-semantic dict fed identically to both shaders.

    ``zero_w`` selects the rigid path: all-zero blend weights so the retail
    ``dot(weights,1) != 0`` gate is false (random weights never hit this).
    """
    r = random.Random(4000 + seed)
    n = _unit(r); tan = _unit(r)
    if zero_w:
        weights = [f2b(0.0)] * 4
    else:
        w = [r.uniform(0.05, 1.0) for _ in range(4)]
        s = sum(w)
        weights = [f2b(x / s) for x in w]            # normalized, non-zero
    return {
        ("ATTR", 0): [f2b(r.uniform(-2, 2)) for _ in range(3)] + [f2b(1.0)],   # position
        ("ATTR", 1): [f2b(n[0]), f2b(n[1]), f2b(n[2]), f2b(0.0)],              # normal
        ("ATTR", 2): [f2b(r.uniform(0, 1)) for _ in range(4)],                 # color
        ("ATTR", 3): [f2b(r.uniform(-2, 2)) for _ in range(4)],                # uv0
        ("ATTR", 4): [f2b(r.uniform(-2, 2)) for _ in range(4)],                # uv1
        ("ATTR", 5): weights,                                                  # blendWeights
        ("ATTR", 6): [i2b(r.randint(0, 40)) for _ in range(4)],               # blendIndices (uint)
        ("ATTR", 7): [f2b(tan[0]), f2b(tan[1]), f2b(tan[2]),
                      f2b(r.choice([-1.0, 1.0]))],                             # tangent
    }


# --- constant buffers with meaningful transforms -------------------------

def sd_on_hd_cbufs(seed):
    """cb2 (per-draw matrices) + cb3 (bone palette). Rows past the driven
    matrices are filled with tame random values so any stray read is stable."""
    rng = random.Random(seed * 7 + 1)

    # cb2: world / worldView / worldViewProj as affine transforms at rows
    # 0-3, 4-7, 8-11 (matching the slang VSPerDraw layout), rest random.
    cb2 = [[f2b(rng.uniform(-2, 2)) for _ in range(4)] for _ in range(24)]
    cb2[0:4]  = _rows_bits(_affine_rows(rng))     # world
    cb2[4:8]  = _rows_bits(_affine_rows(rng))     # worldView
    cb2[8:12] = _rows_bits(_affine_rows(rng))     # worldViewProj

    # cb3: bone palette. Each bone is a 4x3 (three rows) affine transform;
    # blendIndices*3 indexes it, so drive plenty of well-formed bones.
    cb3 = [[f2b(rng.uniform(-2, 2)) for _ in range(4)] for _ in range(768)]
    for bone in range(200):
        rows = _affine_rows(rng)[:3]              # 4x3 -> first three rows
        for k in range(3):
            cb3[bone * 3 + k] = [f2b(x) for x in rows[k]]

    # cb1: up to three shadow-cascade view-proj matrices (rows 0-3, 4-7, 8-11)
    # feeding o6/o7/o8 in the SHAD perms; affine transforms, rest random.
    cb1 = [[f2b(rng.uniform(-2, 2)) for _ in range(4)] for _ in range(16)]
    cb1[0:4]  = _rows_bits(_affine_rows(rng))
    cb1[4:8]  = _rows_bits(_affine_rows(rng))
    cb1[8:12] = _rows_bits(_affine_rows(rng))

    return {1: cb1, 2: cb2, 3: cb3}


# --- perm feature label (mirrors scratch driver) -------------------------

def feat(idx):
    tang = idx % 2; weight = (idx // 2) % 3; color = (idx // 6) % 2
    tc = (idx // 12) % 3; prepass = (idx // 36) % 2; shadows = (idx // 72) % 2
    f = []
    if weight == 2: f.append("SKIN")
    if tang: f.append("TAN")
    if color: f.append("VC")
    if tc >= 1: f.append("UV1")
    if tc >= 2: f.append("UV2")
    if prepass: f.append("PRE")
    if shadows and not prepass: f.append("SHAD")
    return "+".join(f) if f else "base"


# --- driver ---------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=40)
    ap.add_argument('--tol', type=float, default=1e-6)
    ap.add_argument('--perms', default=None,
                    help='comma-separated perm indices (default: all 144)')
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

        perm_worst = 0.0; perm_where = None; perm_seed = None; perm_dm = 0
        # Sweep both skin modes: rigid (zero_w) and weighted. Split the trial
        # budget across the two so each branch gets real coverage.
        for zero_w in (False, True):
            res = compare(
                prog_s, prog_r, trials=args.trials, output_regs=OUTPUT_REGS,
                tol=args.tol,
                inputs_fn=(lambda s, zw=zero_w: sd_on_hd_inputs(s, zero_w=zw)),
                cbufs_fn=sd_on_hd_cbufs,
                sysvals_fn=(lambda s: {}),            # VS: no front-face sysval
                seed0=(1000 if zero_w else 0))
            perm_dm += res.discard_mismatches
            if res.worst > perm_worst:
                perm_worst = res.worst; perm_where = res.worst_where
                perm_seed = (res.worst_seed, "rigid" if zero_w else "weighted")

        worst_all = max(worst_all, perm_worst)
        dm_total += perm_dm
        if perm_worst > args.tol or perm_dm:
            diverging.append((idx, perm_worst, perm_dm))
            print(f"  DIVERGE perm_{idx:03d} {feat(idx)}: worst={perm_worst:.3e} "
                  f"dm={perm_dm} at {perm_where} (seed {perm_seed})")
        if idx % 36 == 0:
            print(f"  ...perm {idx} (running worst {worst_all:.1e})", file=sys.stderr)

    print(f"\n=== sd_on_hd_vs: {len(perms)} perms x {args.trials} trials x 2 skin modes ===")
    print(f"output regs      : {list(OUTPUT_REGS)}")
    print(f"skin modes       : weighted + rigid (zero blend weights)")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"discard mismatch : {dm_total}")
    print(f"perms diverging  : {len(diverging)}")
    print("ALL MATCH" if not diverging else f"DIVERGING: {[d[0] for d in diverging]}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
