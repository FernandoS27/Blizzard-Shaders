"""Differential test of the slang full-screen post-process families vs retail.

These are screen-space passes (a full-screen triangle: ``SV_POSITION`` +
``TEXCOORD0``, sample one or more source textures, write RT0). They share enough
structure to live in one config-driven driver rather than a file each:

    bloomcombine  bloomextract  gaussianblur  distortion_ps  tonemap_ps  depthoffield

Most just work on default random inputs + constant buffers (both shaders read
the same values). ``depthoffield`` is the exception: it runs a bokeh blur *loop*
whose tap count and radius come from cb1, so it needs those driven to sane
values (garbage random cb1 makes the loop iterate wildly and amplifies fp
noise) — see ``_dof_cbufs``.

    python tools/shader_diff_postfx.py
    python tools/shader_diff_postfx.py --only depthoffield --trials 100
"""

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import f2b, TextureModel                 # noqa: E402
from shader_diff import load, compare                     # noqa: E402


class _ConstTexture(TextureModel):
    """Per-slot constant texel (coord-independent).

    A bokeh/blur pass sums many samples taken at coords the two shaders compute
    with different fp reassociation; under a spatially-varying texture model
    those tiny coord deltas turn into visible per-sample differences that the
    sum amplifies. A constant texture removes the coord dependence so the
    *arithmetic* (blur weights, focal math, accumulation) is checked exactly —
    the sample coords are verified structurally by the shared sample opcodes.
    """
    def sample(self, slot, coords):
        return [0.3 + 0.13 * slot, 0.5, 0.7, 0.4]
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


def _dof_cbufs(seed):
    """Depth-of-field blur params. The loop does `r1.w += cb1[1].y/r1.w` while
    `r1.w < cb1[1].x` starting at cb1[1].y, so keep cb1[1].x small (~3) and
    cb1[1].y ~1 for a handful of taps; small texel size keeps sample coords
    clustered so the smooth texture model stays well-conditioned."""
    rng = random.Random(seed * 5 + 1)
    cb1 = [[f2b(rng.uniform(-1, 1)) for _ in range(4)] for _ in range(8)]
    cb1[0] = [f2b(rng.uniform(-1, 1)), f2b(rng.uniform(-1, 1)), f2b(1 / 1024), f2b(1 / 1024)]
    cb1[1] = [f2b(3.0), f2b(1.0), f2b(rng.uniform(2, 10)), f2b(rng.uniform(0.5, 2))]
    cb1[2] = [f2b(rng.uniform(-1, 1)) for _ in range(3)] + [f2b(rng.choice([0.0, 1.0]))]
    return {1: cb1}


# family -> (retail subdir, slang subdir, nperms, output_regs, inputs_fn, cbufs_fn, texture)
FAMILIES = {
    "bloomcombine":  ("bloomcombine", "bloomcombine",  2, (0,), _fullscreen_inputs, None, None),
    "bloomextract":  ("bloomextract", "bloomextract",  1, (0,), _fullscreen_inputs, None, None),
    "gaussianblur":  ("gaussianblur", "gaussianblur",  1, (0,), _fullscreen_inputs, None, None),
    "distortion_ps": ("distortion",   "distortion_ps", 1, (0,), _fullscreen_inputs, None, None),
    "tonemap_ps":    ("tonemap",      "tonemap_ps",    1, (0,), _fullscreen_inputs, None, None),
    # depthoffield: a bokeh blur loop -> constant textures (see _ConstTexture).
    "depthoffield":  ("depthoffield", "depthoffield",  1, (0,), _fullscreen_inputs, _dof_cbufs,
                      _ConstTexture()),
}


def run_family(name, cfg, trials, tol):
    retail_sub, slang_sub, nperms, out_regs, inputs_fn, cbufs_fn, texture = cfg
    retail = REPO / "re_shaders" / retail_sub
    slang = SLANG / slang_sub
    worst = 0.0; diverging = []
    for idx in range(nperms):
        prog_r = load(retail / f"perm_{idx:03d}.asm")
        prog_s = load(slang / f"perm_{idx:03d}.dxbc", decompiler=DECOMPILER)
        res = compare(prog_s, prog_r, trials=trials, output_regs=out_regs, tol=tol,
                      inputs_fn=inputs_fn, cbufs_fn=cbufs_fn, sysvals_fn=(lambda s: {}),
                      texture=texture)
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
    args = ap.parse_args(argv)

    only = set(args.only.split(',')) if args.only else None
    print("=== post-process families ===")
    all_ok = True
    for name, cfg in FAMILIES.items():
        if only and name not in only:
            continue
        all_ok &= run_family(name, cfg, args.trials, args.tol)
    print("ALL MATCH" if all_ok else "SOME DIVERGE")
    return 0 if all_ok else 1


if __name__ == '__main__':
    sys.exit(main())
