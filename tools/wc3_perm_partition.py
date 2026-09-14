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
    python tools/wc3_perm_partition.py --all --check-banks
    python tools/wc3_perm_partition.py crystal_ps --retail-version 2.0.0

**G1 is not a census on its own.** A family with one equivalence class folds
trivially and passes whatever its body does -- which is how five 2.0.0
post-process shaders read ``OK retail=1 mapper=1`` in a tree whose census said
23/29 families agree with 3.0.0. ``--check-banks`` adds gate G0b
(``tools/wc3_decl_surface.py``): the per-permutation declaration surface of the
slang build against retail's, which sees a bank move at any perm count. With
``--all`` it also prints a per-family VERSION verdict:

* ``identical``  -- retail ships byte-identical blobs in 2.0.0 and 3.0.0, so
  there is nothing version-specific to port;
* ``3.0.0``      -- the slang surface matches 3.0.0 retail on every perm;
* ``2.0.0``      -- it matches 2.0.0 retail instead: a stale family;
* ``neither``    -- it matches no tree (mid-port, or a family whose index
  space changed between versions, so a same-index comparison means nothing);
* ``3.0.0-only`` -- no 2.0.0 extraction exists and G0b fails against 3.0.0.

A family is OK only when G1 matches AND its version verdict is ``3.0.0`` or
``identical``.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "tools"))

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


def retail_identical(family: str) -> bool | None:
    """Do 2.0.0 and 3.0.0 retail ship the same blob for every perm index?

    None when either tree has no folder for this family.
    """
    sub = RETAIL_DIRS.get(family, family)
    old, new = TREES["2.0.0"] / sub, TREES["3.0.0"] / sub
    if not (old.is_dir() and new.is_dir()):
        return None

    def blobs(d: Path) -> dict[int, str]:
        return {perm_index(p): hashlib.sha1(p.read_bytes()).hexdigest()
                for p in d.glob("perm_*.dxbc")}
    return blobs(old) == blobs(new)


def version_verdict(family: str):
    """(label, 3.0.0 G0b verdict) -- labels are described in the module docstring."""
    import wc3_decl_surface as G0b
    cfg = FAMILY_CONFIGS[family]
    slang = G0b.slang_surfaces(family, cfg.perm_count)
    new = G0b.check(family, "3.0.0", slang)
    same = retail_identical(family)
    if same is None:
        return ("3.0.0" if new.ok else "3.0.0-only"), new
    if same:
        return "identical", new
    if new.ok:
        return "3.0.0", new
    old = G0b.check(family, "2.0.0", slang)
    return ("2.0.0" if old.ok else "neither"), new


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
    ap.add_argument("--check-banks", action="store_true",
                    help="also run gate G0b (declaration surface); with --all, "
                         "print a per-family version verdict")
    args = ap.parse_args(argv)

    if args.all:
        results = {}
        for f in FAMILY_CONFIGS:
            ok = check(f, None, args.retail_version, verbose=False)
            if args.check_banks:
                label, g0b = version_verdict(f)
                fine = label in ("3.0.0", "identical")
                ok = ok and fine
                # The line above is G1 alone; this one carries the verdict.
                print(f"  => {'OK  ' if ok else 'FAIL'} {'':<19} G0b {g0b.matched}/"
                      f"{g0b.perms}  version {label}"
                      f"{'' if fine else '  <-- NOT ON 3.0.0'}")
            results[f] = ok
        bad = [f for f, ok in results.items() if not ok]
        what = ("are on 3.0.0 (G1 + G0b)" if args.check_banks
                else f"agree with {args.retail_version} retail")
        print(f"\n{len(results) - len(bad)}/{len(results)} families {what}")
        if bad:
            print(f"disagreeing: {', '.join(bad)}")
        if not args.check_banks:
            print("note: G1 alone cannot see single-class families; "
                  "add --check-banks for a census")
        return 1 if bad else 0

    if not args.family:
        ap.error("give a family name or --all")
    ok = check(args.family, args.retail, args.retail_version)
    if args.check_banks:
        import wc3_decl_surface as G0b
        v = G0b.check(args.family, args.retail_version)
        G0b.report(v, verbose=True)
        ok = ok and v.ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
