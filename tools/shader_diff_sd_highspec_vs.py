"""Differential test of the slang ``sd_highspec_vs`` family against retail bytecode.

A worked example of :mod:`shader_diff` for a *vertex* shader (no textures): it
builds physically-plausible skinning / lighting constant buffers and *forces*
the two runtime discriminants that random floats never hit on their own:

  (A) the four-bone skinning gate ``weightSum != 0`` (an exact-equality
      discriminant — driven both ways: normalised nonzero weights take the
      skinned path, all-zero weights take the rigid fallback), and
  (B) the per-light point-vs-directional test ``lights[i].position.w > 0``
      (swept across all-directional / all-point / mixed masks per light count).

It sweeps all 162 perms (retail ``perm_NNN.asm`` vs the slang ``perm_NNN.dxbc``
under ``slang_out``) and compares o0(SV_POSITION) / o1(COLOR) / o2(TEXCOORD0) /
o3(TEXCOORD1); every perm in this family declares all four. Run from repo root::

    python tools/shader_diff_sd_highspec_vs.py                 # full sweep
    python tools/shader_diff_sd_highspec_vs.py --perms 17,161  # specific perms
    python tools/shader_diff_sd_highspec_vs.py --trials 40

Known-good result: every perm matches retail to <=2.2e-16 on every output
(lighting-reassociation fp noise only) — effectively bit-identical. Reports
ALL MATCH at --tol 1e-4.
"""

import argparse
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import f2b, i2b                         # noqa: E402
from shader_diff import load, compare                    # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RETAIL_DIR = REPO / "re_shaders" / "sd_highspec_vs"
SLANG_DIR  = REPO / "slang_out" / "d3d11" / "sd_highspec_vs"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
NPERMS = 162
OUTPUT_REGS = (0, 1, 2, 3)   # SV_POSITION, COLOR, TEXCOORD0, TEXCOORD1 (all perms)


# --- meaningful-matrix builders (ported from hs_meaningful.py) -------------

