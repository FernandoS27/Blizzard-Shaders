"""Differential test of the slang full-screen post-process families vs retail.

These are screen-space passes (a full-screen triangle: ``SV_POSITION`` +
``TEXCOORD0``, sample one or more source textures, write RT0). They share enough
structure to live in one config-driven driver rather than a file each:

    bloomcombine  bloomextract  gaussianblur  distortion_ps  tonemap_ps  depthoffield

Most just work on default random inputs + constant buffers (both shaders read
the same values). ``depthoffield`` is the exception: it runs a bokeh blur *loop*
whose tap count and radius come from cb3, so it needs those driven to sane
values (garbage random cb3 makes the loop iterate wildly and amplifies fp
noise) — see ``_dof_cbufs`` and ``_CellTexture``.

Every per-draw buffer here sits on **bank 3** in 3.0.0 (bank 1 in 2.0.0; the
instruction streams are otherwise identical), and every driver builds bank 3
only, so pointing the gate at ``--retail-dir re_shaders_old`` reports each moved
family as reading a bank the driver does not build. ``distortion_ps`` reads no
constant buffer and matches both trees.

    python tools/shader_diff_postfx.py
    python tools/shader_diff_postfx.py --only depthoffield --trials 100
"""

import argparse
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import b2f, f2b, TextureModel                # noqa: E402
from shader_diff import load, compare, perm_path                     # noqa: E402


class _CellTexture(TextureModel):
    """Piecewise-constant texture: one random texel per half-pixel cell.

    This driver used to hand the gather a per-slot CONSTANT texel, to keep the
    two compilers' fp reassociation of the tap coordinates out of the sum. That
    removed nearly everything the gate could see. When every tap returns
    the same colour, Gustafsson's `lerp(accum / count, sample, weight)` returns
    that colour whatever the weight is -- so the CoC, the far-field clamp, the
    bleed guard, the golden angle, the sky sentinel and the disc edge were all
    unobservable (five of five such mutations missed in P8's G7b sweep).

    Hashing the texel on the integer CELL of the coordinate keeps the texture
    spatially varying, but insensitive to the ~1e-8 coordinate differences two
    compilers' reassociation produces: those only matter on a cell boundary,
    which a tap hits with probability ~ 1e-5 at 2048 cells per UV unit.

    Slot 1 is the depth buffer (read as `.x`): 15% of cells are sky (0.0, which
    the shader replaces with its far sentinel), the rest span both sides of the
    focus distances `_dof_cbufs` draws, so near-, in- and far-field taps all
    occur and `centerDepth < sampleDepth` goes both ways.
    """
    CELLS = 2048

    def sample(self, slot, coords):
        iu = math.floor(coords[0] * self.CELLS)
        iv = math.floor(coords[1] * self.CELLS)
        rng = random.Random(f"{slot}:{iu}:{iv}")
        if slot == 1:
            depth = 0.0 if rng.random() < 0.15 else rng.uniform(0.5, 20.0)
            return [depth, depth, depth, 1.0]
        return [rng.uniform(0.05, 0.95) for _ in range(4)]

    def sample_lod(self, slot, coords, lod):
        return self.sample(slot, coords)

REPO = Path(__file__).resolve().parent.parent
SLANG = REPO / "slang_out" / "d3d11"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")


def _fullscreen_inputs(seed):
    """A full-screen-quad fragment: screen position + a [0,1] source UV."""
    r = random.Random(300 + seed)
    return {
        ("SV_POSITION", 0): [f2b(r.uniform(0, 1024)), f2b(r.uniform(0, 1024)),
                             f2b(r.uniform(0, 1)), f2b(1.0)],
        ("TEXCOORD", 0): [f2b(r.uniform(0.05, 0.95)) for _ in range(4)],
    }


# 3.0.0 moved every per-draw buffer below from bank 1 to bank 3 and changed
# nothing else (2.0.0 read `cb1[...]`, 3.0.0 reads `cb3[...]`, the instruction
# streams are otherwise identical). The drivers therefore build bank 3 ONLY. A
# driver that also built bank 1 would let a shader still reading b1 compare its
# random garbage against retail's driven values and fail by luck; one that built
# only bank 1 (as `_dof_cbufs` did before the move) makes the 3.0.0 retail leg
# raise `KeyError: 3`. Keep the bank explicit so a wrong bank is a loud error.
POSTFX_BANK = 3


