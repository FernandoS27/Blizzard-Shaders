"""Differential test of the slang ``popcorn_ps`` family against retail bytecode.

A worked example of :mod:`shader_diff` for a non-trivial shader: it shows how to
(a) generate structured per-semantic inputs and (b) *drive* the constant-buffer
discriminants that select the shader's branches, instead of trusting random
floats to ever hit them exactly. The single most important lesson from building
this set: random CB floats never make ``lights[0].position.w == 0.0`` (the
directional-first-light branch) or ``probeBound != 0`` land — you must set those
discriminants explicitly or whole code paths go untested and bugs hide.

It sweeps all 1152 perms (retail ``perm_NNNN.asm`` vs the slang ``perm_NNN.dxbc``
under ``slang_out``) and compares RT0/RT1/RT2. Run from the repo root::

    python tools/shader_diff_popcorn.py                 # full sweep
    python tools/shader_diff_popcorn.py --perms 192,896 # specific perms
    python tools/shader_diff_popcorn.py --trials 50

Expected result after the June-2026 fixes (diffMax IBL scale, LIT g-buffer
normal, motion vc.w premultiply): all 1152 perms MATCH, worst ~1e-3 (texture /
fp residual). useNdf is forced off because specular-AA depends on real
screen-space derivatives, which a single-invocation interpreter can't reproduce.
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
RETAIL_DIR = REPO / "re_shaders" / "popcornfx" / "popcornfx"
SLANG_DIR  = REPO / "slang_out" / "d3d11" / "popcorn_ps"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 1152


# --- per-semantic inputs (Wc3 popcorn varying conventions) ----------------
# Build a CONCRETE dict once per trial so every ``.get(key)`` is deterministic
# regardless of the order each shader queries its semantics in — feeding the two
# shaders even slightly different values per semantic produces phantom diffs.

def _unit(rng):
    v = [rng.uniform(-1, 1) for _ in range(3)]
    m = math.sqrt(sum(c * c for c in v)) or 1.0
    return [c / m for c in v]

def popcorn_inputs(seed):
    r = random.Random(9000 + seed)
    n = _unit(r); t = _unit(r)
    return {
        ("COLOR", 0):    [f2b(r.uniform(0, 1)) for _ in range(4)],            # vertColor
        ("TEXCOORD", 0): [f2b(r.uniform(-2, 2)) for _ in range(4)],           # uv
        ("TEXCOORD", 1): [f2b(r.uniform(-2, 2)) for _ in range(4)],           # slot1
        ("TEXCOORD", 2): [f2b(r.uniform(-2, 2)) for _ in range(4)],           # uvAxis
        ("TEXCOORD", 3): [f2b(r.uniform(0, 1)) for _ in range(4)],            # random stream
        ("TEXCOORD", 4): [f2b(n[0]), f2b(n[1]), f2b(n[2]), f2b(0.0)],         # normalWS
        ("TEXCOORD", 5): [f2b(t[0]), f2b(t[1]), f2b(t[2]),
                          f2b(r.choice([-1.0, 1.0]))],                        # tangentWS
        ("TEXCOORD", 7): [f2b(r.uniform(-20, 20)) for _ in range(3)]
                         + [f2b(r.uniform(-5, 5))],                           # worldPos
    }


# --- constant buffers with DRIVEN discriminants ---------------------------

def popcorn_cbufs(seed):
    """cb2/cb3 with light count, first-light direction, IBL probe and per-light
    type explicitly driven (random floats never hit these exact values)."""
    rng = random.Random(seed * 13 + 7)
    lights = rng.randint(0, 8)
    first_dir = rng.random() < 0.5
    probe = rng.random() < 0.6
    light_types = rng.getrandbits(8)

    def rows(n):
        return [[f2b(rng.uniform(-1, 1)) for _ in range(4)] for _ in range(n)]
    cb2 = rows(60); cb3 = rows(4)

    cb2[20][2] = i2b(lights)                 # light count
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
    return {2: cb2, 3: cb3}


def popcorn_sysvals(seed):
    return {'is_front_face': 0xFFFFFFFF if (seed & 1) else 0}


# --- perm feature label (for readable divergence reports) -----------------

def feat(idx):
    inner = idx & 0x7F; outer = idx // 128; mode = outer // 3; uv = outer % 3
    bits = [(0x40, "LIT"), (0x20, "VC"), (0x10, "ALUT"),
            (0x08, "SOFT"), (0x06, "FOG"), (0x01, "GBUF")]
    f = [n for m, n in bits if inner & m]
    f.append(["NoUV", "Color", "Motion"][uv] + "-" + ["Basic", "BB", "Atlas"][mode])
    return "+".join(f)


# --- driver ---------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=150)
    ap.add_argument('--tol', type=float, default=1e-2)
    ap.add_argument('--perms', default=None,
                    help='comma-separated perm indices (default: all 1152)')
    ap.add_argument('--retail-dir', default=str(RETAIL_DIR))
    ap.add_argument('--slang-dir', default=str(SLANG_DIR))
    ap.add_argument('--decompiler', default=str(DECOMPILER))
    args = ap.parse_args(argv)

    perms = ([int(x) for x in args.perms.split(',')] if args.perms
             else range(NPERMS))
    retail = Path(args.retail_dir); slang = Path(args.slang_dir)

    worst_all = 0.0; diverging = []; dm_total = 0
    for idx in perms:
        prog_r = load(retail / f"perm_{idx:04d}.asm")
        prog_s = load(slang / f"perm_{idx:03d}.dxbc", decompiler=args.decompiler)
        res = compare(prog_s, prog_r, trials=args.trials, output_regs=(0, 1, 2),
                      tol=args.tol, inputs_fn=popcorn_inputs, cbufs_fn=popcorn_cbufs,
                      sysvals_fn=popcorn_sysvals)
        worst_all = max(worst_all, res.worst)
        dm_total += res.discard_mismatches
        if res.worst > args.tol or res.discard_mismatches:
            diverging.append((idx, res.worst, res.discard_mismatches))
            print(f"  DIVERGE perm_{idx} {feat(idx)}: worst={res.worst:.3e} "
                  f"dm={res.discard_mismatches} (seed {res.worst_seed})")
        if idx % 128 == 0:
            print(f"  ...perm {idx} (running worst {worst_all:.1e})", file=sys.stderr)

    n = len(list(perms)) if not isinstance(perms, range) else len(perms)
    print(f"\n=== popcorn_ps: {n} perms x {args.trials} trials ===")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"discard mismatch : {dm_total}")
    print(f"perms diverging  : {len(diverging)}")
    print("ALL MATCH" if not diverging else f"DIVERGING: {[d[0] for d in diverging]}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
