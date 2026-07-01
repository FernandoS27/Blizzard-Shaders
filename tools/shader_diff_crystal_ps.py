"""Differential test of the slang ``crystal_ps`` family against retail bytecode.

A worked example of :mod:`shader_diff` for the crystal (gem / refraction) shader,
which patches HD via BLS and therefore shares the HD-family constant-buffer
discriminant layout (light count / cascade count / debug mode / IBL probe /
per-light directional flag) plus crystal's own refraction + shadow path. As with
``shader_diff_popcorn``, the key is to *drive* those CB discriminants explicitly:
random floats never make ``lights[0].position.w == 0.0`` (directional first light)
or ``probeExtent != 0`` land, so whole branches would go untested otherwise.

Crystal input varyings (retail signature, fed per-semantic; ``map_inputs`` places
each into the right register/channels for either shader):

    COLOR    0  -> vertColor        (v1)
    TEXCOORD 0  -> uv               (v2.xy)
    TEXCOORD 1  -> viewVec + depth  (v3.xyz view, v3.w gates the discard)
    TEXCOORD 2  -> normalWS  (unit) (v4.xyz)
    TEXCOORD 3  -> tangentWS (unit) (v5.xyz, v5.w handedness +/-1)

Outputs: single RT (o0) for most perms; the MRT (g-buffer) perms also write
o1/o2. Comparing (0,1,2) is safe -- unwritten targets read back as 0 in both.

useNdf is forced OFF because specular-AA depends on real screen-space
derivatives, which a single-invocation interpreter can't reproduce.

Run from the repo root::

    python tools/shader_diff_crystal_ps.py                 # full 512-perm sweep
    python tools/shader_diff_crystal_ps.py --perms 1,384   # specific perms
    python tools/shader_diff_crystal_ps.py --trials 60

Expected (June-2026 fixes -- fog-under-debug, albedo-override-vs-refraction,
debug modes 5-8, ported shadow-cascade path): all 512 perms MATCH, worst ~1e-5.
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
RETAIL_DIR = REPO / "re_shaders" / "crystal"
SLANG_DIR  = REPO / "slang_out" / "d3d11" / "crystal_ps"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 512


# --- per-semantic inputs (Wc3 crystal varying conventions) ----------------
# Build a CONCRETE dict per trial so every ``.get(key)`` is deterministic
# regardless of which order each shader queries its semantics -- feeding the two
# shaders even slightly different values per semantic produces phantom diffs.

def _unit(rng):
    v = [rng.uniform(-1, 1) for _ in range(3)]
    m = math.sqrt(sum(c * c for c in v)) or 1.0
    return [c / m for c in v]

def crystal_inputs(seed):
    r = random.Random(9000 + seed)
    n = _unit(r); t = _unit(r)
    return {
        ("COLOR", 0):    [f2b(r.uniform(0, 1)) for _ in range(4)],            # vertColor
        ("TEXCOORD", 0): [f2b(r.uniform(-2, 2)) for _ in range(4)],           # uv
        # viewVec.xyz + depth.w ; v3.w<0 => discard, so span both signs
        ("TEXCOORD", 1): [f2b(r.uniform(-20, 20)) for _ in range(3)]
                         + [f2b(r.uniform(-5, 5))],
        ("TEXCOORD", 2): [f2b(n[0]), f2b(n[1]), f2b(n[2]), f2b(0.0)],         # normalWS (unit)
        ("TEXCOORD", 3): [f2b(t[0]), f2b(t[1]), f2b(t[2]),
                          f2b(r.choice([-1.0, 1.0]))],                        # tangentWS + handedness
    }


# --- constant buffers with DRIVEN discriminants ---------------------------
# Same HD-family layout as hd_ps: cb1[0].x cascade count, cb2[20].z light count,
# cb2[20].w useNdf, cb3[0].y debug mode, cb2[19].xy probe extents (probe bound
# iff product != 0), per-light block cb2[21+4i]=ambient / [+22]=diffuse /
# [+23]=position (.w==0 => directional).

def crystal_cbufs(seed):
    rng = random.Random(seed * 13 + 7)
    lights = rng.randint(0, 8)
    cascades = rng.randint(0, 3)
    dbg = rng.randint(0, 8)
    first_dir = rng.random() < 0.5
    probe = rng.random() < 0.6
    light_types = rng.getrandbits(8)

    def rows(n):
        return [[f2b(rng.uniform(-1, 1)) for _ in range(4)] for _ in range(n)]
    cb1 = rows(4); cb2 = rows(60); cb3 = rows(4)

    cb1[0][0] = i2b(cascades)                # cb1[0].x cascade count (ilt)
    cb3[0][1] = i2b(dbg)                      # cb3[0].y debug mode
    cb2[20][2] = i2b(lights)                  # cb2[20].z light count (ult/switch)
    cb2[20][3] = f2b(0.0)                     # useNdf OFF (specular-AA unmatchable)
    cb2[16][0] = f2b(rng.uniform(0, 1))
    cb2[16][1] = f2b(rng.uniform(0, 1))
    cb2[19][2] = f2b(rng.uniform(0, 1))
    # IBL probe bound iff probe -> non-zero extents at cb2[19].xy
    cb2[19][0] = f2b(rng.uniform(0.1, 3) if probe else 0.0)
    cb2[19][1] = f2b(rng.uniform(0.1, 3) if probe else 0.0)
    # per-light position.w: 0 == directional, >0 == point
    for i in range(8):
        directional = (i == 0 and first_dir) or (i > 0 and (light_types >> i) & 1)
        cb2[23 + i * 4][3] = f2b(0.0 if directional else rng.uniform(0.2, 3.0))
    return {1: cb1, 2: cb2, 3: cb3}


def crystal_sysvals(seed):
    return {'is_front_face': 0xFFFFFFFF if (seed & 1) else 0}


# --- perm feature label (hd-family 9-bit encoding; MRT is the low bit) -----

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


# --- driver ---------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=150)
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
        res = compare(prog_s, prog_r, trials=args.trials, output_regs=(0, 1, 2),
                      tol=args.tol, inputs_fn=crystal_inputs, cbufs_fn=crystal_cbufs,
                      sysvals_fn=crystal_sysvals)
        worst_all = max(worst_all, res.worst)
        dm_total += res.discard_mismatches
        if res.worst > args.tol or res.discard_mismatches:
            diverging.append((idx, res.worst, res.discard_mismatches))
            print(f"  DIVERGE perm_{idx} {feat(idx)}: worst={res.worst:.3e} "
                  f"dm={res.discard_mismatches} (seed {res.worst_seed})")
        if idx % 64 == 0:
            print(f"  ...perm {idx} (running worst {worst_all:.1e})", file=sys.stderr)

    print(f"\n=== crystal_ps: {len(perms)} perms x {args.trials} trials ===")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"discard mismatch : {dm_total}")
    print(f"perms diverging  : {len(diverging)}")
    print("ALL MATCH" if not diverging else f"DIVERGING: {[d[0] for d in diverging]}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
