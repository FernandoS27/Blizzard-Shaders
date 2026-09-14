"""Does each slang vertex shader declare the same INPUT SIGNATURE as retail?

The differential gate (`shader_diff`) aligns vertex inputs by
``(semantic, index)`` so that two shaders which assign registers differently can
still be compared. That is the right call for a numeric comparison — but it
makes the gate blind to two structural properties of the shipped artifact:

  * **the attribute SET.** Retail prunes its input signature per permutation, to
    exactly the attributes that permutation reads: ``hd_vs`` perm 0 declares
    ``ATTR0, ATTR1`` and nothing else. Our slang declares the whole vertex
    struct on every permutation, because the struct is one type and ``TVF``
    gates the *reads* rather than the declarations.
  * **the attribute ORDER.** Slang assigns input registers from member order, so
    a struct written in tidy ascending order produces ``v0..v7`` ascending,
    while retail puts the two skinning streams immediately after position
    (``ATTR0, ATTR5, ATTR6, ATTR1, ...``).

Neither shows up as a divergence, so a family can report ALL MATCH while its
signature looks nothing like the shipped one. This script measures it.

Whether a mismatch is a *defect* depends on how the engine builds its input
layouts, which is not decidable from the bytecode alone: D3D11 validates an
input layout against the VS input signature, so a shader that declares an
element the engine's layout does not provide fails to bind — but if the engine
derives the layout from the shader, extra declarations are harmless. Resolving
that needs the executable (plan item P0.5, currently blocked). Until then this
is a measurement, not a verdict.

Usage::

    python tools/wc3_vs_signature_check.py            # every VS family
    python tools/wc3_vs_signature_check.py hd_vs
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shader_diff import load, perm_path                          # noqa: E402

REPO = Path(__file__).resolve().parent.parent
DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")

# family -> (retail folder, perm count, retail filename width)
FAMILIES = {
    "hd_vs":          ("hd_vs", 72, 3),
    "sd_on_hd_vs":    ("sd_on_hd_vs", 144, 3),
    "sd_highspec_vs": ("sd_highspec_vs", 162, 3),
    "popcorn_vs":     ("popcornfx_vs", 72, 3),
    "terrain_vs":     ("terrain_vs", 8, 3),
    "foliage_vs":     ("foliage_vs", 8, 3),
    "water_vs":       ("water_vs", 1, 3),
    "sprite_vs":      ("sprite_vs", 1, 3),
}


def input_attrs(path: Path) -> tuple[int, ...]:
    """The ATTR indices of a disassembly's input signature, in register order.

    slangc names an input semantic ``ATTR<n*10>`` where fxc emits ``ATTR<n>``
    (the same inflation recorded in `project_dxbc_sig_uninflate`), so exact
    multiples of ten are divided back down. ATTR0 is unambiguous either way.
    """
    out: list[int] = []
    in_sig = False
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("// Input signature:"):
            in_sig = True
            continue
        if line.startswith("// Output signature:"):
            break
        if in_sig and line.startswith("// ATTR"):
            idx = int(line.split()[2])
            out.append(idx // 10 if idx >= 10 and idx % 10 == 0 else idx)
    return tuple(out)


def check(family: str, verbose: bool = False) -> tuple[int, int, int]:
    retail_name, nperms, width = FAMILIES[family]
    slang_dir = REPO / "slang_out" / "d3d11" / family
    retail_dir = REPO / "wc3_re_shaders" / retail_name

    ok = bad = skipped = 0
    first_bad = None
    for i in range(nperms):
        rp = retail_dir / f"perm_{i:0{width}d}.asm"
        sp = slang_dir / f"perm_{i:03d}.asm"
        if not rp.exists():
            skipped += 1          # retail ships fewer perms than we compile
            continue
        # Re-disassemble whenever the .asm is MISSING **or older than the
        # .dxbc beside it**. Only checking existence was a real bug: the build
        # writes .dxbc and a separate step writes .asm, so a tree rebuilt since
        # the last disassembly leaves stale .asm files that this tool then
        # reports on -- measuring a shader that is no longer there. It is the
        # same hazard the fold gate had; `shader_diff.decompile` avoids it by
        # re-running unconditionally.
        dp = perm_path(slang_dir, i, "dxbc")
        stale = (not sp.exists()) or (dp.exists()
                                      and sp.stat().st_mtime < dp.stat().st_mtime)
        if stale:
            try:
                load(dp, decompiler=str(DECOMPILER))
            except Exception:
                skipped += 1
                continue
        if not sp.exists():
            skipped += 1
            continue
        a, b = input_attrs(sp), input_attrs(rp)
        if a == b:
            ok += 1
        else:
            bad += 1
            if first_bad is None:
                first_bad = (i, a, b)

    note = ""
    if skipped:
        note = f"{skipped} perm(s) not comparable"
    print(f"{family:<18}{f'{ok}/{ok + bad}':>12}   {note}")
    if first_bad and (verbose or bad):
        i, a, b = first_bad
        print(f"    first mismatch  perm {i}: slang {a}")
        print(f"    {'':>20}retail {b}")
    return ok, bad, skipped


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("family", nargs="?", choices=sorted(FAMILIES))
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)

    fams = [args.family] if args.family else list(FAMILIES)
    print(f"{'family':<18}{'shape match':>12}")
    total_bad = 0
    for f in fams:
        if not (REPO / "slang_out" / "d3d11" / f).exists():
            print(f"{f:<18}{'-':>12}   not built")
            continue
        _, bad, _ = check(f, args.verbose)
        total_bad += bad
    print(f"\n{total_bad} permutation(s) declare a different input signature than retail.")
    print("This is a MEASUREMENT, not a pass/fail — see the module docstring.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
