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

``--target flakes`` packs the WhiteoutFlakes engine target instead
(tools/d3_flakes.py): one bundle per backend, a slot the backend cannot run (or
that is not ported) left null so the engine falls back, and the engine manifest
``d3_flakes_slots.json`` beside them (schema in its ``_schema``).

Metal packs the ``.metallib`` that macOS linked beside each ``.metal``
(tools/metal_compile_libs.py) into the v1.8 MTLB container the engine reads for
Warcraft III's Metal bundles, so ``flakes`` takes it only where those exist. A
Metal run also writes ``d3_flakes_slots.metal.json``, the Metal bundles' own
record; a run without Metal takes Metal's slots from it while its slots still
match, so bundles linked on macOS join the manifest of any host.

Reads:  d3_slang_out/flakes-<api>/<bundle>/slot_<NNNN>.<ext>   (Metal: .metallib)
Writes: bls_out_d3_flakes/shaders/<pixel|vertex>/<dx_5_0|dx_6_0|spv_X_Y|wgsl_1_0|metal>/<domain>.bls
        bls_out_d3_flakes/d3_flakes_slots.json  (+ d3_flakes_slots.metal.json)

Usage:
  python build_d3_bls.py --all [--verify] [--complete]
  python build_d3_bls.py --bundle ps_actor --verify
  python build_d3_bls.py --all --target flakes [--verify]
