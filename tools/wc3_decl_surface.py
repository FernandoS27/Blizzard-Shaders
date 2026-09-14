"""Gate G0b -- does a family's compiled slang declare retail's resource surface?

`wc3_perm_partition.py` (G1) asks whether the mapper folds permutations the way
retail does. It is structurally blind to a family with ONE equivalence class: a
1-perm shader folds trivially and "agrees" no matter what its body reads. That is
exactly how five 2.0.0 post-process shaders sat in a tree whose census said 23/29
families agree with 3.0.0 retail -- 3.0.0 had moved their per-draw buffer from
b1 to b3 and nothing else, and no partition can see a bank move.

G0b compares the DECLARATION SURFACE instead, per permutation:

* constant-buffer banks -- the set of bank numbers must be equal, and slang's
  row count must be >= retail's in every bank. Slang declares a bank's full
  struct where fxc-on-Blizzard shrinks it per perm (CB2[31] against CB2[24]),
  which is a known, deliberate, harmless difference. The reverse, slang
  declaring FEWER rows than retail reads, is a real layout error.
  A bank retail declares ``dynamicIndexed`` must match its row count EXACTLY:
  fxc cannot shrink an array it indexes at runtime, so retail's count is the
  array the engine uploads -- a 256-bone palette where retail declares 72
  (`sd_lowspec_vs`) binds a buffer the size of the one it replaced, which the
  differential cannot see because both legs read the same rows.
* textures, structured buffers, UAVs, samplers -- register, dimension, stride
  and sampler mode must match exactly.
* interpolants -- the (semantic, index) SETS of the input and output
  signatures, with slang's x10 semantic numbering undone. Register assignment
  and order are NOT checked here; that is wc3_vs_signature_check.py and the
  per-milestone signature gates.

  One deliberate relaxation: a VERTEX shader whose slang input set is a strict
  SUPERSET of retail's is a warning, not a failure. Retail prunes unread vertex
  attributes per permutation and slang does not -- the known, out-of-scope
  "input-signature reshaping" item (hd_vs, sd_on_hd_vs, sd_highspec_vs,
  popcorn_vs). An attribute retail reads that slang does NOT declare is still a
  failure.

Retail disassembly is an extraction artifact and never goes stale. Slang
disassembly is a BUILD artifact: the .asm beside a .dxbc is written by a
separate step and can be months old (project_fold_class_counting). So a slang
.asm that is missing or older than its .dxbc is re-disassembled first.

Needs no mapper, no compiler and no interpreter, and works at any perm count
including one.

    python tools/wc3_decl_surface.py tonemap_ps
    python tools/wc3_decl_surface.py --all
    python tools/wc3_decl_surface.py foliage_ps --retail-version 2.0.0
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "tools"))

from compile_all_slang import FAMILY_CONFIGS, RETAIL_DIRS   # noqa: E402
from shader_diff import perm_path                           # noqa: E402

DECOMPILER = Path("C:/Tools/3Dmigoto/cmd_Decompiler/cmd_Decompiler.exe")
SLANG_OUT = REPO / "slang_out" / "d3d11"
TREES = {
    "3.0.0": REPO / "wc3_re_shaders",
    "2.0.0": REPO / "re_shaders_old",
}

_CB = re.compile(r"^dcl_constantbuffer CB(\d+)\[(\d+)\]")
_TEX = re.compile(r"^dcl_resource_(\w+)(?: \(([^)]*)\))? t(\d+)(?:, (\d+))?")
_UAV = re.compile(r"^dcl_uav_(\w+)(?: \(([^)]*)\))? u(\d+)(?:, (\d+))?")
_SMP = re.compile(r"^dcl_sampler s(\d+), (\w+)")
_SIG = re.compile(r"^//\s+(\w+)\s+(\d+)\s+[xyzw]+\s+\d+\s")


@dataclass
class Surface:
    banks: dict = field(default_factory=dict)      # bank -> rows
    dynamic: set = field(default_factory=set)      # banks declared dynamicIndexed
    textures: dict = field(default_factory=dict)   # t-reg -> (kind, format, stride)
    uavs: dict = field(default_factory=dict)       # u-reg -> (kind, format, stride)
    samplers: dict = field(default_factory=dict)   # s-reg -> mode
    inputs: frozenset = frozenset()                # {(SEMANTIC, index)}
    outputs: frozenset = frozenset()


def parse_surface(asm: Path) -> Surface:
    s = Surface()
    section = None
    ins, outs = [], []
    for line in asm.read_text(errors="replace").splitlines():
        if line.startswith("// Input signature:"):
            section = ins
            continue
        if line.startswith("// Output signature:"):
            section = outs
            continue
        if not line.startswith("//"):
            section = None
        if section is not None:
            m = _SIG.match(line)
            if m:
                section.append((m.group(1).upper(), int(m.group(2))))
            continue
        # Column 0 only: the Level9 (ps_2_0) preamble retail carries for sprite
        # and imgui indents its `dcl_2d s0` lines, and they are not the SM4
        # surface.
        if (m := _CB.match(line)):
            s.banks[int(m.group(1))] = int(m.group(2))
            if line.rstrip().endswith("dynamicIndexed"):
                s.dynamic.add(int(m.group(1)))
        elif (m := _TEX.match(line)):
            s.textures[int(m.group(3))] = (m.group(1), m.group(2), m.group(4))
        elif (m := _UAV.match(line)):
            s.uavs[int(m.group(3))] = (m.group(1), m.group(2), m.group(4))
        elif (m := _SMP.match(line)):
            s.samplers[int(m.group(1))] = m.group(2)
    s.inputs, s.outputs = _deflate(ins), _deflate(outs)
    return s


def _deflate(sig):
    """Undo slang's x10 semantic-index inflation (see shader_diff.is_x10_inflated)."""
    idx = [i for _, i in sig]
    inflated = bool(idx) and max(idx) >= 10 and all(i % 10 == 0 for i in idx)
    return frozenset((n, i // 10 if inflated else i) for n, i in sig)


def diff_surface(slang: Surface, retail: Surface,
                 stage: str = "ps") -> tuple[list[str], list[str]]:
    """(failures, warnings) explaining how the two surfaces disagree."""
    out, warn = [], []
    if set(slang.banks) != set(retail.banks):
        out.append(f"cb banks slang={sorted(slang.banks)} retail={sorted(retail.banks)}")
    for b in sorted(set(slang.banks) & set(retail.banks)):
        if slang.banks[b] < retail.banks[b]:
            out.append(f"CB{b} rows slang={slang.banks[b]} < retail={retail.banks[b]}")
        elif b in retail.dynamic and slang.banks[b] != retail.banks[b]:
            out.append(f"CB{b} dynamicIndexed rows slang={slang.banks[b]} != retail={retail.banks[b]}")
    for name, a, r in (("t", slang.textures, retail.textures),
                       ("u", slang.uavs, retail.uavs),
                       ("s", slang.samplers, retail.samplers)):
        for reg in sorted(set(a) | set(r)):
            if a.get(reg) != r.get(reg):
                out.append(f"{name}{reg} slang={a.get(reg)} retail={r.get(reg)}")
    for name, a, r in (("inputs", slang.inputs, retail.inputs),
                       ("outputs", slang.outputs, retail.outputs)):
        if a == r:
            continue
        msg = f"{name} slang-only={sorted(a - r)} retail-only={sorted(r - a)}"
        if name == "inputs" and stage == "vs" and a > r:
            warn.append(msg + "  (VS attribute pruning)")
        else:
            out.append(msg)
    return out, warn


def _fresh_slang_asm(dxbc: Path) -> Path:
    asm = dxbc.with_suffix(".asm")
    if not asm.exists() or asm.stat().st_mtime < dxbc.stat().st_mtime:
        subprocess.run([str(DECOMPILER), "-d", str(dxbc)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return asm


def slang_surfaces(family: str, count: int, jobs: int = 12) -> dict[int, Surface]:
    d = SLANG_OUT / family
    paths = {i: perm_path(d, i, "dxbc") for i in range(count)}
    missing = [i for i, p in paths.items() if not p.exists()]
    if missing:
        raise FileNotFoundError(f"{family}: {len(missing)} slang blobs missing "
                                f"(first perm {missing[0]}) -- build it first")
    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        asms = dict(zip(paths, ex.map(_fresh_slang_asm, paths.values())))
    return {i: parse_surface(a) for i, a in asms.items()}


def retail_surfaces(folder: Path) -> dict[int, Surface]:
    out = {}
    for asm in folder.glob("perm_*.asm"):
        out[int(re.search(r"perm_(\d+)", asm.name).group(1))] = parse_surface(asm)
    return out


@dataclass
class Verdict:
    family: str
    perms: int
    matched: int
    problems: dict          # perm -> [reasons]
    note: str = ""
    warned: int = 0         # perms whose only difference is a tolerated one

    @property
    def ok(self) -> bool:
        return not self.problems and not self.note


def check(family: str, version: str = "3.0.0",
          slang: dict[int, Surface] | None = None) -> Verdict:
    cfg = FAMILY_CONFIGS[family]
    folder = TREES[version] / RETAIL_DIRS.get(family, family)
    if not folder.is_dir():
        return Verdict(family, 0, 0, {}, note=f"no retail folder {folder}")
    retail = retail_surfaces(folder)
    slang = slang if slang is not None else slang_surfaces(family, cfg.perm_count)
    note = ""
    if len(retail) != cfg.perm_count:
        note = f"perm_count {cfg.perm_count} but {version} retail ships {len(retail)}"
    problems, warned = {}, 0
    n = min(len(retail), cfg.perm_count)
    for i in range(n):
        reasons, warnings = diff_surface(slang[i], retail[i], cfg.stage)
        if reasons:
            problems[i] = reasons
        elif warnings:
            warned += 1
    return Verdict(family, cfg.perm_count, n - len(problems), problems, note, warned)


def report(v: Verdict, verbose: bool, limit: int = 4) -> None:
    status = "OK  " if v.ok else "FAIL"
    tail = f"  ({v.note})" if v.note else ""
    if v.warned:
        tail += f"  [{v.warned} perm(s) VS attribute pruning only]"
    print(f"{status} {v.family:<24} surface {v.matched}/{v.perms}{tail}")
    if verbose or not v.ok:
        # Group identical reason lists so a 128-perm bank move prints once.
        groups: dict[tuple, list[int]] = {}
        for i, rs in v.problems.items():
            groups.setdefault(tuple(rs), []).append(i)
        for rs, idxs in list(groups.items())[:limit]:
            head = ", ".join(str(i) for i in idxs[:6]) + (" ..." if len(idxs) > 6 else "")
            print(f"       {len(idxs)} perm(s) [{head}]:")
            for r in rs[:6]:
                print(f"         {r}")
        if len(groups) > limit:
            print(f"       ... and {len(groups) - limit} more distinct reason sets")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("family", nargs="?")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--retail-version", choices=sorted(TREES), default="3.0.0")
    args = ap.parse_args(argv)
    fams = list(FAMILY_CONFIGS) if args.all else [args.family]
    if not fams[0]:
        ap.error("give a family name or --all")
    bad = []
    for f in fams:
        v = check(f, args.retail_version)
        report(v, verbose=not args.all)
        if not v.ok:
            bad.append(f)
    if args.all:
        print(f"\n{len(fams) - len(bad)}/{len(fams)} families declare the "
              f"{args.retail_version} retail surface")
        if bad:
            print(f"differing: {', '.join(bad)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
