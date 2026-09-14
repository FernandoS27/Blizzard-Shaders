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

  * **Driven CB discriminants.** cb0[0].x is the alpha-test reference,
    cb0[1] is (fogColor.xyz, fogStart) and cb0[2].xy is (fogEnd, fogDensity).
    Random junk is NOT good enough for the fog rows: a fogStart past the
    sampled depth range makes every mode return "no fog" and the six arms
    become indistinguishable, so the ranges below are picked to straddle the
    band. 3.0.0 re-ordered this bank — 2.0.0 put the three fog scalars in
    cb0[1] and fogColor alone at cb0[2].

Sweeps all 350 perms (retail ``perm_NNN.asm`` %03d vs slang ``perm_NNN.dxbc``)
and compares SV_Target0 (output register 0) only. Run from the repo root::

    python tools/shader_diff_sd_classic_ps.py                # full sweep
    python tools/shader_diff_sd_classic_ps.py --perms 0,349  # specific perms
    python tools/shader_diff_sd_classic_ps.py --trials 128

Expected: all 350 perms MATCH. The default smooth TextureModel is sufficient --
both shaders sample the same slot/coord so no custom model is needed.

**Trial count is coverage, and the fog axis is what sets the floor here.**
Measured retail-against-retail (two SHIPPED perms differing only in fog mode,
so any divergence is that mode alone):

    trials                        8       16       32       64      128
    fog 1 linear    (1 v 0)  6.4e-01  8.2e-01  9.3e-01  9.9e-01  9.9e-01
    fog 2 exp       (2 v 0)  6.7e-01  8.2e-01  8.2e-01  9.5e-01  9.5e-01
    fog 3 expSq     (3 v 0)  9.5e-01  9.5e-01  9.5e-01  1.0e+00  1.0e+00
    fog 5 expBand   (5 v 0)  3.3e-02  7.4e-02  7.4e-02  7.7e-02  9.5e-02
    fog 6 expSqBand (6 v 0)  2.9e-03  1.2e-02  1.2e-02  1.2e-02  1.8e-02
    stage ops    (14/28/...) 5.0e-01 or better at every trial count

Two rows score 0.0 and are supposed to:

    fog 4           (4 v 0)  0.0e+00 at every count — this IS the volumetric
                             fold; retail ships mode 4 as mode 0's bytecode
    alpha test      (7 v 0)  0.0e+00 worst, because a discarded pixel writes
                             no output — the axis is carried by
                             `discard_mismatches` instead, 8 at 32 trials
                             rising to 39 at 128

Mode 6 is the floor that sets the default: at 8 trials it scores 2.9e-03,
only three times the tolerance.

