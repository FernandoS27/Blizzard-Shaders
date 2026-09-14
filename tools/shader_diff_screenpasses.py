"""Differential test of the small 3.0.0 screen / world passes vs retail.

Plan II's P13 long tail -- thirteen families with no 2.0.0 ancestor::

    greyscale_ps  ssaa_ps  foliagepush_ps  debugtexture_ps  waterreflection_ps
    fog_ps  volumetricfog_vs  volumetricfog_ps  cameraocclusion_vs
    cameraocclusion_ps  coneindicator_vs  coneindicator_ps  movie_ps

Each is a handful of instructions, so they share one config-driven driver the
way the post-process families do (``shader_diff_postfx.py``). What they do NOT
share is what random inputs fail to reach, so every family has its own inputs,
constant rows and texture model:

* **Textures are piecewise constant** (``_CellTexture``): a gather that averages
  a smooth field returns the same answer whatever its tap offsets are -- the P8
  lesson -- so ``ssaa``'s taps and ``waterreflection``'s min / max would be
  vacuous.
* **Every exact-comparison branch is straddled**: the sky sentinel (depth past
  32768), ``fogEverywhere`` as exactly 0.0 or 1.0 (the shader tests the BITS),
  the cone's degenerate arm (a zero length, or a slope of one or more), the
  occlusion disc's rim (with an inner radius past it, where only the rim test
  cuts) and its dither threshold.
* **Loop bounds stay sane**: ``waterreflection``'s nested loop walks a source
  rectangle of ``dims * scale`` texels; random rows make that 10^6 iterations.

Retail ``greyscale`` / ``movie`` are SM4 with a Level9 preamble, so every retail
leg is loaded through ``shader_diff_imgui.load_retail``.

    python tools/shader_diff_screenpasses.py
    python tools/shader_diff_screenpasses.py --only fog_ps,movie_ps --trials 400
"""

import argparse
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import f2b, TextureModel                     # noqa: E402
from shader_diff import load, compare, perm_path               # noqa: E402
from shader_diff_imgui import load_retail                      # noqa: E402

REPO = Path(__file__).resolve().parent.parent
SLANG = REPO / "slang_out" / "d3d11"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
SKY = 32768.0


class _CellTexture(TextureModel):
    """One random texel per cell of the coordinate, per slot.

    ``depth_slots`` hold a scene depth (read as ``.x``): 15% of cells are sky
    (past the 32768 sentinel), the rest span ``depth``. Every coordinate is
    hashed on its cell, so a filtered sample and an integer ``ld`` fetch of the
    same place agree, and ~1e-8 reassociation noise between two compilers only
    matters on a cell boundary.
    """

    def __init__(self, cells=2048, depth_slots=(), depth=(-2.0, 60.0), lo=0.0, hi=1.0,
                 dims=(1024, 1024, 0, 11)):
        self.cells = cells
        self.depth_slots = set(depth_slots)
        self.depth = depth
        self.lo, self.hi = lo, hi
        self.dims = dims

    def sample(self, slot, coords):
        key = f"{slot}:" + ":".join(str(math.floor(c * self.cells)) for c in coords[:3])
        r = random.Random(key)
        if slot in self.depth_slots:
            d = r.uniform(SKY, 2 * SKY) if r.random() < 0.15 else r.uniform(*self.depth)
            return [d, d, d, 1.0]
        return [r.uniform(self.lo, self.hi) for _ in range(4)]

    def sample_lod(self, slot, coords, lod):
        return self.sample(slot, coords)


def _rng(tag, seed):
    return random.Random(f"{tag}:{seed}")


def _rows(n, fill=0.0):
    return [[f2b(fill)] * 4 for _ in range(n)]


def _fs_inputs(seed, uv=(0.02, 0.98)):
    r = _rng("fs", seed)
    return {
        ("SV_POSITION", 0): [f2b(r.uniform(0, 1024)), f2b(r.uniform(0, 1024)),
                             f2b(r.uniform(0, 1)), f2b(1.0)],
        ("TEXCOORD", 0): [f2b(r.uniform(*uv)) for _ in range(4)],
        ("TEXCOORD", 1): [f2b(r.uniform(-50, 50)) for _ in range(4)],
    }


def _uv_inputs(seed):
    return _fs_inputs(seed, uv=(0.0, 1.0))


# -- ssaa / foliagepush / debugtexture / coneindicator: cb2[22], cb2[23] -------

