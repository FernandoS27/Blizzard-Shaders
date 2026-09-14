"""Differential test of the slang ``foliage_vs`` family against retail bytecode.

The Warcraft III Reforged **3.0.0** foliage vertex shader: 2 permutations, one
axis -- bit 0 WIND. (2.0.0 shipped eight; both shadow bits left with the cascade
outputs.)

**3.0.0 moved foliage onto the HD mesh's VERTEX banks**: cb1[0] is HD's blight
rect and cb2 is HD's per-draw bank read at HD's offsets -- world (0-3),
worldView (4-7), worldViewProj (8-11), the diffuse tint (18) and the UV0 matrix
(19-20), plus the wind clock at cb2[16].x. So the attribute and constant-buffer
generators are ``DRIVERS['hd_vs']``'s, with two overrides that only the WIND
permutation needs:

* **cb3 is the wind-area rect, not a bone palette.** Origin and size are drawn
  against the position range hd's attribute generator produces, with the size
  kept well away from zero (the body divides by it).
* **the wind field (t0) is PIECEWISE CONSTANT.** The body takes a gradient from
  three taps one texel apart and adds its (cos, sin) swing ONLY where that
  gradient is exactly zero on both axes. A smooth texture model has a non-zero
  gradient everywhere, which would make the swing branch unreachable; cells a
  few texels wide make both the flat and the sloped case common, and a value
  range wider than [0, 1] makes the [-1, 1] gradient clamp bind.

The wind gate is ``ATTR2.w > 0``, and ``|ATTR7.w|`` scales the wind strength
(clamped at 100), so both are driven per trial: the gate negative, zero and
positive; the tangent w including zero (where the handedness output ``sign(w)``
is 0) and values past the clamp.

Outputs compared: o0..o6 (SV_POSITION, COLOR0, TEXCOORD0/1/3/2/10), taken from
the retail signature.

    python tools/shader_diff_foliage_vs.py
    python tools/shader_diff_foliage_vs.py --trials 512
"""

import argparse
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import TextureModel, f2b                   # noqa: E402
from shader_diff import load, compare, perm_path            # noqa: E402
from wc3_uber_validate import hd_vs_cbufs, hd_vs_inputs     # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "wc3_re_shaders" / "foliage_vs"
SLANG_DIR = REPO / "slang_out" / "d3d11" / "foliage_vs"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 2
OUTPUT_REGS = tuple(range(7))


class WindField(TextureModel):
    """Cell-constant wind field: 64 cells per UV unit over a 1024-texel map."""
    CELLS = 64

    def sample(self, slot, coords):
        iu = math.floor(coords[0] * self.CELLS)
        iv = math.floor(coords[1] * self.CELLS)
        v = random.Random(f"wind:{slot}:{iu}:{iv}").uniform(-1.5, 1.5)
        return [v, v, v, 1.0]

    def sample_lod(self, slot, coords, lod):
        return self.sample(slot, coords)


def foliage_vs_inputs(seed):
    inp = dict(hd_vs_inputs(seed))
    r = random.Random(7700 + seed)
    color = inp[("ATTR", 2)]
    gate = r.random()
    w = 0.0 if gate < 0.15 else (-r.uniform(0.01, 1) if gate < 0.25 else r.uniform(0.01, 1))
    inp[("ATTR", 2)] = color[:3] + [f2b(w)]
    tangent = inp[("ATTR", 7)]
    k = r.random()
    tw = 0.0 if k < 0.1 else r.choice([-1, 1]) * (r.uniform(80, 160) if k < 0.2 else r.uniform(0.05, 4))
    inp[("ATTR", 7)] = tangent[:3] + [f2b(tw)]
    return inp


def foliage_vs_cbufs(seed):
    cb = hd_vs_cbufs(seed)
    rng = random.Random(seed * 131 + 7)
    # hd_vs_inputs draws positions in [-3, 3]; texels are 1/1024, so a 2..8
    # unit area puts neighbouring taps in the same 64-per-unit cell most of
    # the time and across a cell edge some of the time.
    cb[3] = [[f2b(rng.uniform(-4, -1)), f2b(rng.uniform(-4, -1)),
              f2b(rng.uniform(2, 8)), f2b(rng.uniform(2, 8))]]
    cb[2][16][0] = f2b(rng.uniform(-50, 50))     # wind clock, frac() taken
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

    retail, slang = Path(args.retail_dir), Path(args.slang_dir)
    worst_all, diverging = 0.0, []
    for idx in range(NPERMS):
        prog_r = load(perm_path(retail, idx, "asm"))
        prog_s = load(perm_path(slang, idx, "dxbc"), decompiler=args.decompiler)
        res = compare(prog_s, prog_r, trials=args.trials, output_regs=OUTPUT_REGS,
                      tol=args.tol, inputs_fn=foliage_vs_inputs,
                      cbufs_fn=foliage_vs_cbufs, sysvals_fn=lambda s: {},
                      texture=WindField())
        worst_all = max(worst_all, res.worst)
        tag = "WIND" if idx & 1 else "static"
        if res.worst > args.tol:
            diverging.append(idx)
            print(f"  DIVERGE perm_{idx:03d} {tag}: worst={res.worst:.3e} "
                  f"at {res.worst_where} (seed {res.worst_seed})")
        else:
            print(f"  ok      perm_{idx:03d} {tag}: worst={res.worst:.3e}")

    print(f"\n=== foliage_vs 3.0.0: {NPERMS} perms x {args.trials} trials ===")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"perms diverging  : {len(diverging)}")
    print("ALL MATCH" if not diverging else f"DIVERGING: {diverging}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