def _rows(rng, n, lo=-1.0, hi=1.0):
    return [[f2b(rng.uniform(lo, hi)) for _ in range(4)] for _ in range(n)]


def _tonemap_cbufs(seed):
    """cb3[0].x = exposure: sometimes 0, mostly a sane gain, and one trial in
    three a large one. The last regime is not decoration -- the ACES fit only
    exceeds 1.0 above an input of ~7.24, the texture model's texels stop at
    0.9, and without it the final `saturate` was unobservable (P8 G7b)."""
    rng = random.Random(seed * 7 + 3)
    cb = _rows(rng, 1)
    if seed % 9 == 0:
        exposure = 0.0
    elif seed % 3 == 1:
        exposure = rng.uniform(10.0, 40.0)
    else:
        exposure = rng.uniform(0.05, 4.0)
    cb[0][0] = f2b(exposure)
    return {POSTFX_BANK: cb}


def _bloomextract_cbufs(seed):
    """cb3[0].x = luminance cutoff, spread across the texel range [0.1, 0.9]
    so the `lum > threshold` select takes both arms."""
    rng = random.Random(seed * 7 + 5)
    cb = _rows(rng, 1)
    cb[0][0] = f2b(rng.uniform(-0.1, 1.0))
    return {POSTFX_BANK: cb}


def _bloomcombine_cbufs(seed):
    """cb3[0].zw = layer intensities, cb3[1].xy = layer saturations."""
    rng = random.Random(seed * 7 + 11)
    cb = _rows(rng, 2)
    cb[0][2], cb[0][3] = f2b(rng.uniform(0, 2)), f2b(rng.uniform(0, 2))
    cb[1][0], cb[1][1] = f2b(rng.uniform(0, 2)), f2b(rng.uniform(0, 2))
    return {POSTFX_BANK: cb}


def _gaussian_cbufs(seed):
    """Up to 15 taps: [i].xy UV offset, [i].z weight, [0].w the tap COUNT.

    The count is read once as `ftoi cb3[0].w`. The default random rows put it
    in (-1, 1), which truncates to 0 -- so before this driver existed the loop
    ran ZERO taps on every trial and the gate compared (0,0,0,0) with
    (0,0,0,0). One trial in eight still uses 0 taps (and one a negative count)
    to keep the empty-loop path covered; the rest run 1..15.
    """
    rng = random.Random(seed * 7 + 13)
    cb = [[f2b(rng.uniform(-0.02, 0.02)), f2b(rng.uniform(-0.02, 0.02)),
           f2b(rng.uniform(0.0, 0.3)), f2b(rng.uniform(-1, 1))] for _ in range(15)]
    count = {0: 0.0, 1: -2.0}.get(seed % 8, float(rng.randint(1, 15)) + rng.uniform(0, 0.99))
    cb[0][3] = f2b(count)
    return {POSTFX_BANK: cb}


def _dof_cbufs(seed):
    """Depth-of-field blur params. The loop does `r1.w += cb3[1].y/r1.w` while
    `r1.w < cb3[1].x` starting at cb3[1].y, so keep cb3[1].x small and
    cb3[1].y ~1 for a bounded number of taps."""
    rng = random.Random(seed * 5 + 1)
    cb = [[f2b(rng.uniform(-1, 1)) for _ in range(4)] for _ in range(8)]
    cb[0] = [f2b(rng.uniform(-1, 1)), f2b(rng.uniform(-1, 1)), f2b(1 / 1024), f2b(1 / 1024)]
    # maxBlurSize 2..6 px (the loop bound) and radiusScale ~1 keep the gather
    # at 2..30 taps; focus distance 2..10 sits inside _CellTexture's depths.
    focus = rng.uniform(2, 10)
    # The bleed guard (`min(size, 2 * |centreCoc| * maxBlur)` for taps BEHIND
    # the centre) and the far-field `max(0.01, coc)` only act when the CENTRE
    # pixel is near focus -- a regime independent draws reach about once in
    # a thousand trials (both mutations missed at 80, caught at 1500). So on
    # two trials in three the focus distance is derived from the centre
    # pixel's own depth, read through the same fragment position and texture
    # model the shaders will use.
    if seed % 3 != 0:
        pos = _fullscreen_inputs(seed)[("SV_POSITION", 0)]
        centre = _CellTexture().sample(1, [b2f(pos[0]) / 1024, b2f(pos[1]) / 1024])[0]
        if centre > 0.0:
            focus = centre * rng.uniform(0.8, 1.25)
    cb[1] = [f2b(rng.uniform(2.0, 6.0)), f2b(rng.uniform(0.8, 1.2)),
             f2b(focus), f2b(rng.uniform(0.5, 2))]
    cb[2] = [f2b(rng.uniform(-1, 1)) for _ in range(3)] + [f2b(rng.choice([0.0, 1.0]))]
    return {POSTFX_BANK: cb}


