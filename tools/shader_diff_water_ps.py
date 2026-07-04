"""Differential test of the slang ``water_ps`` family against retail bytecode.

A worked example of :mod:`shader_diff` for the Warcraft-III Reforged water
PIXEL shader (4 permutations; the only axis is fog mode:
perm_000 none, perm_001 linear, perm_002 exponential, perm_003 exp^2). All four
share one input/output signature (v0..v5 in, SV_Target0 out) and differ only in
a smooth fog tail, so the same driver covers every perm.

Like ``tools/shader_diff_popcorn.py`` it (a) builds structured per-semantic
inputs and (b) *drives* the constant-buffer discriminants that select branches,
because random CB floats never land on the exact values those branches test:

  * cb2[20].z  light count (int) -> the dynamic light loop bound + ``lightCount>0``
               gates. Undriven garbage would blow the loop cap.
  * cb2[20].w  useNdf flag -> FORCED 0.0. useNdf selects a specular-AA roughness
               computed from ``deriv_rtx/rty`` gradients, which a single-pixel
               interpreter cannot reproduce (see dxbc_interp docstring).
  * cb2[23].w  first light position.w -> ``==0`` directional-first-light gate.
  * cb2[19].x*cb2[19].y  IBL probe extents -> ``!=0`` probe-bound gate.
  * cb2[r*4+23] light array (stride-4 rows from 23): position(.xyz,+.w type),
               colour at rows 21/22 + 4i -- same layout as hd_ps / popcorn_ps.

Inputs:
  SV_Position  screen pixel coord (divided by t0 dims -> [0,1] refraction UV)
  COLOR0       vertColor / opacity in .w
  TEXCOORD0    normal-map scroll UV
  TEXCOORD1    view/world position (.xyz), depth in .z path
  TEXCOORD3    tangent-frame vector
  TEXCOORD4    tangent-frame vector (.w handedness)

Run from the repo root::

    python tools/shader_diff_water_ps.py                    # full 4-perm sweep
    python tools/shader_diff_water_ps.py --perms 0,2        # specific perms
    python tools/shader_diff_water_ps.py --trials 100

Goal tolerance ~1e-2 (texture / fp residual). useNdf is forced off because
specular-AA depends on real screen-space derivatives.
"""

import argparse
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import Program, TextureModel, f2b, i2b   # noqa: E402
from shader_diff import load as _load, compare, decompile # noqa: E402


# --- `continue` support (driver-side, without touching dxbc_interp) --------
# The slang SSR loop emits a `continue` as the last statement of an
# `if_nz r6.y { <increment>; continue }` block at the top of the loop body.
# dxbc_interp doesn't model `continue`, so we rewrite the AST after parsing:
# within a loop body, when an `if` then-branch ends in `continue`, that node's
# else-branch absorbs every following sibling and the `continue` is dropped.
# Semantically identical: `continue` skips the rest of this iteration, i.e. the
# trailing body runs only when the condition is FALSE (the new else-branch).
# The retail shader spells the same logic with explicit if/else, so this
# transform makes the two directly comparable rather than papering over a diff.

def _is_continue(node):
    return node[0] == 'op' and node[1] == 'continue'


def _rewrite_continue(nodes, in_loop=False):
    out = []
    i = 0
    while i < len(nodes):
        n = nodes[i]
        if n[0] == 'loop':
            out.append(('loop', _rewrite_continue(n[1], in_loop=True)))
            i += 1
            continue
        if n[0] == 'if':
            _, want_nz, cond, then_n, else_n = n
            then_r = _rewrite_continue(then_n, in_loop)
            else_r = _rewrite_continue(else_n, in_loop)
            # `continue` as the last statement of a then-branch at loop-body
            # level: fold the trailing loop-body siblings into the else-branch.
            if in_loop and then_r and _is_continue(then_r[-1]) and not else_r:
                then_r = then_r[:-1]
                tail = _rewrite_continue(nodes[i + 1:], in_loop)
                out.append(('if', want_nz, cond, then_r, tail))
                return out
            out.append(('if', want_nz, cond, then_r, else_r))
            i += 1
            continue
        if n[0] == 'switch':
            _, sel, cases = n
            out.append(('switch', sel,
                        [(v, _rewrite_continue(b, in_loop)) for v, b in cases]))
            i += 1
            continue
        if _is_continue(n):
            # bare `continue` (not the folded top-of-body form): drop it; the
            # remaining body would be unreachable this iteration, so re-loop.
            i += 1
            continue
        out.append(n)
        i += 1
    return out


def load(path, decompiler=None):
    prog = _load(path, decompiler=decompiler)
    prog.ast = _rewrite_continue(prog.ast)
    return prog

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "re_shaders" / "water"
SLANG_DIR  = REPO / "slang_out" / "d3d11" / "water_ps"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 4

FOG = {0: "no-fog", 1: "FogLinear", 2: "FogExp", 3: "FogExp2"}


# --- per-semantic inputs (Wc3 water varying conventions) ------------------

def _unit(rng):
    v = [rng.uniform(-1, 1) for _ in range(3)]
    m = math.sqrt(sum(c * c for c in v)) or 1.0
    return [c / m for c in v]


