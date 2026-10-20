#!/usr/bin/env python3
"""Behaviour of the engine target's Vulkan and WebGPU builds, through D3D11.

The engine-target gate (tools/d3_flakes_gate.py) runs the D3D11 build; nothing
here can execute SPIR-V or WGSL. So each sampled slot's ``flakes-vulkan`` SPIR-V,
and its ``flakes-webgpu`` WGSL taken to SPIR-V by naga, is translated back to
HLSL by spirv-cross, compiled by fxc and run in the same interpreter against
retail, fed exactly as the engine would bind it:

* vertex inputs by LOCATION (the engine element list), interpolants by location
  = retail register (pixel inputs are rebuilt register by register from D4's
  per-semantic values), outputs read back the same way;
* every CB, texture and sampler found by its SET and BINDING in the SPIR-V
  reflection, which must be the engine's (set 0 / 1 / 2, the stage's offset plus
  the retail register), never by name.

So this checks what the D3D11 gate cannot: the CB layouts and matrix majorness
slang emitted for the backend, the binding numbers and the location linkage. A
translated program is fxc-compiled from spirv-cross's HLSL, so it may legitimately
land order-only where the D3D11 build is exact; anything else is a failure. Clip
distances are not declared on these backends and are not compared.

``--static`` instead checks the interface of EVERY built slot of both backends
from its reflection: vertex inputs at the engine element locations and types (the
bone elements only on a slot that reads them), interpolants float4 at a location
below 16, every resource in its set at its stage offset plus a register the slot
declares, nothing else bound.

    python tools/d3_flakes_xcheck.py --all --sample 12 [--jobs N]
    python tools/d3_flakes_xcheck.py --all --static
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import traceback
from collections import Counter
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
import d3_diff as DF                      # noqa: E402
import d3_drivers as DR                   # noqa: E402
import d3_dxbc as DX                      # noqa: E402
import d3_flakes as F                     # noqa: E402
import d3_flakes_gate as G                # noqa: E402
import d3_perm_manifest as M              # noqa: E402
import d3_retail as R                     # noqa: E402
import dxbc_interp as DI                  # noqa: E402

_CH = {'x': 0, 'y': 1, 'z': 2, 'w': 3}
#: CB bank index by name, as types/cbuffers.slang declares them
BANK = {'CBMain': 0, 'CBBones': 1, 'CBLights': 2}
#: engine element location by the semantic the gate's engine view names
MESH_LOC = {(sem, 0): loc for loc, sem, _i, _f, _o, _b in F.MESH_ELEMENTS}
PARTICLE_LOC = {(sem, 0): loc for loc, sem, _i, _f, _o, _b in F.PARTICLE_ELEMENTS}


def fxc_path() -> str:
    found = shutil.which('fxc')
    if found:
        return found
    kits = sorted(Path(r'C:\Program Files (x86)\Windows Kits\10\bin').glob('*/x64/fxc.exe'))
    if not kits:
        raise RuntimeError('fxc.exe not found')
    return str(kits[-1])


def raw_rdef(blob: bytes) -> dict:
    """``{name: register}`` of a DXBC's bound resources, names unstripped."""
    body = DX.chunks(blob)['RDEF']
    _ncb, _cbo, nres, res_off = struct.unpack_from('<IIII', body, 0)
    out = {}
    for i in range(nres):
        name_off, typ, _ret, _dim, _ns, bind, _cnt, _flags = struct.unpack_from('<IIIIIIII', body, res_off + i * 32)
        prefix = {0: 'cb', 2: 't', 3: 's'}.get(typ, 'u')
        out[DX._cstr(body, name_off)] = (prefix, bind)
    return out


