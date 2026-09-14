"""Pin a retail shader extraction so a gate result can be reproduced.

``wc3_re_shaders/`` is gitignored: it is the *reference leg* of every
differential gate in this repo, and nothing in version control records what it
contained when a gate went green. That is the precise shape of the failure in
``project_build_artifact_staleness`` — 80% of an SC2 per-slot tree was stale
while every structural gate passed, because each gate recompiled instead of
checking what it was reading.

This writes a small manifest next to the tree recording, per family, the blob
count and a digest over the sorted ``(name, sha1)`` pairs, plus the source
``.bls`` each folder was extracted from. ``--verify`` re-derives it and reports
drift. The manifest is tiny and *is* meant to be committed.

Usage::

    python tools/wc3_retail_manifest.py write                   # wc3_re_shaders/
    python tools/wc3_retail_manifest.py verify
    python tools/wc3_retail_manifest.py write --tree re_shaders_old \\
        --out docs/retail_manifest_2_0_0.json --label "Reforged 2.0.0"
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_TREE = REPO / "wc3_re_shaders"
DEFAULT_OUT = REPO / "docs" / "retail_manifest_3_0_0.json"


def family_digest(folder: Path) -> dict | None:
    """Count + content digest for one extracted family folder."""
    blobs = sorted(folder.glob("perm_*.dxbc"))
    if not blobs:
        return None
    h = hashlib.sha1()
    for b in blobs:
        # Name AND content, so a renumbering is drift even if the bytes are
        # all still present somewhere in the folder.
        h.update(b.name.encode())
        h.update(hashlib.sha1(b.read_bytes()).digest())
    src = None
    idx = folder / "index.csv"
    if idx.exists():
        for line in idx.read_text(errors="replace").splitlines()[:6]:
            m = re.search(r"extracted from (.+)$", line)
            if m:
                src = m.group(1).strip().replace("\\", "/")
                break
    return {"perms": len(blobs), "digest": h.hexdigest(), "source": src}


def build(tree: Path) -> dict[str, dict]:
    out = {}
    for d in sorted(p.parent for p in tree.rglob("perm_*.dxbc")):
        key = d.relative_to(tree).as_posix()
        fam = family_digest(d)
        if fam:
            out[key] = fam
    return out


def cmd_write(args) -> int:
    fams = build(args.tree)
    if not fams:
        print(f"error: no perm_*.dxbc under {args.tree}", file=sys.stderr)
        return 1
    doc = {
        "label": args.label,
        "tree": args.tree.name,
        "families": fams,
        "total_perms": sum(f["perms"] for f in fams.values()),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n",
                        encoding="utf-8")
    print(f"wrote {args.out.relative_to(REPO)}: {len(fams)} families, "
          f"{doc['total_perms']} perms")
    return 0


def cmd_verify(args) -> int:
    if not args.out.exists():
        print(f"error: no manifest at {args.out} — run `write` first",
              file=sys.stderr)
        return 1
    want = json.loads(args.out.read_text(encoding="utf-8"))["families"]
    have = build(args.tree)

    missing = sorted(set(want) - set(have))
    added = sorted(set(have) - set(want))
    drifted = sorted(k for k in set(want) & set(have)
                     if want[k]["digest"] != have[k]["digest"])

    for k in missing:
        print(f"  MISSING  {k:<28} manifest has {want[k]['perms']} perms")
    for k in added:
        print(f"  ADDED    {k:<28} {have[k]['perms']} perms, not in manifest")
    for k in drifted:
        w, h = want[k], have[k]
        detail = (f"{w['perms']} -> {h['perms']} perms" if w["perms"] != h["perms"]
                  else "same count, different bytes")
        print(f"  DRIFTED  {k:<28} {detail}")

    if missing or added or drifted:
        print(f"\nretail tree does NOT match {args.out.name} "
              f"({len(missing)} missing, {len(added)} added, {len(drifted)} drifted)"
              "\nGate results taken against this tree are not comparable with "
              "results recorded under the manifest.")
        return 1
    print(f"retail tree matches {args.out.name}: {len(have)} families, "
          f"{sum(f['perms'] for f in have.values())} perms")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=("write", "verify"))
    ap.add_argument("--tree", type=Path, default=DEFAULT_TREE,
                    help="extraction root (default wc3_re_shaders/)")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT,
                    help="manifest path (default docs/retail_manifest_3_0_0.json)")
    ap.add_argument("--label", default="Reforged 3.0.0",
                    help="human label recorded in the manifest")
    args = ap.parse_args(argv)
    return cmd_write(args) if args.action == "write" else cmd_verify(args)


if __name__ == "__main__":
    sys.exit(main())
