"""Differential test of the slang ``foliage_ps`` family against retail bytecode.

The Warcraft III Reforged **3.0.0** foliage pixel shader: 128 permutations on
HD's feature mask with LIGHTING pinned on and AO_MAP / MULTI_LAYER struck out::

    bit 0 SHADOW_CASCADE2   1 MULTI_TARGET   2 DEPTH_PREPASS   3 LIGHT_DEBUG
    bit 4 POINT_SHADOWS     5 SHADOW_CASCADE 6 ALPHA_TEST

**This file reuses ``DRIVERS['hd']`` verbatim.** 3.0.0 moved foliage onto the
HD mesh's banks: its declarations are a lit HD permutation's minus the scene
depth texture t7 -- the same cb1[43] / cb2[31], t0-t3, t6 / t8, t11-t13 and
t16 / t17 / t18. A second driver would be a second description of one layout.

Borrowing a driver means checking UNITS, not just banks (see
project_differential_numeric_coverage): every slot foliage reads was compared
against what hd's driver puts there. t7 -- the one slot hd's texture model
reshapes, to straddle zero for the depth test -- is not read by foliage at all.
The blight UV foliage reads at ``TEXCOORD0.zw`` is a plain [0,1]-ish texture
coordinate in both families (hd reads its AO map there), and TEXCOORD1 / 2 / 3
/ 10 carry the same view position, frame and world position.

What differs from the 2.0.0 version of this file: the whole driver. 2.0.0
foliage had its own per-draw light array in cb2 and cascade interpolants on
TEXCOORD4-6, and the old harness raised ``IndexError: cb1 index 42 outside
[0,4)`` against the 3.0.0 tree.

Outputs compared: SV_TARGET0, plus the two deferred targets on MRT perms.

Run from the repo root::

    python tools/shader_diff_foliage_ps.py                 # full 128-perm sweep
    python tools/shader_diff_foliage_ps.py --perms 0,2,64  # specific perms
    python tools/shader_diff_foliage_ps.py --retail-dir re_shaders_old/foliage

The tolerance and trial count are hd_ps's, for the reasons documented there --
in particular 128 trials, below which the two shadow axes stop being visible.
"""

import argparse
import hashlib
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shader_diff import load, compare, perm_path                    # noqa: E402
from wc3_uber_validate import DRIVERS                               # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "wc3_re_shaders" / "foliage"
SLANG_DIR = REPO / "slang_out" / "d3d11" / "foliage_ps"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 128

#: SV_TARGET0 always; 1 and 2 exist only on MRT perms and read as zero on both
#: legs elsewhere. max(output register) over all 128 retail disassemblies is 2.
OUTPUT_REGS = (0, 1, 2)

#: hd's driver, unchanged -- see the module docstring for the units check.
DRIVER = DRIVERS['hd']

_BITS = (("SC2", 1), ("MRT", 2), ("DP", 4), ("DBG", 8), ("PTS", 16),
         ("SC", 32), ("AT", 64))


def feat(idx):
    """Human-readable label for a permutation index."""
    f = [name for name, bit in _BITS if idx & bit]
    return "+".join(f) if f else "base"


def body_hash(asm_path):
    """Hash of a disassembly's declarations + instruction stream.

    Counts distinct INSTRUCTION STREAMS -- a dedup for the sweep, never a fold
    count (project_fold_class_counting).
    """
    h = hashlib.sha1()
    for line in Path(asm_path).read_text('utf-8', errors='replace').splitlines():
        s = line.strip()
        if s and not s.startswith('//'):
            h.update(s.encode('utf-8'))
            h.update(b'\n')
    return h.hexdigest()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=128)
    ap.add_argument('--tol', type=float, default=1e-3)
    # Relative above magnitude 1 -- the LIGHT_DEBUG perms add a light count.
    ap.add_argument('--rel-scale', type=float, default=1.0,
                    help='magnitude floor for the diff score (0 = absolute)')
    ap.add_argument('--perms', default=None,
                    help='comma-separated perm indices (default: all 128)')
    ap.add_argument('--retail-dir', default=str(RETAIL_DIR))
    ap.add_argument('--slang-dir', default=str(SLANG_DIR))
    ap.add_argument('--decompiler', default=str(DECOMPILER))
    args = ap.parse_args(argv)

    perms = ([int(x) for x in args.perms.split(',')] if args.perms
             else list(range(NPERMS)))
    retail = Path(args.retail_dir)
    slang = Path(args.slang_dir)

    t0 = time.time()
    worst_all = 0.0
    diverging = []
    dm_total = 0
    seen = {}

    for idx in perms:
        retail_asm = perm_path(retail, idx, "asm")
        slang_dxbc = perm_path(slang, idx, "dxbc")
        prog_r = load(retail_asm)
        prog_s = load(slang_dxbc, decompiler=args.decompiler)

        key = (body_hash(retail_asm), body_hash(slang_dxbc.with_suffix('.asm')))
        if key in seen:
            first, failure = seen[key]
            if failure is not None:
                diverging.append((idx, failure[0], failure[1]))
                print(f"  DIVERGE perm_{idx:03d} {feat(idx)}: same program as "
                      f"perm_{first:03d}")
            continue

        res = compare(prog_s, prog_r, trials=args.trials,
                      output_regs=OUTPUT_REGS, tol=args.tol,
                      rel_scale=args.rel_scale, **DRIVER)
        worst_all = max(worst_all, res.worst)
        dm_total += res.discard_mismatches
        if res.worst > args.tol or res.discard_mismatches:
            seen[key] = (idx, (res.worst, res.discard_mismatches))
            diverging.append((idx, res.worst, res.discard_mismatches))
            print(f"  DIVERGE perm_{idx:03d} {feat(idx)}: worst={res.worst:.3e} "
                  f"dm={res.discard_mismatches} at {res.worst_where} "
                  f"(seed {res.worst_seed})")
        else:
            seen[key] = (idx, None)

    print(f"\n=== foliage_ps 3.0.0: {len(perms)} perms x {args.trials} trials ===")
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