def translate(spv: Path, stage: str, work: Path) -> tuple:
    """SPIR-V -> (DXBC path, spirv-cross reflection)."""
    refl = json.loads(subprocess.run(['spirv-cross', str(spv), '--reflect'], capture_output=True, text=True,
                                     check=True).stdout)
    hlsl = work / (spv.stem + '.hlsl')
    subprocess.run(['spirv-cross', str(spv), '--hlsl', '--shader-model', '50', '--hlsl-auto-binding', 'all',
                    '--output', str(hlsl)], capture_output=True, text=True, check=True)
    dxbc = work / (spv.stem + '.dxbc')
    r = subprocess.run([fxc_path(), '/nologo', '/T', '%s_5_0' % stage, '/E', 'main', '/Fo', str(dxbc), str(hlsl)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError('fxc: %s' % (r.stderr or r.stdout).strip().splitlines()[-1])
    return dxbc, refl


class _RemapBanks:
    def __init__(self, banks, remap):
        self.banks, self.remap = banks, remap

    def __getitem__(self, slot):
        return self.banks[self.remap[slot]]


class _RemapTextures:
    """The gate's texture model addressed by the translated program's t-slots
    (an adapter: the model calls its own ``sample`` from ``sample_compare``)."""

    def __init__(self, inner, remap):
        self.inner, self.remap = inner, remap
        self.dims = inner.dims

    def sample(self, slot, coords):
        return self.inner.sample(self.remap[slot], coords)

    def sample_lod(self, slot, coords, lod):
        return self.inner.sample_lod(self.remap[slot], coords, lod)

    def sample_compare(self, slot, coords, ref):
        return self.inner.sample_compare(self.remap[slot], coords, ref)

    def lod(self, slot, coords):
        return self.inner.lod(self.remap[slot], coords)


class CrossLeg(G.FlakesLeg):
    """A translated Vulkan / WebGPU program, fed by location and binding."""

    @classmethod
    def build(cls, dxbc: Path, refl: dict, backend: str, measured: dict, stage: str, cube: frozenset) -> tuple:
        problems = []
        prog = DI.Program.from_file(DX.asm_path(dxbc, refresh=True))
        blob = dxbc.read_bytes()
        # bindings: every resource by set + binding, checked against the engine's scheme
        cb_base, tex_base, samp_base = F.SHIFT[backend] if stage == 'ps' else (0, 0, 0)
        by_name = {}
        for kind, want_set, letter in (('ubos', 0, None), ('separate_images', 1, 'T'), ('separate_samplers', 2, 'S')):
            for r in refl.get(kind, []):
                if r.get('set') != want_set:
                    problems.append('%s %s in set %s, not %d' % (kind, r['name'], r.get('set'), want_set))
                reg = (r['binding'] - cb_base if letter is None
                       else F.binding_register(backend, stage, letter, r['binding']))
                by_name[r['name']] = (kind, reg)
        for kind in ('ssbos', 'storage_images', 'push_constants', 'textures', 'images', 'acceleration_structures'):
            if refl.get(kind):
                problems.append('unexpected %s: %s' % (kind, [r.get('name') for r in refl[kind]]))
        declared = {int(reg[1:]) for reg, k, _d, _c, _n in measured['resources'] if k == 'texture'}
        banks, texs = {}, {}
        for name, (prefix, bind) in raw_rdef(blob).items():
            kind, reg = by_name.get(name, (None, None))
            if prefix == 'cb':
                if kind != 'ubos' or reg not in (0, 1, 2):
                    problems.append('cbuffer %s at binding offset %s' % (name, reg))
                banks[bind] = reg if reg in (0, 1, 2) else 0
            elif prefix == 't':
                if kind != 'separate_images' or reg not in declared:
                    problems.append('texture %s at register %s, retail declares %s' % (name, reg, sorted(declared)))
                texs[bind] = reg
        # outputs keyed by retail semantic through location = register
        osgn = {(n, i): reg for n, i, reg, _m, _s, _c in DX.signature(blob, 'OSGN')}
        out_keys, depth = {}, False
        if stage == 'vs':
            for name, idx, reg, mask, _s, _c in measured['transport']:
                if name == 'SV_CLIPDISTANCE':
                    continue
                at = osgn.get(('SV_POSITION', 0)) if name == 'SV_POSITION' else osgn.get(('TEXCOORD', reg))
                if at is None:
                    continue
                for k, ch in enumerate(mask):
                    out_keys[(name, idx, k)] = (at, _CH[ch])
        else:
            for name, idx, reg, mask, _s, _c in measured.get('outputs') or []:
                if name.startswith('SV_DEPTH'):
                    depth = True
                    continue
                at = osgn.get(('SV_TARGET', idx))
                for k, ch in enumerate(mask):
                    out_keys[(name, idx, k)] = (at, _CH[ch])
        leg = cls(prog, False, cube, out_keys, depth)
        leg.view, leg.measured, leg.stage = 'engine', measured, stage
        leg.banks_map, leg.tex_map, leg.backend = banks, texs, backend
        return leg, problems

    def run(self, seed, regime, formats, *, overrides=None, trace=None, wide=False):
        base = 'R0' if regime in ('T', 'N') else regime
        centre = None
        if self.stage == 'vs':
            packed = G.Packed(seed, self.measured, base)
            loc = PARTICLE_LOC if packed.kind == 'particle' else MESH_LOC
            sem = {('TEXCOORD', loc[k]): v for k, v in packed.engine().items()}
        else:
            per = DR.Inputs(seed, formats, base)
            sem = {}
            for name, idx, reg, mask, _s, _c in self.measured['transport']:
                if name == 'SV_CLIPDISTANCE':
                    continue
                v = per.get((name, idx))
                if name == 'SV_POSITION':
                    sem[('SV_POSITION', 0)] = v
                    continue
                lanes = sem.setdefault(('TEXCOORD', reg), [0, 0, 0, 0])
                for k, ch in enumerate(mask):
                    lanes[_CH[ch]] = v[k]
            if base == 'R4':
                tcs = sorted(i for n, i in formats if n == 'TEXCOORD')
                if tcs:
                    centre = [DI.b2f(b) for b in per.get(('TEXCOORD', tcs[0]))[:2]]
        tex = _RemapTextures(G.Textures(seed, base, self.cube, centre), self.tex_map)
        banks = _RemapBanks(DR.Banks(seed, base, overrides), self.banks_map)
        return DI.execute(self.prog, self.inputs(G._Sem(sem), DR.sysvals(seed)), banks, texture=tex,
                          deriv_scale=0.0, trace=trace, wide=wide, ieee=True)


#: SPIR-V reflection type of each engine element, by location
_MESH_TYPES = {0: 'vec3', 1: 'vec3', 2: 'vec4', 3: 'vec4', 4: 'vec4', 5: 'uvec4', 6: 'vec4', 7: 'uvec4'}
_PARTICLE_TYPES = {0: 'vec3', 1: 'vec4', 2: 'vec4', 3: 'uvec4', 4: 'uvec4', 5: 'uvec4', 6: 'uvec4',
                   7: 'uvec4', 8: 'vec4'}


def static_check(job):
    """Interface problems of one slot's Vulkan and WebGPU builds."""
    bid, slot = job
    import compile_all_d3 as CA
    s = M.load(bid)[slot]
    stage = bid.split('_', 1)[0]
    m = s['measured']
    row = {'bid': bid, 'slot': slot, 'problems': []}
    spec, _p = CA.slot_spec(s)
    reads = CA.flakes_reads(bid, slot, spec) if stage == 'vs' else {}
    skinned = stage == 'vs' and F.stream_kind(m) == 'mesh' and F.reads_bones(reads or {})
    texregs = {int(r[1:]) for r, k, _d, _c, _n in m['resources'] if k == 'texture'}
    sampregs = {int(r[1:]) for r, k, _d, _c, _n in m['resources'] if k == 'sampler'}
    with tempfile.TemporaryDirectory(prefix='d3xs_') as td:
        for backend, target in (('vulkan', 'flakes-vulkan'), ('webgpu', 'flakes-webgpu')):
            src = CA.out_path(target, bid, slot)
            if not src.exists():
                continue
            spv = src
            if backend == 'webgpu':
                spv = Path(td) / 'w.spv'
                subprocess.run(['naga', str(src), str(spv)], capture_output=True, check=True)
            refl = json.loads(subprocess.run(['spirv-cross', str(spv), '--reflect'], capture_output=True,
                                             text=True, check=True).stdout)
            bad = row['problems']
            tag = '%s %s:%d' % (backend, bid, slot)
            cb = F.SHIFT[backend][0] if stage == 'ps' else 0
            top = F.MAX_REGISTER[backend][stage]
            for kind, want_set, letter, allowed in (('ubos', 0, None, {0, 1, 2}), ('separate_images', 1, 'T', texregs),
                                                    ('separate_samplers', 2, 'S', sampregs)):
                for r in refl.get(kind, []):
                    if letter is None:
                        ok = r['binding'] - cb in allowed
                    else:
                        reg = F.binding_register(backend, stage, letter, r['binding'])
                        ok = (reg in allowed and reg <= top
                              and F.register_binding(backend, stage, letter, reg) == r['binding'])
                    if r.get('set') != want_set or not ok:
                        bad.append('%s: %s %s at set %s binding %s' % (tag, kind, r['name'], r.get('set'), r['binding']))
            for kind in ('ssbos', 'storage_images', 'push_constants', 'textures', 'images'):
                if refl.get(kind):
                    bad.append('%s: unexpected %s' % (tag, kind))
            seen = Counter((r.get('set'), r['binding']) for kind in ('ubos', 'separate_images', 'separate_samplers')
                           for r in refl.get(kind, []))
            bad += ['%s: two resources at set %s binding %s' % (tag, st, b) for (st, b), n in seen.items() if n > 1]
            if stage == 'vs':
                want = _PARTICLE_TYPES if F.stream_kind(m) == 'particle' else _MESH_TYPES
                for r in refl.get('inputs', []):
                    if want.get(r['location']) != r['type'] or (r['location'] >= 6 and want is _MESH_TYPES and not skinned):
                        bad.append('%s: vertex input %s at location %s' % (tag, r['type'], r['location']))
                if skinned and not {6, 7} & {r['location'] for r in refl.get('inputs', [])}:
                    bad.append('%s: reads bones but declares no bone element' % tag)
            regs = {reg for n, _i, reg, _m, _s, _c in m['transport'] if not n.startswith('SV_')}
            for r in refl.get('outputs' if stage == 'vs' else 'inputs', []):
                if r['type'] != 'vec4' or r['location'] not in regs or r['location'] > 15:
                    bad.append('%s: interpolant %s at location %s' % (tag, r['type'], r['location']))
    return row


def check_slot(job):
    bid, slot = job
    import compile_all_d3 as CA
    s = M.load(bid)[slot]
    stage = bid.split('_', 1)[0]
    row = {'bid': bid, 'slot': slot}
    try:
        retail = R.key_dxbc(s['retail'][0])
        measured = s['measured']
        formats = DF.input_formats(retail)
        cube = frozenset(int(r[1:]) for r, k, dim, _c, _n in measured['resources'] if dim == 'texturecube')
        with tempfile.TemporaryDirectory(prefix='d3xc_') as td:
            work = Path(td)
            for backend, target in (('vulkan', 'flakes-vulkan'), ('webgpu', 'flakes-webgpu')):
                src = CA.out_path(target, bid, slot)
                if not src.exists():
                    row[backend] = 'not built'
                    continue
                spv = src
                if backend == 'webgpu':
                    spv = work / ('wgsl_%04d.spv' % slot)
                    # WGSL clip space is D3D's; naga's SPIR-V would flip y for Vulkan
                    subprocess.run(['naga', '--keep-coordinate-space', str(src), str(spv)], capture_output=True,
                                   check=True)
                dxbc, refl = translate(spv, stage, work)
                leg, problems = CrossLeg.build(dxbc, refl, backend, measured, stage, cube)
                ref = G.FlakesLeg.open(retail, slang=False, view='retail', measured=measured, stage=stage)
                missing = sorted(set(k for k in ref.out_keys if k[0] != 'SV_CLIPDISTANCE') - set(leg.out_keys))
                if missing:
                    problems.append('outputs not found by location: %s' % missing[:4])
                ref.out_keys = {k: v for k, v in ref.out_keys.items() if k in leg.out_keys}
                res = G.compare(ref, {backend: leg}, measured, DR.slot_seed(s['retail'][0]['hash']), formats)[backend]
                row[backend] = 'fail' if problems else res.status
                row[backend + '_detail'] = problems or res.error
    except Exception as e:                                   # noqa: BLE001
        tb = traceback.extract_tb(e.__traceback__)[-1]
        row['error'] = '%s: %s @%s:%d' % (type(e).__name__, str(e)[:200], Path(tb.filename).name, tb.lineno)
    return row


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--bundle', action='append', default=[])
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--slot', action='append', type=int, default=[])
    ap.add_argument('--sample', type=int, default=0)
    ap.add_argument('--jobs', type=int, default=max(1, (os.cpu_count() or 2) - 2))
    ap.add_argument('--static', action='store_true', help='interface checks of every built slot')
    args = ap.parse_args(argv)
    import compile_all_d3 as CA
    bids = [R.bundle_id(d, s) for d, s in R.bundles()] if args.all else args.bundle
    if not bids:
        ap.error('pass --bundle <id> or --all')
    jobs = []
    for bid in bids:
        mine = [(bid, s['slot']) for s in M.load(bid)
                if (not args.slot or s['slot'] in args.slot)
                and any(CA.out_path(tg, bid, s['slot']).exists() for tg in ('flakes-vulkan', 'flakes-webgpu'))]
        if args.sample and len(mine) > args.sample:
            step = len(mine) / args.sample
            mine = [mine[int(k * step)] for k in range(args.sample)]
        jobs += mine
    if args.static:
        with ProcessPoolExecutor(args.jobs) as ex:
            rows = list(ex.map(static_check, jobs, chunksize=4))
        bad = [p for r in rows for p in r['problems']]
        for p in bad[:40]:
            print('  ' + p)
        print('static: %d slot(s), %s' % (len(rows), 'clean' if not bad else '%d problem(s)' % len(bad)))
        return 1 if bad else 0
    with ProcessPoolExecutor(args.jobs) as ex:
        rows = list(ex.map(check_slot, jobs, chunksize=1))
    reports = CA.OUT_ROOT / '_reports'
    reports.mkdir(parents=True, exist_ok=True)
    (reports / 'flakes_xcheck.json').write_text(json.dumps(rows, indent=1, default=str), 'utf-8')
    bad = 0
    for bid in bids:
        mine = [r for r in rows if r['bid'] == bid]
        st = {b: dict(Counter(r.get(b, 'error') for r in mine)) for b in ('vulkan', 'webgpu')}
        print('%-11s %3d slot(s)  vulkan %s  webgpu %s' % (bid, len(mine), st['vulkan'], st['webgpu']))
        for r in mine:
            for b in ('vulkan', 'webgpu'):
                if r.get(b) not in ('exact', 'order-only', 'not built'):
                    bad += 1
                    print('   slot %4d %-6s %s  %s' % (r['slot'], b, r.get(b), r.get(b + '_detail') or r.get('error')))
    print('OK' if not bad else '%d problem(s)' % bad)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
