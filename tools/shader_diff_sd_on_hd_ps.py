"""Differential test of the slang ``sd_on_hd_ps`` family against retail bytecode.

The SD-on-HD family renders the classic (SD) art path through the HD deferred
pipeline, so it shares the HD-family constant-buffer *discriminant* layout with
``hd_ps`` / ``crystal_ps`` / ``popcorn_ps``: a debug mode, a light count, a
cascade count, per-light directional/point markers and an IBL probe bound flag.
As with the other families, random CB floats never land the exact discriminant
values (``lights[i].position.w == 0`` for directional, ``probeBound != 0``,
integer light/cascade/debug counts), so those are driven explicitly to force
branch coverage instead of leaving whole paths untested.

Built on :mod:`shader_diff`; a worked sibling of ``tools/shader_diff_popcorn.py``.
Inputs are generated per semantic and :func:`shader_diff.map_inputs` places each
into the right register channels of whichever shader it is feeding (handling the
slang x10 semantic-index naming and retail's per-register packing).

Outputs: SV_Target0 always; SV_Target1/2 additionally on the MRT (g-buffer)
perms -- comparing all of o0/o1/o2 is harmless where o1/o2 are unwritten (both
shaders leave them zero).

Run from the repo root::

    python tools/shader_diff_sd_on_hd_ps.py                 # full 384-perm sweep
    python tools/shader_diff_sd_on_hd_ps.py --perms 1,5     # specific perms
    python tools/shader_diff_sd_on_hd_ps.py --trials 60

Expected result after the June-2026 IBL fixes (brdf scale-vs-bias, shadow
fallback, debug modes 5-8): all 384 perms MATCH, worst ~1e-5 (fp / texture
residual). useNdf is forced off because specular-AA depends on real
screen-space derivatives a single-invocation interpreter cannot reproduce.
"""

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import f2b, i2b                         # noqa: E402
from shader_diff import load, compare                    # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "re_shaders" / "sd_on_hd"
SLANG_DIR  = REPO / "slang_out" / "d3d11" / "sd_on_hd_ps"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 384


# --- per-semantic inputs (SD-on-HD varying conventions) -------------------
# CONCRETE dict per trial so every ``.get(key)`` is deterministic regardless of
# which order each shader queries its semantics -- feeding the two shaders even
# slightly different values per semantic produces phantom diffs. The MRT/IBL
# perms additionally read TEXCOORD4/5/6 (normal / tangent / bitangent frame);
# always populate them (harmless where unread). TEXCOORD1.w gates the discard
# (``lt v3.w, 0`` -> discard_nz), so keep it positive to exercise the lit path.

def sohp_inputs(seed):
    r = random.Random(9000 + seed)

    def v4(lo=-1.5, hi=1.5):
        return [f2b(r.uniform(lo, hi)) for _ in range(4)]

    tc1 = v4()
    tc1[3] = f2b(r.uniform(0.05, 1.5))                    # v3.w > 0 -> no discard
    return {
        ("COLOR", 0):    [f2b(r.uniform(0, 1)) for _ in range(4)],   # vertColor
        ("TEXCOORD", 0): v4(),                                       # uv
        ("TEXCOORD", 1): tc1,                                        # view/params
        ("TEXCOORD", 2): v4(),                                       # normal-ish
        ("TEXCOORD", 3): v4(),
        ("TEXCOORD", 4): v4(),                                       # frame (MRT/IBL)
        ("TEXCOORD", 5): v4(),
        ("TEXCOORD", 6): v4(),
    }


# --- constant buffers with DRIVEN discriminants ---------------------------
# Shared HD-family discriminant layout:
#   cb3[0].y   debug mode
#   cb2[20].z  light count (loop / switch bound)
#   cb2[20].w  useNdf  -> FORCE 0.0 (specular-AA unmatchable, see docstring)
#   cb1[0].x   cascade count
#   cb2[4i+21] light block: +0 ambient, +1 diffuse, +2 position (.w==0 dir.)
#   cb2[19].x * cb2[19].y != 0  ->  IBL probe bound