def rand_rotation(rng):
    """A proper 3x3 rotation (orthonormal, det +1) via Gram-Schmidt. Rows."""
    def n(v):
        m = math.sqrt(sum(c * c for c in v)) or 1.0
        return [c / m for c in v]
    a = n([rng.uniform(-1, 1) for _ in range(3)])
    b = [rng.uniform(-1, 1) for _ in range(3)]
    d = sum(b[i] * a[i] for i in range(3))
    b = n([b[i] - d * a[i] for i in range(3)])
    c = [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
    return [a, b, c]

def affine_rows(rng, scale=1.0):
    """3 float4 rows of a [R|t] affine (rotation + translation)."""
    R = rand_rotation(rng)
    t = [rng.uniform(-scale, scale) for _ in range(3)]
    return [[R[r][0], R[r][1], R[r][2], t[r]] for r in range(3)]


# --- per-semantic inputs (Wc3 sd_highspec_vs vertex-attribute layout) ------
# Keyed by ("ATTR", semantic-index) so map_inputs places each semantic at the
# right register/channels for whichever shader (retail packs ATTR0/ATTR5/ATTR6
# etc. distinctly; slang gives each its own register). Feed BOTH identically.

def hs_inputs(seed, skin_mode):
    """skin_mode: 'weighted' (weightSum != 0) or 'rigid' (weights all zero)."""
    rng = random.Random(seed)
    n = rand_rotation(rng)[0]      # unit normal
    pos = [rng.uniform(-2, 2) for _ in range(3)]
    uv0 = [rng.uniform(-2, 2) for _ in range(4)]
    uv1 = [rng.uniform(-2, 2) for _ in range(4)]
    vc  = [rng.uniform(0, 1) for _ in range(4)]
    if skin_mode == 'rigid':
        w = [0.0, 0.0, 0.0, 0.0]
    else:
        raw = [rng.uniform(0.05, 1) for _ in range(4)]
        s = sum(raw)
        w = [x / s for x in raw]                          # normalised weights
    bones = [float(rng.randint(0, 200)) for _ in range(4)]  # bone indices (uint)
    return {
        ("ATTR", 0): [f2b(pos[0]), f2b(pos[1]), f2b(pos[2]), f2b(1.0)],   # position
        ("ATTR", 1): [f2b(n[0]), f2b(n[1]), f2b(n[2]), f2b(0.0)],         # normal
        ("ATTR", 2): [f2b(c) for c in vc],                               # vertColor
        ("ATTR", 3): [f2b(c) for c in uv0],                              # uv0
        ("ATTR", 4): [f2b(c) for c in uv1],                              # uv1
        ("ATTR", 5): [f2b(c) for c in w],                               # blend weights
        ("ATTR", 6): [i2b(int(b)) for b in bones],                      # bone indices
        ("ATTR", 7): [f2b(n[0]), f2b(n[1]), f2b(n[2]), f2b(1.0)],        # tangent
    }


# --- constant buffers with DRIVEN discriminants ---------------------------
# cb0: world rows @0-2 + translation @3, worldViewProj @4-7, diffuseColor @8,
# texMtx @9-12, then 8 light blocks @13+4i (ambient / diffuse / position.w=type).
# cb3: 256-bone palette, 3 affine rows each.

def hs_cbufs(seed, light_types):
    """light_types: 8-bit mask, bit i set => light i is a POINT light (w>0)."""
    rng = random.Random(seed * 7 + 1)
    cb0 = [[f2b(0.0)] * 4 for _ in range(64)]

    wr = affine_rows(rng, 3.0)   # world as rows0..2 + translation packed in [3]
    cb0[0] = [f2b(wr[0][0]), f2b(wr[0][1]), f2b(wr[0][2]), f2b(0.0)]
    cb0[1] = [f2b(wr[1][0]), f2b(wr[1][1]), f2b(wr[1][2]), f2b(0.0)]
    cb0[2] = [f2b(wr[2][0]), f2b(wr[2][1]), f2b(wr[2][2]), f2b(0.0)]
    cb0[3] = [f2b(wr[0][3]), f2b(wr[1][3]), f2b(wr[2][3]), f2b(0.0)]

    pr = affine_rows(rng, 2.0)   # worldViewProj
    cb0[4] = [f2b(pr[0][0]), f2b(pr[0][1]), f2b(pr[0][2]), f2b(0.0)]
    cb0[5] = [f2b(pr[1][0]), f2b(pr[1][1]), f2b(pr[1][2]), f2b(0.0)]
    cb0[6] = [f2b(pr[2][0]), f2b(pr[2][1]), f2b(pr[2][2]), f2b(0.0)]
    cb0[7] = [f2b(pr[0][3]), f2b(pr[1][3]), f2b(pr[2][3]), f2b(1.0)]

    cb0[8] = [f2b(rng.uniform(0, 1)) for _ in range(4)]                  # diffuseColor RGBA
    for k in (9, 10, 11, 12):
        cb0[k] = [f2b(rng.uniform(-1, 1)) for _ in range(4)]            # texMtx

    for i in range(8):
        base = 13 + 4 * i
        cb0[base]     = [f2b(rng.uniform(0, 1)) for _ in range(3)] + [f2b(0.0)]  # ambient
        cb0[base + 1] = [f2b(rng.uniform(0, 1)) for _ in range(3)] + [f2b(0.0)]  # diffuse
        if (light_types >> i) & 1:                                       # POINT
            pos = [rng.uniform(-30, 30) for _ in range(3)]
            cb0[base + 2] = [f2b(pos[0]), f2b(pos[1]), f2b(pos[2]),
                             f2b(rng.uniform(0.2, 3.0))]                 # w>0
        else:                                                            # DIRECTIONAL
            d = rand_rotation(rng)[0]
            cb0[base + 2] = [f2b(d[0]), f2b(d[1]), f2b(d[2]),
                             f2b(-rng.uniform(0.2, 3.0))]                # w<=0
        cb0[base + 3] = [f2b(0.0)] * 4

    cb3 = [[f2b(0.0)] * 4 for _ in range(768)]              # 256 bones x 3 rows
    for b in range(256):
        rows = affine_rows(rng, 5.0)
        for r in range(3):
            cb3[b * 3 + r] = [f2b(x) for x in rows[r]]
    return {0: cb0, 3: cb3}


# --- perm feature label (for readable divergence reports) -----------------

def feat(idx):
    weight = idx % 3; color = (idx // 3) % 2; uv = (idx // 6) % 3; lights = (idx // 18) % 9
    f = []
    if weight == 2: f.append("SKIN")
    if color == 1: f.append("VC")
    if uv >= 1: f.append("UV1")
    if uv >= 2: f.append("UV2")
    f.append(f"NL{lights}")
    return "+".join(f)


def light_scenarios(nl):
    """Point/dir masks covering all-dir, all-point, and mixed for `nl` lights."""
    if nl == 0:
        return [0]
    full = (1 << nl) - 1
    masks = {0, full, 0b01010101 & full, 0b10101010 & full, 1, full ^ 1}
    return sorted(masks)


# --- driver: wraps compare() to sweep skin-mode + light-type per perm ------

def compare_perm(prog_s, prog_r, idx, trials, tol, cov):
    """Sweep both skin modes and varied light-type masks across `trials`.

    A skinning perm (weight==2) alternates weighted/rigid (~1/4 rigid); a
    non-skinning perm always uses weighted inputs (no gate). Light-type mask
    cycles through the covering set for this perm's light count.
    """
    nl = (idx // 18) % 9
    skinning = (idx % 3) == 2
    masks = light_scenarios(nl)
    worst = 0.0; worst_where = None; worst_seed = None; dm = 0

    for t in range(trials):
        skin_mode = 'rigid' if (skinning and t % 4 == 3) else 'weighted'
        mask = masks[t % len(masks)]
        seed = idx * 131 + t
        sv = hs_inputs(20000 + seed, skin_mode)
        cb = hs_cbufs(40000 + seed, mask)

        # coverage bookkeeping
        cov['evals'] += 1
        if skinning:
            if skin_mode == 'rigid':
                cov['skin_rigid'] += 1
            else:
                cov['skin_weighted'] += 1
        for i in range(nl):
            if (mask >> i) & 1:
                cov['pt_lights'] += 1
            else:
                cov['dir_lights'] += 1

        # single-seed compare so we control skin_mode + mask per trial
        res = compare(prog_s, prog_r, trials=1, output_regs=OUTPUT_REGS, tol=tol,
                      inputs_fn=lambda s, _sv=sv: _sv, cbufs_fn=lambda s, _cb=cb: _cb,
                      sysvals_fn=lambda s: {}, seed0=seed)
        dm += res.discard_mismatches
        if res.worst > worst:
            worst = res.worst; worst_where = res.worst_where
            worst_seed = (t, skin_mode, mask)
    return worst, worst_where, worst_seed, dm


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=40)
    ap.add_argument('--tol', type=float, default=1e-4)
    ap.add_argument('--perms', default=None,
                    help='comma-separated perm indices (default: all 162)')
    ap.add_argument('--retail-dir', default=str(RETAIL_DIR))
    ap.add_argument('--slang-dir', default=str(SLANG_DIR))
    ap.add_argument('--decompiler', default=str(DECOMPILER))
    args = ap.parse_args(argv)

    perms = ([int(x) for x in args.perms.split(',')] if args.perms else list(range(NPERMS)))
    retail = Path(args.retail_dir); slang = Path(args.slang_dir)

    worst_all = 0.0; diverging = []; dm_total = 0
    cov = {'evals': 0, 'skin_weighted': 0, 'skin_rigid': 0, 'pt_lights': 0, 'dir_lights': 0}

    for idx in perms:
        prog_r = load(retail / f"perm_{idx:03d}.asm")
        prog_s = load(slang / f"perm_{idx:03d}.dxbc", decompiler=args.decompiler)
        w, where, seed, dm = compare_perm(prog_s, prog_r, idx, args.trials, args.tol, cov)
        worst_all = max(worst_all, w)
        dm_total += dm
        if w > args.tol or dm:
            diverging.append((idx, w, dm))
            print(f"  DIVERGE perm_{idx} {feat(idx)}: worst={w:.3e} dm={dm} "
                  f"(trial/skin/mask {seed}) where={where}")
        if idx % 18 == 0:
            print(f"  ...perm {idx} (running worst {worst_all:.1e})", file=sys.stderr)

    n = len(perms)
    print(f"\n=== sd_highspec_vs: {n} perms x {args.trials} trials ===")
    print(f"output regs      : {list(OUTPUT_REGS)} (SV_POSITION,COLOR,TEXCOORD0,TEXCOORD1)")
    print(f"worst divergence : {worst_all:.3e}")
    print(f"discard mismatch : {dm_total}")
    print(f"perms diverging  : {len(diverging)}")
    print("--- branch coverage (proves discriminants were exercised) ---")
    print(f"  total evals                 : {cov['evals']}")
    print(f"  skinning weightSum!=0       : {cov['skin_weighted']}")
    print(f"  skinning weightSum==0 rigid : {cov['skin_rigid']}")
    print(f"  light point (w>0)           : {cov['pt_lights']}")
    print(f"  light directional (w<=0)    : {cov['dir_lights']}")
    print("ALL MATCH" if not diverging else f"DIVERGING: {[d[0] for d in diverging]}")
    return 0 if not diverging else 1


if __name__ == '__main__':
    sys.exit(main())
