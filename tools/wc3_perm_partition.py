"""Gate G1 — does a family's permutation mapper fold the way retail does?

The retail blobs already tell us which permutations are *the same program*: two
perm indices whose bytecode is identical are, by definition, indices the engine
folded together. A correct mapper must fold them the same way — if
``compile_all_slang.MAPPERS[family]`` produces one specialisation for perms
{4, 5, 6, 7} while retail ships one blob for {4, 5} and another for {6, 7}, the
axis assignment is wrong and no amount of shader-body work will fix it.

That makes this the cheapest possible correctness gate on a port, and the
earliest: it needs **no shader code, no compiler and no interpreter**, only the
retail extraction and the mapper. Run it before writing a single line of slang.
It is what made `hd_ps` land on 203 classes and `hd_vs` on 36.

Two partitions are compared:

* **retail**  — perm indices grouped by normalised disassembly. The generator
  timestamp line is stripped; everything else (including the signature comments)
  is significant.
* **mapper**  — perm indices grouped by the *identity* of the ``PermSpec`` the
  mapper returns: ``(entry, types, defines)``. ``label`` is excluded because it
  is cosmetic, and two perms with identical types and defines compile to
  identical bytecode whatever their labels say.

A mismatch is reported as concrete index sets, not a count, because the shape of
the disagreement is what names the wrong axis: a mapper class that is the *union*
of two retail classes means an axis is missing; the *split* of one means an axis
is being specialised on that the engine treats as dead.

Usage::

    python tools/wc3_perm_partition.py sd_on_hd_ps
    python tools/wc3_perm_partition.py hd_ps --retail wc3_re_shaders/hd
    python tools/wc3_perm_partition.py --all
    python tools/wc3_perm_partition.py crystal_ps --retail-version 2.0.0
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from compile_all_slang import (FAMILY_CONFIGS, MAPPERS,  # noqa: E402
                               RETAIL_DIRS)

# The disassembler stamps the run's date into a comment; nothing else in the
# header varies between two extractions of the same blob.
_GENERATED = re.compile(r"^//\s*using 3Dmigoto")

TREES = {
    "3.0.0": REPO / "wc3_re_shaders",
    "2.0.0": REPO / "re_shaders_old",
}


def normalised_asm(path: Path) -> str:
    """Disassembly text with the generator stamp and blank lines removed."""
    lines = path.read_text(errors="replace").splitlines()
    return "\n".join(l.rstrip() for l in lines
                     if not _GENERATED.match(l) and l.strip() not in ("", "//"))


def perm_index(path: Path) -> int:
    return int(re.search(r"perm_(\d+)", path.name).group(1))


def retail_partition(folder: Path) -> dict[str, list[int]]:
    """{bytecode hash: sorted perm indices} for one retail family folder."""
    out: dict[str, list[int]] = {}
    for asm in sorted(folder.glob("perm_*.asm")):
        out.setdefault(hashlib.sha1(normalised_asm(asm).encode()).hexdigest(),
                       []).append(perm_index(asm))
    for v in out.values():
        v.sort()
    return out


def mapper_partition(family: str, count: int) -> dict[str, list[int]]:
    """{specialisation identity: sorted perm indices} for one family's mapper."""
    mapper = MAPPERS[family]
    out: dict[str, list[int]] = {}
    for idx in range(count):
        spec = mapper(idx)
        key = repr((spec.entry, tuple(spec.types), tuple(sorted(spec.defines))))
        out.setdefault(key, []).append(idx)
    return out


def as_sets(partition: dict[str, list[int]]) -> set[frozenset[int]]:
    return {frozenset(v) for v in partition.values()}


