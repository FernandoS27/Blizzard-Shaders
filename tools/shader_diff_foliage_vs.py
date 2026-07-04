"""Differential test of the slang ``foliage_vs`` family against retail bytecode.

A worked example of :mod:`shader_diff` for a VERTEX shader with 8 perms. Inputs
are ATTR vertex attributes (retail "// Input signature", keyed by ATTR index;
the slang ATTRx10 naming is resolved by :func:`shader_diff.map_inputs`):

    ATTR0 position   ATTR1 normal   ATTR2 color(+.w anim gate)   ATTR3 uv0
    ATTR4 uv1        ATTR5 blendWeights   ATTR6 blendIndices(uint)   ATTR7 tangent

Unlike ``sd_on_hd_vs`` this family has NO GPU-skinning path (blendWeights /
blendIndices are declared but never read in any of the 8 perms). It DOES have a
foliage-animation branch (perms 4-7) gated on ``ATTR2.w > 0`` -- we sweep that
gate BOTH ways so the animated and static paths are both covered. The animation
path samples a noise texture with explicit LOD (deterministic in the interp) and
reads cb3[0] (an animation bounding box, min.xy / size.zw) plus cb2[12].x (time)
-- these are driven with sane, non-degenerate values (size != 0) so the div's
stay finite.

Constant buffers driven with MEANINGFUL matrices:
    cb2[4..7] world (3x4), cb2[8..11] worldViewProj (4x4), cb2[13] color scale,
    cb2[14..15] uv transform, cb2[12] misc/time.
    cb1[0..11] up to three shadow-cascade view-proj matrices (perms 2, 6 ->
    TEXCOORD4/5/6 outputs).
    cb3[0] foliage-animation box (perms 4-7).

Compares all declared o# outputs (o0..o8). Run from the repo root::

    python tools/shader_diff_foliage_vs.py                 # full 8-perm sweep
    python tools/shader_diff_foliage_vs.py --perms 2,6     # specific perms
    python tools/shader_diff_foliage_vs.py --trials 40
"""

import argparse
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import f2b, i2b                          # noqa: E402
from shader_diff import load, compare                     # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "re_shaders" / "foliage_vs"
SLANG_DIR  = REPO / "slang_out" / "d3d11" / "foliage_vs"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 8

# up to nine VS outputs: SV_POSITION, COLOR, TEXCOORD0..6
OUTPUT_REGS = tuple(range(9))


# --- meaningful matrix helpers (mirrors sd_on_hd_vs) ----------------------

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


def foliage_vs_inputs(seed, animate=False):
    """Concrete per-semantic dict fed identically to both shaders.

    ``animate`` drives the ATTR2.w foliage-animation gate: >0 takes the animated
    path (perms 4-7), <=0 the static path. (Random .w would essentially always
    be non-zero, leaving the static branch untested.)
    """
    r = random.Random(4000 + seed)
    n = _unit(r); tan = _unit(r)
    color_w = r.uniform(0.1, 1.0) if animate else 0.0
    return {
        ("ATTR", 0): [f2b(r.uniform(-2, 2)) for _ in range(3)] + [f2b(1.0)],   # position
        ("ATTR", 1): [f2b(n[0]), f2b(n[1]), f2b(n[2]), f2b(0.0)],              # normal
        ("ATTR", 2): [f2b(r.uniform(0, 1)), f2b(r.uniform(0, 1)),
                      f2b(r.uniform(0, 1)), f2b(color_w)],                     # color(+anim gate)
        ("ATTR", 3): [f2b(r.uniform(-2, 2)) for _ in range(4)],                # uv0
        ("ATTR", 4): [f2b(r.uniform(-2, 2)) for _ in range(3)]
                     + [f2b(r.choice([-1.0, 1.0]))],                           # uv1 (+.w sign gate)
        ("ATTR", 5): [f2b(r.uniform(0, 1)) for _ in range(4)],                 # blendWeights (unused)
        ("ATTR", 6): [i2b(r.randint(0, 40)) for _ in range(4)],               # blendIndices (unused)
        ("ATTR", 7): [f2b(tan[0]), f2b(tan[1]), f2b(tan[2]),
                      f2b(r.choice([-1.0, 1.0]))],                             # tangent
    }


# --- constant buffers with meaningful transforms + driven anim box --------

