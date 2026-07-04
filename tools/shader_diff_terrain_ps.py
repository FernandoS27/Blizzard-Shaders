"""Differential test of the slang ``terrain_ps`` family against retail bytecode.

The Warcraft-III Reforged terrain pixel shader. It is HD-light-family lit (same
cb2 light layout as ``hd_ps``: ``cb2[20].z`` light count, per-light ambient/
diffuse/position at ``cb2[21+4i] / cb2[22+4i] / cb2[23+4i]``, IBL probe bound by
``cb2[19].x*y``, useNdf at ``cb2[20].w``), plus terrain-specific machinery:

  * up to four **splat layers** selected by a uint varying ``TEXCOORD7`` (v0);
    each lane is a texture-array slice index, or the sentinel ``0xFFFF`` meaning
    "layer absent" (retail: ``ine v0, 0x0000ffff`` gates each layer's blend).
  * an optional SHAD feature: shadow-cascade clip coords in TEXCOORD4/5/6
    (v7/v8/v9), a PCF loop bounded by ``cb1[0].x`` (cascade count), sampling
    depth maps t10/t11/t12 with ``sample_c_lz``.
  * an optional DEBUG feature (perms >= 64): a ``cb3`` DebugVisCB whose
    ``cb3[0].x`` enable-bitmask conditionally overrides albedo/orm.

128 perms. Feature bits (from structural analysis):
    bit0(1)=MRT   bit1(2)=NO-OUTPUT(depth-only, empty ret)   bit2(4)=SHAD
    bit6(64)=DEBUG ; bits 3/4/5 do not alter the compiled body.
Perms with ``idx%4 in {2,3}`` are empty (both slang & retail emit ``ret`` only) —
they have no SV_Target, so there is nothing to compare and they are skipped.

Discriminants are DRIVEN (light count, cascade count, directional gate, IBL
probe bound, debug enable mask, useNdf forced OFF) because random CB floats
never land on the integer/zero values those branches test. useNdf is forced off
for the same reason as hd_ps: specular-AA needs real screen-space derivatives a
single-invocation interpreter cannot reproduce.

Run from the repo root::

    python tools/shader_diff_terrain_ps.py                 # full 128-perm sweep
    python tools/shader_diff_terrain_ps.py --perms 0,1,4,5 # specific perms
    python tools/shader_diff_terrain_ps.py --trials 80
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
RETAIL_DIR = REPO / "re_shaders" / "terrain"
SLANG_DIR  = REPO / "slang_out" / "d3d11" / "terrain_ps"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 128

LAYER_ABSENT = 0x0000FFFF   # sentinel: "this splat layer is not present"


def _unit(rng):
    v = [rng.uniform(-1, 1) for _ in range(3)]
    m = math.sqrt(sum(c * c for c in v)) or 1.0
    return [c / m for c in v]


# --- per-semantic inputs --------------------------------------------------
# Retail packs the terrain PS varyings one-semantic-per-register:
#   TEXCOORD7 (v0, uint) = four splat-layer array indices (or 0xFFFF absent)
#   COLOR0    (v2)       = vertex color; .w is a per-splat blend weight
#   TEXCOORD0 (v3)       = splat uv (.xy) + lightmap uv (.zw)
#   TEXCOORD1 (v4)       = view-space position (view dir = normalize(-v4))
#   TEXCOORD2 (v5)       = geometric basis row (used with tangent for TBN)
#   TEXCOORD3 (v6)       = tangent (.xyz) + handedness (.w = +/-1)
#   TEXCOORD4/5/6 (v7/8/9) = shadow-cascade clip coords (SHAD perms)

def terrain_ps_inputs(seed):
    r = random.Random(7000 + seed)
    n = _unit(r); t = _unit(r)

    # Splat-layer indices: each lane independently present (small index) or the
    # 0xFFFF sentinel, so every combination of the four `ine`-gated blends fires
    # across the trial sweep.
    def layer():
        return LAYER_ABSENT if r.random() < 0.35 else r.randint(0, 6)
    layers = [layer() for _ in range(4)]

    # Shadow clip coords: bias ~60% inside the cascade frustum so the
    # PCF-select branches actually execute; .z is the compare reference.
    in_frustum = r.random() < 0.6

    def shad():
        if in_frustum:
            return [f2b(r.uniform(-0.9, 0.9)), f2b(r.uniform(-0.9, 0.9)),
                    f2b(r.uniform(0.05, 0.95)), f2b(1.0)]
        return [f2b(r.uniform(-1.5, 1.5)) for _ in range(3)] + [f2b(1.0)]

    return {
        ("TEXCOORD", 7): [i2b(x) for x in layers],                            # uint layer indices
        ("COLOR", 0):    [f2b(r.uniform(0, 1)) for _ in range(4)],            # vertColor + weight
        ("TEXCOORD", 0): [f2b(r.uniform(-2, 2)) for _ in range(4)],           # splat uv + lightmap uv
        ("TEXCOORD", 1): [f2b(r.uniform(-20, 20)) for _ in range(3)]
                         + [f2b(r.uniform(-5, 5))],                           # view-space position
        ("TEXCOORD", 2): [f2b(n[0]), f2b(n[1]), f2b(n[2]), f2b(0.0)],         # basis row
        ("TEXCOORD", 3): [f2b(t[0]), f2b(t[1]), f2b(t[2]),
                          f2b(r.choice([-1.0, 1.0]))],                        # tangent + handedness
        ("TEXCOORD", 4): shad(),                                             # shadow clip cascade 0
        ("TEXCOORD", 5): shad(),                                             # shadow clip cascade 1
        ("TEXCOORD", 6): shad(),                                             # shadow clip cascade 2
    }


# --- constant buffers with DRIVEN discriminants ---------------------------

def terrain_ps_cbufs(seed):
    """cb1 (cascade count + shadow VP), cb2 (HD light layout + matrices),
    cb3 (debug vis) with the branch discriminants driven explicitly.
      cb1[0].x  shadow cascade count (int, ilt/uge PCF-loop bound)
      cb2[7..9] view matrix rows (world normal -> view, for IBL cube lookup)
      cb2[19].x/.y IBL probe extents (probe bound iff x*y != 0); .z transition
      cb2[20].z light count (int, uge light-loop bound)
      cb2[20].w useNdf -> FORCED 0.0 (specular-AA unmatchable)
      cb2[21+4i]/[22+4i]/[23+4i] per-light ambient/diffuse/position(.w=type)
      cb2[23+4i].w == 0 -> directional (first-light IBL gate / point-vs-dir)
      cb3[0].x  debug enable bitmask (uint); cb3[1]/[2] override albedo/orm
    """
    rng = random.Random(seed * 13 + 7)
    lights = rng.randint(0, 8)
    cascades = rng.randint(0, 3)
    first_dir = rng.random() < 0.5
    probe = rng.random() < 0.6
    light_types = rng.getrandbits(8)
    debug_mask = rng.randint(0, 3)          # exercises the bit0/bit1 override movc

    def rows(n):
        return [[f2b(rng.uniform(-1, 1)) for _ in range(4)] for _ in range(n)]

    cb1 = rows(16); cb2 = rows(60); cb3 = rows(3)

    cb1[0][0] = i2b(cascades)               # cascade count (shadow PCF loop bound)

    cb2[20][2] = i2b(lights)                # light count
    cb2[20][3] = f2b(0.0)                    # useNdf OFF (specular-AA unmatchable)
    # IBL probe bound iff envFromMipEnd*envToMipEnd != 0; .z is transition t.
    cb2[19][0] = f2b(rng.uniform(0.1, 3) if probe else 0.0)
    cb2[19][1] = f2b(rng.uniform(0.1, 3) if probe else 0.0)
    cb2[19][2] = f2b(rng.uniform(0, 1))
    # per-light position.w: 0 == directional (first-light IBL gate), >0 == point
    for i in range(8):
        directional = (i == 0 and first_dir) or (i > 0 and (light_types >> i) & 1)
        cb2[23 + i * 4][3] = f2b(0.0 if directional else rng.uniform(0.2, 3.0))

    cb3[0][0] = i2b(debug_mask)             # enable bitmask (uint)

    return {1: cb1, 2: cb2, 3: cb3}


def terrain_ps_sysvals(seed):
    return {'is_front_face': 0xFFFFFFFF if (seed & 1) else 0}


# --- perm feature label ---------------------------------------------------

def feat(idx):
    f = []
    if idx & 1:  f.append("MRT")
    if idx & 2:  f.append("NOOUT")
    if idx & 4:  f.append("SHAD")
    if idx & 64: f.append("DBG")
    other = idx & (8 | 16 | 32)
    if other:    f.append(f"b{other}")
    return "+".join(f) if f else "base"


def output_regs_for(prog):
    """SV_Target registers this shader writes (RT0, plus RT1/RT2 on MRT perms).
    Empty (depth-only) perms have none."""
    regs = sorted({reg for name, _, _, reg in prog.output_sig
                   if name.upper() == "SV_TARGET"})
    return tuple(regs)


# --- driver ---------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=60)
    ap.add_argument('--tol', type=float, default=1e-2)
    ap.add_argument('--perms', default=None,
                    help='comma-separated perm indices (default: all 128)')
    ap.add_argument('--retail-dir', default=str(RETAIL_DIR))
    ap.add_argument('--slang-dir', default=str(SLANG_DIR))
    ap.add_argument('--decompiler', default=str(DECOMPILER))
    args = ap.parse_args(argv)

    perms = ([int(x) for x in args.perms.split(',')] if args.perms
             else list(range(NPERMS)))
    retail = Path(args.retail_dir); slang = Path(args.slang_dir)

    worst_all = 0.0; diverging = []; dm_total = 0; empty = 0
    for idx in perms:
        prog_r = load(retail / f"perm_{idx:03d}.asm")
        prog_s = load(slang / f"perm_{idx:03d}.dxbc", decompiler=args.decompiler)
        oregs = output_regs_for(prog_r)
        if not oregs:
            empty += 1
            continue
        res = compare(prog_s, prog_r, trials=args.trials, output_regs=oregs,
                      tol=args.tol, inputs_fn=terrain_ps_inputs,
                      cbufs_fn=terrain_ps_cbufs, sysvals_fn=terrain_ps_sysvals)
        worst_all = max(worst_all, res.worst)
        dm_total += res.discard_mismatches
        if res.worst > args.tol or res.discard_mismatches:
            diverging.append((idx, res.worst, res.discard_mismatches))
            print(f"  DIVERGE perm_{idx:03d} {feat(idx)}: worst={res.worst:.3e} "
                  f"dm={res.discard_mismatches} regs={list(oregs)} "
                  f"(seed {res.worst_seed} at {res.worst_where})")
        if idx % 32 == 0:
            print(f"  ...perm {idx} (running worst {worst_all:.1e})", file=sys.stderr)

    print(f"\n=== terrain_ps: {len(perms)-empty} lit perms x {args.trials} trials "
          f"({empty} empty/depth-only skipped) ===")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"discard mismatch : {dm_total}")
    print(f"perms diverging  : {len(diverging)}")
    print("ALL MATCH" if not diverging else f"DIVERGING: {[d[0] for d in diverging]}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