def describe_mismatch(retail: set[frozenset[int]],
                      mapper: set[frozenset[int]], limit: int = 6) -> list[str]:
    """Explain a partition disagreement in terms of what it implies about axes."""
    msgs: list[str] = []
    only_mapper = sorted(mapper - retail, key=lambda s: min(s))
    only_retail = sorted(retail - mapper, key=lambda s: min(s))

    for grp in only_mapper[:limit]:
        # Which retail classes does this mapper class overlap?
        touching = sorted((r for r in retail if r & grp), key=lambda s: min(s))
        if len(touching) > 1:
            msgs.append(
                f"  mapper class {_fmt(grp)} spans {len(touching)} retail classes "
                f"{', '.join(_fmt(t) for t in touching[:3])}"
                f"{' ...' if len(touching) > 3 else ''}\n"
                f"      -> the mapper is MISSING an axis: it treats as identical "
                f"perms the engine compiles differently")
        elif touching and touching[0] > grp:
            msgs.append(
                f"  mapper class {_fmt(grp)} is a SUBSET of retail class "
                f"{_fmt(touching[0])}\n"
                f"      -> the mapper specialises on an axis the engine folds away "
                f"(dead bit not folded)")
        else:
            msgs.append(f"  mapper class {_fmt(grp)} has no retail counterpart")

    for grp in only_retail[:limit]:
        if not any(grp & m for m in mapper):
            msgs.append(f"  retail class {_fmt(grp)} is unreached by the mapper")

    extra = len(only_mapper) + len(only_retail) - min(limit, len(only_mapper)) \
        - min(limit, len(only_retail))
    if extra > 0:
        msgs.append(f"  ... and {extra} further differing classes")
    return msgs


def _fmt(s: frozenset[int], limit: int = 6) -> str:
    v = sorted(s)
    body = ", ".join(str(x) for x in v[:limit])
    return "{" + body + (f", +{len(v) - limit} more" if len(v) > limit else "") + "}"


def check(family: str, retail_dir: Path | None, version: str,
          verbose: bool = True) -> bool:
    cfg = FAMILY_CONFIGS.get(family)
    if cfg is None:
        print(f"{family}: not a family in wc3_shaders.json")
        return False
    folder = retail_dir or (TREES[version] / RETAIL_DIRS.get(family, family))
    if not folder.is_dir():
        print(f"{family:<24} SKIP  (no retail folder at {folder})")
        return True

    rp, mp = retail_partition(folder), mapper_partition(family, cfg.perm_count)
    rs, ms = as_sets(rp), as_sets(mp)
    n_retail_perms = sum(len(v) for v in rp.values())
    match = rs == ms

    if not verbose:
        status = "OK  " if match else "FAIL"
        print(f"{status} {family:<24} retail={len(rs):<5} mapper={len(ms):<5} "
              f"perms {n_retail_perms} vs {cfg.perm_count}")
        return match

    print(f"=== {family} ({version} retail: {folder.name}) ===")
    print(f"  retail perms     : {n_retail_perms}")
    print(f"  config perm_count: {cfg.perm_count}"
          + ("" if n_retail_perms == cfg.perm_count else "   <-- MISMATCH"))
    print(f"  retail classes   : {len(rs)}")
    print(f"  mapper classes   : {len(ms)}")
    print(f"  partition match  : {'YES' if match else 'NO'}")
    if n_retail_perms != cfg.perm_count:
        print("  note: the two partitions cover different index ranges, so the "
              "comparison\n        below is only meaningful once perm_count is "
              "reconciled.")
    if not match:
        print("  --- disagreement ---")
        for line in describe_mismatch(rs, ms):
            print(line)
    return match


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("family", nargs="?", help="family name from wc3_shaders.json")
    ap.add_argument("--all", action="store_true", help="check every family")
    ap.add_argument("--retail", type=Path, default=None,
                    help="explicit retail folder (overrides --retail-version)")
    ap.add_argument("--retail-version", choices=sorted(TREES), default="3.0.0",
                    help="which retail tree to compare against (default 3.0.0)")
    args = ap.parse_args(argv)

    if args.all:
        results = {f: check(f, None, args.retail_version, verbose=False)
                   for f in FAMILY_CONFIGS}
        bad = [f for f, ok in results.items() if not ok]
        print(f"\n{len(results) - len(bad)}/{len(results)} families agree with "
              f"{args.retail_version} retail")
        if bad:
            print(f"disagreeing: {', '.join(bad)}")
        return 1 if bad else 0

    if not args.family:
        ap.error("give a family name or --all")
    return 0 if check(args.family, args.retail, args.retail_version) else 1


if __name__ == "__main__":
    sys.exit(main())
