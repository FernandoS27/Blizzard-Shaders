"""Differential test of the slang ``cliffblightmiscterrain_vs`` against retail.

The Warcraft III Reforged **3.0.0** cliff / blight / misc-terrain vertex shader --
new coverage, one permutation. It reads HD's vertex banks and HD's eight-slot
stream, so the generators are ``DRIVERS['hd_vs']``'s, with the tangent's w
drawn at 0 and at magnitudes other than 1: the shader passes it through raw,
and hd's generator only draws +-1, where a stray ``sign()`` would be invisible
(the same hole P10's terrain driver had). hd's normals cover the whole sphere,
so the unclamped bend sees z < 0 as well as z in (0, 1).

    python tools/shader_diff_cliffblightmiscterrain_vs.py
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
RETAIL_DIR = REPO / "wc3_re_shaders" / "cliffblightmiscterrain_vs"
SLANG_DIR = REPO / "slang_out" / "d3d11" / "cliffblightmiscterrain_vs"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
OUTPUT_REGS = tuple(range(7))


def cliff_vs_inputs(seed):
    inp = dict(hd_vs_inputs(seed))
    r = random.Random(6060 + seed)
    tangent = inp[("ATTR", 7)]
    inp[("ATTR", 7)] = tangent[:3] + [f2b(r.choice([-1.0, 1.0, 0.0, r.uniform(-3, 3)]))]
    return inp


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
                  tol=args.tol, inputs_fn=cliff_vs_inputs, cbufs_fn=hd_vs_cbufs,
                  sysvals_fn=lambda s: {}, texture=TextureModel())
    ok = res.worst <= args.tol
    print(f"=== cliffblightmiscterrain_vs 3.0.0: 1 perm x {args.trials} trials ===")
    print(f"worst divergence : {res.worst:.3e}"
          + (f"  at {res.worst_where} (seed {res.worst_seed})" if not ok else ""))
    print("ALL MATCH" if ok else "DIVERGING: [0]")
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
