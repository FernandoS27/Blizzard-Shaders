"""Differential test of the slang ``cliffblightmiscterrain_ps`` family against retail.

The Warcraft III Reforged **3.0.0** cliff / blight / misc-terrain pixel shader --
new coverage, no 2.0.0 counterpart. 256 permutations, 50 programs::

    bit 0 SHADOW_CASCADE2   1 MULTI_TARGET   2 DEPTH_PREPASS   3 LIGHT_DEBUG
    bit 4 POINT_SHADOWS     5 SHADOW_CASCADE 6 (dead)          7 ALPHA_TEST

**The driver is ``DRIVERS['hd']``** -- the family sits on HD's banks exactly as
foliage and terrain do -- with ONE addition, for the one branch hd's texture
model would starve: the 0.8 coverage cut-out. It tests the ALBEDO alpha alone,
and hd's texels stop at 0.9, so without help almost every pixel would pass.
t0's alpha is spread to about [0, 1.1], which also puts the alpha test's
``vertexAlpha * albedoAlpha < alphaRef`` on both sides.

Units check for the borrowed driver: the family reads t0-t2 at TEXCOORD0.xy,
the blight at .zw, and TEXCOORD1 / 2 / 3 / 10 as HD does; it never reads t7.
The front face is hd's random one (the normal is flipped on back faces here).

    python tools/shader_diff_cliffblightmiscterrain_ps.py
"""

import argparse
import hashlib
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shader_diff import load, compare, perm_path                    # noqa: E402
from wc3_uber_validate import DRIVERS, HdTextures                   # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "wc3_re_shaders" / "cliffblightmiscterrain"
SLANG_DIR = REPO / "slang_out" / "d3d11" / "cliffblightmiscterrain_ps"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 256
OUTPUT_REGS = (0, 1, 2)


class CliffTextures(HdTextures):
    """hd's texture model with the albedo alpha spread across the cut-out."""

    def sample(self, slot, coords):
        out = super().sample(slot, coords)
        if slot == 0:
            out = out[:3] + [out[3] * 1.4 - 0.15]
        return out


DRIVER = dict(DRIVERS['hd'])
DRIVER.update(texture=CliffTextures())

_BITS = (("SC2", 1), ("MRT", 2), ("DP", 4), ("DBG", 8), ("PTS", 16), ("SC", 32),
         ("b6", 64), ("AT", 128))


def feat(idx):
    f = [name for name, bit in _BITS if idx & bit]
    return "+".join(f) if f else "base"


def body_hash(asm_path):
    """Declarations + instruction stream; a sweep dedup, never a fold count."""
    h = hashlib.sha1()
    for line in Path(asm_path).read_text('utf-8', errors='replace').splitlines():
        s = line.strip()
        if s and not s.startswith('//'):
            h.update(s.encode('utf-8') + b'\n')
    return h.hexdigest()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=128)
    ap.add_argument('--tol', type=float, default=1e-3)
    ap.add_argument('--rel-scale', type=float, default=1.0)
    ap.add_argument('--perms', default=None)
    ap.add_argument('--retail-dir', default=str(RETAIL_DIR))
    ap.add_argument('--slang-dir', default=str(SLANG_DIR))
    ap.add_argument('--decompiler', default=str(DECOMPILER))
    args = ap.parse_args(argv)

    perms = ([int(x) for x in args.perms.split(',')] if args.perms
             else list(range(NPERMS)))
    retail, slang = Path(args.retail_dir), Path(args.slang_dir)
    t0 = time.time()
    worst_all, diverging, dm_total, seen = 0.0, [], 0, {}
    for idx in perms:
        retail_asm = perm_path(retail, idx, "asm")
        slang_dxbc = perm_path(slang, idx, "dxbc")
        prog_r = load(retail_asm)
        prog_s = load(slang_dxbc, decompiler=args.decompiler)
        key = (body_hash(retail_asm), body_hash(slang_dxbc.with_suffix('.asm')))
        if key in seen:
            first, failure = seen[key]
            if failure is not None:
                diverging.append((idx,) + failure)
                print(f"  DIVERGE perm_{idx:03d} {feat(idx)}: same program as perm_{first:03d}")
            continue
        res = compare(prog_s, prog_r, trials=args.trials, output_regs=OUTPUT_REGS,
                      tol=args.tol, rel_scale=args.rel_scale, **DRIVER)
        worst_all = max(worst_all, res.worst)
        dm_total += res.discard_mismatches
        if res.worst > args.tol or res.discard_mismatches:
            seen[key] = (idx, (res.worst, res.discard_mismatches))
            diverging.append((idx, res.worst, res.discard_mismatches))
            print(f"  DIVERGE perm_{idx:03d} {feat(idx)}: worst={res.worst:.3e} "
                  f"dm={res.discard_mismatches} at {res.worst_where} (seed {res.worst_seed})")
        else:
            seen[key] = (idx, None)

    print(f"\n=== cliffblightmiscterrain_ps 3.0.0: {len(perms)} perms x {args.trials} trials ===")
    print(f"output regs      : {list(OUTPUT_REGS)}")
    print(f"distinct classes : {len(seen)}")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"discard mismatch : {dm_total}")
    print(f"perms diverging  : {len(diverging)}")
    print(f"elapsed          : {time.time() - t0:.1f}s")
    print("ALL MATCH" if not diverging else f"DIVERGING: {[d[0] for d in diverging]}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
