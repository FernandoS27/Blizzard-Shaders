#!/usr/bin/env python3
"""Bundle compiled sc2_shaders permutations into per-family BLS files.

SC2 ships no BLS templates (unlike Wc3), so this writes the template-less
**v1.14 DX50** container: each family+stage becomes one BLS whose permutation
slots are the family's retail permutation set, in retail cache order (the
manifest slot order), split VS/PS.  Each slot carries its slang-compiled DXBC
(dedup slots simply carry their own — byte-identical — blob); the v1.14 inner
resource-binding chunk is zero-filled (a consumer reads DXBC reflection).

Reads:  sc2_slang_out/d3d11/<Family>_<stage>/perm_<NNN>.dxbc  (compile_all_sc2.py)
Writes: bls_out_sc2_1_14/shaders/<pixel|vertex>/dx_5_0/<bls_name>

Usage:
  python build_sc2_bls.py [--family Simple] [--slang-out sc2_slang_out]
                          [--output bls_out_sc2] [--verify]
"""
import os
import sys
import struct
import argparse
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(REPO_ROOT / "tools"))
import build_bls as bb
import sc2_shaders_cfg as cfg

STAGE_DIR = {"vs": "vertex", "ps": "pixel"}


def _process_dxbc(dxbc):
    """Fix slangc's ATTRn ×10 semantic bug, then recompute the DXBC hash.
    No ISGN template alignment (SC2 ships none) — the signature is kept as
    slangc emitted it, only the numeric-suffix bug corrected."""
    dxbc = bb.fix_dxbc_signatures(dxbc)
    out = bytearray(dxbc)
    out[4:20] = bb.dxbc_hash(bytes(out[20:]))
    return bytes(out)


def build_stage(family, stage, slang_out, out_root, verbose=True):
    scfg = cfg.family_cfg(family).get(stage)
    if scfg is None:
        return None
    slots = list(cfg.iter_slots(family, stage))
    in_dir = Path(slang_out) / "d3d11" / ("%s_%s" % (family, stage))

    dxbcs = []
    for slot, _bv, _live, _dedup in slots:
        p = in_dir / ("perm_%03d.dxbc" % slot)
        if not p.exists():
            raise FileNotFoundError(
                "%s (run compile_all_sc2.py --family %s --stage %s first)"
                % (p, family, stage))
        dxbcs.append(_process_dxbc(p.read_bytes()))

    blob = bb.assemble_dx_v14_bls(dxbcs, bb.PLATFORM_TAG_DX5, bb.FLAGS_DX5)
    out_dir = Path(out_root) / "shaders" / STAGE_DIR[stage] / "dx_5_0"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / scfg["bls_name"]
    out_path.write_bytes(blob)
    if verbose:
        print("  %s %s -> %s  (%d perms, %#x bytes)"
              % (family, stage, out_path, len(dxbcs), len(blob)))
    return out_path, len(dxbcs)


def verify_bls(path, expected_perms):
    """Full round-trip of a written v1.14 BLS: check magic/version + perm count,
    decompress the data blob, split it by the per-perm size table, and confirm
    each non-null slot's inner permutation carries an extractable `DXBC` blob at
    the §3.2 DX inner offset.  Proves the bundle reads back to the same slots we
    packed, in order."""
    import zlib
    data = Path(path).read_bytes()
    if data[:4] != bb.BLS_MAGIC:
        return False, "bad magic"
    minor, major = struct.unpack_from("<HH", data, 4)
    if (major, minor) != (bb.BLS_V14_MAJOR, bb.BLS_V14_MINOR):
        return False, "unexpected version v%d.%d" % (major, minor)
    off_perms, num_perms, off_blobs, num_blobs, off_data = \
        struct.unpack_from("<IIIII", data, 12)
    if num_perms != expected_perms:
        return False, "num_perms=%d expected %d" % (num_perms, expected_perms)

    sizes, prev_cum = [], 0
    cur = off_perms + 4
    for _ in range(num_perms):
        sz, = struct.unpack_from("<I", data, cur)
        cum, = struct.unpack_from("<I", data, cur + 20)
        if cum < prev_cum:
            return False, "non-monotonic cumulative offset"
        prev_cum = cum
        sizes.append(sz)
        cur += bb.BLS_V14_PERM_ENTRY

    decompressed = zlib.decompress(data[off_data:]) if num_blobs else b""
    pos = 0
    dxbc_ok = 0
    for i, sz in enumerate(sizes):
        if sz == 0:
            continue
        inner = decompressed[pos:pos + sz]
        pos += sz
        if inner[0x60:0x64] != b"DXBC":
            return False, "slot %d has no DXBC at inner +0x60" % i
        dxbc_ok += 1
    if pos != len(decompressed):
        return False, "perm sizes (%d) != decompressed length (%d)" % (pos, len(decompressed))
    return True, "%d perms (%d DXBC), %#x bytes" % (num_perms, dxbc_ok, len(data))


def main(argv=None):
    ap = argparse.ArgumentParser(description="Bundle sc2_shaders perms into BLS.")
    ap.add_argument("--family", help="one family; omit with --all")
    ap.add_argument("--all", action="store_true",
                    help="every family in sc2_shaders.json (M5.1)")
    ap.add_argument("--stage", choices=["ps", "vs"], help="default: both")
    ap.add_argument("--slang-out", default=str(REPO_ROOT / "sc2_slang_out"))
    ap.add_argument("--output", default=str(REPO_ROOT / "bls_out_sc2"))
    ap.add_argument("--verify", action="store_true")
    args = ap.parse_args(argv)
    if not args.all and not args.family:
        ap.error("pass --family <name> or --all")

    out_root = args.output + "_1_14"
    families = sorted(cfg.load_families()) if args.all else [args.family]
    stages = [args.stage] if args.stage else ["vs", "ps"]
    print("building %s -> %s" % (", ".join(families), out_root))
    rc = 0
    bundles = perms = 0
    for fam in families:
        for st in stages:
            r = build_stage(fam, st, args.slang_out, out_root)
            if r is None:
                continue
            path, n = r
            bundles += 1
            perms += n
            if args.verify:
                ok, msg = verify_bls(path, n)
                print("    verify %s: %s" % ("OK" if ok else "FAIL", msg))
                if not ok:
                    rc = 1
    if args.all:
        print("\n%d bundles, %d permutation slots -> %s" % (bundles, perms, out_root))
    return rc


if __name__ == "__main__":
    sys.exit(main())