def _ssaa_cbufs(seed):
    r = _rng("ssaa", seed)
    cb = _rows(24)
    cb[22] = [f2b(1.0 / r.choice([256, 512, 1024, 2048])),
              f2b(1.0 / r.choice([256, 512, 1024])),
              f2b(r.choice([1.0, 2.0, 4.0, r.uniform(0.5, 4.0)])), f2b(r.uniform(-1, 1))]
    return {2: cb}


def _foliagepush_cbufs(seed):
    r = _rng("push", seed)
    cb = _rows(24)
    cb[22] = [f2b(r.uniform(-2, 2))] + [f2b(r.uniform(-1, 1)) for _ in range(3)]
    return {2: cb}


def _debugtexture_cbufs(seed):
    r = _rng("dbgtex", seed)
    cb = _rows(24)
    cb[22] = [f2b(r.choice([0.0, 1.0, 2.0, 5.0, r.uniform(0, 8)]))] + \
             [f2b(r.uniform(-1, 1)) for _ in range(3)]
    return {2: cb}


def _cone_ps_cbufs(seed):
    r = _rng("cone", seed)
    cb = _rows(24)
    r0, r1 = r.uniform(0.0, 0.6), r.uniform(0.0, 0.6)
    k = r.random()
    if k < 0.15:
        length = r.choice([0.0, -0.2])                  # degenerate: no length
    elif k < 0.35:
        length = abs(r1 - r0) * r.uniform(0.3, 1.0)     # degenerate: slope >= 1
    else:
        length = r.uniform(0.2, 1.2)
    a = r.uniform(-math.pi, math.pi)
    cb[22] = [f2b(r0), f2b(r1), f2b(length), f2b(math.sin(a))]
    cb[23] = [f2b(math.cos(a))] + [f2b(r.uniform(-1, 1)) for _ in range(3)]
    return {2: cb}


# -- waterreflection: the depth-bounds downsample --------------------------------

def _waterreflection_inputs(seed):
    r = _rng("wr", seed)
    inp = _fs_inputs(seed)
    inp[("SV_POSITION", 0)] = [f2b(r.uniform(0, 64)), f2b(r.uniform(0, 64)), f2b(0.5), f2b(1.0)]
    return inp


def _waterreflection_cbufs(seed):
    r = _rng("wrcb", seed)
    zw = [r.choice([1 / 2, 1 / 4, 1 / 8, 1 / 16, r.uniform(0.05, 0.6)]) for _ in range(2)]
    return {3: [[f2b(r.uniform(-1, 1)), f2b(r.uniform(-1, 1)), f2b(zw[0]), f2b(zw[1])]]}


# -- fog / volumetric fog: HD's per-draw fog rows (cb2[1..3], cb2[8..20]) -------

def _fog_rows(r, cb):
    start = r.uniform(-5, 30)
    end = start + r.choice([r.uniform(0.0, 0.0005), r.uniform(1, 60), -r.uniform(0, 5)])
    cb[1] = [f2b(r.uniform(0, 1)), f2b(r.uniform(0, 1)), f2b(r.uniform(0, 1)), f2b(start)]
    cb[2] = [f2b(end), f2b(r.uniform(-0.1, 0.3)), f2b(r.uniform(-5, 40)), f2b(r.uniform(-5, 40))]
    inner = r.uniform(0, 40)
    cb[3] = [f2b(inner), f2b(inner + r.choice([r.uniform(-2, 0.0005), r.uniform(1, 50)])),
             f2b(r.uniform(-1.5, 1.5)), f2b(r.choice([0.0, 0.0, 1.0]))]


def _fog_cbufs(seed):
    cb = _rows(4)
    _fog_rows(_rng("fog", seed), cb)
    return {2: cb}


def _volfog_inputs(seed):
    r = _rng("vf", seed)
    inp = _fs_inputs(seed)
    inp[("TEXCOORD", 0)] = [f2b(r.uniform(-1, 1)), f2b(r.uniform(-1, 1)), f2b(0), f2b(0)]
    return inp


