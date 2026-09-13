"""Differential test of the slang ``hd_vs`` family against retail bytecode.

The Warcraft III Reforged **3.0.0** HD mesh vertex shader: 72 permutations,
indexed by a MIXED-RADIX counter rather than a feature bit mask ::

    index = BONE_BUFFER * 1 + TANGENT * 2 + WEIGHT_INDEX * 4
          + VERTEX_COLOR * 12 + UV_COUNT * 24          radices 2/2/3/2/3

Two of those digits do not mean what they look like -- WEIGHT_INDEX 0 and 1
both mean "no skinning", and BONE_BUFFER is only observable on a skinned mesh
-- so the 72 slots hold 36 distinct programs. This runs every slot anyway and
reports how many distinct comparisons that came to, because a candidate that
folds differently from retail is exactly the bug worth catching.

**The drivers come from** :mod:`wc3_uber_validate`. They are the same
constant-buffer / attribute generators the uber reconstruction was gated with,
and they exist because random floats never reach four of this shader's
branches: the unskinned fall-through (``dot(weights, 1) != 0``), the two
``length > 0`` fallbacks on the normal and tangent, and the ``abs(n.z) < 0.999``
reference-axis pick. Feeding this comparison plain noise would validate the
straight-line transform maths and nothing else. See
``tools/wc3_uber_validate.py`` for what each generator shapes and why.

Outputs compared: all eight registers -- SV_POSITION, COLOR0, TEXCOORD0
(UVs), TEXCOORD1 (view pos + water clip), TEXCOORD2 (normal), TEXCOORD3
(tangent), TEXCOORD10 (world pos), TEXCOORD11 (blight UV).

Run from the repo root::

    python tools/shader_diff_hd_vs.py                 # full sweep
    python tools/shader_diff_hd_vs.py --perms 4,71    # specific perms
    python tools/shader_diff_hd_vs.py --trials 64

Known-good result: ALL MATCH, 36 distinct classes over 72 slots.
"""

import argparse
import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shader_diff import load, compare                    # noqa: E402
from wc3_uber_validate import DRIVERS                     # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "wc3_re_shaders" / "hd_vs"
SLANG_DIR = REPO / "slang_out" / "d3d11" / "hd_vs"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 72

#: SV_POSITION, COLOR, TEXCOORD0/1/2/3, TEXCOORD10, TEXCOORD11.
OUTPUT_REGS = tuple(range(8))

#: ``hd_vs`` driver: attribute + constant-buffer generators and the structured
#: bone palette, shared verbatim with the uber-shader gate.
DRIVER = DRIVERS['hd_vs']


def feat(idx):
    """Human-readable label for a mixed-radix permutation index."""
    bone_buffer = idx % 2
    tangent = (idx // 2) % 2
    weight = (idx // 4) % 3
    color = (idx // 12) % 2
    uv = (idx // 24) % 3
    f = []
    if weight == 2:
        f.append("SKIN" + ("/buf" if bone_buffer else "/cb"))
    if tangent:
        f.append("TAN")
    if color:
        f.append("VC")
    if uv >= 1:
        f.append(f"UV{uv}")
    return "+".join(f) if f else "base"


def body_hash(asm_path):
    """Hash of a disassembly's behavioural content.

    Comment lines carry the disassembler's timestamp and the reflection dump
    (which retail blobs do not have at all), so they are dropped; what is left
    is the signature-free instruction stream plus the declarations.
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
    ap.add_argument('--trials', type=int, default=48)
    ap.add_argument('--tol', type=float, default=1e-4)
    ap.add_argument('--perms', default=None,
                    help='comma-separated perm indices (default: all 72)')
    ap.add_argument('--retail-dir', default=str(RETAIL_DIR))
    ap.add_argument('--slang-dir', default=str(SLANG_DIR))
    ap.add_argument('--decompiler', default=str(DECOMPILER))
    args = ap.parse_args(argv)

    perms = ([int(x) for x in args.perms.split(',')] if args.perms
             else list(range(NPERMS)))
    retail = Path(args.retail_dir)
    slang = Path(args.slang_dir)

    worst_all = 0.0
    diverging = []
    dm_total = 0
    # Two slots that share both hashes pose the same comparison, so the second
    # one is not a sample of the first -- it IS the first. Interpret once.
    seen = {}

    for idx in perms:
        retail_asm = retail / f"perm_{idx:03d}.asm"
        slang_dxbc = slang / f"perm_{idx:03d}.dxbc"
        prog_r = load(retail_asm)
        prog_s = load(slang_dxbc, decompiler=args.decompiler)

        key = (body_hash(retail_asm), body_hash(slang_dxbc.with_suffix('.asm')))
        if key in seen:
            first, res = seen[key]
            if res is not None:
                diverging.append((idx, res[0], res[1]))
                print(f"  DIVERGE perm_{idx:03d} {feat(idx)}: same program as "
                      f"perm_{first:03d}")
            continue

        res = compare(prog_s, prog_r, trials=args.trials,
                      output_regs=OUTPUT_REGS, tol=args.tol, **DRIVER)
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

    print(f"\n=== hd_vs 3.0.0: {len(perms)} perms x {args.trials} trials ===")
    print(f"output regs      : {list(OUTPUT_REGS)}")
    print(f"distinct classes : {len(seen)}   (retail ships 36 unique programs)")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"discard mismatch : {dm_total}")
    print(f"perms diverging  : {len(diverging)}")
    print("ALL MATCH" if not diverging else f"DIVERGING: {[d[0] for d in diverging]}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
