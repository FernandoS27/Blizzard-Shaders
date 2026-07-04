"""Differential test of the slang ``sprite_ps`` family against retail bytecode.

A :mod:`shader_diff` driver for the sprite pixel shaders (4 perms). This is the
simplest PS family: a single render target (``o0`` = SV_Target0), one texture
(t0) sampled by one 2D UV varying (TEXCOORD0), no constant buffers and no system
values. The four perms differ only in the color-space conversion applied to the
sampled texel:

    perm_000 / perm_003 : pass-through (``sample -> o0``)
    perm_001            : linear -> sRGB encode  (pow 1/2.4 + cmp/movc split)
    perm_002            : sRGB -> linear decode

One quirk makes it worth a bespoke driver rather than the CLI:

  * **Level9 prefix.** Each retail ``perm_NNN.asm`` begins with a legacy
    ``ps_2_0`` Level9 bytecode block (``texld`` / ``cmp`` / ``abs`` — SM1-3 ops
    the interpreter does NOT support) *before* the real ``ps_4_0`` block.
    ``Program.from_file`` would latch onto that first model line and choke on
    ``texld``. :func:`load_retail` splices out the Level9 block (keeping the
    signature comments, which precede it) before parsing; the parser then
    latches onto the real ``ps_4_0`` model line. The slang ``.dxbc`` has no
    Level9 block, so it loads through the normal :func:`load`.

Both shaders sample the same slot (t0) at the same coord, so the default smooth
:class:`TextureModel` is sufficient; a custom constant-texture model is only
useful to *isolate* texture sensitivity if a divergence appears. Run from the
repo root::

    python tools/shader_diff_sprite_ps.py                 # all 4 perms
    python tools/shader_diff_sprite_ps.py --perms 1,2     # specific perms
    python tools/shader_diff_sprite_ps.py --trials 200

Expected: all 4 perms MATCH, worst ~1e-3 (texture / fp residual). Output reg o0.
"""

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import Program, f2b, TextureModel          # noqa: E402
from shader_diff import load, compare                       # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "re_shaders" / "sprite"
SLANG_DIR  = REPO / "slang_out" / "d3d11" / "sprite_ps"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 4

# Legacy Level9 model lines that precede the real ps_4_0 block in retail asm.
_LEVEL9 = ('ps_1_1', 'ps_1_2', 'ps_1_3', 'ps_1_4', 'ps_2_0', 'ps_2_x', 'ps_3_0')


def load_retail(path):
    """Load a retail ``.asm`` as a :class:`Program`, dropping the Level9 block.

    The signature comments come *before* the Level9 asm, so we only splice out
    the model-line-through-body of the ps_2_0 block and hand the rest to the
    normal parser, which then latches onto the real ``ps_4_0`` model line.
    """
    lines = Path(path).read_text(encoding='utf-8', errors='replace').splitlines()
    out = []
    skip = False
    for ln in lines:
        s = ln.strip()
        if s == 'ps_4_0':
            skip = False
        elif s in _LEVEL9:
            skip = True
            continue
        if skip:
            continue
        out.append(ln)
    return Program.from_text('\n'.join(out))


# --- per-semantic inputs ---------------------------------------------------
# Only TEXCOORD0 (uv) is used; SV_POSITION (reg 0) is declared but never read.
# Build a CONCRETE dict per trial so every .get(key) is deterministic no matter
# the order each shader queries its semantics -- feeding even slightly different
# values per semantic manufactures phantom diffs.

def sprite_inputs(seed):
    r = random.Random(11000 + seed)
    return {
        ("TEXCOORD", 0): [f2b(r.uniform(-4, 4)) for _ in range(4)],   # uv
    }


# --- constant-texture model (for texture-sensitivity isolation) ------------
# Both shaders sample t0 at the same coord, so a divergence cannot come from the
# texture *unless* one shader mishandles a channel. Swapping in a per-slot
# CONSTANT texel removes all coord dependence: if a divergence survives with
# constant textures it is not a sampling/coord issue.

class _ConstTexture(TextureModel):
    def sample(self, slot, coords):
        base = 0.37 + 0.5 * slot
        return [ (base + 0.13 * c) % 1.0 for c in range(4) ]


# --- driver ----------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=120)
    ap.add_argument('--tol', type=float, default=1e-3)
    ap.add_argument('--perms', default=None,
                    help='comma-separated perm indices (default: all 4)')
    ap.add_argument('--const-tex', action='store_true',
                    help='use a per-slot CONSTANT texture (isolate coord/tex sensitivity)')
    ap.add_argument('--retail-dir', default=str(RETAIL_DIR))
    ap.add_argument('--slang-dir', default=str(SLANG_DIR))
    ap.add_argument('--decompiler', default=str(DECOMPILER))
    args = ap.parse_args(argv)

    perms = ([int(x) for x in args.perms.split(',')] if args.perms
             else list(range(NPERMS)))
    retail = Path(args.retail_dir); slang = Path(args.slang_dir)
    tex = _ConstTexture() if args.const_tex else None

    labels = {0: "passthrough", 1: "lin->sRGB", 2: "sRGB->lin", 3: "passthrough"}

    worst_all = 0.0; diverging = []; dm_total = 0
    for idx in perms:
        prog_r = load_retail(retail / f"perm_{idx:03d}.asm")
        prog_s = load(slang / f"perm_{idx:03d}.dxbc", decompiler=args.decompiler)
        res = compare(prog_s, prog_r, trials=args.trials, output_regs=(0,),
                      tol=args.tol, inputs_fn=sprite_inputs,
                      cbufs_fn=(lambda s: {}),           # no CBs
                      sysvals_fn=(lambda s: {}),         # no front-face sysval
                      texture=tex)
        worst_all = max(worst_all, res.worst)
        dm_total += res.discard_mismatches
        tag = f"perm_{idx:03d} ({labels.get(idx, '?')})"
        if res.worst > args.tol or res.discard_mismatches:
            diverging.append((idx, res.worst, res.discard_mismatches))
            print(f"  DIVERGE {tag}: worst={res.worst:.3e} "
                  f"dm={res.discard_mismatches} at {res.worst_where} (seed {res.worst_seed})")
        else:
            print(f"  MATCH   {tag}: worst={res.worst:.3e}")

    print(f"\n=== sprite_ps: {len(perms)} perms x {args.trials} trials"
          f"{' (const-tex)' if args.const_tex else ''} ===")
    print(f"output regs      : [0]  (SV_Target0)")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"discard mismatch : {dm_total}")
    print(f"perms diverging  : {len(diverging)}")
    print("ALL MATCH" if not diverging else f"DIVERGING: {[d[0] for d in diverging]}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
