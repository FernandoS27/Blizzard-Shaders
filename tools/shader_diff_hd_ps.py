"""Differential test of the slang ``hd_ps`` family against retail bytecode.

The Warcraft III Reforged **3.0.0** HD mesh pixel shader: 1024 permutations on
a 10-bit feature mask ::

    bit 0 AO_MAP   1 SHADOW_CASCADE2   2 MULTI_TARGET   3 DEPTH_PREPASS
    bit 4 LIGHT_DEBUG   5 POINT_SHADOWS   6 SHADOW_CASCADE   7 LIGHTING
    bit 8 ALPHA_TEST   9 MULTI_LAYER

Several of those only mean anything under another (a depth prepass ignores
every shading axis; the four lighting sub-axes need LIGHTING; the second
cascade set needs the first), so the mask holds far fewer distinct programs
than slots. Every slot is still checked — a candidate that folds differently
from retail is exactly the bug worth catching — but slots that pose an
identical comparison on BOTH legs are interpreted once.

**The drivers come from** :mod:`wc3_uber_validate`. They are the same
generators the uber reconstruction was gated with, and they exist because this
shader is a clustered-forward renderer whose loop bounds come out of a constant
buffer and a structured cluster grid. Fed plain random floats it either runs a
loop ``asuint(0.37)`` times or never enters the light loop at all and silently
validates nothing; the drivers put sane integers in every discriminant so each
branch is reachable, and hand both shaders the same values. See
``tools/wc3_uber_validate.py`` for what each one shapes and why.

Outputs compared: SV_TARGET0, plus the two deferred targets on MRT perms.

Run from the repo root::

    python tools/shader_diff_hd_ps.py                   # full sweep
    python tools/shader_diff_hd_ps.py --perms 231,1015  # specific perms
    python tools/shader_diff_hd_ps.py --trials 64

The tolerance is looser than the vertex shader's: the specular-AA path is fed a
synthetic derivative, and the cascade / cube reprojections accumulate their
dot products in a different order than fxc scheduled them, so a few ulps of
drift on a large clip coordinate is fp noise rather than a logic divergence.
"""

import argparse
import hashlib
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shader_diff import load, compare, perm_path                    # noqa: E402
from wc3_uber_validate import DRIVERS                     # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "wc3_re_shaders" / "hd"
SLANG_DIR = REPO / "slang_out" / "d3d11" / "hd_ps"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 1024

#: SV_TARGET0 always; 1 and 2 exist only on the MRT perms and read as zero on
#: both legs elsewhere, so comparing all three unconditionally is safe.
OUTPUT_REGS = (0, 1, 2)

#: ``hd`` driver: varyings, driven constant buffers, the clustered light /
#: index / grid structured buffers, and the texture stand-in whose depth
#: samples straddle zero. Shared verbatim with the uber-shader gate.
DRIVER = DRIVERS['hd']

_BITS = (("AO", 1), ("SC2", 2), ("MRT", 4), ("DP", 8), ("DBG", 16),
         ("PTS", 32), ("SC", 64), ("LIT", 128), ("AT", 256), ("ML", 512))


def feat(idx):
    """Human-readable label for a permutation index."""
    f = [name for name, bit in _BITS if idx & bit]
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
    #   SHADOW_CASCADE2         0.0e0     0.0e0   4.4e-03   9.0e-03   1.2e-02
    #   POINT_SHADOWS           0.0e0     0.0e0   5.1e-04   2.3e-03   1.5e-02
    #
    # At 8 and 16 trials the two programs are bit-identical; at 32 the cube
    # shadow clears 5.1e-04, which is BELOW the 1e-3 tolerance -- so a sweep at
    # the old default reported every point-shadow permutation green without
    # ever executing a cube-shadow lookup that changed the answer. Both axes
    # need a shaded point that lands inside a cascade AND inside a light's
    # shadow shell, and the driver only reaches that combination every few
    # dozen seeds. Lowering this re-opens the hole.
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
                    help='comma-separated perm indices (default: all 1024)')
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
                print(f"  DIVERGE perm_{idx:04d} {feat(idx)}: same program as "
                      f"perm_{first:04d}")
            continue

        res = compare(prog_s, prog_r, trials=args.trials,
                      output_regs=OUTPUT_REGS, tol=args.tol,
                      rel_scale=args.rel_scale, **DRIVER)
        worst_all = max(worst_all, res.worst)
        dm_total += res.discard_mismatches
        if res.worst > args.tol or res.discard_mismatches:
            seen[key] = (idx, (res.worst, res.discard_mismatches))
            diverging.append((idx, res.worst, res.discard_mismatches))
            print(f"  DIVERGE perm_{idx:04d} {feat(idx)}: worst={res.worst:.3e} "
                  f"dm={res.discard_mismatches} at {res.worst_where} "
                  f"(seed {res.worst_seed})")
        else:
            seen[key] = (idx, None)

        if n and n % 128 == 0:
            print(f"  ...perm {idx} ({len(seen)} classes, "
                  f"worst {worst_all:.1e}, {time.time() - t0:.0f}s)",
                  file=sys.stderr)

    print(f"\n=== hd_ps 3.0.0: {len(perms)} perms x {args.trials} trials ===")
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
