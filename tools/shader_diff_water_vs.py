"""Differential test of the slang ``water_vs`` against retail bytecode.

The Warcraft III Reforged **3.0.0** water vertex shader: one permutation.

3.0.0 moved water onto the HD mesh's VERTEX banks, so the attribute and
constant generators are ``DRIVERS['hd_vs']``'s -- cb2 world (0-3) /
worldView (4-7) / worldViewProj (8-11), the effect clock at cb2[16].x and the
UV0 matrix at cb2[19..20]; cb1[0] the blight rect -- with two additions:

* **cb1[1].x, the wave height.** hd's generator builds one cb1 row (HD reads
  only the rect), and retail water reads the second, so without this every
  trial raises. Drawn in (-2, 2), including exact zero on a fixed seed, where
  the displacement vanishes and a candidate that ignored the height entirely
  would still agree.
* **t0, the vertex texture fetch.** The ripple normal map is sampled at two
  counter-scrolling coordinates and the decoded normal Y's displace the vertex.
  The default smooth texture model is right here: the taps are reached through
  the UV matrix and the clock, so a wrong tiling, scroll or shift moves the
  sample and changes the height.

The effect clock is drawn over a wide range (the scroll takes ``frac(0.0035 *
t)``, so a clock inside (-1, 1) would barely move the ripples).

Outputs compared: o0..o6, from the retail signature.

    python tools/shader_diff_water_vs.py
"""

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import TextureModel, f2b                   # noqa: E402
from shader_diff import load, compare, perm_path            # noqa: E402
from wc3_uber_validate import hd_vs_cbufs, hd_vs_inputs     # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "wc3_re_shaders" / "water_vs"
SLANG_DIR = REPO / "slang_out" / "d3d11" / "water_vs"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 1
OUTPUT_REGS = tuple(range(7))


def water_vs_cbufs(seed):
    cb = hd_vs_cbufs(seed)
    rng = random.Random(seed * 977 + 3)
    wave = 0.0 if seed % 11 == 4 else rng.uniform(-2, 2)
    cb[1] = cb[1][:1] + [[f2b(wave)] + [f2b(rng.uniform(-1, 1)) for _ in range(3)]]
    cb[2][16][0] = f2b(rng.uniform(-5000, 5000))      # effect clock
    return cb


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=256)
    ap.add_argument('--tol', type=float, default=1e-4)
    ap.add_argument('--retail-dir', default=str(RETAIL_DIR))
    ap.add_argument('--slang-dir', default=str(SLANG_DIR))
    ap.add_argument('--decompiler', default=str(DECOMPILER))
    args = ap.parse_args(argv)

    prog_r = load(perm_path(Path(args.retail_dir), 0, "asm"))
    prog_s = load(perm_path(Path(args.slang_dir), 0, "dxbc"), decompiler=args.decompiler)
    res = compare(prog_s, prog_r, trials=args.trials, output_regs=OUTPUT_REGS,
                  tol=args.tol, inputs_fn=hd_vs_inputs, cbufs_fn=water_vs_cbufs,
                  sysvals_fn=lambda s: {}, texture=TextureModel())
    ok = res.worst <= args.tol
    print(f"=== water_vs 3.0.0: 1 perm x {args.trials} trials ===")
    print(f"worst divergence : {res.worst:.3e}"
          + (f"  at {res.worst_where} (seed {res.worst_seed})" if not ok else ""))
    print("ALL MATCH" if ok else "DIVERGING: [0]")
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