def _volfog_cbufs(seed):
    r = _rng("vfcb", seed)
    cb = _rows(21)
    _fog_rows(r, cb)
    # heightTop / heightBottom straddle each other.
    top = r.uniform(-10, 20)
    cb[2][2] = f2b(top)
    cb[2][3] = f2b(top + r.choice([r.uniform(-20, -0.5), r.uniform(-0.0005, 0.0005),
                                   r.uniform(0.5, 5)]))
    # invView: a basis plus a translation.
    for k in range(3):
        cb[8 + k] = [f2b(r.uniform(-1, 1)) for _ in range(3)] + [f2b(0.0)]
    cb[11] = [f2b(r.uniform(-30, 30)) for _ in range(3)] + [f2b(1.0)]
    # invProjection: the ray spread by the frustum, z near 1 (sometimes ~0,
    # for the 1e-6 guard), w positive.
    cb[12] = [f2b(r.uniform(0.5, 1.5)), f2b(r.uniform(-0.1, 0.1)),
              f2b(r.uniform(-0.1, 0.1)), f2b(r.uniform(-0.05, 0.05))]
    cb[13] = [f2b(r.uniform(-0.1, 0.1)), f2b(r.uniform(0.5, 1.5)),
              f2b(r.uniform(-0.1, 0.1)), f2b(r.uniform(-0.05, 0.05))]
    cb[14] = [f2b(r.uniform(-0.1, 0.1)), f2b(r.uniform(-0.1, 0.1)),
              f2b(r.choice([r.uniform(0.2, 1.5), r.uniform(-1e-7, 1e-7)])), f2b(r.uniform(0.2, 1.0))]
    cb[15] = [f2b(r.uniform(-0.1, 0.1)), f2b(r.uniform(-0.1, 0.1)),
              f2b(r.uniform(-0.2, 0.2)), f2b(r.uniform(0.2, 1.0))]
    cb[20] = [f2b(r.uniform(-30, 30)), f2b(r.uniform(-30, 30)), f2b(r.uniform(-15, 25)), f2b(0.0)]
    return {2: cb}


def _volfog_vs_inputs(seed):
    r = _rng("vfvs", seed)
    return {("ATTR", 0): [f2b(r.uniform(-3, 3)) for _ in range(3)] + [f2b(1.0)]}


# -- camera occlusion --------------------------------------------------------------

def _camocc_vs_inputs(seed):
    r = _rng("covs", seed)
    return {
        ("ATTR", 0): [f2b(r.uniform(-40, 40)) for _ in range(3)] + [f2b(1.0)],
        ("ATTR", 10): [f2b(r.uniform(0, 20))] + [f2b(0.0)] * 3,
        ("ATTR", 1): [f2b(r.uniform(-1, 1)) for _ in range(3)] + [f2b(0.0)],
        ("ATTR", 7): [f2b(r.uniform(-5, 20))] + [f2b(0.0)] * 3,
    }


def _camocc_vs_sysvals(seed):
    # The corner table has four entries; the engine draws 4-vertex strips.
    return {"vertex_id": seed % 4}


def _camocc_vs_cbufs(seed):
    r = _rng("cocb", seed)
    cb = [[f2b(r.uniform(-1, 1)) for _ in range(4)] for _ in range(16)]
    cb[7] = [f2b(r.uniform(-20, 20)) for _ in range(3)] + [f2b(1.0)]
    return {2: cb}


def _camocc_ps_inputs(seed):
    r = _rng("cops", seed)
    inp = _fs_inputs(seed)
    # Corners out to 1.5 only where the inner radius passes the rim (see
    # _camocc_ps_cbufs); elsewhere most of the square is the disc, where the
    # fade and the dither threshold are decided.
    span = 1.5 if seed % 3 == 0 else 1.1
    inp[("TEXCOORD", 0)] = [f2b(r.uniform(-span, span)), f2b(r.uniform(-span, span)),
                            f2b(r.uniform(-50, 50)), f2b(0.0)]
    inp[("TEXCOORD", 1)] = [f2b(r.uniform(-50, 50)) for _ in range(4)]
    return inp


def _camocc_ps_cbufs(seed):
    r = _rng("cocbps", seed)
    cb = _rows(37)
    cb[36] = [f2b(r.uniform(-1, 1)), f2b(r.uniform(-1, 1)),
              f2b(r.uniform(-0.1, 1.2)), f2b(r.choice([1.0, r.uniform(-0.2, 1.1)]))]
    # An inner radius past the rim on one seed in three. Below 1 the fade has
    # already reached zero alpha by the rim, so the rim discard is redundant
    # with the dither and dropping it was visible on 0.3% of trials; past 1 the
    # fade never starts inside the disc's bounding square and only the rim
    # test cuts the corners off.
    if seed % 3 == 0:
        cb[36][2] = f2b(r.uniform(0.3, 1.2))
        cb[36][3] = f2b(r.uniform(1.0, 1.6))
    return {1: cb}


# -- cone indicator VS: HD's per-draw vertex bank -----------------------------------

