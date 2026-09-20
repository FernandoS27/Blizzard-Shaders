#!/usr/bin/env python3
"""Bundle compiled d3_shaders slots into the eight Diablo III BLS files.

Diablo III ships no BLS templates for this toolchain to follow, so each bundle
(stage x domain) is a template-less **v1.14 DX50** container whose slots are
the bundle's distinct retail programs in manifest order (d3_perms/<bundle>.json).
Every blob goes through ``build_bls.fix_dxbc_signatures`` exactly once and is
re-hashed with ``dxbc_hash``. A slot that is not built yet is written as a null
permutation, so a bundle can be packed while its roots are still landing;
``--complete`` refuses that.

``--verify`` (gate D7) never trusts the packer: it reads the written file back,
extracts every DXBC, recomputes each container hash from the extracted bytes
([[project_dxbc_container_hash]]) and re-runs D2 and D4 on the extracted blobs
against retail -- the bytes that ship, not the bytes that were compiled.

Reads:  d3_slang_out/d3d11/<bundle>/slot_<NNNN>.dxbc
Writes: bls_out_d3_1_14/shaders/<pixel|vertex>/dx_5_0/<domain>.bls

Usage:
  python build_d3_bls.py --all [--verify] [--complete]
  python build_d3_bls.py --bundle ps_actor --verify
"""

from __future__ import annotations

import argparse
import struct
import sys
import tempfile
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / 'tools'))
import build_bls as bb                     # noqa: E402
import compile_all_d3 as CA                # noqa: E402
import d3_perm_manifest as M               # noqa: E402
import d3_retail as R                      # noqa: E402

OUT_ROOT = REPO / 'bls_out_d3_1_14'
STAGE_DIR = {'vs': 'vertex', 'ps': 'pixel'}


def process_dxbc(dxbc: bytes) -> bytes:
    dxbc = bb.fix_dxbc_signatures(dxbc)
    out = bytearray(dxbc)
    out[4:20] = bb.dxbc_hash(bytes(out[20:]))
    return bytes(out)


def bundle_path(bid: str) -> Path:
    stage, domain = bid.split('_', 1)
    name = R.load_config()[domain][stage]['bls_name']
    return OUT_ROOT / 'shaders' / STAGE_DIR[stage] / 'dx_5_0' / name


def build(bid: str, complete: bool):
    wm = CA.module_mtime()
    blobs, missing = [], []
    for s in M.load(bid):
        p = CA.out_path('d3d11', bid, s['slot'])
        if not p.exists():
            missing.append(s['slot'])
            blobs.append(None)
            continue
        if p.stat().st_mtime < wm:
            raise SystemExit('%s is older than the module source -- recompile' % p)
        blobs.append(process_dxbc(p.read_bytes()))
    if complete and missing:
        raise SystemExit('%s: %d slots not built (e.g. %s)' % (bid, len(missing), missing[:8]))
    data = bb.assemble_dx_v14_bls(blobs, bb.PLATFORM_TAG_DX5, bb.FLAGS_DX5)
    out = bundle_path(bid)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(data)
    print('  %-11s -> %s  (%d/%d slots, %#x bytes)'
          % (bid, out.relative_to(REPO), len(blobs) - len(missing), len(blobs), len(data)))
    return out, len(blobs)


def read_slots(path: Path) -> list:
    """Every slot's DXBC bytes (None for a null slot) from a written v1.14 BLS."""
    data = path.read_bytes()
    if data[:4] != bb.BLS_MAGIC:
        raise ValueError('bad magic')
    minor, major = struct.unpack_from('<HH', data, 4)
    if (major, minor) != (bb.BLS_V14_MAJOR, bb.BLS_V14_MINOR):
        raise ValueError('unexpected version v%d.%d' % (major, minor))
    off_perms, num_perms, _off_blobs, num_blobs, off_data = struct.unpack_from('<IIIII', data, 12)
    payload = zlib.decompress(data[off_data:]) if num_blobs else b''
    out, pos, cur = [], 0, off_perms + 4
    for _ in range(num_perms):
        size, = struct.unpack_from('<I', data, cur)
        cur += bb.BLS_V14_PERM_ENTRY
        if size == 0:
            out.append(None)
            continue
        inner = payload[pos:pos + size]
        pos += size
        if inner[0x60:0x64] != b'DXBC':
            raise ValueError('slot %d: no DXBC at inner +0x60' % len(out))
        total, = struct.unpack_from('<I', inner, 0x60 + 24)
        out.append(inner[0x60:0x60 + total])
    if pos != len(payload):
        raise ValueError('slot sizes %d != payload %d' % (pos, len(payload)))
    return out


def verify(bid: str, path: Path, expected: int) -> list:
    import d3_decl_surface as D2
    import d3_diff as DF
    import d3_drivers as DR
    import d3_dxbc as DX
    problems = []
    slots = read_slots(path)
    if len(slots) != expected:
        return ['%s: %d slots in the file, manifest has %d' % (bid, len(slots), expected)]
    manifest = M.load(bid)
    checked = 0
    with tempfile.TemporaryDirectory(prefix='d3bls_') as td:
        for s, blob in zip(manifest, slots):
            if blob is None:
                continue
            if bytes(blob[4:20]) != bb.dxbc_hash(bytes(blob[20:])):
                problems.append('%s slot %d: container hash does not match its bytes' % (bid, s['slot']))
                continue
            dx = Path(td) / ('slot_%04d.dxbc' % s['slot'])
            dx.write_bytes(blob)
            DX.asm_path(dx, refresh=True)
            r0 = s['retail'][0]
            retail = R.key_dxbc(r0)
            # the packed blob's signature indices are already canonical: read it as retail-shaped
            d2 = D2.compare(D2.retail_surface(retail), DX.surface(dx, slang=False))
            if d2:
                problems.append('%s slot %d: D2 on the shipped blob: %s' % (bid, s['slot'], d2[:2]))
            res = DF.compare_slot(DF.Leg.load(retail, slang=False), DF.Leg.load(dx, slang=False),
                                  s['measured'], DR.slot_seed(r0['hash']), DF.input_formats(retail))
            if not res.ok():
                problems.append('%s slot %d: D4 on the shipped blob: %s' % (bid, s['slot'], res.error))
            checked += 1
    print('    verify %-11s %d/%d slots read back, hash + D2 + D4 on shipped bytes: %s'
          % (bid, checked, len(slots), 'OK' if not problems else '%d problem(s)' % len(problems)))
    return problems


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--bundle', action='append', default=[])
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--verify', action='store_true')
    ap.add_argument('--complete', action='store_true', help='fail on any unbuilt slot')
    args = ap.parse_args(argv)
    bids = [R.bundle_id(d, s) for d, s in R.bundles()] if args.all else args.bundle
    if not bids:
        ap.error('pass --bundle <id> or --all')
    problems = []
    for bid in bids:
        path, n = build(bid, args.complete)
        if args.verify:
            problems += verify(bid, path, n)
    for p in problems:
        print('FAIL', p)
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