def water_inputs(seed):
    r = random.Random(9000 + seed)
    t3 = _unit(r); t4 = _unit(r)
    return {
        # SV_Position: screen pixel coord (shader does v0.xy / textureDims).
        ("SV_Position", 0): [f2b(r.uniform(0, 1024)), f2b(r.uniform(0, 1024)),
                             f2b(r.uniform(0, 1)), f2b(1.0)],
        ("COLOR", 0):    [f2b(r.uniform(0, 1)) for _ in range(4)],            # vertColor / opacity
        ("TEXCOORD", 0): [f2b(r.uniform(-2, 2)) for _ in range(4)],           # normal-map scroll UV
        ("TEXCOORD", 1): [f2b(r.uniform(-20, 20)) for _ in range(3)]
                         + [f2b(r.uniform(0, 1))],                            # view/world pos (+depth-ish .w)
        ("TEXCOORD", 3): [f2b(t3[0]), f2b(t3[1]), f2b(t3[2]), f2b(0.0)],      # tangent-frame vec
        ("TEXCOORD", 4): [f2b(t4[0]), f2b(t4[1]), f2b(t4[2]),
                          f2b(r.choice([-1.0, 1.0]))],                        # tangent-frame vec + handedness
    }


# --- constant buffer cb2 with DRIVEN discriminants ------------------------

def water_cbufs(seed):
    """cb2 (size 52) with the branch discriminants driven explicitly."""
    rng = random.Random(seed * 13 + 7)
    lights = rng.randint(0, 7)                 # keep 23+4*(lights-1) < 52
    first_dir = rng.random() < 0.5
    probe = rng.random() < 0.6
    light_types = rng.getrandbits(8)

    cb2 = [[f2b(rng.uniform(-1, 1)) for _ in range(4)] for _ in range(52)]

    cb2[20][2] = i2b(lights)                   # light count (loop bound + gates)
    cb2[20][3] = f2b(0.0)                       # useNdf OFF (specular-AA unmatchable)

    # IBL probe bound iff cb2[19].x * cb2[19].y != 0
    cb2[19][0] = f2b(rng.uniform(0.1, 3) if probe else 0.0)
    cb2[19][1] = f2b(rng.uniform(0.1, 3) if probe else 0.0)
    cb2[19][2] = f2b(rng.uniform(0, 1))        # IBL blend factor

    # per-light position.w: 0 == directional, >0 == point (cb2[23+4i].w)
    for i in range(8):
        row = 23 + i * 4
        if row >= 52:
            break
        directional = (i == 0 and first_dir) or (i > 0 and (light_types >> i) & 1)
        cb2[row][3] = f2b(0.0 if directional else rng.uniform(0.2, 3.0))

    return {2: cb2}


def water_sysvals(seed):
    return {'is_front_face': 0xFFFFFFFF if (seed & 1) else 0}


def output_regs_for(prog):
    regs = sorted({reg for name, _, _, reg in prog.output_sig
                   if name.upper() == "SV_TARGET"})
    return tuple(regs) if regs else (0,)


# --- constant-texture model (for the divergence-isolation --const-tex mode) --

class _ConstTex(TextureModel):
    """Per-slot constant texel: isolates real arithmetic divergences from
    texture-coordinate sensitivity (both shaders read the same constant)."""
    def sample(self, slot, coords):
        v = 0.3 + 0.05 * slot
        return [v, v, v, v]

    def sample_lod(self, slot, coords, lod):
        return self.sample(slot, coords)

    def sample_compare(self, slot, coords, ref):
        return self.sample(slot, coords)[0]


# --- driver ---------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=100)
    ap.add_argument('--tol', type=float, default=1e-2)
    ap.add_argument('--perms', default=None,
                    help='comma-separated perm indices (default: all 4)')
    ap.add_argument('--smooth-tex', action='store_true',
                    help='use the spatially-varying texture model instead of the default '
                         'per-slot constant one. The SSR ray-march samples the scene/depth '
                         'buffers at coords the two shaders compute with different fp '
                         'reassociation, so smooth textures leave a coord-sensitivity residual '
                         '(like the dof bokeh loop) even though the arithmetic is bit-identical.')
    ap.add_argument('--retail-dir', default=str(RETAIL_DIR))
    ap.add_argument('--slang-dir', default=str(SLANG_DIR))
    ap.add_argument('--decompiler', default=str(DECOMPILER))
    args = ap.parse_args(argv)

    perms = ([int(x) for x in args.perms.split(',')] if args.perms
             else list(range(NPERMS)))
    retail = Path(args.retail_dir); slang = Path(args.slang_dir)
    tex = None if args.smooth_tex else _ConstTex()

    worst_all = 0.0; diverging = []; dm_total = 0
    for idx in perms:
        prog_r = load(retail / f"perm_{idx:03d}.asm")
        prog_s = load(slang / f"perm_{idx:03d}.dxbc", decompiler=args.decompiler)
        oregs = output_regs_for(prog_r)
        res = compare(prog_s, prog_r, trials=args.trials, output_regs=oregs,
                      tol=args.tol, inputs_fn=water_inputs, cbufs_fn=water_cbufs,
                      sysvals_fn=water_sysvals, texture=tex)
        worst_all = max(worst_all, res.worst)
        dm_total += res.discard_mismatches
        if res.worst > args.tol or res.discard_mismatches:
            diverging.append((idx, res.worst, res.discard_mismatches))
            print(f"  DIVERGE perm_{idx:03d} {FOG[idx]}: worst={res.worst:.3e} "
                  f"dm={res.discard_mismatches} regs={list(oregs)} "
                  f"(seed {res.worst_seed} at {res.worst_where})")

    label = "smooth-tex" if args.smooth_tex else "const-tex"
    print(f"\n=== water_ps: {len(perms)} perms x {args.trials} trials [{label}] ===")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"discard mismatch : {dm_total}")
    print(f"perms diverging  : {len(diverging)}")
    print("ALL MATCH" if not diverging else f"DIVERGING: {[d[0] for d in diverging]}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
