"""Differential test of the slang ``terrain_vs`` family against retail bytecode.

The Warcraft-III Reforged terrain VERTEX shader. Eight perms, up to ten outputs
(TEXCOORD7 splat indices + SV_POSITION + COLOR + TEXCOORD0..3, plus three
shadow-cascade clip coords TEXCOORD4/5/6 on the SHAD perms). No textures.

Input layout (per the retail "// Input signature"), keyed by ATTR index (single
digit, so no x10 remap needed):

    ATTR0 position(xyz)   ATTR6 blendIndices(uint,xyzw)   ATTR1 normal(xyz)
    ATTR7 tangent(xyzw)   ATTR2 color(xyzw)   ATTR3 uv0(xy)   ATTR4 uv1(xy)

The uint ATTR6 (splat layer indices) doubles as the TEXCOORD7 passthrough and is
compared against the ``0xFFFF`` sentinel (``ieq ... 0x0000ffff``) to decide the
"hole" vertex position (``movc o1, mask, l(0,0,-2,1), clip)``). ATTR6 is fed as
integer bits, sometimes all-0xFFFF so that hole branch actually fires.

Constant buffers are driven with MEANINGFUL matrices matching the slang
TerrainVSPerDraw layout:
    cb2 rows 0-3   shadowWorld (unused by most perms)
    cb2 rows 4-7   world rows 0-2 + worldTranslate (normal/tangent/geo basis)
    cb2 rows 8-11  worldViewProj (clip-space position)
    cb2 row  13    tintColor (-> COLOR0 output)
    cb1 rows 0-3 / 4-7 / 8-11   three shadow-cascade view-proj matrices (SHAD)

Compares o0..o9. Run from the repo root::

    python tools/shader_diff_terrain_vs.py                 # full 8-perm sweep
    python tools/shader_diff_terrain_vs.py --perms 2,6     # specific perms
    python tools/shader_diff_terrain_vs.py --trials 60

Feature bits (structural): bit1(2)=SHAD (cb1 cascades, o7/o8/o9);
bit2(4)=vertex-color attribute (reads ATTR2 xyzw).
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
RETAIL_DIR = REPO / "re_shaders" / "terrain_vs"
SLANG_DIR  = REPO / "slang_out" / "d3d11" / "terrain_vs"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 8

OUTPUT_REGS = tuple(range(10))   # TEXCOORD7, SV_POSITION, COLOR, TEXCOORD0..6

HOLE_INDEX = 0x0000FFFF          # sentinel splat index -> "hole" vertex


# --- meaningful matrix helpers (mirror sd_on_hd_vs) -----------------------

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


def terrain_vs_inputs(seed, hole=False):
    """Concrete per-semantic dict fed identically to both shaders.

    ``hole`` selects the sentinel path: all four ATTR6 lanes == 0xFFFF so the
    retail ``ieq(...0xffff)`` mask is true and the vertex snaps to the degenerate
    clip position (random indices essentially never hit this)."""
    r = random.Random(4000 + seed)
    n = _unit(r); tan = _unit(r)
    if hole:
        indices = [i2b(HOLE_INDEX)] * 4
    else:
        indices = [i2b(r.randint(0, 6)) for _ in range(4)]
    return {
        ("ATTR", 0): [f2b(r.uniform(-2, 2)) for _ in range(3)] + [f2b(1.0)],   # position
        ("ATTR", 6): indices,                                                  # blendIndices (uint)
        ("ATTR", 1): [f2b(n[0]), f2b(n[1]), f2b(n[2]), f2b(0.0)],              # normal
        ("ATTR", 7): [f2b(tan[0]), f2b(tan[1]), f2b(tan[2]),
                      f2b(r.choice([-1.0, 1.0]))],                             # tangent
        ("ATTR", 2): [f2b(r.uniform(0, 1)) for _ in range(4)],                 # color
        ("ATTR", 3): [f2b(r.uniform(-2, 2)) for _ in range(2)] + [f2b(0.0)] * 2,  # uv0
        ("ATTR", 4): [f2b(r.uniform(-2, 2)) for _ in range(2)] + [f2b(0.0)] * 2,  # uv1
    }


# --- constant buffers with meaningful transforms -------------------------

def terrain_vs_cbufs(seed):
    """cb2 (per-draw matrices matching TerrainVSPerDraw) + cb1 (shadow cascades)."""
    rng = random.Random(seed * 7 + 1)

    cb2 = [[f2b(rng.uniform(-2, 2)) for _ in range(4)] for _ in range(14)]
    cb2[0:4]  = _rows_bits(_affine_rows(rng))     # shadowWorld
    cb2[4:8]  = _rows_bits(_affine_rows(rng))     # world rows 0-2 + translate
    cb2[8:12] = _rows_bits(_affine_rows(rng))     # worldViewProj
    cb2[13]   = [f2b(rng.uniform(0, 1)) for _ in range(4)]   # tintColor

    cb1 = [[f2b(rng.uniform(-2, 2)) for _ in range(4)] for _ in range(12)]
    cb1[0:4]  = _rows_bits(_affine_rows(rng))     # shadow cascade 0 view-proj
    cb1[4:8]  = _rows_bits(_affine_rows(rng))     # shadow cascade 1
    cb1[8:12] = _rows_bits(_affine_rows(rng))     # shadow cascade 2

    return {1: cb1, 2: cb2}


# --- perm feature label ---------------------------------------------------

def feat(idx):
    f = []
    if idx & 2: f.append("SHAD")
    if idx & 4: f.append("VC")
    if idx & 1: f.append("b1")
    return "+".join(f) if f else "base"


def output_regs_for(prog):
    regs = sorted({reg for _, _, _, reg in prog.output_sig})
    return tuple(regs) if regs else (0,)


# --- driver ---------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=40)
    ap.add_argument('--tol', type=float, default=1e-4)
    ap.add_argument('--perms', default=None,
                    help='comma-separated perm indices (default: all 8)')
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
        oregs = output_regs_for(prog_r)

        perm_worst = 0.0; perm_where = None; perm_seed = None; perm_dm = 0
        # Sweep both the normal and the "hole" (all-0xFFFF index) path so the
        # sentinel movc branch gets real coverage.
        for hole in (False, True):
            res = compare(
                prog_s, prog_r, trials=args.trials, output_regs=oregs,
                tol=args.tol,
                inputs_fn=(lambda s, h=hole: terrain_vs_inputs(s, hole=h)),
                cbufs_fn=terrain_vs_cbufs,
                sysvals_fn=(lambda s: {}),
                seed0=(1000 if hole else 0))
            perm_dm += res.discard_mismatches
            if res.worst > perm_worst:
                perm_worst = res.worst; perm_where = res.worst_where
                perm_seed = (res.worst_seed, "hole" if hole else "normal")

        worst_all = max(worst_all, perm_worst)
        dm_total += perm_dm
        if perm_worst > args.tol or perm_dm:
            diverging.append((idx, perm_worst, perm_dm))
            print(f"  DIVERGE perm_{idx:03d} {feat(idx)}: worst={perm_worst:.3e} "
                  f"dm={perm_dm} regs={list(oregs)} at {perm_where} (seed {perm_seed})")

    print(f"\n=== terrain_vs: {len(perms)} perms x {args.trials} trials x 2 paths ===")
    print(f"output regs      : {list(OUTPUT_REGS)} (per-perm subset compared)")
    print(f"paths            : normal + hole (all-0xFFFF splat indices)")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"discard mismatch : {dm_total}")
    print(f"perms diverging  : {len(diverging)}")
    print("ALL MATCH" if not diverging else f"DIVERGING: {[d[0] for d in diverging]}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
