#!/usr/bin/env python3
"""Static interface check of the engine target's Metal build (``flakes-metal``).

Nothing on this host runs or even links Metal, so this reads the ``.metal`` source
slangc wrote for every built slot and checks the entry point against what the
engine's Metal device binds (src/gfx/metal: per-stage argument tables, VS slot N
at index N and PS slot N at index N; textures / samplers 0-15; vertex buffer
slot S at [[buffer(16 + S)]], one MTLVertexDescriptor attribute per input-layout
element in element order):

* buffers: only the three CBs, at ``[[buffer(b)]]`` -- CBMain 0, CBBones 1,
  CBLights 2 -- below the vertex-buffer indices;
* textures / samplers at ``[[texture(t)]]`` / ``[[sampler(s)]]``, a register the
  slot declares, below 16, never one index twice; a cube is a ``texturecube_array``;
* vertex input: ``[[attribute(location)]]`` of the engine element list with its
  type, the bone elements only (and always) on a slot that reads them;
* interpolants: float4 ``[[user(D3REG_<register>)]]``, a vertex shader writing
  every retail register of its slot (Metal rejects a pipeline whose fragment
  input the vertex function does not write), a pixel shader reading only its
  slot's; ``[[position]]``, no clip distances; pixel outputs ``[[color(n)]]`` /
  ``[[depth(any)]]`` as the slot declares.

And once per run, the constant buffers' layout under Metal against the HLSL
layout, from slangc reflection, member by member and stride by stride: the
engine uploads one byte image per CB for every backend (CBMain 2384 B, CBBones
12288 B, CBLights 6192 B). Slots a Metal build cannot hold are listed.

    python tools/d3_flakes_metal_check.py --all [--bundle ps_actor] [--slot N]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
import compile_all_d3 as CA               # noqa: E402
import compile_all_slang as cas           # noqa: E402
import d3_flakes as F                     # noqa: E402
import d3_perm_manifest as M              # noqa: E402
import d3_retail as R                     # noqa: E402
import d3_shaders_cfg as C                # noqa: E402

TARGET = 'flakes-metal'
#: CB index and the byte image the engine uploads
BANKS = {'CBMain': (0, 2384), 'CBBones': (1, 12288), 'CBLights': (2, 6192)}
#: the device's per-stage texture / sampler range (metal_handles.h kSrvBindingCount)
MAX_INDEX = F.MAX_REGISTER['metal']
_MESH_TYPES = {0: 'float3', 1: 'float3', 2: 'float4', 3: 'float4', 4: 'float4', 5: 'uint4', 6: 'float4',
               7: 'uint4'}
_PARTICLE_TYPES = {0: 'float3', 1: 'float4', 2: 'float4', 3: 'uint4', 4: 'uint4', 5: 'uint4', 6: 'uint4',
                   7: 'uint4', 8: 'float4'}
#: retail texture dimension -> the Metal type the engine's view matches
_TEXTURE_TYPE = {'texture2d': 'texture2d', 'texturecube': 'texturecube_array'}

_ATTR = re.compile(r'\[\[\s*(\w+)\s*(?:\(([^)]*)\))?\s*\]\]')
_ENTRY = re.compile(r'^\[\[(vertex|fragment)\]\]\s+(\w+)\s+(\w+)\((.*)\)\s*$', re.M)


def _split_params(text: str) -> list:
    out, depth, cur = [], 0, ''
    for ch in text:
        if ch in '<(':
            depth += 1
        elif ch in '>)':
            depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur.strip())
            cur = ''
            continue
        cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def _decl(text: str) -> tuple:
    """``(type, name, attribute, argument)`` of ``<type> <name> [[attr(arg)]]``."""
    m = _ATTR.search(text)
    head = text[:m.start()].strip() if m else text.strip()
    ty, _, name = head.rpartition(' ')
    return ty.strip(), name, m.group(1) if m else None, m.group(2) if m else None


def _struct(src: str, name: str) -> list:
    m = re.search(r'^struct %s\s*\{(.*?)^\};' % re.escape(name), src, re.M | re.S)
    if not m:
        return []
    return [_decl(line.strip().rstrip(';')) for line in m.group(1).splitlines()
            if line.strip() and not line.strip().startswith('#')]


def check_slot(bid: str, s: dict, src: str) -> list:
    stage = bid.split('_', 1)[0]
    m = s['measured']
    tag = '%s:%d' % (bid, s['slot'])
    bad = []
    entries = _ENTRY.findall(src)
    want = 'vertex' if stage == 'vs' else 'fragment'
    if len(entries) != 1 or entries[0][0] != want:
        return ['%s: %d entry point(s), wanted one [[%s]]' % (tag, len(entries), want)]
    _kind, result, _name, params = entries[0]
    texregs = {int(r[1:]): dim for r, k, dim, _c, _n in m['resources'] if k == 'texture'}
    sampregs = {int(r[1:]) for r, k, _d, _c, _n in m['resources'] if k == 'sampler'}
    regs = {reg for n, _i, reg, _m, _s, _c in m['transport'] if not n.startswith('SV_')}
    seen = {}
    stage_in = None
    for p in _split_params(params):
        ty, name, attr, arg = _decl(p)
        if attr in ('buffer', 'texture', 'sampler'):
            idx = int(arg)
            if (attr, idx) in seen:
                bad.append('%s: [[%s(%d)]] bound twice (%s, %s)' % (tag, attr, idx, seen[(attr, idx)], name))
            seen[(attr, idx)] = name
        if attr == 'stage_in':
            stage_in = ty
        elif attr == 'buffer':
            cb = re.match(r'SLANG_ParameterGroup_(\w+?)_\d+ constant\*$', ty)
            if not cb or cb.group(1) not in BANKS or BANKS[cb.group(1)][0] != idx:
                bad.append('%s: %s %s at [[buffer(%d)]]' % (tag, ty, name, idx))
        elif attr == 'texture':
            want_ty = _TEXTURE_TYPE.get(texregs.get(idx))
            if idx not in texregs or idx > MAX_INDEX[stage] or not ty.startswith((want_ty or '?') + '<'):
                bad.append('%s: %s %s at [[texture(%d)]], slot declares %s'
                           % (tag, ty, name, idx, sorted(texregs.items())))
        elif attr == 'sampler':
            if idx not in sampregs or idx > MAX_INDEX[stage] or ty != 'sampler':
                bad.append('%s: %s %s at [[sampler(%d)]], slot declares %s' % (tag, ty, name, idx, sorted(sampregs)))
        elif not (attr == 'position' and stage == 'ps'):
            bad.append('%s: unexpected entry parameter %s' % (tag, p))
    # vertex input
    if stage == 'vs':
        kind = F.stream_kind(m)
        spec, _p = CA.slot_spec(s)
        skinned = kind == 'mesh' and F.reads_bones(CA.flakes_reads(bid, s['slot'], spec) or {})
        types = _PARTICLE_TYPES if kind == 'particle' else _MESH_TYPES
        attrs = {}
        for ty, name, attr, arg in (_struct(src, stage_in) if stage_in else []):
            if attr != 'attribute':
                bad.append('%s: vertex input %s %s [[%s]]' % (tag, ty, name, attr))
                continue
            attrs[int(arg)] = ty
            if types.get(int(arg)) != ty or (kind == 'mesh' and int(arg) >= 6 and not skinned):
                bad.append('%s: vertex input %s at [[attribute(%s)]]' % (tag, ty, arg))
        if kind == 'none' and attrs:
            bad.append('%s: no stream, but vertex inputs %s' % (tag, sorted(attrs)))
        if skinned and not {6, 7} <= set(attrs):
            bad.append('%s: reads bones but declares %s' % (tag, sorted(attrs)))
    # interpolants and outputs
    varyings = _struct(src, result) if stage == 'vs' else (_struct(src, stage_in) if stage_in else [])
    users = set()
    for ty, name, attr, arg in varyings:
        if attr == 'position' and stage == 'vs':
            continue
        um = re.fullmatch(r'D3REG_(\d+)', arg or '') if attr == 'user' else None
        if not um or ty != 'float4' or int(um.group(1)) not in regs:
            bad.append('%s: interpolant %s %s [[%s(%s)]]' % (tag, ty, name, attr, arg))
            continue
        users.add(int(um.group(1)))
    if stage == 'vs' and users != regs:
        bad.append('%s: writes registers %s, its slot declares %s' % (tag, sorted(users), sorted(regs)))
    if stage == 'ps':
        targets = {i for n, i, _r, _m, _s, _c in m.get('outputs') or [] if n == 'SV_TARGET'}
        depth = any(n.startswith('SV_DEPTH') for n, *_ in m.get('outputs') or [])
        colors, wrote_depth = set(), False
        for ty, name, attr, arg in _struct(src, result):
            if attr == 'color':
                colors.add(int(arg))
            elif attr == 'depth':
                wrote_depth = True
            else:
                bad.append('%s: pixel output %s %s [[%s]]' % (tag, ty, name, attr))
        if colors != targets or wrote_depth != depth:
            bad.append('%s: outputs color %s depth %s, slot declares %s %s'
                       % (tag, sorted(colors), wrote_depth, sorted(targets), depth))
    return bad


# --------------------------------------------------------------------------
# constant buffer layouts
# --------------------------------------------------------------------------

def _flatten(t: dict, base: int, path: str, out: dict):
    if t['kind'] == 'struct':
        for f in t['fields']:
            _flatten(f['type'], base + f['binding']['offset'], '%s.%s' % (path, f['name']), out)
    elif t['kind'] == 'array':
        out[path + '[]'] = (base, t['elementCount'], t['uniformStride'])
        _flatten(t['elementType'], base, path + '[0]', out)
    else:
        out[path] = base


def cb_layouts(refl: dict) -> dict:
    """``{cb: (index, size, {member path: offset | (offset, count, stride)})}``."""
    out = {}
    for p in refl['parameters']:
        if p['name'] in BANKS:
            el = p['type']['elementVarLayout']
            members = {}
            _flatten(el['type'], 0, p['name'], members)
            out[p['name']] = (p['binding']['index'], el['binding']['size'], members)
    return out


def check_cbs(bid: str, s: dict) -> list:
    """The three CBs under Metal against HLSL, compiled from one slot's spec."""
    stage = bid.split('_', 1)[0]
    spec, _p = CA.slot_spec(s)
    reads = CA.flakes_reads(bid, s['slot'], spec) if stage == 'vs' else {}
    espec = F.engine_spec(spec, s['measured'], TARGET, stage, reads or {})
    layouts = {}
    with tempfile.TemporaryDirectory(prefix='d3mc_') as td:
        for target, profile, ext in (('metal', 'sm_6_0', 'metal'), ('hlsl', '%s_5_0' % stage, 'hlsl')):
            out = Path(td) / ('cb.%s' % ext)
            js = Path(td) / ('cb_%s.json' % target)
            if not cas.invoke_slangc(espec.entry, target, profile, list(espec.specialize), out, C.MODULE,
                                     extra=['-reflection-json', str(js)], include_dirs=[C.INCLUDE],
                                     defines=list(espec.defines)) or not js.exists():
                return ['cb layout: slangc %s reflection of %s:%d failed' % (target, bid, s['slot'])]
            layouts[target] = cb_layouts(json.loads(js.read_text('utf-8')))
    bad = []
    for cb, (index, size) in BANKS.items():
        mt, hl = layouts['metal'].get(cb), layouts['hlsl'].get(cb)
        if not mt or not hl:
            bad.append('cb layout: %s missing from the reflection' % cb)
            continue
        mine = []
        if mt[0] != index:
            mine.append('cb layout: %s at [[buffer(%d)]], wanted %d' % (cb, mt[0], index))
        if mt[1] != size or hl[1] != size:
            mine.append('cb layout: %s is %d B on Metal, %d B in HLSL, the engine uploads %d B'
                        % (cb, mt[1], hl[1], size))
        for path in sorted(set(mt[2]) | set(hl[2])):
            if mt[2].get(path) != hl[2].get(path):
                mine.append('cb layout: %s Metal %s, HLSL %s' % (path, mt[2].get(path), hl[2].get(path)))
        print('  %-8s [[buffer(%d)]] %5d B, %3d offsets / strides: Metal %s HLSL'
              % (cb, mt[0], mt[1], len(mt[2]), '==' if not mine else '!='))
        bad += mine
    return bad


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--bundle', action='append', default=[])
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--slot', action='append', type=int, default=[])
    args = ap.parse_args(argv)
    bids = [R.bundle_id(d, s) for d, s in R.bundles()] if args.all else args.bundle
    if not bids:
        ap.error('pass --bundle <id> or --all')
    bad, checked, null, first = [], 0, [], None
    for bid in bids:
        stage = bid.split('_', 1)[0]
        for s in M.load(bid):
            if args.slot and s['slot'] not in args.slot:
                continue
            spec, _p = CA.slot_spec(s)
            why = spec is not None and F.unsupported(s['measured'], TARGET, stage)
            if why:
                null.append('%s:%d (%s)' % (bid, s['slot'], why))
                continue
            src = CA.out_path(TARGET, bid, s['slot'])
            if spec is None or not src.exists():
                continue
            bad += check_slot(bid, s, src.read_text('utf-8'))
            checked += 1
            first = first or (bid, s)
    if first:
        bad += check_cbs(*first)
    for p in bad[:60]:
        print('  ' + p)
    print('null on Metal: %d slot(s)%s' % (len(null), ''.join('\n  ' + n for n in null)))
    print('metal static: %d slot(s), %s' % (checked, 'clean' if not bad else '%d problem(s)' % len(bad)))
    return 1 if bad or not checked else 0


if __name__ == '__main__':
    sys.exit(main())