def _cone_vs_cbufs(seed):
    r = _rng("conevs", seed)
    return {2: [[f2b(r.uniform(-2, 2)) for _ in range(4)] for _ in range(21)]}


# family -> (retail dir, nperms, output_regs, inputs_fn, cbufs_fn, sysvals_fn, texture)
FAMILIES = {
    "greyscale_ps":       ("greyscale", 1, (0,), _fs_inputs, None, None, _CellTexture()),
    "ssaa_ps":            ("ssaa", 1, (0,), _fs_inputs, _ssaa_cbufs, None, _CellTexture(cells=4096)),
    "foliagepush_ps":     ("foliagepush", 1, (0,), _uv_inputs, _foliagepush_cbufs, None, None),
    "debugtexture_ps":    ("debugtexture", 1, (0,), _fs_inputs, _debugtexture_cbufs, None,
                           _CellTexture()),
    "waterreflection_ps": ("waterreflection", 1, (0,), _waterreflection_inputs,
                           _waterreflection_cbufs, None,
                           _CellTexture(cells=1, depth_slots=(0,), dims=(256, 192, 0, 1))),
    "fog_ps":             ("fog", 7, (0,), _fs_inputs, _fog_cbufs, None,
                           _CellTexture(depth_slots=(0,))),
    "volumetricfog_vs":   ("volumetricfog_vs", 1, (0, 1), _volfog_vs_inputs, None, None, None),
    "volumetricfog_ps":   ("volumetricfog", 1, (0,), _volfog_inputs, _volfog_cbufs, None,
                           _CellTexture(cells=1, depth_slots=(0,))),
    "cameraocclusion_vs": ("cameraocclusion_vs", 1, (0, 1), _camocc_vs_inputs, _camocc_vs_cbufs,
                           _camocc_vs_sysvals, None),
    "cameraocclusion_ps": ("cameraocclusion", 1, (0,), _camocc_ps_inputs, _camocc_ps_cbufs,
                           None, None),
    "coneindicator_vs":   ("coneindicator_vs", 1, (0, 1, 2), None, _cone_vs_cbufs, None, None),
    "coneindicator_ps":   ("coneindicator", 1, (0,), _uv_inputs, _cone_ps_cbufs, None,
                           _CellTexture()),
    "movie_ps":           ("movie", 24, (0,), _fs_inputs, None, None,
                           _CellTexture(lo=-0.1, hi=1.1)),
}


def run_family(name, cfg, trials, tol, slang_root=None, retail_root=None, quiet=False):
    retail_sub, nperms, out_regs, inputs_fn, cbufs_fn, sysvals_fn, texture = cfg
    retail = Path(retail_root or (REPO / "wc3_re_shaders")) / retail_sub
    slang = Path(slang_root or SLANG) / name
    worst = 0.0
    diverging = []
    for idx in range(nperms):
        prog_r = load_retail(perm_path(retail, idx, "asm"))
        prog_s = load(perm_path(slang, idx, "dxbc"), decompiler=DECOMPILER)
        try:
            res = compare(prog_s, prog_r, trials=trials, output_regs=out_regs, tol=tol,
                          inputs_fn=inputs_fn, cbufs_fn=cbufs_fn,
                          sysvals_fn=sysvals_fn or (lambda s: {}), texture=texture,
                          rel_scale=1.0)
        except KeyError as exc:
            diverging.append((idx, f"reads cb bank {exc.args[0]} the driver does not build"))
            continue
        worst = max(worst, res.worst)
        if res.worst > tol or res.discard_mismatches:
            diverging.append((idx, res.worst, res.discard_mismatches))
    ok = not diverging
    if not quiet:
        print(f"  {name:<20} {nperms:2d} perm(s): worst={worst:.3e}  "
              + ("MATCH" if ok else f"DIVERGE {diverging}"), flush=True)
    return ok, diverging


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--trials", type=int, default=256)
    ap.add_argument("--tol", type=float, default=1e-3)
    ap.add_argument("--only", default=None, help="comma-separated family names")
    ap.add_argument("--slang-dir", default=None, help="root of the slang d3d11 family folders")
    args = ap.parse_args(argv)

    only = set(args.only.split(",")) if args.only else None
    print("=== P13 screen / world passes ===")
    all_ok = True
    for name, cfg in FAMILIES.items():
        if only and name not in only:
            continue
        all_ok &= run_family(name, cfg, args.trials, args.tol, args.slang_dir)[0]
    print("ALL MATCH" if all_ok else "SOME DIVERGE")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
