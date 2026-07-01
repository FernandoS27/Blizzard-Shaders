"""Differential test of the slang ``hd_vs`` family against retail bytecode.

The HD vertex shader. Like ``sd_on_hd_vs`` it has one runtime branch — the
four-bone skinning weight-sum gate (``dot(blendWeights, 1) != 0``; rigid
fallback on exactly-zero weights) — that random weights never exercise, so we
sweep BOTH skin modes. Up to nine outputs (SV_POSITION, COLOR, UV, world-pos,
normal, tangent, and three shadow-cascade clip coords).

Inputs keyed by ATTR index (the slang ATTRx10 naming — ATTR10 == retail ATTR1 —
is resolved by :func:`shader_diff.map_inputs`)::

    ATTR0 position   ATTR1 normal   ATTR2 color   ATTR3 uv0   ATTR4 uv1
    ATTR5 blendWeights   ATTR6 blendIndices (uint)   ATTR7 tangent

Constant buffers carry MEANINGFUL rigid transforms (orthonormal rotation +
small translation) for cb2 world/worldView/worldViewProj, cb1's three shadow
cascades, and a cb3 bone palette — so the transform math runs on
well-conditioned values. Translations are kept small (|t|<=2): the interpreter
accumulates dot products in float64 and reorders vs the GPU's float32, which on
large clip coords would leave an absolute residual ~1e-6*|coord| that is fp
noise, not a logic divergence.

Sweeps all 144 perms; retail lives under the nested ``hd_vs/hd/`` dir. Run from
the repo root::

    python tools/shader_diff_hd_vs.py                 # full sweep
    python tools/shader_diff_hd_vs.py --perms 2,143    # specific perms
    python tools/shader_diff_hd_vs.py --trials 40

Known-good result: hd_vs is bit-identical to retail -> ALL MATCH (the new
float32 VM leaves ~1e-6 rounding noise, well under the 1e-4 logical tolerance).
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
RETAIL_DIR = REPO / "re_shaders" / "hd_vs" / "hd"        # note the nested hd/ dir
SLANG_DIR  = REPO / "slang_out" / "d3d11" / "hd_vs"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 144

OUTPUT_REGS = tuple(range(9))   # SV_POSITION, COLOR, UV, wpos, normal, tangent, SH0/1/2


# --- meaningful matrix helpers (well-conditioned, both shaders see them) ---

def _rot(rng):
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
    r = _rot(rng)
    tx, ty, tz = (rng.uniform(-2, 2) for _ in range(3))   # small |t| -> low fp noise
    return [[r[0][0], r[0][1], r[0][2], tx],
            [r[1][0], r[1][1], r[1][2], ty],
            [r[2][0], r[2][1], r[2][2], tz],
            [0.0, 0.0, 0.0, 1.0]]

def _rows_bits(rows):
    return [[f2b(x) for x in row] for row in rows]

def _unit(rng):
    v = [rng.uniform(-1, 1) for _ in range(3)]
    m = math.sqrt(sum(c * c for c in v)) or 1.0
    return [c / m for c in v]


# --- per-semantic inputs (keyed by ATTR index) ---------------------------

def hd_vs_inputs(seed, zero_w=False):
    r = random.Random(70000 + seed)
    n = _unit(r); tan = _unit(r)
    if zero_w:
        weights = [f2b(0.0)] * 4                          # rigid path
    else:
        w = [r.uniform(0.05, 1.0) for _ in range(4)]; s = sum(w)
        weights = [f2b(x / s) for x in w]                 # normalized, non-zero
    return {
        ("ATTR", 0): [f2b(r.uniform(-2, 2)) for _ in range(3)] + [f2b(1.0)],   # position
        ("ATTR", 1): [f2b(n[0]), f2b(n[1]), f2b(n[2]), f2b(0.0)],              # normal
        ("ATTR", 2): [f2b(r.uniform(0, 1)) for _ in range(4)],                 # color
        ("ATTR", 3): [f2b(r.uniform(-2, 2)) for _ in range(4)],                # uv0
        ("ATTR", 4): [f2b(r.uniform(-2, 2)) for _ in range(4)],                # uv1
        ("ATTR", 5): weights,                                                  # blendWeights
        ("ATTR", 6): [i2b(r.randint(0, 200)) for _ in range(4)],              # blendIndices (uint)
        ("ATTR", 7): [f2b(tan[0]), f2b(tan[1]), f2b(tan[2]),
                      f2b(r.choice([-1.0, 1.0]))],                             # tangent (+handedness)
    }


# --- constant buffers -----------------------------------------------------

def hd_vs_cbufs(seed):
    """cb2 per-draw matrices + misc, cb1 shadow cascades, cb3 bone palette."""
    rng = random.Random(seed * 7 + 1)

    # cb2: world@0-3, worldView@4-7, worldViewProj@8-11, then misc rows.
    cb2 = [[f2b(rng.uniform(-1, 1)) for _ in range(4)] for _ in range(24)]
    cb2[0:4]  = _rows_bits(_affine_rows(rng))
    cb2[4:8]  = _rows_bits(_affine_rows(rng))
    cb2[8:12] = _rows_bits(_affine_rows(rng))
    # cb2[12]: effectTime, popcornScale, clipHeight, underWater (sign flag)
    cb2[12] = [f2b(rng.uniform(0, 1)), f2b(rng.uniform(0, 1)),
               f2b(rng.uniform(-5, 5)), f2b(rng.choice([-1.0, 1.0]))]
    cb2[13] = [f2b(rng.uniform(0, 1)) for _ in range(4)]                       # diffuseColor
    for k in (14, 15, 16, 17):
        cb2[k] = [f2b(rng.uniform(-1, 1)) for _ in range(4)]                   # texMtx

    # cb1: three shadow-cascade matrices @0-3/4-7/8-11 feeding o6/o7/o8.
    cb1 = [[f2b(rng.uniform(-1, 1)) for _ in range(4)] for _ in range(16)]
    cb1[0:4]  = _rows_bits(_affine_rows(rng))
    cb1[4:8]  = _rows_bits(_affine_rows(rng))
    cb1[8:12] = _rows_bits(_affine_rows(rng))

    # cb3: 256-bone palette, three rows each (blendIndices*3 indexes it).
    cb3 = [[f2b(rng.uniform(-1, 1)) for _ in range(4)] for _ in range(768)]
    for bone in range(256):
        rows = _affine_rows(rng)[:3]
        for k in range(3):
            cb3[bone * 3 + k] = [f2b(x) for x in rows[k]]

    return {1: cb1, 2: cb2, 3: cb3}


# --- perm feature label (mirrors the scratch driver) ---------------------

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
    ap.add_argument('--tol', type=float, default=1e-4)
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
        for zero_w in (False, True):                     # weighted + rigid skinning
            res = compare(
                prog_s, prog_r, trials=args.trials, output_regs=OUTPUT_REGS,
                tol=args.tol,
                inputs_fn=(lambda s, zw=zero_w: hd_vs_inputs(s, zero_w=zw)),
                cbufs_fn=hd_vs_cbufs,
                sysvals_fn=(lambda s: {}),               # VS: no front-face sysval
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

    print(f"\n=== hd_vs: {len(perms)} perms x {args.trials} trials x 2 skin modes ===")
    print(f"output regs      : {list(OUTPUT_REGS)}")
    print(f"skin modes       : weighted + rigid (zero blend weights)")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"discard mismatch : {dm_total}")
    print(f"perms diverging  : {len(diverging)}")
    print("ALL MATCH" if not diverging else f"DIVERGING: {[d[0] for d in diverging]}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