# family -> (retail subdir, slang subdir, nperms, output_regs, inputs_fn, cbufs_fn, texture)
FAMILIES = {
    "bloomcombine":  ("bloomcombine", "bloomcombine",  2, (0,), _fullscreen_inputs,
                      _bloomcombine_cbufs, None),
    "bloomextract":  ("bloomextract", "bloomextract",  1, (0,), _fullscreen_inputs,
                      _bloomextract_cbufs, None),
    "gaussianblur":  ("gaussianblur", "gaussianblur",  1, (0,), _fullscreen_inputs,
                      _gaussian_cbufs, None),
    # distortion reads no constant buffer in either version; default rows.
    "distortion_ps": ("distortion",   "distortion_ps", 1, (0,), _fullscreen_inputs, None, None),
    "tonemap_ps":    ("tonemap",      "tonemap_ps",    1, (0,), _fullscreen_inputs,
                      _tonemap_cbufs, None),
    # depthoffield: a bokeh gather -> piecewise-constant textures (see _CellTexture).
    "depthoffield":  ("depthoffield", "depthoffield",  1, (0,), _fullscreen_inputs, _dof_cbufs,
                      _CellTexture()),
}


def run_family(name, cfg, trials, tol, retail_root=None):
    retail_sub, slang_sub, nperms, out_regs, inputs_fn, cbufs_fn, texture = cfg
    retail = Path(retail_root or (REPO / "wc3_re_shaders")) / retail_sub
    slang = SLANG / slang_sub
    worst = 0.0; diverging = []
    for idx in range(nperms):
        prog_r = load(perm_path(retail, idx, "asm"))
        prog_s = load(perm_path(slang, idx, "dxbc"), decompiler=DECOMPILER)
        try:
            res = compare(prog_s, prog_r, trials=trials, output_regs=out_regs, tol=tol,
                          inputs_fn=inputs_fn, cbufs_fn=cbufs_fn,
                          sysvals_fn=(lambda s: {}), texture=texture)
        except KeyError as exc:
            # One leg reads a constant-buffer bank the driver never built --
            # e.g. the 2.0.0 tree's b1 against the 3.0.0 drivers' bank 3.
            diverging.append((idx, f"reads cb bank {exc.args[0]} the driver does not build"))
            continue
        worst = max(worst, res.worst)
        if res.worst > tol or res.discard_mismatches:
            diverging.append((idx, res.worst))
    ok = not diverging
    print(f"  {name:<14} {nperms} perm(s): worst={worst:.3e}  "
          + ("MATCH" if ok else f"DIVERGE {diverging}"))
    return ok


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=80)
    ap.add_argument('--tol', type=float, default=1e-3)
    ap.add_argument('--only', default=None, help='comma-separated family names')
    ap.add_argument('--retail-dir', default=None,
                    help='root holding the retail family folders '
                         '(default wc3_re_shaders/ — pass re_shaders_old/ for 2.0.0)')
    args = ap.parse_args(argv)

    only = set(args.only.split(',')) if args.only else None
    print("=== post-process families ===")
    all_ok = True
    for name, cfg in FAMILIES.items():
        if only and name not in only:
            continue
        all_ok &= run_family(name, cfg, args.trials, args.tol, args.retail_dir)
    print("ALL MATCH" if all_ok else "SOME DIVERGE")
    return 0 if all_ok else 1


if __name__ == '__main__':
    sys.exit(main())
