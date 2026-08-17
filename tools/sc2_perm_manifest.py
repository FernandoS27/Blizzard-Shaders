#!/usr/bin/env python3
"""Per-family permutation manifests for the sc2_shaders module.

The retail baselinecache stores every family's *vertex and pixel* permutations
under one family schema hash (bytes 8..11 of the decoded key vec).  The stage is
NOT in bytes 8..11 - it is a per-family boolean field elsewhere in the key vec
(1 = pixel, 0 = vertex; the engine's b_iPixelShader-style stage axis).  We recover
that field's byte index per family from ground truth and classify by the key alone:

  1. walk the D3D cache records in physical order,
  2. classify FAMILY via sc2_ps_layout.family_of (bytes 8..11),
  3. determine STAGE from the per-family stage byte in the key vec.  The byte
     index is learned once from the non-dedup records, whose true stage is known
     cheaply from the blob D3D9 version token (non-dedup blob[9] & 1: 1=ps, 0=vs).
     The learned classifier reproduces the Metal name-catalog split exactly for the
     14 small/medium families; the 4 Default families carry a few more VS perms in
     D3D than Metal (PS matches).  Instant - no blob decompression, no dedup
     resolution.
  4. decode each key to its (b_*, live) feature vector with the stage schema,
  5. emit  sc2_perms/<Family>_<ps|vs>.json  - an ordered list whose index is the
     retail permutation slot.

This is the enumerator half of the sc2_shaders validation pipeline
(see docs/SC2_SHADERS_MODULE_DESIGN.md).  The (b_*, live) decode is exact for
the DefaultPixelMain families (Model/Particle/Ribbon/Foliage) via
sc2_model_key_decode.decode_ps; other families and every VS carry the raw decoded
vector until their schema is named (decode_vs / per-family PS schema).
"""
import os
import sys
import json
import argparse

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import sc2_cache
import sc2_ps_layout as layout
import sc2_d3d_decode as d3d

PERMS_DIR = os.path.join(os.path.dirname(HERE), "sc2_perms")

# Families whose PS uses DefaultPixelMain and whose PS key decode is validated.
DEFAULT_PS_FAMILIES = {"Model", "Particle", "Ribbon", "Foliage"}


def learn_stage_indices(data, recs, *, verbose=True):
    """Per family, find the key-vec byte index that is 1 for pixel and 0 for vertex.

    Ground truth for the learn set = non-dedup records, whose stage is the blob's
    D3D9 version token (blob[9] & 1: odd=ps, even=vs).  Returns {family: index}.
    """
    from collections import defaultdict
    truth = defaultdict(list)  # family -> [(stage, vec)]
    for r in recs:
        off = r["blob_off"]
        if data[off] != 0:            # only non-dedup carry a decodable version bit
            continue
        _, vec = sc2_cache.decode_key(r["key"])
        fam = layout.family_of(vec)
        if fam is None:
            continue
        stage = "ps" if (data[off + 9] & 1) else "vs"
        truth[fam[0]].append((stage, bytes(vec)))

    idx = {}
    for fam, rows in truth.items():
        has_ps = any(s == "ps" for s, _ in rows)
        has_vs = any(s == "vs" for s, _ in rows)
        if not has_ps:
            idx[fam] = ("ps", None)   # family is pixel-only in the learn set
            continue
        if not has_vs:
            idx[fam] = ("vs", None)   # (never observed; kept for symmetry)
            continue
        best = None
        ml = min(len(v) for _, v in rows)
        for i in range(ml):
            psv = set(v[i] for s, v in rows if s == "ps")
            vsv = set(v[i] for s, v in rows if s == "vs")
            if psv == {1} and vsv == {0}:
                best = i
                break
        idx[fam] = (None, best)
    if verbose:
        print("  stage indices learned for %d families" % len(idx))
    return idx


def stage_of(vec, fam_idx):
    """Classify a record's stage from the per-family stage byte."""
    fixed, i = fam_idx
    if fixed is not None:
        return fixed
    if i is None or i >= len(vec):
        return "?"
    b = vec[i]
    return "ps" if b == 1 else ("vs" if b == 0 else "?")


def _decode_perm(family, stage, vec):
    """Per-slot manifest payload beyond {slot,key,dedup}.

    Storage is deliberately COMPACT for the Default families (Model/Particle/
    Ribbon/Foliage): their (bv, live) is huge (~780 axes) and fully recoverable
    from the stored key via sc2_family_decode.decode_perm, so the manifest keeps
    only the key and the drivers decode on demand (a 50k-slot Model manifest with
    materialised bv would be gigabytes).  Small schema families (Simple, ...) DO
    store bv/live inline for at-a-glance inspection; undecodable families keep the
    raw vec."""
    import sc2_family_decode as fd
    if stage == "ps" and family in fd.DEFAULT_PS_FAMILIES:
        return {}                       # compact — decode from key on demand
    if stage == "vs" and family in fd.DEFAULT_VS_FAMILIES:
        return {}                       # ditto: the VS shares the family schema
    r = fd.decode_perm(family, stage, vec)
    if r is not None:
        bv, live = r
        return {"bv": bv, "live": sorted(live)}
    return {"vec": list(vec)}


def build_manifests(families=None, *, verbose=True):
    data, _ver, recs = sc2_cache.parse_cache(d3d.D3D_CACHE)
    if verbose:
        print("cache: %d records" % len(recs))
    fam_idx = learn_stage_indices(data, recs, verbose=verbose)

    from collections import defaultdict
    groups = defaultdict(list)   # (family, stage) -> [(rec, vec)]
    for r in recs:
        _, vec = sc2_cache.decode_key(r["key"])
        fam = layout.family_of(vec)
        if fam is None:
            continue
        name = fam[0]
        if families and name not in families:
            continue
        st = stage_of(vec, fam_idx.get(name, (None, None)))
        groups[(name, st)].append((r, vec))

    import sc2_family_decode as fd
    os.makedirs(PERMS_DIR, exist_ok=True)
    written = []
    for (name, st), items in sorted(groups.items()):
        perms = []
        for slot, (r, vec) in enumerate(items):
            e = {"slot": slot, "key": r["key"].hex(), "dedup": int(data[r["blob_off"]] == 1)}
            e.update(_decode_perm(name, st, vec))
            perms.append(e)
        # decodable = the unified decode yields (bv, live) for this (family, stage),
        # independent of whether the manifest stores it inline (compact Default
        # families store only the key but are fully decodable on demand).
        decoded = bool(items) and fd.decode_perm(name, st, items[0][1]) is not None
        out = {
            "family": name, "stage": st, "count": len(perms),
            "stage_index": fam_idx.get(name, (None, None))[1],
            "decoded": decoded,
            "perms": perms,
        }
        path = os.path.join(PERMS_DIR, "%s_%s.json" % (name, st))
        json.dump(out, open(path, "w"), indent=0)
        written.append((name, st, len(perms), out["decoded"]))
    if verbose:
        print("\nwrote %d manifests to %s:" % (len(written), PERMS_DIR))
        for name, st, n, dec in sorted(written):
            print("  %-16s %-3s %7d perms  decoded=%s" % (name, st, n, dec))
    return written


def main(argv=None):
    ap = argparse.ArgumentParser(description="Build sc2_shaders per-family perm manifests.")
    ap.add_argument("--family", action="append", help="limit to family (repeatable)")
    args = ap.parse_args(argv)
    build_manifests(set(args.family) if args.family else None)


if __name__ == "__main__":
    main()