"""

from __future__ import annotations

import argparse
import hashlib
import json
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
import d3_flakes as F                      # noqa: E402
import d3_perm_manifest as M               # noqa: E402
import d3_retail as R                      # noqa: E402

OUT_ROOT = REPO / 'bls_out_d3_1_14'
FLAKES_ROOT = REPO / 'bls_out_d3_flakes'
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


# --------------------------------------------------------------------------
# the engine target
# --------------------------------------------------------------------------

FLAKES_SCHEMA = (
    'WhiteoutFlakes engine target of d3_shaders (D3_TARGET_FLAKES). bundles[<bundle>]: stage, slot '
    'count, and per target the .bls (relative to this file) whose permutation i is slot i; a null '
    'permutation means fall back. slots[]: one per manifest slot -- bundle, stage, slot, hashes (the '
    'lowercase retail program hashes it reproduces, as in d3_perms/_index.json), backends (targets it '
    'is packed for) and unsupported ({target: reason}). Vertex slots: stream (mesh | particle | '
    'none; element lists under streams), readsBones (declares the BLENDWEIGHT/BLENDINDICES elements: '
    'bind the bone stream), unsuppliable (retail reads the mesh stream gives a stand-in, '
    '"<SEM><idx>.<lanes> (<type>): <stand-in>"). Pixel slots: textures [[register, kind]] (kind 2d, '
    'cube = bind a cube-array view, 2dms, ...), samplers [[register, sampler|comparison]], '
    'maxTexture / maxSampler (-1 = none). Registers are the retail ones (= the pass stage index); '
    'bindings per backend are under bindings.')


def flakes_bundle_path(bid: str, api: str) -> Path:
    stage, domain = bid.split('_', 1)
    name = R.load_config()[domain][stage]['bls_name']
    return FLAKES_ROOT / 'shaders' / STAGE_DIR[stage] / api / name


def _spirv_api(blobs: list) -> str:
    for b in blobs:
        if b and len(b) >= 8 and struct.unpack_from('<I', b, 0)[0] == 0x07230203:
            ver = struct.unpack_from('<I', b, 4)[0]
            return 'spv_%d_%d' % ((ver >> 16) & 0xFF, (ver >> 8) & 0xFF)
    return 'spv'


def flakes_slots(bid: str, target: str, records: dict) -> list:
    """The bundle's blobs in slot order (None = null), noting each slot's backend in
    ``records``."""
    stage = bid.split('_', 1)[0]
    wm = CA.module_mtime()
    blobs = []
    for s in M.load(bid):
        rec = records[(bid, s['slot'])]
        spec, problem = CA.slot_spec(s)
        why = None
        if spec is None:
            why = problem or 'not ported'
        else:
            why = F.unsupported(s['measured'], target, stage, s['program'])
        p = CA.out_path(target, bid, s['slot'])
        if why is None:
            reads = CA.flakes_reads(bid, s['slot'], spec) if stage == 'vs' else {}
            espec = F.engine_spec(spec, s['measured'], target, stage, reads or {})
            stamp = p.with_suffix(p.suffix + '.spec')
            key = repr((espec.key(), F.profile(target, stage, s['measured'])))
            if not p.exists():
                why = 'not built (compile failed)' if p.with_suffix(p.suffix + '.err').exists() else 'not built'
            elif p.stat().st_mtime < wm:
                raise SystemExit('%s is older than the module source -- recompile' % p)
            elif not stamp.exists() or stamp.read_text('utf-8') != key:
                raise SystemExit("%s was not built from this slot's current spec -- recompile" % p)
        if why is None and target == 'flakes-metal':
            # the blob is the library linked from this .metal, never an older one
            lib = p.with_suffix('.metallib')
            if not lib.exists() or lib.stat().st_mtime < p.stat().st_mtime:
                why = 'not linked (tools/metal_compile_libs.py on macOS)'
            elif lib.read_bytes()[:4] != b'MTLB':
                why = 'not a metallib'
            else:
                p = lib
        if why is not None:
            rec['unsupported'][target] = why
            blobs.append(None)
            continue
        blob = p.read_bytes()
        blobs.append(process_dxbc(blob) if target == 'flakes-d3d11' else blob)
        rec['backends'].append(target)
    return blobs


def flakes_pack(target: str, blobs: list) -> bytes:
    cfg = F.TARGETS[target]
    if cfg['backend'] == 'metal':
        return bb.assemble_metal_v18_bls([b or b'' for b in blobs], len(blobs))
    if cfg['backend'] == 'd3d':
        inner = [bb.pack_v14_dx_perm(b) if b else b'' for b in blobs]
    else:
        inner = [bb.pack_blob_perm(b) if b else b'' for b in blobs]
    return bb.build_v14_outer(inner, cfg['tag'], cfg['flags'])


def metal_read_back(path: Path) -> list:
    """Every permutation's metallib (None for a null one) from a v1.8 Metal bundle."""
    data = path.read_bytes()
    if data[:4] != bb.BLS_MAGIC or struct.unpack_from('<HH', data, 4) != (bb.BLS_MINOR, bb.BLS_MAJOR):
        raise ValueError('%s: not a v1.8 BLS' % path)
    _meta, num_perms, off_data, _pad = struct.unpack_from('<4I', data, 8)
    ends = struct.unpack_from('<%dI' % num_perms, data, bb.BLS_FILE_HEADER_SIZE)
    out, start = [], 0
    for end in ends:
        if end == start:
            out.append(None)
            continue
        inner = data[off_data + start:off_data + end]
        n, = struct.unpack_from('<I', inner, 0x20)
        out.append(inner[bb.METAL_PERM_INNER_HEADER_SIZE:bb.METAL_PERM_INNER_HEADER_SIZE + n])
        start = end
    return out


def flakes_read_back(path: Path, dx: bool) -> list:
    """Every permutation's payload (None for a null one) from a written bundle."""
    if dx:
        return read_slots(path)
    data = path.read_bytes()
    off_perms, num_perms, _ob, num_blobs, off_data = struct.unpack_from('<IIIII', data, 12)
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
        n, = struct.unpack_from('<I', inner, 0x20)
        out.append(inner[bb.METAL_PERM_INNER_HEADER_SIZE:bb.METAL_PERM_INNER_HEADER_SIZE + n])
    return out


METAL_RECORD = FLAKES_ROOT / 'd3_flakes_slots.metal.json'
METAL_SCHEMA = (
    "The flakes-metal bundles beside it, as the macOS run that linked them packed them (build_d3_bls.py). "
    "bundles[<bundle>]: slot count and file. slots[]: bundle, slot, hashes, key (digest of the spec the "
    "slot was compiled from, null = not compiled), backends / unsupported as in d3_flakes_slots.json. A run "
    "that does not pack Metal takes a slot's Metal entry from here while bundle, slot, hashes and key match.")


