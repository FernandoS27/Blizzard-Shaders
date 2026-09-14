"""Differential test of the slang ``crystal_ps`` family against retail bytecode.

The Warcraft III Reforged **3.0.0** crystal (gem / glass / refraction) pixel
shader: 512 permutations which are ``hd_ps``'s 1024 with the AO_MAP axis struck
out and every higher bit shifted down one, so crystal index ``c`` denotes the
feature set of hd index ``2 * c`` ::

    bit 0 SHADOW_CASCADE2   1 MULTI_TARGET   2 DEPTH_PREPASS   3 LIGHT_DEBUG
    bit 4 POINT_SHADOWS     5 SHADOW_CASCADE 6 LIGHTING        7 ALPHA_TEST
    bit 8 MULTI_LAYER

**This file reuses ``DRIVERS['hd']`` verbatim, and that is a measured fact, not
a convenience.** Crystal's shipped declarations and input signature are
BYTE-IDENTICAL to hd's on the lit permutations -- same cb1[43] / cb2[31], same
t0-t3 / t6-t8 / t11-t13, same t16/t17/t18 clustered-light buffers, same eight
interpolants. Crystal did not get a port in 3.0.0; it got moved onto HD's banks,
exactly as ``popcorn_ps`` and ``popcorn_vs`` were. Writing a second driver would
mean maintaining a second description of the same layout.

Outputs compared: SV_TARGET0, plus the two deferred targets on MRT perms.

WHAT THIS GATE HAS TO REACH THAT HD'S DOES NOT
----------------------------------------------
Crystal's three material differences all hang off the refract mask in ``t2.x``:

* the albedo is two taps of ``t0`` -- at ``uv`` and at
  ``uv + n.xy * (0.02 / |n.z|)`` -- lerped by ``1 - mask``;
* the normal map is decoded RAW (hd scales it by ``cb2[27].x``);
* the Fresnel rim alpha PARAMETER is remapped by the mask.

The first of those is the one a gate can be blind to. The two taps differ only
by a small UV step, so on a smooth texture field the refracted and unrefracted
albedos are CLOSE, and a candidate that dropped the refraction entirely could
score under an absolute tolerance. Two things keep it live: the driver's UV
range is wide enough that the texture field has real gradient across the step,
and ``0.02 / |n.z|`` diverges as the normal turns edge-on, so the grazing trials
take large offsets. That it is genuinely live is not assumed -- ``refraction-
dropped`` and ``refract-offset-uses-shading-normal`` are mutations in the P6
harness and both must come back CAUGHT.

Run from the repo root::

    python tools/shader_diff_crystal_ps.py                 # full 512-perm sweep
    python tools/shader_diff_crystal_ps.py --perms 64,320  # specific perms
    python tools/shader_diff_crystal_ps.py --trials 64

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
RETAIL_DIR = REPO / "wc3_re_shaders" / "crystal"
SLANG_DIR = REPO / "slang_out" / "d3d11" / "crystal_ps"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 512

#: SV_TARGET0 always; 1 and 2 exist only on the MRT perms and read as zero on
#: both legs elsewhere, so comparing all three unconditionally is safe.
#: Taken from the BLOBS (max output register over all 512 retail disassemblies),
#: not from counting struct members -- see
#: project_wc3_output_register_alignment, where popcorn_vs's equivalent tuple
#: was one short and four shipped permutations went uncompared.
OUTPUT_REGS = (0, 1, 2)

#: The hd driver, unchanged: varyings, driven constant buffers, the clustered
#: light / index / grid structured buffers, and the texture stand-in whose t7
#: depth samples straddle zero.
DRIVER = DRIVERS['hd']

_BITS = (("SC2", 1), ("MRT", 2), ("DP", 4), ("DBG", 8), ("PTS", 16),
         ("SC", 32), ("LIT", 64), ("AT", 128), ("ML", 256))


def feat(idx):
    """Human-readable label for a permutation index."""
    f = [name for name, bit in _BITS if idx & bit]
    return "+".join(f) if f else "base"


def body_hash(asm_path):
    """Hash of a disassembly's behavioural content.

    Comment lines carry the disassembler's timestamp and the reflection dump
    (which the retail blobs do not have at all), so they are dropped; what is
    left is the declarations plus the instruction stream.

    Note this counts distinct INSTRUCTION STREAMS, which is not necessarily the
    same number as distinct blobs -- see project_fold_class_counting. The fold
    gate (G4) is what counts blobs; this number is only a dedup for the sweep,
    and must never be quoted as a fold count.
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
    # 128, not 32 -- hd_ps measured two shadow axes to be invisible below it,
    # and crystal runs the same cascade and cube-shadow code.
    ap.add_argument('--trials', type=int, default=128)
    ap.add_argument('--tol', type=float, default=1e-3)
    # The score is RELATIVE above magnitude 1 (see shader_diff.output_diff);
    # the LIGHT_DEBUG perms output a light count and would otherwise be held to
    # a far stricter standard than their shaded siblings. 0 = absolute.
    ap.add_argument('--rel-scale', type=float, default=1.0,
                    help='magnitude floor for the diff score (0 = absolute)')
    ap.add_argument('--perms', default=None,
                    help='comma-separated perm indices (default: all 512)')
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

        if n and n % 128 == 0:
            print(f"  ...perm {idx} ({len(seen)} classes, "
                  f"worst {worst_all:.1e}, {time.time() - t0:.0f}s)",
                  file=sys.stderr)

    print(f"\n=== crystal_ps 3.0.0: {len(perms)} perms x {args.trials} trials ===")
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
