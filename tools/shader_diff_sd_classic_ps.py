"""Differential test of the slang ``sd_classic_ps`` family against retail bytecode.

A :mod:`shader_diff` driver for the SD (classic) pixel shaders. This family is
``ps_4_0`` (SM4) and much simpler than the HD/popcorn sets: a single render
target, one constant buffer (cb0, 3 rows), two textures (t0/t1) and three
varyings (COLOR0 = vertex color, TEXCOORD0 = uv pair, TEXCOORD1 = fog world
depth). No system values (``is_front_face`` is never declared).

Two quirks make it worth a bespoke driver rather than the CLI:

  * **Level9 prefix.** Each retail ``perm_NNN.asm`` begins with a legacy
    ``ps_2_0`` Level9 bytecode block (``dcl t0`` / ``mov oC0, t0``) *before* the
    real ``ps_4_0`` block. ``Program.from_file`` would latch onto that first
    model line and choke on ``oC0``. :func:`load_retail` strips the Level9 block
    (keeping the signature comments, which precede it) before parsing. The slang
    ``.dxbc`` has no Level9 block, so it loads through the normal :func:`load`.

  * **Driven CB discriminants.** cb0[0].x is the alpha-test reference and
    cb0[1] holds fog start/end/density — random junk here still exercises the
    branches fine (the alpha discard is a plain compare), so we just fill cb0
    with sane per-field ranges the way the retail shader expects.

Sweeps all 200 perms (retail ``perm_NNN.asm`` %03d vs slang ``perm_NNN.dxbc``)
and compares SV_Target0 (output register 0) only. Run from the repo root::

    python tools/shader_diff_sd_classic_ps.py                # full sweep
    python tools/shader_diff_sd_classic_ps.py --perms 0,199  # specific perms
    python tools/shader_diff_sd_classic_ps.py --trials 60

Expected: all 200 perms MATCH, worst ~1e-3 (texture / fp residual). The default
smooth TextureModel is sufficient -- both shaders sample the same slot/coord so
no custom model is needed.
"""

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import Program, f2b                       # noqa: E402
from shader_diff import load, compare                      # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "re_shaders" / "sd"
SLANG_DIR  = REPO / "slang_out" / "d3d11" / "sd_classic_ps"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 200

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


# --- per-semantic inputs (Wc3 SD-classic varying conventions) --------------
# CONCRETE dict per trial so every .get(key) is deterministic no matter what
# order each shader queries its semantics -- feeding even slightly different
# values per semantic manufactures phantom diffs.

def sd_inputs(seed):
    r = random.Random(7000 + seed)
    return {
        ("COLOR", 0):    [f2b(r.uniform(0, 1.5)) for _ in range(4)],   # vertColor
        ("TEXCOORD", 0): [f2b(r.uniform(-2, 2)) for _ in range(4)],    # uv (two pairs)
        ("TEXCOORD", 1): [f2b(r.uniform(-50, 50)) for _ in range(4)],  # fog world depth
    }


# --- constant buffer cb0 (3 rows: alphaRef, fog params, fog color) ---------

def sd_cbufs(seed):
    rng = random.Random(seed * 13 + 5)
    cb0 = [[0, 0, 0, 0] for _ in range(3)]
    cb0[0][0] = f2b(rng.uniform(0, 1))                     # alphaRef
    fs = rng.uniform(0, 50)
    fe = fs + rng.uniform(1, 100)
    cb0[1][0] = f2b(fs)                                    # fogStart
    cb0[1][1] = f2b(fe)                                    # fogEnd
    cb0[1][2] = f2b(rng.uniform(0.001, 0.1))              # fogDensity
    cb0[2] = [f2b(rng.uniform(0, 1)) for _ in range(4)]   # fogColor
    return {0: cb0}


# --- perm feature label (for readable divergence reports) ------------------

def feat(idx):
    low = idx & 7
    t0 = (idx // 8) % 5
    t1 = (idx // 40) % 5
    f = [f"T0={t0}", f"T1={t1}"]
    if low & 1:
        f.append("FogL")
    if low & 2:
        f.append("FogE")
    if low & 4:
        f.append("AT")
    return "+".join(f)


# --- driver ----------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=60)
    ap.add_argument('--tol', type=float, default=1e-3)
    ap.add_argument('--perms', default=None,
                    help='comma-separated perm indices (default: all 200)')
    ap.add_argument('--retail-dir', default=str(RETAIL_DIR))
    ap.add_argument('--slang-dir', default=str(SLANG_DIR))
    ap.add_argument('--decompiler', default=str(DECOMPILER))
    args = ap.parse_args(argv)

    perms = ([int(x) for x in args.perms.split(',')] if args.perms
             else range(NPERMS))
    retail = Path(args.retail_dir)
    slang = Path(args.slang_dir)

    worst_all = 0.0
    diverging = []
    dm_total = 0
    for idx in perms:
        prog_r = load_retail(retail / f"perm_{idx:03d}.asm")
        prog_s = load(slang / f"perm_{idx:03d}.dxbc", decompiler=args.decompiler)
        res = compare(prog_s, prog_r, trials=args.trials, output_regs=(0,),
                      tol=args.tol, inputs_fn=sd_inputs, cbufs_fn=sd_cbufs)
        worst_all = max(worst_all, res.worst)
        dm_total += res.discard_mismatches
        if res.worst > args.tol or res.discard_mismatches:
            diverging.append((idx, res.worst, res.discard_mismatches))
            print(f"  DIVERGE perm_{idx} {feat(idx)}: worst={res.worst:.3e} "
                  f"dm={res.discard_mismatches} (seed {res.worst_seed})")
        if idx % 40 == 0:
            print(f"  ...perm {idx} (running worst {worst_all:.1e})", file=sys.stderr)

    n = len(perms) if not isinstance(perms, range) else len(perms)
    print(f"\n=== sd_classic_ps: {n} perms x {args.trials} trials ===")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"discard mismatch : {dm_total}")
    print(f"perms diverging  : {len(diverging)}")
    print("ALL MATCH" if not diverging else f"DIVERGING: {[d[0] for d in diverging]}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
