"""Differential test of the slang ``water_vs`` against retail bytecode.

A worked example of :mod:`shader_diff` for the Warcraft-III Reforged water
VERTEX shader. Single permutation. No textures, no loops, no discards — the
shader is a straight transform pipeline reading only ``cb2`` (a per-draw matrix
block) and four ATTR inputs, and writing six outputs
(SV_POSITION + COLOR + TEXCOORD0/1/3/4).

Input layout (per the retail "// Input signature"), keyed by ATTR index; the
slang ATTRx10 naming is resolved by :func:`shader_diff.map_inputs`:

    ATTR0 position (xyz)   ATTR1 normal (xyz)   ATTR2 color (xyzw)   ATTR3 uv (xy)

Constant buffer ``cb2`` is driven with MEANINGFUL affine transforms so the
transform math exercises well-conditioned data:

    cb2[4..7]   worldView         (o3 = worldView * position, o4 = normalize(WV3x3 * normal))
    cb2[8..11]  worldViewProj     (o0 = clip position)
    cb2[14..15] texMtx0 rows      (o2 = tex-matrix * uv)

o1 (COLOR) and o5 come straight from ATTR2 / cb2[5], so they match trivially.

Run from the repo root::

    python tools/shader_diff_water_vs.py                 # full sweep (1 perm)
    python tools/shader_diff_water_vs.py --trials 200

Goal tolerance ~1e-4 (VS, double-precision-vs-float32 dot reordering residual).
"""

import argparse
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import f2b                              # noqa: E402
from shader_diff import load, compare                    # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "re_shaders" / "water_vs"
SLANG_DIR  = REPO / "slang_out" / "d3d11" / "water_vs"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 1

# six VS outputs: SV_POSITION, COLOR, TEXCOORD0, TEXCOORD1, TEXCOORD3, TEXCOORD4
OUTPUT_REGS = (0, 1, 2, 3, 4, 5)


# --- meaningful matrix helpers (mirrors sd_on_hd_vs driver) --------------

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
    """A 4x4 affine transform (rotation + small translation) as 4 row 4-vectors.

    Translation kept small (|t|<=2) so composed clip magnitudes stay modest and
    the double-vs-float32 dot-reordering residual stays down in fp-noise range."""
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


def water_vs_inputs(seed):
    r = random.Random(4000 + seed)
    n = _unit(r)
    return {
        ("ATTR", 0): [f2b(r.uniform(-2, 2)) for _ in range(3)] + [f2b(1.0)],   # position
        ("ATTR", 1): [f2b(n[0]), f2b(n[1]), f2b(n[2]), f2b(0.0)],              # normal
        ("ATTR", 2): [f2b(r.uniform(0, 1)) for _ in range(4)],                 # color
        ("ATTR", 3): [f2b(r.uniform(-2, 2)) for _ in range(4)],                # uv
    }


# --- constant buffer with meaningful transforms --------------------------

def water_vs_cbufs(seed):
    """cb2: worldView (rows 4-7), worldViewProj (rows 8-11), texMtx0
    (rows 14-15); rest tame random so any stray read is stable."""
    rng = random.Random(seed * 7 + 1)
    cb2 = [[f2b(rng.uniform(-2, 2)) for _ in range(4)] for _ in range(16)]
    cb2[4:8]   = _rows_bits(_affine_rows(rng))    # worldView
    cb2[8:12]  = _rows_bits(_affine_rows(rng))    # worldViewProj
    cb2[14:16] = _rows_bits(_affine_rows(rng))[:2]  # texMtx0 rows 0/1
    return {2: cb2}


# --- driver ---------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=200)
    ap.add_argument('--tol', type=float, default=1e-4)
    ap.add_argument('--perms', default=None,
                    help='comma-separated perm indices (default: all, 1 perm)')
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
        res = compare(
            prog_s, prog_r, trials=args.trials, output_regs=OUTPUT_REGS,
            tol=args.tol, inputs_fn=water_vs_inputs, cbufs_fn=water_vs_cbufs,
            sysvals_fn=(lambda s: {}))            # VS: no front-face sysval
        worst_all = max(worst_all, res.worst)
        dm_total += res.discard_mismatches
        if res.worst > args.tol or res.discard_mismatches:
            diverging.append((idx, res.worst, res.discard_mismatches))
            print(f"  DIVERGE perm_{idx:03d}: worst={res.worst:.3e} "
                  f"dm={res.discard_mismatches} (seed {res.worst_seed} at {res.worst_where})")

    print(f"\n=== water_vs: {len(perms)} perm(s) x {args.trials} trials ===")
    print(f"output regs      : {list(OUTPUT_REGS)}")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"discard mismatch : {dm_total}")
    print(f"perms diverging  : {len(diverging)}")
    print("ALL MATCH" if not diverging else f"DIVERGING: {[d[0] for d in diverging]}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
