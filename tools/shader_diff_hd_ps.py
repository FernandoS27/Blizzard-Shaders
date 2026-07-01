"""Differential test of the slang ``hd_ps`` family against retail bytecode.

A worked example of :mod:`shader_diff` for the Warcraft-III Reforged HD mesh
pixel shader. Like ``tools/shader_diff_popcorn.py`` it (a) generates structured
per-semantic inputs and (b) *drives* the constant-buffer discriminants that
select the shader's branches, because random CB floats never land on the exact
integer/zero values those branches test (light count, cascade count, debug
mode, ``light.position.w == 0`` directional gate, IBL probe-bound).

It sweeps all 512 perms (retail ``perm_NNN.asm`` vs the slang ``perm_NNN.dxbc``
under ``slang_out``). ``hd_ps`` is an MRT shader: perms with the MRT feature bit
write three SV_Target registers (RT0/RT1/RT2), the rest write only RT0. The
driver reads each retail perm's output signature and compares exactly those
registers. Run from the repo root::

    python tools/shader_diff_hd_ps.py                    # full 512-perm sweep
    python tools/shader_diff_hd_ps.py --perms 0,1,4      # specific perms
    python tools/shader_diff_hd_ps.py --trials 60

Known-good result: with useNdf forced OFF, all 512 perms MATCH, worst ~1.1e-5
(texture / fp residual). useNdf is forced off because specular-AA depends on
real screen-space derivatives, which a single-invocation interpreter can't
reproduce.
"""

import argparse
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import Program, f2b, i2b                 # noqa: E402
from shader_diff import load, compare                     # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "re_shaders" / "hd"
SLANG_DIR  = REPO / "slang_out" / "d3d11" / "hd_ps"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 512


# --- per-semantic inputs (Wc3 HD mesh varying conventions) ----------------
# Retail packs the HD PS varyings one-semantic-per-register:
#   COLOR0=vertColor, TEXCOORD0=uv, TEXCOORD1=viewPos(+fogDepth.w),
#   TEXCOORD2=normalWS(unit), TEXCOORD3=tangentWS(unit,.w=+/-1 handedness),
#   TEXCOORD4/5/6=shadow-cascade clip coords (SHAD perms only).
# The slang side names these with the x10 semantic index (TEXCOORD10 ==
# retail TEXCOORD1); shader_diff.map_inputs handles that automatically. Build a
# CONCRETE dict once per trial so every ``.get(key)`` is deterministic and both
# shaders get identical values.

def _unit(rng):
    v = [rng.uniform(-1, 1) for _ in range(3)]
    m = math.sqrt(sum(c * c for c in v)) or 1.0
    return [c / m for c in v]

def hd_inputs(seed):
    r = random.Random(9000 + seed)
    n = _unit(r); t = _unit(r)
    # Bias shadow clip coords inside the cascade frustum ([-1,1] xy, [0,1) z)
    # ~60% of the time so the frustum-select branches actually fire.
    in_frustum = r.random() < 0.6

    def clip():
        if in_frustum:
            return [f2b(r.uniform(-0.9, 0.9)), f2b(r.uniform(-0.9, 0.9)),
                    f2b(r.uniform(0.05, 0.95)), f2b(1.0)]
        return [f2b(r.uniform(-1.5, 1.5)) for _ in range(3)] + [f2b(1.0)]

    return {
        ("COLOR", 0):    [f2b(r.uniform(0, 1)) for _ in range(4)],            # vertColor
        ("TEXCOORD", 0): [f2b(r.uniform(-2, 2)) for _ in range(4)],           # uv
        ("TEXCOORD", 1): [f2b(r.uniform(-20, 20)) for _ in range(3)]
                         + [f2b(r.uniform(-5, 5))],                           # viewPos + fogDepth
        ("TEXCOORD", 2): [f2b(n[0]), f2b(n[1]), f2b(n[2]), f2b(0.0)],         # normalWS (unit)
        ("TEXCOORD", 3): [f2b(t[0]), f2b(t[1]), f2b(t[2]),
                          f2b(r.choice([-1.0, 1.0]))],                        # tangentWS
        ("TEXCOORD", 4): clip(),                                             # shadow clip cascade 0
        ("TEXCOORD", 5): clip(),                                             # shadow clip cascade 1
        ("TEXCOORD", 6): clip(),                                             # shadow clip cascade 2
    }


# --- constant buffers with DRIVEN discriminants ---------------------------