def _metal_key(bid: str, s: dict) -> str | None:
    """Digest of the stamp key a slot's Metal build is made under (None: no build)."""
    stage = bid.split('_', 1)[0]
    spec, _problem = CA.slot_spec(s)
    if spec is None or F.unsupported(s['measured'], 'flakes-metal', stage):
        return None
    reads = CA.flakes_reads(bid, s['slot'], spec) if stage == 'vs' else {}
    espec = F.engine_spec(spec, s['measured'], 'flakes-metal', stage, reads or {})
    key = repr((espec.key(), F.profile('flakes-metal', stage, s['measured'])))
    return hashlib.sha1(key.encode('utf-8')).hexdigest()


def write_metal_record(bids: list, records: dict, files: dict):
    rec = {'_schema': METAL_SCHEMA,
           'bundles': {bid: {'slots': len(M.load(bid)), 'file': files[bid]['flakes-metal']} for bid in bids},
           'slots': []}
    if METAL_RECORD.exists():
        # bundles this run does not pack keep their entries
        old = json.loads(METAL_RECORD.read_text('utf-8'))
        rec['bundles'] = dict({b: v for b, v in old['bundles'].items() if b not in bids}, **rec['bundles'])
        rec['slots'] = [r for r in old['slots'] if r['bundle'] not in bids]
    for (bid, slot) in sorted(records):
        r = records[(bid, slot)]
        rec['slots'].append({'bundle': bid, 'slot': slot, 'hashes': r['hashes'],
                             'key': _metal_key(bid, M.load(bid)[slot]),
                             'backends': [t for t in r['backends'] if t == 'flakes-metal'],
                             'unsupported': {t: w for t, w in r['unsupported'].items() if t == 'flakes-metal'}})
    METAL_RECORD.write_text(json.dumps(rec, indent=1) + '\n', 'utf-8')
    print('  metal record -> %s' % METAL_RECORD.relative_to(REPO))


def carry_metal_record(bids: list, records: dict, files: dict):
    """Metal's slots from the bundles' own record, for a run that does not pack Metal."""
    if not METAL_RECORD.exists():
        return
    old = json.loads(METAL_RECORD.read_text('utf-8'))
    have = {(r['bundle'], r['slot']): r for r in old['slots']}
    for bid in bids:
        b = old['bundles'].get(bid)
        slots = M.load(bid)
        whole = b is not None and b['slots'] == len(slots) and (FLAKES_ROOT / b['file']).exists()
        if whole:
            files[bid]['flakes-metal'] = b['file']
        live = 0
        for s in slots:
            r, o = records[(bid, s['slot'])], have.get((bid, s['slot']))
            if not (whole and o and o['hashes'] == r['hashes'] and o['key'] == _metal_key(bid, s)):
                r['unsupported']['flakes-metal'] = 'stale Metal build (relink on macOS)'
                continue
            if 'flakes-metal' in o['backends']:
                r['backends'].append('flakes-metal')
                live += 1
            else:
                r['unsupported'].update(o['unsupported'])
        print('  %-13s %-11s <- %s  (%d/%d slots)' % ('flakes-metal', bid, METAL_RECORD.relative_to(REPO),
                                                       live, len(slots)))


