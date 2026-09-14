"""Differential test of the slang ``terrain_vs`` family against retail bytecode.

The Warcraft III Reforged **3.0.0** terrain vertex shader: 2 permutations, one
axis -- bit 0 VERTEX_COLOR (the vertex colour REPLACES the diffuse tint).
2.0.0 shipped eight; both shadow bits left with the cascade outputs.

3.0.0 moved terrain onto the HD mesh's VERTEX banks (cb1[0] blight rect, cb2
world / worldView / worldViewProj / tint at HD's offsets), so the attribute and
constant generators are ``DRIVERS['hd_vs']``'s with one override: **ATTR6 is
not a bone weight on terrain, it is the four splat layer indices**, a uint4
passed straight through to TEXCOORD8. When all four are 0xFFFF the vertex is
culled to clip z = -2, so the driver makes one slot in four empty and one trial
in ten fully empty -- random uints would essentially never produce 0xFFFF and
the cull would be unreachable.

The tangent's w is passed through raw, so it is drawn at 0 and at magnitudes
other than 1 (hd's generator only draws +-1, which hides a stray ``sign()``).

The normal bend ``saturate(z) * (z^8 - z) + z`` is only interesting where z is
inside (0, 1) and at its ends; hd's generator draws unit normals over the whole
sphere plus exact zero vectors, which covers z < 0 (saturate at 0), z in
(0, 1), and the degenerate normalise.

Outputs compared: o0..o7 (TEXCOORD8, SV_POSITION, COLOR0, TEXCOORD0/1/3/2/10),
taken from the retail signature.

    python tools/shader_diff_terrain_vs.py
"""

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import TextureModel, f2b, i2b                  # noqa: E402
from shader_diff import load, compare, perm_path            # noqa: E402
from wc3_uber_validate import hd_vs_cbufs, hd_vs_inputs     # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "wc3_re_shaders" / "terrain_vs"
SLANG_DIR = REPO / "slang_out" / "d3d11" / "terrain_vs"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 2
OUTPUT_REGS = tuple(range(8))
NO_LAYER = 0xFFFF


def terrain_vs_inputs(seed):
    inp = dict(hd_vs_inputs(seed))
    r = random.Random(5150 + seed)
    if seed % 10 == 3:
        layers = [NO_LAYER] * 4
    else:
        layers = [NO_LAYER if r.random() < 0.25 else r.randrange(0, 64) for _ in range(4)]
    inp[("ATTR", 6)] = [i2b(x) for x in layers]
    # Terrain passes the tangent's w through RAW (foliage takes its sign). hd's
    # generator only draws +-1, where sign(w) == w and a sign() would be
    # invisible, so draw zero and other magnitudes too.
    tangent = inp[("ATTR", 7)]
    w = r.choice([-1.0, 1.0, 0.0, r.uniform(-3, 3)])
    inp[("ATTR", 7)] = tangent[:3] + [f2b(w)]
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

    retail, slang = Path(args.retail_dir), Path(args.slang_dir)
    worst_all, diverging = 0.0, []
    for idx in range(NPERMS):
        prog_r = load(perm_path(retail, idx, "asm"))
        prog_s = load(perm_path(slang, idx, "dxbc"), decompiler=args.decompiler)
        res = compare(prog_s, prog_r, trials=args.trials, output_regs=OUTPUT_REGS,
                      tol=args.tol, inputs_fn=terrain_vs_inputs, cbufs_fn=hd_vs_cbufs,
                      sysvals_fn=lambda s: {}, texture=TextureModel())
        worst_all = max(worst_all, res.worst)
        tag = "VERTEX_COLOR" if idx & 1 else "tint"
        if res.worst > args.tol:
            diverging.append(idx)
            print(f"  DIVERGE perm_{idx:03d} {tag}: worst={res.worst:.3e} "
                  f"at {res.worst_where} (seed {res.worst_seed})")
        else:
            print(f"  ok      perm_{idx:03d} {tag}: worst={res.worst:.3e}")

    print(f"\n=== terrain_vs 3.0.0: {NPERMS} perms x {args.trials} trials ===")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"perms diverging  : {len(diverging)}")
    print("ALL MATCH" if not diverging else f"DIVERGING: {diverging}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