def hd_cbufs(seed):
    """cb1/cb2/cb3 with the branch discriminants driven explicitly:
      cb1[0].x  cascade count (int, ilt frustum-loop bound)
      cb2[20].z light count / shadow mode (int, ult / switch selector)
      cb2[20].w useNdf -> FORCED 0.0 (specular-AA unmatchable)
      cb3[0].y  debug mode (int)
      cb2[19].xy IBL probe extents (bound iff x*y != 0)
      cb2[4i+23].w per-light position.w (0 == directional, >0 == point)
    """
    rng = random.Random(seed * 13 + 7)
    dbg = seed % 9
    lights = rng.randint(0, 8)
    cascades = rng.randint(0, 3)
    first_dir = rng.random() < 0.5
    probe = rng.random() < 0.6
    light_types = rng.getrandbits(8)

    def rows(n):
        return [[f2b(rng.uniform(-1, 1)) for _ in range(4)] for _ in range(n)]
    cb1 = rows(4); cb2 = rows(60); cb3 = rows(4)

    cb1[0][0] = i2b(cascades)                # cascade count
    cb3[0][1] = i2b(dbg)                      # debug mode
    cb2[20][2] = i2b(lights)                  # light count / shadow mode
    cb2[20][3] = f2b(0.0)                     # useNdf OFF (specular-AA unmatchable)
    cb2[16][0] = f2b(rng.uniform(0, 1))
    cb2[16][1] = f2b(rng.uniform(0, 1))
    cb2[19][2] = f2b(rng.uniform(0, 1))
    # IBL probe bound iff envFromMip*envToMip != 0
    cb2[19][0] = f2b(rng.uniform(0.1, 3) if probe else 0.0)
    cb2[19][1] = f2b(rng.uniform(0.1, 3) if probe else 0.0)
    # per-light position.w: 0 == directional (first-light IBL gate), >0 == point
    for i in range(8):
        directional = (i == 0 and first_dir) or (i > 0 and (light_types >> i) & 1)
        cb2[23 + i * 4][3] = f2b(0.0 if directional else rng.uniform(0.2, 3.0))
    return {1: cb1, 2: cb2, 3: cb3}


def hd_sysvals(seed):
    return {'is_front_face': 0xFFFFFFFF if (seed & 1) else 0}


# --- perm feature label (for readable divergence reports) -----------------
# hd_ps 9-bit encoding: MRT,DP,SHAD,IBL,FogL,FogE,AT,ML,DBG.

def feat(idx):
    f = []
    if idx & 2:   f.append("DP")
    if idx & 1:   f.append("MRT")
    if idx & 4:   f.append("SHAD")
    if idx & 8:   f.append("IBL")
    if (idx & 16) and (idx & 32): f.append("FogE2")
    elif idx & 16: f.append("FogL")
    elif idx & 32: f.append("FogE")
    if idx & 64:  f.append("AT")
    if idx & 128: f.append("ML")
    if idx & 256: f.append("DBG")
    return "+".join(f) if f else "base"


def output_regs_for(prog):
    """SV_Target registers this shader writes (RT0, plus RT1/RT2 on MRT perms)."""
    regs = sorted({reg for name, _, _, reg in prog.output_sig
                   if name.upper() == "SV_TARGET"})
    return tuple(regs) if regs else (0,)


# --- driver ---------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=60)
    ap.add_argument('--tol', type=float, default=1e-2)
    ap.add_argument('--perms', default=None,
                    help='comma-separated perm indices (default: all 512)')
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
        res = compare(prog_s, prog_r, trials=args.trials, output_regs=oregs,
                      tol=args.tol, inputs_fn=hd_inputs, cbufs_fn=hd_cbufs,
                      sysvals_fn=hd_sysvals)
        worst_all = max(worst_all, res.worst)
        dm_total += res.discard_mismatches
        if res.worst > args.tol or res.discard_mismatches:
            diverging.append((idx, res.worst, res.discard_mismatches))
            print(f"  DIVERGE perm_{idx:03d} {feat(idx)}: worst={res.worst:.3e} "
                  f"dm={res.discard_mismatches} regs={list(oregs)} "
                  f"(seed {res.worst_seed} at {res.worst_where})")
        if idx % 64 == 0:
            print(f"  ...perm {idx} (running worst {worst_all:.1e})", file=sys.stderr)

    print(f"\n=== hd_ps: {len(perms)} perms x {args.trials} trials ===")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"discard mismatch : {dm_total}")
    print(f"perms diverging  : {len(diverging)}")
    print("ALL MATCH" if not diverging else f"DIVERGING: {[d[0] for d in diverging]}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