A mode the comparator scores 0.0 on is a mode the gate cannot see at all. The
ranges in :func:`sd_cbufs` are chosen so viewZ straddles the fog band rather
than sitting past fogEnd, where every mode saturates to "no fog" and all six
agree. See ``project_differential_numeric_coverage``.
"""

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import Program, f2b                       # noqa: E402
from shader_diff import load, compare, perm_path                      # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "wc3_re_shaders" / "sd"
SLANG_DIR  = REPO / "slang_out" / "d3d11" / "sd_classic_ps"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 350

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

def _fog_band(seed):
    """The fog band for this trial: (alphaRef, fogColor, fogStart, fogEnd, density).

    Derived once and used by BOTH :func:`sd_cbufs` and :func:`sd_inputs`, so the
    sampled depth can be placed on the band the constants describe. Feeding the
    two independently wastes most trials: past fogEnd every mode has saturated
    and all six agree, so an uncorrelated depth mostly compares "no fog" with
    "no fog".

    One trial in three uses a DEGENERATE band, with fogEnd at or below fogStart.
    That is the only regime in which `fogInvRange`'s SAFE_EPS clamp changes the
    answer, and it is what separates the shipped linear arm from the plausible
    wrong one: retail clamps the range in the DENOMINATOR but keeps the raw
    fogEnd in the numerator. With a band that is always well-formed the two are
    indistinguishable -- the `linear-numerator-clamped` mutation scored ALL
    MATCH at roughly 6e-05 per trial before this was added.
    """
    rng = random.Random(seed * 13 + 5)
    alpha_ref = rng.uniform(0, 1)
    color = [rng.uniform(0, 1) for _ in range(3)]
    fs = rng.uniform(-20, 20)
    if rng.random() < 1.0 / 3.0:
        fe = fs + rng.uniform(-5.0, 0.001)                 # degenerate
    else:
        fe = fs + rng.uniform(0.001, 40.0)                 # well-formed
    density = rng.uniform(0.005, 0.4)
    return alpha_ref, color, fs, fe, density


def sd_inputs(seed):
    r = random.Random(7000 + seed)
    _, _, fs, fe, _ = _fog_band(seed)
    lo, hi = min(fs, fe), max(fs, fe)
    # Two trials in three put the depth ON the band (plus a margin, so both
    # sides of each endpoint are reached); the rest sweep the whole scene range
    # so the far-distance and behind-camera cases stay covered.
    z = (r.uniform(lo - 1.0, hi + 1.0) if r.random() < 2.0 / 3.0
         else r.uniform(-50, 50))
    return {
        ("COLOR", 0):    [f2b(r.uniform(0, 1.5)) for _ in range(4)],   # vertColor
        ("TEXCOORD", 0): [f2b(r.uniform(-2, 2)) for _ in range(4)],    # uv (two pairs)
        ("TEXCOORD", 1): [f2b(r.uniform(-50, 50)), f2b(r.uniform(-50, 50)),
                          f2b(z), f2b(r.uniform(-50, 50))],            # .z = fog depth
    }


# --- constant buffer cb0 (3.0.0: alphaRef | fogColor+start | end+density) --

def sd_cbufs(seed):
    alpha_ref, color, fs, fe, density = _fog_band(seed)
    cb0 = [[0, 0, 0, 0] for _ in range(3)]
    cb0[0][0] = f2b(alpha_ref)                             # alphaRef
    cb0[1][0] = f2b(color[0])                              # fogColor.x
    cb0[1][1] = f2b(color[1])                              # fogColor.y
    cb0[1][2] = f2b(color[2])                              # fogColor.z
    cb0[1][3] = f2b(fs)                                    # fogStart
    cb0[2][0] = f2b(fe)                                    # fogEnd
    cb0[2][1] = f2b(density)                               # fogDensity
    return {0: cb0}


# --- perm feature label (for readable divergence reports) ------------------

def feat(idx):
    # 3.0.0 mixed radix: idx = fog + 7*alpha + 14*t0 + 70*t1.
    fog = idx % 7
    alpha = (idx // 7) % 2
    t0 = (idx // 14) % 5
    t1 = (idx // 70) % 5
    f = [f"T0={t0}", f"T1={t1}", f"fog{fog}"]
    if alpha:
        f.append("AT")
    return "+".join(f)


# --- driver ----------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=128)
    ap.add_argument('--tol', type=float, default=1e-3)
    ap.add_argument('--rel-scale', type=float, default=1.0,
                    help='divergence is scored |a-b| / max(rel_scale, |a|, |b|), '
                         'so the tolerance means the same thing for a modulate2x '
                         'chain near 6 as for a plain sample near 1')
    ap.add_argument('--perms', default=None,
                    help='comma-separated perm indices (default: all 350)')
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
        prog_r = load_retail(perm_path(retail, idx, "asm"))
        prog_s = load(perm_path(slang, idx, "dxbc"), decompiler=args.decompiler)
        res = compare(prog_s, prog_r, trials=args.trials, output_regs=(0,),
                      tol=args.tol, inputs_fn=sd_inputs, cbufs_fn=sd_cbufs,
                      rel_scale=args.rel_scale)
        worst_all = max(worst_all, res.worst)
        dm_total += res.discard_mismatches
        if res.worst > args.tol or res.discard_mismatches:
            diverging.append((idx, res.worst, res.discard_mismatches))
            print(f"  DIVERGE perm_{idx} {feat(idx)}: worst={res.worst:.3e} "
                  f"dm={res.discard_mismatches} (seed {res.worst_seed})")
        if idx % 70 == 0:
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