def sohp_cbufs(seed):
    rng = random.Random(seed * 13 + 7)
    dbg        = rng.randint(0, 8)          # debug modes 0..8 (5-8 were buggy)
    lights     = rng.randint(0, 8)
    cascades   = rng.randint(0, 3)
    first_dir  = rng.random() < 0.5
    probe      = rng.random() < 0.6
    light_types = rng.getrandbits(8)

    def rows(n):
        return [[f2b(rng.uniform(-1, 1)) for _ in range(4)] for _ in range(n)]
    cb1 = rows(4); cb2 = rows(64); cb3 = rows(4)

    cb1[0][0] = i2b(cascades)               # cb1[0].x cascade count (ilt)
    cb3[0][1] = i2b(dbg)                     # cb3[0].y debug mode
    cb2[20][2] = i2b(lights)                 # cb2[20].z light count
    cb2[20][3] = f2b(0.0)                     # cb2[20].w useNdf OFF
    cb2[16][0] = f2b(rng.uniform(0, 1))
    cb2[16][1] = f2b(rng.uniform(0, 1))
    cb2[19][2] = f2b(rng.uniform(0, 1))
    # IBL probe bound iff cb2[19].x * cb2[19].y != 0
    cb2[19][0] = f2b(rng.uniform(0.1, 3) if probe else 0.0)
    cb2[19][1] = f2b(rng.uniform(0.1, 3) if probe else 0.0)
    # per-light block: light i at cb2[4i+21]=ambient, +22=diffuse, +23=position;
    # position.w == 0 marks the light directional (gates the first-light IBL
    # combine), > 0 marks it a point light.
    for i in range(8):
        directional = (i == 0 and first_dir) or (i > 0 and (light_types >> i) & 1)
        cb2[23 + i * 4][3] = f2b(0.0 if directional else rng.uniform(0.2, 3.0))
    return {1: cb1, 2: cb2, 3: cb3}


def sohp_sysvals(seed):
    return {'is_front_face': 0xFFFFFFFF if (seed & 1) else 0}


# --- perm feature label (for readable divergence reports) -----------------
# base = idx & 0x3F : MRT(1) DP(2) SHAD(4) IBL(8) FogL(16) FogE(32)
# hi   = idx // 64  : atlas / srgb / debug variant selector

def feat(idx):
    base = idx & 0x3F; hi = idx // 64
    f = []
    if base & 2:  f.append("DP")
    if base & 1:  f.append("MRT")
    if base & 4:  f.append("SHAD")
    if base & 8:  f.append("IBL")
    if (base & 16) and (base & 32): f.append("FogE2")
    elif base & 16: f.append("FogL")
    elif base & 32: f.append("FogE")
    if hi in (1, 4): f.append("AT")
    if hi in (2, 5): f.append("SRGB")
    if hi in (3, 4, 5): f.append("DBG")
    return "+".join(f) if f else "base"


# --- driver ---------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=150)
    ap.add_argument('--tol', type=float, default=1e-2)
    ap.add_argument('--perms', default=None,
                    help='comma-separated perm indices (default: all 384)')
    ap.add_argument('--retail-dir', default=str(RETAIL_DIR))
    ap.add_argument('--slang-dir', default=str(SLANG_DIR))
    ap.add_argument('--decompiler', default=str(DECOMPILER))
    args = ap.parse_args(argv)

    perms = ([int(x) for x in args.perms.split(',')] if args.perms
             else range(NPERMS))
    retail = Path(args.retail_dir); slang = Path(args.slang_dir)

    worst_all = 0.0; diverging = []; dm_total = 0
    for idx in perms:
        prog_r = load(retail / f"perm_{idx:03d}.asm")
        prog_s = load(slang / f"perm_{idx:03d}.dxbc", decompiler=args.decompiler)
        res = compare(prog_s, prog_r, trials=args.trials, output_regs=(0, 1, 2),
                      tol=args.tol, inputs_fn=sohp_inputs, cbufs_fn=sohp_cbufs,
                      sysvals_fn=sohp_sysvals)
        worst_all = max(worst_all, res.worst)
        dm_total += res.discard_mismatches
        if res.worst > args.tol or res.discard_mismatches:
            diverging.append((idx, res.worst, res.discard_mismatches))
            print(f"  DIVERGE perm_{idx} {feat(idx)}: worst={res.worst:.3e} "
                  f"dm={res.discard_mismatches} (seed {res.worst_seed})")
        if idx % 64 == 0:
            print(f"  ...perm {idx} (running worst {worst_all:.1e})", file=sys.stderr)

    n = len(perms) if not isinstance(perms, range) else len(perms)
    print(f"\n=== sd_on_hd_ps: {n} perms x {args.trials} trials ===")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"discard mismatch : {dm_total}")
    print(f"perms diverging  : {len(diverging)}")
    print("ALL MATCH" if not diverging else f"DIVERGING: {[d[0] for d in diverging]}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
