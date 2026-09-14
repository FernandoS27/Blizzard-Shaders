"""Differential test of the slang ``imgui_ps`` + ``imgui_vs`` against retail.

Dear ImGui's UI shaders: the VS applies an orthographic projection (cb0) and
passes through uv + vertex colour; the PS samples the font/atlas texture and
multiplies by the vertex colour. Tiny (PS 2 perms, VS 1 perm).

Retail bytecode is extracted from ``war3.w3mod/shaders/{ps,vs}/imgui.bls`` into
``re_shaders/imgui/`` and ``re_shaders/imgui_vs/`` by ``tools/extract_retail_bls.py``
(run that first if those dirs are empty). Each retail perm carries a legacy
Level9 (``ps_2_0`` / ``vs_2_0``, ``Aon9`` chunk) block before the real
``*_4_0`` block, which :func:`load_retail` strips.

    python tools/shader_diff_imgui.py

**imgui_ps perm_000 deliberately deviates from retail** (commit ``40a12b5``,
"Correct Dear Imgui"). Retail sRGB-decodes the MODULATED product
``texel * vertColor``; the slang decodes the vertex colour alone and multiplies
the texel in afterwards, because a texel read through an sRGB SRV is already
linear and decoding it again renders ``ImGui::Image`` draws far too dark. On a
random texture the two therefore diverge (~2.8e-01), and that red is expected.

A deviation that is merely *tolerated* stops being checked, so perm_000 runs
two legs instead of one:

* **white-texel leg** -- RGB texel pinned to 1.0 (the font / solid-white atlas
  that every text and widget draw samples). The two programs are the same
  function there, so this leg must MATCH. It keeps the vertex-colour decode,
  the alpha path and the modulate under the gate.
* **control leg** -- the default texture model. This leg must DIVERGE: if it
  ever matches, either the fix was reverted or the harness stopped reading t0,
  and both deserve to go red.
"""

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dxbc_interp import Program, TextureModel, f2b        # noqa: E402
from shader_diff import load, compare, perm_path                     # noqa: E402

REPO = Path(__file__).resolve().parent.parent
SLANG = REPO / "slang_out" / "d3d11"
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")

# Level9 (SM1-3) model lines that precede the real SM4 block in retail asm.
_LEVEL9 = ('ps_1_1', 'ps_1_2', 'ps_1_3', 'ps_1_4', 'ps_2_0', 'ps_2_x', 'ps_3_0',
           'vs_1_1', 'vs_2_0', 'vs_2_x', 'vs_3_0')


def load_retail(path):
    """Load a retail ``.asm`` dropping the Level9 preamble (keep the real *_4_0)."""
    lines = Path(path).read_text(encoding='utf-8', errors='replace').splitlines()
    out, skip = [], False
    for ln in lines:
        s = ln.strip()
        if s in ('ps_4_0', 'vs_4_0', 'ps_5_0', 'vs_5_0'):
            skip = False
        elif s in _LEVEL9:
            skip = True
            continue
        if not skip:
            out.append(ln)
    return Program.from_text('\n'.join(out))


class WhiteTexelModel(TextureModel):
    """RGB pinned to 1.0, alpha left smooth -- the font / solid-white atlas."""

    def sample(self, slot, coords):
        return [1.0, 1.0, 1.0, super().sample(slot, coords)[3]]


#: perm -> why the slang intentionally differs from retail on a general texel.
KNOWN_DEVIATIONS = {
    0: "sRGB decode applied to the vertex colour only, not the texel (40a12b5)",
}


# --- generators -----------------------------------------------------------

def ps_inputs(seed):
    r = random.Random(100 + seed)
    return {
        ("SV_Position", 0): [f2b(r.uniform(0, 800)) for _ in range(4)],   # unused as pos
        ("TEXCOORD", 0):    [f2b(r.uniform(-1, 2)) for _ in range(4)],     # uv
        ("COLOR", 0):       [f2b(r.uniform(0, 1)) for _ in range(4)],      # vertex colour
    }

def vs_inputs(seed):
    r = random.Random(200 + seed)
    return {
        ("ATTR", 0): [f2b(r.uniform(-500, 500)) for _ in range(2)] + [f2b(0.0), f2b(1.0)],  # pos.xy
        ("ATTR", 1): [f2b(r.uniform(-1, 1)) for _ in range(4)],
        ("ATTR", 2): [f2b(r.uniform(0, 1)) for _ in range(4)],             # colour
        ("ATTR", 3): [f2b(r.uniform(-1, 2)) for _ in range(4)],            # uv
    }

def run_stage(name, retail_dir, slang_dir, nperms, out_regs, inputs_fn, trials, tol):
    # Constant buffers (projection matrix / colour / flags) are read-only and
    # branch-free here, so the default random cbuf generator is fine — both
    # shaders see identical values.
    worst = 0.0; diverging = []
    deviations = KNOWN_DEVIATIONS if name == "imgui_ps" else {}
    for idx in range(nperms):
        prog_r = load_retail(perm_path(retail_dir, idx, "asm"))
        prog_s = load(perm_path(slang_dir, idx, "dxbc"), decompiler=DECOMPILER)

        def run(texture=None):
            return compare(prog_s, prog_r, trials=trials, output_regs=out_regs,
                           tol=tol, inputs_fn=inputs_fn, texture=texture,
                           sysvals_fn=(lambda s: {}))

        if idx in deviations:
            white, control = run(WhiteTexelModel()), run()
            white_ok = white.worst <= tol and not white.discard_mismatches
            control_ok = control.worst > tol
            print(f"    perm_{idx:03d} known deviation: {deviations[idx]}")
            print(f"      white-texel leg worst={white.worst:.3e}  "
                  f"{'MATCH' if white_ok else 'DIVERGE  <-- must match'}")
            print(f"      control leg     worst={control.worst:.3e}  "
                  f"{'DIVERGE (expected)' if control_ok else 'MATCH  <-- deviation vanished'}")
            worst = max(worst, white.worst)
            if not (white_ok and control_ok):
                diverging.append(idx)
            continue

        res = run()
        worst = max(worst, res.worst)
        if res.worst > tol or res.discard_mismatches:
            diverging.append(idx)
    print(f"  {name:<10} {nperms} perms, outs {list(out_regs)}: "
          f"worst={worst:.3e}  {'MATCH' if not diverging else 'DIVERGE '+str(diverging)}")
    return not diverging


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--trials', type=int, default=80)
    ap.add_argument('--tol', type=float, default=1e-3)
    ap.add_argument('--retail-dir', default=None,
                    help='root holding imgui/ and imgui_vs/ '
                         '(default wc3_re_shaders/ — pass re_shaders_old/ for 2.0.0)')
    args = ap.parse_args(argv)

    root = Path(args.retail_dir) if args.retail_dir else REPO / "wc3_re_shaders"
    print("=== imgui (ps + vs) ===")
    ok_ps = run_stage("imgui_ps", root / "imgui", SLANG / "imgui_ps",
                      2, (0,), ps_inputs, args.trials, args.tol)
    ok_vs = run_stage("imgui_vs", root / "imgui_vs", SLANG / "imgui_vs",
                      1, (0, 1, 2), vs_inputs, args.trials, args.tol)
    ok = ok_ps and ok_vs
    print("ALL MATCH" if ok else "DIVERGING")
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
