"""Differential test of the slang ``sd_on_hd_ps`` family against retail bytecode.

The Warcraft III Reforged **3.0.0** SD-on-HD pixel shader: SD art rendered
through the HD pipeline. 384 permutations, a 6-bit feature mask under a 6-way
outer block ::

    idx = bits | 64 * outer      outer = LIGHTING + 2 * sub

    bit 0 SHADOW_CASCADE2   1 MULTI_TARGET   2 DEPTH_PREPASS
    bit 3 LIGHT_DEBUG       4 POINT_SHADOWS  5 SHADOW_CASCADE
    sub   0 plain           1 ALPHA_TEST     2 SRGB_OUTPUT

Several axes only mean anything under another (a depth prepass ignores every
shading axis and the sRGB encode; the four lighting sub-axes need LIGHTING; the
second cascade set needs the first), so the 384 slots hold 80 distinct
programs. Every slot is still checked -- a candidate that folds differently
from retail is exactly the bug worth catching -- but slots posing an identical
comparison on BOTH legs are interpreted once.

**The drivers are HD's**, from :mod:`wc3_uber_validate`, and that is the point:
3.0.0 put this family on the HD constant buffers, the HD textures and the HD
clustered-forward light list, so a driver that shapes HD's discriminants shapes
this one's too. Fed plain random floats the shader either runs its light loop
``asuint(0.37)`` times or never enters it, and validates nothing. The handful
of HD slots SD never reads (the normal / ORM / emissive / team maps, the
fresnel tint) are simply driven and ignored.

Outputs compared: SV_TARGET0, plus the two deferred targets on MRT perms.

Run from the repo root::

    python tools/shader_diff_sd_on_hd_ps.py                # full 384-perm sweep
    python tools/shader_diff_sd_on_hd_ps.py --perms 64,121 # specific perms
    python tools/shader_diff_sd_on_hd_ps.py --trials 64

The tolerance matches ``hd_ps``'s: the cascade and cube reprojections
accumulate their dot products in a different order than fxc scheduled them, so
a few ulps of drift on a large clip coordinate is fp noise rather than a logic
divergence.
"""

import argparse
import hashlib
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shader_diff import load, compare, perm_path          # noqa: E402
from wc3_uber_validate import DRIVERS                     # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "wc3_re_shaders" / "sd_on_hd"
SLANG_DIR = REPO / "slang_out" / "d3d11" / "sd_on_hd_ps"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 384

#: SV_TARGET0 always; 1 and 2 exist only on the MRT perms and read as zero on
#: both legs elsewhere, so comparing all three unconditionally is safe.
OUTPUT_REGS = (0, 1, 2)

#: Shared verbatim with ``hd_ps`` and the uber-shader gate.
DRIVER = DRIVERS['hd']

_BITS = (("SC2", 1), ("MRT", 2), ("DP", 4), ("DBG", 8), ("PTS", 16), ("SC", 32))
_SUB = ("plain", "AT", "SRGB")


def feat(idx):
    """Human-readable label for a permutation index."""
    outer = idx // 64
    f = [name for name, bit in _BITS if idx & bit]
    if outer % 2:
        f.insert(0, "LIT")
    sub = _SUB[outer // 2]
    if sub != "plain":
        f.insert(0, sub)
    return "+".join(f) if f else "base"


def body_hash(asm_path):
    """Hash of a disassembly's behavioural content.

    Comment lines carry the disassembler's timestamp and the reflection dump
    (which the retail blobs do not have at all), so they are dropped; what is
    left is the declarations plus the instruction stream.
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
    # 128, not 32. Two of the shadow axes are invisible below it. Measured
    # retail-against-retail -- two SHIPPED permutations that differ only in one
    # axis, so any divergence is that axis and nothing else:
    #
    #   trials                      8        16        32        64       128
    #   SHADOW_CASCADE2 96/97   0.0e0     0.0e0   2.3e-02   5.5e-02   8.0e-02
    #   POINT_SHADOWS   64/80   0.0e0     0.0e0   4.1e-03   3.8e-02   6.9e-02
    #
    # At 8 and 16 trials the two programs are bit-identical -- a mutation
    # disabling either axis passes a sweep at that count. This family clears
    # the 1e-3 tolerance at 32, but only just, and `hd_ps` (same driver, same
    # axes) does NOT: its point-shadow pair reaches 5.1e-04 at 32 trials, below
    # tolerance, so its old default reported every point-shadow permutation
    # green without ever executing a cube-shadow lookup that changed the
    # answer. Both axes need a shaded point landing inside a cascade AND inside
    # a light's shadow shell, and the driver reaches that combination only
    # every few dozen seeds. Lowering this re-opens the hole.
    ap.add_argument('--trials', type=int, default=128)
    ap.add_argument('--tol', type=float, default=1e-3)
    # The score is RELATIVE above magnitude 1 (see shader_diff.output_diff).
    # A fixed absolute threshold tests a bright pixel far more strictly than a
    # dim one, which is not a property a correctness gate should have: the
    # LIGHT_DEBUG permutations add a light count to the output and sit around
    # 13 where the shaded ones sit near 3, so at 128 trials all 64 of them
    # crossed 1e-3 absolute while their non-debug siblings passed -- same seed,
    # same output lane, same relative error. Set to 0 to score absolutely.
    ap.add_argument('--rel-scale', type=float, default=1.0,
                    help='magnitude floor for the diff score (0 = absolute)')
    ap.add_argument('--perms', default=None,
                    help='comma-separated perm indices (default: all 384)')
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

    for n, idx in enumerate(perms):
        retail_asm = perm_path(retail, idx, "asm")
        slang_dxbc = perm_path(slang, idx, "dxbc")
        prog_r = load(retail_asm)
        prog_s = load(slang_dxbc, decompiler=args.decompiler)

        # Two slots that share BOTH hashes pose the same comparison, so the
        # second is not a sample of the first -- it IS the first.
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

        if n and n % 64 == 0:
            print(f"  ...perm {idx} ({len(seen)} classes, "
                  f"worst {worst_all:.1e}, {time.time() - t0:.0f}s)",
                  file=sys.stderr)

    print(f"\n=== sd_on_hd_ps 3.0.0: {len(perms)} perms x {args.trials} trials ===")
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
