"""Differential test of the slang ``sprite_vs`` family against retail bytecode.

A :mod:`shader_diff` driver for the sprite vertex shader (1 perm). This VS is
trivially simple: it passes vertex position straight through to clip space
(``o0.xyz = position``, ``o0.w = 1``) and forwards a UV (``o1.xy``). There are
no constant buffers, no skinning, and no matrices to drive.

Input layout (per the retail "// Input signature"), keyed by ATTR index; the
slang ATTRx10 naming (if any) is resolved by :func:`shader_diff.map_inputs`:

    ATTR0 position (xyz)   ATTR3 uv (xy)

Outputs compared: o0 (SV_Position) and o1 (TEXCOORD0).

Quirk — **Level9 prefix.** Unlike a typical vs_4_0, this retail ``perm_000.asm``
DOES carry a legacy ``vs_2_0`` Level9 block (``add oPos`` / ``mad`` / ``mov
oT0``) *before* the real ``vs_4_0`` block. ``Program.from_file`` would latch onto
that first model line and choke on the ``oPos`` destinations. :func:`load_retail`
splices out the Level9 block (keeping the preceding signature comments) before
parsing. The slang ``.dxbc`` has no Level9 block, so it loads through the normal
:func:`load`.

Run from the repo root::

    python tools/shader_diff_sprite_vs.py
    python tools/shader_diff_sprite_vs.py --trials 200 --tol 1e-6

Expected: MATCH, worst ~0 (bit-identical pass-through). Output regs o0, o1.
"""

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import Program, f2b                        # noqa: E402
from shader_diff import load, compare                       # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "re_shaders" / "sprite_vs"
SLANG_DIR  = REPO / "slang_out" / "d3d11" / "sprite_vs"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 1

OUTPUT_REGS = (0, 1)   # SV_Position, TEXCOORD0

# Legacy Level9 model lines that precede the real vs_4_0 block in retail asm.
_LEVEL9 = ('vs_1_1', 'vs_2_0', 'vs_2_x', 'vs_3_0')


def load_retail(path):
    """Load a retail ``.asm`` as a :class:`Program`, dropping the Level9 block.

    The signature comments come *before* the Level9 asm, so we only splice out
    the model-line-through-body of the vs_2_0 block and hand the rest to the
    normal parser, which then latches onto the real ``vs_4_0`` model line.
    """
    lines = Path(path).read_text(encoding='utf-8', errors='replace').splitlines()
    out = []
    skip = False
    for ln in lines:
        s = ln.strip()
        if s == 'vs_4_0':
            skip = False
        elif s in _LEVEL9:
            skip = True
            continue
        if skip:
            continue
        out.append(ln)
    return Program.from_text('\n'.join(out))


# --- per-semantic inputs (keyed by ATTR index) -----------------------------
# CONCRETE dict per trial so every .get(key) is deterministic regardless of the
# order each shader queries its semantics.

def sprite_vs_inputs(seed):
    r = random.Random(12000 + seed)
    return {
        ("ATTR", 0): [f2b(r.uniform(-4, 4)) for _ in range(3)] + [f2b(1.0)],  # position
        ("ATTR", 3): [f2b(r.uniform(-4, 4)) for _ in range(4)],               # uv
    }


# --- driver ----------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=120)
    ap.add_argument('--tol', type=float, default=1e-6)
    ap.add_argument('--perms', default=None,
                    help='comma-separated perm indices (default: all 1)')
    ap.add_argument('--retail-dir', default=str(RETAIL_DIR))
    ap.add_argument('--slang-dir', default=str(SLANG_DIR))
    ap.add_argument('--decompiler', default=str(DECOMPILER))
    args = ap.parse_args(argv)

    perms = ([int(x) for x in args.perms.split(',')] if args.perms
             else list(range(NPERMS)))
    retail = Path(args.retail_dir); slang = Path(args.slang_dir)

    worst_all = 0.0; diverging = []; dm_total = 0
    for idx in perms:
        prog_r = load_retail(retail / f"perm_{idx:03d}.asm")
        prog_s = load(slang / f"perm_{idx:03d}.dxbc", decompiler=args.decompiler)
        res = compare(prog_s, prog_r, trials=args.trials, output_regs=OUTPUT_REGS,
                      tol=args.tol, inputs_fn=sprite_vs_inputs,
                      cbufs_fn=(lambda s: {}),           # no CBs
                      sysvals_fn=(lambda s: {}))         # VS: no sysvals
        worst_all = max(worst_all, res.worst)
        dm_total += res.discard_mismatches
        if res.worst > args.tol or res.discard_mismatches:
            diverging.append((idx, res.worst, res.discard_mismatches))
            print(f"  DIVERGE perm_{idx:03d}: worst={res.worst:.3e} "
                  f"dm={res.discard_mismatches} at {res.worst_where} (seed {res.worst_seed})")
        else:
            print(f"  MATCH   perm_{idx:03d}: worst={res.worst:.3e}")

    print(f"\n=== sprite_vs: {len(perms)} perms x {args.trials} trials ===")
    print(f"output regs      : {list(OUTPUT_REGS)}  (SV_Position, TEXCOORD0)")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"discard mismatch : {dm_total}")
    print(f"perms diverging  : {len(diverging)}")
    print("ALL MATCH" if not diverging else f"DIVERGING: {[d[0] for d in diverging]}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