def build_flakes(bids: list, targets: list, verify: bool) -> list:
    problems = []
    records = {}
    for bid in bids:
        for s in M.load(bid):
            records[(bid, s['slot'])] = dict(F.slot_record(bid, s, None), backends=[], unsupported={})
    files = {bid: {} for bid in bids}
    for target in targets:
        for bid in bids:
            blobs = flakes_slots(bid, target, records)
            api = F.TARGETS[target]['api'] or _spirv_api(blobs)
            out = flakes_bundle_path(bid, api)
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_bytes(flakes_pack(target, blobs))
            files[bid][target] = out.relative_to(FLAKES_ROOT).as_posix()
            live = sum(1 for b in blobs if b)
            print('  %-13s %-11s -> %s  (%d/%d slots)' % (target, bid, out.relative_to(REPO), live, len(blobs)))
            if verify:
                if target == 'flakes-metal':
                    back = metal_read_back(out)
                else:
                    back = flakes_read_back(out, F.TARGETS[target]['backend'] == 'd3d')
                for i, (a, b) in enumerate(zip(blobs, back)):
                    if a != b:
                        problems.append('%s %s slot %d: bytes read back differ' % (target, bid, i))
                    elif a and target == 'flakes-d3d11' and bytes(a[4:20]) != bb.dxbc_hash(bytes(a[20:])):
                        problems.append('%s %s slot %d: container hash does not match' % (target, bid, i))
                if len(back) != len(blobs):
                    problems.append('%s %s: %d slots read back, %d written' % (target, bid, len(back), len(blobs)))
    if 'flakes-metal' in targets:
        write_metal_record(bids, records, files)
    else:
        carry_metal_record(bids, records, files)
    # vertex reads, once per slot (the probe builds are cached)
    for (bid, slot), rec in records.items():
        if rec['stage'] != 'vs':
            continue
        s = M.load(bid)[slot]
        spec, _problem = CA.slot_spec(s)
        if spec is not None:
            rec.update({k: v for k, v in F.slot_record(bid, s, CA.flakes_reads(bid, slot, spec) or {}).items()
                        if k in ('readsBones', 'unsuppliable')})
    manifest = {
        '_schema': FLAKES_SCHEMA,
        'streams': {
            'mesh': [dict(zip(('location', 'semantic', 'index', 'format', 'offset', 'buffer'), e))
                     for e in F.MESH_ELEMENTS],
            'meshStrides': [68, 8],
            'particle': [dict(zip(('location', 'semantic', 'index', 'format', 'offset', 'buffer'), e))
                         for e in F.PARTICLE_ELEMENTS],
            'particleStride': 56,
        },
        'bindings': {
            'd3d': 'CBs b0 CBMain (2384 B), b1 CBBones (12288 B, 256 bones), b2 CBLights (6192 B) per '
                   'stage; texture tN / sampler sN at the retail register',
            'vulkan': 'set 0 CBs (VS b, PS 16+b), set 1 textures (VS t, PS 16+t for t0-t15, 36+(t-16) '
                      'for t16-t19), set 2 samplers (VS s, PS 16+s); interpolant location = retail '
                      'register; no clip distances',
            'webgpu': 'group 0 CBs (VS b, PS 4+b), group 1 textures (VS t, PS 12+t), group 2 '
                      'samplers (VS s, PS 12+s); interpolant location = retail register; no clip distances',
            'metal': 'per stage: CBs [[buffer(b)]] (b0-b2), textures [[texture(t)]] / samplers [[sampler(s)]] '
                     'at the retail register (0-15); vertex elements [[attribute(location)]]; interpolants '
                     '[[user(D3REG_<retail register>)]]; no clip distances',
        },
        'bundles': {bid: {'stage': bid.split('_', 1)[0], 'slots': len(M.load(bid)), 'files': files[bid]}
                    for bid in bids},
        'slots': [records[k] for k in sorted(records)],
    }
    path = FLAKES_ROOT / 'd3_flakes_slots.json'
    path.write_text(json.dumps(manifest, indent=1) + '\n', 'utf-8')
    print('  manifest -> %s  (%d slots)' % (path.relative_to(REPO), len(records)))
    return problems


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--bundle', action='append', default=[])
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--verify', action='store_true')
    ap.add_argument('--complete', action='store_true', help='fail on any unbuilt slot')
    ap.add_argument('--target', default='d3d11',
                    help='d3d11 (the retail bundles), or flakes / flakes-<api>[,...] (the engine target)')
    args = ap.parse_args(argv)
    bids = [R.bundle_id(d, s) for d, s in R.bundles()] if args.all else args.bundle
    if not bids:
        ap.error('pass --bundle <id> or --all')
    if args.target != 'd3d11':
        targets = list(F.TARGETS) if args.target == 'flakes' else args.target.split(',')
        if args.target == 'flakes' and not any((CA.OUT_ROOT / 'flakes-metal').glob('*/slot_*.metallib')):
            # only macOS links Metal; elsewhere its bundles come from the Metal record
            targets.remove('flakes-metal')
        if any(t not in F.TARGETS for t in targets):
            ap.error('unknown engine target in %s' % args.target)
        problems = build_flakes(bids, targets, args.verify)
        for p in problems:
            print('FAIL', p)
        return 1 if problems else 0
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