def foliage_vs_cbufs(seed):
    rng = random.Random(seed * 7 + 1)

    # cb2: world (rows 4-7), worldViewProj (rows 8-11) as affine transforms;
    # cb2[13] color scale, cb2[14..15] uv transform, cb2[12] time. Rest tame.
    cb2 = [[f2b(rng.uniform(-2, 2)) for _ in range(4)] for _ in range(24)]
    cb2[4:8]  = _rows_bits(_affine_rows(rng))     # world
    cb2[8:12] = _rows_bits(_affine_rows(rng))     # worldViewProj
    cb2[12] = [f2b(rng.uniform(0, 10)) for _ in range(4)]   # time etc (frc'd)
    cb2[13] = [f2b(rng.uniform(0, 1)) for _ in range(4)]    # color scale
    cb2[14] = [f2b(rng.uniform(-1, 1)) for _ in range(4)]   # uv xform row0
    cb2[15] = [f2b(rng.uniform(-1, 1)) for _ in range(4)]   # uv xform row1

    # cb1: up to three shadow-cascade view-proj matrices (rows 0-3,4-7,8-11).
    cb1 = [[f2b(rng.uniform(-2, 2)) for _ in range(4)] for _ in range(16)]
    cb1[0:4]  = _rows_bits(_affine_rows(rng))
    cb1[4:8]  = _rows_bits(_affine_rows(rng))
    cb1[8:12] = _rows_bits(_affine_rows(rng))

    # cb3[0]: foliage-animation box -- min.xy, size.zw. Size MUST be non-zero
    # (the animation path divides by cb3[0].zw); keep it well away from 0.
    cb3 = [[f2b(rng.uniform(-2, 2)) for _ in range(4)] for _ in range(4)]
    cb3[0] = [f2b(rng.uniform(-2, 2)), f2b(rng.uniform(-2, 2)),
              f2b(rng.uniform(2, 6)), f2b(rng.uniform(2, 6))]

    return {1: cb1, 2: cb2, 3: cb3}


# --- perm feature label ----------------------------------------------------
# 8 perms: bit 1 => cascade/shadow output (cb1 -> TEXCOORD4/5/6), bit 2 => anim
# (cb3). Determined from cb usage (see index.csv analysis).

def feat(idx):
    f = []
    if idx & 2: f.append("SHAD")
    if idx & 4: f.append("ANIM")
    if idx & 1: f.append("b0")
    return "+".join(f) if f else "base"


def output_regs_for(prog):
    seen = set()
    for name, _, _, reg in prog.output_sig:
        u = name.upper()
        if u in ("SV_POSITION", "COLOR", "TEXCOORD"):
            seen.add(reg)
    return tuple(sorted(seen)) if seen else OUTPUT_REGS


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
        # Sweep both animation-gate modes (static + animated).
        for animate in (False, True):
            res = compare(
                prog_s, prog_r, trials=args.trials, output_regs=oregs,
                tol=args.tol,
                inputs_fn=(lambda s, an=animate: foliage_vs_inputs(s, animate=an)),
                cbufs_fn=foliage_vs_cbufs,
                sysvals_fn=(lambda s: {}),            # VS: no front-face sysval
                seed0=(1000 if animate else 0))
            perm_dm += res.discard_mismatches
            if res.worst > perm_worst:
                perm_worst = res.worst; perm_where = res.worst_where
                perm_seed = (res.worst_seed, "anim" if animate else "static")

        worst_all = max(worst_all, perm_worst)
        dm_total += perm_dm
        if perm_worst > args.tol or perm_dm:
            diverging.append((idx, perm_worst, perm_dm))
            print(f"  DIVERGE perm_{idx:03d} {feat(idx)}: worst={perm_worst:.3e} "
                  f"dm={perm_dm} regs={list(oregs)} at {perm_where} (seed {perm_seed})")
        else:
            print(f"  ok      perm_{idx:03d} {feat(idx)}: worst={perm_worst:.3e} "
                  f"regs={list(oregs)}")

    print(f"\n=== foliage_vs: {len(perms)} perms x {args.trials} trials x 2 anim modes ===")
    print(f"output regs      : varies per perm (o0..o8)")
    print(f"anim modes       : static + animated (ATTR2.w gate)")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"discard mismatch : {dm_total}")
    print(f"perms diverging  : {len(diverging)}")
    print("ALL MATCH" if not diverging else f"DIVERGING: {[d[0] for d in diverging]}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
